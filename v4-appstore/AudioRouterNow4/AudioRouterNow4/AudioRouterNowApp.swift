//
//  AudioRouterNowApp.swift
//  AudioRouterNow4
//
//  AudioRouterNow v4.0 — App Store Edition (Process Taps Architektur)
//  Phase 0 Skelett — MenuBarExtra-Stil wird in Phase 4 finalisiert.
//
//  LSUIElement-App: kein Dock-Icon, kein WindowGroup — die App lebt
//  ausschliesslich in der Menüleiste.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI

@main
struct AudioRouterNowApp: App {
    var body: some Scene {
        // Phase 0: reines Skelett. Routing-Engine (AudioRouterKit) und
        // vollständige UI folgen in Phase 2–4.
        MenuBarExtra("AudioRouterNow", systemImage: "speaker.wave.2.circle.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
