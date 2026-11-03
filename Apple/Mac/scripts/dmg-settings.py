# dmgbuild settings (invoked by make-dmg.sh; not run on its own).
# dmgbuild writes .DS_Store directly instead of going through Finder AppleScript: no automation permission needed, and the result
# is reproducible.
# Window size and icon coordinates must match WINDOW / ICON_* in export-dmg-art.py, or the icons drift off their spots on the
# background.
# ruff: noqa: F821  # `defines` is injected by dmgbuild

import os.path

app = defines["app"]  # Path to Kakey.app
art = defines["art"]  # design/dmg (output of export-dmg-art.py)
app_name = os.path.basename(app)

format = "UDZO"  # zlib; opens directly on every macOS version
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon once mounted: the system removable disk icon plus the Kakey logo.
icon = os.path.join(art, "volume.icns")
# dmgbuild automatically combines background@2x.png from the same folder into a multi-resolution TIFF.
background = os.path.join(art, "background.png")

# Finder's window height includes the title bar (about 32 pt with the toolbar hidden); only the content
# area shows the 400 pt background.
window_rect = ((200, 160), (700, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (150, 196),
    "Applications": (550, 196),
}
hide_extensions = [app_name]
