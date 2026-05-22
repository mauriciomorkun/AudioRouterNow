#!/usr/bin/env python3
"""
Erstellt das DMG-Installer-Hintergrundbild fuer AudioRouterNow.

Zeigt einen Pfeil von der App (links) zum Applications-Ordner (rechts)
damit auch nicht-technische User sofort verstehen was zu tun ist.

Benoetigt: Pillow (wird von build.sh automatisch installiert)
Ausgabe:   installer/dmg_background.png (620x400 px)
"""

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow nicht verfuegbar — DMG ohne Hintergrundbild")
    sys.exit(0)

# --- Dimensionen (muss mit build.sh Fenstermassen uebereinstimmen) -----------
W, H = 620, 400

# Icon-Positionen im DMG (gesetzt via AppleScript in build.sh)
ICON_APP_X  = 160   # AudioRouterNow.app — Mitte X
ICON_APP_Y  = 185   # AudioRouterNow.app — Mitte Y
ICON_APPS_X = 460   # Applications      — Mitte X
ICON_APPS_Y = 185   # Applications      — Mitte Y


def create_background(output_path: Path):
    # --- Hintergrund (dunkler macOS-Stil Gradient) ---
    img  = Image.new("RGB", (W, H), (28, 28, 30))
    draw = ImageDraw.Draw(img)

    for y in range(H):
        t = y / H
        r = int(28 + t * 14)
        g = int(28 + t * 14)
        b = int(30 + t * 18)
        draw.line([(0, y), (W, y)], fill=(r, g, b))

    # --- Pfeil von App (links) zu Applications (rechts) ---
    arrow_y     = ICON_APP_Y
    arrow_start = ICON_APP_X  + 68   # Rand App-Icon
    arrow_end   = ICON_APPS_X - 68   # Rand Applications-Icon
    body_h      = 12
    head_w      = 28
    head_h      = 32
    blue        = (64, 156, 255)

    # Pfeilkoerper
    draw.rectangle(
        [arrow_start, arrow_y - body_h // 2,
         arrow_end,   arrow_y + body_h // 2],
        fill=blue
    )
    # Pfeilkopf (Dreieck rechts)
    draw.polygon([
        (arrow_end + head_w, arrow_y),
        (arrow_end,           arrow_y - head_h // 2),
        (arrow_end,           arrow_y + head_h // 2),
    ], fill=blue)

    # --- Fonts laden (macOS System-Fonts) ---
    def load_font(size: int):
        candidates = [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/SFNSText.ttf",
            "/System/Library/Fonts/Geneva.ttf",
        ]
        for path in candidates:
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
        return ImageFont.load_default()

    font_main  = load_font(17)
    font_small = load_font(13)

    # --- "Drag to install" Text ---
    main_text = "Drag to install"
    bbox = draw.textbbox((0, 0), main_text, font=font_main)
    tw   = bbox[2] - bbox[0]
    draw.text(
        ((W - tw) // 2, arrow_y + 52),
        main_text,
        fill=(170, 170, 175),
        font=font_main
    )

    # --- Dezente Trennlinie unten ---
    line_y = H - 50
    draw.line([(40, line_y), (W - 40, line_y)], fill=(55, 55, 60), width=1)

    # --- Footer-Text ---
    footer = "AudioRouterNow — free forever ❤️"
    bbox_f = draw.textbbox((0, 0), footer, font=font_small)
    fw     = bbox_f[2] - bbox_f[0]
    draw.text(
        ((W - fw) // 2, H - 32),
        footer,
        fill=(90, 90, 95),
        font=font_small
    )

    img.save(str(output_path), "PNG")
    print(f"Hintergrundbild erstellt: {output_path} ({W}x{H} px)")


if __name__ == "__main__":
    out = Path(__file__).parent / "dmg_background.png"
    create_background(out)
