"""The installer shortcut must resolve correctly without modifying its destination."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

APP_ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Finder alias support")
class ApplicationsShortcutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory()
        cls.helper = Path(cls.tools.name) / "shortcut"
        subprocess.run(["swiftc", str(APP_ROOT / "scripts/dmg-applications-shortcut.swift"),
                        "-o", str(cls.helper)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def run_helper(self, mode, target, alias):
        args = [str(self.helper), mode, str(target), str(alias)]
        if mode == "create":
            args.append(str(APP_ROOT / "art/dmg/goat-applications-icon.png"))
        return subprocess.run(args, capture_output=True, text=True)

    def icon_attributes(self, path):
        result = {}
        for name in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
            attribute = subprocess.run(["xattr", "-px", name, str(path)], capture_output=True)
            if attribute.returncode == 0:
                result[name] = attribute.stdout
        return result

    def test_custom_icon_belongs_to_movable_alias_and_target_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "destination"
            target.mkdir()
            before = self.icon_attributes(target)
            alias = root / "Applications"
            created = self.run_helper("create", target, alias)
            self.assertEqual(created.returncode, 0, created.stderr)
            self.assertEqual(self.icon_attributes(target), before)
            self.assertFalse(alias.is_symlink())
            self.assertTrue(self.icon_attributes(alias)["com.apple.ResourceFork"])
            moved = root / "moved"
            moved.mkdir()
            alias = alias.rename(moved / "Applications")
            verified = self.run_helper("verify", target, alias)
            self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_existing_symbolic_link_is_never_styled_or_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "destination"
            target.mkdir()
            before = self.icon_attributes(target)
            alias = root / "Applications"
            alias.symlink_to(target, target_is_directory=True)
            self.assertNotEqual(self.run_helper("create", target, alias).returncode, 0)
            self.assertNotEqual(self.run_helper("verify", target, alias).returncode, 0)
            self.assertTrue(alias.is_symlink())
            self.assertEqual(self.icon_attributes(target), before)

    def test_wrong_destination_or_missing_icon_fails_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, wrong = root / "destination", root / "wrong"
            target.mkdir()
            wrong.mkdir()
            alias = root / "Applications"
            self.assertEqual(self.run_helper("create", target, alias).returncode, 0)
            self.assertNotEqual(self.run_helper("verify", wrong, alias).returncode, 0)
            subprocess.run(["xattr", "-d", "com.apple.ResourceFork", str(alias)], check=True)
            self.assertNotEqual(self.run_helper("verify", target, alias).returncode, 0)
