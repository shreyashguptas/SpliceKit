#!/usr/bin/env python3
"""Offline check that spine.reorder (behind move_clips) runs inside FCP's own edit
transaction instead of a hand-made NSUndoManager entry.

The hand-made entry had two faults seen live: its redo registered nothing, so a second
undo was an empty "Shuffle Clips" step; and it rebuilt the spine without the model write
lock, so FCP's background render tracker read it mid-rebuild and FCP aborted. Inside
actionBegin: / actionEnd:save:error: FCP holds the lock and records the change itself."""
import re
import unittest
from pathlib import Path

SPINE = Path(__file__).resolve().parents[1] / "Sources" / "Bridge" / "SpliceKitServerSpine.m"


class SpineReorderUndoTests(unittest.TestCase):
    def setUp(self):
        source = SPINE.read_text(encoding="utf-8")
        handler = re.search(r"NSDictionary \*SpliceKit_handleSpineReorder\(NSDictionary \*params\) \{(?P<body>.*?)\n\}\n",
                            source, re.DOTALL)
        self.assertIsNotNone(handler, "SpliceKit_handleSpineReorder is gone")
        self.source = source
        self.body = handler.group("body")

    def test_reorder_runs_in_one_fcp_edit_transaction(self):
        self.assertIn('NSString *undoName = @"Shuffle Clips";', self.body)
        self.assertIn("SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoName)", self.body)
        self.assertIn("SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoName, openedUndoGroup)", self.body)
        begin = self.body.index("SpliceKit_internalBeginEditGroupIfNeeded")
        apply = self.body.index("SpliceKit_applySpineOrder(spine, newClips)")
        end = self.body.index("SpliceKit_internalEndEditGroupIfOpened")
        self.assertLess(begin, apply)
        self.assertLess(apply, end)
        # The transaction is closed even when the rebuild raises.
        self.assertRegex(self.body[apply:end], r"\}\s*@finally\s*\{\s*$")

    def test_no_hand_made_undo(self):
        self.assertNotIn("registerUndoWithTarget:", self.source)
        self.assertNotIn("SpliceKit_getUndoManager()", self.body)


if __name__ == "__main__":
    unittest.main()
