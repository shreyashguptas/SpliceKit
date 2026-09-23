"""Tools: lane and handle selection, edit grouping, exact trims."""

import json

from ..registry import DESTRUCTIVE, LOCAL, LOCAL_IDEMPOTENT, splicekit_tool
from ..bridge import _call_or_error, _err, bridge
from .timeline_reads import _fmt_secs, _time_seconds


# ============================================================
# Select Connected Clip at Playhead (Lane Selection)
# ============================================================
# The standard selectClipAtPlayhead only selects the primary
# storyline clip. This tool selects clips in any lane.

@splicekit_tool("select_clip_in_lane", LOCAL_IDEMPOTENT)
def select_clip_in_lane(lane: int = 1) -> str:
    """Select the clip at the playhead in a specific lane (connected storyline).

    The standard timeline_action("selectClipAtPlayhead") only selects clips in
    the primary storyline (lane 0). This tool can select connected clips in any
    lane — essential for inspecting or modifying connected titles, B-roll, etc.

    Args:
        lane: Lane number to select from.
              0 = primary storyline (same as selectClipAtPlayhead)
              1 = first connected lane above (captions, titles, B-roll)
              -1 = first connected lane below
              2, 3, etc. = higher connected lanes

    Returns the selected clip's name, class, and handle for further inspection.
    """
    return _call_or_error("timeline.selectClipInLane", lane=lane)


# ============================================================
# Handle-based selection, edit grouping, exact trims
# ============================================================
# get_timeline_clips() hands back a handle for every clip. These tools act on
# those handles directly instead of on whatever happens to be under the playhead.

def _parse_handle_list(handles) -> list:
    """Accept a Python list, a JSON array string, or a comma-separated string of handles."""
    if handles is None:
        return []
    if isinstance(handles, str):
        text = handles.strip()
        if not text:
            return []
        if text.startswith("["):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as e:
                raise ValueError(f"handles is not a valid JSON array: {e}")
            if not isinstance(parsed, list):
                raise ValueError("handles JSON must be an array of handle strings")
            return [str(h).strip() for h in parsed if str(h).strip()]
        return [part.strip() for part in text.split(",") if part.strip()]
    if isinstance(handles, (list, tuple)):
        return [str(h).strip() for h in handles if str(h).strip()]
    raise ValueError("handles must be a list of handle strings, a JSON array string, "
                     "or a comma-separated string")


@splicekit_tool("select_clips", LOCAL_IDEMPOTENT)
def select_clips(handles: list[str] | str = "", mode: str = "replace") -> str:
    """Select clips by handle -- the way to act on a specific clip after get_timeline_clips().

    Workflow:
        get_timeline_clips()                       # read handles (e.g. "obj_12")
        select_clips(["obj_12"])                   # make that clip the selection
        timeline_action("addColorBoard")           # act on the selection as usual

    Works for clips in the primary storyline and for connected clips (titles,
    B-roll, music) alike, at any depth. Like Option-clicking a clip in Final Cut
    Pro, it never moves the playhead. An empty list is Edit > Deselect All. This
    tool selects clips only; to change a marker use list_markers() and the marker
    actions (changeMarkerName, markMarkerCompleted, removeMarker).

    Args:
        handles: a Python list, a JSON array string ('["obj_1","obj_2"]') or a
                 comma-separated string ("obj_1, obj_2"). Empty = deselect all.
        mode: "replace" (default) makes these clips the selection (a click in FCP);
              "add" adds them to the current selection (Command-click);
              "remove" takes them out of it (Command-click a selected clip).

    If none of the handles resolve, the selection is left unchanged and an error
    is returned. Handles and `matchesRequest` are SpliceKit bookkeeping, not Final
    Cut Pro terms: a handle is a reference to an object from an earlier read
    (re-run get_timeline_clips() if one comes back unresolved) and is unrelated to
    FCP's "media handles"; matchesRequest reports whether FCP's selection after the
    call equals the intended set (the requested clips for replace; the current
    selection plus or minus them for add/remove).
    """
    mode_l = (mode or "replace").strip().lower()
    if mode_l not in ("replace", "add", "remove"):
        return 'Error: mode must be "replace", "add" or "remove"'
    try:
        handle_list = _parse_handle_list(handles)
    except ValueError as e:
        return f"Error: {e}"

    r = bridge.call("timeline.selectItems", handles=handle_list, mode=mode_l)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    selected = r.get("selected", []) or []
    lines = [f"Selection ({r.get('mode', mode_l)}): {r.get('selectedCount', len(selected))} selected, "
             f"{r.get('resolvedCount', 0)}/{r.get('requestedCount', len(handle_list))} handles resolved"]
    if selected:
        lines.append(f"  {'handle':<10} {'lane':>4} {'start':>8} {'end':>8}  name")
        for item in selected:
            lines.append(
                f"  {str(item.get('handle', '?')):<10} {str(item.get('lane', '?')):>4} "
                f"{_fmt_secs(_time_seconds(item, 'startTime'))} {_fmt_secs(_time_seconds(item, 'endTime'))}  "
                f"{item.get('name', '')}"
            )
    elif not handle_list and mode_l == "replace":
        lines.append("  (nothing selected -- deselected all)")
    else:
        lines.append("  (nothing selected)")

    unresolved = r.get("unresolved", []) or []
    if unresolved:
        lines.append("Unresolved handles (stale? re-run get_timeline_clips): " + ", ".join(map(str, unresolved)))
    for rej in r.get("rejected", []) or []:
        lines.append(f"Rejected {rej.get('handle', '?')}: {rej.get('reason', 'rejected')}")
    if r.get("matchesRequest") is False:
        lines.append("WARNING: FCP's selection does not match the request (matchesRequest=false); "
                     "check the rows above before acting on the selection.")
    return "\n".join(lines)


