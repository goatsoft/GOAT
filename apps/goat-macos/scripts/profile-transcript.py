#!/usr/bin/env python3
"""Capture a bounded CPU sample of the isolated reasoning qualification host."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--sample", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a qualification command is required after --")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.sample.parent.mkdir(parents=True, exist_ok=True)
    sampler = None
    sample_error = None
    with args.log.open("w") as log, args.sample.with_suffix(".stderr.log").open("w") as diagnostics:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        try:
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
                marker = re.search(r"DELIVERY3_PROFILE_START phase=reasoning pid=(\d+)\b", line)
                if marker and sampler is None and sample_error is None:
                    try:
                        sampler = subprocess.Popen(
                            ["/usr/bin/sample", marker[1], "60", "-mayDie", "-file", str(args.sample)],
                            stdout=diagnostics, stderr=subprocess.STDOUT,
                        )
                    except OSError as error:
                        sample_error = str(error)
            result = process.wait()
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
                process.wait()
            if sampler is not None:
                try:
                    sample_result = sampler.wait(timeout=75)
                except subprocess.TimeoutExpired:
                    sampler.kill()
                    sampler.wait()
                    sample_result = 1
        if result:
            return result
        if sampler is None:
            print(sample_error or "No reasoning qualification PID was emitted.", file=sys.stderr)
            return 1
        if sample_result or not args.sample.is_file() or not args.sample.stat().st_size:
            print("Reasoning CPU sample failed; inspect the sampler diagnostics.", file=sys.stderr)
            return 1
        return 0


if __name__ == "__main__":
    sys.exit(main())
