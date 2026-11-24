# AudioRouterNow 4.1: Nachbesserungsplan v3

Erstellt: 2026-11-13 (Planer: Fable 5, Phase 1 Durchlauf 3 des Fable/Opus/Fable-Kreislaufs)
Basis: Audit `docs/v4.1/08-audit-v2.md` (Commit `080f0c8`) und
       Abschlussbericht `docs/v4.1/09-final-report.md` (Commit `14a6417`)

---

## 1. Kopf

### 1.1 Ziel

Vier Nachbesserungspunkte (F1 bis F4) erledigen: eine noch offene Formulierung
im CHANGELOG (F1), die Aufloesung einer Entscheidungs-ID-Kollision durch einen
Kommentar (F2), einen neuen "Known Limitation"-Absatz in CHANGELOG und
RELEASE_NOTES fuer die maxSlots-Grenze (F3) und vier Korrekturen am
Abschlussbericht (F4). Kein neues Feature, kein Produktivcode, kein Echtzeitpfad.

### 1.2 Scope-Freeze (verbindlich)

**Enthalten:** F1 (CHANGELOG Blip-Formulierung), F2 (Kommentar-Praezisierung in
`EngineController.swift`), F3 (Known-Limitation-Absatz in CHANGELOG und
RELEASE_NOTES), F4a bis F4e (Korrekturen im Abschlussbericht).

**Ausdruecklich ausgeschlossen:**
- Jede Aenderung an Logik oder Produktivcode (kein Echtzeitpfad, kein IOProc)
- Aenderungen an `SlotGains.maxSlots`, `PeakMeters.maxSlots` oder der Engine
- Entitlements, Signing, Einreichung
- Consent-Mechanik (`ensureLoginItemCompliance`, `hasValidLaunchAtLoginConsent`,
  `launchAtLoginConsentBuild`)
- Historische Versionseintraege in CHANGELOG oder RELEASE_NOTES (alles vor [4.1])
- Plan- und Audit-Historik `02-plan-v1.md` bis `08-audit-v2.md` NICHT umschreiben
- Kein Push, kein Tag, kein Merge
- Keine neuen Swift-Dateien in `v4/AudioRouterNow4/`
- Marketing-Inhalte (kein Marketing-Text ins Repo)

### 1.3 Branch

`release/4.1`, Startpunkt Commit `14a6417`.

### 1.4 Baseline

Verifiziert durch Audit v2 (Commit `080f0c8`):

| Pruefung | Ergebnis |
|----------|----------|
| `bash v4/scripts/test.sh` | 59 swift-testing in 10 Suiten, alle gruen |
| XCTest (Framework AudioRouterKitTests) | 56 Faelle, alle gruen |
| App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED |

App-Build-Befehl:

```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Hinweis: `xcode-select` zeigt auf die Command Line Tools (kein vollstaendiges
Xcode.app-Bundle im Standardpfad). Deshalb `DEVELOPER_DIR` voranstellen.

Versionsdaten (unveraendert): `MARKETING_VERSION = 4.1`,
`CURRENT_PROJECT_VERSION = 11` in `v4/Configs/AudioRouterNow4.xcconfig`.

### 1.5 Leitplanken (unveraendert aus Plan v2, zuzueglich)

- Kein Produktivcode-Fix. Dieser Durchlauf besteht aus einer reinen
  Kommentarzeile in `EngineController.swift` und Textaenderungen in Doku-Dateien.
- Konventionelle Commit-Messages, Scope in Klammern.
- Kein Em-Dash ` -- `, kein En-Dash, keine privaten Namen, keine E-Mails Dritter
  in neuen Inhalten.
- Keine Gedankenstriche im Sinne der Schreibstil-Konvention des Nutzers.
- Der einzige Swift-Eingriff ist ein reiner Kommentar (kein Logikwechsel, keine
  neue Zeile ausser dem Kommentar).
- Wenn der Build nach F2 abweicht (unerwartet), Schritt rueckgaengig machen.

---

## 2. Entscheidungen

### P3-D1: Formulierung fuer CHANGELOG-Blip-Eintrag (F1)

**Frage:** Welche Formulierung ersetzt "the engine keeps running uninterrupted"
im CHANGELOG-Blip-Eintrag (Z. 106)?

**Kontext:** Die RELEASE_NOTES haben den Satz bereits in zwei Schritten
umformuliert (Commit `fd502c7`): "the pending restart is discarded and the engine
keeps running on the same session. Whether audio stays audibly uninterrupted
depends on the hardware and can only be confirmed on a real device."
Die CHANGELOG-Formulierung muss denselben sachlichen Kern behalten, aber die
unhaltbare Zusage ("uninterrupted") ersetzen.

**Wahl:** "the pending restart is discarded and the engine keeps running on the
same session" als Ersatz, ohne den Hardware-Vorbehalt-Satz (der ins CHANGELOG
zu lang waere). Der Vorbehalt steht vollstaendig in den RELEASE_NOTES.

**Risikoabschaetzung:** Rein stilistisch, kein Code beruhrt. Keine Audio-Auswirkung.

**Rueckfall:** Text kann in einem separaten Commit zurueckgesetzt werden.

### P3-D2: Kommentar-Praezisierung fuer D1-Kollision (F2)

**Frage:** Wie soll der Code-Kommentar in `EngineController.swift` Z. 752
praezisiert werden, um die Kollision mit `05-decisions.md` D1 aufzuloesen?

**Kontext:** Aktuell: `// Entscheidung D1 (Planer, 2026-11-13): SoloGain.effective ...`
Das meint D1 aus `05-plan-v2.md`, aber ein Leser, der im Repo nach "D1" sucht,
findet zuerst `05-decisions.md` (Launch-at-Login) und liest den falschen Kontext.

