import Foundation
import XCTest
@testable import ConversationCore

final class AudioProcessingTests: XCTestCase {
    func testReplayProducesSampleClockAndKeepsRole() async throws {
        let source = CaptureSource(id: "replay", role: .candidate)
        let replay = PCMReplaySource(source: source, pcm: Data(repeating: 0, count: 2_000), pace: { _ in })
        var frames: [AudioFrame] = []
        for try await frame in try await replay.start() { frames.append(frame) }
        XCTAssertEqual(frames.map(\.startSample), [0, 480, 960])
        XCTAssertEqual(frames.map { $0.pcm.count }, [960, 960, 80])
        XCTAssertTrue(frames.allSatisfy { $0.source == source })
        await replay.stop()
    }

    func testAudioEndpointCommitsOnceAfterSpeechAndSilence() {
        let source = CaptureSource(id: "replay", role: .interviewer)
        let quiet = AudioFrame(source: source, sampleRate: 100, startSample: 0, pcm: Data(repeating: 0, count: 40))
        let speech = AudioFrame(source: source, sampleRate: 100, startSample: 0, pcm: Data(repeating: 60, count: 40))
        var endpoint = AudioEndpoint(silenceSeconds: 0.4)
        XCTAssertFalse(endpoint.observe(quiet).shouldCommit)
        XCTAssertGreaterThan(endpoint.observe(speech).level, 0.1)
        XCTAssertFalse(endpoint.observe(quiet).shouldCommit)
        XCTAssertTrue(endpoint.observe(quiet).shouldCommit)
        XCTAssertFalse(endpoint.observe(quiet).shouldCommit)
    }
}
