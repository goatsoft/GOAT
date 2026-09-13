# ADR-0074: Visible agent progress and expandable tool details

Status: Accepted · 2026-09-08 · Amended 2026-09-13 · Refines ADR-0058

The 2026-09-13 amendment replaces this ADR's original whole-message grouping decision. It also supersedes ADR-0089's elapsed-time-based “prefill” label. Storage, prompt construction, permissions and tool execution remain separate from this presentation decision.

## Context

Coding agents produce consecutive tool rounds. The original implementation moved an assistant message into a collapsed activity group when its structured tool events arrived. That hid narration and reasoning that had just been visible. Opening the group then exposed another reasoning disclosure. The user could see a spinner and action count while losing the useful explanation of what the agent was doing.

The waiting label also inferred prefill after ten seconds without output. A silent client cannot distinguish queueing, model loading, prompt evaluation or a stalled connection. Renaming a spinner did not provide that missing information.

## Decision

### Keep the conversation visible

Each assistant message retains its own row identity and view ancestry throughout streaming, tool-call arrival, execution and completion. Adjacent assistant rounds share alignment and omit repeated avatars, forming a continuous response. Never reparent a message because its tool-event array becomes nonempty. User and Lead messages remain visible boundaries.

Render the model's emitted reasoning and narration outside tool disclosures. Reasoning is visible by default with a subtle vertical rule and readable text. A bounded recent excerpt keeps long traces manageable; “Show all reasoning” reveals the full content in the transcript without a nested scroll view. The owner can collapse reasoning explicitly. Token arrival, tool events and completion must not reset those choices.

### Keep tool details expandable

Tool steps stay in chronological order as compact, descriptive rows. Their arguments and results are collapsed independently. Adjacent tool-only steps form a visual list; they never absorb narration or reasoning between steps. No second outer disclosure hides the assistant message.

Consecutive tool-only rows share a subtle vertical trunk with short branches, including across assistant rounds. An isolated action has no dangling branch. The connector represents transcript order, not a claim of concurrent execution. Narration, reasoning, user guidance and host errors break the connector. Whitespace-only text does not create a response or reasoning block. Tool rounds reserve no invisible response-footer space and adjacent tool-only rounds have no inter-message gap; response details remain available through their context menu. Reasoning display removes empty boundary lines while preserving internal spacing, code indentation and stored source. The active progress row sits close beneath the sequence. Stable message identities and independent disclosures remain unchanged.

Native actions show a path, search query or command. Arbitrary external actions retain server/tool identity. Multiple memory actions in a round use one expandable action-count summary with visible failure, denial and unresolved counts. Expanding shows the chronological tree of individual actions; surrounding reasoning remains visible. Memory labels identify the page, source or query without including stored body content. The label text alone opens its inspection popover, which supports outside-click dismissal, Escape and an explicit close button. Pending, failed, denied and missing-result states remain distinguishable without opening raw payloads. Host errors remain visible. No unresolved action is represented as successful.

Response Details appears only when provenance or a concrete provenance-decoding failure is available. Live persistence checkpoints also refresh the in-memory inspection record, including lifecycle changes; historical records remain usable after reload. Omit unknown fields and empty sections, and offer Copy Report only for an actual record. Requested sampling values describe the client request, not proof of engine-effective settings.

### One live progress row

At the latest transcript edge, show one persistent status row during an active turn. Its label follows observed activity: waiting for response, thinking, writing a response, preparing a tool call, using a named tool, waiting for permission, retrying a response, or preparing the next step. Incoming reasoning can resume after prose; the phase must follow newly received content rather than testing whether prose has ever appeared.

Show one current activity label, spinner (or permission icon) and elapsed timer. The 2026-09-14 refinement removes the last-completed action and last-output-age detail lines: actions are already visible immediately above, and a second timer adds noise. Last-output timestamps remain internal to detecting a pause; empty publications do not advance them and streamed tool-argument bytes count as model output. State updates retain the existing coalesced cadence and the visible clock refreshes once per second.

After five seconds without streamed output, show “Waiting for more output” rather than continuing to imply active writing or showing a steadily declining token rate. If a measured live rate is available, label it as the last rate. Manual and automatic compaction publish an operation-owned transient status, shown as “Compacting context” in both the transcript and composer and cleared on success, failure or cancellation.

Do not label a wait as prefill without explicit engine evidence. Do not invent progress percentages, reasoning, task descriptions or throughput during silence. Permission requests continue to use the existing permission sheet and authority boundaries.

### Preserve navigation and performance

Apply the projection within the existing measured 40-message window. Tool-role rows already represented by call events do not duplicate results. Earlier/Later navigation preserves every original message and tool event. Normal stream growth follows only when the reader is already following; expanding details and reading older reasoning must not force a jump to the bottom. No estimated row-height feedback or insertion animation is introduced.

## Validation

Regression checks cover stable row IDs and continuation alignment before/after call arrival, visible narration and reasoning, chronological paging, independent action expansion, failure/denial/missing-result states, native action labels, observed stream phases, permission precedence, bounded reasoning excerpts and precise elapsed clocks. Native hosted-view snapshots check the composed layout and that tool arrival does not collapse visible content. Existing transcript font/width reflow and reader-scroll tests remain part of full verification.
