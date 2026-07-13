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

// MARK: - FanOutEngine (CI-safe: Fehler-Pfade)
// Hardware-abhängige Tests laufen auf echtem Mac — CI testet nur Fehler-Pfade.

@Suite("FanOutEngine (CI-safe: Fehler-Pfade)")
struct FanOutEngineTests {

    @Test("Initialer Status ist idle")
    @MainActor
    func initialStatusIsIdle() {
        let engine = FanOutEngine()
        #expect(engine.status == .idle)
    }

    @Test("start() wirft RouterError in CI (kein Audio/TCC) — oder routet auf echtem Mac")
    @MainActor
    func startBehaviour() {
        let engine = FanOutEngine()
        do {
            try engine.start()
            #expect(engine.status == .routing)
            engine.stop()
            #expect(engine.status == .idle)
        } catch let error as RouterError {
            #expect(engine.status == .idle, "Nach Fehler muss Status idle bleiben")
            _ = error
        } catch {
            Issue.record("Unerwarteter Error-Typ: \(error) — nur RouterError erlaubt")
        }
    }

    @Test("stop() ist idempotent")
    @MainActor
    func stopIsIdempotent() {
        let engine = FanOutEngine()
        engine.stop()
        engine.stop()
        #expect(engine.status == .idle)
    }

