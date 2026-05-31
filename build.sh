#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "🔨 Building VimText (release)..."
swift build -c release 2>&1

echo "📦 Creating app bundle..."
APP_NAME="VimText"
APP_DIR="$APP_NAME.app/Contents"
MACOS_DIR="$APP_DIR/MacOS"
RESOURCES_DIR="$APP_DIR/Resources"

rm -rf "$APP_NAME.app"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Generate AppIcon.icns from the generated appiconset
echo "🎨 Compiling AppIcon.icns..."
ICONSET_DIR="VimText/Assets.xcassets/AppIcon.appiconset"
TEMP_ICONSET="VimText/Assets.xcassets/AppIcon.iconset"
if [ -d "$ICONSET_DIR" ]; then
    rm -rf "$TEMP_ICONSET"
    cp -R "$ICONSET_DIR" "$TEMP_ICONSET"
    rm -f "$TEMP_ICONSET/Contents.json"
    iconutil -c icns "$TEMP_ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$TEMP_ICONSET"
    echo "✅ Compiled AppIcon.icns successfully"
else
    echo "⚠️  AppIcon.appiconset not found, skipping icon compilation"
fi

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VimText</string>
    <key>CFBundleIdentifier</key>
    <string>com.vimtext.app</string>
    <key>CFBundleName</key>
    <string>VimText</string>
    <key>CFBundleDisplayName</key>
    <string>VimText</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

cp .build/release/VimText "$MACOS_DIR/VimText"

for bundle in .build/release/VimText*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES_DIR/"
    fi
done

echo "📍 Installing to /Applications..."
pkill -f "VimText" 2>/dev/null || true
sleep 0.5

cp -R "$APP_NAME.app" /Applications/
echo "✅ VimText.app installed to /Applications/"
echo "🚀 Launching VimText..."
open /Applications/VimText.app
