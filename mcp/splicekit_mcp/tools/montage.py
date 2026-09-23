"""Tools: Montage Maker."""

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Montage Maker (Auto-Edit to Beat)
# ============================================================
# End-to-end pipeline: analyze clips -> plan cuts to music beats
# -> assemble a montage timeline. Can run as individual steps
# or as a single montage_auto() call.

@splicekit_tool("montage_analyze_clips")
def montage_analyze_clips(event_name: str = "") -> str:
    """Analyze clips in the browser for montage creation.

    Scans clips in the specified event (or all events), scores them
    based on duration, type (video/photo), and available metadata.
    Returns a ranked list of clips suitable for montage assembly.

    Args:
        event_name: Event name to scan (empty = all events).
    """
    r = bridge.call("montage.analyzeClips", eventName=event_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_plan_edit")
def montage_plan_edit(beats: str, clips: str, style: str = "beat",
                      bars: str = "", sections: str = "",
                      total_duration: float = 0) -> str:
    """Create an edit decision list (EDL) that maps clips to musical beats.

    Takes beat/bar timing data and scored clips, then creates a plan
    that assigns the best clips to each musical segment.

    Each style cuts on a different list, and the list it needs must be supplied:
    "beat" uses `beats`, "bar" uses `bars`, "section" uses `sections` (falling back
    to `bars`). flexmusic_get_timing returns all three for a song.

    Args:
        beats: JSON array of beat timestamps in seconds (from flexmusic_get_timing).
        clips: JSON array of clip objects with handle, duration, score (from montage_analyze_clips).
        style: Cut rhythm - "beat" (every beat), "bar" (every bar/measure), "section" (at sections).
        bars: JSON array of bar timestamps in seconds. Required when style="bar".
        sections: JSON array of section-boundary timestamps in seconds. Used when
                  style="section"; falls back to `bars` when empty.
        total_duration: Total montage duration in seconds (0 = the last cut point).

    Returns an edit decision list with clip assignments, in/out points, and timeline positions.
    """
    import json as _json

    def _arr(value):
        if not value:
            return []
        return _json.loads(value) if isinstance(value, str) else value

    beats_arr, bars_arr, sections_arr = _arr(beats), _arr(bars), _arr(sections)
    clips_arr = _arr(clips)

    # The default used to be "bar" while this tool sent no bars at all, so every call
    # that did not override style failed with "Not enough timing data" no matter what
    # was passed. Say which list is missing instead of making the caller guess.
    needed = {"beat": ("beats", beats_arr), "bar": ("bars", bars_arr),
              "section": ("sections", sections_arr or bars_arr)}.get(style)
    if needed is None:
        return f"Error: style must be one of beat, bar, section (got {style!r})"
    name, values = needed
    if len(values) < 2:
        return (f"Error: style={style!r} cuts on {name}, and {name} has "
                f"{len(values)} entries; at least 2 are needed. "
                "flexmusic_get_timing returns beats, bars and sections for a song.")

    r = bridge.call("montage.planEdit", beats=beats_arr, bars=bars_arr,
                    sections=sections_arr, clips=clips_arr,
                    style=style, totalDuration=total_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_assemble")
def montage_assemble(edit_plan: str, project_name: str = "Montage", song_file: str = "") -> str:
    """Assemble a montage on the timeline from an edit plan.

    Takes the edit decision list and creates the actual timeline:
    places clips at their assigned positions, adds transitions,
    and includes the background music track.

    Uses FCPXML import for reliable, atomic timeline construction.

    Args:
        edit_plan: JSON string of the edit decision list (from montage_plan_edit).
        project_name: Name for the new project.
        song_file: Path to rendered FlexMusic audio file (from flexmusic_render_to_file).
    """
    import json as _json
    plan = _json.loads(edit_plan) if isinstance(edit_plan, str) else edit_plan
    r = bridge.call("montage.assemble", editPlan=plan, projectName=project_name, songFile=song_file)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_auto")
def montage_auto(song_uid: str = "", event_name: str = "", style: str = "bar", project_name: str = "Montage") -> str:
    """One-shot automatic montage creation.

    Analyzes clips, selects a song, gets beat timing, plans the edit,
    renders the music, and assembles everything into a new timeline.

    This is the high-level convenience function that orchestrates the
    entire montage creation pipeline in a single call.

    Args:
        song_uid: FlexMusic song UID (empty = auto-select based on clip mood).
        event_name: Event to pull clips from (empty = all events).
        style: Cut rhythm - "beat", "bar" (default), or "section".
        project_name: Name for the new project.
    """
    r = bridge.call("montage.auto", songUID=song_uid, eventName=event_name,
                     style=style, projectName=project_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)
