//
//  AudioRouterNowApp.swift
//  AudioRouterNow4
//
//  AudioRouterNow v4.0 — App Store Edition (Process Taps Architektur)
//  Phase 1: EngineController als StateObject injiziert für Test-UI.
//
//  LSUIElement-App: kein Dock-Icon, kein WindowGroup — die App lebt
//  ausschliesslich in der Menüleiste.
//
//  Session 3: Onboarding (M3) + Login-Item-Registrierung (M2).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AppKit
import ServiceManagement

/// SwiftUI-Einstiegspunkt der Menu-Bar-App.
///
/// Die App ist ein `LSUIElement` (kein Dock-Icon, kein `WindowGroup`) und lebt
/// ausschliesslich als ``MenuBarExtra`` im `.window`-Stil. Der zentrale
/// ``EngineController`` wird als `@StateObject` erzeugt und in die Menu-Bar-View
/// injiziert; er überlebt damit die gesamte App-Laufzeit.
///
/// Verantwortlichkeiten:
/// - MenuBarExtra-Scene mit Custom-Template-Icon aufbauen.
/// - Beim ersten Start das Onboarding-Fenster zeigen (via AppKit, siehe
///   ``showOnboarding(key:)``) — `@StateObject` ist im `init` noch nicht
///   zugänglich, deshalb der Umweg über ``AppDelegate``.
@main
struct AudioRouterNowApp: App {

    /// Brücke in den AppKit-Lebenszyklus (`applicationDidFinishLaunching`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Einziger, App-weit lebender Engine-Controller (Main-Thread-gebunden).
    @StateObject private var controller = EngineController()

    /// StoreKit-2-Tip-Jar-Store (Consumable-IAPs, Main-Thread-gebunden).
    @StateObject private var tipJarStore = TipJarStore()

    /// UserDefaults-Key: wurde das Onboarding bereits gezeigt?
    private static let hasShownOnboardingKey = "arn.v4.hasShownOnboarding"

    var body: some Scene {
        // Custom Fan-out Template-Icon (Assets.xcassets/MenuBarIcon.imageset):
        // Quelle unten-mitte → 4 geschwungene Kurven → 4 Outputs oben,
        // visuelle Sprache des v3.4.4 App-Icons.
        MenuBarExtra("AudioRouterNow", image: "ARNMenuBarIcon") {
            MenuBarView()
                .environmentObject(controller)
                .environmentObject(tipJarStore)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // AppDelegate-Callback: läuft nach applicationDidFinishLaunching.
        // Hinweis: @StateObject ist im init noch nicht zugänglich →
        // Onboarding wird via DispatchQueue.main.async (nach SwiftUI-Init) gezeigt.
        // Der Auto-Start (S4) wird vom EngineController selbst getriggert.
        let key = Self.hasShownOnboardingKey
        appDelegate.onFinishedLaunching = {
            Task { @MainActor in
                if !UserDefaults.standard.bool(forKey: key) {
                    Self.showOnboarding(key: key)
                }
            }
        }
    }

    // W6: Statische Referenzen halten Fenster + Delegate am Leben.
    /// Starke Referenz auf das Onboarding-Fenster — ohne sie würde das nicht
    /// über `WindowGroup` verwaltete `NSWindow` sofort deallokiert.
    @MainActor private static var onboardingWindow: NSWindow?
    /// Starke Referenz auf den Fenster-Delegate (analog `onboardingWindow`).
    @MainActor private static var onboardingDelegate: OnboardingWindowDelegate?

    /// Erzeugt und zeigt das einmalige Onboarding-Fenster (AppKit).
    ///
    /// Bewusst als `NSWindow` mit `NSHostingView` statt als SwiftUI-Scene: die
    /// App hat kein `WindowGroup`, ein modales AppKit-Fenster ist der
    /// zuverlässigste Weg, beim Erststart ein Willkommensfenster zu zeigen.
    /// Setzt bei „Continue" das `hasShownOnboarding`-Flag und registriert
    /// optional das Login-Item.
    ///
    /// - Parameter key: UserDefaults-Key für das „bereits gezeigt"-Flag.
    /// - Note: Muss auf dem Main-Thread laufen (AppKit).
    @MainActor
    private static func showOnboarding(key: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AudioRouterNow"
        window.isReleasedWhenClosed = false
        window.center()

        // W6: windowWillClose deckt ALLE Schließ-Pfade ab (X-Button UND
        // programmatisches close()) → Flag wird immer gesetzt, kein Loop.
        let delegate = OnboardingWindowDelegate(onboardingKey: key)
        delegate.onClose = {
            Self.onboardingWindow = nil
            Self.onboardingDelegate = nil
        }
        window.delegate = delegate
        onboardingDelegate = delegate
        onboardingWindow = window

        window.contentView = NSHostingView(rootView: OnboardingView(onContinue: { [weak window] launchAtLogin in
            UserDefaults.standard.set(true, forKey: key)
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            }
            window?.close()
        }))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// W6: Fenster-Delegate für das Onboarding — setzt das hasShownOnboarding-Flag
/// bei JEDEM Schließ-Pfad (auch X-Button) und gibt statische Referenzen frei.
@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onboardingKey: String
    var onClose: (() -> Void)?

    init(onboardingKey: String) {
        self.onboardingKey = onboardingKey
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.delegate = nil
        UserDefaults.standard.set(true, forKey: onboardingKey)
        onClose?()
    }
}
