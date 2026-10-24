"""Native callbacks must reach Supabase without becoming Flutter routes."""
from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ANDROID = "{http://schemas.android.com/apk/res/android}"


class OAuthCallbackConfigurationTest(unittest.TestCase):
    def test_android_delegates_callback_to_app_links(self):
        manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml")
        activity = manifest.find("application/activity")
        flags = {
            item.get(ANDROID + "name"): item.get(ANDROID + "value")
            for item in activity.findall("meta-data")
        }
        self.assertEqual(flags.get("flutter_deeplinking_enabled"), "false")
        callback = activity.find("intent-filter/data")
        self.assertEqual(callback.get(ANDROID + "scheme"), "${oauthScheme}")
        self.assertEqual(callback.get(ANDROID + "host"), "login-callback")

    def test_ios_debug_and_release_delegate_callback_to_app_links(self):
        for name in ("Info.plist", "Info-Debug.plist"):
            with self.subTest(plist=name):
                with (ROOT / "ios/Runner" / name).open("rb") as source:
                    config = plistlib.load(source)
                self.assertIs(config.get("FlutterDeepLinkingEnabled"), False)
                schemes = [
                    scheme
                    for entry in config["CFBundleURLTypes"]
                    for scheme in entry["CFBundleURLSchemes"]
                ]
                self.assertIn("$(OAUTH_SCHEME)", schemes)


if __name__ == "__main__":
    unittest.main()
