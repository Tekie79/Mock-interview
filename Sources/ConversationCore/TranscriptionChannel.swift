import Foundation

public enum ChannelEvent: Sendable {
    case connected(source: CaptureSource, epoch: UUID)
    case transcript(TranscriptEvent)
    case level(source: CaptureSource, value: Float)
    case gap(source: CaptureSource)
}

/// Runs one transport per selected source and starts a fresh epoch on reconnect.
/// Audio from the failed connection is discarded instead of replaying uncertain commits.
public struct TranscriptionChannel: Sendable {
    public let source: CaptureSource
    private let audio: any AudioSource
    private let makeSTT: @Sendable () -> any StreamingSTT
    private let threshold: Float
    private let delay: @Sendable (Duration) async throws -> Void

    public init(source: CaptureSource, audio: any AudioSource, threshold: Float = 0.015,
                makeSTT: @escaping @Sendable () -> any StreamingSTT,
                delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.audio = audio
        self.makeSTT = makeSTT
        self.threshold = threshold
        self.delay = delay
    }

    public func run(events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        let frames = try await audio.start()
        do {
            try await consume(frames: frames, events: events)
            await audio.stop()
        } catch {
            await audio.stop()
            throw error
        }
    }

    private func consume(frames: AsyncThrowingStream<AudioFrame, Error>,
                         events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        // Reconnect begins with a new capture activation. This also clears any queued old audio.
        var frames = frames
        for attempt in 0...2 {
            try Task.checkCancellation()
            let stt = makeSTT()
            let epoch = UUID()
            do {
                let transcripts = try await stt.connect(source: source, epoch: epoch)
                await events(.connected(source: source, epoch: epoch))
                try await forward(frames: frames, transcripts: transcripts, stt: stt, events: events)
                await stt.close()
                return
            } catch {
                await stt.close()
                guard !Task.isCancelled else { throw CancellationError() }
                let transient = (error as? ProviderFailure).map {
                    [ProviderFailure.unavailable, .disconnected, .timeout, .rateLimited].contains($0)
                } ?? false
                guard transient || (error as? CaptureFailure) == .bufferOverrun, attempt < 2 else {
                    throw error
                }
                await events(.gap(source: source))
                await audio.stop()
                try await delay(.milliseconds(300 * (1 << attempt)))
                frames = try await audio.start()
            }
        }
    }

    private func forward(frames: AsyncThrowingStream<AudioFrame, Error>,
                         transcripts: AsyncThrowingStream<TranscriptEvent, Error>,
                         stt: any StreamingSTT,
                         events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var endpoint = AudioEndpoint(threshold: threshold)
                var preRoll: [AudioFrame] = []
                var sending = false
                var hasCommitted = false
                for try await frame in frames {
                    try Task.checkCancellation()
                    let activity = endpoint.observe(frame)
                    await events(.level(source: source, value: activity.level))
                    if sending {
                        try await stt.append(frame)
                    } else if activity.level >= threshold {
                        for leadingFrame in preRoll { try await stt.append(leadingFrame) }
                        preRoll.removeAll(keepingCapacity: true)
                        try await stt.append(frame)
                        sending = true
                    } else {
                        preRoll.append(frame)
                        if preRoll.count > 12 { preRoll.removeFirst() }
                    }
                    if activity.shouldCommit, sending {
                        try await stt.commit()
                        sending = false
                        hasCommitted = true
                    }
                }
                if sending {
                    try await stt.commit()
                    hasCommitted = true
                }
                if hasCommitted {
                    // A finite replay may end before the provider sends its last transcript.
                    try await delay(.seconds(3))
                }
                return true
            }
            group.addTask {
                for try await transcript in transcripts {
                    try Task.checkCancellation()
                    await events(.transcript(transcript))
                }
                return false
            }
            defer { group.cancelAll() }
            guard let captureEnded = try await group.next(), captureEnded else {
                throw ProviderFailure.disconnected
            }
        }
    }
}
