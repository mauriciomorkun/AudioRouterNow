//
//  WaveHeaderView.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer): Oszilloskop-Header mit ECHTEN Audiodaten.
//  `Canvas` + `.drawingGroup()` (Metal-Compositing), getaktet vom Audio-Poll.
//
//  Aktiv: Der Canvas liest `controller.waveformFrame(count:)`, also die
//  (min, max)-Mono-Mix-Werte, die der IOProc pro Callback in die
//  RT-sichere `WaveformBridge` schreibt. Gezeichnet werden vertikale Balken
//  (min→max pro Spalte) um eine Nulllinie, echte ±Halbwellen wie in
//  Logic Pro / Audacity: Kick-Drums, Transienten und Dynamik sind sichtbar.
//
//  Idle: subtile Sinus-Animation als Fallback (keine Audiodaten verfügbar).
//
//  v4.0.1: Die Kurve wird zusätzlich um einen Bruchteil einer Spalte nach
//  links versetzt (``WaveformFrame/phase``). Pro Callback trifft genau eine
//  Spalte ein, das passt bei keiner Bildrate glatt auf ganze Spalten. Ohne den
//  Versatz springt die Darstellung abwechselnd um eine und um zwei Spalten,
//  und genau das ist als Ruckeln sichtbar.
//
//  v4.0.1 (CASE-003): Die Zeitachse (`TimelineView`) ist ersatzlos entfallen,
//  der Takt kommt jetzt aus dem Audio-Poll. Damit verschwindet der
//  Display-Cycle-Beobachter, in dem der gemeldete Absturz steht. Ausserdem
//  werden die Sample-Werte gehärtet, bevor daraus Koordinaten entstehen.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

/// Oszilloskop-Header, der echte IOProc-Audiodaten als ±Halbwellen zeichnet.
///
/// Baut auf `Canvas` + `.drawingGroup()` (Metal-Compositing), getaktet vom
/// 20fps-Wave-Poll des Controllers. Aktiv liest der
/// Canvas ``EngineController/waveformFrame(count:)`` (die RT-sicheren
/// (min, max)-Mono-Paare aus der ``WaveformBridge``, dazu die Teilpixel-Phase);
/// im Idle-Zustand steht eine statische Sinuslinie.
///
/// Die Kurve wird pro Snapshot auf die maximale Amplitude NORMALISIERT (füllt
/// stets ~60 % der Höhe), damit auch leise Passagen sichtbar bleiben; unter
/// ~−40 dBFS gilt als Stille und wird als dünne Nulllinie gezeichnet.
struct WaveHeaderView: View {
    /// Effektive UI-Phase (steuert Aktiv-/Idle-Darstellung und Intensität).
    let state: ARNUIState
    @EnvironmentObject private var controller: EngineController

    /// Taktgeber des Canvas. Bewusst getrennt vom Controller injiziert, siehe
    /// ``WaveClock``: an diesem Objekt hängt nur der Header, nicht das Panel.
    @ObservedObject var clock: WaveClock

    /// Hält den geglätteten Normierungsfaktor über Bilder hinweg fest, damit
    /// die Kurvenhöhe nicht bei jedem ein- oder auswandernden Transienten
    /// springt. Siehe ``WaveNormalizer``.
    @State private var normalizer = WaveNormalizer()

    /// Header-Intensität [0…1] aus dem UI-State, treibt Farbe, Glow und Gradient.
    private var intensity: Double { state.waveIntensity }

