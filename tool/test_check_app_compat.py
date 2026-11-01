"""Unit tests for tool/check_app_compat.py."""
import json
import unittest

import check_app_compat as compat


def mark(version):
    return json.dumps({"min_supported_app_version": version})


def pubspec(version):
    return f"name: x\nversion: {version}+7\n"


class CheckAppCompatTest(unittest.TestCase):
    def test_the_repo_file_passes(self):
        text = (compat.ROOT / compat.COMPAT).read_text()
        pub = (compat.ROOT / compat.PUBSPEC).read_text()
        self.assertEqual(compat.check(text, pub), ([], []))

    def test_value_must_be_xyz_and_not_above_the_app(self):
        for bad in ("1.2", "latest", None):
            with self.subTest(bad=bad):
                errors, _ = compat.check(mark(bad), pubspec("1.2.0"))
                self.assertIn("must be x.y.z", errors[0])
        errors, _ = compat.check(mark("1.3.0"), pubspec("1.2.0"))
        self.assertIn("above the App version 1.2.0", errors[0])

    def test_marking_this_release_passes(self):
        self.assertEqual(
            compat.check(mark("1.2.0"), pubspec("1.2.0"), mark("1.0.0"), pubspec("1.1.0")),
            ([], []))

    def test_marking_without_a_version_change_is_warned(self):
        errors, warnings = compat.check(mark("1.2.0"), pubspec("1.2.0"), mark("1.0.0"),
                                        pubspec("1.2.0"))
        self.assertEqual(errors, [])
        self.assertIn("does not change the pubspec version", warnings[0])

    def test_a_change_marks_only_this_release(self):
        errors, _ = compat.check(mark("1.1.0"), pubspec("1.2.0"), mark("1.0.0"), pubspec("1.1.0"))
        self.assertIn("set 1.2.0 (pubspec), not 1.1.0", errors[0])

    def test_lowering_is_an_admin_call(self):
        errors, _ = compat.check(mark("1.0.0"), pubspec("1.2.0"), mark("1.2.0"), pubspec("1.2.0"))
        self.assertIn("lowering 1.2.0 → 1.0.0", errors[0])

    def test_an_untouched_mark_needs_nothing(self):
        self.assertEqual(
            compat.check(mark("1.0.0"), pubspec("1.2.0"), mark("1.0.0"), pubspec("1.1.0")),
            ([], []))


if __name__ == "__main__":
    unittest.main()
