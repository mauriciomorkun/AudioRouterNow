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
    /// Kapazität als Power-of-2 für schnelles Modulo via Bitmaske.
    /// 256 ≈ 3 Sekunden bei ~86 IOProc-Callbacks/Sekunde (44100/512).
    static let capacity = 256

    private var _lock = os_unfair_lock_s()
    // Interleaved: [min0, max0, min1, max1, ...]
    private let storage: UnsafeMutableBufferPointer<Float32>
    // Write-Cursor (nur vom IOProc-Pfad inkrementiert, unter Lock)
    private var writeIndex: Int = 0

    init() {
        storage = UnsafeMutableBufferPointer<Float32>.allocate(capacity: Self.capacity * 2)
        storage.initialize(repeating: 0)
    }
    deinit { storage.deallocate() }

    /// RT-Pfad: schreibt (min, max) des aktuellen Callbacks.
    /// Nur aus dem IOProc aufrufen.
    func push(min: Float32, max: Float32) {
        os_unfair_lock_lock(&_lock)
        let idx = writeIndex & (Self.capacity - 1)
        storage[idx * 2]     = min
        storage[idx * 2 + 1] = max
        writeIndex &+= 1
        os_unfair_lock_unlock(&_lock)
    }

    /// Main-Thread: gibt die letzten `count` Samples zurück (oldest→newest).
    /// `count` wird auf capacity geklemmt.
    func snapshot(count: Int) -> [(min: Float32, max: Float32)] {
        let n = Swift.max(0, Swift.min(count, Self.capacity))
        os_unfair_lock_lock(&_lock)
        let w = writeIndex
        var result = [(min: Float32, max: Float32)](repeating: (0, 0), count: n)
        for i in 0..<n {
            let idx = (w - n + i) & (Self.capacity - 1)
            result[i] = (min: storage[idx * 2], max: storage[idx * 2 + 1])
        }
        os_unfair_lock_unlock(&_lock)
        return result
    }

    /// Reset bei Engine-Stop.
    func reset() {
        os_unfair_lock_lock(&_lock)
        storage.update(repeating: 0)
        writeIndex = 0
        os_unfair_lock_unlock(&_lock)
    }
}
