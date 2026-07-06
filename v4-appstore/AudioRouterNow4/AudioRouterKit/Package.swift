// swift-tools-version: 6.0
//
// AudioRouterKit — Core-Engine-Package für AudioRouterNow v4.0 (App Store).
//
// Phase 0: Skeleton ohne externe Abhängigkeiten.
// swift-atomics wird erst in Phase 2 (SPSC-Ring-Buffer) ergänzt.

import PackageDescription

let package = Package(
    name: "AudioRouterKit",
    platforms: [
        // Bewusste zweite Quelle neben project.yml options.deploymentTarget —
        // SwiftPM kann das xcodegen-Setting nicht lesen. Bei Bump: BEIDE anpassen.
        .macOS("14.4")
    ],
    products: [
        .library(
            name: "AudioRouterKit",
            targets: ["AudioRouterKit"]
        )
    ],
    targets: [
        // Swift-6-Sprachmodus (Default bei tools-version 6.0) — Strict
        // Concurrency ist damit verpflichtend aktiv. Explizit dokumentiert
        // via .swiftLanguageMode(.v6) statt des bei 6.0 redundanten
        // .enableUpcomingFeature("StrictConcurrency").
        .target(
            name: "AudioRouterKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // swift-testing wird von SwiftPM für Test-Targets automatisch gelinkt —
        // KEINE unsafeFlags/Framework-Pfade nötig. Voraussetzung: volles Xcode
        // als aktive Toolchain (die CLT enthalten kein swift-testing). Lokal:
        // scripts/test.sh nutzen oder DEVELOPER_DIR auf Xcode.app setzen.
        .testTarget(
            name: "AudioRouterKitTests",
            dependencies: ["AudioRouterKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
