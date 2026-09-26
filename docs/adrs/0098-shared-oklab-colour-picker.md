# ADR-0098: Shared OKLab colour picker

**Status:** Proposed · 2026-09-26 · refines [0022](0022-theme-format-and-community-themes.md)

## Context

GOAT owns the SwiftUI OKLabColorPicker package, while its Pen sheet maintains a separate picker. Theme colours currently require JSON editing. Reusing the shared package avoids maintaining a second set of colour-selection controls.

## Decision

Use GOATsoft/OKLabColorPicker 0.1.2, pinned by version and revision in the maintained Xcode project, as an app presentation dependency. It has no transitive dependencies and performs no network requests. The app supplies a writable mode selector for swatches, the wheel, sliders and harmonies; the package renders colour controls.

Keep Pens.OKLCH as the persistence value. Adapt L/C/H directly at the UI boundary without clipping through sRGB. Keep GTF theme slots as opaque #RRGGBB; alpha is not editable and RGBA picker input is stored opaque. Backend modules do not depend on SwiftUI or the picker package.

User themes gain a draft colour editor with Save and Cancel through the existing theme worker. Built-ins remain read-only and must be duplicated. JSON editing remains available. This editor covers existing colour slots; separately authored syntax slots can use the same control when their schema lands.

Version 0.1.2 corrects relativeLuminance to weight linear-light sRGB channels. Future contrast feedback should use the package's shared WCAG utilities. The host supplies mode selection explicitly; customPresets is not consumed by this version's swatch view.

## Consequences

Existing Pen and theme files need no migration. Colour selection stays native and local. The new dependency's MIT notice is bundled. Package upgrades should check conversion round trips, mode selection, keyboard access and Reduce Motion before adoption.

## Alternatives considered

Keeping the custom Pen sliders duplicates our shared package. Replacing persisted values with package types would introduce unnecessary storage coupling. Contrast feedback UI remains a separate follow-up; the corrected shared helpers are available.

## Review refinements

Theme editing holds an unquantized OKLab working value while the popover is open; only the draft hex projection is clipped to sRGB. New Pen selections retain the previous L 0.35–0.92 / C 0–0.30 bounds. These bounds constrain extremes, not guarantee WCAG contrast. Existing stored Pens and their default palette are preserved; package swatches are additional choices and need not contain the initial colour. Saves distinguish successful, superseded/cancelled and failed results.

The adopted 0.1.2 fixes the upstream luminance calculation: #777777 on white is approximately 4.48:1, whereas 0.1.1 computed approximately 2.03:1. Contrast feedback UI remains a follow-up. Do not add a second competing WCAG implementation in the app. The package's Cartesian colour value also cannot retain a preferred hue at exactly zero chroma; that is a separate upstream editing behavior, not fixed by avoiding hex round trips.
