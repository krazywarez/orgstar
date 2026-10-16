#!/bin/sh
# Archives the iOS app (with its extensions and the watch app) and uploads it to App Store
# Connect for TestFlight, signed automatically with the team's distribution certificate through
# the Apple ID signed in to Xcode. The version is the project's MARKETING_VERSION; the build
# number is the commit count, as the Mac release's is. Run after scripts/release-mac.sh.
# Usage: scripts/release-ios.sh
#   ORGSTAR_PUBLISH  0 archives and exports the .ipa to .build/ios-release without uploading
set -eu

cd "$(dirname "$0")/.."
publish="${ORGSTAR_PUBLISH:-1}"
team=ZCNAX3VL9D
project=ios/Orgstar.xcodeproj

if [ "$publish" != 0 ]; then
    [ -z "$(git status --porcelain)" ] || { echo "The working tree has changes." >&2; exit 1; }
    [ "$(git branch --show-current)" = main ] || { echo "Release from main." >&2; exit 1; }
fi

version="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$project/project.pbxproj" | sort -u)"
[ "$(printf '%s\n' "$version" | wc -l | tr -d ' ')" = 1 ] || { echo "The targets' MARKETING_VERSION differ: $version" >&2; exit 1; }
build="$(git rev-list --count HEAD)"

out=.build/ios-release
rm -rf "${out:?}"
mkdir -p "$out"
archive="$out/orgstar.xcarchive"
# xcodebuild rewrites the project file in its own key order; the copy puts it back as it was.
cp "$project/project.pbxproj" "$out/project.pbxproj"
trap 'cp "$out/project.pbxproj" "$project/project.pbxproj"' EXIT
xcodebuild archive -project "$project" -scheme "Orgstar iOS" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates -quiet \
    CURRENT_PROJECT_VERSION="$build"

if [ "$publish" = 0 ]; then destination=export; else destination=upload; fi
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
    -exportPath "$out/export" -allowProvisioningUpdates -quiet

if [ "$publish" = 0 ]; then
    echo "Exported $(ls "$out"/export/*.ipa): $version ($build), not uploaded"
else
    echo "Uploaded orgstar $version ($build) to App Store Connect; it shows in TestFlight once processed"
fi
