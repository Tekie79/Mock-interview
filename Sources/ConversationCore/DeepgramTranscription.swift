import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepgramTranscriptAssembler {
    private struct Result: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable { let speaker: Int? }
                let transcript: String
                let words: [Word]?
            }
            let alternatives: [Alternative]
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
        let segment = Segment(text: text, speaker: speaker)
        let boundary = result.speech_final == true || result.from_finalize == true
        if result.is_final == true, !text.isEmpty {
            finalized[start] = segment
        }
        guard finalized.count <= 64 else { throw ProviderFailure.disconnected }
        var accumulated = finalized
        if result.is_final != true, !text.isEmpty { accumulated[start] = segment }
        let ordered = accumulated.sorted(by: { $0.key < $1.key }).map(\.value)
        let combined = ordered.map(\.text).joined(separator: " ")
        let soleSpeaker = ordered.first?.speaker
        let resolved = ordered.allSatisfy { $0.speaker == soleSpeaker } ? soleSpeaker : nil
        let id = "deepgram-\(utterance)"
        if boundary {
            completedThrough = start + duration
            utterance += 1
            finalized.removeAll(keepingCapacity: true)
        }
        guard !combined.isEmpty else { return nil }
        return TranscriptEvent(source: source, epoch: epoch, itemID: id, text: combined,
                               state: boundary ? .final : .partial, speaker: boundary ? resolved : nil)
    }
}

public actor DeepgramTranscriber: StreamingSTT {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let diarize: Bool
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?

    public init(apiKey: String, model: String = "nova-3", language: String? = nil, diarize: Bool = false) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.diarize = diarize
    }

    static func request(apiKey: String, model: String, language: String?, diarize: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ProviderFailure.missingCredentials }
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
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        if diarize { components.queryItems?.append(.init(name: "diarize_model", value: "v1")) }
        if let language, !language.isEmpty { components.queryItems?.append(.init(name: "language", value: language)) }
        guard !model.isEmpty, let url = components.url else { throw ProviderFailure.requestRejected }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Token " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        let request = try Self.request(apiKey: apiKey, model: model, language: language, diarize: diarize)
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
                    if let event = try assembler.receive(bytes), case .dropped = output.yield(event) {
                        throw CaptureFailure.bufferOverrun
                    }
                }
                output.finish()
            } catch {
                if Task.isCancelled { output.finish() }
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
