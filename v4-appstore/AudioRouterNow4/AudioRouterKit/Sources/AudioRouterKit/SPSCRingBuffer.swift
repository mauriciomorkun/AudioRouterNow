//
//  SPSCRingBuffer.swift
//  AudioRouterKit
//
//  Phase 2 — Single-Producer/Single-Consumer Ring-Buffer (echte Implementierung).
//
//  Referenz-Implementierung: v3 C-Code in helper/AudioRouterNowHelper.c
//  und helper/shared_ring.h (ARN_RING_CAPACITY = 16384, ARN_RING_MASK).
//
//  Design-Notizen aus v3, die dieser Swift-Port ÜBERNIMMT:
//
//    - Monoton steigende atomic-uint32-Indizes (write_idx / read_idx),
//      uint32-Overflow ist OK, weil 2^32 ein Vielfaches der Kapazität ist
//      (Power-of-2!). Position = index & mask.
//    - Producer-Hot / Consumer-Hot auf getrennten Cache-Lines
//      (Offset 0 vs. 64 im Control-Block — False-Sharing vermeiden).
//    - KEINE Locks, KEINE Allokationen, KEIN throw auf dem Realtime-Pfad:
//      UnsafeMutableBufferPointer + swift-atomics `UnsafeAtomic`.
//    - Overrun-Erkennung Consumer-seitig: behind > capacity → Re-Sync
//      (v3: helper Zeile ~934).
//    - Pre-Roll: Consumer gibt Stille bis prerollFrames = 2048 Frames
//      (≈ 43 ms @ 48 kHz) gefüllt sind (v3: ARN_PREROLL_FRAMES).
//    - Pro Output-Channel-Route EIN eigener Ring — der Tap-Callback
//      (Producer) überspringt volle Ringe non-blocking (push → false).
//
//  Einheiten-Konvention:
//    - Der Ring speichert INTERLEAVED Float32-Stereo (L,R,L,R,…).
//    - `capacity`/`mask` sind in SAMPLES (16384 Samples = 8192 Stereo-Frames).
//    - Die Indizes write_idx/read_idx zählen SAMPLES, werden pro Frame um 2
//      erhöht und bleiben damit immer gerade (Frame-aligned) — auch über den
//      uint32-Overflow hinweg, weil 2^32 ein Vielfaches von 2 UND von
//      capacity ist.
//    - `prerollFrames` ist in FRAMES (v3-Golden-Konstante: capacity/8 = 2048).
//

import Atomics
import Foundation

/// Lock-freier Single-Producer/Single-Consumer Ring-Buffer für den
/// Realtime-Audio-Pfad (Tap-IOProc → Output-IOProc).
///
/// ## SPSC-Invariante (Grund für `@unchecked Sendable`)
///
/// Genau EIN Producer-Thread ruft `push…` auf (der Tap-IOProc auf
/// `com.apple.audio.IOThread.client` des Aggregate Devices) und genau EIN
/// Consumer-Thread ruft `pop…` auf (der Output-IOProc des Ziel-Devices).
/// Niemals zwei Produzenten oder zwei Konsumenten gleichzeitig.
///
/// Unter dieser Invariante ist der Zugriff korrekt synchronisiert:
/// - Der Producer besitzt `writeIdx` exklusiv (store `.releasing` publiziert
///   die geschriebenen Samples), liest `readIdx` nur `.acquiring`.
/// - Der Consumer besitzt `readIdx` und `prerollDone` exklusiv (store
///   `.releasing` gibt Slots frei), liest `writeIdx` nur `.acquiring`.
/// - Der Sample-Storage wird pro Slot immer nur von genau einer Seite
///   berührt (Ownership wechselt über die Acquire/Release-Paare).
///
/// Der Compiler kann diese Invariante nicht prüfen → `@unchecked Sendable`
/// mit dieser Dokumentation als Vertrag.
///
/// Alle `push…`/`pop…`-Methoden sind RT-safe: non-throwing, non-allocating,
/// non-blocking, keine ObjC/Swift-Runtime-Calls im Hot-Path.
public final class SPSCRingBuffer: @unchecked Sendable {

    // MARK: Golden-Konstanten (v3-Parität)

    /// Kapazität in Samples — MUSS Power-of-2 sein (wie v3:
    /// `ARN_RING_CAPACITY = 16384`), damit Index-Wrapping via Bitmaske
    /// funktioniert und uint32-Overflow der monotonen Indizes transparent ist.
    public static let capacity: Int = 16_384

    /// Bitmaske für Index-Wrapping (v3: `ARN_RING_MASK = capacity - 1`).
    public static let mask: Int = capacity - 1

