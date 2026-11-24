import ConversationCore
import SwiftUI
import UniformTypeIdentifiers

struct InterviewReviewView: View {
    @ObservedObject var model: WorkspaceModel
    let store: KnowledgeStore
    let current: SavedInterview?
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SavedInterview] = []
    @State private var record: SavedInterview?
    @State private var search = ""
    @State private var error: String?
    @State private var export = false
    @State private var confirmDelete = false
    @State private var question = ""
    @State private var actual = ""
    @State private var reviewing = false
    @State private var reviewTask: Task<Void, Never>?

    var body: some View {
        VStack {
            HStack {
                Text("Review and History").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                VStack(alignment: .leading) {
                    TextField("Search saved sessions", text: $search)
                    if let current {
                        Button("Current Session") { select(current) }
                    }
                    List(results) { item in
                        Button {
                            select(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.startedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }.frame(minWidth: 230, idealWidth: 260)
                if let record {
                    details(record).frame(minWidth: 475)
                } else {
                    ContentUnavailableView("No session selected", systemImage: "clock")
                        .frame(minWidth: 475)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(16)
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

    private func details(_ entry: SavedInterview) -> some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Session title", text: $record.title)
                Button("Save Locally") { save() }
                Button("Export Text") { export = true }
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .disabled(!results.contains(where: { $0.id == entry.id }))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Transcript").font(.headline)
                    ForEach(entry.transcript) { turn in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(turn.role.rawValue.capitalized).font(.caption)
                                if let timestamp = turn.timestamp {
                                    Text(timestamp, style: .time).font(.caption)
                                }
                                Spacer()
                                if turn.role == .interviewer || turn.role == .unknown {
                                    Button("Mark Missed") {
                                        if record?.missedQuestions.contains(turn.text) == false {
                                            record?.missedQuestions.append(turn.text)
                                        }
                                    }.buttonStyle(.link)
                                }
                                if turn.role == .candidate {
                                    Button("Use as Actual Answer") { actual = turn.text }.buttonStyle(.link)
                                }
                            }
                            Text(turn.text).textSelection(.enabled)
                        }
                    }
                    Text("Suggested answers").font(.headline)
                    ForEach(entry.suggestions) { answer in
                        VStack(alignment: .leading) {
                            Text(answer.question.original).fontWeight(.medium)
                            Text(answer.text).textSelection(.enabled)
                            Button("Review This Question") { question = answer.question.original }.buttonStyle(.link)
                        }
                    }
                    if !entry.missedQuestions.isEmpty {
                        Text("Missed questions").font(.headline)
                        ForEach(Array(entry.missedQuestions.enumerated()), id: \.offset) { _, missed in
                            HStack {
                                Text(missed)
                                Spacer()
                                Button("Review") { question = missed }.buttonStyle(.link)
                                Button("Remove") { record?.missedQuestions.removeAll { $0 == missed } }.buttonStyle(.link)
                            }
                        }
                    }
                    TextField("Practice notes", text: $record.notes, axis: .vertical)
                    Divider()
                    Text("Coaching · AI estimates").font(.headline)
                    TextField("Interview question", text: $question, axis: .vertical)
                    TextField("Actual candidate answer", text: $actual, axis: .vertical)
                    Button(reviewing ? "Cancel Coaching" : "Get Coaching") { coach() }
                        .disabled(!reviewing && entry.coachingInput(question: question, actualAnswer: actual) == nil)
                        .help("Sends the selected question and answer to the configured text provider.")
                    if !entry.coaching.isEmpty {
                        Text(entry.coaching).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .padding(.leading, 12)
    }

    private func select(_ item: SavedInterview) {
        reviewTask?.cancel()
        reviewTask = nil
        reviewing = false
        record = item
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
                error = publicErrorMessage(error)
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
                if record?.id == id { record = nil }
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
    @ObservedObject var model: WorkspaceModel
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
                Text("Solo Practice").font(.title2)
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
            Text(question).font(.title3)
            TextField("Use your own question", text: $customQuestion).disabled(task != nil)
            Text("Your answer").font(.headline)
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
        .padding(18)
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
                error = publicErrorMessage(error)
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
