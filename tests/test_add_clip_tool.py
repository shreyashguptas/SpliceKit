#!/usr/bin/env python3
"""Offline tests for add_clip_to_timeline (browser.placeClip): argument validation, the
parameters sent to the bridge, and how the bridge's answer is rendered. Runs without the
mcp package through the shared fake loader."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridgeMixin  # noqa: E402
from support.payloads import placed_response  # noqa: E402


class AddClipToTimelineTests(FakeBridgeMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def setUp(self):
        self.response = placed_response()
        self.calls = self._install_bridge(lambda method, params: self.response)

    def test_registered_with_write_annotations(self):
        tool = self.tools["add_clip_to_timeline"]
        self.assertEqual(tool["annotations"]["title"], "Add Clip To Timeline")
        self.assertFalse(tool["annotations"]["readOnlyHint"])
        # Repo convention: every tool that changes the project is flagged destructive
        # (an insert edit moves every later clip), same as browser_append_clip.
        self.assertTrue(tool["annotations"]["destructiveHint"])
        self.assertEqual(tool["annotations"]["destructiveHint"],
                         self.tools["browser_append_clip"]["annotations"]["destructiveHint"])
        doc = tool["func"].__doc__
        self.assertIn("Edit > Paste", doc)
        self.assertIn("the effect of Insert (W)", doc)
        self.assertIn("Connect to Primary Storyline (Q)", doc)
        self.assertIn("Append to Storyline (E)", doc)
        self.assertIn("FCP has no paste that overwrites", doc)
        self.assertIn("within two frames", doc)
        self.assertIn("pasteboard is replaced", doc)

    def test_sends_fcp_range_target_and_edit_to_the_bridge(self):
        m = self.module
        m.add_clip_to_timeline(handle="obj_5", edit="connect", start_seconds=12, end_seconds=18,
                               at_seconds=45, backtimed=True)
        self.assertEqual(self.calls, [("browser.placeClip", {
            "edit": "connect", "handle": "obj_5", "inSeconds": 12.0, "outSeconds": 18.0,
            "atSeconds": 45.0, "backtimed": True})])

    def test_whole_clip_append_sends_only_the_clip(self):
        m = self.module
        self.response = placed_response("append", source={"startSeconds": 0.0, "endSeconds": 42.0,
                                                           "durationSeconds": 42.0, "wholeClip": True},
                                         target={"playheadBeforeSeconds": 10.0, "storylineEndBeforeSeconds": 30.0,
                                                 "playheadAfterSeconds": 72.0})
        text = m.add_clip_to_timeline(name="Interview", edit="APPEND")
        self.assertEqual(self.calls, [("browser.placeClip", {"edit": "append", "name": "Interview"})])
        self.assertIn("Append edit (the effect of E): verified", text)
        self.assertIn("whole clip, 42.000s of 42.000s", text)
        self.assertIn("Target: end of the primary storyline (was at 30.000s); playhead now 72.000s", text)

    def test_dry_run_is_forwarded_and_rendered_as_a_plan(self):
        m = self.module
        self.response = placed_response(status="dry_run", dryRun=True, placed=None, verified=None,
                                         target={"requestedSeconds": 45.0, "playheadBeforeSeconds": 10.0})
        text = m.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=12, end_seconds=18,
                                      at_seconds=45, dry_run=True)
        self.assertTrue(self.calls[0][1]["dryRun"])
        self.assertTrue(text.startswith("Dry run (nothing changed): insert edit (the effect of W)"))
        self.assertIn("Source: Interview A (obj_5): 12.000s to 18.000s from the clip's first frame, 6.000s of 42.000s", text)
        self.assertIn("Target: playhead will move to 45.000s (now 10.000s)", text)
        self.assertNotIn("moved to", text)
        self.assertNotIn("Placed:", text)
        self.assertNotIn("Undo:", text)

    def test_verified_insert_renders_placed_clip_checks_and_undo(self):
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=12,
                                                end_seconds=18, at_seconds=45)
        self.assertEqual(text.splitlines()[0], "Insert edit (the effect of W): verified")
        self.assertIn("Placed: Interview A (obj_88) primary storyline, 45.000s to 51.000s (6.000s)", text)
        self.assertNotIn("lane 0", text)
        self.assertIn("Range honored: yes; position as requested: yes (within two frames, at least 50 ms)", text)
        self.assertTrue(text.endswith('Undo: history_action("undo")'))

    def test_connected_backtimed_placement_names_the_lane_and_shortcut(self):
        self.response = placed_response("connect", backtimed=True,
                                         placed=[{"handle": "obj_90", "name": "B-roll", "lane": 1, "connected": True,
                                                  "startSeconds": 39.0, "endSeconds": 45.0, "durationSeconds": 6.0}])
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="connect", start_seconds=12,
                                                end_seconds=18, at_seconds=45, backtimed=True)
        self.assertIn("Connect edit (the effect of Q) backtimed (Shift-Q): verified", text)
        self.assertIn("Placed: B-roll (obj_90) lane 1 (connected clip), 39.000s to 45.000s (6.000s)", text)

    def test_unverified_placement_says_so_with_the_bridge_note(self):
        self.response = placed_response(verified=False, rangeHonored=False, positionVerified=True,
                                         note="a clip was placed but its duration or position does not match the request within a frame; compare placed with source/target and undo if needed")
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=12, end_seconds=18)
        self.assertIn("Insert edit (the effect of W): done, NOT verified", text)
        self.assertIn("Range honored: no; position as requested: yes", text)
        self.assertIn("Note: a clip was placed but its duration or position does not match", text)

    def test_nothing_placed_is_reported(self):
        self.response = placed_response(placed=[], placedCount=0, verified=False,
                                         rangeHonored=None, positionVerified=None,
                                         note="the edit ran but no new clip was found on the timeline afterwards; check get_timeline_clips and undo if needed")
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert")
        self.assertIn("Placed: no new clip found on the timeline afterwards", text)
        self.assertIn("Range honored: unknown; position as requested: unknown", text)

    def test_argument_errors_do_not_reach_the_bridge(self):
        m = self.module
        cases = [
            (dict(handle="obj_5", edit="overwrite"), 'FCP has no paste that overwrites. FCP\'s own Overwrite (D) of the browser\'s current selection is timeline_destructive_action("overwriteEdit")'),
            (dict(handle="obj_5", edit="replace"), "edit must be append, insert or connect"),
            (dict(edit="insert"), "give the source clip as handle"),
            (dict(handle="obj_5", edit="insert", start_seconds=5, end_seconds=5), "end_seconds (5) must be after start_seconds (5)"),
            (dict(handle="obj_5", edit="append", at_seconds=3), "append edit always adds at the end"),
            (dict(handle="obj_5", edit="insert", backtimed=True), "backtimed is only available for connect edits (Connect to Primary Storyline - Backtimed, Shift-Q)"),
        ]
        for kwargs, expected in cases:
            text = m.add_clip_to_timeline(**kwargs)
            self.assertTrue(text.startswith("Error: "), (kwargs, text))
            self.assertIn(expected, text, kwargs)
        self.assertEqual(self.calls, [])

    def test_other_new_objects_are_listed_separately_from_the_placed_clip(self):
        self.response = placed_response("insert", alsoNew=[
            {"handle": "obj_89", "name": "Interview A", "class": "FFAnchoredMediaComponent", "lane": 0,
             "connected": False, "startSeconds": 51.0, "endSeconds": 80.0, "durationSeconds": 29.0}],
            note="1 other new object(s) on the timeline (alsoNew): the far half of a split clip or a gap Final Cut Pro added")
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=12, end_seconds=18, at_seconds=45)
        self.assertEqual(text.count("Placed:"), 1)
        self.assertIn("Also new on the timeline (not the source clip): 1: Interview A (obj_89) primary storyline 51.000s to 80.000s", text)
        self.assertIn("Note: 1 other new object(s)", text)

    def test_snapped_range_is_marked(self):
        self.response = placed_response("insert", source={"startSeconds": 12.0, "endSeconds": 18.0, "durationSeconds": 6.0,
                                                           "wholeClip": False, "snappedToClipFrames": True})
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=12.01, end_seconds=18.02)
        self.assertIn("from the clip's first frame (snapped to the clip's frames), 6.000s of 42.000s", text)

    def test_explicit_none_for_the_optional_seconds_is_accepted(self):
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=None,
                                                end_seconds=None, at_seconds=None)
        self.assertEqual(self.calls, [("browser.placeClip", {"edit": "insert", "handle": "obj_5"})])
        self.assertIn("verified", text)

    def test_bridge_error_is_returned_as_text(self):
        self.response = {"error": "the range end (50.000s) is beyond the end of the clip, which is 42.000s long"}
        text = self.module.add_clip_to_timeline(handle="obj_5", edit="insert", start_seconds=40, end_seconds=50)
        self.assertEqual(text, "Error: the range end (50.000s) is beyond the end of the clip, which is 42.000s long")


if __name__ == "__main__":
    unittest.main()
