#!/bin/bash
#
# Guided setup for this SpliceKit checkout.  Run it with: make install
#
# Checks everything this Mac needs, and for anything missing offers to install
# it — arrow keys to choose, Return to confirm. Takes a clean clone and leaves
# you with:
#
#   1. Homebrew, if it is needed to install anything else
#   2. Xcode Command Line Tools (clang, codesign, otool)
#   3. a Python 3.10+ interpreter (the mcp package needs it; macOS ships 3.9)
#   4. a patched, renamed copy of Final Cut Pro with the SpliceKit dylib injected
#   5. the MCP server wired into Claude Desktop and Claude Code
#
# Safe to re-run: every step checks whether it already did its work.
#
# Usage:
#   make install                    # guided, asks before installing anything
#   ./Scripts/install.sh --check    # report status, change nothing
#   ./Scripts/install.sh --yes      # assume yes, never prompt (CI / scripting)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults. Override with the flags below or by exporting these before running.
APP_NAME="${SPLICEKIT_APP_NAME:-Final Cut Pro Modified}"
DEST_DIR="${SPLICEKIT_DEST_DIR:-/Applications}"
SOURCE_APP="${SPLICEKIT_SOURCE_APP:-}"
PYTHON_FORMULA="python@3.12"
DISK_NEEDED_GB=10

CHECK_ONLY=false
ASSUME_YES=false

RED=$'\033[0;31m';   GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m';  CYAN=$'\033[0;36m';  DIM=$'\033[2m'
BOLD=$'\033[1m';     NC=$'\033[0m'

log()  { printf '%s[+]%s %s\n' "$GREEN"  "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[X]%s %s\n' "$RED"    "$NC" "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$BLUE"   "$NC" "$*"; }
step() { printf '\n%s%s=== %s ===%s\n' "$CYAN" "$BOLD" "$*" "$NC"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --app-name) APP_NAME="$2"; shift 2 ;;
        --dest)     DEST_DIR="$2"; shift 2 ;;
        --source)   SOURCE_APP="$2"; shift 2 ;;
        --check)    CHECK_ONLY=true; shift ;;
        --yes|-y)   ASSUME_YES=true; shift ;;
        -h|--help)  sed -n '2,22p' "$0" | sed 's/^#//;s/^ //'; exit 0 ;;
        *) err "Unknown option: $1"; exit 2 ;;
    esac
done

MODDED_APP="$DEST_DIR/${APP_NAME%.app}.app"

# A TTY on both stdin and stdout is required to draw a menu and read arrow keys.
# Without one (CI, a pipe, make with output captured) fall back to --yes so the
# run still completes instead of blocking forever on a prompt nobody can see.
INTERACTIVE=true
if [[ ! -t 0 || ! -t 1 ]]; then
    INTERACTIVE=false
fi

# ============================================================
# choose "Question" "Option A" "Option B" ...
#
# Arrow keys (or j/k) to move, Return to pick, Esc/q to cancel. Echoes the
# 1-based index of the chosen option on stdout; returns 1 if cancelled.
# ============================================================
choose() {
    local prompt="$1"; shift
    local options=("$@")
    local count=${#options[@]}
    local selected=0 key rest

    if ! $INTERACTIVE; then
        printf '%s\n' "$prompt" >&2
        printf '  %s(non-interactive: choosing "%s")%s\n' "$DIM" "${options[0]}" "$NC" >&2
        echo 1
        return 0
    fi

    printf '\n%s%s%s\n' "$BOLD" "$prompt" "$NC" >&2

    _render() {
        local i
        for ((i = 0; i < count; i++)); do
            if ((i == selected)); then
                printf '  %s❯ %s%s\n' "$CYAN" "${options[i]}" "$NC" >&2
            else
                printf '    %s%s%s\n' "$DIM" "${options[i]}" "$NC" >&2
            fi
        done
        printf '%s  ↑/↓ move · return select · esc cancel%s\n' "$DIM" "$NC" >&2
    }

    # Hide the cursor while the menu is live, and always put it back — including
    # on Ctrl-C, or the user is left with an invisible cursor in their shell.
    printf '\033[?25l' >&2
    trap 'printf "\033[?25h" >&2' RETURN INT TERM

    _render
    while true; do
        IFS= read -rsn1 key </dev/tty || { printf '\033[?25h' >&2; return 1; }
        case "$key" in
            $'\x1b')
                # An arrow key arrives as ESC [ A/B. A lone ESC is the user
                # cancelling. Read the bracket and the letter separately: a
                # single 2-byte read can come up short when the sequence is
                # delivered in more than one chunk, which made every arrow key
                # read as a cancel.
                #
                # The timeout must be a whole number of seconds. macOS still
                # ships bash 3.2, where `read -t 0.3` is not a slightly slower
                # timeout but a hard error ("invalid timeout specification"),
                # which failed the read and turned every arrow key into a
                # cancel. Fractional timeouts need bash 4+.
                if ! IFS= read -rsn1 -t 1 rest </dev/tty; then
                    printf '\033[?25h' >&2
                    return 1
                fi
                [[ "$rest" == '[' || "$rest" == 'O' ]] || continue
                IFS= read -rsn1 -t 1 rest </dev/tty || continue
                case "$rest" in
                    'A') ((selected = (selected - 1 + count) % count)) ;;
                    'B') ((selected = (selected + 1) % count)) ;;
                    *) continue ;;
                esac
                ;;
            k) ((selected = (selected - 1 + count) % count)) ;;
            j) ((selected = (selected + 1) % count)) ;;
            q) printf '\033[?25h' >&2; return 1 ;;
            '') printf '\033[?25h' >&2; printf '\n' >&2; echo $((selected + 1)); return 0 ;;
        esac
        # Redraw in place: one line per option plus the hint line.
        printf '\033[%dA' $((count + 1)) >&2
        _render
    done
}

