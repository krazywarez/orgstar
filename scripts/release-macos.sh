#!/bin/sh
# Archives the Mac App Store app (with its widgets, Quick Look and Spotlight extensions) and uploads
# it to App Store Connect. The version is the project's MARKETING_VERSION; the build number is the
# commit count. The Developer ID app is released by scripts/release-mac.sh instead. The work is done
# by appstore-kit, checked out beside this repository or at $APPSTORE_KIT.
# Usage: scripts/release-macos.sh
#   ORGSTAR_PUBLISH  0 archives and exports the .pkg to .build/macos-release without uploading
PUBLISH="${ORGSTAR_PUBLISH:-1}"
name=orgstar
project=ios/Orgstar.xcodeproj
scheme="Orgstar macOS"
platform=macos
configuration=Release

# Runs before the archive, so it can only check build settings.
preflight() {
    settings="$(command xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
        -destination 'generic/platform=macOS' -showBuildSettings 2>/dev/null)" || fail "can't read the build settings of $scheme"
    value() {
        printf '%s\n' "$settings" | sed -n "s/^ *$1 = //p" | head -1
    }
    case " $(value SWIFT_ACTIVE_COMPILATION_CONDITIONS) " in
        *" APPSTORE "*) ;;
        *) fail "SWIFT_ACTIVE_COMPILATION_CONDITIONS of $scheme ($configuration) lacks APPSTORE" ;;
    esac
    [ "$(value PRODUCT_BUNDLE_IDENTIFIER)" = sh.krz.orgstar ] || fail "$scheme's bundle ID is $(value PRODUCT_BUNDLE_IDENTIFIER), not sh.krz.orgstar"
    for entitlements in ios/OrgstarMac/*.entitlements ios/OrgstarWidgets/*-macOS.entitlements \
        ios/OrgstarQuickLook/*-macOS.entitlements ios/OrgstarSpotlight/*.entitlements; do
        ! grep -q temporary-exception "$entitlements" || fail "$entitlements has a temporary exception"
    done
}

# Checks the built app: no Sparkle, no updater keys, no process launching, no temporary exceptions,
# and no license or update text in its string tables. Provisioning profiles aren't checked here: the
# archive is signed for development, which gives extensions without capabilities none, and the
# export signs every bundle again with a distribution profile.
check_archive() {
    set -- "$1"/Products/Applications/*.app
    [ -d "$1" ] || fail "no app in the archive"
    app="$1"
    [ -z "$(find "$app" -iname '*sparkle*' | head -1)" ] || fail "the archive contains Sparkle: $(find "$app" -iname '*sparkle*' | head -1)"
    keys="$(plutil -convert json -o - "$app/Contents/Info.plist" \
        | python3 -c 'import json, sys; print(" ".join(k for k in json.load(sys.stdin) if k.startswith("SU")))')"
    [ -z "$keys" ] || fail "Info.plist has Sparkle keys: $keys"
    for bundle in "$app" "$app"/Contents/PlugIns/*.appex "$app"/Contents/Extensions/*.appex; do
        [ -d "$bundle" ] || continue
        executable="$bundle/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
        symbols="$(nm -u "$executable" | grep -E '_OBJC_CLASS_\$_NSTask$|_posix_spawnp?$' | sort -u | tr '\n' ' ')"
        [ -z "$symbols" ] || fail "$(basename "$bundle") launches processes: $symbols"
        entitlements="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null)" || fail "$(basename "$bundle") isn't signed"
        case "$entitlements" in
            *temporary-exception*) fail "$(basename "$bundle") has a temporary-exception entitlement" ;;
        esac
    done
    found="$(find "$app" -path '*.lproj/*' -name '*.strings' -exec sh -c \
        'plutil -convert json -o - "$1" | grep -Eio "sponsor|license key|krz\.sh|check for updates" | sed "s|^|$1: |"' _ {} \; | head -1)"
    [ -z "$found" ] || fail "the app has Developer ID text: $found"
}

# appstore-kit has no step between archiving and exporting, so its export call checks the archive first.
xcodebuild() {
    if [ "$1" = -exportArchive ] && [ "$2" = -archivePath ]; then
        check_archive "$3"
    fi
    command xcodebuild "$@"
}
. "${APPSTORE_KIT:-$(dirname "$0")/../../appstore-kit}/release-ios.sh"
