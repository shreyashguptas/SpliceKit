#!/usr/bin/env python3
"""The WebM / MKV remux helpers in Sources/Media/URLImport/SpliceKitURLImportMedia.m.

Final Cut plays a .webm / .mkv through an MP4 SpliceKit stream-copies with ffmpeg,
rewriting the timestamps to a constant frame rate. ffmpeg 9 changed how that
rewrite reads its expressions, and every WebM played at one frame per second.
tests/objc/urlimport_media_test.m is built against the real source file: it
checks the frame-rate table, the rewrite arguments and the duration check, and
prints the arguments so this test can run them on a real VP9 WebM with the
ffmpeg SpliceKit itself would use. That end-to-end part is skipped when no
ffmpeg with a VP9 encoder is installed.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HARNESS = REPO_ROOT / "tests" / "objc" / "urlimport_media_test.m"
SOURCE = REPO_ROOT / "Sources" / "Media" / "URLImport" / "SpliceKitURLImportMedia.m"


def _find_tool(name):
    """The tool SpliceKit's installer links first, else the one on PATH."""
    linked = Path.home() / "Applications" / "SpliceKit" / "tools" / name
    if os.access(linked, os.X_OK):
        return str(linked)
    return shutil.which(name)


class TestURLImportMedia(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("clang"):
            raise unittest.SkipTest("clang is not installed")
        cls.tmp = tempfile.mkdtemp(prefix="splicekit-urlimport-test-")
        cls.binary = os.path.join(cls.tmp, "urlimport_media_test")
        includes = sorted({str(p.parent) for p in (REPO_ROOT / "Sources").rglob("*.h")})
        cmd = ["clang", "-fobjc-arc", "-fmodules",
               "-fmodules-cache-path=" + os.path.join(cls.tmp, "modules"),
               "-Wno-unused-parameter"]
        for directory in includes:
            cmd += ["-I", directory]
        cmd += [str(HARNESS), str(SOURCE), "-framework", "Foundation",
                "-framework", "AVFoundation", "-framework", "CoreMedia", "-o", cls.binary]
        built = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            raise AssertionError("building the test harness failed:\n" + built.stderr[-4000:])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def _run(self, *args):
        return subprocess.run([self.binary, *args], capture_output=True, text=True, timeout=60)

    def test_helpers(self):
        result = self._run("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok")

    def _make_webm(self, path, rate, seconds=2):
        ffmpeg = _find_tool("ffmpeg")
        made = subprocess.run(
            [ffmpeg, "-hide_banner", "-v", "error", "-y",
             "-f", "lavfi", "-i", f"testsrc2=size=160x90:rate={rate}:duration={seconds}",
             "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
             "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "200k",
             "-c:a", "libopus", "-shortest", path],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(made.returncode, 0, made.stderr)

    def _probe_video(self, path):
        ffprobe = _find_tool("ffprobe")
        out = subprocess.run(
            [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=time_base,duration,nb_frames:packet=dts,duration", "-of", "json", path],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_remux_keeps_the_frame_rate(self):
        ffmpeg, ffprobe = _find_tool("ffmpeg"), _find_tool("ffprobe")
        if not ffmpeg or not ffprobe:
            self.skipTest("ffmpeg / ffprobe are not installed")
        encoders = subprocess.run([ffmpeg, "-hide_banner", "-encoders"],
                                  capture_output=True, text=True, timeout=30).stdout
        if "libvpx-vp9" not in encoders or "libopus" not in encoders:
            self.skipTest("this ffmpeg cannot write a VP9 / Opus WebM")

        for rate, fps in (("24", 24.0), ("30", 30.0), ("60", 60.0), ("30000/1001", 30000 / 1001)):
            with self.subTest(rate=rate):
                lines = self._run("args", repr(fps)).stdout.split("\n")
                timescale, ticks = (int(v) for v in lines[0].split())
                rewrite = [line for line in lines[1:] if line]
                source = os.path.join(self.tmp, f"src_{rate.replace('/', '_')}.webm")
                output = os.path.join(self.tmp, f"out_{rate.replace('/', '_')}.mp4")
                self._make_webm(source, rate)
                # The same stream-copy SpliceKitURLImportRewriteVP9TimestampsSynchronously runs.
                remux = subprocess.run(
                    [ffmpeg, "-hide_banner", "-v", "error", "-y", "-i", source,
                     "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-c:a", "copy",
                     *rewrite, "-movflags", "+faststart", output],
                    capture_output=True, text=True, timeout=120)
                self.assertEqual(remux.returncode, 0, remux.stderr)

                info = self._probe_video(output)
                stream = info["streams"][0]
                self.assertEqual(stream["time_base"], f"1/{timescale}")
                dts = [int(p["dts"]) for p in info["packets"]]
                self.assertEqual(dts[:4], [0, ticks, 2 * ticks, 3 * ticks],
                                 "frames must be one frame apart, not one second")
                self.assertAlmostEqual(float(stream["duration"]), 2.0, delta=2 * ticks / timescale)


if __name__ == "__main__":
    unittest.main()
