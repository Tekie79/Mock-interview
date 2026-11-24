import Foundation
import XCTest
@testable import ConversationCore

private actor ClassifierFixture: QuestionClassifier {
    private(set) var inputs: [QuestionInput] = []

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        inputs.append(input)
        if input.turn.text.hasSuffix("...") { return QuestionDecision(decision: .wait) }
        return QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text,
                                parts: ["design", "testing"], isFollowUp: !input.previousQuestions.isEmpty)
    }
}

final class QuestionDetectionTests: XCTestCase {
    func testOnlyFreshFinalInterviewerTurnsReachClassifier() async throws {
        let classifier = ClassifierFixture()
        let detector = QuestionDetector(classifier: classifier)
        let epoch = UUID()
        let remote = CaptureSource(id: "remote", role: .interviewer)
        let mic = CaptureSource(id: "mic", role: .candidate)
        await detector.connect(remote, epoch: epoch)
        await detector.connect(mic, epoch: epoch)
        func event(_ id: String, _ text: String, source: CaptureSource = remote,
                   epoch value: UUID? = nil, state: TranscriptEvent.State = .final) -> TranscriptEvent {
            TranscriptEvent(source: source, epoch: value ?? epoch, itemID: id, text: text, state: state)
        }

        for ignored in [
            event("partial", "Explain the design", state: .partial),
            event("logistics", "Can you hear me?"),
            event("candidate", "Explain the design", source: mic),
            event("stale", "Explain the design", epoch: UUID()),
            event("incomplete", "Explain how you...")
        ] {
            let result = try await detector.receive(ignored)
            XCTAssertNil(result)
        }
        let complete = event("continuation", "designed and tested it.")
        let accepted = try await detector.receive(complete)
        XCTAssertEqual(accepted?.original, "Explain how you designed and tested it.")
        XCTAssertEqual(accepted?.parts, ["design", "testing"])
        let duplicate = try await detector.receive(complete)
        XCTAssertNil(duplicate)
        let repeatQuestion = try await detector.receive(event("repeat", "Explain the design again."))
        XCTAssertNotEqual(repeatQuestion?.id, accepted?.id)
        XCTAssertEqual(repeatQuestion?.previousQuestionID, accepted?.id)
        let inputs = await classifier.inputs
        XCTAssertEqual(inputs.count, 2)
    }
}
