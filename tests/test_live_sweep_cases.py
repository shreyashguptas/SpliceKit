#!/usr/bin/env python3
"""tests/live/live_tool_sweep.py must have a case for every registered tool.

The sweep refuses to start when a tool has no case, and nothing noticed that until
someone tried to run it against Final Cut Pro. This checks the same thing offline.
"""

import importlib.util
import sys
import unittest
from pathlib import Path

from test_mcp_tool_annotations import load_server_module

SWEEP = Path(__file__).resolve().parent / "live" / "live_tool_sweep.py"


class LiveSweepCaseTests(unittest.TestCase):
    def test_every_tool_has_a_case_and_every_case_a_tool(self):
        try:
            import mcp  # noqa: F401  (the sweep imports the real SDK at module level)
        except ImportError:
            self.skipTest("needs the mcp package (run under the MCP virtualenv)")
        spec = importlib.util.spec_from_file_location("live_tool_sweep_under_test", SWEEP)
        sweep = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = sweep  # its dataclasses look their module up there
        try:
            spec.loader.exec_module(sweep)
        finally:
            sys.modules.pop(spec.name, None)

        tools = {tool["name"] for tool in load_server_module().mcp.tools}
        cases = set(sweep.CASES)
        self.assertEqual(sorted(tools - cases), [], "tools with no case in the live sweep")
        self.assertEqual(sorted(cases - tools), [], "live sweep cases for tools that do not exist")


if __name__ == "__main__":
    unittest.main()
