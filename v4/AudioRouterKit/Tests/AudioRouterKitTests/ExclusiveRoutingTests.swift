import XCTest
@testable import AudioRouterKit

/// CASE-008 (Exclusive Routing): Der Default-Output-Slot wird nicht mehr
/// bedingungslos angehaengt. `FanOutEngine.shouldAppendDefaultSlot` ist die
/// reine Entscheidungsfunktion dahinter, CoreAudio-frei und damit CI-tauglich.
///
/// Geprueft werden alle drei Faelle plus zwei Mutationsproben: entfernt man je
/// einen der beiden Fruehausstiege, faellt ein Test um. Was nicht als Funktion
/// vorliegt, wird nicht geprueft (dieselbe Lehre wie bei CASE-004).
final class ExclusiveRoutingTests: XCTestCase {

    // MARK: Fall 1, Passthrough-Garantie

    /// Keine auflosbaren User-Outputs (leere oder komplett nicht auflosbare
    /// Auswahl): der Default-Slot MUSS angehaengt werden, sonst waere alles
    /// stumm. Gilt unabhaengig vom Exklusiv-Schalter.
    func testNoResolvableUserOutputsAppendsDefaultEvenWhenExclusive() {
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: false, exclusiveRouting: true))
    }

    func testNoResolvableUserOutputsAppendsDefaultWhenNotExclusive() {
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: false, exclusiveRouting: false))
    }

    // MARK: Fall 2, Standard-Modus (bisheriges Verhalten)

    /// Exklusiv AUS und echte Auswahl: der Default-Output spielt wie bisher
    /// immer mit, der Slot wird angehaengt. Das ist das Verhalten, das
    /// bestehende Nutzer kennen.
    func testNotExclusiveWithResolvableUserOutputsAppendsDefault() {
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: true, exclusiveRouting: false))
    }

    // MARK: Fall 3, Exklusiv-Modus aktiv

    /// Exklusiv AN und echte Auswahl: der Default-Slot faellt weg, der
    /// Default-Output bleibt durch `.mutedWhenTapped` stumm. Das ist der Kern
    /// von CASE-008.
    func testExclusiveWithResolvableUserOutputsDropsDefault() {
        XCTAssertFalse(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: true, exclusiveRouting: true))
    }

    // MARK: Mutationsproben

    /// Nur der Fall "auflosbare Auswahl + Exklusiv" darf `false` ergeben. Alle
    /// vier Kombinationen auf einmal, damit keine Mutation (z.B. ein
    /// vertauschter Rueckgabewert oder ein entfernter Fruehausstieg) unentdeckt
    /// durchkommt.
    func testTruthTableIsExact() {
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: false, exclusiveRouting: false))
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: false, exclusiveRouting: true))
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: true, exclusiveRouting: false))
        XCTAssertFalse(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: true, exclusiveRouting: true))
    }

    /// Mutationsprobe gegen den Passthrough-Fruehausstieg: wird die erste Regel
    /// (`!hasResolvableUserOutputs -> true`) entfernt, liefert dieser Fall
    /// faelschlich `false`. Der Test fixiert, dass leere Auswahl + Exklusiv
    /// NIEMALS den Default weglaesst (sonst Totalstille, die lauteste
    /// Fehlerrichtung der Stille).
    func testExclusiveWithEmptySelectionNeverSilencesEverything() {
        XCTAssertTrue(FanOutEngine.shouldAppendDefaultSlot(
            hasResolvableUserOutputs: false, exclusiveRouting: true),
            "Exklusiv-Modus ohne auflosbare Auswahl darf den Default nicht weglassen")
    }

    // MARK: CASE-008 Slot-Reihenfolge (orderedSlotConfigs), Master-first-Invariante

    /// Repro BT-Speaker + Built-in(Default), Exclusive ON: der User hat den
    /// Default selbst gewaehlt, Built-in gewinnt die Elektion (Rang 1 gegen BT
    /// Rang 4), appendDefaultSlot ist false. Branch 1a muss die User-Configs des
    /// Default-Geraets ZUERST anhaengen, sonst beginnt allOutputs mit dem BT-Slot,
    /// die SubDeviceList aber mit dem Master → Buffer-Offset-Mismatch, Faktor-1.0-Leck.
    func testExclusiveDefaultInSelectionMasterEqualsDefaultOrdersDefaultFirst() {
        let bt = OutputConfig(uid: "bt-speaker")
        let builtin = OutputConfig(uid: "builtin")
        let ordered = FanOutEngine.orderedSlotConfigs(
            outputs: [bt, builtin],
            defaultOutputUID: "builtin",
            masterUID: "builtin",
            appendDefaultSlot: false
        )
        XCTAssertEqual(ordered.first?.uid, "builtin",
            "Master-first-Invariante: der Default-Master muss zuerst stehen")
        XCTAssertEqual(ordered.map { $0.uid }, ["builtin", "bt-speaker"])
    }

    /// Standard-Modus (appendDefaultSlot=true, Master==Default): der erste Eintrag
    /// ist der synthetische Default-ch0-Slot, der Rest folgt in outputs-Reihenfolge.
    /// Regressionsschutz fuer das bisherige Verhalten.
    func testStandardModeMasterEqualsDefaultPrependsDefaultCh0Slot() {
        let extern = OutputConfig(uid: "usb-dac")
        let builtin = OutputConfig(uid: "builtin")
        let ordered = FanOutEngine.orderedSlotConfigs(
            outputs: [extern, builtin],
            defaultOutputUID: "builtin",
            masterUID: "builtin",
            appendDefaultSlot: true
        )
        XCTAssertEqual(ordered.first?.uid, "builtin")
        XCTAssertEqual(ordered.first?.channelOffset, 0)
        XCTAssertEqual(ordered.map { $0.uid }, ["builtin", "usb-dac"])
    }

    /// Master ist ein User-Device (Branch 1b): dessen Configs zuerst, dann der
    /// Default-Slot, dann der Rest.
    func testMasterIsUserDeviceOrdersMasterThenDefaultThenRest() {
        let usb = OutputConfig(uid: "usb-dac")
        let hdmi = OutputConfig(uid: "hdmi")
        let ordered = FanOutEngine.orderedSlotConfigs(
            outputs: [hdmi, usb],
            defaultOutputUID: "builtin",
            masterUID: "usb-dac",
            appendDefaultSlot: true
        )
        XCTAssertEqual(ordered.map { $0.uid }, ["usb-dac", "builtin", "hdmi"])
    }

    /// Dedup: steht der Default mit channelOffset 0 bereits in outputs, darf kein
    /// Doppel-Slot entstehen.
    func testDefaultWithChannelOffsetZeroInOutputsNoDuplicateSlot() {
        let builtin = OutputConfig(uid: "builtin", channelOffset: 0)
        let usb = OutputConfig(uid: "usb-dac")
        let ordered = FanOutEngine.orderedSlotConfigs(
            outputs: [usb, builtin],
            defaultOutputUID: "builtin",
            masterUID: "usb-dac",
            appendDefaultSlot: true
        )
        let builtinCh0Count = ordered.filter { $0.uid == "builtin" && $0.channelOffset == 0 }.count
        XCTAssertEqual(builtinCh0Count, 1, "Default-ch0 darf nur einen Slot erzeugen")
        XCTAssertEqual(ordered.map { $0.uid }, ["usb-dac", "builtin"])
    }

    // MARK: CASE-008 electMasterUID Fallback

    /// Alle Kandidaten Rang 4 (nur BT/AirPlay): electMasterUID liefert den
    /// Fallback, da kein Kandidat Rang < 4 hat. Sichert die bekannte
    /// Einschraenkung (rank-4-Fallback-Master) ab.
    func testElectMasterAllRankFourReturnsFallback() {
        let candidates: [(uid: String, rank: Int)] = [
            (uid: "bt-a", rank: 4),
            (uid: "bt-b", rank: 4),
        ]
        let elected = FanOutEngine.electMasterUID(candidates: candidates, fallback: "bt-a")
        XCTAssertEqual(elected, "bt-a",
            "Alle Rang 4: kein Kandidat qualifiziert, Fallback greift")
    }
}
