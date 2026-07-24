#!/usr/bin/env python3
"""
Setzt das Custom-Icon auf der fertigen DMG-Datei.
Wird von build.sh als eigenstaendiges Script aufgerufen (nicht als Heredoc),
damit AppKit/NSWorkspace korrekt initialisiert werden kann.
"""
import sys
import subprocess
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dmg_path> <icns_path>")
        sys.exit(1)

    dmg_path  = sys.argv[1]
    icon_path = sys.argv[2]

    if not Path(dmg_path).exists():
        print(f"DMG not found: {dmg_path}")
        sys.exit(1)
    if not Path(icon_path).exists():
        print(f"ICNS not found: {icon_path}")
        sys.exit(1)

    # ── AppKit-Methode (primär) ─────────────────────────────────────────────
    try:
        from AppKit import NSWorkspace, NSImage
        from Foundation import NSDistributedNotificationCenter

        img = NSImage.alloc().initWithContentsOfFile_(icon_path)
        if img is None:
            raise RuntimeError("NSImage konnte ICNS nicht laden")

        ws     = NSWorkspace.sharedWorkspace()
        result = ws.setIcon_forFile_options_(img, dmg_path, 0)

        if result:
            # FinderInfo kHasCustomIcon-Flag explizit setzen (sicherheitshalber)
            r = subprocess.run(
                ["xattr", "-px", "com.apple.FinderInfo", dmg_path],
                capture_output=True, text=True,
            )
            hex_val = r.stdout.strip().replace(" ", "").replace("\n", "")
            fi = bytearray.fromhex(hex_val) if len(hex_val) >= 32 else bytearray(32)
            flags = (fi[8] << 8) | fi[9]
            flags |= 0x0400  # kHasCustomIcon
            fi[8] = (flags >> 8) & 0xFF
            fi[9] = flags & 0xFF
            subprocess.run(
                ["xattr", "-wx", "com.apple.FinderInfo",
                 " ".join(f"{b:02x}" for b in fi), dmg_path],
                check=True,
            )

            # Finder benachrichtigen
            nc = NSDistributedNotificationCenter.defaultCenter()
            nc.postNotificationName_object_userInfo_deliverImmediately_(
                "com.apple.LaunchServices.database.changed", None, None, True,
            )
            print("DMG-Icon gesetzt (AppKit + FinderInfo + Notification)")
        else:
            raise RuntimeError("setIcon returned False")

    except Exception as e:
        print(f"AppKit failed: {e}")
        # ── Fallback: fileicon CLI ──────────────────────────────────────────
        r = subprocess.run(
            ["fileicon", "set", dmg_path, icon_path],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print("DMG-Icon gesetzt (fileicon)")
        else:
            print(f"Icon konnte nicht gesetzt werden: {r.stderr.strip()}")
            sys.exit(1)


if __name__ == "__main__":
    main()
