interface ReleaseIdentity {
  version: string
  codename: string
}

interface Publication {
  releaseTag: string | null
  codename: string | null
}

/** Keep the approved download independent of the next source candidate. */
export function siteRelease(source: ReleaseIdentity, publication: Publication) {
  const tag = publication.releaseTag
  if (tag !== null && (!/^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(tag) || !publication.codename?.trim())) {
    throw new Error('Published downloads require an exact release tag and codename')
  }
  const version = tag === null ? source.version : tag.slice(1)
  const codename = tag === null ? source.codename : publication.codename
  return {
    releaseAvailable: tag !== null,
    releaseTag: tag ?? `v${version}`,
    releaseLabel: `${version.replace(/\.0$/, '')} (${codename})`,
    downloadFilename: `GOAT-${version}.dmg`,
  }
}
