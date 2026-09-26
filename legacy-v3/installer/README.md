# AudioRouterNow v3: Build und Release

Dieses Verzeichnis baut aus dem Python-Code und dem C-Treiber ein fertiges,
signiertes, notarisiertes und gestapeltes DMG.

> **v3 ist Legacy, aber nicht tot.** v4 verlangt macOS 14.4+. Auf macOS 11 bis
> 14.3 ist v3 die einzige Option. Apple Silicon ist für beide Versionen
> Voraussetzung. Fehler hier treffen echte Nutzer.

---

## Voraussetzungen

### Werkzeuge

| | Prüfen mit |
|---|---|
| macOS 11+ | `sw_vers` |
| Python 3.13, Framework-Build von python.org | `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 --version` |
| Xcode Command Line Tools | `xcode-select -p` |
| Kompilierter HAL-Treiber | `ls ../driver/build/AudioRouterNow.driver` |

Der Interpreter ist seit 3.4.6 fest verdrahtet, `build.sh` sucht `python3` nicht
mehr in der Umgebung. Homebrew-Python übersetzt gegen das macOS des bauenden
Rechners; PyInstaller kopiert diesen Interpreter unverändert ins Bundle, und auf
älteren Systemen startet die App dann wortlos nicht. Fehlt der python.org-Build,
bricht das Skript mit der Download-Adresse ab. Herunterladen:
<https://www.python.org/downloads/macos/>

Treiber bauen, falls nicht vorhanden (`build.sh` macht das ohnehin selbst):

```bash
cd ../driver && make build
```

### Zugangsdaten

Ohne diese drei schlägt der Build ab der Signierung fehl.

| Was | Prüfen mit | Erwartet |
|---|---|---|
| Developer-ID-Zertifikat | `security find-identity -v -p codesigning` | `Developer ID Application: MAURICIO MORAIS DA CUNHA (5D52U34B3W)` |
| Notarisierungs-Profil | `xcrun notarytool history --keychain-profile "AudioRouterNow-Notarization"` | `Successfully received submission history` |
| Sparkle-Signaturschlüssel | `security find-generic-password -s "https://sparkle-project.org"` | Eintrag mit `acct` = `ed25519` |

Profil neu anlegen, falls es fehlt:

```bash
xcrun notarytool store-credentials "AudioRouterNow-Notarization" \
    --apple-id "<apple-id>" --team-id 5D52U34B3W --password "<app-specific-password>"
```

Das App-spezifische Passwort kommt von appleid.apple.com, **nicht** das normale Apple-Passwort.

---

## Build

```bash
cd legacy-v3/installer
./build.sh
```

Dauer: etwa 12 bis 18 Minuten. Der größte Anteil sind **zwei** Notarisierungsrunden
bei Apple, je 2 bis 5 Minuten, auf die das Skript wartet.

### Was das Skript tut

1. Voraussetzungen prüfen (fest verdrahteter Interpreter, clang)
2. HAL-Treiber und Helper bauen (Universal Binary, arm64 + x86_64)
3. Python-venv einrichten, **inklusive Funktions- und Herkunftsprüfung** (siehe unten)
4. Dependencies und PyInstaller installieren
5. `AudioRouterNow.app` bauen
6. **minos-Gate:** jede Mach-O-Datei im Bundle gegen die zugesagte Mindestversion messen
7. Alles mit Developer ID signieren, Hardened Runtime, Timestamp
8. **Signing-Gate:** `codesign --verify --deep --strict` über App und Sparkle-Framework
9. **App notarisieren und stapeln** (per `ditto` archiviert, siehe unten)
10. DMG bauen, Hintergrund und Icons setzen
11. DMG signieren
12. **DMG notarisieren und stapeln**
13. **Abschluss-Gate:** DMG mounten und prüfen, ob die App *darin* ein gestapeltes Ticket hat und Gatekeeper sie akzeptiert

Ergebnis: `~/Desktop/AudioRouterNow.dmg`

### Die vier Gates

Das Skript bricht ab, statt ein kaputtes Artefakt weiterzureichen:

- **minos-Gate** nach PyInstaller, vor dem Signieren: misst mit `vtool` das Deployment-Target jeder einzelnen Mach-O-Datei im Bundle. Liegt eine über der zugesagten Mindestversion, bricht der Build ab. Bis 3.4.5 fehlte diese Prüfung, und jedes Release enthielt eine Python-Laufzeit, die unterhalb macOS 26 nicht lädt. Der Schwellwert kommt aus `engine/version.py`, also aus derselben Quelle, aus der die Makefiles ihr `-mmacosx-version-min` beziehen.
- **Signing-Gate** vor der Notarisierung: unvollständige Signaturen fallen hier auf, nicht erst bei Apple.
- **Unklarer Notarisierungsstatus** ist ein Abbruchgrund. Früher wurde nur gewarnt und weitergebaut, was den Fehler nur verschob: ohne akzeptierte Notarisierung scheitert das Stapling ohnehin, nur später und mit unklarerer Meldung.
- **Abschluss-Gate** nach dem Stapling: mountet das fertige DMG und prüft die App darin. Genau diese Prüfung fehlte jahrelang, siehe unten.

