#!/bin/sh
# Adds a release to the Sparkle appcast, newest first: signs the DMG with the EdDSA key in the
# keychain (sign_update, from the Sparkle package in .build/artifacts) and writes the item.
# Usage: scripts/appcast-add.sh <appcast.xml> <version> <build> <dmg> <notes-file>
set -eu

appcast="${1:?usage: appcast-add.sh <appcast.xml> <version> <build> <dmg> <notes-file>}"
version="${2:?version}"
build="${3:?build}"
dmg="${4:?dmg}"
notes="${5:?notes-file}"
cd "$(dirname "$0")/.."

! grep -q "<sparkle:shortVersionString>$version<" "$appcast" || { echo "$appcast already has $version." >&2; exit 1; }
# SIGN_UPDATE names another signer, for a dry run without the key.
sign_update="${SIGN_UPDATE:-$(find .build/artifacts -path '*/Sparkle/bin/sign_update' | head -1)}"
[ -n "$sign_update" ] || { echo "sign_update not in .build/artifacts; swift build fetches Sparkle." >&2; exit 1; }
signature="$("$sign_update" "$dmg")"   # sparkle:edSignature="..." length="..."
date="$(LC_ALL=C date -R)"
name="$(basename "$dmg")"

item="$(mktemp)"
{
    echo "    <item>"
    echo "      <title>orgstar $version</title>"
    echo "      <link>https://gitbay.org/krz/orgstar/releases/tag/v$version</link>"
    echo "      <sparkle:version>$build</sparkle:version>"
    echo "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>"
    echo "      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>"
    echo "      <pubDate>$date</pubDate>"
    echo "      <description><![CDATA[$(cat "$notes")]]></description>"
    echo "      <enclosure url=\"https://gitbay.org/krz/orgstar/releases/download/v$version/$name\" type=\"application/octet-stream\" $signature/>"
    echo "    </item>"
} > "$item"
# After the channel's <link>, so the newest release comes first.
awk -v item="$item" 'BEGIN { done = 0 } { print } /<\/link>/ && !done { while ((getline line < item) > 0) print line; done = 1 }' "$appcast" > "$appcast.new"
mv "$appcast.new" "$appcast"
rm -f "$item"
xmllint --noout "$appcast"
echo "$appcast: added $version"
