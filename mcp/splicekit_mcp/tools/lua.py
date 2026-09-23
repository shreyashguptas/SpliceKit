"""Tools: the embedded Lua VM."""

from ..registry import DESTRUCTIVE, READ, splicekit_tool
from ..bridge import _call_or_error, _err, bridge


# ── Lua Scripting ────────────────────────────────────────────────────────────


@splicekit_tool("lua_execute", DESTRUCTIVE, title="Execute Lua Code")
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


@splicekit_tool("lua_execute_file", DESTRUCTIVE, title="Execute Lua File")
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


@splicekit_tool("lua_reset", DESTRUCTIVE, title="Reset Lua VM")
def lua_reset() -> str:
    """Reset the Lua VM. All state (variables, loaded modules) is cleared and the sk module is re-registered."""
    r = bridge.call("lua.reset")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Lua VM reset"


@splicekit_tool("lua_watch", DESTRUCTIVE, title="Watch Lua Files")
def lua_watch(action: str = "list", path: str = "") -> str:
    """Manage Lua file watching for live coding.

    Actions:
      list   — show watched directories
      add    — watch a directory (files in auto/ subdirs execute on save)
      remove — stop watching a directory

    The default watched directory is ~/Library/Application Support/SpliceKit/lua/.
    Save .lua files to the auto/ subdirectory and they execute automatically on every save.
    """
    return _call_or_error("lua.watch", action=action, path=path)


@splicekit_tool("lua_state", READ, title="Get Lua State")
def lua_state() -> str:
    """Get Lua VM state: memory usage, user-defined globals, watched paths, scripts directory."""
    return _call_or_error("lua.getState")
