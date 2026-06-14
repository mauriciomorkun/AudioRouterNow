# AudioRouterNow v3.4.0 — Launch Execution Plan

> **Zweck:** Das *Wie* und *Wann*, nicht das *Was*. Entscheidungen stehen in [`LAUNCH_PLAN.md`](LAUNCH_PLAN.md).
> Hier: konkrete Reihenfolge, Abhängigkeiten, Parallelisierung, Wartezeiten, Risiken.
> Solo-Dev + Claude. Stand: 13.06.2026

---

## 🔔 Offene Entscheidungen (blockieren oder beeinflussen den Launch)

| Thema | Status | Entscheidung |
|-------|--------|--------------|
| **Sparkle Auto-Updates** | 🔴 **OFFEN — Mauricio entscheidet** | A) Jetzt (komplex, Python/PyInstaller) · B) v3.5 schieben · C) Swift-Wrapper |
| **Homebrew Cask** | ✅ Beschlossen: **JA, zum Launch** | Sobald Notarisierung + GitHub Release steht — Claude macht alles |
| **Landing Page URL** | ✅ `audiorouternow.mauriciomorkun.com` | |
| **Landing Page** | 🟡 **Placeholder live** | https://audiorouternow.mauriciomorkun.com ✅ · DNS + nginx + SSL fertig · Inhalt noch zu bauen |
| **Lizenz** | ✅ GPL-3.0 | |
| **Donations** | ✅ Buy Me a Coffee | |

> 🔔 **Sparkle-Entscheidung nicht vergessen!** Bei jeder Session nachfragen bis entschieden.

---

## 📋 Fortschritts-Log

### 13.06.2026 — Phase 1: Developer ID Signing Pipeline
**Status:** ✅ Abgeschlossen

#### Abgeschlossene Schritte:

**[13.06.2026 ~21:30 CEST] Landing Page — Placeholder + BMC Widget live**
- **Was:** Subdomain + Infrastruktur (DNS, nginx, SSL) + Placeholder-Seite + Buy Me a Coffee Widget eingebaut
- **BMC Widget Text:** "You route the coffee, I route the music ;) ♥" · Farbe #40DCA5 · Position rechts unten
- **Ergebnis:** https://audiorouternow.mauriciomorkun.com live mit HTTPS ✅ · BMC Widget sichtbar ✅ · Seite in `landing-page/index.html` versioniert
- **Offen:** Eigentliche Landing Page (Texte, Design, Screenshots) — vor Launch zu bauen

**[13.06.2026 ~21:00 CEST] Phase 3 — Community Files + Lizenz-Fix**
- **Was:** RELEASE_NOTES.md finalisiert (Datum 12→13.06., DOKUMENTATION.md-Referenz entfernt), Bundle-ID/Version-Konsistenzcheck aller 5 Quellen (alle ✅ `3.4.0`), Community Files erstellt, Lizenz MIT→GPL-3.0 gefixt
- **Erstellt:** `CONTRIBUTING.md`, `SECURITY.md`, `.github/FUNDING.yml`, `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`
- **Gefixt:** `LICENSE` (MIT→GPL-3.0 via curl gnu.org), `README.md` (Lizenz-Referenzen), `RELEASE_NOTES.md` (Datum + Footer)
- **Ergebnis:** Repo ist bereit für öffentliche Contributor (Issues, PRs, Security Reporting, Buy-Me-a-Coffee-Button) ✅

