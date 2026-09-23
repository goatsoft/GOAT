# ADR-0096: Bounded read-only subagent delegation and prompt optimization

Status: Proposed · 2026-09-24

Refines [ADR-0006](0006-mcp-integration.md), [ADR-0023](0023-single-active-turn-and-engine-lifecycle.md),
[ADR-0042](0042-goated-kid-capability-contract.md), and [ADR-0074](0074-grouped-transcript-tool-activity.md).
Implements Stage 1 of [issue #32](https://github.com/goatsoft/GOAT/issues/32).

## Context

GOAT enforces a single active turn per session. When a complex task requires extensive
investigation, repository searches, or documentation review, performing every intermediate tool
step directly in the parent conversation consumes substantial prompt budget, pollutes the chat
transcript, and dilutes the model context with transient raw outputs.

### Unsloth Multi-Agent Orchestration Patterns
Unsloth's `--as-subagent` integration and native supervisor-subagent proposal (issue unslothai/unsloth#10776)
demonstrate the value of delegating bounded subtasks to local worker models. Key lessons include:
1. **Supervisor and Subagent separation:** The primary coordinator focuses on high-level planning and user
   interaction, delegating narrow, bounded tasks (codebase searches, log analysis, batch review) to
   specialized local subagent workers.
2. **Strict output bounding:** The supervisor never ingests the subagent's raw tool stream. Instead, the
   child returns a compact, synthesized summary with citations.
3. **Fail-closed timeouts and cooperative cancellation:** Delegated tasks must have hard wall-clock bounds
   and respond to cancellation signals immediately.
4. **Read-only execution path:** Unchecked subagent writes lead to state divergence and corruption. Bounded
   read-only exploration must precede any write delegation.

GOAT adopts these conceptual patterns within its native Swift architecture while avoiding AGPL code and
preserving all repository invariants.

### On-Device Intelligence and Prompt Optimization
On macOS, system-level capabilities provide distinct architectural opportunities:
1. **On-Device Foundation Models (`SystemLanguageModel`):** Apple's `FoundationModels` framework introduces
   `SystemLanguageModel` on supported macOS releases. When available, it can perform auxiliary tasks
   (such as extraction, summarization, and prompt restructuring) locally on the Apple Neural Engine (ANE).
2. **Prompt Optimization in the Composer:** Native AppKit Apple Writing Tools integration
   (`writingToolsBehavior = .complete` on `NSTextView`) provides an inline editing affordance in the composer.
   Because system Writing Tools may utilize cloud processing or external intelligence depending on user system
   preferences, it is treated as a user-invoked platform editing feature rather than part of GOAT's offline engine.
3. **App Intents Integration Surface:** `AppIntents` provides a separate mechanism for system experiences and
   Siri to trigger GOAT actions from the outside. This is a external invocation boundary, kept distinct from
   GOAT's internal model execution backends.

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
  - `subagentTimeoutSeconds: Int` (default 60, minimum 10, maximum 90).
  - `subagentPreferredBackend: SubagentBackendID` (default .localEngine).

### 2. Single-Active-Turn Invariant and Execution Budgets

#### Invariant Preservation
- Preserves the Shepherd single-active-turn invariant (ADR-0006 and ADR-0023): the parent turn
  remains the sole active turn registered with `ShepherdModel`.
- The subagent executes synchronously from the parent's perspective inside the invocation of
  `subagent_delegate`, driven by a headless background actor (`SubagentWorker`).

#### Inner and Outer Deadlines
- GOATed enforces an outer model-tool execution budget on extension invocations (`ToolExecutionBudget.standard`,
  which is 120 seconds). Exceeding this budget causes GOATed to quarantine the extension.
- To prevent accidental quarantine of `goat.subagents`, the child subagent timeout is strictly decoupled from
  and bounded below the outer budget:
  `innerChildTimeout <= 90 seconds < outerBudget (120 seconds)`.
- A minimum buffer of 30 seconds is guaranteed for the child worker to abort operations, collect partial findings,
  synthesize a structured receipt, and persist its terminal state before the outer 120-second budget expires.

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
Two backends are defined:
- **Local Engine Backend (Baseline):** Executes re-entrantly against the active model on the currently
  loaded local engine (such as oMLX). Because the parent turn is synchronously awaiting the tool result,
  parent and child inference do not execute concurrently on the GPU. Reusing the loaded model avoids weight
  reloading. Before execution, the host checks that the engine is idle and that KV cache memory headroom is
  sufficient for the requested subagent context window. If memory admission fails, delegation fails closed
  with a descriptive error instead of thrashing.
- **System Language Model Backend (Progressive Enhancement):** Targets Apple's on-device `SystemLanguageModel`
  (`import FoundationModels`). Before execution, runtime availability is verified via
  `SystemLanguageModel.default.availability`. If available, lightweight extraction and summary tasks execute on
  the Apple Neural Engine. If unavailable (unsupported hardware, disabled by policy, or missing assets), it
  fails closed or falls back explicitly to the Local Engine Backend according to user configuration, never
  initiating an unrequested network request.

External `AppIntents` and Siri system actions are defined as separate entry points for invoking GOAT from macOS,
and do not serve as internal subagent inference backends.

### 4. Composer Writing Tools vs Automated Prompt Refinement
- **Composer Writing Tools:** Configured in `MarkdownComposerEditor.swift` via `writingToolsBehavior = .complete`
  and `allowedWritingToolsResultOptions = [.plainText]`. This enables macOS system Writing Tools in the UI.
  Because system Writing Tools behavior depends on user-configured macOS intelligence settings (which may include
  Apple Cloud Intelligence), it is documented as a native AppKit convenience rather than a component of GOAT's
  offline engine guarantee.
- **Automated Task Brief Refinement:** When constructing a `SubagentTaskBrief` for `subagent_delegate`,
  ambiguous user requests can optionally undergo an on-device refinement pass (via `SystemLanguageModel` or a
  deterministic template) to produce explicit search criteria, file path filters, and expected return schemas.

### 5. Executable Permission Fence and Capability Allowlist

#### Host-Validated Capability Handles
Excluding a tool name from the model schema is not an authorization boundary. The host creates an explicit
child capability scope:
- The child worker is provisioned with host-validated `ToolHandle` tokens bound strictly to the parent turn
  and Pen workspace.
- The host validates tool ownership, active turn validity, and workspace path containment on every invocation.
- Attempting to invoke a forged, expired, or out-of-scope handle throws `CapabilityError.unauthorized`.

#### Tool Allowlist
The child subagent schema is strictly limited to read-only workspace and memory inspection:
- **Permitted Read-Only Pen Tools:**
  - `pen_read_file`
  - `pen_list_files`
  - `pen_search`
  - `pen_glob`
- **Denied Pen Operations:**
  - File writes (`pen_write_file`) and edits (`pen_edit_file`) are excluded.
  - Command executions (`pen_run_command`, `pen_command_status`, `pen_stop_command`) are excluded.
- **Excluded MCP Tools:** All external MCP tools are completely excluded from the child toolset in Stage 1,
  regardless of their declared read-only properties.
- **No Recursive Spawning:** The `subagent_delegate` tool is excluded from child schemas.
- **Unattended Fail-Closed Policy:** Any operation requiring interactive user confirmation or host permission
  prompts fails closed immediately with `unattendedApprovalDenied`.
- **The Herd Guarantee:** Child subagents operate strictly local and offline. No analytics, telemetry, or
  unsolicited network connections.

### 6. Work Bounding and Cumulative Delegation Limits

#### Concurrency and Delegation Caps
- **Single Child Admission:** Exactly one child subagent may run at any time per parent turn. Concurrent calls
  to `subagent_delegate` fail with `alreadyDelegating`.
- **Cumulative Invocations:** A parent turn may invoke `subagent_delegate` at most 3 times. Subsequent calls
  are rejected by the router.
- **Cumulative Token Budget:** Total tokens across all child turns within a single delegation are capped at 16,384.

#### Intermediate and Output Limits
- **Per-Call Tool Output Limit:** Intermediate tool responses (such as file reads or search outputs) are
  capped at 32 KiB per call. Output exceeding this limit is cleanly truncated with a structured marker.
- **Child Transcript Limit:** The cumulative child conversation transcript stored in memory is capped at 512 KiB.
- **Receipt Size Limit:** The synthesized JSON receipt returned to the parent turn is strictly bounded at 16 KiB.
- **JSON Truncation Safety:** If a receipt exceeds size boundaries, truncation never slices raw JSON. Instead,
  lower-priority secondary citations and non-critical metadata are pruned, preserving valid JSON structure and
  recording an explicit `truncated: true` flag and `omitted_citations_count`.
- **Budget Exhaustion Outcome:** When round, token, or time limits are reached, the worker ceases further tool
  calls and executes a single bounded synthesis pass to emit a receipt with `status: budgetExhausted` and all
  evidence accumulated to that point.

### 7. Durable Child Ownership, Recovery, and Evidence Provenance

#### Persistence Schema
Child subagent lifecycles are persisted in an auxiliary `subagent_runs` table in `Persistence`:
- `run_id: UUID` (primary key)
- `parent_chat_id: UUID` (foreign key to `chats.id` with `ON DELETE CASCADE`)
- `parent_turn_id: UUID` (foreign key identifying the initiating parent turn)
- `status: String` (`running`, `completed`, `timedOut`, `cancelled`, `interrupted`, `failed`)
- `task_brief_json: String` (delegated objective and search constraints)
- `rounds_executed: Int`
- `total_tokens: Int`
- `transcript_bytes: Int`
- `summary: String?`
- `citations_json: String?`
- `receipt_json: String?`
- `created_at: Date`
- `completed_at: Date?`

#### Lifecycle Ordering and Idempotency
1. **Creation:** A record with status `running` is committed to the database before the child worker starts.
2. **Terminal Transition:** Upon completion, timeout, or cancellation, the record transitions to its final
   status, recording the serialized receipt.
3. **Receipt Return:** The serialized receipt is returned to the parent turn as the result of `subagent_delegate`.
4. **Idempotency and Late-Result Rejection:** Once a record transitions to a terminal state (`timedOut`,
   `cancelled`, `interrupted`), late completions or delayed tool responses are discarded and cannot overwrite
   the terminal state.
5. **Startup Recovery:** During app launch, `StartupDiskLoader` scans for any `subagent_runs` remaining in the
   `running` state and updates them to `interrupted`. Unfinished child runs are never left hanging or
   silently erased.
6. **Cascade Deletion:** When a parent chat is deleted, all associated `subagent_runs` are automatically deleted
   via database foreign key cascade.

#### Evidence Provenance and Citation Verification
Model-generated citations cannot be trusted without verification. Every citation in the returned receipt must
be verified against actual tool execution evidence:
- **Path Validation:** The cited path must match a file actually read via `pen_read_file` during that run.
- **Range Validation:** The cited line range must fall entirely within the line spans returned by `pen_read_file`.
- **Content Fingerprint:** Each verified citation includes a SHA-256 fingerprint of the file slice as read during
  the child turn. This allows the host or user to detect if the file was modified subsequent to the subagent review.
- **Unverified Citation Handling:** Any citation referencing unread files, invalid line ranges, or failed reads
  is stripped from the `citations` list and moved to `unresolved` with the reason `unverifiedCitation`.

### 8. Cancellation Ownership and Uncooperative Workers
- **Cancellation Propagation:** When a parent turn is cancelled or stopped by the user, Swift Task cancellation
  propagates immediately to the child `SubagentWorker`.
- **Transport Cancellation:** Active HTTP connections to the engine or streaming sessions are aborted immediately.
- **Bounded Shutdown:** The child worker is granted up to 5 seconds to finalize database records and release
  memory leases.
- **Uncooperative Severance:** If a child task or tool fails to respond to cancellation within the 5-second window,
  the host severs the task handle, marks the database record `cancelled`, and reclaims parent execution. Any
  subsequent return from the severed worker is discarded.

## Consequences

- Complex multi-step investigation runs within a tightly bounded child sandbox without polluting parent context.
- Eliminates risk of extension quarantine by strictly ordering child timeouts (<=90s) within the outer budget (120s).
- Protects workspace integrity with an executable read-only capability fence and host-side handle validation.
- Preserves the single active turn invariant and the Herd Guarantee.
- Establishes a verified, durable provenance model for all subagent evidence before introducing write delegation in Stage 2.

## Alternatives Considered

- **Subprocess or Daemon Architecture:** Adds IPC overhead, process lifecycle issues, and security boundaries;
  rejected in favor of in-process Swift actors within the existing GOAT architecture.
- **Permitting Read-Only External MCP Tools:** External MCP tools frequently lack strict read-only enforcement;
  excluded in Stage 1 in favor of audited builtin Pen tools.
- **Allowing Recursive Delegation:** Dramatically increases complexity, risk of context explosion, and deadlock;
  strictly prohibited.
- **Trusting Model Citations Without Verification:** LLMs frequently hallucinate line numbers and file names;
  rejected in favor of host-verified tool read spans and SHA-256 fingerprints.
