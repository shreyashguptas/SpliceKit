#!/usr/bin/env python3
"""Drive every MCP tool against a running, patched Final Cut Pro and report what works.

This is the check the other suites do not make. `tests/mcp_server_check.py` calls every
tool against a fake bridge, which proves a tool does not crash on a canned answer.
`tests/live/live_bridge_endpoints.py` calls the bridge directly and skips anything that
would change the timeline. Neither one proves that a tool which edits a project
actually edits it, so tools could sit broken for a long time while every suite stayed
green — that is exactly how a marker-placement bug and two crashers survived.

This sweep calls each tool the way a person would, checks the timeline afterwards, and
puts it back.

    WARNING: this sweep edits the open project. Run it only against the throwaway
    library. It refuses to start against anything else (see EXPECTED_PROJECT).

Usage
    python3 tests/live/live_tool_sweep.py [options]

    --only PREFIX     run only tools whose name starts with PREFIX (repeatable)
    --group NAME      run only one group (read / write / dependency / modal)
    --list            print the plan and exit without calling anything
    --json PATH       write a machine-readable report
    --allow-project N run against project N instead of the QA project (be careful)
    --library NAME    the library that must be the only one open (default "testing")

Every timeline time the cases use is derived from the open project (its clips and edit
points), so the sweep works on a project whose timeline starts at a timecode other
than zero. Before each case the playhead is put inside the connected clip and that clip
is selected; cases that need more (an edit point, a transcript, a bus effect) say so in
`setup`. The run starts and ends with a snapshot of the library, the browser, the
timeline, every clip's effects and roles and the mixer; the two must match, and a last
persisted edit (a marker added and deleted) makes the saved library match what was
checked.

Exit code is 0 only when nothing FAILED. A tool that reports a missing external
dependency clearly is BLOCKED, not failed — see `dependency` below.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

try:
    from mcp import Client, StdioServerParameters
except ImportError:  # pragma: no cover - the venv is the documented way to run this
    print("This needs the mcp 2.x SDK: ~/.venvs/splicekit-mcp/bin/python", file=sys.stderr)
    raise

# The sweep edits clips, so it must never be pointed at real work.
EXPECTED_PROJECT = "QA Timeline"
EXPECTED_LIBRARY = "testing"

PASS, FAIL, BLOCKED, SKIPPED = "PASS", "FAIL", "BLOCKED", "SKIPPED"


def browser_rows(text: str) -> list[dict]:
    """The rows of a browser_list_clips answer."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    rows = data.get("clips", []) if isinstance(data, dict) else []
    return [r for r in rows if isinstance(r, dict)]


# Arguments that take a number of seconds: a timeline-time placeholder given alone there
# is passed as a number. Everywhere else it stays text ("43.043, 44.043").
NUMERIC_ARGS = {"seconds", "at_seconds", "start_seconds", "end_seconds", "time",
                "frame_time"}


class SetupError(Exception):
    """A case's fixture could not be put in place; the case fails without running."""


# --------------------------------------------------------------------------- specs

@dataclass
class Case:
    """One tool, called one way, with what should happen afterwards.

    kind:
        read        must answer without an error; must not change the timeline
        write       changes the project; `undo` names the step that takes it back,
                    or `cleanup` runs tools that restore the previous state
        dependency  needs something not installed here (a headset, a song library,
                    a model server). A clear message naming what is missing passes
                    as BLOCKED; a crash, a hang or a misleading message FAILS.
        modal       opens a panel or sheet a person would have to answer. Run only
                    with --group modal, and always paired with a `cleanup` that
                    closes it again.
        skip        not callable from a sweep; `reason` says why
    """
    args: dict[str, Any] = field(default_factory=dict)
    kind: str = "read"
    # A regex the answer must match to count as working. None means "anything that
    # is not an error".
    expect: str | None = None
    # Substrings that mark an acceptable missing-dependency answer (kind=dependency).
    dependency_markers: tuple[str, ...] = ()
    undo: str | tuple[str, ...] | None = None
    cleanup: list[tuple[str, dict]] = field(default_factory=list)
    reason: str = ""
    # Some tools are slow (tracking, transcription, model calls).
    timeout: float = 60.0
    # True for a tool that invalidates object handles (reopening a project drops the
    # whole registry), so the placeholders are looked up again before the next case
    # instead of every later call failing on a handle that no longer resolves.
    invalidates_handles: bool = False
    # A handle to select before the call, for tools that act on the selection and need
    # a particular kind of clip (the second timeline pane only takes a compound clip).
    select_before: str = ""
    # Steps run before the case, after the playhead / selection prelude and before the
    # timeline snapshot the case is judged against: (tool, args) pairs, or the name of a
    # built-in fixture: "deselect", "edit_point", "speech_fixture", "transcript",
    # "captions", "bus_effect". Fixtures that add to the timeline are taken away again
    # after the case (see Sweep.teardown_fixtures), and the timeline must then match
    # what it was before the setup ran.
    setup: list = field(default_factory=list)
    # The edit must land: the undo stack has to name one of `undo` afterwards. Without
    # this, a tool that quietly did nothing passed, because nothing needed undoing.
    require_undo: bool = False
    # Needs the Parakeet v3 model on disk (the transcript and caption panels); BLOCKED,
    # never a download, when it is not there.
    needs_parakeet: bool = False
    # Undo steps Final Cut Pro records under the case's own step and that belong to the
    # same call (generate_native_captions: the scratch project's "Import XML" sits under
    # its "Paste"). Undone after the case's step when they are next on the stack.
    extra_undo: tuple = ()


# The names SpliceKit's own pipelines generate, matched whole, the same shapes
# SpliceKit_isScratchImportProjectName and SpliceKit_isScratchImportEventName use.
SCRATCH_NAME = re.compile(
    r"^(?:SpliceKit Caption Import \d+|SK Structure \d+|_SKPaste_\d+"
    r"|SpliceKit Captions|SpliceKit Structure)(?: \d+)*$")


def read(expect: str | None = None, timeout: float = 60.0, **args) -> Case:
    return Case(args=args, kind="read", expect=expect, timeout=timeout)


def write(undo=None, cleanup=None, expect=None, timeout=60.0, setup=None,
          require_undo=False, **args) -> Case:
    return Case(args=args, kind="write", undo=undo, cleanup=cleanup or [],
                expect=expect, timeout=timeout, setup=setup or [],
                require_undo=require_undo)


def dependency(*markers, timeout=60.0, **args) -> Case:
    return Case(args=args, kind="dependency", dependency_markers=markers, timeout=timeout)


def modal(cleanup=None, **args) -> Case:
    return Case(args=args, kind="modal", cleanup=cleanup or [])


def skip(reason: str, **args) -> Case:
    return Case(args=args, kind="skip", reason=reason)


# Placeholders resolved against the live timeline just before a call, so the sweep
# never hard-codes a handle (they are per-session) or a media path (per-machine).
#   $SPINE_CLIP       first clip on the primary storyline
#   $CONNECTED_CLIP   the connected clip above it
#   $EFFECT_STACK     effect-stack handle of the selected clip
#   $MEDIA_FILE       absolute path of a source media file used on the timeline
#   $TMP              a scratch directory that the sweep removes afterwards
#   $PROBE_MEDIA      a small media file made for the run, safe to import and remove
#   $PROBE_NAME       the name that file lands under in the browser
#   $PROBE_URL        that same file over a local HTTP server, for import_url
#   $EVENT_NAME       the event the QA project lives in
#   $SCRATCH_FCPXML   this project exported as FCPXML, renamed so re-importing it
#   $SCRATCH_PROJECT  lands under a name of its own ($PASTE_* is a second copy, so
#   $PASTE_FCPXML     import_fcpxml and paste_fcpxml never collide on one name)
#   $PASTE_PROJECT
#   $OTIO_IMPORT      the same, exported as OTIO, for import_otio
#   $OTIO_PROJECT
#   $URL_PROBE_NAME   the name import_url's download lands under
# Every one of those names carries this run's process id, because Final Cut Pro keeps
# a name reserved after the thing holding it is trashed.


