# ADR-0067: Lead waits for the current action

Status: Accepted, 2026-09-08. Refines ADR-0066.

## Context

Lead dismissed a pending file-write approval, leaving an orange unexecuted-tool result. The user wants ordinary guidance to wait for the current step to finish, with Stop remaining the explicit interruption control.

## Decision

Saving Lead never cancels an approval. The current model response and its first tool action can finish, including any approval, execution, and result persistence. The pending instruction is supplied before the next model response. If the current response contains multiple calls, apply Lead between actions and retain explicit unexecuted results for later calls from the old response.

Keep approvals authoritative: Allow executes the current action; Deny records a denial even if Lead is queued. Stop cancels the turn and pending approval as before. The composer says "Lead queued • applies after the current action" and its help explains that approvals stay open.

## Consequences

A pending write is no longer skipped simply because the user provides guidance. Lead can wait for approval; users can deny that action or press Stop when they want to interrupt it. Durable saves, the single generation owner, and completion of in-flight writes remain unchanged.

## Alternatives considered

Waiting for the entire coding task would delay guidance indefinitely. Automatically approving a pending action would override the user's file-permission choice. Cancelling approvals on every Lead caused the reported skipped writes.
