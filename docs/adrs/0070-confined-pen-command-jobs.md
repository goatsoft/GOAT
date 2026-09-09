# ADR-0070: Confined Pen command jobs

Status: Accepted · 2026-09-08

Implements the native command direction in ADR-0061 and refines ADR-0045. Adds the internal Pens → JUDAS dependency, with no third-party package dependency.

## Context

File tools alone cannot install dependencies, run builds or execute tests. The user requested built-in shell support restricted to the working directory and a whitelist, with permission requests for other commands. Native file grants must not become shell grants. A working directory alone does not enforce file authority.

## Decision

Herder exposes `pen_run_command`, `pen_command_status` and `pen_stop_command` for the current Pen turn. Run accepts an executable, literal argument array, a relative working directory, a network flag and a deadline. Shell syntax requires an explicitly approved shell executable with its `-c` argument. Start returns a job ID; the model polls for bounded combined output and a final exit code. Running is not success.

Pens owns command execution on an actor. Resolve physical workspace and executable paths, validate the workspace identity and executable metadata again after approval, and reject parent traversal or an outside working directory. Reject broad workspaces containing host settings/permissions and preexisting hard links shared outside the Pen. The bounded preflight scan checks at most 200,000 entries. Changes by unrelated external writers remain a race, as with native edits.

Launch through `/usr/bin/sandbox-exec` with a deny-default profile. The command and descendants can read/write the Pen and a private per-job scratch folder, read declared system/toolchain roots and executable, and read system metadata. Other file data access and writes are denied. A clean environment supplies isolated HOME, TMPDIR, npm/cache paths and a controlled PATH; it does not inherit credentials, shell startup configuration or injection variables. Built-in command discovery supports system/Homebrew binaries, installed NVM Node versions, inherited absolute PATH directories and explicit executable paths. Read-only toolchain access is not arbitrary access to the owner's home directory.

Network is denied unless requested and separately approved. JUDAS admits network-enabled jobs only in configured-connections mode and stops registered jobs on a policy change. Offline commands remain usable in blocked mode. Network permission permits the command's outbound network traffic; it is not a domain allowlist. External MCP tools keep their separate authority.

Each job has a process group, a bounded output pipe, a host-liveness pipe and a deadline. A fixed trusted shell supervisor forwards argv without evaluating model text. Its watcher kills the command group when GOAT exits; the model-controlled command cannot retain the liveness descriptor. Stop, timeout, policy change and turn cleanup kill the group and reap its leader. The sandbox rejects direct setsid/setpgid syscalls and limits signals to self/children. Interactive terminals, detached background services and adversarial process isolation are not supported. In particular, macOS spawn attributes can create a different process group without those direct syscalls; process-group cleanup is not a VM-grade guarantee against deliberately daemonized descendants. The filesystem sandbox is inherited independently of grouping.

At most four jobs run concurrently. Deadlines are 1–600 seconds, default 120 seconds. Status waits at most ten seconds and returns at most 32 KiB of combined output with an explicit truncation flag. Retain the latest 100 job records, evicting completed records instead of imposing a turn action limit. Long output can be redirected to a Pen file. Turn completion stops remaining jobs and persists an explicit notice rather than silently abandoning them.

## Permissions and interface

System pwd, ls, cat, head, tail and wc have a small offline default whitelist. All other executables request approval. Allow Once authorizes the displayed call; the split menu can whitelist that executable for this chat or all chats in this Pen. Grants bind Pen ID, optional chat ID, physical workspace identity, executable path/metadata and the exact network mode. Whitelisting permits arbitrary arguments and children within the displayed sandbox; it is not argument-by-argument approval. Preview copy states this explicitly.

Owner command grants are separate from file grants and persisted in host preferences, outside command authority. The Pen page shows a Command permissions section below File permissions, with grant removal/reset. Chat moves, deletion and workspace rebinding clear affected grants. Removing a whitelist entry affects future launches; Stop handles an already running job. Models receive no whitelist-administration tool. Stale approvals and changed executables fail closed.

## Platform dependency and limits

Apple's installed sandbox-exec man page marks the command deprecated. This implementation targets the repository's macOS 26 baseline, tests actual enforcement and never falls back to unconfined execution. If the command or a required policy operation stops working on a future OS, the job fails visibly. This is a compatibility risk, not a portable subprocess sandbox or a replacement for App Sandbox. App Sandbox remains off under ADR-0007.

System SDKs, runtime layouts, developer-service access and authenticated package registries can need additional explicitly reviewed support. Do not broaden file access or inject owner credentials to make a failing command pass. A missing runtime, blocked path or unsupported interactive flow is an actionable limitation for the agent to explain.

## Validation

Deterministic tests cover native GOATed approvals, remembered scopes, revocation, literal arguments, path/symlink/hard-link boundaries, stale executable checks, output limits, timeout/child termination, turn cleanup and network-policy cancellation. An opt-in disposable project installs esbuild using npm, builds TypeScript and executes Node tests with isolated HOME/cache and offline build/test commands. Final evidence belongs in the agent-support audit.

## Alternatives considered

Setting cwd without a kernel file policy would leave access to unrelated user files. Reusing native file grants would hide the greater authority of an interpreter. Treating printed commands as execution would provide no capability or result guarantees. A VM/container backend provides a stronger boundary for hostile programs but is a separate runtime/distribution project.