**Wahl:** Den Kommentar auf
`// Plan-v2-Entscheidung D1 (docs/v4.1/05-plan-v2.md): SoloGain.effective ...`
praezisieren. Damit ist der Bezug eindeutig und ohne Umnummerierung loesbar. Nur
die erste Zeile des Kommentars (Z. 752) aendern, der Rest des Kommentars bleibt.
Kein Logikwechsel.

**Rueckfall:** Kommentar kann rueckgesetzt werden.

### P3-D3: Known-Limitation-Formulierung fuer maxSlots (F3)

**Frage:** Was schreiben wir und wohin?

**Kontext aus Code-Verifikation:**
- `SlotGains.maxSlots = 16` (SlotGains.swift Z. 17)
- `PeakMeters.maxSlots = 16` (PeakMeters.swift Z. 24)
- `FanOutEngine.setOutputGain` ignoriert idx >= 16 mit Log-Warnung
  (FanOutEngine.swift Z. 196 bis 199); Warnung bei buildDirectOutputSlots
  wenn `slotDeviceKeys.count > 16` (Z. 598 bis 599)
- Die Grenze gilt ab Slot-Index 16, das ist die 17. Ausgabe (nullbasiert).
- Commit `f9c34df` (tagged v4.0.0 UND v4.0.1) fuegte SlotGains und die W3-Warnung
  ein: die Per-Device-Lautstaerke-Grenze existiert also seit v4.0.0.
- 4.1 fuegt Solo hinzu, das ebenfalls ueber `setOutputGain` arbeitet. Slots ab
  Index 16 werden daher auch durch Solo nicht stummgeschaltet.
- Folge: Ab der 17. Ausgabe wirken weder Per-Device-Lautstaerke noch Solo.
  Beides spielt mit festem Unity-Gain (1.0).

**Wahl fuer F3:** Einen neuen `### Known limitation` Abschnitt am Ende der
4.1-Sections einfuegen (vor der horizontalen Linie `---`), sowohl in
CHANGELOG.md als auch in RELEASE_NOTES.md. Formulierung sachlich und kurz,
im Stil der vorhandenen Eintraege, ohne Marketing, ohne Superlativ.

