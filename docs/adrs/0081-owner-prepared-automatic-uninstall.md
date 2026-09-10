# ADR-0081: Owner-prepared automatic uninstall

Status: Accepted

Date: 2026-09-10

## Context

The owner requested automatic app removal with independent choices to keep macOS preferences, connections, Pens, local memory, customisations and chats. A shell command that removes a running app and live database cannot preserve those choices reliably. The review-only Settings prototype also repeated the same parent paths and truncated its entry button.

## Decision

Settings displays a storage tree and an uninstall review with Partial uninstall selected by default. This keeps GOAT Home data and chats/attachments while leaving macOS preferences/window state unchecked. Uninstall all clears every keep option; selecting Partial uninstall restores the default selection. Individual keep options remain editable, and retaining any category returns the mode to Partial uninstall. Entering the uninstall tab starts with the partial default. The separate local-data removal preview is removed; category choices live in uninstall, alongside direct preference reset ([ADR-0082](0082-direct-preference-reset.md)). Removing Pen metadata also selects chats and attachments; keeping chats preserves Pen metadata. External workspaces, referenced project files, model engines and remote memory are excluded. Only this app copy and an explicitly selected, signature-checked `goat` CLI can be removed.

After an explicit confirmation, the app copies its signed executable into an owner-only temporary directory and launches its fixed `--goat-uninstall-helper` mode with a private typed request. The entry point dispatches this mode before creating AppModel or opening storage. There is no shell, privileged helper, launch agent, arbitrary command or network operation. The copied executable retains its signature; the JUDAS source check allows only this reviewed local process-launch site.

The helper waits for its exact launching process to exit. Preparation checks startup, active turns, queued Lead, extension changes and pending approvals. It does not terminate GOAT or claim to drain every view-owned task. The owner must finish imports, commands and other work and then quit normally. A prepared request can be cancelled while GOAT is open and expires after one hour. This deliberately avoids forcing shutdown during active work.

Normal launches hold a per-user shared maintenance lock before any app state is created. After the parent exits, the helper takes that lock exclusively and refuses cleanup if another GOAT copy is running. New versions cannot open storage during cleanup. Older releases do not implement this lock; visible older copies are checked, and users must not launch an old version during maintenance.

The helper validates captured root identities and builds a fresh inventory after process exit. It uses recognised config filenames and Pen metadata files, and selected memory, skills, themes, extensions and attachment categories. It never moves shared roots, follows symbolic links, removes unknown top-level entries or traverses an external workspace. Selected data moves into a private recovery directory using same-volume renames, with a planned manifest and a completed-move journal. Cross-volume recovery destinations are rejected before any source move. Empty directories and linked entries remain in place.

When requested, preferences are backed up as a private plist and cleared through the macOS preferences API after exit. Saved window state is handled separately from the home and database. App and CLI copies move to macOS Trash after data handling. Failures stop further moves and leave a recovery report. The helper removes its private executable/request directory when it finishes; it never removes the recovery folder.

## Consequences and validation

Automatic uninstall is recoverable, not secure erasure. Recovery can contain credentials and conversations, and restoring it requires a compatible app version, closed storage and review before overwriting files. A custom home remains recorded in the recovery request even when preferences are removed. Retained Pen memory remains in its original folders when Pen metadata is removed.

Tests cover retained categories, linked targets, unknown files, nested workspaces, live-host refusal, changed roots, database companions, preference-domain isolation and partial recovery. Native review checks cover storage grouping, keep selections, confirmation and the Settings entry layout. Helper process checks use disposable fixtures; they must never uninstall the maintainer's active app. Release qualification must verify the copied signed executable under the final notarized distribution identity before publishing this functionality.
