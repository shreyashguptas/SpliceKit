"""The JSON-RPC connection to the bridge inside Final Cut Pro, and call helpers."""

import socket
import json
import functools
import atexit
import threading

from .config import SPLICEKIT_HOST, SPLICEKIT_PORT


class BridgeConnection:
    """Persistent TCP connection to the SpliceKit JSON-RPC server inside FCP.

    Keeps the socket open between calls so we don't pay the connect overhead
    on every tool invocation. Auto-reconnects if the connection drops (FCP
    restarted, socket timed out, etc).
    """

    def __init__(self):
        self.sock = None
        self._buf = b""  # leftover bytes from previous recv (newline-delimited protocol)
        self._id = 0     # monotonically increasing JSON-RPC request ID
        # The mcp 2.x SDK runs synchronous tools in worker threads, so two tool calls
        # can be in flight at once (a client sending parallel calls, or a call that is
        # still running after the client gave up on it). One socket, one read buffer and
        # one id counter must not be shared between them: serialize every round trip.
        self._lock = threading.Lock()

    CONNECT_TIMEOUT = 5    # loopback either accepts at once or refuses
    READ_TIMEOUT = 30      # some bridge calls wait on FCP's main thread (20 s watchdog inside)

    def ensure_connected(self):
        if self.sock is None:
            # Assign only after connect() succeeds: a refused connect must not leave
            # a dead socket behind, or the next call fails once before reconnecting.
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.CONNECT_TIMEOUT)
            try:
                sock.connect((SPLICEKIT_HOST, SPLICEKIT_PORT))
            except OSError:
                sock.close()
                raise
            sock.settimeout(self.READ_TIMEOUT)
            self.sock = sock
            self._buf = b""

    def reset(self):
        """Drop the connection (the next call reconnects). Safe to call from any thread;
        deploy_and_restart uses it around killing and relaunching Final Cut Pro."""
        with self._lock:
            self._drop_socket()

    close = reset

    def _drop_socket(self):
        sock, self.sock, self._buf = self.sock, None, b""
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def call(self, method: str, params_dict=None, /, *, timeout: float = None, **params) -> dict:
        """Send a JSON-RPC request and wait for the response.

        Accepts params as keyword args OR as a single dict positional arg:
            bridge.call("method", key="value")       # kwargs
            bridge.call("method", {"key": "value"})  # dict

        `method` and `params_dict` are positional-only so that an RPC parameter of
        the same name cannot collide with them. bridge.describe takes a parameter
        literally called "method", and before this that call raised
        "got multiple values for argument 'method'" instead of reaching the bridge.
        An RPC parameter named "timeout" still has to go through the dict form.

        `timeout` (seconds) bounds this one round trip instead of the usual READ_TIMEOUT;
        the import-time plugin probe uses it so a Final Cut Pro whose main thread is busy
        cannot hold up the MCP handshake.

        Returns the result dict on success, or {"error": "..."} on failure.
        Handles connection errors gracefully — the next call will auto-reconnect.
        """
        # Merge positional dict and kwargs so callers can use either style
        if params_dict is not None:
            if isinstance(params_dict, dict):
                params = {**params_dict, **params}
            # else ignore non-dict positional (shouldn't happen)
        # One round trip at a time: the lock is held across the read, so a call that
        # waits on FCP's main thread delays the calls queued behind it (by design: there
        # is one bridge and one socket, and interleaving frames would be worse).
        with self._lock:
            return self._call_locked(method, params, timeout)

    def _call_locked(self, method: str, params: dict, timeout: float = None) -> dict:
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as e:
            return {"error": f"Cannot connect to SpliceKit at {SPLICEKIT_HOST}:{SPLICEKIT_PORT}. "
                    f"Is the modded FCP running? Error: {e}"}
        if timeout is not None:
            self.sock.settimeout(timeout)

        self._id += 1
        expected_id = self._id
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": expected_id})
        try:
            # Protocol: newline-delimited JSON, one request/response per line.
            # The server may also emit unsolicited `method:"event"` frames
            # (JSON-RPC notifications) on the same socket. Those must NOT be
            # consumed as the response. Loop until we see a frame with a
            # matching `id`; drop anything else.
            self.sock.sendall(req.encode() + b"\n")
            while True:
                while b"\n" not in self._buf:
                    chunk = self.sock.recv(16777216)  # 16MB — FCPXML responses can be large
                    if not chunk:
                        self.sock = None  # server closed the connection, force reconnect next call
                        return {"error": "Connection closed by SpliceKit"}
                    self._buf += chunk
                line, self._buf = self._buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    resp = json.loads(line)
                except json.JSONDecodeError:
                    # Corrupt frame — skip it and keep reading
                    continue
                # Skip notifications (no id, or has a method field)
                if "method" in resp or "id" not in resp:
                    continue
                # Skip responses whose id doesn't match (stale from a prior
                # call that timed out or got interrupted)
                if resp.get("id") != expected_id:
                    continue
                if "error" in resp:
                    return {"error": resp["error"]}
                return resp.get("result", {})
        except Exception as e:
            self._drop_socket()  # toss the broken socket so the next call reconnects
            return {"error": f"Bridge communication error: {e}"}
        finally:
            if timeout is not None and self.sock is not None:
                self.sock.settimeout(self.READ_TIMEOUT)


bridge = BridgeConnection()  # singleton -- shared by all tool functions below
atexit.register(bridge.close)


# -- Helpers used by every tool function --

def _err(r):
    """Check if a bridge response contains an error."""
    return "error" in r


def _fmt(r):
    """Pretty-print a bridge response as indented JSON."""
    return json.dumps(r, indent=2, default=str)


def _call_or_error(method: str, /, **params) -> str:
    """Call the bridge and return formatted JSON, or an error string.

    `method` is positional-only: an RPC parameter of the same name would otherwise
    collide with it (see BridgeConnection.call).

    This is the common pattern used by most tools — call the bridge,
    check for errors, format the result. Having it in one place means
    we don't repeat the same 4 lines in every tool function.
    """
    r = bridge.call(method, **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if isinstance(r, dict) and r.get("dialogPending") and r.get("note"):
        # A sheet or modal dialog is open after the action: nothing has happened on the
        # timeline yet, so say that before the JSON (whose key order is not fixed).
        return f"DIALOG PENDING: {r['note']}\n\n{_fmt(r)}"
    return _fmt(r)


class BridgeError(Exception):
    """Raised when a bridge call returns an error."""
    pass


def _call(method: str, /, **params) -> dict:
    """Call the bridge and return the result dict. Raises BridgeError on failure.

    `method` is positional-only for the same reason as _call_or_error."""
    r = bridge.call(method, **params)
    if _err(r):
        raise BridgeError(r.get("error", str(r)))
    return r


def bridge_tool(fn):
    """Decorator: catches BridgeError and returns 'Error: ...' string.

    Use with _call() to eliminate the repetitive if-_err-return pattern:
        @splicekit_tool("my_tool")
        @bridge_tool
        def my_tool() -> str:
            r = _call("my.method")
            return _fmt(r)
    """
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except BridgeError as e:
            return f"Error: {e}"
    return wrapper