    /// CASE-003: Der Takt kommt aus dem Audio-Poll, nicht aus dem Display-Cycle.
    ///
    /// Bis 4.0.1 stand hier ein `TimelineView(.animation)`. Das registriert
    /// einen Display-Cycle-Beobachter am Fenster, und genau dort steht der
    /// gemeldete Absturz (`__NSWindowGetDisplayCycleObserver`). Da der View-Baum
    /// eines `MenuBarExtra(.window)`-Panels beim Schliessen NICHT abgebaut wird,
    /// lief die Zeitachse ausserdem unbegrenzt weiter, auch wenn das Panel zu war.
    ///
    /// Zwei Versuche, die Sichtbarkeit des Panels zu ermitteln und die Zeitachse
    /// daran zu pausieren, sind gescheitert: der Key-Status ist falsch (ein
    /// Fenster kann sichtbar sein, ohne Key zu sein, bei einer
    /// `LSUIElement`-App der Normalfall) und `occlusionState` erwies sich als
    /// unzuverlässig. Beide Male fror die Kurve bei offenem Panel ein.
    ///
    /// Jetzt ohne Zeitachse: das Neuzeichnen hängt an
    /// ``WaveClock``, die der ohnehin vorhandene Wave-Poll des Controllers
    /// hochzählt (60 fps). Der läuft nur bei aktivem Routing und wird in
    /// `stopRouting()`
    /// abgebrochen. Damit ruht die Animation im Leerlauf von selbst, es gibt
    /// keinen Display-Cycle-Beobachter mehr, und der Fensterzustand muss
    /// nirgends erraten werden.
    ///
    /// Folge fürs Idle: die Sinuswelle steht still statt zu driften. Bewusst in
    /// Kauf genommen, sie ist reine Dekoration ohne Signalbezug.
    var body: some View {
        // Erzeugt die Abhängigkeit zum Poll-Takt. Ohne diese Zeile zeichnet
        // SwiftUI den Canvas nicht neu, der Wert selbst wird nicht gebraucht.
        let _ = clock.tick
        let t = Date.timeIntervalSinceReferenceDate
        Group {
            Canvas { ctx, size in
                // Entartete Layout-Grössen kommen beim Aufbau und beim Teardown
                // des Panels vor. Ohne diesen Riegel entstünden daraus direkt
                // nicht-endliche oder negative Koordinaten.
                guard size.width.isFinite, size.height.isFinite,
                      size.width >= 1, size.height >= 1 else { return }
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
                    let visibleColumns = max(1, Int(size.width / 2))
                    // Eine Spalte mehr als sichtbar anfordern: die Zeichnung wird
                    // gleich um einen Bruchteil einer Spalte nach links versetzt
                    // und wandert dabei vom rechten Rand weg. Die Reservespalte
                    // sitzt genau am Rand und rückt nach, ohne sie klaffte dort
                    // eine ganze Spalte plus Versatz.
                    let frame = controller.waveformFrame(count: visibleColumns + 1)
                    // CASE-003: Härten, BEVOR aus den Werten Koordinaten werden.
                    // Der Ring kann ±Infinity enthalten, siehe WaveformGeometry.
                    let samples = frame.samples.map(WaveformGeometry.sanitize)
                    if !samples.isEmpty {
                        let scale = size.height * 0.30   // ±30% von Mitte = 60% der Höhe genutzt
                        // Spaltenbreite aus der GELIEFERTEN Menge, nicht aus der
                        // angeforderten: der Ring gibt höchstens seine Kapazität
                        // her. Die n Spalten spannen n-1 Schritte über die Breite,
                        // die letzte sitzt damit genau am rechten Rand.
                        let step = size.width / CGFloat(max(1, samples.count - 1))
                        // Teilpixel-Versatz gegen das Ruckeln: pro Callback trifft
                        // genau eine Spalte ein, bei 86 Callbacks/s und 60 Bildern/s
                        // ist das kein ganzzahliges Verhältnis. Ohne den Bruchteil
                        // springt die Kurve abwechselnd um eine und um zwei Spalten.
                        // Mit ihm läuft sie zwischen zwei Callbacks weiter.
                        let shift = CGFloat(frame.phase) * step

                        // Normalisierung: grösste Absolut-Amplitude (|max| bzw.
                        // |min|) über den GESAMTEN Snapshot bestimmen. Diese dient
                        // gleich als Divisor → die lauteste Stelle nutzt immer die
                        // volle Höhe, leise Passagen bleiben trotzdem sichtbar.
                        //
                        // Über Bilder hinweg geglättet: der Rohwert springt,
                        // sobald ein lauter Schlag in den sichtbaren Ausschnitt
                        // hinein oder rechts wieder hinaus wandert, und mit ihm
                        // spränge die Höhe der ganzen Kurve. Siehe ``WaveNormalizer``.
                        let maxAmp = normalizer.smoothed(
                            towards: WaveformGeometry.normalizationAmplitude(samples))
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
                                let yMax = midY - nMax * scale
                                let yMin = midY - nMin * scale
                                // CASE-003: positiv formuliert. Gezeichnet wird die
                                // echte Spalte nur, wenn beide Koordinaten endlich
                                // sind UND die Spalte mindestens 1pt hoch ist (sonst
                                // kollabierte sie zu einem unsichtbaren 0-Pixel-Balken).
                                // Alles andere fällt auf den sicheren Strich an der
                                // Nulllinie zurück. Die frühere Fassung `if yMin - yMax < 1`
                                // war mit NaN-Koordinaten IMMER falsch und lief damit
                                // genau in dem Fall ins Leere, für den sie gedacht war.
                                guard yMax.isFinite, yMin.isFinite, yMin - yMax >= 1 else {
                                    path.move(to: CGPoint(x: x, y: midY - 0.5))
                                    path.addLine(to: CGPoint(x: x, y: midY + 0.5))
                                    continue
                                }
                                path.move(to: CGPoint(x: x, y: yMax))
                                path.addLine(to: CGPoint(x: x, y: yMin))
                            }
                        }

                        // Eigene Kopie des Kontexts für alles, was mitwandern soll.
                        // `GraphicsContext` ist ein Werttyp, Clip und Verschiebung
                        // enden mit der Kopie. Die Nulllinie ist ohnehin schon
                        // gezeichnet und bleibt deshalb ortsfest, ebenso der
                        // Idle-Zweig im else. Geclippt wird VOR dem Verschieben,
                        // sonst ragte die Reservespalte über den Rand hinaus.
                        var wave = ctx
                        wave.clip(to: Path(CGRect(origin: .zero, size: size)))
                        wave.translateBy(x: -shift, y: 0)

                        // Glow: energie-skalierter Blur-Schein hinter der Waveform
                        if state.isActive, energy > 0.02, !isSilence {
                            wave.drawLayer { glow in
                                glow.addFilter(.blur(radius: 2.5))
                                glow.stroke(path, with: .color(ARNColor.accent.opacity(0.25)), lineWidth: 3)
                            }
                        }
                        let waveColor = ARNColor.accent
                            .opacity(0.85 * max(0.1, intensity))
                        wave.stroke(path, with: .color(waveColor), lineWidth: 1.5)
                    }
                } else {
                    // Bezugswert fallen lassen, sonst startete die Kurve beim
                    // nächsten Routing mit dem Maßstab der letzten Sitzung und
                    // wäre für einen Moment sichtbar zu flach oder zu hoch.
                    normalizer.reset()
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
            // Metal-Compositing für ruckelfreie Kurve.
            // CASE-003, offener Punkt: drawingGroup gilt als Verstärker des
            // Absturzes (es verlagert das Zeichnen in eine eigene Render-Passe).
            // Bleibt bis zur Reproduktionsmessung drin, ein Entfernen ohne
            // Messung wäre geraten, nicht belegt.
            .drawingGroup()
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

// `initiallyVisible: true`, weil in der Preview kein Panel-Fenster existiert,
// das Key werden könnte. Ohne den Schalter bliebe die Zeitachse pausiert und
// die Vorschau zeigte ein Standbild.
#Preview("Idle") {
    WaveHeaderView(state: .idle, clock: WaveClock())
        .environmentObject(EngineController())
        .frame(width: 320)
}

#Preview("Active") {
    WaveHeaderView(state: .active, clock: WaveClock())
        .environmentObject(EngineController())
        .frame(width: 320)
}