**[13.06.2026 ~17:19 CEST] Build 8 — Erste erfolgreiche Developer ID Signierung**
- **Problem:** PyInstaller 6.x erstellt in `Contents/Frameworks/` zwei Symlinks (`AudioRouterNow.driver` → `__dot__driver/`, `com.audiorouter.now.helper.plist` → `../Resources/...`) die codesign auf macOS 26 als unsigned nested bundles/non-code ablehnt. 6 fehlgeschlagene Builds davor.
- **Fix 1 — `installer/build.sh`:** Vollständige Symlink-Auflösung: `__dot__driver` → `AudioRouterNow.driver` umbenennen (echter Directory), Frameworks/-Symlinks entfernen, Symlinks im driver-Bundle auflösen, Storage-Bundle entfernen. Bottom-Up Developer ID Signing implementiert (Helper → Driver-Binary → .driver-Bundle → Executable → outer .app). Notarization + Stapling.
- **Fix 2 — `installer/AudioRouterNow.spec`:** Redundanten `(HELPER_PLIST, ".")` Eintrag aus `datas` entfernt — plist war bereits im driver-Bundle, der separate Eintrag erzeugte die problematische Datei in `Frameworks/`.
- **Ergebnis:** Signing ✅ · DMG erstellt (12MB) ✅ · DMG signiert ✅ · Bei Apple eingereicht ✅
- **Submission ID:** `ebd256de-71ed-4df3-ae11-5f4941e5369b`
- **Status Apple:** ✅ `Accepted` (14.06.2026 ~09:00 CEST — nach ~18h, vermutlich manueller Review wegen HAL-Treiber + Entitlements)
- **Stapling:** ✅ `xcrun stapler staple` erfolgreich — Ticket in DMG eingebettet
- **Validierung:** ✅ `spctl` → `accepted` / `source=Notarized Developer ID`
- **DMG:** `~/Desktop/AudioRouterNow.dmg` — bereit für GitHub Release
- **Commits:** `9012bba`, `f001254`

---

**Legende:**
`→ braucht X` = harte Abhängigkeit (blockiert) · `⟳ parallel` = kann gleichzeitig laufen · `⏳` = externe Wartezeit · `🔴` = Risiko/Showstopper · `🤖` = Claude kann's machen · `👤` = nur du (Account/Geld/Entscheidung)

---

## Kritischer Pfad (auf einen Blick)

```
Apple Dev Account ──► Notarization-Setup ──► erster notarisierter DMG ──► Sparkle-Signing ──► CI/CD ──► Release
   (👤 ⏳ 0–2 Tage)        (Tools/Cert)         (= Gating-Test)          (EdDSA-Key)      (Automatik)   (Tag)
```

**Der eine Showstopper:** Ohne fertige **Notarization** kein vertrauenswürdiger Download → keine Landing-Page-Buttons → kein HN-Post. Alles andere kann parallel laufen, aber der Notarization-Strang bestimmt das früheste Launch-Datum. **Diesen Strang zuerst starten** (Apple-Enrollment kann Stunden bis 2 Tage hängen).

---

## PHASE 0 — Gating & Account-Beschaffung
**Ziel:** externe Wartezeiten so früh wie möglich auslösen. **Zeit: ~30 Min Arbeit + ⏳ Wartezeit.**
**→ Diese Phase ZUERST, weil sie blockiert und Wartezeit hat.**

- [x] 👤 **Apple Developer Account** — ✅ `dev@mauriciomorkun.com`
- [x] 👤 **Team ID** — ✅ `5D52U34B3W`
- [x] 👤 **Developer ID Application Zertifikat** — ✅ installiert im Keychain (`MAURICIO MORAIS DA CUNHA`)
- [x] 👤 **App-specific Password** — ✅ gespeichert als `--keychain-profile "AudioRouterNow-Notarization"`
- [x] 🤖 **Bundle Identifier** — ✅ `com.audiorouter.now` (konsistent in allen Komponenten)
- [x] 👤 **Buy Me a Coffee** — ✅ `buymeacoffee.com/mauriciomorkun`
- [ ] 👤 **Server-Zugang prüfen** (`/opt/mauriciomorkun/`, DNS-Kontrolle für Subdomain) ⟳ parallel

> **Checkpoint 0:** Sobald das Apple-Enrollment durch ist → Phase 1 startet. Bis dahin laufen Phasen 2, 3, 4 (alles ohne Apple-Abhängigkeit) **parallel weiter** — keine Leerzeit.

---

## PHASE 1 — Signing & Notarization (kritischer Pfad)
**Ziel:** Ein DMG, das auf einem fremden Mac ohne "App ist beschädigt"-Dialog öffnet.
**→ braucht Phase 0 (Account + Team ID + App-specific PW). Zeit: ~1 Tag (viel Trial & Error).**

