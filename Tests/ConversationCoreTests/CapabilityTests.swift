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
