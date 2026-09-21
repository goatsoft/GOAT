#!/usr/bin/env python3
"""Check maintained Xcode target membership and release wiring using macOS plutil."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'GOAT.xcodeproj'


def load_project():
    return json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-', str(PROJECT / 'project.pbxproj')]))


def validate(project, root=ROOT):
    objects = project['objects']
    paths = {}

    def walk(key, parent):
        item = objects[key]
        if item.get('sourceTree') not in ('<group>', 'SOURCE_ROOT'):
            return
        path = (root if item.get('sourceTree') == 'SOURCE_ROOT' else parent) / item.get('path', '')
        paths[key] = path
        for child in item.get('children', []):
            walk(child, path)

    walk(objects[project['rootObject']]['mainGroup'], root)
    targets = {v['name']: v for v in objects.values() if v['isa'] == 'PBXNativeTarget'}
    failures = []
    for name, directory in [('GOAT', 'App/Sources'), ('GOATTests', 'App/Tests')]:
        target = targets.get(name)
        if target is None:
            failures.append(f'Missing {name} target')
            continue
        sources = [paths.get(objects[ref]['fileRef'])
                   for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
                   for ref in objects[phase]['files']]
        expected = set((root / directory).rglob('*.swift'))
        if set(sources) != expected or len(sources) != len(set(sources)):
            failures.append(f'{name} source membership differs from {directory}; add/remove files in Xcode')
        if name == 'GOAT':
            phases = [objects[key] for key in target['buildPhases']]
            if not any(p['isa'] == 'PBXShellScriptBuildPhase' and p.get('alwaysOutOfDate') == '1'
                       and 'release-metadata.py' in p.get('shellScript', '')
                       and '$(DERIVED_FILE_DIR)/GOAT-Info.plist' in p.get('outputPaths', []) for p in phases):
                failures.append('App must generate fresh release identity on every build')
            for key in objects[target['buildConfigurationList']]['buildConfigurations']:
                if objects[key]['buildSettings'].get('INFOPLIST_FILE') != '$(DERIVED_FILE_DIR)/GOAT-Info.plist':
                    failures.append('App configuration must consume the generated Info.plist')
    return failures


def main():
    failures = validate(load_project())
    scheme = ET.parse(PROJECT / 'xcshareddata/xcschemes/GOAT.xcscheme')
    test = scheme.find('TestAction')
    env = {x.attrib['key']: x.attrib['value'] for x in test.findall('EnvironmentVariables/EnvironmentVariable')
           if x.attrib.get('isEnabled') == 'YES'}
    if env.get('GOAT_TEST_MODE') != '1' or env.get('GOAT_HOME') != '$(PROJECT_TEMP_DIR)/GOATTestsHome':
        failures.append('Shared test scheme must isolate test state')
    lock = PROJECT / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    if not json.loads(lock.read_text()).get('pins'):
        failures.append('App dependency lock is missing pins')
    if failures:
        raise SystemExit('\n'.join(failures))
    print('Maintained Xcode project: source membership, release wiring and shared test scheme pass')


if __name__ == '__main__':
    main()
