"""Reject incomplete official signing configuration and incorrectly signed artifacts."""
import argparse
import base64
import binascii
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


REQUIRED = (
    "MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PASSWORD", "CODE_SIGN_IDENTITY",
    "NOTARY_APPLE_ID", "NOTARY_PASSWORD", "APPLE_TEAM_ID",
)


def validate_publisher(identity, team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("APPLE_TEAM_ID must contain ten uppercase letters or digits")
    if not identity.startswith("Developer ID Application: ") or not identity.endswith(f"({team})"):
        raise ValueError("CODE_SIGN_IDENTITY must be a Developer ID Application identity for APPLE_TEAM_ID")


def validate_configuration(env):
    missing = [name for name in REQUIRED if not env.get(name, "").strip()]
    if missing:
        raise ValueError("missing release secrets: " + ", ".join(missing))
    validate_publisher(env["CODE_SIGN_IDENTITY"], env["APPLE_TEAM_ID"])
    try:
        certificate = base64.b64decode("".join(env["MACOS_CERTIFICATE"].split()), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("MACOS_CERTIFICATE must be a base64-encoded PKCS#12 export") from None
    if not certificate:
        raise ValueError("MACOS_CERTIFICATE is empty")


def validate_signature(details, identity, team):
    validate_publisher(identity, team)
    lines = details.splitlines()
    authorities = [line.removeprefix("Authority=") for line in lines if line.startswith("Authority=")]
    if not authorities or authorities[0] != identity or f"TeamIdentifier={team}" not in lines:
        raise ValueError("artifact publisher does not match the approved Developer ID identity")
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", details)
    if not flags or not int(flags[1], 16) & 0x10000:
        raise ValueError("official artifacts require hardened runtime")
    if not any(line.startswith("Timestamp=") and line != "Timestamp=none" for line in lines):
        raise ValueError("official artifacts require a secure timestamp")


def validate_entitlements(data):
    if not data.strip():
        return
    try:
        entitlements = plistlib.loads(data)
    except plistlib.InvalidFileException:
        raise ValueError("artifact entitlements could not be decoded") from None
    if not isinstance(entitlements, dict):
        raise ValueError("artifact entitlements must be a dictionary")
    if entitlements.get("com.apple.security.get-task-allow"):
        raise ValueError("official artifacts must not allow debugger attachment")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path, help="check a signed app or executable")
    args = parser.parse_args()
    try:
        if args.verify:
            subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", "-R", "=anchor apple generic", str(args.verify)],
                check=True, capture_output=True, text=True)
            details = subprocess.run(
                ["codesign", "-d", "--verbose=4", str(args.verify)],
                check=True, capture_output=True, text=True)
            validate_signature(
                details.stderr, os.environ.get("CODE_SIGN_IDENTITY", ""),
                os.environ.get("APPLE_TEAM_ID") or os.environ.get("DEVELOPMENT_TEAM", ""))
            entitlements = subprocess.run(
                ["codesign", "-d", "--entitlements", "-", "--xml", str(args.verify)],
                check=True, capture_output=True)
            validate_entitlements(entitlements.stdout)
        else:
            validate_configuration(os.environ)
    except (ValueError, subprocess.CalledProcessError) as error:
        message = str(error) if isinstance(error, ValueError) else "codesign verification failed"
        print("release signing: " + message, file=sys.stderr)
        return 1
    print("release signing: verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
