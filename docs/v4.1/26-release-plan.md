# AudioRouterNow 4.1: Release-Plan (Weg bis zur Einreichung)

Stand 2026-11-17. Geschrieben aus dem tatsaechlichen Repo- und Dokumentationsstand
auf `release/4.1`. Belege stehen in eckigen Klammern (Datei, Befehl, Zeile).
Was nicht belegbar ist, steht als OFFEN oder NICHT PRUEFBAR mit Grund. Kein
Zugriff auf Apple-Konten, keine Rechtsberatung. Diese Datei aendert nichts am
Code, an `landing-page/`, bei GitHub oder auf Servern, und committet nichts.

---

## 1. Kurzfassung

> **Nachtrag 23.11.2026:** Die Messpunkte (Voraussetzung (b) unten, Abschnitt 4(e)) sind
> durchgeführt, keiner fiel negativ aus (`27-messprotokoll.md`, `09-final-report.md`
> Abschnitt 12). "Nicht am Gerät verifiziert" in dieser Kurzfassung gilt für den Stand
> vom 18.11.2026. Offen blieben die Zusatzzeilen (der CPU-Vergleich mit 4.0.1 ist am
> 23.11.2026 erledigt, kein Unterschied), siehe den Nachtrag am Ende dieser Datei.

- 4.1 (Version 4.1, Build 11) liegt fertig und auditiert auf `release/4.1`,
  **65 Commits vor `main`** [git rev-list --count main..HEAD], plus unverbuchter
  Arbeitsbaum (8 geaenderte, 7 neue Dateien) fuer die am 17.11. entschiedene
  UI-Variante C3/V2 [git status --short]. Nichts gepusht, kein Tag `v4.1`,
  nicht eingereicht, nicht am Geraet verifiziert.
- Blockierend bis zur Einreichung, in dieser Reihenfolge: (a) unverbuchten
  Arbeitsbaum committen, (b) Messpunkte am Geraet (M1 bis M9, M2b/M2c/M2d, NM-1
  bis NM-7), (c) neues 4.1-Archiv bauen und signieren, (d) Texte in App Store
  Connect, (e) Datum setzen, Tag, Merge, Push, Einreichung.
- Preflight meldet heute **1 ABBRUCH** (letztes Archiv ist 4.0.1 (10), erwartet
  4.1 (11)) und 3 Warnungen; der ABBRUCH verschwindet erst, wenn ein 4.1-Archiv
  gebaut ist [v4/scripts/preflight.sh].
- Architektur **BELEGT**: das v4-Binary ist **universal (x86_64 arm64)**, sowohl
  in der Store-App 4.0.1 als auch in der 4.1-Test-App; `v4/project.yml` setzt kein
  `ARCHS` (Xcode baut Default universal) [lipo -archs, 17.11.2026]. Fuer 4.1
  **Option A empfohlen** (Status quo universal belassen, Doku ehrlicher fassen
  statt arm64-only zu erzwingen), Begruendung in Abschnitt 4(a).
- Kuerzester sicherer Weg: committen, Messpunkte durchgehen, Archiv bauen und
  signieren, Preflight gruen (nur Warnungen), Texte setzen, Datum setzen, Tag,
  Merge nach `main`, Push, Einreichung. Jeder unumkehrbare Schritt ausschliesslich
  auf ausdrueckliche Anweisung des Nutzers.

---

## 2. Ist-Stand (belegt)

### 2.1 Arbeitsbaum

`git status --short` auf `release/4.1`:

| Datei | Zustand | Gehoert zu |
|-------|---------|-----------|
| `v4/AudioRouterNow4/MenuBarView.swift` | geaendert (72 Zeilen) | P1 ScrollView/Header, C3-Footer-Umbau |
| `v4/AudioRouterNow4/UI/DeviceCardView.swift` | geaendert (45 Zeilen) | Solo-Button, V2 Add-device-Kennzeichnung |
| `v4/AudioRouterNow4/UI/RoutingControls.swift` | geaendert (361 Zeilen) | C3 Footer, Support-Pille, Hover-Bubbles, oberer Start/Stop-Knopf |
| `v4/AudioRouterKit/Sources/AudioRouterKit/AddDeviceMenuModel.swift` | neu | V2 Add-device-Menuemodell (Kennzeichnung, Filter) |
| `v4/AudioRouterKit/Sources/AudioRouterKit/FooterTips.swift` | neu | C3 Hover-Erklaerungen (testbare Texte im Kit) |
| `v4/AudioRouterKit/Tests/AudioRouterKitTests/AddDeviceMenuModelTests.swift` | neu | Tests V2 |
| `v4/AudioRouterKit/Tests/AudioRouterKitTests/FooterTipsTests.swift` | neu | Tests C3 FooterTips |
| `.gitignore` | geaendert (+3) | `docs/homepage-redesign/` ausnehmen |
| `CHANGELOG.md` | geaendert | wird vom parallelen Doku-Agenten aktualisiert |
| `docs/v4.1/09-final-report.md` | geaendert | dto. |
| `docs/v4.1/13-doc-inventory.md` | geaendert | dto. |
| `docs/v4.1/README.md` | geaendert | dto. |
| `docs/v4.1/23-ui-start-button-oben.md` | neu | UI-Vergleich C/C2/C3 |
| `docs/v4.1/24-audit-ui-c3.md` | neu | Audit C3 |
| `docs/v4.1/25-add-device-liste.md` | neu | Audit/Analyse V2 Add-device |

Anmerkung: CHANGELOG, 09-final-report, 13-doc-inventory und README werden parallel
von einem Doku-Agenten bearbeitet (Entscheidung C3/V2). Dieser Plan fasst sie
nicht an.

Der UI-/V2-Code (C3b) liegt damit noch **unverbucht** vor; der auditierte
Kern-4.1-Stand (ScrollView, Solo, SR-Listener, Blip, maxSlots=256, WaveEnergy
Solo-neutral) ist bereits committet [09-final-report, Abschnitt 3; v41_status.md].

### 2.2 Teststand (selbst ausgefuehrt)

- `bash v4/scripts/test.sh`: **60 swift-testing in 10 Suiten, alle gruen**
  (selbst ausgefuehrt am 17.11.2026). `git status --short` davor und danach gleich.
- Die **129 XCTest** sind aus der Doku belegt [v41_status.md, Abschnitt Tests:
  "60 swift-testing plus 129 XCTest gruen"; 24-audit-ui-c3.md, 25-add-device-liste.md],
  in diesem Lauf nicht separat ausgefuehrt (XCTest laeuft ueber das App-Target,
  nicht ueber `test.sh`, das nur das SPM-Kit testet). Die 129 enthalten die neuen
  FooterTips- und AddDeviceMenuModel-Faelle.
