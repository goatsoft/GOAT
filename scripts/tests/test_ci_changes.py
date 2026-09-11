import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("ci_changes", Path(__file__).parents[1] / "ci-changes.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class PathTests(unittest.TestCase):
    def test_any_root_markdown_skips_app(self):
        for path in ["CHANGELOG.md", "PLAN.md", "new-guide.md", "release notes.md"]:
            with self.subTest(path=path):
                self.assertFalse(ci.requires_app([path]))

    def test_root_markdown_rule_does_not_match_nested_or_other_files(self):
        for path in ["apps/goat-macos/README.md", "new-directory/guide.md", "PLAN.md.py"]:
            with self.subTest(path=path):
                self.assertTrue(ci.requires_app([path]))

    def test_content_and_website_only_skip_app(self):
        self.assertFalse(ci.requires_app([
            "README.md", "docs/ROADMAP.md", "assets/logo.svg",
            "web/src/main.ts", "web/package-lock.json",
        ]))

    def test_app_and_shared_build_inputs_require_app(self):
        for path in [
            "apps/goat-macos/App/App.swift", "apps/goat-macos/Package.resolved",
            "apps/goat-macos/art/dmg/background.png", "Makefile",
            "scripts/distribution-notices.py", ".github/workflows/ci.yml",
            "LICENSE", "LICENSE-ART.md", "THIRD-PARTY-NOTICES.md",
            "third-party/distribution-manifest.json", "new-directory/file",
        ]:
            with self.subTest(path=path):
                self.assertTrue(ci.requires_app(["README.md", path]))

    def test_uncertain_comparisons_require_app(self):
        for name, event in [
            ("workflow_dispatch", {}), ("pull_request", {}),
            ("push", {"before": "0" * 40, "after": "a" * 40}),
            ("push", {"before": "missing", "after": "a" * 40}),
            ("push", {"before": "a" * 40, "after": "b" * 40}),
        ]:
            with self.subTest(event=event):
                self.assertTrue(ci.needs_app(name, event))


class GitDiffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(os.chdir, self.previous)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "CI test")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("apps/goat-macos/app.swift", "app\n")
        self.write("README.md", "readme\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.PIPE).decode().strip()

    def write(self, path, text):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "test")
        return self.git("rev-parse", "HEAD")

    def push_needs_app(self, head):
        return ci.needs_app("push", {"before": self.base, "after": head})

    def test_document_add_modify_delete_and_unusual_filename(self):
        Path("README.md").unlink()
        self.write("docs/space and\nnewline.md", "new doc")
        self.assertFalse(self.push_needs_app(self.commit()))

    def test_app_deleted(self):
        Path("apps/goat-macos/app.swift").unlink()
        self.assertTrue(self.push_needs_app(self.commit()))

    def test_new_root_markdown_in_real_diff_skips_app(self):
        self.write("CHANGELOG.md", "new release notes")
        self.assertFalse(self.push_needs_app(self.commit()))

    def test_app_renamed_to_root_markdown_still_requires_app(self):
        Path("apps/goat-macos/app.swift").rename("EXAMPLE.md")
        self.assertTrue(self.push_needs_app(self.commit()))

    def test_app_renamed_into_docs(self):
        Path("docs").mkdir()
        Path("apps/goat-macos/app.swift").rename("docs/example.swift")
        self.assertTrue(self.push_needs_app(self.commit()))

    def test_push_includes_every_commit(self):
        self.write("apps/goat-macos/new.swift", "code")
        self.commit()
        self.write("README.md", "updated")
        self.assertTrue(self.push_needs_app(self.commit()))

    def test_pr_uses_merge_base_not_unrelated_base_changes(self):
        self.git("checkout", "-qb", "docs-change")
        self.write("README.md", "updated")
        head = self.commit()
        self.git("checkout", "-q", "main")
        self.write("apps/goat-macos/new.swift", "unrelated code")
        base = self.commit()
        event = {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}
        self.assertFalse(ci.needs_app("pull_request", event))


if __name__ == "__main__":
    unittest.main()
