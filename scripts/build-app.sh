#!/bin/sh
# Builds orgstar.app in .build/app from the release binary, signed ad hoc for local use. The
# icon is drawn by scripts/make-icon.swift.
# Usage: scripts/build-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
app=".build/app/orgstar.app"

swift build -c release --product Orgstar
swift build -c release --product OrgstarQuickLook
swift build -c release --product OrgstarSpotlight
binary="$(swift build -c release --show-bin-path)/Orgstar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Orgstar"
iconset="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar</string>
    <key>CFBundleName</key>
    <string>orgstar</string>
    <key>CFBundleDisplayName</key>
    <string>orgstar</string>
    <key>CFBundleExecutable</key>
    <string>Orgstar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.orgmode.org</string>
            <key>UTTypeDescription</key>
            <string>Org document</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>org</string><string>org_archive</string></array>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Org document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array><string>org.orgmode.org</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.plain-text</string></array>
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
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>The agenda shows your calendar events alongside your Org entries. orgstar only reads them.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# App Intents metadata for Shortcuts, from the constant values Swift Build extracted; SwiftPM
# doesn't run this step itself.
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
objects=".build/out/Intermediates.noindex/Orgstar.build/Release/Orgstar-p.build/Objects-normal/$(uname -m)"
work="$(mktemp -d)"
echo "$PWD/$objects/Orgstar-primary.swiftconstvalues" > "$work/constvalues.txt"
"$toolchain/usr/bin/appintentsmetadataprocessor" --toolchain-dir "$toolchain" --module-name Orgstar \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 26.0 --bundle-identifier sh.krz.orgstar \
    --target-triple "$(uname -m)-apple-macos26.0" --binary-file "$binary" --source-file-list "$objects/Orgstar.SwiftFileList" \
    --swift-const-vals-list "$work/constvalues.txt" --output "$app/Contents/Resources" --force > /dev/null 2>&1
rm -rf "$work"

# App extensions: Quick Look previews and the Spotlight importer. They run sandboxed.
appex() { # name, extension point, principal class, attributes
    dir="$app/Contents/PlugIns/$1.appex/Contents"
    mkdir -p "$dir/MacOS"
    cp "$(dirname "$binary")/$1" "$dir/MacOS/$1"
    cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sh.krz.orgstar.$(echo "$1" | sed 's/^Orgstar//' | tr 'A-Z' 'a-z')</string>
    <key>CFBundleName</key>
    <string>$1</string>
    <key>CFBundleExecutable</key>
    <string>$1</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>$2</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$3</string>
        <key>NSExtensionAttributes</key>
        <dict>$4</dict>
    </dict>
</dict>
</plist>
PLIST
    cat > "$work/sandbox.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
PLIST
    codesign --force --sign - --entitlements "$work/sandbox.entitlements" "$app/Contents/PlugIns/$1.appex"
}
work="$(mktemp -d)"
appex OrgstarQuickLook com.apple.quicklook.preview PreviewProvider \
    "<key>QLSupportedContentTypes</key><array><string>org.orgmode.org</string></array><key>QLIsDataBasedPreview</key><true/>"
appex OrgstarSpotlight com.apple.spotlight.import ImportExtension \
    "<key>CSSupportedContentTypes</key><array><string>org.orgmode.org</string></array>"
rm -rf "$work"

codesign --force --sign - "$app"
echo "$app"