- [x] 👤 **Developer ID Application Certificate** — ✅ `MAURICIO MORAIS DA CUNHA (5D52U34B3W)` in Keychain
- [x] 👤 **Developer ID Installer Certificate** — nicht nötig, kein `.pkg` im Build
- [x] 🤖 **`installer/build.sh` auf Developer-ID-Signing umstellen** — ✅ Build 8 (13.06.2026). HAL-Driver + Helper + App mit Hardened Runtime + Timestamp signiert. PyInstaller-Symlink-Fix erforderlich.
- [x] 🤖 **`installer/entitlements.plist` für Hardened Runtime** — ✅ `allow-jit` + `allow-unsigned-executable-memory` + `disable-library-validation`
- [x] 🤖 **Signing-Reihenfolge im Build:** ✅ Bottom-Up: Helper → Driver-Binary → .driver-Bundle → Executable → outer .app → DMG
- [ ] 🤖 **Notarization-Submit-Script** — ⏳ `xcrun notarytool submit --wait` läuft seit 15:19 UTC. Submission `ebd256de` bei Apple **In Progress**.
- [ ] 🤖 **Stapling** (`xcrun stapler staple`) — ⏳ wartet auf Notarization-Ergebnis
- [ ] 👤 **🔴 GATING-TEST: DMG auf einem ZWEITEN Mac** (oder frischem User-Account) öffnen, installieren, Audio routen. → Das ist der Moment, der "Launch-ready" definiert. Erst wenn das clean durchläuft, ist Phase 1 fertig.

> **Risiko:** Notarization scheitert oft an Kleinigkeiten (fehlendes `--options runtime`, nicht-signierte Nested-Binaries, Python-Engine als unsignierter Inhalt). Plane **Puffer von 1–2 Iterationen** ein. Jede Iteration = ⏳ 5–30 Min Apple-Roundtrip.

---

## PHASE 2 — Repo-Hygiene & Fresh Start (parallel zu Phase 1)
**Ziel:** Sauberes Public-Repo, ein Initial-Commit, keine Secrets. ⟳ **komplett parallel zu Phase 0/1.**
**Zeit: ~2–3 Std.**

- [ ] 🤖 **`gitleaks` über aktuelle Working-Tree** laufen lassen (auch wenn Fresh Start — fängt Secrets in zu committenden Files)
- [ ] 🤖 **`.gitignore` prüfen** — `build_output`, `dist`, private Pfade, `.claude/` ausschließen
- [ ] 🤖 **Aufräumen vor Initial-Commit:** Interne Docs sichten — was ist public-tauglich?
  - Behalten: `README.md`, `LICENSE`, `RELEASE_NOTES.md`, `driver/`, `helper/`, `engine/`, `installer/`
  - 🔴 **Prüfen/entfernen:** `AUDIT_REPORT.md`, `PLAN.md` (69 KB intern), `LAUNCH_PLAN.md`, `LAUNCH_EXECUTION.md`, `BACKLOG.md`, `projekt.md`, Strategie/Roadmap-PDFs, `Bildschirmfoto*.png`, `v4-appstore/` → in privates Verzeichnis verschieben **oder** über `.gitignore` draußen halten
  - 🔴 **`DOKUMENTATION.md` (317 KB!)** — interne Vollchronik. Nicht roh public. Entweder kürzen oder ausschließen.
- [ ] 🤖 **Fresh-Start-Mechanik vorbereiten** (noch nicht ausführen): neuer Ordner / `git init` mit nur den public-tauglichen Files, ein Commit. → wird in Phase 5 scharf geschaltet
- [ ] 👤 **Leeres GitHub-Repo `audiorouternow` anlegen** (zunächst **privat** lassen)

> **Checkpoint 2:** Klare Liste "was geht ins Public-Repo, was bleibt privat". Dieser Cut ist irreversibel sichtbar → sorgfältig.

---

