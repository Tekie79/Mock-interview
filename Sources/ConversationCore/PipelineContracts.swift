import Foundation

public struct CaptureSource: Hashable, Sendable {
    public let id: String
    public let role: SourceRole

    public init(id: String, role: SourceRole) {
        self.id = id
        self.role = role
    }
}

/// A chunk of mono, signed 16-bit little-endian PCM with timing relative to capture start.
public struct AudioFrame: Equatable, Sendable {
    public let source: CaptureSource
    public let sampleRate: Int
    public let startSample: Int64
    public let pcm: Data

    public init(source: CaptureSource, sampleRate: Int, startSample: Int64, pcm: Data) {
        self.source = source
        self.sampleRate = sampleRate
        self.startSample = startSample
        self.pcm = pcm
    }
}

public protocol AudioSource: Sendable {
    func start() async throws -> AsyncThrowingStream<AudioFrame, Error>
    func stop() async
}

public struct TranscriptEvent: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case partial
        case final
    }

    public let source: CaptureSource
    public let epoch: UUID
    public let itemID: String
    public let previousItemID: String?
    public let text: String
    public let state: State
    public let speaker: Int?

    public init(source: CaptureSource, epoch: UUID, itemID: String, previousItemID: String? = nil,
                text: String, state: State, speaker: Int? = nil) {
        self.source = source
        self.epoch = epoch
        self.itemID = itemID
        self.previousItemID = previousItemID
        self.text = text
        self.state = state
        self.speaker = speaker
    }
}

public protocol StreamingSTT: Sendable {
    func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error>
    func append(_ frame: AudioFrame) async throws
    func commit() async throws
    func close() async
}

public struct QuestionInput: Equatable, Sendable {
    public let turn: TranscriptEvent
    public let previousQuestions: [String]

    public init(turn: TranscriptEvent, previousQuestions: [String]) {
        self.turn = turn
        self.previousQuestions = previousQuestions
    }
}

public struct QuestionDecision: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case accept, wait, ignore, uncertain
    }

    public let decision: Kind
    public let category: String
    public let normalizedQuestion: String
    public let parts: [String]
    public let contextTurnIDs: [String]
    public let isFollowUp: Bool
    public let isIntentionalRepeat: Bool
    public let confidence: Double
    public let reasonCode: String

    public init(decision: Kind, category: String = "", normalizedQuestion: String = "",
                parts: [String] = [], contextTurnIDs: [String] = [], isFollowUp: Bool = false,
                isIntentionalRepeat: Bool = false, confidence: Double = 1, reasonCode: String = "") {
        self.decision = decision
        self.category = category
        self.normalizedQuestion = normalizedQuestion
        self.parts = parts
        self.contextTurnIDs = contextTurnIDs
        self.isFollowUp = isFollowUp
        self.isIntentionalRepeat = isIntentionalRepeat
        self.confidence = confidence
        self.reasonCode = reasonCode
    }
}

public protocol QuestionClassifier: Sendable {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision
}

public struct AnswerRequest: Equatable, Sendable {
    public let question: String
    public let instructions: String
    public let evidence: [String]
    public let coaching: CoachingInput?
    public let interviewContext: [String]

    public init(question: String, instructions: String, evidence: [String], coaching: CoachingInput? = nil,
                interviewContext: [String] = []) {
        self.question = question
        self.instructions = instructions
        self.evidence = evidence
        self.coaching = coaching
        self.interviewContext = interviewContext
    }
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = max(0, input)
        self.output = max(0, output)
    }
}

public enum GenerationEvent: Sendable, Equatable {
    case text(String)
    case usage(TokenUsage)
}

public protocol TextGenerator: Sendable {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error>
}
