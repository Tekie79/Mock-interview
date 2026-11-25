import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech, openai, elevenLabs, deepgram, anthropic, chatGPTSubscription
    public var id: String { rawValue }
}

public enum ProviderSelection {
    /// A missing setting may use the application default. An explicitly invalid selection fails closed.
    public static func decode<T: RawRepresentable>(_ stored: String?, default fallback: T) throws -> T
        where T.RawValue == String {
        guard let stored else { return fallback }
        guard let selection = T(rawValue: stored) else { throw ProviderFailure.unsupportedCapability }
        return selection
    }
}

public enum ProviderService: String, Codable, CaseIterable, Sendable {
    case transcription, classification, answer, embeddings
}

public enum ProviderAuthentication: String, Sendable {
    case systemPermission, apiKey, approvedHostSignIn
}

public enum ProviderBilling: String, Sendable {
    case native, separatelyBilledAPI, chatGPTPlan
}

public enum TranscriptionCommitStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, voiceActivity, semanticTurn
    public var id: String { rawValue }
}

public struct ProviderCapabilities: Equatable, Sendable {
    public let provider: ProviderID
    public let services: Set<ProviderService>
    public let authentication: ProviderAuthentication
    public let billing: ProviderBilling
    public var models: [String] = []
    public var streams = false
    public var designatedLanguage = false
    public var detectsLanguage = false
    public var wordTimestamps = false
    public var diarization = false
    public var commits: Set<TranscriptionCommitStrategy> = []
    public var structuredOutput = false
    public var usage = false
    public var vocabularyHints = false
    public var canRunOnDevice = false
    public var requiresNetwork = true
    public var unavailableReason: String?

    static let openAIKeywordModels: Set<String> = ["gpt-live-transcribe", "gpt-transcribe"]
    static let openAIPromptModels: Set<String> = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1",
                                                  "gpt-4o-mini-transcribe-2025-03-20", "gpt-4o-mini-transcribe-2025-12-15"]
    private static let deepgramModels: Set<String> = [
        "nova-3", "nova-3-general", "nova-3-medical", "nova-2", "nova-2-general", "nova-2-meeting",
        "nova-2-finance", "nova-2-conversationalai", "nova-2-voicemail", "nova-2-video", "nova-2-medical",
        "nova-2-drivethru", "nova-2-automotive", "nova", "nova-general", "nova-phonecall", "nova-medical",
        "enhanced", "enhanced-general", "enhanced-meeting", "enhanced-phonecall", "enhanced-finance",
        "base", "meeting", "phonecall", "finance", "conversationalai", "voicemail", "video", "custom"
    ]
    private static let deepgramMultilingualModels: Set<String> = [
        "nova-3", "nova-3-general", "nova-3-medical", "nova-2", "nova-2-general"
    ]

    public static func describe(_ provider: ProviderID, model: String? = nil,
                                appleOnDevice: Bool = false) -> Self {
        switch provider {
        case .appleSpeech:
            return .init(provider: provider, services: [.transcription], authentication: .systemPermission,
                         billing: .native, models: ["Speech framework"], streams: true, designatedLanguage: true,
                         commits: [.manual], vocabularyHints: true, canRunOnDevice: appleOnDevice,
                         requiresNetwork: !appleOnDevice)
        case .openai:
            let selected = model ?? "gpt-live-transcribe"
            let hints = openAIKeywordModels.contains(selected) || openAIPromptModels.contains(selected)
            let realtime = hints || selected == "gpt-realtime-whisper"
            let services: Set<ProviderService>
            if model == nil { services = [.transcription, .classification, .answer, .embeddings] }
            else if realtime { services = [.transcription] }
            else if selected.hasPrefix("text-embedding-") { services = [.embeddings] }
            else { services = [.classification, .answer] }
            return .init(provider: provider, services: services,
                         authentication: .apiKey, billing: .separatelyBilledAPI,
                          models: ["gpt-live-transcribe", "gpt-transcribe", "gpt-realtime-whisper"],
                          streams: services != [.embeddings], designatedLanguage: realtime,
                          detectsLanguage: selected == "gpt-transcribe", commits: realtime ? [.manual] : [],
                          structuredOutput: services.contains(.classification),
                          usage: model == nil || services.contains(.answer), vocabularyHints: hints)
        case .elevenLabs:
            let semantic = model == "scribe_v3_live"
            return .init(provider: provider, services: [.transcription], authentication: .apiKey,
                         billing: .separatelyBilledAPI, models: ["scribe_v3_live", "scribe_v2_realtime"],
                         streams: true, designatedLanguage: true, detectsLanguage: true, wordTimestamps: true, diarization: semantic,
                         commits: semantic ? [.manual, .voiceActivity, .semanticTurn] : [.manual, .voiceActivity],
                         vocabularyHints: true)
        case .deepgram:
            let selected = model ?? "nova-3"
            let streaming = deepgramModels.contains(selected)
            let nova = selected == "nova" || selected.hasPrefix("nova-")
            let hints = nova || selected == "enhanced" || selected.hasPrefix("enhanced-") || selected == "base"
            return .init(provider: provider, services: streaming ? [.transcription] : [], authentication: .apiKey,
                         billing: .separatelyBilledAPI, models: ["nova-3", "nova-3-general", "nova-2"],
                         streams: streaming, designatedLanguage: streaming,
                         detectsLanguage: deepgramMultilingualModels.contains(selected),
                         wordTimestamps: streaming, diarization: streaming && nova,
                         commits: streaming ? [.manual, .voiceActivity] : [], vocabularyHints: streaming && hints)
        case .anthropic:
            return .init(provider: provider, services: [.classification, .answer], authentication: .apiKey,
                         billing: .separatelyBilledAPI, streams: true, structuredOutput: true, usage: true)
        case .chatGPTSubscription:
            return .init(provider: provider, services: [], authentication: .approvedHostSignIn,
                         billing: .chatGPTPlan, unavailableReason: ChatGPTPlanEligibility.requirement)
        }
    }

    public func supports(_ service: ProviderService) -> Bool {
        unavailableReason == nil && services.contains(service)
    }
}

public struct TranscriptionBehavior: Equatable, Sendable {
    public enum Delivery: Sendable {
        /// A final transcript acknowledges each explicit local commit.
        case clientCommit
        /// The transport owns segmentation and finishes its stream after input is gracefully ended.
        case providerCommit
    }

    public let sampleRate: Int
    public let delivery: Delivery
    public let streamsSilence: Bool
    public let requiresStreamEnd: Bool

    public init(sampleRate: Int = 24_000, delivery: Delivery = .clientCommit, streamsSilence: Bool = false,
                requiresStreamEnd: Bool = false) {
        self.sampleRate = sampleRate
        self.delivery = delivery
        self.streamsSilence = streamsSilence
        self.requiresStreamEnd = requiresStreamEnd
    }
}
