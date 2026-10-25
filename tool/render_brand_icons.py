"""Render the app icon, staging icon and splash images.

Source: assets/branding/app_icon_source.png, the supplied illustration with
its white margin removed and the area outside its rounded corners filled
with the neighbouring blue (1024 x 1024, no alpha). Create it once from the
original artwork with:

    python3 tool/render_brand_icons.py --from-original <artwork.png>

Then (and after any change here) render every derived image and regenerate
the platform files:

    python3 tool/render_brand_icons.py
    dart run flutter_launcher_icons
    dart run flutter_native_splash:create

The two generators rewrite AndroidManifest.xml (`${appIcon}`),
ios/Runner.xcodeproj/project.pbxproj (staging icon set) and
ios/Runner/Info.plist; restore those three files afterwards.

Requires Pillow and numpy (`python3 -m pip install pillow numpy`).
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "assets/branding"
SOURCE = BRANDING / "app_icon_source.png"
OUT = BRANDING / "png"
WEB = ROOT / "web"
STAGING_RES = ROOT / "android/app/src/staging/res"
STAGING_IOS = ROOT / "ios/Runner/Assets.xcassets/AppIconStaging.appiconset"
PRODUCTION_IOS = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"

SIZE = 1024
# The artwork's rounded corners, as a fraction of its side.
CORNER = 0.245
# Distance of the artwork's main subjects (pin, scooter) from the center, as
# a fraction of half the side. Decorative ground marks reach further.
SUBJECT = 0.95

# Original artwork (1254 px): the rounded square inside the white margin.
ORIGINAL_CROP = (40, 38, 1214, 1212)

TEST_YELLOW = (242, 194, 0)
TEST_INK = (28, 28, 28)

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


# Preparing the source from the original artwork ---------------------------

def _rounded_mask(size, inset=0):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - 1 - inset, size - 1 - inset),
        radius=size * CORNER - inset, fill=255)
    return mask


def _blur(values, radius):
    """Three box blurs, close to a Gaussian, on a float (H, W, C) array."""
    out = values
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0)] * out.ndim
            pad[axis] = (radius + 1, radius)
            summed = np.cumsum(np.pad(out, pad, mode="edge"), axis=axis)
            n = summed.shape[axis]
            hi = np.take(summed, range(2 * radius + 1, n), axis=axis)
            lo = np.take(summed, range(0, n - 2 * radius - 1), axis=axis)
            out = (hi - lo) / (2 * radius + 1)
    return out


def _fill_outside(image, known, ground_only=False):
    """Fill pixels where `known` is 0 from the surrounding known colors.
    With `ground_only`, white marks do not spread into the filled area."""
    rgb = np.asarray(image.convert("RGB"), dtype=np.float64)
    weight = (np.asarray(known, dtype=np.float64) / 255)[..., None]
    if ground_only:
        weight = weight * (rgb.min(axis=2, keepdims=True) < 170)
    filled = rgb * weight
    have = weight.copy()
    for radius in (3, 6, 12, 24, 48, 96, 192, 384):
        num = _blur(rgb * weight, radius)
        den = _blur(weight, radius)
        guess = num / np.maximum(den, 1e-6)
        mix = np.where((have < 1) & (den > 0.02), 1 - have, 0)
        filled = filled + guess * mix
        have = have + mix
    # Anything still out of reach takes the average known color.
    mean = (rgb * weight).sum(axis=(0, 1)) / max(weight.sum(), 1e-6)
    filled = filled + mean * (1 - have)
    return Image.fromarray(np.clip(filled, 0, 255).astype(np.uint8), "RGB")


def _corner_known():
    """Pixels kept from the artwork: all but the four corners outside its
    rounded outline, minus a thin anti-aliased rim along those corners."""
    known = np.asarray(_rounded_mask(SIZE), dtype=np.uint8).copy()
    core = np.asarray(_rounded_mask(SIZE, inset=12), dtype=np.uint8)
    corner = round(SIZE * CORNER) + 12
    for ys in (slice(0, corner), slice(SIZE - corner, SIZE)):
        for xs in (slice(0, corner), slice(SIZE - corner, SIZE)):
            known[ys, xs] = core[ys, xs]
    return Image.fromarray(known, "L")


def prepare(original):
    art = Image.open(original).convert("RGB").crop(ORIGINAL_CROP)
    art = art.resize((SIZE, SIZE), Image.LANCZOS)
    known = _corner_known()
    filled = _fill_outside(art, known, ground_only=True)
    # Keep the artwork's own pixels wherever they are known.
    filled.paste(art, mask=known)
    filled.save(SOURCE, optimize=True)


# Rendering ----------------------------------------------------------------

def _source():
    return Image.open(SOURCE).convert("RGB")


def _zoomed_out(image, scale, size):
    """`image` at `scale` of a `size` canvas, the rest filled from its edges."""
    inner = round(size * scale)
    offset = (size - inner) // 2
    canvas = Image.new("RGB", (size, size))
    canvas.paste(image.resize((inner, inner), Image.LANCZOS), (offset, offset))
    box = (offset + 2, offset + 2, offset + inner - 2, offset + inner - 2)
    known = Image.new("L", (size, size), 0)
    known.paste(255, box)
    filled = _fill_outside(canvas, known)
    filled.paste(canvas.crop(box), box[:2])
    return filled


def adaptive_scale():
    """Artwork size within the 108 dp layer so its subjects stay inside the
    66 dp safe circle."""
    return (66 / SUBJECT) / 108


def _letters(draw, box, ink):
    """Block letters T E S T centered in `box`, no font needed."""
    x0, y0, x1, y1 = box
    h = y1 - y0
    w, stroke, gap = h * 0.72, h * 0.2, h * 0.22
    x = x0 + ((x1 - x0) - (4 * w + 3 * gap)) / 2

    def rect(a, b, c, d):
        draw.rectangle((a, b, c, d), fill=ink)

    def T(x):
        rect(x, y0, x + w, y0 + stroke)
        rect(x + (w - stroke) / 2, y0, x + (w + stroke) / 2, y1)

    def E(x):
        rect(x, y0, x + stroke, y1)
        for top in (y0, y0 + (h - stroke) / 2, y1 - stroke):
            rect(x, top, x + w, top + stroke)

    def S(x):
        mid = y0 + (h - stroke) / 2
        for top in (y0, mid, y1 - stroke):
            rect(x, top, x + w, top + stroke)
        rect(x, y0, x + stroke, mid + stroke)
        rect(x + w - stroke, mid, x + w, y1)

    for letter in (T, E, S, T):
        letter(x)
        x += w + gap


def _test_band(image, top, bottom, left=0, right=None):
    """Yellow band reading TEST across rows [top, bottom]."""
    out = image.copy()
    draw = ImageDraw.Draw(out)
    right = image.width if right is None else right
    draw.rectangle((0, top, image.width, bottom), fill=TEST_YELLOW)
    pad = (bottom - top) * 0.22
    _letters(draw, (left, top + pad, right, bottom - pad), TEST_INK)
    return out


def _band_rows(visible_top, visible_size):
    """The band sits at 68–86% of the visible icon height."""
    return (round(visible_top + 0.68 * visible_size),
            round(visible_top + 0.86 * visible_size))


def _splash_mark(icon_dp=150, canvas_dp=288, px_per_dp=4):
    """Rounded artwork centered on a transparent 288 dp canvas. Android 12+
    shows the middle 192 dp circle; a 150 dp rounded square fits inside."""
    size, inner = canvas_dp * px_per_dp, icon_dp * px_per_dp
    art = _source().resize((inner, inner), Image.LANCZOS).convert("RGBA")
    art.putalpha(_rounded_mask(inner))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(art, ((size - inner) // 2, (size - inner) // 2))
    return canvas


def outputs():
    """Inputs for flutter_launcher_icons and flutter_native_splash. The
    artwork is one picture, so it is the adaptive background and the
    foreground stays empty."""
    return {
        "adaptive_background.png": _zoomed_out(
            _source(), adaptive_scale(), SIZE),
        "adaptive_foreground.png": Image.new(
            "RGBA", (SIZE, SIZE), (0, 0, 0, 0)),
        "splash_mark.png": _splash_mark(),
    }


def staging_icons():
    """Square staging icon (iOS, Android 7) and its adaptive layer."""
    square = _test_band(_source(), *_band_rows(0, SIZE))
    layer = _zoomed_out(_source(), adaptive_scale(), SIZE)
    visible, safe = SIZE * 72 / 108, SIZE * 66 / 108
    layer = _test_band(layer, *_band_rows((SIZE - visible) / 2, visible),
                       left=(SIZE - safe) / 2 + safe * 0.2,
                       right=(SIZE + safe) / 2 - safe * 0.2)
    return square, layer


STAGING_ADAPTIVE = """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/render_brand_icons.py. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_staging_background" />
    <foreground android:drawable="@android:color/transparent" />
