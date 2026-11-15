//
//  PeakMetersTests.swift
//  AudioRouterKitTests
//
//  Prüft PeakMeters-Kapazität 256 (NT-S3).
//

import XCTest
@testable import AudioRouterKit

final class PeakMetersTests: XCTestCase {

    func testRecordAndReadBeyondSixteen() {
        let pm = PeakMeters()
        pm.record(l: 0.5, r: 0.25, slotCount: 100)
        XCTAssertEqual(pm.level(slotIndex: 0).l, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 0).r, 0.25, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 16).l, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 16).r, 0.25, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 99).l, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 99).r, 0.25, accuracy: 0.0001)
        // Slot 100 liegt außerhalb slotCount: (0, 0)
        XCTAssertEqual(pm.level(slotIndex: 100).l, 0.0)
        XCTAssertEqual(pm.level(slotIndex: 100).r, 0.0)
    }

    func testRecordAtFullCapacity() {
        let pm = PeakMeters()
        pm.record(l: 0.8, r: 0.6, slotCount: 256)
        XCTAssertEqual(pm.level(slotIndex: 255).l, 0.8, accuracy: 0.0001)
        XCTAssertEqual(pm.level(slotIndex: 255).r, 0.6, accuracy: 0.0001)
    }

    func testRecordClampsAboveCapacity() {
        let pm = PeakMeters()
        pm.record(l: 0.9, r: 0.7, slotCount: 300)  // darf nicht crashen
        // Slot 256 ist außerhalb der Kapazität
        XCTAssertEqual(pm.level(slotIndex: 256).l, 0.0)
        XCTAssertEqual(pm.level(slotIndex: 300).l, 0.0)
    }

    func testLevelOutOfRange() {
        let pm = PeakMeters()
        pm.record(l: 1.0, r: 1.0, slotCount: 10)
        let neg = pm.level(slotIndex: -1)
        XCTAssertEqual(neg.l, 0.0)
        XCTAssertEqual(neg.r, 0.0)
    }

    func testRecordZeroesSlotsAboveCount() {
        let pm = PeakMeters()
        pm.record(l: 0.9, r: 0.9, slotCount: 200)
        pm.record(l: 0.5, r: 0.5, slotCount: 3)
        // Slots 3 bis 199 wurden genullt
        XCTAssertEqual(pm.level(slotIndex: 3).l, 0.0)
        XCTAssertEqual(pm.level(slotIndex: 150).l, 0.0)
    }

    func testResetClearsAll() {
        let pm = PeakMeters()
        pm.record(l: 1.0, r: 1.0, slotCount: 256)
        pm.reset()
        XCTAssertEqual(pm.level(slotIndex: 0).l, 0.0)
        XCTAssertEqual(pm.level(slotIndex: 255).l, 0.0)
    }
}
