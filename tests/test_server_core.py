#!/usr/bin/env python3
"""Unit tests for the server core (registry, bridge connection, config), much of it added
in the move to the mcp 2.x SDK.

Runs without the mcp package (the shared fake loader in test_mcp_tool_annotations
stands in for the SDK): the tool error guard, the tool registration helper, the bridge
lock and reset, per-call timeouts, batch clip iteration from timeline state, the bridge
address overrides and the reported version.
"""
import inspect
import json
import os
import re
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import FakeToolError, load_server_module, set_package_global  # noqa: E402
from support.fake_bridge import FakeBridge  # noqa: E402
from support.payloads import cmtime, media_spine_item, three_clip_detailed_state  # noqa: E402


class FakeSocket:
    """A bridge socket whose replies arrive in a chosen order and after a chosen delay,
    so two threads calling at once would read each other's frames without the lock."""

    def __init__(self, delay=0.0):
        self.sent = []
        self._pending = []
        self.delay = delay
        self.timeout = None
        self.closed = False
        self.lock = threading.Lock()

    # socket API used by BridgeConnection
    def settimeout(self, value):
        self.timeout = value

    def gettimeout(self):
        return self.timeout

    NONCE = "ef" * 32

    def connect(self, address):
        # The real bridge opens every connection with its challenge.
        self._hello = True

    def close(self):
        self.closed = True

    def sendall(self, data):
        req = json.loads(data)
        with self.lock:
            self.sent.append(req)
            self._pending.append(req)

    def recv(self, _size):
        import time
        if getattr(self, "_hello", False):
            self._hello = False
            hello = {"jsonrpc": "2.0", "method": "bridge.hello",
                     "params": {"nonce": self.NONCE, "auth": "hmac-sha256"}}
            return (json.dumps(hello) + "\n").encode()
        time.sleep(self.delay)
        with self.lock:
            req = self._pending.pop(0)
        frame = {"jsonrpc": "2.0", "id": req["id"], "result": {"echo": req["method"], "id": req["id"]}}
        return (json.dumps(frame) + "\n").encode()


