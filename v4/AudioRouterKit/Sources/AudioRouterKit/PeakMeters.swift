//
//  PeakMeters.swift
//  AudioRouterKit
//
//  RT-sichere Peak-Level-Brücke: der Direct-IOProc schreibt pro Callback den
//  Source-Peak (post-Volume), der MainActor pollt ihn alle 500 ms.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import os

/// Peak-Pegel-Box (L/R pro Output-Slot). Single-Writer (IOProc-Thread),
/// Single-Reader (MainActor-Polling). RT-safe: eine `os_unfair_lock`-Sektion
/// pro Zugriff (< 100 ns), keine Allokation im Audio-Pfad.
///
/// - `@unchecked Sendable`: geteilter Zustand ausschliesslich über `_lock`
///   serialisiert; `storage` wird EINMAL bei `init` alloziert und erst im
///   `deinit` (nach `AudioDeviceStop`, RT-Pfad ruht) freigegeben.
final class PeakMeters: @unchecked Sendable {

    /// Harte Obergrenze der Output-Slots (= FanOutEngine-Fan-out-Limit).
    static let maxSlots = 16

    private var _lock = os_unfair_lock_s()
    /// Interleaved [l0, r0, l1, r1, …] mit `maxSlots * 2` Float32.
    private let storage: UnsafeMutableBufferPointer<Float32>

    init() {
        storage = UnsafeMutableBufferPointer<Float32>.allocate(capacity: Self.maxSlots * 2)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    /// RT-Pfad: schreibt denselben (l, r)-Peak auf `slotCount` Slots und nullt
    /// den Rest. Aufruf NUR aus dem IOProc-Callback. `slotCount` wird gegen
    /// `maxSlots` geklemmt (RT-sicher, kein Overrun).
    func record(l: Float32, r: Float32, slotCount: Int) {
        let n = max(0, min(slotCount, Self.maxSlots))
        os_unfair_lock_lock(&_lock)
        for i in 0..<n {
            storage[i * 2]     = l
            storage[i * 2 + 1] = r
        }
        for i in n..<Self.maxSlots {
            storage[i * 2]     = 0
            storage[i * 2 + 1] = 0
        }
        os_unfair_lock_unlock(&_lock)
    }

    /// MainActor-Pfad: liest den Peak eines Slots. Out-of-range → (0, 0).
    func level(slotIndex: Int) -> (l: Float32, r: Float32) {
        guard slotIndex >= 0, slotIndex < Self.maxSlots else { return (0, 0) }
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return (storage[slotIndex * 2], storage[slotIndex * 2 + 1])
    }

    /// Setzt alle Pegel auf 0 (Silence-Callback ohne Delay, Stop, Teardown).
    func reset() {
        os_unfair_lock_lock(&_lock)
        storage.update(repeating: 0)
        os_unfair_lock_unlock(&_lock)
    }
}
