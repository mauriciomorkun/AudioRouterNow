//
//  OutputConfig.swift
//  AudioRouterKit
//
//  Phase 2 — Konfiguration eines Output-Routing-Ziels (Fan-out).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import CoreAudio
import Foundation

/// Configuration für ein Output-Routing-Ziel.
///
/// `Codable` ist bewusst HIER deklariert (nicht als Extension im App-Target):
/// Codable-Synthese funktioniert nur in derselben Datei wie die
/// Typ-Deklaration — das App-Target nutzt sie für UserDefaults-Persistenz.
public struct OutputConfig: Sendable, Hashable, Codable {
    /// Persistente UID des Output-Devices (`kAudioDevicePropertyDeviceUID`).
    /// Stabil über Hot-Plug hinweg (NICHT AudioObjectID — die ist flüchtig).
    public let uid: String

    /// Channel-Offset im Output-Device (0 = Ch1-2, 2 = Ch3-4 für KA6 etc.)
    public let channelOffset: Int

    /// Anzahl zu bespielender Kanäle (typisch 2 für Stereo)
    public let channelCount: Int

    public init(uid: String, channelOffset: Int = 0, channelCount: Int = 2) {
        self.uid = uid
        self.channelOffset = channelOffset
        self.channelCount = channelCount
    }
}

/// Interne Laufzeit-Darstellung eines Output-Routing-Ziels (Phase 2).
/// Pro Output-Config EINE Instanz; enthält Ring-Buffer + Channel-Offset.
///
/// `@unchecked Sendable`: wird vom Tap-IOProc (Producer) UND vom
/// Output-IOProc (Consumer) zugegriffen, aber über die getrennten Seiten des
/// SPSC-Ring-Buffers (SPSC-Invariante hält — genau ein Producer-Thread,
/// genau ein Consumer-Thread pro Ring). Alle Stored Properties sind `let`.
final class OutputDeviceChannel: @unchecked Sendable {
    let config: OutputConfig
    let ring: SPSCRingBuffer

    init(config: OutputConfig) {
        self.config = config
        self.ring = SPSCRingBuffer()
    }
}
