//
//  WaveClock.swift
//  AudioRouterNow4
//
//  v4.0.1 (CASE-003): Taktgeber für den Oszilloskop-Header.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation

/// Zählt hoch, damit SwiftUI den Wellen-Canvas neu zeichnet.
///
/// ## Warum es dieses Objekt gibt
/// Bis 4.0.1 kam der Takt aus einem `TimelineView(.animation)`, das sich als
/// Beobachter am Display-Cycle des Fensters registriert. Genau dort steht der
/// in CASE-003 gemeldete Absturz (`__NSWindowGetDisplayCycleObserver`). Da der
/// View-Baum eines `MenuBarExtra(.window)`-Panels beim Schliessen nicht
/// abgebaut wird, lief diese Zeitachse ausserdem unbegrenzt weiter.
///
/// Der Takt kommt jetzt aus ``EngineController/startWavePoll()``, also aus der
/// Audio-Seite. Der zugehörige Task existiert nur bei aktivem Routing und wird
/// in `stopRouting()` abgebrochen, womit die Animation im Leerlauf von selbst
/// ruht. Kein Display-Cycle-Beobachter, keine Fenstererkennung.
///
/// ## Warum getrennt vom Controller
/// Ein `@Published` am ``EngineController`` hätte denselben Zweck erfüllt, aber
/// jede Änderung dort lässt SwiftUI den gesamten Panel-Baum neu bewerten:
/// Geräte-Karten, Pegel, Regler, Fusszeile. Bei 60 Hz ist das um ein Vielfaches
/// mehr Arbeit als nötig, neu zu zeichnen ist nur der Canvas. An diesem Objekt
/// hängt deshalb ausschliesslich ``WaveHeaderView``.
@MainActor
final class WaveClock: ObservableObject {

    /// Läuft bei jedem Takt um eins weiter. Der Wert selbst wird nicht
    /// ausgewertet, allein seine Änderung löst das Neuzeichnen aus.
    @Published private(set) var tick: UInt32 = 0

    /// Überlauf ist unkritisch und deshalb mit `&+` ausdrücklich erlaubt:
    /// bei 60 Hz dauert er gut zwei Jahre Dauerbetrieb, und danach zählt der
    /// Wert einfach bei null weiter. Auf die Änderung kommt es an, nicht auf
    /// die Zahl.
    func advance() {
        tick &+= 1
    }
}

/// Geglätteter Normierungsfaktor der Wellenform, über Bilder hinweg gehalten.
///
/// ## Warum das nötig ist
/// Der Canvas normalisiert die Kurve auf die lauteste Stelle des sichtbaren
/// Ausschnitts, damit auch leise Passagen die Höhe ausnutzen. Der Bezugswert
/// wurde bis 4.0.1 bei JEDEM Bild neu bestimmt. Wandert ein lauter Schlag in
/// den Ausschnitt hinein oder rechts wieder hinaus, springt er, und mit ihm
/// springt die Höhe der gesamten sichtbaren Kurve. Das wirkt als Atmen oder
/// Zucken und wird leicht mit Ruckeln verwechselt.
///
/// Die Glättung ist derselbe Gedanke wie beim VU-Meter in
/// ``EngineController``: schneller Anstieg, langsamer Abfall. Der Anstieg muss
/// schnell sein, damit ein plötzlicher Transient nicht oben abgeschnitten wird.
/// Der Abfall darf träge sein, damit die Kurve nach einer lauten Stelle nicht
/// sofort wieder aufgeblasen wird.
///
/// Referenztyp, weil der Wert von Bild zu Bild fortgeschrieben werden muss und
/// der Zeichenblock des `Canvas` eine View-Struct nicht verändern kann. Das
/// Schreiben löst bewusst KEINE Neuzeichnung aus, sonst entstünde eine Schleife.
@MainActor
final class WaveNormalizer {

    /// Aktueller Bezugswert. Start bei 0, der erste Messwert wird direkt
    /// übernommen, damit die Kurve nicht sichtbar einschwingt.
    private var value: Float32 = 0

    /// Glättet den Bezugswert und liefert ihn zurück.
    ///
    /// - Parameter target: der am aktuellen Bild gemessene Spitzenwert.
    /// - Returns: der zu verwendende Normierungsfaktor.
    func smoothed(towards target: Float32) -> Float32 {
        guard target.isFinite else { return value }
        guard value > 0 else {
            value = target
            return value
        }
        // Anstieg 0.5, Abfall 0.04. Der Abfall entspricht bei 60 Bildern je
        // Sekunde einer Zeitkonstante von rund 0.4 s: lang genug, dass das
        // Hinauswandern eines einzelnen Schlags nicht auffällt, kurz genug,
        // dass ein dauerhaft leiser werdendes Signal nicht minutenlang
        // zusammengedrückt bleibt.
        let alpha: Float32 = target > value ? 0.5 : 0.04
        let next = alpha * target + (1 - alpha) * value
        // Unter die Stille-Schwelle darf der Wert sauber auf 0 fallen, sonst
        // bliebe ein Rest-Epsilon hängen und die Stille-Erkennung im Canvas
        // würde nie greifen.
        value = next < 0.001 ? 0 : next
        return value
    }

    /// Setzt den Bezugswert zurück, etwa beim Stoppen des Routings.
    func reset() {
        value = 0
    }
}