# Ask to install something. Returns 0 for yes, 1 for no.
confirm_install() {
    local what="$1" how="$2"
    if $ASSUME_YES || ! $INTERACTIVE; then
        info "Installing $what ($how)"
        return 0
    fi
    local pick
    pick="$(choose "$what is not installed. Install it?" \
        "Yes — run: $how" \
        "No — I'll install it myself, stop here")" || return 1
    [[ "$pick" == "1" ]]
}

# ============================================================
# Checks
# ============================================================
have_brew()  { command -v brew >/dev/null 2>&1; }

find_python310() {
    local c p
    for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        p="$(command -v "$c" 2>/dev/null)" || continue
        [[ -n "$p" ]] || continue
        "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null || continue
        printf '%s\n' "$p"; return 0
    done
    return 1
}

find_source_fcp() {
    local c
    [[ -n "$SOURCE_APP" ]] && { printf '%s\n' "$SOURCE_APP"; return 0; }
    for c in "/Applications/Final Cut Pro.app" "/Applications/Final Cut Pro Creator Studio.app"; do
        [[ -d "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

is_patched() {
    [[ -d "$MODDED_APP" ]] && \
        otool -L "$MODDED_APP/Contents/MacOS/Final Cut Pro" 2>/dev/null | grep -q SpliceKit
}

# ============================================================
# Step 0: macOS + Xcode Command Line Tools
# ============================================================
ensure_toolchain() {
    step "Xcode Command Line Tools"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        err "SpliceKit patches Final Cut Pro, which is macOS only."
        exit 1
    fi

    local missing=()
    for t in clang codesign otool; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "Present: $(xcode-select -p 2>/dev/null || echo 'command line tools')"
        return 0
    fi

    warn "Missing build tools: ${missing[*]}"
    $CHECK_ONLY && { info "Would install with: xcode-select --install"; return 1; }

    if confirm_install "Xcode Command Line Tools" "xcode-select --install"; then
        xcode-select --install 2>/dev/null || true
        err "A macOS installer window should have opened."
        err "Finish it, then re-run: make install"
        exit 1
    fi
    err "Cannot build the dylib without clang. Stopping."
    exit 1
}

# ============================================================
# Step 1: Homebrew (only needed if something else is missing)
# ============================================================
ensure_brew() {
    have_brew && return 0

    warn "Homebrew is not installed, and it is the simplest way to get Python 3.10+."
    $CHECK_ONLY && { info "Would install from https://brew.sh"; return 1; }

    if confirm_install "Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # A fresh install is not on PATH in this shell yet.
        for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [[ -x "$p" ]] && eval "$("$p" shellenv)" && break
        done
        have_brew || { err "Homebrew installed but not on PATH. Open a new terminal and re-run: make install"; exit 1; }
        log "Homebrew ready: $(brew --version | head -1)"
        return 0
    fi
    return 1
}

# ============================================================
# Step 2: Python 3.10+
# ============================================================
ensure_python() {
    step "Python 3.10+"

    local py
    if py="$(find_python310)"; then
        log "Found: $py ($("$py" --version 2>&1))"
        return 0
    fi

    local sysver
    sysver="$(/usr/bin/python3 --version 2>&1 | awk '{print $2}')"
    warn "No Python 3.10+ found (macOS ships ${sysver:-3.9}; the mcp package needs 3.10+)"

    $CHECK_ONLY && { info "Would install with: brew install $PYTHON_FORMULA"; return 1; }

    if ! have_brew; then
        ensure_brew || {
            err "Python 3.10+ is required for the MCP server."
            err "Install it any way you like, then re-run: make install"
            exit 1
        }
    fi

    if confirm_install "Python 3.12" "brew install $PYTHON_FORMULA"; then
        brew install "$PYTHON_FORMULA"
        if py="$(find_python310)"; then
            log "Installed: $py ($("$py" --version 2>&1))"
            return 0
        fi
        err "Installed $PYTHON_FORMULA but no Python 3.10+ is on PATH."
        err "Check 'brew doctor' and that $(brew --prefix 2>/dev/null)/bin is on your PATH."
        exit 1
    fi

    err "Python 3.10+ is required for the MCP server. Stopping."
    exit 1
}

# ============================================================
# Step 3: Patch Final Cut Pro
# ============================================================
ensure_patched_app() {
    step "Patched Final Cut Pro"

    if is_patched; then
        log "Already patched: $MODDED_APP"
        info "Rebuild the dylib into it with:"
        info "  ./patcher/patch_fcp.sh --dest '$DEST_DIR' --app-name '$APP_NAME' --rebuild"
        return 0
    fi

    local src
    if ! src="$(find_source_fcp)"; then
        err "Final Cut Pro not found in /Applications."
        err "Install it from the App Store, or point at it with --source."
        $CHECK_ONLY && return 1
        exit 1
    fi
    log "Source: $src ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$src/Contents/Info.plist" 2>/dev/null || echo 'unknown'))"

    local avail
    avail="$(df -g "$HOME" | tail -1 | awk '{print $4}')"
    if [[ -n "$avail" ]] && (( avail < DISK_NEEDED_GB )); then
        warn "Only ${avail}GB free; the copy needs about ${DISK_NEEDED_GB}GB."
    fi

    if $CHECK_ONLY; then
        warn "Not patched yet — would create $MODDED_APP"
        return 1
    fi

    if pgrep -f "$MODDED_APP/Contents/MacOS/Final Cut Pro" >/dev/null 2>&1; then
        err "The patched Final Cut Pro is running. Quit it (Cmd+Q) and re-run."
        exit 1
    fi

    if ! $ASSUME_YES && $INTERACTIVE; then
        local pick
        pick="$(choose "Create the patched copy? It copies ~7GB and leaves your Final Cut Pro untouched." \
            "Yes — patch it as \"${APP_NAME}\"" \
            "No — skip this step")" || { err "Cancelled."; exit 1; }
        [[ "$pick" == "1" ]] || { warn "Skipped patching."; return 0; }
    fi

    local args=(--dest "$DEST_DIR" --app-name "$APP_NAME" --source "$src")
    "$REPO_DIR/patcher/patch_fcp.sh" "${args[@]}"
}

