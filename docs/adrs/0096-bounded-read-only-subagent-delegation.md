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
   Siri to trigger GOAT actions from the outside. This is an external invocation boundary, kept distinct from
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
  - `subagentTimeoutSeconds: Int` (default 180, minimum 10, maximum 300).
  - `subagentPreferredBackend: SubagentBackendID` (default .localEngine).

### 2. Single-Active-Turn Invariant and Execution Budgets

#### Invariant Preservation
- Preserves the Shepherd single-active-turn invariant (ADR-0006 and ADR-0023): the parent turn
  remains the sole active turn registered with `ShepherdModel`.
- The subagent executes synchronously from the parent's perspective inside the invocation of
  `subagent_delegate`, driven by a headless background actor (`SubagentWorker`).

#### Inner and Outer Deadlines
- GOATed enforces an outer model-tool execution budget on extension invocations (`ToolExecutionBudget.supervisedSubagent`,
  which is 330 seconds and is selected only for the built-in delegation route). Exceeding this budget causes GOATed to quarantine the extension.
- To prevent accidental quarantine of `goat.subagents`, the child subagent timeout is strictly decoupled from
  and bounded below the outer budget:
  `innerChildTimeout <= 300 seconds < outerBudget (330 seconds)`.
- A minimum buffer of 30 seconds is guaranteed for the child worker to abort operations, collect partial findings,
  synthesize a structured receipt, and persist its terminal state before the outer 330-second budget expires.

The longer default accommodates multiple prompt-processing and generation rounds on local hardware.
Explicitly saved time limits remain unchanged; the default applies when no valid limit is saved.
Other extension tools retain their existing budgets.

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
- **Local Engine Backend (Baseline):** The owner selects a worker model per engine profile. The parent
  retains its own chat model and synchronously awaits the delegated result before continuing. The worker
  uses the same explicitly configured local engine, including literal local-network addresses admitted
  by JUDAS (ADR-0055). Both models must already be loaded; missing workers fail with a descriptive error,
  never silently reuse the parent or load a different model. Only one child generates at a time.
  Admission checks engine idle state, loaded worker identity and memory headroom on that server.
- **System Language Model Backend (Progressive Enhancement):** Targets Apple's on-device `SystemLanguageModel`
  (`import FoundationModels`). Before execution, runtime availability is verified via
  `SystemLanguageModel.default.availability`. If available, lightweight extraction and summary tasks execute through the on-device framework. Hardware scheduling is owned by Apple; GOAT does not promise a particular processor. If unavailable (unsupported hardware, disabled by policy, or missing assets), it
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

### 5. Executable Permission Fence and Pen-File-Only Scope

#### Strict Pen-File-Only Scope in Stage 1
To eliminate any conflict with Hindsight remote endpoints or JUDAS network policies, Stage 1 delegation is
strictly limited to local Pen file inspection. Memory inspection, external MCP tools, and command execution
are deferred.

#### Host-Validated Capability Handles
Excluding a tool name from the model schema is not an authorization boundary. The host creates an explicit
child capability scope:
- The child worker is provisioned with host-validated `ToolHandle` tokens bound strictly to the parent turn
  and Pen workspace.
- The host validates tool ownership, active turn validity, workspace path containment, and extension registration
  status on every invocation.
- Attempting to invoke a forged, expired, or out-of-scope handle throws `CapabilityError.unauthorized`.

#### Tool Allowlist
The child subagent schema is strictly limited to four audited read-only Pen tools:
- `pen_read_file`
- `pen_list_files`
- `pen_search`
- `pen_glob`

All other tools are excluded:
- File writes (`pen_write_file`) and edits (`pen_edit_file`) are excluded.
- Command executions (`pen_run_command`, `pen_command_status`, `pen_stop_command`) are excluded.
- All external MCP tools are completely excluded in Stage 1, regardless of their self-reported read-only metadata.
- Memory provider queries and Hindsight lookups are excluded from Stage 1 child schemas.
- The `subagent_delegate` tool is excluded from child schemas, preventing recursive spawning.
- **Unattended Fail-Closed Policy:** Any operation requiring interactive user confirmation or host permission
  prompts fails closed immediately with `unattendedApprovalDenied`.
- **The Herd Guarantee:** Child subagent exploration tools generate zero network traffic, operating strictly
  against local Pen files with zero telemetry, zero analytics, and no external network endpoints. The only
  network transport permitted during delegation is communication to the explicitly configured inference engine
  on loopback or a literal local-network address. JUDAS still authorizes the connection; cloud endpoints and
  arbitrary DNS aliases do not acquire local authority.

### 6. Work Bounding, Token Accounting, and Output Guarantees

