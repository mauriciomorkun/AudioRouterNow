//  DelayLine.swift
//  AudioRouterKit
//
//  Phase 4 — Latency-Compensation Delay-Line für den Direct-IOProc.
//
//  Single-Thread-Invariante: NUR vom IOProc-Thread aufgerufen (push + pop im
//  selben Callback). Keine Locks, keine Atomics, keine Allokationen im Pfad.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.

import Foundation

/// Stereo-Delay-Line für Output-Latency-Compensation.
///
/// Funktionsprinzip: Der interne Buffer wird mit `delayFrames` Stille
/// vorbelegt. Bei jedem `process()`-Aufruf wird zunächst das "alte" Audio
/// (= genau `delayFrames` Frames alt) ausgelesen und dann das neue Audio
/// eingeschrieben — netto: Ausgabe ist um `delayFrames` Frames verzögert.
///
/// ## Single-Thread-Invariante
/// `process()` darf ausschließlich vom IOProc-Thread aufgerufen werden.
/// Niemals concurrent, daher kein Lock/Atomic nötig.
/// `@unchecked Sendable` ist korrekt: die Instanz wird nach `init()`
/// ausschließlich vom IOProc-Thread mutiert.
public final class DelayLine: @unchecked Sendable {

    /// Wie viele Frames sind mindestens nötig, damit eine DelayLine sinnvoll ist.
    /// Darunter: direkt schreiben (kein Delay-Overhead).
    public static let minimumDelayFrames = 64

    private let lBuffer: UnsafeMutableBufferPointer<Float32>
    private let rBuffer: UnsafeMutableBufferPointer<Float32>
    private let capacityFrames: Int
    /// Verzögerung in Frames (unveränderlich nach init).
    private let delay: Int
    /// Schreib-Position des NEUEN Audios (in Frames).
    private var writePos: Int
    /// Lese-Position des VERZÖGERTEN Audios (= `delay` Frames hinter writePos).
    private var readPos: Int

    /// Erstellt eine Delay-Line mit exakt `delayFrames` Frames Verzögerung.
    ///
    /// Kapazität = `delayFrames + maxFramesPerCallback`, damit ein IO-Callback
    /// mit bis zu `maxFramesPerCallback` Frames die Kapazität NIEMALS übersteigt
    /// (F1-Regression: früher blieb das Gerät stumm, sobald der IO-Buffer größer
    /// als die Delay-Länge war).
    ///
    /// - Parameters:
    ///   - delayFrames: Verzögerung in Frames (wird auf min. 1 geclamped).
    ///   - maxFramesPerCallback: obere Grenze der IO-Buffer-Größe (Default 4096).
    public init(delayFrames: Int, maxFramesPerCallback: Int = 4096) {
        let d = max(1, delayFrames)
        let maxIO = max(1, maxFramesPerCallback)
        delay = d
        capacityFrames = d + maxIO
        lBuffer = UnsafeMutableBufferPointer<Float32>.allocate(capacity: capacityFrames)
        rBuffer = UnsafeMutableBufferPointer<Float32>.allocate(capacity: capacityFrames)
        lBuffer.initialize(repeating: 0)
        rBuffer.initialize(repeating: 0)
        // readPos startet bei 0, writePos `delay` Frames voraus → die ersten
        // `delay` Frames Output sind Stille (pre-fill), danach fließt Audio.
        readPos = 0
        writePos = d % capacityFrames
    }

    deinit {
        lBuffer.deallocate()
        rBuffer.deallocate()
    }

