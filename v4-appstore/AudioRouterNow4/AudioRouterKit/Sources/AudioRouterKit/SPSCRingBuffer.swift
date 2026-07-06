//
//  SPSCRingBuffer.swift
//  AudioRouterKit
//
//  Phase 2 — Single-Producer/Single-Consumer Ring-Buffer (Placeholder).
//
//  Referenz-Implementierung: v3 C-Code in helper/AudioRouterNowHelper.c
//  und helper/shared_ring.h (ARN_RING_CAPACITY = 16384, ARN_RING_MASK).
//
//  Design-Notizen aus v3, die der Swift-Port ÜBERNEHMEN MUSS:
//
//    - Monoton steigende atomic-uint32-Indizes (write_idx / read_idx),
//      uint32-Overflow ist OK, weil 2^32 ein Vielfaches der Kapazität ist
//      (Power-of-2!). Position = index & mask.
//    - Producer-Hot / Consumer-Hot auf getrennten Cache-Lines
//      (v3: Offset 64 vs. 128 — False-Sharing vermeiden).
//    - KEINE Locks, KEINE Allokationen, KEIN ObjC/Swift-Runtime-Call auf
//      dem Realtime-Pfad: UnsafeMutableBufferPointer + Atomics
//      (swift-atomics `ManagedAtomic`/`UnsafeAtomic` — Dependency kommt
//      in Phase 2 ins Package.swift).
//    - Overrun-Erkennung Consumer-seitig: behind > capacity → Re-Sync
//      (v3: helper Zeile ~934).
//    - Pre-Roll: Consumer gibt Stille bis capacity/8 = 2048 Frames
//      (≈ 43 ms @ 48 kHz) gefüllt sind (v3: ARN_PREROLL_FRAMES).
//    - Pro Output-Device EIN eigener Ring — der Tap-Callback (Producer)
//      überspringt inaktive Branches non-blocking (Phase-2-Anforderung
//      aus der Issue-Resolution).
//

import Foundation

/// Lock-freier Single-Producer/Single-Consumer Ring-Buffer für den
/// Realtime-Audio-Pfad (Tap-IOProc → Output-IOProc).
///
/// Phase-0-Placeholder: enthält nur die Kapazitäts-Konstanten. Die
/// eigentliche lock-freie Implementierung folgt in Phase 2 und portiert
/// das bewährte v3-Design aus `helper/shared_ring.h`.
public struct SPSCRingBuffer<Element> {

    /// Kapazität in Samples — MUSS Power-of-2 sein (wie v3:
    /// `ARN_RING_CAPACITY = 16384`), damit Index-Wrapping via Bitmaske
    /// funktioniert und uint32-Overflow der monotonen Indizes transparent ist.
    public static var capacity: Int { 16384 }

    /// Bitmaske für Index-Wrapping (v3: `ARN_RING_MASK = capacity - 1`).
    public static var mask: Int { capacity - 1 }

    /// Pre-Roll-Schwelle in Frames: capacity/8 = 2048 ≈ 43 ms @ 48 kHz
    /// (v3: `ARN_PREROLL_FRAMES`). Consumer liefert Stille, bis der Ring
    /// mindestens so weit gefüllt ist — verhindert Start-Underruns.
    public static var prerollFrames: Int { capacity / 8 }

    /// Erstellt einen (noch funktionslosen) Ring-Buffer-Placeholder.
    public init() {
        // TODO(Phase 2): UnsafeMutableBufferPointer<Element>-Storage
        //   (aligned alloc), UnsafeAtomic<UInt32> für write_idx/read_idx,
        //   Cache-Line-Padding zwischen Producer- und Consumer-Feld.
        // TODO(Phase 2): push(_:count:) / pop(into:count:) als @inlinable,
        //   RT-safe (keine Allokation, kein Locking, kein Throw).
        // TODO(Phase 2): Golden-Tests gegen v3-Verhalten VOR dem
        //   PI-Regler-Port (IMPLEMENTATION_PLAN.md Phase 2, Key Tasks).
        // TODO(Phase 2): Sendable-Strategie neu entscheiden — mit
        //   UnsafeMutableBufferPointer-Storage ist die bedingte Konformität
        //   unten nicht mehr synthetisierbar/korrekt; dann bewusst
        //   `@unchecked Sendable` mit dokumentierter SPSC-Invariante
        //   (genau EIN Producer-Thread, genau EIN Consumer-Thread).
    }
}

// Bedingte Sendable-Konformität: nur sendbar, wenn Element sendbar ist.
// (Phase-0-Placeholder ohne Stored Properties — siehe TODO(Phase 2) oben
// für die Neubewertung, sobald Unsafe-Storage dazukommt.)
extension SPSCRingBuffer: Sendable where Element: Sendable {}
