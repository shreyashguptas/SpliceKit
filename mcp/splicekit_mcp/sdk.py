"""The official MCP Python SDK (2.x): import guard, ToolAnnotations, ToolError, Image."""

import sys


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
