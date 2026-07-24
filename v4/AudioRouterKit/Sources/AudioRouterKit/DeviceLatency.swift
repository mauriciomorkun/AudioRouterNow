//  DeviceLatency.swift
//  AudioRouterKit
//
//  Phase 4 — CoreAudio-Latenz-Abfragen pro Output-Device.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.

import CoreAudio
import Foundation

/// Fasst alle Output-Latenz-Quellen eines CoreAudio-Devices zusammen.
public struct DeviceLatencyInfo: Sendable {
    /// `kAudioDevicePropertyLatency` (Output-Scope) in Frames.
    public let deviceFrames: Int
    /// `kAudioDevicePropertySafetyOffset` (Output-Scope) in Frames.
    public let safetyFrames: Int
    /// `kAudioStreamPropertyLatency` des ersten Output-Streams in Frames.
    public let streamFrames: Int
    /// Gemessene oder angenommene Sample-Rate (Frames/Sekunde).
    public let sampleRate: Double

    /// Summe: `deviceFrames + safetyFrames + streamFrames`.
    public var totalFrames: Int { deviceFrames + safetyFrames + streamFrames }

    /// Gesamtlatenz in Millisekunden (auf 2 Dezimalstellen gerundet).
    public var totalMilliseconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate * 1000
    }

    /// Gesamtlatenz in Sekunden (`totalFrames / sampleRate`). Basis für den
    /// Sample-Rate-normalisierten Latenz-Vergleich (F6).
    public var totalSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    /// Latenz für Fan-Out-Synchronisation — OHNE `safetyFrames`.
    ///
    /// `kAudioDevicePropertySafetyOffset` ist ein Pre-Scheduling-Buffer
    /// (z. B. für Spatial Audio / APC auf MacBook-Lautsprechern) und kann
    /// zehntausende Frames betragen. Für physische Output-Latenz (= wann
    /// Audio den Lautsprecher verlässt) ist er nicht relevant.
    /// Fan-out-Sync braucht nur `deviceFrames + streamFrames`.
    public var fanOutLatencySeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(deviceFrames + streamFrames) / sampleRate
    }
}

/// Liest alle Output-Latenz-Quellen eines CoreAudio-Devices aus.
///
/// Gibt eine ``DeviceLatencyInfo`` zurück — niemals nil (Fallback: 0 Frames).
/// Nicht RT-safe (allocations inside) — nur beim `start()` aufrufen, nie im IOProc.
public func readDeviceLatency(deviceID: AudioObjectID) -> DeviceLatencyInfo {
    DeviceLatencyInfo(
        deviceFrames: readUInt32Frames(deviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
        safetyFrames: readUInt32Frames(deviceID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
        streamFrames: firstOutputStreamLatency(deviceID),
        sampleRate:   deviceNominalSampleRate(deviceID)
    )
}

// MARK: - Private Helpers

private func readUInt32Frames(
    _ deviceID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope
) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
    else { return 0 }
    return Int(value)
}

private func firstOutputStreamLatency(_ deviceID: AudioObjectID) -> Int {
    // Ersten Output-Stream-ID lesen
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioStreamID>.size)
    else { return 0 }

    var streamID = AudioStreamID(kAudioObjectUnknown)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streamID) == noErr,
          streamID != kAudioObjectUnknown
    else { return 0 }

    var streamAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyLatency,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var latency: UInt32 = 0
    var latSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(streamID, &streamAddr, 0, nil, &latSize, &latency) == noErr
    else { return 0 }
    return Int(latency)
}

private func deviceNominalSampleRate(_ deviceID: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 48000
    var size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    return rate
}