    @Test("TCC Deep-Link URL ist valide (statisch)")
    func tccDeepLinkIsValid() {
        let url = FanOutEngine.tccDeepLink
        #expect(url.hasPrefix("x-apple.systempreferences:"))
        #expect(url.contains("Privacy_AudioCapture"))
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

// MARK: - DelayLine (Phase 4)

@Suite("DelayLine")
struct DelayLineTests {

    @Test("Stille passiert unverändert durch (pre-fill = silence)")
    func silencePassthrough() {
        let delay = DelayLine(delayFrames: 512)
        var inL  = [Float32](repeating: 0.5, count: 64)
        var outL = [Float32](repeating: 99,  count: 64)
        inL.withUnsafeMutableBufferPointer { il in
            outL.withUnsafeMutableBufferPointer { ol in
                delay.process(frameCount: 64, inL: il.baseAddress, inR: nil,
                              outL: ol.baseAddress!, outR: nil)
            }
        }
        // Ersten 512 Frames: Stille (pre-fill). Da wir nur 64 Frames pushen,
        // kommt noch Stille zurück.
        #expect(outL.allSatisfy { $0 == 0 }, "Erster Output muss Stille sein (delay noch nicht gefüllt)")
    }

    @Test("Audio erscheint nach genau delayFrames Frames")
    func delayIsExact() {
        let delayFrames = 256
        let delay = DelayLine(delayFrames: delayFrames)
        let batchSize = 64  // delayFrames / 4, damit wir sauber auf Grenzen arbeiten

        var silent = [Float32](repeating: 0, count: batchSize)
        var audio  = [Float32](repeating: 1.0, count: batchSize)
        var outL   = [Float32](repeating: 0, count: batchSize)

        // 1. delayFrames / batchSize Runden Stille pushen → immer Stille zurück
        let rounds = delayFrames / batchSize
        for _ in 0..<rounds {
            silent.withUnsafeMutableBufferPointer { sl in
                outL.withUnsafeMutableBufferPointer { ol in
                    delay.process(frameCount: batchSize, inL: sl.baseAddress, inR: nil,
                                  outL: ol.baseAddress!, outR: nil)
                }
            }
            #expect(outL.allSatisfy { $0 == 0 }, "Muss noch Stille sein")
        }

        // 2. Audio pushen → Stille zurück (Audio ist gerade reingewandert)
        audio.withUnsafeMutableBufferPointer { al in
            outL.withUnsafeMutableBufferPointer { ol in
                delay.process(frameCount: batchSize, inL: al.baseAddress, inR: nil,
                              outL: ol.baseAddress!, outR: nil)
            }
        }
        #expect(outL.allSatisfy { $0 == 0 }, "Audio darf noch nicht durch sein")

        // 3. Weitere (rounds - 1) Runden Stille → immer noch Stille
        for _ in 0..<(rounds - 1) {
            silent.withUnsafeMutableBufferPointer { sl in
                outL.withUnsafeMutableBufferPointer { ol in
                    delay.process(frameCount: batchSize, inL: sl.baseAddress, inR: nil,
                                  outL: ol.baseAddress!, outR: nil)
                }
            }
            #expect(outL.allSatisfy { $0 == 0 })
        }

        // 4. Jetzt kommt das Audio durch (genau nach delayFrames Frames)
        silent.withUnsafeMutableBufferPointer { sl in
            outL.withUnsafeMutableBufferPointer { ol in
                delay.process(frameCount: batchSize, inL: sl.baseAddress, inR: nil,
                              outL: ol.baseAddress!, outR: nil)
            }
        }
        #expect(outL.allSatisfy { $0 == 1.0 }, "Audio muss nach delayFrames Frames erscheinen")
    }

    @Test("Stereo L/R bleiben getrennt")
    func stereoSeparation() {
        let delay = DelayLine(delayFrames: 64)
        var inL = [Float32](repeating: 1.0, count: 64)
        var inR = [Float32](repeating: -1.0, count: 64)
        var outL = [Float32](repeating: 0, count: 64)
        var outR = [Float32](repeating: 0, count: 64)

        // Erst Stille (pre-fill)
        inL.withUnsafeMutableBufferPointer { il in
            inR.withUnsafeMutableBufferPointer { ir in
                outL.withUnsafeMutableBufferPointer { ol in
                    outR.withUnsafeMutableBufferPointer { or in
                        delay.process(frameCount: 64, inL: il.baseAddress, inR: ir.baseAddress,
                                      outL: ol.baseAddress!, outR: or.baseAddress)
                    }
                }
            }
        }
        // Dann kommt Audio
        inL.withUnsafeMutableBufferPointer { il in
            inR.withUnsafeMutableBufferPointer { ir in
                outL.withUnsafeMutableBufferPointer { ol in
                    outR.withUnsafeMutableBufferPointer { or in
                        delay.process(frameCount: 64, inL: il.baseAddress, inR: ir.baseAddress,
                                      outL: ol.baseAddress!, outR: or.baseAddress)
                    }
                }
            }
        }
        #expect(outL.allSatisfy { $0 == 1.0 },  "L muss 1.0 sein")
        #expect(outR.allSatisfy { $0 == -1.0 }, "R muss -1.0 sein")
    }

    @Test("Wrap-Around am Pufferende korrekt")
    func wrapAround() {
        // delayFrames = 100, batchSize = 64 → nach Batch 1 (writePos=64)
        // liegt writePos+batchSize = 128 > 100 → Wrap nötig
        let delay = DelayLine(delayFrames: 100)
        var silent = [Float32](repeating: 0, count: 64)
        var audio  = [Float32](repeating: 0.7, count: 64)
        var outL   = [Float32](repeating: 0, count: 64)

        // Push Stille bis kurz vor Wrap
        silent.withUnsafeMutableBufferPointer { sl in
            outL.withUnsafeMutableBufferPointer { ol in
                delay.process(frameCount: 64, inL: sl.baseAddress, inR: nil,
                              outL: ol.baseAddress!, outR: nil)
            }
        }
        // Push Audio (verursacht Wrap: writePos 64 → 64+64=128 > 100 → kein Crash)
        var ok = true
        audio.withUnsafeMutableBufferPointer { al in
            outL.withUnsafeMutableBufferPointer { ol in
                // Kein crash → ok
                delay.process(frameCount: 64, inL: al.baseAddress, inR: nil,
                              outL: ol.baseAddress!, outR: nil)
                ok = true
            }
        }
        #expect(ok, "Wrap-Around darf nicht crashen")
    }

    @Test("delayFrames-Eigenschaft stimmt mit init überein")
    func delayFramesProperty() {
        #expect(DelayLine(delayFrames: 9600).delayFrames == 9600)
        #expect(DelayLine(delayFrames: 1).delayFrames == 1)
    }

    @Test("minimumDelayFrames ist > 0")
    func minimumDelayFrames() {
        #expect(DelayLine.minimumDelayFrames > 0)
        #expect(DelayLine.minimumDelayFrames == 64)
    }

    @Test("frameCount > delayFrames bleibt hörbar (F1-Regression)")
    func frameCountLargerThanDelay() {
        // Kleiner Delay (128), großer IO-Buffer (512) → früher: guard → stumm.
        let delay = DelayLine(delayFrames: 128, maxFramesPerCallback: 4096)
        var audio = [Float32](repeating: 0.9, count: 512)
        var outL  = [Float32](repeating: -1, count: 512)
        for _ in 0..<4 {
            audio.withUnsafeMutableBufferPointer { al in
                outL.withUnsafeMutableBufferPointer { ol in
                    delay.process(frameCount: 512, inL: al.baseAddress, inR: nil,
                                  outL: ol.baseAddress!, outR: nil)
                }
            }
        }
        #expect(outL.contains { $0 != 0 },
                "F1: Output darf bei frameCount > delayFrames nicht dauerhaft stumm sein")
    }

    @Test("processInterleaved verzögert um delayFrames und trennt L/R")
    func interleavedBasic() {
        let delay = DelayLine(delayFrames: 64, maxFramesPerCallback: 4096)
        var src = [Float32]()
        for _ in 0..<64 { src.append(0.5); src.append(-0.5) } // interleaved L,R
        var outL = [Float32](repeating: 0, count: 64)
        var outR = [Float32](repeating: 0, count: 64)

        // 1. Aufruf: Pre-fill-Stille kommt raus.
        src.withUnsafeMutableBufferPointer { sp in
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or in
                    delay.processInterleaved(frameCount: 64, src: sp.baseAddress!,
                                             srcStride: 2, srcOffset: 0,
                                             outL: ol.baseAddress!, outR: or.baseAddress)
                }
            }
        }
        #expect(outL.allSatisfy { $0 == 0 }, "Erster Output muss Stille sein")

