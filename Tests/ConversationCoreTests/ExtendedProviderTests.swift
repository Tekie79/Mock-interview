import Foundation
import XCTest
@testable import ConversationCore

final class ExtendedProviderTests: XCTestCase {
    func testDeepgramCombinesFinalSegmentsUntilEndpoint() throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        let epoch = UUID()
        var state = DeepgramTranscriptAssembler(source: source, epoch: epoch)
        let first = Data(#"{"type":"Results","start":0,"duration":1,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"Explain the design"}]}}"#.utf8)
        let second = Data(#"{"type":"Results","start":1,"duration":1,"is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"and how you tested it."}]}}"#.utf8)
        XCTAssertEqual(try state.receive(first)?.state, .partial)
        let result = try XCTUnwrap(state.receive(second))
        XCTAssertEqual(result.state, .final)
        XCTAssertEqual(result.text, "Explain the design and how you tested it.")
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.epoch, epoch)
        XCTAssertNil(try state.receive(second))
        XCTAssertNil(try state.receive(first))
    }

    func testDeepgramRequestNegotiatesRawPCM() throws {
        let request = try DeepgramTranscriber.request(apiKey: "synthetic", model: "nova-3", language: "en")
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token synthetic")
        XCTAssertTrue(request.url?.query?.contains("encoding=linear16") == true)
        XCTAssertTrue(request.url?.query?.contains("sample_rate=24000") == true)
    }

    func testAnthropicDecodesTextStopAndReportedUsage() throws {
        let state = AnthropicStreamDecoder()
        _ = try state.receive(#"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#)
        if case .text(let delta) = try state.receive(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Example."}}"#) {
            XCTAssertEqual(delta, "Example.")
        } else {
            XCTFail("Expected text delta")
        }
        _ = try state.receive(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#)
        if case .complete(let usage) = try state.receive(#"{"type":"message_stop"}"#) {
            XCTAssertEqual(usage, TokenUsage(input: 25, output: 3))
        } else {
            XCTFail("Expected completion")
        }
        XCTAssertThrowsError(try state.receive(#"{"type":"error","error":{"message":"synthetic"}}"#))
    }
}
