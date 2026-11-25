import XCTest
@testable import ConversationCore

final class AudioRouteTests: XCTestCase {
    func testExplicitRouteNeverFallsBackAndDefaultFollowsUID() throws {
        let devices: [AudioEndpointChoice] = [
            .init(id: "builtin", name: "Internal Speakers"),
            .init(id: "usb", name: "USB Interface"),
            .init(id: "multiple", name: "Multi-stream", canTap: false)
        ]
        XCTAssertEqual(try AudioRouteSelection.output(in: devices, selectedUID: "usb", defaultUID: "builtin").id, "usb")
        XCTAssertEqual(try AudioRouteSelection.output(in: devices, selectedUID: nil, defaultUID: "builtin").id, "builtin")
        XCTAssertEqual(try AudioRouteSelection.output(in: devices, selectedUID: nil, defaultUID: "usb").id, "usb")
        XCTAssertThrowsError(try AudioRouteSelection.output(in: devices, selectedUID: "missing", defaultUID: "builtin"))
        XCTAssertThrowsError(try AudioRouteSelection.output(in: devices, selectedUID: "multiple", defaultUID: "builtin"))
    }

    func testGroupBoundaryAndMicrophonePreferencesRoundTrip() throws {
        XCTAssertEqual(AudioRouteSelection.applicationMembers(in: ["app", "app.helper", "app1", "app1.helper"],
                                                               group: "app"), ["app", "app.helper"])
        var route = AudioRoutePreference(question: .sharedMicrophone, interviewerMicrophoneUID: "a",
                                         candidateMicrophoneUID: "b", candidateEnabled: true)
        XCTAssertNoThrow(try route.validateConcurrentMicrophones())
        let restored = try JSONDecoder().decode(AudioRoutePreference.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(restored, route)
        route.candidateMicrophoneUID = "a"
        XCTAssertThrowsError(try route.validateConcurrentMicrophones())
        route.candidateEnabled = false
        XCTAssertNoThrow(try route.validateConcurrentMicrophones())
    }
}
