#!/usr/bin/env python3
"""Sources/SpliceKitBridgeParams.m must match what tools/gen_bridge_params.py generates."""

import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


class BridgeParamsGeneratedTests(unittest.TestCase):
    def test_generated_params_table_is_current(self):
        proc = subprocess.run(
            [sys.executable, str(REPO_ROOT / "tools" / "gen_bridge_params.py"), "--check"],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_fcpxml_import_lists_path_and_async(self):
        text = (REPO_ROOT / "Sources" / "SpliceKitBridgeParams.m").read_text(encoding="utf-8")
        line = next(l for l in text.splitlines() if l.strip().startswith('@"fcpxml.import":'))
        for key in ("xml", "path", "async", "library", "internal"):
            self.assertIn(f'@"{key}"', line)


if __name__ == "__main__":
    unittest.main()
