"""Check entrypoint isolation and admin-only Hosting preparation."""
from pathlib import Path
import re
import tempfile
import unittest

from prepare_admin_web import ROOT, prepare


class AdminWebTest(unittest.TestCase):
    def test_mobile_import_graph_never_reaches_admin(self):
        pending = [ROOT / "lib/main.dart"]
        visited = set()
        while pending:
            path = pending.pop().resolve()
            if path in visited:
                continue
            visited.add(path)
            self.assertNotEqual(path.name, "main_admin.dart")
            self.assertNotIn(ROOT / "lib/admin", path.parents)
            # Include conditional imports and exports, not only direct imports.
            for directive in re.findall(r"(?:import|export)\s+(.*?);", path.read_text(), re.S):
                for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive):
                    if uri.startswith("package:motorcycle_parking/"):
                        pending.append(ROOT / "lib" / uri.split("/", 1)[1])
                    elif ":" not in uri and uri.endswith(".dart"):
                        pending.append(path.parent / uri)

    def test_preparation_only_replaces_admin_hosting_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build/admin").mkdir(parents=True)
            (root / "build/web").mkdir()
            (root / "admin_web").mkdir()
            (root / "build/admin/main.dart.js").write_text("compiled admin")
            (root / "build/web/index.html").write_text("app")
            (root / "admin_web/index.html").write_text("admin noindex")
            prepare(root)
            self.assertEqual((root / "build/admin/index.html").read_text(), "admin noindex")
            self.assertEqual((root / "build/web/index.html").read_text(), "app")

    def test_preparation_requires_a_compiled_build(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                prepare(Path(directory))


if __name__ == "__main__":
    unittest.main()
