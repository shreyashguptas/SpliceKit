#!/usr/bin/env python3
"""Offline tests for the per-clip "eyes and ears" tools.

Covers get_clip_info (param forwarding, rendering of every Info-inspector section,
inline image vs text-only), capture_clip_frame (forwarding, playhead restore
rendering), the inline image returned by capture_viewer / capture_timeline /
capture_inspector, the annotations of the new tools, and the absence of a return
annotation on every tool that may return [text, Image] (FastMCP only emits mixed
content for unannotated tools).
"""
import base64
import inspect
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402

# A valid 1x1 PNG; the tools only pass the bytes through, so the pixel format is irrelevant.
TINY_PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJ"
                "RU5ErkJggg==")
TINY_PNG = base64.b64decode(TINY_PNG_B64)


class _StubImage:
    """Stands in for mcp.server.fastmcp.utilities.types.Image (records what it was given)."""

    def __init__(self, path=None, data=None, format=None):
        if path is None and data is None:
            raise ValueError("Either path or data must be provided")
        self.path = path
        self.data = data
        self.format = format


def _cmtime(seconds, timescale=600):
    return {"value": int(round(seconds * timescale)), "timescale": timescale, "seconds": seconds}


def _clip_info_response(params, **overrides):
    out = {
        "handle": params["handle"], "name": "Interview A", "class": "FFAnchoredMediaComponent",
        "kind": "video clip", "onPrimaryStoryline": True, "lane": 0,
        "startTime": _cmtime(0.0), "endTime": _cmtime(6.0), "duration": _cmtime(6.0),
        "timeline": {"start": 0.0, "end": 6.0, "duration": 6.0},
        "enabled": True, "hasVideo": True, "hasAudio": True, "selected": False,
        "roles": {"video": "Video", "audio": "Dialogue"},
        "notes": "Good take",
        "sourceMedia": {
            "path": "/Volumes/Media/interview_a.mov", "fileName": "interview_a.mov", "exists": True,
            "representation": "original", "urlSource": "media.originalMediaURL",
            "sourceStart": 12.5, "sourceStartSelector": "trimStartTime",
            "mediaOrigin": 0.0, "mediaOriginSelector": "unclippedRange",
            "fileStart": 12.5, "fileEnd": 18.5,
        },
        "effects": [{"class": "FFColorBoardEffect", "name": "Color Board",
                     "effectID": "FFColorBoardEffect", "handle": "obj_50"}],
        "effectCount": 1, "effectStackHandle": "obj_49",
        "title": {"text": "Hello", "fontName": "Helvetica-Bold", "fontFamily": "Helvetica",
                  "fontSize": 72, "textColor": "1.000 1.000 1.000 1.000",
                  "channels": [{"text": "Hello", "channelName": "Text"}], "channelCount": 1},
        "markers": [{"handle": "obj_21", "class": "FFAnchoredMarker", "kind": "todo",
                     "name": "Fix audio", "time": _cmtime(1.5), "parentHandle": params["handle"]}],
        "markerCount": 1,
        "transcript": {
            "available": True, "status": "ready", "engine": "parakeet", "wordCount": 3,
            "matchedByHandle": 3, "truncated": False, "speakers": ["Host"],
            "text": "hello there world",
            "words": [{"text": "hello", "startTime": 0.5, "endTime": 0.8, "confidence": 0.9, "speaker": "Host"},
                      {"text": "there", "startTime": 0.9, "endTime": 1.2, "confidence": 0.8, "speaker": "Host"},
                      {"text": "world", "startTime": 1.3, "endTime": 1.7, "confidence": 0.7, "speaker": "Host"}],
        },
        "frame": {"format": "jpeg", "width": 640, "height": 360, "base64": TINY_PNG_B64,
                  "bytes": len(TINY_PNG), "timelineTime": 3.0, "sourceTime": 15.5, "mediaOrigin": 0.0,
                  "fileTime": 15.5, "actualFileTime": 15.5, "source": "media file", "maxWidth": 640},
        "timings": {"mainThreadMs": 4.2, "frameMs": 120.0},
    }
    out.update(overrides)
    return out


