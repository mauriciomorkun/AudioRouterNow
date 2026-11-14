import Foundation

/// Einzige Quelle der Wahrheit fuer die Slot-Obergrenze der Engine (NT-D1).
/// Kapazitaet der Bruecken `SlotGains` und `PeakMeters`; die Kosten haengen an der
/// tatsaechlich genutzten Slotzahl, nicht an dieser Konstante.
public enum OutputLimits {

    /// Obergrenze gleichzeitiger Slots (Brueckenkapazitaet).
    public static let maxSlots = 256

    /// Obergrenze konfigurierter Ausgaben. Ein Slot bleibt fuer den synthetischen
    /// Default-Slot reserviert (`orderedSlotConfigs` haengt hoechstens einen an).
    public static let maxConfiguredOutputs = maxSlots - 1

    public enum AddDecision: Equatable, Sendable {
        case allowed
        case duplicate
        case limitReached(max: Int)
    }

    /// Entscheidung beim Hinzufuegen einer Ausgabe. Duplikate bleiben stumme No-Ops
    /// (Bestandsverhalten von `addOutputConfig`), das Limit wird sichtbar gemeldet.
    public static func addDecision(currentCount: Int, alreadyConfigured: Bool) -> AddDecision {
        if alreadyConfigured { return .duplicate }
        if currentCount >= maxConfiguredOutputs { return .limitReached(max: maxConfiguredOutputs) }
        return .allowed
    }

    public static func limitMessage(max: Int) -> String {
        "Output limit reached: AudioRouterNow can route to \(max) outputs at once. Remove an output to add another."
    }

    /// Pruefung fuer Start und Rebuild (die Persistenz kann mehr Eintraege enthalten).
    public static func validateOutputCount(_ count: Int) throws {
        if count > maxConfiguredOutputs {
            throw RouterError.tooManyOutputs(count: count, max: maxConfiguredOutputs)
        }
    }
}
