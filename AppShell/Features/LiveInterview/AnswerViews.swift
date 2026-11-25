import AppKit
import ConversationCore
import SwiftUI

enum InterviewPresentation: String, CaseIterable, Identifiable {
    case focus = "Focus"
    case chat = "Chat"
    var id: Self { self }
}

struct InterviewAnswerView: View {
    @Bindable var model: WorkspaceModel
    let fontSize: Double
    var compact = false
    @State var previewPresentation: InterviewPresentation?
    @AppStorage("interviewPresentation") private var presentation = InterviewPresentation.focus
    @AppStorage("interviewAnswersOnly") private var answersOnly = false

    private var presentationSelection: Binding<InterviewPresentation> {
        Binding(get: { previewPresentation ?? presentation }, set: { selection in
            if previewPresentation != nil { previewPresentation = selection }
            else { presentation = selection }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.tight) {
            HStack {
                Picker("Answer view", selection: presentationSelection) {
                    ForEach(InterviewPresentation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: compact ? 124 : 164)
                .accessibilityLabel("Answer view")
                Spacer(minLength: Studio.small)
                Toggle(isOn: $answersOnly) {
                    if compact { Image(systemName: "eye.slash") }
                    else { Label("Answers Only", systemImage: "eye.slash") }
                }
                .toggleStyle(.button)
                .studioIcon("Answers Only")
                .help(answersOnly ? "Show the interview question above each answer" : "Hide the interview question above each answer")
                if (previewPresentation ?? presentation) == .focus { focusControls }
            }
            if model.active, model.sessionUsesChatGPT, let url = SessionProviders.usageURL {
                Link("Manage ChatGPT plan usage", destination: url).font(.caption)
            }
            if (previewPresentation ?? presentation) == .chat {
                InterviewChatView(model: model, fontSize: fontSize, compact: compact, answersOnly: answersOnly)
                    .id(model.startedAt)
            } else if let answer = model.displayedAnswer {
                ScrollView {
                    AnswerEntry(answer: answer, number: nil, fontSize: fontSize, compact: compact, answersOnly: answersOnly, model: model)
                        .frame(maxWidth: 690, alignment: .leading)
                        .padding(compact ? Studio.tight : Studio.page)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .id(answer.id)
                .studioSurface()
                .accessibilityLabel("Focused answer")
            } else {
                StudioEmpty(title: "Ready for a question", icon: "text.bubble",
                            detail: "Suggested answers will appear here as questions are accepted.")
                    .studioSurface()
            }
        }
    }

    private var focusControls: some View {
        HStack(spacing: Studio.small) {
            Button { model.moveAnswer(-1) } label: { Image(systemName: "chevron.left") }
                .studioIcon("Previous answer")
            Button { model.moveAnswer(1) } label: { Image(systemName: "chevron.right") }
                .studioIcon("Next answer")
            Button(action: model.togglePin) { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                .studioIcon(model.pinned ? "Unpin answer" : "Pin answer")
        }.disabled(model.displayedAnswer == nil)
    }
}

private struct InterviewChatView: View {
    private enum Anchor: Hashable { case bottom }
    @Bindable var model: WorkspaceModel
    let fontSize: Double
    let compact: Bool
    let answersOnly: Bool
    @State private var followsLatest = true
    @State private var pendingNew = 0
    @State private var scheduledFollow: Task<Void, Never>?
    @AppStorage("fitLatestAnswer") private var fitLatest = false

    private var answers: [InterviewAnswer] { model.answerHistory }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Studio.tight) {
                HStack(spacing: Studio.tight) {
                    Toggle("Follow Latest", isOn: $followsLatest)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .onChange(of: followsLatest) { _, follow in
                            if follow { jump(proxy) }
                            else { scheduledFollow?.cancel(); scheduledFollow = nil }
                        }
                    Spacer(minLength: 0)
                    if !followsLatest {
                        Button(pendingNew == 0 ? "Jump to Latest" : "Jump to Latest (\(pendingNew))",
                               systemImage: "arrow.down") { followsLatest = true }
                            .controlSize(.small)
                    }
                    Menu {
                        Toggle("Fit Latest Answer", isOn: $fitLatest)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .fixedSize().studioIcon("Chat view options")
                }
                if answers.isEmpty {
                    StudioEmpty(title: "Ready for a question", icon: "text.bubble",
                                detail: "Accepted questions and answers appear here in order.")
                        .studioSurface()
                } else {
                    List {
                        ForEach(Array(answers.enumerated()), id: \.element.id) { index, answer in
                            AnswerEntry(answer: answer, number: index + 1, fontSize: fontSize,
                                        compact: compact, answersOnly: answersOnly, model: model)
                                .equatable()
                                .frame(maxWidth: 690, alignment: .leading)
                                .padding(.horizontal, compact ? Studio.small : Studio.section)
                                .padding(.vertical, Studio.section)
                                .frame(maxWidth: .infinity)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Studio.surface)
                                .accessibilityActions {
                                    if answer.state != .invalidated && !answer.text.isEmpty {
                                        Button("Copy answer") { copy(answer.text) }
                                    }
                                    if model.state.isRunning {
                                        Button(revisionAction(answer)) { model.regenerateAnswer(answer.id) }
                                    }
                                    if answer.state == .generating {
                                        Button("Cancel answer", action: model.cancelAnswer)
                                    }
                                }
                        }
                        Color.clear.frame(height: 1).id(Anchor.bottom).accessibilityHidden(true)
                            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                            .listRowBackground(Studio.surface)
                    }
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(ChatScrollInput { followsLatest = false })
                    .studioSurface()
                    .accessibilityLabel("Interview chat")
                    .onChange(of: answers.last?.id, initial: true) { old, new in
                        guard old != new || old == nil else { return }
                        if followsLatest { scheduleFollow(proxy) }
                        else { pendingNew += 1 }
                    }
                    .onChange(of: answers.last?.text.utf8.count) { _, _ in
                        if followsLatest && !fitLatest { scheduleFollow(proxy) }
                    }
                    .onChange(of: fitLatest) { _, _ in if followsLatest { jump(proxy) } }
                    .onDisappear { scheduledFollow?.cancel(); scheduledFollow = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scheduleFollow(_ proxy: ScrollViewProxy) {
        guard scheduledFollow == nil else { return }
        scheduledFollow = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            scheduledFollow = nil
            if followsLatest { jump(proxy) }
        }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let latest = answers.last else { return }
        pendingNew = 0
        if fitLatest { proxy.scrollTo(latest.id, anchor: .top) }
        else { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
    }
}

private struct AnswerEntry: View, Equatable {
    let answer: InterviewAnswer
    let number: Int?
    let fontSize: Double
    let compact: Bool
    let answersOnly: Bool
    let model: WorkspaceModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.answer == rhs.answer && lhs.number == rhs.number && lhs.fontSize == rhs.fontSize
            && lhs.compact == rhs.compact && lhs.answersOnly == rhs.answersOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.row) {
            if !answersOnly {
                HStack(alignment: .firstTextBaseline, spacing: Studio.small) {
                    if let number { Text("Q\(number)").foregroundStyle(Studio.accent).fontWeight(.semibold) }
                    if let origin = answer.originLabel { Text(origin) }
                    Text(answer.format.rawValue)
                    Spacer(minLength: 0)
                    if let date = answer.createdAt, !compact { Text(date, style: .time) }
                }
                .font(.caption).foregroundStyle(Studio.secondary).accessibilityElement(children: .combine)
                Text(answer.question.original)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(Studio.primary).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            }
            if answer.state == .invalidated {
                Label(answer.failure ?? "Answer withdrawn", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Studio.warning)
            } else {
                if !answer.text.isEmpty {
                    AnswerText(text: answer.text, format: answer.format, fontSize: fontSize,
                               revision: answer.revision, acknowledge: model.responseVisible).equatable()
                }
                if !answer.evidence.isEmpty {
                    DisclosureGroup("Approved profile evidence") {
                        VStack(alignment: .leading, spacing: Studio.tight) {
                            ForEach(Array(answer.evidence.enumerated()), id: \.offset) { _, fact in
                                Text(fact).textSelection(.enabled)
                            }
                        }.padding(.top, Studio.tight)
                    }
                    .font(.callout).foregroundStyle(Studio.secondary)
                }
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: Studio.tight) {
            Text(answer.state.rawValue.capitalized).font(.caption).foregroundStyle(Studio.muted).lineLimit(1)
            if let usage = answer.usage, !compact {
                Text("\(usage.input) in / \(usage.output) out").font(.caption).foregroundStyle(Studio.muted)
            }
            Spacer(minLength: 0)
            if answer.state != .invalidated && !answer.text.isEmpty {
                Button { copy(answer.text) } label: { Image(systemName: "doc.on.doc") }
                .studioIcon("Copy answer")
            }
            if answer.state == .generating {
                Button(action: model.cancelAnswer) { Image(systemName: "xmark.circle") }.studioIcon("Cancel answer")
            }
            Button {
                model.regenerateAnswer(answer.id)
            } label: { Image(systemName: "arrow.clockwise") }
            .studioIcon(revisionAction(answer))
            .disabled(!model.state.isRunning)
            Menu {
                ForEach(AnswerFormat.allCases) { format in
                    Button(format.rawValue) { model.regenerateAnswer(answer.id, format: format) }
                }
            } label: { Image(systemName: "textformat") }
            .fixedSize().studioIcon("Answer format").disabled(!model.state.isRunning)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottomLeading) {
            if answer.state == .failed, let failure = answer.failure {
                Color.clear.help(failure).accessibilityLabel(failure).allowsHitTesting(false)
            }
        }
    }
}

@MainActor private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func revisionAction(_ answer: InterviewAnswer) -> String {
    switch answer.state {
    case .failed: "Retry answer"
    case .invalidated: "Generate manually"
    default: "Regenerate answer"
    }
}

private struct ChatScrollInput: NSViewRepresentable {
    let suspend: () -> Void

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) { view.suspend = suspend }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.removeMonitor() }

    final class Host: NSView {
        var suspend: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
                self?.scrollInput(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func scrollInput(_ event: NSEvent) {
            guard event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) || event.type == .keyDown,
                  let scroll = scrollView() else { return }
            let point = scroll.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .scrollWheel where event.scrollingDeltaY > 0 && scroll.bounds.contains(point): suspend?()
            case .leftMouseDown:
                if let bar = scroll.verticalScroller, !bar.isHidden,
                   bar.bounds.contains(bar.convert(event.locationInWindow, from: nil)) { suspend?() }
                else if scroll.contentView.bounds.contains(scroll.contentView.convert(event.locationInWindow, from: nil)) { suspend?() }
            case .keyDown:
                if let focused = window?.firstResponder as? NSView, focused === scroll || focused.isDescendant(of: scroll),
                   [115, 116, 126].contains(event.keyCode) { suspend?() }
            default: break
            }
        }

        private func scrollView() -> NSScrollView? {
            if let enclosingScrollView { return enclosingScrollView }
            guard let root = window?.contentView else { return nil }
            let probeFrame = convert(bounds, to: nil)
            guard !probeFrame.isEmpty else { return nil }
            var candidates = [root]
            // Match the represented list's viewport, excluding neighboring inspector and sidebar scrolling.
            while let candidate = candidates.popLast() {
                let frame = candidate.convert(candidate.bounds, to: nil)
                if !frame.intersects(probeFrame) { continue }
                if let scroll = candidate as? NSScrollView,
                   frame.intersection(probeFrame).height >= min(frame.height, probeFrame.height) * 0.9,
                   frame.intersection(probeFrame).width >= probeFrame.width * 0.9 { return scroll }
                candidates.append(contentsOf: candidate.subviews)
            }
            return nil
        }
    }
}

private struct AnswerText: View, Equatable {
    let text: String
    let format: AnswerFormat
    let fontSize: Double
    let revision: UUID
    let acknowledge: (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.text == rhs.text && lhs.format == rhs.format && lhs.fontSize == rhs.fontSize
    }

    var body: some View {
        let blocks = AnswerPresentation.blocks(for: text, format: format)
        let firstUseful = blocks.firstIndex { block in
            switch block {
            case .paragraph(let text), .item(_, let text), .code(let text):
                text.lazy.filter { $0.isLetter || $0.isNumber }.prefix(8).count == 8
            case .heading: false
            }
        }
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                render(block).background(alignment: .topLeading) {
                    if index == firstUseful {
                        AnswerViewport(revision: revision, acknowledge: acknowledge)
                            .frame(maxWidth: 160)
                            .frame(height: fontSize * 1.15)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .font(.system(size: fontSize))
        .lineSpacing(6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func render(_ block: AnswerBlock) -> some View {
        switch block {
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .heading(let text):
                    Text(Self.inline(text))
                        .bold()
                        .foregroundStyle(format == .star || format == .technical ? Color.accentColor : Color.primary)
                        .accessibilityAddTraits(.isHeader)
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                    .accessibilityElement(children: .combine)
                case .code(let text):
                    Text(text)
                        .font(.system(size: fontSize * 0.9, design: .monospaced))
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        attributed.link = nil
        return attributed
    }
}
