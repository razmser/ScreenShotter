#!/usr/bin/env bash
# Builds ScreenShotter.app into ./build.
#
# Signing: macOS ties the Screen Recording permission to the code signature.
# An ad-hoc signature changes on every build, so the permission would have to be
# re-granted after each rebuild. If an "Apple Development" identity is available
# it is used automatically; override with SIGN_IDENTITY=... (use "-" for ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/ScreenShotter.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Screenshotter" "$APP/Contents/MacOS/ScreenShotter"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Release builds stamp the version from the tag; local builds keep Info.plist's.
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Build all standard and Retina icon sizes from the transparent source artwork.
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP (signed with: $SIGN_IDENTITY)"
