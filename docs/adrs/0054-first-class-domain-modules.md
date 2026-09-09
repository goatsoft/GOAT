# ADR-0054: First-class domain modules

Status: Accepted · 2026-09-07 · Refines ADRs 0002, 0003, 0006, 0018, 0026, 0042 and 0045.

## Context

Kid's six local packages do not match its domain vocabulary. GoatCore mixes database storage, filesystem authority, Pens, UI themes and network policy. Shepherd, Paddock and Herd are app folders with no import boundary. Provider-neutral tool contracts are owned by the MCP adapter. This makes ownership harder to discover and causes independent packages to resolve and compile overlapping dependencies.

## Decision

Use one local Swift package, `apps/goat-macos/Modules`, with separately compiled library targets: Hoofprint, Caprine, Bleet, GOATed, Herd, Hindsight, Hitch, Inference, JUDAS, MCPClient, Memory, Paddock, Pens, Persistence, Pronk, Shepherd and Tools. The `goat` executable remains the Hitch command-line client. A package is the dependency-resolution unit; a target is the compiler-enforced module boundary.

Remove redundant Goat prefixes from infrastructure types and module names. Keep GOATed as the established product name. Use MCPClient because the external SDK already exports MCP. Keep brand/resource names, bundle IDs, persisted field names, environment variables, extension IDs, socket paths and command names unchanged. This is a source API reorganisation before Kid's first release, not a data migration.

Herd owns filesystem services and workspace bindings. Pens owns Pen metadata and serializable colour data. Caprine owns rendering and themes. Persistence alone imports GRDB. Tools owns transport-neutral tool requests and results; GOATed does not depend on the MCP adapter. MCPClient alone imports the external MCP SDK. JUDAS is an independent policy module and retains the existing configured/loopback/blocked behaviour. No module gains endpoint authority through this extraction.

Bleet owns observable session and message state. Shepherd owns turn orchestration and its worker, depending on explicit environment and tool-source protocols implemented by the host. Hoofprint owns bounded, in-memory event publication. The app owns composition, routing, settings, platform integration and screens that need the composition root. Extracted modules do not import the app.

Paddock owns artifact values, navigation decisions, HTML shells and the WebKit preview host. Hindsight owns the optional provider transport and store; the native graph presentation remains in the app. Pronk is a separate bundled example that depends on GOATed, never the reverse.

The module catalogue records every library, its dependencies, public seams, security limits and tests. A build check rejects unapproved module imports, dependency cycles, application imports from modules and direct GRDB/MCP imports outside their adapters. The existing network-boundary check follows the moved sources.

Tether remains proposed under ADR-0029. It owns media drafts and contextual Image/Video controls. A future media generation engine and job coordinator remain distinct from token-oriented Inference and Shepherd turns. No placeholder library, media job implementation or new network capability is added in this pass.

## Consequences

A domain has one source location and explicit imports. Tests share one resolver and build graph. Backend modules no longer import a catch-all package containing SwiftUI and SQLite. Cross-domain integration tests retain explicit test-only imports. The app can still compose concrete implementations; this is not a plugin sandbox.

Existing approvals, lifetimes, stored data, budgets and network behaviour must survive the move. Module extraction alone is not proof of lower runtime cost or security isolation. Optimisation findings require evidence and acceptance criteria in the architecture audit.

## Alternatives considered

Renaming GoatCore to Core would retain its mixed ownership. One Swift package per module would multiply resolver work without strengthening Swift import boundaries. Making every view a module would force presentation-specific contracts into the public API. Keeping all tool types in MCPClient would make bundled extensions depend on a transport they do not use.
