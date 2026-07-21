//
//  FanOutEngine.swift
//  AudioRouterKit
//
//  Phase 3/4 — Multi-Output Fan-out Engine (Zero-Latency Direct IOProc)
//              mit Output-Latency-Compensation (Phase 4).
//
//  Aggregate(Tap + DefaultOutput + ALL FanOut-Targets) → Single IOProc
//      inInputData (Tap) ─────────────────────────────────────────────────┐
//                                                                         ▼
//      ioOutputData: [DefaultOutput] [FanOut1] [FanOut2] … [FanOutN]
//
//  WICHTIG (Phase-5-Fix): Mit `.mutedWhenTapped` mutet CoreAudio die Quelle am
//  Tap — der Default-Output bekommt auf dem nativen Weg KEIN Signal mehr. Der
//  Direct-IOProc ist die EINZIGE Signalquelle und bespielt deshalb ALLE Slots
//  inkl. Default-Output (= allOutputs[0], bufferOffset 0). Es gibt keinen
//  „skip"-Slot mehr.
//
//  Kein Ring-Buffer, kein Inter-Thread-Delay. CoreAudio's Aggregate Device
//  synchronisiert die Clocks aller Sub-Devices automatisch (kAudioSubTapDriftCompensationKey).
//  Latenz: ≈ 5ms (nur Tap-Capture-Delay, unvermeidbar bei Post-Mix-Tap).
//
//  ## Phase 4 — Output-Latency-Compensation
//  Unterschiedliche Output-Devices haben stark unterschiedliche Hardware-
//  Latenzen (USB ≈ 5–40 ms, Bluetooth ≈ 100–300 ms, AirPlay ≈ 200–2000 ms).
//  Laufen zwei Targets gleichzeitig, spielen sie dasselbe Audio zeitversetzt →
//  hörbares Echo. Lösung: niedrig-latente Targets (inkl. Default-Output) werden
//  per ``DelayLine`` auf `maxLatency` verzögert, bis ALLE Slots synchron sind.
//  Latenzen werden Sample-Rate-normalisiert verglichen (Sekunden, F6), das
//  delayFrames-Ergebnis in der Nominal-Sample-Rate des Aggregates ausgedrückt.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AudioToolbox // re-exportiert die AudioHardware-Tap-APIs (AudioCap-Muster)
import CoreAudio
import Foundation
import os

/// Reine Wert-Beschreibung eines Sub-Devices für die Slot-Planung.
/// CoreAudio-frei → in ``FanOutEngine/computeSlotLayouts`` unit-testbar (F3/F6/F7).
struct DeviceLayoutInfo: Equatable, Sendable {
    /// Erster Buffer-Index dieses Devices in `ioOutputData`.
    let bufferOffset: Int
    /// Gesamt-Output-Latenz in Sekunden (Sample-Rate-normalisiert, F6).
    let latencySeconds: Double
    /// true = 1 Buffer mit N Kanälen; false = 1 Buffer pro Kanal.
    let isInterleaved: Bool
    /// Anzahl Buffer, die dieses Device in `ioOutputData` beiträgt.
    let bufferCount: Int
}

/// Reines Layout-Ergebnis pro OutputConfig (ohne allozierte DelayLine/Scratch).
struct SlotLayout: Equatable, Sendable {
    let bufferIndex: Int
    let channelOffset: Int
    let delayFrames: Int
    /// Buffer-Bereich DIESES Devices in `ioOutputData` (F7 R-Bounds-Check).
    let bufferSpan: Range<Int>
}

/// Multi-Output Fan-out Engine (Phase 3 — Zero-Latency Direct IOProc).
///
/// `@MainActor`, weil Start/Stop und Statusabfragen vom UI-/Kontroll-Pfad
/// kommen. Der Realtime-Pfad (ein einziger Direct-IOProc auf dem Aggregate)
/// läuft NICHT auf dem MainActor; er kommuniziert mit dem MainActor
/// ausschließlich über ``TapIOMetrics``.
///
/// ## ⚠️ PFLICHTREGEL (Phase-1-Crash-Root-Cause, Fix 07.07.2026)
///
/// Der IOProc-Block wird über eine `nonisolated static` Factory erstellt
/// (``makeDirectIOBlock(metrics:slots:)``). Eine inline in einer
/// `@MainActor`-Methode definierte Closure erbt die MainActor-Isolation →
/// `swift_task_checkIsolatedSwift` → `_dispatch_assert_queue_fail` →
/// EXC_BREAKPOINT auf dem CoreAudio-RT-Thread. Voll ausgeführte Root-Cause-
/// Analyse: siehe ``makeDirectIOBlock``.
@MainActor
public final class FanOutEngine {

    // MARK: Konstanten

    /// Anzahl aufeinanderfolgender reiner Silence-Callbacks, ab der ein
    /// TCC-Denied-Verdacht besteht. Bei 48 kHz / 512 Frames ≈ 2,1 s Wandzeit.
    public static let silenceHeuristicThreshold = 200

    /// Obere Grenze der IO-Buffer-Größe pro Callback. Bestimmt DelayLine-
    /// Kapazität (F1), Scratch-Buffer-Größe (F8) und den IOProc-Clamp (F9).
    /// 4096 Frames deckt reguläre und AirPlay-typische IO-Buffer ab; größere
    /// Callbacks werden im IOProc geclamped (RT-sicher, kein Overrun).
    public nonisolated static let maxFramesPerCallback = 4096

    /// Deep-Link zu Systemeinstellungen → Datenschutz → System-Audio-Aufnahme
    /// (einziger MAS-konformer Weg, den User zur Berechtigung zu leiten —
    /// keine public Preflight-API, Guideline 2.5.1).
    public nonisolated static let tccDeepLink =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

    // MARK: State

    /// Aktueller Engine-Status. Wird von der Menu-Bar-UI beobachtet.
    public private(set) var status: RouterStatus = .idle

    /// AudioObjectID des Process Taps (`AudioHardwareCreateProcessTap`).
    private let logger = Logger(subsystem: "com.mauriciomorkun.audiorouternow", category: "FanOutEngine")
    private var tapID = AudioObjectID(kAudioObjectUnknown)

    /// UUID des aktiven Process-Taps — wird für Warm-Restart-Aggregate wiederverwendet.
    private var tapUUID: UUID?

    /// K1: Engine-interne Serialisierung für updateOutputs — verhindert
    /// parallele Rebuilds (zweiter IOProc auf demselben Tap → doppeltes Audio).
    private var isRebuilding = false

    /// AudioObjectID des privaten Aggregate Devices.
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// IOProc-Handle des Tap-IOProcs auf dem Aggregate Device.
    private var tapIoProcID: AudioDeviceIOProcID?

    /// Buffer-Slot-Mapping: welcher Buffer-Index in `ioOutputData` gehört zu
    /// welchem OutputConfig. Wird nach Aggregate-Erstellung gebaut und vom
    /// Direct-IOProc gelesen (Wert-Kopie im Block-Capture — kein self-Capture).
    private var directOutputSlots: [DirectOutputSlot] = []

    /// System-Volume-Tracker — startet mit start(), stoppt mit stop().
    private var volumeTracker: VolumeTracker?

    /// Realtime-sichere Zähler-Brücke (siehe ``TapIOMetrics``).
    private let metrics = TapIOMetrics()

    /// Realtime-sichere Peak-Pegel-Brücke (siehe ``PeakMeters``).
    private let peaks = PeakMeters()

    /// Realtime-sichere Oszilloskop-Brücke (siehe ``WaveformBridge``):
    /// der IOProc schreibt pro Callback einen (min, max)-Mono-Mix-Wert.
    private let waveform = WaveformBridge()

    /// RT-sichere Per-Slot-Gain-Brücke (F16). MainActor schreibt, IOProc liest.
    private let slotGains = SlotGains()
    /// Gewünschte Gains pro Composite-Key "<uid>:<channelOffset>" — überlebt Warm-Restarts.
    private var outputGains: [String: Float32] = [:]

