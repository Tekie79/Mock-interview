import Foundation
import XCTest
@testable import ConversationCore

private actor HeldSessionSummarizer: SessionSummarizing {
    private(set) var input: [ConversationTurn] = []
    private var result: AsyncStream<String>.Continuation?

    func summarize(_ turns: [ConversationTurn]) async throws -> String {
        let (stream, result) = AsyncStream<String>.makeStream()
        input = turns
        self.result = result
        var iterator = stream.makeAsyncIterator()
        guard let text = await iterator.next() else { throw CancellationError() }
        return text
    }

    func release(_ text: String) { result?.yield(text); result?.finish() }
}

final class SessionMemoryTests: XCTestCase {
    func testOlderRelevantSpeechAndLatestCorrectionAreBothRetained() {
        var memory = SessionMemory()
        memory.append(.init(id: "project", role: .candidate, text: "Project Larch uses customer partitions."))
        for index in 0..<14 {
            memory.append(.init(id: "turn-\(index)", role: .interviewer, text: "Discuss other examples."))
        }
        memory.append(.init(id: "corrected", role: .candidate, text: "A correction to Larch: partition by region."))
        memory.append(.init(id: "unassigned", role: .unknown, text: "Invented context."))
        let context = ContextBudget(turns: 6).relevant(memory.turns, to: "Explain the Project Larch partition design.")
        XCTAssertEqual(context.first?.id, "project")
        XCTAssertEqual(context.last?.id, "corrected")
        XCTAssertFalse(memory.turns.contains { $0.id == "unassigned" })

        for index in 0..<130 {
            memory.append(.init(id: "next-\(index)", role: .candidate, text: "Bounded conversation."))
        }
        XCTAssertEqual(memory.turns.count, 128)
        memory.finish()
        XCTAssertTrue(memory.turns.isEmpty)
    }

    func testSummaryIsWithdrawnWhenAnySourceOrAssociatedQuestionLosesAttribution() throws {
        var memory = SessionMemory()
        for index in 0..<12 {
            memory.append(.init(id: String(index), role: .interviewer, text: "Original speech \(index)."))
        }
        let ids = Set(try XCTUnwrap(memory.takeSummaryBatch()).map(\.id))
        XCTAssertEqual(ids.count, 8)
        let question = UUID()
        memory.associate(["0", "1"], with: question)
        XCTAssertTrue(memory.installSummary("Older session context", sourceIDs: ids))
        XCTAssertEqual(memory.revoke(["0"], questions: [question]), ["0", "1"])
        XCTAssertTrue(memory.summaries.isEmpty)
        XCTAssertFalse(memory.installSummary("Late invalid summary", sourceIDs: ids))
    }

    func testBackgroundSummaryNeverBlocksAnAnswerAndOnlyUsesFinalSpokenTurns() async throws {
        let stt = InjectedSTT()
        let summarizer = HeldSessionSummarizer()
        let generator = ControlledGenerator()
        let source = CaptureSource(id: "candidate", role: .candidate)
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
            detector: .init(classifier: HeldClassifier(slow: false)), generator: generator, summarizer: summarizer,
            evidence: { _ in ["Approved profile fact"] })
        await session.start()
        try await eventually { await session.current().connected.contains(source.id) }
        await stt.send("Unfinished speech", item: "partial", state: .partial)
        for index in 0..<12 {
            await stt.send("Spoken project detail \(index)", item: "said-\(index)")
        }
        try await eventually { await summarizer.input.count == 8 }
        let originals = await summarizer.input
        XCTAssertTrue(originals.allSatisfy { $0.role == .candidate && $0.text.hasPrefix("Spoken project detail") })
        let before = await session.current()
        XCTAssertTrue(before.answers.isEmpty)
        await session.manualQuestion("How should I explain the project?")
        var requests = generator.started.makeAsyncIterator()
        let inFlight = await requests.next()
        XCTAssertEqual(inFlight?.sessionSummaries, [])
        await generator.write("Suggested content", to: 0, finish: true)
        await summarizer.release("Unverified summary of earlier spoken details")
        try await eventually { await session.current().sessionSummariesCompleted == 1 }
        await session.manualQuestion("What changed on this project?")
        let followUp = await requests.next()
        XCTAssertEqual(followUp?.sessionSummaries, ["Unverified summary of earlier spoken details"])
        XCTAssertEqual(followUp?.evidence, ["Approved profile fact"])
        XCTAssertFalse(followUp?.interviewContext.contains(where: { $0.contains("Suggested content") }) ?? true)
        await session.stop()
    }

    func testOpenAISummaryContractUsesStatelessLunaAndAttributedInput() throws {
        let request = try OpenAISessionSummarizer(apiKey: "fixture").summaryRequest([
            .init(id: "spoken", role: .candidate, text: "Actual project correction."),
            .init(id: "unknown", role: .unknown, text: "Unassigned content.")
        ])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 320)
        let input = try XCTUnwrap(body["input"] as? String)
        XCTAssertTrue(input.contains("Actual project correction"))
        XCTAssertFalse(input.contains("Unassigned content"))
    }

    func testStopDiscardsALateSummaryWithoutSavingIt() async throws {
        let stt = InjectedSTT()
        let summarizer = HeldSessionSummarizer()
        let source = CaptureSource(id: "candidate", role: .candidate)
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
            detector: .init(classifier: HeldClassifier(slow: false)), generator: ControlledGenerator(), summarizer: summarizer)
        await session.start()
        try await eventually { await session.current().connected.contains(source.id) }
        for index in 0..<12 { await stt.send("Recorded speech \(index)", item: String(index)) }
        try await eventually { await summarizer.input.count == 8 }
        await session.stop()
        await summarizer.release("Stale derived context")
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertEqual(snapshot.sessionSummariesCompleted, 0)
        XCTAssertEqual(snapshot.transcript.filter(\.isFinal).count, 12)
        XCTAssertFalse(snapshot.diagnosticSummary.contains("Stale derived context"))
    }
}