    /// Pre-Roll-Schwelle in Frames: capacity/8 = 2048 ≈ 43 ms @ 48 kHz
    /// (v3: `ARN_PREROLL_FRAMES`). Consumer liefert Stille, bis der Ring
    /// mindestens so weit gefüllt ist — verhindert Start-Underruns.
    public static let prerollFrames: Int = capacity / 8

    /// Pre-Roll-Schwelle in Samples (interleaved Stereo → Frames × 2).
    private static let prerollSampleCount = UInt32(prerollFrames * 2)

    // MARK: Storage

    /// Interleaved Float32-Stereo-Storage (L,R,L,R,…), `capacity` Samples.
    private let samples: UnsafeMutableBufferPointer<Float32>

    /// Control-Block für die beiden Atomics: 128 Bytes, 128-Byte-aligned.
    ///
    /// Cache-Line-Separation: `writeIdx`-Storage liegt bei Offset 0
    /// (Producer-Hot, Cache-Line 0), `readIdx`-Storage bei Offset 64
    /// (Consumer-Hot, Cache-Line 1). Bewusst `UnsafeAtomic` mit manuell
    /// platziertem Storage statt `ManagedAtomic`: dessen Storage ist
    /// heap-boxed pro Instanz — Padding-Structs um `ManagedAtomic`-Referenzen
    /// würden die Atomics NICHT auf getrennte Cache-Lines legen.
    private let controlBlock: UnsafeMutableRawPointer

    /// Monoton steigender Producer-Index in Samples (Cache-Line 0).
    private let writeIdx: UnsafeAtomic<UInt32>

    /// Monoton steigender Consumer-Index in Samples (Cache-Line 1).
    private let readIdx: UnsafeAtomic<UInt32>

    /// Pre-Roll-Gate offen? NUR der Consumer-Thread liest/schreibt dieses
    /// Feld (SPSC-Invariante) — daher bewusst non-atomic.
    /// Nach einem Underrun wird das Gate wieder geschlossen (Re-Preroll),
    /// damit sich Stotter-Ketten nicht aufschaukeln (v3-Verhalten).
    private var prerollDone = false

    private static let cacheLineSize = 64

    // MARK: Init / Deinit

    /// Alloziert Storage + Control-Block; alle Samples und Indizes auf 0.
    public init() {
        samples = UnsafeMutableBufferPointer<Float32>.allocate(capacity: Self.capacity)
        samples.initialize(repeating: 0)

        controlBlock = UnsafeMutableRawPointer.allocate(
            byteCount: 2 * Self.cacheLineSize,
            alignment: 2 * Self.cacheLineSize
        )
        // UInt32-Storage ist trivial — plain deallocate im deinit reicht.
        let writeStorage = controlBlock
            .bindMemory(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1)
        writeStorage.initialize(to: .init(0))
        let readStorage = (controlBlock + Self.cacheLineSize)
            .bindMemory(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1)
        readStorage.initialize(to: .init(0))

        writeIdx = UnsafeAtomic(at: writeStorage)
        readIdx = UnsafeAtomic(at: readStorage)
    }

    deinit {
        // Storage ist trivial (UInt32) — kein dispose() nötig, nur Speicher
        // freigeben. KEIN writeIdx.destroy(): das würde zusätzlich
        // deallozieren wollen (nur für UnsafeAtomic.create()-Instanzen).
        controlBlock.deallocate()
        samples.deallocate()
    }

    // MARK: Producer-Seite (Tap-IOProc-Thread)

    /// Schreibt `frameCount` Stereo-Frames aus non-interleaved Input in den
    /// Ring (interleaved L,R,L,R,…).
    ///
    /// - Parameters:
    ///   - left: Linker Kanal, `frameCount` Float32-Samples.
    ///   - right: Rechter Kanal oder `nil` (mono) → L wird auf beide
    ///     Ring-Kanäle dupliziert.
    /// - Returns: `false`, wenn der Ring den Block nicht komplett aufnehmen
    ///   kann (Overrun) — der Block wird vollständig übersprungen
    ///   (non-blocking, kein Partial-Write, kein Crash).
    @discardableResult
    public func push(
        left: UnsafePointer<Float32>,
        right: UnsafePointer<Float32>?,
        frameCount: Int
    ) -> Bool {
        guard let base = beginPush(frameCount: frameCount) else { return frameCount == 0 }
        guard frameCount > 0 else { return true }

        let buf = samples.baseAddress!
        var pos = Int(base) & Self.mask
        if let right {
            for i in 0..<frameCount {
                buf[pos] = left[i]
                buf[(pos + 1) & Self.mask] = right[i]
                pos = (pos + 2) & Self.mask
            }
        } else {
            for i in 0..<frameCount {
                let v = left[i]
                buf[pos] = v
                buf[(pos + 1) & Self.mask] = v
                pos = (pos + 2) & Self.mask
            }
        }
        commitPush(base: base, frameCount: frameCount)
        return true
    }

