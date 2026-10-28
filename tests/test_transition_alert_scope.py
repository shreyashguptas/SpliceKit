#!/usr/bin/env python3
"""The transition alert auto-answer is armed only around the call that adds transitions.

SpliceKit answers Final Cut Pro's "not enough extra media" alert itself while it adds a
transition (a swizzle of -[NSAlert runModal]). Two callers switched that on and never
off again when no alert came, and from then on every NSAlert in Final Cut Pro was
answered without being shown: a timeline delete was silently cancelled. The flag is
now private to SpliceKitFeatureFreezeExtend.m and set only by
SpliceKit_withTransitionAlertAutoAccept, which restores it when its block returns.
"""

import re
import unittest
from pathlib import Path

SOURCES = Path(__file__).resolve().parents[1] / "Sources"
FEATURE = SOURCES / "Features" / "SpliceKitFeatureFreezeExtend.m"


class TestTransitionAlertScope(unittest.TestCase):
    def test_flag_is_private_to_the_feature(self):
        text = FEATURE.read_text()
        self.assertRegex(text, r"(?m)^static BOOL sFreezeExtendPendingAutoAccept = NO;")
        for path in SOURCES.rglob("*.[mh]"):
            if path != FEATURE:
                self.assertNotIn("sFreezeExtendPendingAutoAccept", path.read_text(errors="replace"),
                                 f"{path.relative_to(SOURCES)} touches the auto-answer flag directly")

    def test_flag_is_only_armed_inside_the_scoped_helper(self):
        text = FEATURE.read_text()
        arms = [m.start() for m in re.finditer(r"sFreezeExtendPendingAutoAccept\s*=\s*YES", text)]
        helper = re.search(r"void SpliceKit_withTransitionAlertAutoAccept\(void \(\^block\)\(void\)\) \{"
                           r".*?\n\}\n", text, re.S)
        self.assertIsNotNone(helper)
        self.assertTrue(arms)
        for position in arms:
            self.assertTrue(helper.start() <= position < helper.end(),
                            "the flag is armed outside SpliceKit_withTransitionAlertAutoAccept")
        self.assertIn("@finally", helper.group(0), "the helper must disarm even when its block throws")

    def test_no_caller_arms_without_disarming(self):
        for path in SOURCES.rglob("*.m"):
            self.assertNotIn("SpliceKit_armTransitionAlertAutoAccept", path.read_text(errors="replace"),
                             f"{path.relative_to(SOURCES)} uses the removed one-way arm call")


if __name__ == "__main__":
    unittest.main()