**Fuer CHANGELOG.md** (unter dem ### Changed-Block, vor `---`):

```
### Known limitation

- **Outputs beyond the first 16 do not respond to per-device volume or Solo.**
  The per-device volume controls and Solo both operate through a 16-slot gain
  bridge (`SlotGains.maxSlots = 16`). Configured outputs beyond the 16th
  (zero-based index 16 and above) are not covered by the bridge and play at
  a fixed gain of 1.0, regardless of the volume slider or Solo state. The
  engine logs a warning when more than 16 outputs are configured. The
  per-device volume limit has been present since 4.0; Solo was added in 4.1
  and inherits the same constraint. Configurations reaching this limit require
  a device such as BlackHole 64ch together with a large multi-channel interface,
  and are uncommon.
```

**Fuer RELEASE_NOTES.md** (neuer kurzer Absatz nach "Wording", vor `---`):

```
#### Known limitation: more than 16 outputs

The per-device volume controls and the Solo button both work through a fixed
16-slot gain bridge. If you have more than 16 outputs configured, the ones
beyond the 16th (zero-based: index 16 and above) will not respond to the
volume slider or Solo; they play at full gain regardless. This is relevant only
in very large configurations, such as BlackHole 64ch combined with a
multi-channel interface. The engine logs a warning to the system log when this
limit is exceeded. The per-device volume constraint has been present since 4.0;
Solo is new in 4.1 and inherits it.
```

**Offen als Option fuer 4.2:** Eine UI-Begrenzung oder einen Hinweis in der
App selbst (z.B. ein Badge oder eine Info-Zeile bei mehr als 16 Ausgaben) waere
nuetzlicher als das stille Log. Das ist ein BACKLOG-Eintrag fuer 4.2, kein
Scope fuer diesen Durchlauf.

**Rueckfall:** Absatz entfernen.

---

## 3. Schritte

### Schritt P3-S0: Baseline-Verifikation

**ID:** P3-S0
**Datei:** keine Produktivdatei

Vorgehen:
1. `git status` prueft, dass `release/4.1` sauber ist (HEAD = `14a6417`).
2. `cd ~/AudioRouterNow/v4 && bash scripts/test.sh`
   Erwartet: 59 swift-testing, alle gruen.
3. App-Build (Befehl aus Abschnitt 1.4). Erwartet: BUILD SUCCEEDED.

Akzeptanzkriterium: Tests gruen, Build gruen, kein unerwarteter Diff.

Commit: keiner (reine Verifikation).

---

### Schritt P3-S1: CHANGELOG Blip-Formulierung korrigieren (F1)

**ID:** P3-S1
**Datei:** `CHANGELOG.md` Z. 103 bis 107

**Fundstelle (verifiziert):** `grep -n "keeps running uninterrupted" CHANGELOG.md`
liefert Z. 106 im 4.1-Abschnitt.

**Zu aendernde Zeile (aktuell Z. 106):**

```
  restart is now discarded and the engine keeps running uninterrupted. Devices that
```

**Ersatz:**

```
  restart is now discarded and the engine keeps running on the same session. Devices that
```

Nur diese Zeile aendern. Keine anderen Teile des Blip-Eintrags beruehren.
Kein Em-Dash, kein Superlativ, keine Zusage die nur am Geraet belegbar ist.

**Pruefen:** Formulierung nach Edit im Kontext lesen: der Satz muss mit dem
nachfolgenden "Devices that stay away longer..." korrekt zusammenhaengen.

Akzeptanzkriterium:
```
grep "keeps running uninterrupted" CHANGELOG.md
```
darf keinen Treffer im 4.1-Abschnitt (Z. 70 bis 122) liefern.

```
grep "keeps running on the same session" CHANGELOG.md
```
muss Z. 106 im 4.1-Abschnitt treffen.

**Build/Tests nach diesem Schritt:** Nein (kein Swift-Code beruehrt).

**Commit nach P3-S1:**
```
docs(changelog): describe blip session behaviour without hardware claim (F1)
```
Kein Push.

---

### Schritt P3-S2: Code-Kommentar D1 praezisieren (F2)

**ID:** P3-S2
**Datei:** `v4/AudioRouterNow4/EngineController.swift` Z. 752

**Fundstelle (verifiziert):** `grep -n "Entscheidung D1 (Planer" v4/AudioRouterNow4/EngineController.swift`
liefert Z. 752.

**Zu aendernde Zeile (aktuell Z. 752):**

```swift
        // Entscheidung D1 (Planer, 2026-11-13): SoloGain.effective auch fuer `sum`,
```

**Ersatz:**

```swift
        // Plan-v2-Entscheidung D1 (docs/v4.1/05-plan-v2.md): SoloGain.effective auch fuer `sum`,
```

Nur diese eine Zeile aendern. Die nachfolgende Zeile 753 bleibt unveraendert:
`        // damit Wellenform und Meter konsistent die tatsaechlich ausgegebene Energie zeigen.`

Kein Logikwechsel. Kein neuer Import. Kein neuer Code.

**Pruefen nach Edit:** Die umliegenden Zeilen 751 und 753 bis 755 unveraendert
lesen, um sicherzustellen, dass keine unbeabsichtigte Whitespace-Aenderung
eingeflossen ist.

Akzeptanzkriterium:
```
grep -n "Plan-v2-Entscheidung D1" v4/AudioRouterNow4/EngineController.swift
```
muss Z. 752 treffen.

```
grep -n "Entscheidung D1 (Planer" v4/AudioRouterNow4/EngineController.swift
```
darf keinen Treffer liefern.

**Build/Tests nach diesem Schritt:** Ja (Swift-Code beruehrt). App-Build und
Tests muessen gruen bleiben. Erwartet: identisch zu P3-S0, kein Compiler-Fehler
(nur Kommentar geaendert).

**Commit nach P3-S2:**
```
docs(engine): qualify D1 comment to reference 05-plan-v2.md (F2, C1)
```
Kein Push.

---

### Schritt P3-S3: Known-Limitation-Absatz einfuegen (F3)

**ID:** P3-S3
**Dateien:** `CHANGELOG.md` und `RELEASE_NOTES.md`

#### 3a. CHANGELOG.md

**Fundstelle:** Z. 122 (aktuell die `---`-Linie die den 4.1-Abschnitt
schliesst, direkt nach dem `### Changed`-Block).

Neuen Block vor der `---`-Linie einfuegen. Vollstaendiger neuer Text
(zwischen `### Changed`-Block-Ende und der `---`-Linie):

```markdown
### Known limitation

- **Outputs beyond the first 16 do not respond to per-device volume or Solo.**
  The per-device volume controls and Solo both operate through a 16-slot gain
  bridge (`SlotGains.maxSlots = 16`). Configured outputs beyond the 16th
  (zero-based index 16 and above) are not covered by the bridge and play at
  a fixed gain of 1.0, regardless of the volume slider or Solo state. The
  engine logs a warning when more than 16 outputs are configured. The
  per-device volume limit has been present since 4.0; Solo was added in 4.1
  and inherits the same constraint. Configurations reaching this limit require
  a device such as BlackHole 64ch together with a large multi-channel interface,
  and are uncommon.
```

#### 3b. RELEASE_NOTES.md

**Fundstelle:** Im 4.1-Abschnitt nach dem "#### Wording"-Block (Z. 210 bis 214)
und vor der `---`-Linie (Z. 215).

Neuen Block einfuegen. Vollstaendiger neuer Text (nach "Wording"-Block, vor `---`):

```markdown
#### Known limitation: more than 16 outputs

The per-device volume controls and the Solo button both work through a fixed
16-slot gain bridge. If you have more than 16 outputs configured, the ones
beyond the 16th (zero-based: index 16 and above) will not respond to the
volume slider or Solo; they play at full gain regardless. This is relevant only
in very large configurations, such as BlackHole 64ch combined with a
multi-channel interface. The engine logs a warning to the system log when this
limit is exceeded. The per-device volume constraint has been present since 4.0;
Solo is new in 4.1 and inherits it.
```

**Pruefen:** Kein Em-Dash. Kein Superlativ. Kein privater Name. Aussagen stimmen
mit dem Code ueberein: nullbasierter Index 16 ist die 17. Ausgabe, Grenze seit
4.0 fuer Lautstaerke, seit 4.1 auch fuer Solo.

Akzeptanzkriterium:
```
grep -n "Known limitation" CHANGELOG.md
```
muss einen Treffer im 4.1-Abschnitt liefern.

```
grep -n "Known limitation" RELEASE_NOTES.md
```
muss einen Treffer im 4.1-Abschnitt liefern.

```
grep -n "uninterrupted\|without interruption" CHANGELOG.md
```
darf im 4.1-Abschnitt (Z. 70 bis zum Ende des Blocks) keinen Treffer liefern
(Treffer in historischen Abschnitten wie Z. 342 sind erwartet und unberuehrt).

```
grep -n "seamless\|no interruption" CHANGELOG.md RELEASE_NOTES.md docs/v4.1/06-appstore-texts.md
```
darf im 4.1-Abschnitt keinen Treffer liefern (06-appstore-texts.md hat aktuell
keinen; historische Abschnitte werden nicht geprueft).

**Build/Tests nach diesem Schritt:** Nein (kein Swift-Code beruehrt).

**Commit nach P3-S3:**
```
docs(changelog): document maxSlots limitation for volume and Solo (F3)
```
Kein Push.

---

### Schritt P3-S4: Abschlussbericht aktualisieren (F4)

**ID:** P3-S4
**Datei:** `docs/v4.1/09-final-report.md`

Dieser Schritt korrigiert vier Unstimmigkeiten im bestehenden Bericht. Die
Korrekturen sind textlicher Natur und aendern keine anderen Dokumente.

#### F4a: M5-Pruefleitfaden (17 Ausgaben)

**Fundstelle:** Z. 269 (Tabelle M1 bis M9, Zeile M5).

Die Pruefliste fuer M5 lautet aktuell:
"16 konfigurierte Ausgaben (z.B. BlackHole 64ch, Paare 1 bis 16). Slot 1
(Index 0) solo setzen, Slot 16 (Index 15) solo setzen, pruefen, ob ein Slot
ab Index 16 weiter spielt"

Das ist inkonsistent: wer einen "Slot ab Index 16" testen will, braucht 17
Ausgaben, nicht 16. Plan v1 (Messpunkt M5) und das Impl-Protokoll sind als
historische Dokumente unveraendert. Der Bericht ist das verbindliche Ergebnis-
dokument.

**Aenderung:** Die Pruefliste fuer M5 auf 17 Ausgaben korrigieren und den
Hinweis am Ende der Zeile entfernen (da er nur auf die Inkonsistenz hinweist,
die jetzt behoben ist). Konkret:

Alte Pruefliste (M5):
```
16 konfigurierte Ausgaben (z.B. BlackHole 64ch, Paare 1 bis 16). Slot 1
(Index 0) solo setzen, Slot 16 (Index 15) solo setzen, pruefen, ob ein Slot
ab Index 16 weiter spielt
```

Neue Pruefliste (M5):
```
17 konfigurierte Ausgaben (z.B. BlackHole 64ch, Paare 1 bis 17). Slot 1
(Index 0) solo setzen, Slot 17 (Index 16) solo setzen; pruefen, ob Slot 17
(Index 16) weiter spielt und nicht stummgeschaltet wird
```

Dazu den Hinweissatz am Ende der M5-Zeile entfernen: "Hinweis: Die Anleitung
im Plan nennt 'genau 16' Ausgaben und prueft zugleich einen Slot mit Index 16;
dafuer sind 17 Ausgaben noetig. Vorgehen bei der Messung ist daher zu klaeren"

#### F4b: Zuschreibung B4/B5 (Quelle des Befunds)

**Fundstelle:** Abschnitt 4.3 (Z. 155 bis 161).

Der Bericht erwaehnt bereits, dass B4 nicht aus Audit 1 stammt und dass Plan v2
die Zuschreibung abweichend darstellt. Die Formulierung kann in einem Satz
praeziser werden:

Aktuell: "Der Befund B4 stammt nicht aus dem Audit 1. Laut Auftrag hat ihn der
Hauptagent ergaenzt..."

Ersetzen des dritten Satzes ("Der Plan v2 (Abschnitt 1.1) schreibt B4 und B5
stattdessen dem Planer zu...") durch eine klarere Trennung:

Neue Formulierung fuer diesen Abschnitt:
```
Der Befund B4 stammt nicht aus dem Audit 1. Laut Auftrag hat ihn der Hauptagent
ergaenzt, weil der Audit 1 den Reset von Launch at Login nicht dokumentiert
fand. `05-plan-v2.md` Abschnitt 1.1 schreibt B4 und B5 dem Planer zu und
nennt als Quelle die Aufgabenbeschreibung; das ist eine Vereinfachung fuer die
Planungs-Perspektive und aendert nichts am Sachverhalt. Die Zuschreibung ist
in den Dokumenten nicht einheitlich, aber der Bericht gibt den Sachstand
korrekt wieder: B4 und B5 tauchten nach Audit 1 auf, nicht im Audit selbst.
```

#### F4c: C2-Bezifferung anpassen

**Fundstelle:** Abschnitt 4.3 (Z. 161 bis 164).

Aktuell heisst es: "Gezaehlt wird hier deshalb nur C1: 0 hoch, 0 mittel, 1 niedrig."

Das ist korrekt. Der Bericht sagt aber, dass der Hauptagent die Wellenenergie
"quantifiziert hat und der Audit es nicht beziffert habe": das stimmt nicht,
Audit 2 nennt ausdruecklich "1 von 4 = 0,25" in Abschnitt B1 (Z. 141).

Den entsprechenden Klammersatz in Abschnitt 6a anpassen. Aktuell (Z. 207 bis 209):
"Der Auftrag zu diesem Bericht vermerkt, dass der Hauptagent dies bei der
Nachpruefung quantifiziert hat und der Audit es nicht beziffert habe; das
Rechenbeispiel im Audit 2 steht dem entgegen."

Diesen Satz umformulieren auf:
```
Das Rechenbeispiel (1 von 4 Slots, linear = 0,25) stammt aus Audit 2, Abschnitt B1.
```

#### F4d: maxSlots-Zeilenangaben vereinheitlichen

**Fundstelle:** Abschnitt 6c (Z. 227 bis 232), letzter Klammersatz.

Aktuell: "laut Umsetzungsprotokoll `FanOutEngine.swift:196`; der Plan nennt als
Fundstelle `FanOutEngine.swift:598-600`, was ich nicht geprueft habe"

Code-Verifikation durch diesen Planer (am HEAD `14a6417`):
- `FanOutEngine.swift` Z. 196 bis 199: `setOutputGain`, Zweig `idx >= SlotGains.maxSlots`
  mit Log-Warnung (korrekt, beides existiert)
- `FanOutEngine.swift` Z. 598 bis 599: `buildDirectOutputSlots`, Warnung wenn
  `slotDeviceKeys.count > SlotGains.maxSlots` (korrekt, beides existiert)

Beide Fundstellen sind korrekt und ergaenzen sich. Den Klammersatz ersetzen:

Alte Formulierung (Klammersatz am Ende von Abschnitt 6c):
```
(laut Umsetzungsprotokoll `FanOutEngine.swift:196`; der Plan nennt als Fundstelle
`FanOutEngine.swift:598-600`, was ich nicht geprueft habe)
```

Neue Formulierung:
```
(FanOutEngine.swift Z. 196 bis 199: `setOutputGain` verwirft den Aufruf;
FanOutEngine.swift Z. 598 bis 599: `buildDirectOutputSlots` loggt eine Warnung
bei mehr als 16 Slots; beide Stellen existieren und ergaenzen sich)
```

#### F4e: Abschnitt "Durchlauf 3" erganzen

Dieser Schritt erfordert, dass P3-S1 bis P3-S3 bereits abgeschlossen sind
(Commits existieren), damit der Bericht die Commit-Hashes der Durchlauf-3-Arbeit
nennen kann. P3-S4 muss deshalb NACH P3-S1, P3-S2 und P3-S3 ausgefuehrt werden.

**Ergaenzungen am Bericht:**

a) Abschnitt 1 (Ergebnis in 5 Saetzen): Den letzten Satz aktualisieren
   (vorhandene Formulierung ueber Pushes bleibt, aber eine sechste Aussage ueber
   Durchlauf 3 hinzufuegen):
   "Durchlauf 3 behebt F1 (CHANGELOG-Formulierung), F2 (Kommentar-Praezisierung),
   F3 (Known-Limitation-Absatz) und F4 (Berichts-Korrekturen). Das Audit dazu
   steht in `12-audit-v3.md`."

b) Abschnitt 4.1 (Tabelle der Durchlaeuf): Eine dritte Zeile einfuegen.

   | Durchlauf | Plan | Umsetzung | Audit | Befunde | Behebung |
   |-----------|------|-----------|-------|---------|----------|
   | 3 | `10-plan-v3.md` (Fable, 4 Schritte P3-S0 bis P3-S3 plus Bericht-Update P3-S4, 3 Entscheidungen P3-D1 bis P3-D3) | Commits P3-S1 bis P3-S4 (Opus) | `12-audit-v3.md` (Fable): folgt | F1, F2, F3, F4 | In diesem Durchlauf |

