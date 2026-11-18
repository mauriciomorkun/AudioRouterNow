//
//  FooterTips.swift
//  AudioRouterKit
//
//  4.1 Nachtrag (UI, Variante C3): Texte der Hover-Erklaerungen im Footer.
//
//  Warum im Kit und nicht im App-Target: die Footer-View liegt im App-Target und
//  ist aus dem SPM-Test-Target nicht erreichbar. Die reinen Texte sollen testbar
//  sein (nicht leer, Laenge begrenzt, kein Gedankenstrich, kein Superlativ),
//  damit sie nicht unbemerkt kaputtgehen. Gleiches Muster wie SoloGain,
//  OutputLimits und WaveEnergyMath: eine Quelle der Wahrheit hier, die View liest
//  nur ab.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation

/// Sachliche Hover-Erklaerung je Footer-Element. Jeweils ein Satz, englisch,
/// ohne Gedankenstrich und ohne Superlativ (siehe `FooterTips.isValid`).
///
/// Die Texte beschreiben, was das Element tut, nicht ein behauptetes Audio-
/// Ergebnis. Bedeutung am Code belegt (`EngineController`, `FooterRow`):
/// Support oeffnet den Tip Jar (freiwilliger In-App-Kauf, schaltet nichts frei),
/// Lock verhindert, dass macOS das Ausgabegeraet waehrend des Routings wechselt,
/// Exclusive laesst nur die gewaehlten Geraete spielen und den Default stumm,
/// Bug oeffnet eine vorausgefuellte E-Mail mit Version und Systemdaten, Quit
/// beendet die App, Launch at Login startet die App beim Anmelden.
public enum FooterTips {

    /// Tip-Jar-Knopf (Herz). Der Tip Jar ist ein freiwilliger In-App-Kauf.
    public static let support = "Opens the tip jar. Tipping is optional and unlocks nothing."

    /// Stable Output Mode (Schloss).
    public static let lock = "Keeps macOS from switching the output device while routing."

    /// Exclusive Routing (durchgestrichener Lautsprecher, CASE-008).
    public static let exclusive = "Only selected devices play. The default output stays silent."

    /// Bug-Report (Marienkaefer).
    public static let bug = "Opens a pre-filled bug report email with version info."

    /// Beenden.
    public static let quit = "Quits AudioRouterNow."

    /// Launch at Login (Checkbox).
    public static let launchAtLogin = "Starts AudioRouterNow automatically when you log in."

    /// Alle Texte, fuer die Test-Schleife.
    public static let all: [String] = [support, lock, exclusive, bug, quit, launchAtLogin]

    /// Hoechstlaenge eines Tooltip-Textes (Zeichen). Haelt die Bubble kompakt.
    public static let maxLength = 90

    /// Woerter, die als Superlativ gelten und in Tooltips nicht vorkommen duerfen.
    /// Klein geschrieben; der Vergleich ist case-insensitive.
    public static let bannedSuperlatives: [String] = [
        "best", "fastest", "easiest", "simplest", "smartest", "greatest",
        "ultimate", "perfect", "flawless", "unmatched", "unbeatable",
        "world-class", "revolutionary", "seamless", "effortless"
    ]

    /// Prueft einen Tooltip-Text gegen die Stilregeln.
    ///
    /// - nicht leer,
    /// - hoechstens `maxLength` Zeichen,
    /// - kein Em-Dash " — " und kein Doppelbindestrich " -- ",
    /// - kein Superlativ aus `bannedSuperlatives` (als ganzes Wort).
    ///
    /// - Parameter text: der zu pruefende Tooltip.
    /// - Returns: `true` wenn der Text alle Regeln erfuellt.
    public static func isValid(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if text.count > maxLength { return false }
        if text.contains(" — ") { return false }
        if text.contains(" -- ") { return false }
        if text.contains("—") { return false }
        let lowered = text.lowercased()
        // Woerter isolieren (Buchstaben zusammenhaengend), damit "best" nicht in
        // "bestimmt" o.ae. anschlaegt.
        let words = lowered.split { !$0.isLetter && $0 != "-" }.map(String.init)
        for banned in bannedSuperlatives where words.contains(banned) {
            return false
        }
        return true
    }
}
