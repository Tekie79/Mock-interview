#if os(macOS)
import AppKit
import AudioToolbox
import AudioBufferSlots
import AVFoundation
import CoreAudio
import Foundation
import os

public enum MacAudioDevices {
    public static func processes() throws -> [AudioEndpointChoice] {
        let items = try processRecords()
        var groups: [String: String] = [:]
        for item in items where item.pid != ProcessInfo.processInfo.processIdentifier {
            guard let app = NSRunningApplication(processIdentifier: item.pid), let name = app.localizedName else {
                continue
            }
            groups[app.bundleIdentifier ?? item.bundle ?? "pid:\(item.pid)"] = name
        }
        return groups.map { AudioEndpointChoice(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func microphones() throws -> [AudioEndpointChoice] {
        try devices(scope: kAudioDevicePropertyScopeInput).map(\.choice)
    }

    public static func outputs() throws -> [AudioEndpointChoice] {
        try devices(scope: kAudioDevicePropertyScopeOutput).map(\.choice)
    }

    fileprivate static func processGroup(_ group: String) throws -> [AudioObjectID] {
        let processes = try processRecords()
        if group.hasPrefix("pid:"), let pid = Int32(group.dropFirst(4)) {
            return processes.filter { $0.pid == pid }.map(\.object)
        }
        let ids = AudioRouteSelection.applicationMembers(in: processes.compactMap(\.bundle), group: group)
        return processes.filter { $0.bundle.map(ids.contains) == true }.map(\.object)
    }

    fileprivate static func ownProcess() -> [AudioObjectID] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return (try? processRecords().filter { $0.pid == pid }.map(\.object)) ?? []
    }

    fileprivate static func uidOfDefaultOutput() throws -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    fileprivate static func devices(scope: AudioObjectPropertyScope) throws -> [(object: AudioObjectID, choice: AudioEndpointChoice)] {
        try objectList(kAudioHardwarePropertyDevices).compactMap { object in
            var streams = property(kAudioDevicePropertyStreams, scope: scope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &streams, 0, nil, &size) == noErr, size > 0,
                  let name = stringProperty(object, kAudioObjectPropertyName),
                  let uid = stringProperty(object, kAudioDevicePropertyDeviceUID) else { return nil }
            return (object, AudioEndpointChoice(id: uid, name: name,
                                                canTap: size == UInt32(MemoryLayout<AudioStreamID>.stride)))
        }.sorted { $0.choice.name.localizedStandardCompare($1.choice.name) == .orderedAscending }
    }

    private static func processRecords() throws -> [(object: AudioObjectID, pid: pid_t, bundle: String?)] {
        try objectList(kAudioHardwarePropertyProcessObjectList).compactMap { object in
            var address = property(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
            let bundle = stringProperty(object, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return (object, pid, bundle)
        }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: result))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr,
              let result else { return nil }
        // Core Audio transfers ownership of these string properties to the caller.
        return result.takeRetainedValue() as String
    }

    fileprivate static func objectList(_ selector: AudioObjectPropertySelector,
                                      on object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = property(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try objects.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, baseAddress))
        }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }
}