CASES: dict[str, Case] = {
    # ---------------------------------------------------------------- bridge, events
    "bridge_status": read(expect=r'"fcp_version"'),
    "bridge_alive": read(expect=r'"alive": true'),
    "bridge_describe": read(method="timeline.getState"),
    "bridge_safety_tags": read(),
    "events_subscribe": write(patterns=["timeline.*"],
                              cleanup=[("events_unsubscribe", {})]),
    "events_unsubscribe": write(),
    "events_status": read(),
    "async_status": read(),

    # ---------------------------------------------------------------- timeline reads
    "get_timeline_clips": read(expect=r"Sequence:"),
    "list_markers": read(),
    "get_selected_clips": read(),
    "get_playhead_position": read(expect=r"\d"),
    "analyze_timeline": read(),
    "get_clip_effects": Case(args={"handle": "$CONNECTED_CLIP"}, kind="read"),
    "get_clip_info": Case(args={"handle": "$CONNECTED_CLIP", "include_frame": False},
                          kind="read", expect=r"source media file"),
    "capture_clip_frame": Case(args={"handle": "$CONNECTED_CLIP"}, kind="read"),
    "get_inspector_properties": read(),
    "get_title_text": read(),
    "get_audio_levels": Case(args={"handle": "$CONNECTED_CLIP", "include_image": False},
                             kind="read", timeout=120),
    "verify_action": read(description="live sweep"),
    "get_viewer_zoom": read(),
    "get_bridge_options": read(),
    "get_active_libraries": read(expect=EXPECTED_LIBRARY),
    "is_library_updating": read(),
    "browser_list_clips": read(),
    "list_effects": read(type="filter"),
    "list_transitions": read(),
    "list_menus": read(menu="Edit"),
    "search_commands": read(query="blade", limit=5),
    "list_handles": read(),
    "inspect_handle": Case(args={"handle": "$CONNECTED_CLIP"}, kind="read"),
    "get_object_property": Case(args={"handle": "$CONNECTED_CLIP", "key": "displayName"},
                                kind="read"),
    "detect_dialog": read(),
    "background_render_status": read(),
    "get_caption_state": read(),
    "get_caption_styles": read(),
    "verify_captions": read(),
    "verify_native_captions": read(),
    "sections_get": read(),
    "mixer_get_state": read(),
    "dual_timeline_status": read(),
    "plugin_list": read(),
    "plugin_list_methods": read(),
    "lua_state": read(),
    "lua_watch": read(action="list"),

    # ---------------------------------------------------------------- introspection
    "get_classes": read(filter="FFAnchoredSequence"),
    "get_methods": read(class_name="FFAnchoredSequence"),
    "get_properties": read(class_name="FFAnchoredSequence"),
    "get_ivars": read(class_name="FFAnchoredSequence"),
    "get_protocols": read(class_name="FFAnchoredSequence"),
    "get_superchain": read(class_name="FFAnchoredSequence"),
    "explore_class": read(class_name="FFAnchoredSequence"),
    "search_methods": read(class_name="FFAnchoredSequence", keyword="marker"),
    "call_method": read(class_name="FFAnchoredSequence", selector="class"),
    "call_method_with_args": Case(
        args={"target": "$CONNECTED_CLIP", "selector": "displayName",
              "args": "[]", "class_method": False}, kind="read"),
    "raw_call": read(method="timeline.getState", params="{}"),
    "debug_eval": read(expression="NSApp.className"),
    "debug_threads": read(),
    "debug_get_config": read(),
    "dump_runtime_metadata": read(classes_only=True, timeout=120),
    "list_loaded_images": read(filter="SpliceKit"),
    "get_image_sections": read(binary="SpliceKit"),
    "get_image_symbols": read(binary="SpliceKit", filter="SpliceKit_handleDialogDetect"),
    "get_notification_names": read(binary="SpliceKit"),
    "debug_breakpoint": read(action="list"),
    "debug_trace_method": read(action="list"),
    "debug_watch": read(action="list"),
    "debug_observe_notification": read(action="list"),
    "debug_load_plugin": read(action="list"),
    "debug_crash_handler": read(action="status"),

    # ---------------------------------------------------------------- scene detection
    "detect_scene_changes": Case(args={"handle": "$CONNECTED_CLIP", "action": "detect"},
                                 kind="read", timeout=180),
    "mark_scene_changes": Case(args={"handle": "$CONNECTED_CLIP"}, kind="write",
                               undo="Mark Scene Changes", timeout=180),
    "blade_scene_changes": Case(args={"handle": "$CONNECTED_CLIP"}, kind="write",
                                undo="Blade Scene Changes", timeout=180),
}

CASES.update({
    # ---------------------------------------------------------------- playhead, view
    "seek_to_time": write(seconds="$T_B", cleanup=[("seek_to_time", {"seconds": "$T_HOME"})]),
    "playback_action": write(action="stopPlaying"),
    "set_playback_speed": write(rate=1.0),
    "set_viewer_zoom": write(zoom=1.0, cleanup=[("set_viewer_zoom", {"zoom": 0})]),
    "select_clips": Case(args={"handles": "$CONNECTED_CLIP"}, kind="write"),
    "select_clip_in_lane": write(lane=1),
    "select_tool": write(tool="select"),
    "timeline_navigation_action": write(action="selectAll",
                                        cleanup=[("timeline_navigation_action",
                                                  {"action": "deselectAll"})]),
    "set_bridge_option": Case(args={"option": "$BRIDGE_OPTION", "enabled": False},
                              kind="write"),
    "set_bridge_option_value": Case(args={"option": "$BRIDGE_VALUE_OPTION",
                                          "value": "$BRIDGE_VALUE_CURRENT"},
                                    kind="write"),
    "set_silence_threshold": write(threshold=0.3),
    "set_transcript_engine": write(engine="parakeetV3"),

    # ---------------------------------------------------------------- timeline writes
    "add_markers_at_times": write(markers="$T_A, $T_B", undo="Add Markers",
                                  require_undo=True),
    "blade_at_times": write(times="$T_A", undo=("Blade at Times", "Blade", "Blade Clips"),
                            require_undo=True),
    "timeline_edit_action": write(action="addMarker", undo=("Add Marker", "Marker"),
                                  require_undo=True),
    "timeline_action": write(action="addMarker", undo=("Add Marker", "Marker"),
                             require_undo=True),
    "timeline_destructive_action": write(action="blade", undo=("Blade", "Blade Clips"),
                                         require_undo=True),
    # Many direct actions are build-dependent; this one is the marker path the
    # handler is built around and is the one worth proving works.
    "direct_timeline_action": Case(args={"action": "changeMarkerName", "name": "sweep"},
                                   kind="read",
                                   expect=r"[Nn]o marker|marker"),
    "batch_timeline_actions": write(actions='[{"action":"addMarker"}]',
                                    undo_name="Sweep Batch", undo="Sweep Batch",
                                    require_undo=True),
    "history_action": Case(args={"action": "undo"}, kind="skip",
                           reason="driven by the sweep itself to undo other steps"),
    "begin_edit": write(name="Sweep Group", cleanup=[("end_edit", {"name": "Sweep Group"})]),
    "end_edit": skip("closes the group begin_edit opens; exercised as its cleanup"),
    "trim_clip": Case(args={"handle": "$CONNECTED_CLIP", "edge": "end",
                            "delta_seconds": -0.5},
                      kind="write", undo=("Trim", "Trim Clip", "Trim End"),
                      require_undo=True),
    # The prelude selects the connected clip, so the effect lands on it.
    "apply_effect": write(name="Black & White", require_undo=True,
                          undo=("Add Effect", "Black & White", "Add Video Effect")),
    # At the edit point between two primary-storyline clips, nothing selected (with a
    # clip selected FCP puts the transition on that clip's edges instead).
    "apply_transition": write(name="Cross Dissolve", setup=["edit_point"],
                              require_undo=True,
                              undo=("Add Transition", "Cross Dissolve")),
    "apply_transition_to_all_clips": write(
        undo=("Add Transition", "Cross Dissolve", "Add Transitions"), timeout=120,
        require_undo=True),
    "batch_apply_effect": write(name="Black & White", clip_count=2, require_undo=True,
                                undo=("Batch Apply Effect", "Add Effect")),
    "batch_color_correct": write(correction="addColorBoard", clip_count=2,
                                 require_undo=True,
                                 undo=("Batch Color Correct", "Add Color Board Effect")),
    "insert_title": write(name="Basic Title", require_undo=True,
                          undo=("Connect to Primary Storyline", "Insert Title",
                                "Connect Title", "Add Basic Title")),
    "set_inspector_property": write(property="positionX", value=25, require_undo=True,
                                    undo="Set positionX"),
    # A no-op write of the value already there: proves the KVC path works without
    # changing anything.
    "set_object_property": Case(args={"handle": "$CONNECTED_CLIP", "key": "displayName",
                                      "value": "$CLIP_NAME"}, kind="write"),
    # The connected clip's video role is Video; Titles is a different role FCP offers
    # for it, so the change is real and the answer's `verified` reads it back.
    "assign_role": Case(args={"type": "video", "role": "Titles"}, kind="write",
                        select_before="$CONNECTED_CLIP", undo="Set Role",
                        require_undo=True, expect=r'"verified": true'),
    # The prelude selects the connected clip and puts the playhead over it.
    "stabilize_subject": Case(args={}, kind="write", undo="Stabilize Subject", timeout=600,
                              require_undo=True, expect=r'"status": "ok"'),
    "import_srt_as_markers": write(
        srt_content="1\n$SRT_A --> $SRT_B\nsweep\n", require_undo=True,
        undo=("Add Marker", "Add Markers", "Marker", "Import SRT as Markers")),
    # $SOURCE_CLIP is a source clip the sweep imports for the run ($SPEECH_MEDIA) and
    # removes at the end: the test event holds only projects, which these tools rightly
    # refuse.
    "add_clip_to_timeline": Case(args={"handle": "$SOURCE_CLIP", "edit": "connect",
                                       "start_seconds": 0.5, "end_seconds": 1.5,
                                       "at_seconds": "$T_HOME"},
                                 kind="write", undo=("Paste", "Paste as Connected Clip"),
                                 require_undo=True, expect=r"verified"),
    "browser_append_clip": Case(args={"handle": "$SOURCE_CLIP"}, kind="write",
                                undo=("Append", "Paste", "Append to Storyline",
                                      "Connect to Primary Storyline"),
                                require_undo=True, expect=r"verified"),

    # ---------------------------------------------------------------- panels / UI
    "toggle_panel": write(panel="inspector",
                          cleanup=[("toggle_panel", {"panel": "inspector"})]),
    "set_workspace": write(workspace="default"),
    "show_command_palette": write(cleanup=[("hide_command_palette", {})]),
    "hide_command_palette": write(),
    "dual_timeline_open": write(cleanup=[("dual_timeline_close", {})]),
    "dual_timeline_close": write(),
    "dual_timeline_focus": write(pane="primary"),
    "dual_timeline_sync_root": write(),
    # Only a compound clip, multicam angle or similar can open in the second pane.
    "dual_timeline_open_selected_in_secondary": Case(
        args={}, kind="write", select_before="$SPINE_CLIP",
        cleanup=[("dual_timeline_close", {}),
                 ("select_clips", {"handles": "$CONNECTED_CLIP"})]),
    "dual_timeline_toggle_panel": write(panel="timelineIndex", pane="secondary",
                                        cleanup=[("dual_timeline_toggle_panel",
                                                  {"panel": "timelineIndex",
                                                   "pane": "secondary"})]),
    # Toggles the visibility of structure blocks that are already on the timeline;
    # with none placed, saying so is the correct answer.
    # The happy path is song_structure_blocks' cleanup step above. What is left to check
    # here is that it says so clearly when there is nothing to remove, rather than
    # reporting success or deleting something else.
    "toggle_structure_blocks": Case(args={}, kind="read",
                                    expect=r"No structure blocks on the timeline to remove"),
    "sections_hide": write(),
    "livecam_open": write(cleanup=[("livecam_close", {})]),
    "livecam_close": write(),
    "livecam_status": read(),
    "capture_viewer": Case(args={"path": "$TMP/viewer.png", "return_image": False},
                           kind="read"),
    "capture_timeline": Case(args={"path": "$TMP/timeline.png", "return_image": False},
                             kind="read"),
    "capture_inspector": Case(args={"path": "$TMP/inspector.png", "return_image": False},
                              kind="read"),

    # ---------------------------------------------------------------- render / export
    "background_render_control": write(action="low_overhead", seconds=5),
    "export_xml": Case(args={"path": "$TMP/sweep.fcpxml"}, kind="write",
                       expect=r"fcpxml|Exported", timeout=120),
    "export_otio": Case(args={"path": "$TMP/sweep.otio"}, kind="write", timeout=120),
    # import_otio builds a new project in a new event named after the timeline; the
    # open project is left alone. The new project is removed afterwards so the library
    # does not grow a copy on every run.
    "import_otio": Case(args={"path": "$OTIO_IMPORT"}, kind="write", timeout=180,
                        cleanup=[("remove_browser_clip",
                                  {"name": "$OTIO_PROJECT", "include_projects": True})],
                        invalidates_handles=True),
    "generate_fcpxml": read(items="[]"),
    "export_captions_srt": Case(args={"path": "$TMP/sweep.srt"}, kind="write",
                                setup=["speech_fixture", "captions"], needs_parakeet=True,
                                timeout=120),
    "export_captions_txt": Case(args={"path": "$TMP/sweep.txt"}, kind="write",
                                setup=["speech_fixture", "captions"], needs_parakeet=True,
                                timeout=120),
})

