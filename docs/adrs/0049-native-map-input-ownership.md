# ADR-0049: Native map input ownership

**Status:** Accepted · 2026-09-06 · Refines [ADR-0047](0047-native-graph-controls-and-session-charts.md) and [ADR-0048](0048-spatial-memory-and-knowledge-graph.md)

## Context

Click-to-activate combined SwiftUI tap gestures and keyboard focus with a separate native event
monitor. Blank viewport hit testing and focus transitions could prevent activation or clear it
immediately. Custom Records/Map buttons also lacked an explicit full-segment hit area, making
clicks beside their text unreliable.

## Decision

One native NSView responder owns the graph's pointer, trackpad, and keyboard input. Clicking
activates it and makes it first responder. Pointer exit, first-responder resignation, scene
deactivation, or view removal releases it. Inactive scroll events pass up the responder chain;
active scroll, drag, pinch, and right-drag update the existing camera. There are no app-wide event
monitors and no competing SwiftUI focus or gesture state.

Pointer selection and hovering use the same projected coordinates as rendering and choose the
nearest-depth node when targets overlap. Native input receives drags even when they start on a
node. SwiftUI node buttons remain accessibility actions without competing for pointer events.
The active-state badge remains; bottom gesture instructions are removed. The type legend and
graph counts remain visible.

Each Records/Map/Connections button declares a rectangular hit area inside its full-width label,
with a 28-point minimum height. Selection remains local and does not trigger network loading.

## Consequences

- Input ownership has one lifecycle and the inactive graph cannot consume page scrolling.
- Tests exercise actual native responder methods for click activation, scroll forwarding, exit,
  resignation, selection, and reactivation. Live UI checks remain necessary for host hit testing.
- The same behavior applies to Pen, Settings, and expanded graphs without new dependencies.

## Alternatives considered

More flags or delayed retries around SwiftUI focus would preserve competing state owners. An
always-active wheel monitor would restore interaction by breaking page scrolling again.
