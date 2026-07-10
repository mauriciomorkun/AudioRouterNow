//
//  WaveHeaderView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Animierter 3-Layer-Sinuswellen-Header.
//  `TimelineView(.animation)` + `Canvas` + `.drawingGroup()` (Metal-Compositing).
//  Amplitude und Farbdeckkraft koppeln an `state.waveIntensity`.
//
//  Audio-reaktiv: `controller.waveEnergy` (20fps-Wave-Poll, EMA-geglättet)
//  moduliert Amplitude, Deckkraft, Phase-Push und Glow der Layer — die
//  Wellenform schwingt mit der tatsächlich abgespielten Musik mit.
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
                let midY = size.height * 0.62
                let energy = Double(controller.waveEnergy)
                let baseIntensity = state.waveIntensity          // 0.0 idle, 1.0 active
                let reactiveAmp = baseIntensity * energy

                // (Amplitude pt, Wellenlänge pt, Speed rad/s, Phase-Push rad, Deckkraft)
                // Speed wird bewusst NICHT direkt moduliert: t ist riesig
                // (Sekunden seit 2001) — `t * (speed + Δ)` ergäbe bei jeder
                // Energy-Änderung Phasensprünge. Stattdessen schiebt
                // `energy * push` die Phase bei Beats sanft nach vorn —
                // gleicher visueller Effekt (Welle läuft bei Beats schneller).
                // Amplituden: base + reaktiver Boost
                // Bei energy=0.73 (−16dBFS typisch): Layer1 = 10 + 0.73*45 ≈ 43pt
                let layers: [(amp: Double, len: Double, speed: Double, push: Double, opacity: Double)] = [
                    (10 + reactiveAmp * 45, 200, 0.30, 2.4, 0.90),
                    ( 7 + reactiveAmp * 28, 150, 0.45, 1.6, 0.50 + energy * 0.25),
                    ( 5 + reactiveAmp * 16, 110, 0.65, 1.0, 0.30 + energy * 0.20),
                ]

                for (i, layer) in layers.enumerated() {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY))
                    var x: CGFloat = 0
                    let step: CGFloat = 2
                    while x <= size.width {
                        let phase = (Double(x) / layer.len) * 2 * .pi
                            + t * layer.speed + energy * layer.push
                        let y = midY + sin(phase) * layer.amp * max(0.08, intensity)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += step
                    }
                    let tint = (intensity > 0.5 ? ARNColor.accent : ARNColor.accentDim)
                        .opacity(layer.opacity * (0.35 + 0.65 * intensity))
                    // Glow: Hauptwelle bekommt einen energie-skalierten
                    // Blur-Schein — pulsiert bei Bass.
                    if i == 0, reactiveAmp > 0.02 {
                        ctx.drawLayer { glow in
                            glow.addFilter(.blur(radius: 3 + energy * 5))
                            glow.stroke(
                                path,
                                with: .color(ARNColor.accent.opacity(0.35 * reactiveAmp)),
                                lineWidth: 2.5
                            )
                        }
                    }
                    ctx.stroke(path, with: .color(tint), lineWidth: 1.5)
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
