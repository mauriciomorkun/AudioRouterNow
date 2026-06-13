# AudioRouterNow — Backlog & Ideen-Diskussionen

> ⚠️ **Dieses Dokument enthält Ideen, Brainstormings und Diskussionen — KEINE beschlossenen Features oder festen Roadmap-Einträge.**
> Einträge hier sind Gedanken, die festgehalten werden sollen, um sie zu einem späteren Zeitpunkt zu bewerten und zu entscheiden.
> Ein Eintrag im Backlog bedeutet nicht, dass er gebaut wird.

---

## Status-Legende

| Symbol | Bedeutung |
|--------|-----------|
| 💡 | Idee / Diskussion — kein Beschluss |
| 🔍 | Wird gerade evaluiert |
| ✅ | Beschlossen (wird in PLAN.md oder Roadmap übertragen) |
| ❌ | Verworfen (mit Begründung) |

---

## Feature-Ideen

### 💡 Per-App Audio Routing Panel

**Erstellt:** 12. Juni 2026  
**Status:** Idee / Diskussion — kein Beschluss  
**Ziel-Version:** Unbekannt (potentiell v4.0 oder später)

#### Beschreibung

Ein interaktives Panel in der App, das aktiv erkannte Audio-Quellen (laufende Apps mit Audio-Output) anzeigt und dem User erlaubt, jede Quelle unabhängig zu einem bestimmten Ausgabegerät zu routen.

**Beispiel-Use-Case:**
- YouTube im Browser → Externe Soundkarte
- Telegram-Sprachnachricht → AUX-Kopfhörer (MacBook 3,5mm)
- Spotify → Externe Soundkarte
- Zoom → Eingebaute Lautsprecher

**Kern-Funktionen (diskutiert):**
1. Erkennung aktiver Audio-Quellen in Echtzeit (welche Apps senden gerade Audio?)
2. Unabhängiges Routing jeder Quelle zu einem beliebigen Ausgabegerät
3. Kombiniertes Routing (mehrere Apps → selber Ausgang möglich)

**Mögliche Erweiterungen (für spätere Updates, noch weiter entfernt):**
- Per-App-Lautstärkereglung
- Routing-Profile / Szenen (z.B. "Meeting-Modus", "Streaming-Modus")

#### Technische Basis (diskutiert)

- **Apple Process Taps API** (`AudioHardwareCreateProcessTap`, `CATapDescription`) — verfügbar ab macOS 14.2+
- Ermöglicht App-Audio-Streams in der Sandbox abzugreifen, ohne HAL-Plugin oder Systemerweiterung
- Voraussetzung: App Store Distribution (Sandbox)

#### Strategische Erkenntnisse — LLM Council (12. Juni 2026)

Ein LLM Council (5 Berater, Fable-Modell) wurde zu dieser Frage durchgeführt: *"Inwiefern würde dieses Feature AudioRouterNow von der Konkurrenz abgrenzen?"*

**Konsens des Councils:**

- **Das Feature selbst ist kein Alleinstellungsmerkmal.** SoundSource (Rogue Amoeba, 47 USD) und Audio Hijack bieten Per-App-Routing seit Jahren. BackgroundMusic tut es gratis.
- **Der echte Vorteil wäre der Distributions-Kanal:** Rogue Amoeba ist strukturell nicht App-Store-fähig (ihre Audio-Engine braucht Kernel-nahe Komponenten außerhalb der Sandbox). Process Taps würde AudioRouterNow zum ersten sandboxed, App-Store-legalen Per-App-Routing machen.
- **Zeitfenster, kein Burggraben:** Sobald Process Taps allgemein bekannt ist, kann Rogue Amoeba oder jeder andere Indie-Entwickler nachziehen. Schätzung: 12–18 Monate Vorsprung-Fenster.

**Wichtige Risiken (Council-Findings):**

| Risiko | Beschreibung |
|--------|-------------|
| **Sherlocking** | Apple könnte Per-App-Routing nativ in macOS einbauen (Windows hat es seit Vista). Ein WWDC könnte die gesamte Kategorie killen. |
| **DRM-Streams** | Process Taps kann keine DRM-geschützten Streams abgreifen (Apple Music, Netflix). Das begrenzt den Mainstream-Use-Case. |
| **Permission-Schock** | Der System-Dialog "möchte Systemaudio aufnehmen" kann bei Mainstream-Usern Misstrauen auslösen. |
| **macOS 14.2+ Floor** | Schränkt die adressierbare Nutzerbasis ein. Parallele Pflege von v3.x (HAL) und v4.x (Process Taps) nötig? |
| **App Store Entitlement** | Ob Apple `com.apple.security.device.audio-input` + Process Taps im Review akzeptiert, ist unbekannt und muss validiert werden. |
| **Latenz / Lip-Sync** | Process Taps = capture + re-render auf anderem Gerät → potentielle Audio-Video-Synchronisations-Probleme bei Video-Playback. |

**Positionierungs-Empfehlung (falls das Feature gebaut wird):**

- Konsumprodukt-Sprache: *"Jede App auf ihr eigenes Gerät — in 10 Sekunden."*
- Niemals technisches Framing auf der Store-Seite ("HAL-Plugin", "Process Taps API")
- Einmalkauf ca. 15–25 EUR, klar unter SoundSource/Loopback
- Minimaler Scope für v1: nur Routing, keine EQ/Profile

**Validation-Spike (Empfehlung vor jeder Entscheidung):**

Bevor eine Entscheidung zu diesem Feature getroffen wird, sollte ein 5-Tage technischer Spike folgende Fragen beantworten:

1. Können aktive Audio-Apps zuverlässig erkannt werden?
2. Ist die Latenz bei Video-Playback akzeptabel? (Ziel: < 40ms)
3. Was passiert bei DRM-Streams (Apple Music, Netflix)?
4. Kommt das Entitlement durch App Store Review? (→ TestFlight-Submit nötig)

> **Punkt 4 ist der Strategy-Killer.** Wenn Apple das Entitlement ablehnt, ist dieser Weg technisch tot. Das lässt sich nur durch echten TestFlight-Submit herausfinden.

#### Offene Fragen

- [ ] Ist dies für v4.0 (App Store) oder eine eigenständige v3.x-Erweiterung geplant?
- [ ] Wie verhält sich das zu der aktuellen HAL-Plugin-Architektur?
- [ ] Welches Preismodell ist für eine App-Store-Version realistisch?
- [ ] Wie wird die v3.4-DMG-Nutzerbasis migriert (Upgrade-Pricing existiert im App Store nicht)?

---

## Verworfene Ideen

*(leer — noch keine Einträge)*

---

## Referenz-Dokumente

- [`v4-appstore/PLAN.md`](v4-appstore/PLAN.md) — Technische v4.0 Architektur (Process Taps)
- [`RELEASE_NOTES.md`](RELEASE_NOTES.md) — Aktueller Stand v3.4.0
- [`PLAN.md`](PLAN.md) — Abgeschlossener Stability-Hardening-Plan (historisch)

---

*Zuletzt aktualisiert: 12. Juni 2026*
