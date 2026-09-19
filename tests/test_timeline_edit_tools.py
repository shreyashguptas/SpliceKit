#!/usr/bin/env python3
"""Offline tests for the handle-based edit tools.

Covers select_clips (handle parsing, mode validation, rendering of unresolved /
rejected / mismatch), begin_edit / end_edit forwarding, trim_clip validation and
rendering, the annotations of all four tools, and the timeline markers resource.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402


def _cmtime(seconds, timescale=600):
    return {"value": int(round(seconds * timescale)), "timescale": timescale, "seconds": seconds}


def _select_response(params, **overrides):
    handles = params.get("handles", [])
    selected = [
        {"handle": h, "name": f"Clip {h}", "class": "FFAnchoredMediaComponent", "lane": 0,
         "startTime": _cmtime(6.0), "endTime": _cmtime(12.0)}
        for h in handles
    ]
    out = {
        "status": "ok", "mode": params.get("mode", "replace"),
        "requestedCount": len(handles), "resolvedCount": len(handles),
        "unresolved": [], "rejected": [], "selected": selected,
        "selectedCount": len(selected), "matchesRequest": True, "selector": "setSelectedItems:",
    }
    out.update(overrides)
    return out


def _trim_response(params, dry_run=False):
    before = {"start": 6.0, "end": 12.0, "duration": 6.0}
    delta = params.get("deltaSeconds", -0.5)
    if dry_run:
        return {"dryRun": True, "handle": params["handle"], "name": "Interview B",
                "edge": params["edge"], "requestedDelta": delta, "deltaSeconds": delta,
                "deltaFrames": -12, "before": before,
                "projected": {"start": 6.0, "end": 12.0 + delta, "duration": 6.0 + delta},
                "frameSeconds": 1 / 24, "trimCommand": "ripple"}
    return {"status": "ok", "handle": params["handle"], "name": "Interview B",
            "edge": params["edge"], "requestedDelta": delta, "deltaSeconds": delta,
            "before": before, "after": {"start": 6.0, "end": 12.0 + delta, "duration": 6.0 + delta},
            "appliedDelta": delta, "returnedOK": True, "trimCommand": "ripple"}


class TimelineEditToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}
        cls.resources = {res["uri"]: res for res in cls.module.mcp.resources}

    def _install_bridge(self, responder):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return responder(method, params)

        self.module.bridge.call = fake_call
        return calls

    # ── select_clips ──────────────────────────────────────────────────────

    def test_select_clips_accepts_list_json_and_comma_strings(self):
        calls = self._install_bridge(lambda m, p: _select_response(p))

        out_list = self.module.select_clips(["obj_1", "obj_2"])
        out_json = self.module.select_clips('["obj_1", "obj_2"]', mode="add")
        out_csv = self.module.select_clips("obj_1, obj_2", mode="Remove")

        self.assertEqual(
            calls,
            [
                ("timeline.selectItems", {"handles": ["obj_1", "obj_2"], "mode": "replace"}),
                ("timeline.selectItems", {"handles": ["obj_1", "obj_2"], "mode": "add"}),
                ("timeline.selectItems", {"handles": ["obj_1", "obj_2"], "mode": "remove"}),
            ],
        )
        self.assertIn("Selection (replace): 2 selected", out_list)
        self.assertIn("Selection (add): 2 selected", out_json)
        self.assertIn("Selection (remove): 2 selected", out_csv)
        row = next(line for line in out_list.splitlines() if "obj_2" in line)
        self.assertIn("Clip obj_2", row)
        self.assertIn("6.00s", row)
        self.assertIn("12.00s", row)

    def test_select_clips_rejects_bad_mode_without_calling_bridge(self):
        calls = self._install_bridge(lambda m, p: _select_response(p))
        out = self.module.select_clips(["obj_1"], mode="toggle")
        self.assertTrue(out.startswith("Error:"), out)
        self.assertIn("mode", out)
        self.assertEqual(calls, [])

    def test_select_clips_rejects_bad_json_without_calling_bridge(self):
        calls = self._install_bridge(lambda m, p: _select_response(p))
        out = self.module.select_clips('["obj_1"')
        self.assertTrue(out.startswith("Error:"), out)
        self.assertEqual(calls, [])

    def test_select_clips_empty_handles_forwards_empty_list(self):
        calls = self._install_bridge(lambda m, p: _select_response(p))
        out_default = self.module.select_clips()
        out_empty_str = self.module.select_clips("")
        out_empty_list = self.module.select_clips([])
        self.assertEqual(
            calls,
            [("timeline.selectItems", {"handles": [], "mode": "replace"})] * 3,
        )
        for out in (out_default, out_empty_str, out_empty_list):
            self.assertIn("0 selected", out)
            self.assertIn("deselected all", out)

    def test_select_clips_renders_unresolved_rejected_and_mismatch(self):
        def responder(method, params):
            return _select_response(
                {"handles": ["obj_1"], "mode": "replace"},
                requestedCount=3, resolvedCount=1,
                unresolved=["obj_99"],
                rejected=[{"handle": "obj_20", "reason": "markers cannot be selected as clips"}],
                matchesRequest=False,
            )

        self._install_bridge(responder)
        out = self.module.select_clips(["obj_1", "obj_99", "obj_20"])
        self.assertIn("1/3 handles resolved", out)
        self.assertIn("Unresolved handles", out)
        self.assertIn("obj_99", out)
        self.assertIn("Rejected obj_20: markers cannot be selected as clips", out)
        self.assertIn("WARNING", out)
        self.assertIn("matchesRequest=false", out)

    def test_select_clips_surfaces_bridge_error(self):
        self._install_bridge(lambda m, p: {"error": "No active timeline module"})
        out = self.module.select_clips(["obj_1"])
        self.assertTrue(out.startswith("Error: No active timeline module"), out)

    # ── begin_edit / end_edit ─────────────────────────────────────────────

    def test_begin_and_end_edit_forward_name(self):
        def responder(method, params):
            if method == "timeline.beginEdit":
                return {"status": "ok", "name": params.get("name"),
                        "hadOpenTransaction": False, "hasOpenTransaction": True}
            return {"status": "ok", "name": params.get("name", "Rough cut"), "saved": True,
                    "hadOpenTransaction": True, "hasOpenTransaction": False,
                    "closedWith": "actionEnd:save:error:", "openedWith": "actionBegin:"}

        calls = self._install_bridge(responder)

        out_begin = self.module.begin_edit(name="Rough cut")
        out_end_default = self.module.end_edit()
        out_end_named = self.module.end_edit(name="Rough cut")

        self.assertEqual(
            calls,
            [
                ("timeline.beginEdit", {"name": "Rough cut"}),
                ("timeline.endEdit", {}),
                ("timeline.endEdit", {"name": "Rough cut"}),
            ],
        )
        self.assertIn("Undo step open: Rough cut", out_begin)
        self.assertIn("end_edit()", out_begin)
        self.assertIn("Undo step closed (ok): Rough cut via actionEnd:save:error:", out_end_default)
        self.assertIn("Edit > Undo Rough cut", out_end_named)
        self.assertNotIn("Saved:", out_end_default)

    def test_begin_edit_default_name_and_note(self):
        calls = self._install_bridge(
            lambda m, p: {"status": "ok", "name": p.get("name"),
                          "note": "a transaction was already open; nested begin ignored"})
        out = self.module.begin_edit()
        self.assertEqual(calls, [("timeline.beginEdit", {"name": "Edit"})])
        self.assertIn("Note: a transaction was already open", out)

    def test_end_edit_reports_fcp_error(self):
        self._install_bridge(lambda m, p: {"status": "failed", "name": "Edit", "saved": True,
                                           "closedWith": "actionEnd:save:error:",
                                           "error": "The operation could not be completed"})
        out = self.module.end_edit()
        self.assertIn("Undo step closed (failed)", out)
        self.assertIn("Error reported by FCP: The operation could not be completed", out)

    # ── trim_clip ─────────────────────────────────────────────────────────

    def test_trim_clip_validates_edge_and_delta_exclusivity_without_calling_bridge(self):
        calls = self._install_bridge(lambda m, p: _trim_response(p))

        out_edge = self.module.trim_clip("obj_2", edge="middle", delta_seconds=-0.5)
        out_none = self.module.trim_clip("obj_2", edge="end")
        out_both = self.module.trim_clip("obj_2", edge="end", delta_seconds=-0.5, to_seconds=11.5)
        out_no_handle = self.module.trim_clip("", edge="end", delta_seconds=-0.5)

        self.assertTrue(out_edge.startswith("Error:"), out_edge)
        self.assertIn("edge", out_edge)
        self.assertTrue(out_none.startswith("Error:"), out_none)
        self.assertIn("exactly one", out_none)
        self.assertTrue(out_both.startswith("Error:"), out_both)
        self.assertIn("exactly one", out_both)
        self.assertTrue(out_no_handle.startswith("Error:"), out_no_handle)
        self.assertEqual(calls, [])

    def test_trim_clip_forwards_camel_case_params_and_dry_run(self):
        calls = self._install_bridge(lambda m, p: _trim_response(p, dry_run=p.get("dryRun")))

        out_dry = self.module.trim_clip("obj_2", edge="END", delta_seconds=-0.5, dry_run=True)
        out_to = self.module.trim_clip("obj_2", edge="start", to_seconds=7.0)

        self.assertEqual(
            calls,
            [
                ("timeline.trimClip", {"handle": "obj_2", "edge": "end", "dryRun": True, "deltaSeconds": -0.5}),
                ("timeline.trimClip", {"handle": "obj_2", "edge": "start", "dryRun": False, "toSeconds": 7.0}),
            ],
        )
        self.assertIn("DRY RUN", out_dry)
        self.assertIn("end edit point of 'Interview B' (obj_2)", out_dry)
        self.assertIn("delta: -0.500s (earlier on the timeline, -12 frame(s))", out_dry)
        self.assertIn("before:    6.000s - 12.000s (duration 6.000s)", out_dry)
        self.assertIn("projected: 6.000s - 11.500s (duration 5.500s)", out_dry)
        self.assertIn("Nothing was changed", out_dry)

    def test_trim_clip_renders_before_after_and_applied_delta(self):
        self._install_bridge(lambda m, p: _trim_response(p))
        out = self.module.trim_clip("obj_2", edge="end", delta_seconds=-0.5)
        self.assertIn("Ripple trim OK -- end edit point of 'Interview B' (obj_2)", out)
        self.assertIn("requested: -0.500s, applied: -0.500s", out)
        self.assertIn("before: 6.000s - 12.000s (duration 6.000s)", out)
        self.assertIn("after:  6.000s - 11.500s (duration 5.500s)", out)
        self.assertIn('Undo with timeline_action("undo")', out)

    def test_trim_clip_renders_failed_status_and_error(self):
        def responder(method, params):
            r = _trim_response(params)
            r["status"] = "failed"
            r["after"] = dict(r["before"])
            r["appliedDelta"] = 0.0
            r["error"] = "operationTrimEdit returned NO"
            return r

        self._install_bridge(responder)
        out = self.module.trim_clip("obj_2", edge="end", delta_seconds=-0.5)
        self.assertIn("Ripple trim FAILED", out)
        self.assertIn("applied: +0.000s", out)
        self.assertIn("error: operationTrimEdit returned NO", out)
        self.assertNotIn("Undo with", out)

    def test_trim_clip_surfaces_bridge_error_with_current_range(self):
        self._install_bridge(lambda m, p: {"error": "no-op: requested delta 0.0010s is less than half a frame",
                                           "before": {"start": 6.0, "end": 12.0, "duration": 6.0}})
        out = self.module.trim_clip("obj_2", edge="end", delta_seconds=0.001)
        self.assertTrue(out.startswith("Error: no-op"), out)
        self.assertIn("current: 6.000s - 12.000s", out)

    # ── annotations ───────────────────────────────────────────────────────

    def test_annotations(self):
        for name in ("select_clips", "begin_edit", "end_edit", "trim_clip"):
            self.assertIn(name, self.tools)
            self.assertFalse(self.tools[name]["annotations"]["openWorldHint"], name)

        sel = self.tools["select_clips"]["annotations"]
        self.assertFalse(sel["readOnlyHint"])
        self.assertFalse(sel["destructiveHint"])
        self.assertTrue(sel["idempotentHint"])
        self.assertEqual(sel["title"], "Select Clips")

        for name, title in (("begin_edit", "Begin Undo Step"), ("end_edit", "End Undo Step")):
            ann = self.tools[name]["annotations"]
            self.assertFalse(ann["readOnlyHint"], name)
            self.assertFalse(ann["destructiveHint"], name)
            self.assertEqual(ann["title"], title)

        trim = self.tools["trim_clip"]["annotations"]
        self.assertFalse(trim["readOnlyHint"])
        self.assertTrue(trim["destructiveHint"])
        self.assertEqual(trim["title"], "Trim Clip")
        self.assertIn("trim_clip", self.module.DESTRUCTIVE_TOOLS)
        self.assertIn("select_clips", self.module.IDEMPOTENT_LOCAL_WRITE_TOOLS)

    def test_instructions_mention_handle_targeting(self):
        text = self.module.mcp.instructions
        self.assertIn("Targeting by handle", text)
        self.assertIn("select_clips(", text)
        self.assertIn("begin_edit(", text)
        self.assertIn("trim_clip(", text)

    # ── markers resource ──────────────────────────────────────────────────

    def test_markers_resource_calls_get_markers(self):
        calls = self._install_bridge(
            lambda m, p: {"markers": [{"handle": "obj_20", "kind": "chapter", "name": "Chapter 1"}],
                          "markerCount": 1})
        res = self.resources["splicekit://timeline/markers"]
        out = json.loads(res["func"]())
        self.assertEqual(calls, [("timeline.getMarkers", {})])
        self.assertEqual(out["count"], 1)
        self.assertEqual(out["markers"][0]["handle"], "obj_20")


if __name__ == "__main__":
    unittest.main()
