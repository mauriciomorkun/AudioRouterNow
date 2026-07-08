//
//  AudioMetrics.swift
//  AudioRouterKit
//
//  Realtime-sichere Zähler-Brücke zwischen IOProc-Callbacks und MainActor.
//  In Phase 2 aus TapEngine.swift ausgelagert, weil TapEngine UND
//  FanOutEngine dieselbe Metriken-Box verwenden.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import os

/// Zähler, die der Realtime-IOProc beschreibt und der MainActor liest.
///
/// PoC-Kompromiss: `OSAllocatedUnfairLock` statt lock-freier Atomics.
/// Ein unfair lock im Realtime-Callback ist akzeptabel (nur zwei
/// Int-Inkremente, MainActor pollt selten). Der eigentliche Audio-Pfad
/// (Fan-out) läuft lock-frei über ``SPSCRingBuffer`` + swift-atomics —
/// diese Box bedient NUR die Silence-Heuristik/UI-Metriken
/// (v3-Lektion: keine Locks im 50ms-Regel-Pfad).
final class TapIOMetrics: @unchecked Sendable {

    private struct State {
        var totalCallbacks: Int = 0
        var consecutiveSilentCallbacks: Int = 0
        var hasReceivedAudio: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Wird aus dem IOProc-Callback aufgerufen (NICHT MainActor).
    /// Kein throw, kein Allocation-lastiger Pfad — nur zählen.
    func record(callbackWasSilent: Bool) {
        state.withLock { s in
            s.totalCallbacks += 1
            if callbackWasSilent {
                s.consecutiveSilentCallbacks += 1
            } else {
                s.consecutiveSilentCallbacks = 0
                s.hasReceivedAudio = true
            }
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    var totalCallbacks: Int { state.withLock { $0.totalCallbacks } }
    var consecutiveSilentCallbacks: Int { state.withLock { $0.consecutiveSilentCallbacks } }
    var hasReceivedAudio: Bool { state.withLock { $0.hasReceivedAudio } }
}
