#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
MIXER_PANEL = SOURCES / "SpliceKitMixerPanel.m"


def source(path):
    return path.read_text(encoding="utf-8")


def function_body(text, name):
    search_from = 0
    while True:
        start = text.index(name, search_from)
        brace = text.index("{", start)
        semicolon = text.find(";", start, brace)
        if semicolon == -1:
            break
        search_from = start + len(name)

    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise AssertionError(f"Could not find body for {name}")


def server_function_body(name):
    """Body of a bridge function, wherever in Sources/**/*.m it is defined."""
    definition = re.compile(r"^[A-Za-z_][^;{}()\n]*\b" + re.escape(name) + r"\s*\(", re.M)
    for path in sorted(SOURCES.rglob("*.m")):
        text = source(path)
        for match in definition.finditer(text):
            brace = text.find("{", match.end())
            semicolon = text.find(";", match.end())
            if brace != -1 and (semicolon == -1 or brace < semicolon):
                return function_body(text[match.start():], name)
    raise AssertionError(f"Could not find a definition of {name} in {SOURCES}")


class AudioBusStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panel = source(MIXER_PANEL)

    def test_mixer_get_state_only_reconciles_managed_bus_effects_on_target_change(self):
        body = server_function_body("SpliceKit_handleMixerGetState")
        self.assertNotIn("SpliceKit_mixerAdoptExistingBusEffectsForRole(", body)
        self.assertNotIn("SpliceKit_mixerSyncManagedBusEntryState(", body)
        self.assertNotIn("SpliceKit_mixerSetEffectEnabledInStack(", body)
        needs_index = body.index("SpliceKit_mixerManagedBusNeedsReconcile(allClips, scopeKey)")
        reconcile_index = body.index("SpliceKit_mixerReconcileManagedBusEffects(allClips, scopeKey)")
        self.assertLess(needs_index, reconcile_index)

    def test_reconcile_no_longer_mirrors_au_state_on_poll_path(self):
        body = server_function_body("SpliceKit_mixerReconcileManagedBusEffects")
        self.assertNotIn("SpliceKit_mixerSyncManagedBusEntryState(entry)", body)

    def test_effect_enable_helper_is_idempotent(self):
        body = server_function_body("SpliceKit_mixerSetEffectEnabledInStack")
        read_index = body.index("currentEnabled == enabled")
        mutation_index = body.index("actionBegin:animationHint:deferUpdates:")
        self.assertLess(read_index, mutation_index)

    def test_managed_bus_entries_are_scoped_to_current_timeline(self):
        body = server_function_body("SpliceKit_mixerNewManagedBusEntry")
        self.assertIn('@"scopeKey": scopeKey ?: @""', body)
        get_state = server_function_body("SpliceKit_handleMixerGetState")
        self.assertIn("SpliceKit_mixerManagedBusScopeKey(sequence, primaryObj)", get_state)
        self.assertIn("SpliceKit_mixerManagedBusEffectSummariesForRole(role, scopeKey)", get_state)

    def test_mixer_get_state_supports_twelve_role_stress_fixture(self):
        get_state = server_function_body("SpliceKit_handleMixerGetState")
        self.assertNotIn("faderIdx >= 10", get_state)
        self.assertIn("params[@\"maxFaders\"]", get_state)
        self.assertIn(": 12", get_state)
        self.assertIn("@\"maxFaders\": @(maxFaders)", get_state)

        self.assertIn("kSpliceKitMixerMaxFaders = 12", self.panel)
        self.assertNotIn("Create 10 faders", self.panel)
        self.assertNotIn("for (NSInteger i = 0; i < 10", self.panel)

    def test_managed_bus_roles_stay_visible_without_current_role_targets(self):
        get_state = server_function_body("SpliceKit_handleMixerGetState")
        self.assertIn("SpliceKit_mixerAddManagedBusRolesToRoleOrder(roleOrder, scopeKey)", get_state)
        managed_index = get_state.index("if (managedBusEffects.count > 0)")
        raw_index = get_state.index("} else if (busTargets.count > 0)")
        self.assertLess(managed_index, raw_index)

    def test_managed_bus_reconcile_tracks_role_target_membership(self):
        needs = server_function_body("SpliceKit_mixerManagedBusRoleNeedsReconcile")
        self.assertIn("SpliceKit_mixerObjectKeysForBusTargets(busTargets)", needs)
        self.assertIn("SpliceKit_mixerObjectKeysForManagedEntry(entry)", needs)
        self.assertIn("isEqualToSet:currentObjectKeys", needs)
        reconcile = server_function_body("SpliceKit_mixerReconcileManagedBusEffects")
        self.assertIn("SpliceKit_mixerFindManagedEffectOnObject(entry, object", reconcile)

    def test_stale_managed_handles_are_recovered_from_current_bus_targets(self):
        tracked = server_function_body("SpliceKit_mixerTrackedEffectForObject")
        self.assertIn("SpliceKit_mixerFindManagedEffectOnObject", tracked)
        toggle = server_function_body("SpliceKit_handleMixerSetBusEffectEnabled")
        remove = server_function_body("SpliceKit_handleMixerRemoveBusEffect")
        open_editor = server_function_body("SpliceKit_handleMixerOpenBusEffect")
        self.assertIn("SpliceKit_mixerCurrentBusTargetsForManagedEntry", toggle)
        self.assertIn("SpliceKit_mixerCurrentBusTargetsForManagedEntry", remove)
        self.assertIn("SpliceKit_mixerCurrentBusTargetsForManagedEntry", open_editor)

    def test_managed_bus_index_actions_resolve_display_index_before_raw_stack_index(self):
        helper = server_function_body("SpliceKit_mixerManagedBusEntryForRoleDisplayIndex")
        self.assertIn("SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey)", helper)
        self.assertIn("(NSUInteger)displayIndex >= scopedEntries.count", helper)

        for name in (
            "SpliceKit_handleMixerSetBusEffectEnabled",
            "SpliceKit_handleMixerRemoveBusEffect",
            "SpliceKit_handleMixerOpenBusEffect",
        ):
            body = server_function_body(name)
            self.assertIn("SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex", body)

    def test_managed_bus_remove_does_not_use_display_index_as_raw_stack_index(self):
        body = server_function_body("SpliceKit_handleMixerRemoveBusEffect")
        managed_lookup = body.index("SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex")
        raw_lookup = body.index("SpliceKit_mixerEffectAtIndex(stack, effectIndex)")
        self.assertLess(managed_lookup, raw_lookup)

    def test_poll_exception_clears_reentrancy_guard(self):
        body = function_body(self.panel, "pollTimerFired:")
        catch_start = body.index("@catch")
        catch_body = body[catch_start:]
        self.assertIn("self.isPolling = NO;", catch_body)


if __name__ == "__main__":
    unittest.main()
