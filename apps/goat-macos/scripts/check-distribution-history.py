#!/usr/bin/env python3
"""Read existing GitHub release manifests; fail closed before preparing a new draft."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location("metadata", Path(__file__).with_name("release-metadata.py"))
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)


def check(current, releases, fetch):
    for item in releases:
        tag = item["tag_name"]
        if tag == f"v{current['version']}":
            raise ValueError("a draft or published release already owns this tag; assets will not be replaced")
        if not re.fullmatch("v" + metadata.SEMVER, tag):
            raise ValueError(f"existing noncanonical release {tag!r} needs explicit migration")
        assets = [asset for asset in item["assets"] if asset["name"] == "release-metadata.json"]
        if len(assets) != 1:
            raise ValueError(f"existing release {tag} has no unique release manifest; review its identity first")
        previous = fetch(assets[0]["id"])
        if f"v{previous['version']}" != tag or previous.get("channel") != "Release" or previous.get("dirty") is not False:
            raise ValueError("previous release manifest disagrees with its release")
        metadata.progression(current, {key: previous[key] for key in ("version", "codename", "build")})


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid repository slug")
    current = metadata.validate(json.loads(metadata.RECORD.read_text()))
    pages = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/releases", "--paginate", "--slurp"]))

    def fetch(asset_id):
        if type(asset_id) is not int or asset_id <= 0:
            raise ValueError("invalid release asset id")
        return json.loads(subprocess.check_output([
            "gh", "api", "-H", "Accept: application/octet-stream", f"repos/{repo}/releases/assets/{asset_id}"
        ]))

    check(current, [item for page in pages for item in page], fetch)
    print("Distribution history verified; no existing release assets will be replaced.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"distribution history: {error}")
