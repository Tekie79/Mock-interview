import AppKit
import ConversationCore
import LocalAuthentication
import Security
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditor: View {
    private enum Attachment {
        case file(URL)
        case pasted(String)

        var name: String {
            switch self {
            case .file(let url): url.lastPathComponent
            case .pasted: "Pasted text"
            }
        }

        func read(kind: ProfileDocument.Kind) async throws -> ProfileDocument {
            switch self {
            case .pasted(let text):
                return ProfileDocument(kind: kind, title: "Pasted " + kind.rawValue, text: text)
            case .file(let url):
                return try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try ProfileDocument.read(url, kind: kind)
                }.value
            }
        }
    }

    private static let attachmentTypes: [UTType] = [.plainText, .pdf] + ["md", "markdown", "docx"].compactMap {
        UTType(filenameExtension: $0)
    }

    @Bindable var model: WorkspaceModel
    let store: KnowledgeStore
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var profile = InterviewProfile(name: "")
    @State private var facts: [ExperienceFact] = []
    @State private var documents: [ProfileDocument] = []
    @State private var claim = ""
    @State private var pastedText = ""
    @State private var kind: ProfileDocument.Kind = .resume
    @State private var picker = false
    @State private var attaching = false
    @State private var showingPaste = false
    @State private var showingProjectStory = false
    @State private var message: String?
    @State private var selectedFact: ExperienceFact?
    @State private var deleteConfirmation = false
    @State private var indexing = false
    @AppStorage("semanticRetrieval") private var semanticRetrieval = false

    private var hasProfileName: Bool { !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private enum Page: String, CaseIterable {
        case overview = "Overview", skills = "Skills", experience = "Experience"
        case projects = "Projects", documents = "Documents", answers = "Answer Preferences"
    }
    @State private var page = Page.overview
    @State private var selection: UUID?
    @State private var documentCounts: [UUID: Int] = [:]
    @State private var editingStory: ExperienceFact?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: Studio.tight) {
                StudioHeading(title: "Profiles")
                Button("New Profile", systemImage: "plus") { select(InterviewProfile(name: "")) }
                    .disabled(model.active || attaching)
                List(model.profiles, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: Studio.small) {
                        Text(item.name).font(.headline).lineLimit(1)
                        if !item.role.isEmpty { Text(item.role).font(.caption).lineLimit(1) }
                        HStack {
                            Text("\(documentCounts[item.id, default: 0]) documents")
                            if let date = item.modifiedAt { Text(date, style: .date) }
                        }.font(.caption2).foregroundStyle(Studio.secondary)
                    }.tag(item.id)
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Interview profiles")
                .onChange(of: selection) { _, id in
                    guard let item = model.profiles.first(where: { $0.id == id }), item.id != profile.id else { return }
                    select(item)
                }
            }.padding(Studio.section).frame(minWidth: 170, idealWidth: 205)
            VStack(alignment: .leading, spacing: Studio.row) {
                HStack {
                    StudioHeading(title: hasProfileName ? profile.name : "New profile", detail: profile.role)
                    Spacer()
                    Menu {
                        Button("Duplicate Profile", systemImage: "plus.square.on.square", action: duplicate)
                        Button("Delete Profile", systemImage: "trash", role: .destructive) { deleteConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .studioIcon("Profile actions")
                    .disabled(model.active || !model.profiles.contains(where: { $0.id == profile.id }))
                    if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                    Button("Save Profile", action: save).buttonStyle(.borderedProminent)
                        .disabled(!hasProfileName || model.active)
                }
                Picker("Profile section", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityLabel("Profile section")
                ScrollView {
                    VStack(alignment: .leading, spacing: Studio.section) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Studio.section)
                }.studioSurface().id(page)
                .disabled(model.active || attaching)
                if model.active { Text("Stop the interview to edit profiles.").font(.caption).foregroundStyle(Studio.secondary) }
                if let message { Text(message).font(.callout).foregroundStyle(Studio.secondary) }
            }.padding(Studio.page).frame(minWidth: 360)
        }
        .background(Studio.canvas)
        .task { documentCounts = (try? await store.profileDocumentCounts()) ?? [:] }
        .onChange(of: model.profiles) { _, _ in
            Task { documentCounts = (try? await store.profileDocumentCounts()) ?? [:] }
        }
        .task { if let item = model.profiles.first(where: { $0.id == model.profileID }) { select(item) } }
        .fileImporter(isPresented: $picker, allowedContentTypes: Self.attachmentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): attach(urls.map(Attachment.file))
            case .failure:
                message = "The selected document could not be opened."
            }
        }
        .sheet(item: $selectedFact) { fact in
            FactEditor(fact: fact, save: { update in
                Task { await change { id in try await store.save(update, profile: id) } }
            }, remove: {
                Task { await change { id in try await store.deleteFact(fact.id, profile: id) } }
            })
        }
        .sheet(item: $editingStory) { existing in
            ProjectStoryEditor(existing: existing) { story in
                Task { await change { id in try await store.save(story, profile: id) } }
            }
        }
        .sheet(isPresented: $showingProjectStory) {
            ProjectStoryEditor { story in
                Task { await change { id in try await store.save(story, profile: id) } }
            }
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

    @ViewBuilder private var content: some View {
        switch page {
        case .overview:
            TextField("Profile name", text: $profile.name)
            TextField("Target role", text: $profile.role)
            TextField("Seniority", text: $profile.seniority)
            TextField("Industry", text: $profile.industry)
            TextField("Professional summary", text: Binding(get: { profile.professionalSummary ?? "" },
                set: { profile.professionalSummary = $0 }), axis: .vertical).lineLimit(3...8)
        case .skills:
            TextField("Skills you’ve used", text: trainingField(\.skills), axis: .vertical).lineLimit(4...10)
        case .answers:
            TextField("Answer language", text: $profile.answerLanguage)
            TextField("Response instructions", text: $profile.instructions, axis: .vertical).lineLimit(2...5)
            TextField("Sample answer in your own words", text: trainingField(\.speakingSample), axis: .vertical).lineLimit(3...7)
        case .experience, .projects:
            let projects = page == .projects
            if projects { Button("Add Project Story…", systemImage: "plus") { showingProjectStory = true }.disabled(!hasProfileName) }
            else {
                HStack {
                    TextField("Add an experience fact", text: $claim)
                    Button("Add Fact") {
                        let fact = ExperienceFact(claim: claim, status: .confirmed)
                        claim = ""
                        Task { await change { id in try await store.save(fact, profile: id) } }
                    }.disabled(claim.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            let visible = facts.filter { ($0.category == ExperienceFact.projectStoryCategory) == projects }
            if visible.isEmpty { Text(projects ? "No project stories" : "No experience facts").foregroundStyle(Studio.muted) }
            ForEach(visible) { fact in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Studio.small) {
                        Text(fact.claim).lineLimit(5)
                        Text(fact.status == .confirmed ? "Approved" : fact.status == .pending ? "Pending" : "Excluded")
                            .font(.caption).foregroundStyle(fact.status == .confirmed ? Studio.success : Studio.warning)
                    }
                    Spacer()
                    Button("Edit") {
                        if projects { editingStory = fact } else { selectedFact = fact }
                    }.buttonStyle(.borderless)
                    if projects {
                        Button("Evidence Settings") { selectedFact = fact }.buttonStyle(.borderless)
                    }
                }
                Divider()
            }
            if !projects {
                HStack {
                    if semanticRetrieval {
                        Button(indexing ? "Indexing…" : "Build Embeddings", action: reindex)
                            .disabled(indexing || !facts.contains(where: { $0.status == .confirmed }))
                    }
                    Button("Clear Embeddings") {
                        let id = profile.id
                        Task {
                            do { try await store.clearFactIndex(profile: id); if profile.id == id { message = "Embedding index cleared." } }
                            catch { if profile.id == id { message = "The embedding index could not be cleared." } }
                        }
                    }.disabled(indexing || !model.profiles.contains(where: { $0.id == profile.id }))
                }
            }
        case .documents:
            attachmentControls
            if documents.isEmpty { Text("No attachments").foregroundStyle(Studio.muted) }
            ForEach(documents) { document in attachmentRow(document); Divider() }
        }
    }

    private func duplicate() {
        let id = profile.id
        Task {
            do {
                let copy = try await store.duplicateProfile(id)
                await model.reloadProfiles()
                select(copy)
            } catch { message = "The profile could not be duplicated." }
        }
    }

    private func trainingField(_ key: WritableKeyPath<ProfileAnswerTraining, String>) -> Binding<String> {
        Binding(
            get: { profile.answerTraining?[keyPath: key] ?? "" },
            set: { value in
                var training = profile.answerTraining ?? .init()
                training[keyPath: key] = value
                profile.answerTraining = training
            }
        )
    }

    private var attachmentControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Attach as", selection: $kind) {
                    ForEach(ProfileDocument.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                Button(attaching ? "Attaching…" : "Attach Files…") { picker = true }
                    .disabled(!hasProfileName)
            }
            Text(hasProfileName ? "Markdown (.md, .markdown), text, PDF, or DOCX." : "Enter a profile name to add attachments.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Résumé and project notes are used in answers. Job descriptions guide the role.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Paste document text", isExpanded: $showingPaste) {
                HStack(alignment: .top) {
                    TextField("Document text", text: $pastedText, axis: .vertical).lineLimit(2...4)
                    Button("Attach Text") { attach([.pasted(pastedText)]) }
                        .disabled(!hasProfileName || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 4)
            }
        }
        .disabled(attaching)
    }

    private func attachmentRow(_ document: ProfileDocument) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title).lineLimit(1).truncationMode(.middle).help(document.title)
                Text(document.kind.rawValue + " · Imported").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", role: .destructive) {
                Task { await change { id in try await store.deleteDocument(document.id, profile: id) } }
            }.buttonStyle(.borderless).accessibilityLabel("Remove " + document.title)
        }
    }

    private func reindex() {
        let id = profile.id
        indexing = true
        Task {
            defer { indexing = false }
            do {
                guard let provider = try await SessionProviders.embeddings(defaults: .standard) else { return }
                let count = try await store.indexConfirmedFacts(profile: id, provider: provider)
                if profile.id == id { message = "Indexed \(count) approved facts." }
            } catch {
                if profile.id == id { message = publicErrorMessage(error) }
            }
        }
    }

    private func select(_ item: InterviewProfile) {
        profile = item
        selection = model.profiles.contains(where: { $0.id == item.id }) ? item.id : nil
        page = .overview
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
        Task { await change { _ in } }
    }

    private func attach(_ attachments: [Attachment]) {
        guard !attachments.isEmpty, hasProfileName, !attaching else { return }
        var target = profile
        target.modifiedAt = .now
        let type = kind
        attaching = true
        message = nil
        Task {
            defer { attaching = false }
            var saved = false
            var attached = 0
            var firstFailure: String?
            for attachment in attachments {
                do {
                    let document = try await attachment.read(kind: type)
                    if !saved {
                        try await store.save(target)
                        saved = true
                    }
                    try await store.add(document, to: target.id)
                    attached += 1
                    if case .pasted = attachment { pastedText = "" }
                } catch {
                    if firstFailure == nil { firstFailure = attachment.name + " — " + attachmentFailure(error) }
                }
            }
            if saved { await model.reloadProfiles() }
            guard profile.id == target.id else { return }
            if saved {
                model.profileID = target.id
                await refresh(target.id)
            }
            let failures = attachments.count - attached
            if let firstFailure {
                message = attachments.count == 1 ? firstFailure : "Attached \(attached) of \(attachments.count) files. \(failures) failed. \(firstFailure)"
            } else {
                message = attached == 1 ? "Attached \(attachments[0].name)." : "Attached \(attached) files."
            }
        }
    }

    private func attachmentFailure(_ error: Error) -> String {
        switch error {
        case StorageFailure.emptyDocument: "No text was found. Try a text-based file or paste the text."
        case StorageFailure.documentTooLarge: "The document is too large to attach."
        case StorageFailure.unsupportedFormat: "Choose a Markdown, text, PDF, or DOCX file."
        default: "Could not read or attach the document. Check that it opens locally."
        }
    }

    private func change(_ operation: (UUID) async throws -> Void) async {
        var target = profile
        target.modifiedAt = .now
        do {
            try await store.save(target)
            try await operation(target.id)
            await model.reloadProfiles()
            guard profile.id == target.id else { return }
            model.profileID = target.id
            await refresh(target.id)
            message = nil
        } catch {
            if profile.id == target.id { message = "Could not save. Enter a profile name and check the document or fact." }
        }
    }
}

