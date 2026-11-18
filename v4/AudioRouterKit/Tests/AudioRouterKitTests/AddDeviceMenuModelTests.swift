//
//  AddDeviceMenuModelTests.swift
//  AudioRouterKitTests
//
//  4.1 Nachtrag (UI, Verbesserung V2): Tests fuer die Auswahl- und Titellogik
//  des "Add device"-Menues. Sichert das Titelformat (deckungsgleich mit dem
//  bisherigen AddDeviceRow), die "schon hinzugefuegt"-Erkennung (uid plus
//  channelOffset) und die Grenzfaelle (alle hinzugefuegt, Mehrpaar-/Einzelpaar-
//  Geraete, gleiche Namen mit verschiedener uid, konfigurierter Ausgang ohne
//  verfuegbares Geraet, ungerade und Nullkanal-Faelle).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import XCTest
@testable import AudioRouterKit

final class AddDeviceMenuModelTests: XCTestCase {

    // Kurzschreibweise fuer ein verfuegbares Geraet.
    private func dev(_ uid: String, _ name: String, _ ch: Int)
        -> (uid: String, name: String, channelCount: Int) {
        (uid: uid, name: name, channelCount: ch)
    }
    // Kurzschreibweise fuer einen konfigurierten Ausgang.
    private func out(_ uid: String, _ offset: Int) -> (uid: String, channelOffset: Int) {
        (uid: uid, channelOffset: offset)
    }

    // MARK: pairCount

