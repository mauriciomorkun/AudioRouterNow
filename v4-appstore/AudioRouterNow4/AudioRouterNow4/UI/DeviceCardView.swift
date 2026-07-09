//
//  DeviceCardView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Glass-Device-Card mit Accordion-Expand,
//  Kanal-Chips, L/R-Signal-Metern, Stats-Grid (Latenz · Puffer · Rate) und der
//  Add-Device-Zeile (Menu).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

// MARK: - DeviceCardView

struct DeviceCardView: View {
    @EnvironmentObject var controller: EngineController
    let state: ARNUIState
    let config: OutputConfig
    @State private var expanded = false

    private var deviceName: String {
        controller.availableDevices.first { $0.uid == config.uid }?.name
            ?? String(config.uid.prefix(24))
    }
    private var isAvailable: Bool {
        controller.availableDevices.contains { $0.uid == config.uid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.isActive, expanded {
                ExpandedDeviceDetail(config: config)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity))
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(strokeColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(state.isStarting ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard state.isActive else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                expanded.toggle()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            leadingIndicator
            Text(deviceName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isAvailable ? .primary : .tertiary)
            if config.channelOffset > 0 {
                Text("Ch\(config.channelOffset + 1)-\(config.channelOffset + 2)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isActive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            removeButton
        }
    }

    @ViewBuilder private var leadingIndicator: some View {
        switch state {
        case .idle, .error:
            Image(systemName: "checkmark.square.fill")   // in outputConfigs = checked
                .foregroundStyle(ARNColor.accent)
                .font(.system(size: 13))
        case .starting:
            MintSpinner()
        case .active:
            Circle()
                .fill(signalColor)
                .frame(width: 8, height: 8)
        }
    }

    private var signalColor: Color {
        guard isAvailable, let p = controller.peak(for: config) else {
            return Color.secondary.opacity(0.35)
        }
        return (p.l + p.r) > 0.001 ? ARNColor.accent : Color.secondary.opacity(0.5)
    }

    private var removeButton: some View {
        Button { controller.removeOutputConfig(config) } label: {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var strokeColor: Color {
        state.isActive && expanded ? ARNColor.cardStrokeActive : ARNColor.cardStroke
    }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
    }
}

// MARK: - ExpandedDeviceDetail

struct ExpandedDeviceDetail: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 8)
            ChannelChipsRow(config: config)
            signalMeters
            StatsGrid(config: config)
        }
        .padding(.top, 2)
    }

    private var peak: (l: Float32, r: Float32) { controller.peak(for: config) ?? (0, 0) }

    private var signalMeters: some View {
        VStack(spacing: 5) {
            SignalMeter(label: "L", linear: peak.l)
            SignalMeter(label: "R", linear: peak.r)
        }
    }
}

// MARK: - ChannelChipsRow

/// Kanalpaar-Chips aus channelOffset + channelCount.
struct ChannelChipsRow: View {
    let config: OutputConfig
    /// Standard-Kanalnamen (WAVE-Reihenfolge): L, R, C, LFE, Ls, Rs, …
    private static let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb"]

    private var labels: [String] {
        let start = config.channelOffset
        let count = max(1, config.channelCount)
        return (start..<start + count).map { i in
            i < Self.names.count ? Self.names[i] : "Ch\(i + 1)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(ARNColor.accent.opacity(0.18)))
                    .foregroundStyle(ARNColor.accent)
            }
            Spacer()
        }
    }
}

// MARK: - SignalMeter

/// Ein Signal-Balken (L oder R) mit dBFS-Wert.
struct SignalMeter: View {
    let label: String
    let linear: Float32

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ARNColor.meterTrack)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [ARNColor.accent.opacity(0.7), ARNColor.accent],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * ARNAudioMath.meterFraction(linear))
                        .animation(.linear(duration: 0.12), value: linear)
                }
            }
            .frame(height: 6)
            Text(dbLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 42, alignment: .trailing)
        }
    }

    private var dbLabel: String {
        let db = ARNAudioMath.dbfs(linear)
        return db <= -60 ? "−∞" : String(format: "%.0f dB", db)
    }
}

// MARK: - StatsGrid

/// Latenz · Puffer · Rate.
struct StatsGrid: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    private var latency: DeviceLatencyInfo? { controller.latency(for: config) }

    var body: some View {
        HStack(spacing: 0) {
            stat("Latenz", latency.map { String(format: "%.1f ms", $0.totalMilliseconds) } ?? "–")
            divider
            stat("Puffer", "\(controller.bufferFrames)")
            divider
            stat("Rate", latency.map { String(format: "%.1f kHz", $0.sampleRate / 1000) } ?? "–")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 20)
    }
}

// MARK: - AddDeviceRow

struct AddDeviceRow: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        Menu {
            ForEach(controller.availableDevices, id: \.uid) { device in
                let pairCount = max(1, device.channelCount / 2)
                if pairCount == 1 {
                    Button(device.name) {
                        controller.addOutputConfig(OutputConfig(uid: device.uid, channelOffset: 0))
                    }
                } else {
                    ForEach(0..<pairCount, id: \.self) { pair in
                        let offset = pair * 2
                        Button("\(device.name) (Ch\(offset + 1)-\(offset + 2))") {
                            controller.addOutputConfig(OutputConfig(uid: device.uid, channelOffset: offset))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(ARNColor.accent)
                Text("Gerät hinzufügen").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }
}
