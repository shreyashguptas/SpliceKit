"""MCP resources: read-only context a client can pre-load."""

import json

from .app import mcp
from .bridge import _err, bridge


# ============================================================
# MCP Resources
# ============================================================
# Read-only contextual data that models can pre-load before
# acting. Cheaper than tool calls — no side effects, cacheable.


@mcp.resource("splicekit://project/info",
              name="Project Info",
              description="Current project name, library, event, timeline state, version, and library status",
              mime_type="application/json")
def resource_project_info() -> str:
    """Return project-level context: what's loaded, library name, version, library status."""
    r = bridge.call("system.version")
    version_info = r if not _err(r) else {}

    r2 = bridge.call("timeline.getState")
    timeline_state = r2 if not _err(r2) else {}

    r3 = bridge.call("playback.getPosition")
    playhead = r3 if not _err(r3) else {}

    r4 = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                      selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    libraries = r4 if not _err(r4) else {}

    r5 = bridge.call("system.callMethod", className="FFLibraryDocument",
                      selector="isAnyLibraryUpdating", classMethod=True)
    updating = r5 if not _err(r5) else {}

    return json.dumps({
        "splicekit": version_info,
        "timeline": timeline_state,
        "playhead": playhead,
        "libraries": libraries,
        "isLibraryUpdating": updating,
    }, indent=2, default=str)


@mcp.resource("splicekit://timeline/clips",
              name="Timeline Clips",
              description="All clips on the active timeline with handles, durations, types, and track positions",
              mime_type="application/json")
def resource_timeline_clips() -> str:
    """Return the full clip list for the active timeline."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/markers",
              name="Timeline Markers",
              description="All markers in the active timeline with type, position, name, and notes",
              mime_type="application/json")
def resource_timeline_markers() -> str:
    """Return all markers from the active timeline (timeline.getMarkers)."""
    r = bridge.call("timeline.getMarkers")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    markers = r.get("markers", []) or []
    return json.dumps({"markers": markers, "count": len(markers)}, indent=2, default=str)


@mcp.resource("splicekit://effects/available",
              name="Available Effects",
              description="All installed video effects, generators, titles, and audio effects",
              mime_type="application/json")
def resource_available_effects() -> str:
    """Return all available effects from FCP."""
    r = bridge.call("effects.listAvailable", type="all")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://transitions/available",
              name="Available Transitions",
              description="All installed video transitions with names, effect IDs, and categories",
              mime_type="application/json")
def resource_available_transitions() -> str:
    """Return all available transitions from FCP."""
    r = bridge.call("transitions.list")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/selected-clips",
              name="Selected Clips",
              description="Currently selected clips in the timeline with handles, durations, and properties",
              mime_type="application/json")
def resource_selected_clips() -> str:
    """Return only the currently selected clips."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    items = [i for i in r.get("items", []) if i.get("selected")]
    return json.dumps({"selectedCount": len(items), "items": items}, indent=2, default=str)


@mcp.resource("splicekit://timeline/analysis",
              name="Timeline Analysis",
              description="Timeline statistics: clip count, duration, pacing, potential issues (flash frames, long clips)",
              mime_type="application/json")
def resource_timeline_analysis() -> str:
    """Return timeline analysis: pacing stats, potential issues, structure."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    pacing = "unknown"
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "accelerating"
        elif q4_avg > q1_avg * 1.3:
            pacing = "decelerating"
        else:
            pacing = "steady"

    issues = []
    if short_clips:
        issues.append(f"{len(short_clips)} flash frames (< 0.5s)")
    if long_clips:
        issues.append(f"{len(long_clips)} long clips (> 30s)")

    return json.dumps({
        "sequenceName": r.get("sequenceName", "?"),
        "durationSeconds": round(total_dur, 2),
        "playheadSeconds": round(playhead, 2),
        "clipCount": len(clips),
        "transitionCount": len(transitions),
        "avgClipDuration": round(avg_dur, 2),
        "minClipDuration": round(min_dur, 2),
        "maxClipDuration": round(max_dur, 2),
        "pacing": pacing,
        "issues": issues,
    }, indent=2, default=str)


@mcp.resource("splicekit://clips/applied-effects",
              name="Applied Effects",
              description="Effects currently applied to the selected clip, with names, IDs, and handles",
              mime_type="application/json")
def resource_applied_effects() -> str:
    """Return effects applied to the current/selected clip."""
    r = bridge.call("effects.getClipEffects")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://browser/clips",
              name="Browser Clips",
              description="Clips available in the FCP browser/media library with names, durations, and handles",
              mime_type="application/json")
def resource_browser_clips() -> str:
    """Return clips from the active library's browser."""
    r = bridge.call("browser.listClips")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://config/instructions",
              name="Editing Instructions",
              description="Operating rules, workflow guidance, and best practices for AI-driven FCP editing",
              mime_type="text/markdown")
def resource_instructions() -> str:
    """Workflow guidance and operating rules for models using SpliceKit.

    This teaches the model how to use SpliceKit properly regardless of
    whether CLAUDE.md is in context.
    """
    return """# SpliceKit Operating Instructions

## Golden Rules
1. **NEVER use keyboard simulation or AppleScript.** All actions go through direct ObjC calls via the bridge.
2. **Discover before editing.** Call get_timeline_clips() or read splicekit://timeline/clips before making changes.
3. **Select before acting.** Color correction, effects, retiming, and titles require a clip to be selected first.
4. **Verify after editing.** Use verify_action(), capture_timeline(), or capture_viewer() to confirm results.
5. **Prefer non-destructive workflows.** Use undo via history_action("undo") if something goes wrong.

## Standard Workflow
1. bridge_status() — verify FCP is connected
2. open_project("Name") — load a project
3. get_timeline_clips() — see timeline contents
4. Position playhead → select clip → apply action
5. verify_action() — confirm the edit took effect
6. capture_timeline() / capture_viewer() — visual verification

## Selection Pattern
```
playback_action("goToStart")
timeline_action("selectClipAtPlayhead")   # select primary storyline clip
timeline_action("addColorBoard")          # now apply effect/correction
```

For connected clips (B-roll, titles): use select_clip_in_lane(lane=1) for above, lane=-1 for below.

## Playhead Positioning
- 1 frame = ~0.042s at 24fps, ~0.033s at 30fps
- Use seek_to_time(seconds) for precise positioning
- Use batch_timeline_actions() for multi-step navigation + edit sequences
- Avoid frame-stepping loops when seek_to_time exists

## Batch Operations
Use batch_timeline_actions() for multi-step sequences rather than individual tool calls.
Use apply_transition_to_all_clips() to add transitions at every edit point at once.
Use blade_at_times() to cut at multiple timecodes in one call.
Use add_markers_at_times() to place markers at multiple positions.

## FCPXML for Complex Edits
For creating entire projects with precise timing, gaps, titles, and markers:
```
xml = generate_fcpxml(items='[{"type":"gap","duration":5},{"type":"title","text":"Hello","duration":3}]')
import_fcpxml(xml, internal=True)
```

## Timeline Data Model
FCP uses a spine model: sequence → primaryObject (collection) → items.
Items are FFAnchoredMediaComponent (clips), FFAnchoredTransition, etc.
get_timeline_clips() returns handles for each item — use handles in subsequent calls.

## Error Recovery
- history_action("undo") to reverse the last edit
- release_all_handles() to clean up leaked object handles
- bridge_status() to check if the connection is still alive
"""
