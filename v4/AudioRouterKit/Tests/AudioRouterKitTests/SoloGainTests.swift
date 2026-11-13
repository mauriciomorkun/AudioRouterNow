//
//  SoloGainTests.swift
//  AudioRouterKitTests
//
//  P2 (v4.1): Tests fuer die reine Solo-Gain-Entscheidung SoloGain.effective.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import XCTest
@testable import AudioRouterKit

final class SoloGainTests: XCTestCase {

    private let a = "uidA:0"
    private let b = "uidB:0"
    private let c = "uidC:2"

    func testNoSoloReturnsStoredGainForEachKey() {
        let gains: [String: Double] = [a: 0.8, b: 0.3]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: [], deviceGains: gains), 0.8, accuracy: 1e-6)
        XCTAssertEqual(SoloGain.effective(key: b, soloedKeys: [], deviceGains: gains), 0.3, accuracy: 1e-6)
    }

    func testSingleSoloedKeyGetsStoredGainOthersZero() {
        let gains: [String: Double] = [a: 0.8, b: 0.3, c: 0.9]
        let solo: Set<String> = [a]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: solo, deviceGains: gains), 0.8, accuracy: 1e-6)
        XCTAssertEqual(SoloGain.effective(key: b, soloedKeys: solo, deviceGains: gains), 0.0, accuracy: 1e-6)
        XCTAssertEqual(SoloGain.effective(key: c, soloedKeys: solo, deviceGains: gains), 0.0, accuracy: 1e-6)
    }

    func testMultipleSoloedKeysAllGetStoredGainRestZero() {
        let gains: [String: Double] = [a: 0.8, b: 0.3, c: 0.9]
        let solo: Set<String> = [a, c]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: solo, deviceGains: gains), 0.8, accuracy: 1e-6)
        XCTAssertEqual(SoloGain.effective(key: c, soloedKeys: solo, deviceGains: gains), 0.9, accuracy: 1e-6)
        XCTAssertEqual(SoloGain.effective(key: b, soloedKeys: solo, deviceGains: gains), 0.0, accuracy: 1e-6)
    }

    func testSoloedKeyMissingFromDeviceGainsDefaultsToUnity() {
        // Key ist solo'ed, steht aber nicht in deviceGains → Unity 1.0.
        let solo: Set<String> = [a]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: solo, deviceGains: [:]), 1.0, accuracy: 1e-6)
    }

    func testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo() {
        // Kein Solo: leerer Key liefert Unity (Fallback-Default aus deviceGains[""]).
        XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [], deviceGains: [:]), 1.0, accuracy: 1e-6)
        // Solo aktiv, leerer Key NICHT in soloedKeys: stumm (kein Absturz erwartet).
        XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: ["x:0"], deviceGains: [:]), 0.0, accuracy: 1e-6)
        // Leerer Key solo'et: Unity-Default (nicht in deviceGains, daher 1.0).
        XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [""], deviceGains: [:]), 1.0, accuracy: 1e-6)
    }

    func testStoredHalfGainSoloedReturnsHalfNotUnity() {
        // deviceGains 0.5, Key solo'ed → 0.5 (nicht 1.0).
        let gains: [String: Double] = [a: 0.5]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: [a], deviceGains: gains), 0.5, accuracy: 1e-6)
    }

    func testStoredHalfGainNotSoloedWhileSoloActiveReturnsZero() {
        // deviceGains 0.5, Key NICHT solo'ed bei aktivem Solo → 0.0.
        let gains: [String: Double] = [a: 0.5, b: 0.7]
        XCTAssertEqual(SoloGain.effective(key: a, soloedKeys: [b], deviceGains: gains), 0.0, accuracy: 1e-6)
    }
}
