#!/usr/bin/env python3
"""Offline checks for the small tool-output defects found against live FCP.

Covers the parts that do not need Final Cut Pro: the set_inspector_property
docstring names the accepted keys, beat_sync_blade's cut count is the numbered
list it prints, and batch_timeline_actions does not leave a trailing colon on
the undo-group line.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module, set_package_global  # noqa: E402


INSPECTOR_SET_KEYS = (
    "opacity",
    "positionX",
    "positionY",
    "positionZ",
    "scaleX",
    "scaleY",
    "rotation",
    "anchorX",
    "anchorY",
    "volume",
    "handle:",
)


class ReportedNitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()

    def _install_bridge(self, responder):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return responder(method, params)

        self.module.bridge.call = fake_call
        return calls

    def test_set_inspector_property_docstring_lists_keys_not_labels(self):
        doc = " ".join((self.module.set_inspector_property.__doc__ or "").split())
        for key in INSPECTOR_SET_KEYS:
            self.assertIn(key, doc)
        self.assertIn("keys like positionX, not inspector labels like Position X", doc)

    def test_beat_sync_blade_count_matches_numbered_cuts(self):
        # Three blade points plus a song end. The end is not a cut; numbering
        # it used to make the list one longer than "Cuts:".
        analysis = {
            "bpm": 120,
            "beatInterval": 0.5,
            "bars": [1.0, 2.0, 3.0],
            "beats": [],
            "drops": [],
            "structure": [
                {"label": "INTRO", "start": 0.0},
                {"label": "VERSE", "start": 2.0},
            ],
            "duration": 4.0,
        }
        set_package_global(self.module, "_run_structure_analyzer", lambda *args, **kwargs: analysis)
        out = self.module.beat_sync_blade("/tmp/song.wav", dry_run=True)

        numbered = re.findall(r"(?m)^\s+(\d+)\.", out)
        count = int(re.search(r"Cuts: (\d+)", out).group(1))
        self.assertEqual(numbered, ["1", "2", "3"])
        self.assertEqual(count, len(numbered))
        end_lines = [line for line in out.splitlines() if "[end]" in line]
        self.assertEqual(end_lines, ["  end    4.00s  (clip: 1.00s)  [end]"])

    def test_batch_timeline_actions_undo_group_has_no_trailing_colon(self):
        self._install_bridge(lambda method, params: {"status": "ok"})
        out = self.module.batch_timeline_actions(
            '[{"type":"timeline","action":"addMarker"}]'
        )
        self.assertIn("Executed 1 actions:\n", out)
        self.assertIn("\nUndo group: Batch Actions\n", out)
        self.assertNotIn("Batch Actions:", out)

    def test_batch_timeline_actions_without_undo_group_still_introduces_results(self):
        self._install_bridge(lambda method, params: {"status": "ok"})
        out = self.module.batch_timeline_actions(
            '[{"type":"playback","action":"goToStart"}]'
        )
        self.assertTrue(out.startswith("Executed 1 actions:\n"))
        self.assertNotIn("Undo group", out)
        self.assertIn("[0] playback.goToStart -> OK", out)


if __name__ == "__main__":
    unittest.main()