# ============================================================
# Step 4: MCP server
# ============================================================
ensure_mcp() {
    step "MCP server"
    if $CHECK_ONLY; then
        "$REPO_DIR/Scripts/setup-mcp.sh" --check
    else
        "$REPO_DIR/Scripts/setup-mcp.sh"
    fi
}

# ============================================================
# Run
# ============================================================
printf '%sSpliceKit install%s  %s(%s)%s\n' "$BOLD" "$NC" "$DIM" "$REPO_DIR" "$NC"
printf '  target: %s\n' "$MODDED_APP"
$INTERACTIVE || printf '  %snon-interactive: assuming yes to prompts%s\n' "$DIM" "$NC"

if $CHECK_ONLY; then
    ensure_toolchain   || true
    ensure_python      || true
    ensure_patched_app || true
    ensure_mcp         || true
    printf '\n'; info "Check complete — nothing was changed."
    exit 0
fi

ensure_toolchain
ensure_python
ensure_patched_app
ensure_mcp

step "Done"
cat <<EOF

Open the patched app:
  open "$MODDED_APP"

Inside it, press Cmd+Shift+P for the Command Palette.

For Claude to drive Final Cut Pro:
  1. Leave the patched Final Cut Pro running — the MCP server talks to the
     bridge inside it on 127.0.0.1:9876.
  2. Fully quit Claude Desktop (Cmd+Q) and reopen it so it reloads the config.
  3. Ask Claude to do something in Final Cut Pro.

Check the wiring any time:
  make install-check

EOF
