# =============================================================================
# AudioRouterNow — HAL AudioServerPlugin + Helper Build (Phase 7)
#
#   make            Baut das .driver Bundle (inkl. Helper-Binary, Universal)
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
HELPER_NAME := AudioRouterNowHelper
BUNDLE      := $(DRIVER_NAME).driver

SRC_DIR     := src
RES_DIR     := resources
BUILD_DIR   := build

SRC         := $(SRC_DIR)/AudioRouterNowDriver.c
PLIST       := $(RES_DIR)/Info.plist

HELPER_DIR  := ../helper
HELPER_SRC  := $(HELPER_DIR)/AudioRouterNowHelper.c
HELPER_HDR  := $(HELPER_DIR)/shared_ring.h
HELPER_PLIST_SRC := $(HELPER_DIR)/com.audiorouter.now.helper.plist

BUNDLE_DIR  := $(BUILD_DIR)/$(BUNDLE)
CONTENTS    := $(BUNDLE_DIR)/Contents
MACOS_DIR   := $(CONTENTS)/MacOS
RES_BUNDLE  := $(CONTENTS)/Resources
BINARY      := $(MACOS_DIR)/$(EXEC_NAME)
HELPER_BIN  := $(MACOS_DIR)/$(HELPER_NAME)
HELPER_PLIST_DST := $(RES_BUNDLE)/com.audiorouter.now.helper.plist

INSTALL_DIR := /Library/Audio/Plug-Ins/HAL

# --- Compiler-Flags ----------------------------------------------------------
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

# Flags fuer Helper (Executable, kein dynamiclib, mit AudioToolbox)
HELPER_CFLAGS := $(ARCHS) \
                 -mmacosx-version-min=11.0 \
                 -O2 -Wall -Wextra -std=c11 \
                 -I$(HELPER_DIR)
HELPER_LDFLAGS := $(ARCHS) \
                  -framework CoreAudio \
                  -framework AudioToolbox \
                  -framework CoreFoundation

# =============================================================================
# Targets
# =============================================================================

.PHONY: all build install uninstall reload clean

all: build

build: $(BINARY) $(HELPER_BIN) $(CONTENTS)/Info.plist $(HELPER_PLIST_DST)
	@echo ""
	@echo "  Build fertig:  $(BUNDLE_DIR)"
	@echo "  Driver Archs:  $$(lipo -archs $(BINARY))"
	@echo "  Helper Archs:  $$(lipo -archs $(HELPER_BIN))"
	@echo ""
	@echo "  Naechster Schritt:  sudo make install && sudo make reload"
	@echo ""

# Driver-Binary
$(BINARY): $(SRC) | $(MACOS_DIR)
	@echo "==> Kompiliere & linke $(EXEC_NAME) (Universal Binary)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC)
	@echo "==> Ad-hoc Code-Signierung Driver"
	codesign --force --sign - --timestamp=none $@
	@echo "==> OK: $@"

# Helper-Binary (Phase 7: ins Bundle eingebettet)
$(HELPER_BIN): $(HELPER_SRC) $(HELPER_HDR) | $(MACOS_DIR)
	@echo "==> Kompiliere & linke $(HELPER_NAME) (Universal Binary)"
	$(CC) $(HELPER_CFLAGS) $(HELPER_LDFLAGS) -o $@ $(HELPER_SRC)
	@echo "==> Ad-hoc Code-Signierung Helper"
	codesign --force --sign - --timestamp=none $@
	@echo "==> OK: $@"

# Info.plist ins Bundle kopieren
$(CONTENTS)/Info.plist: $(PLIST) | $(CONTENTS)
	@echo "==> Kopiere Info.plist"
	cp $(PLIST) $@

# launchd plist ins Bundle/Resources kopieren
$(HELPER_PLIST_DST): $(HELPER_PLIST_SRC) | $(RES_BUNDLE)
	@echo "==> Kopiere launchd plist"
	cp $(HELPER_PLIST_SRC) $@

# --- Verzeichnis-Regeln ------------------------------------------------------
$(MACOS_DIR):
	mkdir -p $(MACOS_DIR)

$(CONTENTS):
	mkdir -p $(CONTENTS)

$(RES_BUNDLE):
	mkdir -p $(RES_BUNDLE)

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
	@# Helper auch ins App-Bundle kopieren (LaunchAgent startet von dort)
	@APP_HELPER="/Applications/AudioRouterNow.app/Contents/Frameworks/AudioRouterNow.driver/Contents/MacOS/AudioRouterNowHelper"; \
	if [ -d "$$(dirname $$APP_HELPER)" ]; then \
		cp "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/AudioRouterNowHelper" "$$APP_HELPER" && \
		echo "==> Helper auch nach App-Bundle kopiert"; \
	else \
		echo "==> Hinweis: App-Bundle nicht gefunden, nur HAL-Pfad aktualisiert"; \
	fi
	@echo "==> Installiert. Jetzt: sudo make reload"

uninstall:
	@echo "==> Entferne $(INSTALL_DIR)/$(BUNDLE)"
	@if [ "$$(id -u)" != "0" ]; then \
		echo "FEHLER: 'make uninstall' braucht root. Nutze: sudo make uninstall"; \
		exit 1; \
	fi
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	@echo "==> Entfernt. Jetzt: sudo make reload"

reload:
	@echo "==> Starte coreaudiod neu (Treiber wird neu geladen)"
	@if [ "$$(id -u)" != "0" ]; then \
		echo "FEHLER: 'make reload' braucht root. Nutze: sudo make reload"; \
		exit 1; \
	fi
	killall coreaudiod || true
	@echo "==> coreaudiod neu gestartet."

clean:
	@echo "==> Loesche $(BUILD_DIR)"
	rm -rf $(BUILD_DIR)
