"""Tools: beat-synced trims and song cuts."""

import json

from ..registry import DESTRUCTIVE, splicekit_tool
from ..bridge import _err, bridge


@splicekit_tool("trim_clips_to_beats", DESTRUCTIVE)
def trim_clips_to_beats(
    grid: str = "beat",
    randomize: bool = False,
    random_min_step: int = 1,
    random_max_step: int = 4,
    random_seed: int = 1337,
    min_trim_seconds: float = 0.0,
    min_result_duration: float = 0.0,
    source_handle: str = "",
    target_handles: str = "",
    target_mode: str = "auto",
    dry_run: bool = False,
) -> str:
    """Trim video clips so they end on Apple beat-map boundaries from a music clip in the timeline.

    Uses Apple's timing metadata from a beat-detected audio clip already on the timeline.
    It preserves each target clip's start time and shortens the tail so the clip ends on:
      - the nearest valid beat before the current clip end (`grid="beat"`)
      - the nearest valid half-beat before the current clip end (`grid="half_beat"`)
      - the nearest valid bar before the current clip end (`grid="bar"`)

    If `randomize=True`, each clip picks a random valid boundary near its tail within the
    `random_min_step..random_max_step` window counted backward from the clip end.
    For example, with beat grid and `random_min_step=1`, `random_max_step=4`, each clip ends
    on one of the last 1-4 beat boundaries before its current end.

    Source selection:
      - If `source_handle` is provided, use that beat-detected clip.
      - Else prefer a selected beat-detected audio clip.
      - Else auto-discover the first beat-detected audio clip in the active timeline.

    Target selection:
      - If `target_handles` is provided, trim exactly those clips.
      - Else if non-source clips are selected, trim the selected video clips.
      - Else prefer connected/overlay video clips above the source lane.
      - Else trim all visible video clips except the source.

    Args:
        grid: "beat", "half_beat", "quarter_beat", "bar", "section", "random", "random_half_beat", or "random_quarter_beat"
        randomize: When true, pick a random tail-near grid point per clip
        random_min_step: Minimum step backward from the clip end when randomizing
        random_max_step: Maximum step backward from the clip end when randomizing
        random_seed: Seed for deterministic random trims
        min_trim_seconds: Skip trims smaller than this many seconds (0 = auto)
        min_result_duration: Skip trims that would leave a shorter clip than this (0 = auto)
        source_handle: Optional handle of the beat-detected audio clip in the active timeline
        target_handles: Optional JSON array of clip handles to trim
        target_mode: "auto", "selected", "overlay", or "all" when target_handles is omitted
        dry_run: When true, preview the trim plan without modifying the timeline

    Returns a preview or apply summary with the chosen source, grid preview, and per-clip plan.
    """
    parsed_target_handles = []
    if target_handles:
        try:
            parsed_target_handles = json.loads(target_handles)
        except json.JSONDecodeError as e:
            return f"Invalid target_handles JSON: {e}"
        if not isinstance(parsed_target_handles, list):
            return "target_handles must decode to a JSON array of clip handles"

    params = {
        "grid": grid,
        "randomize": randomize,
        "randomMinStep": random_min_step,
        "randomMaxStep": random_max_step,
        "randomSeed": random_seed,
        "dryRun": dry_run,
    }
    if target_mode:
        params["targetMode"] = target_mode
    if min_trim_seconds > 0:
        params["minTrimSeconds"] = min_trim_seconds
    if min_result_duration > 0:
        params["minResultDuration"] = min_result_duration
    if source_handle:
        params["sourceHandle"] = source_handle
    if parsed_target_handles:
        params["targetHandles"] = parsed_target_handles

    r = bridge.call("timeline.trimClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return _format_trim_to_beats_result(r, random_min_step, random_max_step, random_seed)


def _format_trim_to_beats_result(
    response: dict,
    random_min_step: int,
    random_max_step: int,
    random_seed: int,
) -> str:
    source = response.get("source", {})
    lines = [
        f"{'Previewing' if response.get('dryRun') else 'Applied'} {response.get('applied', 0)}/{response.get('planned', 0)} planned trims",
        f"Source: {source.get('name', '<unknown>')}  grid={response.get('grid')}  gridPoints={response.get('gridPointCount', 0)}",
    ]
    tempo = source.get("tempo")
    if tempo:
        lines[-1] += f"  tempo={tempo:.2f}"
    if response.get("targetMode"):
        lines[-1] += f"  targets={response.get('targetMode')}"
    if response.get("randomize"):
        lines.append(
            f"Random window: {random_min_step}-{random_max_step} steps  seed={response.get('randomSeed', random_seed)}"
        )

    preview = response.get("gridPreview", [])
    if preview:
        lines.append("Grid preview: " + ", ".join(f"{float(v):.2f}s" for v in preview))

    for entry in response.get("plan", []):
        status = entry.get("status", "?")
        name = entry.get("name", "")
        if status in {"planned", "applied"}:
            lines.append(
                f"  {name}: {entry['start']:.2f}s -> {entry['targetEnd']:.2f}s "
                f"(trim {entry['trimAmount']:.2f}s, new {entry['newDuration']:.2f}s) [{status}]"
            )
        else:
            lines.append(f"  {name}: {entry.get('reason', 'skipped')} [{status}]")

    return "\n".join(lines)


def _song_cut_preset(pace: str) -> dict | None:
    presets = {
        "natural": {
            "grid": "half_beat",
            "segment_min_step": 1,
            "segment_max_step": 4,
            "step_weights": {"1": 1, "2": 8, "4": 3},
            "label": "mostly whole-beat cuts, sometimes two beats, rarely paired half-beats",
        },
        "medium": {
            "grid": "half_beat",
            "segment_min_step": 2,
            "segment_max_step": 4,
            "label": "1-2 beat cuts on a half-beat grid",
        },
        "fast": {
            "grid": "half_beat",
            "segment_min_step": 1,
            "segment_max_step": 2,
            "step_weights": {"1": 1, "2": 4},
            "label": "half- to full-beat cuts, half-beats always paired",
        },
        "aggressive": {
            "grid": "quarter_beat",
            "segment_min_step": 1,
            "segment_max_step": 4,
            "label": "quarter- to full-beat cuts",
        },
    }
    return presets.get((pace or "").lower())


@splicekit_tool("sync_clips_to_song_beats", DESTRUCTIVE)
def sync_clips_to_song_beats(
    mode: str = "beat",
    target_mode: str = "auto",
    overlay_only: bool = False,
    source_handle: str = "",
    dry_run: bool = False,
    random_min_step: int = 1,
    random_max_step: int = 4,
    random_seed: int = 1337,
    min_trim_seconds: float = 0.0,
    min_result_duration: float = 0.0,
) -> str:
    """Sync timeline clips to a selected song's Apple beat map with editor-friendly defaults.

    This is the simpler wrapper over `trim_clips_to_beats()`:
      - source clip: selected beat-detected song, or the first detected song in the timeline
      - targets: selected video clips, overlay clips, or all visible clips depending on `target_mode`

    Args:
        mode: "beat", "half_beat", "quarter_beat", "bar", "section", "random", "random_half_beat", or "random_quarter_beat"
        target_mode: "auto", "selected", "overlay", or "all"
        overlay_only: Shortcut for target_mode="overlay"
        source_handle: Optional handle of the beat-detected song clip
        dry_run: Preview the trim plan without changing the timeline
        random_min_step: Random tail-window minimum when mode is random
        random_max_step: Random tail-window maximum when mode is random
        random_seed: Seed for deterministic random trims
        min_trim_seconds: Skip trims below this size (0 = auto)
        min_result_duration: Skip trims that would leave a shorter result (0 = auto)
    """
    effective_target_mode = "overlay" if overlay_only else target_mode
    randomize = mode in {"random", "random_half", "random_half_beat", "random_quarter", "random_quarter_beat"}
    params = {
        "grid": mode,
        "targetMode": effective_target_mode,
        "randomize": randomize,
        "randomMinStep": random_min_step,
        "randomMaxStep": random_max_step,
        "randomSeed": random_seed,
        "dryRun": dry_run,
    }
    if source_handle:
        params["sourceHandle"] = source_handle
    if min_trim_seconds > 0:
        params["minTrimSeconds"] = min_trim_seconds
    if min_result_duration > 0:
        params["minResultDuration"] = min_result_duration

    r = bridge.call("timeline.trimClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return _format_trim_to_beats_result(r, random_min_step, random_max_step, random_seed)


@splicekit_tool("build_song_cut", DESTRUCTIVE)
def build_song_cut(
    pace: str = "natural",
    project_name: str = "Song Beat Cut",
    event_name: str = "",
    clip_handles: str = "",
    source_handle: str = "",
    source_project_name: str = "",
    clip_source_project_name: str = "",
    max_segments: int = 0,
    random_seed: int = 1337,
    allow_clip_reuse: bool = True,
    include_audio: bool = True,
    build_mode: str = "native",
    target_current_timeline: bool = False,
    dry_run: bool = False,
) -> str:
    """Build a no-gap main-timeline cut against a selected song using simple pacing presets.

    This is the simplified wrapper over `assemble_random_clips_to_song_beats()`:
      - it always creates a contiguous primary-storyline cut
      - it keeps the selected song attached underneath as the timing bed
      - it chooses the beat subdivision and cut length spread from `pace`

    Pace presets:
      - `natural`: mostly whole-beat cuts, sometimes two beats, rarely half-beats
      - `medium`: half-beat grid, random cuts of 1-2 beats
      - `fast`: half-beat grid, random cuts of 0.5-1 beat
      - `aggressive`: quarter-beat grid, random cuts of 0.25-1 beat

    Args:
        pace: "natural", "medium", "fast", or "aggressive"
        project_name: Name of the generated project
        event_name: Optional browser event filter for the clip pool
        clip_handles: Optional JSON array of browser clip handles
        source_handle: Optional handle of the beat-detected song clip in the timeline
        source_project_name: Optional sequence name containing the beat-detected song clip
        clip_source_project_name: Optional sequence name whose timeline clips should form the reusable video pool
        max_segments: Optional hard limit on generated cuts (0 = full song)
        random_seed: Seed for deterministic assembly
        allow_clip_reuse: Reuse browser clips when the pool is smaller than the song
        include_audio: Include the selected song as the audio track in the generated sequence
        build_mode: "native" for direct in-app assembly, or "fcpxml" for the XML import variant
        target_current_timeline: For native builds only, append directly into the active empty timeline instead of creating a new project
        dry_run: Preview the assembly plan without creating the native sequence
    """
    preset = _song_cut_preset(pace)
    if not preset:
        return 'pace must be one of: "natural", "medium", "fast", "aggressive"'

    result = assemble_random_clips_to_song_beats(
        grid=preset["grid"],
        project_name=project_name,
        event_name=event_name,
        clip_handles=clip_handles,
        source_handle=source_handle,
        source_project_name=source_project_name,
        clip_source_project_name=clip_source_project_name,
        segment_min_step=preset["segment_min_step"],
        segment_max_step=preset["segment_max_step"],
        step_weights=json.dumps(preset["step_weights"]) if preset.get("step_weights") else "",
        max_segments=max_segments,
        random_seed=random_seed,
        allow_clip_reuse=allow_clip_reuse,
        include_audio=include_audio,
        build_mode=build_mode,
        target_current_timeline=target_current_timeline,
        dry_run=dry_run,
    )

    prefix = (
        f"Preset: {pace.lower()}  {preset['label']}\n"
        f"Build mode: {build_mode.lower()}\n"
        f"Song attached underneath generated primary storyline"
    )
    return f"{prefix}\n{result}"


@splicekit_tool("assemble_random_clips_to_song_beats", DESTRUCTIVE)
def assemble_random_clips_to_song_beats(
    grid: str = "half_beat",
    project_name: str = "Beat Random Cut",
    event_name: str = "",
    clip_handles: str = "",
    source_handle: str = "",
    source_project_name: str = "",
    clip_source_project_name: str = "",
    segment_min_step: int = 1,
    segment_max_step: int = 4,
    step_weights: str = "",
    max_segments: int = 0,
    random_seed: int = 1337,
    allow_clip_reuse: bool = True,
    include_audio: bool = True,
    build_mode: str = "native",
    target_current_timeline: bool = False,
    dry_run: bool = False,
) -> str:
    """Build a new sequence by randomly assigning browser clips to a selected song's Apple beat map.

    Uses the Apple beat-detected song already on the active timeline as the timing source,
    or from `source_project_name` when the active timeline is just the target container.
    The generated video clips are placed contiguously on the primary storyline with no gaps;
    the song audio is attached underneath as the timing bed.
    The video pool comes from either:
      - timeline clips in `clip_source_project_name`, or
      - browser clips in the active library:
      - if `clip_handles` is provided, use exactly those browser clips
      - else if `event_name` is provided, pull clips from matching events
      - else use all browser video clips in the active library

    Segment timing:
      - `grid` chooses the beat map: beat, half_beat, quarter_beat, bar, or section
      - `segment_min_step..segment_max_step` controls how many grid intervals each cut spans
      - `step_weights` can bias specific step sizes, for example `{"1": 1, "2": 8, "4": 3}`
      - clips are chosen randomly for each segment, with optional reuse

    Args:
        grid: "beat", "half_beat", "quarter_beat", "bar", or "section"
        project_name: Name of the generated random-cut project
        event_name: Optional browser event filter for the clip pool
        clip_handles: Optional JSON array of browser clip handles
        source_handle: Optional handle of the beat-detected song clip in the timeline
        source_project_name: Optional sequence name containing the beat-detected song clip
        clip_source_project_name: Optional sequence name whose timeline clips form the reusable video pool
        segment_min_step: Minimum number of grid intervals per cut
        segment_max_step: Maximum number of grid intervals per cut
          For example, quarter_beat with 1..4 gives random quarter-, half-, three-quarter-, and full-beat cut lengths.
        step_weights: Optional JSON object mapping step size to relative weight
        max_segments: Optional hard limit on generated cuts (0 = full song)
        random_seed: Seed for deterministic assembly
        allow_clip_reuse: Reuse browser clips when the pool is smaller than the song
        include_audio: Include the selected song as the audio track in the generated sequence
        build_mode: "native" for direct in-app assembly, or "fcpxml" for the XML import variant
        target_current_timeline: For native builds only, append directly into the active empty timeline instead of creating a new project
        dry_run: Preview the assembly plan without creating the native sequence
    """
    parsed_clip_handles = []
    if clip_handles:
        try:
            parsed_clip_handles = json.loads(clip_handles)
        except json.JSONDecodeError as e:
            return f"Invalid clip_handles JSON: {e}"
        if not isinstance(parsed_clip_handles, list):
            return "clip_handles must decode to a JSON array of browser clip handles"

    parsed_step_weights = {}
    if step_weights:
        try:
            parsed_step_weights = json.loads(step_weights)
        except json.JSONDecodeError as e:
            return f"Invalid step_weights JSON: {e}"
        if not isinstance(parsed_step_weights, dict):
            return "step_weights must decode to a JSON object of step -> weight"

    params = {
        "grid": grid,
        "projectName": project_name,
        "segmentMinStep": segment_min_step,
        "segmentMaxStep": segment_max_step,
        "randomSeed": random_seed,
        "allowClipReuse": allow_clip_reuse,
        "includeAudio": include_audio,
        "buildMode": build_mode,
        "targetCurrentTimeline": target_current_timeline,
        "dryRun": dry_run,
    }
    if parsed_step_weights:
        params["stepWeights"] = parsed_step_weights
    if event_name:
        params["eventName"] = event_name
    if parsed_clip_handles:
        params["clipHandles"] = parsed_clip_handles
    if source_handle:
        params["sourceHandle"] = source_handle
    if source_project_name:
        params["sourceProjectName"] = source_project_name
    if clip_source_project_name:
        params["clipSourceProjectName"] = clip_source_project_name
    if max_segments > 0:
        params["maxSegments"] = max_segments

    r = bridge.call("timeline.assembleRandomClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    source = r.get("source", {})
    lines = [
        f"{'Previewing' if r.get('dryRun') else 'Built'} {r.get('assignedClipCount', 0)}/{r.get('segmentCount', 0)} beat segments",
        f"Source: {source.get('name', '<unknown>')}  grid={r.get('grid')}  tempo={source.get('tempo', 0):.2f}  pool={r.get('clipPoolCount', 0)}",
        f"Project: {r.get('projectName', project_name)}  build={r.get('buildMethod', 'native')}  gaps={r.get('gapCount', 0)}  seed={r.get('randomSeed', random_seed)}",
    ]
    if not r.get("dryRun"):
        lines.append(
            f"Song attached: {'yes' if r.get('songAudioInserted') else 'no'}"
        )
    for entry in r.get("plan", [])[:12]:
        if entry.get("status") == "gap":
            lines.append(
                f"  gap: {entry.get('timelineStartSeconds', 0):.2f}s +{entry.get('durationSeconds', 0):.2f}s"
            )
        else:
            lines.append(
                f"  {entry.get('clipName', 'Clip')}: {entry.get('timelineStartSeconds', 0):.2f}s "
                f"+{entry.get('durationSeconds', 0):.2f}s from {entry.get('clipEvent', '')}"
            )
    if len(r.get("plan", [])) > 12:
        lines.append(f"  ... {len(r['plan']) - 12} more")
    return "\n".join(lines)
