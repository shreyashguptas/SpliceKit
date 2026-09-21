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


def _fcpxml(resources_extra, spine_body):
    """A one-project FCPXML with two assets, for the awkward-shape cases below."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<fcpxml version="1.10">
  <resources>
    <format id="r1" name="FFVideoFormat1080p2997" frameDuration="1001/30000s"
            width="1920" height="1080"/>
    <asset id="a1" name="A" start="0s" duration="600600/30000s" hasVideo="1" format="r1">
      <media-rep kind="original-media" src="file:///tmp/a.mov"/>
    </asset>
{resources_extra}
  </resources>
  <library>
    <event name="E">
      <project name="Awkward">
        <sequence format="r1" duration="600600/30000s">
          <spine>
{spine_body}
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
"""


class CompoundClipShapesThatResolveToNothingTests(unittest.TestCase):
    """A <ref-clip> the reader cannot turn into clips must never reach the output.

    Every one of these came back as a Clip with a MissingReference — unplayable, with
    nothing in the clip to say why — because the top-level walk in
    _otio_fcpx_flatten_ref_clips kept its own copies of these checks and they were left
    behind when the nested ones were fixed.
    """

    def _timeline(self, xml):
        module = load_server_module()
        return module, module._otio_first_timeline(module._otio_read_fcpx_string(xml))

    def _assert_all_playable(self, timeline, label):
        for clip in timeline.find_clips():
            self.assertNotIsInstance(
                clip.media_reference, otio.schema.MissingReference,
                f"{label}: {clip.name!r} came back unplayable")

    def test_a_top_level_compound_clip_with_no_media_at_all(self):
        xml = _fcpxml(
            "",
            '            <ref-clip ref="m_absent" name="Bad" offset="0s" start="0s"'
            ' duration="300300/30000s"/>')
        _, timeline = self._timeline(xml)
        self._assert_all_playable(timeline, "missing media")

    def test_a_top_level_compound_clip_whose_media_has_no_sequence(self):
        xml = _fcpxml(
            '    <media id="m_bare" name="Bare"/>',
            '            <ref-clip ref="m_bare" name="Bad" offset="0s" start="0s"'
            ' duration="300300/30000s"/>')
        _, timeline = self._timeline(xml)
        self._assert_all_playable(timeline, "media with no sequence")

    def test_a_top_level_compound_clip_with_an_empty_spine(self):
        xml = _fcpxml(
            '    <media id="m_empty" name="Empty">\n'
            '      <sequence format="r1" duration="300300/30000s"><spine></spine></sequence>\n'
            '    </media>',
            '            <ref-clip ref="m_empty" name="Empty" offset="0s" start="0s"'
            ' duration="300300/30000s"/>')
        _, timeline = self._timeline(xml)
        self._assert_all_playable(timeline, "empty spine")

    def test_a_nested_compound_clip_with_an_empty_spine(self):
        xml = _fcpxml(
            '    <media id="m_empty" name="Empty">\n'
            '      <sequence format="r1" duration="300300/30000s"><spine></spine></sequence>\n'
            '    </media>\n'
            '    <media id="m_outer" name="Outer">\n'
            '      <sequence format="r1" duration="300300/30000s"><spine>\n'
            '        <ref-clip ref="m_empty" name="Empty" offset="0s" start="0s"'
            ' duration="300300/30000s"/>\n'
            '      </spine></sequence>\n'
            '    </media>',
            '            <ref-clip ref="m_outer" name="Outer" offset="0s" start="0s"'
            ' duration="300300/30000s"/>')
        _, timeline = self._timeline(xml)
        self._assert_all_playable(timeline, "nested empty spine")


