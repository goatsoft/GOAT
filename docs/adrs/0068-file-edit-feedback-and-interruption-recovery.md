# ADR-0068: File edit feedback and interruption recovery

Status: Accepted, 2026-09-08. Refines ADR-0003, ADR-0061, and ADR-0066.

## Context

A coding chat repeatedly tried to create existing files, submitted three identical replacements that were reported as saved, and guessed an existing file's contents. A development restart interrupted the next response. Startup sealed its empty checkpoint without explaining what happened.

## Decision

Reject byte-identical old_text/new_text in pen_edit_file during preparation, before approval or filesystem mutation, with an explicit "No change" result. Distinguish missing matches from ambiguous matches and direct the model to read the current file and copy an exact unique fragment. File-exists failures direct the model to read and edit, preserving create-only writes. Never guess a replacement or silently overwrite existing content.

Expand tool and host guidance to prefer focused edits, skip already-correct content, and preserve completed work after follow-up instructions. No-op edits do not count as progress. Tool permissions, confinement, atomic saves, and stale-approval checks remain intact.

At startup, recover incomplete response rows and unfinished tool results on each chat's last assistant response, including when a queued Lead follows it. Seal saved text without attaching an error to the original message, preserve completed tool results, and mark unfinished results as unknown outcomes that require inspection before retrying. Append one separate, visible interruption notice per affected chat in the same database transaction. Reopening again must not duplicate notices. Completed responses remain unchanged.

## Consequences

An unchanged edit can no longer masquerade as a saved modification. The model receives concrete recovery instructions, but this does not guarantee it will follow them. Interrupted work is visible while completed tool evidence remains in prompt history. GOAT cannot know whether a tool finished between executing a mutation and persisting its result; it reports uncertainty instead of assuming failure or retrying automatically.

Historical messages already sealed by an older build are not retroactively classified as interrupted. Development restarts must check for active work first; do not restart a busy app just to install a change.

## Alternatives considered

Treating no-op edits as successful writes falsely signals progress and needlessly rewrites files. Attaching an error to an interrupted tool response would remove its successful results from model history and risk repeating completed actions. Automatically retrying an interrupted write can duplicate side effects.
