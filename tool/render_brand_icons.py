"""Render the app icon and splash images from assets/branding/app_icon.svg.

The SVG is the only source. It has two layers: `background` (blue ground and
parking bay lines) and `mark` (scooter, location pin, ripple). Every raster
variant is the same artwork with a different layer set and viewBox, so the
icon, the adaptive layers and the splash mark always line up.

The mark is drawn inside a circle of radius MARK_RADIUS around the canvas
center. That circle is the Android adaptive safe zone (66 of the 72 dp that
stay visible) once the 1024 canvas is mapped onto the visible 72 dp.

Requires cairosvg and Pillow (`python3 -m pip install cairosvg pillow`). After
running this, regenerate the platform files:

    dart run flutter_launcher_icons
    dart run flutter_native_splash:create
"""
import io
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/branding/app_icon.svg"
OUT = ROOT / "assets/branding/png"
WEB = ROOT / "web"

SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)

CANVAS = 1024
CENTER = CANVAS / 2
MARK_RADIUS = 469  # 66/72 of the half canvas.
# Dark splash: the mark sits on this blue disc over the asphalt background.
SIGN_BLUE = "#1F5FA8"


def _tree():
    return ET.parse(SOURCE)


def _layer(root, name):
    for group in root.iter(f"{{{SVG_NS}}}g"):
        if group.get("id") == name:
            return group
    raise ValueError(f"{SOURCE} has no layer {name!r}")


def _without(root, name):
    layer = _layer(root, name)
    for parent in root.iter():
        if layer in list(parent):
            parent.remove(layer)
            return
    raise ValueError(f"layer {name!r} not found")


def _view(root, size):
    """Show a `size`-unit square centered on the canvas."""
    origin = CENTER - size / 2
    root.set("viewBox", f"{origin:g} {origin:g} {size:g} {size:g}")


def _leaves(root):
    """Drawn elements of the mark in paint order."""
    return [e for e in _layer(root, "mark").iter() if len(e) == 0]


def _remove(root, doomed):
    for parent in list(root.iter()):
        for child in list(parent):
            if child in doomed:
                parent.remove(child)


def _whiten(root):
    for element in _layer(root, "mark").iter():
        for attribute in ("fill", "stroke"):
            value = element.get(attribute)
            if value and value != "none":
                element.set(attribute, "#FFFFFF")


def _monochrome(view, pixels):
    """One color. data-mono="skip" parts are left out; a data-mono="cut"
    part erases what was painted before it, so overlapping shapes stay apart.
    """
    def part(keep):
        root = _variant(drop=["background"], view=view)
        leaves = _leaves(root)
        _remove(root, [e for i, e in enumerate(leaves) if not keep(i, e)])
        _whiten(root)
        return _render(root, pixels)

    leaves = _leaves(_variant(drop=["background"], view=view))
    cuts = [i for i, e in enumerate(leaves) if e.get("data-mono") == "cut"]
    split = cuts[-1] if cuts else len(leaves)
    plain = lambda e: e.get("data-mono") not in ("skip", "cut")
    below = part(lambda i, e: i < split and plain(e))
    cut = part(lambda i, e: e.get("data-mono") == "cut").getchannel("A")
    above = part(lambda i, e: i > split and plain(e))
    alpha = ImageChops.multiply(below.getchannel("A"), ImageChops.invert(cut))
    below.putalpha(alpha)
    return Image.alpha_composite(below, above)


def _render(root, pixels):
    data = ET.tostring(root, encoding="unicode")
    png = cairosvg.svg2png(
        bytestring=data.encode(), output_width=pixels, output_height=pixels
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def _variant(*, drop=(), view=CANVAS, disc=None):
    root = _tree().getroot()
    for name in drop:
        _without(root, name)
    if disc:
        circle = ET.Element(
            f"{{{SVG_NS}}}circle",
            {"cx": f"{CENTER:g}", "cy": f"{CENTER:g}", "r": f"{disc:g}",
             "fill": SIGN_BLUE},
        )
        root.insert(0, circle)
    _view(root, view)
    return root


def _opaque(image):
    flat = Image.new("RGB", image.size, "#FFFFFF")
    flat.paste(image, mask=image.getchannel("A"))
    return flat


def _view_for(radius_px, pixels):
    """viewBox size that draws MARK_RADIUS as `radius_px` on `pixels`."""
    return MARK_RADIUS * pixels / radius_px


def outputs():
    """File name → (image, keep alpha)."""
    # Adaptive icon: 108 dp canvas, the 1024 artwork covers the visible 72 dp.
    adaptive = CANVAS * 108 / 72
    # Splash sizes follow Android 12: 288 dp image with the mark in a 192 dp
    # circle; with an icon background, 240 dp with a 160 dp visible circle.
    # Images are 4x (1 dp = 4 px). The dark mark keeps 10 dp clear of its disc.
    light = _view_for(384, 1152)
    dark_radius = 70 * 4
    return {
        "app_icon.png": (_opaque(_render(_variant(), 1024)), False),
        "adaptive_background.png": (
            _render(_variant(drop=["mark"], view=adaptive), 1024), False),
        "adaptive_foreground.png": (
            _render(_variant(drop=["background"], view=adaptive), 1024), True),
        "adaptive_monochrome.png": (_monochrome(adaptive, 1024), True),
        "splash_mark.png": (
            _render(_variant(drop=["background"], view=light), 1152), True),
        "splash_mark_dark.png": (
            _render(_variant(
                drop=["background"], view=_view_for(dark_radius, 1152),
                disc=MARK_RADIUS * 320 / dark_radius), 1152), True),
        "splash_android12_dark.png": (
            _render(_variant(
                drop=["background"], view=_view_for(dark_radius, 960)), 960),
            True),
    }


def web_outputs():
    """The web manifest wants maskable icons with the mark inside 40%."""
    maskable = _view_for(0.4 * 512, 512)
    full = _render(_variant(), 512)
    mask = _render(_variant(view=maskable), 512)
    return {
        "favicon.png": _opaque(full.resize((32, 32), Image.LANCZOS)),
        "icons/Icon-192.png": _opaque(full.resize((192, 192), Image.LANCZOS)),
        "icons/Icon-512.png": _opaque(full),
        "icons/Icon-maskable-192.png": _opaque(
            mask.resize((192, 192), Image.LANCZOS)),
        "icons/Icon-maskable-512.png": _opaque(mask),
    }


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (image, alpha) in outputs().items():
        (image if alpha else image.convert("RGB")).save(
            OUT / name, optimize=True)
    for name, image in web_outputs().items():
        image.save(WEB / name, optimize=True)


if __name__ == "__main__":
    main()
