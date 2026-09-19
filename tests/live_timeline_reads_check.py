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

Usage:
    python3 tests/live_timeline_reads_check.py                # read-only report
    python3 tests/live_timeline_reads_check.py --cross-check  # also verify lanes/times
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
    res = resp.get("result", resp)
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


def main():
    global HOST, PORT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--cross-check", action="store_true", help="seek + selectClipInLane comparison")
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
    section("Verdict")
    print("; ".join(verdict) if verdict else "no project open — vocabulary section is still valid evidence")
    print("Paste this whole output back for review.")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(RAW, f, indent=2, default=str)
        print(f"raw responses written to {args.json}")


if __name__ == "__main__":
    main()