private struct ProjectStoryEditor: View {
    var existing: ExperienceFact? = nil
    let save: (ExperienceFact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var source = ""
    @State private var destination = ""
    @State private var data = ""
    @State private var technologies = ""
    @State private var contribution = ""
    @State private var outcome = ""

    var body: some View {
        Form {
            Text("Project Story").font(.title2)
            TextField("Project name", text: $title)
            TextField("Source systems", text: $source)
            TextField("Destination", text: $destination)
            TextField("Types of data", text: $data)
            TextField("Technologies", text: $technologies)
            TextField("What I did", text: $contribution, axis: .vertical).lineLimit(2...5)
            TextField("Outcome", text: $outcome, axis: .vertical).lineLimit(1...3)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Project Story", action: saveStory)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || contribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 470)
        .onAppear {
            guard let existing else { return }
            let labels = ["Project", "Source", "Destination", "Data", "Technologies", "What I did", "Outcome"]
            var fields: [String: String] = [:]
            var current: String?
            for line in existing.claim.components(separatedBy: "\n") {
                if let label = labels.first(where: { line.hasPrefix($0 + ": ") }) {
                    current = label
                    fields[label] = String(line.dropFirst(label.count + 2))
                } else if let current { fields[current, default: ""] += "\n" + line }
            }
            title = fields["Project"] ?? ""
            source = fields["Source"] ?? ""
            destination = fields["Destination"] ?? ""
            data = fields["Data"] ?? ""
            technologies = fields["Technologies"] ?? ""
            contribution = fields["What I did"] ?? existing.claim
            outcome = fields["Outcome"] ?? ""
        }
    }

    private func saveStory() {
        let fields = [("Project", title), ("Source", source), ("Destination", destination), ("Data", data),
                      ("Technologies", technologies), ("What I did", contribution), ("Outcome", outcome)]
        let claim = fields.compactMap { label, value -> String? in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : label + ": " + text
        }.joined(separator: "\n")
        var story = existing ?? .init(category: ExperienceFact.projectStoryCategory, claim: claim, status: .confirmed)
        story.claim = claim
        save(story)
        dismiss()
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
            Toggle("Use in answers", isOn: Binding(
                get: { fact.status == .confirmed },
                set: { fact.status = $0 ? .confirmed : .rejected }
            ))
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
