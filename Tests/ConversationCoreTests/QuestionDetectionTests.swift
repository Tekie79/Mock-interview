import Foundation
import XCTest
@testable import ConversationCore

private actor ClassifierFixture: QuestionClassifier {
    private(set) var inputs: [QuestionInput] = []
    private let decisions: [String: QuestionDecision.Kind]

    init(decisions: [String: QuestionDecision.Kind] = [:]) {
        self.decisions = decisions
    }

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        inputs.append(input)
        if let decision = decisions[input.turn.text] { return QuestionDecision(decision: decision) }
        if input.turn.text.hasSuffix("...") { return QuestionDecision(decision: .wait) }
        if input.turn.itemID == "literal-repeat" {
            return QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text,
                                    parts: [input.turn.text])
        }
        return QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text,
                                parts: ["design", "testing"], isFollowUp: !input.previousQuestions.isEmpty)
    }
}

final class QuestionDetectionTests: XCTestCase {
    func testFirstPersonIndirectAndConversationalRequestsReachSemanticClassification() async throws {
        let classifier = ClassifierFixture()
        let detector = QuestionDetector(classifier: classifier)
        let source = CaptureSource(id: "mixed output", role: .interviewer)
        let epoch = UUID()
        await detector.connect(source, epoch: epoch)
        let questions = ["Walk me through the failure.", "I want you to tell me how the test worked.",
                         "My next question is what happened after the rollback.",
                         "We reviewed the fault, but could you explain your rollback check?",
                         "I'd love to hear about the first incident you handled.",
                         "I'm curious how you decided when to retry",
                         "I was hoping you'd talk us through the rollout.",
                         "Our next topic is partitioning. Your approach?",
                         "I have one more for you, “What went wrong during the migration?”",
                         "You mentioned a backfill. I’d be interested in what broke first, okay?"]
        for (index, text) in questions.enumerated() {
            let result = try await detector.receive(.init(source: source, epoch: epoch, itemID: String(index),
                                                          text: text, state: .final))
            XCTAssertEqual(result?.original, text)
        }
        let classified = await classifier.inputs
        XCTAssertEqual(classified.map(\.turn.text), questions)
    }

    func testNarrationAndAmbiguityUseSemanticDecisionWithoutProducingQuestionCards() async throws {
        let narration = ["We saw the outage and routed around it.",
                         "I remember asking myself, “How did this fail?” I checked the service log.",
                         "The retry queue just needed a concurrency limit, right?"]
        let ambiguous = "I'm still thinking about the rollout."
        var decisions = Dictionary(uniqueKeysWithValues: narration.map { ($0, QuestionDecision.Kind.ignore) })
        decisions[ambiguous] = .uncertain
        let classifier = ClassifierFixture(decisions: decisions)
        let detector = QuestionDetector(classifier: classifier)
        let source = CaptureSource(id: "mixed output", role: .interviewer)
        let epoch = UUID()
        await detector.connect(source, epoch: epoch)

        let inputs = narration + [ambiguous]
        for (index, text) in inputs.enumerated() {
            let result = try await detector.receive(.init(source: source, epoch: epoch, itemID: String(index),
                                                          text: text, state: .final))
            XCTAssertNil(result, text)
        }
        let classified = await classifier.inputs
        XCTAssertEqual(classified.map(\.turn.text), inputs)
    }

    func testClassifierPayloadKeepsLatestUtteranceSeparateFromPriorQuestions() throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        let latest = "I would record the result before retrying."
        let earlier = "How would you safely retry the operation?"
        let input = QuestionInput(turn: .init(source: source, epoch: UUID(), itemID: "answer",
                                              text: latest, state: .final), previousQuestions: [earlier])
        let encoded = try ClassifierContext.encode(input)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["previousQuestions"] as? [String], [earlier])
        XCTAssertEqual(payload["latest"] as? String, latest)
        XCTAssertTrue(encoded.hasSuffix("\"latest\":\"\(latest)\"}"))
    }

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
            event("compound-logistics", "Thanks. Can you see the next slide?"),
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

    func testCallLogisticsDoNotSuppressAnInterviewRequestInTheSameTurn() async throws {
        let classifier = ClassifierFixture()
        let detector = QuestionDetector(classifier: classifier)
        let epoch = UUID()
        let interviewer = CaptureSource(id: "remote", role: .interviewer)
        await detector.connect(interviewer, epoch: epoch)
        let text = "Is the screen readable? Describe how you tested the audio export."
        let result = try await detector.receive(.init(source: interviewer, epoch: epoch, itemID: "mixed",
                                                      text: text, state: .final))
        XCTAssertEqual(result?.original, text)
        let inputs = await classifier.inputs
        XCTAssertEqual(inputs.map(\.turn.text), [text])
    }

    func testLiteralRepeatLinksToTheMatchingQuestionAcrossAnInterveningTurn() async throws {
        let detector = QuestionDetector(classifier: ClassifierFixture())
        let epoch = UUID()
        let interviewer = CaptureSource(id: "remote", role: .interviewer)
        await detector.connect(interviewer, epoch: epoch)
        let text = "Describe how you tested the audio export."
        func final(_ id: String, _ text: String) -> TranscriptEvent {
            .init(source: interviewer, epoch: epoch, itemID: id, text: text, state: .final)
        }
        let original = try await detector.receive(final("first", text))
        let intervening = try await detector.receive(final("second", "Describe the release process."))
        let repeatQuestion = try await detector.receive(final("literal-repeat", text))
        XCTAssertNotNil(original)
        XCTAssertNotEqual(intervening?.id, original?.id)
        XCTAssertNotEqual(repeatQuestion?.id, original?.id)
        XCTAssertEqual(repeatQuestion?.previousQuestionID, original?.id)
    }
}
