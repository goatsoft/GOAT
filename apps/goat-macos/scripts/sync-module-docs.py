#!/usr/bin/env python3
"""Render the module catalogue and colocated guides from reviewed metadata."""
import argparse
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='fail instead of updating stale documentation')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
repo = root.parent.parent
modules = root / 'Modules'
rows = sorted(json.loads((modules / 'catalogue.json').read_text())['modules'], key=lambda row: row['name'].lower())
start, end = '<!-- module-catalogue:start -->', '<!-- module-catalogue:end -->'
lines = [start, '## Catalogue', '', '| Module | Owns | Dependencies |', '|---|---|---|']
for row in rows:
    if row['name'] == 'goat':
        continue
    lines.append(f"| [{row['name']}](#{row['name'].lower()}) | {row['summary']} | {', '.join(row['dependencies']) or 'None'} |")
outputs = {}
for row in rows:
    name = row['name']
    seams = '`' + row['interfaces'].replace(', ', '`, `') + '`'
    lines += ['', f'## {name}', '', row['summary'], '',
              f'Source: [Modules/Sources/{name}](../apps/goat-macos/Modules/Sources/{name}).', '',
              f'Public seams: {seams}.', '', row['security'], '', f"Validation: {row['validation']}"]
    if name != 'goat':
        outputs[modules / 'Sources' / name / 'README.md'] = '\n'.join([
            f'# {name}', '', row['summary'], '', f'Public seams: {seams}.', '',
            f"Dependencies: {', '.join(row['dependencies']) or 'none'}.", '', row['security'], '',
            f"Validation: {row['validation']}", '',
            'See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.', ''])
lines += ['', end]
page = repo / 'docs/MODULES.md'
text = page.read_text()
if start not in text or end not in text:
    sys.exit('Missing module-catalogue markers in docs/MODULES.md')
outputs[page] = text[:text.index(start)] + '\n'.join(lines) + text[text.index(end) + len(end):]
stale = []
for path, content in outputs.items():
    if path.exists() and path.read_text() == content:
        continue
    stale.append(str(path.relative_to(repo)))
    if not args.check:
        path.write_text(content)
if stale and args.check:
    sys.exit('Stale module documentation; run make module-docs:\n' + '\n'.join(stale))
print('Module documentation is current' if args.check else 'Module documentation synchronized')
