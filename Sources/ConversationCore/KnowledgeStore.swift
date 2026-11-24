import Foundation
#if os(macOS)
import PDFKit
#endif

public struct InterviewProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var role: String
    public var seniority: String
    public var industry: String
    public var instructions: String
    public var answerLanguage: String

    public init(id: UUID = UUID(), name: String, role: String = "", seniority: String = "",
                industry: String = "", instructions: String = "", answerLanguage: String = "") {
        self.id = id
        self.name = name
        self.role = role
        self.seniority = seniority
        self.industry = industry
        self.instructions = instructions
        self.answerLanguage = answerLanguage
    }
}

public struct ProfileDocument: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case resume = "Résumé"
        case jobDescription = "Job description"
        case project = "Project notes"
        public var id: String { rawValue }
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let text: String

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
        #if os(macOS)
        case "pdf":
            guard let pdf = PDFDocument(url: url), let content = pdf.string else {
                throw StorageFailure.emptyDocument
            }
            text = content
        #endif
        default: throw StorageFailure.unsupportedFormat
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.emptyDocument
        }
        return Self(kind: kind, title: url.lastPathComponent, text: text)
    }
}

public struct ExperienceFact: Codable, Identifiable, Equatable, Sendable {
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

    public init(id: UUID = UUID(), documentID: UUID? = nil, locator: String = "",
                category: String = "", claim: String, ownership: String = "", dates: String = "",
                limitations: String = "", status: Status = .pending) {
        self.id = id
        self.documentID = documentID
        self.locator = locator
        self.category = category
        self.claim = claim
        self.ownership = ownership
        self.dates = dates
        self.limitations = limitations
        self.status = status
    }

    public var promptText: String {
        [claim, labeled("Ownership", ownership), labeled("Dates", dates), labeled("Limitations", limitations)]
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
            guard let version = versions.first, ["0", "1", "2"].contains(version) else {
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
            if version != "2" {
                try database.execute("""
                    CREATE TABLE saved_sessions (id TEXT PRIMARY KEY, started TEXT NOT NULL, data TEXT NOT NULL);
                    CREATE VIRTUAL TABLE session_search USING fts5(id UNINDEXED, content);
                    CREATE TRIGGER remove_session_search AFTER DELETE ON saved_sessions
                        BEGIN DELETE FROM session_search WHERE id=old.id; END;
                    PRAGMA user_version = 2;
                    """)
            }
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
            if document.kind != .jobDescription {
                let lines = document.text.split(whereSeparator: \.isNewline).enumerated()
                for (index, line) in lines.prefix(100) {
                    let claim = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard claim.count >= 12 else { continue }
                    let fact = ExperienceFact(documentID: document.id, locator: "Text line \(index + 1)",
                                              claim: String(claim.prefix(1_200)))
                    try writeFact(fact, profile: profile)
                }
            }
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
        try database.transaction { try writeFact(fact, profile: profile) }
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

    private func writeFact(_ fact: ExperienceFact, profile: UUID) throws {
        guard !fact.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageFailure.invalidRecord
        }
        if let documentID = fact.documentID {
            let document = try database.query("SELECT data FROM documents WHERE id=? AND profile=?",
                                              [documentID.uuidString, profile.uuidString]) {
                try SQLiteDatabase.decode(ProfileDocument.self, from: $0)
            }.first
            guard let document, document.kind != .jobDescription else { throw StorageFailure.invalidRecord }
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
        if fact.status == .confirmed {
            try database.write("INSERT INTO fact_search VALUES (?, ?, ?)",
                               [fact.id.uuidString, profile.uuidString, fact.promptText + " " + fact.category])
        }
    }
}
