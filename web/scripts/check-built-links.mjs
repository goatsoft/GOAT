#!/usr/bin/env node
/** Verify the combined local build, including document anchors and copied notices. */
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { resolve, dirname, relative, extname } from 'node:path'
import { fileURLToPath } from 'node:url'

const web = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const root = resolve(process.argv[2] || resolve(web, 'dist'))
const decode = value => value.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#(?:x([\da-f]+)|(\d+));/gi, (_, hex, dec) => String.fromCodePoint(parseInt(hex || dec, hex ? 16 : 10)))
const pages = new Map()
function visit(dir) {
  for (const name of readdirSync(dir)) {
    const file = resolve(dir, name)
    if (statSync(file).isDirectory()) visit(file)
    else if (name.endsWith('.html')) {
      const html = readFileSync(file, 'utf8')
      pages.set(file, {
        ids: new Set([...html.matchAll(/\bid="([^"]*)"/g)].map(m => decode(m[1]))),
        links: [...html.matchAll(/<a\b[^>]*\bhref="([^"]*)"/g)].map(m => decode(m[1])),
      })
    }
  }
}
visit(root)
const errors = []
let checked = 0
for (const [file, page] of pages) {
  for (const href of page.links) {
    if (/^(?:[a-z][\w+.-]*:|\/\/)/i.test(href)) continue
    const url = new URL(href, 'https://preview.invalid/' + relative(root, file))
    let target = resolve(root, decodeURIComponent(url.pathname).replace(/^\//, ''))
    if (existsSync(target) && statSync(target).isDirectory()) target = resolve(target, 'index.html')
    if (!existsSync(target) && !extname(target)) target += '.html'
    checked++
    const anchor = decodeURIComponent(url.hash.slice(1))
    if (!existsSync(target)) errors.push(`${relative(root, file)}: missing target ${href}`)
    else if (anchor && pages.has(target) && !pages.get(target).ids.has(anchor)) errors.push(`${relative(root, file)}: missing anchor ${href}`)
  }
}
for (const folder of ['', 'docs/']) {
  const file = resolve(root, folder, 'third-party-licenses.txt')
  if (!existsSync(file) || !readFileSync(file).equals(readFileSync(resolve(web, 'public/third-party-licenses.txt')))) errors.push(`Missing or stale ${folder}third-party-licenses.txt`)
}
if (errors.length) {
  console.error(errors.join('\n'))
  process.exitCode = 1
} else console.log(`Checked ${checked} links and anchors across ${pages.size} pages; both licence files match`)