</adaptive-icon>
"""


def write_staging():
    square, layer = staging_icons()
    for name, dp, image in (("ic_launcher_staging", 48, square),
                            ("ic_launcher_staging_background", 108, layer)):
        for bucket, factor in DENSITIES.items():
            folder = STAGING_RES / f"drawable-{bucket}"
            folder.mkdir(parents=True, exist_ok=True)
            px = round(dp * factor)
            image.resize((px, px), Image.LANCZOS).save(
                folder / f"{name}.png", optimize=True)
    adaptive = STAGING_RES / "drawable-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    # No monochrome layer, so themed icons keep the TEST band in color.
    (adaptive / "ic_launcher_staging.xml").write_text(STAGING_ADAPTIVE)
    # Same icon sizes as production.
    contents = json.loads((PRODUCTION_IOS / "Contents.json").read_text())
    for old in STAGING_IOS.glob("*.png"):
        old.unlink()
    for entry in contents["images"]:
        side = float(entry["size"].split("x")[0])
        px = round(side * float(entry["scale"].rstrip("x")))
        square.resize((px, px), Image.LANCZOS).save(
            STAGING_IOS / entry["filename"], optimize=True)
    (STAGING_IOS / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n")


def web_outputs():
    source = _source()
    # Maskable icons keep their subjects inside the 40% radius safe circle.
    maskable = _zoomed_out(source, 0.8 / SUBJECT, 512)
    return {
        "favicon.png": source.resize((32, 32), Image.LANCZOS),
        "icons/Icon-192.png": source.resize((192, 192), Image.LANCZOS),
        "icons/Icon-512.png": source.resize((512, 512), Image.LANCZOS),
        "icons/Icon-maskable-192.png": maskable.resize(
            (192, 192), Image.LANCZOS),
        "icons/Icon-maskable-512.png": maskable,
    }


def render():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, image in outputs().items():
        image.save(OUT / name, optimize=True)
    for name, image in web_outputs().items():
        image.save(WEB / name, optimize=True)
    write_staging()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--from-original", type=Path,
                        help="create app_icon_source.png from the artwork")
    args = parser.parse_args()
    if args.from_original:
        prepare(args.from_original)
    render()


if __name__ == "__main__":
    main()
