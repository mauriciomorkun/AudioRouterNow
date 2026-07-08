//
//  FanOutEngine.swift
//  AudioRouterKit
//
//  Phase 2 — Multi-Output Fan-out Engine.
//
//  Erweitert die Phase-1-Tap-Logik (TapEngine) um echten Fan-out:
//
//    Tap-IOProc (Producer, com.apple.audio.IOThread.client des Aggregates)
//        └─► SPSCRingBuffer pro Output-Route (lock-frei, non-blocking)
//                └─► Output-IOProc pro physischem Ziel-Device (Consumer)
//
//  Gruppierung: Mehrere OutputConfigs mit derselben Device-UID (z. B.
//  KA6 Ch1-2 + KA6 Ch3-4) werden zu EINEM OutputDeviceNode mit EINEM
//  IOProc zusammengefasst — jede Route behält ihren eigenen Ring.
//
//  SR-Drift: Phase 2 ist SR-agnostisch (Ring-Preroll puffert 43 ms);
//  echte Drift-Kompensation (PI-Regler/SRC) kommt in Phase 3.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AudioToolbox // re-exportiert die AudioHardware-Tap-APIs (AudioCap-Muster)
import CoreAudio
import Foundation
import os

/// Multi-Output Fan-out Engine (Phase 2).
///
/// `@MainActor`, weil Start/Stop und Statusabfragen vom UI-/Kontroll-Pfad
/// kommen. Die Realtime-Pfade (Tap-IOProc als Producer, Output-IOProcs als
/// Consumer) laufen NICHT auf dem MainActor; sie kommunizieren ausschließlich
/// über ``SPSCRingBuffer`` (lock-frei) und ``TapIOMetrics``.
///
/// ## ⚠️ PFLICHTREGEL (Phase-1-Crash-Root-Cause, Fix 07.07.2026)
///
/// ALLE IOProc-Blöcke werden über `nonisolated static` Factories erstellt
/// (``makeTapIOBlock(metrics:outputChannels:)``,
/// ``makeOutputIOBlock(channels:)``). Eine inline in einer
/// `@MainActor`-Methode definierte Closure erbt die MainActor-Isolation →
/// `swift_task_checkIsolatedSwift` → `_dispatch_assert_queue_fail` →
/// EXC_BREAKPOINT auf dem CoreAudio-RT-Thread. Details: TapEngine.makeIOBlock.
@MainActor
public final class FanOutEngine {

    // MARK: Konstanten (TapEngine-Parität)

    /// Anzahl aufeinanderfolgender reiner Silence-Callbacks, ab der ein
    /// TCC-Denied-Verdacht besteht. Bei 48 kHz / 512 Frames ≈ 2,1 s Wandzeit.
    public static let silenceHeuristicThreshold = 200

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

    /// AudioObjectID des privaten Aggregate Devices.
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// IOProc-Handle des Tap-IOProcs auf dem Aggregate Device.
    private var tapIoProcID: AudioDeviceIOProcID?

    /// Aktive Output-Nodes (ein Node pro physischem Ziel-Device).
    private var outputNodes: [OutputDeviceNode] = []

    /// Realtime-sichere Zähler-Brücke (siehe ``TapIOMetrics``).
    private let metrics = TapIOMetrics()

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

    /// Erstellt eine noch nicht gestartete Engine.
    public init() {}

    // MARK: Interne Typen

    /// Laufzeit-Gruppierung pro physischem Output-Device.
    /// Mehrere OutputConfigs mit derselben UID → EIN OutputDeviceNode mit
    /// mehreren ``OutputDeviceChannel``s (je Route ein eigener Ring).
    ///
    /// `@unchecked Sendable`: Die `channels`-Referenzen werden vom
    /// Output-IOProc (RT-Thread) gelesen; alle Stored Properties außer
    /// `ioProcID` sind `let`. `ioProcID` wird ausschließlich vom MainActor
    /// beschrieben (start/teardown), nie vom RT-Pfad — der IOProc-Block
    /// captured nur `channels`, nie den Node selbst.
    private final class OutputDeviceNode: @unchecked Sendable {
        let deviceID: AudioObjectID
        let uid: String
        let channels: [OutputDeviceChannel] // geordnet nach Config-Reihenfolge
        var ioProcID: AudioDeviceIOProcID?

