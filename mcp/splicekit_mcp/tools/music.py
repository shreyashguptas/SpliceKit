"""Tools: beat detection, song structure, sections bar, FlexMusic."""

import json

from ..config import REPO_ROOT
from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Beat Detection (Any Audio File)
# ============================================================
# Runs an external Swift tool (not in-process, because AVFoundation
# deadlocks inside FCP's hardened runtime). Returns beat/bar/section
# timestamps for syncing video cuts to music.

@splicekit_tool("detect_beats")
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
    import subprocess, os
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
        return "Error: beat-detector tool not found. Re-run the SpliceKit patcher to install tools, or build from source with: swiftc -O -o build/beat-detector tools/beat-detector.swift"

    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return f"Error: beat-detector failed: {result.stderr}"
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
# Song Structure Analysis
# ============================================================
# Extends beat detection with song structure labeling (verse,
# chorus, bridge, intro, outro) using energy contour + spectral
# features. Also returns drop points and per-bar energy.

def _find_structure_analyzer():
    """Find the structure-analyzer binary."""
    import os
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
    import subprocess
    tool = _find_structure_analyzer()
    if not tool:
        return {"error": "structure-analyzer tool not found. Build with: swiftc -O -o build/structure-analyzer tools/structure-analyzer.swift"}
    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return {"error": f"structure-analyzer failed: {result.stderr}"}
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        return {"error": "structure-analyzer timed out"}
    except json.JSONDecodeError as e:
        return {"error": f"structure-analyzer returned invalid JSON: {e}"}
    except Exception as e:
        return {"error": str(e)}


@splicekit_tool("analyze_song_structure")
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
    import os
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


@splicekit_tool("beat_sync_blade")
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
    import os
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

@splicekit_tool("song_structure_blocks")
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
    import os
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


@splicekit_tool("toggle_structure_blocks")
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


@splicekit_tool("remove_structure_blocks")
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

@splicekit_tool("song_structure_sections")
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
    import os
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


@splicekit_tool("sections_get")
def sections_get() -> str:
    """Get the current sections displayed in the timeline sections bar."""
    r = bridge.call("sections.get")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("sections_hide")
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

@splicekit_tool("flexmusic_list_songs")
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
        return "No FlexMusic songs are available."
    return _fmt(r)


@splicekit_tool("flexmusic_get_song")
def flexmusic_get_song(song_uid: str) -> str:
    """Get detailed info about a specific FlexMusic song.

    Args:
        song_uid: The unique identifier of the song.

    Returns metadata (mood, pace, genres, arousal, valence),
    natural duration, minimum duration, and ideal durations.
    """
    r = bridge.call("flexmusic.getSong", songUID=song_uid)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("flexmusic_get_timing")
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
    r = bridge.call("flexmusic.getTiming", songUID=song_uid, durationSeconds=duration_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("flexmusic_render_to_file")
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
    r = bridge.call("flexmusic.renderToFile", songUID=song_uid,
                     durationSeconds=duration_seconds, outputPath=output_path, format=format)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("flexmusic_add_to_timeline")
def flexmusic_add_to_timeline(song_uid: str, duration_seconds: float = 0) -> str:
    """Add a FlexMusic song to the current timeline as background music.

    The song dynamically fits to the specified duration (or the timeline duration
    if not specified). It will automatically re-arrange if the project length changes.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration (0 = use current timeline duration).
    """
    r = bridge.call("flexmusic.addToTimeline", songUID=song_uid,
                     durationSeconds=duration_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)
