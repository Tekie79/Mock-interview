import Foundation
import XCTest
@testable import ConversationCore

private struct NeverClassify: QuestionClassifier {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        XCTFail("Manual requests must bypass automatic classification.")
        return QuestionDecision(decision: .ignore)
    }
}

actor ControlledGenerator: TextGenerator {
    private var streams: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []
    private let requests: AsyncStream<AnswerRequest>.Continuation
    let started: AsyncStream<AnswerRequest>
    private(set) var submitted: [AnswerRequest] = []

    init() {
        (started, requests) = AsyncStream.makeStream()
    }

    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        streams.append(continuation)
        submitted.append(request)
        requests.yield(request)
        return stream
    }

    func write(_ text: String, to index: Int, finish: Bool = false) {
        streams[index].yield(.text(text))
        if finish { streams[index].finish() }
    }
}

final class AnswerStreamingTests: XCTestCase {
    func testManualGenerationSupersedesAndPauseInvalidates() async throws {
        let generator = ControlledGenerator()
        let session = InterviewSession(channels: [], detector: QuestionDetector(classifier: NeverClassify()),
                                       generator: generator, evidence: { _ in ["Reviewed evidence"] })
        await session.start()
        let updates = await session.updates()
        var requests = generator.started.makeAsyncIterator()
        await session.manualQuestion("Explain retries.")
        let first = await requests.next()
        XCTAssertEqual(first?.evidence, ["Reviewed evidence"])
        await session.manualQuestion("Explain queues.")
        let second = await requests.next()
        XCTAssertEqual(second?.question, "Explain queues.")
        await generator.write("Stale", to: 0, finish: true)
        await generator.write("Fresh", to: 1, finish: true)
        for await snapshot in updates where snapshot.answers.last?.state == .complete {
            XCTAssertEqual(snapshot.answers.map(\.state), [.superseded, .complete])
            XCTAssertEqual(snapshot.answers.map(\.text), ["", "Fresh"])
            break
        }
        await session.manualQuestion("Explain timeouts.")
        _ = await requests.next()
        await session.pause()
        await generator.write("After pause", to: 2, finish: true)
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.answers.last?.state, .cancelled)
        XCTAssertEqual(snapshot.answers.last?.text, "")
        await session.stop()
    }

    func testSSEHandlesSplitUTF8MultilineAndCompletion() throws {
        var parser = EventStreamParser()
        var messages: [String] = []
        let wire = Data("data: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"ሰ\"}\r\n\r\ndata: {\"type\":\"response.completed\"}\n\n".utf8)
        for byte in wire {
            try parser.receive(Data([byte])) { messages.append($0) }
        }
        XCTAssertEqual(messages.count, 2)
        if case .text(let text) = try OpenAITextGenerator.decode(messages[0]) {
            XCTAssertEqual(text, "ሰ")
        } else {
            XCTFail("Expected text delta")
        }
        guard case .complete = try OpenAITextGenerator.decode(messages[1]) else {
            return XCTFail("Expected completion")
        }
    }
}

extension AnswerStreamingTests {
    func testJobRequirementsAreKeptSeparateFromApprovedEvidence() throws {
        let request = AnswerRequest(question: "How have you used distributed tracing?", instructions: "",
                                    evidence: [], interviewContext: ["Job requirements: tracing experience"])
        let data = Data(try AnswerPrompt.input(request).utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        XCTAssertEqual(payload["approved_facts"], [])
        XCTAssertEqual(payload["interview_context"], ["Job requirements: tracing experience"])
    }
}
