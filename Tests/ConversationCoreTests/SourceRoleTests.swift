import XCTest
@testable import ConversationCore

final class SourceRoleTests: XCTestCase {
    func testInterviewerCanProceedToQuestionClassification() {
        XCTAssertTrue(AutomaticQuestionRoleGate.permitsClassification(for: .interviewer))
    }

    func testCandidateCannotAutomaticallyTriggerClassification() {
        XCTAssertFalse(AutomaticQuestionRoleGate.permitsClassification(for: .candidate))
    }

    func testUnknownCannotAutomaticallyTriggerClassification() {
        XCTAssertFalse(AutomaticQuestionRoleGate.permitsClassification(for: .unknown))
    }
}
