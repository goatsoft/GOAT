# Website and documentation

GOAT’s landing site uses Vue and Vite. The documentation uses VitePress over the repository’s `docs/` directory. Both produce static files for GitHub Pages. The existing visual language is shared; product copy lives in page components and documentation stays in Markdown.

## Local development

Run these commands from `web/` with Node.js 22 or later:

```sh
npm ci
npm run dev:all     # landing site on 5173, docs proxied from 5174
npm run build:all   # landing site in dist/, docs also copied to dist/docs/
npm run check:content # built links, anchors and copied licence files
npm run preview    # inspect the combined output on port 4173
```

Use `npm run dev` or `npm run docs:dev` to work on one site. `npm run build` includes Vue type checking; `npm run docs:build` fails on broken document links. A local environment with restricted file watchers can use `CHOKIDAR_USEPOLLING=1` for builds.

## Edit the content

| Source | Responsibility |
| --- | --- |
| `src/components/section/` | Landing page copy and layout. |
| `src/components/mock/ProductMock.vue` | Hero and six feature illustrations, using fictional content. |
| `src/components/mock/AppWindow.vue` | Shared illustrative native window and sidebar. |
| `src/composables/useSite.ts` | Navigation, repository and release links. |
| `../docs/overview/`, `../docs/how-to/`, `../docs/reference/` | Concepts, tasks and detailed reference. |
| `../docs/wiki/` | Established introductory routes and contributor guides. |
| `docs/.vitepress/config.ts` | Documentation navigation, search and route rewrites. |
| `../docs/GLOSSARY.md` | Short term definitions shared by both sites. |
| `../LICENSE`, `../LICENSE-ART.md`, `../THIRD-PARTY-NOTICES.md`, `../docs/PRIVACY.md` | Source for the landing site’s legal dialogs. |

Keep interface illustrations consistent with the current app. Do not fabricate benchmark results, completed work or live network measurements. Preserve native labels where they help readers recognise a control. The seven scenes are `hero`, `coding`, `pens`, `memory`, `previews`, `extensions` and `connections`.

Documentation wiki pages retain their established root routes. ADR and reference directories retain their paths; their README pages become indexes. The link plugin handles relative Markdown links and links to source files in GitHub. Put literal angle brackets inside code spans to avoid Vue parsing them as components.

## Public configuration

The tracked `.env` contains public build values only. `VITE_REPO` selects the source repository, `VITE_SITE_URL` the landing URL, `VITE_DOCS_URL` the separate docs URL and `VITE_BASE` the deployment path. `.env.example` documents these values. Never put secrets in `VITE_*` variables: they can be included in the browser bundle.

Release identity comes from `../apps/goat-macos/release.json`. `publication.json` controls download availability independently. Leave `releaseTag` null until an approved artifact exists. Set it to the exact `v<version>` tag only as part of an authorised launch. The sites do not query GitHub for releases at runtime.

## Publication

The [Pages workflow](../.github/workflows/pages.yml) is manual. Pushes and visibility changes do not publish the sites. Deployment requires public repository visibility, the `PAGES_PUBLISH_ENABLED` repository variable set to `true`, and an explicit workflow dispatch from `main` with publication selected.

The landing site publishes through the GOAT repository’s Pages environment at goatapp.dev. Documentation publishes built files to the `gh-pages` branch of goatsoft/goatherd.dev, using the `GOATHERD_DEPLOY_KEY` secret. Configure a dedicated write-enabled deploy key for that target repository; keep its private key in Actions secrets only. Set the docs repository’s Pages source to that branch. Confirm domain verification, DNS and HTTPS for both sites before enabling publication.

The workflow includes `deploy/goatherd-README.md` as the published repository's README. Edit that source file so the next deployment preserves your changes.

Review both builds locally, publication state, reporting contacts, licence notices, navigation and the exact release artifact before dispatching. Deployment is a separate decision from a successful build. See [Release readiness](../docs/RELEASE-CHECKLIST.md).

## Dependencies and attribution

Use the lockfile and `npm ci`. Refresh the distribution notices when dependencies or embedded assets change, following [Distribution](../docs/DISTRIBUTION.md). The sites load their own assets and search index; do not add external scripts, fonts, analytics or embeds without updating the privacy design and disclosure.

Keep design tokens in `src/assets/main.css`, links in `useSite()` and technical implementation details out of visitor-facing copy. See [ADR-0041](../docs/adrs/0041-website-as-vite-vue-spa.md) and [ADR-0044](../docs/adrs/0044-docs-site-vitepress.md) for the architectural decisions.

Run `npm run test:unit` for graphics lifetime regressions. The tests use Node’s built-in runner and delayed GPU fixtures, including teardown during adapter/device acquisition.
