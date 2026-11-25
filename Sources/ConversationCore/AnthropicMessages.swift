import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicMessagesClient: Sendable {
    let apiKey: String
    let model: String

    func request(system: String, input: String, fields: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ProviderFailure.missingCredentials }
        guard !model.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ProviderFailure.requestRejected
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = fields
        body["model"] = model
        body["system"] = system
        body["messages"] = [["role": "user", "content": input]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public struct AnthropicQuestionClassifier: QuestionClassifier {
    private let client: AnthropicMessagesClient

    public init(apiKey: String, model: String) {
        client = AnthropicMessagesClient(apiKey: apiKey, model: model)
    }

    public func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        let context = ClassifierContext(input)
        let serialized = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let request = try client.request(system: OpenAIQuestionClassifier.instructions, input: serialized, fields: [
            "max_tokens": 650,
            "output_config": ["format": ["type": "json_schema", "schema": OpenAIQuestionClassifier.schema]]
        ], timeout: 8)
        return try await OpenAIResponsesClient.protected {
            let (data, response) = try await URLSession.shared.data(for: request)
            try OpenAIResponsesClient.validate(response)
            guard let message = try? JSONDecoder().decode(Message.self, from: data),
                  message.stop_reason == "end_turn",
                  let text = message.content.first(where: { $0.type == "text" })?.text,
                  let decision = try? JSONDecoder().decode(QuestionDecision.self, from: Data(text.utf8))
            else { throw ProviderFailure.malformedEvent }
            return decision
        }
    }

    private struct Message: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let content: [Content]
        let stop_reason: String?
    }
}

public struct AnthropicTextGenerator: TextGenerator {
    private let client: AnthropicMessagesClient

    public init(apiKey: String, model: String) {
        client = AnthropicMessagesClient(apiKey: apiKey, model: model)
    }

    public func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let request = try client.request(system: AnswerPrompt.instructions(request), input: AnswerPrompt.input(request),
                                         fields: ["stream": true, "max_tokens": 1_200], timeout: 20)
        let decoder = AnthropicStreamDecoder()
        // StreamingHTTP supplies a serial delegate queue for each decoder.
        return StreamingHTTP.start(request) { try decoder.receive($0) }
    }
}

final class AnthropicStreamDecoder: @unchecked Sendable {
    private struct Event: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        struct Message: Decodable {
            let usage: Usage?
        }
        let type: String
        let delta: Delta?
        let message: Message?
        let usage: Usage?
    }

    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopReason: String?

    func receive(_ message: String) throws -> StreamingHTTP.Event {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(message.utf8)) else {
            throw ProviderFailure.malformedEvent
        }
        switch event.type {
        case "message_start":
            inputTokens = event.message?.usage?.input_tokens
            outputTokens = event.message?.usage?.output_tokens
        case "content_block_delta":
            if event.delta?.type == "text_delta" {
                guard let text = event.delta?.text else { throw ProviderFailure.malformedEvent }
                return .text(text)
            }
        case "message_delta":
            inputTokens = event.usage?.input_tokens ?? inputTokens
            outputTokens = event.usage?.output_tokens ?? outputTokens
            stopReason = event.delta?.stop_reason ?? stopReason
        case "message_stop":
            guard stopReason == "end_turn" || stopReason == "stop_sequence" else {
                throw ProviderFailure.requestRejected
            }
            let usage = inputTokens.flatMap { input in outputTokens.map { TokenUsage(input: input, output: $0) } }
            return .complete(usage)
        case "error": throw ProviderFailure.unavailable
        default: break
        }
        return .ignore
    }
}
