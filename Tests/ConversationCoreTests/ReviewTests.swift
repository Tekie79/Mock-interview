import Foundation
import XCTest
@testable import ConversationCore

final class ReviewTests: XCTestCase {
    func testHistorySearchOnlyAfterExplicitSaveAndDeletesIndex() async throws {
        let library = try KnowledgeStore()
        let now = Date()
        let question = "How do queues handle backpressure?"
        let transcript = [
            InterviewTranscript(id: "actual", role: .candidate, text: "I used bounded queues.", isFinal: true),
            InterviewTranscript(id: "partial", role: .unknown, text: "This is provisional.", isFinal: false)
        ]
        let suggestion = InterviewAnswer(question: AcceptedQuestion(original: question, normalized: question),
                                         revision: UUID(), format: .brief, text: "Explain bounded buffers.",
                                         state: .complete)
        var session = SavedInterview(title: "Practice", startedAt: now, endedAt: now, transcript: transcript,
                                     suggestions: [suggestion], missedQuestions: [question])
        let empty = try await library.savedInterviews()
        XCTAssertTrue(empty.isEmpty)
        let coaching = session.coachingInput(question: question, actualAnswer: transcript[0].text)
        XCTAssertEqual(coaching?.candidateAnswer, "I used bounded queues.")
        XCTAssertEqual(coaching?.suggestedAnswer, "Explain bounded buffers.")
        XCTAssertFalse(session.plainText.contains("provisional"))
        XCTAssertTrue(session.plainText.contains("Candidate: I used bounded queues."))
        XCTAssertTrue(session.plainText.contains("Suggested answers"))
        try await library.saveInterview(session)
        let indexed = try await library.savedInterviews(matching: "backpressure")
        XCTAssertEqual(indexed, [session])

        session.notes = "Talk about saturation."
        try await library.saveInterview(session)
        let edited = try await library.savedInterviews(matching: "saturation")
        XCTAssertEqual(edited.map(\.id), [session.id])
        try await library.deleteInterview(session.id)
        let removed = try await library.savedInterviews(matching: "saturation")
        XCTAssertTrue(removed.isEmpty)
    }
}