        init(deviceID: AudioObjectID, uid: String, channels: [OutputDeviceChannel]) {
            self.deviceID = deviceID
            self.uid = uid
            self.channels = channels
            self.ioProcID = nil
        }
    }

    // MARK: Start

    /// Startet Tap + N Output-IOProcs.
    ///
    /// API-Sequenz (Erweiterung der Research-verifizierten TapEngine-Sequenz):
    /// 1. `CATapDescription` (global, unmuted, privat)
    /// 2. `AudioHardwareCreateProcessTap` → `tapID`
    /// 3. Privates Aggregate Device mit Tap in `kAudioAggregateDeviceTapListKey`
    /// 4. Output-Nodes auflösen (UID → AudioObjectID, nach Device gruppieren)
    /// 5. Pro Output-Node ein Output-IOProc (Consumer, `makeOutputIOBlock`)
    /// 6. Tap-IOProc mit Fan-out in alle Ringe (`makeTapIOBlock`)
    /// 7. Output-Devices starten, dann Aggregate starten (TCC-Prompt HIER)
    ///
    /// `outputs` kann leer sein → verhält sich wie Phase 1
    /// (nur Metriken/Silence-Heuristik, kein Fan-out).
    ///
    /// - Throws: ``RouterError/tapFailed(status:)`` bei OSStatus-Fehlern,
    ///   ``RouterError/deviceNotFound(uid:)`` wenn eine Output-UID nicht
    ///   auflösbar ist. Bei jedem Fehler werden bereits erstellte Ressourcen
    ///   in Teardown-Reihenfolge rückabgewickelt.
    ///
    /// - Note: TCC-Denied führt meist zu `noErr` + Silence, NICHT zu einem
    ///   Throw. Den Denied-Fall über ``isSuspectedTCCDenied`` abfragen.
    public func start(outputs: [OutputConfig] = []) throws {
        // Nur aus .idle starten — doppeltes start() ist ein No-Op.
        guard status == .idle else { return }

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
        // Die UUID wird unten als Tap-UID im Aggregate referenziert!
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        // Quelle NICHT muten — v4-Routing ist additiv.
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "AudioRouterNow Global Tap (Phase 2 Fan-out)"

        // ── Schritt 2: Process Tap erzeugen ─────────────────────────────
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw RouterError.tapFailed(status: err)
        }
        tapID = newTapID

        // Ab hier: bei JEDEM Fehler zuerst teardownPartial(), dann werfen.

        // ── Schritt 2b: Default-Output-Device-UID lesen ─────────────────
        let defaultOutputUID: String
        do {
            defaultOutputUID = try Self.readDefaultOutputDeviceUID()
        } catch {
            teardownPartial()
            throw error
        }

