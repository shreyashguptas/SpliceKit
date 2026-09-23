# Scene & Beat Detection Guide

Automatically detect scene changes in video and beats in audio for
intelligent editing workflows.

---

## Table of Contents

1. [Overview](#overview)
2. [Scene Change Detection](#scene-change-detection)
3. [Beat Detection](#beat-detection)
4. [Combined Workflows](#combined-workflows)

---

## Overview

SpliceKit provides two analysis tools that detect structural boundaries in
media — scene changes in video and beats in audio. These can be used
independently or together to automate editing decisions:

| Tool | Input | Detects | Use Case |
|------|-------|---------|----------|
| `detect_scene_changes()` | One timeline clip (or a file) | Cuts, transitions, shot boundaries | Review cuts, then `mark_scene_changes()` / `blade_scene_changes()` |
| `detect_beats()` | Audio file | Beats, bars, sections, BPM | Cut video to music rhythm |

---

## Scene Change Detection

Analyzes one timeline clip's video (only the part of its media the clip uses) to detect
cuts and shot boundaries using histogram comparison (the same approach FCP uses
internally). Three tools share the same analysis:

| Tool | What it does |
|------|--------------|
| `detect_scene_changes()` | Read-only: lists the cuts with scores |
| `mark_scene_changes()` | Adds a marker at each cut (one undo step) |
| `blade_scene_changes()` | Blades the timeline at each cut (one undo step) |

**Target clip** (the same for all three): `handle` if given; else the sole selected clip;
else the primary-storyline clip under the playhead; else an error listing spine candidates.
A compound, multicam or synchronized clip is refused; pass `handle` to an inner clip or use
`file_url` on the underlying file. Reported times are **source media seconds**;
`mark_scene_changes` and `blade_scene_changes` map them onto the clip, and refuse
`file_url` mode (there is nothing to map the cuts onto).

### Basic Detection

```python
# Detect scene changes with default settings
detect_scene_changes()
```

Returns a list of timestamps where scene changes were detected, with confidence
scores for each:

```
Scene changes: 12 (threshold=0.35, file=interview.mov)

  2.30s  (score: 0.892)
  5.10s  (score: 0.756)
  8.45s  (score: 0.934)
  12.80s (score: 0.671)
  ...
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `threshold` | 0.35 | Sensitivity (0.0–1.0). Lower = more sensitive, detects subtle changes. Higher = only strong cuts. |
| `handle` | `""` | Timeline clip handle from `get_timeline_clips()` (required for an inner clip of a compound/multicam) |
| `file_url` | `""` | Analyse this media file directly (read-only; no timeline mapping) |
| `sample_interval` | 0.1 | Seconds between sampled frames. Lower = more accurate but slower. |

### Adjusting Sensitivity

```python
# Very sensitive — detect even subtle changes (pans, lighting shifts)
detect_scene_changes(threshold=0.15)

# Less sensitive — only detect hard cuts
detect_scene_changes(threshold=0.6)

# Faster analysis with larger sample interval
detect_scene_changes(threshold=0.35, sample_interval=0.25)
```

### Auto-Blade at Scene Changes

```python
# Automatically blade the timeline at every detected scene change
blade_scene_changes()
```

This performs a blade operation at each detected timestamp, splitting the
timeline into individual shots.

### Mark Scene Changes

```python
# Add markers at scene changes (non-destructive)
mark_scene_changes()
```

Adds standard markers at each detected cut point for review before making
any edits.

### Workflow: Auto-Segment Long Footage

```python
# 1. Detect scene changes and add markers for review
mark_scene_changes(threshold=0.3)

# 2. Review the markers, then blade if they look right
blade_scene_changes(threshold=0.3)

# 3. Now each shot is a separate clip — rate, rearrange, or delete
```

`detect_scene_changes(action="markers")` and `action="blade"` are rejected; the `action`
argument only accepts `"detect"` and remains for compatibility.

---

## Beat Detection

Analyzes any audio file to detect beats, bars, sections, and BPM using onset
detection and tempo estimation. Runs as an external process to avoid
AVFoundation deadlocks inside FCP.

### Basic Detection

```python
# Detect beats in an audio file
detect_beats(file_path="/path/to/music.mp3")
```

Returns beat timestamps, bar timestamps (every 4 beats), section timestamps
(every 16 beats), detected BPM, and total duration.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `file_path` | (required) | Path to audio file (MP3, WAV, M4A, AAC, AIFF) |
| `sensitivity` | 0.5 | Detection sensitivity (0.0–1.0). Higher = more beats detected. |
| `min_bpm` | 60.0 | Minimum expected BPM |
| `max_bpm` | 200.0 | Maximum expected BPM |
| `limit` | 16 | Timestamps listed per kind (beats, bars, sections); the rest are summarized |

### Adjusting Detection

```python
# More sensitive — detect subtle rhythmic elements
detect_beats(file_path="/path/to/song.mp3", sensitivity=0.8)

# Less sensitive — only strong beats
detect_beats(file_path="/path/to/song.mp3", sensitivity=0.3)

# For fast electronic music
detect_beats(file_path="/path/to/edm.mp3", min_bpm=120, max_bpm=180)

# For slow ballads
detect_beats(file_path="/path/to/ballad.mp3", min_bpm=50, max_bpm=100)
```

### Building the Beat Detector

The beat detector is a standalone Swift tool (`helpers/beat-detector.swift`), built and
installed with the other Swift helpers by `make tools` / `make install`. By hand:

```bash
swiftc -O -o build/beat-detector helpers/beat-detector.swift
```

The tool is searched in these locations:
1. `build/beat-detector` in this checkout
2. `~/Applications/SpliceKit/tools/beat-detector`
3. `~/Library/Application Support/SpliceKit/tools/beat-detector`
4. `/usr/local/bin/beat-detector`

### Beat Data for Montage

Beat detection output can be fed directly into the montage system:

```python
# 1. Detect beats in a song (the answer lists beat, bar and section times)
detect_beats(file_path="/path/to/music.mp3")

# 2. Score the browser clips
clips = montage_analyze_clips(event_name="My Event")

# 3. Plan the edit: beats is a JSON array of beat times in seconds,
#    clips the clip objects from montage_analyze_clips
plan = montage_plan_edit(beats='[0.5, 1.0, 1.5, 2.0]', clips=clips, style="beat")

# 4. Assemble the montage on the timeline
montage_assemble(edit_plan=plan, song_file="/path/to/music.mp3")
```

---

## Combined Workflows

### Music Video: Cut to Beat

```python
# 1. Detect beats in the music track
beats = detect_beats(file_path="/path/to/song.mp3")

# 2. Import the music to the timeline
# (via FCPXML or manually)

# 3. Detect scene changes in the raw footage
scenes = detect_scene_changes(threshold=0.3)

# 4. Auto-assemble clips to a FlexMusic song's beats (song_uid from
#    flexmusic_list_songs; empty picks one by clip mood). For your own song
#    file, use build_song_cut (see song-cut.md) or the montage steps above.
montage_auto(song_uid="com.apple.flexmusic.song-12345")
```

### Auto-Segment Interview + Add Music Markers

```python
# 1. Blade at scene changes (camera angle switches)
blade_scene_changes(threshold=0.25)

# 2. Detect beats in background music for pacing reference
detect_beats(file_path="/path/to/background-music.mp3")

# 3. Use beat timestamps to place markers for rhythm-aware editing
```

### Rough Cut Automation

```python
# 1. Start with long uncut footage on timeline
# 2. Blade at all scene changes
blade_scene_changes()

# 3. Now each shot is a separate clip, with a handle
get_timeline_clips()

# 4. Rate them by handle (no playhead stepping)
select_clips(handles=["obj_12"])
timeline_edit_action("favorite")  # mark good takes
select_clips(handles=["obj_15"])
timeline_edit_action("reject")    # mark bad takes
```

---

## Additional Analysis Tools

### Playhead Position

Get precise playhead position for analysis-driven workflows:

```python
get_playhead_position()
# Returns: seconds, duration, frameRate, isPlaying
```

### Timeline Analysis

Analyze timeline structure and health:

```python
analyze_timeline()
# Returns: clip count, duration, pacing stats, potential issues
# (flash frames, long clips, short clips)
```

### SRT Import as Markers

Import subtitle timestamps as timeline markers:

```python
import_srt_as_markers(srt_content="""
1
00:00:05,000 --> 00:00:10,000
First subtitle

2
00:00:12,000 --> 00:00:15,000
Second subtitle
""")
```

Each subtitle becomes a marker at the corresponding timecode, useful for
marking sections referenced in scripts or transcripts.

---

*Scene detection uses GPU-accelerated histogram comparison. Beat detection
runs as an external process using AVFoundation's audio analysis. Both operate
on-device with no network dependency.*
