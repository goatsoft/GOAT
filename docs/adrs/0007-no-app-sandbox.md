# ADR-0007: No App Sandbox; Hardened Runtime at ship

**Status:** Accepted · 2026-08-29

The App Sandbox decision remains current. The network and signing details below record the original design: [ADR-0008](0008-inference-via-omlx.md) moved inference to an external engine, [ADR-0045](0045-judas-central-egress-policy.md) introduced JUDAS, and [ADR-0078](0078-owner-approved-release-signing.md) requires Developer ID signing and notarization for official downloads. Use [Architecture](../ARCHITECTURE.md) for current process and permission boundaries.

## Context

App Sandbox would preclude core features: stdio MCP servers require launching arbitrary user-configured processes (npx, uvx, binaries) with inherited environments; memory lives in a user-legible folder; users point GOAT at model directories. Claude Desktop itself ships unsandboxed for the same structural reason. GOAT is direct-distribution (no App Store plan).

## Decision

- **App Sandbox: off.** Documented consequence: MCP servers you configure run with your user's privileges. The permission gate (ADR-0006) is the mitigation layer, not the sandbox.
- **Hardened Runtime + notarization** wired into `make release` when distribution starts; local dev builds are ad-hoc signed.
- Network posture enforced by design + tested (Airplane Mode Guarantee): the app's only own endpoints are Hugging Face (model downloads) and user-configured MCP/Hindsight URLs. No analytics, no update pings (Sparkle later would be opt-in and signature-checked).

## Consequences

No Mac App Store distribution without rearchitecting stdio MCP (acceptable; explicitly out of scope). Security review shifts to: process spawning is user-configured only, every tool call is permission-gated and logged, nothing runs that the user didn't add.

## What Hardened Runtime is (and isn't)

Two different shields, often confused:

- **App Sandbox** contains *what the app can touch*: files, network, process spawning. It protects the system from the app. This is the one we're turning off, because stdio MCP servers are, by definition, "spawn arbitrary user-chosen executables."
- **Hardened Runtime** protects *the app's own process from being tampered with*: no writable-executable memory, no DYLD injection via environment variables, no loading of unsigned libraries, no debugger attachment in release builds, and protected-resource access (camera/mic/automation) gated behind entitlements + user consent. It costs us nothing feature-wise and is **required for notarization**. Without it, Gatekeeper blocks the app on other people's Macs.

So "no Sandbox + Hardened Runtime" is not a contradiction: we decline the cage, keep the armor. This is the standard posture for the category: Claude Desktop, VS Code, iTerm, Ollama, LM Studio all ship exactly this way, for the same structural reason.

## Why not Docker?

Docker on macOS runs a **Linux VM**. Three dead-ends follow: a native SwiftUI app cannot run in a Linux container at all; MLX inference needs Metal + unified memory, which no VM passthrough provides (this would delete the entire performance story); and containerized MCP servers can't see the user's real files or tools, which is usually their whole job. Apple's macOS 26 containerization framework is also Linux-containers-only: same wall.

Where Docker *is* legitimate: **per-server, by choice**. A stdio server's launch command is arbitrary, so `docker run -i mcp/whatever` works today for sandboxing an untrusted server. The user picks the trust level per tool. (Hindsight already lives in Docker; that's the one container-shaped thing in the stack, and it's fine.) A one-click "run this server in a container" template is in the parking lot.

The honest security model: GOAT's risk surface is *what you plug into it*: MCP servers run with your user's privileges. The controls that matter are the per-call permission gate, the visible call log, and never-auto-allow defaults (ADR-0006), not a sandbox the feature set can't survive.

## Alternatives considered

Sandbox + XPC helper for process launch (rejected: complexity explosion for MVP, still fights the model), sandbox with HTTP-only MCP (rejected: kills the dominant stdio server ecosystem), Docker (rejected as host, see above; embraced as an optional per-server containment choice).