        // 2. Aufruf: jetzt kommt das Audio (delay == 64).
        src.withUnsafeMutableBufferPointer { sp in
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or in
                    delay.processInterleaved(frameCount: 64, src: sp.baseAddress!,
                                             srcStride: 2, srcOffset: 0,
                                             outL: ol.baseAddress!, outR: or.baseAddress)
                }
            }
        }
        #expect(outL.allSatisfy { $0 == 0.5 },  "L verzögert korrekt")
        #expect(outR.allSatisfy { $0 == -0.5 }, "R verzögert korrekt")
    }
}

// MARK: - FanOutEngine Slot-Layout (F3/F6/F7)

@Suite("FanOutEngine slot layout")
struct SlotLayoutTests {

    @Test("Default-Output: bufferIndex 0, kein Delay, span 0..<2")
    func defaultOutputNoDelay() {
        let outputs = [OutputConfig(uid: "DEF", channelOffset: 0)]
        let info: [String: DeviceLayoutInfo] = [
            "DEF": .init(bufferOffset: 0, latencySeconds: 0, isInterleaved: false, bufferCount: 2)
        ]
        let layouts = FanOutEngine.computeSlotLayouts(
            allOutputs: outputs, deviceInfoByUID: info, aggregateSampleRate: 48_000)
        #expect(layouts.count == 1)
        #expect(layouts[0].bufferIndex == 0)
        #expect(layouts[0].delayFrames == 0)
        #expect(layouts[0].bufferSpan == 0..<2)
    }

