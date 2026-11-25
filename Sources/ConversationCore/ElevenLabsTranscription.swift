import Foundation
#if canImport(os)
import os
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ElevenLabsSpeechConfiguration: Equatable, Sendable {
    public var model: String
    public var language: String?
    public var detectLanguage: Bool
    public var strategy: TranscriptionCommitStrategy
    public var silenceSeconds: Double
    public var vocabulary: [String]
    public var localActivityThreshold: Float
    public var diarize: Bool

    public init(model: String = "scribe_v3_live", language: String? = nil, detectLanguage: Bool = true,
                strategy: TranscriptionCommitStrategy = .semanticTurn, silenceSeconds: Double = 0.65,
                vocabulary: [String] = [], localActivityThreshold: Float = 0.015, diarize: Bool = false) {
        self.model = model
        self.language = language
        self.detectLanguage = detectLanguage
        self.strategy = strategy
        self.silenceSeconds = silenceSeconds
        self.vocabulary = vocabulary
        self.localActivityThreshold = localActivityThreshold
        self.diarize = diarize
    }

    func request(key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw ProviderFailure.missingCredentials }
        let capabilities = ProviderCapabilities.describe(.elevenLabs, model: model)
        guard capabilities.models.contains(model), capabilities.commits.contains(strategy), !diarize || capabilities.diarization,
              silenceSeconds.isFinite, (0.192...3).contains(silenceSeconds), (0.005...0.08).contains(localActivityThreshold) else {
            throw ProviderFailure.unsupportedCapability
        }
        if let language, !language.isEmpty,
           !(2...3).contains(language.count) || !language.utf8.allSatisfy({ (97...122).contains($0) }) {
            throw ProviderFailure.unsupportedCapability
        }
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = "api.elevenlabs.io"
        parts.path = "/v1/speech-to-text/realtime"
        let strategyWire: String
        switch strategy {
        case .manual: strategyWire = "manual"
        case .voiceActivity: strategyWire = "vad"
        case .semanticTurn: strategyWire = "turn_prediction"
        }
        parts.queryItems = [
            .init(name: "model_id", value: model), .init(name: "audio_format", value: "pcm_24000"),
            .init(name: "commit_strategy", value: strategyWire),
            .init(name: "include_timestamps", value: diarize ? "false" : "true"),
            .init(name: "include_language_detection", value: detectLanguage ? "true" : "false"),
            .init(name: "vad_silence_threshold_secs", value: String(silenceSeconds)),
            .init(name: "enable_logging", value: "false")
        ]
        if diarize { parts.queryItems?.append(.init(name: "diarize", value: "true")) }
        if let language, !language.isEmpty { parts.queryItems?.append(.init(name: "language_code", value: language)) }
        for word in vocabulary.prefix(25) where !word.isEmpty {
            parts.queryItems?.append(.init(name: "keyterms", value: String(word.prefix(32))))
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw ProviderFailure.requestRejected }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }
}

struct ElevenLabsWire: Decodable, Sendable {
    struct Configuration: Decodable, Sendable {
        let model_id: String
        let audio_format: String
        let sample_rate: Int
    }

    struct Word: Decodable, Sendable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String?
        let speaker_id: String?
    }

    let message_type: String
    let session_id: String?
    let config: Configuration?
    let text: String?
    let language_code: String?
    let turn_probability: Double?
    let words: [Word]?
    let segment_index: Int?
    let from_speaker_id: String?
    let to_speaker_id: String?

    static func decode(_ bytes: Data) throws -> Self {
        guard let value = try? JSONDecoder().decode(Self.self, from: bytes) else {
            throw ProviderFailure.malformedEvent
        }
        switch value.message_type {
        case "auth_error": throw ProviderFailure.authentication
        case "rate_limited", "commit_throttled": throw ProviderFailure.rateLimited
        case "quota_exceeded": throw ProviderFailure.quotaExhausted
        case "invalid_request", "input_error", "chunk_size_exceeded", "unaccepted_terms":
            throw ProviderFailure.requestRejected
        case "session_time_limit_exceeded", "resource_exhausted", "transcriber_error", "error",
             "insufficient_audio_activity":
            throw ProviderFailure.unavailable
        case "queue_overflow": throw CaptureFailure.bufferOverrun
        default: return value
        }
    }

    static func chunk(_ bytes: Data, commit: Bool) throws -> String {
        let body: [String: Any] = [
            "message_type": "input_audio_chunk", "audio_base_64": bytes.base64EncodedString(),
            "sample_rate": 24_000, "commit": commit
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }
}

