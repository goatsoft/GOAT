# ADR-0039: Preview and extension lifetime boundaries

Status: Accepted

## Context

Paddock had no explicit navigation delegate, retained artifacts across chat changes, and silently ignored export failures. Scoped skill providers could complete after unregistering. ADR-0036 described a broader future extension surface than the runtime currently supplies.

## Decision

Keep the existing native transcript, typed tool routes and scoped actor runtime. Separate web rendering and app tool routing into their own files. Bind returned skill identities to their exact registration generation, recheck registration and cancellation after provider awaits, and discard revoked catalog results.

Paddock is a viewer. Script navigation cannot replace the top-level artifact or launch custom URL schemes. Explicit HTTP(S) links open the system browser, subject to the off-grid host policy. Embedded web resources remain governed by ADR-0015. Policy changes replace the web view before loading content, preserving a fail-closed off-grid start. Mermaid is always offline, uses strict rendering and bounded text/edge counts, and exposes source for failures.

Preview and source are available for renderable artifacts. Closing returns to the info inspector; changing chats clears the old artifact. Export errors are visible. Completed Markdown preparation tracks both message identity and source, preventing stale cached presentation. Reasoning expansion is bounded and remains user controlled.

Document the implemented skill hooks and internal turn integration separately from future public capability families in `docs/EXTENSIONS.md`.

## Consequences

Re-registering a provider invalidates loaded resource handles while preserving selection keys. Cancellation is cooperative and cannot stop arbitrary provider side effects. Browser previews remain untrusted web content, with no native execution bridge. Interactive HTML that relies on top-level navigation or custom protocols must use an explicit web link or be opened outside Paddock. No dependency or executable plugin loader is added.

## Alternatives considered

A new chat framework or generic plugin/event bus would broaden scope and introduce new lifecycle contracts without evidence that replacement is necessary. Retaining provider identity by name alone cannot distinguish a revoked registration from its replacement. Reusing an online web view while compiling an off-grid policy leaves an avoidable document lifetime gap.
