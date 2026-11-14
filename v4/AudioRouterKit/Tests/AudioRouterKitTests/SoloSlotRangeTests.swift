//
//  SoloSlotRangeTests.swift
//  AudioRouterKitTests
//
//  Prueft, dass SoloGain.effective und SlotGains.set/gain fuer Slots jenseits
//  von Index 16 korrekt zusammenarbeiten (NT-S8, W1).
//
//  Hinweis: Diese Datei bildet die Pipeline applySoloGains (EngineController) mit
//  setOutputGain (FanOutEngine) aus den beiden Kit-Bausteinen nach: SoloGain.effective
//  je Schluessel, Ergebnis per SlotGains.set(_, slotIndex:), Lesen per gain(slotIndex:).
//  Dies prueft, dass die Bausteine ueber Index 16 hinaus zusammenpassen, NICHT den
//  EngineController oder FanOutEngine selbst (diese benoetigen CoreAudio/App-Target).
//

import XCTest
@testable import AudioRouterKit

final class SoloSlotRangeTests: XCTestCase {

    private func makeKeys(count: Int) -> [String] {
        (0..<count).map { "device-uid:slot-\($0)" }
    }

    /// Hilfsfunktion: simuliert applySoloGains fuer alle Keys mit gegebenen soloedKeys
    private func applyGains(keys: [String], soloedKeys: Set<String>, deviceGains: [String: Double],
                            into sg: SlotGains) {
        for (i, key) in keys.enumerated() {
            let effective = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
            sg.set(effective, slotIndex: i)
        }
    }

    func testSoloOnSlotBeyondSixteenSilencesTheOthers() {
        let count = 120
        let keys = makeKeys(count: count)
        let sg = SlotGains()
        let deviceGains: [String: Double] = [keys[100]: 0.7]
        let soloedKeys: Set<String> = [keys[100]]

        applyGains(keys: keys, soloedKeys: soloedKeys, deviceGains: deviceGains, into: sg)

        // Solo-Slot 100 traegt den gespeicherten Gain
        XCTAssertEqual(sg.gain(slotIndex: 100), 0.7, accuracy: 0.001)
        // Alle anderen Slots (0, 15, 16, 17, 119) sind stumm
        for idx in [0, 15, 16, 17, 119] {
            XCTAssertEqual(sg.gain(slotIndex: idx), 0.0, "Slot \(idx) muss unter Solo stumm sein")
        }
    }

    func testSoloOnSlotZeroSilencesSlotsAboveSixteen() {
        let count = 120
        let keys = makeKeys(count: count)
        let sg = SlotGains()
        let soloedKeys: Set<String> = [keys[0]]

        applyGains(keys: keys, soloedKeys: soloedKeys, deviceGains: [:], into: sg)

        // Slot 0 ist solo'ed: Unity
        XCTAssertEqual(sg.gain(slotIndex: 0), 1.0)
        // Slots 16, 17, 100 sind stumm
        for idx in [16, 17, 100] {
            XCTAssertEqual(sg.gain(slotIndex: idx), 0.0, "Slot \(idx) muss unter Solo stumm sein")
        }
    }

    func testReleaseSoloRestoresStoredGainsAboveSixteen() {
        let count = 120
        let keys = makeKeys(count: count)
        let sg = SlotGains()
        var deviceGains: [String: Double] = [:]
        for i in [16, 17, 100] { deviceGains[keys[i]] = 0.6 }

        // Solo setzen
        let soloedKeys: Set<String> = [keys[0]]
        applyGains(keys: keys, soloedKeys: soloedKeys, deviceGains: deviceGains, into: sg)
        XCTAssertEqual(sg.gain(slotIndex: 16), 0.0)

        // Solo aufheben
        applyGains(keys: keys, soloedKeys: [], deviceGains: deviceGains, into: sg)
        for idx in [16, 17, 100] {
            XCTAssertEqual(sg.gain(slotIndex: idx), 0.6, accuracy: 0.001,
                           "Slot \(idx) muss nach Solo-Aufheben den gespeicherten Gain haben")
        }
    }

    func testPerDeviceVolumeBeyondSixteen() {
        let sg = SlotGains()
        sg.set(0.4, slotIndex: 40)
        XCTAssertEqual(sg.gain(slotIndex: 40), 0.4, accuracy: 0.001)
        // Nachbarn unveraendert (1.0)
        XCTAssertEqual(sg.gain(slotIndex: 39), 1.0)
        XCTAssertEqual(sg.gain(slotIndex: 41), 1.0)
    }

    func testSlotExactlySixteenAndSeventeenBehaveLikeLowSlots() {
        let count = 20
        let keys = makeKeys(count: count)
        let sg = SlotGains()
        let deviceGains: [String: Double] = [keys[15]: 0.3, keys[16]: 0.4, keys[17]: 0.5]

        // Ohne Solo: Gains wie gespeichert
        applyGains(keys: keys, soloedKeys: [], deviceGains: deviceGains, into: sg)
        XCTAssertEqual(sg.gain(slotIndex: 15), 0.3, accuracy: 0.001)
        XCTAssertEqual(sg.gain(slotIndex: 16), 0.4, accuracy: 0.001)
        XCTAssertEqual(sg.gain(slotIndex: 17), 0.5, accuracy: 0.001)

        // Solo auf 15: 16 und 17 stumm
        applyGains(keys: keys, soloedKeys: [keys[15]], deviceGains: deviceGains, into: sg)
        XCTAssertEqual(sg.gain(slotIndex: 15), 0.3, accuracy: 0.001)
        XCTAssertEqual(sg.gain(slotIndex: 16), 0.0)
        XCTAssertEqual(sg.gain(slotIndex: 17), 0.0)
    }

    func testMoreSlotsThanBeforeConfigured() {
        let sg = SlotGains()
        // Erst 5 Werte
        sg.setAll([0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(sg.gain(slotIndex: 4), 0.5, accuracy: 0.001)
        XCTAssertEqual(sg.gain(slotIndex: 5), 1.0)

        // Dann 60 Werte
        var gains60 = [Float32](repeating: 0.0, count: 60)
        for i in 0..<60 { gains60[i] = Float32(i) / 60.0 }
        sg.setAll(gains60)
        for i in 5..<60 {
            XCTAssertEqual(sg.gain(slotIndex: i), Float32(i) / 60.0, accuracy: 0.001,
                           "Slot \(i) muss den neuen Wert tragen")
        }
        // Slots 60 bis 255 sind 1.0
        XCTAssertEqual(sg.gain(slotIndex: 60), 1.0)
        XCTAssertEqual(sg.gain(slotIndex: 255), 1.0)
    }

    func testEmptyKeyUnderSoloBeyondSixteen() {
        let keys = ["", "device:0", "device:2"]
        let sg = SlotGains()
        let soloedKeys: Set<String> = ["device:0"]
        // Leerer Schluessel: unter Solo ergibt SoloGain.effective 0.0 (nicht enthalten)
        applyGains(keys: keys, soloedKeys: soloedKeys, deviceGains: [:], into: sg)
        XCTAssertEqual(sg.gain(slotIndex: 0), 0.0)   // Leerer Key ist nicht solo'ed
        XCTAssertEqual(sg.gain(slotIndex: 1), 1.0)   // "device:0" ist solo'ed
        // Schreiben auf einen gueltigen Index ueber 16 ist problemlos
        sg.set(0.5, slotIndex: 20)
        XCTAssertEqual(sg.gain(slotIndex: 20), 0.5, accuracy: 0.001)
    }
}
