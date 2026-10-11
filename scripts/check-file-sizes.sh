#!/bin/sh
# Lists hand-written Swift files over 1,000 lines and exits 1 when there are any.
# Generated files (scripts/update-char-fold.sh, scripts/update-highlight-queries.sh) are exempt.
# Usage: scripts/check-file-sizes.sh
set -eu
cd "$(dirname "$0")/.."
limit=1000
over="$(find Sources -name '*.swift' \
    ! -path 'Sources/OrgCore/Keymap/CharFold.swift' ! -path 'Sources/OrgHighlight/Queries.swift' \
    -exec wc -l {} + | awk -v limit="$limit" '$2 != "total" && $1 > limit { printf "%6d %s\n", $1, $2 }')"
[ -z "$over" ] || { echo "Swift files over $limit lines:"; echo "$over"; exit 1; }
echo "No hand-written Swift file over $limit lines."
