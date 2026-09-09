#!/usr/bin/env python3
"""Collect upstream notices without fetching or executing dependency code.

Refresh after npm ci and Xcode package resolution. --check validates recorded
inputs and outputs without requiring platform-specific dependency checkouts.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'apps/goat-macos'
META = ROOT / 'third-party/distribution-manifest.json'
WEB = ROOT / 'web'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path):
    return {'path': str(path.relative_to(ROOT)), 'sha256': sha(path)}


def notice_files(path):
    return sorted(f for f in path.iterdir() if f.is_file() and
                  re.search(r'(?i)(?:^|[-_])(licen[cs]e|copying|notice)(?:[.-]|$)', f.name))


def section(title, source, texts):
    return '\n' + '=' * 72 + '\n' + title + '\nSource: ' + source + '\n' + '=' * 72 + '\n\n' + '\n\n'.join(texts) + '\n'


def fail(message):
    sys.exit(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--swift-checkouts', type=Path)
    parser.add_argument('--app-resolved', type=Path)
    parser.add_argument('--cli-checkouts', type=Path, default=APP / 'Modules/.build/checkouts')
    args = parser.parse_args()
    if args.check:
        manifest = json.loads(META.read_text())
        stale = [r['path'] for r in manifest['inputs'] + manifest['outputs']
                 if not (ROOT / r['path']).is_file() or sha(ROOT / r['path']) != r['sha256']]
        if stale:
            fail('Distribution notices are stale; refresh and review:\n' + '\n'.join(stale))
        resolved = args.app_resolved or APP / 'Package.resolved'
        if resolved:
            pins = sorted(json.loads(resolved.read_text())['pins'], key=lambda p: p['identity'])
            if pins != manifest['swiftPackages']:
                fail('App package resolution differs from the reviewed notices; refresh them')
        print('Distribution notice inputs and outputs match the reviewed manifest')
        return
    if not args.swift_checkouts or not args.app_resolved:
        parser.error('refresh requires --swift-checkouts and --app-resolved')
    lock = json.loads((WEB / 'package-lock.json').read_text())['packages']
    upstream = ROOT / 'third-party/upstream'
    sources = json.loads((upstream / 'sources.json').read_text())
    overrides = {
        '@docsearch/css': 'docsearch', '@docsearch/js': 'docsearch',
        '@docsearch/sidepanel-js': 'docsearch', '@vue/devtools-api': 'vue-devtools',
        '@iconify-json/hugeicons': 'hugeicons', '@iconify-json/simple-icons': 'simple-icons',
        'fastdom': 'fastdom', 'strictdom': 'strictdom',
    }
    npm = {}
    for rel, entry in sorted(lock.items()):
        if not rel or entry.get('os') or entry.get('cpu'):
            continue  # Platform-specific build executables are not browser assets.
        path = WEB / rel
        if not path.is_dir():
            fail('Missing dependency: ' + rel + '; run npm ci')
        package = json.loads((path / 'package.json').read_text())
        name = package['name']
        if package['version'] != entry['version']:
            fail('Installed version differs from lockfile: ' + rel)
        files = notice_files(path)
        origin = package.get('repository', '')
        if isinstance(origin, dict):
            origin = origin.get('url', '')
        origin = origin or 'https://www.npmjs.com/package/' + name
        if name in overrides:
            source = sources[overrides[name]]
            files = [upstream / source['file']]
            origin = source['url']
        if not files:
            fail('Missing full licence text: ' + name)
        npm[rel] = {'name': name, 'version': package['version'], 'license': package.get('license'),
                    'text': section(name + ' ' + package['version'], origin,
                                    [f.name + '\n\n' + f.read_text(errors='strict') for f in files])}
    # Resolve the installed dependency graph rooted at the exact bundled Mermaid version.
    mermaid = set()
    def visit(rel):
        if rel in mermaid:
            return
        if rel not in npm:
            fail('Mermaid dependency lacks notices: ' + rel)
        mermaid.add(rel)
        for dep in lock[rel].get('dependencies', {}):
            base = rel
            while True:
                target = base + '/node_modules/' + dep if base else 'node_modules/' + dep
                if target in lock:
                    break
                if not base:
                    fail('Unresolved dependency: ' + dep)
                base = base.rsplit('/node_modules/', 1)[0] if '/node_modules/' in base else ''
            visit(target)
    visit('node_modules/mermaid')
    renderer = APP / 'App/Resources/mermaid.min.js'
    version = npm['node_modules/mermaid']['version']
    if 'version:"' + version + '"' not in renderer.read_text():
        fail('Bundled Mermaid version differs from npm; review its provenance before refreshing')
    swift = []
    swift_text = ''
    for pin in sorted(json.loads(args.app_resolved.read_text())['pins'], key=lambda p: p['identity']):
        matches = [p for p in args.swift_checkouts.iterdir() if p.name.lower() == pin['identity']]
        if len(matches) != 1:
            fail('Missing Swift checkout: ' + pin['identity'])
        path = matches[0]
        revision = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != pin['state']['revision']:
            fail('Swift revision differs from app resolution: ' + path.name)
        files = notice_files(path)
        # Notices for code or assets embedded within these dependencies.
        for extra in ['Sources/HighlightSwift/HighlightJS/LICENSE.md',
                      'Sources/CNIOLLHTTP/LICENSE']:
            if (path / extra).is_file():
                files.append(path / extra)
        if not files:
            fail('Missing Swift licence: ' + path.name)
        swift.append(pin)
        swift_text += section(path.name + ' ' + pin['state']['version'], pin['location'] + ' @ ' + revision,
                              [str(f.relative_to(path)) + '\n\n' + f.read_text() for f in files])
    cli_pins = sorted(json.loads((APP / 'Modules/Package.resolved').read_text())['pins'], key=lambda p: p['identity'])
    app_revisions = {(pin['identity'], pin['state']['revision']) for pin in swift}
    for pin in cli_pins:
        if (pin['identity'], pin['state']['revision']) in app_revisions:
            continue
        matches = [p for p in args.cli_checkouts.iterdir() if p.name.lower() == pin['identity']]
        if len(matches) != 1:
            fail('Missing CLI checkout: ' + pin['identity'])
        path = matches[0]
        revision = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != pin['state']['revision']:
            fail('CLI checkout differs from resolution: ' + path.name)
        files = notice_files(path)
        nested = path / 'Sources/CNIOLLHTTP/LICENSE'
        if nested.is_file():
            files.append(nested)
        if not files:
            fail('Missing CLI licence: ' + path.name)
        swift_text += section(path.name + ' ' + pin['state']['version'] + ' (CLI resolution)',
                              pin['location'] + ' @ ' + revision,
                              [str(f.relative_to(path)) + '\n\n' + f.read_text() for f in files])
    hindsight = sources['hindsight']
    native = ('GOAT application third-party notices\n\n'
              'Upstream terms apply to these components. The Mermaid dependency list is\n'
              'inclusive of its resolved dependencies, including build-time type packages;\n'
              'it is not a claim that every listed package executes in the application.\n')
    native += swift_text + section('Hindsight integration mark', hindsight['url'],
                                  [(upstream / hindsight['file']).read_text()])
    native += ''.join(npm[n]['text'] for n in sorted(mermaid))
    embedded_notices = re.findall(r'/\*! Bundled license information:[\s\S]*?\*/', renderer.read_text())
    if not embedded_notices:
        fail('Expected Mermaid embedded attribution comments are missing; review the asset')
    native += section('Additional embedded Mermaid attributions', 'Bundled mermaid.min.js', embedded_notices)
    browser = ('GOAT website and documentation third-party notices\n\n'
               'Inclusive notices for locked site dependencies and build tools. Platform-specific\n'
               'build executables are omitted. This is not a list of external services or\n'
               'a claim that every dependency executes in the browser.\n')
    browser += ''.join(row['text'] for row in npm.values())
    outputs = {
        APP / 'App/Resources/Licenses/THIRD-PARTY-NOTICES.txt': native,
        APP / 'App/Resources/Licenses/LICENSE.txt': (ROOT / 'LICENSE').read_text(),
        APP / 'App/Resources/Licenses/LICENSE-ART.txt': (ROOT / 'LICENSE-ART.md').read_text(),
        WEB / 'public/third-party-licenses.txt': browser,
    }
    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    inputs = [ROOT / 'LICENSE', ROOT / 'LICENSE-ART.md', WEB / 'package-lock.json', renderer,
              APP / 'Modules/Package.resolved', APP / 'Modules/Package.swift', APP / 'project.yml',
              Path(__file__).resolve(), *sorted(upstream.iterdir())]
    manifest = {'schemaVersion': 1, 'swiftPackages': swift, 'cliPackages': cli_pins,
                'npmPackages': [{k: v for k, v in row.items() if k != 'text'} for row in npm.values()],
                'mermaidPackages': sorted(mermaid), 'inputs': [record(p) for p in inputs],
                'outputs': [record(p) for p in outputs]}
    META.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Collected {len(swift)} Swift packages, {len(mermaid)} Mermaid dependency entries, '
          f'{len(npm)} site dependency entries')


if __name__ == '__main__':
    main()
