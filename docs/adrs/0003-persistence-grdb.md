# ADR-0003: GRDB/SQLite for persistence

**Status:** Accepted · 2026-08-29

## Context

Chats, messages, projects, model registry, MCP config. Write pattern is hostile to naive ORMs: high-frequency streaming checkpoints, append-heavy transcripts, and we want future FTS5 full-text search. Candidates: SwiftData, Core Data, GRDB, raw SQLite.

## Decision

**GRDB** (`groue/GRDB.swift`), one database `goat.sqlite`, explicit `Codable` record structs in `GoatCore`, migrations via GRDB's `DatabaseMigrator`, UI observation via `ValueObservation` bridged to `@Observable` models.

Memory notes are deliberately **not** in the database. They are markdown files on disk (see ADR-0005). Attachments are files, referenced by row.

## Consequences

- Deterministic migrations, WAL mode, proven performance under streaming writes, and FTS5 is one migration away (parked feature, schema stays compatible).
- One third-party dependency, but the most battle-tested in the ecosystem; no cloud-sync pull because GOAT is local-only by pillar #1, which removes SwiftData's main selling point.
- Slightly more boilerplate than SwiftData; accepted in exchange for zero framework surprises (SwiftData's macOS behavior under heavy update load and its migration story remain the risk we're not taking).

## Alternatives considered

SwiftData (rejected: maturity/perf risk under token streaming, opaque migrations, main benefit, CloudKit, is anti-goal), Core Data (rejected: ceremony without SwiftData's ergonomics), raw SQLite (rejected: reinventing GRDB badly).
