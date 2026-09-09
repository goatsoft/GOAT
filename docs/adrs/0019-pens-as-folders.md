# ADR-0019: Pens (projects) are folders you own

**Status:** Accepted · 2026-08-30

## Context

"Projects" grouped chats with a shared instruction blob, stored as a row in GRDB. It was thin: the instructions were invisible outside the app, there was no place for per-project agent guidance or referenced files, and the create UI was a bare form. Meanwhile memory already follows a principle that works: *a folder you own, in plain files* (ADR-0009). Projects should too.

## Decision

Rename the concept to **Pens** (a pen is an enclosure for the herd) and store each as a folder under **`~/.goat/projects/<slug>/`**:

```
~/.goat/projects/<slug>/
├── project.json   # PenSpec: id, name, emoji, OKLCH colour, createdAt, file refs
├── README.md      # the instructions: your brief
├── AGENTS.md      # the agent guide (references README); a GOATed coding template
└── CLAUDE.md      # one line → AGENTS.md
```

- **Files are the source of truth.** `PenStore` (GoatCore) reads/writes the folder; the app holds an observable `Pen`. GRDB keeps only the chat→pen link (the existing `chat.projectId` column, unrenamed to avoid a migration).
- **AGENTS.md is the injected brief.** A chat in a Pen gets the Pen's `AGENTS.md` in its system prompt (which points at README.md), so guidance is standard and hand-editable. AGENTS.md is scaffolded once from a coding-methodology template, then it's yours.
- **Colour is OKLCH.** Pens carry a perceptually-uniform `OKLCH` colour (custom picker; no native OKLCH exists), shown as the sidebar dot and the landing-page accent.
- **Files are references, not copies.** A Pen stores paths + security-scoped bookmarks. It points at your files, keeping Pens tiny.
- **A landing page.** Selecting a Pen shows its page (header, instructions editor, files, chats) instead of a chat.
- **Migration.** On first launch with old DB projects and no folders, they're copied into `~/.goat/projects` once; the DB rows are left in place, harmlessly.

## Consequences

Pens are inspectable, portable, and editable outside GOAT, same ethos as memory. AGENTS.md/CLAUDE.md make each Pen a real agent workspace, aligned with the emerging `AGENTS.md` convention. The one wart: the DB column and a few internal helpers still say `project`, kept to avoid a schema migration for a cosmetic rename, noted, not load-bearing.

## Alternatives considered

Keep projects in GRDB (rejected: opaque, no room for agent guidance or files); one big `project.json` holding the prose too (rejected: prose wants to be real Markdown files you can open in any editor); copying referenced files into the Pen (rejected: bloats Pens, defeats "small and optimised"); native `ColorPicker` (rejected: sRGB, off-brand; see the OKLCH note).