## PHASE 3 — Doc-, Community- & Funding-Files (parallel)
**Ziel:** README + Pflicht-Files, die ein OSS-Repo seriös machen. ⟳ **parallel zu Phase 1/2.**
**Zeit: ~3–4 Std (Screenshots/GIF sind der Engpass — manuell).**

- [ ] 👤 **Screenshot des Menübar-UIs** (sauberer Desktop, echtes Routing-Beispiel) — 🔴 **Engpass, nur du kannst's aufnehmen**
- [ ] 👤 **15-Sek-GIF** "App auf eigenes Gerät in 10 Sekunden" (Kap/Gifski) ⟳ parallel zum Screenshot
- [ ] 🤖 **README finalisieren** — existiert schon stark. Ergänzen:
  - Screenshot/GIF einbetten (→ braucht obige Assets)
  - Vergleichstabelle AudioRouterNow vs. Loopback vs. SoundSource vs. BlackHole
  - Install-3-Zeiler (Download-Button + `brew install --cask`)
  - Requirements (macOS-Min-Version, Apple Silicon/Intel)
  - Troubleshooting (coreaudiod, "beschädigt"-Dialog), Uninstall
  - Solo-Dev-Disclaimer + BMC-Abschnitt
- [ ] 🤖 **`CONTRIBUTING.md`** (Build-Anleitung + "Issues vor PRs")
- [ ] 🤖 **`SECURITY.md`** (Vuln-Kontakt-E-Mail)
- [ ] 🤖 **`.github/FUNDING.yml`** (Buy Me a Coffee)
- [ ] 🤖 **`.github/ISSUE_TEMPLATE/`** — Bug Report (macOS-Version, Audio-Setup, Logs) + Feature Request
- [ ] 🤖 **GPL-3.0 LICENSE verifizieren** (existiert — Inhalt = echter GPL-3.0-Text? prüfen)
- [ ] 🤖 **Architektur-Diagramm** (das ASCII-Diagramm im README ist gut — ggf. als Bild aufwerten)

> **Checkpoint 3:** README liest sich für einen Fremden in 30 Sek schlüssig. Test: jemandem zeigen.

---

## PHASE 4 — Landing Page (parallel)
**Ziel:** `audiorouternow.mauriciomorkun.com` live, ausführlich, ohne Video.
**⟳ parallel — aber Download-Buttons → brauchen Phase 5 (Release-URL).**
**Zeit: ~4–6 Std.**

- [ ] 👤 **DNS:** Subdomain `audiorouternow` → Server-IP, A/AAAA-Record ⏳ DNS-Propagation **bis ~1 Std** (meist Minuten)
- [ ] 🤖 **Landing Page bauen** (statisch, passend zum bestehenden `/opt/mauriciomorkun/`-Stack):
  - Headline ohne Tech-Jargon, Sub: "Free open-source alternative to Loopback (129 $)"
  - Screenshot/GIF (→ braucht Phase-3-Assets)
  - Vergleichstabelle (kostenlos vs. Loopback 129 $)
  - Feature-Abschnitte, "What gets installed where"
  - Download-Button (→ **Placeholder bis Phase 5**, dann auf GitHub-Release-URL)
  - GitHub-Link + Buy-Me-a-Coffee-Button
