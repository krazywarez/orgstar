#!/bin/sh
# Builds the user manual in docs/manual with orgo, with the third-party notices as a page, and
# copies it to files.krz.sh/orgstar/, next to the DMGs. While krz/orgstar is public it also
# force-pushes it to the `pages` branch, which gitbay serves at https://krz.gitbay.site/orgstar/:
# installs from before 1.0.0 read their appcast there.
# Usage: scripts/publish-docs.sh [--dry-run]
#   ORGSTAR_FILES  rsync destination (default: homelab:/var/www/files/orgstar)
set -eu

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
site="$tmp/site"

files="${ORGSTAR_FILES:-homelab:/var/www/files/orgstar}"
src="$tmp/manual"
cp -R docs/manual "$src"
cp THIRD_PARTY.org "$src/third-party.org"
orgo build "$src" -o "$site" --strict --no-cache
rm -f "$site/.orgo-cache.json"

if [ "${1:-}" = "--dry-run" ]; then
	echo "built $(find "$site" -name '*.html' | wc -l | tr -d ' ') pages; not published"
	exit 0
fi

# --delete keeps the copy exact, apart from the DMGs that release-mac.sh puts beside it.
rsync -a --delete --exclude '*.dmg' "$site/" "$files/"
echo "published the manual to $files"

visibility=$(gitbay repo show krz/orgstar --json | sed -n 's/.*"visibility":"\([a-z]*\)".*/\1/p')
[ "$visibility" = public ] || exit 0
# The pages branch holds only the built site, replaced on each publish.
sha=$(git rev-parse --short HEAD)
git init -q "$tmp/work"
cp -R "$site/." "$tmp/work/"
git -C "$tmp/work" add -A
git -C "$tmp/work" commit -q -m "Publish the manual from $sha"
git -C "$tmp/work" push -q --force "$(git remote get-url origin)" HEAD:refs/heads/pages
echo "published the manual from $sha"
