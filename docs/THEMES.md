# GOAT Theme Format (GTF)

GOAT themes are plain JSON: legible, hand-editable, and yours to share. This is the open format
community themes use (ADR-0022). Built-in themes ship in the app and are read-only; **your** themes
live as folders you own.

## Where themes live

```
~/.goat/config/themes/<id>/
  theme.json     # the theme (this document)
  preview.png    # optional preview image (any name; theme.json points at it)
```

One theme is one folder, so a theme is a thing you can zip and hand to someone. In the app,
**Settings → Appearance → Import Theme…** takes a pasted `theme.json`; **Duplicate to Edit** copies a
built-in into an editable theme; **Export** copies a theme's JSON to your clipboard.

System follows the Mac's light or dark appearance. Light, Pasture, Midnight, and community
themes are available in Settings. Community themes are data-only: they cannot supply
executable behavior, sounds, application icons, or copy catalogs.

The unlocked GOAT 1337 theme enables the bundled goaties and playful decorations. Selecting
any other theme turns them off while retaining the unlock. Standard themes use the light or
dark horn masthead. In 1337, the assistant goat waves after a reply, thinks while busy, and
shows a warning pose on failure.

## `theme.json`

```json
{
  "schema": 1,
  "id": "neon-lagoon",
  "name": "Neon Lagoon",
  "author": "you",
  "description": "Teal dusk with a magenta rim.",
  "appearance": "dark",
  "mono": false,
  "fonts": {
    "chat": "system",
    "code": "monospaced"
  },

  "bg": "#0A0B14",
  "surface": "#151726",
  "ink": "#E9ECF5",
  "muted": "#8E95A8",
  "accent": "#3AA0FF",
  "accent2": "#B44BFF",
  "glow": "#7A5CFF",
  "selection": "#3AA0FF",
  "tint": "#3AA0FF",

  "washOpacity": 0.14,
  "bgOpacity": 0.45,
  "intensity": 1.0,

  "preview": "preview.png"
}
```

### Fields

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | Format version. Current: **1**. Themes without a schema remain readable. Saving or exporting writes version 1. |
| `id` | string | Unique slug (`a–z`, `0–9`, `-`). Must not match a reserved built-in ID; the app renames on collision. |
| `name` | string | Display name in the theme picker. |
| `author` | string? | Optional credit. |
| `description` | string? | Optional one-liner. |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | Drives the OS color-scheme hint. `system` follows the OS (Light in light mode, Midnight in dark). |
| `mono` | bool | Legacy metadata. Reading font selection uses `fonts`; interface controls retain native macOS typography. |
| `fonts` | object? | Optional `chat` and `code` font names; see below. |
| `preview` | string? | Preview image filename in the theme's folder. |

### Fonts (GTF v1)

The machine-readable contract is [theme.schema.json](theme.schema.json). Font declarations are optional. Old themes without them keep GOAT's system defaults.

```json
"fonts": {
  "chat": "AvenirNext-Regular",
  "code": "JetBrainsMono-Regular"
}
```

Use a font's **PostScript name**, not its filename or family label. Hover a font in the picker to see its PostScript name. Names are case-sensitive, at most 128 ASCII letters, digits, hyphens, underscores or periods, and cannot begin with a period. System aliases are `system`, `rounded`, `serif`, and `monospaced`; `code` requires a fixed-pitch font and normally uses `monospaced`.

In **Appearance → Fonts**, **Theme default** follows the selected theme for that role. Explicit font choices override the theme; font sizes remain the user's preference. **Reset** restores theme-following and GOAT's default sizes. Applying a theme never overwrites explicit preferences.

Fonts are references only. Do not include font files or download URLs in a theme. If a requested font is absent, or a code font is not monospaced, GOAT uses its built-in system text or system monospace font. Appearance shows the requested name and an installation hint. Users install the font themselves with Font Book, then reopen the picker; no automatic download or installation occurs. Theme authors should list optional font requirements and licensing instructions in their own README. Import, duplicate, save and export preserve declarations even on a Mac without those fonts.

### Colors: `"#RRGGBB"`

| Token | Paints |
|---|---|
| `bg` | Window background |
| `surface` | Cards, panels, composer |
| `ink` | Primary text |
| `muted` | Secondary text |
| `accent` · `accent2` | The theme gradient endpoints (wordmark, highlights) |
| `glow` | Halo / glow color |
| `selection` | Selected-row fill |
| `tint` | Control tint (buttons, switches, focus) |

### Numbers `0.0–1.0` (except `intensity`)

| Token | Effect |
|---|---|
| `washOpacity` | Strength of the ambient colour wash behind content |
| `bgOpacity` | Background material opacity: lower is more translucent |
| `intensity` | Neon intensity multiplier (≈ `0.5–2.0`; `1.0` is neutral) |

The Appearance transparency slider displays a relative strength from **0%** (solid) to
**100%** (maximum transparency). Its clickable **Theme default · 40%** marker restores
the default strength, adding opacity above the theme's `bgOpacity` baseline at 50%. This is a theme-relative control, not a measurement of the
composited window's alpha; dialogs and accessibility settings can add opacity.

## Tips

- Start from a built-in: **Duplicate to Edit**, then tweak; you'll inherit sensible opacities.
- Keep `ink`/`muted` readable against `bg`/`surface`; GOAT doesn't auto-contrast.
- `appearance` only sets the light/dark hint; your hex colors are always used (except `system`).
- Ship a `preview.png` (16:9 reads well) so people can see it before applying.
