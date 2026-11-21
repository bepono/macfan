#!/bin/bash
# Builds "CPU Fan.app" (menu bar app + cpufan tool + install scripts) and copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/CPU Fan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -Wall -framework IOKit -o cpufan cpufan.c
cp cpufan install.sh uninstall.sh "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/"*.sh

# App icon: draw the 1024px master once, then scale it into an .icns.
[ -f icon/icon-1024.png ] || swift icon/make_icon.swift icon/icon-1024.png
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/CPUFan" CPUFanApp.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.local.cpufan.app</string>
  <key>CFBundleName</key><string>CPU Fan</string>
  <key>CFBundleDisplayName</key><string>CPU Fan</string>
  <key>CFBundleExecutable</key><string>CPUFan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
pkill -x CPUFan 2>/dev/null || true
rm -rf "/Applications/CPU Fan.app"
ditto "$APP" "/Applications/CPU Fan.app"
echo "Built and copied to /Applications/CPU Fan.app"