#### Concurrency and Delegation Caps
- **Single Child Admission:** Exactly one child subagent may run at any time per parent turn. Concurrent calls
  to `subagent_delegate` fail with `alreadyDelegating`.
- **Cumulative Invocations:** A parent turn may invoke `subagent_delegate` at most 3 times. Subsequent calls
  are rejected by the router.

#### Token Budgets and Accounting
- **Per-Request Context Admission:** Input context for each child inference request is capped at 12,288 tokens.
- **Per-Round Generation Cap:** Output generation is capped at 2,048 tokens per child round.
- **Per-Delegation Processing Budget:** Auto allocates 14,336 tokens per configured round,
  bounded to 32,768–131,072 total tokens. Custom selects a value in that range. Input is
  counted again on each request, including cached input. This is a work allowance, not RAM allocation.
- **Aggregate Parent-Turn Bound:** Total processing across children is at most twice the
  configured investigation allowance. Generated output across children is capped at
  `max(8,192, configuredRounds * 2,048 * 2)`, at most 40,960 tokens. Three delegations remain the maximum.
- The same saved Auto/Custom, time and round controls appear in Nerd Stats and Extensions settings.
  They are locked throughout an active parent turn. The next turn captures a configuration snapshot.
  The tool description tells the parent its effective limits and recommends focused tasks.

#### Synthesis Pass Budget Reservation
- Exploration reserves up to 14,336 processing tokens for the final bounded input and output.
  The worker switches to synthesis before another exploration request would consume that reserve,
  when only one output round remains, or after 65% of the wall-clock limit has elapsed.
- The final input is pruned if needed to leave output headroom. The objective is included only once.
  Unchecked parts must be reported as unresolved. Hard deadlines and cancellation remain authoritative;
  a stalled request can still prevent synthesis. In that case the host returns a bounded failure receipt
  with any previously verified summary/citations; it does not invent findings from raw reads.
- Engine-reported usage still undergoes strict final budget checks. Larger processing allowances
  do not change the 12,288-token input or 2,048-token output limits used for memory admission.

#### Intermediate and Output Limits
- **Per-Call Tool Output Limit:** Intermediate tool responses (such as file reads or search outputs) are
  capped at 32 KiB per call. Output exceeding this limit is cleanly truncated with a structured marker.
- **Child Transcript Limit:** The cumulative child conversation transcript stored in memory is capped at 512 KiB.
  Intermediate tool outputs in the transcript are pruned to fit this limit.
- **Guaranteed 16 KiB Receipt Size:**
  - `summary` is hard-capped at 8,192 UTF-8 bytes.
  - `unresolved` is hard-capped at 2,048 UTF-8 bytes.
  - Text fields exceeding their bounds are truncated on valid UTF-8 character boundaries with a `[truncated]` notice.
  - Secondary citations and non-critical telemetry are pruned to ensure the total receipt remains under 16 KiB.
  - If serialized output still threatens the limit, an always-fitting minimal fallback receipt (<1 KiB) is emitted,
    containing primary citations and a direct reference to `run_id`.
  - Truncation never cuts raw JSON strings, preserving valid JSON parsing at all times.

### 7. Durable Child Ownership, Recovery, and Evidence Provenance

#### Persistence Schema
Child subagent lifecycles are persisted in an auxiliary `subagent_run` table in `Persistence`:
- `id: String` (primary key UUID)
- `chat_id: String` (foreign key referencing `chat(id)` with `ON DELETE CASCADE`)
- `parent_turn_id: String` (correlation UUID identifying the parent turn)
- `status: String` (`running`, `completed`, `timedOut`, `budgetExhausted`, `cancelled`, `interrupted`, `failed`)
- `task_brief_json: String` (delegated objective and search constraints)
- `rounds_executed: Int`
- `total_tokens: Int`
- `transcript_bytes: Int`
- `transcript_json: String?` (persisted full child transcript, capped at 512 KiB on disk)
- `summary: String?`
- `citations_json: String?`
- `receipt_json: String?`
- `created_at: Date`
- `completed_at: Date?`

#### Lifecycle Ordering and Compare-and-Set Transitions
1. **Creation:** A record with status `running` is committed to the database before the child worker starts.
2. **Atomic Terminal Transitions:** Every terminal state transition (`completed`, `timedOut`, `budgetExhausted`,
   `cancelled`, `interrupted`, `failed`) executes as an atomic compare-and-set database update:
   `UPDATE subagent_run SET status = :new_status, ... WHERE id = :run_id AND status = 'running'`.
   If zero rows are updated, the transition is rejected, ensuring terminal idempotency.
3. **Late-Result Rejection:** Once terminal, any delayed tool returns or late inference callbacks are discarded.
4. **Startup Recovery:** During application launch, `StartupDiskLoader` executes a recovery query that updates
   any `subagent_run` rows remaining in the `running` status to `interrupted`.
