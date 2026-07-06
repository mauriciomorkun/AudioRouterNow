//
//  TapEngine.swift
//  AudioRouterKit
//
//  Phase 1 PoC — Go/No-Go Gate
//
//  Placeholder für den CoreAudio Process Tap. Die echte Implementierung
//  (Phase 1) nutzt:
//
//    - `CATapDescription` (macOS 14.4+) — systemweiter Tap via
//      `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`
//    - `AudioHardwareCreateProcessTap(_:_:)` → Tap-AudioObjectID
//    - Private Aggregate Device (`kAudioAggregateDeviceIsPrivateKey`) mit
//      Tap als Sub-Tap, IOProc liest den Tap-Stream
//
//  ⚠️ Phase-1-Risiken laut IMPLEMENTATION_PLAN.md, die der PoC beweisen muss:
//    - CATap unter App-Sandbox fragil (DGR-Labs-Befund): Aggregate-Lifecycle
//      und coreaudiod-Restart explizit testen, BEVOR Phase 2 startet
//    - TCC-Prompt-Flow (NSAudioCaptureUsageDescription) im Sandbox-Kontext
//    - Drift-Underruns nach Minuten sind OHNE Phase 3 (PI-Regler) normal —
//      nicht als Bug werten
//

import Foundation

/// Der System-Audio-Tap: erfasst den globalen Audio-Output-Stream und speist
/// ihn in die Fan-out-Pipeline (Phase 2).
///
/// `@MainActor`, weil Start/Stop und Statusabfragen vom UI-/Kontroll-Pfad
/// kommen. Der Realtime-Pfad (IOProc-Callbacks, Phase 1+) läuft NICHT auf
/// dem MainActor, sondern schreibt lock-frei in ``SPSCRingBuffer``-Instanzen.
@MainActor
public final class TapEngine {

    /// Aktueller Engine-Status. Wird von der Menu-Bar-UI beobachtet.
    public private(set) var status: RouterStatus = .idle

    /// Erstellt eine noch nicht gestartete Engine.
    public init() {}

    /// Startet den Process Tap.
    ///
    /// Phase-1-Implementierung:
    /// 1. TCC-Berechtigung prüfen/anfordern → bei Ablehnung ``RouterError/tccDenied``
    /// 2. `CATapDescription` erzeugen, `AudioHardwareCreateProcessTap` aufrufen
    ///    → bei Fehler ``RouterError/tapFailed(status:)``
    /// 3. Privates Aggregate Device erstellen, IOProc registrieren
    ///
    /// - Throws: ``RouterError``, wenn der Tap nicht aufgebaut werden kann.
    public func start() throws {
        // TODO(Phase 1): CATapDescription + AudioHardwareCreateProcessTap.
        // TODO(Phase 1): TCC-Preflight (kTCCServiceAudioCapture).
        // TODO(Phase 1): Privates Aggregate Device + AudioDeviceCreateIOProcIDWithBlock.
        // TODO(Phase 3): ProcessInfo.beginActivity über die GESAMTE Laufzeit
        //                halten (App-Nap-Schutz für den 50ms-Regel-Thread).
        status = .routing
    }

    /// Stoppt den Tap und gibt alle CoreAudio-Ressourcen frei.
    ///
    /// Muss idempotent sein: Mehrfaches Stoppen und Stoppen nach
    /// Gerätverlust (`'!dev'`) sind erwartete Pfade, keine Fehler.
    public func stop() {
        // TODO(Phase 1): AudioDeviceStop + AudioDeviceDestroyIOProcID.
        // TODO(Phase 1): AudioHardwareDestroyProcessTap + Aggregate-Teardown.
        status = .idle
    }
}
