#!/bin/sh
# Builds Technoduck.app next to this script.
# UNIVERSAL=1 builds for Apple silicon and Intel; SIGN="<identity>" signs with that certificate and the hardened runtime (see release.sh).
set -e
cd "$(dirname "$0")"
if [ -n "$UNIVERSAL" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/out/Products/Release/Technoduck
else
  swift build -c release
  BIN=.build/release/Technoduck
fi
rm -rf Technoduck.app && mkdir -p Technoduck.app/Contents/MacOS
cp "$BIN" Technoduck.app/Contents/MacOS/Technoduck
# App icon: every size macOS wants, made from Resources/AppIcon.png.
ICONSET=$(mktemp -d)/AppIcon.iconset && mkdir -p "$ICONSET" Technoduck.app/Contents/Resources
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Technoduck.app/Contents/Resources/AppIcon.icns
cp Resources/ChicagoFLF.ttf Resources/BebasNeue-Regular.ttf Technoduck.app/Contents/Resources/  # Macintosh 512K and Label Lime
cp -R Resources/Icons Technoduck.app/Contents/Resources/  # Settings › Icon
cat > Technoduck.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Technoduck</string>
<key>CFBundleIdentifier</key><string>app.technoduck.client</string>
<key>CFBundleExecutable</key><string>Technoduck</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -n "$SIGN" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN" Technoduck.app
else
  codesign --force -s - Technoduck.app
fi
