import assert from 'node:assert/strict'
import { test } from 'node:test'
import { siteRelease } from '../src/lib/site-release.ts'

const candidate = { version: '0.1.1', codename: 'Kid' }

test('a new candidate keeps the approved older download and its label', () => {
  assert.deepEqual(siteRelease(candidate, { releaseTag: 'v0.1.0', codename: 'Kid' }), {
    releaseAvailable: true, releaseTag: 'v0.1.0', releaseLabel: '0.1 (Kid)', downloadFilename: 'GOAT-0.1.0.dmg',
  })
  assert.equal(siteRelease({ version: '0.2.0', codename: 'Yearling' }, { releaseTag: 'v0.1.1', codename: 'Kid' }).releaseLabel, '0.1.1 (Kid)')
})

test('only an explicit publication switch enables the maintenance download', () => {
  const result = siteRelease(candidate, { releaseTag: 'v0.1.1', codename: 'Kid' })
  assert.equal(result.downloadFilename, 'GOAT-0.1.1.dmg')
  assert.equal(result.releaseLabel, '0.1.1 (Kid)')
  assert.equal(result.releaseAvailable, true)
})

test('source-only previews stay unavailable and malformed published identities fail', () => {
  assert.equal(siteRelease(candidate, { releaseTag: null, codename: null }).releaseAvailable, false)
  for (const publication of [{ releaseTag: 'latest', codename: 'Kid' }, { releaseTag: 'v0.1.1/extra', codename: 'Kid' }, { releaseTag: 'v0.1.1', codename: null }]) {
    assert.throws(() => siteRelease(candidate, publication), /exact release tag and codename/)
  }
})
