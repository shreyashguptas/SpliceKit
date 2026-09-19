#!/usr/bin/env python3
"""
live_timeline_reads_check.py — evidence report for the connected-clip + marker reads.

Runs against a LIVE Final Cut Pro with SpliceKit injected (bridge on 127.0.0.1:9876)
and prints, without changing the timeline:

  1. Bridge + FCP version.
  2. FCP's own vocabulary: which of the selectors the new code probes actually exist
     on FFAnchoredMarker / FFAnchoredChapterMarker / FFAnchoredKeywordMarker /
     FFAnchoredObject / FFAnchoredSequence / FFAnchoredCollection in this FCP build,
     plus any marker-related selectors FCP has that the code does not probe yet.
  3. What timeline.getDetailedState and timeline.getMarkers return for the open
     project: every connected clip and marker with the `timeSource` that resolved
     its time, and sanity flags (unknown time, time outside the sequence, kind
     that disagrees with the class name).
  4. Optional --cross-check: for a few connected clips, seek to their midpoint and ask
     the pre-existing timeline.selectClipInLane for the clip on that lane; the
     handles must match. This moves the playhead and selection (restored after),
     never the content.
  5. Optional, each CHANGES STATE and reverts itself:
     --select-check  selects one clip by handle via timeline.selectItems, verifies the
                     readback, then restores the previous selection (or deselects all).
     --edit-check    beginEdit -> addMarkers (2) -> endEdit, then undoes and reports
                     whether ONE undo removed both markers (grouped) or one; undoes
                     until the marker count is back at the baseline.
     --trim-check    ripple-trims the last spine clip's end by one frame via
                     timeline.trimClip (dry run first), verifies, then undoes and
                     verifies the clip's end is back where it was.
  6. Optional --clip-info-check (READ-ONLY): timeline.getClipInfo on the first spine
     clip that is a video or audio clip; prints kind, source media file (path, exists,
     representation), source start / media origin / file time, effects, title text,
     transcript status + word count and the frame (written to
     /tmp/splicekit_clip_info_frame.jpg so a human can look at it). FAIL when the
     response errors or reports neither sourceMedia nor sourceMediaError; a frameError
     is a WARN, not a FAIL.
  7. Optional --viewer-frame-check (CHANGES STATE: moves the playhead, restored):
     timeline.captureClipFrame on that clip, verifies playheadRestored and that the
     playhead really is back, writes /tmp/splicekit_clip_viewer_frame.jpg.

Usage:
    python3 tests/live_timeline_reads_check.py                # read-only report
    python3 tests/live_timeline_reads_check.py --cross-check  # also verify lanes/times
    python3 tests/live_timeline_reads_check.py --select-check --edit-check --trim-check
    python3 tests/live_timeline_reads_check.py --clip-info-check --viewer-frame-check
    python3 tests/live_timeline_reads_check.py --json out.json # dump raw responses

Open a project first that has at least one title, one connected audio clip,
one chapter marker and one to-do marker. Paste the whole output back for review.
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 9876
_id = 0
RAW: dict = {}

# Selectors the bridge code probes (Sources/SpliceKitServer.m, timeline.getDetailedState).
PROBED = {
    "marker kind (chapter)": ["isChapter", "isChapterMarker"],
    "marker kind (todo)": ["isToDo", "isTodo", "isToDoMarker", "isIncomplete", "isCompleted"],
    "marker completed": ["isCompleted", "completed", "isDone"],
    "marker note": ["note", "notes", "comment"],
    "marker name": ["displayName", "name"],
    "marker range": ["timeRange", "range", "anchoredRange"],
    "marker time": ["anchoredOffset", "startTime", "time", "offset"],
    "item flags": ["hasVideo", "hasAudio", "isConnectedStoryline", "isEnabled", "enabled"],
    "item tree": ["anchoredItems", "containedItems", "anchoredLane", "anchoredOffset",
                  "duration", "displayName", "mediaType", "trimmedOffset"],
}
RELEVANT = re.compile(r"(todo|ToDo|Todo|chapter|Chapter|complet|Complet|note|Note|comment|"
                      r"range|Range|time|Time|offset|Offset|lane|Lane|anchored|Anchored|"
                      r"enabled|Enabled|marker|Marker|poster|Poster)")


def rpc(method, params=None, timeout=20):
    global _id
    _id += 1
    req = {"jsonrpc": "2.0", "method": method, "id": _id}
    if params:
        req["params"] = params
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    s.sendall((json.dumps(req) + "\n").encode())
    data = b""
    while b"\n" not in data:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        data += chunk
    s.close()
    resp = json.loads(data.decode().strip())
    if "result" in resp:
        res = resp["result"]
    else:
        # A refused call comes back as a JSON-RPC error object ({"message", "code"}); hand it
        # on as {"error": "<message>"} so every check can test the text the same way.
        err = resp.get("error")
        if isinstance(err, dict):
            res = {"error": err.get("message") or json.dumps(err), "code": err.get("code")}
        else:
            res = resp
    RAW.setdefault(method, []).append({"params": params, "result": res})
    return res


def secs(d, key):
    t = d.get(key) if isinstance(d, dict) else None
    if isinstance(t, dict) and isinstance(t.get("seconds"), (int, float)):
        return float(t["seconds"])
    return None


def fmt(v):
    return f"{v:8.3f}s" if v is not None else "       ?"


def section(title):
    print(f"\n== {title} ==")


# ── 1. bridge ──────────────────────────────────────────────────────────────────

def check_bridge():
    section("Bridge")
    try:
        v = rpc("system.version")
    except OSError as e:
        print(f"FAIL  cannot reach SpliceKit bridge at {HOST}:{PORT}: {e}")
        print("      Launch the patched Final Cut Pro first.")
        sys.exit(2)
    print("OK    " + json.dumps(v)[:300])
    return v


# ── 2. FCP vocabulary ─────────────────────────────────────────────────────────

def class_methods(class_name):
    r = rpc("system.getMethods", {"className": class_name, "includeSuper": True})
    if "error" in r:
        return None, r["error"]
    names = set((r.get("instanceMethods") or {}).keys())
    p = rpc("system.getProperties", {"className": class_name})
    props = {x.get("name") for x in (p.get("properties") or []) if isinstance(x, dict)}
    return names | props, None


def check_vocabulary():
    section("FCP vocabulary (does this FCP build have the selectors the code probes?)")
    classes = ["FFAnchoredObject", "FFAnchoredMarker", "FFAnchoredChapterMarker",
               "FFAnchoredKeywordMarker", "FFAnchoredMediaComponent",
               "FFAnchoredSequence", "FFAnchoredCollection"]
    found = {}
    for cls in classes:
        names, err = class_methods(cls)
        if names is None:
            print(f"MISS  class {cls}: {err}")
            continue
        found[cls] = names
        print(f"OK    class {cls}: {len(names)} selectors/properties (incl. superclasses)")

    def has(cls, sel):
        return cls in found and sel in found[cls]

    print("\nProbe checklist (Y = exists on FFAnchoredMarker / Chapter / Keyword / MediaComponent):")
    targets = ["FFAnchoredMarker", "FFAnchoredChapterMarker", "FFAnchoredKeywordMarker",
               "FFAnchoredMediaComponent"]
    for group, sels in PROBED.items():
        for sel in sels:
            marks = " ".join("Y" if has(t, sel) else "." for t in targets)
            print(f"  {group:<22} {sel:<22} {marks}")

    print("\nSequence/collection entry points:")
    for cls, sel in [("FFAnchoredSequence", "markersInTimeRange:"),
                     ("FFAnchoredCollection", "effectiveRangeOfObject:"),
                     ("FFAnchoredSequence", "primaryObject"),
                     ("FFAnchoredCollection", "containedItems")]:
        print(f"  {'OK ' if has(cls, sel) else 'MISS'}  -[{cls} {sel}]")

    print("\nMarker-related selectors FCP has that the code does NOT probe (candidates for real names):")
    probed_all = {s for sels in PROBED.values() for s in sels}
    for cls in ["FFAnchoredMarker", "FFAnchoredChapterMarker", "FFAnchoredKeywordMarker"]:
        if cls not in found:
            continue
        extra = sorted(n for n in found[cls] if RELEVANT.search(n) and n not in probed_all
                       and not n.startswith("_") and n.count(":") <= 1)
        print(f"  {cls}: " + (", ".join(extra[:60]) if extra else "(none)"))
        if len(extra) > 60:
            print(f"    ... {len(extra) - 60} more")
    return found


# ── 3. snapshot ───────────────────────────────────────────────────────────────

def check_snapshot():
    section("timeline.getDetailedState")
    st = rpc("timeline.getDetailedState")
    if "error" in st:
        print(f"SKIP  {st['error']} (open a project and re-run)")
        return None
    dur = secs(st, "duration")
    items = st.get("items") or []
    spine_start = min((secs(i, "startTime") for i in items if secs(i, "startTime") is not None),
                      default=0.0)
    spine_end = max((secs(i, "endTime") for i in items if secs(i, "endTime") is not None),
                    default=(spine_start + (dur or 0)))
    print(f"sequence={st.get('sequenceName')!r} spine items={st.get('itemCount')} "
          f"connected={st.get('connectedCount')} markers={st.get('markerCount')} "
          f"duration={fmt(dur)} spine=[{fmt(spine_start)} .. {fmt(spine_end)}]")
    for key in ("connectedItemsError", "markersError"):
        if st.get(key):
            print(f"FAIL  {key}: {st[key]}")
    print(f"markerSources={json.dumps(st.get('markerSources'))}")

    warns = 0
    conn = st.get("connectedItems") or []
    print(f"\nConnected clips ({len(conn)}):")
    print(f"  {'lane':>4} {'eff':>4} {'class':<28} {'name':<22} {'start':>9} {'end':>9} "
          f"{'parent':>6} {'depth':>5} {'timeSource'}")
    for c in conn:
        s, e = secs(c, "startTime"), secs(c, "endTime")
        flag = ""
        if c.get("timeSource") == "unknown" or s is None:
            flag = "  <-- WARN no time"
            warns += 1
        elif s < spine_start - 0.01 or (e is not None and e > spine_end + 0.01):
            flag = "  <-- WARN outside spine bounds"
            warns += 1
        print(f"  {c.get('lane', '?'):>4} {c.get('effectiveLane', '?'):>4} "
              f"{str(c.get('class', ''))[:28]:<28} {str(c.get('name', ''))[:22]:<22} "
              f"{fmt(s)} {fmt(e)} {c.get('parentIndex', '?'):>6} {c.get('depth', '?'):>5} "
              f"{c.get('timeSource', '?')}{flag}")

    marks = st.get("markers") or []
    print(f"\nMarkers ({len(marks)}):")
    print(f"  {'time':>9} {'kind':<9} {'class':<26} {'name':<22} {'done':<6} {'doneSrc':<12} {'timeSource'}")
    for m in marks:
        t = secs(m, "time")
        flag = ""
        cls = str(m.get("class", ""))
        if m.get("timeSource") == "unknown" or t is None:
            flag = "  <-- WARN no time"
            warns += 1
        elif t < spine_start - 0.01 or t > spine_end + 0.01:
            flag = "  <-- WARN outside spine bounds"
            warns += 1
        if "Chapter" in cls and m.get("kind") != "chapter":
            flag += "  <-- WARN class says chapter"
            warns += 1
        done = m.get("completed")
        print(f"  {fmt(t)} {str(m.get('kind', '?')):<9} {cls[:26]:<26} {str(m.get('name', ''))[:22]:<22} "
              f"{'' if done is None else str(done):<6} {str(m.get('completedSource', '')):<12} "
              f"{m.get('timeSource', '?')}{flag}")

    section("timeline.getMarkers")
    gm = rpc("timeline.getMarkers")
    if "error" in gm:
        print(f"FAIL  {gm['error']}")
    else:
        print(f"OK    markerCount={gm.get('markerCount')} (getDetailedState reported {st.get('markerCount')})")
        if gm.get("markerCount") != st.get("markerCount"):
            print("WARN  counts differ between the two RPCs")
            warns += 1
        ch = rpc("timeline.getMarkers", {"kind": "chapter"})
        print(f"OK    kind=chapter -> {ch.get('markerCount')} marker(s)")
    return st, conn, marks, warns


# ── 4. cross-check ────────────────────────────────────────────────────────────

def cross_check(conn):
    section("Cross-check against timeline.selectClipInLane (moves playhead + selection, restored)")
    pos = rpc("playback.getPosition")
    original = pos.get("seconds")
    candidates = [c for c in conn
                  if c.get("depth") == 0 and not c.get("isGap") and not c.get("isTransition")
                  and secs(c, "startTime") is not None and secs(c, "endTime") is not None]
    seen_lanes = set()
    checked = 0
    mismatches = 0
    for c in candidates:
        lane = c.get("effectiveLane", c.get("lane"))
        if lane in seen_lanes or lane == 0:
            continue
        seen_lanes.add(lane)
        mid = (secs(c, "startTime") + secs(c, "endTime")) / 2.0
        rpc("playback.seekToTime", {"seconds": mid})
        r = rpc("timeline.selectClipInLane", {"lane": lane})
        checked += 1
        if r.get("handle") == c.get("handle"):
            print(f"OK    lane {lane:>3} @ {mid:8.3f}s -> {r.get('clip')!r} matches handle {c.get('handle')}")
        else:
            mismatches += 1
            print(f"FAIL  lane {lane:>3} @ {mid:8.3f}s -> selector got {r.get('clip')!r} "
                  f"({r.get('handle') or r.get('error')}), snapshot said {c.get('name')!r} ({c.get('handle')})")
        if checked >= 4:
            break
    if isinstance(original, (int, float)):
        rpc("playback.seekToTime", {"seconds": original})
    if checked == 0:
        print("SKIP  no connected clips with resolved times to check")
    return checked, mismatches


# ── 5. state-changing checks (each reverts itself) ────────────────────────────

def _frame_seconds(st):
    fps = st.get("frameRate")
    if isinstance(fps, (int, float)) and fps > 0:
        return 1.0 / float(fps)
    return 1.0 / 24.0


def _spine_clips(st):
    return [i for i in (st.get("items") or [])
            if not i.get("isGap") and not i.get("isTransition")
            and "Transition" not in str(i.get("class", ""))
            and secs(i, "startTime") is not None and secs(i, "endTime") is not None]


def select_check(st, conn):
    section("timeline.selectItems (changes selection, restored)")
    fails = 0
    previous = [i.get("handle") for i in (st.get("items") or []) if i.get("selected") and i.get("handle")]
    previous += [c.get("handle") for c in conn if c.get("selected") and c.get("handle")]
    print(f"previous selection: {previous or '(none)'}")

    candidates = [c for c in conn if c.get("depth") == 0 and not c.get("isGap")
                  and not c.get("isTransition") and c.get("handle")]
    target = candidates[0] if candidates else (_spine_clips(st)[0] if _spine_clips(st) else None)
    if not target:
        print("SKIP  no clip with a handle to select")
        return 0, 1
    kind = "connected clip" if candidates else "spine clip"
    print(f"target: {kind} {target.get('name')!r} handle={target.get('handle')} lane={target.get('effectiveLane', target.get('lane', 0))}")

    r = rpc("timeline.selectItems", {"handles": [target["handle"]], "mode": "replace"})
    if "error" in r:
        print(f"FAIL  selectItems: {r['error']}")
        return 1, 1
    got = [s.get("handle") for s in (r.get("selected") or [])]
    print(f"readback: selected={got} matchesRequest={r.get('matchesRequest')} selector={r.get('selector')} "
          f"unresolved={r.get('unresolved')} rejected={r.get('rejected')}")
    if target["handle"] in got and r.get("matchesRequest") is True and len(got) == 1:
        print("OK    selection readback contains the target and matches the request")
    else:
        fails += 1
        print("FAIL  selection readback does not match (see above)")

    # also prove that a marker handle is rejected, not selected
    markers = st.get("markers") or []
    if markers and markers[0].get("handle"):
        rm = rpc("timeline.selectItems", {"handles": [markers[0]["handle"]], "mode": "add"})
        rej = [x.get("handle") for x in (rm.get("rejected") or [])]
        if markers[0]["handle"] in rej:
            print(f"OK    marker handle {markers[0]['handle']} rejected: {rm['rejected'][0].get('reason')}")
        else:
            fails += 1
            print(f"FAIL  marker handle {markers[0]['handle']} was not rejected: {json.dumps(rm)[:200]}")

    # restore
    rr = rpc("timeline.selectItems", {"handles": previous, "mode": "replace"})
    restored = [s.get("handle") for s in (rr.get("selected") or [])]
    if set(restored) == set(previous):
        print(f"OK    previous selection restored ({len(previous)} item(s))")
    else:
        fails += 1
        print(f"FAIL  restore mismatch: wanted {previous}, got {restored} ({rr.get('error', '')})")
    return fails, 1


def _marker_count():
    gm = rpc("timeline.getMarkers")
    return gm.get("markerCount") if "error" not in gm else None


def edit_check(st):
    section("timeline.beginEdit / endEdit grouping (adds 2 markers, then undoes)")
    clips = _spine_clips(st)
    if not clips:
        print("SKIP  no spine clip to put markers on")
        return 0, 1
    baseline = _marker_count()
    if baseline is None:
        print("FAIL  cannot read marker count")
        return 1, 1
    c = clips[0]
    s, e = secs(c, "startTime"), secs(c, "endTime")
    t1 = s + (e - s) * 0.25
    t2 = s + (e - s) * 0.75
    print(f"baseline markers={baseline}; adding at {t1:.3f}s and {t2:.3f}s inside {c.get('name')!r}")

    b = rpc("timeline.beginEdit", {"name": "SpliceKit check"})
    print(f"beginEdit -> {json.dumps(b)[:200]}")
    if "error" in b:
        return 1, 1
    a = rpc("timeline.addMarkers", {"markers": [
        {"time": t1, "name": "SpliceKit check 1"}, {"time": t2, "name": "SpliceKit check 2"}]})
    print(f"addMarkers -> {json.dumps(a)[:200]}")
    en = rpc("timeline.endEdit", {"name": "SpliceKit check"})
    print(f"endEdit -> {json.dumps(en)[:200]}")

    fails = 0
    after_add = _marker_count()
    if after_add == baseline + 2:
        print(f"OK    markers after add = {after_add} (baseline + 2)")
    else:
        fails += 1
        print(f"FAIL  markers after add = {after_add}, expected {baseline + 2}")

    u = rpc("timeline.action", {"action": "undo"})
    print(f"undo -> {json.dumps(u)[:200]}")
    after_undo = _marker_count()
    if after_undo == baseline:
        print(f"OK    ONE undo removed both markers -> grouped as one undoable action "
              f"({u.get('actionName', '?')!r})")
    elif after_undo == baseline + 1:
        fails += 1
        print(f"FAIL  one undo removed only one marker -> NOT grouped (undo name {u.get('actionName', '?')!r})")
    else:
        fails += 1
        print(f"FAIL  markers after one undo = {after_undo} (baseline {baseline})")

    tries = 0
    while after_undo is not None and after_undo > baseline and tries < 4:
        u = rpc("timeline.action", {"action": "undo"})
        after_undo = _marker_count()
        tries += 1
        print(f"extra undo #{tries} ({u.get('actionName', u.get('error', '?'))!r}) -> markers={after_undo}")
    print(f"final markers={after_undo} vs baseline={baseline}: {'OK' if after_undo == baseline else 'MISMATCH'}")
    if after_undo != baseline:
        fails += 1
    return fails, 1


def trim_check(st):
    section("timeline.trimClip (ripple-trims last spine clip end by one frame, then undoes)")
    clips = _spine_clips(st)
    if not clips:
        print("SKIP  no spine clip to trim")
        return 0, 0
    c = clips[-1]
    frame = _frame_seconds(st)
    half = frame / 2.0
    start0, end0 = secs(c, "startTime"), secs(c, "endTime")
    print(f"target: {c.get('name')!r} handle={c.get('handle')} range=[{start0:.4f} .. {end0:.4f}] frame={frame:.5f}s")

    dry = rpc("timeline.trimClip", {"handle": c["handle"], "edge": "end", "deltaSeconds": -frame, "dryRun": True})
    print(f"dry run -> {json.dumps(dry)[:300]}")
    if "error" in dry:
        print(f"FAIL  dry run refused: {dry['error']}")
        return 1, 1
    fails = 0
    if abs(dry.get("before", {}).get("end", -1) - end0) > half:
        fails += 1
        print("FAIL  dry-run 'before' does not match the snapshot's clip end")

    real = rpc("timeline.trimClip", {"handle": c["handle"], "edge": "end", "deltaSeconds": -frame})
    print(f"trim -> {json.dumps(real)[:400]}")
    after_end = (real.get("after") or {}).get("end")
    if real.get("status") == "ok" and after_end is not None and abs((end0 - after_end) - frame) <= half:
        print(f"OK    end moved {end0:.4f} -> {after_end:.4f} (about one frame), status ok")
    else:
        fails += 1
        print(f"FAIL  status={real.get('status')} end {end0:.4f} -> {after_end} error={real.get('error')}")

    changed = after_end is not None and abs(after_end - end0) > half
    if real.get("status") == "ok" or changed:
        u = rpc("timeline.action", {"action": "undo"})
        print(f"undo -> {json.dumps(u)[:200]}")
    else:
        print("SKIP  undo: the trim did not change the clip, nothing to revert")
    st2 = rpc("timeline.getDetailedState")
    back = None
    for i in (st2.get("items") or []):
        if i.get("handle") == c["handle"]:
            back = secs(i, "endTime")
    if back is None:
        # handle may have been re-issued; match by start time
        for i in _spine_clips(st2):
            if abs(secs(i, "startTime") - start0) <= half:
                back = secs(i, "endTime")
    if back is not None and abs(back - end0) <= half:
        print(f"OK    after undo the clip end is back at {back:.4f} (original {end0:.4f})")
    else:
        fails += 1
        print(f"FAIL  after undo the clip end is {back} (original {end0:.4f})")
    return fails, 1


# ── 5b. browser.placeClip: a range of a browser clip as a connect edit, then undo ──

def _browser_clip_for_place(min_seconds=2.0):
    """First browser clip at least `min_seconds` long, from browser.listClips."""
    r = rpc("browser.listClips")
    if "error" in r:
        print(f"SKIP  browser.listClips: {r['error']}")
        return None
    for c in r.get("clips") or []:
        dur = (c.get("duration") or {}).get("seconds")
        if isinstance(dur, (int, float)) and dur >= min_seconds:
            return c
    print(f"SKIP  no browser clip at least {min_seconds:.0f}s long among {len(r.get('clips') or [])} clip(s)")
    return None


def place_check(st):
    section("browser.placeClip (connect a 1 s range of a browser clip at the playhead, verify, undo)")
    src = _browser_clip_for_place()
    if not src:
        return 0, 0
    spine = _spine_clips(st)
    if not spine:
        print("SKIP  no spine clip to connect to (an empty primary storyline would make FCP add a gap)")
        return 0, 0
    frame = _frame_seconds(st)
    half = frame / 2.0
    dur = (src.get("duration") or {}).get("seconds")
    print(f"source: {src.get('name')!r} handle={src.get('handle')} duration={dur:.3f}s frame={frame:.5f}s")
    fails = 0

    # Dry runs of every edit type: resolution only, nothing changes.
    for edit in ("append", "insert", "connect"):
        params = {"handle": src["handle"], "edit": edit, "inSeconds": 0.5, "outSeconds": 1.5, "dryRun": True}
        if edit != "append":
            params["atSeconds"] = 0.0
        d = rpc("browser.placeClip", params)
        print(f"dry run {edit} -> {json.dumps(d)[:260]}")
        if d.get("status") != "dry_run" or abs((d.get("source") or {}).get("durationSeconds", -1) - 1.0) > half:
            fails += 1
            print(f"FAIL  dry run {edit}: status={d.get('status')} source={d.get('source')} error={d.get('error')}")
    bad = rpc("browser.placeClip", {"handle": src["handle"], "edit": "insert", "inSeconds": 0.0,
                                    "outSeconds": dur + 5.0, "dryRun": True})
    if "error" in bad and "beyond the end of the clip" in bad["error"]:
        print(f"OK    out-of-range end refused: {bad['error']}")
    else:
        fails += 1
        print(f"FAIL  out-of-range end was not refused: {json.dumps(bad)[:200]}")

    # The real edit: a 1 s range as a connected clip in the middle of the first spine clip
    # (over an existing clip, so FCP adds no gap). A connect edit moves nothing else, so undo
    # puts the timeline back exactly.
    before = rpc("timeline.getDetailedState")
    c0 = spine[0]
    at = (secs(c0, "startTime") + secs(c0, "endTime")) / 2.0
    print(f"connect target: middle of {c0.get('name')!r} at {at:.3f}s")
    real = rpc("browser.placeClip", {"handle": src["handle"], "edit": "connect",
                                     "inSeconds": 0.5, "outSeconds": 1.5, "atSeconds": at})
    print(f"connect -> {json.dumps({k: v for k, v in real.items() if k != 'placementDebug'})[:600]}")
    placed = real.get("placed") or []
    if real.get("status") == "ok" and placed and real.get("verified"):
        p0 = placed[0]
        print(f"OK    placed {p0.get('name')!r} handle={p0.get('handle')} lane={p0.get('lane')} "
              f"[{p0.get('startSeconds')} .. {p0.get('endSeconds')}] rangeHonored={real.get('rangeHonored')} "
              f"positionVerified={real.get('positionVerified')}")
    else:
        fails += 1
        print(f"FAIL  status={real.get('status')} verified={real.get('verified')} placed={len(placed)} "
              f"rangeHonored={real.get('rangeHonored')} positionVerified={real.get('positionVerified')} "
              f"error={real.get('error')} note={real.get('note')}")

    if real.get("status") == "ok" or placed:
        u = rpc("timeline.action", {"action": "undo"})
        print(f"undo -> {json.dumps(u)[:200]}")
        after = rpc("timeline.getDetailedState")
        placed_handles = {p.get("handle") for p in placed}
        still = [c for c in (after.get("connectedItems") or []) + (after.get("items") or [])
                 if c.get("handle") in placed_handles]
        n_before = len(before.get("connectedItems") or []) + len(before.get("items") or [])
        n_after = len(after.get("connectedItems") or []) + len(after.get("items") or [])
        if not still and n_after == n_before:
            print(f"OK    after undo the placed clip is gone and the item count is back to {n_before}")
        else:
            fails += 1
            print(f"FAIL  after undo: placed still present={len(still)} items before={n_before} after={n_after}")
    return fails, 1


# ── 6/7. clip info (read-only) and viewer frame (moves playhead, restored) ────

CLIP_INFO_FRAME_PATH = "/tmp/splicekit_clip_info_frame.jpg"
VIEWER_FRAME_PATH = "/tmp/splicekit_clip_viewer_frame.jpg"


def _first_media_clip(st):
    """First spine clip that is a video or audio clip (not a gap, generator or title)."""
    for c in _spine_clips(st):
        cls = str(c.get("class", ""))
        if "Gap" in cls or "Generator" in cls or "Title" in cls:
            continue
        if c.get("hasVideo") or c.get("hasAudio") or "MediaComponent" in cls:
            return c
    return None


def _write_frame(frame, path):
    import base64
    try:
        data = base64.b64decode(frame.get("base64") or "")
    except Exception as e:  # noqa: BLE001
        print(f"WARN  frame base64 did not decode: {e}")
        return False
    if not data:
        print("WARN  frame base64 is empty")
        return False
    with open(path, "wb") as f:
        f.write(data)
    print(f"      frame written to {path} ({len(data)} bytes) -- open it and check it is a frame of this clip")
    return True


def audio_check(st):
    section("timeline.getAudioLevels (levels of the first spine clip with audio, then the whole timeline)")
    spine = [c for c in _spine_clips(st) if c.get("hasAudio") and not c.get("isCompound")]
    if not spine:
        print("SKIP  no primary-storyline clip with audio (compound clips are skipped: no single source file)")
        return 0, 0
    c0 = spine[0]
    start, end = secs(c0, "startTime"), secs(c0, "endTime")
    fails = 0
    t0 = time.time()
    one = rpc("timeline.getAudioLevels", {"handle": c0["handle"], "sliceSeconds": 0.05}, timeout=180)
    took = time.time() - t0
    if "error" in one:
        print(f"FAIL  {one['error']}")
        if "helper not found" in one["error"]:
            print("      the audio-levels helper is missing: re-run `make install` (step 3c builds it) or "
                  "`swiftc -O -o build/audio-levels tools/audio-levels.swift`")
        return 1, 1
    clips = one.get("clips") or []
    entry = clips[0] if clips else {}
    stats = entry.get("stats") or {}
    slices = entry.get("slices") or {}
    print(f"clip {c0.get('name')!r} handle={c0['handle']} [{start:.3f} .. {end:.3f}] -> "
          f"{json.dumps({k: v for k, v in entry.items() if k not in ('slices',)})[:700]}")
    print(f"took {took:.2f}s; helper {one.get('helper')}")
    if entry.get("error") or entry.get("skipped"):
        fails += 1
        print(f"FAIL  clip not analysed: {entry.get('error') or entry.get('skipped')}")
        return fails, 1
    n = slices.get("count") or 0
    peak = slices.get("peakDb") or []
    rms = slices.get("rmsDb") or []
    if n == 0 or len(peak) != n or len(rms) != n:
        fails += 1
        print(f"FAIL  slice arrays: count={n} peak={len(peak)} rms={len(rms)}")
    else:
        print(f"OK    {n} slices of {slices.get('sliceSeconds')}s starting at {slices.get('startSeconds')}s")
    if any(not (-100.0 <= v <= 6.0) for v in peak + rms):
        fails += 1
        print("FAIL  a level is outside -100..+6 dBFS")
    if any(r > p + 0.11 for p, r in zip(peak, rms)):
        fails += 1
        print("FAIL  an RMS value exceeds its slice's peak (impossible for a real signal)")
    frame = _frame_seconds(st)
    s0 = slices.get("startSeconds")
    slice_s = slices.get("sliceSeconds") or 0.05
    if isinstance(s0, (int, float)) and abs(s0 - start) > max(frame, slice_s):
        fails += 1
        print(f"FAIL  slices start at {s0:.3f}s but the clip starts at {start:.3f}s")
    covered = slice_s * n
    if abs(covered - (end - start)) > 0.25 + 2 * slice_s:
        fails += 1
        print(f"FAIL  slices cover {covered:.3f}s but the clip lasts {end - start:.3f}s")
    else:
        print(f"OK    slices cover {covered:.3f}s of a {end - start:.3f}s clip; peak max {stats.get('maxPeakDb')} dB "
              f"at {stats.get('maxPeakAtSeconds')}s; head silence {stats.get('headSilenceSeconds')}s, "
              f"tail silence {stats.get('tailSilenceSeconds')}s; clipped {stats.get('clippedSlices')}")
    if entry.get("retimed") not in (True, False, "unknown"):
        fails += 1
        print(f"FAIL  retimed flag has an unexpected value: {entry.get('retimed')!r}")
    else:
        print(f"note  retimed={entry.get('retimed')!r} (selector {entry.get('retimeSelector', 'none')})")

    # The whole timeline, summary only: every clip with audio, plus the cuts.
    t0 = time.time()
    allc = rpc("timeline.getAudioLevels", {"includeSlices": False}, timeout=600)
    took = time.time() - t0
    if "error" in allc:
        fails += 1
        print(f"FAIL  whole timeline: {allc['error']}")
        return fails, 1
    analysed = allc.get("analyzedCount", 0)
    errors = [c for c in (allc.get("clips") or []) if c.get("error")]
    print(f"whole timeline in {took:.2f}s: considered {allc.get('clipCount')}, analysed {analysed}, "
          f"skipped {len(allc.get('skipped') or [])}, clip errors {len(errors)}, cuts {len(allc.get('cuts') or [])}")
    for c in errors[:5]:
        print(f"      error on {c.get('handle')} {c.get('name')!r}: {c.get('error')}")
    for cut in (allc.get("cuts") or [])[:8]:
        print(f"      cut {cut.get('atSeconds')}s: {json.dumps({k: v for k, v in cut.items() if k != 'atSeconds'})[:220]}")
    if analysed < 1:
        fails += 1
        print("FAIL  no clip analysed on the whole timeline")
    if errors:
        fails += 1
        print(f"FAIL  {len(errors)} clip(s) failed to analyse")
    return fails, 1


def clip_info_check(st):
    section("timeline.getClipInfo (read-only: never moves the playhead or selection)")
    c = _first_media_clip(st)
    if not c:
        print("SKIP  no video/audio spine clip to inspect")
        return 0, 0, 0
    s0, e0 = secs(c, "startTime"), secs(c, "endTime")
    print(f"target: {c.get('name')!r} handle={c.get('handle')} class={c.get('class')} range=[{s0:.3f} .. {e0:.3f}]")
    pos_before = rpc("playback.getPosition").get("seconds")
    r = rpc("timeline.getClipInfo", {"handle": c["handle"]}, timeout=60)
    if "error" in r:
        print(f"FAIL  getClipInfo: {r['error']}")
        return 1, 1, 0
    fails = warns = 0
    tl = r.get("timeline") or {}
    print(f"kind={r.get('kind')!r} (SpliceKit classification) name={r.get('name')!r} lane={r.get('lane')} "
          f"primary={r.get('onPrimaryStoryline')} enabled={r.get('enabled')} selected={r.get('selected')} "
          f"hasVideo={r.get('hasVideo')} hasAudio={r.get('hasAudio')} "
          f"timeline=[{tl.get('start')} .. {tl.get('end')}] roles={json.dumps(r.get('roles'))}")
    if abs((tl.get("start") or 0) - s0) > 0.01 or abs((tl.get("end") or 0) - e0) > 0.01:
        warns += 1
        print("WARN  timeline range differs from the getDetailedState snapshot")
    if r.get("notes"):
        print(f"notes={r['notes']!r}")

    sm = r.get("sourceMedia")
    if isinstance(sm, dict):
        print(f"source media: {sm.get('path')}\n      exists={sm.get('exists')} representation={sm.get('representation')} "
              f"urlSource={sm.get('urlSource')}\n      sourceStart={sm.get('sourceStart')} via {sm.get('sourceStartSelector')}; "
              f"mediaOrigin={sm.get('mediaOrigin')} via {sm.get('mediaOriginSelector')}; "
              f"file=[{sm.get('fileStart')} .. {sm.get('fileEnd')}]")
        if not sm.get("exists"):
            warns += 1
            print("WARN  the source media file does not exist on disk (offline media?)")
    elif r.get("sourceMediaError"):
        print(f"source media: {r['sourceMediaError']}")
    else:
        fails += 1
        print("FAIL  response has neither sourceMedia nor sourceMediaError")

    effects = r.get("effects") or []
    print(f"effects: {r.get('effectCount', len(effects))} " +
          json.dumps([e.get("name") or e.get("class") for e in effects])[:200] +
          (f"  effectsError={r.get('effectsError')}" if r.get("effectsError") else ""))
    if isinstance(r.get("title"), dict):
        t = r["title"]
        print(f"title text: {t.get('text')!r} font={t.get('fontFamily') or t.get('fontName')} size={t.get('fontSize')} "
              f"channels={t.get('channelCount')}")
    else:
        print("title text: (none)")
    print(f"markers on clip: {r.get('markerCount', len(r.get('markers') or []))}")
    tr = r.get("transcript") or {}
    print(f"transcript: available={tr.get('available')} status={tr.get('status')} wordsInClip={tr.get('wordCount')} "
          f"matchedByHandle={tr.get('matchedByHandle')} truncated={tr.get('truncated')} "
          f"text={str(tr.get('text', ''))[:120]!r}")

    frame = r.get("frame")
    if isinstance(frame, dict):
        print(f"frame: {frame.get('width')}x{frame.get('height')} {frame.get('format')} {frame.get('bytes')} bytes "
              f"timelineTime={frame.get('timelineTime')} sourceTime={frame.get('sourceTime')} "
              f"mediaOrigin={frame.get('mediaOrigin')} fileTime={frame.get('fileTime')} "
              f"actualFileTime={frame.get('actualFileTime')}")
        mid = (s0 + e0) / 2.0
        if abs((frame.get("timelineTime") or 0) - mid) > 0.01:
            warns += 1
            print(f"WARN  frame timelineTime is not the clip midpoint ({mid:.3f})")
        if not _write_frame(frame, CLIP_INFO_FRAME_PATH):
            warns += 1
    elif r.get("frameError"):
        warns += 1
        print(f"WARN  frameError: {r['frameError']}  request={json.dumps(r.get('frameRequest'))}")
    else:
        print("frame: (not requested)")
    print(f"timings={json.dumps(r.get('timings'))}")

    pos_after = rpc("playback.getPosition").get("seconds")
    if isinstance(pos_before, (int, float)) and isinstance(pos_after, (int, float)):
        if abs(pos_after - pos_before) < 1e-6:
            print(f"OK    playhead unchanged at {pos_after:.3f}s")
        else:
            fails += 1
            print(f"FAIL  playhead moved {pos_before:.3f} -> {pos_after:.3f} during a read-only call")
    if fails == 0:
        print("OK    getClipInfo returned clip information" + (f" with {warns} warning(s)" if warns else ""))
    return fails, 1, warns


def viewer_frame_check(st):
    section("timeline.captureClipFrame (CHANGES STATE: moves the playhead, restored)")
    clips = _spine_clips(st)
    c = _first_media_clip(st) or (clips[0] if clips else None)
    if not c:
        print("SKIP  no spine clip to capture")
        return 0, 0
    frame_s = _frame_seconds(st)
    half = frame_s / 2.0
    pos0 = rpc("playback.getPosition").get("seconds")
    print(f"target: {c.get('name')!r} handle={c.get('handle')} playhead before={pos0}")
    r = rpc("timeline.captureClipFrame", {"handle": c["handle"]}, timeout=60)
    fails = 0
    if "error" in r and r.get("status") != "failed":
        print(f"FAIL  captureClipFrame: {r['error']}")
        return 1, 1
    print(f"status={r.get('status')} timelineTime={r.get('timelineTime')} playheadBefore={r.get('playheadBefore')} "
          f"playheadAtCapture={r.get('playheadAtCapture')} playheadAfter={r.get('playheadAfter')} "
          f"playheadRestored={r.get('playheadRestored')} path={r.get('path')} capture={json.dumps(r.get('capture'))}")
    if r.get("status") != "ok":
        fails += 1
        print(f"FAIL  status={r.get('status')} failure={r.get('failure') or r.get('error')}")
    if r.get("playheadRestored") is not True:
        fails += 1
        print("FAIL  playheadRestored is not true")
    tt = r.get("timelineTime")
    at = r.get("playheadAtCapture")
    if isinstance(tt, (int, float)) and isinstance(at, (int, float)) and abs(tt - at) > half + 1e-6:
        fails += 1
        print(f"FAIL  the playhead at capture ({at:.3f}) was not at the requested frame time ({tt:.3f})")
    pos1 = rpc("playback.getPosition").get("seconds")
    if isinstance(pos0, (int, float)) and isinstance(pos1, (int, float)):
        if abs(pos1 - pos0) <= half + 1e-6:
            print(f"OK    playhead really is back at {pos1:.3f}s (was {pos0:.3f}s)")
        else:
            fails += 1
            print(f"FAIL  playhead is at {pos1:.3f}s, was {pos0:.3f}s -- seeking back")
            rpc("playback.seekToTime", {"seconds": pos0})
    frame = r.get("frame")
    if isinstance(frame, dict):
        print(f"frame: {frame.get('width')}x{frame.get('height')} {frame.get('format')} {frame.get('bytes')} bytes source={frame.get('source')}")
        _write_frame(frame, VIEWER_FRAME_PATH)
    else:
        fails += 1
        print("FAIL  no frame in the response")
    if fails == 0:
        print("OK    Viewer frame captured and playhead restored")
    return fails, 1


def main():
    global HOST, PORT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--cross-check", action="store_true", help="seek + selectClipInLane comparison")
    ap.add_argument("--select-check", action="store_true",
                    help="CHANGES STATE (reverted): select one clip by handle via timeline.selectItems, "
                         "verify readback, restore previous selection")
    ap.add_argument("--edit-check", action="store_true",
                    help="CHANGES STATE (reverted): beginEdit + addMarkers x2 + endEdit, then undo; "
                         "reports whether one undo removed both markers")
    ap.add_argument("--trim-check", action="store_true",
                    help="CHANGES STATE (reverted): ripple-trim last spine clip end by one frame via "
                         "timeline.trimClip, verify, undo, verify")
    ap.add_argument("--place-check", action="store_true",
                    help="CHANGES STATE (reverted): browser.placeClip dry runs for append/insert/connect, an "
                         "out-of-range refusal, then a real connect edit of a 1 s range of the first browser "
                         "clip at the playhead, verified (placed, rangeHonored, positionVerified), then undo")
    ap.add_argument("--audio-check", action="store_true",
                    help="timeline.getAudioLevels on the first spine clip with audio, then the whole timeline (read-only)")
    ap.add_argument("--clip-info-check", action="store_true",
                    help="READ-ONLY: timeline.getClipInfo on the first video/audio spine clip; prints source "
                         "media, source start / media origin / file time, effects, title text, transcript, "
                         "and writes the frame to " + CLIP_INFO_FRAME_PATH)
    ap.add_argument("--viewer-frame-check", action="store_true",
                    help="CHANGES STATE (moves the playhead, restored): timeline.captureClipFrame on that "
                         "clip, verifies playheadRestored, writes " + VIEWER_FRAME_PATH)
    ap.add_argument("--json", metavar="PATH", help="write every raw RPC response to this file")
    args = ap.parse_args()
    HOST, PORT = args.host, args.port

    check_bridge()
    check_vocabulary()
    snap = check_snapshot()
    verdict = []
    if snap:
        st, conn, marks, warns = snap
        verdict.append(f"connected={len(conn)} markers={len(marks)} warnings={warns}")
        if args.cross_check:
            checked, mismatches = cross_check(conn)
            verdict.append(f"cross-check: {checked} lanes checked, {mismatches} mismatches")
        if args.select_check:
            fails, ran = select_check(st, conn)
            verdict.append(f"select-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}")
        if args.edit_check:
            fails, ran = edit_check(st)
            verdict.append(f"edit-check: {'not run' if not ran else ('OK (grouped)' if fails == 0 else f'{fails} failure(s)')}")
        if args.trim_check:
            fails, ran = trim_check(st)
            verdict.append(f"trim-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}")
        if args.place_check:
            fails, ran = place_check(st)
            verdict.append(f"place-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}")
        if args.audio_check:
            fails, ran = audio_check(st)
            verdict.append(f"audio-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}")
        if args.clip_info_check:
            fails, ran, ci_warns = clip_info_check(st)
            verdict.append(f"clip-info-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}"
                           + (f" ({ci_warns} warning(s))" if ran and ci_warns else ""))
        if args.viewer_frame_check:
            fails, ran = viewer_frame_check(st)
            verdict.append(f"viewer-frame-check: {'not run' if not ran else ('OK' if fails == 0 else f'{fails} failure(s)')}")
    section("Verdict")
    print("; ".join(verdict) if verdict else "no project open — vocabulary section is still valid evidence")
    failed = any(("failure" in v) or ("mismatches" in v and not v.endswith("0 mismatches")) for v in verdict)
    print("Paste this whole output back for review.")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(RAW, f, indent=2, default=str)
        print(f"raw responses written to {args.json}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
