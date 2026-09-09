# GOAT LLM Wiki contract

The local LLM Wiki is a distinct `MemoryStore` provider. It is not an alternate label or
on-disk representation for Markdown (local).

## Authority and layout

For the application scope, its root is `~/.goat/memory/llm-wiki`. For a Pen, its root is
`~/.goat/projects/<short-name>_<uuid>/memory/llm-wiki`. The root contains five stable
authorities:

```text
raw/       # immutable, captured source documents; never rewritten by GOAT or the model
wiki/      # curated, model-maintained Markdown pages with canonical frontmatter and links
AGENTS.md  # the provider's machine-readable maintenance schema and workflow
index.md   # regenerated content catalogue of curated wiki pages
log.md     # append-only, chronological record of ingest, query, and lint operations
```

Raw material is the source of truth. The model may read it but cannot edit or delete it.
The wiki is a compounding derived artifact: the model may create and revise pages, adds
`[[wikilinks]]`, records claims' raw-source identifiers, and calls out contradictions rather
than silently replacing them. `AGENTS.md` is the only authority for the required ingest,
query, and maintenance sequence. `index.md` and `log.md` are provider-generated and are not
ordinary memory notes.

## Operations

`wiki_ingest_source` captures one bounded source immutably, appends an ingest record, and
returns an opaque source ID. The model reads that source, updates one or more curated pages,
and records source citations. `memory_list`, `memory_read`, and `memory_write` operate only
on the curated wiki. `wiki_query` starts at `index.md`, then returns bounded matching page
metadata; it never performs embedding retrieval. `wiki_lint` deterministically checks the
schema, index freshness, source citations, exact wikilinks, orphan pages, and malformed log
records; it reports issues and never silently edits the wiki.

The prompt digest is selected only from curated pages by `PromptBudgeter`. Raw sources, the
schema, index, and log remain available through tools and browser sections but are not injected
as chat context. This keeps the prompt budget independent of an archive's size.

## Native map

Settings and Pens share one provider-aware browser: **Pages** is always available, while **Map**
and **Connections** are available only for the active LLM Wiki. Selecting a Page row or any map
node opens the same safe, rendered Markdown document in a dedicated GOAT popup; source nodes open
their immutable raw document without making it editable. Known `[[wiki-links]]` and relative
Markdown document links open in that same popup, whose Back control preserves the browsing trail
without changing any stored document.

The native desktop map shows circles for curated memory pages, lines for exact wiki links, and
document tiles for saved sources cited by a page. Its compact legend identifies the two node types;
the count sits at the bottom left so the map heading stays uncluttered. It supports expected Mac
interactions: drag the background to pan, use the scroll wheel or a trackpad pinch to zoom around
the pointer, right-drag in any direction to rotate, hover a node to inspect it, and click a node to open it. Hovering
a memory page also sends small direction-of-link dots along its connected wiki links. The reset and
zoom controls affect only the graph viewport; they never scale the surrounding labels or controls.
When a page is hovered, its direct links are foregrounded, one-hop context is softened, and more
distant links recede; this preserves a useful reading path as the map becomes dense.

The store actor supplies bounded curated-page material and source metadata. A detached,
Sendable-only builder validates links and runs a deterministic force layout before the `@MainActor`
Canvas maps the graph into its viewport. The separate **Connections** tab uses native Swift Charts
to compare how many page links and source citations each page has; Charts owns axes, category
spacing, and accessible values, while Canvas owns the arbitrary node-link graph. Markdown (local)
remains a Pages surface; Hindsight does not fabricate a graph where its provider cannot supply one.
This adds no graph dependency.

## Provider lifecycle

Each chat/Pen has one active provider binding. Selecting LLM Wiki activates only this root;
the inactive Markdown provider remains intact and discoverable, with no automatic import,
merge, mirroring, or deletion. Any future Markdown-to-Wiki import is explicit, one-way, and
creates raw source records before derived pages.