c) Abschnitt 4.2 (Befundliste): Folgende Zeilen ergaenzen:

   | F1 | niedrig | CHANGELOG Blip-Eintrag beschrieb Audio-Ergebnis als Tatsache, nicht als Code-Verhalten | Behoben in P3-S1-Commit |
   | F2 | niedrig | Kommentar-ID "D1" in EngineController.swift ohne Dokument-Verweis | Behoben in P3-S2-Commit |
   | F3 | niedrig | maxSlots-Einschraenkung nirgends in Nutzerdoku | Behoben in P3-S3-Commit |
   | F4 | niedrig | Vier Unstimmigkeiten im Abschlussbericht | Behoben in P3-S4-Commit |

d) Zusammenfassung in Abschnitt 1 (Ergebnis in 5 Saetzen): Den Satz "Audit 1 fand..."
   auf drei Durchlaeuf erweitern: "Audit 3 ist noch ausstehend (12-audit-v3.md)."

e) Den Hinweis auf das Sitzungslimit-Abbruch-Geschehen (Abschnitt 4.3, erster
   Spiegelstrich) beibehalten wie er ist.

**Pruefen nach F4:** Keine Em-Dashes, keine privaten Namen in neuen Textteilen.

Akzeptanzkriterium:
```
grep -n "Durchlauf 3\|10-plan-v3\|12-audit-v3" docs/v4.1/09-final-report.md
```
muss mindestens drei Treffer liefern.

