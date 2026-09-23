#!/bin/bash
#
# Build and install the on-device transcription helper binaries.
#
# The transcript panel (Parakeet engine) and the caption panel (Whisper engines)
# both shell out to a small Swift CLI rather than linking the ASR stack into the
# injected dylib. Those CLIs live in helpers/<name>/ as SwiftPM packages and have
# to be compiled and placed somewhere the injected code looks for them.
#
# Install locations, matching the runtime search order in
# SpliceKitTranscriptPanel+Parakeet.m (parakeetTranscriberPath) and
# SpliceKitCaptionPanel+Transcription.m (transcriberBinaryPathForName:):
#
#   1. <patched FCP>.app/Contents/Frameworks/SpliceKit.framework/.../Resources/
#      Preferred: travels with the app, survives a home directory rename, and
#      needs no per-user state. Wiped and rewritten on every patch run.
#   2. ~/Library/Application Support/SpliceKit/tools/
#      Fallback for a framework that has not been redeployed yet. Resolved from
#      NSHomeDirectory() at runtime, so it is never pinned to one user's home.
#
# Builds are cached in build/<name>. A rebuild only happens when a source file
# or Package.swift is newer than the cached binary, so re-running `make install`
# does not re-download the ASR dependencies.
#
# Usage:
#   ./scripts/build-transcribers.sh [--framework <SpliceKit.framework path>]
#                                   [--only <name>] [--all] [--force]
#
# By default only parakeet-transcriber is built — it is what the transcript
# panel needs, and it has a single dependency with no transitive packages.
# whisper-transcriber (the caption panel's Whisper engines) is opt-in via
# --all, because WhisperKit pulls a much larger dependency tree and its models
# are 800 MB-1.5 GB. Nothing downloads either of those unless you ask.
#
# A build failure is reported but never fatal: transcription is one feature of
# many, and a network outage should not block patching Final Cut Pro.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
SUPPORT_TOOLS_DIR="$HOME/Library/Application Support/SpliceKit/tools"

FRAMEWORK_DIR=""
ONLY=""
FORCE=false
BUILD_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework) FRAMEWORK_DIR="${2:-}"; shift 2 ;;
        --only)      ONLY="${2:-}"; shift 2 ;;
        --all)       BUILD_ALL=true; shift ;;
        --force)     FORCE=true; shift ;;
        -h|--help)
            printf 'Usage: %s [--framework <path>] [--only <name>] [--all] [--force]\n' "$0"
            printf '  default: parakeet-transcriber only (transcript panel)\n'
            printf '  --all:   also whisper-transcriber (caption panel, much larger)\n'
            exit 0 ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*"; }

DEFAULT_TRANSCRIBERS=(parakeet-transcriber)
OPTIONAL_TRANSCRIBERS=(whisper-transcriber)

# A cached binary is stale when any input file is newer than it. Package.resolved
# is deliberately included: a dependency bump has to produce a fresh build.
needs_rebuild() {
    local pkg_dir="$1" cached="$2"
    [[ -f "$cached" ]] || return 0
    $FORCE && return 0
    local newer
    newer="$(find "$pkg_dir/Sources" "$pkg_dir/Package.swift" "$pkg_dir/Package.resolved" \
                 -newer "$cached" -print -quit 2>/dev/null)"
    [[ -n "$newer" ]]
}

