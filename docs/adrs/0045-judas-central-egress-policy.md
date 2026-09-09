# ADR-0045: JUDAS central connection policy and security activity

**Status:** Accepted · 2026-09-05 · Refines [ADR-0015](0015-preview-network-policy.md), [ADR-0024](0024-deterministic-prompt-budgeting.md) and [ADR-0042](0042-goated-kid-capability-contract.md).

## Context

The Herd Guarantee prohibited app-owned telemetry, but enforcement was distributed across transports. Chat generation used the shared HTTP session, metadata allowed same-origin redirects, and MCP and Hindsight rejected redirects independently. Paddock Markdown could use a dependency's image downloader. There was no central restriction switch or common security audit surface.

JUDAS is the host security component: “JUDAS is watching the HERD.” Herd remains the project workspace convention; Shepherd coordinates chat turns; Hitch exposes the local CLI/API. JUDAS is always present and is not an optional GOATed extension.

## Decision

Place the shared policy, isolated HTTP client, typed audit events and scoped cancellation registrations in GoatCore. GoatMCP gains a local GoatCore dependency; no external dependency is added. The production app uses one host-owned JUDAS instance. Tests inject independent instances where policy changes must be isolated.

Settings > JUDAS persists one of three modes:

| Mode | Managed HTTP | MCP subprocesses | Previews and browser links |
|---|---|---|---|
| Configured connections (default) | The origin supplied by the existing, validated integration configuration | Existing configured processes and tool approvals | Existing preview Off-grid preference; deliberate HTTP(S) links |
| Loopback only | Exact configured origins on `localhost`, `127.0.0.1` or `::1` | Denied because their independent traffic cannot be confined | Local resources and loopback image/media resources; local HTTP(S) links |
| Block connections | Denied, including loopback | Denied | Local resources; no HTTP(S) links or network resources |

The first mode preserves the existing policy for explicitly chosen endpoints. Loopback mode intentionally excludes LAN addresses, DNS aliases and other loopback spellings. A local server can itself contact other systems; loopback does not prove that the external server is offline.

Every managed HTTP request checks its scheme, host and effective port against its client's configured origin and the current JUDAS mode. Embedded userinfo and fragments are rejected. Paths and queries remain functional but are never retained in the audit. HTTP redirects, including same-origin redirects, are denied before following the new request. Sessions are ephemeral and have no shared cookie, credential or response-cache storage. Existing integration-specific validation, request limits and timeouts remain in force.

Mode changes revoke all currently registered managed HTTP sessions and retire preview documents, even when changing to a less restrictive mode. MCP subprocess launch and pipe writes check policy; registered processes receive termination with the existing bounded escalation. The host requests cleanup without blocking the main thread. Integrations may need reconnection afterward. Revocation cancels pending work but cannot undo bytes or side effects already delivered. A request admitted immediately before revocation may already be in the operating system's network stack.

WebKit receives centrally generated content-blocking rules before restricted content renders. Rule compilation failure leaves a blank/error document. Restricted HTML/SVG disables page JavaScript and receives a restrictive Content Security Policy, including no fetch, workers, frames or form submission. Only GOAT's escaped, bundled Mermaid template opts into bundled scripts. Switching policy replaces the web view and cancels the old document. Native Markdown uses blocked image providers in chat, memory and Paddock; it does not use the dependency's default downloader. Deliberate browser links pass through the host policy before handoff. External browser activity after handoff is outside GOAT.

Hitch remains a same-user Unix socket in all modes. Its local operations enter the audit; a submitted turn's HTTP and MCP work still obeys JUDAS. There is no Hitch operation or model tool for changing JUDAS policy. Local files, Pronk state and ordinary offline application features remain usable.

## Activity Log

Use the existing Activity Log with a `JUDAS` category and monotonically sequenced, timestamped events. Record policy changes, connection admissions and denials, redirect refusals, request termination, revocation, preview policy/navigation decisions, MCP/extension tool permission decisions and local Hitch operations.

Audit destination fields contain sanitized HTTP origins, bounded engine/server/extension and tool names, fixed operation names or fixed policy labels. Unsafe or oversized display names are redacted. They never contain URL paths, queries, fragments, userinfo, headers, prompts, tool arguments, response bodies, subprocess arguments/environment or raw transport errors. Existing non-JUDAS activity entries retain their own logging policies.

Producers write into a locked queue capped at 2,048 events. The UI drains it every 200 ms and retains its existing latest 500 entries. Queue overflow produces an explicit omitted-event count which remains visible after the batch. Clear also drains queued events so they do not reappear. This is an in-memory operational log, not a durable or tamper-evident forensic journal.

WebKit does not expose every subresource decision through its navigation delegate. The audit records installed preview policy and observable navigation decisions, not a packet trace or an invented list of all blocked resources. Request completion records the transport outcome, not application-level success.

## Consequences and limits

JUDAS makes the managed request path uniform and testable. A repository verification check rejects new direct URLSession clients, Network connections, default AsyncImage loaders and unmanaged web views outside the approved host entry points. This check catches accidental regressions; it is not a proof of confinement.

Native bundled Swift code remains trusted and in-process under ADR-0042. It can technically call operating-system APIs directly. JUDAS is not an OS firewall, a sandbox for arbitrary executable extensions, a monitor of another process's traffic, or content-based data-loss prevention. External MCP descendants and independently running model servers are outside its confinement. Strict modes therefore refuse MCP subprocess use rather than claiming to inspect it. Arbitrary executable extension loading remains outside Kid.

The lock-protected policy and immutable URLSession delegate/client use documented `@unchecked Sendable` conformances. Cancellation callbacks run outside the policy lock and can reenter safely. Scoped registrations release callbacks when their owners exit, including failed connection startup.

## Validation

Tests cover exact origin matching, scheme/port changes, redaction, bounded audit overflow, callback reentrancy, strict-mode subprocess admission, restricted-preview rule compilation, disabled arbitrary scripts, CSP installation and real bundled Mermaid rendering. Loopback HTTP fixtures prove denial before transport, redirect rejection before a second listener receives a request, and cancellation while a request is active. The normal `make verify` gate includes the JUDAS boundary check and existing transport/lifecycle tests; no live engine, external endpoint or published artifact is required.

## Alternatives considered

A dashboard over existing logs would not enforce requests. Making JUDAS an optional extension would put host security under extension lifecycle control. An OS-wide network extension would need a separate entitlement, distribution and product decision. Packet inspection or a durable compliance journal would introduce capabilities and privacy costs beyond this local host policy.
