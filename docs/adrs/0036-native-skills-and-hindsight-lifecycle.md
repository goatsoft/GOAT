# ADR-0036: GOATed extensions, native skills, and Hindsight lifecycle

**Status:** Accepted · 2026-09-04 · Supersedes the Hindsight runtime and scope decisions in [ADR-0034](0034-hindsight-bank-scoped-mcp.md), refines [ADR-0005](0005-memory-architecture.md), [ADR-0033](0033-exclusive-pen-and-global-memory-scopes.md), and [ADR-0035](0035-hindsight-connection-lifecycle.md)

## Context

ADR-0034 made Hindsight a first-class Settings choice, but reduced its runtime to a typed client of
one bank-scoped MCP endpoint. That is a first-class storage connection, not the behavior provided
by [`@vectorize-io/hindsight-coding-agents`](https://github.com/vectorize-io/hindsight/tree/main/hindsight-integrations/coding-agents).

The upstream coding-agent integration has a shared lifecycle runtime plus a thin adapter for each
agent host. Hook-based hosts receive session-start, prompt-submit, and stop hooks together with an
MCP tool server and a companion skill. Hosts with a persistent extension API bind the same runtime
as a native plugin and may expose native tools without MCP. In both forms, the integration owns
bank resolution, bounded memory synthesis, knowledge pages, Git and conversation ingestion, and
session write-back. The skill teaches the model how and when to use those capabilities, but it does
not implement them.

GOAT is itself an agent host. Installing another host's wrapper would give a Swift application an
unsupported harness identity and would still leave GOAT without lifecycle events it can reason
about or test. Conversely, treating MCP tools as the whole integration omits the behavior the user
expects from coding-agent memory.

GOAT also needs a general skills model. A skill is a bounded directory whose `SKILL.md` contains
[Agent Skills](https://agentskills.io/specification) frontmatter and instructions, with optional supporting resources. Skills need clear
ownership and scope. A repository or Pen must not be able to silently enable executable code or
turn on network memory for a user.

The [DeepSeek Harness architecture](https://deepseek-harness.github.io/deepseek-harness/en/reference/)
demonstrates useful extension patterns: a capability has a definition, provider,
and consumer; registrations belong to a scope; unloading reverses its effects; lifecycle events
separate durable facts from live interception; and model tools pass through an ordered policy and
observation pipeline. GOAT needs the same properties without importing Cordis, adopting its package
tree, or replacing GOAT's Swift actors, GRDB persistence, and existing domain protocols.

## Decision

### GOATed extension runtime

The extension framework is named **GOATed**, expanded as **GOAT Extension Dynamics**. Dynamic means
scoped runtime composition and reversible activation, not unrestricted dynamic-library loading.
Its Swift module is `GoatExtensions`, with public vocabulary including `GoatExtension`,
`GoatExtensionContext`, `GoatCapability`, and `GoatRegistration`. Product UI calls contributions
extensions or integrations. GOAT does not expose the Cordis name or API.

The runtime is a typed composition layer over existing GOAT protocols, not a second application
container. Each capability has three explicit roles:

- A definition owns the stable identifier, value protocol, scope rules, and invariants.
- A provider registers one implementation and owns its lifetime.
- A consumer resolves the capability from its current scope without importing the provider.

The first capability families are prompt sections, model tools, skills, memory lifecycle, and turn
observers. Existing inference, persistence, memory, MCP, and UI protocols remain authoritative and
become providers or consumers only where extensibility is needed.

Registrations are scoped to the application, Pen, or live chat session. A child scope can add a
capability but cannot replace an invariant-bearing application capability. Any permitted override
must be explicit in the capability definition and visible in diagnostics. Registration returns a
`GoatRegistration` token. Releasing that token atomically removes the contribution, cancels work
owned by it, and invalidates affected catalogs. No extension leaves callbacks or tools behind after
deactivation.

The Shepherd publishes a small, ordered lifecycle:

1. `turnWillPrepare` allows bounded context providers to prepare material without mutating history.
2. Prompt-section and tool catalogs are snapshotted for one canonical request plan.
3. Tool calls pass through preflight policy, monotonic invariant guards, dispatch, bounded result
   transformation, and immutable result observation.
4. `turnDidPersist` runs only after the completed assistant output is durably stored.
5. `turnDidEnd` reports completion, cancellation, or failure and releases turn-owned work.

Live interceptors cannot rewrite committed transcript facts. Every model-visible extension result
is represented in the canonical request plan with its extension identity and revision, so a debug
trace can reconstruct what the model received. Post-persist work such as Hindsight retention cannot
race ahead of transcript durability.

Extension failures are contained by capability. Optional context and observers degrade with a
redacted diagnostic; invariant guards fail closed; an unavailable required provider prevents only
the dependent feature from activating. The runtime never catches cancellation and continues work
under a dead scope.

M6 loads only GOAT-bundled Swift extensions. Skills are data providers, not executable plugins.
Loading third-party native libraries or processes requires a later signing, compatibility,
permission, update, and sandbox decision. This prevents an extension architecture from silently
becoming arbitrary code execution while preserving stable seams for a future external SDK.

### Native Hindsight integration

GOAT implements a native Hindsight lifecycle adapter at the Shepherd boundary. It does not launch
or install `hindsight-coding-agents`, impersonate another harness, or expose Hindsight as a generic
MCP server row.

The official bank-scoped MCP endpoint may remain the private transport for Hindsight operations.
That transport is an implementation detail behind typed GOAT protocols. It is pre-granted,
restricted to an explicit allow-list, absent from generic MCP Settings, and described in the UI as
a Hindsight server and memory bank. A future official Swift or stable HTTP client may replace the
transport without changing provider, skill, or lifecycle semantics.

For an active and healthy Hindsight route, GOAT owns these behaviors:

- Before the first completed model request for a chat in an app session, fetch a bounded
  knowledge-page roster and perform a low-budget synthesis for the current request. Inject the
  result through `PromptBudgeter`, never by appending unbudgeted text after planning.
- Refresh the bounded page roster on a deterministic turn cadence. The model can explicitly
  search and read pages, retain a document, capture or update an initiative, inspect sync status,
  and request a deeper reflection through native Hindsight tools.
- After a completed assistant turn is durably stored, asynchronously upsert a bounded transcript
  document with a stable chat identity. Retries are idempotent. Cancelled, failed, incomplete, or
  unpersisted turns are never retained.
- For a Pen with a user-owned Git workspace, optionally seed and incrementally ingest bounded Git
  history and a read-only codebase survey. This is off until the user enables it for that Pen.
- Hindsight failure never fails an otherwise valid chat turn. GOAT records a redacted diagnostic,
  marks the route degraded, and continues without Hindsight context or write-back.
- Turning memory off or selecting another provider removes the Hindsight skill, tools, reads,
  injection, ingestion, and writes for that scope. It does not delete server data.

GOAT tracks its integration contract explicitly rather than copying the upstream package's private
implementation. Contract tests cover the supported tool schemas, lifecycle ordering, bounded
payloads, idempotency, failure degradation, and scope resolution.

### Hindsight scope and bank routing

Loose chats use a Global Hindsight bank binding. A Pen may inherit that binding, disable memory,
or select its own Hindsight bank. Chats do not own bank bindings. Moving a chat changes only future
reads and writes to the destination Global or Pen route; it never copies, merges, renames, or
deletes memories.

One configured Hindsight service profile owns the server URL and optional credential. Global and
Pen routes store bank IDs separately from the service identity. This preserves the single visible
Hindsight connection lifecycle from ADR-0035 while allowing per-Pen banks like the upstream
per-repository model. A shared bank remains an explicit user choice, not an accidental consequence
of one process-scoped client.

Existing bank-scoped provider records migrate without server writes: their server and credential
become the service profile, and every scope that referenced the record is bound to its existing
bank. No local or remote memory is copied. Ambiguous or invalid legacy state fails closed and asks
the user to reconnect.

### Native skills

GOAT supports three ownership layers and one selection layer:

1. Built-in skills are read-only application resources. They can be capability-gated.
2. Global user skills live at `~/.goat/skills/<skill>/SKILL.md`.
3. Pen skills live at `<pen>/skills/<skill>/SKILL.md` and are available only to chats in that Pen.
4. A chat stores enable or disable overrides by stable skill identity. It does not copy a skill.

The effective set is enabled built-ins, then enabled Global skills, then enabled skills in the
current Pen, filtered by chat overrides. Moving a chat recomputes that set on its next turn. The
transcript and skill files are untouched.

Skill identity includes source and declared name. GOAT never silently shadows two effective skills
with the same declared name. It reports the conflict and excludes both until the user resolves it.
Built-in names are reserved from user impersonation. Symbolic links, special files, path escapes,
oversized metadata, duplicate keys, malformed UTF-8, and unsupported frontmatter fail closed.

GOAT follows progressive disclosure:

- At planning time, the model receives only bounded skill name and description metadata.
- Native `skill_load` loads the selected `SKILL.md` instructions when the request or user invokes
  it.
- Native `skill_read_resource` reads a bounded regular file within that skill directory.
- Scripts are not executed in the first skills release. Future script execution requires a
  separate permission and sandbox decision; the presence of a `scripts` directory grants nothing.

Skill instructions are untrusted context, never system authority. They cannot change the active
memory provider, enable networking, bypass tool permissions, or override application and user
instructions.

User-invocable Built-in, Global, and Pen skills appear directly below first-class commands in the
searchable composer `/` menu. The composer `+` menu also exposes skills directly. Selecting a skill
resolves its stable identity when the message is sent, so typed text cannot impersonate a skill
that is missing, disabled, or conflicted.

Settings > GOATed > Skills lists locked built-ins and manages the Global ownership layer with
direct actions. Each Pen manages its own scoped skills from the Pen landing page, alongside the
Pen's other resources. Users can open, import into, and remove skills from the appropriate surface.
Imports are copied through a bounded staging directory, revalidated with the runtime parser, and
atomically installed; symbolic links, special files, unsafe names, excessive depth, and oversized
bundles are rejected.
Settings > GOATed > Extensions is the future installation surface, but remains read-only until the
executable extension trust contract is complete.

GOAT ships `/handoff` as a first-class application command, not a skill or model tool. Its hidden,
fixed recipe reviews durable outcomes and returns a compact fenced Markdown handover. The command
suppresses the skill catalog and model tools for that turn, so execution cannot be interrupted by
skill selection or depend on the model inventing a tool call. After the final assistant row is
durably persisted, GOAT writes the checkpoint through the active provider. It still produces the
copyable handover when memory is off or degraded. GOAT, rather than the model, adds the dated
Markdown heading and fence, then shows the provider write receipt with the completed response.

The same post-persist lifecycle automatically upserts completed Hindsight transcripts with one
stable document identity per chat. Repeated turns replace that bounded transcript document rather
than creating duplicate session documents. Local Markdown and LLM Wiki providers remain explicit:
they receive a lifecycle write only for `/handoff`.

Hindsight is the first bundled `GoatExtension` spanning the memory lifecycle, model-tool, prompt,
and skill capability families. The built-in Hindsight companion skill is advertised only when Hindsight is enabled for the
current Global or Pen route and its typed tool contract is available. It explains the native
Hindsight lifecycle and tool surface. The runtime works without relying on the model to remember
automatic recall or write-back, and the skill cannot activate Hindsight by itself.

## Consequences

- Hindsight matches the coding-agent product behavior while remaining native to GOAT's lifecycle,
  concurrency, prompt budgeting, persistence, and privacy boundaries.
- GOAT gains one named extension runtime instead of adding Hindsight-specific callbacks directly to
  the Shepherd.
- MCP remains a supported private wire transport rather than the product abstraction.
- A Pen can use a dedicated Hindsight bank without introducing per-chat memory fragmentation.
- Skills become a general GOAT capability with built-in, Global, Pen, and chat-selection layers.
- Skill instructions load only when relevant, preserving context budget and making provenance
  visible. First-class commands do not produce skill-load events.
- Read-only skills ship before script execution. This is intentionally narrower than the complete
  Agent Skills optional directory surface.
- The integration adds no dependency and makes no unconfigured network request, preserving the
  Herd Guarantee.

## Alternatives considered

Install `hindsight-coding-agents` as if GOAT were Codex or Claude Code (rejected: unsupported host
identity and lifecycle wiring); keep bank MCP tools plus a bundled skill (rejected: a skill does
not provide automatic recall, ingestion, or write-back); replace MCP immediately with bespoke
HTTP calls (rejected: transport replacement is independent of the missing lifecycle); make every
chat own a bank (rejected: fragments shared context and makes chat moves surprising); silently let
Pen skills override Global or built-in skills (rejected: hidden instruction substitution); and
execute skill scripts automatically (rejected: repository-carried code requires a separate trust
model). Adopting Cordis or making every GOAT subsystem a dynamically replaceable plugin was also
rejected: its separation patterns are useful, but GOAT already has typed Swift module boundaries
and security invariants that must remain privileged.
