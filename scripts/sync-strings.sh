#!/bin/sh
# Brings l10n/Localizable.xcstrings up to date with the strings the apps show: builds the Mac and
# iOS targets with SWIFT_EMIT_LOC_STRINGS and syncs the catalog from their .stringsdata files.
# New strings are added, ones no longer used are marked stale; translations are kept.
set -eu

cd "$(dirname "$0")/.."
catalog=l10n/Localizable.xcstrings
mac=.build/loc-mac
ios=.build/loc-ios

for scheme in Orgstar OrgstarWidgets; do
    xcodebuild -scheme "$scheme" -destination 'platform=macOS' -derivedDataPath "$mac" build -quiet SWIFT_EMIT_LOC_STRINGS=YES
done
for scheme in OrgstarMobile OrgstarShare OrgstarWidgets; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ios" build -quiet SWIFT_EMIT_LOC_STRINGS=YES
done

[ -f "$catalog" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$catalog"
find "$mac" "$ios" -path '*/arm64/*' -name '*.stringsdata' \
    | grep -E '/(Orgstar|OrgstarMobile|OrgstarWidgets|OrgstarShare)-p\.build/|/(OrgApp|OrgPresentation|OrgEditorAppKit)-t?\.build/' \
    > "$mac/stringsdata.txt"
# shellcheck disable=SC2046
xcrun xcstringstool sync "$catalog" --stringsdata $(tr '\n' ' ' < "$mac/stringsdata.txt")
echo "$(python3 -c "import json; print(len(json.load(open('$catalog'))['strings']))") strings in $catalog"
