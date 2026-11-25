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
