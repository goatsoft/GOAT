# ADR-0072: Tool-generation telemetry and coder recovery

Status: Accepted · 2026-09-08

## Context

A live coding chat reported engine decode rates around 33–36 tokens/second with about 40 seconds of first-token latency per response. The UI treated the entire agent turn as active generation, and live counters omitted streamed tool arguments. The coder also repeatedly confused job cancellation with file deletion and retried create-only calls against existing files.

## Decision

Inference emits a byte-count-only toolInput event for streamed function names and arguments. These events are display estimates, never executable calls or transcript text. Assembled calls still appear only at stream completion. Shepherd coalesces the counters at the existing publication cadence, and Bleet includes them in the same byte-based live token estimate as text/reasoning. Final engine statistics retain authority.

The throughput UI distinguishes engine waiting, active output and tool steps. Initial waiting does not generate zero-rate chart samples. Waiting/tool steps show the latest measured response with an explicit label rather than presenting a stopped or empty live dial as current decode speed.

Native coding guidance includes literal JSON examples for commands, file deletion, working directories, shell syntax and job polling. The next request adds a bounded host-authored correction for the latest completed failed native action. Raw tool error content is not elevated into system instructions. Explicit owner denial receives no retry guidance. There is no automatic command execution, new deletion tool, expanded permission scope or round limit.

File deletion remains an explicitly authorized confined command, independently of native create/edit grants. The model must inspect the real command receipt and verify its outcome. Better instructions cannot guarantee that a local model always chooses the correct action.

## Consequences

Tool-heavy coding responses contribute live estimates and context usage. A fast decode rate can still follow a long engine wait; the display does not claim to solve server latency. Current chat/provider configuration and project files are not modified by this change. Tests use disposable workspaces.

## Alternatives considered

- Count transport chunks as exact tokens: wrong for batching and different server implementations.
- Show zero throughout engine waiting: conflates latency with decode speed.
- Treat stop-job or empty-write requests as inferred deletion: executes an action outside its declared tool contract.
- Automatically repeat failures or broaden approvals: hides the model's error and can duplicate side effects.
