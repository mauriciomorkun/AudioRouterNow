"""
diagnostic.py — Diagnostic Report Generator for AudioRouterNow.

Sammelt System-Info, Logs und Helper-Status in einem strukturierten .txt-Report
und öffnet Mail.app mit der Datei bereits angehängt (ein Klick = Senden).

Verwendung:
    from diagnostic import generate_report, open_mail_with_report
    path = generate_report(helper_client)
    ok   = open_mail_with_report(path)
"""
import json
import platform
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

# ── Konstanten ───────────────────────────────────────────────────────────────
from version import APP_VERSION

DEVELOPER_EMAIL  = "m.moraisdacunha@pm.me"

LOG_DIR          = Path.home() / "Library" / "Logs" / "AudioRouterNow"
HELPER_LOG       = LOG_DIR / "helper.log"
HELPER_ERR       = LOG_DIR / "helper.err"

# Letzte N Event-Zeilen im Report (keine Polling-Zeilen)
MAX_EVENT_LINES  = 200
# Letzten N Bytes aus helper.log lesen (3 MB reicht für recent events)
LOG_READ_TAIL    = 3_000_000
# Letzten N Bytes aus helper.err lesen (1 MB — Schutz vor crash-loop-Aufblähung)
ERR_READ_TAIL    = 1_000_000
# Grobe IOProc-Rate bei 48 kHz / 512 frames
IOPROC_PER_SEC   = 93.5

_DIV  = "─" * 56
_HDIV = "═" * 56


# ── Interne Hilfsfunktionen ───────────────────────────────────────────────────

def _system_info() -> dict:
    """macOS-Version, Hardware-Modell, CPU-Architektur."""
    try:
        mac_ver = platform.mac_ver()[0] or "unknown"
    except Exception:
        mac_ver = "unknown"

    try:
        hw_model = subprocess.check_output(
            ["sysctl", "-n", "hw.model"], text=True, timeout=3
        ).strip()
    except Exception:
        hw_model = "unknown"

    return {
        "mac_ver":  mac_ver,
        "hw_model": hw_model,
        "arch":     platform.machine(),  # arm64 / x86_64
    }


def _read_helper_err() -> str:
    """Letzten ERR_READ_TAIL Bytes von helper.err (gegen crash-loop-Aufblähung gecapped)."""
    if not HELPER_ERR.exists():
        return "(helper.err nicht gefunden)"
    try:
        file_size = HELPER_ERR.stat().st_size
        read_from = max(0, file_size - ERR_READ_TAIL)
        with open(HELPER_ERR, "r", errors="replace") as f:
            if read_from > 0:
                f.seek(read_from)
                f.readline()   # unvollständige erste Zeile überspringen
            text = f.read().strip()
        if not text:
            return "(leer)"
        if read_from > 0:
            return f"[... {read_from:,} Bytes übersprungen — zeige letztes 1 MB ...]\n{text}"
        return text
    except Exception as exc:
        return f"(Lesefehler: {exc})"


def _extract_log_events(max_events: int = MAX_EVENT_LINES) -> tuple[str, dict]:
    """
    Extrahiert Event-Zeilen aus helper.log (keine Status-Polling-Zeilen).

    Polling-Blöcke haben das Format:
        "Ring: NNNN Frames | Outputs: N | IOProc-Calls: +N/2s (N total)"

    Strategie: Polling-Blöcke per Regex entfernen, dann Event-Tokens extrahieren.
    Robuster als ein einzelner Event-Regex mit Lookahead, da das Log kaum echte
    Zeilenumbrüche enthält (32 physische Zeilen bei 14 MB).

    Returns:
        (events_text, stats_dict)
    """
    if not HELPER_LOG.exists():
        return "(helper.log nicht gefunden)", {}

    try:
        file_size = HELPER_LOG.stat().st_size
        read_from = max(0, file_size - LOG_READ_TAIL)

        with open(HELPER_LOG, "r", errors="replace") as f:
            if read_from > 0:
                f.seek(read_from)
                f.readline()          # unvollständige Zeile am Anfang überspringen
            content = f.read()

        # ── Statistiken (vor dem Bereinigen, auf Rohdaten) ───────────────────
        totals = re.findall(r'\((\d+) total\)', content)
        last_ioproc = int(totals[-1]) if totals else 0
        stall_count = content.count("HARD-STALL")
        uptime_h    = last_ioproc / (IOPROC_PER_SEC * 3600) if last_ioproc else 0

        stats = {
            "last_ioproc_total":  last_ioproc,
            "uptime_hours":       uptime_h,
            "stall_count_in_log": stall_count,
        }

        # ── Event-Extraktion ────────────────────────────────────────────────
        # Schritt 1: Polling-Blöcke entfernen.
        # Format: "Ring: N Frames | Outputs: N | IOProc-Calls: +N/2s (N total)"
        clean = re.sub(
            r'Ring:\s+\d+\s+Frames\s+\|\s+Outputs:\s+\d+\s+\|\s+IOProc-Calls:[^)]+\)',
            ' ',
            content,
        )

        # Schritt 2: Event-Tokens extrahieren.
        # Bekannte Präfixe: "Helper: ", "Helper laeuft", "AudioRouterNow Helper",
        # "Warte auf SHM", "SHM:". Token endet an Tab, Newline oder doppeltem Leerzeichen.
        token_re = re.compile(
            r'((?:Helper[:\s]|AudioRouterNow\s+Helper|Warte\s+auf\s+SHM|SHM:|Helper\s+laeuft)'
            r'[^\t\n]{3,120})',
        )
        raw: list[str] = [m.group(1).strip() for m in token_re.finditer(clean)]
        raw = [ev for ev in raw if ev]

        # Aufeinanderfolgende Duplikate entfernen
        events: list[str] = []
        prev = None
        for ev in raw:
            if ev != prev:
                events.append(ev)
                prev = ev

        events = events[-max_events:]

        return ("\n".join(events) if events else "(keine Events gefunden)"), stats

    except Exception as exc:
        return f"(Lesefehler: {exc})", {}


