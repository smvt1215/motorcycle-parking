"""Apply admin-only Hosting metadata after building lib/main_admin.dart.

The mobile app's web/ files and build/web output remain independent.
"""
from pathlib import Path
import shutil

from web_private_assets import check, strip


ROOT = Path(__file__).resolve().parent.parent


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


if __name__ == "__main__":
    prepare()
