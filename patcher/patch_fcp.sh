#!/bin/bash
#
# SpliceKit Patcher
# Patches Final Cut Pro to load the SpliceKit dylib for programmatic control.
#
# Usage:
#   ./patch_fcp.sh                     # Patch using defaults
#   ./patch_fcp.sh --dest ~/Desktop    # Custom destination
#   ./patch_fcp.sh --uninstall         # Remove the modded copy
#
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Auto-detect FCP edition: prefer standard, fall back to Creator Studio
CREATOR_STUDIO_APP="/Applications/Final Cut Pro Creator Studio.app"
STANDARD_APP="/Applications/Final Cut Pro.app"
if [[ -z "${SOURCE_APP:-}" ]]; then
    if [[ -d "$STANDARD_APP" ]]; then
        SOURCE_APP="$STANDARD_APP"
    elif [[ -d "$CREATOR_STUDIO_APP" ]]; then
        SOURCE_APP="$CREATOR_STUDIO_APP"
    else
        SOURCE_APP="$STANDARD_APP"  # will fail with a clear error later
    fi
fi
DEFAULT_DEST="/Applications"
DEST_DIR="${DEST_DIR:-$DEFAULT_DEST}"
APP_NAME="$(basename "$SOURCE_APP")"
BRIDGE_PORT=9876
VERSION="2.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[X]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

detect_sign_identity() {
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
        awk '
            /"Apple Development:/ { print $2; exit }
            /"Developer ID Application:/ && developer == "" { developer = $2 }
            /[0-9]+\) [0-9A-F]+ "/ && first == "" { first = $2 }
            END {
                if (developer != "") print developer;
                else if (first != "") print first;
            }'
}

sign_if_present() {
    local identity="$1"
    local path="$2"
    shift 2

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    if ! codesign --force --options runtime --sign "$identity" "$@" "$path"; then
        return 1
    fi
}

sign_modded_app() {
    local identity="$1"

    # Existing modded copies can already contain custom nested code from prior
    # SpliceKit installs. Sign those first so the top-level app seal doesn't
    # fail with "code object is not signed at all" on rebuild / no-copy flows.
    xattr -cr "$MODDED_APP" 2>/dev/null || true

    if ! sign_if_present "$identity" "$MODDED_APP/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle"; then
        return 1
    fi
    if ! sign_if_present "$identity" "$MODDED_APP/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle"; then
        return 1
    fi
    if ! sign_if_present "$identity" "$MODDED_APP/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"; then
        return 1
    fi
    if ! sign_if_present "$identity" "$MODDED_APP/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"; then
        return 1
    fi

    if ! codesign --force --options runtime --sign "$identity" "$MODDED_APP/Contents/Frameworks/SpliceKit.framework"; then
        return 1
    fi
    if ! codesign --force --options runtime --sign "$identity" --entitlements "$ENTITLEMENTS" "$MODDED_APP"; then
        return 1
    fi
}

# ============================================================
# Help
# ============================================================
usage() {
    cat << 'EOF'

  SpliceKit Patcher v2.0.0

  Creates a modded copy of Final Cut Pro with SpliceKit injected
  for direct programmatic control via JSON-RPC and MCP.

  Usage:
    ./patch_fcp.sh [options]

  Options:
    --dest DIR       Destination directory (default: /Applications)
    --source APP     Source FCP app (default: /Applications/Final Cut Pro.app)
    --app-name NAME  Name for the patched copy (default: same as the source).
                     e.g. --app-name "Final Cut Pro Modified" also sets the
                     Finder/Dock/menu-bar title. The bundle identifier is never
                     changed, so the App Store licence keeps working.
    --no-copy        Skip copying (use existing modded copy)
    --rebuild        Rebuild dylib only and redeploy
    --uninstall      Remove the modded copy
    --help           Show this help

  What it does:
    1. Copies Final Cut Pro to a writable location
    2. Builds the SpliceKit dylib from source
    3. Injects it into the FCP binary (LC_LOAD_DYLIB)
    4. Re-signs everything with custom entitlements (no sandbox)
    5. Patches CloudContent/ImagePlayground crash points
    6. Sets up the MCP server config

  After patching:
    - Launch: the renamed copy in /Applications
    - Connect: 127.0.0.1:9876 (JSON-RPC)
    - MCP config: .mcp.json is created in the repo root
    - Claude Desktop: run ./Scripts/setup-mcp.sh

  Requirements:
    - macOS 14+
    - Xcode Command Line Tools
    - Final Cut Pro installed
    - ~7 GB free disk space

EOF
    exit 0
}

