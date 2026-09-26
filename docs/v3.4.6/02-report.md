# v3.4.6 Abschlussbericht

Verfasst am 26.09.2026. Autor: Claude Sonnet 4.6 (im Auftrag des Projektinhabers).

Dieser Bericht ist öffentlich und liegt im Repository. Er enthält keine personenbezogenen
Daten des Melders.

---

## 1. Was passiert ist

### Der Defekt

Jede öffentlich verfügbare v3-Version enthielt eine Python-Laufzeit mit `minos 26.0`. Auf
Systemen unterhalb von macOS 26 wies der dynamische Linker die Bibliotheken ab, bevor eine
einzige Zeile Anwendungscode ausgeführt wurde. Für den Nutzer sah das so aus: kein Symbol
in der Menüleiste, kein Fenster, keine Fehlermeldung.

Das README verspricht seit dem Launch am 14.06.2026: "macOS 11 (Big Sur) or later".
Diese Zusage war ab dem ersten Release nie erfüllt.

Betroffen sind alle fünf öffentlichen Releases der v3-Linie:

| Release | Veröffentlicht | minos der Python-Laufzeit |
|---------|----------------|--------------------------|
| v3.4.0 | 14.06.2026 | 26.0 |
| v3.4.2 | 29.06.2026 | 26.0 |
| v3.4.3 | 30.06.2026 | 26.0 |
| v3.4.4 | 30.06.2026 | 26.0 |
| v3.4.5 | 18.09.2026 | 26.0 |

Gemeldet am 24.09.2026 von einem Nutzer auf macOS 12.7.6 (Monterey), M2 MacBook Air.

### Die Ursache

`legacy-v3/installer/build.sh`, Zeile 90:

```bash
PYTHON=$(command -v python3)
```

Das ergab Homebrew Python 3.14. Homebrew übersetzt grundsätzlich für das Betriebssystem
des bauenden Rechners. Die Build-Maschine läuft macOS 26, also tat es das auch Python.

Alles, was das Projekt selbst baut, hatte ein explizites Deployment-Target und war korrekt.
Genau das verdeckte das Problem.

### Die Messung am veröffentlichten Bundle

Am SHA256-identischen v3.4.5-DMG gemessen:

| `minos` | Anzahl Mach-O-Dateien | Was |
|---------|-----------------------|-----|
| 26.0 | 57 | Python-Interpreter und Standardbibliothek |
| 11.0 | 16 | Alles, was das Projekt selbst baut |

Das Hauptbinary zeigte bei einer oberflächlichen Prüfung 11.0. Wer nur dieses eine Binary
ansah, bekam die versprochene Version bestätigt und erkannte das Problem nicht.

---

## 2. Warum es drei Monate unsichtbar blieb

Funf Gründe, nacheinander:

1. Die Build-Maschine lauft immer die neueste macOS-Version. Der Fehler trat auf ihr nie auf.
2. Der Fehler ist stumm. Es gibt keinen Crash-Report, keinen Dialog, nichts Weiterleitbares.
3. Wer die App nicht starten kann, erzeugt keinen Diagnosebericht und meldet in der Regel gar
   nichts. Die Cases 001 bis 004 stammen alle von Nutzern, bei denen die App lief.
4. Das Hauptbinary zeigt korrekt 11.0. Die naheliegende Stichprobe bestätigt genau die
   falsche Annahme.
5. `build.sh` hatte kein Tor, das das Ergebnis gegen die versprochene Mindestversion prüft.

Punkt 5 ist der eigentliche Prozessfehler. Die Punkte 1 bis 4 erklären, warum er folgenlos
blieb.

---

## 3. Der Fund, der alles neu einordnet

Beim Audit der Nacharbeit gefunden: `DOKUMENTATION.md`, Kapitel 43.4, datiert auf den
4. Juni 2026, zehn Tage vor dem Launch. Darin steht:

> Das aktuelle Bundle enthalt Python 3.14 (Beta/RC-Zyklus). Für einen stabilen
> Produktions-Release sollte auf Python 3.13 (LTS-stable) downgegradet werden, bevor
> offiziell gelauncht wird. Aktion: Vor GitHub Release. Dieser Punkt ist in der Roadmap als
> P0-Praventivm assnahme eingetragen.