- [ ] 🤖 **TLS-Zertifikat** für Subdomain (Let's Encrypt/Caddy auf bestehendem Server)
- [ ] 🤖 **Meta/OG-Tags** (für schöne Vorschau in HN/Reddit/Twitter-Shares) — wichtig für Discovery-Phase
- [ ] 👤 **Deploy nach `/opt/mauriciomorkun/`** ⟳ parallel

> **Hinweis:** Page kann mit Placeholder-Download-Link **vorab** online gehen (noindex), Buttons werden in Phase 5 auf die echte Release-URL umgebogen.

---

## PHASE 5 — Sparkle, CI/CD & Homebrew (Konvergenz)
**Ziel:** Auto-Updates, automatischer Release-Build, Homebrew-Installation.
**→ braucht Phase 1 (funktionierendes Signing/Notarization als Baustein). Zeit: ~1 Tag.**

### 5a — Sparkle (Auto-Updates) → braucht Phase 1
- [ ] 🤖 **Sparkle ins App-Target integrieren** (rumps/Python-App → Sparkle-Anbindung klären; ggf. via nativem App-Wrapper)
- [ ] 👤/🤖 **EdDSA-Signing-Key generieren** (`generate_keys`) — 🔴 **Private Key sicher sichern** (Verlust = keine Updates mehr signierbar)
- [ ] 🤖 **`SUFeedURL` setzen** → Entscheidung: `audiorouternow.mauriciomorkun.com/appcast.xml` (empfohlen, volle Kontrolle) vs. GitHub-Releases
- [ ] 🤖 **`appcast.xml` generieren** + auf Server hosten (→ braucht Phase 4 Subdomain)
- [ ] 🤖 **Update-Test:** v3.4.0 erkennt fiktive v3.4.1 im Appcast und updated sauber

### 5b — CI/CD (GitHub Actions)
- [ ] 🤖 **Stufe 1 — Build-on-PR** (macOS-Runner, Build-Check) → grünes Badge. ⟳ kann früh parallel, braucht nur Repo
- [ ] 🤖 **Stufe 2 — Release-Pipeline:** Tag `v*` → Build → Sign → Notarize → Staple → DMG → SHA256 → GitHub Release + Appcast-Update
- [ ] 👤 **GitHub Secrets setzen:** Developer-ID-Cert (base64), Cert-PW, App-specific PW, Team ID, Sparkle-EdDSA-Key 🔴 → braucht Phase 0 + 5a
- [ ] 🤖 **Pipeline einmal end-to-end auf Test-Tag** (`v3.4.0-rc1`) durchlaufen lassen ⏳ inkl. Notarization-Wartezeit

### 5c — Homebrew Cask → braucht ersten echten GitHub-Release
- [ ] 👤 **Eigenen Tap-Repo `homebrew-tap` anlegen**
- [ ] 🤖 **Cask-Formula schreiben** (URL → GitHub-Release-DMG, SHA256, `auto_updates true` wegen Sparkle)
- [ ] 👤 **`brew install --cask mauriciomorkun/tap/audiorouternow` auf sauberem Mac testen** 🔴 → braucht Phase 6 Release-Artefakt
- [ ] 📋 **`homebrew/cask`-PR** = später, nicht launch-blockierend (eigener Tap reicht zum Launch)

> **Checkpoint 5:** `git tag v3.4.0 && git push --tags` produziert vollautomatisch einen signierten, notarisierten, gestapleten DMG-Release. Das ist das technische Launch-Gate.

---

## PHASE 6 — Soft Launch (Tag 1)
**Ziel:** Repo public + Release live — **aber noch keine laute Promotion.**
**→ braucht alle Phasen 1–5 grün. Zeit: ~2 Std + Quiet Period.**

- [ ] 👤 **Repo auf public schalten** (Fresh-Start-Commit pushen)
- [ ] 👤 **v3.4.0 GitHub Release veröffentlichen** (DMG + SHA256, Release Notes aus `RELEASE_NOTES.md`)
- [ ] 🤖 **Landing-Page-Download-Buttons** auf echte Release-URL umbiegen + noindex entfernen → braucht Phase 4
- [ ] 👤 **Homebrew-Tap-Cask live & getestet** → braucht Release-DMG (Phase 5c)
- [ ] 🤖 **GitHub Discussions aktivieren** (Q&A, Show your setup, Ideas)
- [ ] 🔴 **Final-Install-Test komplett von vorn** auf einem Mac, der die App nie hatte: Download von Landing Page → install → notarisiert öffnet → Audio routet → Sparkle meldet "aktuell". **Erst danach laut werden.**

> **Quiet Period (Tag 1–7):** 3–5 bekannte technische User testen lassen. Letzte README-Fixes. **awesome-Listen-PRs einreichen** (laufen asynchron, ⏳ Merge dauert Tage–Wochen, daher früh starten).

---

## PHASE 7 — Discovery / Promotion (gestaffelt, ab ~Tag 7)
**Ziel:** Sichtbarkeit, ohne alles auf einen Tag zu verbrennen. **Zeit: über ~4 Wochen verteilt.**

- [ ] 📋 **awesome-Listen-PRs** (awesome-mac, open-source-mac-os-apps) — **sofort ab Tag 1**, asynchron ⏳
- [ ] 👤 **Show HN** ~Tag 7, **Di–Do vormittags** (US-Zeit beachten): *"Show HN: AudioRouterNow – free open-source audio routing for macOS"* 🔴 **einmaliger Schuss — Page/Repo müssen perfekt sein, du musst den Tag über für Kommentare da sein**
- [ ] 👤 **Reddit r/macapps** ~Tag 8 → braucht HN-Erfahrung/Feedback eingearbeitet
- [ ] 👤 **Reddit r/audioengineering, r/WeAreTheMusicMakers** ~Tag 14
- [ ] 👤 **Reddit r/Twitch** (Streamer-Use-Case) ~Tag 14–21
- [ ] 👤 **YouTuber-Outreach** (Mac-Audio/Streaming) ~Tag 21–30
- [ ] 📋 **Product Hunt** — nachgelagert
- [ ] 🤖 **v3.4.1 Patch** ~Tag 30 (Launch-Feedback einsammeln) → zweite Sichtbarkeitswelle + erster echter Sparkle-Auto-Update-Test in the wild

---

## Parallelisierungs-Übersicht

| Während du wartest auf… | …läuft parallel |
|---|---|
| ⏳ Apple-Enrollment (Phase 0) | Phase 2 (Repo-Hygiene), Phase 3 (Docs), Phase 4 (Landing-Page-Gerüst) |
| ⏳ Notarization-Roundtrips (Phase 1) | Phase 3-Feinschliff, Phase 5b CI-Stufe-1, Phase 4-Content |
| ⏳ awesome-Listen-Merge (Phase 7) | Quiet-Period-Tests, README-Fixes |

**Engpässe, die NUR du kannst (👤, nicht delegierbar):** Apple-Enrollment, Zertifikate, Screenshot/GIF, Zweit-Mac-Tests, Repo-public-schalten, HN/Reddit-Posts.
**Alles andere (🤖):** Scripts, README, Landing-Page-Code, CI-YAML, Cask-Formula, Appcast — kann Claude bauen, während du an den 👤-Tasks sitzt.

---

## Top-Risiken & Wartezeiten

1. 🔴 **Notarization scheitert an unsignierten Nested-Binaries** (Python-Engine, Helper, Driver). Wahrscheinlichster Zeitfresser. → Phase 1 früh & isoliert testen, nicht erst kurz vor Launch.
2. 🔴 **Sparkle + Python/rumps-App** ist unüblich (Sparkle ist für native Cocoa-Apps). Integration könnte einen App-Wrapper erfordern. → früh einen Spike machen; wenn zu komplex, ggf. doch auf v3.5 schieben (Entscheidung war "zum Launch", aber das ist der riskanteste Punkt).
3. 🔴 **Secrets in alten/internen Docs** (DOKUMENTATION.md, PLAN.md, PDFs). Fresh Start hilft, aber der File-Cut muss bewusst sein.
4. ⏳ **Apple-Enrollment 0–2 Tage** — deshalb Phase 0 als allererstes.
5. ⏳ **Notarization 5–30 Min pro Submit** × mehrere Iterationen.
6. 🔴 **HN-Launch ist einmalig** — kein zweiter Versuch mit gleichem Titel. Erst posten, wenn Phase 6 Final-Test 100% clean.

---

## Frühestes realistisches Launch-Datum

- **Best Case** (Account sofort durch, Notarization 1. Versuch, Sparkle reibungslos): Repo public **Tag 4–5**, Show HN **Tag ~12**.
- **Realistisch** (1–2 Notarization-Iterationen, Sparkle-Spike): Repo public **Tag 7–9**, Show HN **Tag ~16**.
- **Engpass-bestimmend:** Phase 1 (Notarization) + Phase 5a (Sparkle). Beides früh angehen.

---

*Erstellt: 13.06.2026 — Execution-Layer zu LAUNCH_PLAN.md*
