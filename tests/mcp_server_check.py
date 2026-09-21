#!/usr/bin/env python3
"""End-to-end check of the SpliceKit MCP server over the real MCP wire.

The server (mcp/server.py) is started exactly the way an MCP client starts it: as a
subprocess speaking MCP over stdio. This script then acts as the client, using the
official `mcp` 2.x SDK, and proves the parts a user cannot see from a chat window.

Modes
  (default)  Offline. A fake SpliceKit bridge answers on a private port, so no Final
             Cut Pro is needed. Checks the handshake in both connect modes (the
             2026-07-28 protocol and the legacy initialize handshake older clients use),
             lists tools/resources/prompts, calls EVERY tool, reads every resource and
             renders every prompt. A tool passes when the server answers without an
             error result (a tool reporting "Error: ..." text about the fake data is a
             normal answer; an exception or an output-validation failure is not).
  --quick    Offline, but only the handshake, the listings and one tool call.
  --live     Against the bridge inside the running patched Final Cut Pro
             (127.0.0.1:9876). Read-only tools only; nothing in the timeline changes.

Options
  --python PATH   interpreter that runs the server (default: the one running this script)
  --json PATH     also write a machine-readable report
  --timeout S     per-request timeout in seconds (default 60)
  --wait S        --live only: how long to keep retrying bridge_status while Final Cut
                  Pro finishes launching (default 90)
  -v              print every tool's first response line

A tool call counts only if it reached the bridge: a tool that answers "Error: ..."
without a single JSON-RPC call is reported as "argument path only" and fails, unless it
is listed in NO_BRIDGE_OK with the reason (an optional dependency that is not installed).
Exit status 0 means everything passed. Requires the `mcp` 2.x package
(mcp/requirements.txt) in the interpreter running this script.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import shutil
import socketserver
import struct
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SERVER = REPO / "mcp" / "server.py"
sys.path.insert(0, str(REPO / "tests"))

try:
    import mcp
    from mcp import Client, StdioServerParameters
except ModuleNotFoundError as exc:  # pragma: no cover - the message is the point
    sys.exit(
        f"[X] The `mcp` package is not importable by {sys.executable} ({exc}).\n"
        "    Run this with the MCP virtualenv: ~/.venvs/splicekit-mcp/bin/python "
        "tests/mcp_server_check.py"
    )

if not hasattr(mcp, "Client"):
    sys.exit(
        f"[X] {sys.executable} has mcp {getattr(mcp, '__version__', '?')} without mcp.Client; "
        "the check needs the 2.x SDK (mcp>=2,<3). Run: make mcp-setup"
    )

# Realistic response shapes shared with the offline unit tests, when available.
try:
    from test_timeline_reads import _detailed_state, _markers_response
except Exception:  # pragma: no cover
    _detailed_state = _markers_response = None
try:
    from test_clip_info_tools import _capture_clip_frame_response, _clip_info_response
except Exception:  # pragma: no cover
    _clip_info_response = _capture_clip_frame_response = None


# ---------------------------------------------------------------------------
# Tiny valid images (so image-returning tools can be proven over the wire)
# ---------------------------------------------------------------------------
def tiny_png() -> bytes:
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"\x00\x00\x00\x00"  # one row, one RGB pixel (filter byte + 3 bytes)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


# A minimal baseline JPEG (1x1, gray); enough for base64 transport checks.
TINY_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////"
    "////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAA"
    "AAAAAP/aAAgBAQABPxA="
)


def _audio_levels_response(p: dict) -> dict:
    """The shape timeline.getAudioLevels answers with: two analyzed spine clips (the second
    ends below the silence threshold), one connected clip, one compound clip skipped after
    resolution, the cut between the two spine clips, and a title skipped before resolution
    (no audio), as the ObjC handler does it. A single handle brings its spine neighbour
    along (role "neighbor", summary only)."""
    def clip(handle, name, start, end, lane=0, connected=False, tail_silent=False, clipped=False, role=None):
        n = 40
        rms = [-20.0 + (i % 5) for i in range(n)]
        peak = [v + 8.0 for v in rms]
        if tail_silent:
            rms[-6:] = [-80.0] * 6
            peak[-6:] = [-70.0] * 6
        if clipped:
            peak[3] = 0.0
        slice_s = (end - start) / n
        out = {"handle": handle, "name": name, "class": "FFAnchoredMediaComponent", "connected": connected,
               "lane": lane, "index": 0, "kind": "video clip", "startSeconds": start, "endSeconds": end,
               "durationSeconds": end - start, "retimed": "unknown",
               "source": {"path": f"/Volumes/Media/{name}.mov", "fileName": f"{name}.mov",
                          "representation": "original", "fileStart": 3.0, "fileEnd": 3.0 + (end - start),
                          "sourceStart": 3603.0, "mediaOrigin": 3600.0},
               "analysisRange": {"startSeconds": start, "endSeconds": end},
               "audio": {"sampleRate": 48000, "channels": 2, "channelsMode": "pooled", "audioTrackCount": 1,
                         "tracksDecoded": 1, "videoFrameRate": 24.0, "fileDuration": 120.0,
                         "sliceSeconds": slice_s, "sliceCount": n},
               "stats": {"maxPeakDb": max(peak), "maxPeakAtSeconds": start + 0.5, "meanRmsDb": -18.5,
                         "clippedSlices": 1 if clipped else 0, "silentSlices": 6 if tail_silent else 0,
                         "allSilent": False, "headSilenceSeconds": 0.0,
                         "tailSilenceSeconds": 0.3 if tail_silent else 0.0,
                         "headRmsDb": -20.0, "headPeakDb": -12.0,
                         "tailRmsDb": -80.0 if tail_silent else -19.0,
                         "tailPeakDb": -70.0 if tail_silent else -11.0, "edgeSeconds": 0.1}}
        if role:
            out["role"] = role
        else:
            out["slices"] = {"startSeconds": start, "sliceSeconds": slice_s, "count": n, "peakDb": peak,
                             "rmsDb": rms, "clippedSliceIndices": [3] if clipped else []}
        return out
    if p.get("handle"):
        clips = [clip("obj_1", "Interview A", 0.0, 2.0, tail_silent=True),
                 clip("obj_2", "B-roll", 2.0, 4.0, role="neighbor")]
        neighbours = 1
    else:
        clips = [clip("obj_1", "Interview A", 0.0, 2.0, tail_silent=True), clip("obj_2", "B-roll", 2.0, 4.0, clipped=True),
                 clip("obj_3", "Music", 0.5, 3.5, lane=-1, connected=True),
                 {"handle": "obj_5", "name": "Nested", "class": "FFAnchoredCollection", "connected": False, "lane": 0,
                  "startSeconds": 4.0, "endSeconds": 6.0, "durationSeconds": 2.0, "kind": "compound clip",
                  "skipped": "compound clip: no single source media file (open it to analyse the clips inside)"}]
        neighbours = 0
    return {"status": "ok", "levelsAre": "the source media file as decoded", "floorDb": -100.0,
            "sliceSeconds": p.get("sliceSeconds", 0.05), "silenceDb": p.get("silenceDb", -50.0),
            "edgeSeconds": p.get("edgeSeconds", 0.1), "perChannel": bool(p.get("perChannel")),
            "helper": "/Applications/Final Cut Pro Modified.app/Contents/Frameworks/SpliceKit.framework/Versions/A/Resources/audio-levels",
            "timeline": {"frameRate": 24.0, "durationSeconds": 6.0},
            "clipCount": len(clips) + 1, "analyzedCount": sum(1 for c in clips if c.get("stats")),
            "neighborCount": neighbours, "outsideRangeCount": 0, "clips": clips,
            "cuts": [{"atSeconds": 2.0, "outgoing": {"handle": "obj_1", "name": "Interview A", "tailRmsDb": -80.0,
                                                     "tailPeakDb": -70.0, "tailSilenceSeconds": 0.3},
                      "incoming": {"handle": "obj_2", "name": "B-roll", "headRmsDb": -20.0, "headPeakDb": -12.0,
                                   "headSilenceSeconds": 0.0},
                      "jumpDb": 60.0, "outgoingEndsInSilence": True, "incomingStartsInSilence": False}],
            "skipped": [{"handle": "obj_4", "name": "Title", "reason": "no audio"},
                        {"handle": "obj_9", "name": "Cross Dissolve", "reason": "transition (no source media of its own)"}],
            "elapsedSeconds": 0.4}


# ---------------------------------------------------------------------------
# Fake bridge: the JSON-RPC server that lives inside Final Cut Pro, stood in for.
# ---------------------------------------------------------------------------
class FakeBridge(threading.Thread):
    """Newline-delimited JSON-RPC 2.0 over TCP, persistent connections, like the dylib."""

    def __init__(self, workdir: Path):
        super().__init__(daemon=True)
        self.workdir = workdir
        self.calls: list[tuple[str, dict]] = []
        bridge = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                while True:
                    line = self.rfile.readline()
                    if not line:
                        return
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        req = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    method = req.get("method", "")
                    params = req.get("params") or {}
                    bridge.calls.append((method, params))
                    result = bridge.result_for(method, params)
                    if isinstance(result, dict) and "__error__" in result:
                        frame = {"jsonrpc": "2.0", "id": req.get("id"),
                                 "error": {"code": -32601, "message": result["__error__"]}}
                    else:
                        frame = {"jsonrpc": "2.0", "id": req.get("id"), "result": result}
                    self.wfile.write((json.dumps(frame) + "\n").encode())
                    self.wfile.flush()

        socketserver.ThreadingTCPServer.allow_reuse_address = True
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]

    def run(self):
        self.server.serve_forever(poll_interval=0.1)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    # -- response shapes ----------------------------------------------------
    def result_for(self, method: str, params: dict):
        p = params
        if method == "system.version":
            return {"splicekit": "check", "version": "check", "fcp": "12.3", "fcpVersion": "12.3",
                    "build": "check", "pid": os.getpid()}
        if method == "timeline.getDetailedState" and _detailed_state:
            return _detailed_state()
        if method == "timeline.getMarkers" and _markers_response:
            return _markers_response(p.get("kind"))
        if method == "timeline.getAudioLevels":
            return _audio_levels_response(p)
        if method == "timeline.getClipInfo" and _clip_info_response:
            r = _clip_info_response({"handle": p.get("handle", "obj_1"), **p})
            if p.get("includeFrame", True) and isinstance(r, dict):
                r.setdefault("frame", {})
                if isinstance(r["frame"], dict):
                    r["frame"].update({"jpegBase64": base64.b64encode(TINY_JPEG).decode(),
                                       "width": 1, "height": 1, "sourceTime": 1.0})
            return r
        if method == "timeline.captureClipFrame" and _capture_clip_frame_response:
            r = _capture_clip_frame_response({"handle": p.get("handle", "obj_1"), **p})
            if isinstance(r, dict):
                r.setdefault("capture", {})
                if isinstance(r["capture"], dict):
                    r["capture"].update({"jpegBase64": base64.b64encode(TINY_JPEG).decode(),
                                         "width": 1, "height": 1})
            return r
        # viewer.capture / timeline.capture / inspector.capture write a PNG where asked.
        if method.endswith(".capture") or method.startswith("capture."):
            path = p.get("path") or str(self.workdir / f"{method.replace('.', '_')}.png")
            try:
                Path(path).parent.mkdir(parents=True, exist_ok=True)
                Path(path).write_bytes(tiny_png())
            except OSError:
                pass
            return {"status": "ok", "path": path, "width": 1, "height": 1, "cropped": True}
        if method == "playback.getPosition":
            return {"seconds": 2.0, "time": {"seconds": 2.0, "value": 48, "timescale": 24},
                    "duration": {"seconds": 30.0}, "durationSeconds": 30.0, "frameRate": 24.0,
                    "fps": 24.0, "isPlaying": False, "playing": False}
        if method == "system.getMethods":
            return {"className": p.get("className"), "instanceMethods": {"displayName": {"typeEncoding": "@16@0:8"}},
                    "classMethods": {}, "count": 1}
        if method == "system.getClasses":
            return {"classes": ["FFAnchoredTimelineModule"], "count": 1}
        if method in ("system.getProperties", "system.getIvars", "system.getProtocols", "system.getSuperchain",
                      "system.exploreClass", "system.searchMethods"):
            return {"className": p.get("className"), "properties": [], "ivars": [], "protocols": [],
                    "superchain": [], "methods": [], "instanceMethods": {}, "classMethods": {}, "count": 0}
        if method == "plugin.listMethods":
            return {"methods": [], "count": 0}
        if method.startswith("transcript."):
            return {"status": "complete", "state": "complete", "engine": "check", "words": [], "segments": [],
                    "silences": [], "speakers": [], "count": 0, "wordCount": 0, "silenceCount": 0,
                    "progress": {"completed": 1, "total": 1}, "results": [], "matches": [],
                    "deleted": 0, "moved": 0}
        if method.startswith("captions."):
            return {"status": "complete", "state": "complete", "segments": [], "words": [], "styles": [],
                    "presets": [], "count": 0, "progress": 1.0, "titles": [], "verified": 0}
        if method.startswith("debug."):
            return {"status": "ok", "config": {}, "threads": [], "log": [], "entries": [], "count": 0,
                    "result": None, "images": [], "symbols": [], "sections": {}, "classes": {}, "notifications": []}
        if method == "timeline.getSelectedClips" or method == "timeline.getSelection":
            return {"clips": [], "items": [], "count": 0, "selectedItems": []}
        if method.startswith("handles.") or method == "system.listHandles":
            return {"handles": [], "count": 0, "released": 0}
        if method.startswith("effects.") or method.startswith("transitions."):
            return {"status": "ok", "effects": [], "transitions": [], "count": 0, "applied": [], "names": []}
        if method.startswith("menu."):
            return {"status": "ok", "menus": [], "items": [], "executed": True}
        if method.startswith("dialog."):
            return {"status": "ok", "dialogs": [], "buttons": [], "fields": [], "found": False}
        if method == "browser.placeClip":
            edit = p.get("edit", "append")
            dry = bool(p.get("dryRun"))
            whole = "inSeconds" not in p and "outSeconds" not in p
            src_in = float(p.get("inSeconds", 0.0))
            src_out = float(p.get("outSeconds", 42.0))
            at = p.get("atSeconds")
            edit_at = at if at is not None else (10.0 if edit != "append" else None)
            res = {"status": "dry_run" if dry else "ok", "dryRun": dry, "edit": edit,
                   "backtimed": bool(p.get("backtimed")),
                   "clip": "Interview A",
                   "sourceClip": {"handle": p.get("handle", "obj_5"), "name": "Interview A",
                                  "class": "FFAnchoredMediaComponent", "durationSeconds": 42.0, "startSeconds": 0.0},
                   "source": {"startSeconds": src_in, "endSeconds": src_out,
                              "durationSeconds": src_out - src_in, "wholeClip": whole},
                   "target": {"playheadBeforeSeconds": 10.0}}
            if at is not None:
                res["target"]["requestedSeconds"] = at
            if edit_at is not None:
                res["target"]["editSeconds"] = edit_at
            if edit == "append":
                res["target"]["storylineEndBeforeSeconds"] = 30.0
            if not dry:
                start = 30.0 if edit == "append" else float(edit_at)
                res["target"]["playheadAfterSeconds"] = start
                res["placed"] = [{"handle": "obj_88", "name": "Interview A", "class": "FFAnchoredMediaComponent",
                                  "lane": 1 if edit == "connect" else 0, "connected": edit == "connect",
                                  "startSeconds": start, "endSeconds": start + (src_out - src_in),
                                  "durationSeconds": src_out - src_in}]
                res.update({"alsoNew": [], "placedCount": 1, "verified": True, "rangeHonored": True,
                            "positionVerified": True, "handleTableReset": False, "skimmingActive": False})
            return res
        if method.startswith("browser."):
            return {"status": "ok", "clips": [], "count": 0, "handle": "obj_1"}
        if method.startswith("library."):
            return {"status": "ok", "libraries": [], "events": [], "projects": [], "count": 0, "updating": False}
        if method.startswith("montage.") or method.startswith("flexmusic.") or method.startswith("songcut."):
            return {"status": "ok", "songs": [], "clips": [], "plan": [], "segments": [], "beats": [],
                    "bars": [], "sections": [], "count": 0, "timing": {}, "song": {}}
        if method.startswith("lua."):
            return {"status": "ok", "output": "", "result": None, "state": {}}
        if method.startswith("inspector."):
            return {"status": "ok", "properties": {}, "value": 0.0, "category": p.get("category")}
        if method == "timeline.getClipEffects" or method == "clip.getEffects":
            return {"effects": [], "count": 0, "clip": "check"}
        if method == "system.getOptions" or method == "options.get":
            return {"options": {}, "status": "ok"}
        return {"status": "ok", "method": method, "params": p}


# ---------------------------------------------------------------------------
# Argument synthesis from each tool's published input schema
# ---------------------------------------------------------------------------
MINIMAL_FCPXML = ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'
                  '<fcpxml version="1.10"><resources><format id="r1" name="FFVideoFormat1080p24" '
                  'frameDuration="100/2400s" width="1920" height="1080"/></resources>'
                  '<library><event name="Check"><project name="Check"><sequence format="r1" duration="0s">'
                  '<spine/></sequence></project></event></library></fcpxml>')
MINIMAL_SRT = "1\n00:00:01,000 --> 00:00:02,000\nCheck\n"
MINIMAL_OTIO = json.dumps({"OTIO_SCHEMA": "Timeline.1", "name": "Check",
                           "tracks": {"OTIO_SCHEMA": "Stack.1", "children": []}})


def schema_types(prop: dict) -> set[str]:
    types: set[str] = set()
    if "type" in prop:
        t = prop["type"]
        types.update(t if isinstance(t, list) else [t])
    for alt in prop.get("anyOf", []) + prop.get("oneOf", []):
        types |= schema_types(alt)
    return types


def synth_value(name: str, prop: dict, workdir: Path):
    types = schema_types(prop)
    lname = name.lower()
    if "enum" in prop and prop["enum"]:
        return prop["enum"][0]
    if "string" in types or not types:
        if lname in ("xml", "fcpxml", "xml_content"):
            return MINIMAL_FCPXML
        if "srt" in lname:
            return MINIMAL_SRT
        if lname == "otio_json":
            return MINIMAL_OTIO
        if lname == "handle" or lname.endswith("_handle"):
            return "obj_1"
        if lname in ("json", "items", "actions", "clips", "beats", "edit_plan", "step_weights", "params",
                     "args", "args_json", "arguments", "keywords", "paths", "handles_json"):
            return "[]" if lname != "params" and lname != "json" and lname != "step_weights" else "{}"
        if lname.endswith("_path") or lname in ("path", "file_path", "file_url", "output_path", "song_file"):
            target = workdir / f"{lname}.dat"
            target.write_bytes(b"check")
            return str(target)
        if lname in ("code", "expression", "lua", "script"):
            return "return 1"
        if lname in ("selector",):
            return "description"
        if lname in ("class_name", "classname", "target", "cls"):
            return "NSObject"
        if lname in ("key_path", "keypath", "property", "prop", "key"):
            return "description"
        if lname in ("method",):
            return "system.version"
        if lname in ("query", "search", "text", "pattern", "filter", "name", "title", "label"):
            return "check"
        if lname in ("action",):
            return "goToStart"
        return "check"
    if "array" in types:
        item = prop.get("items", {}) or {}
        if lname == "handles":
            return ["obj_1"]
        if lname in ("times", "seconds"):
            return [1.0]
        if lname in ("menu_path", "path", "menu"):
            return ["File"]
        it = schema_types(item)
        if "number" in it or "integer" in it:
            return [1]
        return ["check"] if "string" in it or not it else []
    if "integer" in types:
        return 1 if "index" not in lname else 0
    if "number" in types:
        return 1.0
    if "boolean" in types:
        return False
    if "object" in types:
        return {}
    return None


# Per-tool argument overrides where the schema alone would pick something unusable.
def overrides(workdir: Path) -> dict[str, dict]:
    return {
        "export_otio": {"path": str(workdir / "check.otio")},
        "export_xml": {"path": str(workdir / "check.fcpxml")},
        "import_otio": {"path": str(workdir / "missing.otio")},
        "capture_timeline": {"path": str(workdir / "timeline.png")},
        "capture_viewer": {"path": str(workdir / "viewer.png")},
        "capture_inspector": {"path": str(workdir / "inspector.png")},
        "batch_timeline_actions": {"actions": '[{"type":"playback","action":"goToStart"}]'},
        "seek_to_time": {"seconds": 1.0},
        "blade_at_times": {"times": "[1.0, 2.0]"},
        "set_timeline_range": {"start_seconds": 1.0, "end_seconds": 2.0},
        "execute_menu_command": {"menu_path": ["File", "Save"]},
        "list_menus": {"menu": "File"},
        # Valid choices where the schema alone cannot say which string is accepted.
        "background_render_control": {"action": "hold_off"},
        "timeline_navigation_action": {"action": "nextEdit"},
        "timeline_edit_action": {"action": "addMarker"},
        "timeline_destructive_action": {"action": "blade"},
        "history_action": {"action": "undo"},
        "set_playback_speed": {"rate": 1.0},
        "add_markers_at_times": {"markers": '[{"time": 1.0, "name": "Check"}]'},
        "apply_effect": {"name": "Gaussian Blur"},
        "batch_apply_effect": {"name": "Gaussian Blur", "clip_count": 2},
        "apply_transition": {"name": "Cross Dissolve"},
        "toggle_dialog_checkbox": {"checkbox": "Use custom settings", "checked": True},
        "mixer_set_volume": {"handle": "obj_1", "volume_db": -6.0},
        "trim_clip": {"handle": "obj_1", "edge": "end", "to_seconds": 2.0},
        "import_media": {"path": str(workdir / "clip.mov")},
        "set_caption_words": {"words": '[{"text": "Check", "start": 0.0, "end": 1.0}]'},
        "visionpro_connect": {"host": "127.0.0.1"},
        "visionpro_disconnect": {"host": "127.0.0.1"},
        "visionpro_set_camera_calibration": {"camera_id": "cam1", "json": "{}"},
        "add_clip_to_timeline": {"handle": "obj_5", "edit": "insert", "start_seconds": 12.0,
                                 "end_seconds": 18.0, "at_seconds": 45.0},
        # These run a local analysis binary (~/Applications/SpliceKit/tools/...) on the
        # file when it is installed; a path that does not exist makes them fail fast
        # without analysing anything.
        "detect_beats": {"file_path": str(workdir / "missing.wav")},
        "analyze_song_structure": {"file_path": str(workdir / "missing.wav")},
        "beat_sync_blade": {"file_path": str(workdir / "missing.wav")},
        "song_structure_blocks": {"file_path": str(workdir / "missing.wav")},
        "song_structure_sections": {"file_path": str(workdir / "missing.wav")},
    }


# Tools allowed to answer without any bridge traffic, and why.
NO_BRIDGE_OK = {
    "generate_fcpxml": "generates FCPXML locally; the bridge is not involved by design",
    "import_otio": "missing .otio path returns an error before the bridge is contacted",
    "export_otio": "missing bridge export path returns an error before OTIO write",
    "detect_beats": "runs a local analysis binary on the file first (absent here, or the file is missing), so the bridge is not reached",
    "analyze_song_structure": "runs a local analysis binary on the file first (absent here, or the file is missing), so the bridge is not reached",
    "beat_sync_blade": "runs a local analysis binary on the file first (absent here, or the file is missing), so the bridge is not reached",
    "song_structure_blocks": "runs a local analysis binary on the file first (absent here, or the file is missing), so the bridge is not reached",
    "song_structure_sections": "runs a local analysis binary on the file first (absent here, or the file is missing), so the bridge is not reached",
}


# Tools that must never run from a check (they change this Mac, not the timeline).
SKIP = {
    "deploy_and_restart": "rebuilds the dylib and relaunches Final Cut Pro",
}

# Live mode: read-only tools whose answers prove the whole chain against the real app.
# bridge_status, get_bridge_options and get_classes need only the bridge and the ObjC
# runtime, so they must answer properly; the timeline reads need a project open.
LIVE_TOOLS = [
    ("bridge_status", {}),
    ("get_bridge_options", {}),
    ("get_classes", {"filter": "FFAnchoredTimelineModule"}),
    ("get_playhead_position", {}),
    ("get_timeline_clips", {}),
    ("list_markers", {}),
    ("get_selected_clips", {}),
    ("capture_timeline", {"path": None}),   # filled in with a temp path at run time
]
LIVE_HARD = {"bridge_status", "get_bridge_options", "get_classes"}
NO_PROJECT_WORDS = ("no active timeline", "no sequence", "no project", "no timeline")


# ---------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.rows: list[dict] = []

    def add(self, kind: str, name: str, ok: bool, detail: str = "", secs: float = 0.0,
            status: str = None, note: bool = False):
        """status: PASS/FAIL derived from ok unless given (SKIP); note=True prints the detail
        even in a passing, non-verbose run (a caveat the reader must see)."""
        status = status or ("PASS" if ok else "FAIL")
        self.rows.append({"kind": kind, "name": name, "ok": ok, "status": status,
                          "detail": detail, "secs": round(secs, 3)})
        line = f"  {status} {kind:9s} {name}"
        if secs:
            line += f"  ({secs:.2f}s)"
        if detail and (not ok or VERBOSE or note):
            line += f"\n         {detail[:300]}"
        print(line, flush=True)

    @property
    def notes(self):
        return [r for r in self.rows if r["status"] == "PASS" and r["detail"].startswith("(")]

    @property
    def failures(self):
        return [r for r in self.rows if not r["ok"]]


VERBOSE = False


def full_text(result) -> str:
    return "\n".join(b.text for b in result.content if getattr(b, "type", "") == "text")


def first_text(result) -> str:
    text = full_text(result).strip()
    return text.splitlines()[0] if text else ""


def expected_version() -> str:
    """SPLICEKIT_VERSION from patcher/SpliceKit/Configuration/Version.xcconfig, or ""."""
    try:
        for line in (REPO / "patcher" / "SpliceKit" / "Configuration" / "Version.xcconfig").read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() == "SPLICEKIT_VERSION":
                return value.strip()
    except OSError:
        pass
    return ""


async def handshake(params, mode: str, report: Report, timeout: float):
    t0 = time.time()
    try:
        async with Client(params, mode=mode, read_timeout_seconds=timeout) as cl:
            info = cl.server_info
            ok = bool(cl.protocol_version) and info is not None and info.name == "splicekit" and bool(cl.instructions)
            want = expected_version()
            if want and info is not None and info.version != want:
                ok = False
            detail = (f"protocol {cl.protocol_version}; server {info.name} {info.version or '(no version)'}"
                      f"{'' if not want else ' (expected ' + want + ')' if info.version != want else ''}; "
                      f"instructions {len(cl.instructions or '')} chars")
            report.add("handshake", mode, ok, detail, time.time() - t0)
            return cl.protocol_version
    except Exception as exc:  # noqa: BLE001
        report.add("handshake", mode, False, f"{type(exc).__name__}: {exc}", time.time() - t0)
        return None


async def run_offline(args, report: Report):
    workdir = Path(tempfile.mkdtemp(prefix="splicekit-mcp-check-"))
    bridge = FakeBridge(workdir)
    bridge.start()
    try:
        await _run_offline(args, report, workdir, bridge)
    finally:
        bridge.stop()
        shutil.rmtree(workdir, ignore_errors=True)


async def _run_offline(args, report: Report, workdir: Path, bridge: "FakeBridge"):
    env = {**os.environ, "SPLICEKIT_HOST": "127.0.0.1", "SPLICEKIT_PORT": str(bridge.port), "PYTHONUNBUFFERED": "1"}
    params = StdioServerParameters(command=args.python, args=[str(SERVER)], env=env)
    print(f"server: {args.python} {SERVER}")
    print(f"fake bridge: 127.0.0.1:{bridge.port}   mcp package: {mcp_version()}")

    legacy = await handshake(params, "legacy", report, args.timeout)
    if await handshake(params, "auto", report, args.timeout) is None:
        return  # nothing below can run without a session

    if legacy is not None:
        # One text tool and one image tool through the legacy handshake, the path
        # clients on the 2025 protocol revisions take.
        t0 = time.time()
        try:
            async with Client(params, mode="legacy", read_timeout_seconds=args.timeout) as cl:
                r1 = await cl.call_tool("bridge_status", {})
                r2 = await cl.call_tool("capture_viewer", {"path": str(workdir / "legacy_viewer.png")})
                kinds = [b.type for b in r2.content]
                ok = not r1.is_error and not r2.is_error and "image" in kinds
                report.add("legacy", "text + image tool calls", ok,
                           f"bridge_status ok={not r1.is_error}; capture_viewer content {kinds}", time.time() - t0)
        except Exception as exc:  # noqa: BLE001
            report.add("legacy", "text + image tool calls", False, f"{type(exc).__name__}: {exc}", time.time() - t0)

    async with Client(params, read_timeout_seconds=args.timeout) as cl:
        tools = (await cl.list_tools()).tools
        resources = (await cl.list_resources()).resources
        prompts = (await cl.list_prompts()).prompts
        names = [t.name for t in tools]
        dupes = sorted({n for n in names if names.count(n) > 1})
        report.add("listing", "tools", len(tools) >= 200 and not dupes,
                   f"{len(tools)} tools" + (f"; duplicates: {dupes}" if dupes else ""))
        report.add("listing", "resources", len(resources) >= 1, f"{len(resources)} resources")
        report.add("listing", "prompts", len(prompts) >= 1, f"{len(prompts)} prompts")

        missing = []
        for t in tools:
            a = t.annotations
            hints_ok = a is not None and all(isinstance(getattr(a, f), bool) for f in
                                             ("read_only_hint", "destructive_hint", "idempotent_hint", "open_world_hint"))
            if not (hints_ok and a.title and t.description and (t.input_schema or {}).get("type") == "object"):
                missing.append(t.name)
        report.add("listing", "tool metadata", not missing,
                   "every tool has a description, an object input schema and all four annotation hints"
                   if not missing else f"incomplete: {missing[:10]}")

        if args.quick:
            r = await cl.call_tool("bridge_status", {})
            report.add("tool", "bridge_status", not r.is_error and "check" in full_text(r),
                       " ".join(full_text(r).split())[:160])
            return

        ov = overrides(workdir)
        for t in tools:
            if t.name in SKIP:
                report.add("tool", t.name, True, f"not invoked: {SKIP[t.name]} (schema and annotations checked)",
                           status="SKIP", note=True)
                continue
            schema = t.input_schema or {}
            props = schema.get("properties", {}) or {}
            call_args = {n: synth_value(n, props.get(n, {}) or {}, workdir) for n in schema.get("required", [])}
            call_args.update(ov.get(t.name, {}))
            calls_before = len(bridge.calls)
            t0 = time.time()
            try:
                r = await cl.call_tool(t.name, call_args)
            except Exception as exc:  # noqa: BLE001
                report.add("tool", t.name, False, f"{type(exc).__name__}: {exc}", time.time() - t0)
                continue
            reached_bridge = len(bridge.calls) > calls_before
            kinds = [b.type for b in r.content]
            detail = first_text(r)
            ok = not r.is_error
            if t.output_schema is not None and ok:
                ok = r.structured_content is not None
                if not ok:
                    detail = "output schema published but no structuredContent returned"
            if t.name in ("capture_timeline", "capture_viewer", "capture_inspector", "get_clip_info", "capture_clip_frame", "get_audio_levels") and ok:
                ok = "image" in kinds
                if not ok:
                    detail = f"expected an image content block, got {kinds}: {detail}"
                else:
                    detail = f"content {kinds}; {detail}"
            note = False
            if ok and not reached_bridge:
                if t.name in NO_BRIDGE_OK:
                    detail = f"(no bridge traffic: {NO_BRIDGE_OK[t.name]}) {detail}"
                    note = True
                else:
                    ok = False
                    detail = f"argument path only: answered without a single bridge call ({detail})"
            report.add("tool", t.name, ok, detail, time.time() - t0, note=note)

        for res in resources:
            t0 = time.time()
            try:
                rr = await cl.read_resource(str(res.uri))
                contents = getattr(rr, "contents", [])
                ok = bool(contents) and all(getattr(c, "text", None) or getattr(c, "blob", None) for c in contents)
                detail = f"{len(contents)} content block(s)"
            except Exception as exc:  # noqa: BLE001
                ok, detail = False, f"{type(exc).__name__}: {exc}"
            report.add("resource", str(res.uri), ok, detail, time.time() - t0)

        for pr in prompts:
            t0 = time.time()
            pargs = {a.name: "check" for a in (pr.arguments or []) if a.required}
            try:
                gp = await cl.get_prompt(pr.name, pargs)
                msgs = getattr(gp, "messages", [])
                ok = bool(msgs)
                detail = f"{len(msgs)} message(s)"
            except Exception as exc:  # noqa: BLE001
                ok, detail = False, f"{type(exc).__name__}: {exc}"
            report.add("prompt", pr.name, ok, detail, time.time() - t0)

    report.add("bridge", "traffic", len(bridge.calls) > 0, f"{len(bridge.calls)} JSON-RPC calls reached the fake bridge")


def _not_ready(text: str) -> bool:
    """A bridge_status answer from a Final Cut Pro that is not (yet) able to answer."""
    low = text.lower()
    return ("not connected" in low or "did not finish" in low or "timed out" in low
            or "communication error" in low or text.startswith("Error"))


async def run_live(args, report: Report):
    params = StdioServerParameters(command=args.python, args=[str(SERVER)], env={**os.environ, "PYTHONUNBUFFERED": "1"})
    print(f"server: {args.python} {SERVER}")
    host = os.environ.get("SPLICEKIT_HOST") or "127.0.0.1"
    port = os.environ.get("SPLICEKIT_PORT") or "9876"
    print(f"bridge: {host}:{port} (the patched Final Cut Pro)   mcp package: {mcp_version()}")
    if await handshake(params, "auto", report, args.timeout) is None:
        return
    workdir = Path(tempfile.mkdtemp(prefix="splicekit-mcp-live-"))
    try:
        async with Client(params, read_timeout_seconds=args.timeout) as cl:
            tools = (await cl.list_tools()).tools
            report.add("listing", "tools", len(tools) >= 200, f"{len(tools)} tools")

            # The port opens when the app finishes launching, but its main thread can
            # still be busy (library restore, a first-run dialog). Keep asking for a while.
            deadline = time.time() + args.wait
            t0 = time.time()
            while True:
                r = await cl.call_tool("bridge_status", {})
                text = first_text(r)
                if not r.is_error and not _not_ready(text):
                    break
                if time.time() >= deadline:
                    break
                print(f"         waiting for Final Cut Pro to answer ({int(time.time() - t0)}s): {text[:80]}", flush=True)
                await asyncio.sleep(3)
            report.add("tool", "bridge_status", not r.is_error and not _not_ready(text), text, time.time() - t0)

            for name, call_args in LIVE_TOOLS[1:]:
                if name == "capture_timeline":
                    call_args = {"path": str(workdir / "timeline.png")}
                t0 = time.time()
                try:
                    r = await cl.call_tool(name, call_args)
                except Exception as exc:  # noqa: BLE001
                    report.add("tool", name, False, f"{type(exc).__name__}: {exc}", time.time() - t0)
                    continue
                text = first_text(r)
                kinds = [b.type for b in r.content]
                ok = not r.is_error
                note = False
                if name in LIVE_HARD:
                    ok = ok and not text.startswith("Error")
                    if name == "get_classes":
                        ok = ok and "FFAnchoredTimelineModule" in full_text(r)
                elif text.startswith("Error") or (name == "capture_timeline" and "image" not in kinds):
                    # Timeline reads need a project open in Final Cut Pro. Right after a
                    # fresh launch there is none, and the server says so in FCP's own
                    # words; that is a correct answer from a working chain, not a failure,
                    # but it is shown, counted, and named in the summary.
                    if any(k in text.lower() for k in NO_PROJECT_WORDS):
                        text = f"(no project open in Final Cut Pro; timeline read not exercised) {text}"
                        note = True
                    else:
                        ok = False
                elif name == "capture_timeline":
                    text = f"content {kinds}; {text}"
                report.add("tool", name, ok, text, time.time() - t0, note=note)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def mcp_version() -> str:
    try:
        import importlib.metadata
        return importlib.metadata.version("mcp")
    except Exception:  # pragma: no cover
        return "?"


def main(argv=None) -> int:
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--json")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--wait", type=float, default=90.0)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    VERBOSE = args.verbose

    if not SERVER.is_file():
        print(f"[X] server not found: {SERVER}")
        return 2

    report = Report()
    started = time.time()
    print(f"== SpliceKit MCP server check ({'live' if args.live else 'quick offline' if args.quick else 'offline'}) ==")
    try:
        asyncio.run(run_live(args, report) if args.live else run_offline(args, report))
    except KeyboardInterrupt:
        return 130

    passed = len([r for r in report.rows if r["ok"] and r["status"] == "PASS"])
    skipped = len([r for r in report.rows if r["status"] == "SKIP"])
    failed = report.failures
    print(f"\n{passed} passed, {len(failed)} failed, {skipped} skipped in {time.time() - started:.1f}s")
    for f in failed:
        print(f"  FAIL {f['kind']} {f['name']}: {f['detail'][:400]}")
    if args.live:
        not_exercised = [r["name"] for r in report.rows if r["kind"] == "tool" and "timeline read not exercised" in r["detail"]]
        if not_exercised:
            print(f"  bridge and MCP server verified; {len(not_exercised)} timeline read(s) answered 'no project open' "
                  f"and were not exercised ({', '.join(not_exercised)}). Open a project in Final Cut Pro and run: "
                  "make mcp-check-live")
        elif not failed:
            print("  bridge, MCP server and timeline reads verified against the running Final Cut Pro")
    if args.json:
        Path(args.json).write_text(json.dumps({"mcp": mcp_version(), "python": args.python,
                                               "mode": "live" if args.live else "offline",
                                               "rows": report.rows}, indent=2))
        print(f"report: {args.json}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
