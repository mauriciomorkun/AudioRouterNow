# =============================================================================
# AudioRouterNow — HAL AudioServerPlugin Build
#
#   make            Baut das .driver Bundle (Universal Binary arm64 + x86_64)
#   make install    Kopiert das Bundle nach /Library/Audio/Plug-Ins/HAL/ (sudo)
#   make uninstall  Entfernt das installierte Bundle (sudo)
#   make reload     Startet coreaudiod neu, damit der Treiber geladen wird (sudo)
#   make clean      Loescht Build-Artefakte
#
# Typischer Ablauf:  make && sudo make install && sudo make reload
# =============================================================================

# --- Werkzeuge ---------------------------------------------------------------
CC          := clang

# --- Namen / Pfade -----------------------------------------------------------
DRIVER_NAME := AudioRouterNow
EXEC_NAME   := AudioRouterNowDriver
BUNDLE      := $(DRIVER_NAME).driver

SRC_DIR     := src
RES_DIR     := resources
BUILD_DIR   := build

SRC         := $(SRC_DIR)/AudioRouterNowDriver.c
PLIST       := $(RES_DIR)/Info.plist

BUNDLE_DIR  := $(BUILD_DIR)/$(BUNDLE)
CONTENTS    := $(BUNDLE_DIR)/Contents
MACOS_DIR   := $(CONTENTS)/MacOS
BINARY      := $(MACOS_DIR)/$(EXEC_NAME)

INSTALL_DIR := /Library/Audio/Plug-Ins/HAL

# --- Compiler-Flags ----------------------------------------------------------
# Universal Binary: arm64 (Apple Silicon) + x86_64 (Intel).
ARCHS       := -arch arm64 -arch x86_64

CFLAGS      := $(ARCHS) \
               -mmacosx-version-min=11.0 \
               -fvisibility=hidden \
               -DNDEBUG \
               -O2 \
               -Wall -Wextra \
               -std=c11

LDFLAGS     := $(ARCHS) \
               -dynamiclib \
               -framework CoreAudio \
               -framework CoreFoundation

# =============================================================================
# Targets
# =============================================================================

.PHONY: all build install uninstall reload clean

all: build

# --- Bundle bauen ------------------------------------------------------------
build: $(BINARY) $(CONTENTS)/Info.plist
	@echo ""
	@echo "  Build fertig:  $(BUNDLE_DIR)"
	@echo "  Architekturen: $$(lipo -archs $(BINARY))"
	@echo ""
	@echo "  Naechster Schritt:  sudo make install && sudo make reload"
	@echo ""

# Universal-Binary kompilieren und linken
$(BINARY): $(SRC) | $(MACOS_DIR)
	@echo "==> Kompiliere & linke $(EXEC_NAME) (Universal Binary)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC)
	@echo "==> Ad-hoc Code-Signierung (noetig fuer Apple Silicon)"
	codesign --force --sign - --timestamp=none $@
	@echo "==> OK: $@"

# Info.plist ins Bundle kopieren
$(CONTENTS)/Info.plist: $(PLIST) | $(CONTENTS)
	@echo "==> Kopiere Info.plist"
	cp $(PLIST) $@

# --- Verzeichnis-Regeln ------------------------------------------------------
$(MACOS_DIR):
	mkdir -p $(MACOS_DIR)

$(CONTENTS):
	mkdir -p $(CONTENTS)

# --- Installation ------------------------------------------------------------
install: build
	@echo "==> Installiere nach $(INSTALL_DIR)/$(BUNDLE)"
	@if [ "$$(id -u)" != "0" ]; then \
		echo "FEHLER: 'make install' braucht root. Nutze: sudo make install"; \
		exit 1; \
	fi
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	mkdir -p "$(INSTALL_DIR)"
	cp -R "$(BUNDLE_DIR)" "$(INSTALL_DIR)/"
	codesign --force --deep --sign - "$(INSTALL_DIR)/$(BUNDLE)" || true
	chown -R root:wheel "$(INSTALL_DIR)/$(BUNDLE)"
	chmod -R 755 "$(INSTALL_DIR)/$(BUNDLE)"
	@echo "==> Installiert. Jetzt: sudo make reload"

# --- Deinstallation ----------------------------------------------------------
uninstall:
	@echo "==> Entferne $(INSTALL_DIR)/$(BUNDLE)"
	@if [ "$$(id -u)" != "0" ]; then \
		echo "FEHLER: 'make uninstall' braucht root. Nutze: sudo make uninstall"; \
		exit 1; \
	fi
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	@echo "==> Entfernt. Jetzt: sudo make reload"

# --- coreaudiod neu starten --------------------------------------------------
reload:
	@echo "==> Starte coreaudiod neu (Treiber wird neu geladen)"
	@if [ "$$(id -u)" != "0" ]; then \
		echo "FEHLER: 'make reload' braucht root. Nutze: sudo make reload"; \
		exit 1; \
	fi
	killall coreaudiod || true
	@echo "==> coreaudiod neu gestartet."

# --- Aufraeumen --------------------------------------------------------------
clean:
	@echo "==> Loesche $(BUILD_DIR)"
	rm -rf $(BUILD_DIR)
