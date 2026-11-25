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
    case incompleteTranscription
    case unsupportedCapability
    case quotaExhausted
}

public enum OpenAIRealtimeWire {
    public static func session(model: String, language: String?, vocabulary: [String] = []) throws -> String {
        guard ProviderCapabilities.describe(.openai, model: model).supports(.transcription) else {
            throw ProviderFailure.unsupportedCapability
        }
        var transcription: [String: Any] = ["model": model]
        let keywordModel = ProviderCapabilities.openAIKeywordModels.contains(model)
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !language.isEmpty {
            let pattern = keywordModel ? #"\A(?:[a-z]{2,3}|zh-(?:cn|tw|hk))\z"# : #"\A[a-z]{2}\z"#
            guard language.range(of: pattern, options: .regularExpression) != nil else {
                throw ProviderFailure.unsupportedCapability
            }
            if keywordModel { transcription["languages"] = [language] }
            else { transcription["language"] = language }
        }
        if model == "gpt-live-transcribe" { transcription["delay"] = "low" }
        let terms = vocabulary.lazy.filter { $0.rangeOfCharacter(from: .newlines.union(.init(charactersIn: "<>"))) == nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .prefix(25).map { String($0.prefix(48)) }
        if !terms.isEmpty {
            if keywordModel { transcription["keywords"] = Array(terms) }
            else if ProviderCapabilities.openAIPromptModels.contains(model) {
                transcription["prompt"] = terms.joined(separator: ", ")
            }
        }
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
        struct Language: Decodable { let code: String }
        struct Usage: Decodable {
            let type: String
            let seconds: Double?
            let input_tokens: Int?
            let output_tokens: Int?

            var normalized: RecognitionUsage? {
                switch type {
                case "duration":
                    guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
                    return .audioSeconds(seconds)
                case "tokens":
                    guard let input_tokens, let output_tokens, input_tokens >= 0, output_tokens >= 0 else { return nil }
                    return .tokens(.init(input: input_tokens, output: output_tokens))
                default: return nil
                }
            }
        }
        let type: String
        let event_id: String?
        let item_id: String?
        let previous_item_id: String?
        let content_index: Int?
        let delta: String?
        let transcript: String?
        let languages: [Language]?
        let usage: Usage?
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
        var language: String?
        var usage: RecognitionUsage?
    }

    private let source: CaptureSource
    private let epoch: UUID
    private let replacementPartials: Bool
    private var items: [String: Item] = [:]
    private var lastPublished: String?
    private var delivered: Set<String> = []
    private var seenEventIDs: Set<String> = []

    public init(source: CaptureSource, epoch: UUID, replacementPartials: Bool = false) {
        self.source = source
        self.epoch = epoch
        self.replacementPartials = replacementPartials
    }

    public mutating func receive(_ data: Data) throws -> [TranscriptEvent] {
        guard let message = try? JSONDecoder().decode(Event.self, from: data) else {
            throw ProviderFailure.malformedEvent
        }
        if message.type == "error" {
            let labels = Set([message.error?.code, message.error?.type].compactMap { $0 })
            if !labels.isDisjoint(with: ["invalid_api_key", "authentication_error"]) { throw ProviderFailure.authentication }
            if !labels.isDisjoint(with: ["rate_limit_exceeded", "rate_limit_error"]) { throw ProviderFailure.rateLimited }
            if labels.contains("insufficient_quota") { throw ProviderFailure.quotaExhausted }
            throw ProviderFailure.requestRejected
        }
        if message.type == "conversation.item.input_audio_transcription.failed" {
            throw ProviderFailure.unavailable
        }
        guard ["input_audio_buffer.committed", "conversation.item.input_audio_transcription.delta",
               "conversation.item.input_audio_transcription.completed"].contains(message.type) else { return [] }
        // Each client commit creates exactly one audio content part.
        if let index = message.content_index, index != 0 { return [] }
        guard let itemID = message.item_id, !itemID.isEmpty else { throw ProviderFailure.malformedEvent }
        guard !delivered.contains(itemID) else { return [] }
        if let eventID = message.event_id {
            guard seenEventIDs.count < 65_536 else { throw ProviderFailure.disconnected }
            if !seenEventIDs.insert(eventID).inserted { return [] }
        }
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
            if replacementPartials { item.partial = delta } else { item.partial += delta }
            guard item.partial.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
            items[itemID] = item
            return [normalize(itemID, item, text: item.partial, state: .partial)]
        default:
            guard let transcript = message.transcript, transcript.utf8.count <= 32_768 else {
                throw ProviderFailure.malformedEvent
            }
            if item.final != nil { return [] }
            item.final = transcript
            item.usage = message.usage?.normalized
            if let languages = message.languages, languages.count == 1, let code = languages.first?.code, !code.isEmpty {
                item.language = code
            }
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
                        text: text, state: state, language: item.language, recognitionUsage: item.usage)
    }
}

