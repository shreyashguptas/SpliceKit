#!/usr/bin/env python3
"""Every RPC method dispatched in SpliceKit_handleRequest must have built-in safety metadata."""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER = REPO_ROOT / "Sources" / "SpliceKitServer.m"
METADATA = REPO_ROOT / "Sources" / "SpliceKitBridgeMetadata.m"

METHOD_DISPATCH_RE = re.compile(r'\[method isEqualToString:@"([^"]+)"\]')
METADATA_KEY_RE = re.compile(r'@"([^"]+)":\s*meta\(')


def dispatcher_methods_from_server(source: str) -> set[str]:
    start = source.index("NSDictionary *SpliceKit_handleRequest")
    end = source.index("#pragma mark - Client Handler", start)
    block = source[start:end]
    return set(METHOD_DISPATCH_RE.findall(block))


def metadata_keys_from_table(source: str) -> set[str]:
    return set(METADATA_KEY_RE.findall(source))


class BridgeRpcMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server_source = SERVER.read_text(encoding="utf-8")
        cls.metadata_source = METADATA.read_text(encoding="utf-8")
        cls.dispatch_methods = dispatcher_methods_from_server(cls.server_source)
        cls.table_keys = metadata_keys_from_table(cls.metadata_source)

    def test_every_dispatched_method_has_builtin_metadata(self):
        missing = sorted(self.dispatch_methods - self.table_keys)
        self.assertEqual(
            missing,
            [],
            "RPC methods handled in SpliceKit_handleRequest but missing from "
            f"sBuiltinMetadata in {METADATA.name}: {', '.join(missing)}",
        )

    def test_metadata_table_has_no_orphan_keys(self):
        extra = sorted(self.table_keys - self.dispatch_methods)
        self.assertEqual(
            extra,
            [],
            "sBuiltinMetadata keys with no matching dispatch branch in "
            f"{SERVER.name}: {', '.join(extra)}",
        )


if __name__ == "__main__":
    unittest.main()
