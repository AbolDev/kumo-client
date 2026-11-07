"""Draws the app icons the user can pick in Settings and writes them where each platform wants them.

    python tools/make_app_icons.py

Needs cairosvg and Pillow. Writes:
  assets/app_icons/<id>.png            the picture shown in the Settings picker
  assets/app_icons/<id>.ico            the window, taskbar and tray icon on Windows
  android/.../mipmap-*/ic_launcher_<id>*.webp  and  mipmap-anydpi-v26/ic_launcher_<id>.xml
  windows/runner/resources/app_icon.ico        the default icon (DEFAULT below)

The "classic" icon is the one Kumo had before; its files are kept as they were.
"""

import io
import shutil
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
ASSETS = ROOT / "assets/app_icons"
DEFAULT = "teal_night"

# The cloud, cut into facets that catch the light from the top left (a 100 x 100 drawing).
SILHOUETTE = "24,70 23,62 27,53 35,48 40,40 48,32 58,32 66,38 69,47 76,50 80,58 78,67 72,71"
LIGHT = [
    ("24,70 23,62 40,58", 0.45), ("23,62 27,53 40,58", 0.65), ("27,53 35,48 40,58", 0.8),
    ("35,48 40,40 55,50", 0.95), ("35,48 55,50 40,58", 0.7), ("40,40 48,32 55,50", 0.9),
    ("48,32 58,32 55,50", 0.75), ("58,32 66,38 55,50", 0.5), ("66,38 69,47 55,50", 0.3),
    ("69,47 62,62 55,50", 0.15), ("69,47 76,50 62,62", 0.4), ("76,50 80,58 62,62", 0.15),
    ("40,58 55,50 62,62", 0.6), ("24,70 40,58 62,62", 0.35),
]
SHADE = [("80,58 78,67 62,62", 0.1), ("78,67 72,71 62,62", 0.2), ("24,70 62,62 72,71", 0.12)]

SPARKLE = '<path d="M76 24 L77.3 28.7 L82 30 L77.3 31.3 L76 36 L74.7 31.3 L70 30 L74.7 28.7 Z" fill="#d6fff7"/>'

# id: (background: a colour or two for a diagonal gradient, cloud colour, strength of the
# facets, extra drawing on top of the cloud)
ICONS = {
    # In the app's own teal (the theme's seed colour, 0E9F8E).
    "teal": (("#16302c", "#0b1312"), "#0e9f8e", 1.0, ""),
    "teal_light": (("#f4fbf8",), "#006a60", 0.6, ""),
    "teal_solid": (("#14b8a3", "#006a60"), "#9ff2e2", 1.0, ""),
    "teal_blue": (("#00201c",), "#0e9f8e", 1.0,
                  '<g fill="#7fb4e6" fill-opacity="0.75"><polygon points="58,32 66,38 55,50"/>'
                  '<polygon points="66,38 69,47 55,50"/><polygon points="69,47 76,50 62,62"/></g>'),
    "mint": (("#b8f5ea", "#74f8e5"), "#00504a", 0.5, ""),
    "teal_night": (("#003731", "#001a17"), "#14b8a3", 1.0, SPARKLE),
    # The first set, in other colours.
    "blue": (("#0d2a6b", "#071433"), "#6f95f2", 1.0, ""),
    "sunset": (("#2a0f3d",), "#ff6a7a", 1.0,
               '<polygon points="35,48 40,40 55,50" fill="#ffd27a" fill-opacity="0.6"/>'
               '<polygon points="40,40 48,32 55,50" fill="#ffd27a" fill-opacity="0.5"/>'),
    "emerald": (("#04241f",), "#17b890", 1.0, ""),
    "vivid": (("#5b3cf0", "#ff5f9e"), "#cfc8ff", 1.0, ""),
    "navy": (("#eef1fb",), "#1b2a6b", 0.55, ""),
    "gold": (("#0b0a09",), "#b8892e", 0.8, ""),
}


def cloud(color, strength, extra):
    light = "".join(f'<polygon points="{p}" fill-opacity="{o}"/>' for p, o in LIGHT)
    shade = "".join(f'<polygon points="{p}" fill-opacity="{o}"/>' for p, o in SHADE)
    return (f'<polygon points="{SILHOUETTE}" fill="{color}"/>'
            f'<g opacity="{strength}"><g fill="#fff">{light}</g><g fill="#000">{shade}</g></g>{extra}')


def background_fill(bg):
    if len(bg) == 1:
        return "", bg[0]
    grad = (f'<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bg[0]}"/>'
            f'<stop offset="1" stop-color="{bg[1]}"/></linearGradient>')
    return grad, "url(#bg)"


def svg_full(icon_id):
    """The whole icon on its rounded square (Windows, the Settings picker, old Androids)."""
    bg, color, strength, extra = ICONS[icon_id]
    defs, fill = background_fill(bg)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="4 4 92 92"><defs>{defs}</defs>'
            f'<rect x="4" y="4" width="92" height="92" rx="22" fill="{fill}"/>{cloud(color, strength, extra)}</svg>')


