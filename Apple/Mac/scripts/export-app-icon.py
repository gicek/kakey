#!/usr/bin/env python3
"""Export the macOS app icon and menu bar template image from the logo masters in design/logo/.

- AppIcon: macOS does not mask app icons, so the icon must carry its own plate. Following
  Apple's icon grid, the full-bleed kakey-logo-1024-background.png is scaled to 824x824,
  clipped to a continuous-corner (squircle) plate centered on a 1024 canvas, given a soft
  drop shadow, and exported at every AppIcon.appiconset size.
- Menu bar template image: kakey-logo-1024-menubar.svg goes into the imageset as is and is
  rendered as a vector by the system.
Requires Pillow (repo root .venv): .venv/bin/python Apple/Mac/scripts/export-app-icon.py
"""
import shutil
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO / "design/logo/kakey-logo-1024-background.png"
ASSETS = REPO / "Apple/Mac/Resources/Assets.xcassets"
OUTPUT = ASSETS / "AppIcon.appiconset"
MENU_BAR_SOURCE = REPO / "design/logo/kakey-logo-1024-menubar.svg"
MENU_BAR_OUTPUT = ASSETS / "Kakey-menubar-template.imageset/Kakey-menubar-template.svg"
SIZE = 1024
PLATE_ORIGIN, PLATE_SIZE, CORNER_RADIUS = 100, 824, 185.4
SUPERSAMPLE = 4
# File name -> pixel edge length, matching Contents.json
SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def cubic(p0, p1, p2, p3, steps=24):
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        yield (u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
               u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1])


def squircle(x0, y0, x1, y1, r):
    """Apple continuous-corner rectangle (same cubic Bezier coefficients as UIBezierPath rounded
    corners); returns the polygon vertices."""
    a, b, c, d, e, f, g = (k * r for k in (1.52866483, 1.08849323, 0.86840701, 0.63149399, 0.07491100, 0.37282401, 0.16906001))
    # Clockwise: top right, bottom right, bottom left, top left; three cubic Bezier segments per corner.
    corners = [
        [((x1 - a, y0), (x1 - b, y0), (x1 - c, y0), (x1 - d, y0 + e)),
         ((x1 - d, y0 + e), (x1 - f, y0 + g), (x1 - g, y0 + f), (x1 - e, y0 + d)),
         ((x1 - e, y0 + d), (x1, y0 + c), (x1, y0 + b), (x1, y0 + a))],
        [((x1, y1 - a), (x1, y1 - b), (x1, y1 - c), (x1 - e, y1 - d)),
         ((x1 - e, y1 - d), (x1 - g, y1 - f), (x1 - f, y1 - g), (x1 - d, y1 - e)),
         ((x1 - d, y1 - e), (x1 - c, y1), (x1 - b, y1), (x1 - a, y1))],
        [((x0 + a, y1), (x0 + b, y1), (x0 + c, y1), (x0 + d, y1 - e)),
         ((x0 + d, y1 - e), (x0 + f, y1 - g), (x0 + g, y1 - f), (x0 + e, y1 - d)),
         ((x0 + e, y1 - d), (x0, y1 - c), (x0, y1 - b), (x0, y1 - a))],
        [((x0, y0 + a), (x0, y0 + b), (x0, y0 + c), (x0 + e, y0 + d)),
         ((x0 + e, y0 + d), (x0 + g, y0 + f), (x0 + f, y0 + g), (x0 + d, y0 + e)),
         ((x0 + d, y0 + e), (x0 + c, y0), (x0 + b, y0), (x0 + a, y0))],
    ]
    points = []
    for corner in corners:
        points.append(corner[0][0])
        for segment in corner:
            points.extend(cubic(*segment))
    return points


big = SIZE * SUPERSAMPLE
mask = Image.new("L", (big, big), 0)
s = SUPERSAMPLE
ImageDraw.Draw(mask).polygon(
    squircle(PLATE_ORIGIN * s, PLATE_ORIGIN * s, (PLATE_ORIGIN + PLATE_SIZE) * s, (PLATE_ORIGIN + PLATE_SIZE) * s, CORNER_RADIUS * s),
    fill=255,
)
mask = mask.resize((SIZE, SIZE), Image.LANCZOS)

art = Image.open(SOURCE).convert("RGB").resize((PLATE_SIZE, PLATE_SIZE), Image.LANCZOS)
plate = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
plate.paste(art, (PLATE_ORIGIN, PLATE_ORIGIN))
plate.putalpha(mask)

# Shadow: plate shape shifted down 10, Gaussian blur, 30% black.
shadow_alpha = ImageChops.offset(mask, 0, 10).filter(ImageFilter.GaussianBlur(12)).point(lambda v: v * 3 // 10)
icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.putalpha(shadow_alpha)
icon.alpha_composite(plate)

for name, px in SIZES.items():
    out = icon if px == SIZE else icon.resize((px, px), Image.LANCZOS)
    out.save(OUTPUT / name, optimize=True)
print(f"wrote {len(SIZES)} icons to {OUTPUT.relative_to(REPO)}")

shutil.copyfile(MENU_BAR_SOURCE, MENU_BAR_OUTPUT)
print(f"wrote {MENU_BAR_OUTPUT.relative_to(REPO)}")