# ============================================================
# Parse arguments
# ============================================================
NO_COPY=false
REBUILD_ONLY=false
UNINSTALL=false
APP_NAME_OVERRIDE="${APP_NAME_OVERRIDE:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)     DEST_DIR="$2"; shift 2 ;;
        --source)   SOURCE_APP="$2"; shift 2 ;;
        --app-name) APP_NAME_OVERRIDE="$2"; shift 2 ;;
        --no-copy)  NO_COPY=true; shift ;;
        --rebuild)  REBUILD_ONLY=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h)  usage ;;
        *)          err "Unknown option: $1"; usage ;;
    esac
done

# Resolve the bundle name AFTER parsing, so --source is honoured (it used to be
# computed from the default source before the flag was read) and so --app-name
# survives --rebuild / --no-copy, which otherwise looked for the source's name
# in the destination and failed against a renamed bundle.
if [[ -n "$APP_NAME_OVERRIDE" ]]; then
    APP_NAME="${APP_NAME_OVERRIDE%.app}.app"
else
    APP_NAME="$(basename "$SOURCE_APP")"
fi
APP_DISPLAY_NAME="$(basename "$APP_NAME" .app)"

MODDED_APP="$DEST_DIR/$APP_NAME"

# Refuse to write the patched copy over the app being copied. The destination
# defaults to /Applications, which is also where the source lives, so without a
# distinct --app-name the two paths collide and the "copy" would patch the real
# Final Cut Pro in place — destroying the untouched original the whole design
# depends on. Compare resolved paths so ".."  and symlinks cannot slip past.
resolve_path() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"; }
if [[ "$(resolve_path "$MODDED_APP")" == "$(resolve_path "$SOURCE_APP")" ]]; then
    err "The patched copy would overwrite the original Final Cut Pro:"
    err "  source:      $SOURCE_APP"
    err "  destination: $MODDED_APP"
    err ""
    err "Give the copy its own name, for example:"
    err "  --app-name \"Final Cut Pro Modified\""
    err "or send it somewhere else with --dest."
    exit 1
fi

# ============================================================
# Uninstall
# ============================================================
if $UNINSTALL; then
    step "Uninstalling SpliceKit"

    # Remove the app bundle, never the directory holding it. This used to be
    # `rm -rf "$DEST_DIR"`, which is only safe while the copy lives in a
    # subdirectory of its own — point --dest at an Applications folder and
    # uninstalling would take every other app in it with it.
    if [[ -d "$MODDED_APP" ]]; then
        if pgrep -f "$MODDED_APP/Contents/MacOS/Final Cut Pro" >/dev/null 2>&1; then
            err "$APP_DISPLAY_NAME is running. Quit it (Cmd+Q) and re-run."
            exit 1
        fi
        info "Removing $MODDED_APP"
        rm -rf "$MODDED_APP"
        log "Modded FCP removed"
    else
        warn "Nothing to uninstall at $MODDED_APP"
    fi

    # Tidy up an empty container left behind by the old nested layout, but only
    # if it is empty and is not itself an Applications folder.
    case "$DEST_DIR" in
        "$HOME/Applications"|/Applications) ;;
        *)
            if [[ -d "$DEST_DIR" ]] && [[ -z "$(ls -A "$DEST_DIR" 2>/dev/null)" ]]; then
                rmdir "$DEST_DIR" 2>/dev/null && info "Removed empty $DEST_DIR"
            fi
            ;;
    esac

    exit 0
fi

