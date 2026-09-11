#!/bin/bash
#
# Wire this SpliceKit checkout into the Claude Desktop app.
#
# Creates the MCP virtualenv if it is missing, then adds a "splicekit" entry to
# Claude Desktop's config file using absolute paths discovered at runtime — so
# this works on any Mac, for any user, from any checkout location.
#
# Usage:
#   ./scripts/setup-claude-desktop.sh
#   ./scripts/setup-claude-desktop.sh --check    # report status, change nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$HOME/.venvs/splicekit-mcp"
VENV_PYTHON="$VENV_DIR/bin/python"
MCP_SERVER="$REPO_DIR/mcp/server.py"
CLAUDE_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG="$CLAUDE_DIR/claude_desktop_config.json"
BRIDGE_PORT=9876

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

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
if [[ -x "$VENV_PYTHON" ]] && "$VENV_PYTHON" -c "import mcp" 2>/dev/null; then
    log "Ready: $VENV_PYTHON ($("$VENV_PYTHON" --version 2>&1))"
elif $CHECK_ONLY; then
    warn "Missing or incomplete — run without --check to create it"
else
    warn "Creating virtualenv (this takes a few seconds)…"
    make -C "$REPO_DIR" mcp-setup
    if ! "$VENV_PYTHON" -c "import mcp" 2>/dev/null; then
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
        cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.bak"
        log "Backed up existing config to: $(basename "$CLAUDE_CONFIG").bak"
    else
        echo '{}' > "$CLAUDE_CONFIG"
        log "Created a new config file"
    fi

    # Merge, never overwrite: every other server and preference is preserved.
    "$(host_python)" "$CONFIG_TOOL" write "$CLAUDE_CONFIG" "$VENV_PYTHON" "$MCP_SERVER"
    log "Config updated: $CLAUDE_CONFIG"
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
