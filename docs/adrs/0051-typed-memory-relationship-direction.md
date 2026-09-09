# ADR-0051: Typed memory relationship direction

**Status:** Accepted · 2026-09-06 · Refines [ADR-0048](0048-spatial-memory-and-knowledge-graph.md) and [ADR-0050](0050-map-zoom-and-connector-motion.md)

## Context and evidence

The decoder discarded Hindsight's `linkType`, merged different relationships on a pair, and animated
every edge from serialized source to target. That ordering does not imply direction for associations.
Hindsight's [retain documentation](https://hindsight.vectorize.io/developer/retain#building-connections)
distinguishes meaning, entity and time-proximity connections from causal relationships. Its
[Constellation overview](https://hindsight.vectorize.io/blog/2026/04/16/constellation-view) uses link-type
colours. GOAT keeps its theme's node-type colours, as requested, while preserving relationship meaning.

Read-only inspection of the configured server on 2026-09-06 confirmed:

- `engine/memory_engine.py:get_graph_data` derives entity pairs from shared entities and observation
  semantic pairs from shared source memories. The serialization order of these pairs is incidental.
- `engine/retain/link_utils.py:create_temporal_links_batch_per_fact` uses absolute time distance and
  creates reciprocal within-batch links. Temporal edges do not assert before/after ordering.
- `engine/causal_links.py` defines canonical `caused_by` plus legacy `causes`, `enables`, `prevents`.
  The writer stores the fact as source and its cause as target for `caused_by`.
- `engine/memories/pg/graph.py:graph_direct_links` preserves stored causal endpoints.
- Knowledge links in GOAT come from saved `reflect_response.based_on` references.

No remote code, bank configuration, or memory records were changed for this investigation.

## Decision

Preserve a typed relationship on every edge. Canonicalize endpoint ordering only for symmetric
associations, deduplicating reciprocal rows of the same type while retaining distinct types.
Unknown server types remain unknown, never defaulting to a wiki link or causal relationship.

| Relationship | Motion | Highlighted connector colour |
|---|---|---|
| Semantic, entity, temporal, co-occurrence | Both ways | Gradient between endpoint node colours |
| Caused by | Stored target (cause) to source (effect) | Cause node |
| Causes, enables, prevents | Stored source to target | Origin node |
| Wiki link or citation | Citing page to linked page or evidence | Citing node |
| Unknown | None | Muted |

Every dot retains its origin node's theme colour throughout travel. Hover takes temporary visual
precedence over the pinned selection, which remains selected for Open. Its card overlays the canvas
rather than taking layout height from it; selecting and clearing nodes cannot resize the projection
or native hit-test surface. A fixed divider separates the legend. Compact node/type counts and
solid/dashed line samples expose accurate tooltip and VoiceOver explanations, including preview
counts and zero-type semantics. Active maps tint other
connections softly; focused connections are stronger and unrelated connections recede. Direction
illustrates the recorded relationship, not a live retrieval trace or network transmission.

An active map with no hovered or selected node stays still and creates no animation timeline.
The animation preview keeps a maximum of 24 dots, deduplicates identical travel paths across
relationship types, keeps association pairs together, and excludes missing endpoints. Existing
activation, scene, Reduce Motion, and animation-setting gates remain. Layout ordering includes
relationship type to remain deterministic after preserving multiple types on the same pair.

## Consequences

Regression tests cover reciprocal deduplication, distinct type retention, reversed caused-by motion,
legacy direction, citation direction, unknown types, focus, missing endpoints and paired dot budgets.
Multiple relationship types can share one curve and its tracers; these dots are not an exhaustive
edge inspector. The Hindsight UI remains the full graph exploration destination.
