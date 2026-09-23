//
//  PanelVisibility.swift
//  AudioRouterNow4
//
//  v4.0.1 (CASE-003): Sichtbarkeitszustand des MenuBarExtra-Panels.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import AppKit
import SwiftUI

/// Verfolgt, ob das ``MenuBarExtra``-Panel gerade sichtbar ist.
///
/// Hintergrund (CASE-003): SwiftUI baut den View-Baum eines
/// `MenuBarExtra(.window)`-Panels beim Schliessen NICHT ab. Ein
/// `TimelineView(.animation)` und ein `.task`-Poll laufen deshalb auch dann
/// weiter, wenn niemand hinsieht: unnötige Last und, schlimmer, ein
/// `@Published`-Update mitten im Fenster-Teardown.
///
/// Diese Klasse liefert das fehlende Sichtbarkeitssignal, damit
/// ``WaveHeaderView`` ihre Zeitachse anhalten und ``MenuBarView`` ihren
/// Geräte-Poll aussetzen kann.
///
/// ## Warum der Key-Status des echten Fensters die Quelle ist
/// Der SwiftUI-Lebenszyklus taugt hier nicht als Signalquelle. Genau weil der
/// View-Baum nicht abgebaut wird, feuert `onAppear` nur beim allerersten
/// Erscheinen und `onDisappear` gar nicht. Ein Zustand, der daran hängt, bliebe
/// ab der zweiten Öffnung dauerhaft auf `false` stehen: die Welle wäre tot,
/// obwohl das Panel offen ist.
///
/// Deshalb hängt der Zustand am echten `NSWindow` des Panels, ermittelt über
/// ``PanelWindowProbe``. Beobachtet werden beide Richtungen, gefiltert auf genau
/// dieses eine Fensterobjekt:
///
/// | Richtung | Signal |
/// |----------|--------|
/// | Auf | `NSWindow.didBecomeKeyNotification` |
/// | Ab | `NSWindow.didResignKeyNotification` |
///
/// Key-Status statt `window.isVisible`, weil `orderOut()` (der Weg, auf dem
/// MenuBarExtra sein Panel schliesst) den Key-Status zuverlässig entzieht und
/// dabei ein Notification-Paar liefert. `isVisible` hat kein solches Paar und
/// müsste per KVO abgefragt werden, wofür `NSWindow` keine dokumentierte Zusage
/// gibt.
///
/// Der Filter auf das Panel-Fenster ist zugleich der Fix für den zweiten
/// Fehler der ersten Fassung: ein ungefilterter Observer reagierte auf JEDES
/// Fenster, also auch auf den `NSAlert` aus
/// ``EngineController/requestLaunchAtLoginEnable()``. Dieser Aufbau heilt sich
/// dort selbst: der Alert nimmt den Key-Status (die Welle pausiert kurz), beim
/// Schliessen des Alerts wird das Panel wieder Key und der Zustand kehrt zurück.
@MainActor
final class PanelVisibility: ObservableObject {

    /// `true`, solange das Panel den Key-Status hält.
    ///
    /// Startwert im Normalbetrieb `false`: beim App-Start ist das Panel zu.
    @Published private(set) var isVisible: Bool

    /// Das echte Panel-Fenster, sobald ``attach(to:)`` es gemeldet bekommen hat.
    /// Schwach, weil das Fenster AppKit gehört und diese Klasse es nicht am
    /// Leben halten soll.
    private weak var panelWindow: NSWindow?

    /// `nonisolated(unsafe)`, weil `deinit` einer MainActor-isolierten Klasse
    /// selbst nonisolated ist und sonst nicht auf die (nicht-Sendable) Tokens
    /// zugreifen dürfte. Unbedenklich: geschrieben wird ausschliesslich auf dem
    /// MainActor (``attach(to:)``), gelesen im `deinit`, der erst läuft, wenn
    /// niemand mehr eine Referenz hält. Ein Fenster für nebenläufigen Zugriff
    /// gibt es damit nicht.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// - Parameter initiallyVisible: nur für SwiftUI-Previews gedacht. Dort gibt
    ///   es kein Panel-Fenster, das Key werden könnte, und ohne diesen Schalter
    ///   zeigte jede Preview des Wellen-Headers ein Standbild.
    init(initiallyVisible: Bool = false) {
        isVisible = initiallyVisible
    }

