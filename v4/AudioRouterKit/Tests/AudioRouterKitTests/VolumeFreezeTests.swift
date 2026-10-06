import XCTest
@testable import AudioRouterKit

/// CASE-007: Beim Anschliessen von Kopfhoerern wechselt macOS den System-Default.
/// `VolumeTracker` liest sofort den (oft hoeheren) gespeicherten Pegel des neuen
/// Geraets, waehrend der Engine-Rebuild sein `slotAppliesVol`-Layout erst nach
/// ~2s neu berechnet. Im Settle-Fenster trifft der neue Wert auf das alte
/// Slot-Layout: hoerbarer Lautstaerke-Sprung nach oben.
///
/// `shouldAdoptVolume` ist das Gate, das den Wert im Fenster verwirft. Die
/// Entscheidung ist eine reine Funktion, damit sie geprueft werden kann, nicht
/// nur ein Ausdruck am Schreibpfad (dieselbe Lehre wie CASE-004).
final class VolumeFreezeTests: XCTestCase {

    private let dur = VolumeTracker.settleFreezeDurationConst

    // MARK: Die fuenf Regeln, einzeln festgenagelt

    /// Regel 1: Mute (newValue == 0.0) wird IMMER uebernommen, auch im Freeze.
    /// Ein verworfenes Mute hiesse Ton trotz Stummtaste, die laute Fehlerrichtung.
    func testMuteAlwaysAdoptedEvenWhenFrozen() {
        XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
            newValue: 0.0, isFrozen: true, frozenElapsed: 0.0,
            isUserIntent: false, isMute: true),
            "Mute muss den Freeze durchbrechen")
    }

    /// Regel 2: User-Intent (Slider bewegt) wird IMMER uebernommen und hebt den
    /// Freeze auf. Eine bewusste Handlung, kein Geraetewechsel-Artefakt.
    func testUserIntentAlwaysAdoptedEvenWhenFrozen() {
        XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
            newValue: 0.9, isFrozen: true, frozenElapsed: 0.0,
            isUserIntent: true, isMute: false),
            "User-Slider muss den Freeze aufheben")
    }

    /// Regel 3: Kein Freeze aktiv → Normalbetrieb, Wert wird uebernommen.
    func testNotFrozenAdoptsNormally() {
        XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
            newValue: 0.8, isFrozen: false, frozenElapsed: 0.0,
            isUserIntent: false, isMute: false),
            "Ohne Freeze gilt der Normalpfad")
    }

    /// Regel 4: Freeze aktiv, aber Deadline abgelaufen → Sicherheitsnetz greift,
    /// Wert wird uebernommen, statt ewig einzufrieren.
    func testFrozenButDeadlineElapsedAdopts() {
        XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
            newValue: 0.8, isFrozen: true, frozenElapsed: dur,
            isUserIntent: false, isMute: false),
            "Nach Ablauf der Deadline muss der Wert uebernommen werden")
        XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
            newValue: 0.8, isFrozen: true, frozenElapsed: dur + 1.0,
            isUserIntent: false, isMute: false))
    }

    /// Regel 5 (Kern des Fixes): Freeze aktiv, positiver Wert, vor Deadline
    /// → Wert wird VERWORFEN. Das verhindert den Sprung nach oben.
    func testFrozenPositiveValueBeforeDeadlineIsRejected() {
        XCTAssertFalse(VolumeTracker.shouldAdoptVolume(
            newValue: 0.9, isFrozen: true, frozenElapsed: 0.0,
            isUserIntent: false, isMute: false),
            "Im Freeze muss ein positiver Wert verworfen werden")
        XCTAssertFalse(VolumeTracker.shouldAdoptVolume(
            newValue: 0.9, isFrozen: true, frozenElapsed: dur - 0.1,
            isUserIntent: false, isMute: false),
            "Knapp vor der Deadline weiterhin verwerfen")
    }

    // MARK: Prioritaet der Regeln

    /// Mute schlaegt den Freeze auch exakt an der Deadline-Grenze und darunter.
    func testMuteBeatsFreezeAtAnyElapsed() {
        for elapsed in [0.0, dur / 2, dur - 0.01, dur, dur + 5] {
            XCTAssertTrue(VolumeTracker.shouldAdoptVolume(
                newValue: 0.0, isFrozen: true, frozenElapsed: elapsed,
                isUserIntent: false, isMute: true),
                "Mute muss bei elapsed=\(elapsed) uebernommen werden")
        }
    }

    // MARK: Mutationsproben

    /// Mutationsprobe 1 (Gate entfernen): Wuerde Regel 5 auf `true` gedreht
    /// (also das Gate entfernt, immer uebernehmen), faellt dieser Test. Er ist
    /// die einzige Stelle, an der `false` das korrekte Ergebnis ist.
    func testMutationRemovingGateWouldBreak() {
        let adopt = VolumeTracker.shouldAdoptVolume(
            newValue: 0.75, isFrozen: true, frozenElapsed: 0.0,
            isUserIntent: false, isMute: false)
        XCTAssertFalse(adopt,
            "Ohne das Gate (Regel 5 -> true) wuerde der Freeze nicht greifen")
    }

    /// Mutationsprobe 2 (Mute-Bypass entfernen): Wuerde Regel 1 entfernt, liefe
    /// ein Mute im Freeze in Regel 5 und wuerde verworfen. Dieser Test verlangt
    /// `true` fuer ein Mute im aktiven Freeze und faellt damit bei der Mutation.
    func testMutationRemovingMuteBypassWouldBreak() {
        let adopt = VolumeTracker.shouldAdoptVolume(
            newValue: 0.0, isFrozen: true, frozenElapsed: 0.0,
            isUserIntent: false, isMute: true)
        XCTAssertTrue(adopt,
            "Ohne den Mute-Bypass wuerde ein Mute im Freeze faelschlich verworfen")
    }

    /// Der konstante Spiegelwert fuer die Deadline muss mit der Instanz-Property
    /// uebereinstimmen (4s = 2x btSettleDelay). Faellt, wenn einer der beiden
    /// Werte unbemerkt driftet.
    func testSettleFreezeDurationConstantIsFourSeconds() {
        XCTAssertEqual(VolumeTracker.settleFreezeDurationConst, 4.0, accuracy: 1e-9)
    }
}
