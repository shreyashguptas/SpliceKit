"""Tools: share, create project / event / library, open project, dual timeline."""

from ..registry import splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge


# ============================================================
# Share/Export
# ============================================================
# Triggers FCP's share destinations (Export File, YouTube, etc).

@splicekit_tool("share_project")
def share_project(destination: str = "") -> str:
    """Share/export the project using a specific or the default destination.

    This starts the export and returns straight away with `dialogPending: true` and the
    destination it used. It does not finish the export: Final Cut Pro opens its Export
    sheet and waits for someone at the machine to answer it. The bridge can read that
    sheet with detect_dialog() and close it with dismiss_dialog(action="cancel"), but it
    cannot confirm a save panel, so nothing is written until a person clicks through.

    With no destination it uses whichever one Final Cut Pro marks "(default)" in
    File > Share, and tells you which that was.

    Args:
        destination: Share destination name exactly as File > Share lists it (e.g.
                     "Export File (default)…", "Apple Devices 1080p…", "Social
                     Platforms…"). A trailing ellipsis may be left off. Leave empty for
                     the default destination. On a miss the error lists every destination
                     the menu actually has; list_menus(menu="File") shows them too.
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
