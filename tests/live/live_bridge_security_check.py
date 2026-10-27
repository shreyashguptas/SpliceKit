#!/usr/bin/env python3
"""
live_bridge_security_check.py — the bridge's front door against a LIVE Final Cut Pro.

    python3 tests/live/live_bridge_security_check.py

Read-only: every request it lets through is system.version. It checks that

  - every connection opens with a bridge.hello challenge, a fresh 64-hex nonce each time;
  - a browser-style HTTP POST whose body is a JSON-RPC request gets nothing but the
    challenge and the connection is closed before the body is read (a web page reaching
    127.0.0.1:9876 used to have its body run, lua.execute included); same for a
    WebSocket handshake;
  - a request with no answer, a wrong answer, the raw key itself, or an answer to another
    connection's nonce is refused ("Unauthorized", -32003) and the connection closed, so
    the next request on it gets nothing;
  - the right answer, HMAC-SHA256(key, nonce), authenticates the connection: later
    requests on it need no answer;
  - a JSON array (not an object) closes the connection instead of reaching the dispatcher;
  - before the answer a line may be at most 64 KB (an endless one is cut off); after it,
    a request line over 64 KB is read whole;
  - the key file exists, holds 64 hex characters and is readable by this user only.
"""

import json
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


def session(make_payload, timeout=5.0):
    """Connect, read the challenge, send make_payload(nonce); return (nonce, the lines
    after the challenge, whether the bridge closed the connection)."""
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    try:
        nonce, data = live_rpc.read_hello(s)
        closed = False
        try:
            s.sendall(make_payload(nonce))
            while True:
                chunk = s.recv(1 << 20)
                if not chunk:
                    closed = True
                    break
                data += chunk
        except socket.timeout:
            pass
        except (ConnectionResetError, BrokenPipeError):
            closed = True  # closed with our bytes still unread (it stopped reading mid-line)
        lines = [json.loads(line) for line in data.split(b"\n") if line.strip()]
        return nonce, lines, closed
    finally:
        s.close()


def request(auth=None, rid=1, **extra):
    body = {"jsonrpc": "2.0", "method": "system.version", "id": rid, **extra}
    if auth is not None:
        body["auth"] = auth
    return (json.dumps(body) + "\n").encode()


def refused(lines):
    return len(lines) == 1 and lines[0].get("error", {}).get("code") == -32003


def main():
    key = live_rpc.bridge_key()
    answer = live_rpc.bridge_answer
    print("[key file]")
    path = Path(live_rpc.KEY_PATH)
    check("exists", path.is_file(), str(path))
    if not path.is_file():
        print("refusing to go on: launch the patched Final Cut Pro once so it writes the key")
        return 2
    mode = stat.S_IMODE(path.stat().st_mode)
    check("readable by this user only (0600)", mode == 0o600, oct(mode))
    check("64 hex characters", len(key) == 64 and all(c in "0123456789abcdef" for c in key), repr(key[:8]))

    print("\n[the challenge]")
    n1, _, _ = session(lambda n: b"")
    n2, _, _ = session(lambda n: b"")
    check("every connection opens with a 64-hex nonce", len(n1) == 64 and len(n2) == 64, f"{n1!r} {n2!r}")
    check("a fresh nonce each time", n1 != n2)

    print("\n[web pages]")
    body = request()  # a JSON-RPC body a page would POST; it cannot answer the challenge
    http = (b"POST / HTTP/1.1\r\nHost: 127.0.0.1:9876\r\nOrigin: https://example.com\r\n"
            b"Content-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body)) + body
    _, lines, closed = session(lambda n: http)
    check("HTTP POST: nothing after the challenge", lines == [], str(lines)[:160])
    check("HTTP POST: connection closed", closed)
    _, lines, closed = session(lambda n: http.replace(body, request(auth=answer(n))))
    check("HTTP POST carrying a right answer: still nothing, closed", lines == [] and closed, str(lines)[:160])
    ws = (b"GET / HTTP/1.1\r\nHost: 127.0.0.1:9876\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
          b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    _, lines, closed = session(lambda n: ws)
    check("WebSocket handshake: nothing, closed", lines == [] and closed, str(lines)[:160])

    print("\n[the answer]")
    _, lines, closed = session(lambda n: request() + request(auth=answer(n), rid=2))
    check("no answer: refused as Unauthorized", refused(lines), str(lines)[:200])
    check("no answer: connection closed, the request after it never runs", closed and len(lines) == 1)
    _, lines, closed = session(lambda n: request(auth="0" * 64))
    check("wrong answer: refused and closed", refused(lines) and closed, str(lines)[:200])
    _, lines, closed = session(lambda n: request(auth=key))
    check("the raw key itself is not accepted", refused(lines) and closed, str(lines)[:200])
    _, lines, closed = session(lambda n: request(auth=answer(n1)))
    check("an answer to another connection's nonce is refused", refused(lines) and closed, str(lines)[:200])
    _, lines, closed = session(lambda n: request(auth=answer(n)) + request(rid=2), timeout=3)
    check("right answer: answered", len(lines) >= 1 and "result" in lines[0], str(lines)[:200])
    check("then the same connection needs no answer",
          len(lines) == 2 and "result" in lines[1] and not closed, str(lines)[:200])
    _, lines, _ = session(lambda n: b"  \t" + request(auth=answer(n)), timeout=3)
    check("leading whitespace before the JSON is fine", lines and "result" in lines[0], str(lines)[:160])

    print("\n[framing]")
    _, lines, closed = session(lambda n: request(auth=answer(n)) + b"[1, 2]\n" + request(rid=3), timeout=3)
    check("a JSON array (not an object) closes the connection, nothing after it runs",
          len(lines) == 1 and "result" in lines[0] and closed, str(lines)[:200])
    _, lines, closed = session(lambda n: b'{"padding": "' + b"x" * 300_000, timeout=5)
    check("before the answer, a line past 64 KB is cut off and the connection closed",
          lines == [] and closed, str(lines)[:160])
    _, lines, _ = session(lambda n: request(auth=answer(n))
                          + request(rid=2, params={"padding": "x" * 200_000}), timeout=10)
    check("after the answer, a ~195 KB request line is read whole",
          len(lines) == 2 and "result" in lines[1], str(lines)[:160])
    check("the bridge still answers through live_rpc", "result" in live_rpc.rpc("system.version"))

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED: " + ", ".join(FAILS))
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
