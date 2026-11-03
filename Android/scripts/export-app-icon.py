#!/usr/bin/env python3
"""Export the Android adaptive icon from the logo masters in design/logo/ (never edit res/mipmap-* by hand).

- Foreground: kakey-logo-1024-transparent.png (transparent, no backplate), scaled as a whole to the central 72dp of the
  108dp canvas so the logo body (about 80% of the master) falls inside the 66dp safe zone.
- Monochrome layer (Android 13 themed icon): the same image shaped by luminance. The dark keyhole and badge outline are cut
  out, everything else is opaque white, and the system tints it.
- Background: res/drawable/ic_launcher_background.xml, using the same gradient as the full-bleed background master
  (#323232 -> #131313).
- The splash screen uses the foreground image directly (SplashScreen icon canvas 240dp, content within a 160dp circle).
Requires Pillow (repository root .venv): .venv/bin/python Android/scripts/export-app-icon.py
"""
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "design/logo/kakey-logo-1024-transparent.png"
RES = REPO / "Android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

logo = Image.open(SOURCE).convert("RGBA")


def monochrome(image: Image.Image) -> Image.Image:
    out = Image.new("RGBA", image.size, (255, 255, 255, 0))
    src, dst = image.load(), out.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = src[x, y]
            luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            if a and luminance > 0.16:
                dst[x, y] = (255, 255, 255, a)
    return out


mono = monochrome(logo)
for name, scale in DENSITIES.items():
    canvas_px = round(108 * scale)
    logo_px = round(72 * scale)
    for suffix, image in (("foreground", logo), ("monochrome", mono)):
        canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
        resized = image.resize((logo_px, logo_px), Image.LANCZOS)
        offset = (canvas_px - logo_px) // 2
        canvas.paste(resized, (offset, offset), resized)
        path = RES / f"mipmap-{name}" / f"ic_launcher_{suffix}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(path, optimize=True)
        print(f"wrote {path.relative_to(REPO)}")
