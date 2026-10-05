#!/usr/bin/env python3
"""Offline checks that the caption panel's default engine (Whisper large-v3) is
built by default, and that a missing Whisper transcriber falls back to Parakeet
v3 instead of failing the caption run."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402
from support.fake_bridge import FakeBridge  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-transcribers.sh"
CAPTIONS = ROOT / "Sources" / "Panels" / "Captions"
WHISPER_PKG = ROOT / "helpers" / "whisper-transcriber"


class WhisperBuiltByDefaultTests(unittest.TestCase):
    def test_build_script_builds_whisper_without_flags(self):
        source = BUILD_SCRIPT.read_text(encoding="utf-8")
        match = re.search(r"^TRANSCRIBERS=\((?P<names>[^)]*)\)", source, re.MULTILINE)
        self.assertIsNotNone(match, "build-transcribers.sh no longer declares TRANSCRIBERS")
        names = match.group("names").split()
        self.assertIn("parakeet-transcriber", names)
        self.assertIn("whisper-transcriber", names)
        self.assertNotIn("OPTIONAL_TRANSCRIBERS", source)

    def test_whisperkit_is_pinned_and_resolved(self):
        manifest = (WHISPER_PKG / "Package.swift").read_text(encoding="utf-8")
        self.assertRegex(manifest, r'WhisperKit\.git", exact: "\d+\.\d+\.\d+"')
        self.assertTrue((WHISPER_PKG / "Package.resolved").is_file())


class CaptionEngineFallbackTests(unittest.TestCase):
    def test_default_engine_is_whisper_large_v3(self):
        ui = (CAPTIONS / "SpliceKitCaptionPanel+UI.m").read_text(encoding="utf-8")
        self.assertEqual(
            ui.count('stringForKey:@"SpliceKitCaptionEngine"] ?: @"whisperLargeV3"'), 2)

    def test_missing_whisper_falls_back_to_parakeet(self):
        source = (CAPTIONS / "SpliceKitCaptionPanel+Transcription.m").read_text(encoding="utf-8")
        body = re.search(
            r"- \(void\)performCaptionTranscription \{(?P<body>.*?)\n\}\n", source, re.DOTALL)
        self.assertIsNotNone(body)
        body = body.group("body")
        fallback = body.index("self.engineNotice = [NSString")
        not_found = body.index("transcriber not found. Re-run")
        # The fallback is resolved before the "not found" failure can fire.
        self.assertLess(fallback, not_found)
        self.assertIn("[self parakeetTranscriberPath]", body[:fallback])
        self.assertIn('binaryName = @"parakeet-transcriber";', body[fallback:not_found])
        self.assertIn('modelArg = @"v3";', body[fallback:not_found])

    def test_get_caption_state_reports_the_fallback(self):
        m = load_server_module()
        notice = ("(Whisper large-v3 is not installed, so Parakeet v3 was used. "
                  "Run `make transcribers` to install it.)")
        answer = {"status": "ready", "wordCount": 9, "segmentCount": 2, "engineNotice": notice}
        with FakeBridge(m, answer):
            out = m.get_caption_state()
        self.assertIn("Engine fallback: Whisper large-v3 is not installed", out)
        self.assertNotIn("Last error", out)


if __name__ == "__main__":
    unittest.main()
