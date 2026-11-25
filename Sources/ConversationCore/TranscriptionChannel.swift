import Foundation

public enum ChannelEvent: Sendable {
    case connected(source: CaptureSource, epoch: UUID)
    case transcript(TranscriptEvent)
    case level(source: CaptureSource, value: Float)
    case gap(source: CaptureSource)
    case dropped(source: CaptureSource, chunks: Int)
    case sentAudio(source: CaptureSource, samples: Int)
    case candidateSpeech(source: CaptureSource, epoch: UUID, start: ContinuousClock.Instant, end: ContinuousClock.Instant)
}

enum TranscriptionRecoveryFailure: Error {
    case exhausted(ProviderFailure)
}

/// One transport and one capture activation per source. Reconnect never replays audio.
public struct TranscriptionChannel: Sendable {
    public let source: CaptureSource
    private let audio: any AudioSource
    private let makeSTT: @Sendable () -> any StreamingSTT
    private let threshold: Float
    private let replay: Bool
    private let drainTimeout: Duration
    private let recognitionTimeout: Duration
    private let heartbeatInterval: Duration
    private let watchdogSleep: @Sendable (Duration) async throws -> Void
    private let delay: @Sendable (Duration) async throws -> Void

    public init(source: CaptureSource, audio: any AudioSource, threshold: Float = 0.015,
                replay: Bool = false, drainTimeout: Duration = .seconds(6),
                recognitionTimeout: Duration = .seconds(15),
                heartbeatInterval: Duration = .seconds(15),
                watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                makeSTT: @escaping @Sendable () -> any StreamingSTT,
                delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.audio = audio
        self.makeSTT = makeSTT
        self.threshold = threshold
        self.replay = replay
        self.drainTimeout = max(.milliseconds(10), drainTimeout)
        self.recognitionTimeout = max(.milliseconds(10), recognitionTimeout)
        self.heartbeatInterval = max(.milliseconds(10), heartbeatInterval)
        self.watchdogSleep = watchdogSleep
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
                try await forward(frames: frames, transcripts: transcripts, epoch: epoch, stt: stt, events: events)
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
                guard (transient || overrun || (error as? CaptureFailure) == .routeChanged),
                      !replay || !captureStarted else { throw error }
                if attempt == 2 {
                    if transient, let failure = error as? ProviderFailure {
                        throw TranscriptionRecoveryFailure.exhausted(failure)
                    }
                    throw error
                }
                await events(.gap(source: source))
                try await delay(.milliseconds(300 * (1 << attempt)))
            }
        }
    }

    private func forward(frames: AsyncThrowingStream<AudioFrame, Error>,
                         transcripts: AsyncThrowingStream<TranscriptEvent, Error>,
                         epoch: UUID, stt: any StreamingSTT,
                         events: @escaping @Sendable (ChannelEvent) async -> Void) async throws {
        let behavior = await stt.behavior
        guard behavior.sampleRate == 24_000 else { throw CaptureFailure.invalidFormat }
        let providerCommits = behavior.delivery == .providerCommit
        let progress = RecognitionProgress(providerCommits: providerCommits, requiresStreamEnd: behavior.requiresStreamEnd)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var endpoint = AudioEndpoint(threshold: threshold)
                var preRoll: [AudioFrame] = []
                var span: PipelineTiming?
                var lastSampleEnd: Int64?
                var latest: AudioFrame?
                var latestVoicedAt: ContinuousClock.Instant?
                var lastSpeechReport: ContinuousClock.Instant?
                var sampleUsage = 0

                func send(_ frame: AudioFrame, voiced: Bool = false) async throws {
                    await progress.sending(frame, voiced: voiced)
                    try await stt.append(frame)
                    await progress.sent()
                    sampleUsage += frame.pcm.count / 2
                    if sampleUsage >= 24_000 {
                        await events(.sentAudio(source: source, samples: sampleUsage))
                        sampleUsage = 0
                    }
                }
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard frame.source == source, frame.sampleRate == 24_000, !frame.pcm.isEmpty,
                          frame.pcm.count.isMultiple(of: 2), frame.startSample >= 0,
                          frame.startSample <= Int64.max - Int64(frame.pcm.count / 2) else {
                        throw CaptureFailure.invalidFormat
                    }
                    if let lastSampleEnd, frame.startSample != lastSampleEnd {
                        throw CaptureFailure.bufferOverrun
                    }
                    lastSampleEnd = frame.startSample + Int64(frame.pcm.count / 2)
                    latest = frame
                    let activity = endpoint.observe(frame)
                    let voiced = activity.level >= threshold
                    if voiced {
                        latestVoicedAt = frame.capturedAt.advanced(by: .seconds(Double(frame.pcm.count / 2) / 24_000))
                    }
                    await events(.level(source: source, value: activity.level))
                    if source.role == .candidate, let end = latestVoicedAt, voiced || activity.shouldCommit {
                        let start = span?.speechStart ?? frame.capturedAt
                        if activity.shouldCommit || lastSpeechReport.map({ $0.duration(to: end) >= .milliseconds(100) }) != false {
                            await events(.candidateSpeech(source: source, epoch: epoch, start: start, end: end))
                            lastSpeechReport = activity.shouldCommit ? nil : end
                        }
                    }
                    if span != nil {
                        try await send(frame, voiced: voiced)
                    } else if voiced {
                        var began = PipelineTiming()
                        began.capture = preRoll.first?.capturedAt ?? frame.capturedAt
                        began.speechStart = frame.capturedAt
                        began.audioTimingBasis = .localSpeechEstimate
                        span = began
                        if !behavior.streamsSilence {
                            for leading in preRoll { try await send(leading) }
                        }
                        preRoll.removeAll(keepingCapacity: true)
                        try await send(frame, voiced: true)
                    } else if behavior.streamsSilence {
                        try await send(frame)
                    } else {
                        preRoll.append(frame)
                        if preRoll.count > 12 { preRoll.removeFirst() }
                    }
                    if activity.shouldCommit, var closing = span {
                        closing.endpoint = min(latestVoicedAt ?? frame.capturedAt, .now)
                        if providerCommits {
                            try await progress.endedSpeech(closing)
                        } else {
                            closing.commit = .now
                            try await progress.committed(closing)
                            try await stt.commit()
                            await progress.sent()
                        }
                        span = nil
                    }
                }
                try Task.checkCancellation()
                if var closing = span {
                    closing.endpoint = (latestVoicedAt ?? latest?.capturedAt).map { min($0, .now) }
                    if source.role == .candidate, let start = closing.speechStart, let end = closing.endpoint {
                        await events(.candidateSpeech(source: source, epoch: epoch, start: start, end: end))
                    }
                    if providerCommits {
                        try await progress.endedSpeech(closing)
                    } else {
                        closing.commit = .now
                        try await progress.committed(closing)
                        try await stt.commit()
                        await progress.sent()
                    }
                }
                if sampleUsage > 0 { await events(.sentAudio(source: source, samples: sampleUsage)) }
                await progress.requestFinish()
                try await stt.finishInput()
                await progress.finishSent()
                try await drain(progress)
                return true
            }
            group.addTask {
                for try await transcript in transcripts {
                    try Task.checkCancellation()
                    guard transcript.source == source, transcript.epoch == epoch else { continue }
                    guard let tagged = await progress.tag(transcript) else { continue }
                    await events(.transcript(tagged))
                    await progress.delivered(tagged)
                }
                guard await progress.streamEnded() else { throw ProviderFailure.disconnected }
                return false
            }
            group.addTask {
                while true {
                    try await watchdogSleep(min(.seconds(1), recognitionTimeout / 2, drainTimeout))
                    try Task.checkCancellation()
                    if let failure = await progress.expired(recognition: recognitionTimeout, drain: drainTimeout) {
                        throw failure
                    }
                }
            }
            group.addTask {
                while true {
                    try await watchdogSleep(heartbeatInterval)
                    try Task.checkCancellation()
                    if await progress.isFinishing { return false }
                    try await stt.checkConnection()
                }
            }
            defer { group.cancelAll() }
            while let writerFinished = try await group.next(), !writerFinished {}
        }
    }

    private func drain(_ progress: RecognitionProgress) async throws {
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

actor RecognitionProgress {
    private struct Observation {
        let timing: PipelineTiming
        let closedAt: ContinuousClock.Instant
    }

    nonisolated let changes: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: [Observation] = []
    private var partials: [String: (first: ContinuousClock.Instant, text: String)] = [:]
    private var finalIDs: Set<String> = []
    private var writeStarted: ContinuousClock.Instant?
    private var finishing: ContinuousClock.Instant?
    private var finishWritten = false
    private var ended = false
    private let providerCommits: Bool
    private let requiresStreamEnd: Bool
    private var speech: PipelineTiming?
    private var speechProgress: ContinuousClock.Instant?
    private var coverage: [(start: ContinuousClock.Instant, end: ContinuousClock.Instant)] = []
    private var providerRanges: [TranscriptAudioRange] = []
    private var audioClock = StreamAudioClock()

    init(providerCommits: Bool, requiresStreamEnd: Bool = false) {
        self.providerCommits = providerCommits
        self.requiresStreamEnd = providerCommits || requiresStreamEnd
        (changes, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var isFinished: Bool { finishWritten && (requiresStreamEnd ? ended : pending.isEmpty) }
    var isFinishing: Bool { finishing != nil }

    func expired(recognition: Duration, drain: Duration, now: ContinuousClock.Instant = .now) -> ProviderFailure? {
        if let finishing {
            return !isFinished && finishing.duration(to: now) >= drain ? .incompleteTranscription : nil
        }
        if [writeStarted, pending.first?.closedAt].compactMap({ $0 }).contains(where: {
            $0.duration(to: now) >= recognition
        }) || speechProgress.map({ $0.duration(to: now) >= recognition + .seconds(10) }) == true { return .timeout }
        return nil
    }

    func streamEnded() -> Bool {
        ended = true
        signal.yield(())
        return finishing != nil && (requiresStreamEnd || pending.isEmpty)
    }

    func sending(_ frame: AudioFrame, voiced: Bool, now: ContinuousClock.Instant = .now) {
        writeStarted = now
        guard providerCommits else { return }
        audioClock.record(frame)
        if voiced {
            if speech == nil {
                var start = PipelineTiming()
                start.capture = frame.capturedAt
                start.speechStart = frame.capturedAt
                start.audioTimingBasis = .localSpeechEstimate
                speech = start
                speechProgress = now
            }
            speech?.endpoint = frame.capturedAt.advanced(by: .seconds(Double(frame.pcm.count / 2) / 24_000))
        }
    }

    func sent() { writeStarted = nil }

    func endedSpeech(_ timing: PipelineTiming, now: ContinuousClock.Instant = .now) throws {
        speech = nil
        speechProgress = nil
        if !coverage.contains(where: { Self.covers($0, timing) }) {
            try queue(timing, now: now)
        }
    }

    func committed(_ timing: PipelineTiming, now: ContinuousClock.Instant = .now) throws {
        writeStarted = now
        try queue(timing, now: now)
    }

    private func queue(_ timing: PipelineTiming, now: ContinuousClock.Instant) throws {
        guard pending.count < 64 else { throw ProviderFailure.timeout }
        pending.append(.init(timing: timing, closedAt: now))
    }

    func requestFinish() {
        finishing = .now
        signal.yield(())
    }

    func finishSent() {
        finishWritten = true
        signal.yield(())
    }

    func tag(_ event: TranscriptEvent, now: ContinuousClock.Instant = .now) -> TranscriptEvent? {
        var event = event
        guard !finalIDs.contains(event.itemID) else { return nil }
        if event.state == .partial {
            if partials.count < 128, !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               partials[event.itemID]?.text != event.text {
                partials[event.itemID] = (partials[event.itemID]?.first ?? now, event.text)
                if speechProgress != nil { speechProgress = now }
            }
            if let range = event.audioRange, let boundary = audioClock.measure(range) {
                event.timing.speechStart = boundary.start
                event.timing.endpoint = boundary.end
                event.timing.audioTimingBasis = .providerRangeEstimate
            }
        } else {
            let first = partials.removeValue(forKey: event.itemID)?.first
            if !providerCommits {
                event.timing = pending.first?.timing ?? event.timing
            } else if let range = event.audioRange {
                // A late, overlapping range is valid; reusing the same coordinates is not new evidence.
                if !providerRanges.contains(range), let boundary = audioClock.measure(range) {
                    providerRanges.append(range)
                    if providerRanges.count > 128 { providerRanges.removeFirst() }
                    event.timing.capture = boundary.start
                    event.timing.speechStart = boundary.start
                    event.timing.endpoint = boundary.end
                    event.timing.audioTimingBasis = .providerRangeEstimate
                }
            } else if let observation = pending.first?.timing ?? speech,
                      let start = observation.speechStart, first.map({ $0 >= start }) ?? true {
                // An untimed final can acknowledge at most the oldest local speech observation.
                event.timing = observation
            }
            event.timing.firstPartial = first ?? event.timing.firstPartial
            event.timing.final = now
        }
        return event
    }

    func delivered(_ event: TranscriptEvent) {
        guard event.state == .final, finalIDs.count < 32_768, finalIDs.insert(event.itemID).inserted else { return }
        if !providerCommits {
            if !pending.isEmpty { pending.removeFirst() }
        } else if let start = event.timing.speechStart, let end = event.timing.endpoint {
            let span = (start, end)
            if event.timing.audioTimingBasis == .providerRangeEstimate {
                pending.removeAll { Self.covers(span, $0.timing) }
            } else if pending.first?.timing.endpoint == end {
                pending.removeFirst()
            }
            coverage.append(span)
            if coverage.count > 64 { coverage.removeFirst() }
            if let speech, Self.covers(span, speech) { speechProgress = event.timing.final }
        }
        signal.yield(())
    }

    private static func covers(_ span: (start: ContinuousClock.Instant, end: ContinuousClock.Instant),
                               _ timing: PipelineTiming) -> Bool {
        guard let start = timing.speechStart, let end = timing.endpoint else { return false }
        let overlap = max(span.start, start).duration(to: min(span.end, end))
        return overlap > .zero && overlap >= start.duration(to: end) / 2
            && span.end >= end.advanced(by: .milliseconds(-250))
    }
}
