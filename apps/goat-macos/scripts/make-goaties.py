#!/usr/bin/env python3
"""Regenerate the goatie mascots and the two strut animations from the named art in art/.

Sources (all 384x384, borderless):
  * art/goaties/emoji-NN-<name>.png   the reaction goaties, one pose each
  * art/poop_a/frame-01..12.png       the poop strut: walk (1-4), poop (5-8), look (9-12)
  * art/pronk_a/frame-01..12.png      the pronk strut: walk (1-4), jump (5-8), look (9-12)
  * art/rocket_a/frame-01..12.png     the Climb rocket flight: ahead (1-4), look (5-8), ahead (9-12)

Each maps onto an existing imageset by the names the app already uses (the Goatie enum
and the GoatStrut frame prefixes), so no Swift changes are needed. Art is copied at its
native resolution with no resampling, so the mascots stay crisp; the small on-screen sizes
are a clean downscale that SwiftUI does at draw time.

Re-run after changing the art:  python3 scripts/make-goaties.py
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art"
ASSETS = ROOT / "App" / "Assets.xcassets"

# Reaction goaties: source emoji stem  ->  Goatie enum case (imageset name is goatie-<case>).
# Names track the poses: shocked=surprise, crying=cry, microphone=mic, success=check,
# thumbs-up=thumbsup, and annoyed is the arms-crossed pose the app calls "arms".
GOATIES = {
    "emoji-01-wave": "wave",
    "emoji-02-thumbs-up": "thumbsup",
    "emoji-03-heart": "heart",
    "emoji-04-laugh": "laugh",
    "emoji-05-shocked": "surprise",
    "emoji-06-thinking": "thinking",
    "emoji-07-shrug": "shrug",
    "emoji-08-crying": "cry",
    "emoji-09-annoyed": "arms",
    "emoji-10-sleeping": "sleeping",
    "emoji-11-typing": "typing",
    "emoji-12-headphones": "headphones",
    "emoji-13-microphone": "mic",
    "emoji-14-success": "check",
    "emoji-15-warning": "warning",
    "emoji-16-celebrate": "celebrate",
    "emoji-17-running": "running",
    "emoji-18-folder": "folder",
    "emoji-19-laptop": "laptop",
    "emoji-20-rocket": "rocket",
}

# Strut animations: 12 ordered frames -> the phase imagesets GoatStrut plays.
# walk = frames 1-4, act (poop / jump) = 5-8, look = 9-12.
POOP_PHASES = [f"gwalk{i}" for i in range(4)] + [f"gpoop{i}" for i in range(4)] + [f"glook{i}" for i in range(4)]
PRONK_PHASES = [f"prwalk{i}" for i in range(4)] + [f"prjump{i}" for i in range(4)] + [f"prlook{i}" for i in range(4)]
# The Climb rocket is 12 distinct frames played once across the flight (ahead / look / ahead).
ROCKET_FRAMES = [f"rocket{i}" for i in range(12)]


def write_single(name: str, source: Path) -> None:
    """Copy `source` into <name>.imageset as a single 1x image at native resolution."""
    if not source.exists():
        raise FileNotFoundError(source)
    out = ASSETS / f"{name}.imageset"
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, out / f"{name}.png")
    (out / "Contents.json").write_text(
        json.dumps({"images": [{"idiom": "universal", "filename": f"{name}.png", "scale": "1x"}],
                    "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main() -> None:
    for stem, case in GOATIES.items():
        write_single(f"goatie-{case}", ART / "goaties" / f"{stem}.png")
    frame_sets = [("poop_a", POOP_PHASES), ("pronk_a", PRONK_PHASES), ("rocket_a", ROCKET_FRAMES)]
    for folder, names in frame_sets:
        for i, name in enumerate(names, start=1):
            write_single(name, ART / folder / f"frame-{i:02d}.png")
    n_frames = sum(len(names) for _, names in frame_sets)
    print(f"Goaties + animations generated to App/Assets.xcassets "
          f"({len(GOATIES)} goaties, {n_frames} animation frames)")


if __name__ == "__main__":
    main()
