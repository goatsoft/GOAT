# Finder installer theme

The current background and CLI icon were created with the built-in ImageGen tool from the owner's Midnight base and GOAT icon reference. They replace the first circular-layout exports. Source masters retain the generated artwork and transparency; packaging renders the final background locally. These pictures are Brand Assets under [LICENSE-ART.md](../../../../LICENSE-ART.md). The authoring [prompts](PROMPTS.md) are retained for reference; measured export geometry governs Finder placement.

- `goat-dmg-background-source.png`: 3:2 ImageGen landscape with two main squircles, a separated smaller CLI squircle, raised arrow, installation copy and an empty blue build capsule. No optional footer copy or divider.
- `goat-cli-icon.png`: transparent terminal tile in the GOAT icon family. Applied to the CLI Tools folder only, preserving the signed executable inside it.

## Rendering and identity

`dmg-background.swift` reads the actual validated app's Info.plist and fills the light-blue capsule beside the gradient GOAT wordmark with `BUILD <number>` in dark navy native SF Mono. Missing, invalid or oversized build labels fail instead of producing a placeholder. It exports 720 x 480 at 72 DPI and 1440 x 960 at 144 DPI, then macOS `tiffutil` combines both representations for the 720 x 480-point Finder canvas. The image's `build.json`, the volume title, app and release manifest agree on identity. No image service runs during packaging.

## Finder layout

| Item | Finder anchor | Visible icon centre | Icon size |
| --- | --- | --- | --- |
| GOAT.app | (222, 180) | (222, 180) | 96 |
| Applications | (499, 180) | (499, 180) | 96 |
| CLI Tools | (296, 247) | (296, 271) | 48 |
| Licence | (638, 375) | (638, 399) | 48 |
| .background | (532, 375) | (532, 399) | 48 |
| .fseventsd, when present | (426, 375) | (426, 399) | 48 |

Finder only supports one icon size per window. Smaller icons use transparent padding in the 96-point footprint, positioning the artwork 24 points below the anchor and leaving room for filenames. Other hidden support folders, when present, occupy the remaining footer slots to the left. They never cover the header, even with Show Hidden Files enabled. Packaging does not change that global preference.

The CLI recess sits below and to the right of the app recess with a visible gap. Finder retains dark native filename labels over picture backgrounds. Translucent pale-blue pills back the GOAT, CLI Tools and Applications labels for contrast. The installation sentence sits at the bottom centre, below the support-folder row.

The saved window hides its toolbar, sidebar, status bar and tab bar. Finder's 32-point title bar adds to the 480-point canvas. Packaging requires Finder in a logged-in macOS session and permission for the packaging terminal to automate Finder. It refuses an invalid saved layout. Opening the volume in a fresh window uses that geometry; navigation inside an existing Finder window retains that window's chrome.
