"""Tools: seek, timeline contents, markers, selection, range, batch export, verify."""

import time

from ..registry import DESTRUCTIVE, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge


@splicekit_tool("seek_to_time", LOCAL_IDEMPOTENT)
def seek_to_time(seconds: float) -> str:
    """Use this tool to jump the playhead to an exact time before another operation.

    Args:
        seconds: Time in seconds (e.g. 3.5 = 3 seconds 500ms)

    This is much faster than stepping frames. Use this for all
    time-based positioning before blade, marker, or other operations.
    """
    return _call_or_error("playback.seekToTime", seconds=seconds)


# ============================================================
# Timeline State (structured)
# ============================================================
# Read the timeline's current contents as structured data.
# This is how the AI "sees" what's in the project.

def _time_seconds(container, key):
    """Read container[key]["seconds"] from a bridge CMTime dict, or None if absent."""
    if not isinstance(container, dict):
        return None
    t = container.get(key)
    if isinstance(t, dict) and isinstance(t.get("seconds"), (int, float)):
        return float(t["seconds"])
    return None


def _fmt_secs(value, width=8):
    """Right-aligned seconds column ('   1.50s') or '?' when unknown."""
    if value is None:
        return f"{'?':>{width}}"
    return f"{value:>{width - 1}.2f}s"


def _s3(value) -> str:
    """Seconds with three decimals for the placement report, or '?' when absent."""
    return f"{value:.3f}s" if isinstance(value, (int, float)) and not isinstance(value, bool) else "?"


def _connected_lane(c):
    """Lane relative to the spine. The bridge reports `effectiveLane` (nested anchors
    have lanes relative to their parent); fall back to the raw `lane`."""
    lane = c.get("effectiveLane")
    if lane is None:
        lane = c.get("lane", 0)
    return lane or 0


def _container_tag(item) -> str:
    """Marker for a clip that is a container of clips (FCP's isReferenceClip / isCompoundClip flags)."""
    if not isinstance(item, dict):
        return ""
    if item.get("isReferenceClip"):
        return "  [reference clip]"
    if item.get("isCompound"):
        return "  [compound clip]"
    if item.get("isMulticamClip"):
        return "  [multicam clip]"
    return ""


def _connected_table_lines(connected):
    """Render connectedItems from timeline.getDetailedState as a table,
    sorted by start time then lane."""
    if not connected:
        return []
    ordered = sorted(
        connected,
        key=lambda c: (
            _time_seconds(c, "startTime") is None,
            _time_seconds(c, "startTime") or 0.0,
            _connected_lane(c),
        ),
    )
    lines = [
        f"{'Lane':>4} {'Class':<30} {'Name':<20} {'Start':>8} {'End':>8} {'Duration':>10} {'Parent':>6} {'Sel':>4} {'Handle'}",
        "-" * 118,
    ]
    for c in ordered:
        dur_s = _time_seconds(c, "duration")
        lines.append(
            f"{_connected_lane(c):>4} "
            f"{str(c.get('class', '?')):<30} "
            f"{str(c.get('name', ''))[:20]:<20} "
            f"{_fmt_secs(_time_seconds(c, 'startTime'))} "
            f"{_fmt_secs(_time_seconds(c, 'endTime'))} "
            f"{(dur_s if dur_s is not None else 0.0):>9.3f}s "
            f"{c.get('parentIndex', '?'):>6} "
            f"{'*' if c.get('selected') else ' ':>4} "
            f"{c.get('handle', '')}{_container_tag(c)}"
        )
    return lines