private func property(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func check(_ status: OSStatus) throws {
    if status != noErr { throw CaptureFailure.hardware(status) }
}

public actor MacAudioSource: AudioSource {
    public enum Input: Sendable {
        case microphone(uid: String)
        case application(group: String)
        case output(uid: String?)
    }

    private let source: CaptureSource
    private let input: Input
    private var runID: UUID?
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var conversionTask: Task<Void, Never>?
    private var rawOutput: AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.Continuation?

    public init(source: CaptureSource, input: Input) {
        self.source = source
        self.input = input
    }

    public func start() async throws -> AsyncThrowingStream<AudioFrame, Error> {
        try Task.checkCancellation()
        guard runID == nil else { throw CaptureFailure.alreadyRunning }
        let id = UUID()
        runID = id
        let (frames, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(200))
        let (raw, buffers) = AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(40))
        rawOutput = buffers
        do {
            switch input {
            case .microphone(let uid):
                let granted = await Self.requestMicrophonePermission()
                try Task.checkCancellation()
                guard runID == id else { throw CancellationError() }
                guard granted else { throw CaptureFailure.permissionDenied }
                guard let device = try MacAudioDevices.devices(scope: kAudioDevicePropertyScopeInput)
                    .first(where: { $0.choice.id == uid })?.object else { throw CaptureFailure.sourceUnavailable }
                try monitorDevice(device, uid: uid, scope: kAudioDevicePropertyScopeInput, followsDefault: false,
                                  output: buffers)
                try startMicrophone(device, output: buffers)
            case .application(let group):
                let selected = try Set(MacAudioDevices.processGroup(group))
                guard !selected.isEmpty else { throw CaptureFailure.sourceUnavailable }
                applicationObserver = Self.observeApplicationTermination(group, output: buffers)
                let validate: @Sendable () throws -> Void = {
                    guard let current = try? Set(MacAudioDevices.processGroup(group)) else { throw CaptureFailure.routeChanged }
                    guard !current.isEmpty else { throw CaptureFailure.sourceUnavailable }
                    guard current == selected else { throw CaptureFailure.routeChanged }
                }
                try observe(property(kAudioHardwarePropertyProcessObjectList)) {
                    do { try validate() } catch { buffers.finish(throwing: error) }
                }
                try validate()
                try startTap(CATapDescription(monoMixdownOfProcesses: selected.sorted()), output: buffers)
                try validate()
            case .output(let uid):
                let defaultUID = uid == nil ? try MacAudioDevices.uidOfDefaultOutput() : nil
                let devices = try MacAudioDevices.devices(scope: kAudioDevicePropertyScopeOutput)
                let selected = try AudioRouteSelection.output(in: devices.map(\.choice), selectedUID: uid,
                                                               defaultUID: defaultUID)
                guard let device = devices.first(where: { $0.choice.id == selected.id })?.object else {
                    throw CaptureFailure.sourceUnavailable
                }
                try monitorDevice(device, uid: selected.id, scope: kAudioDevicePropertyScopeOutput,
                                  followsDefault: uid == nil, output: buffers)
                if uid == nil {
                    try observe(property(kAudioHardwarePropertyDefaultOutputDevice)) {
                        if (try? MacAudioDevices.uidOfDefaultOutput()) != selected.id {
                            buffers.finish(throwing: CaptureFailure.routeChanged)
                        }
                    }
                    guard (try? MacAudioDevices.uidOfDefaultOutput()) == selected.id else {
                        throw CaptureFailure.routeChanged
                    }
                }
                try startTap(CATapDescription(excludingProcesses: MacAudioDevices.ownProcess(),
                                              deviceUID: selected.id, stream: 0), output: buffers)
                if uid == nil, (try? MacAudioDevices.uidOfDefaultOutput()) != selected.id {
                    throw CaptureFailure.routeChanged
                }
            }
            try Task.checkCancellation()
        } catch {
            if runID == id { await stop() }
            throw error
        }
        output.onTermination = { [weak self] _ in Task { await self?.stop(id) } }
        conversionTask = Task.detached { [source] in
            do {
                var encoder = PCMEncoder(source: source)
                for try await lease in raw {
                    defer { lease.release() }
                    try Task.checkCancellation()
                    for frame in try encoder.convert(lease.buffer, capturedAt: lease.capturedAt) {
                        switch output.yield(frame) {
                        case .enqueued: break
                        case .terminated: return
                        case .dropped: throw CaptureFailure.bufferOverrun
                        @unknown default: throw CaptureFailure.invalidFormat
                        }
                    }
                }
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        return frames
    }

    public func stop() async {
        runID = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
        applicationObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        for (object, var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        listeners.removeAll()
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        rawOutput?.finish()
        rawOutput = nil
        let previous = conversionTask
        conversionTask = nil
        previous?.cancel()
        await previous?.value
    }

    private func stop(_ id: UUID) async {
        if id == runID { await stop() }
    }

    private static func requestMicrophonePermission() async -> Bool {
        let permission = AsyncStream<Bool> { status in
            AVCaptureDevice.requestAccess(for: .audio) {
                status.yield($0)
                status.finish()
            }
        }
        var responses = permission.makeAsyncIterator()
        return await responses.next() == true
    }

    private func startMicrophone(_ device: AudioObjectID,
                                 output: AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.Continuation) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard let unit = node.audioUnit else { throw CaptureFailure.sourceUnavailable }
        var selected = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &selected, UInt32(MemoryLayout<AudioObjectID>.size)))
        let format = node.outputFormat(forBus: 0)
        let pool = try NativeAudioBufferPool(format: format)
        let copy: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            pool.copy(buffer.audioBufferList, frames: buffer.frameLength, into: output)
        }
        node.installTap(onBus: 0, bufferSize: 960, format: nil, block: copy)
        self.engine = engine
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in output.finish(throwing: CaptureFailure.routeChanged) }
        try engine.start()
        var actual = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &actual, &size))
        guard actual == device, node.outputFormat(forBus: 0) == format else { throw CaptureFailure.routeChanged }
    }

    private static func observeApplicationTermination(
        _ group: String, output: AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.Continuation
    ) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == group || "pid:\(app.processIdentifier)" == group else { return }
            output.finish(throwing: CaptureFailure.sourceUnavailable)
        }
    }

    private func monitorDevice(_ object: AudioObjectID, uid: String, scope: AudioObjectPropertyScope,
                               followsDefault: Bool,
                               output: AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.Continuation) throws {
        let changesOutput = scope == kAudioDevicePropertyScopeOutput
        let unavailable: CaptureFailure = followsDefault ? .routeChanged : .sourceUnavailable
        let validatePresence: @Sendable () throws -> Void = {
            guard let devices = try? MacAudioDevices.devices(scope: scope) else { throw CaptureFailure.routeChanged }
            guard let current = devices.first(where: { $0.choice.id == uid }), !changesOutput || current.choice.canTap else {
                throw unavailable
            }
            guard current.object == object else { throw CaptureFailure.routeChanged }
        }
        let validateAlive: @Sendable () throws -> Void = {
            var address = property(kAudioDevicePropertyDeviceIsAlive)
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &alive) == noErr, alive != 0 else {
                throw unavailable
            }
        }
        let configuration: @Sendable () throws -> (streams: [AudioObjectID], rate: Double) = {
            let streams = try MacAudioDevices.objectList(kAudioDevicePropertyStreams, on: object, scope: scope)
            var address = property(kAudioDevicePropertyNominalSampleRate)
            var rate = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &rate))
            return (streams, rate)
        }
        let original = try configuration()
        let configurationChanged: @Sendable () -> Void = {
            do {
                try validatePresence()
                // HAL can notify listeners while an aggregate starts even when the selected device stays intact.
                if let current = try? configuration(), current == original { return }
                output.finish(throwing: CaptureFailure.routeChanged)
            } catch { output.finish(throwing: error) }
        }
        try observe(property(kAudioHardwarePropertyDevices)) {
            do { try validatePresence() } catch { output.finish(throwing: error) }
        }
        try observe(property(kAudioDevicePropertyDeviceIsAlive), on: object) {
            do { try validateAlive() } catch { output.finish(throwing: error) }
        }
        try observe(property(kAudioDevicePropertyNominalSampleRate), on: object, change: configurationChanged)
        try observe(property(kAudioDevicePropertyStreams, scope: scope), on: object, change: configurationChanged)
        try validatePresence()
        try validateAlive()
    }

    private func observe(_ property: AudioObjectPropertyAddress,
                         on object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                         change: @escaping @Sendable () -> Void) throws {
        var address = property
        let listener: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in change() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, listener))
        listeners.append((object, address, listener))
    }

    private func startTap(_ description: CATapDescription,
                          output: AsyncThrowingStream<NativeAudioBufferPool.Lease, Error>.Continuation) throws {
        description.name = "Mock Interview"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))

        var address = property(kAudioTapPropertyFormat)
        var streamFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamFormat))
        guard let format = AVAudioFormat(streamDescription: &streamFormat), streamFormat.mBytesPerFrame > 0 else {
            throw CaptureFailure.invalidFormat
        }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mock Interview Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate))
        let pool = try NativeAudioBufferPool(format: format)
        let bytesPerFrame = streamFormat.mBytesPerFrame
        let copy: @Sendable (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>,
                             UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>,
                             UnsafePointer<AudioTimeStamp>) -> Void = { _, input, _, _, _ in
            guard input.pointee.mNumberBuffers > 0 else { return }
            let bytes = input.pointee.mBuffers.mDataByteSize
            guard bytes.isMultiple(of: bytesPerFrame) else {
                output.finish(throwing: CaptureFailure.invalidFormat)
                return
            }
            let frames = bytes / bytesPerFrame
            pool.copy(input, frames: frames, into: output)
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil, copy))
        guard let ioProc else { throw CaptureFailure.sourceUnavailable }
        try check(AudioDeviceStart(aggregate, ioProc))
    }
}