def _format_report(
    sys_info:   dict,
    status:     Optional[dict],
    err_text:   str,
    events_text: str,
    stats:      dict,
) -> str:
    """Baut den vollständigen Report-Text zusammen."""
    # Einmalige Zeit-Instanz — verhindert Diskrepanz bei Mitternachts-Übergang.
    dt     = datetime.now().astimezone()
    now    = dt.strftime("%Y-%m-%d %H:%M:%S")
    zone   = dt.strftime("%Z")

    # Uptime
    uptime_h = stats.get("uptime_hours", 0)
    ioproc_t = stats.get("last_ioproc_total", 0)
    if uptime_h >= 24:
        uptime_str = f"~{uptime_h / 24:.1f} days  ({ioproc_t:,} IOProc calls)"
    elif uptime_h >= 1:
        uptime_str = f"~{uptime_h:.1f} hours  ({ioproc_t:,} IOProc calls)"
    elif uptime_h > 0:
        uptime_str = f"~{uptime_h * 60:.1f} min  ({ioproc_t:,} IOProc calls)"
    else:
        uptime_str = "(nicht verfügbar)"

    stall_n = stats.get("stall_count_in_log", 0)

    # Status-JSON
    if status:
        try:
            status_str = json.dumps(status, indent=2, ensure_ascii=False)
        except Exception:
            status_str = str(status)
    else:
        status_str = "(Helper läuft nicht oder nicht erreichbar)"

    parts = [
        f"╔{_HDIV}╗",
        f"║{'AudioRouterNow — Diagnostic Report':^56}║",
        f"╚{_HDIV}╝",
        "",
        f"Generated : {now} {zone}",
        f"Version   : {APP_VERSION}",
        f"macOS     : {sys_info.get('mac_ver', 'unknown')}",
        f"Hardware  : {sys_info.get('hw_model', 'unknown')}",
        f"Arch      : {sys_info.get('arch', 'unknown')}",
        "",
        "NOTE: This report contains audio device identifiers",
        "      (hardware model info only — no personal data).",
        "",
        _DIV,
        "STATISTICS",
        _DIV,
        f"Uptime estimate : {uptime_str}",
        f"HARD-STALLs     : {stall_n}  (in letzten 3 MB des Logs)",
        "",
        _DIV,
        "CURRENT STATUS",
        _DIV,
        status_str,
        "",
        _DIV,
        "ERROR LOG  (helper.err — letztes 1 MB)",
        _DIV,
        err_text,
        "",
        _DIV,
        f"RECENT EVENTS  (letzte {MAX_EVENT_LINES} aus helper.log)",
        _DIV,
        events_text,
        "",
        _DIV,
        "END OF REPORT",
        _DIV,
    ]
    return "\n".join(parts)


# ── Öffentliche API ───────────────────────────────────────────────────────────

def generate_report(helper_client) -> Path:
    """
    Generiert den Diagnostic Report, speichert ihn auf dem Desktop.

    Args:
        helper_client: HelperClient-Instanz (für get_status_quick)

    Returns:
        Path zur gespeicherten .txt-Datei

    Raises:
        OSError / PermissionError: wenn Desktop nicht beschreibbar ist.
    """
    timestamp   = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename    = f"AudioRouterNow_DiagReport_{timestamp}.txt"
    report_path = Path.home() / "Desktop" / filename

    # Daten sammeln
    sys_info      = _system_info()
    err_text      = _read_helper_err()
    events, stats = _extract_log_events()

    # Helper-Status (quick, non-blocking)
    try:
        status = helper_client.get_status_quick()
    except Exception:
        status = None

    # Report generieren & speichern (wirft bei Schreibfehler)
    report_text = _format_report(sys_info, status, err_text, events, stats)
    report_path.write_text(report_text, encoding="utf-8")

    return report_path


def open_mail_with_report(report_path: Path) -> bool:
    """
    Öffnet Mail.app mit einer neuen Nachricht, Empfänger vorausgefüllt,
    Report-Datei bereits angehängt.

    Returns:
        True bei Erfolg, False wenn osascript fehlschlägt (Fallback nötig).
    """
    date_str  = datetime.now().strftime("%Y-%m-%d")
    posix     = str(report_path).replace("\\", "\\\\").replace('"', '\\"')

    script = f'''
tell application "Mail"
    set theFile to POSIX file "{posix}" as alias
    set newMsg to make new outgoing message with properties {{subject:"AudioRouterNow Bug Report — {date_str}", content:"Hi Mauricio,\\n\\nI experienced an issue with AudioRouterNow. Please find the diagnostic report attached.\\n\\n[Describe your issue here]\\n\\nThanks!"}}
    tell newMsg
        make new to recipient with properties {{address:"{DEVELOPER_EMAIL}"}}
        make new attachment with properties {{file name:theFile}} at after last paragraph
    end tell
    activate
    open newMsg
end tell
'''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=20,
        )
        return result.returncode == 0
    except Exception:
        return False


def reveal_in_finder(report_path: Path) -> None:
    """Fallback: Datei im Finder markieren (selektieren)."""
    try:
        subprocess.run(["open", "-R", str(report_path)], check=True, timeout=5)
    except Exception:
        try:
            subprocess.run(["open", str(report_path.parent)], timeout=5)
        except Exception:
            pass
