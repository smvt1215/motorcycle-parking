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

    def test_admin_web_uses_public_settings_without_mobile_signing_material(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ref = "a" * 20
            env = {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co",
                   "SUPABASE_ANON_KEY": "public-anon-test", "GOOGLE_MAPS_API_KEY": "web-key"}
            with patch.dict(os.environ, env, clear=True), patch("cd_config.ROOT", root):
                configure_build("staging", "web")
            config = root / "config/staging.json"
            self.assertEqual(json.loads(config.read_text()), {
                "SUPABASE_URL": env["SUPABASE_URL"],
                "SUPABASE_ANON_KEY": "public-anon-test", "GOOGLE_MAPS_WEB_API_KEY": "web-key",
            })
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertFalse((root / "android").exists())
            self.assertFalse((root / "ios").exists())

    def test_missing_map_key_cannot_publish_preview_map(self):
        with tempfile.TemporaryDirectory() as directory:
            ref = "a" * 20
            env = {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co",
                   "SUPABASE_ANON_KEY": "anon", "GOOGLE_MAPS_API_KEY": ""}
            with patch.dict(os.environ, env), patch("cd_config.ROOT", Path(directory)), self.assertRaises(ValueError):
                configure_build("production", "ios")

    def mobile_env(self, **extra):
        ref = "a" * 20
        return {"SUPABASE_PROJECT_REF": ref, "SUPABASE_URL": f"https://{ref}.supabase.co",
                "SUPABASE_ANON_KEY": "anon", "GOOGLE_MAPS_API_KEY": "maps", **extra}

    def test_app_check_options_follow_the_platform(self):
        env = self.mobile_env(FIREBASE_IOS_API_KEY="ios-key", FIREBASE_IOS_APP_ID="1:123456:ios:abc123",
                              FIREBASE_ANDROID_API_KEY="android-key",
                              FIREBASE_ANDROID_APP_ID="1:123456:android:def456",
                              FIREBASE_PROJECT_ID="demo-project")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.dict(os.environ, env, clear=True), patch("cd_config.ROOT", root):
                configure_build("staging", "ios")
            data = json.loads((root / "config/staging.json").read_text())
        self.assertEqual(data["FIREBASE_API_KEY"], "ios-key")
        self.assertEqual(data["FIREBASE_APP_ID"], "1:123456:ios:abc123")
        self.assertEqual(data["FIREBASE_MESSAGING_SENDER_ID"], "123456")
        self.assertEqual(data["FIREBASE_PROJECT_ID"], "demo-project")

    def test_missing_app_check_settings_build_without_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.dict(os.environ, self.mobile_env(), clear=True), patch("cd_config.ROOT", root):
                configure_build("production", "ios")
            data = json.loads((root / "config/production.json").read_text())
        self.assertFalse(any(name.startswith("FIREBASE_") for name in data))

    def test_partial_or_crossed_app_check_settings_are_rejected_before_any_write(self):
        cases = [
            {"FIREBASE_IOS_API_KEY": "key"},
            {"FIREBASE_IOS_APP_ID": "1:123456:ios:abc123", "FIREBASE_PROJECT_ID": "demo-project"},
            {"FIREBASE_IOS_API_KEY": "key", "FIREBASE_IOS_APP_ID": "1:123456:android:abc123",
             "FIREBASE_PROJECT_ID": "demo-project"},
            {"FIREBASE_IOS_API_KEY": "key", "FIREBASE_IOS_APP_ID": "1:123456:ios:abc123"},
        ]
        for extra in cases:
            with self.subTest(extra=sorted(extra)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with patch.dict(os.environ, self.mobile_env(**extra), clear=True), \
                        patch("cd_config.ROOT", root), self.assertRaises(ValueError):
                    configure_build("staging", "ios")
                self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
