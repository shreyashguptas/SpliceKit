#!/usr/bin/env python3
"""Offline tests for get_audio_levels (timeline.getAudioLevels): argument validation, the
parameters sent to the bridge, the text rendering (summary, neighbours, cuts, skipped,
sparklines, full detail) and the pure-Python waveform PNG. Runs without the mcp package
through the shared fake loader, so the image is checked by decoding the PNG bytes, not by
the SDK. The fixtures mirror the shapes Sources/SpliceKitAudioLevels.m emits."""
import json
import struct
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402


def _clip(handle, name, start, end, lane=0, connected=False, n=40, tail_silent=False, clipped=False,
          role=None, retimed="unknown"):
    rms = [-20.0 + (i % 5) for i in range(n)]
    peak = [v + 8.0 for v in rms]
    if tail_silent:
        rms[-6:] = [-80.0] * 6
        peak[-6:] = [-70.0] * 6
    if clipped:
        peak[3] = 0.0
    slice_s = (end - start) / n
    out = {
        "handle": handle, "name": name, "class": "FFAnchoredMediaComponent", "connected": connected,
        "lane": lane, "index": 0, "kind": "video clip", "startSeconds": start, "endSeconds": end,
        "durationSeconds": end - start, "retimed": retimed,
        "source": {"path": f"/Volumes/Media/{name}.mov", "fileName": f"{name}.mov", "representation": "original",
                   "fileStart": 3.0, "fileEnd": 3.0 + (end - start), "sourceStart": 3603.0, "mediaOrigin": 3600.0},
        "analysisRange": {"startSeconds": start, "endSeconds": end},
        "audio": {"sampleRate": 48000, "channels": 2, "channelsMode": "pooled", "audioTrackCount": 1,
                  "tracksDecoded": 1, "videoFrameRate": 24.0, "fileDuration": 120.0, "sliceSeconds": slice_s,
                  "sliceCount": n},
        "stats": {"maxPeakDb": max(peak), "maxPeakAtSeconds": start + 0.5, "meanRmsDb": -18.5,
                  "clippedSlices": 1 if clipped else 0, "silentSlices": 6 if tail_silent else 0,
                  "allSilent": False, "headSilenceSeconds": 0.0,
                  "tailSilenceSeconds": round(6 * slice_s, 3) if tail_silent else 0.0,
                  "headRmsDb": -20.0, "headPeakDb": -12.0,
                  "tailRmsDb": -80.0 if tail_silent else -19.0, "tailPeakDb": -70.0 if tail_silent else -11.0,
                  "edgeSeconds": 0.1},
    }
    if role:
        out["role"] = role          # neighbours carry no slices (summary only)
    else:
        out["slices"] = {"startSeconds": start, "sliceSeconds": slice_s, "count": n, "peakDb": peak, "rmsDb": rms,
                         "clippedSliceIndices": [3] if clipped else []}
    return out


def _cut():
    return {"atSeconds": 2.0,
            "outgoing": {"handle": "obj_1", "name": "Interview A", "tailRmsDb": -80.0, "tailPeakDb": -70.0,
                         "tailSilenceSeconds": 0.3},
            "incoming": {"handle": "obj_2", "name": "B-roll", "headRmsDb": -20.0, "headPeakDb": -12.0,
                         "headSilenceSeconds": 0.0},
            "jumpDb": 60.0, "outgoingEndsInSilence": True, "incomingStartsInSilence": False}


