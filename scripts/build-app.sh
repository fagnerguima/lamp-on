#!/bin/sh
# Compila o LAMP-ON (arm64, release) e monta build/LAMP-ON.app com assinatura ad-hoc.
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="build/LAMP-ON.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/LampOn"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LampOn"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.lampon.LampOn</string>
    <key>CFBundleName</key><string>LAMP-ON</string>
    <key>CFBundleDisplayName</key><string>LAMP-ON</string>
    <key>CFBundleExecutable</key><string>LampOn</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>LAMP-ON — servidor local com Homebrew</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Pronto: $APP ($(lipo -archs "$APP/Contents/MacOS/LampOn"))"
