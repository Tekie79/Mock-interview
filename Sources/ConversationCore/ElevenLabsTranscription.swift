import Foundation
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

    public init(model: String = "scribe_v3_live", language: String? = nil, detectLanguage: Bool = true,
                strategy: TranscriptionCommitStrategy = .semanticTurn, silenceSeconds: Double = 0.65,
                vocabulary: [String] = []) {
        self.model = model
        self.language = language
        self.detectLanguage = detectLanguage
        self.strategy = strategy
        self.silenceSeconds = silenceSeconds
        self.vocabulary = vocabulary
    }

    func request(key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw ProviderFailure.missingCredentials }
        let capabilities = ProviderCapabilities.describe(.elevenLabs, model: model)
        guard capabilities.models.contains(model), capabilities.commits.contains(strategy),
              silenceSeconds.isFinite, (0.192...3).contains(silenceSeconds) else {
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
            .init(name: "include_timestamps", value: "true"),
            .init(name: "include_language_detection", value: detectLanguage ? "true" : "false"),
            .init(name: "vad_silence_threshold_secs", value: String(silenceSeconds)),
            .init(name: "enable_logging", value: "false")
        ]
        if let language, !language.isEmpty { parts.queryItems?.append(.init(name: "language_code", value: language)) }
        for word in vocabulary.prefix(25) where !word.isEmpty {
            parts.queryItems?.append(.init(name: "keyterms", value: String(word.prefix(32))))
        }
        guard let url = parts.url else { throw ProviderFailure.requestRejected }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }
}

struct ElevenLabsWire: Decodable, Sendable {
    struct Word: Decodable, Sendable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String?
    }

    let message_type: String
    let session_id: String?
    let text: String?
    let language_code: String?
    let turn_probability: Double?
    let words: [Word]?

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
        case "session_time_limit_exceeded", "resource_exhausted", "transcriber_error", "error":
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
    public nonisolated let behavior: TranscriptionBehavior
    private let key: String
    private let config: ElevenLabsSpeechConfiguration
    private let makeSocket: @Sendable (URLRequest) -> any RealtimeSocket
    private var socket: (any RealtimeSocket)?
    private var connectionID: UUID?
    private var reader: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var chunk = Data()
    private var nextItem = 0
    private var partial = ""
    private var prediction: Double?
    private var lastCommit: (range: ClosedRange<Double>, text: String)?
    private var finishing = false
    private var speechSeen = false
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
                         streamsSilence: true)
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        let request = try config.request(key: key)
        let socket = makeSocket(request)
        self.socket = socket
        let id = UUID()
        connectionID = id
        do {
            try await receiveReadiness(on: socket) { data in
                let event = try ElevenLabsWire.decode(data)
                guard event.message_type == "session_started" else { return false }
                guard event.session_id?.isEmpty == false else { throw ProviderFailure.malformedEvent }
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
                    let message = try ElevenLabsWire.decode(data)
                    if try await self?.receive(message, source: source, epoch: epoch, connection: id) != true { return }
                }
            } catch {
                if !Task.isCancelled {
                    if let failure = error as? CaptureFailure { output.finish(throwing: failure) }
                    else { output.finish(throwing: (error as? ProviderFailure) ?? .disconnected) }
                }
            }
        }
        output.onTermination = { _ in socket.close() }
        return stream
    }

    public func append(_ frame: AudioFrame) async throws {
        guard !finishing, frame.sampleRate == behavior.sampleRate, !frame.pcm.isEmpty,
              frame.pcm.count.isMultiple(of: 2), frame.pcm.count <= 24_000 else { throw CaptureFailure.invalidFormat }
        if endpoint.observe(frame).level >= 0.015 { speechSeen = true }
        chunk.append(frame.pcm)
        if chunk.count >= 4_800 { try await flush(commit: false) }
    }

    public func commit() async throws { try await flush(commit: true) }

    public func finishInput() async throws {
        if config.strategy == .manual { return }
        finishing = true
        if speechSeen || !partial.isEmpty {
            try await flush(commit: true)
        } else {
            if !chunk.isEmpty { try await flush(commit: false) }
            output?.finish()
        }
    }

    public func close() async {
        connectionID = nil
        let previous = reader
        reader = nil
        previous?.cancel()
        socket?.close()
        socket = nil
        output?.finish()
        output = nil
        chunk.removeAll()
        nextItem = 0
        partial = ""
        prediction = nil
        lastCommit = nil
        finishing = false
        speechSeen = false
        endpoint = AudioEndpoint()
        await previous?.value
    }

    private func flush(commit: Bool) async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        let bytes = chunk
        chunk.removeAll(keepingCapacity: true)
        try await socket.send(ElevenLabsWire.chunk(bytes, commit: commit))
    }

    private func receive(_ wire: ElevenLabsWire, source: CaptureSource, epoch: UUID, connection: UUID) throws -> Bool {
        guard connectionID == connection, let output else { return false }
        let item = "scribe-\(nextItem)"
        if wire.message_type == "partial_transcript" {
            guard let text = wire.text else { throw ProviderFailure.malformedEvent }
            guard text.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
            if let score = wire.turn_probability, (0...1).contains(score) { prediction = score }
            guard !text.isEmpty, text != partial else { return true }
            partial = text
            if case .dropped = output.yield(.init(source: source, epoch: epoch, itemID: item,
                                                text: text, state: .partial, turnProbability: prediction)) {
                throw CaptureFailure.bufferOverrun
            }
            return true
        }
        if wire.message_type == "insufficient_audio_activity" {
            if finishing { output.finish(); return false }
            if config.strategy == .manual {
                nextItem += 1
                partial = ""
                prediction = nil
                if case .dropped = output.yield(.init(source: source, epoch: epoch, itemID: item,
                                                       text: "", state: .final)) {
                    throw CaptureFailure.bufferOverrun
                }
            }
            return true
        }
        // With timestamps enabled the plain commit is superseded by its detailed companion event.
        guard wire.message_type == "committed_transcript_with_timestamps" else { return true }
        guard let text = wire.text, text.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
        let words = (wire.words ?? []).prefix(1_024).filter { $0.type == nil || $0.type == "word" }.map {
            TranscriptWord(text: $0.text, startSeconds: $0.start, endSeconds: $0.end)
        }
        if let start = words.first?.startSeconds, let end = words.last?.endSeconds, start <= end {
            let range = start...end
            if let previous = lastCommit, range == previous.range, text == previous.text, partial.isEmpty {
                return true
            }
            lastCommit = (range, text)
        }
        let event = TranscriptEvent(source: source, epoch: epoch, itemID: item,
                                    previousItemID: nextItem > 0 ? "scribe-\(nextItem - 1)" : nil,
                                    text: text, state: .final, words: words,
                                    language: wire.language_code, turnProbability: prediction)
        nextItem += 1
        partial = ""
        prediction = nil
        speechSeen = false
        if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
        if finishing { output.finish(); return false }
        return true
    }
}
