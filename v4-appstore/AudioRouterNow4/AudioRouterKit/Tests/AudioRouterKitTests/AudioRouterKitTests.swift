//
//  AudioRouterKitTests.swift
//  AudioRouterKitTests
//
//  Phase-0-Tests: laufen OHNE Hardware und OHNE CoreAudio-Calls.
//  Golden-Tests für Konstanten sichern die v3-Parität ab.
//

import Testing
import Foundation
@testable import AudioRouterKit

// MARK: - RouterError

@Suite("RouterError")
struct RouterErrorTests {

    @Test("Fälle sind unterscheidbar und Equatable")
    func caseEquality() {
        #expect(RouterError.tccDenied == RouterError.tccDenied)
        #expect(RouterError.deviceNotFound(uid: "A") == RouterError.deviceNotFound(uid: "A"))
        #expect(RouterError.deviceNotFound(uid: "A") != RouterError.deviceNotFound(uid: "B"))
        #expect(RouterError.tapFailed(status: -1) != RouterError.tccDenied)
    }

    @Test("'!dev' OSStatus (560227702) bleibt im tapFailed-Payload erhalten")
    func devNotAvailableStatus() {
        // v3-Lektion: '!dev' = kAudioHardwareBadDeviceError-Klasse
        let bangDev: Int32 = 560_227_702
        if case .tapFailed(let status) = RouterError.tapFailed(status: bangDev) {
            #expect(status == bangDev)
        } else {
            Issue.record("tapFailed payload lost")
        }
    }

    @Test("Nicht-ASCII-Geräte-UIDs (CJK) überleben den Error-Roundtrip")
    func nonASCIIDeviceUID() {
        // v3.4.4-Bug-Klasse: CJK-Seriennummern in Geräte-UIDs
        let uid = "USB-오디오-機器-12345"
        let error = RouterError.deviceNotFound(uid: uid)
        #expect(error == .deviceNotFound(uid: uid))
        #expect(error.errorDescription?.contains(uid) == true)
    }

    @Test("LocalizedError liefert englische Beschreibungen")
    func errorDescriptions() {
        #expect(RouterError.tccDenied.errorDescription?.isEmpty == false)
        #expect(RouterError.tapFailed(status: -50).errorDescription?.contains("-50") == true)
    }
}

// MARK: - RouterStatus

@Suite("RouterStatus")
struct RouterStatusTests {

    @Test("isRouting nur im routing-Zustand")
    func isRoutingFlag() {
        #expect(RouterStatus.routing.isRouting)
        #expect(!RouterStatus.idle.isRouting)
        #expect(!RouterStatus.error(.tccDenied).isRouting)
    }

    @Test("isError nur im error-Zustand")
    func isErrorFlag() {
        #expect(RouterStatus.error(.tccDenied).isError)
        #expect(!RouterStatus.idle.isError)
        #expect(!RouterStatus.routing.isError)
    }

    @Test("Error-Zustand transportiert den RouterError")
    func errorPayload() {
        let status = RouterStatus.error(.deviceNotFound(uid: "X"))
        #expect(status == .error(.deviceNotFound(uid: "X")))
        #expect(status != .error(.tccDenied))
    }
}

// MARK: - TapEngine (Phase 1 PoC)
// Hardware-abhängige Tests laufen auf echtem Mac — CI testet nur Fehler-Pfade.

@Suite("TapEngine (CI-safe: Fehler-Pfade)")
struct TapEngineTests {

    @Test("Initialer Status ist idle")
    @MainActor
    func initialStatusIsIdle() {
        let engine = TapEngine()
        #expect(engine.status == .idle)
    }

    @Test("start() wirft RouterError in CI-Umgebung (kein Audio/TCC)")
    @MainActor
    func startThrowsWithoutPermission() {
        let engine = TapEngine()
        // In CI (kein Audio, kein TCC): start() MUSS RouterError werfen.
        // Auf echtem Mac mit TCC: start() KANN .routing setzen (manuell testen).
        do {
            try engine.start()
            // Wenn wir hier ankommen: echter Mac mit TCC-Permission.
            // Status muss routing sein.
            #expect(engine.status == .routing)
            engine.stop()
            #expect(engine.status == .idle)
        } catch let error as RouterError {
            // CI-Pfad: RouterError erwartet (tapFailed oder tccDenied)
            #expect(engine.status == .idle, "Nach Fehler muss Status idle bleiben")
            _ = error // tapFailed(status:) oder tccDenied
        } catch {
            Issue.record("Unerwarteter Error-Typ: \(error) — nur RouterError erlaubt")
        }
    }

