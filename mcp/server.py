#!/usr/bin/env python3
"""
SpliceKit MCP Server — the bridge between AI tools and Final Cut Pro.

This is the MCP (Model Context Protocol) server that Claude and other AI tools
talk to. It exposes FCP's entire editing API as MCP tools. Under the hood, each
tool just sends a JSON-RPC request to the SpliceKit dylib running inside FCP's
process (127.0.0.1:9876) and returns the result.

The tools are intentionally verbose in their docstrings because that's what the
AI model sees when deciding which tool to use and how to call it.
"""

import socket
import json
import sys
import inspect
import time
import functools
import base64
import os
import struct
import zlib
import atexit
import logging
import threading

# The official MCP Python SDK, major version 2 (mcp>=2.2,<3 in mcp/requirements.txt).
# v2 renamed FastMCP to MCPServer and moved it to mcp.server.mcpserver; the old
# mcp.server.fastmcp path no longer exists. The messages below tell apart "mcp is
# not installed" from "an mcp 1.x is installed", because both raise the same
# ModuleNotFoundError and the fix is the same command either way.
try:
    from mcp.server.mcpserver import MCPServer
except ModuleNotFoundError as exc:
    if exc.name and exc.name.split(".")[0] == "mcp":
        import importlib.metadata
        try:
            installed = importlib.metadata.version("mcp")
        except importlib.metadata.PackageNotFoundError:
            installed = None
        if installed is None:
            problem = f"The `mcp` Python package is not installed for this interpreter ({sys.executable})."
        else:
            problem = (
                f"This interpreter ({sys.executable}) has mcp {installed}; SpliceKit's server "
                "needs the 2.x line of the official SDK (mcp>=2.2,<3)."
            )
        sys.stderr.write(
            f"\n[splicekit-mcp] {problem}\n"
            "Set up (or upgrade) the recommended virtualenv and re-launch your MCP client:\n\n"
            "    make mcp-setup\n\n"
            "Or manually:\n"
            "    python3 -m venv ~/.venvs/splicekit-mcp\n"
            "    ~/.venvs/splicekit-mcp/bin/python -m pip install --upgrade -r mcp/requirements.txt\n"
            "Then point your MCP config `command` at "
            "~/.venvs/splicekit-mcp/bin/python.\n\n"
        )
        sys.exit(1)
    raise

# ToolAnnotations carries the read-only / destructive / idempotent / open-world hints
# every tool below publishes. v2 spells the fields snake_case in Python and serializes
# them camelCase on the wire, so construct the model instead of passing a dict.
from mcp.types import ToolAnnotations
# ToolError is the v2 SDK's "this tool failed, tell the client why" exception: its message
# is forwarded to the client with isError=true. Any other exception escaping a tool is
# reported to the client only as "Error executing tool <name>" (the detail stays in the
# server log), which is useless to an AI that has to decide what to do next.
from mcp.server.mcpserver.exceptions import ToolError

# The SDK's Image helper turns bytes or a file into MCP image content, so a tool can
# hand a frame or a screenshot to any MCP client inline. It only exists in the real
# package (the offline tests load this module with a fake MCPServer); without it the
# tools return text and point at the file / base64 instead.
try:
    from mcp.server.mcpserver import Image
except Exception:  # pragma: no cover - exercised by the offline tests
    Image = None


def _image_content(path=None, data=None, fmt=None):
    """MCP image content (the SDK's Image helper) for a local file or raw bytes, or None
    when an image cannot be returned: no Image class, the file does not exist, or empty
    data. Tools that return images carry NO return annotation on purpose: the SDK emits
    mixed text + image content only for unannotated tools (a `-> str` tool returning a
    list fails output validation)."""
    if Image is None:
        return None
    try:
        if data:
            return Image(data=data, format=(fmt or "jpeg"))
        if path and os.path.isfile(path):
            return Image(path=path)
    except Exception:
        return None
    return None


def _maybe_with_image(text, image):
    """[text, image] when an image is available, otherwise just the text."""
    return [text, image] if image is not None else text


def _decode_base64_image(b64):
    """Bytes for a base64 image string from the bridge; b'' when it is missing or invalid."""
    if not b64 or not isinstance(b64, str):
        return b""
    try:
        return base64.b64decode(b64)
    except Exception:
        return b""


# Where the bridge inside Final Cut Pro listens. The environment overrides exist for
# the test harness (tests/mcp_server_check.py points the server at a fake bridge);
# a normal install never sets them. The bridge speaks plaintext JSON-RPC and this
# server forwards clip names, transcript text and file paths to it, so a host other
# than loopback is refused unless SPLICEKIT_ALLOW_REMOTE=1 says that is intended.
_LOG = logging.getLogger("splicekit-mcp")


def _bridge_address() -> tuple:
    host = os.environ.get("SPLICEKIT_HOST") or "127.0.0.1"
    try:
        port = int(os.environ.get("SPLICEKIT_PORT") or 9876)
    except ValueError:
        sys.stderr.write(f"[splicekit-mcp] ignoring SPLICEKIT_PORT={os.environ.get('SPLICEKIT_PORT')!r}; using 9876\n")
        port = 9876
    if host not in ("127.0.0.1", "localhost", "::1") and os.environ.get("SPLICEKIT_ALLOW_REMOTE") != "1":
        sys.stderr.write(f"[splicekit-mcp] ignoring SPLICEKIT_HOST={host!r} (not loopback; set "
                         "SPLICEKIT_ALLOW_REMOTE=1 if that is really intended); using 127.0.0.1\n")
        host = "127.0.0.1"
    if (host, port) != ("127.0.0.1", 9876):
        sys.stderr.write(f"[splicekit-mcp] bridge address overridden by environment: {host}:{port}\n")
    return host, port


SPLICEKIT_HOST, SPLICEKIT_PORT = _bridge_address()


def _splicekit_version() -> str:
    """SpliceKit's version string (patcher/SpliceKit/Configuration/Version.xcconfig), or ""
    when the file is not beside this checkout. Reported to MCP clients as the server version."""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "patcher",
                            "SpliceKit", "Configuration", "Version.xcconfig")
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.partition("=")
                if sep and key.strip() == "SPLICEKIT_VERSION":
                    return value.strip()
    except OSError:
        pass
    return ""


SPLICEKIT_VERSION = _splicekit_version()

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
  as rendered in the Viewer, effects included; moves the playhead and restores it). Captures are
  in-process from FCP's views; a one-colour content region comes back with flat:true and a WARNING.
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
  open_transcript, get_transcript, search_transcript, delete_transcript_words,
  move_transcript_words, delete_transcript_silences, set_transcript_speaker,
  set_silence_threshold. Captions: open_captions, set_caption_style, set_caption_grouping,
  generate_captions, verify_captions, generate_native_captions, remove_captions,
  cleanup_temp_projects.
UNDO / GROUPING: history_action("undo" | "redo"). begin_edit("Rough cut") ... end_edit() makes
  everything in between ONE undo step (Flexo's internal term: one undoable action) -- always
  call end_edit.
SCENES, BEATS, WHOLE EDITS: detect_scene_changes() lists the cuts (read-only), then
  blade_scene_changes() / mark_scene_changes(); detect_beats(file), beat_sync_blade,
  trim_clips_to_beats; import_srt_as_markers; generate_fcpxml + import_fcpxml (a project from
  XML); build_song_cut / assemble_random_clips_to_song_beats (beat-synced cuts).
EXPORT / EXCHANGE: export_xml, export_otio / import_otio (.otio, .fcpxml, .edl, .aaf),
  share_project, batch_export, export_captions_srt / export_captions_txt.
PROJECTS / LIBRARY / BROWSER: open_project, create_project, create_event, create_library,
  get_active_libraries, browser_list_clips, import_media, dual_timeline_* (a second timeline
  window).
FCP'S UI: execute_menu_command(["Modify", "Balance Color"]), list_menus, toggle_panel,
  set_workspace, select_tool, get_viewer_zoom / set_viewer_zoom, detect_dialog then
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


# Tool annotation hint sets (MCP ToolAnnotations, snake_case as the v2 SDK spells them;
# they reach the client as readOnlyHint / destructiveHint / idempotentHint / openWorldHint).
# open_world_hint is False everywhere: every tool talks to the one Final Cut Pro on this Mac.
READ_ONLY = {
    "read_only_hint": True,
    "destructive_hint": False,
    "idempotent_hint": True,
    "open_world_hint": False,
}

LOCAL_WRITE = {
    "read_only_hint": False,
    "destructive_hint": False,
    "idempotent_hint": False,
    "open_world_hint": False,
}

DESTRUCTIVE_LOCAL_WRITE = {
    "read_only_hint": False,
    "destructive_hint": True,
    "idempotent_hint": False,
    "open_world_hint": False,
}

READ_ONLY_TOOLS = {
    "bridge_status",
    "background_render_status",
    "dual_timeline_status",
    "get_timeline_clips",
    "list_markers",
    "get_selected_clips",
    "verify_action",
    "get_object_property",
    "generate_fcpxml",
    "get_clip_effects",
    "get_clip_info",
    "get_audio_levels",
    "analyze_timeline",
    "get_active_libraries",
    "is_library_updating",
    "get_classes",
    "get_methods",
    "get_properties",
    "get_ivars",
    "get_protocols",
    "get_superchain",
    "explore_class",
    "search_methods",
    "get_transcript",
    "search_transcript",
    "list_effects",
    "list_transitions",
    "search_commands",
    "livecam_status",
    "list_menus",
    "get_inspector_properties",
    "get_title_text",
    "verify_captions",
    "get_playhead_position",
    "detect_dialog",
    "get_viewer_zoom",
    "get_bridge_options",
    "detect_scene_changes",
    "detect_beats",
    "analyze_song_structure",
    "sections_get",
    "flexmusic_list_songs",
    "flexmusic_get_song",
    "flexmusic_get_timing",
    "montage_analyze_clips",
    "montage_plan_edit",
    "debug_get_config",
    "dump_runtime_metadata",
    "list_loaded_images",
    "get_image_sections",
    "get_image_symbols",
    "get_notification_names",
    "debug_threads",
    "debug_eval",
    "browser_list_clips",
    "get_caption_state",
    "get_caption_styles",
    "verify_native_captions",
    "list_handles",
    "inspect_handle",
    "plugin_list",
    "plugin_list_methods",
    "reload_plugin_tools",
    "mixer_get_state",
    "import_url_status",
    "bridge_alive",
    "bridge_describe",
    "bridge_safety_tags",
    "events_subscribe",
    "events_unsubscribe",
    "events_status",
    "async_status",
    "capture_inspector",
    "capture_timeline",
    "capture_viewer",
    "lua_state",
}

DESTRUCTIVE_TOOLS = {
    "timeline_action",
    "timeline_destructive_action",
    "history_action",
    "batch_export",
    "call_method",
    "call_method_with_args",
    "set_object_property",
    "import_fcpxml",
    "import_otio",
    "remove_browser_clip",
    "batch_timeline_actions",
    "delete_transcript_words",
    "move_transcript_words",
    "delete_transcript_silences",
    "blade_at_times",
    "trim_clip",
    "trim_clips_to_beats",
    "sync_clips_to_song_beats",
    "assemble_random_clips_to_song_beats",
    "build_song_cut",
    "apply_effect",
    "apply_transition",
    "apply_transition_to_all_clips",
    "batch_apply_effect",
    "batch_color_correct",
    "execute_command",
    "ai_command",
    "execute_menu_command",
    "set_inspector_property",
    "share_project",
    "create_project",
    "create_event",
    "create_library",
    "click_dialog_button",
    "fill_dialog_field",
    "toggle_dialog_checkbox",
    "select_dialog_popup",
    "dismiss_dialog",
    "flexmusic_render_to_file",
    "flexmusic_add_to_timeline",
    "montage_assemble",
    "montage_auto",
    "debug_set_config",
    "debug_reset_config",
    "debug_enable_preset",
    "debug_load_plugin",
    "direct_timeline_action",
    "browser_append_clip",
    "add_clip_to_timeline",
    "import_media",
    "paste_fcpxml",
    "stabilize_subject",
    "insert_title",
    "generate_captions",
    "export_captions_srt",
    "export_captions_txt",
    "generate_native_captions",
    "remove_captions",
    "cleanup_temp_projects",
    "blade_scene_changes",
    "beat_sync_blade",
    "song_structure_blocks",
    "song_structure_sections",
    "remove_structure_blocks",
    # Write to a caller-supplied path and overwrite whatever is there, with no existence
    # check and no dry run — the same disk-write risk export_captions_srt/txt are marked for.
    "export_xml",
    "export_otio",
    # Deletes the structure storyline whenever one is on the timeline: same code path as
    # remove_structure_blocks. It was READ_ONLY and idempotent, which invited an agent to
    # call it speculatively and silently lose the blocks.
    "toggle_structure_blocks",
    "sections_hide",
    "ai_command_gemma",
    "deploy_and_restart",
    "lua_execute",
    "lua_execute_file",
    "lua_reset",
    "lua_watch",
    "raw_call",
    "mixer_set_volume",
    "mixer_set_all_volumes",
    "mixer_apply_bus_effect",
    "mixer_set_bus_effect_enabled",
    "mixer_remove_bus_effect",
    "import_url",
    "cancel_import_url",
}

LOCAL_WRITE_TOOLS = {
    "add_markers_at_times",
    "assign_role",
    "background_render_control",
    "begin_edit",
    "capture_clip_frame",
    "close_captions",
    "close_transcript",
    "debug_breakpoint",
    "debug_crash_handler",
    "debug_observe_notification",
    "debug_start_framerate_monitor",
    "debug_stop_framerate_monitor",
    "debug_trace_method",
    "debug_watch",
    "dual_timeline_close",
    "dual_timeline_focus",
    "dual_timeline_open",
    "dual_timeline_open_selected_in_secondary",
    "dual_timeline_sync_root",
    "dual_timeline_toggle_panel",
    "end_edit",
    "hide_command_palette",
    "import_srt_as_markers",
    "livecam_close",
    "livecam_open",
    "mark_scene_changes",
    "mixer_open_bus_effect",
    "mixer_set_mute",
    "mixer_set_solo",
    "mixer_volume_begin",
    "mixer_volume_end",
    "open_captions",
    "open_project",
    "open_transcript",
    "playback_action",
    "release_all_handles",
    "release_handle",
    "seek_to_time",
    "select_clip_in_lane",
    "select_clips",
    "select_tool",
    "set_bridge_option",
    "set_bridge_option_value",
    "set_caption_grouping",
    "set_caption_style",
    "set_caption_words",
    "set_playback_speed",
    "set_silence_threshold",
    "set_timeline_range",
    "set_transcript_engine",
    "set_transcript_speaker",
    "set_viewer_zoom",
    "set_workspace",
    "show_command_palette",
    "timeline_edit_action",
    "timeline_navigation_action",
    "toggle_panel",
}

IDEMPOTENT_LOCAL_WRITE_TOOLS = {
    "assign_role",
    "capture_clip_frame",
    "close_captions",
    "close_transcript",
    "end_edit",
    "hide_command_palette",
    "livecam_close",
    "livecam_open",
    "mixer_volume_begin",
    "mixer_volume_end",
    "open_project",
    "seek_to_time",
    "select_clip_in_lane",
    "select_clips",
    "select_tool",
    "set_bridge_option",
    "set_bridge_option_value",
    "set_silence_threshold",
    "set_timeline_range",
    "set_transcript_engine",
    "set_viewer_zoom",
    "set_workspace",
}

CUSTOM_TOOL_TITLES = {
    "bridge_status": "Bridge Status",
    "background_render_status": "Background Render Status",
    "background_render_control": "Background Render Control",
    "get_timeline_clips": "Get Timeline Clips",
    "list_markers": "List Markers",
    "get_selected_clips": "Get Selected Clips",
    "set_timeline_range": "Set Timeline Range",
    "batch_export": "Batch Export Clips",
    "verify_action": "Verify Timeline Action",
    "call_method_with_args": "Call Method With Args",
    "list_handles": "List Object Handles",
    "inspect_handle": "Inspect Object Handle",
    "release_handle": "Release Object Handle",
    "release_all_handles": "Release All Handles",
    "get_object_property": "Get Object Property",
    "set_object_property": "Set Object Property",
    "import_fcpxml": "Import FCPXML",
    "generate_fcpxml": "Generate FCPXML",
    "batch_timeline_actions": "Batch Timeline Actions",
    "import_srt_as_markers": "Import SRT As Markers",
    "blade_at_times": "Blade At Times",
    "trim_clips_to_beats": "Trim Clips To Beats",
    "sync_clips_to_song_beats": "Sync Clips To Song Beats",
    "assemble_random_clips_to_song_beats": "Assemble Random Clips To Song Beats",
    "build_song_cut": "Build Song Cut",
    "open_project": "Open Project",
    "select_clip_in_lane": "Select Clip In Lane",
    "select_clips": "Select Clips",
    "begin_edit": "Begin Undo Step",
    "end_edit": "End Undo Step",
    "trim_clip": "Trim Clip",
    "get_clip_info": "Get Clip Info",
    "capture_clip_frame": "Capture Clip Frame",
    "capture_viewer": "Capture Viewer",
    "capture_timeline": "Capture Timeline",
    "capture_inspector": "Capture Inspector",
    "export_xml": "Export FCPXML",
    "export_otio": "Export OpenTimelineIO",
    "import_otio": "Import OpenTimelineIO",
    "is_library_updating": "Check Library Updating",
    "search_methods": "Search Methods",
    "raw_call": "Raw JSON-RPC Call",
    "ai_command_gemma": "AI Command Gemma",
    "delete_transcript_words": "Delete Transcript Words",
    "move_transcript_words": "Move Transcript Words",
    "close_transcript": "Close Transcript Panel",
    "search_transcript": "Search Transcript",
    "livecam_open": "Open LiveCam",
    "livecam_close": "Close LiveCam",
    "livecam_status": "Get LiveCam Status",
    "delete_transcript_silences": "Delete Transcript Silences",
    "set_silence_threshold": "Set Silence Threshold",
    "show_command_palette": "Show Command Palette",
    "hide_command_palette": "Hide Command Palette",
    "ai_command": "AI Command",
    "execute_menu_command": "Execute Menu Command",
    "get_inspector_properties": "Get Inspector Properties",
    "set_inspector_property": "Set Inspector Property",
    "get_title_text": "Get Title Text",
    "toggle_panel": "Toggle Panel",
    "get_playhead_position": "Get Playhead Position",
    "detect_dialog": "Detect Dialog",
    "click_dialog_button": "Click Dialog Button",
    "fill_dialog_field": "Fill Dialog Field",
    "toggle_dialog_checkbox": "Toggle Dialog Checkbox",
    "select_dialog_popup": "Select Dialog Popup",
    "dismiss_dialog": "Dismiss Dialog",
    "get_viewer_zoom": "Get Viewer Zoom",
    "set_viewer_zoom": "Set Viewer Zoom",
    "get_bridge_options": "Get Bridge Options",
    "set_bridge_option": "Set Bridge Option",
    "set_bridge_option_value": "Set Bridge Option Value",
    "apply_transition_to_all_clips": "Apply Transition To All Clips",
    "batch_apply_effect": "Batch Apply Effect",
    "batch_color_correct": "Batch Color Correct",
    "detect_beats": "Detect Beats",
    "analyze_song_structure": "Analyze Song Structure",
    "beat_sync_blade": "Beat Sync Blade",
    "song_structure_blocks": "Song Structure Blocks",
    "song_structure_sections": "Song Structure Sections",
    "toggle_structure_blocks": "Remove Structure Blocks (Toggle)",
    "remove_structure_blocks": "Remove Structure Blocks",
    "sections_get": "Get Sections",
    "sections_hide": "Hide Sections",
    "flexmusic_list_songs": "List FlexMusic Songs",
    "flexmusic_get_song": "Get FlexMusic Song",
    "flexmusic_get_timing": "Get FlexMusic Timing",
    "flexmusic_render_to_file": "Render FlexMusic To File",
    "flexmusic_add_to_timeline": "Add FlexMusic To Timeline",
    "montage_analyze_clips": "Analyze Montage Clips",
    "montage_plan_edit": "Plan Montage Edit",
    "montage_assemble": "Assemble Montage",
    "montage_auto": "Auto Montage",
    "debug_get_config": "Get Debug Config",
    "debug_set_config": "Set Debug Config",
    "debug_reset_config": "Reset Debug Config",
    "debug_enable_preset": "Enable Debug Preset",
    "debug_start_framerate_monitor": "Start Framerate Monitor",
    "debug_stop_framerate_monitor": "Stop Framerate Monitor",
    "dump_runtime_metadata": "Dump Runtime Metadata",
    "list_loaded_images": "List Loaded Images",
    "get_image_sections": "Get Image Sections",
    "get_image_symbols": "Get Image Symbols",
    "get_notification_names": "Get Notification Names",
    "debug_trace_method": "Trace Method",
    "debug_watch": "Watch Property Changes",
    "debug_crash_handler": "Crash Handler",
    "debug_eval": "Evaluate Debug Expression",
    "debug_load_plugin": "Load Debug Plugin",
    "debug_observe_notification": "Observe Notifications",
    "direct_timeline_action": "Direct Timeline Action",
    "browser_list_clips": "List Browser Clips",
    "browser_append_clip": "Append Browser Clip",
    "add_clip_to_timeline": "Add Clip To Timeline",
    "import_media": "Import Media Files",
    "remove_browser_clip": "Remove Browser Clip",
    "paste_fcpxml": "Paste FCPXML",
    "stabilize_subject": "Stabilize Subject",
    "insert_title": "Insert Title",
    "set_transcript_engine": "Set Transcript Engine",
    "import_url": "Import Media URL",
    "import_url_status": "URL Import Status",
    "cancel_import_url": "Cancel URL Import",
    "open_captions": "Open Captions Panel",
    "close_captions": "Close Captions Panel",
    "get_caption_state": "Get Caption State",
    "get_caption_styles": "Get Caption Styles",
    "set_caption_style": "Set Caption Style",
    "set_caption_grouping": "Set Caption Grouping",
    "generate_captions": "Generate Captions",
    "export_captions_srt": "Export Captions SRT",
    "export_captions_txt": "Export Captions Text",
    "set_caption_words": "Set Caption Words",
    "generate_native_captions": "Generate Native Captions",
    "remove_captions": "Remove Captions",
    "cleanup_temp_projects": "Cleanup Temp Import Projects",
    "verify_native_captions": "Verify Native Captions",
    "mark_scene_changes": "Mark Scene Changes",
    "blade_scene_changes": "Blade Scene Changes",
    "timeline_navigation_action": "Timeline Navigation Action",
    "timeline_edit_action": "Timeline Edit Action",
    "timeline_destructive_action": "Timeline Destructive Action",
    "history_action": "Timeline History Action",
    "deploy_and_restart": "Deploy And Restart FCP",
    "lua_execute": "Execute Lua Code",
    "lua_execute_file": "Execute Lua File",
    "lua_reset": "Reset Lua VM",
    "lua_watch": "Watch Lua Files",
    "lua_state": "Get Lua State",
}

TIMELINE_NAVIGATION_ACTIONS = {
    "nextEdit", "previousEdit", "nextMarker", "previousMarker",
    "nextKeyframe", "previousKeyframe",
    "selectClipAtPlayhead", "selectToPlayhead", "selectAll", "deselectAll",
    "showVideoAnimation", "showAudioAnimation", "soloAnimation",
    "showTrackingEditor", "showCinematicEditor", "showMagneticMaskEditor",
    "enableBeatDetection",
    "showPrecisionEditor", "showAudioLanes", "expandSubroles",
    "showDuplicateRanges", "showKeywordEditor", "togglePrecisionEditor",
    "toggleSnapping", "toggleSkimming", "toggleClipSkimming",
    "toggleAudioSkimming", "toggleInspector", "toggleTimeline",
    "toggleTimelineIndex", "toggleInspectorHeight", "beatDetectionGrid",
    "timelineScrolling", "enterFullScreen", "timelineHistoryBack",
    "timelineHistoryForward", "zoomToFit", "zoomIn", "zoomOut",
    "verticalZoomToFit", "zoomToSamples", "goToInspector", "goToTimeline",
    "goToViewer", "goToColorBoard", "selectNextItem", "selectUpperItem",
}

TIMELINE_EDIT_ACTIONS = {
    "addMarker", "addTodoMarker", "addChapterMarker", "addTransition",
    "copy", "paste", "pasteAsConnected", "pasteEffects",
    "pasteAttributes", "removeAttributes", "copyAttributes", "copyTimecode",
    "connectToPrimaryStoryline", "insertEdit", "appendEdit", "insertGap",
    "insertPlaceholder", "addAdjustmentClip", "addColorBoard", "addColorWheels",
    "addColorCurves", "addColorAdjustment", "addHueSaturation",
    "addEnhanceLightAndColor", "balanceColor", "matchColor",
    "addMagneticMask", "smartConform", "adjustVolumeUp", "adjustVolumeDown",
    "expandAudio", "expandAudioComponents", "addChannelEQ", "enhanceAudio",
    "matchAudio", "detachAudio", "addBasicTitle", "addBasicLowerThird",
    "addKeyframe",
    "favorite", "reject", "unrate", "setRangeStart", "setRangeEnd",
    "clearRange", "setClipRange", "solo", "disable", "createCompoundClip",
    "autoReframe", "synchronizeClips", "openClip", "renameClip",
    "addToSoloedClips", "referenceNewParentClip", "changeDuration",
    "createStoryline", "liftFromPrimaryStoryline", "createAudition",
    "finalizeAudition", "nextAuditionPick", "previousAuditionPick",
    "addCaption", "createMulticamClip", "addKeywordGroup1", "addKeywordGroup2",
    "addKeywordGroup3", "addKeywordGroup4", "addKeywordGroup5",
    "addKeywordGroup6", "addKeywordGroup7", "nextColorEffect",
    "previousColorEffect", "resetColorBoard", "toggleAllColorOff",
    "alignAudioToVideo", "volumeMute", "addDefaultAudioEffect",
    "addDefaultVideoEffect", "applyAudioFades", "makeClipsUnique",
    "enableDisable", "transcodeMedia", "pasteAllAttributes", "duplicateProject", "snapshotProject",
    "projectProperties", "libraryProperties", "consolidateEventMedia",
    "mergeEvents", "renderSelection", "renderAll", "exportXML",
    "shareSelection", "find", "findAndReplaceTitle", "revealInBrowser",
    "revealProjectInBrowser", "revealInFinder", "analyzeAndFix",
    "backgroundTasks", "recordVoiceover", "editRoles", "addVideoGenerator",
}

TIMELINE_DESTRUCTIVE_ACTIONS = {
    "blade", "bladeAll", "deleteMarker", "deleteMarkersInSelection",
    "delete", "cut", "replaceWithGap", "overwriteEdit", "trimToPlayhead",
    "extendEditToPlayhead", "trimStart", "trimEnd", "joinClips", "nudgeLeft",
    "nudgeRight", "nudgeUp", "nudgeDown", "retimeNormal", "retimeFast2x",
    "retimeFast4x", "retimeFast8x", "retimeFast20x", "retimeSlow50",
    "retimeSlow25", "retimeSlow10", "retimeReverse", "retimeHold",
    "freezeFrame", "retimeBladeSpeed", "retimeSpeedRampToZero",
    "retimeSpeedRampFromZero", "deleteKeyframes", "removeAllKeyframesFromClip",
    "breakApartClipItems",
    "removeEffects", "overwriteToPrimaryStoryline", "collapseToConnectedStoryline",
    "splitCaption", "resolveOverlaps", "toggleSelectedEffectsOff",
    "toggleDuplicateDetection", "insertEditAudio", "insertEditVideo",
    "appendEditAudio", "appendEditVideo", "overwriteEditAudio",
    "overwriteEditVideo", "connectEditAudio", "connectEditVideo",
    "connectEditBacktimed", "avEditModeAudio", "avEditModeVideo",
    "avEditModeBoth", "replaceFromStart", "replaceFromEnd", "replaceWhole",
    "retimeCustomSpeed", "retimeInstantReplayHalf", "retimeInstantReplayQuarter",
    "retimeReset", "retimeOpticalFlow", "retimeFrameBlending",
    "retimeFloorFrame", "removeAllKeywords", "removeAnalysisKeywords",
    "closeLibrary", "deleteGeneratedFiles", "moveToTrash", "hideClip",
}

TIMELINE_HISTORY_ACTIONS = {
    "undo", "redo",
}


def _titleize_tool_name(name: str) -> str:
    return " ".join(part.upper() if part in {"ai", "fcpxml", "srt"} else part.capitalize()
                    for part in name.split("_"))


def _tool_annotations(name: str) -> ToolAnnotations:
    if name in READ_ONLY_TOOLS:
        hints = dict(READ_ONLY)
    elif name in DESTRUCTIVE_TOOLS:
        hints = dict(DESTRUCTIVE_LOCAL_WRITE)
    else:
        # LOCAL_WRITE_TOOLS, and anything newly added that has not been classified
        # yet. A tool that lands here by accident is caught by
        # test_every_registered_tool_is_in_a_classification_set, so the three sets
        # stay a decision rather than a default.
        hints = dict(LOCAL_WRITE)

    if name in IDEMPOTENT_LOCAL_WRITE_TOOLS:
        hints["idempotent_hint"] = True

    return ToolAnnotations(title=CUSTOM_TOOL_TITLES.get(name, _titleize_tool_name(name)), **hints)


def _guard_tool_errors(fn):
    """Turn an unexpected exception inside a tool into a ToolError carrying the exception
    text, so the client (and the AI reading it) sees "KeyError: 'items'" instead of the
    SDK's bare "Error executing tool ...". The SDK logs a ToolError without its traceback
    (only unexpected exceptions get one), so the traceback is logged here first; the
    SDK's logging goes to stderr, never to the protocol stream."""
    if inspect.iscoroutinefunction(fn):
        # A sync wrapper would hide an async tool from the SDK and return a coroutine.
        raise TypeError(f"{fn.__name__}: SpliceKit tools are synchronous functions")

    @functools.wraps(fn)
    def guarded(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except ToolError:
            raise
        except Exception as exc:
            _LOG.exception("tool %s crashed", fn.__name__)
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc
    return guarded


def splicekit_tool(name: str):
    """Register a SpliceKit MCP tool under the SDK: the tool annotations that belong to
    `name` (see READ_ONLY_TOOLS / DESTRUCTIVE_TOOLS / LOCAL_WRITE_TOOLS /
    IDEMPOTENT_LOCAL_WRITE_TOOLS) plus the error guard above. `name` must equal the decorated function's name."""
    register = mcp.tool(annotations=_tool_annotations(name))

    def decorator(fn):
        if fn.__name__ != name:
            raise ValueError(f"splicekit_tool({name!r}) applied to {fn.__name__}()")
        return register(_guard_tool_errors(fn))

    return decorator


def _lists_actions(actions, note: str = ""):
    """Append the accepted `action` strings to a tool's docstring, generated from the set the
    tool actually validates against.

    These four tools each checked `action` against a set and returned a helpful error, but
    their docstrings named none of the values — and the server's own instructions tell an
    agent to prefer them over the legacy `timeline_action`, which does list its actions. So
    the only way to discover them was to guess, or to fall back to the legacy tool. There are
    220 of them across the four sets, far too many to keep in sync by hand, so the list is
    built from the set at import time and cannot drift.

    Applied UNDER @splicekit_tool so the docstring is already rewritten when the tool registers.
    """
    def decorator(fn):
        names = ", ".join(f"``{a}``" for a in sorted(actions))
        extra = f"\n    Accepted ``action`` values ({len(actions)}):\n    {names}\n"
        if note:
            extra += f"\n    {note}\n"
        fn.__doc__ = (fn.__doc__ or "").rstrip() + "\n" + extra
        return fn
    return decorator


def _handle_management_response(action: str, handle: str = "") -> str:
    if action == "list":
        r = bridge.call("object.list")
    elif action == "inspect" and handle:
        r = bridge.call("object.get", handle=handle)
    elif action == "release" and handle:
        r = bridge.call("object.release", handle=handle)
    elif action == "release_all":
        r = bridge.call("object.release", all=True)
    else:
        return (
            "Unknown handle action. Use list_handles(), inspect_handle(handle), "
            "release_handle(handle), or release_all_handles()."
        )

    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


class BridgeConnection:
    """Persistent TCP connection to the SpliceKit JSON-RPC server inside FCP.

    Keeps the socket open between calls so we don't pay the connect overhead
    on every tool invocation. Auto-reconnects if the connection drops (FCP
    restarted, socket timed out, etc).
    """

    def __init__(self):
        self.sock = None
        self._buf = b""  # leftover bytes from previous recv (newline-delimited protocol)
        self._id = 0     # monotonically increasing JSON-RPC request ID
        # The mcp 2.x SDK runs synchronous tools in worker threads, so two tool calls
        # can be in flight at once (a client sending parallel calls, or a call that is
        # still running after the client gave up on it). One socket, one read buffer and
        # one id counter must not be shared between them: serialize every round trip.
        self._lock = threading.Lock()

    CONNECT_TIMEOUT = 5    # loopback either accepts at once or refuses
    READ_TIMEOUT = 30      # some bridge calls wait on FCP's main thread (20 s watchdog inside)

    def ensure_connected(self):
        if self.sock is None:
            # Assign only after connect() succeeds: a refused connect must not leave
            # a dead socket behind, or the next call fails once before reconnecting.
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.CONNECT_TIMEOUT)
            try:
                sock.connect((SPLICEKIT_HOST, SPLICEKIT_PORT))
            except OSError:
                sock.close()
                raise
            sock.settimeout(self.READ_TIMEOUT)
            self.sock = sock
            self._buf = b""

    def reset(self):
        """Drop the connection (the next call reconnects). Safe to call from any thread;
        deploy_and_restart uses it around killing and relaunching Final Cut Pro."""
        with self._lock:
            self._drop_socket()

    close = reset

    def _drop_socket(self):
        sock, self.sock, self._buf = self.sock, None, b""
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def call(self, method: str, params_dict=None, /, *, timeout: float = None, **params) -> dict:
        """Send a JSON-RPC request and wait for the response.

        Accepts params as keyword args OR as a single dict positional arg:
            bridge.call("method", key="value")       # kwargs
            bridge.call("method", {"key": "value"})  # dict

        `method` and `params_dict` are positional-only so that an RPC parameter of
        the same name cannot collide with them. bridge.describe takes a parameter
        literally called "method", and before this that call raised
        "got multiple values for argument 'method'" instead of reaching the bridge.
        An RPC parameter named "timeout" still has to go through the dict form.

        `timeout` (seconds) bounds this one round trip instead of the usual READ_TIMEOUT;
        the import-time plugin probe uses it so a Final Cut Pro whose main thread is busy
        cannot hold up the MCP handshake.

        Returns the result dict on success, or {"error": "..."} on failure.
        Handles connection errors gracefully — the next call will auto-reconnect.
        """
        # Merge positional dict and kwargs so callers can use either style
        if params_dict is not None:
            if isinstance(params_dict, dict):
                params = {**params_dict, **params}
            # else ignore non-dict positional (shouldn't happen)
        # One round trip at a time: the lock is held across the read, so a call that
        # waits on FCP's main thread delays the calls queued behind it (by design: there
        # is one bridge and one socket, and interleaving frames would be worse).
        with self._lock:
            return self._call_locked(method, params, timeout)

    def _call_locked(self, method: str, params: dict, timeout: float = None) -> dict:
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as e:
            return {"error": f"Cannot connect to SpliceKit at {SPLICEKIT_HOST}:{SPLICEKIT_PORT}. "
                    f"Is the modded FCP running? Error: {e}"}
        if timeout is not None:
            self.sock.settimeout(timeout)

        self._id += 1
        expected_id = self._id
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": expected_id})
        try:
            # Protocol: newline-delimited JSON, one request/response per line.
            # The server may also emit unsolicited `method:"event"` frames
            # (JSON-RPC notifications) on the same socket. Those must NOT be
            # consumed as the response. Loop until we see a frame with a
            # matching `id`; drop anything else.
            self.sock.sendall(req.encode() + b"\n")
            while True:
                while b"\n" not in self._buf:
                    chunk = self.sock.recv(16777216)  # 16MB — FCPXML responses can be large
                    if not chunk:
                        self.sock = None  # server closed the connection, force reconnect next call
                        return {"error": "Connection closed by SpliceKit"}
                    self._buf += chunk
                line, self._buf = self._buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    resp = json.loads(line)
                except json.JSONDecodeError:
                    # Corrupt frame — skip it and keep reading
                    continue
                # Skip notifications (no id, or has a method field)
                if "method" in resp or "id" not in resp:
                    continue
                # Skip responses whose id doesn't match (stale from a prior
                # call that timed out or got interrupted)
                if resp.get("id") != expected_id:
                    continue
                if "error" in resp:
                    return {"error": resp["error"]}
                return resp.get("result", {})
        except Exception as e:
            self._drop_socket()  # toss the broken socket so the next call reconnects
            return {"error": f"Bridge communication error: {e}"}
        finally:
            if timeout is not None and self.sock is not None:
                self.sock.settimeout(self.READ_TIMEOUT)


bridge = BridgeConnection()  # singleton -- shared by all tool functions below
atexit.register(bridge.close)


# -- Helpers used by every tool function --

def _err(r):
    """Check if a bridge response contains an error."""
    return "error" in r


def _fmt(r):
    """Pretty-print a bridge response as indented JSON."""
    return json.dumps(r, indent=2, default=str)


_SECONDS_LIST_PARSE_HELP = (
    "Accepted forms: JSON array of seconds (e.g. '[3.0, 6.0, 9.0]') or "
    "comma-separated seconds (e.g. '3.0, 6.0, 9.0' or '25.0')."
)


def _parse_seconds_list(value: str) -> list[float]:
    """Parse a JSON seconds array or a plain comma-separated list of numbers."""
    text = (value or "").strip()
    if not text:
        raise ToolError(f"times is required. {_SECONDS_LIST_PARSE_HELP}")

    if text.startswith("["):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ToolError(
                f"Invalid times JSON: {exc}. {_SECONDS_LIST_PARSE_HELP}"
            ) from exc
        if isinstance(parsed, (int, float)):
            return [float(parsed)]
        if not isinstance(parsed, list):
            raise ToolError(
                f"times must be a JSON array of numbers. {_SECONDS_LIST_PARSE_HELP}"
            )
        try:
            return [float(x) for x in parsed]
        except (TypeError, ValueError) as exc:
            raise ToolError(
                f"times must contain only numbers. {_SECONDS_LIST_PARSE_HELP}"
            ) from exc

    parts = [p.strip() for p in text.split(",") if p.strip()]
    try:
        return [float(p) for p in parts]
    except ValueError as exc:
        raise ToolError(
            f"Invalid comma-separated times: {exc}. {_SECONDS_LIST_PARSE_HELP}"
        ) from exc


_MARKERS_PARSE_HELP = (
    "Accepted forms: JSON array of marker objects "
    '(e.g. \'[{"time": 5.0, "name": "Scene 1"}]\') or comma-separated seconds '
    "(e.g. '5.0, 12.0' — standard markers at those times)."
)


def _parse_markers_list(value: str) -> list:
    """Parse marker specs from JSON or comma-separated time values."""
    text = (value or "").strip()
    if not text:
        raise ToolError(f"markers is required. {_MARKERS_PARSE_HELP}")

    if text.startswith("["):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ToolError(
                f"Invalid markers JSON: {exc}. {_MARKERS_PARSE_HELP}"
            ) from exc
        if not isinstance(parsed, list):
            raise ToolError(
                f"markers must be a JSON array. {_MARKERS_PARSE_HELP}"
            )
        return parsed

    try:
        times = _parse_seconds_list(text)
    except ToolError as exc:
        raise ToolError(f"{exc}. {_MARKERS_PARSE_HELP}") from exc
    return [{"time": t} for t in times]


def _call_or_error(method: str, /, **params) -> str:
    """Call the bridge and return formatted JSON, or an error string.

    `method` is positional-only: an RPC parameter of the same name would otherwise
    collide with it (see BridgeConnection.call).

    This is the common pattern used by most tools — call the bridge,
    check for errors, format the result. Having it in one place means
    we don't repeat the same 4 lines in every tool function.
    """
    r = bridge.call(method, **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if isinstance(r, dict) and r.get("dialogPending") and r.get("note"):
        # A sheet or modal dialog is open after the action: nothing has happened on the
        # timeline yet, so say that before the JSON (whose key order is not fixed).
        return f"DIALOG PENDING: {r['note']}\n\n{_fmt(r)}"
    return _fmt(r)


class BridgeError(Exception):
    """Raised when a bridge call returns an error."""
    pass


def _call(method: str, /, **params) -> dict:
    """Call the bridge and return the result dict. Raises BridgeError on failure.

    `method` is positional-only for the same reason as _call_or_error."""
    r = bridge.call(method, **params)
    if _err(r):
        raise BridgeError(r.get("error", str(r)))
    return r


def bridge_tool(fn):
    """Decorator: catches BridgeError and returns 'Error: ...' string.

    Use with _call() to eliminate the repetitive if-_err-return pattern:
        @splicekit_tool("my_tool")
        @bridge_tool
        def my_tool() -> str:
            r = _call("my.method")
            return _fmt(r)
    """
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except BridgeError as e:
            return f"Error: {e}"
    return wrapper


# ============================================================
# Core Connection & Status
# ============================================================
# The first thing any client should do is call bridge_status() to
# verify FCP is running and the bridge is responsive.

@splicekit_tool("bridge_status")
def bridge_status() -> str:
    """Check if SpliceKit is running and get FCP version info."""
    r = bridge.call("system.version")
    if _err(r):
        return f"Error: SpliceKit not connected: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("bridge_alive")
def bridge_alive() -> str:
    """Cheap liveness probe that does not touch the main thread.

    Returns {alive, version, pid, timestamp} without any FCP API calls. Use
    this when you want to verify the bridge is responsive without risking a
    hang on a stuck main thread.
    """
    return _call_or_error("bridge.alive")


@splicekit_tool("bridge_describe")
def bridge_describe(method: str = "", safety: str = "") -> str:
    """Return self-describing metadata for every known RPC method.

    - method: optional — return metadata for a single method only
    - safety: optional — filter by classification
      ("safe", "state_dependent", "modal", "destructive", "system", "unclassified")

    Each entry includes: name, safety classification, one-line summary, source
    (builtin/plugin). Use this to discover what's safe to call autonomously,
    what requires selection/project state, and what may open modals.
    """
    params = {}
    if method:
        params["method"] = method
    if safety:
        params["safety"] = safety
    return _call_or_error("bridge.describe", **params)


@splicekit_tool("bridge_safety_tags")
def bridge_safety_tags() -> str:
    """List the safety classifications used by bridge_describe with meanings."""
    return _call_or_error("bridge.safetyTags")


@splicekit_tool("events_subscribe")
def events_subscribe(patterns: list[str] | None = None) -> str:
    """Subscribe this connection to bridge events matching patterns.

    Patterns: exact event type (e.g. "command.completed"), "prefix.*" wildcard,
    or "*" for everything. Without a subscription, all events are delivered.

    Events arrive as JSON-RPC notifications with method="event" and params
    carrying {type, ...}. Relevant types include:
      - command.completed — when async=true RPCs finish (carries correlation_id)
      - crash             — when the in-process crash handler catches a signal
      - trace             — from debug.traceMethod installed traces

    Example: events_subscribe(patterns=["command.*", "crash"])
    """
    return _call_or_error("events.subscribe", patterns=patterns or ["*"])


@splicekit_tool("events_unsubscribe")
def events_unsubscribe() -> str:
    """Remove this connection's event pattern allowlist."""
    return _call_or_error("events.unsubscribe")


@splicekit_tool("events_status")
def events_status() -> str:
    """Report this connection's current event subscription state."""
    return _call_or_error("events.status")


@splicekit_tool("async_status")
def async_status() -> str:
    """List in-flight async operations with elapsed time.

    Long-running RPCs dispatched with async=true are tracked here. Each entry
    has a correlation_id, method name, and elapsed_ms since dispatch. When
    they finish, a `command.completed` event is broadcast with the result.
    """
    return _call_or_error("async.status")


@splicekit_tool("background_render_status")
def background_render_status() -> str:
    """Inspect Final Cut Pro's live background-render state.

    Returns queue and manager state pulled from the running process, including:
    - Whether background render is currently in low-overhead mode
    - The current Background Render run-group queue concurrency
    - Auto-start delay and related background-render defaults
    - Active GPU/render preference defaults used for background render

    Use this before and after background_render_control() to see whether FCP
    accepted the requested throttle window.
    """
    r = bridge.call("backgroundRender.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("background_render_control")
def background_render_control(action: str, seconds: float) -> str:
    """Temporarily reduce background-render impact while editing.

    Args:
        action: One of:
          - "hold_off": Delay background-render auto-start for `seconds`
          - "low_overhead": Enter FCP's internal low-overhead mode for `seconds`
        seconds: Duration in seconds. Must be > 0.

    This tool intentionally exposes only short-lived, reversible throttles.
    It does not change persistent preferences or attempt CPU affinity control.
    """
    normalized = action.strip().lower()
    if normalized not in {"hold_off", "low_overhead"}:
        return "Error: action must be 'hold_off' or 'low_overhead'."
    if seconds <= 0:
        return "Error: seconds must be > 0."

    r = bridge.call("backgroundRender.control", action=normalized, seconds=seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Timeline Actions
# ============================================================
# These map directly to FCP's IBAction methods on the timeline module.
# Most require a clip to be selected first (selectClipAtPlayhead).

@splicekit_tool("timeline_action")
def timeline_action(action: str, dry_run: bool = False) -> str:
    """Use this legacy catch-all tool when a timeline action does not fit the narrower action tools.

    Actions:
      Blade: blade, bladeAll
      Markers: addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker,
               previousMarker, deleteMarkersInSelection
      Transitions: addTransition
      Navigation: nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead
      Selection: selectAll, deselectAll
      Edit: delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap,
            pasteEffects, pasteAttributes, removeAttributes, copyAttributes, copyTimecode
      Edit Modes: connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit
      Insert: insertGap, insertPlaceholder, addAdjustmentClip
      Trim: trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips,
            nudgeLeft, nudgeRight, nudgeUp, nudgeDown
      Color: addColorBoard, addColorWheels, addColorCurves, addColorAdjustment,
             addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor,
             addMagneticMask, smartConform
      Volume: adjustVolumeUp, adjustVolumeDown
      Audio: expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio,
             matchAudio, detachAudio
      Titles: addBasicTitle, addBasicLowerThird
      Speed: retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10,
             retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed,
             retimeSpeedRampToZero, retimeSpeedRampFromZero
      Keyframes: addKeyframe, deleteKeyframes, removeAllKeyframesFromClip,
                 nextKeyframe, previousKeyframe
      Rating: favorite, reject, unrate
      Range: setRangeStart, setRangeEnd, clearRange, setClipRange
      Clip Ops: solo, disable, createCompoundClip, autoReframe, detachAudio,
                breakApartClipItems, removeEffects, synchronizeClips, openClip,
                renameClip, addToSoloedClips, referenceNewParentClip, changeDuration
      Storyline: createStoryline, liftFromPrimaryStoryline,
                 overwriteToPrimaryStoryline, collapseToConnectedStoryline
      Audition: createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick
      Captions: addCaption, splitCaption, resolveOverlaps
      Multicam: createMulticamClip
      Show/Hide: showVideoAnimation, showAudioAnimation, soloAnimation,
                 showTrackingEditor, showCinematicEditor, showMagneticMaskEditor,
                 enableBeatDetection, showPrecisionEditor, showAudioLanes,
                 expandSubroles, showDuplicateRanges, showKeywordEditor,
                 togglePrecisionEditor, toggleSelectedEffectsOff, toggleDuplicateDetection
      Edit Modes AV: insertEditAudio, insertEditVideo, appendEditAudio, appendEditVideo,
                     overwriteEditAudio, overwriteEditVideo, connectEditAudio,
                     connectEditVideo, connectEditBacktimed, avEditModeAudio,
                     avEditModeVideo, avEditModeBoth
      Replace: replaceFromStart, replaceFromEnd, replaceWhole
      Speed Extra: retimeCustomSpeed, retimeInstantReplayHalf, retimeInstantReplayQuarter,
                   retimeReset, retimeOpticalFlow, retimeFrameBlending, retimeFloorFrame
      Keywords: addKeywordGroup1..7
      Color Nav: nextColorEffect, previousColorEffect, resetColorBoard, toggleAllColorOff
      Audio Extra: alignAudioToVideo, volumeMute, toggleMuteAudio, addDefaultAudioEffect,
                   addDefaultVideoEffect, applyAudioFades
      Clip Extra: makeClipsUnique, enableDisable, transcodeMedia, pasteAllAttributes
      Navigate: goToInspector, goToTimeline, goToViewer, goToColorBoard,
                selectNextItem, selectUpperItem
      View: zoomToFit, zoomIn, zoomOut, verticalZoomToFit, zoomToSamples,
            toggleSnapping, toggleSkimming, toggleClipSkimming, toggleAudioSkimming,
            toggleInspector, toggleTimeline, toggleTimelineIndex, toggleInspectorHeight,
            beatDetectionGrid, timelineScrolling, enterFullScreen,
            timelineHistoryBack, timelineHistoryForward
      Project: duplicateProject, snapshotProject, projectProperties
      Library: closeLibrary, libraryProperties, consolidateEventMedia, mergeEvents,
               deleteGeneratedFiles
      Render: renderSelection, renderAll
      Export: exportXML, shareSelection
      Find: find, findAndReplaceTitle
      Reveal: revealInBrowser, revealProjectInBrowser, revealInFinder, moveToTrash
      Other: analyzeAndFix, backgroundTasks, recordVoiceover, editRoles,
             hideClip, removeAllKeywords, removeAnalysisKeywords, addVideoGenerator

    You can also pass any raw ObjC selector name.

    Pass dry_run=True to see what would fire without firing it — useful when
    you want to verify a project is loaded and a clip is selected before a
    destructive action.
    """
    return _call_or_error("timeline.action", action=action, dry_run=dry_run)


@splicekit_tool("timeline_navigation_action")
@_lists_actions(TIMELINE_NAVIGATION_ACTIONS,
                "Nothing here changes the project. For edits use timeline_edit_action(), for "
                "deletes and trims timeline_destructive_action(), for undo/redo history_action().")
def timeline_navigation_action(action: str) -> str:
    """Move the playhead, change the selection, or change what the timeline shows.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_NAVIGATION_ACTIONS:
        return (
            f"Error: '{action}' is not a supported navigation action. "
            "Use timeline_edit_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("timeline_edit_action")
@_lists_actions(TIMELINE_EDIT_ACTIONS,
                "These change the project but do not remove media: markers, effects, titles, "
                "roles, ranges. Undo with history_action(\"undo\"). For deletes, cuts, blades, "
                "trims and retimes use timeline_destructive_action().")
def timeline_edit_action(action: str) -> str:
    """Change the timeline without removing anything: markers, effects, titles, ranges.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_EDIT_ACTIONS:
        return (
            f"Error: '{action}' is not a supported non-destructive edit action. "
            "Use timeline_navigation_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("timeline_destructive_action")
@_lists_actions(TIMELINE_DESTRUCTIVE_ACTIONS,
                "Every one of these removes or rewrites timeline content. Most are undoable with "
                "history_action(\"undo\") — check the result and verify with get_timeline_clips() "
                "rather than assuming.")
def timeline_destructive_action(action: str) -> str:
    """Delete, cut, blade, replace, trim or retime timeline content.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_DESTRUCTIVE_ACTIONS:
        return (
            f"Error: '{action}' is not a supported destructive action. "
            "Use timeline_navigation_action(), timeline_edit_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("history_action")
@_lists_actions(TIMELINE_HISTORY_ACTIONS)
def history_action(action: str) -> str:
    """Undo or redo the last timeline edit.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_HISTORY_ACTIONS:
        return (
            f"Error: '{action}' is not a supported history action. "
            "Valid actions are: undo, redo."
        )
    return _call_or_error("timeline.action", action=action)


PLAYBACK_ACTIONS = (
    "playPause",
    "goToStart",
    "goToEnd",
    "nextFrame",
    "prevFrame",
    "nextFrame10",
    "prevFrame10",
    "playAroundCurrent",
    "playFromStart",
    "playInToOut",
    "playReverse",
    "stopPlaying",
    "loop",
    "fastForward",
    "rewind",
    "playRate1X",
    "playRate2X",
    "playRate4X",
    "playRate8X",
    "playRate16X",
    "playRate32X",
    "playRateHalf",
    "playRateMinusHalf",
    "playRateMinus1X",
    "playRateMinus2X",
    "playRateMinus32X",
)


def _playback_action_doc() -> str:
    return (
        "Use this tool to move playback state without changing timeline content.\n\n"
        f"Actions: {', '.join(PLAYBACK_ACTIONS)}\n\n"
        "For precise speed control, use set_playback_speed() instead."
    )


@splicekit_tool("playback_action")
def playback_action(action: str) -> str:
    """Use this tool to move playback state without changing timeline content."""
    if action not in PLAYBACK_ACTIONS:
        return (
            f"Error: unknown playback action '{action}'. "
            f"Available: {', '.join(PLAYBACK_ACTIONS)}"
        )
    return _call_or_error("playback.action", action=action)


playback_action.__doc__ = _playback_action_doc()


@splicekit_tool("set_playback_speed")
def set_playback_speed(rate: float = None, action: str = None) -> str:
    """Set playback speed to an exact rate, or use shuttle actions.

    Args:
        rate: Exact playback rate as float. Examples:
              0.5 = half speed, 1.0 = normal, 1.5, 1.8,
              2.0 = double speed, -1.0 = reverse normal.
              Supports any float value.
        action: Named speed action. One of:
              "faster" - play forward at configured L speed
              "slower" - play reverse at configured J speed
              "stop" - stop playback

    L/J speed ladders are configurable via Enhancements > Playback Speed menu,
    or via set_bridge_option("lLadder", value=[1, 1.5, 2, 4, 8]).
    Default ladders: [1, 2, 4, 8, 16, 32].
    "faster"/"slower" trigger the swizzled fastForward/rewind which walk
    the configured ladder progressively (like pressing L/J on keyboard).

    Provide either rate OR action, not both.
    """
    if rate is not None and action is not None:
        return "Error: provide either rate or action, not both"

    if rate is not None:
        return _call_or_error("playback.setRate", rate=rate)

    if action is not None:
        if action in ("faster", "slower", "stop"):
            return _call_or_error("playback.shuttle", direction=action)
        return f"Error: unknown action '{action}'. Valid: faster, slower, stop"

    return "Error: provide either rate (float) or action (string)"


def _format_scene_detect_result(r: dict) -> str:
    changes = r.get("sceneChanges", [])
    total = int(r.get("count", len(changes)))
    lines = [
        f"Scene changes: {total} (threshold={r.get('threshold', 0)}, file={r.get('mediaFile', '?')})",
    ]
    if r.get("clipName"):
        tl_start = float(r.get("clipTimelineStart", 0))
        tl_end = float(r.get("clipTimelineEnd", 0))
        file_start = float(r.get("fileStart", 0))
        clip_media_dur = tl_end - tl_start
        file_end = file_start + clip_media_dur
        lines.append(
            f"Analysed clip: \"{r.get('clipName')}\" ({r.get('clipHandle', '')}) "
            f"timeline {tl_start:.3f}-{tl_end:.3f}s"
        )
        lines.append(
            f"Clip used source media range: {file_start:.3f}-{file_end:.3f}s "
            f"(mark/blade only apply to cuts inside this window)."
        )
    lines.append(
        "Times below are SOURCE MEDIA file seconds (not timeline). "
        "mark_scene_changes / blade_scene_changes map them onto the analysed clip."
    )
    action = r.get("action")
    if action not in (None, "detect"):
        applied = int(r.get("applied", 0))
        skipped = int(r.get("skippedOutsideClip", 0))
        lines.append(f"Action: {action}")
        lines.append(
            f"Applied {applied} of {total} ({skipped} fell outside the clip's used media range and were skipped)."
        )
        if applied == 0:
            lines.append(
                "No markers or blades were placed (all detected cuts were outside the clip's "
                "used source media range, or placement failed)."
            )
    lines.append("")
    for sc in changes:
        lines.append(f"  {sc['time']:.2f}s  (score: {sc.get('score', 0):.3f})")
    if r.get("error"):
        lines.append(f"\nWarning: {r['error']}")
    return "\n".join(lines)


@splicekit_tool("detect_scene_changes")
def detect_scene_changes(
    threshold: float = 0.35,
    action: str = "detect",
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Use this read-only tool to inspect scene changes before deciding whether to mark or blade them.

    Target clip (analysed once, same for detect/mark/blade): handle if given; else the sole
    selected clip; else the primary-storyline clip under the playhead; else an error listing
    spine candidates. Pass file_url to analyse a file on disk without a timeline clip (times
    are file seconds only; mark/blade are refused).

    Args:
        threshold: Sensitivity (0.0-1.0). Lower = more sensitive. Default 0.35.
        action: Deprecated compatibility argument. Only "detect" is accepted here.
        sample_interval: Seconds between sampled frames. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips() (required for compound/multicam).
        file_url: Analyse this media path directly (no timeline mapping).

    Returns scene-change timestamps in source-media seconds with confidence scores.
    """
    if action != "detect":
        return "Error: detect_scene_changes() is read-only. Use mark_scene_changes() or blade_scene_changes()."

    params: dict = {
        "threshold": threshold,
        "action": action,
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url

    r = bridge.call("scene.detect", **params)
    if _err(r):
        err = f"Error: {r.get('error', r)}"
        candidates = r.get("candidates")
        if candidates:
            err += "\nPrimary storyline candidates:"
            for c in candidates:
                err += (
                    f"\n  {c.get('handle', '?')} \"{c.get('name', '')}\" "
                    f"{c.get('start', 0):.3f}-{c.get('end', 0):.3f}s"
                )
        return err

    return _format_scene_detect_result(r)


@splicekit_tool("mark_scene_changes")
def mark_scene_changes(
    threshold: float = 0.35,
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Add markers at detected scene changes on the resolved timeline clip (see detect_scene_changes).

    Args:
        threshold: Scene-cut sensitivity (0.0–1.0). Lower detects more cuts. Default 0.35.
        sample_interval: Seconds between sampled frames for detection. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips(); required for compound/multicam.
        file_url: If set, analyse this media file only; mark is refused (nothing to map onto).
    """
    params: dict = {
        "threshold": threshold,
        "action": "markers",
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url
    r = bridge.call("scene.detect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _format_scene_detect_result(r)


@splicekit_tool("blade_scene_changes")
def blade_scene_changes(
    threshold: float = 0.35,
    sample_interval: float = 0.1,
    handle: str = "",
    file_url: str = "",
) -> str:
    """Blade the timeline at detected scene changes on the resolved timeline clip (see detect_scene_changes).

    Args:
        threshold: Scene-cut sensitivity (0.0–1.0). Lower detects more cuts. Default 0.35.
        sample_interval: Seconds between sampled frames for detection. Default 0.1.
        handle: Timeline clip handle from get_timeline_clips(); required for compound/multicam.
        file_url: If set, analyse this media file only; blade is refused (nothing to map onto).
    """
    params: dict = {
        "threshold": threshold,
        "action": "blade",
        "sampleInterval": sample_interval,
    }
    if handle:
        params["handle"] = handle
    if file_url:
        params["fileURL"] = file_url
    r = bridge.call("scene.detect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _format_scene_detect_result(r)


@splicekit_tool("seek_to_time")
def seek_to_time(seconds: float) -> str:
    """Use this tool to jump the playhead to an exact time before another operation.

    Args:
        seconds: Time in seconds (e.g. 3.5 = 3 seconds 500ms)

    This is much faster than stepping frames. Use this for all
    time-based positioning before blade, marker, or other operations.
    """
    return _call_or_error("playback.seekToTime", seconds=seconds)


# ============================================================
# Timeline State (structured)
# ============================================================
# Read the timeline's current contents as structured data.
# This is how the AI "sees" what's in the project.

def _time_seconds(container, key):
    """Read container[key]["seconds"] from a bridge CMTime dict, or None if absent."""
    if not isinstance(container, dict):
        return None
    t = container.get(key)
    if isinstance(t, dict) and isinstance(t.get("seconds"), (int, float)):
        return float(t["seconds"])
    return None


def _fmt_secs(value, width=8):
    """Right-aligned seconds column ('   1.50s') or '?' when unknown."""
    if value is None:
        return f"{'?':>{width}}"
    return f"{value:>{width - 1}.2f}s"


def _connected_lane(c):
    """Lane relative to the spine. The bridge reports `effectiveLane` (nested anchors
    have lanes relative to their parent); fall back to the raw `lane`."""
    lane = c.get("effectiveLane")
    if lane is None:
        lane = c.get("lane", 0)
    return lane or 0


def _container_tag(item) -> str:
    """Marker for a clip that is a container of clips (FCP's isReferenceClip / isCompoundClip flags)."""
    if not isinstance(item, dict):
        return ""
    if item.get("isReferenceClip"):
        return "  [reference clip]"
    if item.get("isCompound"):
        return "  [compound clip]"
    if item.get("isMulticamClip"):
        return "  [multicam clip]"
    return ""


def _connected_table_lines(connected):
    """Render connectedItems from timeline.getDetailedState as a table,
    sorted by start time then lane."""
    if not connected:
        return []
    ordered = sorted(
        connected,
        key=lambda c: (
            _time_seconds(c, "startTime") is None,
            _time_seconds(c, "startTime") or 0.0,
            _connected_lane(c),
        ),
    )
    lines = [
        f"{'Lane':>4} {'Class':<30} {'Name':<20} {'Start':>8} {'End':>8} {'Duration':>10} {'Parent':>6} {'Sel':>4} {'Handle'}",
        "-" * 118,
    ]
    for c in ordered:
        dur_s = _time_seconds(c, "duration")
        lines.append(
            f"{_connected_lane(c):>4} "
            f"{str(c.get('class', '?')):<30} "
            f"{str(c.get('name', ''))[:20]:<20} "
            f"{_fmt_secs(_time_seconds(c, 'startTime'))} "
            f"{_fmt_secs(_time_seconds(c, 'endTime'))} "
            f"{(dur_s if dur_s is not None else 0.0):>9.3f}s "
            f"{c.get('parentIndex', '?'):>6} "
            f"{'*' if c.get('selected') else ' ':>4} "
            f"{c.get('handle', '')}{_container_tag(c)}"
        )
    return lines


def _marker_table_lines(markers):
    """Render marker dicts (timeline.getDetailedState / timeline.getMarkers) as a table
    sorted by time. The Completed column only appears when some marker reports `completed`."""
    if not markers:
        return []
    ordered = sorted(
        markers,
        key=lambda m: (_time_seconds(m, "time") is None, _time_seconds(m, "time") or 0.0),
    )
    has_done = any("completed" in m for m in markers)
    header = f"{'Time':>9} {'Kind':<9} {'Name':<30}"
    if has_done:
        header += f" {'Completed':<9}"
    header += " Handle"
    lines = [header, "-" * (len(header) + 8)]
    for m in ordered:
        secs = _time_seconds(m, "time")
        time_str = f"{secs:>8.3f}s" if secs is not None else f"{'?':>9}"
        row = f"{time_str} {str(m.get('kind', '?')):<9} {str(m.get('name', ''))[:30]:<30}"
        if has_done:
            done = m.get("completed")
            done_str = "" if done is None else ("yes" if done else "no")
            row += f" {done_str:<9}"
        row += f" {m.get('handle', '')}"
        lines.append(row)
    return lines


@splicekit_tool("get_timeline_clips")
def get_timeline_clips(limit: int = 100, include_connected: bool = True,
                       include_markers: bool = True) -> str:
    """Get a structured view of everything in the current timeline.

    Returns sequence name, playhead time, duration, then three sections:

    1. Primary storyline (spine) items: index, class, name, start/end, duration,
       lane, selected, handle, and after the handle a [reference clip] /
       [compound clip] / [multicam clip] tag for a clip that is a container of clips
       (FCP's own isReferenceClip / isCompoundClip flags; the multicam flag is a
       SpliceKit probe), with a legend line at the end.
    2. Connected clips -- everything anchored to spine clips: titles, B-roll,
       captions and SpliceKit-generated caption titles, music/SFX on negative lanes, and the contents of
       connected storylines. Columns: lane (relative to the spine; positive is
       above, negative below), class, name, start, end, duration, parent (spine
       index the clip is anchored to), selected, handle.
    3. Markers: time, kind (FCP calls this the marker type: standard, todo =
       to-do item, chapter; keyword and analysis are keyword ranges and analysis
       keywords, which FCP's Timeline Index lists as tags), name, completed
       (to-do items, when readable), handle. Marker handles work with
       timeline.directAction changeMarkerName / markMarkerCompleted / removeMarker.

    Args:
        limit: max spine items to list (connected clips/markers cover ALL spine items)
        include_connected: walk anchoredItems for connected clips (default True)
        include_markers: query markers via markersInTimeRange + anchored walk (default True)

    Handles can be used with get_object_property() for deeper inspection.
    Use list_markers() for a markers-only view with a kind filter.
    """
    r = bridge.call("timeline.getDetailedState", limit=limit,
                    include_connected=include_connected,
                    include_markers=include_markers)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Build a human-readable table -- the AI reads this to understand the timeline
    lines = []
    lines.append(f"Sequence: {r.get('sequenceName', '?')}")
    pt = r.get("playheadTime", {})
    lines.append(f"Playhead: {pt.get('seconds', 0):.3f}s")
    dur = r.get("duration", {})
    lines.append(f"Duration: {dur.get('seconds', 0):.3f}s")
    lines.append(f"Items: {r.get('itemCount', 0)}")
    lines.append(f"Selected: {r.get('selectedCount', 0)}")
    if include_connected:
        lines.append(f"Connected: {r.get('connectedCount', 0)}")
    if include_markers:
        lines.append(f"Markers: {r.get('markerCount', 0)}")
    if r.get("connectedItemsError"):
        lines.append(f"WARNING connected clips: {r['connectedItemsError']}")
    if r.get("markersError"):
        lines.append(f"WARNING markers: {r['markersError']}")

    items = r.get("items", [])
    if items:
        # Two table formats: with start/end times if available, otherwise just duration + lane
        has_pos = any("startTime" in i for i in items)
        if has_pos:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Start':>8} {'End':>8} {'Duration':>10} {'Sel':>4} {'Handle'}")
            lines.append("-" * 110)
        else:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Duration':>10} {'Lane':>5} {'Sel':>4} {'Handle'}")
            lines.append("-" * 95)
        for item in items:
            dur_s = item.get("duration", {}).get("seconds", 0)
            if has_pos:
                start_s = item.get("startTime", {}).get("seconds", 0)
                end_s = item.get("endTime", {}).get("seconds", 0)
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{start_s:>7.2f}s "
                    f"{end_s:>7.2f}s "
                    f"{dur_s:>9.3f}s "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}{_container_tag(item)}"
                )
            else:
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{dur_s:>9.3f}s "
                    f"{item.get('lane', 0):>5} "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}{_container_tag(item)}"
                )

    if include_connected:
        connected = r.get("connectedItems", []) or []
        if connected:
            lines.append("\nConnected clips (anchored to spine items):")
            lines.extend(_connected_table_lines(connected))
            if r.get("connectedTruncated"):
                lines.append("(connected list truncated -- raise connected_limit on timeline.getDetailedState)")

    if include_markers:
        markers = r.get("markers", []) or []
        if markers:
            lines.append("\nMarkers:")
            lines.extend(_marker_table_lines(markers))
            if r.get("markersTruncated"):
                lines.append(f"(showing {len(markers)} of {r.get('markerTotal', '?')} markers)")

    tagged = [i for i in items if _container_tag(i)]
    if include_connected:
        tagged += [c for c in (r.get("connectedItems") or []) if _container_tag(c)]
    if tagged:
        lines.append("\n[reference clip] = FCP's own isReferenceClip flag: a compound clip (verified on 12.3), and by "
                     "the same flag a multicam or synchronized clip; isCompoundClip gives [compound clip], SpliceKit's "
                     "multicam probe [multicam clip]. One clip on the timeline whose contents are clips of their own: "
                     "get_clip_info reports no single source media file for it and get_audio_levels skips it; "
                     "timeline_action(\"openClip\") with it selected opens its own timeline.")

    return "\n".join(lines)


@splicekit_tool("list_markers")
def list_markers(kind: str = "") -> str:
    """List all markers on the current timeline with time, kind, name, completion, handle.

    Markers are gathered two ways and merged: the sequence's markersInTimeRange:
    query over the whole timeline, plus markers found anchored to spine and
    connected clips. Each marker's `timeSource` in the raw RPC says which path
    resolved its time.

    Args:
        kind: optional filter -- "standard", "todo" (FCP: to-do item), "chapter",
              "keyword" or "analysis" (keyword ranges / analysis keywords, listed
              as tags in FCP's Timeline Index). FCP calls this the marker type.

    Marker handles can be passed to timeline.directAction actions
    changeMarkerName / markMarkerCompleted / removeMarker (via the `marker` param).
    """
    params = {}
    if kind:
        params["kind"] = kind
    r = bridge.call("timeline.getMarkers", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Sequence: {r.get('sequenceName', '?')}"]
    count = r.get("markerCount", 0)
    lines.append(f"Markers: {count}" + (f" (kind={kind})" if kind else ""))
    if r.get("markersError"):
        lines.append(f"WARNING markers: {r['markersError']}")

    sources = r.get("markerSources") or {}
    markers = r.get("markers", []) or []
    if markers:
        lines.append("")
        lines.extend(_marker_table_lines(markers))
        if r.get("markersTruncated"):
            lines.append(f"(showing {len(markers)} of {r.get('markerTotal', '?')} markers)")
    else:
        if sources and not sources.get("sequenceRespondsToMarkersInTimeRange", True) \
                and not sources.get("anchoredWalk", 0):
            lines.append("No markers found: the sequence does not respond to markersInTimeRange: "
                         "and no markers were found on anchored items.")
        elif kind:
            lines.append(f"No markers of kind '{kind}'.")
        else:
            lines.append("No markers found.")
    if sources:
        lines.append(
            f"Sources: markersInTimeRange={sources.get('markersInTimeRange', 0)}, "
            f"anchoredWalk={sources.get('anchoredWalk', 0)}"
        )
    return "\n".join(lines)


@splicekit_tool("get_selected_clips")
def get_selected_clips() -> str:
    """Get only the currently selected clips in the timeline.
    Includes selected connected clips (titles, B-roll, music), marked with "connected": true.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    items = [i for i in r.get("items", []) if i.get("selected")]
    items += [dict(i, connected=True) for i in (r.get("connectedItems", []) or []) if i.get("selected")]
    if not items:
        return "No clips selected"
    return _fmt({"selectedCount": len(items), "items": items})


@splicekit_tool("set_timeline_range")
def set_timeline_range(start_seconds: float, end_seconds: float) -> str:
    """Set the timeline in/out range (mark in/out) to specific times in seconds.
    This positions the playhead and marks the range start and end points.
    Useful for defining export ranges or reviewing specific sections.
    """
    r = bridge.call("timeline.setRange", startSeconds=start_seconds, endSeconds=end_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if not r.get("rangeStartSet") or not r.get("rangeEndSet"):
        return (
            f"Error: failed to set timeline range "
            f"{r.get('startSeconds', start_seconds):.3f}s–"
            f"{r.get('endSeconds', end_seconds):.3f}s "
            f"(mark in: {'OK' if r.get('rangeStartSet') else 'FAILED'}, "
            f"mark out: {'OK' if r.get('rangeEndSet') else 'FAILED'})"
        )
    return (
        f"Range set: {r.get('startSeconds', 0):.3f}s - {r.get('endSeconds', 0):.3f}s\n"
        f"Mark in: OK\n"
        f"Mark out: OK"
    )


@splicekit_tool("batch_export")
def batch_export(scope: str = "all", folder: str = "") -> str:
    """Batch export every clip from the active timeline as individual files.
    A folder picker appears once, then all clips are exported automatically
    with effects/color grading baked in. No further interaction needed.

    If no folder path is given, FCP may open a modal save/open panel. While that
    panel is open the bridge cannot serve main-thread RPC; bridge_alive still
    responds. Save/open panels cannot be confirmed from the bridge — only
    dismiss_dialog(action=\"cancel\") closes them.

    Args:
        scope: "all" exports every clip, "selected" exports only selected clips
        folder: Optional output folder path. If empty, a folder picker dialog appears.
    """
    params = {"scope": scope}
    if folder:
        params["folder"] = folder
    r = bridge.call("timeline.batchExport", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "cancelled":
        return "Batch export cancelled by user."

    lines = [
        f"Batch export: {r.get('exported', 0)}/{r.get('total', 0)} clips queued",
        f"Folder: {r.get('folder', '?')}",
    ]
    clips = r.get("clips", [])
    for c in clips:
        start = c.get("startTime", {}).get("seconds", 0)
        end = c.get("endTime", {}).get("seconds", 0)
        lines.append(f"  [{c.get('status', '?')}] {c.get('name', '?')} ({start:.2f}s - {end:.2f}s)")
    return "\n".join(lines)


@splicekit_tool("verify_action")
def verify_action(description: str = "") -> str:
    """Capture timeline state for before/after verification.

    Call before an action, then after, and compare the snapshots.
    Returns: playhead_seconds, item_count, selected_count, timestamp.

    Args:
        description: A free-text label echoed back in the snapshot, so two snapshots can
            be told apart in a transcript ("before blade", "after blade"). It has no
            effect on what is captured and may be left out.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        # Fallback to basic state
        r = bridge.call("timeline.getState")
        if _err(r):
            return f"Error: {r.get('error', r)}"
    return _fmt({
        "playhead_seconds": r.get("playheadTime", {}).get("seconds", 0),
        "item_count": r.get("itemCount", 0),
        "selected_count": r.get("selectedCount", 0),
        "connected_count": r.get("connectedCount", 0),
        "marker_count": r.get("markerCount", 0),
        "sequence_name": r.get("sequenceName", ""),
        "description": description,
        "timestamp": time.time()
    })


# ============================================================
# Advanced Method Calling (with arguments)
# ============================================================
# The swiss army knife — call any ObjC method on any object.
# Use this when a specific tool doesn't exist for what you need.

@splicekit_tool("call_method_with_args")
def call_method_with_args(target: str, selector: str, args: str | list = "[]",
                          class_method: bool = True, return_handle: bool = False) -> str:
    """Call any ObjC method with typed arguments via NSInvocation.

    Args:
        target: ObjC class name (e.g. "FFLibraryDocument") or retained handle (e.g. "obj_3").
        selector: Method selector (e.g. "copyActiveLibraries" or "objectAtIndex:").
        args: JSON array of typed arguments as a string or Python list. Each element is
            ``{"type": "...", "value": ...}``. Types: string, int, double, float, bool,
            nil, sender, handle, cmtime, selector. cmtime value example:
            ``{"value": 30000, "timescale": 600}``.
        class_method: When True (default), call ``+[target selector]``; when False, call on the
            handle instance ``-[target selector]``.
        return_handle: When True, retain the returned object and include its handle in the response.

    Warnings:
      - Selectors with out-parameters (error:, askedRetry:, etc.) are invoked with the raw pointer
        bytes you pass in args. Passing [{"type":"nil"}] only works when the selector explicitly
        tolerates a null out pointer.
      - FFAnchoredSequence actionTrimDuration:forEdits:isDelta:error: is known to crash Final Cut
        on a constrained trim if error: is null.
      - If you need an NSArray argument, build it first via NSArray arrayWithObject: and pass the
        returned handle into the real call.

    Examples:
      call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
      call_method_with_args("obj_3", "displayName", "[]", false)
      call_method_with_args("obj_1", "objectAtIndex:", [{"type":"int","value":0}], false, true)
    """
    # Accept args as either a JSON string or a direct list
    if isinstance(args, list):
        parsed_args = args
    else:
        try:
            parsed_args = json.loads(args)
        except json.JSONDecodeError as e:
            return f"Invalid args JSON: {e}"

    # Safety rail: these selectors crash FCP when the error: out-pointer is nil
    unsafe_nil_error_selectors = {
        "actionTrimDuration:forEdits:isDelta:error:",
        "operationTrimDuration:forEdits:isDelta:error:",
    }
    if selector in unsafe_nil_error_selectors and parsed_args:
        last_arg = parsed_args[-1] if isinstance(parsed_args[-1], dict) else {}
        last_arg_type = last_arg.get("type", "nil")
        if last_arg_type == "nil":
            return (
                f"Refusing {selector} with a nil error: pointer. "
                "This selector is known to crash Final Cut when the trim is constrained. "
                "Use a dedicated safe wrapper instead."
            )

    r = bridge.call("system.callMethodWithArgs",
                    target=target, selector=selector, args=parsed_args,
                    classMethod=class_method, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Object Handles
# ============================================================
# The handle system lets you hold references to live ObjC objects
# across multiple tool calls. Think of handles as pointers that
# survive between requests. Always release_all when you're done.

@splicekit_tool("list_handles")
def list_handles() -> str:
    """Use this tool to inspect the currently retained bridge object handles."""
    return _handle_management_response("list")


@splicekit_tool("inspect_handle")
def inspect_handle(handle: str) -> str:
    """Inspect one retained bridge object handle: its class, description and key properties.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: The handle to inspect, e.g. "obj_3".
    """
    return _handle_management_response("inspect", handle)


@splicekit_tool("release_handle")
def release_handle(handle: str) -> str:
    """Release one retained bridge object handle when it is no longer needed.

    This frees SpliceKit's reference to the object. It does not delete anything in Final
    Cut Pro — the clip, marker or project the handle pointed at is untouched. Any other
    handle you still hold stays valid.

    Args:
        handle: The handle to release, e.g. "obj_3".
    """
    return _handle_management_response("release", handle)


@splicekit_tool("release_all_handles")
def release_all_handles() -> str:
    """Release every retained bridge object handle.

    Frees all of SpliceKit's references at once. Nothing in Final Cut Pro is deleted, but
    every handle you are holding stops resolving, so re-read anything you still need.
    """
    return _handle_management_response("release_all")


@splicekit_tool("get_object_property")
def get_object_property(handle: str, key: str, return_handle: bool = False) -> str:
    """Use this tool to inspect one property on a retained Objective-C object handle.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: Retained bridge handle (e.g. "obj_3").
        key: KVC key or property name (e.g. "displayName", "duration", "containedItems").
            Spelled exactly as the runtime has it; get_properties(class_name) lists them.
        return_handle: When True, retain the property value and return a new handle for it,
            instead of describing it. Use this to walk from one object to another.

    Example: get_object_property("obj_3", "displayName")
    """
    r = bridge.call("object.getProperty", handle=handle, key=key, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_object_property")
def set_object_property(handle: str, key: str, value: str, value_type: str = "string") -> str:
    """Set a property on an object handle using Key-Value Coding.

    WARNING: Direct KVC bypasses undo. For undoable edits, use timeline_action() instead.
    Nothing written here can be taken back with history_action("undo"), and writing a key
    Final Cut Pro did not expect can leave the document in a state it cannot save.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: Retained bridge handle whose property will be written.
        key: KVC key or property name, spelled exactly as the runtime has it.
        value: Value as a string; converted using value_type before sending to the bridge.
        value_type: One of string, int, double, bool, nil (default string).
    """
    # Convert the string value to the correct Python type before sending to the bridge
    val_spec = {"type": value_type, "value": value}
    if value_type == "int":
        val_spec["value"] = int(value)
    elif value_type == "double":
        val_spec["value"] = float(value)
    elif value_type == "bool":
        val_spec["value"] = value.lower() in ("true", "1", "yes")
    r = bridge.call("object.setProperty", handle=handle, key=key, value=val_spec)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# FCPXML Import & Generation
# ============================================================
# FCPXML is Apple's interchange format for FCP projects. We can
# generate it programmatically and import it to create complex
# timelines without clicking through FCP's UI.

@splicekit_tool("import_fcpxml")
def import_fcpxml(xml: str, internal: bool = True) -> str:
    """Import FCPXML into FCP. If internal=True, uses PEAppController's import method
    (imports into the running instance without restart). If internal=False, opens via NSWorkspace.
    Provide valid FCPXML as a string.
    """
    r = bridge.call("fcpxml.import", xml=xml, internal=internal)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("import_url")
def import_url(url: str, mode: str = "import_only", target_event: str = "",
               title: str = "", highest_quality: bool = False,
               wait_until_complete: bool = True) -> str:
    """Download a remote media URL, import it into Final Cut Pro, and optionally
    place it into the active timeline.

    Args:
        url: Direct media URL (.mp4, .mov, .m4v, .webm) or a supported provider URL
            like YouTube or Vimeo.
        mode: "import_only", "insert_at_playhead", or "append_to_timeline".
        target_event: Optional event name override.
        title: Optional clip title override.
        highest_quality: If True, fetch the highest available resolution from
            YouTube/Vimeo (1080p/1440p/4K via VP9/AV1 when needed). Default False
            downloads the best progressive mp4 (typically 720p) for faster imports.
        wait_until_complete: If False, returns immediately with a job_id that can
            be polled via import_url_status().

    Notes:
        Provider URLs rely on yt-dlp + ffmpeg being available to the modded app.
    """
    params = {"url": url, "mode": mode}
    if target_event:
        params["target_event"] = target_event
    if title:
        params["title"] = title
    if highest_quality:
        params["highest_quality"] = True

    method = "urlImport.import" if wait_until_complete else "urlImport.start"
    r = bridge.call(method, **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("import_url_status")
def import_url_status(job_id: str) -> str:
    """Check the current status of a URL import job."""
    r = bridge.call("urlImport.status", job_id=job_id)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("cancel_import_url")
def cancel_import_url(job_id: str) -> str:
    """Cancel an in-flight URL import job."""
    r = bridge.call("urlImport.cancel", job_id=job_id)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_fcpxml")
def generate_fcpxml(event_name: str = "SpliceKit Event", project_name: str = "SpliceKit Project",
                    frame_rate: str = "24", width: int = 1920, height: int = 1080,
                    items: str = "[]") -> str:
    """Generate valid FCPXML for import using OpenTimelineIO.

    Builds an OTIO Timeline from the provided items, then serializes to FCPXML
    via the otio-fcpx-xml-adapter. Title and transition items (which OTIO doesn't
    model natively) are injected as FCPXML-specific post-processing.

    Args:
        event_name: FCP event name embedded in the FCPXML (default "SpliceKit Event").
        project_name: Sequence/project name in the FCPXML (default "SpliceKit Project").
        frame_rate: Timeline frame rate as a string: 23.976, 24, 25, 29.97, 30, 48, 50,
            59.94, or 60 (default "24").
        width: Project raster width in pixels (default 1920).
        height: Project raster height in pixels (default 1080).
        items: JSON array of timeline items (string). Each item:
      {"type": "gap", "duration": 5.0}
      {"type": "gap", "duration": 5.0, "name": "My Gap"}
      {"type": "title", "text": "Hello World", "duration": 5.0}
      {"type": "title", "text": "Lower Third", "duration": 3.0, "position": "lower-third"}
      {"type": "marker", "time": 2.5, "name": "Review Here", "kind": "standard"}
      {"type": "marker", "time": 5.0, "name": "Chapter 1", "kind": "chapter"}
      {"type": "transition", "duration": 1.0}

    Returns the FCPXML string. Pass to import_fcpxml() or import_otio() to load into FCP.

    Example:
      xml = generate_fcpxml(project_name="Test", items='[
        {"type":"gap","duration":5},
        {"type":"transition","duration":1},
        {"type":"title","text":"Hello","duration":3},
        {"type":"gap","duration":5},
        {"type":"marker","time":2,"name":"Start","kind":"chapter"}
      ]')
      import_fcpxml(xml, internal=True)
    """
    try:
        item_list = json.loads(items)
    except json.JSONDecodeError:
        item_list = []

    # Frame rate string → numeric fps for OTIO RationalTime
    fps_map = {
        "23.976": 23.98, "24": 24, "25": 25, "29.97": 29.97,
        "30": 30, "48": 48, "50": 50, "59.94": 59.94, "60": 60,
    }
    fps = fps_map.get(frame_rate, 24)

    # Separate spine items, markers, titles, and transitions
    spine_items = [i for i in item_list if i.get("type") in ("gap", "title", "transition", None)]
    markers = [i for i in item_list if i.get("type") == "marker"]

    if not spine_items:
        spine_items = [{"type": "gap", "duration": 10.0}]

    # Keep the direct builder for title/transition synthesis. The custom `items`
    # input schema is intentionally tiny and relies on FCP-specific defaults.
    has_fcpxml_only_items = any(i.get("type") in ("title", "transition") for i in spine_items)

    if has_fcpxml_only_items:
        # Fall back to direct FCPXML construction for full feature support
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    # Build OTIO Timeline from items
    try:
        import opentimelineio as otio
        from opentimelineio import opentime
    except ImportError:
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    timeline = otio.schema.Timeline(name=project_name)
    track = otio.schema.Track(name="V1", kind=otio.schema.TrackKind.Video)

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        frames = round(idur * fps)

        if itype == "gap":
            gap = otio.schema.Gap(
                source_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(0, fps),
                    duration=opentime.RationalTime(frames, fps)
                )
            )
            track.append(gap)

    timeline.tracks.append(track)

    # Add markers to the first gap/clip (OTIO attaches markers to items, not the sequence)
    marker_color_map = {
        "standard": otio.schema.MarkerColor.PURPLE,
        "todo": otio.schema.MarkerColor.RED,
        "chapter": otio.schema.MarkerColor.GREEN,
    }
    if markers and len(track) > 0:
        for m in markers:
            mt = m.get("time", 0)
            mname = m.get("name", "Marker")
            mkind = m.get("kind", "standard")
            mdur = m.get("duration", 1.0 / fps)
            marker = otio.schema.Marker(
                name=mname,
                marked_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(round(mt * fps), fps),
                    duration=opentime.RationalTime(max(1, round(mdur * fps)), fps)
                ),
                color=marker_color_map.get(mkind, otio.schema.MarkerColor.PURPLE)
            )
            track[0].markers.append(marker)

    # Serialize to FCPXML via the adapter
    try:
        xml = _otio_write_fcpx_string(timeline)
    except Exception as e:
        # Fall back to direct construction on adapter failure
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    return xml


def _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers):
    """Direct FCPXML string construction for items that OTIO can't model (titles, transitions)."""
    fr_map = {
        "23.976": (1001, 24000), "24": (100, 2400), "25": (100, 2500),
        "29.97": (1001, 30000), "30": (100, 3000), "48": (100, 4800),
        "50": (100, 5000), "59.94": (1001, 60000), "60": (100, 6000),
    }
    fd_num, fd_den = fr_map.get(frame_rate, (100, 2400))
    fd_str = f"{fd_num}/{fd_den}s"

    def dur_rational(seconds):
        frames = round(seconds * fd_den / fd_num)
        return f"{frames * fd_num}/{fd_den}s"

    spine_xml = ""
    offset_seconds = 0.0
    total_seconds = 0.0
    ts_counter = 1

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        iname = item.get("name", "")
        dur_str = dur_rational(idur)
        off_str = dur_rational(offset_seconds)

        if itype == "gap":
            gap_name = iname or "Gap"
            spine_xml += f'            <gap name="{gap_name}" offset="{off_str}" duration="{dur_str}" start="3600s"/>\n'
        elif itype == "title":
            text = item.get("text", "Title")
            title_name = iname or text
            font_size = "63" if item.get("position") != "lower-third" else "42"
            ts_id = f"ts{ts_counter}"
            ts_counter += 1
            spine_xml += f'''            <title name="{title_name}" offset="{off_str}" duration="{dur_str}" start="3600s">
                <text><text-style ref="{ts_id}">{text}</text-style></text>
                <text-style-def id="{ts_id}"><text-style font="Helvetica" fontSize="{font_size}" fontColor="1 1 1 1"/></text-style-def>
            </title>\n'''
        elif itype == "transition":
            spine_xml += f'            <transition name="Cross Dissolve" offset="{off_str}" duration="{dur_str}"/>\n'

        offset_seconds += idur
        total_seconds += idur

    total_dur_str = dur_rational(total_seconds)

    markers_xml = ""
    for m in markers:
        mt = m.get("time", 0)
        mname = m.get("name", "Marker")
        mkind = m.get("kind", "standard")
        moff = dur_rational(mt)
        mdur = dur_rational(m.get("duration", 0) if m.get("duration") else fd_num / fd_den)
        if mkind == "chapter":
            markers_xml += f'            <chapter-marker start="{moff}" duration="{mdur}" value="{mname}" posterOffset="0s"/>\n'
        elif mkind == "todo":
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}" completed="0"/>\n'
        else:
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}"/>\n'

    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.14">
    <resources>
        <format id="r1" name="FFVideoFormat{width}x{height}p{frame_rate}" frameDuration="{fd_str}" width="{width}" height="{height}"/>
    </resources>
    <library>
        <event name="{event_name}">
            <project name="{project_name}">
                <sequence format="r1" duration="{total_dur_str}" tcStart="0s" tcFormat="NDF">
                    <spine>
{spine_xml}                    </spine>
{markers_xml}                </sequence>
            </project>
        </event>
    </library>
</fcpxml>'''


# ============================================================
# Effects & Color Correction
# ============================================================
# Tools for inspecting and applying effects on clips.

@splicekit_tool("get_clip_effects")
def get_clip_effects(handle: str = "") -> str:
    """Get the effects applied to a clip. If no handle provided, uses the first selected clip.
    Returns effect names, IDs, classes, and handles for further inspection.
    """
    params = {}
    if handle:
        params["handle"] = handle
    r = bridge.call("effects.getClipEffects", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Clip: {r.get('clipName', '?')} ({r.get('clipClass', '?')})"]
    effects = r.get("effects", [])
    lines.append(f"Effects: {r.get('effectCount', len(effects))}")
    for ef in effects:
        lines.append(f"  {ef.get('name', '?')} ({ef.get('class', '?')}) ID={ef.get('effectID', '')} handle={ef.get('handle', '')}")

    if r.get("effectStackHandle"):
        lines.append(f"\nEffect stack handle: {r['effectStackHandle']}")

    return "\n".join(lines)


# ============================================================
# Batch Operations
# ============================================================
# Lets the AI chain many small edits in one round-trip instead
# of making a separate tool call for each step.

@splicekit_tool("batch_timeline_actions")
def batch_timeline_actions(actions: str, undo_name: str = "Batch Actions") -> str:
    """Execute multiple timeline/playback actions in sequence.
    Much more efficient than calling individual tools.

    When the batch includes any timeline action, the whole run is wrapped in one
    undo step (timeline.beginEdit / timeline.endEdit), so Edit > Undo reverts
    every timeline mutation in the batch with a single undo.

    actions: JSON array of action objects. Each action:
      {"type": "timeline", "action": "blade"}
      {"type": "playback", "action": "nextFrame"}
      {"type": "playback", "action": "nextFrame", "repeat": 30}
      {"type": "wait", "seconds": 0.5}

    undo_name: Edit > Undo menu name when a group is opened (default "Batch Actions").

    Example: blade at 3 positions:
      batch_timeline_actions('[
        {"type":"playback","action":"goToStart"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"}
      ]')
    """
    try:
        action_list = json.loads(actions)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    has_timeline_actions = any(
        act.get("type", "timeline") == "timeline" for act in action_list
    )
    undo_group_opened = False
    begin_edit_note: str | None = None
    if has_timeline_actions:
        r = bridge.call("timeline.beginEdit", name=undo_name)
        if _err(r):
            begin_edit_note = (
                f"Note: could not open undo group ({r.get('error', r)}); "
                "timeline actions are not grouped."
            )
        else:
            undo_group_opened = True

    results = []
    errors = 0
    try:
        for i, act in enumerate(action_list):
            act_type = act.get("type", "timeline")
            action_name = act.get("action", "")
            repeat = act.get("repeat", 1)

            if act_type == "wait":
                secs = act.get("seconds", 0.5)
                time.sleep(secs)
                results.append(f"[{i}] wait {secs}s -> OK")
            elif act_type == "playback":
                r = None
                for _ in range(repeat):
                    r = bridge.call("playback.action", action=action_name)
                label = f"[{i}] playback.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
                if r and _err(r):
                    errors += 1
                    results.append(f"{label} -> FAILED: {r.get('error', '?')}")
                else:
                    results.append(f"{label} -> OK")
            elif act_type == "timeline":
                r = None
                for _ in range(repeat):
                    r = bridge.call("timeline.action", action=action_name)
                label = f"[{i}] timeline.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
                if r and _err(r):
                    errors += 1
                    results.append(f"{label} -> FAILED: {r.get('error', '?')}")
                else:
                    results.append(f"{label} -> OK")
            else:
                errors += 1
                results.append(f"[{i}] unknown type: {act_type} -> SKIPPED")
    finally:
        if undo_group_opened:
            bridge.call("timeline.endEdit", name=undo_name)

    summary = f"Executed {len(action_list)} actions"
    if errors:
        summary += f" ({errors} failed)"
    # The colon introduces the per-action lines. It belongs on this line: appending
    # it after the undo-group line produced "Undo group: Batch Actions:".
    summary += ":"
    if undo_group_opened:
        summary += f"\nUndo group: {undo_name}"
    if begin_edit_note:
        summary += f"\n{begin_edit_note}"
    return summary + "\n" + "\n".join(results)


# ============================================================
# Timeline Analysis
# ============================================================
# Computes statistics the AI can use to understand the timeline
# before suggesting edits (pacing, flash frames, etc).

@splicekit_tool("analyze_timeline")
def analyze_timeline() -> str:
    """Analyze the current timeline: duration, clip count, pacing stats,
    potential issues (short clips, gaps). Returns a structured report.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    # Split items into clips vs transitions for separate stats
    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    # Flag potential problems: flash frames (<0.5s) and overly long shots (>30s)
    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    # Pacing: compare average clip length in the first vs last quarter
    # to detect if the edit is accelerating or decelerating over time
    pacing = ""
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "Accelerating (cuts getting faster)"
        elif q4_avg > q1_avg * 1.3:
            pacing = "Decelerating (cuts getting slower)"
        else:
            pacing = "Steady"

    lines = [
        f"=== Timeline Analysis ===",
        f"Sequence: {r.get('sequenceName', '?')}",
        f"Duration: {total_dur:.1f}s ({total_dur/60:.1f}min)",
        f"Playhead: {playhead:.1f}s",
        f"",
        f"Clips: {len(clips)}",
        f"Transitions: {len(transitions)}",
        f"Avg clip duration: {avg_dur:.2f}s",
        f"Shortest clip: {min_dur:.2f}s",
        f"Longest clip: {max_dur:.2f}s",
    ]

    if pacing:
        lines.append(f"Pacing: {pacing}")

    # Issues
    issues = []
    if short_clips:
        issues.append(f"Flash frames: {len(short_clips)} clips < 0.5s")
    if long_clips:
        issues.append(f"Long clips: {len(long_clips)} clips > 30s")

    if issues:
        lines.append(f"\nPotential issues:")
        for issue in issues:
            lines.append(f"  - {issue}")
    else:
        lines.append(f"\nNo issues detected")

    return "\n".join(lines)


# ============================================================
# SRT/Transcript to Markers
# ============================================================
# Bulk marker placement. The bridge handles seeking internally
# so we don't have to move the playhead for each marker.

@splicekit_tool("add_markers_at_times")
def add_markers_at_times(markers: str) -> str:
    """Add multiple markers at specific times in a single batch call.
    Much faster than seeking + adding markers one at a time.

    markers accepts either:
      - JSON array of marker objects, e.g.
        [{"time": 5.0, "name": "Scene 1", "kind": "standard"},
         {"time": 15.5, "name": "Chapter 1", "kind": "chapter"}]
      - Comma-separated seconds for plain standard markers, e.g. "5.0, 12.0"

    kind (JSON form only): "standard" (default), "chapter", or "todo"

    Returns count of markers successfully added.
    """
    marker_list = _parse_markers_list(markers)

    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Added {r.get('applied', 0)}/{r.get('count', 0)} markers"]
    for m in r.get("markers", []):
        status = "OK" if m.get("success") else f"FAILED: {m.get('error', '?')}"
        lines.append(f"  {m['time']:.2f}s -> {status}")
    return "\n".join(lines)


@splicekit_tool("blade_at_times")
def blade_at_times(times: str) -> str:
    """Blade (cut) the timeline at multiple specific times in a single batch call.
    Much faster than seeking + blading one at a time.

    times accepts either:
      - JSON array of seconds, e.g. [3.0, 6.0, 9.0, 12.0, 15.0]
      - Comma-separated seconds, e.g. "3.0, 6.0, 9.0" or a single value "25.0"

    Returns count of cuts successfully applied.
    """
    time_list = _parse_seconds_list(times)

    r = bridge.call("timeline.bladeAtTimes", times=time_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Applied {r.get('applied', 0)}/{r.get('count', 0)} cuts"]
    for c in r.get("cuts", []):
        status = "OK" if c.get("success") else f"FAILED: {c.get('error', '?')}"
        lines.append(f"  {c['time']:.2f}s -> {status}")
    return "\n".join(lines)


@splicekit_tool("trim_clips_to_beats")
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


@splicekit_tool("sync_clips_to_song_beats")
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


@splicekit_tool("build_song_cut")
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


@splicekit_tool("assemble_random_clips_to_song_beats")
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


@splicekit_tool("import_srt_as_markers")
def import_srt_as_markers(srt_content: str) -> str:
    """Import SRT subtitle content as markers in the current timeline.
    Each subtitle becomes a standard marker at the corresponding timecode.

    srt_content: SRT file content as string. Example:
      1
      00:00:05,000 --> 00:00:10,000
      Hello world

      2
      00:01:30,500 --> 00:01:35,000
      Second subtitle
    """
    import re

    # Parse SRT format: sequential blocks of "index / timestamp / text"
    blocks = re.split(r'\n\n+', srt_content.strip())
    marker_list = []

    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:  # need at least: index line, timestamp line, text line
            continue

        # We only use the start time -- FCP markers are points, not ranges
        ts_match = re.match(r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})', lines[1])
        if not ts_match:
            continue

        h, m, s, ms = int(ts_match.group(1)), int(ts_match.group(2)), int(ts_match.group(3)), int(ts_match.group(4))
        total_seconds = h * 3600 + m * 60 + s + ms / 1000.0
        text = ' '.join(lines[2:]).strip()

        marker_list.append({"time": total_seconds, "name": text, "kind": "standard"})

    if not marker_list:
        return "No valid SRT entries found"

    # Single batch call to add all markers at once (no playhead movement needed)
    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    applied = r.get("applied", 0)
    result = f"Imported {applied}/{len(marker_list)} markers from SRT"
    failed = [m for m in r.get("markers", []) if not m.get("success")]
    if failed:
        result += f"\nFailed: {len(failed)}"
        for m in failed[:5]:
            result += f"\n  - {m['time']:.1f}s: {m.get('error', '?')}"
    return result


# ============================================================
# Library & Project Management
# ============================================================
# Thin wrappers around FCP's FFLibraryDocument class methods.

@splicekit_tool("get_active_libraries")
def get_active_libraries() -> str:
    """Get list of currently open libraries in FCP."""
    from urllib.parse import unquote, urlparse

    def _objc(target, selector, args=None, return_handle=False):
        return bridge.call(
            "system.callMethodWithArgs",
            target=target,
            selector=selector,
            args=args or [],
            classMethod=False,
            returnHandle=return_handle,
        )

    r = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                    selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    array_handle = r.get("handle")
    if not array_handle:
        return "No libraries are open."

    lib_handles = []
    count = None
    try:
        cr = _objc(array_handle, "count")
        if not _err(cr) and cr.get("result") is not None:
            count = int(cr["result"])
    except (TypeError, ValueError):
        count = None

    if count is not None:
        if count == 0:
            return "No libraries are open."
        for i in range(count):
            lr = _objc(
                array_handle,
                "objectAtIndex:",
                [{"type": "int", "value": i}],
                return_handle=True,
            )
            lib_handles.append(lr.get("handle") if not _err(lr) else None)
    else:
        i = 0
        while i < 256:
            lr = _objc(
                array_handle,
                "objectAtIndex:",
                [{"type": "int", "value": i}],
                return_handle=True,
            )
            if _err(lr) or not lr.get("handle"):
                break
            lib_handles.append(lr["handle"])
            i += 1
        count = len(lib_handles)

    if count == 0:
        return "No libraries are open."

    lines = [f"Open libraries ({count}):"]
    for lib_handle in lib_handles:
        name = None
        path = None
        unread = []
        if not lib_handle:
            lines.append("  (could not read library entry)")
            continue
        try:
            nr = _objc(lib_handle, "displayName")
            if _err(nr):
                unread.append("name")
            else:
                name = nr.get("result")
        except Exception:
            unread.append("name")
        try:
            ur = _objc(lib_handle, "URL")
            if _err(ur):
                unread.append("path")
            else:
                url_str = ur.get("result") or ""
                if url_str:
                    parsed = urlparse(str(url_str))
                    path = unquote(parsed.path).rstrip("/")
        except Exception:
            unread.append("path")
        if name and path:
            line = f"  {name} — {path}"
        elif name:
            line = f"  {name}"
        elif path:
            line = f"  (unnamed) — {path}"
        else:
            line = "  (library)"
        if unread:
            line += f" (could not read: {', '.join(unread)})"
        try:
            ir = _objc(lib_handle, "isUpdating")
            if not _err(ir) and ir.get("result"):
                line += " [updating]"
        except Exception:
            pass
        try:
            idr = _objc(lib_handle, "uniqueIdentifier")
            if not _err(idr) and idr.get("result"):
                line += f"  id={idr['result']}"
        except Exception:
            pass
        lines.append(line)
    return "\n".join(lines)


@splicekit_tool("is_library_updating")
def is_library_updating() -> str:
    """Check if any library is currently being updated/saved."""
    r = bridge.call("system.callMethod", className="FFLibraryDocument",
                    selector="isAnyLibraryUpdating", classMethod=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Runtime Introspection
# ============================================================
# Reverse-engineering tools — enumerate classes, explore methods,
# inspect the class hierarchy. Use these to discover new APIs.

@splicekit_tool("get_classes")
def get_classes(filter: str = "") -> str:
    """List ObjC classes loaded in FCP's process.

    Args:
        filter: Case-insensitive substring to match against the class names. Left out, it
            lists everything, which is tens of thousands of classes — pass a prefix.
            Common prefixes: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getClasses", filter=filter) if filter else bridge.call("system.getClasses")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    classes = r.get("classes", [])
    count = r.get("count", len(classes))
    if count > 200:
        return f"Found {count} classes matching '{filter}'. Showing first 200:\n" + "\n".join(classes[:200])
    return f"Found {count} classes:\n" + "\n".join(classes)


@splicekit_tool("get_methods")
def get_methods(class_name: str, include_super: bool = False) -> str:
    """List all methods on an ObjC class with type encodings.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
        include_super: Also list methods inherited from superclasses. Default False.
    """
    r = bridge.call("system.getMethods", className=class_name, includeSuper=include_super)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"=== {class_name} ==="]
    lines.append(f"\nInstance methods ({r.get('instanceMethodCount', 0)}):")
    for name in sorted(r.get("instanceMethods", {}).keys()):
        info = r["instanceMethods"][name]
        lines.append(f"  - {name}  ({info.get('typeEncoding', '')})")
    lines.append(f"\nClass methods ({r.get('classMethodCount', 0)}):")
    for name in sorted(r.get("classMethods", {}).keys()):
        info = r["classMethods"][name]
        lines.append(f"  + {name}  ({info.get('typeEncoding', '')})")
    return "\n".join(lines)


@splicekit_tool("get_properties")
def get_properties(class_name: str) -> str:
    """List declared @property definitions on an ObjC class.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getProperties", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} properties"]
    for p in r.get("properties", []):
        lines.append(f"  {p['name']}: {p['attributes']}")
    return "\n".join(lines)


@splicekit_tool("get_ivars")
def get_ivars(class_name: str) -> str:
    """List instance variables of an ObjC class with their types.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getIvars", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} ivars"]
    for iv in r.get("ivars", []):
        lines.append(f"  {iv['name']}: {iv['type']}")
    return "\n".join(lines)


@splicekit_tool("get_protocols")
def get_protocols(class_name: str) -> str:
    """List protocols adopted by an ObjC class.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getProtocols", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return f"{class_name}: {r.get('count', 0)} protocols\n" + "\n".join(f"  {p}" for p in r.get("protocols", []))


@splicekit_tool("get_superchain")
def get_superchain(class_name: str) -> str:
    """Get the inheritance chain for an ObjC class, from it up to NSObject.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getSuperchain", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return " -> ".join(r.get("superchain", []))


@splicekit_tool("explore_class")
def explore_class(class_name: str) -> str:
    """Comprehensive overview of an ObjC class: inheritance, protocols, properties, ivars, key methods.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    lines = [f"=== {class_name} ===\n"]
    r = bridge.call("system.getSuperchain", className=class_name)
    if not _err(r):
        lines.append("Inheritance: " + " -> ".join(r.get("superchain", [])))
    r = bridge.call("system.getProtocols", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProtocols ({r['count']}): " + ", ".join(r.get("protocols", [])))
    r = bridge.call("system.getProperties", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProperties ({r['count']}):")
        for p in r.get("properties", [])[:30]:
            lines.append(f"  {p['name']}")
    r = bridge.call("system.getIvars", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nIvars ({r['count']}):")
        for iv in r.get("ivars", [])[:15]:
            lines.append(f"  {iv['name']}: {iv['type']}")
    r = bridge.call("system.getMethods", className=class_name)
    if not _err(r):
        im = r.get("instanceMethodCount", 0)
        cm = r.get("classMethodCount", 0)
        lines.append(f"\nMethods: {im} instance, {cm} class")
        if cm > 0:
            lines.append(f"\nClass methods:")
            for name in sorted(r.get("classMethods", {}).keys()):
                lines.append(f"  + {name}")
        # Surface the most interesting methods -- the ones an AI is likely to want to call
        keywords = ['get', 'set', 'current', 'active', 'selected', 'add', 'remove',
                    'create', 'delete', 'open', 'close', 'name', 'items', 'clip', 'effect', 'marker']
        notable = [m for m in sorted(r.get("instanceMethods", {}).keys()) if any(k in m.lower() for k in keywords)]
        if notable:
            lines.append(f"\nNotable instance methods ({len(notable)} of {im}):")
            for m in notable[:50]:
                lines.append(f"  - {m}")
    return "\n".join(lines)


@splicekit_tool("search_methods")
def search_methods(class_name: str, keyword: str) -> str:
    """Search for methods on a class by keyword.

    This, and get_methods(), are the only acceptable evidence that a selector exists on
    this build of Final Cut Pro. Do not assume one from a header, a disassembly or
    another version.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
        keyword: Case-insensitive substring to match against the method names.
    """
    r = bridge.call("system.getMethods", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = []
    for name in sorted(r.get("instanceMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  - {name}  ({r['instanceMethods'][name].get('typeEncoding', '')})")
    for name in sorted(r.get("classMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  + {name}  ({r['classMethods'][name].get('typeEncoding', '')})")
    if not lines:
        return f"No methods matching '{keyword}' on {class_name}"
    return f"Methods matching '{keyword}' on {class_name} ({len(lines)}):\n" + "\n".join(lines)


# -- Low-level escape hatches for arbitrary ObjC calls --

@splicekit_tool("call_method")
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method. For methods WITH arguments, use call_method_with_args instead.

    Args:
        class_name: ObjC class name (e.g. "FFLibraryDocument").
        selector: Zero-argument selector (e.g. "copyActiveLibraries").
        class_method: When True (default), invoke the class method ``+[class_name selector]``;
            when False, not supported here — use call_method_with_args with a handle target.
    """
    r = bridge.call("system.callMethod", className=class_name, selector=selector, classMethod=class_method)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("raw_call")
def raw_call(method: str, params: str = "{}") -> str:
    """Send a raw JSON-RPC call to SpliceKit. Last resort when no other tool fits.

    Args:
        method: Bridge RPC method name (e.g. "timeline.getState").
        params: JSON object string of keyword arguments for that method (default "{}").
    """
    try:
        p = json.loads(params)
    except json.JSONDecodeError as e:
        return f"Invalid JSON params: {e}"
    r = bridge.call(method, **p)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Transcript-Based Editing
# ============================================================
# Text-based editing: transcribe clips, then edit the video by
# editing the text. Delete words to remove video segments,
# drag words to reorder clips.

@splicekit_tool("open_transcript")
def open_transcript(file_url: str = "", force_retranscribe: bool = False) -> str:
    """Open the transcript panel and start transcribing.

    If no file_url is provided, transcribes all clips on the current timeline.
    If file_url is provided, transcribes that specific audio/video file.

    By default, if a persisted transcript exists it will be restored without
    re-running analysis. Set force_retranscribe=True to discard the cache
    and run a fresh transcription.

    The transcript panel allows text-based editing:
    - Clicking a word jumps the playhead to that time
    - Deleting words removes those segments from the timeline
    - Dragging words reorders clips on the timeline

    Transcription is async - use get_transcript() to check progress and results.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if force_retranscribe:
        params["forceRetranscribe"] = True
    r = bridge.call("transcript.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("get_transcript")
def get_transcript() -> str:
    """Get the current transcript state, including all words with timestamps, speakers, and silences.

    Returns:
    - status: idle/transcribing/ready/error
    - wordCount: number of transcribed words
    - silenceCount: number of detected pauses/silences
    - text: full transcript text (with segment headers and silence markers)
    - words: array of {index, text, startTime, endTime, duration, confidence, speaker}
    - silences: array of {startTime, endTime, duration, startTimecode, endTimecode}
    - progress: {completed, total} when transcribing

    Use this after open_transcript() to check when transcription is complete
    and to get the word list for editing operations.
    """
    r = bridge.call("transcript.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Format nicely
    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Silences: {r.get('silenceCount', 0)}")
    lines.append(f"Silence threshold: {r.get('silenceThreshold', 0.3):.1f}s")

    if r.get('gapBuckets'):
        gb = r['gapBuckets']
        buckets = ' | '.join(f">={k}: {gb[k]}" for k in sorted(gb.keys()))
        lines.append(f"Gap histogram: {buckets}")

    if r.get('progress'):
        p = r['progress']
        lines.append(f"Progress: {p.get('completed', 0)}/{p.get('total', 0)} clips")

    if r.get('text'):
        text = r['text']
        if len(text) > 2000:
            text = text[:2000] + "..."
        lines.append(f"\nTranscript:\n{text}")

    if r.get('silences'):
        lines.append(f"\nSilences ({len(r['silences'])} pauses):")
        for s in r['silences']:
            lines.append(f"  {s.get('startTimecode', '?')} - {s.get('endTimecode', '?')} "
                         f"({s['duration']:.1f}s) after word [{s.get('afterWordIndex', '?')}]")

    if r.get('words'):
        lines.append(f"\nWord list ({len(r['words'])} words):")
        for w in r['words']:
            conf = w.get('confidence', 0) * 100
            speaker = w.get('speaker', 'Unknown')
            lines.append(f"  [{w['index']:3d}] {w['startTime']:7.2f}s - {w['endTime']:7.2f}s "
                         f"({conf:3.0f}%) [{speaker}] \"{w['text']}\"")

    # The bridge reports the failure reason in `errorMessage` (see
    # SpliceKitTranscriptPanel getState). Reading only `error` meant every failed
    # transcription came back as a bare "Status: error" with no explanation,
    # which is indistinguishable from the feature being broken.
    detail = r.get('errorMessage') or r.get('error')
    if detail:
        lines.append(f"\nError: {detail}")
    elif r.get('status') == 'error':
        lines.append("\nError: transcription failed, but the bridge reported no reason. "
                     "Check the SpliceKit log panel in Final Cut Pro for [Transcript] lines.")

    return "\n".join(lines)


@splicekit_tool("delete_transcript_words")
def delete_transcript_words(start_index: int, count: int) -> str:
    """Delete words from the transcript, which removes the corresponding video segments.

    This performs a ripple delete on the timeline:
    1. Blades at the start time of the first word
    2. Blades at the end time of the last word
    3. Selects and deletes the segment between the blades

    Args:
        start_index: Index of the first word to delete (from get_transcript word list)
        count: Number of consecutive words to delete

    The timeline gap closes automatically (ripple delete).
    Use timeline_action("undo") to reverse.
    """
    r = bridge.call("transcript.deleteWords", startIndex=start_index, count=count)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("move_transcript_words")
def move_transcript_words(start_index: int, count: int, dest_index: int) -> str:
    """Move words in the transcript to a new position, which reorders clips on the timeline.

    This performs a cut-and-paste on the timeline:
    1. Blades at source start/end to isolate the segment
    2. Cuts the segment
    3. Moves playhead to the destination position
    4. Pastes the segment

    Args:
        start_index: Index of the first word to move
        count: Number of consecutive words to move
        dest_index: Target position in the word list (the words will be inserted before this index)

    Use timeline_action("undo") to reverse.
    """
    r = bridge.call("transcript.moveWords", startIndex=start_index, count=count, destIndex=dest_index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("close_transcript")
def close_transcript() -> str:
    """Close the transcript panel."""
    r = bridge.call("transcript.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Transcript panel closed."


@splicekit_tool("search_transcript")
def search_transcript(query: str) -> str:
    """Search the transcript for text or special keywords.

    Args:
        query: Search text to find in the transcript.
               Special keywords: "pauses" or "silences" to find all detected pauses.

    Returns matching words or silences with timestamps.
    Also updates the UI to highlight matches.
    """
    r = bridge.call("transcript.search", query=query)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Query: {r.get('query', query)}"]
    lines.append(f"Results: {r.get('resultCount', 0)}")

    results = r.get("results", [])
    for res in results:
        if res.get("type") == "silence":
            lines.append(f"  [Pause] {res['startTime']:.2f}s - {res['endTime']:.2f}s ({res['duration']:.1f}s)")
        else:
            lines.append(f"  [{res.get('index', '?'):3d}] {res['startTime']:.2f}s - {res['endTime']:.2f}s "
                         f"({res.get('confidence', 0)*100:.0f}%) \"{res.get('text', '')}\"")

    return "\n".join(lines)


@splicekit_tool("delete_transcript_silences")
def delete_transcript_silences(min_duration: float = 0.0) -> str:
    """Delete all detected silences/pauses from the timeline.

    This performs batch ripple-deletes on all silence gaps, removing dead air
    from the video. Silences are deleted from end to start to maintain accuracy.

    Args:
        min_duration: Minimum silence duration in seconds to delete. Default 0 = all silences.
                      Use 0.5 to only delete pauses longer than half a second, etc.

    Use timeline_action("undo") repeatedly to reverse.
    """
    r = bridge.call("transcript.deleteSilences", minDuration=min_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Deleted: {r.get('deletedCount', 0)}/{r.get('totalSilences', 0)} silences")
    if r.get("lastError"):
        lines.append(f"Last error: {r['lastError']}")

    return "\n".join(lines)


@splicekit_tool("set_transcript_speaker")
def set_transcript_speaker(start_index: int, count: int, speaker: str) -> str:
    """Assign a speaker name to a range of words in the transcript.

    Args:
        start_index: Index of the first word to label
        count: Number of consecutive words to label
        speaker: Speaker name (e.g., "Host", "Guest", "Speaker 1")

    This updates the speaker labels in the transcript display.
    """
    r = bridge.call("transcript.setSpeaker", speaker=speaker, startIndex=start_index, count=count)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_silence_threshold")
def set_silence_threshold(threshold: float) -> str:
    """Set the minimum gap duration (seconds) to detect as a silence/pause.

    Args:
        threshold: Duration in seconds. Default is 0.3 (300ms).
                   Lower values detect shorter pauses, higher values only long ones.

    Takes effect immediately — silences are recomputed from existing word
    timings without re-transcription. Returns the updated silence count.
    """
    r = bridge.call("transcript.setSilenceThreshold", threshold=threshold)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Effects (video filters, generators, titles, audio)
# ============================================================
# Enumerate FCP's installed effects and apply them to clips.
# FCP organizes effects by type (filter, generator, title, audio).

@splicekit_tool("list_effects")
def list_effects(type: str = "filter", filter: str = "") -> str:
    """List available effects in FCP by type.

    Args:
        type: "filter" (video effects), "generator", "title", "audio", or "all"
        filter: Optional search string to filter by name or category.

    Returns effect name, effectID, category, and type for each.
    Use the effectID or name with apply_effect() to add one.
    """
    params = {"type": type}
    if filter:
        params["filter"] = filter
    r = bridge.call("effects.listAvailable", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effects = r.get("effects", [])
    lines = [f"Available {type} effects: {r.get('count', len(effects))}"]
    lines.append("")

    if effects:
        lines.append(f"{'Name':<30} {'Category':<25} {'Type':<12} {'Effect ID'}")
        lines.append("-" * 100)
        for e in effects:
            lines.append(
                f"{e['name']:<30} {e.get('category', ''):<25} "
                f"{e.get('type', ''):<12} {e['effectID'][:40]}"
            )
    else:
        lines.append("No effects found.")

    return "\n".join(lines)


@splicekit_tool("apply_effect")
def apply_effect(name: str = "", effectID: str = "") -> str:
    """Apply a video effect, generator, or title to the selected clip(s).

    Select a clip first with timeline_action("selectClipAtPlayhead").
    Use list_effects() to see available effects.

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur", "Vignette")
        effectID: The effect ID string

    Supports undo via timeline_action("undo").
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name

    r = bridge.call("effects.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return f"Applied effect: {r.get('effect', '?')} ({r.get('effectID', '')})"


# ============================================================
# Transitions
# ============================================================
# FCP has 376+ built-in transitions. These tools enumerate them
# and apply them at edit points (between adjacent clips).

@splicekit_tool("list_transitions")
def list_transitions(filter: str = "") -> str:
    """List all available video transitions installed in FCP.

    Returns transition name, effectID, and category for each.
    Use the effectID or name with apply_transition() to add one.

    Args:
        filter: Optional search string to filter by name or category.
    """
    params = {}
    if filter:
        params["filter"] = filter
    r = bridge.call("transitions.list", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    transitions = r.get("transitions", [])
    default = r.get("defaultTransition", {})

    lines = [f"Available transitions: {r.get('count', len(transitions))}"]
    lines.append(f"Default: {default.get('name', '?')} ({default.get('effectID', '?')})")
    lines.append("")

    if transitions:
        lines.append(f"{'Name':<30} {'Category':<30} {'Effect ID'}")
        lines.append("-" * 90)
        for t in transitions:
            lines.append(
                f"{t['name']:<30} {t.get('category', ''):<30} {t['effectID'][:50]}"
            )
    else:
        lines.append("No transitions found.")

    return "\n".join(lines)


@splicekit_tool("apply_transition")
def apply_transition(name: str = "", effectID: str = "", freeze_extend: bool = True) -> str:
    """Apply a specific transition at the current edit point.

    You can specify the transition by display name or effectID.
    Use list_transitions() to see available transitions.

    Args:
        name: Display name of the transition (e.g. "Cross Dissolve", "Flow")
        effectID: The effect ID (e.g. "FxPlug:4731E73A-...")
        freeze_extend: If True, automatically resolve missing-media transitions with freeze frames
            when there isn't enough media for the transition. This avoids the
            "not enough extra media" dialog and prevents ripple trimming.

    The transition is applied at the selected edit point (between clips).
    Select an edit point first with timeline_action("nextEdit") or
    timeline_action("previousEdit").

    Supports undo via ``history_action("undo")``. Note that a transition consumes media
    from both sides of the cut, so with freeze_extend the clips around it may be altered
    too; undo takes the whole thing back together.
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name
    if freeze_extend:
        params["freezeExtend"] = True

    r = bridge.call("transitions.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    msg = f"Applied transition: {r.get('transition', '?')} ({r.get('effectID', '')})"
    if r.get("freezeExtended"):
        msg += " (missing-media fixed with freeze frames)"
    return msg


@splicekit_tool("apply_transition_to_all_clips")
def apply_transition_to_all_clips() -> str:
    """Apply the default transition (Cross Dissolve) between every clip on the timeline.

    This selects all clips and adds the default transition at every edit point
    in a single operation. Much faster than applying transitions one at a time.

    Use list_transitions() to see which transition is currently set as default.
    """
    r = bridge.call("command.execute", action="addTransitionToAll", type="timeline")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Command Palette
# ============================================================
# A floating search palette (like VS Code's Cmd+Shift+P) that
# can also pipe queries through Apple Intelligence for natural
# language editing commands.

@splicekit_tool("show_command_palette")
def show_command_palette() -> str:
    """Open the command palette inside FCP.
    The palette provides quick access to all FCP actions via fuzzy search,
    and supports natural language commands via Apple Intelligence.
    Shortcut: Cmd+Shift+P
    """
    r = bridge.call("command.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette opened."


@splicekit_tool("hide_command_palette")
def hide_command_palette() -> str:
    """Close the command palette."""
    r = bridge.call("command.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette closed."


@splicekit_tool("livecam_open")
def livecam_open() -> str:
    """Open the LiveCam panel inside Final Cut Pro."""
    r = bridge.call("liveCam.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("livecam_close")
def livecam_close() -> str:
    """Close the LiveCam panel."""
    r = bridge.call("liveCam.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("livecam_status")
def livecam_status() -> str:
    """Get the current LiveCam panel state, selected devices, recording flags, and destination."""
    r = bridge.call("liveCam.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("search_commands")
def search_commands(query: str, limit: int = 20) -> str:
    """Search available FCP commands by name, keyword, or category.

    Returns matching commands sorted by relevance. Each result includes:
    name, action, type (timeline/playback/transcript), category, detail, shortcut.

    Use execute_command() to run one of the results.
    """
    r = bridge.call("command.search", query=query, limit=limit)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    commands = r.get("commands", [])
    if not commands:
        return f"No commands match '{query}'"

    lines = [f"Found {r.get('total', len(commands))} matches:"]
    for cmd in commands:
        shortcut = f"  [{cmd['shortcut']}]" if cmd.get("shortcut") else ""
        lines.append(f"  {cmd['name']:<30} {cmd['category']:<12} {cmd['type']}/{cmd['action']}{shortcut}")
        if cmd.get("detail"):
            lines.append(f"    {cmd['detail']}")

    return "\n".join(lines)


@splicekit_tool("execute_command")
def execute_command(action: str, type: str = "timeline") -> str:
    """Execute a command from the palette by action name.

    Args:
        action: The action ID (e.g. "blade", "addColorBoard", "retimeSlow50")
        type: "timeline", "playback", or "transcript"

    This is equivalent to selecting a command in the palette and pressing Enter.
    """
    r = bridge.call("command.execute", action=action, type=type)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


_AI_COMMAND_ENGINES = ("standard", "agentic", "gemma")


@splicekit_tool("ai_command")
def ai_command(query: str, engine: str = "") -> str:
    """Use Apple Intelligence (on-device LLM) to interpret a natural language
    editing instruction and execute the appropriate FCP actions.

    FCP's default AI engine is **agentic** (Apple Intelligence+, multi-turn).
    Calls on that path can take several minutes. Use engine="standard" for the
    fast single-shot Apple Intelligence path (fixed action schema, ~60s on the
    bridge).

    Args:
        query: Natural language editing instruction.
        engine: Optional override of the palette's configured engine:
            "standard" — single-shot Apple Intelligence;
            "agentic" — Apple Intelligence+ agent loop (FCP default);
            "gemma" — Gemma 4 via MLX (requires mlx-lm server).
            Omit or pass "" to use the palette setting (usually agentic).

    Examples:
      "cut at 3 seconds"
      "slow this clip to half speed"
      "add color correction"
      "go to the beginning and play"
      "add a chapter marker"

    The LLM translates your description into a sequence of FCP actions and
    executes them automatically. Falls back to keyword matching if Apple
    Intelligence is not available on this Mac.

    The MCP client waits up to ~5.5 minutes (330s) so it outlasts the bridge's
    300s agentic/Gemma deadline; standard mode usually finishes sooner.

    This hands the instruction to a language model that then edits the timeline itself.
    On the agentic and gemma engines it decides its own sequence of actions and can run
    destructive ones — delete, blade, trim, replace — without asking again. It is driven
    by your wording, so keep the instruction specific, and take a verify_action()
    snapshot first if you want to be able to tell exactly what it changed.
    """
    if engine and engine not in _AI_COMMAND_ENGINES:
        allowed = ", ".join(_AI_COMMAND_ENGINES)
        return f"Error: invalid engine '{engine}'. Use one of: {allowed}."
    call_params = {"query": query, "timeout": 330.0}
    if engine:
        call_params["engine"] = engine
    r = bridge.call("command.ai", **call_params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Apple Intelligence+ (agentic) returns a summary string, not actions
    if r.get("summary"):
        return r["summary"]

    actions = r.get("actions", [])
    if not actions:
        return "No actions determined from query."

    # Execute a single AI action, dispatching by type
    def _exec_one(act):
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        if act_type == "seek":
            secs = act.get("seconds", 0)
            er = bridge.call("playback.seekToTime", seconds=secs)
            if _err(er):
                return f"Error on seek({secs}s): {er.get('error', er)}"
            return f"seek -> {secs}s"

        if act_type == "effect":
            eff_name = act.get("name", "")
            # Auto-select clip at playhead first
            bridge.call("timeline.action", action="selectClipAtPlayhead")
            er = bridge.call("effects.apply", name=eff_name)
            if _err(er):
                return f"Error on effect '{eff_name}': {er.get('error', er)}"
            return f"effect '{eff_name}' -> ok"

        if act_type == "transition":
            tr_name = act.get("name", "")
            er = bridge.call("transitions.apply", name=tr_name, freezeExtend=True)
            if _err(er):
                return f"Error on transition '{tr_name}': {er.get('error', er)}"
            return f"transition '{tr_name}' -> ok"

        if act_type == "repeat_pattern":
            count = act.get("count", 1)
            inner = act.get("actions", [])
            msgs = []
            for i in range(count):
                for sub in inner:
                    msgs.append(_exec_one(sub))
            return f"repeat_pattern x{count}: " + "; ".join(msgs)

        if act_type == "scene_detect":
            er = bridge.call("scene.detect", threshold=0.35, action="detect", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_detect: {er.get('error', er)}"
            return f"scene_detect -> {er.get('count', 0)} changes"

        if act_type == "scene_markers":
            er = bridge.call("scene.detect", threshold=0.35, action="markers", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_markers: {er.get('error', er)}"
            return f"scene_markers -> {er.get('count', 0)} markers"

        # timeline, playback, or any other type with an action field
        for _ in range(repeat):
            er = bridge.call(f"{act_type}.action", action=action_name)
            if _err(er):
                return f"Error on {act_type}.{action_name}: {er.get('error', er)}"
        return f"{act_type}.{action_name}" + (f" x{repeat}" if repeat > 1 else "") + " -> ok"

    # Apple Intelligence returns a list of FCP actions — execute them in order
    results = []
    for act in actions:
        results.append(_exec_one(act))

    return f"AI executed {len(actions)} action(s):\n" + "\n".join(results)


@splicekit_tool("ai_command_gemma")
def ai_command_gemma(query: str, model: str = "unsloth/gemma-4-E4B-it-UD-MLX-4bit") -> str:
    """Use Gemma 4 (via MLX on Apple Silicon) for agentic natural language editing.

    Runs a multi-turn tool-calling loop that can reach every bridge method, rather than
    the fixed action schema ai_command's "standard" engine uses.
    Requires mlx-lm server: python -m mlx_lm.server --model unsloth/gemma-4-E4B-it-UD-MLX-4bit

    ``ai_command(query, engine="gemma")`` reaches the same handler and does the same
    thing; this tool exists to name the model. Prefer whichever reads more clearly, and
    use this one when you want to choose a different `model`.

    This hands the instruction to a language model that then edits the timeline itself.
    It decides its own sequence of actions and can run destructive ones — delete, blade,
    trim, replace — without asking again. It is driven by your wording, so keep the
    instruction specific, and take a verify_action() snapshot first if you want to be able
    to tell exactly what it changed.

    Args:
        query: Natural language editing instruction
        model: HuggingFace model ID (default: unsloth/gemma-4-E4B-it-UD-MLX-4bit). Must be
            the model the mlx-lm server was started with.

    The Gemma path uses a multi-turn agentic loop (local MLX model) and can take
    several minutes; the MCP client waits up to ~5.5 minutes so it outlasts the
    bridge handler's own deadline.
    """
    r = bridge.call("command.aiGemma", query=query, model=model, timeout=330.0)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return r.get("summary", "Done.")


# ============================================================
# Menu Execute (universal menu access)
# ============================================================
# Fallback for anything that doesn't have a dedicated tool.
# Walks FCP's NSMenu hierarchy by title to reach any menu item.

@splicekit_tool("execute_menu_command")
def execute_menu_command(menu_path: list[str], dry_run: bool = False) -> str:
    """Execute ANY FCP menu command by navigating the menu bar hierarchy.

    Args:
        menu_path: List of menu item names from top to bottom.
                   e.g. ["File", "New", "Project"] or ["Edit", "Paste as Connected Clip"]
        dry_run: If True, report what would fire without firing it. Returns
                 {menuItem, enabled, validates, action, target_class,
                  likely_modal, would_fire} — useful for checking whether a
                 menu item is available in the current state and whether
                 it is likely to open a modal dialog before committing.

    This gives you access to every single menu item in FCP, including items
    that don't have dedicated SpliceKit actions. Menu items are matched
    case-insensitively and trailing ellipsis (...) is ignored.
    """
    r = bridge.call("menu.execute", menuPath=menu_path, dry_run=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("list_menus")
def list_menus(menu: str = "", depth: int = 2, validate: bool = False) -> str:
    """List FCP menu items to discover available commands.

    Args:
        menu: Optional top-level menu name (e.g. "File", "Edit", "Modify").
              If empty, lists all top-level menus.
        depth: How deep to recurse into submenus (default 2).
        validate: run each listed menu's validation first (what AppKit does when the menu
              opens). Off by default. It resolves the Undo / Redo titles only when Final
              Cut Pro is frontmost: validation goes through the key window, and with FCP in
              the background (QA run 4) the items stay "Undo" / "Redo" and disabled even
              while the document holds an undoable step.

    Returns the menu items with shortcuts and enabled status. For the Edit menu (or all
    menus) the answer also carries `undoState` when a library is open: canUndo / canRedo
    and the action names read from the library document's undo manager, which is what
    Edit > Undo and history_action act on, and a `note` on the validation limit above.
    """
    params = {"depth": depth}
    if menu:
        params["menu"] = menu
    if validate:
        params["validate"] = True
    r = bridge.call("menu.list", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Inspector Properties (read/write clip properties)
# ============================================================
# Reads/writes FCP's internal effect parameter channels directly,
# bypassing the inspector UI. Works on transform, compositing, audio, crop.

@splicekit_tool("get_inspector_properties")
def get_inspector_properties(property: str = "all") -> str:
    """Read properties of the selected clip from the inspector.

    Args:
        property: Which properties to read. Options:
                  "all" - transform, compositing, audio, crop values
                  "transform" - positionX/Y/Z, rotation, scaleX/Y, anchorX/Y
                  "compositing" - opacity (0.0-1.0), blend mode handle
                  "audio" - volume level (linear gain)
                  "crop" - left, right, top, bottom crop values
                  "info" - clip name, class, effect stack presence
                  "channels" - ALL effect channels with handles for direct access

    Returns actual numeric values from FCP's internal effect parameter channels.
    Requires a clip to be selected first (use timeline_action("selectClipAtPlayhead")).
    """
    r = bridge.call("inspector.get", property=property)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_inspector_property")
def set_inspector_property(property: str, value: float | str | bool) -> str:
    """Set a property on the selected clip's effect parameters.

    Args:
        property: Property key to set. These are keys like positionX, not inspector
                  labels like Position X.
                  "opacity" - 0.0 to 1.0 (0% to 100%)
                  "positionX" - horizontal position in pixels (0 = center)
                  "positionY" - vertical position in pixels (0 = center)
                  "positionZ" - Z depth
                  "rotation" - rotation in degrees
                  "scaleX" - horizontal scale (100 = 100%)
                  "scaleY" - vertical scale (100 = 100%)
                  "anchorX" - anchor point X
                  "anchorY" - anchor point Y
                  "volume" - audio volume (linear gain, 1.0 = 0dB)
                  "handle:<handle_id>" - set any channel directly by its object handle
        value: New numeric value to set

    Changes are undoable (Cmd+Z). Creates the transform effect if it doesn't exist yet.
    Requires a clip to be selected first.
    """
    r = bridge.call("inspector.set", property=property, value=value)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("get_title_text")
def get_title_text() -> str:
    """Read text content, font, and size from the selected Motion title clip.

    Inspects the selected clip's effect channel tree to find CHChannelText nodes.
    Returns the rendered text string, font family, font name, and point size as
    stored in the NSAttributedString on the text channel.

    This is useful for verifying that title text imported via FCPXML actually
    rendered with the correct content and font size.

    Requires a title clip to be selected first (use timeline_action("selectClipAtPlayhead")).
    """
    r = bridge.call("inspector.getTitle")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("verify_captions")
def verify_captions() -> str:
    """Verify that generated captions rendered correctly on the timeline.

    Checks the most recently generated captions by inspecting their text channels.
    Returns verification results: text content, font size, font family for each
    title that can be found. Reports any mismatches from the expected style.

    Run this after generate_captions() to confirm titles have visible text at
    the correct font size, without needing to ask the user to check manually.
    """
    r = bridge.call("captions.verify")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# View/Panel Toggles
# ============================================================
# Show/hide FCP's various panels and viewers.

@splicekit_tool("toggle_panel")
def toggle_panel(panel: str) -> str:
    """Show or hide a panel/viewer in the FCP interface.

    Args:
        panel: Panel to toggle. Options:
               inspector, timeline, browser, eventViewer,
               effectsBrowser, transitionsBrowser,
               videoScopes, histogram, vectorscope, waveform, audioMeter,
               keywordEditor, timelineIndex, precisionEditor, retimeEditor,
               audioCurves, videoAnimation, audioAnimation,
               multicamViewer, 360viewer, fullscreenViewer,
               backgroundTasks, voiceover, comparisonViewer
    """
    r = bridge.call("view.toggle", panel=panel)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_workspace")
def set_workspace(workspace: str) -> str:
    """Switch to a predefined workspace layout.

    Args:
        workspace: "default", "organize", "colorEffects", or "dualDisplays"
    """
    r = bridge.call("view.workspace", workspace=workspace)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Tool Selection
# ============================================================
# Switch the active editing tool (blade, trim, range, etc).

@splicekit_tool("select_tool")
def select_tool(tool: str) -> str:
    """Switch to a specific editing tool.

    Args:
        tool: "select", "trim", "blade", "position", "hand", "zoom",
              "range", "crop", "distort", "transform"
    """
    r = bridge.call("tool.select", tool=tool)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Roles Management
# ============================================================
# Roles control how clips appear in the timeline index and
# how they're grouped during export (e.g. separate Dialogue/Music stems).

@splicekit_tool("assign_role")
def assign_role(type: str, role: str) -> str:
    """Assign a role to the selected clip.

    Args:
        type: "audio", "video", or "caption"
        role: Role name (e.g. "Dialogue", "Music", "Effects", "Titles", "Video")
    """
    r = bridge.call("roles.assign", type=type, role=role)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Mixer (Audio Faders)
# ============================================================
# Real-time audio mixer with per-clip volume faders.
# Returns clips overlapping the playhead with volume levels.

@splicekit_tool("mixer_get_state")
def mixer_get_state() -> str:
    """Get current mixer state: all clips overlapping the playhead with their volumes.

    Returns up to 12 faders, sorted by lane (highest/topmost clip = fader 0).
    Each fader includes clipHandle, volumeChannelHandle, effectStackHandle,
    volumeDB, volumeLinear, lane, role, and clip name.
    """
    r = bridge.call("mixer.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    faders = r.get("faders", [])
    if not faders:
        return f"No clips at playhead (time: {r.get('playheadSeconds', 0):.3f}s)"
    lines = [f"Mixer State (playhead: {r.get('playheadSeconds', 0):.3f}s, {len(faders)} faders):"]
    lines.append("")
    for f in faders:
        db = f.get("volumeDB", 0)
        db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
        role_str = f" [{f['role']}]" if f.get("role") else ""
        flags = []
        if f.get("soloed"):
            flags.append("SOLO")
        if f.get("soloMuted"):
            flags.append("solo-muted")
        if f.get("muted"):
            flags.append("MUTE")
        elif f.get("muteMixed"):
            flags.append("mute-mixed")
        flag_str = f" ({', '.join(flags)})" if flags else ""
        lines.append(f"  Fader {f['index']}: {f.get('name', '?')} (lane {f['lane']})"
                     f"  {db_str} dB{role_str}{flag_str}")
        lines.append(f"    handles: clip={f.get('clipHandle','?')}"
                     f" vol={f.get('volumeChannelHandle','?')}"
                     f" es={f.get('effectStackHandle','?')}"
                     f" bus={f.get('busEffectStackHandle','?')}")
        if f.get("busKind") and f.get("busKind") != "none":
            lines.append(f"    bus: {f.get('busKind')} ({f.get('busObjectCount', 0)} object(s),"
                         f" {f.get('busEffectCount', 0)} effect(s))")
    if r.get("totalClipsAtPlayhead", 0) > 10:
        lines.append(f"\n  ({r['totalClipsAtPlayhead']} total clips, showing first 10)")
    return "\n".join(lines)


@splicekit_tool("mixer_set_volume")
def mixer_set_volume(handle: str, volume_db: float = None,
                     volume_linear: float = None) -> str:
    """Set volume on a specific clip via its volumeChannelHandle.

    Use mixer_get_state() first to get handles. For proper undo support,
    call mixer_volume_begin() before a series of changes, then mixer_volume_end() after.

    Args:
        handle: The volumeChannelHandle from mixer_get_state()
        volume_db: Volume in dB (0 = unity, -6 = half, -inf = silent). Use this OR
            volume_linear. If both are given, volume_db wins and volume_linear is ignored.
        volume_linear: Volume as linear gain (1.0 = 0dB, 0.5 = -6dB, 0 = silent)
    """
    params = {"handle": handle}
    if volume_db is not None:
        params["volumeDB"] = volume_db
    elif volume_linear is not None:
        params["volumeLinear"] = volume_linear
    else:
        return "Error: provide either volume_db or volume_linear"
    r = bridge.call("mixer.setVolume", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    db = r.get("volumeDB", 0)
    db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
    return f"Volume set: {db_str} dB (linear: {r.get('volumeLinear', 0):.3f})"


@splicekit_tool("mixer_set_solo")
def mixer_set_solo(index: int = -1, role: str = "", mode: str = "toggle",
                   solo: bool = None) -> str:
    """Solo, unsolo, or clear solo for a mixer role fader.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "exclusive", "add", "remove", or "clear".
        solo: Optional explicit state. If omitted, toggle/exclusive behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if solo is not None:
        params["solo"] = solo

    r = bridge.call("mixer.setSolo", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer solo cleared"
    state = "soloed" if r.get("soloed") else "not soloed"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('soloObjectCount', 0)} soloed objects)"


@splicekit_tool("mixer_set_mute")
def mixer_set_mute(index: int = -1, role: str = "", mode: str = "toggle",
                   muted: bool = None) -> str:
    """Mute, unmute, or clear mute for a mixer role fader.

    This uses Final Cut Pro's disabled audio-role playback map, so it does not
    change clip gain or insert mute effects.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "mute", "unmute", or "clear".
        muted: Optional explicit mute state. If omitted, toggle/mode behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if muted is not None:
        params["muted"] = muted

    r = bridge.call("mixer.setMute", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer role mutes cleared"
    state = "muted" if r.get("muted") else "unmuted"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('roleUIDCount', 0)} role UIDs)"


@splicekit_tool("mixer_apply_bus_effect")
def mixer_apply_bus_effect(effect_id: str = "", name: str = "",
                           index: int = -1, role: str = "",
                           dry_run: bool = False,
                           allow_object_fallback: bool = False) -> str:
    """Apply an audio effect to a mixer role's collection-backed bus.

    The true bus path targets role-bearing compound/collection objects, so the
    effect is inserted on the parent audio stack that all contained audio flows through.

    Args:
        effect_id: Exact FCP audio effect ID. Use this or name.
        name: Audio effect display name, e.g. "Channel EQ". Used when effect_id is empty.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        dry_run: Preview the bus targets without applying the effect.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"dryRun": dry_run, "allowObjectFallback": allow_object_fallback}
    if effect_id:
        params["effectID"] = effect_id
    if name:
        params["name"] = name
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.applyBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or name or effect_id
    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    if dry_run:
        return f"Mixer bus preview: {effect_name} -> {target} ({count} bus object{'s' if count != 1 else ''})"
    return f"Applied {effect_name} to mixer role {target} ({count} bus object{'s' if count != 1 else ''})"


@splicekit_tool("mixer_open_bus_effect")
def mixer_open_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                          effect_handle: str = "", effect_stack_handle: str = "",
                          allow_object_fallback: bool = False) -> str:
    """Open the native FCP editor window for an effect on a mixer role bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.openBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or f"effect {effect_index}"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Opened {effect_name} editor for mixer role {target}"


@splicekit_tool("mixer_set_bus_effect_enabled")
def mixer_set_bus_effect_enabled(effect_index: int = -1, enabled: bool = True,
                                 index: int = -1, role: str = "",
                                 effect_handle: str = "", effect_stack_handle: str = "",
                                 allow_object_fallback: bool = False) -> str:
    """Enable or disable an effect on a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        enabled: True to enable the effect, false to disable it.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {
        "enabled": enabled,
        "allowObjectFallback": allow_object_fallback,
    }
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.setBusEffectEnabled", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    state = "enabled" if r.get("enabled") else "disabled"
    return f"Mixer bus effect {effect_index} on {target}: {state}"


@splicekit_tool("mixer_remove_bus_effect")
def mixer_remove_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                            effect_handle: str = "", effect_stack_handle: str = "",
                            allow_object_fallback: bool = False) -> str:
    """Remove an effect from a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.removeBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    return f"Removed mixer bus effect {effect_index} from {target} ({count} bus object{'s' if count != 1 else ''})"


@splicekit_tool("mixer_volume_begin")
def mixer_volume_begin(effect_stack_handle: str) -> str:
    """Begin an undo-batched volume change (call before a series of mixer_set_volume).

    Opens an undo transaction so all volume changes until mixer_volume_end()
    are grouped as a single undo action.

    Args:
        effect_stack_handle: The effectStackHandle from mixer_get_state()
    """
    r = bridge.call("mixer.volumeBegin", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction opened for volume adjustment"


@splicekit_tool("mixer_volume_end")
def mixer_volume_end(effect_stack_handle: str) -> str:
    """End an undo-batched volume change (call after mixer_set_volume series).

    Closes the undo transaction. The entire series of changes becomes one undo action.

    Args:
        effect_stack_handle: The effectStackHandle used in mixer_volume_begin()
    """
    r = bridge.call("mixer.volumeEnd", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction closed"


@splicekit_tool("mixer_set_all_volumes")
def mixer_set_all_volumes(volumes: list) -> str:
    """Set volumes for multiple faders at once.

    For proper undo support, call mixer_volume_begin() before this and
    mixer_volume_end() after: without that scope each fader move lands in Final Cut Pro's
    undo stack separately, or not at all, and one ``history_action("undo")`` will not put
    them all back.

    Args:
        volumes: List of dicts with 'handle' (volumeChannelHandle) and
                 'volumeDB' or 'volumeLinear'. Example:
                 [{"handle": "obj_42", "volumeDB": -6.0},
                  {"handle": "obj_43", "volumeDB": -3.0}]
                 When an entry carries both, 'volumeDB' wins.
    """
    r = bridge.call("mixer.setAllVolumes", volumes=volumes)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    results = r.get("results", [])
    lines = [f"Set {len(results)} volumes:"]
    for res in results:
        if res.get("ok"):
            db = res.get("volumeDB", 0)
            db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
            lines.append(f"  {res.get('handle', '?')}: {db_str} dB")
        else:
            lines.append(f"  {res.get('handle', '?')}: ERROR - {res.get('error', '?')}")
    return "\n".join(lines)


# ============================================================
# Share/Export
# ============================================================
# Triggers FCP's share destinations (Export File, YouTube, etc).

@splicekit_tool("share_project")
def share_project(destination: str = "") -> str:
    """Share/export the project using a specific or default destination.

    May open FCP share or save panels. While a modal save/open panel is open the
    bridge cannot serve main-thread RPC; bridge_alive still responds. Save/open
    panels cannot be confirmed from the bridge — only dismiss_dialog(action=\"cancel\")
    closes them.

    Args:
        destination: Share destination name (e.g. "Export File", "Apple Devices 1080p",
                     "YouTube & Facebook"). Leave empty for default destination.
                     Use list_menus(menu="File") to see available Share destinations.
    """
    params = {}
    if destination:
        params["destination"] = destination
    r = bridge.call("share.export", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Project/Library/Event Management
# ============================================================
# Create new projects, events, and libraries via FCP's internal APIs.

@splicekit_tool("create_project")
def create_project() -> str:
    """Open the New Project dialog in FCP.

    Opens a modal save/open panel. While it is open the bridge cannot serve
    main-thread RPC; bridge_alive still responds. The panel cannot be confirmed
    from the bridge — only dismiss_dialog(action=\"cancel\") closes it.

    This tool cannot finish the job by itself. It opens Final Cut Pro's own panel and
    stops there: a person has to type the name and click Save. Until they do, the panel
    blocks every main-thread RPC on the bridge, so no other tool that reads or edits the
    document will answer (bridge_alive still responds). If nobody is at the machine, call
    dismiss_dialog(action="cancel") to close it again — that is the only way out from here.
    Nothing is created when it is cancelled.
    """
    return _call_or_error("project.create")


@splicekit_tool("create_event")
def create_event() -> str:
    """Create a new event in the current library.

    Opens a modal save/open panel. While it is open the bridge cannot serve
    main-thread RPC; bridge_alive still responds. The panel cannot be confirmed
    from the bridge — only dismiss_dialog(action=\"cancel\") closes it.

    This tool cannot finish the job by itself. It opens Final Cut Pro's own panel and
    stops there: a person has to type the name and click Save. Until they do, the panel
    blocks every main-thread RPC on the bridge, so no other tool that reads or edits the
    document will answer (bridge_alive still responds). If nobody is at the machine, call
    dismiss_dialog(action="cancel") to close it again — that is the only way out from here.
    Nothing is created when it is cancelled.
    """
    return _call_or_error("project.createEvent")


@splicekit_tool("create_library")
def create_library() -> str:
    """Open the New Library dialog.

    Opens a modal save/open panel. While it is open the bridge cannot serve
    main-thread RPC; bridge_alive still responds. The panel cannot be confirmed
    from the bridge — only dismiss_dialog(action=\"cancel\") closes it.

    This tool cannot finish the job by itself. It opens Final Cut Pro's own panel and
    stops there: a person has to type the name and click Save. Until they do, the panel
    blocks every main-thread RPC on the bridge, so no other tool that reads or edits the
    document will answer (bridge_alive still responds). If nobody is at the machine, call
    dismiss_dialog(action="cancel") to close it again — that is the only way out from here.
    Nothing is created when it is cancelled.
    """
    return _call_or_error("project.createLibrary")


# ============================================================
# Open Project by Name
# ============================================================
# Find a sequence by name (and optionally event) and load it
# into the editor — no manual handle navigation required.

@splicekit_tool("open_project")
def open_project(name: str, event: str = "") -> str:
    """Open a project/sequence by name, loading it into the timeline editor.

    Searches all active libraries for a sequence matching the given name,
    and optionally filters by event name. Much faster than manually navigating
    the library -> sequences -> loadEditorForSequence: chain.

    An exact name always wins over a longer one that merely contains it. Final Cut Pro
    hands out "QA Timeline 1" when "QA Timeline" is already taken, so asking for
    "QA Timeline" opens that one and not the copy. Among several substring matches with
    no exact one, the first found wins — pass `event` to be sure which.

    A project with nothing in it cannot be found by name: Final Cut Pro reports an empty,
    unopened project as a clip rather than a project, so it is not a candidate here.

    Args:
        name: Project/sequence name to find. Matched case-insensitively; an exact match
              is preferred, otherwise a substring match.
              e.g. "My Project", "Edit v2", "Interview"
        event: Optional event name filter (case-insensitive substring match).
               e.g. "4-5-26", "Wedding", "Interview"

    Returns the matched project name, event, and library on success.
    If no match is found, returns a list of all available sequences.
    """
    params = {"name": name}
    if event:
        params["event"] = event
    r = bridge.call("project.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Dual Timeline
# ============================================================
# Floating secondary timeline window backed by a second
# PEEditorContainerModule. Commands route to the focused pane.
# Close hides the window (-orderOut:) and retains the container for the app session;
# open reuses the cached module instead of tearing it down.

@splicekit_tool("dual_timeline_status")
def dual_timeline_status() -> str:
    """Inspect the primary/secondary timeline panes and current focused pane."""
    return _call_or_error("dualTimeline.status")


@splicekit_tool("dual_timeline_open")
def dual_timeline_open(source: str = "primary", focus: bool = False) -> str:
    """Open a floating secondary timeline window.

    Creates the secondary PEEditorContainerModule at most once per app run; closing
    hides the window without destroying the module. Re-open reuses the cached container.

    Args:
        source: Which pane to copy the sequence from.
                "primary" (default), "focused", or "secondary"
        focus: When true, move keyboard focus to the secondary timeline after opening.
               When false, restore focus back to the primary timeline after loading.
    """
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.open", **params)


@splicekit_tool("dual_timeline_sync_root")
def dual_timeline_sync_root(source: str = "primary", focus: bool = False) -> str:
    """Clone the source pane's root into the secondary timeline."""
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.syncRoot", **params)


@splicekit_tool("dual_timeline_open_selected_in_secondary")
def dual_timeline_open_selected_in_secondary(source: str = "primary", focus: bool = True) -> str:
    """Open the selection in the secondary timeline."""
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.openSelectedInSecondary", **params)


@splicekit_tool("dual_timeline_focus")
def dual_timeline_focus(pane: str) -> str:
    """Focus a specific timeline pane so subsequent commands target it.

    Args:
        pane: "primary" or "secondary"
    """
    return _call_or_error("dualTimeline.focus", pane=pane)


@splicekit_tool("dual_timeline_close")
def dual_timeline_close(focus_primary: bool = True) -> str:
    """Hide the floating secondary timeline window (does not destroy the container).

    Args:
        focus_primary: When true, move focus back to the primary timeline after closing.
    """
    return _call_or_error("dualTimeline.close", focusPrimary=focus_primary)


@splicekit_tool("dual_timeline_toggle_panel")
def dual_timeline_toggle_panel(panel: str, pane: str = "secondary") -> str:
    """Toggle a container-local panel on a specific timeline pane.

    Supported panels:
        "browser", "timelineIndex", "audioMeters",
        "effectsBrowser", "transitionsBrowser"

    Args:
        panel: Panel identifier to toggle.
        pane: "primary" or "secondary". Defaults to "secondary".
    """
    return _call_or_error("dualTimeline.togglePanel", pane=pane, panel=panel)


# ============================================================
# Select Connected Clip at Playhead (Lane Selection)
# ============================================================
# The standard selectClipAtPlayhead only selects the primary
# storyline clip. This tool selects clips in any lane.

@splicekit_tool("select_clip_in_lane")
def select_clip_in_lane(lane: int = 1) -> str:
    """Select the clip at the playhead in a specific lane (connected storyline).

    The standard timeline_action("selectClipAtPlayhead") only selects clips in
    the primary storyline (lane 0). This tool can select connected clips in any
    lane — essential for inspecting or modifying connected titles, B-roll, etc.

    Args:
        lane: Lane number to select from.
              0 = primary storyline (same as selectClipAtPlayhead)
              1 = first connected lane above (captions, titles, B-roll)
              -1 = first connected lane below
              2, 3, etc. = higher connected lanes

    Returns the selected clip's name, class, and handle for further inspection.
    """
    r = bridge.call("timeline.selectClipInLane", lane=lane)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Handle-based selection, edit grouping, exact trims
# ============================================================
# get_timeline_clips() hands back a handle for every clip. These tools act on
# those handles directly instead of on whatever happens to be under the playhead.

def _parse_handle_list(handles) -> list:
    """Accept a Python list, a JSON array string, or a comma-separated string of handles."""
    if handles is None:
        return []
    if isinstance(handles, str):
        text = handles.strip()
        if not text:
            return []
        if text.startswith("["):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as e:
                raise ValueError(f"handles is not a valid JSON array: {e}")
            if not isinstance(parsed, list):
                raise ValueError("handles JSON must be an array of handle strings")
            return [str(h).strip() for h in parsed if str(h).strip()]
        return [part.strip() for part in text.split(",") if part.strip()]
    if isinstance(handles, (list, tuple)):
        return [str(h).strip() for h in handles if str(h).strip()]
    raise ValueError("handles must be a list of handle strings, a JSON array string, "
                     "or a comma-separated string")


@splicekit_tool("select_clips")
def select_clips(handles: list[str] | str = "", mode: str = "replace") -> str:
    """Select clips by handle -- the way to act on a specific clip after get_timeline_clips().

    Workflow:
        get_timeline_clips()                       # read handles (e.g. "obj_12")
        select_clips(["obj_12"])                   # make that clip the selection
        timeline_action("addColorBoard")           # act on the selection as usual

    Works for clips in the primary storyline and for connected clips (titles,
    B-roll, music) alike, at any depth. Like Option-clicking a clip in Final Cut
    Pro, it never moves the playhead. An empty list is Edit > Deselect All. This
    tool selects clips only; to change a marker use list_markers() and the marker
    actions (changeMarkerName, markMarkerCompleted, removeMarker).

    Args:
        handles: a Python list, a JSON array string ('["obj_1","obj_2"]') or a
                 comma-separated string ("obj_1, obj_2"). Empty = deselect all.
        mode: "replace" (default) makes these clips the selection (a click in FCP);
              "add" adds them to the current selection (Command-click);
              "remove" takes them out of it (Command-click a selected clip).

    If none of the handles resolve, the selection is left unchanged and an error
    is returned. Handles and `matchesRequest` are SpliceKit bookkeeping, not Final
    Cut Pro terms: a handle is a reference to an object from an earlier read
    (re-run get_timeline_clips() if one comes back unresolved) and is unrelated to
    FCP's "media handles"; matchesRequest reports whether FCP's selection after the
    call equals the intended set (the requested clips for replace; the current
    selection plus or minus them for add/remove).
    """
    mode_l = (mode or "replace").strip().lower()
    if mode_l not in ("replace", "add", "remove"):
        return 'Error: mode must be "replace", "add" or "remove"'
    try:
        handle_list = _parse_handle_list(handles)
    except ValueError as e:
        return f"Error: {e}"

    r = bridge.call("timeline.selectItems", handles=handle_list, mode=mode_l)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    selected = r.get("selected", []) or []
    lines = [f"Selection ({r.get('mode', mode_l)}): {r.get('selectedCount', len(selected))} selected, "
             f"{r.get('resolvedCount', 0)}/{r.get('requestedCount', len(handle_list))} handles resolved"]
    if selected:
        lines.append(f"  {'handle':<10} {'lane':>4} {'start':>8} {'end':>8}  name")
        for item in selected:
            lines.append(
                f"  {str(item.get('handle', '?')):<10} {str(item.get('lane', '?')):>4} "
                f"{_fmt_secs(_time_seconds(item, 'startTime'))} {_fmt_secs(_time_seconds(item, 'endTime'))}  "
                f"{item.get('name', '')}"
            )
    elif not handle_list and mode_l == "replace":
        lines.append("  (nothing selected -- deselected all)")
    else:
        lines.append("  (nothing selected)")

    unresolved = r.get("unresolved", []) or []
    if unresolved:
        lines.append("Unresolved handles (stale? re-run get_timeline_clips): " + ", ".join(map(str, unresolved)))
    for rej in r.get("rejected", []) or []:
        lines.append(f"Rejected {rej.get('handle', '?')}: {rej.get('reason', 'rejected')}")
    if r.get("matchesRequest") is False:
        lines.append("WARNING: FCP's selection does not match the request (matchesRequest=false); "
                     "check the rows above before acting on the selection.")
    return "\n".join(lines)


@splicekit_tool("begin_edit")
def begin_edit(name: str = "Edit") -> str:
    """Open one undo step: everything until end_edit() reverts with a single Edit > Undo `name`.

    Final Cut Pro's internal term for this is an undoable action. It is opened
    on the sequence with actionBegin: and closed with actionEnd:save:error:,
    the same pair FCP's own edits use, so a multi-step edit (several blades,
    trims, markers, ...) undoes with one timeline_action("undo"). Always call
    end_edit() afterwards, also after an error, or the step stays open.

    Args:
        name: the Edit > Undo menu name for the step, e.g. "Rough cut".
    """
    r = bridge.call("timeline.beginEdit", name=name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"Undo step open: {r.get('name', name)}"
             + (f" (opened with {r['openedWith']})" if r.get("openedWith") else "")]
    if r.get("note"):
        lines.append(f"Note: {r['note']}")
    if "hadOpenTransaction" in r or "hasOpenTransaction" in r:
        lines.append(f"(diagnostic) hasOpenTimelineTransaction before: {r.get('hadOpenTransaction', '?')}, "
                     f"after: {r.get('hasOpenTransaction', '?')}")
    lines.append("Remember to call end_edit() when the edit is complete.")
    return "\n".join(lines)


@splicekit_tool("end_edit")
def end_edit(name: str = "") -> str:
    """Close the undo step opened by begin_edit(); everything since then is one Edit > Undo entry.

    Always call this after begin_edit(), also when something went wrong in
    between. Final Cut Pro registers the step under the name given to
    begin_edit() (or `name` here, if provided). If SpliceKit has no step open
    this does nothing, so it can never close a transaction FCP itself opened.

    Args:
        name: optional override for the Edit > Undo menu name.
    """
    params = {}
    if name:
        params["name"] = name
    r = bridge.call("timeline.endEdit", **params)
    if _err(r) and "status" not in r:
        return f"Error: {r.get('error', r)}"
    status = r.get("status", "ok")
    lines = [f"Undo step closed ({status}): {r.get('name', name or 'Edit')}"
             + (f" via {r['closedWith']}" if r.get("closedWith") else "")]
    if r.get("note"):
        lines.append(f"Note: {r['note']}")
    if "hadOpenTransaction" in r or "hasOpenTransaction" in r:
        lines.append(f"(diagnostic) hasOpenTimelineTransaction before: {r.get('hadOpenTransaction', '?')}, "
                     f"after: {r.get('hasOpenTransaction', '?')}")
    if r.get("error"):
        lines.append(f"Error reported by FCP: {r['error']}")
    if status == "ok" and not r.get("note"):
        lines.append(f"Edit > Undo {r.get('name', name or 'Edit')} now reverts the whole step.")
    return "\n".join(lines)


def _trim_range_line(label, rng):
    if not isinstance(rng, dict):
        return f"  {label} ?"
    return (f"  {label} {rng.get('start', 0):.3f}s - {rng.get('end', 0):.3f}s "
            f"(duration {rng.get('duration', 0):.3f}s)")


@splicekit_tool("trim_clip")
def trim_clip(handle: str, edge: str, delta_seconds: float | None = None,
              to_seconds: float | None = None, dry_run: bool = False) -> str:
    """Ripple trim one edit point (a clip's start point or end point) by handle, to an exact time.

    This is Final Cut Pro's default trim, a ripple edit: the same as dragging a
    clip's start point or end point with the Select tool. On the primary
    storyline the clip's duration changes and all subsequent clips ripple
    earlier or later so no gap is left (the project duration changes);
    connected clips attached to the trimmed clip or to any subsequent clip move
    with them, as in FCP. For a connected clip only that clip changes.

    A positive delta moves the edit point later on the timeline (to the right,
    like pressing Period with the edit point selected), a negative delta moves
    it earlier (Comma). Trimming the START point of a primary-storyline clip
    keeps the clip in place: its start point moves within the source media, its
    duration changes, and its end plus everything after it shifts.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        edge: "start" (the clip's start point) or "end" (its end point).
        delta_seconds: move the edit point by this many seconds (+ later, - earlier).
        to_seconds: or, the absolute timeline time the edit point should be at.
                    Give exactly one of delta_seconds / to_seconds. For a start
                    point on the primary storyline this sets how much head is
                    removed or added (to_seconds minus the current start); the
                    clip itself stays where it is.
        dry_run: True reports the planned before/after ranges without changing
                 anything (a SpliceKit preview; FCP has no dry run). Try it first.

    Sub-frame requests are a no-op; a trim that would leave the clip shorter
    than one frame is refused; transitions and connected storylines (trim the
    clips inside them) are not accepted; a compound clip is trimmed like any
    clip. Undo with timeline_action("undo").
    """
    edge_l = (edge or "").strip().lower()
    if edge_l not in ("start", "end"):
        return 'Error: edge must be "start" or "end"'
    if (delta_seconds is None) == (to_seconds is None):
        return "Error: give exactly one of delta_seconds or to_seconds"
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"

    params = {"handle": handle, "edge": edge_l, "dryRun": bool(dry_run)}
    if delta_seconds is not None:
        params["deltaSeconds"] = float(delta_seconds)
    else:
        params["toSeconds"] = float(to_seconds)
    r = bridge.call("timeline.trimClip", **params)
    if _err(r) and "status" not in r:
        # Validation refusals (bad handle, no-op, too short) carry no status; a
        # status:"failed" response is rendered below with its before/after ranges.
        lines = [f"Error: {r.get('error', r)}"]
        if isinstance(r, dict) and r.get("before"):
            lines.append(_trim_range_line("current:", r["before"]))
        return "\n".join(lines)

    name = r.get("name", "")
    label = f"{edge_l} edit point of '{name}' ({r.get('handle', handle)})"
    if r.get("dryRun"):
        lines = [f"DRY RUN -- ripple trim of the {label}",
                 f"  delta: {r.get('deltaSeconds', 0):+.3f}s "
                 f"({'later' if r.get('deltaSeconds', 0) > 0 else 'earlier'} on the timeline"
                 + (f", {r['deltaFrames']} frame(s)" if "deltaFrames" in r else "") + ")",
                 _trim_range_line("before:   ", r.get("before")),
                 _trim_range_line("projected:", r.get("projected"))]
        if r.get("rippleScope"):
            lines.append(f"  ripple: {r['rippleScope']}")
        lines.append("  Ripple edit: subsequent clips move so no gap is left, connected clips move with them. "
                     "Nothing was changed.")
        return "\n".join(lines)

    status = r.get("status", "?")
    lines = [f"Ripple trim {'OK' if status == 'ok' else 'FAILED'} -- {label}",
             f"  requested: {r.get('requestedDelta', 0):+.3f}s, applied: {r.get('appliedDelta', 0):+.3f}s"]
    lines.append(_trim_range_line("before:", r.get("before")))
    lines.append(_trim_range_line("after: ", r.get("after")))
    if r.get("error"):
        lines.append(f"  error: {r['error']}")
    if r.get("warning"):
        lines.append(f"  warning: {r['warning']}")
    if r.get("note"):
        lines.append(f"  note: {r['note']}")
    if r.get("rippleScope"):
        lines.append(f"  ripple: {r['rippleScope']}")
    if r.get("undoStepError"):
        lines.append(f"  undo step '{r.get('undoStep', 'Trim')}' could not be closed cleanly: {r['undoStepError']} "
                     "-- check Edit > Undo before relying on it")
    elif r.get("undoStep"):
        lines.append(f"  undo step: {r['undoStep']}" + (f" ({r['undoStepNote']})" if r.get("undoStepNote") else ""))
    elif r.get("undoStepNote"):
        lines.append(f"  undo step: none -- {r['undoStepNote']}")
    if status == "ok":
        lines.append('  Ripple edit applied: subsequent clips moved so no gap is left. Undo with timeline_action("undo").')
    return "\n".join(lines)


# ============================================================
# Clip Information (Info inspector fields + SpliceKit extras) and Viewer frame
# ============================================================
# Per-clip context for the AI: the Info inspector's fields for one clip
# (name, notes, roles, source media file) plus what SpliceKit adds from
# the model (timeline placement, effects, title text, markers, transcript
# words, a frame image), all by handle and without moving the playhead.

def _secs3(value):
    return f"{value:.3f}s" if isinstance(value, (int, float)) else "?"


def _render_clip_info(r: dict) -> str:
    """Compact Info-inspector style summary of a timeline.getClipInfo response."""
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    start = tl.get("start", _time_seconds(r, "startTime"))
    end = tl.get("end", _time_seconds(r, "endTime"))
    duration = tl.get("duration", _time_seconds(r, "duration"))
    where = "primary storyline" if r.get("onPrimaryStoryline") else "connected clip"
    lines = [f"{r.get('name', '?')} — {r.get('kind', 'clip')} on lane {r.get('lane', 0)} ({where}), "
             f"{_secs3(start)}–{_secs3(end)} ({_secs3(duration)})",
             f"  handle {r.get('handle', '?')} ({r.get('class', '?')})"]
    if r.get("timelineRangeError"):
        lines.append(f"  timeline range: unknown -- {r['timelineRangeError']}")

    roles = r.get("roles") if isinstance(r.get("roles"), dict) else {}
    role_bits = []
    if roles.get("video"):
        role_bits.append(f"video: {roles['video']}")
    if roles.get("audio"):
        role_bits.append(f"audio: {roles['audio']}")
    lines.append("  roles: " + (", ".join(role_bits) if role_bits else "(none reported)"))

    flags = []
    if "enabled" in r:
        flags.append("enabled" if r.get("enabled") else "DISABLED")
    media = [name for name, key in (("video", "hasVideo"), ("audio", "hasAudio")) if r.get(key)]
    flags.append("+".join(media) if media else "no media flags")
    if r.get("selected"):
        flags.append("selected")
    lines.append("  " + ", ".join(flags))

    sm = r.get("sourceMedia")
    if isinstance(sm, dict):
        lines.append(f"  source media file: {sm.get('fileName', '?')} "
                     f"({'exists' if sm.get('exists') else 'missing on disk (FCP: Missing File)'}; "
                     f"media representation: {sm.get('representation', '?')})")
        lines.append(f"    path: {sm.get('path', '')}")
        if sm.get("sourceStartKnown") is False:
            lines.append(f"    start point in the source media: not read (FCP's clip object answered none of "
                         f"clippedRange / trimStartTime / trimmedOffset); media starts at "
                         f"{_secs3(sm.get('mediaOrigin'))}; taken as {_secs3(sm.get('fileStart'))}–"
                         f"{_secs3(sm.get('fileEnd'))} into the media file, counted from the file's start "
                         f"(right only if the clip's start is not trimmed)")
        else:
            lines.append(f"    start point in the source media: {_secs3(sm.get('sourceStart'))}; "
                         f"media starts at {_secs3(sm.get('mediaOrigin'))}; "
                         f"{_secs3(sm.get('fileStart'))}–{_secs3(sm.get('fileEnd'))} into the media file")
    elif r.get("sourceMediaError"):
        lines.append(f"  source media file: {r['sourceMediaError']}")

    if "effects" in r or "effectCount" in r:
        effects = r.get("effects") or []
        names = []
        for e in effects:
            if not isinstance(e, dict):
                continue
            label = e.get("name") or e.get("class", "?")
            eid = e.get("effectID")
            names.append(f"{label} ({eid})" if eid and eid != label else str(label))
        lines.append(f"  effects: {r.get('effectCount', len(effects))}" + (": " + ", ".join(names) if names else ""))
        if r.get("effectsError"):
            lines.append(f"    effects error: {r['effectsError']}")

    title = r.get("title")
    if isinstance(title, dict):
        font = ""
        if title.get("fontFamily") or title.get("fontName"):
            font = f", {title.get('fontFamily') or title.get('fontName')}"
            if title.get("fontSize") is not None:
                font += f" {title['fontSize']}pt"
        channels = [c for c in (title.get("channels") or []) if isinstance(c, dict)]
        count = title.get("channelCount", len(channels))
        lines.append(f"  title text: {title.get('text', '')!r}{font} ({count} text layer(s))")
        if len(channels) > 1:
            for c in channels[:8]:
                lines.append(f"    {c.get('channelName') or 'text'}: {str(c.get('text', ''))!r}")
            if len(channels) > 8:
                lines.append(f"    ... {len(channels) - 8} more text layer(s)")

    if "markers" in r or "markerCount" in r:
        markers = r.get("markers") or []
        lines.append(f"  markers within the clip: {r.get('markerCount', len(markers))}")
        for m in markers[:5]:
            lines.append(f"    at {_secs3(_time_seconds(m, 'time'))} (timeline) {m.get('kind', '?')} {m.get('name', '')}".rstrip())
        if len(markers) > 5:
            lines.append(f"    ... {len(markers) - 5} more")

    tr = r.get("transcript")
    if isinstance(tr, dict):
        if tr.get("error"):
            lines.append(f"  transcript (SpliceKit Text-Based Editor): error {tr['error']}")
        elif not tr.get("available"):
            lines.append(f"  transcript: none (SpliceKit Text-Based Editor status: {tr.get('status', 'idle')}; "
                         f"run open_transcript() first; this is not FCP's Transcribe to Captions)")
        else:
            words = [w for w in (tr.get("words") or []) if isinstance(w, dict)]
            span = ""
            if words and isinstance(words[0].get("startTime"), (int, float)) \
                    and isinstance(words[-1].get("endTime"), (int, float)):
                span = f", {_secs3(words[0]['startTime'])}–{_secs3(words[-1]['endTime'])} timeline"
            lines.append(f"  transcript (SpliceKit Text-Based Editor): {tr.get('wordCount', len(words))} word(s) in clip"
                         f"{span} (status {tr.get('status', '?')}, {tr.get('matchedByHandle', 0)} tagged with this handle"
                         f"{', truncated' if tr.get('truncated') else ''})")
            preview = " ".join(str(w.get("text", "")) for w in words[:60]).strip()
            if preview:
                lines.append(f'    "{preview}{" ..." if len(words) > 60 else ""}"')
            if tr.get("speakers"):
                lines.append(f"    speakers: {', '.join(str(x) for x in tr['speakers'])}")
            lines.append("    (per-word times and confidence: get_transcript() / search_transcript())")

    if r.get("notes"):
        lines.append(f"  notes: {r['notes']}")

    frame = r.get("frame")
    if isinstance(frame, dict):
        lines.append(f"  frame: {frame.get('width')}x{frame.get('height')} JPEG at {_secs3(frame.get('timelineTime'))} "
                     f"(source {_secs3(frame.get('sourceTime'))}, file {_secs3(frame.get('fileTime'))}) "
                     f"from the source media file, no effects")
    elif r.get("frameError"):
        lines.append(f"  frame: not available -- {r['frameError']}")

    timings = r.get("timings")
    if isinstance(timings, dict):
        lines.append(f"  (timings: main thread {timings.get('mainThreadMs', 0):.0f} ms, "
                     f"frame {timings.get('frameMs', 0):.0f} ms)")
    return "\n".join(lines)


@splicekit_tool("get_clip_info")
def get_clip_info(handle: str, include_frame: bool = True, frame_time: float | None = None,
                  frame_max_width: int = 640):
    """Clip information for one clip by handle: the fields Final Cut Pro's Info
    inspector shows for it, plus timeline placement, effects, title text, markers,
    transcript words and a frame from its source media file. Read-only: never moves
    the playhead and never changes the selection.

    Info inspector fields: name, notes, Video Roles / Audio Roles, and the source
    media file: path, file name, whether the file exists on disk (FCP: Missing File
    when it does not), and which media representation it is, in FCP's words:
    original, optimized or proxy (the Info inspector lists these under Available
    Media Representations). The Info inspector's Start / End / Duration are shown
    there as timecode; this tool reports timeline seconds instead (below).

    Timeline placement and source timing (SpliceKit, in seconds): start, end and
    duration on the timeline; whether the clip is on the primary storyline or a
    connected clip and its lane; enabled or disabled (Clip > Disable); selected; the
    clip's start point in the source media; where the source media starts (normally
    its starting source timecode); and how many seconds into the media file the
    clip's range lies.

    Added by SpliceKit from the model: the effects on the clip (names and effect IDs;
    get_clip_effects() for handles and parameters), the title text of a title or
    generator (text, font and size, and the text of every text layer), the markers
    placed within the clip, the words of SpliceKit's Text-Based Editor transcript that
    fall inside the clip (open_transcript() first; the summary shows the text, the
    count and the time span; get_transcript() has per-word times, confidence and
    speaker), and a JPEG frame decoded straight from the source media file at the
    clip's midpoint (or frame_time). That frame is the raw footage WITHOUT effects,
    color or transforms; use capture_clip_frame() for the rendered look. The frame is
    returned inline as MCP image content, so any MCP client can look at it.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        include_frame: also decode a frame from the source media file (default True).
        frame_time: absolute timeline time in seconds of the frame to read; default the
                    clip's midpoint; a time outside the clip is clamped into it.
        frame_max_width: longest side of the returned frame in pixels (64-1920, default 640).

    `kind` (video clip, audio clip, title, generator, gap clip, transition, compound
    clip, reference clip, multicam clip, connected storyline, caption), handles and
    `timings` are SpliceKit's own bookkeeping, spelled with FCP's words; compound,
    reference (an FFAnchoredClip standing in for an event clip: a compound, multicam or
    synchronized clip) and multicam come from FCP's own flags on the clip, not from its
    class name. Titles, generators and gap clips have no
    source media file and report that instead of a frame. A compound clip (FCP: reference
    clip, verified on 12.3; a multicam or synchronized clip answers the same flag) has no
    single source media file: its contents are clips of their own, so no source file, no
    start point and no frame are reported for it (`containerKind` says which;
    capture_clip_frame shows it as the Viewer shows it; timeline_action "openClip" on the
    selected clip opens its own timeline). A marker is not a clip; use list_markers().
    """
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"
    params = {"handle": handle, "includeFrame": bool(include_frame),
              "frameMaxWidth": int(frame_max_width)}
    if frame_time is not None:
        params["frameTime"] = float(frame_time)
    r = bridge.call("timeline.getClipInfo", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    text = _render_clip_info(r)
    frame = r.get("frame") if isinstance(r.get("frame"), dict) else None
    image = None
    if frame and frame.get("base64"):
        image = _image_content(data=_decode_base64_image(frame.get("base64")),
                               fmt=frame.get("format") or "jpeg")
        if image is None and Image is None:
            text += "\n  (frame available as base64 in the raw RPC timeline.getClipInfo)"
    return _maybe_with_image(text, image)


def _capture_flat_note(r: dict) -> str:
    """One WARNING line when the bridge found the captured image content to be one flat colour."""
    if not isinstance(r, dict) or not r.get("flat"):
        return ""
    return "\nWARNING: " + str(r.get("warning") or "the captured image is one flat colour: the window may have rendered nothing")


@splicekit_tool("capture_clip_frame")
def capture_clip_frame(handle: str, frame_time: float | None = None, frame_max_width: int = 960):
    """The clip as rendered in the Viewer: effects, color correction and transforms
    included. Moves the playhead to the frame time and restores it afterwards.

    Moves the playhead to frame_time (default the clip's midpoint), lets Final Cut Pro
    render the frame, captures the Viewer to a PNG (a screenshot of the Viewer, not
    FCP's File > Share > Save Current Frame export) and puts the playhead back where
    it was (the selection is not touched). The frame is returned inline as MCP image
    content and the PNG path is reported. The Viewer shows the playhead frame only
    while the pointer is not skimming over the timeline. A one-colour content region is
    reported with `flat: true` and a WARNING line; that can be a genuinely flat frame
    (black, a gap) or nothing rendered in the Viewer area.

    Prefer get_clip_info() when the raw footage is enough: it reads the frame from the
    source media file without moving the playhead. Use this tool to see what the clip
    actually looks like in the Viewer after effects, color or a title over it.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        frame_time: absolute timeline time in seconds; default the clip's midpoint;
                    clamped into the clip.
        frame_max_width: longest side of the returned JPEG in pixels (64-1920, default 960).

    Reports playheadBefore / playheadAtCapture and whether the playhead was restored
    (within half a frame). If it was not, seek_to_time(playheadBefore) puts it back.
    A capture that fails still reports those playhead fields (status "failed").
    """
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"
    params = {"handle": handle, "frameMaxWidth": int(frame_max_width)}
    if frame_time is not None:
        params["frameTime"] = float(frame_time)
    r = bridge.call("timeline.captureClipFrame", **params)
    if _err(r) and "status" not in r:
        return f"Error: {r.get('error', r)}"

    status = r.get("status", "?")
    tt = r.get("timelineTime")
    lines = [f"Viewer frame {'captured' if status == 'ok' else 'FAILED'} for '{r.get('name', '')}' "
             f"({r.get('handle', handle)}) at {_secs3(tt)}"]
    restored = r.get("playheadRestored")
    if isinstance(r.get("playheadBefore"), (int, float)):
        lines.append(f"  playhead: {_secs3(r.get('playheadBefore'))} -> {_secs3(r.get('playheadAtCapture'))} "
                     f"at capture -> restored: {'yes' if restored else 'NO'}")
        if not restored:
            lines.append(f"  WARNING: the playhead was not restored; seek_to_time({r.get('playheadBefore')}) puts it back")
    elif restored is False:
        lines.append("  WARNING: the playhead was moved and its previous position could not be read, so it was "
                     "not restored; check get_playhead_position()")
    if r.get("path"):
        lines.append(f"  PNG: {r['path']}")
    capture = r.get("capture") if isinstance(r.get("capture"), dict) else {}
    frame = r.get("frame") if isinstance(r.get("frame"), dict) else None
    if frame:
        where = ("as rendered in the Viewer (effects included)" if capture.get("cropped", True)
                 else "of the whole FCP window (the Viewer could not be isolated; effects included)")
        lines.append(f"  frame: {frame.get('width')}x{frame.get('height')} JPEG {where}")
    if capture.get("flat") or r.get("flat"):
        lines.append("  WARNING: " + str(capture.get("warning") or r.get("warning")
                                         or "the Viewer image is one flat colour: not a verified frame"))
    failure = r.get("failure") or r.get("error")
    if failure:
        lines.append(f"  failure: {failure}")

    image = None
    if frame and frame.get("base64"):
        image = _image_content(data=_decode_base64_image(frame.get("base64")),
                               fmt=frame.get("format") or "jpeg")
        if image is None and Image is None:
            lines.append("  (frame available as base64 in the raw RPC timeline.captureClipFrame)")
    return _maybe_with_image("\n".join(lines), image)


# ============================================================
# Capture Viewer Screenshot
# ============================================================
# Captures the viewer/canvas contents directly — no external
# screencapture tool needed, no other windows in the way.

@splicekit_tool("capture_viewer")
def capture_viewer(path: str = "/tmp/splicekit_viewer.png", return_image: bool = True):
    """Capture the FCP viewer/canvas as a PNG screenshot.

    Screenshots the viewer area only (cropped from the FCP window, not the
    whole screen). Captures the window's content directly (CGWindowListCreateImage),
    so FCP need not be frontmost. Flat detection trims uniform Viewer chrome /
    letterbox bars and tests the inner content; `flat: true` with a WARNING can mean
    a genuinely flat frame (black, a gap) or that nothing rendered in the content area.

    Use after: applying effects, color correction, titles, captions, or
    any change visible in the canvas. Read the resulting PNG to visually
    verify text rendering, font/size, position, color, and compositing.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_viewer.png
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, and file size, plus the image itself
    when return_image is True. The saved PNG can also be read from disk.
    """
    r = bridge.call("viewer.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        text = (f"Viewer captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)


# ============================================================
# Audio levels (timeline.getAudioLevels)
# ============================================================

_SPARK_BLOCKS = "▁▂▃▄▅▆▇█"
_AUDIO_DB_LO, _AUDIO_DB_HI = -60.0, 0.0


def _is_num(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


def _num_list(values, fill=-100.0):
    """Floats for a list of dB values; a missing, non-numeric or NaN entry becomes `fill` so
    positions stay aligned with the other array."""
    if not isinstance(values, (list, tuple)):
        return []
    return [float(v) if _is_num(v) else fill for v in values]


def _sparkline(values, columns=100, lo=_AUDIO_DB_LO, hi=_AUDIO_DB_HI):
    """One line of block characters for a series of dB values: the maximum of each column,
    mapped from lo..hi onto eight levels. Left is the start of the series. One column per
    value, or per 1/columns of the series when it is longer than that."""
    vals = [float(v) for v in (values or []) if _is_num(v)]
    if not vals or hi <= lo:
        return ""
    n = len(vals)
    columns = max(1, min(int(columns), n))
    out = []
    for c in range(columns):
        a = c * n // columns
        b = max(a + 1, (c + 1) * n // columns)
        f = (max(vals[a:b]) - lo) / (hi - lo)
        f = 0.0 if f < 0 else (1.0 if f > 1 else f)
        out.append(_SPARK_BLOCKS[min(7, int(f * 8))])
    return "".join(out)


def _db(value):
    return f"{value:.1f} dB" if _is_num(value) else "?"


def _ms(value, fallback="?"):
    return f"{value * 1000:.0f} ms" if _is_num(value) else fallback


def _audio_place(clip):
    return "primary storyline" if not clip.get("connected") else f"lane {clip.get('lane')} (connected clip)"


def _render_audio_levels(r: dict, detail: str) -> str:
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    slice_s = r.get("sliceSeconds")
    silence = r.get("silenceDb") if _is_num(r.get("silenceDb")) else -50.0
    edge = r.get("edgeSeconds")
    clips = [c for c in (r.get("clips") or []) if isinstance(c, dict)]
    cuts = [c for c in (r.get("cuts") or []) if isinstance(c, dict)]
    skipped = [k for k in (r.get("skipped") or []) if isinstance(k, dict)]
    lines = ["Audio levels in dBFS measured by SpliceKit from each clip's source media file (0 = full scale; "
             "-100 is the floor for a slice with no sample above 1e-5). Not Final Cut Pro's audio meters (the mix "
             "during playback) and not its timeline waveforms (which follow the clip's volume and effects): FCP's "
             "volume, fades, effects, retiming and the mix of all concurrent clips are NOT applied. Channels are "
             "pooled, not mixed: a slice's peak is the loudest sample in any channel and its RMS is over all "
             "channels' samples (for a file with one audio track, the figures ffmpeg's volumedetect gives for the "
             "same range), unless a clip's line says mixdownMono."]
    rng = ""
    if _is_num(tl.get("rangeStartSeconds")) or _is_num(tl.get("rangeEndSeconds")):
        rng = (f"; requested range {_s3(tl.get('rangeStartSeconds')) if _is_num(tl.get('rangeStartSeconds')) else 'start'}"
               f" to {_s3(tl.get('rangeEndSeconds')) if _is_num(tl.get('rangeEndSeconds')) else 'end'}")
    fps = tl.get("frameRate")
    head = (f"Slice requested {_ms(slice_s, '50 ms')} (each clip line shows its own); silence below "
            f"{silence:.0f} dB; edge window {_ms(edge, '100 ms')}, rounded up to whole slices")
    if _is_num(fps):
        head += f"; timeline {fps:g} fps, {_s3(tl.get('durationSeconds'))}"
    lines.append(head + rng + ".")
    errors = sum(1 for c in clips if c.get("error"))
    skips = len(skipped) + sum(1 for c in clips if c.get("skipped"))
    neighbours = sum(1 for c in clips if c.get("role") == "neighbor")
    summary = (f"Clips considered: {r.get('clipCount', len(clips))}; analyzed: {r.get('analyzedCount', 0)}"
               + (f" (including {neighbours} neighbour{'s' if neighbours != 1 else ''} of the requested clip, summary only)"
                  if neighbours else "")
               + f"; skipped: {skips}; errors: {errors}")
    if r.get("outsideRangeCount"):
        summary += f"; outside the range: {r.get('outsideRangeCount')}"
    if r.get("truncatedTo"):
        summary += f"; only the first {r.get('truncatedTo')} analyzed (narrow the range or pass handles)"
    lines.append(summary + ".")

    for clip in clips:
        role = "Neighbour clip" if clip.get("role") == "neighbor" else "Clip"
        head = (f"\n{role} {clip.get('handle')} \"{clip.get('name')}\"  {_audio_place(clip)}  "
                f"{_s3(clip.get('startSeconds'))}-{_s3(clip.get('endSeconds'))} ({_s3(clip.get('durationSeconds'))})")
        if clip.get("role") == "neighbor":
            head += "  [analyzed for the cut comparison; summary only]"
        lines.append(head)
        if clip.get("error"):
            lines.append(f"  error: {clip['error']}")
            if clip.get("note"):
                lines.append(f"  note: {clip['note']}")
            continue
        if clip.get("skipped"):
            lines.append(f"  skipped: {clip['skipped']}")
            continue
        src = clip.get("source") if isinstance(clip.get("source"), dict) else {}
        audio = clip.get("audio") if isinstance(clip.get("audio"), dict) else {}
        st = clip.get("stats") if isinstance(clip.get("stats"), dict) else {}
        sl = clip.get("slices") if isinstance(clip.get("slices"), dict) else {}
        rate = audio.get("sampleRate")
        rate_s = f"{rate:g} Hz" if _is_num(rate) else "? Hz"
        a_slice = audio.get("sliceSeconds") if _is_num(audio.get("sliceSeconds")) else slice_s
        mode = audio.get("channelsMode")
        ch_n = audio.get("channels") if _is_num(audio.get("channels")) else "?"
        if mode == "pooled":
            ch_s = f"{ch_n} ch pooled"
            tracks = audio.get("audioTrackCount")
            decoded = audio.get("tracksDecoded")
            if _is_num(tracks) and tracks > 1:
                ch_s += f" over {decoded if _is_num(decoded) else tracks} of {tracks} audio tracks"
        elif mode == "mixdownMono":
            ch_s = ("1 ch mixdownMono (the decoder's mono mixdown, the fallback when no track decodes at its own "
                    "channel count: it reads 3 dB above either channel on a dual-mono file, two channels carrying "
                    "the same signal; more such channels read higher)")
        else:
            ch_s = f"{ch_n} ch decoded ({mode})"
        lines.append(f"  source: {src.get('fileName')} ({src.get('representation')}) file "
                     f"{_s3(src.get('fileStart'))}-{_s3(src.get('fileEnd'))}; {rate_s}, {ch_s}, "
                     f"{audio.get('sliceCount')} slices of {_ms(a_slice)}")
        ar = clip.get("analysisRange") if isinstance(clip.get("analysisRange"), dict) else {}
        if ar and (ar.get("startSeconds") != clip.get("startSeconds") or ar.get("endSeconds") != clip.get("endSeconds")):
            lines.append(f"  analyzed: {_s3(ar.get('startSeconds'))}-{_s3(ar.get('endSeconds'))} (the requested range)")
        count = audio.get("sliceCount") if _is_num(audio.get("sliceCount")) else 0
        silent = st.get("silentSlices") if _is_num(st.get("silentSlices")) else 0
        pct = f" ({100.0 * silent / count:.0f}%)" if count else ""
        lines.append(f"  peak max {_db(st.get('maxPeakDb'))} at {_s3(st.get('maxPeakAtSeconds'))}; "
                     f"RMS mean {_db(st.get('meanRmsDb'))}; slices at full scale (peak >= -0.1 dBFS) "
                     f"{st.get('clippedSlices', 0)}; slices below {silence:.0f} dB {silent}/{count}{pct}"
                     + ("; ALL BELOW THE SILENCE THRESHOLD" if st.get("allSilent") else ""))
        # channels="separate": the same figures per channel of the first audio track.
        for i, ch in enumerate(sl.get("perChannel") if isinstance(sl.get("perChannel"), list) else []):
            if isinstance(ch, dict) and _is_num(ch.get("maxPeakDb")):
                lines.append(f"  ch{i + 1}: peak max {_db(ch.get('maxPeakDb'))}; RMS mean {_db(ch.get('meanRmsDb'))}; "
                             f"slices at full scale {ch.get('clippedSlices', 0)}")
        lines.append(f"  start: {_s3(st.get('headSilenceSeconds'))} below threshold, first window RMS "
                     f"{_db(st.get('headRmsDb'))} (peak {_db(st.get('headPeakDb'))}); end: "
                     f"{_s3(st.get('tailSilenceSeconds'))} below threshold, last window RMS "
                     f"{_db(st.get('tailRmsDb'))} (peak {_db(st.get('tailPeakDb'))}); window {_ms(st.get('edgeSeconds'))}")
        if clip.get("retimed") is True and not clip.get("note"):
            lines.append(f"  retimed: FCP's {clip.get('retimeSelector') or 'retime flag'} is true (a speed change, or "
                         "possibly a frame-rate conform); levels mapped at normal speed, so they may not match playback")
        elif clip.get("retimed") == "unknown":
            lines.append("  retimed: unknown (no retime flag found on this clip's object; if it is retimed, the "
                         "levels do not match playback)")
        if clip.get("note"):
            lines.append(f"  note: {clip['note']}")
        if sl.get("rmsDb"):
            lines.append(f"  RMS  {_sparkline(sl.get('rmsDb'))}")
            lines.append(f"  peak {_sparkline(sl.get('peakDb'))}")
            per_channel = sl.get("perChannel") if isinstance(sl.get("perChannel"), list) else []
            for i, ch in enumerate(per_channel):
                if isinstance(ch, dict) and ch.get("rmsDb"):
                    lines.append(f"  ch{i + 1} RMS {_sparkline(ch.get('rmsDb'))}")
        if detail == "full" and sl:
            compact = {k: sl.get(k) for k in ("startSeconds", "sliceSeconds", "count", "peakDb", "rmsDb",
                                              "clippedSliceIndices") if k in sl}
            if sl.get("perChannel"):
                compact["perChannel"] = sl.get("perChannel")
            lines.append("  slices: " + json.dumps(compact, separators=(",", ":")))

    if cuts:
        lines.append("\nCuts between analysed primary-storyline clips (outgoing clip's last window -> incoming "
                     "clip's first window):")
        for cut in cuts:
            out = cut.get("outgoing") if isinstance(cut.get("outgoing"), dict) else {}
            inc = cut.get("incoming") if isinstance(cut.get("incoming"), dict) else {}
            at = _s3(cut.get("atSeconds"))
            if cut.get("transition"):
                lines.append(f"  {at}  \"{out.get('name')}\" -> \"{inc.get('name')}\": transition {cut['transition']} "
                             f"(FCP crossfades attached audio under a transition; whether this audio is expanded "
                             f"or detached is not checked)")
            elif _is_num(cut.get("jumpDb")):
                flags = []
                if cut.get("outgoingEndsInSilence"):
                    flags.append("outgoing ends below the silence threshold")
                if cut.get("incomingStartsInSilence"):
                    flags.append("incoming starts below the silence threshold")
                lines.append(f"  {at}  \"{out.get('name')}\" end {_db(out.get('tailRmsDb'))} -> "
                             f"\"{inc.get('name')}\" start {_db(inc.get('headRmsDb'))}  jump {cut['jumpDb']:+.1f} dB"
                             + (f"  ({'; '.join(flags)})" if flags else ""))
            else:
                lines.append(f"  {at}  \"{out.get('name')}\" -> \"{inc.get('name')}\": {cut.get('note', 'not a straight cut')}")
    if skipped:
        shown = "; ".join(f"{k.get('handle')} \"{k.get('name')}\" ({k.get('reason')})" for k in skipped[:20])
        more = f"; and {len(skipped) - 20} more" if len(skipped) > 20 else ""
        lines.append(f"\nSkipped: {shown}{more}")
    lines.append("\nSparklines: -60..0 dB over eight levels, one column per slice (or per 1/100 of the clip when it "
                 "has more than 100 slices), left = clip start. Raw arrays: detail=\"full\" or the RPC "
                 "timeline.getAudioLevels. `slice`, `edge window`, `jump` and the sparkline are SpliceKit's "
                 "bookkeeping, not FCP terms.")
    return "\n".join(lines)


def _png_encode(width: int, height: int, rgb: bytearray) -> bytes:
    """A minimal PNG (8-bit RGB, no filtering) from a packed RGB buffer."""
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def _render_audio_levels_png(r: dict, width: int = 1200):
    """A waveform strip of every analyzed clip that carries slices: one row per lane (upper lanes
    on top, the primary storyline, then lanes below), x = timeline seconds across the analyzed
    span (clamped to the requested range), symmetric bars (light = peak, dark = RMS, -60..0 dB),
    red top marks where a slice peaked at full scale, white lines at straight cuts between analysed
    primary-storyline clips, grey lines at regular time ticks. Returns (png_bytes, legend) or
    (None, None) when nothing was analyzed."""
    clips = []
    for c in (r.get("clips") or []):
        if not isinstance(c, dict) or not isinstance(c.get("slices"), dict) or not c.get("stats"):
            continue
        ar = c.get("analysisRange") if isinstance(c.get("analysisRange"), dict) else {}
        a0 = ar.get("startSeconds") if _is_num(ar.get("startSeconds")) else c.get("startSeconds")
        a1 = ar.get("endSeconds") if _is_num(ar.get("endSeconds")) else c.get("endSeconds")
        if _is_num(a0) and _is_num(a1) and a1 > a0:
            clips.append((float(a0), float(a1), c))
    if not clips:
        return None, None
    width = max(200, min(int(width), 4000))
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    span_lo = min(a for a, _, _ in clips)
    span_hi = max(b for _, b, _ in clips)
    t0 = max(float(tl["rangeStartSeconds"]), span_lo) if _is_num(tl.get("rangeStartSeconds")) else span_lo
    t1 = min(float(tl["rangeEndSeconds"]), span_hi) if _is_num(tl.get("rangeEndSeconds")) else span_hi
    if t1 <= t0:
        return None, None
    lanes = sorted({int(c.get("lane")) if _is_num(c.get("lane")) else 0 for _, _, c in clips}, reverse=True)
    row_h, gutter, top, bottom = 88, 4, 14, 6
    height = top + len(lanes) * (row_h + gutter) + bottom
    bg, row_bg, clip_bg = (28, 28, 30), (36, 36, 38), (44, 44, 46)
    peak_col, rms_col, red, white = (74, 127, 181), (142, 197, 255), (255, 69, 58), (255, 255, 255)
    tick_col, edge_col, baseline = (58, 58, 60), (12, 12, 12), (70, 70, 74)
    buf = bytearray(bytes(bg) * (width * height))

    def fill(x0, y0, x1, y1, col):
        x0, x1 = max(0, min(x0, x1)), min(width, max(x0, x1))
        y0, y1 = max(0, min(y0, y1)), min(height, max(y0, y1))
        if x1 <= x0 or y1 <= y0:
            return
        row = bytes(col) * (x1 - x0)
        for y in range(y0, y1):
            off = (y * width + x0) * 3
            buf[off:off + len(row)] = row

    px_per_s = (width - 2) / (t1 - t0)

    def X(t):
        return int(round(1 + (t - t0) * px_per_s))

    span = t1 - t0
    tick = 600.0
    for cand in (0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600):
        if span / cand <= 16:
            tick = float(cand)
            break
    import math as _m
    if span / tick <= width:
        k = _m.ceil(t0 / tick)
        drawn = 0
        while k * tick <= t1 and drawn <= width:
            fill(X(k * tick), 0, X(k * tick) + 1, height, tick_col)
            k += 1
            drawn += 1

    cuts_x = [X(float(c.get("atSeconds"))) for c in (r.get("cuts") or [])
              if isinstance(c, dict) and _is_num(c.get("jumpDb")) and _is_num(c.get("atSeconds"))]
    half = row_h // 2 - 2
    for i, lane in enumerate(lanes):
        y0 = top + i * (row_h + gutter)
        y1 = y0 + row_h
        mid = y0 + row_h // 2
        fill(0, y0, width, y1, row_bg)
        fill(0, mid, width, mid + 1, baseline)
        for a0, a1, c in clips:
            c_lane = int(c.get("lane")) if _is_num(c.get("lane")) else 0
            if c_lane != lane:
                continue
            xa, xb = X(a0), X(a1)
            fill(xa, y0, xb, y1, clip_bg)
            fill(xa, y0, xa + 1, y1, edge_col)
            fill(xb - 1, y0, xb, y1, edge_col)
            fill(xa + 1, mid, xb - 1, mid + 1, baseline)   # under the bars: a silent slice shows it
            sl = c["slices"]
            peak = _num_list(sl.get("peakDb"))
            rms = _num_list(sl.get("rmsDb"))
            n = min(len(peak), len(rms))
            ss = sl.get("sliceSeconds") if _is_num(sl.get("sliceSeconds")) and sl.get("sliceSeconds") > 0 else None
            if ss is None:
                ss = r.get("sliceSeconds") if _is_num(r.get("sliceSeconds")) and r.get("sliceSeconds") > 0 else 0.05
            s0 = float(sl.get("startSeconds")) if _is_num(sl.get("startSeconds")) else a0
            idx = sl.get("clippedSliceIndices")
            clipped_idx = {int(v) for v in idx if _is_num(v)} if isinstance(idx, list) else None
            if n == 0:
                continue
            for x in range(max(xa, 0), min(xb, width)):
                ta = t0 + (x - 1) / px_per_s
                tb = t0 + x / px_per_s
                ia = int((ta - s0) / ss)
                ib = int((tb - s0) / ss)
                ia = 0 if ia < 0 else (n - 1 if ia > n - 1 else ia)
                ib = ia if ib < ia else (n - 1 if ib > n - 1 else ib)
                p = max(peak[ia:ib + 1])
                q = max(rms[ia:ib + 1])
                fp = (p - _AUDIO_DB_LO) / (_AUDIO_DB_HI - _AUDIO_DB_LO)
                fq = (q - _AUDIO_DB_LO) / (_AUDIO_DB_HI - _AUDIO_DB_LO)
                hp = int(half * (0.0 if fp < 0 else (1.0 if fp > 1 else fp)))
                hq = int(half * (0.0 if fq < 0 else (1.0 if fq > 1 else fq)))
                if hp > 0:
                    fill(x, mid - hp, x + 1, mid + hp + 1, peak_col)
                if hq > 0:
                    fill(x, mid - hq, x + 1, mid + hq + 1, rms_col)
                at_full_scale = (any(j in clipped_idx for j in range(ia, ib + 1)) if clipped_idx is not None
                                 else p >= -0.1)
                if at_full_scale:
                    fill(x, y0, x + 1, y0 + 3, red)
        if lane == 0:
            for x in cuts_x:
                fill(x, y0, x + 1, y1, white)
    legend = {"width": width, "height": height, "lanes": lanes, "startSeconds": round(t0, 3),
              "endSeconds": round(t1, 3), "tickSeconds": tick}
    return _png_encode(width, height, buf), legend


@splicekit_tool("get_audio_levels")
def get_audio_levels(handle: str = "", handles: list[str] | None = None,
                     start_seconds: float | None = None, end_seconds: float | None = None,
                     slice_ms: int = 50, channels: str = "mix", edge_ms: int = 100,
                     silence_db: float = -50.0, detail: str = "summary",
                     include_image: bool = True, image_width: int = 1200,
                     max_slices_per_clip: int = 600):
    """Audio levels of timeline clips over time, measured by SpliceKit from each clip's
    source media file: per slice the peak and the RMS level in dBFS, the way an editor
    reads a waveform. These are NOT Final Cut Pro's audio meters (which show the level of
    the mix during playback) and NOT FCP's timeline waveforms (which change with the
    clip's volume and effects); see "What the numbers are NOT". Read-only: never moves
    the playhead or the selection, never changes the project.

    Scope: one clip (`handle`, from get_timeline_clips(); its nearest primary-storyline
    neighbours with audio are analyzed too, summary only, so the cuts on both sides are
    compared), several clips (`handles`; pass one of the two, not both), a timeline range
    (`start_seconds` / `end_seconds`: every clip with audio overlapping it, each analyzed
    only inside the range), or no arguments for every clip with audio on the timeline,
    primary storyline and connected clips, at most the first 100 in timeline order (the
    answer says when it stopped; narrow with a range or handles). A whole timeline can
    take minutes: each clip's range is decoded by a helper process. Transitions, gap
    clips, titles and generators have no audio of their own, a compound or multicam clip
    has no single source media file, and a connected storyline container is analyzed
    through its clips;
    all are listed as skipped with the reason.

    Per clip: the source media file and where the clip lies in it, the sample rate and the
    number of channels pooled (and of audio tracks, when the file has several), then per slice (`slice_ms`,
    default 50 ms; lengthened for a clip that would otherwise exceed `max_slices_per_clip`
    slices, so with the defaults any clip longer than 30 s gets longer slices; each clip's
    actual slice length is reported) the peak level and the RMS level in dBFS (0 = full
    scale; -100 is the floor SpliceKit reports for a slice with no sample above 1e-5; a
    decoded peak can exceed 0), placed in timeline seconds. Summary numbers: the loudest
    slice and when, the mean RMS, how many slices peaked at or above -0.1 dBFS (at full
    scale: possible clipping; FCP's waveforms and meters turn red when a level exceeds
    0 dB), how many are below `silence_db`, the seconds below `silence_db` at the clip's
    start and end, and the RMS and peak of the first and last `edge_ms` (rounded up to
    whole slices, so at least one slice; the actual window is reported). The text carries a
    sparkline of RMS and of peak per clip; `detail="full"` appends the raw arrays as JSON.
    The image (`include_image`) is a waveform strip: one row per lane, x = timeline
    seconds, light bars = peak, dark = RMS, red top marks = slices at full scale, white
    lines = straight cuts between analyzed primary-storyline clips.

    Cuts: for neighbouring primary-storyline clips that were both analyzed, the outgoing
    clip's last window against the incoming clip's first window (`edge_ms`) and the jump in
    dB, flagging when either side is below `silence_db`. A cut with a transition on it is
    reported as such instead: Final Cut Pro applies an audio crossfade there when the
    clips' audio is attached (not when it is expanded or detached), which this tool does
    not verify. Cuts next to a gap clip, a title, a skipped or failed clip, and cuts
    between connected clips are not compared. That is where a harsh audio cut shows: fix
    it with trim_clip, a fade (direct_timeline_action applyAudioFadesDirect on the selected
    clip) or changeAudioVolume, then call this again.

    What the numbers are NOT: they are decoded from the source media file by SpliceKit's
    audio-levels helper, so Final Cut Pro's volume, fades, effects, retiming and the mix of
    all concurrent clips are not applied (the same way get_clip_info's frame is the raw
    footage). The file-to-timeline mapping always assumes normal speed (100%): for a
    retimed clip the levels and their times do not correspond to what FCP plays. `retimed`
    is FCP's own flag (`isRetimed` on 12.3) and "unknown" when the clip object answers
    none. When the flag is set the note compares two readings of the media file's video,
    its average frame rate over the file and the rate its most common frame duration
    corresponds to (neither is a "nominal" rate), with the project's rate, naming a
    variable-frame-rate recording when they differ; a conform is asserted only when both
    differ from the project's rate, and left open when they straddle it, since which one
    FCP's Rate Conform goes by SpliceKit does not know. A file at another frame rate is
    rate-conformed by FCP (Rate Conform in the Video inspector); a conform was seen to set
    the flag by itself on 12.3 (a 30 fps, variable-frame-rate screen recording in a 29.97
    fps project), and FCP's conform repeats or drops frames without a speed
    change, so the mapping holds for a conform alone; whether a speed change sits on top of
    it SpliceKit cannot tell. Check the clip's Retime state yourself before trusting a
    retimed clip's levels. Channels are pooled, never mixed: up to eight audio tracks of the
    file are decoded, each at its own channel count; a slice's peak is the loudest sample in
    any channel and its RMS is over all channels' samples (for a file with one audio track,
    the figures ffmpeg's volumedetect gives for the same range), so a channel at full scale
    is never hidden by another. `channels="separate"` adds each channel of the first audio
    track when it has more than one (up to eight): its peak max, RMS mean and full-scale
    count, a per-channel RMS sparkline and, with `detail="full"`, per-channel arrays. A clip
    whose line says mixdownMono fell back to the decoder's mono mixdown (no track decoded
    at its own channel count), which reads 3 dB above either channel on a dual-mono file
    (two channels carrying the same signal; more such channels read higher).

    Args:
        handle: one clip's handle (get_timeline_clips()).
        handles: several clips' handles (not together with `handle`).
        start_seconds / end_seconds: timeline range in seconds (either or both).
        slice_ms: slice length in milliseconds (5-5000, default 50).
        channels: "mix" (default) or "separate".
        edge_ms: window for the start/end levels and the cut comparison (10-5000, default 100).
        silence_db: RMS below this counts as silence (default -50).
        detail: "summary" (default) or "full" (raw per-slice arrays appended as JSON).
        include_image: return the waveform strip inline as MCP image content (default True).
        image_width: width of that image in pixels (200-4000, default 1200).
        max_slices_per_clip: the slice is lengthened so no clip reports more (20-4000, default 600).

    `slice`, `edge window`, `jump`, the sparkline and the waveform strip are SpliceKit's own
    bookkeeping, not FCP terms; FCP says straight cut, start point / end point and outgoing /
    incoming clip, and shows levels in dB.
    """
    if channels not in ("mix", "separate"):
        return "Error: channels must be \"mix\" or \"separate\""
    if detail not in ("summary", "full"):
        return "Error: detail must be \"summary\" or \"full\""
    try:
        slice_ms = int(slice_ms)
        edge_ms = int(edge_ms)
        image_width = int(image_width)
        max_slices_per_clip = int(max_slices_per_clip)
        silence_db = float(silence_db)
    except (TypeError, ValueError):
        return "Error: slice_ms, edge_ms, image_width and max_slices_per_clip must be integers; silence_db a number"
    if not 5 <= slice_ms <= 5000:
        return "Error: slice_ms must be between 5 and 5000"
    if not 10 <= edge_ms <= 5000:
        return "Error: edge_ms must be between 10 and 5000"
    if not 200 <= image_width <= 4000:
        return "Error: image_width must be between 200 and 4000"
    if not 20 <= max_slices_per_clip <= 4000:
        return "Error: max_slices_per_clip must be between 20 and 4000"
    if not -100.0 <= silence_db <= 0.0:
        return "Error: silence_db must be between -100 and 0"
    for name, value in (("start_seconds", start_seconds), ("end_seconds", end_seconds)):
        if value is not None and (not isinstance(value, (int, float)) or isinstance(value, bool)
                                  or value != value or value in (float("inf"), float("-inf"))):
            return f"Error: {name} must be a finite number of seconds"
    if start_seconds is not None and end_seconds is not None and end_seconds <= start_seconds:
        return "Error: end_seconds must be greater than start_seconds"
    handle_list = []
    if handles is not None:
        if isinstance(handles, str):
            handles = [handles]
        handle_list = [str(h) for h in handles if h]
        if not handle_list:
            return "Error: handles is empty; pass the clip handles from get_timeline_clips(), or leave it out"
        if handle:
            return "Error: pass handle (one clip) or handles (several), not both"

    params = {"sliceSeconds": slice_ms / 1000.0, "edgeSeconds": edge_ms / 1000.0,
              "silenceDb": silence_db, "perChannel": channels == "separate",
              "maxSlicesPerClip": max_slices_per_clip, "includeSlices": True}
    if handle:
        params["handle"] = handle
    elif handle_list:
        params["handles"] = handle_list
    if start_seconds is not None:
        params["startSeconds"] = float(start_seconds)
    if end_seconds is not None:
        params["endSeconds"] = float(end_seconds)
    # Decoding runs per clip in a helper process; a whole timeline can take minutes.
    r = bridge.call("timeline.getAudioLevels", params, timeout=180.0 if handle else 600.0)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    try:
        text = _render_audio_levels(r, detail)
    except Exception as exc:  # a rendering bug must never discard a finished analysis
        _LOG.exception("get_audio_levels: text rendering failed")
        text = f"(summary not rendered: {type(exc).__name__}: {exc}; raw answer follows)\n{_fmt(r)}"
    image = None
    if include_image:
        try:
            png, legend = _render_audio_levels_png(r, image_width)
        except Exception as exc:
            _LOG.exception("get_audio_levels: image rendering failed")
            png, legend = None, None
            text += f"\n(image not rendered: {type(exc).__name__}: {exc})"
        if png:
            image = _image_content(data=png, fmt="png")
            lanes = ", ".join("primary storyline" if l == 0 else f"lane {l}" for l in legend["lanes"])
            text += (f"\nImage ({legend['width']}x{legend['height']}): rows top to bottom = {lanes}; "
                     f"x = timeline {legend['startSeconds']:.3f}s to {legend['endSeconds']:.3f}s, grey ticks every "
                     f"{legend['tickSeconds']:g} s; light = peak, dark = RMS (-60..0 dB); red top marks = peak at "
                     f"full scale (>= -0.1 dBFS); white lines = straight cuts between analyzed primary-storyline clips.")
            if image is None:
                text += "\n  (image not attached: the mcp Image helper is unavailable in this process)"
    return _maybe_with_image(text, image)


# ============================================================
# Capture Timeline Screenshot
# ============================================================

@splicekit_tool("capture_timeline")
def capture_timeline(path: str = "/tmp/splicekit_timeline.png", return_image: bool = True):
    """Capture the FCP timeline as a PNG screenshot.

    Screenshots the timeline area only (cropped from the FCP window, not the
    whole screen). Captures the window's content directly (CGWindowListCreateImage),
    so FCP need not be frontmost. A one-colour capture is reported with `flat: true`
    and a WARNING line.

    Use after: blade cuts, clip rearrangement, adding/removing markers,
    transitions, trim edits, or any structural timeline change. Read the
    resulting PNG to visually verify clip layout, edit points, gaps,
    markers, transitions, and overall timeline structure.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_timeline.png
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, and file size, plus the image itself
    when return_image is True. The saved PNG can also be read from disk.
    """
    r = bridge.call("timeline.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        text = (f"Timeline captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)


# ============================================================
# Capture Inspector Screenshot
# ============================================================

@splicekit_tool("capture_inspector")
def capture_inspector(path: str = "/tmp/splicekit_inspector.png", class_name: str = "",
                      return_image: bool = True):
    """Capture the FCP Inspector pane as a PNG screenshot.

    Crops the Inspector area from the FCP window. Searches the view hierarchy
    for one of FCP's known inspector root view classes (FFInspectorRootStackView,
    FFInspectorRootOutlineView, FFInspectorOutlineView, etc.) and captures the
    largest matching view.

    Use after applying or modifying an effect on the selected clip to visually
    verify what parameters appear, their values, and custom UI views (e.g.
    FxPlug 4 custom parameter views).

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_inspector.png
        class_name: Optional override — search for a specific NSView subclass
              instead of the default candidate list.
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, file size, and the matched class, plus
    the image itself when return_image is True. The saved PNG can also be read from disk.
    """
    kwargs = {"path": path}
    if class_name:
        kwargs["class_name"] = class_name
    r = bridge.call("inspector.capture", **kwargs)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        matched = r.get("matchedClass", "(full window fallback)")
        text = (f"Inspector captured: {r.get('path')}\n"
                f"Matched class: {matched}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)


# ============================================================
# Export FCPXML (Programmatic, No Dialog)
# ============================================================
# Export the current project to FCPXML without the save dialog.

@splicekit_tool("export_xml")
def export_xml(path: str = "/tmp/splicekit_export.fcpxml") -> str:
    """Export the current project/sequence as FCPXML to a file — no save dialog.

    Programmatically serializes the active timeline's sequence to FCPXML format
    and writes it to the specified path. Unlike timeline_action("exportXML")
    which opens FCP's save dialog, this writes directly.

    timeline_action("exportXML") and some share/export flows can still open modal
    save/open panels; while one is open the bridge cannot serve main-thread RPC.
    Save/open panels cannot be confirmed from the bridge — only
    dismiss_dialog(action=\"cancel\") closes them.

    Args:
        path: Output file path for the FCPXML.
              Default: /tmp/splicekit_export.fcpxml

    The exported FCPXML contains the full project structure including clips,
    effects, titles, markers, and timing. Useful for:
    - Inspecting the project structure (e.g. finding Custom Speed keyframes)
    - Backing up before destructive edits
    - Transferring projects between systems
    """
    r = bridge.call("fcpxml.export", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# OpenTimelineIO Import & Export
# ============================================================
# Universal timeline interchange via OpenTimelineIO. Handles all
# OTIO-supported formats (.otio, .otioz, .otiod) AND .fcpxml via
# the otio-fcpx-xml-adapter. Replaces import_fcpxml / export_xml
# as the primary format tools.

def _otio_prepare_for_fcp(timeline):
    """Prepare an OTIO timeline for FCP import.

    - Converts non-title GeneratorReference clips to gaps
    - Preserves title generators (the adapter writes them as <title> elements)
    - Returns the modified timeline (in-place)
    """
    import opentimelineio as otio
    if not isinstance(timeline, otio.schema.Timeline):
        return timeline
    for track in timeline.tracks:
        for i, item in enumerate(list(track)):
            if (isinstance(item, otio.schema.Clip) and
                    isinstance(item.media_reference, otio.schema.GeneratorReference)):
                if not _otio_is_title_generator_reference(item.media_reference):
                    track[i] = otio.schema.Gap(source_range=item.source_range)
    return timeline


def _otio_is_title_generator_reference(media_reference):
    """Detect title-like GeneratorReference metadata across adapter variants."""
    title_generator_kinds = {"Title", "title", "fcpx.title"}
    gen_kind = getattr(media_reference, "generator_kind", "")
    if gen_kind in title_generator_kinds:
        return True

    parameters = getattr(media_reference, "parameters", {}) or {}
    if not isinstance(parameters, dict):
        return False
    return bool(parameters.get("text_xml") or parameters.get("text_style_def_xml"))


def _otio_fcpx_adapter_candidates():
    """Return compatible FCPXML adapter names in preference order."""
    import opentimelineio as otio

    preferred = ("fcpxml", "fcpx_xml")
    try:
        available = set(otio.adapters.available_adapter_names())
    except Exception:
        available = set()

    ordered = [name for name in preferred if name in available]
    if ordered:
        return ordered
    return list(preferred)


def _otio_with_fcpx_adapter(operation):
    """Run an OTIO adapter operation against the supported FCPXML adapter names."""
    errors = []
    for adapter_name in _otio_fcpx_adapter_candidates():
        try:
            return operation(adapter_name)
        except Exception as exc:
            errors.append(f"{adapter_name}: {exc}")
    raise RuntimeError("No working FCPXML adapter found (" + "; ".join(errors) + ")")


def _otio_fcpxml_parse_root(fcpxml_str):
    """Parse FCPXML text into an ElementTree root."""
    from xml.etree import ElementTree as ET

    return ET.fromstring(fcpxml_str)


def _otio_fcpx_time_to_seconds(value, default_rate=30):
    """Convert an FCPXML time attribute (e.g. ``28s``, ``300/30s``) to seconds."""
    if not value:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    if text.endswith("s"):
        text = text[:-1].strip()
    if "/" in text:
        num, den = text.split("/", 1)
        return float(num) / float(den)
    try:
        return float(text)
    except ValueError:
        return 0.0


def _otio_fcpx_sequence_rate(sequence_elem, resources_elem, default_rate=30):
    """Resolve the frame rate for a ``<sequence>`` from its format resource."""
    format_id = sequence_elem.get("format") if sequence_elem is not None else None
    if not format_id or resources_elem is None:
        return default_rate
    for fmt in resources_elem.findall("format"):
        if fmt.get("id") == format_id:
            frame_duration = fmt.get("frameDuration", "")
            seconds = _otio_fcpx_time_to_seconds(frame_duration, default_rate)
            if seconds > 0:
                return round(1.0 / seconds)
    return default_rate


# --- FCPXML -> OTIO, without the adapter ------------------------------------
#
# otio-fcpx-xml-adapter 1.0 was the only reader here, and it lost the timeline:
# exporting a project of three storyline clips plus one connected clip reported
# "1 track, 2 clips", every clip came back as a MissingReference, and re-importing
# produced gaps. Three separate causes — a compound clip it crashes on, anchored
# clips it does not place on a lane, and media references it does not carry — so
# the FCPXML Final Cut Pro writes is now read directly. The adapter stays as a
# fallback for FCPXML shapes this does not recognise.

_FCPX_TIMED_TAGS = {
    "asset-clip", "clip", "ref-clip", "video", "audio", "title", "gap",
    "sync-clip", "mc-clip", "transition", "audition",
}


def _otio_fcpx_fraction(value, default="0s"):
    """An FCPXML time ("1001/30000s", "20s", "0s") as an exact Fraction of seconds."""
    from fractions import Fraction

    text = (value if value is not None else default)
    text = str(text).strip()
    if text.endswith("s"):
        text = text[:-1]
    if not text:
        return Fraction(0)
    if "/" in text:
        numerator, denominator = text.split("/", 1)
        return Fraction(int(numerator), int(denominator))
    return Fraction(text)


def _otio_fcpx_format_time(value):
    """A Fraction of seconds back as an FCPXML time string."""
    from fractions import Fraction

    value = Fraction(value)
    if value.denominator == 1:
        return f"{value.numerator}s"
    return f"{value.numerator}/{value.denominator}s"


def _otio_fcpx_media_spine(resources_elem, ref):
    """The spine inside the ``<media>`` resource a ``<ref-clip>`` points at."""
    if resources_elem is None or not ref:
        return None
    for media in resources_elem.findall("media"):
        if media.get("id") != ref:
            continue
        sequence = media.find("sequence")
        if sequence is not None:
            return sequence.find("spine")
    return None


_OTIO_FCPX_MAX_COMPOUND_DEPTH = 8


def _otio_fcpx_expand_ref_clip(ref_clip, inner_spine, resources_elem=None,
                               notes=None, _seen=frozenset()):
    """One ``<ref-clip>`` as the clips it actually contains, trimmed as it is trimmed.

    A compound clip can hold another compound clip. Those inner ``<ref-clip>`` elements
    live in ``<resources>``, not under the project, so the flattening pass never walked
    to them: one was copied through untouched and later resolved against the asset index,
    where a ``<media>`` id matches no ``<asset>``, so it turned into a clip with a
    MissingReference while the note still said the compound clip had been flattened.
    Expansion now recurses, carrying the resource index with it, and refuses to follow a
    compound clip that contains itself.
    """
    import copy

    ref_offset = _otio_fcpx_fraction(ref_clip.get("offset"))
    ref_start = _otio_fcpx_fraction(ref_clip.get("start"))
    ref_end = ref_start + _otio_fcpx_fraction(ref_clip.get("duration"))
    if notes is None:
        notes = []

    expanded = []
    for inner in inner_spine:
        if inner.tag not in _FCPX_TIMED_TAGS:
            continue
        inner_offset = _otio_fcpx_fraction(inner.get("offset"))
        inner_end = inner_offset + _otio_fcpx_fraction(inner.get("duration"))
        visible_from = max(inner_offset, ref_start)
        visible_to = min(inner_end, ref_end)
        if visible_to <= visible_from:
            continue  # trimmed out of the compound clip entirely
        clip = copy.deepcopy(inner)
        clip.set("offset", _otio_fcpx_format_time(ref_offset + (visible_from - ref_start)))
        clip.set("duration", _otio_fcpx_format_time(visible_to - visible_from))
        if inner.tag != "gap":
            clip.set("start", _otio_fcpx_format_time(
                _otio_fcpx_fraction(inner.get("start")) + (visible_from - inner_offset)))
        clip.attrib.pop("lane", None)

        # A compound clip inside this one. `clip` already carries timeline offset and the
        # in-point into the nested media, which is exactly what this function expects.
        if clip.tag == "ref-clip" and resources_elem is not None:
            nested_ref = clip.get("ref", "")
            name = clip.get("name", "?")
            if nested_ref in _seen or len(_seen) >= _OTIO_FCPX_MAX_COMPOUND_DEPTH:
                notes.append(
                    f"compound clip {name!r} kept as is: it is nested inside itself"
                    if nested_ref in _seen else
                    f"compound clip {name!r} kept as is: nested more than "
                    f"{_OTIO_FCPX_MAX_COMPOUND_DEPTH} compound clips deep")
                expanded.append(clip)
                continue
            nested_spine = _otio_fcpx_media_spine(resources_elem, nested_ref)
            if nested_spine is None:
                notes.append(f"compound clip {name!r} kept as is: "
                             "its contents are not in this document")
                expanded.append(clip)
                continue
            sub = _otio_fcpx_expand_ref_clip(clip, nested_spine, resources_elem,
                                             notes, _seen | {nested_ref})
            if sub:
                notes.append(f"compound clip {name!r} nested inside another one "
                             f"flattened into {len(sub)} clip(s)")
                expanded.extend(sub)
                continue
            expanded.append(clip)
            continue

        expanded.append(clip)

    # The compound clip's own connected clips move onto whichever of the expanded
    # clips now covers the moment they were anchored at. An anchored offset is in its
    # parent's local time, so it is converted to timeline time and back again.
    visible_span_end = ref_offset + (ref_end - ref_start)
    for child in list(ref_clip):
        if child.tag not in _FCPX_TIMED_TAGS or not child.get("lane"):
            continue
        anchored_at = ref_offset + (_otio_fcpx_fraction(child.get("offset")) - ref_start)
        host = None
        for candidate in expanded:
            candidate_offset = _otio_fcpx_fraction(candidate.get("offset"))
            if candidate_offset <= anchored_at < candidate_offset + _otio_fcpx_fraction(
                    candidate.get("duration")):
                host = candidate
                break
        if host is None:
            # It used to fall back to expanded[0], which silently moved a connected clip
            # anchored in a trimmed-away part of the compound clip onto the first visible
            # clip, at an offset that meant nothing. If the moment it was anchored to is
            # not on the timeline any more, neither is it — and that gets reported.
            if not (ref_offset <= anchored_at < visible_span_end):
                notes.append(
                    f"connected clip {child.get('name', '?')!r} dropped: it was anchored "
                    f"inside the part of compound clip {ref_clip.get('name', '?')!r} that "
                    "is trimmed off")
            else:
                notes.append(
                    f"connected clip {child.get('name', '?')!r} dropped: nothing in "
                    f"compound clip {ref_clip.get('name', '?')!r} covers the moment it "
                    "was anchored at")
            continue
        moved = copy.deepcopy(child)
        moved.set("offset", _otio_fcpx_format_time(
            _otio_fcpx_fraction(host.get("start"))
            + (anchored_at - _otio_fcpx_fraction(host.get("offset")))))
        host.append(moved)
    return expanded


def _otio_fcpx_flatten_ref_clips(project_elem, resources_elem):
    """Replace every ``<ref-clip>`` with the clips it contains, in place.

    OTIO has no compound clip, and the previous answer was to swap each one for a
    gap of the same length: the QA timeline's compound clip, and the connected clip
    anchored inside it, simply vanished. Flattening is what any editor without
    compound clips would receive, and it keeps the media. Returns a list of notes
    for the caller to report.
    """
    notes = []
    for spine in project_elem.iter("spine"):
        rebuilt = []
        changed = False
        for child in list(spine):
            if child.tag != "ref-clip":
                rebuilt.append(child)
                continue
            inner_spine = _otio_fcpx_media_spine(resources_elem, child.get("ref", ""))
            if inner_spine is None:
                rebuilt.append(child)
                notes.append(f"compound clip {child.get('name', '?')!r} kept as is: "
                             "its contents are not in this document")
                continue
            expanded = _otio_fcpx_expand_ref_clip(child, inner_spine, resources_elem,
                                                  notes, frozenset({child.get("ref", "")}))
            if not expanded:
                rebuilt.append(child)
                continue
            changed = True
            anchored = sum(1 for c in child if c.tag in _FCPX_TIMED_TAGS and c.get("lane"))
            notes.append(
                f"compound clip {child.get('name', '?')!r} flattened into "
                f"{len(expanded)} clip(s)"
                + (f", {anchored} connected clip(s) re-anchored" if anchored else "")
                + " — OTIO has no compound clip")
            rebuilt.extend(expanded)
        if changed:
            for child in list(spine):
                spine.remove(child)
            for child in rebuilt:
                spine.append(child)
    return notes


def _otio_fcpx_asset_index(resources_elem):
    """``id`` -> resource element, for every asset, effect, format and media."""
    index = {}
    if resources_elem is None:
        return index
    for child in resources_elem:
        resource_id = child.get("id")
        if resource_id:
            index[resource_id] = child
    return index


def _otio_fcpx_asset_for(element, resources):
    """The ``<asset>`` resource an item plays, following ``ref`` through a wrapper."""
    ref = element.get("ref")
    if not ref:
        for child in element:
            if child.tag in ("video", "audio") and child.get("ref"):
                ref = child.get("ref")
                break
    return resources.get(ref) if ref else None


def _otio_fcpx_media_url(element, resources):
    """The file URL an item plays, following ``ref`` into ``<resources>``."""
    ref = element.get("ref")
    if not ref:
        for child in element:
            if child.tag in ("video", "audio") and child.get("ref"):
                ref = child.get("ref")
                break
    asset = resources.get(ref) if ref else None
    if asset is None:
        return None
    src = asset.get("src")
    if src:
        return src
    media_rep = asset.find("media-rep") if hasattr(asset, "find") else None
    if media_rep is not None and media_rep.get("src"):
        return media_rep.get("src")
    return None


def _otio_fcpx_sequence_format_rate(sequence_elem, resources, default=30):
    """Frames per second for a ``<sequence>``, from its format's frameDuration."""
    from fractions import Fraction

    format_elem = resources.get(sequence_elem.get("format")) if sequence_elem is not None else None
    if format_elem is None:
        for element in resources.values():
            if element.tag == "format" and element.get("frameDuration"):
                format_elem = element
                break
    if format_elem is None or not format_elem.get("frameDuration"):
        return Fraction(default)
    frame = _otio_fcpx_fraction(format_elem.get("frameDuration"))
    if frame <= 0:
        return Fraction(default)
    return 1 / frame


def _otio_fcpx_build_timeline(project_elem, resources_elem):
    """One FCPXML ``<project>`` as an OTIO timeline. Returns (timeline, notes)."""
    import opentimelineio as otio
    from opentimelineio import opentime

    resources = _otio_fcpx_asset_index(resources_elem)
    notes = _otio_fcpx_flatten_ref_clips(project_elem, resources_elem)

    sequence = project_elem.find("sequence")
    if sequence is None:
        raise ValueError("project has no <sequence>")
    spine = sequence.find("spine")
    if spine is None:
        raise ValueError("sequence has no <spine>")

    rate = _otio_fcpx_sequence_format_rate(sequence, resources)
    float_rate = float(rate)

    def frames(seconds):
        return opentime.RationalTime(round(float(seconds) * float_rate), float_rate)

    timeline = otio.schema.Timeline(name=project_elem.get("name", "Timeline"))
    timeline.metadata["fcpx_sequence_duration_seconds"] = float(
        _otio_fcpx_fraction(sequence.get("duration")))

    def make_item(element, host_offset, host_start):
        """An OTIO item for one FCPXML element, or None when it carries no time."""
        if element.tag == "gap":
            return otio.schema.Gap(source_range=opentime.TimeRange(
                frames(0), frames(_otio_fcpx_fraction(element.get("duration")))))
        source_start = _otio_fcpx_fraction(element.get("start"))
        duration = _otio_fcpx_fraction(element.get("duration"))
        url = _otio_fcpx_media_url(element, resources)
        if url:
            reference = otio.schema.ExternalReference(target_url=url)
            # The whole extent of the media, from the <asset> it came from. Leaving it
            # out writes "available_range": null, and a reader has no way to tell how
            # much of the file is there beyond the part this clip uses.
            asset = _otio_fcpx_asset_for(element, resources)
            if asset is not None and asset.get("duration"):
                reference.available_range = opentime.TimeRange(
                    frames(_otio_fcpx_fraction(asset.get("start"))),
                    frames(_otio_fcpx_fraction(asset.get("duration"))))
        elif element.tag in ("title", "video"):
            reference = otio.schema.GeneratorReference(
                name=element.get("name", "") or element.tag)
        else:
            reference = otio.schema.MissingReference()
        clip = otio.schema.Clip(
            name=element.get("name", "") or element.tag,
            media_reference=reference,
            source_range=opentime.TimeRange(frames(source_start), frames(duration)))
        clip.metadata["fcpx"] = {
            "tag": element.tag,
            "timeline_offset_seconds": float(
                host_offset + (_otio_fcpx_fraction(element.get("offset")) - host_start)),
        }
        return clip

    # Lane 0 is the primary storyline; each anchored lane becomes its own track, so
    # a connected clip survives instead of being dropped on the floor.
    lanes = {}
    for child in spine:
        if child.tag not in _FCPX_TIMED_TAGS:
            continue
        offset = _otio_fcpx_fraction(child.get("offset"))
        if child.tag == "transition":
            lanes.setdefault(0, []).append(("transition", offset, child))
            continue
        lanes.setdefault(0, []).append(("item", offset, child))
        host_start = _otio_fcpx_fraction(child.get("start"))
        for anchored in child:
            if anchored.tag not in _FCPX_TIMED_TAGS or not anchored.get("lane"):
                continue
            lane = int(anchored.get("lane"))
            anchored_at = offset + (_otio_fcpx_fraction(anchored.get("offset")) - host_start)
            lanes.setdefault(lane, []).append(("item", anchored_at, anchored))

    for lane in sorted(lanes):
        entries = sorted(lanes[lane], key=lambda e: e[1])
        track = otio.schema.Track(name=str(lane), kind=otio.schema.TrackKind.Video)
        # Starts at zero, not at the first item: a connected clip anchored twelve
        # seconds in needs twelve seconds of gap before it or it lands at the head of
        # the timeline.
        playhead = _otio_fcpx_fraction("0s")
        for kind, offset, element in entries:
            if kind == "transition":
                # Half on each side of the cut, which is where Final Cut Pro centres it.
                half = _otio_fcpx_fraction(element.get("duration")) / 2
                track.append(otio.schema.Transition(
                    name=element.get("name", "Transition"),
                    transition_type=otio.schema.TransitionTypes.SMPTE_Dissolve,
                    in_offset=frames(half), out_offset=frames(half)))
                continue
            if playhead is not None and offset > playhead:
                track.append(otio.schema.Gap(source_range=opentime.TimeRange(
                    frames(0), frames(offset - playhead))))
            item = make_item(element, offset, _otio_fcpx_fraction(element.get("offset")))
            if item is None:
                continue
            track.append(item)
            playhead = offset + _otio_fcpx_fraction(element.get("duration"))
        timeline.tracks.append(track)

    return timeline, notes


def _otio_sanitize_fcpx_project_element(project_elem):
    """Return a copy of ``project_elem`` safe for otio-fcpx-xml-adapter 1.0.

    The published adapter crashes on nested ``<ref-clip>`` compound timelines; a
    gap with the same timing preserves project duration for interchange summaries.
    """
    from xml.etree import ElementTree as ET

    project = ET.fromstring(ET.tostring(project_elem, encoding="unicode"))
    for parent in project.iter():
        for child in list(parent):
            if child.tag != "ref-clip":
                continue
            gap = ET.Element(
                "gap",
                offset=child.get("offset", "0s"),
                name=child.get("name", ""),
                duration=child.get("duration", "0s"),
            )
            idx = list(parent).index(child)
            parent.remove(child)
            parent.insert(idx, gap)
    return project


def _otio_build_fcpx_project_document(resources_elem, project_elem, fcpxml_version="1.14"):
    """Wrap resources + project in a standalone ``<fcpxml>`` document."""
    from xml.etree import ElementTree as ET

    root = ET.Element("fcpxml", version=fcpxml_version)
    root.append(ET.fromstring(ET.tostring(resources_elem, encoding="unicode")))
    root.append(ET.fromstring(ET.tostring(project_elem, encoding="unicode")))
    return ET.tostring(root, encoding="unicode")


def _otio_should_skip_fcpx_library_project(project_elem):
    """Skip FCP scene-detection projects that are not user timelines."""
    name = project_elem.get("name", "")
    return name.endswith(" - Scenes")


def _otio_inject_fcpx_spine_transitions(timeline, spine_elem, default_rate):
    """Insert OTIO ``Transition`` objects for ``<transition>`` spine items."""
    import copy

    import opentimelineio as otio
    from opentimelineio import opentime

    if spine_elem is None:
        return

    spine_children = list(spine_elem)
    if not any(child.tag == "transition" for child in spine_children):
        return

    video_track = None
    for track in timeline.tracks:
        if track.kind == otio.schema.TrackKind.Video:
            video_track = track
            break
    if video_track is None:
        return

    clip_items = [item for item in video_track if isinstance(item, otio.schema.Clip)]
    if not clip_items:
        return

    rebuilt = otio.schema.Track(name=video_track.name, kind=video_track.kind)
    clip_index = 0
    for child in spine_children:
        if child.tag == "clip":
            if clip_index >= len(clip_items):
                break
            rebuilt.append(copy.deepcopy(clip_items[clip_index]))
            clip_index += 1
        elif child.tag == "transition":
            rate = default_rate
            if clip_index < len(clip_items):
                clip = clip_items[clip_index]
                if clip.source_range and clip.source_range.duration.rate > 0:
                    rate = clip.source_range.duration.rate
            duration_seconds = _otio_fcpx_time_to_seconds(child.get("duration", "0s"), rate)
            half_frames = max(1, round((duration_seconds / 2.0) * rate))
            rebuilt.append(
                otio.schema.Transition(
                    name=child.get("name", "Transition"),
                    in_offset=opentime.RationalTime(half_frames, rate),
                    out_offset=opentime.RationalTime(half_frames, rate),
                )
            )

    while clip_index < len(clip_items):
        rebuilt.append(copy.deepcopy(clip_items[clip_index]))
        clip_index += 1

    for track_index, track in enumerate(timeline.tracks):
        if track is video_track:
            timeline.tracks[track_index] = rebuilt
            break


def _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem):
    """Attach FCP sequence duration and spine transitions to an OTIO timeline."""
    sequence_elem = project_elem.find("sequence")
    if sequence_elem is None:
        return
    rate = _otio_fcpx_sequence_rate(sequence_elem, resources_elem)
    duration_attr = sequence_elem.get("duration")
    if duration_attr:
        timeline.metadata["fcpx_sequence_duration_seconds"] = _otio_fcpx_time_to_seconds(
            duration_attr,
            rate,
        )
    spine_elem = sequence_elem.find("spine")
    _otio_inject_fcpx_spine_transitions(timeline, spine_elem, rate)


def _otio_enhance_fcpx_read_result(result, root_elem):
    """Post-process adapter output using the source FCPXML tree."""
    import opentimelineio as otio

    resources_elem = root_elem.find("resources")
    project_elem = root_elem.find("project")
    if project_elem is not None:
        timeline = _otio_first_timeline(result)
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem)
        return result

    library_elem = root_elem.find("library")
    if library_elem is None:
        return result

    projects = []
    for event in library_elem.findall("event"):
        for project in event.findall("project"):
            projects.append(project)

    timelines = _otio_all_timelines(result, collection_fallback=False)
    for timeline, project in zip(timelines, projects):
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project, resources_elem)
    return result


def _otio_read_fcpx_library_collection(root_elem):
    """Read a ``<library>`` document one project at a time."""
    import opentimelineio as otio

    resources_elem = root_elem.find("resources")
    if resources_elem is None:
        raise RuntimeError("FCPXML library is missing a <resources> block.")

    fcpxml_version = root_elem.get("version", "1.14")
    library_elem = root_elem.find("library")
    library_name = library_elem.get("location", "Library") if library_elem is not None else "Library"
    collection = otio.schema.SerializableCollection(name=library_name)

    for event in library_elem.findall("event"):
        for project in event.findall("project"):
            if _otio_should_skip_fcpx_library_project(project):
                continue
            timeline = _otio_fcpx_read_project(project, resources_elem, fcpxml_version)
            if isinstance(timeline, otio.schema.Timeline):
                collection.append(timeline)

    if not len(collection):
        raise RuntimeError("No readable timelines found in FCPXML library.")
    return collection


def _otio_fcpx_read_project(project_elem, resources_elem, fcpxml_version="1.14"):
    """One ``<project>`` as an OTIO timeline, read directly, adapter as the fallback.

    Notes about what could not be carried across (a compound clip flattened, say) end
    up in the timeline's metadata under ``splicekit_notes`` so export_otio can report
    them instead of quietly dropping things.
    """
    import copy

    import opentimelineio as otio

    project_copy = copy.deepcopy(project_elem)
    try:
        timeline, notes = _otio_fcpx_build_timeline(project_copy, resources_elem)
        if notes:
            timeline.metadata["splicekit_notes"] = list(notes)
        return timeline
    except Exception as direct_error:  # noqa: BLE001 - fall back, then report both
        project_xml = _otio_build_fcpx_project_document(
            resources_elem,
            _otio_sanitize_fcpx_project_element(project_elem),
            fcpxml_version=fcpxml_version,
        )
        timeline = _otio_with_fcpx_adapter(
            lambda adapter_name: otio.adapters.read_from_string(project_xml, adapter_name)
        )
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem)
            timeline.metadata["splicekit_notes"] = [
                f"read with otio-fcpx-xml-adapter, not directly ({direct_error}); "
                "a compound clip becomes a gap and connected clips are dropped"
            ]
        return timeline


def _otio_read_fcpx_string(fcpxml_str):
    """Read FCPXML into OTIO: directly when the shape is understood, adapter otherwise."""
    import opentimelineio as otio

    root = _otio_fcpxml_parse_root(fcpxml_str)
    if root.find("library") is not None:
        return _otio_read_fcpx_library_collection(root)

    resources_elem = root.find("resources")
    project_elem = root.find("project")
    if project_elem is None:
        event_elem = root.find("event")
        if event_elem is not None:
            project_elem = event_elem.find("project")
    if project_elem is not None and resources_elem is not None:
        return _otio_fcpx_read_project(project_elem, resources_elem,
                                       root.get("version", "1.14"))

    result = _otio_with_fcpx_adapter(
        lambda adapter_name: otio.adapters.read_from_string(fcpxml_str, adapter_name)
    )
    return _otio_enhance_fcpx_read_result(result, root)


def _otio_write_fcpx_string(timeline, fcpxml_version=None):
    """Write FCPXML using whichever adapter name is installed.

    The modern PR #7 adapter accepts ``fcpxml_version`` for version-aware
    FCPXML 1.0-1.14 output. Older adapters reject that kwarg, so retry without
    it before moving to the next adapter name.
    """
    import opentimelineio as otio

    def write(adapter_name):
        if fcpxml_version:
            try:
                return otio.adapters.write_to_string(
                    timeline,
                    adapter_name,
                    fcpxml_version=fcpxml_version,
                )
            except TypeError as exc:
                if "fcpxml_version" not in str(exc):
                    raise
        return otio.adapters.write_to_string(timeline, adapter_name)

    return _otio_with_fcpx_adapter(write)


def _otio_fcpxmld_info_path(package_path):
    """Return the FCPXML document entrypoint for a `.fcpxmld` package."""
    from pathlib import Path

    package = Path(package_path)
    if not package.exists():
        raise FileNotFoundError(f"FCPXML package does not exist: '{package}'.")
    if not package.is_dir():
        raise NotADirectoryError(f"FCPXML package path is not a directory: '{package}'.")

    info_path = package / "Info.fcpxml"
    if not info_path.is_file():
        raise FileNotFoundError(f"FCPXML package is missing 'Info.fcpxml': '{package}'.")
    return info_path


def _otio_read_fcpx_document(path):
    """Read a `.fcpxml` document or `.fcpxmld` package entrypoint."""
    from pathlib import Path

    document_path = Path(path)
    if document_path.is_dir() or document_path.suffix.lower() == ".fcpxmld":
        document_path = _otio_fcpxmld_info_path(document_path)

    return document_path.read_text(encoding="utf-8")


def _otio_fcpxml_clean_for_paste(fcpxml_str):
    """Clean FCPXML for FCP's pasteboard import.

    - Strips <library> wrapper (pasteboard merges into active library)
    - Strips standalone <asset-clip> elements at event level (browser clutter)
    """
    lines = fcpxml_str.split("\n")
    clean = []
    for line in lines:
        s = line.strip()
        if s in ("<library>", "</library>"):
            continue
        if s.startswith("<asset-clip ") and s.endswith("/>"):
            if (len(line) - len(line.lstrip())) <= 16:
                continue
        clean.append(line)
    return "\n".join(clean)


def _otio_first_timeline(result):
    """Extract the first Timeline from an OTIO read result."""
    timelines = _otio_all_timelines(result, collection_fallback=False)
    if timelines:
        return timelines[0]
    return result

def _otio_all_timelines(result, collection_fallback=True):
    """Extract all Timelines from an OTIO read result."""
    import opentimelineio as otio
    if isinstance(result, otio.schema.Timeline):
        return [result]
    if isinstance(result, otio.schema.SerializableCollection):
        timelines = []
        if hasattr(result, "find_children"):
            timelines = list(result.find_children(descended_from_type=otio.schema.Timeline))
        if not timelines:
            timelines = [
                child
                for item in result
                for child in _otio_all_timelines(item, collection_fallback=False)
            ]
        if timelines:
            return timelines
        return list(result) if collection_fallback else []
    return [result] if collection_fallback else []

def _otio_timeline_summary(timeline):
    """Build a summary dict for an OTIO timeline."""
    import opentimelineio as otio
    info = {"name": getattr(timeline, "name", "unknown")}
    if isinstance(timeline, otio.schema.Timeline):
        info["tracks"] = len(timeline.tracks)
        info["clips"] = len(list(timeline.find_clips()))
        metadata = getattr(timeline, "metadata", None) or {}
        sequence_seconds = metadata.get("fcpx_sequence_duration_seconds")
        if sequence_seconds is not None:
            info["duration_seconds"] = round(float(sequence_seconds), 3)
        else:
            total_dur = timeline.duration()
            if total_dur and total_dur.value > 0 and total_dur.rate > 0:
                info["duration_seconds"] = round(total_dur.value / total_dur.rate, 3)
        # What could not be carried across, said out loud rather than dropped: OTIO
        # has no compound clip, so one gets flattened, and that is worth knowing
        # before the file goes to another editor.
        notes = metadata.get("splicekit_notes")
        if notes:
            info["not_carried_across"] = list(notes)
    return info


def _otio_detect_rate(timeline):
    """Auto-detect frame rate from an OTIO timeline. Returns 24 as default."""
    import opentimelineio as otio
    raw_rate = 24
    if isinstance(timeline, otio.schema.Timeline):
        for clip in timeline.find_clips():
            if clip.source_range and clip.source_range.duration.rate > 1:
                raw_rate = clip.source_range.duration.rate
                break
        else:
            dur = timeline.duration()
            if dur and dur.rate > 1:
                raw_rate = dur.rate
    return _otio_normalize_rate(raw_rate)


def _otio_normalize_rate(rate):
    """Map common approximate frame rates to exact SMPTE values.

    The FCPXML adapter returns integer rates (29 for 29.97fps) and user input
    may use approximate values (29.97). The EDL adapter needs exact fractional
    rates (30000/1001) for drop-frame timecode support.
    """
    rate_map = {
        23: 24000 / 1001,    # 23.976
        23.98: 24000 / 1001,
        23.976: 24000 / 1001,
        24: 24,
        25: 25,
        29: 30000 / 1001,    # 29.97 (FCPXML adapter returns 29)
        29.97: 30000 / 1001,
        30: 30,
        47: 48000 / 1001,
        47.95: 48000 / 1001,
        48: 48,
        50: 50,
        59: 60000 / 1001,    # 59.94
        59.94: 60000 / 1001,
        60: 60,
    }
    # Check exact match first, then closest integer
    if rate in rate_map:
        return rate_map[rate]
    rounded = round(rate)
    if rounded in rate_map:
        return rate_map[rounded]
    return rate


@splicekit_tool("export_otio")
def export_otio(path: str = "/tmp/splicekit_export.otio", rate: float = 0) -> str:
    """Export the current project/sequence via OpenTimelineIO.

    Universal export that handles all OTIO-supported formats including FCPXML.
    Enables timeline interchange with DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that supports OTIO or FCPXML.

    Supported output formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (default, most compatible for NLE exchange)
      .otioz  — OpenTimelineIO bundled with media references (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (uses FCP's native exporter for full fidelity,
                then round-trips through OTIO for normalization)
      .fcpxmld — Final Cut Pro XML package (writes native export to `Info.fcpxml`)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid compatible)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path: Output file path. Extension determines format.
              Default: /tmp/splicekit_export.otio
        rate: Frame rate for EDL export (e.g. 23.98, 24, 29.97, 30).
              Required for .edl, ignored for other formats. If 0, auto-detected
              from timeline.

    Returns:
        JSON with status, output path, timeline name, track/clip counts, and duration,
        plus `not_carried_across` listing anything OTIO has no way to represent — a
        compound clip, for instance, is flattened into the clips it contains.

    Some export paths use FCP's native save dialog instead of writing directly.
    While a modal save/open panel is open the bridge cannot serve main-thread RPC.
    Save/open panels cannot be confirmed from the bridge — only
    dismiss_dialog(action=\"cancel\") closes them.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"

    import tempfile, os

    # For .fcpxml/.fcpxmld output, use FCP's native exporter directly for maximum fidelity.
    if path.lower().endswith((".fcpxml", ".fcpxmld")):
        export_path = path
        if path.lower().endswith(".fcpxmld"):
            os.makedirs(path, exist_ok=True)
            export_path = os.path.join(path, "Info.fcpxml")

        r = bridge.call("fcpxml.export", path=export_path)
        if _err(r):
            return f"Error exporting FCPXML: {r.get('error', r)}"
        # Also parse through OTIO for summary info
        try:
            with open(export_path, "r") as f:
                fcpxml_str = f.read()
            result = _otio_read_fcpx_string(fcpxml_str)
            timeline = _otio_first_timeline(result)
            summary = _otio_timeline_summary(timeline)
        except Exception:
            summary = {}
        summary.update({
            "status": "ok",
            "path": path,
            "bytes": os.path.getsize(export_path),
            "format": "fcpxmld" if path.lower().endswith(".fcpxmld") else "fcpxml",
        })
        return _fmt(summary)

    # For OTIO formats: export FCPXML from FCP, convert via adapter, write target format
    fcpxml_path = os.path.join(tempfile.gettempdir(), "splicekit_otio_export.fcpxml")
    r = bridge.call("fcpxml.export", path=fcpxml_path)
    if _err(r):
        return f"Error exporting FCPXML: {r.get('error', r)}"

    try:
        with open(fcpxml_path, "r") as f:
            fcpxml_str = f.read()
        result = _otio_read_fcpx_string(fcpxml_str)
    except Exception as e:
        return f"Error reading FCPXML into OTIO: {e}"

    timeline = _otio_first_timeline(result)

    # Format-specific write options
    ext = path.rsplit(".", 1)[-1].lower()
    try:
        if ext == "edl":
            # EDL needs a rate; auto-detect from timeline or use provided rate
            edl_rate = _otio_normalize_rate(rate) if rate > 0 else _otio_detect_rate(timeline)
            otio.adapters.write_to_file(timeline, path, rate=edl_rate)
        else:
            otio.adapters.write_to_file(timeline, path)
    except Exception as e:
        hint = ""
        if ext == "aaf" and "mob" in str(e).lower():
            hint = " (AAF requires Avid-specific metadata on clips — try .edl or .otio instead)"
        elif ext == "otioz" and ("NotAFileOnDisk" in type(e).__name__ or "not" in str(e).lower()):
            hint = " (.otioz bundles media files — referenced files must exist on disk)"
        return f"Error writing {ext.upper()} file: {e}{hint}"

    summary = _otio_timeline_summary(timeline)
    summary.update({"status": "ok", "path": path, "bytes": os.path.getsize(path), "format": ext})

    try:
        os.unlink(fcpxml_path)
    except OSError:
        pass

    return _fmt(summary)


@splicekit_tool("import_otio")
def import_otio(path: str = "", otio_json: str = "", rate: float = 0, event: str = "") -> str:
    """Import a timeline file into FCP via OpenTimelineIO.

    Universal import that handles all OTIO-supported formats including FCPXML.
    Enables importing timelines from DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that exports OTIO or FCPXML.

    Supported input formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (DaVinci Resolve, universal)
      .otioz  — OpenTimelineIO bundle (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (sent directly to FCP's native importer
                for full fidelity — effects, transitions, titles all preserved)
      .fcpxmld — Final Cut Pro XML package (loads `Info.fcpxml` for native import)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path:      Path to the file to import. Extension determines format.
        otio_json: Alternatively, pass raw OTIO JSON string directly (uses .otio adapter).
                   If both path and otio_json are provided, path takes priority.
        rate:      Frame rate for EDL import (e.g. 23.98, 24, 29.97, 30).
                   Required for .edl files with drop-frame timecodes. If 0, defaults to 24.
        event:     Event to import into, by name. Empty uses the library's first event,
                   which is where import_media puts things too.

    Where it lands:
        A NEW project, in an existing event. The project you have open is not touched.
        Verified on FCP 12.3 against a four-clip timeline with a connected clip: offsets,
        durations, source in-points and the connected clip's lane all came back matching.

    What OTIO cannot carry:
        A compound clip. export_otio flattens one into the clips it contains and says so
        in `not_carried_across`; what comes back is those clips, not a compound clip.

    Returns:
        JSON with import status, timeline name, track/clip counts.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"

    # For .fcpxml/.fcpxmld input, send directly to FCP's native importer for full fidelity.
    if path and path.lower().endswith((".fcpxml", ".fcpxmld")):
        try:
            fcpxml_str = _otio_read_fcpx_document(path)
        except Exception as e:
            return f"Error reading file: {e}"

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)

        # Also parse through OTIO for summary info
        summary = {"format": path.rsplit(".", 1)[-1].lower()}
        try:
            result = _otio_read_fcpx_string(fcpxml_str)
            timelines = _otio_all_timelines(result)
            summary["timelines_total"] = len(timelines)
            summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
        except Exception:
            pass

        if _err(r):
            summary["status"] = "error"
            summary["error"] = r.get("error", str(r))
        else:
            summary["status"] = "ok"
        return _fmt(summary)

    # For .otio files: prefer the native ObjC converter (correct transitions,
    # titles, connected clips, exact frame-rate math) over the Python adapter.
    ext = path.rsplit(".", 1)[-1].lower() if path else ""
    if ext == "otio" or (not path and otio_json):
        native_ok = False
        try:
            if path and ext == "otio":
                r = bridge.call("otio.toFCPXML", path=path, event=event)
            elif otio_json:
                r = bridge.call("otio.toFCPXML", path="/dev/null", otio_json=otio_json,
                                event=event)
            else:
                r = {"error": "no input"}

            if not _err(r) and r.get("fcpxml"):
                fcpxml_str = r["fcpxml"]
                fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
                ir = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
                # Parse through OTIO for summary
                summary = {"format": ext or "otio_json", "converter": "native"}
                try:
                    parsed = _otio_read_fcpx_string(fcpxml_str)
                    timelines = _otio_all_timelines(parsed)
                    summary["timelines_total"] = len(timelines)
                    summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
                except Exception:
                    pass
                if _err(ir):
                    summary["status"] = "error"
                    summary["error"] = ir.get("error", str(ir))
                else:
                    summary["status"] = "ok"
                return _fmt(summary)
        except Exception:
            pass  # Fall through to Python adapter path

    # Fallback: read via Python OTIO adapter, convert to FCPXML, import into FCP
    try:
        if path:
            if ext == "edl":
                edl_rate = _otio_normalize_rate(rate) if rate > 0 else 24
                result = otio.adapters.read_from_file(path, rate=edl_rate)
            else:
                result = otio.adapters.read_from_file(path)
        elif otio_json:
            result = otio.adapters.read_from_string(otio_json, "otio_json")
        else:
            return "Error: provide either 'path' (file path) or 'otio_json' (raw OTIO JSON string)"
    except Exception as e:
        hint = ""
        if path and path.lower().endswith(".edl") and "drop frame" in str(e).lower():
            hint = " (try setting rate=29.97 for drop-frame EDLs)"
        return f"Error reading file: {e}{hint}"

    timelines = _otio_all_timelines(result)
    if not timelines:
        return "Error: no timelines found in OTIO file"

    imported = []
    for tl in timelines:
        _otio_prepare_for_fcp(tl)
        try:
            fcpxml_str = _otio_write_fcpx_string(tl)
            fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
        except Exception as e:
            err_msg = f"FCPXML conversion failed: {e}"
            if "kind" in str(e):
                err_msg += " (nested compound clips may not convert — try flattening first)"
            elif "start_time" in str(e) or "NoneType" in str(e):
                err_msg += " (clip has missing source range — may need media references)"
            imported.append({"name": getattr(tl, "name", "unknown"), "error": err_msg})
            continue

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
        entry = _otio_timeline_summary(tl)
        entry["converter"] = "python_adapter"
        if _err(r):
            entry["error"] = r.get("error", str(r))
        else:
            entry["status"] = "ok"
        imported.append(entry)

    summary = {
        "status": "ok" if any(i.get("status") == "ok" for i in imported) else "error",
        "format": path.rsplit(".", 1)[-1] if path else "otio_json",
        "timelines_imported": len([i for i in imported if i.get("status") == "ok"]),
        "timelines_total": len(imported),
        "details": imported,
    }
    return _fmt(summary)


# ============================================================
# Deploy & Restart FCP
# ============================================================
# One-shot command to resolve modded app, quit FCP, build/deploy, relaunch,
# and wait for the bridge to come back online.

@splicekit_tool("deploy_and_restart")
def deploy_and_restart(skip_build: bool = False) -> str:
    """Build SpliceKit, deploy to the modded FCP app, and restart FCP.

    This automates the entire deploy cycle:
    1. Resolve the modded FCP app path (same precedence as the Makefile)
    2. Quit Final Cut Pro and wait for the process to exit
    3. Run `make deploy` (builds dylib + copies to framework path + re-signs)
    4. Relaunch the modded FCP
    5. Wait for the SpliceKit bridge to come online (up to 30 seconds)

    Args:
        skip_build: If True, skip `make deploy` and just restart FCP.
                    Useful when you've already built and just need to relaunch.

    Returns success/failure status and bridge connection state.
    """
    import subprocess, os, time as _time

    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    results = []

    modded_modified = "/Applications/Final Cut Pro Modified.app"
    modded_standard = os.path.expanduser("~/Applications/SpliceKit/Final Cut Pro.app")
    modded_creator = os.path.expanduser(
        "~/Applications/SpliceKit/Final Cut Pro Creator Studio.app"
    )
    modded_app = None
    for candidate in (modded_modified, modded_standard, modded_creator):
        if os.path.isdir(candidate):
            modded_app = candidate
            break
    if modded_app is None:
        return (
            "Error: modded FCP not found at "
            f"{modded_modified}, {modded_standard}, or {modded_creator}"
        )

    def _fcp_is_running() -> bool:
        try:
            proc = subprocess.run(
                ["pgrep", "-x", "Final Cut Pro"],
                capture_output=True,
                timeout=5,
            )
            return proc.returncode == 0
        except Exception:
            return False

    def _quit_through_bridge() -> bool:
        """Ask Final Cut Pro to quit itself, the way the Quit menu item does.

        SIGTERM is not good enough here. Final Cut Pro flushes its library metadata on a
        real -[NSApplication terminate:], not on a signal: killed with pkill it comes back
        with library changes from the session undone, which is how three scratch projects
        that had just been removed reappeared after a restart. This tool runs against the
        user's real libraries, so it asks the app to quit and only falls back to a signal
        when the bridge cannot be reached at all.

        This is the app's own AppKit method called in-process over the bridge. It is not
        AppleScript, not a synthetic key event and not the accessibility API.
        """
        try:
            app = bridge.call(
                "system.callMethodWithArgs",
                target="NSApplication", selector="sharedApplication",
                args=[], classMethod=True, returnHandle=True,
            )
            handle = (app or {}).get("handle")
            if not handle:
                return False
            bridge.call(
                "system.callMethodWithArgs",
                target=handle, selector="terminate:",
                args=[{"type": "nil"}], classMethod=False,
            )
            return True
        except Exception:
            return False

    # Step 2: Quit FCP before deploy (make deploy removes the in-app framework)
    if _fcp_is_running():
        if not _quit_through_bridge():
            results.append("Bridge unreachable; fell back to SIGTERM")
            try:
                subprocess.run(
                    ["pkill", "-x", "Final Cut Pro"], capture_output=True, timeout=5
                )
            except Exception as e:
                return f"Error sending quit to Final Cut Pro: {e}"

        quit_deadline = _time.time() + 30
        while _time.time() < quit_deadline:
            if not _fcp_is_running():
                results.append("Quit FCP: OK")
                break
            _time.sleep(0.5)
        else:
            return (
                "Error: Final Cut Pro did not exit within 30s after SIGTERM. "
                "Not running make deploy — quit FCP manually (Cmd+Q) and retry."
            )
    else:
        results.append("FCP was not running")

    # Step 3: Build and deploy (only after FCP has exited)
    if not skip_build:
        try:
            proc = subprocess.run(
                ["make", "deploy"],
                cwd=project_dir,
                capture_output=True,
                text=True,
                timeout=900,
            )
            if proc.returncode != 0:
                return f"Build failed (exit {proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
            results.append("Build + deploy: OK")
        except subprocess.TimeoutExpired:
            return (
                "Error: make deploy timed out after 900s. "
                "The app's SpliceKit.framework may already have been replaced; "
                "check the modded app and relaunch manually if needed."
            )
        except Exception as e:
            return f"Error running make deploy: {e}"

    # Step 4: Relaunch
    try:
        subprocess.Popen(["open", modded_app])
        results.append(f"Launched: {os.path.basename(modded_app)}")
    except Exception as e:
        return f"Error launching FCP: {e}"

    # Step 5: Wait for bridge
    # Drop the existing connection so we don't use a stale socket
    bridge.reset()

    max_wait = 30
    start = _time.time()
    connected = False
    while _time.time() - start < max_wait:
        _time.sleep(2)
        try:
            r = bridge.call("system.version")
            if not _err(r):
                connected = True
                break
        except Exception:
            pass
        bridge.reset()  # reset on failure

    if connected:
        results.append(f"Bridge connected ({_time.time() - start:.1f}s)")
        return "\n".join(results)
    else:
        results.append(f"Bridge NOT connected after {max_wait}s — FCP may still be loading")
        return "\n".join(results)


# ============================================================
# Playhead Position & Monitoring
# ============================================================
# Query current playhead position, frame rate, and play state.

@splicekit_tool("get_playhead_position")
def get_playhead_position() -> str:
    """Get the current playhead position, timeline duration, frame rate, and playing state.

    Returns:
        seconds: Current playhead position in seconds
        duration: Total timeline duration
        frameRate: Timeline frame rate (e.g. 23.976, 29.97, 59.94)
        isPlaying: Whether playback is currently active

    Use this to monitor playhead position during playback or to know
    exact position before performing edits.
    """
    r = bridge.call("playback.getPosition")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Dialog Detection & Interaction
# ============================================================
# FCP pops up modal dialogs for various operations (project settings,
# export, missing media, etc). These tools detect and interact with
# them so the AI can handle dialogs without human intervention.

@splicekit_tool("detect_dialog")
def detect_dialog(view_tree: bool = False) -> str:
    """Detect if any dialog, sheet, alert, or popup is currently showing in FCP.

    Returns details about all visible dialogs including:
    - Dialog type (modal, sheet, alert, panel, progress, share)
    - Title and all text labels
    - Available buttons with enabled/disabled status
    - Text fields (editable) with current values
    - Checkboxes and radio buttons, each with an index, title and on/off/mixed state
    - Popup menus with available options and current selection

    Call this before/after any action that might trigger a dialog,
    or to check if a dialog needs to be handled before proceeding.

    Args:
        view_tree: Also dump each dialog's raw view hierarchy (class, title, frame,
                   depth, and for buttons the cell shape). Use this when a sheet
                   reports no controls of the kind you expected — it shows what FCP
                   actually built the sheet from. Capped at 2048 nodes per dialog.
    """
    params = {"viewTree": True} if view_tree else {}
    r = bridge.call("dialog.detect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("click_dialog_button")
def click_dialog_button(button: str = "", index: int = -1) -> str:
    """Click a button in the currently showing dialog/sheet/alert.

    Args:
        button: Button title to click (case-insensitive, partial match).
                e.g. "OK", "Cancel", "Share", "Don't Save", "Use Freeze Frames"
        index: Button index (0-based) if title is ambiguous. Use -1 to use title.

    Finds the active dialog (modal window, sheet, or alert panel) and clicks
    the specified button. Use detect_dialog() first to see available buttons.

    Save/open file panels cannot be confirmed (Save/OK/Open) from the bridge;
    only Cancel is supported via click_dialog_button or dismiss_dialog(action=\"cancel\").

    This confirms whatever the dialog is asking. Some of those choices cannot be taken
    back: "Don't Save" discards unsaved changes, "Replace" overwrites a file, and the
    render-file and generated-file dialogs delete what they name. Call detect_dialog()
    and read the buttons before choosing one. There is no undo for a dialog.
    """
    params = {}
    if button:
        params["button"] = button
    if index >= 0:
        params["index"] = index
    r = bridge.call("dialog.click", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("fill_dialog_field")
def fill_dialog_field(value: str, index: int = 0) -> str:
    """Fill a text field in the currently showing dialog.

    Args:
        value: Text to enter in the field
        index: Field index (0-based) if there are multiple fields

    Use detect_dialog() first to see available text fields and their indices.

    Filling a field does not commit anything on its own, but it decides what the button
    you click next will act on — a name typed here is the name a Save panel will use.
    """
    r = bridge.call("dialog.fill", value=value, index=index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("toggle_dialog_checkbox")
def toggle_dialog_checkbox(checkbox: str = "", index: int = -1, checked: bool = None) -> str:
    """Toggle or set a checkbox in the currently showing dialog.

    Args:
        checkbox: Checkbox title (partial match, case-insensitive)
        index: Checkbox index instead of a title, numbered as detect_dialog lists
               them. Use this for a checkbox whose title is empty. -1 means unused.
        checked: True to check, False to uncheck, None to toggle

    Use detect_dialog() first to see available checkboxes. On a miss the error
    lists every checkbox the dialog actually has.

    A checkbox can change what the dialog's confirm button will do — "Delete render
    files" and "Include used clips only" among them — so read the dialog before setting
    one, and there is no undo once the dialog is confirmed.
    """
    if not checkbox and index < 0:
        return "Error: pass checkbox (a title) or index"
    params = {}
    if checkbox:
        params["checkbox"] = checkbox
    if index >= 0:
        params["index"] = index
    if checked is not None:
        params["checked"] = checked
    r = bridge.call("dialog.checkbox", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("select_dialog_popup")
def select_dialog_popup(select: str, popup_index: int = 0) -> str:
    """Select an item from a popup menu in the currently showing dialog.

    Args:
        select: Item title to select
        popup_index: Which popup menu (0-based) if there are multiple

    Use detect_dialog() first to see available popup menus and their options.

    A popup can change what the dialog's confirm button will do — an export preset, a
    destination, a codec — so read the dialog before setting one, and there is no undo
    once the dialog is confirmed.
    """
    r = bridge.call("dialog.popup", select=select, popupIndex=popup_index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("dismiss_dialog")
def dismiss_dialog(action: str = "cancel") -> str:
    """Dismiss the currently showing dialog without committing (by default).

    With no arguments, clicks Cancel (or equivalent) and does not confirm the
    sheet. Pass action="default" or action="ok" to confirm normal sheets
    (OK, Share, Done, etc.) — not save/open file panels; those cannot be
    confirmed from the bridge on current FCP builds.

    Args:
        action: How to dismiss (default "cancel"):
                "cancel" - click Cancel / Don't Save; for save/open panels uses
                panel cancel: only
                "default" - click the default button (usually OK/Share/Done)
                "ok" - explicitly look for OK/Done/Share button

    Automatically finds and clicks the appropriate button to dismiss
    the dialog, sheet, or alert.
    """
    r = bridge.call("dialog.dismiss", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Viewer Zoom
# ============================================================
# Get/set the canvas zoom level. 0.0 = fit-to-window.

@splicekit_tool("get_viewer_zoom")
def get_viewer_zoom() -> str:
    """Get the current viewer zoom level.

    Returns the zoom factor (0.0 = Fit, 1.0 = 100%, 2.0 = 200%, etc.),
    the reported zoom percentage, and whether the viewer is in Fit mode.
    """
    r = bridge.call("viewer.getZoom")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_viewer_zoom")
def set_viewer_zoom(zoom: float) -> str:
    """Set the viewer zoom level to any value.

    Args:
        zoom: Zoom factor. 0.0 = Fit to window, 0.5 = 50%, 1.0 = 100%,
              1.5 = 150%, 2.0 = 200%, etc. Any float value is accepted
              (not limited to FCP's preset percentages).
    """
    r = bridge.call("viewer.setZoom", zoom=zoom)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# SpliceKit Options
# ============================================================
# Runtime configuration for SpliceKit's own behavioral tweaks.

@splicekit_tool("get_bridge_options")
def get_bridge_options() -> str:
    """Get the current SpliceKit option settings.

    Returns the state of all configurable options
    (e.g. effectDragAsAdjustmentClip, viewerPinchZoom, videoOnlyKeepsAudioDisabled,
    suppressAutoImport, defaultSpatialConformType).
    """
    r = bridge.call("options.get")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_bridge_option")
def set_bridge_option(option: str, enabled: bool) -> str:
    """Toggle a boolean SpliceKit option.

    Args:
        option: Option name. Currently supported:
                "effectDragAsAdjustmentClip" - enable/disable dragging effects to empty timeline space to create adjustment clips
                "viewerPinchZoom" - enable/disable trackpad pinch-to-zoom on the viewer
                "videoOnlyKeepsAudioDisabled" - when Video-Only AV edit mode adds clips, keep audio+video but with audio disabled in inspector
                "suppressAutoImport" - stop FCP from auto-opening the Import Media window when a card, camera, or iOS device mounts
                "timelineOverviewBar" - show an inline miniature-timeline strip below the ruler that you can click/drag to jump
                "timelinePerformanceMode" - master toggle for all three timeline perf features below (atomic A/B switch)
                "timelineInteractionSuspend" - freeze filmstrip + anchored-clip updates during pinch/marquee/scrollbar drag
                "timelinePlayheadOverlay" - 120Hz cosmetic playhead overlay for smooth playback on ProMotion displays
                "tlkOptimizedReload" - enable Apple's hidden TLKOptimizedReload fast-path (A/B experiment)
                For "defaultSpatialConformType", use set_bridge_option_value() instead.
        enabled: True to enable, False to disable
    """
    r = bridge.call("options.set", option=option, enabled=enabled)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_bridge_option_value")
def set_bridge_option_value(option: str, value: str) -> str:
    """Set a string-valued SpliceKit option.

    Args:
        option: Option name. Currently supported:
                "defaultSpatialConformType" - override the default spatial conform type for newly added clips
        value: The value to set. For "defaultSpatialConformType":
               "fit"  - Fit (letterbox/pillarbox, FCP default)
               "fill" - Fill (scale to fill frame, crops edges)
               "none" - None (native resolution, no scaling)
    """
    r = bridge.call("options.set", option=option, value=value)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


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
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "beat-detector"),
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
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "structure-analyzer"),
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


# ============================================================
# Montage Maker (Auto-Edit to Beat)
# ============================================================
# End-to-end pipeline: analyze clips -> plan cuts to music beats
# -> assemble a montage timeline. Can run as individual steps
# or as a single montage_auto() call.

@splicekit_tool("montage_analyze_clips")
def montage_analyze_clips(event_name: str = "") -> str:
    """Analyze clips in the browser for montage creation.

    Scans clips in the specified event (or all events), scores them
    based on duration, type (video/photo), and available metadata.
    Returns a ranked list of clips suitable for montage assembly.

    Args:
        event_name: Event name to scan (empty = all events).
    """
    r = bridge.call("montage.analyzeClips", eventName=event_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_plan_edit")
def montage_plan_edit(beats: str, clips: str, style: str = "beat",
                      bars: str = "", sections: str = "",
                      total_duration: float = 0) -> str:
    """Create an edit decision list (EDL) that maps clips to musical beats.

    Takes beat/bar timing data and scored clips, then creates a plan
    that assigns the best clips to each musical segment.

    Each style cuts on a different list, and the list it needs must be supplied:
    "beat" uses `beats`, "bar" uses `bars`, "section" uses `sections` (falling back
    to `bars`). flexmusic_get_timing returns all three for a song.

    Args:
        beats: JSON array of beat timestamps in seconds (from flexmusic_get_timing).
        clips: JSON array of clip objects with handle, duration, score (from montage_analyze_clips).
        style: Cut rhythm - "beat" (every beat), "bar" (every bar/measure), "section" (at sections).
        bars: JSON array of bar timestamps in seconds. Required when style="bar".
        sections: JSON array of section-boundary timestamps in seconds. Used when
                  style="section"; falls back to `bars` when empty.
        total_duration: Total montage duration in seconds (0 = the last cut point).

    Returns an edit decision list with clip assignments, in/out points, and timeline positions.
    """
    import json as _json

    def _arr(value):
        if not value:
            return []
        return _json.loads(value) if isinstance(value, str) else value

    beats_arr, bars_arr, sections_arr = _arr(beats), _arr(bars), _arr(sections)
    clips_arr = _arr(clips)

    # The default used to be "bar" while this tool sent no bars at all, so every call
    # that did not override style failed with "Not enough timing data" no matter what
    # was passed. Say which list is missing instead of making the caller guess.
    needed = {"beat": ("beats", beats_arr), "bar": ("bars", bars_arr),
              "section": ("sections", sections_arr or bars_arr)}.get(style)
    if needed is None:
        return f"Error: style must be one of beat, bar, section (got {style!r})"
    name, values = needed
    if len(values) < 2:
        return (f"Error: style={style!r} cuts on {name}, and {name} has "
                f"{len(values)} entries; at least 2 are needed. "
                "flexmusic_get_timing returns beats, bars and sections for a song.")

    r = bridge.call("montage.planEdit", beats=beats_arr, bars=bars_arr,
                    sections=sections_arr, clips=clips_arr,
                    style=style, totalDuration=total_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_assemble")
def montage_assemble(edit_plan: str, project_name: str = "Montage", song_file: str = "") -> str:
    """Assemble a montage on the timeline from an edit plan.

    Takes the edit decision list and creates the actual timeline:
    places clips at their assigned positions, adds transitions,
    and includes the background music track.

    Uses FCPXML import for reliable, atomic timeline construction.

    Args:
        edit_plan: JSON string of the edit decision list (from montage_plan_edit).
        project_name: Name for the new project.
        song_file: Path to rendered FlexMusic audio file (from flexmusic_render_to_file).
    """
    import json as _json
    plan = _json.loads(edit_plan) if isinstance(edit_plan, str) else edit_plan
    r = bridge.call("montage.assemble", editPlan=plan, projectName=project_name, songFile=song_file)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("montage_auto")
def montage_auto(song_uid: str = "", event_name: str = "", style: str = "bar", project_name: str = "Montage") -> str:
    """One-shot automatic montage creation.

    Analyzes clips, selects a song, gets beat timing, plans the edit,
    renders the music, and assembles everything into a new timeline.

    This is the high-level convenience function that orchestrates the
    entire montage creation pipeline in a single call.

    Args:
        song_uid: FlexMusic song UID (empty = auto-select based on clip mood).
        event_name: Event to pull clips from (empty = all events).
        style: Cut rhythm - "beat", "bar" (default), or "section".
        project_name: Name for the new project.
    """
    r = bridge.call("montage.auto", songUID=song_uid, eventName=event_name,
                     style=style, projectName=project_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Debug & Diagnostics
# ============================================================
# Exposes FCP's hidden internal debug flags (TLK visual overlays,
# ProAppSupport logging, CFPreferences keys) and SpliceKit's own
# debugging toolkit (breakpoints, tracing, eval, crash handling).

@splicekit_tool("debug_get_config")
def debug_get_config() -> str:
    """Get current state of all FCP internal debug/logging settings.

    Returns the current values of:
    - Timeline debug flags (TLK*): visual overlays, logging, performance monitors
    - CFPreferences debug flags: video decoder log level, frame drop logging, GPU logging
    - ProAppSupport log settings: log level, categories, in-app panel visibility, thread info
    - FCP behavior flags: gap coalescing, snapping, skimming overrides

    Use this to see what debug options are currently active before changing them.
    """
    r = bridge.call("debug.getConfig")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("debug_set_config")
def debug_set_config(key: str, value: str = "true") -> str:
    """Set a single FCP internal debug/logging flag.

    Args:
        key: The debug key to set. Common keys:

            Timeline visual overlays:
              TLKShowItemLaneIndex, TLKShowMisalignedEdges, TLKShowRenderBar,
              TLKShowHiddenGapItems, TLKShowHiddenItemHeaders,
              TLKShowInvalidLayoutRects, TLKShowContainerBounds,
              TLKShowContentLayers, TLKShowRulerBounds, TLKShowUsedRegion,
              TLKShowZeroHeightSpineItems

            Timeline logging:
              TLKLogVisibleLayerChanges, TLKLogParts, TLKLogReloadRequests,
              TLKLogRecyclingLayerChanges, TLKLogVisibleRectChanges,
              TLKLogSegmentationStatistics

            Performance/rendering:
              TLKPerformanceMonitorEnabled, TLKDebugColorChangedObjects,
              TLKDebugLayoutConstraints, TLKDebugErrorsAndWarnings,
              TLKDisableItemContents,
              DebugKeyItemVideoFilmstripsDisabled,
              DebugKeyItemBackgroundDisabled,
              DebugKeyItemAudioWaveformsDisabled

            Video/audio logging (integer values, higher = more verbose):
              VideoDecoderLogLevelInNLE, FrameDropLogLevel

            GPU/effects logging:
              GPU_LOGGING, EnableScheduledReadAudioLogging

            Library debugging:
              EnableLibraryUpdateHistoryValidation

            Transcription:
              FFVAMLSaveTranscription

            ProAppSupport log system:
              LogLevel (trace/debug/info/warning/error/failure),
              LogUI (show/hide the in-app SpliceKit log panel),
              LogThread (include thread info in emitted SpliceKit log lines),
              LogCategory (bitmask)

            FCP behavior overrides:
              FFDontCoalesceGaps, FFDisableSnapping, FFDisableSkimming

        value: Value to set. "true"/"false" for bools, integer string for int keys,
               or level name for LogLevel (trace/debug/info/warning/error/failure).
    """
    # Coerce the string value to the right type -- the bridge expects bool/int/string
    if value.lower() in ("true", "yes", "1"):
        parsed = True
    elif value.lower() in ("false", "no", "0"):
        parsed = False
    else:
        try:
            parsed = int(value)
        except ValueError:
            parsed = value  # pass as string (for LogLevel names like "trace", "debug", etc.)

    r = bridge.call("debug.setConfig", key=key, value=parsed)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("debug_reset_config")
def debug_reset_config(scope: str = "all") -> str:
    """Reset debug/logging settings to defaults.

    Args:
        scope: What to reset:
          "all" - reset everything
          "tlk" - reset timeline debug flags only
          "cfprefs" - reset CFPreferences debug flags only
          "log" - reset ProAppSupport log settings only
    """
    r = bridge.call("debug.resetConfig", scope=scope)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("debug_enable_preset")
def debug_enable_preset(preset: str) -> str:
    """Enable a preset group of debug settings.

    Args:
        preset: One of:
          "timeline_visual" - Show lane indices, misaligned edges, render bar,
                              hidden gaps, invalid layouts, color-highlight changes
          "timeline_logging" - Log layer changes, parts, reload requests,
                               recycling, visible rect changes, segmentation stats
          "performance" - Enable TLK performance monitor, video decoder logging,
                          frame drop logging
          "render_debug" - Disable filmstrips/backgrounds/waveforms rendering,
                           enable GPU logging (isolates render issues)
          "verbose_logging" - Set ProAppSupport log level to trace, enable log UI,
                              thread info, and audio logging
          "all_off" - Disable all debug flags and reset to defaults
    """
    r = bridge.call("debug.enablePreset", preset=preset)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("debug_start_framerate_monitor")
def debug_start_framerate_monitor(interval: float = 2.0) -> str:
    """Start FCP's built-in HMD framerate monitor.

    Logs FPS and frame timing statistics to the system log at regular intervals.
    View output in Console.app or via: log stream --process "Final Cut Pro"

    Reports: overall fps, average getFrame() time, min/max frame times in ms.

    Args:
        interval: Seconds between measurements (default 2.0).
    """
    r = bridge.call("debug.startFramerateMonitor", interval=interval)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("debug_stop_framerate_monitor")
def debug_stop_framerate_monitor() -> str:
    """Stop the HMD framerate monitor."""
    r = bridge.call("debug.stopFramerateMonitor")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# -- Runtime metadata export (for reverse engineering / IDA Pro) --

@splicekit_tool("dump_runtime_metadata")
def dump_runtime_metadata(binary: str = "", classes_only: bool = False) -> str:
    """Bulk-export ObjC runtime metadata from a running FCP process for IDA Pro import.

    Returns loaded images (with ASLR slides and base addresses) and full class metadata
    including instance/class methods with IMP addresses, ivars with offsets, properties,
    protocols, and superchains.

    Args:
        binary: Optional filter — match binary/framework name (e.g. "Flexo", "TLKit")
        classes_only: If true, return just class names per image (fast overview)
    """
    params = {}
    if binary:
        params["binary"] = binary
    if classes_only:
        params["classesOnly"] = True
    r = bridge.call("debug.dumpRuntimeMetadata", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("list_loaded_images")
def list_loaded_images(filter: str = "") -> str:
    """List all Mach-O images loaded in FCP's process with base addresses and ASLR slides.

    Use this to see which frameworks/dylibs are loaded and their address information
    needed for mapping runtime IMP addresses to static IDA addresses.

    Args:
        filter: Optional filter string to match image name/path
    """
    params = {}
    if filter:
        params["filter"] = filter
    r = bridge.call("debug.listLoadedImages", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("get_image_sections")
def get_image_sections(binary: str) -> str:
    """Get ObjC section data for a loaded binary: selector refs, class refs, superclass refs.

    Returns the selectors referenced by this binary (which methods it calls),
    the classes it references, and superclass references. Essential for
    understanding cross-binary dependencies and building call graphs.

    Args:
        binary: Binary/framework name to inspect (e.g. "Flexo", "TLKit")
    """
    r = bridge.call("debug.getImageSections", {"binary": binary})
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("get_image_symbols")
def get_image_symbols(binary: str, filter: str = "", demangle: bool = True) -> str:
    """Get exported symbols from a loaded binary's symbol table.

    Returns all exported defined symbols including C functions, ObjC class symbols,
    global variables, and Swift symbols (with automatic demangling).

    Args:
        binary: Binary/framework name to inspect
        filter: Optional filter to match symbol names
        demangle: Whether to demangle Swift symbols (default True)
    """
    params = {"binary": binary}
    if filter:
        params["filter"] = filter
    if not demangle:
        params["demangle"] = False
    r = bridge.call("debug.getImageSymbols", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("get_notification_names")
def get_notification_names(binary: str = "") -> str:
    """Enumerate NSNotification name constants from exported symbols.

    Finds all exported symbols containing 'Notification' and resolves their
    actual NSString values. These are the notification names used in
    NSNotificationCenter postNotificationName: calls.

    Args:
        binary: Optional filter to a specific binary/framework
    """
    params = {}
    if binary:
        params["binary"] = binary
    r = bridge.call("debug.getNotificationNames", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Breakpoints
# ---------------------------------------------------------------------------
# True breakpoints that freeze FCP mid-execution. The JSON-RPC server
# stays alive on a background thread so you can inspect state while paused.

@splicekit_tool("debug_breakpoint")
def debug_breakpoint(action: str = "list", class_name: str = "", selector: str = "",
                     condition: str = "", hit_count: int = 0, one_shot: bool = False,
                     key_path: str = "", store_result: bool = False,
                     class_method: bool = False) -> str:
    """Set, manage, and interact with in-process breakpoints on FCP methods.

    True breakpoints that pause FCP execution, let you inspect state, then continue.
    FCP's UI freezes while paused (same as Xcode). The JSON-RPC server stays alive
    on a separate thread so you can inspect and continue.

    Args:
        action: One of:
            - "add": Set a breakpoint on className.selector
            - "remove": Remove a breakpoint
            - "removeAll": Remove all breakpoints (auto-resumes if paused)
            - "list": List all breakpoints and paused state
            - "enable": Re-enable a disabled breakpoint
            - "disable": Disable without removing
            - "continue": Resume paused execution
            - "step": Resume but auto-break on next call to same class
            - "inspect": Get current paused state (self, args, call stack)
            - "inspectSelf": Evaluate a keyPath on the paused self object
        class_name: ObjC class name (e.g. "FFAnchoredTimelineModule")
        selector: ObjC selector (e.g. "blade:")
        condition: Optional keyPath on self that must be truthy for bp to fire
        hit_count: Only fire after this many calls (skip earlier ones)
        one_shot: If true, auto-remove after first hit
        key_path: For inspectSelf — the property path to evaluate
        store_result: For inspectSelf — store the result as a handle
        class_method: If true, breakpoint a class method (+) instead of instance (-)

    When a breakpoint fires, a "breakpoint.hit" event is broadcast with:
    - selfClass, self description, selfHandle
    - firstArg (if present), firstArgHandle
    - callStack (up to 20 frames)
    - threadName, isMainThread

    While paused, use debug_eval(), call_method_with_args(), or inspectSelf
    to examine state before continuing.
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if condition:
        params["condition"] = condition
    if hit_count > 0:
        params["hitCount"] = hit_count
    if one_shot:
        params["oneShot"] = True
    if key_path:
        params["keyPath"] = key_path
    if store_result:
        params["storeResult"] = True
    if class_method:
        params["classMethod"] = True
    r = bridge.call("debug.breakpoint", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Method Tracing
# ---------------------------------------------------------------------------
# Non-blocking alternative to breakpoints. Swizzles methods to log calls
# without pausing. Good for understanding call patterns and frequencies.

@splicekit_tool("debug_trace_method")
def debug_trace_method(action: str = "list", class_name: str = "", selector: str = "",
                       log_stack: bool = False, log_args: bool = True,
                       limit: int = 50, class_method: bool = False) -> str:
    """Trace ObjC method calls without pausing execution.

    Swizzles the target method to log every call with timestamp, self, and
    optionally the call stack. Traces are stored in a circular buffer (500 entries)
    and broadcast to MCP clients in real-time.

    Use this when you want to observe call patterns without freezing FCP.
    Use debug_breakpoint() when you need to pause and inspect.

    Args:
        action: One of:
            - "add": Start tracing className.selector
            - "remove": Stop tracing a specific method
            - "removeAll": Stop all traces
            - "list": List active traces
            - "getLog": Read trace log entries
            - "clearLog": Clear the trace log buffer
        class_name: ObjC class name
        selector: ObjC selector
        log_stack: Include call stack in trace entries (slower but more info)
        log_args: Log argument info (default true)
        limit: For getLog — max entries to return
        class_method: Trace a class method (+) instead of instance (-)
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if log_stack:
        params["logStack"] = True
    if not log_args:
        params["logArgs"] = False
    if action == "getLog":
        params["limit"] = limit
    if class_method:
        params["classMethod"] = True
    r = bridge.call("debug.traceMethod", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Property Watching (KVO)
# ---------------------------------------------------------------------------
# Uses ObjC Key-Value Observing to fire events whenever a property changes.
# Replaces hardware watchpoints -- works on any KVO-compliant property.

@splicekit_tool("debug_watch")
def debug_watch(action: str = "list", handle: str = "", class_name: str = "",
                key_path: str = "", watch_key: str = "") -> str:
    """Watch ObjC property changes via KVO (Key-Value Observing).

    When a watched property changes, old/new values are broadcast to MCP clients.

    Args:
        action: One of:
            - "add": Start watching a property
            - "remove": Stop watching (requires watch_key)
            - "removeAll": Stop all watches
            - "list": List active watches
        handle: Object handle (e.g. "obj_1") to watch
        class_name: Class name (resolved to singleton if no handle)
        key_path: The property to watch (e.g. "mainWindow", "sequence.displayName")
        watch_key: For remove — the key returned when the watch was created
    """
    params = {"action": action}
    if handle:
        params["handle"] = handle
    if class_name:
        params["className"] = class_name
    if key_path:
        params["keyPath"] = key_path
    if watch_key:
        params["watchKey"] = watch_key
    r = bridge.call("debug.watch", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Crash Handler
# ---------------------------------------------------------------------------
# Catches NSExceptions and Unix signals before the process dies,
# so you get a stack trace instead of a silent crash.

@splicekit_tool("debug_crash_handler")
def debug_crash_handler(action: str = "install") -> str:
    """Install or query the in-process crash handler.

    Catches uncaught NSExceptions and Unix signals (SIGABRT, SIGSEGV, SIGBUS,
    SIGFPE, SIGILL) inside FCP. Captures full stack traces and broadcasts to
    MCP clients before the process terminates.

    Args:
        action: One of:
            - "install": Install exception + signal handlers (idempotent)
            - "status": Check if installed + crash count
            - "getLog": Read captured crash stack traces
            - "clearLog": Clear the crash log
    """
    r = bridge.call("debug.crashHandler", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Thread Inspection
# ---------------------------------------------------------------------------
# Lists all ~45 threads in FCP's process with CPU usage via Mach APIs.

@splicekit_tool("debug_threads")
def debug_threads(detailed: bool = False) -> str:
    """List all threads in FCP's process with CPU usage and state.

    Uses Mach kernel APIs for accurate thread counts and per-thread metrics.

    Args:
        detailed: If true, include per-thread CPU usage, run state, and
                  call stacks for the current and main threads.

    Returns thread count, operation queue info, and optionally per-thread:
    - cpuUsage (percentage 0-100)
    - userTime / systemTime (seconds)
    - runState (1=running, 2=stopped, 3=waiting)
    - suspended flag
    """
    r = bridge.call("debug.threads", detailed=detailed)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Expression Evaluation
# ---------------------------------------------------------------------------
# Like lldb's `po` command. Walks ObjC property chains at runtime.

@splicekit_tool("debug_eval")
def debug_eval(expression: str = "", chain: str = "", target: str = "",
               store_result: bool = False) -> str:
    """Evaluate ObjC property chains inside FCP's process.

    Two modes:
    1. Dot expression: "NSApp.delegate._targetLibrary.displayName"
    2. Chain array: ["delegate", "_targetLibrary", "displayName"]

    Each step tries respondsToSelector: first, then KVC valueForKey: as fallback.

    Args:
        expression: Dot-separated property chain (e.g. "NSApp.delegate.className")
                   Starting points: "NSApp", "obj_XXX" (handle), or any class name
        chain: Comma-separated chain of property/method names (alternative to expression)
               e.g. "delegate,_targetLibrary,displayName"
        target: Object handle to start the chain from (e.g. "obj_1"). If omitted,
                starts from NSApp for chain mode.
        store_result: Store the final result as a handle for further inspection

    Returns the result value, its class, and optionally a handle.
    """
    params = {}
    if expression:
        params["expression"] = expression
    if chain:
        params["chain"] = [s.strip() for s in chain.split(",")]
    if target:
        params["target"] = target
    if store_result:
        params["storeResult"] = True
    r = bridge.call("debug.eval", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Hot Plugin Loading
# ---------------------------------------------------------------------------
# dlopen/dlclose for live-patching FCP without restarting.

@splicekit_tool("debug_load_plugin")
def debug_load_plugin(action: str = "list", path: str = "") -> str:
    """Load or unload arbitrary native code inside Final Cut Pro's running process.

    This runs whatever is in the file, with Final Cut Pro's own privileges, in Final Cut
    Pro's own address space. The dylib's __attribute__((constructor)) runs the moment it
    loads, before this tool returns. A bad build crashes Final Cut Pro and takes any
    unsaved work with it, and a plugin that corrupts memory can damage the open library.
    There is no sandbox and no undo. Unloading does not reverse anything the constructor
    already did. Only load a file you compiled yourself and know the contents of.

    Load compiled .dylib or .bundle files without restarting FCP.
    Use for hot-patching fixes or adding features at runtime.

    Args:
        action: One of:
            - "load": Load a dylib or bundle into FCP
            - "unload": Unload a previously loaded dylib
            - "list": List currently loaded plugins
        path: File path to the .dylib or .bundle to load/unload

    Workflow:
    1. Write patch code (ObjC with constructor function)
    2. Compile: clang -dynamiclib -framework Foundation -o /tmp/fix.dylib fix.m
    3. Load: debug_load_plugin(action="load", path="/tmp/fix.dylib")
    4. Test the change
    5. Unload: debug_load_plugin(action="unload", path="/tmp/fix.dylib")
    """
    params = {"action": action}
    if path:
        params["path"] = path
    r = bridge.call("debug.loadPlugin", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Notification Observation
# ---------------------------------------------------------------------------
# Subscribe to NSNotificationCenter events. FCP posts 337+ named
# notifications internally -- this lets you see them in real time.

@splicekit_tool("debug_observe_notification")
def debug_observe_notification(action: str = "list", name: str = "",
                               log_object: bool = False) -> str:
    """Subscribe to FCP's internal NSNotification events.

    Events are broadcast to MCP clients in real-time with notification name,
    object class, and userInfo dictionary.

    Args:
        action: One of:
            - "add": Start observing a notification
            - "remove": Stop observing (requires name)
            - "removeAll": Stop all observers
            - "list": List active observers
        name: Notification name (e.g. "FFEffectsChangedNotification").
              Use "*" to observe ALL notifications (high volume — use briefly).
        log_object: Include the notification's object description in events

    Common notifications:
    - FFEffectsChangedNotification: effect stack modified
    - FFEffectStackChangedNotification: effect added/removed
    - FFAssetMediaChangedNotification: media asset changes
    - FFBeatGridSettingsChangedNotification: beat grid toggled
    - FFQTMovieExporterFinishedNotification: export completes
    See fcp_symbols/notifications.txt for all 337 notification names.
    """
    params = {"action": action}
    if name:
        params["name"] = name
    if log_object:
        params["logObject"] = True
    r = bridge.call("debug.observeNotification", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Direct Timeline Actions (parameterized Flexo methods)
# ---------------------------------------------------------------------------
# Unlike timeline_action() which dispatches through the responder chain
# with no arguments, these call Flexo's action* methods directly with
# real parameters (rates, durations, flags, etc). More powerful but
# requires knowing which parameters each action needs.

@splicekit_tool("direct_timeline_action")
def direct_timeline_action(action: str = "", selector: str = "",
                           rate: float = 0, ripple: bool = False,
                           allow_variable_speed: bool = True,
                           to_zero: bool = False, from_zero: bool = False,
                           frames_to_jump: int = 0, speed: float = 0,
                           name: str = "", marker: str = "",
                           type_: str = "", completed: bool = False,
                           amount: float = 0, frames: int = 0,
                           relative: bool = True,
                           fade_in: bool = True, duration: float = 0,
                           enabled: bool = True, effect_id: str = "",
                           keywords: str = "", language: str = "",
                           format_: str = "", multicam: bool = False,
                           as_split: bool = False, is_delta: bool = False,
                           replace_with_gap: bool = False,
                           on_edges: bool = True, on_left: bool = True,
                           add_title: bool = True,
                           interpolation: str = "",
                           time: float = -1,
                           store_result: bool = False) -> str:
    """Call Flexo's parameterized action methods directly on FFAnchoredTimelineModule.

    More powerful than timeline_action() because these accept real parameters
    (rates, durations, flags) instead of just dispatching through the responder chain.

    Many advertised actions call Flexo ``action*`` selectors that are not present on
    Final Cut Pro 12.3 (only 17 ``action*`` methods exist on FFAnchoredTimelineModule
    there). Unsupported ones return a clear error:
    ``<action> is not supported on this Final Cut Pro build``, plus ``missingSelector``
    and ``fcpVersion``. Verified working on FCP 12.3: insertGap, insertPlaceholder,
    insertGapDirect, splitAtTime, nudgeAnchoredItems, nudgeSpineItems, insertFreezeFrame,
    removeEdits, joinThroughEdits.

    Args:
        action: The action name. Available actions:

            Retiming/Speed:
              retimeSetRate (rate, ripple, allow_variable_speed)
              retimeHoldPreset, retimeReverse, retimeBladeSpeedPreset
              retimeSpeedRamp (to_zero, from_zero)
              retimeInstantReplay (rate, allow_variable_speed, add_title)
              retimeJumpCut (frames_to_jump, allow_variable_speed)
              retimeRewind (speed, allow_variable_speed)
              retimeSetInterpolation (interpolation)
              insertFreezeFrame

            Markers:
              changeMarkerType (type_: "chapter"/"todo"/"note")
              changeMarkerName (name, marker handle)
              markMarkerCompleted (completed, marker handle)
              removeMarker (marker handle)

            Audio:
              changeAudioVolume (amount, relative)
              applyAudioFadesDirect (fade_in, duration)
              setAudioPlayEnable (enabled)
              setBackgroundMusic (enabled)
              detachAudioDirect, alignAudioToVideoDirect

            Trim/Edit:
              splitAtTime (time: seconds, or current playhead when omitted)
              trimDuration (is_delta)
              extendOverNextClip, joinThroughEdits (on_edges/on_left kept for
              compatibility but ignored — FCP 12.3 only has parameterless join)
              removeEdits (replace_with_gap), insertGapDirect

            Clips:
              breakApartClipItems, createCompoundClipDirect (multicam)
              liftAnchoredEdits, renameDirect (name)
              deleteItemsInArray, moveClipsToTrash

            Keywords/Roles:
              addKeywords (keywords: comma-separated), removeKeywords

            Effects:
              removeEffectByID (effect_id), invertEffectMasks, toggleEnabled

            Multicam:
              deleteMultiAngle, renameAngle (name), audioSyncMultiAngle

            Variants:
              addVariants, removeVariants, finalizeVariant

            Captions:
              duplicateCaptions (language, format_)

            Music:
              alignToMusicMarkers, alignClipsAtMusicMarkers (as_split)

            Project:
              newProject (name), newEvent (name), validateAndRepair

            Other:
              autoReframeDirect, addTransitionsDirect
              analyzeAndOptimize, resolveLaneConflicts, resolveLaneGaps
              nudgeAnchoredItems, nudgeSpineItems (frames for whole frames, amount for
              seconds; default one project frame when neither is set)

        selector: Raw ObjC selector fallback when action is empty (e.g.
            "actionValidateAndRepair:validateMode:error:"). Passed through to timeline.directAction.

    Shared parameters (only sent when non-default; each action uses a subset):

        Retiming / speed (retimeSetRate, retimeSpeedRamp, retimeInstantReplay, retimeJumpCut,
        retimeRewind, retimeSetInterpolation, insertFreezeFrame, …):
            rate: Playback rate for retimeSetRate / retimeInstantReplay (0 skips sending).
            ripple: When True, ripple the retime to following clips (retimeSetRate).
            allow_variable_speed: When False, disallow variable-speed retime paths (default True).
            to_zero: Speed ramp toward zero (retimeSpeedRamp).
            from_zero: Speed ramp from zero (retimeSpeedRamp).
            frames_to_jump: Frame count for retimeJumpCut (>0 to send).
            speed: Rewind speed for retimeRewind (non-zero to send).
            interpolation: Interpolation mode string for retimeSetInterpolation.
            add_title: For retimeInstantReplay, whether to add a title (default True; False to send).

        Markers (changeMarkerType, changeMarkerName, markMarkerCompleted, removeMarker):
            type_: Marker kind for changeMarkerType: "chapter", "todo", or "note".
            name: New marker name for changeMarkerName / renameDirect / newProject / newEvent.
            marker: Handle of the marker object (from list_markers).
            completed: When True, mark a to-do marker completed (markMarkerCompleted).

        Audio (changeAudioVolume, applyAudioFadesDirect, setAudioPlayEnable, setBackgroundMusic):
            amount: Volume change in dB for changeAudioVolume (non-zero to send).
            relative: When False, set absolute volume instead of relative (default True).
            fade_in: When False, apply fade-out only for applyAudioFadesDirect (default True).
            duration: Fade duration in seconds for applyAudioFadesDirect (non-zero to send).
            enabled: When False, disable audio play or background music (default True).

        Trim / edit (splitAtTime, trimDuration, removeEdits, joinThroughEdits, nudge*, …):
            time: Timeline seconds for splitAtTime (>=0 to send; omit for playhead).
            is_delta: For trimDuration, how `duration` is read. True (the default) treats
                it as a change to add to the clip's current length; False treats it as the
                length to set. Getting this backwards silently trims to the wrong place.
            replace_with_gap: When True, removeEdits leaves a gap instead of ripple.
            on_edges / on_left: Ignored on FCP 12.3 for joinThroughEdits (reported in response).
            frames: Whole frames to nudge (nudgeAnchoredItems, nudgeSpineItems).
            amount: Seconds to nudge when frames is 0; also used by changeAudioVolume.

        Effects / keywords:
            effect_id: Effect identifier for removeEffectByID.
            keywords: Comma-separated keyword strings for addKeywords / removeKeywords.

        Captions / multicam / variants:
            language: Language code for duplicateCaptions.
            format_: Export format for duplicateCaptions (e.g. "SRT").
            multicam: When True, createCompoundClipDirect builds a multicam compound.
            as_split: For alignClipsAtMusicMarkers, when True each clip is cut at the
                marker and both halves are kept, instead of the clip being moved so its
                start lands on the marker.

        Misc:
            store_result: When True, retain a direct-action result object as a handle.

    Nudge amount (nudgeAnchoredItems, nudgeSpineItems): pass frames=N to move N whole
    frames, or amount=S to move S seconds. Omit both for a one-frame nudge.
    """
    # Only include params that were explicitly set -- the bridge uses their
    # presence/absence to determine which ObjC selector variant to call
    params = {}
    if action:
        params["action"] = action
    if selector:
        params["selector"] = selector
    if rate != 0:
        params["rate"] = rate
    if ripple:
        params["ripple"] = True
    if not allow_variable_speed:
        params["allowVariableSpeed"] = False
    if to_zero:
        params["toZero"] = True
    if from_zero:
        params["fromZero"] = True
    if frames_to_jump > 0:
        params["framesToJump"] = frames_to_jump
    if speed != 0:
        params["speed"] = speed
    if name:
        params["name"] = name
    if marker:
        params["marker"] = marker
    if type_:
        params["type"] = type_
    if completed:
        params["completed"] = True
    if amount != 0:
        params["amount"] = amount
    if frames != 0:
        params["frames"] = frames
    if not relative:
        params["relative"] = False
    if not fade_in:
        params["fadeIn"] = False
    if duration != 0:
        params["duration"] = duration
    if not enabled:
        params["enabled"] = False
    if effect_id:
        params["effectID"] = effect_id
    if keywords:
        params["keywords"] = [k.strip() for k in keywords.split(",")]
    if language:
        params["language"] = language
    if format_:
        params["format"] = format_
    if multicam:
        params["multicam"] = True
    if as_split:
        params["asSplit"] = True
    if is_delta:
        params["isDelta"] = True
    if replace_with_gap:
        params["replaceWithGap"] = True
    if time >= 0:
        params["time"] = time
    if not add_title:
        params["addTitle"] = False
    if interpolation:
        params["interpolation"] = interpolation
    ignored_parameters = []
    if action == "joinThroughEdits":
        if not on_edges:
            ignored_parameters.append("on_edges")
        if not on_left:
            ignored_parameters.append("on_left")

    r = bridge.call("timeline.directAction", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if ignored_parameters and isinstance(r, dict):
        r = dict(r)
        r["ignoredParameters"] = ignored_parameters
        r["ignoredParametersNote"] = (
            "FCP 12.3 only exposes the parameterless join-through-edits path "
            "(_joinSelectedThroughEdits); on_edges and on_left are not applied."
        )
    return _fmt(r)


# ---------------------------------------------------------------------------
# Additional tools: browser, pasteboard import, seek, stabilize, titles,
# transcript engine selection
# ---------------------------------------------------------------------------


@splicekit_tool("browser_list_clips")
def browser_list_clips(event: str = "") -> str:
    """List what is in the browser (the active library's events): name, event, duration,
    a handle, and whether each row is a project.

    Use the handle with add_clip_to_timeline() to make an append, insert or connect edit
    from a clip or a range of it.

    Check `isProject` first. A project sits in the browser next to the source clips but it
    is a whole timeline, not footage: add_clip_to_timeline() and browser_append_clip()
    refuse it, and remove_browser_clip() refuses it unless you pass include_projects. Open
    a project with open_project(name) instead. Items already in the library trash are not
    listed at all.

    One caveat: a project with nothing in it cannot be told apart from a clip here and
    reports `isProject: false`. Final Cut Pro answers -isProject NO and -sequenceType
    "clip" for an empty, unopened project, and there is nothing else to go on.

    Args:
        event: Optional event name to filter by (case-insensitive substring match).
    """
    params = {}
    if event:
        params["event"] = event
    r = bridge.call("browser.listClips", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("browser_append_clip")
def browser_append_clip(handle: str = "", index: int = -1, name: str = "") -> str:
    """Append a whole browser clip at the end of the primary storyline (FCP: Append, E).
    Shortcut for add_clip_to_timeline(edit="append"); use that tool for a range of the
    clip, an insert or connect edit, a target time, or a dry run.

    Pass exactly one of handle, index or name. A project is refused: it is a whole
    timeline, not footage. Check `isProject` in browser_list_clips() before choosing.

    Args:
        handle: Object handle of the clip from browser_list_clips() (e.g. "obj_5").
            Unambiguous; preferred.
        index: The clip's `index` as browser_list_clips() reports it. That ordering is
            Final Cut Pro's and can change when the library changes, so read it fresh.
        name: The clip's name. Matched case-insensitively; an exact match wins over a
            longer name that merely contains it. If several clips still match, the first
            found wins, so prefer a handle when names repeat across events.
    """
    params = {}
    if handle:
        params["handle"] = handle
    if index >= 0:
        params["index"] = index
    if name:
        params["name"] = name
    r = bridge.call("browser.appendClip", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


def _s3(value) -> str:
    """Seconds with three decimals for the placement report, or '?' when absent."""
    return f"{value:.3f}s" if isinstance(value, (int, float)) and not isinstance(value, bool) else "?"


def _yes_no(value) -> str:
    return "unknown" if value is None else ("yes" if value else "no")


def _place_where(item: dict) -> str:
    """Where a placed item sits, in FCP's words: the primary storyline, or a lane for a connected clip."""
    if item.get("connected"):
        lane = item.get("lane")
        return f"lane {lane} (connected clip)" if lane is not None else "connected clip"
    return "primary storyline"


def _render_place_clip(r: dict) -> str:
    """Human-readable report for browser.placeClip: what was asked, what landed, and
    whether the two agree (the bridge re-reads the timeline and compares within two
    frames, at least 50 ms)."""
    edit = r.get("edit", "?")
    key = {"append": "E", "insert": "W", "connect": "Q"}.get(edit, "")
    label = f"{edit} edit" + (f" (the effect of {key})" if key else "") + (" backtimed (Shift-Q)" if r.get("backtimed") else "")
    clip = r.get("sourceClip") or {}
    src = r.get("source") or {}
    tgt = r.get("target") or {}
    dry = r.get("status") == "dry_run" or r.get("dryRun") is True
    lines = []
    if dry:
        lines.append(f"Dry run (nothing changed): {label}")
    else:
        lines.append(f"{label[:1].upper()}{label[1:]}: " + ("verified" if r.get("verified") else "done, NOT verified"))
    if src.get("wholeClip"):
        span = "whole clip"
    else:
        span = f"{_s3(src.get('startSeconds'))} to {_s3(src.get('endSeconds'))} from the clip's first frame"
        if src.get("snappedToClipFrames"):
            span += " (snapped to the clip's frames)"
    lines.append(f"Source: {clip.get('name') or '?'} ({clip.get('handle') or '?'}): {span}, "
                 f"{_s3(src.get('durationSeconds'))} of {_s3(clip.get('durationSeconds'))}")
    if edit == "append":
        target = "end of the primary storyline"
        if tgt.get("storylineEndBeforeSeconds") is not None:
            target += f" (was at {_s3(tgt.get('storylineEndBeforeSeconds'))})"
        if dry:
            target += "; the playhead will be moved there"
    elif tgt.get("requestedSeconds") is not None:
        verb = "will move to" if dry else "moved to"
        target = f"playhead {verb} {_s3(tgt.get('requestedSeconds'))} ({'now' if dry else 'was'} {_s3(tgt.get('playheadBeforeSeconds'))})"
    else:
        target = f"playhead at {_s3(tgt.get('editSeconds', tgt.get('playheadBeforeSeconds')))}"
    if not dry and tgt.get("playheadAfterSeconds") is not None:
        target += f"; playhead now {_s3(tgt.get('playheadAfterSeconds'))}"
    lines.append(f"Target: {target}")
    if not dry:
        placed = r.get("placed") or []
        if not placed:
            lines.append("Placed: no new clip found on the timeline afterwards")
        for item in placed:
            lines.append(f"Placed: {item.get('name') or '?'} ({item.get('handle') or '?'}) {_place_where(item)}, "
                         f"{_s3(item.get('startSeconds'))} to {_s3(item.get('endSeconds'))} ({_s3(item.get('durationSeconds'))})")
        also = r.get("alsoNew") or []
        if also:
            shown = ", ".join(f"{i.get('name') or i.get('class') or '?'} ({i.get('handle') or '?'}) {_place_where(i)} "
                              f"{_s3(i.get('startSeconds'))} to {_s3(i.get('endSeconds'))}" for i in also[:5])
            more = f", and {len(also) - 5} more" if len(also) > 5 else ""
            lines.append(f"Also new on the timeline (not the source clip): {len(also)}: {shown}{more}")
        lines.append(f"Range honored: {_yes_no(r.get('rangeHonored'))}; position as requested: {_yes_no(r.get('positionVerified'))} "
                     "(within two frames, at least 50 ms)")
        if r.get("note"):
            lines.append(f"Note: {r['note']}")
        lines.append('Undo: history_action("undo")')
    return "\n".join(lines)


@splicekit_tool("add_clip_to_timeline")
@bridge_tool
def add_clip_to_timeline(handle: str = "", name: str = "", index: int = -1,
                         edit: str = "append",
                         start_seconds: float | None = None, end_seconds: float | None = None,
                         at_seconds: float | None = None, backtimed: bool = False,
                         dry_run: bool = False) -> str:
    """Put a browser clip, or a range of it, on the timeline. SpliceKit writes the range to
    Final Cut Pro's pasteboard and uses FCP's Edit > Paste (insert) or Edit > Paste as
    Connected Clip (connect) at the playhead; append moves the playhead to the end of the
    primary storyline and pastes there. For insert and connect this is FCP's three-point
    edit: source start + end, with the playhead as the timeline point.

      edit="insert"   the effect of Insert (W): into the primary storyline at the playhead;
                      later clips move right
      edit="connect"  the effect of Connect to Primary Storyline (Q): a connected clip at the
                      playhead. FCP picks the lane (its Connect puts video above and audio-only
                      clips below the primary storyline); the answer reports where it landed
      edit="append"   the effect of Append to Storyline (E): at the end of the primary storyline
                      regardless of the playhead. SpliceKit moves the playhead there first and
                      leaves it there
      No overwrite: FCP has no paste that overwrites. FCP's own E / W / Q / D on whatever the
      browser currently has selected are timeline_edit_action("appendEdit" | "insertEdit" |
      "connectToPrimaryStoryline") and timeline_destructive_action("overwriteEdit").

    Source: prefer the handle from browser_list_clips(); name is the first case-insensitive
    substring match; index is that listing's index. start_seconds / end_seconds are the
    equivalent of a browser range selection (Set Range Start I / Set Range End O), in seconds
    from the clip's first frame. Either alone works (start only = to the end, end only = from
    the first frame); neither = the whole clip. The range is snapped to the clip's own frames
    when FCP exposes its frame duration.
    Target: at_seconds moves the playhead there first. backtimed=True (connect only, the
    effect of Connect to Primary Storyline - Backtimed, Shift-Q) puts the END of the range at
    the playhead. If the pointer is skimming over the timeline FCP may edit at the skimmer
    instead; the answer says so.

    The answer re-reads the timeline and reports the placed clip as get_timeline_clips() would
    (handle, primary storyline or lane, timeline range), whether its duration matches the range
    and its position the target (both within two frames, at least 50 ms), and anything else the
    edit created (the far half of a split clip, a gap FCP added). The pasteboard is replaced:
    whatever was copied before is gone. The edit is a single paste, so history_action("undo")
    removes it in one step (Edit > Undo shows FCP's paste name). dry_run=True resolves the
    clip, range and target and changes nothing.
    """
    edit = (edit or "append").lower()
    if edit not in ("append", "insert", "connect", "overwrite"):
        return "Error: edit must be append, insert or connect"
    if edit == "overwrite":
        return ("Error: no overwrite here: FCP has no paste that overwrites. FCP's own Overwrite (D) of the "
                "browser's current selection is timeline_destructive_action(\"overwriteEdit\"); otherwise use "
                "insert or connect")
    if not handle and not name and index < 0:
        return "Error: give the source clip as handle (from browser_list_clips), name, or index"
    if start_seconds is not None and end_seconds is not None and end_seconds <= start_seconds:
        return f"Error: end_seconds ({end_seconds}) must be after start_seconds ({start_seconds})"
    if at_seconds is not None and edit == "append":
        return "Error: an append edit always adds at the end of the primary storyline; use insert or connect with at_seconds"
    if backtimed and edit != "connect":
        return "Error: backtimed is only available for connect edits (Connect to Primary Storyline - Backtimed, Shift-Q)"
    params = {"edit": edit}
    if handle:
        params["handle"] = handle
    if name:
        params["name"] = name
    if index >= 0:
        params["index"] = index
    if start_seconds is not None:
        params["inSeconds"] = float(start_seconds)
    if end_seconds is not None:
        params["outSeconds"] = float(end_seconds)
    if at_seconds is not None:
        params["atSeconds"] = float(at_seconds)
    if backtimed:
        params["backtimed"] = True
    if dry_run:
        params["dryRun"] = True
    r = _call("browser.placeClip", **params)
    return _render_place_clip(r)


@splicekit_tool("import_media")
def import_media(paths: list[str] | None = None,
                 path: str = "",
                 event: str = "",
                 library: str = "",
                 manage_file_type: int = 0) -> str:
    """Import local media files into an event's browser — the same landing
    place dragging a file into FCP puts it.

    Wraps -[FFMediaEventProject newClipFromURL:manageFileType:] + addOwnedClipsObject:
    which is FCP's native drop-import path. Works with any file type FCP can
    read (QuickTime, MP4, MXF, etc.).

    Args:
        paths: List of absolute paths to import
        path: Single absolute path (alternative to paths)
        event: Substring match for event name (case-insensitive). Empty = first event.
        library: Substring match for library display name. Empty = any library.
        manage_file_type: 0 = leave in place (default), 1 = copy into managed media.

    Returns imported clip handles plus any skipped paths with reasons.
    """
    all_paths: list[str] = []
    if paths:
        all_paths.extend(p for p in paths if p)
    if path:
        all_paths.append(path)
    if not all_paths:
        return "Error: provide `paths` (list) or `path` (single)"
    params: dict = {"paths": all_paths, "manageFileType": manage_file_type}
    if event:
        params["event"] = event
    if library:
        params["library"] = library
    r = bridge.call("media.importFile", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("remove_browser_clip")
def remove_browser_clip(handle: str = "", name: str = "", event: str = "",
                        library: str = "", include_projects: bool = False,
                        dry_run: bool = False) -> str:
    """Take a source clip back out of an event's browser — the counterpart to import_media.

    Removes the clip from the event the way Final Cut Pro's own delete does
    (-removeOwnedClipsObject:, the exact inverse of the add import_media makes).
    The media file on disk is left alone.

    Refuses a project unless include_projects is set: removing a project removes a whole
    timeline. cleanup_temp_projects removes SpliceKit's own scratch projects without it.

    A name is not unique. If `name` matches more than one item — the same clip name in two
    events, or in two open libraries — nothing is removed and the error lists every match
    with its event, so you can narrow it with `event=` or pass the handle instead. A handle
    is unambiguous by definition and never triggers this.

    Returns `removed` (each with name, event and whether it was a clip or a project) and
    `failed` (anything that matched but Final Cut Pro refused to remove, with the reason).
    A partial result still reports both lists rather than reading as a total failure.

    Args:
        handle: A handle from browser_list_clips() or import_media(). Unambiguous; preferred.
        name: The clip's name exactly as the browser shows it, when no handle is given.
            Matched in full, case-sensitively, not as a substring.
        event: Substring match for the event name (case-insensitive), to narrow the search.
        library: Substring match for the library display name.
        include_projects: Allow removing a project (a whole timeline), not just a source clip.
        dry_run: Report what would be removed and change nothing. Default False.
    """
    params: dict = {}
    if handle:
        params["handle"] = handle
    if name:
        params["name"] = name
    if event:
        params["event"] = event
    if library:
        params["library"] = library
    if include_projects:
        params["includeProjects"] = True
    if dry_run:
        params["dryRun"] = True
    if not handle and not name:
        return ("Error: provide `handle` (from browser_list_clips or import_media) or "
                "`name` (the clip's name exactly as the browser shows it)")
    r = bridge.call("media.removeClip", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("paste_fcpxml")
def paste_fcpxml(xml: str = "") -> str:
    """Import FCPXML content via the pasteboard (no file I/O, no dialogs).

    Puts FCPXML data on the system pasteboard and triggers FCP's internal
    paste-from-XML handler. Faster and cleaner than file-based import.

    Args:
        xml: FCPXML content string
    """
    params = {}
    if xml:
        params["xml"] = xml
    r = bridge.call("fcpxml.pasteImport", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("stabilize_subject")
def stabilize_subject() -> str:
    """Stabilize the selected clip around a tracked subject.

    Uses the Vision framework to detect and track a subject at the current
    playhead position, then applies inverse position keyframes so the subject
    stays fixed on screen while the background moves.

    Requirements: a clip must be selected and the playhead should be on a frame
    where the subject is clearly visible.
    """
    r = bridge.call("stabilize.subject")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("insert_title")
def insert_title(name: str = "", effect_id: str = "") -> str:
    """Insert a title or generator into the timeline.

    Resolves by display name or effect ID. If name is provided, searches
    all available title effects for a case-insensitive match.

    Args:
        name: Display name of the title (e.g. "Basic Title", "Lower Third")
        effect_id: Direct effect ID (e.g. "FFBasicTitleEffect")
    """
    params = {}
    if name:
        params["name"] = name
    if effect_id:
        params["effectID"] = effect_id
    r = bridge.call("titles.insert", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_transcript_engine")
def set_transcript_engine(engine: str) -> str:
    """Set the speech recognition engine for transcript panel.

    Args:
        engine: One of:
            - "fcpNative": FCP's built-in AASpeechAnalyzer
            - "appleSpeech": Apple's SFSpeechRecognizer (slower, network-capable)
    """
    r = bridge.call("transcript.setEngine", engine=engine)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Social Media Captions
# ============================================================
# Word-by-word highlighted, animated caption titles overlaid
# on the timeline as a connected storyline. Uses the Parakeet
# transcript engine for word timing, then generates styled
# FCPXML title elements and imports via pasteboard.


@splicekit_tool("open_captions")
def open_captions(file_url: str = "", style: str = "") -> str:
    """Open the social captions panel and start transcribing the timeline.

    Transcribes timeline audio using Parakeet (word-level timing), then lets
    you choose a visual style and generate social-media-style captions
    (word-by-word highlighted, animated) as FCPXML title clips.

    Args:
        file_url: Optional path to a specific media file to transcribe.
                  If empty, transcribes all clips on the current timeline.
        style: Optional preset ID to apply (e.g. "bold_pop", "neon_glow").
               Use get_caption_styles() to see all available presets.

    Transcription is async — use get_caption_state() to check progress.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if style:
        params["style"] = style
    r = bridge.call("captions.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("close_captions")
def close_captions() -> str:
    """Close the social captions panel."""
    r = bridge.call("captions.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Captions panel closed."


@splicekit_tool("get_caption_state")
def get_caption_state() -> str:
    """Get the current caption panel state.

    Returns status, word count, segment count, current style, and segment list.
    Use after open_captions() to check transcription progress.

    `Last error` is the panel's own record of the last caption run that went wrong.
    It is a state reading, not a failure of this call.
    """
    r = bridge.call("captions.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Segments: {r.get('segmentCount', 0)}")
    if r.get("lastError"):
        lines.append(f"Last error (from an earlier caption run): {r['lastError']}")

    if r.get('style'):
        s = r['style']
        lines.append(f"\nStyle: {s.get('name', 'Custom')}")
        lines.append(f"  Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        lines.append(f"  Position: {s.get('position', '?')}")
        lines.append(f"  Animation: {s.get('animation', 'none')}")
        lines.append(f"  Word highlight: {s.get('wordByWordHighlight', False)}")

    if r.get('segments'):
        lines.append(f"\nSegments ({len(r['segments'])}):")
        for seg in r['segments'][:20]:
            lines.append(f"  [{seg['index']:3d}] {seg['startTime']:.2f}s - "
                         f"{seg['endTime']:.2f}s \"{seg['text']}\"")
        if len(r['segments']) > 20:
            lines.append(f"  ... and {len(r['segments']) - 20} more")

    return "\n".join(lines)


@splicekit_tool("get_caption_styles")
def get_caption_styles() -> str:
    """List all available caption style presets.

    Returns preset IDs and their visual characteristics (font, colors, animation).
    Use set_caption_style() or generate_captions() with a preset ID to apply one.
    """
    r = bridge.call("captions.getStyles")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Available caption styles ({r.get('count', 0)}):"]
    for s in r.get('styles', []):
        lines.append(f"\n  {s['presetID']}: \"{s['name']}\"")
        lines.append(f"    Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        hl = s.get('highlightColor', 'none')
        lines.append(f"    Text: {s.get('textColor', '?')}  Highlight: {hl}")
        lines.append(f"    Animation: {s.get('animation', 'none')}  Position: {s.get('position', 'bottom')}")
        lines.append(f"    Caps: {s.get('allCaps', False)}  Word highlight: {s.get('wordByWordHighlight', True)}")
    return "\n".join(lines)


@splicekit_tool("set_caption_style")
def set_caption_style(preset_id: str = "", font: str = "", font_size: float = 0,
                      text_color: str = "", highlight_color: str = "",
                      outline_color: str = "", outline_width: float = -1,
                      position: str = "", animation: str = "",
                      word_highlight: bool = True, all_caps: bool = False) -> str:
    """Set the caption style, either from a preset or with custom values.

    Args:
        preset_id: Preset name (e.g. "bold_pop", "neon_glow", "clean_minimal",
                   "karaoke", "social_bold"). Use get_caption_styles() for full list.
        font: Font family name (e.g. "Futura-Bold", "Impact", "Avenir-Heavy")
        font_size: Size in points (20-120)
        text_color: RGBA as "R G B A" (0-1 floats), e.g. "1 1 1 1" for white
        highlight_color: RGBA for active word highlight
        outline_color: RGBA for text outline/stroke
        outline_width: Stroke width (0-6)
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Enable word-by-word karaoke highlighting (default True)
        all_caps: Convert text to uppercase

    If preset_id is given, it's used as the base and other params override it.
    """
    params = {}
    if preset_id:
        params["presetID"] = preset_id
    if font:
        params["font"] = font
    if font_size > 0:
        params["fontSize"] = font_size
    if text_color:
        params["textColor"] = text_color
    if highlight_color:
        params["highlightColor"] = highlight_color
    if outline_color:
        params["outlineColor"] = outline_color
    if outline_width >= 0:
        params["outlineWidth"] = outline_width
    if position:
        params["position"] = position
    if animation:
        params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["allCaps"] = all_caps

    r = bridge.call("captions.setStyle", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_caption_grouping")
def set_caption_grouping(mode: str = "social", max_words: int = 3,
                         max_chars: int = 20, max_seconds: float = 3.0) -> str:
    """Configure how words are grouped into caption segments.

    Args:
        mode: "social" (2-3 words, 0.5s silence break — best for TikTok/Reels),
              "words" (by word count), "sentence" (by punctuation),
              "time" (by duration), "chars" (by character count)
        max_words: Max words per segment (when mode="words", default 3)
        max_chars: Max characters per segment (when mode="chars", default 20)
        max_seconds: Max duration per segment (when mode="time", default 3.0)
    """
    r = bridge.call("captions.setGrouping",
                    mode=mode, maxWords=max_words,
                    maxChars=max_chars, maxSeconds=max_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_captions")
def generate_captions(style: str = "", position: str = "center",
                      animation: str = "pop", word_highlight: bool = True,
                      max_words: int = 3, all_caps: bool = True) -> str:
    """Generate social-media-style captions and add them to the USER's timeline.

    One-shot tool: uses the current transcription (or existing words),
    applies the style, generates FCPXML title clips, imports them into a
    temp project, then copies and pastes them as a connected storyline
    onto the user's actual timeline. The temp project is deleted after.

    Position offset (bottom/center/top) is applied via ObjC transform
    after paste, not via FCPXML adjust-transform (which breaks with
    Motion templates).

    After insertion, the pipeline self-verifies by inspecting the first
    title's text channel — returns verified text, font size, and font
    family in the response.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        style: Preset ID (e.g. "bold_pop", "social_bold"). Empty = current style.
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Word-by-word karaoke highlighting (default True)
        max_words: Max words per caption segment (default 3)
        all_caps: Convert text to uppercase

    Returns the number of caption clips generated, import status,
    and self-verification results (text, fontSize, fontFamily).
    Remove pasted title captions with remove_captions(native=False).
    """
    params = {}
    if style:
        params["style"] = style
    params["position"] = position
    params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["maxWords"] = max_words
    params["allCaps"] = all_caps

    r = bridge.call("captions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("export_captions_srt")
def export_captions_srt(path: str) -> str:
    """Export the current captions as an SRT subtitle file.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.srt")

    Requires captions to have been transcribed first.

    If FCP shows a save panel for the path, while it is open the bridge cannot
    serve main-thread RPC. Save/open panels cannot be confirmed from the bridge —
    only dismiss_dialog(action=\"cancel\") closes them.
    """
    r = bridge.call("captions.exportSRT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("export_captions_txt")
def export_captions_txt(path: str) -> str:
    """Export the current captions as plain text.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.txt")

    If FCP shows a save panel for the path, while it is open the bridge cannot
    serve main-thread RPC. Save/open panels cannot be confirmed from the bridge —
    only dismiss_dialog(action=\"cancel\") closes them.
    """
    r = bridge.call("captions.exportTXT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_caption_words")
def set_caption_words(words: str) -> str:
    """Manually set caption words with timing (bypasses transcription).

    Args:
        words: JSON array of word objects, each with:
            {"text": "hello", "startTime": 1.5, "duration": 0.3}

    Use this when you already have word-level timing (e.g. from an SRT file
    or external transcription service).

    Example:
        set_caption_words('[
            {"text": "Hello", "startTime": 0.5, "duration": 0.3},
            {"text": "world", "startTime": 0.9, "duration": 0.4}
        ]')
    """
    try:
        word_list = json.loads(words)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    r = bridge.call("captions.setWords", words=word_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_native_captions")
def generate_native_captions(grouping: str = "word", language: str = "en",
                              max_words: int = 1, max_seconds: float = 3.0,
                              format: str = "ITT") -> str:
    """Generate native FCP captions (FFAnchoredCaption) with word-level timing.

    Unlike generate_captions() which creates styled Motion title clips for
    social media, this creates FCP's native caption/subtitle objects that
    appear in the dedicated caption lane. These are real captions — editable
    in FCP's caption editor and exportable as ITT/SRT/SCC files.

    The key feature: words appear one at a time (one caption per word),
    using precise word-level timing from Parakeet transcription.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        grouping: How to group words into captions.
                  "word" - one caption per word (default, words appear one at a time)
                  "phrase" or "sentence" - one caption per sentence
                  "group:N" - N words per caption (e.g. "group:3")
                  "time:S" - max S seconds per caption (e.g. "time:2.0")
                  "social" - 2-3 words, break on pauses (TikTok/Reels style)
        language: Language identifier (e.g. "en", "en-US", "fr")
        max_words: Override max words per caption (when grouping="word" or "group:N")
        max_seconds: Override max duration per caption (when grouping="time:S")
        format: Caption format - "ITT" (default), "SRT", or "CEA608"

    Returns the number of native captions created and their placement status.
    Remove them later with remove_captions(native=True).
    """
    params = {
        "grouping": grouping,
        "language": language,
        "maxWords": max_words,
        "maxSeconds": max_seconds,
        "format": format,
    }
    r = bridge.call("nativeCaptions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("cleanup_temp_projects")
def cleanup_temp_projects(dry_run: bool = False) -> str:
    """Remove stale scratch projects left by caption and song-structure pipelines.

    ``generate_native_captions``, ``song_structure_blocks`` (and related
    structure-caption import) and the FCPXML pasteboard route create temporary
    import projects named ``SpliceKit Caption Import <number>``, ``SK Structure
    <number>`` or ``_SKPaste_<number>``, inside events named ``SpliceKit Captions``
    or ``SpliceKit Structure``. They should be deleted automatically when each run
    finishes; this tool finds any that were left behind and moves them to the
    library Trash.

    An event SpliceKit's own FCPXML created, holding SpliceKit scratch and nothing
    else, goes as a unit. That is also the only way to clear a scratch project Final
    Cut Pro has not loaded, which is every one left over from an earlier session. An
    empty event is never removed, however its name reads.

    Your own projects and clips are never touched. The whole name has to match one of
    the shapes above — the number is required, and Final Cut Pro's own de-duplicating
    " 2" suffix is allowed after it. A project of yours called "SK Structure notes",
    or an event called "SpliceKit Captions Q3 review", does not match and is left
    alone. Run with ``dry_run=True`` first to see exactly what it would remove.

    Args:
        dry_run: When true, only list matching project names without deleting.

    Returns found/removed project and event names, plus any that failed to delete.
    """
    r = bridge.call("captions.cleanup", dryRun=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("verify_native_captions")
def verify_native_captions() -> str:
    """Verify native captions on the current timeline.

    Walks the timeline's caption lane and reports all FFAnchoredCaption
    objects found — their text, display names, and count. Use after
    generate_native_captions() to confirm captions were placed correctly.
    """
    r = bridge.call("nativeCaptions.verify")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


def _format_caption_removal_item(row: dict) -> str:
    label = row.get("displayName") or row.get("text") or row.get("class") or "?"
    text = row.get("text")
    if text and text != label:
        return f'  "{label}" — {text}'
    return f'  "{label}"'


def _render_remove_captions(r: dict) -> str:
    native = r.get("native", True)
    pipeline = (
        "native FFAnchoredCaption (generate_native_captions)"
        if native
        else "Motion title captions (generate_captions)"
    )
    found = int(r.get("foundCount", 0))
    removed = int(r.get("removedCount", 0))
    not_removed = r.get("notRemoved") or []
    items = r.get("items") or []

    if r.get("dryRun"):
        if found == 0:
            return f"Dry run: no {pipeline} items found on the timeline."
        lines = [f"Dry run — would remove {found} {pipeline} item(s):"]
        for row in items:
            lines.append(_format_caption_removal_item(row))
        return "\n".join(lines)

    if found == 0:
        return f"No {pipeline} items found on the timeline."

    lines = [
        f"Removed {removed} of {found} {pipeline} item(s) "
        f"(Edit > Undo \"Remove Captions\")."
    ]
    if not_removed:
        lines.append(f"Could not remove {len(not_removed)} item(s):")
        for row in not_removed:
            line = _format_caption_removal_item(row).lstrip()
            reason = row.get("reason")
            if reason:
                line += f" — {reason}"
            lines.append(f"  {line}")
    elif removed and items:
        lines.append("Removed:")
        for row in items[:min(len(items), removed)]:
            lines.append(_format_caption_removal_item(row))
    return "\n".join(lines)


@splicekit_tool("remove_captions")
def remove_captions(native: bool = True, dry_run: bool = False) -> str:
    """Delete caption items from the open sequence.

    Removes captions placed by SpliceKit caption pipelines — not scratch import
    projects (use cleanup_temp_projects for those).

    Args:
        native: When True (default), delete FCP native ``FFAnchoredCaption`` objects
            from the caption lane (the pipeline behind generate_native_captions).
            When False, delete connected Motion title clips produced by
            generate_captions (social-style title captions).
        dry_run: When True, report how many caption items would be removed without
            changing the timeline.

    Reports foundCount and removedCount separately. Only caption items from the
    chosen pipeline are considered; ordinary clips are never touched. Any item
    the bridge could not delete is listed under notRemoved with a reason.

    Supports undo via ``history_action("undo")``, which takes the whole removal back as
    one step. Run with dry_run=True first to see the count before committing.
    """
    r = bridge.call("nativeCaptions.remove", native=native, dryRun=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _render_remove_captions(r)


# ── Lua Scripting ────────────────────────────────────────────────────────────


@splicekit_tool("lua_execute")
def lua_execute(code: str) -> str:
    """Execute Lua code in SpliceKit's embedded Lua 5.4 VM running inside FCP.

    The VM is persistent — variables and state survive between calls.
    Use the `sk` module for FCP operations:
      sk.blade(), sk.clips(), sk.seek(5.0), sk.rpc("method", {params}), etc.

    Returns output (from print()), result (last expression value), and any error.

    Examples:
      lua_execute("sk.blade()")
      lua_execute("local clips = sk.clips(); return #clips")
      lua_execute("for i=1,5 do sk.next_frame() end")
      lua_execute("x = 42")  -- persists: lua_execute("return x") → 42
    """
    r = bridge.call("lua.execute", code=code)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    parts = []
    if r.get("output"):
        parts.append(r["output"].rstrip())
    if r.get("result"):
        parts.append(f"→ {r['result']}")
    if r.get("error"):
        parts.append(f"Error: {r['error']}")
    return "\n".join(parts) if parts else "ok"


@splicekit_tool("lua_execute_file")
def lua_execute_file(path: str) -> str:
    """Execute a Lua script file in SpliceKit's VM.

    Path can be absolute or relative to ~/Library/Application Support/SpliceKit/lua/.

    Examples:
      lua_execute_file("examples/blade_every_n_seconds.lua")
      lua_execute_file("/tmp/my_script.lua")
    """
    r = bridge.call("lua.executeFile", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    parts = []
    if r.get("output"):
        parts.append(r["output"].rstrip())
    if r.get("result"):
        parts.append(f"→ {r['result']}")
    if r.get("error"):
        parts.append(f"Error: {r['error']}")
    return "\n".join(parts) if parts else "ok"


@splicekit_tool("lua_reset")
def lua_reset() -> str:
    """Reset the Lua VM. All state (variables, loaded modules) is cleared and the sk module is re-registered."""
    r = bridge.call("lua.reset")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Lua VM reset"


@splicekit_tool("lua_watch")
def lua_watch(action: str = "list", path: str = "") -> str:
    """Manage Lua file watching for live coding.

    Actions:
      list   — show watched directories
      add    — watch a directory (files in auto/ subdirs execute on save)
      remove — stop watching a directory

    The default watched directory is ~/Library/Application Support/SpliceKit/lua/.
    Save .lua files to the auto/ subdirectory and they execute automatically on every save.
    """
    r = bridge.call("lua.watch", action=action, path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("lua_state")
def lua_state() -> str:
    """Get Lua VM state: memory usage, user-defined globals, watched paths, scripts directory."""
    r = bridge.call("lua.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Plugin System
# ============================================================
# Plugins can register JSON-RPC methods that become available as
# MCP tools automatically. The plugin.listMethods endpoint returns
# all registered plugin methods with metadata.


@splicekit_tool("plugin_list")
def plugin_list() -> str:
    """List all loaded SpliceKit plugins with their manifests."""
    return _call_or_error("plugin.list")


@splicekit_tool("plugin_list_methods")
def plugin_list_methods() -> str:
    """List all registered plugin methods with descriptions and parameter schemas."""
    return _call_or_error("plugin.listMethods")


_registered_plugin_tools = set()


def _register_plugin_tools(timeout: float = None):
    """Query SpliceKit for registered plugin methods and create MCP tools dynamically.

    Called at module load time. If FCP isn't running yet, this silently skips —
    plugin methods can still be called through the raw_call tool. Use
    reload_plugin_tools() to refresh after FCP launches or plugins change.
    """
    try:
        # A short timeout: this runs at import, before the MCP handshake, and a Final
        # Cut Pro that accepted the connection but is busy on its main thread must not
        # delay the client's initialize by the full read timeout.
        r = bridge.call("plugin.listMethods", timeout=timeout)
        if _err(r) or "methods" not in r:
            return 0
        count = 0
        for m in r["methods"]:
            method_name = m.get("name")
            if not method_name:
                continue

            # Build a safe tool name: com.example.plugin.greet -> com_example_plugin_greet
            tool_name = "plugin_" + method_name.replace(".", "_")
            if tool_name in _registered_plugin_tools:
                continue  # already registered by an earlier call; the SDK keeps the first
            description = m.get("description", f"Plugin method: {method_name}")
            plugin_name = m.get("pluginId", "")
            short_name = m.get("shortName", method_name)
            read_only = m.get("readOnly", False)

            # Create a closure that captures the method name
            def make_handler(mn):
                def handler(params: str = "{}") -> str:
                    try:
                        p = json.loads(params)
                    except json.JSONDecodeError as e:
                        return f"Invalid JSON params: {e}"
                    r = bridge.call(mn, **p)
                    if _err(r):
                        return f"Error: {r.get('error', r)}"
                    return _fmt(r)
                handler.__name__ = tool_name
                handler.__doc__ = description
                return handler

            title = f"{plugin_name}: {short_name}" if plugin_name else short_name
            annotations = ToolAnnotations(title=title, **(READ_ONLY if read_only else LOCAL_WRITE))
            mcp.tool(annotations=annotations)(_guard_tool_errors(make_handler(method_name)))
            _registered_plugin_tools.add(tool_name)
            if read_only:
                READ_ONLY_TOOLS.add(tool_name)
            else:
                LOCAL_WRITE_TOOLS.add(tool_name)
            count += 1
        return count
    except Exception:
        return 0  # FCP not running yet — no plugin tools to register


# Register plugin tools at startup (best-effort)
_plugin_tool_count = _register_plugin_tools(timeout=2.0)


@splicekit_tool("reload_plugin_tools")
def reload_plugin_tools() -> str:
    """Reload plugin tools from SpliceKit.

    Call this after FCP launches or after installing new plugins to make their
    methods available as MCP tools. Tools registered earlier stay registered; only
    new plugin methods are added. The client has to list tools again to see them:
    this server sends no tools/list_changed notification.
    """
    added = _register_plugin_tools()
    if added:
        _forbid_unknown_tool_arguments()  # newly registered tools need it too
    total = len(_registered_plugin_tools)
    return (
        f"Plugin tools reloaded: {added} new tool(s) registered "
        f"({total} plugin tool(s) total). Re-list MCP tools to see new names."
    )


# ============================================================
# MCP Resources
# ============================================================
# Read-only contextual data that models can pre-load before
# acting. Cheaper than tool calls — no side effects, cacheable.


@mcp.resource("splicekit://project/info",
              name="Project Info",
              description="Current project name, library, event, timeline state, version, and library status",
              mime_type="application/json")
def resource_project_info() -> str:
    """Return project-level context: what's loaded, library name, version, library status."""
    r = bridge.call("system.version")
    version_info = r if not _err(r) else {}

    r2 = bridge.call("timeline.getState")
    timeline_state = r2 if not _err(r2) else {}

    r3 = bridge.call("playback.getPosition")
    playhead = r3 if not _err(r3) else {}

    r4 = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                      selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    libraries = r4 if not _err(r4) else {}

    r5 = bridge.call("system.callMethod", className="FFLibraryDocument",
                      selector="isAnyLibraryUpdating", classMethod=True)
    updating = r5 if not _err(r5) else {}

    return json.dumps({
        "splicekit": version_info,
        "timeline": timeline_state,
        "playhead": playhead,
        "libraries": libraries,
        "isLibraryUpdating": updating,
    }, indent=2, default=str)


@mcp.resource("splicekit://timeline/clips",
              name="Timeline Clips",
              description="All clips on the active timeline with handles, durations, types, and track positions",
              mime_type="application/json")
def resource_timeline_clips() -> str:
    """Return the full clip list for the active timeline."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/markers",
              name="Timeline Markers",
              description="All markers in the active timeline with type, position, name, and notes",
              mime_type="application/json")
def resource_timeline_markers() -> str:
    """Return all markers from the active timeline (timeline.getMarkers)."""
    r = bridge.call("timeline.getMarkers")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    markers = r.get("markers", []) or []
    return json.dumps({"markers": markers, "count": len(markers)}, indent=2, default=str)


@mcp.resource("splicekit://effects/available",
              name="Available Effects",
              description="All installed video effects, generators, titles, and audio effects",
              mime_type="application/json")
def resource_available_effects() -> str:
    """Return all available effects from FCP."""
    r = bridge.call("effects.listAvailable", type="all")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://transitions/available",
              name="Available Transitions",
              description="All installed video transitions with names, effect IDs, and categories",
              mime_type="application/json")
def resource_available_transitions() -> str:
    """Return all available transitions from FCP."""
    r = bridge.call("transitions.list")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/selected-clips",
              name="Selected Clips",
              description="Currently selected clips in the timeline with handles, durations, and properties",
              mime_type="application/json")
def resource_selected_clips() -> str:
    """Return only the currently selected clips."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    items = [i for i in r.get("items", []) if i.get("selected")]
    return json.dumps({"selectedCount": len(items), "items": items}, indent=2, default=str)


@mcp.resource("splicekit://timeline/analysis",
              name="Timeline Analysis",
              description="Timeline statistics: clip count, duration, pacing, potential issues (flash frames, long clips)",
              mime_type="application/json")
def resource_timeline_analysis() -> str:
    """Return timeline analysis: pacing stats, potential issues, structure."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    pacing = "unknown"
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "accelerating"
        elif q4_avg > q1_avg * 1.3:
            pacing = "decelerating"
        else:
            pacing = "steady"

    issues = []
    if short_clips:
        issues.append(f"{len(short_clips)} flash frames (< 0.5s)")
    if long_clips:
        issues.append(f"{len(long_clips)} long clips (> 30s)")

    return json.dumps({
        "sequenceName": r.get("sequenceName", "?"),
        "durationSeconds": round(total_dur, 2),
        "playheadSeconds": round(playhead, 2),
        "clipCount": len(clips),
        "transitionCount": len(transitions),
        "avgClipDuration": round(avg_dur, 2),
        "minClipDuration": round(min_dur, 2),
        "maxClipDuration": round(max_dur, 2),
        "pacing": pacing,
        "issues": issues,
    }, indent=2, default=str)


@mcp.resource("splicekit://clips/applied-effects",
              name="Applied Effects",
              description="Effects currently applied to the selected clip, with names, IDs, and handles",
              mime_type="application/json")
def resource_applied_effects() -> str:
    """Return effects applied to the current/selected clip."""
    r = bridge.call("effects.getClipEffects")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://browser/clips",
              name="Browser Clips",
              description="Clips available in the FCP browser/media library with names, durations, and handles",
              mime_type="application/json")
def resource_browser_clips() -> str:
    """Return clips from the active library's browser."""
    r = bridge.call("browser.listClips")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://config/instructions",
              name="Editing Instructions",
              description="Operating rules, workflow guidance, and best practices for AI-driven FCP editing",
              mime_type="text/markdown")
def resource_instructions() -> str:
    """Workflow guidance and operating rules for models using SpliceKit.

    This teaches the model how to use SpliceKit properly regardless of
    whether CLAUDE.md is in context.
    """
    return """# SpliceKit Operating Instructions

## Golden Rules
1. **NEVER use keyboard simulation or AppleScript.** All actions go through direct ObjC calls via the bridge.
2. **Discover before editing.** Call get_timeline_clips() or read splicekit://timeline/clips before making changes.
3. **Select before acting.** Color correction, effects, retiming, and titles require a clip to be selected first.
4. **Verify after editing.** Use verify_action(), capture_timeline(), or capture_viewer() to confirm results.
5. **Prefer non-destructive workflows.** Use undo via timeline_action("undo") if something goes wrong.

## Standard Workflow
1. bridge_status() — verify FCP is connected
2. open_project("Name") — load a project
3. get_timeline_clips() — see timeline contents
4. Position playhead → select clip → apply action
5. verify_action() — confirm the edit took effect
6. capture_timeline() / capture_viewer() — visual verification

## Selection Pattern
```
playback_action("goToStart")
timeline_action("selectClipAtPlayhead")   # select primary storyline clip
timeline_action("addColorBoard")          # now apply effect/correction
```

For connected clips (B-roll, titles): use select_clip_in_lane(lane=1) for above, lane=-1 for below.

## Playhead Positioning
- 1 frame = ~0.042s at 24fps, ~0.033s at 30fps
- Use seek_to_time(seconds) for precise positioning
- Use batch_timeline_actions() for multi-step navigation + edit sequences
- Avoid frame-stepping loops when seek_to_time exists

## Batch Operations
Use batch_timeline_actions() for multi-step sequences rather than individual tool calls.
Use apply_transition_to_all_clips() to add transitions at every edit point at once.
Use blade_at_times() to cut at multiple timecodes in one call.
Use add_markers_at_times() to place markers at multiple positions.

## FCPXML for Complex Edits
For creating entire projects with precise timing, gaps, titles, and markers:
```
xml = generate_fcpxml(items='[{"type":"gap","duration":5},{"type":"title","text":"Hello","duration":3}]')
import_fcpxml(xml, internal=True)
```

## Timeline Data Model
FCP uses a spine model: sequence → primaryObject (collection) → items.
Items are FFAnchoredMediaComponent (clips), FFAnchoredTransition, etc.
get_timeline_clips() returns handles for each item — use handles in subsequent calls.

## Error Recovery
- timeline_action("undo") to reverse the last edit
- release_all_handles() to clean up leaked object handles
- bridge_status() to check if the connection is still alive
"""


# ============================================================
# MCP Prompts
# ============================================================
# Workflow templates for common editing scenarios. Each prompt
# provides role context, step-by-step guidance, and attaches
# the instructions resource for operating rules.


@mcp.prompt(name="edit_podcast",
            description="Multi-participant podcast editing: silence removal, leveling, chapter markers")
def prompt_edit_podcast(episode_name: str = "", participants: str = "") -> str:
    """Guide for editing a podcast episode in FCP."""
    return f"""You are an expert podcast editor working in Final Cut Pro via SpliceKit.

Task: Edit the podcast episode{f' "{episode_name}"' if episode_name else ''}{f' with participants: {participants}' if participants else ''}.

## Workflow
1. **Setup**: Open the project and review the timeline with get_timeline_clips()
2. **Silence removal**: Use detect_scene_changes() to find dead air, then blade_at_times() to cut silent sections
3. **Audio leveling**: Check levels across participants — use timeline_action("adjustVolumeUp/Down") to balance
4. **Cleanup**: Remove filler words, long pauses, and false starts by selecting and deleting clips
5. **Chapter markers**: Add chapter markers at topic transitions using timeline_action("addChapterMarker")
6. **Transitions**: Add cross dissolves between segments with apply_transition_to_all_clips() or individual apply_transition()
7. **Export**: Use generate_fcpxml() to export, or share_project() for direct export

## Tips
- Use capture_timeline() frequently to verify your edits visually
- Use batch_timeline_actions() for efficient multi-step editing
- Silence detection threshold can be tuned with set_silence_threshold()
"""


@mcp.prompt(name="edit_music_video",
            description="Beat-synced music video editing with scene detection and montage assembly")
def prompt_edit_music_video(song_name: str = "", style: str = "bar") -> str:
    """Guide for editing a music video synced to beats."""
    return f"""You are an expert music video editor working in Final Cut Pro via SpliceKit.

Task: Edit a music video{f' for "{song_name}"' if song_name else ''} with cuts synced to the music.

## Workflow
1. **Analyze music**: Use detect_beats() to find beat positions, then analyze_song_structure() for sections
2. **Score clips**: Use montage_analyze_clips() to rank available footage
3. **Plan the edit**: Use montage_plan_edit() with style="{style}" to map clips to musical segments
4. **Assemble**: Use montage_assemble() to build the timeline, or montage_auto() for one-shot creation
5. **Refine**: Review with capture_viewer(), adjust individual clips, add effects
6. **Transitions**: Add transitions at cut points — apply_transition_to_all_clips() for uniform look, or individual apply_transition() for variety
7. **Color**: Select clips and apply color correction with timeline_action("addColorBoard") or timeline_action("addColorCurves")

## Beat Sync Tips
- "beat" style cuts on every beat (fast, energetic)
- "bar" style cuts on every measure (balanced, standard)
- "section" style cuts on verse/chorus boundaries (cinematic, slower)
- Use blade_at_times() to manually cut at specific beat positions
"""


@mcp.prompt(name="social_media_reformat",
            description="Reformat a timeline for social media: aspect ratio, captions, pacing")
def prompt_social_media(platform: str = "instagram", source_project: str = "") -> str:
    """Guide for reformatting content for social media platforms."""
    specs = {
        "instagram": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "tiktok": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "youtube_shorts": {"aspect": "9:16 (1080x1920)", "duration": "up to 60s", "captions": True},
        "youtube": {"aspect": "16:9 (1920x1080)", "duration": "any", "captions": True},
        "twitter": {"aspect": "16:9 or 1:1", "duration": "up to 2:20", "captions": True},
    }
    spec = specs.get(platform, specs["instagram"])

    return f"""You are a social media content editor working in Final Cut Pro via SpliceKit.

Task: Reformat{f' "{source_project}"' if source_project else ' the current project'} for {platform}.

## Target Specs
- Aspect ratio: {spec['aspect']}
- Duration: {spec['duration']}
- Captions: {'Required for accessibility' if spec['captions'] else 'Optional'}

## Workflow
1. **Review source**: get_timeline_clips() to understand the current edit
2. **Trim for length**: Identify the strongest {spec['duration']} segment — blade and remove excess
3. **Add captions**: Use open_transcript() to transcribe, then generate_captions() for subtitles
4. **Style captions**: Use set_caption_style() and set_caption_grouping() for platform-appropriate look
5. **Pacing**: Tighten cuts — social content needs faster pacing than long-form
6. **Visual polish**: Add effects, color correction, titles as needed
7. **Export**: share_project() or generate FCPXML

## Social Media Tips
- Front-load the hook in the first 3 seconds
- Captions are essential — most viewers watch without sound
- Use generate_social_captions() for word-by-word highlighting style
- Keep text and key visuals in the center safe zone for 9:16
"""


@mcp.prompt(name="color_grade",
            description="Color grading workflow: correction, look development, consistency")
def prompt_color_grade(look: str = "", mood: str = "") -> str:
    """Guide for color grading a project in FCP."""
    return f"""You are a professional colorist working in Final Cut Pro via SpliceKit.

Task: Color grade the current project{f' with a {look} look' if look else ''}{f' for a {mood} mood' if mood else ''}.

## Workflow
1. **Review**: get_timeline_clips() and capture_viewer() to assess current color state
2. **Primary correction** (per clip):
   - Select clip: timeline_action("selectClipAtPlayhead")
   - Add Color Board: timeline_action("addColorBoard") for basic lift/gamma/gain
   - Or Color Wheels: timeline_action("addColorWheels") for more control
   - Or Color Curves: timeline_action("addColorCurves") for precise curve adjustments
3. **Look development**: Use timeline_action("addHueSaturation") for selective color shifts
4. **Consistency**: Apply the same correction across similar clips using copy/paste attributes
5. **Verify**: capture_viewer() after each correction to check the result

## Color Tools Available
- addColorBoard — basic 3-way (global, shadows, midtones, highlights)
- addColorWheels — lift/gamma/gain wheels
- addColorCurves — RGB curves
- addColorAdjustment — exposure, saturation, black point
- addHueSaturation — selective hue shifts
- addEnhanceLightAndColor — FCP's auto enhancement
- balanceColor — automatic white balance
- matchColor — match color between clips

## Tips
- Always correct exposure/white balance first, then add creative looks
- Use capture_viewer() frequently to compare before/after
- Work clip-by-clip for narrative, or batch for documentary/event
"""


@mcp.prompt(name="rough_cut_assembly",
            description="Assemble a rough cut from clips: import, arrange, basic transitions")
def prompt_rough_cut(project_name: str = "", clip_folder: str = "") -> str:
    """Guide for assembling a rough cut from raw footage."""
    return f"""You are an assistant editor assembling a rough cut in Final Cut Pro via SpliceKit.

Task: Build a rough cut{f' for "{project_name}"' if project_name else ''}{f' from clips in {clip_folder}' if clip_folder else ''}.

## Workflow
1. **Review footage**: get_timeline_clips() to see what's in the timeline, or montage_analyze_clips() to score available clips
2. **Arrange clips**: Use the montage tools for automated assembly, or manually:
   - Position playhead where you want to place each clip
   - Use FCPXML for precise placement: generate_fcpxml() + import_fcpxml()
3. **Rough ordering**: Get the story structure right before fine-tuning
4. **Basic transitions**: apply_transition_to_all_clips() for uniform cross dissolves, or apply_transition() at specific cuts
5. **Timing**: Adjust clip durations, add gaps for pacing
6. **Review**: capture_timeline() for layout overview, capture_viewer() for content check

## Assembly Tips
- Start with the strongest clips, fill in secondary footage later
- Don't worry about perfect timing in a rough cut — focus on story order
- Use markers (timeline_action("addMarker")) to flag sections needing attention
- Use todo markers (timeline_action("addTodoMarker")) for notes on missing content
"""


@mcp.prompt(name="caption_workflow",
            description="Full captioning pipeline: transcribe, generate, style, and export captions")
def prompt_caption_workflow(language: str = "en", export_format: str = "srt") -> str:
    """Guide for the complete captioning workflow."""
    return f"""You are a captioning specialist working in Final Cut Pro via SpliceKit.

Task: Create captions for the current timeline in {language}, export as {export_format.upper()}.

## Workflow
1. **Transcribe**: open_transcript() to start the Parakeet speech-to-text engine
2. **Review transcript**: get_transcript() to read the text, search_transcript() to find specific words
3. **Clean up**: delete_transcript_words() to remove filler, move_transcript_words() to fix ordering
4. **Remove silence**: delete_transcript_silences() to clean dead air (tune with set_silence_threshold())
5. **Generate captions**: generate_captions() to create subtitle track from transcript
6. **Style**: set_caption_style() for font, size, position; set_caption_grouping() for line breaks
7. **Verify**: verify_captions() to check timing and content, capture_viewer() to see visual result
8. **Export**: export_captions_srt() for SRT or export_captions_txt() for plain text

## Caption Tips
- Use generate_social_captions() for word-by-word highlighting (TikTok/Reels style)
- Parakeet v3 supports multilingual transcription
- SRT is universal; use it for YouTube, Vimeo, social platforms
- Always verify_captions() before export to catch timing issues
"""


@mcp.prompt(name="documentary_editing",
            description="Documentary editing: interview structure, B-roll, narrative pacing")
def prompt_documentary(topic: str = "") -> str:
    """Guide for documentary-style editing."""
    return f"""You are a documentary editor working in Final Cut Pro via SpliceKit.

Task: Edit a documentary{f' about "{topic}"' if topic else ''}.

## Workflow
1. **Organize**: Review all clips with get_timeline_clips(), use markers to tag key moments
2. **Structure**: Build the narrative arc — establish the story spine with interview clips
3. **Transcribe**: Use open_transcript() + get_transcript() to find the best soundbites
4. **Assemble**: Place interview clips in story order using FCPXML or montage tools
5. **B-roll**: Layer supporting footage above the primary storyline:
   - select_clip_in_lane(lane=1) to work with connected clips
   - Use blade_at_times() to trim B-roll to match interview pacing
6. **Transitions**: Add dissolves at section breaks, hard cuts within scenes
7. **Audio**: Balance interview audio, add ambient sound, music bed
8. **Captions**: Full caption workflow for accessibility
9. **Review**: capture_viewer() and capture_timeline() throughout

## Documentary Tips
- Let interviews drive the structure, B-roll supports the narrative
- Use chapter markers (timeline_action("addChapterMarker")) at major sections
- Use todo markers for sections needing pickup shots or additional footage
- Color correct interviews for consistency, grade B-roll for mood
"""


# ============================================================
# Batch Effect & Color Tools
# ============================================================
# Apply effects or corrections to multiple clips in one call,
# reducing round-trips for common bulk operations.

_BATCH_SPINE_READ_LIMIT = 10000


def _spine_item_accepts_batch_effect(item: dict) -> bool:
    """Primary-storyline items that cannot take a clip effect or color correction."""
    cls = str(item.get("class") or "")
    if "Transition" in cls:
        return False
    if "Gap" in cls or "Generator" in cls:
        return False
    return bool(item.get("handle"))


def _primary_storyline_targets_from_playhead(clip_count: int) -> tuple[list[dict], str | None]:
    """Ordered eligible primary-spine clips from the playhead clip through the end.

    Includes the clip whose range contains the playhead (start <= playhead < end), then every
    later eligible clip in timeline order. If the playhead is in a gap or past the end, only
    clips that start after the playhead are included.
    """
    r = bridge.call(
        "timeline.getDetailedState",
        limit=_BATCH_SPINE_READ_LIMIT,
        include_connected=False,
        include_markers=False,
    )
    if _err(r):
        return [], f"Error reading timeline: {r.get('error', r)}"

    spine_total = int(r.get("itemCount") or 0)
    items = r.get("items") or []
    if spine_total > len(items):
        return [], (
            f"Error: timeline has {spine_total} primary storyline items but getDetailedState "
            f"returned only {len(items)} (limit {_BATCH_SPINE_READ_LIMIT}); cannot batch safely"
        )

    playhead = _time_seconds(r, "playheadTime")
    if playhead is None:
        playhead = 0.0

    targets: list[dict] = []
    eps = 1e-9
    for item in items:
        if not _spine_item_accepts_batch_effect(item):
            continue
        start = _time_seconds(item, "startTime")
        end = _time_seconds(item, "endTime")
        if start is None:
            continue
        under_playhead = (
            end is not None
            and start <= playhead + eps
            and playhead < end - eps
        )
        starts_after = start > playhead + eps
        if not under_playhead and not starts_after:
            continue
        targets.append({
            "handle": item.get("handle"),
            "name": item.get("name") or "",
            "index": item.get("index"),
            "start_seconds": start,
        })

    if clip_count > 0:
        targets = targets[:clip_count]

    return targets, None


def _format_batch_clip_results(title: str, undo_name: str, clips_out: list[dict],
                               applied: int, extra_line: str = "") -> str:
    """Human-readable summary for batch_apply_effect / batch_color_correct."""
    total = len(clips_out)
    errors = total - applied
    lines = [f"{title}: {applied} of {total} clip(s) applied (Edit > Undo \"{undo_name}\")"]
    if errors:
        lines.append(f"  Errors: {errors}")
    if extra_line:
        lines.append(f"  {extra_line}")
    for c in clips_out:
        ok = c.get("success")
        tag = "ok" if ok else "FAILED"
        head = f"  [{tag}] {c.get('handle', '?')} \"{c.get('name', '')}\""
        if c.get("index") is not None:
            head += f" (spine {c['index']}"
            start = c.get("start_seconds")
            if isinstance(start, (int, float)):
                head += f" @ {float(start):.3f}s"
            head += ")"
        if ok:
            if c.get("effect"):
                head += f" — {c['effect']}"
            elif c.get("correction"):
                head += f" — {c['correction']}"
        else:
            head += f" — {c.get('error', 'unknown error')}"
        lines.append(head)
    return "\n".join(lines)


def _batch_select_clip_by_handle(handle: str) -> dict | None:
    """Select one spine/connected clip by handle; return bridge error dict or None on success."""
    r = bridge.call("timeline.selectItems", handles=[handle], mode="replace")
    if _err(r):
        return r
    unresolved = r.get("unresolved") or []
    if unresolved:
        return {"error": f"Handle not resolved: {unresolved[0]}"}
    if r.get("matchesRequest") is False and not (r.get("selected") or []):
        return {"error": "Selection did not match request (no clip selected)"}
    return None


@splicekit_tool("batch_apply_effect")
def batch_apply_effect(name: str = "", effectID: str = "", clip_count: int = 0) -> str:
    """Apply one effect to each targeted primary-storyline clip.

    Reads the spine once via timeline.getDetailedState (same data as get_timeline_clips),
    skips transitions and gap/generator items, selects each target clip by handle without
    moving the playhead, and applies the effect once per clip. Targets are the clip whose
    range contains the playhead (start <= playhead < end), then every eligible clip that
    starts after the playhead in timeline order. If the playhead is in a gap or past the end,
    only clips that start after the playhead are processed. The whole batch is a single undo
    step (Edit > Undo "Batch Apply Effect").

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur").
        effectID: The effect ID string (alternative to name).
        clip_count: Process only the first N eligible clips (0 = all targets to end of spine).
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    targets, err = _primary_storyline_targets_from_playhead(clip_count)
    if err:
        return err
    if not targets:
        return "Error: no primary storyline clips from the playhead onward accept an effect"

    undo_name = "Batch Apply Effect"
    r = bridge.call("timeline.beginEdit", name=undo_name)
    if _err(r):
        return f"Error opening undo step: {r.get('error', r)}"

    clips_out: list[dict] = []
    applied = 0
    try:
        for target in targets:
            handle = target["handle"]
            entry: dict = {
                "handle": handle,
                "name": target["name"],
                "index": target.get("index"),
                "start_seconds": target.get("start_seconds"),
            }
            sel_err = _batch_select_clip_by_handle(handle)
            if sel_err:
                entry["success"] = False
                entry["error"] = sel_err.get("error", str(sel_err))
                clips_out.append(entry)
                continue

            params: dict = {}
            if effectID:
                params["effectID"] = effectID
            if name:
                params["name"] = name
            r = bridge.call("effects.apply", **params)
            if _err(r):
                entry["success"] = False
                entry["error"] = r.get("error", str(r))
            else:
                entry["success"] = True
                entry["effect"] = r.get("effect", name or effectID or "?")
                applied += 1
            clips_out.append(entry)
    finally:
        bridge.call("timeline.endEdit", name=undo_name)

    if applied == 0:
        return (
            "Error: batch apply failed on all "
            + _format_batch_clip_results("Batch Apply Effect", undo_name, clips_out, 0)
        )

    effect_line = ""
    if name:
        effect_line = f"Effect name: {name}"
    elif effectID:
        effect_line = f"Effect ID: {effectID}"
    return _format_batch_clip_results("Batch Apply Effect", undo_name, clips_out, applied, effect_line)


@splicekit_tool("batch_color_correct")
def batch_color_correct(correction: str = "addColorBoard", clip_count: int = 0) -> str:
    """Apply one color correction to each targeted primary-storyline clip.

    Reads the spine once via timeline.getDetailedState (same data as get_timeline_clips),
    skips transitions and gap/generator items, selects each target clip by handle without
    moving the playhead, and runs the correction action once per clip. Targets are the clip
    whose range contains the playhead (start <= playhead < end), then every eligible clip that
    starts after the playhead in timeline order. If the playhead is in a gap or past the end,
    only clips that start after the playhead are processed. The whole batch is a single undo
    step (Edit > Undo "Batch Color Correct").

    Args:
        correction: The color correction action. One of:
            "addColorBoard", "addColorWheels", "addColorCurves",
            "addColorAdjustment", "addHueSaturation",
            "addEnhanceLightAndColor", "balanceColor", "matchColor"
        clip_count: Process only the first N eligible clips (0 = all targets to end of spine).
    """
    valid_corrections = {
        "addColorBoard", "addColorWheels", "addColorCurves",
        "addColorAdjustment", "addHueSaturation",
        "addEnhanceLightAndColor", "balanceColor", "matchColor",
    }
    if correction not in valid_corrections:
        return f"Error: correction must be one of: {', '.join(sorted(valid_corrections))}"

    targets, err = _primary_storyline_targets_from_playhead(clip_count)
    if err:
        return err
    if not targets:
        return "Error: no primary storyline clips from the playhead onward accept color correction"

    undo_name = "Batch Color Correct"
    r = bridge.call("timeline.beginEdit", name=undo_name)
    if _err(r):
        return f"Error opening undo step: {r.get('error', r)}"

    clips_out: list[dict] = []
    applied = 0
    try:
        for target in targets:
            handle = target["handle"]
            entry: dict = {
                "handle": handle,
                "name": target["name"],
                "index": target.get("index"),
                "start_seconds": target.get("start_seconds"),
            }
            sel_err = _batch_select_clip_by_handle(handle)
            if sel_err:
                entry["success"] = False
                entry["error"] = sel_err.get("error", str(sel_err))
                clips_out.append(entry)
                continue

            r = bridge.call("timeline.action", action=correction)
            if _err(r):
                entry["success"] = False
                entry["error"] = r.get("error", str(r))
            else:
                entry["success"] = True
                entry["correction"] = correction
                applied += 1
            clips_out.append(entry)
    finally:
        bridge.call("timeline.endEdit", name=undo_name)

    if applied == 0:
        return (
            "Error: batch color correct failed on all "
            + _format_batch_clip_results("Batch Color Correct", undo_name, clips_out, 0,
                                         f"Correction: {correction}")
        )

    return _format_batch_clip_results(
        "Batch Color Correct", undo_name, clips_out, applied, f"Correction: {correction}")


def _forbid_unknown_tool_arguments() -> int:
    """Make every tool reject arguments it does not declare.

    The SDK derives each tool's argument model from its signature, and pydantic
    ignores extra fields by default. A tool that takes parameters therefore rejects
    an unknown key (the model has fields, and a typo shows up as a validation
    error), but a tool that takes none silently accepts anything:

        bridge_alive(bogus_arg=1)   ->  ran, returned normally, ignored bogus_arg

    That turns a caller's typo into a silent no-op, which is exactly the failure
    that is hardest to read back from a transcript. Forbid extras everywhere, so a
    wrong argument name is always an error that says which name was wrong.

    Returns the number of tools tightened. Call this again after registering more
    tools at runtime (see reload_plugin_tools).
    """
    tightened = 0
    for tool in mcp._tool_manager.list_tools():
        try:
            model = tool.fn_metadata.arg_model
            if model.model_config.get("extra") != "forbid":
                model.model_config["extra"] = "forbid"
                model.model_rebuild(force=True)
            if isinstance(tool.parameters, dict):
                tool.parameters["additionalProperties"] = False
            tightened += 1
        except Exception:  # never let schema tightening stop the server starting
            _LOG.exception("could not forbid extra arguments on tool %s", tool.name)
    return tightened


_forbid_unknown_tool_arguments()


# MCP over stdio: the client (Claude Desktop, Claude Code, any MCP client) starts this
# file as a subprocess and speaks JSON-RPC on its stdin/stdout. While serving, the SDK
# points fd 1 at stderr so stray prints cannot corrupt the wire.
if __name__ == "__main__":
    mcp.run(transport="stdio")
