"""
popover_menu.py — NSPopover-Praesentationsschicht fuer AudioRouterNow.

Option B der NSPopover-Migration: Ein NSPopover-Container mit custom
NSStackView-Rows ersetzt — wenn das Feature-Flag `use_popover_menu` aktiv ist —
das klassische NSMenu. Der entscheidende Nutzer-Vorteil: der Popover bleibt nach
einem Klick GEOEFFNET (NSMenu schliesst bei jedem Klick), sodass mehrere Devices
oder Channel-Pairs hintereinander getoggelt werden koennen.

Architektur-Invarianten (siehe menu_bar_app.py):
  * Das komplette State-/Logik-Modell der App bleibt unangetastet — diese Datei
    rendert nur und ruft die BESTEHENDEN Python-Callbacks (z.B. _toggle_device).
  * Alle View-Mutationen laufen auf dem Main-Thread. refresh() besitzt einen
    NSThread-Guard (Defense-in-Depth) und wird ausschliesslich aus dem 0.5s-
    rumps.Timer-Pump bzw. aus Main-Thread-Callbacks aufgerufen (K2-Pattern).
  * Strong-Reference-Disziplin (PyObjC-GC): _Target-Instanzen werden in
    _RowsController._targets gehalten; die App haelt eine starke Referenz auf
    StatusPopover; der NSPopover haelt den ViewController. Sonst → GC-Crash.

Plattform: NSPopover (10.7+), NSStatusItem.button() (10.10+). Deployment-Target
der App ist macOS 11.0 — beide garantiert verfuegbar.
"""

import logging
import time   # WARNING-3-Fix: Debounce-Zeitstempel fuer Transient-Dismiss-Guard

import objc
from AppKit import (
    NSPopover,
    NSPopoverBehaviorTransient,
    NSViewController,
    NSStackView,
    NSButton,
    NSSwitchButton,
    NSTextField,
    NSBox,
    NSBoxSeparator,
    NSFont,
    NSScrollView,
    NSApplication,
    NSMinYEdge,
    NSUserInterfaceLayoutOrientationVertical,
    NSLayoutAttributeLeading,
    NSLeftTextAlignment,   # WARNING-1-Fix: linksbuendige Status-Button-Beschriftung
)
from Foundation import NSObject, NSMakeRect, NSMakeSize, NSThread

logger = logging.getLogger(__name__)

# Standard-Breite und maximale Hoehe des Popover-Inhalts (px). Ueberschreitet der
# Inhalt die Maximalhoehe, wird das StackView in eine NSScrollView eingebettet.
_DEFAULT_WIDTH = 320.0
_MAX_HEIGHT = 560.0


# --- Daten-Spec (kein UI) -------------------------------------------------
class Row:
    """Eine logische Menue-Zeile. kind in {'item','header','separator','status'}.

    Reine Datenklasse — haelt keinerlei AppKit-Objekte. Wird in
    AudioRouterApp.build_rows() erzeugt und vom _RowsController in Views
    uebersetzt. callback erhaelt beim Klick den NSButton als sender (analog zur
    rumps-MenuItem-Callback-Signatur).
    """

    __slots__ = ("title", "callback", "checked", "kind", "indent", "enabled")

    def __init__(self, title="", callback=None, checked=False,
                 kind="item", indent=0, enabled=True):
        self.title = title
        self.callback = callback
        self.checked = checked
        self.kind = kind
        self.indent = indent
        self.enabled = enabled


# --- NSButton-Action -> Python-Callback Bridge ----------------------------
class _Target(NSObject):
    """Bruecke von einer NSButton-Action (Selector 'fire:') auf ein Python-
    Callable. Instanzen MUESSEN stark referenziert werden (siehe
    _RowsController._targets), sonst raeumt der PyObjC-GC sie ab und der
    Button-Klick laeuft ins Leere bzw. crasht."""

    def initWithCallback_(self, cb):
        self = objc.super(_Target, self).init()
        if self is None:
            return None
        self._cb = cb
        return self

    def fire_(self, sender):
        try:
            self._cb(sender)
        except Exception:  # noqa: BLE001 — UI-Callback darf den Runloop nie killen
            logger.exception("Popover-Row-Callback fehlgeschlagen")


