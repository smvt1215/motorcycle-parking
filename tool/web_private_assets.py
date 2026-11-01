"""Keep licensed private assets (assets/private/) out of web builds.

The IconScout heavy-bike glyph may ship inside the store apps but must never
be served from a public web build. Flutter bundles every declared asset, so
a developer machine that fetched the glyph would otherwise copy it into
build/web or build/admin.

    python3 tool/web_private_assets.py strip build/web   # remove, then check
    python3 tool/web_private_assets.py check build/web   # fail if present
"""
import argparse
from pathlib import Path

# The Flutter web output keeps an asset at assets/<declared path>.
PRIVATE_DIR = Path("assets/assets/private")
FORBIDDEN_NAME = "heavy_glyph"


def offending(output: Path) -> list[Path]:
    """Every private asset file, and anything named like the glyph."""
    found = set()
    private = output / PRIVATE_DIR
    if private.is_dir():
        found.update(p for p in private.rglob("*") if p.is_file() and p.name != ".gitkeep")
    found.update(p for p in output.rglob(f"*{FORBIDDEN_NAME}*") if p.is_file())
    return sorted(found)


def strip(output: Path) -> list[Path]:
    removed = offending(output)
    for path in removed:
        path.unlink()
    return removed


def check(output: Path) -> None:
    left = offending(output)
    if left:
        names = ", ".join(str(p.relative_to(output)) for p in left)
        raise ValueError(f"web 產物含有授權私有素材：{names}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["strip", "check"])
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if not args.output.is_dir():
        parser.exit(1, f"找不到 web 產物資料夾：{args.output}\n")
    if args.action == "strip":
        for path in strip(args.output):
            print(f"已移除 {path.relative_to(args.output)}")
    try:
        check(args.output)
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
