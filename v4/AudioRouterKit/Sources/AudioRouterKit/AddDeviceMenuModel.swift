//
//  AddDeviceMenuModel.swift
//  AudioRouterKit
//
//  4.1 Nachtrag (UI, Verbesserung V2 aus `docs/v4.1/25-add-device-liste.md`):
//  reine, testbare Auswahl- und Titellogik fuer das "Add device"-Menue.
//
//  Warum im Kit und nicht im App-Target: die "Add device"-View (`AddDeviceRow`)
//  liegt im App-Target und ist aus dem SPM-Test-Target nicht erreichbar. Die
//  Entscheidung, welche Geraete-Kanalpaare als Eintrag erscheinen, wie sie
//  heissen und welche davon bereits hinzugefuegt sind, soll testbar sein, damit
//  das Titelformat und die "schon hinzugefuegt"-Erkennung nicht unbemerkt
//  kaputtgehen. Gleiches Muster wie FooterTips, OutputLimits, SoloGain und
//  WaveEnergyMath: eine Quelle der Wahrheit hier, die View liest nur ab und ruft
//  weiter `EngineController.addOutputConfig` auf.
//
//  Keine Engine-Aenderung: Diese Datei entscheidet nur die Anzeige. Ob ein Klick
//  tatsaechlich eine Ausgabe anlegt, bleibt bei `addOutputConfig`/`OutputLimits`
//  (Duplikate dort weiterhin stummes No-Op).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation

/// Ein Eintrag im "Add device"-Menue: ein Geraet plus ein Kanalpaar.
///
/// Identitaet eines Ausgangs ist `uid` plus `channelOffset` (deckungsgleich mit
/// `DeviceSelectionRow.selectedConfig` und `EngineController.addOutputConfig`,
/// das Duplikate ueber uid und channelOffset erkennt). `channelCount` gehoert
/// bewusst NICHT zur Identitaet: alle aus dem Menue angelegten Configs tragen
/// den Default (Stereo), und die bestehende Duplikat-Erkennung ist ebenfalls
/// channelCount-agnostisch.
public struct AddDeviceMenuEntry: Hashable, Sendable {

    /// Angezeigter Titel. Format deckungsgleich mit dem bisherigen `AddDeviceRow`:
    /// nur der Geraetename bei Einzelpaar-Geraeten, sonst `name (ChX-Y)`.
    public let title: String

    /// Device-UID (stabil ueber Hot-Plug, `kAudioDevicePropertyDeviceUID`).
    public let uid: String

    /// Kanal-Offset des Paares (0 = Ch1-2, 2 = Ch3-4, …).
    public let channelOffset: Int

    /// `true`, wenn dieses Paar (uid plus channelOffset) bereits in den
    /// konfigurierten Ausgaengen steht. Die View zeigt es dann mit Haken und
    /// deaktiviert; ein Klick ist ohnehin ein stummes No-Op (`addOutputConfig`).
    public let isAdded: Bool

    public init(title: String, uid: String, channelOffset: Int, isAdded: Bool) {
        self.title = title
        self.uid = uid
        self.channelOffset = channelOffset
        self.isAdded = isAdded
    }
}

/// Reine Auswahl- und Titellogik fuer das "Add device"-Menue (V2).
///
/// Eingabe sind die aktuell verfuegbaren Ausgabegeraete und die konfigurierten
/// Ausgaenge. Ausgabe ist die Liste der Menue-Eintraege (ein Eintrag je
/// Kanalpaar je verfuegbarem Geraet, Reihenfolge wie `availableDevices`) plus
/// die Aussage, ob bereits alle moeglichen Eintraege hinzugefuegt sind.
///
/// Nicht verbundene, aber konfigurierte Ausgaenge erzeugen bewusst KEINEN
/// Eintrag: Das Menue listet nur, was man gerade hinzufuegen koennte, also die
/// Paare verfuegbarer Geraete. Ein konfigurierter Ausgang ohne verfuegbares
/// Geraet taucht hier nicht auf (er bleibt als Card in der Liste sichtbar und
/// entfernbar, das ist Sache der View, nicht dieses Modells).
public enum AddDeviceMenuModel {

