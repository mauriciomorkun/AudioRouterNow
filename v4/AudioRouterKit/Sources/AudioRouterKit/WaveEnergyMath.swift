import Foundation

/// W2 (NT-D4, docs/v4.1/14-plan-nachtrag.md): Solo-neutrale lineare Wellen-Energie.
/// Reine Arithmetik, kein CoreAudio. `soloedKeys` ist bewusst KEIN Parameter: Solo kann
/// die Wellenhöhe so nicht beeinflussen. Die Meter der Karten nutzen weiter
/// `SoloGain.effective`.
public enum WaveEnergyMath {

    /// - Parameters:
    ///   - slotPeaks: IOProc-Peaks (L, R) je Slot, Reihenfolge wie `keys`.
    ///   - keys: Slot-Schlüssel "<uid>:<channelOffset>" in Slot-Reihenfolge.
    ///   - deviceGains: gespeicherte Nutzer-Gains [0...1] (Solo schreibt sie nie).
    /// - Returns: Mittelwert über ALLE Slots, auf 1.0 geklemmt; 0 bei leerer Eingabe.
    public static func soloNeutralLinear(
        slotPeaks: [(l: Float32, r: Float32)],
        keys: [String],
        deviceGains: [String: Double]
    ) -> Float32 {
        let n = min(slotPeaks.count, keys.count)
        guard n > 0 else { return 0 }
        var sum: Float32 = 0
        for i in 0..<n {
            let g = Float32(deviceGains[keys[i]] ?? 1.0)
            sum += (slotPeaks[i].l + slotPeaks[i].r) * 0.5 * g
        }
        return min(1, sum / Float32(n))
    }
}
