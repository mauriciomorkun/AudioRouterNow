//
//  WaveformGeometryTests.swift
//  AudioRouterKitTests
//
//  v4.0.1 (CASE-003): Regressionstests für die Waveform-Härtung.
//  Laufen ohne Hardware und ohne CoreAudio-Calls.
//

import Testing
import Foundation
@testable import AudioRouterKit

@Suite("WaveformGeometry")
struct WaveformGeometryTests {

    // MARK: sanitize

    @Test("Endliche Werte bleiben unverändert")
    func sanitizeKeepsFiniteValues() {
        #expect(WaveformGeometry.sanitize(Float32(0.5)) == 0.5)
        #expect(WaveformGeometry.sanitize(Float32(-0.5)) == -0.5)
        #expect(WaveformGeometry.sanitize(Float32(0)) == 0)
    }

    @Test("Nicht-endliche Werte werden zu 0")
    func sanitizeReplacesNonFiniteValues() {
        #expect(WaveformGeometry.sanitize(Float32.infinity) == 0)
        #expect(WaveformGeometry.sanitize(-Float32.infinity) == 0)
        #expect(WaveformGeometry.sanitize(Float32.nan) == 0)
    }

    @Test("Werte über Vollaussteuerung werden geklemmt")
    func sanitizeClampsOutOfRangeValues() {
        #expect(WaveformGeometry.sanitize(Float32(1.8)) == 1)
        #expect(WaveformGeometry.sanitize(Float32(-1.8)) == -1)
    }

    @Test("Paar-Variante härtet beide Komponenten")
    func sanitizePairHardensBothComponents() {
        let result = WaveformGeometry.sanitize((min: -Float32.infinity, max: Float32(4.0)))
        #expect(result.min == 0)
        #expect(result.max == 1)
    }

    // MARK: normalizationAmplitude

    @Test("Normale Samples liefern die grösste Absolut-Amplitude")
    func amplitudeFindsLargestMagnitude() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: -0.2, max: 0.3),
            (min: -0.7, max: 0.1),
            (min: -0.1, max: 0.4)
        ]
        #expect(WaveformGeometry.normalizationAmplitude(samples) == 0.7)
    }

    @Test("+Infinity in max vergiftet die Amplitude nicht")
    func amplitudeIgnoresPositiveInfinityInMax() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: -0.25, max: Float32.infinity),
            (min: -0.1, max: 0.4)
        ]
        let amplitude = WaveformGeometry.normalizationAmplitude(samples)
        #expect(amplitude.isFinite)
        #expect(amplitude == 0.4)
    }

    @Test("-Infinity in min vergiftet die Amplitude nicht")
    func amplitudeIgnoresNegativeInfinityInMin() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: -Float32.infinity, max: 0.2),
            (min: -0.6, max: 0.1)
        ]
        let amplitude = WaveformGeometry.normalizationAmplitude(samples)
        #expect(amplitude.isFinite)
        #expect(amplitude == 0.6)
    }

    @Test("NaN in beiden Komponenten wird übersprungen")
    func amplitudeIgnoresNaNInBothComponents() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: Float32.nan, max: Float32.nan),
            (min: -0.3, max: 0.15)
        ]
        let amplitude = WaveformGeometry.normalizationAmplitude(samples)
        #expect(amplitude.isFinite)
        #expect(amplitude == 0.3)
    }

    @Test("Durchgängig nicht-endliche Eingabe liefert endliche 0")
    func amplitudeIsZeroWhenEverythingIsNonFinite() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: -Float32.infinity, max: Float32.infinity),
            (min: Float32.nan, max: Float32.nan)
        ]
        let amplitude = WaveformGeometry.normalizationAmplitude(samples)
        #expect(amplitude.isFinite)
        #expect(amplitude == 0)
    }

    @Test("Stille (alles 0) liefert 0")
    func amplitudeIsZeroForSilence() {
        let samples: [(min: Float32, max: Float32)] = [
            (min: 0, max: 0),
            (min: 0, max: 0)
        ]
        #expect(WaveformGeometry.normalizationAmplitude(samples) == 0)
    }

    @Test("Werte über 1 werden hier NICHT geklemmt, das ist sanitize-Aufgabe")
    func amplitudeReportsMagnitudeAboveUnity() {
        let samples: [(min: Float32, max: Float32)] = [(min: -2.5, max: 1.5)]
        #expect(WaveformGeometry.normalizationAmplitude(samples) == 2.5)
    }

    @Test("Leeres Array liefert 0 statt abzustürzen")
    func amplitudeHandlesEmptyInput() {
        let amplitude = WaveformGeometry.normalizationAmplitude([])
        #expect(amplitude.isFinite)
        #expect(amplitude == 0)
    }

    // MARK: Zusammenspiel

    @Test("sanitize vor normalizationAmplitude ergibt eine Amplitude in [0, 1]")
    func sanitizeThenAmplitudeStaysInUnitRange() {
        let raw: [(min: Float32, max: Float32)] = [
            (min: -Float32.infinity, max: 3.0),
            (min: Float32.nan, max: 0.2),
            (min: -0.9, max: 0.4)
        ]
        let cleaned = raw.map(WaveformGeometry.sanitize)
        let amplitude = WaveformGeometry.normalizationAmplitude(cleaned)
        #expect(amplitude.isFinite)
        #expect(amplitude == 1.0)
    }
}