5. **Cascade Deletion:** When a parent chat is deleted, all associated `subagent_run` rows and transcripts are
   purged automatically via database foreign key cascade.

#### Evidence Provenance and Citation Verification
Model-generated citations cannot be trusted without verification. Every citation in the returned receipt must
be verified against actual tool execution evidence:
- **Path Validation:** The cited path must match a file actually read via `pen_read_file` during that run.
- **Range Validation:** The cited line range must fall entirely within the line spans returned by `pen_read_file`.
- **Content Fingerprint:** Each verified citation includes a SHA-256 fingerprint of the file slice as read during
  the child turn. This allows the host or user to detect if the file was modified subsequent to the subagent review.
- **Unverified Citation Handling:** Any citation referencing unread files, invalid line ranges, or failed reads
  is stripped from the `citations` list and moved to `unresolved` with the reason `unverifiedCitation`.

### 8. Cancellation Ownership, Leases, and Engine Protection

#### Capability Lease Revocation
- When a child times out, exhausts budget, or receives a parent cancellation signal, the host immediately revokes
  the child's capability lease.
- Subsequent tool invocations or inference stream chunks arriving from the child are immediately rejected with
  `CapabilityError.revoked`.

#### Transport Shutdown and Reservation Quarantine
- Swift Task cancellation propagates immediately to the child `SubagentWorker` and its underlying engine HTTP
  connections or streaming tasks.
- Severing a Swift task handle does not guarantee immediate termination of underlying socket connections.
  Therefore, the engine reservation held by the parent turn cannot be released or reused for new model inference
  until the engine transport confirms closure.
- **Shutdown Grace Period:** The child worker is granted up to 5 seconds to complete transport termination and
  finalize database records.
- **Fail-Closed Reservation Quarantine:** If transport closure is not confirmed within the 5-second window, the host
  quarantines the engine reservation, preventing the parent from dispatching subsequent inference until the
  transport confirms aborted state. This prevents concurrent model execution on the engine.
- An unconfirmed transport shutdown never permits parent inference to proceed prematurely.

### 9. Acceptance Test Scenarios

The test plan for Stage 1 subagent delegation includes the following deterministic acceptance scenarios:

1. **Inner/Outer Deadline Ordering:** Verify that an inner timeout (e.g. 60s) fires, cleanly terminates the child,
   records `timedOut`, and returns a partial receipt before the outer 330s budget expires, preventing extension quarantine.
2. **Uncooperative Child Worker:** Simulate a child task that ignores cancellation. Verify capability lease revocation,
   host task severance, failure to update the CAS database record, and rejection of late callbacks.
3. **Transport Termination and Quarantine:** Simulate delayed socket closure on engine transport. Verify that parent
   engine reservation is quarantined and blocked from new inference until socket termination is confirmed.
4. **Completion Arriving After Stop:** Simulate a user stopping the parent turn while the child is generating. Verify
   immediate cancellation, CAS transition to `cancelled`, and rejection of late model responses.
5. **Token and Round Budget Exhaustion:** Test that reaching round limits or cumulative token bounds halts further tool
   execution and produces a receipt with `status: budgetExhausted`. Verify deterministic fallback when synthesis
   budget is insufficient.
6. **Oversized and Multibyte Output Truncation:** Pass multibyte UTF-8 outputs exceeding 32 KiB and 16 KiB. Verify clean
   truncation on valid character boundaries without corrupting JSON syntax.
7. **Permission Security and Handle Forgery:** Attempt invoking unissued or altered `ToolHandle` tokens, stale
   handles from prior turns, or Pen tools after workspace re-binding. Verify `CapabilityError.unauthorized` or `revoked`.
8. **Unattended Approval Denial:** Attempt invoking write tools or commands from a child context. Verify immediate
   fail-closed denial with `unattendedApprovalDenied` without prompting the user.
9. **Startup Recovery and Cascade Deletion:** Create simulated `running` subagent runs and verify `StartupDiskLoader`
   migrates them to `interrupted` on boot. Delete parent chat and verify cascade deletion of all child run records.
10. **Evidence Provenance and Fabricated Citation Stripping:** Provide model citations matching unread files or out-of-bound
    line ranges. Verify that invalid citations are stripped from `citations` and added to `unresolved`, while valid
    citations retain their SHA-256 slice fingerprints.

## Consequences

- Complex multi-step investigation runs within a tightly bounded child sandbox without polluting parent context.
- Eliminates risk of extension quarantine by strictly ordering child timeouts (<=300s) within the outer budget (330s).
- Protects engine and memory stability by enforcing sequential GPU access, memory headroom checks, and reservation quarantine.
- Protects workspace integrity with an executable Pen-file-only capability fence and host-side handle validation.
- Preserves the single active turn invariant and the Herd Guarantee.
- Establishes a verified, durable provenance model for all subagent evidence before introducing write delegation in Stage 2.

