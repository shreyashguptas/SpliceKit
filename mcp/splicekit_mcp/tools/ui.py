"""Tools: menus, inspector properties, panels, tool selection, roles."""

from ..registry import DESTRUCTIVE, LOCAL, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error


# ============================================================
# Menu Execute (universal menu access)
# ============================================================
# Fallback for anything that doesn't have a dedicated tool.
# Walks FCP's NSMenu hierarchy by title to reach any menu item.

@splicekit_tool("execute_menu_command", DESTRUCTIVE)
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
    return _call_or_error("menu.execute", menuPath=menu_path, dry_run=dry_run)


@splicekit_tool("list_menus", READ)
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
    return _call_or_error("menu.list", **params)


# ============================================================
# Inspector Properties (read/write clip properties)
# ============================================================
# Reads/writes FCP's internal effect parameter channels directly,
# bypassing the inspector UI. Works on transform, compositing, audio, crop.

@splicekit_tool("get_inspector_properties", READ)
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
    return _call_or_error("inspector.get", property=property)


@splicekit_tool("set_inspector_property", DESTRUCTIVE)
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
    return _call_or_error("inspector.set", property=property, value=value)


@splicekit_tool("get_title_text", READ)
def get_title_text() -> str:
    """Read text content, font, and size from the selected Motion title clip.

    Inspects the selected clip's effect channel tree to find CHChannelText nodes.
    Returns the rendered text string, font family, font name, and point size as
    stored in the NSAttributedString on the text channel.

    This is useful for verifying that title text imported via FCPXML actually
    rendered with the correct content and font size.

    Requires a title clip to be selected first (use timeline_action("selectClipAtPlayhead")).
    """
    return _call_or_error("inspector.getTitle")


@splicekit_tool("verify_captions", READ)
def verify_captions() -> str:
    """Verify that generated captions rendered correctly on the timeline.

    Checks the most recently generated captions by inspecting their text channels.
    Returns verification results: text content, font size, font family for each
    title that can be found. Reports any mismatches from the expected style.

    Run this after generate_captions() to confirm titles have visible text at
    the correct font size, without needing to ask the user to check manually.
    """
    return _call_or_error("captions.verify")


# ============================================================
# View/Panel Toggles
# ============================================================
# Show/hide FCP's various panels and viewers.

@splicekit_tool("toggle_panel", LOCAL)
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
               (audioCurves has no Final Cut Pro 12.3 equivalent and returns an error;
               fullscreenViewer starts Play Full Screen)
    """
    return _call_or_error("view.toggle", panel=panel)


@splicekit_tool("set_workspace", LOCAL_IDEMPOTENT)
def set_workspace(workspace: str) -> str:
    """Switch to a predefined workspace layout.

    Args:
        workspace: "default", "organize", "colorEffects", or "dualDisplays"
    """
    return _call_or_error("view.workspace", workspace=workspace)


# ============================================================
# Tool Selection
# ============================================================
# Switch the active editing tool (blade, trim, range, etc).

@splicekit_tool("select_tool", LOCAL_IDEMPOTENT)
def select_tool(tool: str) -> str:
    """Switch to a specific editing tool.

    Args:
        tool: "select", "trim", "blade", "position", "hand", "zoom",
              "range", "crop", "distort", "transform"
    """
    return _call_or_error("tool.select", tool=tool)


# ============================================================
# Roles Management
# ============================================================
# Roles control how clips appear in the timeline index and
# how they're grouped during export (e.g. separate Dialogue/Music stems).

@splicekit_tool("assign_role", LOCAL_IDEMPOTENT)
def assign_role(type: str, role: str) -> str:
    """Assign a role to the selected clip (Modify > Assign Video / Audio / Caption Roles).

    Works with Final Cut Pro in the background: SpliceKit has FCP fill the submenu from
    the current selection, then chooses the role. The answer reports the role FCP now
    checks for the selection (`verified`); an unknown name lists the roles FCP offers.
    One undo step ("Set Role").

    Args:
        type: "audio", "video", or "caption"
        role: Role name as FCP lists it (e.g. "Dialogue", "Music", "Effects", "Titles", "Video")
    """
    return _call_or_error("roles.assign", type=type, role=role)
