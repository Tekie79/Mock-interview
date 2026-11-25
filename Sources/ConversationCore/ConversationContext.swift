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

/// A UTF-8 byte ceiling is the conservative token bound used across provider tokenizers.
public struct ContextBudget: Equatable, Sendable {
    public let turns: Int
    public let tokenBudget: Int

    public init(turns: Int = 12, tokenBudget: Int = 3_000) {
        self.turns = max(0, min(turns, 64))
        self.tokenBudget = max(0, min(tokenBudget, 24_000))
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
}

struct ClassifierContext: Encodable {
    let latest: String
    let previousQuestions: [String]
    let conversation: [ConversationTurn]
    let approvedEvidence: [String]
    let interviewContext: [String]

    init(_ input: QuestionInput) {
        latest = input.turn.text
        previousQuestions = input.previousQuestions
        conversation = input.conversation
        approvedEvidence = input.approvedEvidence
        interviewContext = input.interviewContext
    }
}