# ============================================================
# Banner
# ============================================================
echo -e "${BOLD}"
cat << 'BANNER'

  ╔═══════════════════════════════════════════════╗
  ║         SpliceKit Patcher v2.0.0              ║
  ║  Direct programmatic control of Final Cut Pro ║
  ╚═══════════════════════════════════════════════╝

BANNER
echo -e "${NC}"

# ============================================================
# Prerequisites
# ============================================================
step "Checking prerequisites"

# Xcode tools
if ! xcode-select -p &>/dev/null; then
    err "Xcode Command Line Tools not installed"
    info "Install with: xcode-select --install"
    exit 1
fi
log "Xcode Command Line Tools: $(xcode-select -p)"

# codesign
if ! command -v codesign &>/dev/null; then
    err "codesign not found"; exit 1
fi
log "codesign: $(which codesign)"

# clang
if ! command -v clang &>/dev/null; then
    err "clang not found"; exit 1
fi
log "clang: $(which clang)"

# Source app
if [[ ! -d "$SOURCE_APP" ]]; then
    err "Final Cut Pro not found at: $SOURCE_APP"
    info "Install from the Mac App Store or specify --source"
    exit 1
fi
FCP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
log "Final Cut Pro: v$FCP_VERSION at $SOURCE_APP"

# Disk space
AVAIL_GB=$(df -g "$HOME" | tail -1 | awk '{print $4}')
if [[ $AVAIL_GB -lt 8 ]]; then
    warn "Low disk space: ${AVAIL_GB}GB available (need ~7GB)"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
log "Disk space: ${AVAIL_GB}GB available"

# ============================================================
# Step 1: Copy FCP
# ============================================================
if ! $NO_COPY && ! $REBUILD_ONLY; then
    step "Step 1: Copying Final Cut Pro"

    if [[ -d "$MODDED_APP" ]]; then
        warn "Modded copy already exists at $MODDED_APP"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$MODDED_APP"
        else
            NO_COPY=true
            log "Using existing copy"
        fi
    fi

    if ! $NO_COPY; then
        mkdir -p "$DEST_DIR"
        info "Copying $(du -sh "$SOURCE_APP" | cut -f1) ... (this takes a minute)"
        cp -R "$SOURCE_APP" "$MODDED_APP"
        log "Copied to $MODDED_APP"

        # Copy MAS receipt
        if [[ -f "$SOURCE_APP/Contents/_MASReceipt/receipt" ]]; then
            mkdir -p "$MODDED_APP/Contents/_MASReceipt"
            cp "$SOURCE_APP/Contents/_MASReceipt/receipt" "$MODDED_APP/Contents/_MASReceipt/"
            log "MAS receipt copied"
        fi

        # Remove quarantine
        xattr -cr "$MODDED_APP" 2>/dev/null || true
        log "Quarantine attributes removed"
    fi
else
    if [[ ! -d "$MODDED_APP" ]]; then
        err "No modded copy found at $MODDED_APP"
        info "Run without --no-copy or --rebuild first"
        exit 1
    fi
    log "Using existing copy at $MODDED_APP"
fi

# ============================================================
# Step 2: Build SpliceKit dylib
# ============================================================
step "Step 2: Building SpliceKit dylib"

BUILD_DIR="$REPO_DIR/build"
mkdir -p "$BUILD_DIR"

# Read canonical source list from Sources/SOURCES.txt
SOURCES=()
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    SOURCES+=("$REPO_DIR/Sources/$line")
done < "$REPO_DIR/Sources/SOURCES.txt"

