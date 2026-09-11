"""The rendered capsule must follow the actual app bundle, never stale artwork text."""
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest

APP_ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native macOS artwork renderer")
class BackgroundIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory()
        cls.renderer = Path(cls.tools.name) / "dmg-background"
        subprocess.run(["swiftc", str(APP_ROOT / "scripts/dmg-background.swift"),
                        "-o", str(cls.renderer)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def render(self, root, build, source="goat-dmg-background-source.png"):
        app = root / "GOAT.app/Contents"
        app.mkdir(parents=True, exist_ok=True)
        info = {"CFBundleShortVersionString": "0.1.0", "GOATReleaseChannel": "Candidate"}
        if build is not None:
            info["CFBundleVersion"] = build
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        output = root / f"output-{build}"
        result = subprocess.run([str(self.renderer), str(APP_ROOT / "art/dmg" / source),
                                 str(app.parent), str(output)], capture_output=True, text=True)
        return result, output

    def test_changed_bundle_build_updates_both_exports_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outputs = []
            for build in ("1347", "1348"):
                result, output = self.render(root, build)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((output / "build.json").read_text()),
                                 {"build": int(build), "version": "0.1.0", "channel": "Candidate",
                                  "label": f"BUILD {build}"})
                for name, dimensions in (("background.png", (720, 480)),
                                         ("background@2x.png", (1440, 960))):
                    data = (output / name).read_bytes()
                    self.assertEqual(struct.unpack_from(">II", data, 16), dimensions)
                outputs.append(output)
            for name in ("background.png", "background@2x.png"):
                self.assertNotEqual((outputs[0] / name).read_bytes(), (outputs[1] / name).read_bytes())

    def test_missing_or_invalid_build_never_creates_a_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            for build in (None, "unknown", "0"):
                result, output = self.render(Path(directory), build)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_wrong_aspect_ratio_is_rejected_before_export(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.render(Path(directory), "1347", "goat-cli-icon.png")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
