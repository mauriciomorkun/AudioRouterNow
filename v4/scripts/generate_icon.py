#!/usr/bin/env python3
"""
generate_icon.py — AudioRouterNow v4.0 App Icon Generator
Generiert alle macOS App Store Icon-Größen aus einem 1024x1024 Master.

Aufruf: python3 scripts/generate_icon.py
Output: AudioRouterNow4/Assets.xcassets/AppIcon.appiconset/
"""

import json
import math
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("Pillow nicht installiert. Bitte: pip install Pillow")
    sys.exit(1)


# ── Design-Konstanten ─────────────────────────────────────────────────────────

BG_TOP    = (18, 18, 46)       # Deep Navy #12122E
BG_BOTTOM = (35, 55, 95)       # Medium Blue #23375F
ACCENT    = (100, 200, 255)    # Sky Blue #64C8FF
WHITE     = (255, 255, 255)
GLOW      = (100, 180, 255, 60)


# ── Icon-Zeichnen ─────────────────────────────────────────────────────────────

def draw_master(size: int = 1024) -> Image.Image:
    """Zeichnet den 1024x1024 Master."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Gradient-Hintergrund (top → bottom)
    for y in range(size):
        t = y / size
        r = int(BG_TOP[0] + t * (BG_BOTTOM[0] - BG_TOP[0]))
        g = int(BG_TOP[1] + t * (BG_BOTTOM[1] - BG_TOP[1]))
        b = int(BG_TOP[2] + t * (BG_BOTTOM[2] - BG_TOP[2]))
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    cx, cy = size // 2, size // 2
    pad = size * 0.14

    # ── Symbol: Audio-Fan-Out (1 Eingang → 3 Ausgänge) ─────────────────────
    # Trunk (links): dicke Linie von links nach Mitte
    trunk_lw = int(size * 0.065)
    trunk_x1 = int(cx - size * 0.20)
    trunk_x2 = int(cx + size * 0.05)
    draw.line(
        [(trunk_x1, cy), (trunk_x2, cy)],
        fill=WHITE, width=trunk_lw
    )

    # Verzweigungspunkt: gefüllter Kreis
    dot_r = int(size * 0.055)
    draw.ellipse(
        [trunk_x2 - dot_r, cy - dot_r, trunk_x2 + dot_r, cy + dot_r],
        fill=WHITE
    )

    # 3 Ausgangszweige (oben, mitte, unten)
    branch_lw = int(size * 0.05)
    branch_x2 = int(cx + size * 0.26)
    spreads = [-size * 0.24, 0, size * 0.24]

    for dy in spreads:
        y_end = int(cy + dy)
        # Diagonale Kurve simuliert durch 3-Segment-Poly
        x_mid = int(trunk_x2 + (branch_x2 - trunk_x2) * 0.45)
        points = [
            (trunk_x2, cy),
            (x_mid, cy + int(dy * 0.5)),
            (branch_x2, y_end),
        ]
        # Zeichne als Linie mit quadratischen Zwischenpunkten
        for i in range(len(points) - 1):
            draw.line([points[i], points[i + 1]], fill=WHITE, width=branch_lw)

        # Pfeilspitze / Endpunkt
        dot_r2 = int(size * 0.040)
        draw.ellipse(
            [branch_x2 - dot_r2, y_end - dot_r2, branch_x2 + dot_r2, y_end + dot_r2],
            fill=ACCENT
        )

    # Accent-Glühen um die Punkte (Unschärfe-Layer)
    glow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow_layer)
    for dy in spreads:
        y_end = int(cy + dy)
        gr = dot_r2 + int(size * 0.03)
        gdraw.ellipse(
            [branch_x2 - gr, y_end - gr, branch_x2 + gr, y_end + gr],
            fill=(*ACCENT, 80)
        )
    glow_blurred = glow_layer.filter(ImageFilter.GaussianBlur(radius=size * 0.025))
    img = Image.alpha_composite(img, glow_blurred)
    img = Image.alpha_composite(img, Image.fromarray(
        __draw_symbol_layer(size, cx, cy, trunk_x1, trunk_x2, branch_x2, spreads,
                            trunk_lw, branch_lw, dot_r, dot_r2)
    ))

    return img


def __draw_symbol_layer(size, cx, cy, trunk_x1, trunk_x2, branch_x2, spreads,
                        trunk_lw, branch_lw, dot_r, dot_r2):
    """Re-zeichnet das Symbol scharf auf transparentem Layer."""
    import numpy as np
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    draw.line([(trunk_x1, cy), (trunk_x2, cy)], fill=WHITE, width=trunk_lw)
    draw.ellipse(
        [trunk_x2 - dot_r, cy - dot_r, trunk_x2 + dot_r, cy + dot_r],
        fill=WHITE
    )
    for dy in spreads:
        y_end = int(cy + dy)
        x_mid = int(trunk_x2 + (branch_x2 - trunk_x2) * 0.45)
        points = [(trunk_x2, cy), (x_mid, cy + int(dy * 0.5)), (branch_x2, y_end)]
        for i in range(len(points) - 1):
            draw.line([points[i], points[i + 1]], fill=WHITE, width=branch_lw)
        draw.ellipse(
            [branch_x2 - dot_r2, y_end - dot_r2, branch_x2 + dot_r2, y_end + dot_r2],
            fill=ACCENT
        )
    import numpy as np
    return np.array(layer)


# ── Größen-Definition (macOS App Store) ──────────────────────────────────────

SIZES = [
    ("16x16",   "1x",  16),
    ("16x16",   "2x",  32),
    ("32x32",   "1x",  32),
    ("32x32",   "2x",  64),
    ("128x128", "1x",  128),
    ("128x128", "2x",  256),
    ("256x256", "1x",  256),
    ("256x256", "2x",  512),
    ("512x512", "1x",  512),
    ("512x512", "2x",  1024),
]


def generate_all(output_dir: Path):
    """Generiert alle Größen und schreibt Contents.json."""
    output_dir.mkdir(parents=True, exist_ok=True)

    print("🎨 Zeichne 1024×1024 Master…")
    master = draw_master(1024)

    images_json = []
    generated = []

    for size_name, scale, px in SIZES:
        filename = f"icon_{px}x{px}.png"
        out_path = output_dir / filename

        if px == 1024:
            resized = master
        else:
            resized = master.resize((px, px), Image.LANCZOS)

        resized.save(out_path, "PNG", optimize=True)
        generated.append(filename)
        print(f"  ✅ {filename}  ({px}×{px})")

        images_json.append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size_name,
        })

    # Contents.json schreiben
    contents = {
        "images": images_json,
        "info": {"author": "xcode", "version": 1}
    }
    contents_path = output_dir / "Contents.json"
    contents_path.write_text(json.dumps(contents, indent=2) + "\n")
    print(f"\n📄 Contents.json aktualisiert ({len(images_json)} Einträge)")
    print(f"✅ Icon-Set komplett: {output_dir}")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    output = project_root / "AudioRouterNow4" / "Assets.xcassets" / "AppIcon.appiconset"

    print(f"AudioRouterNow v4.0 — App Icon Generator")
    print(f"Output: {output}\n")
    generate_all(output)
