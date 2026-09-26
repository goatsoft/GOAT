# ADR-0098: Shared OKLab colour picker

**Status:** Proposed · 2026-09-26 · refines [0022](0022-theme-format-and-community-themes.md)

## Context

GOAT owns the SwiftUI OKLabColorPicker package, while its Pen sheet maintains a separate picker. Theme colours currently require JSON editing. Reusing the shared package avoids maintaining a second set of colour-selection controls.

## Decision

Use GOATsoft/OKLabColorPicker 0.1.1, pinned by version and revision in the maintained Xcode project, as an app presentation dependency. It has no transitive dependencies and performs no network requests. The app supplies a writable mode selector for swatches, the wheel, sliders and harmonies; the package renders colour controls.

Keep Pens.OKLCH as the persistence value. Adapt L/C/H directly at the UI boundary without clipping through sRGB. Keep GTF theme slots as opaque #RRGGBB; alpha is not editable and RGBA picker input is stored opaque. Backend modules do not depend on SwiftUI or the picker package.

User themes gain a draft colour editor with Save and Cancel through the existing theme worker. Built-ins remain read-only and must be duplicated. JSON editing remains available. This editor covers existing colour slots; separately authored syntax slots can use the same control when their schema lands.

Do not use 0.1.1's contrast helpers for accessibility validation: relativeLuminance currently weights gamma-encoded sRGB rather than linearized channels. The package's colour conversion/picking does not require that helper. The host supplies mode selection explicitly; customPresets is not consumed by this version's swatch view.

## Consequences

Existing Pen and theme files need no migration. Colour selection stays native and local. The new dependency's MIT notice is bundled. Package upgrades should check conversion round trips, mode selection, keyboard access and Reduce Motion before adoption.

## Alternatives considered

Keeping the custom Pen sliders duplicates our shared package. Replacing persisted values with package types would introduce unnecessary storage coupling. Adopting package contrast helpers is deferred until their calculation is corrected upstream.
