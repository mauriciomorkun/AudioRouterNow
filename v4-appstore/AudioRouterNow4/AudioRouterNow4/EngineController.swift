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

@MainActor
final class EngineController: ObservableObject {

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

    func stopRouting() {
        pollingTask?.cancel(); pollingTask = nil      // F10
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

    /// Vom Polling-Task alle 0,5 s aufgerufen — liest Engine-Metriken.
    func poll() {
        guard status == .routing else { return }
        isSuspectedTCCDenied = engine.isSuspectedTCCDenied
        totalCallbacks = engine.totalCallbacks
        hasReceivedAudio = engine.hasReceivedAudio
        let vol = engine.currentVolumeScale
        isMuted = vol < 0.001
        currentVolume = isMuted ? currentVolume : Double(vol)  // Volume nicht überschreiben wenn gemutet

        // Peak-Level pro Slot lesen + UI-seitige Release-Glättung (Attack sofort,
        // Release ~40 %/Tick), damit der Meter bei 500 ms-Polling nicht flackert.
        var newPeaks: [String: (l: Float32, r: Float32)] = [:]
        for (i, key) in engine.slotDeviceKeys.enumerated() {
            let raw = engine.peakLevel(slotIndex: i)
            let prev = peakLevels[key] ?? (l: 0, r: 0)
            newPeaks[key] = (
                l: max(raw.l, prev.l * 0.6),
                r: max(raw.r, prev.r * 0.6)
            )
        }
        peakLevels = newPeaks
    }

    /// Schreibt die Lautstärke auf das System-Default-Output-Gerät (UI-Slider → System).
    func setSystemVolume(_ value: Double) {
        engine.setSystemVolume(Float32(value))
    }

    func refreshAvailableDevices() {
        availableDevices = FanOutEngine.availableOutputDevices()
    }

    /// Peak-Pegel für eine Output-Config [0.0 … 1.0 linear]. `nil`, wenn das
    /// Gerät gerade nicht aktiv geroutet wird (kein Slot vorhanden).
    func peak(for config: OutputConfig) -> (l: Float32, r: Float32)? {
        peakLevels["\(config.uid):\(config.channelOffset)"]
    }

    /// Latenz-Info für eine Output-Config (oder `nil`, wenn nicht verfügbar).
    func latency(for config: OutputConfig) -> DeviceLatencyInfo? {
        deviceLatencies[config.uid]
    }

    func addOutputConfig(_ config: OutputConfig) {
        guard !outputConfigs.contains(config) else { return }
        outputConfigs.append(config)
        Self.saveOutputConfigs(outputConfigs)
        applyOutputsIfRouting()
    }

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
