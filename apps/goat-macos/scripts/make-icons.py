#!/usr/bin/env python3
"""Generate GOAT's app icons from the square source art in art/.

Applies a continuous-corner ("squircle") alpha mask (the macOS icon shape) so the
full-bleed square source reads as a proper rounded icon in the Dock. Produces:

  * App/Assets.xcassets/AppIcon.appiconset  ← the default bundle icon (from art/icon.png)
  * App/Assets.xcassets/AppIconGlyphOriginal.imageset  ← for the settings picker
  * App/Assets.xcassets/AppIconGlyphV.imageset         ← the alternate, also used at runtime

Re-run after changing the source art:  python3 scripts/make-icons.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art"
ASSETS = ROOT / "App" / "Assets.xcassets"

SQUIRCLE_N = 5.0  # exponent of the superellipse; ~5 matches Apple's icon curvature
SUPERSAMPLE = 4  # render the mask big, then downscale for a smooth antialiased edge


def squircle_mask(size: int) -> Image.Image:
    """A full-bleed superellipse alpha mask (0–255) at the given pixel size."""
    hi = size * SUPERSAMPLE
    axis = (np.arange(hi) + 0.5) / hi * 2.0 - 1.0  # centre of each pixel in [-1, 1]
    x, y = np.meshgrid(axis, axis)
    inside = (np.abs(x) ** SQUIRCLE_N + np.abs(y) ** SQUIRCLE_N) <= 1.0
    big = Image.fromarray((inside * 255).astype("uint8"), mode="L")
    return big.resize((size, size), Image.LANCZOS)


def render(source: Path, size: int, pad: float = 0.0) -> Image.Image:
    """Source art masked to the squircle shape, optionally inset by `pad` (fraction per side) so
    art with its own near-edge frame gets a transparent margin instead of clipping at the corners."""
    inner = round(size * (1 - 2 * pad))
    art = Image.open(source).convert("RGBA").resize((inner, inner), Image.LANCZOS)
    art.putalpha(squircle_mask(inner))  # round the art's own corners
    if inner == size:
        return art
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    canvas.paste(art, (off, off))
    return canvas


def write_appiconset(source: Path) -> None:
    out = ASSETS / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    # (filename, pixel size): the standard mac idiom set, 16→512 at 1x and 2x.
    sizes = {
        "icon_16.png": 16, "icon_16@2x.png": 32,
        "icon_32.png": 32, "icon_32@2x.png": 64,
        "icon_128.png": 128, "icon_128@2x.png": 256,
        "icon_256.png": 256, "icon_256@2x.png": 512,
        "icon_512.png": 512, "icon_512@2x.png": 1024,
    }
    for name, px in sizes.items():
        render(source, px).save(out / name)
    images = []
    for base, scale in [(16, "1x"), (16, "2x"), (32, "1x"), (32, "2x"),
                        (128, "1x"), (128, "2x"), (256, "1x"), (256, "2x"),
                        (512, "1x"), (512, "2x")]:
        suffix = "@2x" if scale == "2x" else ""
        images.append({"filename": f"icon_{base}{suffix}.png", "idiom": "mac",
                       "scale": scale, "size": f"{base}x{base}"})
    (out / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def write_imageset(name: str, source: Path, pad: float = 0.0) -> None:
    out = ASSETS / f"{name}.imageset"
    out.mkdir(parents=True, exist_ok=True)
    render(source, 512, pad).save(out / f"{name}.png")
    render(source, 1024, pad).save(out / f"{name}@2x.png")
    images = [
        {"filename": f"{name}.png", "idiom": "universal", "scale": "1x"},
        {"filename": f"{name}@2x.png", "idiom": "universal", "scale": "2x"},
    ]
    (out / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main() -> None:
    write_appiconset(ART / "icon.png")
    # Small inset so variants whose art has a near-edge frame get a transparent margin, not a clip.
    write_imageset("AppIconGlyphOriginal", ART / "icon.png", pad=0.05)
    write_imageset("AppIconGlyphV", ART / "icon-v.png", pad=0.05)
    write_imageset("AppIconGlyphLight", ART / "icon-light.png", pad=0.05)
    write_imageset("AppIconGlyphDark", ART / "icon-dark.png", pad=0.05)
    print("Icons generated → App/Assets.xcassets")


if __name__ == "__main__":
    main()
