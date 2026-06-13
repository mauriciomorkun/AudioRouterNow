# AudioRouterNow — GitHub Launch Plan

> **Status:** In Planung — aktive Diskussion (Stand: 12. Juni 2026)
> Dieses Dokument hält alle Entscheidungen, offenen Fragen und nächsten Schritte
> für den öffentlichen GitHub-Launch von v3.4.0 fest.

---

## Strategische Grundsatz-Entscheidungen (bereits beschlossen)

| Entscheidung | Beschluss |
|---|---|
| **Preismodell** | Gratis — für immer |
| **Open Source** | Ja — für immer |
| **Spenden** | Buy Me a Coffee (Account bereits vorhanden) |
| **Primäre Distribution** | GitHub (DMG) — App Store nachgelagert (v4.0) |
| **App Store** | Ja, aber erst v4.0 (Process Taps, Swift-Rewrite) — kann nach GitHub-Launch nachgereicht werden |
| **Landing Page** | Subdomain `audiorouternow.mauriciomorkun.com` |

---

## Strategischer Kontext — LLM Council Findings (12. Juni 2026)

Ein LLM Council (Fable-Modell, 5 Berater) wurde zur Frage der Differenzierung durch das Per-App-Routing-Feature durchgeführt. Relevante Erkenntnisse für den Launch:

- **Per-App-Routing ist kein Alleinstellungsmerkmal** — SoundSource (47 USD) und BackgroundMusic (gratis) existieren bereits
- **Der echte Differenzierer ist der Kanal:** Rogue Amoeba kann strukturell nicht in den App Store
- **Positionierung:** *"Free open-source alternative to Loopback (129 $)"* — das ist die Story
- **Zielgruppe:** Power-User, Musiker, Streamer, Entwickler — technisch affin, wissen was ein HAL-Treiber ist
- **Konsumprodukt-Sprache:** Niemals "HAL-Plugin" oder "Process Taps API" nach außen — "Jede App auf ihr eigenes Gerät, in 10 Sekunden"
- **Sherlocking-Risiko:** Apple könnte Per-App-Routing nativ einbauen (WWDC-Risiko) — daher v4.0 nicht als einzige Strategie wetten

---

## Die 11 Dimensionen — Status

### ✅ Entschieden

| Dimension | Entscheidung |
|---|---|
| **Spenden-Mechanismus** | Buy Me a Coffee (bestehender Account) |
| **App Store Zeitpunkt** | Nach GitHub-Launch, v4.0, kann nachgereicht werden |
| **Haupt-Zielgruppe** | Power-User / technisch affine Mac-User |

---

### ⚠️ Offene Entscheidungen (Lock-in — zuerst treffen!)

#### 1. Git-History
**Frage:** Bestehende History behalten oder Fresh Start (neues Repo, ein Initial-Commit)?

| Option | Pro | Contra |
|---|---|---|
| History behalten | Authentisch, zeigt Entwicklung | Risiko: Secrets/private Pfade in alten Commits |
| Fresh Start | Sauber, kein Risiko | Verliert Commit-Geschichte |

**Empfehlung:** Zumindest `gitleaks`-Scan vor dem Public-Schalten. Bei Zweifeln: Fresh Start.
**Status:** ✅ **ENTSCHIEDEN — Fresh Start** (13.06.2026)

---

#### 2. Lizenz
**Frage:** MIT oder GPL-3.0?

| Lizenz | Pro | Contra |
|---|---|---|
| **MIT** | Einfachste Lösung, v4.0 unproblematisch, maximal contributor-freundlich | Jemand könnte Closed-Source-Fork verkaufen |
| **GPL-3.0** | Schützt vor kommerziellen Forks, passt zu "für immer Open Source" | Bei externen PRs: Contributors müssen CLA unterzeichnen damit v4.0-App-Store-Version möglich bleibt |

**Wichtig:** Da v4.0 ein kompletter Swift-Rewrite ist (kein gemeinsamer Code mit v3.x), ist GPL-3.0 für v3.x gut vertretbar.
**Entscheidung nötig vor dem ersten externen PR.**
**Status:** ✅ **ENTSCHIEDEN — GPL-3.0** (13.06.2026) — Begründung: Verhindert dass jemand den Code ohne Anerkennung kommerziell nutzt; passt zur "für immer Open Source / gratis"-Philosophie. v4.0 ist Swift-Rewrite → kein Konflikt.

---

### 📋 Geplant (nachträglich korrigierbar)

#### 3. README & Dokumentation
**Was rein muss (Reihenfolge):**
- [ ] Ein Satz was die App tut (keine technischen Begriffe)
- [ ] Screenshot oder 15-Sekunden-GIF des UIs
- [ ] Vergleichstabelle: AudioRouterNow vs. Loopback vs. SoundSource vs. BlackHole
- [ ] Install in 3 Zeilen (Download-Button + Homebrew-Befehl)
- [ ] Requirements (macOS-Mindestversion, Apple Silicon/Intel)
- [ ] Architektur-Diagramm (HAL-Plugin + C-Helper + Python-Engine) — schafft Vertrauen
- [ ] "What gets installed where" — HAL-Pfad, Helper, LaunchDaemon, Berechtigungen
- [ ] Troubleshooting-Abschnitt (coreaudiod, "App beschädigt"-Dialog)
- [ ] Uninstall-Anleitung
- [ ] Ehrlicher Hinweis: Solo-Projekt, Wartung in Freizeit

**Weitere Dateien:**
- [ ] `LICENSE`
- [ ] `CONTRIBUTING.md` (Build-Anleitung + "Issues vor PRs")
- [ ] `SECURITY.md` (E-Mail für Vulns)
- [ ] Issue-Templates (Bug Report + Feature Request)

---

