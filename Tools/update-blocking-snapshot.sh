#!/bin/sh
# Refreshes the EasyList and EasyPrivacy copies bundled in Packages/Blocking, which first launch
# compiles before any download. Run before a release, then `cd Packages/Blocking && swift test`.
set -eu

dir="$(cd "$(dirname "$0")/.." && pwd)/Packages/Blocking/Sources/Blocking/Snapshot"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for name in easylist easyprivacy; do
    curl -fsSL --max-time 120 -o "$tmp/$name.txt" "https://easylist.to/easylist/$name.txt"
    if ! head -1 "$tmp/$name.txt" | grep -q '^\[Adblock'; then
        echo "$name: the download isn't a filter list" >&2
        exit 1
    fi
done
for name in easylist easyprivacy; do
    mv "$tmp/$name.txt" "$dir/$name.txt"
    printf '%s: %s, %s bytes\n' "$name" "$(grep -m1 '^! Version:' "$dir/$name.txt")" "$(wc -c < "$dir/$name.txt" | tr -d ' ')"
done
