# ADR-0094: Pure-Swift syntax highlighting and tool diff presentation

Status: Accepted · 2026-09-23

Refines [ADR-0010](0010-paddock-artifacts.md), [ADR-0074](0074-grouped-transcript-tool-activity.md)
and [ADR-0091](0091-content-bounded-transcript-layout.md). Tracked in
[issue #50](https://github.com/goatsoft/GOAT/issues/50).

## Context

Code block syntax highlighting previously relied on `HighlightSwift`, which executed `highlight.js`
through JavaScriptCore. This introduced JavaScript runtime overhead, memory footprint, and
visible flashing during token streaming. Furthermore, code fence parsing could produce
unstable highlights when tokens arrived incrementally.

In addition, file tool operations (`pen_edit_file`, file creation, and deletions) output
raw JSON strings containing `old_text` and `new_text`. Reviewing changes in inline tool
cards and permission approval sheets required reading escaped JSON strings, rather than
a clear, unified diff showing line modifications, additions, and deletions.

All project dependencies must adhere to the Herd Guarantee (100% offline, local-first,
no telemetry) and must be licensed under the MIT license. An alternative highlighter,
`SwiftHighlight`, was evaluated but rejected due to its BSD-3-Clause license.

## Decision

### 1. Pure-Swift Syntax Highlighting and Streaming Coalescing
- Replace `HighlightSwift` (JavaScriptCore) with `HighlightKit` (`goatsoft/HighlightKit`),
  a pure Swift syntax highlighting engine licensed under the MIT license.
- Syntax tokenization and attributed string generation run on an isolated background actor
  (`CodeSyntaxHighlighter`), preventing main-thread stalls during transcript layout and scrolling.
- Exact source preservation: on unknown language, cancellation, or tokenization mismatch,
  the original raw text is preserved immediately as plain text without character loss or mangling.
- Full integration with GOAT design system: light and dark theme palettes, token styles,
  and user reading font preferences (ADR-0053) are mapped to syntax tokens.
- Progressive streaming with prefix coalescing: active streaming code blocks highlight
  progressively rather than waiting for generation to settle. Rapid token arrivals are coalesced
  before dispatching highlighting passes, avoiding per-token layout thrashing while eliminating
  flashing between unhighlighted and highlighted states.

### 2. Code Block Scrolling and Word Wrap
- Word wrap toggle: Users can toggle between horizontal scrolling and soft word wrap.
- Suppress line numbers on word wrap: When word wrap is active, the monospaced line-number
  gutter is suppressed in `HighlightedCodeView` because wrapped soft lines do not correspond
  1:1 with fixed gutter row heights.
- Themed overlay scrollbars: AppKit native horizontal scrollers are suppressed via
  `ScrollerDisablingView` to prevent conflicting with Caprine-themed hover scrollbars,
  even when macOS system preferences mandate visible scrollbars.

### 3. Native Tool Diff Presentation, LCS Bounding, and Caching
- Dedicated unified diff view: Introduce `ToolDiffView` for file modifications (`pen_edit_file`,
  file creation, and deletion).
- Parse modifications into structured hunks displaying deletions (- in red/warning) and
  additions (+ in green/accent) with line numbers and unified context.
- Guard against runaway LCS: If input text blocks exceed 500 lines per side, quadratic
  Longest Common Subsequence computation is bypassed in favor of sequential deletion and
  addition hunks.
- Bounded rendered diff rows: Rendered diff lines are capped at 500 rows. When total diff
  lines exceed this budget, a truncation notice is displayed with a toggle action to inspect
  the raw JSON payload.
- Diff caching outside body: Parsed diffs are memoized via `NSCache` in `ToolDiffParser`
  and resolved outside SwiftUI view `body` evaluations (`ToolCallDetails`), avoiding
  unnecessary re-parsing and diffing during view layout or re-renders.
- Design token routing: All diff typography and colors route strictly through Caprine design
  tokens (`Caprine.Activity` fonts and semantic palettes).
- Diff presentation surfaces:
  1. Inline transcript tool call cards (`ToolCallDetails`), replacing raw `old_text` / `new_text`
     JSON representations.
  2. Pre-execution permission approval sheets (`PermissionSheet`), allowing the user to clearly
     review exact changes before approving or denying file writes.
- Add an owner preference in Settings (Appearance / Bleet) to toggle between the structured
  diff view and the raw JSON payload view.

### 4. Transcript Endless Paging and Reader Viewport Ownership (Refines ADR-0091)
- Bounded paging budgets: Transcript paging via `TranscriptWindow` strictly enforces both
  message capacity (40 items) and source content budgets (16KB). Paging earlier or later evicts
  the opposite edge while preserving the reader visible anchor.
- Reader viewport ownership: Viewport ownership remains with the reader when scrolled up or
  paging earlier/later messages. Paging into the final page preserves reader position and does
  not snap to bottom unless the reader is already following at the bottom. Single-shot
  scroll-to-bottom snapping is preserved when requested.

## Consequences

- Completely eliminates JavaScriptCore/WebKit runtime dependencies for code highlighting.
- Maintains strict MIT license compliance across all Bleet dependencies.
- Eliminates visual flicker during streaming model responses with responsive prefix coalescing.
- Significantly improves user experience when approving file modifications and inspecting tool
  history in conversation transcripts.
- Prevents main-thread layout recursion and runaway LCS execution on massive tool diffs.

## Alternatives Considered

- **Keep JavaScriptCore `HighlightSwift`**: Carries unnecessary runtime overhead and causes
  visual flashing during streaming updates.
- **`SwiftHighlight`**: Uses a BSD 3-Clause license, conflicting with GOAT MIT licensing policy.
- **`swift-syntax`**: High quality but restricted exclusively to the Swift language; GOAT requires
  polyglot syntax highlighting for dozens of development languages.
- **Embedded WebKit / Monaco Editor for Diffs**: Heavyweight process model, slow initialization,
  and incompatible with GOAT native SwiftUI rendering and keyboard navigation standards.

## Amendment: Theme-derived syntax palette (2026-09-26)

Tracked by [#60](https://github.com/goatsoft/GOAT/issues/60) (A5). Section 1 mapped only the light
and dark schemes to syntax tokens, so every theme shared Xcode's colours.

- `SyntaxPalette` derives the token colours from the active `ThemeSpec`: keywords from the accent,
  strings from the second accent, numbers and literals from the glow, comments from the muted ink,
  types and titles from the tint, and plain text from the ink. Diff additions and deletions use the
  semantic success and danger tokens.
- Each colour moves toward the theme's ink until it reaches 4.5:1 contrast on the theme's
  background (DESIGN.md §10). A colour that already does is used unchanged.
- The window root provides the palette as an environment value from the active theme, so System
  follows its light or dark theme. Views outside a themed window keep the Xcode palette.
- The palette's colours are part of every highlight cache key (the shared highlight cache, prepared
  code text, reasoning code and Vue code), so a theme change never serves another theme's colours.
  During a live change the previous colours stay on screen until the new highlight is ready; after
  eviction the source shows until it is prepared again.
