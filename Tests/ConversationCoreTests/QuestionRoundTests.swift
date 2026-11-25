import Foundation
import XCTest
@testable import ConversationCore

private final class RoundClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    private var waiters: [UUID: (deadline: ContinuousClock.Instant, wake: AsyncStream<Void>.Continuation)] = [:]

    func now() -> ContinuousClock.Instant { lock.withLock { time } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let (stream, wake) = AsyncStream<Void>.makeStream()
        let id = UUID()
        lock.withLock {
            if deadline <= time { wake.finish() }
            else { waiters[id] = (deadline, wake) }
        }
        defer { _ = lock.withLock { waiters.removeValue(forKey: id) } }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }

    func advance(_ duration: Duration) {
        let ready = lock.withLock {
            time = time.advanced(by: duration)
            let ready = waiters.filter { $0.value.deadline <= time }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return ready.values.map(\.wake)
        }
        for wake in ready { wake.finish() }
    }

    func hasWaiter(until deadline: ContinuousClock.Instant) -> Bool {
        lock.withLock { waiters.values.contains { $0.deadline == deadline } }
    }
}

private actor RoundClassifier: QuestionClassifier {
    private(set) var received: [String] = []

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        received.append(input.turn.text)
        return .init(decision: .accept, normalizedQuestion: input.turn.text,
                     parts: input.turn.text.components(separatedBy: "\n"))
    }
}

private final class RoundFixture {
    let source = CaptureSource(id: "remote", role: .interviewer)
    let audio = HeldAudio()
    let stt = InjectedSTT()
    let classifier = RoundClassifier()
    let generator = ControlledGenerator()
    let clock = RoundClock()
    let session: InterviewSession

    init() {
        let stt = self.stt
        let clock = self.clock
        session = InterviewSession(
            channels: [.init(source: source, audio: audio, makeSTT: { stt })],
            detector: .init(classifier: classifier), generator: generator,
            questionWait: .seconds(2), questionNow: { clock.now() },
            questionSleep: { try await clock.sleep(until: $0) }
        )
    }

    func start() async throws {
        await session.start()
        try await eventually { await self.session.current().state == .listening }
    }

    func send(_ text: String, id: String, state: TranscriptEvent.State = .final) async throws {
        await stt.send(text, item: id, state: state)
        try await eventually {
            await self.session.current().transcript.contains {
                $0.id.hasSuffix("/" + id) && $0.text == text && $0.isFinal == (state == .final)
            }
        }
    }
}

final class QuestionRoundTests: XCTestCase {
    func testResumingSpeechRestartsQuietWindowAndJoinsFinalFragments() async throws {
        let fixture = RoundFixture()
        try await fixture.start()
        let began = fixture.clock.now()
        try await fixture.send("How would you scale the queue?", id: "first")
        try await eventually { fixture.clock.hasWaiter(until: began.advanced(by: .seconds(2))) }

        fixture.clock.advance(.milliseconds(1_500))
        await fixture.audio.send(.init(source: fixture.source, sampleRate: 24_000, startSample: 0,
                                       pcm: Data(repeating: 64, count: 4_800)))
        try await eventually { await fixture.session.current().levels[fixture.source.id, default: 0] > 0 }
        fixture.clock.advance(.milliseconds(750))
        try await eventually { fixture.clock.hasWaiter(until: began.advanced(by: .milliseconds(3_500))) }
        let early = await fixture.classifier.received
        XCTAssertTrue(early.isEmpty)

        try await fixture.send("Assume traffic will double.", id: "second")
        fixture.clock.advance(.seconds(2))
        try await eventually { await fixture.generator.submitted.count == 1 }
        let inputs = await fixture.classifier.received
        XCTAssertEqual(inputs, ["How would you scale the queue?\nAssume traffic will double."])
        let snapshot = await fixture.session.current()
        XCTAssertEqual(snapshot.answers.first?.automaticProvenance?.contributingTranscriptIDs, snapshot.transcript.map(\.id))
        await fixture.session.stop()
    }

    func testLateFinalAndTwoQuestionsProduceOneRequestWithBothParts() async throws {
        let fixture = RoundFixture()
        try await fixture.start()
        let began = fixture.clock.now()
        try await fixture.send("Explain idempotency.", id: "first")
        fixture.clock.advance(.seconds(1))
        try await fixture.send("How would you", id: "second", state: .partial)
        fixture.clock.advance(.seconds(3))
        try await eventually { fixture.clock.hasWaiter(until: began.advanced(by: .seconds(5))) }
        let early = await fixture.generator.submitted
        XCTAssertTrue(early.isEmpty)
        try await fixture.send("How would you test retries?", id: "second")
        fixture.clock.advance(.seconds(2))
        try await eventually { await fixture.generator.submitted.count == 1 }
        let generated = await fixture.generator.submitted
        XCTAssertTrue(generated[0].question.contains("Explain idempotency.\nHow would you test retries?"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try AnswerPrompt.input(generated[0]).utf8)) as? [String: [String]])
        XCTAssertEqual(payload["question_parts"], ["Explain idempotency.", "How would you test retries?"])
        XCTAssertTrue(generated[0].instructions.contains("Address all 2 requested parts"))
        let firstRound = await fixture.session.current()
        XCTAssertEqual(firstRound.answers.count, 1)
        XCTAssertEqual(firstRound.answers.first?.question.parts, ["Explain idempotency.", "How would you test retries?"])

        try await fixture.send("What should fire an alert?", id: "next-round")
        fixture.clock.advance(.seconds(2))
        try await eventually { await fixture.generator.submitted.count == 2 }
        let separate = await fixture.session.current()
        XCTAssertEqual(separate.answers.map(\.state), [.superseded, .generating])
        await fixture.session.stop()
    }

    func testUnresolvedPartialNeverTriggersAnAnswer() async throws {
        let fixture = RoundFixture()
        try await fixture.start()
        try await fixture.send("How would you scale the queue?", id: "first")
        fixture.clock.advance(.seconds(1))
        try await fixture.send("But what if", id: "partial", state: .partial)
        fixture.clock.advance(.seconds(4))
        try await eventually { await fixture.session.current().discardedQuestions == 1 }
        let snapshot = await fixture.session.current()
        XCTAssertTrue(snapshot.answers.isEmpty)
        XCTAssertEqual(snapshot.transcript.map(\.text), ["How would you scale the queue?", "But what if"])
        await fixture.session.stop()
    }

    func testTimingChangeIsLiveAndPauseDiscardsAnUnfinishedRound() async throws {
        let fixture = RoundFixture()
        try await fixture.start()
        try await fixture.send("Describe the checklist.", id: "first")
        await fixture.session.pause()
        fixture.clock.advance(.seconds(3))
        let paused = await fixture.session.current()
        XCTAssertFalse(paused.waitingForQuestionEnd)
        XCTAssertTrue(paused.answers.isEmpty)

        try await fixture.start()
        try await fixture.send("Describe rollback.", id: "second")
        await fixture.session.setQuestionWait(.zero)
        try await eventually { await fixture.generator.submitted.count == 1 }
        let classified = await fixture.classifier.received
        XCTAssertEqual(classified, ["Describe rollback."])
        await fixture.session.stop()
    }
}
