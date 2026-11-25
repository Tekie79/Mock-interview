import Foundation
import XCTest
@testable import ConversationCore

actor HeldAudio: AudioSource {
    private var output: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    func start() -> AsyncThrowingStream<AudioFrame, Error> {
        let (stream, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.output = output
        return stream
    }
    func stop() { output?.finish(); output = nil }
    func fail() { output?.finish(throwing: CaptureFailure.sourceUnavailable) }
}

actor InjectedSTT: StreamingSTT {
    private var source: CaptureSource?
    private var epoch: UUID?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    func connect(source: CaptureSource, epoch: UUID) -> AsyncThrowingStream<TranscriptEvent, Error> {
        self.source = source
        self.epoch = epoch
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        return stream
    }
    func append(_ frame: AudioFrame) {}
    func commit() {}
    func close() { output?.finish(); output = nil }
    func send(_ text: String, item: String, state: TranscriptEvent.State = .final, epoch override: UUID? = nil) {
        guard let source, let epoch else { return }
        output?.yield(.init(source: source, epoch: override ?? epoch, itemID: item, text: text, state: state))
    }
}

actor HeldClassifier: QuestionClassifier {
    private(set) var inputs: [QuestionInput] = []
    private let slow: Bool
    init(slow: Bool = true) { self.slow = slow }
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        inputs.append(input)
        if slow { try await Task.sleep(for: .seconds(30)) }
        return .init(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text], isFollowUp: true)
    }
}

struct FixedAnswer: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.yield(.text("Suggested response.")); $0.finish() }
    }
}

func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ProviderFailure.timeout
}

final class PipelineHardeningTests: XCTestCase {
    func testBlockedClassifierDoesNotBlockIngestionAndOverflowRetainsTranscript() async throws {
        let audio = HeldAudio()
        let stt = InjectedSTT()
        let classifier = HeldClassifier()
        let source = CaptureSource(id: "question", role: .interviewer)
        let session = InterviewSession(channels: [.init(source: source, audio: audio, makeSTT: { stt })],
                                       detector: .init(classifier: classifier), generator: FixedAnswer(), queueLimit: 1)
        await session.start()
        try await eventually { await session.current().state == .listening }
        await stt.send("Explain queues.", item: "first")
        try await eventually { await classifier.inputs.count == 1 }
        await stt.send("Explain locks.", item: "second")
        await stt.send("Explain locks.", item: "second")
        await stt.send("Explain scheduling.", item: "third")
        await stt.send("Ignored old epoch", item: "old", epoch: UUID())
        try await eventually { await session.current().discardedQuestions == 1 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.transcript.count, 3)
        XCTAssertTrue(snapshot.answers.isEmpty)
        await session.stop()
        let stopped = await session.current()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(stopped.answers.isEmpty)
    }

    func testCandidateOnlyIsDegradedAndAllDisconnectedIsFailed() async throws {
        let questionAudio = HeldAudio()
        let candidateAudio = HeldAudio()
        let question = InjectedSTT()
        let candidate = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: questionAudio, makeSTT: { question }),
            .init(source: .init(id: "candidate", role: .candidate), audio: candidateAudio, makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await questionAudio.fail()
        try await eventually { await session.current().state == .degraded }
        let degraded = await session.current()
        XCTAssertEqual(degraded.connected, ["candidate"])
        await candidate.send("What is the deadline?", item: "candidate")
        try await eventually { await session.current().transcript.count == 1 }
        let inputs = await classifier.inputs
        XCTAssertTrue(inputs.isEmpty)
        await candidateAudio.fail()
        try await eventually { await session.current().state == .failed }
        let failed = await session.current()
        XCTAssertTrue(failed.connected.isEmpty)
        await session.stop()
    }
}