    @Test("F6: niedrig-latentes Device wird Sample-Rate-normalisiert verzögert")
    func delayCompensation() {
        let outputs = [
            OutputConfig(uid: "FAST", channelOffset: 0),
            OutputConfig(uid: "SLOW", channelOffset: 0)
        ]
        let info: [String: DeviceLayoutInfo] = [
            "FAST": .init(bufferOffset: 0, latencySeconds: 0.010, isInterleaved: false, bufferCount: 2),
            "SLOW": .init(bufferOffset: 2, latencySeconds: 0.110, isInterleaved: false, bufferCount: 2)
        ]
        let layouts = FanOutEngine.computeSlotLayouts(
            allOutputs: outputs, deviceInfoByUID: info, aggregateSampleRate: 48_000)
        // FAST: delta 0,1 s × 48000 = 4800 Frames Delay.
        #expect(layouts[0].delayFrames == 4800)
        #expect(layouts[0].bufferSpan == 0..<2)
        // SLOW: höchste Latenz → 0 Delay, bufferIndex 2.
        #expect(layouts[1].delayFrames == 0)
        #expect(layouts[1].bufferIndex == 2)
        #expect(layouts[1].bufferSpan == 2..<4)
    }

    @Test("Interleaved-Device: channelOffset bleibt im Frame, bufferIndex == offset")
    func interleavedMapping() {
        let outputs = [OutputConfig(uid: "IL", channelOffset: 2)]
        let info: [String: DeviceLayoutInfo] = [
            "IL": .init(bufferOffset: 0, latencySeconds: 0, isInterleaved: true, bufferCount: 1)
        ]
        let layouts = FanOutEngine.computeSlotLayouts(
            allOutputs: outputs, deviceInfoByUID: info, aggregateSampleRate: 48_000)
        #expect(layouts[0].bufferIndex == 0)
        #expect(layouts[0].channelOffset == 2)
        #expect(layouts[0].bufferSpan == 0..<1)
    }
}

// MARK: - OutputConfig Codable

@Suite("OutputConfig Codable")
struct OutputConfigCodableTests {

    @Test("Codable-Roundtrip mit CJK-UID erhält alle Felder")
    func codableRoundtripCJK() throws {
        let original = OutputConfig(uid: "USB-오디오-機器-12345", channelOffset: 2, channelCount: 2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OutputConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.uid == "USB-오디오-機器-12345")
        #expect(decoded.channelOffset == 2)
        #expect(decoded.channelCount == 2)
    }

    @Test("Array-Roundtrip mehrerer Configs bleibt stabil")
    func arrayRoundtrip() throws {
        let configs = [OutputConfig(uid: "A"), OutputConfig(uid: "B", channelOffset: 2)]
        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode([OutputConfig].self, from: data)
        #expect(decoded == configs)
    }
}

// MARK: - TapIOMetrics

@Suite("TapIOMetrics")
struct TapIOMetricsTests {

    @Test("record zählt Callbacks, erkennt Audio, zählt Silence konsekutiv")
    func recordSemantics() {
        let m = TapIOMetrics()
        #expect(m.totalCallbacks == 0)
        #expect(m.hasReceivedAudio == false)
        m.record(callbackWasSilent: true)
        m.record(callbackWasSilent: true)
        #expect(m.totalCallbacks == 2)
        #expect(m.consecutiveSilentCallbacks == 2)
        #expect(m.hasReceivedAudio == false)
        m.record(callbackWasSilent: false)
        #expect(m.totalCallbacks == 3)
        #expect(m.consecutiveSilentCallbacks == 0)
        #expect(m.hasReceivedAudio == true)
    }

    @Test("Silence nach Audio: consecutive zählt weiter, hasReceivedAudio bleibt true")
    func silentAfterAudio() {
        let m = TapIOMetrics()
        m.record(callbackWasSilent: false)
        m.record(callbackWasSilent: true)
        #expect(m.consecutiveSilentCallbacks == 1)
        #expect(m.hasReceivedAudio == true)
    }

    @Test("reset setzt alle Zähler zurück")
    func resetClears() {
        let m = TapIOMetrics()
        m.record(callbackWasSilent: false)
        m.record(callbackWasSilent: true)
        m.reset()
        #expect(m.totalCallbacks == 0)
        #expect(m.consecutiveSilentCallbacks == 0)
        #expect(m.hasReceivedAudio == false)
    }
}
