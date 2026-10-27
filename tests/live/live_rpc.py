"""The JSON-RPC client the live scripts share: one request per connection to the bridge
inside Final Cut Pro (newline-delimited JSON-RPC 2.0), the parsed response back.

    from live_rpc import rpc
    rpc("system.version")            ->  {"jsonrpc": "2.0", "id": 1, "result": {...}}

Lines that are not the reply to this request (event notifications, which carry a
"method" and no "id") are skipped rather than returned as the answer.
"""
import hashlib
import hmac
import itertools
import json
import os
import socket

HOST = "127.0.0.1"
PORT = 9876
_ids = itertools.count(1)
KEY_PATH = os.path.expanduser("~/Library/Application Support/SpliceKit/bridge-key")


def bridge_key():
    """The key the bridge wants as "auth" (SPLICEKIT_BRIDGE_KEY, else the key file)."""
    if os.environ.get("SPLICEKIT_BRIDGE_KEY"):
        return os.environ["SPLICEKIT_BRIDGE_KEY"].strip()
    try:
        with open(KEY_PATH, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def bridge_answer(nonce, key=None):
    """HMAC-SHA256(key, nonce) hex: what the bridge accepts as "auth" on the connection
    that sent `nonce` in its bridge.hello. The key itself never goes over the socket."""
    key = bridge_key() if key is None else key
    if not nonce or not key:
        return ""
    return hmac.new(key.encode(), nonce.encode(), hashlib.sha256).hexdigest()


def read_hello(sock, data=b""):
    """(nonce, leftover bytes): the challenge the bridge opens every connection with."""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return "", data
        data += chunk
    line, rest = data.split(b"\n", 1)
    frame = json.loads(line.decode())
    if frame.get("method") == "bridge.hello":
        return str(frame.get("params", {}).get("nonce", "")), rest
    return "", data


def rpc(method, params=None, timeout=10, *, host=None, port=None):
    """Send one request and return the parsed response ({"result": ...} or {"error": ...})."""
    request_id = next(_ids)
    req = {"jsonrpc": "2.0", "method": method, "id": request_id}
    if params:
        req["params"] = params
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host or HOST, port or PORT))
        nonce, data = read_hello(s)
        req["auth"] = bridge_answer(nonce)
        s.sendall((json.dumps(req) + "\n").encode())
        while True:
            while b"\n" not in data:
                chunk = s.recv(1 << 20)
                if not chunk:
                    return json.loads(data.decode().strip())
                data += chunk
            line, data = data.split(b"\n", 1)
            if not line.strip():
                continue
            message = json.loads(line.decode())
            if "id" not in message and "method" in message:
                continue  # an event notification, not our reply
            return message
    finally:
        s.close()
