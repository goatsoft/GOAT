# ADR-0050: Map zoom and connector motion

**Status:** Accepted · 2026-09-06 · Refines [ADR-0047](0047-native-graph-controls-and-session-charts.md) and [ADR-0049](0049-native-map-input-ownership.md)

## Context

The 500% camera ceiling prevented close inspection. Accelerated wheel events could zoom sharply,
and the fixed pan bound could displace the pointer anchor at higher zoom. Selected record actions
also blended into the legend. The renderer replacement had removed connector motion.

## Decision

The shared camera supports 20–2000% zoom. Trackpad pixels and mouse wheel lines have separate
sensitivities, with each event bounded before exponentiation. Pan bounds grow with zoom, preserving
pointer anchoring during close inspection. Toolbar, keyboard, and pinch use the same camera limits.
Fit resets zoom, position, and orbit.

An isolated Canvas overlay draws up to 24 moving connector dots at a maximum of 30 frames per
second. Projected paths are prepared outside the ticking subtree; static topology, labels, native
input, and accessibility targets do not depend on the animation clock. Dots follow the exact
quadratic connector paths and focus narrows them to incident links. They are decorative relationship
tracers, not evidence of live data transfer or causal direction. Motion runs only while the map owns
interaction and its scene is active, respects Reduce Motion and the interface animation setting,
and can be disabled with Animate connections. It performs no layout or network work per frame.

The badge says Map active, the search field says Search, and the selected record uses a tinted,
bordered card with a divider before the legend.

## Consequences

- Scroll bursts cannot overflow the exponential scale or jump directly to an extreme.
- Camera tests cover gradual input, reversibility, bounds, invalid input, and high-zoom anchoring.
- Motion stops when the user leaves the map and introduces no dependency or background polling.
- Live checks still cover native input and presentation, beyond the camera's unit tests.
