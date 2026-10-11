#!/bin/bash
# Packs mac/build/ScreenVoicer.app into ScreenVoicer-macOS.dmg for first installs: the app, an «Applications»
# shortcut and the branded background (mac/Resources/dmg-background*.png, drawn from installer/art.html).
# The updater keeps using ScreenVoicer-macOS.zip. Run after build.sh.
#
#   mac/scripts/dmg.sh
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$MAC_DIR/build"
APP="$OUT/ScreenVoicer.app"
DMG="$OUT/ScreenVoicer-macOS.dmg"
[ -d "$APP" ] || { echo "Build the app first (mac/scripts/build.sh)." >&2; exit 1; }

# dmgbuild writes the Finder layout (.DS_Store) itself, so no Finder scripting is needed on a headless runner
VENV="$OUT/dmg-venv"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6.1,<2"

# one TIFF with the 1x and 2x pictures: sharp on Retina screens too
tiffutil -cathidpicheck "$MAC_DIR/Resources/dmg-background.png" "$MAC_DIR/Resources/dmg-background@2x.png" \
  -out "$OUT/dmg-background.tiff"

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$MAC_DIR/scripts/dmg-settings.py" -D app="$APP" -D bg="$OUT/dmg-background.tiff" \
  "ScreenVoicer" "$DMG"
hdiutil verify "$DMG"
rm -rf "$VENV" "$OUT/dmg-background.tiff"
echo "▸ $DMG ($(du -h "$DMG" | cut -f1))"
