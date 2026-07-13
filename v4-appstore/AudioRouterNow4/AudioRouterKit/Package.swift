// swift-tools-version: 6.0
//
// AudioRouterKit — Core-Engine-Package für AudioRouterNow v4.0 (App Store).
//
// Phase 3/4: Keine externen Dependencies. Der Realtime-Pfad ist single-thread
// (ein Direct-IOProc, siehe FanOutEngine) — kein SPSC-Ring, keine Atomics mehr.

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
    dependencies: [],
    targets: [
        // Swift-6-Sprachmodus (Default bei tools-version 6.0) — Strict
        // Concurrency ist damit verpflichtend aktiv. Explizit dokumentiert
        // via .swiftLanguageMode(.v6) statt des bei 6.0 redundanten
        // .enableUpcomingFeature("StrictConcurrency").
        .target(
            name: "AudioRouterKit",
            dependencies: [],
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
