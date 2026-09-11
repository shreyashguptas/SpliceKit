#!/bin/bash
#
# Wire this SpliceKit checkout into your MCP clients.
#
# Creates the MCP virtualenv if it is missing, then writes a "splicekit" entry
# into both Claude Desktop's config and this checkout's .mcp.json (Claude Code),
# using absolute paths discovered at runtime — so this works on any Mac, for any
# user, from any checkout location.
#
# .mcp.json is deliberately git-ignored: it holds absolute paths that are only
# valid on the machine that generated it.
#
# Usage:
#   ./Scripts/setup-mcp.sh
#   ./Scripts/setup-mcp.sh --check    # report status, change nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Honour the same override the Makefile accepts (MCP_VENV ?= ...), so that
# `make mcp-setup` and this script never disagree about where the venv lives.
VENV_DIR="${MCP_VENV:-$HOME/.venvs/splicekit-mcp}"
VENV_PYTHON="$VENV_DIR/bin/python"
MCP_SERVER="$REPO_DIR/mcp/server.py"
CLAUDE_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG="$CLAUDE_DIR/claude_desktop_config.json"
PROJECT_CONFIG="$REPO_DIR/.mcp.json"
BRIDGE_PORT=9876

# Reject anything we don't recognise. A typo like --chek must not silently fall
# through to the mutating path and rewrite the user's configs.
CHECK_ONLY=false
case "$#" in
    0) ;;
    1)
        case "$1" in
            --check) CHECK_ONLY=true ;;
            -h|--help) printf 'Usage: %s [--check]\n' "$0"; exit 0 ;;
            *) printf 'Unknown option: %s\nUsage: %s [--check]\n' "$1" "$0" >&2; exit 2 ;;
        esac
        ;;
    *)
        printf 'Too many arguments.\nUsage: %s [--check]\n' "$0" >&2
        exit 2
        ;;
esac

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# Any python3 will do for the JSON edit; prefer the venv once it exists.
host_python() {
    if [[ -x "$VENV_PYTHON" ]]; then echo "$VENV_PYTHON"; else echo "/usr/bin/python3"; fi
}

# ------------------------------------------------------------------
step "Checking this checkout"
# ------------------------------------------------------------------
if [[ ! -f "$MCP_SERVER" ]]; then
    err "MCP server not found at: $MCP_SERVER"
    err "Run this script from inside a SpliceKit checkout."
    exit 1
fi
log "Repo:       $REPO_DIR"
log "MCP server: $MCP_SERVER"

# ------------------------------------------------------------------
step "Python environment"
# ------------------------------------------------------------------
# Probe the import the server actually performs (mcp/server.py imports
# mcp.server.fastmcp). A bare `import mcp` can succeed against a partial install
# and leave us writing a config that fails at launch. Matches `make mcp-doctor`.
if [[ -x "$VENV_PYTHON" ]] && "$VENV_PYTHON" -c "import mcp.server.fastmcp" 2>/dev/null; then
    log "Ready: $VENV_PYTHON ($("$VENV_PYTHON" --version 2>&1))"
elif $CHECK_ONLY; then
    warn "Missing or incomplete — run without --check to create it"
else
    warn "Creating virtualenv (this takes a few seconds)…"
    make -C "$REPO_DIR" mcp-setup
    if ! "$VENV_PYTHON" -c "import mcp.server.fastmcp" 2>/dev/null; then
        err "Virtualenv created but the mcp package failed to import."
        exit 1
    fi
    log "Ready: $VENV_PYTHON"
fi

# ------------------------------------------------------------------
step "Claude Desktop config"
# ------------------------------------------------------------------
CONFIG_TOOL="$SCRIPT_DIR/claude_config.py"

if $CHECK_ONLY; then
    if [[ -f "$CLAUDE_CONFIG" ]]; then
        "$(host_python)" "$CONFIG_TOOL" show "$CLAUDE_CONFIG" || true
    else
        warn "No config file yet at: $CLAUDE_CONFIG"
    fi
else
    mkdir -p "$CLAUDE_DIR"
    if [[ -f "$CLAUDE_CONFIG" ]]; then
        # Write the backup once only. Re-running would otherwise overwrite it
        # with a config we already edited, losing the untouched original.
        if [[ -e "$CLAUDE_CONFIG.bak" ]]; then
            log "Keeping existing backup: $(basename "$CLAUDE_CONFIG").bak"
        else
            cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.bak"
            log "Backed up original config to: $(basename "$CLAUDE_CONFIG").bak"
        fi
    else
        echo '{}' > "$CLAUDE_CONFIG"
        log "Created a new config file"
    fi

    # Merge, never overwrite: every other server and preference is preserved.
    "$(host_python)" "$CONFIG_TOOL" write "$CLAUDE_CONFIG" "$VENV_PYTHON" "$MCP_SERVER"
    log "Config updated: $CLAUDE_CONFIG"
fi

# ------------------------------------------------------------------
step "Project config for Claude Code (.mcp.json)"
# ------------------------------------------------------------------
if $CHECK_ONLY; then
    if [[ -f "$PROJECT_CONFIG" ]]; then
        "$(host_python)" "$CONFIG_TOOL" show "$PROJECT_CONFIG" || true
    else
        warn "Not generated yet: $PROJECT_CONFIG"
    fi
else
    "$(host_python)" "$CONFIG_TOOL" write "$PROJECT_CONFIG" "$VENV_PYTHON" "$MCP_SERVER"
    log "Generated: $PROJECT_CONFIG (git-ignored — paths are machine-specific)"
fi

# ------------------------------------------------------------------
step "Patched Final Cut Pro"
# ------------------------------------------------------------------
PATCHED_APP=""
for candidate in "$HOME/Applications/SpliceKit/Final Cut Pro.app" \
                 "$HOME/Applications/SpliceKit/Final Cut Pro Creator Studio.app"; do
    [[ -d "$candidate" ]] && PATCHED_APP="$candidate" && break
done

if [[ -n "$PATCHED_APP" ]]; then
    log "Found: $PATCHED_APP"
else
    warn "No patched Final Cut Pro found in ~/Applications/SpliceKit/"
    warn "Create one first:  ./patcher/patch_fcp.sh"
fi

if nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null; then
    log "Bridge is live on 127.0.0.1:$BRIDGE_PORT — the patched FCP is running"
else
    warn "Nothing listening on 127.0.0.1:$BRIDGE_PORT — the patched FCP isn't running yet"
fi

# ------------------------------------------------------------------
step "Next steps"
# ------------------------------------------------------------------
cat <<EOF
1. Quit Final Cut Pro if it's open. The patched copy and the App Store copy
   share one app identity, so opening one while the other runs just switches
   to the copy already running.
2. Open the patched Final Cut Pro from ~/Applications/SpliceKit/ and leave it
   open — the MCP server talks to the bridge inside the running app.
3. Fully quit Claude Desktop (Cmd+Q) and reopen it, so it reloads the config.
4. Ask Claude to do something in Final Cut Pro. Re-run this script with
   --check at any time to confirm the wiring.
EOF
