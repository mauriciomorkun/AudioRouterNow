//
//  SRListenerTests.swift
//  AudioRouterKitTests
//
//  P3 (v4.1): Tests fuer die reine SR-Aenderungserkennung
//  DeviceLifecycleManager.srChangedSignificantly.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import XCTest
@testable import AudioRouterKit

final class SRListenerTests: XCTestCase {

    func testSameRateReturnsFalse() {
        XCTAssertFalse(DeviceLifecycleManager.srChangedSignificantly(
            newRate: 48000.0, baselineRate: 48000.0))
    }

    func testTinyChangeBelowToleranceReturnsFalse() {
        // < 0.5 Hz Abstand → keine echte Aenderung.
        XCTAssertFalse(DeviceLifecycleManager.srChangedSignificantly(
            newRate: 48000.3, baselineRate: 48000.0))
    }

    func testRealRateChangeReturnsTrue() {
        // 44100 vs 48000 → 3900 Hz, klar ueber Toleranz.
        XCTAssertTrue(DeviceLifecycleManager.srChangedSignificantly(
            newRate: 44100.0, baselineRate: 48000.0))
    }

    func testNilNewRateReturnsTrueConservative() {
        // Lesefehler → konservativ Restart.
        XCTAssertTrue(DeviceLifecycleManager.srChangedSignificantly(
            newRate: nil, baselineRate: 48000.0))
    }

    func testExactToleranceBoundaryReturnsFalse() {
        // Exakt 0.5 Hz → NICHT groesser als 0.5, also false.
        XCTAssertFalse(DeviceLifecycleManager.srChangedSignificantly(
            newRate: 48000.5, baselineRate: 48000.0))
    }

    func testJustAboveToleranceReturnsTrue() {
        // Knapp ueber 0.5 Hz → true.
        XCTAssertTrue(DeviceLifecycleManager.srChangedSignificantly(
            newRate: 48000.6, baselineRate: 48000.0))
    }
}