#### 4. Release-Mechanismus
- [ ] **Notarization** — Apple Developer Account (99 $/Jahr) — notwendig da App HAL-Plugin + privilegierten Helper installiert. Apple Developer Account wird sowieso für v4.0 App Store gebraucht.
- [ ] **GitHub Release** — DMG + SHA256-Checksums, Tag `v3.4.0`
- [ ] **Homebrew Cask** — eigener Tap zuerst (`brew tap mauriciomorkun/tap`), später Migration zu `homebrew/cask`

---

#### 5. Sparkle (Auto-Updates)
Das Standard-Framework für automatische Updates in Nicht-App-Store-Mac-Apps.

**Optionen:**
- **Zum Launch:** User werden automatisch über neue Versionen informiert — professioneller Eindruck
- **Bei v3.5 nachliefern:** Launch nicht verzögern, erstmal ohne

**Appcast-Hosting:** Entweder auf `audiorouternow.mauriciomorkun.com/appcast.xml` oder direkt über GitHub Releases API.

**Status:** ✅ **ENTSCHIEDEN — zum Launch, inkl. Homebrew Cask** (13.06.2026)

---

#### 6. CI/CD
- **Stufe 1 (vor Launch):** GitHub Actions — Build auf PR, grünes Badge im README
- **Stufe 2 (nach Launch):** Tag → Build → Sign → Notarize → DMG → GitHub Release automatisch

---

#### 7. Community
- [ ] **GitHub Discussions aktivieren** — Kategorien: Q&A, Show your setup, Ideas
- [ ] **Issue-Templates** — Bug Report (macOS-Version, Audio-Setup, Logs) + Feature Request
- [ ] Kein Discord zum Launch — erst ab echter Community-Größe (>500 Stars)

---

#### 8. Discovery / Launch-Kanäle
**Reihenfolge:**

| Schritt | Kanal | Timing |
|---|---|---|
| 1 | awesome-Listen PRs (awesome-mac, open-source-mac-os-apps) | Sofort nach Launch (laufen asynchron) |
| 2 | **Show HN** ("Show HN: AudioRouterNow – free open-source audio routing for macOS") | ~1 Woche nach Launch, Di–Do |
| 3 | Reddit: r/macapps | ~1 Woche nach HN |
| 4 | Reddit: r/audioengineering, r/WeAreTheMusicMakers | ~2 Wochen nach Launch |
| 5 | Reddit: r/Twitch (Streamer-Use-Case) | ~2–3 Wochen nach Launch |
| 6 | YouTuber-Outreach (Mac-Audio/Streaming) | ~3–4 Wochen nach Launch |
| 7 | Product Hunt | Nachgelagert |

**Stärkster Pitch:** *"Free open-source alternative to Loopback (129 $)"*

---

#### 9. Buy Me a Coffee Integration
- [ ] BMC-Link in `README.md` (dezenter Abschnitt am Ende)
- [ ] BMC-Link in `.github/FUNDING.yml`
- [ ] Optional: Hinweis im "About"-Fenster der App
- **Kein Nag-Screen** — zerstört Goodwill bei der Zielgruppe

---

#### 10. Subdomain Landing Page
**URL:** `audiorouternow.mauriciomorkun.com`
**Hosting:** Auf bestehendem Server (`/opt/mauriciomorkun/`)

**Inhalte (Vorschlag):**
- Headline: kurz, kein Tech-Jargon
- Screenshot/Demo-GIF
- Download-Button (→ GitHub Release)
- Vergleich: "Kostenlos vs. Loopback 129 $"
- GitHub-Link
- Buy Me a Coffee Button

**Status:** ✅ **ENTSCHIEDEN — ausführlich, ohne Video** (13.06.2026)

---

#### 11. Timing & Launch-Sequenz
```
Woche 0:  Vorbereitung
          - History-Scan / Fresh Start
          - Lizenz festlegen
          - README + Screenshots/GIF
          - Issue-Templates, FUNDING.yml
          - CI-Build grün
          - Developer Account + Notarization
          - Landing Page live

Tag 1:    Repo public + v3.4.0 GitHub Release + Homebrew-Tap
          (Noch nicht auf HN/Reddit posten)

Tage 1-7: Quiet Period
          - 3-5 bekannte technische User testen
          - awesome-Listen PRs einreichen
          - Letzte README-Fixes

Tag ~7:   Show HN (Di-Do, vormittags)

Tage 8-21: Reddit gestaffelt
           YouTuber-Outreach

Tag ~30:  v3.4.1 Patch (Launch-Feedback) — zweite Sichtbarkeitswelle
```

---

## Nächste konkrete Schritte

- [ ] **Git-History-Entscheidung** treffen (Fresh Start vs. Scan)
- [ ] **Lizenz** festlegen (MIT vs. GPL-3.0)
- [ ] **Sparkle-Timing** entscheiden (Launch vs. v3.5)
- [ ] **Landing Page Scope** festlegen (minimal vs. ausführlich)
- [ ] Apple Developer Account prüfen (vorhanden? 99 $/Jahr)
- [ ] README-Entwurf beginnen (Screenshot/GIF als erstes)

---

## Verweis-Dokumente

- [`BACKLOG.md`](BACKLOG.md) — Feature-Ideen (Per-App-Routing, Council-Findings)
- [`RELEASE_NOTES.md`](RELEASE_NOTES.md) — v3.4.0 Changelog
- [`v4-appstore/PLAN.md`](v4-appstore/PLAN.md) — v4.0 App Store Architektur (Process Taps)
- [`PLAN.md`](PLAN.md) — Stability Hardening (abgeschlossen, historisch)

---

*Erstellt: 12. Juni 2026 — basierend auf Session-Diskussion inkl. LLM Council*
*Zuletzt aktualisiert: 12. Juni 2026*
