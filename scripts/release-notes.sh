#!/usr/bin/env bash
# Prints Markdown release notes for TAG from the commit subjects since the
# previous version tag, grouped by conventional-commit type.
#
# Usage: scripts/release-notes.sh v0.2.0 [owner/repo]
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="$1"
REPO="${2:-}"
PREV="$(git describe --tags --abbrev=0 --match 'v*.*.*' "$TAG^" 2>/dev/null || true)"
RANGE="${PREV:+$PREV..}$TAG"

section() {
    local title="$1" pattern="$2" strip="$3" lines
    lines="$(git log --no-merges --format='%s (%h)' "$RANGE" | grep -E "$pattern" | sed -E "s/$strip/- /" || true)"
    if [[ -n "$lines" ]]; then
        printf '## %s\n\n%s\n\n' "$title" "$lines"
    fi
}

# The type prefix is dropped where the heading already says it.
section "Features" '^feat(\(|!|:)' '^[a-z]+(\([^)]*\))?!?: *'
section "Fixes" '^fix(\(|!|:)' '^[a-z]+(\([^)]*\))?!?: *'
section "Other changes" '^(build|ci|docs|perf|refactor|chore|test|style)(\(|!|:)' '^'

# Commits that don't follow the conventional format.
other="$(git log --no-merges --format='%s (%h)' "$RANGE" | grep -vE '^[a-z]+(\([^)]*\))?!?:' | sed 's/^/- /' || true)"
if [[ -n "$other" ]]; then
    printf '## Uncategorized\n\n%s\n\n' "$other"
fi

if [[ -n "$PREV" && -n "$REPO" ]]; then
    printf '**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG"
fi
