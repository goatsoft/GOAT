/** Prefix a public/ path with the deploy base (GitHub Pages serves under /<repo>/). */
export function asset(path: string): string {
  if (/^(data:|https?:)/.test(path)) return path
  return import.meta.env.BASE_URL + path.replace(/^\//, '')
}
