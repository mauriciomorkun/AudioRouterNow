# AudioRouterNow 4.1: Umsetzungsprotokoll v2

Umsetzer: Opus (Durchlauf 2 des Fable/Opus/Fable-Kreislaufs), nach Plan
`docs/v4.1/05-plan-v2.md` (Commit `41d4673`), der auf Audit
`docs/v4.1/04-audit-v1.md` (Befunde B1 bis B3) basiert.

Stil wie `docs/v4.1/03-impl-v1.md`. Dieses Protokoll trennt strikt zwischen
belegt, gebaut, getestet und offen (Nutzer muss messen).

Hinweis zur Dateibenennung: der Plan legt die Dateien `05-decisions.md` und
`06-appstore-texts.md` an (Plan-Schritte N4 und N6). Dieses Protokoll heisst
daher `07-impl-v2.md`, um keine Namenskollision mit `06-appstore-texts.md` zu
erzeugen.

---

## Baseline (N0)

| Pruefung | Ergebnis |
|----------|----------|
| Branch | `release/4.1`, `git status` sauber, Startpunkt `338855e` (Plan-Commit `41d4673` als HEAD) |
| swift-testing | `bash scripts/test.sh`: 59 Tests in 10 Suiten, alle gruen |
| XCTest | 56 Faelle, alle gruen |
| App-Build | BUILD SUCCEEDED (Debug, `CODE_SIGNING_ALLOWED=NO`) |

App-Build-Befehl (unveraendert aus Plan Abschnitt 1.4):

