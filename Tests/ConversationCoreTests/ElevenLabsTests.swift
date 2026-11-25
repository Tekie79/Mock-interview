import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ConversationCore

actor ScriptedSocket: RealtimeSocket {
    private let messages: AsyncThrowingStream<Data, Error>
    private let input: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var sent: [String] = []

    init() { (messages, input) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(128)) }

    nonisolated func close() { input.finish() }
    func enqueue(_ text: String) { input.yield(Data(text.utf8)) }
    func fail(_ error: ProviderFailure = .timeout) { input.finish(throwing: error) }
    func send(_ text: String) { sent.append(text) }
    func read() async throws -> Data {
        var cursor = messages.makeAsyncIterator()
        guard let next = try await cursor.next() else { throw ProviderFailure.disconnected }
        return next
    }
}

private actor LateFinalSocket: RealtimeSocket {
    nonisolated let reading: AsyncStream<Void>
    nonisolated let closed: AsyncStream<Void>
    private let onRead: AsyncStream<Void>.Continuation
    private let onClose: AsyncStream<Void>.Continuation
    private var didStart = false
    private var pending: CheckedContinuation<Data, Never>?

    init() {
        (reading, onRead) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (closed, onClose) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated func close() { onClose.yield(()) }
    func send(_ text: String) {}

    func read() async throws -> Data {
        if !didStart {
            didStart = true
            return Data(scribeReady.utf8)
        }
        return await withCheckedContinuation {
            pending = $0
            onRead.yield(())
        }
    }

    func release(_ text: String) {
        pending?.resume(returning: Data(text.utf8))
        pending = nil
    }
}

private let scribeReady = #"{"message_type":"session_started","session_id":"synthetic","config":{"audio_format":"pcm_24000","sample_rate":24000,"model_id":"scribe_v3_live"}}"#

final class ElevenLabsTests: XCTestCase {
    private let source = CaptureSource(id: "replay", role: .interviewer)

    func testWireConfigurationGuardsUnsupportedStrategyAndKeepsCredentialInHeader() throws {
        let language = ElevenLabsSpeechConfiguration(language: "en", vocabulary: ["A & B", "C++"])
        let request = try language.request(key: "synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic")
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(.init(name: "commit_strategy", value: "turn_prediction")))
        XCTAssertTrue(items.contains(.init(name: "audio_format", value: "pcm_24000")))
        XCTAssertTrue(items.contains(.init(name: "keyterms", value: "A & B")))
        XCTAssertTrue(request.url?.absoluteString.contains("keyterms=C%2B%2B") == true)
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic") ?? true)
        XCTAssertThrowsError(try ElevenLabsSpeechConfiguration(model: "scribe_v2_realtime").request(key: "test"))
        XCTAssertThrowsError(try ElevenLabsSpeechConfiguration(language: "en-US").request(key: "test"))
        XCTAssertThrowsError(try language.request(key: ""))
    }

    func testRejectsMismatchedAudioConfigurationBeforeCapture() async throws {
        let socket = ScriptedSocket()
        await socket.enqueue(scribeReady.replacingOccurrences(of: "24000", with: "16000"))
        await socket.fail()
        let provider = ElevenLabsTranscriber(apiKey: "synthetic", configuration: .init(), socket: { _ in socket })
        do {
            _ = try await provider.connect(source: source, epoch: UUID())
            XCTFail("Expected the mismatched audio configuration to be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .malformedEvent)
        }
    }

    func testDelayedReadinessAndGracefulSemanticCommitWithWordMetadata() async throws {
        let (provider, socket, stream) = try await connect()
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Explain","turn_probability":0.2}"#)
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Explain caching","turn_probability":0.85}"#)
        let first = try await cursor.next()
        let second = try await cursor.next()
        XCTAssertEqual(first?.itemID, second?.itemID)
        XCTAssertEqual(second?.text, "Explain caching")
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Explain caching."}"#)
        await socket.enqueue(detailed("Explain caching.", 0.02, 0.09))
        await socket.fail() // A fallback failure must not be read after graceful completion.
        let final = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(final?.state, .final)
        XCTAssertEqual(final?.itemID, first?.itemID)
        XCTAssertEqual(final?.turnProbability, 0.85)
        XCTAssertEqual(final?.words.first?.endSeconds, 0.09)
        XCTAssertEqual(final?.language, "en")
        XCTAssertNil(end)
        let flags = try await commitFlags(socket)
        XCTAssertEqual(flags, [false, true])
        await provider.close()
    }

    func testDelayedCompanionAndReplayDoNotCloseNewerSpeechOrClearItsPartial() async throws {
        let (provider, socket, stream) = try await connect()
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"First","turn_probability":0.95}"#)
        let first = try await cursor.next()
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"First."}"#)

        try await provider.append(audio(at: 2_400, voiced: false))
        try await provider.append(audio(at: 4_800))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Second","turn_probability":0.8}"#)
        let second = try await cursor.next()
        XCTAssertNotEqual(first?.itemID, second?.itemID)
        try await provider.finishInput()

        let firstFinal = detailed("First.", 0.01, 0.09)
        await socket.enqueue(firstFinal)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"First."}"#)
        await socket.enqueue(firstFinal)
        await socket.enqueue(#"{"message_type":"committed_transcript_with_timestamps","text":"","words":[]}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Second."}"#)
        await socket.enqueue(detailed("Second.", 0.21, 0.29))
        await socket.fail()

        let committedFirst = try await cursor.next()
        let committedSecond = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(committedFirst?.itemID, first?.itemID)
        XCTAssertEqual(committedFirst?.turnProbability, 0.95)
        XCTAssertEqual(committedSecond?.itemID, second?.itemID)
        XCTAssertEqual(committedSecond?.previousItemID, first?.itemID)
        XCTAssertEqual(committedSecond?.turnProbability, 0.8)
        XCTAssertNil(end)
        await provider.close()
    }

    func testOlderFinalBeforeFinishDoesNotEraseNewerAudioWithoutAPartial() async throws {
        let (provider, socket, stream) = try await connect(strategy: .voiceActivity)
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.append(audio(at: 2_400))
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"First."}"#)
        await socket.enqueue(detailed("First.", 0.01, 0.09))
        let first = try await cursor.next()
        XCTAssertEqual(first?.text, "First.")
        try await provider.finishInput()
        let flags = try await commitFlags(socket)
        XCTAssertEqual(flags, [false, false, true])

        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Next."}"#)
        await socket.enqueue(detailed("Next.", 0.11, 0.19))
        await socket.fail()
        let last = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(last?.text, "Next.")
        XCTAssertNil(end)
        await provider.close()
    }

    func testDistinctCompanionsCanArriveOutOfOrderWithoutReorderingFinals() async throws {
        let (provider, socket, stream) = try await connect()
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.append(audio(at: 2_400))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Later","turn_probability":0.7}"#)
        let interim = try await cursor.next()
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Earlier."}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Later."}"#)
        await socket.enqueue(detailed("Later.", 0.11, 0.19))
        await socket.enqueue(detailed("Earlier.", 0.01, 0.09))
        await socket.fail()

        let first = try await cursor.next()
        let second = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(first?.text, "Earlier.")
        XCTAssertNil(first?.turnProbability)
        XCTAssertEqual(second?.text, "Later.")
        XCTAssertEqual(second?.itemID, interim?.itemID)
        XCTAssertEqual(second?.turnProbability, 0.7)
        XCTAssertEqual(second?.previousItemID, first?.itemID)
        XCTAssertNil(end)
        await provider.close()
    }

    func testDelayedPlainFinalCannotTakeTheNewerIdenticalPartial() async throws {
        let (provider, socket, stream) = try await connect()
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.append(audio(at: 2_400))
        await socket.enqueue(#"{"message_type":"partial_transcript","text":"Why?","turn_probability":0.7}"#)
        let newer = try await cursor.next()
        try await provider.finishInput()

        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Why?"}"#)
        await socket.enqueue(detailed("Why?", 0.01, 0.09))
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Why?"}"#)
        await socket.enqueue(detailed("Why?", 0.11, 0.19))
        await socket.fail()

        let first = try await cursor.next()
        let second = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(first?.state, .final)
        XCTAssertEqual(second?.state, .final)
        XCTAssertNotEqual(first?.itemID, newer?.itemID)
        XCTAssertNil(first?.turnProbability)
        XCTAssertEqual(second?.itemID, newer?.itemID)
        XCTAssertEqual(second?.turnProbability, 0.7)
        XCTAssertNil(end)
        await provider.close()
    }

    func testMultipleManualRequestsRemainIndependentAndAllowIntentionalRepeat() async throws {
        let (provider, socket, stream) = try await connect(strategy: .manual)
        XCTAssertTrue(provider.behavior.requiresStreamEnd)
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.commit()
        try await provider.append(audio(at: 2_400))
        try await provider.commit()
        try await provider.finishInput()
        let flags = try await commitFlags(socket)
        XCTAssertEqual(flags, [false, true, false, true])

        let older = detailed("Repeat?", 0.01, 0.09)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Repeat?"}"#)
        await socket.enqueue(older)
        await socket.enqueue(older)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"Repeat?"}"#)
        await socket.enqueue(detailed("Repeat?", 0.11, 0.19))
        await socket.fail()
        let first = try await cursor.next()
        let repeated = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(first?.text, "Repeat?")
        XCTAssertEqual(repeated?.text, first?.text)
        XCTAssertNotEqual(repeated?.itemID, first?.itemID)
        XCTAssertEqual(repeated?.previousItemID, first?.itemID)
        XCTAssertNil(end)
        await provider.close()
    }

    func testSilenceOnlyDrainFlushesBufferedAudioWithoutCommitOrTranscript() async throws {
        let (provider, socket, stream) = try await connect()
        try await provider.append(audio(at: 0, voiced: false, bytes: 960))
        try await provider.finishInput()
        await socket.fail()
        var cursor = stream.makeAsyncIterator()
        let end = try await cursor.next()
        let flags = try await commitFlags(socket)
        XCTAssertNil(end)
        XCTAssertEqual(flags, [false])
        await provider.close()
    }

    func testEmptyAndUnpositionedEventsCannotAcknowledgePendingCommit() async throws {
        let (provider, socket, stream) = try await connect()
        try await provider.append(audio(at: 0))
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"partial_transcript","text":""}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript","text":""}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript_with_timestamps","text":"","words":[]}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript_with_timestamps","text":"Unpositioned","words":null}"#)
        await socket.enqueue(detailed("Beyond sent audio", 0.11, 0.19))
        await socket.fail()
        var cursor = stream.makeAsyncIterator()
        do {
            let event = try await cursor.next()
            XCTFail("Expected a timeout with no transcript or successful EOF, received \(String(describing: event))")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .timeout)
        }
        await provider.close()
    }

    func testInsufficientActivityIsAnErrorNotAnEmptyAcknowledgment() async throws {
        let (provider, socket, stream) = try await connect()
        try await provider.append(audio(at: 0))
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"insufficient_audio_activity","error":"synthetic"}"#)
        var cursor = stream.makeAsyncIterator()
        do {
            let event = try await cursor.next()
            XCTFail("Expected a typed error, received \(String(describing: event))")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .unavailable)
        }
        await provider.close()
    }

    func testCancellationWhileDrainingIgnoresLateFinal() async throws {
        let socket = LateFinalSocket()
        let provider = ElevenLabsTranscriber(apiKey: "fake", configuration: .init(), socket: { _ in socket })
        let stream = try await provider.connect(source: source, epoch: UUID())
        var cursor = stream.makeAsyncIterator()
        var reading = socket.reading.makeAsyncIterator()
        var closed = socket.closed.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.finishInput()
        _ = await reading.next()
        let closing = Task { await provider.close() }
        _ = await closed.next()

        // Model a transport already returning a callback when cancellation reached it.
        await socket.release(detailed("Pending.", 0.01, 0.09))
        await closing.value
        do {
            let event = try await cursor.next()
            XCTFail("Expected cancellation, received \(String(describing: event))")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
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

    private func connect(strategy: TranscriptionCommitStrategy = .semanticTurn) async throws
        -> (ElevenLabsTranscriber, ScriptedSocket, AsyncThrowingStream<TranscriptEvent, Error>) {
        let socket = ScriptedSocket()
        let provider = ElevenLabsTranscriber(apiKey: "fake", configuration: .init(strategy: strategy), socket: { _ in socket })
        await socket.enqueue(scribeReady)
        return (provider, socket, try await provider.connect(source: source, epoch: UUID()))
    }

    private func audio(at start: Int64, voiced: Bool = true, bytes: Int = 4_800) -> AudioFrame {
        .init(source: source, sampleRate: 24_000, startSample: start, pcm: Data(repeating: voiced ? 80 : 0, count: bytes))
    }

    private func detailed(_ text: String, _ start: Double, _ end: Double) -> String {
        #"{"message_type":"committed_transcript_with_timestamps","text":"\#(text)","language_code":"en","words":[{"text":"word","start":\#(start),"end":\#(end),"type":"word"}]}"#
    }

    private func commitFlags(_ socket: ScriptedSocket) async throws -> [Bool] {
        try await socket.sent.map { payload in
            let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            return try XCTUnwrap(data["commit"] as? Bool)
        }
    }
}
