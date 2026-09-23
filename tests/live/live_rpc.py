"""The JSON-RPC client the live scripts share: one request per connection to the bridge
inside Final Cut Pro (newline-delimited JSON-RPC 2.0), the parsed response back.

    from live_rpc import rpc
    rpc("system.version")            ->  {"jsonrpc": "2.0", "id": 1, "result": {...}}

Lines that are not the reply to this request (event notifications, which carry a
"method" and no "id") are skipped rather than returned as the answer.
"""
import itertools
import json
import socket

HOST = "127.0.0.1"
PORT = 9876
_ids = itertools.count(1)


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
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
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
