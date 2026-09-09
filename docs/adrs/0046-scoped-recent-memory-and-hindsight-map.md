# ADR-0046: Scoped recent memory and a native Hindsight map

**Status:** Accepted · 2026-09-06 · Refines [0031](0031-provider-aware-llm-wiki-map.md) and [0037](0037-app-wide-memory-provider-and-pen-banks.md)

## Context

The Pen landing page mixed workspace setup, instructions, files, skills and memory in one long
column. Its six-record memory preview incorrectly directed users to Global Memory Settings for
more Pen records. Hindsight records were also alphabetized after retrieval, obscuring recency.

A saved configuration selected the same bank for Global memory and a Pen. Correctly scoped
requests therefore still displayed the same corpus. Editing a connection without changing its
provider ID could additionally leave an old browser result visible.

Hindsight 0.9.2 exposes a bank-scoped graph endpoint. Its actual response wraps nodes and edges
in `data` objects. These represent server relationships, not wiki citations. GOAT can reuse its
native map renderer without embedding the Hindsight web application or inventing relationships.

## Decision

- The Pen area below the composer has Workspace and Memory tabs. Workspace contains the folder
  and Git status, Instructions, Additional Files, and Skills, in that order.
- Both recent-record lists display at most 20 records in a scroll area capped at 300 points,
  typically four previews at once. Settings always requests Global memory;
  a Pen always requests its dedicated route. Hindsight preserves the server's descending update
  and creation ordering. Local records sort by modification date with a deterministic ID tie-break.
- Known Pen bank routes cannot be selected as Global memory. Existing conflicting configurations
  fail closed at the store boundary with a corrective message. Pen enablement also rejects using
  the service's Global bank. No historical records are automatically migrated or deleted.
- Browser load identities include the resolved connection and bank. Loading clears old records
  and previews; asynchronous reads verify ownership before publishing their results.
- Hindsight's native map reads `GET /v1/default/banks/{bank_id}/graph?limit=60` through the existing
  bounded, credential-aware, JUDAS-managed HTTP client. The graph response has a separate 2 MiB limit (bank control responses remain 256 KiB), 60
  nodes and 480 rendered connections. IDs must be unique; dangling and self-links are discarded.
  Multiple server link types between the same ordered pair share one rendered connection.
- Graph decoding and deterministic layout run off the main actor. Server colors are ignored in
  favor of GOAT's theme. The map labels memories and relationships rather than wiki sources.
  Clicking a node uses the existing bank-scoped memory reader. A graph failure does not hide
  successfully loaded recent records. Hindsight does not expose wiki-only Connections statistics.
- An explicit Open in Hindsight link uses the configured server's scheme and host on port 9999,
  opens through JUDAS, and never includes API credentials. This conventional UI endpoint is a
  user-facing link, not an automatic service probe. Custom reverse-proxy UI endpoints are not
  configured by this change. SSH users must forward the UI port separately from the API port.

## Consequences

The landing page is shorter and memory scope is visible. Large banks have bounded native previews
and a route to Hindsight's complete UI. Hindsight facts remain facts; GOAT does not describe them
as complete original chat transcripts. Existing mixed-bank content stays in place because its
historical ownership cannot safely be guessed.

Regression tests cover shared-bank rejection, endpoint edits, graph identity validation, dangling
links, graph size limits, deterministic layout and credential-free UI links. No dependency is added.

## Alternatives considered

Embedding Hindsight's entire UI would duplicate navigation and introduce browser authentication
and rendering concerns. Generating relationships from text similarity inside GOAT would imply
connections the server did not provide. Loading every record would make large banks expensive.
