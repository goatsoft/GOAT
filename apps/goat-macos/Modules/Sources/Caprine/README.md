# Caprine

Themes, colour rendering and reusable visual primitives.

Public seams: `Caprine`, `ThemeSpec`, `ThemeStore`, `ThemeCatalog`.

Dependencies: Herd, Pens.

Theme files are bounded local data; font declarations never download assets.

Validation: ThemeFontTests, theme persistence tests, ReadingFontTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
