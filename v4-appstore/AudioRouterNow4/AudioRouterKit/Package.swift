// swift-tools-version: 6.0
//
// AudioRouterKit — Core-Engine-Package für AudioRouterNow v4.0 (App Store).
//
// Phase 2: swift-atomics für den lock-freien SPSC-Ring-Buffer
// (UnsafeAtomic<UInt32> write_idx/read_idx, v3-Port aus shared_ring.h).

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
    dependencies: [
        // Lock-freie Atomics für den Realtime-Pfad (SPSCRingBuffer).
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // Swift-6-Sprachmodus (Default bei tools-version 6.0) — Strict
        // Concurrency ist damit verpflichtend aktiv. Explizit dokumentiert
        // via .swiftLanguageMode(.v6) statt des bei 6.0 redundanten
        // .enableUpcomingFeature("StrictConcurrency").
        .target(
            name: "AudioRouterKit",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ],
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
