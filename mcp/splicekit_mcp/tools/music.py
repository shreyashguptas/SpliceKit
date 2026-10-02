"""Tools: beat detection, Final Cut Pro's beat map, song structure, sections bar, FlexMusic."""

import json
import subprocess
import os

from ..config import REPO_ROOT
from ..registry import DESTRUCTIVE, READ, splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge


# ============================================================
# Beat Detection (Any Audio File)
# ============================================================
# Runs an external Swift tool (not in-process, because AVFoundation
# deadlocks inside FCP's hardened runtime). Returns beat/bar/section
# timestamps for syncing video cuts to music.

def _helper_failure(result) -> str:
    """Why a helper CLI failed: stderr when it wrote any, else the JSON {"error": ...}
    the audio helpers print on stdout (e.g. "No audio tracks in file")."""
    if result.stderr.strip():
        return result.stderr.strip()
    try:
        return str(json.loads(result.stdout).get("error") or result.stdout.strip())
    except (ValueError, AttributeError):
        return result.stdout.strip() or f"exit status {result.returncode}"


@splicekit_tool("detect_beats", READ)
def detect_beats(file_path: str, sensitivity: float = 0.5, min_bpm: float = 60.0, max_bpm: float = 200.0,
                 limit: int = 16) -> str:
    """Detect beats, bars, and sections in any audio file (MP3, WAV, M4A, etc.).

    Analyzes the audio using onset detection and tempo estimation.
    Returns precise timestamps for every beat, bar (4 beats), and section (16 beats),
    plus the detected BPM. These timestamps can be fed directly into montage_plan_edit()
    to cut video clips to the rhythm of any song.

    Args:
        file_path: Path to audio file (MP3, WAV, M4A, AAC, AIFF, etc.)
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
                     Higher = more beats detected, lower = only strong beats.
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).
        limit: Max beat/bar/section timestamps to show in the preview (default 16).
               Full counts are always reported; omitted timestamps are summarized.

    Returns beat timestamps, bar timestamps, section timestamps, BPM, and duration.
    """
    # Search common install locations for the beat-detector binary
    tool_paths = [
        os.path.join(REPO_ROOT, "build", "beat-detector"),
        os.path.expanduser("~/Applications/SpliceKit/tools/beat-detector"),
        os.path.expanduser("~/Library/Application Support/SpliceKit/tools/beat-detector"),
        "/usr/local/bin/beat-detector",
    ]
    tool = None
    for p in tool_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            tool = p
            break
    if not tool:
        return "Error: beat-detector tool not found. Re-run the SpliceKit patcher to install tools, or build from source with: swiftc -O -o build/beat-detector helpers/beat-detector.swift"

    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return f"Error: beat-detector failed: {_helper_failure(result)}"
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            return f"Error: beat-detector returned invalid JSON: {e}"

        preview_n = max(0, int(limit))

        def _preview_line(label, times):
            total = len(times)
            if total == 0:
                return f"{label} (0): none"
            shown = times[:preview_n]
            body = ", ".join(f"{t:.2f}s" for t in shown)
            omitted = total - len(shown)
            line = f"{label} ({total}): {body}"
            if omitted > 0:
                line += f" ... {omitted} more omitted (showing first {len(shown)}; pass limit= to see more)"
            return line

        beats = data.get("beats") or []
        bars = data.get("bars") or []
        sections = data.get("sections") or []
        beat_count = data.get("beatCount", len(beats))
        bar_count = data.get("barCount", len(bars))
        section_count = data.get("sectionCount", len(sections))
        onset_count = data.get("onsetCount", 0)
        bpm = data.get("bpm", "?")
        beat_interval = data.get("beatInterval", 0)
        duration = data.get("duration", 0)

        lines = [
            f"Beat Detection: {os.path.basename(file_path)}",
            f"Duration: {duration:.1f}s  BPM: {bpm}  Beat interval: {beat_interval:.4f}s",
            f"Counts: {beat_count} beats, {bar_count} bars, {onset_count} onsets, {section_count} sections",
            "",
            _preview_line("Beats", beats),
            _preview_line("Bars", bars),
            _preview_line("Sections", sections),
        ]
        return "\n".join(lines)
    except subprocess.TimeoutExpired:
        return "Error: beat-detector timed out"
    except Exception as e:
        return f"Error: {e}"


# ============================================================
# Final Cut Pro's Beat Map (timeline.getBeatGrid)
# ============================================================
# Reads the beats, bars, sections and tempo Final Cut Pro's own beat
# detection stored on the songs in the timeline (the data behind its
# beat grid), mapped to timeline seconds. In-process and read-only.

_BEAT_GRID_DETAILS = ("bars", "sections", "json")


