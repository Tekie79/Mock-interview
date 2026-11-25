import Foundation
#if os(macOS)
import PDFKit
#endif

public struct ProfileAnswerTraining: Codable, Equatable, Sendable {
    public var skills: String
    public var speakingSample: String

    public init(skills: String = "", speakingSample: String = "") {
        self.skills = skills
        self.speakingSample = speakingSample
    }

    func limited(to budget: ContextBudget) -> Self? {
        let skills = skills.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = speakingSample.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillsBudget = sample.isEmpty ? budget : budget.share(35)
        let keptSkills = skillsBudget.limit([skills]).first ?? ""
        let sampleBudget = ContextBudget(turns: budget.turns, tokenBudget: budget.tokenBudget - keptSkills.utf8.count)
        let keptSample = sampleBudget.limit([sample]).first ?? ""
        guard !keptSkills.isEmpty || !keptSample.isEmpty else { return nil }
        return .init(skills: keptSkills, speakingSample: keptSample)
    }
}

public struct InterviewProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var role: String
    public var seniority: String
    public var industry: String
    public var instructions: String
    public var answerLanguage: String
    public var answerTraining: ProfileAnswerTraining?

    public init(id: UUID = UUID(), name: String, role: String = "", seniority: String = "",
                industry: String = "", instructions: String = "", answerLanguage: String = "",
                answerTraining: ProfileAnswerTraining? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.seniority = seniority
        self.industry = industry
        self.instructions = instructions
        self.answerLanguage = answerLanguage
        self.answerTraining = answerTraining
    }
}

public struct ProfileDocument: Codable, Identifiable, Equatable, Sendable {
    private struct PageRegion: Codable, Equatable, Sendable {
        let lastLine: Int
        let page: Int
        let column: Int?
    }

    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case resume = "Résumé"
        case jobDescription = "Job description"
        case project = "Project notes"
        public var id: String { rawValue }

        fileprivate var isExperienceSource: Bool { self == .resume || self == .project }
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let text: String
    private var pageRegions: [PageRegion]?

    public init(id: UUID = UUID(), kind: Kind, title: String, text: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
    }

