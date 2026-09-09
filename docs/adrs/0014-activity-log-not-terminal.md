# ADR-0014: The bottom panel is an activity log, not a shell terminal

**Status:** Accepted · 2026-08-30

## Context

JB wanted an "integrated terminal somehow at the bottom" that shows an ASCII goat on open. Two readings: a real shell (run commands) or a read-only console of GOAT's own internals. A prototype shell was built, then reconsidered.

## Decision

**A read-only activity log** (`ActivityLog` + `ActivityLogPanel`), not a shell. JB's reasoning, adopted verbatim: keep it lean, no TTY/PTY emulation, and users already have a terminal if they want one. It streams GOAT's internals: `ENGINE` (requests, tok/s, tool-schema load), `MCP` (tool calls + timing), `WARN` (errors/offline/auth), `INFO` (health), timestamped and category-coloured, headed by the front-on goat ASCII crest. Toggle via the **"Activity" text link** (left of the model dropdown, under the composer) or **⌃`**.

## Consequences

No arbitrary-exec security surface; reuses existing data (the MCP call log, engine stats); tells the local-first story ("watch it run on your machine"). Events are emitted from `AppModel` at the points they happen (`runGeneration`, tool invoke, `apply(health:)`). The prototype shell code was discarded.

## Alternatives considered

Shell terminal (rejected by JB: TTY complexity, redundant with the user's own terminal), tabbed both (rejected: more to build/maintain).
