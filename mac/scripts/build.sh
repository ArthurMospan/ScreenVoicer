#!/bin/bash
# Builds ScreenVoicer.app (universal: Apple Silicon + Intel), signs it and packs ScreenVoicer-macOS.zip.
#
#   mac/scripts/build.sh [version]
#
# Signing: with MAC_CERT_P12 (base64 .p12) and MAC_CERT_PASSWORD set, every build is signed with the same
# self-signed certificate, so macOS keeps the Screen Recording and Microphone permissions across updates
# (TCC matches the designated requirement "identifier + certificate"). Without them it signs ad-hoc.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$MAC_DIR/.." && pwd)"
cd "$MAC_DIR"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' "$REPO_DIR/CHANGELOG.md" | sed -E 's/^## //')"
fi
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
echo "▸ ScreenVoicer $VERSION ($BUILD_NUMBER) for: $ARCHS"

# ── whisper.cpp (prebuilt xcframework with the Metal backend) ───────────────────────────────────────
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip"
WHISPER_SHA256="e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
if [ ! -d Vendor/whisper.xcframework ]; then
  echo "▸ Fetching whisper.cpp xcframework"
  mkdir -p Vendor
  curl -fsSL --retry 3 -o Vendor/whisper.zip "$WHISPER_URL"
  echo "$WHISPER_SHA256  Vendor/whisper.zip" | shasum -a 256 -c -
  rm -rf Vendor/unpacked && mkdir -p Vendor/unpacked
  ditto -x -k Vendor/whisper.zip Vendor/unpacked
  mv "$(find Vendor/unpacked -maxdepth 3 -name whisper.xcframework -type d | head -1)" Vendor/whisper.xcframework
  rm -rf Vendor/unpacked Vendor/whisper.zip
fi

# ── compile ─────────────────────────────────────────────────────────────────────────────────────────
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

# ── bundle ──────────────────────────────────────────────────────────────────────────────────────────
OUT="$MAC_DIR/build"
APP="$OUT/ScreenVoicer.app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/ScreenVoicer" "$APP/Contents/MacOS/ScreenVoicer"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/whisper.framework"
rm -rf "$APP/Contents/Frameworks/whisper.framework/Versions/A/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Versions/A/Modules" \
       "$APP/Contents/Frameworks/whisper.framework/Modules"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# The icon is drawn by the app itself from the same vector as the Windows logo.
codesign --force --deep --sign - "$APP" >/dev/null
ICONSET="$OUT/AppIcon.iconset"
"$APP/Contents/MacOS/ScreenVoicer" --render-icons "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ── sign ────────────────────────────────────────────────────────────────────────────────────────────
IDENTITY="-"
KEYCHAIN_ARGS=()
if [ -n "${MAC_CERT_P12:-}" ] && [ -n "${MAC_CERT_PASSWORD:-}" ]; then
  echo "▸ Signing with the ScreenVoicer certificate"
  TMP="$(mktemp -d)"
  KEYCHAIN="$TMP/screenvoicer-signing.keychain-db"
  KEYCHAIN_PASS="$(openssl rand -hex 16)"
  echo "$MAC_CERT_P12" | base64 --decode > "$TMP/cert.p12"
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/ScreenVoicer Self-Signed/ {print $2; exit}')"
  if [ -z "$IDENTITY" ]; then
    security find-identity "$KEYCHAIN"
    echo "The certificate has no usable code-signing identity." >&2
    exit 1
  fi
  KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
  rm -f "$TMP/cert.p12"
else
  echo "▸ No certificate: signing ad-hoc (macOS will ask for permissions again after every update)"
fi

sign() {
  # bash 3.2 (macOS) treats an empty "${array[@]}" as unbound under set -u
  codesign --force --timestamp=none --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$@"
}
if ! sign "$APP/Contents/Frameworks/whisper.framework"; then
  [ "$IDENTITY" = "-" ] && exit 1
  # Some codesign versions refuse an untrusted self-signed identity: trust it for code signing on this runner.
  echo "▸ Trusting the certificate for code signing on this machine"
  security find-certificate -c "ScreenVoicer Self-Signed" -p "$KEYCHAIN" > "$TMP/cert.pem"
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"
  sign "$APP/Contents/Frameworks/whisper.framework"
fi
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "▸ Designated requirement:"
codesign -d -r- "$APP" 2>&1 | grep designated || true

# ── pack ────────────────────────────────────────────────────────────────────────────────────────────
ditto -c -k --keepParent "$APP" "$OUT/ScreenVoicer-macOS.zip"
echo "▸ $OUT/ScreenVoicer-macOS.zip ($(du -h "$OUT/ScreenVoicer-macOS.zip" | cut -f1))"
