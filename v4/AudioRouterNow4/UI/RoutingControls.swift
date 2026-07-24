//
//  RoutingControls.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Steuer-Elemente — pulsierender Status-Dot,
//  Mint-Spinner, globaler Volume-Slider, State-Button (Start/Verbinde/Stop)
//  und Footer-Zeile (Launch-at-Login · Beenden).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

// MARK: - PulsingDot

/// Status-Dot mit sanftem Puls (scale + opacity) im aktiven/startenden Zustand.
struct PulsingDot: View {
    let color: Color
    var pulsing: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && animate ? 1.35 : 1.0)
            .opacity(pulsing && animate ? 0.55 : 1.0)
            .animation(pulsing
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                : .default, value: animate)
            .onAppear { animate = true }
            .onChange(of: pulsing) { _, newValue in animate = newValue }
    }
}

// MARK: - MintSpinner

/// Kleiner mint-getönter Spinner für STARTING-Zustände (Geräteliste / Button).
struct MintSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ARNColor.accent)
            .scaleEffect(0.7)
            .frame(width: 12, height: 12)
    }
}

// MARK: - VolumeRow

/// Globaler System-Volume-Slider (nur im ACTIVE-Zustand sichtbar).
/// Extrahiert aus dem bisherigen `volumeSection` der MenuBarView.
struct VolumeRow: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        HStack {
            Image(systemName: controller.isMuted ? "speaker.slash.fill" : volumeIconName)
                .font(.caption)
                .foregroundStyle(controller.isMuted ? .secondary : .primary)
                .frame(width: 16)
            Slider(
                value: Binding(
                    get: { controller.currentVolume },
                    set: { controller.setSystemVolume($0) }
                ),
                in: 0...1
            )
            Text(controller.isMuted ? "Mute" : "\(Int(controller.currentVolume * 100))%")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var volumeIconName: String {
        let v = controller.currentVolume
        if v > 0.66 { return "speaker.wave.3.fill" }
        if v > 0.33 { return "speaker.wave.2.fill" }
        if v > 0.01 { return "speaker.wave.1.fill" }
        return "speaker.fill"
    }
}

// MARK: - RoutingButton

/// Primärer State-Button: Start (idle/error) · Verbinde… (starting) · Stop (active).
struct RoutingButton: View {
    @EnvironmentObject var controller: EngineController
    let state: ARNUIState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func action() {
        switch state {
        case .active:        controller.stopRouting()
        case .idle, .error:  controller.startRouting()
        case .starting:      break
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .idle, .error: Image(systemName: "play.fill")
        case .starting:     MintSpinner()
        case .active:       Image(systemName: "stop.fill")
        }
    }

    private var title: String {
        switch state {
        case .idle, .error: return "Start Routing"
        case .starting:     return "Connecting…"
        case .active:       return "Stop Routing"
        }
    }

    private var disabled: Bool {
        state == .starting || (controller.outputConfigs.isEmpty && !state.isActive)
    }

    private var background: AnyShapeStyle {
        switch state {
        case .idle, .error: return AnyShapeStyle(ARNColor.accent)
        case .starting:     return AnyShapeStyle(.ultraThinMaterial)
        case .active:       return AnyShapeStyle(Color(white: 0.12))
        }
    }

    private var foreground: Color {
        switch state {
        case .idle, .error: return .black
        default:            return ARNColor.accent
        }
    }

    private var borderColor: Color {
        state == .active ? ARNColor.accent.opacity(0.6) : .clear
    }
}

// MARK: - FooterRow

struct FooterRow: View {
    @EnvironmentObject var controller: EngineController
    @EnvironmentObject private var store: TipJarStore
    @State private var showTipJar = false

    var body: some View {
        VStack(spacing: 8) {
            if showTipJar {
                TipJarView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity))
            }
            HStack {
                Toggle("Launch at Login", isOn: $controller.launchAtLogin)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showTipJar.toggle()
                    }
                } label: {
                    Label(showTipJar ? "Hide" : "Support", systemImage: showTipJar ? "xmark" : "heart")
                        .font(.system(size: 11))
                        .foregroundStyle(showTipJar ? Color.secondary : ARNColor.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
