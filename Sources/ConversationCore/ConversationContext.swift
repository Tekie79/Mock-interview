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

public enum InterviewContextMode: String, CaseIterable, Sendable {
    case recent = "Recent"
    case adaptive = "Adaptive"
}

public struct SessionContextConfiguration: Equatable, Sendable {
    public var mode: InterviewContextMode
    public var includesCandidate: Bool
    public var includesFeedback: Bool
    public var adaptsSpeakingStyle: Bool

    public init(mode: InterviewContextMode = .adaptive, includesCandidate: Bool = true,
                includesFeedback: Bool = true, adaptsSpeakingStyle: Bool = false) {
        self.mode = mode
        self.includesCandidate = includesCandidate
        self.includesFeedback = includesFeedback
        self.adaptsSpeakingStyle = adaptsSpeakingStyle
    }
}

public struct LearnedContextItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case discussion = "Discussion"
        case project = "Project reference"
        case candidate = "Actual candidate speech"
        case feedback = "Interviewer feedback"
        case correction = "Correction"
        case summary = "Session summary"
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let role: SourceRole?
    public let source: String?
    public let epoch: UUID?
    public let capturedAt: Date?
    public let sourceTranscriptIDs: [String]
    public let isExcluded: Bool
    public let isEdited: Bool
}

struct ContextBoundary: Sendable {
    var instant: ContinuousClock.Instant? = nil
    var order: UInt64
}

struct SessionMemory {
    struct Summary {
        let id: String
        let sourceIDs: Set<String>
        let stamps: [Stamp]
        let text: String
    }

    struct Stamp {
        var source: String? = nil
        var epoch: UUID? = nil
        var end: ContinuousClock.Instant? = nil
        var arrived: ContinuousClock.Instant? = nil
        var date: Date? = nil
        var order: UInt64 = 0

        func precedes(_ boundary: ContextBoundary) -> Bool {
            if let end, let instant = boundary.instant { return end <= instant }
            return order < boundary.order
        }
    }

    private(set) var turns: [ConversationTurn] = []
    private(set) var summaries: [Summary] = []
    private var stamps: [String: Stamp] = [:]
    private var excluded: Set<String> = []
    private var edited: [String: String] = [:]
    private var newTurns = 0
    private static let capacity = 128
    private static let summaryInterval = 8

    mutating func append(_ turn: ConversationTurn, stamp: Stamp = .init()) {
        guard turn.role != .unknown else { return }
        turns.append(.init(id: turn.id, role: turn.role, text: Self.clip(turn.text, to: 2_000), questionID: turn.questionID))
        stamps[turn.id] = stamp
        newTurns = min(newTurns + 1, Self.summaryInterval)
        if turns.count > Self.capacity {
            let evicted = turns.removeFirst()
            stamps[evicted.id] = nil
            excluded.remove(evicted.id)
            edited[evicted.id] = nil
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
        let affected = removed.union(ids)
        removeSummaries(referencing: affected)
        for id in removed { stamps[id] = nil; excluded.remove(id); edited[id] = nil }
        return removed
    }

    mutating func takeSummaryBatch(configuration: SessionContextConfiguration = .init()) -> [ConversationTurn]? {
        guard newTurns >= Self.summaryInterval, turns.count >= Self.summaryInterval + 4 else { return nil }
        newTurns = 0
        let batch = turns.dropLast(4).suffix(8).compactMap { resolved($0, configuration: configuration) }
        return batch.isEmpty ? nil : batch
    }

    @discardableResult
    mutating func installSummary(_ text: String, sourceIDs: Set<String>) -> Bool {
        let text = Self.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 2_000)
        guard !text.isEmpty, !sourceIDs.isEmpty, sourceIDs.isSubset(of: Set(turns.map(\.id))) else { return false }
        guard sourceIDs.isDisjoint(with: excluded) else { return false }
        if summaries.count == 4 { excluded.remove(summaries.removeFirst().id) }
        summaries.append(.init(id: "summary/" + UUID().uuidString, sourceIDs: sourceIDs,
                               stamps: sourceIDs.compactMap { stamps[$0] }, text: text))
        return true
    }

