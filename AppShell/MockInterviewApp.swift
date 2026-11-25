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
                .frame(width: 500)
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
    case openai = "OpenAI"
    case deepgram = "Deepgram"
    var id: String { rawValue }
}

private enum TextProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    var id: String { rawValue }
}

private struct SessionProviders {
    let transcriber: @Sendable () -> any StreamingSTT
    let classifier: any QuestionClassifier
    let generator: any TextGenerator

    init(defaults: UserDefaults, diarize: Bool = false) throws {
        let speech = SpeechProvider(rawValue: defaults.string(forKey: "speechProvider") ?? "") ?? .openai
        let classification = TextProvider(rawValue: defaults.string(forKey: "classificationProvider") ?? "") ?? .openai
        let language = defaults.string(forKey: "sttLanguage")
        func key(_ account: String) throws -> String {
            guard let value = Keychain.load(account), !value.isEmpty else {
                throw ProviderFailure.missingCredentials
            }
            return value
        }

        switch speech {
        case .openai:
            let credential = try key("openai")
            let model = defaults.string(forKey: "sttModel") ?? "gpt-live-transcribe"
            transcriber = { OpenAIRealtimeTranscriber(apiKey: credential, model: model, language: language) }
        case .deepgram:
            let credential = try key("deepgram")
            let model = defaults.string(forKey: "deepgramModel") ?? "nova-3"
            transcriber = {
                DeepgramTranscriber(apiKey: credential, model: model, language: language, diarize: diarize)
            }
        }
        switch classification {
        case .openai:
            classifier = OpenAIQuestionClassifier(apiKey: try key("openai"),
                                                  model: defaults.string(forKey: "questionModel") ?? "gpt-4.1-mini")
        case .anthropic:
            classifier = AnthropicQuestionClassifier(apiKey: try key("anthropic"),
                model: defaults.string(forKey: "anthropicQuestionModel") ?? "claude-haiku-4-5")
        }
        generator = try Self.answerGenerator(defaults: defaults)
    }

    static func embeddings(defaults: UserDefaults) throws -> (any TextEmbeddingProvider)? {
        guard defaults.bool(forKey: "semanticRetrieval") else { return nil }
        guard let key = Keychain.load("openai") else { throw ProviderFailure.missingCredentials }
        return OpenAIEmbeddings(apiKey: key,
                               model: defaults.string(forKey: "embeddingModel") ?? "text-embedding-3-small")
    }

