# ADR-0038: Local presentation gate and professional interface

**Status:** Accepted · 2026-09-05 · Refines [0030](0030-corporate-default-and-unlockable-1337-experience.md)

## Context

The user approved the professional interface pass and supplied light/dark figurehead assets.
Existing mascot views, menus, reaction effects, and icons did not yet share an unlock gate.
The user explicitly requested typing `1337` in About, simplifying ADR-0030's arming chord.

## Decision

`PresentationPreferences` owns a persistent, local unlock and a separately switchable active
presentation. It fails closed: an enabled preference without an unlock does nothing. Only
About recognizes the four digits, within ten seconds, while its window is key and the app is
active. Losing window focus, invalid input, or timeout resets capture. Pasted strings and key
repeat cannot complete it. There is no global keyboard hook or storage of typed input.

Unlocking is idempotent, activates the pack, and selects the hidden built-in theme. A progress
ring and brief confirmation acknowledge it. System appearance or the unlocked presentation
switch restores professional presentation while retaining the unlock. No model, prompt,
memory, rating, permission, or tool behavior depends on this preference.

All mascot renderers have a professional light/dark figurehead fallback. Effort icons,
reaction effects, thinking bubbles, playful copy, and alternate icons are gated. About cycles
poses in order only with the presentation active. Motion additionally respects the animation
preference, Reduce Motion, and scene activity. The professional thinking label has a bounded
30 Hz theme-gradient sweep, with a static fallback.

The main window, Settings, About, and shared dialogs apply the same tint and accent environment.
AppKit editors receive themed carets and selection colors. System follows light/dark changes;
professional icons follow the resolved appearance unless the user selects Light or Dark.
The canonical packaged icon uses the existing professional Light artwork.

## Consequences

Public user documentation and landing-page copy use the professional identity and do not
advertise the unlock. Historical ADRs retain implementation decisions for maintainers.
The presentation flag is a preference, not an authorization or security boundary.
Built-in light-theme accents are darkened for contrast; community themes remain user data.
Window translucency and the known fullscreen compositor limitation are unchanged.

## Alternatives considered

Independent flags in each view risk missed surfaces and inconsistent startup behavior.
Gating actual extension tools would alter functionality, so only their display branding changes.
Remote flags and global keyboard monitors are unnecessary for a local presentation preference.