    var items: [LearnedContextItem] {
        turns.map { turn in
            let stamp = stamps[turn.id]
            return .init(id: turn.id, kind: edited[turn.id] == nil ? Self.kind(turn) : .correction,
                         text: edited[turn.id] ?? turn.text, role: turn.role, source: stamp?.source,
                         epoch: stamp?.epoch, capturedAt: stamp?.date, sourceTranscriptIDs: [turn.id],
                         isExcluded: excluded.contains(turn.id), isEdited: edited[turn.id] != nil)
        } + summaries.map { summary in
            .init(id: summary.id, kind: .summary, text: summary.text, role: nil, source: nil, epoch: nil,
                  capturedAt: summary.stamps.compactMap(\.date).max(), sourceTranscriptIDs: summary.sourceIDs.sorted(),
                  isExcluded: excluded.contains(summary.id), isEdited: false)
        }
    }

    func context(before boundary: ContextBoundary, ignoring ids: Set<String>, query: String,
                 budget: ContextBudget, configuration: SessionContextConfiguration) -> [ConversationTurn] {
        let attributed = turns.compactMap { turn -> ConversationTurn? in
            guard !ids.contains(turn.id), stamps[turn.id]?.precedes(boundary) == true else { return nil }
            return resolved(turn, configuration: configuration)
        }.sorted { lhs, rhs in
            let left = stamps[lhs.id], right = stamps[rhs.id]
            switch (left?.end ?? left?.arrived, right?.end ?? right?.arrived) {
            case let (.some(a), .some(b)) where a != b: return a < b
            case (.none, .some): return true
            case (.some, .none): return false
            default: break
            }
            return (left?.order ?? 0) < (right?.order ?? 0)
        }
        return configuration.mode == .adaptive ? budget.relevant(attributed, to: query) : budget.recent(attributed)
    }

    func validSummaries(before boundary: ContextBoundary, ignoring ids: Set<String>) -> [Summary] {
        summaries.filter { !excluded.contains($0.id) && $0.sourceIDs.isDisjoint(with: ids)
            && $0.stamps.allSatisfy { $0.precedes(boundary) } }
    }

    mutating func exclude(_ id: String, excluded value: Bool) -> Bool {
        guard turns.contains(where: { $0.id == id }) || summaries.contains(where: { $0.id == id }),
              excluded.contains(id) != value else { return false }
        if value { excluded.insert(id); removeSummaries(referencing: [id]) }
        else { excluded.remove(id) }
        return true
    }

    mutating func correct(_ id: String, text: String) -> Bool {
        let text = Self.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 2_000)
        guard !text.isEmpty, turns.contains(where: { $0.id == id }), edited[id] != text else { return false }
        edited[id] = text
        removeSummaries(referencing: [id])
        return true
    }

    private mutating func removeSummaries(referencing ids: Set<String>) {
        for summary in summaries where !summary.sourceIDs.isDisjoint(with: ids) { excluded.remove(summary.id) }
        summaries.removeAll { !$0.sourceIDs.isDisjoint(with: ids) }
    }

    private func resolved(_ turn: ConversationTurn, configuration: SessionContextConfiguration) -> ConversationTurn? {
        guard !excluded.contains(turn.id), configuration.includesCandidate || turn.role != .candidate,
              configuration.includesFeedback || Self.kind(turn) != .feedback else { return nil }
        guard let text = edited[turn.id] else { return turn }
        return .init(id: turn.id, role: turn.role, text: "User correction: " + text, questionID: turn.questionID)
    }

    private static func kind(_ turn: ConversationTurn) -> LearnedContextItem.Kind {
        let text = turn.text.lowercased()
        if ["correction", "i meant", "actually,", "let me correct"].contains(where: text.contains) { return .correction }
        if turn.role == .interviewer && ["good answer", "feedback", "that was clear", "could be clearer"].contains(where: text.contains) { return .feedback }
        if ["project", "migration", "rollout", "pipeline"].contains(where: text.contains) { return .project }
        return turn.role == .candidate ? .candidate : .discussion
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

    static func sharesTopic(_ a: String, _ b: String) -> Bool {
        let overlap = terms(a).intersection(terms(b))
        return overlap.count >= 2 || overlap.contains { $0.count >= 7 }
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
