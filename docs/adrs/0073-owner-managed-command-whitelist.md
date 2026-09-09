# ADR-0073: Owner-managed command whitelist

Status: Accepted · 2026-09-08

## Context

The user wants practical shell permissions for tools such as npm and Git, including custom scripts, dependency installs and remote access. Fixed argument/subcommand lists would impede normal project work. ADR-0070 already provides executable-wide approval but only adds entries through a running command's dialog.

## Decision

The Pen's Command permissions section supports Add tool, Edit, Remove and Reset. An owner can enter an executable name or path, check the resolved executable, select one chat or all chats in the Pen, and separately allow requested network access. All arguments and child processes remain covered by the executable grant within the existing Pen confinement. No npm-script or Git-subcommand allowlist is introduced.

Checking resolves metadata and validates the workspace without running the executable or authorizing network access. Save revalidates the reviewed executable and physical workspace and rejects stale permission revisions. Changed binaries, replaced folders, removed entries and resets cannot be overwritten by an older review. Validation errors remain separate from persistence authority failures. Executable paths are optional stored metadata so older entries remain readable.

Refining ADR-0070's exact network-mode matching, a network-enabled grant also authorizes offline calls of that executable. An offline grant does not authorize network requests. The launched command's network flag still determines its actual sandbox: allowing a tool to request networking never silently gives an offline command networking. JUDAS can deny networking regardless of the whitelist. Network permission covers outbound connections generally, not selected domains.

Permissions are additive: a Pen-wide grant applies to every chat, and a chat-only grant cannot narrow it. The editor explains this. Owner edits replace their selected entry and merge equivalent executable/scope entries. Existing action dialogs continue to add grants. Removing grants affects future launches; stopping a running command remains a separate action.

## Consequences

Users can allow npm, Git and custom tools without enumerating project scripts. Dependency installation is supported with network approval. The UI shows resolved paths and scope to make the granted capability reviewable. A command or network capability does not instruct the agent to publish changes; the user's task remains authoritative. Existing filesystem restrictions, credential isolation and non-interactive command limits remain.

## Alternatives considered

- Enumerate npm scripts and Git subcommands: rejected by the user as too restrictive.
- Infer network permission from executable names: child programs and custom scripts make this unreliable.
- Run a program to validate it: introduces unnecessary side effects during configuration.
- Treat a network-enabled grant as requiring network on every call: incorrectly couples capability with execution mode.
