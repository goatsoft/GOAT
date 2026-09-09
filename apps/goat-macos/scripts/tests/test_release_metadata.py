import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release_metadata", Path(__file__).parents[1] / "release-metadata.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.record = {"version": "0.1.0", "codename": "Kid", "build": 1338}

    def test_schema_rejects_incomplete_and_noncanonical_records(self):
        bad = [{}, {**self.record, "extra": 1}]
        bad += [{**self.record, "version": version} for version in ["0.1", "v0.1.0", "00.1.0", "0.1.0-rc.1", "0.1.0\n"]]
        bad += [{**self.record, "build": build} for build in [0, -1, True, "1338", 2147483648]]
        bad += [{**self.record, "codename": "Unknown"}]
        for record in bad:
            with self.subTest(record=record), self.assertRaises(ValueError):
                release.validate(record)

    def test_progression_and_patch_codename(self):
        release.progression({**self.record, "build": 1339}, self.record)
        release.progression({"version": "0.2.0", "codename": "Yearling", "build": 1339}, self.record)
        for current in [self.record, {**self.record, "build": 1337},
                        {**self.record, "version": "0.0.9", "build": 1339},
                        {**self.record, "version": "0.1.1", "codename": "Yearling", "build": 1339}]:
            with self.subTest(current=current), self.assertRaises(ValueError):
                release.progression(current, self.record)

    def test_environment_overrides_cannot_create_a_second_identity(self):
        for key in ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "GOAT_CODENAME"]:
            with patch.dict(os.environ, {key: "wrong"}), self.assertRaises(ValueError):
                release.check_overrides(self.record)

    def test_display_only_omits_zero_patch(self):
        self.assertEqual(release.label(self.record), "0.1 (Kid)")
        self.assertEqual(release.label({**self.record, "version": "0.1.1"}), "0.1.1 (Kid)")

    def test_only_clean_matching_tag_at_head_can_be_release(self):
        snapshot = {"source_commit": "abc", "source_tree_sha256": "123", "dirty": False}
        with patch.object(release, "source", return_value=snapshot), patch.object(release, "git", return_value="abc"):
            self.assertEqual(release.identity(self.record, "Release", "v0.1.0")["channel"], "Release")
            for tag in [None, "v0.2.0", "v0.1.0;echo bad"]:
                with self.subTest(tag=tag), self.assertRaises(ValueError):
                    release.identity(self.record, "Release", tag)
            with patch.object(release, "git", return_value="other"), self.assertRaises(ValueError):
                release.identity(self.record, "Release", "v0.1.0")
            with patch.object(release, "source", return_value={**snapshot, "dirty": True}), self.assertRaises(ValueError):
                release.identity(self.record, "Release", "v0.1.0")

    def test_stale_bundle_and_staged_metadata_fail_closed(self):
        expected = {**self.record, "channel": "Candidate", "source_commit": "abc",
                    "source_tree_sha256": "123", "dirty": True}
        good = {"CFBundleIdentifier": "dev.leet.goat", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1338",
                "GOATCodename": "Kid", "GOATReleaseChannel": "Candidate", "GOATSourceCommit": "abc",
                "GOATSourceTreeSHA256": "123", "GOATSourceDirty": "dirty"}
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "GOAT.app"
            (app / "Contents").mkdir(parents=True)
            plist = app / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps(good))
            release.check_bundle(app, expected)
            for field in good:
                with self.subTest(field=field):
                    plist.write_bytes(plistlib.dumps({**good, field: "stale"}))
                    with self.assertRaises(ValueError):
                        release.check_bundle(app, expected)


class SourceIdentityTests(unittest.TestCase):
    def test_content_and_executable_changes_invalidate_same_head(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text("first")

            def git(*args):
                if args[0] == "ls-files":
                    return "main.swift\0apps/goat-macos/App/Info.plist\0"
                if args[0] == "status":
                    return " M main.swift"
                return "same-commit"

            with patch.object(release, "ROOT", root), patch.object(release, "git", side_effect=git):
                first = release.source()
                self.assertEqual(first, release.source())
                source.write_text("second")
                second = release.source()
                self.assertEqual(first["source_commit"], second["source_commit"])
                self.assertNotEqual(first["source_tree_sha256"], second["source_tree_sha256"])
                source.chmod(0o755)
                self.assertNotEqual(second["source_tree_sha256"], release.source()["source_tree_sha256"])

    def test_history_accepts_same_candidate_rebuild_but_rejects_regression(self):
        current = {"version": "0.1.0", "codename": "Kid", "build": 1338}
        with patch.object(release, "git", return_value=""):
            release.check_history(current)
            with self.assertRaises(ValueError):
                release.check_history({**current, "build": 1337})
        with patch.object(release, "git", side_effect=["new\nold", json.dumps(current),
                                                       json.dumps({**current, "build": 1339})]):
            with self.assertRaises(ValueError):
                release.check_history(current)


class DistributionHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("history", Path(__file__).parents[1] / "check-distribution-history.py")
        cls.history = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.history)

    def test_existing_draft_blocks_replacement(self):
        current = {"version": "0.1.0", "codename": "Kid", "build": 1338}
        with self.assertRaises(ValueError):
            self.history.check(current, [{"tag_name": "v0.1.0", "assets": []}], lambda _: {})

    def test_missing_or_mismatched_old_manifest_blocks_new_release(self):
        current = {"version": "0.1.1", "codename": "Kid", "build": 1339}
        with self.assertRaises(ValueError):
            self.history.check(current, [{"tag_name": "v0.1.0", "assets": []}], lambda _: {})
        old = {"tag_name": "v0.1.0", "assets": [{"name": "release-metadata.json", "id": 1}]}
        with self.assertRaises(ValueError):
            self.history.check(current, [old], lambda _: {"version": "0.2.0"})

    def test_new_release_advances_distributed_build(self):
        current = {"version": "0.1.1", "codename": "Kid", "build": 1339}
        old = {"tag_name": "v0.1.0", "assets": [{"name": "release-metadata.json", "id": 1}]}
        manifest = {"version": "0.1.0", "codename": "Kid", "build": 1338, "channel": "Release", "dirty": False}
        self.history.check(current, [old], lambda _: manifest)
        with self.assertRaises(ValueError):
            self.history.check({**current, "build": 1338}, [old], lambda _: manifest)


if __name__ == "__main__":
    unittest.main()
