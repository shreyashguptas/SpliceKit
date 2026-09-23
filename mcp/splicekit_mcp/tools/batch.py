"""Tools: effects and color corrections on many clips in one call."""

from ..registry import DESTRUCTIVE, splicekit_tool
from ..bridge import _err, bridge
from .timeline_reads import _time_seconds


# ============================================================
# Batch Effect & Color Tools
# ============================================================
# Apply effects or corrections to multiple clips in one call,
# reducing round-trips for common bulk operations.

_BATCH_SPINE_READ_LIMIT = 10000


def _spine_item_accepts_batch_effect(item: dict) -> bool:
    """Primary-storyline items that cannot take a clip effect or color correction."""
    cls = str(item.get("class") or "")
    if "Transition" in cls:
        return False
    if "Gap" in cls or "Generator" in cls:
        return False
    return bool(item.get("handle"))


def _primary_storyline_targets_from_playhead(clip_count: int) -> tuple[list[dict], str | None]:
    """Ordered eligible primary-spine clips from the playhead clip through the end.

    Includes the clip whose range contains the playhead (start <= playhead < end), then every
    later eligible clip in timeline order. If the playhead is in a gap or past the end, only
    clips that start after the playhead are included.
    """
    r = bridge.call(
        "timeline.getDetailedState",
        limit=_BATCH_SPINE_READ_LIMIT,
        include_connected=False,
        include_markers=False,
    )
    if _err(r):
        return [], f"Error reading timeline: {r.get('error', r)}"

    spine_total = int(r.get("itemCount") or 0)
    items = r.get("items") or []
    if spine_total > len(items):
        return [], (
            f"Error: timeline has {spine_total} primary storyline items but getDetailedState "
            f"returned only {len(items)} (limit {_BATCH_SPINE_READ_LIMIT}); cannot batch safely"
        )

    playhead = _time_seconds(r, "playheadTime")
    if playhead is None:
        playhead = 0.0

    targets: list[dict] = []
    eps = 1e-9
    for item in items:
        if not _spine_item_accepts_batch_effect(item):
            continue
        start = _time_seconds(item, "startTime")
        end = _time_seconds(item, "endTime")
        if start is None:
            continue
        under_playhead = (
            end is not None
            and start <= playhead + eps
            and playhead < end - eps
        )
        starts_after = start > playhead + eps
        if not under_playhead and not starts_after:
            continue
        targets.append({
            "handle": item.get("handle"),
            "name": item.get("name") or "",
            "index": item.get("index"),
            "start_seconds": start,
        })

    if clip_count > 0:
        targets = targets[:clip_count]

    return targets, None


def _format_batch_clip_results(title: str, undo_name: str, clips_out: list[dict],
                               applied: int, extra_line: str = "") -> str:
    """Human-readable summary for batch_apply_effect / batch_color_correct."""
    total = len(clips_out)
    errors = total - applied
    lines = [f"{title}: {applied} of {total} clip(s) applied (Edit > Undo \"{undo_name}\")"]
    if errors:
        lines.append(f"  Errors: {errors}")
    if extra_line:
        lines.append(f"  {extra_line}")
    for c in clips_out:
        ok = c.get("success")
        tag = "ok" if ok else "FAILED"
        head = f"  [{tag}] {c.get('handle', '?')} \"{c.get('name', '')}\""
        if c.get("index") is not None:
            head += f" (spine {c['index']}"
            start = c.get("start_seconds")
            if isinstance(start, (int, float)):
                head += f" @ {float(start):.3f}s"
            head += ")"
        if ok:
            if c.get("effect"):
                head += f" — {c['effect']}"
            elif c.get("correction"):
                head += f" — {c['correction']}"
        else:
            head += f" — {c.get('error', 'unknown error')}"
        lines.append(head)
    return "\n".join(lines)


def _batch_select_clip_by_handle(handle: str) -> dict | None:
    """Select one spine/connected clip by handle; return bridge error dict or None on success."""
    r = bridge.call("timeline.selectItems", handles=[handle], mode="replace")
    if _err(r):
        return r
    unresolved = r.get("unresolved") or []
    if unresolved:
        return {"error": f"Handle not resolved: {unresolved[0]}"}
    if r.get("matchesRequest") is False and not (r.get("selected") or []):
        return {"error": "Selection did not match request (no clip selected)"}
    return None