    /// Slot-Identität pro Peak-Index: `slotDeviceKeys[i]` gehört zu `slots[i]`.
    /// Key-Format `"<uid>:<channelOffset>"` (Composite — mehrere Configs teilen
    /// evtl. dieselbe UID). Wird in ``buildAndStartAggregate`` gesetzt und in
    /// ``teardownAggregate`` geleert. Vom MainActor gelesen (Wert-Kopie).
    public private(set) var slotDeviceKeys: [String] = []

    /// IO-Buffer-Grösse (Frames pro Callback) des aktiven Aggregates.
    /// Wird nach erfolgreichem Start gesetzt (Fallback 512, falls unlesbar).
    public private(set) var ioBufferFrames: Int = 512

    /// `true`, wenn seit ``silenceHeuristicThreshold`` Callbacks nur Silence
    /// ankam und noch NIE Audio empfangen wurde → TCC-Denied-Verdacht.
    public var isSuspectedTCCDenied: Bool {
        !metrics.hasReceivedAudio
            && metrics.consecutiveSilentCallbacks >= Self.silenceHeuristicThreshold
    }

    /// Gesamtzahl der Tap-IOProc-Callbacks seit Start (UI-Polling).
    public var totalCallbacks: Int { metrics.totalCallbacks }

    /// `true`, wenn der Tap mindestens ein nicht-stilles Frame empfangen hat.
    public var hasReceivedAudio: Bool { metrics.hasReceivedAudio }

    /// Aktueller Lautstärke-Skalar aus dem VolumeTracker [0.0–1.0]. Polling-sicher.
    public var currentVolumeScale: Float32 {
        volumeTracker?.volumeScale ?? 1.0
    }

    /// Schreibt die Lautstärke auf das Default-Output-Gerät (kAudioDevicePropertyVolumeScalar).
    /// Kein-Op wenn kein Tracker aktiv oder Gerät kein Software-Volume unterstützt.
    public func setSystemVolume(_ vol: Float32) {
        volumeTracker?.setSystemVolume(vol)
    }

    /// Setzt alle Per-Device-Gains (Seed vor start()/updateOutputs()). Key = "<uid>:<channelOffset>".
    public func setOutputGains(_ gains: [String: Float32]) {
        outputGains = gains
        reseedSlotGains()
    }

    /// Live-Update EINES Gains ohne Rebuild. Wirkt im nächsten IOProc-Callback.
    public func setOutputGain(_ gain: Float32, forKey key: String) {
        outputGains[key] = gain
        if let idx = slotDeviceKeys.firstIndex(of: key) {
            if idx >= SlotGains.maxSlots {
                logger.warning("F16/W3: Gain für Slot \(idx, privacy: .public) (Key \(key, privacy: .public)) ignoriert — außerhalb SlotGains.maxSlots=\(SlotGains.maxSlots, privacy: .public)")
                return   // W3.2-Fix: kein Log-Spam bei Slider-Drag; slotGains.set wäre No-Op
            }
            slotGains.set(gain, slotIndex: idx)
        }
    }

    private func reseedSlotGains() {
        slotGains.setAll(slotDeviceKeys.map { outputGains[$0] ?? 1.0 })
    }

    /// Erstellt eine noch nicht gestartete Engine.
    public init() {}

    // MARK: Interne Typen

    /// Zielbeschreibung EINES OutputConfigs innerhalb `ioOutputData` des
    /// Aggregate-Devices.
    ///
    /// Die Buffer-Reihenfolge in `ioOutputData` folgt der Sub-Device-Reihenfolge
    /// des Aggregates; jedes Sub-Device trägt seine Output-Streams bei.
    ///
    /// - Non-interleaved (`mNumberChannels == 1` pro Buffer):
    ///   `bufferIndex` zeigt auf den L-Channel-Buffer; der zugehörige
    ///   R-Buffer liegt bei `bufferIndex + 1`. `channelOffset` ist bereits in
    ///   `bufferIndex` eingerechnet und deshalb 0.
    /// - Interleaved (`mNumberChannels >= 2` in einem Buffer):
    ///   `bufferIndex` zeigt auf den (einzigen) Buffer des Devices;
    ///   `channelOffset` indiziert L/R INNERHALB des interleavten Frames.
    ///
    /// - `@unchecked Sendable`: `bufferIndex`/`channelOffset`/`bufferSpan` sind
    ///   reine Werte; `delay` ist eine `DelayLine`-Referenz (selbst
    ///   `@unchecked Sendable`); `scratchL/R` sind vorab-allozierte RT-Buffer
    ///   (F8), die AUSSCHLIESSLICH vom IOProc-Thread beschrieben und im Teardown
    ///   erst NACH `AudioDeviceStop` freigegeben werden — kein Shared State.
    private struct DirectOutputSlot: @unchecked Sendable {
        let bufferIndex: Int
        let channelOffset: Int
        /// nil = direkt schreiben (höchste Latenz). non-nil = durch DelayLine.
        let delay: DelayLine?
        /// Buffer-Bereich DIESES Devices in `ioOutputData`. F7: R (bufferIndex+1)
        /// wird nur geschrieben, wenn er in dieser Span liegt (sonst Mono-Gerät).
        let bufferSpan: Range<Int>
        /// F8: vorab-allozierte Scratch für den interleaved Delay-Pfad
        /// (ersetzt `withUnsafeTemporaryAllocation` → kein Heap/Stack-Risiko).
        /// Kapazität = `maxFramesPerCallback`. Freigabe in `teardownPartial`.
        let scratchL: UnsafeMutableBufferPointer<Float32>
        let scratchR: UnsafeMutableBufferPointer<Float32>
    }

    // MARK: Start

    /// Startet Tap + einen einzigen Direct-IOProc (Zero-Latency Fan-out).
    ///
    /// API-Sequenz (Research-verifizierte CoreAudio-Tap-Sequenz):
    /// 1. `CATapDescription` (global, unmuted, privat)
    /// 2. `AudioHardwareCreateProcessTap` → `tapID`
    /// 3. Privates Aggregate Device mit Tap UND allen Fan-out-Targets als
    ///    Sub-Devices (`kAudioAggregateDeviceSubDeviceListKey`)
    /// 4. Buffer-Slot-Mapping bauen (welcher `ioOutputData`-Buffer gehört zu
    ///    welchem OutputConfig, `buildDirectOutputSlots`)
    /// 5. Ein Direct-IOProc auf dem Aggregate (`makeDirectIOBlock`) —
    ///    liest inInputData (Tap) und schreibt direkt nach ioOutputData
    /// 6. Aggregate starten (TCC-Prompt HIER)
    ///
    /// `outputs` kann leer sein → dann ist der Default-Output der einzige Slot
    /// (Passthrough mit reiner Tap-Latenz, keine Delay-Kompensation).
    ///
    /// - Throws: ``RouterError/tapFailed(status:)`` bei OSStatus-Fehlern,
    ///   ``RouterError/deviceNotFound(uid:)`` wenn eine Output-UID nicht
    ///   auflösbar ist. Bei jedem Fehler werden bereits erstellte Ressourcen
    ///   in Teardown-Reihenfolge rückabgewickelt.
    ///
    /// - Note: TCC-Denied führt meist zu `noErr` + Silence, NICHT zu einem
    ///   Throw. Den Denied-Fall über ``isSuspectedTCCDenied`` abfragen.
    public func start(outputs: [OutputConfig] = []) throws {
        // Nur wenn nicht bereits routing — doppeltes start() ist ein No-Op.
        guard status != .routing else { return }

        // ── Ebene 1: Process-Tap (TCC-Session) ──────────────────────────
        try createTap()

        // ── Ebene 2: VolumeTracker ──────────────────────────────────────
        // WICHTIG: VOR buildAndStartAggregate — der Direct-IOProc-Block captured
        // den Tracker per Wert. Würde er erst danach erzeugt, hätte der IOProc
        // beim ersten Start keine Volume-Referenz. Der Tracker überlebt jeden
        // Warm-Restart (updateOutputs ruft NUR buildAndStartAggregate).
        if volumeTracker == nil {
            let tracker = VolumeTracker()
            tracker.start()
            volumeTracker = tracker
        }

        // ── Ebene 3: Aggregate + IOProc ─────────────────────────────────
        do {
            // createTap() hat tapUUID gesetzt — defensiv statt Force-Unwrap.
            guard let uuid = tapUUID else { throw RouterError.tapFailed(status: -1) }
            try buildAndStartAggregate(outputs: outputs, tapUUID: uuid)
        } catch {
            teardownPartial()
            throw error
        }
    }

