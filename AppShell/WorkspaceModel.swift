import AppKit
import AVFoundation
import ConversationCore
import LocalAuthentication
import Observation
import Security
import Speech
import SwiftUI
import UniformTypeIdentifiers

private enum Keychain {
    static let service = "com.mockinterview.desktop"
    static let providers = ProviderCredentialStore(
        read: { account in load(account) },
        persist: { value, account in try save(value, account: account) }
    )

    static func configuredAccounts() -> Set<String> {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return Set(["openai", "deepgram", "anthropic", "elevenlabs"].filter { account in
            var query = base(account)
            query[kSecUseAuthenticationContext as String] = authentication
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        })
    }

    private static func load(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) throws {
        let query = base(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ProviderFailure.requestRejected
            }
            return
        }
        let data = Data(value.utf8)
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProviderFailure.requestRejected }
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum SpeechProvider: String, CaseIterable, Identifiable {
    case apple = "Apple Speech"
    case eleven = "ElevenLabs"
    case openai = "OpenAI"
    case deepgram = "Deepgram"
    var id: String { rawValue }
    var provider: ProviderID {
        switch self {
        case .apple: .appleSpeech
        case .eleven: .elevenLabs
        case .openai: .openai
        case .deepgram: .deepgram
        }
    }
}

enum WorkspaceAudioChannel: String {
    case question = "Question"
    case replay = "Replay"
    case candidate = "Candidate microphone"
}

enum TextProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    case chatGPT = "ChatGPT plan"
    var id: String { rawValue }
    var provider: ProviderID {
        switch self {
        case .openai: .openai
        case .anthropic: .anthropic
        case .chatGPT: .chatGPTSubscription
        }
    }

    static var available: [Self] {
        ChatGPTPlanEligibility.desktopAvailable ? allCases : [.openai, .anthropic]
    }
}

@MainActor
struct SessionProviders {
    static let chatGPT = ChatGPTPlanAccounts.makeDesktop()
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")
    let transcriber: @Sendable () -> any StreamingSTT
    let classifier: any QuestionClassifier
    let generator: any TextGenerator
    let usesChatGPT: Bool
    let activityThreshold: Float

    init(defaults: UserDefaults, diarize: Bool = false) async throws {
        let classification = try ProviderSelection.decode(defaults.string(forKey: "classificationProvider"), default: TextProvider.openai)
        let answer = try ProviderSelection.decode(defaults.string(forKey: "answerProvider"), default: TextProvider.openai)
        let activityThreshold = Self.audioActivityThreshold(defaults: defaults)
        let transcriber = try await Self.transcriptionFactory(defaults: defaults, diarize: diarize, activityThreshold: activityThreshold)
        self.classifier = try await Self.questionClassifier(defaults: defaults, provider: classification)
        self.generator = try await Self.answerGenerator(defaults: defaults, provider: answer)
        self.transcriber = transcriber
        self.usesChatGPT = classification == .chatGPT || answer == .chatGPT
        self.activityThreshold = activityThreshold
    }

    private static func key(_ account: String) async throws -> String {
        try Task.checkCancellation()
        guard let value = await Keychain.providers.load(account) else { throw ProviderFailure.missingCredentials }
        try Task.checkCancellation()
        return value
    }

    static func audioActivityThreshold(defaults: UserDefaults) -> Float {
        let stored = defaults.object(forKey: "vadThreshold") as? Double ?? 0.015
        return (0.005...0.08).contains(stored) ? Float(stored) : 0.015
    }

