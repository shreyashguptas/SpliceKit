#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path


# The server module is loaded with the shared fake of the mcp 2.x SDK layout
# (FakeMCPServer / FakeToolAnnotations) so these tests need no mcp package.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402


try:
    import opentimelineio as otio
except ImportError:  # pragma: no cover - exercised via skip
    otio = None


@unittest.skipIf(otio is None, "opentimelineio is required for upstream fixture tests")
class OTIOUpstreamFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.fixture_root = Path(__file__).resolve().parent / "fixtures" / "upstream_otio_fcpxml"
        cls.transitions_fixture = cls.fixture_root / "fcpx_transitions.fcpxml"
        cls.package_fixture = cls.fixture_root / "Test Library.fcpxmld"

    def test_transition_fixture_reads_with_adapter_fallback(self):
        result = self.module._otio_read_fcpx_string(
            self.transitions_fixture.read_text(encoding="utf-8")
        )
        timeline = self.module._otio_first_timeline(result)
        summary = self.module._otio_timeline_summary(timeline)

        transitions = [
            item
            for track in timeline.video_tracks()
            for item in track
            if isinstance(item, otio.schema.Transition)
        ]

        self.assertEqual(summary["name"], "Transitions_Test_Project")
        self.assertEqual(summary["tracks"], 1)
        self.assertEqual(summary["clips"], 3)
        self.assertEqual(summary["duration_seconds"], 30.5)
        self.assertEqual(len(transitions), 2)

    def test_fcpxmld_package_fixture_reads_via_info_entrypoint(self):
        xml = self.module._otio_read_fcpx_document(str(self.package_fixture))
        result = self.module._otio_read_fcpx_string(xml)
        timelines = self.module._otio_all_timelines(result)
        names = [self.module._otio_timeline_summary(timeline)["name"] for timeline in timelines]

        self.assertIn("<fcpxml", xml)
        self.assertEqual(len(timelines), 3)
        self.assertEqual(
            names,
            [
                "1920x1080 23.98p Timeline",
                "1920x1080 25p Timeline",
                "Untitled Project",
            ],
        )


if __name__ == "__main__":
    unittest.main()
