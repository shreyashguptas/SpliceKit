from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LogiHapticsIntegrationTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_plugin_targets_logi_service_runtime(self):
        project = self.read(
            "plugins/logi-haptics/FCPHapticsPlugin/src/FCPHapticsPlugin.csproj"
        )
        self.assertIn("<TargetFramework>net10.0</TargetFramework>", project)

    def test_native_sources_are_built_and_installed(self):
        sources = self.read("Sources/SOURCES.txt")
        # The install calls live in the launch sequence; search every source file so
        # the test does not depend on which file that code sits in.
        initializer = "\n".join(
            path.read_text(encoding="utf-8") for path in sorted((ROOT / "Sources").rglob("*.m"))
        )
        for filename in ("SpliceKitHapticBridge.m", "SpliceKitHapticSnapEmitters.m"):
            self.assertIn(filename, sources)
        self.assertIn("SpliceKit_installHapticBridge();", initializer)
        self.assertIn("SpliceKit_installHapticSnapEmitters();", initializer)

    def test_event_contract_matches_plugin_and_mappings(self):
        plugin = self.read(
            "plugins/logi-haptics/FCPHapticsPlugin/src/FCPHapticsPlugin.cs"
        )
        definitions = self.read(
            "plugins/logi-haptics/FCPHapticsPlugin/src/package/events/DefaultEventSource.yaml"
        )
        mappings = self.read(
            "plugins/logi-haptics/FCPHapticsPlugin/src/package/events/extra/eventMapping.yaml"
        )
        for event in (
            "viewer_snap",
            "title_drop_snap",
            "trim_limit",
            "jkl_pressure",
            "clip_snap",
            "playhead_snap",
            "unknown",
        ):
            with self.subTest(event=event):
                self.assertIn(event, plugin)
                self.assertIn(event, definitions)
                self.assertIn(event, mappings)


if __name__ == "__main__":
    unittest.main()