# Build Lua 5.4.7 static library if vendored sources exist
LUA_DIR="$REPO_DIR/vendor/lua-5.4.7/src"
LUA_LIB="$BUILD_DIR/liblua.a"
LUA_FLAGS=""
if [ -d "$LUA_DIR" ]; then
    info "Building Lua 5.4.7 static library..."
    mkdir -p "$BUILD_DIR/lua_obj"
    for src in "$LUA_DIR"/*.c; do
        base="$(basename "$src" .c)"
        [ "$base" = "lua" ] && continue
        [ "$base" = "luac" ] && continue
        clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
            -DLUA_USE_MACOSX -O2 -Wall -c "$src" -o "$BUILD_DIR/lua_obj/$base.o"
    done
    libtool -static -o "$LUA_LIB" "$BUILD_DIR"/lua_obj/*.o
    LUA_FLAGS="-I $LUA_DIR $LUA_LIB"
    log "Built: $LUA_LIB"
fi

info "Compiling ${#SOURCES[@]} source files..."
clang -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit -framework AVFoundation -framework Speech -framework CoreServices \
    -fobjc-arc -fmodules -Wno-deprecated-declarations \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_DIR/Sources" \
    "${SOURCES[@]}" $LUA_FLAGS \
    -o "$BUILD_DIR/SpliceKit" 2>&1

log "Built: $(file "$BUILD_DIR/SpliceKit" | grep -o 'universal.*')"

# ============================================================
# Step 3: Create framework bundle
# ============================================================
step "Step 3: Installing SpliceKit framework"

FW_DIR="$MODDED_APP/Contents/Frameworks/SpliceKit.framework"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Versions/A/Resources"

# Copy dylib
cp "$BUILD_DIR/SpliceKit" "$FW_DIR/Versions/A/SpliceKit"

# Create symlinks. Use -n so repeated patch runs replace the symlink itself
# instead of following it into Versions/A and creating recursive loops.
cd "$FW_DIR/Versions" && ln -sfn A Current
cd "$FW_DIR" && ln -sfn Versions/Current/SpliceKit SpliceKit
cd "$FW_DIR" && ln -sfn Versions/Current/Resources Resources

# Create Info.plist
cat > "$FW_DIR/Versions/A/Resources/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
    <key>CFBundleName</key><string>SpliceKit</string>
    <key>CFBundleVersion</key><string>2.0.0</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleExecutable</key><string>SpliceKit</string>
</dict>
</plist>
PLIST

log "Framework installed"

# ============================================================
# Step 3b: Transcription helper binaries
#
# The transcript panel's Parakeet engine shells out to a Swift CLI rather than
# linking the ASR stack into the injected dylib. Step 3 wipes and recreates the
# framework, so it has to be re-installed on every run — including --rebuild.
# Without it the panel reports a missing binary and transcribes nothing.
#
# Builds are cached in build/, so this is a no-op once warm. The caption panel's
# Whisper engines are opt-in (--all) and not built here.
#
# Never fatal: a failed ASR build costs one engine, not the whole patch.
# ============================================================
step "Step 3b: Installing transcription helpers"

if ! "$REPO_DIR/Scripts/build-transcribers.sh" --framework "$FW_DIR"; then
    warn "Some transcription helpers are unavailable — see the messages above."
    warn "Everything else in Final Cut Pro still works; re-run 'make install' to retry."
fi

# ============================================================
# Step 4: Inject LC_LOAD_DYLIB
# ============================================================
step "Step 4: Injecting dylib into FCP binary"

BINARY="$MODDED_APP/Contents/MacOS/Final Cut Pro"

# Check if already injected
if otool -L "$BINARY" 2>/dev/null | grep -q SpliceKit; then
    log "Already injected (skipping)"
else
    # Build insert_dylib if needed
    INSERT_DYLIB="/tmp/splicekit_insert_dylib"
    if [[ ! -x "$INSERT_DYLIB" ]]; then
        info "Building insert_dylib tool..."
        TMPDIR_ID=$(mktemp -d)
        if ! git clone --quiet https://github.com/tyilo/insert_dylib.git "$TMPDIR_ID/insert_dylib" 2>&1; then
            rm -rf "$TMPDIR_ID"
            err "Failed to download insert_dylib"
            exit 1
        fi
        if ! clang -o "$INSERT_DYLIB" "$TMPDIR_ID/insert_dylib/insert_dylib/main.c" -framework Foundation 2>&1; then
            rm -rf "$TMPDIR_ID"
            err "Failed to build insert_dylib"
            exit 1
        fi
        rm -rf "$TMPDIR_ID"
        log "insert_dylib built"
    fi

    if ! "$INSERT_DYLIB" --inplace --all-yes \
        "@rpath/SpliceKit.framework/Versions/A/SpliceKit" \
        "$BINARY" 2>&1; then
        err "insert_dylib failed"
        exit 1
    fi

    if ! otool -L "$BINARY" 2>/dev/null | grep -q "@rpath/SpliceKit.framework/Versions/A/SpliceKit"; then
        err "insert_dylib completed but the SpliceKit load command is still missing"
        exit 1
    fi

    log "LC_LOAD_DYLIB injected"
fi

# ============================================================
# Step 4b: Bundle metadata
#
# Every Info.plist write has to happen BEFORE signing. Code signing seals
# Contents/Info.plist, so editing it afterwards leaves the app reporting
# "invalid Info.plist (plist or signature have been modified)" and macOS
# refuses to launch it. These edits used to live in Step 6, after the signing
# step, which meant the patcher always finished with a broken signature.
# ============================================================
step "Step 4b: Configuring bundle metadata"

PLIST="$MODDED_APP/Contents/Info.plist"

plist_set() {
    local key="$1" value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key '$value'" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string '$value'" "$PLIST" 2>/dev/null \
        || true
}

# Speech and microphone usage descriptions for transcript + command palette dictation.
plist_set NSSpeechRecognitionUsageDescription \
    "SpliceKit uses speech recognition for transcript editing and command palette voice dictation inside Final Cut Pro."
plist_set NSMicrophoneUsageDescription \
    "SpliceKit uses the microphone for LiveCam capture and command palette voice dictation inside Final Cut Pro."
log "Speech recognition and microphone permissions configured"

# Retitle the copy when --app-name was given, so it is distinguishable from the
# stock app in Finder, the Dock and the menu bar. CFBundleIdentifier is left
# alone on purpose: it ties to the Mac App Store receipt and the FCP licence,
# and changing it makes the copy read as unlicensed. CFBundleExecutable is left
# alone too — the injected binary is still Contents/MacOS/Final Cut Pro.
if [[ -n "$APP_NAME_OVERRIDE" ]]; then
    plist_set CFBundleDisplayName "$APP_DISPLAY_NAME"
    plist_set CFBundleName "$APP_DISPLAY_NAME"

    # Info.plist alone is not enough. Final Cut Pro ships a localized
    # InfoPlist.strings in each .lproj, and a localized CFBundleDisplayName
    # overrides the one in Info.plist — so Finder, the Dock and Launchpad kept
    # showing "Final Cut Pro" for the copy, indistinguishable from the original
    # sitting next to it. Retitle every locale, not just English, or the name
    # reverts for anyone running the Mac in another language.
    localized=0
    for strings_file in "$MODDED_APP"/Contents/Resources/*.lproj/InfoPlist.strings; do
        [[ -f "$strings_file" ]] || continue
        for key in CFBundleDisplayName CFBundleName; do
            if plutil -extract "$key" raw "$strings_file" >/dev/null 2>&1; then
                plutil -replace "$key" -string "$APP_DISPLAY_NAME" "$strings_file" 2>/dev/null || true
            fi
        done
        localized=$((localized + 1))
    done

    log "Bundle retitled: $APP_DISPLAY_NAME (Info.plist + $localized localizations)"
fi

# ============================================================
# Step 5: Create entitlements and re-sign
# ============================================================
step "Step 5: Re-signing (this takes a moment)"

# Create entitlements
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
</dict>
</plist>
ENT

# Only sign the SpliceKit framework (ours) and the main app bundle.
# Apple's own frameworks must keep their original signatures or internal
# integrity checks (e.g. ProAppSupport +[PCApp isiMovie]) abort on launch.
SIGN_IDENTITY="$(detect_sign_identity || true)"
if [[ -n "$SIGN_IDENTITY" ]]; then
    info "Using signing identity: $SIGN_IDENTITY"
else
    SIGN_IDENTITY="-"
    info "No local codesigning identity found; falling back to ad-hoc signing (higher risk of macOS launch/security blocks)"
fi

info "Signing main application..."
if ! sign_modded_app "$SIGN_IDENTITY"; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        err "Signing failed"
        exit 1
    fi

    warn "Developer signing failed; retrying with ad-hoc signature (higher risk of macOS launch/security blocks)"
    sign_modded_app "-"
    SIGN_IDENTITY="-"
fi

# Verify
VERIFY_OUT=$(codesign --verify --verbose "$MODDED_APP" 2>&1)
if echo "$VERIFY_OUT" | grep -q "valid on disk"; then
    log "Signature valid"
elif echo "$VERIFY_OUT" | grep -q "satisfies"; then
    log "Signature valid"
else
    # Mixed signatures (Apple + ad-hoc) may report issues but the app can
    # still launch with library validation disabled via entitlements.
    log "Signature note: $VERIFY_OUT"
fi

# Verify entitlements applied
if codesign -d --entitlements - "$MODDED_APP" 2>&1 | grep -q "disable-library-validation"; then
    log "Entitlements applied (no sandbox, library validation disabled)"
else
    err "Entitlements not applied correctly"
    exit 1
fi

# ============================================================
# Step 6: Set up NSUserDefaults
# ============================================================
step "Step 6: Configuring defaults"

defaults write com.apple.FinalCut CloudContentFirstLaunchCompleted -bool true 2>/dev/null || true
defaults write com.apple.FinalCut FFCloudContentDisabled -bool true 2>/dev/null || true
log "CloudContent defaults set"

# NOTE: Info.plist edits belong in Step 4b, before signing. Writing to the
# bundle here would invalidate the signature made in Step 5.

# ============================================================
# Step 7: Create MCP config
# ============================================================
step "Step 7: Setting up MCP server"

MCP_SERVER="$REPO_DIR/mcp/server.py"

# What the completion banner will say about MCP. Starts pessimistic and is
# upgraded only where a config is actually written, so the summary can never
# tell the user they are configured when they are not.
MCP_STATUS_LINE="Not configured — run ./Scripts/setup-mcp.sh"

if [[ -f "$MCP_SERVER" ]]; then
    # Prefer the dedicated virtualenv: a bare `python3` usually lacks the `mcp`
    # package, which makes the server fail to start with no obvious cause.
    # Honour the same MCP_VENV override the Makefile accepts, and require the
    # import the server really performs — an interpreter that merely exists, or
    # a half-finished install, would otherwise be written into the config.
    MCP_VENV_DIR="${MCP_VENV:-$HOME/.venvs/splicekit-mcp}"
    # A relative override must be anchored, or the path we write into the config
    # would only resolve from the directory the patcher happened to run in.
    case "$MCP_VENV_DIR" in
        /*) ;;
        *)  MCP_VENV_DIR="$REPO_DIR/$MCP_VENV_DIR" ;;
    esac

    MCP_PYTHON="$MCP_VENV_DIR/bin/python"
    if [[ ! -x "$MCP_PYTHON" ]] || ! "$MCP_PYTHON" -c "import mcp.server.fastmcp" 2>/dev/null; then
        # Fall back to an absolute system python3: MCP clients are launched by
        # the OS and do not necessarily inherit this shell's PATH.
        MCP_FALLBACK="$(command -v python3 || true)"

        # A relative PATH entry (a bare `.`, say) makes `command -v` hand back
        # something like ./python3. The config has to hold a path that resolves
        # from any working directory, so pin it down before using it.
        case "$MCP_FALLBACK" in
            ""|/*) ;;
            *)
                if MCP_FALLBACK_DIR="$(cd "$(dirname "$MCP_FALLBACK")" >/dev/null 2>&1 && pwd)"; then
                    MCP_FALLBACK="$MCP_FALLBACK_DIR/$(basename "$MCP_FALLBACK")"
                else
                    MCP_FALLBACK=""
                fi
                ;;
        esac

        if [[ -z "$MCP_FALLBACK" ]]; then
            MCP_FALLBACK="/usr/bin/python3"
        fi

        if [[ -x "$MCP_FALLBACK" ]] && "$MCP_FALLBACK" -c "import mcp.server.fastmcp" 2>/dev/null; then
            MCP_PYTHON="$MCP_FALLBACK"
            warn "No MCP virtualenv at $MCP_VENV_DIR — using $MCP_PYTHON"
        else
            # Nothing here can run the server. Writing this interpreter anyway
            # would produce a config that fails at launch, which is exactly what
            # the import check exists to prevent — so write nothing.
            MCP_PYTHON=""
            warn "No Python with the mcp package found (checked $MCP_VENV_DIR and $MCP_FALLBACK)"
        fi
    fi

    # Absolute path: this must land next to the repo, not in the caller's cwd.
    MCP_CONFIG="$REPO_DIR/.mcp.json"
    MCP_MERGE_TOOL="$REPO_DIR/Scripts/claude_config.py"

    # Only claim success where something was actually written — a patch run that
    # reports "MCP config written" after deliberately skipping the write sends
    # the user looking in the wrong place when the server doesn't appear.
    if [[ -z "$MCP_PYTHON" ]]; then
        # No interpreter can actually run the server, so there is no honest
        # value to write. Leave any existing config alone and say what to run.
        warn "Not writing $MCP_CONFIG — no usable Python to run the MCP server"
        warn "Run ./Scripts/setup-mcp.sh, which creates the venv and writes the config"
    elif [[ -f "$MCP_MERGE_TOOL" ]]; then
        # Merge rather than overwrite. This file can already hold other MCP
        # servers for the project, and clobbering it would delete them silently.
        if "$MCP_PYTHON" "$MCP_MERGE_TOOL" write "$MCP_CONFIG" "$MCP_PYTHON" "$MCP_SERVER"; then
            log "MCP config written to $MCP_CONFIG"
            MCP_STATUS_LINE="Configured in .mcp.json (restart Claude Code to load)"
        else
            warn "Could not update $MCP_CONFIG — see the error above"
        fi
    elif [[ -f "$MCP_CONFIG" ]]; then
        # Nothing to merge with safely — leave the existing file alone rather
        # than destroying entries we cannot read.
        warn "Cannot find $MCP_MERGE_TOOL; leaving existing $MCP_CONFIG untouched"
        warn "Add the splicekit entry by hand, or run ./Scripts/setup-mcp.sh"
    else
        cat > "$MCP_CONFIG" << MCPJSON
{
  "mcpServers": {
    "splicekit": {
      "command": "$MCP_PYTHON",
      "args": ["$MCP_SERVER"]
    }
  }
}
MCPJSON
        log "MCP config written to $MCP_CONFIG"
        MCP_STATUS_LINE="Configured in .mcp.json (restart Claude Code to load)"
    fi
    info "For Claude Desktop, run: ./Scripts/setup-mcp.sh"
else
    warn "MCP server not found at $MCP_SERVER"
fi

# ============================================================
# Done!
# ============================================================
step "Patching complete!"

echo -e "
${GREEN}${BOLD}SpliceKit has been installed successfully!${NC}

${BOLD}Launch:${NC}
  $MODDED_APP/Contents/MacOS/Final\\ Cut\\ Pro

${BOLD}Or double-click:${NC}
  $MODDED_APP

${BOLD}JSON-RPC server:${NC}
  127.0.0.1:$BRIDGE_PORT (starts automatically)

${BOLD}Check logs:${NC}
  ~/Library/Logs/SpliceKit/splicekit.log

${BOLD}Python client:${NC}
  python3 $REPO_DIR/Scripts/splicekit_client.py

${BOLD}MCP server:${NC}
  $MCP_STATUS_LINE

${BOLD}Quick test:${NC}
  echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc 127.0.0.1 $BRIDGE_PORT

${BOLD}Uninstall:${NC}
  $0 --uninstall
"
