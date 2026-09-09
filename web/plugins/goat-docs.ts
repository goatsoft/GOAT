import { readFileSync, existsSync } from 'node:fs'
import { basename, dirname, posix, relative } from 'node:path'
import type { Plugin } from 'vite'
import MarkdownIt from 'markdown-it'

/**
 * Vite plugin: `virtual:goat-docs` renders a handful of repo Markdown files to HTML at
 * build time so the landing site can show them in a dialog (third-party notices, the
 * artwork licence) without leaving the page and without a runtime Markdown parser.
 *
 *   import { docs } from 'virtual:goat-docs'
 *   docs['third-party-notices'] // { title, html, source }
 *
 * Relative links inside the documents point at repo files, so they are rewritten to
 * GitHub blob URLs; everything else is plain markdown-it output (html off, links auto).
 */

export interface GoatDoc { title: string; html: string; source: string }

const ID = 'virtual:goat-docs'
const RESOLVED = '\0' + ID

export function goatDocs(opts: { files: Record<string, string>; repo: string; root: string; branch?: string }): Plugin {
  const branch = opts.branch ?? 'main'
  const md = new MarkdownIt({ html: false, linkify: true, typographer: true })
  // External links open in a new tab; relative ones resolve against the repo.
  const defaultLink = md.renderer.rules.link_open ?? ((t, i, o, _e, s) => s.renderToken(t, i, o))
  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    const tok = tokens[idx]!
    const href = tok.attrGet('href') ?? ''
    // Relative links resolve from the document's own folder in the repo.
    if (!/^[a-z]+:/i.test(href) && !href.startsWith('#')) {
      const dir: string = env?.dir ?? ''
      tok.attrSet('href', `https://github.com/${opts.repo}/blob/${branch}/${posix.normalize(posix.join(dir, href))}`)
    }
    tok.attrSet('target', '_blank'); tok.attrSet('rel', 'noopener')
    return defaultLink(tokens, idx, options, env, self)
  }

  const render = () => {
    const out: Record<string, GoatDoc> = {}
    for (const [key, file] of Object.entries(opts.files)) {
      if (!existsSync(file)) continue
      const rel = relative(opts.root, file).split('\\').join('/')
      const text = readFileSync(file, 'utf8').replace(/^---\n[\s\S]*?\n---\n/, '').replace(/^\s+/, '')
      const title = text.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? basename(file)
      const body = text.replace(/^#\s+.+\n/, '')
      out[key] = { title, html: md.render(body, { dir: dirname(rel) === '.' ? '' : dirname(rel) }), source: `https://github.com/${opts.repo}/blob/${branch}/${rel}` }
    }
    return out
  }

  return {
    name: 'goat-docs',
    resolveId(id) { return id === ID ? RESOLVED : undefined },
    load(id) {
      if (id !== RESOLVED) return
      return `export const docs = ${JSON.stringify(render())};`
    },
    configureServer(server) {
      const files = Object.values(opts.files).filter(existsSync)
      files.forEach(f => server.watcher.add(f))
      server.watcher.on('change', p => {
        if (!files.includes(p)) return
        const mod = server.moduleGraph.getModuleById(RESOLVED)
        if (mod) { server.moduleGraph.invalidateModule(mod); server.ws.send({ type: 'full-reload' }) }
      })
    },
  }
}
