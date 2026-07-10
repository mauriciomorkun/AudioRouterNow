//
//  EngineController.swift
//  AudioRouterNow4
//
//  Phase 2/4: ObservableObject-Wrapper um FanOutEngine — Status/Metriken für
//  SwiftUI, Output-Config-Persistenz, Device-Lifecycle & MainActor-Polling.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AppKit
import AudioRouterKit
import ServiceManagement
import SwiftUI
import os

/// `@MainActor`-`ObservableObject`-Brücke zwischen der RT-``FanOutEngine`` und
/// der SwiftUI-Menu-Bar-UI.
///
/// Der Controller besitzt die Engine, spiegelt deren Status/Metriken in
/// `@Published`-Properties und übersetzt UI-Aktionen (Start/Stop, Geräte
/// hinzufügen/entfernen, Volume) in Engine-Aufrufe. Er verwaltet zudem
/// Persistenz (``OutputConfig`` in UserDefaults), den Device-Lifecycle
/// (``DeviceLifecycleManager``) und die Login-Item-Registrierung.
///
/// ## Threading / Polling (3-Tier)
/// Die Engine schreibt RT-sicher, der Controller POLLT auf dem MainActor:
/// - ``pollingTask`` (2 fps, 500 ms): langsame Metriken — Callbacks, TCC-Verdacht,
///   Volume/Mute.
/// - ``wavePollTask`` (20 fps, 50 ms): Peak-Level + perceptual ``waveEnergy``
///   für flüssige Signal-Meter und den Wellen-Header.
/// - Das Oszilloskop liest ``waveformSnapshot(count:)`` direkt im Canvas bei
///   bis zu 60 fps (kein `@Published`, kein Polling).
///
/// - Warning: Alle Methoden sind MainActor-gebunden. Lifecycle-Callbacks kommen
///   von einer seriellen CoreAudio-Queue und hüpfen deshalb via `Task { @MainActor }`
///   zurück (siehe ``startLifecycle()``).
@MainActor
final class EngineController: ObservableObject {

    /// Die RT-Audio-Engine (Tap + Fan-out). Nur vom MainActor angesprochen —
    /// die Engine kapselt den RT-Pfad selbst.
    private let engine = FanOutEngine()
    private let logger = Logger(subsystem: "com.mauriciomorkun.audiorouternow",
                                category: "EngineController")

    /// Gespiegelter Engine-Status.
    /// TODO(Phase 4): Statt Spiegelung `engine.status` direkt beobachten
    /// (Engine `@Observable`), um die Status-Duplikation aufzulösen (F13).
    @Published private(set) var status: RouterStatus = .idle
    @Published private(set) var isSuspectedTCCDenied: Bool = false
    @Published private(set) var totalCallbacks: Int = 0
    @Published private(set) var hasReceivedAudio: Bool = false
    @Published private(set) var currentVolume: Double = 1.0
    @Published private(set) var isMuted: Bool = false

    /// Output-Latenzen pro UID (befüllt bei Start / Warm-Restart).
    @Published private(set) var deviceLatencies: [String: DeviceLatencyInfo] = [:]

    /// IO-Buffer-Grösse (Frames) des aktiven Aggregates.
    @Published private(set) var bufferFrames: Int = 512

    /// Peak-Pegel pro Output-Slot. Key = `"<uid>:<channelOffset>"` (Composite —
    /// mehrere Configs desselben Geräts kollidieren sonst). Über ``peak(for:)``
    /// lesen, statt den Key manuell zu bilden.
    @Published private(set) var peakLevels: [String: (l: Float32, r: Float32)] = [:]

    /// `true` zwischen `startRouting()`-Aufruf und Engine-Bestätigung
    /// (UI-State „Verbinde Geräte…").
    @Published private(set) var isStarting: Bool = false

