#!/usr/bin/env python3
import re
import sys
import unittest
from pathlib import Path


# The fake SDK and the loader live in tests/support/server_loader.py; they are imported
# here under their old names because the other test files import them from this module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support.server_loader import (  # noqa: E402,F401
    FakeMCPServer,
    FakeToolAnnotations,
    FakeToolError,
    load_server_module,
    package_module,
    set_package_global,
)
from support.fake_bridge import FakeBridgeMixin  # noqa: E402


# The keys set_inspector_property accepts, which its docstring must name.
INSPECTOR_SET_KEYS = (
    "opacity",
    "positionX",
    "positionY",
    "positionZ",
    "scaleX",
    "scaleY",
    "rotation",
    "anchorX",
    "anchorY",
    "volume",
    "handle:",
)


class MCPToolAnnotationTests(FakeBridgeMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def test_every_registered_tool_has_required_annotations(self):
        required = {"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint", "title"}
        self.assertGreater(len(self.tools), 0)
        for name, tool in self.tools.items():
            self.assertTrue(required.issubset(tool["annotations"]), name)

    def test_every_registered_tool_is_in_a_classification_set(self):
        read_only = self.module.READ_ONLY_TOOLS
        destructive = self.module.DESTRUCTIVE_TOOLS
        local_write = self.module.LOCAL_WRITE_TOOLS
        for name in self.tools:
            classified = name in read_only or name in destructive or name in local_write
            self.assertTrue(
                classified,
                f"{name} is not in READ_ONLY_TOOLS, DESTRUCTIVE_TOOLS, or LOCAL_WRITE_TOOLS",
            )
        self.assertEqual(
            read_only | destructive | local_write,
            set(self.tools.keys()),
            "the three sets together must name exactly the registered tools",
        )
        # A partition, not just a cover: a tool in two sets gets whichever hint the
        # first branch of _tool_annotations happens to test for, which is a silent
        # way to advertise a destructive tool as read-only.
        for left, right, names in (
            (read_only, destructive, "READ_ONLY_TOOLS and DESTRUCTIVE_TOOLS"),
            (read_only, local_write, "READ_ONLY_TOOLS and LOCAL_WRITE_TOOLS"),
            (destructive, local_write, "DESTRUCTIVE_TOOLS and LOCAL_WRITE_TOOLS"),
        ):
            self.assertEqual(left & right, set(), f"tools in both {names}")

    def test_split_tools_are_registered(self):
        expected = {
            "background_render_status",
            "background_render_control",
            "mark_scene_changes",
            "blade_scene_changes",
            "history_action",
            "list_handles",
            "inspect_handle",
            "release_handle",
            "release_all_handles",
            "timeline_navigation_action",
            "timeline_edit_action",
            "timeline_destructive_action",
            "mixer_set_solo",
            "mixer_set_mute",
            "mixer_apply_bus_effect",
            "mixer_open_bus_effect",
            "mixer_set_bus_effect_enabled",
            "mixer_remove_bus_effect",
            "livecam_open",
            "livecam_close",
            "livecam_status",
        }
        self.assertTrue(expected.issubset(self.tools.keys()))

    def test_key_annotation_profiles_match_expected_behavior(self):
        checks = {
            "detect_scene_changes": {"readOnlyHint": True, "destructiveHint": False},
            "background_render_status": {"readOnlyHint": True, "destructiveHint": False},
            "background_render_control": {"readOnlyHint": False, "destructiveHint": False},
            "mark_scene_changes": {"readOnlyHint": False, "destructiveHint": False},
            "blade_scene_changes": {"readOnlyHint": False, "destructiveHint": True},
            "timeline_action": {"readOnlyHint": False, "destructiveHint": True},
            "timeline_navigation_action": {"readOnlyHint": False, "destructiveHint": False},
            "timeline_destructive_action": {"readOnlyHint": False, "destructiveHint": True},
            "history_action": {"readOnlyHint": False, "destructiveHint": True},
            "call_method": {"readOnlyHint": False, "destructiveHint": True},
            "list_handles": {"readOnlyHint": True, "destructiveHint": False},
            "inspect_handle": {"readOnlyHint": True, "destructiveHint": False},
            "release_handle": {"readOnlyHint": False, "destructiveHint": False},
            "release_all_handles": {"readOnlyHint": False, "destructiveHint": False},
            "livecam_open": {"readOnlyHint": False, "destructiveHint": False},
            "livecam_close": {"readOnlyHint": False, "destructiveHint": False},
            "livecam_status": {"readOnlyHint": True, "destructiveHint": False},
        }
        for name, expected in checks.items():
            annotations = self.tools[name]["annotations"]
            for key, value in expected.items():
                self.assertEqual(annotations[key], value, f"{name} {key}")
            self.assertFalse(annotations["openWorldHint"], name)

    def test_scene_split_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            return {"method": method, "params": params}

        calls = self._install_bridge(respond)

        self.module.mark_scene_changes(threshold=0.2, sample_interval=0.25)
        self.module.blade_scene_changes(threshold=0.5, sample_interval=0.1)

        self.assertEqual(
            calls,
            [
                ("scene.detect", {"threshold": 0.2, "action": "markers", "sampleInterval": 0.25}),
                ("scene.detect", {"threshold": 0.5, "action": "blade", "sampleInterval": 0.1}),
            ],
        )

    def test_background_render_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            return {"method": method, "params": params}

        calls = self._install_bridge(respond)

        self.module.background_render_status()
        self.module.background_render_control("hold_off", 2.5)

        self.assertEqual(
            calls,
            [
                ("backgroundRender.status", {}),
                ("backgroundRender.control", {"action": "hold_off", "seconds": 2.5}),
            ],
        )

    def test_mixer_solo_mute_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            if method == "mixer.setSolo":
                return {"ok": True, "role": "Dialogue", "soloed": True, "soloObjectCount": 2}
            if method == "mixer.setMute":
                return {"ok": True, "role": "Music", "muted": False, "roleUIDCount": 1}
            if method == "mixer.openBusEffect":
                return {"ok": True, "role": "Music", "effect": {"name": "Channel EQ"}, "effectIndex": 0}
            if method == "mixer.setBusEffectEnabled":
                return {"ok": True, "role": "Music", "enabled": False, "effectIndex": 0}
            if method == "mixer.removeBusEffect":
                return {"ok": True, "role": "Music", "effectIndex": 0, "busObjectCount": 1}
            return {"ok": True, "role": "Music", "effect": {"name": "Channel EQ"}, "busObjectCount": 1}

        calls = self._install_bridge(respond)

        solo_result = self.module.mixer_set_solo(index=0, mode="exclusive")
        mute_result = self.module.mixer_set_mute(role="Music", mode="unmute")
        bus_result = self.module.mixer_apply_bus_effect(name="Channel EQ", role="Music", dry_run=True)
        open_result = self.module.mixer_open_bus_effect(effect_index=0, role="Music")
        disable_result = self.module.mixer_set_bus_effect_enabled(effect_index=0, enabled=False, role="Music")
        remove_result = self.module.mixer_remove_bus_effect(effect_index=0, role="Music")

        self.assertIn("Dialogue: soloed", solo_result)
        self.assertIn("Music: unmuted", mute_result)
        self.assertIn("Channel EQ -> Music", bus_result)
        self.assertIn("Opened Channel EQ editor", open_result)
        self.assertIn("Music: disabled", disable_result)
        self.assertIn("Removed mixer bus effect 0 from Music", remove_result)
        self.assertEqual(
            calls,
            [
                ("mixer.setSolo", {"mode": "exclusive", "index": 0}),
                ("mixer.setMute", {"mode": "unmute", "role": "Music"}),
                ("mixer.applyBusEffect", {
                    "dryRun": True,
                    "allowObjectFallback": False,
                    "name": "Channel EQ",
                    "role": "Music",
                }),
                ("mixer.openBusEffect", {
                    "effectIndex": 0,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
                ("mixer.setBusEffectEnabled", {
                    "effectIndex": 0,
                    "enabled": False,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
                ("mixer.removeBusEffect", {
                    "effectIndex": 0,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
            ],
        )

    def test_handle_split_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            return {"method": method, "params": params}

        calls = self._install_bridge(respond)

        self.module.list_handles()
        self.module.inspect_handle("obj_7")
        self.module.release_handle("obj_7")
        self.module.release_all_handles()

        self.assertEqual(
            calls,
            [
                ("object.list", {}),
                ("object.get", {"handle": "obj_7"}),
                ("object.release", {"handle": "obj_7"}),
                ("object.release", {"all": True}),
            ],
        )

    def test_timeline_split_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            return {"ok": True}

        calls = self._install_bridge(respond)

        self.module.timeline_navigation_action("nextEdit")
        self.module.timeline_edit_action("addMarker")
        self.module.timeline_destructive_action("blade")
        self.module.history_action("undo")

        self.assertEqual(
            calls,
            [
                ("timeline.action", {"action": "nextEdit"}),
                ("timeline.action", {"action": "addMarker"}),
                ("timeline.action", {"action": "blade"}),
                ("timeline.action", {"action": "undo"}),
            ],
        )

    def test_read_only_scene_tool_rejects_mutating_legacy_actions(self):
        result = self.module.detect_scene_changes(action="markers")
        self.assertIn("read-only", result)

    def test_timeline_split_wrappers_accept_documented_actions(self):
        self._install_bridge(lambda method, params: {"ok": True, "action": params["action"]})

        self.assertIn("ok", self.module.timeline_navigation_action("enableBeatDetection"))
        self.assertIn("ok", self.module.timeline_navigation_action("nextKeyframe"))
        self.assertIn("ok", self.module.timeline_edit_action("addKeyframe"))
        self.assertIn("ok", self.module.timeline_destructive_action("removeAllKeyframesFromClip"))
        self.assertIn("ok", self.module.timeline_edit_action("transcodeMedia"))

    def test_history_actions_are_rejected_by_non_destructive_split(self):
        result = self.module.timeline_edit_action("undo")
        self.assertIn("history_action()", result)

    def test_background_render_control_rejects_invalid_inputs(self):
        self.assertIn("action must be", self.module.background_render_control("pause", 1.0))
        self.assertIn("seconds must be > 0", self.module.background_render_control("hold_off", 0))

    def test_trim_clips_to_beats_forwards_expected_bridge_call(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "half_beat",
                "randomize": True,
                "randomSeed": 99,
                "gridPointCount": 3,
                "gridPreview": [1.0, 1.5, 2.0],
                "planned": 1,
                "applied": 0,
                "source": {"name": "Song", "tempo": 120.0},
                "plan": [
                    {
                        "name": "Clip A",
                        "start": 5.0,
                        "targetEnd": 6.5,
                        "trimAmount": 1.0,
                        "newDuration": 1.5,
                        "status": "planned",
                    }
                ],
            }

        calls = self._install_bridge(respond)

        result = self.module.trim_clips_to_beats(
            grid="half_beat",
            randomize=True,
            random_min_step=2,
            random_max_step=5,
            random_seed=99,
            min_trim_seconds=0.2,
            min_result_duration=0.5,
            source_handle="obj_10",
            target_handles='["obj_11","obj_12"]',
            dry_run=True,
        )

        self.assertIn("Previewing 0/1 planned trims", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.trimClipsToBeats",
                    {
                        "grid": "half_beat",
                        "randomize": True,
                        "randomMinStep": 2,
                        "randomMaxStep": 5,
                        "randomSeed": 99,
                        "dryRun": True,
                        "minTrimSeconds": 0.2,
                        "minResultDuration": 0.5,
                        "sourceHandle": "obj_10",
                        "targetHandles": ["obj_11", "obj_12"],
                        "targetMode": "auto",
                    },
                )
            ],
        )

    def test_trim_clips_to_beats_rejects_invalid_target_handle_json(self):
        result = self.module.trim_clips_to_beats(target_handles="{bad json")
        self.assertIn("Invalid target_handles JSON", result)

    def test_sync_clips_to_song_beats_uses_overlay_shortcut(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "random_half_beat",
                "targetMode": "overlay",
                "randomize": True,
                "randomSeed": 77,
                "gridPointCount": 4,
                "gridPreview": [0.5, 1.0, 1.5],
                "planned": 2,
                "applied": 0,
                "source": {"name": "Song", "tempo": 128.0},
                "plan": [],
            }

        calls = self._install_bridge(respond)

        result = self.module.sync_clips_to_song_beats(
            mode="random_half_beat",
            overlay_only=True,
            random_min_step=2,
            random_max_step=3,
            random_seed=77,
            dry_run=True,
        )

        self.assertIn("targets=overlay", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.trimClipsToBeats",
                    {
                        "grid": "random_half_beat",
                        "targetMode": "overlay",
                        "randomize": True,
                        "randomMinStep": 2,
                        "randomMaxStep": 3,
                        "randomSeed": 77,
                        "dryRun": True,
                    },
                )
            ],
        )

    def test_assemble_random_clips_to_song_beats_forwards_expected_bridge_call(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "bar",
                "projectName": "Beat Cut",
                "randomSeed": 12,
                "segmentCount": 3,
                "assignedClipCount": 2,
                "gapCount": 1,
                "clipPoolCount": 9,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [
                    {"clipName": "Clip A", "timelineStartSeconds": 0.0, "durationSeconds": 1.0, "clipEvent": "Beat Tests", "status": "planned"},
                    {"segmentIndex": 1, "timelineStartSeconds": 1.0, "durationSeconds": 1.0, "status": "gap"},
                ],
            }

        calls = self._install_bridge(respond)

        result = self.module.assemble_random_clips_to_song_beats(
            grid="bar",
            project_name="Beat Cut",
            event_name="Beat Tests",
            clip_handles='["obj_20","obj_21"]',
            source_handle="obj_10",
            segment_min_step=1,
            segment_max_step=3,
            max_segments=12,
            random_seed=12,
            allow_clip_reuse=False,
            include_audio=True,
            dry_run=True,
        )

        self.assertIn("Previewing 2/3 beat segments", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "bar",
                        "projectName": "Beat Cut",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 3,
                        "randomSeed": 12,
                        "allowClipReuse": False,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                        "eventName": "Beat Tests",
                        "clipHandles": ["obj_20", "obj_21"],
                        "sourceHandle": "obj_10",
                        "maxSegments": 12,
                    },
                )
            ],
        )

    def test_assemble_random_clips_to_song_beats_rejects_invalid_clip_handle_json(self):
        result = self.module.assemble_random_clips_to_song_beats(clip_handles="{bad json")
        self.assertIn("Invalid clip_handles JSON", result)

    def test_build_song_cut_maps_aggressive_preset(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "quarter_beat",
                "projectName": "Song Cut Demo",
                "randomSeed": 9,
                "segmentCount": 4,
                "assignedClipCount": 4,
                "gapCount": 0,
                "clipPoolCount": 12,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [],
            }

        calls = self._install_bridge(respond)

        result = self.module.build_song_cut(
            pace="aggressive",
            project_name="Song Cut Demo",
            event_name="Beat Tests",
            source_handle="obj_99",
            max_segments=20,
            random_seed=9,
            dry_run=True,
        )

        self.assertIn("Preset: aggressive", result)
        self.assertIn("Song attached underneath generated primary storyline", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "quarter_beat",
                        "projectName": "Song Cut Demo",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "randomSeed": 9,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                        "eventName": "Beat Tests",
                        "sourceHandle": "obj_99",
                        "maxSegments": 20,
                    },
                )
            ],
        )

    def test_build_song_cut_maps_natural_preset_with_weighted_steps(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "buildMethod": "fcpxml",
                "grid": "half_beat",
                "projectName": "Song Cut Natural",
                "randomSeed": 42,
                "segmentCount": 8,
                "assignedClipCount": 8,
                "gapCount": 0,
                "clipPoolCount": 6,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [],
            }

        calls = self._install_bridge(respond)

        result = self.module.build_song_cut(
            project_name="Song Cut Natural",
            build_mode="fcpxml",
            random_seed=42,
            dry_run=True,
        )

        self.assertIn("Preset: natural", result)
        self.assertIn("Build mode: fcpxml", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "half_beat",
                        "projectName": "Song Cut Natural",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "stepWeights": {"1": 1, "2": 8, "4": 3},
                        "randomSeed": 42,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "fcpxml",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                    },
                )
            ],
        )

    def test_build_song_cut_forwards_sequence_backed_source_and_current_timeline(self):
        def respond(method, params):
            return {
                "status": "ok",
                "dryRun": True,
                "buildMethod": "native",
                "grid": "half_beat",
                "projectName": "Test",
                "randomSeed": 7,
                "segmentCount": 10,
                "assignedClipCount": 10,
                "gapCount": 0,
                "clipPoolCount": 1,
                "source": {"name": "Here We Go", "tempo": 122.0},
                "plan": [],
            }

        calls = self._install_bridge(respond)

        result = self.module.build_song_cut(
            project_name="Ignored",
            source_project_name="Here We Go feat We Lepers - Instrumental by ivywild Song License",
            clip_source_project_name="THE LIONESS - A Kenyan Woman's Unexpected Journey to Photography",
            target_current_timeline=True,
            random_seed=7,
            dry_run=True,
        )

        self.assertIn("Preset: natural", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "half_beat",
                        "projectName": "Ignored",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "stepWeights": {"1": 1, "2": 8, "4": 3},
                        "randomSeed": 7,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": True,
                        "dryRun": True,
                        "sourceProjectName": "Here We Go feat We Lepers - Instrumental by ivywild Song License",
                        "clipSourceProjectName": "THE LIONESS - A Kenyan Woman's Unexpected Journey to Photography",
                    },
                )
            ],
        )

    def test_build_song_cut_rejects_invalid_pace(self):
        result = self.module.build_song_cut(pace="slow")
        self.assertIn('pace must be one of', result)

    def test_livecam_wrappers_forward_expected_bridge_calls(self):
        def respond(method, params):
            return {"method": method, "params": params}

        calls = self._install_bridge(respond)

        self.module.livecam_open()
        self.module.livecam_close()
        self.module.livecam_status()

        self.assertEqual(
            calls,
            [
                ("liveCam.show", {}),
                ("liveCam.hide", {}),
                ("liveCam.status", {}),
            ],
        )

    def test_set_inspector_property_docstring_lists_keys_not_labels(self):
        doc = " ".join((self.module.set_inspector_property.__doc__ or "").split())
        for key in INSPECTOR_SET_KEYS:
            self.assertIn(key, doc)
        self.assertIn("keys like positionX, not inspector labels like Position X", doc)

    def test_beat_sync_blade_count_matches_numbered_cuts(self):
        # Three blade points plus a song end. The end is not a cut; numbering
        # it used to make the list one longer than "Cuts:".
        analysis = {
            "bpm": 120,
            "beatInterval": 0.5,
            "bars": [1.0, 2.0, 3.0],
            "beats": [],
            "drops": [],
            "structure": [
                {"label": "INTRO", "start": 0.0},
                {"label": "VERSE", "start": 2.0},
            ],
            "duration": 4.0,
        }
        set_package_global(self.module, "_run_structure_analyzer", lambda *args, **kwargs: analysis)
        out = self.module.beat_sync_blade("/tmp/song.wav", dry_run=True)

        numbered = re.findall(r"(?m)^\s+(\d+)\.", out)
        count = int(re.search(r"Cuts: (\d+)", out).group(1))
        self.assertEqual(numbered, ["1", "2", "3"])
        self.assertEqual(count, len(numbered))
        end_lines = [line for line in out.splitlines() if "[end]" in line]
        self.assertEqual(end_lines, ["  end    4.00s  (clip: 1.00s)  [end]"])


if __name__ == "__main__":
    unittest.main()
