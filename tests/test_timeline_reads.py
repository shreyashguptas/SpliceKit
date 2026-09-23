#!/usr/bin/env python3
"""Offline tests for the timeline read tools.

Covers get_timeline_clips (spine + connected clips + markers), list_markers,
get_selected_clips and verify_action against a synthetic bridge payload shaped
like timeline.getDetailedState / timeline.getMarkers responses.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridgeMixin  # noqa: E402
from support.payloads import cmtime, detailed_state, markers_response  # noqa: E402


class TimelineReadToolTests(FakeBridgeMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    # (a) full render + param forwarding
    def test_get_timeline_clips_renders_all_sections_and_forwards_params(self):
        calls = self._install_bridge(lambda method, params: detailed_state())

        out = self.module.get_timeline_clips(limit=50)

        self.assertEqual(
            calls,
            [("timeline.getDetailedState",
              {"limit": 50, "include_connected": True, "include_markers": True})],
        )
        # summary lines
        self.assertIn("Sequence: Demo Edit", out)
        self.assertIn("Items: 2", out)
        self.assertIn("Selected: 2", out)
        self.assertIn("Connected: 2", out)
        self.assertIn("Markers: 2", out)
        # spine rows
        self.assertIn("Interview A", out)
        self.assertIn("obj_2", out)
        # connected rows, sorted by start time (Music Bed @0s before Lower Third @7s)
        self.assertIn("Connected clips (anchored to spine items):", out)
        self.assertIn("Music Bed", out)
        self.assertIn("Lower Third", out)
        self.assertLess(out.index("Music Bed"), out.index("Lower Third"))
        music_row = next(line for line in out.splitlines() if "Music Bed" in line)
        self.assertTrue(music_row.strip().startswith("-1"), music_row)
        self.assertIn("obj_10", music_row)
        title_row = next(line for line in out.splitlines() if "Lower Third" in line)
        self.assertIn("*", title_row)  # selected
        # marker rows, sorted by time (Fix audio @1.5s before Chapter 1 @6s)
        self.assertIn("Markers:", out)
        self.assertLess(out.index("Fix audio"), out.index("Chapter 1"))
        todo_row = next(line for line in out.splitlines() if "Fix audio" in line)
        self.assertIn("todo", todo_row)
        self.assertIn("no", todo_row.split())  # Done column present because `completed` was reported
        self.assertIn("obj_21", todo_row)
        chapter_row = next(line for line in out.splitlines() if "Chapter 1" in line)
        self.assertIn("chapter", chapter_row)
        self.assertIn("obj_20", chapter_row)

    def test_connected_table_prefers_effective_lane_for_nested_anchors(self):
        def responder(method, params):
            state = detailed_state()
            # A title anchored to the connected B-roll: raw lane 1 relative to its
            # parent, effective lane 2 relative to the spine.
            state["connectedItems"].append({
                "class": "FFAnchoredTitle", "name": "Nested Title", "duration": cmtime(2.0),
                "lane": 1, "effectiveLane": 2, "mediaType": 1, "selected": False,
                "handle": "obj_12", "parentHandle": "obj_11", "parentIndex": 1, "depth": 1,
                "relation": "anchored", "hasVideo": True, "hasAudio": False,
                "isConnectedStoryline": False, "isGap": False, "isTransition": False,
                "startTime": cmtime(8.0), "endTime": cmtime(10.0), "timeSource": "effectiveRange",
            })
            state["connectedCount"] = 3
            return state

        self._install_bridge(responder)
        out = self.module.get_timeline_clips()
        nested_row = next(line for line in out.splitlines() if "Nested Title" in line)
        self.assertTrue(nested_row.strip().startswith("2 "), nested_row)
        # Parent column still points at the spine index the chain hangs from
        self.assertIn(" 1 ", nested_row)

    def test_get_timeline_clips_marks_reference_and_compound_clips(self):
        state = detailed_state()
        state["items"][0]["isReferenceClip"] = True
        state["connectedItems"][0]["isCompound"] = True
        self._install_bridge(lambda method, params: state)
        out = self.module.get_timeline_clips()
        spine_line = next(l for l in out.splitlines() if l.startswith("0 ") and "FFAnchored" in l)
        self.assertTrue(spine_line.rstrip().endswith("[reference clip]"), spine_line)
        lower_third = next(l for l in out.splitlines() if "Lower Third" in l)
        self.assertTrue(lower_third.rstrip().endswith("[compound clip]"), lower_third)
        self.assertIn("[reference clip] = FCP's own isReferenceClip flag: a compound clip (verified on 12.3)", out)
        self.assertIn("get_clip_info reports no single source media file for it and get_audio_levels skips it", out)
        # no legend when nothing is a container
        self._install_bridge(lambda method, params: detailed_state())
        self.assertNotIn("[reference clip]", self.module.get_timeline_clips())

    def test_get_timeline_clips_prints_walk_errors_as_warnings(self):
        def responder(method, params):
            state = detailed_state()
            state["connectedItemsError"] = "boom connected"
            state["markersError"] = "boom markers"
            return state

        self._install_bridge(responder)
        out = self.module.get_timeline_clips()
        self.assertIn("WARNING connected clips: boom connected", out)
        self.assertIn("WARNING markers: boom markers", out)

    # (b) opt-out forwards False and omits sections
    def test_get_timeline_clips_can_omit_connected_and_markers(self):
        def responder(method, params):
            state = detailed_state()
            for key in ("connectedItems", "connectedCount", "markers", "markerCount",
                        "markerTotal", "markerSources"):
                state.pop(key, None)
            return state

        calls = self._install_bridge(responder)

        out = self.module.get_timeline_clips(include_connected=False, include_markers=False)

        self.assertEqual(
            calls,
            [("timeline.getDetailedState",
              {"limit": 100, "include_connected": False, "include_markers": False})],
        )
        self.assertIn("Interview A", out)
        self.assertNotIn("Connected", out)
        self.assertNotIn("Markers", out)
        self.assertNotIn("Music Bed", out)
        self.assertNotIn("Chapter 1", out)

    # (c) list_markers forwarding + rendering
    def test_list_markers_forwards_kind_and_renders_table(self):
        calls = self._install_bridge(lambda method, params: markers_response(params.get("kind")))

        out_all = self.module.list_markers()
        out_chapter = self.module.list_markers(kind="chapter")

        self.assertEqual(
            calls,
            [
                ("timeline.getMarkers", {}),
                ("timeline.getMarkers", {"kind": "chapter"}),
            ],
        )
        self.assertIn("Sequence: Demo Edit", out_all)
        self.assertIn("Markers: 2", out_all)
        self.assertIn("Fix audio", out_all)
        self.assertIn("Chapter 1", out_all)
        self.assertIn("obj_20", out_all)
        self.assertLess(out_all.index("Fix audio"), out_all.index("Chapter 1"))
        self.assertIn("Sources: markersInTimeRange=2, anchoredWalk=2", out_all)

        self.assertIn("Markers: 1 (kind=chapter)", out_chapter)
        self.assertIn("Chapter 1", out_chapter)
        self.assertNotIn("Fix audio", out_chapter)

    def test_list_markers_explains_missing_marker_api(self):
        def responder(method, params):
            return {
                "sequenceName": "Demo Edit",
                "markers": [],
                "markerCount": 0,
                "markerSources": {
                    "markersInTimeRange": 0,
                    "anchoredWalk": 0,
                    "sequenceRespondsToMarkersInTimeRange": False,
                },
            }

        self._install_bridge(responder)
        out = self.module.list_markers()
        self.assertIn("does not respond to markersInTimeRange:", out)

    def test_list_markers_surfaces_bridge_error(self):
        self._install_bridge(lambda method, params: {"error": "No active timeline module"})
        out = self.module.list_markers()
        self.assertTrue(out.startswith("Error:"), out)

    # (d) selected connected items
    def test_get_selected_clips_includes_selected_connected_items(self):
        self._install_bridge(lambda method, params: detailed_state())

        out = json.loads(self.module.get_selected_clips())

        self.assertEqual(out["selectedCount"], 2)
        handles = {i["handle"] for i in out["items"]}
        self.assertEqual(handles, {"obj_1", "obj_11"})
        connected = [i for i in out["items"] if i.get("connected")]
        self.assertEqual(len(connected), 1)
        self.assertEqual(connected[0]["handle"], "obj_11")
        spine = [i for i in out["items"] if not i.get("connected")]
        self.assertEqual(spine[0]["handle"], "obj_1")

    # (e) verify_action snapshot
    def test_verify_action_includes_connected_and_marker_counts(self):
        self._install_bridge(lambda method, params: detailed_state())

        out = json.loads(self.module.verify_action("after edit"))

        self.assertEqual(out["item_count"], 2)
        self.assertEqual(out["selected_count"], 2)
        self.assertEqual(out["connected_count"], 2)
        self.assertEqual(out["marker_count"], 2)
        self.assertEqual(out["description"], "after edit")

    # (f) annotations
    def test_list_markers_is_read_only(self):
        self.assertIn("list_markers", self.tools)
        annotations = self.tools["list_markers"]["annotations"]
        self.assertTrue(annotations["readOnlyHint"])
        self.assertFalse(annotations["destructiveHint"])
        self.assertFalse(annotations["openWorldHint"])
        self.assertEqual(annotations["title"], "List Markers")
        self.assertIn("list_markers", self.module.READ_ONLY_TOOLS)


if __name__ == "__main__":
    unittest.main()
