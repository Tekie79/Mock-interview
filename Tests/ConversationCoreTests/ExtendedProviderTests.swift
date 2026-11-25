import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ConversationCore

final class ExtendedProviderTests: XCTestCase {
    func testDeepgramCombinesFinalSegmentsUntilEndpoint() throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        let epoch = UUID()
        var state = DeepgramTranscriptAssembler(source: source, epoch: epoch)
        let first = Data(#"{"type":"Results","start":0,"duration":1,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"Explain the design","languages":["en"]}]}}"#.utf8)
        let second = Data(#"{"type":"Results","start":1,"duration":1,"is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"and how you tested it.","languages":["en"]}]}}"#.utf8)
        let partial = try XCTUnwrap(state.receive(first))
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.language, "en")
        let result = try XCTUnwrap(state.receive(second))
        XCTAssertEqual(result.state, .final)
        XCTAssertEqual(result.text, "Explain the design and how you tested it.")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.epoch, epoch)
        XCTAssertNil(try state.receive(second))
        XCTAssertNil(try state.receive(first))
    }

    func testDeepgramRequestNegotiatesRawPCM() throws {
        let request = try DeepgramTranscriber.request(apiKey: "synthetic", model: "nova-3", language: " multi ",
                                                      vocabulary: ["  ", " C++ "])
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token synthetic")
        let url = try XCTUnwrap(request.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(.init(name: "encoding", value: "linear16")))
        XCTAssertTrue(items.contains(.init(name: "sample_rate", value: "24000")))
        XCTAssertTrue(items.contains(.init(name: "language", value: "multi")))
        XCTAssertTrue(items.contains(.init(name: "redact_usage", value: "true")))
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.compactMap(\.value), ["C++"])
        XCTAssertTrue(url.absoluteString.contains("keyterm=C%2B%2B"))
        XCTAssertThrowsError(try DeepgramTranscriber.request(apiKey: "synthetic", model: "base", language: "multi")) {
            XCTAssertEqual($0 as? ProviderFailure, .unsupportedCapability)
        }
    }

    func testDeepgramManualFinalizationDoesNotAssignAMixedLanguage() throws {
        var state = DeepgramTranscriptAssembler(source: .init(id: "source", role: .interviewer), epoch: UUID())
        let first = Data(#"{"type":"Results","start":0,"duration":1,"is_final":true,"channel":{"alternatives":[{"transcript":"Hello","languages":["en"]}]}}"#.utf8)
        let second = Data(#"{"type":"Results","start":1,"duration":1,"is_final":true,"from_finalize":true,"channel":{"alternatives":[{"transcript":"buenas tardes","languages":["es"]}]}}"#.utf8)
        XCTAssertEqual(try state.receive(first)?.state, .partial)
        let result = try XCTUnwrap(state.receive(second))
        XCTAssertEqual(result.state, .final)
        XCTAssertEqual(result.text, "Hello buenas tardes")
        XCTAssertNil(result.language)
        XCTAssertNil(state.drain())
    }

    func testDeepgramHeartbeatRequiresAnActiveSocket() async {
        let provider: any StreamingSTT = DeepgramTranscriber(apiKey: "synthetic")
        do {
            try await provider.checkConnection()
            XCTFail("Expected the disconnected provider to fail the heartbeat")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .disconnected)
        }
    }

    func testAnthropicDecodesTextStopAndReportedUsage() throws {
        let state = AnthropicStreamDecoder()
        _ = try state.receive(#"{"type":"message_start","message":{"usage":{"input_tokens":25,"cache_creation_input_tokens":7,"cache_read_input_tokens":11,"output_tokens":1}}}"#)
        if case .text(let delta) = try state.receive(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Example."}}"#) {
            XCTAssertEqual(delta, "Example.")
        } else {
            XCTFail("Expected text delta")
        }
        _ = try state.receive(#"{"type":"message_delta","usage":{"output_tokens":2}}"#)
        _ = try state.receive(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#)
        if case .complete(let usage) = try state.receive(#"{"type":"message_stop"}"#) {
            XCTAssertEqual(usage, TokenUsage(input: 43, output: 3))
        } else {
            XCTFail("Expected completion")
        }
    }

    func testAnthropicMapsTypedStreamErrorsWithoutExposingProviderMessages() {
        let cases: [(String, ProviderFailure)] = [
            ("authentication_error", .authentication), ("billing_error", .quotaExhausted),
            ("rate_limit_error", .rateLimited), ("timeout_error", .timeout),
            ("permission_error", .requestRejected), ("overloaded_error", .unavailable),
            ("unknown_error", .unavailable)
        ]
        for (type, expected) in cases {
            let wire = #"{"type":"error","error":{"type":"\#(type)","message":"synthetic details"}}"#
            XCTAssertThrowsError(try AnthropicStreamDecoder().receive(wire), type) {
                XCTAssertEqual($0 as? ProviderFailure, expected)
            }
        }
        XCTAssertThrowsError(try AnthropicStreamDecoder().receive(#"{"type":"error","error":{"message":"missing type"}}"#)) {
            XCTAssertEqual($0 as? ProviderFailure, .malformedEvent)
        }
    }

    func testAnthropicMapsProviderSpecificHTTPFailures() throws {
        let url = try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages"))
        let cases: [(Int, ProviderFailure)] = [(401, .authentication), (402, .quotaExhausted),
                                              (403, .requestRejected), (429, .rateLimited), (504, .timeout)]
        for (status, expected) in cases {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            XCTAssertThrowsError(try AnthropicMessagesClient.validate(response)) {
                XCTAssertEqual($0 as? ProviderFailure, expected)
            }
        }
    }

    func testAnthropicRejectsIncompleteOrRefusedMessages() throws {
        for stop in ["max_tokens", "refusal"] {
            let wire = #"{"stop_reason":"\#(stop)","content":[{"type":"text","text":"{}"}]}"#
            XCTAssertThrowsError(try AnthropicQuestionClassifier.decode(Data(wire.utf8))) {
                XCTAssertEqual($0 as? ProviderFailure, .requestRejected)
            }
        }
        let state = AnthropicStreamDecoder()
        _ = try state.receive(#"{"type":"message_start","message":{}}"#)
        _ = try state.receive(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        XCTAssertThrowsError(try state.receive(#"{"type":"message_stop"}"#)) {
            XCTAssertEqual($0 as? ProviderFailure, .requestRejected)
        }
    }
}

extension ExtendedProviderTests {
    func testDeepgramSummaryFlushesOnlyProviderFinalizedWords() throws {
        var result = DeepgramTranscriptAssembler(source: .init(id: "source", role: .unknown), epoch: UUID())
        let wire = Data(#"{"type":"Results","start":0,"duration":1.5,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"What's the tradeoff?","languages":["en"],"words":[{"word":"tradeoff","start":1.0,"end":1.4,"speaker":2}]}]}}"#.utf8)
        XCTAssertEqual(try result.receive(wire)?.state, .partial)
        let interim = Data(#"{"type":"Results","start":1.5,"duration":0.2,"is_final":false,"speech_final":true,"channel":{"alternatives":[{"transcript":"Unconfirmed tail","languages":["en","es"]}]}}"#.utf8)
        let partial = try XCTUnwrap(result.receive(interim))
        XCTAssertEqual(partial.state, .partial)
        XCTAssertTrue(partial.text.hasSuffix("Unconfirmed tail"))
        XCTAssertNil(partial.language)
        XCTAssertFalse(DeepgramTranscriptAssembler.isStreamSummary(interim))
        XCTAssertTrue(DeepgramTranscriptAssembler.isStreamSummary(Data(#"{"type":"Metadata","duration":1.7}"#.utf8)))
        let final = try XCTUnwrap(result.drain())
        XCTAssertEqual(final.state, .final)
        XCTAssertEqual(final.text, "What's the tradeoff?")
        XCTAssertEqual(final.speaker, 2)
        XCTAssertEqual(final.language, "en")
        XCTAssertEqual(final.words.first?.endSeconds, 1.4)
        XCTAssertNil(result.drain())
    }

    func testDeepgramEmptyFinalCarriesNoSpeechRangeButSummaryDoesNot() throws {
        var state = DeepgramTranscriptAssembler(source: .init(id: "source", role: .interviewer), epoch: UUID())
        let summary = Data(#"{"type":"Metadata","duration":2.5}"#.utf8)
        XCTAssertNil(try state.receive(summary))
        let empty = Data(#"{"type":"Results","start":1.5,"duration":1.0,"is_final":true,"from_finalize":true,"channel":{"alternatives":[{"transcript":"","words":[]}]}}"#.utf8)
        let final = try XCTUnwrap(state.receive(empty))
        XCTAssertEqual(final.state, .final)
        XCTAssertEqual(final.text, "")
        XCTAssertEqual(final.audioRange, .init(startSeconds: 1.5, endSeconds: 2.5))
    }
}
