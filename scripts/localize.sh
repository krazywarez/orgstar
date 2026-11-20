#!/bin/sh
# Compiles l10n/Localizable.xcstrings into the .lproj folders of each bundle folder given (an
# app's Contents/Resources, an iOS app or extension folder). English is the source language:
# its folder is empty, so the keys show as they are. With --developer-id, the DeveloperID table
# too: the license and update strings, which only the Developer ID Mac app shows.
# Usage: scripts/localize.sh [--developer-id] <folder>...
set -eu

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
xcrun xcstringstool compile l10n/Localizable.xcstrings --output-directory "$work" > /dev/null
if [ "${1:-}" = --developer-id ]; then
    shift
    xcrun xcstringstool compile l10n/DeveloperID.xcstrings --output-directory "$work" > /dev/null
fi
mkdir -p "$work/en.lproj"
for folder in "$@"; do
    for lproj in "$work"/*.lproj; do
        rm -rf "$folder/$(basename "$lproj")"
        cp -R "$lproj" "$folder/"
    done
done
rm -rf "$work"
