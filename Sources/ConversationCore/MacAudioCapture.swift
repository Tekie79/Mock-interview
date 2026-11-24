#if os(macOS)
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public struct MacAudioChoice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let name: String
}

public enum MacAudioDevices {
    public static func processes() throws -> [MacAudioChoice] {
        try objectList(kAudioHardwarePropertyProcessObjectList).compactMap { object in
            var address = property(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: pid),
                  let name = application.localizedName else { return nil }
            return MacAudioChoice(id: object, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func microphones() throws -> [MacAudioChoice] {
        try objectList(kAudioHardwarePropertyDevices).compactMap { object in
            var input = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &input, 0, nil, &size) == noErr, size > 0 else {
                return nil
            }
            var nameAddress = property(kAudioObjectPropertyName)
            var name: CFString?
            size = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(object, &nameAddress, 0, nil, &size, &name) == noErr,
                  let name else { return nil }
            return MacAudioChoice(id: object, name: name as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    fileprivate static func objectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = property(selector)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try objects.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, baseAddress))
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
        case microphone(AudioObjectID)
        case process(AudioObjectID)
    }

    private let source: CaptureSource
    private let input: Input
    private var runID: UUID?
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var conversionTask: Task<Void, Never>?
    private var rawOutput: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?

    public init(source: CaptureSource, input: Input) {
        self.source = source
        self.input = input
    }

    public func start() async throws -> AsyncThrowingStream<AudioFrame, Error> {
        guard runID == nil else { throw CaptureFailure.alreadyRunning }
        let id = UUID()
        runID = id
        let (frames, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(200))
        let (raw, buffers) = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(96))
        rawOutput = buffers
        do {
            switch input {
            case .microphone(let device):
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureFailure.permissionDenied }
                guard runID == id else { throw CancellationError() }
                try startMicrophone(device, output: buffers)
            case .process(let process):
                try startProcess(process, output: buffers)
            }
        } catch {
            if runID == id { await stop() }
            throw error
        }
        conversionTask = Task.detached { [source, weak self] in
            do {
                var encoder = PCMEncoder(source: source)
                for try await buffer in raw {
                    try Task.checkCancellation()
                    for frame in try encoder.convert(buffer) {
                        if case .dropped = output.yield(frame) { throw CaptureFailure.bufferOverrun }
                    }
                }
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
            Task { await self?.stop(id) }
        }
        output.onTermination = { [weak self] _ in Task { await self?.stop(id) } }
        return frames
    }

    public func stop() async {
        runID = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        if let processListener {
            var address = property(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main,
                                                   processListener)
        }
        processListener = nil
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

    private func startMicrophone(_ device: AudioObjectID,
                                 output: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard let unit = node.audioUnit else { throw CaptureFailure.sourceUnavailable }
        var selected = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &selected, UInt32(MemoryLayout<AudioObjectID>.size)))
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.invalidFormat }
        node.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            copyAudio(buffer.audioBufferList, frames: buffer.frameLength, format: format, into: output)
        }
        self.engine = engine
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in output.finish(throwing: CaptureFailure.sourceUnavailable) }
        try engine.start()
    }

    private func startProcess(_ process: AudioObjectID,
                              output: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) throws {
        let selector = kAudioHardwarePropertyProcessObjectList
        guard try MacAudioDevices.objectList(selector).contains(process) else { throw CaptureFailure.sourceUnavailable }
        let description = CATapDescription()
        description.name = "Mock Interview"
        description.processes = [process]
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
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
        let bytesPerFrame = streamFormat.mBytesPerFrame
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, _, _ in
            let frames = input.pointee.mBuffers.mDataByteSize / bytesPerFrame
            copyAudio(input, frames: frames, format: format, into: output)
        })
        guard let ioProc else { throw CaptureFailure.sourceUnavailable }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            if (try? MacAudioDevices.objectList(selector).contains(process)) != true {
                output.finish(throwing: CaptureFailure.sourceUnavailable)
            }
        }
        address = property(selector)
        try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener))
        processListener = listener
        try check(AudioDeviceStart(aggregate, ioProc))
    }
}

private func copyAudio(_ input: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount,
                       format: AVAudioFormat,
                       into output: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) {
    guard (1...8_192).contains(frames),
          let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
    copy.frameLength = frames
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard inputs.count == destinations.count else { return }
    for index in inputs.indices {
        let source = inputs[index]
        let destination = destinations[index]
        guard let from = source.mData, let to = destination.mData,
              source.mDataByteSize == destination.mDataByteSize else { return }
        memcpy(to, from, Int(source.mDataByteSize))
    }
    if case .dropped = output.yield(copy) { output.finish(throwing: CaptureFailure.bufferOverrun) }
}

private struct PCMEncoder {
    private static let rate = 24_000
    private static let frameBytes = 960
    let source: CaptureSource
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var startSample: Int64 = 0

    init(source: CaptureSource) { self.source = source }

    mutating func convert(_ input: AVAudioPCMBuffer) throws -> [AudioFrame] {
        if converter == nil {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Self.rate),
                                             channels: 1, interleaved: true) else { throw CaptureFailure.invalidFormat }
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter, converter.inputFormat == input.format,
              let converted = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * Double(Self.rate)
                                                     / input.format.sampleRate)) + 256
              ) else { throw CaptureFailure.invalidFormat }
        var sent = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if sent {
                state.pointee = .noDataNow
                return nil
            }
            sent = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, let samples = converted.int16ChannelData else {
            throw CaptureFailure.invalidFormat
        }
        pending.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
        var frames: [AudioFrame] = []
        while pending.count >= Self.frameBytes {
            frames.append(AudioFrame(source: source, sampleRate: Self.rate, startSample: startSample,
                                     pcm: Data(pending.prefix(Self.frameBytes))))
            pending.removeFirst(Self.frameBytes)
            startSample += Int64(Self.frameBytes / 2)
        }
        return frames
    }
}
#endif
