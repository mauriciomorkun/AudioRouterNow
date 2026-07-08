//
//  MenuBarView.swift
//  AudioRouterNow4
//
//  Phase 2 Test-UI: Output-Liste (Add/Remove), Start/Stop, Metriken.
//  Wird in Phase 4 durch die vollständige UI ersetzt.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

struct MenuBarView: View {

    @EnvironmentObject var controller: EngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header ──────────────────────────────────────────────────
            Text("AudioRouterNow v4.0")
                .font(.headline)
                .bold()

            Text("Phase 2 — Fan-out")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            // ── Status ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
            }

            // ── TCC-Denied-Warnung ───────────────────────────────────────
            if controller.isSuspectedTCCDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ TCC möglicherweise verweigert")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Systemeinstellungen öffnen →") {
                        controller.openTCCSettings()
                    }
                    .font(.caption)
                }
            }

            // ── Fehler-Anzeige ───────────────────────────────────────────
            if case .error(let e) = controller.status {
                Text(e.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            // ── Metriken (nur bei aktivem Routing) ───────────────────────
            if controller.status == .routing {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Callbacks: \(controller.totalCallbacks)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(controller.hasReceivedAudio ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(controller.hasReceivedAudio ? "Audio erfasst ✓" : "Warte auf Audio…")
                            .font(.caption.monospaced())
                            .foregroundStyle(controller.hasReceivedAudio ? .primary : .secondary)
                    }
                }
            }

            Divider()

            // ── Output-Config-Verwaltung (nur wenn nicht routing) ────────
            if controller.status != .routing {
                Text("Routing-Ziele:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.outputConfigs.isEmpty {
                    Text("Kein Ziel — routet nur Tap")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(controller.outputConfigs, id: \.self) { config in
                        HStack {
                            Text(config.uid.prefix(20))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            if config.channelOffset > 0 {
                                Text("Ch\(config.channelOffset + 1)-\(config.channelOffset + 2)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(action: { controller.removeOutputConfig(config) }) {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Add-Picker: verfügbare Devices; >= 4 Kanäle → Ch1-2 und
                // Ch3-4 separat anbieten (KA6-Fall).
                if !controller.availableDevices.isEmpty {
                    Menu("+ Hinzufügen") {
                        ForEach(controller.availableDevices, id: \.uid) { device in
                            if device.channelCount >= 4 {
                                Button("\(device.name) (Ch1-2)") {
                                    controller.addOutputConfig(
                                        OutputConfig(uid: device.uid, channelOffset: 0)
                                    )
                                }
                                Button("\(device.name) (Ch3-4)") {
                                    controller.addOutputConfig(
                                        OutputConfig(uid: device.uid, channelOffset: 2)
                                    )
                                }
                            } else {
                                Button(device.name) {
                                    controller.addOutputConfig(
                                        OutputConfig(uid: device.uid, channelOffset: 0)
                                    )
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                }

                Divider()
            }

            // ── Start / Stop Button ──────────────────────────────────────
            Button(controller.status == .routing ? "Stop Routing" : "Start Routing") {
                if controller.status == .routing {
                    controller.stopRouting()
                } else {
                    controller.startRouting()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.status == .routing ? .red : .accentColor)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
        // Einmalig Devices laden + Polling alle 0,5 s für Metriken-Update
        .task {
            controller.refreshAvailableDevices()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                controller.poll()
            }
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .idle:    return .gray
        case .routing: return .green
        case .error:   return .red
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle:    return "Idle"
        case .routing: return "Routing → \(controller.outputConfigs.count) Outputs"
        case .error:   return "Fehler"
        }
    }
}
