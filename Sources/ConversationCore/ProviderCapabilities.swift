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

    public static func describe(_ provider: ProviderID, model: String? = nil,
                                appleOnDevice: Bool = false) -> Self {
        switch provider {
        case .appleSpeech:
            return .init(provider: provider, services: [.transcription], authentication: .systemPermission,
                         billing: .native, models: ["Speech framework"], streams: true, designatedLanguage: true,
                         commits: [.manual], vocabularyHints: true, canRunOnDevice: appleOnDevice,
                         requiresNetwork: !appleOnDevice)
        case .openai:
            let realtime = model == nil || ["gpt-live-transcribe", "gpt-4o-transcribe",
                                            "gpt-4o-mini-transcribe", "whisper-1"].contains(model)
            let alternate = model == "gpt-4o-transcribe" || model == "gpt-4o-mini-transcribe" || model == "whisper-1"
            return .init(provider: provider, services: [.transcription, .classification, .answer, .embeddings],
                         authentication: .apiKey, billing: .separatelyBilledAPI,
                         models: ["gpt-live-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"],
                         streams: true, designatedLanguage: realtime,
                         commits: alternate ? [.manual, .voiceActivity] : [.manual],
                         structuredOutput: true, usage: true, vocabularyHints: alternate)
        case .elevenLabs:
            let semantic = model == "scribe_v3_live"
            return .init(provider: provider, services: [.transcription], authentication: .apiKey,
                         billing: .separatelyBilledAPI, models: ["scribe_v3_live", "scribe_v2_realtime"],
                         streams: true, designatedLanguage: true, detectsLanguage: true, wordTimestamps: true,
                         commits: semantic ? [.manual, .voiceActivity, .semanticTurn] : [.manual, .voiceActivity],
                         vocabularyHints: true)
        case .deepgram:
            let nova = (model ?? "nova-3").hasPrefix("nova-")
            return .init(provider: provider, services: [.transcription], authentication: .apiKey,
                         billing: .separatelyBilledAPI, models: ["nova-3", "nova-3-general", "nova-2"],
                         streams: true, designatedLanguage: true, detectsLanguage: model == "nova-3",
                         wordTimestamps: true, diarization: nova, commits: [.manual, .voiceActivity],
                         vocabularyHints: nova)
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

    public init(sampleRate: Int = 24_000, delivery: Delivery = .clientCommit, streamsSilence: Bool = false) {
        self.sampleRate = sampleRate
        self.delivery = delivery
        self.streamsSilence = streamsSilence
    }
}
