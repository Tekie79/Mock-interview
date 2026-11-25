import Foundation

public struct ProviderPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transcription: ProviderID
    public var transcriptionModel: String
    public var classifier: ProviderID
    public var classificationModel: String
    public var answer: ProviderID
    public var answerModel: String
    public var language: String
    public var appleRecognitionMode: AppleRecognitionMode
    public var commit: TranscriptionCommitStrategy
    public var embeddingsModel: String?

    public init(id: UUID = UUID(), name: String, transcription: ProviderID, transcriptionModel: String,
                classifier: ProviderID, classificationModel: String, answer: ProviderID, answerModel: String,
                language: String = "", appleRecognitionMode: AppleRecognitionMode = .onDevice,
                commit: TranscriptionCommitStrategy = .manual, embeddingsModel: String? = nil) {
        self.id = id
        self.name = name
        self.transcription = transcription
        self.transcriptionModel = transcriptionModel
        self.classifier = classifier
        self.classificationModel = classificationModel
        self.answer = answer
        self.answerModel = answerModel
        self.language = language
        self.appleRecognitionMode = appleRecognitionMode
        self.commit = commit
        self.embeddingsModel = embeddingsModel
    }

    public var unavailableReason: String? {
        for (provider, model, service) in [(transcription, transcriptionModel, ProviderService.transcription),
                                           (classifier, classificationModel, .classification),
                                           (answer, answerModel, .answer)] {
            let caps = ProviderCapabilities.describe(provider, model: model)
            if let reason = caps.unavailableReason { return reason }
            if provider != .appleSpeech && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a model for each selected service."
            }
            if !caps.supports(service) { return "The selected provider or model does not support this service." }
        }
        if transcription == .elevenLabs {
            let caps = ProviderCapabilities.describe(transcription, model: transcriptionModel)
            if !caps.models.contains(transcriptionModel) || !caps.commits.contains(commit) {
                return "The selected Scribe model does not support this configuration."
            }
        }
        if transcription == .openai,
           (try? OpenAIRealtimeWire.session(model: transcriptionModel, language: language)) == nil {
            return "Enter a language code supported by the selected OpenAI transcription model."
        }
        if transcription == .deepgram, language.trimmingCharacters(in: .whitespacesAndNewlines) == "multi",
           !ProviderCapabilities.describe(transcription, model: transcriptionModel).detectsLanguage {
            return "The selected Deepgram model does not support multilingual transcription."
        }
        if let embeddingsModel,
           !ProviderCapabilities.describe(.openai, model: embeddingsModel).supports(.embeddings) {
            return "Enter an OpenAI embedding model or disable semantic retrieval."
        }
        return nil
    }

    public func copy(named name: String) -> Self {
        var next = self
        next.id = UUID()
        next.name = name
        return next
    }

    public static func defaults() -> [Self] {
        [
            .init(name: "Subscription-first", transcription: .appleSpeech, transcriptionModel: "Speech framework",
                  classifier: .chatGPTSubscription, classificationModel: "", answer: .chatGPTSubscription, answerModel: "",
                  language: "en-US"),
            .init(name: "Real-time cloud", transcription: .elevenLabs, transcriptionModel: "scribe_v3_live",
                  classifier: .chatGPTSubscription, classificationModel: "", answer: .chatGPTSubscription, answerModel: "",
                  commit: .semanticTurn),
            .init(name: "OpenAI", transcription: .openai, transcriptionModel: "gpt-live-transcribe",
                  classifier: .openai, classificationModel: "gpt-4.1-mini", answer: .openai, answerModel: "gpt-4.1-mini"),
            .init(name: "Alternative cloud", transcription: .deepgram, transcriptionModel: "nova-3",
                  classifier: .anthropic, classificationModel: "claude-haiku-4-5",
                  answer: .anthropic, answerModel: "claude-haiku-4-5", commit: .voiceActivity),
            .init(name: "Hybrid", transcription: .elevenLabs, transcriptionModel: "scribe_v3_live",
                  classifier: .openai, classificationModel: "gpt-4.1-mini", answer: .openai, answerModel: "gpt-4.1-mini",
                  commit: .semanticTurn),
            .init(name: "Custom", transcription: .openai, transcriptionModel: "gpt-live-transcribe",
                  classifier: .openai, classificationModel: "gpt-4.1-mini", answer: .openai, answerModel: "gpt-4.1-mini")
        ]
    }
}
