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
        queue.sync { [weak self] in self?.updateDevice() }
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
        queue.sync { [weak self] in self?.removeDeviceListeners() }
        // Zurück auf Unity (kein Gain) nach Stopp
        setVolumeInternal(1.0)
    }

    // MARK: Listener-Callbacks (läuft auf `queue`)

    private func onDefaultDeviceChanged() {
        updateDevice()
    }

    private func onVolumeChanged(deviceID: AudioObjectID) {
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
            mElement: kAudioObjectPropertyElementMain
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
                mElement: kAudioObjectPropertyElementMain
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

        // 2. Volume-Scalar lesen
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 1.0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(deviceID, &volAddr),
           AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
            setVolumeInternal(max(0, min(1, vol)))
            logger.debug("VolumeTracker: volume=\(vol, privacy: .public)")
        } else {
            // Gerät unterstützt kein Software-Volume (z.B. HDMI) → kein Gain-Attenuation
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
    /// Läuft auf der normalen UI-Queue — kein RT-Kontext.
    func setSystemVolume(_ vol: Float32) {
        let id = queue.sync { currentDeviceID }
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }
        var v = max(0, min(1, vol))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &addr, &settable)
        guard settable.boolValue else { return }
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
