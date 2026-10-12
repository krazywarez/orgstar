#!/bin/sh
# Builds orgstar.app for the iOS Simulator in .build/ios-app from the OrgstarMobile product,
# signed ad hoc. Install with `xcrun simctl install booted .build/ios-app/orgstar.app`.
# Usage: scripts/build-ios-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.3.2}"
app=".build/ios-app/orgstar.app"
products=".build/ios/Build/Products/Debug-iphonesimulator"

# The entitlements (the app group the share extension leaves captures in) go where the
# Simulator reads them, into the binaries.
entitlements=scripts/OrgstarMobile.entitlements
for scheme in OrgstarMobile OrgstarQuickLook OrgstarShare; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios build -quiet \
        CODE_SIGN_ENTITLEMENTS="$PWD/$entitlements"
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
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>de</string></array>
    <key>CFBundleName</key>
    <string>orgstar</string>
    <key>CFBundleDisplayName</key>
    <string>orgstar</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
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
    <key>NSCameraUsageDescription</key>
    <string>Photos you take from the editor are saved with your notes and linked where the caret is.</string>
    <key>NSFaceIDUsageDescription</key>
    <string>Face ID unlocks the passphrase of encrypted entries you asked orgstar to remember.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>The agenda shows your calendar events alongside your Org entries. orgstar changes your calendars only when you edit an event or add an entry to one.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>The agenda shows your reminders alongside your Org entries. orgstar only reads them.</string>
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

# App Intents metadata for Shortcuts, from the constant values the build extracted; building
# a package doesn't run this step itself.
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
objects=".build/ios/Build/Intermediates.noindex/Orgstar.build/Debug-iphonesimulator/OrgstarMobile-p.build/Objects-normal/arm64"
work="$(mktemp -d)"
ls "$PWD/$objects"/*.swiftconstvalues > "$work/constvalues.txt"
"$toolchain/usr/bin/appintentsmetadataprocessor" --toolchain-dir "$toolchain" --module-name OrgstarMobile \
    --sdk-root "$(xcrun --sdk iphonesimulator --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family iOS --deployment-target 26.0 --bundle-identifier sh.krz.orgstar \
    --target-triple arm64-apple-ios26.0-simulator --binary-file "$app/OrgstarMobile" --source-file-list "$objects/OrgstarMobile.SwiftFileList" \
    --swift-const-vals-list "$work/constvalues.txt" --output "$app" --force > /dev/null 2>&1

# The UI's translations, from l10n/Localizable.xcstrings.
scripts/localize.sh "$app"

appex() { # name, bundle id suffix, extension point, principal class, attributes, entitlements
    dir="$app/PlugIns/$1.appex"
    mkdir -p "$dir"
    cp "$products/$1" "$dir/$1"
    scripts/localize.sh "$dir"
    cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar.$2</string>
    <key>CFBundleName</key>
    <string>$1</string>
    <key>CFBundleDisplayName</key>
    <string>orgstar</string>
    <key>CFBundleExecutable</key>
    <string>$1</string>
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
        <string>$3</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$4</string>
        <key>NSExtensionAttributes</key>
        <dict>$5</dict>
    </dict>
</dict>
</plist>
PLIST
    codesign --force --sign - ${6:+--entitlements "$6"} "$dir"
}
# Quick Look previews of org files, in Files and wherever else Quick Look shows them.
appex OrgstarQuickLook quicklook com.apple.quicklook.preview PreviewProvider \
    "<key>QLSupportedContentTypes</key><array><string>org.orgmode.org</string></array><key>QLIsDataBasedPreview</key><true/>"
# Capture from the share sheet: a page's link or text.
appex OrgstarShare share com.apple.share-services ShareViewController \
    "<key>NSExtensionActivationRule</key><dict><key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer><key>NSExtensionActivationSupportsText</key><true/><key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>10</integer><key>NSExtensionActivationSupportsMovieWithMaxCount</key><integer>10</integer><key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>10</integer></dict>" \
    "$entitlements"

# The watch app, which a paired watch installs from here.
scripts/build-watch-app.sh "$version" > /dev/null
mkdir -p "$app/Watch"
cp -R .build/watch-app/OrgstarWatch.app "$app/Watch/"

codesign --force --sign - --entitlements "$entitlements" "$app"
rm -rf "$work"
echo "$app"
