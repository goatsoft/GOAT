# ADR-0047: Native graph controls and session charts

**Status:** Accepted · 2026-09-06 · Refines [ADR-0031](0031-provider-aware-llm-wiki-map.md) and [ADR-0046](0046-scoped-recent-memory-and-hindsight-map.md)

## Context

Dense memory maps need a stable focus, readable labels, and direct camera controls. The previous
hover-only interaction and app-wide event monitors made exploration difficult. The chat inspector
also exposed only a few generation numbers, despite the application already maintaining context
budgets, engine statistics, and coalesced live token estimates.

## Decision

Keep two native rendering tools with distinct purposes: SwiftUI Canvas renders graph topology;
Apple Swift Charts renders quantitative context, throughput, and response comparisons. No new
package, web renderer, network request, or persisted analytics is introduced.

The graph retains the existing provider validation, node/edge caps, and detached deterministic
layout. Its view adds collision-avoiding labels, curved links, pinned focus, bounded search,
a neighborhood filter, and an expanded sheet. Clicking pins a node; the focus panel's Open button
opens the existing record preview. Wiki link direction uses arrowheads around the focused node;
Hindsight relationships do not imply curated wiki direction. Fixed vector emphasis replaces the
continuous particle animation, including when Reduce Motion is enabled.

Camera math lives in a finite, bounded value type. The viewport requires a click to activate and
releases input when the pointer leaves, keyboard focus moves, or the scene becomes inactive. A
visible badge names its state, and an inactive map passes page scrolling through unchanged.
Drag pans, scroll/pinch zoom, right-drag rotates,
and the toolbar provides zoom, fit, and rotation actions. Keyboard +, -, and 0 operate the focused
viewport. Native event monitors belong to the exact visible viewport and key window, use weak
ownership, and are removed when the view disappears. Expanded-map record selection is handed off
after dismissal so it cannot compete with the record preview sheet.

The inspector's Nerd stats card uses the existing ContextStatus for a context-pressure ring,
including its input reserve and unknown/estimated states. Context additions saturate on overflow;
nonpositive capacities never become a plausible percentage. The live throughput area/line chart
samples existing byte-based text-plus-reasoning estimates once per second while the inspector is
visible and its scene is active. A bounded 60-sample series records interval rates, including zero
for stalls. Pause/resume establishes a new baseline, and a new generation resets the series.
Closing the inspector cancels sampling; no background sampler or telemetry file exists.

Up to 12 recent completed response statistics produce comparison bars. Engine-reported decode
rates and duration-derived rates have distinct colors and labels. Invalid rates are omitted,
unknown context is not drawn as zero, and estimates retain the ~ qualifier. Comparisons may span
models and settings and are explicitly not a benchmark. Existing persistence is unchanged; live
traces are session UI state and disappear on reload.

## Consequences

- Both graph surfaces share bounded rendering, camera behavior, and accessible native controls.
- The inspector becomes useful during inference without adding endpoint probes or transcript scans
  for live measurement. Timing and token estimation remain distinct from authoritative server data.
- The graph remains a bounded preview, not the full Hindsight explorer. Search covers loaded nodes.
- The graph has no permanent animation loop. Sampling is 1 Hz only during a visible active response.
- Tests cover camera anchors/limits/invalid input, rate capacity/pause/stalls, exact-versus-derived
  metrics, and context overflow. Existing graph validation and routing tests remain applicable.

## Alternatives considered

A third-party general-purpose graph package or embedded web dashboard would add dependencies and
lifetime complexity. A pie of token categories would suggest a breakdown the engine does not
reliably report. An unbounded, persisted high-frequency performance trace would add storage and
rendering cost without improving the compact inspector.
