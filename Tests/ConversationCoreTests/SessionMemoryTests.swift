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

extension SessionMemoryTests {
    func testCaptureTimeIncludesLatePriorCandidateAndExcludesFutureAndUnmappedLateSpeech() {
        let origin = ContinuousClock.now
        let boundary = ContextBoundary(instant: origin.advanced(by: .seconds(4)), order: 8)
        var memory = SessionMemory()
        memory.append(.init(id: "future", role: .candidate, text: "Future conversation"),
                      stamp: .init(end: origin.advanced(by: .seconds(6)), order: 4))
        memory.append(.init(id: "late-prior", role: .candidate, text: "Candidate repaired the job."),
                      stamp: .init(source: "mic", epoch: UUID(), end: origin.advanced(by: .seconds(3)), order: 9))
        memory.append(.init(id: "late-unmapped", role: .candidate, text: "Timing unavailable"),
                      stamp: .init(order: 10))

        let ids = { (mode: InterviewContextMode) in
            memory.context(before: boundary, ignoring: [], query: "How did the job recover?",
                           budget: .init(), configuration: .init(mode: mode)).map(\.id)
        }
        XCTAssertEqual(ids(.recent), ["late-prior"])
        XCTAssertEqual(ids(.adaptive), ["late-prior"])
        XCTAssertTrue(memory.context(before: boundary, ignoring: [], query: "job",
            budget: .init(), configuration: .init(includesCandidate: false)).isEmpty)
    }

    func testLearnedEditsAndSummaryRolloverPreserveOriginalSpeechAndBounds() throws {
        var memory = SessionMemory()
        for index in 0..<12 {
            memory.append(.init(id: String(index), role: .candidate, text: "Candidate migration \(index)."),
                          stamp: .init(order: UInt64(index + 1)))
        }
        let candidate = try XCTUnwrap(memory.takeSummaryBatch())
        let sources = Set(candidate.map(\.id))
        for index in 0..<6 { XCTAssertTrue(memory.installSummary("Derived \(index)", sourceIDs: sources)) }
        XCTAssertEqual(memory.summaries.count, 4)
        XCTAssertTrue(memory.validSummaries(before: .init(order: 2), ignoring: []).isEmpty)
        XCTAssertTrue(memory.correct("0", text: "The migration used queues."))
        XCTAssertTrue(memory.summaries.isEmpty)
        XCTAssertEqual(memory.turns.first?.text, "Candidate migration 0.")
        let edited = memory.context(before: .init(order: 14), ignoring: [], query: "migration queues",
                                    budget: .init(), configuration: .init())
        XCTAssertTrue(edited.contains { $0.text == "User correction: The migration used queues." })
        XCTAssertTrue(memory.exclude("0", excluded: true))
        let included = memory.context(before: .init(order: 14), ignoring: [], query: "migration queues",
                                      budget: .init(), configuration: .init())
        XCTAssertFalse(included.contains { $0.id == "0" })
        XCTAssertTrue(memory.items.first?.isExcluded == true)
    }

    func testViewportRequiresUsefulTextInsideAVisibleWindow() {
        let firstLine = CGRect(x: 15, y: 20, width: 120, height: 20)
        XCTAssertTrue(AnswerViewportVisibility.containsUsefulText(firstLine, in: CGRect(x: 0, y: 0, width: 200, height: 50), windowVisible: true))
        XCTAssertFalse(AnswerViewportVisibility.containsUsefulText(firstLine, in: CGRect(x: 0, y: 30, width: 200, height: 50), windowVisible: true))
        XCTAssertFalse(AnswerViewportVisibility.containsUsefulText(firstLine, in: CGRect(x: 0, y: 0, width: 200, height: 50), windowVisible: false))
        XCTAssertFalse(AnswerViewportVisibility.containsUsefulText(firstLine, in: CGRect(x: 150, y: 0, width: 200, height: 50), windowVisible: true))
    }

