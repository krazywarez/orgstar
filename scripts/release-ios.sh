#!/bin/sh
# Archives the iOS app (with its extensions and the watch app) and uploads it to App Store
# Connect for TestFlight. The version is the project's MARKETING_VERSION; the build number is the
# commit count, as the Mac release's is. Run after scripts/release-mac.sh. The work is done by
# appstore-kit, checked out beside this repository or at $APPSTORE_KIT.
# Usage: scripts/release-ios.sh
#   ORGSTAR_PUBLISH  0 archives and exports the .ipa to .build/ios-release without uploading
PUBLISH="${ORGSTAR_PUBLISH:-1}"
name=orgstar
project=ios/Orgstar.xcodeproj
scheme="Orgstar iOS"
. "${APPSTORE_KIT:-$(dirname "$0")/../../appstore-kit}/release-ios.sh"
