import XCTest
@testable import ConversationCore

final class AnswerPresentationTests: XCTestCase {
    func testStarExpandsInlineLabelsIntoFourSections() {
        let text = "**Situation:** The queue backed up. **Task:** Reduce delays. Action: Add bounded retries. Result: Latency recovered."
        XCTAssertEqual(AnswerPresentation.blocks(for: text, format: .star), [
            .heading("Situation"), .paragraph("The queue backed up."),
            .heading("Task"), .paragraph("Reduce delays."),
            .heading("Action"), .paragraph("Add bounded retries."),
            .heading("Result"), .paragraph("Latency recovered.")
        ])
    }

    func testTalkingPointsKeepExplicitListAndFormatPlainSentences() {
        XCTAssertEqual(AnswerPresentation.blocks(for: "- Store the ID.\n- Acknowledge after writing.", format: .bullets), [
            .item(marker: "•", body: "Store the ID."), .item(marker: "•", body: "Acknowledge after writing.")
        ])
        XCTAssertEqual(AnswerPresentation.blocks(for: "Store the ID. Acknowledge after writing.", format: .bullets), [
            .item(marker: "•", body: "Store the ID."), .item(marker: "•", body: "Acknowledge after writing.")
        ])
    }

    func testBriefLimitsParagraphLengthWithoutBreakingCommonAbbreviations() {
        let text = "Consult Dr. Patel. Set a baseline. Measure changes. Keep a rollback ready."
        XCTAssertEqual(AnswerPresentation.blocks(for: text, format: .brief), [
            .paragraph("Consult Dr. Patel. Set a baseline."),
            .paragraph("Measure changes. Keep a rollback ready.")
        ])
        XCTAssertEqual(AnswerPresentation.blocks(for: text, format: .ultraBrief), [.paragraph(text)])
    }

    func testTechnicalPreservesIndentationInStreamingCodeAndNumberedSteps() {
        let text = "Approach: Detect duplicate work.\n1. Read the record.\n```swift\nif let value {\n    return value"
        XCTAssertEqual(AnswerPresentation.blocks(for: text, format: .technical), [
            .heading("Approach"), .paragraph("Detect duplicate work."),
            .item(marker: "1.", body: "Read the record."),
            .code("if let value {\n    return value")
        ])
    }
}
