//
//  SoloGain.swift
//  AudioRouterKit
//
//  P2 (v4.1): Reine Entscheidungslogik fuer den Solo-Zustand pro Output-Slot.
//
//  Warum im Kit und nicht im EngineController: Der EngineController liegt im
//  App-Target und ist aus dem SPM-Test-Target nicht erreichbar. Die Logik ist
//  aber reine Arithmetik ohne CoreAudio und soll als Funktion geprueft werden
//  (gleiches Muster wie FanOutEngine.effectiveVolume/slotTargetSV aus CASE-004).
//  Eine Duplikat-Funktion im Test waere zwei Quellen der Wahrheit, genau das,
//  wovor CASE-004 warnt. Deshalb eine einzige Quelle hier.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation

/// Reine Solo-Gain-Entscheidung (keine Persistenz, kein CoreAudio).
public enum SoloGain {

    /// Effektiver Gain eines Slots unter Solo.
    ///
    /// - Kein Solo aktiv (`soloedKeys` leer): der gespeicherte Gain (Default 1.0,
    ///   Unity, falls der Key nicht in `deviceGains` steht).
    /// - Solo aktiv und dieser Key ist solo'ed: der gespeicherte Gain.
    /// - Solo aktiv und dieser Key ist NICHT solo'ed: 0.0 (stumm durch fremdes Solo).
    ///
    /// `deviceGains` wird NUR gelesen, nie veraendert. Solo darf die
    /// persistierten Per-Device-Gains niemals verschmutzen (CASE-004/R3).
    ///
    /// - Parameters:
    ///   - key: Composite-Key "<uid>:<channelOffset>" des Slots.
    ///   - soloedKeys: aktuell solo'ede Keys (leer = kein Solo aktiv).
    ///   - deviceGains: gespeicherte Per-Device-Gains [0…1].
    /// - Returns: effektiver Gain [0…1] fuer den Slot.
    public static func effective(
        key: String,
        soloedKeys: Set<String>,
        deviceGains: [String: Double]
    ) -> Float32 {
        let base = Float32(deviceGains[key] ?? 1.0)
        if soloedKeys.isEmpty { return base }
        return soloedKeys.contains(key) ? base : 0.0
    }
}
