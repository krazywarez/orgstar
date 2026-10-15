#!/bin/sh
# Builds OrgstarWatch.app, with its complications, for the watchOS Simulator in
# .build/watch-app from the OrgstarWatch and OrgstarWatchWidgets products, signed ad hoc.
# scripts/build-ios-app.sh embeds it in the iOS app; install it on a paired watch simulator
# with `xcrun simctl install <watch> .build/watch-app/OrgstarWatch.app`.
# Usage: scripts/build-watch-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.6.0}"
app=".build/watch-app/OrgstarWatch.app"
products=".build/watch/Build/Products/Debug-watchsimulator"
# The app group the complications read the agenda from, on the watch.
entitlements=scripts/OrgstarMobile.entitlements

for scheme in OrgstarWatch OrgstarWatchWidgets; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=watchOS Simulator' -derivedDataPath .build/watch build -quiet \
        CODE_SIGN_ENTITLEMENTS="$PWD/$entitlements"
done

rm -rf "$app"
mkdir -p "$app/PlugIns/OrgstarWatchWidgets.appex"
cp "$products/OrgstarWatch" "$app/OrgstarWatch"
scripts/localize.sh "$app"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar.watchkitapp</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>de</string></array>
    <key>CFBundleName</key>
    <string>orgstar</string>
    <key>CFBundleDisplayName</key>
    <string>orgstar</string>
    <key>CFBundleExecutable</key>
    <string>OrgstarWatch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>WatchSimulator</string></array>
    <key>MinimumOSVersion</key>
    <string>26.0</string>
    <key>UIDeviceFamily</key>
    <array><integer>4</integer></array>
    <key>WKApplication</key>
    <true/>
    <key>WKCompanionAppBundleIdentifier</key>
    <string>sh.krz.orgstar</string>
</dict>
</plist>
PLIST

dir="$app/PlugIns/OrgstarWatchWidgets.appex"
cp "$products/OrgstarWatchWidgets" "$dir/OrgstarWatchWidgets"
scripts/localize.sh "$dir"
cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar.watchkitapp.widgets</string>
    <key>CFBundleName</key>
    <string>OrgstarWatchWidgets</string>
    <key>CFBundleDisplayName</key>
    <string>orgstar</string>
    <key>CFBundleExecutable</key>
    <string>OrgstarWatchWidgets</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>WatchSimulator</string></array>
    <key>MinimumOSVersion</key>
    <string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$entitlements" "$dir"
codesign --force --sign - --entitlements "$entitlements" "$app"
echo "$app"
