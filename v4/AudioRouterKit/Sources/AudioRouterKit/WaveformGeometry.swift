//
//  WaveformGeometry.swift
//  AudioRouterKit
//
//  v4.0.1 (CASE-003): Härtung der Waveform-Normalisierung gegen nicht-endliche
//  Sample-Werte, bevor sie in eine CoreGraphics-Koordinate wandern.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation

/// Reine Rechenhilfen für die Oszilloskop-Darstellung.
///
/// Bewusst im Kit statt in der View: hier ist der Code ohne UI-Bootstrap
/// testbar. Und bewusst NACH dem Ring, nicht im IOProc: der RT-Pfad bleibt
/// unangetastet, die Prüfung kostet nur auf dem MainActor Zeit.
///
/// ## Warum `isFinite` und nicht `isNaN`
/// Die Engine sammelt pro Spalte Min und Max über `if s < wMin` bzw.
/// `if s > wMax` (``FanOutEngine``). Ein NaN scheitert an BEIDEN Vergleichen
/// und landet deshalb nie im Ring, davor muss hier niemand schützen.
/// Ein Infinity dagegen gewinnt jeden Vergleich und wird sauber eingetragen.
/// Ab da genügt ein einziges Inf-Sample, um die Normalisierung zu zerstören:
/// die grösste Absolut-Amplitude wird Inf, und Inf/Inf ergibt NaN. Jede daraus
/// berechnete y-Koordinate ist dann NaN, und ein NaN in einem `CGPoint` ist der
/// Punkt, an dem CoreGraphics im Display-Cycle abbricht.
public enum WaveformGeometry {

    /// Macht einen einzelnen Sample-Wert zeichenbar: nicht-endliche Werte
    /// (±Infinity, NaN) werden zu 0, alles andere wird auf [-1, 1] geklemmt.
    ///
    /// Das Klemmen ist nicht bloss Kosmetik. Ein Sample über 1.0 (möglich, wenn
    /// eine Quelle über Vollaussteuerung hinaus liefert) würde die Kurve aus dem
    /// Header herauszeichnen.
    ///
    /// - Parameter value: Roher Sample-Wert aus dem Waveform-Ring.
    /// - Returns: Endlicher Wert in [-1, 1].
    public static func sanitize(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        return Swift.max(-1, Swift.min(1, value))
    }

    /// Wendet ``sanitize(_:)`` auf ein komplettes (min, max)-Paar an.
    ///
    /// - Parameter sample: Rohes Spalten-Paar aus dem Waveform-Ring.
    /// - Returns: Paar, dessen beide Komponenten endlich und in [-1, 1] liegen.
    public static func sanitize(_ sample: (min: Float32, max: Float32)) -> (min: Float32, max: Float32) {
        (min: sanitize(sample.min), max: sanitize(sample.max))
    }

    /// Divisor für die Normalisierung: die grösste Absolut-Amplitude über den
    /// gesamten Snapshot.
    ///
    /// Nicht-endliche Werte werden übersprungen statt den Gesamtwert zu
    /// vergiften. Das Ergebnis ist damit garantiert endlich und >= 0, auch wenn
    /// JEDER Eingabewert nicht-endlich war oder das Array leer ist (dann 0).
    ///
    /// - Important: Der Rückgabewert kann 0 sein. Aufrufer dürfen nicht
    ///   ungeprüft durch ihn dividieren, die Silence-Schwelle der View fängt
    ///   diesen Fall ab.
    ///
    /// - Parameter samples: Snapshot aus (min, max)-Paaren.
    /// - Returns: Endliche, nicht-negative Referenz-Amplitude.
    public static func normalizationAmplitude(_ samples: [(min: Float32, max: Float32)]) -> Float32 {
        var amplitude: Float32 = 0
        for sample in samples {
            if sample.max.isFinite {
                amplitude = Swift.max(amplitude, abs(sample.max))
            }
            if sample.min.isFinite {
                amplitude = Swift.max(amplitude, abs(sample.min))
            }
        }
        // abs() eines endlichen Wertes ist endlich, der Startwert ist 0:
        // das Ergebnis kann die Schleife nicht nicht-endlich verlassen.
        return amplitude
    }
}
