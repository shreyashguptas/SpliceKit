#!/usr/bin/env python3
"""Where the Transcript Editor places each word on the timeline after an edit.

Sources/Panels/Transcript/SpliceKitTranscriptPlacement.m places every transcribed word on
the clips the timeline plays now, after every transcript edit, undo or edit made in Final
Cut Pro. The resync before it matched each word to the first clip whose source range held
its start and left the rest at their old times ("matched 49 words, 16 unmatched"), so the
next edit cut at times past the end of the timeline. tests/objc/transcript_placement_test.m
is built against the real source file and checks cuts rounded to a frame, a blade inside a
word, moves, a clip used twice, a clip removed and a conformed frame rate.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HARNESS = REPO_ROOT / "tests" / "objc" / "transcript_placement_test.m"
SOURCE = REPO_ROOT / "Sources" / "Panels" / "Transcript" / "SpliceKitTranscriptPlacement.m"


class TestTranscriptPlacement(unittest.TestCase):
    def test_placement_rules(self):
        if not shutil.which("clang"):
            self.skipTest("clang is not installed")
        with tempfile.TemporaryDirectory(prefix="splicekit-placement-test-") as tmp:
            binary = str(Path(tmp) / "transcript_placement_test")
            cmd = ["clang", "-fobjc-arc", "-fmodules",
                   "-fmodules-cache-path=" + str(Path(tmp) / "modules"),
                   "-I", str(SOURCE.parent), str(HARNESS), str(SOURCE),
                   "-framework", "Foundation", "-o", binary]
            built = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            self.assertEqual(built.returncode, 0, "building the test harness failed:\n" + built.stderr[-4000:])
            ran = subprocess.run([binary], capture_output=True, text=True, timeout=60)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn("all placement checks passed", ran.stdout)


if __name__ == "__main__":
    unittest.main()
