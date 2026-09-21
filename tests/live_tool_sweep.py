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
import sys
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


def read(expect: str | None = None, **args) -> Case:
    return Case(args=args, kind="read", expect=expect)


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
    "manage_handles": read(action="list"),
    "inspect_handle": Case(args={"handle": "$CONNECTED_CLIP"}, kind="read"),
    "get_object_property": Case(args={"handle": "$CONNECTED_CLIP", "key": "displayName"},
                                kind="read"),
    "detect_dialog": read(),
    "background_render_status": read(),
    "get_caption_state": read(),
    "get_caption_styles": read(),
    "verify_captions": read(),
    "verify_native_captions": read(),
    "get_sections": read(),
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
    "playback_action": write(action="pause"),
    "set_playback_speed": write(rate=1.0),
    "set_viewer_zoom": write(zoom=1.0, cleanup=[("set_viewer_zoom", {"zoom": 0})]),
    "select_clips": Case(args={"handles": "$CONNECTED_CLIP"}, kind="write"),
    "select_clip_in_lane": write(lane=1),
    "select_tool": write(tool="select"),
    "timeline_navigation_action": write(action="selectAll",
                                        cleanup=[("timeline_navigation_action",
                                                  {"action": "deselectAll"})]),
    "set_bridge_option": write(option="verboseLogging", enabled=False),
    "set_bridge_option_value": write(option="captionStylePreset", value="social"),
    "set_silence_threshold": write(threshold=-50.0),
    "set_transcript_engine": write(engine="parakeetV3"),

    # ---------------------------------------------------------------- timeline writes
    "add_markers_at_times": write(markers="5.0, 10.0", undo="Add Markers"),
    "blade_at_times": write(times="5.0", undo=("Blade", "Blade Clips")),
    "timeline_edit_action": write(action="addMarker", undo=("Add Marker", "Marker")),
    "timeline_action": write(action="addMarker", undo=("Add Marker", "Marker")),
    "timeline_destructive_action": write(action="blade", undo=("Blade", "Blade Clips")),
    "direct_timeline_action": write(action="addMarker", name="sweep",
                                    undo=("Add Marker", "Marker")),
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
    "apply_transition_to_all_clips": write(undo=("Add Transition", "Cross Dissolve")),
    "batch_apply_effect": write(name="Black & White", clip_count=2,
                                undo=("Batch Apply Effect", "Add Effect")),
    "batch_color_correct": write(correction="addColorBoard", clip_count=2,
                                 undo=("Batch Color Correct", "Add Color Board Effect")),
    "insert_title": write(name="Basic Title",
                          undo=("Insert Title", "Connect Title", "Add Basic Title")),
    "set_inspector_property": write(property="positionX", value=25,
                                    undo="Set positionX"),
    "set_object_property": skip("arbitrary KVC write on a live model object"),
    "assign_role": write(type="video", role="Video"),
    "stabilize_subject": Case(args={}, kind="write", undo="Stabilize Subject", timeout=600),
    "import_srt_as_markers": write(
        srt_content="1\n00:00:05,000 --> 00:00:06,000\nsweep\n",
        undo=("Add Marker", "Add Markers", "Marker")),
    "add_clip_to_timeline": Case(args={"handle": "$BROWSER_CLIP", "edit": "append",
                                       "dry_run": True}, kind="read"),
    "browser_append_clip": Case(args={"handle": "$BROWSER_CLIP"}, kind="skip",
                                reason="appends to the browser, not undoable as one step"),

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
    "dual_timeline_open_selected_in_secondary": write(
        cleanup=[("dual_timeline_close", {})]),
    "dual_timeline_toggle_panel": write(panel="index", pane="secondary",
                                        cleanup=[("dual_timeline_toggle_panel",
                                                  {"panel": "index",
                                                   "pane": "secondary"})]),
    "toggle_structure_blocks": write(cleanup=[("toggle_structure_blocks", {})]),
    "hide_sections": write(),
    "open_livecam": write(cleanup=[("close_livecam", {})]),
    "close_livecam": write(),
    "get_livecam_status": read(),
    "capture_viewer": Case(args={"path": "$TMP/viewer.png", "return_image": False},
                           kind="read"),
    "capture_timeline": Case(args={"path": "$TMP/timeline.png", "return_image": False},
                             kind="read"),
    "capture_inspector": Case(args={"path": "$TMP/inspector.png", "return_image": False},
                              kind="read"),

    # ---------------------------------------------------------------- render / export
    "background_render_control": write(action="pause", seconds=5),
    "export_xml": Case(args={"path": "$TMP/sweep.fcpxml"}, kind="write",
                       expect=r"fcpxml|Exported", timeout=120),
    "export_otio": Case(args={"path": "$TMP/sweep.otio"}, kind="write", timeout=120),
    "import_otio": Case(args={"path": "$TMP/sweep.otio"}, kind="skip",
                        reason="creates a project; covered by cleanup_temp_projects"),
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
    "delete_transcript_words": skip("needs a transcript with known word indices"),
    "move_transcript_words": skip("needs a transcript with known word indices"),
    "set_transcript_speaker": skip("needs a transcript with known word indices"),
    "delete_transcript_silences": skip("removes timeline content based on transcription"),

    # ---------------------------------------------------------------- captions
    "open_captions": write(cleanup=[("close_captions", {})]),
    "close_captions": write(),
    "set_caption_style": write(preset_id="social"),
    "set_caption_grouping": write(mode="social", max_words=3),
    "set_caption_words": skip("needs generated captions with known word indices"),
    "generate_captions": Case(args={}, kind="write", timeout=300,
                              cleanup=[("cleanup_temp_projects", {})]),
    "generate_native_captions": Case(args={}, kind="write", timeout=300,
                                     cleanup=[("cleanup_temp_projects", {})]),
    "cleanup_temp_projects": read(dry_run=True),

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
    "trim_clips_to_beats": Case(args={"dry_run": True}, kind="read", timeout=120),
    "sync_clips_to_song_beats": Case(args={"dry_run": True}, kind="read", timeout=120),
    "build_song_cut": Case(args={"dry_run": True}, kind="read", timeout=180),
    "assemble_random_clips_to_song_beats": Case(args={"dry_run": True}, kind="read",
                                                timeout=180),

    # ---------------------------------------------------------------- montage
    "montage_analyze_clips": Case(args={}, kind="read", timeout=300),
    "montage_plan_edit": read(beats="[0.0, 1.0, 2.0]", clips="[]"),
    "montage_assemble": skip("builds a whole project; covered by montage_auto"),
    "montage_auto": skip("builds a whole project from a song library that is absent"),

    # ---------------------------------------------------------------- mixer
    "mixer_set_volume": Case(args={"handle": "$EFFECT_STACK", "volume_db": 0.0},
                             kind="write"),
    "mixer_set_mute": write(index=0, muted=False),
    "mixer_set_solo": write(index=0, solo=False),
    "mixer_set_all_volumes": write(volumes=[]),
    "mixer_volume_begin": Case(args={"effect_stack_handle": "$EFFECT_STACK"},
                               kind="write",
                               cleanup=[("mixer_volume_end",
                                         {"effect_stack_handle": "$EFFECT_STACK"})]),
    "mixer_volume_end": skip("closes the scope mixer_volume_begin opens"),
    "mixer_apply_bus_effect": Case(args={"name": "Channel EQ", "index": 0,
                                         "dry_run": True}, kind="read"),
    "mixer_open_bus_effect": skip("opens a plugin window a person has to close"),
    "mixer_set_bus_effect_enabled": skip("needs a bus effect applied first"),
    "mixer_remove_bus_effect": skip("needs a bus effect applied first"),

    # ---------------------------------------------------------------- lua / plugins
    "lua_execute": read(code="return 1 + 1"),
    "lua_execute_file": skip("needs a script on disk; lua_execute covers the engine"),
    "lua_reset": write(),
    "reload_plugin_tools": read(),

    # ---------------------------------------------------------------- debug config
    "debug_set_config": write(key="verbose", value="false"),
    "debug_reset_config": write(scope="all"),
    "debug_enable_preset": write(preset="off"),
    "debug_start_framerate_monitor": write(interval=2.0,
                                           cleanup=[("debug_stop_framerate_monitor", {})]),
    "debug_stop_framerate_monitor": write(),

    # ---------------------------------------------------------------- AI
    "ai_command": Case(args={"query": "how many clips are on the timeline?"},
                       kind="write", timeout=400),
    "ai_command_gemma": dependency("MLX", "mlx", "model", "server", "not running",
                                   timeout=400,
                                   query="how many clips are on the timeline?"),
    "execute_command": read(action="blade", type="timeline"),
    "execute_menu_command": read(menu_path=["Edit"], dry_run=True),

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
    "import_media": skip("adds media to the library; needs a file outside the bundle"),
    "import_fcpxml": skip("creates a project from XML"),
    "paste_fcpxml": skip("pastes into the open timeline from the pasteboard"),
    "import_url": skip("downloads from the network"),
    "import_url_status": Case(args={"job_id": "no-such-job"}, kind="read",
                              expect=r"[Nn]ot found|[Nn]o such|[Uu]nknown"),
    "cancel_import_url": Case(args={"job_id": "no-such-job"}, kind="read",
                              expect=r"[Nn]ot found|[Nn]o such|[Uu]nknown"),

    # ---------------------------------------------------------------- handles
    "release_handle": skip("would invalidate handles the sweep is still using"),
    "release_all_handles": skip("would invalidate handles the sweep is still using"),

    # ---------------------------------------------------------------- modal panels
    "create_project": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "create_event": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "create_library": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "share_project": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "batch_export": modal(cleanup=[("dismiss_dialog", {"action": "cancel"})]),
    "open_project": Case(args={"name": EXPECTED_PROJECT}, kind="write",
                         invalidates_handles=True),
    "set_timeline_range": write(start_seconds=1.0, end_seconds=2.0),

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
    "visionpro_status": read(),
    "visionpro_list_clients": read(),
    "visionpro_open_panel": write(cleanup=[("visionpro_close_panel", {})]),
    "visionpro_close_panel": write(),
    "visionpro_start": dependency("ImmersiveVideoToolbox", "not available",
                                  "unavailable", "failed"),
    "visionpro_stop": dependency("ImmersiveVideoToolbox", "not available",
                                 "unavailable", "not running"),
    "visionpro_connect": dependency("no client", "not found", "unavailable",
                                    "ImmersiveVideoToolbox", host="127.0.0.1"),
    "visionpro_disconnect": dependency("no client", "not found", "unavailable",
                                       "ImmersiveVideoToolbox", host="127.0.0.1"),
    "visionpro_load_aime": dependency("not found", "no such file", "unavailable",
                                      path="/tmp/none.aime"),
    "visionpro_send_aime": dependency("no client", "not found", "unavailable",
                                      path="/tmp/none.aime"),
    "visionpro_export_aime": dependency("unavailable", "no session", "failed",
                                        path="/tmp/sweep.aime"),
    "visionpro_set_camera": dependency("not found", "unavailable", "no session",
                                       camera_id="none"),
    "visionpro_set_camera_calibration": dependency("not found", "unavailable",
                                                   "provide one of", "no session",
                                                   camera_id="none"),
    "visionpro_remove_camera": dependency("not found", "unavailable", "no session",
                                          camera_id="none"),
    "visionpro_send_mask": dependency("no client", "not found", "unavailable",
                                      path="/tmp/none.usdz"),
    "visionpro_set_max_clients": write(max=2),

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

        browser = await self.call("browser_list_clips", {})
        m = re.search(r"(obj_\d+)", browser)
        self.placeholders["$BROWSER_CLIP"] = m.group(1) if m else ""

        self.placeholders["$TMP"] = str(self.tmp)

        missing = [k for k, v in self.placeholders.items() if not v]
        if missing:
            raise SystemExit(f"could not resolve {missing} from the live timeline; "
                             "is the QA project open with a connected clip?")

    def fill(self, args: dict) -> dict:
        out = {}
        for k, v in args.items():
            if isinstance(v, str):
                for name, value in self.placeholders.items():
                    v = v.replace(name, value)
            out[k] = v
        return out

    # -- one case ----------------------------------------------------------

    async def run_case(self, tool: str, case: Case) -> Result:
        started = time.monotonic()
        if case.kind == "skip":
            return Result(tool, SKIPPED, case.reason)

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
            if name not in wanted:
                return (f"nothing to undo: the undo stack says {name!r}, "
                        f"expected one of {wanted}")
            await self.call("history_action", {"action": "undo"})

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
                await self.resolve_placeholders()
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
