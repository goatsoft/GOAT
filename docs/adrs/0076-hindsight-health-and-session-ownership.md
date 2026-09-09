# ADR-0076: Hindsight health and session ownership

Status: Accepted · Refines [ADR-0035](0035-hindsight-connection-lifecycle.md)

## Context

An individual memory request could mark the saved provider unavailable even when its connection remained healthy. That status prevented subsequent turns from attempting recovery. Independent health checks also replaced live transports, allowing overlapping checks, cancelled views and late results to interfere with the current connection. A disposable editor test could succeed while the operational card retained its failure.

## Decision

- Share concurrent connection checks for the same provider and complete transport fingerprint, including credentials. Validate an existing session with `get_bank` before replacing its transport.
- Give each connection attempt explicit ownership. Configuration changes and disconnect invalidate older attempts, including handshakes that have not yet published a session. A cancelled view does not cancel a shared operational check.
- Keep request errors separate from session health. Report failed context preparation for that turn while retaining a healthy connection. Retrying a read does not turn a tool-level rejection into an offline state. Never replay an unacknowledged write.
- Publish model status only for the current configuration and reconciliation. Reconcile selected providers without disconnecting unchanged healthy clients.
- Refresh the saved operational connection after a successful test of its unchanged editor draft. Edited server, bank or credential drafts remain isolated until saved.
- Recheck the configured card every 15 seconds while Memory settings is visible. Before preparing a turn, retry an unavailable, enabled scope using the existing short connection backoff. Explicit bank checks can retry immediately. Disabled extensions and Pen memory remain disabled; JUDAS still controls every transport.

## Validation

Deterministic transport tests cover overlapping checks, cancelled callers, disconnect during validation, late results after a bank change, request errors, endpoint recovery and no replay of uncertain writes. The test transport seam is internal; the production adapter remains MCPServerManager. No dependencies or server-side data changes are introduced.
