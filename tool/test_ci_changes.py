"""Regression tests for selective CI; irrelevant changes must not hide failures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ci_changes import PATHS, changed_paths, main, needs_run


class ChangeRoutingTest(unittest.TestCase):
    def targets(self, *files):
        return {target for target in PATHS if needs_run(target, files)}

    def test_documents_and_release_tools_do_not_build_application(self):
        for path in ("docs/PLAN.md", "README.md", ".github/dependabot.yml",
                     "tool/cd_gate.py", "tool/ios_signing.py", "tool/release_notes.py",
                     "tool/tdx_audit.ts", "tool/import_kml.py"):
            with self.subTest(path=path):
                self.assertEqual(self.targets(path), set())

    def test_platform_inputs_are_isolated(self):
        self.assertEqual(self.targets("android/app/build.gradle.kts"), {"android"})
        self.assertEqual(self.targets("ios/Runner/AppDelegate.swift"), {"ios"})
        self.assertEqual(self.targets("tool/boot_ios_simulator.py"), {"ios"})
        self.assertEqual(self.targets("tool/retry_command.py"), {"android", "ios"})
        self.assertEqual(self.targets("web/maps_loader.js"), {"quality"})
        self.assertEqual(self.targets("analysis_options.yaml"), {"quality"})
        self.assertEqual(self.targets("data/imports/official/spots.json"), {"quality"})
        self.assertEqual(self.targets("supabase/functions/submit-report/index.ts"), {"backend"})
        self.assertEqual(self.targets(".github/actions/mobile-setup/action.yml"), {"android", "ios"})

    def test_shared_flutter_inputs_trigger_all_app_checks(self):
        for path in ("lib/main.dart", "test/model_test.dart", "integration_test/ui_test.dart",
                     "test_driver/integration_test.dart", "assets/fonts/Outfit.ttf",
                     "pubspec.yaml", "pubspec.lock", ".flutter-version", ".metadata"):
            with self.subTest(path=path):
                self.assertEqual(self.targets(path), {"quality", "android", "ios"})

    def test_admin_inputs_skip_mobile_but_keep_quality(self):
        for path in ("lib/admin/admin_app.dart", "lib/main_admin.dart",
                     "test/admin/auth_test.dart", "admin_web/index.html",
                     "firebase.json", ".firebaserc", "tool/prepare_admin_web.py", "tool/admin_smoke.cjs"):
            with self.subTest(path=path):
                self.assertEqual(self.targets(path), {"quality"})
        self.assertEqual(self.targets("lib/admin/admin_app.dart", "lib/models/parking.dart"),
                         {"quality", "android", "ios"})
        self.assertEqual(self.targets("lib/main_admin.dart.old"), {"quality", "android", "ios"})
        # A move into admin still validates the old shared input.
        self.assertEqual(self.targets("lib/admin/auth.dart", "lib/features/auth.dart"),
                         {"quality", "android", "ios"})

    def test_seed_inputs_check_both_generation_and_database(self):
        for path in ("tool/generate_seed.py", "supabase/seed.sql"):
            with self.subTest(path=path):
                self.assertEqual(self.targets(path), {"quality", "backend"})
        self.assertEqual(self.targets("assets/demo/spots.json"), set(PATHS))
        self.assertEqual(self.targets("assets/rules/parking_rules.json"), set(PATHS))

    def test_shared_precheck_rules_check_both_app_and_function(self):
        for name in ("precheck_rules.json", "precheck_cases.json"):
            with self.subTest(name=name):
                path = f"supabase/functions/submit-report/{name}"
                self.assertEqual(self.targets(path), {"quality", "backend"})
        self.assertEqual(self.targets("supabase/functions/submit-report/precheck.ts"),
                         {"backend"})

    def test_parking_contract_checks_app_function_and_database(self):
        for name in ("parking_contract.json", "parking_contract_cases.json", "fee_note_limit.json",
                     "rule_verdict_cases.json"):
            with self.subTest(name=name):
                path = f"supabase/functions/_shared/{name}"
                self.assertEqual(self.targets(path), {"quality", "backend"})
        for path in ("tool/gen_contract_sql.py", "tool/fee_text.py", "supabase/contract/parking_contract.sql",
                     "supabase/tests/parking_contract_test.sql", "supabase/tests/rule_verdict_test.sql"):
            with self.subTest(path=path):
                self.assertEqual(self.targets(path), {"backend"})

    def test_routing_changes_revalidate_every_target(self):
        for path in ("tool/ci_changes.py", "tool/test_ci_changes.py", ".github/workflows/codeql.yml"):
            self.assertEqual(self.targets(path), set(PATHS))

    def test_workflows_revalidate_their_own_checks(self):
        self.assertEqual(self.targets(".github/workflows/ci.yml"), {"quality", "backend"})
        self.assertEqual(self.targets(".github/workflows/android.yml"), {"android"})
        self.assertEqual(self.targets(".github/workflows/ios.yml"), {"ios"})

    def test_root_inputs_are_not_prefix_matches(self):
        self.assertEqual(self.targets("pubspec.yaml.notes", ".flutter-version.old"), set())

    def test_missing_or_zero_base_requests_full_validation(self):
        for event in ({}, {"before": "0" * 40}):
            with patch("ci_changes.subprocess.check_output") as git:
                self.assertIsNone(changed_paths(event))
                git.assert_not_called()

    def test_pr_base_takes_precedence_and_paths_are_nul_delimited(self):
        event = {"before": "push-base", "pull_request": {"base": {"sha": "pr-base"}}}
        with patch("ci_changes.subprocess.check_output", return_value=b"ios/old.swift\0docs/new\nname.md\0") as git:
            self.assertEqual(changed_paths(event), ["ios/old.swift", "docs/new\nname.md"])
            git.assert_called_once_with([
                "git", "diff", "--no-renames", "--name-only", "-z", "pr-base", "HEAD",
            ])

    def test_push_uses_before_sha_and_git_errors_are_not_success(self):
        with patch("ci_changes.subprocess.check_output", side_effect=subprocess.CalledProcessError(1, "git")) as git:
            with self.assertRaises(subprocess.CalledProcessError):
                changed_paths({"before": "push-base"})
            self.assertEqual(git.call_args.args[0][-2:], ["push-base", "HEAD"])

    def test_main_emits_only_boolean_step_output(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / "event.json"
            event.write_text(json.dumps({"before": "base"}))
            with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event)}), \
                    patch("ci_changes.sys.argv", ["ci_changes.py", "quality"]), \
                    patch("ci_changes.subprocess.check_output", return_value=b"docs/PLAN.md\0"), \
                    patch("builtins.print") as output:
                main()
                output.assert_called_once_with("run=false")

    def test_real_git_cross_directory_rename_and_deletion_keep_old_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], stderr=subprocess.DEVNULL)
            git("init")
            (root / "ios").mkdir()
            (root / "ios/old.swift").write_text("// original source\n")
            (root / "ios/deleted.swift").write_text("// deleted source\n")
            git("add", ".")
            git("-c", "commit.gpgsign=false", "-c", "user.name=CI test",
                "-c", "user.email=ci@example.test", "commit", "-m", "fixture")
            base = git("rev-parse", "HEAD").decode().strip()
            (root / "docs").mkdir()
            (root / "ios/old.swift").rename(root / "docs/moved.md")
            (root / "ios/deleted.swift").unlink()
            git("add", ".")
            git("-c", "commit.gpgsign=false", "-c", "user.name=CI test",
                "-c", "user.email=ci@example.test", "commit", "-m", "move and delete")
            previous = Path.cwd()
            try:
                os.chdir(root)
                paths = changed_paths({"before": base})
            finally:
                os.chdir(previous)
            assert paths is not None
            self.assertEqual(set(paths), {"ios/old.swift", "ios/deleted.swift", "docs/moved.md"})
            self.assertTrue(needs_run("ios", paths))


if __name__ == "__main__":
    unittest.main()