```
grep -n "17 konfigurierte\|Index 16" docs/v4.1/09-final-report.md
```
muss Z. M5 treffen.

```
grep -n "0,25.*Audit 2\|Audit 2.*0,25" docs/v4.1/09-final-report.md
```
muss Z. 6a treffen.

```
grep -n "Z. 196\|Z. 598" docs/v4.1/09-final-report.md
```
muss Z. 6c treffen.

**Build/Tests nach diesem Schritt:** Nein (nur Markdown).

**Commit nach P3-S4:**
```
docs(v4.1): update final report for cycle 3 findings (F4a-F4e)
```
Kein Push.

---

### Schritt P3-S5: README aktualisieren

**ID:** P3-S5
**Datei:** `docs/v4.1/README.md`

Zwei neue Zeilen in der Inhaltstabelle ergaenzen:

```markdown
| [10-plan-v3.md](10-plan-v3.md) | Nachbesserungsplan v3 (Planer: Fable 5). Scope: F1 (CHANGELOG-Formulierung), F2 (Kommentar-D1-Praezision), F3 (Known-Limitation maxSlots), F4 (Abschlussbericht-Korrekturen). 5 Schritte P3-S0 bis P3-S4. Status: bereit zur Ausfuehrung. |
| [11-impl-v3.md](11-impl-v3.md) | Umsetzungsprotokoll v3 (Umsetzer: Opus). Wird nach der Ausfuehrung durch den Opus-Agenten ausgefuellt. Status: ausstehend. |
| [12-audit-v3.md](12-audit-v3.md) | Audit Durchlauf 3 (Auditor: Fable 5). Status: ausstehend. |
```

