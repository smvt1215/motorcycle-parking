"""Print a GitHub step output without skipping required workflow checks."""
import json
import os
import subprocess
import sys

event = json.loads(open(os.environ["GITHUB_EVENT_PATH"]).read())
base = event.get("pull_request", {}).get("base", {}).get("sha") or event.get("before")
prefixes = {
    "ios": ("lib/", "test/", "integration_test/", "test_driver/", "assets/", "ios/", "pubspec", ".flutter-version", ".github/workflows/ios.yml", "tool/"),
    "android": ("lib/", "test/", "integration_test/", "test_driver/", "assets/", "android/", "pubspec", ".flutter-version", ".github/workflows/android.yml", "tool/"),
    "backend": ("supabase/", "tool/", ".supabase-version", ".github/workflows/ci.yml"),
}[sys.argv[1]]
if not base or set(base) == {"0"}:
    run = True
else:
    changed = subprocess.check_output(["git", "diff", "--name-only", base, "HEAD"], text=True).splitlines()
    run = any(path.startswith(prefixes) for path in changed)
print(f"run={str(run).lower()}")
