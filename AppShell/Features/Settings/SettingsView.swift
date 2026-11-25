import AppKit
import ConversationCore
import LocalAuthentication
import Security
import SwiftUI
import UniformTypeIdentifiers

struct ProviderSettingsView: View {
    @Bindable var model: WorkspaceModel
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
    @AppStorage("chatGPTQuestionModel") private var chatGPTQuestionModel = ""
    @AppStorage("chatGPTAnswerModel") private var chatGPTAnswerModel = ""
    @AppStorage("sttModel") private var sttModel = "gpt-live-transcribe"
    @AppStorage("questionModel") private var questionModel = "gpt-4.1-mini"
    @AppStorage("answerModel") private var answerModel = "gpt-4.1-mini"
    @AppStorage("openAIQuestionReasoning") private var openAIQuestionReasoning = ReasoningEffort.modelDefault
    @AppStorage("openAIAnswerReasoning") private var openAIAnswerReasoning = ReasoningEffort.modelDefault
    @AppStorage("anthropicQuestionReasoning") private var anthropicQuestionReasoning = ReasoningEffort.modelDefault
    @AppStorage("anthropicAnswerReasoning") private var anthropicAnswerReasoning = ReasoningEffort.modelDefault
    @AppStorage("sttLanguage") private var sttLanguage = ""
    @AppStorage("answerFormat") private var format = AnswerFormat.brief
    @AppStorage("answerInstructions") private var instructions = ""
    @AppStorage("vadThreshold") private var vad = 0.015
    @AppStorage("questionThreshold") private var confidence = 0.8
    @AppStorage("answerFontSize") private var fontSize = 16.0
    @AppStorage("semanticRetrieval") private var semanticRetrieval = false
    @AppStorage("summarizeSession") private var summarizeSession = false
    @AppStorage("embeddingModel") private var embeddingModel = "text-embedding-3-small"
    @AppStorage("pauseShortcut") private var pauseShortcut = "p"
    @AppStorage("compactShortcut") private var compactShortcut = "k"

    @AppStorage("classificationInstructions") private var questionInstructions = ""
    @AppStorage("classifierContextBudget") private var classifierBudget = 3_000
    @AppStorage("classifierContextTurns") private var classifierTurns = 12
    @AppStorage("answerContextBudget") private var answerBudget = 3_000
    @AppStorage("answerContextTurns") private var answerTurns = 12
    @AppStorage("completionGrace") private var completionGrace = 3.0
    @AppStorage("questionWaitSeconds") private var questionWaitSeconds = 2.0
    @AppStorage("generationTimeout") private var generationTimeout = 45.0
    @AppStorage("answerLanguage") private var answerLanguage = ""
    @AppStorage("answerWordLimit") private var answerWordLimit = 0
    @AppStorage("providerPresets") private var storedPresets = Data()
    @State private var presets: [ProviderPreset] = []
    @State private var selectedPreset: UUID?
    @State private var presetName = ""