- App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) laut Audits erfolgreich
  [09-final-report, Zeile 453, 471, 529].

### 2.3 Commits ahead of main

- `git rev-list --count main..HEAD` = **65** (Stand 15.11. in der Doku: 63; die
  zwei zusaetzlichen stammen aus den UI-Nachtrag-Commits).
- Keine Merge-Commits auf `release/4.1` [git log --merges main..HEAD: leer].
- Keine `v4.1`-relevanten Tags vorhanden [git tag: nur v2.7.0 bis v3.4.6, v4.0.0,
  v4.0.1].

### 2.4 Test-Apps auf dem Desktop

[ls ~/Desktop]: `AudioRouterNow 4.1 TEST.app`, `... TEST (neu).app`, `... TEST C2.app`,
`... TEST C3.app`, `... TEST C3 LISTE.app`, `... TEST C3b.app`, dazu
`ARN-4.1-TEST-LIES-MICH.txt`. **C3b** ist der Stand der entschiedenen Variante,
**C3 LISTE** ist die Pruefhilfe fuer die Scrollbarkeit des Add-device-Menues
(120 kuenstliche Eintraege) [M2d in 09-final-report]. Diese sind ad-hoc signierte
Testbuilds, kein Store-Build.

### 2.5 Xcode-Archive

[ls ~/Library/Developer/Xcode/Archives]: Ordner bis `2026-10-07`. Das juengste
Archiv ist `AudioRouterNow4 07-10-2026, 17.55.xcarchive` = **4.0.1 (10)**
[preflight Abschnitt 6]. **Es existiert kein 4.1-Archiv.** Das ist der Grund fuer
den Preflight-ABBRUCH.

---

## 3. Commit-Plan (Vorschlag, nichts committen)

Ziel: den unverbuchten Arbeitsbaum in sinnvolle Conventional Commits aufteilen, so
dass jeder Commit baut und die Tests gruen bleiben. Kit-Paket und App-Target nicht
auseinanderreissen, wenn eins vom anderen abhaengt. Die vom Doku-Agenten
bearbeiteten Dateien (CHANGELOG, 09, 13, README) sind **dessen** Commit, nicht
Teil dieses Plans; hier nur die UI-/V2-Code- und die drei neuen Doku-Dateien.

Abhaengigkeiten [aus diff und Dateilage]: `RoutingControls.swift` (C3 Footer) liest
`FooterTips` aus dem Kit; `MenuBarView`/`DeviceCardView` (V2) lesen
`AddDeviceMenuModel` aus dem Kit. Kit-Datei und die darauf zugreifende View
gehoeren deshalb in **denselben** Commit, sonst baut der Zwischenstand nicht.

| # | Dateien | Typ und Nachricht (Vorschlag) | Warum zusammen |
|---|---------|-------------------------------|----------------|
| 1 | `v4/.../AudioRouterKit/Sources/.../FooterTips.swift`, `.../Tests/.../FooterTipsTests.swift`, `v4/AudioRouterNow4/UI/RoutingControls.swift`, `v4/AudioRouterNow4/MenuBarView.swift` (C3-Footer-Teil) | `feat(ui): Variante C3 (oberer Start/Stop-Knopf, Support-Pille, Hover-Bubbles)` | View liest `FooterTips`; ohne die Kit-Datei baut die View nicht |
| 2 | `v4/.../AudioRouterKit/Sources/.../AddDeviceMenuModel.swift`, `.../Tests/.../AddDeviceMenuModelTests.swift`, `v4/AudioRouterNow4/UI/DeviceCardView.swift`, `v4/AudioRouterNow4/MenuBarView.swift` (V2-Teil) | `feat(ui): V2 Add-device kennzeichnet bereits hinzugefuegte Ausgaben` | View liest `AddDeviceMenuModel`; gleiche Abhaengigkeit |
| 3 | `.gitignore` | `chore(gitignore): docs/homepage-redesign/ ausnehmen (intern)` | eigenstaendig, kein Code |
| 4 | `docs/v4.1/23-ui-start-button-oben.md`, `24-audit-ui-c3.md`, `25-add-device-liste.md` | `docs(v4.1): UI-Vergleich C3, Audit C3, Add-device-Liste V2` | reine Doku |

Hinweis: `MenuBarView.swift` beruehrt sowohl C3 (Footer) als auch V2 (Add-device).
Laesst sich die Datei nicht sauber auf Commit 1 und 2 aufteilen (eng verzahnte
Hunks), gehoeren Commit 1 und 2 zu **einem** Commit `feat(ui): Bedienoberflaeche
C3 plus V2 (Add-device-Kennzeichnung)` zusammengefasst; Vorrang hat, dass jeder
Commit baut. Vor dem Aufteilen `git add -p` je Datei pruefen; nur benannte Dateien
`git add` [CLAUDE.md, Auto-Commit-Regel]. Conventional Commits, Co-Author-Zeile.
Kein Push ohne Anweisung.

Reihenfolge: 3, 4, dann 1, 2 (oder der zusammengefasste UI-Commit). So ist der
Code-Commit der letzte und laesst sich isoliert bauen und testen.

---

## 4. Voraussetzungen vor dem Archiv

### (a) E2: Architektur (ARCHS arm64 vs universal)

**Fakten aus BACKLOG.md** (Abschnitt "Intel-Unterstuetzung fuer v3"): Der Befund
betrifft **v3** (PyInstaller, `target_arch=None` in `legacy-v3/installer/
AudioRouterNow.spec:87`), nicht die v4-App-Store-App. Fuer v3 gilt: das Projekt
baut universal und wirft die Intel-Haelfte im letzten Schritt selbst weg; es gibt
keine Messung, dass ein Universal-Buendel auf Intel startet, und keinen
Intel-Testrechner. "`target_arch` wird nicht geaendert." [BACKLOG].

**Fuer v4 BELEGT (am 17.11.2026 selbst gemessen):** Das v4-Binary ist **universal
(x86_64 arm64)**, nicht arm64-only. Gemessen an der installierten Store-Version und
an der aktuellen Test-App:

| Was | Messung |
|-----|---------|
| Store-App 4.0.1 `lipo -archs /Applications/AudioRouterNow4.app/Contents/MacOS/AudioRouterNow4` | `x86_64 arm64` |
| Store-App Version (`CFBundleShortVersionString`) | `4.0.1` |
| Test-App C3b `lipo -archs` (`AudioRouterNow 4.1 TEST C3b.app`) | `x86_64 arm64` |
| C3b `LSMinimumSystemVersion` | `14.4` |
| `ARCHS` in `v4/project.yml` | **nicht gesetzt** [grep ARCHS: kein Treffer] |

