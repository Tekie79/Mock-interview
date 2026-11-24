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

    public init(source: CaptureSource, epoch: UUID, itemID: String, previousItemID: String? = nil,
                text: String, state: State) {
        self.source = source
        self.epoch = epoch
        self.itemID = itemID
        self.previousItemID = previousItemID
        self.text = text
        self.state = state
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
    public let relevant: Bool
    public let complete: Bool
    public let parts: [String]

    public init(relevant: Bool, complete: Bool, parts: [String]) {
        self.relevant = relevant
        self.complete = complete
        self.parts = parts
    }
}

public protocol QuestionClassifier: Sendable {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision
}

public struct AnswerRequest: Equatable, Sendable {
    public let question: String
    public let instructions: String
    public let evidence: [String]

    public init(question: String, instructions: String, evidence: [String]) {
        self.question = question
        self.instructions = instructions
        self.evidence = evidence
    }
}

public protocol TextGenerator: Sendable {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<String, Error>
}
