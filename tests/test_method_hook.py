#!/usr/bin/env python3
"""The forwarding hook in Sources/Core/SpliceKitMethodHook.m.

debug.traceMethod and debug.breakpoint replace an FCP method with this hook. It used to
call the original with no arguments and drop its return value, which crashed Final Cut
Pro as soon as a traced method that returns something ran. tests/objc/method_hook_test.m
is built against the real source file and hooks methods of many signatures (objects,
BOOL, six integers, mixed integers and floats, CGRect, NSRange, a struct passed by
pointer, float structs, a class method), checking every argument and return value gets
through, and that unsupported signatures are refused.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HARNESS = REPO_ROOT / "tests" / "objc" / "method_hook_test.m"
SOURCE = REPO_ROOT / "Sources" / "Core" / "SpliceKitMethodHook.m"


class TestMethodHook(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("clang"):
            raise unittest.SkipTest("clang is not installed")
        cls.tmp = tempfile.mkdtemp(prefix="splicekit-method-hook-test-")
        cls.binary = os.path.join(cls.tmp, "method_hook_test")
        cmd = ["clang", "-fobjc-arc", "-fmodules",
               "-fmodules-cache-path=" + os.path.join(cls.tmp, "modules"),
               "-I", str(SOURCE.parent), str(HARNESS), str(SOURCE),
               "-framework", "Foundation", "-o", cls.binary]
        built = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            raise AssertionError("building the test harness failed:\n" + built.stderr[-4000:])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def test_forwarding(self):
        result = subprocess.run([self.binary, "check"], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