    /// Tauscht Output-Geräte bei laufendem Routing ohne den Tap zu zerstören.
    /// Musikunterbrechung: Aggregate-Teardown + 200 ms Settle + Rebuild (~0.5–1 s).
    /// Tap und TCC-Session bleiben erhalten — kein neuer TCC-Prompt.
    public func updateOutputs(_ outputs: [OutputConfig]) async throws {
        // K1: Serialisierung — nur EIN Rebuild gleichzeitig. Die Tap-UUID wird
        // VOR der Suspension festgehalten, um Identität nachher zu prüfen.
        guard status == .routing, !isRebuilding, let expectedUUID = tapUUID else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        teardownAggregate()
        try await Task.sleep(nanoseconds: 200_000_000)   // 200 ms CoreAudio settle

        // K1: Re-Validierung nach der Suspension. Während der 200 ms kann
        // (a) stopRouting() → teardownPartial() → tapUUID = nil gelaufen sein
        //     (Force-Unwrap-Crash), oder
        // (b) ein voller stop()+start()-Zyklus mit NEUER tapUUID und eigenem
        //     Aggregate (zweiter IOProc → doppeltes Audio).
        // Identitätsvergleich deckt BEIDE Fälle ab.
        guard status == .routing, let uuid = tapUUID, uuid == expectedUUID else {
            logger.debug("K1: updateOutputs abandoned — tap identity changed or status no longer routing")
            return
        }

        do {
            try buildAndStartAggregate(outputs: outputs, tapUUID: uuid)
        } catch {
            // Fallback: vollständiger Stop damit Status konsistent bleibt
            teardownPartial()
            status = .idle
            throw error
        }
    }

    // MARK: Tap-Erstellung

    /// Erstellt den globalen Process-Tap (TCC-Session). Setzt `tapID` + `tapUUID`.
    /// Der Tap überlebt Warm-Restarts — die UUID wird im Aggregate wiederverwendet.
    private func createTap() throws {
        metrics.reset()

        // ── Schritt 1: CATapDescription ─────────────────────────────────
        //
        // ⚠️ KRITISCH: Eigenen Prozess IMMER aus dem Tap ausschliessen.
        //
        // `stereoGlobalTapButExcludeProcesses` erfasst den System-Audio-Mix
        // von ALLEN Prozessen. Unsere Output-IOProcs schreiben Audio auf
        // Ziel-Devices (z. B. MacBook-Lautsprecher) — dieses Audio wird
        // von coreaudiod unserem Prozess zugerechnet und landet ohne diesen
        // Ausschluss erneut im Tap. Resultat: Feedback-Schleife mit
        // Unity-Gain (43 ms Pre-Roll-Delay) → exponentiell akkumulierendes
        // Signal → "Wirrwarr". Das ist das etablierte AudioCap-Muster.
        // Eigene ProcessObjectID für die Exclude-Liste ermitteln.
        // kAudioHardwarePropertyTranslatePIDToProcessObject übersetzt
        // unsere OS-PID in die CoreAudio-interne AudioObjectID des Prozesses.
        // Ohne diese Exclusion würde unser Fan-out-Output wieder in den
        // Global-Tap einfließen (Feedback-Loop).
        let excludeList: [AudioObjectID] = Self.ownProcessObjectID().map { [$0] } ?? []
        if excludeList.isEmpty {
            logger.warning("FanOutEngine: eigene PID nicht zu AudioObjectID auflösbar — Tap ohne Exclude-Liste (Feedback-Loop möglich!)")
        }
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludeList
        )
        // Die UUID wird als Tap-UID im Aggregate referenziert!
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        // Quelle am Tap muten — der Direct-IOProc übernimmt die Wiedergabe für
        // ALLE Outputs inkl. Default-Output. Kein paralleler nativer Signalweg.
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.name = "AudioRouterNow Global Tap (Fan-out — muted at source)"

