# Feedback- & Bug-Register — AudioRouterNow

Zentrales Register für alle gemeldeten Bugs, Feedback-Fälle und User-Reports zu
AudioRouterNow. Jeder Fall bekommt eine eigene, ausführliche Case-Datei und einen
Eintrag in der Tabelle unten.

> **Hinweis:** Dieser Ordner dient der **Analyse und Dokumentation**. Fixes werden
> daraus als Backlog abgeleitet — die Doku selbst nimmt **keine** Code-Änderungen vor.

---

## Case-Register

| Case-ID | Datum | Quelle | Titel | Status | Schweregrad |
|---------|-------|--------|-------|--------|-------------|
| [CASE-001](./CASE-001_macrumors_routing-not-working.md) | 2026-06-24 | MacRumors-Forum | Routing funktioniert nicht — "Audio Router nicht in CoreAudio gefunden", nur leiser Ton aus Mac-mini-Speaker | Fix in Arbeit — Wave-1-Fixes (H2, H5, i18n) in v3.4.1 implementiert; H7 ausstehend | Kritisch |

---

## Ablage- & Namens-Konvention

**Dateiname je Case:**

```
CASE-<NNN>_<quelle>_<kurz-slug>.md
```

- `<NNN>` — fortlaufende dreistellige Case-Nummer (001, 002, …)
- `<quelle>` — Herkunft in Kurzform (`macrumors`, `github`, `reddit`, `email`, `bmc`, …)
- `<kurz-slug>` — knapper, kleingeschriebener Bindestrich-Slug des Kernproblems

**Beispiele:**

```
CASE-001_macrumors_routing-not-working.md
CASE-002_github_crash-on-hotplug.md
```

- Eine Datei pro Case. Folge-Reports zum **selben Wurzelproblem** werden im
  bestehenden Case unter "Originalfeedback" / "Änderungs-Log" ergänzt, nicht neu angelegt.
- Jeder Case führt am Ende ein **Änderungs-Log** (Datum + Was geändert wurde).
- Belege immer als **Datei:Zeile** (z.B. `engine/audio_device_control.py:222`) — mit
  Relativlink zur Quelldatei, wo sinnvoll.

---

## Status-Schema

| Status | Bedeutung |
|--------|-----------|
| **Offen** | Gemeldet, noch nicht analysiert |
| **In Analyse** | Wird untersucht; Hypothesen formuliert, Beweis ggf. noch ausstehend |
| **Ursache bestätigt** | Root Cause reproduziert / bewiesen |
| **Fix in Arbeit** | Behebung wird implementiert |
| **Behoben** | Fix released und verifiziert |
| **Won't fix** | Bewusst nicht behoben (mit Begründung im Case) |

---

## Schweregrad-Schema

| Schweregrad | Bedeutung |
|-------------|-----------|
| **Kritisch** | App-Kernfunktion betroffen / unbrauchbar |
| **Hoch** | Wichtige Funktion oder Vertrauen beeinträchtigt, Workaround schwierig |
| **Mittel** | Spürbares Problem, Workaround möglich |
| **Niedrig** | Kosmetik / Edge Case |

---

_Stand: 2026-06-24_
