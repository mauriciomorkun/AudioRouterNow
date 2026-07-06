//
//  DeviceLifecycleManager.swift
//  AudioRouterKit
//
//  Phase 3 — Hot-Plug, BT-Reconnect-Kaskaden & HDMI-Display-Sleep
//  (Placeholder, Design aus der Issue-Resolution im IMPLEMENTATION_PLAN.md).
//
//  Kern-Design: UID-keyed Desired-State-Reconciliation mit
//  per-Output-Zustandsmaschine. Dieselbe Maschinerie behandelt
//  BT-Reconnect-Kaskaden UND HDMI-Display-Sleep — nur mit
//  transportspezifischen Settle-Parametern (~90 % Code-Identität).
//
//  v3-Lektion H3: Property-Listener-Callbacks enqueuen NUR
//  (auf eine serielle Queue) — niemals synchron im Callback in CoreAudio
//  zurückrufen (Re-Entry-Deadlock in coreaudiod).
//

import Foundation

/// Zustand eines Output-Geräts in der Desired-State-Reconciliation.
public enum DeviceState: Equatable, Sendable {
    /// Gerät ist vorhanden und wird aktiv bespielt.
    case active

    /// Gerät ist gerade verschwunden (`'!dev'` / DeviceIsAlive == 0);
    /// Settle-Karenz läuft — noch KEIN Teardown (HDMI-Sleep und
    /// BT-Kaskaden erzeugen mehrfaches Verschwinden/Erscheinen in Sekunden).
    case disappearing

    /// Gerät ist wieder aufgetaucht; idempotenter Graph-Rebuild läuft.
    case reconnecting

    /// Gerät ist dauerhaft weg (Settle-Karenz abgelaufen); Desired-State
    /// bleibt gespeichert — bei späterem Wiedererscheinen wird automatisch
    /// reconciled.
    case unavailable
}

/// Verwaltet den Lebenszyklus aller Output-Geräte: Hot-Plug,
/// Bluetooth-Reconnect-Kaskaden und HDMI-Display-Sleep.
///
/// Geräte werden über ihre persistente UID (`kAudioDevicePropertyDeviceUID`)
/// identifiziert, NICHT über die flüchtige `AudioObjectID` — nur so bleibt
/// der Desired-State über Disconnects hinweg stabil.
public final class DeviceLifecycleManager: Sendable {

    /// Settle-Karenz für HDMI/DisplayPort-Geräte: Display-Sleep lässt das
    /// Gerät verschwinden und (teils mehrfach) wieder erscheinen —
    /// 3 s warten, bevor Teardown oder Rebuild ausgelöst wird.
    public static let hdmiSettleDelay: TimeInterval = 3.0

    /// Settle-Karenz für Bluetooth-Geräte: Reconnect-Kaskaden
    /// (Gerät verschwindet/erscheint mehrfach in Sekunden) — 2 s Karenz,
    /// danach idempotenter Graph-Rebuild.
    public static let btSettleDelay: TimeInterval = 2.0

    /// Erstellt einen (noch passiven) Lifecycle-Manager.
    public init() {
        // TODO(Phase 3): Property-Listener auf kAudioHardwarePropertyDevices,
        //   kAudioDevicePropertyDeviceIsAlive und
        //   kAudioHardwarePropertyServiceRestarted registrieren.
        //   Callbacks enqueuen NUR auf eine serielle Queue (v3-Lektion H3 —
        //   kein synchroner CoreAudio-Re-Entry, kein Deadlock).
        // TODO(Phase 3): UID-keyed Desired-State-Map + reconcile() auf der
        //   seriellen Queue: Ist-Zustand gegen Soll-Zustand abgleichen,
        //   pro Output-Zustandsmaschine (DeviceState) mit transportspezifischer
        //   Settle-Karenz (hdmiSettleDelay / btSettleDelay).
        // TODO(Phase 3): '!dev' (OSStatus 560227702) als ERWARTETEN Pfad
        //   tolerieren — OutputUnit-API idempotent/fehlertolerant.
        // TODO(Phase 3): Nicht-ASCII-UIDs (CJK-Seriennummern) im
        //   CFString-Bridging + UserDefaults-Roundtrip testen (v3.4.4-Bug-Klasse).
    }

    /// Liefert die transportspezifische Settle-Karenz.
    ///
    /// - Parameter isBluetooth: `true` für BT-Transport, `false` für
    ///   HDMI/DisplayPort (und konservativ alle übrigen Transporte).
    public static func settleDelay(isBluetooth: Bool) -> TimeInterval {
        isBluetooth ? btSettleDelay : hdmiSettleDelay
    }
}
