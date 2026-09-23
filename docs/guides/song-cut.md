# Song Cut (Beat-Synced Video Assembly)

Build a contiguous primary-storyline cut synced to a song's Apple beat map.
Uses beat detection from one sequence, video clips from another, and assembles
the result via FCPXML import — no per-clip latency, handles any segment count.

## Quick Start
```
# 1. Have three sequences in your library:
#    - A song sequence (with beat detection already run on the audio)
#    - A video clip sequence (source footage to cut from)
#    - An empty target sequence (or let it create a new project)

# 2. Open the target sequence
open_project("My Target")

# 3. Build the song cut
build_song_cut(
    pace="natural",                          # pacing preset
    source_project_name="My Song",           # sequence with beat-detected audio
    clip_source_project_name="My Footage",   # sequence with video clips
    build_mode="fcpxml",                     # "fcpxml" (recommended) or "native"
    project_name="My Song Cut",              # name for the generated project
)
```

## Pacing Presets
| Preset | Grid | Behavior |
|--------|------|----------|
| `natural` | half_beat | Mostly whole-beat cuts, sometimes two beats, rarely paired half-beats |
| `medium` | half_beat | 1-2 beat cuts |
| `fast` | half_beat | Half- to full-beat cuts, half-beats always paired |
| `aggressive` | quarter_beat | Quarter- to full-beat cuts |

**Half-beat pairing rule**: On a half_beat grid, when a half-beat step is chosen,
the next segment is forced to also be a half-beat. This ensures half-beat cuts
always come in pairs, resolving on whole-beat boundaries.

## Custom Pacing (bypass presets)
```
assemble_random_clips_to_song_beats(
    grid="half_beat",                        # beat, half_beat, quarter_beat, bar, section
    segment_min_step=1,                      # min grid intervals per cut
    segment_max_step=4,                      # max grid intervals per cut
    step_weights='{"1": 1, "2": 8, "4": 3}', # bias toward whole beats
    source_project_name="My Song",
    clip_source_project_name="My Footage",
    build_mode="fcpxml",
    project_name="Custom Cut",
)
```

## Build Modes
- **`fcpxml`** (recommended): Generates complete FCPXML and imports once. Handles
  any segment count instantly. Creates a new project in the library.
- **`native`**: Direct in-app append edits via browser selection. Works for smaller
  builds (~50 segments) but times out on large ones. Supports `target_current_timeline=True`
  to append into the active empty timeline.

## Source Requirements
- **Song**: Must have Apple beat detection run on it (`hasTimingMetadata` = true).
  Run beat detection in FCP first (select clip → Modify → Detect Beats), or use
  `detect_beats()` on the audio file.
- **Video pool**: Any sequence with video clips. Clips are reused with random in-points
  when the pool is smaller than the song. Set `allow_clip_reuse=False` to prevent reuse.
- **Song audio**: Automatically attached underneath the video on lane -1.
  Set `include_audio=False` to omit.

## Dry Run
```
build_song_cut(pace="natural", source_project_name="Song", 
               clip_source_project_name="Footage", dry_run=True)
# Returns: segment count, gap count, tempo, plan details — no changes made
```

## Related tools

- `trim_clips_to_beats()` / `sync_clips_to_song_beats()` — trim clips already on the
  timeline so they end on the song's beat map.
- `beat_sync_blade(file_path, cut_on="bar")` — blade the timeline at a song's beats, bars or
  sections.
- `montage_auto()` and the montage tools — assemble to a FlexMusic song
  ([flexmusic-and-montage.md](flexmusic-and-montage.md)).

All of them are listed in [mcp-tools.md](../reference/mcp-tools.md#scenes-beats-music-and-song-structure).
