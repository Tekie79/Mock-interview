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

private actor DelayedFinalSTT: StreamingSTT {
    private var source: CaptureSource?
    private var epoch: UUID?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private(set) var inputEnded = false
    func connect(source: CaptureSource, epoch: UUID) -> AsyncThrowingStream<TranscriptEvent, Error> {
        self.source = source
        self.epoch = epoch
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        return stream
    }
    func append(_ frame: AudioFrame) {}
    func commit() {
        if let source, let epoch {
            output?.yield(.init(source: source, epoch: epoch, itemID: "one", text: "Explain", state: .partial))
        }
    }
    func finishInput() { inputEnded = true }
    func close() { output?.finish(); output = nil }
    func final() {
        if let source, let epoch {
            output?.yield(.init(source: source, epoch: epoch, itemID: "one", text: "Explain the tradeoffs.", state: .final))
        }
    }
}

extension PipelineHardeningTests {
    func testReplayDrainsDelayedFinalAndMeasuresToViewAcknowledgment() async throws {
        let source = CaptureSource(id: "replay", role: .interviewer)
        let audio = PCMReplaySource(source: source, pcm: Data(repeating: 64, count: 9_600), pace: { _ in })
        let stt = DelayedFinalSTT()
        let session = InterviewSession(channels: [
            .init(source: source, audio: audio, replay: true, drainTimeout: .seconds(2), makeSTT: { stt })
        ], detector: .init(classifier: HeldClassifier(slow: false)), generator: FixedAnswer())
        await session.start()
        try await eventually { await stt.inputEnded }
        let beforeFinal = await session.current()
        XCTAssertTrue(beforeFinal.answers.isEmpty)
        await stt.final()
        try await eventually { await session.current().answers.last?.state == .complete }
        let snapshot = await session.current()
        let answer = try XCTUnwrap(snapshot.answers.last)
        XCTAssertNil(answer.pipeline?.endpointToVisible)
        XCTAssertNotNil(answer.pipeline?.commitToFinal)
        XCTAssertNotNil(answer.pipeline?.classification)
        XCTAssertNotNil(answer.pipeline?.retrieval)
        XCTAssertNotNil(answer.pipeline?.requestToToken)
        await session.responseVisible(answer.revision)
        let visible = await session.current()
        XCTAssertNotNil(visible.answers.last?.pipeline?.endpointToVisible)
        await session.stop()
    }

    func testCandidateContextCarriesActualSpeechAndPriorQuestionIdentity() async throws {
        let question = InjectedSTT()
        let candidate = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: HeldAudio(), makeSTT: { question }),
            .init(source: .init(id: "candidate", role: .candidate), audio: HeldAudio(), makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await question.send("Describe your approach.", item: "first")
        try await eventually { await session.current().answers.count == 1 }
        await candidate.send("I split the queue by priority.", item: "actual")
        try await eventually { await session.current().transcript.count == 2 }
        await question.send("Why did you choose that approach?", item: "follow-up")
        try await eventually { await classifier.inputs.count == 2 }
        let inputs = await classifier.inputs
        XCTAssertEqual(inputs.last?.conversation.map(\.role), [.interviewer, .candidate])
        XCTAssertNotNil(inputs.last?.conversation.first?.questionID)
        XCTAssertEqual(inputs.last?.conversation.last?.text, "I split the queue by priority.")
        XCTAssertFalse(inputs.last?.conversation.contains { $0.text.contains("Suggested response") } ?? true)
        await session.stop()
    }
}

extension PipelineHardeningTests {
    func testSwitchingSourcesRejectsOldEpochWhileKeepingExistingTranscript() async throws {
        let original = InjectedSTT()
        let replacement = InjectedSTT()
        let source = CaptureSource(id: "question", role: .interviewer)
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: source, audio: HeldAudio(), makeSTT: { original })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await original.send("Explain the first design.", item: "one")
        try await eventually { await session.current().answers.count == 1 }
        await session.replaceChannels([.init(source: source, audio: HeldAudio(), makeSTT: { replacement })])
        try await eventually { await session.current().state == .listening }
        await original.send("This is from the old stream.", item: "two")
        await replacement.send("Explain the second design.", item: "two")
        try await eventually { await session.current().answers.count == 2 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.transcript.map(\.text), ["Explain the first design.", "Explain the second design."])
        await session.stop()
    }
}

private struct HangingGenerator: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try await Task.sleep(for: .seconds(30))
        return AsyncThrowingStream { $0.finish() }
    }
}

extension PipelineHardeningTests {
    func testMultipartConnectorWaitsAndPauseCancelsClassifier() async throws {
        let stt = InjectedSTT()
        let classifier = HeldClassifier()
        let source = CaptureSource(id: "question", role: .interviewer)
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
                                       detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await stt.send("Explain your approach and", item: "one")
        try await eventually { await session.current().transcript.count == 1 }
        let inputCount = await classifier.inputs.count
        XCTAssertEqual(inputCount, 0)
        await stt.send("how you measured success.", item: "two")
        try await eventually { await classifier.inputs.count == 1 }
        let merged = await classifier.inputs.first?.turn.text
        XCTAssertEqual(merged, "Explain your approach and how you measured success.")
        await session.pause()
        let paused = await session.current()
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(paused.answers.isEmpty)
        await session.start()
        try await eventually { await session.current().state == .listening }
        await session.stop()
    }

    func testGenerationDeadlineDoesNotChangeCaptureLifecycle() async throws {
        let session = InterviewSession(channels: [], detector: .init(classifier: HeldClassifier(slow: false)),
                                       generator: HangingGenerator(), generationTimeout: .milliseconds(20))
        await session.start()
        await session.manualQuestion("Explain deadlines.")
        try await eventually { await session.current().answers.last?.state == .failed }
        let failed = await session.current()
        XCTAssertEqual(failed.state, .degraded)
        XCTAssertTrue(failed.answers.last?.failure?.contains("timed out") == true)
        await session.stop()
    }
}

private actor UnreadySTT: StreamingSTT {
    private(set) var attempted = false
    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        attempted = true
        try await Task.sleep(for: .seconds(30))
        throw ProviderFailure.authentication
    }
    func append(_ frame: AudioFrame) {}
    func commit() {}
    func close() {}
}

private actor ObservedAudio: AudioSource {
    private(set) var started = false
    func start() -> AsyncThrowingStream<AudioFrame, Error> {
        started = true
        return AsyncThrowingStream { $0.finish() }
    }
    func stop() {}
}

extension PipelineHardeningTests {
    func testCaptureNeverStartsBeforeProviderReadinessAndStopCancelsStartup() async throws {
        let audio = ObservedAudio()
        let stt = UnreadySTT()
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: audio, makeSTT: { stt })
        ], detector: .init(classifier: HeldClassifier()), generator: FixedAnswer())
        await session.start()
        try await eventually { await stt.attempted }
        let starting = await session.current()
        XCTAssertEqual(starting.state, .connecting)
        let launched = await audio.started
        XCTAssertFalse(launched)
        await session.stop()
        let stopped = await session.current()
        XCTAssertEqual(stopped.state, .stopped)
        let launchedAfterStop = await audio.started
        XCTAssertFalse(launchedAfterStop)
    }
}
