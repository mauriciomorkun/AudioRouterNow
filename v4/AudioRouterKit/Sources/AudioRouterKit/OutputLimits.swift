import Foundation

/// Einzige Quelle der Wahrheit für die Slot-Obergrenze der Engine (NT-D1).
/// Kapazität der Brücken `SlotGains` und `PeakMeters`; die Kosten hängen an der
/// tatsächlich genutzten Slotzahl, nicht an dieser Konstante.
public enum OutputLimits {

    /// Obergrenze gleichzeitiger Slots (Brückenkapazität).
    public static let maxSlots = 256

    /// Obergrenze konfigurierter Ausgaben. Ein Slot bleibt für den synthetischen
    /// Default-Slot reserviert (`orderedSlotConfigs` hängt höchstens einen an).
    public static let maxConfiguredOutputs = maxSlots - 1

    public enum AddDecision: Equatable, Sendable {
        case allowed
        case duplicate
        case limitReached(max: Int)
    }

    /// Entscheidung beim Hinzufügen einer Ausgabe. Duplikate bleiben stumme No-Ops
    /// (Bestandsverhalten von `addOutputConfig`), das Limit wird sichtbar gemeldet.
    public static func addDecision(currentCount: Int, alreadyConfigured: Bool) -> AddDecision {
        if alreadyConfigured { return .duplicate }
        if currentCount >= maxConfiguredOutputs { return .limitReached(max: maxConfiguredOutputs) }
        return .allowed
    }

    public static func limitMessage(max: Int) -> String {
        "Output limit reached: AudioRouterNow can route to \(max) outputs at once. Remove an output to add another."
    }

    /// Prüfung für Start und Rebuild (die Persistenz kann mehr Einträge enthalten).
    public static func validateOutputCount(_ count: Int) throws {
        if count > maxConfiguredOutputs {
            throw RouterError.tooManyOutputs(count: count, max: maxConfiguredOutputs)
        }
    }
}
