# ImageGen prompts

## Label alignment refinement

undefined

## Final label contrast and footer refinement

undefined

## Final header refinement

Use case: precise-object-edit. Make ONLY two colour corrections in the top-left branding of this existing 1536x1024 Finder installer background. 1. Restore a strong but tasteful cyan-to-violet horizontal gradient across the actual letter fills of the word 'GOAT', from icy cyan at G through clear blue to lilac/violet at T. The word must no longer be plain white. Preserve the exact GOAT letterforms, bold weight, position and size. 2. Change the small EMPTY rounded build capsule immediately beside GOAT from intense saturated royal blue to a softer lighter sky blue, approximately #66BCF5 with a restrained pale-cyan edge and reduced glow. Keep its exact position, shape and dimensions and leave it completely empty for later build metadata. Preserve the welcome sentence, landscape, both large empty squircle recesses, arrow, the smaller separated CLI recess with its clear gap from the app, the installation sentence and all other pixels and geometry as closely as possible. No added icons, no new words, no label backings, no footer line, no additional edits.

## Final spacing refinement

Use case: precise-object-edit. Edit the provided macOS Finder installer background, keeping the same 1536x1024 canvas and preserving the landscape, header, empty blue build capsule, both large main squircle recesses and arrow exactly. Move ONLY the smaller EMPTY CLI squircle away from the app recess: its new centre must be pixel (627,593) and its size remains 142x138 pixels. Its top edge should be at y524, leaving a clearly visible 22-pixel vertical gap below the main app recess bottom at y502. They must NOT overlap or touch. This is a separate companion tile below and slightly right of the app, with generous breathing room. Erase the previous CLI recess at (592,491), restoring the mountain landscape and completing the main app squircle border where it had overlapped. Move the sentence 'Drag GOAT to Applications.' downward, centre it at pixel (768,747), preserving exact typography and wording. Do not change anything else. No actual app icons or folders, no CLI glyph, no extra text, no footer line, no labels, no panels behind names. Keep the blue capsule empty. The output is background artwork only.

## Final CLI refinement

Precise icon edit: remove only the small horn/GOAT masthead mark above the terminal prompt. Keep the same dark navy squircle tile, luminous cyan-left/violet-right rim, glass treatment and genuinely transparent outer background. Rebalance the existing '>_' terminal prompt so it is centred as the sole large glyph, immediately readable at 48x48 points. Preserve the icon's visual style; no other logo, no words, no tiny decorative marks, no folder, no extra symbols, no perspective. Output one square PNG with true alpha.

## CLI transparency extraction

Use case: background-extraction. Return this exact terminal icon as a transparent PNG cutout. Remove ALL of the grey checkerboard outside the rounded tile; that checkerboard is currently painted pixels and must not appear in the output. Set the entire exterior and corner regions to actual alpha=0, retaining clean antialiased edges around the cyan/violet rim. Do not draw a replacement background, do not draw another checkerboard, do not use solid black or white outside the tile. Preserve every visible part INSIDE the tile, including the large '>_' prompt, the dark navy fill and cyan/violet rim. Do not reintroduce the horn logo or any masthead. True PNG transparency is required.

Generated with the built-in ImageGen tool from the owner-supplied Midnight base. Finder supplies interactive icons; packaging adds the verified build number to the empty blue capsule.

## Initial background

Use case: compositing. Create a production macOS Finder DMG BACKGROUND IMAGE, not a screenshot or app mockup. Output exactly 1440 x 960 pixels (720 x 480 logical points), flat edge-to-edge artwork.
Input image 1 is the editable Midnight landscape base. Preserve its blue-violet horn-shaped aurora, moon, mountain lake and goat silhouette. Input image 2 is ONLY a reference of the previous flawed installer, not an edit target: do not include its window frame, real icons, folders, black filenames or circular landing zones.
Use the base to make a cleaner installer canvas. Move the main installation pair and connecting arrow upward. All coordinates below are LOGICAL POINTS, multiply by 2 for pixels.
Top left: white 'GOAT' wordmark in SF Pro Display Bold at x36 y25, 'Welcome to the herd.' beneath at x37 y67 in SF Pro Text. Immediately beside GOAT, a compact solid luminous blue rounded build capsule, rectangle x148 y31 to245 y52. Leave this capsule entirely EMPTY: packaging will render the verified build number in SF Mono, never paint a placeholder or invented number.
Two empty squircle landing zones, macOS continuous rounded squares, NOT CIRCLES, dark navy glass with a fine restrained cyan/lilac edge: 112 x112 points, centred at (215,205) and (505,205). These are empty recesses for real Finder app/folder icons. They must be large enough for 96-point icons.
One smaller empty squircle 64x64 points centred at (280,276), overlapping and coming off the LOWER RIGHT corner of the left/main app squircle like an attached satellite, for a 48-point CLI icon. Keep this CLI squircle empty too.
One simple slim luminous cyan-to-violet arrow horizontally from (293,205) to (440,205), pointing right. Not from the CLI.
White sentence 'Drag GOAT to Applications.' centred at (360,345), SF Pro Text Semibold. Quiet dark area around this caption.
Remove the entire old OPTIONAL caption, 'CLI tools and licence' text and the horizontal divider. No footer text or line. Leave the entire bottom strip y390-480 uncluttered dark scenery so real support folders can be arranged there, even when hidden files are visible. Retain the goat silhouette at left without crowding the installation icons.
Important: no real app icons, no Applications folder drawing, no CLI icon drawn into the background, no Finder window chrome, no extra words, no watermark, no grids. Only the specified branding, empty blue capsule, three empty SQUIRCLES, arrow and one installation sentence. Crisp native Mac typography and precise 3:2 canvas.

## Geometry refinement

Edit this installer BACKGROUND, preserving the exact landscape, brand header, blank blue build capsule, palette and overall composition. Keep canvas 1536x1024. Make these specific geometry corrections only: enlarge both main EMPTY squircle recesses to 250x250 pixels, centred at pixel (479,386) and (1057,386); their overall corners should read as macOS continuous rounded squares, never circles. Enlarge the attached EMPTY lower-right CLI squircle to 140x140 pixels, centre (606,536), overlapping the main left recess's lower-right corner. Keep the arrow from (615,386) to (923,386). Move the sentence 'Drag GOAT to Applications.' down so its centre is at pixel (768,700), leaving generous space below the CLI zone. Do not add app or folder icons, do not add a CLI icon, do not add any extra captions, footer text, horizontal divider or window chrome. Leave build capsule empty for dynamic verified metadata. Preserve the original landscape and goat without adding objects. This image will be uniformly resampled to a 720x480-point Finder canvas.

## CLI icon

Use case: logo-brand. Create ONE crisp companion GOAT CLI installer icon, a production raster asset on a truly transparent background. Use the provided GOAT app icon as the exact visual-family reference, but make this a distinguishable command-line tool icon, not a second app icon. A dark navy macOS squircle tile with the same restrained cyan-left / violet-right luminous glass edge. Dominant large simple terminal prompt glyph '>_' in crisp icy cyan/white with a violet accent. A very small subtle horn motif may appear above it, but the terminal prompt must be immediately legible at 48x48 points. No folder, no paper, no landscape, no text words, no word CLI, no keyboard, no cursor arrow, no perspective. Tile fills about 90% of the square frame with transparent corners and an even small margin; flat straight-on view. Keep the background genuinely transparent, not black and not a checkerboard. Output 1024x1024 PNG with alpha. This will be the interactive Finder icon on the CLI Tools folder, not painted into the installer background.
