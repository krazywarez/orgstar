#!/bin/sh
# Builds Orgstar.app for the iOS Simulator in .build/ios-app from the OrgstarMobile product,
# signed ad hoc. Install with `xcrun simctl install booted .build/ios-app/Orgstar.app`.
# Usage: scripts/build-ios-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
app=".build/ios-app/Orgstar.app"
products=".build/ios/Build/Products/Debug-iphonesimulator"

for scheme in OrgstarMobile OrgstarQuickLook; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios build -quiet
done

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
    <!-- public.text, not public.plain-text as on the Mac: iOS previews plain text itself and
         never asks the Quick Look extension. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.orgmode.org</string>
            <key>UTTypeDescription</key>
            <string>Org document</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>org</string><string>org_archive</string></array>
            </dict>
        </dict>
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

# Quick Look previews of org files, in Files and wherever else Quick Look shows them.
appex="$app/PlugIns/OrgstarQuickLook.appex"
mkdir -p "$appex"
cp "$products/OrgstarQuickLook" "$appex/OrgstarQuickLook"
cat > "$appex/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar.quicklook</string>
    <key>CFBundleName</key>
    <string>OrgstarQuickLook</string>
    <key>CFBundleDisplayName</key>
    <string>Orgstar</string>
    <key>CFBundleExecutable</key>
    <string>OrgstarQuickLook</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>iPhoneSimulator</string></array>
    <key>MinimumOSVersion</key>
    <string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>PreviewProvider</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array><string>org.orgmode.org</string></array>
            <key>QLIsDataBasedPreview</key>
            <true/>
        </dict>
    </dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$appex"

codesign --force --sign - "$app"
echo "$app"