# Android's adaptive icon is 108 units with the middle 72 showing; the rounded square of the
# drawing (4..96) is placed on those 72 units, so the cloud keeps the same size.
ADAPTIVE = 'transform="translate(18 18) scale(0.7826) translate(-4 -4)"'


def svg_foreground(icon_id):
    _, color, strength, extra = ICONS[icon_id]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">'
            f'<g {ADAPTIVE}>{cloud(color, strength, extra)}</g></svg>')


def svg_background(icon_id):
    defs, fill = background_fill(ICONS[icon_id][0])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><defs>{defs}</defs>'
            f'<rect width="108" height="108" fill="{fill}"/></svg>')


def render(svg, size):
    # Every size is drawn four times larger and scaled down with a high-quality filter: the edges
    # between facets come out smooth, without the faint seams of drawing at the final size.
    big = size * 4
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=big, output_height=big)
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    return img.resize((size, size), Image.LANCZOS)


def save_webp(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "WEBP", lossless=True, quality=100, method=6)


DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
# Every size Windows asks for from 100% to 300% screen scale, so none is enlarged.
ICO_SIZES = [16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 96, 128, 256]


def write_ico(icon_id, path):
    # Every size is drawn on its own, so the small ones stay sharp.
    images = [render(svg_full(icon_id), s) for s in ICO_SIZES]
    images[-1].save(path, format="ICO", sizes=[(s, s) for s in ICO_SIZES], append_images=images[:-1])


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)

    # The icon Kumo had before stays available as "classic".
    win_ico = ROOT / "windows/runner/resources/app_icon.ico"
    if not (ASSETS / "classic.ico").exists():
        shutil.copyfile(win_ico, ASSETS / "classic.ico")
    if not (ASSETS / "classic.png").exists():
        Image.open(RES / "mipmap-xxxhdpi/ic_launcher.webp").convert("RGBA").save(ASSETS / "classic.png")

    for icon_id in ICONS:
        # Large enough for the picker on a phone with a dense screen.
        render(svg_full(icon_id), 384).save(ASSETS / f"{icon_id}.png", optimize=True)
        write_ico(icon_id, ASSETS / f"{icon_id}.ico")
        for name, scale in DENSITIES.items():
            d = RES / f"mipmap-{name}"
            save_webp(render(svg_foreground(icon_id), round(108 * scale)), d / f"ic_launcher_{icon_id}_fg.webp")
            save_webp(render(svg_background(icon_id), round(108 * scale)), d / f"ic_launcher_{icon_id}_bg.webp")
            save_webp(render(svg_full(icon_id), round(48 * scale)), d / f"ic_launcher_{icon_id}.webp")
        (RES / "mipmap-anydpi-v26" / f"ic_launcher_{icon_id}.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            f'    <background android:drawable="@mipmap/ic_launcher_{icon_id}_bg"/>\n'
            f'    <foreground android:drawable="@mipmap/ic_launcher_{icon_id}_fg"/>\n'
            '</adaptive-icon>\n', encoding="utf-8")

    # The cloud alone, without its square, for the app's header: the default icon's cloud on a
    # dark theme, the darker one of the light icon on a light theme.
    for name, icon_id in (("mark_dark", DEFAULT), ("mark_light", "teal_light")):
        _, color, strength, _ = ICONS[icon_id]
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="22 31 59 41">'
               f'{cloud(color, strength, "")}</svg>')
        png = cairosvg.svg2png(bytestring=svg.encode(), output_width=59 * 16, output_height=41 * 16)
        img = Image.open(io.BytesIO(png)).convert("RGBA").resize((59 * 4, 41 * 4), Image.LANCZOS)
        img.save(ASSETS / f"{name}.png", optimize=True)

    # The default icon for web pages (the landing page, the admin panel): vector and pixel
    # files, a favicon, and the cloud alone without its square.
    web = ROOT / "assets/brand"
    web.mkdir(parents=True, exist_ok=True)
    (web / "kumo-icon.svg").write_text(svg_full(DEFAULT), encoding="utf-8")
    for s in (1024, 512, 192, 180, 32):
        render(svg_full(DEFAULT), s).save(web / f"kumo-icon-{s}.png", optimize=True)
    fav = [render(svg_full(DEFAULT), s) for s in (16, 32, 48)]
    fav[-1].save(web / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)], append_images=fav[:-1])
    for name, icon_id in (("kumo-cloud-dark", DEFAULT), ("kumo-cloud-light", "teal_light")):
        _, color, strength, _ = ICONS[icon_id]
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="22 31 59 41">'
               f'{cloud(color, strength, "")}</svg>')
        (web / f"{name}.svg").write_text(svg, encoding="utf-8")

    shutil.copyfile(ASSETS / f"{DEFAULT}.ico", win_ico)
    print(f"{len(ICONS)} icons written; default: {DEFAULT}")


if __name__ == "__main__":
    main()
