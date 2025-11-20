#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
APP_NAME="NetSpeed"
BUILD_DIR="$ROOT_DIR/.build/release"
BIN_PATH="$BUILD_DIR/$APP_NAME"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy icon if present
ICON_SRC="$ROOT_DIR/Sources/Assets/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NetSpeed</string>
    <key>CFBundleIdentifier</key>
    <string>com.netspeed.macos</string>
    <key>CFBundleExecutable</key>
    <string>NetSpeed</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/NetSpeed"
chmod +x "$APP_DIR/Contents/MacOS/NetSpeed"

echo "Packaged: $APP_DIR"