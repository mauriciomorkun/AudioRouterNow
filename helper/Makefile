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

# --- Compiler-Flags ----------------------------------------------------------
ARCHS       := -arch arm64 -arch x86_64

CFLAGS      := $(ARCHS) \
               -mmacosx-version-min=11.0 \
               -O2 \
               -Wall -Wextra \
               -std=c11 \
               -I.

# Versionsnummer dynamisch aus engine/version.py lesen (einzige Quelle)
ARN_VERSION := $(shell python3 -c "import re,sys; m=re.search(r'APP_VERSION\s*=\s*\"([^\"]+)\"',open('../engine/version.py').read()); print(m.group(1)) if m else sys.exit(1)" 2>/dev/null)
$(if $(ARN_VERSION),,$(error ARN_VERSION konnte nicht aus ../engine/version.py gelesen werden))
CFLAGS      += -DARN_HELPER_VERSION=\"$(ARN_VERSION)\"

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
