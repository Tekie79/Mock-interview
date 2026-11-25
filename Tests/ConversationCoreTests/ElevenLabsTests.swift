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

    func testDiarizationIsOptInAndLimitedToScribeV3Live() throws {
        let request = try ElevenLabsSpeechConfiguration(diarize: true).request(key: "synthetic")
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(.init(name: "diarize", value: "true")))
        XCTAssertTrue(items.contains(.init(name: "include_timestamps", value: "false")))
        XCTAssertThrowsError(try ElevenLabsSpeechConfiguration(model: "scribe_v2_realtime", strategy: .manual,
                                                                 diarize: true).request(key: "synthetic"))
        XCTAssertFalse(try ElevenLabsSpeechConfiguration().request(key: "synthetic").url?.query?.contains("diarize=") ?? true)
    }

    func testIndexedDiarizationPreservesRepeatedTurnsAndWithholdsUnknownAndMixedWords() async throws {
        let (provider, socket, stream) = try await connect(diarize: true)
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.append(audio(at: 2_400))
        try await provider.append(audio(at: 4_800))
        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":0,"text":"Explain retries."}"#)
        await socket.enqueue(#"{"message_type":"diarized_transcript","segment_index":9,"text":"Explain retries.","words":[{"text":"Explain retries.","start":0,"end":0.1,"speaker_id":"speaker_9"}]}"#)
        let firstPending = try await cursor.next()
        XCTAssertEqual(firstPending?.state, .partial)
        await socket.enqueue(#"{"message_type":"diarized_transcript","segment_index":0,"text":"Explain retries.","words":[{"text":"Explain","start":0,"end":0.05,"speaker_id":"speaker_1"},{"text":" ","type":"spacing"},{"text":"retries.","start":0.05,"end":0.1,"speaker_id":"speaker_1"}]}"#)
        let first = try await cursor.next()
        XCTAssertEqual(first?.speaker, 1)
        XCTAssertEqual(first?.itemID, firstPending?.itemID)
        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":0,"text":"Explain retries."}"#)
        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":1,"text":"Explain retries."}"#)
        await socket.enqueue(#"{"message_type":"diarized_transcript","segment_index":1,"text":"Explain retries.","words":[{"text":"Explain","start":0.1,"end":0.15,"speaker_id":"speaker_1"},{"text":"retries.","start":0.15,"end":0.2,"speaker_id":"speaker_2"}]}"#)
        let secondPending = try await cursor.next()
        let second = try await cursor.next()
        XCTAssertEqual(secondPending?.state, .partial)
        XCTAssertEqual(second?.state, .final)
        XCTAssertEqual(second?.text, first?.text)
        XCTAssertNotEqual(second?.itemID, first?.itemID)
        XCTAssertNil(second?.speaker)

        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":2,"text":"Explain timeouts."}"#)
        await socket.enqueue(#"{"message_type":"diarized_transcript","segment_index":2,"text":"Explain timeouts.","words":[{"text":"Explain","start":0.2,"end":0.25,"speaker_id":"speaker_1"},{"text":"timeouts.","start":0.25,"end":0.3,"speaker_id":null}]}"#)
        _ = try await cursor.next()
        let unknown = try await cursor.next()
        XCTAssertNil(unknown?.speaker)
        XCTAssertEqual(unknown?.text, "Explain timeouts.")
        try await provider.finishInput()
        let end = try await cursor.next()
        XCTAssertNil(end)
        await provider.close()
    }

    func testSpeakerMergeRepairsLaterIDsAndMissingDiarizationRetainsOriginalText() async throws {
        let (provider, socket, stream) = try await connect(diarize: true)
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        await socket.enqueue(#"{"message_type":"speakers_merged","from_speaker_id":"speaker_1","to_speaker_id":"speaker_3"}"#)
        let merge = try await cursor.next()
        XCTAssertEqual(merge?.state, .speakerMerge(from: 1, to: 3))
        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":0,"text":"Explain retries."}"#)
        await socket.enqueue(#"{"message_type":"diarized_transcript","segment_index":0,"text":"Explain retries.","words":[{"text":"Explain retries.","start":0,"end":0.1,"speaker_id":"speaker_1"}]}"#)
        _ = try await cursor.next()
        let associated = try await cursor.next()
        XCTAssertEqual(associated?.speaker, 3)
        await socket.enqueue(#"{"message_type":"committed_transcript","segment_index":1,"text":"Original text."}"#)
        let pending = try await cursor.next()
        await socket.fail(.disconnected)
        let retained = try await cursor.next()
        XCTAssertEqual(retained?.state, .final)
        XCTAssertEqual(retained?.itemID, pending?.itemID)
        XCTAssertEqual(retained?.text, "Original text.")
        XCTAssertNil(retained?.speaker)
        do {
            _ = try await cursor.next()
            XCTFail("Expected a disconnected transport to surface its failure")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .disconnected)
        }
        await provider.close()
    }

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

    func testSemanticTurnRetainsATimestampOnlyFinalWhileWaitingForAnEarlierCompanion() async throws {
        let (provider, socket, stream) = try await connect()
        var cursor = stream.makeAsyncIterator()
        try await provider.append(audio(at: 0))
        try await provider.append(audio(at: 2_400))
        try await provider.finishInput()
        await socket.enqueue(#"{"message_type":"committed_transcript","text":"First"}"#)
        await socket.enqueue(detailed("Second?", 0.11, 0.19))
        await socket.enqueue(detailed("First.", 0.01, 0.09))
        await socket.fail()
        let first = try await cursor.next()
        let second = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(first?.text, "First.")
        XCTAssertEqual(second?.text, "Second?")
        XCTAssertEqual(second?.previousItemID, first?.itemID)
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

    func testInteriorFinalPreservesBothSidesAndAcceptsAnOverlappingEarlierResult() async throws {
        let (provider, socket, stream) = try await connect(strategy: .manual)
        for offset in [0, 2_400, 4_800] { try await provider.append(audio(at: Int64(offset))) }
        try await provider.finishInput()
        var cursor = stream.makeAsyncIterator()
        await socket.enqueue(detailed("Middle", 0.1, 0.2))
        await socket.enqueue(detailed("Trailing", 0.19, 0.29))
        await socket.enqueue(detailed("Leading", 0.01, 0.11))
        await socket.fail()

        for expected in ["Middle", "Trailing", "Leading"] {
            let final = try await cursor.next()
            XCTAssertEqual(final?.text, expected)
        }
        let end = try await cursor.next()
        XCTAssertNil(end)
        await provider.close()
    }

    func testFinalsOnBothSidesOfANontrivialIntermediateGapCannotCompleteDrain() async throws {
        let (provider, socket, stream) = try await connect(strategy: .manual)
        for offset in [0, 2_400, 4_800] { try await provider.append(audio(at: Int64(offset))) }
        try await provider.finishInput()
        var cursor = stream.makeAsyncIterator()
        await socket.enqueue(detailed("Leading", 0.01, 0.1))
        await socket.enqueue(detailed("Trailing", 0.2, 0.29))
        await socket.fail()

        for expected in ["Leading", "Trailing"] {
            let final = try await cursor.next()
            XCTAssertEqual(final?.text, expected)
        }
        do {
            _ = try await cursor.next()
            XCTFail("A missing middle result cannot acknowledge the commit")
        } catch { XCTAssertEqual(error as? ProviderFailure, .timeout) }
        await provider.close()
    }

    func testAllScribeStrategiesAccountForAnchoredAcousticEdgesBeyondWordTimings() async throws {
        for strategy: TranscriptionCommitStrategy in [.manual, .voiceActivity, .semanticTurn] {
            let (provider, socket, stream) = try await connect(strategy: strategy)
            for offset in [0, 2_400, 4_800] { try await provider.append(audio(at: Int64(offset))) }
            try await provider.finishInput()
            var cursor = stream.makeAsyncIterator()
            await socket.enqueue(detailed("Bounded onset and decay.", 0.04, 0.26))
            await socket.fail()
            let final = try await cursor.next()
            XCTAssertEqual(final?.text, "Bounded onset and decay.")
            let end = try await cursor.next()
            XCTAssertNil(end, strategy.rawValue)
            await provider.close()
        }
    }

    func testTwoFinalsDoNotConsumeInteriorGapEvenIfItFitsEdgeTolerance() async throws {
        let (provider, socket, stream) = try await connect(strategy: .semanticTurn)
        for offset in [0, 2_400, 4_800] { try await provider.append(audio(at: Int64(offset))) }
        try await provider.finishInput()
        var cursor = stream.makeAsyncIterator()
        await socket.enqueue(detailed("Leading", 0, 0.15))
        await socket.enqueue(detailed("Trailing", 0.19, 0.3))
        await socket.fail()
        for text in ["Leading", "Trailing"] {
            let final = try await cursor.next()
            XCTAssertEqual(final?.text, text)
        }
        do {
            _ = try await cursor.next()
            XCTFail("A word timing edge cannot erase the uncovered interior.")
        } catch { XCTAssertEqual(error as? ProviderFailure, .timeout) }
        await provider.close()
    }

    func testTinyOverlapCannotAcknowledgeNewerAudioOrItsCommit() async throws {
        let (provider, socket, stream) = try await connect(strategy: .manual)
        try await provider.append(audio(at: 0))
        try await provider.commit()
        try await provider.append(audio(at: 2_400, bytes: 960))
        try await provider.commit()
        try await provider.finishInput()
        var cursor = stream.makeAsyncIterator()
        await socket.enqueue(detailed("First", 0.01, 0.101))
        await socket.enqueue(detailed("Second", 0.102, 0.119))
        await socket.fail()

        let first = try await cursor.next()
        let second = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(first?.text, "First")
        XCTAssertEqual(second?.text, "Second")
        XCTAssertNil(end)
        await provider.close()
    }

    func testLaterManualResultLeavesMissingEarlierCommitPending() async throws {
        let (provider, socket, stream) = try await connect(strategy: .manual)
        for offset in [0, 2_400] {
            try await provider.append(audio(at: Int64(offset)))
            try await provider.commit()
        }
        try await provider.finishInput()
        await socket.enqueue(detailed("Later", 0.11, 0.19))
        await socket.fail()
        var cursor = stream.makeAsyncIterator()
        let final = try await cursor.next()
        XCTAssertEqual(final?.text, "Later")
        do {
            _ = try await cursor.next()
            XCTFail("The newer result cannot acknowledge the older commit")
        } catch { XCTAssertEqual(error as? ProviderFailure, .timeout) }
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

    func testGracefulDrainTracksQuietSpeechAtTheConfiguredSensitivity() async throws {
        let socket = ScriptedSocket()
        let provider = ElevenLabsTranscriber(apiKey: "synthetic",
            configuration: .init(strategy: .voiceActivity, localActivityThreshold: 0.005), socket: { _ in socket })
        await socket.enqueue(scribeReady)
        let stream = try await provider.connect(source: source, epoch: UUID())
        var cursor = stream.makeAsyncIterator()
        // 257/32768 is below the default threshold and above this session's threshold.
        try await provider.append(.init(source: source, sampleRate: 24_000, startSample: 0,
                                       pcm: Data(repeating: 1, count: 4_800)))
        try await provider.finishInput()
        let commits = try await commitFlags(socket)
        XCTAssertEqual(commits, [false, true])

        await socket.enqueue(detailed("Quiet speech", 0.02, 0.09))
        await socket.fail()
        let final = try await cursor.next()
        let end = try await cursor.next()
        XCTAssertEqual(final?.text, "Quiet speech")
        XCTAssertNil(end)
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

    private func connect(strategy: TranscriptionCommitStrategy = .semanticTurn, diarize: Bool = false) async throws
        -> (ElevenLabsTranscriber, ScriptedSocket, AsyncThrowingStream<TranscriptEvent, Error>) {
        let socket = ScriptedSocket()
        let provider = ElevenLabsTranscriber(apiKey: "fake", configuration: .init(strategy: strategy, diarize: diarize), socket: { _ in socket })
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
