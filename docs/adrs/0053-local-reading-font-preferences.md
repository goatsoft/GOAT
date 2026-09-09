# ADR-0053: Local reading font preferences

- Status: Accepted
- Date: 2026-09-06

## Context

Appearance exposed only a chat-size slider. Body text, composer highlighting and code used separate system-font calls, so a font selector alone would leave different renderers inconsistent.

## Decision

Use Apple's system text and monospaced fonts by default through AppKit and SwiftUI APIs. Bundle no font files and request no downloads. A compact searchable SwiftUI popover anchored to each font control offers system designs and locally available font faces. Font names in the list and closed control render in the resolved typeface. Clicking a font applies it; keyboard users can select a row and press Return. Escape or clicking outside dismisses it without applying a choice. Code choices require fixed-pitch fonts.

Persist separate chat/composer and code font identifiers and sizes in UserDefaults. Preserve the existing chat-size key; initialize an absent code size from the previous 0.92 chat-size ratio, rounded to whole points. Chat uses 11–28 pt and code 10–24 pt. Clamp invalid or non-finite preferences. Missing fonts resolve to the relevant system font without discarding the saved identifier. Explicit font preferences override themes and the GOAT 1337 experience. The default selection follows optional GTF v1 `fonts.chat` and `fonts.code` PostScript names or system aliases; absent or unavailable fonts fall back to GOAT system fonts. A missing-font notice explains manual installation through Font Book. Sizes stay user-owned.

Use one resolver for AppKit, SwiftUI and MarkdownUI. Apply the preference to chat and native Markdown readers, plain-text fallbacks, reasoning text, composer highlighting, fenced and inline code, and Paddock source views. Composer font changes reapply presentation without replacing the draft or rebuilding the text view. Interface controls remain native system typography. Web preview content owns its own styling.

## Consequences

No additional dependency, redistributed font license, network request or font asset is introduced. The picker reflects fonts available when opened; installing a font in macOS and reopening the picker refreshes the inventory. Font fallback and size validation are covered by app tests. Settings include compact font rows with numeric size entry and steppers, a shared preview and a reset action. Optional fonts extend the unshipped GTF v1 contract, which retains schema-less loading, validates font names without resolving them on the author’s machine, and preserves declarations across theme persistence and export. The JSON Schema and theme-author documentation describe this contract.