    @Test("stop() ist idempotent: mehrfach sicher aufrufbar")
    @MainActor
    func stopIsIdempotent() {
        let engine = TapEngine()
        engine.stop()  // Ohne start() — darf nicht crashen
        engine.stop()  // Doppeltes stop() — darf nicht crashen
        #expect(engine.status == .idle)
    }

    @Test("TCC Deep-Link URL ist valide (statisch, kein Hardware nötig)")
    func tccDeepLinkIsValid() {
        let url = TapEngine.tccDeepLink
        #expect(url.hasPrefix("x-apple.systempreferences:"), "Deep-Link muss x-apple.systempreferences: Scheme haben")
        #expect(url.contains("Privacy_AudioCapture"), "Deep-Link muss Privacy_AudioCapture enthalten")
    }
}

// MARK: - SPSCRingBuffer (Golden-Tests für v3-Parität)

@Suite("SPSCRingBuffer capacity")
struct SPSCRingBufferCapacityTest {

    @Test("Kapazität ist 16384 == 2^14 (Golden: v3 ARN_RING_CAPACITY)")
    func capacityIsPowerOfTwo() {
        let capacity = SPSCRingBuffer.capacity
        #expect(capacity == 16_384)
        #expect(capacity == 1 << 14)
        #expect(capacity.nonzeroBitCount == 1)
    }

    @Test("Maske ist capacity - 1 (Golden: v3 ARN_RING_MASK)")
    func maskMatchesCapacity() {
        #expect(SPSCRingBuffer.mask == SPSCRingBuffer.capacity - 1)
        #expect(SPSCRingBuffer.mask == 16_383)
    }

    @Test("uint32-Overflow ist transparent: 2^32 ist Vielfaches der Kapazität")
    func overflowTransparency() {
        let capacity = UInt64(SPSCRingBuffer.capacity)
        #expect((UInt64(UInt32.max) + 1) % capacity == 0)
    }

    @Test("Pre-Roll ist capacity/8 = 2048 Frames (Golden: v3 ARN_PREROLL_FRAMES)")
    func prerollFrames() {
        #expect(SPSCRingBuffer.prerollFrames == 2_048)
        #expect(SPSCRingBuffer.prerollFrames == SPSCRingBuffer.capacity / 8)
    }
}

// MARK: - SPSCRingBuffer Push/Pop (Phase 2)

@Suite("SPSCRingBuffer Push/Pop")
struct SPSCRingBufferPushPopTests {

