"""Check config/app_compat.json, the incompatible-release mark (#195 P2).

The file names the lowest App version the backend still serves. A PR that
makes older Apps unusable (their writes refused, a payload they cannot read)
raises it to this release's pubspec version in the same diff, so review sees
it; CD then raises client_config's minimum to it (staging at deploy,
production once both stores list the release). See docs/CICD.md.

    python3 tool/check_app_compat.py                 # the file alone
    python3 tool/check_app_compat.py --base <sha>    # also what the PR changed

On a pull request the base comes from GITHUB_EVENT_PATH when --base is not
given. Rules:
  * x.y.z, and not above the pubspec version;
  * a change only raises it (lowering is an admin's manual call), and only
    to the pubspec version: that release is the one being marked;
  * a raise without a pubspec version change in the same PR is warned about,
    since it marks a version that may already be in review elsewhere.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
COMPAT = "config/app_compat.json"
PUBSPEC = "pubspec.yaml"
KEY = "min_supported_app_version"


def semver(value):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value or "")
    return tuple(map(int, match.groups())) if match else None


def compat_version(text):
    try:
        value = json.loads(text).get(KEY)
    except (ValueError, AttributeError):
        return None
    return value if isinstance(value, str) else None


def pubspec_version(text):
    match = re.search(r"^version:\s*(\S+)", text, re.M)
    return match[1].split("+")[0] if match else None


def show(ref, path):
    """The file at a commit, or None when it did not exist there."""
    result = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT,
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def check(compat_text, pubspec_text, base_compat=None, base_pubspec=None):
    """(errors, warnings) for the files now and, when given, at the base."""
    errors, warnings = [], []
    value = compat_version(compat_text)
    pubspec = pubspec_version(pubspec_text)
    if semver(value) is None:
        return [f"{COMPAT}: {KEY} must be x.y.z, got {value!r}"], warnings
    if semver(pubspec) is None:
        return [f"{PUBSPEC}: version must start with x.y.z, got {pubspec!r}"], warnings
    if semver(value) > semver(pubspec):
        errors.append(f"{COMPAT}: {value} is above the App version {pubspec}")
    if base_compat is None:
        return errors, warnings
    before = compat_version(base_compat)
    if value == before:
        return errors, warnings
    if semver(before) is not None and semver(value) < semver(before):
        errors.append(f"{COMPAT}: lowering {before} → {value} is not done here; "
                      "an admin lowers the minimum with admin_v1.set_min_supported_app_version")
    elif value != pubspec:
        errors.append(f"{COMPAT}: an incompatible release is marked with its own version: "
                      f"set {pubspec} (pubspec), not {value}")
    elif base_pubspec is not None and pubspec_version(base_pubspec) == pubspec:
        warnings.append(f"{COMPAT}: marks {pubspec} incompatible but this PR does not change "
                        f"the pubspec version; check {pubspec} is the release that breaks older Apps")
    return errors, warnings


def event_base():
    path = os.environ.get("GITHUB_EVENT_PATH")
    if not path or not Path(path).exists():
        return None
    event = json.loads(Path(path).read_text())
    return event.get("pull_request", {}).get("base", {}).get("sha")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="commit to compare with (default: the PR base)")
    args = parser.parse_args(argv)
    base = args.base or event_base()
    compat = (ROOT / COMPAT).read_text()
    pubspec = (ROOT / PUBSPEC).read_text()
    base_compat = show(base, COMPAT) if base else None
    base_pubspec = show(base, PUBSPEC) if base else None
    if base and base_compat is None:
        # The file is new in this PR: compare with the floor it replaces.
        base_compat = json.dumps({KEY: "0.1.0"})
    errors, warnings = check(compat, pubspec, base_compat, base_pubspec)
    for warning in warnings:
        print(f"::warning file={COMPAT}::{warning}")
    for error in errors:
        print(f"::error file={COMPAT}::{error}")
    if not errors:
        print(f"App compatibility mark: {compat_version(compat)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
