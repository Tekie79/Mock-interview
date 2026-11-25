import Foundation

public enum ChannelEvent: Sendable {
    case connected(source: CaptureSource, epoch: UUID)
    case transcript(TranscriptEvent)
    case level(source: CaptureSource, value: Float)
    case gap(source: CaptureSource)
    case dropped(source: CaptureSource, chunks: Int)
}

/// One transport and one capture activation per source. Reconnect never replays audio.
public struct TranscriptionChannel: Sendable {
    public let source: CaptureSource
    private let audio: any AudioSource
    private let makeSTT: @Sendable () -> any StreamingSTT
    private let threshold: Float
    private let replay: Bool
    private let drainTimeout: Duration
    private let delay: @Sendable (Duration) async throws -> Void

    public init(source: CaptureSource, audio: any AudioSource, threshold: Float = 0.015,
                replay: Bool = false, drainTimeout: Duration = .seconds(6),
                makeSTT: @escaping @Sendable () -> any StreamingSTT,
                delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.audio = audio
        self.makeSTT = makeSTT
        self.threshold = threshold
        self.replay = replay
        self.drainTimeout = drainTimeout
        self.delay = delay
    }

    public func run(events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        for attempt in 0...2 {
            try Task.checkCancellation()
            let stt = makeSTT()
            let epoch = UUID()
            var captureStarted = false
            do {
                // Start the device only after its recognition transport has acknowledged readiness.
                let transcripts = try await stt.connect(source: source, epoch: epoch)
                try Task.checkCancellation()
                let frames = try await audio.start()
                captureStarted = true
                try Task.checkCancellation()
                await events(.connected(source: source, epoch: epoch))
                try await forward(frames: frames, transcripts: transcripts, stt: stt, events: events)
                await audio.stop()
                await stt.close()
                return
            } catch {
                await audio.stop()
                await stt.close()
                try Task.checkCancellation()
                let overrun = (error as? CaptureFailure) == .bufferOverrun
                if overrun { await events(.dropped(source: source, chunks: 1)) }
                let transient = (error as? ProviderFailure).map {
                    [ProviderFailure.unavailable, .disconnected, .timeout, .rateLimited].contains($0)
                } ?? false
                guard (transient || overrun), attempt < 2, !replay || !captureStarted else { throw error }
                await events(.gap(source: source))
                try await delay(.milliseconds(300 * (1 << attempt)))
            }
        }
    }

    private func forward(frames: AsyncThrowingStream<AudioFrame, Error>,
                         transcripts: AsyncThrowingStream<TranscriptEvent, Error>,
                         stt: any StreamingSTT,
                         events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        let progress = CommitProgress()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var endpoint = AudioEndpoint(threshold: threshold)
                var preRoll: [AudioFrame] = []
                var span: PipelineTiming?
                var lastSampleEnd: Int64?
                var latest: AudioFrame?
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard frame.source == source, frame.sampleRate == 24_000, !frame.pcm.isEmpty,
                          frame.pcm.count.isMultiple(of: 2), frame.startSample >= 0 else {
                        throw CaptureFailure.invalidFormat
                    }
                    if let lastSampleEnd, frame.startSample != lastSampleEnd {
                        throw CaptureFailure.bufferOverrun
                    }
                    lastSampleEnd = frame.startSample + Int64(frame.pcm.count / 2)
                    latest = frame
                    let activity = endpoint.observe(frame)
                    await events(.level(source: source, value: activity.level))
                    if span != nil {
                        try await stt.append(frame)
                    } else if activity.level >= threshold {
                        var began = PipelineTiming()
                        began.capture = preRoll.first?.capturedAt ?? frame.capturedAt
                        began.speechStart = frame.capturedAt
                        span = began
                        for leading in preRoll { try await stt.append(leading) }
                        preRoll.removeAll(keepingCapacity: true)
                        try await stt.append(frame)
                    } else {
                        preRoll.append(frame)
                        if preRoll.count > 12 { preRoll.removeFirst() }
                    }
                    if activity.shouldCommit, var closing = span {
                        closing.endpoint = frame.capturedAt
                        closing.commit = .now
                        try await progress.committed(closing)
                        try await stt.commit()
                        span = nil
                    }
                }
                try Task.checkCancellation()
                if var closing = span {
                    closing.endpoint = latest?.capturedAt
                    closing.commit = .now
                    try await progress.committed(closing)
                    try await stt.commit()
                }
                await progress.requestFinish()
                try await stt.finishInput()
                try await drain(progress)
            }
            group.addTask {
                for try await transcript in transcripts {
                    try Task.checkCancellation()
                    guard transcript.source == source else { continue }
                    let tagged = await progress.tag(transcript)
                    await events(.transcript(tagged))
                    await progress.delivered(tagged)
                }
                guard await progress.isFinished else { throw ProviderFailure.disconnected }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func drain(_ progress: CommitProgress) async throws {
        if await progress.isFinished { return }
        let changes = progress.changes
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes {
                    try Task.checkCancellation()
                    if await progress.isFinished { return }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: drainTimeout)
                throw ProviderFailure.incompleteTranscription
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private actor CommitProgress {
    nonisolated let changes: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: [PipelineTiming] = []
    private var firstPartials: [String: ContinuousClock.Instant] = [:]
    private var finalIDs: Set<String> = []
    private var finishing = false

    init() { (changes, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    var isFinished: Bool { finishing && pending.isEmpty }

    func committed(_ timing: PipelineTiming) throws {
        guard pending.count < 64 else { throw ProviderFailure.incompleteTranscription }
        pending.append(timing)
    }

    func requestFinish() {
        finishing = true
        signal.yield(())
    }

    func tag(_ event: TranscriptEvent) -> TranscriptEvent {
        var event = event
        if event.state == .partial {
            if firstPartials.count < 128, firstPartials[event.itemID] == nil {
                firstPartials[event.itemID] = .now
            }
        } else {
            let first = firstPartials.removeValue(forKey: event.itemID)
            event.timing = pending.first ?? event.timing
            event.timing.firstPartial = first ?? event.timing.firstPartial
            event.timing.final = .now
        }
        return event
    }

    func delivered(_ event: TranscriptEvent) {
        guard event.state == .final, finalIDs.count < 32_768, finalIDs.insert(event.itemID).inserted else { return }
        if !pending.isEmpty { pending.removeFirst() }
        signal.yield(())
    }
}
