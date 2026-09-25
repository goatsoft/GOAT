#!/usr/bin/env python3
"""Delete superseded compilation caches on one ref, keeping the newest per namespace.

Cache keys are `<namespace>-<40-hex commit>`. Namespaces encode the toolchain, phase and
dependency identity (ADR-0095). Only exact key matches of that form under the prefix are
touched; anything else is left for GitHub's unused-cache eviction.
"""
import argparse
import json
import re
import subprocess

KEY = re.compile(r'^(?P<namespace>.+)-(?P<commit>[0-9a-f]{40})$')


def superseded(entries, prefix):
    """Return ids of caches older than the newest entry in the same namespace."""
    newest = {}
    candidates = []
    for entry in entries:
        key = entry.get('key', '')
        match = KEY.match(key)
        if not key.startswith(prefix) or not match:
            continue
        namespace = match['namespace']
        candidates.append((namespace, entry))
        current = newest.get(namespace)
        if current is None or (entry['createdAt'], entry['id']) > (current['createdAt'], current['id']):
            newest[namespace] = entry
    return sorted(entry['id'] for namespace, entry in candidates if entry is not newest[namespace])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    listing = subprocess.check_output(
        ['gh', 'cache', 'list', '--ref', args.ref, '--key', args.prefix, '--limit', '100',
         '--json', 'id,key,createdAt'], text=True)
    stale = superseded(json.loads(listing), args.prefix)
    for cache_id in stale:
        print(f'Deleting superseded cache {cache_id}')
        if not args.dry_run:
            subprocess.run(['gh', 'cache', 'delete', str(cache_id)], check=True)
    print(f'{len(stale)} superseded compilation caches removed from {args.ref}.')


if __name__ == '__main__':
    main()