class GapKeepsAnchoredClipsWhereTheyWereTests(unittest.TestCase):
    def test_an_anchored_clip_on_a_trimmed_compound_clip_does_not_move(self):
        # An anchored child's offset is in its host's local time, and the reader reads it
        # as host_offset + (child_offset - host_start). Replacing the host with a gap whose
        # start is 0, without rebasing the children, pushed every one of them later by
        # exactly the discarded start — which is any compound clip not played from its
        # first frame, i.e. the ordinary case.
        start = "50050/30000s"      # 1.668s into the compound clip
        child_offset = "55055/30000s"  # 0.167s past that, so 0.167s on the timeline
        xml = _fcpxml(
            "",
            f'            <ref-clip ref="m_absent" name="Bad" offset="0s" start="{start}"'
            f' duration="200200/30000s">\n'
            f'              <asset-clip ref="a1" lane="1" name="Anchored"'
            f' offset="{child_offset}" start="0s" duration="30030/30000s" format="r1"/>\n'
            f'            </ref-clip>')
        module = load_server_module()
        timeline = module._otio_first_timeline(module._otio_read_fcpx_string(xml))

        anchored = [c for c in timeline.find_clips() if c.name == "Anchored"]
        self.assertEqual(len(anchored), 1, "the anchored clip did not survive the gap")
        lane = [t for t in timeline.tracks if any(c.name == "Anchored"
                                                 for c in t.find_clips())][0]
        at = 0.0
        for item in lane:
            if getattr(item, "name", None) == "Anchored":
                break
            d = item.source_range.duration
            at += d.value / d.rate
        self.assertAlmostEqual(at, 0.167, places=2,
                               msg=f"the anchored clip moved to {at:.3f}s; the host's "
                                   "start was dropped without rebasing it")


class ConnectedCompoundClipTests(unittest.TestCase):
    """A compound clip does not have to sit in the spine.

    Connect one to a clip — B-roll, an insert, a titled sequence — and it hangs off its
    host on a lane. The flattening walk only ever looked at the direct children of a
    <spine>, so it never reached those: the raw <ref-clip> went to the reader, which
    resolves `ref` against the asset index, where a <media> id matches no <asset>. It came
    back as an unplayable clip with no note beside it, even when its contents were good.
    """

    def _timeline(self, xml):
        module = load_server_module()
        return module._otio_first_timeline(module._otio_read_fcpx_string(xml))

    def test_a_connected_compound_clip_with_good_media_is_flattened(self):
        xml = _fcpxml(
            '    <asset id="a2" name="B" start="0s" duration="600600/30000s" hasVideo="1"'
            ' format="r1">\n'
            '      <media-rep kind="original-media" src="file:///tmp/b.mov"/>\n'
            '    </asset>\n'
            '    <media id="m_real" name="Real">\n'
            '      <sequence format="r1" duration="120120/30000s"><spine>\n'
            '        <asset-clip ref="a2" name="Inside" offset="0s" start="0s"'
            ' duration="120120/30000s" format="r1"/>\n'
            '      </spine></sequence>\n'
            '    </media>',
            '            <asset-clip ref="a1" name="Main" offset="0s" start="0s"'
            ' duration="300300/30000s" format="r1">\n'
            '              <ref-clip ref="m_real" name="AnchoredCompound" lane="1"'
            ' offset="90090/30000s" start="0s" duration="120120/30000s"/>\n'
            '            </asset-clip>')
        timeline = self._timeline(xml)
        names = [c.name for c in timeline.find_clips()]
        self.assertIn("Inside", names,
                      f"the connected compound clip was not flattened: {names}")
        for clip in timeline.find_clips():
            self.assertNotIsInstance(clip.media_reference, otio.schema.MissingReference,
                                     f"{clip.name!r} came back unplayable")

    def test_a_connected_compound_clip_with_no_media_becomes_a_gap(self):
        xml = _fcpxml(
            "",
            '            <asset-clip ref="a1" name="Main" offset="0s" start="0s"'
            ' duration="300300/30000s" format="r1">\n'
            '              <ref-clip ref="m_absent" name="AnchoredCompound" lane="1"'
            ' offset="90090/30000s" start="0s" duration="120120/30000s"/>\n'
            '            </asset-clip>')
        timeline = self._timeline(xml)
        for clip in timeline.find_clips():
            self.assertNotIsInstance(clip.media_reference, otio.schema.MissingReference,
                                     f"{clip.name!r} came back unplayable")


