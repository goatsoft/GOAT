import { readFileSync, existsSync, statSync } from 'node:fs'
import type { Plugin } from 'vite'
import type MarkdownIt from 'markdown-it'

/**
 * The glossary, shared by the landing site and the docs site.
 *
 * Source of truth: docs/GLOSSARY.md, one `## Term` per entry, a definition paragraph,
 * then optional `Aliases:` and `See:` lines. Two consumers:
 *
 *   - `goatGlossary()` (Vite plugin): `virtual:goat-glossary` exports the parsed entries
 *     plus the glossary page URL, so <Term> can show a definition without a fetch.
 *   - `glossaryLinks()` (markdown-it plugin, docs only): wraps the first occurrence of
 *     each term on a page in <Term>, skipping headings, code, links and pages with
 *     `glossary: false` in their frontmatter.
 */

export interface GlossaryEntry {
  /** Anchor id on the glossary page, VitePress slug rules. */
  slug: string
  term: string
  definition: string
  aliases: string[]
  /** Relative link from the `See:` line, resolved by the consumer. */
  see?: { text: string; href: string }
}

export function parseGlossary(markdown: string): GlossaryEntry[] {
  const entries: GlossaryEntry[] = []
  const sections = markdown.split(/^## +/m).slice(1)
  for (const section of sections) {
    const [head, ...rest] = section.split('\n')
    const term = head!.trim()
    const lines = rest.map(l => l.trim())
    const aliases = lines.find(l => /^Aliases:/i.test(l))?.replace(/^Aliases:\s*/i, '').split(',').map(s => s.trim()).filter(Boolean) ?? []
    const see = lines.find(l => /^See:/i.test(l))?.match(/\[([^\]]+)\]\(([^)]+)\)/)
    const definition = lines.filter(l => l && !/^(Aliases|See):/i.test(l)).join(' ')
    entries.push({
      slug: slugify(term), term, definition, aliases,
      see: see ? { text: see[1]!, href: see[2]! } : undefined,
    })
  }
  return entries
}

/** VitePress's default heading slug: lowercase, non-alphanumerics to `-`. */
export function slugify(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
}

const ID = 'virtual:goat-glossary'
const RESOLVED = '\0' + ID

export function goatGlossary(opts: { file: string; glossaryUrl: string; docsUrl: string }): Plugin {
  return {
    name: 'goat-glossary',
    resolveId(id) { return id === ID ? RESOLVED : undefined },
    load(id) {
      if (id !== RESOLVED) return
      const entries = existsSync(opts.file) ? parseGlossary(readFileSync(opts.file, 'utf8')) : []
      return [
        `export const entries = ${JSON.stringify(entries)};`,
        `export const glossaryUrl = ${JSON.stringify(opts.glossaryUrl)};`,
        `export const docsUrl = ${JSON.stringify(opts.docsUrl)};`,
      ].join('\n')
    },
    configureServer(server) {
      server.watcher.add(opts.file)
      server.watcher.on('change', p => {
        if (p !== opts.file) return
        const mod = server.moduleGraph.getModuleById(RESOLVED)
        if (mod) { server.moduleGraph.invalidateModule(mod); server.ws.send({ type: 'full-reload' }) }
      })
    },
  }
}

/**
 * Docs auto-linker. Runs after inline parsing; the first time a term (or alias) appears
 * in plain text on a page it becomes `<Term term="...">text</Term>`. Longest names win
 * so "Herd Guarantee" is not swallowed by "Herd". Matching is case-sensitive for the
 * canonical term and case-insensitive for aliases only when they are lowercase already.
 */
export function glossaryLinks(md: MarkdownIt, opts: { file: string }) {
  let cache: { names: { name: string; slug: string; re: RegExp }[]; mtime: number } | undefined
  const names = () => {
    const mtime = existsSync(opts.file) ? statSync(opts.file).mtimeMs : 0
    if (cache && cache.mtime === mtime) return cache.names
    const text = mtime ? readFileSync(opts.file, 'utf8') : ''
    const list = parseGlossary(text).flatMap(e => [e.term, ...e.aliases].map(name => ({ name, slug: e.slug })))
      .sort((a, b) => b.name.length - a.name.length)
      .map(({ name, slug }) => ({ name, slug, re: new RegExp(`(^|[^\\w-])(${escape(name)})(?![\\w-])`) }))
    cache = { names: list, mtime }
    return list
  }

  md.core.ruler.push('goat_glossary_links', state => {
    const fm = state.env?.frontmatter ?? {}
    if (/GLOSSARY\.md$/.test(state.env?.relativePath ?? state.env?.path ?? '')) {
      // On the glossary page itself: no self-links, just tag the meta paragraphs for styling.
      for (let i = 0; i < state.tokens.length - 1; i++) {
        const t = state.tokens[i]!, inline = state.tokens[i + 1]!
        if (t.type === 'paragraph_open' && inline.type === 'inline' && /^(Aliases|See):/.test(inline.content)) t.attrSet('class', 'goat-gloss-meta')
      }
      return
    }
    if (fm.glossary === false) return
    const seen = new Set<string>()
    for (const block of state.tokens) {
      if (block.type !== 'inline' || !block.children) continue
      // Only paragraphs and list items; headings, tables and custom blocks keep plain text.
      const parent = state.tokens[state.tokens.indexOf(block) - 1]
      if (!parent || !['paragraph_open', 'list_item_open'].includes(parent.type)) continue
      let depth = 0
      const out: typeof block.children = []
      for (const tok of block.children) {
        if (tok.type === 'link_open') depth++
        if (tok.type === 'link_close') depth--
        // Raw anchors from other plugins (repolinks) arrive as html_inline.
        if (tok.type === 'html_inline' && /^<a[\s>]/i.test(tok.content)) depth++
        if (tok.type === 'html_inline' && /^<\/a>/i.test(tok.content)) depth--
        if (tok.type !== 'text' || depth > 0) { out.push(tok); continue }
        out.push(...linkText(state, tok, names(), seen))
      }
      block.children = out
    }
  })

  function linkText(state: any, tok: any, list: ReturnType<typeof names>, seen: Set<string>) {
    let text: string = tok.content
    const pieces: any[] = []
    let guard = 0
    while (text && guard++ < 50) {
      let best: { index: number; len: number; slug: string; match: string } | undefined
      for (const { slug, re } of list) {
        if (seen.has(slug)) continue
        const m = re.exec(text)
        if (!m) continue
        const index = m.index + m[1]!.length
        if (!best || index < best.index) best = { index, len: m[2]!.length, slug, match: m[2]! }
      }
      if (!best) break
      seen.add(best.slug)
      if (best.index > 0) pieces.push(textToken(state, text.slice(0, best.index)))
      const open = new state.Token('html_inline', '', 0)
      open.content = `<Term term="${best.slug}">${state.md.utils.escapeHtml(best.match)}</Term>`
      pieces.push(open)
      text = text.slice(best.index + best.len)
    }
    if (text) pieces.push(textToken(state, text))
    return pieces.length ? pieces : [tok]
  }
  function textToken(state: any, content: string) {
    const t = new state.Token('text', '', 0)
    t.content = content
    return t
  }
}

function escape(s: string) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') }
