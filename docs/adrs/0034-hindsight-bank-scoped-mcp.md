# ADR-0034: Hindsight is a bank-scoped server provider

**Status:** Accepted · 2026-09-03 · Supersedes the Hindsight implementation details in [ADR-0005](0005-memory-architecture.md)

## Context

ADR-0005 correctly made Hindsight optional and first class, but its implementation details
mistook the coding-agent integration for Hindsight's storage model. In particular, a repository
workspace picker, a Node package launch, and `~/.hindsight/coding-agent.json` are not the identity
of Hindsight memory. Hindsight is a server of isolated memory banks.

The official MCP documentation recommends single-bank mode: the bank is in the MCP URL
`{base}/mcp/{bank_id}/`, and all operations on that connection are scoped to that bank. The core
MCP tools are `retain`, `recall`, `reflect`, `list_memories`, `get_memory`, and `get_bank`.
Knowledge pages and coding-agent harnesses are server or integration features, not GOAT's provider
identity. A GOAT provider must not require an arbitrary local directory to select its data.

## Decision

`HindsightMemoryStore` is a typed private client of Hindsight's official single-bank Streamable
HTTP MCP endpoint. Settings asks for exactly a base server URL, a bank ID, and an optional API key;
it never opens a folder picker, installs Node, starts a daemon, reads coding-agent configuration,
or derives a bank from a project path. GOAT builds the bank URL itself and validates it before any
connection: the bank ID is lowercase alphanumeric, hyphen, or underscore; a non-loopback server
must use HTTPS; the base URL has no path, credentials, query, or fragment.

GOAT owns only a non-destructive core allow-list:

- `get_bank` tests the selected bank during explicit connect and health checks.
- `list_memories` and `get_memory` back the Pages browser and document preview.
- `retain` stores explicit remembers and feedback. It is asynchronous, so a just-written item may
  not appear in a subsequent browse immediately.
- `recall` and `reflect` are model-facing memory operations.

The client refuses a server that does not expose every required tool, rejects error, truncated, or
malformed JSON results, bounds request and response sizes, disconnects after a failed call, and
backs off before reconnecting. GOAT does not expose Hindsight's delete, clear, update, bank-
management, directive, or knowledge-page tools. It therefore cannot mutate or delete bank
configuration or data beyond an explicit `retain`.

The configuration stores only the server URL and bank ID. An API key is stored separately in
GOAT's owner-only credential store; it is never written into `memory.json`, logs, or a tool
argument. Hindsight Cloud's preferred OAuth flow is not implemented by GOAT's current MCP client,
so Cloud users must deliberately supply an API key until OAuth callback support exists. No endpoint,
bank, or credential has a GOAT default.

Existing coding-agent-style bindings remain decoded as legacy configuration so GOAT does not
silently alter or delete them. They fail closed with a reconnect message. Reconnecting creates a
new bank-scoped provider binding; it never copies, merges, or renames a bank or local memory.

Hindsight remains one shared bank per GOAT provider binding. It is not labeled as an isolated
Global or Pen store, and moving a chat changes only which provider future operations use. The local
Markdown and LLM Wiki scope rules remain unchanged.

## Consequences

- The Hindsight setup UI matches the actual product model: server plus memory bank, never
  workspace plus plugin.
- GOAT works with the official recommended single-bank endpoint and does not depend on a local
  coding-agent package or its private configuration format.
- Explicit selection and the HTTPS rule retain the Herd Guarantee: Hindsight traffic occurs only
  after the user deliberately configures the server and bank.
- Browser data is Hindsight memory facts, not local Markdown or synthetic LLM Wiki pages. The
  provider has Pages but no GOAT map because it does not provide local wikilinks and provenance.
- A legacy binding requires user action, which is safer than guessing a bank or writing to a
  default bank.

## Alternatives considered

Keep the coding-agent wrapper (rejected: it ties a server-backed bank to an unrelated repository
directory and unsupported harness lifecycle), configure Hindsight as a generic user MCP row
(rejected: GOAT could not maintain durable provider identity or constrain destructive tools), use
multi-bank mode with `X-Bank-Id` (rejected: a single-bank URL provides stronger, simpler scope),
and create or migrate banks automatically (rejected: it could put durable memory in the wrong
place).