def _marker_table_lines(markers):
    """Render marker dicts (timeline.getDetailedState / timeline.getMarkers) as a table
    sorted by time. The Completed column only appears when some marker reports `completed`."""
    if not markers:
        return []
    ordered = sorted(
        markers,
        key=lambda m: (_time_seconds(m, "time") is None, _time_seconds(m, "time") or 0.0),
    )
    has_done = any("completed" in m for m in markers)
    header = f"{'Time':>9} {'Kind':<9} {'Name':<30}"
    if has_done:
        header += f" {'Completed':<9}"
    header += " Handle"
    lines = [header, "-" * (len(header) + 8)]
    for m in ordered:
        secs = _time_seconds(m, "time")
        time_str = f"{secs:>8.3f}s" if secs is not None else f"{'?':>9}"
        row = f"{time_str} {str(m.get('kind', '?')):<9} {str(m.get('name', ''))[:30]:<30}"
        if has_done:
            done = m.get("completed")
            done_str = "" if done is None else ("yes" if done else "no")
            row += f" {done_str:<9}"
        row += f" {m.get('handle', '')}"
        lines.append(row)
    return lines


@splicekit_tool("get_timeline_clips", READ)
def get_timeline_clips(limit: int = 100, include_connected: bool = True,
                       include_markers: bool = True) -> str:
    """Get a structured view of everything in the current timeline.

    Returns sequence name, playhead time, duration, then three sections:

    1. Primary storyline (spine) items: index, class, name, start/end, duration,
       lane, selected, handle, and after the handle a [reference clip] /
       [compound clip] / [multicam clip] tag for a clip that is a container of clips
       (FCP's own isReferenceClip / isCompoundClip flags; the multicam flag is a
       SpliceKit probe), with a legend line at the end.
    2. Connected clips -- everything anchored to spine clips: titles, B-roll,
       captions and SpliceKit-generated caption titles, music/SFX on negative lanes, and the contents of
       connected storylines. Columns: lane (relative to the spine; positive is
       above, negative below), class, name, start, end, duration, parent (spine
       index the clip is anchored to), selected, handle.
    3. Markers: time, kind (FCP calls this the marker type: standard, todo =
       to-do item, chapter; keyword and analysis are keyword ranges and analysis
       keywords, which FCP's Timeline Index lists as tags), name, completed
       (to-do items, when readable), handle. Marker handles work with
       timeline.directAction changeMarkerName / markMarkerCompleted / removeMarker.

    Args:
        limit: max spine items to list (connected clips/markers cover ALL spine items)
        include_connected: walk anchoredItems for connected clips (default True)
        include_markers: query markers via markersInTimeRange + anchored walk (default True)

    Handles can be used with get_object_property() for deeper inspection.
    Use list_markers() for a markers-only view with a kind filter.
    """
    r = bridge.call("timeline.getDetailedState", limit=limit,
                    include_connected=include_connected,
                    include_markers=include_markers)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Build a human-readable table -- the AI reads this to understand the timeline
    lines = []
    lines.append(f"Sequence: {r.get('sequenceName', '?')}")
    pt = r.get("playheadTime", {})
    lines.append(f"Playhead: {pt.get('seconds', 0):.3f}s")
    dur = r.get("duration", {})
    lines.append(f"Duration: {dur.get('seconds', 0):.3f}s")
    lines.append(f"Items: {r.get('itemCount', 0)}")
    lines.append(f"Selected: {r.get('selectedCount', 0)}")
    if include_connected:
        lines.append(f"Connected: {r.get('connectedCount', 0)}")
    if include_markers:
        lines.append(f"Markers: {r.get('markerCount', 0)}")
    if r.get("connectedItemsError"):
        lines.append(f"WARNING connected clips: {r['connectedItemsError']}")
    if r.get("markersError"):
        lines.append(f"WARNING markers: {r['markersError']}")

    items = r.get("items", [])
    if items:
        # Two table formats: with start/end times if available, otherwise just duration + lane
        has_pos = any("startTime" in i for i in items)
        if has_pos:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Start':>8} {'End':>8} {'Duration':>10} {'Sel':>4} {'Handle'}")
            lines.append("-" * 110)
        else:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Duration':>10} {'Lane':>5} {'Sel':>4} {'Handle'}")
            lines.append("-" * 95)
        for item in items:
            dur_s = item.get("duration", {}).get("seconds", 0)
            if has_pos:
                start_s = item.get("startTime", {}).get("seconds", 0)
                end_s = item.get("endTime", {}).get("seconds", 0)
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{start_s:>7.2f}s "
                    f"{end_s:>7.2f}s "
                    f"{dur_s:>9.3f}s "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}{_container_tag(item)}"
                )
            else:
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{dur_s:>9.3f}s "
                    f"{item.get('lane', 0):>5} "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}{_container_tag(item)}"
                )

    if include_connected:
        connected = r.get("connectedItems", []) or []
        if connected:
            lines.append("\nConnected clips (anchored to spine items):")
            lines.extend(_connected_table_lines(connected))
            if r.get("connectedTruncated"):
                lines.append("(connected list truncated -- raise connected_limit on timeline.getDetailedState)")

    if include_markers:
        markers = r.get("markers", []) or []
        if markers:
            lines.append("\nMarkers:")
            lines.extend(_marker_table_lines(markers))
            if r.get("markersTruncated"):
                lines.append(f"(showing {len(markers)} of {r.get('markerTotal', '?')} markers)")

    tagged = [i for i in items if _container_tag(i)]
    if include_connected:
        tagged += [c for c in (r.get("connectedItems") or []) if _container_tag(c)]
    if tagged:
        lines.append("\n[reference clip] = FCP's own isReferenceClip flag: a compound clip (verified on 12.3), and by "
                     "the same flag a multicam or synchronized clip; isCompoundClip gives [compound clip], SpliceKit's "
                     "multicam probe [multicam clip]. One clip on the timeline whose contents are clips of their own: "
                     "get_clip_info reports no single source media file for it and get_audio_levels skips it; "
                     "timeline_action(\"openClip\") with it selected opens its own timeline.")

    return "\n".join(lines)


