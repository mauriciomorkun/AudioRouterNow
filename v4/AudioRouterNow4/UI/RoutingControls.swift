//
//  RoutingControls.swift
//  AudioRouterNow4
//
//  Phase 3 (UI-Layer, Konzept 4B): Steuer-Elemente, pulsierender Status-Dot,
//  Mint-Spinner, globaler Volume-Slider, State-Button (Start/Verbinde/Stop)
//  und Footer-Zeile (Launch-at-Login · Beenden).
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import SwiftUI
import AudioRouterKit

// MARK: - PulsingDot

/// Status-Dot mit sanftem Puls (scale + opacity) im aktiven/startenden Zustand.
struct PulsingDot: View {
    let color: Color
    var pulsing: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && animate ? 1.35 : 1.0)
            .opacity(pulsing && animate ? 0.55 : 1.0)
            .animation(pulsing
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                : .default, value: animate)
            .onAppear { animate = pulsing }
            .onChange(of: pulsing) { _, newValue in animate = newValue }
    }
}

// MARK: - MintSpinner

/// Kleiner mint-getönter Spinner für STARTING-Zustände (Geräteliste / Button).
struct MintSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ARNColor.accent)
            .scaleEffect(0.7)
            .frame(width: 12, height: 12)
    }
}

// MARK: - VolumeRow

/// Globaler System-Volume-Slider (nur im ACTIVE-Zustand sichtbar).
/// Extrahiert aus dem bisherigen `volumeSection` der MenuBarView.
struct VolumeRow: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        HStack {
            Image(systemName: controller.isMuted ? "speaker.slash.fill" : volumeIconName)
                .font(.caption)
                .foregroundStyle(controller.isMuted ? .secondary : .primary)
                .frame(width: 16)
            Slider(
                value: Binding(
                    get: { controller.currentVolume },
                    set: { controller.setSystemVolume($0) }
                ),
                in: 0...1
            )
            Text(controller.isMuted ? "Mute" : "\(Int(controller.currentVolume * 100))%")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var volumeIconName: String {
        let v = controller.currentVolume
        if v > 0.66 { return "speaker.wave.3.fill" }
        if v > 0.33 { return "speaker.wave.2.fill" }
        if v > 0.01 { return "speaker.wave.1.fill" }
        return "speaker.fill"
    }
}

// MARK: - RoutingButton

/// Primärer State-Button: Start (idle/error) · Verbinde… (starting) · Stop (active).
struct RoutingButton: View {
    @EnvironmentObject var controller: EngineController
    let state: ARNUIState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func action() {
        switch state {
        case .active:        controller.stopRouting()
        case .idle, .error:  controller.startRouting()
        case .starting:      break
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .idle, .error: Image(systemName: "play.fill")
        case .starting:     MintSpinner()
        case .active:       Image(systemName: "stop.fill")
        }
    }

    private var title: String {
        switch state {
        case .idle, .error: return "Start Routing"
        case .starting:     return "Connecting…"
        case .active:       return "Stop Routing"
        }
    }

    private var disabled: Bool {
        state == .starting || (controller.outputConfigs.isEmpty && !state.isActive)
    }

    private var background: AnyShapeStyle {
        switch state {
        case .idle, .error: return AnyShapeStyle(ARNColor.accent)
        case .starting:     return AnyShapeStyle(.ultraThinMaterial)
        case .active:       return AnyShapeStyle(Color(white: 0.12))
        }
    }

    private var foreground: Color {
        switch state {
        case .idle, .error: return .black
        default:            return ARNColor.accent
        }
    }

    private var borderColor: Color {
        state == .active ? ARNColor.accent.opacity(0.6) : .clear
    }
}

// MARK: - FooterRow

/// Welches Footer-Element gerade gehovert wird. Steuert die eigene Hover-Bubble.
///
/// Variante C3: Die System-Tooltips (`.help`, NSToolTip) sind in einem nicht
/// aktivierenden `MenuBarExtra(.window)`-Panel unzuverlaessig (an das Key-Window
/// gebunden, ca. 1 s Verzoegerung) und koennen ueber den Panel-Rand ragen und
/// abgeschnitten werden. Deshalb eine eigene SwiftUI-Bubble im Fenster, die von
/// NSToolTip unabhaengig ist. Siehe `docs/v4.1/23-ui-start-button-oben.md`.
enum FooterTip: Equatable {
    case support
    case lock
    case exclusive
    case bug
    case quit
    case launchAtLogin

    /// Sachlicher Erklaerungstext (Quelle: `AudioRouterKit.FooterTips`, getestet).
    var text: String {
        switch self {
        case .support:       return FooterTips.support
        case .lock:          return FooterTips.lock
        case .exclusive:     return FooterTips.exclusive
        case .bug:           return FooterTips.bug
        case .quit:          return FooterTips.quit
        case .launchAtLogin: return FooterTips.launchAtLogin
        }
    }
}

/// Meldet die horizontale Mitte des gehoverten Footer-Elements im Koordinatenraum
/// der Footer-Reihe, damit die Bubble darueber zentriert und am Rand geclampt
/// werden kann.
private struct FooterTipAnchorKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

