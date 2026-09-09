# ADR-0022: An open theme format; built-ins locked; System follows the OS

**Status:** Accepted · 2026-08-30 · refines [ADR-0013](0013-themes-as-data.md)

## Context

ADR-0013 made themes data (`ThemeSpec`) and let users edit a single `~/.goat/config/themes.json`, where an entry whose id matched a built-in **overrode** it. Three problems as we open up: editing built-ins means a bad edit silently breaks a shipped theme (and there's no clean "reset"); a single array file is awkward to share and can't carry a preview image; and the "System" theme rendered raw macOS window colors, so it didn't look like GOAT at all. We want community themes to be a real, shareable thing.

## Decision

**The GOAT Theme Format (GTF)**, documented in [docs/THEMES.md](../THEMES.md), is our own small, versioned JSON. There's no external app-chrome theme standard worth adopting (VS Code themes are editor-token-centric, base16 is 16 terminal colors); our token model already fits. `ThemeSpec` gains optional metadata (`schema`, `author`, `description`, `preview`); colors stay `#RRGGBB` for legibility.

- **Community themes are folders you own:** `~/.goat/config/themes/<id>/theme.json` (+ optional `preview.png`), mirroring Pens (ADR-0019). One theme = one folder = one thing you can zip and share. The app also imports/exports a single pasted `theme.json`.
- **Built-ins are read-only.** They live in code; a user theme whose id collides with a built-in is dropped, never an override. To change a built-in you **Duplicate to Edit** into your own theme. This keeps shipped themes a stable baseline and makes "reset" trivial (delete your copy).
- **System follows the OS by adopting a real theme:** Light in light mode, **Midnight** in dark (not raw `windowBackgroundColor`) so GOAT looks like itself in either mode while still honoring the user's macOS setting.
- The old single `themes.json` is migrated once into folders; built-in overrides in it become suffixed user themes so no work is lost.

The visual theme builder (gradient editor, per-slot swatches via the OKLCH picker, editable live preview) is **Phase 2**; this ADR is the format + storage + locking + the System fix, plus JSON import/edit and preview images.

## Consequences

Themes are now shareable artifacts with previews, built-ins can't be broken, and System is on-brand. Authors have a documented format and a reference (`Export` any built-in). Storage moved from one file to a folder tree; resolution reads built-ins (code) + user folders, never merging the two. Preview images for built-ins ship as bundled assets (`theme-preview-<id>`); user themes carry their own `preview.png`.

## Alternatives considered

Keep the single `themes.json` + a preview field (rejected: previews are loose, sharing means copying an array entry, and built-ins stay overridable), one-file `.goattheme` bundles with base64-embedded previews (rejected: bloated and less hand-editable than a folder; reconsider if a one-file share format is ever demanded), adopt VS Code/base16 (rejected: they model editors/terminals, not app chrome), keep System on macOS window colors (rejected: it never looked like GOAT).
