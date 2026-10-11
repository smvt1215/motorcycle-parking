"""Require a version newer than every stable release tag."""
import re
import subprocess
from pathlib import Path


def stable(value):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", value)
    return tuple(map(int, match.groups())) if match else None


version = re.search(r"^version:\s*(\S+)", Path("pubspec.yaml").read_text(), re.M)[1]
current = stable(version.split("+")[0])
if current is None:
    raise SystemExit("pubspec version must be a stable X.Y.Z version")
tags = subprocess.check_output(["git", "tag", "--list"], text=True).splitlines()
releases = [parsed for tag in tags if (parsed := stable(tag)) is not None]
if releases and current <= max(releases):
    raise SystemExit(f"Version {current} must be newer than release {max(releases)}")
print(f"Version check passed: {version}")
