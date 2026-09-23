//
//  WaveformBridge.swift
//  AudioRouterKit
//
//  RT-sichere Brücke für Oszilloskop-Daten: IOProc schreibt pro Callback einen
//  (min, max)-Mono-Mix-Wert. Main-Thread liest Snapshot bei 60fps ohne Locks
//  im Hot-Path zu halten.
//
//  Muster: identisch mit PeakMeters (os_unfair_lock, vorallozierter Storage).
//
//  v4.0.1: Der Ring misst zusätzlich den zeitlichen Abstand seiner eigenen
//  Befüllung. Daraus entsteht die Teilpixel-Phase, mit der die Darstellung
//  zwischen zwei eintreffenden Paaren weiterläuft statt spaltenweise zu
//  springen (siehe ``WaveformFrame``).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import QuartzCore
import os

/// Ein Oszilloskop-Bild: die letzten Sample-Paare plus der Bruchteil einer
/// Spalte, um den die Zeichnung nach links versetzt werden muss.
///
/// ## Warum das Ruckeln ohne Phase strukturell ist
/// Der IOProc liefert pro Callback GENAU ein Paar, bei 44100 Hz und 512 Frames
/// also 86,1 Paare pro Sekunde. Bei 2 pt Spaltenbreite sind das 172,2 pt/s, bei
/// 60 Bildern pro Sekunde 2,87 pt pro Bild. Das ist kein Vielfaches der
/// Spaltenbreite: die Zeichnung springt abwechselnd um eine und um zwei
/// Spalten. Eine höhere Bildrate ändert daran nichts, der Bruchteil muss im
/// Versatz landen.
///
/// ## Warum Samples und Phase EIN Wert sind
/// Beide werden unter DERSELBEN Lock-Sektion gelesen. Das spart pro Bild eine
/// Sperre und schliesst aus, dass zwischen beiden Lesevorgängen ein Push
/// dazwischenkommt. Sonst gehörte die Phase bereits zum nächsten Paar, während
/// die Samples noch das vorige zeigen, und die Kurve zuckte um eine Spalte
/// zurück.
public struct WaveformFrame: Sendable {
    /// (min, max)-Paare in chronologischer Reihenfolge, oldest → newest.
    public let samples: [(min: Float32, max: Float32)]

    /// Anteil [0, 1] der Zeit, die seit dem neuesten Paar vergangen ist,
    /// gemessen am geglätteten Abstand zweier Paare. 0, solange nichts
    /// gemessen werden konnte.
    public let phase: Double
}

/// Ring-Buffer-Box für (min, max)-Sample-Paare. Single-Writer (IOProc-Thread),
/// Single-Reader (MainActor bei 60fps). RT-safe: eine `os_unfair_lock`-Sektion
/// pro Zugriff (< 100 ns), keine Allokation im Audio-Pfad.
///
/// - `@unchecked Sendable`: geteilter Zustand ausschliesslich über `_lock`
///   serialisiert; `storage` wird EINMAL bei `init` alloziert und erst im
///   `deinit` (nach `AudioDeviceStop`, RT-Pfad ruht) freigegeben.
final class WaveformBridge: @unchecked Sendable {
    /// Ring-Buffer-Kapazität in (min, max)-Paaren.
    ///
    /// MUSS eine Zweierpotenz sein: das Wrap-around wird per Bitmaske
    /// `index & (capacity - 1)` statt `index % capacity` berechnet (schneller,
    /// verzweigungsfrei, RT-sicher). 256 Paare ≈ 3 s Historie bei ~86
    /// IOProc-Callbacks/s (44100 Hz / 512 Frames).
    static let capacity = 256

    /// Glättungsgewicht der EMA über den Abstand zweier `push()`-Aufrufe.
    ///
    /// 0.1 entspricht einer Zeitkonstante von rund 10 Callbacks, bei ~86
    /// Callbacks/s also gut 100 ms. Kurz genug, damit ein Wechsel von
    /// Samplerate oder Puffergrösse binnen eines Sekundenbruchteils übernommen
    /// wird. Lang genug, dass der übliche Scheduling-Jitter eines einzelnen
    /// Callbacks die Scrollgeschwindigkeit nicht sichtbar wackeln lässt, und
    /// genau dieses Wackeln zu vermeiden ist der ganze Zweck der Messung.
    private static let intervalSmoothing: Double = 0.1

    /// Untere Plausibilitätsgrenze für den Abstand zweier Callbacks: 0,5 ms.
    /// Darunter liegt kein realer CoreAudio-Callback, das wären 22 Frames bei
    /// 44,1 kHz oder 96 Frames bei 192 kHz. Kleinere Werte entstehen nur, wenn
    /// zwei Pushes unmittelbar aufeinander folgen (Warm-Restart, Testcode).
    private static let minPushInterval: Double = 0.0005

