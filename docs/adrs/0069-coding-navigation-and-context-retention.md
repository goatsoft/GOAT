# ADR-0069: Coding navigation and context retention

Status: Accepted · 2026-09-08

Refines ADR-0024, ADR-0061 and ADR-0068.

## Context

The agent-support pass found no native search, no continuation after a 200-entry listing, whole-file reads that consumed context, and old tool arguments that could make a long coding exchange exceed the input budget. Stop could discard a provider result returned just after cancellation.

## Decision

Add literal `pen_search` with filename glob, case sensitivity, line numbers and bounded result excerpts. Search skips links, `.git` and common dependency/build directories. Scanning is limited to 10,000 entries, 1,000 files, 16 MiB, depth 32 and at most 100 matches. Truncation is explicit and asks the model to narrow the search.

Directory listings have a sorted `after` cursor and `next_after`, with at most 200 entries and a bounded encoded page. Reads use 1-based `start_line` and `line_count`, return exact content plus separate metadata, and expose `next_start_line`. UTF-8 files may be up to 1 MiB; each read contains at most 200 lines and 32 KiB. LF, CRLF, Unicode and final-newline state are preserved. A single line beyond the read bound fails with guidance. Native create/edit arguments remain limited to 64 KiB; large files should use focused edits or separately approved command tools.

Prompt-budget policy version 3 may replace old, complete tool call/result groups in the newest exchange with deterministic, labelled excerpts when that exchange exceeds its budget. It preserves the latest two tool groups, user instructions where they fit, tool names, bounded argument fields and result excerpts including denial/error text. Both sides of a compacted protocol pair are removed together. Retained calls keep their original arguments and identifiers; invalid or unanswered call history is rejected before compaction. Excerpts are quoted historical data, not executable calls or a claim of success. Compaction is reported in the existing context-trimming report, affects only the outbound request, and leaves the durable transcript unchanged. Ordinary trimming and honest budget failure remain possible.

Guidance follows the supplied tool catalog: navigate before editing, copy exact read content, correct actual failures, preserve unrelated work, check results and report blockers. Native command instructions and external process instructions are distinguished. The agent should continue authorized work after intermediate tools and give brief progress updates.

Stop preserves known results even if cancellation arrived during the provider's return. Unstarted calls are marked not executed. A cancelled call without a known outcome explicitly asks for state inspection before retrying. Explicit owner denial is distinct from stale or revoked authority.

## Consequences

Large projects are easier to inspect and long tool histories fit more often. Context excerpts are lossy and do not provide semantic task memory across arbitrary Lead messages or multiple full exchanges. The model must reread current files before editing or repeating an old action. The newest two oversized calls, excessive schemas or system context can still fail budgeting with an explanation.

## Validation

Tests cover pagination without omissions, CRLF/Unicode reconstruction, large-file ranges, byte/scalar bounds, search filters, literal matching, links, argument types, old-history compaction, protocol consistency, deterministic planning, Stop with a completed action, and registration through GOATed. See the agent-support audit for final run evidence.

## Alternatives considered

Unlimited tool output would exhaust context. Editing tool-call arguments in place would misrepresent executed protocol history. An additional model-generated summary would add inference latency and another failure path; deterministic excerpts are inspectable and need no engine call.