        // ── Schritt 2: Process Tap erzeugen ─────────────────────────────
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw RouterError.tapFailed(status: err)
        }
        tapID = newTapID
        tapUUID = tapDescription.uuid
    }

    // MARK: Aggregate-Aufbau (Warm-Restart-fähig)

    /// Baut das Aggregate + IOProc und startet die Wiedergabe. Setzt `status`
    /// bei Erfolg auf `.routing`. Erwartet einen bereits erstellten Tap
    /// (`tapUUID` gesetzt). Wirft ohne selbst aufzuräumen — der Aufruf-Kontext
    /// (start/updateOutputs) übernimmt Teardown im catch.
    private func buildAndStartAggregate(outputs: [OutputConfig], tapUUID: UUID) throws {
        let diagLogger = Logger(subsystem: "com.mauriciomorkun.audiorouternow", category: "SlotDiag")

        // ── Schritt 2b: Default-Output-Device-UID lesen ─────────────────
        let defaultOutputUID = try Self.readDefaultOutputDeviceUID()

        // ── Schritt 2c: Master-Device bestimmen (L1 — transport-basiert, deterministisch) ─
        //
        // Rang-0: USB/TB/PCI/FireWire (eigene stabile Clock)
        // Rang-1: Built-in
        // Rang-2: HDMI/DisplayPort
        // Rang-3: Virtual/Unknown
        // Rang-4: Bluetooth/AirPlay — NIEMALS Master (adaptive Buffer = instabile Clock)
        // Tie-Break: lexikografisch kleinste UID (unabhängig von Add-Reihenfolge)
        //
        // Kandidaten = alle konfigurierten UIDs + Default-Output (vor Stale-Filter,
        // damit der Default-Output immer wählbar bleibt).
        var electionUIDs: [String] = [defaultOutputUID]
        var electionSeen = Set<String>([defaultOutputUID])
        for c in outputs where electionSeen.insert(c.uid).inserted {
            electionUIDs.append(c.uid)
        }
        let masterCandidates: [(uid: String, rank: Int)] = electionUIDs.compactMap { uid in
            guard let deviceID = Self.deviceIDForUID(uid) else { return nil }
            return (uid: uid, rank: Self.deviceTransportRank(deviceID))
        }
        let masterUID = Self.electMasterUID(candidates: masterCandidates, fallback: defaultOutputUID)
        let masterRankStr = masterCandidates.first(where: { $0.uid == masterUID })?.rank ?? -1
        let masterPrefix = String(masterUID.prefix(20))
        diagLogger.debug("L1: Master=\(masterPrefix, privacy: .public) rank=\(masterRankStr, privacy: .public)")

        // ── Schritt 2d: allOutputs in subDevice-Reihenfolge aufbauen ─────
        //
        // KRITISCH: allOutputs-Reihenfolge legt die Buffer-Offsets für
        // buildDirectOutputSlots fest und MUSS exakt der SubDeviceList-Reihenfolge
        // entsprechen, damit ioOutputData-Buffer-Indizes korrekt sind.
        //
        // W4: Der Master ist nur Clock-Referenz (SubDeviceList/MainSubDevice) —
        // er bekommt KEINEN synthetischen ch0-Schreib-Slot mehr. Schreib-Slots
        // gibt es nur für (a) den Default-Output und (b) explizit konfigurierte OutputConfigs.
        var allOutputs: [OutputConfig] = []
        var addedConfigKeys = Set<String>()

        func appendConfig(_ c: OutputConfig) {
            let key = "\(c.uid):\(c.channelOffset)"
            if addedConfigKeys.insert(key).inserted { allOutputs.append(c) }
        }

        if masterUID == defaultOutputUID {
            // 1a. Master == Default → ch0-Slot (Default wird immer bespielt).
            appendConfig(OutputConfig(uid: defaultOutputUID, channelOffset: 0))
        } else {
            // 1b. Master ist ein User-Device → NUR die vom User konfigurierten
            //     Slots dieses Devices (kein ungewollter Ch1-2-Slot, W4).
            for config in outputs where config.uid == masterUID { appendConfig(config) }
            // 2. Default-Output als Slave (wird immer bespielt).
            appendConfig(OutputConfig(uid: defaultOutputUID, channelOffset: 0))
        }
        // 3. Alle übrigen User-Configs in Reihenfolge (dedupliziert).
        for config in outputs { appendConfig(config) }

        // ── Schritt 2d-filter: Unavailable UIDs filtern (L1) — graceful degradation ─
        // Statt Throw: konfigurierte Geräte die gerade nicht verbunden sind überspringen.
        // Default-Output ist immer auflösbar → resolvableOutputs ist nie leer.
        // TOCTOU (bewusst akzeptiert): Verschwindet das Master-Device zwischen
        // Elektion (2c) und diesem Re-Resolve, enthält die SubDeviceList den Master,
        // resolvableOutputs aber nicht → Offset-Mismatch, den der F5-Guard
        // (aggregateLayoutMismatch, Schritt 4b) sicher abfängt. Kein Code-Fix nötig.
        let resolvableOutputs = allOutputs.filter { Self.deviceIDForUID($0.uid) != nil }
        let skippedCount = allOutputs.count - resolvableOutputs.count
        if skippedCount > 0 {
            diagLogger.warning("L1: \(skippedCount, privacy: .public) output(s) unavailable — skipped for this session")
        }

        // ── Schritt 3: Privates Aggregate Device ────────────────────────
        //
        // SubDeviceList: masterUID ZUERST (kein DriftKey — Master ist Clock-Quelle),
        // alle weiteren Sub-Devices MIT DriftKey (SRC aktiviert, lockt zum Master).
        // Reihenfolge MUSS exakt resolvableOutputs entsprechen (Buffer-Offsets!).
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: masterUID]]
        var addedSubUIDs = Set<String>([masterUID])
        for config in resolvableOutputs {
            if addedSubUIDs.insert(config.uid).inserted {
                subDevices.append([
                    kAudioSubDeviceUIDKey: config.uid,
                    kAudioSubDeviceDriftCompensationKey: true,   // L1: Slave-Sync
                ])
            }
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouterNow-FanOut-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: masterUID,   // L1: Clock-Master
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != kAudioObjectUnknown else {
            throw RouterError.tapFailed(status: err)
        }
        aggregateDeviceID = newAggregateID

        // ── Schritt 4: Buffer-Slot-Mapping bauen ────────────────────────
        let (slots, expectedBufferCount) = Self.buildDirectOutputSlots(
            allOutputs: resolvableOutputs,
            aggregateDeviceID: newAggregateID
        )
        directOutputSlots = slots

        // Peak-Slot-Identität: 1:1 mit `slots` (computeSlotLayouts erhält die
        // Reihenfolge von resolvableOutputs). Für das UI-Peak-Mapping.
        slotDeviceKeys = resolvableOutputs.map { "\($0.uid):\($0.channelOffset)" }

        reseedSlotGains()   // F16: Slot-Reihenfolge steht jetzt fest, Gains einsäen

        // W3: SlotGains/PeakMeters tragen max. maxSlots Einträge — Slots darüber
        // laufen still mit Unity-Gain. Sichtbar machen statt stumm degradieren.
        if slotDeviceKeys.count > SlotGains.maxSlots {
            logger.warning("F16/W3: \(self.slotDeviceKeys.count, privacy: .public) Output-Slots konfiguriert, SlotGains.maxSlots=\(SlotGains.maxSlots, privacy: .public) — Slots ≥ \(SlotGains.maxSlots, privacy: .public) spielen mit festem Unity-Gain (1.0)")
        }

        // DIAG: Slot-Mapping nach buildDirectOutputSlots loggen
        diagLogger.debug("SlotDiag slots.count=\(slots.count, privacy: .public) expectedBufferCount=\(expectedBufferCount, privacy: .public)")
        for (i, slot) in slots.enumerated() {
            diagLogger.debug("  SlotDiag slot[\(i, privacy: .public)] bufferIndex=\(slot.bufferIndex, privacy: .public) bufferSpan=\(slot.bufferSpan.lowerBound, privacy: .public)..<\(slot.bufferSpan.upperBound, privacy: .public) channelOffset=\(slot.channelOffset, privacy: .public) delayFrames=\(slot.delay?.delayFrames ?? 0, privacy: .public)")
        }

        // ── Schritt 4b: Aggregate-Buffer-Layout validieren (F5) ─────────
        // Das Aggregate MUSS exakt so viele Output-Buffer bereitstellen, wie die
        // Summe der Sub-Device-Buffer erwartet — sonst zeigt unser Slot-Mapping
        // in falsche/fremde Buffer.
        let aggregateBufferCount = Self.outputStreamBufferCount(for: newAggregateID)
        diagLogger.debug("SlotDiag F5: aggregateBufferCount=\(aggregateBufferCount, privacy: .public) expected=\(expectedBufferCount, privacy: .public) match=\(aggregateBufferCount == expectedBufferCount, privacy: .public)")
        guard aggregateBufferCount == expectedBufferCount else {
            throw RouterError.aggregateLayoutMismatch(
                expected: expectedBufferCount, actual: aggregateBufferCount)
        }

        // ── Schritt 5: Ein Direct-IOProc auf dem Aggregate ──────────────
        // ⚠️ Block via nonisolated static Factory — niemals inline (s. o.).
        // Der Block captured nur `metrics` (Sendable) und `slots` (Wert-Kopie).
        let directBlock = Self.makeDirectIOBlock(
            metrics: metrics, slots: slots, volumeTracker: volumeTracker,
            peaks: peaks, waveform: waveform, slotGains: slotGains
        )
        var newProcID: AudioDeviceIOProcID?
        // nil = CoreAudio-eigener IOThread (eigene Queue → assert-Crash-Regel).
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, nil, directBlock)
        guard err == noErr, newProcID != nil else {
            throw RouterError.tapFailed(status: err)
        }
        tapIoProcID = newProcID

        // ── Schritt 6: Aggregate starten — HIER feuert der TCC-Prompt ───
        err = AudioDeviceStart(aggregateDeviceID, tapIoProcID)
        guard err == noErr else {
            throw RouterError.tapFailed(status: err)
        }

        // IO-Buffer-Grösse für die UI-Statistik lesen (Fallback bleibt 512).
        ioBufferFrames = Self.bufferFrameSize(for: aggregateDeviceID) ?? ioBufferFrames

        status = .routing
    }

    // MARK: Stop

    /// Stoppt den Direct-IOProc und gibt alle Ressourcen frei.
    /// Idempotent — mehrfaches Stoppen und Stoppen nach Gerätverlust
    /// (`'!dev'` = 560227702) sind erwartete Pfade, keine Fehler.
    public func stop() {
        teardownPartial()
        status = .idle
    }

    /// Reißt NUR Aggregate + Direct-IOProc ab — Tap (TCC-Session) und
    /// VolumeTracker bleiben erhalten. Grundlage für Warm-Restart
    /// (``updateOutputs(_:)``): der Tap überlebt, es feuert kein neuer
    /// TCC-Prompt. `status` bleibt `.routing`.
    /// OSStatus-Fehler beim Teardown werden bewusst ignoriert
    /// ('!dev' nach Gerätverlust ist hier normal, v3-Lektion).
    private func teardownAggregate() {
        // 1. Direct-IOProc stoppen + zerstören (RT-Pfad zuerst — danach
        //    greift niemand mehr auf ioOutputData zu).
        if let procID = tapIoProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        tapIoProcID = nil

        // 2. Slot-Mapping verwerfen: erst die vorab-allozierten Scratch-Buffer
        //    (F8) freigeben (RT-Handles sind nach AudioDeviceStop tot),
        //    DelayLines werden via ARC beim Array-Clear freigegeben.
        for slot in directOutputSlots {
            slot.scratchL.deallocate()
            slot.scratchR.deallocate()
        }
        directOutputSlots = []

        // Peak-Meter + Slot-Keys zurücksetzen (RT-Pfad ruht nach AudioDeviceStop).
        peaks.reset()
        waveform.reset()
        slotDeviceKeys = []
        ioBufferFrames = 512

        // 3. Aggregate Device zerstören.
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Rückabwicklung ALLER erstellten Ressourcen in korrekter Reihenfolge:
    /// Direct-IOProc → Aggregate → Tap → VolumeTracker.
    /// OSStatus-Fehler beim Teardown werden bewusst ignoriert
    /// ('!dev' nach Gerätverlust ist hier normal, v3-Lektion).
    private func teardownPartial() {
        // 1.–3. Aggregate-Ebene (IOProc, Scratch, Aggregate).
        teardownAggregate()

        // 4. Process Tap zerstören (zuletzt — das Aggregate referenziert ihn).
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapUUID = nil
        }

        // 5. VolumeTracker stoppen (nach AudioDeviceStop — RT-Pfad liest nicht mehr).
        volumeTracker?.stop()
        volumeTracker = nil
    }

    // MARK: Buffer-Slot-Mapping

    /// Baut das Mapping OutputConfig → Buffer-Slot in `ioOutputData` des
    /// Aggregates.
    ///
    /// **Buffer-Reihenfolge:** `allOutputs[0]` ist immer der Default-Output
    /// (bufferOffset = 0 → erster Buffer in `ioOutputData`). Weitere Fan-out-
    /// Targets folgen in Config-Reihenfolge. Jedes Sub-Device trägt so viele
    /// Buffer bei, wie ``outputStreamBufferCount(for:)`` meldet
    /// (non-interleaved: 1 Buffer pro Kanal; interleaved: 1 Buffer gesamt).
    ///
    /// **WICHTIG:** Pro einzigartiger UID wird der Offset nur EINMAL vorgerückt —
    /// auch wenn mehrere OutputConfigs dieselbe UID teilen (z. B. KA6 Ch1-2 +
    /// KA6 Ch3-4 zeigen in denselben Device-Buffer-Bereich, nur mit anderem
    /// Channel-Offset).
    ///
    /// Liest pro einzigartiger UID Buffer-Anzahl, Latenz (Sekunden, F6) und
    /// Layout aus CoreAudio, ruft die reine Planungslogik ``computeSlotLayouts``
    /// (F3/F6/F7) und alloziert DelayLines + Scratch (F8).
    ///
    /// - Returns: die Slots plus `expectedBufferCount` (Summe aller Sub-Device-
    ///   Buffer) für die Aggregate-Validierung (F5).
    private nonisolated static func buildDirectOutputSlots(
        allOutputs: [OutputConfig],
        aggregateDeviceID: AudioObjectID
    ) -> (slots: [DirectOutputSlot], expectedBufferCount: Int) {
        var currentOffset = 0
        var deviceInfoByUID: [String: DeviceLayoutInfo] = [:]

        for config in allOutputs {
            guard deviceInfoByUID[config.uid] == nil else { continue }
            let deviceID = deviceIDForUID(config.uid)
            let bufCount = deviceID.map { outputStreamBufferCount(for: $0) } ?? 2
            // F18: fanOutLatencySeconds = deviceFrames + streamFrames (OHNE safetyFrames).
            // safetyOffset kann zehntausende Frames groß sein (MacBook Spatial Audio) —
            // das ist kein physischer Hardware-Latenz-Wert und würde KA6 etc. zu
            // langen DelayLines zwingen (mehrere Sekunden Anfangsstille).
            let latInfo = deviceID.map { readDeviceLatency(deviceID: $0) }
            let latencySeconds = latInfo.map { $0.fanOutLatencySeconds } ?? 0
            let interleaved = deviceID.map { isDeviceOutputInterleaved($0) } ?? false
            // DIAG: Buffer-Mapping + Latenz pro Device loggen
            let diagLogger = Logger(subsystem: "com.mauriciomorkun.audiorouternow", category: "SlotDiag")
            let totalMs = latInfo.map { $0.totalMilliseconds } ?? -1
            let fanOutMs = latInfo.map { $0.fanOutLatencySeconds * 1000 } ?? -1
            diagLogger.debug("SlotDiag uid=\(String(config.uid.prefix(20)), privacy: .public) bufOffset=\(currentOffset, privacy: .public) bufCount=\(bufCount, privacy: .public) interleaved=\(interleaved, privacy: .public) totalMs=\(totalMs, privacy: .public) fanOutMs=\(fanOutMs, privacy: .public)")
            deviceInfoByUID[config.uid] = DeviceLayoutInfo(
                bufferOffset: currentOffset,
                latencySeconds: latencySeconds,
                isInterleaved: interleaved,
                bufferCount: bufCount
            )
            currentOffset += bufCount
        }

        let aggregateSampleRate = nominalSampleRate(for: aggregateDeviceID)
        let layouts = computeSlotLayouts(
            allOutputs: allOutputs,
            deviceInfoByUID: deviceInfoByUID,
            aggregateSampleRate: aggregateSampleRate
        )

        var slots: [DirectOutputSlot] = []
        slots.reserveCapacity(layouts.count)
        for layout in layouts {
            let delay: DelayLine? = layout.delayFrames >= DelayLine.minimumDelayFrames
                ? DelayLine(delayFrames: layout.delayFrames,
                            maxFramesPerCallback: maxFramesPerCallback)
                : nil
            let scratchL = UnsafeMutableBufferPointer<Float32>.allocate(capacity: maxFramesPerCallback)
            let scratchR = UnsafeMutableBufferPointer<Float32>.allocate(capacity: maxFramesPerCallback)
            scratchL.initialize(repeating: 0)
            scratchR.initialize(repeating: 0)
            slots.append(DirectOutputSlot(
                bufferIndex:   layout.bufferIndex,
                channelOffset: layout.channelOffset,
                delay:         delay,
                bufferSpan:    layout.bufferSpan,
                scratchL:      scratchL,
                scratchR:      scratchR
            ))
        }
        return (slots, currentOffset)
    }

    /// Reine Slot-Planung (F3/F6/F7) — CoreAudio-frei, deshalb unit-testbar.
    ///
    /// - F6: Latenzen werden in SEKUNDEN verglichen (Sample-Rate-normalisiert);
    ///   `delayFrames` wird in der Nominal-Sample-Rate des Aggregates ausgedrückt.
    /// - F7: `bufferSpan` pro Slot = Buffer-Bereich des Devices.
    nonisolated static func computeSlotLayouts(
        allOutputs: [OutputConfig],
        deviceInfoByUID: [String: DeviceLayoutInfo],
        aggregateSampleRate: Double
    ) -> [SlotLayout] {
        let maxLatencySeconds = deviceInfoByUID.values.map(\.latencySeconds).max() ?? 0
        let sr = aggregateSampleRate > 0 ? aggregateSampleRate : 48_000

        var layouts: [SlotLayout] = []
        for config in allOutputs {
            guard let info = deviceInfoByUID[config.uid] else { continue }
            let deltaSeconds = maxLatencySeconds - info.latencySeconds
            let delayFrames = max(0, Int((deltaSeconds * sr).rounded()))
            let span = info.bufferOffset ..< (info.bufferOffset + info.bufferCount)

            let bufferIndex: Int
            let channelOffset: Int
            if info.isInterleaved {
                bufferIndex   = info.bufferOffset
                channelOffset = config.channelOffset
            } else {
                bufferIndex   = info.bufferOffset + config.channelOffset
                channelOffset = 0
            }
            layouts.append(SlotLayout(
                bufferIndex:   bufferIndex,
                channelOffset: channelOffset,
                delayFrames:   delayFrames,
                bufferSpan:    span
            ))
        }
        return layouts
    }

    // MARK: Realtime-IOProc-Factory

    /// Erstellt den einzigen Direct-IOProc-Block (Zero-Latency Fan-out).
    ///
    /// ## ⚠️ nonisolated static — PFLICHT (Phase-1-Crash-Root-Cause, 07.07.2026)
    /// `FanOutEngine` ist `@MainActor`. Eine INLINE in einer `@MainActor`-Methode
    /// definierte Closure ERBT die MainActor-Isolation — auch ohne `self`-Capture.
    /// Swift fügt dann bei jeder Invokation `swift_task_checkIsolatedSwift` →
    /// `dispatch_assert_queue(mainQueue)` ein. CoreAudio ruft den IOProc aber auf
    /// `com.apple.audio.IOThread.client` (HALC_ProxyIOContext::IOWorkLoop), NICHT
    /// auf der Main Queue → `_dispatch_assert_queue_fail` → `brk #0x1` →
    /// EXC_BREAKPOINT. (Die Sandbox war NICHT die Ursache — gleicher Crash mit
    /// app-sandbox=false verifiziert.) Fix: Block in dieser `nonisolated static`
    /// Factory erstellen → keine geerbte Isolation → kein Assert → RT-safe.
    /// **Lektion:** ALLE RT-/CoreAudio-Callbacks in `nonisolated`-Kontext bauen.
    ///
    /// - Parameters:
    ///   - metrics: Sendable-Zähler-Box (kein `self`-Capture!).
    ///   - slots: Buffer-Ziel-Slots (Wert-Kopie; Reihenfolge = Config-Reihenfolge).
    private nonisolated static func makeDirectIOBlock(
        metrics: TapIOMetrics,
        slots: [DirectOutputSlot],
        volumeTracker: VolumeTracker?,
        peaks: PeakMeters,
        waveform: WaveformBridge,
        slotGains: SlotGains
    ) -> AudioDeviceIOBlock {
        // F2: Bei aktiven DelayLines darf Silence NICHT früh raus — sonst wird
        // der Audio-Tail abgeschnitten (Geister-Burst beim nächsten Callback).
        let anySlotHasDelay = slots.contains { $0.delay != nil }
        // F9: Kapazitätsgrenze für Scratch/DelayLine (kein RT-Alloc).
        let maxFrames = maxFramesPerCallback

        // W1: Letzter effektiver Sample-Faktor (vol × gain) pro Slot — für den
        // linearen Gain-Ramp gegen Zipper-Noise. -1 = Sentinel "noch nie gesetzt"
        // (erster Callback snappt statt zu rampen — kein Fade-in-Artefakt).
        // Closure-Capture per Referenz (Heap-Box): Lebensdauer = IOProc-Block,
        // wird bei jedem Rebuild frisch erzeugt (Slot-Indizes remappen!).
        // Subscript-Mutation auf uniquely-referenced Array: kein Alloc → RT-safe.
        var lastSV = [Float32](repeating: -1, count: slots.count)

        let block: AudioDeviceIOBlock = { _, inInputData, _, ioOutputData, _ in
            let inputList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            let outputList = UnsafeMutableAudioBufferListPointer(ioOutputData)

            // ── Silence-Heuristik (W10: NUR Tap-Buffer scannen) ──────────
            // Hardware-Inputs (Mic, Line-In) liefern auch bei TCC-Denied
            // Nicht-Null-Samples → würden die TCC-Warnung dauerhaft
            // unterdrücken (false negative). Tap = letzter Input-Buffer.
            var isSilent = true
            if inputList.count >= 1 {
                let lastIdx = inputList.count - 1
                let scanStart = (inputList[lastIdx].mNumberChannels == 1
                                 && lastIdx >= 1
                                 && inputList[lastIdx - 1].mNumberChannels == 1)
                                ? lastIdx - 1 : lastIdx
                outer: for bi in scanStart...lastIdx {
                    let buffer = inputList[bi]
                    guard let data = buffer.mData else { continue }
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                    let samples = data.assumingMemoryBound(to: Float32.self)
                    for i in 0..<sampleCount where samples[i] != 0 {
                        isSilent = false
                        break outer
                    }
                }
            }
            metrics.record(callbackWasSilent: isSilent)

            // F2: Nur früh raus, wenn KEINE DelayLine zu leeren ist.
            guard (!isSilent || anySlotHasDelay), !slots.isEmpty, inputList.count >= 1
            else {
                if isSilent {
                    peaks.reset()                     // UI-Meter auf 0 bei Stille
                    waveform.push(min: 0, max: 0)     // Oszilloskop scrollt flach weiter
                }
                return
            }

            let bytesPerSample = MemoryLayout<Float32>.size

            // F20: Tap-Buffer = LETZTER Input-Buffer im Aggregate.
            //
            // CoreAudio legt die Input-Buffer-Reihenfolge so fest:
            // [0..N-1] = Sub-Device Hardware-Inputs (KA6 Line-In, MacBook Mic) = meist Stille
            // [N]      = Tap-Audio (CATap, Systemton) — immer am Ende
            //
            // Bisheriger Fehler: inputList[0] war der Hardware-Input → Stille auf ALLEN Outputs,
            // auch wenn Audio erfasst ✓ zeigte (Silence-Check scannt ALLE Buffer → findet Tap in [N]).
            let tapIdx = max(0, inputList.count - 1)
            let first = inputList[tapIdx]

            // ── Tap-Format bestimmen ─────────────────────────────────────
            let frameCount: Int
            let tapLeft: UnsafeMutablePointer<Float32>?
            let tapRight: UnsafeMutablePointer<Float32>?
            var tapInterleavedPtr: UnsafeMutablePointer<Float32>? = nil
            var tapInterleavedStride: Int = 1

            if first.mNumberChannels >= 2 {
                // Interleaved Stereo (häufigster Fall: stereoGlobalTap liefert 2ch interleaved)
                tapInterleavedStride = Int(first.mNumberChannels)
                frameCount = Int(first.mDataByteSize) / (bytesPerSample * tapInterleavedStride)
                tapInterleavedPtr = first.mData?.assumingMemoryBound(to: Float32.self)
                tapLeft = nil; tapRight = nil
            } else if first.mNumberChannels == 1, tapIdx >= 1,
                      inputList[tapIdx - 1].mNumberChannels == 1 {
                // Non-interleaved Stereo: L bei tapIdx-1, R bei tapIdx
                let prevBuf = inputList[tapIdx - 1]
                frameCount = Int(prevBuf.mDataByteSize) / bytesPerSample
                tapLeft  = prevBuf.mData?.assumingMemoryBound(to: Float32.self)
                tapRight = first.mData?.assumingMemoryBound(to: Float32.self)
            } else {
                // Mono oder einziger Buffer
                frameCount = Int(first.mDataByteSize) / bytesPerSample
                tapLeft  = first.mData?.assumingMemoryBound(to: Float32.self)
                tapRight = nil
            }

            guard frameCount > 0 else { return }

            // Phase 2: System-Lautstärke-Multiplikator (RT-safe via os_unfair_lock < 100 ns).
            let vol: Float32 = volumeTracker?.volumeScale ?? 1.0

            // ── Peak-Metering (RT-safe, einzelne O(n)-Passage) ───────────
            // Alle Slots teilen dieselbe Tap-Quelle (channelOffset selektiert
            // nur den Output-Kanal) → ein Source-Peak ist für alle Slots gültig.
            var pkL: Float32 = 0
            var pkR: Float32 = 0
            if let intPtr = tapInterleavedPtr {
                let stride = tapInterleavedStride
                let rIdx = min(1, stride - 1)
                for i in 0..<frameCount {
                    let l = abs(intPtr[i * stride])
                    let r = abs(intPtr[i * stride + rIdx])
                    if l > pkL { pkL = l }
                    if r > pkR { pkR = r }
                }
            } else if let L = tapLeft {
                for i in 0..<frameCount {
                    let l = abs(L[i]); if l > pkL { pkL = l }
                }
                if let R = tapRight {
                    for i in 0..<frameCount { let r = abs(R[i]); if r > pkR { pkR = r } }
                } else {
                    pkR = pkL   // Mono → R spiegelt L
                }
            }
            peaks.record(l: pkL * vol, r: pkR * vol, slotCount: slots.count)

            // ── Waveform: signed mono Min/Max für Oszilloskop (RT-safe) ──
            // Gleiche Tap-Quelle wie das Peak-Metering; mono = (L + R) / 2
            // pro Frame, Min/Max über alle Frames dieses Callbacks. Keine
            // Allokation, reiner Pointer-Scan (O(n), n ≤ maxFrames).
            var wMin: Float32 = 0
            var wMax: Float32 = 0
            if let intPtr = tapInterleavedPtr {
                let stride = tapInterleavedStride
                let rIdx = min(1, stride - 1)
                for i in 0..<frameCount {
                    let mono = (intPtr[i * stride] + intPtr[i * stride + rIdx]) * 0.5
                    if mono < wMin { wMin = mono }
                    if mono > wMax { wMax = mono }
                }
            } else if let L = tapLeft {
                if let R = tapRight {
                    for i in 0..<frameCount {
                        let mono = (L[i] + R[i]) * 0.5
                        if mono < wMin { wMin = mono }
                        if mono > wMax { wMax = mono }
                    }
                } else {
                    for i in 0..<frameCount {
                        let s = L[i]
                        if s < wMin { wMin = s }
                        if s > wMax { wMax = s }
                    }
                }
            }
            waveform.push(min: wMin * vol, max: wMax * vol)

            // ── Direkt in ioOutputData schreiben ─────────────────────────
            for (slotIdx, slot) in slots.enumerated() {
                let bi = slot.bufferIndex
                guard bi < outputList.count else { continue }
                let outBuf = outputList[bi]

                // F9: frameCount gegen REALE Output-Buffer-Größe UND Scratch/
                // DelayLine-Kapazität (maxFrames) clampen.
                let outChannels = max(1, Int(outBuf.mNumberChannels))
                let outCapacity = Int(outBuf.mDataByteSize) / bytesPerSample / outChannels
                let n = min(frameCount, outCapacity, maxFrames)
                guard n > 0 else { continue }

                // F16: effektiver Sample-Faktor = globalVol × Per-Slot-Gain.
                // W1: linearer Ramp gegen Zipper-Noise (kein harter sv-Sprung).
                let g = slotGains.gain(slotIndex: slotIdx)
                let targetSV = vol * g
                var currentSV = lastSV[slotIdx]
                if currentSV < 0 { currentSV = targetSV }    // erster Callback: snap
                let svStep = (targetSV - currentSV) / Float32(n)
                lastSV[slotIdx] = targetSV

                // F21: DelayLine nur wenn n ≤ delayFrames.
                // Bei n > delayFrames (z.B. n=512 > d=230) überlappen Read/Write-
                // Ranges im Ring-Buffer: die letzten (n-d) Output-Frames lesen noch-
                // ungeschriebene Positionen → Stille-Burst → hörbare Artefakte.
                // Fallback: direkt schreiben (kein Delay). Der Sync-Fehler beträgt
                // dann fanOutMs ≤ 5 ms und ist im Hörtest nicht wahrnehmbar.
                if let delay = slot.delay, n <= delay.delayFrames {
                    // ── Delay-Pfad (Phase 4) ─────────────────────────────
                    if outBuf.mNumberChannels == 1 {
                        // Non-interleaved: L → buffers[bi], R → buffers[bi+1].
                        let rbi = bi + 1
                        guard let dstL = outBuf.mData?.assumingMemoryBound(to: Float32.self)
                        else { continue }
                        // F7: R nur, wenn rbi im Buffer-Bereich DIESES Devices liegt.
                        let dstR: UnsafeMutablePointer<Float32>? =
                            (slot.bufferSpan.contains(rbi) && rbi < outputList.count)
                            ? outputList[rbi].mData?.assumingMemoryBound(to: Float32.self)
                            : nil

                        if let intPtr = tapInterleavedPtr {
                            delay.processInterleaved(
                                frameCount: n,
                                src: intPtr, srcStride: tapInterleavedStride, srcOffset: 0,
                                outL: dstL, outR: dstR
                            )
                        } else {
                            delay.process(
                                frameCount: n,
                                inL: tapLeft, inR: tapRight,
                                outL: dstL, outR: dstR
                            )
                        }
                        // Volume + Per-Device-Gain anwenden (Non-Interleaved Delay-Pfad)
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        if svStep != 0 || currentSV != 1.0 {
                            var s = currentSV
                            for i in 0..<n { s += svStep; dstL[i] *= s; dstR?[i] *= s }
                        }
                    } else {
                        // Interleaved Output — F8: vorab-allozierte Scratch.
                        let stride = Int(outBuf.mNumberChannels)
                        let chOffset = slot.channelOffset
                        guard chOffset + 1 < stride,
                              let dst = outBuf.mData?.assumingMemoryBound(to: Float32.self)
                        else { continue }
                        let tL = slot.scratchL.baseAddress!
                        let tR = slot.scratchR.baseAddress!
                        if let intPtr = tapInterleavedPtr {
                            delay.processInterleaved(
                                frameCount: n,
                                src: intPtr, srcStride: tapInterleavedStride, srcOffset: 0,
                                outL: tL, outR: tR
                            )
                        } else {
                            delay.process(frameCount: n,
                                          inL: tapLeft, inR: tapRight,
                                          outL: tL, outR: tR)
                        }
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        var s = currentSV
                        for i in 0..<n {
                            s += svStep
                            dst[i * stride + chOffset]     = tL[i] * s
                            dst[i * stride + chOffset + 1] = tR[i] * s
                        }
                    }
                } else if outBuf.mNumberChannels == 1 {
                    // ── Direkter Pfad (kein Delay) ───────────────────────
                    let rbi = bi + 1
                    guard let dst = outBuf.mData?.assumingMemoryBound(to: Float32.self)
                    else { continue }
                    // F7: R-Bounds gegen Device-Buffer-Span.
                    let dstR: UnsafeMutablePointer<Float32>? =
                        (slot.bufferSpan.contains(rbi) && rbi < outputList.count)
                        ? outputList[rbi].mData?.assumingMemoryBound(to: Float32.self)
                        : nil

                    if let intPtr = tapInterleavedPtr {
                        let stride = tapInterleavedStride
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        var s = currentSV
                        for i in 0..<n {
                            s += svStep
                            dst[i] = intPtr[i * stride] * s
                            dstR?[i] = intPtr[i * stride + min(1, stride - 1)] * s
                        }
                    } else if let L = tapLeft {
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        var s = currentSV
                        for i in 0..<n {
                            s += svStep
                            dst[i] = L[i] * s
                            dstR?[i] = (tapRight?[i] ?? L[i]) * s
                        }
                    }
                } else {
                    // Interleaved Output: L/R innerhalb eines Buffers.
                    let stride = Int(outBuf.mNumberChannels)
                    let chOffset = slot.channelOffset
                    guard chOffset + 1 < stride,
                          let dst = outBuf.mData?.assumingMemoryBound(to: Float32.self)
                    else { continue }

                    if let intPtr = tapInterleavedPtr {
                        let srcStride = tapInterleavedStride
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        var s = currentSV
                        for i in 0..<n {
                            s += svStep
                            dst[i * stride + chOffset]     = intPtr[i * srcStride] * s
                            dst[i * stride + chOffset + 1] = intPtr[i * srcStride + min(1, srcStride - 1)] * s
                        }
                    } else if let L = tapLeft {
                        let R = tapRight
                        // W1: linearer Ramp — s += svStep VOR jeder Multiplikation.
                        var s = currentSV
                        for i in 0..<n {
                            s += svStep
                            dst[i * stride + chOffset]     = L[i] * s
                            dst[i * stride + chOffset + 1] = (R?[i] ?? L[i]) * s
                        }
                    }
                }
            }
        }
        return block
    }

    // MARK: Device-Discovery

    /// Liefert alle verfügbaren (nicht-aggregierten) Output-Devices.
    ///
    /// Filtert Aggregate-Devices (inkl. das eigene private Fan-out-Aggregate)
    /// und Geräte ohne Output-Kanäle heraus, damit die Geräteauswahl in der UI
    /// nur echte, adressierbare Ziele zeigt.
    ///
    /// - Returns: Tupel je Gerät aus persistenter `uid`, User-sichtbarem `name`
    ///   und `channelCount` (Summe der Output-Kanäle über alle Streams).
    /// - Note: `nonisolated static` — reine CoreAudio-Abfrage, MainActor-frei
    ///   vom Kontroll-Layer aufrufbar.
    public nonisolated static func availableOutputDevices()
        -> [(uid: String, name: String, channelCount: Int)]
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        var result: [(uid: String, name: String, channelCount: Int)] = []
        for deviceID in deviceIDs {
            // Nur Devices mit Output-Kanälen.
            guard let channelCount = outputChannelCount(for: deviceID), channelCount > 0
            else { continue }
            // Aggregate-Devices ausschließen (inkl. unser eigenes privates).
            guard !isAggregateDevice(deviceID) else { continue }
            guard let uid = deviceUID(for: deviceID) else { continue }
            let name = deviceName(for: deviceID) ?? uid
            result.append((uid: uid, name: name, channelCount: channelCount))
        }
        return result
    }

    /// Peak-Pegel eines Output-Slots [0.0 … 1.0 linear]. Polling-sicher.
    ///
    /// - Parameter slotIndex: Slot-Index, korrespondiert 1:1 mit ``slotDeviceKeys``.
    /// - Returns: linearer L/R-Peak seit dem letzten IOProc-Update.
    /// - Note: Vom MainActor-Poll (20 fps) gelesen; die Werte werden vom IOProc
    ///   RT-sicher via ``PeakMeters`` (os_unfair_lock) gesetzt.
    public func peakLevel(slotIndex: Int) -> (l: Float32, r: Float32) {
        peaks.level(slotIndex: slotIndex)
    }

    /// Oszilloskop-Snapshot: die letzten `count` (min, max)-Mono-Mix-Werte
    /// (oldest→newest, `count` gegen ``WaveformBridge/capacity`` geklemmt).
    /// Thread-safe via ``WaveformBridge`` — Polling-sicher bei 60fps.
    public func waveformSnapshot(count: Int) -> [(min: Float32, max: Float32)] {
        waveform.snapshot(count: count)
    }

    /// Public UID→AudioObjectID Auflösung für den Kontroll-Layer
    /// (Latenz-Abfrage). Flüchtig (AudioObjectID) — nur zum sofortigen Lesen.
    public nonisolated static func deviceID(forUID uid: String) -> AudioObjectID? {
        deviceIDForUID(uid)
    }

    // MARK: Master-Elektion (L1 — transport-basiert, deterministisch)

    /// Liest `kAudioDevicePropertyTransportType` und mappt ihn auf einen
    /// Clock-Master-Rang (kleiner = besser). BT/AirPlay = Rang 4 (nie Master).
    private nonisolated static func deviceTransportRank(_ deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        switch value {
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire:
            return 0   // Beste Hardware-Clock
        case kAudioDeviceTransportTypeBuiltIn:
            return 1
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:
            return 2
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeUnknown,
             kAudioDeviceTransportTypeAVB:
            return 3
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay:
            return 4   // Niemals Master (adaptive Buffer, Netzwerk-Jitter)
        default:
            return 3
        }
    }

    /// Wählt den Clock-Master deterministisch nach Transport-Typ und UID.
    /// BT/AirPlay werden niemals Master (Rang 4).
    /// Tie-Break: lexikografisch kleinste UID (Reihenfolge-unabhängig).
    nonisolated static func electMasterUID(
        candidates: [(uid: String, rank: Int)],
        fallback: String
    ) -> String {
        guard let best = candidates.min(by: { l, r in
            l.rank != r.rank ? l.rank < r.rank : l.uid < r.uid
        }), best.rank < 4 else {
            return fallback
        }
        return best.uid
    }

    // MARK: Device-Property-Helpers (nonisolated static)

    /// Übersetzt die OS-PID des laufenden Prozesses in die CoreAudio-interne
    /// `AudioObjectID` des Prozesses.
    ///
    /// Wird genutzt, um den eigenen Prozess aus dem Global-Tap auszuschließen
    /// und so eine digitale Feedback-Schleife zu verhindern (AudioCap-Muster).
    ///
    /// - Returns: `AudioObjectID` des eigenen Prozesses, oder `nil` wenn die
    ///   Übersetzung fehlschlägt (z. B. Sandbox-Einschränkung).
    private nonisolated static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pid) { pidPtr in
            withUnsafeMutablePointer(to: &processObjectID) { objPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<pid_t>.size),
                    pidPtr,
                    &outSize,
                    objPtr
                )
            }
        }
        guard err == noErr, processObjectID != kAudioObjectUnknown else { return nil }
        return processObjectID
    }

    /// Liest `kAudioDevicePropertyStreamConfiguration` (Output-Scope) →
    /// Summe der Output-Kanäle über alle Streams.
    private nonisolated static func outputChannelCount(for deviceID: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPtr) == noErr
        else { return nil }

        let bufferList = UnsafeMutableAudioBufferListPointer(listPtr)
        var total = 0
        for buffer in bufferList {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    /// Gibt die Anzahl der Output-Stream-Buffer zurück, die ein Device in das
    /// `ioOutputData` des Aggregates einbringt (non-interleaved: 1 Buffer pro
    /// Kanal; interleaved: 1 Buffer für alle Kanäle).
    ///
    /// Grundlage für die Offset-Akkumulation in ``buildDirectOutputSlots``.
    private nonisolated static func outputStreamBufferCount(for deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPtr) == noErr
        else { return 0 }
        return Int(listPtr.pointee.mNumberBuffers)
    }

    /// `true`, wenn das Output-Layout des Devices INTERLEAVED ist, d. h. genau
    /// EIN Stream-Buffer alle Kanäle (`mNumberChannels >= 2`) trägt.
    /// `false` für non-interleaved (1 Buffer pro Kanal) oder unbekannt.
    private nonisolated static func isDeviceOutputInterleaved(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPtr) == noErr
        else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(listPtr)
        return bufferList.count == 1 && bufferList[0].mNumberChannels >= 2
    }

    /// `true`, wenn das Device ein Aggregate ist — echte Aggregates besitzen
    /// die Property `kAudioAggregateDevicePropertyComposition`.
    private nonisolated static func isAggregateDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &address)
    }

    /// Liest `kAudioDevicePropertyDeviceUID` (CJK-sicher via CFString-Bridge).
    private nonisolated static func deviceUID(for deviceID: AudioObjectID) -> String? {
        stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Liest `kAudioObjectPropertyName` (User-sichtbarer Gerätename).
    private nonisolated static func deviceName(for deviceID: AudioObjectID) -> String? {
        stringProperty(of: deviceID, selector: kAudioObjectPropertyName)
    }

    /// Gemeinsamer CFString-Property-Reader (toll-free bridged).
    private nonisolated static func stringProperty(
        of deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        return value as String
    }

    /// Wandelt eine persistente Device-UID in die (flüchtige) AudioObjectID
    /// (`kAudioHardwarePropertyTranslateUIDToDevice`).
    private nonisolated static func deviceIDForUID(_ uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
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

    /// Liest die UID des aktuellen Default-Output-Devices
    /// (CoreAudio-Helper — UID statt AudioObjectID: stabil über Hot-Plug,
    /// CJK-sicher).
    /// W3: Public Helper — UID des aktuellen Default-Output-Devices, `nil`
    /// bei Fehler. Für den Lifecycle-Layer: Der Default-Output ist immer Teil
    /// des Aggregates, seine SR-Wechsel müssen deshalb ebenso einen
    /// Warm-Restart auslösen wie die der konfigurierten Targets.
    public nonisolated static func currentDefaultOutputUID() -> String? {
        try? readDefaultOutputDeviceUID()
    }

    private nonisolated static func readDefaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw RouterError.deviceNotFound(uid: "default-output")
        }
        guard let uid = deviceUID(for: deviceID) else {
            throw RouterError.deviceNotFound(uid: "default-output")
        }
        return uid
    }

    /// Liest `kAudioDevicePropertyNominalSampleRate` (Fallback 48000).
    /// Für das Aggregate genutzt, um F6-delayFrames in dessen Sample-Rate zu
    /// berechnen.
    private nonisolated static func nominalSampleRate(for deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    /// Liest `kAudioDevicePropertyBufferFrameSize` (Output-Scope) des Aggregates.
    /// Nicht RT-safe — nur im Start-/Rebuild-Pfad aufrufen.
    private nonisolated static func bufferFrameSize(for deviceID: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return Int(value)
    }
}
