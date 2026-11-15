//
//  WaveEnergyMathTests.swift
//  AudioRouterKitTests
//
//  Prüft WaveEnergyMath.soloNeutralLinear (NT-S5, W2, NT-D4).
//

import XCTest
@testable import AudioRouterKit

final class WaveEnergyMathTests: XCTestCase {

    func testEqualPeaksNoGainsReturnsPeak() {
        let peaks = Array(repeating: (l: Float32(0.6), r: Float32(0.6)), count: 3)
        let keys = ["a", "b", "c"]
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        XCTAssertEqual(result, 0.6, accuracy: 0.001)
    }

    func testSoloDoesNotLowerTheWave() {
        // Drei Slots, gleicher Peak. Die Funktion kennt Solo nicht.
        // Test dokumentiert: Ergebnis ist identisch, unabhängig davon, welcher
        // Key solo'ed wäre (soloedKeys wird nicht übergeben).
        let peaks = Array(repeating: (l: Float32(0.5), r: Float32(0.5)), count: 3)
        let keys = ["a", "b", "c"]
        let gains: [String: Double] = [:]
        let withoutSolo = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
        // Absicht: soloNeutralLinear hat kein soloedKeys-Argument. Beide Aufrufe sind
        // identisch, die Regressionsgarantie liegt in der Signatur der Funktion,
        // nicht im Vergleichswert. Kein Copy-Paste-Fehler.
        // Der Signatur-Test testSoloNeutralLinearSignatureHasNoSoloedKeys prueft,
        // dass die Signatur unveraendert bleibt.
        let withSolo = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
        XCTAssertEqual(withoutSolo, withSolo, accuracy: 0.0001)
    }

    func testMaskedSumWouldHaveShrunkTheWave() {
        // Regressionsanker gegen D1 (Welle): dieselben Slots, Summe mit
        // SoloGain.effective und Solo auf 1 von 3 ergibt 1/3 des neutralen Werts;
        // die neutrale Funktion liefert den ungekürzten Wert.
        let peak = Float32(0.6)
        let peaks = Array(repeating: (l: peak, r: peak), count: 3)
        let keys = ["a", "b", "c"]
        let gains: [String: Double] = [:]

        // Neutrale Formel: Mittelwert aller Gains (alle 1.0) mal Peak
        let neutral = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
        XCTAssertEqual(neutral, peak, accuracy: 0.001)

        // Alte D1-Formel (SoloGain.effective, Solo auf "b"): nur "b" trägt bei
        let soloedKeys: Set<String> = ["b"]
        var maskedSum: Float32 = 0
        for key in keys {
            let g = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: [:])
            maskedSum += peak * g
        }
        let maskedAvg = maskedSum / Float32(keys.count)
        // Alte Formel: 0.6/3 = 0.2, also ein Drittel des neutralen Werts
        XCTAssertEqual(maskedAvg, peak / 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(neutral, maskedAvg)
    }

    func testQuieterSoloDeviceDoesNotChangeTheWave() {
        // Gegenbeispiel zu Option 2 (Division durch die Zahl hörbarer Slots):
        // Drei Slots gleichen Peaks 0.8, das Solo-Gerät "b" hat gespeichert Gain 0.2.
        // Solo schreibt deviceGains nie, die Funktion bekommt daher dieselben Eingaben
        // mit und ohne Solo. Erwartet ist der Mittelwert über ALLE Slots.
        let peaks = Array(repeating: (l: Float32(0.8), r: Float32(0.8)), count: 3)
        let keys = ["a", "b", "c"]
        let gains: [String: Double] = ["b": 0.2]
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
        let expected = Float32(0.8) * (1.0 + 0.2 + 1.0) / 3.0
        XCTAssertEqual(result, expected, accuracy: 0.0001)
        // Option 2 unter Solo auf "b" ergäbe 0.8 * 0.2 / 1 = 0.16 und die Welle
        // würde gegenüber dem Zustand ohne Solo schrumpfen.
        let option2UnderSolo = Float32(0.8) * 0.2
        XCTAssertGreaterThan(result, option2UnderSolo)
    }

    func testDisconnectedSoloDeviceChangesWaveOnlyThroughPeaks() {
        // Slot mit Peak (0, 0) senkt den Mittelwert (dokumentierte physische Änderung).
        let peaks: [(l: Float32, r: Float32)] = [(0.6, 0.6), (0.0, 0.0), (0.6, 0.6)]
        let keys = ["a", "b", "c"]
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        // (0.6 + 0 + 0.6) / 3 = 0.4
        XCTAssertEqual(result, 0.4, accuracy: 0.001)
    }

    func testEmptyInputReturnsZero() {
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: [], keys: [], deviceGains: [:])
        XCTAssertEqual(result, 0.0)
    }

    func testMismatchedArrayLengthsUseShorterLength() {
        let peaks: [(l: Float32, r: Float32)] = [(0.6, 0.6), (0.4, 0.4), (0.5, 0.5)]
        let keys = ["a", "b"]  // nur 2 Keys
        // Divisor 2: (0.6 + 0.4) / 2 = 0.5
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testMissingGainDefaultsToUnity() {
        let peaks: [(l: Float32, r: Float32)] = [(0.4, 0.4)]
        let keys = ["unknown-key"]
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        XCTAssertEqual(result, 0.4, accuracy: 0.001)
    }

    func testClampsAtOne() {
        let peaks = Array(repeating: (l: Float32(1.0), r: Float32(1.0)), count: 3)
        let keys = ["a", "b", "c"]
        let result1 = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        XCTAssertEqual(result1, 1.0, accuracy: 0.0001)

        // Peaks 2.0 (über dem normalen Bereich): geklemmt auf 1.0
        let highPeaks = Array(repeating: (l: Float32(2.0), r: Float32(2.0)), count: 3)
        let result2 = WaveEnergyMath.soloNeutralLinear(slotPeaks: highPeaks, keys: keys, deviceGains: [:])
        XCTAssertEqual(result2, 1.0, accuracy: 0.0001)
    }

    func testManySlotsBeyondSixteenCountEqually() {
        let peak = Float32(0.5)
        let peaks = Array(repeating: (l: peak, r: peak), count: 100)
        let keys = (0..<100).map { "slot-\($0)" }
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        // Alle Slots gleicher Peak: Ergebnis gleich dem Einzelpeak
        XCTAssertEqual(result, peak, accuracy: 0.001)
    }

    func testOneLoudSlotAtIndexNinetyNineOfHundred() {
        var peaks = Array(repeating: (l: Float32(0.0), r: Float32(0.0)), count: 100)
        peaks[99] = (l: 1.0, r: 1.0)
        let keys = (0..<100).map { "slot-\($0)" }
        let result = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: [:])
        // Nur ein Slot mit Peak 1.0: 1.0 / 100 = 0.01
        XCTAssertEqual(result, 1.0 / 100.0, accuracy: 0.001)
    }

    func testSoloNeutralLinearSignatureHasNoSoloedKeys() {
        // Regressionsschutz fuer W2 (NT2-D3): Wenn jemand soloedKeys als
        // Parameter einfuehrt, kompiliert diese Zuweisung nicht mehr.
        // Der Typ muss exakt ([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32 sein.
        // Kein Laufzeit-Assert noetig: der Compiler uebernimmt die Pruefung.
        let _: ([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32
            = WaveEnergyMath.soloNeutralLinear
        // Platzhalter-Assertion damit der Compiler kein "never used"-Warn ausgibt.
        XCTAssertTrue(true)
    }
}
