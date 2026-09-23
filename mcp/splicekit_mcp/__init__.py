"""SpliceKit MCP Server — the bridge between AI tools and Final Cut Pro.

This is the MCP (Model Context Protocol) server that Claude and other AI tools
talk to. It exposes FCP's entire editing API as MCP tools. Under the hood, each
tool just sends a JSON-RPC request to the SpliceKit dylib running inside FCP's
process (127.0.0.1:9876) and returns the result.

The tools are intentionally verbose in their docstrings because that's what the
AI model sees when deciding which tool to use and how to call it.

Layout: sdk (the MCP SDK import), config, images, app (the MCPServer `mcp`),
registry (annotations and @splicekit_tool), bridge (the JSON-RPC connection),
parsing, otio_fcpxml, tools/ (one module per area), resources, prompts, and main
(imports all of it in order and starts the server). mcp/server.py launches it.
"""
