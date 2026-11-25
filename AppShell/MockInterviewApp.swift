import AppKit
import ConversationCore
import Security
import SwiftUI
import UniformTypeIdentifiers

@main
struct MockInterviewApp: App {
    @StateObject private var model = WorkspaceModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("pauseShortcut") private var pauseShortcut = "p"
    @AppStorage("compactShortcut") private var compactShortcut = "k"

    var body: some Scene {
        WindowGroup("Mock Interview", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 850, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandMenu("Interview") {
                Button("Start or Resume") { model.startOrResume() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Pause") { model.pause() }
                    .keyboardShortcut(KeyEquivalent(pauseShortcut.first ?? "p"), modifiers: [.command, .shift])
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Show Compact Window") { openWindow(id: "compact") }
                    .keyboardShortcut(KeyEquivalent(compactShortcut.first ?? "k"), modifiers: [.command, .shift])
            }
        }

        Window("Compact Answer", id: "compact") {
            CompactView(model: model)
                .frame(minWidth: 300, minHeight: 210)
        }
        .defaultSize(width: 430, height: 285)

        Window("Solo Practice", id: "solo") {
            SoloPracticeView(model: model)
                .frame(minWidth: 560, minHeight: 430)
        }

        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 530, height: 665)
        }
    }
}

private enum Keychain {
    static let service = "com.mockinterview.desktop"

