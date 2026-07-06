//
//  TapEngine.swift
//  AudioRouterKit
//
//  Phase 1 PoC — Go/No-Go Gate (Wegwerf-Code, wird in Phase 2 refaktoriert)
//
//  Echte CoreAudio-Process-Tap-Implementierung (macOS 14.4+):
//
//    - `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` — systemweiter
//      Stereo-Mixdown-Tap des globalen Audio-Outputs
//    - `AudioHardwareCreateProcessTap(_:_:)` → Tap-AudioObjectID
//    - Privates Aggregate Device (`kAudioAggregateDeviceIsPrivateKey`) mit dem
//      Tap als Sub-Tap (`kAudioAggregateDeviceTapListKey`), IOProc liest den
//      Tap-Stream aus `inInputData`
//
//  TCC-Verhalten (Research-verifiziert, AudioCap + Apple-Doku):
//    - Der TCC-Prompt ("System Audio Recording Only", eigene Kategorie ab
//      macOS 14.4) feuert beim ERSTEN `AudioDeviceStart` auf einem Aggregate
//      mit Tap — NICHT bei `AudioHardwareCreateProcessTap`.
//    - Es gibt KEINE public API zum Abfragen/Anfordern der Permission
//      (Apple-Doku wörtlich). AudioCaps TCC-SPI-Pfad wird NICHT portiert
//      (MAS Guideline 2.5.1) → Silence-Heuristik ist der einzige
//      Erkennungsweg für Denied.
//    - Denied/Headless-CI: alle Calls liefern typischerweise `noErr`, der
//      IOProc läuft und liefert NUR Silence — kein Error-Code, kein Crash.
//
//  ⚠️ Phase-1-Risiken laut IMPLEMENTATION_PLAN.md, die der PoC beweisen muss:
//    - CATap unter App-Sandbox fragil (DGR-Labs-Befund): Aggregate-Lifecycle
//      und coreaudiod-Restart explizit testen, BEVOR Phase 2 startet
//    - TCC-Prompt-Flow (NSAudioCaptureUsageDescription manuell in Info.plist,
//      fehlt im Xcode-Dropdown) im Sandbox-Kontext; Sandbox braucht zusätzlich
//      `com.apple.security.device.audio-input`
//    - Drift-Underruns nach Minuten sind OHNE Phase 3 (PI-Regler) normal —
//      nicht als Bug werten
//

import AudioToolbox // re-exportiert die AudioHardware-Tap-APIs (AudioCap-Muster)
import CoreAudio
import Foundation
import os

// MARK: - IO-Metriken (Realtime-Pfad ↔ MainActor-Brücke)

/// Zähler, die der Realtime-IOProc beschreibt und der MainActor liest.
///
/// PoC-Kompromiss: `OSAllocatedUnfairLock` statt lock-freier Atomics.
/// Ein unfair lock im Realtime-Callback ist für den Phase-1-PoC akzeptabel
/// (nur zwei Int-Inkremente, MainActor pollt selten), MUSS aber in Phase 2
/// durch den lock-freien ``SPSCRingBuffer``-Pfad + swift-atomics ersetzt
/// werden (v3-Lektion: keine Locks im 50ms-Regel-Pfad).
final class TapIOMetrics: @unchecked Sendable {