@splicekit_tool("begin_edit", LOCAL, title="Begin Undo Step")
def begin_edit(name: str = "Edit") -> str:
    """Open one undo step: everything until end_edit() reverts with a single Edit > Undo `name`.

    Final Cut Pro's internal term for this is an undoable action. It is opened
    on the sequence with actionBegin: and closed with actionEnd:save:error:,
    the same pair FCP's own edits use, so a multi-step edit (several blades,
    trims, markers, ...) undoes with one timeline_action("undo"). Always call
    end_edit() afterwards, also after an error, or the step stays open.

    Args:
        name: the Edit > Undo menu name for the step, e.g. "Rough cut".
    """
    r = bridge.call("timeline.beginEdit", name=name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"Undo step open: {r.get('name', name)}"
             + (f" (opened with {r['openedWith']})" if r.get("openedWith") else "")]
    if r.get("note"):
        lines.append(f"Note: {r['note']}")
    if "hadOpenTransaction" in r or "hasOpenTransaction" in r:
        lines.append(f"(diagnostic) hasOpenTimelineTransaction before: {r.get('hadOpenTransaction', '?')}, "
                     f"after: {r.get('hasOpenTransaction', '?')}")
    lines.append("Remember to call end_edit() when the edit is complete.")
    return "\n".join(lines)


@splicekit_tool("end_edit", LOCAL_IDEMPOTENT, title="End Undo Step")
def end_edit(name: str = "") -> str:
    """Close the undo step opened by begin_edit(); everything since then is one Edit > Undo entry.

    Always call this after begin_edit(), also when something went wrong in
    between. Final Cut Pro registers the step under the name given to
    begin_edit() (or `name` here, if provided). If SpliceKit has no step open
    this does nothing, so it can never close a transaction FCP itself opened.

    Args:
        name: optional override for the Edit > Undo menu name.
    """
    params = {}
    if name:
        params["name"] = name
    r = bridge.call("timeline.endEdit", **params)
    if _err(r) and "status" not in r:
        return f"Error: {r.get('error', r)}"
    status = r.get("status", "ok")
    lines = [f"Undo step closed ({status}): {r.get('name', name or 'Edit')}"
             + (f" via {r['closedWith']}" if r.get("closedWith") else "")]
    if r.get("note"):
        lines.append(f"Note: {r['note']}")
    if "hadOpenTransaction" in r or "hasOpenTransaction" in r:
        lines.append(f"(diagnostic) hasOpenTimelineTransaction before: {r.get('hadOpenTransaction', '?')}, "
                     f"after: {r.get('hasOpenTransaction', '?')}")
    if r.get("error"):
        lines.append(f"Error reported by FCP: {r['error']}")
    if status == "ok" and not r.get("note"):
        lines.append(f"Edit > Undo {r.get('name', name or 'Edit')} now reverts the whole step.")
    return "\n".join(lines)


def _trim_range_line(label, rng):
    if not isinstance(rng, dict):
        return f"  {label} ?"
    return (f"  {label} {rng.get('start', 0):.3f}s - {rng.get('end', 0):.3f}s "
            f"(duration {rng.get('duration', 0):.3f}s)")


