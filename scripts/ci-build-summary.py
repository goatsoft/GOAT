#!/usr/bin/env python3
"""Summarize one CI verification phase for the run summary (ADR-0095).

Reports duration, exit status, compilation-cache state and compiler reuse, and the
largest entries of Xcode's build timing summary. It only reads the phase log and never
changes the phase result.
"""
import argparse
import os
import re
import subprocess

TIMING = re.compile(r'^(?P<name>\S+) \((?P<tasks>\d+) tasks?\) \| (?P<seconds>[0-9.]+) seconds$')


def parse(lines):
    """Return compiler cache hits, misses and timing rows parsed from an xcodebuild log."""
    hits = misses = 0
    timings = []
    in_summary = False
    for raw in lines:
        line = raw.rstrip('\n')
        if line == 'Cache hit':
            hits += 1
        elif line == 'Cache miss':
            misses += 1
        if line.strip() == 'Build Timing Summary':
            in_summary = True
            timings = []
            continue
        if in_summary:
            match = TIMING.match(line.strip())
            if match:
                timings.append((match['name'], int(match['tasks']), float(match['seconds'])))
            elif line.startswith('** '):
                in_summary = False
    return hits, misses, timings


def cache_megabytes(path):
    if not path or not os.path.isdir(path):
        return None
    try:
        return int(subprocess.check_output(['du', '-sm', path], text=True).split()[0])
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        return None


def render(phase, seconds, status, cache, hits, misses, timings, size_mb, top=6):
    minutes, secs = divmod(max(0, seconds), 60)
    out = [f'### {phase}: {minutes}m {secs:02d}s (exit {status})', '']
    if cache:
        reuse = f'{hits} hits, {misses} misses' if hits or misses else 'no compiler cache activity recorded'
        size = f', {size_mb} MB' if size_mb is not None else ''
        out.append(f'Compilation cache: {cache}{size}; {reuse}.')
    else:
        out.append('Compilation cache: not used.')
    if timings:
        out += ['', '| Task | Tasks | Seconds |', '| --- | ---: | ---: |']
        for name, tasks, secs_ in sorted(timings, key=lambda row: row[2], reverse=True)[:top]:
            out.append(f'| {name} | {tasks} | {secs_:.1f} |')
    out.append('')
    return '\n'.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True)
    parser.add_argument('--seconds', type=int, required=True)
    parser.add_argument('--exit', dest='status', type=int, required=True)
    parser.add_argument('--cache', default='')
    parser.add_argument('--cas', default='')
    parser.add_argument('--log', default='')
    args = parser.parse_args()
    lines = []
    if args.log and os.path.isfile(args.log):
        with open(args.log, errors='replace') as handle:
            lines = handle.readlines()
    hits, misses, timings = parse(lines)
    print(render(args.phase, args.seconds, args.status, args.cache, hits, misses, timings,
                 cache_megabytes(args.cas) if args.cache else None))


if __name__ == '__main__':
    main()
