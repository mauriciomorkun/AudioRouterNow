# =============================================================================
# AudioRouterNow — Helper Daemon Build
#
#   make            Baut AudioRouterNowHelper (Universal Binary arm64 + x86_64)
#   make clean      Loescht Build-Artefakte
#
# Typischer Ablauf (nach Driver-Install):
#   make && ./AudioRouterNowHelper
#   make && ./AudioRouterNowHelper <device-uid>
# =============================================================================

CC          := clang
BINARY      := AudioRouterNowHelper
SRC         := AudioRouterNowHelper.c
BUILD_DIR   := build

OUT         := $(BUILD_DIR)/$(BINARY)

# --- Werte aus engine/version.py ---------------------------------------------
# Einzige Quelle fuer die Versionsnummer und fuer das Deployment-Target.
#
# Dieser Block steht bewusst VOR den Compiler-Flags. Beide Variablen werden mit
# ':=' sofort ausgewertet; stuende er darunter, waere $(ARN_MACOS_MIN) beim
# Expandieren der CFLAGS noch leer. clang bricht dann zwar ab, aber mit
# "missing version number" statt mit der Meldung hier.
#
# Dieses Makefile wird nur beim Einzelbau des Helpers benutzt. Im Release baut
# das Driver-Makefile den Helper mit; beide muessen denselben Wert setzen,
# sonst haengt das Deployment-Target davon ab, welcher Weg gewaehlt wurde.
ARN_VERSION := $(shell python3 -c "import re,sys; m=re.search(r'APP_VERSION\s*=\s*\"([^\"]+)\"',open('../engine/version.py').read()); print(m.group(1)) if m else sys.exit(1)" 2>/dev/null)
$(if $(ARN_VERSION),,$(error ARN_VERSION konnte nicht aus ../engine/version.py gelesen werden))

ARN_MACOS_MIN := $(shell python3 -c "import re,sys; m=re.search(r'MACOS_MIN_VERSION\s*=\s*\"([^\"]+)\"',open('../engine/version.py').read()); print(m.group(1)) if m else sys.exit(1)" 2>/dev/null)
$(if $(ARN_MACOS_MIN),,$(error ARN_MACOS_MIN konnte nicht aus ../engine/version.py gelesen werden))

# --- Compiler-Flags ----------------------------------------------------------
ARCHS       := -arch arm64 -arch x86_64

CFLAGS      := $(ARCHS) \
               -mmacosx-version-min=$(ARN_MACOS_MIN) \
               -O2 \
               -Wall -Wextra \
               -std=c11 \
               -I. \
               -DARN_HELPER_VERSION=\"$(ARN_VERSION)\"

LDFLAGS     := $(ARCHS) \
               -framework CoreAudio \
               -framework AudioToolbox \
               -framework CoreFoundation \
               -lproc               # P0-D: proc_pid_rusage fuer coreaudiod-Watchdog

# =============================================================================
# Targets
# =============================================================================

.PHONY: all clean

all: $(OUT)
	@echo ""
	@echo "  Build fertig: $(OUT)"
	@echo "  Architekturen: $$(lipo -archs $(OUT))"
	@echo ""
	@echo "  Starten mit:  ./$(OUT)"
	@echo "              oder ./$(OUT) <device-uid>"
	@echo ""
	# Symlink im Projektroot fuer bequemen Zugriff
	@ln -sf $(OUT) ./$(BINARY) 2>/dev/null || true

$(OUT): $(SRC) shared_ring.h | $(BUILD_DIR)
	@echo "==> Kompiliere $(BINARY) (Universal Binary)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(OUT) $(SRC)
	@echo "==> Ad-hoc Code-Signierung"
	codesign --force --sign - --timestamp=none $(OUT)
	@echo "==> OK: $(OUT)"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	@echo "==> Loesche $(BUILD_DIR) und Symlink"
	rm -rf $(BUILD_DIR)
	rm -f ./$(BINARY)