    deinit {
        // Ohne explizites Abmelden bliebe ein Observer auf einer toten Instanz
        // zurück.
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// Bindet den Sichtbarkeitszustand an das echte Panel-Fenster.
    ///
    /// Wird von ``PanelWindowProbe`` gerufen, sobald AppKit die Sonde in eine
    /// Fensterhierarchie eingehängt hat.
    ///
    /// - Parameter window: das `NSWindow`, in dem das Panel lebt.
    func attach(to window: NSWindow) {
        // Mehrfachmeldungen sind normal: `viewDidMoveToWindow` feuert auch,
        // wenn AppKit die Sonde innerhalb derselben Hierarchie umhängt.
        guard window !== panelWindow else { return }

        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        panelWindow = window

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter-Closures sind nonisolated, auch bei queue: .main.
            // Der Hop über Task ist der einzige Weg, der unter
            // SWIFT_STRICT_CONCURRENCY=complete ohne Zusicherung auskommt.
            Task { @MainActor [weak self] in
                self?.isVisible = true
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isVisible = false
            }
        })

        // Anfangsabgleich: wurde das Fenster bereits Key, BEVOR die Sonde in der
        // Hierarchie hing, ist die zugehörige Notification verpasst worden.
        //
        // Bewusst verzögert statt direkt: `attach` läuft aus einem
        // AppKit-Layout-Callback, der innerhalb eines SwiftUI-Update-Durchlaufs
        // liegen kann. Ein `@Published`-Schreibzugriff mittendrin ist genau die
        // Sorte Zustandsänderung, die SwiftUI moniert.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isVisible = self.panelWindow?.isKeyWindow ?? false
        }
    }

    /// Frühes Aufwärts-Signal aus `MenuBarView.onAppear`.
    ///
    /// Redundant zu `didBecomeKey` und bewusst behalten. Es greift beim
    /// allerersten Erscheinen, bevor die Sonde ihr Fenster kennt, und deckt den
    /// Fall ab, dass das Panel wider Erwarten nie Key wird. Die Asymmetrie der
    /// Risiken gibt den Ausschlag: ein fälschlich stehengebliebenes `true`
    /// entspricht dem Verhalten von 4.0.0 und wird beim ersten Key-Wechsel
    /// korrigiert, ein fälschlich stehengebliebenes `false` hingegen liesse
    /// Welle und Geräte-Poll dauerhaft tot.
    func panelDidAppear() {
        isVisible = true
    }
}

/// Unsichtbare Sonde, die das `NSWindow` ihrer Umgebung nach oben meldet.
///
/// Der kanonische AppKit-Weg, an das Fenster einer SwiftUI-Hierarchie zu
/// kommen. `viewDidMoveToWindow()` ist die einzige Stelle, die unabhängig davon
/// funktioniert, ob SwiftUI den View-Baum neu aufbaut oder (wie bei
/// `MenuBarExtra(.window)`) stehen lässt. Kein privates API.
struct PanelWindowProbe: NSViewRepresentable {

    /// Gerufen, sobald die Sonde in einer Fensterhierarchie hängt.
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    /// `NSView` ohne eigene Darstellung, einzige Aufgabe ist der Fensterzugriff.
    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Beim Aushängen ist `window` nil. Das ist kein Sichtbarkeitssignal,
            // der Key-Status des zuvor gemeldeten Fensters bleibt massgeblich.
            guard let window = self.window else { return }
            onWindow?(window)
        }
    }
}