    static func transcriptionFactory(defaults: UserDefaults, diarize: Bool = false, activityThreshold: Float? = nil) async throws
        -> @Sendable () -> any StreamingSTT {
        let speech = try ProviderSelection.decode(defaults.string(forKey: "speechProvider"), default: SpeechProvider.openai)
        let language = defaults.string(forKey: "sttLanguage")
        let vocabulary = (defaults.string(forKey: "speechVocabulary") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch speech {
        case .apple:
            let locale = defaults.string(forKey: "appleSpeechLocale") ?? "en-US"
            let mode = AppleRecognitionMode(rawValue: defaults.string(forKey: "appleSpeechMode") ?? "") ?? .onDevice
            return { AppleSpeechRouter(locale: locale, mode: mode, vocabulary: vocabulary) }
        case .eleven:
            let credential = try await key("elevenlabs")
            let model = defaults.string(forKey: "elevenModel") ?? "scribe_v3_live"
            let strategy = TranscriptionCommitStrategy(rawValue: defaults.string(forKey: "elevenCommit") ?? "") ?? .manual
            let config = ElevenLabsSpeechConfiguration(
                model: model, language: language, detectLanguage: defaults.object(forKey: "elevenDetectLanguage") as? Bool ?? true,
                strategy: strategy, silenceSeconds: defaults.object(forKey: "sttEndpoint") as? Double ?? 0.65,
                vocabulary: vocabulary, localActivityThreshold: activityThreshold ?? audioActivityThreshold(defaults: defaults),
                diarize: diarize && ProviderCapabilities.describe(.elevenLabs, model: model).diarization)
            return { ElevenLabsTranscriber(apiKey: credential, configuration: config) }
        case .openai:
            let credential = try await key("openai")
            let model = defaults.string(forKey: "sttModel") ?? "gpt-live-transcribe"
            return { OpenAIRealtimeTranscriber(apiKey: credential, model: model, language: language, vocabulary: vocabulary) }
        case .deepgram:
            let credential = try await key("deepgram")
            let model = defaults.string(forKey: "deepgramModel") ?? "nova-3"
            let seconds = defaults.object(forKey: "sttEndpoint") as? Double ?? 0.65
            let endpoint = Int(min(3, max(0.1, seconds.isFinite ? seconds : 0.65)) * 1_000)
            return {
                DeepgramTranscriber(apiKey: credential, model: model, language: language, diarize: diarize,
                                    endpointMilliseconds: endpoint, vocabulary: vocabulary)
            }
        }
    }

    private static func questionClassifier(defaults: UserDefaults, provider: TextProvider) async throws -> any QuestionClassifier {
        let instructions = defaults.string(forKey: "classificationInstructions") ?? ""
        switch provider {
        case .openai:
            return OpenAIQuestionClassifier(apiKey: try await key("openai"),
                model: defaults.string(forKey: "questionModel") ?? "gpt-4.1-mini", guidance: instructions,
                reasoning: reasoning(defaults, "openAIQuestionReasoning"))
        case .anthropic:
            return AnthropicQuestionClassifier(apiKey: try await key("anthropic"),
                model: defaults.string(forKey: "anthropicQuestionModel") ?? "claude-haiku-4-5", guidance: instructions,
                reasoning: reasoning(defaults, "anthropicQuestionReasoning"))
        case .chatGPT:
            guard let chatGPT else { throw PlanAuthorizationFailure.unavailable }
            return try await chatGPT.classifier(model: defaults.string(forKey: "chatGPTQuestionModel") ?? "", guidance: instructions)
        }
    }

    static func embeddings(defaults: UserDefaults) async throws -> (any TextEmbeddingProvider)? {
        guard defaults.bool(forKey: "semanticRetrieval") else { return nil }
        return OpenAIEmbeddings(apiKey: try await key("openai"),
                               model: defaults.string(forKey: "embeddingModel") ?? "text-embedding-3-small")
    }

    static func summarizer() async throws -> OpenAISessionSummarizer {
        OpenAISessionSummarizer(apiKey: try await key("openai"))
    }

    static func answerGenerator(defaults: UserDefaults, provider: TextProvider? = nil) async throws -> any TextGenerator {
        let answer = try provider ?? ProviderSelection.decode(defaults.string(forKey: "answerProvider"), default: TextProvider.openai)
        switch answer {
        case .openai:
            return OpenAITextGenerator(apiKey: try await key("openai"),
                model: defaults.string(forKey: "answerModel") ?? "gpt-4.1-mini",
                reasoning: reasoning(defaults, "openAIAnswerReasoning"))
        case .anthropic:
            return AnthropicTextGenerator(apiKey: try await key("anthropic"),
                model: defaults.string(forKey: "anthropicAnswerModel") ?? "claude-haiku-4-5",
                reasoning: reasoning(defaults, "anthropicAnswerReasoning"))
        case .chatGPT:
            guard let chatGPT else { throw PlanAuthorizationFailure.unavailable }
            return try await chatGPT.generator(model: defaults.string(forKey: "chatGPTAnswerModel") ?? "")
        }
    }

    private static func reasoning(_ defaults: UserDefaults, _ key: String) -> ReasoningEffort {
        defaults.string(forKey: key).flatMap(ReasoningEffort.init(rawValue:)) ?? .modelDefault
    }

    static func testTextProvider(_ service: ProviderService, defaults: UserDefaults, question: String) async throws -> String {
        let classification = service == .classification
        let provider = try ProviderSelection.decode(defaults.string(forKey: classification ? "classificationProvider" : "answerProvider"),
                                                    default: TextProvider.openai)
        if provider == .chatGPT {
            guard let chatGPT else { throw PlanAuthorizationFailure.unavailable }
            try await chatGPT.checkModel(defaults.string(forKey: classification ? "chatGPTQuestionModel" : "chatGPTAnswerModel") ?? "",
                service: service, guidance: defaults.string(forKey: "classificationInstructions") ?? "")
            return "The selected ChatGPT plan model passed its capability check."
        } else if classification {
            let classifier = try await questionClassifier(defaults: defaults, provider: provider)
            let source = CaptureSource(id: "Connection test", role: .interviewer)
            let start = ContinuousClock.now
            let result = try await classifier.classify(QuestionInput(
                turn: TranscriptEvent(source: source, epoch: UUID(), itemID: "test", text: question, state: .final),
                previousQuestions: []))
            guard result.decision == .accept, !result.parts.isEmpty else { throw ProviderFailure.unsupportedCapability }
            return "Structured answerable-question decision in \(milliseconds(since: start)) ms."
        } else {
            let generator = try await answerGenerator(defaults: defaults, provider: provider)
            let start = ContinuousClock.now
            var firstText: Int?
            for try await event in try await generator.stream(.init(question: question, instructions: "One sentence.", evidence: [])) {
                if case .text(let text) = event, firstText == nil, text.contains(where: { !$0.isWhitespace }) {
                    firstText = milliseconds(since: start)
                }
            }
            guard let firstText else { throw ProviderFailure.malformedEvent }
            return "Answer stream completed. First text \(firstText) ms, completion \(milliseconds(since: start)) ms."
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    var route: AudioRoutePreference = {
        guard let data = UserDefaults.standard.data(forKey: "audioRoute") else { return .init() }
        return (try? JSONDecoder().decode(AudioRoutePreference.self, from: data)) ?? .init()
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(route), forKey: "audioRoute") }
    }
    var processes: [AudioEndpointChoice] = []
    var microphones: [AudioEndpointChoice] = []
    var outputs: [AudioEndpointChoice] = []
    var replayURL: URL? {
        didSet { if oldValue != replayURL { replayAttribution = .unresolved } }
    }
    var replayAttribution: QuestionAudioAttribution = .unresolved
    private(set) var liveQuestionMode: QuestionAudioMode = .unresolved
    private(set) var liveQuestionChannel = WorkspaceAudioChannel.question
    private(set) var snapshot: InterviewSnapshot? {
        didSet {
            if state != snapshot?.state ?? .idle { state = snapshot?.state ?? .idle }
            if answerHistory != snapshot?.answers ?? [] { answerHistory = snapshot?.answers ?? [] }
            if transcriptHistory != snapshot?.transcript ?? [] { transcriptHistory = snapshot?.transcript ?? [] }
            if learnedContext != snapshot?.learnedContext ?? [] { learnedContext = snapshot?.learnedContext ?? [] }
            if speakers != snapshot?.speakers ?? [] { speakers = snapshot?.speakers ?? [] }
            if lastIssue != snapshot?.issues.last { lastIssue = snapshot?.issues.last }
        }
    }
    private(set) var state: LiveState = .idle
    private(set) var answerHistory: [InterviewAnswer] = []
    private(set) var transcriptHistory: [InterviewTranscript] = []
    private(set) var learnedContext: [LearnedContextItem] = []
    private(set) var speakers: [DiarizedSpeaker] = []
    private(set) var lastIssue: String?
    var error: String?
    var busy = false
    var testing = false
    var showAudioConfiguration = false
    var retainNextSession = false
    var testLevels: [String: Float] = [:]
    var profiles: [InterviewProfile] = []
    var profileID = UserDefaults.standard.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(profileID?.uuidString, forKey: "selectedProfileID") }
    }
    var selectedAnswer: UUID?
    var pinned = false
    var startedAt: Date?
    var endedAt: Date?
    var providerTest: String?
    var checkingProvider = false
    var configuredKeys: Set<String> = []
    private var keySettingsRevision = 0
    private(set) var chatGPTSnapshot: ChatGPTPlanAccounts.Snapshot?
    private(set) var chatGPTStatus: String?
    private(set) var chatGPTBusy = false
    private(set) var chatGPTCanCancel = false
    private(set) var sessionUsesChatGPT = false

    private(set) var store: KnowledgeStore?
    private var session: InterviewSession?
    private var recordID = UUID()
    private var sessionProfileName: String?
    private var observations: Task<Void, Never>?
    private var captureTest: Task<Void, Never>?
    private var chatGPTTask: Task<Void, Never>?

    var requestsSpeakerLabels: Bool {
        route.requiresSpeakerLabels || (route.question == .replay && replayAttribution == .speakerLabels)
    }

    private var selectedQuestionMode: QuestionAudioMode {
        let defaults = UserDefaults.standard
        let provider = SpeechProvider(rawValue: defaults.string(forKey: "speechProvider") ?? "") ?? .openai
        let model = switch provider {
        case .eleven: defaults.string(forKey: "elevenModel") ?? "scribe_v3_live"
        case .deepgram: defaults.string(forKey: "deepgramModel") ?? "nova-3"
        default: ""
        }
        return route.questionMode(speakerLabelsAvailable: ProviderCapabilities.describe(provider.provider, model: model).diarization,
                                  replayAttribution: replayAttribution)
    }
    var active: Bool { state.isRunning || [.pausing, .paused, .stopping, .failed].contains(state) }
    var startActionLabel: String? {
        switch state {
        case .idle, .stopped: "Start"
        case .paused: "Resume"
        default: nil
        }
    }
    var canStartOrResume: Bool { startActionLabel != nil && !busy && !testing && !chatGPTBusy }

    var answerModeLabel: String {
        switch active ? liveQuestionMode : selectedQuestionMode {
        case .trustedInterviewerOnly, .separateChannels: "Automatic answers"
        case .diarized: "Automatic after speaker assignment"
        case .unresolved: "Manual answers"
        }
    }

    var offersInterviewerOutputConfirmation: Bool {
        !active && route.canDesignateInterviewerOutput && route.outputAttribution == .unresolved
    }

    var questionMeterChannel: WorkspaceAudioChannel {
        active ? liveQuestionChannel : configuredQuestionChannel
    }

    private var configuredQuestionChannel: WorkspaceAudioChannel {
        route.question == .replay ? .replay : .question
    }

    func startWithConfirmedInterviewerOutput(_ confirmedRoute: AudioRoutePreference) {
        guard canStartOrResume, offersInterviewerOutputConfirmation, route == confirmedRoute else { return }
        route.outputAttribution = .interviewerOnly
        startOrResume()
    }

    var selectedProfileName: String { profiles.first { $0.id == profileID }?.name ?? "General practice" }

    var questionSourceLabel: String {
        switch route.question {
        case .application: processes.first { $0.id == route.applicationID }?.name ?? "Choose an application"
        case .outputDevice: outputs.first { $0.id == route.outputUID }?.name ?? "Choose an output device"
        case .interviewerMicrophone, .sharedMicrophone:
            microphones.first { $0.id == route.interviewerMicrophoneUID }?.name ?? "Choose a microphone"
        case .replay: replayURL?.lastPathComponent ?? "Choose a replay file"
        case .defaultOutput: "System default output"
        }
    }

    var candidateSourceLabel: String {
        guard route.candidateEnabled else { return "Off" }
        return microphones.first { $0.id == route.candidateMicrophoneUID }?.name ?? "Choose a microphone"
    }

    var microphoneReadiness: String? {
        guard route.candidateEnabled || route.question == .interviewerMicrophone || route.question == .sharedMicrophone else { return nil }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined: return "macOS will request microphone access when you start or test audio."
        default: return "Microphone access is unavailable. Check macOS Privacy & Security settings."
        }
    }

    var providerReadiness: String {
        let defaults = UserDefaults.standard
        let speech = SpeechProvider(rawValue: defaults.string(forKey: "speechProvider") ?? "") ?? .openai
        let textKeys = ["classificationProvider", "answerProvider"].map {
            TextProvider(rawValue: defaults.string(forKey: $0) ?? "") ?? .openai
        }
        if textKeys.contains(.chatGPT), !ChatGPTPlanEligibility.desktopAvailable { return "ChatGPT authorization unavailable" }
        let speechKey: String? = switch speech {
        case .apple: nil
        case .openai: "openai"
        case .eleven: "elevenlabs"
        case .deepgram: "deepgram"
        }
        let expected = textKeys.compactMap { value -> String? in
            switch value {
            case .openai: "openai"
            case .anthropic: "anthropic"
            case .chatGPT: nil
            }
        } + [speechKey].compactMap { $0 }
        if let missing = expected.first(where: { !configuredKeys.contains($0) }) {
            return "Add \(missing == "openai" ? "OpenAI" : missing.capitalized) key in Settings"
        }
        if speech == .apple {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .denied, .restricted: return "Speech Recognition is unavailable. Check macOS Privacy & Security."
            case .notDetermined: return "Speech Recognition permission required on Start"
            default: break
            }
        }
        return selectedQuestionMode == .unresolved ? "Configured · manual answers" : "Configured"
    }

    var displayedAnswer: InterviewAnswer? {
        if let selectedAnswer,
           let result = answerHistory.first(where: { $0.id == selectedAnswer }) { return result }
        return answerHistory.last
    }

    func load() async {
        #if DEBUG || M12_UI_FIXTURES
        if WorkspaceFixture.isEnabled {
            await loadFixture()
            return
        }
        #endif
        if store == nil {
            do {
                let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                    .appendingPathComponent("MockInterview", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let database = dir.appendingPathComponent("interviews.sqlite")
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                let opened = try KnowledgeStore(url: database)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
                store = opened
            } catch {
                self.error = "Local profile storage could not open."
            }
        }
        await reloadProfiles()
        reloadDevices()
        let revision = keySettingsRevision
        let accounts = await Task.detached { Keychain.configuredAccounts() }.value
        if revision == keySettingsRevision { configuredKeys = accounts }
    }

    func reloadDevices() {
        do {
            processes = try MacAudioDevices.processes()
            microphones = try MacAudioDevices.microphones()
            outputs = try MacAudioDevices.outputs()
        } catch {
            self.error = "macOS audio sources could not be listed."
        }
    }

    func reloadProfiles() async {
        do {
            profiles = try await store?.profiles() ?? []
            if !profiles.contains(where: { $0.id == profileID }) { profileID = nil }
        } catch {
            self.error = "Profiles could not be read."
        }
    }

    func saveKey(_ key: String, account: String) {
        guard !busy, !checkingProvider, !active else { return }
        busy = true
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                try await Keychain.providers.save(normalized, account: account)
                keySettingsRevision += 1
                if normalized.isEmpty { configuredKeys.remove(account) } else { configuredKeys.insert(account) }
                providerTest = nil
            } catch {
                self.error = "The provider key could not be updated in Keychain."
            }
        }
    }

    func checkProvider(_ service: ProviderService) {
        guard !checkingProvider, !active, !busy, !chatGPTBusy else { return }
        checkingProvider = true
        providerTest = "Checking \(service.rawValue)…"
        Task {
            defer { checkingProvider = false }
            do {
                let defaults = UserDefaults.standard
                let question = "What is a FIFO queue?"
                switch service {
                case .transcription:
                    let factory = try await SessionProviders.transcriptionFactory(defaults: defaults,
                                                                            diarize: requestsSpeakerLabels)
                    try await factory().testConnection()
                    providerTest = "Transcription provider acknowledged the connection."
                case .classification, .answer:
                    providerTest = try await SessionProviders.testTextProvider(service, defaults: defaults, question: question)
                case .embeddings:
                    guard let embeddings = try await SessionProviders.embeddings(defaults: defaults),
                          try await embeddings.embed([question]).first?.isEmpty == false else {
                        throw ProviderFailure.unsupportedCapability
                    }
                    providerTest = "The embedding model returned a vector."
                }
            } catch { providerTest = (error as? PlanAuthorizationFailure)?.errorDescription ?? publicErrorMessage(error) }
        }
    }

    func checkSessionContext(evaluation: Bool) {
        guard !checkingProvider, !active, !busy, !chatGPTBusy else { return }
        checkingProvider = true
        providerTest = evaluation ? "Checking evaluation…" : "Checking session summary…"
        Task {
            defer { checkingProvider = false }
            do {
                if evaluation {
                    let score = try await coaching(.init(question: "How would you preserve message order?",
                        candidateAnswer: "I would partition by customer and verify sequence numbers on retries."))
                    guard score.range(of: "relevance", options: .caseInsensitive) != nil else { throw ProviderFailure.malformedEvent }
                    providerTest = "Evaluation returned rubric feedback for a synthetic candidate answer."
                } else {
                    let summarizer = try await SessionProviders.summarizer()
                    let start = ContinuousClock.now
                    let result = try await summarizer.summarize([
                        .init(id: "one", role: .interviewer, text: "Which queue retains messages for Project Larch?"),
                        .init(id: "two", role: .candidate, text: "Project Larch uses a FIFO queue. I corrected the retention period to 14 days.")
                    ])
                    guard result.range(of: "Larch", options: .caseInsensitive) != nil else { throw ProviderFailure.malformedEvent }
                    providerTest = "Session summary returned in \(SessionProviders.milliseconds(since: start)) ms."
                }
            } catch { providerTest = publicErrorMessage(error) }
        }
    }

    func loadChatGPT() {
        guard chatGPTSnapshot == nil else { return }
        updateChatGPT { _ in }
    }

    func signInToChatGPT(_ id: UUID? = nil, requestConsent: Bool = false) {
        updateChatGPT(cancellable: true) { try await $0.signIn(account: id, requestConsent: requestConsent) }
    }

    func signOutOfChatGPT(_ id: UUID) {
        updateChatGPT { try await $0.signOut(account: id) }
    }

    func cancelChatGPTSignIn() { chatGPTTask?.cancel() }

    func refreshChatGPTModels() { updateChatGPT { _ in } }

    private func updateChatGPT(cancellable: Bool = false,
                              operation: @escaping (ChatGPTPlanAccounts) async throws -> Void) {
        guard let accounts = SessionProviders.chatGPT, !chatGPTBusy, !active, !busy, !checkingProvider else { return }
        chatGPTStatus = nil
        chatGPTBusy = true
        chatGPTCanCancel = cancellable
        chatGPTTask = Task {
            defer { chatGPTBusy = false; chatGPTCanCancel = false; chatGPTTask = nil }
            do {
                try await operation(accounts)
                let snapshot = try await accounts.snapshot()
                chatGPTSnapshot = snapshot
                if snapshot.accounts.first(where: { $0.id == snapshot.active })?.planEnabled == true {
                    try await accounts.refreshCatalog()
                    chatGPTSnapshot = try await accounts.snapshot()
                }
            } catch {
                chatGPTSnapshot = try? await accounts.snapshot()
                if !Task.isCancelled {
                    chatGPTStatus = (error as? PlanAuthorizationFailure)?.errorDescription ?? publicErrorMessage(error)
                }
            }
        }
    }

    func startOrResume() {
        guard canStartOrResume else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            if state == .paused, let session {
                await session.start()
                return
            }
            do {
                let options = UserDefaults.standard
                let diarize = requestsSpeakerLabels
                let providers = try await SessionProviders(defaults: options, diarize: diarize)
                let embedding = try? await SessionProviders.embeddings(defaults: options)
                let summarizer = options.bool(forKey: "summarizeSession") ? try? await SessionProviders.summarizer() : nil
                let contextConfiguration = SessionContextConfiguration(
                    mode: options.string(forKey: "interviewContextMode").flatMap(InterviewContextMode.init(rawValue:)) ?? .adaptive,
                    includesCandidate: options.object(forKey: "contextCandidate") as? Bool ?? true,
                    includesFeedback: options.object(forKey: "contextFeedback") as? Bool ?? true,
                    adaptsSpeakingStyle: options.bool(forKey: "contextSpeakingStyle"))
                let format = AnswerFormat(rawValue: options.string(forKey: "answerFormat") ?? "") ?? .brief
                let threshold = options.object(forKey: "questionThreshold") as? Double ?? 0.8
                let profile = profiles.first(where: { $0.id == profileID })
                sessionProfileName = profile?.name
                let store = self.store
                let channels = try makeChannels(providers.transcriber, sensitivity: providers.activityThreshold)
                let responseLanguage = (profile?.answerLanguage.isEmpty == false)
                    ? profile?.answerLanguage : options.string(forKey: "answerLanguage")
                let answerWords = options.integer(forKey: "answerWordLimit")
                let preferences = [
                    options.string(forKey: "answerInstructions") ?? "", profile?.instructions ?? "",
                    responseLanguage.map { $0.isEmpty ? "" : "Answer language: " + $0 } ?? ""
                ].joined(separator: "\n")
                let classificationBudget = ContextBudget(turns: options.object(forKey: "classifierContextTurns") as? Int ?? 12,
                                                         tokenBudget: options.object(forKey: "classifierContextBudget") as? Int ?? 3_000)
                let answerBudget = ContextBudget(turns: options.object(forKey: "answerContextTurns") as? Int ?? 12,
                                                 tokenBudget: options.object(forKey: "answerContextBudget") as? Int ?? 3_000)
                let seconds = options.object(forKey: "generationTimeout") as? Double ?? 45
                let timeout = seconds.isFinite ? min(45, max(5, seconds)) : 45
                let continuation = options.object(forKey: "completionGrace") as? Double ?? 3
                let grace = continuation.isFinite ? min(6, max(0.5, continuation)) : 3
                var context: [String] = []
                if let profile {
                    let role = [profile.role, profile.seniority, profile.industry].filter { !$0.isEmpty }
                    if !role.isEmpty { context.append("Target role: " + role.joined(separator: ", ")) }
                    let documents = (try? await store?.documents(profile: profile.id)) ?? []
                    let requirements = documents.lazy.filter { $0.kind == .jobDescription }.prefix(3)
                    context.append(contentsOf: requirements.map { "Job requirements: " + String($0.text.prefix(1_100)) })
                }
                let next = InterviewSession(
                    channels: channels,
                    detector: QuestionDetector(classifier: providers.classifier, threshold: threshold,
                                               completionGrace: .seconds(grace)),
                    generator: providers.generator, summarizer: summarizer, contextConfiguration: contextConfiguration,
                    format: format, preferences: preferences, interviewContext: context, answerWordLimit: answerWords,
                    profileTraining: profile?.answerTraining,
                    questionWait: Self.questionWaitDuration(options.object(forKey: "questionWaitSeconds") as? Double ?? 2),
                    classificationBudget: classificationBudget, answerBudget: answerBudget,
                    generationTimeout: .seconds(timeout), classificationEvidence: { question in
                        guard let store, let profile else { return [] }
                        return (try? await store.retrieve(question, profile: profile.id))?.map(\.promptText) ?? []
                    }, pastWorkEvidence: {
                        guard let store, let profile else { return [] }
                        return (try? await store.pastWorkExamples(profile: profile.id))?.map(\.promptText) ?? []
                    }, evidence: { question in
                        guard let store, let profile else { return [] }
                        if let embedding,
                           let facts = try? await store.hybridRetrieve(question, profile: profile.id, provider: embedding) {
                            return facts.map(\.promptText)
                        }
                        return (try? await store.retrieve(question, profile: profile.id))?.map(\.promptText) ?? []
                    }
                )
                observations?.cancel()
                session = next
                liveQuestionMode = selectedQuestionMode
                liveQuestionChannel = configuredQuestionChannel
                sessionUsesChatGPT = providers.usesChatGPT
                selectedAnswer = nil
                pinned = false
                recordID = UUID()
                startedAt = .now
                endedAt = nil
                let updates = await next.updates()
                observations = Task { [weak self] in
                    for await update in updates {
                        guard !Task.isCancelled else { return }
                        self?.snapshot = update
                    }
                }
                await next.start()
            } catch ProviderFailure.missingCredentials {
                error = "Add API keys for the selected providers in Settings before starting."
            } catch CaptureFailure.sourceUnavailable {
                error = "Select each required audio source before starting."
            } catch {
                self.error = (error as? PlanAuthorizationFailure)?.errorDescription ?? publicErrorMessage(error)
            }
        }
    }

    func prepareForSleep() {
        captureTest?.cancel()
        if state.isRunning { pause() }
    }

    func pause() {
        guard let session, state.isRunning, !busy else { return }
        busy = true
        Task {
            await session.pause()
            busy = false
        }
    }

    func stop() {
        guard active, !busy else { return }
        busy = true
        Task {
            await stopSession()
            busy = false
        }
    }

    func shutdownForTermination() async {
        chatGPTTask?.cancel()
        await chatGPTTask?.value
        captureTest?.cancel()
        await captureTest?.value
        await stopSession()
    }

    private func stopSession() async {
        guard let session, endedAt == nil else { return }
        await session.stop()
        guard endedAt == nil else { return }
        snapshot = await session.current()
        endedAt = .now
        if retainNextSession, let record = finishedRecord() {
            do {
                guard let store else { throw StorageFailure.invalidRecord }
                try await store.saveInterview(record)
            } catch {
                self.error = "The session could not be saved. Review it before clearing the workspace."
            }
        }
        retainNextSession = false
    }

    func finishedRecord() -> SavedInterview? {
        guard let snapshot, snapshot.state == .stopped, let startedAt, let endedAt else { return nil }
        return SavedInterview(id: recordID, title: "Mock interview", startedAt: startedAt, endedAt: endedAt,
                              transcript: snapshot.transcript, suggestions: snapshot.answers, profileName: sessionProfileName)
    }

    func coaching(_ input: CoachingInput) async throws -> String {
        let provider = try await SessionProviders.answerGenerator(defaults: .standard)
        var text = ""
        for try await event in try await provider.stream(input.request()) {
            if case .text(let fragment) = event {
                guard text.utf8.count + fragment.utf8.count <= 32_768 else { throw ProviderFailure.malformedEvent }
                text.append(fragment)
            }
        }
        try Task.checkCancellation()
        guard !text.isEmpty else { throw ProviderFailure.malformedEvent }
        return text
    }

    func clearSession() {
        guard !active, !busy else { return }
        observations?.cancel()
        observations = nil
        session = nil
        snapshot = nil
        selectedAnswer = nil
        pinned = false
        startedAt = nil
        endedAt = nil
    }

    func assignSpeaker(_ id: DiarizedSpeaker.ID, role: SourceRole) {
        Task { await session?.assignSpeaker(id, role: role) }
    }

    func responseVisible(_ revision: UUID) {
        Task { await session?.responseVisible(revision) }
    }

    func excludeContext(_ id: String, excluded: Bool) {
        Task { await session?.excludeLearnedContext(id, excluded: excluded) }
    }

    func correctContext(_ id: String, text: String) {
        Task { await session?.correctLearnedContext(id, text: text) }
    }

    func clearContext() { Task { await session?.clearLearnedContext() } }

    func updateQuestionWait(_ seconds: Double) {
        Task { await session?.setQuestionWait(Self.questionWaitDuration(seconds)) }
    }

    private static func questionWaitDuration(_ seconds: Double) -> Duration {
        .seconds(seconds.isFinite ? min(6, max(0, seconds)) : 2)
    }

    func cancelAnswer() {
        Task { await session?.cancelAnswer() }
    }

    func regenerate(_ format: AnswerFormat? = nil) {
        guard let id = displayedAnswer?.id else { return }
        regenerateAnswer(id, format: format)
    }

    func regenerateAnswer(_ id: UUID, format: AnswerFormat? = nil) {
        Task { await session?.regenerate(id, format: format) }
    }

    func manual(_ text: String) {
        if !pinned { selectedAnswer = nil }
        Task { await session?.manualQuestion(text) }
    }

    func moveAnswer(_ offset: Int) {
        guard let answers = snapshot?.answers, !answers.isEmpty else { return }
        let index = answers.firstIndex(where: { $0.id == displayedAnswer?.id }) ?? answers.count - 1
        selectedAnswer = answers[min(max(index + offset, 0), answers.count - 1)].id
    }

    func togglePin() {
        pinned.toggle()
        selectedAnswer = pinned ? displayedAnswer?.id : nil
    }

    func testSources() {
        if testing {
            captureTest?.cancel()
            return
        }
        guard !active, !busy else { return }
        do {
            let sources = try captureSources()
            error = nil
            testing = true
            captureTest = Task {
                defer {
                    testing = false
                    captureTest = nil
                    testLevels.removeAll()
                }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (source, audio) in sources {
                            group.addTask { [weak self] in
                                let stream = try await audio.start()
                                do {
                                    var meter = AudioEndpoint()
                                    for try await frame in stream {
                                        try Task.checkCancellation()
                                        let level = meter.observe(frame).level
                                        await self?.displayTestLevel(level, source: source.id)
                                    }
                                    await audio.stop()
                                } catch {
                                    await audio.stop()
                                    throw error
                                }
                            }
                        }
                        group.addTask {
                            // Allow the OS permission and HAL startup deadlines to report their errors.
                            try await Task.sleep(for: .seconds(22))
                            await self.finishAudioTestIfMissingFrames(expected: sources.map { $0.0.id })
                            throw CancellationError()
                        }
                        while try await group.next() != nil {}
                    }
                } catch is CancellationError {
                } catch {
                    self.error = publicErrorMessage(error)
                }
            }
        } catch {
            self.error = publicErrorMessage(error)
        }
    }

    private func displayTestLevel(_ level: Float, source: String) { testLevels[source] = level }

    private func finishAudioTestIfMissingFrames(expected: [String]) {
        if expected.contains(where: { testLevels[$0] == nil }) {
            error = "The audio test did not receive frames from every selected source. Check source availability and macOS Privacy & Security."
        }
    }

    private func makeChannels(_ transcriber: @escaping @Sendable () -> any StreamingSTT, sensitivity: Float) throws -> [TranscriptionChannel] {
        try captureSources().map { source, audio in
            TranscriptionChannel(source: source, audio: audio, threshold: sensitivity,
                                 replay: source.id == WorkspaceAudioChannel.replay.rawValue, makeSTT: transcriber)
        }
    }

    func applySources() {
        guard let session, active, !busy, !testing else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let options = UserDefaults.standard
                let sensitivity = SessionProviders.audioActivityThreshold(defaults: options)
                let speech = try await SessionProviders.transcriptionFactory(defaults: options,
                    diarize: requestsSpeakerLabels, activityThreshold: sensitivity)
                let channels = try makeChannels(speech, sensitivity: sensitivity)
                liveQuestionMode = selectedQuestionMode
                liveQuestionChannel = configuredQuestionChannel
                await session.replaceChannels(channels)
            } catch {
                self.error = publicErrorMessage(error)
            }
        }
    }

    private func captureSources() throws -> [(CaptureSource, any AudioSource)] {
        try route.validateConcurrentMicrophones()
        func required(_ value: String?) throws -> String {
            guard let value else { throw CaptureFailure.sourceUnavailable }
            return value
        }
        let question = CaptureSource(id: configuredQuestionChannel.rawValue, role: selectedQuestionMode.questionRole)
        let audio: any AudioSource
        switch route.question {
        case .defaultOutput: audio = MacAudioSource(source: question, input: .output(uid: nil))
        case .outputDevice:
            audio = MacAudioSource(source: question, input: .output(uid: try required(route.outputUID)))
        case .application:
            audio = MacAudioSource(source: question, input: .application(group: try required(route.applicationID)))
        case .interviewerMicrophone, .sharedMicrophone:
            audio = MacAudioSource(source: question, input: .microphone(uid: try required(route.interviewerMicrophoneUID)))
        case .replay:
            guard let replayURL else { throw CaptureFailure.sourceUnavailable }
            let accessed = replayURL.startAccessingSecurityScopedResource()
            defer { if accessed { replayURL.stopAccessingSecurityScopedResource() } }
            let size = try replayURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 24_000_000 else { throw CaptureFailure.invalidFormat }
            audio = PCMReplaySource(source: question, pcm: try Data(contentsOf: replayURL))
        }
        var result = [(question, audio)]
        if route.candidateEnabled {
            let candidate = CaptureSource(id: WorkspaceAudioChannel.candidate.rawValue, role: .candidate)
            result.append((candidate, MacAudioSource(source: candidate,
                          input: .microphone(uid: try required(route.candidateMicrophoneUID)))))
        }
        return result
    }

}

