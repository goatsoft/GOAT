import assert from 'node:assert/strict'
import { readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { docRoute } from '../src/lib/doc-routes.ts'

test('guide and reference links remain distinct with anchors intact', () => {
  assert.equal(docRoute('wiki/Architecture.md'), 'Architecture')
  assert.equal(docRoute('/ARCHITECTURE#ownership'), 'reference/architecture#ownership')
  assert.equal(docRoute('ENGINES.md#compatibility-evidence'), 'reference/engines#compatibility-evidence')
  assert.equal(docRoute('wiki/Extensions.md'), 'Extensions')
  assert.equal(docRoute('wiki/Home.md'), '')
})

test('all documentation routes are unique on case-insensitive filesystems', () => {
  const root = fileURLToPath(new URL('../../docs/', import.meta.url))
  const routes = new Map()
  for (const path of readdirSync(root, { recursive: true }).filter(path => path.endsWith('.md'))) {
    const route = docRoute(path).toLowerCase()
    assert.equal(routes.has(route), false, `${path} collides with ${routes.get(route)}`)
    routes.set(route, path)
  }
})
