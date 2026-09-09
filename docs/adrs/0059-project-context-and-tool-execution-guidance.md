# ADR-0059: Project context and tool execution guidance

Status: Accepted · 2026-09-07

## Context

A coder model returned instructions and printed MCP tool names instead of making protocol tool calls. Shepherd supplied tool schemas but its generic assistant prompt did not explain execution, and Pen workspace paths were absent from the model context. A Pen with no custom instructions lost even its project identity.

## Decision

Pass immutable `ShepherdProjectContext` from the app to Shepherd with the Pen name, instructions and optional workspace path. Include project identity and workspace even when instructions are empty. Quote paths as JSON strings and explain that they describe the intended destination, not a permission grant or a change to an MCP process's working directory.

Select execution guidance from the actual tool schemas offered in each generation round. With tools, instruct the model to perform requested actions through structured calls, inspect before editing, preserve unrelated work and verify outcomes. With no tools, describe the capability limitation honestly. Missing or denied tools must not cause invented actions or attempts to change security policy.

For process tools that separate executable and arguments, explain literal argv semantics with a concrete absolute-path example. A standalone `cd` does not persist across calls, and `echo` output is not a file write. Distinguish malformed calls and unexpanded paths from actual access denials; correction must stay within existing permission policy. Prefer dedicated file tools, or an already permitted shell script when appropriate, with read-back verification.

Continue to execute only structured tool calls through the existing capability-bound permission path. Never turn fenced code, JSON examples or command-looking prose into actions. Model/server parsing belongs to the inference service; its supported tool format is part of engine compatibility.

## Consequences

No new file access, shell executor, dependency, permission bypass or configuration migration. Existing MCP servers retain their configured filesystem scope and execution policy. A workspace path in a prompt cannot enforce filesystem containment. Native workspace-scoped file tools remain a separate feature, with actual path enforcement and reviewable writes required before shipping.

The selected model and server must emit protocol tool calls. Prompt guidance cannot guarantee that capability. A synthetic streaming probe against the configured Qwen2.5-Coder-7B-Instruct-4bit/oMLX pairing returned fenced JSON, zero `tool_calls` and `finish_reason: stop`; no tool was executed. The same no-action probe using the already available Qwen3-Coder-30B-A3B-Instruct-MLX-4bit returned a structured `diagnostic_echo` call and `finish_reason: tool_calls`. This verifies wire format only, not MCP execution or file creation. The Qwen2.5 result is consistent with [oMLX issue 2565](https://github.com/jundot/omlx/issues/2565), but does not establish the server's underlying parser cause or installed version.

## Alternatives considered

- Automatically execute command-looking replies: rejected because examples and explanations are not execution requests.
- Enable the existing filesystem server automatically: rejected because its configured root may differ from the Pen workspace.
- Add a broad native shell as a prompt fix: rejected; process and filesystem authority require their own design.