    /// Audio-Energie für die WaveHeader-Animation [0.0 … 1.0]. Wird vom
    /// 20fps-Wave-Poll (50 ms) direkt aus `engine.peakLevel()` gespeist und
    /// per EMA geglättet (schneller Attack, langsamer Release — VU-Meter).
    @Published private(set) var waveEnergy: Float32 = 0

    @Published private(set) var outputConfigs: [OutputConfig] = []
    @Published private(set) var availableDevices: [(uid: String, name: String, channelCount: Int)] = []

    /// M2: Login-Item-Toggle. Spiegelt den SMAppService-Status und registriert/
    /// deregistriert das Login-Item bei Änderung (rollt bei Fehler zurück).
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard oldValue != launchAtLogin, !isRefreshingLoginStatus else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("LoginItem toggle failed: \(String(describing: error), privacy: .public)")
                // Zurückrollen ohne didSet erneut zu triggern
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }

    /// W5: true, während refreshLaunchAtLoginStatus() den Wert nur SPIEGELT —
    /// didSet darf dann NICHT registrieren/deregistrieren.
    private var isRefreshingLoginStatus = false

    /// W5: Liest den SMAppService-Status neu ein, OHNE didSet-Seiteneffekte
    /// auszulösen. Nötig, weil das Onboarding das Login-Item DIREKT registriert,
    /// nachdem launchAtLogin bereits mit dem alten Status initialisiert wurde.
    func refreshLaunchAtLoginStatus() {
        let actual = (SMAppService.mainApp.status == .enabled)
        guard launchAtLogin != actual else { return }
        isRefreshingLoginStatus = true
        launchAtLogin = actual
        isRefreshingLoginStatus = false
    }

    private static let outputConfigsKey = "arn.v4.outputConfigs"
    private static let wasRoutingKey = "arn.v4.wasRouting"

    /// F10: Polling läuft unabhängig vom geöffneten Menü.
    private var pollingTask: Task<Void, Never>?
    /// 20fps-Poll für die audio-reaktive Wellenform (nil, wenn nicht routing).
    private var wavePollTask: Task<Void, Never>?
    /// F4: Device-Lifecycle-Listener (nil, wenn nicht routing).
    private var lifecycle: DeviceLifecycleManager?
    /// Re-Entry-Schutz für restartRouting().
    private var isRestarting = false
    /// M1: Re-Entry-Schutz für den Warm-Restart via updateOutputs().
    private var isUpdatingOutputs = false
    /// W8: Output-Änderung traf ein, während ein Warm-Restart lief →
    /// nach dessen Abschluss erneut anwenden statt verwerfen.
    private var needsOutputUpdate = false
    /// W8-Analog für SR-Wechsel: SR-Änderung traf ein, während ein
    /// M1-Warm-Restart lief → nach dessen Abschluss nachholen statt verwerfen.
    private var needsSRRestart = false

    init() {
        outputConfigs = Self.loadOutputConfigs()
        Task { @MainActor in
            refreshAvailableDevices()
        }
        // S4: Auto-Start nach kurzer Verzögerung (gibt coreaudiod Zeit zu settlen).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.autoStartIfNeeded()
        }
    }

    /// Startet das Routing mit der aktuell persistierten Output-Konfiguration.
    ///
    /// Setzt zuerst `isStarting` (UI zeigt „Verbinde Geräte…") und führt den
    /// blockierenden CoreAudio-Start erst im nächsten MainActor-Tick aus, damit
    /// SwiftUI den Zwischen-Frame rendern kann. No-Op bei bereits laufendem
    /// oder gerade startendem Routing.
    func startRouting() {
        guard status != .routing, !isStarting else { return }
        isStarting = true
        // Nächster MainActor-Tick: SwiftUI rendert erst den STARTING-Frame,
        // dann folgt der (blockierende) CoreAudio-Start.
        Task { @MainActor [weak self] in
            guard let self, self.isStarting else { return }
            self.performStart()
        }
    }

    private func performStart() {
        defer { isStarting = false }
        do {
            try engine.start(outputs: outputConfigs)
            status = engine.status
            if status == .routing {
                bufferFrames = engine.ioBufferFrames          // neu
                captureDeviceLatencies()                       // neu
                startPolling()      // F10
                startLifecycle()    // F4
                UserDefaults.standard.set(true, forKey: Self.wasRoutingKey)
            }
        } catch let e as RouterError {
            logger.error("startRouting: RouterError: \(e.localizedDescription, privacy: .public)")
            status = .error(e)
        } catch {
            logger.error("startRouting: unerwarteter Fehler: \(String(describing: error), privacy: .public)")
            status = .error(.tapFailed(status: -1))
        }
    }

    /// Liest Output-Latenzen für alle konfigurierten Geräte (dedupliziert per UID).
    /// Nutzt die public UID→AudioObjectID-Auflösung der Engine + `readDeviceLatency`.
    private func captureDeviceLatencies() {
        var result: [String: DeviceLatencyInfo] = [:]
        for config in outputConfigs {
            guard result[config.uid] == nil,
                  let deviceID = FanOutEngine.deviceID(forUID: config.uid)
            else { continue }   // Gerät nicht (mehr) verbunden → überspringen
            result[config.uid] = readDeviceLatency(deviceID: deviceID)
        }
        deviceLatencies = result
    }

    /// Stoppt das Routing, reisst alle Ressourcen ab und setzt den UI-Zustand
    /// zurück. Merkt sich zusätzlich, dass der User BEWUSST gestoppt hat
    /// (`wasRoutingKey = false`) → kein Auto-Start beim nächsten Launch.
    func stopRouting() {
        pollingTask?.cancel(); pollingTask = nil      // F10
        wavePollTask?.cancel(); wavePollTask = nil
        waveEnergy = 0
        lifecycle?.stop(); lifecycle = nil            // F4
        engine.stop()
        status = engine.status
        isSuspectedTCCDenied = false
        totalCallbacks = 0
        hasReceivedAudio = false
        currentVolume = 1.0
        isMuted = false
        deviceLatencies = [:]
        peakLevels = [:]
        bufferFrames = 512
        isStarting = false
        // S4: Benutzer hat bewusst gestoppt → beim nächsten Launch nicht auto-starten.
        UserDefaults.standard.set(false, forKey: Self.wasRoutingKey)
    }

    /// S4: Startet Routing automatisch, wenn die letzte Session aktiv war.
    /// Gate: Onboarding muss bereits gezeigt worden sein.
    func autoStartIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.wasRoutingKey),
              UserDefaults.standard.bool(forKey: "arn.v4.hasShownOnboarding"),
              status == .idle else { return }
        Task { @MainActor [weak self] in
            // 2 s warten: coreaudiod und Geräte nach Login settlen lassen
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.status == .idle else { return }
            self.startRouting()
        }
    }

    /// Von DeviceLifecycleManager ausgelöst (F4): Engine sauber neu aufsetzen.
    func restartRouting() {
        guard status == .routing || status.isError, !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        logger.log("restartRouting: Lifecycle-Ereignis → Engine-Neustart")
        engine.stop()
        do {
            try engine.start(outputs: outputConfigs)
            status = engine.status
            bufferFrames = engine.ioBufferFrames
            captureDeviceLatencies()
        } catch let e as RouterError {
            logger.error("restartRouting: RouterError: \(e.localizedDescription, privacy: .public)")
            status = .error(e)
        } catch {
            logger.error("restartRouting: unerwarteter Fehler: \(String(describing: error), privacy: .public)")
            status = .error(.tapFailed(status: -1))
        }
    }

    /// Vom ``pollingTask`` alle 0,5 s aufgerufen — spiegelt die langsamen
    /// Engine-Metriken (Callbacks, TCC-Verdacht, Audio-Empfang, Volume/Mute)
    /// in die `@Published`-Properties. Peak-Level laufen separat im 20fps-Poll.
    func poll() {
        guard status == .routing else { return }
        isSuspectedTCCDenied = engine.isSuspectedTCCDenied
        totalCallbacks = engine.totalCallbacks
        hasReceivedAudio = engine.hasReceivedAudio
        let vol = engine.currentVolumeScale
        isMuted = vol < 0.001
        currentVolume = isMuted ? currentVolume : Double(vol)  // Volume nicht überschreiben wenn gemutet

        // peakLevels: jetzt im wavePollTask (20fps) — siehe updateWaveEnergy()
    }

    /// Schreibt die Lautstärke auf das System-Default-Output-Gerät.
    /// - Parameter value: Ziel-Skalar [0.0 … 1.0] vom UI-Volume-Slider.
    func setSystemVolume(_ value: Double) {
        engine.setSystemVolume(Float32(value))
    }

    /// Liest die aktuell verfügbaren Output-Geräte neu ein (Geräteauswahl-UI).
    func refreshAvailableDevices() {
        availableDevices = FanOutEngine.availableOutputDevices()
    }

    /// Peak-Pegel für eine Output-Config [0.0 … 1.0 linear]. `nil`, wenn das
    /// Gerät gerade nicht aktiv geroutet wird (kein Slot vorhanden).
    func peak(for config: OutputConfig) -> (l: Float32, r: Float32)? {
        peakLevels["\(config.uid):\(config.channelOffset)"]
    }

    /// Waveform-Snapshot für Oszilloskop-Anzeige. Thread-safe via WaveformBridge —
    /// wird direkt vom Canvas bei 60fps gelesen (kein @Published, kein Polling).
    func waveformSnapshot(count: Int) -> [(min: Float32, max: Float32)] {
        engine.waveformSnapshot(count: count)
    }

    /// Latenz-Info für eine Output-Config (oder `nil`, wenn nicht verfügbar).
    func latency(for config: OutputConfig) -> DeviceLatencyInfo? {
        deviceLatencies[config.uid]
    }

    /// Fügt ein Output-Ziel hinzu, persistiert es und wendet die Änderung bei
    /// laufendem Routing per Warm-Restart an (No-Op bei Duplikat).
    func addOutputConfig(_ config: OutputConfig) {
        guard !outputConfigs.contains(config) else { return }
        outputConfigs.append(config)
        Self.saveOutputConfigs(outputConfigs)
        applyOutputsIfRouting()
    }

    /// Entfernt ein Output-Ziel, persistiert und wendet die Änderung bei
    /// laufendem Routing per Warm-Restart an.
    func removeOutputConfig(_ config: OutputConfig) {
        outputConfigs.removeAll { $0 == config }
        Self.saveOutputConfigs(outputConfigs)
        applyOutputsIfRouting()
    }

    /// M1: Bei laufendem Routing die Output-Änderung per Warm-Restart anwenden
    /// (Tap bleibt bestehen, kein neuer TCC-Prompt). Im Idle-Zustand ist das ein
    /// No-Op — die neue Config greift beim nächsten `startRouting()`.
    private func applyOutputsIfRouting() {
        guard status == .routing else { return }
        if isUpdatingOutputs {
            // W8: Läuft bereits ein Warm-Restart, Änderung NICHT verwerfen.
            needsOutputUpdate = true
            return
        }
        isUpdatingOutputs = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isUpdatingOutputs = false
                if self.needsOutputUpdate {
                    self.needsOutputUpdate = false
                    // Der Output-Update ruft dasselbe updateOutputs() → deckt
                    // einen gequeuten SR-Restart gleich mit ab.
                    self.needsSRRestart = false
                    self.applyOutputsIfRouting()
                } else if self.needsSRRestart {
                    self.needsSRRestart = false
                    self.warmRestartForSampleRateChange()
                }
            }
            do {
                try await self.engine.updateOutputs(self.outputConfigs)
                self.status = self.engine.status
                // Lifecycle für neue UID-Menge neu aufsetzen.
                self.lifecycle?.stop()
                self.lifecycle = nil
                self.startLifecycle()
                self.bufferFrames = self.engine.ioBufferFrames
                self.captureDeviceLatencies()
            } catch let e as RouterError {
                self.logger.error("applyOutputsIfRouting: RouterError: \(e.localizedDescription, privacy: .public)")
                self.status = .error(e)
            } catch {
                self.logger.error("applyOutputsIfRouting: unerwarteter Fehler: \(String(describing: error), privacy: .public)")
                self.status = .error(.tapFailed(status: -1))
            }
        }
    }

    /// Öffnet Systemeinstellungen → Datenschutz → System-Audio-Aufnahme
    /// (Deep-Link), damit der User die TCC-Berechtigung erteilen kann.
    func openTCCSettings() {
        guard let url = URL(string: FanOutEngine.tccDeepLink) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Privat

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.poll()
            }
        }
        startWavePoll()
    }

    /// Startet den 20fps-Wave-Poll (50 ms) für die audio-reaktive Wellenform.
    /// Liest `engine.peakLevel()` direkt (RT-safe via os_unfair_lock) — kein
    /// Umweg über das 500ms-`poll()`, das für Animationen zu langsam ist.
    private func startWavePoll() {
        wavePollTask?.cancel()
        wavePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms = 20 fps
                self?.updateWaveEnergy()
            }
        }
    }

    /// Berechnet die Audio-Energie perceptual (dBFS-skaliert) aus den Slot-Peaks
    /// und glättet per EMA: schneller Attack (α = 0.55), langsamer Release
    /// (α = 0.10) — VU-Meter-Charakter. Befüllt zusätzlich `peakLevels` bei
    /// 20fps für flüssige Signal-Meter. Ohne Audio zerfällt der Wert natürlich.
    private func updateWaveEnergy() {
        guard status == .routing else { decayWaveEnergy(); return }
        let slots = engine.slotDeviceKeys.count
        guard slots > 0 else { decayWaveEnergy(); return }

        // 1. Peaks lesen + peakLevels aktualisieren (20fps für Signal-Meter — Fix 2)
        var newPeaks: [String: (l: Float32, r: Float32)] = [:]
        var sum: Float32 = 0
        for (i, key) in engine.slotDeviceKeys.enumerated() where i < 16 {
            let p = engine.peakLevel(slotIndex: i)
            let prev = peakLevels[key] ?? (l: 0, r: 0)
            // Peak-Hold: schneller Attack, Release ×0.80/Tick bei 20fps
            newPeaks[key] = (
                l: max(p.l, prev.l * 0.80),
                r: max(p.r, prev.r * 0.80)
            )
            sum += (p.l + p.r) / 2
        }
        if !newPeaks.isEmpty { peakLevels = newPeaks }

        // 2. Perceptual Energy: linear → dBFS → normalisiert [0,1].
        //    Warum nicht der lineare Peak direkt? Menschliches Lautheitsempfinden
        //    ist logarithmisch: bei −16 dBFS wirkt Musik „gut hörbar", der lineare
        //    Peak ist dort aber nur 0.16 → die Welle bliebe optisch fast flach.
        //    Über dBFS wird daraus perceptual ≈ 0.73 → visuell stimmig.
        //    a) linearer Mittel-Peak über alle Slots, gegen 1.0 geklemmt.
        let linear = min(1, sum / Float32(slots))
        //    b) in dBFS umrechnen; Floor bei 0.001 verhindert log10(0) = −∞.
        //       Ergebnis liegt in (−60 … 0] (0.001 ≈ −60 dBFS, 1.0 = 0 dBFS).
        let dBFS = 20.0 * log10(Double(max(linear, 0.001)))   // −∞..0
        //    c) [−60, 0] dBFS linear auf [0, 1] mappen und clampen.
        let perceptual = Float32(max(0, min(1, (dBFS + 60.0) / 60.0)))

        // 3. EMA-Glättung mit asymmetrischem α (VU-Meter-Charakter):
        //    steigt der Wert → schneller Attack (α = 0.55, reagiert prompt);
        //    fällt er → langsamer Release (α = 0.10, klingt weich aus).
        //    next = α·neu + (1−α)·alt.
        let alpha: Float32 = perceptual > waveEnergy ? 0.55 : 0.10
        let next = alpha * perceptual + (1 - alpha) * waveEnergy
        // Snap-to-zero verhindert endloses Publish-Churn bei Rest-Epsilon.
        waveEnergy = next < 0.001 ? 0 : next
    }

    /// Natürlicher Zerfall (×0.88/Tick) — Wellen bleiben subtil, kein Publish-
    /// Churn bei bereits erreichter Null.
    private func decayWaveEnergy() {
        guard waveEnergy > 0 else { return }
        let next = waveEnergy * 0.88
        waveEnergy = next < 0.001 ? 0 : next
    }

    private func startLifecycle() {
        var uids = Set(outputConfigs.map(\.uid))
        // W3: Default-Output mit überwachen — er ist immer Sub-Device des
        // Aggregates; ein SR-Wechsel dort braucht denselben Warm-Restart.
        if let defaultUID = FanOutEngine.currentDefaultOutputUID() {
            uids.insert(defaultUID)
        }
        let manager = DeviceLifecycleManager(
            onNeedsRestart: { [weak self] in
                // Läuft auf der seriellen Lifecycle-Queue → auf MainActor hüpfen.
                Task { @MainActor in self?.restartRouting() }
            },
            onSampleRateChanged: { [weak self] in
                Task { @MainActor in self?.warmRestartForSampleRateChange() }
            }
        )
        manager.start(routedUIDs: uids)
        lifecycle = manager
    }

    /// M4: Sample-Rate-Wechsel auf einem gerouteten Device → Warm-Restart
    /// (Tap bleibt, kein TCC-Prompt). Fällt bei Fehler auf Full-Restart zurück.
    private func warmRestartForSampleRateChange() {
        // K2: Gleicher Re-Entry-Guard wie applyOutputsIfRouting — verhindert
        // parallele Warm-Restarts (M4+M1 gleichzeitig → IOProc-/Scratch-Leak).
        guard status == .routing else { return }
        if isUpdatingOutputs {
            // W8-Analog: SR-Wechsel während laufendem Warm-Restart NICHT
            // verwerfen — nach dessen Abschluss nachholen.
            needsSRRestart = true
            return
        }
        isUpdatingOutputs = true
        logger.log("M4: Sample rate changed on routed device → warm restart")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isUpdatingOutputs = false
                // SR-Restart während SR-Restart: dieser Durchlauf deckt jeden
                // währenddessen eingetroffenen SR-Wunsch mit ab → 1x reicht.
                self.needsSRRestart = false
                // W8: Output-Änderung während SR-Restart nachholen.
                if self.needsOutputUpdate {
                    self.needsOutputUpdate = false
                    self.applyOutputsIfRouting()
                }
            }
            guard self.status == .routing else { return }
            do {
                try await self.engine.updateOutputs(self.outputConfigs)
                self.status = self.engine.status
                self.bufferFrames = self.engine.ioBufferFrames
                self.captureDeviceLatencies()
            } catch {
                self.logger.error("M4: Warm restart failed → full restart")
                self.restartRouting()
            }
        }
    }

    // MARK: UserDefaults-Serialisierung

    private static func loadOutputConfigs() -> [OutputConfig] {
        guard let data = UserDefaults.standard.data(forKey: outputConfigsKey),
              let configs = try? JSONDecoder().decode([OutputConfig].self, from: data)
        else { return [] }
        return configs
    }

    private static func saveOutputConfigs(_ configs: [OutputConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: outputConfigsKey)
    }
}
