#!/bin/sh
# Builds orgstar.app in .build/app from the release binary. The icon is drawn by
# scripts/make-icon.swift.
# Usage: scripts/build-app.sh [version] [build]
#   ORGSTAR_SIGN   signing identity; ad hoc ("-") for local use by default. Any other
#                  identity also turns on the hardened runtime and a secure timestamp.
#   ORGSTAR_ARCHS  architectures, e.g. "arm64 x86_64" for a universal app; this Mac's by default.
set -eu

cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
build="${2:-$version}"
sign="${ORGSTAR_SIGN:--}"
app=".build/app/orgstar.app"
arch_flags=""
for arch in ${ORGSTAR_ARCHS:-$(uname -m)}; do arch_flags="$arch_flags --arch $arch"; done
if [ "$sign" = "-" ]; then
    sign_flags=""
else
    sign_flags="--options runtime --timestamp"
fi

# shellcheck disable=SC2086
swift build -c release $arch_flags --product Orgstar
# shellcheck disable=SC2086
swift build -c release $arch_flags --product OrgstarQuickLook
# shellcheck disable=SC2086
swift build -c release $arch_flags --product OrgstarSpotlight
# shellcheck disable=SC2086
binary="$(swift build -c release $arch_flags --show-bin-path)/Orgstar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary" "$app/Contents/MacOS/Orgstar"

# Sparkle, from its SwiftPM artifact: the framework beside the binary, found through an rpath.
sparkle="$(find .build/artifacts -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 7 | head -1)"
[ -n "$sparkle" ] || { echo "Sparkle.framework not in .build/artifacts; swift build fetches it." >&2; exit 1; }
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
otool -l "$app/Contents/MacOS/Orgstar" | grep -q '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Orgstar"

# SwiftMath's math fonts, which it finds in the app's resources.
cp -R "$(dirname "$binary")/SwiftMath_SwiftMath.bundle" "$app/Contents/Resources/"

# Updates: the appcast and its signing key, for signed builds only; a dev build never checks.
if [ "$sign" != "-" ]; then
    feed_keys="    <key>SUFeedURL</key>
    <string>https://krz.gitbay.site/orgstar/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>${ORGSTAR_ED_PUBLIC_KEY:?set ORGSTAR_ED_PUBLIC_KEY to the key generate_keys printed}</string>"
else
    feed_keys=""
fi
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
    <string>${build}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
${feed_keys}
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>The agenda shows your calendar events alongside your Org entries. orgstar only reads them.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>The agenda shows your reminders alongside your Org entries. orgstar only reads them.</string>
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
    <string>${build}</string>
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
    # shellcheck disable=SC2086
    codesign --force --sign "$sign" $sign_flags --entitlements "$work/sandbox.entitlements" "$app/Contents/PlugIns/$1.appex"
}
work="$(mktemp -d)"
appex OrgstarQuickLook com.apple.quicklook.preview PreviewProvider \
    "<key>QLSupportedContentTypes</key><array><string>org.orgmode.org</string></array><key>QLIsDataBasedPreview</key><true/>"
appex OrgstarSpotlight com.apple.spotlight.import ImportExtension \
    "<key>CSSupportedContentTypes</key><array><string>org.orgmode.org</string></array>"

# Sparkle's inner pieces are signed first, as its documentation has it, then the framework.
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$fw/Autoupdate" "$fw/Updater.app" "$app/Contents/Frameworks/Sparkle.framework"; do
    # shellcheck disable=SC2086
    codesign --force --sign "$sign" $sign_flags "$item"
done

# The hardened runtime needs Calendar access declared for the agenda's events.
cat > "$work/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
PLIST
# shellcheck disable=SC2086
codesign --force --sign "$sign" $sign_flags --entitlements "$work/app.entitlements" "$app"
rm -rf "$work"
echo "$app"
