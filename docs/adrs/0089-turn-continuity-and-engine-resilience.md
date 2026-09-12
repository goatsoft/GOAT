# ADR-0089: Turn continuity and engine resilience

Status: Proposed · 2026-09-11

Refines [ADR-0023](0023-single-active-turn-and-engine-lifecycle.md), [ADR-0065](0065-bounded-tool-format-recovery.md), [ADR-0066](0066-lead-and-continuous-tool-work.md) and the no-progress direction of [ADR-0084](0084-model-inspection-favourites-and-recovery.md).

## Context

Prompt history keeps only assistant rows that completed without an error. A response that hit the output limit, a response stopped during streaming, and a stopped tool round all carry an error, so they vanish from the next request: after a `length` finish the model never sees its own partial output and "send a message to continue" starts from nothing; after Stop in a tool loop, files the model already wrote disappear from its memory and it may recreate them. ADR-0065 intended this exclusion only for the malformed-markup row.

The engine client makes exactly one attempt per request. HTTP 408, 429 and 5xx are classified as connection failures but nothing retries them, and the stream uses the URL loading system's default 60 second idle timeout with no user-visible state while a large prompt prefills. The only loop guard is the file-repair tracker; a model that repeats an identical search or status call indefinitely is not caught. Established practice keeps failed turns with a synthetic marker, patches dangling tool calls with error results, retries transient errors with backoff before the first token, watches for stream stalls, and pauses after three identical tool calls.

## Decision

### Failed and stopped turns stay in history

Assistant rows whose failure category is `length`, `cancelled` or a tool error remain in prompt history. Their text receives a short model-visible suffix: `[response truncated by the output limit]`, `[stopped by the user before the response finished]`. Tool events without a result already carry "Not executed" or "outcome unknown" text and are sent as ordinary tool results. Only rows whose failure category is tool-format recovery are excluded, as ADR-0065 requires. The budgeter treats these rows like any other; they can be pruned or compacted.

### Repetition guard

Beside the file-repair tracker, a turn-scoped repetition tracker records each executed (tool name, canonical argument JSON) pair and a hash of each result. Three identical calls in one turn, or three consecutive identical results from the same tool, pause the turn with the existing no-progress presentation: the transcript explains what repeated, and the user can continue or stop. This is a no-progress check, not a round cap; productive repeated edits with different arguments are unaffected.

### Retry before the first token

A request that fails with HTTP 408, 429, 502, 503, 504, a connection reset or a classified `unsupportedParameter` (see [ADR-0086](0086-sampling-parameters-are-model-facts.md)) is retried up to three times with exponential backoff starting at one second, jittered, honouring `retry-after`, provided no token or tool fragment has been received. Once output has started there is no retry; the partial row is kept per the rule above. Context-overflow errors are never retried here; they route to [ADR-0087](0087-conversation-compaction.md). An empty initial response (round 0, before any tool round, so completed tool actions are never re-run) is retried once silently before the "ended without a final reply" message appears.

### Stall watchdog

The stream request's idle timeout becomes 300 seconds. Independently, when no bytes have arrived for ten seconds the composer shows "Waiting for the engine (prefill)" with the elapsed clock; when none arrive for 120 seconds after the first token the turn fails with a stall error rather than hanging. Both thresholds are constants recorded in ENGINES.md.

### Identifiers

Fallback tool-call identifiers become `call_<round>_<index>` so they are unique across rounds, and a request-side identifier longer than 40 bytes is truncated with a hash suffix before encoding.

## Consequences

Continuation after an output limit or a Stop works, and the model no longer repeats completed file actions after an interruption. Transient engine errors self-heal without duplicating output. Long prefills are visible instead of silent. Repetition loops end with an explanation rather than running until Stop. Fixture tests through the fake engine cover length continuation history, stopped-turn history with executed tool results, repetition pause after three identical calls, retry on 503 before first token, no retry after first token, empty-response retry, stall detection and identifier uniqueness.

## Alternatives considered

Auto-continue after a `length` finish (rejected for now: spends another full round without user consent; keeping the partial in history makes a manual continue work). A global tool-round cap (rejected by ADR-0084). Retrying after partial output (rejected: duplicates content and corrupts transcript state). Sending keep-alive probes to detect stalls (rejected: the client cannot probe an in-flight streaming request; elapsed-time thresholds are sufficient).
