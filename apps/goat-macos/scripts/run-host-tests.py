#!/usr/bin/env python3
"""Run xcodebuild tests and reject an empty or entirely skipped selection."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


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
    outcome = subprocess.run(command)
    print(f'Test results: {result}', flush=True)
    if outcome.returncode:
        raise SystemExit(outcome.returncode)
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
