import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepgramTranscriptAssembler {
    private struct Result: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable {
                    let speaker: Int?
                    let word: String?
                    let punctuated_word: String?
                    let start: Double?
                    let end: Double?
                }
                let transcript: String
                let words: [Word]?
            }
            let alternatives: [Alternative]
            let detected_language: String?
        }
        let type: String
        let start: Double?
        let duration: Double?
        let is_final: Bool?
        let speech_final: Bool?
        let from_finalize: Bool?
        let channel: Channel?
    }

    private let source: CaptureSource
    private let epoch: UUID
    private struct Segment {
        let text: String
        let speaker: Int?
        let words: [TranscriptWord]
    }

    private var finalized: [Double: Segment] = [:]
    private var completedThrough: Double = 0
    private var utterance = 0

    public init(source: CaptureSource, epoch: UUID) {
        self.source = source
        self.epoch = epoch
    }

    public mutating func receive(_ bytes: Data) throws -> TranscriptEvent? {
        guard let result = try? JSONDecoder().decode(Result.self, from: bytes) else {
            throw ProviderFailure.malformedEvent
        }
        if result.type == "Error" { throw ProviderFailure.requestRejected }
        guard result.type == "Results" else { return nil }
        guard let start = result.start, let duration = result.duration, start >= 0, duration >= 0,
              let alternative = result.channel?.alternatives.first,
              alternative.transcript.utf8.count <= 32_768 else {
            throw ProviderFailure.malformedEvent
        }
        guard start + duration > completedThrough else { return nil }
        let text = alternative.transcript
        let speaker: Int?
        if let words = alternative.words, let first = words.first?.speaker, first >= 0,
           words.allSatisfy({ $0.speaker == first }) {
            speaker = first
        } else {
            speaker = nil
        }
        let words = (alternative.words ?? []).prefix(1_024).compactMap { word -> TranscriptWord? in
            guard let text = word.punctuated_word ?? word.word else { return nil }
            return .init(text: text, startSeconds: word.start, endSeconds: word.end, speaker: word.speaker)
        }
        let segment = Segment(text: text, speaker: speaker, words: words)
        let boundary = result.is_final == true && (result.speech_final == true || result.from_finalize == true)
        if result.is_final == true, !text.isEmpty {
            finalized[start] = segment
        }
        guard finalized.count <= 64 else { throw ProviderFailure.disconnected }
        var accumulated = finalized
        if result.is_final != true, !text.isEmpty { accumulated[start] = segment }
        let event = combined(accumulated, final: boundary, language: result.channel?.detected_language)
        if boundary {
            completedThrough = start + duration
            utterance += 1
            finalized.removeAll(keepingCapacity: true)
        }
        return event
    }
    mutating func drain() -> TranscriptEvent? {
        let event = combined(finalized, final: true, language: nil)
        finalized.removeAll()
        return event
    }

    private func combined(_ segments: [Double: Segment], final: Bool, language: String?) -> TranscriptEvent? {
        let ordered = segments.sorted(by: { $0.key < $1.key }).map(\.value)
        let text = ordered.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let soleSpeaker = ordered.first?.speaker
        let speaker = final && ordered.allSatisfy { $0.speaker == soleSpeaker } ? soleSpeaker : nil
        return TranscriptEvent(source: source, epoch: epoch, itemID: "deepgram-\(utterance)", text: text,
                               state: final ? .final : .partial, speaker: speaker,
                               words: Array(ordered.flatMap(\.words).prefix(1_024)), language: language)
    }

    static func isStreamSummary(_ bytes: Data) -> Bool {
        (try? JSONDecoder().decode(Result.self, from: bytes))?.type == "Metadata"
    }

}

