"""Gate expensive steps without skipping required workflow checks.

Keep paths aligned with the inputs consumed by each workflow. Git failures must
fail the step, never silently turn a required build into a no-op.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


APP_PATHS = (
    "lib/", "test/", "integration_test/", "test_driver/", "assets/",
    "pubspec.yaml", "pubspec.lock", ".flutter-version", ".metadata",
)
ROUTING_PATHS = (
    "tool/ci_changes.py", "tool/test_ci_changes.py", ".github/workflows/codeql.yml",
)
PATHS = {
    "quality": APP_PATHS + ROUTING_PATHS + (
        "web/", "analysis_options.yaml", ".github/workflows/ci.yml",
        "tool/check_version.py", "tool/generate_seed.py", "supabase/seed.sql",
    ),
    "android": APP_PATHS + ROUTING_PATHS + (
        "android/", ".github/workflows/android.yml", ".github/actions/mobile-setup/",
    ),
    "ios": APP_PATHS + ROUTING_PATHS + (
        "ios/", ".github/workflows/ios.yml", "tool/boot_ios_simulator.py",
        ".github/actions/mobile-setup/",
    ),
    "backend": ROUTING_PATHS + (
        "supabase/", ".supabase-version", ".github/workflows/ci.yml",
        "tool/generate_seed.py", "assets/demo/", "assets/rules/",
    ),
}


def needs_run(target, changed):
    """Directory prefixes end in /; other inputs are exact file names."""
    patterns = PATHS[target]
    return any(
        path.startswith(pattern) if pattern.endswith("/") else path == pattern
        for path in changed for pattern in patterns
    )


def changed_paths(event):
    """Compare the PR base to checked-out HEAD, or the entire pushed range.

    Missing/zero bases (manual/scheduled/initial push) mean a full validation.
    Disable rename detection so both removed and added inputs trigger checks.
    NUL delimiting preserves paths containing whitespace or newlines.
    """
    base = event.get("pull_request", {}).get("base", {}).get("sha") or event.get("before")
    if not base or set(base) == {"0"}:
        return None
    output = subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD"],
    )
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def main():
    target = sys.argv[1]
    if target not in PATHS:
        raise ValueError(f"Unknown CI target: {target}")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    changed = changed_paths(event)
    run = changed is None or needs_run(target, changed)
    print(f"run={str(run).lower()}")


if __name__ == "__main__":
    main()
