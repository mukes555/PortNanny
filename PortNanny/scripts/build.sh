#!/bin/bash

set -euo pipefail

APP_NAME="PortNanny"
VERSION="2.3.0"
BUNDLE_ID="${BUNDLE_ID:-com.mukes555.$APP_NAME}"
MAKE_DMG=0

usage() {
    echo "Usage: $0 [--dmg] [--bundle-id=...]"
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --dmg) MAKE_DMG=1 ;;
        --bundle-id=*) BUNDLE_ID="${arg#*=}" ;;
        *)
            echo "Unknown argument: $arg"
            usage
            exit 2
            ;;
    esac
done

# Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGING_DIR="$WORK_DIR/dmg_staging"

echo "🚀 Building $APP_NAME for Release..."

# 1. Clean previous build
rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 2. Build with Swift PM (Release Mode, universal arm64 + x86_64)
# A universal binary runs natively on both Apple Silicon and Intel Macs.
# (For a single-arch build, drop the --arch flags.)
echo "📦 Compiling Swift sources (universal: arm64 + x86_64)..."
cd "$PROJECT_ROOT"
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# 3. Copy Executable: multi-arch builds land under .build/apple/Products,
# single-arch under .build/release; support both.
echo "📂 Copying executable..."
if [ -f "$PROJECT_ROOT/.build/apple/Products/Release/$APP_NAME" ]; then
    BINARY_SOURCE="$PROJECT_ROOT/.build/apple/Products/Release/$APP_NAME"
else
    BINARY_SOURCE="$PROJECT_ROOT/.build/release/$APP_NAME"
fi
cp "$BINARY_SOURCE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# The standalone CLI (no AppKit) ships in Contents/Helpers, because a
# Contents/MacOS/portnanny would be the same file as Contents/MacOS/PortNanny
# on a case-insensitive volume. The Homebrew cask links it as `portnanny`;
# the app binary still answers CLI arguments for anyone who symlinked it.
CLI_SOURCE="$(dirname "$BINARY_SOURCE")/portnanny-cli"
if [ -f "$CLI_SOURCE" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Helpers"
    cp "$CLI_SOURCE" "$APP_BUNDLE/Contents/Helpers/portnanny"
else
    echo "warning: standalone CLI not found at $CLI_SOURCE" >&2
fi

# 3a. Mascot art (assets/mascot/quokka-<mood>.png, made by scripts/make_artwork.swift);
# MascotView falls back to a symbol when a file is missing.
if ls "$PROJECT_ROOT/assets/mascot/"quokka-*.png >/dev/null 2>&1; then
    cp "$PROJECT_ROOT/assets/mascot/"quokka-*.png "$APP_BUNDLE/Contents/Resources/"
fi

# 3b. App icon (regenerate with: swift scripts/make_artwork.swift icon <1024.png> assets/AppIcon.icns)
if [ -f "$PROJECT_ROOT/assets/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 4. Generate Info.plist
echo "📝 Generating Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. https://github.com/mukes555/PortNanny</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>portnanny</string>
                <string>portkilla</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Single-binary bundle: sign the bundle itself (--deep is deprecated and
# unnecessary here since there is no nested code).
echo "🔏 Signing App (ad-hoc)..."
# Nested executables are not covered by the bundle signature; an unsigned
# Mach-O is refused outright on Apple Silicon.
if [ -f "$APP_BUNDLE/Contents/Helpers/portnanny" ]; then
    codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/portnanny"
fi
codesign --force --sign - "$APP_BUNDLE"

codesign --verify --strict "$APP_BUNDLE"

if [ "$MAKE_DMG" -eq 1 ]; then
    echo "📦 Creating DMG..."
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

echo "✨ Build Complete!"
echo "✅ App is ready at: $APP_BUNDLE"
if [ -f "$DMG_PATH" ]; then
    echo "✅ DMG is ready at: $DMG_PATH"
fi