    enum Category: String, CaseIterable, Identifiable {
        case general = "General", audio = "Audio", ai = "AI and Models", answers = "Answer Preferences"
        case context = "Interview Context", privacy = "Privacy and Storage", diagnostics = "Diagnostics"
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .audio: "waveform"
            case .ai: "cpu"
            case .answers: "text.alignleft"
            case .context: "text.magnifyingglass"
            case .privacy: "lock.shield"
            case .diagnostics: "waveform.path.ecg"
            }
        }
    }

    @State private var category: Category? = .general
    @AppStorage("interviewAppearance") private var appearance = InterviewAppearance.system
    @AppStorage("interviewPresentation") private var presentation = InterviewPresentation.focus
    @AppStorage("compactOnTop") private var compactOnTop = false
    @AppStorage("fitLatestAnswer") private var fitLatest = false
    @AppStorage("interviewContextMode") private var contextMode = InterviewContextMode.adaptive
    @AppStorage("contextCandidate") private var contextCandidate = true
    @AppStorage("contextFeedback") private var contextFeedback = true
    @AppStorage("contextSpeakingStyle") private var contextSpeakingStyle = false
    @State private var confirmClearContext = false

    init(model: WorkspaceModel, initialCategory: Category = .general) {
        self.model = model
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Category.allCases, selection: $category) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).tag(item)
            }
            .listStyle(.sidebar).frame(width: 190).accessibilityLabel("Settings categories")
            Divider()
            VStack(alignment: .leading, spacing: Studio.tight) {
                StudioHeading(title: (category ?? .general).rawValue)
                    .padding(.horizontal, Studio.page).padding(.top, Studio.page)
                if let message = model.providerTest ?? model.error {
                    Text(message).font(.callout).foregroundStyle(Studio.secondary)
                        .padding(.horizontal, Studio.page)
                }
                if category == .diagnostics {
                    DiagnosticsView(model: model, showTitle: false).padding(Studio.section)
                } else {
                    Form { categoryContent }.formStyle(.grouped).id(category)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Studio.canvas)
        }
        .onAppear {
            presets = (try? JSONDecoder().decode([ProviderPreset].self, from: storedPresets)) ?? ProviderPreset.defaults()
            persistPresets()
            model.loadChatGPT()
        }
        .confirmationDialog("Clear learned session context?", isPresented: $confirmClearContext) {
            Button("Clear learned context", role: .destructive, action: model.clearContext)
        }
    }

    @ViewBuilder private var categoryContent: some View {
        switch category ?? .general {
        case .general:
            Section("Appearance and layout") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(InterviewAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Default answer view", selection: $presentation) {
                    ForEach(InterviewPresentation.allCases) { Text($0.rawValue).tag($0) }
                }
                Slider(value: $fontSize, in: 12...30, step: 1) { Text("Answer text size") }
                Toggle("Keep Compact on top", isOn: $compactOnTop)
                Toggle("Fit latest answer in Chat", isOn: $fitLatest)
            }
            Section("Keyboard shortcuts") {
                TextField("Pause (Command-Shift plus key)", text: $pauseShortcut)
                    .onChange(of: pauseShortcut) { _, value in pauseShortcut = String(value.suffix(1).lowercased()) }
                TextField("Compact window (Command-Shift plus key)", text: $compactShortcut)
                    .onChange(of: compactShortcut) { _, value in compactShortcut = String(value.suffix(1).lowercased()) }
            }
        case .audio:
            Section("Sources") { AudioSourceEditor(model: model) }
            Section("Recognition and question timing") {
                Slider(value: $vad, in: 0.005...0.08) { Text("Audio sensitivity") }.disabled(model.active)
                Slider(value: $questionWaitSeconds, in: 0...6, step: 0.5) { Text("Wait for silence") }
                    .onChange(of: questionWaitSeconds) { _, seconds in model.updateQuestionWait(seconds) }
                Text("\(questionWaitSeconds.formatted()) seconds").foregroundStyle(.secondary)
                Slider(value: $completionGrace, in: 0.5...6, step: 0.5) { Text("Continuation window") }
                    .disabled(model.active)
                Slider(value: $sttEndpoint, in: 0.2...3, step: 0.05) { Text("Provider endpoint silence") }
                    .disabled(model.active)
            }
        case .ai:
            if model.active { Text("Stop the session to change AI services.") }
            Group {
                Section("OpenAI connection") {
                    ProviderKeyField(model: model, provider: "OpenAI", account: "openai")
                }
                speechSettings
                classificationSettings
                generationSettings
                knowledgeSettings
                DisclosureGroup("Provider presets") { presetSettings }
                DisclosureGroup("Other providers and subscription accounts") { accounts }
            }.disabled(model.active)
        case .answers: answerPreferences.disabled(model.active)
        case .context:
            Section("Learn during the session") {
                Picker("Context mode", selection: $contextMode) {
                    ForEach(InterviewContextMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Include candidate speech", isOn: $contextCandidate)
                Toggle("Include interviewer feedback", isOn: $contextFeedback)
                Toggle("Adapt to the candidate’s speaking style", isOn: $contextSpeakingStyle)
                    .disabled(!contextCandidate)
                Stepper("Answer context turns: \(answerTurns)", value: $answerTurns, in: 0...32)
                Stepper("Answer context byte budget: \(answerBudget)", value: $answerBudget, in: 500...8_000, step: 250)
                Stepper("Classifier context turns: \(classifierTurns)", value: $classifierTurns, in: 0...32)
                Stepper("Classifier context byte budget: \(classifierBudget)", value: $classifierBudget, in: 500...8_000, step: 250)
            }.disabled(model.active)
            sessionContextSettings.disabled(model.active)
            Button("Clear learned context", role: .destructive) { confirmClearContext = true }
                .disabled(model.snapshot?.learnedContext.isEmpty != false)
        case .privacy:
            Section("Session storage") {
                Toggle("Save the next session locally", isOn: $model.retainNextSession)
                Text("Raw audio is never saved. Saved sessions can be exported or deleted in History.")
                Text("API credentials are managed in AI and Models and stored in macOS Keychain.")
            }
        case .diagnostics: EmptyView()
        }
    }

    private var accounts: some View {
        Section("Accounts and billing") {
            Text("Apple Speech uses macOS recognition permissions. API credentials below are separately billed by each provider.")
            ProviderKeyField(model: model, provider: "ElevenLabs", account: "elevenlabs")
            ProviderKeyField(model: model, provider: "Deepgram", account: "deepgram")
            ProviderKeyField(model: model, provider: "Anthropic", account: "anthropic")
            if ChatGPTPlanEligibility.desktopAvailable {
                chatGPTAccounts
            } else {
                LabeledContent("ChatGPT subscription") { Text("Authorization unavailable") }
                Text(ChatGPTPlanEligibility.requirement)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(ChatGPTPlanEligibility.audioAvailability).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chatGPTAccounts: some View {
        Group {
            Text("Eligible text requests can use your ChatGPT plan. This is separate from API billing.")
            if let snapshot = model.chatGPTSnapshot {
                ForEach(snapshot.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.label)
                        Text(!account.signedIn ? "Signed out" : !account.planEnabled ? "Plan usage not enabled"
                             : account.id == snapshot.active ? "Active account" : "Saved account")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if account.signedIn, !account.planEnabled {
                                Button("Enable plan usage") { model.signInToChatGPT(account.id, requestConsent: true) }
                            }
                            Button(account.id == snapshot.active ? "Sign in again" : "Continue with this account") {
                                model.signInToChatGPT(account.id)
                            }
                            if account.signedIn {
                                Button("Sign out", role: .destructive) { model.signOutOfChatGPT(account.id) }
                            }
                        }
                    }.disabled(model.chatGPTBusy || model.checkingProvider)
                }
            }
            HStack {
                Button("Continue with ChatGPT") { model.signInToChatGPT() }
                    .help("Add another ChatGPT account or workspace.")
                if model.chatGPTSnapshot?.active != nil {
                    Button("Refresh models") { model.refreshChatGPTModels() }
                }
            }.disabled(model.chatGPTBusy || model.checkingProvider)
            if model.chatGPTCanCancel {
                Button("Cancel sign-in") { model.cancelChatGPTSignIn() }
            }
            if model.chatGPTBusy { ProgressView().controlSize(.small).accessibilityLabel("ChatGPT account operation") }
            if let status = model.chatGPTStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let url = SessionProviders.usageURL { Link("Manage ChatGPT usage", destination: url) }
        }
    }

    private var speechSettings: some View {
        Section("Transcription") {
            Picker("Provider", selection: $speech) {
                ForEach(SpeechProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            qualificationStatus(speech == .openai && sttModel == "gpt-live-transcribe")
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
                Text("Turn on Interview on another device to assign roles to voices heard by one microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            connectionButton(.transcription)
        }
    }

    private var classificationSettings: some View {
        Section("Question classification") {
            Picker("Provider", selection: $classification) {
                ForEach(TextProvider.available) { Text($0.rawValue).tag($0) }
                if classification == .chatGPT, !ChatGPTPlanEligibility.desktopAvailable {
                    Text("ChatGPT plan (unavailable)").tag(TextProvider.chatGPT)
                }
            }
            qualificationStatus(classification == .openai && questionModel == "gpt-6-luna" && openAIQuestionReasoning == .none)
            if classification == .chatGPT {
                chatGPTModelPicker($chatGPTQuestionModel)
            } else {
                TextModelSettings(provider: classification.provider, service: .classification,
                    modelID: classification == .openai ? $questionModel : $anthropicQuestionModel,
                    reasoning: classification == .openai ? $openAIQuestionReasoning : $anthropicQuestionReasoning)
                    .id(classification)
            }
            Slider(value: $confidence, in: 0.5...1) { Text("Question confidence") }
            TextField("Classification instructions", text: $questionInstructions, axis: .vertical)
            connectionButton(.classification)
        }
    }

    private var generationSettings: some View {
        Section("Answer generation") {
            Picker("Provider", selection: $answer) {
                ForEach(TextProvider.available) { Text($0.rawValue).tag($0) }
                if answer == .chatGPT, !ChatGPTPlanEligibility.desktopAvailable {
                    Text("ChatGPT plan (unavailable)").tag(TextProvider.chatGPT)
                }
            }
            qualificationStatus(answer == .openai && answerModel == "gpt-6.2-sol" && openAIAnswerReasoning == .low)
            if answer == .chatGPT {
                chatGPTModelPicker($chatGPTAnswerModel)
            } else {
                TextModelSettings(provider: answer.provider, service: .answer,
                    modelID: answer == .openai ? $answerModel : $anthropicAnswerModel,
                    reasoning: answer == .openai ? $openAIAnswerReasoning : $anthropicAnswerReasoning)
                    .id(answer)
            }
            connectionButton(.answer)
        }
    }

    private var answerPreferences: some View {
        Section("Response") {
            Picker("Format", selection: $format) {
                ForEach(AnswerFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Response language", text: $answerLanguage)
            TextField("Requested word limit", value: $answerWordLimit, format: .number)
                .onChange(of: answerWordLimit) { _, limit in answerWordLimit = min(400, max(0, limit)) }
            Text("The model may exceed this length. Enter 0 to use the format default.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Answer instructions", text: $instructions, axis: .vertical)
            Slider(value: $generationTimeout, in: 5...45, step: 5) { Text("Timeout (seconds)") }
        }
    }

    private func chatGPTModelPicker(_ selection: Binding<String>) -> some View {
        let models = model.chatGPTSnapshot?.models ?? []
        return Picker("ChatGPT plan model", selection: selection) {
            Text("Select a model").tag("")
            if !selection.wrappedValue.isEmpty, !models.contains(where: { $0.slug == selection.wrappedValue }) {
                Text("Selected model unavailable").tag(selection.wrappedValue)
            }
            ForEach(models) { Text($0.displayName).tag($0.slug) }
        }.disabled(models.isEmpty)
    }

    private var knowledgeSettings: some View {
        Section("Keyword and semantic retrieval") {
            Toggle("Use OpenAI embeddings", isOn: $semanticRetrieval)
            if semanticRetrieval {
                TextField("Embedding model", text: $embeddingModel)
                qualificationStatus(embeddingModel == "text-embedding-3-small")
                Text("Build the index in Profiles. Indexing sends approved facts, and semantic search sends accepted questions.")
                    .font(.caption).foregroundStyle(.secondary)
                connectionButton(.embeddings)
            }
        }
    }

    private func qualificationStatus(_ inScope: Bool) -> some View {
        Text(inScope ? "M11 qualification target" : "Outside the M11 production qualification scope")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var sessionContextSettings: some View {
        Section("Interview context and evaluation") {
            Toggle("Summarize older conversation with OpenAI", isOn: $summarizeSession)
            if summarizeSession {
                Text("Sends older attributed dialogue to GPT-6 Luna during the session. Derived context stays in memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Test Summary") { model.checkSessionContext(evaluation: false) }
                .disabled(model.checkingProvider || model.chatGPTBusy)
            Button("Test Evaluation") { model.checkSessionContext(evaluation: true) }
                .disabled(model.checkingProvider || model.chatGPTBusy)
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
            .disabled(model.checkingProvider || model.chatGPTBusy)
            .help("May send a synthetic request using the selected provider.")
    }

    private var currentPreset: ProviderPreset? { presets.first { $0.id == selectedPreset } }

    private var presetSettings: some View {
        Section("Provider presets") {
            Button("Apply OpenAI M11 Configuration") { apply(.openAIQualification) }
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
            classificationModel: classification == .chatGPT ? chatGPTQuestionModel
                : classification == .openai ? questionModel : anthropicQuestionModel,
            answer: answer.provider, answerModel: answer == .chatGPT ? chatGPTAnswerModel
                : answer == .openai ? answerModel : anthropicAnswerModel,
            language: speech == .apple ? appleLocale : sttLanguage, appleRecognitionMode: appleMode,
            commit: speech == .eleven ? elevenCommit : speech == .deepgram ? .voiceActivity : .manual,
            embeddingsModel: semanticRetrieval ? embeddingModel : nil,
            classificationReasoning: classification == .chatGPT ? nil : classification == .openai
                ? openAIQuestionReasoning : anthropicQuestionReasoning,
            answerReasoning: answer == .chatGPT ? nil : answer == .openai
                ? openAIAnswerReasoning : anthropicAnswerReasoning)
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
        switch classification {
        case .openai:
            questionModel = preset.classificationModel
            openAIQuestionReasoning = preset.classificationReasoning ?? .modelDefault
        case .anthropic:
            anthropicQuestionModel = preset.classificationModel
            anthropicQuestionReasoning = preset.classificationReasoning ?? .modelDefault
        case .chatGPT: chatGPTQuestionModel = preset.classificationModel
        }
        switch answer {
        case .openai:
            answerModel = preset.answerModel
            openAIAnswerReasoning = preset.answerReasoning ?? .modelDefault
        case .anthropic:
            anthropicAnswerModel = preset.answerModel
            anthropicAnswerReasoning = preset.answerReasoning ?? .modelDefault
        case .chatGPT: chatGPTAnswerModel = preset.answerModel
        }
        semanticRetrieval = preset.embeddingsModel != nil
        if let value = preset.embeddingsModel { embeddingModel = value }
    }

    private func persistPresets() {
        if let encoded = try? JSONEncoder().encode(presets) { storedPresets = encoded }
    }
}

private struct TextModelSettings: View {
    let provider: ProviderID
    let service: ProviderService
    @Binding var modelID: String
    @Binding var reasoning: ReasoningEffort
    @State private var customDraft: String?

    var body: some View {
        let models = ProviderCapabilities.textModels(provider)
        let custom = customDraft == modelID || !models.contains(modelID)
        let efforts = ProviderCapabilities.reasoningEfforts(provider, model: modelID, service: service)
        Picker("Model", selection: Binding(
            get: { custom ? "" : modelID },
            set: { selection in
                customDraft = selection.isEmpty ? modelID : nil
                if !selection.isEmpty { modelID = selection }
            }
        )) {
            ForEach(models, id: \.self) { Text($0).tag($0) }
            Text("Custom model ID…").tag("")
        }
        .pickerStyle(.menu)
        if custom {
            TextField("Custom model ID", text: Binding(
                get: { modelID },
                set: { value in
                    modelID = value
                    customDraft = value
                }
            ))
        }

        Picker("Reasoning", selection: Binding(
            get: { efforts.contains(reasoning) ? reasoning : .modelDefault },
            set: { reasoning = $0 }
        )) {
            Text(efforts.isEmpty ? "Unavailable for this model" : ReasoningEffort.modelDefault.label)
                .tag(ReasoningEffort.modelDefault)
            ForEach(efforts, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .disabled(efforts.isEmpty)
    }
}

private struct ProviderKeyField: View {
    @Bindable var model: WorkspaceModel
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
        .disabled(model.busy || model.checkingProvider)
    }
}