// A slot belongs to the callback until yield, then to the conversion worker until release.
// The atomic slot table keeps those accesses disjoint without blocking the callback.
private final class NativeAudioBufferPool: @unchecked Sendable {
    struct Lease: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let capturedAt: ContinuousClock.Instant
        fileprivate let pool: NativeAudioBufferPool
        fileprivate let index: Int32

        func release() { AudioBufferSlotsRelease(pool.slots, index) }
    }

    private static let count = 40
    private let frameCapacity: AVAudioFrameCount
    private let buffers: [AVAudioPCMBuffer]
    fileprivate let slots: OpaquePointer

    init(format: AVAudioFormat) throws {
        guard format.sampleRate.isFinite, (8_000...384_000).contains(format.sampleRate),
              (1...8).contains(format.channelCount) else { throw CaptureFailure.invalidFormat }
        let capacity = AVAudioFrameCount(min(8_192, format.sampleRate * 5 / Double(Self.count)))
        var allocated: [AVAudioPCMBuffer] = []
        for _ in 0..<Self.count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw CaptureFailure.invalidFormat
            }
            allocated.append(buffer)
        }
        guard let slots = AudioBufferSlotsCreate(Self.count) else { throw CaptureFailure.bufferOverrun }
        frameCapacity = capacity
        buffers = allocated
        self.slots = slots
    }

    deinit { AudioBufferSlotsDestroy(slots) }

    func copy(_ input: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount,
              into output: AsyncThrowingStream<Lease, Error>.Continuation) {
        if frames == 0 { return }
        guard frames <= frameCapacity else {
            output.finish(throwing: CaptureFailure.invalidFormat)
            return
        }
        let index = AudioBufferSlotsAcquire(slots)
        guard index >= 0 else {
            output.finish(throwing: CaptureFailure.bufferOverrun)
            return
        }
        let buffer = buffers[Int(index)]
        let lease = Lease(buffer: buffer, capturedAt: .now, pool: self, index: index)
        buffer.frameLength = frames
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let targets = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard inputs.count == targets.count else {
            lease.release()
            output.finish(throwing: CaptureFailure.invalidFormat)
            return
        }
        for channel in inputs.indices {
            let source = inputs[channel]
            let target = targets[channel]
            guard let from = source.mData, let to = target.mData, source.mDataByteSize == target.mDataByteSize else {
                lease.release()
                output.finish(throwing: CaptureFailure.invalidFormat)
                return
            }
            memcpy(to, from, Int(source.mDataByteSize))
        }
        switch output.yield(lease) {
        case .enqueued: break
        case .dropped(let dropped):
            dropped.release()
            output.finish(throwing: CaptureFailure.bufferOverrun)
        case .terminated:
            lease.release()
        @unknown default:
            lease.release()
            output.finish(throwing: CaptureFailure.invalidFormat)
        }
    }
}