def _capture_clip_frame_response(params, **overrides):
    out = {
        "status": "ok", "handle": params["handle"], "name": "Interview A",
        "class": "FFAnchoredMediaComponent", "timelineTime": params.get("frameTime", 3.0),
        "playheadBefore": 10.0, "playheadAtCapture": params.get("frameTime", 3.0),
        "playheadAfter": 10.0, "playheadRestored": True, "restorePlayhead": True,
        "path": f"/tmp/splicekit_clip_{params['handle']}.png",
        "capture": {"width": 1920, "height": 1080, "bytes": 12345, "cropped": True},
        "frame": {"format": "jpeg", "width": 960, "height": 540, "base64": TINY_PNG_B64,
                  "bytes": len(TINY_PNG), "source": "viewer", "maxWidth": 960},
    }
    out.update(overrides)
    return out


class ClipInfoToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def setUp(self):
        # Under the fake FastMCP the real Image class is unavailable; each test picks.
        self.module.Image = _StubImage

    def tearDown(self):
        self.module.Image = None

    def _install_bridge(self, responder):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return responder(method, params)

        self.module.bridge.call = fake_call
        return calls

    # ── get_clip_info ─────────────────────────────────────────────────────

    def test_get_clip_info_forwards_params_and_frame_time_only_when_given(self):
        calls = self._install_bridge(lambda m, p: _clip_info_response(p))
        self.module.get_clip_info("obj_1")
        self.module.get_clip_info("obj_1", include_frame=False, frame_time=2.5, frame_max_width=320)
        self.assertEqual(
            calls,
            [
                ("timeline.getClipInfo", {"handle": "obj_1", "includeFrame": True, "frameMaxWidth": 640}),
                ("timeline.getClipInfo", {"handle": "obj_1", "includeFrame": False, "frameMaxWidth": 320,
                                          "frameTime": 2.5}),
            ],
        )

    def test_get_clip_info_requires_handle_without_calling_bridge(self):
        calls = self._install_bridge(lambda m, p: _clip_info_response(p))
        out = self.module.get_clip_info("")
        self.assertTrue(out.startswith("Error:"), out)
        self.assertEqual(calls, [])

    def test_get_clip_info_renders_every_section_and_returns_image(self):
        self._install_bridge(lambda m, p: _clip_info_response(p))
        out = self.module.get_clip_info("obj_1")
        self.assertIsInstance(out, list)
        self.assertEqual(len(out), 2)
        text, image = out
        self.assertIn("Interview A — video clip on lane 0 (primary storyline), 0.000s–6.000s (6.000s)", text)
        self.assertIn("handle obj_1 (FFAnchoredMediaComponent)", text)
        self.assertIn("roles: video: Video, audio: Dialogue", text)
        self.assertIn("enabled, video+audio", text)
        self.assertIn("source media file: interview_a.mov (exists; media representation: original)", text)
        self.assertIn("path: /Volumes/Media/interview_a.mov", text)
        self.assertIn("start point in the source media: 12.500s; media starts at 0.000s; "
                      "12.500s–18.500s into the media file", text)
        self.assertNotIn("trimStartTime", text)   # selector names stay in the raw RPC only
        self.assertIn("effects: 1: Color Board (FFColorBoardEffect)", text)
        self.assertIn("title text: 'Hello', Helvetica 72pt (1 text layer(s))", text)
        self.assertIn("markers within the clip: 1", text)
        self.assertIn("at 1.500s (timeline) todo Fix audio", text)
        self.assertIn("transcript (SpliceKit Text-Based Editor): 3 word(s) in clip, 0.500s–1.700s timeline "
                      "(status ready, 3 tagged with this handle)", text)
        self.assertIn('"hello there world"', text)
        self.assertIn("speakers: Host", text)
        self.assertIn("per-word times and confidence: get_transcript()", text)
        self.assertIn("notes: Good take", text)
        self.assertIn("frame: 640x360 JPEG at 3.000s (source 15.500s, file 15.500s) from the source media file, no effects", text)
        self.assertIn("timings: main thread 4 ms, frame 120 ms", text)
        self.assertIsInstance(image, _StubImage)
        self.assertEqual(image.data, TINY_PNG)
        self.assertEqual(image.format, "jpeg")
        self.assertIsNone(image.path)

    def test_get_clip_info_text_only_when_image_class_unavailable(self):
        self._install_bridge(lambda m, p: _clip_info_response(p))
        self.module.Image = None
        out = self.module.get_clip_info("obj_1")
        self.assertIsInstance(out, str)
        self.assertIn("frame: 640x360 JPEG", out)
        self.assertIn("frame available as base64 in the raw RPC", out)

    def test_get_clip_info_renders_connected_title_without_media_or_frame(self):
        def responder(method, params):
            r = _clip_info_response(params, kind="title", onPrimaryStoryline=False, lane=1,
                                    hasAudio=False, selected=True, enabled=False,
                                    roles={"video": "Titles"},
                                    frameError="no source media file to read a frame from (title, generator or gap clip); use timeline.captureClipFrame for the Viewer",
                                    transcript={"available": False, "status": "idle", "wordCount": 0,
                                                "matchedByHandle": 0, "words": [], "text": "", "truncated": False})
            r.pop("sourceMedia")
            r.pop("frame")
            r.pop("notes")
            r["sourceMediaError"] = "no source media file: this is a title, generator or gap clip (a clip whose media file is missing still reports its path with exists=false)"
            return r

        self._install_bridge(responder)
        out = self.module.get_clip_info("obj_11")
        self.assertIsInstance(out, str)   # no frame -> no image
        self.assertIn("title on lane 1 (connected clip)", out)
        self.assertIn("roles: video: Titles", out)
        self.assertIn("DISABLED, video, selected", out)
        self.assertIn("source media file: no source media file: this is a title, generator or gap clip", out)
        self.assertIn("transcript: none (SpliceKit Text-Based Editor status: idle; run open_transcript() first; "
                      "this is not FCP's Transcribe to Captions)", out)
        self.assertIn("frame: not available -- no source media file to read a frame from", out)
        self.assertNotIn("notes:", out)

    def test_get_clip_info_renders_container_without_source_file_or_frame(self):
        # QA run 3: a compound (FCP: reference clip) must not be given a source media file or a
        # frame decoded from one; the bridge now answers sourceMediaError + frameError for it.
        def responder(method, params):
            r = _clip_info_response(params, kind="reference clip", containerKind="reference clip",
                                    isReferenceClip=True,
                                    frameError="no single source media file to decode a frame from: this is a "
                                               "reference clip whose contents are clips of their own; "
                                               "timeline.captureClipFrame renders it as the Viewer shows it")
            r.pop("sourceMedia")
            r.pop("frame")
            r["sourceMediaError"] = ("no single source media file: this is a reference clip, whose contents are "
                                     "clips of their own, each with its own media file (Final Cut Pro opens it in "
                                     "its own timeline: select it and timeline_action(\"openClip\")); "
                                     "timeline.captureClipFrame renders it as the Viewer shows it")
            return r

        self._install_bridge(responder)
        out = self.module.get_clip_info("obj_12")
        self.assertIsInstance(out, str)   # no frame -> no image
        self.assertIn("reference clip on lane 0 (primary storyline)", out)
        self.assertIn("source media file: no single source media file: this is a reference clip", out)
        self.assertIn("frame: not available -- no single source media file to decode a frame from", out)
        self.assertNotIn("into the media file", out)
        self.assertNotIn("from the source media file, no effects", out)

    def test_get_clip_info_renders_every_text_layer_and_unknown_range(self):
        def responder(method, params):
            r = _clip_info_response(params, kind="title",
                                    title={"text": "Big Title", "fontFamily": "Helvetica", "fontSize": 72,
                                           "channels": [{"text": "Big Title", "channelName": "Title"},
                                                        {"text": "small words", "channelName": "Subtitle"}],
                                           "channelCount": 2},
                                    timelineRangeError="the clip's absolute timeline range could not be determined (nested connected clip)")
            for key in ("startTime", "endTime", "duration", "timeline", "frame"):
                r.pop(key, None)
            return r

        self._install_bridge(responder)
        out = self.module.get_clip_info("obj_31")
        self.assertIsInstance(out, str)
        self.assertIn("title text: 'Big Title', Helvetica 72pt (2 text layer(s))", out)
        self.assertIn("Title: 'Big Title'", out)
        self.assertIn("Subtitle: 'small words'", out)
        self.assertIn("timeline range: unknown -- the clip's absolute timeline range could not be determined", out)

    def test_get_clip_info_error_passthrough(self):
        self._install_bridge(lambda m, p: {"error": "Handle not found: obj_9 (re-run timeline.getDetailedState)",
                                           "handle": "obj_9"})
        out = self.module.get_clip_info("obj_9")
        self.assertTrue(out.startswith("Error: Handle not found: obj_9"), out)

    # ── capture_clip_frame ────────────────────────────────────────────────

    def test_capture_clip_frame_forwards_params_and_renders_restored_playhead(self):
        calls = self._install_bridge(lambda m, p: _capture_clip_frame_response(p))
        out_default = self.module.capture_clip_frame("obj_1")
        out_custom = self.module.capture_clip_frame("obj_1", frame_time=4.0, frame_max_width=480)
        self.assertEqual(
            calls,
            [
                ("timeline.captureClipFrame", {"handle": "obj_1", "frameMaxWidth": 960}),
                ("timeline.captureClipFrame", {"handle": "obj_1", "frameMaxWidth": 480, "frameTime": 4.0}),
            ],
        )
        self.assertIsInstance(out_default, list)
        text, image = out_default
        self.assertIn("Viewer frame captured for 'Interview A' (obj_1) at 3.000s", text)
        self.assertIn("playhead: 10.000s -> 3.000s at capture -> restored: yes", text)
        self.assertIn("PNG: /tmp/splicekit_clip_obj_1.png", text)
        self.assertIn("frame: 960x540 JPEG as rendered in the Viewer (effects included)", text)
        self.assertNotIn("WARNING", text)
        self.assertEqual(image.data, TINY_PNG)
        self.assertEqual(image.format, "jpeg")
        self.assertIn("at 4.000s", out_custom[0])

    def test_capture_clip_frame_warns_when_playhead_not_restored_and_reports_failure(self):
        self._install_bridge(lambda m, p: _capture_clip_frame_response(p, playheadRestored=False, playheadAfter=3.0))
        out = self.module.capture_clip_frame("obj_1")
        self.assertIn("restored: NO", out[0])
        self.assertIn("WARNING: the playhead was not restored; seek_to_time(10.0)", out[0])

        def failed(method, params):
            r = _capture_clip_frame_response(params, status="failed",
                                             failure="CGWindowListCreateImage returned nil")
            r.pop("frame")
            return r

        self._install_bridge(failed)
        out = self.module.capture_clip_frame("obj_1")
        self.assertIsInstance(out, str)
        self.assertIn("Viewer frame FAILED", out)
        self.assertIn("failure: CGWindowListCreateImage returned nil", out)
        self.assertIn("playhead: 10.000s -> 3.000s at capture -> restored: yes", out)   # diagnostics survive a failure

    def test_capture_clip_frame_flags_full_window_fallback_and_unknown_playhead(self):
        def fallback(method, params):
            r = _capture_clip_frame_response(params)
            r["capture"] = {"width": 2560, "height": 1440, "bytes": 999, "cropped": False}
            return r

        self._install_bridge(fallback)
        text = self.module.capture_clip_frame("obj_1")[0]
        self.assertIn("JPEG of the whole FCP window (the Viewer could not be isolated", text)
        self.assertNotIn("as rendered in the Viewer (effects included)", text)

        def no_before(method, params):
            r = _capture_clip_frame_response(params, playheadRestored=False)
            for key in ("playheadBefore", "playheadAfter"):
                r.pop(key, None)
            return r

        self._install_bridge(no_before)
        text = self.module.capture_clip_frame("obj_1")[0]
        self.assertIn("WARNING: the playhead was moved and its previous position could not be read", text)

    def test_capture_clip_frame_requires_handle_and_passes_errors(self):
        calls = self._install_bridge(lambda m, p: {"error": "No active timeline module"})
        self.assertTrue(self.module.capture_clip_frame("").startswith("Error:"))
        self.assertEqual(calls, [])
        self.assertEqual(self.module.capture_clip_frame("obj_1"), "Error: No active timeline module")

    # ── capture_viewer / capture_timeline / capture_inspector ─────────────

    def test_capture_tools_return_inline_image_when_png_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            png_path = os.path.join(tmp, "viewer.png")
            with open(png_path, "wb") as f:
                f.write(TINY_PNG)
            missing = os.path.join(tmp, "missing.png")

            def responder(method, params):
                return {"status": "ok", "path": params["path"], "width": 1, "height": 1,
                        "bytes": len(TINY_PNG), "matchedClass": "FFInspectorRootStackView"}

            calls = self._install_bridge(responder)
            for tool, method, label in (("capture_viewer", "viewer.capture", "Viewer captured"),
                                        ("capture_timeline", "timeline.capture", "Timeline captured"),
                                        ("capture_inspector", "inspector.capture", "Inspector captured")):
                fn = getattr(self.module, tool)
                out = fn(path=png_path)
                self.assertIsInstance(out, list, tool)
                self.assertIn(f"{label}: {png_path}", out[0])
                self.assertIsInstance(out[1], _StubImage)
                self.assertEqual(out[1].path, png_path)
                self.assertIsNone(out[1].data)

                out_no_image = fn(path=png_path, return_image=False)
                self.assertIsInstance(out_no_image, str, tool)
                self.assertIn(f"{label}: {png_path}", out_no_image)

                out_missing = fn(path=missing)
                self.assertIsInstance(out_missing, str, tool)
                self.assertIn(f"{label}: {missing}", out_missing)
            self.assertEqual([c[0] for c in calls],
                             ["viewer.capture"] * 3 + ["timeline.capture"] * 3 + ["inspector.capture"] * 3)

            self.module.Image = None
            out = self.module.capture_viewer(path=png_path)
            self.assertIsInstance(out, str)
            self.assertIn("Viewer captured", out)

    def test_capture_tools_error_passthrough(self):
        self._install_bridge(lambda m, p: {"error": "No visible FCP window found"})
        for tool in ("capture_viewer", "capture_timeline", "capture_inspector"):
            self.assertEqual(getattr(self.module, tool)(), "Error: No visible FCP window found", tool)

    # ── annotations / signatures ──────────────────────────────────────────

    def test_annotations(self):
        info = self.tools["get_clip_info"]["annotations"]
        self.assertTrue(info["readOnlyHint"])
        self.assertFalse(info["destructiveHint"])
        self.assertTrue(info["idempotentHint"])
        self.assertFalse(info["openWorldHint"])
        self.assertEqual(info["title"], "Get Clip Info")
        self.assertIn("get_clip_info", self.module.READ_ONLY_TOOLS)

        cap = self.tools["capture_clip_frame"]["annotations"]
        self.assertFalse(cap["readOnlyHint"])
        self.assertFalse(cap["destructiveHint"])
        self.assertTrue(cap["idempotentHint"])
        self.assertEqual(cap["title"], "Capture Clip Frame")
        self.assertIn("capture_clip_frame", self.module.IDEMPOTENT_LOCAL_WRITE_TOOLS)

        for name, title in (("capture_viewer", "Capture Viewer"), ("capture_timeline", "Capture Timeline"),
                            ("capture_inspector", "Capture Inspector")):
            self.assertEqual(self.tools[name]["annotations"]["title"], title)

    def test_image_returning_tools_have_no_return_annotation(self):
        for name in ("get_clip_info", "capture_clip_frame", "capture_viewer", "capture_timeline",
                     "capture_inspector"):
            fn = self.tools[name]["func"]
            self.assertIs(inspect.signature(fn).return_annotation, inspect.Signature.empty, name)

    def test_image_helpers(self):
        self.assertIsNone(self.module._image_content())
        self.assertIsNone(self.module._image_content(path="/nonexistent/x.png"))
        self.assertIsNone(self.module._image_content(data=b""))
        img = self.module._image_content(data=b"xx", fmt="jpeg")
        self.assertEqual((img.data, img.format), (b"xx", "jpeg"))
        self.assertEqual(self.module._maybe_with_image("t", None), "t")
        self.assertEqual(self.module._maybe_with_image("t", img), ["t", img])
        self.assertEqual(self.module._decode_base64_image("!!!"), b"")
        self.assertEqual(self.module._decode_base64_image(TINY_PNG_B64), TINY_PNG)

    def test_instructions_mention_clip_info_and_inline_captures(self):
        text = self.module.mcp.instructions
        self.assertIn('get_clip_info("obj_12")', text)
        self.assertIn("inline as image content", text)


if __name__ == "__main__":
    unittest.main()
