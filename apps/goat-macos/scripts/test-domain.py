#!/usr/bin/env python3
"""Run the package and hosted tests owned by one domain. Unknown selections fail."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# Value-only interfaces are verified through their real consumers, not tautological constructors.
CONTRACT_CONSUMERS = {'Tools': ['GOATed', 'MCPClient', 'Pens', 'Shepherd'], 'goat': ['Hitch']}


def domains():
    packages = set(re.findall(r'\.testTarget\(name: "(\w+)Tests"', (ROOT / 'Modules/Package.swift').read_text()))
    plans = {p.stem for p in (ROOT / 'TestPlans').glob('*.xctestplan')} - {'All', 'Qualification'}
    return packages, plans


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('module')
    args = parser.parse_args()
    packages, plans = domains()
    if args.module not in packages | plans | CONTRACT_CONSUMERS.keys():
        parser.error('Choose a tested domain: ' + ', '.join(sorted(packages | plans | CONTRACT_CONSUMERS.keys())))
    commands = []
    owners = CONTRACT_CONSUMERS.get(args.module, [args.module])
    if args.module in CONTRACT_CONSUMERS:
        print(f"{args.module} contracts are exercised by: {', '.join(owners)}", flush=True)
    for owner in owners:
        if owner in packages:
            commands.append(['make', 'test-package', 'MODULE=' + owner])
        if owner in plans:
            commands.append(['make', 'test-app', 'TEST_PLAN=' + owner])
    for command in commands:
        subprocess.run(command, cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
