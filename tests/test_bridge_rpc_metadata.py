#!/usr/bin/env python3
"""SpliceKitRPCTable.def is the one list of built-in RPC methods.

Each row names a method, its handler and its bridge.describe metadata. The dispatcher
(SpliceKitServer.m) and sBuiltinMetadata (SpliceKitBridgeMetadata.m) are both built
from it, so these checks guard the table itself and the few methods the dispatcher
handles explicitly (rows with a NULL handler).
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
TABLE = SOURCES / "Bridge" / "SpliceKitRPCTable.def"
SERVER = SOURCES / "Bridge" / "SpliceKitServer.m"
METADATA = SOURCES / "Bridge" / "SpliceKitBridgeMetadata.m"

ROW_RE = re.compile(
    r'^SK_RPC\("([^"]+)",\s*(\w+),\s*@"([^"]+)",\s*@"((?:[^"\\]|\\.)*)"\)\s*$')
SAFETY_TAGS = {"safe", "state_dependent", "modal", "destructive", "system"}
EXPLICIT_RE = re.compile(r'\[method isEqualToString:@"([^"]+)"\]')
PREFIX_RE = re.compile(r'\[method hasPrefix:@"([^"]+)"\]')
INCLUDE = '#include "SpliceKitRPCTable.def"'


def table_rows(text: str) -> list[tuple[str, str, str, str]]:
    rows = []
    for line in text.splitlines():
        if line.startswith("SK_RPC("):
            m = ROW_RE.match(line)
            if not m:
                raise AssertionError(f"malformed row in {TABLE.name}: {line}")
            rows.append(m.groups())
    return rows


def dispatch_section(server: str) -> str:
    """The part of SpliceKit_handleRequest that routes a method to its handler."""
    start = server.index("SpliceKitRPCHandler builtinHandler")
    end = server.index("// Fallthrough: check plugin handler registry", start)
    return server[start:end]


class BridgeRpcTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = table_rows(TABLE.read_text(encoding="utf-8"))
        cls.server = SERVER.read_text(encoding="utf-8")
        cls.names = [r[0] for r in cls.rows]
        cls.null_rows = {r[0] for r in cls.rows if r[1] == "NULL"}
        section = dispatch_section(cls.server)
        cls.explicit = set(EXPLICIT_RE.findall(section))
        cls.prefixes = set(PREFIX_RE.findall(section))
        cls.sources = "\n".join(
            p.read_text(encoding="utf-8", errors="replace")
            for p in SOURCES.rglob("*") if p.suffix in (".m", ".mm"))

    def test_table_is_not_empty(self):
        self.assertGreater(len(self.rows), 150, f"{TABLE.name} rows stopped matching ROW_RE")

    def test_no_duplicate_names(self):
        seen, dupes = set(), set()
        for name in self.names:
            (dupes if name in seen else seen).add(name)
        self.assertEqual(sorted(dupes), [], f"methods listed twice in {TABLE.name}")

    def test_safety_tags_are_known(self):
        bad = sorted(f"{r[0]}={r[2]}" for r in self.rows if r[2] not in SAFETY_TAGS)
        self.assertEqual(bad, [], "unknown safety tag (see SpliceKitBridgeMetadata.m)")

    def test_every_handler_is_defined(self):
        missing = []
        for name, handler, _, _ in self.rows:
            if handler == "NULL":
                continue
            pattern = re.compile(
                r'^NSDictionary\s*\*\s*' + re.escape(handler)
                + r'\s*\(\s*(?:__unused\s+)?NSDictionary\s*\*\s*\w+\s*\)\s*\{', re.M)
            if not pattern.search(self.sources):
                missing.append(f"{name} -> {handler}")
        self.assertEqual(missing, [], "handlers named in the table but not defined in Sources/")

    def test_null_rows_are_the_explicit_dispatch_cases(self):
        # A NULL row is only metadata: the dispatcher must route it itself. And an
        # explicit branch for a method whose row has a handler would be a second,
        # divergent route for the same name.
        self.assertEqual(
            sorted(self.null_rows), sorted(self.explicit),
            "NULL-handler rows must be exactly the methods SpliceKit_handleRequest "
            "dispatches explicitly")

    def test_every_explicitly_named_method_has_metadata(self):
        request = self.server[self.server.index("NSDictionary *SpliceKit_handleRequest(NSDictionary *request) {"):
                              self.server.index("#pragma mark - Client Handler")]
        missing = sorted(set(EXPLICIT_RE.findall(request)) - set(self.names))
        self.assertEqual(missing, [], f"methods named in SpliceKit_handleRequest with no {TABLE.name} row")

    def test_prefix_routes_do_not_shadow_rows(self):
        shadowed = sorted(n for n in self.names for p in self.prefixes if n.startswith(p))
        self.assertEqual(shadowed, [], "rows that a prefix route in the dispatcher also matches")

    def test_dispatcher_and_metadata_include_the_table(self):
        self.assertIn(INCLUDE, self.server)
        self.assertIn(INCLUDE, METADATA.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
