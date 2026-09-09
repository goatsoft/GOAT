/** Keep reference routes distinct from the capitalised guide names on every filesystem. */
export const referenceRoutes: Readonly<Record<string, string>> = {
  ARCHITECTURE: 'reference/architecture',
  ENGINES: 'reference/engines',
  EXTENSIONS: 'reference/extensions',
}

export function docRoute(path: string): string {
  const split = path.search(/[?#]/)
  const suffix = split < 0 ? '' : path.slice(split)
  const page = (split < 0 ? path : path.slice(0, split)).replace(/^\//, '').replace(/\.md$/, '')
  if (page === 'wiki/Home') return suffix
  if (page === 'adrs/README') return `adrs/${suffix}`
  if (page === 'reference/README') return `reference/${suffix}`
  return (referenceRoutes[page] ?? page.replace(/^wiki\//, '')) + suffix
}
