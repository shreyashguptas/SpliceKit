"""Tools: playhead position, dialogs, viewer zoom, SpliceKit options."""

from ..registry import DESTRUCTIVE, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error


# ============================================================
# Playhead Position & Monitoring
# ============================================================
# Query current playhead position, frame rate, and play state.

@splicekit_tool("get_playhead_position", READ)
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
    return _call_or_error("playback.getPosition")


# ============================================================
# Dialog Detection & Interaction
# ============================================================
# FCP pops up modal dialogs for various operations (project settings,
# export, missing media, etc). These tools detect and interact with
# them so the AI can handle dialogs without human intervention.

@splicekit_tool("detect_dialog", READ)
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

    Non-modal overlay windows with nothing to answer (FFOSCOverlayWindow, the Viewer's
    on-screen controls) are listed under `overlays`, not as dialogs, so hasDialog is a
    usable "clear to proceed" signal. When Final Cut Pro's main thread does not answer
    within 3 s (a long import's progress sheet), the answer comes from the window server
    instead: mainThreadBusy: true, window titles and sizes only.

    Args:
        view_tree: Also dump each dialog's raw view hierarchy (class, title, frame,
                   depth, and for buttons the cell shape). Use this when a sheet
                   reports no controls of the kind you expected — it shows what FCP
                   actually built the sheet from. Capped at 2048 nodes per dialog.
    """
    params = {"viewTree": True} if view_tree else {}
    return _call_or_error("dialog.detect", **params)


@splicekit_tool("click_dialog_button", DESTRUCTIVE)
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
    return _call_or_error("dialog.click", **params)


@splicekit_tool("fill_dialog_field", DESTRUCTIVE)
def fill_dialog_field(value: str, index: int = 0) -> str:
    """Fill a text field in the currently showing dialog.

    Args:
        value: Text to enter in the field
        index: Field index (0-based) if there are multiple fields

    Use detect_dialog() first to see available text fields and their indices.

    Filling a field does not commit anything on its own, but it decides what the button
    you click next will act on — a name typed here is the name a Save panel will use.
    """
    return _call_or_error("dialog.fill", value=value, index=index)


@splicekit_tool("toggle_dialog_checkbox", DESTRUCTIVE)
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
    return _call_or_error("dialog.checkbox", **params)


@splicekit_tool("select_dialog_popup", DESTRUCTIVE)
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
    return _call_or_error("dialog.popup", select=select, popupIndex=popup_index)


@splicekit_tool("dismiss_dialog", DESTRUCTIVE)
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
    return _call_or_error("dialog.dismiss", action=action)


# ============================================================
# Viewer Zoom
# ============================================================
# Get/set the canvas zoom level. 0.0 = fit-to-window.

@splicekit_tool("get_viewer_zoom", READ)
def get_viewer_zoom() -> str:
    """Get the current viewer zoom level.

    Returns the zoom factor (0.0 = Fit, 1.0 = 100%, 2.0 = 200%, etc.),
    the reported zoom percentage, and whether the viewer is in Fit mode.
    """
    return _call_or_error("viewer.getZoom")


@splicekit_tool("set_viewer_zoom", LOCAL_IDEMPOTENT)
def set_viewer_zoom(zoom: float) -> str:
    """Set the viewer zoom level to any value.

    Args:
        zoom: Zoom factor. 0.0 = Fit to window, 0.5 = 50%, 1.0 = 100%,
              1.5 = 150%, 2.0 = 200%, etc. Any float value is accepted
              (not limited to FCP's preset percentages).
    """
    return _call_or_error("viewer.setZoom", zoom=zoom)


# ============================================================
# SpliceKit Options
# ============================================================
# Runtime configuration for SpliceKit's own behavioral tweaks.

@splicekit_tool("get_bridge_options", READ)
def get_bridge_options() -> str:
    """Get the current SpliceKit option settings.

    Returns the state of all configurable options
    (e.g. effectDragAsAdjustmentClip, viewerPinchZoom, videoOnlyKeepsAudioDisabled,
    suppressAutoImport, defaultSpatialConformType).
    """
    return _call_or_error("options.get")


@splicekit_tool("set_bridge_option", LOCAL_IDEMPOTENT)
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
    return _call_or_error("options.set", option=option, enabled=enabled)


@splicekit_tool("set_bridge_option_value", LOCAL_IDEMPOTENT)
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
    return _call_or_error("options.set", option=option, value=value)