---

## Zwei Fallen, die schon zugeschlagen haben

### 1. Das venv zeigt ins Leere

**Symptom:** `pip: /pfad/zu/altem/ort/.venv/bin/python3.14: bad interpreter: No such file or directory`

**Ursache:** venvs schreiben absolute Pfade fest, in `pyvenv.cfg` und in den
Shebang-Zeilen unter `bin/`. Wird das Projektverzeichnis verschoben oder
umbenannt, zeigen sie auf einen Ort, den es nicht mehr gibt. Passiert beim
Umbau auf `legacy-v3/`: das venv verwies weiter auf `<repo>/installer/.venv`.

**Früheres Verhalten:** Das Skript prüfte nur, *ob* `.venv/` existiert, und
meldete „venv bereits vorhanden". Jedes Release wäre daran gescheitert.

**Heute:** `venv_is_healthy()` startet den Interpreter und `pip` tatsächlich.
`pip` wird getrennt geprüft, weil es eine eigene Shebang-Zeile hat, die
unabhängig vom Interpreter kaputtgehen kann. Ist etwas faul, wird das venv
gelöscht, neu gebaut und erneut geprüft.

Seit 3.4.6 prüft `venv_matches_interpreter()` zusätzlich die **Herkunft**: Ein
venv merkt sich in `pyvenv.cfg` unter `home` das bin-Verzeichnis, aus dem es
erzeugt wurde, und benutzt dessen Standardbibliothek weiter. Ein venv, das
einmal aus Homebrew-Python entstanden ist, bleibt ein Homebrew-venv, egal
welcher Interpreter im Skript steht. Ohne diese Prüfung wäre das Festnageln des
Interpreters wirkungslos. Stimmt die Herkunft nicht, wird verworfen und neu
gebaut.

**Manuell beheben**, falls doch nötig:

```bash
rm -rf legacy-v3/installer/.venv
```

### 2. Die App im DMG hatte kein Ticket

**Symptom:** kein sichtbarer. Genau das war das Problem.

```bash
# So sah es bis einschliesslich 3.4.5 aus:
hdiutil attach ~/Desktop/AudioRouterNow.dmg -mountpoint /tmp/chk -nobrowse
xcrun stapler validate /tmp/chk/AudioRouterNow.app
# → "AudioRouterNow.app does not have a ticket stapled to it."
```

