# ADR-0010: The Paddock: artifact previews over a custom transcript

**Status:** Accepted · 2026-08-29

## Context

JB wants rich previews: syntax-highlighted code, rendered diagrams and charts, live HTML, and eventually running code. The question arose as "should we adopt [SwiftyChat](https://github.com/EnesKaraosman/SwiftyChat)?" Evaluated fairly: it has macOS 14+ support (since 2.7.0) and is actively maintained, but it is a *messenger* kit (carousels, quick replies, contacts). It has no streaming-token model, no markdown pipeline, no thinking disclosures, no tool cards, and no artifact rendering, which is the actual ask. Swapping frameworks pays a rebuild tax toward none of the goal.

## Decision

**Transcript stays custom (reaffirms ADR-0002). The ask becomes a new surface: the Paddock**, where the goat's creations run around.

- **Phase 1, rich code in-transcript:** [HighlightSwift](https://github.com/appstefan/HighlightSwift) (highlight.js via JavaScriptCore, 50+ languages, fully offline) plugged into MarkdownUI's code-block style. Header row: language chip, Copy, Save…, Open in Paddock. Highlighting runs on completed messages only (the streaming perf rule stands).
- **Phase 2, the Paddock pane:** lives in the inspector slot (artifact open → Paddock; closed → info inspector). Fenced `html`/`svg`/`mermaid`/`markdown` blocks and any code block open there. Renderers: HTML/SVG in a `WKWebView` with `websiteDataStore = .nonPersistent()`; **Mermaid via `mermaid.min.js` (11.x) bundled as an app resource**, no CDN, the Airplane Mode Guarantee holds; markdown natively via MarkdownUI. Export via `NSSavePanel`.
- **Phase 3, Run (deferred, designed):** ▶ on scripts (python3 / zsh / swift) executes via `Process` behind the **same Deny / Allow Once / Always gate as MCP tools** (ADR-0006). Code execution is a permission surface, never a free pass. Output streams into the pane.

## Consequences

- Model-authored HTML renders in-app: mitigated by non-persistent web storage, no credentials in the app to steal, local-only posture (ADR-0007); the webview is a viewer, not a browser.
- Two additions: HighlightSwift (SPM) and the 3.4MB mermaid asset. The AGENT.md size-rule exception now covers `App/Resources` alongside the icon.
- MarkdownUI's code-block rendering is now ours to maintain, and ours to make excellent.

## Alternatives considered

SwiftyChat swap (rejected: messenger-shaped, zero artifact features, rebuild tax), native Swift Charts renderer for a chart JSON spec (deferred: mermaid + HTML cover it), CDN-loaded mermaid (rejected: violates the Airplane Mode Guarantee), separate artifact window (deferred: inspector slot first, window promotion later if wanted).
