#!/bin/sh
# Compiles l10n/Localizable.xcstrings into the .lproj folders of each bundle folder given (an
# app's Contents/Resources, an iOS app or extension folder). English is the source language:
# its folder is empty, so the keys show as they are.
# Usage: scripts/localize.sh <folder>...
set -eu

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
xcrun xcstringstool compile l10n/Localizable.xcstrings --output-directory "$work" > /dev/null
mkdir -p "$work/en.lproj"
for folder in "$@"; do
    for lproj in "$work"/*.lproj; do
        rm -rf "$folder/$(basename "$lproj")"
        cp -R "$lproj" "$folder/"
    done
done
rm -rf "$work"
