#!/usr/bin/env python3
"""Offline checks that the transcript panel offers Whisper (its default engine),
that set_transcript_engine accepts it, and that get_transcript names the engine and
reports a fall back to Parakeet."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridge  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT = ROOT / "Sources" / "Panels" / "Transcript"
SERVER = ROOT / "Sources" / "Bridge" / "SpliceKitServerTranscript.m"


class TranscriptWhisperEngineTests(unittest.TestCase):
    def test_default_engine_is_whisper_large_v3(self):
        source = (TRANSCRIPT / "SpliceKitTranscriptPanel.m").read_text(encoding="utf-8")
        self.assertIn("_engine = SpliceKitTranscriptEngineWhisper;", source)
        self.assertIn('_whisperModel = @"large-v3";', source)

    def test_restoring_a_saved_transcript_keeps_the_chosen_engine(self):
        source = (TRANSCRIPT / "SpliceKitTranscriptPanel.m").read_text(encoding="utf-8")
        body = re.search(r"- \(void\)restorePersistedStateForCurrentSequenceIfNeeded \{(?P<body>.*?)\n\}\n",
                         source, re.DOTALL)
        self.assertIsNotNone(body)
        self.assertNotIn("self.engine =", body.group("body"))

    def test_the_dropdown_choice_is_remembered(self):
        ui = (TRANSCRIPT / "SpliceKitTranscriptPanel+UI.m").read_text(encoding="utf-8")
        changed = re.search(r"- \(void\)engineChanged:\(id\)sender \{(?P<body>.*?)\n\}\n", ui, re.DOTALL)
        self.assertIsNotNone(changed)
        self.assertIn("[self saveEngineChoice];", changed.group("body"))
        source = (TRANSCRIPT / "SpliceKitTranscriptPanel.m").read_text(encoding="utf-8")
        self.assertIn("[self loadSavedEngineChoice];", source)

    def test_dropdown_offers_both_whisper_models(self):
        ui = (TRANSCRIPT / "SpliceKitTranscriptPanel+UI.m").read_text(encoding="utf-8")
        self.assertIn('@"Whisper large-v3"', ui)
        self.assertIn('@"Whisper large-v3 turbo"', ui)

    def test_set_engine_rpc_accepts_whisper_names(self):
        source = SERVER.read_text(encoding="utf-8")
        for name in ("whisper", "whisperLargeV3", "whisperLargeV3Turbo"):
            self.assertIn(f'isEqualToString:@"{name}"', source)

    def test_missing_whisper_falls_back_to_parakeet(self):
        source = (TRANSCRIPT / "SpliceKitTranscriptPanel+Parakeet.m").read_text(encoding="utf-8")
        body = re.search(r"- \(NSString \*\)prepareCLIEngine \{(?P<body>.*?)\n\}\n", source, re.DOTALL)
        self.assertIsNotNone(body)
        body = body.group("body")
        self.assertIn("[self whisperTranscriberPath]", body)
        self.assertIn("self.cliEngineNotice = @\"Whisper is not installed", body)
        self.assertIn("return [self parakeetTranscriberPath];", body)

    def test_get_transcript_names_the_engine_and_the_fallback(self):
        m = load_server_module()
        notice = "Whisper is not installed, so Parakeet v3 was used."
        answer = {"status": "ready", "engine": "whisper", "whisperModel": "large-v3",
                  "engineNotice": notice, "wordCount": 0, "words": [], "silences": []}
        with FakeBridge(m, answer):
            out = m.get_transcript()
        self.assertIn("Engine: whisper large-v3", out)
        self.assertIn(f"Engine fallback: {notice}", out)


if __name__ == "__main__":
    unittest.main()
