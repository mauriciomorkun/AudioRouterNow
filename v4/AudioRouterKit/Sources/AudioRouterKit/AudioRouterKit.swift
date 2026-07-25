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
    ///
    /// - Note (F15): Dieser Fall wird derzeit NICHT aus der Engine geworfen —
    ///   TCC-Denied liefert `noErr` + Dauer-Silence (keine public Preflight-API,
    ///   Guideline 2.5.1). Der Verdacht wird ausschließlich über die
    ///   Silence-Heuristik (`FanOutEngine.isSuspectedTCCDenied`) erkannt und ist
    ///   ein reiner UI-Hint. `tccDenied` bleibt im Enum als semantischer Marker
    ///   für eine spätere, verlässliche Erkennung.
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

    /// Die Buffer-Anzahl des erstellten Aggregates stimmt nicht mit der
    /// erwarteten Slot-Mapping-Größe überein — Treiber-Sonderfall oder
    /// veraltete Sub-Device-Konfiguration.
    case aggregateLayoutMismatch(expected: Int, actual: Int)
}

extension RouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tccDenied:
            return "AudioRouterNow needs System Audio Recording permission. Open System Settings → Privacy & Security → Screen & System Audio Recording."
        case .deviceNotFound(let uid):
            return "Output device '\(uid)' is no longer connected. Remove it from Output Targets or reconnect it."
        case .tapFailed(let status):
            return "Could not start audio routing: \(OSStatusMapper.describe(status)). Try unplugging and reconnecting the device, then press Start again."
        case .aggregateLayoutMismatch:
            return "The audio device reported an unexpected channel layout. Remove the device from Output Targets and add it again."
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

// MARK: - OSStatus Mapper

/// Wandelt bekannte CoreAudio OSStatus-Codes in lesbare Fehlerbeschreibungen um.
public enum OSStatusMapper {
    public static func describe(_ status: Int32) -> String {
        switch status {
        case 560227702:  return "the audio device was disconnected"       // kAudioHardwareBadDeviceError '!dev'
        case 560947818:  return "an internal audio object became invalid"  // kAudioHardwareBadObjectError '!obj'
        case 1937010544: return "the audio system is not running"          // kAudioHardwareNotRunningError 'stop'
        case 1970171760: return "the operation is not supported by this device"
        case 1852797029: return "the audio system rejected the operation"
        case 560226676:  return "the audio format is not supported"        // kAudioDeviceUnsupportedFormatError '!dat'
        case 2003329396: return "an unspecified audio system error occurred"
        case 560492391:  return "audio access was denied"                  // kAudioDevicePermissionsError '!hog'
        case -1:         return "an unexpected error occurred"
        default:
            // 4-Char-Code versuchen lesbar zu machen
            let bytes = [
                UInt8((status >> 24) & 0xFF), UInt8((status >> 16) & 0xFF),
                UInt8((status >> 8) & 0xFF),  UInt8(status & 0xFF)
            ]
            let chars = bytes.compactMap { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : nil }
            let code = chars.count == 4 ? "'\(String(chars))'" : "OSStatus \(status)"
            return "audio system error (\(code))"
        }
    }
}