    private struct State {
        var totalCallbacks: Int = 0
        var consecutiveSilentCallbacks: Int = 0
        var hasReceivedAudio: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Wird aus dem IOProc-Callback aufgerufen (NICHT MainActor).
    /// Kein throw, kein Allocation-lastiger Pfad — nur zählen.
    func record(callbackWasSilent: Bool) {
        state.withLock { s in
            s.totalCallbacks += 1
            if callbackWasSilent {
                s.consecutiveSilentCallbacks += 1
            } else {
                s.consecutiveSilentCallbacks = 0
                s.hasReceivedAudio = true
            }
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    var totalCallbacks: Int { state.withLock { $0.totalCallbacks } }
    var consecutiveSilentCallbacks: Int { state.withLock { $0.consecutiveSilentCallbacks } }
    var hasReceivedAudio: Bool { state.withLock { $0.hasReceivedAudio } }
}

// MARK: - TapEngine

/// Der System-Audio-Tap: erfasst den globalen Audio-Output-Stream und speist
/// ihn (ab Phase 2) in die Fan-out-Pipeline.
///
/// `@MainActor`, weil Start/Stop und Statusabfragen vom UI-/Kontroll-Pfad
/// kommen. Der Realtime-Pfad (IOProc-Callback) läuft NICHT auf dem MainActor;
/// er schreibt nur in ``TapIOMetrics`` und (ab Phase 2) lock-frei in
/// ``SPSCRingBuffer``-Instanzen.
@MainActor
public final class TapEngine {

    // MARK: Konstanten

    /// Anzahl aufeinanderfolgender reiner Silence-Callbacks, ab der ein
    /// TCC-Denied-Verdacht besteht. Bei 48 kHz / 512 Frames ≈ 2,1 s Wandzeit.
    /// ⚠️ Echtes Silence (keine Quelle spielt) ist von Denied NICHT
    /// deterministisch unterscheidbar — die UX muss beide Fälle nennen
    /// (Plan-Restrisiko, §Issue 1).
    public static let silenceHeuristicThreshold = 200

    /// Deep-Link zu Systemeinstellungen → Datenschutz → System-Audio-Aufnahme.
    /// ⚠️ Auf 14.4 + aktuellem macOS verifizieren (Plan warnt vor Versionsdrift).
    public nonisolated static let tccDeepLink =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

    // MARK: State

    /// Aktueller Engine-Status. Wird von der Menu-Bar-UI beobachtet.
    public private(set) var status: RouterStatus = .idle

    /// AudioObjectID des Process Taps (`AudioHardwareCreateProcessTap`).
    private var tapID = AudioObjectID(kAudioObjectUnknown)

    /// AudioObjectID des privaten Aggregate Devices.
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// IOProc-Handle auf dem Aggregate Device.
    private var ioProcID: AudioDeviceIOProcID?

    /// Realtime-sichere Zähler-Brücke (siehe ``TapIOMetrics``).
    private let metrics = TapIOMetrics()

    /// Dispatch-Queue für den IOProc-Callback (CoreAudio ruft den Block hier).
    private let ioQueue = DispatchQueue(
        label: "com.mauriciomorkun.audiorouternow.tap-io",
        qos: .userInteractive
    )

    /// Anzahl aufeinanderfolgender Silence-Callbacks seit dem letzten
    /// Nicht-Silence-Callback (für die TCC-Heuristik).
    private var silenceFrameCount: Int { metrics.consecutiveSilentCallbacks }

    /// Gesamtzahl der IOProc-Callbacks seit Start.
    private var totalFrameCount: Int { metrics.totalCallbacks }

    /// `true`, wenn seit ``silenceHeuristicThreshold`` Callbacks nur Silence
    /// ankam und noch NIE Audio empfangen wurde → TCC-Denied-Verdacht.
    /// Kein throw im Realtime-Callback — der Kontroll-Pfad pollt dieses Flag.
    public var isSuspectedTCCDenied: Bool {
        !metrics.hasReceivedAudio
            && metrics.consecutiveSilentCallbacks >= Self.silenceHeuristicThreshold
    }

    /// Erstellt eine noch nicht gestartete Engine.
    public init() {}

    // MARK: Start

    /// Startet den Process Tap.
    ///
    /// API-Sequenz (Research-verifiziert, AudioCap-Muster):
    /// 1. `CATapDescription` (global, unmuted, privat)
    /// 2. `AudioHardwareCreateProcessTap` → `tapID`
    /// 3. Privates Aggregate Device mit Tap in `kAudioAggregateDeviceTapListKey`
    /// 4. `AudioDeviceCreateIOProcIDWithBlock` (Silence-Heuristik im Callback)
    /// 5. `AudioDeviceStart` — HIER feuert der TCC-Prompt (erster IO-Start)
    ///
    /// In CI/headless WIRD dieser Pfad scheitern oder nur Silence liefern —
    /// das ist korrektes, erwartetes Verhalten (kein Crash-Pfad, nur OSStatus).
    ///
    /// - Throws: ``RouterError``, wenn der Tap nicht aufgebaut werden kann.
    ///   Bei jedem Fehler nach Tap-Erstellung werden bereits erstellte
    ///   Ressourcen in Teardown-Reihenfolge rückabgewickelt.
    public func start() throws {
        // Nur aus .idle starten — doppeltes start() ist ein No-Op.
        guard status == .idle else { return }

        metrics.reset()

        // ── Schritt 1: CATapDescription ─────────────────────────────────
        // Globaler Stereo-Mixdown des gesamten System-Outputs, keine
        // Prozesse ausgeschlossen (AudioRouterNow-Fall, Plan §Phase 1).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        // Die UUID wird unten als Tap-UID im Aggregate referenziert!
        tapDescription.uuid = UUID()
        // Privat: Tap für andere Prozesse/Audio-MIDI-Setup unsichtbar.
        tapDescription.isPrivate = true
        // WICHTIG: Quelle NICHT muten — der User hört sein Audio weiter
        // (v4-Routing ist additiv, kein Umleiten wie bei .mutedWhenTapped).
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "AudioRouterNow Global Tap (Phase 1 PoC)"

        // ── Schritt 2: Process Tap erzeugen ─────────────────────────────
        // Kein TCC-Prompt hier — der feuert erst bei AudioDeviceStart.
        // In CI liefert dieser Call typischerweise trotzdem noErr + gültige ID.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            // '!dev' (560227702) ist ein ERWARTETER Pfad (v3-Lektion) —
            // der Payload-Status muss unverändert durchgereicht werden.
            throw RouterError.tapFailed(status: err)
        }
        tapID = newTapID

        // Ab hier gilt: bei JEDEM Fehler zuerst partielle Ressourcen
        // rückabwickeln (teardownPartial), dann werfen.

        // ── Schritt 2b: Default-Output-Device-UID lesen ─────────────────
        // Das Aggregate braucht ein reales Output-Device als Main-Sub-Device
        // (UID-basiert, NICHT AudioObjectID — Hot-Plug-Reconciliation,
        // v3-Lektion / RouterError.deviceNotFound-Vertrag).
        let outputUID: String
        do {
            outputUID = try Self.readDefaultOutputDeviceUID()
        } catch {
            teardownPartial()
            throw error
        }

        // ── Schritt 3: Privates Aggregate Device ────────────────────────
        // Exakte Keys AudioCap-verifiziert (Research §1 Schritt 4).
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouterNow-PoC-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // Main-Sub-Device = aktuelles Default-Output (Clock-Master).
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Privat: versteckt das Device vor anderen Apps/Audio-MIDI-Setup.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Tap startet automatisch mit dem Device-IO.
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            // Der Tap wird über die UUID der CATapDescription referenziert.
            // Drift-Kompensation an — Underruns ohne Phase-3-PI-Regler sind
            // trotzdem normal (Plan-Hinweis).
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != kAudioObjectUnknown else {
            teardownPartial() // Tap wieder zerstören
            throw RouterError.tapFailed(status: err)
        }
        aggregateDeviceID = newAggregateID

        // ── Schritt 4: IOProc registrieren ──────────────────────────────
        // Tap-Audio kommt in inInputData (AudioDeviceIOBlock-Signatur).
        // Phase 1: NUR zählen + Silence-Heuristik. Kein throw, keine
        // MainActor-Berührung, keine Allocations im Callback.
        // TODO(Phase 2): Fan-out — Frames aus inInputData lock-frei in je
        //                einen SPSCRingBuffer pro Ziel-Device schreiben.
        let ioMetrics = metrics // Sendable-Box capturen, NICHT self (@MainActor)
        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, ioQueue) {
            _, inInputData, _, _, _ in
            // Silence-Check: alle Input-Buffer als Float32 scannen,
            // Early-Exit beim ersten Nicht-Null-Sample.
            var isSilent = true
            let bufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            outer: for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.assumingMemoryBound(to: Float32.self)
                for i in 0..<sampleCount where samples[i] != 0 {
                    isSilent = false
                    break outer
                }
            }
            ioMetrics.record(callbackWasSilent: isSilent)
        }
        guard err == noErr, newProcID != nil else {
            teardownPartial() // Aggregate + Tap zerstören
            throw RouterError.tapFailed(status: err)
        }
        ioProcID = newProcID

