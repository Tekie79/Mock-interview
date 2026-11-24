import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderFailure: Error, Equatable, Sendable {
    case missingCredentials
    case authentication
    case rateLimited
    case requestRejected
    case unavailable
    case malformedEvent
    case disconnected
    case timeout
}

public enum OpenAIRealtimeWire {
    public static func session(model: String, language: String?) throws -> String {
        var transcription = ["model": model]
        if let language, !language.isEmpty { transcription["language"] = language }
        if model == "gpt-live-transcribe" { transcription["delay"] = "low" }
        return try encode([
            "type": "session.update",
            "session": ["type": "transcription", "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24_000],
                "transcription": transcription,
                "turn_detection": NSNull()
            ]]]
        ])
    }

    public static func append(_ pcm: Data) throws -> String {
        try encode(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    public static let commit = #"{"type":"input_audio_buffer.commit"}"#

    private static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

public struct OpenAITranscriptAssembler {
    private struct Event: Decodable {
        let type: String
        let event_id: String?
        let item_id: String?
        let previous_item_id: String?
        let delta: String?
        let transcript: String?
        let error: ServiceError?
    }

    private struct ServiceError: Decodable {
        let code: String?
        let type: String?
    }

    private struct Item {
        var previous: String?
        var committed = false
        var partial = ""
        var final: String?
    }

    private let source: CaptureSource
    private let epoch: UUID
    private var items: [String: Item] = [:]
    private var lastPublished: String?
    private var delivered: Set<String> = []
    private var seenEventIDs: Set<String> = []

    public init(source: CaptureSource, epoch: UUID) {
        self.source = source
        self.epoch = epoch
    }

    public mutating func receive(_ data: Data) throws -> [TranscriptEvent] {
        guard let message = try? JSONDecoder().decode(Event.self, from: data) else {
            throw ProviderFailure.malformedEvent
        }
        if message.type == "error" {
            switch message.error?.code ?? message.error?.type {
            case "invalid_api_key", "authentication_error": throw ProviderFailure.authentication
            case "rate_limit_exceeded", "rate_limit_error": throw ProviderFailure.rateLimited
            default: throw ProviderFailure.requestRejected
            }
        }
        if message.type == "conversation.item.input_audio_transcription.failed" {
            throw ProviderFailure.unavailable
        }
        guard ["input_audio_buffer.committed", "conversation.item.input_audio_transcription.delta",
               "conversation.item.input_audio_transcription.completed"].contains(message.type) else { return [] }
        guard let itemID = message.item_id, !itemID.isEmpty else { throw ProviderFailure.malformedEvent }
        guard !delivered.contains(itemID) else { return [] }
        if let eventID = message.event_id, !seenEventIDs.insert(eventID).inserted { return [] }
        // Fail closed if provider fragments the stream without completing earlier items.
        guard items.count < 128 || items[itemID] != nil else { throw ProviderFailure.disconnected }
        var item = items[itemID, default: Item()]
        switch message.type {
        case "input_audio_buffer.committed":
            item.previous = message.previous_item_id
            item.committed = true
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = message.delta else { throw ProviderFailure.malformedEvent }
            guard item.final == nil else { return [] }
            item.partial += delta
            guard item.partial.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
            items[itemID] = item
            return [normalize(itemID, item, text: item.partial, state: .partial)]
        default:
            guard let transcript = message.transcript, transcript.utf8.count <= 32_768 else {
                throw ProviderFailure.malformedEvent
            }
            if item.final != nil { return [] }
            item.final = transcript
        }
        items[itemID] = item
        var output: [TranscriptEvent] = []
        while let next = items.first(where: { $0.value.committed && $0.value.previous == lastPublished }),
              let final = next.value.final {
            lastPublished = next.key
            items.removeValue(forKey: next.key)
            delivered.insert(next.key)
            output.append(normalize(next.key, next.value, text: final, state: .final))
        }
        if seenEventIDs.count > 65_536 || delivered.count > 16_384 {
            throw ProviderFailure.disconnected
        }
        return output
    }

    private func normalize(_ id: String, _ item: Item, text: String, state: TranscriptEvent.State) -> TranscriptEvent {
        TranscriptEvent(source: source, epoch: epoch, itemID: id, previousItemID: item.previous,
                        text: text, state: state)
    }
}

public actor OpenAIRealtimeTranscriber: StreamingSTT {
    private let apiKey: String
    private let model: String
    private let language: String?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?

    public init(apiKey: String, model: String = "gpt-live-transcribe", language: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        guard !apiKey.isEmpty else { throw ProviderFailure.missingCredentials }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw ProviderFailure.requestRejected
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        let handshakeTimeout = Task {
            do {
                try await Task.sleep(for: .seconds(15))
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer { handshakeTimeout.cancel() }
        socket.resume()
        var assembler = OpenAITranscriptAssembler(source: source, epoch: epoch)
        do {
            try await withTaskCancellationHandler {
                try await socket.send(.string(OpenAIRealtimeWire.session(model: model, language: language)))
                while true {
                    let data = try await Self.data(from: socket.receive())
                    if Self.isAcknowledgement(data) { break }
                    _ = try assembler.receive(data)
                }
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
            guard self.socket === socket else { throw CancellationError() }
        } catch {
            if self.socket === socket { self.socket = nil }
            socket.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            switch (socket.response as? HTTPURLResponse)?.statusCode {
            case 401, 403: throw ProviderFailure.authentication
            case 429: throw ProviderFailure.rateLimited
            default: throw (error as? ProviderFailure) ?? ProviderFailure.disconnected
            }
        }
        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        reader = Task.detached {
            do {
                var state = assembler
                while !Task.isCancelled {
                    for event in try state.receive(await Self.data(from: socket.receive())) {
                        if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
                    }
                }
                output.finish()
            } catch {
                output.finish(throwing: Task.isCancelled ? nil : ((error as? ProviderFailure) ?? .disconnected))
            }
        }
        output.onTermination = { _ in socket.cancel(with: .goingAway, reason: nil) }
        return events
    }

    public func append(_ frame: AudioFrame) async throws {
        guard frame.sampleRate == 24_000, frame.pcm.count.isMultiple(of: 2) else {
            throw CaptureFailure.invalidFormat
        }
        try await send(OpenAIRealtimeWire.append(frame.pcm))
    }

    public func commit() async throws {
        try await send(OpenAIRealtimeWire.commit)
    }

    public func close() async {
        let oldReader = reader
        reader = nil
        oldReader?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        await oldReader?.value
    }

    private func send(_ message: String) async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        do {
            try await socket.send(.string(message))
        } catch {
            throw ProviderFailure.disconnected
        }
    }

    private static func isAcknowledgement(_ data: Data) -> Bool {
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?["type"] as? String == "session.updated"
    }

    private static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw ProviderFailure.malformedEvent
        }
    }
}