build_one() {
    local name="$1"
    local pkg_dir="$REPO_DIR/helpers/$name"
    local cached="$BUILD_DIR/$name"

    if [[ ! -f "$pkg_dir/Package.swift" ]]; then
        warn "$name: no package at helpers/$name — skipping"
        return 1
    fi

    if ! needs_rebuild "$pkg_dir" "$cached"; then
        log "$name: up to date (build/$name)"
        return 0
    fi

    # The ASR backends are Apple-silicon-first (Core ML / Neural Engine), so
    # build for the host architecture rather than forcing a universal binary the
    # dependencies may not support. FCP itself stays universal; only this helper
    # is native-only, and it runs as a separate process.
    warn "$name: building (first run downloads dependencies — this takes a few minutes)"
    mkdir -p "$BUILD_DIR"
    local logfile="$BUILD_DIR/$name-build.log"
    if ! ( cd "$pkg_dir" && swift build -c release --arch "$(uname -m)" ) >"$logfile" 2>&1; then
        err "$name: build failed — see $logfile"
        tail -15 "$logfile" | sed 's/^/    /'
        if grep -q "xcrun: error\|xcode-select" "$logfile"; then
            err "$name: Xcode Command Line Tools look missing. Run: xcode-select --install"
        elif grep -qi "could not resolve\|failed to resolve\|network\|timed out" "$logfile"; then
            err "$name: dependency download failed — check the network and re-run: make install"
        fi
        return 1
    fi

    # Ask SwiftPM where it put the product rather than assuming .build/release.
    # The layout differs between the legacy and Swift-Build back ends, and the
    # `release` symlink is not always the directory holding the executable.
    local bin_dir built
    bin_dir="$( cd "$pkg_dir" && swift build -c release --arch "$(uname -m)" --show-bin-path 2>/dev/null )"
    built="$bin_dir/$name"
    if [[ ! -f "$built" ]]; then
        built="$(find "$pkg_dir/.build" -name "$name" -type f -perm -u+x -maxdepth 6 2>/dev/null | head -1)"
    fi
    if [[ -z "$built" || ! -f "$built" ]]; then
        err "$name: build reported success but produced no executable"
        err "$name: searched $bin_dir and $pkg_dir/.build"
        return 1
    fi

    cp "$built" "$cached"
    chmod +x "$cached"
    # Ad-hoc sign so the binary has a valid signature of its own. Without it,
    # a Mach-O dropped into the framework's Resources is unsigned nested code
    # and the framework's own signature fails to verify.
    codesign --force --sign - "$cached" >/dev/null 2>&1 || true
    log "$name: built ($(du -h "$cached" | cut -f1))"
    return 0
}

install_one() {
    local name="$1"
    local cached="$BUILD_DIR/$name"
    [[ -f "$cached" ]] || return 1

    mkdir -p "$SUPPORT_TOOLS_DIR"
    cp "$cached" "$SUPPORT_TOOLS_DIR/$name"
    chmod +x "$SUPPORT_TOOLS_DIR/$name"

    if [[ -n "$FRAMEWORK_DIR" && -d "$FRAMEWORK_DIR/Versions/A/Resources" ]]; then
        cp "$cached" "$FRAMEWORK_DIR/Versions/A/Resources/$name"
        chmod +x "$FRAMEWORK_DIR/Versions/A/Resources/$name"
        log "$name: installed into the app bundle and Application Support"
    else
        log "$name: installed into $SUPPORT_TOOLS_DIR"
    fi
    return 0
}

TRANSCRIBERS=("${DEFAULT_TRANSCRIBERS[@]}")
if $BUILD_ALL; then
    TRANSCRIBERS+=("${OPTIONAL_TRANSCRIBERS[@]}")
elif [[ -n "$ONLY" ]]; then
    # --only names one explicitly, including an optional one.
    TRANSCRIBERS=("${DEFAULT_TRANSCRIBERS[@]}" "${OPTIONAL_TRANSCRIBERS[@]}")
fi

status=0
for name in "${TRANSCRIBERS[@]}"; do
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
    if build_one "$name"; then
        install_one "$name" || { err "$name: install failed"; status=1; }
    else
        # Keep whatever was installed before rather than leaving a half state.
        if [[ -f "$SUPPORT_TOOLS_DIR/$name" ]]; then
            warn "$name: keeping the previously installed copy"
            install_one "$name" || true
        else
            warn "$name: not installed — that engine will be unavailable"
            status=1
        fi
    fi
done

exit $status
