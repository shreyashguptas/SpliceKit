#!/usr/bin/env python3
"""Offline tests for get_beat_grid (timeline.getBeatGrid): argument validation, the parameters
sent to the bridge, and the text rendering (tempo, sections, bars with their beats, the pickup,
clips not analysed yet, unsupported clips, json). The fixture mirrors the shape
Sources/Bridge/SpliceKitServerBeatGrid.m emits."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridgeMixin  # noqa: E402
from support.payloads import beat_grid_response  # noqa: E402


class GetBeatGridTests(FakeBridgeMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def setUp(self):
        self.response = None
        self.calls = self._install_bridge(
            lambda method, params: self.response if self.response is not None else beat_grid_response(params))

    def _run(self, **kwargs):
        return self.tools["get_beat_grid"]["func"](**kwargs)

    def test_registered_read_only(self):
        tool = self.tools["get_beat_grid"]
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertFalse(tool["annotations"]["destructiveHint"])
        self.assertIn("get_beat_grid", self.module.mcp.instructions)
        doc = tool["func"].__doc__
        for phrase in ("downbeat", "no per-beat strength", "numbered from the start of the song",
                       "read fresh on", "audio-only clips", "speed ramp"):
            self.assertIn(phrase, doc)

    def test_rejects_bad_arguments_without_calling_the_bridge(self):
        cases = [dict(detail="everything"), dict(start_seconds=float("nan")), dict(end_seconds=float("inf")),
                 dict(start_seconds=5.0, end_seconds=5.0), dict(start_seconds="ten"), dict(handle=7)]
        for kwargs in cases:
            with self.subTest(kwargs=kwargs):
                out = self._run(**kwargs)
                self.assertTrue(out.startswith("Error:"), out)
        self.assertEqual(self.calls, [])

    def test_parameters_sent_to_the_bridge(self):
        self._run()
        self.assertEqual(self.calls[-1], ("timeline.getBeatGrid", {}))
        self._run(handle=" obj_7 ", start_seconds=10, end_seconds=12.5)
        self.assertEqual(self.calls[-1], ("timeline.getBeatGrid",
                                          {"handle": "obj_7", "startSeconds": 10.0, "endSeconds": 12.5}))

    def test_bars_rendering(self):
        out = self._run()
        self.assertIn("Song obj_7 \"Song\"  lane -1 (connected clip)  9.750s-14.000s", out)
        self.assertIn("tempo 120.00 BPM; a beat every 0.500s of the song, varying 0.250-0.500s (tempo drifts)", out)
        self.assertIn("beat grid shown", out)
        self.assertIn("16 beats, 4 bars, 2 sections", out)
        self.assertIn("this clip plays the song from 0.750s to 5.000s", out)
        self.assertIn("section 1  10.000s-12.000s  2.00s, 1 bar from bar 1", out)
        self.assertIn("[on the timeline 12.000s-14.000s]", out)
        self.assertIn("pickup (before bar 1): 9.750", out)
        self.assertRegex(out, r"bar 1\s+S1\s+10\.000 10\.500 11\.000 11\.500")
        self.assertRegex(out, r"bar 2\s+S2\s+12\.000 12\.500 13\.000 13\.500")
        self.assertRegex(out, r"bar 3\s+14\.000")
        self.assertIn("can detect beats on but has not yet", out)
        self.assertIn('obj_9 "Voiceover"  lane -2 (connected clip)', out)
        self.assertIn('select_clips(handles=["obj_9"])', out)
        self.assertIn('timeline_action("enableBeatDetection")', out)

    def test_sections_detail_leaves_out_the_bars(self):
        out = self._run(detail="sections")
        self.assertIn("section 2", out)
        self.assertNotIn("bar 1 ", out)
        self.assertNotIn("pickup", out)

    def test_json_detail_is_the_raw_answer(self):
        out = self._run(detail="json")
        data = json.loads(out)
        self.assertEqual(data["clips"][0]["beats"][1]["level"], "section")
        self.assertEqual(data["clips"][0]["tempo"], 120.0)

    def test_no_song_and_unsupported_clip(self):
        self.response = {"status": "ok", "timeline": {"frameRate": 24.0, "rangeStartSeconds": 3.0}, "clips": [],
                         "detectable": [],
                         "unsupported": [{"handle": "obj_2", "name": "Interview", "lane": 0,
                                          "startSeconds": 0.0, "endSeconds": 6.0, "status": "unsupported",
                                          "reason": "has video: Final Cut Pro only analyses audio-only clips"}]}
        out = self._run(handle="obj_2", start_seconds=3.0)
        self.assertIn("No song on this timeline has a beat map in that range.", out)
        self.assertIn('obj_2 "Interview": no beat map, and Final Cut Pro cannot detect beats on it: has video', out)

    def test_speed_change_is_reported(self):
        self.response = beat_grid_response()
        self.response["clips"][0].update(speed=2.0, timelineTempo=240.0)
        out = self._run()
        self.assertIn("tempo 120.00 BPM at 200% speed = 240.00 BPM on the timeline", out)

    def test_bridge_error_passes_through(self):
        self.response = {"error": "No active timeline module"}
        self.assertEqual(self._run(), "Error: No active timeline module")


if __name__ == "__main__":
    unittest.main()
