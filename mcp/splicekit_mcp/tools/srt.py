"""Tools: SRT subtitles as markers."""

import re

from ..registry import LOCAL, splicekit_tool
from ..bridge import _err, bridge


@splicekit_tool("import_srt_as_markers", LOCAL)
def import_srt_as_markers(srt_content: str) -> str:
    """Import SRT subtitle content as markers in the current timeline.
    Each subtitle becomes a standard marker at the corresponding timecode.

    SRT times count from the timeline's first frame (00:00:00,000 is the start of the
    project, whatever its start timecode), so a subtitle file made for this program lines
    up; the markers land at that offset from the timeline's start.

    srt_content: SRT file content as string. Example:
      1
      00:00:05,000 --> 00:00:10,000
      Hello world

      2
      00:01:30,500 --> 00:01:35,000
      Second subtitle
    """

    # Parse SRT format: sequential blocks of "index / timestamp / text"
    blocks = re.split(r'\n\n+', srt_content.strip())
    marker_list = []

    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:  # need at least: index line, timestamp line, text line
            continue

        # We only use the start time -- FCP markers are points, not ranges
        ts_match = re.match(r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})', lines[1])
        if not ts_match:
            continue

        h, m, s, ms = int(ts_match.group(1)), int(ts_match.group(2)), int(ts_match.group(3)), int(ts_match.group(4))
        total_seconds = h * 3600 + m * 60 + s + ms / 1000.0
        text = ' '.join(lines[2:]).strip()

        marker_list.append({"time": total_seconds, "name": text, "kind": "standard"})

    if not marker_list:
        return "No valid SRT entries found"

    # SRT counts from the program's start; timeline times start at the project's start
    # timecode (00:00:30:00 puts the first frame at 30.03 s).
    state = bridge.call("timeline.getDetailedState")
    offset = 0.0
    if not _err(state):
        items = state.get("items") or []
        if items and isinstance(items[0], dict):
            start = items[0].get("startTime")
            if isinstance(start, dict):
                offset = float(start.get("seconds") or 0.0)
    for m in marker_list:
        m["time"] = round(m["time"] + offset, 6)

    # Single batch call to add all markers at once (no playhead movement needed)
    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    applied = r.get("applied", 0)
    result = f"Imported {applied}/{len(marker_list)} markers from SRT"
    failed = [m for m in r.get("markers", []) if not m.get("success")]
    if failed:
        result += f"\nFailed: {len(failed)}"
        for m in failed[:5]:
            result += f"\n  - {m['time'] - offset:.1f}s: {m.get('error', '?')}"
    return result
