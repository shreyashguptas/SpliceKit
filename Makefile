CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation -framework Speech -framework CoreServices -framework CoreImage -framework Metal -framework MetalKit -framework QuartzCore -framework Vision
MODULE_CACHE_DIR = $(BUILD_DIR)/ModuleCache
OBJC_FLAGS = -fobjc-arc -fmodules -fmodules-cache-path=$(abspath $(MODULE_CACHE_DIR))
OBJCXX_FLAGS = $(OBJC_FLAGS) -std=c++17
DEBUG_FLAGS = -g
LINKER_FLAGS = -undefined dynamic_lookup -dynamiclib
CPP_LIBS = -lc++
INSTALL_NAME = -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit
SPLICEKIT_VERSION = $(shell tr -d ' \n' < VERSION)
VERSION_DEFINE = -DSPLICEKIT_VERSION=\"$(SPLICEKIT_VERSION)\"
DSYM = $(OUTPUT).dSYM

# Read canonical source list from Sources/SOURCES.txt
SOURCES = $(addprefix Sources/, $(shell grep -v '^\#' Sources/SOURCES.txt | grep -v '^$$'))
# Every object depends on every header: they are small, and a changed struct or
# prototype in any of them must rebuild its users. .def files are included X-macro
# tables (SpliceKitRPCTable.def), so a changed row must rebuild too.
HEADERS = $(shell find Sources -name '*.h' -o -name '*.def')
INCLUDES = $(addprefix -I ,$(sort $(dir $(HEADERS))))
OBJC_SOURCES = $(filter %.m,$(SOURCES))
OBJCXX_SOURCES = $(filter %.mm,$(SOURCES))
OBJS = $(patsubst Sources/%.m,$(BUILD_DIR)/obj/%.o,$(OBJC_SOURCES)) \
	$(patsubst Sources/%.mm,$(BUILD_DIR)/obj/%.o,$(OBJCXX_SOURCES))

BUILD_DIR = build
OUTPUT = $(BUILD_DIR)/SpliceKit

