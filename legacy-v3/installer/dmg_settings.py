#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DMG-Einstellungen fuer AudioRouterNow.
Wird von build.sh via dmgbuild aufgerufen.

Pfade werden via -D von build.sh uebergeben:
  -D app_path=<...>    Pfad zur AudioRouterNow.app
  -D icon_path=<...>   Pfad zur AudioRouterNow.icns (Volume-Icon)
  -D bg_path=<...>     Pfad zum Hintergrundbild (PNG, enthaelt weissen Pfeil)

Der Pfeil ist direkt ins Hintergrundbild eingezeichnet — keine extra Datei
im DMG-Fenster. Nur 2 Icons: App (links) und Applications-Alias (rechts).
Finder zeigt Icon-Labels bei dunklem Hintergrund automatisch in Weiss.
"""

# ── Pfade (via -D defines von build.sh) ──────────────────────────────────────
_app   = defines.get('app_path',   '')  # noqa: F821  (defines injiziert von dmgbuild)
_icon  = defines.get('icon_path',  '')
_bg    = defines.get('bg_path',    '')

# ── Inhalte -------------------------------------------------------------------
# Nur die App — kein Arrow-File mehr (Pfeil ist im Hintergrundbild)
files    = [_app]
symlinks = {'Applications': '/Applications'}

# ── Icons --------------------------------------------------------------------
icon = _icon          # Volume-Icon (.VolumeIcon.icns im Finder)

# ── Hintergrundbild ----------------------------------------------------------
background = _bg

# ── Format -------------------------------------------------------------------
format = 'UDZO'
size   = None

# ── Fenster-Einstellungen ----------------------------------------------------
show_status_bar = False
show_tab_view   = False
show_toolbar    = False
show_pathbar    = False
show_sidebar    = False

# (links, oben), (breite, hoehe) in Bildschirm-Punkten
window_rect = ((200, 120), (680, 440))

# ── Icon-Darstellung ---------------------------------------------------------
icon_size = 100
text_size = 13   # sichtbare Labels — Finder zeigt Weiss auf dunklem Hintergrund

# ── Icon-Positionen (Mittelpunkt im Fenster, in Punkten) ---------------------
icon_locations = {
    'AudioRouterNow.app': (160, 210),
    'Applications':       (520, 210),
}
