#!/usr/bin/env python3
"""Export the iOS app icon and in-app brand mark from the logo masters in design/logo/.

- AppIcon: kakey-logo-1024-background.png is already a full-bleed square without rounded corners (the system applies the mask);
  iOS requires an opaque icon, so only the alpha channel is dropped.
- BrandMark: kakey-logo-1024-transparent.png (transparent, no backplate), used on the lock screen, onboarding, and privacy cover.
Requires Pillow (repo-root .venv): .venv/bin/python Apple/iOS/scripts/export-app-icon.py
"""
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[3]
LOGO = REPO / "design/logo"
ASSETS = REPO / "Apple/iOS/Resources/Assets.xcassets"

app_icon = ASSETS / "AppIcon.appiconset/app-icon-1024.png"
Image.open(LOGO / "kakey-logo-1024-background.png").convert("RGB").save(app_icon, optimize=True)

brand_mark = ASSETS / "BrandMark.imageset/brand-mark.png"
Image.open(LOGO / "kakey-logo-1024-transparent.png").convert("RGBA").save(brand_mark, optimize=True)

for path in (app_icon, brand_mark):
    print(f"wrote {path.relative_to(REPO)}")
