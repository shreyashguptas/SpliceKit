"""Tool annotation sets, the @splicekit_tool decorator, and argument tightening."""

import inspect
import functools

from .sdk import ToolAnnotations, ToolError
from .config import _LOG
from .app import mcp


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
    "import_fcpxml_status",
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
    "import_fcpxml_status": "FCPXML Import Status",
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