@splicekit_tool("trim_clip", DESTRUCTIVE)
def trim_clip(handle: str, edge: str, delta_seconds: float | None = None,
              to_seconds: float | None = None, dry_run: bool = False) -> str:
    """Ripple trim one edit point (a clip's start point or end point) by handle, to an exact time.

    This is Final Cut Pro's default trim, a ripple edit: the same as dragging a
    clip's start point or end point with the Select tool. On the primary
    storyline the clip's duration changes and all subsequent clips ripple
    earlier or later so no gap is left (the project duration changes);
    connected clips attached to the trimmed clip or to any subsequent clip move
    with them, as in FCP. For a connected clip only that clip changes.

    A positive delta moves the edit point later on the timeline (to the right,
    like pressing Period with the edit point selected), a negative delta moves
    it earlier (Comma). Trimming the START point of a primary-storyline clip
    keeps the clip in place: its start point moves within the source media, its
    duration changes, and its end plus everything after it shifts.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        edge: "start" (the clip's start point) or "end" (its end point).
        delta_seconds: move the edit point by this many seconds (+ later, - earlier).
        to_seconds: or, the absolute timeline time the edit point should be at.
                    Give exactly one of delta_seconds / to_seconds. For a start
                    point on the primary storyline this sets how much head is
                    removed or added (to_seconds minus the current start); the
                    clip itself stays where it is.
        dry_run: True reports the planned before/after ranges without changing
                 anything (a SpliceKit preview; FCP has no dry run). Try it first.

    Sub-frame requests are a no-op; a trim that would leave the clip shorter
    than one frame is refused; transitions and connected storylines (trim the
    clips inside them) are not accepted; a compound clip is trimmed like any
    clip. Undo with timeline_action("undo").
    """
    edge_l = (edge or "").strip().lower()
    if edge_l not in ("start", "end"):
        return 'Error: edge must be "start" or "end"'
    if (delta_seconds is None) == (to_seconds is None):
        return "Error: give exactly one of delta_seconds or to_seconds"
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"

    params = {"handle": handle, "edge": edge_l, "dryRun": bool(dry_run)}
    if delta_seconds is not None:
        params["deltaSeconds"] = float(delta_seconds)
    else:
        params["toSeconds"] = float(to_seconds)
    r = bridge.call("timeline.trimClip", **params)
    if _err(r) and "status" not in r:
        # Validation refusals (bad handle, no-op, too short) carry no status; a
        # status:"failed" response is rendered below with its before/after ranges.
        lines = [f"Error: {r.get('error', r)}"]
        if isinstance(r, dict) and r.get("before"):
            lines.append(_trim_range_line("current:", r["before"]))
        return "\n".join(lines)

    name = r.get("name", "")
    label = f"{edge_l} edit point of '{name}' ({r.get('handle', handle)})"
    if r.get("dryRun"):
        lines = [f"DRY RUN -- ripple trim of the {label}",
                 f"  delta: {r.get('deltaSeconds', 0):+.3f}s "
                 f"({'later' if r.get('deltaSeconds', 0) > 0 else 'earlier'} on the timeline"
                 + (f", {r['deltaFrames']} frame(s)" if "deltaFrames" in r else "") + ")",
                 _trim_range_line("before:   ", r.get("before")),
                 _trim_range_line("projected:", r.get("projected"))]
        if r.get("rippleScope"):
            lines.append(f"  ripple: {r['rippleScope']}")
        lines.append("  Ripple edit: subsequent clips move so no gap is left, connected clips move with them. "
                     "Nothing was changed.")
        return "\n".join(lines)

    status = r.get("status", "?")
    lines = [f"Ripple trim {'OK' if status == 'ok' else 'FAILED'} -- {label}",
             f"  requested: {r.get('requestedDelta', 0):+.3f}s, applied: {r.get('appliedDelta', 0):+.3f}s"]
    lines.append(_trim_range_line("before:", r.get("before")))
    lines.append(_trim_range_line("after: ", r.get("after")))
    if r.get("error"):
        lines.append(f"  error: {r['error']}")
    if r.get("warning"):
        lines.append(f"  warning: {r['warning']}")
    if r.get("note"):
        lines.append(f"  note: {r['note']}")
    if r.get("rippleScope"):
        lines.append(f"  ripple: {r['rippleScope']}")
    if r.get("undoStepError"):
        lines.append(f"  undo step '{r.get('undoStep', 'Trim')}' could not be closed cleanly: {r['undoStepError']} "
                     "-- check Edit > Undo before relying on it")
    elif r.get("undoStep"):
        lines.append(f"  undo step: {r['undoStep']}" + (f" ({r['undoStepNote']})" if r.get("undoStepNote") else ""))
    elif r.get("undoStepNote"):
        lines.append(f"  undo step: none -- {r['undoStepNote']}")
    if status == "ok":
        lines.append('  Ripple edit applied: subsequent clips moved so no gap is left. Undo with timeline_action("undo").')
    return "\n".join(lines)