```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Hinweis: Der App-Build gibt in dieser Umgebung Umgebungsmeldungen aus
(DVTCoreDeviceCore-Plugin, CoreSimulator veraltet). Das sind Hinweise zur
Xcode-Installation, keine Build-Fehler; der Build endet mit `BUILD SUCCEEDED`.

Versionsdaten (unveraendert): `MARKETING_VERSION = 4.1`,
`CURRENT_PROJECT_VERSION = 11` in `v4/Configs/AudioRouterNow4.xcconfig`.

---

## Schritt-Protokoll

### N0 Baseline-Verifikation, erledigt, KEIN Commit
Tests 59 swift-testing + 56 XCTest gruen, App-Build SUCCEEDED, Branch
`release/4.1` sauber. Kein Commit (N0).

### N1 Peak-Meter und Wellenenergie unter Solo korrigieren (B1), erledigt
- Commit: `cba4489`
- Datei: `v4/AudioRouterNow4/EngineController.swift`, `updateWaveEnergy()`
- `let gain = Float32(deviceGains[key] ?? 1.0)` ersetzt durch
  `let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)`.
  Damit zaehlen unter aktivem Solo stumme Slots mit Gain 0.0 in die Signal-Meter
  UND in `sum` (Wellenenergie), konsistent zur tatsaechlich ausgegebenen Energie
  (Entscheidung D1). Reine Anzeigeaenderung, `deviceGains` wird nur gelesen,
  `soloedKeys` nur gelesen. `SoloGain` bereits ueber `import AudioRouterKit`
  verfuegbar (Z. 12), bereits in `applySoloGains()` genutzt.
- Akzeptanz: `grep -n "deviceGains\[key\]" v4/AudioRouterNow4/EngineController.swift`
  liefert nur noch den Treffer in `setDeviceGain` (Z. 478, Persistenz-Schreibpfad),
  keinen direkten `deviceGains[key]`-Zugriff fuer `gain` in `updateWaveEnergy` mehr.
- Build SUCCEEDED, keine Swift-6-Warnungen. Test: 59 swift-testing gruen.
- Abweichung: keine.

### N2 RELEASE_NOTES.md Formulierung hardware-neutral fassen (B2), erledigt
- Commit: `fd502c7`
- Datei: `RELEASE_NOTES.md`, Abschnitt "Fewer unnecessary audio interruptions"
- Satz "routing keeps running without interruption" ersetzt durch eine
  Formulierung, die nur den Code-Pfad beschreibt (pending restart verworfen,
  Engine laeuft auf derselben Session weiter) und ausdruecklich sagt, dass die
  hoerbare Ununterbrochenheit von der Hardware abhaengt und nur am Geraet
  bestaetigbar ist.
- Akzeptanz: `grep "keeps running without interruption" RELEASE_NOTES.md` findet
  im 4.1-Abschnitt keinen Treffer mehr (der verbleibende Treffer auf Z. 442
  gehoert zum vorhandenen, nicht im Scope liegenden Feature "Bluetooth output
  lock" einer frueheren Version). `grep "pending restart is discarded"
  RELEASE_NOTES.md` liefert einen Treffer.
- ABWEICHUNG (minimal): Der Plan skizziert die neue Formulierung in drei Zeilen.
  Beim Zeilenumbruch im Dokument wurde darauf geachtet, dass die Phrase "pending
  restart is discarded" in einer Zeile bleibt, damit der literale grep-Check des
  Audit-Leitfadens (B2) anschlaegt. Inhalt wortgleich zum Plan.
- Test: 59 swift-testing gruen (Docs ohne Testwirkung).

### N3 Testluecke in SoloGainTests behoben (B3), erledigt
- Commit: `f2f7deb`
- Datei: `v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloGainTests.swift`
- In `testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo` zwei Assertionen
  ergaenzt (Entscheidung D2): leerer Key unter aktivem Solo (nicht in soloedKeys)
  liefert 0.0, leerer Key selbst solo'et liefert 1.0 (Unity-Default). Keine neue
  Testmethode.
- Akzeptanz: `grep -c "XCTAssertEqual" ...SoloGainTests.swift` = 14 (war 12,
  Mindestanforderung 10). Methodenanzahl unveraendert (7).
- XCTest-Lauf `swift test --filter SoloGainTests`: 7 Methoden gruen, inkl. der
  erweiterten Methode. Voller Kit-Testlauf: 56 XCTest gruen. swift-testing 59 gruen.
- Abweichung: keine.

### N4 Entscheidungsdokument 05-decisions.md erstellen (B4a), erledigt
- Commit: `c079c27`
- Datei: `docs/v4.1/05-decisions.md` (NEU)
- Enthaelt D1 (Launch-at-Login-Reset beim Build-Sprung 10 auf 11) mit den vier
  Feldern Decision, Why this is not a regression, Effect on the user, Why no
  code fix, plus Fallback. Text exakt nach Plan-Vorlage, Kopf- und Datumsfelder
  gefuellt.
- Akzeptanz: Datei existiert, kein Em-/En-Dash (Byte-Pruefung), kein Nutzername,
  kein Marketing. Der genannte Footer-Schalter ist am Code verifiziert
  (`v4/AudioRouterNow4/UI/RoutingControls.swift`, `Toggle("Launch at Login", ...)`).
- Abweichung: keine.

### N5 CHANGELOG und RELEASE_NOTES um B4-Hinweis ergaenzt (B4b), erledigt
- Commit: `68c8d71`
- Dateien: `CHANGELOG.md` (Abschnitt `[4.1 (11)]`, vorhandene Rubrik `### Changed`),
  `RELEASE_NOTES.md` (Abschnitt "AudioRouterNow 4.1", neuer Unterabschnitt
  "Launch at Login is reset after the update" vor "Wording").
- Beide Absaetze ergaenzt, kein vorhandener Text geloescht. Verweis auf
  `docs/v4.1/05-decisions.md` D1.
- Akzeptanz: kein Em-/En-Dash in den neuen Bloecken (Byte-Pruefung), kein
  Nutzername, kein Marketing.
- Abweichung: keine. N4 und N5 wurden entgegen dem optionalen Plan-Hinweis
  getrennt committet (sauberer Audit-Trail; der Plan erlaubt beides).
- Test: 59 swift-testing gruen.

### N6 App-Store-Connect-Textvorlage erstellen (B4c), erledigt
- Commit: `8eae52b`
- Datei: `docs/v4.1/06-appstore-texts.md` (NEU)
- Drei Abschnitte: What's New (Store-Versionshinweise), Review-Notiz (fuer den
  Reviewer), Store-Description-Ersetzung (Schritt fuer Schritt). Text exakt nach
  Plan-Vorlage.
