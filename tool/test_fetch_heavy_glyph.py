import base64
import tempfile
import unittest
from pathlib import Path

from fetch_heavy_glyph import DESTINATION, fetch

# A stand-in drawing, not the licensed glyph.
SAMPLE = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>'


class FetchHeavyGlyphTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_secret_writes_the_asset(self) -> None:
        env = {"HEAVY_GLYPH_SVG_BASE64": base64.b64encode(SAMPLE).decode()}
        self.assertTrue(fetch(env, self.root))
        self.assertEqual((self.root / DESTINATION).read_bytes(), SAMPLE)

    def test_local_file_writes_the_asset(self) -> None:
        source = self.root / "glyph.svg"
        source.write_bytes(SAMPLE)
        self.assertTrue(fetch({"HEAVY_GLYPH_SVG_PATH": str(source)}, self.root))
        self.assertEqual((self.root / DESTINATION).read_bytes(), SAMPLE)

    def test_no_source_writes_nothing(self) -> None:
        env = {"HEAVY_GLYPH_SVG_PATH": str(self.root / "missing.svg")}
        self.assertFalse(fetch(env, self.root))
        self.assertFalse((self.root / DESTINATION).exists())

    def test_rejects_bad_input(self) -> None:
        with self.assertRaises(ValueError):
            fetch({"HEAVY_GLYPH_SVG_BASE64": "not base64!"}, self.root)
        script = base64.b64encode(b"<svg><script>x</script></svg>").decode()
        with self.assertRaises(ValueError):
            fetch({"HEAVY_GLYPH_SVG_BASE64": script}, self.root)
        self.assertFalse((self.root / DESTINATION).exists())


if __name__ == "__main__":
    unittest.main()
