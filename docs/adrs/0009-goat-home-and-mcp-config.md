# ADR-0009: GOAT home directory (`~/.goat`) and file-based MCP config

**Status:** Accepted · 2026-08-29 · Amends the config-storage clause of [ADR-0006](0006-mcp-integration.md), refined by [ADR-0033](0033-exclusive-pen-and-global-memory-scopes.md)

## Context

M4 needs a home for MCP server config. ADR-0006 said "GRDB, edited via native forms." JB's counter-proposal: a `~/.goat` directory with `config/mcp-servers.json`, working dir configurable in Settings.

The ecosystem settles it. Every MCP server README says "add this JSON to your config." Claude Desktop's `mcpServers` shape is the lingua franca; dotfile homes are the dev-tool norm (`~/.claude`, `~/.ssh`, `~/.config`). A database row cannot be pasted from a README, hand-fixed in BBEdit, or checked into a dotfiles repo. GOAT's audience is exactly the people who do all three.

## Decision

**Two roots, one rule: files you own live in the GOAT home; machine state lives in App Support.**

```
~/.goat/                          # GOAT home: yours. Default; overridable.
├── config/
│   └── mcp-servers.json          # Claude Desktop-compatible (see below)
└── memory/                       # the wiki moves here from App Support (ADR-0005 intent: "a folder you own")
    ├── MEMORY.md                 # global Markdown index + notes
    └── llm-wiki/                 # global LLM Wiki authority

~/.goat/projects/<name>_<uuid>/   # Pen control folder
└── memory/                        # Pen-only local memory

~/Library/Application Support/GOAT/   # machine state: the app's
├── goat.sqlite                       # chats, projects, tool grants, call log
├── Attachments/
└── Logs/
```

- **Home resolution:** `GOAT_HOME` env var → Settings override (Settings → General, "GOAT home") → `~/.goat`.
- **`mcp-servers.json` format:** Claude Desktop's `mcpServers` map, verbatim semantics. An entry with `command`/`args`/`env` is a stdio server; an entry with `url`/`headers` is Streamable HTTP. GOAT extension keys are additive (`"disabled": true` first). Import from Claude Desktop = read the same shape and merge, near enough to a file copy.
- **The file is the source of truth.** Settings → MCP renders a native editor over it, plus "Open Config File" for hand edits; a file watcher hot-reloads and reconnects changed servers. Invalid JSON never crashes: Settings shows the parse error inline with an open-in-editor button.
- **Not in the file:** per-tool permission grants and the call log stay in GRDB. Connection config is shareable; security state is not. A pasted config must never smuggle in "always allow".

## Consequences

README snippets paste straight in; configs are versionable (dotfiles repo away); Claude Desktop import becomes trivial; the memory folder gets more discoverable than a hidden Library path. Costs: hand edits can break JSON (validated, surfaced inline, never fatal), and two storage roots to document. The yours-vs-the-app's split is the documentation. ADR-0006's native-forms UI survives, now as an editor over the file.

## Alternatives considered

GRDB-only (rejected: fights the paste-a-snippet ecosystem), JSON in App Support (rejected: hidden from the people who hand-edit it), TOML/YAML (rejected: the ecosystem speaks this exact JSON dialect).