    /// Verarbeitet `frameCount` Stereo-Frames: liest verzögertes Audio (readPos),
    /// schreibt neues Audio (writePos). Beide Positionen wandern synchron.
    ///
    /// - Parameters:
    ///   - frameCount: Anzahl Frames. Muss <= capacityFrames sein (garantiert
    ///     durch den IOProc-Clamp auf maxFramesPerCallback).
    ///   - inL: Linker Eingangskanal. nil → Stille.
    ///   - inR: Rechter Kanal oder nil → Mono (L wird dupliziert).
    ///   - outL: Ziel für verzögertes L.
    ///   - outR: Ziel für verzögertes R, oder nil.
    public func process(
        frameCount: Int,
        inL: UnsafeMutablePointer<Float32>?,
        inR: UnsafeMutablePointer<Float32>?,
        outL: UnsafeMutablePointer<Float32>,
        outR: UnsafeMutablePointer<Float32>?
    ) {
        guard frameCount > 0, frameCount <= capacityFrames else { return }

        let lBase = lBuffer.baseAddress!
        let rBase = rBuffer.baseAddress!

        // ── 1) Lesen (delayed) aus readPos → outL/outR (ggf. Wrap) ──
        let rChunk1 = min(frameCount, capacityFrames - readPos)
        let rChunk2 = frameCount - rChunk1
        outL.update(from: lBase + readPos, count: rChunk1)
        if let outR { outR.update(from: rBase + readPos, count: rChunk1) }
        if rChunk2 > 0 {
            outL.advanced(by: rChunk1).update(from: lBase, count: rChunk2)
            if let outR { outR.advanced(by: rChunk1).update(from: rBase, count: rChunk2) }
        }

        // ── 2) Schreiben (neu) an writePos ← inL/inR (ggf. Wrap) ──
        let wChunk1 = min(frameCount, capacityFrames - writePos)
        let wChunk2 = frameCount - wChunk1
        if let inL {
            let src = inR ?? inL // Mono → R = L
            (lBase + writePos).update(from: inL, count: wChunk1)
            (rBase + writePos).update(from: src, count: wChunk1)
            if wChunk2 > 0 {
                lBase.update(from: inL.advanced(by: wChunk1), count: wChunk2)
                rBase.update(from: src.advanced(by: wChunk1), count: wChunk2)
            }
        } else {
            (lBase + writePos).initialize(repeating: 0, count: wChunk1)
            (rBase + writePos).initialize(repeating: 0, count: wChunk1)
            if wChunk2 > 0 {
                lBase.initialize(repeating: 0, count: wChunk2)
                rBase.initialize(repeating: 0, count: wChunk2)
            }
        }

        writePos = (writePos + frameCount) % capacityFrames
        readPos  = (readPos  + frameCount) % capacityFrames
    }

    /// Verarbeitet einen interleaved Eingangs-Buffer (stride ≥ 2).
    /// Liest L aus `src[i*stride + srcOffset]`, R aus `src[i*stride + srcOffset + 1]`.
    /// Schreibt verzögertes L/R nach outL/outR (non-interleaved).
    public func processInterleaved(
        frameCount: Int,
        src: UnsafeMutablePointer<Float32>,
        srcStride: Int,
        srcOffset: Int,
        outL: UnsafeMutablePointer<Float32>,
        outR: UnsafeMutablePointer<Float32>?
    ) {
        guard frameCount > 0, frameCount <= capacityFrames, srcStride >= 2 else { return }

        let lBase = lBuffer.baseAddress!
        let rBase = rBuffer.baseAddress!

        // Erst KOMPLETT lesen (delayed) …
        var rp = readPos
        for i in 0..<frameCount {
            outL[i] = lBase[rp]
            outR?[i] = rBase[rp]
            rp += 1; if rp == capacityFrames { rp = 0 }
        }
        // … dann KOMPLETT schreiben (neu). Getrennte Pässe → kein Overlap-Bug,
        // auch wenn delay < frameCount.
        var wp = writePos
        for i in 0..<frameCount {
            lBase[wp] = src[i * srcStride + srcOffset]
            rBase[wp] = src[i * srcStride + min(srcOffset + 1, srcStride - 1)]
            wp += 1; if wp == capacityFrames { wp = 0 }
        }

        writePos = (writePos + frameCount) % capacityFrames
        readPos  = (readPos  + frameCount) % capacityFrames
    }

    /// Verzögerung in Frames (unveränderlich nach init).
    public var delayFrames: Int { delay }
}
