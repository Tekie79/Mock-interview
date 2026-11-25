import Foundation

public enum CaptureFailure: Error, Equatable, Sendable {
    case alreadyRunning
    case routeChanged
    case unsupportedRoute
    case conflictingMicrophones
    case invalidFormat
    case sourceUnavailable
    case permissionDenied
    case bufferOverrun
    case hardwareStartupTimedOut
    case hardwareStartupBusy
    case hardware(Int32)
}

public struct AudioActivity: Equatable, Sendable {
    public let level: Float
    public let shouldCommit: Bool
}

/// Uses the sample clock so replay and live audio apply the same endpointing.
public struct AudioEndpoint {
    private let threshold: Float
    private let silenceSeconds: Double
    private let segmentSeconds: Double
    private var voiced = false
    private var segmentDuration: Double = 0
    private var silenceDuration: Double = 0

    public init(threshold: Float = 0.015, silenceSeconds: Double = 0.45,
                segmentSeconds: Double = 20) {
        self.threshold = threshold
        self.silenceSeconds = silenceSeconds
        self.segmentSeconds = segmentSeconds
    }

    public mutating func observe(_ frame: AudioFrame) -> AudioActivity {
        let sampleCount = frame.pcm.count / 2
        guard sampleCount > 0, frame.sampleRate > 0 else {
            return AudioActivity(level: 0, shouldCommit: false)
        }
        let energy = frame.pcm.withUnsafeBytes { raw in
            var sum: Double = 0
            for index in 0..<sampleCount {
                let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                let normalized = Double(Int16(bitPattern: bits)) / 32_768
                sum += normalized * normalized
            }
            return sum
        }
        let level = Float((energy / Double(sampleCount)).squareRoot())
        let duration = Double(sampleCount) / Double(frame.sampleRate)
        if level >= threshold {
            voiced = true
            silenceDuration = 0
        } else if voiced {
            silenceDuration += duration
        }
        if voiced {
            segmentDuration += duration
        }
        let commit = voiced && (silenceDuration >= silenceSeconds || segmentDuration >= segmentSeconds)
        if commit {
            voiced = false
            silenceDuration = 0
            segmentDuration = 0
        }
        return AudioActivity(level: level, shouldCommit: commit)
    }
}

public actor PCMReplaySource: AudioSource {
    private let source: CaptureSource
    private let sampleRate: Int
    private let pcm: Data
    private let pace: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var runID: UUID?

    public init(source: CaptureSource, sampleRate: Int = 24_000, pcm: Data,
                pace: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.sampleRate = sampleRate
        self.pcm = pcm
        self.pace = pace
    }

    public func start() throws -> AsyncThrowingStream<AudioFrame, Error> {
        guard task == nil else { throw CaptureFailure.alreadyRunning }
        guard (50...192_000).contains(sampleRate), pcm.count.isMultiple(of: 2) else {
            throw CaptureFailure.invalidFormat
        }
        let id = UUID()
        runID = id
        let (stream, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(200)
        )
        let frameBytes = max(1, sampleRate / 50) * 2
        task = Task { [weak self, source, pcm, sampleRate, pace] in
            defer { output.finish() }
            do {
                for offset in stride(from: 0, to: pcm.count, by: frameBytes) {
                    try Task.checkCancellation()
                    let start = pcm.startIndex + offset
                    let end = pcm.startIndex + min(offset + frameBytes, pcm.count)
                    let frame = AudioFrame(source: source, sampleRate: sampleRate,
                                           startSample: Int64(offset / 2), pcm: pcm.subdata(in: start..<end))
                    if case .dropped = output.yield(frame) {
                        throw CaptureFailure.bufferOverrun
                    }
                    try await pace(.seconds(Double(end - start) / Double(sampleRate * 2)))
                }
            } catch is CancellationError {
                // Stop closes the stream normally.
            } catch {
                output.finish(throwing: error)
            }
            await self?.finished(id)
        }
        output.onTermination = { [weak self] _ in
            Task { await self?.cancel(id) }
        }
        return stream
    }

    public func stop() async {
        let previous = task
        previous?.cancel()
        await previous?.value
    }

    private func cancel(_ id: UUID) {
        if id == runID { task?.cancel() }
    }

    private func finished(_ id: UUID) {
        if id == runID {
            task = nil
            runID = nil
        }
    }
}
