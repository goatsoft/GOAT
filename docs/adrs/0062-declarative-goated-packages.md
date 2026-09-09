# ADR-0062: Declarative GOATed packages

**Status:** Accepted · 2026-09-07 · Extends ADR-0042 with user-installable data packages; executable extension loading remains deferred.

## Context

The User extension tab needs a real import and management flow. The bundled Swift runtime already supplies scope, prompt provenance, skills and revocable registrations. Loading arbitrary native code would bypass those host boundaries. The user approved a ZIP-based `.goated` format with an `extension.json` manifest.

## Decision

Format version 1 carries UTF-8 skills, skill resources, prompt documents and optional inert MCP setup suggestions. A strict manifest identifies the package and declares permissions matching its contents. Unknown fields, unsupported versions and reserved builtin IDs are rejected. Author identity is self-declared, not authenticated. Packages cannot declare executable entry points, host tools, lifecycle code, credentials or permission bypasses.

The GOATed module reads stored and raw-deflate ZIP entries with the system zlib library. It validates central/local headers, supported flags/methods, CRCs, sizes, entry types, ASCII relative paths and case-insensitive uniqueness. It rejects links and executable file modes. No archive entry is extracted to disk or executed. Reviewed archive bytes and parsed content are immutable, eliminating a source-file swap between review and installation. This adds no third-party dependency.

The application owns an actor-backed store under GOAT Home `extensions/packages`. One owner-only JSON record contains original archive bytes, selected Global/Pen scope and enabled state. Writes are atomic through Herd's file store. Load/validation stays off the main actor. A package ID has one installed scope; replacement requires explicit removal and another import review. Export preserves the reviewed archive, excludes host scope/enabled state and never bundles connection credentials added in GOAT.

The review sheet shows identity, version, declared capabilities, permissions, files and Global/Pen scope. Users can export the complete package before installation. Import offers Install Disabled or Install and Enable. Enabling adapts data into the existing GOATed prompt and skill contracts. Prompts carry untrusted extension provenance. Disabling unregisters capabilities and persists the disabled state; already submitted prompt context cannot be withdrawn, so prompt changes apply to future turns. Activation failure leaves an imported package disabled. Existing tool approvals remain authoritative.

MCP suggestions contain a name and either command/arguments or URL, without headers/environment credentials. Set Up opens the existing MCP editor as a new draft, preserving explicit Test/Add and duplicate-name checks. Import, activation and startup do not start these suggested transports. MCP connections added by the user are app-wide and independently managed; removing/disabling a package does not remove those connections or their settings. Package scope applies only to its prompts and skills. Testing a stdio connection runs with ordinary macOS user authority, not Herder confinement; JUDAS still governs managed host transports.

## Bounds and verification

Limits: 8 MiB archive and expanded payload, 1 MiB per file, 256 entries, 240-byte paths, 12 path components; 64 KiB manifest, 16 skills, 16 prompt files totaling 16 KiB, 8 MCP suggestions. The app permits 16 user packages and 32 MiB of installed archive bytes. Review text is rendered only on expansion and capped at 12,000 characters per file, with full package export available. No watcher or recurring scan is added.

Package tests cover stored/deflate archives, malicious paths, links, executable entries, duplicate names, CRC corruption, unsupported methods, truncation, expansion limits, unsupported authority, scoped prompts/skills, resources and revocation. App tests cover immutable review bytes, import without activation, restart state, enable/disable/remove, duplicate imports, export equality and malformed/symlinked managed records. Native previews exercise the review and User list layouts.

## Limits

Unsigned package content can influence model behavior within the selected scope. This is not a trust certification or a sandbox for externally configured MCP programs. There is no marketplace, auto-download, auto-update, executable package host, skill script execution or automatic MCP lifecycle ownership. Binary resources and ZIP64/encrypted/multi-disk archives are unsupported. Installed files remain owner-controlled, not protected from another program with the same user authority. A separate ADR is required for executable extensions.