// Keep each converter on one worker or actor. AVAudioConverter borrows its input only during convert().
final class NativePCMConverter {
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else { throw CaptureFailure.invalidFormat }
        converter.downmix = input.channelCount > output.channelCount
        inputFormat = input
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let outputFormat = converter.outputFormat
        let count = ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)
        guard inputFormat == input.format, count.isFinite, count > 0, count <= Double(UInt32.max - 256),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count) + 256)
        else { throw CaptureFailure.invalidFormat }
        // The sendable callback takes the buffer exactly once, without a shared captured `var`.
        let pending = OSAllocatedUnfairLock(uncheckedState: Optional(input))
        let status = converter.convert(to: output, error: nil) { _, state in
            let buffer = pending.withLockUnchecked { stored in
                let buffer = stored
                stored = nil
                return buffer
            }
            state.pointee = buffer == nil ? .noDataNow : .haveData
            return buffer
        }
        guard status == .haveData || status == .inputRanDry,
              pending.withLockUnchecked({ $0 == nil }) else { throw CaptureFailure.invalidFormat }
        return output
    }

    func drain() throws -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096) else {
            throw CaptureFailure.invalidFormat
        }
        let status = converter.convert(to: output, error: nil) { _, state in
            state.pointee = .endOfStream
            return nil
        }
        if status == .endOfStream, output.frameLength == 0 { return nil }
        guard status != .error, output.frameLength > 0 else { throw CaptureFailure.invalidFormat }
        return output
    }
}

