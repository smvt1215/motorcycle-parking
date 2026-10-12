"""Ensure staging identities and backend targeting cannot be crossed silently."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from cd_config import configure_build


class BuildConfigurationTest(unittest.TestCase):
    def test_backend_target_check_needs_no_mobile_credentials_or_files(self):
        with tempfile.TemporaryDirectory() as directory:
            ref = "a" * 20
            env = {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co"}
            with patch.dict(os.environ, env), patch("cd_config.ROOT", Path(directory)):
                configure_build("production", "backend")
            self.assertEqual(list(Path(directory).iterdir()), [])
    def test_each_flavor_has_distinct_login_callback_and_backend(self):
        for environment in ("staging", "production"):
            with self.subTest(environment=environment), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ref = "a" * 20
                env = {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co",
                       "SUPABASE_ANON_KEY": "public-anon-test", "GOOGLE_MAPS_API_KEY": "test-key"}
                with patch.dict(os.environ, env), patch("cd_config.ROOT", root):
                    configure_build(environment, "ios")
                data = json.loads((root / f"config/{environment}.json").read_text())
                suffix = ".staging" if environment == "staging" else ""
                self.assertEqual(data["OAUTH_REDIRECT_URL"], f"tw.motopark.motorcycleparking{suffix}://login-callback")
                self.assertTrue(data["GOOGLE_MAPS_IOS_ENABLED"])
                self.assertFalse(data["GOOGLE_MAPS_ANDROID_ENABLED"])
                self.assertEqual((root / f"config/{environment}.json").stat().st_mode & 0o777, 0o600)

    def test_wrong_backend_is_rejected_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {"SUPABASE_PROJECT_REF": "a" * 20, "SUPABASE_URL": "https://other.supabase.co"}
            with patch.dict(os.environ, env), patch("cd_config.ROOT", root), self.assertRaises(ValueError):
                configure_build("staging", "ios")
            self.assertEqual(list(root.iterdir()), [])

    def test_missing_map_key_cannot_publish_preview_map(self):
        with tempfile.TemporaryDirectory() as directory:
            ref = "a" * 20
            env = {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co",
                   "SUPABASE_ANON_KEY": "anon", "GOOGLE_MAPS_API_KEY": ""}
            with patch.dict(os.environ, env), patch("cd_config.ROOT", Path(directory)), self.assertRaises(ValueError):
                configure_build("production", "ios")


if __name__ == "__main__":
    unittest.main()
