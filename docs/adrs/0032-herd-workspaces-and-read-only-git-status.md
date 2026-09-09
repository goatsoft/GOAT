# ADR-0032: Herd workspaces and local Git status

**Status:** Accepted · 2026-09-03 · Refines [ADR-0019](0019-pens-as-folders.md) and [ADR-0026](0026-main-actor-publication-and-worker-io.md)

## Context

ADR-0019 made a Pen an inspectable GOAT-owned folder with instructions, memory, and references.
That remains useful application state, but it is not necessarily the folder in which a person does
their work. A software Pen needs a user-owned project folder, while research and personal Pens
may need no folder at all. Copying a repository into GOAT Home, putting memory inside a repository,
or treating every attached folder as prompt context would violate ownership and exhaust small local
model context windows.

Git can give a useful, immediate signal for a bound project folder. SwiftUI supplies native
presentation primitives, but no public Git repository status API. Manually interpreting `.git`
would mishandle valid layouts such as linked worktrees.

## Decision

### Pens optionally bind one user-owned workspace

A Pen persists an optional absolute `PenWorkspace` path and bookmark in `project.json`. GOAT's
existing Pen folder remains the control sidecar for instructions and memory. A workspace is never
silently moved, merged, populated with GOAT metadata, or deleted when its Pen is deleted.

The global **Default Herd location** is a convenience for creating future folders, not a policy.
It defaults to `~/Projects`, is user-selectable in Settings, and changes no existing binding. New
Pens offer three explicit choices: create a folder in the Herd, bind an existing folder, or create
no workspace yet. Creation slugifies the Pen name and uses `-1`, `-2`, and later suffixes rather
than adopting a conflicting folder.

Folders and references are not prompt context. The existing Pen brief remains explicit system
content, while memory remains under its deterministic budget. Future user-selected chat worksets
and permissioned workspace tools must declare their own bounded context cost rather than reading a
workspace recursively.

### Git is local, status is read-only, and initialization is opt-in

The Pen header shows the current branch and a compact clean, changed, or conflict state. Its
workspace section and status popover reveal staged, modified, untracked, conflict, and local
ahead/behind counts. The sidebar can later use the same compact status without giving each chat a
misleading branch badge. A chat does not own the branch because every chat in a Pen shares the
bound working folder.

GOAT invokes the system `/usr/bin/git` through Foundation `Process` on a worker actor. It calls
`rev-parse --show-toplevel`, `status --porcelain=v2 --branch`, `--version`, and read-only
configuration queries for status. A visible **Initialize Git repository** option appears only
when Git is available while creating a new folder, and only that explicit selection can call
`git init --quiet` in the newly created folder. It adds no contents, creates no remote, and does
not require a configured identity. It sets `GIT_TERMINAL_PROMPT=0`, clears environment variables
that could redirect the working tree, uses no network command, and never fetches, stages, commits,
switches, or merges. Git's porcelain output is the parser contract, preserving Git's own semantics
for worktrees and detached HEADs.

Settings reports whether Git is available and whether the optional global name and email identity
are configured. Missing Git is an integration warning, not an application failure. A non-Git
workspace quietly reports that it is not a repository. Identity is advisory until GOAT offers a
user-authorized write action.

## Consequences

- Pens can be useful local workspaces without coupling GOAT's memory files to repositories.
- Existing Pens load as unbound, so this adds no migration or destructive file operation.
- Workspace binding, Git probing, and folder creation stay off the main actor. UI state receives
  only Sendable result values.
- Folder paths and Git status consume no model tokens. No repository contents enter a prompt by
  default.
- The user-facing Herd root and `PenWorkspace` form a reusable core for a future GOAT CLI or API,
  without duplicating folder and Git behaviour outside the app.

## Alternatives considered

Make the GOAT Pen sidecar the project root (rejected: it places managed memory and metadata in a
user repository), copy external folders into GOAT Home (rejected: duplicates data and obscures
ownership), inject a folder tree into every request (rejected: high and unpredictable token cost),
parse `.git` directly (rejected: incomplete worktree semantics), and use Git status as a chat-row
badge (rejected: one mutable workspace state is shared by the Pen, not owned by an individual
chat).