    /// Schreibt `frameCount` Stereo-Frames aus einem INTERLEAVED Input-Buffer.
    ///
    /// Nötig für den realen CoreAudio-Pfad: der Tap-Stereo-Mixdown liefert
    /// typischerweise EINEN Buffer mit `mNumberChannels == 2` (interleaved),
    /// nicht zwei Mono-Buffer.
    ///
    /// - Parameters:
    ///   - src: Zeigt auf das erste Sample des L-Kanals im ersten Frame.
    ///   - stride: Samples pro Frame im Quell-Buffer (Kanalzahl).
    ///     `stride == 1` → mono, L wird dupliziert. `stride >= 2` → L/R sind
    ///     die ersten beiden Kanäle ab `src`, weitere werden ignoriert.
    /// - Returns: `false` bei Overrun (Block komplett übersprungen).
    @discardableResult
    public func pushInterleaved(
        from src: UnsafePointer<Float32>,
        stride: Int,
        frameCount: Int
    ) -> Bool {
        guard let base = beginPush(frameCount: frameCount) else { return frameCount == 0 }
        guard frameCount > 0 else { return true }

        let buf = samples.baseAddress!
        var pos = Int(base) & Self.mask
        if stride >= 2 {
            for i in 0..<frameCount {
                buf[pos] = src[i * stride]
                buf[(pos + 1) & Self.mask] = src[i * stride + 1]
                pos = (pos + 2) & Self.mask
            }
        } else {
            for i in 0..<frameCount {
                let v = src[i]
                buf[pos] = v
                buf[(pos + 1) & Self.mask] = v
                pos = (pos + 2) & Self.mask
            }
        }
        commitPush(base: base, frameCount: frameCount)
        return true
    }

    /// Kapazitäts-Check des Producers. Liefert den Start-Index (in Samples)
    /// oder `nil`, wenn der Block nicht komplett passt (Overrun-Skip).
    @inline(__always)
    private func beginPush(frameCount: Int) -> UInt32? {
        guard frameCount > 0 else { return nil }
        let needed = UInt32(truncatingIfNeeded: frameCount &* 2)
        // Producer besitzt writeIdx exklusiv → relaxed load reicht.
        let w = writeIdx.load(ordering: .relaxed)
        // Acquire: paart mit dem releasing-Store des Consumers und macht die
        // freigegebenen Slots für den Producer sichtbar.
        let r = readIdx.load(ordering: .acquiring)
        let used = w &- r // wrapping-Differenz — Overflow-transparent
        guard UInt32(Self.capacity) &- used >= needed, needed <= UInt32(Self.capacity) else {
            return nil
        }
        return w
    }

    /// Publiziert die geschriebenen Samples (Release-Store des writeIdx).
    @inline(__always)
    private func commitPush(base: UInt32, frameCount: Int) {
        writeIdx.store(
            base &+ UInt32(truncatingIfNeeded: frameCount &* 2),
            ordering: .releasing
        )
    }

    // MARK: Consumer-Seite (Output-IOProc-Thread)

    /// Liest `frameCount` Stereo-Frames aus dem Ring in non-interleaved
    /// Output-Buffer.
    ///
    /// - Parameters:
    ///   - left: Ziel-Buffer für den linken Kanal (`frameCount` Samples).
    ///   - right: Ziel-Buffer rechts oder `nil` (mono Output) → nur der
    ///     L-Kanal des Rings wird ausgegeben, R wird verworfen.
    /// - Returns: `false` bei Underrun ODER geschlossenem Pre-Roll-Gate —
    ///   beide Ziel-Buffer werden dann mit Stille (0.0) gefüllt.
    @discardableResult
    public func pop(
        left: UnsafeMutablePointer<Float32>,
        right: UnsafeMutablePointer<Float32>?,
        frameCount: Int
    ) -> Bool {
        guard frameCount > 0 else { return true }
        guard let base = beginPop(frameCount: frameCount) else {
            left.update(repeating: 0, count: frameCount)
            right?.update(repeating: 0, count: frameCount)
            return false
        }

        let buf = samples.baseAddress!
        var pos = Int(base) & Self.mask
        if let right {
            for i in 0..<frameCount {
                left[i] = buf[pos]
                right[i] = buf[(pos + 1) & Self.mask]
                pos = (pos + 2) & Self.mask
            }
        } else {
            for i in 0..<frameCount {
                left[i] = buf[pos]
                pos = (pos + 2) & Self.mask
            }
        }
        commitPop(base: base, frameCount: frameCount)
        return true
    }