    /// Anzahl Kanalpaare eines Geraets. Deckungsgleich mit `AddDeviceRow` und
    /// `DeviceSelectionRow`: `max(1, channelCount / 2)`. Damit hat ein Mono- oder
    /// Einzelpaar-Geraet (channelCount 0, 1 oder 2) genau ein Paar, und ungerade
    /// Kanalzahlen runden wie bisher ab (channelCount 3 -> 1 Paar).
    public static func pairCount(channelCount: Int) -> Int {
        max(1, channelCount / 2)
    }

    /// Titel eines Eintrags. Format EXAKT wie bisher in `AddDeviceRow`:
    /// - Einzelpaar-Geraet (`pairCount == 1`): nur der Geraetename, ohne Zusatz.
    /// - Mehrpaar-Geraet: `name (ChX-Y)` mit X = offset+1, Y = offset+2.
    ///
    /// - Parameters:
    ///   - name: Geraetename.
    ///   - channelOffset: Offset des Paares.
    ///   - pairCount: Zahl der Paare (steuert, ob der `(ChX-Y)`-Zusatz erscheint).
    public static func title(name: String, channelOffset: Int, pairCount: Int) -> String {
        if pairCount == 1 {
            return name
        }
        return "\(name) (Ch\(channelOffset + 1)-\(channelOffset + 2))"
    }

    /// Baut die Eintragsliste fuer das Menue.
    ///
    /// - Parameters:
    ///   - availableDevices: verfuegbare Ausgabegeraete in Anzeige-Reihenfolge.
    ///   - configuredOutputs: bereits konfigurierte Ausgaenge (uid, channelOffset).
    ///     `channelCount` spielt fuer die Identitaet bewusst keine Rolle.
    /// - Returns: ein Eintrag je Kanalpaar je verfuegbarem Geraet, Reihenfolge
    ///   wie `availableDevices` und innerhalb eines Geraets nach Offset
    ///   aufsteigend. Reihenfolge ist stabil (bereits hinzugefuegte Eintraege
    ///   wandern nicht, sie werden nur markiert).
    public static func entries(
        availableDevices: [(uid: String, name: String, channelCount: Int)],
        configuredOutputs: [(uid: String, channelOffset: Int)]
    ) -> [AddDeviceMenuEntry] {
        // Nachschlag-Menge fuer "schon hinzugefuegt" in O(1) je Paar. Identitaet
        // ist (uid, channelOffset); gleiche Geraetenamen mit verschiedener uid
        // sind damit verschiedene Schluessel und werden nicht verwechselt.
        var added = Set<String>()
        added.reserveCapacity(configuredOutputs.count)
        for out in configuredOutputs {
            added.insert(key(uid: out.uid, channelOffset: out.channelOffset))
        }

        var result: [AddDeviceMenuEntry] = []
        for device in availableDevices {
            let pairs = pairCount(channelCount: device.channelCount)
            for pair in 0..<pairs {
                let offset = pair * 2
                let isAdded = added.contains(key(uid: device.uid, channelOffset: offset))
                result.append(AddDeviceMenuEntry(
                    title: title(name: device.name, channelOffset: offset, pairCount: pairs),
                    uid: device.uid,
                    channelOffset: offset,
                    isAdded: isAdded))
            }
        }
        return result
    }

    /// `true`, wenn mindestens ein Eintrag existiert und ALLE Eintraege bereits
    /// hinzugefuegt sind. Die View zeigt dann statt lauter deaktivierter Zeilen
    /// einen einzigen deaktivierten Hinweis "All outputs are added", damit das
    /// Menue nicht leer oder nutzlos wirkt.
    ///
    /// Bei komplett leerer Liste (kein verfuegbares Geraet) ist das Ergebnis
    /// `false`: dann gibt es nichts hinzuzufuegen UND nichts, das "schon alles"
    /// sagen koennte; die View zeigt in dem Fall gar nichts Besonderes.
    public static func allAdded(_ entries: [AddDeviceMenuEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0.isAdded }
    }

    /// Englischer, neutraler Hinweistext fuer den Fall, dass alle Paare aller
    /// verfuegbaren Geraete schon hinzugefuegt sind. Ein Satz, kein
    /// Gedankenstrich, kein Doppelbindestrich, kein Superlativ.
    public static let allAddedNotice = "All outputs are added."

    // MARK: - Intern

    /// Composite-Schluessel fuer die "schon hinzugefuegt"-Menge. Gleiches Muster
    /// wie `EngineController.soloedKeys` ("<uid>:<channelOffset>").
    private static func key(uid: String, channelOffset: Int) -> String {
        "\(uid):\(channelOffset)"
    }
}
