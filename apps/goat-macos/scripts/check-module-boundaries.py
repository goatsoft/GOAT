#!/usr/bin/env python3
"""Verify the reviewed module graph and adapter boundaries without network access."""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
modules = root / 'Modules'
catalogue = json.loads((modules / 'catalogue.json').read_text())
expected = {row['name']: set(row['dependencies']) for row in catalogue['modules']}
manifest = (modules / 'Package.swift').read_text()
actual = {}
for name, body in re.findall(r'\.(?:target|executableTarget)\(\s*name:\s*"(\w+)",\s*dependencies:\s*\[([\s\S]*?)\](?:\s*,\s*exclude:\s*\[[^\]]*\])?\s*\)', manifest):
    # External product expressions are independently checked below.
    local = re.sub(r'\.product\([^)]*\)', '', body)
    actual[name] = set(re.findall(r'"(\w+)"', local))
failures = []
if actual != expected:
    failures.append('Package.swift and Modules/catalogue.json disagree; review both module graphs.')
if {p.name for p in (modules / 'Sources').iterdir() if p.is_dir()} != set(expected):
    failures.append('Every source module must be present in the catalogue.')

project = (root / 'project.yml').read_text()
products = set(re.findall(r'- package: Modules\s+product: (\w+)', project))
if products != set(expected) - {'goat'}:
    failures.append('project.yml must compose every current library product exactly by name.')

visiting, visited = set(), set()
def visit(name):
    if name in visiting:
        failures.append(f'Dependency cycle at {name}')
        return
    if name in visited:
        return
    visiting.add(name)
    for dependency in expected.get(name, set()):
        if dependency not in expected:
            failures.append(f'{name}: unknown dependency {dependency}')
        else:
            visit(dependency)
    visiting.remove(name)
    visited.add(name)
for name in expected:
    visit(name)

adapters = {'GRDB': 'Persistence', 'MCP': 'MCPClient'}
for path in [*(modules / 'Sources').rglob('*.swift'), *(root / 'App/Sources').rglob('*.swift')]:
    owner = path.relative_to(modules / 'Sources').parts[0] if modules / 'Sources' in path.parents else 'App'
    for line, text in enumerate(path.read_text().splitlines(), 1):
        match = re.match(r'\s*(?:@\w+\s+)?(?:(?:public|internal|private|package)\s+)?import\s+(\w+)', text)
        if not match:
            continue
        imported = match[1]
        problem = None
        if imported in adapters and owner != adapters[imported]:
            problem = f'{imported} belongs only to {adapters[imported]}'
        elif imported.startswith('Goat'):
            problem = 'obsolete prefixed module import'
        elif owner != 'App' and imported == 'GOAT':
            problem = 'domain modules cannot import the app'
        elif owner != 'App' and imported in expected and imported not in expected[owner]:
            problem = f'undeclared dependency {owner} -> {imported}'
        elif owner in {'Herd', 'Pens', 'Persistence', 'Inference', 'Memory', 'Tools', 'GOATed', 'Hitch', 'MCPClient', 'JUDAS'} and imported in {'SwiftUI', 'AppKit', 'WebKit'}:
            problem = f'{owner} cannot depend on a UI framework'
        if problem:
            failures.append(f'{path.relative_to(root)}:{line}: {problem}')
for row in catalogue['modules']:
    if row['name'] != 'goat' and not (modules / 'Sources' / row['name'] / 'README.md').is_file():
        failures.append(f'{row["name"]}: missing module documentation')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print(f'Module boundaries passed: {len(expected) - 1} libraries and the goat executable')
