import XCTest
@testable import AudioRouterKit

/// CASE-004: `vol` des Default-Geräts darf nicht zusätzlich auf den Slot
/// gelegt werden, der dieses Gerät selbst IST, sonst wirkt der Faktor zweimal
/// (`vol²`, gemessen 10,5 dB Verlust bei 30 %).
///
/// Die Zuordnung ist eine reine Array-Transformation, deshalb CoreAudio-frei
/// und CI-tauglich testbar.
final class VolumeScalingTests: XCTestCase {

    private let defaultUID = "BuiltInSpeakerDevice"
    private let otherUID = "AppleUSBAudioEngine:Creative:Pebble"
    private let thirdUID = "DellU3277WB-HDMI"

    /// Default-Gerät MIT Hardwareregler plus ein Fan-out-Slot:
    /// der Default-Slot bekommt Faktor 1.0 (false), alle anderen weiter `vol`.
    func testDefaultWithHardwareVolumeSkipsSoftwareScaling() {
        let outputs = [
            OutputConfig(uid: defaultUID, channelOffset: 0),
            OutputConfig(uid: otherUID, channelOffset: 0),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [false, true])
    }

    /// Default-Gerät OHNE Hardwareregler (Software-Volume-Modus):
    /// die Hardware trägt nichts bei, also braucht auch der Default-Slot `vol`,
    /// sonst wirkt der Systemregler gar nicht mehr.
    func testDefaultWithoutHardwareVolumeKeepsSoftwareScaling() {
        let outputs = [
            OutputConfig(uid: defaultUID, channelOffset: 0),
            OutputConfig(uid: otherUID, channelOffset: 0),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: false
        )
        XCTAssertEqual(result, [true, true])
    }

    /// Dieselbe UID wie das Default-Gerät, aber `channelOffset == 2`:
    /// `kAudioDevicePropertyVolumeScalar` steuert nur das primäre Stereo-Paar,
    /// Kanal 3/4 braucht `vol` weiterhin als Proxy.
    func testSameUIDWithChannelOffsetTwoStillAppliesVol() {
        let outputs = [
            OutputConfig(uid: defaultUID, channelOffset: 0),
            OutputConfig(uid: defaultUID, channelOffset: 2),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [false, true])
    }

    // MARK: Zuordnung über die UID, nicht über den Index

    /// Der wichtigste Test dieser Datei.
    ///
    /// Die drei Tests darüber platzieren das Default-Gerät alle auf Index 0.
    /// Sie bestehen deshalb auch unter der Fehlimplementierung
    /// `slotIdx == 0 && hasHW ? false : true`, gegen die der Entwurf sich
    /// ausdrücklich entschieden hat. Die zentrale Entscheidung, Zuordnung über
    /// `uid` statt über die Position, war damit von keinem Test abgedeckt.
    ///
    /// Der Fall ist nicht konstruiert: gewinnt ein fremdes Gerät die
    /// Master-Rolle im Aggregate, stehen dessen Slots vor dem Default-Gerät.
    func testDefaultDeviceNotAtIndexZero() {
        let outputs = [
            OutputConfig(uid: otherUID, channelOffset: 0),
            OutputConfig(uid: defaultUID, channelOffset: 0),
            OutputConfig(uid: thirdUID, channelOffset: 0),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [true, false, true])
    }

    /// Default-Gerät gar nicht unter den Ausgaben: alle Slots bekommen `vol`,
    /// also das Verhalten vor dem Fix.
    ///
    /// Heute strukturell unerreichbar, weil das Default-Gerät unbedingt
    /// angehängt wird. Die leise Richtung ist Absicht und wird hier festgenagelt,
    /// damit ein späterer Umbau sie nicht stillschweigend umdreht.
    func testDefaultDeviceAbsentFromOutputs() {
        let outputs = [
            OutputConfig(uid: otherUID, channelOffset: 0),
            OutputConfig(uid: thirdUID, channelOffset: 0),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [true, true])
    }

