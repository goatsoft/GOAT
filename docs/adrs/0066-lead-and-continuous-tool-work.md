# ADR-0066: Lead and continuous tool work

Status: Accepted, 2026-09-08. Refines ADR-0023 and supersedes the eight-round cutoff in ADR-0006 and the cap reference in ADR-0065. The pre-tool automatic-title timing is revised by [ADR-0085](0085-prefix-stable-prompts-and-usage-calibrated-budgeting.md): titles now run after the turn so no title request evicts the engine prefix cache between tool rounds.

> Superseded in part by [ADR-0067](0067-lead-waits-for-the-current-action.md): Lead waits for the current action and keeps its pending approval open. The earlier decision text is retained as history.

## Context

Coding tasks stopped after eight response rounds without explaining why. Users could type a draft while the agent worked but could not guide the active turn. Automatic titles waited until the entire tool workflow ended.

## Decision

Remove the response-round cutoff for native and MCP tool workflows. Continue until the model finishes, an error prevents progress, or the user presses Stop. Preserve prompt budgeting, permission checks, sequential tool execution, persistence barriers, and the single malformed-tool-format retry.

Expose **Lead** beside Stop in the active chat's composer. Lead accepts text, saves it as a user message, and joins it to the same turn. Let an in-flight response or tool operation finish; skip unstarted tool calls from the old response and give the model the saved instruction before further actions. A pending permission dialog is dismissed when Lead is saved, with the call recorded as superseded rather than denied. Never cancel an in-flight file write to apply Lead.

Only the owning chat accepts Lead. Serialize saves, allow at most eight pending instructions of 32 KiB each, and never include an unsaved instruction in an inference request. Failed saves keep the draft. Stop does not launch a new turn for a queued instruction; show that it remains saved but unapplied. Close Lead admission before final lifecycle work so input cannot disappear in turn cleanup. Attachments remain available for ordinary sends after the turn ends.

Generate the title after the first usable assistant response, before its tools execute. If the model emits only tool calls, name after the first completed tool round. Serialize this small naming request with normal generation to avoid competing local model requests. Preserve automatic-title preferences and manual renames.

Surface empty final responses, user cancellation, and engine output limits explicitly. Preserve the engine's finish reason through stream normalization; do not execute tool calls from a response truncated by an output limit.

## Consequences

Long coding tasks can finish naturally and remain steerable. A model that continues issuing valid tool calls can run until stopped; there is no fixed action budget. Lead takes effect at a safe boundary rather than interrupting a write. Naming can briefly delay the first tool while its request completes. Lead is text-only in this version.

## Alternatives considered

Cancelling and restarting each response on Lead risks interrupting writes and losing their results. A separate concurrent turn breaks the existing ownership invariant. Keeping an arbitrary response-round cap prevents ordinary scaffolding tasks from completing.
