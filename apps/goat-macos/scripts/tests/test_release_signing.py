import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("release_signing", Path(__file__).parents[1] / "check-release-signing.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.identity = "Developer ID Application: Test Publisher (ABCDEFGHIJ)"
        self.env = dict.fromkeys(signing.REQUIRED, "test-value")
        self.env.update(CODE_SIGN_IDENTITY=self.identity, APPLE_TEAM_ID="ABCDEFGHIJ",
                        MACOS_CERTIFICATE=base64.b64encode(b"fixture-p12").decode())

    def test_every_secret_is_required_without_disclosing_other_values(self):
        for name in signing.REQUIRED:
            env = {**self.env, name: ""}
            with self.subTest(name=name), self.assertRaises(ValueError) as raised:
                signing.validate_configuration(env)
            self.assertIn(name, str(raised.exception))
            self.assertNotIn("test-value", str(raised.exception))

    def test_only_matching_developer_id_identity_is_accepted(self):
        signing.validate_configuration(self.env)
        for identity in ["-", "Apple Development: Test (ABCDEFGHIJ)",
                         "Developer ID Application: Test (XXXXXXXXXX)"]:
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                signing.validate_configuration({**self.env, "CODE_SIGN_IDENTITY": identity})

    def test_invalid_certificate_encoding_is_rejected(self):
        with self.assertRaises(ValueError):
            signing.validate_configuration({**self.env, "MACOS_CERTIFICATE": "not-base64!"})

    def test_signature_requires_publisher_team_runtime_and_timestamp(self):
        details = (f"Authority={self.identity}\nTeamIdentifier=ABCDEFGHIJ\n"
                   "CodeDirectory flags=0x10000(runtime)\nTimestamp=9 Sep 2026 at 14:00:00\n")
        signing.validate_signature(details, self.identity, "ABCDEFGHIJ")
        for altered in [details.replace("0x10000", "0x0"),
                        details.replace("TeamIdentifier=ABCDEFGHIJ", "TeamIdentifier=XXXXXXXXXX"),
                        details.replace("Authority=Developer ID Application", "Authority=Apple Development"),
                        details.replace("Timestamp=9 Sep 2026 at 14:00:00", "Timestamp=none"),
                        details.replace("Timestamp=9 Sep 2026 at 14:00:00\n", "")]:
            with self.subTest(details=altered), self.assertRaises(ValueError):
                signing.validate_signature(altered, self.identity, "ABCDEFGHIJ")

    def test_official_notarization_cannot_skip_missing_credentials(self):
        env = {key: value for key, value in os.environ.items() if key not in signing.REQUIRED}
        env.update(DMG="unused-fixture.dmg", RELEASE_CHANNEL="Release")
        result = subprocess.run(["bash", str(Path(__file__).parents[1] / "notarize.sh")],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require notarization credentials", result.stderr)
        env["RELEASE_CHANNEL"] = "Candidate"
        result = subprocess.run(["bash", str(Path(__file__).parents[1] / "notarize.sh")],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("skipped", result.stdout)

    def test_release_entitlements_reject_debugger_access(self):
        for entitlements in ({}, {"com.apple.security.get-task-allow": False}):
            signing.validate_entitlements(plistlib.dumps(entitlements))
        signing.validate_entitlements(b"")
        for entitlements in (plistlib.dumps({"com.apple.security.get-task-allow": True}),
                             b"invalid plist", plistlib.dumps(["unexpected"])):
            with self.subTest(entitlements=entitlements), self.assertRaises(ValueError):
                signing.validate_entitlements(entitlements)

    def test_make_keeps_local_and_release_signing_separate(self):
        makefile = Path(__file__).parents[2] / "Makefile"
        with tempfile.TemporaryDirectory() as directory:
            def dry_run(target, *overrides):
                result = subprocess.run(
                    ["make", "-n", "-f", str(makefile), target, *overrides],
                    cwd=directory, check=True, capture_output=True, text=True)
                return result.stdout

            self.assertIn('CODE_SIGN_IDENTITY="-"', dry_run("build"))
            self.assertIn('OTHER_CODE_SIGN_FLAGS=""', dry_run("release"))
            Path(directory, "signing.local.mk").write_text(
                "CODE_SIGN_IDENTITY = development-fingerprint\n"
                f"RELEASE_SIGNING_IDENTITY = {self.identity}\n"
                "DEVELOPMENT_TEAM = ABCDEFGHIJ\n")
            self.assertIn('CODE_SIGN_IDENTITY="development-fingerprint"', dry_run("build"))
            release = dry_run("release")
            self.assertIn(f'CODE_SIGN_IDENTITY="{self.identity}"', release)
            self.assertIn('OTHER_CODE_SIGN_FLAGS="--timestamp"', release)
            self.assertIn('CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', release)
            self.assertNotIn('CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', dry_run("test-app"))
            self.assertIn('CODE_SIGN_STYLE=Manual', release)
            self.assertIn('CODE_SIGN_IDENTITY="-"', dry_run("build", "CODE_SIGN_IDENTITY=-"))
            self.assertIn('OTHER_CODE_SIGN_FLAGS=""',
                          dry_run("release", "RELEASE_SIGNING_IDENTITY=-"))


if __name__ == "__main__":
    unittest.main()