Akzeptanzkriterium:
```
grep -n "10-plan-v3\|11-impl-v3\|12-audit-v3" docs/v4.1/README.md
```
muss drei Treffer liefern.

**Build/Tests nach diesem Schritt:** Nein.

**Commit nach P3-S5:**
```
docs(v4.1): update README for cycle 3 documents
```
Kein Push.

---

## 4. Verbotsliste

Die folgenden Aktionen sind in diesem Durchlauf verboten:

1. Jede Aenderung an Logik oder Produktivcode (Audio-Pfad, IOProc, Engine)
2. Aenderungen an `SlotGains.maxSlots`, `PeakMeters.maxSlots`
3. Jede neue Zeile Swift-Code (ausser dem Kommentar in P3-S2)
4. Entitlements, Signing, Einreichung, Push, Tag, Merge
5. Consent-Mechanik beruehren (`ensureLoginItemCompliance`,
   `hasValidLaunchAtLoginConsent`, `launchAtLoginConsentBuild`)
6. Historische Versionseintraege in CHANGELOG oder RELEASE_NOTES (alles vor [4.1])
7. Plan- und Audit-Historik `02-plan-v1.md` bis `08-audit-v2.md` aendern
8. Marketing-Inhalte in Doku oder Commits
9. `--no-verify` beim Commit
10. Em-Dash ` -- `, En-Dash, private Namen, E-Mails Dritter in neuen Inhalten