struct FooterRow: View {
    @EnvironmentObject var controller: EngineController
    @EnvironmentObject private var store: TipJarStore
    @State private var showTipJar = false

    // C3: Die Footer-Pille ist entfernt (der grosse Knopf oben ist der einzige
    // Start/Stop-Knopf). `FooterRow` braucht die UI-Phase daher nicht mehr.

    /// Aktuell gehovertes Element (oder `nil`). Steuert die Bubble.
    @State private var hoveredTip: FooterTip?
    /// Horizontale Mitte des gehoverten Elements in der Footer-Breite.
    @State private var anchorX: CGFloat?
    /// Gesamtbreite der Footer-Reihe (fuer das Clamping der Bubble).
    @State private var rowWidth: CGFloat = 0

    /// Verzoegerung, bevor die Bubble erscheint (gegen Flimmern beim Durchfahren).
    private let hoverDelay: TimeInterval = 0.35
    /// Geschaetzte Bubble-Breite fuer das Clamping (die Bubble selbst ist
    /// `fixedSize`, dieser Wert dient nur der Rand-Berechnung).
    private let bubbleWidth: CGFloat = 220
    private let edgePadding: CGFloat = 8

    var body: some View {
        VStack(spacing: 8) {
            if showTipJar {
                TipJarView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity))
            }

