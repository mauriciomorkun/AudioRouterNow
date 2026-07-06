//
//  MenuBarView.swift
//  AudioRouterNow4
//
//  Phase 0: Temporäre Platzhalter-UI — keine echte Routing-Logik.
//  Die vollständige UI (Geräte-Selektion, Volume/Mute, Sample-Rate,
//  Health-Ampel) folgt in Phase 4.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AudioRouterNow v4.0")
                .font(.headline)
                .bold()

            Divider()

            Text("Status: Initializing...")
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

// #Preview nicht verfügbar ohne volles Xcode — Phase 0 Skelett.
// Preview wird in Phase 4 (UI-Finalisierung) ergänzt.
