# AudioRouterNow 4.1: App Store Connect Texte

## 1. "What's New" (Versionshinweise im Store, max. 4000 Zeichen)

Vorlage (englisch, kein Superlativ, kein Marketing):

---

This update adds a solo button, fixes two causes of unnecessary audio
interruptions, and makes the device list scrollable when many devices
are configured.

Scrollable device list. The panel no longer grows past the screen when you
have many outputs configured. The device list scrolls, and the start/stop button
now sits at the top of the panel so it stays visible with a long list.

Clearer footer. The footer is a single row. The support control is a labelled
button, and footer controls show a short note on hover.

The "Add device" menu now marks outputs that are already added with a checkmark
and greys them out.

Solo per output. While routing is active, each output has a solo button (the
"S" icon). Tap it to hear only that output. Tap it again to release. Solo is
session-only and resets when you stop routing. It does not change your stored
volume settings.

Fewer unnecessary restarts. The sample rate listener no longer restarts the
engine when macOS fires a notification but the rate did not actually change.
A device that briefly disconnects and reconnects within the settle window
no longer forces a restart.

Note: "Launch at Login" is reset by this update. The consent is tied to the
exact build number it was granted for. If you had it turned on, open the app
and check "Launch at Login" in the footer to re-enable it.

---

## 2. Review-Notizen (nicht oeffentlich sichtbar, fuer den Reviewer)

Vorlage:

---

This update adds three features and fixes two defects.

1. Scrollable device list: the panel now has a ScrollView capped at 400 pt.
   The footer stays outside the scroll view. The start/stop button sits at the
   top of the panel, above the scroll view, and is the only start/stop button.

2. Solo per output: a session-only solo button on each device card. Tap to
   play only that output. Solo uses engine.setOutputGain exclusively and never
   writes to the stored per-device gains (UserDefaults). Full test coverage in
   SoloGainTests.swift.

3. Sample rate listener: the listener reads a baseline at registration and
   compares before triggering a restart. A read failure is treated as a change
   (conservative). Test coverage in SRListenerTests.swift.

4. Device blip absorption: a device reconnecting within the settle window
   discards the pending restart instead of scheduling a new one.

5. Store description: unverifiable superlative removed.

To test routing you need to allow audio recording when macOS asks. The app
uses the Process Tap API to read system audio. Nothing is recorded or stored;
the audio is passed straight to the selected output devices.

Steps to test:
1. Open the app from the menu bar icon.
2. Allow audio recording when prompted.
3. Select one or more output devices.
4. Play any audio. It should come out of all selected devices.
5. Tap the "S" button on one device card. Only that device should play.

Note on "Launch at Login": this update deliberately resets that setting. The
consent is tied to the exact build number it was granted for, so that an app
update can never silently keep launching the app. This is the same mechanism
reviewed and accepted in build 10 (4.0.1). Working as intended under
Guideline 2.4.5(iii).

Contact: dev@mauriciomorkun.com

---

## 3. Store Description: Textbaustein ersetzen (Nutzeraufgabe)

Der Satz "AudioRouterNow is the only sandboxed multi-output solution on the
Mac App Store" (oder aehnlich) muss in App Store Connect durch folgenden
Satz ersetzt werden:

  "AudioRouterNow runs fully sandboxed. No kernel extension. No virtual
  driver. No reboot."

Wo in App Store Connect:
1. App Store Connect oeffnen: https://appstoreconnect.apple.com
2. AudioRouterNow App aufrufen.
3. Version 4.1 anlegen (falls noch nicht vorhanden, nach dem Hochladen des
   Archivs).
4. Im Reiter "App Information" (linke Spalte) ODER direkt in der
   Versionsvorbereitung: Feld "Description" aufrufen.
5. Den Satz suchen und durch den neuen ersetzen.
6. Speichern. Die Aenderung wird erst mit dem naechsten Review sichtbar.

Hinweis: die Superlativ-Stelle liegt nur in App Store Connect, NICHT im
Repository (verifiziert im Impl-Protokoll S9).

## 4. Ergänzte Fassung nach dem Nachtrag W1 (Vorschlag vom 24.11.2026, Nutzer entscheidet)

**Warum:** Die Abschnitte 1 und 2 entstanden vor dem Nachtrag W1 (`OutputLimits.maxSlots` 256, sichtbare
Grenze 255, vorher 16). Für Nutzer mit langen Listen ist das neben dem Scrollen die wichtigste Änderung.
Die Texte oben nennen sie nicht. Die Fassung unten ergänzt genau das und sonst nichts.

**Einordnung der Aussage:** Die Grenze 255 ist aus dem Code belegt, am Gerät gemessen sind Listen bis 48 Zeilen
(`27-messprotokoll.md`). Der Satz sagt deshalb "up to 255" und nennt keine gemessene Zahl darüber. Der Zustand in
4.0.1 (ab dem 17. Ausgang fester Pegel ohne Regler und Pegelanzeige, kein Abbruch) ist am Code von 4.0.1 belegt.

### 4.1 "What's New", ergänzte Fassung (1565 Zeichen, Grenze 4000)

---

This update adds a solo button, supports up to 255 outputs with full controls,
makes the device list scrollable, and fixes two causes of unnecessary audio
interruptions.

Scrollable device list. The panel no longer grows past the screen when you
have many outputs configured. The device list scrolls, and the start/stop button
now sits at the top of the panel so it stays visible with a long list.

More outputs, all with controls. Volume, solo and level meters now work for
every configured output, up to 255. In 4.0.1, outputs after the 16th played at
a fixed volume, without a volume control or level meter.

Clearer footer. The footer is a single row. The support control is a labelled
button, and footer controls show a short note on hover.

The "Add device" menu now marks outputs that are already added with a checkmark
and greys them out.

Solo per output. While routing is active, each output has a solo button (the
"S" icon). Tap it to hear only that output. Tap it again to release. Solo is
session-only and resets when you stop routing. It does not change your stored
volume settings.

Fewer unnecessary restarts. The sample rate listener no longer restarts the
engine when macOS fires a notification but the rate did not actually change.
A device that briefly disconnects and reconnects within the settle window
no longer forces a restart.

Note: "Launch at Login" is reset by this update. The consent is tied to the
exact build number it was granted for. If you had it turned on, open the app
and check "Launch at Login" in the footer to re-enable it.

---

### 4.2 Review-Notiz, Ergänzung

Im ersten Satz "This update adds three features and fixes two defects." beibehalten und als Punkt 6 einfügen,
direkt vor "5. Store description" oder dahinter:

---

6. Output limit: the per-output controls (volume, solo, level meters) now cover
   up to 255 outputs. In the previous version (4.0.1) outputs after the 16th
   ran at a fixed volume without these controls.

---

Die Angaben "ScrollView gedeckelt auf 400 pt" und "Start/Stop oben, einziger Knopf" in Abschnitt 2 sind gegen
`MenuBarView.swift` (Zeilen 43 und 92) geprüft und stimmen (24.11.2026).
