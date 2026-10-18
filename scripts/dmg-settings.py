# dmgbuild settings for Tern's install window: Tern on the left, Applications on the right, the arrow and caption
# from dmg-background.swift behind them, and no toolbar, sidebar or status bar. release.sh runs
#   dmgbuild -s scripts/dmg-settings.py -D app=<Tern.app> -D background=<tiff> -D icon=<icns> Tern <out.dmg>
# Icon positions are icon centres in window points; keep them in step with dmg-background.swift.

import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]
icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
window_rect = ((240, 160), (600, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (160, 152),
    "Applications": (440, 152),
}
