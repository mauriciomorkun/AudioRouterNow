//
//  WaveHeaderView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer): Oszilloskop-Header mit ECHTEN Audiodaten.
//  `TimelineView(.animation)` + `Canvas` + `.drawingGroup()` (Metal-Compositing).
//
//  Aktiv: Der Canvas liest bei 60fps `controller.waveformSnapshot(count:)` —
//  die (min, max)-Mono-Mix-Werte, die der IOProc pro Callback in die
//  RT-sichere `WaveformBridge` schreibt. Gezeichnet werden vertikale Balken
//  (min→max pro Spalte) um eine Nulllinie — echte ±Halbwellen wie in
//  Logic Pro / Audacity: Kick-Drums, Transienten und Dynamik sind sichtbar.
//
//  Idle: subtile Sinus-Animation als Fallback (keine Audiodaten verfügbar).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI

struct WaveHeaderView: View {
    let state: ARNUIState
    @EnvironmentObject private var controller: EngineController

    private var intensity: Double { state.waveIntensity }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let midY = size.height * 0.55
                let energy = Double(controller.waveEnergy)

                // ── Nulllinie (Oszilloskop-Referenz) ─────────────────────
                var zeroLine = Path()
                zeroLine.move(to: CGPoint(x: 0, y: midY))
                zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
                ctx.stroke(zeroLine, with: .color(Color.white.opacity(0.08)), lineWidth: 0.5)

                if state.isActive || state.isStarting {
                    // ── Oszilloskop: echte IOProc-Samples ────────────────
                    // 2pt pro Sample-Spalte (320pt → 160 Samples ≈ 1,9 s Audio).
                    let sampleCount = max(1, Int(size.width / 2))
                    let samples = controller.waveformSnapshot(count: sampleCount)
                    if !samples.isEmpty {
                        let scale = size.height * 0.75   // voller Ausschlag = 75% der Höhe
                        let step = size.width / CGFloat(samples.count)

                        // Normalisierung: maximale Amplitude im aktuellen Snapshot finden.
                        // Unter 0.01 (~−40 dBFS) gilt als Stille → dünne Linie statt
                        // aufgebauschtem Rauschen.
                        let maxAmp = samples.reduce(Float32(0)) { acc, s in
                            max(acc, abs(s.max), abs(s.min))
                        }
                        let isSilence = maxAmp < 0.01

                        // Vertikale Balken: min→max pro Spalte (±Halbwellen)
                        var path = Path()
                        for (i, sample) in samples.enumerated() {
                            let x = CGFloat(i) * step
                            if isSilence {
                                // Stille: dünne horizontale Linie an der Nulllinie
                                path.move(to: CGPoint(x: x, y: midY - 0.5))
                                path.addLine(to: CGPoint(x: x, y: midY + 0.5))
                            } else {
                                // Normalisiert auf ±1.0 → füllt immer den vollen Bereich
                                let nMax = CGFloat(sample.max / maxAmp)
                                let nMin = CGFloat(sample.min / maxAmp)
                                var yMax = midY - nMax * scale
                                var yMin = midY - nMin * scale
                                // Mindesthöhe 1pt
                                if yMin - yMax < 1 {
                                    yMax = midY - 0.5
                                    yMin = midY + 0.5
                                }
                                path.move(to: CGPoint(x: x, y: yMax))
                                path.addLine(to: CGPoint(x: x, y: yMin))
                            }
                        }

                        // Glow: energie-skalierter Blur-Schein hinter der Waveform
                        if state.isActive, energy > 0.02, !isSilence {
                            ctx.drawLayer { glow in
                                glow.addFilter(.blur(radius: 2.5))
                                glow.stroke(path, with: .color(ARNColor.accent.opacity(0.25)), lineWidth: 3)
                            }
                        }
                        let waveColor = ARNColor.accent
                            .opacity(0.85 * max(0.1, intensity))
                        ctx.stroke(path, with: .color(waveColor), lineWidth: 1.5)
                    }
                } else {
                    // ── Idle-Fallback: subtile Sinus-Animation ───────────
                    let amp = 6.0 * max(0.08, intensity)
                    var sinePath = Path()
                    var x: CGFloat = 0
                    while x <= size.width {
                        let phase = (Double(x) / 180.0) * 2 * .pi + t * 0.25
                        let y = midY + sin(phase) * amp
                        if x == 0 { sinePath.move(to: CGPoint(x: x, y: y)) }
                        else { sinePath.addLine(to: CGPoint(x: x, y: y)) }
                        x += 2
                    }
                    ctx.stroke(sinePath, with: .color(ARNColor.accentDim.opacity(0.5)), lineWidth: 1)
                }
            }
            .drawingGroup()   // Metal-Compositing für ruckelfreie Kurve
        }
        .frame(height: 112)
        .background(headerGradient)
        .overlay(alignment: .topLeading) { titleOverlay }
        .animation(.easeInOut(duration: 0.4), value: intensity)
    }

    private var headerGradient: LinearGradient {
        let hot = intensity > 0.5
        return LinearGradient(
            colors: [hot ? ARNColor.headerTop : ARNColor.headerTopDim,
                     hot ? ARNColor.headerBottom : ARNColor.headerBottomDim],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var titleOverlay: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .foregroundStyle(intensity > 0.5 ? ARNColor.accent : Color.secondary)
            Text("AudioRouterNow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}

#Preview("Idle") {
    WaveHeaderView(state: .idle)
        .environmentObject(EngineController())
        .frame(width: 320)
}

#Preview("Active") {
    WaveHeaderView(state: .active)
        .environmentObject(EngineController())
        .frame(width: 320)
}
