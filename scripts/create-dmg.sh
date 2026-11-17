#!/bin/bash

# Create DMG for Gemini Desktop
# Usage: ./scripts/create-dmg.sh   (run ./scripts/build-app.sh first;
#        use ./scripts/build-app.sh --universal for a DMG that runs on every Mac)

set -e

cd "$(dirname "$0")/.."

APP_NAME="Gemini Desktop"
APP_PATH="$(pwd)/build/${APP_NAME}.app"
OUTPUT_DIR="$(pwd)/build"
DMG_FINAL="${OUTPUT_DIR}/GeminiDesktop.dmg"
VOLUME_NAME="Gemini Desktop"

echo "Creating DMG for ${APP_NAME}..."

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH} — run ./scripts/build-app.sh first"
    exit 1
fi

# Create staging directory in the same location
STAGING_DIR="${OUTPUT_DIR}/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app to staging
echo "Copying app..."
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if exists
rm -f "$DMG_FINAL"

# Create DMG directly (no mount needed)
echo "Creating DMG..."
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_FINAL"

# Cleanup staging
rm -rf "$STAGING_DIR"

echo ""
echo "DMG created successfully: ${DMG_FINAL}"
echo "Size: $(du -h "$DMG_FINAL" | cut -f1)"