    public static func read(_ url: URL, kind: Kind) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw StorageFailure.documentTooLarge }
        let text: String
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown":
            text = try String(contentsOf: url, encoding: .utf8)
        case "docx":
            text = try DOCXDocument.text(from: Data(contentsOf: url))
        #if os(macOS)
        case "pdf":
            return try readPDF(url, kind: kind)
        #endif
        default: throw StorageFailure.unsupportedFormat
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.emptyDocument
        }
        return Self(kind: kind, title: url.lastPathComponent, text: text)
    }

    fileprivate func experienceFacts() -> [ExperienceFact] {
        guard kind.isExperienceSource else { return [] }
        let markdown = ["md", "markdown"].contains((title as NSString).pathExtension.lowercased())
        var fence: (marker: Character, count: Int)?
        var facts: [ExperienceFact] = []
        var block = (text: "", first: 0, last: 0)
        var regionIndex = 0
        let regions = pageRegions ?? []
        func flush() {
            defer { block.text = "" }
            guard (12...1_200).contains(block.text.count), !Self.unfinished(block.text),
                  block.text.range(of: #"^(?:and|or|with|to|of|from|including|which)\s"#,
                                   options: [.regularExpression, .caseInsensitive]) == nil else { return }
            let lines = block.first == block.last ? "Text line \(block.first)" : "Text lines \(block.first)–\(block.last)"
            let place = regions.indices.contains(regionIndex) ? regions[regionIndex] : nil
            let page = place.map { "Page \($0.page)" + ($0.column.map { ", column \($0)" } ?? "") + " · " } ?? ""
            facts.append(.init(documentID: id, locator: page + lines, claim: block.text, status: .confirmed,
                               sourceTitle: title))
        }
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let number = index + 1
            if regions.indices.contains(regionIndex), number > regions[regionIndex].lastLine {
                flush()
                while regions.indices.contains(regionIndex), number > regions[regionIndex].lastLine { regionIndex += 1 }
            }
            if facts.count >= 100 { break }
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if markdown {
                if let first = line.first, first == "`" || first == "~",
                   case let count = line.prefix(while: { $0 == first }).count, count >= 3 {
                    flush()
                    if let active = fence {
                        if first == active.marker, count >= active.count, line.count == count { fence = nil }
                    } else { fence = (first, count) }
                    continue
                }
                guard fence == nil else { continue }
                let hashes = line.prefix(while: { $0 == "#" })
                if (1...6).contains(hashes.count), line.dropFirst(hashes.count).first?.isWhitespace == true {
                    flush()
                    continue
                }
            }
            if line.isEmpty {
                flush()
                continue
            }
            let bullet = line.range(of: #"^(?:[-*+•▪‣]|\d+[.)])\s+"#, options: .regularExpression)
            if let bullet { line.removeSubrange(bullet) }
            if !block.text.isEmpty, bullet == nil, !block.text.hasSuffix(":"),
               !block.text.hasSuffix("."), !block.text.hasSuffix("!"), !block.text.hasSuffix("?"),
               Self.unfinished(block.text) || line.first?.isLowercase == true || rawLine.first?.isWhitespace == true {
                block.text += " " + line
                block.last = number
            } else {
                flush()
                block = (line, number, number)
            }
        }
        if facts.count < 100 { flush() }
        return Array(facts.prefix(100))
    }

    private static func unfinished(_ text: String) -> Bool {
        text.range(of: #"(?:[:…]|\.\.\.|\b(?:and|or|to|from|with|including|such as))$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    #if os(macOS)
    private struct PDFLine {
        let text: String
        let bounds: CGRect
    }

    private static func readPDF(_ url: URL, kind: Kind) throws -> Self {
        guard let pdf = PDFDocument(url: url) else { throw StorageFailure.emptyDocument }
        var lines: [String] = []
        var regions: [PageRegion] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let ordered = page.selection(for: bounds)?.selectionsByLine().compactMap { selection -> PDFLine? in
                guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return .init(text: text, bounds: selection.bounds(for: page))
            } ?? []
            let blocks = columns(in: ordered, page: bounds) ?? [(nil, page.string ?? "")]
            for (column, text) in blocks {
                let newLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
                guard newLines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
                lines.append(contentsOf: newLines)
                regions.append(.init(lastLine: lines.count, page: index + 1, column: column))
            }
        }
        guard !lines.isEmpty else { throw StorageFailure.emptyDocument }
        var document = Self(kind: kind, title: url.lastPathComponent, text: lines.joined(separator: "\n"))
        document.pageRegions = regions
        return document
    }

    private static func columns(in lines: [PDFLine], page: CGRect) -> [(Int?, String)]? {
        // Require a gutter, overlapping column heights, and no full-width line inside the
        // column body. Ambiguous pages keep the reading order supplied by PDFKit.
        for fraction in [0.5, 0.45, 0.55, 0.4, 0.6, 0.35, 0.65, 0.7] {
            let split = page.minX + page.width * fraction
            let left = lines.filter { $0.bounds.maxX <= split - 7 }
            let right = lines.filter { $0.bounds.minX >= split + 7 }
            guard left.count >= 2, right.count >= 2,
                  let leftTop = left.map(\.bounds.maxY).max(), let rightTop = right.map(\.bounds.maxY).max(),
                  let leftBottom = left.map(\.bounds.minY).min(), let rightBottom = right.map(\.bounds.minY).min(),
                  min(leftTop, rightTop) - max(leftBottom, rightBottom) >= 12 else { continue }
            let top = max(leftTop, rightTop)
            let bottom = min(leftBottom, rightBottom)
            let full = lines.filter { $0.bounds.maxX > split - 7 && $0.bounds.minX < split + 7 }
            guard full.allSatisfy({ $0.bounds.minY >= top - 1 || $0.bounds.maxY <= bottom + 1 }) else { continue }
            func readingOrder(_ block: [PDFLine]) -> String {
                block.sorted { $0.bounds.midY > $1.bounds.midY }.map(\.text).joined(separator: "\n")
            }
            return [(nil, readingOrder(full.filter { $0.bounds.midY >= top })), (1, readingOrder(left)),
                    (2, readingOrder(right)), (nil, readingOrder(full.filter { $0.bounds.midY < top }))]
        }
        return nil
    }
    #endif
}

public struct ExperienceFact: Codable, Identifiable, Equatable, Sendable {
    public static let projectStoryCategory = "Project story"

    public enum Status: String, Codable, CaseIterable, Identifiable, Sendable {
        case pending, confirmed, rejected
        public var id: String { rawValue }
    }

    public let id: UUID
    public var documentID: UUID?
    public var locator: String
    public var category: String
    public var claim: String
    public var ownership: String
    public var dates: String
    public var limitations: String
    public var status: Status
    public var sourceTitle: String?

    public init(id: UUID = UUID(), documentID: UUID? = nil, locator: String = "",
                category: String = "", claim: String, ownership: String = "", dates: String = "",
                limitations: String = "", status: Status = .pending, sourceTitle: String? = nil) {
        self.id = id
        self.documentID = documentID
        self.locator = locator
        self.category = category
        self.claim = claim
        self.ownership = ownership
        self.dates = dates
        self.limitations = limitations
        self.status = status
        self.sourceTitle = sourceTitle
    }

