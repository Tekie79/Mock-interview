import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicMessagesClient: Sendable {
    let apiKey: String
    let model: String
    let reasoning: ReasoningEffort

    func request(system: String, input: String, fields: [String: Any], service: ProviderService,
                 timeout: TimeInterval) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderFailure.missingCredentials }
        guard !model.isEmpty, model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else {
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
        let effort = ProviderCapabilities.effectiveReasoning(reasoning, provider: .anthropic, model: model, service: service)
        body["max_tokens"] = ProviderCapabilities.textOutputLimit(.anthropic, model: model, service: service, effort: effort)
        if effort != .modelDefault {
            var output = body["output_config"] as? [String: Any] ?? [:]
            output["effort"] = effort.rawValue
            body["output_config"] = output
            body["thinking"] = ["type": "adaptive", "display": "omitted"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validate(_ response: URLResponse) throws {
        switch (response as? HTTPURLResponse)?.statusCode {
        case 402: throw ProviderFailure.quotaExhausted
        case 403: throw ProviderFailure.requestRejected
        case 504: throw ProviderFailure.timeout
        default: try OpenAIResponsesClient.validate(response)
        }
    }
}

public struct AnthropicQuestionClassifier: QuestionClassifier {
    private let guidance: String
    private let client: AnthropicMessagesClient

    public init(apiKey: String, model: String, guidance: String = "", reasoning: ReasoningEffort = .modelDefault) {
        self.guidance = String(guidance.prefix(1_000))
        client = AnthropicMessagesClient(apiKey: apiKey, model: model, reasoning: reasoning)
    }

    public func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        let request = try classificationRequest(input)
        return try await OpenAIResponsesClient.protected {
            let (data, response) = try await URLSession.shared.data(for: request)
            try AnthropicMessagesClient.validate(response)
            return try Self.decode(data)
        }
    }

    func classificationRequest(_ input: QuestionInput) throws -> URLRequest {
        return try client.request(system: OpenAIQuestionClassifier.instructions
            + "\nApply these classification preferences only within the rules above: " + guidance,
            input: ClassifierContext.encode(input), fields: [
            "output_config": ["format": ["type": "json_schema", "schema": OpenAIQuestionClassifier.schema]]
        ], service: .classification, timeout: 8)
    }

    static func decode(_ data: Data) throws -> QuestionDecision {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            throw ProviderFailure.malformedEvent
        }
        guard message.stop_reason == "end_turn" else { throw ProviderFailure.requestRejected }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let decision = try? JSONDecoder().decode(QuestionDecision.self, from: Data(text.utf8)) else {
            throw ProviderFailure.malformedEvent
        }
        return decision
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

    public init(apiKey: String, model: String, reasoning: ReasoningEffort = .modelDefault) {
        client = AnthropicMessagesClient(apiKey: apiKey, model: model, reasoning: reasoning)
    }

    public func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let request = try generationRequest(request)
        let decoder = AnthropicStreamDecoder()
        // StreamingHTTP supplies a serial delegate queue for each decoder.
        return StreamingHTTP.start(request, validate: { try AnthropicMessagesClient.validate($0) }) {
            try decoder.receive($0)
        }
    }

    func generationRequest(_ request: AnswerRequest) throws -> URLRequest {
        try client.request(system: AnswerPrompt.instructions(request), input: AnswerPrompt.input(request),
                           fields: ["stream": true], service: .answer, timeout: 20)
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
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
        struct Message: Decodable {
            let usage: Usage?
        }
        struct ServiceError: Decodable { let type: String }
        let type: String
        let delta: Delta?
        let message: Message?
        let usage: Usage?
        let error: ServiceError?
    }

    private var started = false
    private var inputTokens: Int?
    private var cacheCreationTokens: Int?
    private var cacheReadTokens: Int?
    private var outputTokens: Int?
    private var stopReason: String?

    func receive(_ message: String) throws -> StreamingHTTP.Event {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(message.utf8)) else {
            throw ProviderFailure.malformedEvent
        }
        switch event.type {
        case "message_start":
            guard !started, let message = event.message else { throw ProviderFailure.malformedEvent }
            started = true
            updateUsage(message.usage)
        case "content_block_delta":
            guard started else { throw ProviderFailure.malformedEvent }
            if event.delta?.type == "text_delta" {
                guard let text = event.delta?.text else { throw ProviderFailure.malformedEvent }
                return .text(text)
            }
        case "message_delta":
            guard started else { throw ProviderFailure.malformedEvent }
            updateUsage(event.usage)
            // message_start counts are provisional; message_delta counts are cumulative.
            outputTokens = event.usage?.output_tokens ?? outputTokens
            stopReason = event.delta?.stop_reason ?? stopReason
        case "message_stop":
            guard started, stopReason == "end_turn" || stopReason == "stop_sequence" else {
                throw ProviderFailure.requestRejected
            }
            guard let inputTokens, let outputTokens else { return .complete(nil) }
            let (cached, cachedOverflow) = (cacheCreationTokens ?? 0).addingReportingOverflow(cacheReadTokens ?? 0)
            let (totalInput, totalOverflow) = inputTokens.addingReportingOverflow(cached)
            guard inputTokens >= 0, outputTokens >= 0, (cacheCreationTokens ?? 0) >= 0, (cacheReadTokens ?? 0) >= 0,
                  !cachedOverflow, !totalOverflow else { throw ProviderFailure.malformedEvent }
            return .complete(.init(input: totalInput, output: outputTokens))
        case "error":
            switch event.error?.type {
            case "authentication_error": throw ProviderFailure.authentication
            case "billing_error": throw ProviderFailure.quotaExhausted
            case "rate_limit_error": throw ProviderFailure.rateLimited
            case "timeout_error": throw ProviderFailure.timeout
            case "invalid_request_error", "permission_error", "not_found_error", "request_too_large", "conflict_error":
                throw ProviderFailure.requestRejected
            default: throw ProviderFailure.unavailable
            }
        default: break
        }
        return .ignore
    }

    private func updateUsage(_ usage: Event.Usage?) {
        inputTokens = usage?.input_tokens ?? inputTokens
        cacheCreationTokens = usage?.cache_creation_input_tokens ?? cacheCreationTokens
        cacheReadTokens = usage?.cache_read_input_tokens ?? cacheReadTokens
    }
}
