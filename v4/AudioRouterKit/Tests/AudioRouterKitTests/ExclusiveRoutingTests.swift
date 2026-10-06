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
}
