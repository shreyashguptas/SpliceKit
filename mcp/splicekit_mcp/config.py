"""Where the bridge listens, SpliceKit's version, and the repository root."""

import sys
import os
import logging


# Where the bridge inside Final Cut Pro listens. The environment overrides exist for
# the test harness (tests/mcp_server_check.py points the server at a fake bridge);
# a normal install never sets them. The bridge speaks plaintext JSON-RPC and this
# server forwards clip names, transcript text and file paths to it, so a host other
# than loopback is refused unless SPLICEKIT_ALLOW_REMOTE=1 says that is intended.
_LOG = logging.getLogger("splicekit-mcp")


def _bridge_address() -> tuple:
    host = os.environ.get("SPLICEKIT_HOST") or "127.0.0.1"
    try:
        port = int(os.environ.get("SPLICEKIT_PORT") or 9876)
    except ValueError:
        sys.stderr.write(f"[splicekit-mcp] ignoring SPLICEKIT_PORT={os.environ.get('SPLICEKIT_PORT')!r}; using 9876\n")
        port = 9876
    if host not in ("127.0.0.1", "localhost", "::1") and os.environ.get("SPLICEKIT_ALLOW_REMOTE") != "1":
        sys.stderr.write(f"[splicekit-mcp] ignoring SPLICEKIT_HOST={host!r} (not loopback; set "
                         "SPLICEKIT_ALLOW_REMOTE=1 if that is really intended); using 127.0.0.1\n")
        host = "127.0.0.1"
    if (host, port) != ("127.0.0.1", 9876):
        sys.stderr.write(f"[splicekit-mcp] bridge address overridden by environment: {host}:{port}\n")
    return host, port


SPLICEKIT_HOST, SPLICEKIT_PORT = _bridge_address()


# The repository root (the directory holding VERSION, Makefile and build/). This file
# is mcp/splicekit_mcp/config.py, so that is three levels up.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _splicekit_version() -> str:
    """SpliceKit's version string (the VERSION file at the repo root), or "" when the
    file is not beside this checkout. Reported to MCP clients as the server version."""
    try:
        path = os.path.join(REPO_ROOT, "VERSION")
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


SPLICEKIT_VERSION = _splicekit_version()