def _is_num(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


def _t(value) -> str:
    return f"{value:.3f}s" if _is_num(value) else "?"


def _beat_grid_place(clip: dict) -> str:
    lane = clip.get("lane", 0)
    return "primary storyline" if not lane else f"lane {lane} (connected clip)"


def _beat_grid_tempo_line(clip: dict) -> str:
    parts = []
    if _is_num(clip.get("tempo")):
        parts.append(f"tempo {clip['tempo']:.2f} BPM")
    iv = clip.get("beatIntervalSeconds") if isinstance(clip.get("beatIntervalSeconds"), dict) else {}
    med, lo, hi = iv.get("median"), iv.get("min"), iv.get("max")
    if _is_num(med) and med > 0:
        spacing = f"a beat every {med:.3f}s"
        if _is_num(lo) and _is_num(hi) and (hi - lo) / med > 0.05:
            spacing += f", varying {lo:.3f}-{hi:.3f}s (tempo drifts)"
        else:
            spacing += ", steady"
        parts.append(spacing)
    return "; ".join(parts) if parts else "no tempo stored"


def _render_beat_grid_clip(clip: dict, detail: str) -> list[str]:
    head = (f"\nSong {clip.get('handle')} \"{clip.get('name')}\"  {_beat_grid_place(clip)}  "
            f"{_t(clip.get('startSeconds'))}-{_t(clip.get('endSeconds'))}")
    if clip.get("flexMusic"):
        head += "  [FlexMusic]"
    lines = [head]
    if clip.get("error"):
        lines.append(f"  error: {clip['error']}")
        return lines
    grid = "shown" if clip.get("beatGridVisible") else "hidden"
    lines.append(f"  {_beat_grid_tempo_line(clip)}; beat grid {grid} on the timeline")
    song = clip.get("song") if isinstance(clip.get("song"), dict) else {}
    lines.append(f"  whole song: {song.get('beatCount', 0)} beats, {song.get('barCount', 0)} bars, "
                 f"{song.get('sectionCount', 0)} sections, beats from {_t(song.get('firstBeatSeconds'))} to "
                 f"{_t(song.get('lastBeatSeconds'))} of the song; this clip plays the song from "
                 f"{_t(clip.get('songStartSeconds'))} to {_t(clip.get('songEndSeconds'))}")
    if clip.get("note"):
        lines.append(f"  note: {clip['note']}")

    sections = [s for s in (clip.get("sections") or []) if isinstance(s, dict)]
    if sections:
        lines.append("  Sections (timeline start-end; the part on the timeline when the song is trimmed):")
        for s in sections:
            row = (f"    section {s.get('section')}  {_t(s.get('t'))}-{_t(s.get('endT'))}  "
                   f"{s.get('durationSeconds', 0):.2f}s, {s.get('bars', 0)} bar{'' if s.get('bars') == 1 else 's'} "
                   f"from bar {s.get('firstBar')}")
            if _is_num(s.get("onTimelineT")):
                row += f"  [on the timeline {_t(s.get('onTimelineT'))}-{_t(s.get('onTimelineEndT'))}]"
            lines.append(row)
    elif clip.get("status") != "empty":
        lines.append("  Sections: none in range")

    if detail != "bars":
        return lines

    beats = [b for b in (clip.get("beats") or []) if isinstance(b, dict)]
    bars = {b.get("bar"): b for b in (clip.get("bars") or []) if isinstance(b, dict)}
    by_bar: dict = {}
    for b in beats:
        by_bar.setdefault(b.get("bar", 0), []).append(b)
    if not beats and not bars:
        lines.append("  Beats: none in range")
        return lines
    lines.append("  Bars, each with its beats in timeline seconds (the first beat of a bar is its downbeat; "
                 "S<n> marks the bar that starts section n):")
    for n in sorted(set(by_bar) | set(bars), key=lambda v: v if _is_num(v) else -1):
        bar = bars.get(n, {})
        times = " ".join(f"{b['t']:.3f}" for b in by_bar.get(n, []) if _is_num(b.get("t")))
        if n == 0:
            lines.append(f"    pickup (before bar 1): {times}")
            continue
        tag = f"S{bar.get('section')}" if bar.get("sectionStart") else ""
        lines.append(f"    bar {n:<4} {tag:<4} {times}")
    return lines


def _render_beat_grid(r: dict, detail: str) -> str:
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    clips = [c for c in (r.get("clips") or []) if isinstance(c, dict)]
    detectable = [c for c in (r.get("detectable") or []) if isinstance(c, dict)]
    unsupported = [c for c in (r.get("unsupported") or []) if isinstance(c, dict)]

    head = ("Final Cut Pro's beat map (its own beat detection, the data behind the beat grid). "
            "Times are timeline seconds; bars and sections are numbered from the start of the song, "
            "so the numbers stay the same when the song is trimmed or moved. The hierarchy is the "
            "strength: a section start is also a downbeat, a downbeat is also a beat.")
    lines = [head]
    meta = []
    ranged = _is_num(tl.get("rangeStartSeconds")) or _is_num(tl.get("rangeEndSeconds"))
    if _is_num(tl.get("frameRate")):
        meta.append(f"timeline {tl['frameRate']:g} fps")
    if _is_num(tl.get("durationSeconds")):
        meta.append(f"{tl['durationSeconds']:.3f}s long")
    if ranged:
        meta.append(f"range {_t(tl.get('rangeStartSeconds')) if _is_num(tl.get('rangeStartSeconds')) else 'start'}"
                    f" to {_t(tl.get('rangeEndSeconds')) if _is_num(tl.get('rangeEndSeconds')) else 'end'}")
    if tl.get("supportsBeatDetection") is False:
        meta.append("this project type does not support beat detection")
    if meta:
        lines.append("; ".join(meta) + ".")

    if not clips:
        lines.append("\nNo song on this timeline has a beat map" + (" in that range." if ranged else "."))
    for clip in clips:
        lines.extend(_render_beat_grid_clip(clip, detail))

    if detectable:
        lines.append("\nAudio clips Final Cut Pro can detect beats on but has not yet:")
        for c in detectable:
            lines.append(f"  {c.get('handle')} \"{c.get('name')}\"  {_beat_grid_place(c)}  "
                         f"{_t(c.get('startSeconds'))}-{_t(c.get('endSeconds'))}")
        first = detectable[0].get("handle")
        lines.append(f"  To detect: select_clips(handles=[\"{first}\"]), then "
                     f"timeline_action(\"enableBeatDetection\"); the analysis runs in the background, "
                     f"then call get_beat_grid again.")
    for c in unsupported:
        lines.append(f"\n{c.get('handle')} \"{c.get('name')}\": no beat map, and Final Cut Pro cannot detect "
                     f"beats on it: {c.get('reason')}.")
    return "\n".join(lines)


@splicekit_tool("get_beat_grid", READ)
def get_beat_grid(handle: str = "", start_seconds: float | None = None,
                  end_seconds: float | None = None, detail: str = "bars") -> str:
    """Final Cut Pro's own beat map for the songs on the timeline: every beat, bar and
    section, and the tempo, in timeline seconds. This is what Final Cut Pro's beat
    detection (timeline_action("enableBeatDetection")) stores on an audio clip and draws as
    its beat grid. Use it to place and cut B-roll on the music: a cut on a downbeat (the
    first beat of a bar) or a section start lands harder than one on an off-beat, and a
    section change is where a montage should change pace. Read-only: never moves the
    playhead or the selection.

    What it reports, per song with a beat map:
      - tempo (BPM) and the beat spacing, flagged when the tempo drifts;
      - sections as timeline ranges with their length in bars;
      - every bar with its beats (detail="bars"): the first time on a line is the bar's
        downbeat; S<n> marks the bar that starts section n; beats before the first bar are
        a pickup;
      - whether the beat grid is shown on the timeline.
    Bars and sections are numbered from the start of the song, so the numbers stay the same
    when the song is trimmed or moved; only the times change. The times are read fresh on
    every call: after trimming, moving or replacing the music, call this again. Only the
    part of the song the timeline plays is listed (and only the window, when given).

    Final Cut Pro stores no per-beat strength: the hierarchy is the strength (section start,
    then downbeat, then beat). The beat map lives on audio-only clips; a clip with video in
    it is never analysed by Final Cut Pro (use detect_beats on its source file for
    SpliceKit's own, simpler analysis). A beat map is not redone on its own: a new or
    replaced song is listed under "can detect beats on but has not yet", with the two calls
    that run the detection. Times assume the song plays at normal speed (100%); a retimed
    song is flagged.

    Feed the times to blade_at_times, add_markers_at_times or trim_clip; trim_clips_to_beats
    and sync_clips_to_song_beats trim clips to this same map in one call.

    Args:
        handle: one clip (get_timeline_clips()); its beat map, or why it has none. Omit for
            every song on the timeline.
        start_seconds: only beats, bars and sections at or after this timeline time.
        end_seconds: only those at or before this time.
        detail: "bars" (default: sections plus every bar with its beats), "sections"
            (tempo and sections only), or "json" (the raw answer, every beat with its
            index, bar, beat-in-bar, section, level and the time in the song).
    """
    if not isinstance(handle, str):
        return "Error: handle must be a string"
    if detail not in _BEAT_GRID_DETAILS:
        return f"Error: detail must be one of {', '.join(_BEAT_GRID_DETAILS)}"
    params = {}
    for name, key, value in (("start_seconds", "startSeconds", start_seconds),
                             ("end_seconds", "endSeconds", end_seconds)):
        if value is None:
            continue
        if not _is_num(value) or value in (float("inf"), float("-inf")):
            return f"Error: {name} must be a finite number of seconds"
        params[key] = float(value)
    if "startSeconds" in params and "endSeconds" in params and params["endSeconds"] <= params["startSeconds"]:
        return "Error: end_seconds must be after start_seconds"
    if handle.strip():
        params["handle"] = handle.strip()

    r = bridge.call("timeline.getBeatGrid", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if detail == "json":
        return _fmt(r)
    return _render_beat_grid(r, detail)


# ============================================================
# Song Structure Analysis
# ============================================================
# Extends beat detection with song structure labeling (verse,
# chorus, bridge, intro, outro) using energy contour + spectral
# features. Also returns drop points and per-bar energy.

def _find_structure_analyzer():
    """Find the structure-analyzer binary."""
    tool_paths = [
        os.path.join(REPO_ROOT, "build", "structure-analyzer"),
        os.path.expanduser("~/Applications/SpliceKit/tools/structure-analyzer"),
        os.path.expanduser("~/Library/Application Support/SpliceKit/tools/structure-analyzer"),
        "/usr/local/bin/structure-analyzer",
    ]
    for p in tool_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None



def _run_structure_analyzer(file_path: str, sensitivity: float = 0.5,
                             min_bpm: float = 60.0, max_bpm: float = 200.0) -> dict:
    """Run structure-analyzer and return parsed JSON dict (or dict with 'error' key)."""
    tool = _find_structure_analyzer()
    if not tool:
        return {"error": "structure-analyzer tool not found. Build with: swiftc -O -o build/structure-analyzer helpers/structure-analyzer.swift"}
    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return {"error": f"structure-analyzer failed: {_helper_failure(result)}"}
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        return {"error": "structure-analyzer timed out"}
    except json.JSONDecodeError as e:
        return {"error": f"structure-analyzer returned invalid JSON: {e}"}
    except Exception as e:
        return {"error": str(e)}


@splicekit_tool("analyze_song_structure", READ)
def analyze_song_structure(file_path: str, sensitivity: float = 0.5,
                           min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Analyze a song's structure — detect verse, chorus, bridge, intro, outro sections.

    Goes beyond basic beat detection: segments the song by energy + spectral
    features, groups similar sections (repeated verses/choruses), detects
    "drop" points (sudden energy spikes), and returns per-bar energy contour.

    Args:
        file_path: Path to audio file (MP3, WAV, M4A, AAC, AIFF, etc.)
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns labeled song structure, beats, bars, BPM, drops, and energy contour.
    """
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    lines = [
        f"Song Structure Analysis: {os.path.basename(file_path)}",
        f"Duration: {data['duration']:.1f}s  BPM: {data['bpm']}  Bars: {data['barCount']}  Beats: {data['beatCount']}",
        "",
        "Structure:",
    ]
    for s in data.get("structure", []):
        lines.append(f"  {s['label']:15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  "
                     f"({s['bars']:2d} bars, energy={s['energy']:.2f}, {s['duration']:.1f}s)")

    drops = data.get("drops", [])
    if drops:
        lines.append(f"\nDrops ({len(drops)}): {', '.join(f'{d:.1f}s' for d in drops)}")

    lines.append(f"\nBeat interval: {data.get('beatInterval', 0):.4f}s")
    return "\n".join(lines)


@splicekit_tool("beat_sync_blade", DESTRUCTIVE)
def beat_sync_blade(file_path: str, cut_on: str = "bar",
                    sensitivity: float = 0.5, min_bpm: float = 60.0,
                    max_bpm: float = 200.0,
                    range_start: float = -1, range_end: float = -1,
                    min_clip_duration: float = 0,
                    offset_frames: int = 0,
                    dry_run: bool = False) -> str:
    """Analyze a song's beats and blade the timeline at musical boundaries.

    Combines beat/structure analysis with blade_at_times in a single call.
    Detects beats in the audio file, then cuts the FCP timeline at the
    selected musical level (every beat, bar, section, etc.).

    Args:
        file_path: Path to audio file to analyze for beat timing.
        cut_on: What to cut on. Options:
            "beat"     — every beat (fast cuts, ~0.5s at 120 BPM)
            "bar"      — every bar/measure (natural pacing, ~2s at 120 BPM)
            "section"  — at structural section boundaries (verse/chorus/bridge)
            "downbeat" — only on beat 1 of each bar (same as "bar")
            "drop"     — only at detected drop points (dramatic energy spikes)
            "half_bar" — every 2 beats
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).
        range_start: Only blade after this time in seconds (-1 = from start).
        range_end: Only blade before this time in seconds (-1 = to end).
        min_clip_duration: Skip cuts that would create clips shorter than this (seconds).
                           Prevents flash frames at fast tempos.
        offset_frames: Shift all cuts by N frames. Negative = cut before the beat
                       (anticipation feel), positive = cut after (laid-back feel).
                       Typical: -2 for music video anticipation.
        dry_run: If True, return the cut plan without actually blading.

    Returns summary of cuts applied (or planned if dry_run).
    """
    # Run structure analysis (includes beats, bars, structure, drops)
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    bpm = data.get("bpm", 120)
    beat_interval = data.get("beatInterval", 0.5)

    # Select timestamps based on cut_on mode
    if cut_on == "beat":
        times = data.get("beats", [])
        level_desc = "beat"
    elif cut_on in ("bar", "downbeat"):
        times = data.get("bars", [])
        level_desc = "bar"
    elif cut_on == "half_bar":
        # Every 2 beats
        beats = data.get("beats", [])
        times = [beats[i] for i in range(0, len(beats), 2)]
        level_desc = "half-bar (every 2 beats)"
    elif cut_on == "section":
        # Use structural section boundaries
        structure = data.get("structure", [])
        times = [s["start"] for s in structure]
        level_desc = "section boundary"
    elif cut_on == "drop":
        times = data.get("drops", [])
        level_desc = "drop"
    else:
        return f"Error: unknown cut_on value '{cut_on}'. Use: beat, bar, section, downbeat, drop, half_bar"

    if not times:
        return f"Error: no {level_desc} timestamps found in audio analysis"

    # Apply time range filter
    if range_start >= 0:
        times = [t for t in times if t >= range_start]
    if range_end >= 0:
        times = [t for t in times if t <= range_end]

    # Apply frame offset (convert frames to seconds using common frame rates)
    if offset_frames != 0:
        # Estimate frame rate from beat interval: use 24fps as default
        # (FCP projects are typically 23.976, 24, 25, 29.97, or 30 fps)
        frame_duration = 1.0 / 24.0  # ~0.0417s per frame
        offset_seconds = offset_frames * frame_duration
        times = [t + offset_seconds for t in times]
        # Remove any that went negative
        times = [t for t in times if t > 0]

    # Apply minimum clip duration filter
    if min_clip_duration > 0 and len(times) > 1:
        filtered = [times[0]]
        for t in times[1:]:
            if (t - filtered[-1]) >= min_clip_duration:
                filtered.append(t)
        times = filtered

    # Skip the first timestamp if it's at 0.0 (nothing to blade there)
    times = [t for t in times if t > 0.05]

    if not times:
        return "No cut points remain after filtering"

    # Build summary. The numbered rows are the blade points. The song's end is
    # not a cut (there is nothing to blade there); it is printed afterwards and
    # is not part of cut_rows, so the "Cuts:" count and the numbered list are
    # the same list. Counting len(times) and then numbering the end as one more
    # row made the header say 16 while the list ran to 17.
    structure = data.get("structure", [])
    struct_summary = ""
    if structure:
        labels = [s["label"] for s in structure]
        struct_summary = f"\nSong structure: {' → '.join(labels)}"

    cut_rows = []
    prev = 0.0
    for t in times:
        cut_rows.append((t, t - prev))
        prev = t

    header = (
        f"Beat Sync Blade: {os.path.basename(file_path)}\n"
        f"BPM: {bpm}  Cut on: {level_desc}  Cuts: {len(cut_rows)}{struct_summary}\n"
    )

    if dry_run:
        lines = [header + "DRY RUN — no cuts applied\n"]
        lines.append("Planned cuts:")
        for i, (t, clip_dur) in enumerate(cut_rows):
            lines.append(f"  {i+1:3d}. {t:7.2f}s  (clip: {clip_dur:.2f}s)")
        duration = data.get("duration", 0)
        if duration > 0 and cut_rows:
            last_t = cut_rows[-1][0]
            lines.append(f"  end {duration:7.2f}s  (clip: {duration - last_t:.2f}s)  [end]")
        lines.append(f"\nShortest clip: {min(clip_dur for _, clip_dur in cut_rows):.2f}s")
        return "\n".join(lines)

    # Execute the blade
    r = bridge.call("timeline.bladeAtTimes", times=times)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    applied = r.get("applied", 0)
    total = r.get("count", len(times))
    lines = [header + f"Applied {applied}/{total} cuts"]

    failures = [c for c in r.get("cuts", []) if not c.get("success")]
    if failures:
        lines.append(f"\nFailed cuts ({len(failures)}):")
        for c in failures[:10]:
            lines.append(f"  {c['time']:.2f}s: {c.get('error', '?')}")

    return "\n".join(lines)


# ============================================================
# Song Structure Blocks (Color-Coded Timeline Sections)
# ============================================================
# Places song structure labels in FCP's native caption lane — the
# thin dedicated area above the timeline clips. Uses FCPXML <caption>
# elements; Final Cut Pro assigns them to the library's normal SRT caption
# role (e.g. English), not a separate "structure" role.

@splicekit_tool("song_structure_blocks", DESTRUCTIVE)
def song_structure_blocks(file_path: str, sensitivity: float = 0.5,
                          min_bpm: float = 60.0, max_bpm: float = 200.0,
                          at_seconds: float = 0.0) -> str:
    """Analyze a song and write section labels to the timeline caption lane.

    This tool modifies the active timeline: it creates native FFAnchoredCaption
    objects (one per detected section) in FCP's caption lane. Section times in
    the analysis are placed on the timeline starting at ``at_seconds`` (default 0,
    so intro at 0s lines up with timeline 0s). If the labels extend past the end
    of the sequence, Final Cut Pro may append gap media and lengthen the project.

    Remove labels with ``remove_structure_blocks()`` (one undo step).

    Args:
        file_path: Path to audio file to analyze for song structure.
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).
        at_seconds: Timeline time (seconds) where section 0.0s should be placed (default 0).

    Returns summary of structure blocks placed in the caption lane.
    """
    # Run structure analysis
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    structure = data.get("structure", [])
    if not structure:
        return "Error: no song structure detected"

    # The captions are built natively on the ObjC side from `structure`. There used to be
    # forty lines here that assembled an <fcpxml> document — and a playback.getPosition
    # round trip purely to get a frame duration for its rational times — into a local that
    # was never read. structure.generateCaptions replaced that FCPXML import long ago;
    # the scaffolding was left behind.
    r = bridge.call("structure.generateCaptions", sections=structure, atSeconds=at_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    caption_count = r.get("captionCount", 0)
    lines = [
        f"Structure Blocks: {os.path.basename(file_path)}",
        f"BPM: {data.get('bpm', '?')}  Sections: {len(structure)}  Captions placed: {caption_count}",
        f"Placed in caption lane starting at timeline {at_seconds:.3f}s",
        "",
    ]
    if r.get("extendsPastSequenceEnd"):
        seq_dur = r.get("sequenceDurationSeconds", "?")
        labels_end = r.get("labelsEndSeconds", "?")
        lines.append(
            f"WARNING: Labels extend to ~{labels_end}s but the sequence is only ~{seq_dur}s long. "
            "Final Cut Pro may append gap media and lengthen the project."
        )
        lines.append("")
    if r.get("appendedSpineGapRecorded"):
        lines.append(
            f"Recorded pre-paste duration {r.get('prePasteDurationSeconds')}s. "
            "remove_structure_blocks() deletes the primary-storyline gap that begins at or after it, "
            "including after Final Cut Pro restarts."
        )
        lines.append("")
    for s in structure:
        lines.append(f"  {s['label'].upper():15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  ({s['duration']:.1f}s)")

    lines.append(f"\nToggle visibility: View > Timeline Index > Captions tab")
    lines.append("Remove: remove_structure_blocks()")
    return "\n".join(lines)


# DESTRUCTIVE: deletes the structure storyline whenever one is on the timeline (same code
# path as remove_structure_blocks). It was READ_ONLY and idempotent, which invited an
# agent to call it speculatively and silently lose the blocks.
@splicekit_tool("toggle_structure_blocks", DESTRUCTIVE, title="Remove Structure Blocks (Toggle)")
def toggle_structure_blocks() -> str:
    """Remove the song structure block storyline from the timeline, if one is there.

    This is not a visibility toggle and it is not reversible: when structure blocks are
    on the timeline it DELETES them, by the same code path as ``remove_structure_blocks``.
    Calling it a second time does not bring them back — it returns an error, because there
    is now nothing to remove. Rebuild them with ``song_structure_blocks``.

    Returns how many structure block storylines were removed.
    """
    r = bridge.call("structure.toggle")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    removed = r.get("removed", 0)
    if removed > 0:
        return f"Removed {removed} structure block storyline(s)"
    return _fmt(r)


@splicekit_tool("remove_structure_blocks", DESTRUCTIVE)
def remove_structure_blocks(dry_run: bool = False) -> str:
    """Remove song structure block storylines, structure captions, and the gap they appended.

    Only deletes captions created by ``song_structure_blocks`` (session registry, or
    fallback match on exact generated section labels like INTRO, VERSE1 — never by role).
    Also deletes trailing primary-storyline gap generators that begin at or after the
    sequence duration recorded before that paste. A gap that starts earlier is left alone.
    The duration is stored in Final Cut Pro's preferences, so it survives a restart.
    """
    r = bridge.call("structure.remove", dryRun=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    storylines = int(r.get("removedStorylines", 0))
    captions = int(r.get("removedCaptions", 0))
    gaps = int(r.get("removedSpineGaps", 0))
    caption_rows = r.get("captions") or []
    gap_rows = r.get("spineGaps") or []
    pre_paste = r.get("prePasteDurationSeconds")

    def _format_caption_row(row: dict) -> str:
        text = row.get("text", "?")
        start = row.get("startSeconds")
        end = row.get("endSeconds")
        if start is not None and end is not None:
            return f'  "{text}"  {float(start):.3f}s – {float(end):.3f}s'
        return f'  "{text}"'

    def _format_gap_row(row: dict) -> str:
        cls = row.get("class") or "gap"
        name = row.get("name") or "Gap"
        start = row.get("startSeconds")
        end = row.get("endSeconds")
        if start is not None and end is not None:
            return f'  {cls} "{name}"  {float(start):.3f}s – {float(end):.3f}s'
        return f'  {cls} "{name}"'

    def _gap_heading(count: int) -> str:
        if pre_paste is None:
            return f"  {count} primary-storyline gap(s):"
        return (
            f"  {count} primary-storyline gap(s) beginning at or after "
            f"{float(pre_paste):.3f}s:"
        )

    if dry_run:
        if storylines == 0 and captions == 0 and gaps == 0:
            return (
                "Dry run: no structure block storylines, structure captions, "
                "or appended primary-storyline gaps would be removed."
            )
        lines = ["Dry run — would remove:"]
        if storylines:
            lines.append(f"  {storylines} storyline(s) named SpliceKit Structure")
        if captions:
            lines.append(f"  {captions} structure caption(s):")
            for row in caption_rows:
                lines.append(_format_caption_row(row))
        if gaps:
            lines.append(_gap_heading(gaps))
            for row in gap_rows:
                lines.append(_format_gap_row(row))
        return "\n".join(lines)

    if storylines == 0 and captions == 0 and gaps == 0:
        return (
            "No structure block storylines, structure captions, "
            "or appended primary-storyline gaps were found on the timeline."
        )

    lines = ["Removed structure blocks:"]
    if storylines:
        lines.append(f"  {storylines} storyline(s)")
    if captions:
        lines.append(f"  {captions} structure caption(s):")
        for row in caption_rows:
            lines.append(_format_caption_row(row))
    if gaps:
        lines.append(_gap_heading(gaps))
        for row in gap_rows:
            lines.append(_format_gap_row(row))
    return "\n".join(lines)


# ============================================================
# Sections Bar (Custom Timeline View)
# ============================================================
# A dedicated color-coded bar injected into FCP's timeline showing
# song structure sections. Each section has its own color and can be
# modified via right-click context menu or these MCP tools.

@splicekit_tool("song_structure_sections", DESTRUCTIVE)
def song_structure_sections(file_path: str, sensitivity: float = 0.5,
                             min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Analyze a song and display color-coded sections in a dedicated bar above the timeline.

    Creates a thin, color-coded bar above the FCP timeline showing the song
    structure (intro, verse, chorus, bridge, outro). Each section type gets
    its own color. Right-click any section to change its color, rename it,
    or remove it. Right-click empty space to add new sections.

    The sections bar is a custom view — independent from captions, roles,
    or any other FCP system. Sections persist per-project.

    Args:
        file_path: Path to audio file to analyze.
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns summary of sections placed in the bar.
    """
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    structure = data.get("structure", [])
    if not structure:
        return "Error: no song structure detected"

    r = bridge.call("sections.show", sections=structure)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [
        f"Sections Bar: {os.path.basename(file_path)}",
        f"BPM: {data.get('bpm', '?')}  Sections: {r.get('sectionCount', len(structure))}",
        "",
    ]
    for s in structure:
        lines.append(f"  {s['label']:15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  ({s['duration']:.1f}s)")
    lines.append(f"\nRight-click the sections bar to change colors, rename, add, or remove sections.")
    return "\n".join(lines)


@splicekit_tool("sections_get", READ, title="Get Sections")
def sections_get() -> str:
    """Get the current sections displayed in the timeline sections bar."""
    return _call_or_error("sections.get")


@splicekit_tool("sections_hide", DESTRUCTIVE, title="Hide Sections")
def sections_hide() -> str:
    """Hide the sections bar from the timeline."""
    r = bridge.call("sections.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Sections bar hidden"


# ============================================================
# FlexMusic (Dynamic Soundtrack)
# ============================================================
# FCP's built-in AI music engine. Songs can stretch/shrink to
# any duration by rearranging their musical sections dynamically.

# Said when FlexMusicKit's song library lists nothing: what is missing, whose content it
# is, and what would make the flexmusic_* / montage tools work.
FLEXMUSIC_NONE_INSTALLED = (
    "no FlexMusic songs are installed on this Mac: FlexMusicKit's song library (FMSongLibrary) "
    "lists none. FlexMusic songs are Apple's soundtrack content for Final Cut Pro; SpliceKit cannot "
    "create or download them. Once Final Cut Pro has soundtrack songs available, flexmusic_list_songs "
    "lists them with the song_uid these tools take.")


def _flexmusic_song_error(r) -> str:
    """Error text for a bridge answer that could not find a song: when the library is
    empty that is the reason, not the uid."""
    message = str(r.get("error", r)) if isinstance(r, dict) else str(r)
    if "Song not found" not in message:
        return f"Error: {message}"
    listed = bridge.call("flexmusic.listSongs", filter="")
    count = None if _err(listed) else int(listed.get("count", 0) or 0)
    if count == 0:
        return f"Error: {message}: {FLEXMUSIC_NONE_INSTALLED}"
    if count:
        return (f"Error: {message}: no installed FlexMusic song has that song_uid "
                f"({count} installed; flexmusic_list_songs lists them)")
    return f"Error: {message}"


def _flexmusic_call(method: str, **params) -> str:
    r = bridge.call(method, **params)
    if _err(r):
        return _flexmusic_song_error(r)
    return _fmt(r)


@splicekit_tool("flexmusic_list_songs", READ, title="List FlexMusic Songs")
def flexmusic_list_songs(filter: str = "") -> str:
    """List available FlexMusic songs that can dynamically fit any project duration.

    FlexMusic / Soundtrack Pro content must be installed in Final Cut Pro for songs
    to appear; an empty library is normal when none is installed.

    Args:
        filter: Optional search filter for song name, mood, or genre.

    Returns list of songs with uid, name, artist, mood, pace, and genres.
    Songs dynamically adjust their arrangement to match any target duration.
    """
    r = bridge.call("flexmusic.listSongs", filter=filter)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    count = int(r.get("count", 0))
    if count == 0:
        return ("No FlexMusic songs are available" + (f" matching '{filter}'" if filter else "")
                + ("." if filter else f": {FLEXMUSIC_NONE_INSTALLED}"))
    return _fmt(r)


@splicekit_tool("flexmusic_get_song", READ, title="Get FlexMusic Song")
def flexmusic_get_song(song_uid: str) -> str:
    """Get detailed info about a specific FlexMusic song.

    Args:
        song_uid: The unique identifier of the song.

    Returns metadata (mood, pace, genres, arousal, valence),
    natural duration, minimum duration, and ideal durations.
    """
    return _flexmusic_call("flexmusic.getSong", songUID=song_uid)


@splicekit_tool("flexmusic_get_timing", READ, title="Get FlexMusic Timing")
def flexmusic_get_timing(song_uid: str, duration_seconds: float) -> str:
    """Get beat, bar, and section timing for a FlexMusic song fitted to a specific duration.

    The song's arrangement is dynamically computed to fit the requested duration.
    Returns precise timestamps for every beat, bar, and section boundary.
    These timestamps can be used to cut video clips to the rhythm.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration in seconds to fit the song to.

    Returns arrays of beat timestamps, bar timestamps, section timestamps,
    and the actual fitted duration.
    """
    return _flexmusic_call("flexmusic.getTiming", songUID=song_uid, durationSeconds=duration_seconds)


@splicekit_tool("flexmusic_render_to_file", DESTRUCTIVE, title="Render FlexMusic To File")
def flexmusic_render_to_file(song_uid: str, duration_seconds: float, output_path: str, format: str = "m4a") -> str:
    """Render a FlexMusic song fitted to a specific duration as an audio file.

    The song arrangement is dynamically computed to perfectly fill the duration,
    then rendered to a standard audio file that can be imported into any project.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration in seconds.
        output_path: Where to save the rendered audio file.
        format: Audio format - "m4a" (AAC, default) or "wav".
    """
    return _flexmusic_call("flexmusic.renderToFile", songUID=song_uid,
                          durationSeconds=duration_seconds, outputPath=output_path, format=format)


@splicekit_tool("flexmusic_add_to_timeline", DESTRUCTIVE, title="Add FlexMusic To Timeline")
def flexmusic_add_to_timeline(song_uid: str, duration_seconds: float = 0) -> str:
    """Add a FlexMusic song to the current timeline as background music.

    The song dynamically fits to the specified duration (or the timeline duration
    if not specified). It will automatically re-arrange if the project length changes.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration (0 = use current timeline duration).
    """
    return _flexmusic_call("flexmusic.addToTimeline", songUID=song_uid,
                          durationSeconds=duration_seconds)