@splicekit_tool("batch_apply_effect", DESTRUCTIVE)
def batch_apply_effect(name: str = "", effectID: str = "", clip_count: int = 0) -> str:
    """Apply one effect to each targeted primary-storyline clip.

    Reads the spine once via timeline.getDetailedState (same data as get_timeline_clips),
    skips transitions and gap/generator items, selects each target clip by handle without
    moving the playhead, and applies the effect once per clip. Targets are the clip whose
    range contains the playhead (start <= playhead < end), then every eligible clip that
    starts after the playhead in timeline order. If the playhead is in a gap or past the end,
    only clips that start after the playhead are processed. The whole batch is a single undo
    step (Edit > Undo "Batch Apply Effect").

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur").
        effectID: The effect ID string (alternative to name).
        clip_count: Process only the first N eligible clips (0 = all targets to end of spine).
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    targets, err = _primary_storyline_targets_from_playhead(clip_count)
    if err:
        return err
    if not targets:
        return "Error: no primary storyline clips from the playhead onward accept an effect"

    undo_name = "Batch Apply Effect"
    r = bridge.call("timeline.beginEdit", name=undo_name)
    if _err(r):
        return f"Error opening undo step: {r.get('error', r)}"

    clips_out: list[dict] = []
    applied = 0
    try:
        for target in targets:
            handle = target["handle"]
            entry: dict = {
                "handle": handle,
                "name": target["name"],
                "index": target.get("index"),
                "start_seconds": target.get("start_seconds"),
            }
            sel_err = _batch_select_clip_by_handle(handle)
            if sel_err:
                entry["success"] = False
                entry["error"] = sel_err.get("error", str(sel_err))
                clips_out.append(entry)
                continue

            params: dict = {}
            if effectID:
                params["effectID"] = effectID
            if name:
                params["name"] = name
            r = bridge.call("effects.apply", **params)
            if _err(r):
                entry["success"] = False
                entry["error"] = r.get("error", str(r))
            else:
                entry["success"] = True
                entry["effect"] = r.get("effect", name or effectID or "?")
                applied += 1
            clips_out.append(entry)
    finally:
        bridge.call("timeline.endEdit", name=undo_name)

    if applied == 0:
        return (
            "Error: batch apply failed on all "
            + _format_batch_clip_results("Batch Apply Effect", undo_name, clips_out, 0)
        )

    effect_line = ""
    if name:
        effect_line = f"Effect name: {name}"
    elif effectID:
        effect_line = f"Effect ID: {effectID}"
    return _format_batch_clip_results("Batch Apply Effect", undo_name, clips_out, applied, effect_line)


@splicekit_tool("batch_color_correct", DESTRUCTIVE)
def batch_color_correct(correction: str = "addColorBoard", clip_count: int = 0) -> str:
    """Apply one color correction to each targeted primary-storyline clip.

    Reads the spine once via timeline.getDetailedState (same data as get_timeline_clips),
    skips transitions and gap/generator items, selects each target clip by handle without
    moving the playhead, and runs the correction action once per clip. Targets are the clip
    whose range contains the playhead (start <= playhead < end), then every eligible clip that
    starts after the playhead in timeline order. If the playhead is in a gap or past the end,
    only clips that start after the playhead are processed. The whole batch is a single undo
    step (Edit > Undo "Batch Color Correct").

    Args:
        correction: The color correction action. One of:
            "addColorBoard", "addColorWheels", "addColorCurves",
            "addColorAdjustment", "addHueSaturation",
            "addEnhanceLightAndColor", "balanceColor", "matchColor"
        clip_count: Process only the first N eligible clips (0 = all targets to end of spine).
    """
    valid_corrections = {
        "addColorBoard", "addColorWheels", "addColorCurves",
        "addColorAdjustment", "addHueSaturation",
        "addEnhanceLightAndColor", "balanceColor", "matchColor",
    }
    if correction not in valid_corrections:
        return f"Error: correction must be one of: {', '.join(sorted(valid_corrections))}"

    targets, err = _primary_storyline_targets_from_playhead(clip_count)
    if err:
        return err
    if not targets:
        return "Error: no primary storyline clips from the playhead onward accept color correction"

    undo_name = "Batch Color Correct"
    r = bridge.call("timeline.beginEdit", name=undo_name)
    if _err(r):
        return f"Error opening undo step: {r.get('error', r)}"

    clips_out: list[dict] = []
    applied = 0
    try:
        for target in targets:
            handle = target["handle"]
            entry: dict = {
                "handle": handle,
                "name": target["name"],
                "index": target.get("index"),
                "start_seconds": target.get("start_seconds"),
            }
            sel_err = _batch_select_clip_by_handle(handle)
            if sel_err:
                entry["success"] = False
                entry["error"] = sel_err.get("error", str(sel_err))
                clips_out.append(entry)
                continue

            r = bridge.call("timeline.action", action=correction)
            if _err(r):
                entry["success"] = False
                entry["error"] = r.get("error", str(r))
            else:
                entry["success"] = True
                entry["correction"] = correction
                applied += 1
            clips_out.append(entry)
    finally:
        bridge.call("timeline.endEdit", name=undo_name)

    if applied == 0:
        return (
            "Error: batch color correct failed on all "
            + _format_batch_clip_results("Batch Color Correct", undo_name, clips_out, 0,
                                         f"Correction: {correction}")
        )

    return _format_batch_clip_results(
        "Batch Color Correct", undo_name, clips_out, applied, f"Correction: {correction}")
