#!/usr/bin/env python3
"""Offline checks that unknown-value errors list accepted values (Part 1)."""

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support.server_loader import purge_package_modules  # noqa: E402


def _load_server_module():
    # A fresh splicekit_mcp package, not one another test built under the fake SDK.
    purge_package_modules()
    spec = importlib.util.spec_from_file_location(
        "splicekit_mcp_server", REPO_ROOT / "mcp" / "server.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["splicekit_mcp_server"] = module
    spec.loader.exec_module(module)
    return module


class PlaybackActionValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = _load_server_module()

    def test_unknown_playback_action_lists_all_valid_names(self):
        with patch.object(self.server.bridge, "call") as bridge_call:
            out = self.server.playback_action("pause")
        bridge_call.assert_not_called()
        self.assertIn("unknown playback action 'pause'", out)
        for name in self.server.PLAYBACK_ACTIONS:
            self.assertIn(name, out)

    def test_docstring_actions_match_validation_tuple(self):
        doc = self.server.playback_action.__doc__ or ""
        for name in self.server.PLAYBACK_ACTIONS:
            self.assertIn(name, doc)


if __name__ == "__main__":
    unittest.main()
