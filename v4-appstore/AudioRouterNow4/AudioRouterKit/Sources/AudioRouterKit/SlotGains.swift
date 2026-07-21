// SlotGains.swift — AudioRouterKit
// RT-sichere Per-Slot-Gain-Brücke (F16).
// Richtung: MainActor schreibt (set/setAll), IOProc liest (gain) — invertiert zu PeakMeters.
// Synchronisation: os_unfair_lock (<100 ns Hold-Time, RT-kompatibel).
// Kein Alloc, kein ARC-Traffic im IOProc-Pfad.

import os

/// RT-sichere Per-Slot-Gain-Brücke für F16 Per-Gerät-Lautstärke.
///
/// - Writer: MainActor (Slider-Drag → `set(_:slotIndex:)` oder `setAll(_:)`)
/// - Reader: IOProc RT-Thread (`gain(slotIndex:)`)
///
/// Effektiver Sample-Faktor im IOProc: `globalVol × slotGain`.
public final class SlotGains: @unchecked Sendable {

    public static let maxSlots = 16

    private var _lock = os_unfair_lock_s()
    private let storage: UnsafeMutableBufferPointer<Float32>

    public init() {
        storage = .allocate(capacity: Self.maxSlots)
        storage.initialize(repeating: 1.0)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: - IOProc-Pfad (Reader)

    /// Liest den Gain für einen Slot. RT-sicher. Out-of-range → 1.0 (Unity).
    @inline(__always)
    public func gain(slotIndex: Int) -> Float32 {
        guard slotIndex >= 0 && slotIndex < Self.maxSlots else { return 1.0 }
        os_unfair_lock_lock(&_lock)
        let v = storage[slotIndex]
        os_unfair_lock_unlock(&_lock)
        return v
    }

    // MARK: - MainActor-Pfad (Writer)

    /// Setzt den Gain für einen einzelnen Slot. Wird live im nächsten IOProc-Callback wirksam.
    public func set(_ gain: Float32, slotIndex: Int) {
        guard slotIndex >= 0 && slotIndex < Self.maxSlots else { return }
        let clamped = max(0.0, min(1.0, gain))
        os_unfair_lock_lock(&_lock)
        storage[slotIndex] = clamped
        os_unfair_lock_unlock(&_lock)
    }

    /// Setzt alle Gains auf einmal (Seed nach Aggregate-Build).
    /// Slots über `gains.count` werden auf 1.0 gesetzt.
    public func setAll(_ gains: [Float32]) {
        os_unfair_lock_lock(&_lock)
        for i in 0..<Self.maxSlots {
            storage[i] = i < gains.count ? max(0.0, min(1.0, gains[i])) : 1.0
        }
        os_unfair_lock_unlock(&_lock)
    }

    /// Setzt alle Slots auf Unity (1.0).
    public func reset() {
        os_unfair_lock_lock(&_lock)
        storage.initialize(repeating: 1.0)
        os_unfair_lock_unlock(&_lock)
    }
}
