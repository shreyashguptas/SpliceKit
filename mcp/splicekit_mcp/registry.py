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

# The class a tool declares at its decorator: @splicekit_tool("get_timeline_clips", READ).
#   READ              reads state only (read_only_hint, idempotent)
#   LOCAL             changes Final Cut Pro's state but deletes no project content
#   LOCAL_IDEMPOTENT  LOCAL, and calling it twice with the same arguments = calling it once
#   DESTRUCTIVE       can delete or overwrite project content or files (or runs arbitrary code)
READ = "read"
LOCAL = "local"
LOCAL_IDEMPOTENT = "local_idempotent"
DESTRUCTIVE = "destructive"

# Filled in as tools register (splicekit_tool below, plugin tools in tools/plugins.py).
# A partition: every registered tool is in exactly one of the first three sets.
READ_ONLY_TOOLS = set()
DESTRUCTIVE_TOOLS = set()
LOCAL_WRITE_TOOLS = set()
IDEMPOTENT_LOCAL_WRITE_TOOLS = set()
# Titles given at the decorator (title=), for tools whose title is not the automatic one.
CUSTOM_TOOL_TITLES = {}

_CLASS_SETS = {
    READ: (READ_ONLY_TOOLS,),
    LOCAL: (LOCAL_WRITE_TOOLS,),
    LOCAL_IDEMPOTENT: (LOCAL_WRITE_TOOLS, IDEMPOTENT_LOCAL_WRITE_TOOLS),
    DESTRUCTIVE: (DESTRUCTIVE_TOOLS,),
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
        # LOCAL_WRITE_TOOLS. Every tool declares its class at @splicekit_tool, and
        # test_every_registered_tool_is_in_a_classification_set keeps it that way.
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


def splicekit_tool(name: str, tool_class: str, title: str = None):
    """Register a SpliceKit MCP tool under the SDK: `tool_class` (READ / LOCAL /
    LOCAL_IDEMPOTENT / DESTRUCTIVE) decides its annotations and puts it in READ_ONLY_TOOLS /
    LOCAL_WRITE_TOOLS (+ IDEMPOTENT_LOCAL_WRITE_TOOLS) / DESTRUCTIVE_TOOLS; `title` overrides
    the automatic title; the error guard above wraps it. `name` must equal the decorated
    function's name."""
    if tool_class not in _CLASS_SETS:
        raise ValueError(f"splicekit_tool({name!r}): unknown tool class {tool_class!r}")

    def decorator(fn):
        if fn.__name__ != name:
            raise ValueError(f"splicekit_tool({name!r}) applied to {fn.__name__}()")
        if any(name in s for s in (READ_ONLY_TOOLS, LOCAL_WRITE_TOOLS, DESTRUCTIVE_TOOLS)):
            raise ValueError(f"splicekit_tool({name!r}) registered twice")
        for tool_set in _CLASS_SETS[tool_class]:
            tool_set.add(name)
        if title is not None:
            CUSTOM_TOOL_TITLES[name] = title
        return mcp.tool(annotations=_tool_annotations(name))(_guard_tool_errors(fn))

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