# --- ViewController: baut NSStackView aus Row-Liste -----------------------
class _RowsController(NSViewController):
    """Baut aus einer Row-Liste ein vertikales NSStackView. Bei zu vielen Zeilen
    wird das StackView in eine scrollbare NSScrollView eingebettet. Die fuer den
    Popover noetige Inhaltsgroesse wird in _content_size hinterlegt und von
    StatusPopover via contentSize() ausgelesen."""

    def initWithRows_width_maxHeight_(self, rows, width, max_height):
        self = objc.super(_RowsController, self).init()
        if self is None:
            return None
        self._rows = rows
        self._width = width
        self._max_height = max_height
        self._targets = []          # STARKE Refs auf _Target (PyObjC-GC!)
        self._content_size = NSMakeSize(width, 0.0)
        return self

    def contentSize(self):
        return self._content_size

    def loadView(self):
        stack = NSStackView.alloc().init()
        stack.setOrientation_(NSUserInterfaceLayoutOrientationVertical)
        stack.setAlignment_(NSLayoutAttributeLeading)
        stack.setSpacing_(2.0)
        stack.setEdgeInsets_((8.0, 12.0, 8.0, 12.0))   # top, left, bottom, right

        for r in self._rows:
            stack.addArrangedSubview_(self._viewForRow_(r))

        # Natuerliche Groesse ermitteln (Autolayout).
        stack.layoutSubtreeIfNeeded()
        fitting = stack.fittingSize()
        width = max(self._width, float(fitting.width))
        height = float(fitting.height)

        if height > self._max_height:
            # Viele Devices → scrollbar machen. StackView als documentView.
            scroll = NSScrollView.alloc().initWithFrame_(
                NSMakeRect(0.0, 0.0, width, self._max_height))
            scroll.setHasVerticalScroller_(True)
            scroll.setHasHorizontalScroller_(False)
            scroll.setDrawsBackground_(False)
            scroll.setAutohidesScrollers_(True)
            stack.setFrameSize_(NSMakeSize(width, height))
            scroll.setDocumentView_(stack)
            # Oben starten (NSScrollView ist flipped-abhaengig — DocumentView an
            # den oberen Rand scrollen).
            doc = scroll.documentView()
            if doc is not None and not scroll.contentView().isFlipped():
                doc.scrollPoint_((0.0, height))
            self._content_size = NSMakeSize(width, self._max_height)
            self.setView_(scroll)
        else:
            stack.setFrameSize_(NSMakeSize(width, height))
            self._content_size = NSMakeSize(width, height)
            self.setView_(stack)

    def _viewForRow_(self, r):
        if r.kind == "separator":
            box = NSBox.alloc().init()
            box.setBoxType_(NSBoxSeparator)
            return box

        # WARNING-1-Fix: Klickbare Status-Zeile. Wenn build_rows() der Status-Row
        # einen callback (_status_action) gibt — d.h. action_key war
        # restart_helper / reinstall_driver / switch_audio — darf sie NICHT als
        # reines Label gerendert werden, sonst ist die Aktion im Popover-Modus
        # unerreichbar. Borderloser NSButton (kein Checkbox-State, wirkt wie
        # fetter Text) ueber dieselbe _Target/'fire:'-Bridge wie Item-Zeilen.
        if r.kind == "status" and r.callback is not None and r.enabled:
            btn = NSButton.alloc().init()           # Default: Momentary-Push, kein State
            btn.setBordered_(False)                 # bezellos → reine Text-Optik
            btn.setTitle_(r.title or "")
            btn.setFont_(NSFont.boldSystemFontOfSize_(12.0))
            btn.setAlignment_(NSLeftTextAlignment)  # linksbuendig wie der Stack
            t = _Target.alloc().initWithCallback_(r.callback)
            self._targets.append(t)                 # Strong-Ref halten (PyObjC-GC!)
            btn.setTarget_(t)
            btn.setAction_("fire:")
            return btn

        if r.kind in ("header", "status"):
            tf = NSTextField.labelWithString_(r.title or "")
            size = 11.0 if r.kind == "header" else 12.0
            tf.setFont_(NSFont.boldSystemFontOfSize_(size))
            return tf

        if r.kind == "action":
            btn = NSButton.alloc().init()
            btn.setBordered_(False)
            btn.setTitle_(r.title or "")
            btn.setFont_(NSFont.systemFontOfSize_(13.0))
            btn.setAlignment_(NSLeftTextAlignment)
            if r.callback is None or not r.enabled:
                btn.setEnabled_(False)
            else:
                t = _Target.alloc().initWithCallback_(r.callback)
                self._targets.append(t)
                btn.setTarget_(t)
                btn.setAction_("fire:")
            return btn

        # Klick- bzw. nicht-klickbare Item-Zeile als Checkbox-Button.
        btn = NSButton.alloc().init()
        btn.setButtonType_(NSSwitchButton)             # Checkbox-Stil
        btn.setTitle_(("    " * int(r.indent)) + (r.title or ""))
        btn.setState_(1 if r.checked else 0)

        if r.callback is None or not r.enabled:
            # Nicht-klickbar (Header-aehnliche Zeilen, "unavailable", Footer).
            btn.setEnabled_(False)
        else:
            t = _Target.alloc().initWithCallback_(r.callback)
            self._targets.append(t)                    # Ref halten (GC!)
            btn.setTarget_(t)
            btn.setAction_("fire:")
        return btn


