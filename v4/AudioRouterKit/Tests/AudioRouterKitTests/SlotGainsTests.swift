import XCTest
@testable import AudioRouterKit

final class SlotGainsTests: XCTestCase {

    func testInitialGainIsUnity() {
        let sg = SlotGains()
        for i in 0..<SlotGains.maxSlots {
            XCTAssertEqual(sg.gain(slotIndex: i), 1.0, "Slot \(i) soll 1.0 sein")
        }
    }

    func testSetAndGetRoundtrip() {
        let sg = SlotGains()
        sg.set(0.5, slotIndex: 2)
        XCTAssertEqual(sg.gain(slotIndex: 2), 0.5, accuracy: 0.0001)
    }

    func testClampAboveOne() {
        let sg = SlotGains()
        sg.set(1.5, slotIndex: 0)
        XCTAssertEqual(sg.gain(slotIndex: 0), 1.0)
    }

    func testClampBelowZero() {
        let sg = SlotGains()
        sg.set(-0.3, slotIndex: 0)
        XCTAssertEqual(sg.gain(slotIndex: 0), 0.0)
    }

    func testOutOfRangeReadReturnsUnity() {
        let sg = SlotGains()
        XCTAssertEqual(sg.gain(slotIndex: -1), 1.0)
        XCTAssertEqual(sg.gain(slotIndex: SlotGains.maxSlots), 1.0)
    }

    func testOutOfRangeWriteIsNoOp() {
        let sg = SlotGains()
        sg.set(0.0, slotIndex: -1)   // soll nicht crashen
        sg.set(0.0, slotIndex: SlotGains.maxSlots)
        // Alle internen Slots unverändert
        for i in 0..<SlotGains.maxSlots {
            XCTAssertEqual(sg.gain(slotIndex: i), 1.0)
        }
    }

    func testSetAllPartial() {
        let sg = SlotGains()
        sg.setAll([0.1, 0.2, 0.3])
        XCTAssertEqual(sg.gain(slotIndex: 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 2), 0.3, accuracy: 0.0001)
        // Rest soll Unity sein
        for i in 3..<SlotGains.maxSlots {
            XCTAssertEqual(sg.gain(slotIndex: i), 1.0, "Slot \(i) soll 1.0 sein")
        }
    }

    func testReset() {
        let sg = SlotGains()
        sg.setAll(Array(repeating: 0.5, count: SlotGains.maxSlots))
        sg.reset()
        for i in 0..<SlotGains.maxSlots {
            XCTAssertEqual(sg.gain(slotIndex: i), 1.0)
        }
    }
}
