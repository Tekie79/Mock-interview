import AppKit
import ConversationCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("answerFontSize") private var fontSize = 16.0
    @AppStorage("showLiveInspector") private var showInspector = false
    @AppStorage("interviewContextMode") private var contextMode = InterviewContextMode.adaptive
    @State private var manualText = ""
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.section) {
            header
            if let error = model.error ?? model.lastIssue {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(model.error == nil ? Studio.warning : Studio.error)
                    .lineLimit(3)
            }
            if model.state == .idle && model.answerHistory.isEmpty {
                preparation
            } else {
                if model.state.isRunning && model.liveQuestionMode == .unresolved {
                    HStack(spacing: Studio.tight) {
                        Label("Listening to mixed audio. Use a transcript turn to request an answer.", systemImage: "waveform")
                            .font(.callout).foregroundStyle(Studio.secondary)
                        Spacer(minLength: 0)
                        if !showInspector { Button("Show Transcript") { showInspector = true } }
                    }
                }
                HStack(spacing: Studio.section) {
                    InterviewAnswerView(model: model, fontSize: fontSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        ContextInspector(model: model, useAsQuestion: { manualText = $0 })
                            .frame(minWidth: 225, idealWidth: 270, maxWidth: 320)
                    }
                }
            }
            if model.state.isRunning {
                HStack(spacing: Studio.tight) {
                    TextField("Ask a question manually", text: $manualText).onSubmit(submit)
                        .accessibilityIdentifier("manual-question")
                    Button("Generate", systemImage: "arrow.up", action: submit)
                        .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(Studio.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(model: model)
                .padding(Studio.page).frame(minWidth: 440, minHeight: 360)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Studio.row) {
            StudioHeading(title: "Live Interview", detail: model.selectedProfileName)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Studio.small) {
                HStack(spacing: Studio.tight) {
                    Button { openWindow(id: "compact") } label: { Image(systemName: "macwindow.on.rectangle") }
                        .studioIcon("Open Compact")
                    Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .studioIcon(showInspector ? "Hide inspector" : "Show inspector")
                        .disabled(model.state == .idle)
                    Menu {
                        Button("Diagnostics", systemImage: "waveform.path.ecg") { showDiagnostics = true }
                        Button("Clear Session", systemImage: "eraser", action: model.clearSession)
                            .disabled(model.active || model.snapshot == nil)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .studioIcon("Session options")
                }
                StudioSessionClock(startedAt: model.startedAt, endedAt: model.endedAt)
            }
        }
    }

    private var preparation: some View {
        ViewThatFits(in: .vertical) {
            setupContent
            ScrollView { setupContent }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: Studio.section) {
            StudioHeading(title: "Prepare your session", detail: "Choose a profile and confirm the audio sources before starting.")
            VStack(spacing: 0) {
                setupRow("Profile", icon: "person.crop.rectangle") {
                    Picker("Interview profile", selection: $model.profileID) {
                        Text("General practice").tag(UUID?.none)
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().disabled(model.busy)
                }
                Divider()
                setupRow("Interviewer audio", icon: "waveform") { Text(model.questionSourceLabel) }
                Divider()
                setupRow("Candidate microphone", icon: "mic") { Text(model.candidateSourceLabel) }
                Divider()
                setupRow("Answer mode", icon: "text.bubble") { Text(model.answerModeLabel) }
                Divider()
                setupRow("AI connection", icon: "network") { Text(model.providerReadiness) }
                Divider()
                setupRow("Interview context", icon: "text.magnifyingglass") { Text(contextMode.rawValue) }
            }
            .padding(.horizontal, Studio.section).studioSurface()
            if let permission = model.microphoneReadiness {
                Label(permission, systemImage: "mic.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Studio.warning)
            }
            HStack {
                InterviewStartControl(model: model, label: "Start Interview")
                    .buttonStyle(.borderedProminent)
                Button("Configure Audio", systemImage: "slider.horizontal.3") { model.showAudioConfiguration = true }
            }
        }
        .frame(maxWidth: 650, alignment: .leading)
        .padding(.top, Studio.tight)
    }

    private func setupRow<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.callout.weight(.medium))
            Spacer(minLength: Studio.row)
            content().font(.callout).foregroundStyle(Studio.secondary).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Studio.row)
    }

    private func submit() {
        model.manual(manualText)
        manualText = ""
    }
}

