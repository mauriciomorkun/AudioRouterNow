//
//  AppDelegate.swift
//  AudioRouterNow4
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AppKit

/// `NSApplicationDelegate` der Menu-Bar-App.
///
/// Da die App ein `LSUIElement` ohne `WindowGroup` ist, dient der Delegate
/// primär als Aufhänger für den `applicationDidFinishLaunching`-Zeitpunkt: erst
/// hier ist die AppKit-Umgebung so weit hochgefahren, dass das Onboarding-Fenster
/// (siehe ``AudioRouterNowApp``) sicher gezeigt werden kann.
///
/// - Note: `@unchecked Sendable`, weil `NSApplicationDelegate`-Konformität
///   Sendable verlangt; der einzige veränderliche Zustand (`onFinishedLaunching`)
///   wird ausschliesslich auf dem Main-Thread gesetzt und aufgerufen.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    /// Von ``AudioRouterNowApp`` gesetzter Callback, ausgeführt nach
    /// `applicationDidFinishLaunching`. Trägt die Onboarding-Präsentation aus
    /// dem SwiftUI-`App.init` in einen sicheren AppKit-Lebenszyklus-Punkt.
    var onFinishedLaunching: (() -> Void)?

    /// AppKit-Hook: die Anwendung ist vollständig gestartet.
    func applicationDidFinishLaunching(_ notification: Notification) {
        onFinishedLaunching?()
    }
}
