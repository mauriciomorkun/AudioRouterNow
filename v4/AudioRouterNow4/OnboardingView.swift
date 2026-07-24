//
//  OnboardingView.swift
//  AudioRouterNow4
//
//  Erklärt den TCC-Prompt BEVOR er erscheint (App Store Guideline 2.5.1).
//  Wird nur beim allerersten App-Start gezeigt.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import ServiceManagement

struct OnboardingView: View {

    let onContinue: (Bool) -> Void  // Bool = launchAtLogin gewünscht

    @State private var launchAtLogin: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "headphones.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to AudioRouterNow")
                        .font(.title2)
                        .bold()
                    Text("Route your Mac's audio to multiple outputs simultaneously.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Berechtigungs-Erklärung
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio Recording")
                            .font(.headline)
                        Text("macOS will ask for this permission when you first start routing. AudioRouterNow uses it to capture system audio in real time — **nothing is ever recorded or stored.**")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DRM-protected content")
                            .font(.headline)
                        Text("Apple Music Lossless, Netflix, and TV+ use DRM that prevents any app from capturing their audio. This is a macOS limitation, not a bug.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Launch-at-Login Checkbox
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch AudioRouterNow at Login")
                        .font(.body)
                    Text("Start automatically when you log in to your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            // Continue Button
            HStack {
                Spacer()
                Button(action: { onContinue(launchAtLogin) }) {
                    Text("Continue")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}
