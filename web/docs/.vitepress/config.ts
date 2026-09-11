import { fileURLToPath, URL } from 'node:url'
import { resolve } from 'node:path'
import { defineConfig } from 'vitepress'
import AutoImport from 'unplugin-auto-import/vite'
import { wikilinks } from './plugins/wikilinks.ts'
import { repolinks } from './plugins/repolinks.ts'
import { mermaid } from './plugins/mermaid.ts'
import { goatGlossary, glossaryLinks } from './plugins/goat-glossary.ts'
import { existsSync } from 'node:fs'
import { goatData, readAdrs } from './plugins/goat-data.ts'
import { referenceRoutes } from '../../src/lib/doc-routes.ts'

/**
 * GOAT docs: VitePress over the markdown that already lives in docs/ (ADR-0044).
 *
 * Root of the docs source is the repo's docs/ folder: the wiki pages (kept
 * GitHub-Wiki compatible) are lifted to the site root, the reference docs and ADRs
 * keep their paths. Deployed at <site>/docs/ next to the landing page.
 */
const repoRoot = fileURLToPath(new URL('../../../', import.meta.url))
const webRoot = fileURLToPath(new URL('../../', import.meta.url))
const webSrc = resolve(webRoot, 'src')
const repo = process.env.VITE_REPO || 'goatsoft/GOAT'
const siteBase = process.env.VITE_BASE || '/'
// The landing page's absolute URL. A root-relative link would get the docs base prefixed,
// so it must be absolute: CI sets VITE_SITE_URL; locally `vite preview` serves both at 4173.
const siteUrl = process.env.VITE_SITE_URL
  || (process.env.VITE_BASE ? `https://${repo.split('/')[0]!.toLowerCase()}.github.io${siteBase}` : 'http://localhost:4173/')
const docsDir = resolve(repoRoot, 'docs')
const excluded = ['PLAN.md', 'GITHUB-SETUP.md', 'content-plan/**']
const isExcluded = (path: string) => excluded.includes(path) || path.startsWith('content-plan/')
const glossaryFile = resolve(repoRoot, 'docs/GLOSSARY.md')
// Production: the docs own a domain (VITE_DOCS_URL=https://goatherd.dev/) and sit at its root.
// Otherwise they nest under the landing site as <site>/docs/ (dev, previews, project Pages).
const docsUrl = process.env.VITE_DOCS_URL
const docsBase = docsUrl ? '/' : `${siteBase.replace(/\/$/, '')}/docs/`
const adrs = readAdrs(resolve(docsDir, 'adrs'))