class GapRebasesItsAnchoredChildrenTests(unittest.TestCase):
    """The arithmetic in _otio_fcpx_ref_clip_as_gap, on its own.

    Tested directly rather than through a document: routed through a whole read, this is
    masked by whichever earlier branch happens to fire, so a test that looks like it
    covers the rebasing can pass for the wrong reason.
    """

    def test_children_are_rebased_by_the_start_the_gap_discards(self):
        import xml.etree.ElementTree as ET
        module = load_server_module()
        # The reader places an anchored child at host_offset + (child_offset - host_start).
        # The gap is written with start="0s", so each child's offset has to lose the
        # host's start for the child to stay where it was.
        for ref_offset, ref_start, child_offset in (("10s", "5s", "7s"),
                                                    ("0s", "2s", "3s"),
                                                    ("10s", "5s", "2s")):
            with self.subTest(start=ref_start, child=child_offset):
                ref = ET.Element("ref-clip")
                ref.set("name", "C"); ref.set("offset", ref_offset)
                ref.set("start", ref_start); ref.set("duration", "20s")
                child = ET.SubElement(ref, "asset-clip")
                child.set("lane", "1"); child.set("offset", child_offset)
                child.set("duration", "1s"); child.set("start", "0s")

                before = ET.tostring(ref)
                gap = module._otio_fcpx_ref_clip_as_gap(ref)

                self.assertEqual(ET.tostring(ref), before,
                                 "the original element was mutated")
                self.assertEqual(gap.get("start"), "0s")
                self.assertEqual(gap.get("offset"), ref_offset)
                moved = list(gap)[0]
                landed = (module._otio_fcpx_fraction(gap.get("offset"))
                          + module._otio_fcpx_fraction(moved.get("offset")))
                wanted = (module._otio_fcpx_fraction(ref_offset)
                          + module._otio_fcpx_fraction(child_offset)
                          - module._otio_fcpx_fraction(ref_start))
                self.assertEqual(landed, wanted,
                                 f"the anchored clip moved: {float(landed)}s, "
                                 f"wanted {float(wanted)}s")


# A compound clip connected to something inside itself. The cycle is formed through lane
# anchoring rather than spine nesting, which is the path the spine-side guard never saw:
# reading this used to expand forever and hang the reader outright.
SELF_CONNECTED_FCPXML = """<?xml version="1.0" encoding="UTF-8"?>
<fcpxml version="1.10">
  <resources>
    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
    <asset id="a1" name="A" start="0s" duration="600600/30000s" hasVideo="1" format="r1">
      <media-rep kind="original-media" src="file:///tmp/a.mov"/>
    </asset>
    <media id="m_outer" name="Outer">
      <sequence format="r1" duration="300300/30000s"><spine>
        <asset-clip ref="a1" name="Body" offset="0s" start="0s" duration="300300/30000s" format="r1">
          <ref-clip ref="m_outer" name="SelfConnected" lane="1" offset="30030/30000s"
                    start="0s" duration="60060/30000s"/>
        </asset-clip>
      </spine></sequence>
    </media>
  </resources>
  <library><event name="E"><project name="Hang">
    <sequence format="r1" duration="300300/30000s"><spine>
      <asset-clip ref="a1" name="Main" offset="0s" start="0s" duration="300300/30000s" format="r1">
        <ref-clip ref="m_outer" name="Outer" lane="1" offset="0s" start="0s"
                  duration="300300/30000s"/>
      </asset-clip>
    </spine></sequence>
  </project></event></library>
</fcpxml>
"""


class ConnectedCompoundClipCycleTests(unittest.TestCase):
    def test_a_compound_clip_connected_inside_itself_terminates(self):
        # Bounded in wall-clock, because the failure this guards against is a hang, and a
        # test that hangs tells you nothing and blocks everything behind it.
        import signal

        def _giveup(signum, frame):
            raise AssertionError(
                "reading a compound clip connected inside itself did not finish within "
                "10s — the cycle guard is not reaching the lane-anchored path")

        module = load_server_module()
        previous = signal.signal(signal.SIGALRM, _giveup)
        signal.setitimer(signal.ITIMER_REAL, 10.0)
        try:
            timeline = module._otio_first_timeline(
                module._otio_read_fcpx_string(SELF_CONNECTED_FCPXML))
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

        for clip in timeline.find_clips():
            self.assertNotIsInstance(clip.media_reference, otio.schema.MissingReference,
                                     f"{clip.name!r} came back unplayable")
        notes = timeline.metadata.get("splicekit_notes") or []
        self.assertTrue(any("connected inside itself" in n for n in notes),
                        f"the cycle was not reported: {notes}")
        duration = timeline.duration()
        self.assertAlmostEqual(duration.value / duration.rate, 10.01, places=2)


if __name__ == "__main__":
    unittest.main()
