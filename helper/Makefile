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

# Zentrale Helper-Versionsnummer (Single Source of Truth fuer den C-Banner)
CFLAGS += -DARN_HELPER_VERSION=\"3.4.0\"

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