struct AudioSourceEditor: View {
    @Bindable var model: WorkspaceModel
    @State private var replayPicker = false
    @AppStorage("speechProvider") private var speechProvider = SpeechProvider.openai
    @AppStorage("elevenModel") private var elevenModel = "scribe_v3_live"
    @AppStorage("deepgramModel") private var deepgramModel = "nova-3"

    private var supportsSpeakerLabels: Bool {
        switch speechProvider {
        case .eleven: ProviderCapabilities.describe(.elevenLabs, model: elevenModel).diarization
        case .deepgram: ProviderCapabilities.describe(.deepgram, model: deepgramModel).diarization
        default: false
        }
    }

    var body: some View {
        sourceSetup
            .fileImporter(isPresented: $replayPicker, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { model.replayURL = url }
            }
    }

    private var sourceSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.route.question != .sharedMicrophone {
                    Picker("Question audio", selection: $model.route.question) {
                        ForEach(QuestionAudioKind.allCases.filter { $0 != .sharedMicrophone }) { Text($0.rawValue).tag($0) }
                    }
                }
                Button("Refresh Sources", action: model.reloadDevices)
            }
            Toggle("Interview on another device", isOn: Binding(
                get: { model.route.question == .sharedMicrophone },
                set: { model.route.setOtherDeviceInterview($0) }
            ))
            HStack {
                switch model.route.question {
                case .defaultOutput:
                    Text("Follows the macOS default output route.").font(.caption)
                case .outputDevice:
                    sourcePicker("Output", choices: model.outputs, selection: $model.route.outputUID)
                case .application:
                    sourcePicker("Application", choices: model.processes, selection: $model.route.applicationID)
                case .interviewerMicrophone, .sharedMicrophone:
                    sourcePicker(model.route.question == .sharedMicrophone ? "Room microphone" : "Question microphone",
                                 choices: model.microphones,
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
            if model.route.questionUsesOutput || model.route.question == .replay {
                Picker("Speaker attribution", selection: Binding(
                    get: { model.route.question == .replay ? model.replayAttribution : model.route.outputAttribution },
                    set: {
                        if model.route.question == .replay { model.replayAttribution = $0 }
                        else { model.route.outputAttribution = $0 }
                    }
                )) {
                    ForEach(QuestionAudioAttribution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled((model.route.question == .application && model.route.applicationID == nil)
                          || (model.route.question == .outputDevice && model.route.outputUID == nil)
                          || (model.route.question == .replay && model.replayURL == nil))
                Text("Interviewer-only audio enables automatic answers for this source. Choose it only if the feed carries the interviewer alone.")
                    .font(.caption).foregroundStyle(Studio.secondary)
                if model.requestsSpeakerLabels && !supportsSpeakerLabels {
                    Text("This transcription model supplies no speaker labels. Use ElevenLabs Scribe v3 Live, a supported Deepgram Nova model, or ask manually.")
                        .font(.caption).foregroundStyle(.secondary)
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
            if model.route.question == .sharedMicrophone {
                if supportsSpeakerLabels {
                    Text("Play the interview through the other device’s speakers. After Start, label each voice in Transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This transcription configuration cannot separate voices on one microphone. Use separate audio sources for automatic answers, or submit a question manually.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Try ElevenLabs speaker labels (unqualified)") {
                        elevenModel = "scribe_v3_live"
                        speechProvider = .eleven
                    }.disabled(model.busy)
                }
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

}
