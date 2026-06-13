# AudioRouterNow — Projektregeln für Claude Code

## Modell-Pflicht
Für ALLE Aufgaben in diesem Projekt — Planung, Implementierung, Audits, Reviews — gilt:
**Immer das höchste verfügbare Claude-Modell (Opus) verwenden.**

Das gilt insbesondere für:
- Launch-Planung und Entscheidungen
- Code-Implementierung (Sparkle, CI/CD, Homebrew, Notarization)
- Zwischen-Audits und Qualitätsprüfungen
- README und Landing Page Texte
- Jede Aufgabe mit Außenwirkung (öffentlich sichtbar)

## Projektkontext
- **App:** AudioRouterNow v3.4.0 — macOS Audio-Routing (HAL-Plugin + C-Helper + Python)
- **Modell:** Gratis, Open Source (GPL-3.0), für immer
- **Spenden:** Buy Me a Coffee
- **Launch:** GitHub (Fresh Start Repo) → später App Store (v4.0, Swift-Rewrite)
- **Lizenz:** GPL-3.0

## Wichtige Dokumente
- `LAUNCH_PLAN.md` — Alle Launch-Entscheidungen und Phasen
- `BACKLOG.md` — Feature-Ideen (Per-App-Routing, Council-Findings)
- `RELEASE_NOTES.md` — v3.4.0 Changelog
- `v4-appstore/PLAN.md` — v4.0 App Store Architektur
- `PLAN.md` — Stability Hardening (abgeschlossen, historisch)

## Vor jeder Aufgabe
1. `LAUNCH_PLAN.md` lesen — aktueller Stand der Entscheidungen
2. Keine Entscheidungen mit Lock-in alleine treffen — User fragen
3. Nach jeder Phase: kurzes Audit ob alles konsistent ist

## Auto-Commit-Regel (PFLICHT)
Nach jedem abgeschlossenen Arbeitsschritt oder Arbeitspunkt IMMER automatisch:

1. **LAUNCH_EXECUTION.md updaten** — abgeschlossenen Schritt mit Datum/Uhrzeit
   und kurzem Ergebnis eintragen
2. **Git commit erstellen** — mit aussagekräftiger Commit-Message (conventional
   commits: fix/feat/docs/chore + Scope + Was + Warum)

### Was gilt als "abgeschlossener Schritt"?
- Ein konkretes Problem gelöst (Bug, Signing-Fehler, Build-Fix, etc.)
- Eine Datei / ein Modul fertig implementiert oder geändert
- Eine Phase vollständig abgeschlossen (z.B. "Phase 1: Build + Sign + Notarisierung ✅")
- Eine wichtige Entscheidung getroffen und umgesetzt

### Was gilt NICHT als Schritt?
- Zwischenschritte die noch nicht funktionieren
- Experimente / Tests ohne konkretes Ergebnis
- Reine Analyse ohne Code-Änderung

### Commit-Format
```
<type>(<scope>): <kurze Beschreibung>

<optionaler Body: Was wurde gemacht und warum>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

### LAUNCH_EXECUTION.md Format
Jeden Eintrag so:
```
### [DATUM] — [Schritt-Titel]
**Status:** ✅ Abgeschlossen
**Was:** Kurzbeschreibung
**Ergebnis:** Konkretes Resultat
```
