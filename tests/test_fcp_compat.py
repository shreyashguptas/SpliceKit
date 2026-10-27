#!/usr/bin/env python3
"""scripts/fcp_compat.py and the FCP version files it reads.

FCP_TESTED_VERSION and patcher/fcp-names-baseline.txt must name the same release,
or make install and make fcp-compat disagree about what was checked. The scan is
run against a stand-in app bundle whose one "binary" lacks a name the baseline has.
"""

import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fcp_compat", REPO_ROOT / "scripts" / "fcp_compat.py")
fcp_compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fcp_compat)


def make_app(root, version, build, words):
    app = Path(root) / "Final Cut Pro.app"
    framework = app / "Contents" / "Frameworks" / "Flexo.framework" / "Versions" / "A"
    framework.mkdir(parents=True)
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleShortVersionString": version, "CFBundleVersion": build}, handle)
    body = b"\xcf\xfa\xed\xfe" + b"\0" * 12 + b"\0".join(w.encode() for w in words) + b"\0"
    (framework / "Flexo").write_bytes(body)
    # A patched copy's own framework must not count as FCP's.
    own = app / "Contents" / "Frameworks" / "SpliceKit.framework"
    own.mkdir()
    (own / "SpliceKit").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 12 + b"supportsBeatDetection\0")
    return str(app)


class TestVersionFiles(unittest.TestCase):
    def test_tested_version_parses(self):
        version, build = fcp_compat.tested_version()
        self.assertRegex(version, r"^\d+\.\d+(\.\d+)?$")
        self.assertRegex(build, r"^\d+$")

    def test_baseline_is_from_the_tested_release(self):
        header, called, other = fcp_compat.read_baseline()
        self.assertEqual((header["version"], header["build"]), fcp_compat.tested_version(),
                         "FCP_TESTED_VERSION and patcher/fcp-names-baseline.txt name different "
                         "releases; run make fcp-baseline against the release you checked")
        self.assertIn("FFAnchoredTimelineModule", called | other)
        self.assertFalse(called & other)


class TestSourceNames(unittest.TestCase):
    def test_finds_runtime_names(self):
        names = fcp_compat.collect_source_names()
        self.assertTrue(names["FFAnchoredTimelineModule"]["called"])
        self.assertTrue(names["primaryObject"]["called"])
        self.assertTrue(any(use.startswith("Sources/") for use in names["primaryObject"]["uses"]))


class TestScan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_reports_a_name_the_release_dropped(self):
        header, called, other = fcp_compat.read_baseline()
        names = fcp_compat.collect_source_names()
        kept = sorted(n for n in called | other
                      if n in names and n not in ("primaryObject", "supportsBeatDetection"))
        app = make_app(self.tmp, "99.0", "1", kept)
        found = fcp_compat.app_strings(app, set(kept) | {"primaryObject", "supportsBeatDetection"})
        self.assertIn("FFAnchoredTimelineModule", found)
        self.assertNotIn("primaryObject", found)
        self.assertNotIn("supportsBeatDetection", found, "SpliceKit's own framework was scanned")
        self.assertEqual(fcp_compat.cmd_scan(app), 1)

    def test_clean_release_passes(self):
        header, called, other = fcp_compat.read_baseline()
        app = make_app(self.tmp, header["version"], header["build"], sorted(called | other))
        self.assertEqual(fcp_compat.cmd_scan(app), 0)
        self.assertEqual(fcp_compat.app_version(app), (header["version"], header["build"]))


if __name__ == "__main__":
    unittest.main()
