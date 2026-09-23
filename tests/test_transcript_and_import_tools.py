#!/usr/bin/env python3
"""Offline tests for the transcript paging and FCPXML-import-job tools.

Covers open_transcript's forwarding (file URL, primary_storyline_only), get_transcript's
paging / field parameters and rendering (skipped clips, progress, next page), and
import_fcpxml's job flow (path forwarding, polling until done, a job still running when
the wait ends) plus import_fcpxml_status.
"""
import sys
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402


class TranscriptAndImportToolTests(unittest.TestCase):
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

    # ── open_transcript ───────────────────────────────────────────────────

    def test_open_transcript_forwards_file_url_and_primary_only(self):
        calls = self._install_bridge(lambda m, p: {"status": "ok"})
        self.module.open_transcript(file_url="file:///Users/me/a%20b.wav", force_retranscribe=True)
        self.module.open_transcript(primary_storyline_only=True)
        self.module.open_transcript()
        self.assertEqual(calls, [
            ("transcript.open", {"fileURL": "file:///Users/me/a%20b.wav", "forceRetranscribe": True}),
            ("transcript.open", {"primaryStorylineOnly": True}),
            ("transcript.open", {}),
        ])

    # ── get_transcript ────────────────────────────────────────────────────

    def test_get_transcript_forwards_paging_and_fields(self):
        calls = self._install_bridge(lambda m, p: {"status": "ready", "wordCount": 0})
        self.module.get_transcript(start_seconds=60, end_seconds=120, offset=5, limit=50,
                                   fields="text, startTime", words_only=True)
        self.assertEqual(calls, [("transcript.getState", {
            "offset": 5, "limit": 50, "startSeconds": 60.0, "endSeconds": 120.0,
            "fields": ["text", "startTime"], "wordsOnly": True,
            "includeSilences": False, "includeText": False,
        })])

    def test_get_transcript_default_is_one_page_without_panel_text(self):
        calls = self._install_bridge(lambda m, p: {"status": "ready", "wordCount": 0})
        self.module.get_transcript()
        self.assertEqual(calls[0][1], {"offset": 0, "limit": 1000,
                                       "includeSilences": True, "includeText": False})

    def test_get_transcript_renders_skipped_progress_and_next_page(self):
        state = {
            "status": "ready", "wordCount": 3, "silenceCount": 0, "silenceThreshold": 0.3,
            "source": {"mode": "timeline", "primaryStorylineOnly": True},
            "frameRate": None, "frameRateNote": "unknown (no timeline transcribed yet); timecodes use 24 fps",
            "skippedClips": [{"name": "SCREEN", "timelineStart": 5.0, "connected": True,
                              "reason": "no audio track"}],
            "words": [{"index": 0, "text": "Hello", "startTime": 1.0, "endTime": 1.5}],
            "wordsMatched": 3, "wordsOffset": 0, "wordsReturned": 1, "nextOffset": 1,
        }
        self._install_bridge(lambda m, p: state)
        out = self.module.get_transcript(limit=1, fields="text,startTime")
        self.assertIn("Source: timeline (primary storyline only)", out)
        self.assertIn("Frame rate: unknown", out)
        self.assertIn("5.00s [connected] SCREEN: no audio track", out)
        self.assertIn("text='Hello' startTime=1.000", out)
        self.assertIn("More words: get_transcript(offset=1, limit=1)", out)
        self.assertIn("PARTIAL: this answer lists words 0–0 of 3; next page: get_transcript(offset=1)", out)

    def test_get_transcript_progress_line(self):
        self._install_bridge(lambda m, p: {
            "status": "transcribing", "wordCount": 0,
            "progress": {"completed": 1, "total": 4, "fraction": 0.5,
                         "message": "Transcribing 2/4: b.mov...", "elapsedSeconds": 12.5}})
        out = self.module.get_transcript()
        self.assertIn("Progress: 1/4 files, 50% — Transcribing 2/4: b.mov... (12.5s elapsed)", out)

    def test_get_transcript_json_format(self):
        self._install_bridge(lambda m, p: {"status": "ready", "wordCount": 0})
        self.assertEqual(self.module.get_transcript(format="json"), '{"status":"ready","wordCount":0}')

    # ── import_fcpxml ─────────────────────────────────────────────────────

    def test_import_fcpxml_path_polls_job_until_done(self):
        states = iter([{"jobId": "j1", "state": "running"},
                       {"jobId": "j1", "state": "ok", "elapsedSeconds": 1.2,
                        "result": {"library": "/L.fcpbundle", "libraryChosenBy": "<library location> in the XML"}}])

        def responder(method, params):
            if method == "fcpxml.import":
                return {"status": "started", "jobId": "j1"}
            return next(states)

        calls = self._install_bridge(responder)
        with mock.patch.object(self.module.time, "sleep", lambda s: None):
            out = self.module.import_fcpxml(path="~/x.fcpxml", wait_seconds=30)
        self.assertEqual(calls[0], ("fcpxml.import", {"internal": True, "async": True, "path": "~/x.fcpxml"}))
        self.assertEqual([c[0] for c in calls[1:]], ["fcpxml.importStatus", "fcpxml.importStatus"])
        self.assertIn("Import job j1: ok after 1.2s", out)
        self.assertIn("library: /L.fcpbundle (chosen by <library location> in the XML)", out)

    def test_import_fcpxml_still_running_gives_job_id(self):
        def responder(method, params):
            if method == "fcpxml.import":
                return {"status": "started", "jobId": "j2"}
            return {"jobId": "j2", "state": "running", "elapsedSeconds": 3.0,
                    "windows": [{"title": "Import XML"}, {"title": "Final Cut Pro"}]}

        self._install_bridge(responder)
        out = self.module.import_fcpxml(xml="<fcpxml/>", wait_seconds=0)
        self.assertIn("Import job j2: running", out)
        self.assertIn("an import progress sheet is up", out)
        self.assertIn('import_fcpxml_status(job_id="j2")', out)

    def test_import_fcpxml_status_reports_error(self):
        self._install_bridge(lambda m, p: {"jobId": "j3", "state": "error",
                                           "importError": "Import error: The operation was cancelled."})
        out = self.module.import_fcpxml_status(job_id="j3")
        self.assertIn("Import job j3: error", out)
        self.assertIn("error: Import error: The operation was cancelled.", out)


    def test_capture_clip_frame_caps_render_timeout(self):
        calls = self._install_bridge(lambda m, p: {"status": "ok", "handle": "obj_1"})
        self.module.capture_clip_frame("obj_1", render_timeout=40)
        self.assertEqual(calls[0][1]["renderTimeout"], 15.0)
        self.assertEqual(calls[0][1]["timeout"], 40.0)


if __name__ == "__main__":
    unittest.main()