def _response(**overrides):
    out = {
        "status": "ok", "floorDb": -100.0, "sliceSeconds": 0.05, "silenceDb": -50.0, "edgeSeconds": 0.1,
        "perChannel": False, "helper": "/x/audio-levels",
        "timeline": {"frameRate": 24.0, "durationSeconds": 6.0},
        "clipCount": 5, "analyzedCount": 3, "neighborCount": 0, "outsideRangeCount": 0,
        "clips": [
            _clip("obj_1", "Interview A", 0.0, 2.0, tail_silent=True),
            _clip("obj_2", "B-roll", 2.0, 4.0, clipped=True),
            _clip("obj_3", "Music", 0.5, 3.5, lane=-1, connected=True),
            {"handle": "obj_5", "name": "Nested", "class": "FFAnchoredCollection", "connected": False, "lane": 0,
             "startSeconds": 4.0, "endSeconds": 6.0, "durationSeconds": 2.0, "kind": "compound clip",
             "skipped": "compound clip: no single source media file (open it to analyse the clips inside)"},
        ],
        "cuts": [_cut()],
        "skipped": [{"handle": "obj_4", "name": "Title", "reason": "no audio"},
                    {"handle": "obj_9", "name": "Cross Dissolve", "reason": "transition (no source media of its own)"}],
        "elapsedSeconds": 0.4,
    }
    out.update(overrides)
    return out