    @Test("Leerer Ring liefert Stille (Pre-Roll-Gate geschlossen)")
    func emptyRingDeliversSilence() {
        let ring = SPSCRingBuffer()
        var left = [Float32](repeating: 1.0, count: 64)
        var right = [Float32](repeating: 1.0, count: 64)
        let ok = left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, frameCount: 64)
            }
        }
        #expect(!ok, "Underrun muss false zurückgeben")
        #expect(left.allSatisfy { $0 == 0 }, "Linker Buffer muss Stille sein")
        #expect(right.allSatisfy { $0 == 0 }, "Rechter Buffer muss Stille sein")
    }

    @Test("Push + Pop — Stereo-Roundtrip korrekt")
    func stereoPushPopRoundtrip() {
        let ring = SPSCRingBuffer()
        let frameCount = SPSCRingBuffer.prerollFrames // genau prerollFrames pushen

        // Input generieren
        let leftIn = (0..<frameCount).map { Float32($0) / Float32(frameCount) }
        let rightIn = (0..<frameCount).map { Float32($0) / Float32(frameCount) * -1 }

        // Push
        let pushed = leftIn.withUnsafeBufferPointer { lp in
            rightIn.withUnsafeBufferPointer { rp in
                ring.push(left: lp.baseAddress!, right: rp.baseAddress!, frameCount: frameCount)
            }
        }
        #expect(pushed, "Push muss bei ausreichend Platz true zurückgeben")

        // Pop (Pre-Roll-Gate öffnet nach prerollFrames)
        var leftOut = [Float32](repeating: 0, count: frameCount)
        var rightOut = [Float32](repeating: 0, count: frameCount)
        let popped = leftOut.withUnsafeMutableBufferPointer { lp in
            rightOut.withUnsafeMutableBufferPointer { rp in
                ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, frameCount: frameCount)
            }
        }
        #expect(popped, "Pop nach prerollFrames muss true zurückgeben")

        // Vergleich (Float32 Exaktheit — keine Konversion, direkte Memcopy)
        #expect(leftOut == leftIn, "Linker Kanal muss identisch sein")
        #expect(rightOut == rightIn, "Rechter Kanal muss identisch sein")
    }

    @Test("Pre-Roll-Gate öffnet erst nach prerollFrames Frames")
    func prerollGateOpens() {
        let ring = SPSCRingBuffer()
        let preroll = SPSCRingBuffer.prerollFrames

        // Einen Frame weniger als prerollFrames pushen → Gate bleibt zu
        let dummy = [Float32](repeating: 0.5, count: preroll - 1)
        _ = dummy.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: preroll - 1)
        }

        var out = [Float32](repeating: 1.0, count: 64)
        let ok1 = out.withUnsafeMutableBufferPointer { p in
            ring.pop(left: p.baseAddress!, right: nil, frameCount: 64)
        }
        #expect(!ok1, "Gate muss noch geschlossen sein")

        // Einen weiteren Frame pushen → Gate öffnet
        let one = [Float32](repeating: 0.5, count: 1)
        _ = one.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: 1)
        }
        let ok2 = out.withUnsafeMutableBufferPointer { p in
            ring.pop(left: p.baseAddress!, right: nil, frameCount: 64)
        }
        #expect(ok2, "Gate muss nach prerollFrames offen sein")
    }

    @Test("Overrun: voller Ring lässt push false zurückgeben")
    func overrunReturnsFalse() {
        let ring = SPSCRingBuffer()
        // capacity ist in SAMPLES: 16384 Samples = 8192 Stereo-Frames.
        // Zwei Pushes à capacity/4 = 4096 Frames (= 8192 Samples) füllen
        // den Ring exakt.
        let halfRingFrames = SPSCRingBuffer.capacity / 4

        let data = [Float32](repeating: 0.1, count: halfRingFrames)
        let push1 = data.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: halfRingFrames)
        }
        let push2 = data.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: halfRingFrames)
        }
        #expect(push1, "Erster Push muss true sein")
        #expect(push2, "Zweiter Push (Ring genau voll) muss true sein")

        // Jetzt überläuft er
        let one = [Float32](repeating: 0.1, count: 1)
        let push3 = one.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: 1)
        }
        #expect(!push3, "Dritter Push bei vollem Ring muss false sein")
    }

    @Test("uint32 write_idx Overflow ist transparent")
    func writeIdxOverflow() {
        let ring = SPSCRingBuffer()
        // write_idx nahe an UInt32.max setzen (pre-overflow), dann push.
        // UInt32.max - 11 ist GERADE (Frame-aligned, Vertrag des Test-Hooks).
        let nearMax = UInt32.max &- 11
        // Beide Indizes gleich → Ring sieht leer aus (write == read)
        ring._testing_setIndices(write: nearMax, read: nearMax)

        let data = [Float32](repeating: 0.42, count: SPSCRingBuffer.prerollFrames)
        let pushed = data.withUnsafeBufferPointer { p in
            ring.push(left: p.baseAddress!, right: p.baseAddress!, frameCount: SPSCRingBuffer.prerollFrames)
        }
        #expect(pushed, "Push über uint32-Overflow-Grenze muss funktionieren (kein Crash)")

        // Verfügbare Samples: wrapping-Differenz muss trotz Overflow stimmen
        #expect(ring._testing_availableSamples == SPSCRingBuffer.prerollFrames * 2,
                "Verfügbare Samples nach Overflow-Push müssen korrekt sein")
    }
}

// MARK: - DeviceLifecycleManager

@Suite("DeviceLifecycleManager settle delays")
struct DeviceLifecycleManagerSettleDelayTest {

    @Test("HDMI-Settle-Karenz ist 3.0 s")
    func hdmiSettleDelay() {
        #expect(DeviceLifecycleManager.hdmiSettleDelay == 3.0)
    }

    @Test("BT-Settle-Karenz ist 2.0 s")
    func btSettleDelay() {
        #expect(DeviceLifecycleManager.btSettleDelay == 2.0)
    }

    @Test("HDMI-Karenz > BT-Karenz")
    func hdmiLongerThanBT() {
        #expect(DeviceLifecycleManager.hdmiSettleDelay > DeviceLifecycleManager.btSettleDelay)
    }

    @Test("settleDelay(isBluetooth:) wählt transportspezifisch")
    func transportSelection() {
        #expect(DeviceLifecycleManager.settleDelay(isBluetooth: true) == DeviceLifecycleManager.btSettleDelay)
        #expect(DeviceLifecycleManager.settleDelay(isBluetooth: false) == DeviceLifecycleManager.hdmiSettleDelay)
    }

    @Test("DeviceState-Zustandsmaschine: alle 4 Fälle unterscheidbar")
    func deviceStateCases() {
        let states: [DeviceState] = [.active, .disappearing, .reconnecting, .unavailable]
        let descriptions = Set(states.map { "\($0)" })
        #expect(descriptions.count == 4)
        #expect(DeviceState.active != DeviceState.unavailable)
    }
}
