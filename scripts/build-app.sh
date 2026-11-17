#!/bin/bash
#
# Build "Gemini Desktop.app" using only the Xcode Command Line Tools.
# No full Xcode install, Apple ID or Swift packages required.
#
# Usage:
#   ./scripts/build-app.sh               # release build for this Mac's CPU
#   ./scripts/build-app.sh --universal   # Intel + Apple Silicon
#   ./scripts/build-app.sh --debug       # debug build (Web Inspector enabled)
#   ./scripts/build-app.sh --install     # build, then copy to /Applications and launch
#
# Requires: macOS 13 Ventura or later, `xcode-select --install`.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="Gemini Desktop"
EXECUTABLE="GeminiDesktop"
BUNDLE_ID="com.alexcding.geminidesktop"
VERSION="0.3.0"
BUILD_NUMBER="6"
MIN_MACOS="13.0"

CONFIG="release"
UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --universal) UNIVERSAL=1 ;;
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "error: Swift compiler not found. Install the Command Line Tools with: xcode-select --install"
    exit 1
fi

SDK="$(xcrun --show-sdk-path)"
BUILD_DIR="$ROOT/build"
OBJ_DIR="$BUILD_DIR/obj-$CONFIG"
APP="$BUILD_DIR/$APP_NAME.app"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find App ChatBar Coordinators Features Utils Views WebKit -name '*.swift' -print0)

if [ "$CONFIG" = "debug" ]; then
    SWIFT_FLAGS=(-Onone -g -DDEBUG)
else
    SWIFT_FLAGS=(-O -whole-module-optimization)
fi

if [ "$UNIVERSAL" = "1" ]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

echo "==> Building $APP_NAME $VERSION ($CONFIG, ${ARCHS[*]}) with $(xcrun swiftc --version 2>/dev/null | head -1)"
mkdir -p "$OBJ_DIR"

BINARIES=()
for arch in "${ARCHS[@]}"; do
    out="$OBJ_DIR/$EXECUTABLE-$arch"
    echo "    compiling for $arch…"
    xcrun swiftc "${SWIFT_FLAGS[@]}" \
        -parse-as-library \
        -module-name "$EXECUTABLE" \
        -target "$arch-apple-macos$MIN_MACOS" \
        -sdk "$SDK" \
        -framework Carbon -framework WebKit -framework UserNotifications -framework ServiceManagement \
        "${SOURCES[@]}" \
        -o "$out"
    BINARIES+=("$out")
done

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#BINARIES[@]}" -gt 1 ]; then
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
else
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/$EXECUTABLE"
fi

if [ ! -f Resources/AppIcon.icns ]; then
    echo "    generating icon…"
    swift scripts/make-icon.swift "$ROOT"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Info.plist = shared keys from Resources/Info.plist + bundle identity
PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null; }
pb "Add :CFBundleDevelopmentRegion string en"
pb "Add :CFBundleExecutable string $EXECUTABLE"
pb "Add :CFBundleIdentifier string $BUNDLE_ID"
pb "Add :CFBundleName string $APP_NAME"
pb "Add :CFBundleDisplayName string $APP_NAME"
pb "Add :CFBundleIconFile string AppIcon"
pb "Add :CFBundlePackageType string APPL"
pb "Add :CFBundleInfoDictionaryVersion string 6.0"
pb "Add :CFBundleShortVersionString string $VERSION"
pb "Add :CFBundleVersion string $BUILD_NUMBER"
pb "Add :NSPrincipalClass string NSApplication"
pb "Add :NSHumanReadableCopyright string Unofficial wrapper for gemini.google.com. Not affiliated with Google."
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Code signing (ad-hoc)"
codesign --force --sign - \
    --options runtime \
    --entitlements Resources/GeminiDesktop.entitlements \
    --identifier "$BUNDLE_ID" \
    "$APP"
codesign --verify --strict "$APP"

echo "==> Built: $APP"

if [ "$INSTALL" = "1" ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Register with Launch Services so the URL scheme and "Ask Gemini" service show up.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
    /System/Library/CoreServices/pbs -update || true
    open "$DEST"
    echo "==> Installed and launched."
fi
