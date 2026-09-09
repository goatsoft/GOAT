import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import type { Plugin } from 'vite'

/**
 * Vite plugin: `virtual:goat-data` exposes repo facts to the docs at build time so
 * pages never go stale against the tree.
 *
 *   import { adrs, release, repo } from 'virtual:goat-data'
 *
 * - `adrs`: parsed from docs/adrs/*.md (number, title, status, github blob link)
 * - `release`: version + codename, from apps/goat-macos/release.json
 * - `repo`: owner/slug from VITE_REPO (CI sets it from the GitHub context)
 *
 * Runs at build only; nothing here ships to the browser except the resulting JSON.
 */

export interface Adr { id: string; title: string; status: string; file: string }
export interface Release { version: string; codename: string; label: string }

const ID = 'virtual:goat-data'
const RESOLVED = '\0' + ID

export function readAdrs(dir: string): Adr[] {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter(f => /^\d{4}-.*\.md$/.test(f))
    .sort()
    .map(file => {
      const text = readFileSync(join(dir, file), 'utf8')
      const head = text.match(/^#\s*ADR-(\d{4}):\s*(.+)$/m)
      const status = text.match(/^(?:-\s+)?\*{0,2}Status:?\*{0,2}\s*(.+)$/m)?.[1]
        ?.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\*/g, '').trim() ?? 'Unknown'
      return { id: head?.[1] ?? file.slice(0, 4), title: head?.[2]?.trim() ?? file, status, file }
    })
}

export function readRelease(appDir: string): Release {
  const { version, codename } = JSON.parse(readFileSync(join(appDir, 'release.json'), 'utf8'))
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version) || typeof codename !== 'string' || !codename.trim()) {
    throw new Error('release.json must contain a semantic version and codename')
  }
  // Display contract (docs/VERSIONING.md): drop a trailing zero patch, codename in parentheses.
  const shown = version.replace(/\.0$/, '')
  return { version, codename, label: codename ? `${shown} (${codename})` : shown }
}

export function goatData(opts: { root: string; repo: string }): Plugin {
  const adrDir = resolve(opts.root, 'docs/adrs')
  const appDir = resolve(opts.root, 'apps/goat-macos')
  return {
    name: 'goat-data',
    resolveId(id) { return id === ID ? RESOLVED : undefined },
    load(id) {
      if (id !== RESOLVED) return
      const data = { repo: opts.repo, adrs: readAdrs(adrDir), release: readRelease(appDir) }
      return Object.entries(data).map(([k, v]) => `export const ${k} = ${JSON.stringify(v)};`).join('\n')
    },
    configureServer(server) {
      // Editing an ADR while the dev server runs refreshes the index.
      server.watcher.add(adrDir)
      server.watcher.on('change', p => {
        if (!p.startsWith(adrDir) && !p.startsWith(appDir)) return
        const mod = server.moduleGraph.getModuleById(RESOLVED)
        if (mod) { server.moduleGraph.invalidateModule(mod); server.ws.send({ type: 'full-reload' }) }
      })
    },
  }
}
