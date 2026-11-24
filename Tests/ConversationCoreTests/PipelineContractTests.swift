import Foundation
import XCTest
@testable import ConversationCore

private struct FixtureAudioSource: AudioSource {
    let frames: [AudioFrame]

    func start() async throws -> AsyncThrowingStream<AudioFrame, Error> {
        AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    func stop() async {}
}

private actor FixtureTranscriber: StreamingSTT {
    private var continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var event: TranscriptEvent?

    func connect(source: CaptureSource, epoch: UUID) async throws
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        event = TranscriptEvent(source: source, epoch: epoch, itemID: "synthetic-1",
                                text: "Explain backpressure.", state: .final)
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func append(_ frame: AudioFrame) async throws {
        precondition(frame.source == event?.source)
    }

    func commit() async throws {
        if let event {
            continuation?.yield(event)
        }
    }

    func close() async {
        continuation?.finish()
        continuation = nil
        event = nil
    }
}

final class PipelineContractTests: XCTestCase {
    func testSyntheticAudioPassesSourceAndEpochToTranscript() async throws {
        let source = CaptureSource(id: "replay", role: .interviewer)
        let epoch = UUID()
        let audio = FixtureAudioSource(frames: [
            AudioFrame(source: source, sampleRate: 24_000, startSample: 0, pcm: Data([0, 1]))
        ])
        let stt = FixtureTranscriber()
        let events = try await stt.connect(source: source, epoch: epoch)
        for try await frame in try await audio.start() {
            try await stt.append(frame)
        }
        try await stt.commit()
        await stt.close()
        await audio.stop()

        var received: [TranscriptEvent] = []
        for try await event in events {
            received.append(event)
        }
        XCTAssertEqual(received, [
            TranscriptEvent(source: source, epoch: epoch, itemID: "synthetic-1",
                            text: "Explain backpressure.", state: .final)
        ])
    }
}
