#!/bin/sh
# Brings l10n/Localizable.xcstrings and l10n/DeveloperID.xcstrings (the strings with that table,
# which only the Developer ID Mac app shows) up to date with the strings the apps show: builds the Mac, Mac
# App Store and iOS targets with SWIFT_EMIT_LOC_STRINGS and syncs the catalog from their .stringsdata
# files.
# New strings are added, ones no longer used are marked stale; translations are kept.
# Command titles come from Sources/OrgApp/CommandTitles.swift, which CommandTitleTests keeps current.
set -eu

cd "$(dirname "$0")/.."
catalog=l10n/Localizable.xcstrings
mac=.build/loc-mac
ios=.build/loc-ios
mas=.build/loc-mas

for scheme in Orgstar OrgstarWidgets; do
    xcodebuild -scheme "$scheme" -destination 'platform=macOS' -derivedDataPath "$mac" build -quiet SWIFT_EMIT_LOC_STRINGS=YES
done
# The App Store targets compile Sources/Orgstar and Sources/OrgstarWidgets with APPSTORE, which
# shows strings the SwiftPM schemes don't.
xcodebuild -project ios/Orgstar.xcodeproj -scheme 'Orgstar macOS' -destination 'generic/platform=macOS' -derivedDataPath "$mas" \
    build -quiet SWIFT_EMIT_LOC_STRINGS=YES CODE_SIGNING_ALLOWED=NO
for scheme in OrgstarMobile OrgstarShare OrgstarWidgets; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ios" build -quiet SWIFT_EMIT_LOC_STRINGS=YES
done
for scheme in OrgstarWatch OrgstarWatchWidgets; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$ios" build -quiet SWIFT_EMIT_LOC_STRINGS=YES
done

[ -f "$catalog" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$catalog"
find "$mac" "$ios" -path '*/arm64/*' -name '*.stringsdata' \
    | grep -E '/(Orgstar|OrgstarMobile|OrgstarWidgets|OrgstarShare|OrgstarWatch|OrgstarWatchWidgets)-p\.build/|/(OrgApp|OrgPresentation|OrgEditorAppKit)-t?\.build/' \
    > "$mac/stringsdata.txt"
find "$mas" -path '*/arm64/*' -name '*.stringsdata' | grep -E '/(Orgstar macOS|OrgstarWidgets)\.build/' >> "$mac/stringsdata.txt"
# The App Store target's folder name has a space, so the list is read a line at a time.
set --
while IFS= read -r file; do set -- "$@" "$file"; done < "$mac/stringsdata.txt"
for catalog in "$catalog" l10n/DeveloperID.xcstrings; do
    xcrun xcstringstool sync "$catalog" --stringsdata "$@"
    # xcstringstool writes its own spacing; the committed catalog is Python's sorted JSON.
    python3 -c "import json, sys; p = sys.argv[1]; d = json.load(open(p)); open(p, 'w').write(json.dumps(d, indent=2, ensure_ascii=False, sort_keys=True) + '\n')" "$catalog"
    echo "$(python3 -c "import json; print(len(json.load(open('$catalog'))['strings']))") strings in $catalog"
done
