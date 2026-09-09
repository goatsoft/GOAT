# ADR-0041: Public website as a Vite + Vue single-page app

**Status:** Accepted · 2026-09-05 · refines 0018

## Context

ADR-0018 shipped `web/` as one hand-written `index.html`. That was right for a placeholder and wrong for a public face: no components, no motion system, copy and layout tangled in one 230-line file, and a Google Fonts call on every load. The site needs to sell the app the way the app sells itself (Caprine tokens, Midnight, real product mechanics on screen) and stay cheap for one person to keep current.

## Decision

`web/` is a **Vite 8 + Vue 3 SPA**, built in CI and deployed to GitHub Pages from `web/dist`.

**Stack (all build-time; the deployed site is static files):**

- `unplugin-vue-router` for file-based routes in `src/pages/`, `unplugin-auto-import` for Vue/Router/motion composables and everything in `src/composables` and `src/lib`, `unplugin-vue-components` for `src/components`, `unplugin-icons` (Lucide + Simple Icons, tree-shaken SVG). No global store: shared state is composables.
- **Tailwind v4** with the Midnight theme's Caprine tokens (`ThemeCatalog.swift`) mapped onto shadcn semantic variables in `src/assets/main.css`. Colors in components go through those tokens, same rule as the app.
- **shadcn-vue-style primitives** (`src/components/ui/*`, `reka-ui` + `class-variance-authority`) with explicit `cva` variants: `Button` (default / aurora / outline / ghost / glass / link), `Badge`, `Card`.
- **motion-v** for entrance reveals, the hero parallax, and the scroll-telling feature section (`useScrollSteps` picks the copy block nearest a focal line and swaps a sticky app-window mock).
- **GPU backgrounds.** `AuroraCanvas` renders a domain-warped fbm aurora shader: WebGPU (WGSL) when available, WebGL2 (GLSL) otherwise, a static CSS gradient when neither exists or the user prefers reduced motion. Capped at 0.5x DPR, paused off-screen and in hidden tabs. One instance is pinned behind the page; sections use small local instances. This replaced CSS/SVG blur animations, which repainted and flickered.
- **No third-party requests at runtime.** System font stack (SF on a Mac, which is the audience), self-hosted images, no analytics. The site keeps the Herd Guarantee's spirit even though it is not the app.

**Screenshots are built, not captured.** `src/components/mock/*` are DOM renderings of GOAT surfaces (chat + nerd stats, effort dial, Paddock, MCP gate, memory map) inside a `AppWindow` frame. They animate, they stay in sync with copy, and they never go stale against a build. Real screenshots can replace them per section when the product is presentation-ready (ADR-0038).

**Deploy:** `pages.yml` runs `npm ci && npm run build` with `VITE_BASE=/<repo>/` (project-site path; set to `/` when a custom domain lands) and uploads `web/dist`. `public/404.html` is a copy of `index.html` so deep links survive Pages' lack of rewrites. `public/.nojekyll` stays.

**Public/corporate only.** The site shows Light, Pasture, and Midnight. The 1337 theme, goaties, and other whimsy are app-internal (DESIGN.md §1.3 whimsy budget) and do not appear on the public site.

## Consequences

- `web/` gains `node_modules` and a `package-lock.json`; CI needs Node 22+. `npm run build` also runs `vue-tsc` so type errors fail the deploy.
- `.gitignore` already excludes `web/dist/`; the built site is never committed.
- Build config is `web/.env` (tracked; public values only): `VITE_REPO` and `VITE_BASE`, both overridden by CI from the GitHub context, so nothing needs editing when the repo goes public. Secrets never go there; `.env.local` is ignored.
- Design tokens are duplicated between Swift and CSS by hand. Acceptable at three themes; if the site ever needs all themes, generate `main.css` from `ThemeCatalog` JSON (ADR-0022 already exports it).

## Alternatives considered

Keep the static HTML (rejected: no components, no motion system, fonts from Google); Nuxt (rejected: SSR/Nitro machinery for a one-page static site; the unplugin set gives the Nuxt DX without the runtime); Astro (rejected: fine for content sites, but the mocks are interactive Vue islands end to end, so a Vue SPA is simpler); prerendering with `vite-ssg` (deferred: the head tags already live in `index.html`, and a one-route site gains little; revisit if routes multiply or SEO demands per-route meta).