- Akzeptanz: Datei existiert, drei `## `-Abschnitte, kein Em-/En-Dash
  (Byte-Pruefung), kein Marketing-Versprechen, kein Nutzername. Einzige
  E-Mail-Adresse `dev@mauriciomorkun.com` (laut Plan ausdruecklich erlaubt,
  kein privater Name).
- Abweichung: keine.

### N7 Abschluss-Testlauf und README-Ergaenzung, erledigt
- Commit: dieses Protokoll plus README (siehe Abschluss unten).
- Datei: `docs/v4.1/README.md`
- swift-testing: 59 Tests in 10 Suiten, alle gruen (unveraendert).
- XCTest (voller Kit-Lauf): 56 Faelle, alle gruen (unveraendert, da N3 nur
  Assertionen in einer bestehenden Methode ergaenzt).
- App-Build: BUILD SUCCEEDED.
- Preflight-Ergebnis (selbst ausgefuehrt, siehe unten): 1 ABBRUCH (altes
  4.0.1-Archiv), 2 Warnungen (`v4-appstore/`, Commits nicht gepusht). Kein neuer
  ABBRUCH. Version-Pruefung zeigt "4.1 (11)".
- README: die vorhandenen Zeilen fuer `05-decisions.md` und `06-appstore-texts.md`
  (vom Planer mit "Zu erstellen durch Umsetzer" vorbereitet) auf "Status: erstellt"
  aktualisiert und eine Zeile fuer dieses Protokoll `07-impl-v2.md` ergaenzt.
- ABWEICHUNG (minimal): Der Plan-N7-Vorschlag zeigt drei neu einzufuegende
  Tabellenzeilen inklusive einer fuer `05-plan-v2.md`. Diese Zeilen existierten
  im README bereits (vom Planer angelegt). Statt Duplikate anzulegen, wurden die
  vorhandenen Zeilen fuer `05-decisions.md`/`06-appstore-texts.md` im Status
  aktualisiert und die fehlende Zeile `07-impl-v2.md` ergaenzt. Minimale,
  konservative Loesung ohne Duplikate.

---

## Gesamtstand

| Kennzahl | Wert |
|----------|------|
| Plan-Schritte | 8 (N0 bis N7) |
| Erledigt | N0 bis N7 |
| Commits (Code/Doku) | `cba4489`, `fd502c7`, `f2f7deb`, `c079c27`, `68c8d71`, `8eae52b` (plus dieses Protokoll + README) |
| Teststand vorher | 59 swift-testing + 56 XCTest, alle gruen |
| Teststand nachher | 59 swift-testing + 56 XCTest, alle gruen |
| App-Build | SUCCEEDED (Debug, `CODE_SIGNING_ALLOWED=NO`) |
| Push | kein Push (Absicht) |

Alle Commits sind Conventional Commits mit Co-Author. Kein `--no-verify`, kein
`git add -A` (nur die Dateien des jeweiligen Schritts per Namen). Kein
`reset --hard`, kein Revert noetig (kein Test wurde rot).

## Preflight-Ergebnis (selbst ausgefuehrt in N7)

```
1. Projektbaum
  WARNUNG v4-appstore/ existiert noch.

2. Version
  OK      xcconfig sagt 4.1 (11)
  OK      Keine zweite Versionsquelle im Projekt

3. Build-Nummer gegen vorhandene Tags
  OK      Tag v4.1 existiert noch nicht

4. Arbeitsbaum
  OK      Sauber
  WARNUNG Commits sind noch nicht gepusht

5. Berechtigungen (Release)
  OK      App Sandbox aktiv
  OK      Audio Input vorhanden

6. Letztes Archiv (falls vorhanden)
  Archiv: AudioRouterNow4 07-10-2026, 17.55.xcarchive
  ABBRUCH Archiv ist 4.0.1 (10), erwartet war 4.1 (11)
  OK      Archiv stammt aus v4/ (110 Pfadverweise)

ERGEBNIS: 1 Abbruchgrund, 2 Warnungen.
```

