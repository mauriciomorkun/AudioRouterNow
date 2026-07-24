//
//  AudioMetrics.swift
//  AudioRouterKit
//
//  Realtime-sichere Zähler-Brücke zwischen IOProc-Callbacks und MainActor.
//  Eigenständige Metriken-Box, die die FanOutEngine über ``TapIOMetrics``
//  vom Realtime-IOProc mit UI-Zählern versorgt.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import os

/// Zähler, die der Realtime-IOProc beschreibt und der MainActor liest.
///
/// `OSAllocatedUnfairLock` statt lock-freier Atomics: nur zwei
/// Int-Inkremente pro Callback, MainActor pollt selten — akzeptabel.
/// Der eigentliche Audio-Pfad (Direct-IOProc) berührt diese Box gar nicht
/// als Ring: er kopiert direkt inInputData→ioOutputData und meldet hier
/// nur die Silence-Heuristik/UI-Metriken.
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
