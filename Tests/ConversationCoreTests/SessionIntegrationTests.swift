import Foundation
import XCTest
@testable import ConversationCore

private actor ReplaySTT: StreamingSTT {
    private var event: TranscriptEvent?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var byteCount = 0

    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        event = TranscriptEvent(source: source, epoch: epoch, itemID: "synthetic-retry",
                                text: "Explain exponential backoff.", state: .final)
        return stream
    }

    func append(_ frame: AudioFrame) async throws {
        byteCount += frame.pcm.count
    }

    func commit() async throws {
        guard byteCount > 0, let event else { throw ProviderFailure.requestRejected }
        output?.yield(event)
        output?.yield(event)
        byteCount = 0
    }

    func close() async {
        output?.finish()
        output = nil
    }
}

private struct ReplayClassifier: QuestionClassifier {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        QuestionDecision(decision: .accept, normalizedQuestion: input.turn.text,
                         parts: ["Explain exponential backoff"])
    }
}

private struct ReplayAnswer: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        XCTAssertTrue(request.question.contains("backoff"))
        return AsyncThrowingStream {
            $0.yield(.text("Increase the retry delay."))
            $0.yield(.usage(TokenUsage(input: 12, output: 6)))
            $0.finish()
        }
    }
}

final class SessionIntegrationTests: XCTestCase {
    func testPCMToAnswerAndDiagnosticsContainNoDialogue() async throws {
        let id = CaptureSource(id: "replay", role: .interviewer)
        var waveform = Data(repeating: 64, count: 4_800)
        waveform.append(Data(repeating: 0, count: 24_000))
        let audio = PCMReplaySource(source: id, pcm: waveform, pace: { _ in })
        let (hold, gate) = AsyncStream<Void>.makeStream()
        let channel = TranscriptionChannel(source: id, audio: audio, makeSTT: { ReplaySTT() }, delay: { _ in
            var wait = hold.makeAsyncIterator()
            _ = await wait.next()
        })
        let session = InterviewSession(channels: [channel], detector: QuestionDetector(classifier: ReplayClassifier()),
                                       generator: ReplayAnswer())
        let updates = await session.updates()
        await session.start()
        for await update in updates where update.answers.last?.state == .complete {
            XCTAssertEqual(update.answers.count, 1)
            XCTAssertEqual(update.answers.first?.text, "Increase the retry delay.")
            XCTAssertEqual(update.usage, TokenUsage(input: 12, output: 6))
            XCTAssertEqual(update.transcript.filter(\.isFinal).count, 1)
            XCTAssertFalse(update.diagnosticSummary.contains("backoff"))
            XCTAssertFalse(update.diagnosticSummary.contains("retry delay"))
            break
        }
        await session.stop()
        gate.finish()
        let stopped = await session.current()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(stopped.connected.isEmpty)
    }

    func testProviderErrorTextIsRedacted() {
        let error = NSError(domain: "synthetic-secret-value", code: 401, userInfo: [
            NSLocalizedDescriptionKey: "Bearer synthetic-secret-value"
        ])
        XCTAssertFalse(publicErrorMessage(error).contains("synthetic-secret-value"))
        XCTAssertTrue(publicErrorMessage(ProviderFailure.authentication).contains("Settings"))
    }
}
