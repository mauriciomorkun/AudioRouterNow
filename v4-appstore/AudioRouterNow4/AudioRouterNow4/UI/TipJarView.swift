//
//  TipJarView.swift
//  AudioRouterNow4
//
//  Kompaktes Tip-Jar UI — erscheint wenn User "♥ Support" im Footer antippt.
//  Zeigt zwei Kauf-Buttons (Coffee / Beer), Loading- und Thank-You-State.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import StoreKit
import AudioRouterKit

/// Kompakter In-App-Tip-Jar mit Coffee- und Beer-Buttons.
///
/// Zeigt automatisch einen Lade-Indikator solange die StoreKit-Produkte noch
/// nicht verfügbar sind. Wechselt nach erfolgreichem Kauf für 3 Sekunden in
/// den Thank-You-State. Benötigt ``TipJarStore`` als `@EnvironmentObject`.
struct TipJarView: View {
    @EnvironmentObject private var store: TipJarStore

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(ARNColor.accent)
                    .font(.system(size: 12))
                Text("Support AudioRouterNow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            if store.showThankYou {
                thankYouView
            } else if store.products.isEmpty {
                loadingView
            } else {
                productButtons
            }

            if let error = store.purchaseError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ARNColor.accent.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Sub-Views

    private var thankYouView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ARNColor.accent)
            Text("Thank you! It means a lot 🙏")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(ARNColor.accent)
            Text("Loading…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var productButtons: some View {
        HStack(spacing: 8) {
            ForEach(store.products, id: \.id) { product in
                tipButton(product)
            }
        }
    }

    private func tipButton(_ product: Product) -> some View {
        let isCoffee = product.id.contains("coffee")
        return Button {
            Task { await store.purchase(product) }
        } label: {
            VStack(spacing: 3) {
                Text(isCoffee ? "☕" : "🍺")
                    .font(.system(size: 18))
                Text(product.displayPrice)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ARNColor.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(ARNColor.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(ARNColor.accent.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(store.isPurchasing)
        .opacity(store.isPurchasing ? 0.6 : 1.0)
    }
}
