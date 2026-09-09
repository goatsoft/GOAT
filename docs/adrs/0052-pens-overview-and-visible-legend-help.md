# ADR-0052: Pens overview and visible legend help

**Status:** Accepted · 2026-09-06 · Refines [ADR-0051](0051-typed-memory-relationship-direction.md)

## Context

Delayed native SwiftUI help did not reliably appear on the map's compound legend labels. The Pens
list also showed a fixed Dedicated memory claim and excluded pinned chats from its count, giving
an incomplete picture of each Pen's configuration.

## Decision

Legend entries are plain buttons with full rectangular targets. A native per-entry tracking area
detects hover and opens help on pointer clicks alongside the AppKit canvas. SwiftUI retains keyboard
and accessibility activation. The native target never takes keyboard focus and forwards scrolling.
There is no application-wide event monitor. Hovering shows a themed explanation
anchored above the legend, and clicking or keyboard activation also shows it. The explanation
renders outside the legend's horizontal scroll clip, passes pointer events through, and consumes
no layout height. VoiceOver retains the same explanations. Moving away dismisses hover help.

The Pens overview uses adaptive themed cards with the Pen icon in a rounded-square badge matching Settings headers, folder path,
actual memory provider and effective state, all belonging chats including pinned ones, additional
file count, instructions status and last chat activity. A saved Grid/List preference switches between
SwiftUI LazyVGrid and compact LazyVStack rows; ViewThatFits stacks row details in narrow layouts.
The navigation arrow stays at the top-right, memory uses two lines, and no empty instructions
prompt consumes card space. Search covers names,
instructions, folders and provider names. Sort supports recent activity, name and creation date.
Cards offer Open, New Chat, Folder and Edit, plus copying the folder path from the context menu.
New Chat opens the existing composer and sends nothing automatically.

All summaries derive from existing observable model state. The overview performs no per-card file
reads, Git scans, inference or memory-service requests. A configured folder is not represented as
verified accessible; an unsuccessful open surfaces an error. Memory distinguishes loading,
unavailable, off, globally paused and ready. No new dependency or persistence format is introduced.

## Consequences

The overview is useful without misleading health claims or eager I/O. Regression tests cover the
memory-state gates; live checks cover tooltip hit targets and adaptive card layout. Configuration
and content management continue through the existing Pen and Edit flows.
