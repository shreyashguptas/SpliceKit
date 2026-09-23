"""Tools: clip effects, batched timeline actions, timeline analysis."""

import json
import time

from ..registry import DESTRUCTIVE, READ, splicekit_tool
from ..bridge import _err, bridge


# ============================================================
# Effects & Color Correction
# ============================================================
# Tools for inspecting and applying effects on clips.

@splicekit_tool("get_clip_effects", READ)
def get_clip_effects(handle: str = "") -> str:
    """Get the effects applied to a clip. If no handle provided, uses the first selected clip.
    Returns effect names, IDs, classes, and handles for further inspection.
    """
    params = {}
    if handle:
        params["handle"] = handle
    r = bridge.call("effects.getClipEffects", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Clip: {r.get('clipName', '?')} ({r.get('clipClass', '?')})"]
    effects = r.get("effects", [])
    lines.append(f"Effects: {r.get('effectCount', len(effects))}")
    for ef in effects:
        lines.append(f"  {ef.get('name', '?')} ({ef.get('class', '?')}) ID={ef.get('effectID', '')} handle={ef.get('handle', '')}")

    if r.get("effectStackHandle"):
        lines.append(f"\nEffect stack handle: {r['effectStackHandle']}")

    return "\n".join(lines)


# ============================================================
# Batch Operations
# ============================================================
# Lets the AI chain many small edits in one round-trip instead
# of making a separate tool call for each step.

@splicekit_tool("batch_timeline_actions", DESTRUCTIVE)
def batch_timeline_actions(actions: str, undo_name: str = "Batch Actions") -> str:
    """Execute multiple timeline/playback actions in sequence.
    Much more efficient than calling individual tools.

    When the batch includes any timeline action, the whole run is wrapped in one
    undo step (timeline.beginEdit / timeline.endEdit), so Edit > Undo reverts
    every timeline mutation in the batch with a single undo.

    actions: JSON array of action objects. Each action:
      {"type": "timeline", "action": "blade"}
      {"type": "playback", "action": "nextFrame"}
      {"type": "playback", "action": "nextFrame", "repeat": 30}
      {"type": "wait", "seconds": 0.5}

    undo_name: Edit > Undo menu name when a group is opened (default "Batch Actions").

    Example: select the clip at the playhead and grade it, as one undo step:
      batch_timeline_actions('[
        {"type":"timeline","action":"selectClipAtPlayhead"},
        {"type":"timeline","action":"addColorBoard"}
      ]')

    For cuts or markers at known times use blade_at_times / add_markers_at_times: they
    jump straight to each time instead of stepping the playhead frame by frame.
    """
    try:
        action_list = json.loads(actions)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    has_timeline_actions = any(
        act.get("type", "timeline") == "timeline" for act in action_list
    )
    undo_group_opened = False
    begin_edit_note: str | None = None
    if has_timeline_actions:
        r = bridge.call("timeline.beginEdit", name=undo_name)
        if _err(r):
            begin_edit_note = (
                f"Note: could not open undo group ({r.get('error', r)}); "
                "timeline actions are not grouped."
            )
        else:
            undo_group_opened = True

    results = []
    errors = 0
    try:
        for i, act in enumerate(action_list):
            act_type = act.get("type", "timeline")
            action_name = act.get("action", "")
            repeat = act.get("repeat", 1)

            if act_type == "wait":
                secs = act.get("seconds", 0.5)
                time.sleep(secs)
                results.append(f"[{i}] wait {secs}s -> OK")
            elif act_type == "playback":
                r = None
                for _ in range(repeat):
                    r = bridge.call("playback.action", action=action_name)
                label = f"[{i}] playback.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
                if r and _err(r):
                    errors += 1
                    results.append(f"{label} -> FAILED: {r.get('error', '?')}")
                else:
                    results.append(f"{label} -> OK")
            elif act_type == "timeline":
                r = None
                for _ in range(repeat):
                    r = bridge.call("timeline.action", action=action_name)
                label = f"[{i}] timeline.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
                if r and _err(r):
                    errors += 1
                    results.append(f"{label} -> FAILED: {r.get('error', '?')}")
                else:
                    results.append(f"{label} -> OK")
            else:
                errors += 1
                results.append(f"[{i}] unknown type: {act_type} -> SKIPPED")
    finally:
        if undo_group_opened:
            bridge.call("timeline.endEdit", name=undo_name)

    summary = f"Executed {len(action_list)} actions"
    if errors:
        summary += f" ({errors} failed)"
    # The colon introduces the per-action lines. It belongs on this line: appending
    # it after the undo-group line produced "Undo group: Batch Actions:".
    summary += ":"
    if undo_group_opened:
        summary += f"\nUndo group: {undo_name}"
    if begin_edit_note:
        summary += f"\n{begin_edit_note}"
    return summary + "\n" + "\n".join(results)


# ============================================================
# Timeline Analysis
# ============================================================
# Computes statistics the AI can use to understand the timeline
# before suggesting edits (pacing, flash frames, etc).

@splicekit_tool("analyze_timeline", READ)
def analyze_timeline() -> str:
    """Analyze the current timeline: duration, clip count, pacing stats,
    potential issues (short clips, gaps). Returns a structured report.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    # Split items into clips vs transitions for separate stats
    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    # Flag potential problems: flash frames (<0.5s) and overly long shots (>30s)
    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    # Pacing: compare average clip length in the first vs last quarter
    # to detect if the edit is accelerating or decelerating over time
    pacing = ""
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "Accelerating (cuts getting faster)"
        elif q4_avg > q1_avg * 1.3:
            pacing = "Decelerating (cuts getting slower)"
        else:
            pacing = "Steady"

    lines = [
        f"=== Timeline Analysis ===",
        f"Sequence: {r.get('sequenceName', '?')}",
        f"Duration: {total_dur:.1f}s ({total_dur/60:.1f}min)",
        f"Playhead: {playhead:.1f}s",
        f"",
        f"Clips: {len(clips)}",
        f"Transitions: {len(transitions)}",
        f"Avg clip duration: {avg_dur:.2f}s",
        f"Shortest clip: {min_dur:.2f}s",
        f"Longest clip: {max_dur:.2f}s",
    ]

    if pacing:
        lines.append(f"Pacing: {pacing}")

    # Issues
    issues = []
    if short_clips:
        issues.append(f"Flash frames: {len(short_clips)} clips < 0.5s")
    if long_clips:
        issues.append(f"Long clips: {len(long_clips)} clips > 30s")

    if issues:
        lines.append(f"\nPotential issues:")
        for issue in issues:
            lines.append(f"  - {issue}")
    else:
        lines.append(f"\nNo issues detected")

    return "\n".join(lines)