Die Massnahme, die am 25.09.2026 umgesetzt wurde, war also erkannt, notiert und als P0
eingestuft. Die Begründung damals war eine andere (ABI-Stabilität eines noch nicht finalen
Python), nicht das Deployment-Target. Die Handlung wäre identisch gewesen und hatte den
Defekt verhindert.

Der Launch fand ohne diese Massnahme statt.

Schlussfolgerung: Es fehlte nicht an Erkenntnis. Es fehlte an etwas, das den Build anhält,
wenn eine erkannte Massnahme nicht ausgeführt wurde. Eine Notiz in einem Dokument ist kein
Tor.

Das ist der Grund, warum v3.4.6 ein Tor hat.

---

## 4. Was gebaut wurde

### Schritt 1 (Commit e49d243, 25.09.2026)

| Massnahme | Datei |
|-----------|-------|
| Interpreter festgenagelt auf `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3` | `build.sh` |
| Fehler mit Download-URL, wenn der Interpreter fehlt | `build.sh` |
| `venv_matches_interpreter()`: Herkunft des venv geprüft, Fremdvenv verworfen | `build.sh` |
| `check_minos_gate()`: jede Mach-O-Datei im Bundle gegen den Schwellwert geprüft, Fehler vor dem Signieren | `build.sh` |
| `MACOS_MIN_VERSION` als Einzelquelle im Build-Skript definiert | `build.sh` |

Der Gate-Aufruf sitzt nach dem PyInstaller-Schritt und vor dem Signieren, damit ein fehlerhafter
Build in Sekunden abbricht statt nach einem Notarisierungs-Roundtrip.

### Schritt 2 (Commit 3096979, 26.09.2026)

Der erste Audit hatte keinen Blocker gefunden, aber sechs Befunde ausserhalb des ursprünglichen
Diffs. Diese wurden in einem zweiten Commit behoben.

**Einzelquelle für die Mindestversion:**

`MACOS_MIN_VERSION` lebt jetzt in `legacy-v3/engine/version.py`. Drei Dateien leiten daraus
ab, anstatt eigene Werte zu halten:

| Datei | Effekt |
|-------|--------|
| `build.sh` | Schwellwert des Tors |
| `AudioRouterNow.spec` | `LSMinimumSystemVersion` (was macOS beim Start liest) |
| `legacy-v3/driver/Makefile` (2 Stellen) | produziert `minos` im Treiber und Helper |
| `legacy-v3/helper/Makefile` | produziert `minos` beim Standalone-Build |

`driver/resources/Info.plist` wurde bewusst ausgenommen. Die Makefile kopiert diese Datei
unverändert; ein `sed`-Schritt im Kopier-Target ware ausser Verhältnis. `version.py` benennt
sie als absichtliche Ausnahme.

Die Format-Guard im Build-Skript prüft, dass der gelesene Wert numerisch ist. `vgt()` im Tor
rechnet mit `+ 0`, ein nicht-numerischer Wert wurde zu 0 und das Tor wurde alles durchlassen
-- genau die Fehlerklasse, die es abfangen soll.

**Konsistenz und fehlerhafte Aussagen:**

Gefunden in Dateien ausserhalb des ersten Diffs:

| Datei | Befund | Massnahme |
|-------|--------|-----------|
| `RELEASE_NOTES.md` | Behauptete die alte Einzelquelle | Korrigiert |
| `CONTRIBUTING.md` | Pinnate Python 3.10 | Korrigiert |
| `.github/workflows/build.yml` | Pinnate Python 3.10 | Korrigiert |
| `THIRD_PARTY_NOTICES.md` | Nannte die nicht mehr ausgelieferte Laufzeit | Korrigiert |
| `DOKUMENTATION.md` Zeilen 5720 und 5724 | "arm64-only läuft via Rosetta 2" (Übersetzungsrichtung falsch) | Annotiert, nicht überschrieben |
| `DOKUMENTATION.md` Abschnitt 43.3 | "Intel Macs: build from source" als aktuelle Empfehlung | Korrigiert |

Zwei eigene Annahmen wurden im Verlauf widerlegt und sind hier festgehalten:

