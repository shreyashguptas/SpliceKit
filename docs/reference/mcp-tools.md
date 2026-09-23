# MCP Tools Reference

Every tool the SpliceKit MCP server registers, by area. The operating essentials (session
start, select-before-acting, undo, the core workflows) are in
[.claude/CLAUDE.md](../../.claude/CLAUDE.md); the server's own map of which tool to pick for
which task is its `instructions` (also served as the `splicekit://config/instructions`
resource). Each tool's docstring is the authoritative description of its arguments; this page
says what each one is for.

`tests/test_docs_tool_names.py` checks that every registered tool appears on this page.

## Contents

1. [Session and bridge](#session-and-bridge)
2. [Timeline actions](#timeline-actions)
3. [Reading the timeline](#reading-the-timeline)
4. [Playhead, selection and range](#playhead-selection-and-range)
5. [Editing by handle](#editing-by-handle)
6. [Projects, library and browser](#projects-library-and-browser)
7. [Effects, transitions, color and titles](#effects-transitions-color-and-titles)
8. [Audio and the mixer](#audio-and-the-mixer)
9. [Markers and SRT](#markers-and-srt)
10. [Transcript and captions](#transcript-and-captions)
11. [Scenes, beats, music and song structure](#scenes-beats-music-and-song-structure)
12. [Import, export and interchange](#import-export-and-interchange)
13. [Final Cut Pro's UI](#final-cut-pros-ui)
14. [Lua](#lua)
15. [Objects, runtime and escape hatches](#objects-runtime-and-escape-hatches)
16. [Debugging](#debugging)
17. [Plugins](#plugins)

---

## Session and bridge

- `bridge_status()` — is SpliceKit running; SpliceKit and FCP version info. Call it first.
- `bridge_alive()` — cheap liveness probe that does not touch FCP's main thread.
- `bridge_describe(method="", safety="")` — metadata for every known RPC method: safety
  classification, one-line summary, source (builtin/plugin); filter by method or safety.
- `bridge_safety_tags()` — what each safety classification used by `bridge_describe` means.
- `async_status()` — in-flight RPCs dispatched with `async=true`, with elapsed time.
- `events_subscribe(patterns=["command.*", "crash"])` — limit the bridge events this
  connection receives (exact type, `prefix.*` or `*`); without a subscription all are delivered.
- `events_unsubscribe()` — remove this connection's event allowlist.
- `events_status()` — this connection's current event subscription.
- `background_render_status()` — FCP's live background-render state.
- `background_render_control(action="hold_off" | "low_overhead", seconds=30)` — a short,
  reversible throttle on background rendering while editing.

### Deploy & Restart FCP
```
deploy_and_restart()                 # build, deploy, kill FCP, relaunch, wait for bridge
deploy_and_restart(skip_build=True)  # just restart FCP (skip make deploy)
```

### SpliceKit options

```
get_bridge_options()                                # see all configurable options
set_bridge_option("effectDragAsAdjustmentClip", True)   # drag effects to create adjustment clips
set_bridge_option("viewerPinchZoom", True)              # trackpad pinch-to-zoom on viewer
set_bridge_option("videoOnlyKeepsAudioDisabled", True)  # keep audio disabled in video-only mode
set_bridge_option("suppressAutoImport", True)           # stop auto-opening Import window on card/camera mount
set_bridge_option_value("defaultSpatialConformType", "fill")  # default new clips to Fill (crop to fill frame)
set_bridge_option_value("defaultSpatialConformType", "none")  # default new clips to None (native resolution)
set_bridge_option_value("defaultSpatialConformType", "fit")   # restore FCP default (Fit)
```

---

## Timeline actions

FCP's own commands on the current selection and playhead go through a family of dispatchers.
Each takes an action name; the names each one accepts are listed in its docstring.

- `timeline_navigation_action(action)` — move the playhead, change the selection, or change
  what the timeline shows (nextEdit, selectClipAtPlayhead, zoomToFit, toggleSnapping...).
  Changes no project content.
- `timeline_edit_action(action)` — change the timeline without removing anything: markers,
  effects, titles, ranges, paste, appendEdit / insertEdit (addMarker, addColorBoard,
  addBasicTitle, setRangeStart...).
- `timeline_destructive_action(action)` — delete, cut, blade, replace, trim or retime
  (delete, blade, trimToPlayhead, retimeSlow50, replaceWithGap, overwriteEdit...).
- `history_action("undo" | "redo")` — undo or redo the last timeline edit.
- `playback_action(action)` — transport without changing content (playPause, goToStart,
  nextFrame...).
- `timeline_action(action, dry_run=False)` — the legacy catch-all that accepts all of the
  above by name.
- `batch_timeline_actions(actions, undo_name="Batch Actions")` — a JSON list of timeline and
  playback actions run in one call and one undo step.
- `set_playback_speed(rate=1.5)` or `set_playback_speed(action="faster" | "slower" | "stop")`
  — play at an exact rate, or shuttle along the J/L speed ladders.
- `direct_timeline_action(action=..., ...)` — Flexo's parameterized action methods with real
  arguments (below).

### All timeline actions

The names `timeline_action` accepts, grouped. The split between the narrower dispatchers is
in their docstrings.

| Category | Actions |
|----------|---------|
| Blade | blade, bladeAll |
| Markers | addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker, previousMarker, deleteMarkersInSelection |
| Transitions | addTransition |
| Navigation | nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead |
| Selection | selectAll, deselectAll |
| Edit | delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap, copyTimecode |
| Edit Modes | connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit |
| Effects | pasteEffects, pasteAttributes, removeAttributes, copyAttributes, removeEffects |
| Insert | insertGap, insertPlaceholder, addAdjustmentClip |
| Trim | trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips, nudgeLeft, nudgeRight, nudgeUp, nudgeDown |
| Color | addColorBoard, addColorWheels, addColorCurves, addColorAdjustment, addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor, addMagneticMask, smartConform |
| Volume | adjustVolumeUp, adjustVolumeDown |
| Audio | expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio, matchAudio, detachAudio |
| Titles | addBasicTitle, addBasicLowerThird |
| Speed | retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero |
| Keyframes | addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe |
| Rating | favorite, reject, unrate |
| Range | setRangeStart, setRangeEnd, clearRange, setClipRange |
| Clip Ops | solo, disable, createCompoundClip, autoReframe, breakApartClipItems, synchronizeClips, openClip, renameClip, addToSoloedClips, referenceNewParentClip, changeDuration |
| Storyline | createStoryline, liftFromPrimaryStoryline, overwriteToPrimaryStoryline, collapseToConnectedStoryline |
| Audition | createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick |
| Captions | addCaption, splitCaption, resolveOverlaps |
| Multicam | createMulticamClip |
| Show/Hide | showVideoAnimation, showAudioAnimation, soloAnimation, showTrackingEditor, showCinematicEditor, showMagneticMaskEditor, enableBeatDetection, showPrecisionEditor, showAudioLanes, expandSubroles, showDuplicateRanges, showKeywordEditor |
| View | zoomToFit, zoomIn, zoomOut, verticalZoomToFit, zoomToSamples, toggleSnapping, toggleSkimming, toggleClipSkimming, toggleAudioSkimming, toggleInspector, toggleTimeline, toggleTimelineIndex, toggleInspectorHeight, beatDetectionGrid, timelineScrolling, enterFullScreen, timelineHistoryBack, timelineHistoryForward |
| Project | duplicateProject, snapshotProject, projectProperties |
| Library | closeLibrary, libraryProperties, consolidateEventMedia, mergeEvents, deleteGeneratedFiles |
| Render | renderSelection, renderAll |
| Export | exportXML, shareSelection |
| Find | find, findAndReplaceTitle |
| Reveal | revealInBrowser, revealProjectInBrowser, revealInFinder, moveToTrash |
| Keywords | showKeywordEditor, removeAllKeywords, removeAnalysisKeywords |
| Other | analyzeAndFix, backgroundTasks, recordVoiceover, editRoles, hideClip, addVideoGenerator |

### Playback actions

playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10, playAroundCurrent

`playback_action`'s docstring lists the rest (playReverse, playFromStart, playInToOut, loop,
the playRate* ladder, fastForward, rewind, stopPlaying).

### Direct Timeline Actions (`direct_timeline_action`)

Calls Flexo's parameterized `action*` methods directly on FFAnchoredTimelineModule
with real arguments. More powerful than the simple responder-chain `timeline.action`.

#### Retiming (direct control)
```
direct_timeline_action(action="retimeSetRate", rate=0.5, ripple=True)
direct_timeline_action(action="retimeSpeedRamp", to_zero=True)
direct_timeline_action(action="retimeInstantReplay", rate=0.5, add_title=True)
direct_timeline_action(action="retimeJumpCut", frames_to_jump=5)
direct_timeline_action(action="retimeRewind", speed=2.0)
direct_timeline_action(action="insertFreezeFrame")
```

#### Markers (programmatic manipulation)
```
direct_timeline_action(action="changeMarkerType", type_="chapter")
direct_timeline_action(action="changeMarkerName", name="Intro", marker="obj_5")
direct_timeline_action(action="markMarkerCompleted", completed=True)
```

#### Audio (precise control)
```
direct_timeline_action(action="changeAudioVolume", amount=-6.0, relative=True)  # amount is dB here
direct_timeline_action(action="applyAudioFadesDirect", fade_in=True, duration=0.5)
direct_timeline_action(action="setBackgroundMusic", enabled=True)
```

#### Other direct actions
```
direct_timeline_action(action="addKeywords", keywords='["Interview", "B-Roll"]')  # JSON string
direct_timeline_action(action="removeEffectByID", effect_id="HEFlowTransition")
direct_timeline_action(action="renameAngle", name="Camera 2")
direct_timeline_action(action="newProject", name="My Project")
direct_timeline_action(action="alignToMusicMarkers")
direct_timeline_action(action="duplicateCaptions", language="es", format_="SRT")
```

#### Raw selector fallback
```
direct_timeline_action(selector="actionValidateAndRepair:validateMode:error:")
```

---

## Reading the timeline

- `get_timeline_clips(limit=100, include_connected=True, include_markers=True)` — everything
  in the current timeline: spine clips, connected clips and markers, each with a handle.
- `analyze_timeline()` — duration, clip count, pacing stats, potential issues (short clips,
  gaps, flash frames).
- `verify_action(description="after blade")` — capture timeline state for before/after
  verification.
- `get_clip_effects(handle="")` — effects on a clip (the first selected one without a handle):
  names, IDs, classes, handles.

### Look inside a clip
```
get_timeline_clips()                      # find the clip's handle
get_clip_info("obj_12")                   # Info inspector fields + (SpliceKit) placement, effects, title text, markers, transcript words, a frame image
capture_clip_frame("obj_12")              # the clip as rendered in the Viewer (effects included); moves the playhead and restores it
                                          # waits (render_timeout, 5 s) until the Viewer shows the new frame; stale:true if it never did
```
`get_clip_info` never moves the playhead: its frame is decoded from the source media file (no effects), and the
tool returns it as MCP image content. Titles, generators and gap clips have no source media file and say so; a
compound clip (FCP: reference clip, its `isReferenceClip` flag, verified on 12.3; a multicam or synchronized clip
answers the same flag) has no single one, so `get_clip_info` reports no source file and no frame for it
(`capture_clip_frame` shows it as the Viewer shows it) and `get_timeline_clips` marks it [reference clip].
`kind`, handles and `timings` are SpliceKit bookkeeping, not FCP terms.

### Hear the audio of the clips
```
get_audio_levels("obj_12")                        # one clip (+ its primary-storyline neighbours, summary only, for the cuts)
get_audio_levels(start_seconds=40, end_seconds=70) # every clip with audio in a timeline range
get_audio_levels()                                 # the whole timeline (first 100 clips with audio)
get_audio_levels("obj_12", detail="full")          # the raw per-slice arrays as JSON
```
SpliceKit's own measurement of each clip's source audio, as numbers: per clip the peak and RMS
level per slice (50 ms by default, longer for clips over 30 s so no clip reports more than 600
slices) in dBFS (0 = full scale; -100 is the floor for a slice with no sample above 1e-5), placed
in timeline seconds, with the seconds below the silence threshold (RMS under -50 dBFS by default)
at the clip's start and end, the slices at full scale (peak >= -0.1 dBFS: possible clipping), the
loudest moment, and the RMS of the first and last 100 ms (or one slice, whichever is longer). The
answer carries a sparkline per clip and a waveform strip as inline MCP image content (one row per
lane, light = peak, dark = RMS, red = full scale, white = straight cuts). For neighbouring
primary-storyline clips that were both analysed it reports the outgoing clip's end against the
incoming clip's start and the jump in dB, or that a transition sits on the cut (FCP crossfades
attached audio there, which is not checked). Read-only.

Not Final Cut Pro's audio meters (the mix during playback) and not its timeline waveforms (which
follow the clip's volume and effects): the levels are those of the source media file as decoded by
SpliceKit's `audio-levels` helper (`helpers/audio-levels.swift`, built by `make install`), so FCP's
volume, fades, effects, retiming and the mix of all concurrent clips are NOT applied, the same way
`get_clip_info`'s frame is the raw footage. Channels are pooled, never mixed: a slice's peak is the
loudest sample in any channel and its RMS is over all channels' samples (for a file with one audio
track, the figures ffmpeg's volumedetect gives; a clip line saying mixdownMono fell back to the
decoder's mono mixdown, which reads 3 dB high on dual-mono files). The mapping assumes normal speed
(100%); `retimed` is FCP's own flag (`isRetimed`; a frame-rate conform was seen to set it by itself
on 12.3, and the note compares two readings of the media file's video, its average frame rate and the
rate its shortest frame duration corresponds to, with the project's rate, saying when it cannot tell
which one FCP's Rate Conform goes by) when the clip object answers
one, and "unknown" otherwise. The clip's start point in its source media is read from FCP's
`clippedRange` (else `trimStartTime` / `trimmedOffset`) against the media's start timecode
(`unclippedRange.start`), the same reading the transcript panel uses; when none answers, the levels start
at the file's start and the answer says so. Transitions,
gap clips, titles and generators have no audio of their own; a compound or multicam clip has no
single source file; both are listed as skipped. A harsh audio cut: read the outgoing clip's end and the jump
(a single handle brings its neighbours along), then `trim_clip`, a fade
(`direct_timeline_action("applyAudioFadesDirect")` on the selected clip) or `changeAudioVolume`, and
read again. `slice`, `edge window`, `jump` and the sparkline are SpliceKit bookkeeping, not FCP
terms. Raw RPC: `timeline.getAudioLevels`.

---

## Playhead, selection and range

### Playhead & Selection
```
get_playhead_position()              # current time, duration, frame rate, playing state
get_selected_clips()                 # selected clips in timeline (spine + connected, marked "connected": true)
list_markers()                       # all markers: time, kind, name, completion, handle
list_markers(kind="chapter")         # filter by kind: standard, todo, chapter, keyword, analysis
add_markers_at_times("5.0, 12.0")    # batch standard markers at timeline seconds (JSON form too)
seek_to_time(3.5)                    # jump to 3.5 seconds instantly (faster than stepping)
```
`add_markers_at_times` places every marker in one undo step (Edit > Undo reverts the whole batch).
`get_timeline_clips()` also lists connected clips (titles, B-roll, music on lanes != 0, with
the spine index they are anchored to) and markers; raw RPC: `timeline.getDetailedState` returns
`connectedItems` + `markers`, `timeline.getMarkers` returns markers only.

- `select_clips(handles=["obj_12"], mode="replace" | "add" | "remove")` — select clips by
  handle without moving the playhead; an empty list deselects everything.
- `select_clip_in_lane(lane=1)` — select the clip at the playhead in a lane (1 above the
  primary storyline, -1 below, 0 the primary storyline).

### Set in/out range programmatically
```
set_timeline_range(start_seconds=5.0, end_seconds=10.0)  # mark in at 5s, out at 10s
timeline_action("setRangeStart")   # mark in at current playhead
timeline_action("setRangeEnd")     # mark out at current playhead
timeline_action("clearRange")      # remove range selection
```

---

## Editing by handle

- `blade_at_times([3.0, 6.0, 9.0])` — blade at many timeline times in one call.
- `begin_edit(name="Rough cut")` / `end_edit()` — everything between the two is one Edit >
  Undo step; always call `end_edit`, also after an error.

### Trim a clip to an exact time
```
get_timeline_clips()                                              # find the clip's handle
trim_clip("obj_12", edge="end", to_seconds=8.0, dry_run=True)     # plan: before/projected ranges
trim_clip("obj_12", edge="end", to_seconds=8.0)                   # ripple trim the end edit point to 8.0s
```
This is FCP's default trim, a ripple edit (dragging a clip's start or end point with the Select tool):
subsequent clips move so no gap is left, and connected clips move with the clips they are attached to.
A start-point trim on the primary storyline keeps the clip in place and changes its duration.
`delta_seconds=-0.5` works too (negative = edit point earlier). Each trim is one undo step (Edit >
Undo shows the name SpliceKit passes, "Trim"; inside a `begin_edit` group, that group's step). Undo with `history_action("undo")`.

### Add a source clip, or a range of it, to the timeline
```
browser_list_clips()                                                       # name, event, handle, isProject
add_clip_to_timeline("obj_5", edit="connect", start_seconds=12, end_seconds=18, at_seconds=45, dry_run=True)
add_clip_to_timeline("obj_5", edit="connect", start_seconds=12, end_seconds=18, at_seconds=45)
add_clip_to_timeline("obj_5", edit="insert", at_seconds=0)                 # whole clip, the effect of Insert (W) at 0s
add_clip_to_timeline("obj_5", edit="append")                               # whole clip, the effect of Append (E)
```
Check `isProject` before using a row: a project sits in the browser next to the source
clips but it is a whole timeline, and these tools refuse it. Open it with
`open_project(name)` instead. An exact project name always beats a longer one that merely
contains it, so `open_project("QA Timeline")` opens that and not "QA Timeline 1".
SpliceKit writes the range to FCP's pasteboard and uses FCP's Edit > Paste (`insert`: into the primary
storyline at the playhead, later clips move right) or Edit > Paste as Connected Clip (`connect`: a
connected clip at the playhead; FCP picks the lane); `append` moves the playhead to the end of the
primary storyline, pastes there and leaves the playhead there. For insert and connect this is FCP's
three-point edit: source start + end, playhead as the timeline point. `start_seconds`/`end_seconds` are
the equivalent of a browser range selection (Set Range Start I / End O), counted from the clip's first
frame; `at_seconds` moves the playhead first; `backtimed=True` (connect only, the effect of Connect to
Primary Storyline - Backtimed, Shift-Q) puts the end of the range at the playhead. No overwrite: FCP has
no paste that overwrites (FCP's own E/W/Q/D on the browser's current selection are
`timeline_edit_action("appendEdit" | "insertEdit" | "connectToPrimaryStoryline")` and
`timeline_destructive_action("overwriteEdit")`). The answer re-reads the timeline and reports the placed
clip as `get_timeline_clips()` does, whether its duration matches the range and its position the target
(within two frames, at least 50 ms), and anything else the edit created. The pasteboard is replaced.
The edit is a single paste, so `history_action("undo")` removes it in one step.

- `browser_append_clip(handle)` — append a whole browser clip at the end of the primary
  storyline (FCP: Append, E); a shortcut for `add_clip_to_timeline(edit="append")`.

---

## Projects, library and browser

- `open_project(name, event="")` — open a project by name (an exact name beats a longer one
  that contains it).
- `get_active_libraries()` — the libraries open in FCP.
- `is_library_updating()` — whether any library is being updated or saved.
- `browser_list_clips(event="")` — what is in the browser: name, event, duration, handle,
  and whether each row is a project.

### Put a clip into a library, and take one back out
```
import_media(path="/path/to/clip.mov", event="My Event")   # add footage to an event
remove_browser_clip(name="clip", event="My Event")         # the exact inverse; file on disk untouched
remove_browser_clip(name="Old Cut", include_projects=True) # a project is a whole timeline: opt in
remove_browser_clip(name="clip", dry_run=True)             # see what would go first
cleanup_temp_projects(dry_run=True)                        # SpliceKit's own leftovers, nothing of yours
cleanup_temp_projects()                                    # move them to the library trash
```
`remove_browser_clip` refuses a name that matches more than one item and tells you which
ones matched — pass `event=` or a handle to say which. `cleanup_temp_projects` only ever
matches names SpliceKit generates itself ("SK Structure 1271", "_SKPaste_8180",
"SpliceKit Caption Import 7362"), whole-name, number required; a project of yours called
"SK Structure notes" is left alone, and an empty event is never removed.

- `import_url(url, mode="import_only" | "insert_at_playhead" | "append_to_timeline",
  target_event="", title="", highest_quality=False, wait_until_complete=True)` — download a
  media URL (direct link, YouTube, Vimeo) and import it; optionally place it on the timeline.
- `import_url_status(job_id)` — status of a URL import job.
- `cancel_import_url(job_id)` — cancel an in-flight URL import job.

### Roles, sharing and new projects

```
assign_role("audio", "Dialogue")     # assign audio role
assign_role("video", "Titles")       # assign video role
share_project("Export File (default)…")  # a named destination, as File > Share lists it
share_project()                      # whichever one FCP marks "(default)"; opens the Export sheet
create_project()                     # create new project
create_event()                       # create new event
create_library()                     # create new library
```

### Dual timeline

A floating second timeline window.

- `dual_timeline_status()` — the primary/secondary timeline panes and which one has focus.
- `dual_timeline_open(source="primary", focus=False)` — open the secondary timeline window.
- `dual_timeline_sync_root(source="primary")` — clone the source pane's root into the
  secondary timeline.
- `dual_timeline_open_selected_in_secondary(source="primary")` — open the selection in the
  secondary timeline.
- `dual_timeline_focus(pane="primary" | "secondary")` — focus a pane so later commands target it.
- `dual_timeline_close(focus_primary=True)` — hide the secondary window.
- `dual_timeline_toggle_panel(panel, pane="secondary")` — toggle a pane-local panel
  (browser, timelineIndex, audioMeters, effectsBrowser, transitionsBrowser).

---

## Effects, transitions, color and titles

These need a selection first (`select_clips([handle])`).

- `list_effects(type="filter" | "generator" | "title" | "audio" | "all", filter="")` — the
  effects installed in FCP, with effect IDs.
- `apply_effect(name="Gaussian Blur")` or `apply_effect(effectID=...)` — apply a video
  effect, generator or title to the selected clips.
- `batch_apply_effect(name=..., clip_count=0)` — one effect on each primary-storyline clip
  from the playhead on, one undo step.
- `batch_color_correct(correction="addColorBoard", clip_count=0)` — one color correction on
  each targeted primary-storyline clip.
- `insert_title(name="Basic Title")` or `insert_title(effect_id=...)` — insert a title or
  generator into the timeline.
- `get_title_text()` — text, font and size of the selected Motion title.
- `stabilize_subject()` — track a subject in the selected clip (Vision framework) and apply
  inverse position keyframes so it stays fixed on screen.

### Inspector properties
```
get_inspector_properties()                    # read all properties of selected clip
get_inspector_properties("transform")         # just transform (position, rotation, scale)
get_inspector_properties("compositing")       # opacity, blend mode
set_inspector_property("opacity", 0.5)        # set opacity to 50%
set_inspector_property("volume", -6.0)        # set audio volume
set_inspector_property("positionX", 100.0)    # move clip position
```

### Transitions
```
list_transitions()                             # list all 376+ available transitions
list_transitions(filter="dissolve")            # filter by name or category
apply_transition(name="Flow")                  # apply by display name
apply_transition(name="Cross Dissolve")        # apply specific transition
apply_transition(effectID="HEFlowTransition")  # apply by effect ID
```

Transitions are applied at the current edit point. Navigate to an edit point first:
```
timeline_action("nextEdit")           # go to next edit point
apply_transition(name="Flow")         # apply Flow transition there
```

#### Freeze Extend (not enough media handles)
When clips don't have enough extra media beyond their edges for a transition, FCP normally
shows a dialog offering to ripple trim. SpliceKit adds a third option: **"Use Freeze Frames"**.

- **UI button**: Whenever the "not enough extra media" dialog appears (including manual use),
  a "Use Freeze Frames" button is added. It extends clip edges with freeze frames and
  re-applies the transition without shortening the project.
- **API parameter**: `freeze_extend=True` (the default) automatically extends with freeze frames:
```
apply_transition(name="Cross Dissolve", freeze_extend=True)  # auto freeze-extend if needed
```

This creates freeze frames at the outgoing clip's last frame and the incoming clip's first
frame, providing the media handles needed for the transition overlap.

- `apply_transition_to_all_clips()` — the default transition (Cross Dissolve) between every
  clip on the timeline.

---

## Audio and the mixer

`get_audio_levels` (above, under [Reading the timeline](#reading-the-timeline)) measures
levels; these tools change them. `direct_timeline_action` changeAudioVolume /
applyAudioFadesDirect work on the selected clip.

- `mixer_get_state()` — every clip overlapping the playhead with its volume and
  volumeChannelHandle (SpliceKit's Audio Mixer).
- `mixer_set_volume(handle, volume_db=-6.0)` (or `volume_linear=0.5`) — set one clip's volume.
- `mixer_volume_begin(effect_stack_handle)` / `mixer_volume_end(effect_stack_handle)` —
  bracket a series of volume changes so they undo as one step.
- `mixer_set_all_volumes(volumes=[{"handle": "obj_42", "volumeDB": -6.0}])` — several faders
  at once.
- `mixer_set_solo(index=-1, role="", mode="toggle", solo=None)` — solo, unsolo or clear solo
  for a role fader.
- `mixer_set_mute(index=-1, role="", mode="toggle", muted=None)` — mute, unmute or clear mute
  for a role fader.
- `mixer_apply_bus_effect(effect_id="" | name="", role="", dry_run=False)` — apply an audio
  effect to a role's bus.
- `mixer_open_bus_effect(effect_index, role="")` — open FCP's editor window for a bus effect.
- `mixer_set_bus_effect_enabled(effect_index, enabled=True, role="")` — enable or disable a
  bus effect.
- `mixer_remove_bus_effect(effect_index, role="")` — remove a bus effect.

---

## Markers and SRT

- `add_markers_at_times("5.0, 12.0")` — standard markers at timeline seconds, one undo step.
- `list_markers(kind="")` — all markers (standard, todo, chapter, keyword, analysis).
- `timeline_edit_action("addMarker" | "addChapterMarker" | "addTodoMarker")` — a marker at
  the playhead; `direct_timeline_action` changeMarkerName / changeMarkerType edit one.

### SRT Import
```
import_srt_as_markers(srt_content="1\n00:00:05,000 --> 00:00:10,000\nSubtitle text")
```
`import_srt_as_markers` is one undo step (all subtitles from the SRT land in a single Edit > Undo).

---

## Transcript and captions

SpliceKit's Text-Based Editor (not FCP's Transcribe to Captions). Guide:
[transcript-editing.md](../guides/transcript-editing.md).

### Text-based editing via transcript
```
open_transcript()                              # transcribe all clips on timeline
open_transcript(file_url="/path/to/video.mp4") # transcribe a specific file (a path, ~/..., or a file:// URL)
open_transcript(force_retranscribe=True)       # discard cache and re-transcribe (stops a run in progress)
open_transcript(primary_storyline_only=True)   # leave connected clips (B-roll, music) out; remembered
get_transcript()                               # first 1000 words + silences; status, skipped clips, progress
get_transcript(start_seconds=60, end_seconds=120, fields="text,startTime,endTime", words_only=True)
get_transcript(offset=1000)                    # next page (the answer says where the next page starts)
delete_transcript_words(start_index=5, count=3) # delete words 5-7 (removes video segment)
move_transcript_words(start_index=10, count=2, dest_index=3) # reorder clips
search_transcript("hello")                     # search for text in transcript
search_transcript("pauses")                    # find all silences/pauses
delete_transcript_silences()                   # batch-remove all silences from timeline
delete_transcript_silences(min_duration=1.0)   # remove only silences > 1 second
set_transcript_speaker(start_index=0, count=50, speaker="Host")  # label speakers
set_silence_threshold(threshold=0.5)           # recompute silences immediately (no re-transcription)
close_transcript()                             # close the panel
```

Clips that cannot be transcribed are skipped and listed by `get_transcript` with the reason instead
of failing the run: no audio track (screen recordings), volume at or below -60 dB (a muted connected
clip), media that is missing or unreadable, or a file the transcriber cannot decode. File mode
(`file_url`) needs no project open and keeps its words until `open_transcript()` is called without a
file. A clip FCP rate-conforms (30 fps media in a 29.97 project) is mapped through the conform, so its
words land where they are heard. The raw `transcript.getState` takes `wordsOnly`, `fields`,
`startSeconds`/`endSeconds`, `offset`/`limit`, `includeSilences`, `includeText`, `includeGapBuckets`;
with none of them it returns the full state as before (a 40-minute transcript is ~1.8 M characters).

The transcript panel opens inside FCP as a floating window with an **engine selector dropdown**:
- **Parakeet v3** (default) — NVIDIA Parakeet TDT 0.6B multilingual (25 languages), on-device via FluidAudio
- **Parakeet v2** — English-optimized variant, same speed
- **Apple Speech** — SFSpeechRecognizer (slower; SpliceKit requests on-device recognition)
- **FCP Native** — Built-in AASpeechAnalyzer

All clips are transcribed in a single batch process (model loaded once, reused across clips).
Speaker diarization is available with Parakeet engines (checkbox in UI).

Panel features:
- Shows transcribed text grouped by **speaker segments** with timecode ranges (HH:MM:SS:FF)
- **Silence markers** `[...]` shown inline between words where pauses are detected
- Click a word to jump the playhead to that time
- Click a silence marker to jump to that pause
- Select words and press Delete to remove those video segments (ripple delete)
- Select silence markers and press Delete to remove pauses
- Drag words to reorder clips on the timeline
- Current word is highlighted as playback progresses
- **Search bar** with text search and filter by Pauses or Low Confidence
- **Batch operations**: Delete all search results or delete all silences
- Result count with prev/next navigation (Cmd+F to focus search)

Deleting words performs: blade at start -> blade at end -> select segment -> delete
Moving words performs: blade + cut at source -> move playhead -> paste at destination

- `set_transcript_engine(engine="parakeet" | "parakeetV2" | "fcpNative" | "appleSpeech")` —
  choose the speech recognition engine for the transcript panel.

### Captions

Guide: [captions.md](../guides/captions.md). Styled social captions are Motion titles;
native captions are FCP's own caption objects.

- `open_captions(file_url="", style="")` / `close_captions()` — open (and start
  transcribing) or close the social captions panel.
- `get_caption_state()`, `get_caption_styles()` — panel state and the style presets.
- `set_caption_style(preset_id=..., font_size=..., position=...)`,
  `set_caption_grouping(mode="social", max_words=3)` — style and word grouping.
- `set_caption_words(words)` — supply words with timing yourself (bypasses transcription).
- `generate_captions(style=..., position="center", animation="pop")` — styled word-by-word
  caption titles on the user's timeline; `verify_captions()` checks them.
- `generate_native_captions(grouping="word", language="en", format="ITT")` — FCP's native
  captions (FFAnchoredCaption) with word-level timing; `verify_native_captions()` lists them.
- `remove_captions(native=True, dry_run=False)` — delete caption items from the open
  sequence (native captions, or with `native=False` the social title captions).
- `export_captions_srt(path)`, `export_captions_txt(path)` — export the current captions.
- `cleanup_temp_projects(dry_run=False)` — remove scratch projects left by the caption and
  song-structure pipelines.

---

## Scenes, beats, music and song structure

Guides: [scene-and-beat-detection.md](../guides/scene-and-beat-detection.md),
[song-cut.md](../guides/song-cut.md),
[flexmusic-and-montage.md](../guides/flexmusic-and-montage.md).

### Scene Detection

Three tools share the same analysis: one timeline clip (or a file on disk), only the portion
of the media that clip actually uses. Reported cut times are **source media file seconds**, not
timeline seconds; `mark_scene_changes` and `blade_scene_changes` map them onto the clip.

**Target clip** (same resolution for detect / mark / blade): `handle` if given; else the sole
selected clip; else the primary-storyline clip under the playhead; else an error listing spine
candidates. There is no automatic "longest clip" fallback. A compound, multicam, or synchronized
clip is refused — pass `handle` to a specific inner clip or use `file_url` on the underlying file.

**`file_url`**: analyse a path directly (no timeline clip). Times are file seconds only;
`mark_scene_changes` and `blade_scene_changes` refuse this mode (nothing to map cuts onto).

Output includes the scanned window, e.g. `Clip used source media range: 0.000-12.012s`.

```
detect_scene_changes()                                    # read-only: list cuts + scores
detect_scene_changes(threshold=0.2)                       # more sensitive
detect_scene_changes(threshold=0.5, sample_interval=0.25) # less sensitive, faster
detect_scene_changes(handle="obj_12")                     # analyse this clip
detect_scene_changes(file_url="/path/to/footage.mov")     # file-only analysis

mark_scene_changes()                                      # markers at cuts (one undo step)
mark_scene_changes(handle="obj_12", threshold=0.2)
blade_scene_changes()                                     # blade at cuts (one undo step)
blade_scene_changes(handle="obj_12", sample_interval=0.25)
```

`detect_scene_changes(action=...)` with `markers` or `blade` is rejected; use
`mark_scene_changes()` or `blade_scene_changes()` instead.

### Beat Detection
```
detect_beats(file_path="/path/to/song.mp3")         # detect beats, bars, sections, BPM
detect_beats(file_path="song.mp3", sensitivity=0.8) # more sensitive
detect_beats(file_path="song.mp3", min_bpm=120, max_bpm=180) # for fast music
detect_beats(file_path="song.mp3", limit=32)        # show first 32 timestamps per kind; rest summarized
```
Built and installed with the other Swift helpers (`make tools` / `make install`).

- `analyze_song_structure(file_path)` — verse, chorus, bridge, intro and outro sections of a song.
- `beat_sync_blade(file_path, cut_on="bar", dry_run=False)` — detect a song's beats and blade
  the timeline at every beat, bar, section, downbeat or drop.
- `trim_clips_to_beats(grid="beat", randomize=False, dry_run=False)` — trim video clips so
  they end on the beat map of a beat-detected music clip already on the timeline.
- `sync_clips_to_song_beats(mode="beat", target_mode="auto", dry_run=False)` — the simpler
  wrapper over `trim_clips_to_beats` with editor-friendly defaults.
- `build_song_cut(pace="natural", ...)`, `assemble_random_clips_to_song_beats(grid=..., ...)`
  — a beat-synced cut from a song sequence and a footage sequence (see
  [song-cut.md](../guides/song-cut.md)).
- `song_structure_blocks(file_path, at_seconds=0.0)` — write the song's section labels as
  native captions in the timeline's caption lane.
- `remove_structure_blocks(dry_run=False)` — remove those labels, their storyline and the gap
  they appended (one undo step).
- `toggle_structure_blocks()` — despite the name, deletes the structure block storyline when
  one is there (not reversible; rebuild with `song_structure_blocks`).
- `song_structure_sections(file_path)` — show color-coded sections in a bar above the timeline.
- `sections_get()` — the sections currently in that bar; `sections_hide()` hides it.
- `flexmusic_list_songs(filter="")`, `flexmusic_get_song(song_uid)`,
  `flexmusic_get_timing(song_uid, duration_seconds)` — FlexMusic songs that fit any duration,
  and their beat, bar and section timing at a given length.
- `flexmusic_render_to_file(song_uid, duration_seconds, output_path, format="m4a")` — render
  a fitted song to an audio file.
- `flexmusic_add_to_timeline(song_uid, duration_seconds=0)` — add a FlexMusic song as
  background music.
- `montage_analyze_clips(event_name="")` — score browser clips for a montage.
- `montage_plan_edit(beats, clips, style="beat")` — an edit decision list mapping clips to
  beats (`beats` and `clips` are JSON arrays).
- `montage_assemble(edit_plan, project_name="Montage", song_file="")` — build the montage from
  that plan.
- `montage_auto(song_uid="", event_name="", style="bar")` — analyse, plan and assemble in one
  call (an empty `song_uid` picks a FlexMusic song by clip mood).

---

## Import, export and interchange

- `generate_fcpxml(project_name=..., frame_rate="24", items='[...]')` — valid FCPXML built
  with OpenTimelineIO (gaps, titles, transitions, markers).
- `paste_fcpxml(xml)` — FCPXML onto the open timeline through the pasteboard (no file, no
  dialog); see [fcpxml-paste.md](../internals/fcpxml-paste.md).
- `import_fcpxml(xml=... | path=..., internal=True, library="", wait_seconds=60)` and
  `import_fcpxml_status(job_id)` — import FCPXML from a file on this Mac or a string, as a job.

### Import an FCPXML file
```
import_fcpxml(path="~/Exports/Edit v2.fcpxml")          # read on the Mac side; no need to pass the XML inline
import_fcpxml(path="file:///Users/me/a%20b.fcpxml", library="My Library")
import_fcpxml_status(job_id="3f2a9c1e")                  # a job still running when the wait ended
```
Every import runs as a job (`fcpxml.import` with `async=true`); the tool waits up to `wait_seconds`
(60) and otherwise returns the job id. An FCPXML whose media sits on a network volume keeps FCP's
"Importing Remote Resources" sheet up for minutes: poll `import_fcpxml_status` (it answers off the
main thread and lists FCP's on-screen windows while the job runs) and never import the same file
again while it runs. The library is the one the XML's `<library location>` names when it is open,
else `library=`, else the first open library; the answer says which and why. `internal=True` (the
default) is the safe route: FCP's own open-file route (NSWorkspace `openFile:`, `internal=False`)
asks "Which library do you want to import … into?" in a modal panel that blocks the bridge, so
`internal=False` switches to the internal importer when the named library is open.

### Export FCPXML (No Dialog)
```
export_xml()                                       # export to /tmp/splicekit_export.fcpxml
export_xml(path="/tmp/my_project.fcpxml")           # export to custom path
```
Programmatic export — no save dialog. Returns the FCPXML file path.

### OpenTimelineIO Import & Export
```
export_otio()                                      # export to /tmp/splicekit_export.otio
export_otio(path="/tmp/my_project.otio")           # export as .otio (DaVinci Resolve native)
export_otio(path="/tmp/my_project.fcpxml")         # export as .fcpxml (native FCP exporter)
export_otio(path="/tmp/my_project.edl")            # export as EDL (Premiere/Resolve/Avid)
export_otio(path="/tmp/my_project.edl", rate=29.97) # EDL with explicit frame rate
export_otio(path="/tmp/my_project.aaf")            # export as AAF (Avid Media Composer)
import_otio(path="/tmp/from_resolve.otio")         # import .otio from DaVinci Resolve
import_otio(path="/tmp/project.fcpxml")            # import .fcpxml into FCP
import_otio(path="/tmp/premiere.edl", rate=29.97)  # import EDL from Premiere (set fps)
import_otio(path="/tmp/avid.aaf")                  # import AAF from Avid
import_otio(otio_json='{"OTIO_SCHEMA":...}')       # import raw OTIO JSON string
```

Universal timeline import/export via OpenTimelineIO. Handles all OTIO formats
AND FCPXML/EDL/AAF, replacing `import_fcpxml` / `export_xml` as the primary tools.
Enables timeline exchange with DaVinci Resolve, Premiere Pro, Avid Media Composer.

Supported formats:
- `.otio` — OpenTimelineIO native JSON (DaVinci Resolve, universal)
- `.fcpxml` — Final Cut Pro XML (uses FCP's native importer/exporter for full fidelity)
- `.edl` — CMX 3600 EDL (Premiere, Resolve, Avid — set `rate` for drop-frame)
- `.aaf` — Avid AAF (requires Avid-specific metadata on clips)
- `.otioz` / `.otiod` — OTIO bundles (media files must exist on disk)

`opentimelineio` and `otio-fcpx-xml-adapter` are in `mcp/requirements.txt`, so
`make mcp-setup` (and `make install`) put them in the MCP virtualenv. The EDL adapter is
the one optional extra: for `.edl`, run
`~/.venvs/splicekit-mcp/bin/python -m pip install otio-cmx3600-adapter`
(`otio-fcpxml-adapter`, the newer FCPXML adapter, works in place of the legacy one).
SpliceKit reads Final Cut Pro's FCPXML itself and only falls back to an adapter for
shapes it does not recognise. If `opentimelineio` is missing, `export_otio` /
`import_otio` say how to install it.

### Batch export clips individually
```
batch_export(folder="/path/to/output")                 # every clip on the timeline
batch_export(folder="/path/to/output", scope="selected")  # only the selected clips
```

`folder` is required. Without it the bridge would have to open a folder picker and wait
for someone to answer it, which parks FCP's main thread — a save/open panel cannot be
confirmed over the bridge at all, only cancelled. The folder is created if missing.

Each clip is exported individually with all effects/color grading baked in.
For each clip, SpliceKit:
1. Computes the clip's exact position in the timeline
2. Sets the in/out range (mark in/out) to the clip boundaries
3. Queues the export; the files appear in the folder as FCP renders them

Set your default share destination in FCP first (File > Share > Add Destination).

---

## Final Cut Pro's UI

### Universal Menu Access
```
execute_menu_command(["File", "New", "Project"])     # any menu item
execute_menu_command(["Modify", "Balance Color"])     # color correction
execute_menu_command(["View", "Playback", "Loop"])    # toggle loop
list_menus(menu="File")                               # discover menu items
list_menus(menu="Modify", depth=3)                    # see nested submenus
```

### Panels and workspaces
```
toggle_panel("videoScopes")          # show/hide video scopes
toggle_panel("inspector")            # toggle inspector
toggle_panel("effectsBrowser")       # effects browser
set_workspace("colorEffects")        # switch workspace layout
```

### Tool selection
```
select_tool("blade")     # switch to blade tool
select_tool("trim")      # switch to trim tool
select_tool("range")     # switch to range selection
select_tool("transform") # switch to transform tool
```

### Viewer Zoom
```
get_viewer_zoom()                    # current zoom level (0.0=Fit, 1.0=100%, 2.0=200%)
set_viewer_zoom(0.0)                 # fit to window
set_viewer_zoom(1.0)                 # 100%
set_viewer_zoom(2.0)                 # 200% — any float value accepted
```

### Screenshots & Visual Verification

Use `capture_viewer()` and `capture_timeline()` to take screenshots of FCP without
bringing it to the foreground. These capture the window's content directly — no `screencapture`
needed. The resulting PNGs can be read by Claude to visually verify edits. Flat detection
trims uniform Viewer chrome / letterbox bars and tests the inner content; a one-colour
content region is reported with `flat: true` and a WARNING line (it can also be a genuinely
black frame or gap). Captures render in-process from FCP's views; a locked screen does not blank them.

**When to use:**
- After applying effects, color corrections, titles, or captions → `capture_viewer()`
- After blade cuts, rearranging clips, adding markers, or any timeline edit → `capture_timeline()`
- When debugging layout issues (clip positions, gaps, transitions) → `capture_timeline()`
- When verifying text rendering (font, size, position) → `capture_viewer()`

```
capture_viewer()                     # screenshot viewer to /tmp/splicekit_viewer.png
capture_viewer(path="/tmp/check.png") # screenshot to custom path
capture_timeline()                   # screenshot timeline to /tmp/splicekit_timeline.png
capture_timeline(path="/tmp/tl.png") # screenshot to custom path
```
`capture_viewer`, `capture_timeline` and `capture_inspector` also return the image inline as MCP image
content (`return_image=False` to skip), so any MCP client can look at it without reading the PNG.
For one clip, `get_clip_info()` returns a frame of its source media file and `capture_clip_frame()` the
clip as rendered in the Viewer, both inline.

### Dialog Automation
**Note:** The "video properties of this clip are not recognized" dialog is now
auto-dismissed at the start of every bridge request. No manual handling needed.
```
detect_dialog()                      # scan for open dialogs, see buttons/fields/checkboxes
click_dialog_button(button="OK")     # click by title (case-insensitive, partial match)
click_dialog_button(index=0)         # click by index
fill_dialog_field(value="My Project") # fill text field
toggle_dialog_checkbox("Use custom settings", checked=True)
select_dialog_popup(select="4K")     # choose from dropdown
dismiss_dialog(action="default")     # click default button to close
dismiss_dialog(action="cancel")      # cancel/escape
```

Guide: [dialog-automation.md](../guides/dialog-automation.md).

### Command Palette
```
show_command_palette()                         # open the palette (or Cmd+Shift+P)
search_commands("blade")                       # find commands by name/keyword
execute_command("blade", type="timeline")      # run a command directly
ai_command("slow this clip to half speed")     # natural language via Apple Intelligence
hide_command_palette()                         # close it
```

The command palette opens as a floating window inside FCP:
- Fuzzy search across all available actions (editing, playback, color, speed, markers, etc.)
- Arrow keys to navigate, Return to execute, Escape to close
- Type natural language sentences and press Tab to ask Apple Intelligence
- Falls back to keyword matching when Apple Intelligence is unavailable
- Also accessible via toolbar button or Enhancements menu

- `ai_command_gemma(query, model=...)` — the same as `ai_command(query, engine="gemma")`: Gemma 4
  through a local `mlx_lm.server` runs a multi-turn tool-calling loop that can reach every bridge
  method (and can run destructive edits). Guide: [command-palette.md](../guides/command-palette.md).

### LiveCam

- `livecam_open()`, `livecam_close()` — open or close the LiveCam panel inside FCP.
- `livecam_status()` — the panel's state, selected devices, recording flags and destination.

---

## Lua

### Lua Scripting

SpliceKit embeds a Lua 5.4 VM directly in FCP's process. Scripts use the `sk`
module to control FCP with zero latency:

```lua
sk.blade()                          -- blade at playhead
sk.seek(5.0)                        -- jump to 5 seconds
sk.select_clip()                    -- select clip at playhead
sk.color_board()                    -- add color correction
local clips = sk.clips()           -- get timeline clips as Lua table
local pos = sk.position()          -- get playhead position
sk.rpc("effects.apply", {name = "Gaussian Blur"})  -- any RPC method
sk.eval("NSApp.delegate.className") -- ObjC runtime bridge
```

**Entry points:**
- REPL panel: Ctrl+Option+L (Enhancements > Lua REPL)
- Live coding: save .lua files to `~/Library/Application Support/SpliceKit/lua/auto/`
- JSON-RPC: `lua.execute`, `lua.executeFile`, `lua.reset`, `lua.getState`, `lua.watch`
- MCP tools: `lua_execute`, `lua_execute_file`, `lua_reset`, `lua_watch`, `lua_state`

Reference: [lua-sdk.md](lua-sdk.md); tutorial: [lua-scripting.md](../guides/lua-scripting.md).

---

## Objects, runtime and escape hatches

Last resort, raw Objective-C. Guide: [runtime-introspection.md](runtime-introspection.md).

### Object Handles
```
# Get a handle to an object
r = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", true, true)
# r = {"handle": "obj_1", "class": "__NSArrayM", ...}

# Use handle in subsequent calls
call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', false, true)

# Read properties via KVC
get_object_property("obj_2", "displayName")

# Always clean up
release_all_handles()
```

Argument types: string, int, double, float, bool, nil, sender, handle, cmtime, selector

- `call_method(class_name, selector, class_method=True)` — a zero-argument ObjC method.
- `call_method_with_args(target, selector, args='[...]', class_method=True, return_handle=False)`
  — any ObjC method with typed arguments via NSInvocation.
- `get_object_property(handle, key, return_handle=False)` — one property via KVC.
- `set_object_property(handle, key, value, value_type="string")` — set a property via KVC.
  Bypasses undo.
- `list_handles()`, `inspect_handle(handle)`, `release_handle(handle)`,
  `release_all_handles()` — the handles the bridge is holding.
- `raw_call(method, params='{}')` — a raw JSON-RPC call to the bridge.
- Runtime introspection: `get_classes(filter)`, `get_methods(class_name)`,
  `get_properties(class_name)`, `get_ivars(class_name)`, `get_protocols(class_name)`,
  `get_superchain(class_name)`, `explore_class(class_name)`,
  `search_methods(class_name, keyword)`; binary level: `list_loaded_images(filter)`,
  `get_image_sections(binary)`, `get_image_symbols(binary, filter)`,
  `get_notification_names(binary)`, `dump_runtime_metadata(binary, classes_only)`.

### Key Classes
| Class | Use |
|-------|-----|
| FFAnchoredTimelineModule | Timeline editing (1435 methods) |
| FFAnchoredSequence | Timeline data model |
| FFAnchoredMediaComponent | Clips in timeline |
| FFAnchoredTransition | Transitions |
| FFLibrary / FFLibraryDocument | Library management |
| FFEditActionMgr | Edit commands |
| FFEffectStack | Effects on clips |
| PEAppController | App controller |
| PEEditorContainerModule | Editor/timeline modules |

Full class reference: [fcp-api.md](fcp-api.md).

---

## Debugging

Developer tooling; guide: [debug-tools.md](debug-tools.md).

- In-process debugger: `debug_breakpoint`, `debug_trace_method`, `debug_watch`,
  `debug_crash_handler`, `debug_threads`, `debug_eval`, `debug_load_plugin`,
  `debug_observe_notification`.
- FCP's internal debug flags: `debug_get_config()`, `debug_set_config(key, value)`,
  `debug_enable_preset(preset)`, `debug_reset_config(scope="all")`.
- Framerate: `debug_start_framerate_monitor(interval=2.0)`, `debug_stop_framerate_monitor()`.

---

## Plugins

- `plugin_list()` — loaded SpliceKit plugins with their manifests.
- `plugin_list_methods()` — registered plugin methods with descriptions and parameter schemas.
- `reload_plugin_tools()` — register newly available plugin methods as MCP tools (the client
  has to list tools again to see them).