public actor DeepgramTranscriber: StreamingSTT {
    public nonisolated let behavior = TranscriptionBehavior(delivery: .providerCommit, streamsSilence: true)
    private let apiKey: String
    private let model: String
    private let language: String?
    private let diarize: Bool
    private let endpointMilliseconds: Int
    private let vocabulary: [String]
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?

    public init(apiKey: String, model: String = "nova-3", language: String? = nil, diarize: Bool = false,
                endpointMilliseconds: Int = 300, vocabulary: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.diarize = diarize
        self.endpointMilliseconds = endpointMilliseconds
        self.vocabulary = vocabulary
    }

    static func request(apiKey: String, model: String, language: String?, diarize: Bool = false,
                        endpointMilliseconds: Int = 300, vocabulary: [String] = []) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ProviderFailure.missingCredentials }
        guard (100...3_000).contains(endpointMilliseconds),
              !diarize || ProviderCapabilities.describe(.deepgram, model: model).diarization else {
            throw ProviderFailure.unsupportedCapability
        }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "24000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointMilliseconds)),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        if diarize { components.queryItems?.append(.init(name: "diarize_model", value: "v1")) }
        for term in vocabulary.prefix(25) where !term.isEmpty {
            if model.hasPrefix("nova-3") {
                components.queryItems?.append(.init(name: "keyterm", value: String(term.prefix(32))))
            } else if model.hasPrefix("nova-2") {
                components.queryItems?.append(.init(name: "keywords", value: String(term.prefix(32))))
            }
        }
        if let language, !language.isEmpty { components.queryItems?.append(.init(name: "language", value: language)) }
        guard !model.isEmpty, let url = components.url else { throw ProviderFailure.requestRejected }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Token " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        let request = try Self.request(apiKey: apiKey, model: model, language: language, diarize: diarize,
                                       endpointMilliseconds: endpointMilliseconds, vocabulary: vocabulary)
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(12))
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await socket.send(.string(Self.keepAliveMessage))
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
            guard self.socket === socket else { throw CancellationError() }
        } catch {
            if self.socket === socket { self.socket = nil }
            socket.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let response = socket.response { try OpenAIResponsesClient.validate(response) }
            throw ProviderFailure.disconnected
        }

        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        reader = Task.detached {
            var assembler = DeepgramTranscriptAssembler(source: source, epoch: epoch)
            do {
                while !Task.isCancelled {
                    let bytes: Data
                    switch try await socket.receive() {
                    case .data(let data): bytes = data
                    case .string(let text): bytes = Data(text.utf8)
                    @unknown default: throw ProviderFailure.malformedEvent
                    }
                    if DeepgramTranscriptAssembler.isStreamSummary(bytes) {
                        if let event = assembler.drain(), case .dropped = output.yield(event) {
                            throw CaptureFailure.bufferOverrun
                        }
                        output.finish()
                        return
                    }
                    if let event = try assembler.receive(bytes), case .dropped = output.yield(event) {
                        throw CaptureFailure.bufferOverrun
                    }
                }
                output.finish()
            } catch {
                if Task.isCancelled { output.finish() }
                else if let error = error as? CaptureFailure { output.finish(throwing: error) }
                else { output.finish(throwing: (error as? ProviderFailure) ?? .disconnected) }
            }
        }
        keepAlive = Task.detached {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    try await socket.send(.string(Self.keepAliveMessage))
                }
            } catch where !Task.isCancelled {
                output.finish(throwing: ProviderFailure.disconnected)
            } catch {}
        }
        output.onTermination = { _ in socket.cancel(with: .goingAway, reason: nil) }
        return events
    }

    public func append(_ frame: AudioFrame) async throws {
        guard frame.sampleRate == 24_000, frame.pcm.count.isMultiple(of: 2) else {
            throw CaptureFailure.invalidFormat
        }
        try await send(.data(frame.pcm))
    }

    public func commit() async throws {
        try await send(.string(#"{"type":"Finalize"}"#))
    }

    public func finishInput() async throws {
        keepAlive?.cancel()
        try await send(.string(#"{"type":"CloseStream"}"#))
    }

    public func close() async {
        let oldReader = reader
        let oldKeepAlive = keepAlive
        reader = nil
        keepAlive = nil
        oldReader?.cancel()
        oldKeepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        await oldReader?.value
        await oldKeepAlive?.value
    }

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        do {
            try await withTaskCancellationHandler {
                try await socket.send(message)
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            try Task.checkCancellation()
            throw ProviderFailure.disconnected
        }
    }

    private static let keepAliveMessage = #"{"type":"KeepAlive"}"#
}
