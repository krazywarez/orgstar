#!/bin/sh
# Builds Orgstar.app in .build/app from the release binary, signed ad hoc for local use.
# Usage: scripts/build-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
app=".build/app/Orgstar.app"

swift build -c release --product Orgstar
binary="$(swift build -c release --show-bin-path)/Orgstar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Orgstar"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar</string>
    <key>CFBundleName</key>
    <string>Orgstar</string>
    <key>CFBundleDisplayName</key>
    <string>Orgstar</string>
    <key>CFBundleExecutable</key>
    <string>Orgstar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
echo "$app"
