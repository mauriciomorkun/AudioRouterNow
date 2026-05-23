#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DMG-Einstellungen fuer AudioRouterNow.
Wird von build.sh via dmgbuild aufgerufen.

Pfade werden via -D von build.sh uebergeben:
  -D app_path=<...>   Pfad zur AudioRouterNow.app
  -D icon_path=<...>  Pfad zur AudioRouterNow.icns (Volume-Icon)
  -D bg_path=<...>    Pfad zum Hintergrundbild (PNG)

text_size = 1  →  Finder-Labels quasi unsichtbar (1pt)
Weisse Label-Texte kommen aus dem Hintergrundbild (create_dmg_background.py).
"""

# ── Pfade (via -D defines von build.sh) ──────────────────────────────────────
_app  = defines.get('app_path',  '')  # noqa: F821  (defines injiziert von dmgbuild)
_icon = defines.get('icon_path', '')
_bg   = defines.get('bg_path',   '')

# ── Inhalte -------------------------------------------------------------------
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
text_size = 1    # 1pt = unsichtbar; weisse Labels kommen aus dem Hintergrundbild

# ── Icon-Positionen (Mittelpunkt im Fenster, in Punkten) ---------------------
icon_locations = {
    'AudioRouterNow.app': (160, 210),
    'Applications':       (520, 210),
}
