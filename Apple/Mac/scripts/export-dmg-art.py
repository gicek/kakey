#!/usr/bin/env python3
"""Export the DMG window background and mounted volume icon to design/dmg/ (checked in; run by
make icons; never edit the output by hand).

- background.png / background@2x.png: Kakey on the left, Applications on the right, and the
  encryption process in between: code digits flow into a lock and come out as ciphertext dots.
  Coordinates match WINDOW / ICON_* in dmg-settings.py.
- volume.icns: the volume icon once mounted. Takes this Mac's system removable disk icon,
  erases the download arrow in the middle and puts Kakey's lock logo in its place; volume.png
  is the same image as a 1024 px preview for review.

Requires Pillow (repo root .venv; see docs/DEVELOPMENT.md).
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[3]
LOGO = ROOT / "design/logo/kakey-logo-1024-transparent.png"
# The removable disk icon the system shows for a mounted DMG by default (same path on macOS 14-26).
SYSTEM_DISK_ICON = Path("/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/Removable.icns")
MONO_FONT = Path("/System/Library/Fonts/SFNSMono.ttf")

# Window content area and icon centers (points); dmg-settings.py reads the same values.
WINDOW = (700, 400)
ICON_APP = (150, 196)
ICON_APPLICATIONS = (550, 196)
ICON_SIZE = 128

# Brand colors from design/logo: shield blue and checkmark teal.
BLUE_LIGHT = (86, 122, 201)
BLUE_DARK = (40, 70, 140)
NAVY = (14, 26, 56)
CYAN = (46, 166, 207)
INK = (92, 104, 128)
SS = 2  # Supersampling factor; drawn large and scaled down for smooth edges


def vertical_gradient(size: tuple[int, int], top: tuple[int, ...], bottom: tuple[int, ...]) -> Image.Image:
    w, h = size
    column = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((w, h))


def draw_background(scale: int) -> Image.Image:
    k = scale * SS
    W, H = WINDOW[0] * k, WINDOW[1] * k
    cy = ICON_APP[1] * k
    cx = (ICON_APP[0] + ICON_APPLICATIONS[0]) // 2 * k

    img = vertical_gradient((W, H), (248, 249, 252, 255), (236, 240, 246, 255))

    # Soft blue glow behind the lock.
    # Blur only the mask and keep the color solid: blurring RGBA with transparent black directly grays the edges.
    glow_mask = Image.new("L", (W, H), 0)
    r = 120 * k
    ImageDraw.Draw(glow_mask).ellipse((cx - r, cy - r * 0.7, cx + r, cy + r * 0.7), fill=40)
    glow = Image.new("RGBA", (W, H), (*BLUE_LIGHT, 255))
    glow.putalpha(glow_mask.filter(ImageFilter.GaussianBlur(50 * k)))
    img.alpha_composite(glow)

    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    badge_r = 32 * k
    lane_start = (ICON_APP[0] + ICON_SIZE // 2 + 14) * k
    lane_end = (ICON_APPLICATIONS[0] - ICON_SIZE // 2 - 14) * k

    # Left: plain-text code digits, sharper closer to the lock.
    font = ImageFont.truetype(str(MONO_FONT), 16 * k)
    digits = "482913"
    left_span = cx - badge_r - 12 * k - lane_start
    step = left_span / len(digits)
    for i, ch in enumerate(digits):
        t = (i + 1) / len(digits)
        x = lane_start + step * i + step / 2
        d.text((x, cy), ch, font=font, anchor="mm", fill=(*INK, round(70 + 170 * t)))

    # Right: ciphertext dots, fainter closer to Applications, ending in an arrow.
    arrow_w = 9 * k
    right_start = cx + badge_r + 12 * k
    right_span = lane_end - arrow_w - 8 * k - right_start
    dots = 6
    step = right_span / dots
    for i in range(dots):
        t = i / (dots - 1)
        x = right_start + step * i + step / 2
        rr = 3.2 * k
        d.ellipse((x - rr, cy - rr, x + rr, cy + rr), fill=(*CYAN, round(235 - 120 * t)))
    ax = lane_end - arrow_w
    half = 7 * k
    d.line([(ax, cy - half), (ax + arrow_w, cy), (ax, cy + half)], fill=(*CYAN, 130), width=round(2.4 * k), joint="curve")

    # Middle: white circular badge + padlock.
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        (cx - badge_r, cy - badge_r + 3 * k, cx + badge_r, cy + badge_r + 3 * k), fill=(30, 45, 80, 60)
    )
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(7 * k)))
    d.ellipse((cx - badge_r, cy - badge_r, cx + badge_r, cy + badge_r), fill=(255, 255, 255, 255),
              outline=(214, 222, 236, 255), width=max(1, round(1 * k)))

    # Padlock: shackle + gradient body + keyhole.
    body_w, body_h = 26 * k, 20 * k
    bx0, by0 = cx - body_w // 2, cy - 4 * k
    shackle_w = 16 * k
    sw = round(3.6 * k)
    d.arc((cx - shackle_w // 2, by0 - 13 * k, cx + shackle_w // 2, by0 + 6 * k), 180, 360, fill=(132, 142, 160, 255), width=sw)
    d.line([(cx - shackle_w // 2 + sw // 2, by0 - 3 * k), (cx - shackle_w // 2 + sw // 2, by0 + 1 * k)], fill=(132, 142, 160, 255), width=sw)
    d.line([(cx + shackle_w // 2 - sw // 2, by0 - 3 * k), (cx + shackle_w // 2 - sw // 2, by0 + 1 * k)], fill=(132, 142, 160, 255), width=sw)
    img.alpha_composite(layer)

    body = vertical_gradient((body_w, body_h), (*BLUE_LIGHT, 255), (*BLUE_DARK, 255))
    mask = Image.new("L", (body_w, body_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body_w - 1, body_h - 1), radius=5 * k, fill=255)
    img.paste(body, (bx0, by0), mask)
    kd = ImageDraw.Draw(img)
    kr = 3.2 * k
    kcy = by0 + 8 * k
    kd.ellipse((cx - kr, kcy - kr, cx + kr, kcy + kr), fill=(*NAVY, 255))
    kd.polygon([(cx - 1.6 * k, kcy), (cx + 1.6 * k, kcy), (cx + 2.2 * k, kcy + 7 * k), (cx - 2.2 * k, kcy + 7 * k)], fill=(*NAVY, 255))

    return img.resize((WINDOW[0] * scale, WINDOW[1] * scale), Image.LANCZOS).convert("RGB")


def render_icns(icns: Path, size: int) -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "icon.png"
        subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size), str(icns), "--out", str(out)],
                       check=True, capture_output=True)
        return Image.open(out).convert("RGBA")


def draw_volume_icon(out_dir: Path) -> None:
    if not SYSTEM_DISK_ICON.is_file():
        sys.exit(f"System disk icon not found: {SYSTEM_DISK_ICON}")
    disk = render_icns(SYSTEM_DISK_ICON, 1024)

    # Erase the download arrow: redraw each row of the arrow area by linearly interpolating the clean disk pixels on either side (the
    # disk surface has only a very faint horizontal gradient).
    x0, x1, y0, y1 = 330, 694, 262, 660
    px = disk.load()
    for y in range(y0, y1):
        left, right = px[x0, y], px[x1, y]
        for x in range(x0 + 1, x1):
            t = (x - x0) / (x1 - x0)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(left, right))

    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    target_h = 500
    logo = logo.resize((round(logo.width * target_h / logo.height), target_h), Image.LANCZOS)
    pos = ((1024 - logo.width) // 2, 452 - target_h // 2)

    shadow = Image.new("RGBA", disk.size, (0, 0, 0, 0))
    alpha = Image.new("L", disk.size, 0)
    alpha.paste(logo.getchannel("A"), pos)
    shadow.putalpha(ImageChops.multiply(alpha.filter(ImageFilter.GaussianBlur(14)), Image.new("L", disk.size, 70)))
    disk.alpha_composite(shadow.transform(disk.size, Image.AFFINE, (1, 0, 0, 0, 1, -10)))
    disk.alpha_composite(logo, pos)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "volume.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            disk.resize((base, base), Image.LANCZOS).save(iconset / f"icon_{base}x{base}.png")
            disk.resize((base * 2, base * 2), Image.LANCZOS).save(iconset / f"icon_{base}x{base}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out_dir / "volume.icns")], check=True)
    disk.save(out_dir / "volume.png")


def main() -> None:
    out_dir = ROOT / "design/dmg"
    out_dir.mkdir(parents=True, exist_ok=True)
    draw_background(1).save(out_dir / "background.png")
    draw_background(2).save(out_dir / "background@2x.png")
    draw_volume_icon(out_dir)
    print(f"DMG background and volume icon -> {out_dir.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
