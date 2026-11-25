import Foundation
import XCTest
@testable import ConversationCore

private struct DiarizedClassifier: QuestionClassifier {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text])
    }
}

final class DiarizationTests: XCTestCase {
    func testSharedRoomOnlyGeneratesForConfirmedInterviewerAndRevokesAfterMerge() async throws {
        let source = CaptureSource(id: "room", role: .unknown)
        let stt = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
                                       detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().connected.contains(source.id) }
        await stt.send("Can you hear me?", item: "unreviewed-interviewer", speaker: 1)
        await stt.send("Yes, can you hear me?", item: "unreviewed-candidate", speaker: 2)
        try await eventually { await session.current().speakers.count == 2 }
        let roles = await session.current().speakers
        try await session.assignSpeaker(XCTUnwrap(roles.first { $0.id.number == 1 }).id, role: .interviewer)
        try await session.assignSpeaker(XCTUnwrap(roles.first { $0.id.number == 2 }).id, role: .candidate)
        await stt.send("Could you explain retries?", item: "candidate", speaker: 2)
        await stt.send("Explain timeouts.", item: "mixed")
        await stt.send("Explain idempotency.", item: "interviewer", speaker: 1)
        try await eventually { await session.current().answers.first?.state == .complete }
        let inputs = await classifier.inputs
        XCTAssertEqual(inputs.map(\.turn.text), ["Explain idempotency."])
        XCTAssertEqual(inputs.first?.conversation.map(\.role), [.candidate])

        await stt.send("", item: "merge", state: .speakerMerge(from: 1, to: 2))
        try await eventually {
            let snapshot = await session.current()
            return snapshot.answers.first?.state == .invalidated && snapshot.speakers.map(\.role) == [.unknown]
        }
        let merged = await session.current()
        XCTAssertEqual(merged.transcript.first(where: { $0.text == "Explain idempotency." })?.speaker, 2)
        XCTAssertEqual(merged.transcript.first(where: { $0.text == "Explain idempotency." })?.role, .unknown)
        await stt.send("What about another retry?", item: "after-merge", speaker: 2)
        try await eventually { await session.current().transcript.last?.text == "What about another retry?" }
        let final = await session.current()
        XCTAssertEqual(final.answers.count, 1)
        XCTAssertEqual(final.transcript.last?.role, .unknown)
        await session.stop()
    }

    func testMixedWordsDoNotInheritSingleSpeakerLabel() throws {
        let source = CaptureSource(id: "mixed mic", role: .unknown)
        var stt = DeepgramTranscriptAssembler(source: source, epoch: UUID())
        let mixed = Data(#"{"type":"Results","start":0,"duration":1,"is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"What about that?","words":[{"speaker":1},{"speaker":2}]}]}}"#.utf8)
        let solo = Data(#"{"type":"Results","start":1,"duration":1,"is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"Explain retries.","words":[{"speaker":2},{"speaker":2}]}]}}"#.utf8)
        let mixedEvent = try XCTUnwrap(stt.receive(mixed))
        XCTAssertNil(mixedEvent.speaker)
        XCTAssertEqual(mixedEvent.source.role, .unknown)
        XCTAssertEqual(try stt.receive(solo)?.speaker, 2)
    }

    func testAssignmentAppliesOnlyToFreshFinalTurnsFromSameUnknownSourceEpoch() async throws {
        let source = CaptureSource(id: "mixed mic", role: .unknown)
        let candidate = CaptureSource(id: "candidate mic", role: .candidate)
        let detector = QuestionDetector(classifier: DiarizedClassifier())
        let epoch = UUID()
        await detector.connect(source, epoch: epoch)
        await detector.connect(candidate, epoch: epoch)

        func event(_ id: String, source: CaptureSource = source, epoch selected: UUID? = nil) -> TranscriptEvent {
            TranscriptEvent(source: source, epoch: selected ?? epoch, itemID: id, text: "Explain retries.",
                            state: .final, speaker: 2)
        }
        let unassigned = try await detector.receive(event("first"))
        XCTAssertNil(unassigned)
        await detector.assignSpeaker(2, role: .interviewer, sourceID: source.id, epoch: epoch)
        await detector.assignSpeaker(2, role: .interviewer, sourceID: candidate.id, epoch: epoch)
        let replay = try await detector.receive(event("first"))
        let interviewer = try await detector.receive(event("second"))
        let localCandidate = try await detector.receive(event("candidate", source: candidate))
        XCTAssertNil(replay)
        XCTAssertNotNil(interviewer)
        XCTAssertNil(localCandidate)

        let resumed = UUID()
        await detector.connect(source, epoch: resumed)
        let afterReconnect = try await detector.receive(event("third", epoch: resumed))
        XCTAssertNil(afterReconnect)
    }
}
