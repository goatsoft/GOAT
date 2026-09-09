# ADR-0048: Spatial memory and knowledge graph

**Status:** Accepted · 2026-09-06 · Refines [ADR-0047](0047-native-graph-controls-and-session-charts.md) and [ADR-0046](0046-scoped-recent-memory-and-hindsight-map.md)

## Context

The prior map rotated a two-dimensional layout with different horizontal and vertical scales,
which distorted its shape when turned. Hindsight's graph endpoint supplies extracted memory units,
not knowledge pages. Its fact types live in `table_rows`, so decoding only node envelopes also
collapsed world facts, experiences, and observations into one visual category.

## Decision

Use a deterministic, bounded three-dimensional force layout, computed off-main. Each node receives
x/y/z coordinates. The camera orbits with independent yaw and pitch, projects perspective with a
single screen scale, and remains outside the normalized graph volume. Nearer nodes draw and hit-test
in front of farther nodes; size and opacity express depth. Depth is layout, not confidence or time.
Right-drag orbits horizontally and vertically, with toolbar/menu alternatives. Click-to-activate,
release-on-leave, plain minus/plus zoom, and fit remain unchanged. No permanent animation loop or
new rendering package is introduced.

Load at most 60 memory units and 20 knowledge pages from the same selected bank. Knowledge uses
`mental-models?detail=full&limit=20`, with a separate 2 MiB response cap. Pages become hexagonal
knowledge nodes. Their saved `reflect_response.based_on` memory and mental-model references supply
citation edges only when both endpoints are loaded. Knowledge citations receive priority within
the existing 480-edge cap. Missing references and response limits mark a partial preview; no
relationships are invented from shared words or tags. A knowledge failure leaves the memory graph
available with an explicit notice. Opening knowledge performs a bounded, bank-checked read of that
page through the existing JUDAS transport and normal document preview.

Decode each memory's fact type from its matching table row (with a node-field fallback for server
variants). Preserve world, experience, observation, opinion, and unknown types. The legend uses
shapes, theme colors, and preview counts, including zero experiences. It describes the loaded
preview, not bank-wide totals. Knowledge is distinguished from observations: the former are curated
mental models; the latter are consolidated extracted memories.

Future transcript retain calls explicitly identify the User and Assistant sections, distinguish
assistant actions/lessons from external user facts, and distinguish plans from completed actions.
No fact_type is forced, existing data is not reclassified, and custom bank missions are unchanged.
Hindsight remains the authority for extraction and consolidation.

## Consequences

- Rotation is a true 3D view change without planar stretching; the renderer stays native and bounded.
- The graph shows knowledge and all supplied memory types with honest provenance and legends.
- A graph refresh adds one read to the already configured Hindsight endpoint, subject to JUDAS.
- Large banks remain previews; full exploration is available through the Hindsight UI.
- Tests cover orbit/depth/aspect invariants, deterministic spatial layout, all fact types,
  knowledge identity/bank validation, missing citations, and payload bounds.

## Alternatives considered

A tilted flat graph would still lack spatial depth. A full SceneKit or external renderer is not
needed for fewer than 100 nodes. Reclassifying memories in GOAT would overwrite server semantics.
Inferring knowledge links from similar text would create unsupported provenance.
