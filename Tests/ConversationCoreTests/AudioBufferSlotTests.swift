import AudioBufferSlots
import XCTest

final class AudioBufferSlotTests: XCTestCase {
    func testFixedCapacityAndSlotReuse() throws {
        let slots = try XCTUnwrap(AudioBufferSlotsCreate(2))
        defer { AudioBufferSlotsDestroy(slots) }
        let first = AudioBufferSlotsAcquire(slots)
        let second = AudioBufferSlotsAcquire(slots)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(AudioBufferSlotsAcquire(slots), -1)
        AudioBufferSlotsRelease(slots, first)
        XCTAssertEqual(AudioBufferSlotsAcquire(slots), first)
        XCTAssertEqual(AudioBufferSlotsAcquire(slots), -1)
    }
}