Das entspricht exakt der Plan-Erwartung (Abschnitt 1.4 und B5): der ABBRUCH
betrifft das alte 4.0.1-(10)-Archiv auf der Platte, nicht die Versionsquelle.
Er ist unvermeidlich bis ein neues 4.1-Archiv gebaut wird (Einreichungsschritt,
ausserhalb dieses Scopes). Nutzerhinweis fuer die Einreichung: neues Archiv in
Xcode bauen (Product > Archive), dann `v4/scripts/preflight.sh` erneut
ausfuehren; der ABBRUCH muss dann verschwunden sein, nur die zwei Warnungen
bleiben.

## Abweichungen und Luecken

1. **N2 (Zeilenumbruch):** Phrase "pending restart is discarded" bewusst in
   einer Zeile gehalten, damit der literale grep-Check aus dem Audit-Leitfaden
   anschlaegt. Inhalt wortgleich zum Plan.
2. **N4/N5 (getrennte Commits):** Der Plan erlaubt, N4 und N5 zusammenzufassen.
   Hier getrennt committet fuer einen saubereren Audit-Trail.
3. **N7 (README):** Vorhandene Tabellenzeilen aktualisiert statt Duplikate
   anzulegen; Zeile fuer `07-impl-v2.md` ergaenzt.

Keine weiteren Abweichungen. Keine Lueckenentscheidung noetig (der Plan war an
allen umgesetzten Stellen eindeutig).

## Verbotsliste eingehalten

- FanOutEngine-Echtzeitpfad (IOProc, `makeDirectIOBlock`): unberuehrt.
- `deviceGains`/UserDefaults: durch Solo nie geschrieben; N1 liest nur.
- Entitlements: unberuehrt.
- `ensureLoginItemCompliance()`, `hasValidLaunchAtLoginConsent()`,
  Consent-Keys: unberuehrt (nur in 05-decisions.md dokumentiert).
- `v4-appstore/`, `legacy-v3/`: unberuehrt.
- Kein Push, keine Einreichung, kein Force, kein `reset --hard`.
- `SoloGain.effective`: nicht dupliziert; N1 ruft die vorhandene Funktion auf.
- `SlotGains.maxSlots`, W1-Ramp: unberuehrt.

## NUTZER MUSS MESSEN (offen, aus Plan Abschnitt 6, unveraendert)

Keiner dieser Punkte ist durch Build oder Unit-Test verifizierbar. Alle offen:
M1 (ScrollView, 45+ Eintraege), M2 (Header-Toggle), M3 (Solo ohne Knacksen),
M4 (Solo bei abgestecktem Geraet), M5 (maxSlots-Grenze 16), M6 (SR-Noop-Rate),
M7 (SR-Restart bei echtem Wechsel), M8 (Blip-Absorption).

**Zusaetzlicher Messpunkt M9 (B1-Fix, Geraet erforderlich):** Unter aktivem
Solo die Signal-Meter einer durch fremdes Solo stummen Card beobachten. Erwartet
nach N1: Meter zeigen 0 (Stille), konsistent zur 0.4-Opacity. Nur am Geraet
verifizierbar, hier NICHT als verifiziert gemeldet.

## Vom Nutzer bestaetigte Entscheidungen (nicht am Geraet verifiziert)

E1 (maxHeight 400 pt), E3 (Icon-Button in der Statuszeile), E4 (0.4-Opacity
fuer stumm-durch-Solo), E6 (Blip-Restart verwerfen). Vom Nutzer bestaetigt,
am Geraet NICHT verifiziert.

## Restrisiken

- **N1 (B1-Fix):** Die Korrektur ist reine Anzeige. Risiko R1/R2 aus dem Plan
  (Import, `soloedKeys`-Zugriff) sind durch den gruenen Swift-6-Build ohne
  Warnungen entschaerft. Das reale Anzeigeverhalten unter Solo ist nur am
  Geraet pruefbar (M9).
- **Preflight-ABBRUCH:** bleibt bis zum Bau eines neuen 4.1-Archivs. Das ist
  eine reine Nutzeraufgabe vor der Einreichung, kein Fehler in diesem Scope.
