#!/usr/bin/env python3
"""Aggregate the required CI check without accepting unexpectedly skipped jobs."""
import json
import os


def verified(needs):
    changes = needs.get('changes', {})
    if changes.get('result') != 'success':
        return False
    if changes.get('outputs', {}).get('app') == 'false':
        return all(needs.get(job, {}).get('result') == 'skipped' for job in ('lint', 'verification'))
    return all(needs.get(job, {}).get('result') == 'success' for job in ('lint', 'verification'))


if __name__ == '__main__':
    if not verified(json.loads(os.environ['NEEDS_JSON'])):
        raise SystemExit('App verification failed, was cancelled, or did not run completely.')
    print('App verification complete (or explicitly excluded by content-only change detection).')