#if DEBUG || M12_UI_FIXTURES
extension WorkspaceModel {
    private func loadFixture() async {
        guard store == nil, let fixture = try? KnowledgeStore() else { return }
        store = fixture
        var profile = WorkspaceFixture.profile
        profile.modifiedAt = .now
        profile.professionalSummary = "Platform engineer focused on reliable queues, observability, and release safety."
        profile.answerTraining = .init(skills: "Swift, SQL, Linux, observability", speakingSample: "I start with the observable result.")
        let resume = ProfileDocument(kind: .resume, title: "Jordan Ellis — résumé.md", text: "Built an internal queue monitor for a synthetic project.")
        try? await fixture.save(profile)
        try? await fixture.add(resume, to: profile.id)
        try? await fixture.save(.init(category: ExperienceFact.projectStoryCategory,
            claim: "Project: Cedar replay\nSource: Queue\nDestination: Test ledger\nTechnologies: SQL\nWhat I did: Implemented dry-runs.\nOutcome: Replays were auditable.",
            status: .confirmed), profile: profile.id)
        try? await fixture.save(.init(claim: "External production rollout", status: .rejected), profile: profile.id)
        try? await fixture.saveInterview(.init(title: "Platform reliability rehearsal", startedAt: .now.addingTimeInterval(-1150),
            endedAt: .now.addingTimeInterval(-320), transcript: [
                .init(id: "review/q", role: .interviewer, text: "How would you verify ordering after a restart?", isFinal: true),
                .init(id: "review/a", role: .candidate, text: "I would inspect the checkpoint before replaying messages.", isFinal: true)
            ], suggestions: [], coaching: "Separate broker order from processing order. Add a duplicate-event check.", profileName: profile.name))
        profiles = [profile]
        profileID = profile.id
        configuredKeys = ["openai"]
        let question = FixtureRecognition(), candidate = FixtureRecognition()
        let next = InterviewSession(channels: [
            .init(source: .init(id: WorkspaceAudioChannel.question.rawValue, role: .interviewer), audio: FixtureAudio(), makeSTT: { question }),
            .init(source: .init(id: WorkspaceAudioChannel.candidate.rawValue, role: .candidate), audio: FixtureAudio(), makeSTT: { candidate })
        ], detector: .init(classifier: FixtureClassifier()), generator: FixtureAnswer(), format: .technical,
            evidence: { _ in ["Cedar replay project — implemented dry-runs and reviewed audit output."] })
        session = next
        startedAt = .now
        liveQuestionMode = .separateChannels
        let stream = await next.updates()
        observations = Task { [weak self] in
            for await value in stream { self?.snapshot = value }
        }
        await next.start()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await candidate.send("The Cedar project used a replay ledger. Correction: ordering was per key.", id: "candidate-1")
            try? await Task.sleep(for: .milliseconds(850))
            for (index, text) in ["How would you recover an interrupted queue?",
                "Which metric would make you stop the rollout?", "How would you verify message order after a restart?"].enumerated() {
                await question.send(text, id: "question-\(index)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    #if M12_UI_FIXTURES
    func seedChatLoad() {
        guard state.isRunning, let session else { return }
        Task { @MainActor [weak self] in
            for index in 1...200 {
                guard self?.session === session, await session.current().state.isRunning else { return }
                await session.manualQuestion("Load fixture \(index): How would you verify that checkpoint recovery is safe?")
                for _ in 0..<50 {
                    let state = await session.current()
                    if !state.state.isRunning || state.answers.last?.state == .complete { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
    }
    #endif
}
#endif
