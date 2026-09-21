#!/usr/bin/env python3
"""Drive every MCP tool against a running, patched Final Cut Pro and report what works.

This is the check the other suites do not make. `tests/mcp_server_check.py` calls every
tool against a fake bridge, which proves a tool does not crash on a canned answer.
`tests/test_mcp_endpoints.py --live` calls the bridge directly and skips anything that
would change the timeline. Neither one proves that a tool which edits a project
actually edits it, so tools could sit broken for a long time while every suite stayed
green — that is exactly how a marker-placement bug and two crashers survived.

This sweep calls each tool the way a person would, checks the timeline afterwards, and
puts it back.

    WARNING: this sweep edits the open project. Run it only against the throwaway
    library. It refuses to start against anything else (see EXPECTED_PROJECT).

Usage
    python3 tests/live_tool_sweep.py [options]

    --only PREFIX     run only tools whose name starts with PREFIX (repeatable)
    --group NAME      run only one group (read / write / dependency / modal)
    --list            print the plan and exit without calling anything
    --json PATH       write a machine-readable report
    --allow-project N run against project N instead of the QA project (be careful)

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

REPO = Path(__file__).resolve().parent.parent
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


def read(expect: str | None = None, timeout: float = 60.0, **args) -> Case:
    return Case(args=args, kind="read", expect=expect, timeout=timeout)


def write(undo=None, cleanup=None, expect=None, timeout=60.0, **args) -> Case:
    return Case(args=args, kind="write", undo=undo, cleanup=cleanup or [],
                expect=expect, timeout=timeout)


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
    "seek_to_time": write(seconds=5.0, cleanup=[("seek_to_time", {"seconds": 11.979})]),
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
    "add_markers_at_times": write(markers="5.0, 10.0", undo="Add Markers"),
    "blade_at_times": write(times="5.0", undo=("Blade at Times", "Blade", "Blade Clips")),
    "timeline_edit_action": write(action="addMarker", undo=("Add Marker", "Marker")),
    "timeline_action": write(action="addMarker", undo=("Add Marker", "Marker")),
    "timeline_destructive_action": write(action="blade", undo=("Blade", "Blade Clips")),
    # Many direct actions are build-dependent; this one is the marker path the
    # handler is built around and is the one worth proving works.
    "direct_timeline_action": Case(args={"action": "changeMarkerName", "name": "sweep"},
                                   kind="read",
                                   expect=r"[Nn]o marker|marker"),
    "batch_timeline_actions": write(actions='[{"action":"addMarker"}]',
                                    undo_name="Sweep Batch", undo="Sweep Batch"),
    "history_action": Case(args={"action": "undo"}, kind="skip",
                           reason="driven by the sweep itself to undo other steps"),
    "begin_edit": write(name="Sweep Group", cleanup=[("end_edit", {"name": "Sweep Group"})]),
    "end_edit": skip("closes the group begin_edit opens; exercised as its cleanup"),
    "trim_clip": Case(args={"handle": "$CONNECTED_CLIP", "edge": "end",
                            "delta_seconds": -0.5},
                      kind="write", undo=("Trim", "Trim Clip", "Trim End")),
    "apply_effect": write(name="Black & White",
                          undo=("Add Effect", "Black & White", "Add Video Effect")),
    "apply_transition": write(name="Cross Dissolve",
                              undo=("Add Transition", "Cross Dissolve")),
    "apply_transition_to_all_clips": write(
        undo=("Add Transition", "Cross Dissolve", "Add Transitions"), timeout=120),
    "batch_apply_effect": write(name="Black & White", clip_count=2,
                                undo=("Batch Apply Effect", "Add Effect")),
    "batch_color_correct": write(correction="addColorBoard", clip_count=2,
                                 undo=("Batch Color Correct", "Add Color Board Effect")),
    "insert_title": write(name="Basic Title",
                          undo=("Connect to Primary Storyline", "Insert Title",
                                "Connect Title", "Add Basic Title")),
    "set_inspector_property": write(property="positionX", value=25,
                                    undo="Set positionX"),
    # A no-op write of the value already there: proves the KVC path works without
    # changing anything.
    "set_object_property": Case(args={"handle": "$CONNECTED_CLIP", "key": "displayName",
                                      "value": "$CLIP_NAME"}, kind="write"),
    # Final Cut Pro only populates its Assign Roles submenus while it is frontmost,
    # so from a background sweep this can only report that limitation.
    "assign_role": Case(args={"type": "video", "role": "Video"},
                        kind="dependency", select_before="$CONNECTED_CLIP",
                        dependency_markers=("frontmost", "enumerated no items")),
    "stabilize_subject": Case(args={}, kind="write", undo="Stabilize Subject", timeout=600),
    "import_srt_as_markers": write(
        srt_content="1\n00:00:05,000 --> 00:00:06,000\nsweep\n",
        undo=("Add Marker", "Add Markers", "Marker")),
    "add_clip_to_timeline": Case(args={"handle": "$BROWSER_CLIP", "edit": "append",
                                       "dry_run": True}, kind="read"),
    "browser_append_clip": Case(args={"handle": "$BROWSER_CLIP"}, kind="write",
                                undo=("Append", "Paste", "Append to Storyline",
                                      "Connect to Primary Storyline")),

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
    "toggle_structure_blocks": dependency("No structure blocks", "sections array"),
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
    "export_captions_srt": Case(args={"path": "$TMP/sweep.srt"}, kind="write"),
    "export_captions_txt": Case(args={"path": "$TMP/sweep.txt"}, kind="write"),
})

CASES.update({
    # ---------------------------------------------------------------- transcript
    "open_transcript": Case(args={}, kind="write", timeout=300,
                            cleanup=[("close_transcript", {})]),
    "close_transcript": write(),
    "get_transcript": read(),
    "search_transcript": read(query="the"),
    "delete_transcript_words": write(start_index=0, count=1,
                                     undo=("Delete", "Delete Words", "Ripple Delete")),
    "move_transcript_words": write(start_index=0, count=1, dest_index=3,
                                   undo=("Move", "Move Words", "Ripple Delete", "Paste")),
    "set_transcript_speaker": write(start_index=0, count=1, speaker="Sweep"),
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
                              cleanup=[("cleanup_temp_projects", {})]),
    "generate_native_captions": Case(args={}, kind="write", timeout=300,
                                     undo=("Paste", "Insert Captions"),
                                     cleanup=[("remove_captions", {"native": True}),
                                              ("cleanup_temp_projects", {})]),
    "cleanup_temp_projects": read(dry_run=True),
    # The counterpart to generate_native_captions. A dry run is enough here:
    # the real deletion is exercised as generate_native_captions's cleanup.
    "remove_captions": read(dry_run=True),

    # ---------------------------------------------------------------- beats / music
    "detect_beats": Case(args={"file_path": "$MEDIA_FILE", "limit": 8},
                         kind="read", timeout=180),
    "analyze_song_structure": Case(args={"file_path": "$MEDIA_FILE"},
                                   kind="read", timeout=180),
    "song_structure_sections": Case(args={"file_path": "$MEDIA_FILE"},
                                    kind="read", timeout=180),
    "beat_sync_blade": Case(args={"file_path": "$MEDIA_FILE", "dry_run": True},
                            kind="read", timeout=180),
    "song_structure_blocks": Case(args={"file_path": "$MEDIA_FILE"}, kind="write",
                                  timeout=180,
                                  cleanup=[("remove_structure_blocks", {}),
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
    "montage_auto": dependency("Song not found", "no song", "FlexMusic", "music library",
                               timeout=300, song_uid="none"),

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
    "mixer_apply_bus_effect": dependency("role-bearing collection",
                                        "No collection-backed bus",
                                        name="Channel EQ", index=0, dry_run=True),
    "mixer_open_bus_effect": skip("opens a plugin window a person has to close"),
    "mixer_set_bus_effect_enabled": dependency("bus effect", "No collection-backed",
                                               "not found", "no effect",
                                               effect_index=0, index=1, enabled=True),
    "mixer_remove_bus_effect": dependency("bus effect", "No collection-backed",
                                          "not found", "no effect",
                                          effect_index=0, index=1),

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
    "ai_command_gemma": dependency("MLX", "mlx", "model", "server", "not running",
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
    "share_project": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "batch_export": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "open_project": Case(args={"name": EXPECTED_PROJECT}, kind="write",
                         invalidates_handles=True),
    # FCP 12.3 has no setRangeStart:/setRangeEnd: on FFAnchoredTimelineModule, so the
    # honest result is the tool naming what it cannot find.
    "set_timeline_range": dependency("does not implement", "setRangeStart",
                                     start_seconds=1.0, end_seconds=2.0),

    # ---------------------------------------------------------------- external deps
    "flexmusic_list_songs": dependency("no songs", "not installed", "empty",
                                       "FlexMusic", "0 song"),
    "flexmusic_get_song": dependency("not found", "no song", "FlexMusic",
                                     song_uid="none"),
    "flexmusic_get_timing": dependency("not found", "no song", "FlexMusic",
                                       song_uid="none", duration_seconds=10.0),
    "flexmusic_render_to_file": dependency("not found", "no song", "FlexMusic",
                                           song_uid="none", duration_seconds=10.0,
                                           output_path="/tmp/sweep-flexmusic.m4a"),
    "flexmusic_add_to_timeline": dependency("not found", "no song", "FlexMusic",
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


    async def resolve_placeholders(self) -> None:
        clips = await self.call("get_timeline_clips", {})
        spine = re.findall(r"^\d+\s+\S+\s+.*?(obj_\d+)", clips, re.M)
        connected = re.findall(r"^\s+\d+\s+\S+\s+.*?(obj_\d+)", clips, re.M)
        self.placeholders["$SPINE_CLIP"] = spine[0] if spine else ""
        self.placeholders["$CONNECTED_CLIP"] = (connected[0] if connected
                                                else self.placeholders["$SPINE_CLIP"])

        info = await self.call("get_clip_info",
                               {"handle": self.placeholders["$CONNECTED_CLIP"],
                                "include_frame": False})
        m = re.search(r"^\s+path: (.+)$", info, re.M)
        self.placeholders["$MEDIA_FILE"] = m.group(1).strip() if m else ""

        await self.call("select_clips", {"handles": self.placeholders["$CONNECTED_CLIP"]})
        props = await self.call("get_inspector_properties", {})
        m = re.search(r'"effectStackHandle":\s*"(obj_\d+)"', props)
        self.placeholders["$EFFECT_STACK"] = m.group(1) if m else ""

        # A source clip, not a project: browser_list_clips marks projects with
        # isProject true, and the place/append tools rightly refuse one.
        browser = await self.call("browser_list_clips", {})
        source = ""
        for block in re.findall(r"\{[^{}]*\}", browser, re.S):
            if '"isProject": false' in block:
                h = re.search(r'"handle":\s*"(obj_\d+)"', block)
                if h:
                    source = h.group(1)
                    break
        if not source:
            m = re.search(r"(obj_\d+)", browser)
            source = m.group(1) if m else ""
        self.placeholders["$BROWSER_CLIP"] = source

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

        # import_url wants a URL. Serving the scratch directory keeps the sweep off the
        # network and still exercises the whole download-and-import path.
        self.placeholders["$PROBE_URL"] = f"{self.serve()}/{probe.name}"

        browser_json = await self.call("browser_list_clips", {})
        m = re.search(r'"event":\s*"([^"]+)"', browser_json)
        self.placeholders["$EVENT_NAME"] = m.group(1) if m else ""

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

        optional = {"$BRIDGE_VALUE_OPTION", "$BRIDGE_VALUE_CURRENT", "$MONTAGE_CLIPS"}
        missing = [k for k, v in self.placeholders.items() if not v and k not in optional]
        if missing:
            raise SystemExit(f"could not resolve {missing} from the live timeline; "
                             "is the QA project open with a connected clip?")

    def fill(self, value):
        """Substitute placeholders anywhere in an argument, including inside lists
        and dicts — mixer_set_all_volumes takes a list of {handle, volumeDB}."""
        if isinstance(value, str):
            for name, resolved in self.placeholders.items():
                value = value.replace(name, resolved)
            return value
        if isinstance(value, dict):
            return {k: self.fill(v) for k, v in value.items()}
        if isinstance(value, list):
            return [self.fill(v) for v in value]
        return value

    # -- one case ----------------------------------------------------------

    async def run_case(self, tool: str, case: Case) -> Result:
        started = time.monotonic()
        if case.kind == "skip":
            return Result(tool, SKIPPED, case.reason)

        if case.select_before:
            await self.call("select_clips",
                            {"handles": self.fill(case.select_before)})

        args = self.fill(case.args)
        before = await self.shape()

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

        if errored and not (case.expect and re.search(case.expect, out)):
            return Result(tool, FAIL, snippet, elapsed)
        if case.expect and not re.search(case.expect, out):
            return Result(tool, FAIL,
                          f"answer did not match /{case.expect}/: {snippet}", elapsed)

        # Put the project back.
        restored = await self.restore(case, before)
        if restored:
            return Result(tool, FAIL, f"{snippet} | {restored}", elapsed)
        return Result(tool, PASS, snippet, elapsed)

    async def restore(self, case: Case, before: tuple) -> str:
        """Undo or clean up after a case. Returns "" when the timeline is back."""
        for tool, args in case.cleanup:
            try:
                await self.call(tool, self.fill(args), case.timeout)
            except Exception as exc:
                return f"cleanup {tool} raised {type(exc).__name__}: {exc}"[:200]

        if case.undo:
            wanted = (case.undo,) if isinstance(case.undo, str) else tuple(case.undo)
            name = await self.undo_name()
            if name in wanted:
                await self.call("history_action", {"action": "undo"})
            elif await self.shape() != before:
                return (f"the timeline changed but the undo stack says {name!r}, "
                        f"expected one of {wanted} — the change cannot be taken back")
            # Otherwise the tool decided there was nothing to do (no scene changes
            # found, no clip matched) and correctly made no edit. That is a pass, not
            # a missing undo step.

        after = await self.shape()
        if after != before:
            return f"timeline not restored: {before} -> {after}"
        return ""

    # -- the whole run -----------------------------------------------------

    async def run(self, tool_names: list[str]) -> int:
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
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
