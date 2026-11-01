import tempfile
import unittest
from pathlib import Path

from prepare_admin_web import prepare
from web_private_assets import check, strip


class WebPrivateAssetsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def build(self, name: str) -> Path:
        output = self.root / name
        private = output / "assets/assets/private"
        private.mkdir(parents=True)
        (private / "heavy_glyph.svg").write_text("<svg/>")
        (private / ".gitkeep").write_text("")
        (output / "main.dart.js").write_text("compiled")
        return output

    def test_check_fails_when_the_glyph_is_bundled(self) -> None:
        output = self.build("web")
        with self.assertRaises(ValueError):
            check(output)

    def test_strip_removes_private_files_only(self) -> None:
        output = self.build("web")
        (output / "assets/other.txt").write_text("public")
        removed = strip(output)
        self.assertEqual([p.name for p in removed], ["heavy_glyph.svg"])
        check(output)
        self.assertTrue((output / "assets/other.txt").exists())
        self.assertTrue((output / "main.dart.js").exists())

    def test_admin_preparation_strips_the_glyph(self) -> None:
        output = self.build("build/admin")
        (self.root / "admin_web").mkdir()
        (self.root / "admin_web/index.html").write_text("admin")
        prepare(self.root)
        self.assertFalse((output / "assets/assets/private/heavy_glyph.svg").exists())
        check(output)


if __name__ == "__main__":
    unittest.main()
