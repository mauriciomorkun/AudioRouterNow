//
//  DeviceLifecycleManager.swift
//  AudioRouterKit
//
//  Phase 3/4 — Device-Lifecycle: Default-Output-Wechsel, Disconnect,
//  coreaudiod-Restart. Minimal-Reconciliation via debounced Engine-Restart.
//
//  v3-Lektion H3: Property-Listener-Callbacks laufen NUR auf einer seriellen
//  Queue — niemals synchron zurück in CoreAudio (Re-Entry-Deadlock).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AudioToolbox
import CoreAudio
import Foundation
import os

/// Zustand eines Output-Geräts in der Desired-State-Reconciliation.
public enum DeviceState: Equatable, Sendable {
    case active
    case disappearing
    case reconnecting
    case unavailable
}

/// Verwaltet den Lebenszyklus der Output-Geräte und löst bei relevanten
/// Änderungen einen (debounced) Engine-Restart aus.
///
/// `@unchecked Sendable`: aller veränderlicher Zustand ist auf `queue`
/// eingesperrt (SPSC-artige Serial-Queue-Invariante). Listener-Blocks und
/// Reconcile-Code laufen ausschließlich dort.
public final class DeviceLifecycleManager: @unchecked Sendable {

    /// Settle-Karenz für HDMI/DisplayPort (Display-Sleep-Flattern) — 3 s.
    public static let hdmiSettleDelay: TimeInterval = 3.0
    /// Settle-Karenz für Bluetooth-Reconnect-Kaskaden — 2 s.
    public static let btSettleDelay: TimeInterval = 2.0

    /// Liefert die transportspezifische Settle-Karenz.
    public static func settleDelay(isBluetooth: Bool) -> TimeInterval {
        isBluetooth ? btSettleDelay : hdmiSettleDelay
    }

    private let logger = Logger(subsystem: "com.mauriciomorkun.audiorouternow",
                                category: "DeviceLifecycle")

    /// Serielle Queue: ALLE Listener-Blocks + Reconcile laufen NUR hier (H3).
    private let queue = DispatchQueue(
        label: "com.mauriciomorkun.audiorouternow.devicelifecycle")

    /// Restart-Callback (wird auf `queue` aufgerufen; der Empfänger hüpft selbst
    /// auf den MainActor).
    private let onNeedsRestart: @Sendable () -> Void

    /// M4: Warm-Restart-Callback bei Sample-Rate-Wechsel eines gerouteten
    /// Geräts (optional). Wird auf `queue` aufgerufen.
    private let onSampleRateChanged: (@Sendable () -> Void)?

    // ── Zustand — NUR auf `queue` berühren ──
    private var routedUIDs: Set<String> = []
    private var lastDefaultOutputUID: String?
    private var pendingRestart: DispatchWorkItem?
    private var isListening = false

    /// L1: UIDs, die beim letzten `handleDevicesChanged` gefehlt haben —
    /// für die Re-Appear-Erkennung (war weg, ist jetzt wieder da → Restart).
    private var lastKnownMissingUIDs: Set<String> = []