            // ── Eine Reihe (C3): Launch at Login, Support-Pille, Icon-Gruppe, Quit ─
            // Variante C3: Die kompakte Start/Stop-Pille ist entfernt (der grosse
            // Knopf oben ist der einzige Start/Stop-Knopf). Dadurch wird die zweite
            // Reihe frei; alle sekundaeren Elemente liegen jetzt in einer ruhigen
            // Reihe. Keine weitere Funktion entfernt, nichts versteckt. Launch at
            // Login bleibt sichtbar und als Checkbox bedienbar (Guideline
            // 2.4.5(iii)). Support ist als Mint-Pille mit Wort aufgewertet (S1).
            footerControls
                .coordinateSpace(name: Self.coordinateSpace)
                .overlay(alignment: .top) { hoverBubble }
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { rowWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in rowWidth = w }
                    }
                )
                .onPreferenceChange(FooterTipAnchorKey.self) { anchorX = $0 }
        }
        .onDisappear { clearHover() }   // Panel geschlossen: Bubble zuruecksetzen
    }

    // MARK: Reihe

    @ViewBuilder private var footerControls: some View {
        HStack(spacing: 10) {
            // Launch at Login (Checkbox, sichtbar, Guideline 2.4.5(iii)).
            // `lineLimit(1)` plus `fixedSize(horizontal:)` verhindern, dass das Label
            // bei groesserer Schrift zweizeilig umbricht (Audit C3, Punkt D). Die
            // Reihe bleibt einzeilig; wenn der Platz sehr eng wird, schrumpft
            // zuerst der flexible `Spacer`, erst danach wird das Label skaliert
            // (`minimumScaleFactor`), bevor etwas abgeschnitten wuerde. Die Checkbox
            // bleibt sichtbar und bedienbar.
            tracked(.launchAtLogin, Toggle("Launch at Login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { newValue in
                    if newValue {
                        controller.requestLaunchAtLoginEnable()  // Consent-Gate
                    } else {
                        controller.launchAtLogin = false  // Deaktivieren immer direkt
                    }
                }
            ))
                .toggleStyle(.checkbox).font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false))

            // Support-Pille (S1): Herz plus Wort, dezente Mint-Fuellung.
            supportPill

            Spacer()

            // Icon-Gruppe: Lock, Exclusive, Bug.
            lockButton
            exclusiveButton
            bugButton

            // Quit rechts. `lineLimit(1)` plus `fixedSize`, damit das Wort bei
            // engem Platz nicht vertikal umbricht und die Reihe einzeilig bleibt.
            tracked(.quit, Button("Quit") { clearHover(); NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Quit AudioRouterNow"))
        }
    }

    // MARK: Support-Pille (S1)

    /// Herz plus Wort "Support" als dezente Mint-Pille (eingeklappt) bzw. X plus
    /// "Close" (aufgeklappt). Keine Dauer-Animation; Fuellung hellt nur beim Hover
    /// leicht auf. Oeffnet/schliesst den Tip Jar (freiwilliger In-App-Kauf).
    @ViewBuilder private var supportPill: some View {
        tracked(.support, Button {
            clearHover()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showTipJar.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showTipJar ? "xmark" : "heart.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(showTipJar ? "Close" : "Support")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(showTipJar ? Color.secondary : ARNColor.accent)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(
                Capsule().fill(showTipJar
                    ? Color.secondary.opacity(hoveredTip == .support ? 0.12 : 0.08)
                    : ARNColor.accent.opacity(hoveredTip == .support ? 0.16 : 0.10)))
            .overlay(
                Capsule().stroke(showTipJar
                    ? Color.secondary.opacity(0.25)
                    : ARNColor.accent.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showTipJar ? "Hide support" : "Support the developer"))
    }

    // MARK: Icon-Knoepfe

    @ViewBuilder private var lockButton: some View {
        // Feature B: Stable Output Mode.
        tracked(.lock, Button {
            clearHover()
            controller.lockOutputDevice.toggle()
        } label: {
            Image(systemName: controller.lockOutputDevice ? "lock.fill" : "lock.open")
                .font(.system(size: 12))
                .foregroundStyle(controller.lockOutputDevice ? ARNColor.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stable output mode"))
    }

    @ViewBuilder private var exclusiveButton: some View {
        // CASE-008: Exclusive Routing (betrifft wie der Lock das Default-Geraet).
        tracked(.exclusive, Button {
            clearHover()
            controller.exclusiveRouting.toggle()
        } label: {
            Image(systemName: controller.exclusiveRouting ? "speaker.slash.circle.fill" : "speaker.slash.circle")
                .font(.system(size: 12))
                .foregroundStyle(controller.exclusiveRouting ? ARNColor.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exclusive routing"))
    }

    @ViewBuilder private var bugButton: some View {
        // v4.0.1: Bug-Report. Bewusst ein Icon und kein Textbutton.
        tracked(.bug, Button {
            clearHover()
            controller.openBugReport()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Report a bug"))
    }

    // MARK: Hover-Bubble

    /// Eigene Tooltip-Bubble, erscheint ueber der Footer-Reihe (nach unten ist
    /// kein Platz), horizontal am Fensterrand geclampt.
    @ViewBuilder private var hoverBubble: some View {
        if let tip = hoveredTip {
            Text(tip.text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: bubbleWidth, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .fixedSize()
                .offset(x: clampedBubbleOffset, y: -34)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: hoveredTip)
                .allowsHitTesting(false)   // die Bubble faengt keine Klicks ab
                .zIndex(100)
        }
    }

    /// Horizontaler Versatz der Bubble: zentriert ueber dem Anker, aber so
    /// verschoben, dass die Bubble zwischen linkem und rechtem Rand bleibt.
    private var clampedBubbleOffset: CGFloat {
        guard let anchor = anchorX, rowWidth > 0 else { return 0 }
        let half = bubbleWidth / 2
        // Die Bubble liegt zentriert ueber der Reihe (overlay .top ist
        // horizontal mittig). Der gewuenschte Mittelpunkt ist `anchor`, der
        // Ist-Mittelpunkt ist `rowWidth / 2`. Grundversatz:
        var desired = anchor - rowWidth / 2
        // Clampen: der Bubble-Mittelpunkt (rowWidth/2 + desired) darf nicht
        // naeher als half+edgePadding an die Raender kommen.
        let minCenter = half + edgePadding
        let maxCenter = rowWidth - half - edgePadding
        if maxCenter >= minCenter {
            let center = rowWidth / 2 + desired
            let clamped = min(max(center, minCenter), maxCenter)
            desired = clamped - rowWidth / 2
        }
        return desired
    }

    // MARK: Hover-Steuerung

    /// Zeit-Marke des letzten `enter`, damit die verzoegerte Einblendung nur
    /// feuert, wenn der Zeiger seitdem auf demselben Element geblieben ist (gegen
    /// Flackern beim Durchfahren mehrerer Elemente).
    @State private var pendingTip: FooterTip?

    private func enterHover(_ tip: FooterTip) {
        pendingTip = tip
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay) {
            // Nur setzen, wenn der Zeiger seit dem Planen auf demselben Element
            // steht und der Hover nicht geloescht wurde.
            if pendingTip == tip {
                withAnimation(.easeOut(duration: 0.12)) { hoveredTip = tip }
            }
        }
    }

    private func leaveHover(_ tip: FooterTip) {
        if pendingTip == tip { pendingTip = nil }
        if hoveredTip == tip {
            withAnimation(.easeOut(duration: 0.12)) { hoveredTip = nil }
        }
    }

    private func clearHover() {
        pendingTip = nil
        withAnimation(.easeOut(duration: 0.12)) { hoveredTip = nil }
    }

    /// Koordinatenraum-Name der Footer-Reihe fuer die Anker-Messung.
    fileprivate static let coordinateSpace = "arn.footer.row"

    /// Registriert `onHover`, setzt den VoiceOver-Hint aus demselben Text wie die
    /// Hover-Bubble (`FooterTip.text` -> `FooterTips`, eine Quelle der Wahrheit,
    /// keine zweite Textkopie) und meldet die horizontale Mitte des Elements als
    /// Anker, solange es das aktive Hover-Ziel ist. Als Methode von `FooterRow`
    /// (nicht als freie `View`-Extension), damit `enterHover`/`leaveHover` auf der
    /// echten `@State`-Instanz laufen und nicht auf einer Kopie.
    @ViewBuilder
    fileprivate func tracked<V: View>(_ tip: FooterTip, _ content: V) -> some View {
        content
            .accessibilityHint(tip.text)
            .onHover { inside in
                if inside { enterHover(tip) } else { leaveHover(tip) }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: FooterTipAnchorKey.self,
                        value: hoveredTip == tip
                            ? geo.frame(in: .named(Self.coordinateSpace)).midX
                            : nil)
                }
            )
    }
}
