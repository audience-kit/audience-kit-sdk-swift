#!/usr/bin/env bash
# Fails when the SDK's sources changed since BASE but its version didn't. Apps send the SDK version with every call,
# and the AudienceKit API refuses ones older than its minimum, so each change needs its own version.
#
#   scripts/check-version.sh origin/main
set -euo pipefail

base="${1:-origin/main}"
version_file=Sources/AudienceCore/AudienceKitSDK.swift

if git diff --quiet "$base"...HEAD -- Sources; then
    echo "The SDK's sources are unchanged."
    exit 0
fi

version() { git show "$1:$version_file" 2>/dev/null | grep -Eo '"[0-9]+(\.[0-9]+)+"' | head -1 | tr -d '"' || true; }
before="$(version "$(git merge-base "$base" HEAD)")"
after="$(version HEAD)"
if [[ -z "$before" ]]; then
    echo "The SDK is new at $after."
    exit 0
fi
if [[ "$before" == "$after" ]]; then
    echo "The SDK changed but is still $after: bump the version in $version_file." >&2
    exit 1
fi
echo "The SDK changed, and went from $before to $after."
