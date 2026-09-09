# ADR-0030: Corporate default with an unlockable 1337 experience pack

**Status:** Accepted · 2026-09-01 · Refines [ADR-0011](0011-liquid-glass-and-window-translucency.md), [ADR-0013](0013-themes-as-data.md), and [ADR-0022](0022-theme-format-and-community-themes.md)

## Context

GOAT's visual work mixed two product identities. The underlying macOS application is a serious local AI workspace, but prominent neon treatments, goat copy, emoji, and mascot motion made the playful 1337 identity look like the default product. That narrows the audience and makes ordinary work feel less calm than the current light and dark icon direction.

The theme system already treats colour tokens as data and keeps an unlockable 1337 theme. Colour alone is no longer enough to describe the intended easter egg. The complete experience includes alternate app icons, chat decorations, animations, bylines, and selected microcopy. These must remain optional, local, accessible, and unable to change application semantics.

Kid 0.1.0 must ship with the intended identity rather than defer the correction to the later M7 polish release.

## Decision

### Professional by default

GOAT launches in **System**, following macOS appearance through a restrained corporate Light or Midnight token set. The standard experience uses:

- the current professional light and dark app-icon family;
- SF Pro for application chrome and SF Mono only for code;
- monochrome interface symbols with limited semantic colour;
- conventional labels such as **Generate**, **Negative prompt**, and **Save preset**;
- quiet selection, focus, progress, and streaming treatments; and
- deadpan, actionable copy throughout normal workflows.

Pasture, Light, Midnight, and community themes remain available, but they change visual tokens only. System is the first-run default. The 1337 option is absent from Appearance until it is unlocked.

### About owns the easter egg

The command palette is not required to discover or unlock 1337. With the About window frontmost, pressing **Option-Command-G** arms a short local digit capture. Entering `1337` within ten seconds unlocks the pack. The About view gives no permanent instruction or visible input before the chord.

Unlocking is idempotent and stored as a local preference. It reveals **GOAT 1337** in Appearance, shows one celebratory confirmation, and selects it for the current user. Afterward it behaves like any other selectable appearance and the user can return to System immediately. No network, account, date, or remote flag participates.

The exact chord may change before implementation if it conflicts with a macOS reserved command. The invariant is that the unlock is About-scoped, deliberate, keyboard-driven, and does not depend on M7's command palette.

### 1337 is a presentation pack

GOAT 1337 is implemented as a trusted built-in `ExperiencePack` layered over the existing `ThemeSpec`. It can select:

- the 1337 colour and typography theme;
- alternate Dock, About, and in-app icon assets;
- chat-role glyphs and decorative emoji;
- mascot sprite sheets and bounded interface animations;
- optional completion sounds; and
- alternate bylines, empty-state copy, labels, and other non-critical microcopy.

The pack cannot alter engine requests, prompts, persisted message text, permissions, errors, destructive confirmations, database records, keyboard semantics, layout measurements, or feature availability. Decorations are derived at render time and never inserted into the transcript. Error and security copy always use the professional catalog.

Community GTF themes remain data-only and cannot provide executable behavior, sounds, copy catalogs, app icons, or arbitrary animation. Experience packs are trusted built-ins until a separate signed package decision exists.

### Motion, assets, and accessibility stay bounded

Reduce Motion disables non-essential movement and replaces it with static 1337 art. Reduce Transparency and contrast requirements continue to apply through semantic tokens. VoiceOver labels describe the control or content, never its decorative goat.

Animation assets decode off-main, occupy a fixed final layout, pause when hidden or when the app is inactive, and allow at most one prominent looping mascot animation per window. Transcript rows do not run independent loops. Sprite sheets or frame sequences are preferred over multiple concurrently decoded GIFs. The performance budgets from ADR-0028 apply equally to the hidden pack.

The default and 1337 icon families are bundled and deterministic. Selecting an experience updates the runtime Dock icon where macOS permits it; packaging still has one canonical Finder icon and must remain correct if runtime icon replacement is unavailable.

### Kid scope

This identity pivot ships in **Kid 0.1.0 alongside M6 memory**. It is companion release work, not part of the memory protocol. The Kid exit gate requires:

1. a clean profile launches in professional System appearance;
2. 1337 is absent from Appearance before unlock;
3. the About-scoped sequence unlocks locally and survives relaunch;
4. switching back to System restores professional icons, copy, and motion without altering content; and
5. Reduce Motion and the ADR-0028 rendering budgets hold in both experiences.

M7 retains the broader command palette, onboarding, empty-state, and accessibility polish. It no longer owns the 1337 unlock.

## Consequences

- GOAT presents as a credible professional IDE on first launch while retaining a strong hidden personality for users who opt in.
- Theme selection and experience selection become related but distinct concepts. `ThemeSpec` remains the public colour format; `ExperiencePack` coordinates trusted presentation assets.
- Existing goat decorations and neon microcopy must move behind the 1337 gate or be removed from the default catalog.
- Every alternate string and asset needs a professional fallback. Screenshots, release notes, and onboarding use System unless they explicitly demonstrate the easter egg.
- Kid gains a bounded presentation migration beside M6. Memory sequencing remains unchanged.

## Alternatives considered

Keep the GOATed look as the default (rejected: too loud for the primary professional audience), reduce 1337 to a colour theme (rejected: does not cover icons, emoji, motion, or copy), unlock through the command palette (rejected: makes Kid depend on M7 and turns an easter egg into a discoverable command), let community themes supply experience assets (rejected: expands security, performance, and packaging surface), and store decorated transcript text (rejected: presentation would corrupt user content and exports).
