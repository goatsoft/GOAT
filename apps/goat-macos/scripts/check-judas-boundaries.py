#!/usr/bin/env python3
"""Catch accidental unmanaged network entry points; not a native-code sandbox."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
rules = [
    (re.compile(r'\bposix_spawn\s*\('),
     {'Modules/Sources/Pens/PenCommandTools.swift'},
     'native commands need the reviewed Pen sandbox and JUDAS boundary'),
    (re.compile(r'\bProcess\s*\('),
     {'Modules/Sources/Herd/HerdWorkspace.swift', 'Modules/Sources/MCPClient/ServerManager.swift'},
     'process launch needs a reviewed local Git or JUDAS-managed MCP boundary'),
    (re.compile(r'\bURLSession\s*(?:\(|\.\s*shared\b)'),
     {'Modules/Sources/JUDAS/Judas.swift'}, 'HTTP must use JudasHTTPClient'),
    (re.compile(r'\b(?:NWConnection|NWListener|AsyncImage)\s*\('),
     set(), 'network entry point needs JUDAS integration'),
    (re.compile(r'\bWKWebView\s*\('),
     {'Modules/Sources/Paddock/WebPreview.swift'}, 'web content must use the JUDAS preview host'),
    (re.compile(r'(?<![.\w])socket\s*\('),
     {'Modules/Sources/Hitch/LocalSocket.swift'}, 'native sockets need an explicit host boundary'),
]
failures = []
for source in [root / 'App/Sources', root / 'Modules/Sources']:
    for path in sorted(source.rglob('*.swift')):
        relative = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for pattern, allowed, reason in rules:
                if relative not in allowed and pattern.search(line):
                    failures.append(f'{relative}:{number}: {reason}')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('JUDAS network boundary check passed')
