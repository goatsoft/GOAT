#!/usr/bin/env python3
"""Skip macOS verification only when every changed path is known content/web work."""

import json
import os
from pathlib import Path
import subprocess


APP_NOTICE_FILES = {"LICENSE-ART.md", "THIRD-PARTY-NOTICES.md"}
CONTENT_PREFIXES = ("docs/", "web/", "assets/")


def requires_app(paths):
    # Unknown paths, shared notices, build scripts and workflows require the app.
    # Root *.md files are content unless they supply bundled app notices.
    return any(path in APP_NOTICE_FILES or not (
                   ("/" not in path and path.endswith(".md"))
                   or path.startswith(CONTENT_PREFIXES))
               for path in paths)


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def changed_paths(event_name, event):
    if event_name == "pull_request":
        pr = event["pull_request"]
        head = pr["head"]["sha"]
        base = git("merge-base", pr["base"]["sha"], head).decode().strip()
    elif event_name == "push":
        base, head = event["before"], event["after"]
    else:
        raise ValueError("Unsupported event")
    # A missing/new branch baseline cannot establish that only content changed.
    for revision in (base, head):
        if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
            raise ValueError("Invalid commit SHA")
        if revision == "0" * 40:
            raise ValueError("No comparison baseline")
    # Include both sides of renames, including app files moved into docs/.
    raw = git("diff", "--name-only", "--no-renames", "-z", base, head, "--")
    return [os.fsdecode(path) for path in raw.split(b"\0") if path]


def needs_app(event_name, event):
    try:
        return requires_app(changed_paths(event_name, event))
    except (KeyError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot establish a content-only diff ({type(error).__name__}); verifying the app.")
        return True


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    app = needs_app(os.environ["GITHUB_EVENT_NAME"], event)
    value = str(app).lower()
    print(f"App verification required: {value}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"app={value}\n")


if __name__ == "__main__":
    main()
