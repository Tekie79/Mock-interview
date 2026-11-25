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
    private let classifiedQuestions: Set<String>?

    init(classifiedQuestions: Set<String>? = nil) {
        self.classifiedQuestions = classifiedQuestions
    }

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        received.append(input.turn.text)
        if let classifiedQuestions {
            let parts = classifiedQuestions.sorted().filter { input.turn.text.contains($0) }
            guard !parts.isEmpty else { return .init(decision: .ignore) }
            return .init(decision: .accept, normalizedQuestion: parts.joined(separator: "\n"), parts: parts)
        }
        return .init(decision: .accept, normalizedQuestion: input.turn.text,
                     parts: input.turn.text.components(separatedBy: "\n"))
    }
}

private final class RoundFixture {
    let source = CaptureSource(id: "remote", role: .interviewer)
    let audio = HeldAudio()
    let stt = InjectedSTT()
    let classifier: RoundClassifier
    let generator = ControlledGenerator()
    let clock = RoundClock()
    let session: InterviewSession

    init(questionWait: Duration = .seconds(2), classifiedQuestions: Set<String>? = nil, replay: Bool = false) {
        let stt = self.stt
        let clock = self.clock
        classifier = RoundClassifier(classifiedQuestions: classifiedQuestions)
        session = InterviewSession(
            channels: [.init(source: source, audio: audio, replay: replay, makeSTT: { stt })],
            detector: .init(classifier: classifier), generator: generator,
            questionWait: questionWait, questionNow: { clock.now() },
            questionSleep: { try await clock.sleep(until: $0) }
        )
    }

    func start() async throws {
        await session.start()
        try await eventually { await self.session.current().state == .listening }
    }

    func send(_ text: String, id: String, state: TranscriptEvent.State = .final,
              timing: PipelineTiming = .init()) async throws {
        await stt.send(text, item: id, state: state, timing: timing)
        try await eventually {
            await self.session.current().transcript.contains {
                $0.id.hasSuffix("/" + id) && $0.text == text && $0.isFinal == (state == .final)
            }
        }
    }
}

final class QuestionRoundTests: XCTestCase {
    func testObservedEndpointSilenceCountsTowardTheWait() async throws {
        let fixture = RoundFixture(questionWait: .seconds(1))
        try await fixture.start()
        let now = fixture.clock.now()
        var timing = PipelineTiming()
        timing.endpoint = now.advanced(by: .milliseconds(-800))
        try await fixture.send("How would you protect the queue?", id: "timed", timing: timing)
        try await eventually { fixture.clock.hasWaiter(until: now.advanced(by: .milliseconds(200))) }
        fixture.clock.advance(.milliseconds(199))
        let early = await fixture.generator.submitted
        XCTAssertTrue(early.isEmpty)
        fixture.clock.advance(.milliseconds(1))
        try await eventually { await fixture.generator.submitted.count == 1 }
        await fixture.session.stop()
    }

