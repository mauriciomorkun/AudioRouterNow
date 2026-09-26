# Zentrale Versionsnummer für AudioRouterNow
# Diese Datei ist die einzige Quelle der Versionsnummer, alle anderen Dateien importieren von hier.
APP_VERSION = "3.4.6"

# Die älteste macOS-Version, die ein Build unterstützen soll. Das ist die Zahl,
# die README, Landing Page und Appcast dem Nutzer versprechen. Sie steht hier
# genau einmal, damit Versprechen und Kompilat nicht auseinanderlaufen können.
#
# Wer sie liest:
#   installer/build.sh             Schwellwert des minos-Gates (per awk gelesen)
#   installer/AudioRouterNow.spec  LSMinimumSystemVersion der App-Info.plist
#   driver/Makefile                -mmacosx-version-min für Treiber und Helper
#   helper/Makefile                -mmacosx-version-min beim Einzelbau des Helpers
#
# Die drei letzten erzeugen den Wert tatsächlich im Binary, build.sh misst ihn
# danach nach. Die .spec beschriftet ihn nur.
#
# Bewusste Ausnahme: driver/resources/Info.plist trägt die Zahl weiterhin von
# Hand. Das Driver-Makefile kopiert diese Datei unverändert ins Bundle, eine
# Ableitung bräuchte dort einen zusätzlichen sed-Schritt im Kopierziel. Wer den
# Wert hier ändert, muss ihn dort nachziehen.
MACOS_MIN_VERSION = "11.0"
