import json
from pathlib import Path
import tempfile
import unittest

from configure_maps import configure


class MapsConfigurationTest(unittest.TestCase):
    def test_keys_are_separated_and_outputs_are_private(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "input.json"
            config.write_text(json.dumps({"android": "android-test", "ios": "ios-test", "web": "web-test"}))
            self.assertEqual(configure(config, root), ["android", "ios", "web"])
            dart = json.loads((root / "config/maps.generated.json").read_text())
            self.assertTrue(dart["GOOGLE_MAPS_ANDROID_ENABLED"])
            self.assertTrue(dart["GOOGLE_MAPS_IOS_ENABLED"])
            self.assertEqual(dart["GOOGLE_MAPS_WEB_API_KEY"], "web-test")
            self.assertNotIn("android-test", json.dumps(dart))
            self.assertNotIn("ios-test", json.dumps(dart))
            self.assertEqual((root / "ios/Flutter/Maps.xcconfig").stat().st_mode & 0o777, 0o600)

    def test_only_web_can_be_configured_and_removal_clears_native_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "input.json"
            config.write_text(json.dumps({"android": "android-test", "ios": "ios-test"}))
            configure(config, root)
            config.write_text(json.dumps({"web": "web-test"}))
            self.assertEqual(configure(config, root), ["web"])
            dart = json.loads((root / "config/maps.generated.json").read_text())
            self.assertFalse(dart["GOOGLE_MAPS_ANDROID_ENABLED"])
            self.assertFalse(dart["GOOGLE_MAPS_IOS_ENABLED"])
            self.assertEqual((root / "android/maps.properties").read_text(), "apiKey=\n")

    def test_invalid_input_never_overwrites_existing_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "input.json"
            config.write_text(json.dumps({"web": "web-test"}))
            configure(config, root)
            before = (root / "config/maps.generated.json").read_bytes()
            for invalid in [{"web": "bad\nkey"}, {"web": 123}, {"unexpected": "value"}, []]:
                config.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    configure(config, root)
                self.assertEqual((root / "config/maps.generated.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
