//
//  WaveformPhaseTests.swift
//  AudioRouterKitTests
//
//  v4.0.1: Tests für die Teilpixel-Phase der WaveformBridge.
//  Laufen ohne Hardware, ohne CoreAudio und ohne echte Wartezeiten: die
//  Zeitquelle des Rings wird injiziert, jeder Zeitpunkt ist damit exakt
//  festgelegt statt von der Laufzeit der Testmaschine abzuhängen.
//

import Testing
import Foundation
@testable import AudioRouterKit

/// Steuerbare Zeitquelle in Sekunden.
///
/// `@unchecked Sendable` mit `NSLock`, weil die Bridge eine `@Sendable`-Closure
/// verlangt. Die Tests laufen einsträngig, das Lock kostet hier nichts.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double

    init(start: Double = 1000) { seconds = start }

    /// Aktueller Zeitpunkt, zum Einsetzen als Zeitquelle der Bridge.
    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    /// Rückt die Uhr um `delta` Sekunden vor.
    func advance(_ delta: Double) {
        lock.lock()
        seconds += delta
        lock.unlock()
    }
}

/// Erzeugt eine Bridge samt Uhr, beides zusammen, weil die Tests immer beide
/// brauchen.
private func makeBridge(start: Double = 1000) -> (WaveformBridge, FakeClock) {
    let clock = FakeClock(start: start)
    let bridge = WaveformBridge(clock: { clock.now })
    return (bridge, clock)
}

/// Schiebt `count` Paare im Abstand `interval` in den Ring und lässt die Uhr
/// mitlaufen. Der erste Push liegt auf dem aktuellen Zeitpunkt.
private func pushRegularly(_ bridge: WaveformBridge, clock: FakeClock,
                           count: Int, interval: Double) {
    for i in 0..<count {
        if i > 0 { clock.advance(interval) }
        bridge.push(min: -0.5, max: 0.5)
    }
}

@Suite("WaveformBridge Phase")
struct WaveformPhaseTests {

    // MARK: Ausgangszustände

    @Test("Ohne jeden Push ist die Phase 0")
    func phaseIsZeroWithoutAnyPush() {
        let (bridge, _) = makeBridge()
        #expect(bridge.frame(count: 8).phase == 0)
    }

    @Test("Nach genau einem Push ist die Phase 0, es fehlt der Abstand")
    func phaseIsZeroAfterSinglePush() {
        let (bridge, clock) = makeBridge()
        bridge.push(min: -0.2, max: 0.3)
        clock.advance(0.005)
        #expect(bridge.frame(count: 8).phase == 0)
    }

