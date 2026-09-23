"""Builds the complete server (every tool, resource and prompt) and runs it over stdio."""

from . import tools  # noqa: F401  (registers every tool, in order)
from . import resources  # noqa: F401
from . import prompts  # noqa: F401
from .app import mcp
from .registry import _forbid_unknown_tool_arguments
from .tools.plugins import _register_plugin_tools


_forbid_unknown_tool_arguments()


def main():
    # Plugin tools come from the running Final Cut Pro, so they are asked for only when
    # the server really starts (best-effort: FCP may not be up yet), never on import.
    if _register_plugin_tools(timeout=2.0):
        _forbid_unknown_tool_arguments()
    mcp.run(transport="stdio")
