import type MarkdownIt from 'markdown-it'

/**
 * markdown-it plugin: render ```mermaid fences as <Mermaid> components instead of code.
 *
 * The diagram source is passed through an HTML attribute (entity-escaped) so the
 * page stays plain data; the renderer is bundled at build time from the `mermaid`
 * package, never a CDN, matching the app's offline Mermaid rule (ADR-0010).
 */
export function mermaid(md: MarkdownIt) {
  const fence = md.renderer.rules.fence!
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx]!
    if (token.info.trim().split(/\s+/)[0] !== 'mermaid') return fence(tokens, idx, options, env, self)
    return `<Mermaid code="${md.utils.escapeHtml(token.content)}" />\n`
  }
}