public actor ElevenLabsTranscriber: StreamingSTT {
    private struct Partial {
        let id: Int
        let observedFrame: Int64?
        var text: String
        var prediction: Double?
    }

    private struct Companion {
        let text: String
        let partial: Partial?
        var detail: Detail?
    }

    private struct Detail {
        let text: String
        let words: [TranscriptWord]
        let language: String?
        let range: TranscriptAudioRange
        let samples: Range<Int64>
    }

    private struct DiarizedCommit {
        let text: String
        let partial: Partial
    }

    private struct CommitRequest {
        let samples: Range<Int64>
        var receivedFinal = false
    }

    private enum InputState { case open, flushing, draining, drained }

    public nonisolated let behavior: TranscriptionBehavior
    private let key: String
    private let config: ElevenLabsSpeechConfiguration
    private let makeSocket: @Sendable (URLRequest) -> any RealtimeSocket
    private var socket: (any RealtimeSocket)?
    private var connectionID: UUID?
    private var reader: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var chunk = Data()
    private var sentSamples: Int64 = 0
    private struct VoicedSpan {
        let samples: Range<Int64>
        var leadingEdge = true
        var trailingEdge = true
    }

    private static let minimumCommitOverlap: Int64 = 480 // 20 ms at 24 kHz.
    private static let wordEdgeTolerance: Int64 = 1_440 // 60 ms. Acoustic edges only.
    private var voice: [VoicedSpan] = []
    private var lastVoicedFrameStart: Int64?
    private var commitRequests: [CommitRequest] = []
    private var lastCommitRequest: Int64 = 0
    private var inputState = InputState.open
    private var nextItem = 0
    private var partial: Partial?
    private var companions: [Companion] = []
    private var deferredDetails: [Detail] = []
    private var diarizedCommits: [Int: DiarizedCommit] = [:]
    private var lastSegmentIndex = -1
    private var speakerAliases: [Int: Int] = [:]
    private var lastFinalID: Int?
    private var finalRanges: [Range<Int64>] = []
    private var furthestFinalSample: Int64 = 0
    private var recentFinalTexts: [String] = []
    private var endpoint = AudioEndpoint()

    public init(apiKey: String, configuration: ElevenLabsSpeechConfiguration = .init()) {
        self.init(apiKey: apiKey, configuration: configuration, socket: { FoundationRealtimeSocket(request: $0) })
    }

    init(apiKey: String, configuration: ElevenLabsSpeechConfiguration,
         socket: @escaping @Sendable (URLRequest) -> any RealtimeSocket) {
        key = apiKey
        config = configuration
        makeSocket = socket
        behavior = .init(delivery: configuration.strategy == .manual ? .clientCommit : .providerCommit,
                         streamsSilence: true, requiresStreamEnd: true)
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        let request = try config.request(key: key)
        let socket = makeSocket(request)
        self.socket = socket
        let id = UUID()
        connectionID = id
        do {
            let expectedModel = config.model
            try await receiveReadiness(on: socket) { data in
                let event = try ElevenLabsWire.decode(data)
                guard event.message_type == "session_started" else { return false }
                guard event.session_id?.isEmpty == false, let config = event.config, config.model_id == expectedModel,
                      config.audio_format == "pcm_24000", config.sample_rate == 24_000 else {
                    throw ProviderFailure.malformedEvent
                }
                return true
            }
            guard connectionID == id else { throw CancellationError() }
        } catch {
            if connectionID == id { await close() }
            throw error
        }

        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.output = output
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await socket.read()
                    try Task.checkCancellation()
                    let message = try ElevenLabsWire.decode(data)
                    if try await self?.receive(message, source: source, epoch: epoch, connection: id) != true { return }
                }
            } catch {
                if !Task.isCancelled {
                    await self?.fail(error, source: source, epoch: epoch, connection: id)
                }
            }
        }
        output.onTermination = { _ in socket.close() }
        return stream
    }

    public func checkConnection() async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        try await socket.ping()
    }

    public func append(_ frame: AudioFrame) async throws {
        guard output != nil, inputState == .open else { throw ProviderFailure.disconnected }
        guard frame.sampleRate == behavior.sampleRate, !frame.pcm.isEmpty,
              frame.pcm.count.isMultiple(of: 2), frame.pcm.count <= 24_000 else { throw CaptureFailure.invalidFormat }
        if endpoint.observe(frame).level >= config.localActivityThreshold {
            let start = sentSamples + Int64(chunk.count / 2)
            let end = start + Int64(frame.pcm.count / 2)
            lastVoicedFrameStart = start
            if let last = voice.last, last.samples.upperBound == start, last.trailingEdge,
               start != lastCommitRequest {
                voice[voice.count - 1] = .init(samples: last.samples.lowerBound..<end, leadingEdge: last.leadingEdge)
            } else {
                guard voice.count < 4_096 else { throw CaptureFailure.bufferOverrun }
                voice.append(.init(samples: start..<end))
            }
        }
        chunk.append(frame.pcm)
        if chunk.count >= 4_800 { try await flush(commit: false) }
    }

    public func commit() async throws {
        guard output != nil, inputState == .open else { throw ProviderFailure.disconnected }
        try await requestCommit()
    }

    public func finishInput() async throws {
        guard inputState == .open else { return }
        guard let id = connectionID, output != nil else { throw ProviderFailure.disconnected }
        inputState = .flushing
        let hasUncommittedVoice = voice.last.map { $0.samples.upperBound > lastCommitRequest } ?? false
        if hasUncommittedVoice || (partial != nil && sentSamples + Int64(chunk.count / 2) > lastCommitRequest) {
            try await requestCommit()
        } else if !chunk.isEmpty {
            try await flush(commit: false)
        }
        try Task.checkCancellation()
        guard connectionID == id else { throw CancellationError() }
        guard output != nil else { return } // The transcript consumer receives any reader failure.
        inputState = .draining
        _ = finishDrainIfReady()
    }

    public func close() async {
        #if canImport(os)
        if inputState == .flushing || inputState == .draining {
            let samples = voice.reduce(0) { $0 + $1.samples.count }
            let mode = config.strategy.rawValue
            let hasPartial = partial != nil
            let companionCount = companions.count + deferredDetails.count + diarizedCommits.count
            Logger(subsystem: "com.mockinterview.desktop", category: "Scribe").notice(
                "Unconfirmed drain mode=\(mode, privacy: .public) voicedRanges=\(self.voice.count, privacy: .public) voicedSamples=\(samples, privacy: .public) commits=\(self.commitRequests.count, privacy: .public) partial=\(hasPartial, privacy: .public) companions=\(companionCount, privacy: .public)"
            )
        }
        #endif
        connectionID = nil
        let previous = reader
        reader = nil
        previous?.cancel()
        socket?.close()
        socket = nil
        output?.finish(throwing: CancellationError())
        output = nil
        chunk.removeAll()
        sentSamples = 0
        voice.removeAll()
        lastVoicedFrameStart = nil
        commitRequests.removeAll()
        lastCommitRequest = 0
        inputState = .open
        nextItem = 0
        partial = nil
        companions.removeAll()
        deferredDetails.removeAll()
        diarizedCommits.removeAll()
        lastSegmentIndex = -1
        speakerAliases.removeAll()
        lastFinalID = nil
        finalRanges.removeAll()
        furthestFinalSample = 0
        recentFinalTexts.removeAll()
        endpoint = AudioEndpoint()
        await previous?.value
    }

    private func requestCommit() async throws {
        let end = sentSamples + Int64(chunk.count / 2)
        guard end > lastCommitRequest else { return }
        guard commitRequests.count < 64 else { throw CaptureFailure.bufferOverrun }
        commitRequests.append(.init(samples: lastCommitRequest..<end))
        lastCommitRequest = end
        try await flush(commit: true)
    }

    private func flush(commit: Bool) async throws {
        try Task.checkCancellation()
        guard let socket, let id = connectionID else { throw ProviderFailure.disconnected }
        let bytes = chunk
        chunk.removeAll(keepingCapacity: true)
        // Register submitted samples before send suspends: the reader can receive a final first.
        sentSamples += Int64(bytes.count / 2)
        try await socket.send(ElevenLabsWire.chunk(bytes, commit: commit))
        try Task.checkCancellation()
        guard connectionID == id else { throw CancellationError() }
    }

    private func finishDrainIfReady() -> Bool {
        guard inputState == .draining, voice.isEmpty, commitRequests.isEmpty,
              partial == nil, companions.isEmpty, deferredDetails.isEmpty, diarizedCommits.isEmpty else { return false }
        inputState = .drained
        output?.finish()
        output = nil
        return true
    }

    private func fail(_ error: any Error, source: CaptureSource, epoch: UUID, connection: UUID) {
        guard connectionID == connection, let output else { return }
        for index in diarizedCommits.keys.sorted() {
            guard let commit = diarizedCommits[index] else { continue }
            try? emit(text: commit.text, partial: commit.partial, source: source, epoch: epoch, output: output)
        }
        diarizedCommits.removeAll()
        self.output = nil
        if let failure = error as? CaptureFailure { output.finish(throwing: failure) }
        else { output.finish(throwing: (error as? ProviderFailure) ?? .disconnected) }
    }

    private func receive(_ wire: ElevenLabsWire, source: CaptureSource, epoch: UUID, connection: UUID) throws -> Bool {
        guard !Task.isCancelled, connectionID == connection, let output else { return false }
        if config.diarize, wire.message_type != "partial_transcript" {
            try receiveDiarized(wire, source: source, epoch: epoch, output: output)
            return !finishDrainIfReady()
        }
        guard ["partial_transcript", "committed_transcript", "committed_transcript_with_timestamps"]
            .contains(wire.message_type) else { return true }
        guard let text = wire.text, text.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if wire.message_type == "partial_transcript" {
            let prediction = wire.turn_probability.flatMap { (0...1).contains($0) ? $0 : nil }
            if partial?.text == text {
                if let prediction { partial?.prediction = prediction }
                return true
            }
            var current = partial ?? Partial(id: allocateItem(), observedFrame: lastVoicedFrameStart,
                                              text: text, prediction: nil)
            current.text = text
            if let prediction { current.prediction = prediction }
            partial = current
            if case .dropped = output.yield(.init(source: source, epoch: epoch, itemID: "scribe-\(current.id)",
                                                text: text, state: .partial, turnProbability: current.prediction)) {
                throw CaptureFailure.bufferOverrun
            }
            return true
        }
        if wire.message_type == "committed_transcript" {
            // Plain and timestamped events describe the same segment, not two finals. Keep the
            // provisional boundary so a newer partial can arrive before the detailed companion.
            if recentFinalTexts.contains(where: { matches($0, text) }) || companions.contains(where: { matches($0.text, text) }) {
                guard matches(partial?.text, text) else { return true }
            }
            guard companions.count < 64 else { throw CaptureFailure.bufferOverrun }
            companions.append(.init(text: text, partial: partial, detail: nil))
            partial = nil
            return true
        }
        let words = (wire.words ?? []).prefix(1_024).filter { $0.type == nil || $0.type == "word" }
        guard let detail = timingDetail(text, language: wire.language_code, words: words), accepts(detail) else { return true }

        if let match = companions.firstIndex(where: { matches($0.text, text) }) {
            // A different segment's detailed result can wait behind the earlier plain boundary.
            guard companions[match].detail == nil else { return true }
            companions[match].detail = detail
            while let next = companions.first?.detail {
                guard accepts(next) else { companions[0].detail = nil; break }
                let candidate = companions.removeFirst().partial
                var resolved = candidate
                if let candidate, !canBelong(candidate, to: next) {
                    // A plain boundary is tentative: a late older result cannot take a newer partial.
                    if partial == nil { partial = candidate }
                    resolved = nil
                }
                if resolved == nil { resolved = takeMatchingPartial(for: next) }
                try finalize(next, partial: resolved, source: source, epoch: epoch, output: output)
            }
            if companions.isEmpty {
                let waiting = deferredDetails.sorted { $0.samples.lowerBound < $1.samples.lowerBound }
                deferredDetails.removeAll()
                for next in waiting where accepts(next) {
                    try finalize(next, partial: takeMatchingPartial(for: next), source: source, epoch: epoch, output: output)
                }
            }
        } else if companions.isEmpty {
            try finalize(detail, partial: takeMatchingPartial(for: detail), source: source, epoch: epoch, output: output)
        } else if !deferredDetails.contains(where: { $0.samples == detail.samples }) {
            // Some finals arrive without the plain companion. Retain the position until
            // earlier plain boundaries are resolved instead of dropping the later segment.
            guard deferredDetails.count < 64 else { throw CaptureFailure.bufferOverrun }
            deferredDetails.append(detail)
        }
        return !finishDrainIfReady()
    }

    private func receiveDiarized(_ wire: ElevenLabsWire, source: CaptureSource, epoch: UUID,
                                 output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) throws {
        switch wire.message_type {
        case "committed_transcript":
            guard let index = wire.segment_index, index >= 0,
                  let text = wire.text, text.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
            guard index > lastSegmentIndex else { return }
            lastSegmentIndex = index
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard diarizedCommits.count < 64 else { throw CaptureFailure.bufferOverrun }
            let boundary = partial ?? Partial(id: allocateItem(), observedFrame: lastVoicedFrameStart, text: text)
            partial = nil
            diarizedCommits[index] = .init(text: text, partial: boundary)
            // Show the stable text while waiting for its indexed speaker evidence.
            if case .dropped = output.yield(.init(source: source, epoch: epoch, itemID: "scribe-\(boundary.id)",
                                                text: text, state: .partial)) { throw CaptureFailure.bufferOverrun }
        case "diarized_transcript":
            guard let index = wire.segment_index, let commit = diarizedCommits.removeValue(forKey: index) else { return }
            if wire.text == commit.text, let words = wire.words, words.count <= 1_024 {
                let lexical = words.filter { $0.type == "word" || ($0.type == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                if let detail = timingDetail(commit.text, language: wire.language_code, words: lexical), accepts(detail) {
                    let speaker = canonicalSpeaker(lexical.first?.speaker_id)
                    let labeledText = lexical.map(\.text).joined()
                    let oneSpeaker = speaker != nil && lexical.allSatisfy { canonicalSpeaker($0.speaker_id) == speaker }
                        && labeledText.filter { $0.isLetter || $0.isNumber } == commit.text.filter { $0.isLetter || $0.isNumber }
                    try finalize(detail, partial: commit.partial, source: source, epoch: epoch, output: output,
                                 speaker: oneSpeaker ? speaker : nil)
                    return
                }
            }
            try emit(text: commit.text, partial: commit.partial, source: source, epoch: epoch, output: output)
        case "speakers_merged":
            guard let from = canonicalSpeaker(wire.from_speaker_id), let to = canonicalSpeaker(wire.to_speaker_id) else {
                throw ProviderFailure.malformedEvent
            }
            guard from != to else { return }
            guard speakerAliases.count < 256 else { throw CaptureFailure.bufferOverrun }
            speakerAliases[from] = to
            if case .dropped = output.yield(.init(source: source, epoch: epoch, itemID: "scribe-merge-\(from)-\(to)",
                                                text: "", state: .speakerMerge(from: from, to: to))) {
                throw CaptureFailure.bufferOverrun
            }
        default: break
        }
    }

    private func canonicalSpeaker(_ id: String?) -> Int? {
        guard let id, id.hasPrefix("speaker_"), let number = Int(id.dropFirst(8)), number >= 0 else { return nil }
        var current = number
        while let next = speakerAliases[current] { current = next }
        return current
    }

    private func timingDetail(_ text: String, language: String?, words: some BidirectionalCollection<ElevenLabsWire.Word>) -> Detail? {
        // Unpositioned or empty results cannot resolve submitted audio or pending commits.
        guard let start = words.first?.start, let end = words.last?.end,
              start.isFinite, end.isFinite, start >= 0, end > start, end <= Double(sentSamples) / 24_000,
              let first = Int64(exactly: (start * 24_000).rounded()),
              let last = Int64(exactly: (end * 24_000).rounded()), first < last else { return nil }
        let normalized = words.map { TranscriptWord(text: $0.text, startSeconds: $0.start, endSeconds: $0.end) }
        return Detail(text: text, words: normalized, language: language,
                      range: .init(startSeconds: start, endSeconds: end), samples: first..<last)
    }

    private func accepts(_ detail: Detail) -> Bool {
        let range = detail.samples
        guard !finalRanges.contains(range) else { return false }
        // Older results can resolve gaps. Once their audio is accounted for, a replay cannot
        // create a new item even if its exact fingerprint has aged out of the bounded cache.
        return range.upperBound > furthestFinalSample || voice.contains(where: { $0.samples.overlaps(range) })
            || commitRequests.contains { !$0.receivedFinal && Self.confirms($0.samples, with: range) }
    }

    private func canBelong(_ partial: Partial, to detail: Detail) -> Bool {
        partial.observedFrame.map { $0 < detail.samples.upperBound } ?? true
    }

    private func takeMatchingPartial(for detail: Detail) -> Partial? {
        guard let current = partial, matches(current.text, detail.text), canBelong(current, to: detail) else { return nil }
        partial = nil
        return current
    }

    private func finalize(_ detail: Detail, partial: Partial?, source: CaptureSource, epoch: UUID,
                          output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation, speaker: Int? = nil) throws {
        let range = detail.samples
        voice = voice.flatMap { Self.subtract(range, from: $0) }
        guard voice.count <= 4_096 else { throw CaptureFailure.bufferOverrun }
        for index in commitRequests.indices where Self.confirms(commitRequests[index].samples, with: range) {
            commitRequests[index].receivedFinal = true
        }
        commitRequests.removeAll { request in
            request.receivedFinal && !voice.contains(where: { $0.samples.overlaps(request.samples) })
        }

        furthestFinalSample = max(furthestFinalSample, range.upperBound)
        if finalRanges.count == 256 { finalRanges.removeFirst() }
        finalRanges.append(range)
        if recentFinalTexts.count == 32 { recentFinalTexts.removeFirst() }
        recentFinalTexts.append(detail.text)
        try emit(text: detail.text, partial: partial, source: source, epoch: epoch, output: output, detail: detail,
                 speaker: speaker)
    }

    private func emit(text: String, partial: Partial?, source: CaptureSource, epoch: UUID,
                      output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation,
                      detail: Detail? = nil, speaker: Int? = nil) throws {
        let item = partial?.id ?? allocateItem()
        let event = TranscriptEvent(source: source, epoch: epoch, itemID: "scribe-\(item)",
                                    previousItemID: lastFinalID.map { "scribe-\($0)" }, text: text, state: .final,
                                    speaker: speaker, words: detail?.words ?? [], language: detail?.language,
                                    turnProbability: partial?.prediction, audioRange: detail?.range)
        lastFinalID = item
        if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
    }

    private static func subtract(_ covered: Range<Int64>, from pending: VoicedSpan) -> [VoicedSpan] {
        let samples = pending.samples
        guard samples.overlaps(covered) else { return [pending] }
        let start = max(samples.lowerBound, covered.lowerBound)
        let end = min(samples.upperBound, covered.upperBound)
        // Word timestamps can omit onset and decay. Allow tolerance only against an
        // original acoustic edge, never against a boundary cut by another final.
        let half = (samples.upperBound - samples.lowerBound + 1) / 2
        let anchored = end - start >= half
        let handoff = end - start >= min(minimumCommitOverlap, half) ? minimumCommitOverlap : 0
        let leading = anchored && pending.leadingEdge ? wordEdgeTolerance : handoff
        let trailing = anchored && pending.trailingEdge ? wordEdgeTolerance : handoff
        var remaining: [VoicedSpan] = []
        if start - samples.lowerBound > leading {
            remaining.append(.init(samples: samples.lowerBound..<start, leadingEdge: pending.leadingEdge, trailingEdge: false))
        }
        if samples.upperBound - end > trailing {
            remaining.append(.init(samples: end..<samples.upperBound, leadingEdge: false, trailingEdge: pending.trailingEdge))
        }
        return remaining
    }

    private static func confirms(_ request: Range<Int64>, with result: Range<Int64>) -> Bool {
        let overlap = min(request.upperBound, result.upperBound) - max(request.lowerBound, result.lowerBound)
        return overlap >= min(minimumCommitOverlap, (result.upperBound - result.lowerBound + 1) / 2)
    }

    private func allocateItem() -> Int {
        defer { nextItem += 1 }
        return nextItem
    }

    private func matches(_ partial: String?, _ final: String) -> Bool {
        guard let partial else { return false }
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        return partial.trimmingCharacters(in: punctuation).caseInsensitiveCompare(final.trimmingCharacters(in: punctuation)) == .orderedSame
    }
}
