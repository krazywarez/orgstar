#!/bin/sh
# Builds Orgstar.app for the iOS Simulator in .build/ios-app from the OrgstarMobile product,
# signed ad hoc. Install with `xcrun simctl install booted .build/ios-app/Orgstar.app`.
# Usage: scripts/build-ios-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
app=".build/ios-app/Orgstar.app"
products=".build/ios/Build/Products/Debug-iphonesimulator"

xcodebuild -scheme OrgstarMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios build -quiet

rm -rf "$app"
mkdir -p "$app"
cp "$products/OrgstarMobile" "$app/OrgstarMobile"
for bundle in "$products"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$app/"
done

cat > "$app/Info.plist" <<PLIST
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
    <string>OrgstarMobile</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>iPhoneSimulator</string></array>
    <key>MinimumOSVersion</key>
    <string>26.0</string>
    <key>UIDeviceFamily</key>
    <array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <true/>
    </dict>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>org-protocol</string>
            <key>CFBundleURLSchemes</key>
            <array><string>org-protocol</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "$app"
