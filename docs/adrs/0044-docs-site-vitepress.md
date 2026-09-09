# ADR-0044: Docs site as VitePress over `docs/`, served beside the landing page

**Status:** Accepted · 2026-09-05 · Extends [ADR-0041](0041-website-as-vite-vue-spa.md); retires the GitHub Wiki step in GITHUB-SETUP.md

## Context

The plan was to copy `docs/wiki/*.md` into the repo's GitHub Wiki at go-public. That gives a wiki, not documentation: no design control, weak search, a separate repo with no PR review, and pages Google barely indexes. Meanwhile `docs/` already holds the real reference material (engine contract, themes, design, versioning, 43 ADRs) that a wiki would only duplicate. The bar is first-class docs in the Vue/Nuxt mould: markdown in, static site out, no database, light and dark, search, and the same identity as the landing page rather than a stock theme.

## Decision

**VitePress**, configured in `web/docs/.vitepress/`, with `srcDir` pointing at the repo's **`docs/`** folder. Built into `web/dist/docs/` by the existing Pages workflow and served at `<site>/docs/`.

**One source tree, no copies.** `docs/wiki/*.md` are lifted to the site root by `rewrites` (`wiki/Home.md` → `/`, `wiki/Engines.md` → `/Engines`); reference docs and `adrs/` keep their paths; `PLAN.md` and `GITHUB-SETUP.md` are excluded (agent and owner material). The wiki pages stay GitHub-Wiki compatible on disk, `[[Page]]` links and `../blob/main/...` relative links included, so the wiki could be enabled later without editing them; nothing syncs it today.

**Four plugin layers, all in the repo:**

- *markdown-it*: `wikilinks.ts` turns `[[Getting Started]]` into `/Getting-Started` (GitHub's own slug rule, case kept); `repolinks.ts` resolves the wiki's GitHub-relative links (`../blob/main/docs/ENGINES.md` → the built page, `../releases/latest` → the repo) and rewrites any relative link that escapes `docs/` (`../../AGENT.md`) to a `blob/main` URL. Dead-link checking stays on; the build fails on a broken link.
- *Vite*: `goat-data.ts` serves `virtual:goat-data`: every ADR (number, title, status) parsed from `docs/adrs/`, and the release identity (`0.1 (Kid)` per VERSIONING.md) read from `release.json` when ADR-0040 lands, `project.yml` until then. The ADR sidebar and the nav release badge come from it, so neither goes stale.
- *build hooks*: `transformPageData` gives `wiki/Home.md` the `home` layout at build time, since frontmatter in the file would render as a table on GitHub.
- *theme*: `theme/` extends the default theme: Caprine tokens (Light for light, Midnight for dark) mapped onto `--vp-c-*`; nav, sidebar and cards go glass; the landing page's `AuroraCanvas` (WebGPU → WebGL2 → CSS, paused off-screen, frozen under Reduce Motion) is imported from `web/src` and pinned behind the page; the home hero is the landing page's hero condensed (`Masthead` + Midnight art + a local aurora, masked into the page); the wordmark cycles, page content reveals on navigation. `<ReleaseBadge />` and `<AdrList />` are global components any page can use.

**Search** is VitePress's local provider (MiniSearch index built at build time, queried in the browser). No Algolia, no runtime third-party requests, same rule as the landing page (ADR-0041).

**Tooling lives in `web/package.json`** (`vitepress@next`, the 2.0 line on Vite 8 to match the landing site), one `node_modules`, one lockfile, one CI cache. `npm run docs:dev` for local work, `npm run build:all` for what CI runs.

## Consequences

- Public docs now include everything under `docs/` except the two excluded files. Writing there is writing for the site: keep prose free of bare `<angle-brackets>` outside code spans (Vue parses them) and make relative links resolve.
- `pages.yml` also triggers on `docs/**` and on the release identity files.
- VitePress 2 is alpha. It is what vuejs.org runs on and the surface we use (config, markdown-it, theme slots) is the stable 1.x API, but pin bumps deliberately.
- Design tokens are now hand-copied in three places (Swift, `main.css`, `goat.css`). Same escape hatch as ADR-0041: generate from `ThemeCatalog` JSON if it becomes a problem.
- `web/docs/.vitepress/{dist,cache}` are build outputs and git-ignored.

## Alternatives considered

GitHub Wiki (rejected: not first-class; see Context). Nuxt Content (rejected: excellent, and its SQLite is build-time/WASM so still static, but it brings Nuxt into a Vite SPA repo for nothing VitePress lacks). Roll our own on `unplugin-vue-markdown` inside the existing SPA (rejected: sidebar, outline, prev/next, search, code groups and dark mode would all be rebuilt; VitePress is that, maintained by the Vue team, and its plugin layers give the same freedom). Starlight, Docusaurus, MkDocs Material (rejected: wrong stack).