**Ursache:** Die Reihenfolge war verdreht. Erst wurde das DMG gebaut und
notarisiert, danach die App gestapelt, aber nur die Kopie unter `dist/`. Die
Kopie im DMG blieb ohne Ticket. Der Kommentar im Skript behauptete seit jeher
das Gegenteil („App zuerst stapeln, dann DMG"), nur tat der Code es nicht.

**Auswirkung:** Wer die App aus dem DMG zieht und **ohne Internet** startet,
zwingt Gatekeeper zur Online-Nachfrage, die dann nicht beantwortet werden kann.
Mit Netz fällt es nicht auf, deshalb blieb es von 3.4.0 bis 3.4.5 unbemerkt.

**Heute:** Die App wird per `ditto -c -k --keepParent` archiviert, notarisiert,
gestapelt und verifiziert, **bevor** das DMG gebaut wird. `ditto` statt `zip`,
weil `zip` Symlinks und erweiterte Attribute in App-Bundles zerstört und die
Notarisierung dann scheitert. Das Abschluss-Gate prüft das Ergebnis im fertigen
DMG.

---

## Release-Ablauf

Reihenfolge einhalten. Schritt 7 gehört **zum** Release, nicht danach.

| # | Schritt | Befehl / Ort |
|---|---|---|
| 1 | Version bumpen | `engine/version.py` **und** `driver/resources/Info.plist`. Die App-`Info.plist` leitet sich per `.spec` automatisch ab. Gleiches Muster bei der Mindest-Systemversion: `engine/version.py` steuert Makefiles, `.spec` und minos-Gate, nur `driver/resources/Info.plist` wird von Hand nachgezogen. |
| 2 | CHANGELOG datieren | `CHANGELOG.md`, Eintrag von `unreleased` auf das Datum |
| 3 | Release Notes schreiben | `RELEASE_NOTES.md`, Abschnitte „For Everyone" und „For Power Users" |
| 4 | Bauen | `./build.sh` |
| 5 | Commit + Tag | `git tag -a v3.4.x`, `git push origin main --tags` |
| 6 | GitHub Release | `gh release create v3.4.x ~/Desktop/AudioRouterNow.dmg`, SHA-256 in die Notes |
| 7 | **Homebrew-Cask** | `mauriciomorkun/homebrew-tap`, `Casks/audiorouternow.rb`: `version` **und** `sha256` |
| 8 | Appcast | `sign_update`, dann Item in `docs/appcast.xml`, pushen |
| 9 | README + Landing Page | `README.md`, `legacy-v3/README.md`, `landing-page/index.html` |
| 10 | **Landing Page deployen** | `scp` nach `root@<server>:/opt/audiorouternow/index.html`, vorher Backup |
| 11 | Issues benachrichtigen | betroffene GitHub-Issues kommentieren |

### Appcast-Signatur

```bash
./legacy-v3/vendor/Sparkle/bin/sign_update ~/Desktop/AudioRouterNow.dmg
# → sparkle:edSignature="..." length="..."
```

Beim ersten Mal nach einem Neustart fragt der Keychain nach Freigabe.
„Immer erlauben" wählen, sonst blockiert der Aufruf still.

Das Item **von Hand** in `docs/appcast.xml` eintragen, nicht `generate_appcast`
laufen lassen: das Werkzeug überschreibt die handgeschriebenen
CDATA-Beschreibungen der bestehenden Einträge durch bloße Links.

### Warum Schritt 7 kritisch ist

Bei 3.4.4 wurde der Cask erst **sechs Tage nach** dem Release gebumpt. Genau in
diesem Fenster installierte der Melder von Issue #1 über Homebrew und bekam noch
3.4.0, also die Version mit dem kaputten Installer. Der Cask gehört ins Release,
nicht dahinter.

### Warum Schritt 10 kritisch ist

Bei 3.4.5 wurde die Version im Repo gebumpt, aber die Landing Page nicht auf den
Server gespielt. Die Website bot stundenlang weiter 3.4.4 zum Download an, also
exakt den Fehler, den das Release beheben sollte. Ein Repo-Commit deployt nichts.

---

## Verifikation nach dem Build

Das Skript prüft das selbst, aber zum Gegenlesen:

```bash
# DMG
xcrun stapler validate ~/Desktop/AudioRouterNow.dmg
spctl --assess --type open --context context:primary-signature -vv ~/Desktop/AudioRouterNow.dmg

# App IM DMG, das ist die entscheidende Prüfung
hdiutil attach ~/Desktop/AudioRouterNow.dmg -nobrowse -quiet -mountpoint /tmp/chk
xcrun stapler validate /tmp/chk/AudioRouterNow.app     # muss "worked!" sagen
spctl --assess --type execute -vv /tmp/chk/AudioRouterNow.app
defaults read /tmp/chk/AudioRouterNow.app/Contents/Info.plist CFBundleShortVersionString
hdiutil detach /tmp/chk -quiet

# Prüfsumme fuer Release Notes und Homebrew-Cask
shasum -a 256 ~/Desktop/AudioRouterNow.dmg
```

> **Prüfsumme immer gegen das hochgeladene Asset bilden**, nicht nur gegen die
> lokale Datei:
> ```bash
> curl -sL "https://github.com/mauriciomorkun/AudioRouterNow/releases/download/v3.4.x/AudioRouterNow.dmg" | shasum -a 256
> ```
> Daran scheitern Cask-Bumps sonst gern.

---

## Ordnerstruktur nach dem Build

```
legacy-v3/installer/
├── .venv/                    Python-Umgebung, von build.sh erstellt und geprüft
├── build_output/             PyInstaller-Zwischenartefakte
├── dist/
│   └── AudioRouterNow.app    fertige, signierte, gestapelte App
├── AudioRouterNow.spec       PyInstaller-Konfiguration, liest die Version aus engine/version.py
├── build.sh                  Build, Signierung, Notarisierung, Stapling
├── build_local.sh            Variante ohne Notarisierung, nur zum lokalen Testen
└── README.md
```

## Sauber neu bauen

```bash
rm -rf dist/ build_output/
./build.sh
```

Das venv kann stehen bleiben, das Skript prüft es. Bei Verdacht:

```bash
rm -rf .venv dist/ build_output/
./build.sh
```

---

## Installation auf einem frischen Mac

1. `AudioRouterNow.dmg` öffnen
2. `AudioRouterNow.app` nach `Applications` ziehen
3. App starten
4. Beim ersten Start fragt macOS einmalig nach dem Passwort, der HAL-Treiber wird installiert
5. `🎛️` erscheint in der Menüleiste

Schlägt Schritt 4 fehl, nennt die App seit 3.4.5 den konkreten Grund, die
Diagnosebefehle und den Pfad zum Log. Vorher meldete sie fälschlich Erfolg.
