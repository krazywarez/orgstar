#!/bin/sh
# Builds the user manual in docs/manual with orgo and force-pushes it to the `pages`
# branch, which gitbay serves at https://krz.gitbay.page/orgstar/.
# Usage: scripts/publish-docs.sh [--dry-run]
set -eu

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
site="$tmp/site"

orgo build docs/manual -o "$site" --strict --no-cache
rm -f "$site/.orgo-cache.json"

if [ "${1:-}" = "--dry-run" ]; then
	echo "built $(find "$site" -name '*.html' | wc -l | tr -d ' ') pages; not published"
	exit 0
fi

# The pages branch holds only the built site, replaced on each publish.
sha=$(git rev-parse --short HEAD)
git init -q "$tmp/work"
cp -R "$site/." "$tmp/work/"
git -C "$tmp/work" add -A
git -C "$tmp/work" commit -q -m "Publish the manual from $sha"
git -C "$tmp/work" push -q --force "$(git remote get-url origin)" HEAD:refs/heads/pages
echo "published the manual from $sha"