CASES.update({
    # ---------------------------------------------------------------- transcript
    "open_transcript": Case(args={}, kind="write", timeout=300,
                            cleanup=[("close_transcript", {})]),
    "close_transcript": write(),
    # The words come from $SPEECH_MEDIA (spoken text made with `say`), appended to the
    # primary storyline for the case and taken off again afterwards: the project's own
    # clips carry no speech a transcript can place.
    "get_transcript": Case(args={}, kind="read", expect=r"fox",
                           setup=["speech_fixture", "transcript"], needs_parakeet=True,
                           timeout=120),
    "search_transcript": Case(args={"query": "fox"}, kind="read", expect=r"fox",
                              setup=["speech_fixture", "transcript"], needs_parakeet=True,
                              timeout=120),
    "delete_transcript_words": Case(args={"start_index": 0, "count": 1}, kind="write",
                                    undo=("Delete", "Delete Words", "Ripple Delete"),
                                    require_undo=True,
                                    setup=["speech_fixture", "transcript"],
                                    needs_parakeet=True, timeout=120),
    "move_transcript_words": Case(args={"start_index": 0, "count": 1, "dest_index": 3},
                                  kind="write", require_undo=True,
                                  undo=("Move", "Move Words", "Ripple Delete", "Paste"),
                                  setup=["speech_fixture", "transcript"],
                                  needs_parakeet=True, timeout=120),
    "set_transcript_speaker": Case(args={"start_index": 0, "count": 1, "speaker": "Sweep"},
                                   kind="write", setup=["speech_fixture", "transcript"],
                                   needs_parakeet=True, timeout=120),
    "delete_transcript_silences": write(min_duration=30.0,
                                        undo=("Delete", "Ripple Delete", "Delete Silences")),

    # ---------------------------------------------------------------- captions
    "open_captions": write(cleanup=[("close_captions", {})]),
    "close_captions": write(),
    "set_caption_style": write(preset_id="bold_pop"),
    "set_caption_grouping": write(mode="social", max_words=3),
    "set_caption_words": write(words='[{"index": 0, "text": "sweep"}]'),
    "generate_captions": Case(args={}, kind="write", timeout=300,
                              undo=("Paste", "Insert Captions", "Connect to Primary Storyline"),
                              require_undo=True, setup=["speech_fixture", "captions"],
                              needs_parakeet=True,
                              cleanup=[("cleanup_temp_projects", {})]),
    "generate_native_captions": Case(args={}, kind="write", timeout=300,
                                     undo=("Paste", "Insert Captions"),
                                     extra_undo=("Import XML",),
                                     require_undo=True,
                                     setup=["speech_fixture", "transcript"],
                                     needs_parakeet=True,
                                     cleanup=[("cleanup_temp_projects", {})]),
    "cleanup_temp_projects": read(dry_run=True),
    # The counterpart to generate_native_captions, on captions it has just made.
    "remove_captions": Case(args={"native": True}, kind="write",
                            undo="Remove Captions", require_undo=True,
                            setup=["speech_fixture", "transcript",
                                   ("generate_native_captions", {},
                                    ("Paste", "Import XML"))],
                            needs_parakeet=True, timeout=300),

    # ---------------------------------------------------------------- beats / music
    "detect_beats": Case(args={"file_path": "$AUDIO_FILE", "limit": 8},
                         kind="read", timeout=180),
    "analyze_song_structure": Case(args={"file_path": "$AUDIO_FILE"},
                                   kind="read", timeout=180),
    "song_structure_sections": Case(args={"file_path": "$AUDIO_FILE"},
                                    kind="read", timeout=180),
    "beat_sync_blade": Case(args={"file_path": "$AUDIO_FILE", "dry_run": True},
                            kind="read", timeout=180),
    # toggle_structure_blocks does the removal here, which is the only way its real
    # path gets run: on its own it can only ever meet a timeline with no blocks on it.
    "song_structure_blocks": Case(args={"file_path": "$AUDIO_FILE"}, kind="write",
                                  timeout=180,
                                  cleanup=[("toggle_structure_blocks", {}),
                                           ("remove_structure_blocks", {}),
                                           ("cleanup_temp_projects", {})]),
    "remove_structure_blocks": read(dry_run=True),
    # The beat-driven family reads Final Cut Pro's own timing metadata, which only
    # songs from its music library carry. That library is not installed here, so the
    # pass condition is that each tool says so plainly rather than failing obscurely.
    "trim_clips_to_beats": dependency("beat map", "music library", timeout=120,
                                      dry_run=True, source_handle="$CONNECTED_CLIP"),
    "sync_clips_to_song_beats": dependency("beat map", "music library", timeout=120,
                                           dry_run=True,
                                           source_handle="$CONNECTED_CLIP"),
    "build_song_cut": Case(args={"dry_run": True,
                                 "source_handle": "$CONNECTED_CLIP"},
                           kind="read", timeout=180),
    "assemble_random_clips_to_song_beats": dependency(
        "beat map", "music library", timeout=180,
        dry_run=True, source_handle="$CONNECTED_CLIP"),

    # ---------------------------------------------------------------- montage
    "montage_analyze_clips": Case(args={}, kind="read", timeout=300),
    "montage_plan_edit": read(beats="[0.0, 1.0, 2.0, 3.0]", style="beat",
                              clips="$MONTAGE_CLIPS"),
    "montage_assemble": Case(args={"edit_plan": "[]"}, kind="read",
                             expect=r"[Ee]mpty|required|[Nn]o (segments|clips)|[Ff]ail"),
    "montage_auto": dependency("no FlexMusic songs are installed", timeout=300,
                               song_uid="none"),

    # ---------------------------------------------------------------- mixer
    "mixer_set_volume": Case(args={"handle": "$MIXER_VOLUME", "volume_db": 0.0},
                             kind="write"),
    "mixer_set_mute": write(index=0, muted=False),
    "mixer_set_solo": write(index=0, solo=False),
    "mixer_set_all_volumes": write(
        volumes=[{"handle": "$MIXER_VOLUME", "volumeDB": 0.0}]),
    "mixer_volume_begin": Case(args={"effect_stack_handle": "$MIXER_STACK"},
                               kind="write",
                               cleanup=[("mixer_volume_end",
                                         {"effect_stack_handle": "$MIXER_STACK"})]),
    "mixer_volume_end": skip("closes the scope mixer_volume_begin opens"),
    # Fader 0 is the primary-storyline clip under the playhead (the prelude puts it
    # there), whose collection is its audio bus.
    "mixer_apply_bus_effect": Case(args={"name": "Channel EQ", "index": 0}, kind="write",
                                   expect=r"^Applied",
                                   cleanup=[("mixer_remove_bus_effect",
                                             {"effect_index": 0, "index": 0})]),
    "mixer_open_bus_effect": skip("opens a plugin window a person has to close"),
    "mixer_set_bus_effect_enabled": Case(args={"effect_index": 0, "index": 0,
                                               "enabled": False},
                                         kind="write", setup=["bus_effect"]),
    "mixer_remove_bus_effect": Case(args={"effect_index": 0, "index": 0}, kind="write",
                                    setup=["bus_effect"]),

    # ---------------------------------------------------------------- lua / plugins
    "lua_execute": read(code="return 1 + 1"),
    "lua_execute_file": Case(args={"path": "$LUA_SCRIPT"}, kind="read", expect=r"7|ok"),
    "lua_reset": write(),
    "reload_plugin_tools": read(),

    # ---------------------------------------------------------------- debug config
    "debug_set_config": write(key="verbose", value="false"),
    "debug_reset_config": write(scope="all"),
    "debug_enable_preset": write(preset="all_off"),
    "debug_start_framerate_monitor": write(interval=2.0,
                                           cleanup=[("debug_stop_framerate_monitor", {})]),
    "debug_stop_framerate_monitor": write(),

    # ---------------------------------------------------------------- AI
    "ai_command": Case(args={"query": "how many clips are on the timeline?"},
                       kind="write", timeout=400),
    # Only an answer naming what is missing and how to get it counts as BLOCKED.
    "ai_command_gemma": dependency("Local model unavailable", "Python 3 not found",
                                   "Check the model ID", "Not enough memory",
                                   timeout=400,
                                   query="how many clips are on the timeline?"),
    # The palette "blade" command cuts the timeline — this is a write, not a read.
    "execute_command": write(action="blade", type="timeline",
                             undo=("Blade", "Blade Clips", "Blade at Times")),
    "execute_menu_command": read(menu_path=["Edit", "Undo"], dry_run=True),

    # ---------------------------------------------------------------- dialogs
    "click_dialog_button": Case(args={"button": "OK"}, kind="read",
                                expect=r"[Nn]o dialog"),
    "fill_dialog_field": Case(args={"value": "x"}, kind="read", expect=r"[Nn]o dialog"),
    "toggle_dialog_checkbox": Case(args={"checkbox": "x"}, kind="read",
                                   expect=r"[Nn]o dialog"),
    "select_dialog_popup": Case(args={"select": "x"}, kind="read",
                                expect=r"[Nn]o dialog"),
    "dismiss_dialog": Case(args={"action": "cancel"}, kind="read",
                           expect=r"[Nn]o dialog"),

    # ---------------------------------------------------------------- imports
    # These four are exercised on the path that matters: a real file, real FCPXML,
    # a real download. Refusing bad input was all the sweep used to prove, which is
    # not the same as importing. Each one cleans the library up after itself —
    # remove_browser_clip for a clip, and for a project the same call with
    # include_projects, since the imported project lands in the user's own event.
    "import_media": Case(args={"path": "$PROBE_MEDIA", "event": "$EVENT_NAME"},
                         kind="write", timeout=180,
                         expect=r'"imported"',
                         cleanup=[("remove_browser_clip", {"name": "$PROBE_NAME"})]),
    "import_fcpxml": Case(args={"xml": "$SCRATCH_FCPXML"}, kind="write", timeout=300,
                          expect=r"importOK|\bok\b",
                          cleanup=[("remove_browser_clip",
                                    {"name": "$SCRATCH_PROJECT", "include_projects": True})]),
    # Without a job id it lists every import since Final Cut Pro started.
    "import_fcpxml_status": read(),
    "paste_fcpxml": Case(args={"xml": "$PASTE_FCPXML"}, kind="write", timeout=300,
                         expect=r"importOK|\bok\b",
                         cleanup=[("remove_browser_clip",
                                   {"name": "$PASTE_PROJECT", "include_projects": True})]),
    # target_event keeps the download in the QA event: left to itself import_url
    # makes a "URL Imports" event, and an empty event would be left behind every run.
    "import_url": Case(args={"url": "$PROBE_URL", "mode": "import_only",
                             "target_event": "$EVENT_NAME",
                             "title": "$URL_PROBE_NAME"},
                       kind="write", timeout=300,
                       expect=r"completed|imported",
                       cleanup=[("remove_browser_clip", {"name": "$URL_PROBE_NAME"})]),
    # Its happy path is the cleanup step of the three above; on its own it has to say
    # clearly that nothing matched rather than quietly reporting success.
    "remove_browser_clip": Case(args={"name": "no-such-clip-in-this-library"},
                                kind="read",
                                expect=r"No browser clip matching"),
    "import_url_status": Case(args={"job_id": "no-such-job"}, kind="read",
                              expect=r"[Nn]ot found|[Nn]o such|[Uu]nknown"),
    "cancel_import_url": Case(args={"job_id": "no-such-job"}, kind="read",
                              expect=r"[Nn]ot found|[Nn]o such|[Uu]nknown"),

    # ---------------------------------------------------------------- handles
    # Releasing handles invalidates the ones the sweep holds, so both re-resolve
    # their placeholders straight afterwards rather than being skipped outright.
    "release_handle": Case(args={"handle": "$CONNECTED_CLIP"}, kind="write",
                           invalidates_handles=True),
    "release_all_handles": Case(args={}, kind="write", invalidates_handles=True),

    # ---------------------------------------------------------------- modal panels
    "create_project": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "create_event": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "create_library": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    # Opens Final Cut Pro's Export sheet and returns dialogPending straight away; the
    # sheet is cancelled in cleanup. It used to send -shareDefaultDestination: down the
    # responder chain, which nothing on FCP 12.3 answers.
    "share_project": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    # Was modal, and so never ran: with no folder it opened a picker from inside the
    # bridge's main-thread dispatch and hung until the watchdog gave up. It takes a
    # folder now, so it has a real happy path. Rendering every clip takes a while.
    # scope="selected" with one clip, not "all": exporting the whole timeline renders
    # about 840 MB and takes 40 seconds, for no more proof than one clip gives.
    "batch_export": Case(args={"scope": "selected", "folder": "$EXPORT_DIR"},
                         kind="write", select_before="$SPINE_CLIP", timeout=300,
                         expect=r"clips? queued"),
    "open_project": Case(args={"name": EXPECTED_PROJECT}, kind="write",
                         invalidates_handles=True),
    # Mark > Set Range Start / End (setSelectionStart: / setSelectionEnd:); a range
    # selection is not an edit, so Mark > Clear Selected Ranges takes it back.
    "set_timeline_range": write(start_seconds="$T_A", end_seconds="$T_B", expect=r"Range set",
                                cleanup=[("timeline_edit_action",
                                          {"action": "clearRange"})]),

    # ---------------------------------------------------------------- external deps
    # FlexMusic songs are Apple content; with none installed each tool has to say so.
    "flexmusic_list_songs": dependency("no FlexMusic songs are installed"),
    "flexmusic_get_song": dependency("no FlexMusic songs are installed", song_uid="none"),
    "flexmusic_get_timing": dependency("no FlexMusic songs are installed",
                                       song_uid="none", duration_seconds=10.0),
    "flexmusic_render_to_file": dependency("no FlexMusic songs are installed",
                                           song_uid="none", duration_seconds=10.0,
                                           output_path="$TMP/sweep-flexmusic.m4a"),
    "flexmusic_add_to_timeline": dependency("no FlexMusic songs are installed",
                                            song_uid="none"),

    # ---------------------------------------------------------------- not sweepable
    "deploy_and_restart": skip("quits and relaunches Final Cut Pro"),
})


