#!/usr/bin/env python3
"""The FCPXML Final Cut Pro exports, read into OTIO, must still be the timeline.

The fixture is a real export of the QA project: three items on the primary storyline,
the first of them a compound clip holding two clips of its own, plus one connected clip
anchored inside that compound clip on lane 1. 40.040 seconds at 29.97.

Before this, otio-fcpx-xml-adapter 1.0 was the only reader, and a `<ref-clip>` was
swapped for a gap of the same length to stop it crashing: the export reported "1 track,
2 clips", the compound clip and the connected clip were gone, and every clip came back
as a MissingReference, so a re-import produced gaps instead of media.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402

import opentimelineio as otio  # noqa: E402


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "otio_roundtrip" / "qa-timeline.fcpxml"


class OTIORoundTripTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        result = cls.module._otio_read_fcpx_string(FIXTURE.read_text(encoding="utf-8"))
        cls.timeline = cls.module._otio_first_timeline(result)
        cls.summary = cls.module._otio_timeline_summary(cls.timeline)

    def test_every_clip_survives_the_read(self):
        # Three spine items, the first of which is two clips in a compound, plus the
        # connected clip: four on the storyline and one on lane 1.
        self.assertEqual(self.summary["clips"], 5)
        self.assertEqual(self.summary["tracks"], 2)
        self.assertEqual(self.summary["duration_seconds"], 40.04)

    def test_the_compound_clip_is_flattened_and_said_so(self):
        notes = self.summary.get("not_carried_across") or []
        self.assertTrue(any("QA Compound Test" in note for note in notes), notes)
        self.assertTrue(any("flattened" in note for note in notes), notes)

    def test_the_storyline_keeps_its_order_and_lengths(self):
        storyline = self.timeline.tracks[0]
        lengths = [round(item.source_range.duration.value / item.source_range.duration.rate, 3)
                   for item in storyline]
        self.assertEqual(lengths, [10.01, 8.008, 12.012, 10.01])
        self.assertEqual(round(sum(lengths), 3), 40.04)

    def test_the_connected_clip_keeps_its_place(self):
        lane_one = self.timeline.tracks[1]
        leading_gap, clip = list(lane_one)
        self.assertIsInstance(leading_gap, otio.schema.Gap)
        self.assertIsInstance(clip, otio.schema.Clip)
        gap = leading_gap.source_range.duration
        self.assertAlmostEqual(gap.value / gap.rate, 11.979, places=2)
        length = clip.source_range.duration
        self.assertAlmostEqual(length.value / length.rate, 4.505, places=2)

    def test_every_clip_still_points_at_its_media(self):
        # The whole point of the exchange: a MissingReference is a clip the receiving
        # application cannot play.
        for clip in self.timeline.find_clips():
            reference = clip.media_reference
            self.assertIsInstance(reference, otio.schema.ExternalReference,
                                  f"{clip.name} lost its media reference")
            self.assertTrue(reference.target_url.endswith((".mov", ".mp4", ".MP4")),
                            reference.target_url)
            # available_range is what tells Final Cut Pro where the media itself starts;
            # without it the re-import writes start="0s" against a camera file whose
            # timecode begins hours in, and FCP silently drops every clip.
            self.assertIsNotNone(reference.available_range,
                                 f"{clip.name} has no available_range")


# A compound clip can hold another compound clip. Those inner <ref-clip> elements live in
# <resources>, which the flattening pass never walked to, so one used to be copied through
# untouched and then resolved against the asset index — where a <media> id matches no
# <asset> — turning into a clip with a MissingReference while the note still claimed the
# compound clip had been flattened.
NESTED_FCPXML = """<?xml version="1.0" encoding="UTF-8"?>
<fcpxml version="1.10">
  <resources>
    <format id="r1" name="FFVideoFormat1080p2997" frameDuration="1001/30000s"
            width="1920" height="1080"/>
    <asset id="a1" name="A" start="0s" duration="600600/30000s" hasVideo="1" format="r1">
      <media-rep kind="original-media" src="file:///tmp/a.mov"/>
    </asset>
    <asset id="a2" name="B" start="0s" duration="600600/30000s" hasVideo="1" format="r1">
      <media-rep kind="original-media" src="file:///tmp/b.mov"/>
    </asset>
    <media id="m_inner" name="Inner">
      <sequence format="r1" duration="600600/30000s">
        <spine>
          <asset-clip ref="a1" name="A" offset="0s" start="0s" duration="300300/30000s" format="r1"/>
          <asset-clip ref="a2" name="B" offset="300300/30000s" start="0s" duration="300300/30000s" format="r1"/>
        </spine>
      </sequence>
    </media>
    <media id="m_outer" name="Outer">
      <sequence format="r1" duration="600600/30000s">
        <spine>
          <ref-clip ref="m_inner" name="Inner" offset="0s" start="0s" duration="600600/30000s"/>
        </spine>
      </sequence>
    </media>
  </resources>
  <library>
    <event name="E">
      <project name="Nested">
        <sequence format="r1" duration="600600/30000s">
          <spine>
            <ref-clip ref="m_outer" name="Outer" offset="0s" start="0s" duration="600600/30000s"/>
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
"""


class NestedCompoundClipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        result = cls.module._otio_read_fcpx_string(NESTED_FCPXML)
        cls.timeline = cls.module._otio_first_timeline(result)

    def test_a_compound_clip_inside_a_compound_clip_is_flattened_too(self):
        clips = list(self.timeline.find_clips())
        self.assertEqual([c.name for c in clips], ["A", "B"],
                         "the inner compound clip was not flattened")

    def test_the_clips_inside_the_nested_compound_keep_their_media(self):
        for clip in self.timeline.find_clips():
            self.assertIsInstance(
                clip.media_reference, otio.schema.ExternalReference,
                f"{clip.name} came back as a MissingReference: the nested <ref-clip> "
                "was resolved against the asset index instead of being expanded")

    def test_the_nested_flattening_is_reported(self):
        notes = self.timeline.metadata.get("splicekit_notes") or []
        self.assertTrue(any("nested inside another one" in n for n in notes),
                        f"nothing said the nested compound clip was flattened: {notes}")


SELF_NESTED_FCPXML = NESTED_FCPXML.replace(
    '<ref-clip ref="m_inner" name="Inner" offset="0s" start="0s" duration="600600/30000s"/>',
    '<ref-clip ref="m_outer" name="Outer" offset="0s" start="0s" duration="600600/30000s"/>')


# Two compound clips that contain each other. A 2-cycle rather than a direct
# self-reference, which the `_seen` set has to catch just the same.
MUTUAL_FCPXML = NESTED_FCPXML.replace(
    '<ref-clip ref="m_inner" name="Inner" offset="0s" start="0s" duration="600600/30000s"/>',
    '<ref-clip ref="m_outer" name="Outer" offset="0s" start="0s" duration="600600/30000s"/>'
).replace(
    '<media id="m_inner" name="Inner">',
    '<media id="m_inner_unused" name="Inner">')


class SelfNestedCompoundClipTests(unittest.TestCase):
    def _read(self, xml):
        module = load_server_module()
        return module, module._otio_first_timeline(module._otio_read_fcpx_string(xml))

    def test_a_compound_clip_containing_itself_does_not_hang(self):
        # Malformed, but it must not spin forever or blow the stack.
        _, timeline = self._read(SELF_NESTED_FCPXML)
        notes = timeline.metadata.get("splicekit_notes") or []
        self.assertTrue(any("nested inside itself" in n for n in notes),
                        f"the cycle was not reported: {notes}")

    def test_a_cycle_leaves_a_gap_and_never_an_unplayable_clip(self):
        # The note is not enough on its own. Leaving the raw <ref-clip> in the spine
        # produced a Clip whose media_reference was a MissingReference — a clip the
        # receiving application cannot play, with nothing in the clip to say why — while
        # the note alongside it made the read look like it had succeeded.
        for label, xml in (("self-reference", SELF_NESTED_FCPXML),
                           ("mutual reference", MUTUAL_FCPXML)):
            with self.subTest(label):
                _, timeline = self._read(xml)
                for clip in timeline.find_clips():
                    self.assertNotIsInstance(
                        clip.media_reference, otio.schema.MissingReference,
                        f"{label}: {clip.name!r} came back unplayable")
                notes = timeline.metadata.get("splicekit_notes") or []
                self.assertTrue(any("replaced with a gap" in n for n in notes),
                                f"{label}: nothing said a gap was put in its place: {notes}")

    def test_a_cycle_keeps_the_timeline_the_right_length(self):
        # The gap stands in for the compound clip, so the timeline does not shrink.
        _, timeline = self._read(SELF_NESTED_FCPXML)
        duration = timeline.duration()
        self.assertAlmostEqual(duration.value / duration.rate, 20.02, places=2)

    def test_a_compound_clip_whose_contents_are_missing_becomes_a_gap(self):
        # Same treatment when the <media> the ref-clip points at is not in the document
        # at all, which is what a partial or hand-edited FCPXML looks like.
        xml = NESTED_FCPXML.replace('<media id="m_inner" name="Inner">',
                                    '<media id="m_absent" name="Inner">')
        _, timeline = self._read(xml)
        for clip in timeline.find_clips():
            self.assertNotIsInstance(clip.media_reference, otio.schema.MissingReference,
                                     f"{clip.name!r} came back unplayable")
        notes = timeline.metadata.get("splicekit_notes") or []
        self.assertTrue(any("not in this document" in n for n in notes), notes)


if __name__ == "__main__":
    unittest.main()
