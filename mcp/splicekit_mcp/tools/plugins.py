"""Tools: SpliceKit plugins, and registering plugin methods as tools."""

import json

from ..sdk import ToolAnnotations
from ..app import mcp
from ..registry import (
    _forbid_unknown_tool_arguments, _guard_tool_errors, LOCAL_WRITE, LOCAL_WRITE_TOOLS,
    READ_ONLY, READ_ONLY_TOOLS, splicekit_tool,
)
from ..bridge import _call_or_error, _err, _fmt, bridge


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
