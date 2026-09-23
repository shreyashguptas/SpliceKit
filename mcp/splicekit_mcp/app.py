"""The MCPServer instance (`mcp`) and the instructions every client receives."""

from .sdk import MCPServer
from .config import SPLICEKIT_VERSION


mcp = MCPServer(
    name="splicekit",
    version=SPLICEKIT_VERSION,
    instructions="""SpliceKit: direct in-process control of Final Cut Pro through a JSON-RPC bridge inside the
running app (127.0.0.1:9876). No AppleScript, no UI automation. Tools use Final Cut Pro's own
terms where FCP has one (edits, range selection, primary storyline, connected clips, playhead);
SpliceKit bookkeeping (handle, kind, timings) is labelled as such. A "handle" (obj_12) is a
reference to an object from an earlier read, unrelated to FCP's "media handles". Times are
seconds on the timeline; one frame = 1 / frame rate.

## Start of every session
1. bridge_status()              -- is the patched Final Cut Pro running and the bridge answering
2. open_project("Name")         -- load a project by name (event= to narrow)
3. get_timeline_clips()         -- spine clips + connected clips + markers, each with a handle
4. get_clip_info("obj_12")      -- what is IN a clip: source file, effects, title text, transcript words, a frame
Then edit with the exact, handle-based tools below, and check the result: those tools re-read
the timeline and report whether it matches within two frames (verified / placed / before /
after); otherwise get_timeline_clips(), verify_action(), capture_timeline(). Captures and clip
frames come back inline as image content.

## Which tool for what (pick the specific tool before a generic one)
READ the timeline: get_timeline_clips, get_clip_info(handle) (what is IN a clip: source file,
  effects, title text, markers, transcript words, a frame image), list_markers, get_selected_clips,
  get_playhead_position, get_clip_effects, get_inspector_properties, analyze_timeline.
HEAR it: get_audio_levels(handle) (its primary-storyline neighbours come along, summary only, so
  the cuts on both sides are compared), get_audio_levels(start_seconds, end_seconds), or no
  arguments for every clip with audio (first 100): SpliceKit's measurement of each clip's source
  audio, peak and RMS in dBFS per slice (a sparkline per clip plus a waveform image), the
  silence at each clip's start and end, slices at full scale, and the level jump at each straight
  cut between two analysed primary-storyline clips. Not FCP's audio meters or waveforms: FCP's
  volume, fades, effects, retiming and the mix of all concurrent clips are not applied. Read-only.
SEE it: capture_timeline, capture_viewer, capture_inspector, capture_clip_frame(handle) (the clip
  as rendered in the Viewer, effects included; moves the playhead and restores it, waits until the
  Viewer shows the new frame and says stale:true when it never did). Captures are in-process from
  FCP's views; a one-colour content region comes back with flat:true and a WARNING.
SOURCE CLIPS (browser -> timeline): browser_list_clips() then
  add_clip_to_timeline(handle, edit="insert"|"connect"|"append", start_seconds, end_seconds,
  at_seconds, backtimed, dry_run): a range of a source clip (seconds from its first frame)
  pasted at the playhead, the effect of Insert (W) / Connect (Q); at_seconds moves the playhead
  first (insert and connect are FCP's three-point edit); append pastes at the end of the primary
  storyline, the effect of Append (E), and ignores at_seconds. No overwrite there. FCP's own
  E / W / Q / D on the browser's current selection: timeline_edit_action("appendEdit" |
  "insertEdit" | "connectToPrimaryStoryline"), timeline_destructive_action("overwriteEdit" |
  "connectEditBacktimed"). import_media() brings files into an event first.
CUT: blade_at_times([...]) (many cuts, one call). One cut: seek_to_time(t) then
  timeline_destructive_action("blade").
TRIM: trim_clip(handle, edge="start"|"end", to_seconds= or delta_seconds=, dry_run) -- FCP's
  ripple trim by handle, exact; the answer re-reads the clip. trimStart/trimEnd/trimToPlayhead
  (destructive action) work on the selection at the playhead and are coarse.
TIMELINE RANGE (FCP's range selection in the timeline): set_timeline_range(start, end),
  timeline_edit_action("setRangeStart" | "setRangeEnd" | "clearRange").
SELECT: select_clips([handles]) (no playhead move), select_clip_in_lane(lane),
  timeline_navigation_action("selectClipAtPlayhead" | "selectAll" | "deselectAll").
PLAYHEAD: seek_to_time(seconds) (exact); playback_action for transport (goToStart, nextFrame...).
DELETE / REPLACE: timeline_destructive_action("delete" | "cut" | "replaceWithGap" ...) on the
  selection. Spoken content: delete_transcript_words, delete_transcript_silences.
MOVE / REORDER: no move-by-handle tool yet. Reorder spoken content with move_transcript_words;
  otherwise select, timeline_destructive_action("cut"), seek_to_time, timeline_edit_action("paste").
MARKERS: add_markers_at_times, list_markers, timeline_edit_action("addMarker" |
  "addChapterMarker" | "addTodoMarker"), direct_timeline_action changeMarkerName / changeMarkerType.
EFFECTS, TRANSITIONS, COLOR, TITLES (need a selection first): apply_effect, list_effects,
  apply_transition (at the edit point), apply_transition_to_all_clips, list_transitions,
  set_inspector_property, timeline_edit_action (addColorBoard, addColorWheels, addBasicTitle,
  addKeyframe...), batch_apply_effect, batch_color_correct, insert_title, get_title_text,
  stabilize_subject.
SPEED: timeline_destructive_action("retimeSlow50" | "retimeFast2x" | "retimeNormal" |
  "freezeFrame"...), direct_timeline_action retimeSetRate (any rate), set_playback_speed.
AUDIO: get_audio_levels first (where is it loud, silent, at full scale; which cut jumps), then
  mixer_get_state / mixer_set_volume / mixer_set_mute / mixer_set_solo (SpliceKit's Audio
  Mixer), direct_timeline_action changeAudioVolume / applyAudioFadesDirect (select the clip
  first), trim_clip to move an edit point off a hard audio cut, assign_role (FCP roles),
  timeline_edit_action("detachAudio" | "expandAudio").
SPEECH / TEXT-BASED EDITING (SpliceKit's Text-Based Editor, not FCP's Transcribe to Captions):
  open_transcript (timeline, or file_url = a path or file:// URL; primary_storyline_only;
  clips with no audio track or muted are skipped and listed), get_transcript (one page of words:
  start_seconds/end_seconds, offset/limit, fields, words_only), search_transcript, delete_transcript_words,
  move_transcript_words, delete_transcript_silences, set_transcript_speaker,
  set_silence_threshold. Captions: open_captions, set_caption_style, set_caption_grouping,
  generate_captions, verify_captions, generate_native_captions, remove_captions,
  cleanup_temp_projects.
UNDO / GROUPING: history_action("undo" | "redo"). begin_edit("Rough cut") ... end_edit() makes
  everything in between ONE undo step (Flexo's internal term: one undoable action) -- always
  call end_edit.
SCENES, BEATS, WHOLE EDITS: detect_scene_changes() lists the cuts (read-only), then
  blade_scene_changes() / mark_scene_changes(); detect_beats(file), beat_sync_blade,
  trim_clips_to_beats; import_srt_as_markers; generate_fcpxml + import_fcpxml (xml, or path= a
  .fcpxml on this Mac; runs as a job, import_fcpxml_status(job_id) while FCP imports remote media;
  never re-import a running job); build_song_cut / assemble_random_clips_to_song_beats (beat-synced cuts).
EXPORT / EXCHANGE: export_xml, export_otio / import_otio (.otio, .fcpxml, .edl, .aaf),
  share_project, batch_export, export_captions_srt / export_captions_txt.
PROJECTS / LIBRARY / BROWSER: open_project, create_project, create_event, create_library,
  get_active_libraries, browser_list_clips, import_media, dual_timeline_* (a second timeline
  window).
FCP'S UI: execute_menu_command(["Modify", "Balance Color"]), list_menus, toggle_panel,
  set_workspace, select_tool, get_viewer_zoom / set_viewer_zoom, detect_dialog (answers from the
  window server when FCP's main thread is busy: mainThreadBusy, titles only; overlays such as the
  Viewer's on-screen controls are listed apart, not as dialogs) then
  click_dialog_button / fill_dialog_field / select_dialog_popup / toggle_dialog_checkbox /
  dismiss_dialog (cancels by default; save/open panels cannot be confirmed from the bridge),
  search_commands / execute_command (the Command
  Palette's commands).
ESCAPE HATCHES (last resort, raw ObjC): call_method_with_args, call_method, get_object_property,
  raw_call, debug_eval; explore_class / search_methods find a selector; release_all_handles releases
  handles. lua_execute runs Lua inside FCP.
Not routed here on purpose (developer tooling; their docstrings say what they do): debug_*,
  livecam_*, events_*, plugin_*, bridge_* internals, runtime introspection beyond
  explore_class / search_methods, lua extras, deploy_and_restart.

## The action dispatchers (FCP's own commands on the current selection / playhead)
timeline_navigation_action  nextEdit, previousEdit, selectClipAtPlayhead, zoomToFit, toggleSnapping...
                            (changes no project content: navigation, selection, view and settings)
timeline_edit_action        addMarker, addTransition, paste, pasteAsConnected, addColorBoard,
                            addBasicTitle, setRangeStart, appendEdit, insertEdit... (FCP commands
                            that delete no clip content; paste ripples later clips)
timeline_destructive_action delete, cut, blade, trimToPlayhead, retime*, replaceWithGap,
                            overwriteEdit...
history_action              undo, redo
playback_action             playPause, goToStart, goToEnd, nextFrame, prevFrame...
timeline_action             the legacy dispatcher that accepts all of the above by name
batch_timeline_actions      a JSON list of the above, run in one call
direct_timeline_action      FCP's parameterized action methods with real arguments
A success answer names the selector that ran ({"action": ..., "status": "ok"}); a failure is an
error string. "No responder handled X" means the action is not available in this state (nothing
selected, no edit point, wrong tool).

## Targeting by handle (no playhead moves)
get_timeline_clips() gives every clip a handle; browser_list_clips() does the same for source clips.
  select_clips(["obj_12"])                                   select without moving the playhead
  trim_clip("obj_12", edge="end", to_seconds=8.0, dry_run=True)   plan, then drop dry_run to apply
  add_clip_to_timeline("obj_5", edit="connect", start_seconds=12, end_seconds=18, at_seconds=45)
  get_clip_info("obj_12")                                    what is in the clip
  begin_edit("Rough cut") ... end_edit()                     many calls, one undo step
Re-run get_timeline_clips() if a handle comes back unresolved.

## Rules that save round trips
- Prefer the exact, handle-based tools (add_clip_to_timeline, trim_clip, blade_at_times,
  select_clips, seek_to_time) over stepping the playhead frame by frame.
- Color, retime, titles and effects need a selection: select_clips([handle]) first.
- Check what a change will do with dry_run=True (add_clip_to_timeline, trim_clip) before doing it.
- After an edit, read the state back (get_timeline_clips) or look (capture_timeline); after a
  mistake, history_action("undo"). add_clip_to_timeline replaces the pasteboard.
- "No active timeline module" / "No sequence in timeline" = no project open: open_project().
  "Cannot connect" = the patched Final Cut Pro is not running.
- Titles, generators and gap clips have no source media file; get_clip_info says so. A compound
  clip (FCP: reference clip, its isReferenceClip flag; a multicam or synchronized clip answers by
  the same flag; get_timeline_clips marks it [reference clip]) has no single one: get_clip_info
  reports no source file and no frame for it, get_audio_levels skips it; capture_clip_frame shows
  it as the Viewer shows it.
- A harsh audio cut: get_audio_levels(handle) reports the clip's last edge window (100 ms by
  default) and the jump into the next primary-storyline clip, because that neighbour is analysed
  too (or pass handles=[outgoing, incoming] / a range spanning the cut); fix with trim_clip (move
  the edit point), applyAudioFadesDirect (a fade on the selected clip) or changeAudioVolume,
  then get_audio_levels again.

## Hazards (learned the hard way)
- call_method_with_args passes raw pointers through NSInvocation: nil is only safe for an
  out-pointer (error:, askedRetry:) the selector tolerates. FFAnchoredSequence
  actionTrimDuration:forEdits:isDelta:error: can crash Final Cut when the trim is rejected and
  error: is nil -- do not probe it through call_method_with_args; use trim_clip.
- A transition request at a cut often targets the right-hand clip with before=YES: that means
  "on the cut before this clip", not a one-sided effect on its leading edge.
- For model-level selection, build an NSArray handle explicitly:
  arr = call_method_with_args("NSArray", "arrayWithObject:", '[{"type":"handle","value":"obj_7"}]',
  class_method=True, return_handle=True); then setSelectedItems: with that handle.
"""
)