# --------------------------------------------------------------------------- runner

@dataclass
class Result:
    tool: str
    status: str
    detail: str = ""
    seconds: float = 0.0


class Sweep:
    def __init__(self, client, args):
        self.cl = client
        self.args = args
        self.results: list[Result] = []
        self.placeholders: dict[str, str] = {}
        self.tmp = Path(os.environ.get("CLAUDE_JOB_DIR", "/tmp")) / "sweep-scratch"
        self.tmp.mkdir(parents=True, exist_ok=True)
        self._server = None
        self._server_url = ""
        self.times: dict[str, float] = {}
        # A clip of spoken text for the transcript, caption and place/append cases. Made
        # with `say` for the run, imported into the project's event, removed at the end.
        token = f"{os.getpid()}"
        self.speech_name = f"splicekit-sweep-speech-{token}"
        self.speech_path = self.tmp / f"{self.speech_name}.mov"
        self.speech_imported = False
        # Parakeet v3 must already be on disk: the sweep never starts a model download.
        models = Path.home() / "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
        self.parakeet_ok = models.is_dir() and any(models.glob("*.mlmodelc"))
        self.parakeet_reason = ("" if self.parakeet_ok else
                                f"the Parakeet v3 model is not on disk ({models}); the transcript "
                                "would download it (about 600 MB) first, which the sweep never does. "
                                "Run open_transcript() once by hand to fetch it.")

    # -- plumbing ----------------------------------------------------------

    async def call(self, tool: str, args: dict, timeout: float = 60.0) -> str:
        r = await asyncio.wait_for(self.cl.call_tool(tool, args), timeout)
        parts = []
        for block in (getattr(r, "content", None) or []):
            if getattr(block, "type", None) == "text":
                parts.append(block.text)
        return "\n".join(parts)

    async def shape(self) -> tuple:
        """The timeline in the four numbers a sweep must not change."""
        text = await self.call("get_timeline_clips", {})
        def grab(pattern, default="?"):
            m = re.search(pattern, text, re.M)
            return m.group(1) if m else default
        return (grab(r"^Items: (\d+)"), grab(r"^Duration: ([\d.]+)s"),
                grab(r"^Markers: (\d+)"), grab(r"^Connected: (\d+)"))

    async def undo_name(self) -> str:
        text = await self.call("list_menus", {"menu": "Edit"})
        m = re.search(r'"undoActionName":\s*"([^"]*)"', text)
        return m.group(1) if m else ""

    # -- placeholders ------------------------------------------------------

    def serve(self) -> str:
        """Serve the scratch directory over HTTP and return its base URL.

        import_url downloads and imports, so proving it works needs a URL. A local
        server keeps that off the network: no provider, no yt-dlp, nothing that can
        be slow or missing on the machine running the sweep.
        """
        if self._server_url:
            return self._server_url
        from functools import partial
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        handler = partial(SimpleHTTPRequestHandler, directory=str(self.tmp))
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        host, port = self._server.server_address[:2]
        self._server_url = f"http://{host}:{port}"
        return self._server_url


    async def timeline_state(self) -> dict:
        """timeline.getDetailedState as JSON: exact seconds, which the text table rounds."""
        text = await self.call("raw_call", {"method": "timeline.getDetailedState",
                                            "params": "{}"})
        try:
            return json.loads(text)
        except ValueError:
            return {}

    async def resolve_placeholders(self) -> None:
        state = await self.timeline_state()

        def secs(entry, key):
            value = entry.get(key)
            return float(value.get("seconds", 0.0)) if isinstance(value, dict) else None

        spine = [i for i in state.get("items", []) if isinstance(i, dict)]
        media = [i for i in spine
                 if "Gap" not in str(i.get("class", "")) and "Transition" not in str(i.get("class", ""))]
        connected = [i for i in state.get("connectedItems", []) if isinstance(i, dict)]
        # A clip with footage, never the gap the primary storyline starts with: batch_export
        # and the dual timeline need something to act on.
        self.placeholders["$SPINE_CLIP"] = (media or spine or [{}])[0].get("handle", "")
        lane1 = [c for c in connected if c.get("lane") == 1] or connected
        self.placeholders["$CONNECTED_CLIP"] = ((lane1[0].get("handle") if lane1 else "")
                                                or self.placeholders["$SPINE_CLIP"])

        # Timeline times. Taken from the project, never hard-coded: a project's timeline
        # starts at its start timecode (00:00:30:00 for the test project), so a fixed 5.0
        # was before the first frame and every playhead edit there silently did nothing.
        anchor = lane1[0] if lane1 else (media[0] if media else {})
        a_start, a_end = secs(anchor, "startTime") or 0.0, secs(anchor, "endTime") or 0.0
        home = round((a_start + a_end) / 2.0, 3)
        self.times = {"$T_HOME": home, "$T_A": home, "$T_B": round(home + 1.0, 3)}
        edit = None
        for left, right in zip(spine, spine[1:]):
            if left in media and right in media:
                edit = secs(right, "startTime")
                break
        self.times["$T_EDIT"] = edit if edit is not None else home
        for key, value in self.times.items():
            self.placeholders[key] = f"{value:.3f}"
        # SRT times count from the timeline's first frame, whatever its start timecode.
        t_start = secs(spine[0], "startTime") if spine else 0.0
        for key, value in (("$SRT_A", home - (t_start or 0.0)),
                           ("$SRT_B", home - (t_start or 0.0) + 1.0)):
            ms = int(round(value * 1000))
            self.placeholders[key] = (f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:"
                                      f"{ms // 1000 % 60:02d},{ms % 1000:03d}")

        info = await self.call("get_clip_info",
                               {"handle": self.placeholders["$CONNECTED_CLIP"],
                                "include_frame": False})
        m = re.search(r"^\s+path: (.+)$", info, re.M)
        self.placeholders["$MEDIA_FILE"] = m.group(1).strip() if m else ""

        # A media file with sound for the audio analysers (detect_beats and the song
        # structure tools): the first clip whose source file has an audio track. The
        # connected clip is a screen recording without one.
        audio_file = ""
        for item in media + connected:
            handle = item.get("handle")
            if not handle:
                continue
            clip_info = await self.call("get_clip_info", {"handle": handle,
                                                          "include_frame": False})
            path = re.search(r"^\s+path: (.+)$", clip_info, re.M)
            if not path or not re.search(r"^\s+(video\+audio|audio)", clip_info, re.M):
                continue
            candidate = path.group(1).strip()
            probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a",
                                    "-show_entries", "stream=index", "-of", "csv=p=0",
                                    candidate], capture_output=True, text=True)
            if probe.returncode == 0 and probe.stdout.strip():
                audio_file = candidate
                break
        self.placeholders["$AUDIO_FILE"] = audio_file

        await self.call("select_clips", {"handles": self.placeholders["$CONNECTED_CLIP"]})
        props = await self.call("get_inspector_properties", {})
        m = re.search(r'"effectStackHandle":\s*"(obj_\d+)"', props)
        self.placeholders["$EFFECT_STACK"] = m.group(1) if m else ""

        # Anything SpliceKit's own pipelines left behind goes before the run reads the
        # browser. A scratch project left by a previous run's song_structure_blocks or
        # generate_native_captions is empty, and Final Cut Pro reports an empty, unopened
        # project as a clip — isProject false, sequenceType "clip" — so it was picked as
        # $BROWSER_CLIP and handed to add_clip_to_timeline and browser_append_clip, which
        # refused it once FCP had loaded the sequence and could tell. That is three
        # failures in a run, caused by the run before it.
        await self.call("cleanup_temp_projects", {})

        # A source clip, not a project: browser_list_clips marks projects with
        # isProject true, and the place/append tools rightly refuse one. Scratch names are
        # skipped by name as well, for the empty-project case FCP cannot label correctly.
        # Parsed as JSON: each row nests a "duration" object, so a regex for a flat
        # {...} block only ever matched the durations and never saw a row's name.
        rows = browser_rows(await self.call("browser_list_clips", {}))
        source = ""
        for row in rows:
            if row.get("isProject") is False and not SCRATCH_NAME.match(row.get("name", "")):
                source = row.get("handle", "")
                break
        self.placeholders["$BROWSER_CLIP"] = source or (rows[0].get("handle", "") if rows else "")

        # The source clip the sweep imported for this run (prepare_fixtures), found again
        # by name: handles do not survive release_all_handles or reopening the project.
        self.placeholders["$SOURCE_CLIP"] = next(
            (row.get("handle", "") for row in rows if row.get("name") == self.speech_name), "")

        # The mixer hands out its own handles: a volume channel and an effect stack
        # per fader. A clip's effect-stack handle from get_inspector_properties is not
        # the same object and mixer_set_volume rejects it.
        # A tiny Lua script for lua_execute_file, and the clip's own name so
        # set_object_property can write back what is already there.
        script = self.tmp / "sweep.lua"
        script.write_text("return 3 + 4\n")
        self.placeholders["$LUA_SCRIPT"] = str(script)

        name = re.search(r'"name":\s*"([^"]*)"', info) or re.search(r"^(\S.*?) — ", info, re.M)
        self.placeholders["$CLIP_NAME"] = name.group(1) if name else "clip"

        options = await self.call("get_bridge_options", {})
        m = re.search(r'"([a-zA-Z][a-zA-Z0-9_]*)"\s*:\s*(?:true|false)', options)
        self.placeholders["$BRIDGE_OPTION"] = m.group(1) if m else ""
        # set_bridge_option_value needs an option that carries a string, and writing
        # back its current value keeps the sweep from changing a setting.
        v = re.search(r'"([a-zA-Z][a-zA-Z0-9_]*)"\s*:\s*"([^"]*)"', options)
        self.placeholders["$BRIDGE_VALUE_OPTION"] = v.group(1) if v else ""
        self.placeholders["$BRIDGE_VALUE_CURRENT"] = v.group(2) if v else ""

        mixer = await self.call("mixer_get_state", {})
        vol = re.search(r"vol=(obj_\d+)", mixer)
        es = re.search(r"es=(obj_\d+)", mixer)
        self.placeholders["$MIXER_VOLUME"] = vol.group(1) if vol else ""
        self.placeholders["$MIXER_STACK"] = es.group(1) if es else ""

        self.placeholders["$TMP"] = str(self.tmp)

        # -- what the import tools import ---------------------------------
        # Every name below carries a token unique to this run.
        #
        # Final Cut Pro keeps a name reserved after the thing holding it is trashed, so
        # a second run's import landed as "SpliceKit Sweep Import 1" and the cleanup,
        # which asks for the exact name, walked straight past it. The leftover copy then
        # made open_project("QA Timeline") open "QA Timeline 1" instead.
        token = f"{os.getpid()}"
        # A file of our own, so importing it cannot be confused with the media already
        # in the library and removing it afterwards cannot take a real clip with it.
        probe = self.tmp / f"splicekit-sweep-probe-{token}.mov"
        if not probe.exists():
            made = subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error",
                 "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30:duration=2",
                 "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                 str(probe)],
                capture_output=True).returncode == 0
            if not made:
                # No ffmpeg: link the timeline's own media under a name of its own
                # rather than copying a multi-gigabyte file.
                source = self.placeholders["$MEDIA_FILE"]
                probe = self.tmp / (f"splicekit-sweep-probe-{token}" + Path(source).suffix)
                try:
                    os.link(source, probe)
                except OSError:
                    probe.unlink(missing_ok=True)
                    os.symlink(source, probe)
        self.placeholders["$PROBE_MEDIA"] = str(probe)
        self.placeholders["$PROBE_NAME"] = probe.stem

        # batch_export needs somewhere to write. Its own scratch directory, removed with
        # the rest of self.tmp at the end of the run.
        export_dir = self.tmp / f"batch-export-{token}"
        export_dir.mkdir(parents=True, exist_ok=True)
        self.placeholders["$EXPORT_DIR"] = str(export_dir)

        # import_url wants a URL. Serving the scratch directory keeps the sweep off the
        # network and still exercises the whole download-and-import path.
        self.placeholders["$PROBE_URL"] = f"{self.serve()}/{probe.name}"

        # The event the QA project lives in — never a "SpliceKit Structure 2" or
        # "SpliceKit Captions 3" a previous run's pipeline declared, which is what
        # import_media was handed when the first event in the listing happened to be one
        # of those. It had been swept away by then, so the import failed outright.
        browser_json = await self.call("browser_list_clips", {})
        event = ""
        for candidate in re.findall(r'"event":\s*"([^"]+)"', browser_json):
            if not SCRATCH_NAME.match(candidate):
                event = candidate
                break
        self.placeholders["$EVENT_NAME"] = event

        # Real FCPXML for the two FCPXML importers: this project, exported, with the
        # project name rewritten so each import lands beside the original instead of
        # colliding with it.
        export_path = self.tmp / "sweep-import.fcpxml"
        await self.call("export_xml", {"path": str(export_path)}, 180)
        exported = export_path.read_text(encoding="utf-8")
        for key, project in (("$SCRATCH", f"SpliceKit Sweep Import {token}"),
                             ("$PASTE", f"SpliceKit Sweep Paste {token}")):
            self.placeholders[f"{key}_PROJECT"] = project
            self.placeholders[f"{key}_FCPXML"] = re.sub(
                r'<project name="[^"]*"', f'<project name="{project}"', exported, count=1)

        # import_otio builds its project from the timeline's name in the file, so the
        # file gets a name of its own too.
        otio_path = self.tmp / "sweep-import.otio"
        await self.call("export_otio", {"path": str(otio_path)}, 180)
        document = json.loads(otio_path.read_text(encoding="utf-8"))
        document["name"] = f"SpliceKit Sweep OTIO {token}"
        otio_path.write_text(json.dumps(document), encoding="utf-8")
        self.placeholders["$OTIO_IMPORT"] = str(otio_path)
        self.placeholders["$OTIO_PROJECT"] = document["name"]

        self.placeholders["$URL_PROBE_NAME"] = f"SpliceKit Sweep URL {token}"

        # montage_plan_edit wants the clip list montage_analyze_clips produces, so
        # take it from there rather than inventing a shape that drifts from the tool.
        analyzed = await self.call("montage_analyze_clips", {}, 300)
        try:
            clips = json.loads(analyzed).get("clips", [])
        except Exception:
            clips = []
        self.placeholders["$MONTAGE_CLIPS"] = json.dumps([
            {"handle": c.get("handle"), "duration": c.get("duration", 5.0),
             "score": c.get("score", 1)}
            for c in clips[:4]
        ])

        optional = {"$BRIDGE_VALUE_OPTION", "$BRIDGE_VALUE_CURRENT", "$MONTAGE_CLIPS",
                    "$SOURCE_CLIP", "$AUDIO_FILE"}
        missing = [k for k, v in self.placeholders.items() if not v and k not in optional]
        if missing:
            raise SystemExit(f"could not resolve {missing} from the live timeline; "
                             "is the QA project open with a connected clip?")

    def fill(self, value):
        """Substitute placeholders anywhere in an argument, including inside lists
        and dicts — mixer_set_all_volumes takes a list of {handle, volumeDB}."""
        if isinstance(value, str):
            # Longest names first, so $T_AB would never be read as $T_A + "B".
            for name in sorted(self.placeholders, key=len, reverse=True):
                value = value.replace(name, self.placeholders[name])
            return value
        if isinstance(value, dict):
            return {k: (self.times[v] if k in NUMERIC_ARGS and isinstance(v, str)
                        and v in self.times else self.fill(v))
                    for k, v in value.items()}
        if isinstance(value, list):
            return [self.fill(v) for v in value]
        return value

    # -- one case ----------------------------------------------------------

    async def run_case(self, tool: str, case: Case) -> Result:
        started = time.monotonic()
        if case.kind == "skip":
            return Result(tool, SKIPPED, case.reason)
        if case.needs_parakeet and not self.parakeet_ok:
            return Result(tool, BLOCKED, self.parakeet_reason)

        # The same starting point for every case: the playhead over the connected clip
        # (and the primary-storyline clip under it), that clip selected.
        await self.call("seek_to_time", {"seconds": self.times.get("$T_HOME", 0.0)})
        await self.call("select_clips",
                        {"handles": self.fill(case.select_before or "$CONNECTED_CLIP")})

        pre_setup = await self.shape()
        teardown: list[str] = []
        try:
            for step in case.setup:
                await self.setup_step(step, teardown)
        except SetupError as exc:
            await self.teardown_fixtures(teardown, pre_setup)
            return Result(tool, FAIL, f"setup: {exc}", time.monotonic() - started)

        try:
            return await self.run_case_body(tool, case, started)
        finally:
            problem = await self.teardown_fixtures(teardown, pre_setup)
            if problem:
                self.results.append(Result(f"{tool} (fixture)", FAIL, problem))
                print(f"  {'FAIL':8s} {tool} (fixture): {problem}")

    async def run_case_body(self, tool: str, case: Case, started: float) -> Result:
        args = self.fill(case.args)
        before = await self.shape()

        # Every early return below used to skip restore(), and with it case.cleanup — the
        # step that takes the imported clip or project back out of the library. An import
        # that timed out client-side, or failed after the browser item had already landed,
        # left it there for good: the sweep's own names ("SpliceKit Sweep Import <pid>")
        # match nothing cleanup_temp_projects sweeps, so there was no second chance. The
        # finally runs the cleanup steps on every path that did not already reach restore().
        cleaned = False
        try:
            try:
                out = await self.call(tool, args, case.timeout)
            except asyncio.TimeoutError:
                return Result(tool, FAIL, f"timed out after {case.timeout:.0f}s",
                              time.monotonic() - started)
            except Exception as exc:
                return Result(tool, FAIL, f"{type(exc).__name__}: {exc}"[:400],
                              time.monotonic() - started)

            elapsed = time.monotonic() - started
            snippet = " ".join(out.split())[:300]
            errored = out.lstrip().lower().startswith("error")

            # A tool that needs something not installed here passes only when it says so.
            if case.kind == "dependency":
                low = out.lower()
                if any(marker.lower() in low for marker in case.dependency_markers):
                    return Result(tool, BLOCKED, snippet, elapsed)
                if errored:
                    return Result(tool, FAIL,
                                  f"failed without naming the missing dependency: {snippet}",
                                  elapsed)
                return Result(tool, PASS, snippet, elapsed)

            failure = ""
            if errored and not (case.expect and re.search(case.expect, out)):
                failure = snippet
            elif case.expect and not re.search(case.expect, out):
                failure = f"answer did not match /{case.expect}/: {snippet}"
            if failure:
                # A tool can edit and still answer wrongly (assign_role once left a role
                # changed because its answer failed the check): put the project back anyway.
                cleaned = True
                restored = await self.restore(case, before, lenient=True)
                return Result(tool, FAIL, f"{failure} | {restored}" if restored else failure,
                              elapsed)

            # Put the project back. restore() runs case.cleanup itself, first.
            cleaned = True
            restored = await self.restore(case, before)
            if restored:
                return Result(tool, FAIL, f"{snippet} | {restored}", elapsed)
            return Result(tool, PASS, snippet, elapsed)
        finally:
            if not cleaned:
                await self.cleanup_only(case)

    # -- fixtures ----------------------------------------------------------

    async def wait_for(self, tool: str, args: dict, pattern: str, seconds: float,
                       fail_pattern: str | None = None) -> str:
        """Poll a read tool until its answer matches `pattern`."""
        deadline = time.monotonic() + seconds
        out = ""
        while time.monotonic() < deadline:
            out = await self.call(tool, args)
            if re.search(pattern, out):
                return out
            if fail_pattern and re.search(fail_pattern, out):
                break
            await asyncio.sleep(2.0)
        raise SetupError(f"{tool} never showed /{pattern}/: {' '.join(out.split())[:200]}")

    async def setup_step(self, step, teardown: list[str]) -> None:
        if isinstance(step, tuple):
            # (tool, args) or (tool, args, undo name): the latter is an edit the teardown
            # takes back with one undo of that name.
            tool, args = step[0], step[1]
            out = await self.call(tool, self.fill(args), 300)
            if out.lstrip().lower().startswith("error"):
                raise SetupError(f"{tool}: {' '.join(out.split())[:200]}")
            if len(step) > 2:
                names = (step[2],) if isinstance(step[2], str) else tuple(step[2])
                teardown.append(("undo",) + names)
            return
        if step == "deselect":
            await self.call("select_clips", {"handles": ""})
        elif step == "edit_point":
            await self.call("select_clips", {"handles": ""})
            await self.call("seek_to_time", {"seconds": self.times["$T_EDIT"]})
        elif step == "speech_fixture":
            if not self.placeholders.get("$SOURCE_CLIP"):
                raise SetupError("the sweep's speech clip is not in the browser")
            out = await self.call("add_clip_to_timeline",
                                  {"handle": self.placeholders["$SOURCE_CLIP"],
                                   "edit": "append"}, 120)
            if "verified" not in out or out.lower().startswith("error"):
                raise SetupError(f"appending the speech clip: {' '.join(out.split())[:200]}")
            teardown.append("speech_fixture")
        elif step == "transcript":
            await self.call("set_transcript_engine", {"engine": "parakeetV3"})
            out = await self.call("open_transcript", {"force_retranscribe": True}, 120)
            if out.lower().startswith("error"):
                raise SetupError(f"open_transcript: {' '.join(out.split())[:200]}")
            await self.wait_for("get_transcript", {}, r"(?i)\bfox\b", 180,
                                fail_pattern=r"Status: (error|failed)")
        elif step == "captions":
            out = await self.call("open_captions", {"force_retranscribe": True}, 120)
            if out.lower().startswith("error"):
                raise SetupError(f"open_captions: {' '.join(out.split())[:200]}")
            await self.wait_for("get_caption_state", {}, r"(?i)\bfox\b", 180,
                                fail_pattern=r"Status: (error|failed)")
        elif step == "bus_effect":
            out = await self.call("mixer_apply_bus_effect", {"name": "Channel EQ", "index": 0})
            if not out.startswith("Applied"):
                raise SetupError(f"mixer_apply_bus_effect: {' '.join(out.split())[:200]}")
            teardown.append("bus_effect")
        else:
            raise SetupError(f"unknown setup step {step!r}")

    async def teardown_fixtures(self, teardown: list[str], pre_setup: tuple) -> str:
        """Take the fixtures back off, newest first. Returns "" when the timeline is as it
        was before the setup ran."""
        for step in reversed(teardown):
            if isinstance(step, tuple) and step[0] == "undo":
                for expected in step[1:]:
                    name = await self.undo_name()
                    if name != expected:
                        return (f"a setup edit could not be taken off: the undo stack says "
                                f"{name!r}, expected {expected!r}")
                    await self.call("history_action", {"action": "undo"})
            elif step == "speech_fixture":
                name = await self.undo_name()
                if name != "Paste":
                    return (f"the speech clip could not be taken off: the undo stack says "
                            f"{name!r}, expected 'Paste'")
                await self.call("history_action", {"action": "undo"})
            elif step == "bus_effect":
                await self.call("seek_to_time", {"seconds": self.times.get("$T_HOME", 0.0)})
                state = await self.call("mixer_get_state", {})
                fader0 = state.split("Fader 1:")[0]
                m = re.search(r"(\d+) effect\(s\)", fader0)
                if m and int(m.group(1)) > 0:
                    await self.call("mixer_remove_bus_effect", {"effect_index": 0, "index": 0})
        after = await self.shape()
        if teardown and after != pre_setup:
            return f"fixture not removed: {pre_setup} -> {after}"
        return ""

    async def cleanup_only(self, case: Case) -> None:
        """Run just case.cleanup, for a case that failed before restore() was reached.

        Never raises: the case has already failed and the report belongs to that failure,
        not to a cleanup that could not run. Anything that goes wrong is printed so a
        leftover in the library is at least visible in the log.
        """
        for tool, args in case.cleanup:
            try:
                await self.call(tool, self.fill(args), case.timeout)
            except Exception as exc:
                print(f"    ! cleanup {tool} after failure raised "
                      f"{type(exc).__name__}: {exc}", flush=True)

    async def restore(self, case: Case, before: tuple, lenient: bool = False) -> str:
        """Undo or clean up after a case. Returns "" when the timeline is back.

        The undo comes first: a cleanup step can itself be an edit (remove_captions is),
        and it would then sit on top of the step the case made."""
        if case.undo:
            wanted = (case.undo,) if isinstance(case.undo, str) else tuple(case.undo)
            name = await self.undo_name()
            if name in wanted:
                await self.call("history_action", {"action": "undo"})
                for extra in case.extra_undo:
                    if await self.undo_name() == extra:
                        await self.call("history_action", {"action": "undo"})
            elif case.require_undo and not lenient:
                problem = (f"made no edit: the undo stack says {name!r}, expected one of "
                           f"{wanted}")
                await self.cleanup_only(case)
                return problem
            elif await self.shape() != before:
                await self.cleanup_only(case)
                return (f"the timeline changed but the undo stack says {name!r}, "
                        f"expected one of {wanted} — the change cannot be taken back")
            # Otherwise the tool decided there was nothing to do (no scene changes
            # found, no clip matched) and correctly made no edit. That is a pass, not
            # a missing undo step.

        for tool, args in case.cleanup:
            try:
                await self.call(tool, self.fill(args), case.timeout)
            except Exception as exc:
                return f"cleanup {tool} raised {type(exc).__name__}: {exc}"[:200]

        after = await self.shape()
        if after != before:
            return f"timeline not restored: {before} -> {after}"
        return ""

    # -- run-level fixtures and the before/after check ------------------------

    async def prepare_fixtures(self) -> None:
        """Make the speech clip and import it into the project's event."""
        if not self.speech_path.exists():
            aiff = self.speech_path.with_suffix(".aiff")
            said = subprocess.run(["say", "-o", str(aiff),
                                   "The quick brown fox jumps over the lazy dog. Final Cut Pro "
                                   "edits this sentence for the sweep."],
                                  capture_output=True).returncode == 0
            made = said and subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error",
                 "-f", "lavfi", "-i", "color=c=navy:size=320x180:rate=30",
                 "-i", str(aiff), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-ar", "48000", "-shortest", str(self.speech_path)],
                capture_output=True).returncode == 0
            if not made:
                print("  could not make the speech clip (say / ffmpeg); the transcript, "
                      "caption and place cases will fail setup", flush=True)
                return
        browser = await self.call("browser_list_clips", {})
        event = ""
        for candidate in re.findall(r'"event":\s*"([^"]+)"', browser):
            if not SCRATCH_NAME.match(candidate):
                event = candidate
                break
        out = await self.call("import_media", {"path": str(self.speech_path), "event": event}, 180)
        self.speech_imported = '"imported"' in out and self.speech_name in out
        if not self.speech_imported:
            print(f"  importing the speech clip failed: {' '.join(out.split())[:200]}", flush=True)

    async def remove_fixtures(self) -> None:
        for tool, args in (("close_transcript", {}), ("close_captions", {})):
            try:
                await self.call(tool, args)
            except Exception:
                pass
        if self.speech_imported:
            out = await self.call("remove_browser_clip", {"name": self.speech_name})
            if "removed" not in out:
                print(f"  ! removing the speech clip: {' '.join(out.split())[:200]}", flush=True)
            self.speech_imported = False

    async def snapshot(self) -> dict:
        """Everything the sweep promises to leave as it found it, with SpliceKit's
        per-session handles and timings taken out."""
        def scrub(text: str) -> str:
            text = re.sub(r"obj_\d+", "obj", text)
            text = text.replace(", selected", "")      # the selection is not project content
            lines = [line for line in text.splitlines()
                     if not re.search(r"timings:|transcript|playhead", line, re.I)]
            return "\n".join(lines)

        snap: dict[str, Any] = {}
        snap["libraries"] = await self.call("get_active_libraries", {})
        browser = await self.call("browser_list_clips", {})
        rows = [(r.get("name", ""), r.get("event", ""), r.get("isProject"))
                for r in browser_rows(browser)]
        snap["browser"] = sorted(rows, key=str)
        state = await self.timeline_state()
        def item(e):
            return {k: (e.get(k, {}).get("seconds") if isinstance(e.get(k), dict) else e.get(k))
                    for k in ("name", "class", "lane", "startTime", "endTime", "time", "kind")
                    if k in e}
        snap["sequence"] = state.get("sequenceName")
        snap["duration"] = (state.get("duration") or {}).get("seconds")
        for key in ("items", "connectedItems", "markers"):
            snap[key] = [item(e) for e in state.get(key, []) if isinstance(e, dict)]
        clips = {}
        for e in state.get("items", []) + state.get("connectedItems", []):
            if isinstance(e, dict) and e.get("handle"):
                info = await self.call("get_clip_info", {"handle": e["handle"],
                                                         "include_frame": False})
                clips[f"{e.get('name')}@{item(e).get('startTime')}"] = scrub(info)
        snap["clips"] = clips
        await self.call("seek_to_time", {"seconds": self.times.get("$T_HOME", 0.0)})
        snap["mixer"] = scrub(await self.call("mixer_get_state", {}))
        return snap

    async def persist(self) -> str:
        """One real edit and its reverse, not an undo: Final Cut Pro saves the library on
        an edit, and a sweep that ends on undo leaves the file on disk one step behind
        what was checked (undo is not saved before a quit)."""
        before = await self.shape()
        home = self.times.get("$T_HOME", 0.0)
        await self.call("add_markers_at_times", {"markers": f"{home:.3f}"})
        listed = await self.call("list_markers", {})
        # Only the marker just added: the one at `home`, never a marker of the project's.
        handles = []
        for line in listed.splitlines():
            h = re.search(r"(obj_\d+)", line)
            times = [float(x) for x in re.findall(r"(?<![\w.])(\d+\.\d+)", line)]
            if h and any(abs(t - home) < 0.05 for t in times):
                handles.append(h.group(1))
        removed = False
        for handle in handles:
            out = await self.call("direct_timeline_action",
                                  {"action": "removeMarker", "marker": handle})
            if not out.lower().startswith("error"):
                removed = True
                break
        if not removed:
            await self.call("seek_to_time", {"seconds": home})
            await self.call("timeline_action", {"action": "deleteMarker"})
        after = await self.shape()
        if after != before:
            return f"the closing marker add + delete left the timeline changed: {before} -> {after}"
        return ""

    # -- the whole run -----------------------------------------------------

    async def run(self, tool_names: list[str]) -> int:
        start_playhead = await self.call("get_playhead_position", {})
        m = re.search(r'"seconds":\s*([\d.]+)', start_playhead) or re.search(r"([\d.]+)", start_playhead)
        self.start_playhead = float(m.group(1)) if m else self.times.get("$T_HOME", 0.0)
        start_snapshot = await self.snapshot()
        await self.prepare_fixtures()
        await self.resolve_placeholders()
        baseline = await self.shape()
        print(f"baseline timeline: items={baseline[0]} duration={baseline[1]}s "
              f"markers={baseline[2]} connected={baseline[3]}\n")

        width = max(len(n) for n in tool_names)
        for name in tool_names:
            case = CASES[name]
            result = await self.run_case(name, case)
            self.results.append(result)
            if case.invalidates_handles:
                try:
                    await self.resolve_placeholders()
                except SystemExit as exc:
                    print(f"  {'FAIL':8s} {'<re-resolve>':{width}s}  {exc}")
                    self.results.append(Result(f"{name} (handles)", FAIL, str(exc)))
                    break
            mark = {PASS: "ok", FAIL: "FAIL", BLOCKED: "blocked",
                    SKIPPED: "skip"}[result.status]
            print(f"  {mark:8s} {name:{width}s}  {result.detail[:110]}")
            if result.status == FAIL:
                # A failed restore leaves the project dirty; stop before the next
                # case builds on a state nobody checked.
                if "not restored" in result.detail or "nothing to undo" in result.detail:
                    print("\n  stopping: the project was left changed and the sweep "
                          "must not edit on top of that")
                    break

        final = await self.shape()
        await self.remove_fixtures()
        problem = await self.persist()
        if problem:
            self.results.append(Result("<sweep persist>", FAIL, problem))
            print(f"  FAIL     <sweep persist>: {problem}")
        end_snapshot = await self.snapshot()
        await self.call("seek_to_time", {"seconds": self.start_playhead})
        for label, snap in (("start", start_snapshot), ("end", end_snapshot)):
            (self.tmp / f"snapshot-{label}.json").write_text(
                json.dumps(snap, indent=2, default=str, sort_keys=True))
        diffs = [k for k in start_snapshot if start_snapshot.get(k) != end_snapshot.get(k)]
        if diffs:
            import difflib
            a = json.dumps({k: start_snapshot.get(k) for k in diffs}, indent=1,
                           default=str, sort_keys=True).splitlines()
            b = json.dumps({k: end_snapshot.get(k) for k in diffs}, indent=1,
                           default=str, sort_keys=True).splitlines()
            changed = [line for line in difflib.unified_diff(a, b, lineterm="", n=0)
                       if line[:1] in "+-" and line[:3] not in ("+++", "---")]
            detail = f"{', '.join(diffs)} differ: " + " | ".join(changed[:20])
            print(f"\nLIBRARY / PROJECT NOT AS THEY STARTED: {detail}")
            self.results.append(Result("<sweep snapshot>", FAIL, detail))
        else:
            print("\nlibrary, browser, timeline, clips and mixer match the start snapshot")
        print()
        if final != baseline:
            print(f"TIMELINE NOT BACK TO BASELINE: {baseline} -> {final}")
            self.results.append(Result("<sweep>", FAIL,
                                       f"timeline drifted {baseline} -> {final}"))
        else:
            print(f"timeline back to baseline: {final}")

        counts = {s: sum(1 for r in self.results if r.status == s)
                  for s in (PASS, FAIL, BLOCKED, SKIPPED)}
        print(f"\n{counts[PASS]} passed, {counts[FAIL]} failed, "
              f"{counts[BLOCKED]} blocked, {counts[SKIPPED]} skipped "
              f"of {len(self.results)}")

        if counts[FAIL]:
            print("\nfailed:")
            for r in self.results:
                if r.status == FAIL:
                    print(f"  {r.tool}: {r.detail}")

        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        return 1 if counts[FAIL] else 0