---

## 5. Risiken

| Risiko | Eintrittsbedingung | Massnahme |
|--------|-------------------|-----------|
| R1 | P3-S2 (Kommentar) erzeugt unerwarteten Build-Fehler | Kommentar im selben Commit zuruecksetzen; ist extrem unwahrscheinlich, da nur eine Kommentarzeile geaendert wird |
| R2 | Angabe "seit 4.0" fuer maxSlots-Lautstaerke ist falsch | P3-S3 erfordert Verifikation am Commit `f9c34df`; der Planer hat dies geprueft: `f9c34df` ist in v4.0.0 getaggt, Aussage korrekt |
| R3 | Sitzungslimit-Abbruch (wie in frueheren Durchlaeufen) | Plan ist bewusst kurz gehalten. P3-S4 (Bericht) nach P3-S1 bis P3-S3; falls Abbruch vor P3-S4, Commits P3-S1 bis P3-S3 sind bereits nutzbar |
| R4 | Unbeabsichtigte Aenderung an historischen CHANGELOG-Abschnitten | Nur innerhalb des [4.1]-Blocks aendern; nach Edit Z. 1-69 und Z. 123 ff. unveraendert pruefen |

---

## 6. NUTZER MUSS MESSEN (unveraendert M1 bis M9)

Keine dieser Messungen wurde von einem Agenten durchgefuehrt. Kein Build und
kein Unit-Test kann sie ersetzen.

| ID | Thema | Pruefleitfaden | Erwartetes Ergebnis |
|----|-------|----------------|---------------------|
| M1 | ScrollView mit 45+ Eintraegen | BlackHole 64ch und Scarlett 18i20 verbinden, Panel oeffnen, pruefen: Scroll-Indikator, Scrollbarkeit, Footer- und Header-Toggle-Sichtbarkeit, MacBook 13" Panel passt auf Bildschirm | Ja zu allen |
| M2 | Header-Toggle | Mindestens ein Geraet konfiguriert; idle `play.fill` klicken, active `stop.fill` klicken, starting ansehen | Routing startet/stoppt, in starting deaktiviert, kein Doppelstart |
| M3 | Solo ohne Knacksen | Mindestens zwei Ausgaben, Routing aktiv, Musik laeuft; Solo setzen, wechseln, aufheben; Regler der stummen Ausgabe verschieben | Kein Knacksen, kein Pegelsprung; nach Aufheben gilt der gespeicherte Reglerwert |
| M4 | Solo bei abgestecktem Geraet | Zwei Ausgaben, eine solo, dann Solo-Geraet entfernen | Alle anderen bleiben stumm; nach Aufheben alle verbliebenen hoerbar |
| M5 | Grenze maxSlots (16) | 17 konfigurierte Ausgaben (z.B. BlackHole 64ch, Paare 1 bis 17). Slot 17 (Index 16) solo setzen, pruefen ob er weiter spielt (kein Stumm). Slot 1 (Index 0) solo setzen, pruefen ob alle anderen ausser Slot 1 stumm werden (Slots 0 bis 15). | Slots 0 bis 15 reagieren auf Solo; Slot 16 und hoehere bleiben hoerbar (bekannte Einschraenkung) |
| M6 | Noop-Rate SR-Listener | App 15+ Min mit Routing ohne Rate-Wechsel; `log stream ... grep M4-Noop` | Zaehler 0 oder sehr niedrig |
| M7 | Restart bei echtem Rate-Wechsel | Rate in Audio MIDI Setup von 48 kHz auf 44,1 kHz umschalten | Warm-Restart innerhalb 1-3 s, kein "M4-Noop" |
| M8 | Blip-Absorption | USB-Kabel kurz loesen (unter 2 s) | Kuerzere oder keine Unterbrechung als bei 4.0.1 |
| M9 | Meter unter Solo | Zwei+ Ausgaben, Routing aktiv; Solo setzen, stumme Card-Meter ansehen | Meter zeigen 0, passend zur 0,4 Opacity |

---

## 7. Audit-Leitfaden fuer Durchlauf 3

Der unabhaengige Fable-Auditor prueft nach Ausfuehrung durch den Opus-Agenten:

### 7.1 Checkliste F1 bis F4

**F1 (CHANGELOG-Formulierung):**
- [ ] `grep "keeps running uninterrupted" CHANGELOG.md` liefert im 4.1-Abschnitt
  (Z. 70 bis 122) keinen Treffer
- [ ] `grep "keeps running on the same session" CHANGELOG.md` trifft Z. 106
- [ ] Die umliegenden Saetze (Z. 103 bis 108) sind sinnvoll zusammenhaengend

**F2 (Kommentar-Praezisierung):**
- [ ] `grep -n "Plan-v2-Entscheidung D1" v4/AudioRouterNow4/EngineController.swift`
  trifft Z. 752
- [ ] `grep -n "Entscheidung D1 (Planer" v4/AudioRouterNow4/EngineController.swift`
  liefert keinen Treffer
