//
//  FooterTipsTests.swift
//  AudioRouterKitTests
//
//  4.1 Nachtrag (UI, Variante C3): Tests fuer die Hover-Erklaerungstexte im
//  Footer. Sichert, dass die Texte nicht leer, nicht zu lang und stilkonform
//  sind (kein Gedankenstrich, kein Doppelbindestrich, kein Superlativ).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import XCTest
@testable import AudioRouterKit

final class FooterTipsTests: XCTestCase {

    // MARK: Inhalt der einzelnen Texte

    func testAllTipsAreNonEmpty() {
        for tip in FooterTips.all {
            XCTAssertFalse(tip.isEmpty, "Ein Footer-Tooltip darf nicht leer sein")
        }
    }

    func testAllTipsAreWithinLengthLimit() {
        for tip in FooterTips.all {
            XCTAssertLessThanOrEqual(
                tip.count, FooterTips.maxLength,
                "Tooltip zu lang (\(tip.count) > \(FooterTips.maxLength)): \(tip)")
        }
    }

    func testNoTipContainsEmDash() {
        for tip in FooterTips.all {
            XCTAssertFalse(tip.contains("—"), "Em-Dash in: \(tip)")
            XCTAssertFalse(tip.contains(" — "), "Em-Dash mit Leerzeichen in: \(tip)")
        }
    }

    func testNoTipContainsDoubleHyphen() {
        for tip in FooterTips.all {
            XCTAssertFalse(tip.contains(" -- "), "Doppelbindestrich in: \(tip)")
        }
    }

    func testNoTipContainsSuperlative() {
        for tip in FooterTips.all {
            let lowered = tip.lowercased()
            let words = lowered.split { !$0.isLetter && $0 != "-" }.map(String.init)
            for banned in FooterTips.bannedSuperlatives {
                XCTAssertFalse(words.contains(banned), "Superlativ '\(banned)' in: \(tip)")
            }
        }
    }

    func testEveryTipPassesIsValid() {
        for tip in FooterTips.all {
            XCTAssertTrue(FooterTips.isValid(tip), "Tooltip verletzt die Stilregeln: \(tip)")
        }
    }

    // MARK: isValid als Waechter (muss auch ablehnen)

    func testIsValidRejectsEmpty() {
        XCTAssertFalse(FooterTips.isValid(""))
    }

    func testIsValidRejectsTooLong() {
        let tooLong = String(repeating: "a", count: FooterTips.maxLength + 1)
        XCTAssertFalse(FooterTips.isValid(tooLong))
    }

    func testIsValidRejectsEmDash() {
        XCTAssertFalse(FooterTips.isValid("Opens the tip jar — optional."))
    }

    func testIsValidRejectsDoubleHyphen() {
        XCTAssertFalse(FooterTips.isValid("Opens the tip jar -- optional."))
    }

    func testIsValidRejectsSuperlative() {
        XCTAssertFalse(FooterTips.isValid("The best way to route audio."))
        XCTAssertFalse(FooterTips.isValid("A seamless experience."))
    }

    func testIsValidAcceptsPlainSentence() {
        XCTAssertTrue(FooterTips.isValid("Quits AudioRouterNow."))
    }

    func testSuperlativeCheckIsWordBounded() {
        // "bestimmt" enthaelt "best", ist aber kein Superlativ-Wort und soll
        // nicht faelschlich abgelehnt werden.
        XCTAssertTrue(FooterTips.isValid("This bestimmt word is fine here."))
    }

    // MARK: die erwarteten Elemente sind alle vorhanden

    func testAllContainsExactlySixTips() {
        XCTAssertEqual(FooterTips.all.count, 6)
    }

    // MARK: Hint-Quelle (eine Quelle der Wahrheit)

    /// Die View setzt den VoiceOver-Hint ueber `FooterTip.text`, der auf diese
    /// Konstanten verweist. Dieser Test nagelt die sechs Texte fest, damit ein
    /// versehentliches Aendern auffaellt (der Hint und die Hover-Bubble teilen
    /// dieselbe Quelle). `FooterTip` liegt im App-Target und ist hier nicht
    /// erreichbar; deshalb werden die Kit-Konstanten direkt geprueft.
    func testTipConstantsAreTheExpectedSourceOfTruth() {
        XCTAssertEqual(FooterTips.support, "Opens the tip jar. Tipping is optional and unlocks nothing.")
        XCTAssertEqual(FooterTips.lock, "Keeps macOS from switching the output device while routing.")
        XCTAssertEqual(FooterTips.exclusive, "Only selected devices play. The default output stays silent.")
        XCTAssertEqual(FooterTips.bug, "Opens a pre-filled bug report email with version info.")
        XCTAssertEqual(FooterTips.quit, "Quits AudioRouterNow.")
        XCTAssertEqual(FooterTips.launchAtLogin, "Starts AudioRouterNow automatically when you log in.")
    }

    func testAllTipsAreUnique() {
        XCTAssertEqual(Set(FooterTips.all).count, FooterTips.all.count,
                       "Jeder Footer-Hint soll ein eigener Text sein")
    }
}
