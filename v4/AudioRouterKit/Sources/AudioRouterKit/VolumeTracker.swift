//  VolumeTracker.swift
//  AudioRouterKit
//
//  Verfolgt die System-Lautstärke des Default-Output-Geräts.
//  RT-safe: `volumeScale` ist via os_unfair_lock aus dem IOProc lesbar.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.

import CoreAudio
import Foundation
import os

/// Verfolgt die System-Lautstärke (Volume + Mute) des aktuellen
/// Default-Output-Geräts und stellt einen RT-sicheren Skalar für den IOProc bereit.
///
/// - RT-Sicherheit: `os_unfair_lock` hält die Schreib-/Lese-Sektion < 100 ns.
///   Geeignet für CoreAudio-IO-Threads (kein malloc, kein Park).
/// - Update-Pfad: Property-Listener läuft auf serieller Utility-Queue, nie im IOProc.
final class VolumeTracker: @unchecked Sendable {

    // MARK: RT-State (lock-geschützt)

    private var _lock = os_unfair_lock_s()
    private var _volumeScale: Float32 = 1.0

    /// Aktueller Lautstärke-Skalar [0.0 … 1.0].
    /// RT-safe: kurze `os_unfair_lock`-Sektion (< 100 ns Hold-Time).
    var volumeScale: Float32 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _volumeScale
    }

    /// Build-Zeit-Abfrage (nur aus MainActor-Kontext, nicht aus IOProc).
    /// Liest, ob das aktuelle Default-Geraet Hardware-Lautstaerke hat.
    var defaultDeviceHasHardwareVolume: Bool {
        queue.sync { hasHardwareVolume }
    }

    // MARK: Interne State

    private let queue = DispatchQueue(
        label: "com.mauriciomorkun.audiorouternow.volumetracker",
        qos: .utility
    )
    private var currentDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    /// Element, auf dem das aktuelle Gerät VolumeScalar exponiert.
    /// `kAudioObjectPropertyElementMain` (0) oder Kanal-Element 1 (BT-Geräte
    /// exponieren Volume oft NUR auf den Kanal-Elementen). Nur auf `queue` berühren.
    private var volumeElement: AudioObjectPropertyElement = kAudioObjectPropertyElementMain

    /// false = Gerät hat auf KEINEM Element ein Volume-Property (Fixed-Volume-BT,
    /// HDMI) → Software-Volume-Modus: der ARN-Slider steuert `softwareVolume`,
    /// das direkt als `volumeScale` in den IOProc fließt. Nur auf `queue` berühren.
    private var hasHardwareVolume = true

    /// Interner Software-Gain [0…1] für den Software-Volume-Modus.
    /// Überlebt Default-Device-Wechsel innerhalb einer Tracker-Lebensdauer.
    /// Nur auf `queue` berühren.
    private var softwareVolume: Float32 = 1.0

    // MARK: CASE-007, Settle-Freeze

    /// CASE-007: true, solange ein Default-Device-Wechsel aussteht und der
    /// Engine-Rebuild (slotAppliesVol-Neuberechnung) noch nicht gelaufen ist.
    /// Verhindert, dass der (oft hoehere) gespeicherte Lautstaerke-Pegel des
    /// neuen Geraets im ~2s-Settle-Fenster auf das ALTE Slot-Layout trifft und
    /// einen hoerbaren Lautstaerke-Sprung nach oben erzeugt. Nur auf `queue`.
    private var freezeActive = false

    /// CASE-007: das Default-Geraet VOR dem Wechsel. Flippt der System-Default
    /// zurueck auf dieses Geraet (Stable-Output-Lock-Rueck-Flip,
    /// `DeviceLifecycleManager`), ist kein echter Wechsel passiert und der
    /// Freeze wird aufgehoben. Nur auf `queue`.
    private var freezeForDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// CASE-007: Zeitpunkt (`CFAbsoluteTimeGetCurrent`) des Einfrierens.
    /// Grundlage fuer die Deadline aus `settleFreezeDurationConst`. Nur auf `queue`.
    private var freezeSince: Double = 0.0

    private let logger = Logger(
        subsystem: "com.mauriciomorkun.audiorouternow",
        category: "VolumeTracker"
    )

    // MARK: Lifecycle

    /// Startet den Tracker: registriert Default-Device-Listener + liest Inititalwert.
    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultDeviceChanged()
        }
        defaultDeviceListenerBlock = block
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
        )
        // Initialwert synchron lesen (auf queue, damit spätere Callbacks serialisiert sind).
        // CASE-007: Freeze-Zustand zuruecksetzen. Beim Engine-Rebuild wird der
        // Tracker neu erstellt, start() loescht damit einen haengenden Freeze.
        queue.sync { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.freezeActive = false
            self.freezeForDeviceID = AudioObjectID(kAudioObjectUnknown)
            self.updateDevice()
        }
    }

    /// Stoppt den Tracker und entfernt alle Property-Listener.
    func stop() {
        // Default-Device-Listener entfernen
        if let block = defaultDeviceListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
            )
            defaultDeviceListenerBlock = nil
        }
        // Volume- + Mute-Listener vom aktuellen Device entfernen (sync, damit in-flight Callbacks enden)
        // CASE-007: Freeze-Zustand mit zuruecksetzen.
        queue.sync { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.freezeActive = false
            self.freezeForDeviceID = AudioObjectID(kAudioObjectUnknown)
            self.removeDeviceListeners()
        }
        // Zurück auf Unity (kein Gain) nach Stopp
        setVolumeInternal(1.0)
    }

    // MARK: Listener-Callbacks (läuft auf `queue`)

    /// true nach stop(): unterdrückt Late-Callbacks, die der HAL nach
    /// AudioObjectRemovePropertyListenerBlock noch auf `queue` dispatchen kann
    /// (sonst re-registriert updateDevice() Listener, die nie mehr entfernt
    /// werden, und überschreibt den volumeScale-Reset). Nur auf `queue` anfassen.
    private var isStopped = false

    private func onDefaultDeviceChanged() {
        guard !isStopped else { return }
        updateDevice()
    }

    private func onVolumeChanged(deviceID: AudioObjectID) {
        guard !isStopped else { return }
        readEffectiveVolume(for: deviceID)
    }

    /// CASE-007 (Audit Runde 1): zeitgesteuertes Nachziehen des Freeze-Endes.
    /// Das Settle-Freeze-Sicherheitsnetz in `shouldAdoptVolume` greift sonst nur,
    /// wenn nach Ablauf der Deadline noch ein HAL-Volume-/Mute-Event eintrifft.
    /// Bleibt sowohl der Engine-Rebuild (der den Tracker via `start()` neu baut)
    /// als auch jedes weitere Event aus, bliebe der eingefrorene alte Skalar ewig
    /// stehen. Dieser Timer zieht den effektiven Wert nach Ablauf aktiv nach.
    ///
    /// `generation` ist der zum Freeze-Zeitpunkt gemerkte `freezeSince`-Wert und
    /// dient als Token gegen veraltete Timer: feuert ein alter Timer, nachdem ein
    /// neuer Freeze begonnen hat, stimmt `freezeSince` nicht mehr ueberein und der
    /// Timer verfaellt wirkungslos. Alles auf `queue`, kein neuer Lock, kein
    /// Audio-Pfad.
    private func scheduleFreezeSettleDeadline(generation: Double) {
        queue.asyncAfter(deadline: .now() + Self.settleFreezeDurationConst + 0.1) { [weak self] in
            guard let self else { return }
            guard !self.isStopped, self.freezeActive, self.freezeSince == generation else { return }
            self.readEffectiveVolume(for: self.currentDeviceID)
        }
    }

    // MARK: Device-Update (läuft auf `queue`)

    private func updateDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &newID
        ) == noErr, newID != AudioObjectID(kAudioObjectUnknown) else { return }

        guard newID != currentDeviceID else {
            readEffectiveVolume(for: newID)
            return
        }

        // CASE-007: Default-Geraet wechselt. Den volumeScale auf dem ALTEN Wert
        // einfrieren, bis der Engine-Rebuild slotAppliesVol neu berechnet. Sonst
        // trifft der (oft hoehere) gespeicherte Pegel des neuen Geraets im
        // ~2s-Settle-Fenster auf das alte Slot-Layout: hoerbarer Sprung nach oben.
        if currentDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if newID == freezeForDeviceID {
                // Rueck-Flip auf das alte Geraet (Stable-Output-Lock): kein echter
                // Wechsel, Freeze aufheben und den echten Wert wieder uebernehmen.
                freezeActive = false
                freezeForDeviceID = AudioObjectID(kAudioObjectUnknown)
            } else {
                freezeActive = true
                freezeForDeviceID = currentDeviceID
                freezeSince = CFAbsoluteTimeGetCurrent()
                scheduleFreezeSettleDeadline(generation: freezeSince)
            }
        }

        removeDeviceListeners()
        if let element = Self.findVolumeElement(for: newID) {
            volumeElement = element
            hasHardwareVolume = true
        } else {
            volumeElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
            hasHardwareVolume = false
            logger.log("VolumeTracker: Gerät ohne Volume-Property → Software-Volume-Modus")
        }
        currentDeviceID = newID
        addDeviceListeners(to: newID)
        readEffectiveVolume(for: newID)
        logger.debug("VolumeTracker: Default-Device geändert → \(newID, privacy: .public)")
    }

    private func addDeviceListeners(to deviceID: AudioObjectID) {
        // Volume-Listener
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: volumeElement
        )
        if AudioObjectHasProperty(deviceID, &volAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onVolumeChanged(deviceID: deviceID)
            }
            volumeListenerBlock = block
            AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, queue, block)
        }

        // Mute-Listener
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onVolumeChanged(deviceID: deviceID)
            }
            muteListenerBlock = block
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, queue, block)
        }
    }

    private func removeDeviceListeners() {
        let id = currentDeviceID
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }

        if let block = volumeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: volumeElement
            )
            AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
            muteListenerBlock = nil
        }
        currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Element-Auflösung (Kanal-Fallback für BT-Geräte)

    /// Findet das Element, auf dem das Gerät `kAudioDevicePropertyVolumeScalar`
    /// (Output-Scope) exponiert: erst `elementMain` (0), dann Kanal-Element 1.
    /// BT-Geräte exponieren Volume häufig NUR auf den Kanal-Elementen.
    /// - Returns: das gefundene Element, oder `nil` wenn das Gerät gar kein
    ///   Volume-Property besitzt (→ Software-Volume-Modus).
    private static func findVolumeElement(
        for deviceID: AudioObjectID
    ) -> AudioObjectPropertyElement? {
        let candidates: [AudioObjectPropertyElement] = [
            AudioObjectPropertyElement(kAudioObjectPropertyElementMain),
            1,
        ]
        for element in candidates {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &addr) { return element }
        }
        return nil
    }

    // MARK: Volume-Lese-Logik (läuft auf `queue`)

    private func readEffectiveVolume(for deviceID: AudioObjectID) {
        // 1. Mute prüfen
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectHasProperty(deviceID, &muteAddr)
        if hasMute {
            _ = AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muted)
        }
        if muted != 0 {
            // CASE-007: Mute passiert den Freeze immer (isMute).
            adoptVolume(0.0, isMute: true)
            logger.debug("VolumeTracker: Muted → 0.0")
            return
        }

        // Software-Volume-Modus: Gerät hat kein Volume-Property (Fixed-Volume-BT,
        // HDMI) → interner Gain statt Unity-Fallback.
        guard hasHardwareVolume else {
            adoptVolume(softwareVolume, isMute: softwareVolume <= 0)
            return
        }

        // Volume-Scalar lesen (elementMain ODER Kanal 1, siehe findVolumeElement)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: volumeElement
        )
        var vol: Float32 = 1.0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
            let clamped = max(0, min(1, vol))
            adoptVolume(clamped, isMute: clamped <= 0)
            logger.debug("VolumeTracker: volume=\(vol, privacy: .public) (element=\(self.volumeElement, privacy: .public))")
        } else {
            adoptVolume(1.0, isMute: false)
        }
    }

    // MARK: CASE-007, Freeze-Entscheidung (reine Funktion, unit-testbar)

    /// CASE-007: entscheidet, ob ein frisch gelesener Lautstaerke-Wert in den
    /// RT-Skalar uebernommen werden darf, oder ob er im Settle-Fenster eines
    /// Default-Device-Wechsels verworfen wird.
    ///
    /// Bewusst eine reine Funktion und nicht nur ein Ausdruck am Schreibpfad.
    /// Dieselbe Lehre wie bei CASE-004: was nicht als Funktion vorliegt, wird
    /// nicht geprueft. Die Reihenfolge der Regeln ist bindend, die ersten beiden
    /// Zweige schlagen den Freeze.
    ///
    /// - Parameters:
    ///   - newValue: der frisch gelesene Lautstaerke-Skalar [0…1].
    ///   - isFrozen: `freezeActive`, es steht ein Default-Wechsel aus.
    ///   - frozenElapsed: Sekunden seit `freezeSince`.
    ///   - isUserIntent: der User hat den Slider bewegt (`setSystemVolume`),
    ///     der Freeze wird dadurch verworfen.
    ///   - isMute: `newValue == 0.0`, die Stummschaltung.
    /// - Returns: `true` = Wert uebernehmen, `false` = im Freeze verwerfen.
    nonisolated static func shouldAdoptVolume(
        newValue: Float32,
        isFrozen: Bool,
        frozenElapsed: Double,
        isUserIntent: Bool,
        isMute: Bool
    ) -> Bool {
        // 1. Mute darf NIE blockiert werden. Ein verworfenes Mute hiesse Ton
        //    trotz Stummtaste, die laute Fehlerrichtung (vgl. CASE-004, 5a).
        if isMute { return true }
        // 2. User-Intent hebt den Freeze auf: der Slider ist eine bewusste
        //    Handlung, kein transientes Geraetewechsel-Artefakt.
        if isUserIntent { return true }
        // 3. Normalbetrieb ohne Freeze.
        if !isFrozen { return true }
        // 4. Deadline abgelaufen: der erwartete Rebuild blieb aus, Wert
        //    uebernehmen statt ewig einfrieren (Sicherheitsnetz).
        if frozenElapsed >= settleFreezeDurationConst { return true }
        // 5. Freeze aktiv, positiver Wert: verwerfen. Das ist der Kern des Fixes.
        return false
    }

    /// CASE-007: Sicherheitsnetz-Dauer des Settle-Freeze. Bleibt der erwartete
    /// Engine-Rebuild aus (der den Tracker neu erstellt und damit `freezeActive`
    /// ueber `start()` loescht), darf der Freeze nicht ewig haengen. 4s = 2x
    /// `btSettleDelay`. Nach Ablauf wird der neue Wert uebernommen.
    ///
    /// `nonisolated static`, damit die reine Funktion `shouldAdoptVolume` den Wert
    /// erreicht. Einzige Quelle der Dauer, keine zweite Instanz-Property mehr
    /// (die alte `settleFreezeDuration` war toter Code, Audit Runde 1).
    nonisolated static let settleFreezeDurationConst: Double = 4.0

    // MARK: RT-sicherer Schreiber

    /// Schreibt `v` ungeprueft in den RT-Skalar. Interner Pfad, die
    /// Freeze-Entscheidung faellt in `adoptVolume(_:isMute:)` davor.
    private func setVolumeInternal(_ v: Float32) {
        os_unfair_lock_lock(&_lock)
        _volumeScale = v
        os_unfair_lock_unlock(&_lock)
    }

    /// CASE-007: Schreibpfad mit Freeze-Gate. Fragt `shouldAdoptVolume` und
    /// schreibt nur bei `true`. Laeuft auf `queue`, liest den Freeze-Zustand
    /// konsistent. Mute (`v == 0.0`) passiert immer.
    private func adoptVolume(_ v: Float32, isMute: Bool) {
        let elapsed = freezeActive ? (CFAbsoluteTimeGetCurrent() - freezeSince) : 0.0
        let adopt = Self.shouldAdoptVolume(
            newValue: v,
            isFrozen: freezeActive,
            frozenElapsed: elapsed,
            isUserIntent: false,
            isMute: isMute
        )
        guard adopt else {
            logger.debug("VolumeTracker: Wert \(v, privacy: .public) im Settle-Freeze verworfen (CASE-007)")
            return
        }
        setVolumeInternal(v)
    }

    // MARK: Volume setzen (für UI-Slider → System)

    /// Schreibt `vol` auf das aktuelle Default-Output-Gerät.
    /// Element-Fallback: elementMain oder Kanal 1 (+ Spiegelung auf Kanal 2).
    /// Software-Volume-Modus: Gerät ohne Volume-Property → interner Gain
    /// (`softwareVolume` → `volumeScale` → IOProc).
    func setSystemVolume(_ vol: Float32) {
        let v = max(0, min(1, vol))
        let (id, isSoftware, element) = queue.sync {
            // CASE-007: User-Intent. Der Slider ist eine bewusste Handlung, kein
            // transientes Geraetewechsel-Artefakt. Freeze sofort aufheben, der
            // neue Wert wird unmittelbar uebernommen (sowohl im Software- als
            // auch im Hardware-Pfad, letzterer via Listener-Callback).
            freezeActive = false
            freezeForDeviceID = AudioObjectID(kAudioObjectUnknown)
            return (currentDeviceID, !hasHardwareVolume, volumeElement)
        }
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }

        if isSoftware {
            queue.async { [weak self] in
                guard let self else { return }
                self.softwareVolume = v
                self.setVolumeInternal(v)
            }
            return
        }

        writeVolume(v, deviceID: id, element: element)
        if element == 1 {
            writeVolume(v, deviceID: id, element: 2)
        }
    }

    /// Hardware-Write eines VolumeScalar auf ein konkretes Element.
    private func writeVolume(
        _ vol: Float32,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement
    ) {
        var v = vol
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
              settable.boolValue else { return }
        AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        )
    }
}
