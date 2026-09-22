# ADR-0094: Pure-Swift syntax highlighting and tool diff presentation

Status: Proposed · 2026-09-22

Refines [ADR-0010](0010-paddock-artifacts.md), [ADR-0074](0074-grouped-transcript-tool-activity.md)
and [ADR-0091](0091-content-bounded-transcript-layout.md). Tracked in
[issue #50](https://github.com/goatsoft/GOAT/issues/50).

## Context

Code block syntax highlighting currently relies on `HighlightSwift`, which runs `highlight.js`
through JavaScriptCore. This introduces JavaScript runtime overhead, memory footprint, and
visible flashing during token streaming. Furthermore, code fence parsing can produce
unstable highlights when tokens arrive incrementally.

In addition, file tool operations (`pen_edit_file`, file creation, and deletions) output
raw JSON strings containing `old_text` and `new_text`. Reviewing changes in inline tool
cards and permission approval sheets requires reading escaped JSON strings, rather than
a clear, unified diff showing line modifications, additions, and deletions.

All project dependencies must adhere to the Herd Guarantee (100% offline, local-first,
no telemetry) and must be licensed under the MIT license. An alternative highlighter,
`SwiftHighlight`, was evaluated but rejected due to its BSD-3-Clause license.

## Decision

### 1. Pure-Swift Syntax Highlighting
- Replace `HighlightSwift` (JavaScriptCore) with `HighlightKit` (`goatsoft/HighlightKit`),
  a pure Swift syntax highlighting engine licensed under the MIT license.
- Syntax tokenization and attributed string generation run on an isolated background actor,
  preventing main-thread stalls during transcript layout and scrolling.
- Exact source preservation: on unknown language or tokenization fallback, the original
  raw text is preserved without character loss or mangling.
- Full integration with GOAT's design system: light and dark theme palettes, token styles,
  and user reading font preferences (ADR-0053) are mapped to syntax tokens.
- Streaming stability: active streaming code blocks render plain monospaced text to eliminate
  flicker and churn; rich syntax highlighting is applied when the message or fence settles.

### 2. Native Tool Diff Presentation
- Introduce a dedicated, native diff presentation view for file modifications (`pen_edit_file`,
  file creation, and deletion).
- Parse modifications into structured hunks displaying deletions (- in red/warning) and
  additions (+ in green/accent) with monospace line numbers and unified context.
- Apply the diff presentation in both:
  1. Inline transcript tool call cards (`ToolCallDetails`), replacing raw `old_text` / `new_text`
     JSON representations.
  2. Pre-execution permission approval sheets (`PermissionSheet`), allowing the user to clearly
     review exact changes before approving or denying file writes.
- Add an owner preference in Settings (Appearance / Bleet) to toggle between the structured
  diff view and the raw JSON payload view.

## Consequences

- Completely eliminates JavaScriptCore/WebKit runtime dependencies for code highlighting.
- Maintains strict MIT license compliance across all Bleet dependencies.
- Eliminates visual flicker during streaming model responses.
- Significantly improves user experience when approving file modifications and inspecting tool
  history in conversation transcripts.

## Alternatives Considered

- **Keep JavaScriptCore `HighlightSwift`**: Carries unnecessary runtime overhead and causes
  visual flashing during streaming updates.
- **`SwiftHighlight`**: Uses a BSD 3-Clause license, conflicting with GOAT's MIT licensing policy.
- **`swift-syntax`**: High quality but restricted exclusively to the Swift language; GOAT requires
  polyglot syntax highlighting for dozens of development languages.
- **Embedded WebKit / Monaco Editor for Diffs**: Heavyweight process model, slow initialization,
  and incompatible with GOAT's native SwiftUI rendering and keyboard navigation standards.