| Annahme | Wirklichkeit |
|---------|-------------|
| Die Mindestversion lebt in zwei Stellen | Sie lebt in sechs Stellen, von denen drei tatsächlich das `minos` produzieren |
| Das gesamte python.org-3.13-Verzeichnis taugt als Positivreferenz fürs Tor | Nein: lokal installiertes scipy liegt auf `minos 14.0` und hatte 207 Verstöße erzeugt. Prüfziel ist `lib-dynload` (78 Dateien) und `bin` (2 Dateien) |

---

## 5. Die Beweise, mit Zahlen

Alle drei Tor-Referenzen wurden vor dem Build ausgeführt, weil `dist/` danach geloscht wird
und der einzige Negativ-Beleg dann nicht mehr existiert.

| Prüfziel | Mach-O-Dateien | Ergebnis |
|-----------|---------------|---------|
| Ausgeliefertes v3.4.5-Bundle | 73 | Schlägt fehl mit 57 Verstößen |
| python.org 3.13, `lib-dynload` | 78 | Besteht |
| python.org 3.13, `bin` | 2 | Besteht, eine Warnung (x86_64-only) |

Einzelquelle bewiesen: `MACOS_MIN_VERSION` temporär auf `12.0` gesetzt und in beiden Slices
des Treibers und Helpers gemessen. Zurückgesetzt und erneut auf `11.0` gemessen. Der Wert
fliesst korrekt durch.

Format-Guard bewiesen: Nicht-numerischen Wert, leeren Wert und Whitespace jeweils eingesetzt.
Der Build bricht in allen drei Fallen ab, bevor der erste Kompilieraufruf erfolgt.

---

## 6. Die drei Audit-Runden

**Runde 1** (nach Commit e49d243): Kein Blocker. Audit freigegeben.

**Runde 2** (nach dem Freigabe-Audit von Runde 1): Sechs "Wichtig"-Befunde in Dateien
ausserhalb des ursprunglichen Diffs. Alle oben unter "Konsistenz und fehlerhafte Aussagen"
aufgeführt. Kein Blocker, aber korrektur-pflichtig.

**Runde 3** (nach Commit 3096979): Alle Befunde aus Runde 2 behoben. Tor-Referenzen
unverandert: 73 mit 57 Verstößen, 78 bestehend, 2 bestehend. Nichts an `build.sh`, Spec,
Makefiles oder `version.py` angetastet.

---

## 7. Umgang mit der Chronik

`DOKUMENTATION.md` trennt aktuelle Kapitel (1 bis 12) von der Chronik ab Kapitel 13.

Falsche Aussagen in der Chronik wurden annotiert, nicht überschrieben. Der Grund ist
pragmatisch: Rückwirkend korrigierte Chronikeinträge wurden sagen, was sie nie sagten, und
damit genau das tun, was diese Veröffentlichung vermeiden soll. Wer den historischen Zustand
nachvollziehen will, soll ihn vorfinden. Die Korrektur steht mit Datum daneben.

Empfehlungen für die Gegenwart, die falsch sind, wurden richtiggestellt. Der Unterschied ist,
ob ein Text gelesen wird, um zu verstehen, was damals galt, oder um zu wissen, was heute zu
tun ist.

---

## 8. Intel

Intel-Hardware ist nicht unterstützt, weder durch das vorgefertigte Binary noch durch einen
lokalen Build.

Gemessen und festgehalten in `BACKLOG.md` (gitignored, nicht öffentlich): Treiber und Helper
werden universal gebaut (`x86_64 arm64`). Das ausgelieferte v3.4.5-Bundle dünnt sie auf
arm64 aus. Ursache ist eine Zeile in der Spec: `target_arch=None`. python.org 3.13 ist
universal2, PyObjC-Wheels sind `macosx_10_13_universal2`.

Diese Fakten werden festgehalten. Sie sind nicht versprochen. `target_arch` ist nicht
geändert worden. Es gibt keine Intel-Maschine zum Testen, und der HAL-Treiber ist auf Intel
nie gelaufen.

---

## 9. Was das Tor beweist und was nicht

Das ist der wichtigste Abschnitt dieses Berichts.

Das Tor prüft eine notwendige Bedingung: keine Datei im Bundle verlangt ein neueres System
als 11.0. Schlägt dieser Check fehl, kann die App sicher nicht starten. Besteht er, bleibt
offen, ob eine Bibliothek zur Laufzeit eine API aufruft, die auf Monterey nicht existiert.

