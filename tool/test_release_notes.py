"""Check that release retries publish only receipts for actual store builds."""
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from release_notes import publish, validate_receipt


class ReleaseReceiptTest(unittest.TestCase):
    def test_receipt_is_bound_to_platform_build_and_binary_type(self):
        validate_receipt("android", "101", "a" * 64 + "  android-101.aab")
        for value in ("a" * 64 + "  ios-101.ipa", "a" * 64 + "  android-102.aab", "unknown  android-101.aab"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_receipt("android", "101", value)

    def test_retry_preserves_notes_and_uses_original_selected_receipts(self):
        notes = []

        def gh(*args):
            if args[:2] == ("release", "view"):
                return json.dumps({"body": "Generated notes\n<!-- cd-binary-hashes -->\nold hashes", "isDraft": True})
            if args[:2] == ("release", "download"):
                name = args[args.index("--pattern") + 1]
                directory = Path(args[args.index("--dir") + 1])
                platform, number = name.removeprefix("sha256-").removesuffix(".txt").split("-")
                extension = "aab" if platform == "android" else "ipa"
                (directory / name).write_text("a" * 64 + f"  {platform}-{number}.{extension}\n")
                return ""
            if args[:2] == ("release", "edit"):
                notes.append(Path(args[args.index("--notes-file") + 1]).read_text())
                self.assertIn("--draft=false", args)
                return ""
            self.fail(f"Unexpected GitHub operation: {args}")

        with patch.dict(os.environ, {"ANDROID_BUILD": "101", "IOS_BUILD": "103"}), patch("release_notes.gh", gh):
            publish("v1.2.3")
        self.assertEqual(notes[0].count("<!-- cd-binary-hashes -->"), 1)
        self.assertTrue(notes[0].startswith("Generated notes"))
        self.assertIn("android-101.aab", notes[0])
        self.assertIn("ios-103.ipa", notes[0])
        self.assertNotIn("old hashes", notes[0])


if __name__ == "__main__":
    unittest.main()
