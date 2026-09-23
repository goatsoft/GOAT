# ADR-0096: Bounded read-only subagent delegation and prompt optimization

Status: Proposed · 2026-09-24

Refines [ADR-0006](0006-mcp-integration.md), [ADR-0023](0023-single-active-turn-and-engine-lifecycle.md),
[ADR-0042](0042-goated-kid-capability-contract.md), and [ADR-0074](0074-grouped-transcript-tool-activity.md).
Implements Stage 1 of [issue #32](https://github.com/goatsoft/GOAT/issues/32).

## Context

GOAT currently enforces a single active turn per session. When a complex task requires extensive
investigation, repository searches, or documentation review, performing every intermediate tool
step directly in the parent conversation consumes substantial prompt budget, pollutes the chat
transcript, and dilutes the model context with transient raw outputs.

### Unsloth Multi-Agent Orchestration Patterns
Unsloth's `--as-subagent` integration and native supervisor-subagent proposal (issue unslothai/unsloth#10776)
demonstrate the value of delegating bounded subtasks to local worker models. Key lessons include:
1. **Supervisor and Subagent separation:** The primary coordinator focuses on high-level planning and user
   interaction, while delegating narrow, bounded tasks (codebase searches, log analysis, batch review) to
   specialized local subagent profiles.
2. **Strict output bounding:** The supervisor never ingests the subagent's raw tool stream. Instead, the
   child returns a compact, synthesized summary with citations.
3. **Fail-closed timeouts and cooperative cancellation:** Delegated tasks must have hard wall-clock bounds
   and respond to cancellation signals immediately.
4. **Read-only execution path:** Unchecked subagent writes lead to state divergence and corruption. Bounded
   read-only exploration must precede any write delegation.

GOAT adopts these conceptual patterns within its native Swift architecture while avoiding AGPL code and
preserving all repository invariants.

### Apple Intelligence and Siri as Local Subagents
On macOS 26 and 27, Apple Intelligence introduces system-level foundation models and Siri updates that
offer distinct architectural opportunities:
1. **Zero-VRAM and Zero-Thrash Offloading:** Apple's on-device foundation models run on the Apple Neural
   Engine (ANE) in system memory. Utilizing them for auxiliary tasks (such as prompt rewording, extraction,
   or log summarization) consumes zero additional GPU memory from GOAT's primary oMLX coding engine.
2. **Prompt Optimization and Rewording:** Prompts can be optimized and reworded at two distinct tiers:
   - Direct in the composer: Native AppKit Apple Writing Tools integration (`NSWritingToolsCoordinator`)
     for inline rewording, proofreading, and tone adjustment before submission.
   - Programmatic task briefs: An automated prompt-refinement pass that converts ambiguous requests into
     structured, bounded `SubagentTaskBrief` contracts with explicit search goals and output criteria.
3. **Bidirectional Siri and App Intent Integration:**
   - GOAT to Siri: Delegating system-level queries or lightweight summarization to on-device system models.
   - Siri to GOAT: Exposing App Intents so Siri can delegate specialized coding and repository tasks to GOAT.

## Decision

### 1. The Subagents Builtin GOATed Extension
- Introduce a new builtin GOATed extension named `Subagents` with identifier `goat.subagents`
  conforming to the API v1 capability contract (ADR-0042).
- Contributes the `subagent_delegate` model tool via `ModelToolProvider`.
- Contributes a `TurnObserver` to guarantee lifecycle cleanup of child tasks when a parent turn ends,
  fails, or is cancelled.
- Configurable via `BuiltInExtensionSettings`:
  - `subagentsEnabled: Bool` (default true).
  - `subagentMaxRounds: Int` (default 5, ceiling 10).
  - `subagentTimeout: Int` (default 90 seconds, range 10..180 seconds).
  - `subagentPreferredBackend: SubagentBackendID` (default .localEngine).

### 2. Single-Active-Turn Invariant and Child Execution Model
- Preserves the Shepherd single-active-turn invariant (ADR-0006 and ADR-0023): the parent turn
  remains the sole active turn registered with `ShepherdModel`.
- The subagent executes synchronously from the parent's perspective inside the invocation of
  `subagent_delegate`, driven by a headless background actor (`SubagentWorker`).
- The child worker runs an autonomous multi-round loop (model inference, tool execution, feedback)
  bounded by `subagentMaxRounds` and an explicit wall-clock timeout.

### 3. Pluggable Subagent Backend Architecture
Introduce a typed backend abstraction:
```swift
public protocol SubagentBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult
}
```
Two backends are established:
- **Local Engine Backend (macOS 26+ baseline):** Targets the currently loaded model on the active
  oMLX or local engine endpoint. This eliminates model switching latency and allocates zero
  additional GPU memory on unified memory hardware. If an alternate model is requested, memory
  admission checks verify sufficient headroom before loading.
- **Apple Assistant Backend (macOS 27+ progressive enhancement):** Delegates lightweight extraction,
  summary, and prompt polishing tasks to on-device system models or App Intents running on the
  Apple Neural Engine, keeping the primary GPU engine completely undisturbed.

### 4. Native Prompt Optimization via Apple Writing Tools
- Enable Apple Writing Tools in the composer editor (`MarkdownComposerEditor.swift`) by configuring
  `writingToolsBehavior = .complete` and `allowedWritingToolsResultOptions = [.plainText]`
  on `ComposerTextView`.
- This provides instant inline prompt rewording, proofreading, and optimization directly within
  the UI, running entirely on the Apple Neural Engine with zero network traffic or VRAM overhead.
- In addition, task briefs passed to `subagent_delegate` can undergo optional on-device prompt
  refinement to ensure child models receive concise, deterministic search constraints.

### 5. Permission Inheritance and Zero-Widening Read-Only Fence
- The child subagent inherits the parent Pen workspace boundary and cannot access files outside it.
- **Allowed Tools:** Strictly limited to read-only Pen tools (`pen_read_file`, `pen_list_directory`,
  `pen_search_files`) and read-only memory/Hindsight search queries.
- **Denied Operations:** File writes (`pen_write_file`), file edits (`pen_edit_file`), command
  executions (`pen_run_command`), and mutable MCP tools are strictly excluded.
- **No Recursion:** The `subagent_delegate` tool is excluded from child schemas, preventing recursive
  spawning and fork bombs.
- **Unattended Fail-Closed Policy:** Any operation requiring interactive user approval is denied
  immediately with a structured diagnostic, as child subagents run without user interaction.
- **The Herd Guarantee:** Subagents strictly adhere to GOAT's zero-telemetry invariant. No analytics,
  no update checks, and no unsolicited network calls. Apple Intelligence integrations must run
  strictly on-device.

### 6. Dual-Layer Transcript Persistence and Bounded Results
- **Parent Transcript:** Receives a compact, structured JSON receipt (capped at 16 KiB) containing:
  - `status`: completed, timedOut, cancelled, or failed.
  - `summary`: synthesized answer to the delegated task.
  - `citations`: verified file paths and line ranges.
  - `unresolved`: remaining questions or boundaries encountered.
  - `telemetry`: rounds executed, token counts, and wall-clock duration.
  - `run_id`: unique UUID reference to the child execution record.
- **Child Run Persistence:** Full intermediate turns, raw tool inputs, and outputs are stored in
  an auxiliary `subagent_runs` table in `Persistence`.
- **Bleet Presentation:**
  - Real-time progress is rendered in `AgentProgressView` with round counts and current tool activity.
  - Completed receipts render as expandable summary cards with a link to open the full child
    investigation transcript in an inspector popover.

### 7. Cooperative Cancellation and Timeouts
- Structured Swift concurrency cancellation propagates immediately from the parent turn to the child
  worker, terminating active engine HTTP requests and child tool tasks without orphans.
- An independent watchdog enforces the configured timeout, terminating runaway loops and returning
  a `timedOut` receipt with partial findings.
- Startup disk loading cleans up interrupted child records from unexpected application terminations.

## Consequences

- Bounded research tasks run without bloating the parent chat context or degrading prompt efficiency.
- Preserves all architectural invariants: single active turn, Herd Guarantee, and strict permission boundaries.
- Users gain access to Apple Writing Tools in the composer on macOS 26 and 27.
- Establishes a verified read-only foundation before introducing write delegation in Stage 2.

## Alternatives Considered

- **Out-of-band daemon or subprocess:** Adds process lifecycle complexity and credential exposure;
  rejected in favor of in-process Swift actors and GOATed extensions.
- **Unrestricted child tool execution:** Allowing writes in subagents creates race conditions and
  unapproved workspace mutations; postponed to Stage 2 with explicit diff reviews and worktrees.
- **Recursive subagent delegation:** Increases unpredictability and context explosion; explicitly forbidden.
- **Direct Siri execution without backend abstraction:** Couplings to specific OS versions break macOS 26
  compatibility; pluggable backends isolate platform dependencies cleanly.