        // ── Schritt 3: Privates Aggregate Device ────────────────────────
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouterNow-FanOut-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: defaultOutputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: defaultOutputUID]
            ],
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
            teardownPartial()
            throw RouterError.tapFailed(status: err)
        }
        aggregateDeviceID = newAggregateID

        // ── Schritt 4: Output-Nodes aufbauen (UID → DeviceID, gruppiert) ─
        //
        // ⚠️ Default-Output-Device AUSSCHLIESSEN:
        // Das Tap-Aggregate verwendet den Default-Output als Main-Sub-Device
        // (muteBehavior = .unmuted → Audio spielt dort weiter nativ).
        // Würden wir zusätzlich einen Output-IOProc auf demselben Device
        // registrieren, summiert sich das Signal → Feedback-Loop.
        // Der User muss das Default-Device NICHT als Ziel hinzufügen.
        let filteredOutputs = outputs.filter { $0.uid != defaultOutputUID }
        if filteredOutputs.count < outputs.count {
            let skippedUIDs = outputs
                .filter { $0.uid == defaultOutputUID }
                .map { $0.uid }
            logger.warning(
                "FanOutEngine: \(skippedUIDs.count) Output(s) übersprungen (UID = Default-Output '\(defaultOutputUID)') — würde Feedback-Loop erzeugen. Das Default-Device spielt nativ weiter."
            )
        }

        let nodes: [OutputDeviceNode]
        do {
            nodes = try buildOutputNodes(from: filteredOutputs)
        } catch {
            teardownPartial()
            throw error
        }
        // Ab jetzt in outputNodes halten, damit teardownPartial() bereits
        // registrierte Output-IOProcs bei späteren Fehlern mit abräumt.
        outputNodes = nodes

        // ── Schritt 5: Pro Output-Node ein Output-IOProc (Consumer) ─────
        // ⚠️ Block via nonisolated static Factory — niemals inline (s. o.).
        for node in nodes {
            let block = Self.makeOutputIOBlock(channels: node.channels)
            var procID: AudioDeviceIOProcID?
            // nil = CoreAudio-eigener IOThread (eigene Queue → assert-Crash).
            let procErr = AudioDeviceCreateIOProcIDWithBlock(&procID, node.deviceID, nil, block)
            guard procErr == noErr, let pid = procID else {
                teardownPartial()
                throw RouterError.tapFailed(status: procErr)
            }
            node.ioProcID = pid
        }

        // ── Schritt 6: Tap-IOProc mit Fan-out (Producer) ────────────────
        // Alle Channels aller Nodes als flache Liste — der Tap-IOProc pusht
        // jeden Callback-Block in JEDEN Ring (non-blocking, Overrun = Skip).
        let allChannels = nodes.flatMap { $0.channels }
        let tapBlock = Self.makeTapIOBlock(metrics: metrics, outputChannels: allChannels)
        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, nil, tapBlock)
        guard err == noErr, newProcID != nil else {
            teardownPartial()
            throw RouterError.tapFailed(status: err)
        }
        tapIoProcID = newProcID

        // ── Schritt 7a: Output-Devices starten ──────────────────────────
        // Consumer zuerst — die Ringe liefern Stille bis Pre-Roll (43 ms)
        // gefüllt ist, es gibt also keinen Start-Glitch.
        for node in nodes {
            let startErr = AudioDeviceStart(node.deviceID, node.ioProcID)
            guard startErr == noErr else {
                teardownPartial()
                throw RouterError.tapFailed(status: startErr)
            }
        }

        // ── Schritt 7b: Aggregate starten — HIER feuert der TCC-Prompt ──
        err = AudioDeviceStart(aggregateDeviceID, tapIoProcID)
        guard err == noErr else {
            teardownPartial()
            throw RouterError.tapFailed(status: err)
        }

        status = .routing
    }

    // MARK: Stop

    /// Stoppt Tap + alle Output-IOProcs und gibt alle Ressourcen frei.
    /// Idempotent — mehrfaches Stoppen und Stoppen nach Gerätverlust
    /// (`'!dev'` = 560227702) sind erwartete Pfade, keine Fehler.
    public func stop() {
        teardownPartial()
        status = .idle
    }

    /// Rückabwicklung aller BEREITS erstellten Ressourcen in korrekter
    /// Reihenfolge: Tap-IOProc → Output-IOProcs → Aggregate → Tap.
    /// OSStatus-Fehler beim Teardown werden bewusst ignoriert
    /// ('!dev' nach Gerätverlust ist hier normal, v3-Lektion).
    private func teardownPartial() {
        // 1. Tap-IOProc stoppen + zerstören (Producer zuerst — danach
        //    schreibt niemand mehr in die Ringe).
        if let procID = tapIoProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        tapIoProcID = nil

        // 2. Alle Output-IOProcs stoppen + zerstören.
        for node in outputNodes {
            if let procID = node.ioProcID {
                _ = AudioDeviceStop(node.deviceID, procID)
                _ = AudioDeviceDestroyIOProcID(node.deviceID, procID)
            }
            node.ioProcID = nil
        }
        outputNodes = []

        // 3. Aggregate Device zerstören.
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        // 4. Process Tap zerstören (zuletzt — das Aggregate referenziert ihn).
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Output-Node-Aufbau

    /// Löst OutputConfigs zu AudioObjectIDs auf und gruppiert sie pro
    /// physischem Device (KA6 Ch1-2 + KA6 Ch3-4 → EIN Node, 2 Channels).
    private func buildOutputNodes(from configs: [OutputConfig]) throws -> [OutputDeviceNode] {
        // 1. Jede Config zu (AudioObjectID, Config) auflösen.
        var byDeviceID: [(AudioObjectID, OutputConfig)] = []
        for config in configs {
            guard let deviceID = Self.deviceIDForUID(config.uid) else {
                throw RouterError.deviceNotFound(uid: config.uid)
            }
            byDeviceID.append((deviceID, config))
        }

        // 2. Nach DeviceID gruppieren (Config-Reihenfolge beibehalten).
        var grouped: [AudioObjectID: [OutputConfig]] = [:]
        var deviceOrder: [AudioObjectID] = []
        for (deviceID, config) in byDeviceID {
            if grouped[deviceID] == nil {
                grouped[deviceID] = []
                deviceOrder.append(deviceID)
            }
            grouped[deviceID]!.append(config)
        }

        // 3. Pro DeviceID einen OutputDeviceNode erstellen.
        var nodes: [OutputDeviceNode] = []
        for deviceID in deviceOrder {
            let deviceConfigs = grouped[deviceID]!
            let channels = deviceConfigs.map { OutputDeviceChannel(config: $0) }
            // UID aus der ersten Config (alle haben dieselbe UID).
            let uid = deviceConfigs[0].uid
            nodes.append(OutputDeviceNode(deviceID: deviceID, uid: uid, channels: channels))
        }
        return nodes
    }

    // MARK: Realtime-IOProc-Factories

    /// Erstellt den Tap-IOProc-Block (Producer): Silence-Heuristik +
    /// Fan-out in alle Ring-Buffer.
    ///
    /// ## ⚠️ nonisolated static — PFLICHT (Phase-1-Crash-Root-Cause)
    /// NIEMALS inline in einer `@MainActor`-Methode definieren — die Closure
    /// würde die MainActor-Isolation erben und CoreAudio ruft sie auf
    /// `com.apple.audio.IOThread.client` auf → `_dispatch_assert_queue_fail`
    /// → EXC_BREAKPOINT (Details: TapEngine.makeIOBlock, Fix 07.07.2026).
    ///
    /// `AudioDeviceIOBlock` liefert KEINEN Frame-Count-Parameter — die
    /// Framezahl wird aus `mDataByteSize` des jeweiligen Buffers abgeleitet.
    ///
    /// Der Tap liefert je nach Aggregate-Konfiguration:
    /// - NON-INTERLEAVED Stereo: 2 Buffer à `mNumberChannels == 1` (L, R)
    /// - INTERLEAVED: 1 Buffer mit `mNumberChannels >= 2`
    /// - Mono: 1 Buffer mit `mNumberChannels == 1`
    ///
    /// - Parameters:
    ///   - metrics: Sendable-Zähler-Box (kein `self`-Capture!).
    ///   - outputChannels: Alle Ring-Routen (Array von `@unchecked Sendable`
    ///     Referenzen; SPSC-Invariante: dieser Block ist der EINZIGE Producer
    ///     jedes Rings).
    private nonisolated static func makeTapIOBlock(
        metrics: TapIOMetrics,
        outputChannels: [OutputDeviceChannel]
    ) -> AudioDeviceIOBlock {
        return { _, inInputData, _, _, _ in
            let bufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )

            // Silence-Heuristik (Phase-1-Parität): Early-Exit beim ersten
            // Nicht-Null-Sample.
            var isSilent = true
            outer: for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.assumingMemoryBound(to: Float32.self)
                for i in 0..<sampleCount where samples[i] != 0 {
                    isSilent = false
                    break outer
                }
            }
            metrics.record(callbackWasSilent: isSilent)

            // Kein Fan-out bei Silence (Consumer-Ringe laufen leer und
            // liefern selbst Stille) oder ohne Routen.
            guard !isSilent, !outputChannels.isEmpty, bufferList.count >= 1 else { return }

            let bytesPerSample = MemoryLayout<Float32>.size
            let first = bufferList[0]

            if bufferList.count >= 2, first.mNumberChannels == 1 {
                // Non-interleaved: Buffer 0 = L, Buffer 1 = R.
                let frameCount = Int(first.mDataByteSize) / bytesPerSample
                guard frameCount > 0,
                      let left = first.mData?.assumingMemoryBound(to: Float32.self)
                else { return }
                let right = bufferList[1].mData?.assumingMemoryBound(to: Float32.self)
                for ch in outputChannels {
                    _ = ch.ring.push(left: left, right: right, frameCount: frameCount)
                }
            } else if first.mNumberChannels >= 2 {
                // Interleaved: ein Buffer mit 2+ Kanälen.
                let stride = Int(first.mNumberChannels)
                let frameCount = Int(first.mDataByteSize) / (bytesPerSample * stride)
                guard frameCount > 0,
                      let data = first.mData?.assumingMemoryBound(to: Float32.self)
                else { return }
                for ch in outputChannels {
                    _ = ch.ring.pushInterleaved(from: data, stride: stride, frameCount: frameCount)
                }
            } else {
                // Mono: ein Buffer, ein Kanal — L wird ring-seitig dupliziert.
                let frameCount = Int(first.mDataByteSize) / bytesPerSample
                guard frameCount > 0,
                      let left = first.mData?.assumingMemoryBound(to: Float32.self)
                else { return }
                for ch in outputChannels {
                    _ = ch.ring.push(left: left, right: nil, frameCount: frameCount)
                }
            }
        }
    }

    /// Erstellt den Output-IOProc-Block (Consumer) für EIN physisches
    /// Output-Device: popt pro Route aus dem jeweiligen Ring in die
    /// Ziel-Kanäle (Channel-Offset-Support für Multi-Kanal-Interfaces).
    ///
    /// ## ⚠️ nonisolated static — PFLICHT (Phase-1-Crash-Root-Cause)
    /// Siehe ``makeTapIOBlock(metrics:outputChannels:)``.
    ///
    /// Layout-Fälle des Output-Devices:
    /// - NON-INTERLEAVED (`mNumberChannels == 1` pro Buffer): Channel-Offset
    ///   indiziert die BUFFER-Liste (Buffer[offset] = L, Buffer[offset+1] = R).
    /// - INTERLEAVED (1 Buffer, `mNumberChannels >= 2`): Channel-Offset
    ///   indiziert INNERHALB des Buffers — Sample L von Frame i liegt bei
    ///   `data[i * stride + offset]`, R bei `data[i * stride + offset + 1]`.
    ///   `popInterleaved(into: data.advanced(by: offset), stride:)` schreibt
    ///   exakt dorthin.
    ///
    /// Underrun/Pre-Roll: `pop…` füllt die Ziel-Kanäle mit Stille — kein
    /// Garbage-Audio, kein Blockieren.
    ///
    /// - Parameter channels: Die Routen dieses Devices (SPSC-Invariante:
    ///   dieser Block ist der EINZIGE Consumer jedes dieser Ringe).
    private nonisolated static func makeOutputIOBlock(
        channels: [OutputDeviceChannel]
    ) -> AudioDeviceIOBlock {
        return { _, _, _, outOutputData, _ in
            let outputList = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outputList.count > 0 else { return }

            let bytesPerSample = MemoryLayout<Float32>.size
            let first = outputList[0]

            if first.mNumberChannels == 1 {
                // Non-interleaved: ein Buffer pro Kanal.
                let frameCount = Int(first.mDataByteSize) / bytesPerSample
                guard frameCount > 0 else { return }
                for ch in channels {
                    let offset = ch.config.channelOffset
                    guard outputList.count > offset,
                          let left = outputList[offset].mData?
                              .assumingMemoryBound(to: Float32.self)
                    else { continue }
                    let right = offset + 1 < outputList.count
                        ? outputList[offset + 1].mData?.assumingMemoryBound(to: Float32.self)
                        : nil
                    _ = ch.ring.pop(left: left, right: right, frameCount: frameCount)
                }
            } else {
                // Interleaved: ein Buffer mit mehreren Kanälen.
                let stride = Int(first.mNumberChannels)
                let frameCount = Int(first.mDataByteSize) / (bytesPerSample * stride)
                guard frameCount > 0,
                      let data = first.mData?.assumingMemoryBound(to: Float32.self)
                else { return }
                for ch in channels {
                    let offset = ch.config.channelOffset
                    // L+R müssen ins Kanal-Raster passen (offset+1 < stride).
                    guard offset + 1 < stride else { continue }
                    _ = ch.ring.popInterleaved(
                        into: data.advanced(by: offset),
                        stride: stride,
                        frameCount: frameCount
                    )
                }
            }
        }
    }

    // MARK: Device-Discovery

    /// Liefert alle verfügbaren (nicht-aggregierten) Output-Devices.
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
    /// (Re-Implementierung der privaten TapEngine-Helper-Methode —
    /// UID statt AudioObjectID: stabil über Hot-Plug, CJK-sicher).
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
}
