"""Check entrypoint isolation and admin-only Hosting preparation."""
from pathlib import Path
import re
import tempfile
import unittest

import json

from prepare_admin_web import ROOT, add_react_pending, prepare


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

    def _react_site(self, root, bundle="app"):
        (root / "build/admin").mkdir(parents=True)
        (root / "build/admin/main.dart.js").write_text("compiled admin")
        (root / "build/admin/index.html").write_text("flutter")
        dist = root / "admin_web/react/dist"
        (dist / "assets").mkdir(parents=True)
        (dist / "index.html").write_text("react")
        (dist / "assets/index.js").write_text(bundle)
        (dist / "assets/index.js.map").write_text("map")

    def test_react_page_goes_under_pending_without_source_maps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._react_site(root)
            add_react_pending(root)
            self.assertEqual((root / "build/admin/index.html").read_text(), "flutter")
            self.assertEqual((root / "build/admin/pending/index.html").read_text(), "react")
            self.assertTrue((root / "build/admin/pending/assets/index.js").is_file())
            self.assertFalse((root / "build/admin/pending/assets/index.js.map").exists())

    def test_react_page_refuses_sample_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._react_site(root, bundle="MOTOPARK_ADMIN_FIXTURE_DATA")
            with self.assertRaises(ValueError):
                add_react_pending(root)

    def test_react_page_requires_its_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build/admin").mkdir(parents=True)
            (root / "build/admin/main.dart.js").write_text("compiled admin")
            with self.assertRaises(ValueError):
                add_react_pending(root)

    def test_pending_routes_to_react_before_the_flutter_catch_all(self):
        hosting = json.loads((ROOT / "firebase.json").read_text())["hosting"]
        admin = next(site for site in hosting if site["target"] == "admin-staging")
        rewrites = [(rule["source"], rule["destination"]) for rule in admin["rewrites"]]
        self.assertEqual(
            rewrites,
            [
                ("/pending", "/pending/index.html"),
                ("/pending/**", "/pending/index.html"),
                ("**", "/index.html"),
            ],
        )

    def test_preparation_requires_a_compiled_build(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                prepare(Path(directory))


if __name__ == "__main__":
    unittest.main()
