import { dirname, posix, relative, resolve } from 'node:path'
import type MarkdownIt from 'markdown-it'
import { docRoute } from '../../routes.ts'

/**
 * markdown-it plugin: make links that leave docs/ land somewhere real.
 *
 * Two conventions live in the tree:
 *
 * 1. Wiki pages (docs/wiki) are written for GitHub's wiki, where a page lives at
 *    <repo>/wiki/<Page>, so they link to the tree as `../blob/main/docs/ENGINES.md`
 *    and to `../releases/latest`. Here: `../blob/main/docs/<page>.md` becomes the
 *    site route when that page is built, and recognised legacy repository links become
 *    `https://github.com/<repo>/x`.
 *
 * 2. Reference docs use ordinary relative links; when one escapes docs/
 *    (`../../AGENT.md`, `../../CONTRIBUTING.md`) or points at a file that is
 *    not built, it becomes a `blob/main` link into the repo.
 */
export interface RepoLinkOptions {
  repo: string
  /** Absolute path of the repo root. */
  root: string
  /** Absolute path of the docs source root (docs/). */
  docsDir: string
  /** Is this docs-relative markdown path built as a page? */
  isPage: (docsRelative: string) => boolean
}

export function repolinks(md: MarkdownIt, opts: RepoLinkOptions) {
  const blob = (repoRelative: string) => `https://github.com/${opts.repo}/blob/main/${repoRelative}`
  const route = (docsRelative: string, hash: string) => {
    return `/${docRoute(docsRelative)}${hash}`
  }

  md.core.ruler.push('goat_repolinks', state => {
    // realPath is the file on disk; path is the post-rewrite route (wiki/Engines.md → Engines.md).
    const file: string | undefined = state.env?.realPath ?? state.env?.path
    if (!file) return
    const docsRel = relative(opts.docsDir, file).split('\\').join('/')
    const isWiki = docsRel.startsWith('wiki/')

    for (const block of state.tokens) {
      if (block.type !== 'inline' || !block.children) continue
      for (const tok of block.children) {
        if (tok.type !== 'link_open') continue
        const href = tok.attrGet('href')
        if (!href || /^(https?:|mailto:|#|\/)/.test(href)) continue
        const [target, hashPart] = href.split('#', 2)
        const hash = hashPart ? `#${hashPart}` : ''

        if (isWiki && /^\.\.\/(blob\/|releases(?:\/|$)|wiki(?:\/|$))/.test(target!)) {
          const path = target!.slice(3)
          const inDocs = path.match(/^blob\/main\/docs\/(.+)$/)
          if (inDocs && opts.isPage(inDocs[1]!)) tok.attrSet('href', route(inDocs[1]!, hash))
          else tok.attrSet('href', `https://github.com/${opts.repo}/${path}${hash}`)
          continue
        }

        // Ordinary relative link: keep it if it lands on a built page, else point at the tree.
        const abs = resolve(dirname(file), target!)
        const rel = relative(opts.docsDir, abs).split('\\').join('/')
        const escapes = rel.startsWith('../')
        // Built page: use its route, since rewrites move wiki/ pages to the root.
        if (!escapes && opts.isPage(rel)) { tok.attrSet('href', route(rel, hash)); continue }
        const repoRel = posix.normalize(relative(opts.root, abs).split('\\').join('/'))
        tok.attrSet('href', blob(repoRel) + hash)
      }
    }
  })
}