- [ ] Die Logik in Z. 753 bis 755 ist unveraendert

**F3 (Known-Limitation-Absatz):**
- [ ] `grep -n "Known limitation" CHANGELOG.md` trifft den 4.1-Abschnitt
- [ ] `grep -n "Known limitation" RELEASE_NOTES.md` trifft den 4.1-Abschnitt
- [ ] Inhalt nennt Index 16 (nullbasiert), Grenze seit 4.0 fuer Lautstaerke,
  seit 4.1 auch fuer Solo
- [ ] Kein Em-Dash, kein Superlativ, kein privater Name im neuen Absatz

**F4 (Abschlussbericht):**
- [ ] M5-Zeile nennt 17 Ausgaben und Index 16 als Pruefziel
- [ ] Abschnitt 4.3 Zuschreibung B4/B5 klar formuliert
- [ ] Abschnitt 6a: Rechenbeispiel "0,25" mit Verweis auf Audit 2 Abschnitt B1
- [ ] Abschnitt 6c: beide Fundstellen (Z. 196 und Z. 598) genannt, "was ich
  nicht geprueft habe" entfernt
- [ ] Abschnitt ueber Durchlauf 3 vorhanden mit Commits und Verweis auf
  `12-audit-v3.md`
- [ ] Tabelle der Durchlaeuf hat drei Zeilen

**06-appstore-texts.md (Regressionscheck F1):**
- [ ] `grep "uninterrupted\|without interruption\|seamless" docs/v4.1/06-appstore-texts.md`
  liefert keinen Treffer (war bereits sauber, bleibt sauber)

### 7.2 Regressionscheck

- [ ] `bash v4/scripts/test.sh`: 59 swift-testing + 56 XCTest, alle gruen
- [ ] App-Build (Befehl aus Abschnitt 1.4): BUILD SUCCEEDED
- [ ] `git diff --name-only e7db9fe..HEAD`: der Diff enthaelt nur
  - `CHANGELOG.md`
  - `RELEASE_NOTES.md`
  - `v4/AudioRouterNow4/EngineController.swift`
  - `docs/v4.1/09-final-report.md`
  - `docs/v4.1/10-plan-v3.md`
  - `docs/v4.1/11-impl-v3.md`
  - `docs/v4.1/12-audit-v3.md` (falls der Auditor seine Datei schreibt)
  - `docs/v4.1/README.md`
  - Keine weiteren Dateien
- [ ] `git log --oneline -5`: keine Pushes, keine Tags
- [ ] Kein `--no-verify` in der Commit-Liste
- [ ] Keine neuen Dateien in `v4/AudioRouterNow4/`
- [ ] Consent-Funktionen unberuehrt:
  `git diff e7db9fe..HEAD -- v4/AudioRouterNow4/EngineController.swift | grep "^+" | grep "ensureLoginItemCompliance\|hasValidLaunchAtLoginConsent\|launchAtLoginConsentBuild"` liefert keinen Treffer

---

## 8. Abschlussschritte

Nach P3-S4 und P3-S5:

1. `bash v4/scripts/test.sh` nochmals ausfuehren. Erwartet: unveraendert gruen.
2. App-Build (Befehl aus Abschnitt 1.4) nochmals ausfuehren. Erwartet:
   BUILD SUCCEEDED.
3. `git log --oneline -6` lesen: fuenf Commits (P3-S1 bis P3-S5) sollen sichtbar
   sein, kein Push, kein Tag.
4. Dem Opus-Agenten gemaess Projektregel kein Push, kein `--no-verify`.
5. Der Auditor empfaengt den fertigen Branch und schreibt `12-audit-v3.md`.
6. Wenn der Auditor `12-audit-v3.md` geschrieben hat, den Abschlussbericht
   in P3-S4 nachtragen (Commit-Hash des Audit-Commits und Ergebnis).

---

## 9. Schritt-Reihenfolge (verbindlich)

P3-S0 (Baseline) > P3-S1 (F1 CHANGELOG) > P3-S2 (F2 Kommentar) >
P3-S3 (F3 Known Limitation) > P3-S4 (F4 Bericht) > P3-S5 (README)

P3-S4 erfordert zwingend die Commit-Hashes aus P3-S1 bis P3-S3.
Innerhalb P3-S1 bis P3-S3 koennen die Reihenfolgen getauscht werden, falls
noetig; P3-S4 bleibt immer letzter inhaltlicher Schritt.

---

## 10. Was unverified bleibt

- Ob die Formulierung in CHANGELOG und RELEASE_NOTES von Apple App Review
  als zulaessig eingestuft wird: ungetestet, kein Scope fuer Agenten.
- Die Frage, ob 17 Output-Paare auf dem Testgeraet des Nutzers konfigurierbar
  sind: Messpunkt M5, nicht von Agenten durchfuehrbar.
- Ob die Blip-Absorption (M8) in der Praxis funktioniert: weiterhin offen.
- Alle M1 bis M9: keine Agentenaufgabe.
