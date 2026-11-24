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
