#!/usr/bin/env python3
"""Run xcodebuild tests and reject an empty or entirely skipped selection."""
import json
import os
import re
from collections import Counter
from pathlib import Path
import subprocess
import sys
import tempfile


# Only framework messages observed during successful preview tests are summarized.
# Match the log envelope too: assertions/compiler diagnostics quoting these strings
# must remain visible. Unknown messages, sandbox denials and process crashes pass through.
FRAMEWORK_LINE = re.compile(
    r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[-+]\d{4} GOAT\[\d+:\d+\] (.*)$')
BENIGN_WEBKIT = {
    'retired service': re.compile(
        r'Could not signal service com\.apple\.WebKit\.(?:WebContent|Networking|GPU): '
        r'113: Could not find specified service'),
    'empty connection': re.compile(
        r'\[default\] WebContent\[\d+\] Conn 0x0 is not a valid connection ID\.'),
    'networkd preferences': re.compile(
        r'WebContent\[\d+\] networkd_settings_read_from_file_locked Sandbox is preventing '
        r'this process from reading networkd settings file at '
        r'"/Library/Preferences/com\.apple\.networkd\.plist", please add an exception\.'),
}


def benign_webkit_category(line):
    match = FRAMEWORK_LINE.fullmatch(line.rstrip('\r\n'))
    if match:
        for category, pattern in BENIGN_WEBKIT.items():
            if pattern.fullmatch(match[1]):
                return category
    return None


def run_logged(command, log_path, *, raw=False):
    """Always retain raw output and the child status; summarize a narrow allowlist."""
    counts = Counter()
    with log_path.open('w') as log:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors='replace', bufsize=1) as child:
            for line in child.stdout:
                log.write(line)
                category = benign_webkit_category(line)
                if category:
                    counts[category] += 1
                if raw or not category:
                    print(line, end='', flush=True)
            status = child.wait()
    print(f'Raw test log: {log_path}', flush=True)
    if counts:
        label = 'Observed' if raw else 'Summarized'
        print(f'{label} {sum(counts.values())} known WebKit framework messages: '
              + ', '.join(f'{key}={value}' for key, value in sorted(counts.items())), flush=True)
    return status


def require_executed_tests(summary):
    if summary.get('passedTests', 0) + summary.get('failedTests', 0) == 0:
        raise ValueError('No tests executed. Check the test plan/filter and live qualification opt-in.')


def main():
    command = sys.argv[1:]
    if '-resultBundlePath' in command:
        result = Path(command[command.index('-resultBundlePath') + 1])
    else:
        results = Path('.build/TestResults')
        results.mkdir(parents=True, exist_ok=True)
        parent = Path(tempfile.mkdtemp(prefix='run-', dir=results)).resolve()
        result = parent / 'Tests.xcresult'
        command += ['-resultBundlePath', str(result)]
    result.parent.mkdir(parents=True, exist_ok=True)
    status = run_logged(command, result.with_suffix('.log'),
                        raw=os.environ.get('GOAT_TEST_LOG_MODE') == 'raw')
    print(f'Test results: {result}', flush=True)
    if status:
        raise SystemExit(status)
    summary = json.loads(subprocess.check_output([
        'xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)]))
    try:
        require_executed_tests(summary)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print(f"Executed {summary['passedTests']} passed, {summary['failedTests']} failed, "
          f"{summary.get('skippedTests', 0)} skipped tests", flush=True)


if __name__ == '__main__':
    main()
