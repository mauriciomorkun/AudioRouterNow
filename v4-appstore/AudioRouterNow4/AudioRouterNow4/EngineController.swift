//
//  EngineController.swift
//  AudioRouterNow4
//
//  Phase 2: ObservableObject-Wrapper um FanOutEngine — Status/Metriken für
//  SwiftUI + Output-Config-Verwaltung mit UserDefaults-Persistenz.
//  Wird in Phase 4 durch das finale State-Management ersetzt.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AppKit
import AudioRouterKit
import SwiftUI

@MainActor
final class EngineController: ObservableObject {

    private let engine = FanOutEngine()

    @Published private(set) var status: RouterStatus = .idle
    @Published private(set) var isSuspectedTCCDenied: Bool = false
    @Published private(set) var totalCallbacks: Int = 0
    @Published private(set) var hasReceivedAudio: Bool = false

    /// Persistierte Routing-Ziele (UserDefaults, JSON-codiert).
    @Published private(set) var outputConfigs: [OutputConfig] = []

    /// Verfügbare (nicht-aggregierte) Output-Devices für den Add-Picker.
    @Published private(set) var availableDevices: [(uid: String, name: String, channelCount: Int)] = []

    private static let outputConfigsKey = "arn.v4.outputConfigs"

    init() {
        outputConfigs = Self.loadOutputConfigs()
    }

    func startRouting() {
        do {
            try engine.start(outputs: outputConfigs)
            status = engine.status
        } catch let e as RouterError {
            status = .error(e)
        } catch {
            status = .error(.tapFailed(status: -1))
        }
    }

    func stopRouting() {
        engine.stop()
        status = engine.status
        isSuspectedTCCDenied = false
        totalCallbacks = 0
        hasReceivedAudio = false
    }

    /// Vom SwiftUI-Task alle 0,5 s aufgerufen — liest Engine-Metriken.
    func poll() {
        guard status == .routing else { return }
        isSuspectedTCCDenied = engine.isSuspectedTCCDenied
        totalCallbacks = engine.totalCallbacks
        hasReceivedAudio = engine.hasReceivedAudio
    }

    func refreshAvailableDevices() {
        availableDevices = FanOutEngine.availableOutputDevices()
    }

    func addOutputConfig(_ config: OutputConfig) {
        guard !outputConfigs.contains(config) else { return }
        outputConfigs.append(config)
        Self.saveOutputConfigs(outputConfigs)
    }

    func removeOutputConfig(_ config: OutputConfig) {
        outputConfigs.removeAll { $0 == config }
        Self.saveOutputConfigs(outputConfigs)
    }

    func openTCCSettings() {
        guard let url = URL(string: FanOutEngine.tccDeepLink) else { return }
        NSWorkspace.shared.open(url)
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
