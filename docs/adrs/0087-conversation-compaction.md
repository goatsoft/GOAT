# ADR-0087: Conversation compaction

Status: Proposed · 2026-09-11 (amended 2026-09-13: owner defaults confirmed; implementation refinements)

Supersedes the parked rolling-summary decision in [ADR-0024](0024-deterministic-prompt-budgeting.md); refines [ADR-0069](0069-coding-navigation-and-context-retention.md) and the handoff command in [ADR-0066](0066-lead-and-continuous-tool-work.md). Depends on the calibrated estimate from [ADR-0085](0085-prefix-stable-prompts-and-usage-calibrated-budgeting.md).

## Context

When a chat outgrows the input budget, GOAT drops whole older exchanges. Nothing carries their content forward, so a long coding session loses the task, the decisions and the list of files it has already changed. The established alternative is to compact instead: a bounded summary replaces older history at a threshold of 80 to 90 percent of the window, the newest user message is kept verbatim, and old tool results are pruned before any summary is written. GOAT already has the ingredients: the `/handoff` command produces a structured handover, tool events record every file read and edited, and the budgeter enforces exchange boundaries.

The owner asked for a manual compact command and an automatic mode with a threshold.

## Decision

### Two tiers

**Tier 1, deterministic pruning, always on.** Within the retained history, tool-result bodies older than the newest 40,000 estimated tokens of tool output are replaced with the existing excerpt marker once at least 20,000 tokens would be saved. Tool names, arguments and identifiers are untouched; both sides of a protocol pair stay linked. This is the ADR-0069 excerpt rule applied across all retained exchanges rather than only the newest one, and it needs no model call and no setting. The marker is a fixed constant, so a pruned body renders byte-identically across turns (prefix stability, ADR-0085) and the omitted size is carried in the budget report rather than the marker text. Always-on pruning changes the deterministic prompt shape, so the policy version moves to 5, and a new `agedToolResult` truncation component reports it.

**Tier 2, model-written summary, controlled by the user.** A compaction request asks the selected model, with the same system prompt and the existing handoff prompt shape, for a summary with fixed sections: goal, constraints and user preferences, done, in progress, blocked, key decisions, next steps, critical context. GOAT appends the files read and files edited lists itself from tool events; the model is not asked to recall them. The newest user message is always kept verbatim. An optional focus instruction (`/compact keep the WGSL constraints`) is added to the summary request.

### Command and setting

`/compact [focus]` runs tier 2 immediately on the active chat when no turn is running. A manual `/compact` obeys the same threshold as auto: below it (and when nothing new has accrued since the last summary) the command reports through the message notice and changes nothing, because the threshold is the single, user-settable lever (owner decision, 2026-09-13). The focus instruction is one-shot: trimmed, bounded to 500 characters, and carried on the summary request so it never persists into a later plan. Settings gains **Auto-compact** (default on) and **Compact at** (percent of the input budget, default 80, range 50 to 95), both in the **General** tab; the pasture meter shows the threshold mark. Compaction runs behind a composer spinner with the elapsed clock (not a progress bar, since one summary generation has no measurable steps), then lands a collapsed "Compacted N exchanges" row.

### Trigger and timing

After every completed response, the calibrated estimate is compared with the threshold. When it is exceeded and auto-compact is on, compaction runs at the start of the next send, before planning, behind a visible "Compacting" state in the composer, and never inside a tool loop. In practice the auto trigger compares the usage recorded from the last response against the threshold, so an ordinary under-threshold send runs no extra plan; the manual command plans once to gate. An engine error classified as context overflow forces one compaction and one retry of the planned request regardless of the setting. The single-active-turn invariant of ADR-0023 holds throughout: compaction owns the generation slot while it runs.

### Persistence and prompt shape

The summary is persisted as a message row of kind `compaction`, with the ID of the last message it covers. The transcript view shows it as a collapsible "Compacted N exchanges" row; earlier rows remain visible in the transcript and are simply excluded from prompt history. The prompt places the summary as a user-role message immediately after the system turn and the memory index, followed by the retained exchanges. A later compaction summarises from the previous summary forward and carries the file lists forward, so summaries do not nest. The user can delete a compaction row to restore the previous prompt history.

### Failure

A failed or cancelled summary request leaves the chat unchanged and reports the failure; the send proceeds with tier 1 only. Persistence failure aborts compaction before any row is hidden. The summary request is charged against the same budget as any other request and can itself be trimmed by the planner.

## Consequences

Long coding sessions keep their task state across the window boundary and the model stops rediscovering files it already changed. Tier 2 adds one full prefill on a single-slot local engine each time it runs; the visible state and the threshold setting keep that under user control. Determinism is preserved where it matters: which rows are hidden and what tier 1 prunes is a pure function of the plan, and only the summary text comes from the model. Tests cover threshold arithmetic, trigger placement, exchange-boundary cuts, file-list derivation, overflow-forced compaction, deletion and re-summarisation from a prior summary.

## Alternatives considered

Keep dropping exchanges (rejected: amnesia is the failure users notice most). Summarise during send without persistence (rejected by ADR-0024 for nondeterminism; persisting the row answers that objection). Summarise mid-stream on overflow (rejected: violates the single-active-turn ownership and cannot show a stable UI state). Rasterising old history into images (rejected: needs a vision model and hides content from inspection). A separate small summariser model (deferred: worthwhile once multi-slot engines are common, and the design leaves room for a model choice on the summary request).

## Implementation status (2026-09-13)

Backend complete on `feat/model-management` and green under `make verify` (module suite; the app-suite reflow test `streamingAndReflowRespectAReaderWhoScrolledUp` is a pre-existing load-order flake, passes in isolation, unrelated to this ADR):

- Tier-1 aged-tool-result pruning: `1cb931a`.
- Tier-2 content core (fixed sections, one-shot focus, deterministic file-list derivation): `ea07711`.
- Persisted `compaction` message kind (GRDB migration v13 + `CompactionInfo`): `bdbfa9a`.
- Prompt assembly (fold everything before the most recent compaction row; render it as a user turn = summary + file lists): `62f12e2`.
- Manual `/compact` runner: `4fa0542`.
- Auto-compaction trigger: `c391681`.
- Overflow-forced compaction + `contextOverflow` engine classification: `505e1b2`.

The compaction row is persisted with role `user` and kind `compaction`; both compaction paths share the summary construction via `promptSnapshot(truncateAfterIndex:appendedUserRequest:)`. The threshold is read from `ShepherdEnvironment.autoCompactEnabled` / `compactAtPercent` (extension defaults on / 80).

Remaining (Stage 2c, UI): the General-tab **Auto-compact** toggle and **Compact at** slider (wire `AppModel` UserDefaults to override the environment defaults), `/compact` in the slash-command menu, the collapsible "Compacted N exchanges" transcript row in `MessageView` (click to expand the summary and file lists; a compaction row can be deleted to restore the prior prompt history, per Persistence and prompt shape above), and the pasture-meter threshold tick. Then whole-branch qualification flips this ADR Proposed to Accepted.
