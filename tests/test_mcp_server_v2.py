#!/usr/bin/env python3
"""Unit tests for the behaviour mcp/server.py gained in the move to the mcp 2.x SDK.

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
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import FakeToolError, load_server_module  # noqa: E402


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

    def connect(self, address):
        pass

    def close(self):
        self.closed = True

    def sendall(self, data):
        req = json.loads(data)
        with self.lock:
            self.sent.append(req)
            self._pending.append(req)

    def recv(self, _size):
        import time
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
            @m.splicekit_tool("bridge_status")
            def not_bridge_status():
                return "x"

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
        b.close()  # idempotent

    def test_refused_connection_is_reported_not_raised(self):
        m = self.module
        b = m.BridgeConnection()
        spare = socket.socket()
        spare.bind(("127.0.0.1", 0))
        port = spare.getsockname()[1]
        spare.close()  # nothing listens here now
        old = (m.SPLICEKIT_HOST, m.SPLICEKIT_PORT)
        m.SPLICEKIT_HOST, m.SPLICEKIT_PORT = "127.0.0.1", port
        try:
            r = b.call("system.version")
        finally:
            m.SPLICEKIT_HOST, m.SPLICEKIT_PORT = old
        self.assertIn("Cannot connect to SpliceKit", r["error"])

    # -- batch color / effect: one pass per spine clip -------------------------------
    def _cmtime(self, seconds, timescale=600):
        return {
            "value": int(round(seconds * timescale)),
            "timescale": timescale,
            "seconds": seconds,
        }

    def _media_spine_item(self, index, name, handle, start, end):
        return {
            "index": index,
            "class": "FFAnchoredMediaComponent",
            "name": name,
            "duration": self._cmtime(end - start),
            "lane": 0,
            "mediaType": 1,
            "handle": handle,
            "startTime": self._cmtime(start),
            "endTime": self._cmtime(end),
            "hasVideo": True,
            "hasAudio": True,
        }

    def _three_clip_detailed_state(self, playhead_seconds, items=None):
        if items is None:
            items = [
                self._media_spine_item(0, "A", "obj_a", 0, 10),
                self._media_spine_item(1, "B", "obj_b", 10, 20),
                self._media_spine_item(2, "C", "obj_c", 20, 30),
            ]
        return {
            "sequenceName": "Batch Test",
            "playheadTime": self._cmtime(playhead_seconds),
            "duration": self._cmtime(30),
            "frameRate": 24.0,
            "itemCount": len(items),
            "items": items,
        }

    def _install_batch_bridge(self, detailed_state, *, fail_select_handle=None):
        m = self.module
        calls = []

        def fake_call(method, params_dict=None, timeout=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
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

        original = m.bridge.call
        m.bridge.call = fake_call
        return calls, original

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
        calls, original = self._install_batch_bridge(self._three_clip_detailed_state(0.0))
        try:
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
        finally:
            m.bridge.call = original

        # (b) playhead inside second clip -> second and third only
        calls, original = self._install_batch_bridge(self._three_clip_detailed_state(15.0))
        try:
            out = m.batch_color_correct(correction="addColorBoard", clip_count=0)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 2)
            self.assertEqual(self._batch_handles(out), ["obj_b", "obj_c"])
        finally:
            m.bridge.call = original

        # (c) clip_count limits to first target only
        calls, original = self._install_batch_bridge(self._three_clip_detailed_state(0.0))
        try:
            out = m.batch_color_correct(correction="addColorBoard", clip_count=1)
            applied, total = self._batch_applied_total(out)
            self.assertEqual(total, 1)
            self.assertEqual(self._batch_handles(out), ["obj_a"])
        finally:
            m.bridge.call = original

        # (d) gap and transition on the spine are skipped
        spine = [
            self._media_spine_item(0, "A", "obj_a", 0, 8),
            {
                "index": 1,
                "class": "FFAnchoredGap",
                "name": "Gap",
                "handle": "obj_gap",
                "startTime": self._cmtime(8),
                "endTime": self._cmtime(9),
            },
            {
                "index": 2,
                "class": "FFAnchoredTransition",
                "name": "Cross Dissolve",
                "handle": "obj_xfade",
                "startTime": self._cmtime(8.5),
                "endTime": self._cmtime(9.5),
            },
            self._media_spine_item(3, "B", "obj_b", 9, 18),
        ]
        calls, original = self._install_batch_bridge(self._three_clip_detailed_state(0.0, items=spine))
        try:
            out = m.batch_apply_effect(name="Gaussian Blur", clip_count=0)
            result_handles = self._batch_handles(out)
            self.assertEqual(result_handles, ["obj_a", "obj_b"])
            self.assertNotIn("obj_gap", result_handles)
            self.assertNotIn("obj_xfade", result_handles)
        finally:
            m.bridge.call = original

        # (e) exactly one undo group; endEdit even when a clip fails
        calls, original = self._install_batch_bridge(
            self._three_clip_detailed_state(0.0),
            fail_select_handle="obj_b",
        )
        try:
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
        finally:
            m.bridge.call = original

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
        original = m.bridge.call
        m.bridge.call = lambda method, params_dict=None, timeout=None, **p: {
            "methods": [{"name": "com.example.demo.greet", "description": "Say hi", "readOnly": True}]
        }
        try:
            before = len(m.mcp.tools)
            first = m._register_plugin_tools()
            second = m._register_plugin_tools()
        finally:
            m.bridge.call = original
        self.assertEqual(first, 1)
        self.assertEqual(second, 0)
        self.assertEqual(len(m.mcp.tools), before + 1)
        self.assertIn("plugin_com_example_demo_greet", m._registered_plugin_tools)


if __name__ == "__main__":
    unittest.main()
