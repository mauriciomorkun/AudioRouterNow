#!/usr/bin/env python3
"""
DMG-Hintergrundbild fuer AudioRouterNow.

Fenster: 680x440pt → Background: 1360x880px @2x
Icon-Positionen (aus build.sh AppleScript):
  AudioRouterNow : (160, 210) pt  → Pixel-Mitte: (320, 420)
  Applications   : (520, 210) pt  → Pixel-Mitte: (1040, 420)
Icon-Groesse: 100pt → 200px @2x

Weiße Label-Texte werden direkt ins Bild gezeichnet.
Finder-Labels werden auf text size 1 gesetzt (unsichtbar).
"""

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    print("Pillow nicht verfuegbar — DMG ohne Hintergrundbild")
    sys.exit(0)

W, H = 1360, 880   # @2x für 680x440pt Fenster

BG_TOP    = (12,  14,  16)
BG_BOTTOM = (18,  22,  24)
TEAL      = (0,   190, 165)
WHITE     = (255, 255, 255)
WHITE_DIM = (200, 205, 210)

# Icon-Mittelpunkte (@2x Pixel)
APP_CENTER  = (320,  420)
APPS_CENTER = (1040, 420)
ICON_HALF   = 100   # px (icon_size 100pt / 2 * @2x)

# Label-Y: Unterkante Icon + 18px Abstand, dann Textmitte
LABEL_Y = APP_CENTER[1] + ICON_HALF + 32   # ≈ 552px


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSText.ttf",
        "/System/Library/Fonts/Geneva.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def draw_text_centered(draw, text, cx, y, font, color):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    draw.text((cx - tw // 2, y), text, fill=color, font=font)


def create_background(output_path: Path):

    # ── Gradient ──────────────────────────────────────────────────────────────
    img  = Image.new("RGB", (W, H), BG_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        r = int(BG_TOP[0] + t * (BG_BOTTOM[0] - BG_TOP[0]))
        g = int(BG_TOP[1] + t * (BG_BOTTOM[1] - BG_TOP[1]))
        b = int(BG_TOP[2] + t * (BG_BOTTOM[2] - BG_TOP[2]))
        draw.line([(0, y), (W, y)], fill=(r, g, b))

    # ── Subtiler Teal-Glow in der Mitte ───────────────────────────────────────
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd   = ImageDraw.Draw(glow)
    cx, cy = W // 2, H // 2
    for radius in range(500, 0, -5):
        alpha = int(16 * (1 - radius / 500))
        gd.ellipse([cx-radius, cy-radius, cx+radius, cy+radius],
                   fill=(*TEAL, alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=3))
    img  = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
    draw = ImageDraw.Draw(img)

    # ── Teal-Linie oben ───────────────────────────────────────────────────────
    draw.line([(0, 0), (W, 0)], fill=(0, 160, 140))
    draw.line([(0, 1), (W, 1)], fill=(0, 120, 105))

    # ── Weisse Label-Texte an den Icon-Positionen ─────────────────────────────
    font_label = load_font(26)   # 13pt @2x — entspricht normalem Finder-Label

    draw_text_centered(draw, "AudioRouterNow", APP_CENTER[0],  LABEL_Y, font_label, WHITE)
    draw_text_centered(draw, "Applications",   APPS_CENTER[0], LABEL_Y, font_label, WHITE)

    # ── Pfeil + "Drag & Drop" zwischen den Icons ──────────────────────────────
    arrow_y  = APP_CENTER[1]                    # 420 — Höhe der Icon-Mitten
    arrow_x1 = APP_CENTER[0]  + ICON_HALF + 40  # 460 — rechts vom App-Icon
    arrow_x2 = APPS_CENTER[0] - ICON_HALF - 40  # 900 — links vom Applications-Icon
    arrow_cx = (arrow_x1 + arrow_x2) // 2       # 680 — Mitte horizontal

    HEAD_LEN = 36   # Pfeilspitzen-Länge (px)
    HEAD_H   = 20   # halbe Pfeilspitzen-Höhe (px)
    LINE_W   = 4    # Liniendicke (px)

    # Linie (bis kurz vor die Spitze)
    draw.line(
        [(arrow_x1, arrow_y), (arrow_x2 - HEAD_LEN + 2, arrow_y)],
        fill=WHITE, width=LINE_W,
    )

    # Pfeilspitze (ausgefülltes Dreieck, zeigt nach rechts)
    draw.polygon(
        [
            (arrow_x2,            arrow_y),
            (arrow_x2 - HEAD_LEN, arrow_y - HEAD_H),
            (arrow_x2 - HEAD_LEN, arrow_y + HEAD_H),
        ],
        fill=WHITE,
    )

    # "Drag & Drop" Text mittig über dem Pfeil
    font_dnd = load_font(30)
    DND_Y = arrow_y - 72   # 72px über der Pfeil-Linie
    draw_text_centered(draw, "Drag & Drop", arrow_cx, DND_Y, font_dnd, WHITE)

    img.save(str(output_path), "PNG")
    print(f"Hintergrundbild erstellt: {output_path} ({W}x{H}px @2x)")


if __name__ == "__main__":
    out = Path(__file__).parent / "dmg_background.png"
    create_background(out)