Weil `v4/project.yml` kein `ARCHS` setzt, baut Xcode den **Default universal**. Der
ausgelieferte 4.0.1-Stand und der aktuelle 4.1-Stand sind beide universal.
`BACKLOG.md` dokumentiert dieselbe Messung am Build 9 [BACKLOG, Abschnitt
Intel-Unterstuetzung; die dortige v3-Analyse betrifft PyInstaller in `legacy-v3/`,
die Buendel-Messung deckt sich mit der hiesigen v4-Messung]. Das Deployment-Target
ist macOS 14.4 [v4/project.yml, `deploymentTarget.macOS: "14.4"`].

Damit ist die fruehere Aussage "OFFEN, ob arm64-only oder universal" **falsch** und
durch **BELEGT universal** ersetzt. Der in Memory vermerkte "Widerspruch universal
gegen Apple Silicon only" loest sich zugunsten von universal auf: das Binary ist
universal, die Zusage "Apple Silicon only" in Doku und Seite ist die **ungenaue**
Seite des Widerspruchs.

**Folgen fuer bestehende Nutzer:** Da 4.0.1 universal ausgeliefert wird, koennten
Intel-Nutzer mit macOS 14.4+ 4.0.1 technisch bekommen haben (ob der App Store sie
als kompatibel fuehrt, ist nur im Portal belegbar, **OFFEN**, kein Apple-Zugang).
Ob es tatsaechlich Intel-Nutzer gibt, ist **ungemessen**. Entscheidend fuer 4.1:
ein Wechsel auf arm64-only waere eine **Aenderung** gegenueber dem Ist-Zustand und
wuerde solche Nutzer (falls vorhanden) von kuenftigen Updates abschneiden.

**Die Entscheidung fuer 4.1, als zwei klare Optionen:**

- **(A) Status quo universal beibehalten.** Keine Build-Aenderung fuer 4.1 (kein
  `ARCHS` setzen). Intel bleibt ungetestet. Konsequenz: Doku und Seite duerfen
  **keine** Intel-Unterstuetzung **zusagen**; "Requires Apple Silicon" sollte
  ehrlicher lauten, Vorschlag "Developed and tested on Apple Silicon; Intel not
  tested". Das ist eine **Textanpassung ohne Code**. Niemand wird von Updates
  abgeschnitten.
- **(B) `ARCHS = arm64` setzen.** Die Doku "Apple Silicon only" wird wahr, das
  Bundle wird kleiner. Aber: Aenderung am ausgelieferten Binary; bestehende
  Intel-Nutzer mit macOS 14.4+ bekommen **kein 4.1** mehr. Auswirkung auf die
  App-Store-Verfuegbarkeit ist im Portal zu pruefen (**OFFEN**, kein Apple-Zugang).

