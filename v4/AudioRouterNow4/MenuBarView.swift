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

/// Wurzel-View des Menu-Bar-Panels (Konzept 4B „Fusion Prominent Wave +
/// Accordion Expand").
///
/// Komponiert von oben nach unten: animierter Wellen-Header, Status-Bar,
/// optionale TCC-/Fehler-Hinweise, Volume-Slider (nur aktiv), Accordion-
/// Geräteliste sowie Start/Stop-Button und Footer. Die effektive UI-Phase wird
/// aus `controller.status` + `controller.isStarting` zu einem ``ARNUIState``
/// verdichtet und steuert, welche Sektionen erscheinen.
///
/// - Note: `.fixedSize(…vertical: true)` ist notwendig, weil ein
///   `MenuBarExtra(.window)`-Panel sonst keine korrekte Inhaltshöhe erhält.
struct MenuBarView: View {

    /// Der geteilte Engine-Controller (injiziert von ``AudioRouterNowApp``).
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

            // ── Geräteliste (IDLE: Auswahl-Checkboxen · ACTIVE: Accordion) ─
            deviceListSection(ui)

            Divider()

            // ── State-Button + Footer ────────────────────────────────────
            VStack(spacing: 10) {
                RoutingButton(state: ui)
                FooterRow()
            }
            .padding(14)
        }
        .frame(width: 320)
        // Bug-Fix: MenuBarExtra(.window)-Panel erhält sonst keine korrekte
        // Inhaltshöhe — fixedSize erzwingt die ideale vertikale Größe.
        .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Geräteliste

    /// IDLE/ERROR: alle verfügbaren Geräte als togglebare Checkbox-Zeilen
    /// (plus nicht mehr verbundene, aber noch konfigurierte Geräte —
    /// damit stale Configs entfernbar bleiben).
    /// STARTING/ACTIVE: laufende Outputs als Accordion-Cards + AddDeviceRow.
    @ViewBuilder
    private func deviceListSection(_ ui: ARNUIState) -> some View {
        VStack(spacing: 8) {
            switch ui {
            case .idle, .error:
                ForEach(controller.availableDevices, id: \.uid) { device in
                    DeviceSelectionRow(
                        uid: device.uid,
                        name: device.name,
                        channelCount: device.channelCount)
                }
                // Konfigurierte, aber aktuell getrennte Geräte weiterhin
                // anzeigen, damit sie abgewählt werden können.
                ForEach(staleConfigs, id: \.self) { cfg in
                    DeviceCardView(state: ui, config: cfg)
                }
            case .starting, .active:
                ForEach(controller.outputConfigs, id: \.self) { cfg in
                    DeviceCardView(state: ui, config: cfg)
                }
                AddDeviceRow()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Ausgewählte Outputs, deren Gerät gerade nicht verbunden ist.
    private var staleConfigs: [OutputConfig] {
        controller.outputConfigs.filter { cfg in
            !controller.availableDevices.contains { $0.uid == cfg.uid }
        }
    }

    // MARK: Status-Bar (inline, §4.4)

    /// Status-Zeile: Puls-Punkt (Farbe/Animation je Phase) + Text; im Aktiv-
    /// Zustand zusätzlich der monospaced Callback-Zähler.
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

    /// Farbe des Status-Punkts je Phase (aktiv: mint bei Audio, sonst gelb).
    private func dotColor(_ ui: ARNUIState) -> Color {
        switch ui {
        case .idle:     return ARNColor.statusDotIdle
        case .starting: return ARNColor.accent
        case .active:   return controller.hasReceivedAudio ? ARNColor.accent : .yellow
        case .error:    return .red
        }
    }

    /// Lokalisierter Status-Text je Phase (inkl. Geräte-Zählung im Aktiv-Zustand).
    private func statusText(_ ui: ARNUIState) -> String {
        switch ui {
        case .idle:     return "No routing active"
        case .starting: return "Connecting devices…"
        case .active:
            let n = controller.outputConfigs.count
            return controller.hasReceivedAudio
                ? "Routing → \(n) device\(n == 1 ? "" : "s")"
                : "Waiting for audio…"
        case .error:    return "Error"
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