@splicekit_tool("list_markers", READ)
def list_markers(kind: str = "") -> str:
    """List all markers on the current timeline with time, kind, name, completion, handle.

    Markers are gathered two ways and merged: the sequence's markersInTimeRange:
    query over the whole timeline, plus markers found anchored to spine and
    connected clips. Each marker's `timeSource` in the raw RPC says which path
    resolved its time.

    Args:
        kind: optional filter -- "standard", "todo" (FCP: to-do item), "chapter",
              "keyword" or "analysis" (keyword ranges / analysis keywords, listed
              as tags in FCP's Timeline Index). FCP calls this the marker type.

    Marker handles can be passed to timeline.directAction actions
    changeMarkerName / markMarkerCompleted / removeMarker (via the `marker` param).
    """
    params = {}
    if kind:
        params["kind"] = kind
    r = bridge.call("timeline.getMarkers", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Sequence: {r.get('sequenceName', '?')}"]
    count = r.get("markerCount", 0)
    lines.append(f"Markers: {count}" + (f" (kind={kind})" if kind else ""))
    if r.get("markersError"):
        lines.append(f"WARNING markers: {r['markersError']}")

    sources = r.get("markerSources") or {}
    markers = r.get("markers", []) or []
    if markers:
        lines.append("")
        lines.extend(_marker_table_lines(markers))
        if r.get("markersTruncated"):
            lines.append(f"(showing {len(markers)} of {r.get('markerTotal', '?')} markers)")
    else:
        if sources and not sources.get("sequenceRespondsToMarkersInTimeRange", True) \
                and not sources.get("anchoredWalk", 0):
            lines.append("No markers found: the sequence does not respond to markersInTimeRange: "
                         "and no markers were found on anchored items.")
        elif kind:
            lines.append(f"No markers of kind '{kind}'.")
        else:
            lines.append("No markers found.")
    if sources:
        lines.append(
            f"Sources: markersInTimeRange={sources.get('markersInTimeRange', 0)}, "
            f"anchoredWalk={sources.get('anchoredWalk', 0)}"
        )
    return "\n".join(lines)


@splicekit_tool("get_selected_clips", READ)
def get_selected_clips() -> str:
    """Get only the currently selected clips in the timeline.
    Includes selected connected clips (titles, B-roll, music), marked with "connected": true.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    items = [i for i in r.get("items", []) if i.get("selected")]
    items += [dict(i, connected=True) for i in (r.get("connectedItems", []) or []) if i.get("selected")]
    if not items:
        return "No clips selected"
    return _fmt({"selectedCount": len(items), "items": items})


@splicekit_tool("set_timeline_range", LOCAL_IDEMPOTENT)
def set_timeline_range(start_seconds: float, end_seconds: float) -> str:
    """Set the timeline in/out range (mark in/out) to specific times in seconds.
    This positions the playhead and marks the range start and end points.
    Useful for defining export ranges or reviewing specific sections.
    """
    r = bridge.call("timeline.setRange", startSeconds=start_seconds, endSeconds=end_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if not r.get("rangeStartSet") or not r.get("rangeEndSet"):
        return (
            f"Error: failed to set timeline range "
            f"{r.get('startSeconds', start_seconds):.3f}s–"
            f"{r.get('endSeconds', end_seconds):.3f}s "
            f"(mark in: {'OK' if r.get('rangeStartSet') else 'FAILED'}, "
            f"mark out: {'OK' if r.get('rangeEndSet') else 'FAILED'})"
        )
    return (
        f"Range set: {r.get('startSeconds', 0):.3f}s - {r.get('endSeconds', 0):.3f}s\n"
        f"Mark in: OK\n"
        f"Mark out: OK"
    )


@splicekit_tool("batch_export", DESTRUCTIVE, title="Batch Export Clips")
def batch_export(scope: str = "all", folder: str = "") -> str:
    """Batch export every clip from the active timeline as individual files.

    All clips are exported automatically with effects and color grading baked in.

    `folder` is required. Without it the bridge would have to open a folder picker and
    wait for someone to answer it, which parks Final Cut Pro's main thread and leaves the
    export half-run — a save/open panel cannot be confirmed over the bridge at all, only
    cancelled. Pass the path you want instead; the folder is created if it is not there.

    Args:
        scope: "all" exports every clip, "selected" exports only selected clips.
        folder: Output folder path. Required. Created if it does not exist.
    """
    params = {"scope": scope}
    if folder:
        params["folder"] = folder
    r = bridge.call("timeline.batchExport", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "cancelled":
        return "Batch export cancelled by user."

    lines = [
        f"Batch export: {r.get('exported', 0)}/{r.get('total', 0)} clips queued",
        f"Folder: {r.get('folder', '?')}",
    ]
    clips = r.get("clips", [])
    for c in clips:
        start = c.get("startTime", {}).get("seconds", 0)
        end = c.get("endTime", {}).get("seconds", 0)
        lines.append(f"  [{c.get('status', '?')}] {c.get('name', '?')} ({start:.2f}s - {end:.2f}s)")
    return "\n".join(lines)


@splicekit_tool("verify_action", READ, title="Verify Timeline Action")
def verify_action(description: str = "") -> str:
    """Capture timeline state for before/after verification.

    Call before an action, then after, and compare the snapshots.
    Returns: playhead_seconds, item_count, selected_count, timestamp.

    Args:
        description: A free-text label echoed back in the snapshot, so two snapshots can
            be told apart in a transcript ("before blade", "after blade"). It has no
            effect on what is captured and may be left out.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        # Fallback to basic state
        r = bridge.call("timeline.getState")
        if _err(r):
            return f"Error: {r.get('error', r)}"
    return _fmt({
        "playhead_seconds": r.get("playheadTime", {}).get("seconds", 0),
        "item_count": r.get("itemCount", 0),
        "selected_count": r.get("selectedCount", 0),
        "connected_count": r.get("connectedCount", 0),
        "marker_count": r.get("markerCount", 0),
        "sequence_name": r.get("sequenceName", ""),
        "description": description,
        "timestamp": time.time()
    })
