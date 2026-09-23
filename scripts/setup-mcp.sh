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
#   ./scripts/setup-mcp.sh
#   ./scripts/setup-mcp.sh --check    # report status, change nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Honour the same override the Makefile accepts (MCP_VENV ?= ...), so that
# `make mcp-setup` and this script never disagree about where the venv lives.
# A relative override has to be pinned down first: we invoke make with -C, which
# resolves it against the repo, while a bare check here would resolve it against
# whatever directory the user happened to run this from.
VENV_DIR="${MCP_VENV:-$HOME/.venvs/splicekit-mcp}"
case "$VENV_DIR" in
    /*) ;;
    *)  VENV_DIR="$REPO_DIR/$VENV_DIR" ;;
esac
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

CLAUDE_DESKTOP_SKIPPED=false

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
# mcp.server.mcpserver). A bare `import mcp` can succeed against a partial install
# and leave us writing a config that fails at launch. Matches `make mcp-doctor`.
if [[ -x "$VENV_PYTHON" ]] && "$VENV_PYTHON" -c "import mcp.server.mcpserver" 2>/dev/null; then
    log "Ready: $VENV_PYTHON ($("$VENV_PYTHON" --version 2>&1))"
elif $CHECK_ONLY; then
    warn "Missing or incomplete — run without --check to create it"
else
    warn "Creating virtualenv (this takes a few seconds)…"
    # Pass the resolved path explicitly so make cannot pick a different one, and
    # the interpreter install.sh found (a Homebrew keg-only python is not on PATH).
    make_args=(MCP_VENV="$VENV_DIR")
    if [[ -n "${SPLICEKIT_BOOTSTRAP_PYTHON:-}" ]]; then
        make_args+=(MCP_BOOTSTRAP_PYTHON="$SPLICEKIT_BOOTSTRAP_PYTHON")
    fi
    make -C "$REPO_DIR" "${make_args[@]}" mcp-setup
    if ! "$VENV_PYTHON" -c "import mcp.server.mcpserver" 2>/dev/null; then
        err "Virtualenv created but the mcp package failed to import."
        exit 1
    fi
    log "Ready: $VENV_PYTHON"
fi

# ------------------------------------------------------------------
step "MCP server self-check"
# ------------------------------------------------------------------
# Start mcp/server.py the way a client does (a subprocess speaking MCP over
# stdio) and drive it with the official SDK: the handshake in both connect
# modes, the tool/resource/prompt listings and, in the full run, every tool,
# resource and prompt against a fake bridge. Needs no Final Cut Pro. This is the
# proof that the configs written below point at a server that actually works;
# a server that fails here is not wired into anything.
CHECK_SCRIPT="$REPO_DIR/tests/mcp_server_check.py"
if [[ -x "$VENV_PYTHON" ]] && "$VENV_PYTHON" -c "import mcp.server.mcpserver" 2>/dev/null; then
    if $CHECK_ONLY; then
        "$VENV_PYTHON" "$CHECK_SCRIPT" --quick || warn "Self-check failed — run 'make mcp-check' for the full report"
    elif ! "$VENV_PYTHON" "$CHECK_SCRIPT"; then
        err "The MCP server failed its self-check (details above)."
        err "Not writing client configs for a server that does not work. Fix the failure"
        err "(or report it with the output above), then re-run: make install"
        exit 1
    fi
else
    warn "Skipping the self-check: no working MCP virtualenv"
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
elif pgrep -x Claude >/dev/null 2>&1; then
    # Claude Desktop owns this file and rewrites it wholesale when it saves its
    # own preferences, dropping keys it did not have in memory. Writing while it
    # runs looks like it worked and then silently loses the entry minutes later,
    # which is indistinguishable from "MCP is broken". Refuse instead.
    err "Claude Desktop is running — it would overwrite this config."
    err ""
    err "Quit it completely (Cmd+Q, not just closing the window), then re-run:"
    err "  make install"
    err ""
    err "Everything else below is still set up; only the Claude Desktop entry"
    err "was skipped."
    CLAUDE_DESKTOP_SKIPPED=true
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
step "Claude Code user scope"
# ------------------------------------------------------------------
# .mcp.json above only applies while Claude Code runs from inside this checkout.
# Editing happens over the bridge in the running Final Cut Pro, not against files
# on disk, so there is no reason to be in this directory — register the server at
# user scope as well and it works from anywhere, including the folder the footage
# actually lives in.
if ! command -v claude >/dev/null 2>&1; then
    warn "The 'claude' CLI is not on PATH — skipping user-scope registration"
    warn "Claude Code will still work when run from $REPO_DIR"
elif claude mcp get splicekit 2>/dev/null | grep -q -F "$MCP_SERVER"; then
    log "Already registered at user scope (works from any directory)"
elif $CHECK_ONLY; then
    warn "Not registered at user scope (or registered for another checkout) — run without --check to fix"
else
    # A stale entry (an older checkout or venv path) is replaced, not kept.
    claude mcp remove --scope user splicekit >/dev/null 2>&1 || true
    if claude mcp add --scope user splicekit "$VENV_PYTHON" "$MCP_SERVER" >/dev/null 2>&1; then
        log "Registered at user scope — Claude Code can use it from any directory"
    else
        warn "Could not register at user scope. Add it by hand with:"
        warn "  claude mcp add --scope user splicekit \"$VENV_PYTHON\" \"$MCP_SERVER\""
    fi
fi

# ------------------------------------------------------------------
step "Any other MCP client"
# ------------------------------------------------------------------
# Nothing here is Claude-specific. The server speaks MCP over stdio, the
# standard transport, and depends only on the reference `mcp` package — so any
# client that speaks the protocol can drive Final Cut Pro with it. The steps
# above just write the config files two particular clients happen to read.
# These are the details to hand to anything else.
cat <<EOF
Transport: stdio
Command:   $VENV_PYTHON
Arguments: $MCP_SERVER

Most clients take this shape of JSON:

  {
    "mcpServers": {
      "splicekit": {
        "command": "$VENV_PYTHON",
        "args": ["$MCP_SERVER"]
      }
    }
  }

Clients that take a single command line instead:

  $VENV_PYTHON $MCP_SERVER
EOF

# ------------------------------------------------------------------
step "Patched Final Cut Pro"
# ------------------------------------------------------------------
# The patcher's --dest and --app-name mean the copy is not necessarily at the
# default path under a default name, so look for any app in either Applications
# folder that actually carries the injected dylib rather than probing fixed
# names. The stock Final Cut Pro sitting beside it has no SpliceKit load
# command, so it can never match.
PATCHED_APP=""
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if otool -L "$candidate/Contents/MacOS/Final Cut Pro" 2>/dev/null | grep -q SpliceKit; then
        PATCHED_APP="$candidate"
        break
    fi
done < <(find /Applications "$HOME/Applications" -maxdepth 2 -name "*.app" -type d 2>/dev/null)

if [[ -n "$PATCHED_APP" ]]; then
    log "Found: $PATCHED_APP"
else
    warn "No patched Final Cut Pro found in /Applications or ~/Applications"
    warn "Create one first:  make install"
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
1. The patched Final Cut Pro must be the running copy (make install opens
   it for you). The patched copy and the App Store copy share one app
   identity, so opening one while the other runs just switches to the copy
   already running — quit the original first.
2. Fully quit Claude Desktop (Cmd+Q) and reopen it, so it reloads the config.
3. Ask Claude to do something in Final Cut Pro. Re-run this script with
   --check at any time to confirm the wiring, or 'make mcp-check-live' to
   drive the running Final Cut Pro through the MCP server (read-only).
EOF

if $CLAUDE_DESKTOP_SKIPPED; then
    echo
    err "Claude Desktop was NOT configured — it was running. Quit it (Cmd+Q) and"
    err "re-run 'make install', or it will not see the splicekit server."
    # Distinct exit code so make install can say so in its final banner
    # instead of reporting a fully verified setup.
    exit 3
fi
