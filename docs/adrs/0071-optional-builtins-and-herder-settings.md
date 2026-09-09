# ADR-0071: Optional built-ins and Herder settings

Status: Accepted · 2026-09-08

## Context

Extensions expanded only from their caret. Herder and Hindsight were displayed as locked built-ins even though users need control over their capabilities. Herder's description still predated its command runner. This refines ADR-0036 and ADR-0070.

## Decision

Use a shared disclosure style with one accessible button covering the caret, title and header space for built-in and user extensions. Child controls remain separate.

Herder and Hindsight default to enabled and persist app-wide availability in host preferences. Herder offers separate native-write and shell switches plus a default command timeout, initially 120 seconds and bounded to 1–600 seconds. Explicit command timeouts retain the same hard ceiling. Search and reading remain available when native writes are off. Read-only use requires turning off both writes and shell because approved commands can write files. The router and provider enforce availability; hiding a schema alone is insufficient. Existing file grants and executable whitelists remain scoped to the chat/Pen and do not expand when a capability is enabled.

Hindsight off removes its runtime registration and provider choice, disables reconnect/selection/control entry points, disconnects managed sessions, and suppresses context, tools, companion skills and retention. Saved configuration, keys, selected Global/Pen banks and server data remain untouched. Existing Hindsight selections pause with an explanation. No automatic local fallback silently changes where memories are written. Re-enabling reconnects saved selected routes.

Skills remains required capability infrastructure. JUDAS is a required host service, not a GOATed extension; its informational row is labelled Required core and has no switch. Policy configuration remains in JUDAS settings. Hitch and Pronk retain their optional controls and defaults.

Built-in switches and Herder configuration are unavailable during an active chat turn. Existing actions finish under their established authority. This UI constraint avoids interrupting running commands or withdrawing an approval mid-action. Settings apply to subsequent turns. Disabling preserves remembered approvals; owners manage/reset those explicitly on the Pen page.

## Consequences

Owners can opt out of coding or Hindsight without deleting data. Required enforcement cannot be disabled through an extension switch. Herder configuration does not remove filesystem, approval, network or execution limits. Commands are still non-interactive, with detached services unsupported.

Already-submitted Hindsight server work cannot be rolled back by disabling its extension. The off switch prevents new work and disconnects operational clients; it does not delete server jobs or records.

## Alternatives considered

- Keep every built-in locked: prevents reasonable capability choices.
- Treat JUDAS as optional: violates the host enforcement boundary.
- Switch Hindsight users automatically to local memory: silently changes persistence destination and obscures existing banks.
- Call the write switch read-only while shell stays enabled: misleading because commands can modify workspace files.