    func testDuplicatingAProfileRetainsExplicitExclusionsAndSourceOwnership() async throws {
        let store = try KnowledgeStore()
        let profile = InterviewProfile(name: "Synthetic profile", role: "Engineer")
        try await store.save(profile)
        let source = ProfileDocument(kind: .resume, title: "fixture.md", text: "Built a synthetic queue.")
        try await store.add(source, to: profile.id)
        try await store.save(.init(documentID: source.id, claim: "Excluded statement", status: .rejected), profile: profile.id)
        let copy = try await store.duplicateProfile(profile.id)
        let documents = try await store.documents(profile: copy.id)
        let copied = try await store.facts(profile: copy.id)
        XCTAssertEqual(documents.map(\.title), ["fixture.md"])
        XCTAssertNotEqual(documents.first?.id, source.id)
        XCTAssertEqual(copied.last?.documentID, documents.first?.id)
        XCTAssertEqual(copied.last?.status, .rejected)
        XCTAssertNotNil(copy.modifiedAt)
    }
}

private actor GatedContextClassifier: QuestionClassifier {
    private(set) var began = false
    private var pending: AsyncStream<Void>.Continuation?

    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        let (gate, pending) = AsyncStream<Void>.makeStream()
        self.pending = pending
        began = true
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        return .init(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text])
    }
    func release() { pending?.finish() }
}

extension SessionMemoryTests {
    func testDelayedCandidateFinalWhileClassificationRunsAndCorrectionWithdrawsRevision() async throws {
        let classifier = GatedContextClassifier()
        let generator = ControlledGenerator()
        let interviewer = InjectedSTT()
        let candidate = InjectedSTT()
        let session = InterviewSession(channels: [
            .init(source: .init(id: "interviewer", role: .interviewer), audio: HeldAudio(), makeSTT: { interviewer }),
            .init(source: .init(id: "interviewee", role: .candidate), audio: HeldAudio(), makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: generator,
           contextConfiguration: .init(mode: .adaptive, adaptsSpeakingStyle: true))
        let origin = ContinuousClock.now.advanced(by: .seconds(-20))
        func timing(_ start: Int) -> PipelineTiming {
            var value = PipelineTiming()
            value.speechStart = origin.advanced(by: .seconds(start))
            value.endpoint = origin.advanced(by: .seconds(start + 1))
            value.audioTimingBasis = .providerRangeEstimate
            return value
        }

        await session.start()
        try await eventually { await session.current().connected.count == 2 }
        await interviewer.send("How did you choose a delivery strategy?", item: "ask", timing: timing(8))
        try await eventually { await classifier.began }
        await candidate.send("The checkpoint uses a durable ledger.", item: "late", timing: timing(4))
        await candidate.send("The next subject is database encryption.", item: "future", timing: timing(13))
        try await eventually { await session.current().learnedContext.count == 3 }
        await classifier.release()
        try await eventually { await generator.submitted.count == 1 }
        let requests = await generator.submitted
        XCTAssertTrue(requests[0].interviewContext.contains { $0.contains("durable ledger") })
        XCTAssertTrue(requests[0].interviewContext.contains { $0.contains("style only") })
        XCTAssertFalse(requests[0].interviewContext.contains { $0.contains("database encryption") })
        await generator.write("Synthetic answer", to: 0, finish: true)
        try await eventually { await session.current().answers.first?.state == .complete }
        let before = await session.current()
        let late = try XCTUnwrap(before.learnedContext.first { $0.text.contains("durable ledger") })
        await session.correctLearnedContext(late.id, text: "It uses an append-only log.")
        let after = await session.current()
        XCTAssertEqual(after.answers.first?.state, .invalidated)
        XCTAssertEqual(after.answers.first?.revision, before.answers.first?.revision)
        XCTAssertTrue(after.transcript.contains { $0.text.contains("durable ledger") })
        XCTAssertTrue(after.learnedContext.contains { $0.id == late.id && $0.isEdited })
        await session.stop()
        let stopped = await session.current()
        XCTAssertTrue(stopped.learnedContext.isEmpty)
    }
}