    static func answerGenerator(defaults: UserDefaults) throws -> any TextGenerator {
        let answer = TextProvider(rawValue: defaults.string(forKey: "answerProvider") ?? "") ?? .openai
        switch answer {
        case .openai:
            guard let credential = Keychain.load("openai") else { throw ProviderFailure.missingCredentials }
            return OpenAITextGenerator(apiKey: credential,
                                       model: defaults.string(forKey: "answerModel") ?? "gpt-4.1-mini")
        case .anthropic:
            guard let credential = Keychain.load("anthropic") else { throw ProviderFailure.missingCredentials }
            return AnthropicTextGenerator(apiKey: credential,
                model: defaults.string(forKey: "anthropicAnswerModel") ?? "claude-haiku-4-5")
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    enum SourceMode: String, CaseIterable, Identifiable {
        case remote = "Application audio"
        case both = "Application and microphone"
        case microphone = "Microphone only"
        case replay = "Recorded PCM replay"
        var id: String { rawValue }
    }

    @Published var mode: SourceMode = .remote
    @Published var processes: [MacAudioChoice] = []
    @Published var microphones: [MacAudioChoice] = []
    @Published var processID: UInt32?
    @Published var micID: UInt32?
    @Published var designatedInterviewer = false
    @Published var mixedDiarization = false
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
    @Published var configuredKeys = Set(["openai", "deepgram", "anthropic"].filter { Keychain.load($0) != nil })

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
            if !processes.contains(where: { $0.id == processID }) { processID = nil }
            if !microphones.contains(where: { $0.id == micID }) { micID = nil }
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

    func checkProvider() {
        guard !checkingProvider else { return }
        checkingProvider = true
        providerTest = "Checking provider configuration…"
        Task {
            defer { checkingProvider = false }
            do {
                let providers = try SessionProviders(defaults: .standard)
                let transcriber = providers.transcriber()
                let source = CaptureSource(id: "Connection test", role: .interviewer)
                let epoch = UUID()
                _ = try await transcriber.connect(source: source, epoch: epoch)
                await transcriber.close()
                let testQuestion = "What is a FIFO queue?"
                _ = try await providers.classifier.classify(QuestionInput(
                    turn: TranscriptEvent(source: source, epoch: epoch, itemID: "synthetic-connection-test",
                                          text: testQuestion, state: .final), previousQuestions: []))
                for try await _ in try await providers.generator.stream(AnswerRequest(
                    question: testQuestion, instructions: "Use one sentence.", evidence: [])) {}
                providerTest = "The transcription connection opened and both text models responded."
            } catch {
                providerTest = publicErrorMessage(error)
            }
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
                let diarize = mode == .microphone && !designatedInterviewer && mixedDiarization
                let providers = try SessionProviders(defaults: options, diarize: diarize)
                let embedding = try? SessionProviders.embeddings(defaults: options)
                let format = AnswerFormat(rawValue: options.string(forKey: "answerFormat") ?? "") ?? .brief
                let threshold = options.object(forKey: "questionThreshold") as? Double ?? 0.8
                let sensitivity = Float(options.object(forKey: "vadThreshold") as? Double ?? 0.015)
                let profile = profiles.first(where: { $0.id == profileID })
                let store = self.store
                let channels = try captureSources().map { source, audio in
                    TranscriptionChannel(source: source, audio: audio, threshold: sensitivity,
                                         replay: source.id == "Replay", makeSTT: providers.transcriber)
                }
                let preferences = [
                    options.string(forKey: "answerInstructions") ?? "", profile?.instructions ?? "",
                    (profile?.answerLanguage.isEmpty == false) ? "Answer language: " + (profile?.answerLanguage ?? "") : ""
                ].joined(separator: "\n")
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
                    detector: QuestionDetector(classifier: providers.classifier, threshold: threshold),
                    generator: providers.generator,
                    format: format, preferences: preferences, interviewContext: context,
                    classificationEvidence: { question in
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
                self.error = "The interview could not start. Check the selected source and provider settings."
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
                    self.error = "Audio test failed. Check macOS permissions and the selected sources."
                }
            }
        } catch {
            self.error = "Select each required audio source before testing."
        }
    }

    private func displayTestLevel(_ level: Float, source: String) { testLevels[source] = level }

    private func captureSources() throws -> [(CaptureSource, any AudioSource)] {
        var result: [(CaptureSource, any AudioSource)] = []
        if mode == .remote || mode == .both {
            guard let processID else { throw CaptureFailure.sourceUnavailable }
            let source = CaptureSource(id: "Application", role: .interviewer)
            result.append((source, MacAudioSource(source: source, input: .process(processID))))
        }
        if mode == .microphone || mode == .both {
            guard let micID else { throw CaptureFailure.sourceUnavailable }
            let role: SourceRole = mode == .both ? .candidate : (designatedInterviewer ? .interviewer : .unknown)
            let source = CaptureSource(id: "Microphone", role: role)
            result.append((source, MacAudioSource(source: source, input: .microphone(micID))))
        }
        if mode == .replay {
            guard let replayURL else { throw CaptureFailure.sourceUnavailable }
            let fileSize = try replayURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize > 0, fileSize <= 24_000_000 else { throw CaptureFailure.invalidFormat }
            let source = CaptureSource(id: "Replay", role: .interviewer)
            result.append((source, PCMReplaySource(source: source, pcm: try Data(contentsOf: replayURL))))
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
            if !model.active { sourceSetup }
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
                Picker("Source", selection: $model.mode) {
                    ForEach(WorkspaceModel.SourceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Refresh Sources", action: model.reloadDevices)
            }
            HStack {
                if model.mode == .remote || model.mode == .both {
                    Picker("Application", selection: $model.processID) {
                        Text("Select an application").tag(UInt32?.none)
                        ForEach(model.processes) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if model.mode == .microphone || model.mode == .both {
                    Picker("Microphone", selection: $model.micID) {
                        Text("Select a microphone").tag(UInt32?.none)
                        ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if model.mode == .microphone {
                    Toggle("Interviewer-only microphone", isOn: $model.designatedInterviewer)
                }
                if model.mode == .replay {
                    Button(model.replayURL?.lastPathComponent ?? "Choose 24 kHz mono PCM16 file") {
                        replayPicker = true
                    }
                }
                Button(model.testing ? "End Audio Test" : "Test Audio", action: model.testSources)
            }
            if model.mode == .microphone && !model.designatedInterviewer && speechProvider == .deepgram {
                Toggle("Identify speakers for manual role assignment", isOn: $model.mixedDiarization)
            }
            if model.mode == .remote || model.mode == .both {
                Text("A browser process may include audio from multiple tabs. Use headphones with two sources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Save a local copy when this session stops", isOn: $model.retainNextSession)
            ForEach(model.testLevels.keys.sorted(), id: \.self) { source in
                ProgressView(value: Double(model.testLevels[source] ?? 0)) { Text(source) }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading) {
            Text("Transcript").font(.headline)
            if let snapshot = model.snapshot {
                ForEach(snapshot.levels.keys.sorted(), id: \.self) { source in
                    ProgressView(value: Double(snapshot.levels[source] ?? 0)) {
                        Text(source + (snapshot.connected.contains(source) ? " · Connected" : " · Disconnected"))
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

    var body: some View {
        Form {
            Section("Providers") {
                ProviderKeyField(model: model, provider: "OpenAI", account: "openai")
                if speech == .deepgram {
                    ProviderKeyField(model: model, provider: "Deepgram", account: "deepgram")
                }
                if classification == .anthropic || answer == .anthropic {
                    ProviderKeyField(model: model, provider: "Anthropic", account: "anthropic")
                }
                Picker("Transcription provider", selection: $speech) {
                    ForEach(SpeechProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Transcription model", text: speech == .openai ? $sttModel : $deepgramModel)
                Picker("Classification provider", selection: $classification) {
                    ForEach(TextProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Classification model", text: classification == .openai ? $questionModel : $anthropicQuestionModel)
                Picker("Answer provider", selection: $answer) {
                    ForEach(TextProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Answer model", text: answer == .openai ? $answerModel : $anthropicAnswerModel)
                TextField("Transcription language code", text: $sttLanguage)
                Button("Test Connection", action: model.checkProvider).disabled(model.checkingProvider)
                    .help("Sends a synthetic question to the selected models and may incur provider charges.")
                if let result = model.providerTest { Text(result).foregroundStyle(.secondary) }
            }
            Section("Live answers") {
                Picker("Format", selection: $format) {
                    ForEach(AnswerFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Answer instructions", text: $instructions, axis: .vertical)
                Slider(value: $vad, in: 0.005...0.08) { Text("Voice threshold") }
                Slider(value: $confidence, in: 0.5...1) { Text("Question confidence") }
                Slider(value: $fontSize, in: 12...30, step: 1) { Text("Answer text size") }
            }
            Section("Local shortcuts") {
                TextField("Pause (Command-Shift plus key)", text: $pauseShortcut)
                    .onChange(of: pauseShortcut) { _, value in pauseShortcut = String(value.suffix(1).lowercased()) }
                TextField("Compact window (Command-Shift plus key)", text: $compactShortcut)
                    .onChange(of: compactShortcut) { _, value in compactShortcut = String(value.suffix(1).lowercased()) }
            }
            Section("Evidence search") {
                Toggle("Use OpenAI embeddings", isOn: $semanticRetrieval)
                if semanticRetrieval {
                    TextField("Embedding model", text: $embeddingModel)
                    Text("Build an index in Profiles after enabling this option or changing the model. Indexing sends approved facts. Search sends accepted questions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Retention") {
                Text("Session text stays in memory by default. You can save individual sessions locally. Audio is never saved.")
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .padding(10)
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
