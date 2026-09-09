#!/usr/bin/env python3
"""Check the local release test host, without installing or changing any tools."""
import platform
import subprocess
import sys

if platform.system() != "Darwin" or platform.machine() != "arm64":
    sys.exit("release host: macOS on Apple Silicon is required")
os_version = platform.mac_ver()[0]
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
if int(os_version.split(".")[0]) < 26 or int(sdk.split(".")[0]) < 26:
    sys.exit("release host: macOS 26+ and macOS SDK 26+ are required for app tests")
print(f"Release host: macOS {os_version}, arm64, SDK {sdk}")
