#!/usr/bin/env python3
"""Every JSON-RPC method the MCP server sends must be one the dylib answers.

A renamed or removed ObjC handler otherwise only shows up as "Method not found" in a
live session. The dylib's methods are the keys of sBuiltinMetadata, the dispatch
branches of SpliceKit_handleRequest and the SpliceKit_registerPluginMethod calls;
the server's are the string literals it passes to bridge.call and its wrappers.
Both sides are read from every file under Sources/ and mcp/, so moving code between
files does not break the check.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

OBJC_NAME_RES = (
    re.compile(r'@"([a-zA-Z]+\.[a-zA-Z.]+)":\s*meta\('),
    re.compile(r'\[method isEqualToString:@"([a-zA-Z]+\.[a-zA-Z.]+)"\]'),
    re.compile(r'SpliceKit_registerPluginMethod\(\s*@"([a-zA-Z]+\.[a-zA-Z.]+)"'),
)
# Placeholder names used in docstring examples, not real calls.
DOC_EXAMPLES = {"my.method"}
PY_CALL_RE = re.compile(r'\b(?:bridge\.call|_call_or_error|_call|bridge_tool)\(\s*"([a-zA-Z]+\.[a-zA-Z.]+)"')


def dylib_methods() -> set:
    names = set()
    for path in (REPO_ROOT / "Sources").rglob("*.m*"):
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern in OBJC_NAME_RES:
            names.update(pattern.findall(text))
    return names


def server_methods() -> set:
    names = set()
    for path in (REPO_ROOT / "mcp").rglob("*.py"):
        names.update(PY_CALL_RE.findall(path.read_text(encoding="utf-8")))
    return names - DOC_EXAMPLES


class RpcNameTests(unittest.TestCase):
    def test_server_only_calls_methods_the_dylib_answers(self):
        sent = server_methods()
        self.assertGreater(len(sent), 150, "the call pattern stopped matching; update PY_CALL_RE")
        unknown = sorted(sent - dylib_methods())
        self.assertEqual(unknown, [], f"mcp/ sends RPC methods no handler in Sources/ answers: {unknown}")


if __name__ == "__main__":
    unittest.main()
