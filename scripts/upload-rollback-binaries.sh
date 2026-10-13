#!/usr/bin/env bash
# Upload previous-version rollback binaries to the core-binaries Release.
# Run this on a machine with `gh` authenticated (gh auth login).
# It uploads the 8 staged files and appends their SHA256 lines to the
# Release's SHA256SUMS asset. Idempotent: skips files already present.
set -euo pipefail

REPO="alariclin/a-box"
TAG="core-binaries"
STAGE="${1:-./mirror-staging}"

[[ -d "$STAGE" ]] || { echo "staging dir not found: $STAGE"; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

echo "[*] Existing assets in $TAG:"
existing="$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name')"
echo "$existing"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1. Upload binaries (skip if already present)
for f in "$STAGE"/Xray-v26.6.27-linux-*.zip \
         "$STAGE"/sing-box-1.14.1-linux-*.tar.gz \
         "$STAGE"/hysteria-app-v2.12.3-linux-*; do
    name="$(basename "$f")"
    if grep -qxF "$name" <<< "$existing"; then
        echo "[skip] $name already in release"
    else
        echo "[upload] $name"
        gh release upload "$TAG" "$f" --repo "$REPO" --clobber
    fi
done

# 2. Merge SHA256SUMS
echo "[*] Merging SHA256SUMS..."
gh release download "$TAG" --repo "$REPO" -p "SHA256SUMS" -D "$tmp" 2>/dev/null \
    || { echo "SHA256SUMS not found in release; aborting (refusing to create from scratch)"; exit 1; }
cp "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.new"
while read -r sum name _; do
    [[ -n "${sum:-}" && -n "${name:-}" ]] || continue
    grep -qF "  $name" "$tmp/SHA256SUMS.new" || echo "$sum  $name" >> "$tmp/SHA256SUMS.new"
done < "$STAGE/SHA256SUMS.staging"

if cmp -s "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.new"; then
    echo "[skip] SHA256SUMS already up to date"
else
    echo "[upload] SHA256SUMS ($(wc -l < "$tmp/SHA256SUMS.new") lines)"
    gh release upload "$TAG" "$tmp/SHA256SUMS.new#SHA256SUMS" --repo "$REPO" --clobber
fi

echo "[done] Verify at: https://github.com/$REPO/releases/tag/$TAG"
