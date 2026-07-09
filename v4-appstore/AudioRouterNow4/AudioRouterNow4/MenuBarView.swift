//
//  MenuBarView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B "Fusion Prominent Wave + Accordion Expand"):
//  Container-View — animierter Wellen-Header, Status-Bar, Volume-Slider,
//  Accordion-Geräteliste, State-Button und Footer.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

struct MenuBarView: View {

    @EnvironmentObject var controller: EngineController

    var body: some View {
        let ui = ARNUIState(status: controller.status, isStarting: controller.isStarting)
        VStack(alignment: .leading, spacing: 0) {

            // ── Wellen-Header ────────────────────────────────────────────
            WaveHeaderView(state: ui)

            // ── Status-Bar ───────────────────────────────────────────────
            statusBar(ui)

            // ── TCC-Warnung (unverändert übernommen) ─────────────────────
            if controller.isSuspectedTCCDenied {
                tccWarningSection
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // ── Fehler (unverändert übernommen) ──────────────────────────
            if case .error(let e) = controller.status {
                errorSection(e)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // ── Volume-Slider (nur ACTIVE) ───────────────────────────────
            if ui == .active {
                VolumeRow()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider()
            }

            // ── Accordion-Geräteliste ────────────────────────────────────
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(controller.outputConfigs, id: \.self) { cfg in
                        DeviceCardView(state: ui, config: cfg)
                    }
                    AddDeviceRow()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(maxHeight: 320)

            Divider()

            // ── State-Button + Footer ────────────────────────────────────
            VStack(spacing: 10) {
                RoutingButton(state: ui)
                FooterRow()
            }
            .padding(14)
        }
        .frame(width: 320)
        .onAppear {
            // W5: SMAppService-Status bei jedem Öffnen neu spiegeln
            // (Onboarding registriert direkt; User kann in Systemeinstellungen entfernen).
            controller.refreshLaunchAtLoginStatus()
        }
        .task {
            controller.refreshAvailableDevices()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                controller.refreshAvailableDevices()
            }
        }
    }

    // MARK: Status-Bar (inline, §4.4)

    private func statusBar(_ ui: ARNUIState) -> some View {
        HStack(spacing: 7) {
            PulsingDot(color: dotColor(ui), pulsing: ui == .active || ui == .starting)
            Text(statusText(ui))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if ui == .active {
                Text("CBs \(controller.totalCallbacks)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func dotColor(_ ui: ARNUIState) -> Color {
        switch ui {
        case .idle:     return ARNColor.statusDotIdle
        case .starting: return ARNColor.accent
        case .active:   return controller.hasReceivedAudio ? ARNColor.accent : .yellow
        case .error:    return .red
        }
    }

    private func statusText(_ ui: ARNUIState) -> String {
        switch ui {
        case .idle:     return "Kein Routing aktiv"
        case .starting: return "Verbinde Geräte…"
        case .active:
            let n = controller.outputConfigs.count
            return controller.hasReceivedAudio
                ? "Routing → \(n) Gerät\(n == 1 ? "" : "e")"
                : "Warte auf Audio…"
        case .error:    return "Fehler"
        }
    }

    // MARK: TCC-Warnung (unverändert aus dem Ist-Stand)

    private var tccWarningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("System Audio Recording permission missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Either grant permission in System Settings, or the current source plays DRM-protected content (Apple Music, Netflix, TV+) — macOS does not expose DRM audio to any app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings →") {
                controller.openTCCSettings()
            }
            .font(.caption)
        }
    }

    // MARK: Fehler (unverändert aus dem Ist-Stand)

    @ViewBuilder
    private func errorSection(_ error: RouterError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }
}
