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

/// Oszilloskop-Header, der echte IOProc-Audiodaten als ±Halbwellen zeichnet.
///
/// Baut auf `TimelineView(.animation)` + `Canvas` + `.drawingGroup()`
/// (Metal-Compositing) für flüssiges Rendern bei bis zu 60 fps. Aktiv liest der
/// Canvas ``EngineController/waveformSnapshot(count:)`` (die RT-sicheren
/// (min, max)-Mono-Paare aus der ``WaveformBridge``); im Idle-Zustand läuft eine
/// subtile Sinus-Fallback-Animation.
///
/// Die Kurve wird pro Snapshot auf die maximale Amplitude NORMALISIERT (füllt
/// stets ~60 % der Höhe), damit auch leise Passagen sichtbar bleiben; unter
/// ~−40 dBFS gilt als Stille und wird als dünne Nulllinie gezeichnet.
struct WaveHeaderView: View {
    /// Effektive UI-Phase (steuert Aktiv-/Idle-Darstellung und Intensität).
    let state: ARNUIState
    @EnvironmentObject private var controller: EngineController

    /// Header-Intensität [0…1] aus dem UI-State — treibt Farbe, Glow und Gradient.
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
                        let scale = size.height * 0.30   // ±30% von Mitte = 60% der Höhe genutzt
                        let step = size.width / CGFloat(samples.count)

                        // Normalisierung: grösste Absolut-Amplitude (|max| bzw.
                        // |min|) über den GESAMTEN Snapshot bestimmen. Diese dient
                        // gleich als Divisor → die lauteste Stelle nutzt immer die
                        // volle Höhe, leise Passagen bleiben trotzdem sichtbar.
                        let maxAmp = samples.reduce(Float32(0)) { acc, s in
                            max(acc, abs(s.max), abs(s.min))
                        }
                        // Silence-Detection: unter 0.01 (~−40 dBFS) würde die
                        // Normalisierung reines Grundrauschen bildschirmfüllend
                        // aufblasen → stattdessen flache Nulllinie zeichnen.
                        let isSilence = maxAmp < 0.01

                        // Vertikale Balken: eine Linie von min→max pro Sample-Spalte
                        // (±Halbwellen um die Nulllinie, wie in Logic/Audacity).
                        var path = Path()
                        for (i, sample) in samples.enumerated() {
                            let x = CGFloat(i) * step
                            if isSilence {
                                // Stille: dünner 1pt-Strich exakt an der Nulllinie.
                                path.move(to: CGPoint(x: x, y: midY - 0.5))
                                path.addLine(to: CGPoint(x: x, y: midY + 0.5))
                            } else {
                                // Auf [−1, 1] normalisieren (Division durch maxAmp)
                                // und mit `scale` (= 30 % Höhe) auf Pixel abbilden.
                                // y wächst nach unten → deshalb midY − n·scale.
                                let nMax = CGFloat(sample.max / maxAmp)
                                let nMin = CGFloat(sample.min / maxAmp)
                                var yMax = midY - nMax * scale
                                var yMin = midY - nMin * scale
                                // Mindesthöhe 1pt, damit sehr leise Spalten nicht
                                // zu einem unsichtbaren 0-Pixel-Balken kollabieren.
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
