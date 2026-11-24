import Foundation
import XCTest
@testable import ConversationCore

private struct DiarizedClassifier: QuestionClassifier {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text])
    }
}

final class DiarizationTests: XCTestCase {
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