# --- Popover + StatusItem-Anchor + Klick-Routing --------------------------
class StatusPopover(NSObject):
    """Kapselt den NSPopover, koppelt das rumps-NSMenu vom StatusItem ab und
    uebernimmt das Klick-Routing ueber den StatusItem-Button. Wird einmalig nach
    Runloop-Start installiert und von der App stark referenziert."""

    def initWithApp_(self, py_app):
        self = objc.super(StatusPopover, self).init()
        if self is None:
            return None
        self._py_app = py_app
        self._current_vc = None

        self._popover = NSPopover.alloc().init()
        self._popover.setBehavior_(NSPopoverBehaviorTransient)  # Outside-Click-Dismiss
        self._popover.setAnimates_(False)
        self._popover.setDelegate_(self)        # WARNING-3-Fix: popoverDidClose_ empfangen
        self._last_dismiss_ts = 0.0             # monotone Zeit des letzten Schliessens

        # rumps haelt das NSStatusItem auf der NSApp-Delegate-Instanz (_nsapp).
        # Verifiziert: rumps.py:1188 (_nsapp) + :1201 initializeStatusBar →
        # _nsapp.nsstatusitem (rumps.py:940). button() ab macOS 10.10.
        self._statusitem = py_app._nsapp.nsstatusitem
        self._statusitem.setMenu_(None)                # NSMenu abkoppeln

        btn = self._statusitem.button()
        if btn is not None:
            btn.setTarget_(self)
            btn.setAction_("togglePopover:")
        else:
            logger.warning("StatusPopover: statusItem.button() ist nil — "
                           "Klick-Routing nicht moeglich")
        return self

    # -- Klick-Routing -----------------------------------------------------
    def togglePopover_(self, sender):
        if self._popover.isShown():
            self._popover.performClose_(sender)
            return
        # WARNING-3-Fix (Flicker-Guard): Bei NSPopoverBehaviorTransient schliesst
        # ein Klick auf den StatusItem-Button den offenen Popover bereits per
        # Transient-Dismiss, BEVOR diese Action feuert — isShown() ist hier dann
        # schon False. Ohne Guard fuehrt das zu Dismiss→sofortiges Reopen =
        # Flicker. War der letzte Close gerade eben (derselbe Klick), nur
        # geschlossen lassen. Echtes Wieder-Oeffnen liegt > Reaktionszeit
        # entfernt und passiert das Fenster.
        if (time.monotonic() - self._last_dismiss_ts) < 0.15:
            return
        self._present()

    def popoverDidClose_(self, notification):
        """NSPopoverDelegate: feuert bei JEDEM Schliessen (performClose_ UND
        Transient-Dismiss). Liefert den Recency-Stempel fuer den Flicker-Guard
        in togglePopover_."""
        self._last_dismiss_ts = time.monotonic()

    def _build_vc(self):
        rows = self._py_app.build_rows()
        vc = _RowsController.alloc().initWithRows_width_maxHeight_(
            rows, _DEFAULT_WIDTH, _MAX_HEIGHT)
        # loadView triggern, damit contentSize berechnet ist.
        vc.view()
        return vc

    def _present(self):
        vc = self._build_vc()
        self._current_vc = vc                          # Ref halten (defensiv)
        self._popover.setContentViewController_(vc)
        self._popover.setContentSize_(vc.contentSize())
        btn = self._statusitem.button()
        if btn is None:
            return
        self._popover.showRelativeToRect_ofView_preferredEdge_(
            btn.bounds(), btn, NSMinYEdge)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

    # -- Live-Update -------------------------------------------------------
    def refresh(self):
        """Live-Update NUR wenn sichtbar. Tauscht den ViewController in-place,
        ruft KEIN erneutes show (das wuerde re-ankern/flackern). No-op bei
        geschlossenem Popover — beim naechsten Oeffnen liest _present() den
        State ohnehin frisch.

        Main-Thread-Guard (Defense-in-Depth): Aufrufer sind stets Main-Thread
        (0.5s-rumps.Timer bzw. Button-Action), der Guard schuetzt nur gegen
        kuenftige Fehlnutzung."""
        if not NSThread.isMainThread():
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "refresh", None, False)
            return
        if self._popover is None or not self._popover.isShown():
            return
        vc = self._build_vc()
        self._current_vc = vc
        self._popover.setContentViewController_(vc)
        self._popover.setContentSize_(vc.contentSize())

    # -- Teardown ----------------------------------------------------------
    def teardown(self):
        try:
            if self._popover is not None and self._popover.isShown():
                self._popover.performClose_(None)
        except Exception:  # noqa: BLE001
            logger.debug("StatusPopover.teardown: performClose fehlgeschlagen",
                         exc_info=True)
