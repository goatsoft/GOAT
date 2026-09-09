#!/usr/bin/env python3
"""Validate release identity and the actual bundle. Standard library only; no network."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

APP_ROOT = Path(__file__).resolve().parents[1]
ROOT = APP_ROOT.parents[1]
RECORD = APP_ROOT / "release.json"
CODENAMES = {"Kid", "Yearling", "Billy", "Nanny", "Wether", "Ram", "Capra", "Ibex", "Markhor", "Tur"}
SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def validate(record):
    if set(record) != {"version", "codename", "build"}:
        raise ValueError("release record must contain exactly version, codename and build")
    if not isinstance(record["version"], str) or not re.fullmatch(SEMVER, record["version"]):
        raise ValueError("version must be canonical MAJOR.MINOR.PATCH")
    if not isinstance(record["codename"], str) or record["codename"] not in CODENAMES:
        raise ValueError("codename must be selected from CODENAMES.md")
    if type(record["build"]) is not int or not 0 < record["build"] <= 2147483647:
        raise ValueError("build must be a positive 32-bit integer")
    return record


def progression(current, previous):
    validate(current)
    validate(previous)
    old = tuple(map(int, previous["version"].split(".")))
    new = tuple(map(int, current["version"].split(".")))
    if new < old or current["build"] <= previous["build"]:
        raise ValueError("a new candidate must advance build and cannot regress version")
    if new[:2] == old[:2] and current["codename"] != previous["codename"]:
        raise ValueError("patch candidates must retain the release-line codename")


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args]).decode().rstrip("\n")


def source():
    # Info.plist is an XcodeGen output retained for historical compatibility.
    excluded = "apps/goat-macos/App/Info.plist"
    paths = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths) - {"", excluded}):
        path = ROOT / name
        digest.update(name.encode() + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(str(path.stat().st_mode & 0o111).encode() + b"\0" + hashlib.sha256(path.read_bytes()).digest())
        else:
            digest.update(b"deleted")
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal", "--", ".", f":(exclude){excluded}"))
    return {"source_commit": git("rev-parse", "HEAD"), "source_tree_sha256": digest.hexdigest(), "dirty": dirty}


def label(record):
    version = record["version"]
    if version.endswith(".0"):
        version = version.rsplit(".", 1)[0]
    return f"{version} ({record['codename']})"


def check_overrides(record):
    for key, value in {"MARKETING_VERSION": record["version"], "CURRENT_PROJECT_VERSION": str(record["build"]),
                       "GOAT_CODENAME": record["codename"]}.items():
        if os.environ.get(key) and os.environ[key] != value:
            raise ValueError(f"{key} conflicts with release.json")


def identity(record, channel, tag=None):
    check_overrides(record)
    result = {**record, **source(), "channel": channel, "label": label(record), "tag": f"v{record['version']}"}
    if tag is not None and tag != result["tag"]:
        raise ValueError("tag does not match release.json")
    if channel == "Release":
        if tag != result["tag"] or result["dirty"]:
            raise ValueError("Release requires an explicit matching tag and clean source")
        if git("rev-parse", f"refs/tags/{tag}^{{commit}}") != result["source_commit"]:
            raise ValueError("release tag does not point to HEAD")
    return result


def check_bundle(app, expected):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    fields = {"CFBundleShortVersionString": "version", "CFBundleVersion": "build", "GOATCodename": "codename",
              "GOATReleaseChannel": "channel", "GOATSourceCommit": "source_commit",
              "GOATSourceTreeSHA256": "source_tree_sha256", "GOATSourceDirty": "dirty"}
    for key, field in fields.items():
        wanted = ("dirty" if expected[field] else "clean") if field == "dirty" else str(expected[field])
        if str(info.get(key)) != wanted:
            raise ValueError(f"bundle {key} mismatch: expected {wanted}, found {info.get(key)!r}")
    if info.get("CFBundleIdentifier") != "dev.leet.goat":
        raise ValueError("unexpected app bundle identifier")


def check_history(record):
    # Compare the last different record, allowing an unchanged candidate to rebuild.
    for commit in git("log", "--format=%H", "--", "apps/goat-macos/release.json").splitlines():
        previous = json.loads(git("show", f"{commit}:apps/goat-macos/release.json"))
        if previous != record:
            progression(record, previous)
            return
    if record["build"] <= 1337:
        raise ValueError("first managed candidate must exceed the legacy build 1337")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "generate", "bundle", "manifest"])
    parser.add_argument("--channel", choices=["Development", "Candidate", "Release"], default="Development")
    parser.add_argument("--tag")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--previous", type=Path, help="previous distributed release manifest")
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    record = validate(json.loads(RECORD.read_text()))
    check_history(record)
    if args.previous:
        previous = json.loads(args.previous.read_text())
        progression(record, {key: previous[key] for key in ("version", "codename", "build")})
    web = json.loads((ROOT / "web/package.json").read_text())
    if web["version"] != record["version"]:
        raise ValueError("web/package.json version conflicts with release.json")
    data = identity(record, args.channel, args.tag)
    if args.action == "generate":
        settings = {"MARKETING_VERSION": record["version"], "CURRENT_PROJECT_VERSION": str(record["build"]),
                    "GOAT_CODENAME": record["codename"], "GOAT_RELEASE_CHANNEL": args.channel,
                    "GOAT_SOURCE_COMMIT": data["source_commit"], "GOAT_SOURCE_TREE_SHA256": data["source_tree_sha256"],
                    "GOAT_SOURCE_DIRTY": "dirty" if data["dirty"] else "clean"}
        output = APP_ROOT / ".build/release-settings.yml"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({"settings": {"base": settings}}, indent=2) + "\n")
    if args.action in {"bundle", "manifest"}:
        if args.app is None:
            raise ValueError("--app is required")
        check_bundle(args.app, data)
    if args.action == "manifest":
        if not args.dmg or not args.cli or not args.output:
            raise ValueError("manifest requires --dmg, --cli and --output")
        data["artifacts"] = [
            {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}
            for path in (args.dmg, args.cli)
        ]
        args.output.write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"release metadata: {error}")