    @Test("reset löscht die Zeitmessung, die Phase fällt auf 0 zurück")
    func resetClearsTiming() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)
        clock.advance(0.005)
        #expect(bridge.frame(count: 8).phase > 0)

        bridge.reset()
        clock.advance(0.005)
        #expect(bridge.frame(count: 8).phase == 0)
    }

    // MARK: Regulärer Betrieb

    @Test("Halbe Strecke zwischen zwei Paaren ergibt Phase 0,5")
    func phaseIsHalfwayBetweenPushes() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 2, interval: 0.01)
        clock.advance(0.005)
        let phase = bridge.frame(count: 8).phase
        #expect(abs(phase - 0.5) < 0.0001)
    }

    @Test("Unmittelbar nach einem Push ist die Phase 0")
    func phaseIsZeroRightAfterPush() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)
        #expect(bridge.frame(count: 8).phase == 0)
    }

    @Test("Die Phase wächst monoton bis 1 und bleibt im Intervall")
    func phaseGrowsMonotonicallyAndStaysInUnitRange() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)

        var previous = -1.0
        for _ in 0..<20 {
            clock.advance(0.0005)
            let phase = bridge.frame(count: 8).phase
            #expect(phase >= 0)
            #expect(phase <= 1)
            #expect(phase > previous)
            previous = phase
        }
    }

    @Test("Ein ausgefallener Callback lässt die Kurve stehen statt vorauszulaufen")
    func phaseSaturatesAtOne() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)
        clock.advance(10.0)
        #expect(bridge.frame(count: 8).phase == 1)
    }

    // MARK: Ausreisser

    @Test("Eine lange Pause vergiftet die Glättung nicht")
    func longGapDoesNotPoisonSmoothing() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 10, interval: 0.01)

        // Pause wie nach einem Warm-Restart, danach läuft es normal weiter.
        clock.advance(2.0)
        bridge.push(min: -0.5, max: 0.5)

        clock.advance(0.005)
        let phase = bridge.frame(count: 8).phase
        // Wäre der 2-Sekunden-Abstand in die Glättung geflossen, läge die Phase
        // bei rund 0,025 und die Kurve kröche sekundenlang.
        #expect(abs(phase - 0.5) < 0.0001)
    }

    @Test("Ein absurd kurzer Abstand wird verworfen")
    func implausiblyShortGapIsIgnored() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 10, interval: 0.01)

        // Zwei Pushes ohne jeden Zeitversatz, etwa beim Warm-Restart.
        bridge.push(min: -0.5, max: 0.5)

        clock.advance(0.005)
        let phase = bridge.frame(count: 8).phase
        #expect(abs(phase - 0.5) < 0.0001)
    }

    @Test("Nach einer Pause zählt nur der neue Abstand, nicht die Lücke")
    func timestampAdvancesEvenWhenIntervalIsRejected() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 10, interval: 0.01)

        clock.advance(2.0)
        bridge.push(min: -0.5, max: 0.5)   // Abstand verworfen, Zeitpunkt gesetzt
        clock.advance(0.01)
        bridge.push(min: -0.5, max: 0.5)   // dieser Abstand ist wieder plausibel

        clock.advance(0.005)
        #expect(abs(bridge.frame(count: 8).phase - 0.5) < 0.0001)
    }

    // MARK: Nachführung

    @Test("Die Glättung folgt einer geänderten Callback-Rate")
    func smoothingFollowsChangedCallbackRate() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 20, interval: 0.01)

        // Puffergrösse verdoppelt: der Abstand springt von 10 ms auf 20 ms.
        for _ in 0..<60 {
            clock.advance(0.02)
            bridge.push(min: -0.5, max: 0.5)
        }

        clock.advance(0.01)
        let phase = bridge.frame(count: 8).phase
        // Beim alten Intervall wäre die Phase 1 (volle Spalte), beim neuen 0,5.
        #expect(abs(phase - 0.5) < 0.01)
    }

    // MARK: Samples und Phase aus einem Aufruf

    @Test("frame liefert die Paare chronologisch, oldest zuerst")
    func frameReturnsSamplesInChronologicalOrder() {
        let (bridge, clock) = makeBridge()
        for i in 1...3 {
            if i > 1 { clock.advance(0.01) }
            bridge.push(min: Float32(-i), max: Float32(i))
        }
        let samples = bridge.frame(count: 3).samples
        #expect(samples.count == 3)
        #expect(samples[0].max == 1)
        #expect(samples[1].max == 2)
        #expect(samples[2].max == 3)
    }

    @Test("count wird auf die Ringkapazität geklemmt")
    func frameClampsCountToCapacity() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)
        #expect(bridge.frame(count: 10_000).samples.count == WaveformBridge.capacity)
        #expect(bridge.frame(count: -5).samples.isEmpty)
    }

    @Test("Auch ein leeres Bild trägt eine gültige Phase")
    func emptyFrameStillCarriesPhase() {
        let (bridge, clock) = makeBridge()
        pushRegularly(bridge, clock: clock, count: 5, interval: 0.01)
        clock.advance(0.005)
        let frame = bridge.frame(count: 0)
        #expect(frame.samples.isEmpty)
        #expect(abs(frame.phase - 0.5) < 0.0001)
    }
}
