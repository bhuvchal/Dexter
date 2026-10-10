#!/bin/bash
# Build and package DynamicTerminal as a macOS .app bundle

set -e

APP_NAME="DynamicTerminal"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "→ Building release binary..."
swift build -c release

echo "→ Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Copy bundled scripts (ai, search, context_hook.zsh) into Resources so they
# are on PATH automatically when the terminal spawns a shell.
for script in Scripts/ai Scripts/search Scripts/context_hook.zsh; do
    if [ -f "$script" ]; then
        cp "$script" "$RESOURCES_DIR/$(basename "$script")"
        chmod +x "$RESOURCES_DIR/$(basename "$script")"
        echo "→ Bundled $script"
    fi
done

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "→ Icon copied"
fi

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DynamicTerminal</string>
    <key>CFBundleDisplayName</key>
    <string>Dynamic Terminal</string>
    <key>CFBundleIdentifier</key>
    <string>com.bhuvanchalla.dynamicterminal</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>DynamicTerminal</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "→ App bundle created at: $(pwd)/$BUNDLE_DIR"
echo "→ Opening..."
open "$BUNDLE_DIR"
