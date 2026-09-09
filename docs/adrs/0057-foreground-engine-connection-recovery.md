# ADR-0057: Foreground engine connection recovery

Status: Accepted · 2026-09-07 · Refines ADRs 0023, 0025 and 0045.

## Context

A failed startup probe could leave GOAT marked offline indefinitely after the configured engine became available. Recovery depended on an explicit health check or reopening engine settings. Transient engine startup and local-network availability should not require editing a correct profile.

## Decision

The app owns one recovery controller, independent of individual chat and settings views. While GOAT is active and its active engine is offline, it retries after 1, 2, 4, 8, 16 and then 30 seconds between attempts. View updates join the existing loop. Healthy and authentication-required states do not start polling. An in-flight successful probe finishes publishing model capabilities before the loop retires.

Recovery uses the active profile's exact saved URL and credentials through the existing revisioned engine lifecycle. It does not discover fallback ports, rewrite profiles, generate completions or add network authority. Active turns, engine transitions and model capability checks prevent a recovery probe from starting. Inactive app state or a JUDAS-disallowed target cancels recovery. Every actual request remains independently governed by JUDAS.

An offline engine also exposes a direct Reconnect action beside its status. Edit/Test remains the configuration workflow.

## Consequences and validation

Healthy idle sessions have no recurring health timer. An offline foreground session makes bounded, backed-off requests to its configured service and can recover without a settings detour. Authentication errors still require user action. Returning to the app restarts recovery when needed; network recovery while it stays active can wait for the next retry interval.

Deterministic tests cover single-flight scheduling, backoff, busy-turn suppression, cancellation and non-offline states. Existing engine-operation revisions prevent an older probe from publishing over a newer user action. No database migration, dependency or additional service configuration is introduced.
