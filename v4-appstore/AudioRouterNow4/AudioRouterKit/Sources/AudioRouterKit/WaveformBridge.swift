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
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import os

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

    /// Serialisiert Writer (IOProc) gegen Reader (MainActor). `os_unfair_lock`
    /// bietet Priority Inheritance → der niedrig-priorisierte Reader kann den
    /// RT-Writer nicht per Priority Inversion blockieren.
    private var _lock = os_unfair_lock_s()

    /// Vorab-allozierter Backing-Store, interleaved als `[min0, max0, min1, max1, …]`.
    /// Einmalige Allokation im `init` — im Audio-Pfad wird NIE alloziert.
    private let storage: UnsafeMutableBufferPointer<Float32>

    /// Monoton wachsender Schreib-Cursor (Anzahl je gepushter Paare). Wird nur
    /// vom IOProc-Pfad unter `_lock` inkrementiert; via Bitmaske auf `capacity`
    /// zurückgefaltet. Overflow ist unkritisch (`&+=`, wrapping) — nur die
    /// unteren `log2(capacity)` Bits werden ausgewertet.
    private var writeIndex: Int = 0

    /// Alloziert den Backing-Store (2 Slots pro Paar) und nullt ihn.
    init() {
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
        os_unfair_lock_unlock(&_lock)
    }

    /// Liefert die letzten `count` Paare in chronologischer Reihenfolge
    /// (oldest → newest) für die Oszilloskop-Darstellung.
    ///
    /// - Parameter count: gewünschte Anzahl; auf `[0, capacity]` geklemmt.
    /// - Returns: `count` (min, max)-Paare, das letzte Element ist das neueste.
    /// - Note: Vom MainActor bei bis zu 60 fps aufgerufen (Single-Reader).
    ///   Reserviert das Ergebnis-Array VOR der Lock-Sektion nicht — die
    ///   Allokation liegt HIER (Reader-Seite, unkritisch), nie im Audio-Pfad.
    func snapshot(count: Int) -> [(min: Float32, max: Float32)] {
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
        os_unfair_lock_unlock(&_lock)
        return result
    }

    /// Nullt den Ring und setzt den Cursor zurück (Engine-Stop / Stille).
    /// - Note: Aus dem IOProc bei Stille sowie aus dem Teardown aufgerufen.
    func reset() {
        os_unfair_lock_lock(&_lock)
        storage.update(repeating: 0)
        writeIndex = 0
        os_unfair_lock_unlock(&_lock)
    }
}
