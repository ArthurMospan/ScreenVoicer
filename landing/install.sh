#!/bin/bash
# ScreenVoicer for Mac in one Terminal command:
#   curl -fsSL https://sv.mospan.com.ua/install.sh | bash
# Downloads the latest release, puts ScreenVoicer.app into Applications and starts it. A file fetched by curl is not
# quarantined, so macOS does not ask to allow an unknown developer (the app has no paid Apple signature).
set -euo pipefail

URL="https://github.com/ArthurMospan/ScreenVoicer/releases/latest/download/ScreenVoicer-macOS.zip"
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

echo "ScreenVoicer: завантажую останню версію…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar -o "$TMP/ScreenVoicer.zip" "$URL"

echo "Встановлюю в «$DEST»…"
osascript -e 'tell application "ScreenVoicer" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST/ScreenVoicer.app"
ditto -x -k "$TMP/ScreenVoicer.zip" "$DEST"
xattr -dr com.apple.quarantine "$DEST/ScreenVoicer.app" 2>/dev/null || true

open "$DEST/ScreenVoicer.app"
echo ""
echo "Готово! ScreenVoicer встановлено й запущено."
echo "Іконка — у рядку меню вгорі справа. Знімок: ⌥⇧S (Option+Shift+S)."
echo "Далі програма попросить дозволи на запис екрана й мікрофон — це потрібно один раз."
