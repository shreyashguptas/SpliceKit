#!/usr/bin/env python3
"""
live_bridge_security_check.py — the bridge's front door against a LIVE Final Cut Pro.

    python3 tests/live/live_bridge_security_check.py

Read-only: every request it lets through is system.version. It checks that

  - a browser-style HTTP POST whose body is a JSON-RPC request gets no answer and the
    connection is closed before the body is read (a web page reaching 127.0.0.1:9876
    used to have its body run, lua.execute included);
  - a WebSocket handshake is closed the same way;
  - a request without the bridge key, or with a wrong one, is refused ("Unauthorized",
    code -32003) and the connection closed, so the next request on it gets nothing;
  - the right key authenticates the connection: later requests on it need no key;
  - a JSON array (not an object) closes the connection instead of reaching the dispatcher;
  - a request line over 64 KB is read whole;
  - the key file exists, holds 64 hex characters and is readable by this user only.
"""

import json
import os
import socket
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_rpc  # noqa: E402

HOST, PORT = "127.0.0.1", 9876
FAILS = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def exchange(payload: bytes, timeout=5.0):
    """Send raw bytes on a fresh connection; return (reply lines, closed_by_server)."""
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    try:
        s.sendall(payload)
        data, closed = b"", False
        try:
            while True:
                chunk = s.recv(1 << 20)
                if not chunk:
                    closed = True
                    break
                data += chunk
        except socket.timeout:
            pass
        lines = [json.loads(line) for line in data.split(b"\n") if line.strip()]
        return lines, closed
    finally:
        s.close()


def request(method="system.version", auth=None, rid=1, **extra):
    body = {"jsonrpc": "2.0", "method": method, "id": rid, **extra}
    if auth is not None:
        body["auth"] = auth
    return (json.dumps(body) + "\n").encode()


def main():
    key = live_rpc.bridge_key()
    print("[key file]")
    path = Path(live_rpc.KEY_PATH)
    check("exists", path.is_file(), str(path))
    if not path.is_file():
        print("refusing to go on: launch the patched Final Cut Pro once so it writes the key")
        return 2
    mode = stat.S_IMODE(path.stat().st_mode)
    check("readable by this user only (0600)", mode == 0o600, oct(mode))
    check("64 hex characters", len(key) == 64 and all(c in "0123456789abcdef" for c in key), repr(key[:8]))

    print("\n[web pages]")
    body = request()  # a JSON-RPC body a page would POST, with no key: it cannot know it
    http = (b"POST / HTTP/1.1\r\nHost: 127.0.0.1:9876\r\nOrigin: https://example.com\r\n"
            b"Content-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body)) + body
    lines, closed = exchange(http)
    check("HTTP POST: no answer at all", lines == [], str(lines)[:160])
    check("HTTP POST: connection closed", closed)
    # Even a page that somehow had the key: the request line closes it first.
    lines, closed = exchange(http.replace(body, request(auth=key)))
    check("HTTP POST carrying the key: still no answer", lines == [] and closed, str(lines)[:160])
    ws = (b"GET / HTTP/1.1\r\nHost: 127.0.0.1:9876\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
          b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    lines, closed = exchange(ws)
    check("WebSocket handshake: no answer, closed", lines == [] and closed, str(lines)[:160])

    print("\n[the key]")
    lines, closed = exchange(request() + request(auth=key, rid=2))
    check("no key: refused as Unauthorized",
          len(lines) == 1 and lines[0].get("error", {}).get("code") == -32003, str(lines)[:200])
    check("no key: connection closed, the request after it never runs", closed and len(lines) == 1)
    lines, closed = exchange(request(auth="0" * 64))
    check("wrong key: refused and closed",
          closed and len(lines) == 1 and lines[0].get("error", {}).get("code") == -32003, str(lines)[:200])
    lines, closed = exchange(request(auth=key) + request(rid=2), timeout=3)
    check("right key: answered", len(lines) >= 1 and "result" in lines[0], str(lines)[:200])
    check("then the same connection needs no key",
          len(lines) == 2 and "result" in lines[1] and not closed, str(lines)[:200])
    lines, _ = exchange(b"  \t" + request(auth=key), timeout=3)
    check("leading whitespace before the JSON is fine", lines and "result" in lines[0], str(lines)[:160])

    print("\n[framing]")
    lines, closed = exchange(request(auth=key) + b"[1, 2]\n" + request(auth=key, rid=3), timeout=3)
    check("a JSON array (not an object) closes the connection, nothing after it runs",
          len(lines) == 1 and "result" in lines[0] and closed, str(lines)[:200])
    big = request(auth=key, params={"padding": "x" * 200_000})
    lines, _ = exchange(big, timeout=10)
    check(f"a {len(big) // 1024} KB request line is read whole", lines and "result" in lines[0], str(lines)[:160])
    check("the bridge still answers through live_rpc", "result" in live_rpc.rpc("system.version"))

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED: " + ", ".join(FAILS))
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
