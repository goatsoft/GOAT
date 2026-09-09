import release from '../../../apps/goat-macos/release.json'
import publication from '../../publication.json'
import { docRoute } from '../lib/doc-routes.ts'

/** Build-time identity and deliberate publication state; no background release lookup. */
export function useSite() {
  const slug = import.meta.env.VITE_REPO || 'goatsoft/GOAT'
  const repo = `https://github.com/${slug}`
  const docs = import.meta.env.VITE_DOCS_URL || `${import.meta.env.BASE_URL}docs/`
  const doc = (path: string) => `${docs.replace(/\/?$/, '/')}${docRoute(path)}`
  const releaseTag = `v${release.version}`
  const releaseAvailable = publication.releaseTag === releaseTag
  const downloadFilename = `GOAT-${release.version}.dmg`
  return {
    name: 'GOAT',
    releaseLabel: `${release.version.replace(/\.0$/, '')} (${release.codename})`,
    releaseTag,
    releaseAvailable,
    downloadFilename,
    primaryLabel: releaseAvailable ? 'Download for Mac' : 'Build from source',
    primaryHref: releaseAvailable ? `${repo}/releases/download/${releaseTag}/${downloadFilename}` : doc('Getting-Started'),
    tagline: 'Your private AI workspace for Mac',
    slug, repo, docs, doc,
    releases: `${repo}/releases`,
    sponsor: 'https://www.buymeacoffee.com/josephblythe',
    discussions: `${repo}/discussions`,
    omlx: import.meta.env.VITE_OMLX_URL || 'https://omlx.ai',
    requirements: 'macOS 26 or later · Apple Silicon',
    year: new Date().getFullYear(),
  }
}