    // ── M4: Sample-Rate-Listener ──
    /// Pro geroutetem Device ein registrierter SR-Listener-Block (für Remove).
    private var srListenerBlocks: [(deviceID: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = []
    /// Gate gegen Startup-Feedback: erst 1 s nach Start aktiv.
    private var srListenersActive = false
    /// Debounce-Handle für den SR-getriggerten Warm-Restart.
    private var pendingSRRestart: DispatchWorkItem?

    // Listener-Blocks aufbewahren (identische Referenz für Remove nötig).
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var serviceRestartedListener: AudioObjectPropertyListenerBlock?

    // Adressen als Instanz-vars (inout-Übergabe an Add/Remove).
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var serviceRestartedAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Erstellt einen Lifecycle-Manager mit Restart-Callback.
    /// - Parameters:
    ///   - onNeedsRestart: auf der seriellen Queue aufgerufen (Full-Restart).
    ///   - onSampleRateChanged: optional, auf der seriellen Queue aufgerufen,
    ///     wenn ein geroutetes Device seine Nominal-Sample-Rate ändert (M4 →
    ///     Warm-Restart).
    public init(
        onNeedsRestart: @escaping @Sendable () -> Void,
        onSampleRateChanged: (@Sendable () -> Void)? = nil
    ) {
        self.onNeedsRestart = onNeedsRestart
        self.onSampleRateChanged = onSampleRateChanged
    }

    /// Rückwärtskompatibler No-op-Init (Placeholder/Tests).
    public convenience init() {
        self.init(onNeedsRestart: {})
    }

    /// Registriert die Property-Listener. `routedUIDs` = alle UIDs, deren
    /// Verschwinden einen Restart auslöst (Default-Output + Fan-out-Ziele).
    public func start(routedUIDs: Set<String>) {
        queue.async { [self] in
            guard !isListening else { return }
            self.routedUIDs = routedUIDs
            lastDefaultOutputUID = Self.currentDefaultOutputUID()
            // W1: Baseline für Re-Appear — Geräte, die JETZT schon fehlen,
            // sofort erfassen. Sonst greift die Re-Appear-Erkennung erst nach
            // dem ersten handleDevicesChanged-Event NACH dem Start.
            lastKnownMissingUIDs = routedUIDs.subtracting(Self.presentDeviceUIDs())
            let sysObj = AudioObjectID(kAudioObjectSystemObject)

            let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDefaultOutputChanged()
            }
            let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDevicesChanged()
            }
            let srvBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleServiceRestarted()
            }
            defaultOutputListener = defBlock
            devicesListener = devBlock
            serviceRestartedListener = srvBlock

            AudioObjectAddPropertyListenerBlock(sysObj, &defaultOutputAddress, queue, defBlock)
            AudioObjectAddPropertyListenerBlock(sysObj, &devicesAddress, queue, devBlock)
            AudioObjectAddPropertyListenerBlock(sysObj, &serviceRestartedAddress, queue, srvBlock)

            isListening = true
            logger.log("DeviceLifecycle aktiv (\(routedUIDs.count, privacy: .public) UIDs)")

            // M4: Sample-Rate-Listener mit 1 s Verzögerung registrieren.
            // Verhindert Startup-Feedback: beim Aggregate-Aufbau springt die
            // SR der Sub-Devices kurz → würde ohne Gate sofort einen Restart auslösen.
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                // W7: stop() kann innerhalb der 1 s gelaufen sein — dann hier
                // NICHTS mehr registrieren (Listener würden nie entfernt → Leak).
                guard let self, self.isListening else { return }
                self.registerSRListeners(for: routedUIDs)
                self.srListenersActive = true
            }
        }
    }

    /// Entfernt alle Listener und verwirft ausstehende Restarts. IDEMPOTENT.
    /// MUSS vor dem Verwerfen der Instanz aufgerufen werden.
    public func stop() {
        queue.async { [self] in
            guard isListening else { return }
            let sysObj = AudioObjectID(kAudioObjectSystemObject)
            if let b = defaultOutputListener {
                AudioObjectRemovePropertyListenerBlock(sysObj, &defaultOutputAddress, queue, b)
            }
            if let b = devicesListener {
                AudioObjectRemovePropertyListenerBlock(sysObj, &devicesAddress, queue, b)
            }
            if let b = serviceRestartedListener {
                AudioObjectRemovePropertyListenerBlock(sysObj, &serviceRestartedAddress, queue, b)
            }
            defaultOutputListener = nil
            devicesListener = nil
            serviceRestartedListener = nil
            pendingRestart?.cancel()
            pendingRestart = nil

            // M4: Sample-Rate-Listener entfernen + Reset.
            srListenersActive = false
            pendingSRRestart?.cancel()
            pendingSRRestart = nil
            for entry in srListenerBlocks {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(entry.deviceID, &addr, queue, entry.block)
            }
            srListenerBlocks = []
            lastKnownMissingUIDs = []

            isListening = false
            logger.log("DeviceLifecycle gestoppt")
        }
    }

    // ── Listener-Handler (laufen auf `queue`) ──

    private func handleDefaultOutputChanged() {
        let newUID = Self.currentDefaultOutputUID()
        guard newUID != lastDefaultOutputUID else { return }
        lastDefaultOutputUID = newUID
        logger.log("Default-Output gewechselt → Restart (debounced 2s)")
        scheduleRestart(after: Self.btSettleDelay)   // BT-Kaskaden-Karenz
    }

    private func handleDevicesChanged() {
        let present = Self.presentDeviceUIDs()
        let missing = routedUIDs.subtracting(present)

        // L1: Re-Appear — ein Gerät war zuvor missing, ist jetzt wieder da → Restart.
        // (Der reguläre Verschwinden-Pfad unten deckt nur das Wegfallen ab; ohne
        // Re-Appear würde ein während der Session wieder eingestecktes Gerät nie
        // re-integriert.)
        let nowAvailable = lastKnownMissingUIDs.intersection(present)
        lastKnownMissingUIDs = missing
        if !nowAvailable.isEmpty {
            let uidList = nowAvailable.map { String($0.prefix(10)) }.joined(separator: ",")
            logger.debug("L1: Re-Appear: \(uidList, privacy: .public) → restart")
            scheduleRestart(after: Self.btSettleDelay) // Karenz bis Gerät stabil
            return
        }

        guard !missing.isEmpty else { return }
        logger.log("Geroutetes Gerät verschwunden (\(missing.count, privacy: .public)) → Restart (debounced 3s)")
        scheduleRestart(after: Self.hdmiSettleDelay) // konservativ (HDMI-Sleep)
    }

    private func handleServiceRestarted() {
        logger.log("coreaudiod neu gestartet → sofortiger Restart")
        scheduleRestart(after: 0)
    }

    /// Debounce: letzter Aufruf gewinnt. `delay <= 0` → sofort.
    private func scheduleRestart(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.onNeedsRestart()
        }
        pendingRestart = work
        if delay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // ── M4: Sample-Rate-Listener (laufen auf `queue`) ──

    /// Registriert je einen `kAudioDevicePropertyNominalSampleRate`-Listener pro
    /// gerouteter UID. Ein SR-Wechsel triggert (debounced) ``scheduleSRRestart``.
    private func registerSRListeners(for uids: Set<String>) {
        for uid in uids {
            guard let deviceID = Self.deviceIDForUID(uid) else { continue }
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.srListenersActive else { return }
                self.scheduleSRRestart()
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block)
            srListenerBlocks.append((deviceID: deviceID, block: block))
        }
    }

    /// Debounce (500 ms) für den SR-getriggerten Warm-Restart — vermeidet ein
    /// Restart-Flattern, wenn mehrere Devices ihre SR quasi-gleichzeitig ändern.
    private func scheduleSRRestart() {
        pendingSRRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            self.logger.debug("M4: Sample rate changed → warm restart")
            // W2: Gate SOFORT schließen — der ausgelöste Warm-Restart kann
            // die SR der Sub-Devices selbst nochmal ändern → Ping-Pong-Loop.
            // Wiedereröffnung nach 2 s (Rebuild ≈ 0.2–1 s).
            self.srListenersActive = false
            self.onSampleRateChanged?()
            self.queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isListening else { return }
                self.srListenersActive = true
            }
        }
        pendingSRRestart = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // ── CoreAudio-Helpers (nonisolated static) ──

    /// Übersetzt eine Device-UID in ihre (flüchtige) AudioObjectID.
    private static func deviceIDForUID(_ uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<CFString>.size), uidPtr,
                    &size, devPtr
                )
            }
        }
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func currentDefaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceUID(for: deviceID)
    }

    private static func presentDeviceUIDs() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        var uids = Set<String>()
        for id in ids { if let u = deviceUID(for: id) { uids.insert(u) } }
        return uids
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard err == noErr else { return nil }
        return value as String
    }
}