struct PCMEncoder {
    private static let rate = 24_000
    private static let frameBytes = 960
    let source: CaptureSource
    private var converter: NativePCMConverter?
    private var pending = Data()
    private var startSample: Int64 = 0
    private var captureAnchor: ContinuousClock.Instant?

    init(source: CaptureSource) { self.source = source }

    mutating func convert(_ input: AVAudioPCMBuffer, capturedAt: ContinuousClock.Instant) throws -> [AudioFrame] {
        if converter == nil {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Self.rate),
                                             channels: 1, interleaved: true) else { throw CaptureFailure.invalidFormat }
            converter = try NativePCMConverter(from: input.format, to: format)
            // A callback observes a block after capture. Estimate the first sample from that
            // observation, then keep distinct frame boundaries on this activation's sample clock.
            let nanoseconds = Double(input.frameLength) * 1_000_000_000 / input.format.sampleRate
            captureAnchor = capturedAt.advanced(by: .nanoseconds(-Int64(nanoseconds.rounded())))
        }
        guard let converter, let captureAnchor else { throw CaptureFailure.invalidFormat }
        let converted = try converter.convert(input)
        guard converted.frameLength > 0 else { return [] }
        guard let samples = converted.int16ChannelData else {
            throw CaptureFailure.invalidFormat
        }
        pending.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
        var frames: [AudioFrame] = []
        while pending.count >= Self.frameBytes {
            let start = Duration.milliseconds(startSample / Int64(Self.frameBytes / 2) * 20)
            let estimatedStart = captureAnchor.advanced(by: start)
            frames.append(AudioFrame(source: source, sampleRate: Self.rate, startSample: startSample,
                                     pcm: Data(pending.prefix(Self.frameBytes)), capturedAt: estimatedStart))
            pending.removeFirst(Self.frameBytes)
            startSample += Int64(Self.frameBytes / 2)
        }
        return frames
    }
}
#endif
