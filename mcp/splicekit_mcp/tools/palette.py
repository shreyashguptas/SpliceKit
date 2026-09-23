"""Tools: command palette, LiveCam and palette commands."""

from ..registry import DESTRUCTIVE, LOCAL, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error, _err, bridge


# ============================================================
# Command Palette
# ============================================================
# A floating search palette (like VS Code's Cmd+Shift+P): fuzzy
# search over SpliceKit's commands, Return runs the selected one.

@splicekit_tool("show_command_palette", LOCAL)
def show_command_palette() -> str:
    """Open the command palette inside FCP.
    The palette provides quick access to all FCP actions via fuzzy search.
    Shortcut: Cmd+Shift+P
    """
    r = bridge.call("command.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette opened."


@splicekit_tool("hide_command_palette", LOCAL_IDEMPOTENT)
def hide_command_palette() -> str:
    """Close the command palette."""
    r = bridge.call("command.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette closed."


@splicekit_tool("livecam_open", LOCAL_IDEMPOTENT, title="Open LiveCam")
def livecam_open() -> str:
    """Open the LiveCam panel inside Final Cut Pro."""
    return _call_or_error("liveCam.show")


@splicekit_tool("livecam_close", LOCAL_IDEMPOTENT, title="Close LiveCam")
def livecam_close() -> str:
    """Close the LiveCam panel."""
    return _call_or_error("liveCam.hide")


@splicekit_tool("livecam_status", READ, title="Get LiveCam Status")
def livecam_status() -> str:
    """Get the current LiveCam panel state, selected devices, recording flags, and destination."""
    return _call_or_error("liveCam.status")


@splicekit_tool("search_commands", READ)
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


@splicekit_tool("execute_command", DESTRUCTIVE)
def execute_command(action: str, type: str = "timeline") -> str:
    """Execute a command from the palette by action name.

    Args:
        action: The action ID (e.g. "blade", "addColorBoard", "retimeSlow50")
        type: "timeline", "playback", or "transcript"

    This is equivalent to selecting a command in the palette and pressing Enter.
    """
    return _call_or_error("command.execute", action=action, type=type)
