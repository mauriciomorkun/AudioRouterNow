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
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI

@main
struct AudioRouterNowApp: App {

    @StateObject private var controller = EngineController()

    var body: some Scene {
        MenuBarExtra("AudioRouterNow", systemImage: "speaker.wave.2.circle.fill") {
            MenuBarView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