    public var promptText: String {
        [claim, labeled("Ownership", ownership), labeled("Dates", dates), labeled("Limitations", limitations),
         labeled("Source", sourceTitle ?? ""), labeled("Source location", locator)]
            .compactMap { $0 }.joined(separator: " | ")
    }

    private func labeled(_ label: String, _ value: String) -> String? {
        value.isEmpty ? nil : label + ": " + value
    }
}

public actor KnowledgeStore {
    let database: SQLiteDatabase

    public init(url: URL? = nil) throws {
        let database = try SQLiteDatabase(path: url?.path ?? ":memory:")
        try database.transaction {
            let versions = try database.query("PRAGMA user_version") { SQLiteDatabase.text($0, 0) }
            guard let version = versions.first, ["0", "1", "2", "3", "4"].contains(version) else {
                throw StorageFailure.invalidRecord
            }
            if version == "0" {
                try database.execute("""
                    CREATE TABLE profiles (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                    CREATE TABLE documents (
                        id TEXT PRIMARY KEY, profile TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                        data TEXT NOT NULL
                    );
                    CREATE TABLE facts (
                        id TEXT PRIMARY KEY, profile TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                        document TEXT REFERENCES documents(id) ON DELETE CASCADE, data TEXT NOT NULL
                    );
                    CREATE VIRTUAL TABLE fact_search USING fts5(id UNINDEXED, profile UNINDEXED, content);
                    CREATE TRIGGER remove_fact_search AFTER DELETE ON facts
                        BEGIN DELETE FROM fact_search WHERE id=old.id; END;
                    PRAGMA user_version = 1;
                    """)
            }
            if version == "0" || version == "1" {
                try database.execute("""
                    CREATE TABLE saved_sessions (id TEXT PRIMARY KEY, started TEXT NOT NULL, data TEXT NOT NULL);
                    CREATE VIRTUAL TABLE session_search USING fts5(id UNINDEXED, content);
                    CREATE TRIGGER remove_session_search AFTER DELETE ON saved_sessions
                        BEGIN DELETE FROM session_search WHERE id=old.id; END;
                    PRAGMA user_version = 2;
                    """)
            }
            if ["0", "1", "2"].contains(version) {
                try database.execute("""
                    CREATE TABLE fact_vectors (
                        fact TEXT PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
                        model TEXT NOT NULL, data TEXT NOT NULL
                    );
                    PRAGMA user_version = 3;
                    """)
            }
            // Version 4 uses the same tables as version 3. Keep legacy inclusion choices intact.
            if version != "4" { try database.execute("PRAGMA user_version = 4") }
        }
        self.database = database
    }

    public func save(_ profile: InterviewProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.invalidRecord
        }
        try database.write("""
            INSERT INTO profiles VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data
            """, [profile.id.uuidString, try SQLiteDatabase.json(profile)])
    }

    public func profiles() throws -> [InterviewProfile] {
        try database.query("SELECT data FROM profiles ORDER BY rowid") {
            try SQLiteDatabase.decode(InterviewProfile.self, from: $0)
        }
    }

    public func deleteProfile(_ id: UUID) throws {
        try database.write("DELETE FROM profiles WHERE id=?", [id.uuidString])
    }

    public func documents(profile: UUID) throws -> [ProfileDocument] {
        try database.query("SELECT data FROM documents WHERE profile=? ORDER BY rowid", [profile.uuidString]) {
            try SQLiteDatabase.decode(ProfileDocument.self, from: $0)
        }
    }

    public func add(_ document: ProfileDocument, to profile: UUID) throws {
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.emptyDocument
        }
        guard document.text.utf8.count <= 2_000_000 else { throw StorageFailure.documentTooLarge }
        try database.transaction {
            try database.write("INSERT INTO documents VALUES (?, ?, ?)",
                               [document.id.uuidString, profile.uuidString, try SQLiteDatabase.json(document)])
            for fact in document.experienceFacts() { try Self.writeFact(fact, profile: profile, in: database) }
        }
    }

    public func deleteDocument(_ id: UUID, profile: UUID) throws {
        try database.write("DELETE FROM documents WHERE id=? AND profile=?", [id.uuidString, profile.uuidString])
    }

    public func facts(profile: UUID) throws -> [ExperienceFact] {
        try database.query("SELECT data FROM facts WHERE profile=? ORDER BY rowid", [profile.uuidString]) {
            try SQLiteDatabase.decode(ExperienceFact.self, from: $0)
        }
    }

    public func save(_ fact: ExperienceFact, profile: UUID) throws {
        try database.transaction { try Self.writeFact(fact, profile: profile, in: database) }
    }

    public func deleteFact(_ id: UUID, profile: UUID) throws {
        try database.write("DELETE FROM facts WHERE id=? AND profile=?", [id.uuidString, profile.uuidString])
    }

    public func retrieve(_ question: String, profile: UUID) throws -> [ExperienceFact] {
        let query = SQLiteDatabase.keywords(in: question)
        guard !query.isEmpty else { return [] }
        return try database.query("""
            SELECT facts.data FROM fact_search JOIN facts ON facts.id=fact_search.id
            WHERE fact_search MATCH ? AND facts.profile=? ORDER BY bm25(fact_search) LIMIT 8
            """, [query, profile.uuidString]) {
            try SQLiteDatabase.decode(ExperienceFact.self, from: $0)
        }.filter { $0.status == .confirmed }
    }

    public func pastWorkExamples(profile: UUID) throws -> [ExperienceFact] {
        let candidates = try database.query("""
            SELECT facts.data, json_extract(documents.data, '$.kind')
            FROM facts LEFT JOIN documents ON documents.id=facts.document AND documents.profile=facts.profile
            WHERE facts.profile=? AND json_extract(facts.data, '$.status')=?
              AND (facts.document IS NULL OR json_extract(documents.data, '$.kind') IN (?, ?))
            ORDER BY CASE WHEN json_extract(facts.data, '$.category')=? THEN 0
                          WHEN json_extract(documents.data, '$.kind')=? THEN 1 ELSE 2 END,
                     facts.rowid DESC LIMIT 96
            """, [profile.uuidString, ExperienceFact.Status.confirmed.rawValue, ProfileDocument.Kind.resume.rawValue,
                  ProfileDocument.Kind.project.rawValue, ExperienceFact.projectStoryCategory,
                  ProfileDocument.Kind.project.rawValue]) { row in
            (try SQLiteDatabase.decode(ExperienceFact.self, from: row), SQLiteDatabase.text(row, 1))
        }
        return candidates.lazy.filter { fact, kind in
            fact.category == ExperienceFact.projectStoryCategory || kind == ProfileDocument.Kind.project.rawValue
                || Self.looksLikeWork(fact.claim)
        }.prefix(6).map(\.0)
    }

    private static func looksLikeWork(_ claim: String) -> Bool {
        let opening = claim.lowercased().split { !$0.isLetter }.prefix(5)
        return opening.contains { workVerbs.contains(String($0)) }
    }

    private static let workVerbs: Set<String> = [
        "built", "created", "implemented", "designed", "developed", "delivered", "maintained", "managed", "led",
        "migrated", "integrated", "owned", "worked", "improved", "automated", "configured", "tested", "deployed",
        "orchestrated", "processed", "loaded", "ingested", "transformed", "supported", "optimized", "operated"
    ]

    private static func writeFact(_ fact: ExperienceFact, profile: UUID, in database: SQLiteDatabase) throws {
        guard !fact.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.invalidRecord
        }
        if let documentID = fact.documentID {
            let document = try database.query("SELECT data FROM documents WHERE id=? AND profile=?",
                                              [documentID.uuidString, profile.uuidString]) {
                try SQLiteDatabase.decode(ProfileDocument.self, from: $0)
            }.first
            guard let document, document.kind.isExperienceSource else { throw StorageFailure.invalidRecord }
        }
        let owners = try database.query("SELECT profile FROM facts WHERE id=?", [fact.id.uuidString]) {
            SQLiteDatabase.text($0, 0)
        }
        guard owners.isEmpty || owners.first == profile.uuidString else { throw StorageFailure.invalidRecord }
        try database.write("""
            INSERT INTO facts VALUES (?, ?, NULLIF(?, ''), ?)
            ON CONFLICT(id) DO UPDATE SET document=excluded.document, data=excluded.data
            """, [fact.id.uuidString, profile.uuidString, fact.documentID?.uuidString ?? "",
                  try SQLiteDatabase.json(fact)])
        try database.write("DELETE FROM fact_search WHERE id=?", [fact.id.uuidString])
        try database.write("DELETE FROM fact_vectors WHERE fact=?", [fact.id.uuidString])
        if fact.status == .confirmed {
            try database.write("INSERT INTO fact_search VALUES (?, ?, ?)",
                               [fact.id.uuidString, profile.uuidString, fact.promptText + " " + fact.category])
        }
    }
}
