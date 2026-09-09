import type MarkdownIt from 'markdown-it'

/**
 * markdown-it plugin: GitHub-Wiki style `[[Page]]` and `[[Link text|Page]]` links.
 *
 * The source pages in docs/wiki stay compatible with GitHub's wiki, which resolves
 * `[[Getting Started]]` to `Getting-Started.md`; the same rule here gives the
 * VitePress route `/Getting-Started`. `Home` maps to the site root.
 */
export function slugify(page: string): string {
  return page.trim().replace(/[^A-Za-z0-9_.]+/g, '-').replace(/^-|-$/g, '')
}

export function wikilinks(md: MarkdownIt) {
  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const src = state.src
    const start = state.pos
    if (src.charCodeAt(start) !== 0x5b || src.charCodeAt(start + 1) !== 0x5b) return false
    const end = src.indexOf(']]', start + 2)
    if (end < 0) return false
    const body = src.slice(start + 2, end)
    if (!body || body.includes('\n') || body.includes('[')) return false
    if (silent) { state.pos = end + 2; return true }

    // GitHub's order: [[Link text|Page-Name]].
    const [first, second] = body.split('|', 2)
    const page = (second ?? first)!.trim()
    const label = first!.trim()
    const [name, anchor] = page.split('#', 2)
    const slug = slugify(name!)
    const href = (slug === 'Home' ? '/' : `/${slug}`) + (anchor ? `#${slugify(anchor).toLowerCase()}` : '')

    const open = state.push('link_open', 'a', 1)
    open.attrs = [['href', href], ['class', 'wikilink']]
    const text = state.push('text', '', 0)
    text.content = label
    state.push('link_close', 'a', -1)
    state.pos = end + 2
    return true
  })
}