export default defineConfig({
  title: 'GOAT Docs',
  description: 'Set up GOAT, work with local models and project tools, and find practical guides and technical reference.',
  lang: 'en-AU',
  base: docsBase,
  srcDir: '../../docs',
  srcExclude: excluded,
  rewrites: {
    ...Object.fromEntries(Object.entries(referenceRoutes).map(([source, route]) => [`${source}.md`, `${route}.md`])),
    'wiki/Home.md': 'index.md',
    'wiki/:page.md': ':page.md',
    'adrs/README.md': 'adrs/index.md',
    'reference/README.md': 'reference/index.md',
  },
  cleanUrls: true,
  lastUpdated: true,
  appearance: 'dark',
  head: [
    ['link', { rel: 'icon', href: `${docsBase}img/favicon.png` }],
    ['meta', { name: 'theme-color', content: '#0a0b14' }],
    ['meta', { property: 'og:image', content: `${docsUrl ?? docsBase}img/og.jpg` }],
  ],
  ignoreDeadLinks: [/localhost/],

  markdown: {
    config(md) {
      md.use(wikilinks)
      md.use(mermaid)
      md.use(glossaryLinks, { file: glossaryFile })
      md.use(repolinks, {
        repo, root: repoRoot, docsDir,
        isPage: (p: string) => p.endsWith('.md') && !isExcluded(p) && existsSync(resolve(docsDir, p)),
      })
    },
    theme: { light: 'github-light', dark: 'github-dark-dimmed' },
  },

  vite: {
    // Share the landing site's images (web/public/img) so logo and hero resolve in dev too.
    publicDir: resolve(webSrc, '../public'),
    plugins: [
      goatData({ root: repoRoot, repo }),
      goatGlossary({ file: glossaryFile, glossaryUrl: `${docsBase}GLOSSARY`, docsUrl: docsBase }),
      // The landing site's components (AuroraCanvas & co.) rely on auto-imported Vue APIs.
      AutoImport({ imports: ['vue'], dts: false }),
    ],
    resolve: {
      // The markdown source sits outside web/, so bare imports the compiled pages
      // make (vue, vue/server-renderer) are pinned to web/node_modules by hand.
      alias: [
        { find: '@', replacement: webSrc },
        { find: /^vue\/server-renderer$/, replacement: resolve(webRoot, 'node_modules/vue/server-renderer') },
        { find: /^vue$/, replacement: resolve(webRoot, 'node_modules/vue') },
      ],
      dedupe: ['vue'],
    },
    // Only public config crosses into the docs bundle; secrets never live in .env.
    define: {
      'import.meta.env.VITE_REPO': JSON.stringify(repo),
    },
  },

  transformPageData(page) {
    // The wiki's Home.md is the site index. Layout only: the hero is GoatHero.vue in the
    // theme, and frontmatter in the file would render as a table on GitHub.
    if (/(^|\/)wiki\/Home\.md$/.test(page.filePath)) page.frontmatter.layout = 'home'
  },

  themeConfig: {
    logo: { light: '/img/goat-light.webp', dark: '/img/goat-dark.webp', alt: '' },
    siteTitle: 'GOAT',
    nav: [
      { text: 'Start here', link: '/Getting-Started' },
      { text: 'Guides', link: '/overview/GOAT' },
      { text: 'Reference', link: '/reference/' },
      { text: 'Contribute', link: '/Contributing' },
      { text: 'Website', link: siteUrl, target: '_self', noIcon: true },
    ],
    sidebar: {
      '/adrs/': [{ text: 'Architecture decisions', link: '/adrs/', items: adrs.map(a => ({ text: `${a.id} · ${a.title}`, link: `/adrs/${a.file.replace(/\.md$/, '')}` })) }],
      '/': [
        { text: 'Start here', items: [
          { text: 'Getting started', link: '/Getting-Started' },
          { text: 'Understand GOAT', link: '/overview/GOAT' },
          { text: 'Models and engines', link: '/overview/MODELS' },
          { text: 'Tools and permissions', link: '/overview/TOOLS' },
          { text: 'Memory and Pens', link: '/Memory-and-Pens' },
          { text: 'Extensions and skills', link: '/Extensions' },
        ] },
        { text: 'Practical guides', items: [
          { text: 'Connect an engine', link: '/Engines' },
          { text: 'Create a Pen', link: '/how-to/CREATE-A-PEN' },
          { text: 'Work on code', link: '/how-to/WORK-ON-CODE' },
          { text: 'Guide work with Lead', link: '/how-to/LEAD' },
          { text: 'Manage permissions', link: '/how-to/PERMISSIONS' },
          { text: 'Connect Hindsight', link: '/how-to/HINDSIGHT' },
          { text: 'Inspect previews', link: '/how-to/PREVIEWS' },
          { text: 'Add MCP tools', link: '/how-to/MCP' },
          { text: 'Install packages', link: '/GOATed-Packages' },
          { text: 'Connection controls', link: '/JUDAS' },
          { text: 'Appearance', link: '/Appearance' },
          { text: 'Reset and uninstall', link: '/how-to/MANAGE-GOAT-DATA' },
          { text: 'Read statistics', link: '/Nerd-Stats' },
          { text: 'Use the CLI', link: '/CLI-and-API' },
        ] },
        { text: 'Reference', collapsed: true, items: [
          { text: 'Reference index', link: '/reference/' },
          { text: 'Engines', link: '/reference/engines' },
          { text: 'Permissions', link: '/reference/PERMISSIONS' },
          { text: 'Connection policy', link: '/reference/CONNECTIONS' },
          { text: 'Storage and backups', link: '/reference/STORAGE' },
          { text: 'Memory browser', link: '/reference/MEMORY' },
          { text: 'Statistics', link: '/reference/STATISTICS' },
          { text: 'CLI and API', link: '/reference/CLI-API' },
          { text: 'Extension API', link: '/reference/extensions' },
          { text: 'Package format', link: '/reference/PACKAGES' },
          { text: 'Theme format', link: '/THEMES' },
          { text: 'LLM Wiki contract', link: '/llm-wiki-contract' },
          { text: 'Glossary', link: '/GLOSSARY' },
        ] },
        { text: 'Support', items: [
          { text: 'Troubleshooting', link: '/how-to/TROUBLESHOOTING' },
          { text: 'FAQ', link: '/FAQ' },
          { text: 'Public preview', link: '/PUBLIC-PREVIEW' },
          { text: 'Known issues', link: '/KNOWN-ISSUES' },
          { text: 'Release notes', link: '/RELEASE-NOTES' },
          { text: 'Privacy', link: '/PRIVACY' },
        ] },
        { text: 'Contribute', collapsed: true, items: [
          { text: 'Contributor guide', link: '/Contributing' },
          { text: 'Architecture overview', link: '/Architecture' },
          { text: 'Architecture reference', link: '/reference/architecture' },
          { text: 'Modules', link: '/MODULES' },
          { text: 'Design', link: '/DESIGN' },
          { text: 'Pronk example', link: '/Pronk-Example' },
          { text: 'Roadmap', link: '/ROADMAP' },
          { text: 'Release readiness', link: '/RELEASE-CHECKLIST' },
          { text: 'Distribution', link: '/DISTRIBUTION' },
          { text: 'Releasing', link: '/Releasing' },
          { text: 'Versioning', link: '/VERSIONING' },
          { text: 'Codenames', link: '/CODENAMES' },
          { text: 'Architecture decisions', link: '/adrs/' },
        ] },
      ],
    },
    socialLinks: [{ icon: 'github', link: `https://github.com/${repo}` }],
    editLink: {
      // A string, not a function: theme config is serialized to the client, closures don't survive.
      pattern: `https://github.com/${repo}/edit/main/docs/:path`,
      text: 'Edit this page on GitHub',
    },
    search: {
      provider: 'local',
      options: { detailedView: true },
    },
    outline: { level: [2, 3] },
    footer: {
      message: `Code, docs and examples: MIT. Artwork has separate terms. <a href="${docsBase}PRIVACY">Privacy</a> · <a href="${docsBase}third-party-licenses.txt">Third-party licences</a>`,
      copyright: `© ${new Date().getFullYear()} GOAT contributors`,
    },
  },
})
