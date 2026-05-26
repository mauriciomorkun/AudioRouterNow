#!/usr/bin/env python3
"""
DMG-Hintergrundbild fuer AudioRouterNow.

Fenster: 680x440pt → Background: 1360x880px @2x
Hintergrundfarbe: dunkles Teal passend zum App-Icon (0, 20, 18).
Kein Pfeil — nur Farbe.
"""

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("Pillow nicht verfuegbar — DMG ohne Hintergrundbild")
    sys.exit(0)

W, H = 1360, 880   # @2x für 680x440pt Fenster

# Farbe des Logo-Symbols aus dem App-Icon — helles Teal-Grün
BG_TOP    = (25, 220, 168)  # oben: minimal heller
BG_BOTTOM = (15, 185, 142)  # unten: minimal dunkler
TEAL      = (255, 255, 255) # weisser Glow in der Mitte


def create_background(output_path: Path):

    # ── Vertikaler Gradient (passend zum Icon-Hintergrund) ────────────────────
    img  = Image.new("RGB", (W, H), BG_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        r = int(BG_TOP[0] + t * (BG_BOTTOM[0] - BG_TOP[0]))
        g = int(BG_TOP[1] + t * (BG_BOTTOM[1] - BG_TOP[1]))
        b = int(BG_TOP[2] + t * (BG_BOTTOM[2] - BG_TOP[2]))
        draw.line([(0, y), (W, y)], fill=(r, g, b))

    # ── Subtiler weisser Glow in der Mitte ───────────────────────────────────
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd   = ImageDraw.Draw(glow)
    cx, cy = W // 2, H // 2
    for radius in range(500, 0, -5):
        alpha = int(12 * (1 - radius / 500))
        gd.ellipse([cx-radius, cy-radius, cx+radius, cy+radius],
                   fill=(*TEAL, alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=30))
    img  = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
    draw = ImageDraw.Draw(img)

    # ── Feine hellere Linie oben ─────────────────────────────────────────────
    draw.line([(0, 0), (W, 0)], fill=(60, 240, 190))
    draw.line([(0, 1), (W, 1)], fill=(40, 230, 180))

    img.save(str(output_path), "PNG")
    print(f"Hintergrundbild erstellt: {output_path} ({W}x{H}px @2x)")


if __name__ == "__main__":
    parent = Path(__file__).parent
    create_background(parent / "dmg_background.png")