    /// Höchstens EIN Slot darf den Faktor 1.0 bekommen.
    ///
    /// Zwei `false` hieße, ein Fan-out-Ziel spielt auf Anschlag: die laute
    /// Fehlerrichtung. Die Invariante folgt aus dem Dedup-Schlüssel
    /// `"<uid>:<channelOffset>"` in `appendConfig` und war als Messung am Gerät
    /// vorgesehen. Hier wird sie zur Prüfung in der Testsuite.
    func testAtMostOneSlotSkipsVolume() {
        let outputs = [
            OutputConfig(uid: otherUID, channelOffset: 0),
            OutputConfig(uid: defaultUID, channelOffset: 0),
            OutputConfig(uid: defaultUID, channelOffset: 2),
            OutputConfig(uid: thirdUID, channelOffset: 0),
        ]
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: outputs,
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [true, false, true, true])
        XCTAssertEqual(result.filter { !$0 }.count, 1)
    }

    /// Leere Ausgabeliste: leeres Ergebnis. Nagelt den Grenzfall fest gegen
    /// einen späteren Umbau auf `first` oder `[0]`.
    func testEmptyOutputsYieldEmptyResult() {
        let result = FanOutEngine.computeSlotAppliesVol(
            outputs: [],
            defaultOutputUID: defaultUID,
            defaultHasHardwareVolume: true
        )
        XCTAssertEqual(result, [])
    }

    // MARK: Der Faktor selbst, inklusive Stummschaltung

    /// Die vollständige Matrix aus `appliesVol` und `vol`.
    ///
    /// Diese Tests existieren wegen eines Fehlers im ersten Durchlauf: dort
    /// bekam der Default-Slot bedingungslos `1.0`, wodurch die Stummschaltung
    /// auf ihm nicht mehr in Software wirkte. Kein Test hat das gefunden, weil
    /// prüfbar nur die Zuordnung der Slots war und nicht die Entscheidung über
    /// den Faktor.
    ///
    /// `vol == 0` ist die Stummschaltung. `VolumeTracker` führt keinen eigenen
    /// Mute-Zustand, sondern schreibt Lautstärke Null.
    func testEffectiveVolumeMatrix() {
        // Slot bekommt `vol`: unverändert durchgereicht, auch bei Null.
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 0.0, appliesVol: true), 0.0)
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 0.3, appliesVol: true), 0.3)
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 1.0, appliesVol: true), 1.0)

        // Default-Slot mit Hardwareregler: Faktor 1.0 statt vol, das ist der
        // CASE-004-Fix. Aber NICHT bei Stummschaltung.
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 0.0, appliesVol: false), 0.0,
                       "Stummschaltung muss auch den Default-Slot erreichen")
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 0.3, appliesVol: false), 1.0)
        XCTAssertEqual(FanOutEngine.effectiveVolume(vol: 1.0, appliesVol: false), 1.0)
    }

    // MARK: Die Verdrahtung, nicht nur die Bestandteile

    /// Diese Tests existieren wegen eines Befunds des zweiten Audits: die
    /// Zuordnung und der Faktor waren einzeln geprüft, die Multiplikation
    /// dazwischen nicht. Der ursprüngliche Fehler von CASE-004 liess sich
    /// dadurch wieder einbauen, `vol * g` statt `effectiveVol * g` im IOProc,
    /// ohne dass ein einziger Test umfiel.
    ///
    /// Der Default-Slot mit Hardwareregler bei 30 % Systemlautstärke und
    /// Gain 1.0: der Faktor muss 1.0 sein, nicht 0.3 und erst recht nicht 0.09.
    func testSlotTargetSVDoesNotApplyVolumeTwiceOnDefaultSlot() {
        let flags = [false, true]   // Slot 0 ist das Default-Gerät
        let targetSV = FanOutEngine.slotTargetSV(
            vol: 0.3, slotIndex: 0, slotAppliesVol: flags, gain: 1.0)

        XCTAssertEqual(targetSV, 1.0,
                       "Der Default-Slot darf vol nicht in Software anwenden")
        XCTAssertNotEqual(targetSV, 0.3,
                          "0.3 hiesse, die Zuordnung wird ignoriert")
        XCTAssertNotEqual(targetSV, 0.09,
                          "0.09 ist der Originalfehler vol im Quadrat")
    }

    /// Derselbe Aufruf für einen Fan-out-Slot: dort MUSS `vol` wirken, sonst
    /// spielt ein Ziel ohne eigenen Regler auf Anschlag.
    func testSlotTargetSVAppliesVolumeOnFanOutSlot() {
        let flags = [false, true]
        let targetSV = FanOutEngine.slotTargetSV(
            vol: 0.3, slotIndex: 1, slotAppliesVol: flags, gain: 1.0)
        XCTAssertEqual(targetSV, 0.3, accuracy: 1e-6)
    }

    /// Der Per-Slot-Gain muss in beiden Zweigen multiplikativ bleiben.
    func testSlotTargetSVKeepsPerSlotGain() {
        let flags = [false, true]
        // Default-Slot: 1.0 * 0.5
        XCTAssertEqual(
            FanOutEngine.slotTargetSV(vol: 0.3, slotIndex: 0, slotAppliesVol: flags, gain: 0.5),
            0.5, accuracy: 1e-6)
        // Fan-out-Slot: 0.3 * 0.5
        XCTAssertEqual(
            FanOutEngine.slotTargetSV(vol: 0.3, slotIndex: 1, slotAppliesVol: flags, gain: 0.5),
            0.15, accuracy: 1e-6)
    }

    /// Stummschaltung schlägt die Slot-Zuordnung, auch durch die Verdrahtung
    /// hindurch und unabhängig vom Gain.
    func testSlotTargetSVMuteBeatsAssignment() {
        let flags = [false, true]
        XCTAssertEqual(
            FanOutEngine.slotTargetSV(vol: 0.0, slotIndex: 0, slotAppliesVol: flags, gain: 1.0),
            0.0, "Stummschaltung muss auch den Default-Slot erreichen")
        XCTAssertEqual(
            FanOutEngine.slotTargetSV(vol: 0.0, slotIndex: 1, slotAppliesVol: flags, gain: 0.7),
            0.0)
    }

    /// Index ausserhalb der Liste: Rückfall auf `vol` anwenden, die leise
    /// Richtung. Ein Rückfall auf `false` liesse den Slot auf Anschlag spielen.
    func testSlotTargetSVOutOfRangeIndexFallsBackToQuietDirection() {
        let flags = [false]   // nur ein Eintrag
        let targetSV = FanOutEngine.slotTargetSV(
            vol: 0.3, slotIndex: 5, slotAppliesVol: flags, gain: 1.0)

        XCTAssertEqual(targetSV, 0.3, accuracy: 1e-6,
                       "Ohne Eintrag muss vol angewendet werden, nicht 1.0")
        XCTAssertNotEqual(targetSV, 1.0,
                          "1.0 waere die laute Fehlerrichtung")
    }

    /// Leere Liste: jeder Index fällt zurück, niemand spielt auf Anschlag.
    func testSlotTargetSVEmptyFlagsNeverPlaysAtFullScale() {
        for slotIndex in 0..<4 {
            let targetSV = FanOutEngine.slotTargetSV(
                vol: 0.25, slotIndex: slotIndex, slotAppliesVol: [], gain: 1.0)
            XCTAssertEqual(targetSV, 0.25, accuracy: 1e-6)
        }
    }

    /// Bei 30 % war der gemessene Verlust 10,5 dB, die Rechnung sagt
    /// `-20·log10(0.3) = 10,46 dB`. Der Fix muss diesen Abstand auf Null
    /// bringen, also `1.0` liefern statt `0.3`.
    func testThirtyPercentNoLongerAttenuatesTwice() {
        let vol: Float32 = 0.3
        let factor = FanOutEngine.effectiveVolume(vol: vol, appliesVol: false)

        // Vor dem Fix: vol * vol = 0.09. Nach dem Fix: 1.0, die Hardware
        // liefert die 0.3 allein.
        XCTAssertEqual(factor, 1.0)
        XCTAssertNotEqual(factor * vol, vol * vol)
    }
}
