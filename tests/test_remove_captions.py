#!/usr/bin/env python3
"""Offline tests for remove_captions MCP tool formatting."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mcp_tool_annotations import load_server_module  # noqa: E402


class RemoveCaptionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = load_server_module()

    def test_dry_run_no_items(self):
        original = self.m.bridge.call

        def fake(method, **params):
            if method == "nativeCaptions.remove":
                return {
                    "status": "ok",
                    "dryRun": True,
                    "native": params.get("native", True),
                    "foundCount": 0,
                    "removedCount": 0,
                    "items": [],
                    "notRemoved": [],
                }
            return original(method, **params)

        self.m.bridge.call = fake
        try:
            out = self.m.remove_captions(dry_run=True)
            self.assertIn("Dry run", out)
            self.assertIn("no native", out)
        finally:
            self.m.bridge.call = original

    def test_removed_count_reported(self):
        original = self.m.bridge.call

        def fake(method, **params):
            if method == "nativeCaptions.remove":
                return {
                    "status": "ok",
                    "dryRun": False,
                    "native": True,
                    "foundCount": 2,
                    "removedCount": 2,
                    "items": [
                        {"displayName": "Cap 1", "text": "hello"},
                        {"displayName": "Cap 2", "text": "world"},
                    ],
                    "notRemoved": [],
                }
            return original(method, **params)

        self.m.bridge.call = fake
        try:
            out = self.m.remove_captions()
            self.assertIn("Removed 2 of 2", out)
            self.assertIn("Remove Captions", out)
        finally:
            self.m.bridge.call = original

    def test_bridge_error_prefix(self):
        original = self.m.bridge.call

        def fake(method, **params):
            if method == "nativeCaptions.remove":
                return {"error": "No sequence in timeline"}
            return original(method, **params)

        self.m.bridge.call = fake
        try:
            out = self.m.remove_captions()
            self.assertTrue(out.startswith("Error: "))
        finally:
            self.m.bridge.call = original


if __name__ == "__main__":
    unittest.main()