**Doku-Stellen, die je nach Wahl stimmen oder berichtigt werden muessen:** die
Homepage (`index.html`, Hero "Apple Silicon (arm64)") und der Homepage-Punkt E2
[docs/homepage-redesign/04-umsetzungspaket.md: "Variante A unveraendert, erst aendern
wenn ARCHS-Entscheidung im Code getroffen ist"]; die App-Store-Description. Bei (A)
sind diese Stellen auf eine ehrlichere Formulierung anzupassen (Text, kein Code);
bei (B) werden sie durch die Build-Aenderung wahr.

**Einschaetzung (als Einschaetzung gekennzeichnet):** fuer 4.1 **Option A**. 4.1 ist
ein UI- und Stabilitaetsrelease; B fuehrt ein neues Risiko ein (Nutzer vom Update
abschneiden, Verfuegbarkeit ungeprueft) ohne Gewinn fuer den Release-Zweck. Eine
Architektur-Zusage in beide Richtungen ohne Intel-Test waere die Art Fehler, die
CASE-005 korrigiert hat; A vermeidet die Zusage, statt sie umzukehren, und laesst
den seit 4.0.1 ausgelieferten Zustand unangetastet. Die einzige unter A noetige
Arbeit ist die ehrlichere Textformulierung. Aufwand A: gering (nur Text). Aufwand B:
Build-Aenderung plus Portal-Pruefung, Nutzen gering.

### (b) Signierung in `v4/project.yml`

**Dokumentierter Weg von 4.0.1:** Beim 4.0.1-Lauf fehlten `DEVELOPMENT_TEAM`,
`CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY` in `project.pbxproj`; Xcode loeste das
Signieren zur Build-Zeit aus dem angemeldeten Account. Das Oeffnen des richtigen
Projekts liess Xcode die Werte schreiben, Commit `1a8257a` hat sie festgehalten
[docs/v4.0.1/08-submission-log.md, "Side finding: signing lived outside the
repository"]. **Caveat nicht geschlossen:** die Werte stehen in `project.pbxproj`,
**nicht** in `v4/project.yml`; ein `xcodegen`-Lauf wuerde sie wieder verwerfen
[ebd.; CLAUDE.md]. In `v4/project.yml` finden sich nur `CODE_SIGN_ENTITLEMENTS`
und `ENABLE_HARDENED_RUNTIME`, keine Team-/Identity-Angaben [grep in project.yml].

**Vor 4.1 zu setzen:** entweder (1) Signierung dauerhaft in `v4/project.yml`
eintragen (die durable fix laut 4.0.1-Doku), oder (2) vor dem Archiv **kein**
`xcodegen generate` laufen lassen, damit die in `project.pbxproj` liegenden Werte
erhalten bleiben. Variante (1) ist die robustere. Pruefen: nach dem Generieren
`grep DEVELOPMENT_TEAM project.pbxproj` nicht leer. Wer: Nutzer (Xcode/yml).
Aufwand: gering, aber unbedingt vor dem Archiv.

### (c) `v4-appstore/` (594 MB, toter Baum)

**Fakten:** 594 MB [du -sh], **0 getrackte Dateien** [git ls-files v4-appstore:
leer], enthaelt ein zweites Xcode-Projekt gleichen Namens mit 4.0.0 (7). Hat am
01.10.2026 das falsche Archiv erzeugt (114 dSYM-Pfadverweise auf `v4-appstore`)
[08-submission-log]. Seit 4.0.1 live und beide Tags gesetzt ist das Entfernen
**gefahrlos** [v4_tags_pending.md, Nachtrag 14.11.].

**Empfehlung:** vor dem 4.1-Archiv **umbenennen** (umkehrbar) statt loeschen, z.B.
nach `_attic-v4-appstore/`. Risiko bei Belassen: dieselbe Verwechslungsgefahr im
Organizer wie 2026-10-01. Risiko beim Loeschen: keines mehr (untracked, getaggt),
nur unwiederbringlich; darum zuerst umbenennen. Der Preflight warnt, solange der
Ordner existiert [preflight Abschnitt 1]. Wer: Nutzer. Aufwand: Minuten. Nur auf
Anweisung (Dateisystemaenderung).

### (d) Preflight-Ergebnis (heute) und was 4.1 braucht

`bash v4/scripts/preflight.sh` am 17.11.2026, danach `git status --short`
unveraendert:

| Pruefung | Ergebnis |
|----------|----------|
| 1 Projektbaum | **WARNUNG** `v4-appstore/` existiert (zweites Projekt 4.0.0 (7)) |
| 2 Version | **OK** xcconfig sagt 4.1 (11); keine zweite Versionsquelle |
| 3 Build gegen Tags | **OK** Tag `v4.1` existiert noch nicht |
| 4 Arbeitsbaum | **WARNUNG** nicht committete Aenderungen; **WARNUNG** Commits nicht gepusht |
| 5 Berechtigungen | **OK** App Sandbox aktiv; Audio Input vorhanden |
| 6 Letztes Archiv | **ABBRUCH** Archiv ist 4.0.1 (10), erwartet 4.1 (11); OK Archiv stammt aus v4/ |

Ergebnis: **1 Abbruchgrund, 3 Warnungen. Exit 1.** Fuer 4.1 braucht der Preflight:
ein frisch gebautes **4.1 (11)**-Archiv (behebt den ABBRUCH), einen **sauberen,
committeten Arbeitsbaum** (behebt WARNUNG 4a), und idealerweise das entfernte
`v4-appstore/` (behebt WARNUNG 1). Die Warnung "nicht gepusht" bleibt bis zum
bewussten Push bestehen und ist unkritisch. Nach dem Archiv ist Preflight erneut
zu fahren [09-final-report Abschnitt 8, Schritt 5].

### (e) Messpunkte am Geraet (M1 bis M9, NM-1 bis NM-7)

Durchfuehrung mit der Test-App **TEST C3b** (Bundle-ID endet auf `.test`), die
Store-Version vorher **beenden** (sonst zwei Instanzen). Keine Messung wurde von
einem Agenten gemacht; die Ergebnis-Spalten sind leer [09-final-report Abschnitt 7].

Reihenfolge nach Prioritaet/Dauer (Vorschlag), mit Hardware-Hinweis:

| Reihenfolge | ID | Thema | Dauer | Hardware |
|-------------|----|-------|-------|----------|
| 1 | M1 | ScrollView 45+ Zeilen, Panel passt auf 13" | ~10 min | BlackHole 64ch + Interface (z.B. Scarlett) |
| 2 | M2 | Oberer Start/Stop-Knopf schaltet in allen Zustaenden | ~5 min | 1 Geraet |
| 3 | M2b | Knopfoptik oben und Footer, VoiceOver | ~10 min | 1 Geraet, VoiceOver |
| 4 | M2c | Hover-Erklaerungen (Clamping an beiden Raendern, Maus und Trackpad) | ~10 min | Maus + Trackpad |
| 5 | M2d | Add-device scrollbar (Pruefhilfe C3 LISTE) und Kennzeichnung (C3b) | ~10 min | Mehrkanalgeraet; Scrollbarkeit per Pruefhilfe (bereits vom Nutzer am 17.11. bestaetigt, s.u.) |
| 6 | M9 | Peak-Meter unter Solo = 0 | ~5 min | 2 Ausgaben |
| 7 | M3 | Solo ohne Knacksen, Reglerwert bleibt | ~10 min | 2+ Ausgaben, Musik |
| 8 | M4 | Solo bei abgestecktem Geraet | ~5 min | 2 Ausgaben |
| 9 | M7 | Warm-Restart bei echtem Rate-Wechsel | ~10 min | Interface mit umschaltbarer Rate (z.B. Komplete Audio 6) |
| 10 | M8 | Blip-Absorption (Kabel kurz loesen) | ~10 min | USB-Geraet. **Regel M8 negativ: Commit `5798a63` umkehren** [09-final-report Z. 312, 326] |
| 11 | M6 | Noop-Rate SR-Listener | 15+ min Laufzeit | 1 Geraet, `log stream` |
| 12 | M5 | Grenze maxSlots (ueber 16/32 Ausgaben) | ~15 min | **Schwer: 17+ echte Ausgaben.** Siehe unten |
| 13 | NM-1..NM-7 | Hoerpruefung ueber 16/32, CPU, CoreAudio-Stabilitaet bei 128-256 Kanalpaaren, Speicher | 30-45 min | BlackHole 64ch, vgl. M5 |

**Geschaetzte Gesamtzeit:** rund **2,5 bis 3,5 Stunden** am Geraet (M6 laeuft
nebenher 15 min).

**Hardware-Engpass M5 (und NM):** 17 echte Geraete sind nicht noetig. Die
Pruefanleitung nutzt **BlackHole 64ch** (ein virtuelles Geraet mit 32 Kanalpaaren)
plus ein Interface, um 45+ Zeilen zu erzeugen [09-final-report M5 (neu), Z. 428].
Fuer die reine Kapazitaetsgrenze nennt die Anleitung ein **lokales Experiment**:
Konstante `OutputLimits.maxSlots` temporaer auf 20 senken (nicht committen), 19
Ausgaben waehlen, eine weitere versuchen, danach zuruecksetzen [ebd.].

**Bereits vom Nutzer gesehen (17.11.):** Scrollbarkeit des Add-device-Menues per
Pruefhilfe `TEST C3 LISTE` (LISTE-Hilfe, 120 Eintraege) und die Duplikat-/
Kennzeichnung in C3b [CLAUDE.md, Erinnerungsblock; M2d-Beleg per NSMenu-Probe, nicht
am echten SwiftUI-Menue getestet, 25-add-device-liste.md]. M2d bleibt am echten
Menue noch zu bestaetigen.

### (f) Neue App-Store-Screenshots

**Was die Doku zeigt:** `06-appstore-texts.md` beschreibt nur Texte, **keine**
Screenshot-Anforderungen. Fuer 4.0.1 steht in der Submission-Doku kein
Screenshot-Satz; die 4.0.1-Phasenliste nennt Screenshots nicht. **Aufloesung und
Anzahl, die App Store Connect verlangt: OFFEN, im Portal pruefen** (nicht aus der
Doku belegbar, kein Apple-Zugang).

**Welche Screens zeigen die alte Optik und muessen neu:** Jeder Screenshot, der die
**Statuszeile mit dem alten nackten Icon-Button** oder den **alten Footer** (Pille
unten) zeigt, ist durch C3 ueberholt (oberer gefuellter Start/Stop-Knopf, einzeiliger
Footer mit Support-Wort-Pille) [09-final-report Nachtrag C3]. Einschaetzung: neue
Screenshots fuer den Hauptscreen (Panel mit Liste, oberer Knopf, Footer) anfertigen,
sofern die alten diese Elemente zeigen. Wer: Nutzer (oder Claude baut die Vorlage
aus der Test-App). Aufwand: mittel.

### (g) App-Store-Connect-Texte

Stand `docs/v4.1/06-appstore-texts.md`: **Entwuerfe fertig** (What's New ~1103
Zeichen, Review-Notiz, Ersatzsatz fuer den Superlativ) [09-final-report 3.6; Audit 2].

- **Description:** den Superlativ-Satz ("the only sandboxed ...") in App Store
  Connect ersetzen durch "AudioRouterNow runs fully sandboxed. No kernel extension.
  No virtual driver. No reboot." [06-appstore-texts Abschnitt 3]. Steht nur im
  Portal, nicht im Repo.
- **What's New:** Vorlage in 06-appstore-texts Abschnitt 1 (ScrollView, Solo,
  weniger Neustarts, Hinweis Launch-at-Login-Reset).
- **Review-Notes:** Vorlage Abschnitt 2, inkl. **Launch-at-Login-Reset** (Guideline
  2.4.5(iii), gleiche Mechanik wie in Build 10 akzeptiert) und dem Hinweis auf den
  **Tip Jar** (freiwilliger In-App-Kauf, schaltet nichts frei).
- **Promotional Text:** in der Vorlage nicht enthalten; bei 4.0.1 wurde Promotional
  Text im Portal gesetzt [08-submission-log, Phase 4]. Fuer 4.1 pruefen/uebernehmen.
- **Keywords/Subtitle (ASO-Tipp):** Subtitle (max. 30 Zeichen) "audio splitter for
  Mac" (22 Zeichen), Longtail "multi-output audio", "speaker routing Mac" ins
  Keyword-Feld; pro Phrase erst Search Suggestions pruefen, Phrasen einzeln testen
  (ein paar Wochen je Storefront) [project_audiorouternow_aso_pending.md]. Optional,
  nicht release-blockierend.

---

## 5. Release-Ablauf in Schritten

Verantwortlich: 👤 Nutzer, 🤖 Claude. Jeder **unumkehrbare** Schritt (Tag, Push,
Einreichung, Loeschen) nur **auf ausdrueckliche Anweisung**. Reihenfolge verbindlich
[09-final-report Abschnitt 8].

1. 🤖/👤 **Arbeitsbaum committen** nach dem Commit-Plan (Abschnitt 3). Nur benannte
   Dateien, Conventional Commits, Co-Author. **Kein Push.**
2. 👤 **Messpunkte** M1 bis M9, M2b/M2c/M2d, NM-1 bis NM-7 (Abschnitt 4e) mit Claude
   durchgehen, Ergebnisse in `09-final-report` eintragen. **M8 negativ: `5798a63`
   umkehren**, bevor es weitergeht.
3. 👤 **Entscheidungen bestaetigen** (E1, E3, E4, E6 erneut; Welle 6a; Launch-at-
   Login-Reset 6d) [09-final-report Abschnitt 8.2].
4. 👤 **Signierung sichern** (Abschnitt 4b) und **`v4-appstore/` umbenennen**
   (Abschnitt 4c), beide vor dem Archiv.
5. 👤 **Version/Build pruefen:** xcconfig 4.1 (11) gegen live 4.0.1 (10). 11 > 10,
   korrekt [preflight Abschnitt 2].
6. 👤 **Archiv bauen** in Xcode (Product, Archive), **signiert**. Dann im Organizer
   lesen, ob **4.1 (11)** steht (dieser Blick fing 2026-10-01 den Fehler)
   [08-submission-log; 07-submission-plan Schritt 1.6].
7. 👤/🤖 **Preflight erneut:** `v4/scripts/preflight.sh`. Der ABBRUCH muss weg sein,
   nur Warnungen duerfen bleiben [09-final-report Schritt 5].
8. 👤 **Upload:** im Organizer Distribute App, dann App Store Connect, dann Upload
   (so lief 4.0.1; Transporter wird in der 4.0.1-Doku nicht genutzt)
   [07-submission-plan 3.1; 08-submission-log]. Upload ist nicht die Einreichung.
9. 👤 **App Store Connect:** Version 4.1 anlegen (erscheint erst nach dem Upload),
   Build 11 unter **Build** waehlen, Description/What's New/Review-Notiz/Promotional
   Text setzen (Abschnitt 4g), optional Subtitle/Keywords.
10. 👤 **Datum setzen:** `[4.1 (11)], YYYY-MM-DD` in CHANGELOG und RELEASE_NOTES auf
    das Einreichungsdatum [09-final-report Schritt 6]. (Diese Dateien bearbeitet
    aktuell der Doku-Agent; abstimmen, nicht doppelt.)
11. 👤 **Einreichung** ("Add for Review", dann "Submit to App Review"), **Release-
    Option: manuell** (so hat 4.0.1 es gewaehlt: "release mode set to manual
    release") [08-submission-log, Phase 4/6]. **Nur auf Anweisung.**
12. 👤/🤖 **Tag `v4.1`** erst **nach** erfolgreicher Validierung/Einreichung setzen
    (4.0.1-Regel: "noch keinen Tag setzen, solange Validierung nicht durch ist";
    4.0.0/4.0.1 wurden in Phase 7 nach der Einreichung getaggt) [07-submission-plan
    Z. 114, 379; 08-submission-log Phase 7]. Zustand heute: `git tag` zeigt kein
    `v4.1`. **Nur auf Anweisung.**
13. 👤/🤖 **Merge nach `main`:** 4.0.1 kam per **Fast-Forward** auf `main` (die
    main-Commits tragen dieselben Hashes wie die release-Commits, kein Merge-Commit)
    [git log --first-parent main zeigt `9bbd131`, `e3ac13b` direkt]. Fuer 4.1
    gleich verfahren, sofern `main` seither nicht divergiert ist (vorher `git log
    main..` und `..main` pruefen). **Nur auf Anweisung.**
14. 👤/🤖 **Push** von `main` und Tag. **Nur auf Anweisung.**
15. 🤖 **GitHub-Release-Notes** fuer `v4.1` (v4 ist Mac-App-Store, der Store ist der
    Vertrieb; GitHub-Release optional wie bei 4.0.x). **Homebrew/Cask:** betrifft nur
    **v3** (`mauriciomorkun/tap/audiorouternow`), **nicht** v4 [CLAUDE.md Homebrew];
    fuer 4.1 kein Cask-Bump.
16. 👤 **Landing-Page-Aenderungen erst NACH dem Live-Gehen.** Umsetzung nur per
    Verweis auf `docs/homepage-redesign/04-umsetzungspaket.md` (dort E1 bis E8, u.a.
    E2 ARCHS = Variante A unveraendert). Bei 4.0.1 schaltete die Seite automatisch um,
    sobald der Store die neue Version meldete [08-submission-log, "Release"].
17. 👤/🤖 **Support nachfassen:** den beiden Fallnutzern mit dem Scroll-/Footer-Problem
    (ohne Namen) melden, dass der Fix in 4.1 ist, sobald live. Kurz halten, Kernpunkte
    zuerst [CLAUDE.md Support-Lehre; v41_status.md].
18. 🤖 **Issue #1** ("Unable to Install Driver on First Launch") ist **OPEN**
    [gh issue view 1: state OPEN]. Betrifft v3 (Driver/First Launch), nicht v4;
    unabhaengig vom 4.1-Release, Status pruefen und ggf. schliessen, wenn der Melder
    bestaetigt.
19. 🤖 **Memory/TODO pflegen** nach Release: v41_status, v4_tags_pending (v4.1 getaggt),
    CLAUDE.md-Erinnerungsblock entfernen (ist UI-Entscheidung, erledigt den der
    Doku-Agent), TODO/BACKLOG.

---

## 6. Risiken und Rueckfallplan

### App-Review-Risiken

| Risiko | Einschaetzung | Massnahme |
|--------|---------------|-----------|
| Launch-at-Login-Reset | gering: gleiche Mechanik in Build 10 von App Review akzeptiert [05-decisions D1; 06-appstore-texts Review-Notiz] | Review-Notiz nennt Guideline 2.4.5(iii) ausdruecklich |
| Tip Jar / Support-Pille | gering: freiwilliger IAP, schaltet nichts frei, "Support" ist der akzeptierte neutrale Begriff [09-final-report Nachtrag C3] | Review-Notiz erklaert es |
| Hover-Sprechblasen | unkritisch: reine UI, keine neuen Entitlements | keine |

### Technische Risiken

- Messpunkte negativ, v.a. **M8** (Blip): Rueckweg = Commit `5798a63` umkehren
  [09-final-report Z. 312]. **M3** (Knacksen): E5-Annahme, Rueckweg eigene Rampe.
  **Welle 6a/W2**: Rueckfall `SoloGain.effective` in `updateWaveEnergy`
  wiederherstellen [05-plan-v2 D1].
- Test-App nur **ad-hoc signiert** (`.test`): nicht identisch zum Store-Build;
  Messungen am ad-hoc-Build sind indikativ, der Store-Build ist separat am Geraet zu
  bestaetigen.
- **Nicht am Geraet bestaetigt:** Hover-Verhalten im echten Panel, VoiceOver,
  Haken-/Ausgegraut-Darstellung im echten SwiftUI-Menue (bisher nur NSMenu-Probe und
  ImageRenderer-Nachbau) [09-final-report Nachtrag C3; 25-add-device-liste].

### Rueckweg

- Variante-Sicherungen unter `.claude/variants/` (C1, C2, C3b) als Patches
  [CLAUDE.md]. Vor dem Release ist die entschiedene Variante C3b der Arbeitsbaum.
- Nach dem Tag: `v4.1` erlaubt jederzeit Rueckbezug. Einzelne Punkte per
  Revert-Commit zuruecknehmen (z.B. `5798a63` fuer Blip).
- `v4-appstore/` vor dem Entfernen umbenennen (umkehrbar) statt loeschen.

---

## 7. Was ich vom Nutzer brauche (max. 8)

1. **ARCHS (E2):** Das v4-Binary ist BELEGT **universal (x86_64 arm64)**, kein
   `ARCHS` in `v4/project.yml` [lipo -archs, 17.11.2026]. Option **(A)** universal
   belassen (keine Build-Aenderung, Doku ehrlicher fassen: "Developed and tested on
   Apple Silicon; Intel not tested") oder **(B)** `ARCHS = arm64` setzen (Doku wird
   wahr, aber bestehende Intel-Nutzer bekommen kein 4.1). **Empfehlung:** A.
   **Auswirkung:** A schneidet niemanden ab und braucht nur eine Textanpassung; B
   aendert das ausgelieferte Binary und schneidet moegliche Intel-Nutzer (ungemessen)
   von Updates ab, Portal-Verfuegbarkeit OFFEN.
2. **Commit-Freigabe:** den unverbuchten C3/V2-Arbeitsbaum nach dem Commit-Plan
   (Abschnitt 3) committen? **Empfehlung:** ja, vor den Messungen. **Auswirkung:**
   Preflight-Warnung 4a weg, eingereichter Stand eindeutig einem Commit zuzuordnen.
3. **Messpunkte: wann?** Gemeinsame Sitzung (2,5 bis 3,5 h) ansetzen. **Empfehlung:**
   vor allem Weiteren, Vorrang vor der Einreichung. **Auswirkung:** ohne sie ist 4.1
   nicht am Geraet verifiziert.
4. **Screenshots:** selbst anfertigen oder Vorlage durch Claude aus der Test-App?
   **Empfehlung:** Claude baut die Vorlage (Panel C3), Nutzer finalisiert. Anzahl/
   Aufloesung im Portal pruefen (OFFEN). **Auswirkung:** alte Optik (Statuszeile,
   Footer) darf nicht im Store stehen.
5. **`v4-appstore/`:** umbenennen oder loeschen? **Empfehlung:** umbenennen
   (umkehrbar) vor dem Archiv. **Auswirkung:** Preflight-Warnung 1 weg,
   Verwechslungsgefahr im Organizer beseitigt.
6. **Desktop-Test-Apps aufraeumen:** die alten TEST-Apps (TEST, TEST (neu), C2, C3,
   nicht C3b/C3 LISTE) loeschen? **Empfehlung:** nach den Messungen aufraeumen, C3b
   und C3 LISTE bis dahin behalten. **Auswirkung:** weniger Verwechslung beim Messen.
7. **Einreichungszeitpunkt und Release-Option:** Datum? Release manuell (wie 4.0.1)
   oder automatisch? **Empfehlung:** manuell. **Auswirkung:** Nutzer entscheidet, wann
   4.1 oeffentlich wird.
8. **Homepage zeitgleich umstellen?** und **Messtermin in Apple Kalender?** 
   **Empfehlung:** Homepage erst **nach** Live-Gehen (automatischer Umschalter wie 4.0.1); 
   Messtermin als .ics fuer Apple Kalender anlegen, wenn dieser steht (Uhrzeit beim 
   Nutzer erfragen). **Auswirkung:** keine Vorab-Aussage auf der Seite vor der Freigabe.

---

## 8. Quellen und ausgefuehrte Befehle

**Gelesene Dateien:** `.claude/CLAUDE.md`, `BACKLOG.md` (Abschnitt Intel/ARCHS,
v4-appstore), `docs/v4.1/05-decisions.md`, `06-appstore-texts.md`,
`09-final-report.md` (vollstaendig, inkl. M1-M9, NM-1-NM-7, Nachtrag C2/C3),
`docs/v4.0.1/07-submission-plan.md` (Release-/Merge-/Tag-Stellen),
`08-submission-log.md` (vollstaendig: Reihenfolge, Upload, Release-Option, Tags),
`v4/scripts/preflight.sh` (Ausfuehrung), `v4/scripts/test.sh`, `v4/project.yml`
(Signierung), `docs/homepage-redesign/04-umsetzungspaket.md` (E1/E2).
**Memory:** `project_audiorouternow_v41_status.md`, `project_audiorouternow_v4_tags_pending.md`,
`project_audiorouternow_v401_workflow_pending.md` (ueber Index), `project_audiorouternow_aso_pending.md`.

**Ausgefuehrte Befehle (lesend):**
- `git status --short`, `git rev-list --count main..HEAD` (= 65), `git diff --stat`,
  `git log --merges main..HEAD` (leer), `git tag`, `git log --first-parent main`,
  `git ls-files v4-appstore` (leer = untracked).
- `bash v4/scripts/preflight.sh` -> **1 ABBRUCH** (Archiv 4.0.1 (10) statt 4.1 (11)),
  **3 Warnungen** (v4-appstore, Arbeitsbaum nicht committet, nicht gepusht), Exit 1;
  `git status --short` davor und danach **unveraendert**.
- `bash v4/scripts/test.sh` -> **60 swift-testing in 10 Suiten gruen**; git status
  unveraendert. 129 XCTest aus der Doku belegt (laeuft ueber das App-Target).
- `ls ~/Library/Developer/Xcode/Archives` -> juengstes Archiv 2026-10-07 = 4.0.1 (10),
  **kein 4.1-Archiv**.
- `ls ~/Desktop` -> 6 Test-Apps (inkl. C3b, C3 LISTE).
- `du -sh v4-appstore` -> 594M.
- `gh issue view 1` -> **OPEN** ("Unable to Install Driver on First Launch").
- `lipo -archs /Applications/AudioRouterNow4.app/Contents/MacOS/AudioRouterNow4`
  -> `x86_64 arm64` (Store-App 4.0.1 ist **universal**); `defaults read
  .../Info.plist CFBundleShortVersionString` -> `4.0.1`.
- `lipo -archs "$HOME/Desktop/AudioRouterNow 4.1 TEST C3b.app/Contents/MacOS/AudioRouterNow4"`
  -> `x86_64 arm64` (4.1-Test-App ist **universal**); `defaults read .../Info.plist
  LSMinimumSystemVersion` -> `14.4`; `grep ARCHS v4/project.yml` -> kein Treffer.
  (Diese sechs Messungen am 17.11.2026, die ersten vier Werte vom Koordinator
  gemeldet und hier selbst nachgemessen.)

**Nicht geprueft/NICHT PRUEFBAR:** Live-Version im App Store (kein Apple-Zugang,
nur Doku: 4.0.1 (10) seit 13.10.2026); Screenshot-Anforderungen in App Store
Connect; Intel-Verfuegbarkeit von v4 im Portal (ob der App Store Intel-Macs als
kompatibel fuehrt, trotz universalem Binary). Die Architektur selbst ist **BELEGT
universal** (siehe oben), nicht mehr offen.

---

## Nachtrag 18.11.2026

Die beiden Vorbereitungspunkte 4(b) und 4(c) wurden angegangen. Belege in
eckigen Klammern. Nichts committet, kein Push, kein Tag, kein Archiv.

### 4(b) Signierung in `v4/project.yml`

**Ist-Stand (belegt).** Die Signierung lag bisher getrennt: `CODE_SIGN_ENTITLEMENTS`
und `ENABLE_HARDENED_RUNTIME` in der Spec, aber `DEVELOPMENT_TEAM`,
`CODE_SIGN_STYLE` und `CODE_SIGN_IDENTITY` nur im getrackten `project.pbxproj`
[git grep DEVELOPMENT_TEAM HEAD: Treffer in `v4/AudioRouterNow4.xcodeproj/project.pbxproj`;
Commit `1a8257a`]. Die xcconfig bindet bereits per `#include?` eine lokale,
gitignorierte `Configs/Signing.local.xcconfig` ein, die bisher nicht existierte
[ls: No such file]; eine Vorlage `Signing.local.xcconfig.example` war vorhanden.

**Risiko belegt.** In einer /tmp-Kopie (rsync ohne `.git` und `v4-appstore`)
`xcodegen generate` ausgefuehrt und `xcodebuild -showBuildSettings` davor und danach
verglichen: vorher `DEVELOPMENT_TEAM = 5...W`, `CODE_SIGN_STYLE = Automatic`,
`CODE_SIGN_IDENTITY = Apple Development`; nachher `CODE_SIGN_IDENTITY = -` (ad-hoc),
`CODE_SIGN_STYLE` und `DEVELOPMENT_TEAM` entfallen. Das bestaetigt den Plan-Caveat.

**Team-ID-Offenlegung.** Die Team ID steht bereits getrackt im `project.pbxproj`
[Fundstelle oben], also waere die Uebernahme in die Spec keine neue Offenlegung.
Das etablierte Design haelt die Kennung dennoch bewusst aus der getrackten Spec
heraus (gitignorierte lokale xcconfig plus Vorlage). Dieser Weg wird beibehalten.

**Vorbereitete Aenderung (nicht committet).** `v4/project.yml`: `CODE_SIGN_STYLE:
Automatic` in die base-Settings des App-Targets (keine persoenliche Kennung). Die
Team ID bleibt in der gitignorierten `Configs/Signing.local.xcconfig`; die Vorlage
`Signing.local.xcconfig.example` wurde praezisiert. Nachweis in der /tmp-Kopie: mit
`CODE_SIGN_STYLE: Automatic` in der Spec plus lokaler xcconfig reproduziert
`xcodegen generate` die heutige Signierung (`DEVELOPMENT_TEAM`,
`CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = Apple Development`,
`ENABLE_HARDENED_RUNTIME = YES`). `bash v4/scripts/test.sh` 60 swift-testing gruen;
Debug-Build der /tmp-Kopie mit `CODE_SIGNING_ALLOWED=NO` erfolgreich. Schluesselbund:
drei gueltige codesigning-Identitaeten vorhanden (zwei "Apple Development", eine
"Developer ID Application"), nur lesend geprueft. **Noch aus:** Die lokale
`Signing.local.xcconfig` muss der Nutzer aus der Vorlage anlegen und die Team ID
eintragen; ein signiertes Store-Archiv wurde nicht gebaut und nichts hochgeladen
(NICHT PRUEFBAR ohne Archivlauf im Organizer).

### 4(c) `v4-appstore/`

**Befund.** untracked und gitignored [git ls-files: leer; check-ignore: `.gitignore`
Zeile 156], 594 MB, kein `.git` darin, kein Xcode-Prozess hielt ihn offen. Nur
dort vorhanden: `PLAN.md` (AirPlay-Architektur, bereits gesichert in
`docs/v4.1/01-airplay-research.md`), `IMPLEMENTATION_PLAN*.md`, `screenshots/`,
`review issues/`. Getrackte Erwaehnungen sind reine Doku-Chronik plus die
Preflight-Pruefung.

**Ausgefuehrt.** Weil Einzigartiges enthalten ist, umkehrbar umbenannt statt
geloescht: `mv v4-appstore v4-appstore.STALE-2026-10-01`. Rueckgaengig:
`mv v4-appstore.STALE-2026-10-01 v4-appstore`. `.gitignore` um den neuen Namen
ergaenzt (sonst erschien er als untracked).

### Preflight vorher und nachher

| Pruefung | vorher | nachher |
|----------|--------|---------|
| 1 Projektbaum | WARNUNG v4-appstore/ | **OK** kein zweiter Projektbaum |
| 6 Letztes Archiv | ABBRUCH 4.0.1 (10) statt 4.1 (11) | ABBRUCH (unveraendert) |
| Arbeitsbaum / Push | 2 Warnungen | 2 Warnungen |

Vorher 1 ABBRUCH und 3 Warnungen, nachher 1 ABBRUCH und 2 Warnungen. Der ABBRUCH
verschwindet erst mit einem frischen 4.1-Archiv (Nutzerschritt).

### Stand der Entscheidungen

- C3 mit V2 entschieden (17.11.2026) [docs/v4.1/README.md].
- E2 = Option A entschieden (18.11.2026): universal belassen, kein ARCHS
  [Nachtrag in `v4_tags_pending.md`; BACKLOG].
- C3/V2-Arbeitsbaum lokal gesichert, Commits `1a5a959`, `730b8cf`, `30c4d5e`,
  `01125b5`, `27dcd0e`, `4942a34`. Nicht gepusht, kein Tag.
- Screenshot-Vorlage vorhanden (Panel C3 aus der Test-App).
- **Offen:** Messpunkte am Geraet, neues Archiv, Einreichung.

## Nachtrag 23.11.2026

Messsitzung durchgeführt. Belege und Einzelwerte in `27-messprotokoll.md`, Einordnung
in `09-final-report.md` Abschnitt 12.

### 4(e) Messpunkte am Gerät: erledigt

- Durchgeführt am 21., 22. und 23.11.2026 mit "AudioRouterNow 4.1 TEST C3b.app" auf
  einem MacBook Pro (Apple M1, macOS 26.6.2). Ergebnis: alle Hauptzeilen (M1 bis M9 mit
  M2b/M2c/M2d, NM-1 bis NM-7) ok, 20 von 23 Tabellenzeilen ok, 3 Zusatzzeilen offen.
  Kein Messpunkt negativ, der Rückfall bei M8 (Commit `5798a63`) bleibt ungenutzt.
- Dauer: deutlich länger als die Planung (2,5 bis 3,5 Stunden), weil M6 lange
  Laufzeiten braucht (mindestens 90 Minuten Gegenprobe), die Großliste eine
  Nachmessung mit vorübergehend installiertem BlackHole brauchte und M8 wiederholt
  wurde.
- Planung von 4(e), Annahme "17 echte Geräte sind nicht nötig, BlackHole 64ch liefert
  32 Paare": Der Nutzer besaß kein BlackHole. Es wurde am 23.11. per Homebrew
  (`blackhole-64ch`, `blackhole-16ch`, 0.7.1) vorübergehend installiert und danach
  entfernt (Treiberordner und `brew list` geprüft). Das Installieren und Entfernen
  braucht das Administratorpasswort, das nur der Nutzer eingeben kann.

### Was die Sitzung für den weiteren Weg bedeutet

1. **Keine Blocker aus den Messungen.** Die Reihenfolge aus Abschnitt 5 gilt ab dem
   Schritt "Entscheidungen bestätigen" weiter.
2. **Vor der Einreichung empfohlen:** die Zusatzzeilen (VoiceOver-Hinweise, Tab-Fokus,
   große Schrift). Der CPU-Vergleich mit der Store-Version 4.0.1 ist am 23.11.2026
   erledigt: 38,7 Prozent (4.0.1) gegenüber 41,5 Prozent (4.1) bei 3 Zeilen, die Basislast
   von etwa 40 % eines Kerns ist kein 4.1-Effekt.
3. **Entscheidung für später, nicht für 4.1:** Die Blip-Frist (3,0 s) liegt knapp unter
   der Wiederanmeldezeit der Komplete Audio (etwa 3,1 s). Bei schnellem Wiedereinstecken
   greift die Absorption, bei normalem nicht. Kein Code geändert.
4. **Frage 3 aus Abschnitt 7 (Messtermin) ist beantwortet.** Frage 4 (Screenshots):
   Vorlage liegt vor, der Nutzer finalisiert (Gerätename "NI Audio 4 DJ" in zwei Motiven
   sichtbar, Entscheidung offen).
5. **Stand der Entscheidungen:** unverändert (C3 mit V2, E2 = Option A, Commits lokal).
   Offen: neues Archiv, Einreichung.
