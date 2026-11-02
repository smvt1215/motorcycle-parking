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
ADMIN_PATHS = (
    "lib/admin/", "lib/main_admin.dart", "test/admin/", "admin_web/",
    "firebase.json", ".firebaserc", "tool/prepare_admin_web.py", "tool/admin_smoke.cjs",
)
# The React admin rewrite (#195 P7) has its own Node toolchain and job; it
# cannot reach the Flutter app, the mobile builds or the database.
REACT_ADMIN_PATHS = ("admin_web/react/",)
ROUTING_PATHS = (
    "tool/ci_changes.py", "tool/test_ci_changes.py", ".github/workflows/codeql.yml",
)
PATHS = {
    "quality": APP_PATHS + ADMIN_PATHS + ROUTING_PATHS + (
        "web/", "analysis_options.yaml", ".github/workflows/ci.yml",
        "tool/check_version.py", "tool/generate_seed.py", "supabase/seed.sql",
        # test/imported_spots_test.dart checks the generated import data.
        "data/imports/", ".github/workflows/cd-staging.yml",
        # test/precheck_test.dart checks the app against the shared rules.
        "supabase/functions/submit-report/precheck_rules.json",
        "supabase/functions/submit-report/precheck_cases.json",
        # test/parking_contract_test.dart mirrors the parking contract.
        "supabase/functions/_shared/parking_contract.json",
        "supabase/functions/_shared/parking_contract_cases.json",
        # test/fee_contract_test.dart checks the generated fee note bound.
        "supabase/functions/_shared/fee_note_limit.json",
        # test/parking_decision_test.dart runs the shared rule verdicts.
        "supabase/functions/_shared/rule_verdict_cases.json",
        # lib/api/v1/*.g.dart are generated from the API documents.
        "supabase/api/v1/", "tool/gen_api_dart.py",
    ),
    "android": APP_PATHS + ROUTING_PATHS + (
        "android/", ".github/workflows/android.yml", ".github/actions/mobile-setup/",
        "tool/retry_command.py",
    ),
    "ios": APP_PATHS + ROUTING_PATHS + (
        "ios/", ".github/workflows/ios.yml", "tool/boot_ios_simulator.py",
        ".github/actions/mobile-setup/", "tool/retry_command.py",
    ),
    "backend": ROUTING_PATHS + (
        "supabase/", ".supabase-version", ".github/workflows/ci.yml", "workers/",
        "tool/generate_seed.py", "assets/demo/", "assets/rules/",
        # Regenerates the contract SQL and checks it for drift.
        "tool/gen_contract_sql.py", "tool/fee_text.py",
    ),
    "admin_react": REACT_ADMIN_PATHS + ROUTING_PATHS + (
        # src/design/tokens.test.ts checks the tokens against DESIGN.md.
        "admin_web/DESIGN.md", ".github/workflows/ci.yml",
        # src/api/v1/*.generated.ts are generated from the API documents.
        "supabase/api/v1/",
    ),
}


def needs_run(target, changed):
    """Directory prefixes end in /; other inputs are exact file names."""
    patterns = PATHS[target]
    if target != "admin_react":
        # admin_web/ feeds the Flutter admin build; its react/ folder does not.
        changed = [path for path in changed if not path.startswith(REACT_ADMIN_PATHS)]
    if target in ("android", "ios"):
        # The admin entrypoint and tests cannot be reached from the mobile app.
        changed = [path for path in changed if not any(
            path.startswith(pattern) if pattern.endswith("/") else path == pattern
            for pattern in ADMIN_PATHS
        )]
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
