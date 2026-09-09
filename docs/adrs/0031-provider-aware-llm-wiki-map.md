# ADR-0031: Provider-aware LLM Wiki map

**Status:** Accepted · 2026-09-02 · Refines [ADR-0005](0005-memory-architecture.md)

## Context

ADR-0005 established a native, bounded Wiki graph, but the early browser implementations treated
every memory provider as a generic collection of notes. That hid the meaningful differences
between a flat local Markdown store, the LLM Wiki's curated pages plus immutable sources, and
Hindsight's knowledge-page contract. Settings and Pen views also evolved separate graph models,
which made their semantics and visual treatment diverge.

The LLM Wiki is the one local provider that has enough structured authority to earn a richer map:
curated pages have exact wikilinks, and pages can cite immutable sources. The map must reveal that
structure without parsing unbounded Markdown on the main actor, exposing raw source bodies, or
adding a graph dependency.

## Decision

### One provider-aware browser model

Settings and Pens share `MemoryBrowserMode`: **Pages** is always available and **Map** plus
**Connections** are offered only for the active LLM Wiki provider. Markdown (local) remains a
readable Pages surface; Hindsight remains a list/knowledge-page surface. GOAT must not draw a
decorative graph for a provider that cannot supply its links and provenance honestly.

`LLMWikiMemoryStore` provides a bounded graph-material snapshot: curated entry metadata and bodies,
plus immutable-source metadata only. It keeps names and IDs inside the provider boundary so the UI
does not infer meaning from opaque IDs; raw source bodies never enter the map.

### Desktop map and separate Connections view

The shared SwiftUI `Canvas` map renders exact curated `[[safe-name]]` links and immutable source
documents that a page actually cites. Its legend explains the three visuals directly: a circle is a
memory page, a line is a wiki link, and a document tile is a cited source. Hubs and pages that need
attention retain a restrained visual treatment, but those implementation details are not presented
as a user-facing metric.

The graph material is read by the provider actor. A detached, Sendable-only builder validates link
names, sorts deterministically, and runs a bounded deterministic force layout before the
`@MainActor` views render. The Canvas owns a desktop graph viewport: drag the background to pan,
scroll or pinch to zoom around the pointer, right-drag in any direction to rotate, hover a node for detail, and click
it to open the document. While a page is hovered, small dots travel along its linked edges in the
stored source-to-target direction. Zoom controls and labels remain fixed-size. The compact legend
names only node types because link direction is made apparent by the hover animation.
Edges also use bounded focus depth: direct links remain bright, one-hop context softens, and
distant links recede while a page is hovered.

`MemoryGraphInsightsView` is the separate **Connections** tab. It uses Swift Charts `BarMark`s to
compare each page's total page links and source citations. Swift Charts provides the correct native
axes, category spacing, and accessibility for this one-dimensional comparison, but its marks do
not model arbitrary nodes, edges, layout, or a graph camera, so it is not used for the map itself.

### Compact, readable conversation memory

Built-in Memory operations are presented as compact GOAT actions, separate from the technical MCP
tool-card treatment. Empty JSON payloads and redundant completion labels are omitted. Meaningful
raw operation details open in an anchored popover rather than changing the transcript's height;
this keeps the message layout stable. Display titles are bounded and tail-truncated in memory
lists, previews, and map labels.

## Consequences

- The LLM Wiki map shows relations and provenance that users can act on, while Markdown and
  Hindsight do not overclaim equivalent graph support.
- Map construction is deterministic, testable, and stays off the main actor; raw archive material
  remains private to the provider boundary.
- Settings and Pens share one Pages/Map/Connections contract, avoiding separate graph semantics,
  layout, and interaction code.
- The native dependency budget remains flat. Large or malformed content degrades to the bounded
  snapshot rather than a general Markdown or graph-engine parse.

## Alternatives considered

One generic graph for every provider (rejected: visually plausible but semantically dishonest), a
third-party graph package (rejected: extra dependency and a larger interaction surface), a static
radial layout (rejected: it suggests structure the wiki does not have), placing raw source
documents in the graph (rejected: archive bulk is not curated knowledge), and inline expansion of
full memory tool payloads (rejected: it reflows the conversation on every toggle).