    func testPairCountMatchesExistingRule() {
        // Deckungsgleich mit max(1, channelCount / 2).
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 0), 1)
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 1), 1)
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 2), 1)
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 3), 1)
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 4), 2)
        XCTAssertEqual(AddDeviceMenuModel.pairCount(channelCount: 64), 32)
    }

    // MARK: Titelformat (muss EXAKT dem alten AddDeviceRow entsprechen)

    func testTitleSinglePairHasNoChannelSuffix() {
        // pairCount == 1 -> nur der Name, wie Button(device.name) frueher.
        XCTAssertEqual(
            AddDeviceMenuModel.title(name: "MacBook Speakers", channelOffset: 0, pairCount: 1),
            "MacBook Speakers")
    }

    func testTitleMultiPairMatchesOldFormat() {
        // Mehrpaar -> "name (ChX-Y)" mit X = offset+1, Y = offset+2, wie frueher.
        XCTAssertEqual(
            AddDeviceMenuModel.title(name: "Komplete Audio 6 MK2", channelOffset: 0, pairCount: 2),
            "Komplete Audio 6 MK2 (Ch1-2)")
        XCTAssertEqual(
            AddDeviceMenuModel.title(name: "Komplete Audio 6 MK2", channelOffset: 2, pairCount: 2),
            "Komplete Audio 6 MK2 (Ch3-4)")
    }

    /// Nagelt das Titelformat direkt gegen die alte Berechnung aus AddDeviceRow
    /// ("\(device.name) (Ch\(offset + 1)-\(offset + 2))"), damit eine kuenftige
    /// Aenderung auffaellt.
    func testEntryTitlesEqualOldInlineFormula() {
        let name = "BlackHole 64ch"
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("bh", name, 64)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 32)
        for (idx, entry) in entries.enumerated() {
            let offset = idx * 2
            let expected = "\(name) (Ch\(offset + 1)-\(offset + 2))"
            XCTAssertEqual(entry.title, expected)
            XCTAssertEqual(entry.channelOffset, offset)
        }
    }

    // MARK: Nichts hinzugefuegt

    func testNothingAddedAllEntriesSelectable() {
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("a", "Device A", 2), dev("b", "Device B", 4)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 3) // A: 1 Paar, B: 2 Paare
        XCTAssertTrue(entries.allSatisfy { !$0.isAdded })
        XCTAssertFalse(AddDeviceMenuModel.allAdded(entries))
    }

    // MARK: Einige hinzugefuegt

    func testSomeAddedAreMarked() {
        // Beispiel aus dem Screenshot: KA6, Ch1-2 und Ch3-4 schon aktiv.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("ka6", "Komplete Audio 6 MK2", 4)],
            configuredOutputs: [out("ka6", 0), out("ka6", 2)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.isAdded })
        XCTAssertTrue(AddDeviceMenuModel.allAdded(entries))
    }

    func testPartiallyAddedMultiPairDevice() {
        // Nur Ch1-2 aktiv, Ch3-4 noch frei.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("ka6", "Komplete Audio 6 MK2", 4)],
            configuredOutputs: [out("ka6", 0)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isAdded)   // Ch1-2
        XCTAssertFalse(entries[1].isAdded)  // Ch3-4
        XCTAssertFalse(AddDeviceMenuModel.allAdded(entries))
    }

    // MARK: Alle hinzugefuegt

    func testAllAddedAcrossDevices() {
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("a", "Device A", 2), dev("b", "Device B", 4)],
            configuredOutputs: [out("a", 0), out("b", 0), out("b", 2)])
        XCTAssertTrue(entries.allSatisfy { $0.isAdded })
        XCTAssertTrue(AddDeviceMenuModel.allAdded(entries))
    }

    func testAllAddedIsFalseForEmptyList() {
        // Kein verfuegbares Geraet: nichts hinzuzufuegen, aber auch kein
        // "schon alles". allAdded soll false sein (sonst wuerde die View
        // faelschlich den Hinweis zeigen).
        let entries = AddDeviceMenuModel.entries(availableDevices: [], configuredOutputs: [])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(AddDeviceMenuModel.allAdded(entries))
    }

    // MARK: Einzelpaar-Geraet ohne (ChX-Y)-Zusatz

    func testSinglePairDeviceEntryHasNoSuffix() {
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("spk", "MacBook Speakers", 2)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "MacBook Speakers")
        XCTAssertEqual(entries[0].channelOffset, 0)
    }

    // MARK: Gleiche Namen, verschiedene uid

    func testSameNameDifferentUidAreIndependent() {
        // Zwei Geraete heissen gleich, haben aber verschiedene uid. Nur das
        // erste ist hinzugefuegt; das zweite bleibt waehlbar.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("uid-1", "USB Audio", 2), dev("uid-2", "USB Audio", 2)],
            configuredOutputs: [out("uid-1", 0)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].uid, "uid-1")
        XCTAssertTrue(entries[0].isAdded)
        XCTAssertEqual(entries[1].uid, "uid-2")
        XCTAssertFalse(entries[1].isAdded)
    }

    // MARK: Konfigurierter Ausgang ohne verfuegbares Geraet

    func testConfiguredOutputWithoutDeviceProducesNoEntry() {
        // "ghost" ist konfiguriert, aber nicht verfuegbar: er erzeugt keinen
        // Eintrag und markiert auch keinen anderen.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("real", "Real Device", 2)],
            configuredOutputs: [out("ghost", 0), out("real", 0)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].uid, "real")
        XCTAssertTrue(entries[0].isAdded)
        XCTAssertFalse(entries.contains { $0.uid == "ghost" })
    }

    // MARK: Ungerade und Nullkanal-Faelle

    func testZeroChannelDeviceStillOnePair() {
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("z", "Zero Ch", 0)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 1) // max(1, 0/2) = 1
        XCTAssertEqual(entries[0].title, "Zero Ch")
        XCTAssertEqual(entries[0].channelOffset, 0)
    }

    func testOddChannelDeviceRoundsDownLikeBefore() {
        // channelCount 3 -> max(1, 3/2) = 1 Paar (wie bisher), kein Ch-Zusatz.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("odd", "Odd Device", 3)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Odd Device")
    }

    func testOddChannelFiveGivesTwoPairs() {
        // channelCount 5 -> max(1, 5/2) = 2 Paare, mit Ch-Zusatz.
        let entries = AddDeviceMenuModel.entries(
            availableDevices: [dev("odd5", "Five Ch", 5)],
            configuredOutputs: [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Five Ch (Ch1-2)")
        XCTAssertEqual(entries[1].title, "Five Ch (Ch3-4)")
    }

    // MARK: Reihenfolge stabil (markieren verschiebt nicht)

    func testOrderIsStableWhenSomeAdded() {
        let avail = [dev("a", "A", 2), dev("b", "B", 4), dev("c", "C", 2)]
        let none = AddDeviceMenuModel.entries(availableDevices: avail, configuredOutputs: [])
        let some = AddDeviceMenuModel.entries(
            availableDevices: avail,
            configuredOutputs: [out("b", 0)])
        // Gleiche Reihenfolge, nur ein Eintrag markiert.
        XCTAssertEqual(none.map { $0.uid + ":\($0.channelOffset)" },
                       some.map { $0.uid + ":\($0.channelOffset)" })
        XCTAssertEqual(some.filter { $0.isAdded }.count, 1)
    }

    // MARK: allAddedNotice ist stilkonform

    func testAllAddedNoticeIsPlain() {
        let text = AddDeviceMenuModel.allAddedNotice
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("—"))
        XCTAssertFalse(text.contains(" -- "))
        XCTAssertEqual(text, "All outputs are added.")
    }
}
