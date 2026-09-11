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

### HTTPS and phone testing

Use HTTPS when testing WebGPU on another device. Create a certificate with an existing local development CA, such as `mkcert`, including the Mac's current LAN address. Store certificate files outside the repository and `public/`.

Run from `web/`, replacing the address and certificate paths:

```sh
npm run dev:https -- --host <mac-lan-address> --cert <certificate.pem> --key <private-key.pem>
```

The website listens on HTTPS port 5176, with docs under `/docs/`. The docs backend listens only on loopback port 5179. Both sites use the same public origin for navigation and live reload. Override the ports with `--port` and `--docs-port`. The command fails if either port is occupied; it never stops an existing server.

Install only the CA's public certificate on test devices. On iOS, install the certificate profile, then enable it in Settings → General → About → Certificate Trust Settings. Keep private keys on the development Mac. A certificate warning bypass is not a substitute for a trusted certificate. See [Apple's certificate trust instructions](https://support.apple.com/en-ie/102390).

### Aurora rendering

`AuroraCanvas` adapts Vue props and browser visibility to a framework-independent rendering protocol. A page shares one worker, WebGPU device and pipeline across its canvas surfaces. The worker draws at up to 30 frames per second, caps each surface's dimensions and waits for its GPU batch before submitting another. Hidden surfaces stop drawing; reduced motion draws a still frame and refreshes it when inputs change.

Worker setup is checked before transferring a canvas. Unsupported desktop browsers can use the existing main-thread WebGPU or WebGL2 renderer. Touch devices without worker WebGPU use CSS. A worker failure after transfer restores CSS because canvas ownership cannot be transferred back into a normal main-thread context. The last component to unmount terminates the worker. See [ADR-0079](../docs/adrs/0079-shared-aurora-worker.md).

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

Release identity comes from `../apps/goat-macos/release.json`. `publication.json` controls download availability independently. Leave `releaseTag` null until an approved artifact exists. Set it to the exact `v<version>` tag and record its `codename` only as part of an authorised launch. When the source version advances, keep this record on the existing published release until the new artifact is available; its download filename and label continue to use the published identity. The sites do not query GitHub for releases at runtime.

## Publication

The [Pages workflow](../.github/workflows/pages.yml) is manual. Pushes and visibility changes do not publish the sites. Deployment requires public repository visibility, the `PAGES_PUBLISH_ENABLED` repository variable set to `true`, and an explicit workflow dispatch from `main` with publication selected.

The landing site publishes through the GOAT repository’s Pages environment at goatapp.dev. Documentation publishes built files to the `gh-pages` branch of goatsoft/goatherd.dev, using the `GOATHERD_DEPLOY_KEY` secret. Configure a dedicated write-enabled deploy key for that target repository; keep its private key in Actions secrets only. Set the docs repository’s Pages source to that branch. Confirm domain verification, DNS and HTTPS for both sites before enabling publication.

The workflow includes `deploy/goatherd-README.md` as the published repository's README. Edit that source file so the next deployment preserves your changes.

Review both builds locally, publication state, reporting contacts, licence notices, navigation and the exact release artifact before dispatching. Deployment is a separate decision from a successful build. See [Release readiness](../docs/RELEASE-CHECKLIST.md).

## Dependencies and attribution

Use the lockfile and `npm ci`. Refresh the distribution notices when dependencies or embedded assets change, following [Distribution](../docs/DISTRIBUTION.md). The sites load their own assets and search index; do not add external scripts, fonts, analytics or embeds without updating the privacy design and disclosure.

Keep design tokens in `src/assets/main.css`, links in `useSite()` and technical implementation details out of visitor-facing copy. See [ADR-0041](../docs/adrs/0041-website-as-vite-vue-spa.md) and [ADR-0044](../docs/adrs/0044-docs-site-vitepress.md) for the architectural decisions.

Run `npm run test:unit` for graphics lifetime regressions. The tests use Node’s built-in runner and delayed GPU fixtures, including teardown during adapter/device acquisition.
