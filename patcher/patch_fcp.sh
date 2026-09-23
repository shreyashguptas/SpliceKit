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
    --yes            Answer yes to the confirmation prompts (low disk space,
                     overwrite an existing unpatched copy)
    --help           Show this help

  Environment:
    SPLICEKIT_SKIP_MCP_CONFIG=1  Skip step 7 (writing .mcp.json). `make install`
                                 sets this: it verifies the MCP server first and
                                 writes the configs itself afterwards.

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
    - Claude Desktop: run ./scripts/setup-mcp.sh

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
ASSUME_YES=false
APP_NAME_OVERRIDE="${APP_NAME_OVERRIDE:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)     DEST_DIR="$2"; shift 2 ;;
        --source)   SOURCE_APP="$2"; shift 2 ;;
        --app-name) APP_NAME_OVERRIDE="$2"; shift 2 ;;
        --no-copy)  NO_COPY=true; shift ;;
        --rebuild)  REBUILD_ONLY=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --yes|-y)   ASSUME_YES=true; shift ;;
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
    if $ASSUME_YES; then
        warn "--yes: continuing anyway"
    else
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
fi
log "Disk space: ${AVAIL_GB}GB available"

# ============================================================
# Step 1: Copy FCP
# ============================================================
if ! $NO_COPY && ! $REBUILD_ONLY; then
    step "Step 1: Copying Final Cut Pro"

    if [[ -d "$MODDED_APP" ]]; then
        warn "Modded copy already exists at $MODDED_APP"
        if $ASSUME_YES; then
            # An unpatched copy at the destination is what a failed earlier
            # attempt leaves behind; a fresh copy is the reliable way forward.
            REPLY=y
            warn "--yes: replacing it with a fresh copy"
        else
            read -p "Overwrite? [y/N] " -n 1 -r
            echo
        fi
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
# Step 2: Inject LC_LOAD_DYLIB
# ============================================================
step "Step 2: Injecting dylib into FCP binary"

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
# Step 3: Bundle metadata
#
# Every Info.plist write has to happen BEFORE signing (Step 4). Code signing
# seals Contents/Info.plist, so editing it afterwards leaves the app reporting
# "invalid Info.plist (plist or signature have been modified)" and macOS
# refuses to launch it. The privacy usage descriptions are set by make deploy.
# ============================================================
step "Step 3: Configuring bundle metadata"

PLIST="$MODDED_APP/Contents/Info.plist"

plist_set() {
    local key="$1" value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key '$value'" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string '$value'" "$PLIST" 2>/dev/null \
        || true
}

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
# Step 4: Build, install and sign SpliceKit
#
# `make deploy` is the one build: the dylib, the helper CLIs, the plugin
# bundles, the Lua scripts, then re-signing with entitlements.plist. The
# Info.plist edits above have to happen first, because the signature seals
# Info.plist. Deploy wipes and recreates the framework, so it runs on every
# patch, including --rebuild.
# ============================================================
step "Step 4: Building, installing and signing SpliceKit"

if ! make -C "$REPO_DIR" deploy MODDED_APP="$MODDED_APP"; then
    err "make deploy failed — see the output above"
    exit 1
fi

# ============================================================
# Step 5: Set up NSUserDefaults
# ============================================================
step "Step 5: Configuring defaults"

defaults write com.apple.FinalCut CloudContentFirstLaunchCompleted -bool true 2>/dev/null || true
defaults write com.apple.FinalCut FFCloudContentDisabled -bool true 2>/dev/null || true
log "CloudContent defaults set"

# NOTE: Info.plist edits belong in Step 3, before signing. Writing to the
# bundle here would invalidate the signature made in Step 4.

# ============================================================
# Step 6: Create MCP config
# ============================================================
step "Step 6: Setting up MCP server"

MCP_SERVER="$REPO_DIR/mcp/server.py"

# What the completion banner will say about MCP. Starts pessimistic and is
# upgraded only where a config is actually written, so the summary can never
# tell the user they are configured when they are not.
MCP_STATUS_LINE="Not configured — run ./scripts/setup-mcp.sh"

if [[ "${SPLICEKIT_SKIP_MCP_CONFIG:-}" == "1" ]]; then
    # `make install` runs the MCP server's full self-check and writes the configs
    # itself after this script returns. Writing .mcp.json here would point a
    # client at a server nothing has verified yet.
    info "Left to make install (scripts/setup-mcp.sh runs next)"
    MCP_STATUS_LINE="Set up by the next step of make install"
elif [[ -f "$MCP_SERVER" ]]; then
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
    if [[ ! -x "$MCP_PYTHON" ]] || ! "$MCP_PYTHON" -c "import mcp.server.mcpserver" 2>/dev/null; then
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

        if [[ -x "$MCP_FALLBACK" ]] && "$MCP_FALLBACK" -c "import mcp.server.mcpserver" 2>/dev/null; then
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
    MCP_MERGE_TOOL="$REPO_DIR/scripts/claude_config.py"

    # Only claim success where something was actually written — a patch run that
    # reports "MCP config written" after deliberately skipping the write sends
    # the user looking in the wrong place when the server doesn't appear.
    if [[ -z "$MCP_PYTHON" ]]; then
        # No interpreter can actually run the server, so there is no honest
        # value to write. Leave any existing config alone and say what to run.
        warn "Not writing $MCP_CONFIG — no usable Python to run the MCP server"
        warn "Run ./scripts/setup-mcp.sh, which creates the venv and writes the config"
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
        warn "Add the splicekit entry by hand, or run ./scripts/setup-mcp.sh"
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
    info "For Claude Desktop, run: ./scripts/setup-mcp.sh"
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
  python3 $REPO_DIR/scripts/splicekit_client.py

${BOLD}MCP server:${NC}
  $MCP_STATUS_LINE

${BOLD}Quick test:${NC}
  echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc 127.0.0.1 $BRIDGE_PORT

${BOLD}Uninstall:${NC}
  $0 --uninstall
"
