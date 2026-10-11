# dmgbuild settings for ScreenVoicer-macOS.dmg. mac/scripts/dmg.sh passes the app and the background with -D.
# The window: the app on the left, an «Applications» shortcut on the right, the branded background between them
# (an orange arrow and the one hint first-time users need). Icon positions match installer/art.html.
import os.path

application = defines['app']  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')  # the mounted volume's icon
background = defines['bg']  # noqa: F821

format = 'UDZO'
window_rect = ((200, 140), (660, 448))  # 420 of background + the 28-point title bar
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    appname: (170, 206),
    'Applications': (490, 206),
}
