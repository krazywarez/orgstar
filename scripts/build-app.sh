#!/bin/sh
# Builds Orgstar.app in .build/app from the release binary, signed ad hoc for local use. The
# icon is drawn by scripts/make-icon.swift.
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
    <string>Orgstar</string>
    <key>CFBundleDisplayName</key>
    <string>Orgstar</string>
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

codesign --force --sign - "$app"
echo "$app"
