"""Tools: markers and blades at a list of times."""

from ..registry import DESTRUCTIVE, LOCAL, splicekit_tool
from ..bridge import _err, bridge
from ..parsing import _parse_markers_list, _parse_seconds_list


# ============================================================
# SRT/Transcript to Markers
# ============================================================
# Bulk marker placement. The bridge handles seeking internally
# so we don't have to move the playhead for each marker.

@splicekit_tool("add_markers_at_times", LOCAL)
def add_markers_at_times(markers: str) -> str:
    """Add multiple markers at specific times in a single batch call.
    Much faster than seeking + adding markers one at a time.

    markers accepts either:
      - JSON array of marker objects, e.g.
        [{"time": 5.0, "name": "Scene 1", "kind": "standard"},
         {"time": 15.5, "name": "Chapter 1", "kind": "chapter"}]
      - Comma-separated seconds for plain standard markers, e.g. "5.0, 12.0"

    kind (JSON form only): "standard" (default), "chapter", or "todo"

    Returns count of markers successfully added.
    """
    marker_list = _parse_markers_list(markers)

    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Added {r.get('applied', 0)}/{r.get('count', 0)} markers"]
    for m in r.get("markers", []):
        status = "OK" if m.get("success") else f"FAILED: {m.get('error', '?')}"
        lines.append(f"  {m['time']:.2f}s -> {status}")
    return "\n".join(lines)


@splicekit_tool("blade_at_times", DESTRUCTIVE)
def blade_at_times(times: str) -> str:
    """Blade (cut) the timeline at multiple specific times in a single batch call.
    Much faster than seeking + blading one at a time.

    times accepts either:
      - JSON array of seconds, e.g. [3.0, 6.0, 9.0, 12.0, 15.0]
      - Comma-separated seconds, e.g. "3.0, 6.0, 9.0" or a single value "25.0"

    Returns count of cuts successfully applied.
    """
    time_list = _parse_seconds_list(times)

    r = bridge.call("timeline.bladeAtTimes", times=time_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Applied {r.get('applied', 0)}/{r.get('count', 0)} cuts"]
    for c in r.get("cuts", []):
        status = "OK" if c.get("success") else f"FAILED: {c.get('error', '?')}"
        lines.append(f"  {c['time']:.2f}s -> {status}")
    return "\n".join(lines)
