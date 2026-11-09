"""Apply admin-only Hosting metadata after building lib/main_admin.dart.

The mobile app's web/ files and build/web output remain independent.
With --react-pending, also place the React 待處理 page at /pending.
"""
from pathlib import Path
import shutil
import sys

from web_private_assets import check, strip


ROOT = Path(__file__).resolve().parent.parent
FIXTURE_MARKER = "MOTOPARK_ADMIN_FIXTURE_DATA"


def prepare(root=ROOT):
    output = root / "build/admin"
    if not (output / "main.dart.js").is_file():
        raise ValueError("Build the admin web entrypoint before preparing Hosting files")
    for source in (root / "admin_web").iterdir():
        if source.is_file():
            shutil.copyfile(source, output / source.name)
    # Licensed app-only art (assets/private/) never ships on the web.
    strip(output)
    check(output)


def add_react_pending(root=ROOT):
    """Copy admin_web/react/dist to build/admin/pending, without source maps."""
    output = root / "build/admin"
    if not (output / "main.dart.js").is_file():
        raise ValueError("Prepare the Flutter admin before adding the React page")
    source = root / "admin_web/react/dist"
    if not (source / "index.html").is_file():
        raise ValueError("Build admin_web/react before adding the React page")
    target = output / "pending"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("*.map"))
    for path in target.rglob("*"):
        if path.is_file() and FIXTURE_MARKER in path.read_text(errors="ignore"):
            raise ValueError(f"Sample data in the production build: {path}")
    strip(output)
    check(output)


if __name__ == "__main__":
    prepare()
    if "--react-pending" in sys.argv[1:]:
        add_react_pending()