## Alternatives Considered

- **Subprocess or Daemon Architecture:** Adds IPC overhead, process lifecycle issues, and security boundaries;
  rejected in favor of in-process Swift actors within the existing GOAT architecture.
- **Permitting Memory or External MCP Tools in Stage 1:** External MCP tools and Hindsight endpoints introduce network
  risks and approval prompts; deferred in favor of strictly local Pen file inspection.
- **Allowing Recursive Delegation:** Dramatically increases complexity, risk of context explosion, and deadlock;
  strictly prohibited.
- **Trusting Model Citations Without Verification:** LLMs frequently hallucinate line numbers and file names;
  rejected in favor of host-verified tool read spans and SHA-256 fingerprints.

### Stage 1 implementation contract

- `subagent_delegate` accepts a nonempty objective and an optional `max_rounds` in 1...10. The host's configured cap also applies; the final round is synthesis, so a one-round run does not use file tools. Invalid values are rejected before dispatch.
- `scope_hint` contains advisory paths for investigation focus. It is not an authorization boundary. The capability fence enforces read-only access to the owning Pen. The earlier `path_filter` spelling is rejected with migration guidance rather than implying a narrower enforced boundary.
- Static availability is shared by tool advertisement and settings: a local engine and an explicitly supported model identity are required. Runtime admission still checks loaded state, idle request counts, context and model-specific memory headroom before dispatch. Unknown model aliases fail closed.
- Inference owns the per-request `GenerationTransportClosureHandle` and cancellation-safe registration. The producer acknowledges the handle after teardown, including failures before client creation. There is no second closure callback or engine-wide completion wait. The host retains quarantine across turn lifetimes.
- Results present status, summary, verified source references, unresolved items and elapsed time. Source buttons reveal an existing file within the current owning Pen; verification describes the bytes read during the investigation, not a guarantee that the current file is unchanged. Raw arguments and transcripts remain under Diagnostics.
- Settings keep round/time limits under Advanced. A quarantined engine shows an explanation when Send or Regenerate is attempted; the draft is preserved.
- Apple system inference remains deferred and is not offered as a Stage 1 backend. Native Writing Tools remain an explicitly user-invoked platform feature.

Further lifecycle decomposition and broader shared test-fixture consolidation are follow-up work; they do not change these contracts.

### Local worker pairing and Apple Intelligence intent (#32)

The owner-facing goal is a capable main model orchestrating focused work delegated to a smaller model.
Settings > GOATed > Extensions > Subagents selects a worker from the active engine catalog, persisted per
engine profile. No implicit parent-model fallback is allowed. Worker requests use their own model-family
policy, bounded low-effort generation and the existing read-only capability fence. The parent remains
responsible for implementation and final synthesis. This does not introduce concurrent model generation.

The initial modern pair is Qwen3.8-27B MLX 4-bit as parent and Qwen3.5-9B MLX 4-bit as worker. Audited
worker IDs include the exact `-4bit` and `-MLX-4bit` conversions. MTP-only weights, arbitrary fine-tunes,
unknown aliases and unverified quantizations are not admitted by substring matching. Hybrid memory
admission conservatively charges all 32/64 layers as full attention (four KV heads, dimension 256,
two bytes per element), although only one in four layers uses full attention. An additional 512 MiB
allowance covers recurrent state and temporary allocations. The existing bounded 14,336-token request
allocation is used, not the advertised 262,144-token model capacity. Both models' already-resident weights
are included in server-reported memory usage. This is conservative admission, not a guarantee against
unrelated processes consuming memory after the check.

Architecture sources: [Qwen3.5-9B config](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/config.json)
and [Qwen3.8-27B config](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/config.json).

Apple Intelligence is an explicit product direction, not abandoned scope: a subsequent on-device
Foundation Models backend should handle suitable extraction, task-brief refinement and summaries.
Qualification must demonstrate availability handling, bounded structured output, cancellation and zero
cloud fallback. Unavailability must be visible; switching to the configured local worker requires an
explicit owner policy. Native Writing Tools are not evidence that this backend has been implemented.

The installed Qwen3-8B 4-bit worker is also supported, including oMLX's exact HF-cache identifier
`mlx-community--Qwen3-8B-4bit`. Its envelope uses 36 layers, eight KV heads, dimension 128 and a
40,960-token capacity from the [upstream config](https://huggingface.co/Qwen/Qwen3-8B/blob/main/config.json).

The Qwen3.5-9B worker explicitly disables thinking through its audited
[chat template](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/chat_template.jinja), keeping lightweight
file investigation within the child deadline. Parent reasoning settings are unchanged.
