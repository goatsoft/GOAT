# ADR-0013: Themes are data (`ThemeSpec`), custom themes from `~/.goat`

**Status:** Accepted · 2026-08-30 · Amends the theming clause of [ADR-0002](0002-ui-architecture.md)

## Context

Caprine themes began as a hardcoded `Theme` enum with a giant `switch` producing `Caprine` tokens. JB wanted user-editable custom themes and to edit the builtins. An enum can't be extended at runtime.

## Decision

Themes are now **`ThemeSpec`**, a `Codable` struct (id, name, appearance, mono, colors as `#RRGGBB` strings, wash/bg/intensity numbers), in `ThemeCatalog` (GoatCore). Five builtins (System, Light, Pasture, Midnight, 1337) live in code; **user themes load from `~/.goat/config/themes.json`** (ADR-0009 home). Resolution: builtins first, then file entries. A file entry whose `id` matches a builtin **overrides** it (so builtins are editable), new ids append. `AppModel.theme` resolves a stored `themeID` to a spec; `ThemeSpec` keeps the same `.tokens` / `.colorScheme` / `.isMono` surface the old enum had, so ~30 call sites were untouched.

Editing is done in an **in-app themed JSON editor** (`JSONEditorView`, syntax highlight, line numbers, brace match, live validation), also used for `mcp-servers.json`. "Edit Themes…" seeds the file with all builtins on first open. The picker shows a gradient+swatch preview per theme; an attached preview under the field shows the gradient + square colour swatches.

## Consequences

Custom themes with no code change; builtins overridable; one JSON editor serves themes and MCP config. Colours are strings (JSON-legible) parsed via `Color(hexString:)`. Malformed JSON → file ignored, builtins intact.

## Alternatives considered

Keep the enum + a separate custom-theme list (rejected: two code paths, builtins still uneditable), TOML/YAML (rejected: JSON matches the MCP config story and the editor).