    /// Obere Plausibilitätsgrenze: 250 ms. Der grösste übliche Puffer (4096
    /// Frames) dauert bei 44,1 kHz 93 ms, liegt also klar darunter. Alles
    /// darüber ist keine Messung, sondern eine Lücke: Warm-Restart, angehaltene
    /// Wiedergabe, Gerätewechsel. Solche Werte dürfen die Glättung nicht
    /// vergiften, sonst kröche die Kurve danach sekundenlang.
    private static let maxPushInterval: Double = 0.25

    /// Serialisiert Writer (IOProc) gegen Reader (MainActor). `os_unfair_lock`
    /// bietet Priority Inheritance → der niedrig-priorisierte Reader kann den
    /// RT-Writer nicht per Priority Inversion blockieren.
    private var _lock = os_unfair_lock_s()

    /// Vorab-allozierter Backing-Store, interleaved als `[min0, max0, min1, max1, …]`.
    /// Einmalige Allokation im `init`, im Audio-Pfad wird NIE alloziert.
    private let storage: UnsafeMutableBufferPointer<Float32>

    /// Monoton wachsender Schreib-Cursor (Anzahl je gepushter Paare). Wird nur
    /// vom IOProc-Pfad unter `_lock` inkrementiert; via Bitmaske auf `capacity`
    /// zurückgefaltet. Overflow ist unkritisch (`&+=`, wrapping), nur die
    /// unteren `log2(capacity)` Bits werden ausgewertet.
    private var writeIndex: Int = 0

    /// Zeitquelle in Sekunden, monoton wachsend. Siehe `init(clock:)`.
    private let clock: @Sendable () -> Double

    /// Zeitpunkt des letzten `push()`. `nil`, solange noch kein Paar
    /// eingetroffen ist oder seit dem letzten `reset()`.
    private var lastPushTime: Double?

    /// Geglätteter Abstand zweier `push()`-Aufrufe in Sekunden. `nil`, solange
    /// weniger als zwei plausible Pushes vorliegen. Nur dann lässt sich die
    /// Phase überhaupt berechnen.
    private var smoothedInterval: Double?

    /// Alloziert den Backing-Store (2 Slots pro Paar) und nullt ihn.
    ///
    /// - Parameter clock: Zeitquelle in Sekunden. Vorgabe ist
    ///   `CACurrentMediaTime()`, also die Mach-Timebase. Der Parameter existiert
    ///   ausschliesslich, damit die Phasenberechnung ohne echte Wartezeiten
    ///   testbar ist; die Produktion setzt ihn nie.
    init(clock: @escaping @Sendable () -> Double = { CACurrentMediaTime() }) {
        self.clock = clock
        storage = UnsafeMutableBufferPointer<Float32>.allocate(capacity: Self.capacity * 2)
        storage.initialize(repeating: 0)
    }

    /// Gibt den Backing-Store frei. Läuft erst NACH `AudioDeviceStop` (RT-Pfad
    /// ruht) → keine Use-after-free-Gefahr.
    deinit { storage.deallocate() }

    /// Schreibt das (min, max)-Paar des aktuellen Callbacks in den Ring.
    ///
    /// - Parameters:
    ///   - min: kleinster (signed) Mono-Mix-Sample-Wert dieses Callbacks.
    ///   - max: grösster (signed) Mono-Mix-Sample-Wert dieses Callbacks.
    /// - Warning: RT-sicher, aber NUR vom IOProc-Thread aufrufen (Single-Writer).
    ///   Hält `_lock` für eine konstante, allokationsfreie O(1)-Sektion (< 100 ns).
    func push(min: Float32, max: Float32) {
        os_unfair_lock_lock(&_lock)
        // Bitmaske statt Modulo (capacity = Zweierpotenz): faltet den monotonen
        // Cursor auf [0, capacity) zurück. `idx * 2` / `+ 1` adressieren das
        // interleaved (min, max)-Paar.
        let idx = writeIndex & (Self.capacity - 1)
        storage[idx * 2]     = min
        storage[idx * 2 + 1] = max
        // Wrapping-Increment: bei Int-Overflow harmlos, da nur die unteren Bits zählen.
        writeIndex &+= 1

        // Der Ring misst den Abstand seiner Befüllung SELBST, statt Samplerate
        // und Puffergrösse durchgereicht zu bekommen. Damit stimmt die Messung
        // auch nach einem Geräte- oder Ratenwechsel von allein, und es braucht
        // keine zusätzliche Verdrahtung durch drei Schichten.
        //
        // RT-Sicherheit: `CACurrentMediaTime()` liest die Mach-Timebase
        // (`mach_absolute_time()`), ohne Syscall, ohne Allokation, ohne
        // zusätzliches Lock. Der Aufruf liegt INNERHALB der bereits
        // bestehenden Sektion, es kommt keine zweite Sperre dazu.
        let now = clock()
        if let last = lastPushTime {
            let delta = now - last
            // Unplausible Abstände werden verworfen, nicht geglättet: ein
            // einzelner Ausreisser (Pause, Warm-Restart) würde den Mittelwert
            // sonst für viele Callbacks verfälschen.
            if delta >= Self.minPushInterval, delta <= Self.maxPushInterval {
                if let smoothed = smoothedInterval {
                    smoothedInterval = Self.intervalSmoothing * delta
                        + (1 - Self.intervalSmoothing) * smoothed
                } else {
                    // Erster brauchbarer Messwert wird direkt übernommen. Ein
                    // Start bei 0 bräuchte rund 20 Callbacks, bis die Glättung
                    // brauchbar wäre, und die Kurve liefe solange zu schnell.
                    smoothedInterval = delta
                }
            }
        }
        // Auch nach einem verworfenen Abstand fortschreiben, sonst zählte die
        // nächste Messung die Lücke mit und wäre ihrerseits unplausibel.
        lastPushTime = now
        os_unfair_lock_unlock(&_lock)
    }