# Lua 5.4.7 (vendored, compiled as static lib)
LUA_DIR = vendor/lua-5.4.7/src
LUA_SRCS = $(wildcard $(LUA_DIR)/*.c)
LUA_OBJS = $(patsubst $(LUA_DIR)/%.c, $(BUILD_DIR)/lua/%.o, $(LUA_SRCS))
LUA_LIB = $(BUILD_DIR)/liblua.a

# Modded app paths. `make install` puts the patched copy in /Applications under
# a distinct name, beside the untouched original — check there first, or these
# targets deploy into a stale location and report success against an app that
# is not the one being launched. The ~/Applications paths are kept for installs
# made by older versions of the patcher.
MODDED_APP_MODIFIED = /Applications/Final Cut Pro Modified.app
MODDED_APP_STANDARD = $(HOME)/Applications/SpliceKit/Final Cut Pro.app
MODDED_APP_CREATOR = $(HOME)/Applications/SpliceKit/Final Cut Pro Creator Studio.app
MODDED_APP = $(shell if [ -d "$(MODDED_APP_MODIFIED)" ]; then echo "$(MODDED_APP_MODIFIED)"; elif [ -d "$(MODDED_APP_STANDARD)" ]; then echo "$(MODDED_APP_STANDARD)"; elif [ -d "$(MODDED_APP_CREATOR)" ]; then echo "$(MODDED_APP_CREATOR)"; else echo "$(MODDED_APP_MODIFIED)"; fi)
FW_DIR = $(MODDED_APP)/Contents/Frameworks/SpliceKit.framework
ENTITLEMENTS = patcher/entitlements.plist

# $(call plist_set,Key,Value): set a string key in the patched app's Info.plist.
plist_set = /usr/libexec/PlistBuddy -c "Set :$(1) '$(2)'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Add :$(1) string '$(2)'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true

SILENCE_DETECTOR = $(BUILD_DIR)/silence-detector
STRUCTURE_ANALYZER = $(BUILD_DIR)/structure-analyzer
AUDIO_LEVELS = $(BUILD_DIR)/audio-levels
BEAT_DETECTOR = $(BUILD_DIR)/beat-detector
TOOLS_DIR = $(HOME)/Applications/SpliceKit/tools
# Transcription helpers (Parakeet for the transcript panel, Whisper for the
# caption panel), built from helpers/<name> by scripts/build-transcribers.sh and
# cached in build/.
PARAKEET_BIN = $(BUILD_DIR)/parakeet-transcriber
WHISPER_BIN = $(BUILD_DIR)/whisper-transcriber

# --- VP9 codec bundle (plugins/vp9 → FCP.app/Contents/PlugIns/Codecs) --------
VP9_SOURCE_DIR = plugins/vp9/Sources
VP9_PRIVATE_DIR = $(VP9_SOURCE_DIR)/Private
# SPI headers shared by the VP9 decoder and the MKV reader (plugins/common/Private).
PLUGIN_COMMON_DIR = plugins/common
VP9_BUILD_DIR = $(BUILD_DIR)/vp9
VP9_DECODER_BUNDLE = $(VP9_BUILD_DIR)/Codecs/SpliceKitVP9Decoder.bundle
VP9_DECODER_EXEC = $(VP9_DECODER_BUNDLE)/Contents/MacOS/SpliceKitVP9Decoder
VP9_DECODER_INFO = plugins/vp9/Codecs/SpliceKitVP9Decoder.bundle/Contents/Info.plist
VP9_DECODER_SOURCES = $(VP9_SOURCE_DIR)/VP9VideoDecoder.mm
VP9_FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox
VP9_CFLAGS = $(ARCHS) $(MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) -fvisibility=hidden -I $(VP9_SOURCE_DIR) -I $(VP9_PRIVATE_DIR) -I $(PLUGIN_COMMON_DIR) -I $(PLUGIN_COMMON_DIR)/Private
VP9_LDFLAGS = -bundle $(CPP_LIBS)

# --- MKV/WebM format reader (plugins/mkv → FCP.app/Contents/PlugIns/FormatReaders) ---
MKV_SOURCE_DIR = plugins/mkv/Sources
MKV_LIBWEBM_DIR = $(MKV_SOURCE_DIR)/libwebm
MKV_BUILD_DIR = $(BUILD_DIR)/mkv
MKV_IMPORT_BUNDLE = $(MKV_BUILD_DIR)/FormatReaders/SpliceKitMKVImport.bundle
MKV_IMPORT_EXEC = $(MKV_IMPORT_BUNDLE)/Contents/MacOS/SpliceKitMKVImport
MKV_IMPORT_INFO = plugins/mkv/FormatReaders/SpliceKitMKVImport.bundle/Contents/Info.plist
MKV_IMPORT_SOURCES = $(MKV_SOURCE_DIR)/MKVCommon.mm \
                      $(MKV_SOURCE_DIR)/MKVFormatReader.mm \
                      $(MKV_LIBWEBM_DIR)/mkvparser/mkvparser.cc \
                      $(MKV_LIBWEBM_DIR)/mkvparser/mkvreader.cc
MKV_FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework MediaToolbox -framework AudioToolbox
# libwebm uses its own exceptions/assert flow; keep default C++ settings but
# disable ObjC ARC for the .mm so we can freely mix with C++ heap types.
MKV_CFLAGS = $(ARCHS) $(MIN_VERSION) -fno-objc-arc -fmodules -fmodules-cache-path=$(abspath $(MODULE_CACHE_DIR)) -std=c++17 $(DEBUG_FLAGS) -fvisibility=hidden -Wno-deprecated-declarations -I $(MKV_SOURCE_DIR) -I $(PLUGIN_COMMON_DIR) -I $(MKV_LIBWEBM_DIR)
MKV_LDFLAGS = -bundle $(CPP_LIBS)

# A bare `make` builds the dylib. `install` is listed first below for readers, but
# it runs the interactive installer (a ~7 GB copy of Final Cut Pro), which must
# never be what an unqualified `make` does.
.DEFAULT_GOAL := all

.PHONY: all clean deploy tools url-import-tools symbols vp9 mkv mcp-setup mcp-doctor mcp-check mcp-check-live install install-check transcribers test test-unit

# One command to set up a fresh machine: Python 3.10+, a patched and renamed
# copy of Final Cut Pro, the MCP server (proven over the wire with
# tests/mcp_server_check.py before it is wired into Claude), and the patched
# app opened and read from through that server. Safe to re-run.
install:
	@bash scripts/install.sh

install-check:
	@bash scripts/install.sh --check

# Build the Parakeet/Whisper CLI helpers on their own and install them into the
# patched app plus Application Support. `make install` does this already; this
# target exists for retrying after a failed dependency download.
transcribers:
	@bash scripts/build-transcribers.sh --framework "$(FW_DIR)"

all: $(OUTPUT)

symbols: $(DSYM)

tools: $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER) $(AUDIO_LEVELS) $(BEAT_DETECTOR)

# ---------------------------------------------------------------------------
# MCP server setup (Python venv + dependencies)
# ---------------------------------------------------------------------------
MCP_VENV ?= $(HOME)/.venvs/splicekit-mcp
MCP_PYTHON = $(MCP_VENV)/bin/python
MCP_REQUIREMENTS = mcp/requirements.txt

# MCP_BOOTSTRAP_PYTHON: the interpreter to build the venv with (install.sh
# passes the one it found). Otherwise PATH is searched, then Homebrew's opt/
# directory, because a versioned python that is not Homebrew's current default
# is keg-only: installed, but not linked into PATH.
MCP_BOOTSTRAP_PYTHON ?=
mcp-setup:
	@PY=""; \
	if [ -n "$(MCP_BOOTSTRAP_PYTHON)" ] && "$(MCP_BOOTSTRAP_PYTHON)" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then \
		PY="$(MCP_BOOTSTRAP_PYTHON)"; \
	fi; \
	if [ -z "$$PY" ]; then for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do \
		p="$$(command -v $$c 2>/dev/null)" || continue; \
		[ -n "$$p" ] || continue; \
		"$$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null || continue; \
		PY="$$p"; break; \
	done; fi; \
	if [ -z "$$PY" ]; then \
		BREW_PREFIX="$$(brew --prefix 2>/dev/null || true)"; \
		for prefix in $$BREW_PREFIX /opt/homebrew /usr/local; do \
			for v in 3.14 3.13 3.12 3.11 3.10; do \
				p="$$prefix/opt/python@$$v/bin/python$$v"; \
				if [ -x "$$p" ]; then PY="$$p"; break 2; fi; \
			done; \
		done; \
	fi; \
	if [ -z "$$PY" ]; then \
		echo "[mcp-setup] No Python 3.10+ found in PATH."; \
		echo "[mcp-setup] The mcp package requires Python >= 3.10; macOS ships 3.9."; \
		echo "[mcp-setup] Install one, then re-run:  brew install python@3.12"; \
		exit 1; \
	fi; \
	echo "[mcp-setup] Using interpreter: $$PY ($$($$PY --version 2>&1))"; \
	if [ ! -x "$(MCP_PYTHON)" ]; then \
		echo "[mcp-setup] Creating venv at $(MCP_VENV)"; \
		"$$PY" -m venv "$(MCP_VENV)"; \
	elif ! "$(MCP_PYTHON)" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then \
		echo "[mcp-setup] Existing venv runs $$("$(MCP_PYTHON)" --version 2>&1), which is too old for mcp."; \
		echo "[mcp-setup] Recreating it with $$PY"; \
		rm -rf "$(MCP_VENV)"; \
		"$$PY" -m venv "$(MCP_VENV)"; \
	else \
		echo "[mcp-setup] Reusing venv at $(MCP_VENV) ($$("$(MCP_PYTHON)" --version 2>&1))"; \
	fi
	@"$(MCP_PYTHON)" -m pip install --upgrade --quiet pip
	@"$(MCP_PYTHON)" -m pip install --upgrade --quiet -r $(MCP_REQUIREMENTS)
	@echo "[mcp-setup] Installed:"; "$(MCP_PYTHON)" -m pip show mcp | awk '/^(Name|Version|Location):/'
	@echo "[mcp-setup] Done. Point your MCP client's 'command' at: $(MCP_PYTHON)"

# Prove the server works over the real MCP wire. `mcp-check` needs no Final Cut
# Pro: it starts mcp/server.py as a stdio subprocess (the way a client does),
# talks to it with the official SDK and calls every tool against a fake bridge.
# `mcp-check-live` does the same read-only against the bridge inside the running
# patched Final Cut Pro. `make install` runs both.
mcp-check:
	@test -x "$(MCP_PYTHON)" || { echo "[mcp-check] No MCP virtualenv at $(MCP_PYTHON) — run 'make mcp-setup' first"; exit 1; }
	@"$(MCP_PYTHON)" tests/mcp_server_check.py

mcp-check-live:
	@test -x "$(MCP_PYTHON)" || { echo "[mcp-check-live] No MCP virtualenv at $(MCP_PYTHON) — run 'make mcp-setup' first"; exit 1; }
	@"$(MCP_PYTHON)" tests/mcp_server_check.py --live

# Every offline check in one command: the unit tests and the MCP wire check. None
# of it needs Final Cut Pro. SPLICEKIT_PORT=1 points anything that would reach for
# the bridge at a port nothing listens on, so a running Final Cut Pro is never
# touched. The live checks (mcp-check-live, tests/live/) stay opt-in.
test: test-unit mcp-check

test-unit:
	@test -x "$(MCP_PYTHON)" || { echo "[test-unit] No MCP virtualenv at $(MCP_PYTHON) — run 'make mcp-setup' first"; exit 1; }
	@SPLICEKIT_PORT=1 "$(MCP_PYTHON)" -m unittest discover -s tests -p 'test_*.py'

mcp-doctor:
	@echo "== SpliceKit MCP doctor =="
	@if [ -x "$(MCP_PYTHON)" ]; then \
		echo "[ok] venv interpreter:    $(MCP_PYTHON) ($$($(MCP_PYTHON) --version 2>&1))"; \
	else \
		echo "[FAIL] venv interpreter missing at $(MCP_PYTHON) — run 'make mcp-setup'"; \
	fi
	@if [ -x "$(MCP_PYTHON)" ] && "$(MCP_PYTHON)" -c "import mcp.server.mcpserver" >/dev/null 2>&1; then \
		echo "[ok] mcp package:         $$($(MCP_PYTHON) -m pip show mcp | awk '/^Version:/{print $$2}')"; \
	else \
		echo "[FAIL] mcp package not importable in venv — run 'make mcp-setup'"; \
	fi
	@if [ -f .mcp.json ]; then \
		CMD=$$(/usr/bin/python3 -c "import json; print(json.load(open('.mcp.json'))['mcpServers']['splicekit']['command'])" 2>/dev/null); \
		if [ "$$CMD" = "$(MCP_PYTHON)" ]; then \
			echo "[ok] .mcp.json command:   $$CMD"; \
		else \
			echo "[warn] .mcp.json command: $$CMD (expected $(MCP_PYTHON))"; \
		fi; \
	else \
		echo "[warn] .mcp.json not found in repo root — run ./scripts/setup-mcp.sh"; \
	fi
	@if /usr/sbin/lsof -nP -iTCP:9876 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then \
		echo "[ok] FCP bridge listening on 127.0.0.1:9876 — run 'make mcp-check-live' to drive it through the MCP server"; \
	else \
		echo "[warn] No process listening on :9876 — launch the modded Final Cut Pro"; \
	fi
	@echo "[i] Full offline proof (every tool over MCP, no FCP needed): make mcp-check"

url-import-tools:
	@mkdir -p "$(TOOLS_DIR)"
	@YTDLP_PATH="$$(command -v yt-dlp || true)"; \
	if [ -n "$$YTDLP_PATH" ]; then \
		ln -sf "$$YTDLP_PATH" "$(TOOLS_DIR)/yt-dlp"; \
		echo "Linked yt-dlp -> $$YTDLP_PATH"; \
	else \
		echo "yt-dlp not found in PATH. Install with: brew install yt-dlp"; \
	fi
	@FFMPEG_PATH="$$(command -v ffmpeg || true)"; \
	if [ -n "$$FFMPEG_PATH" ]; then \
		ln -sf "$$FFMPEG_PATH" "$(TOOLS_DIR)/ffmpeg"; \
		echo "Linked ffmpeg -> $$FFMPEG_PATH"; \
	else \
		echo "ffmpeg not found in PATH. Install with: brew install ffmpeg"; \
	fi
	@FFPROBE_PATH="$$(command -v ffprobe || true)"; \
	if [ -n "$$FFPROBE_PATH" ]; then \
		ln -sf "$$FFPROBE_PATH" "$(TOOLS_DIR)/ffprobe"; \
		echo "Linked ffprobe -> $$FFPROBE_PATH"; \
	else \
		echo "ffprobe not found in PATH. Install with: brew install ffmpeg"; \
	fi

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/lua: | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/lua

$(BUILD_DIR)/obj: | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/obj

$(SILENCE_DETECTOR): helpers/silence-detector.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(SILENCE_DETECTOR) helpers/silence-detector.swift
	@echo "Built: $(SILENCE_DETECTOR)"

$(STRUCTURE_ANALYZER): helpers/structure-analyzer.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(STRUCTURE_ANALYZER) helpers/structure-analyzer.swift
	@echo "Built: $(STRUCTURE_ANALYZER)"

$(BEAT_DETECTOR): helpers/beat-detector.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(BEAT_DETECTOR) helpers/beat-detector.swift
	@codesign --force --sign - $(BEAT_DETECTOR) >/dev/null 2>&1 || true
	@echo "Built: $(BEAT_DETECTOR)"

# Peak/RMS levels of a media file's audio (timeline.getAudioLevels shells out to it:
# in-process AVFoundation audio decoding deadlocks inside Final Cut Pro).
$(AUDIO_LEVELS): helpers/audio-levels.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(AUDIO_LEVELS) helpers/audio-levels.swift
	@codesign --force --sign - $(AUDIO_LEVELS) >/dev/null 2>&1 || true
	@echo "Built: $(AUDIO_LEVELS)"

# Lua static library — compiled as C (no -fobjc-arc)
$(BUILD_DIR)/lua/%.o: $(LUA_DIR)/%.c | $(BUILD_DIR)/lua
	$(CC) $(ARCHS) $(MIN_VERSION) -DLUA_USE_MACOSX -O2 -Wall -c $< -o $@

$(LUA_LIB): $(LUA_OBJS) | $(BUILD_DIR)
	libtool -static -o $@ $^
	@echo "Built: $(LUA_LIB)"

$(BUILD_DIR)/obj/%.o: Sources/%.m $(HEADERS) | $(BUILD_DIR)/obj
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(MIN_VERSION) $(OBJC_FLAGS) $(DEBUG_FLAGS) $(VERSION_DEFINE) \
		$(INCLUDES) -I $(LUA_DIR) -c $< -o $@

$(BUILD_DIR)/obj/%.o: Sources/%.mm $(HEADERS) | $(BUILD_DIR)/obj
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) $(VERSION_DEFINE) \
		$(INCLUDES) -I $(LUA_DIR) -c $< -o $@

$(OUTPUT): $(OBJS) $(LUA_LIB) | $(BUILD_DIR)
	$(CC) $(ARCHS) $(MIN_VERSION) $(FRAMEWORKS) $(LINKER_FLAGS) \
		$(INSTALL_NAME) $(OBJS) $(LUA_LIB) $(CPP_LIBS) -o $(OUTPUT)
	@# -undefined dynamic_lookup lets calls into FCP internals resolve at load time,
	@# but it also silently permits unresolved SpliceKit_* symbols (missing .m files
	@# not listed in SOURCES.txt). Those become NULL in the host and crash FCP with
	@# pc=0 during init. Fail the build if any SpliceKit_ symbol is undefined.
	@undef="$$(nm -u $(OUTPUT) | awk '/^_SpliceKit_/ {print $$NF}' | sort -u)"; \
	if [ -n "$$undef" ]; then \
		echo "ERROR: undefined SpliceKit_* symbols in $(OUTPUT):" >&2; \
		echo "$$undef" | sed 's/^/  /' >&2; \
		echo "Add the missing .m file(s) to Sources/SOURCES.txt." >&2; \
		rm -f $(OUTPUT); \
		exit 1; \
	fi
	@echo "Built: $(OUTPUT)"
	@file $(OUTPUT)

$(DSYM): $(OUTPUT)
	dsymutil "$(OUTPUT)" -o "$(DSYM)"
	@echo "Built: $(DSYM)"

clean:
	rm -rf $(BUILD_DIR)

$(VP9_DECODER_EXEC): $(VP9_DECODER_SOURCES) $(VP9_DECODER_INFO) | $(BUILD_DIR)
	@mkdir -p "$(VP9_DECODER_BUNDLE)/Contents/MacOS"
	@cp "$(VP9_DECODER_INFO)" "$(VP9_DECODER_BUNDLE)/Contents/Info.plist"
	$(CC) $(VP9_CFLAGS) $(VP9_FRAMEWORKS) $(VP9_DECODER_SOURCES) $(VP9_LDFLAGS) -o "$(VP9_DECODER_EXEC)"
	@codesign --force --sign - "$(VP9_DECODER_BUNDLE)" >/dev/null
	@echo "Built: $(VP9_DECODER_BUNDLE)"

vp9: $(VP9_DECODER_EXEC)

$(MKV_IMPORT_EXEC): $(MKV_IMPORT_SOURCES) $(MKV_IMPORT_INFO) | $(BUILD_DIR)
	@mkdir -p "$(MKV_IMPORT_BUNDLE)/Contents/MacOS"
	@cp "$(MKV_IMPORT_INFO)" "$(MKV_IMPORT_BUNDLE)/Contents/Info.plist"
	$(CC) $(MKV_CFLAGS) $(MKV_FRAMEWORKS) $(MKV_IMPORT_SOURCES) $(MKV_LDFLAGS) -o "$(MKV_IMPORT_EXEC)"
	@codesign --force --sign - "$(MKV_IMPORT_BUNDLE)" >/dev/null
	@echo "Built: $(MKV_IMPORT_BUNDLE)"

mkv: $(MKV_IMPORT_EXEC)

# Install this checkout into the patched app: the framework, the helper CLIs,
# the plugin bundles, the Lua scripts, then re-sign. `make install` runs this
# too (patcher/patch_fcp.sh), so both routes install the same thing. The helpers
# and plugin bundles are best-effort: a failed one costs its own feature, not
# the install. Override the target app with MODDED_APP=<path>.
deploy: $(OUTPUT)
	@test -d "$(MODDED_APP)" || { echo "[X] No patched app at $(MODDED_APP) — run 'make install' first"; exit 1; }
	@echo "=== Deploying SpliceKit $(SPLICEKIT_VERSION) into $(MODDED_APP) ==="
	@$(MAKE) -k tools vp9 mkv || echo "[!] Some helpers or plugin bundles did not build; their features will report them missing."
	@rm -rf "$(FW_DIR)"
	@mkdir -p "$(FW_DIR)/Versions/A/Resources"
	cp $(OUTPUT) "$(FW_DIR)/Versions/A/SpliceKit"
	@# -n so repeated deploys replace the symlink instead of following it into Versions/A.
	@cd "$(FW_DIR)/Versions" && ln -sfn A Current
	@cd "$(FW_DIR)" && ln -sfn Versions/Current/SpliceKit SpliceKit
	@cd "$(FW_DIR)" && ln -sfn Versions/Current/Resources Resources
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>' \
		'<key>CFBundleName</key><string>SpliceKit</string>' \
		'<key>CFBundleVersion</key><string>$(SPLICEKIT_VERSION)</string>' \
		'<key>CFBundleShortVersionString</key><string>$(SPLICEKIT_VERSION)</string>' \
		'<key>CFBundlePackageType</key><string>FMWK</string>' \
		'<key>CFBundleExecutable</key><string>SpliceKit</string>' \
		'</dict></plist>' > "$(FW_DIR)/Versions/A/Resources/Info.plist"
	@# Privacy usage descriptions for the transcript, LiveCam and palette voice dictation.
	@# Info.plist edits must come before signing: the signature seals Info.plist.
	@$(call plist_set,NSSpeechRecognitionUsageDescription,SpliceKit uses speech recognition for transcript editing and command palette voice dictation inside Final Cut Pro.)
	@$(call plist_set,NSCameraUsageDescription,SpliceKit LiveCam uses the camera for native webcam recording inside Final Cut Pro.)
	@$(call plist_set,NSMicrophoneUsageDescription,SpliceKit uses the microphone for LiveCam capture and command palette voice dictation inside Final Cut Pro.)
	@# Helper CLIs. The dylib looks in the framework's Resources first.
	@mkdir -p "$(TOOLS_DIR)"
	@$(MAKE) url-import-tools
	@for h in silence-detector structure-analyzer audio-levels beat-detector; do \
		cp "$(BUILD_DIR)/$$h" "$(TOOLS_DIR)/$$h" 2>/dev/null || true; \
	done
	@for h in silence-detector audio-levels beat-detector; do \
		cp "$(BUILD_DIR)/$$h" "$(FW_DIR)/Versions/A/Resources/$$h" 2>/dev/null || true; \
	done
	@# Build (cached) and install the Parakeet/Whisper CLIs into both the
	@# framework Resources and Application Support. Non-fatal by design.
	@bash scripts/build-transcribers.sh --framework "$(FW_DIR)" || \
		echo "[!] Transcription helpers unavailable — see build/*-build.log"
	@cp "$(PARAKEET_BIN)" "$(TOOLS_DIR)/parakeet-transcriber" 2>/dev/null || true
	@cp "$(WHISPER_BIN)" "$(TOOLS_DIR)/whisper-transcriber" 2>/dev/null || true
	@# Lua scripts and the plugins folder. -n keeps scripts the user has edited.
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/plugins"
	@for d in examples menu lib auto; do mkdir -p "$(HOME)/Library/Application Support/SpliceKit/lua/$$d"; done
	@for d in examples menu lib; do \
		cp -n lua/$$d/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/$$d/" 2>/dev/null || true; \
	done
	@# Plugin bundles, when they built.
	@if [ -d "$(VP9_DECODER_BUNDLE)" ]; then \
		mkdir -p "$(MODDED_APP)/Contents/PlugIns/Codecs"; \
		rm -rf "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"; \
		cp -R "$(VP9_DECODER_BUNDLE)" "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"; \
		echo "VP9 decoder bundle installed"; \
	fi
	@if [ -d "$(MKV_IMPORT_BUNDLE)" ]; then \
		mkdir -p "$(MODDED_APP)/Contents/PlugIns/FormatReaders"; \
		rm -rf "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"; \
		cp -R "$(MKV_IMPORT_BUNDLE)" "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"; \
		echo "MKV/WebM format reader installed"; \
	fi
	@bash scripts/sign-app.sh "$(MODDED_APP)" "$(ENTITLEMENTS)"
	@echo "=== Deployed successfully ==="
