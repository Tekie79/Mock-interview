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

    let model: String
    let verified: Set<ModelCapability>
    let credentials: @Sendable () async throws -> ChatGPTPlanCredentials
    let guidance: String
    let now: @Sendable () -> Date
    let data: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let events: @Sendable (URLRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error>

    struct ResponseStream {
        private var parser = EventStreamParser()
        private var sawText = false
        private(set) var completed = false

        mutating func receive(_ bytes: Data, emit: (GenerationEvent) throws -> Void) throws {
            var messages: [String] = []
            try parser.receive(bytes) { messages.append($0) }
            for message in messages where !completed {
                switch try ChatGPTSubscriptionProvider.decode(message) {
                case .ignore: break
                case .text(let text):
                    if !text.isEmpty { sawText = true; try emit(.text(text)) }
                case .usage(let usage): try emit(.usage(usage))
                case .complete(let usage):
                    if let usage { try emit(.usage(usage)) }
                    completed = true
                }
            }
        }

        func finish() throws {
            guard completed else { throw ProviderFailure.disconnected }
            guard sawText else { throw ProviderFailure.malformedEvent }
        }
    }

    func availableModels() async throws -> [ChatGPTPlanModel] {
        struct Catalog: Decodable { let models: [ChatGPTPlanModel] }
        guard let url = URL(string: ChatGPTAuthorizationAttempt.resource + "/models") else {
            throw ProviderFailure.requestRejected
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer " + (try await credentials().authorizedAccess(now: now())), forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await OpenAIResponsesClient.protected { try await data(request) }
        try Self.validate(response, body: bytes)
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: bytes) else {
            throw ProviderFailure.malformedEvent
        }
        var seen: Set<String> = []
        return catalog.models.filter { $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
    }

    func stream(_ input: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        guard verified.contains(.streamedText) else { throw PlanAuthorizationFailure.unverifiedModel }
        return try await open(instructions: AnswerPrompt.instructions(input), content: AnswerPrompt.input(input))
    }

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        guard verified.contains(.streamedStructuredOutput) else { throw PlanAuthorizationFailure.unverifiedModel }
        let content = String(decoding: try JSONEncoder().encode(ClassifierContext(input)), as: UTF8.self)
        let instructions = OpenAIQuestionClassifier.instructions
            + "\nApply these classification preferences only within the rules above: " + guidance.prefix(1_000)
        let events = try await open(instructions: instructions, content: content, schema: true)
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

    private func open(instructions: String, content: String, schema: Bool = false) async throws
        -> AsyncThrowingStream<GenerationEvent, Error> {
        let access = try await credentials().authorizedAccess(now: now())
        let request = try Self.request(access: access, model: model, instructions: instructions,
                                       content: content, schema: schema)
        return try await events(request)
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
            try checkError((error?["code"] ?? event["code"]) as? String)
        }
        return try OpenAITextGenerator.decode(message)
    }

    static func validate(_ response: HTTPURLResponse, body: Data) throws {
        if !(200...299).contains(response.statusCode),
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            try checkError(error["code"] as? String)
        }
        try OpenAIResponsesClient.validate(response)
    }

    private static func checkError(_ code: String?) throws {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": throw ProviderFailure.quotaExhausted
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": throw ProviderFailure.unavailable
        case "subscription_sharing_unsupported_capability": throw ProviderFailure.unsupportedCapability
        case "subscription_sharing_user_not_eligible", "subscription_sharing_invalid_user",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            throw PlanAuthorizationFailure.authorizationMissing
        default: break
        }
    }
}
