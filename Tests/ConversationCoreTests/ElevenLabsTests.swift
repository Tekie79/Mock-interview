import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ConversationCore

private actor ScriptedSocket: RealtimeSocket {
    private var unread: [Data] = []
    private(set) var sent: [String] = []

    nonisolated func close() {}
    func enqueue(_ text: String) { unread.append(Data(text.utf8)) }
    func send(_ text: String) { sent.append(text) }
    func read() async throws -> Data {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if !unread.isEmpty { return unread.removeFirst() }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProviderFailure.timeout
    }
}

final class ElevenLabsTests: XCTestCase {
    func testWireConfigurationGuardsUnsupportedStrategyAndKeepsCredentialInHeader() throws {
        let language = ElevenLabsSpeechConfiguration(language: "en", vocabulary: ["A & B"])
        let request = try language.request(key: "synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic")
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(.init(name: "commit_strategy", value: "turn_prediction")))
        XCTAssertTrue(items.contains(.init(name: "audio_format", value: "pcm_24000")))
        XCTAssertTrue(items.contains(.init(name: "keyterms", value: "A & B")))
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic") ?? true)
        XCTAssertThrowsError(try ElevenLabsSpeechConfiguration(model: "scribe_v2_realtime").request(key: "test"))
        XCTAssertThrowsError(try ElevenLabsSpeechConfiguration(language: "en-US").request(key: "test"))
        XCTAssertThrowsError(try language.request(key: ""))
    }

    func testDelayedReadinessAndGracefulSemanticCommitWithWordMetadata() async throws {
        let socket = ScriptedSocket()
        let provider = ElevenLabsTranscriber(apiKey: "fake", configuration: .init(), socket: { _ in socket })
        let source = CaptureSource(id: "replay", role: .interviewer)
        await socket.enqueue(#"{"message_type":"session_started","session_id":"synthetic"}"#)
        let stream = try await provider.connect(source: source, epoch: UUID())
        var cursor = stream.makeAsyncIterator()
        try await provider.append(.init(source: source, sampleRate: 24_000, startSample: 0,
                                        pcm: Data(repeating: 80, count: 4_800)))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Explain","turn_probability":0.2}"#)
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Explain caching","turn_probability":0.85}"#)
        let first = try await cursor.next()
        let second = try await cursor.next()
        XCTAssertEqual(first?.itemID, second?.itemID)
        XCTAssertEqual(second?.text, "Explain caching")
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Explain caching."}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript_with_timestamps","text":"Explain caching.","language_code":"en","words":[{"text":"caching","start":0.2,"end":0.4,"type":"word"}]}"#)
        let final = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(final?.state, .final)
        XCTAssertEqual(final?.itemID, first?.itemID)
        XCTAssertEqual(final?.turnProbability, 0.85)
        XCTAssertEqual(final?.words.first?.endSeconds, 0.4)
        XCTAssertNil(end)
        let payloads = await socket.sent
        XCTAssertEqual(payloads.count, 2)
        let last = try XCTUnwrap(payloads.last)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        XCTAssertEqual(data["commit"] as? Bool, true)
        await provider.close()
    }

    func testAuthenticationAndRateLimitsAreTypedAndRedacted() async throws {
        let socket = ScriptedSocket()
        let provider = ElevenLabsTranscriber(apiKey: "fake", configuration: .init(), socket: { _ in socket })
        await socket.enqueue(#"{"message_type":"auth_error","error":"private"}"#)
        do {
            try await provider.testConnection()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .authentication)
            XCTAssertFalse(publicErrorMessage(error).contains("private"))
        }
        XCTAssertThrowsError(try ElevenLabsWire.decode(Data(#"{"message_type":"rate_limited"}"#.utf8))) {
            XCTAssertEqual($0 as? ProviderFailure, .rateLimited)
        }
    }
}