public actor OpenAIRealtimeTranscriber: StreamingSTT {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let vocabulary: [String]
    private let makeSocket: @Sendable (URLRequest) -> any RealtimeSocket
    private var socket: (any RealtimeSocket)?
    private var connection: UUID?
    private var reader: Task<Void, Never>?

    public init(apiKey: String, model: String = "gpt-live-transcribe", language: String? = nil,
                vocabulary: [String] = []) {
        self.init(apiKey: apiKey, model: model, language: language, vocabulary: vocabulary,
                  socket: { FoundationRealtimeSocket(request: $0) })
    }

    init(apiKey: String, model: String, language: String? = nil, vocabulary: [String] = [],
         socket: @escaping @Sendable (URLRequest) -> any RealtimeSocket) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        makeSocket = socket
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard socket == nil else { throw CaptureFailure.alreadyRunning }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderFailure.missingCredentials }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw ProviderFailure.requestRejected
        }
        let sessionUpdate = try OpenAIRealtimeWire.session(model: model, language: language, vocabulary: vocabulary)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let socket = makeSocket(request)
        self.socket = socket
        let id = UUID()
        connection = id
        do {
            try await socket.send(sessionUpdate)
            try await receiveReadiness(on: socket, timeout: .seconds(15)) { bytes in
                guard let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let kind = event["type"] as? String else { throw ProviderFailure.malformedEvent }
                if kind == "session.updated" {
                    guard (event["session"] as? [String: Any])?["type"] as? String == "transcription" else {
                        throw ProviderFailure.malformedEvent
                    }
                    return true
                }
                if kind == "error" {
                    var assembler = OpenAITranscriptAssembler(source: source, epoch: epoch)
                    _ = try assembler.receive(bytes)
                }
                return false
            }
            guard connection == id else { throw CancellationError() }
        } catch {
            if connection == id { await close() }
            throw error
        }
        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let replacementPartials = model == "whisper-1"
        reader = Task.detached {
            var assembler = OpenAITranscriptAssembler(source: source, epoch: epoch,
                                                       replacementPartials: replacementPartials)
            do {
                while !Task.isCancelled {
                    for event in try assembler.receive(await socket.read()) {
                        if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
                    }
                }
                output.finish()
            } catch {
                if Task.isCancelled { output.finish() }
                else if let error = error as? CaptureFailure { output.finish(throwing: error) }
                else { output.finish(throwing: (error as? ProviderFailure) ?? .disconnected) }
            }
        }
        output.onTermination = { _ in socket.close() }
        return events
    }

    public func append(_ frame: AudioFrame) async throws {
        guard frame.sampleRate == 24_000, !frame.pcm.isEmpty, frame.pcm.count.isMultiple(of: 2) else {
            throw CaptureFailure.invalidFormat
        }
        try await send(OpenAIRealtimeWire.append(frame.pcm))
    }

    public func commit() async throws { try await send(OpenAIRealtimeWire.commit) }

    public func checkConnection() async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        try await socket.ping()
    }

    public func close() async {
        let oldReader = reader
        reader = nil
        connection = nil
        oldReader?.cancel()
        socket?.close()
        socket = nil
        await oldReader?.value
    }

    private func send(_ message: String) async throws {
        guard let socket else { throw ProviderFailure.disconnected }
        try await socket.send(message)
    }
}
