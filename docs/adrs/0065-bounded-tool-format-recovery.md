# ADR-0065: Bounded recovery for unexecuted tool-call text

Status: Accepted · 2026-09-08

> The round-cap reference below is superseded by [ADR-0066](0066-lead-and-continuous-tool-work.md).

## Context

A real coding request returned Qwen function/parameter markup as ordinary streamed content, with a closing tool-call envelope but no opening envelope. The response contained no structured tool calls. GOAT's existing diagnostic required the opening envelope, so it presented the response as successful and stopped. Three direct streaming probes using the selected engine and native file schemas returned valid structured calls, demonstrating that a malformed generation does not necessarily mean the engine cannot call tools.

## Decision

Recognize unexecuted Qwen function markup outside Markdown fences when it names a tool currently offered to the model and has either tool-call envelope marker. Never parse that text into executable calls.

Shepherd may request one corrected response per turn, within its existing round cap. Persist the malformed response as failed before retrying, exclude it from subsequent prompt history, and add a one-round host instruction explaining that no action occurred and that the model must use its complete structured tool format. Existing successful tool results remain in context, with an explicit instruction not to repeat completed actions.

A fresh structured call follows the existing route, permission and filesystem checks. Denials, execution errors, timeouts and responses containing structured calls do not trigger this recovery. A second malformed response stops with an explicit error. Persistence failure or cancellation stops recovery. Fenced syntax examples are ordinary content.

## Consequences

Malformed generations can recover without asking the user to resend a request. This adds at most one inference round and does not guarantee that a model will produce a valid call. Persistent engine/template mismatches still require configuration repair. No engine settings or permission scope is changed by recovery.

Regression tests cover missing opening envelopes, fenced examples, the retry cap, and denial at the normal permission gate. An opt-in integration test exercises the configured coder model through Shepherd, AppToolRouter and native Pen files using a disposable workspace and permission database.
