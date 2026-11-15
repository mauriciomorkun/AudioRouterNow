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

    // MARK: - Neue Tests NT-S3: Kapazität 256

    func testSlotsBeyondFormerLimitAreWritableAndReadable() {
        let sg = SlotGains()
        for idx in [15, 16, 17, 31, 32, 33, 100, 255] {
            sg.set(0.5, slotIndex: idx)
            XCTAssertEqual(sg.gain(slotIndex: idx), 0.5, accuracy: 0.0001, "Slot \(idx) muss schreibbar und lesbar sein")
        }
    }

    func testLastValidSlotAndFirstInvalidSlot() {
        let sg = SlotGains()
        let last = SlotGains.maxSlots - 1  // 255
        sg.set(0.3, slotIndex: last)
        XCTAssertEqual(sg.gain(slotIndex: last), 0.3, accuracy: 0.0001)
        // Index maxSlots (256) ist ungültig
        sg.set(0.7, slotIndex: SlotGains.maxSlots)  // No-Op
        XCTAssertEqual(sg.gain(slotIndex: SlotGains.maxSlots), 1.0)
        // Nachbarslot unverändert
        XCTAssertEqual(sg.gain(slotIndex: last), 0.3, accuracy: 0.0001)
    }

    func testSetAllBeyondSixteenSeedsEverySlot() {
        let sg = SlotGains()
        var gains = [Float32](repeating: 0.0, count: 100)
        for i in 0..<100 { gains[i] = Float32(i) / 100.0 }
        sg.setAll(gains)
        XCTAssertEqual(sg.gain(slotIndex: 0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 15), 0.15, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 16), 0.16, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 17), 0.17, accuracy: 0.0001)
        XCTAssertEqual(sg.gain(slotIndex: 99), 0.99, accuracy: 0.0001)
        // Slots jenseits der 100 Werte: Unity
        XCTAssertEqual(sg.gain(slotIndex: 100), 1.0)
        XCTAssertEqual(sg.gain(slotIndex: 255), 1.0)
    }

    func testSetAllWithMoreThanCapacityIgnoresExcess() {
        let sg = SlotGains()
        // 300 Werte, nur die ersten 256 passen in die Kapazität
        var gains = [Float32](repeating: 0.5, count: 300)
        for i in 0..<256 { gains[i] = Float32(i) / 256.0 }
        sg.setAll(gains)  // darf nicht crashen
        // Slot 255 (letzter gültiger) trägt den Wert aus Index 255
        XCTAssertEqual(sg.gain(slotIndex: 255), Float32(255) / 256.0, accuracy: 0.001)
        // Kein Zugriff über die Kapazität (kein Absturz genügt)
        XCTAssertEqual(sg.gain(slotIndex: 256), 1.0)
    }

    func testSetAllClampsValuesAboveSixteen() {
        let sg = SlotGains()
        var gains = [Float32](repeating: 0.5, count: 50)
        gains[40] = -1.0
        gains[41] = 2.0
        sg.setAll(gains)
        XCTAssertEqual(sg.gain(slotIndex: 40), 0.0)
        XCTAssertEqual(sg.gain(slotIndex: 41), 1.0)
    }

    func testResetCoversWholeCapacity() {
        let sg = SlotGains()
        sg.setAll(Array(repeating: 0.3, count: 256))
        sg.reset()
        for i in [0, 15, 16, 17, 100, 255] {
            XCTAssertEqual(sg.gain(slotIndex: i), 1.0, "Slot \(i) nach reset muss 1.0 sein")
        }
    }

    func testBridgesShareTheSingleCapacitySource() {
        XCTAssertEqual(SlotGains.maxSlots, OutputLimits.maxSlots)
        XCTAssertEqual(PeakMeters.maxSlots, OutputLimits.maxSlots)
    }
}
