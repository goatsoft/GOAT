# ADR-0037: App-wide memory provider and explicit Pen banks

**Status:** Accepted · 2026-09-04 · Refines provider routing in [ADR-0005](0005-memory-architecture.md), [ADR-0033](0033-exclusive-pen-and-global-memory-scopes.md), and [ADR-0036](0036-native-skills-and-hindsight-lifecycle.md)

## Context

The first M6 configuration model exposed both a Global provider and a default provider for new
Pens. Pen pages could then select another provider. This made the product appear to have two
application defaults even though a user chooses one storage system for GOAT. It also made
Hindsight ambiguous: configuring one server and Global bank did not explain when or how a Pen got
an isolated bank.

Global and Pen memory still need strict isolation. A local provider naturally has separate Global
and Pen directories. Hindsight instead has one server with many banks. Requiring users to configure
the same server repeatedly would duplicate credentials and connection health, while silently using
the Global bank for every Pen would violate the isolation promised by ADR-0033.

Existing provider bindings and data must remain recoverable. Changing a provider is not permission
to copy, merge, rename, or delete either local files or server banks.

## Decision

GOAT has one app-wide active memory provider. Memory Settings selects Markdown, LLM Wiki, or one
direct Hindsight service and Global bank. There is no separate new-Pen default and no provider
picker on a Pen.

The master Memory switch remains a hard application-wide gate. Under that gate, every Pen has an
explicit enabled state:

- A Pen without a binding is off. Creating a Pen does not create storage or perform network work.
- Enabling a Pen binds it to the current app-wide provider.
- Disabling a Pen preserves its binding and history without reading, writing, or deleting data.
- Changing the app-wide provider performs no Pen network or file mutation. A Pen whose preserved
  binding belongs to another provider appears off until the user explicitly enables it for the
  current provider. Switching back can resume the preserved binding.

For local providers, explicit Pen enablement routes to that Pen's existing provider-specific local
directory. Global memory remains exclusive to chats outside a Pen.

For Hindsight, one direct service record owns the server URL, optional credential, health, and
selected Global bank. Enabling Hindsight for a Pen ensures a dedicated bank on that service using:

```text
goat-<safe-pen-name>-<full-lowercase-pen-uuid>
```

The safe name is ASCII lowercase, separators collapse to hyphens, and the name is bounded so the
complete bank ID is at most 128 bytes. An empty result uses `pen`. The UUID is the durable identity,
so two Pens with the same display name cannot collide. Once a route exists, renaming the Pen does
not rename its bank.

Provisioning is create-or-reuse and occurs only after the explicit Pen enable action. A new bank
receives GOAT's bounded starter template. An existing bank with that deterministic ID is reused and
never overwritten by the starter template. GOAT then validates the bank-scoped runtime contract
before persisting the enabled binding. A failed create or validation leaves the Pen disabled.

Pen route records contain only the direct service provider ID and bank ID. They do not duplicate
the URL or credential. They are internal routing records and do not appear as additional providers
in Settings. Removing Hindsight removes GOAT's local service and route configuration and credential
but never deletes server banks.

Schema 1's `defaultPenProviderID` remains on disk as a compatibility field until a separately
designed configuration migration removes it. GOAT keeps it synchronized with the app-wide provider,
but it has no independent UI or runtime semantics.

## Consequences

- The provider choice is consistent throughout the app and the redundant new-Pen default is gone.
- Pen memory activation is deliberate and does not cause hidden work at Pen creation or app launch.
- Hindsight gets the same Global/Pen isolation model as local providers without duplicating its
  service configuration.
- Existing data remains untouched. Rebinding selects a future read/write destination; it is not a
  migration.
- A server may retain an orphaned GOAT-created bank after local configuration removal. This is the
  safe result because GOAT exposes no destructive Hindsight operation.
- Deterministic provisioning adds a bounded control-plane call to the first explicit Hindsight
  enable action for each Pen.

## Alternatives considered

**Keep a new-Pen default.** Rejected because it duplicates the app-wide provider selection and
makes a newly created Pen look enabled before the user has opted into its memory lifecycle.

**Use the Global Hindsight bank for every Pen.** Rejected because unrelated Pen context would share
one corpus and violate exclusive scope semantics.

**Ask for a bank on every Pen.** Rejected because repeated setup is noisy and easy to misconfigure.
The deterministic bank remains inspectable on the Pen and in Hindsight.

**Create every Pen bank when Hindsight is configured.** Rejected because a provider selection would
perform surprising network writes for Pens that may never use memory.

**Immediately remove the schema 1 compatibility field.** Rejected for this slice because doing so
requires a configuration migration with its own crash-safety and rollback contract. Hiding it from
product semantics resolves the redundancy without risking existing configuration.
