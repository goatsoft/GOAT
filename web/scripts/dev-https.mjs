import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { createServer } from 'vite'
import { createServer as createDocsServer } from 'vitepress'

const { values } = parseArgs({ options: {
  host: { type: 'string', default: 'localhost' },
  port: { type: 'string', default: '5176' },
  'docs-port': { type: 'string', default: '5179' },
  cert: { type: 'string' },
  key: { type: 'string' },
} })
if (!values.cert || !values.key) {
  throw new Error('Provide --cert and --key paths to a trusted local development certificate.')
}
const port = Number(values.port)
const docsPort = Number(values['docs-port'])
if (![port, docsPort].every(p => Number.isInteger(p) && p > 0 && p <= 65535) || port === docsPort) {
  throw new Error('Website and docs ports must be different integers between 1 and 65535.')
}
const origin = new URL(`https://${values.host}:${port}/`).origin
const root = fileURLToPath(new URL('../', import.meta.url))
const [cert, key] = await Promise.all([readFile(values.cert), readFile(values.key)])

// Both sites share the public HTTPS origin; the docs backend stays on loopback.
process.env.VITE_SITE_URL = `${origin}/`
process.env.VITE_DOCS_URL = ''
process.env.VITE_DOCS_DEV_URL = `http://127.0.0.1:${docsPort}`
const servers = []
let closing = false
async function close() {
  if (closing) return
  closing = true
  await Promise.allSettled(servers.map(server => server.close()))
}
process.once('SIGINT', () => { void close() })
process.once('SIGTERM', () => { void close() })

try {
  const docs = await createDocsServer(fileURLToPath(new URL('../docs', import.meta.url)), {
    host: '127.0.0.1', port: docsPort, strictPort: true,
  })
  servers.push(docs)
  await docs.listen()
  const site = await createServer({ root, server: {
    host: values.host, port, strictPort: true, https: { cert, key },
  } })
  servers.push(site)
  await site.listen()
  console.log(`Website: ${origin}/\nDocs: ${origin}/docs/`)
} catch (error) {
  await close()
  throw error
}