class ServerV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    # -- registration helper -----------------------------------------------------
    def test_splicekit_tool_registers_annotations_and_keeps_signature(self):
        m = self.module
        tool = self.tools["seek_to_time"]
        self.assertEqual(tool["annotations"]["title"], "Seek To Time")
        self.assertIn("readOnlyHint", tool["annotations"])
        # functools.wraps: the SDK derives the input schema from the original signature.
        params = inspect.signature(tool["func"]).parameters
        self.assertIn("seconds", params)
        self.assertEqual(tool["func"].__doc__, m.seek_to_time.__doc__)

    def test_splicekit_tool_rejects_a_name_that_does_not_match_the_function(self):
        m = self.module
        with self.assertRaises(ValueError):
            @m.splicekit_tool("brand_new_tool", m.READ)
            def not_brand_new_tool():
                return "x"
        # Nothing was recorded for the refused registration.
        self.assertNotIn("brand_new_tool", m.READ_ONLY_TOOLS)
        self.assertNotIn("brand_new_tool", self.tools)

    def test_splicekit_tool_rejects_a_second_registration_and_an_unknown_class(self):
        m = self.module
        with self.assertRaises(ValueError):
            @m.splicekit_tool("bridge_status", m.READ)
            def bridge_status():
                return "x"
        with self.assertRaises(ValueError):
            m.splicekit_tool("brand_new_tool", "read-only")

    def test_guard_rejects_coroutine_functions(self):
        m = self.module

        async def async_tool():
            return "x"

        with self.assertRaises(TypeError):
            m._guard_tool_errors(async_tool)

    # -- error guard ---------------------------------------------------------------
    def test_guard_converts_unexpected_exceptions_to_tool_error_with_text(self):
        m = self.module

        @m._guard_tool_errors
        def broken():
            return {}["items"]

        with self.assertRaises(FakeToolError) as ctx:
            broken()
        self.assertEqual(str(ctx.exception), "KeyError: 'items'")
        self.assertIsInstance(ctx.exception.__cause__, KeyError)

    def test_guard_passes_tool_error_and_normal_returns_through(self):
        m = self.module

        @m._guard_tool_errors
        def deliberate():
            raise FakeToolError("the clip handle is unresolved")

        with self.assertRaises(FakeToolError) as ctx:
            deliberate()
        self.assertEqual(str(ctx.exception), "the clip handle is unresolved")

        @m._guard_tool_errors
        def fine(x: int = 1) -> str:
            return f"Error: soft failure {x}"

        self.assertEqual(fine(2), "Error: soft failure 2")
        self.assertEqual(fine.__name__, "fine")

    # -- bridge connection ----------------------------------------------------------
    def _patched_bridge(self, fake):
        m = self.module
        b = m.BridgeConnection()
        original = m.socket.socket
        m.socket.socket = lambda *a, **k: fake
        self.addCleanup(setattr, m.socket, "socket", original)
        return b

    def test_concurrent_calls_are_serialized_and_get_their_own_reply(self):
        fake = FakeSocket(delay=0.01)
        b = self._patched_bridge(fake)
        results = {}

        def worker(i):
            results[i] = b.call(f"method.{i}")

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(results), 8)
        for i, r in results.items():
            self.assertEqual(r["echo"], f"method.{i}", r)
        self.assertEqual(sorted(req["id"] for req in fake.sent), list(range(1, 9)))

    def test_every_request_answers_the_challenge_and_the_key_never_leaves(self):
        # The bridge opens each connection with a nonce and runs nothing until a request
        # carries HMAC-SHA256(key, nonce); the key itself must never be sent.
        import hashlib
        import hmac
        fake = FakeSocket()
        b = self._patched_bridge(fake)
        key = "ab" * 32
        os.environ["SPLICEKIT_BRIDGE_KEY"] = key
        self.addCleanup(os.environ.pop, "SPLICEKIT_BRIDGE_KEY", None)
        b.call("one")
        b.call("two")
        answer = hmac.new(key.encode(), FakeSocket.NONCE.encode(), hashlib.sha256).hexdigest()
        self.assertEqual([req["auth"] for req in fake.sent], [answer] * 2)
        self.assertNotIn(key, json.dumps(fake.sent))

    def test_bridge_key_is_read_from_the_key_file(self):
        m = self.module
        os.environ.pop("SPLICEKIT_BRIDGE_KEY", None)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bridge-key")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("cd" * 32 + "\n")
            old = m.BRIDGE_KEY_PATH
            set_package_global(m, "BRIDGE_KEY_PATH", path)
            try:
                self.assertEqual(m.bridge_key(), "cd" * 32)
                os.remove(path)
                self.assertEqual(m.bridge_key(), "", "no key file: send none and let the bridge say why")
            finally:
                set_package_global(m, "BRIDGE_KEY_PATH", old)

    def test_connect_timeout_then_read_timeout_and_per_call_override(self):
        fake = FakeSocket()
        b = self._patched_bridge(fake)
        b.ensure_connected()
        self.assertEqual(fake.timeout, b.READ_TIMEOUT)
        b.call("x", timeout=2.0)
        self.assertEqual(fake.timeout, b.READ_TIMEOUT, "per-call timeout must be restored")

    def test_reset_closes_the_socket_and_forgets_the_buffer(self):
        fake = FakeSocket()
        b = self._patched_bridge(fake)
        b.ensure_connected()
        b._buf = b"partial"
        b.reset()
        self.assertIsNone(b.sock)
        self.assertEqual(b._buf, b"")
        self.assertTrue(fake.closed)
        b.reset()  # idempotent

    def test_refused_connection_is_reported_not_raised(self):
        m = self.module
        b = m.BridgeConnection()
        spare = socket.socket()
        spare.bind(("127.0.0.1", 0))
        port = spare.getsockname()[1]
        spare.close()  # nothing listens here now
        # The address is a global of the package modules (config, and bridge, which
        # connects to it); rebind it where the connection reads it.
        old = (m.SPLICEKIT_HOST, m.SPLICEKIT_PORT)
        set_package_global(m, "SPLICEKIT_HOST", "127.0.0.1")
        set_package_global(m, "SPLICEKIT_PORT", port)
        try:
            r = b.call("system.version")
        finally:
            set_package_global(m, "SPLICEKIT_HOST", old[0])
            set_package_global(m, "SPLICEKIT_PORT", old[1])
        self.assertIn("Cannot connect to SpliceKit", r["error"])

    def _serve(self, handler):
        """A loopback bridge stand-in on a free port, running `handler(listener)` in a
        thread; the package's bridge address points at it for this test."""
        m = self.module
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        old = (m.SPLICEKIT_HOST, m.SPLICEKIT_PORT)
        set_package_global(m, "SPLICEKIT_HOST", "127.0.0.1")
        set_package_global(m, "SPLICEKIT_PORT", listener.getsockname()[1])
        self.addCleanup(set_package_global, m, "SPLICEKIT_PORT", old[1])
        self.addCleanup(set_package_global, m, "SPLICEKIT_HOST", old[0])
        self.addCleanup(listener.close)
        thread = threading.Thread(target=handler, args=(listener,), daemon=True)
        thread.start()
        return thread

    @staticmethod
    def _wait_for_close(b, seconds=5.0):
        """Wait until the bridge's close has reached this end of the socket."""
        import select
        import time
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if select.select([b.sock], [], [], 0.05)[0]:
                return
        raise AssertionError("the stand-in bridge never closed the connection")

    def test_close_behind_unread_event_frames_is_still_seen(self):
        # An events_subscribe client has event frames waiting when Final Cut Pro quits;
        # the close sits behind them and must not be mistaken for a live socket.
        def bridge_that_sends_events_then_restarts(listener):
            conn, _ = listener.accept()
            self._answer_one(conn, {"answer": "first"})
            event = {"jsonrpc": "2.0", "method": "event", "params": {"type": "playhead"}}
            conn.sendall(((json.dumps(event) + "\n") * 3).encode())
            conn.close()
            conn, _ = listener.accept()
            self._answer_one(conn, {"answer": "second"})
            conn.close()

        thread = self._serve(bridge_that_sends_events_then_restarts)
        b = self.module.BridgeConnection()
        self.assertEqual(b.call("one"), {"answer": "first"})
        self._wait_for_close(b)
        import time
        time.sleep(0.05)  # the events and the close arrive together on loopback
        self.assertEqual(b.call("two"), {"answer": "second"})
        thread.join(timeout=5)
        b.reset()

    @staticmethod
    def _answer_one(conn, result):
        hello = {"jsonrpc": "2.0", "method": "bridge.hello", "params": {"nonce": "n1"}}
        conn.sendall((json.dumps(hello) + "\n").encode())
        req = json.loads(conn.makefile().readline())
        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}) + "\n").encode())
        return req

    def test_first_call_after_final_cut_restarts_reconnects(self):
        # Final Cut Pro quitting closes the bridge socket between two calls. The next
        # call used to be sent on the dead socket and fail with "Connection closed".
        seen = []

        def bridge_that_restarts(listener):
            for answer in ("first", "second"):
                conn, _ = listener.accept()
                seen.append(self._answer_one(conn, {"answer": answer})["method"])
                conn.close()

        thread = self._serve(bridge_that_restarts)
        b = self.module.BridgeConnection()
        self.assertEqual(b.call("one"), {"answer": "first"})
        self._wait_for_close(b)
        self.assertEqual(b.call("two"), {"answer": "second"})
        thread.join(timeout=5)
        self.assertEqual(seen, ["one", "two"])
        b.reset()

    def test_close_mid_call_is_reported_and_the_next_call_reconnects(self):
        def bridge_that_dies_then_comes_back(listener):
            conn, _ = listener.accept()
            hello = {"jsonrpc": "2.0", "method": "bridge.hello", "params": {"nonce": "n1"}}
            conn.sendall((json.dumps(hello) + "\n").encode())
            conn.makefile().readline()
            conn.close()  # crashed before answering
            conn, _ = listener.accept()
            self._answer_one(conn, {"ok": True})
            conn.close()

        thread = self._serve(bridge_that_dies_then_comes_back)
        b = self.module.BridgeConnection()
        r = b.call("timeline.blade")
        self.assertIn("Connection closed by SpliceKit before it answered timeline.blade", r["error"])
        self.assertIsNone(b.sock)
        self.assertEqual(b._buf, b"")
        self.assertEqual(b.call("system.version"), {"ok": True})
        thread.join(timeout=5)
        b.reset()

    def test_mismatch_errors_say_how_to_fix_them(self):
        explain = self.module._package_modules["splicekit_mcp.bridge"]._explain_bridge_error
        old_dylib = explain("timeline.newThing", {"code": -32601, "message": "Method not found: timeline.newThing"})
        self.assertTrue(old_dylib["message"].startswith("Method not found: timeline.newThing"))
        self.assertIn("make deploy", old_dylib["message"])
        self.assertEqual(old_dylib["code"], -32601)
        unauthorized = explain("x", {"code": -32003, "message": "Unauthorized: answer this connection's nonce"})
        self.assertIn("bridge-key", unauthorized["message"])
        other = {"code": -32000, "message": "No active timeline module"}
        self.assertEqual(explain("x", other), other)
        self.assertEqual(explain("x", "plain text"), "plain text")

    def test_errors_say_when_the_server_code_changed_on_disk(self):
        m = self.module
        freshness = m._package_modules["splicekit_mcp.freshness"]

        @m._guard_tool_errors
        def tool() -> str:
            return '{"result": 1}'

        @m._guard_tool_errors
        def soft_error() -> str:
            return "Error: Unauthorized"

        @m._guard_tool_errors
        def failing():
            raise FakeToolError("no clip")

        saved = (freshness._started, freshness._stale, freshness._last_check)
        self.addCleanup(lambda: (setattr(freshness, "_started", saved[0]),
                                 setattr(freshness, "_stale", saved[1]),
                                 setattr(freshness, "_last_check", saved[2])))
        freshness._stale = False
        freshness._last_check = -1e9
        self.assertEqual(soft_error(), "Error: Unauthorized", "unchanged code: no notice")

        freshness._started = (0, 0)  # as if every file changed since startup
        freshness._last_check = -1e9
        self.assertTrue(soft_error().endswith(freshness.STALE_NOTICE))
        self.assertEqual(json.loads(tool()), {"result": 1},
                         "a successful result stays parseable: no notice on it")
        with self.assertRaises(FakeToolError) as ctx:
            failing()
        self.assertTrue(str(ctx.exception).startswith("no clip"))
        self.assertIn("Reconnect the splicekit MCP server", str(ctx.exception))

    def test_bridge_status_reports_changed_server_code_in_its_json(self):
        m = self.module
        freshness = m._package_modules["splicekit_mcp.freshness"]
        saved = (freshness._started, freshness._stale, freshness._last_check)
        self.addCleanup(lambda: (setattr(freshness, "_started", saved[0]),
                                 setattr(freshness, "_stale", saved[1]),
                                 setattr(freshness, "_last_check", saved[2])))
        self.addCleanup(FakeBridge(m, {"fcp_version": "12.4"}).install().restore)
        freshness._stale, freshness._last_check = False, -1e9
        self.assertNotIn("mcpServerCodeChanged", json.loads(m.bridge_status()))
        freshness._started, freshness._last_check = (0, 0), -1e9
        status = json.loads(m.bridge_status())
        self.assertTrue(status["mcpServerCodeChanged"])
        self.assertEqual(status["fcp_version"], "12.4")

    def test_server_code_fingerprint_sees_an_edited_file(self):
        freshness = self.module._package_modules["splicekit_mcp.freshness"]
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "a.py")
            Path(path).write_text("x = 1\n")
            os.utime(path, ns=(1_000_000_000, 1_000_000_000))
            before = freshness._fingerprint(tmp)
            os.utime(path, ns=(2_000_000_000, 2_000_000_000))
            self.assertNotEqual(freshness._fingerprint(tmp), before)
            Path(tmp, "b.py").write_text("")
            self.assertEqual(freshness._fingerprint(tmp)[0], 2)

    # -- batch color / effect: one pass per spine clip -------------------------------
    def _batch_bridge(self, detailed_state, *, fail_select_handle=None):
        def respond(method, params):
            if method == "timeline.getDetailedState":
                return detailed_state
            if method in ("timeline.beginEdit", "timeline.endEdit"):
                return {"status": "ok"}
            if method == "timeline.selectItems":
                handle = (params.get("handles") or [None])[0]
                if fail_select_handle and handle == fail_select_handle:
                    return {"error": f"select failed for {handle}"}
                return {"status": "ok", "matchesRequest": True, "selected": [{"handle": handle}]}
            if method == "timeline.action":
                return {"status": "ok", "action": params.get("action")}
            if method == "effects.apply":
                return {"status": "ok", "effect": params.get("name") or params.get("effectID")}
            return {"status": "ok"}

        return FakeBridge(self.module, respond)

    def _batch_applied_total(self, text: str) -> tuple[int, int]:
        m = re.search(r":\s*(\d+)\s+of\s+(\d+)\s+clip", text)
        self.assertIsNotNone(m, text)
        return int(m.group(1)), int(m.group(2))

    @staticmethod
    def _batch_handles(text: str) -> list[str]:
        return re.findall(r"\[(?:ok|FAILED)\] (obj_\w+)", text)

    def test_batch_loops_iterate_actual_clips_and_never_repeat_one(self):
        m = self.module

        # (a) playhead at timeline start -> all three clips, once each
        with self._batch_bridge(three_clip_detailed_state(0.0)) as fake:
            calls = fake.calls
            out = m.batch_color_correct(correction="addColorBoard", clip_count=0)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 3)
            self.assertEqual(applied, 3)
            handles = self._batch_handles(out)
            self.assertEqual(handles, ["obj_a", "obj_b", "obj_c"])
            self.assertEqual(len(set(handles)), 3)
            action_calls = [p for meth, p in calls if meth == "timeline.action"]
            self.assertEqual(len(action_calls), 3)
            self.assertTrue(all(p.get("action") == "addColorBoard" for p in action_calls))

        # (b) playhead inside second clip -> second and third only
        with self._batch_bridge(three_clip_detailed_state(15.0)):
            out = m.batch_color_correct(correction="addColorBoard", clip_count=0)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 2)
            self.assertEqual(self._batch_handles(out), ["obj_b", "obj_c"])

        # (c) clip_count limits to first target only
        with self._batch_bridge(three_clip_detailed_state(0.0)):
            out = m.batch_color_correct(correction="addColorBoard", clip_count=1)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 1)
            self.assertEqual(self._batch_handles(out), ["obj_a"])

        # (d) gap and transition on the spine are skipped
        spine = [
            media_spine_item(0, "A", "obj_a", 0, 8),
            {
                "index": 1,
                "class": "FFAnchoredGap",
                "name": "Gap",
                "handle": "obj_gap",
                "startTime": cmtime(8),
                "endTime": cmtime(9),
            },
            {
                "index": 2,
                "class": "FFAnchoredTransition",
                "name": "Cross Dissolve",
                "handle": "obj_xfade",
                "startTime": cmtime(8.5),
                "endTime": cmtime(9.5),
            },
            media_spine_item(3, "B", "obj_b", 9, 18),
        ]
        with self._batch_bridge(three_clip_detailed_state(0.0, items=spine)):
            out = m.batch_apply_effect(name="Gaussian Blur", clip_count=0)
            result_handles = self._batch_handles(out)
            self.assertEqual(result_handles, ["obj_a", "obj_b"])
            self.assertNotIn("obj_gap", result_handles)
            self.assertNotIn("obj_xfade", result_handles)

        # (e) exactly one undo group; endEdit even when a clip fails
        with self._batch_bridge(
            three_clip_detailed_state(0.0),
            fail_select_handle="obj_b",
        ) as fake:
            calls = fake.calls
            out = m.batch_color_correct(correction="addColorBoard", clip_count=0)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 3)
            self.assertEqual(applied, 2)
            self.assertIn("[FAILED] obj_b", out)
            begin_idxs = [i for i, (meth, _) in enumerate(calls) if meth == "timeline.beginEdit"]
            end_idxs = [i for i, (meth, _) in enumerate(calls) if meth == "timeline.endEdit"]
            self.assertEqual(len(begin_idxs), 1)
            self.assertEqual(len(end_idxs), 1)
            first_work = next(
                i for i, (meth, _) in enumerate(calls)
                if meth in ("timeline.selectItems", "timeline.action", "effects.apply")
            )
            last_work = max(
                i for i, (meth, _) in enumerate(calls)
                if meth in ("timeline.selectItems", "timeline.action", "effects.apply")
            )
            self.assertLess(begin_idxs[0], first_work)
            self.assertGreater(end_idxs[0], last_work)

    # -- environment overrides and version -------------------------------------------------
    def test_bridge_address_defaults_and_overrides(self):
        m = self.module
        saved = {k: os.environ.get(k) for k in ("SPLICEKIT_HOST", "SPLICEKIT_PORT", "SPLICEKIT_ALLOW_REMOTE")}

        def restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)

        for k in saved:
            os.environ.pop(k, None)
        self.assertEqual(m._bridge_address(), ("127.0.0.1", 9876))
        os.environ["SPLICEKIT_PORT"] = "not-a-number"
        self.assertEqual(m._bridge_address(), ("127.0.0.1", 9876))
        os.environ["SPLICEKIT_PORT"] = "9877"
        os.environ["SPLICEKIT_HOST"] = "10.0.0.5"
        self.assertEqual(m._bridge_address(), ("127.0.0.1", 9877), "non-loopback host refused by default")
        os.environ["SPLICEKIT_ALLOW_REMOTE"] = "1"
        self.assertEqual(m._bridge_address(), ("10.0.0.5", 9877))

    def test_reported_version_matches_version_file(self):
        m = self.module
        expected = (Path(__file__).resolve().parents[1] / "VERSION").read_text().strip()
        self.assertTrue(expected)
        self.assertEqual(m.SPLICEKIT_VERSION, expected)
        self.assertEqual(m.mcp.version, expected)

    def test_plugin_reload_does_not_register_the_same_tool_twice(self):
        m = self.module
        answer = {"methods": [{"name": "com.example.demo.greet", "description": "Say hi", "readOnly": True}]}
        with FakeBridge(m, answer):
            before = len(m.mcp.tools)
            first = m._register_plugin_tools()
            second = m._register_plugin_tools()
        self.assertEqual(first, 1)
        self.assertEqual(second, 0)
        self.assertEqual(len(m.mcp.tools), before + 1)
        self.assertIn("plugin_com_example_demo_greet", m._registered_plugin_tools)


if __name__ == "__main__":
    unittest.main()
