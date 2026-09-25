#!/usr/bin/env python3
"""Reject raw system colours in the transcript and its shared controls (#60 D8).

Colours come from `Caprine.Semantic` or the theme tokens so every theme and appearance applies.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('App/Sources/Bleet', 'App/Sources/DesignSystem/CaprineControls.swift')
RAW_COLOUR = re.compile(r'(?<![\w.])(?:Color)?\.(orange|green|red|blue|yellow|black|white|gray|grey|purple|pink)\b(?!\s*[:=(])')


def files(root=ROOT):
    for scope in SCOPES:
        path = root / scope
        yield from sorted(path.rglob('*.swift')) if path.is_dir() else [path]


def validate(root=ROOT):
    failures = []
    for file in files(root):
        for number, line in enumerate(file.read_text().splitlines(), 1):
            code = line.split('//', 1)[0]
            for match in RAW_COLOUR.finditer(code):
                failures.append(f'{file.relative_to(root)}:{number}: raw colour .{match.group(1)}; use Caprine.Semantic or theme tokens')
    return failures


if __name__ == '__main__':
    problems = validate()
    print('\n'.join(problems) or 'Transcript colours use Caprine tokens.')
    sys.exit(1 if problems else 0)