    func testFrozenCorpusDoesNotStarveWithOneSecondWait() async throws {
        struct Cue: Decodable {
            let text: String
            let expected: String
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m11/qualification.jsonl")
        let cues = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Cue.self, from: Data($0.utf8))
        }
        let expected = Set(cues.filter { $0.expected == "accept" }.map(\.text))
        XCTAssertEqual(cues.count, 100)
        XCTAssertEqual(expected.count, 40)
        let fixture = RoundFixture(questionWait: .seconds(1), classifiedQuestions: expected)
        try await fixture.start()
        for (index, cue) in cues.enumerated() {
            try await fixture.send(cue.text, id: "cue-\(index)")
            fixture.clock.advance(.milliseconds(550))
        }
        fixture.clock.advance(.seconds(5))
        try await eventually {
            Set(await fixture.session.current().answers.flatMap(\.question.parts)).intersection(expected).count == 40
        }
        let snapshot = await fixture.session.current()
        let recovered = Set(snapshot.answers.flatMap(\.question.parts)).intersection(expected)
        XCTAssertEqual(snapshot.transcript.filter(\.isFinal).count, 100)
        XCTAssertGreaterThanOrEqual(recovered.count, 36, "Expected ≥90% recall, recovered \(recovered.count)/40")
        XCTAssertEqual(snapshot.discardedQuestions, 0)
        await fixture.session.stop()
    }

    func testSilenceWaitMatrixOnASevenHundredFiftyMillisecondPause() async throws {
        for milliseconds in [0, 500, 1_000, 2_000] {
            let wait = Duration.milliseconds(milliseconds)
            let fixture = RoundFixture(questionWait: wait)
            try await fixture.start()
            let start = fixture.clock.now()
            try await fixture.send("Describe the initial design.", id: "opening")
            if milliseconds > 0 {
                try await eventually { fixture.clock.hasWaiter(until: start.advanced(by: wait)) }
            }
            fixture.clock.advance(.milliseconds(750))
            let premature = milliseconds < 750
            if premature { try await eventually { await fixture.generator.submitted.count == 1 } }
            let countBeforeContinuation = await fixture.generator.submitted.count
            XCTAssertEqual(countBeforeContinuation, premature ? 1 : 0, "wait \(milliseconds) ms")

            try await fixture.send("How would you confirm it works?", id: "continuation")
            if milliseconds > 0 {
                let end = fixture.clock.now()
                if !premature { fixture.clock.advance(wait - .milliseconds(750)) }
                try await eventually { fixture.clock.hasWaiter(until: end.advanced(by: wait)) }
                let remaining = premature ? wait : .milliseconds(750)
                fixture.clock.advance(remaining - .milliseconds(1))
                let countBeforeDeadline = await fixture.generator.submitted.count
                XCTAssertEqual(countBeforeDeadline, countBeforeContinuation)
                fixture.clock.advance(.milliseconds(1))
            }
            try await eventually { await fixture.generator.submitted.count == (premature ? 2 : 1) }
            let requests = await fixture.generator.submitted
            XCTAssertEqual(requests.last?.questionParts.count, premature ? 0 : 2)
            await fixture.session.stop()
        }
    }
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
        try await fixture.send("Tell me about retries and", id: "first")
        fixture.clock.advance(.seconds(1))
        try await fixture.send("But what if", id: "partial", state: .partial)
        fixture.clock.advance(.seconds(4))
        try await eventually { await fixture.session.current().questionDispositions[.deferred] == 1 }
        let snapshot = await fixture.session.current()
        XCTAssertTrue(snapshot.answers.isEmpty)
        XCTAssertEqual(snapshot.questionDispositions[.partialRetained], 1)
        XCTAssertEqual(snapshot.transcript.map(\.text), ["Tell me about retries and", "But what if"])
        await fixture.session.stop()
    }

    func testNewPartialRevisionsCannotEraseEarlierCompleteQuestion() async throws {
        let fixture = RoundFixture(questionWait: .seconds(1))
        try await fixture.start()
        try await fixture.send("How would you scale the queue?", id: "first")
        for index in 0..<8 {
            fixture.clock.advance(.milliseconds(500))
            try await fixture.send("Next thought \(index)", id: "next", state: .partial)
        }
        try await eventually { await fixture.session.current().answers.count == 1 }
        let snapshot = await fixture.session.current()
        XCTAssertEqual(snapshot.answers.first?.question.original, "How would you scale the queue?")
        XCTAssertEqual(snapshot.answers.first?.automaticProvenance?.contributingTranscriptIDs, [snapshot.transcript[0].id])
        XCTAssertEqual(snapshot.questionDispositions[.partialRetained], 1)
        await fixture.session.stop()
    }

    func testReplayEndsWithinSilenceWindowAndDrainsFinalizedQuestion() async throws {
        let fixture = RoundFixture(replay: true)
        try await fixture.start()
        try await fixture.send("Describe rollback.", id: "last-final")
        await fixture.audio.stop()
        try await eventually { await fixture.session.current().answers.count == 1 }
        let snapshot = await fixture.session.current()
        XCTAssertEqual(snapshot.answers.first?.question.original, "Describe rollback.")
        XCTAssertFalse(snapshot.waitingForQuestionEnd)
        await fixture.session.stop()
    }

    func testMixedCandidateAndUnknownPartialsCannotDelayAssignedInterviewer() async throws {
        let stt = InjectedSTT()
        let source = CaptureSource(id: "room", role: .unknown)
        let clock = RoundClock()
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
                                       detector: .init(classifier: RoundClassifier()), generator: FixedAnswer(),
                                       questionWait: .seconds(1), questionNow: { clock.now() },
                                       questionSleep: { try await clock.sleep(until: $0) })
        await session.start()
        try await eventually { await session.current().connected.contains(source.id) }
        await stt.send("Interviewer sample.", item: "assign1", speaker: 1)
        await stt.send("Candidate sample.", item: "assign2", speaker: 2)
        try await eventually { await session.current().speakers.count == 2 }
        let speakers = await session.current().speakers
        for speaker in speakers {
            await session.assignSpeaker(speaker.id, role: speaker.id.number == 1 ? .interviewer : .candidate)
        }
        await stt.send("How would you scale the queue?", item: "question", speaker: 1)
        try await eventually { await session.current().waitingForQuestionEnd }
        clock.advance(.milliseconds(500))
        await stt.send("Candidate interruption", item: "candidate", state: .partial, speaker: 2)
        await stt.send("Unknown interruption", item: "unknown", state: .partial)
        try await eventually { await session.current().transcript.count == 5 }
        clock.advance(.milliseconds(500))
        try await eventually { await session.current().answers.count == 1 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.answers.first?.question.original, "How would you scale the queue?")
        XCTAssertEqual(snapshot.transcript.filter { !$0.isFinal }.map(\.role), [.candidate, .unknown])
        await session.stop()
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