    static func load(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) throws {
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

private enum SpeechProvider: String, CaseIterable, Identifiable {
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

private enum TextProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    var id: String { rawValue }
    var provider: ProviderID { self == .openai ? .openai : .anthropic }
}

private struct SessionProviders {
    let transcriber: @Sendable () -> any StreamingSTT
    let classifier: any QuestionClassifier
    let generator: any TextGenerator

    init(defaults: UserDefaults, diarize: Bool = false) throws {
        transcriber = try Self.transcriptionFactory(defaults: defaults, diarize: diarize)
        classifier = try Self.questionClassifier(defaults: defaults)
        generator = try Self.answerGenerator(defaults: defaults)
    }

    private static func key(_ account: String) throws -> String {
        guard let value = Keychain.load(account), !value.isEmpty else { throw ProviderFailure.missingCredentials }
        return value
    }

    static func transcriptionFactory(defaults: UserDefaults, diarize: Bool = false) throws
        -> @Sendable () -> any StreamingSTT {
        let speech = SpeechProvider(rawValue: defaults.string(forKey: "speechProvider") ?? "") ?? .openai
        let language = defaults.string(forKey: "sttLanguage")
        let vocabulary = (defaults.string(forKey: "speechVocabulary") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch speech {
        case .apple:
            let locale = defaults.string(forKey: "appleSpeechLocale") ?? "en-US"
            let mode = AppleRecognitionMode(rawValue: defaults.string(forKey: "appleSpeechMode") ?? "") ?? .onDevice
            return { AppleSpeechTranscriber(locale: locale, mode: mode, vocabulary: vocabulary) }
        case .eleven:
            let credential = try key("elevenlabs")
            let model = defaults.string(forKey: "elevenModel") ?? "scribe_v3_live"
            let strategy = TranscriptionCommitStrategy(rawValue: defaults.string(forKey: "elevenCommit") ?? "") ?? .manual
            let config = ElevenLabsSpeechConfiguration(
                model: model, language: language, detectLanguage: defaults.object(forKey: "elevenDetectLanguage") as? Bool ?? true,
                strategy: strategy, silenceSeconds: defaults.object(forKey: "sttEndpoint") as? Double ?? 0.65,
                vocabulary: vocabulary)
            return { ElevenLabsTranscriber(apiKey: credential, configuration: config) }
        case .openai:
            let credential = try key("openai")
            let model = defaults.string(forKey: "sttModel") ?? "gpt-live-transcribe"
            return { OpenAIRealtimeTranscriber(apiKey: credential, model: model, language: language, vocabulary: vocabulary) }
        case .deepgram:
            let credential = try key("deepgram")
            let model = defaults.string(forKey: "deepgramModel") ?? "nova-3"
            let seconds = defaults.object(forKey: "sttEndpoint") as? Double ?? 0.65
            let endpoint = Int(min(3, max(0.1, seconds.isFinite ? seconds : 0.65)) * 1_000)
            return {
                DeepgramTranscriber(apiKey: credential, model: model, language: language, diarize: diarize,
                                    endpointMilliseconds: endpoint, vocabulary: vocabulary)
            }
        }
    }

    static func questionClassifier(defaults: UserDefaults) throws -> any QuestionClassifier {
        let provider = TextProvider(rawValue: defaults.string(forKey: "classificationProvider") ?? "") ?? .openai
        let instructions = defaults.string(forKey: "classificationInstructions") ?? ""
        switch provider {
        case .openai:
            return OpenAIQuestionClassifier(apiKey: try key("openai"),
                model: defaults.string(forKey: "questionModel") ?? "gpt-4.1-mini", guidance: instructions)
        case .anthropic:
            return AnthropicQuestionClassifier(apiKey: try key("anthropic"),
                model: defaults.string(forKey: "anthropicQuestionModel") ?? "claude-haiku-4-5", guidance: instructions)
        }
    }

    static func embeddings(defaults: UserDefaults) throws -> (any TextEmbeddingProvider)? {
        guard defaults.bool(forKey: "semanticRetrieval") else { return nil }
        return OpenAIEmbeddings(apiKey: try key("openai"),
                               model: defaults.string(forKey: "embeddingModel") ?? "text-embedding-3-small")
    }

    static func answerGenerator(defaults: UserDefaults) throws -> any TextGenerator {
        let answer = TextProvider(rawValue: defaults.string(forKey: "answerProvider") ?? "") ?? .openai
        switch answer {
        case .openai:
            return OpenAITextGenerator(apiKey: try key("openai"),
                                       model: defaults.string(forKey: "answerModel") ?? "gpt-4.1-mini")
        case .anthropic:
            return AnthropicTextGenerator(apiKey: try key("anthropic"),
                model: defaults.string(forKey: "anthropicAnswerModel") ?? "claude-haiku-4-5")
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var route: AudioRoutePreference = {
        guard let data = UserDefaults.standard.data(forKey: "audioRoute") else { return .init() }
        return (try? JSONDecoder().decode(AudioRoutePreference.self, from: data)) ?? .init()
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(route), forKey: "audioRoute") }
    }
    @Published var processes: [AudioEndpointChoice] = []
    @Published var microphones: [AudioEndpointChoice] = []
    @Published var outputs: [AudioEndpointChoice] = []
    @Published var replayURL: URL?
    @Published var snapshot: InterviewSnapshot?
    @Published var error: String?
    @Published var busy = false
    @Published var testing = false
    @Published var retainNextSession = false
    @Published var testLevels: [String: Float] = [:]
    @Published var profiles: [InterviewProfile] = []
    @Published var profileID: UUID?
    @Published var selectedAnswer: UUID?
    @Published var pinned = false
    @Published var startedAt: Date?
    @Published var endedAt: Date?
    @Published var providerTest: String?
    @Published var checkingProvider = false
    @Published var configuredKeys = Set(["openai", "deepgram", "anthropic", "elevenlabs"].filter { Keychain.load($0) != nil })

    private(set) var store: KnowledgeStore?
    private var session: InterviewSession?
    private var recordID = UUID()
    private var observations: Task<Void, Never>?
    private var captureTest: Task<Void, Never>?

    var state: InterviewSnapshot.State { snapshot?.state ?? .idle }
    var active: Bool { state.isRunning || [.pausing, .paused, .stopping, .failed].contains(state) }
    var displayedAnswer: InterviewAnswer? {
        if let selectedAnswer,
           let result = snapshot?.answers.first(where: { $0.id == selectedAnswer }) { return result }
        return snapshot?.answers.last
    }

    func load() async {
        if store == nil {
            do {
                let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                    .appendingPathComponent("MockInterview", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                store = try KnowledgeStore(url: dir.appendingPathComponent("interviews.sqlite"))
            } catch {
                self.error = "Local profile storage could not open."
            }
        }
        await reloadProfiles()
        reloadDevices()
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
        do {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try Keychain.save(normalized, account: account)
            if normalized.isEmpty { configuredKeys.remove(account) } else { configuredKeys.insert(account) }
            providerTest = nil
        } catch {
            self.error = "The provider key could not be updated in Keychain."
        }
    }

    func checkProvider(_ service: ProviderService) {
        guard !checkingProvider, !active else { return }
        checkingProvider = true
        providerTest = "Checking \(service.rawValue)…"
        Task {
            defer { checkingProvider = false }
            do {
                let defaults = UserDefaults.standard
                let question = "What is a FIFO queue?"
                switch service {
                case .transcription:
                    let factory = try SessionProviders.transcriptionFactory(defaults: defaults,
                                                                            diarize: route.question == .sharedMicrophone)
                    try await factory().testConnection()
                    providerTest = "Transcription provider acknowledged the connection."
                case .classification:
                    let classifier = try SessionProviders.questionClassifier(defaults: defaults)
                    let source = CaptureSource(id: "Connection test", role: .interviewer)
                    let result = try await classifier.classify(QuestionInput(
                        turn: TranscriptEvent(source: source, epoch: UUID(), itemID: "test",
                                              text: question, state: .final), previousQuestions: []))
                    guard result.decision == .accept, !result.parts.isEmpty else { throw ProviderFailure.unsupportedCapability }
                    providerTest = "The classifier returned a structured answerable-question decision."
                case .answer:
                    let generator = try SessionProviders.answerGenerator(defaults: defaults)
                    for try await _ in try await generator.stream(.init(question: question, instructions: "One sentence.", evidence: [])) {}
                    providerTest = "The selected answer model completed a text stream."
                case .embeddings:
                    guard let embeddings = try SessionProviders.embeddings(defaults: defaults),
                          try await embeddings.embed([question]).first?.isEmpty == false else {
                        throw ProviderFailure.unsupportedCapability
                    }
                    providerTest = "The embedding model returned a vector."
                }
            } catch { providerTest = publicErrorMessage(error) }
        }
    }

    func startOrResume() {
        guard !busy, !testing, !state.isRunning else { return }
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
                let diarize = route.question == .sharedMicrophone
                let providers = try SessionProviders(defaults: options, diarize: diarize)
                let embedding = try? SessionProviders.embeddings(defaults: options)
                let format = AnswerFormat(rawValue: options.string(forKey: "answerFormat") ?? "") ?? .brief
                let threshold = options.object(forKey: "questionThreshold") as? Double ?? 0.8
                let sensitivity = Float(options.object(forKey: "vadThreshold") as? Double ?? 0.015)
                let profile = profiles.first(where: { $0.id == profileID })
                let store = self.store
                let channels = try makeChannels(providers.transcriber, sensitivity: sensitivity)
                let responseLanguage = (profile?.answerLanguage.isEmpty == false)
                    ? profile?.answerLanguage : options.string(forKey: "answerLanguage")
                let answerWords = options.integer(forKey: "answerWordLimit")
                let preferences = [
                    options.string(forKey: "answerInstructions") ?? "", profile?.instructions ?? "",
                    responseLanguage.map { $0.isEmpty ? "" : "Answer language: " + $0 } ?? "",
                    answerWords > 0 ? "Use no more than \(answerWords) words." : ""
                ].joined(separator: "\n")
                let classificationBudget = ContextBudget(turns: options.object(forKey: "classifierContextTurns") as? Int ?? 12,
                                                         tokenBudget: options.object(forKey: "classifierContextBudget") as? Int ?? 3_000)
                let answerBudget = ContextBudget(turns: options.object(forKey: "answerContextTurns") as? Int ?? 12,
                                                 tokenBudget: options.object(forKey: "answerContextBudget") as? Int ?? 3_000)
                let timeout = options.object(forKey: "generationTimeout") as? Double ?? 45
                let grace = options.object(forKey: "completionGrace") as? Double ?? 3
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
                    generator: providers.generator,
                    format: format, preferences: preferences, interviewContext: context,
                    classificationBudget: classificationBudget, answerBudget: answerBudget,
                    generationTimeout: .seconds(timeout), classificationEvidence: { question in
                        guard let store, let profile else { return [] }
                        return (try? await store.retrieve(question, profile: profile.id))?.map(\.promptText) ?? []
                    }
                ) { question in
                    guard let store, let profile else { return [] }
                    if let embedding,
                       let facts = try? await store.hybridRetrieve(question, profile: profile.id, provider: embedding) {
                        return facts.map(\.promptText)
                    }
                    return (try? await store.retrieve(question, profile: profile.id))?.map(\.promptText) ?? []
                }
                observations?.cancel()
                session = next
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
                self.error = publicErrorMessage(error)
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
        guard let session, active, !busy else { return }
        busy = true
        Task {
            await session.stop()
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
            busy = false
        }
    }

    func finishedRecord() -> SavedInterview? {
        guard let snapshot, snapshot.state == .stopped, let startedAt, let endedAt else { return nil }
        return SavedInterview(id: recordID, title: "Mock interview", startedAt: startedAt, endedAt: endedAt,
                              transcript: snapshot.transcript, suggestions: snapshot.answers)
    }

    func coaching(_ input: CoachingInput) async throws -> String {
        let provider = try SessionProviders.answerGenerator(defaults: .standard)
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

    func cancelAnswer() {
        Task { await session?.cancelAnswer() }
    }

    func regenerate(_ format: AnswerFormat? = nil) {
        guard let id = displayedAnswer?.id else { return }
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
                            try await Task.sleep(for: .seconds(8))
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

    private func makeChannels(_ transcriber: @escaping @Sendable () -> any StreamingSTT, sensitivity: Float) throws -> [TranscriptionChannel] {
        try captureSources().map { source, audio in
            TranscriptionChannel(source: source, audio: audio, threshold: sensitivity,
                                 replay: source.id == "Replay", makeSTT: transcriber)
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
                let speech = try SessionProviders.transcriptionFactory(defaults: options, diarize: route.question == .sharedMicrophone)
                let sensitivity = Float(options.object(forKey: "vadThreshold") as? Double ?? 0.015)
                let channels = try makeChannels(speech, sensitivity: sensitivity)
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
        let question = CaptureSource(id: route.question == .replay ? "Replay" : "Question",
                                     role: route.question == .sharedMicrophone ? .unknown : .interviewer)
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
            let candidate = CaptureSource(id: "Candidate microphone", role: .candidate)
            result.append((candidate, MacAudioSource(source: candidate,
                          input: .microphone(uid: try required(route.candidateMicrophoneUID)))))
        }
        return result
    }

}

private struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var profileEditor = false
    @State private var replayPicker = false
    @State private var showDiagnostics = false
    @State private var showReview = false
    @State private var manualText = ""
    @AppStorage("answerFontSize") private var fontSize = 16.0
    @AppStorage("speechProvider") private var speechProvider = SpeechProvider.openai

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let issue = model.snapshot?.issues.last {
                Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if model.active {
                DisclosureGroup("Audio Sources") { sourceSetup }
            } else {
                sourceSetup
            }
            HSplitView {
                transcript.frame(minWidth: 245, idealWidth: 360)
                AnswerPanel(model: model, fontSize: fontSize).frame(minWidth: 360, maxWidth: .infinity)
            }
            HStack {
                TextField("Ask an interview question manually", text: $manualText)
                    .onSubmit(submit)
                Button("Generate", action: submit).disabled(manualText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!model.state.isRunning)
        }
        .padding(18)
        .task { await model.load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            model.prepareForSleep()
        }
        .sheet(isPresented: $profileEditor) {
            if let store = model.store {
                ProfileEditor(model: model, store: store)
                    .frame(minWidth: 670, minHeight: 545)
            }
        }
        .sheet(isPresented: $showReview) {
            if let store = model.store {
                InterviewReviewView(model: model, store: store, current: model.finishedRecord())
                    .frame(minWidth: 850, minHeight: 620)
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading) {
                Text("Session Diagnostics").font(.headline)
                Text(model.snapshot?.diagnosticSummary ?? "No session is active.").textSelection(.enabled)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.snapshot?.diagnosticSummary ?? "", forType: .string)
                    }
                    Spacer()
                    Button("Done") { showDiagnostics = false }
                }
            }.padding(18).frame(minWidth: 340)
        }
        .fileImporter(isPresented: $replayPicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.replayURL = url }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Mock Interview").font(.title2.weight(.semibold))
            Text(model.state.rawValue.capitalized).foregroundStyle(.secondary)
            if let start = model.startedAt {
                if let end = model.endedAt {
                    Text(end.timeIntervalSince(start).formatted(.number.precision(.fractionLength(0))) + " s")
                        .monospacedDigit()
                } else {
                    Text(start, style: .timer).monospacedDigit().accessibilityLabel("Elapsed time")
                }
            }
            Spacer()
            Button("Profiles") { profileEditor = true }.disabled(model.store == nil || model.active)
            SettingsLink { Label("Settings", systemImage: "gear") }
            Button("Compact") { openWindow(id: "compact") }
            Menu("Session") {
                Button("Review and History") { showReview = true }.disabled(model.active || model.store == nil)
                Button("Solo Practice") { openWindow(id: "solo") }
                Button("Diagnostics") { showDiagnostics = true }
                Button("Clear Session", action: model.clearSession).disabled(model.active || model.snapshot == nil)
            }
            if model.state.isRunning {
                Button("Pause", action: model.pause)
            } else {
                Button(model.state == .paused ? "Resume" : "Start", action: model.startOrResume)
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.testing)
            }
            if model.active { Button("Stop", action: model.stop).disabled(model.busy) }
        }
    }

    private var sourceSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Profile", selection: $model.profileID) {
                    Text("General practice").tag(UUID?.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Question audio", selection: $model.route.question) {
                    ForEach(QuestionAudioKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Refresh Sources", action: model.reloadDevices)
            }
            HStack {
                switch model.route.question {
                case .defaultOutput:
                    Text("Follows the macOS default output route.").font(.caption)
                case .outputDevice:
                    sourcePicker("Output", choices: model.outputs, selection: $model.route.outputUID)
                case .application:
                    sourcePicker("Application", choices: model.processes, selection: $model.route.applicationID)
                case .interviewerMicrophone, .sharedMicrophone:
                    sourcePicker("Question microphone", choices: model.microphones,
                                 selection: $model.route.interviewerMicrophoneUID)
                case .replay:
                    Button(model.replayURL?.lastPathComponent ?? "Choose 24 kHz mono PCM16 file") {
                        replayPicker = true
                    }
                }
                Toggle("Candidate microphone", isOn: $model.route.candidateEnabled)
                if model.route.candidateEnabled {
                    sourcePicker("Candidate input", choices: model.microphones,
                                 selection: $model.route.candidateMicrophoneUID)
                }
            }
            HStack {
                if model.active {
                    Button("Apply Audio Sources", action: model.applySources).disabled(model.busy)
                } else {
                    Button(model.testing ? "End Audio Test" : "Test Audio", action: model.testSources)
                    Toggle("Save a local copy when this session stops", isOn: $model.retainNextSession)
                }
            }
            if model.route.question == .sharedMicrophone && speechProvider != .deepgram {
                Text("Shared audio stays unknown unless the transcription provider supplies speaker labels. Select Deepgram to assign roles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.route.question == .application {
                Text("A browser process may include audio from multiple tabs.").font(.caption).foregroundStyle(.secondary)
            }
            if model.route.candidateEnabled {
                Text("Use headphones to reduce audio leakage into the candidate microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.testLevels.keys.sorted(), id: \.self) { source in
                ProgressView(value: Double(model.testLevels[source] ?? 0)) { Text(source) }
            }
        }
    }

    private func sourcePicker(_ label: String, choices: [AudioEndpointChoice],
                              selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("Select a source").tag(String?.none)
            if let saved = selection.wrappedValue, !choices.contains(where: { $0.id == saved }) {
                Text("Previously selected source unavailable").tag(Optional(saved))
            }
            ForEach(choices) { item in
                Text(item.name + (item.canTap || label != "Output" ? "" : " (multistream, unsupported)"))
                    .tag(Optional(item.id))
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading) {
            Text("Transcript").font(.headline)
            if let snapshot = model.snapshot {
                ForEach(snapshot.sources.keys.sorted(), id: \.self) { source in
                    ProgressView(value: Double(snapshot.levels[source] ?? 0)) {
                        Text(source + " · " + (snapshot.sources[source]?.rawValue.capitalized ?? "Idle"))
                    }
                }
                ForEach(snapshot.speakers) { speaker in
                    Picker("Speaker \(speaker.id.number)", selection: Binding(
                        get: { speaker.role },
                        set: { model.assignSpeaker(speaker.id, role: $0) }
                    )) {
                        ForEach(SourceRole.allCases, id: \.self) { role in Text(role.rawValue.capitalized).tag(role) }
                    }
                }
                List(snapshot.transcript) { turn in
                    VStack(alignment: .leading) {
                        Text([turn.speaker.map { "Speaker \($0)" }, turn.role.rawValue.capitalized,
                              turn.isFinal ? nil : "Partial"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(turn.text).textSelection(.enabled)
                        if turn.isFinal && model.state.isRunning {
                            Button("Use as question") { manualText = turn.text }.buttonStyle(.link)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
    }

    private func submit() {
        model.manual(manualText)
        manualText = ""
    }
}

private struct AnswerPanel: View {
    @ObservedObject var model: WorkspaceModel
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggested answer").font(.headline)
                Spacer()
                Button { model.moveAnswer(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous answer")
                Button { model.moveAnswer(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next answer")
                Button(model.pinned ? "Unpin" : "Pin", action: model.togglePin)
                    .disabled(model.displayedAnswer == nil)
            }
            if let answer = model.displayedAnswer {
                Text(answer.question.original).font(.title3.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(answer.text).font(.system(size: fontSize)).textSelection(.enabled)
                            .onChange(of: answer.text, initial: true) { _, value in
                                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    model.responseVisible(answer.revision)
                                }
                            }
                        if !answer.evidence.isEmpty {
                            DisclosureGroup("Approved evidence") {
                                ForEach(Array(answer.evidence.enumerated()), id: \.offset) { _, fact in
                                    Text(fact).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(answer.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                if let failure = answer.failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                if let usage = answer.usage {
                    Text("\(usage.input) input / \(usage.output) output tokens")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if answer.state == .generating {
                        Button("Cancel", action: model.cancelAnswer)
                    }
                    Button(answer.state == .failed ? "Retry" : "Regenerate") { model.regenerate() }
                    Menu("Format") {
                        ForEach(AnswerFormat.allCases) { format in
                            Button(format.rawValue) { model.regenerate(format) }
                        }
                    }
                }.disabled(!model.state.isRunning)
            } else {
                Text("Accepted questions and suggested answers will appear here.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.leading, 8)
    }
}

private struct CompactView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("compactOnTop") private var onTop = false
    @AppStorage("answerFontSize") private var fontSize = 16.0

    var body: some View {
        VStack {
            AnswerPanel(model: model, fontSize: fontSize)
            HStack {
                Toggle("Always on Top", isOn: $onTop)
                Spacer()
                Button("Expand") { openWindow(id: "workspace") }
                if model.state.isRunning { Button("Pause", action: model.pause) }
                if model.active { Button("Stop", action: model.stop) }
            }
            .font(.caption)
        }
        .padding(12)
        .background(WindowLevel(floating: onTop))
    }
}

private struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in view?.window?.level = floating ? .floating : .normal }
    }
}

private struct ProviderSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage("speechProvider") private var speech = SpeechProvider.openai
    @AppStorage("appleSpeechLocale") private var appleLocale = "en-US"
    @AppStorage("appleSpeechMode") private var appleMode = AppleRecognitionMode.onDevice
    @AppStorage("speechVocabulary") private var speechVocabulary = ""
    @AppStorage("elevenModel") private var elevenModel = "scribe_v3_live"
    @AppStorage("elevenCommit") private var elevenCommit = TranscriptionCommitStrategy.manual
    @AppStorage("elevenDetectLanguage") private var elevenDetectLanguage = true
    @AppStorage("sttEndpoint") private var sttEndpoint = 0.65
    @AppStorage("classificationProvider") private var classification = TextProvider.openai
    @AppStorage("answerProvider") private var answer = TextProvider.openai
    @AppStorage("deepgramModel") private var deepgramModel = "nova-3"
    @AppStorage("anthropicQuestionModel") private var anthropicQuestionModel = "claude-haiku-4-5"
    @AppStorage("anthropicAnswerModel") private var anthropicAnswerModel = "claude-haiku-4-5"
    @AppStorage("sttModel") private var sttModel = "gpt-live-transcribe"
    @AppStorage("questionModel") private var questionModel = "gpt-4.1-mini"
    @AppStorage("answerModel") private var answerModel = "gpt-4.1-mini"
    @AppStorage("sttLanguage") private var sttLanguage = ""
    @AppStorage("answerFormat") private var format = AnswerFormat.brief
    @AppStorage("answerInstructions") private var instructions = ""
    @AppStorage("vadThreshold") private var vad = 0.015
    @AppStorage("questionThreshold") private var confidence = 0.8
    @AppStorage("answerFontSize") private var fontSize = 16.0
    @AppStorage("semanticRetrieval") private var semanticRetrieval = false
    @AppStorage("embeddingModel") private var embeddingModel = "text-embedding-3-small"
    @AppStorage("pauseShortcut") private var pauseShortcut = "p"
    @AppStorage("compactShortcut") private var compactShortcut = "k"

    @AppStorage("classificationInstructions") private var questionInstructions = ""
    @AppStorage("classifierContextBudget") private var classifierBudget = 3_000
    @AppStorage("classifierContextTurns") private var classifierTurns = 12
    @AppStorage("answerContextBudget") private var answerBudget = 3_000
    @AppStorage("answerContextTurns") private var answerTurns = 12
    @AppStorage("completionGrace") private var completionGrace = 3.0
    @AppStorage("generationTimeout") private var generationTimeout = 45.0
    @AppStorage("answerLanguage") private var answerLanguage = ""
    @AppStorage("answerWordLimit") private var answerWordLimit = 0
    @AppStorage("providerPresets") private var storedPresets = Data()
    @State private var presets: [ProviderPreset] = []
    @State private var selectedPreset: UUID?
    @State private var presetName = ""

    var body: some View {
        Form {
            if model.active {
                Text("Provider changes are available after stopping the session.")
            }
            Group {
                presetSettings
                accounts
                speechSettings
                classificationSettings
                generationSettings
                knowledgeSettings
            }
            .disabled(model.active)
            Section("Audio and shortcuts") {
                Slider(value: $vad, in: 0.005...0.08) { Text("Audio sensitivity") }
                    .disabled(model.active)
                TextField("Pause (Command-Shift plus key)", text: $pauseShortcut)
                    .onChange(of: pauseShortcut) { _, value in pauseShortcut = String(value.suffix(1).lowercased()) }
                TextField("Compact window (Command-Shift plus key)", text: $compactShortcut)
                    .onChange(of: compactShortcut) { _, value in compactShortcut = String(value.suffix(1).lowercased()) }
            }
            Section("Retention") {
                Text("Session text stays in memory by default. Save individual sessions locally from Review and History.")
            }
            if let result = model.providerTest { Text(result).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .padding(10)
        .onAppear {
            presets = (try? JSONDecoder().decode([ProviderPreset].self, from: storedPresets)) ?? ProviderPreset.defaults()
            persistPresets()
        }
    }

    private var accounts: some View {
        Section("Accounts and billing") {
            Text("Apple Speech uses macOS recognition permissions. API credentials below are separately billed by each provider.")
            ProviderKeyField(model: model, provider: "OpenAI", account: "openai")
            ProviderKeyField(model: model, provider: "ElevenLabs", account: "elevenlabs")
            ProviderKeyField(model: model, provider: "Deepgram", account: "deepgram")
            ProviderKeyField(model: model, provider: "Anthropic", account: "anthropic")
            LabeledContent("ChatGPT subscription") { Text("Authorization unavailable") }
            Text(ChatGPTPlanEligibility.requirement + " " + ChatGPTPlanEligibility.audioAvailability)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speechSettings: some View {
        Section("Transcription") {
            Picker("Provider", selection: $speech) {
                ForEach(SpeechProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            if speech == .apple {
                Picker("Language", selection: $appleLocale) {
                    ForEach(AppleSpeechTranscriber.languages(), id: \.self) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale) ?? locale).tag(locale)
                    }
                }
                Picker("Processing", selection: $appleMode) {
                    ForEach(AppleRecognitionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if appleMode == .onDevice, !AppleSpeechTranscriber.hasOnDeviceRecognition(locale: appleLocale) {
                    Text("This locale has no installed or supported on-device recognizer.")
                }
            } else if speech == .eleven {
                Picker("Scribe model", selection: $elevenModel) {
                    ForEach(ProviderCapabilities.describe(.elevenLabs).models, id: \.self) { Text($0).tag($0) }
                }
                Picker("Commit strategy", selection: $elevenCommit) {
                    ForEach(TranscriptionCommitStrategy.allCases.filter { speechCapabilities.commits.contains($0) }) {
                        Text($0.rawValue).tag($0)
                    }
                }
                if !speechCapabilities.commits.contains(elevenCommit) {
                    Text("Choose a commit strategy supported by this Scribe model.")
                }
                Toggle("Report detected language", isOn: $elevenDetectLanguage)
            } else {
                TextField("Model", text: speech == .openai ? $sttModel : $deepgramModel)
            }
            if speech != .apple {
                TextField("Language code (blank uses provider default)", text: $sttLanguage)
            }
            if speech == .eleven || speech == .deepgram {
                Slider(value: $sttEndpoint, in: 0.3...3, step: 0.05) { Text("Endpoint silence") }
                Text("Provider billing can include streamed silence. Account model availability is tested on connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if speechCapabilities.vocabularyHints {
                TextField("Vocabulary hints (comma separated)", text: $speechVocabulary)
            }
            if speechCapabilities.diarization {
                Text("Select Shared microphone in Audio Sources to assign detected speakers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            connectionButton(.transcription)
        }
    }

    private var classificationSettings: some View {
        Section("Question classification") {
            Picker("Provider", selection: $classification) {
                ForEach(TextProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Model", text: classification == .openai ? $questionModel : $anthropicQuestionModel)
            Slider(value: $confidence, in: 0.5...1) { Text("Question confidence") }
            Slider(value: $completionGrace, in: 0.5...6, step: 0.5) { Text("Continuation window") }
            Stepper("Context turns: \(classifierTurns)", value: $classifierTurns, in: 0...32)
            Stepper("Context budget: \(classifierBudget)", value: $classifierBudget, in: 500...8_000, step: 250)
            TextField("Classification instructions", text: $questionInstructions, axis: .vertical)
            connectionButton(.classification)
        }
    }

    private var generationSettings: some View {
        Section("Answer generation") {
            Picker("Provider", selection: $answer) {
                ForEach(TextProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Model", text: answer == .openai ? $answerModel : $anthropicAnswerModel)
            Picker("Format", selection: $format) {
                ForEach(AnswerFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Response language", text: $answerLanguage)
            Stepper(answerWordLimit == 0 ? "Word limit: format default" : "Word limit: \(answerWordLimit)",
                    value: $answerWordLimit, in: 0...400, step: 25)
            TextField("Answer instructions", text: $instructions, axis: .vertical)
            Stepper("Context turns: \(answerTurns)", value: $answerTurns, in: 0...32)
            Stepper("Context budget: \(answerBudget)", value: $answerBudget, in: 500...8_000, step: 250)
            Slider(value: $generationTimeout, in: 5...45, step: 5) { Text("Timeout (seconds)") }
            Slider(value: $fontSize, in: 12...30, step: 1) { Text("Answer text size") }
            connectionButton(.answer)
        }
    }

    private var knowledgeSettings: some View {
        Section("Keyword and semantic retrieval") {
            Toggle("Use OpenAI embeddings", isOn: $semanticRetrieval)
            if semanticRetrieval {
                TextField("Embedding model", text: $embeddingModel)
                Text("Build the index in Profiles. Indexing sends approved facts, and semantic search sends accepted questions.")
                    .font(.caption).foregroundStyle(.secondary)
                connectionButton(.embeddings)
            }
        }
    }

    private var speechCapabilities: ProviderCapabilities {
        let selected: String
        switch speech {
        case .apple: selected = appleLocale
        case .eleven: selected = elevenModel
        case .openai: selected = sttModel
        case .deepgram: selected = deepgramModel
        }
        return ProviderCapabilities.describe(speech.provider, model: selected)
    }

    private func connectionButton(_ service: ProviderService) -> some View {
        Button("Test " + service.rawValue.capitalized) { model.checkProvider(service) }
            .disabled(model.checkingProvider)
            .help("May send a synthetic request using the selected provider.")
    }

    private var currentPreset: ProviderPreset? { presets.first { $0.id == selectedPreset } }

    private var presetSettings: some View {
        Section("Provider presets") {
            Picker("Preset", selection: $selectedPreset) {
                Text("Select a preset").tag(UUID?.none)
                ForEach(presets) { preset in
                    Text(preset.name + (preset.unavailableReason == nil ? "" : " (unavailable)")).tag(Optional(preset.id))
                }
            }
            if let reason = currentPreset?.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Preset name", text: $presetName)
            HStack {
                Button("Apply") { if let preset = currentPreset { apply(preset) } }
                    .disabled(currentPreset == nil || currentPreset?.unavailableReason != nil)
                Button("Create") {
                    let preset = capturePreset(name: presetName)
                    presets.append(preset)
                    selectedPreset = preset.id
                    persistPresets()
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presets.count >= 50)
                Button("Save Current Settings") {
                    guard let id = selectedPreset, let index = presets.firstIndex(where: { $0.id == id }) else { return }
                    presets[index] = capturePreset(name: presetName, id: id)
                    persistPresets()
                }.disabled(currentPreset == nil || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Duplicate") {
                    guard let preset = currentPreset else { return }
                    let copy = preset.copy(named: preset.name + " copy")
                    presets.append(copy)
                    selectedPreset = copy.id
                    persistPresets()
                }.disabled(currentPreset == nil || presets.count >= 50)
                Button("Delete", role: .destructive) {
                    presets.removeAll { $0.id == selectedPreset }
                    selectedPreset = nil
                    persistPresets()
                }.disabled(currentPreset == nil)
            }
        }
        .onChange(of: selectedPreset) { _, _ in presetName = currentPreset?.name ?? "" }
    }

    private func capturePreset(name: String, id: UUID = UUID()) -> ProviderPreset {
        let selected: String
        switch speech {
        case .apple: selected = "Speech framework"
        case .eleven: selected = elevenModel
        case .openai: selected = sttModel
        case .deepgram: selected = deepgramModel
        }
        return ProviderPreset(id: id, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            transcription: speech.provider, transcriptionModel: selected, classifier: classification.provider,
            classificationModel: classification == .openai ? questionModel : anthropicQuestionModel,
            answer: answer.provider, answerModel: answer == .openai ? answerModel : anthropicAnswerModel,
            language: speech == .apple ? appleLocale : sttLanguage, appleRecognitionMode: appleMode,
            commit: elevenCommit, embeddingsModel: semanticRetrieval ? embeddingModel : nil)
    }

    private func apply(_ preset: ProviderPreset) {
        guard preset.unavailableReason == nil,
              let newSpeech = SpeechProvider.allCases.first(where: { $0.provider == preset.transcription }),
              let newClassifier = TextProvider.allCases.first(where: { $0.provider == preset.classifier }),
              let newAnswer = TextProvider.allCases.first(where: { $0.provider == preset.answer }) else { return }
        speech = newSpeech
        classification = newClassifier
        answer = newAnswer
        switch speech {
        case .apple:
            appleLocale = preset.language
            appleMode = preset.appleRecognitionMode
        case .eleven:
            elevenModel = preset.transcriptionModel
            elevenCommit = preset.commit
        case .openai: sttModel = preset.transcriptionModel
        case .deepgram: deepgramModel = preset.transcriptionModel
        }
        if speech != .apple { sttLanguage = preset.language }
        if classification == .openai { questionModel = preset.classificationModel }
        else { anthropicQuestionModel = preset.classificationModel }
        if answer == .openai { answerModel = preset.answerModel }
        else { anthropicAnswerModel = preset.answerModel }
        semanticRetrieval = preset.embeddingsModel != nil
        if let value = preset.embeddingsModel { embeddingModel = value }
    }

    private func persistPresets() {
        if let encoded = try? JSONEncoder().encode(presets) { storedPresets = encoded }
    }
}

private struct ProviderKeyField: View {
    @ObservedObject var model: WorkspaceModel
    let provider: String
    let account: String
    @State private var key = ""

    var body: some View {
        HStack {
            SecureField(provider + " API key", text: $key)
            Button("Save") { model.saveKey(key, account: account); key = "" }
                .disabled(key.isEmpty).accessibilityLabel("Save " + provider + " key")
            Button("Remove") { model.saveKey("", account: account) }
                .disabled(!model.configuredKeys.contains(account)).accessibilityLabel("Remove " + provider + " key")
            Text(model.configuredKeys.contains(account) ? "In Keychain" : "Key required")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var model: WorkspaceModel
    let store: KnowledgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile = InterviewProfile(name: "")
    @State private var facts: [ExperienceFact] = []
    @State private var documents: [ProfileDocument] = []
    @State private var claim = ""
    @State private var pastedText = ""
    @State private var kind: ProfileDocument.Kind = .resume
    @State private var picker = false
    @State private var message: String?
    @State private var selectedFact: ExperienceFact?
    @State private var deleteConfirmation = false
    @State private var indexing = false
    @AppStorage("semanticRetrieval") private var semanticRetrieval = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Interview Profiles").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Menu("Open Profile") {
                    ForEach(model.profiles) { item in Button(item.name) { select(item) } }
                }
                Button("New Profile") { select(InterviewProfile(name: "")) }
                Button("Save Profile", action: save)
                Button("Delete Profile", role: .destructive) { deleteConfirmation = true }
                    .disabled(!model.profiles.contains(where: { $0.id == profile.id }))
            }
            Form {
                TextField("Profile name", text: $profile.name)
                TextField("Target role", text: $profile.role)
                TextField("Seniority", text: $profile.seniority)
                TextField("Industry", text: $profile.industry)
                TextField("Answer language", text: $profile.answerLanguage)
                TextField("Response instructions", text: $profile.instructions)
            }
            Divider()
            HStack {
                Picker("Document type", selection: $kind) {
                    ForEach(ProfileDocument.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Import Document") { picker = true }
                TextField("Paste document text", text: $pastedText)
                Button("Add Text") {
                    let document = ProfileDocument(kind: kind, title: "Pasted " + kind.rawValue, text: pastedText)
                    add(document)
                    pastedText = ""
                }.disabled(pastedText.isEmpty)
            }
            List {
                Section("Imported documents") {
                    ForEach(documents) { document in
                        HStack {
                            Text(document.title)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await change { try await store.deleteDocument(document.id, profile: profile.id) } }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Experience facts") {
                    ForEach(facts) { fact in
                        HStack {
                            Text(fact.claim)
                            Spacer()
                            Text(fact.status.rawValue.capitalized).foregroundStyle(.secondary)
                            Button("Review") { selectedFact = fact }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                TextField("Add an experience fact", text: $claim)
                Button("Add for Review") {
                    let fact = ExperienceFact(claim: claim)
                    claim = ""
                    Task { await change { try await store.save(fact, profile: profile.id) } }
                }.disabled(claim.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if semanticRetrieval {
                    Button(indexing ? "Indexing…" : "Build Embeddings", action: reindex)
                        .disabled(indexing || !facts.contains(where: { $0.status == .confirmed }))
                }
                Button("Clear Embeddings") {
                    let id = profile.id
                    Task {
                        do {
                            try await store.clearFactIndex(profile: id)
                            if profile.id == id { message = "Embedding index cleared." }
                        } catch {
                            if profile.id == id { message = "The embedding index could not be cleared." }
                        }
                    }
                }.disabled(indexing || !model.profiles.contains(where: { $0.id == profile.id }))
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .padding(16)
        .task { if let item = model.profiles.first(where: { $0.id == model.profileID }) { select(item) } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, .pdf, .data]) { result in
            switch result {
            case .success(let url):
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    add(try ProfileDocument.read(url, kind: kind))
                } catch StorageFailure.emptyDocument {
                    message = "This document has no extractable text. Paste its text or use a text-based PDF."
                } catch {
                    message = "Import failed. Choose a text, Markdown, PDF, or DOCX document."
                }
            case .failure:
                message = "The selected document could not be opened."
            }
        }
        .sheet(item: $selectedFact) { fact in
            FactEditor(fact: fact, save: { update in
                Task { await change { try await store.save(update, profile: profile.id) } }
            }, remove: {
                Task { await change { try await store.deleteFact(fact.id, profile: profile.id) } }
            })
        }
        .confirmationDialog("Delete this profile and its documents and facts?", isPresented: $deleteConfirmation) {
            Button("Delete Profile", role: .destructive) {
                Task {
                    do {
                        try await store.deleteProfile(profile.id)
                        await model.reloadProfiles()
                        select(InterviewProfile(name: ""))
                    } catch { message = "Profile deletion failed." }
                }
            }
        }
    }

    private func reindex() {
        let id = profile.id
        indexing = true
        Task {
            defer { indexing = false }
            do {
                guard let provider = try SessionProviders.embeddings(defaults: .standard) else { return }
                let count = try await store.indexConfirmedFacts(profile: id, provider: provider)
                if profile.id == id { message = "Indexed \(count) approved facts." }
            } catch {
                if profile.id == id { message = publicErrorMessage(error) }
            }
        }
    }

    private func select(_ item: InterviewProfile) {
        profile = item
        facts = []
        documents = []
        message = nil
        Task { await refresh(item.id) }
    }

    private func refresh(_ id: UUID) async {
        let facts = (try? await store.facts(profile: id)) ?? []
        let documents = (try? await store.documents(profile: id)) ?? []
        guard profile.id == id else { return }
        self.facts = facts
        self.documents = documents
    }

    private func save() {
        Task { await change {} }
    }

    private func add(_ document: ProfileDocument) {
        Task { await change { try await store.add(document, to: profile.id) } }
    }

    private func change(_ operation: () async throws -> Void) async {
        do {
            try await store.save(profile)
            try await operation()
            await model.reloadProfiles()
            model.profileID = profile.id
            await refresh(profile.id)
            message = nil
        } catch {
            message = "Could not save. Enter a profile name and check the document or fact."
        }
    }
}

private struct FactEditor: View {
    @State var fact: ExperienceFact
    let save: (ExperienceFact) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Claim", text: $fact.claim, axis: .vertical)
            TextField("Location in source", text: $fact.locator)
            TextField("Category", text: $fact.category)
            TextField("Ownership", text: $fact.ownership)
            TextField("Dates", text: $fact.dates)
            TextField("Limitations", text: $fact.limitations)
            Picker("Review status", selection: $fact.status) {
                ForEach(ExperienceFact.Status.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            HStack {
                Button("Remove", role: .destructive) { remove(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Fact") { save(fact); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 490)
    }
}