def _png_dims(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG signature"
    assert data[12:16] == b"IHDR"
    width, height, depth, ctype = struct.unpack(">IIBB", data[16:26])
    return width, height, depth, ctype


def _png_pixels(data: bytes):
    """Decode a filter-0 RGB PNG written by the server into (width, height, rows)."""
    width, height, depth, ctype = _png_dims(data)
    assert (depth, ctype) == (8, 2)
    pos = 8
    idat = b""
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        assert crc == zlib.crc32(tag + body) & 0xFFFFFFFF, f"bad CRC in {tag!r}"
        if tag == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 3
    rows = []
    for y in range(height):
        assert raw[y * (stride + 1)] == 0, "unexpected filter byte"
        rows.append(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    return width, height, rows


ROW_H, GUTTER, TOP = 88, 4, 14
RMS_COL, PEAK_COL, RED, WHITE, BASELINE, ROW_BG = (142, 197, 255), (74, 127, 181), (255, 69, 58), (255, 255, 255), (70, 70, 74), (36, 36, 38)


class GetAudioLevelsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def setUp(self):
        self.calls = []
        self.response = _response()
        m = self.module
        self._original = m.bridge.call

        def fake_call(method, params_dict=None, timeout=None, **params):
            merged = dict(params_dict or {})
            merged.update(params)
            self.calls.append((method, merged, timeout))
            return self.response
        m.bridge.call = fake_call

    def tearDown(self):
        self.module.bridge.call = self._original

    def _run(self, **kwargs):
        return self.tools["get_audio_levels"]["func"](**kwargs)

    # -- registration -----------------------------------------------------------------
    def test_registered_read_only_and_unannotated_return(self):
        tool = self.tools["get_audio_levels"]
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertFalse(tool["annotations"]["destructiveHint"])
        self.assertFalse(tool["annotations"]["openWorldHint"])
        # Image-returning tools carry no return annotation (the SDK only emits mixed
        # text + image content for unannotated tools).
        self.assertNotIn("return", getattr(tool["func"], "__annotations__", {}))
        self.assertIn("get_audio_levels", self.module.mcp.instructions)
        self.assertIn("neighbours come along", self.module.mcp.instructions)
        doc = tool["func"].__doc__
        for phrase in ("NOT Final Cut Pro's audio meters", "at most the first 100", "normal speed (100%)",
                       "possible clipping", "attached (not when it is expanded or detached)", "SpliceKit's own"):
            self.assertIn(phrase, doc)

    # -- validation ---------------------------------------------------------------------
    def test_rejects_bad_arguments_without_calling_the_bridge(self):
        cases = [
            dict(channels="stereo"), dict(detail="everything"), dict(slice_ms=1), dict(slice_ms=9999),
            dict(edge_ms=1), dict(image_width=10), dict(max_slices_per_clip=1), dict(silence_db=5.0),
            dict(start_seconds=float("nan")), dict(start_seconds=5.0, end_seconds=5.0),
            dict(end_seconds=float("inf")), dict(slice_ms="fifty"),
            dict(handles=[]), dict(handles=[None, ""]), dict(handle="obj_1", handles=["obj_2"]),
        ]
        for kwargs in cases:
            with self.subTest(kwargs=kwargs):
                out = self._run(**kwargs)
                self.assertIsInstance(out, str)
                self.assertTrue(out.startswith("Error:"), out)
        self.assertEqual(self.calls, [])

    # -- parameters sent to the bridge ---------------------------------------------------
    def test_single_handle_parameters_and_timeout(self):
        self._run(handle="obj_1", slice_ms=20, channels="separate", edge_ms=250, silence_db=-40.0,
                  max_slices_per_clip=100)
        method, params, timeout = self.calls[0]
        self.assertEqual(method, "timeline.getAudioLevels")
        self.assertEqual(params["handle"], "obj_1")
        self.assertNotIn("handles", params)
        self.assertAlmostEqual(params["sliceSeconds"], 0.02)
        self.assertAlmostEqual(params["edgeSeconds"], 0.25)
        self.assertEqual(params["silenceDb"], -40.0)
        self.assertTrue(params["perChannel"])
        self.assertEqual(params["maxSlicesPerClip"], 100)
        self.assertTrue(params["includeSlices"])
        self.assertEqual(timeout, 180.0)

    def test_range_and_handles_parameters(self):
        self._run(handles=["obj_1", "obj_2"], start_seconds=1.0, end_seconds=3.5)
        _, params, timeout = self.calls[0]
        self.assertEqual(params["handles"], ["obj_1", "obj_2"])
        self.assertEqual(params["startSeconds"], 1.0)
        self.assertEqual(params["endSeconds"], 3.5)
        self.assertFalse(params["perChannel"])
        self.assertEqual(timeout, 600.0)
        self.calls.clear()
        self._run(handles="obj_7")          # a single string is accepted as one handle
        self.assertEqual(self.calls[0][1]["handles"], ["obj_7"])

    def test_bridge_error_is_returned_as_text(self):
        self.response = {"error": "audio-levels helper not found. `make install` builds it"}
        out = self._run(handle="obj_1")
        self.assertIsInstance(out, str)
        self.assertTrue(out.startswith("Error: audio-levels helper not found"))

    # -- rendering ----------------------------------------------------------------------
    def test_summary_text(self):
        text = self._run(include_image=False)
        self.assertIsInstance(text, str)      # no image asked for -> plain text
        self.assertIn("measured by SpliceKit from each clip's source media file", text)
        self.assertIn("Not Final Cut Pro's audio meters", text)
        self.assertIn("NOT applied", text)
        self.assertIn("Slice requested 50 ms (each clip line shows its own)", text)
        self.assertIn("Clips considered: 5; analyzed: 3; skipped: 3; errors: 0.", text)
        self.assertIn('Clip obj_1 "Interview A"  primary storyline  0.000s-2.000s (2.000s)', text)
        self.assertIn("source: Interview A.mov (original) file 3.000s-5.000s; 48000 Hz, 2 ch pooled, "
                      "40 slices of 50 ms", text)
        # channels are pooled, never mixed, and the header says what that means (QA run 3: the
        # earlier mono mixdown read +3 dB on dual-mono files)
        self.assertIn("Channels are pooled, not mixed: a slice's peak is the loudest sample in any channel", text)
        self.assertNotIn("ch mixdownMono", text)     # no clip fell back to the mixdown
        self.assertIn("end: 0.300s below threshold, last window RMS -80.0 dB (peak -70.0 dB); window 100 ms", text)
        self.assertIn("slices at full scale (peak >= -0.1 dBFS) 1", text)
        self.assertIn('Clip obj_3 "Music"  lane -1 (connected clip)', text)
        self.assertIn('Clip obj_5 "Nested"  primary storyline  4.000s-6.000s (2.000s)\n  skipped: compound clip:', text)
        # the retime flag is unknown in the fixture, and the reader is told so
        self.assertIn("retimed: unknown (no retime flag found", text)
        # cuts
        self.assertIn("Cuts between analysed primary-storyline clips", text)
        self.assertIn('2.000s  "Interview A" end -80.0 dB -> "B-roll" start -20.0 dB  jump +60.0 dB  '
                      '(outgoing ends below the silence threshold)', text)
        # skipped list from the bridge (titles land here: no audio)
        self.assertIn('Skipped: obj_4 "Title" (no audio); obj_9 "Cross Dissolve" (transition (no source media of its own))', text)
        # sparklines: one RMS and one peak line per clip with slices, block characters only
        rms_lines = [l for l in text.splitlines() if l.startswith("  RMS  ")]
        self.assertEqual(len(rms_lines), 3)
        for line in rms_lines:
            body = line[len("  RMS  "):]
            self.assertEqual(len(body), 40)   # 40 slices -> 40 columns (fewer than 100)
            self.assertTrue(set(body) <= set(self.module._SPARK_BLOCKS), body)
        self.assertNotIn("slices:", text)
        self.assertIn("SpliceKit's bookkeeping, not FCP terms", text)

    def test_neighbour_rendering_for_a_single_handle(self):
        self.response = _response(clips=[_clip("obj_1", "Interview A", 0.0, 2.0, tail_silent=True),
                                         _clip("obj_2", "B-roll", 2.0, 4.0, role="neighbor")],
                                  clipCount=2, analyzedCount=2, neighborCount=1, skipped=[])
        text = self._run(handle="obj_1", include_image=False)
        self.assertIn("analyzed: 2 (including 1 neighbour of the requested clip, summary only)", text)
        self.assertIn('Neighbour clip obj_2 "B-roll"  primary storyline  2.000s-4.000s (2.000s)  '
                      '[analyzed for the cut comparison; summary only]', text)
        # the neighbour has no slices: exactly one sparkline pair, and the cut is still reported
        self.assertEqual(sum(1 for l in text.splitlines() if l.startswith("  RMS  ")), 1)
        self.assertIn("jump +60.0 dB", text)

    def test_per_channel_figures_and_multi_track_pooling_are_rendered(self):
        r = _response()
        r["perChannel"] = True
        clip = r["clips"][0]
        clip["audio"].update({"channels": 4, "audioTrackCount": 2, "tracksDecoded": 2})
        clip["slices"]["perChannel"] = [
            {"peakDb": clip["slices"]["peakDb"], "rmsDb": clip["slices"]["rmsDb"],
             "maxPeakDb": -8.0, "meanRmsDb": -18.5, "clippedSlices": 0},
            {"peakDb": clip["slices"]["peakDb"], "rmsDb": clip["slices"]["rmsDb"],
             "maxPeakDb": -11.0, "meanRmsDb": -21.5, "clippedSlices": 2},
        ]
        self.response = r
        text = self._run(channels="separate", include_image=False)
        self.assertIn("4 ch pooled over 2 of 2 audio tracks", text)
        # the pooled summary line stays, and each channel gets its own figures (QA run 3, bug 3)
        self.assertIn("peak max -8.0 dB at 0.500s; RMS mean -18.5 dB; slices at full scale (peak >= -0.1 dBFS) 0", text)
        self.assertIn("ch1: peak max -8.0 dB; RMS mean -18.5 dB; slices at full scale 0", text)
        self.assertIn("ch2: peak max -11.0 dB; RMS mean -21.5 dB; slices at full scale 2", text)
        self.assertIn("ch2 RMS ", text)

    def test_mixdown_fallback_is_named_with_its_caveat(self):
        r = _response()
        r["clips"][0]["audio"].update({"channels": 1, "channelsMode": "mixdownMono"})
        self.response = r
        text = self._run(include_image=False)
        self.assertIn("1 ch mixdownMono (the decoder's mono mixdown, the fallback", text)
        self.assertIn("reads up to 3 dB above the per-channel level when the channels carry the same signal", text)

    def test_errors_are_counted_separately_and_retimed_true_prints_the_note_once(self):
        bad = {"handle": "obj_7", "name": "Broken", "connected": False, "lane": 0, "startSeconds": 6.0,
               "endSeconds": 8.0, "durationSeconds": 2.0, "error": "audio-levels did not finish within 90 s"}
        retimed = _clip("obj_8", "Slow", 8.0, 10.0, retimed=True)
        retimed["note"] = "retimed clip: the levels are mapped assuming normal speed (100%)"
        self.response = _response(clips=[bad, retimed], cuts=[], skipped=[], clipCount=2, analyzedCount=1)
        text = self._run(include_image=False)
        self.assertIn("analyzed: 1; skipped: 0; errors: 1.", text)
        self.assertIn("  error: audio-levels did not finish within 90 s", text)
        self.assertIn("  note: retimed clip: the levels are mapped assuming normal speed (100%)", text)
        self.assertNotIn("retimed: yes", text)      # the note already says it

    def test_full_detail_appends_raw_arrays(self):
        text = self._run(detail="full", include_image=False)
        self.assertIn("  slices: ", text)
        line = next(l for l in text.splitlines() if l.startswith("  slices: "))
        data = json.loads(line[len("  slices: "):])
        self.assertEqual(data["count"], 40)
        self.assertEqual(len(data["peakDb"]), 40)
        self.assertEqual(data["startSeconds"], 0.0)
        self.assertIn("clippedSliceIndices", data)

    def test_transition_and_not_straight_cut_lines(self):
        self.response = _response(cuts=[
            {"atSeconds": 2.0, "outgoing": {"name": "A"}, "incoming": {"name": "B"}, "transition": "Cross Dissolve"},
            {"atSeconds": 4.0, "outgoing": {"name": "B"}, "incoming": {"name": "C"},
             "note": "0.500 s between these clips: not a straight cut"},
        ])
        text = self._run(include_image=False)
        self.assertIn('2.000s  "A" -> "B": transition Cross Dissolve (FCP crossfades attached audio under a transition; '
                      'whether this audio is expanded or detached is not checked)', text)
        self.assertIn('4.000s  "B" -> "C": 0.500 s between these clips: not a straight cut', text)

    def test_range_header_and_partial_analysis_note(self):
        clip = _clip("obj_1", "Interview A", 0.0, 2.0)
        clip["analysisRange"] = {"startSeconds": 0.5, "endSeconds": 2.0}
        self.response = _response(clips=[clip], cuts=[], skipped=[], analyzedCount=1, clipCount=1,
                                  timeline={"frameRate": 24.0, "durationSeconds": 4.0,
                                            "rangeStartSeconds": 0.5, "rangeEndSeconds": 3.0},
                                  outsideRangeCount=2)
        text = self._run(start_seconds=0.5, end_seconds=3.0, include_image=False)
        self.assertIn("requested range 0.500s to 3.000s", text)
        self.assertIn("analyzed: 0.500s-2.000s (the requested range)", text)
        self.assertIn("outside the range: 2", text)

    def test_renderers_survive_hostile_shapes(self):
        m = self.module
        hostile = [
            {"clips": None}, {},
            {"clips": [None, "x", {"handle": "h", "slices": None, "stats": None, "audio": {"sliceSeconds": "x"}}],
             "skipped": [None], "sliceSeconds": "0.05", "edgeSeconds": "0.1", "timeline": {"frameRate": "24"}},
            _response(clips=[dict(_clip("a", "A", 0.0, 1.0), slices={"startSeconds": None, "peakDb": [None, "x", 1.0],
                                                                   "rmsDb": [float("nan"), -20.0]})]),
            _response(clips=[_clip("a", "A", 0.0, 1.0), {"analysisRange": {"startSeconds": None}, "slices": {}, "stats": {}}]),
        ]
        for r in hostile:
            with self.subTest(r=str(r)[:60]):
                self.assertIsInstance(m._render_audio_levels(r, "summary"), str)
                m._render_audio_levels_png(r, 300)      # must not raise
        # NaN never reaches the sparkline
        self.assertEqual(len(m._sparkline([float("nan"), -30.0])), 1)

    # -- the PNG ------------------------------------------------------------------------
    def test_png_is_valid_and_draws_levels_per_lane(self):
        png, legend = self.module._render_audio_levels_png(self.response, 400)
        self.assertIsNotNone(png)
        width, height, rows = _png_pixels(png)
        self.assertEqual((width, height), (400, legend["height"]))
        # lanes with slices: 0 and -1 (the compound clip has none) -> [0, -1]
        self.assertEqual(legend["lanes"], [0, -1])
        self.assertEqual(legend["startSeconds"], 0.0)
        self.assertEqual(legend["endSeconds"], 4.0)
        self.assertEqual(height, TOP + 2 * (ROW_H + GUTTER) + 6)

        def px(x, y):
            return tuple(rows[y][x * 3:x * 3 + 3])

        mid0 = TOP + ROW_H // 2
        x_loud = int(round(1 + 1.0 * (width - 2) / 4.0))        # inside Interview A
        self.assertEqual(px(x_loud, mid0), RMS_COL)
        x_silent = int(round(1 + 1.95 * (width - 2) / 4.0))     # its silent end: baseline, no bar
        self.assertEqual(px(x_silent, mid0), BASELINE)
        # B-roll: the clipped slice index 3 (2.15..2.20 s) gets a red top mark, and only there.
        reds = [x for x in range(int(1 + 2.0 * (width - 2) / 4.0), int(1 + 4.0 * (width - 2) / 4.0))
                if px(x, TOP) == RED]
        self.assertTrue(reds, "expected a red full-scale mark on the B-roll clip")
        for x in reds:
            t = (x - 1) * 4.0 / (width - 2)
            self.assertTrue(2.1 <= t <= 2.25, f"red mark at {t:.3f}s is outside slice 3")
        x_cut = int(round(1 + 2.0 * (width - 2) / 4.0))          # the straight cut: white line
        self.assertEqual(px(x_cut, TOP + 5), WHITE)
        mid1 = TOP + (ROW_H + GUTTER) + ROW_H // 2               # lane -1 row: Music from 0.5 s
        self.assertEqual(px(x_loud, mid1), RMS_COL)
        self.assertEqual(px(2, mid1 - 10), ROW_BG)

    def test_png_span_is_clamped_to_the_analyzed_clips(self):
        r = _response(timeline={"frameRate": 24.0, "durationSeconds": 6.0,
                                "rangeStartSeconds": 1.0, "rangeEndSeconds": 1.0e9})
        png, legend = self.module._render_audio_levels_png(r, 400)
        self.assertIsNotNone(png)
        self.assertEqual(legend["startSeconds"], 1.0)
        self.assertEqual(legend["endSeconds"], 4.0)       # not 1e9: the clips end at 4 s
        self.assertEqual(legend["tickSeconds"], 0.5)

    def test_png_absent_when_nothing_analyzed(self):
        empty = _response(clips=[{"handle": "obj_5", "name": "Nested", "connected": False, "lane": 0,
                                  "startSeconds": 4.0, "endSeconds": 6.0, "durationSeconds": 2.0,
                                  "skipped": "compound clip: no single source media file"}],
                          cuts=[], analyzedCount=0, clipCount=1)
        self.assertEqual(self.module._render_audio_levels_png(empty, 400), (None, None))
        self.response = empty
        out = self._run()
        self.assertIsInstance(out, str)
        self.assertIn("analyzed: 0", out)
        self.assertNotIn("Image (", out)

    def test_image_note_when_sdk_image_helper_is_missing(self):
        # The fake loader has no mcp Image class, so the tool must say the image is not attached
        # (the harness proves the real inline image over the wire).
        out = self._run()
        self.assertIsInstance(out, str)
        self.assertIn("Image (1200x", out)
        self.assertIn("rows top to bottom = primary storyline, lane -1", out)
        self.assertIn("red top marks = peak at full scale", out)
        self.assertIn("image not attached", out)

    def test_sparkline_helper(self):
        spark = self.module._sparkline
        self.assertEqual(spark([]), "")
        self.assertEqual(spark([-100.0]), self.module._SPARK_BLOCKS[0])
        self.assertEqual(spark([0.0]), self.module._SPARK_BLOCKS[7])
        self.assertEqual(spark([-30.0, -30.0]), self.module._SPARK_BLOCKS[4] * 2)
        values = [-60.0] * 400
        values[10] = -1.0
        s = spark(values)
        self.assertEqual(len(s), 100)
        self.assertEqual(s[2], self.module._SPARK_BLOCKS[7])
        self.assertEqual(s[0], self.module._SPARK_BLOCKS[0])


if __name__ == "__main__":
    unittest.main()
