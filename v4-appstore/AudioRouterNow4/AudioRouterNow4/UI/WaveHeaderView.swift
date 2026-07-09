//
//  WaveHeaderView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Animierter 3-Layer-Sinuswellen-Header.
//  `TimelineView(.animation)` + `Canvas` + `.drawingGroup()` (Metal-Compositing).
//  Amplitude und Farbdeckkraft koppeln an `state.waveIntensity`.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI

struct WaveHeaderView: View {
    let state: ARNUIState

    private var intensity: Double { state.waveIntensity }

    // (Amplitude pt, Wellenlänge pt, Speed rad/s, Deckkraft)
    private let layers: [(amp: Double, len: Double, speed: Double, opacity: Double)] = [
        (10, 200, 0.30, 0.90),
        (7,  150, 0.45, 0.50),
        (5,  110, 0.65, 0.30),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let midY = size.height * 0.62
                for layer in layers {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY))
                    var x: CGFloat = 0
                    let step: CGFloat = 2
                    while x <= size.width {
                        let phase = (Double(x) / layer.len) * 2 * .pi + t * layer.speed
                        let y = midY + sin(phase) * layer.amp * max(0.08, intensity)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += step
                    }
                    let tint = (intensity > 0.5 ? ARNColor.accent : ARNColor.accentDim)
                        .opacity(layer.opacity * (0.35 + 0.65 * intensity))
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
    WaveHeaderView(state: .idle).frame(width: 320)
}

#Preview("Active") {
    WaveHeaderView(state: .active).frame(width: 320)
}