async def main_async(args) -> int:
    python = os.environ.get("SPLICEKIT_MCP_PYTHON", sys.executable)
    params = StdioServerParameters(command=python,
                                   args=[str(REPO / "mcp" / "server.py")],
                                   env={**os.environ, "PYTHONUNBUFFERED": "1"})
    async with Client(params, read_timeout_seconds=600) as client:
        listed = await client.list_tools()
        registered = {t.name for t in getattr(listed, "tools", listed)}

        # Plugin tools are registered at runtime from whatever plugins are installed,
        # so they cannot be named in a static spec. Give each one a read case.
        for name in sorted(registered - set(CASES)):
            if name.startswith("plugin_") and name not in CASES:
                CASES[name] = read()

        missing_case = sorted(registered - set(CASES))
        stale_case = sorted(set(CASES) - registered)
        if stale_case:
            print(f"spec names {len(stale_case)} tools that are not registered: "
                  f"{', '.join(stale_case)}", file=sys.stderr)
            return 2
        if missing_case:
            print(f"{len(missing_case)} registered tools have no case in this sweep:",
                  file=sys.stderr)
            for name in missing_case:
                print(f"  {name}", file=sys.stderr)
            print("every tool needs a case, even if it is skip(); add them and re-run.",
                  file=sys.stderr)
            return 2

        # The two cases that name the fixture itself follow the command line.
        CASES["get_active_libraries"] = read(expect=rf":\s*{re.escape(args.library)} —")
        CASES["open_project"] = Case(args={"name": args.allow_project or EXPECTED_PROJECT},
                                     kind="write", invalidates_handles=True,
                                     expect=r"(?i)opened|loaded|project")

        names = sorted(registered)
        if args.only:
            names = [n for n in names if any(n.startswith(p) for p in args.only)]
        if args.group:
            names = [n for n in names if CASES[n].kind == args.group]
        elif not args.only:
            names = [n for n in names if CASES[n].kind != "modal"]

        if args.list:
            for n in names:
                print(f"{CASES[n].kind:11s} {n}")
            return 0

        sweep = Sweep(client, args)

        # Refuse to touch anything but the throwaway project.
        clips = await sweep.call("get_timeline_clips", {})
        project = re.search(r"^Sequence: (.+)$", clips, re.M)
        opened = project.group(1).strip() if project else "(none)"
        expected = args.allow_project or EXPECTED_PROJECT
        if opened != expected:
            print(f"refusing to run: the open project is {opened!r}, not {expected!r}. "
                  f"This sweep edits the timeline.", file=sys.stderr)
            return 2
        # ... and only with the throwaway library open, alone.
        libraries = await sweep.call("get_active_libraries", {})
        count = re.search(r"Open libraries \((\d+)\)", libraries)
        if not count or count.group(1) != "1" or \
                not re.search(rf":\s*{re.escape(args.library)} —", libraries):
            print(f"refusing to run: the open libraries are not just {args.library!r}: "
                  f"{' '.join(libraries.split())[:300]}", file=sys.stderr)
            return 2

        await sweep.resolve_placeholders()
        code = await sweep.run(names)

        if args.json:
            Path(args.json).write_text(json.dumps(
                [r.__dict__ for r in sweep.results], indent=2))
            print(f"\nreport: {args.json}")
        return code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", default=[],
                    help="run only tools starting with this prefix (repeatable)")
    ap.add_argument("--group", choices=["read", "write", "dependency", "modal", "skip"])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--allow-project")
    ap.add_argument("--library", default=EXPECTED_LIBRARY,
                    help="the only library that may be open (default %(default)r)")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
