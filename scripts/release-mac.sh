#!/bin/sh
# Builds, signs, notarizes and publishes a Mac release: a universal orgstar.app in a DMG,
# uploaded to the tag's gitbay release, and the cask in krz/homebrew-tap updated.
# Usage: scripts/release-mac.sh <version>   e.g. 0.2.0, for the tag v0.2.0 on HEAD
#   ORGSTAR_SIGN     Developer ID Application identity (default: the keychain's only one)
#   ORGSTAR_NOTARY   notarytool keychain profile (default: orgstar)
#   ORGSTAR_TAP      the homebrew-tap checkout (default: ../homebrew-tap)
#   ORGSTAR_PUBLISH  0 builds and notarizes without tagging, uploading or touching the tap
#   ORGSTAR_NOTES    an HTML file of release notes for the appcast entry, which Sparkle's
#                    update window shows; the platform line is added after it
#   ORGSTAR_RELEASE_NOTES  a Markdown file of release notes for the gitbay release
#   ORGSTAR_ED_PUBLIC_KEY  the Sparkle public key (default: the one whose private half is in the
#                    release Mac's login keychain, from generate_keys); passed on to build-app.sh
#
# Updates: after the DMG is uploaded, the release goes into docs/manual/appcast.xml through a
# merge request on main, and the manual is published, which serves the appcast.
set -eu

cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release-mac.sh <version>}"
tag="v$version"
notary="${ORGSTAR_NOTARY:-orgstar}"
tap="${ORGSTAR_TAP:-../homebrew-tap}"
publish="${ORGSTAR_PUBLISH:-1}"
sign="${ORGSTAR_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -n "$sign" ] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
# The Sparkle public key; its private half is in the release Mac's login keychain (generate_keys).
export ORGSTAR_ED_PUBLIC_KEY="${ORGSTAR_ED_PUBLIC_KEY:-StvsRDaDoGd4S/G66l7XHAcd3KPlpJlu0Gsv9GemsSo=}"
notes="Universal (Apple silicon and Intel), macOS 26 or later. Notarized."
for file in "${ORGSTAR_NOTES:-}" "${ORGSTAR_RELEASE_NOTES:-}"; do
    [ -z "$file" ] || [ -f "$file" ] || { echo "No notes file $file." >&2; exit 1; }
done

if [ "$publish" != 0 ]; then
    [ -z "$(git status --porcelain)" ] || { echo "The working tree has changes." >&2; exit 1; }
    [ "$(git branch --show-current)" = main ] || { echo "Release from main." >&2; exit 1; }
fi

# The build number counts commits, so each release's is higher than the last's.
build="$(git rev-list --count HEAD)"
ORGSTAR_SIGN="$sign" ORGSTAR_ARCHS="arm64 x86_64" sh scripts/build-app.sh "$version" "$build" > /dev/null
app=".build/app/orgstar.app"
codesign --verify --strict --deep "$app"

out=".build/release"
dmg="$out/orgstar-$version.dmg"
rm -rf "${out:?}"
mkdir -p "$out/dmg"
ditto "$app" "$out/dmg/orgstar.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname "orgstar $version" -srcfolder "$out/dmg" -format UDZO -fs HFS+ "$dmg"
codesign --sign "$sign" --timestamp "$dmg"

# Notarizing the DMG covers the app inside it; stapling both lets them open offline.
xcrun notarytool submit "$dmg" --keychain-profile "$notary" --wait
xcrun stapler staple "$dmg"
xcrun stapler staple "$app"
spctl --assess --type open --context context:primary-signature -v "$dmg"
sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo "$dmg $sha"
if [ -n "${ORGSTAR_NOTES:-}" ]; then
    { cat "$ORGSTAR_NOTES"; printf '<p>%s</p>\n' "$notes"; } > "$out/notes.txt"
else
    printf '%s\n' "$notes" > "$out/notes.txt"
fi

if [ "$publish" = 0 ]; then
    # The appcast entry on a copy, so a dry run shows the signature.
    cp docs/manual/appcast.xml "$out/appcast.xml"
    sh scripts/appcast-add.sh "$out/appcast.xml" "$version" "$build" "$dmg" "$out/notes.txt"
    exit 0
fi

git tag -s "$tag" -m "orgstar $version"
git push origin "$tag"
if [ -n "${ORGSTAR_RELEASE_NOTES:-}" ]; then
    { cat "$ORGSTAR_RELEASE_NOTES"; printf '\n%s\n' "$notes"; } | gitbay release create krz/orgstar "$tag" --title "orgstar $version" --file -
else
    gitbay release create krz/orgstar "$tag" --title "orgstar $version" --notes "$notes"
fi
gitbay release asset add krz/orgstar "$tag" "orgstar-$version.dmg" < "$dmg"

# The appcast goes in through a merge request, as every change to main does, after the DMG
# it points at is up; then the manual, which serves it, is published.
branch="appcast-$version"
git switch -q -c "$branch"
sh scripts/appcast-add.sh docs/manual/appcast.xml "$version" "$build" "$dmg" "$out/notes.txt"
git add docs/manual/appcast.xml
git commit -q -m "Appcast for $version"
git push -q -u origin "$branch"
mr="$(gitbay mr create --source "$branch" --target main --title "Appcast for $version" --body "Sparkle entry for orgstar $version." --json | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
gitbay mr merge "$mr" --strategy ff
git switch -q main
git pull -q --ff-only
git branch -d "$branch"
git push -q origin --delete "$branch"
sh scripts/publish-docs.sh

# The cask goes in through a merge request, as every change to the tap's main does.
branch="orgstar-$version"
git -C "$tap" switch -q main
git -C "$tap" pull -q --ff-only
git -C "$tap" switch -q -c "$branch"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" packaging/orgstar.rb > "$tap/Casks/orgstar.rb"
git -C "$tap" add Casks/orgstar.rb
git -C "$tap" commit -q -m "orgstar $version"
git -C "$tap" push -q -u origin "$branch"
mr="$(cd "$tap" && gitbay mr create --source "$branch" --target main --title "orgstar $version" --body "Cask for orgstar $version." --json | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
(cd "$tap" && gitbay mr merge "$mr" --strategy ff)
git -C "$tap" switch -q main
git -C "$tap" pull -q --ff-only
git -C "$tap" branch -d "$branch"
git -C "$tap" push -q origin --delete "$branch"
echo "Released $tag; cask merged in krz/homebrew-tap!$mr"
