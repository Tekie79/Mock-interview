import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uses only an account-bound ChatGPT plan credential source. The application
/// does not compose this provider until distribution eligibility is established.
struct ChatGPTSubscriptionProvider: TextGenerator, QuestionClassifier {
    enum ModelCapability: Hashable, Sendable {
        case streamedText, streamedStructuredOutput
    }

    struct Model: Decodable, Identifiable, Sendable {
        let slug: String
        let display_name: String
        let visibility: String
        var id: String { slug }
    }

    let model: String
    let verified: Set<ModelCapability>
    let credentials: @Sendable () async throws -> ChatGPTPlanCredentials

    func availableModels() async throws -> [Model] {
        struct Catalog: Decodable { let models: [Model] }
        guard let url = URL(string: ChatGPTAuthorizationAttempt.resource + "/models") else {
            throw ProviderFailure.requestRejected
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer " + (try await credentials().authorizedAccess()), forHTTPHeaderField: "Authorization")
        return try await OpenAIResponsesClient.protected {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            try OpenAIResponsesClient.validate(response)
            guard let catalog = try? JSONDecoder().decode(Catalog.self, from: bytes) else {
                throw ProviderFailure.malformedEvent
            }
            return catalog.models.filter { $0.visibility == "list" }
        }
    }

    func stream(_ input: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        guard verified.contains(.streamedText) else { throw PlanAuthorizationFailure.unverifiedModel }
        return try await open(instructions: AnswerPrompt.instructions(input), content: AnswerPrompt.input(input))
    }

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        guard verified.contains(.streamedStructuredOutput) else { throw PlanAuthorizationFailure.unverifiedModel }
        let content = String(decoding: try JSONEncoder().encode(ClassifierContext(input)), as: UTF8.self)
        let events = try await open(instructions: OpenAIQuestionClassifier.instructions, content: content, schema: true)
        var json = Data()
        for try await event in events {
            if case .text(let chunk) = event {
                guard json.count + chunk.utf8.count <= 16_000 else { throw ProviderFailure.malformedEvent }
                json.append(contentsOf: chunk.utf8)
            }
        }
        guard let result = try? JSONDecoder().decode(QuestionDecision.self, from: json) else {
            throw ProviderFailure.unsupportedCapability
        }
        return result
    }

    func open(instructions: String, content: String, schema: Bool = false) async throws
        -> AsyncThrowingStream<GenerationEvent, Error> {
        let access = try await credentials().authorizedAccess()
        let request = try Self.request(access: access, model: model, instructions: instructions,
                                       content: content, schema: schema)
        return StreamingHTTP.start(request) { try Self.decode($0) }
    }

    static func request(access: String, model: String, instructions: String, content: String, schema: Bool) throws
        -> URLRequest {
        guard !access.isEmpty, !model.isEmpty,
              let url = URL(string: ChatGPTAuthorizationAttempt.resource + "/responses") else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        var body: [String: Any] = [
            "model": model, "store": false, "stream": true, "instructions": instructions,
            "input": [["role": "user", "content": content]]
        ]
        if schema {
            body["text"] = ["format": [
                "type": "json_schema", "name": "interview_question", "strict": true, "schema": OpenAIQuestionClassifier.schema
            ]]
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func decode(_ message: String) throws -> StreamingHTTP.Event {
        if let event = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] {
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
            switch (error?["code"] ?? event["code"]) as? String {
            case "subscription_sharing_usage_limit_exceeded": throw ProviderFailure.quotaExhausted
            case "subscription_sharing_usage_unavailable": throw PlanAuthorizationFailure.authorizationMissing
            default: break
            }
        }
        return try OpenAITextGenerator.decode(message)
    }
}
