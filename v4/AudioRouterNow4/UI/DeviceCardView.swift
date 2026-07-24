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

/// Glass-Device-Card für ein einzelnes Output-Ziel.
///
/// Zeigt Gerätename, Kanal-Offset und einen Zustandsindikator (Checkbox im
/// Idle, Spinner beim Start, pulsierender Signal-Punkt im Aktiv-Zustand). Im
/// Aktiv-Zustand ist die Karte antippbar und klappt per Accordion die
/// ``ExpandedDeviceDetail`` (Kanal-Chips, L/R-Meter, Stats) auf. Nicht mehr
/// verbundene Geräte werden abgeblendet, bleiben aber entfernbar.
struct DeviceCardView: View {
    @EnvironmentObject var controller: EngineController
    /// Effektive UI-Phase (bestimmt Indikator + Interaktivität).
    let state: ARNUIState
    /// Das dargestellte Output-Ziel.
    let config: OutputConfig
    /// Accordion-Zustand (nur im Aktiv-Zustand relevant).
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

/// Aufgeklappter Detail-Bereich einer ``DeviceCardView``: Kanal-Chips,
/// L/R-Signal-Meter und das Stats-Grid (Latenz · Puffer · Rate).
struct ExpandedDeviceDetail: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 8)
            ChannelChipsRow(config: config)
            signalMeters
            DeviceVolumeRow(config: config)
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

// MARK: - DeviceSelectionRow

/// IDLE/ERROR-State: Checkbox-Zeile für ein verfügbares Gerät.
/// Multi-Kanal-Geräte (channelCount > 2) erhalten eine Zeile pro
/// Kanal-Paar (Ch1-2, Ch3-4, …) — jedes Paar einzeln togglebar.
struct DeviceSelectionRow: View {
    @EnvironmentObject var controller: EngineController
    let uid: String
    let name: String
    let channelCount: Int

    private var pairCount: Int { max(1, channelCount / 2) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<pairCount, id: \.self) { pair in
                pairRow(offset: pair * 2, showChannels: pairCount > 1)
            }
        }
    }

    /// Bereits ausgewählte Config für uid + offset (channelCount-agnostisch,
    /// damit auch abweichend initialisierte Configs erkannt werden).
    private func selectedConfig(offset: Int) -> OutputConfig? {
        controller.outputConfigs.first {
            $0.uid == uid && $0.channelOffset == offset
        }
    }

    private func pairRow(offset: Int, showChannels: Bool) -> some View {
        let existing = selectedConfig(offset: offset)
        let selected = existing != nil
        return Button {
            if let cfg = existing {
                controller.removeOutputConfig(cfg)
            } else {
                controller.addOutputConfig(OutputConfig(uid: uid, channelOffset: offset))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? ARNColor.accent : Color.secondary)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if showChannels {
                    Text("Ch\(offset + 1)-\(offset + 2)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? ARNColor.cardStrokeActive : ARNColor.cardStroke,
                        lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text("Add device").font(.system(size: 12, weight: .medium))
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

// MARK: - DeviceVolumeRow

/// F16: Per-Gerät-Lautstärke [0…1] — multipliziert mit dem globalen System-Volume.
/// Live-Pfad: Slider → EngineController.setDeviceGain → FanOutEngine.setOutputGain
/// → SlotGains (os_unfair_lock) → IOProc. Kein Warm-Restart, keine Audio-Lücke.
private struct DeviceVolumeRow: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { controller.deviceGain(for: config) },
                    set: { controller.setDeviceGain($0, for: config) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Color.accentColor)
            Text("\(Int(controller.deviceGain(for: config) * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var iconName: String {
        let v = controller.deviceGain(for: config)
        if v > 0.66 { return "speaker.wave.3.fill" }
        if v > 0.33 { return "speaker.wave.2.fill" }
        if v > 0.01 { return "speaker.wave.1.fill" }
        return "speaker.slash.fill"
    }
}