    /// Liest `frameCount` Stereo-Frames in einen INTERLEAVED Output-Buffer.
    ///
    /// Nötig für den realen CoreAudio-Pfad: typische Output-Devices
    /// (MacBook-Speaker, USB-Interfaces) liefern EINEN Buffer mit
    /// `mNumberChannels >= 2` (interleaved).
    ///
    /// - Parameters:
    ///   - dst: Zeigt auf das erste Sample des Ziel-L-Kanals im ersten Frame
    ///     (bei Channel-Offset: bereits um den Offset vorgerückt).
    ///   - stride: Samples pro Frame im Ziel-Buffer (Kanalzahl des Buffers).
    ///     MUSS >= 2 sein; L→`dst[i*stride]`, R→`dst[i*stride+1]`.
    /// - Returns: `false` bei Underrun/Pre-Roll — Zielkanäle werden mit
    ///   Stille gefüllt.
    @discardableResult
    public func popInterleaved(
        into dst: UnsafeMutablePointer<Float32>,
        stride: Int,
        frameCount: Int
    ) -> Bool {
        guard frameCount > 0, stride >= 2 else { return frameCount == 0 }
        guard let base = beginPop(frameCount: frameCount) else {
            for i in 0..<frameCount {
                dst[i * stride] = 0
                dst[i * stride + 1] = 0
            }
            return false
        }

        let buf = samples.baseAddress!
        var pos = Int(base) & Self.mask
        for i in 0..<frameCount {
            dst[i * stride] = buf[pos]
            dst[i * stride + 1] = buf[(pos + 1) & Self.mask]
            pos = (pos + 2) & Self.mask
        }
        commitPop(base: base, frameCount: frameCount)
        return true
    }

    /// Verfügbarkeits-Check des Consumers inkl. Overrun-Resync und
    /// Pre-Roll-Gate. Liefert den Start-Index (in Samples) oder `nil`
    /// (→ Aufrufer füllt Stille).
    @inline(__always)
    private func beginPop(frameCount: Int) -> UInt32? {
        let needed = UInt32(truncatingIfNeeded: frameCount &* 2)
        // Acquire: paart mit dem releasing-Store des Producers und macht die
        // publizierten Samples für den Consumer sichtbar.
        let w = writeIdx.load(ordering: .acquiring)
        // Consumer besitzt readIdx exklusiv → relaxed load reicht.
        var r = readIdx.load(ordering: .relaxed)
        var available = w &- r

        // Overrun-Resync (v3: behind > capacity → Re-Sync). Mit dem
        // Skip-on-full-Producer oben kann das regulär nicht eintreten —
        // defensiv beibehalten (v3-Parität, schützt vor Index-Manipulation).
        if available > UInt32(Self.capacity) {
            r = w &- UInt32(Self.capacity)
            readIdx.store(r, ordering: .releasing)
            available = UInt32(Self.capacity)
        }

        // Pre-Roll-Gate: Stille bis mindestens prerollFrames im Ring liegen.
        if !prerollDone {
            if available >= Self.prerollSampleCount {
                prerollDone = true
            } else {
                return nil
            }
        }

        // Underrun: nicht genug Frames → Stille + Gate wieder schließen
        // (Re-Preroll verhindert Stotter-Ketten).
        if available < needed {
            prerollDone = false
            return nil
        }
        return r
    }

    /// Gibt die gelesenen Slots frei (Release-Store des readIdx).
    @inline(__always)
    private func commitPop(base: UInt32, frameCount: Int) {
        readIdx.store(
            base &+ UInt32(truncatingIfNeeded: frameCount &* 2),
            ordering: .releasing
        )
    }

    // MARK: Test-Hooks (internal — via @testable)

    /// NUR für Tests: setzt beide monotonen Indizes und schließt das
    /// Pre-Roll-Gate. Darf nie aufgerufen werden, während Producer/Consumer
    /// aktiv sind. `write`/`read` sollten gerade (Frame-aligned) sein —
    /// die Produktions-Pfade erhöhen immer um 2 und starten bei 0.
    func _testing_setIndices(write: UInt32, read: UInt32) {
        writeIdx.store(write, ordering: .sequentiallyConsistent)
        readIdx.store(read, ordering: .sequentiallyConsistent)
        prerollDone = false
    }

    /// NUR für Tests: aktueller Füllstand in Samples.
    var _testing_availableSamples: Int {
        Int(writeIdx.load(ordering: .acquiring) &- readIdx.load(ordering: .acquiring))
    }
}
