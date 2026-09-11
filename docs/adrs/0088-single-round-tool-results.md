# ADR-0088: Single-round tool results

Status: Proposed · 2026-09-11

Refines [ADR-0069](0069-coding-navigation-and-context-retention.md) and [ADR-0070](0070-confined-pen-command-jobs.md); the confinement, whitelist, approval and turn-end cleanup rules of ADR-0070 are unchanged.

## Context

On a local engine each model round trip re-reads the growing context, so the number of rounds, not the size of any one result, dominates the cost of a coding task. Three Herder behaviours multiply rounds. `pen_run_command` returns a job ID and the model polls `pen_command_status` with at most ten seconds of wait per call, so a ninety second install costs nine or more rounds. `pen_read_file` returns at most 200 lines and 32 KiB per call, so a 900 line file costs five rounds. `pen_list_files` lists one directory per call with no recursive or pattern mode, so locating a file in an unfamiliar tree costs several rounds.

Results are also JSON objects with the file content as an escaped string, so every newline and quote is escaped. That costs tokens and, more importantly, makes copying an exact `old_text` fragment unreliable for smaller models, which is the origin of the "missing or ambiguous match" loop that the recovery hints try to correct. All reference harnesses return plain text with a bracketed notice, run commands synchronously to a timeout with head-and-tail truncation, and save any overflow to a file the model can search.

## Decision

### Commands block until done or timed out

`pen_run_command` runs the command and returns in one result: exit code, whether it timed out, and combined output bounded to 32 KiB with the middle elided and a marker giving the omitted size. `timeout_seconds` keeps its 1 to 600 range and the owner's default. When output exceeds the bound, the full log is written to the Pen's private scratch area and the result names the scratch path, which `pen_read_file` and `pen_search` accept. A `background: true` argument keeps today's job semantics for servers and watchers; only then is a job ID returned and `pen_command_status` and `pen_stop_command` remain for those jobs. Approval, seatbelt, whitelist, network policy and turn-end cleanup are unchanged. The command guidance in the system prompt shrinks to the synchronous form.

### Reads and searches return plain text

`pen_read_file` returns a one-line header (`path, lines A-B of N, next_start_line M` when truncated) followed by the raw content. An optional `line_numbers: true` argument prefixes each line with its number and a tab, with the header stating that numbers are not content. The per-call bound becomes 2,000 lines and 48 KiB; `start_line` and `line_count` are kept. Search snippets and command output use the same plain form. The 64 KiB argument bound and the 1 MiB file bound are unchanged.

### Navigation in one call

`pen_glob` takes a workspace-relative pattern and returns up to 500 matching paths sorted by modification time, newest first, honouring the same ignore rules and scan bounds as `pen_search`. `pen_search` gains an optional `regex: true` with the same bounds and a 200 millisecond per-file limit. `pen_list_files` is unchanged.

### Read-only calls run concurrently

Within one response, calls to `pen_read_file`, `pen_search`, `pen_glob` and `pen_list_files` execute concurrently and their results are delivered in call order. Writes, edits and commands stay sequential and keep their permission prompts. The system prompt tells the model it may request several independent reads in one response.

## Consequences

A typical build-test-fix cycle drops from roughly eight to twelve rounds to three or four, and a whole-file read is one round. Small models copy edit fragments from raw text far more reliably. Prompt guidance about job polling, escaped content and cursor continuation is removed, shortening the stable prefix. The scratch log path gives the model a way to inspect large output without a bigger context. Existing ADR-0070 fixtures for job lifecycle move behind the `background` flag; new fixtures cover synchronous exit codes, timeout marking, middle elision, scratch spill, glob bounds, regex bounds and concurrent read ordering.

## Alternatives considered

Keep polling with a longer wait (rejected: still one round per wait period and still a page of prompt text). Return command output as an attachment (rejected: not searchable by the model). Keep JSON results for machine safety (rejected: the model is the only consumer and the header carries the metadata). Unlimited concurrency including writes (rejected: permission prompts and file repair progress assume order).
