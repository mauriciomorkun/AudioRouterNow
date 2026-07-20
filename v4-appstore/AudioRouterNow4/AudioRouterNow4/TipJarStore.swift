//
//  TipJarStore.swift
//  AudioRouterNow4
//
//  StoreKit 2 Tip Jar — lädt Consumable-IAP-Produkte und verarbeitet Käufe.
//  Thread-Safety: @MainActor — alle @Published Properties auf Main Thread.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import StoreKit
import SwiftUI

/// StoreKit-2-basierter Tip-Jar-Store für AudioRouterNow.
///
/// Lädt beim Start zwei Consumable-IAP-Produkte (Coffee / Beer) und stellt
/// `purchase(_:)` bereit. Transaktions-Updates werden über einen Background-Task
/// überwacht (``listenForTransactions()``). Alle ``@Published`` Properties
/// sind auf dem Main-Thread zugänglich.
@MainActor
final class TipJarStore: ObservableObject {

    // MARK: - Produkt-IDs

    static let productIDs: [String] = [
        "com.mauriciomorkun.audiorouternow4.tip.coffee",
        "com.mauriciomorkun.audiorouternow4.tip.beer"
    ]

    // MARK: - Published State

    /// Geladene StoreKit-Produkte (leer solange isLoading=true oder nicht verfügbar).
    @Published private(set) var products: [Product] = []
    /// Wird auf false gesetzt sobald loadProducts() abgeschlossen hat (Erfolg oder Fehler).
    @Published private(set) var isLoading = true
    /// Fehler aus loadProducts() — nil = kein Fehler (nur für Debug-Anzeige).
    @Published private(set) var loadError: String? = nil
    /// Läuft gerade ein Kauf-Request?
    @Published private(set) var isPurchasing = false
    /// Soll der "Danke!"-State angezeigt werden?
    @Published var showThankYou = false
    /// Fehlermeldung aus fehlgeschlagenem Kauf (nil = kein Fehler).
    @Published private(set) var purchaseError: String? = nil

    // MARK: - Private

    private var updateListenerTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        updateListenerTask = listenForTransactions()
        Task { await loadProducts() }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Produkte laden

    /// Lädt die konfigurierten IAP-Produkte aus dem App Store.
    ///
    /// Schlägt still fehl wenn die Produkte in App Store Connect noch nicht
    /// angelegt wurden (leeres Array) — kein Crash, UI zeigt Ladeindikator.
    func loadProducts() async {
        isLoading = true
        loadError = nil
        // Bundle-ID muss dem Produkt-ID-Präfix entsprechen. Ein Mismatch (z.B.
        // ...audiorouternow statt ...audiorouternow4) führt dazu, dass der
        // StoreKit-Agent den Katalog nach der falschen App filtert und still []
        // zurückgibt (Root-Cause 2026-07-16). Deshalb hier explizit loggen.
        print("[TipJar] Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil") — expected prefix: com.mauriciomorkun.audiorouternow4")
        print("[TipJar] loadProducts() requesting IDs: \(Self.productIDs)")
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            self.products = fetched.sorted { $0.price < $1.price }
            print("[TipJar] Loaded \(fetched.count) products: \(fetched.map(\.id))")

            // Diagnose: leeres Array OHNE Fehler ist die häufigste (und stille)
            // StoreKit-Fehlkonfiguration. Fast immer eine der beiden Ursachen:
            //   1. Keine StoreKit Configuration am Run-Scheme aktiv
            //      (project.yml → schemes.run.storeKitConfiguration).
            //   2. Produkt-IDs stimmen nicht mit der .storekit-Datei / der
            //      App-Bundle-ID überein.
            if fetched.isEmpty {
                let missing = Set(Self.productIDs)
                print("""
                [TipJar] ⚠️ 0 products returned WITHOUT an error. \
                Requested but unknown to StoreKit: \(missing.sorted()). \
                Check: (a) Run-Scheme has a StoreKit Configuration selected \
                (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Options ▸ StoreKit Configuration = AudioRouterNow.storekit), \
                (b) product IDs above match those in AudioRouterNow.storekit, \
                (c) app bundle ID = com.mauriciomorkun.audiorouternow4.
                """)
                self.loadError = "No products returned (check StoreKit config / IDs)."
            } else {
                // Diagnose: welche angefragten IDs hat StoreKit nicht gefunden?
                let returned = Set(fetched.map(\.id))
                let unresolved = Set(Self.productIDs).subtracting(returned)
                if !unresolved.isEmpty {
                    print("[TipJar] ⚠️ Some product IDs were not resolved: \(unresolved.sorted())")
                }
            }
        } catch {
            self.products = []
            self.loadError = error.localizedDescription
            print("[TipJar] loadProducts failed: \(error)")
        }
        isLoading = false
    }

    // MARK: - Kauf

    /// Initiiert einen Kauf für das angegebene Produkt.
    ///
    /// - Parameter product: Das zu kaufende StoreKit-Produkt.
    /// - Note: Setzt `isPurchasing` während des Requests. Bei Erfolg wird
    ///   `showThankYou` kurzzeitig auf `true` gesetzt.
    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                // Verifikation prüfen
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    showThankYou = true
                    // Thank-You nach 3s automatisch ausblenden
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    showThankYou = false
                case .unverified:
                    purchaseError = "Purchase could not be verified."
                }
            case .pending:
                break  // Warten auf externe Genehmigung (Family Sharing etc.)
            case .userCancelled:
                break  // Kein Fehler — User hat abgebrochen
            @unknown default:
                break
            }
        } catch {
            purchaseError = "Purchase failed. Please try again."
        }
    }

    // MARK: - Transaktions-Listener

    /// Überwacht eingehende Transaktions-Updates (z.B. Refunds, Family Purchases).
    ///
    /// - Returns: Task der im Hintergrund läuft und in `deinit` gecancelt wird.
    /// - Note: No-op für Consumables, aber Best Practice für vollständige
    ///   StoreKit-2-Integration.
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
            }
        }
    }
}
