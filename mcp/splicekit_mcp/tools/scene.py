"""Tools: scene change detection, markers and blades at the cuts."""

from ..registry import DESTRUCTIVE, LOCAL, READ, splicekit_tool
from ..bridge import _err, bridge


def _format_scene_detect_result(r: dict) -> str:
    changes = r.get("sceneChanges", [])
    total = int(r.get("count", len(changes)))
    lines = [
        f"Scene changes: {total} (threshold={r.get('threshold', 0)}, file={r.get('mediaFile', '?')})",
    ]
    if r.get("clipName"):
        tl_start = float(r.get("clipTimelineStart", 0))
        tl_end = float(r.get("clipTimelineEnd", 0))
        file_start = float(r.get("fileStart", 0))
        clip_media_dur = tl_end - tl_start
        file_end = file_start + clip_media_dur
        lines.append(
            f"Analysed clip: \"{r.get('clipName')}\" ({r.get('clipHandle', '')}) "
            f"timeline {tl_start:.3f}-{tl_end:.3f}s"
        )
        lines.append(
            f"Clip used source media range: {file_start:.3f}-{file_end:.3f}s "
            f"(mark/blade only apply to cuts inside this window)."
        )
    lines.append(
        "Times below are SOURCE MEDIA file seconds (not timeline). "
        "mark_scene_changes / blade_scene_changes map them onto the analysed clip."
    )
    action = r.get("action")
    if action not in (None, "detect"):
        applied = int(r.get("applied", 0))
        skipped = int(r.get("skippedOutsideClip", 0))
        lines.append(f"Action: {action}")
        lines.append(
            f"Applied {applied} of {total} ({skipped} fell outside the clip's used media range and were skipped)."
        )
        if applied == 0:
            lines.append(
                "No markers or blades were placed (all detected cuts were outside the clip's "
                "used source media range, or placement failed)."
            )
    lines.append("")
    for sc in changes:
        lines.append(f"  {sc['time']:.2f}s  (score: {sc.get('score', 0):.3f})")
    if r.get("error"):
        lines.append(f"\nWarning: {r['error']}")
    return "\n".join(lines)


@splicekit_tool("detect_scene_changes", READ)
def detect_scene_changes(
    threshold: float = 0.35,
    action: str = "detect",
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Use this read-only tool to inspect scene changes before deciding whether to mark or blade them.

    Target clip (analysed once, same for detect/mark/blade): handle if given; else the sole
    selected clip; else the primary-storyline clip under the playhead; else an error listing
    spine candidates. Pass file_url to analyse a file on disk without a timeline clip (times
    are file seconds only; mark/blade are refused).

    Args:
        threshold: Sensitivity (0.0-1.0). Lower = more sensitive. Default 0.35.
        action: Deprecated compatibility argument. Only "detect" is accepted here.
        sample_interval: Seconds between sampled frames. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips() (required for compound/multicam).
        file_url: Analyse this media path directly (no timeline mapping).

    Returns scene-change timestamps in source-media seconds with confidence scores.
    """
    if action != "detect":
        return "Error: detect_scene_changes() is read-only. Use mark_scene_changes() or blade_scene_changes()."

    params: dict = {
        "threshold": threshold,
        "action": action,
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url

    r = bridge.call("scene.detect", **params)
    if _err(r):
        err = f"Error: {r.get('error', r)}"
        candidates = r.get("candidates")
        if candidates:
            err += "\nPrimary storyline candidates:"
            for c in candidates:
                err += (
                    f"\n  {c.get('handle', '?')} \"{c.get('name', '')}\" "
                    f"{c.get('start', 0):.3f}-{c.get('end', 0):.3f}s"
                )
        return err

    return _format_scene_detect_result(r)


@splicekit_tool("mark_scene_changes", LOCAL)
def mark_scene_changes(
    threshold: float = 0.35,
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Add markers at detected scene changes on the resolved timeline clip (see detect_scene_changes).

    Args:
        threshold: Scene-cut sensitivity (0.0–1.0). Lower detects more cuts. Default 0.35.
        sample_interval: Seconds between sampled frames for detection. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips(); required for compound/multicam.
        file_url: If set, analyse this media file only; mark is refused (nothing to map onto).
    """
    params: dict = {
        "threshold": threshold,
        "action": "markers",
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url
    r = bridge.call("scene.detect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _format_scene_detect_result(r)


@splicekit_tool("blade_scene_changes", DESTRUCTIVE)
def blade_scene_changes(
    threshold: float = 0.35,
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Blade the timeline at detected scene changes on the resolved timeline clip (see detect_scene_changes).

    Args:
        threshold: Scene-cut sensitivity (0.0–1.0). Lower detects more cuts. Default 0.35.
        sample_interval: Seconds between sampled frames for detection. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips(); required for compound/multicam.
        file_url: If set, analyse this media file only; blade is refused (nothing to map onto).
    """
    params: dict = {
        "threshold": threshold,
        "action": "blade",
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url
    r = bridge.call("scene.detect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _format_scene_detect_result(r)
