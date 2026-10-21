"""Run a flaky simulator command with a per-attempt timeout and limited retries.

Simulator integration tests occasionally hang before connecting to the app or
lose the device after the tests finish; both are retried instead of waiting for
the job timeout. Only the exit status of the final attempt counts.
"""
import argparse
import os
import signal
import subprocess
import sys


def run_once(command, timeout):
    """Exit code of one attempt; a timeout kills the whole process group."""
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"::warning::Attempt timed out after {timeout:.0f}s: {' '.join(command)}", flush=True)
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return 124


def run(command, attempts, timeout, before_retry=None):
    code = 1
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            print(f"::warning::Retrying (attempt {attempt}/{attempts}) after exit code {code}", flush=True)
            if before_retry:
                # Recovery is best effort; the retried command reports the real outcome.
                run_once(["bash", "-c", before_retry], timeout=120)
        code = run_once(command, timeout)
        if code == 0:
            return 0
    return code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--timeout-minutes", type=float, required=True)
    parser.add_argument("--before-retry", help="shell command run before each retry")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.attempts < 1 or args.timeout_minutes <= 0:
        parser.error("a command, at least one attempt and a positive timeout are required")
    return run(command, args.attempts, args.timeout_minutes * 60, args.before_retry)


if __name__ == "__main__":
    sys.exit(main())
