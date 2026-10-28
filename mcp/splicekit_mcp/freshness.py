"""Notices when this server's own code changed on disk after it started.

An MCP client starts the server once and keeps it for the whole session. A `git pull`
or a merge after that leaves the old code running: on 27 Oct 2026 a server started
before bridge authentication existed sent requests without "auth", and every tool
failed with "Unauthorized" while the code on disk was fine. Now every error result
carries a notice saying to reconnect the server, and bridge_status reports it, so the
cause is visible from the first failure instead of being guessed at.

Successful results are left alone: callers parse them (the live tool sweep reads the
JSON), and a notice appended to every result broke all of that the moment a file
changed under a running server.
"""

import os
import threading
import time

_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
_CHECK_EVERY = 30.0  # seconds; a stat of ~40 files, so cheap, but not on every call


def _fingerprint(root: str = _PACKAGE_DIR) -> tuple:
    """(number of .py files, newest modification time) under the package."""
    count, newest = 0, 0
    for directory, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for name in filenames:
            if name.endswith(".py"):
                try:
                    newest = max(newest, os.stat(os.path.join(directory, name)).st_mtime_ns)
                except OSError:
                    continue
                count += 1
    return count, newest


_started = _fingerprint()
_lock = threading.Lock()
_last_check = time.monotonic()
_stale = False

STALE_NOTICE = (
    "NOTE: SpliceKit's MCP server code changed on disk after this server started, so the "
    "client is still running the old version. Reconnect the splicekit MCP server (in "
    "Claude Code: /mcp, then splicekit, then Reconnect; or restart the client) to load it."
)


def server_code_changed(now: float = None) -> bool:
    """True once the package's .py files differ from what was loaded at startup."""
    global _last_check, _stale
    now = time.monotonic() if now is None else now
    with _lock:
        if not _stale and now - _last_check >= _CHECK_EVERY:
            _last_check = now
            _stale = _fingerprint() != _started
        return _stale


def with_stale_notice(result):
    """`result` with STALE_NOTICE appended when it is an error text ("Error: ...") and the
    server code changed; anything else unchanged."""
    if (isinstance(result, str) and result.lstrip()[:5].lower() == "error"
            and server_code_changed()):
        return f"{result}\n\n{STALE_NOTICE}"
    return result
