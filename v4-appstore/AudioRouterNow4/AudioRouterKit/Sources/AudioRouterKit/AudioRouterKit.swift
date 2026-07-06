//
//  AudioRouterKit.swift
//  AudioRouterKit
//
//  Public API surface für AudioRouterNow v4.0 (App Store Rewrite).
//
//  Phase 0: Typ-Definitionen ohne CoreAudio-Abhängigkeit — kompiliert und
//  testet ohne echte Hardware. Die eigentliche Engine (Process Tap,
//  Fan-out, PI-Regler) folgt in Phase 1–3 gemäß IMPLEMENTATION_PLAN.md.
//

import Foundation

/// Fehler, die beim Aufbau oder Betrieb der Audio-Routing-Pipeline auftreten können.
///
/// `RouterError` deckt die drei kritischen Fehlerklassen des v4-Designs ab:
/// TCC-Verweigerung (Audio-Capture-Permission), verschwundene Geräte
/// (Hot-Plug / HDMI-Display-Sleep / BT-Reconnect) und Tap-Erstellungsfehler
/// (`AudioHardwareCreateProcessTap`).
public enum RouterError: Error, Equatable, Sendable {
    /// Der User hat die TCC-Berechtigung für System-Audio-Capture verweigert
    /// (NSAudioCaptureUsageDescription / `kTCCServiceAudioCapture`).
    ///
    /// Recovery: User zu Systemeinstellungen → Datenschutz → Bildschirm- &
    /// System-Audio-Aufnahme führen.
    case tccDenied

    /// Das angeforderte Output-Gerät wurde nicht gefunden.
    ///
    /// - Parameter uid: Die persistente Geräte-UID (`kAudioDevicePropertyDeviceUID`).
    ///   UID-basiert statt AudioObjectID, damit Hot-Plug-Reconciliation
    ///   (siehe ``DeviceLifecycleManager``) stabil bleibt.
    case deviceNotFound(uid: String)

    /// `AudioHardwareCreateProcessTap` ist fehlgeschlagen.
    ///
    /// - Parameter status: Der zugrunde liegende CoreAudio-`OSStatus`
    ///   (z. B. `'!dev'` = 560227702 bei verschwundenem Gerät — laut Plan
    ///   ein *erwarteter* Pfad, kein Fatal-Error).
    case tapFailed(status: Int32)
}

extension RouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tccDenied:
            return "System audio capture permission was denied."
        case .deviceNotFound(let uid):
            return "Audio device not found: \(uid)"
        case .tapFailed(let status):
            return "Failed to create process tap (OSStatus \(status))."
        }
    }
}

/// Der aggregierte Zustand der Routing-Engine.
///
/// Wird von der Menu-Bar-UI (Phase 4, Health-Ampel) konsumiert.
public enum RouterStatus: Equatable, Sendable {
    /// Engine ist initialisiert, aber kein Tap aktiv.
    case idle

    /// Tap läuft, Audio wird auf mindestens ein Output-Gerät verteilt.
    case routing

    /// Engine ist in einem Fehlerzustand.
    case error(RouterError)

    /// `true`, wenn aktiv geroutet wird.
    public var isRouting: Bool {
        self == .routing
    }

    /// `true`, wenn ein Fehler vorliegt.
    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
