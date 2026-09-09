# ADR-0015: Preview network policy: the Herd Guarantee, and off-grid as a choice

**Status:** Accepted · 2026-08-30

## Context

The original "Airplane Mode Guarantee" claimed every feature works with networking disabled. Paddock previews (ADR-0010) complicated it: model-written HTML rendered in a `WKWebView` can fetch remote resources, and that is often the point (previewing a page that pulls real docs, images, or a CDN script). Blocking everything would gut a legitimate feature; allowing everything silently made the guarantee's wording false. Two different promises were living under one name.

## Decision

Split the promise in two:

1. **The Herd Guarantee (invariant, absolute):** GOAT's own code never phones home. No telemetry, no analytics, no update pings, no network call initiated by the app on its own behalf. The only egress is what the user configures (engine endpoint, MCP servers, Hindsight) plus preview *content* under the policy below. This is the invariant AGENT.md enforces.
2. **Preview network access (user policy, default on):** Paddock previews may fetch the web by default, like the browser view they are. A **General → Off-grid previews** toggle restricts them to local content: a `WKContentRuleList` blocks every request except `file:`, `about:`, and loopback hosts. Bundled assets (mermaid.min.js) load via `file:`, so diagram rendering works with the cable pulled either way. If the rule list fails to compile, the preview fails **closed** (renders nothing) rather than leaking.

The app itself still functions fully offline: chat, projects, MCP over stdio, previews of self-contained content. Preview content that needs the web degrades exactly as a browser would, and the Paddock header shows a globe / wifi-slash indicator so the mode is never a mystery.

## Consequences

Honest naming: the invariant ("nothing leaves the herd") is now about GOAT's behavior, not the user's content. Privacy-maximal users flip one switch and get the old absolutist behavior. The acceptance bar (PLAN §13) tests both halves: core features with networking off, and off-grid actually blocking a remote fetch.

## Alternatives considered

Always-block (rejected: kills the "preview a real page" use case), a user-editable domain safelist (deferred: the rule-list mechanism supports it if demand appears), per-artifact permission prompts (rejected: permission fatigue for a viewer pane).
