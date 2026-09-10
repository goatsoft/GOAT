"""Regression coverage for preserving Finder's binary window metadata."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import unittest

spec = importlib.util.spec_from_file_location("dmg_window", Path(__file__).parents[1] / "dmg-window.py")
window = importlib.util.module_from_spec(spec)
spec.loader.exec_module(window)


class FinderWindowTests(unittest.TestCase):
    def fixture(self, **overrides):
        options = {"ShowTabView": True, "ShowToolbar": False, "ShowStatusBar": False,
                   "ShowSidebar": False, "WindowBounds": "{{100, 100}, {720, 512}}", **overrides}
        blob = plistlib.dumps(options, fmt=plistlib.FMT_BINARY, sort_keys=False)
        return b"preserved prefix " + struct.pack(">I", 1) + b"\x00.bwspblob" + struct.pack(">I", len(blob)) + blob + b"preserved suffix"

    def test_tab_bar_patch_preserves_length_and_other_records(self):
        source = self.fixture()
        changed = window.hide_tab_bar(source)
        self.assertEqual(len(changed), len(source))
        self.assertEqual(sum(a != b for a, b in zip(source, changed)), 1)
        self.assertTrue(changed.endswith(b"preserved suffix"))
        window.check_window(changed)
        self.assertEqual(window.hide_tab_bar(changed), changed)

    def test_shared_true_object_does_not_change_another_preference(self):
        with self.assertRaisesRegex(ValueError, "shares another"):
            window.hide_tab_bar(self.fixture(ShowToolbar=True))

    def test_wrong_canvas_and_visible_chrome_fail_validation(self):
        for overrides in ({"WindowBounds": "{{0, 0}, {720, 480}}"}, {"ShowSidebar": True}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                window.check_window(self.fixture(ShowTabView=False, **overrides))

    def test_missing_or_ambiguous_window_record_fails_closed(self):
        for data in (b"", self.fixture() + self.fixture()):
            with self.assertRaises(ValueError):
                window.hide_tab_bar(data)

    def test_hidden_system_folders_cannot_cover_header_or_share_footer_slots(self):
        def position_record(name, x, y):
            blob = struct.pack(">IIII", x, y, 0, 0)
            return (struct.pack(">I", len(name)) + name.encode("utf-16be") + b"Ilocblob"
                    + struct.pack(">I", len(blob)) + blob)

        correct = position_record(".background", 532, 401) + position_record(".fseventsd", 426, 401)
        window.check_hidden_folders(correct, [".background", ".fseventsd"])
        with self.assertRaisesRegex(ValueError, "footer slot"):
            window.check_hidden_folders(position_record(".fseventsd", 264, 64), [".fseventsd"])
        with self.assertRaisesRegex(ValueError, "footer slot"):
            window.check_hidden_folders(position_record(".a", 316, 401) + position_record(".b", 316, 401), [".a", ".b"])
        with self.assertRaises(ValueError):
            window.check_hidden_folders(correct, [".missing"])