    /// Liefert die letzten `count` Paare in chronologischer Reihenfolge
    /// (oldest → newest) samt Teilpixel-Phase für die Oszilloskop-Darstellung.
    ///
    /// - Parameter count: gewünschte Anzahl; auf `[0, capacity]` geklemmt.
    /// - Returns: ``WaveformFrame`` mit `count` (min, max)-Paaren, das letzte
    ///   Element ist das neueste, plus der Phase zum selben Zeitpunkt.
    /// - Note: Vom MainActor bei bis zu 60 fps aufgerufen (Single-Reader).
    ///   Reserviert das Ergebnis-Array VOR der Lock-Sektion nicht, die
    ///   Allokation liegt HIER (Reader-Seite, unkritisch), nie im Audio-Pfad.
    func frame(count: Int) -> WaveformFrame {
        let n = Swift.max(0, Swift.min(count, Self.capacity))
        os_unfair_lock_lock(&_lock)
        let w = writeIndex
        var result = [(min: Float32, max: Float32)](repeating: (0, 0), count: n)
        for i in 0..<n {
            // (w - n + i) = absolute Position des i-ten der letzten n Werte;
            // Bitmaske faltet negative/überlaufende Indizes korrekt in den Ring.
            let idx = (w - n + i) & (Self.capacity - 1)
            result[i] = (min: storage[idx * 2], max: storage[idx * 2 + 1])
        }
        let phase = lockedPhase()
        os_unfair_lock_unlock(&_lock)
        return WaveformFrame(samples: result, phase: phase)
    }

    /// Anteil [0, 1] der Zeit, die seit dem letzten `push()` vergangen ist,
    /// gemessen am geglätteten Abstand zweier Pushes.
    ///
    /// - Returns: 0, solange keine zwei plausiblen Pushes vorliegen. Die
    ///   Darstellung verhält sich dann wie vor v4.0.1, also ohne Versatz.
    /// - Warning: Nur mit gehaltenem `_lock` aufrufen, liest `lastPushTime`
    ///   und `smoothedInterval`.
    private func lockedPhase() -> Double {
        guard let last = lastPushTime,
              let interval = smoothedInterval, interval > 0 else { return 0 }
        let elapsed = clock() - last
        // Ein NaN scheitert an diesem Vergleich und liefert 0, genau richtig:
        // eine nicht-endliche Phase würde als Versatz zu einer nicht-endlichen
        // Koordinate, und die bringt CoreGraphics zu Fall (siehe CASE-003).
        guard elapsed > 0 else { return 0 }
        // Bei mehr als einem vollen Intervall bleibt die Kurve stehen, statt in
        // einen Bereich weiterzulaufen, für den noch keine Daten vorliegen. Das
        // passiert, wenn ein Callback ausfällt oder ein Bild spät kommt.
        return Swift.min(1, elapsed / interval)
    }

    /// Nullt den Ring und setzt den Cursor zurück (Engine-Stop / Stille).
    /// - Note: Aus dem Teardown aufgerufen, nachdem der RT-Pfad ruht.
    ///   Die Zeitmessung wird mit zurückgesetzt: der Abstand über einen Stopp
    ///   hinweg ist keine Messung, sondern die Dauer der Pause.
    func reset() {
        os_unfair_lock_lock(&_lock)
        storage.update(repeating: 0)
        writeIndex = 0
        lastPushTime = nil
        smoothedInterval = nil
        os_unfair_lock_unlock(&_lock)
    }
}
