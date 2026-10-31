"""Write the licensed heavy-bike badge silhouette into the ignored asset folder.

The IconScout glyph (Enhanced licence) may ship inside the app but must never
be committed to this public repository. Sources, in order:

1. HEAVY_GLYPH_SVG_BASE64: the SVG, base64-encoded (a CI secret).
2. HEAVY_GLYPH_SVG_PATH, else ~/.config/motorcycle-parking/heavy_glyph.svg:
   a file on the developer's machine.

With neither, nothing is written and the app draws its fallback helmet; the
build still succeeds (forks, pull requests, the admin site).
"""
import argparse
import base64
import binascii
import os
from pathlib import Path

DESTINATION = Path("assets/private/heavy_glyph.svg")
DEFAULT_LOCAL = Path("~/.config/motorcycle-parking/heavy_glyph.svg")
MAX_BYTES = 64 * 1024


def read_source(env: dict[str, str]) -> bytes | None:
    encoded = env.get("HEAVY_GLYPH_SVG_BASE64", "").strip()
    if encoded:
        try:
            return base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ValueError("HEAVY_GLYPH_SVG_BASE64 不是有效的 base64") from error
    path = Path(env.get("HEAVY_GLYPH_SVG_PATH") or DEFAULT_LOCAL).expanduser()
    if path.is_file():
        return path.read_bytes()
    return None


def validate(svg: bytes) -> None:
    if len(svg) > MAX_BYTES:
        raise ValueError("重機剪影檔案過大")
    text = svg.decode("utf-8")
    if "<svg" not in text or "<script" in text.lower():
        raise ValueError("重機剪影不是單純的 SVG")


def fetch(env: dict[str, str], root: Path) -> bool:
    """Writes the glyph under [root]; False when no source is configured."""
    svg = read_source(env)
    if svg is None:
        return False
    validate(svg)
    destination = root / DESTINATION
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(svg)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        written = fetch(dict(os.environ), root)
    except (ValueError, OSError, UnicodeDecodeError) as error:
        parser.exit(1, f"無法寫入重機剪影：{error}\n")
    if written:
        print("已寫入重機剪影（不進版控）。")
    else:
        print("沒有重機剪影來源，App 會改用替代圖示。")


if __name__ == "__main__":
    main()
