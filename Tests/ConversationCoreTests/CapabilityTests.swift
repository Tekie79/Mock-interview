import XCTest
@testable import ConversationCore

final class CapabilityTests: XCTestCase {
    func testModelSpecificAndBillingBoundaries() {
        XCTAssertTrue(ProviderCapabilities.describe(.elevenLabs, model: "scribe_v3_live").commits.contains(.semanticTurn))
        XCTAssertFalse(ProviderCapabilities.describe(.elevenLabs, model: "scribe_v2_realtime").commits.contains(.semanticTurn))
        XCTAssertFalse(ProviderCapabilities.describe(.appleSpeech).supports(.answer))
        XCTAssertFalse(ProviderCapabilities.describe(.anthropic).supports(.transcription))
        XCTAssertEqual(ProviderCapabilities.describe(.openai).billing, .separatelyBilledAPI)
        XCTAssertEqual(ProviderCapabilities.describe(.chatGPTSubscription).billing, .chatGPTPlan)
        for service in ProviderService.allCases {
            XCTAssertFalse(ProviderCapabilities.describe(.chatGPTSubscription).supports(service))
        }
    }

    func testRealtimeCapabilitiesReflectModelSpecificWireSupport() {
        let live = ProviderCapabilities.describe(.openai, model: "gpt-live-transcribe")
        XCTAssertEqual(live.services, [.transcription])
        XCTAssertEqual(live.commits, [.manual])
        XCTAssertTrue(live.vocabularyHints)
        XCTAssertTrue(ProviderCapabilities.describe(.openai, model: "gpt-transcribe").detectsLanguage)
        XCTAssertFalse(ProviderCapabilities.describe(.openai, model: "gpt-realtime-whisper").vocabularyHints)
        XCTAssertFalse(ProviderCapabilities.describe(.openai, model: "gpt-4.1-mini").supports(.transcription))
        XCTAssertEqual(ProviderCapabilities.describe(.openai, model: "text-embedding-3-small").services, [.embeddings])

        let nova = ProviderCapabilities.describe(.deepgram, model: "nova-3-general")
        XCTAssertTrue(nova.diarization)
        XCTAssertTrue(nova.detectsLanguage)
        XCTAssertFalse(ProviderCapabilities.describe(.deepgram, model: "base").detectsLanguage)
        XCTAssertFalse(ProviderCapabilities.describe(.deepgram, model: "flux-general-en").supports(.transcription))
    }
}

extension CapabilityTests {
    func testStrictAppleRecognitionRejectsNetworkFallbackAndUnsupportedLocale() {
        XCTAssertNoThrow(try AppleRecognitionPolicy.validate(language: "en-US", supported: ["en_US"],
                                                             mode: .onDevice, onDeviceAvailable: true))
        XCTAssertThrowsError(try AppleRecognitionPolicy.validate(language: "en-US", supported: ["en_US"],
                                                                 mode: .onDevice, onDeviceAvailable: false)) {
            XCTAssertEqual($0 as? AppleRecognitionFailure, .onDeviceUnavailable)
        }
        XCTAssertNoThrow(try AppleRecognitionPolicy.validate(language: "en-US", supported: ["en_US"],
                                                              mode: .networkPermitted, onDeviceAvailable: false))
        XCTAssertThrowsError(try AppleRecognitionPolicy.validate(language: "zz", supported: ["en_US"],
                                                                 mode: .networkPermitted, onDeviceAvailable: true)) {
            XCTAssertEqual($0 as? AppleRecognitionFailure, .unsupportedLanguage)
        }
    }

    #if os(macOS)
    func testNativeLanguageDiscoveryDoesNotRequireRecordingPermission() {
        let languages = AppleSpeechTranscriber.languages()
        XCTAssertEqual(languages, languages.sorted())
        XCTAssertEqual(languages.count, Set(languages).count)
    }
    #endif
}

extension CapabilityTests {
    func testTextModelChoicesRespectProviderAndService() {
        XCTAssertTrue(ProviderCapabilities.textModels(.openai).contains("gpt-6-luna"))
        XCTAssertTrue(ProviderCapabilities.textModels(.anthropic).contains("claude-sonnet-4-6"))
        XCTAssertTrue(ProviderCapabilities.textModels(.chatGPTSubscription).isEmpty)
        XCTAssertEqual(ProviderCapabilities.reasoningEfforts(.openai, model: "gpt-6-luna", service: .classification), [.none, .low])
        XCTAssertFalse(ProviderCapabilities.reasoningEfforts(.openai, model: "gpt-6.2-sol", service: .answer).contains(.none))
        XCTAssertFalse(ProviderCapabilities.reasoningEfforts(.anthropic, model: "claude-sonnet-4-6", service: .answer).contains(.xhigh))
        XCTAssertEqual(ProviderCapabilities.effectiveReasoning(.low, provider: .openai, model: "custom-snapshot", service: .answer), .modelDefault)
    }

    func testPresetsRoundTripAndUnsupportedServicesNeverSubstituteOtherProviders() throws {
        let defaults = ProviderPreset.defaults()
        let roundTrip = try JSONDecoder().decode([ProviderPreset].self, from: JSONEncoder().encode(defaults))
        XCTAssertEqual(roundTrip, defaults)
        XCTAssertNil(roundTrip.first?.classificationReasoning)
        XCTAssertNil(roundTrip.first?.answerReasoning)
        let blocked = try XCTUnwrap(roundTrip.first)
        XCTAssertEqual(blocked.classifier, .chatGPTSubscription)
        XCTAssertNotNil(blocked.unavailableReason)
        let hybrid = try XCTUnwrap(roundTrip.first { $0.name == "Hybrid" })
        let duplicate = hybrid.copy(named: "Independent")
        XCTAssertNotEqual(duplicate.id, hybrid.id)
        XCTAssertEqual(duplicate.transcription, .elevenLabs)
        XCTAssertEqual(duplicate.answer, .openai)
        XCTAssertNil(duplicate.unavailableReason)
        var invalid = duplicate
        invalid.answer = .deepgram
        XCTAssertNotNil(invalid.unavailableReason)

        var reasoning = duplicate
        reasoning.classificationModel = "gpt-6-luna"
        reasoning.classificationReasoning = ReasoningEffort.none
        reasoning.answerModel = "gpt-6.2-sol"
        reasoning.answerReasoning = .high
        let restored = try JSONDecoder().decode(ProviderPreset.self, from: JSONEncoder().encode(reasoning))
        XCTAssertEqual(restored, reasoning)
    }
}

extension CapabilityTests {
    func testMissingSettingsMayDefaultAndInvalidExplicitProviderFailsClosed() throws {
        XCTAssertEqual(try ProviderSelection.decode(nil, default: ProviderID.openai), .openai)
        XCTAssertEqual(try ProviderSelection.decode("chatGPTSubscription", default: ProviderID.openai), .chatGPTSubscription)
        XCTAssertThrowsError(try ProviderSelection.decode("ChatGPT subscription", default: ProviderID.openai)) {
            XCTAssertEqual($0 as? ProviderFailure, .unsupportedCapability)
        }
    }
}

#if os(macOS) && compiler(>=6.2)
extension CapabilityTests {
    func testSpeechAnalyzerDoesNotUseAnUnavailableLocale() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let unsupported = await MacSpeechAnalyzerTranscriber.installedLocale(for: "und-ZZ")
        XCTAssertNil(unsupported)
    }
}
#endif
