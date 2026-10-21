"""Skipping test builds must only happen when a platform is entirely unconfigured."""
import io
import unittest

from cd_mobile_setup import SETTINGS, main


def outputs(environ):
    out, log = io.StringIO(), io.StringIO()
    main(environ, out, log)
    return dict(line.split("=") for line in out.getvalue().split()), log.getvalue()


class MobileSetupTest(unittest.TestCase):
    def test_unconfigured_platforms_are_skipped_with_a_notice(self):
        values, log = outputs({"SUPABASE_URL": "https://x.supabase.co"})
        self.assertEqual(values, {"android": "false", "ios": "false"})
        self.assertEqual(log.count("::notice::"), 2)

    def test_any_setting_runs_the_build_so_missing_ones_still_fail(self):
        for platform, names in SETTINGS.items():
            for name in names:
                with self.subTest(name=name):
                    values, _ = outputs({name: "set"})
                    self.assertEqual(values[platform], "true")
                    self.assertEqual(sum(v == "true" for v in values.values()), 1)

    def test_empty_values_count_as_unset(self):
        values, _ = outputs({name: "" for names in SETTINGS.values() for name in names})
        self.assertEqual(values, {"android": "false", "ios": "false"})

    def test_values_are_never_printed(self):
        secret = "do-not-print-this"
        values, log = outputs({"ANDROID_KEYSTORE_BASE64": secret})
        self.assertNotIn(secret, log)
        self.assertNotIn(secret, "".join(values.values()))


if __name__ == "__main__":
    unittest.main()
