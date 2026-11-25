import AppKit
import ConversationCore
import SwiftUI

struct ContextInspector: View {
    private enum Tab: String, CaseIterable { case transcript = "Transcript", context = "Learned Context" }
    @Bindable var model: WorkspaceModel
    let useAsQuestion: (String) -> Void
    @State private var selected = Tab.transcript
    @State private var editing: LearnedContextItem?
    @State private var replacement = ""
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.tight) {
            Picker("Inspector", selection: $selected) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if selected == .transcript { transcript }
            else { context }
        }
        .accessibilityLabel("Session inspector")
        .sheet(item: $editing) { item in
            VStack(alignment: .leading, spacing: Studio.section) {
                StudioHeading(title: "Correct learned context",
                              detail: "The original transcript stays in the session. This correction is unverified.")
                TextEditor(text: $replacement).frame(minHeight: 115).accessibilityLabel("Corrected context")
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Apply correction") {
                        model.correctContext(item.id, text: replacement)
                        editing = nil
                    }.disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(Studio.page).frame(width: 480)
        }
        .confirmationDialog("Clear learned session context?", isPresented: $confirmsClear) {
            Button("Clear Context", role: .destructive, action: model.clearContext)
        } message: { Text("This keeps the transcript and withdraws answer revisions that relied on the cleared context.") }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Studio.tight) {
            if model.liveQuestionMode == .unresolved, model.state.isRunning {
                Text("Mixed audio is unresolved. Use transcript text to ask manually.")
                    .font(.caption).foregroundStyle(Studio.warning)
            }
            if model.liveQuestionMode == .diarized {
                ForEach(model.snapshot?.speakers ?? []) { speaker in
                    Picker("Speaker \(speaker.id.number)", selection: Binding(get: { speaker.role },
                        set: { model.assignSpeaker(speaker.id, role: $0) })) {
                        ForEach(SourceRole.allCases, id: \.self) { Text(speakerLabel($0)).tag($0) }
                    }
                }
            }
            let turns = (model.snapshot?.transcript ?? []).sorted {
                ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
            }
            if turns.isEmpty {
                StudioEmpty(title: "Transcript", icon: "list.bullet.rectangle",
                            detail: "Speech appears here as the session listens.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Studio.tight) {
                            ForEach(turns) { turn in
                                VStack(alignment: .leading, spacing: Studio.small) {
                                    HStack {
                                        Text(speakerLabel(turn.role)).fontWeight(.semibold)
                                        if !turn.isFinal { Text("Partial") }
                                        Spacer(minLength: 0)
                                        if let time = turn.timestamp { Text(time, style: .time) }
                                    }.font(.caption).foregroundStyle(Studio.secondary)
                                    Text(turn.text).font(.callout).textSelection(.enabled)
                                        .foregroundStyle(turn.isFinal ? Studio.primary : Studio.secondary)
                                    if model.state.isRunning {
                                        Button("Use as question") { useAsQuestion(turn.text) }.buttonStyle(.link)
                                    }
                                }
                                .padding(.vertical, Studio.tight)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: turns.last?.id, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .accessibilityLabel("Transcript messages")
                }
            }
        }
    }

    private var context: some View {
        let items = model.snapshot?.learnedContext ?? []
        let evidence = model.displayedAnswer?.state == .invalidated ? [] : model.displayedAnswer?.evidence ?? []
        return VStack(alignment: .leading, spacing: Studio.tight) {
            HStack {
                Text("Session memory").font(.headline)
                Spacer(minLength: 0)
                Button { confirmsClear = true } label: { Image(systemName: "eraser") }
                    .studioIcon("Clear learned context").disabled(items.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Studio.row) {
                    if !evidence.isEmpty {
                        DisclosureGroup("Approved profile evidence") {
                            ForEach(Array(evidence.enumerated()), id: \.offset) { _, fact in
                                Text(fact).font(.caption).textSelection(.enabled)
                            }
                        }.foregroundStyle(Studio.success)
                    }
                    if items.isEmpty {
                        Text("Attributed speech and derived summaries appear here during the session.")
                            .font(.callout).foregroundStyle(Studio.muted)
                    } else {
                        let topics = items.filter { !$0.isExcluded && $0.kind == .project }.suffix(2)
                        if !topics.isEmpty {
                            Text("Current discussion").font(.caption.weight(.semibold)).foregroundStyle(Studio.muted)
                            ForEach(Array(topics)) { item in Text(item.text).lineLimit(2).font(.callout) }
                            Divider()
                        }
                        Text("Unverified session information").font(.caption.weight(.semibold)).foregroundStyle(Studio.warning)
                        ForEach(Array(items.reversed())) { item in contextRow(item) }
                    }
                }
            }.accessibilityLabel("Learned context items")
        }
    }

    private func contextRow(_ item: LearnedContextItem) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Studio.tight) {
                Text(item.text).textSelection(.enabled)
                if let role = item.role { Text("Speaker: " + speakerLabel(role)) }
                if let source = item.source { Text("Source: " + source) }
                if let epoch = item.epoch { Text("Capture epoch: " + epoch.uuidString.prefix(8)) }
                if let date = item.capturedAt { Text(date, style: .time) }
                Text("\(item.sourceTranscriptIDs.count) linked transcript entries")
                HStack {
                    if item.kind != .summary {
                        Button("Correct") { replacement = item.text; editing = item }
                    }
                    Button(item.isExcluded ? "Include" : "Exclude") {
                        model.excludeContext(item.id, excluded: !item.isExcluded)
                    }
                }
            }
            .font(.caption).padding(.vertical, Studio.tight)
        } label: {
            VStack(alignment: .leading, spacing: Studio.small) {
                Text(item.kind.rawValue + (item.isExcluded ? " · Excluded" : ""))
                    .font(.caption.weight(.medium)).foregroundStyle(Studio.secondary)
                Text(item.text).font(.callout).lineLimit(2)
            }
        }
    }

    private func speakerLabel(_ role: SourceRole) -> String {
        role == .candidate ? "Interviewee" : role.rawValue.capitalized
    }
}

struct DiagnosticsView: View {
    @Bindable var model: WorkspaceModel

    private var summary: String {
        model.snapshot?.diagnosticSummary ?? "No active session."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.section) {
            StudioHeading(title: "Diagnostics", detail: version)
            StudioStatus(state: model.state)
            ScrollView {
                Text(summary).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Copy Redacted Diagnostics", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            }
        }
    }

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(marketing) (\(build))"
    }
}
