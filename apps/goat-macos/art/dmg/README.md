# Finder installer theme

These are the owner's final GOAT DMG exports, used without repainting or regenerating the artwork. They are Brand Assets under [LICENSE-ART.md](../../../../LICENSE-ART.md).

| Asset | Pixels | Use |
| --- | --- | --- |
| `goat-dmg-background.png` | 720 x 480 | Standard-resolution representation |
| `goat-dmg-background@2x.png` | 1440 x 960 | Retina representation |

Packaging combines the original pixels into a two-representation TIFF using macOS `sips` and `tiffutil`. The Retina representation is assigned 144 DPI so Finder uses a 720 x 480-point canvas. No image-generation service, font download or Python imaging dependency is required.

## Layout

GOAT.app and the Applications shortcut have 96-point icons centred at (215, 235) and (505, 235). The native artwork for the optional CLI Tools and Licence folders is 48 points, centred at (520, 425) and (630, 425). Finder only supports one icon size per window: the footer icons use transparent padding inside a 96-point footprint, with item anchors at Y = 401. This keeps the artwork at the supplied coordinates and the filenames inside the canvas. CLI Tools contains the unchanged, signed `goat` executable. Licence contains the existing distribution notices.

The saved window hides its toolbar, sidebar, status bar and tab bar. Finder's 32-point title bar adds to the 480-point canvas. Packaging requires Finder in a logged-in macOS session and permission for the packaging terminal to automate Finder. It fails if Finder cannot save a valid layout. The helper changes only the staging volume; it does not change global Finder preferences. Users who enable Show Hidden Files will also see the volume's support files.

## Build identity and source provenance

Both supplied PNGs contain a neutral build capsule. It is decorative and does not identify a build. The volume title includes the actual version, channel and build from validated release metadata; the app and release manifest retain the source fingerprint and complete identity. Never substitute an invented or stale build label into the artwork.

The supplied bundle README referred to `tools/build_dmg_background.py`. That generator was present in the owner's artwork workspace, outside the bundle and this application repository. Its source uses the supplied Midnight base image, local SF Pro/SF Mono fonts and Pillow to render the exports, with a neutral build label by default. The base image and generator are not runtime packaging inputs and are not copied here. Regeneration is an artwork-authoring operation; these final exports are the packaging authority.
