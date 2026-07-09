//
//  Theme.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Zentrale Design-Tokens, abgeleiteter
//  UI-State (`ARNUIState`) und dBFS-Helfer für die Signal-Meter.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import Foundation
import AudioRouterKit

// MARK: - UI-State (Single Source of Truth)

/// Abgeleiteter UI-Zustand aus `RouterStatus` + `isStarting`.
/// STARTING hat Vorrang vor dem gespiegelten Engine-`status`.
///
/// `RouterError` ist in `AudioRouterKit` bereits `Equatable`, daher genügt die
/// synthetisierte `Equatable`-Konformanz (Vergleiche wie `ui == .active`
/// tragen keine Associated Values).
enum ARNUIState: Equatable {
    case idle, starting, active, error(RouterError)

    init(status: RouterStatus, isStarting: Bool) {
        if isStarting { self = .starting; return }
        switch status {
        case .idle:         self = .idle
        case .routing:      self = .active
        case .error(let e): self = .error(e)
        }
    }

    var isActive: Bool   { self == .active }
    var isStarting: Bool { self == .starting }

    /// Wellen-/Header-Intensität: 0 = gedimmt (idle/error), 1 = voll (starting/active).
    var waveIntensity: Double {
        switch self {
        case .active, .starting: return 1.0
        default:                 return 0.0
        }
    }
}

// MARK: - Color-Tokens

enum ARNColor {
    /// --accent  #40DCA5
    static let accent       = Color(red: 0.251, green: 0.863, blue: 0.647)
    /// Gedimmter, kühler Dunkelgrün-Tint für den IDLE-Header.
    static let accentDim    = Color(red: 0.157, green: 0.310, blue: 0.267)

    /// Header-Gradient VOLL (starting/active).
    static let headerTop    = Color(red: 0.055, green: 0.157, blue: 0.133)
    static let headerBottom = Color(red: 0.020, green: 0.078, blue: 0.067)
    /// Header-Gradient GEDIMMT (idle/error).
    static let headerTopDim    = Color(red: 0.086, green: 0.098, blue: 0.098)
    static let headerBottomDim = Color(red: 0.043, green: 0.051, blue: 0.051)

    /// Glass-Card-Stroke (über .ultraThinMaterial gelegt).
    static let cardStroke       = Color.white.opacity(0.08)
    static let cardStrokeActive = accent.opacity(0.35)

    static let statusDotIdle = Color(white: 0.55)
    static let meterTrack    = Color.white.opacity(0.10)
}

// MARK: - dBFS-Helfer

enum ARNAudioMath {
    /// Linearer Peak [0…1] → dBFS, geklemmt auf [floorDB … 0].
    static func dbfs(_ linear: Float32, floorDB: Double = -60) -> Double {
        let v = Double(linear)
        guard v > 1e-7 else { return floorDB }
        return max(floorDB, min(0, 20 * log10(v)))
    }

    /// dBFS → Meter-Füllgrad [0…1] relativ zum floorDB.
    static func meterFraction(_ linear: Float32, floorDB: Double = -60) -> Double {
        let db = dbfs(linear, floorDB: floorDB)
        return (db - floorDB) / (0 - floorDB)   // floorDB→0, 0dB→1
    }
}
