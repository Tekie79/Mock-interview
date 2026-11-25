import Foundation

public struct ConversationTurn: Codable, Equatable, Sendable {
    public let id: String
    public let role: SourceRole
    public let text: String
    public let questionID: UUID?

    public init(id: String, role: SourceRole, text: String, questionID: UUID? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.questionID = questionID
    }
}

public protocol SessionSummarizing: Sendable {
    func summarize(_ turns: [ConversationTurn]) async throws -> String
}

struct SessionMemory {
    struct Summary {
        let sourceIDs: Set<String>
        let text: String
    }

    private(set) var turns: [ConversationTurn] = []
    private(set) var summaries: [Summary] = []
    private var newTurns = 0
    private static let capacity = 128
    private static let summaryInterval = 8

    mutating func append(_ turn: ConversationTurn) {
        guard turn.role != .unknown else { return }
        turns.append(.init(id: turn.id, role: turn.role, text: Self.clip(turn.text, to: 2_000), questionID: turn.questionID))
        newTurns = min(newTurns + 1, Self.summaryInterval)
        if turns.count > Self.capacity {
            let evicted = turns.removeFirst()
            summaries.removeAll { $0.sourceIDs.contains(evicted.id) }
        }
    }

    mutating func associate(_ ids: Set<String>, with question: UUID) {
        for index in turns.indices where ids.contains(turns[index].id) {
            let turn = turns[index]
            turns[index] = .init(id: turn.id, role: turn.role, text: turn.text, questionID: question)
        }
    }

    @discardableResult
    mutating func revoke(_ ids: Set<String>, questions: Set<UUID>) -> Set<String> {
        let removed = Set(turns.lazy.filter { ids.contains($0.id) || $0.questionID.map(questions.contains) == true }.map(\.id))
        turns.removeAll { removed.contains($0.id) }
        summaries.removeAll { !$0.sourceIDs.isDisjoint(with: removed) }
        return removed
    }

    mutating func takeSummaryBatch() -> [ConversationTurn]? {
        guard newTurns >= Self.summaryInterval, turns.count >= Self.summaryInterval + 4 else { return nil }
        newTurns = 0
        return Array(turns.dropLast(4).suffix(8))
    }

    @discardableResult
    mutating func installSummary(_ text: String, sourceIDs: Set<String>) -> Bool {
        let text = Self.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 2_000)
        guard !text.isEmpty, !sourceIDs.isEmpty, sourceIDs.isSubset(of: Set(turns.map(\.id))) else { return false }
        if summaries.count == 4 { summaries.removeFirst() }
        summaries.append(.init(sourceIDs: sourceIDs, text: text))
        return true
    }

    mutating func finish() { self = Self() }

    static func clip(_ text: String, to limit: Int) -> String {
        var bytes = text.utf8.prefix(limit)
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A UTF-8 byte ceiling is the conservative token bound used across provider tokenizers.
public struct ContextBudget: Equatable, Sendable {
    public let turns: Int
    public let tokenBudget: Int

    public init(turns: Int = 12, tokenBudget: Int = 3_000) {
        self.turns = max(0, min(turns, 64))
        self.tokenBudget = max(0, min(tokenBudget, 24_000))
    }

    func share(_ percent: Int) -> Self {
        .init(turns: turns, tokenBudget: tokenBudget * percent / 100)
    }

    public func limit(_ context: [String]) -> [String] {
        var remaining = tokenBudget
        var result: [String] = []
        for value in context where remaining > 0 {
            let clipped = String(decoding: value.utf8.prefix(remaining), as: UTF8.self)
            guard clipped.utf8.count <= remaining else { break }
            result.append(clipped)
            remaining -= clipped.utf8.count
        }
        return result
    }

    func recent(_ context: [ConversationTurn]) -> [ConversationTurn] {
        var remaining = tokenBudget
        var result: [ConversationTurn] = []
        for turn in context.suffix(turns).reversed() where remaining > 0 {
            let size = turn.id.utf8.count + turn.role.rawValue.utf8.count + 64
            guard remaining > size else { break }
            remaining -= size
            let clipped = String(decoding: turn.text.utf8.prefix(remaining), as: UTF8.self)
            guard clipped.utf8.count <= remaining else { break }
            result.append(.init(id: turn.id, role: turn.role, text: clipped, questionID: turn.questionID))
            remaining -= clipped.utf8.count
        }
        return result.reversed()
    }

    func relevant(_ context: [ConversationTurn], to query: String) -> [ConversationTurn] {
        let recency = min(turns, max(3, turns / 2))
        guard context.count > recency, turns > recency else { return recent(context) }
        let queryTerms = Self.terms(query)
        guard !queryTerms.isEmpty else { return recent(context) }
        let older = context.dropLast(recency).enumerated().compactMap { index, turn -> (Int, Int, ConversationTurn)? in
            let overlap = Self.terms(turn.text).intersection(queryTerms)
            guard overlap.count >= 2 || overlap.contains(where: { $0.count >= 7 }) else { return nil }
            return (index, overlap.count, turn)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 > rhs.1
        }
        let selected = older.prefix(turns - recency).sorted { $0.0 < $1.0 }.map(\.2)
        return selected.isEmpty ? recent(context) : recent(selected + context.suffix(recency))
    }

    private static func terms(_ text: String) -> Set<Substring> {
        let common: Set<Substring> = ["about", "after", "could", "please", "should", "their", "there", "these",
            "those", "through", "using", "where", "which", "while", "would", "before", "explain", "describe"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }).subtracting(common)
    }
}

struct ClassifierContext: Encodable {
    private struct ReferenceContext: Encodable {
        let providerTurnProbability: Double?
        let previousQuestions: [String]
        let conversation: [ConversationTurn]
        let approvedEvidence: [String]
        let interviewContext: [String]
    }

    private let context: ReferenceContext
    private let latest: String

    static func encode(_ input: QuestionInput) throws -> String {
        let context = ReferenceContext(providerTurnProbability: input.turn.turnProbability,
                                       previousQuestions: input.previousQuestions, conversation: input.conversation,
                                       approvedEvidence: input.approvedEvidence, interviewContext: input.interviewContext)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = Self(context: context, latest: input.turn.text)
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
