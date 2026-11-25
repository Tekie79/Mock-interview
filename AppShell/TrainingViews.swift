import ConversationCore
import SwiftUI
import UniformTypeIdentifiers

struct InterviewReviewView: View {
    @Bindable var model: WorkspaceModel
    let store: KnowledgeStore
    let current: SavedInterview?
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SavedInterview] = []
    @State private var record: SavedInterview?
    @State private var selection: UUID?
    @State private var search = ""
    @State private var error: String?
    @State private var export = false
    @State private var confirmDelete = false
    @State private var question = ""
    @State private var actual = ""
    @State private var reviewing = false
    @State private var reviewTask: Task<Void, Never>?
    private enum SectionPage: String, CaseIterable { case transcript = "Transcript", suggestions = "Suggestions", evaluation = "Evaluation" }
    @State private var page = SectionPage.transcript
    @State private var reviewOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.section) {
            HStack {
                StudioHeading(title: "Interview History")
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            HSplitView {
                VStack(alignment: .leading) {
                    TextField("Search saved sessions", text: $search)
                    Toggle("With evaluation", isOn: $reviewOnly).font(.caption)
                    if let current {
                        Button("Current Session") { select(current) }
                    }
                    List(results.filter { !reviewOnly || !$0.coaching.isEmpty }, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: Studio.small) {
                            Text(item.title).font(.headline)
                            if let profile = item.profileName { Text(profile).font(.caption) }
                            Text(item.startedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(Studio.secondary)
                            Text("\(duration(of: item)) · \(item.suggestions.count) questions")
                                .font(.caption).foregroundStyle(Studio.secondary)
                            Text(item.coaching.isEmpty ? "Available for review" : "Evaluated")
                                .font(.caption2).foregroundStyle(Studio.muted)
                        }
                        .padding(.vertical, Studio.small)
                        .tag(item.id)
                    }
                    .listStyle(.sidebar).accessibilityLabel("Saved sessions")
                    .onChange(of: selection) { _, id in
                        guard id != record?.id, let item = results.first(where: { $0.id == id }) else { return }
                        select(item)
                    }
                }.frame(minWidth: 160, idealWidth: 235, maxWidth: 300)
                if let record {
                    details(record).frame(minWidth: 315)
                } else {
                    StudioEmpty(title: results.isEmpty ? "No saved sessions" : "Select a session",
                                icon: "clock.arrow.circlepath",
                                detail: results.isEmpty ? "Save a completed interview or practice response to review it here." : "Open a session to review speech, suggestions, and evaluation.")
                        .studioSurface().frame(minWidth: 315)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(Studio.page)
        .background(Studio.canvas)
        .task(id: search) { await refresh() }
        .onAppear { if let current { select(current) } }
        .onDisappear { reviewTask?.cancel() }
        .fileExporter(isPresented: $export, document: ReviewExport(text: record?.plainText ?? ""),
                      contentType: .plainText, defaultFilename: "Mock Interview Review") { result in
            if case .failure = result { error = "Export failed." }
        }
        .confirmationDialog("Delete this saved session and its search entries?", isPresented: $confirmDelete) {
            Button("Delete Saved Session", role: .destructive) { delete() }
        }
    }

    private func duration(of item: SavedInterview) -> String {
        Duration.seconds(max(0, Int(item.endedAt.timeIntervalSince(item.startedAt))))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    private func details(_ entry: SavedInterview) -> some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Session title", text: $record.title)
                Button("Save Locally") { save() }
                Button("Export Text") { export = true }
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .disabled(!results.contains(where: { $0.id == entry.id }))
            }
            Picker("Review section", selection: $page) {
                ForEach(SectionPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Studio.section) {
                    switch page {
                    case .transcript:
                        ForEach(entry.transcript) { turn in
                            VStack(alignment: .leading, spacing: Studio.small) {
                                HStack {
                                    Text(turn.role == .candidate ? "Actual candidate speech" : turn.role.rawValue.capitalized)
                                        .font(.caption.weight(.semibold)).foregroundStyle(Studio.secondary)
                                    Spacer(minLength: 0)
                                    if let timestamp = turn.timestamp { Text(timestamp, style: .time).font(.caption) }
                                }
                                Text(turn.text).textSelection(.enabled)
                                HStack {
                                    if turn.role == .candidate {
                                        Button("Use as Actual Answer") { actual = turn.text; page = .evaluation }.buttonStyle(.link)
                                    } else {
                                        Button("Use as Question") { question = turn.text; page = .evaluation }.buttonStyle(.link)
                                        Button("Mark Missed") {
                                            if record?.missedQuestions.contains(turn.text) == false { record?.missedQuestions.append(turn.text) }
                                        }.buttonStyle(.link)
                                    }
                                }
                            }
                            Divider()
                        }
                    case .suggestions:
                        ForEach(entry.suggestions) { answer in
                            VStack(alignment: .leading, spacing: Studio.tight) {
                                Text(answer.question.original).font(.headline)
                                Text("AI-suggested answer").font(.caption).foregroundStyle(Studio.secondary)
                                if answer.state == .invalidated {
                                    Text(answer.failure ?? "Answer withdrawn").foregroundStyle(Studio.warning)
                                } else {
                                    Text(answer.text).textSelection(.enabled)
                                    Button("Review This Question") { question = answer.question.original; page = .evaluation }.buttonStyle(.link)
                                }
                            }
                            Divider()
                        }
                        ForEach(Array(entry.missedQuestions.enumerated()), id: \.offset) { _, missed in
                            HStack {
                                Text(missed)
                                Spacer()
                                Button("Review") { question = missed; page = .evaluation }.buttonStyle(.link)
                                Button("Remove") { record?.missedQuestions.removeAll { $0 == missed } }.buttonStyle(.link)
                            }
                        }
                    case .evaluation:
                        StudioHeading(title: "Evaluation", detail: "AI-generated coaching and improvement recommendations")
                        TextField("Interviewer question", text: $question, axis: .vertical)
                        TextField("Actual candidate answer", text: $actual, axis: .vertical).lineLimit(3...8)
                        Button(reviewing ? "Cancel Coaching" : "Get Coaching", action: coach)
                            .disabled(!reviewing && entry.coachingInput(question: question, actualAnswer: actual) == nil)
                            .help("Sends the selected question and actual answer to the configured text provider.")
                        if !entry.coaching.isEmpty { Text(entry.coaching).textSelection(.enabled) }
                        TextField("Practice notes", text: $record.notes, axis: .vertical)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Studio.section)
            }.studioSurface().id(page)
        }
        .padding(.leading, Studio.section)
    }

    private func select(_ item: SavedInterview) {
        reviewTask?.cancel()
        reviewTask = nil
        reviewing = false
        record = item
        selection = item.id
        page = .transcript
        question = ""
        actual = ""
        error = nil
    }

    private func coach() {
        if reviewing {
            reviewTask?.cancel()
            return
        }
        guard let entry = record, let input = entry.coachingInput(question: question, actualAnswer: actual) else { return }
        reviewing = true
        error = nil
        reviewTask = Task {
            do {
                let feedback = try await model.coaching(input)
                guard !Task.isCancelled, record?.id == entry.id else { return }
                record?.coaching = feedback
            } catch where !Task.isCancelled {
                self.error = publicErrorMessage(error)
            } catch {}
            if record?.id == entry.id { reviewing = false }
        }
    }

    private func save() {
        guard let entry = record else { return }
        Task {
            do {
                try await store.saveInterview(entry)
                await refresh()
            } catch { self.error = "The session could not be saved." }
        }
    }

    private func delete() {
        guard let id = record?.id else { return }
        Task {
            do {
                try await store.deleteInterview(id)
                if record?.id == id { record = nil; selection = nil }
                await refresh()
            } catch { self.error = "The saved session could not be deleted." }
        }
    }

    private func refresh() async {
        let query = search
        do {
            let matches = try await store.savedInterviews(matching: query)
            if !Task.isCancelled, query == search { results = matches }
        } catch {
            if !Task.isCancelled { self.error = "Saved sessions could not be loaded." }
        }
    }
}

private extension Binding where Value == SavedInterview? {
    var title: Binding<String> {
        Binding<String>(get: { wrappedValue?.title ?? "" }, set: { wrappedValue?.title = $0 })
    }

    var notes: Binding<String> {
        Binding<String>(get: { wrappedValue?.notes ?? "" }, set: { wrappedValue?.notes = $0 })
    }
}

private struct ReviewExport: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw StorageFailure.unsupportedFormat
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct SoloPracticeView: View {
    @Bindable var model: WorkspaceModel
    @State private var index = 0
    @State private var customQuestion = ""
    @State private var answer = ""
    @State private var feedback = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var startedAt = Date.now
    @State private var saved = false

    private var question: String {
        customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PracticePrompt.bank[index].question : customQuestion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StudioHeading(title: "Practice", detail: "Choose a prompt, write your response, and review feedback.")
                Spacer()
                Button("Next Question") {
                    index = (index + 1) % PracticePrompt.bank.count
                    customQuestion = ""
                    answer = ""
                    feedback = ""
                    error = nil
                    saved = false
                    startedAt = .now
                }.disabled(task != nil)
            }
            Text("Question").font(.caption.weight(.semibold)).foregroundStyle(Studio.secondary)
            Text(question).font(.title3.weight(.semibold)).foregroundStyle(Studio.primary)
                .padding(Studio.section).frame(maxWidth: .infinity, alignment: .leading).studioSurface()
            TextField("Use your own question", text: $customQuestion).disabled(task != nil)
            Text("Your practice response").font(.headline)
            TextEditor(text: $answer)
                .frame(minHeight: 95)
                .accessibilityLabel("Your actual answer")
                .disabled(task != nil)
            HStack {
                Button(task == nil ? "Get Coaching" : "Cancel Coaching", action: coach)
                    .disabled(task == nil && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Sends your question and answer to the configured text provider.")
                Button(saved ? "Saved Locally" : "Save Locally", action: save)
                    .disabled(saved || task != nil || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !feedback.isEmpty {
                Text("Coaching · AI estimates").font(.headline)
                ScrollView { Text(feedback).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }
        .padding(Studio.page)
        .background(Studio.canvas)
        .onDisappear { task?.cancel() }
        .onChange(of: answer) { _, _ in saved = false }
        .onChange(of: customQuestion) { _, _ in saved = false }
    }

    private func coach() {
        if let task { task.cancel(); return }
        let input = CoachingInput(question: question, candidateAnswer: answer)
        error = nil
        task = Task {
            defer { task = nil }
            do {
                feedback = try await model.coaching(input)
                saved = false
            } catch where !Task.isCancelled {
                self.error = publicErrorMessage(error)
            } catch {}
        }
    }

    private func save() {
        guard let store = model.store else { error = "Local session storage is unavailable."; return }
        let entry = SavedInterview(title: "Solo practice", startedAt: startedAt, endedAt: .now, transcript: [
            InterviewTranscript(id: "prompt", role: .interviewer, text: question, isFinal: true),
            InterviewTranscript(id: "actual", role: .candidate, text: answer, isFinal: true)
        ], suggestions: [], coaching: feedback)
        Task {
            do {
                try await store.saveInterview(entry)
                saved = true
            } catch { self.error = "The session could not be saved." }
        }
    }
}
