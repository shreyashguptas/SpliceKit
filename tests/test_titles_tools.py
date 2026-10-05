#!/usr/bin/env python3
"""Offline checks for the title and generator tools (list_titles, add_title,
get_title_parameters, set_title_parameters): what they send to the bridge, and how
they report its answers."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridgeMixin  # noqa: E402


class TitleToolsTests(FakeBridgeMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()

    def test_add_title_sends_bridge_keys(self):
        calls = self._install_bridge({"status": "ok", "handle": "obj_9", "verified": True, "lane": 2,
                                      "start": 3.0, "end": 7.0, "duration": 4.0, "undoName": "Add Title",
                                      "template": {"name": "Essential Lower Third", "kind": "title",
                                                   "category": "Essential Titles", "theme": "",
                                                   "effectID": "x.moti"}})
        out = self.module.add_title(name="Essential Lower Third", at_seconds=3, duration_seconds=4, lane=2,
                                    text_fields='["Name", {"index": 1, "text": "Role", "color": "#FFD400"}]',
                                    parameters='{"Bar Color": "#1E90FF", "Build In": false}')
        method, params = calls[0]
        self.assertEqual(method, "titles.add")
        self.assertEqual(params["name"], "Essential Lower Third")
        self.assertEqual(params["atSeconds"], 3)
        self.assertEqual(params["durationSeconds"], 4)
        self.assertEqual(params["lane"], 2)
        self.assertEqual(params["textFields"], ["Name", {"index": 1, "text": "Role", "color": "#FFD400"}])
        self.assertEqual(params["parameters"], {"Bar Color": "#1E90FF", "Build In": False})
        self.assertNotIn("dryRun", params)
        self.assertIn("Added: handle obj_9", out)
        self.assertIn("lane 2, 3.000s - 7.000s", out)
        self.assertIn('One undo step ("Add Title")', out)

    def test_add_title_style_keys_and_defaults(self):
        calls = self._install_bridge({"status": "dry_run", "template": {}, "lane": 1})
        out = self.module.add_title(effect_id="x.moti", text="Hello", font="Futura", size=72, bold=True,
                                    color="#FF0000", alignment="center", dry_run=True)
        params = calls[0][1]
        self.assertEqual(params["effectID"], "x.moti")
        for key, value in {"text": "Hello", "font": "Futura", "size": 72, "bold": True,
                           "color": "#FF0000", "alignment": "center", "dryRun": True}.items():
            self.assertEqual(params[key], value, key)
        self.assertNotIn("atSeconds", params)   # the playhead, chosen by the bridge
        self.assertNotIn("lane", params)        # "auto"
        self.assertIn("DRY RUN", out)

    def test_bad_json_is_refused_before_the_bridge(self):
        calls = self._install_bridge({})
        out = self.module.add_title(name="Basic Title", parameters="{not json")
        self.assertTrue(out.startswith("Error: parameters is not valid JSON"))
        out = self.module.set_title_parameters("obj_1", text_fields="[1, 2")
        self.assertTrue(out.startswith("Error: text_fields is not valid JSON"))
        out = self.module.set_title_parameters("obj_1", parameters='["a"]')
        self.assertTrue(out.startswith("Error: parameters must be dict"))
        self.assertEqual(calls, [])

    def test_ambiguous_name_lists_the_candidates(self):
        self._install_bridge({"error": "15 templates match 'Bug'. Pass effect_id, or narrow with category= / theme=.",
                              "candidates": [{"name": "Bug", "category": "Lower Thirds", "theme": "Kinetic",
                                              "kind": "title", "effectID": "k.moti"}]})
        out = self.module.add_title(name="Bug")
        self.assertIn("15 templates match 'Bug'", out)
        self.assertIn("Bug  (Lower Thirds / Kinetic)  effect_id=k.moti", out)

    def test_get_title_parameters_reports_every_kind(self):
        self._install_bridge({
            "kind": "title", "name": "Essential Lower Third", "template": "Essential Lower Third",
            "category": "Essential Titles", "theme": "", "lane": 1, "start": 15.0, "end": 25.0,
            "effectID": "x.moti",
            "textFields": [{"index": 0, "text": "Name Here", "font": "Helvetica", "bold": True, "italic": False,
                            "size": 73, "color": "#FFFFFF", "alignment": "left"}],
            "parameters": [
                {"key": "Title Animation", "kind": "menu", "value": "Fade", "options": ["None", "Fade"]},
                {"key": "Build In", "kind": "checkbox", "value": True},
                {"key": "Bar Opacity", "kind": "number", "value": 0.1, "min": 0, "max": 1},
                {"key": "Graphics HDR Level", "kind": "percent", "value": 95.0, "min": 50, "max": 100},
                {"key": "Drop Shadow Angle", "kind": "angle", "value": 315.0},
                {"key": "Bar Color", "kind": "color", "value": "#FFFFFF"},
                {"key": "Center", "kind": "point", "value": [0.5, 0.5]},
                {"key": "Gradient", "kind": "unsupported", "channelClass": "CHChannelGradient"},
            ]})
        out = self.module.get_title_parameters("obj_5")
        for line in ['[0] "Name Here"  (Helvetica bold, 73 pt, #FFFFFF, left)',
                     "Title Animation: Fade  [menu]  options: None, Fade",
                     "Build In: on  [checkbox]",
                     "Bar Opacity: 0.1  [number, 0..1]",
                     "Graphics HDR Level: 95  [percent, %, 50..100]",
                     "Drop Shadow Angle: 315  [angle, degrees]",
                     "Bar Color: #FFFFFF  [color]",
                     "Center: [0.5, 0.5]  [point]",
                     "Gradient: (CHChannelGradient parameter, not readable or settable here)"]:
            self.assertIn(line, out)

    def test_set_title_parameters_reports_before_and_after(self):
        calls = self._install_bridge({
            "status": "dry_run", "handle": "obj_5",
            "textFields": [{"before": {"index": 0, "text": "Old"}, "after": {"index": 0, "text": "New"}}],
            "parameters": [{"key": "Bar Color", "kind": "color", "before": "#FFFFFF", "requested": "#1E90FF"}]})
        out = self.module.set_title_parameters("obj_5", text="New", parameters={"Bar Color": "#1E90FF"},
                                               dry_run=True)
        self.assertEqual(calls[0], ("titles.setParameters", {"handle": "obj_5", "text": "New", "dryRun": True,
                                                             "parameters": {"Bar Color": "#1E90FF"}}))
        self.assertIn('text [0]: "Old" -> "New"', out)
        self.assertIn("Bar Color: #FFFFFF -> #1E90FF", out)

    def test_list_titles_marks_shared_names(self):
        calls = self._install_bridge({"items": [
            {"kind": "title", "category": "Lower Thirds", "theme": "Kinetic", "name": "Bug",
             "effectID": "k.moti", "nameIsShared": True}], "count": 1})
        out = self.module.list_titles(kind="title", filter="Bug")
        self.assertEqual(calls[0][1], {"kind": "title", "filter": "Bug", "category": "", "theme": ""})
        self.assertIn("Lower Thirds / Kinetic  Bug  effect_id=k.moti  (name shared", out)


if __name__ == "__main__":
    unittest.main()