        // ── Schritt 5: IO starten ───────────────────────────────────────
        // HIER feuert der TCC-Prompt (NSAudioCaptureUsageDescription).
        // Denied/headless: oft trotzdem noErr, dann nur Silence im Callback
        // → isSuspectedTCCDenied greift (einziger Erkennungsweg, keine
        // public Preflight-API).
        err = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard err == noErr else {
            teardownPartial() // IOProc + Aggregate + Tap zerstören
            throw RouterError.tapFailed(status: err)
        }

        // TODO(Phase 3): ProcessInfo.beginActivity über die GESAMTE Laufzeit
        //                halten (App-Nap-Schutz für den 50ms-Regel-Thread).

        status = .routing
    }

    // MARK: Stop

    /// Stoppt den Tap und gibt alle CoreAudio-Ressourcen frei.
    ///
    /// Idempotent: Mehrfaches Stoppen und Stoppen nach Gerätverlust
    /// (`'!dev'` = 560227702) sind erwartete Pfade, keine Fehler.
    /// Teardown-Reihenfolge exakt umgekehrt zum Aufbau (AudioCap-verifiziert):
    /// Stop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap.
    public func stop() {
        teardownPartial()
        status = .idle
    }

    /// Rückabwicklung aller BEREITS erstellten Ressourcen, in korrekter
    /// Reihenfolge. Sicher bei partiellem Aufbau (Fehlerpfade in `start()`)
    /// und bei nie gestarteter Engine — jeder Schritt läuft nur, wenn die
    /// jeweilige ID existiert. OSStatus-Fehler beim Teardown werden bewusst
    /// ignoriert ('!dev' nach Gerätverlust ist hier normal, v3-Lektion).
    private func teardownPartial() {
        // 1. IO stoppen + IOProc zerstören (nur wenn IOProc existiert).
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil

        // 2. Aggregate Device zerstören.
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        // 3. Process Tap zerstören (zuletzt — das Aggregate referenziert ihn).
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Helpers

    /// Liest die UID des aktuellen Default-Output-Devices.
    /// UID statt AudioObjectID (kAudioDevicePropertyDeviceUID) — stabil über
    /// Hot-Plug hinweg; CJK-UIDs müssen den CFString→String-Roundtrip
    /// überleben (v3.4.4-Bug-Klasse).
    private static func readDefaultOutputDeviceUID() throws -> String {
        // Default-Output-Device-ID vom System-Objekt lesen.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw RouterError.deviceNotFound(uid: "default-output")
        }

        // UID des Devices lesen (CFString, toll-free bridged).
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPtr)
        }
        guard err == noErr else {
            throw RouterError.deviceNotFound(uid: "default-output")
        }
        return uid as String
    }
}
