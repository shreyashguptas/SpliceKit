#!/usr/bin/env python3
"""The beat-detector / structure-analyzer failure message names the helper's reason.

The Swift helpers report a bad input as JSON on stdout ({"error": "No audio tracks in
file"}) and exit non-zero with stderr empty; the tools used to print only stderr, so
the answer was "beat-detector failed:" with nothing after it.
"""

import subprocess
import unittest

from support.server_loader import load_server_module, package_module


def _result(returncode, stdout="", stderr=""):
    return subprocess.CompletedProcess(args=["helper"], returncode=returncode, stdout=stdout, stderr=stderr)


class HelperFailureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.music = package_module(load_server_module(), "tools.music")

    def test_json_error_on_stdout_is_reported(self):
        self.assertEqual(self.music._helper_failure(_result(1, stdout='{"error":"No audio tracks in file"}')),
                         "No audio tracks in file")

    def test_stderr_wins_when_present(self):
        self.assertEqual(self.music._helper_failure(_result(1, stdout="{}", stderr="dyld: missing\n")),
                         "dyld: missing")

    def test_plain_stdout_and_silence(self):
        self.assertEqual(self.music._helper_failure(_result(2, stdout="boom")), "boom")
        self.assertEqual(self.music._helper_failure(_result(3)), "exit status 3")


if __name__ == "__main__":
    unittest.main()
