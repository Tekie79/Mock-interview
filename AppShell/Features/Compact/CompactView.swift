import AppKit
import ConversationCore
import SwiftUI

struct SessionControlBar: View {
    @Bindable var model: WorkspaceModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? Studio.tight : Studio.section) {
            StudioStatus(state: model.state, detail: detail)
                .lineLimit(1)
            if !compact {
                meter(model.route.question == .replay ? "Replay" : "Question", title: "Interviewer")
                if model.route.candidateEnabled || model.snapshot?.sources["Candidate"] != nil {
                    meter("Candidate", title: "Candidate")
                }
            }
            Spacer(minLength: 0)
            if !compact {
                Button { model.showAudioConfiguration = true } label: { Image(systemName: "slider.horizontal.3") }
                    .studioIcon("Audio configuration")
            }
            if model.state.isRunning {
                controls("Pause", icon: "pause.fill", disabled: model.busy, action: model.pause)
            } else if let label = model.startActionLabel {
                controls(label, icon: "play.fill", disabled: !model.canStartOrResume, action: model.startOrResume)
            }
            if model.active {
                controls("Stop", icon: "stop.fill", disabled: model.busy, action: model.stop)
            }
        }
        .padding(.horizontal, compact ? 0 : Studio.section)
        .padding(.vertical, Studio.tight)
        .background(compact ? .clear : Studio.surface)
    }

    private var detail: String? {
        guard model.state == .listening else { return nil }
        if model.snapshot?.waitingForQuestionEnd == true { return "Listening · Waiting for question" }
        if model.snapshot?.classifyingQuestion == true { return "Listening · Classifying" }
        if model.snapshot?.answers.last?.state == .generating { return "Listening · Generating" }
        return nil
    }

    private func controls(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact { Image(systemName: icon) }
            else { Label(title, systemImage: icon) }
        }
        .studioIcon(title)
        .disabled(disabled)
    }

    private func meter(_ key: String, title: String) -> some View {
        let level = Double(model.snapshot?.levels[key] ?? model.testLevels[key] ?? 0)
        return HStack(spacing: Studio.small) {
            Text(title).font(.caption).foregroundStyle(Studio.secondary)
            ProgressView(value: min(1, max(0, level * 5))).frame(width: 44)
                .tint(Studio.success)
                .accessibilityLabel(title + " input level")
        }
    }
}

struct CompactView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("compactOnTop") private var onTop = false
    @AppStorage("answerFontSize") private var fontSize = 16.0

    var body: some View {
        VStack(spacing: Studio.tight) {
            if let error = model.error ?? model.snapshot?.issues.last {
                Label(error, systemImage: "exclamationmark.circle").font(.caption)
                    .foregroundStyle(model.error == nil ? Studio.warning : Studio.error)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            InterviewAnswerView(model: model, fontSize: fontSize, compact: true)
            Divider()
            HStack(spacing: Studio.tight) {
                SessionControlBar(model: model, compact: true)
                Toggle(isOn: $onTop) { Image(systemName: onTop ? "pin.fill" : "pin") }
                    .toggleStyle(.button).studioIcon("Always on top")
                Button { openWindow(id: "workspace", value: WorkspaceWindow.main) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .studioIcon("Expand workspace")
            }
        }
        .padding(Studio.row)
        .background(Studio.canvas)
        .background(WindowLevel(floating: onTop))
    }
}

private struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            view?.window?.setFrameAutosaveName("MockInterview.Compact")
            view?.window?.level = floating ? .floating : .normal
        }
    }
}
