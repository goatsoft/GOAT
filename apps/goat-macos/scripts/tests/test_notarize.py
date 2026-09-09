"""Exercise notarization credential selection and Apple's acceptance requirement."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "notarize.sh"


class NotarizeTests(unittest.TestCase):
    def run_notarize(self, credentials, status="Accepted"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls"
            xcrun = root / "xcrun"
            xcrun.write_text(
                '#!/bin/sh\n'
                'printf "%s\\n" "$*" >> "$NOTARY_TEST_CALLS"\n'
                'if [ "$1" = notarytool ]; then\n'
                '  printf \'{"status":"%s"}\\n\' "$NOTARY_TEST_STATUS"\n'
                'fi\n')
            xcrun.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("NOTARY_") and key != "APPLE_TEAM_ID"}
            env.update(PATH=str(root) + os.pathsep + env["PATH"],
                       DMG=str(root / "GOAT test.dmg"), RELEASE_CHANNEL="Release",
                       NOTARY_TEST_CALLS=str(calls), NOTARY_TEST_STATUS=status)
            env.update(credentials)
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            return result, calls.read_text() if calls.exists() else ""

    def test_keychain_profile_submits_and_validates_ticket(self):
        result, calls = self.run_notarize({"NOTARY_KEYCHAIN_PROFILE": "GOAT-notary"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--keychain-profile GOAT-notary", calls)
        self.assertNotIn("--password", calls)
        self.assertIn("stapler staple", calls)
        self.assertIn("stapler validate", calls)

    def test_ci_credentials_remain_supported(self):
        result, calls = self.run_notarize({
            "NOTARY_APPLE_ID": "publisher@example.test",
            "NOTARY_PASSWORD": "test-only-password", "APPLE_TEAM_ID": "TESTTEAM01"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--apple-id publisher@example.test", calls)
        self.assertIn("--team-id TESTTEAM01", calls)

    def test_rejected_submission_is_never_stapled(self):
        result, calls = self.run_notarize({"NOTARY_KEYCHAIN_PROFILE": "GOAT-notary"}, "Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("stapler", calls)

    def test_release_rejects_missing_or_partial_credentials(self):
        for credentials in ({}, {"NOTARY_APPLE_ID": "publisher@example.test"}):
            with self.subTest(credentials=credentials):
                result, calls = self.run_notarize(credentials)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
