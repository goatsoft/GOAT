#!/usr/bin/env python3
"""Stamp the current release version into the one managed doc region, and guard drift.

Single source of truth: apps/goat-macos/release.json. Release docs either point at
https://github.com/goatsoft/GOAT/releases/latest or avoid a version entirely, so the
only mechanical per-release doc surface left is the identity table in
docs/VERSIONING.md (managed here, between stamp markers). The newest section of
docs/RELEASE-NOTES.md is hand written per release; this tool does not touch it.

Usage:
  scripts/stamp-release.py           rewrite the managed table to match release.json
  scripts/stamp-release.py --check   exit 1 if the table drifts, a marker is missing,
                                     or a latest-only doc reintroduces a pinned link
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REC = json.loads((ROOT / "apps/goat-macos/release.json").read_text())
VERSION = REC["version"]
CODENAME = REC["codename"]
TAG = f"v{VERSION}"
DMG = f"GOAT-{VERSION}.dmg"
LABEL = f"{VERSION} ({CODENAME})"

# Managed regions: relative path -> {marker key: replacement inner text}.
MANAGED = {
    "docs/VERSIONING.md": {
        "label": f"`{LABEL}`",
        "title": f"`GOAT {LABEL}`",
        "identity": f"`{VERSION}` / `{TAG}` / `{DMG}`",
    },
}

# Files that must never pin a release version or a versioned download URL; they point
# at /releases/latest instead so they never need a per-release edit.
LATEST_ONLY = [
    "README.md",
    "docs/wiki/FAQ.md",
    "docs/wiki/Home.md",
    "docs/wiki/Getting-Started.md",
    "web/deploy/goatherd-README.md",
]
STRAY = re.compile(r"releases/(?:tag|download)/v\d+\.\d+\.\d+|GOAT-\d+\.\d+\.\d+\.dmg")

MARK = re.compile(r"<!--\s*stamp:(?P<key>[\w-]+)\s*-->.*?<!--\s*/stamp:(?P=key)\s*-->", re.S)


def fill(text: str, values: dict[str, str]) -> str:
    def repl(m: re.Match) -> str:
        key = m.group("key")
        if key not in values:
            raise SystemExit(f"stamp-release: unknown marker key {key!r}")
        return f"<!--stamp:{key}-->{values[key]}<!--/stamp:{key}-->"

    return MARK.sub(repl, text)


def main() -> None:
    check = "--check" in sys.argv[1:]
    problems: list[str] = []
    for rel, values in MANAGED.items():
        path = ROOT / rel
        src = path.read_text()
        present = {m.group("key") for m in MARK.finditer(src)}
        for key in set(values) - present:
            problems.append(f"{rel}: missing stamp marker {key!r}")
        out = fill(src, values)
        if out != src:
            if check:
                problems.append(f"{rel}: identity table is out of sync with release.json ({LABEL})")
            else:
                path.write_text(out)
                print(f"stamped {rel}")
    for rel in LATEST_ONLY:
        for i, line in enumerate((ROOT / rel).read_text().splitlines(), 1):
            if STRAY.search(line):
                problems.append(f"{rel}:{i}: pin a release version; point at /releases/latest instead")
    if problems:
        raise SystemExit("stamp-release:\n  " + "\n  ".join(problems))
    if check:
        print(f"stamp-release: docs consistent with {LABEL}")


if __name__ == "__main__":
    main()
