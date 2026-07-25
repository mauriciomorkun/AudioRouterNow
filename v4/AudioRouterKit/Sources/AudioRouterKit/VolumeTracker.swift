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
        queue.sync { [weak self] in self?.isStopped = false; self?.updateDevice() }
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
        queue.sync { [weak self] in self?.isStopped = true; self?.removeDeviceListeners() }
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
            setVolumeInternal(0.0)
            logger.debug("VolumeTracker: Muted → 0.0")
            return
        }

        // Software-Volume-Modus: Gerät hat kein Volume-Property (Fixed-Volume-BT,
        // HDMI) → interner Gain statt Unity-Fallback.
        guard hasHardwareVolume else {
            setVolumeInternal(softwareVolume)
            return
        }

        // Volume-Scalar lesen (elementMain ODER Kanal 1 — siehe findVolumeElement)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: volumeElement
        )
        var vol: Float32 = 1.0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
            setVolumeInternal(max(0, min(1, vol)))
            logger.debug("VolumeTracker: volume=\(vol, privacy: .public) (element=\(self.volumeElement, privacy: .public))")
        } else {
            setVolumeInternal(1.0)
        }
    }

    // MARK: RT-sicherer Schreiber

    private func setVolumeInternal(_ v: Float32) {
        os_unfair_lock_lock(&_lock)
        _volumeScale = v
        os_unfair_lock_unlock(&_lock)
    }

    // MARK: Volume setzen (für UI-Slider → System)

    /// Schreibt `vol` auf das aktuelle Default-Output-Gerät.
    /// Element-Fallback: elementMain oder Kanal 1 (+ Spiegelung auf Kanal 2).
    /// Software-Volume-Modus: Gerät ohne Volume-Property → interner Gain
    /// (`softwareVolume` → `volumeScale` → IOProc).
    func setSystemVolume(_ vol: Float32) {
        let v = max(0, min(1, vol))
        let (id, isSoftware, element) = queue.sync {
            (currentDeviceID, !hasHardwareVolume, volumeElement)
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
