# ADR-0074: Grouped transcript tool activity

Status: Accepted · 2026-09-08 · Refines ADR-0058

## Context

Coding agents produce many consecutive tool rounds. Rendering each round as a separate assistant block obscures the conversation. The user requested an expandable activity list with individual request/result inspection.

## Decision

Project the existing bounded transcript window into display rows. Consecutive assistant messages containing tool events share a collapsed activity group, identified by the first message. Tool-role results already represented by those events do not produce duplicate rows. User messages, including Lead, and assistant replies without tools remain separate boundaries. Streaming prose stays visible until structured calls arrive. No stored message, prompt, permission or execution policy changes.

The entire group header toggles expansion. Its summary shows the action count, the first unresolved call of the active assistant, and separate failed/denied counts. Pending calls without an active turn remain labelled as missing results, never shown as successful. Host interruption/error text remains visible even when collapsed. Expansion preserves round order, narration, thinking, feedback and each existing tool disclosure. Native file/command actions receive concise path/query/command labels; arbitrary external tools retain server/tool identity. Memory retains its existing detail popover.

Grouping happens after selecting at most 40 messages, preserving the measured-window limit and Earlier/Later navigation. A long run may therefore span windows. Each group retains its first message identity as rounds arrive within that window. No insertion animations or estimated layout heights are added. Newly sent user/Lead messages rearm scroll following; additional assistant/tool rounds only follow if the reader was already following.

## Validation

Regression checks cover grouping boundaries, stable growing identity, original object/data retention, paging through a long run, failed/denied/queued/stopped states, descriptive labels, and native header-click expansion/collapse. The existing font/width reflow and reader-scroll tests remain part of full verification.
