#!/usr/bin/env python3
"""
SpliceKit MCP Server — the bridge between AI tools and Final Cut Pro.

This is the MCP (Model Context Protocol) server that Claude and other AI tools
talk to. It exposes FCP's entire editing API as MCP tools. Under the hood, each
tool just sends a JSON-RPC request to the SpliceKit dylib running inside FCP's
process (127.0.0.1:9876) and returns the result.

The tools are intentionally verbose in their docstrings because that's what the
AI model sees when deciding which tool to use and how to call it.

This file is the entry point MCP clients launch by path (.mcp.json, the Claude
Desktop config, Scripts/setup-mcp.sh). The server itself is the splicekit_mcp
package beside it; see splicekit_mcp/__init__.py for its layout.
"""

import os
import sys

_MCP_DIR = os.path.dirname(os.path.abspath(__file__))
if _MCP_DIR not in sys.path:
    sys.path.insert(0, _MCP_DIR)

from splicekit_mcp.main import main  # noqa: E402  (builds the server: tools, resources, prompts)


def _reexport_package_names():
    """Bind every name the package's modules define or import here as well, so code that
    loads this file as a module (the offline tests) sees the namespace the single-file
    server had: module.get_timeline_clips, module.bridge, module.mcp, module.READ_ONLY_TOOLS.
    Rebinding a name here changes nothing inside the package; patch the module that
    uses it (tests/support/server_loader.py has a helper for that)."""
    namespace = globals()
    for name, module in sorted(sys.modules.items()):
        if not name.startswith("splicekit_mcp.") or hasattr(module, "__path__"):
            continue
        for key, value in vars(module).items():
            if not key.startswith("__"):
                namespace.setdefault(key, value)


_reexport_package_names()


# MCP over stdio: the client (Claude Desktop, Claude Code, any MCP client) starts this
# file as a subprocess and speaks JSON-RPC on its stdin/stdout. While serving, the SDK
# points fd 1 at stderr so stray prints cannot corrupt the wire.
if __name__ == "__main__":
    main()
