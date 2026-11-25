import Foundation
import XCTest
@testable import ConversationCore

final class RealtimeTests: XCTestCase {
    func testSyntheticCommittedChainReordersFinalsAndDropsDuplicates() throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        let epoch = UUID()
        var assembler = OpenAITranscriptAssembler(source: source, epoch: epoch)
        let commit1 = Data(#"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#.utf8)
        let commit2 = Data(#"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#.utf8)
        let partial = Data(#"{"type":"conversation.item.input_audio_transcription.delta","event_id":"d1","item_id":"one","delta":"What"}"#.utf8)
        let final1 = Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"What are queues?"}"#.utf8)
        let final2 = Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"What is backpressure?"}"#.utf8)
        XCTAssertTrue(try assembler.receive(commit1).isEmpty)
        XCTAssertTrue(try assembler.receive(commit2).isEmpty)
        XCTAssertEqual(try assembler.receive(partial).map(\.state), [.partial])
        XCTAssertTrue(try assembler.receive(partial).isEmpty)
        XCTAssertTrue(try assembler.receive(final2).isEmpty)
        let ordered = try assembler.receive(final1)
        XCTAssertEqual(ordered.map(\.itemID), ["one", "two"])
        XCTAssertEqual(ordered.map(\.text), ["What are queues?", "What is backpressure?"])
        XCTAssertTrue(ordered.allSatisfy { $0.epoch == epoch && $0.source == source })
        XCTAssertTrue(try assembler.receive(final1).isEmpty)
    }

    func testSessionPayloadDisablesServerVAD() throws {
        let bytes = Data(try OpenAIRealtimeWire.session(model: "gpt-live-transcribe", language: "en").utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    }
}

extension RealtimeTests {
    func testSessionReadyOnlyAfterUpdateAcknowledgment() async throws {
        let socket = ScriptedSocket()
        let source = CaptureSource(id: "source", role: .interviewer)
        let provider = OpenAIRealtimeTranscriber(apiKey: "synthetic", model: "gpt-live-transcribe",
                                                 socket: { _ in UnresponsivePingSocket(base: socket) })
        await socket.enqueue(#"{"type":"session.created"}"#)
        await socket.enqueue(#"{"type":"session.updated","session":{"type":"transcription"}}"#)
        let stream = try await provider.connect(source: source, epoch: UUID())
        try await provider.append(.init(source: source, sampleRate: 24_000, startSample: 0, pcm: Data([0, 0])))
        try await provider.commit()
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent.first?.contains("session.update") == true)
        XCTAssertEqual(sent.last, OpenAIRealtimeWire.commit)
        do {
            try await provider.checkConnection()
            XCTFail("Expected the socket ping failure")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .timeout)
        }
        _ = stream
        await provider.close()
    }

    func testRejectsNonTranscriptionSessionAcknowledgment() async throws {
        let socket = ScriptedSocket()
        await socket.enqueue(#"{"type":"session.updated","session":{"type":"realtime"}}"#)
        await socket.fail()
        let provider = OpenAIRealtimeTranscriber(apiKey: "synthetic", model: "gpt-live-transcribe", socket: { _ in socket })
        do {
            _ = try await provider.connect(source: .init(id: "source", role: .interviewer), epoch: UUID())
            XCTFail("Expected the non-transcription acknowledgment to be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .malformedEvent)
        }
    }

    func testModelSpecificLanguageAndVocabularyFields() throws {
        func transcription(model: String, language: String?) throws -> [String: Any] {
            let wire = try OpenAIRealtimeWire.session(model: model, language: language,
                                                      vocabulary: [" Swift ", "\nnew line", "<markup>", " ", "C++"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
            let session = json["session"] as? [String: Any]
            let audio = session?["audio"] as? [String: Any]
            let input = audio?["input"] as? [String: Any]
            return try XCTUnwrap(input?["transcription"] as? [String: Any])
        }

        let live = try transcription(model: "gpt-live-transcribe", language: " ZH-TW ")
        XCTAssertEqual(live["languages"] as? [String], ["zh-tw"])
        XCTAssertEqual(live["keywords"] as? [String], ["Swift", "C++"])
        XCTAssertEqual(live["delay"] as? String, "low")
        XCTAssertNil(live["language"])
        XCTAssertNil(live["prompt"])
        let automatic = try transcription(model: "gpt-transcribe", language: nil)
        XCTAssertNil(automatic["languages"])
        XCTAssertNil(automatic["delay"])
        let prompted = try transcription(model: "gpt-4o-transcribe", language: "en")
        XCTAssertEqual(prompted["language"] as? String, "en")
        XCTAssertEqual(prompted["prompt"] as? String, "Swift, C++")
        XCTAssertNil(prompted["keywords"])
        XCTAssertNil(prompted["languages"])
        XCTAssertThrowsError(try transcription(model: "gpt-4o-transcribe", language: "en-US")) {
            XCTAssertEqual($0 as? ProviderFailure, .unsupportedCapability)
        }
    }

    func testNormalizesFinalLanguageAndBothUsageShapesOnlyForTheAudioPart() throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        var assembler = OpenAITranscriptAssembler(source: source, epoch: UUID())
        let commits = [
            #"{"type":"input_audio_buffer.committed","item_id":"one"}"#,
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#,
            #"{"type":"input_audio_buffer.committed","item_id":"three","previous_item_id":"two"}"#
        ]
        for commit in commits { XCTAssertTrue(try assembler.receive(Data(commit.utf8)).isEmpty) }
        let otherPart = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","content_index":1,"transcript":"Wrong part"}"#
        XCTAssertTrue(try assembler.receive(Data(otherPart.utf8)).isEmpty)
        let partialWire = #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","content_index":0,"delta":"Hello"}"#
        let partial = try XCTUnwrap(assembler.receive(Data(partialWire.utf8)).first)
        XCTAssertNil(partial.recognitionUsage)
        let duration = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","content_index":0,"transcript":"Hello.","languages":[{"code":"en"}],"usage":{"type":"duration","seconds":1.5}}"#
        let tokens = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","content_index":0,"transcript":"Next.","languages":[{"code":"en"},{"code":"es"}],"usage":{"type":"tokens","input_tokens":10,"output_tokens":2}}"#
        let invalid = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"three","content_index":0,"transcript":"Last.","usage":{"type":"duration","seconds":-1}}"#
        let first = try XCTUnwrap(assembler.receive(Data(duration.utf8)).first)
        XCTAssertEqual(first.state, .final)
        XCTAssertEqual(first.language, "en")
        XCTAssertEqual(first.recognitionUsage, .audioSeconds(1.5))
        let second = try XCTUnwrap(assembler.receive(Data(tokens.utf8)).first)
        XCTAssertNil(second.language)
        XCTAssertEqual(second.recognitionUsage, .tokens(.init(input: 10, output: 2)))
        XCTAssertNil(try XCTUnwrap(assembler.receive(Data(invalid.utf8)).first).recognitionUsage)
    }
}

private struct UnresponsivePingSocket: RealtimeSocket {
    let base: ScriptedSocket
    func read() async throws -> Data { try await base.read() }
    func send(_ text: String) async throws { await base.send(text) }
    func ping() async throws { throw ProviderFailure.timeout }
    func close() { base.close() }
}
