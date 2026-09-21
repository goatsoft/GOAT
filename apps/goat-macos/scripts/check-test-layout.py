#!/usr/bin/env python3
"""Validate domain ownership, suite selection and isolation in maintained test plans."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def validate(root=ROOT):
    failures = []
    plans = {p.stem: json.loads(p.read_text()) for p in (root / 'TestPlans').glob('*.xctestplan')}
    directories = {p.name for p in (root / 'App/Tests').iterdir() if p.is_dir()}
    if set(plans) != directories | {'All'}:
        failures.append('Every hosted domain needs exactly one named plan, plus All')
    root_suite = (root / 'App/Tests/AppTests.swift').read_text()
    if '@Suite(.serialized)' not in root_suite:
        failures.append('Shared app state requires a serialized root suite')
    if set(re.findall(r'@Suite struct (\w+)', root_suite)) != directories - {'Qualification'}:
        failures.append('Root domain suites differ from the test folders')
    for file in (root / 'App/Tests').glob('*.swift'):
        if file.name != 'AppTests.swift':
            failures.append(f'Loose hosted test file: {file.name}')
    native = {}
    for domain in directories:
        native[domain] = []
        for file in (root / 'App/Tests' / domain).glob('*.swift'):
            source = file.read_text()
            native[domain] += re.findall(r'final class (\w+): XCTestCase', source)
            owners = re.findall(r'extension AppTests\.(\w+)', source)
            if any(owner != domain for owner in owners):
                failures.append(f'{file.name}: suite owner differs from folder')
            if re.search(r'^@Test|^@MainActor\s*\n@Test', source, re.M):
                failures.append(f'{file.name}: hosted Swift tests must belong to a domain suite')
    for name, plan in plans.items():
        env = {x['key']: x['value'] for x in plan['defaultOptions'].get('environmentVariableEntries', [])}
        if env.get('GOAT_TEST_MODE') != '1' or env.get('GOAT_HOME') != '$(PROJECT_TEMP_DIR)/GOATTestsHome':
            failures.append(f'{name}: plan must isolate test state')
        if plan['defaultOptions'].get('targetForVariableExpansion', {}).get('identifier') != 'C832E203313CE6669FE5A036':
            failures.append(f'{name}: test-home variables need the app expansion target')
        targets = plan['testTargets']
        if len(targets) != 1 or targets[0]['target']['name'] != 'GOATTests' or targets[0].get('parallelizable') is not False:
            failures.append(f'{name}: use the single nonparallel hosted bundle')
            continue
        target = targets[0]
        if name == 'All':
            if 'selectedTests' in target or set(target.get('skippedTests', [])) != set(native.get('Qualification', [])):
                failures.append('All must run every ordinary test and exclude only qualification workloads')
        else:
            expected = {}
            if name != 'Qualification':
                expected['suites'] = [{'name': 'AppTests', 'suites': [{'name': name}]}]
            if native.get(name):
                expected['xctestClasses'] = [{'name': n} for n in sorted(native[name])]
            selection = target.get('selectedTests', {})
            if isinstance(selection, dict) and 'xctestClasses' in selection:
                selection['xctestClasses'].sort(key=lambda x: x['name'])
            if selection != expected:
                failures.append(f'{name}: plan selection differs from its owned suites/classes')
    scheme = ET.parse(root / 'GOAT.xcodeproj/xcshareddata/xcschemes/GOAT.xcscheme')
    refs = scheme.findall('TestAction/TestPlans/TestPlanReference')
    if {Path(x.attrib['reference']).stem for x in refs} != set(plans):
        failures.append('Shared scheme must expose every maintained test plan')
    if [Path(x.attrib['reference']).stem for x in refs if x.attrib.get('default') == 'YES'] != ['All']:
        failures.append('All must remain the default regression plan')
    return failures


if __name__ == '__main__':
    failures = validate()
    if failures:
        raise SystemExit('\n'.join(failures))
    print('Test layout: domain suites, plans and isolated host configuration pass')