Ein korrektes `minos` ist keine Garantie für einen erfolgreichen Start auf einem realen System
unterhalb von macOS 26. Genau diese Verwechslung hat den Defekt drei Monate getragen: das
Hauptbinary zeigte korrekt 11.0, und niemand hat weiter gemessen.

Der Nachweis auf einem echten System unterhalb von macOS 26 steht aus. Die Veröffentlichung
hängt davon ab (siehe Abschnitt 10). Solange dieser Nachweis fehlt, ist die Aussage: der
Build ist messbar korrekt, der Laufzeit-Beweis ist ausstehend.

---

## 10. Was jetzt noch aussteht

> **Nachtrag vom 26.09.2026, abends: erledigt.** v3.4.6 ist veröffentlicht.
> GitHub Release, Appcast, Homebrew-Cask und Landing Page stehen auf 3.4.6, die
> heruntergeladene Datei trägt die erwartete Prüfsumme, ist notarisiert und
> gestapelt, und keine Datei im Bündel verlangt mehr als macOS 11. Melder und
> MacRumors-Thread sind informiert.
>
> Zwischen dem Schreiben dieses Berichts und der Veröffentlichung kam ein
> zweiter Defekt hinzu, der hier noch nicht stehen konnte: Sparkle hat seit
> 3.4.0 nie gestartet. Gefunden beim Funktionstest, behoben und belegt, siehe
> `03-sparkle-plan.md` und `feedback/CASE-006`. Deshalb hat v3.4.6 zwei Tore im
> Build statt einem.
>
> Offen bleibt genau ein Punkt, und es ist derselbe wie in Abschnitt 9: die
> Bestätigung auf einem echten System unterhalb macOS 26. Sie kann nur von außen
> kommen.

Die folgende Liste ist der Stand bei Abfassung des Berichts und bleibt als
solcher stehen.

| Schritt | Hinweis |
|---------|---------|
| `build.sh` ausführen | 12 bis 18 Minuten, Keychain-Freigaben nötig |
| SHA256 in README und Homebrew-Cask eintragen | Platzhalter `SHA256_PLACEHOLDER_FILL_AFTER_BUILD` |
| GitHub Release als Entwurf anlegen | Noch nicht veröffentlichen |
| Melder testen lassen | Zuerst den Entwurf schicken, Bestätigung abwarten |
| Veröffentlichen | Nach Bestätigung, oder nach etwa drei Tagen ohne Antwort mit dem Hinweis, dass der Laufzeit-Beweis noch aussteht |
| `docs/appcast.xml` von Hand ergänzen | NICHT `generate_appcast` ausführen, das überschreibt handgeschriebene CDATA der bestehenden Einträge |
| Homebrew-Cask im selben Durchgang bumpen | Nicht danach |
| Landing Page deployen | Erst nach 06:00 Uhr des Veröffentlichungstags, Diff gegen Live-Site vorher |
| MacRumors-Beitrag Nr. 23 richtigstellen | "v3 stays maintained for anyone below that or on Intel" war beim Schreiben nicht zutreffend. Defekt benennen, v3.4.6 als Fix nennen, Intel weiterhin nicht unterstützt wiederholen |

---

## 11. Weitere Dokumente in docs/v3.4.6/

| Datei | Inhalt |
|-------|--------|
| `00-plan.md` | Ausführungsplan, vor jeder Code-Änderung geschrieben, mit zwei korrigierten Anfangsannahmen |
| `01-consistency-plan.md` | Nachfolgeplan nach dem ersten Audit, mit der Auflösung der Sechs-Quellen-Entdeckung |

Weitere Quellen:

| Datei | Inhalt |
|-------|--------|
| `CHANGELOG.md` | Maschinenlesbare Änderungshistorie, v3.4.6-Eintrag an erster Stelle |
| `RELEASE_NOTES.md` | Nutzerorientierte Release-Notes, v3.4.6-Abschnitt mit Ehrlichkeits-Absatz |
| `feedback/CASE-005_email_python-runtime-minos26.md` | Vollstandige Fallakte, lokal und nicht in Git |
