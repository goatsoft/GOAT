# Caprine

Themes, colour rendering and reusable visual primitives.

Public seams: `Caprine`, `ThemeSpec`, `ThemeStore`, `ThemeCatalog`, `caprineSecondaryMenu(color:)`, `CaprineCompactStepper`.

Dependencies: Herd, Pens.

Theme files are bounded local data; font declarations never download assets.

Validation: CaprineTests covers theme catalogues, storage security and font persistence; hosted Caprine tests cover appearance and font rendering. Run `make test MODULE=Caprine`.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
