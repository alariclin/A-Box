#!/usr/bin/env bash
# Upload previous-version rollback binaries to the core-binaries Release.
# Run this on a machine with `gh` authenticated (gh auth login).
# It uploads the 8 staged files and appends their SHA256 lines to the
# Release's SHA256SUMS asset. Idempotent: skips files already present
# with matching digest; aborts on any digest conflict.
set -euo pipefail
shopt -s nullglob

REPO="alariclin/a-box"
TAG="core-binaries"
STAGE="${1:-./mirror-staging}"

[[ -d "$STAGE" ]] || { echo "staging dir not found: $STAGE"; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Expected exact file set (A-03 fix: refuse extras, N-10 fix: nullglob safe).
expected=(
    "Xray-v26.6.27-linux-64.zip"
    "Xray-v26.6.27-linux-arm64-v8a.zip"
    "sing-box-1.14.1-linux-amd64-glibc.tar.gz"
    "sing-box-1.14.1-linux-amd64-musl.tar.gz"
    "sing-box-1.14.1-linux-arm64-glibc.tar.gz"
    "sing-box-1.14.1-linux-arm64-musl.tar.gz"
    "hysteria-app-v2.12.3-linux-amd64"
    "hysteria-app-v2.12.3-linux-arm64"
)

echo "[*] Checking staging file set..."
# P1-05 fix 2026-10-14: reject symlinks to prevent staging-escape upload.
for name in "${expected[@]}"; do
    [[ -f "$STAGE/$name" && ! -L "$STAGE/$name" ]] || { echo "missing or symlink: $name; aborting"; exit 1; }
done
# P1-05: reject any symlink in staging directory
if [[ -n "$(find "$STAGE" -maxdepth 1 -type l)" ]]; then
    echo "symlinks found in staging; aborting"
    find "$STAGE" -maxdepth 1 -type l -printf '  %f -> %l\n'
    exit 1
fi
# A-03 fix: refuse any staged file not in the expected set / manifest.
staged_count=$(find "$STAGE" -maxdepth 1 -type f ! -name 'SHA256SUMS.staging' | wc -l)
if (( staged_count != ${#expected[@]} )); then
    echo "staging contains unexpected extra files (found $staged_count, expected ${#expected[@]}); aborting"
    find "$STAGE" -maxdepth 1 -type f -printf '  %f\n'
    exit 1
fi

echo "[*] Existing assets in $TAG:"
existing_json="$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[] | "\(.name) \(.digest // "")"')"
echo "$existing_json" | cut -d' ' -f1

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Verify staging checksums BEFORE any upload.
echo "[*] Verifying staged files against SHA256SUMS.staging..."
(cd "$STAGE" && sha256sum -c SHA256SUMS.staging) || { echo "staging verification failed; aborting (nothing uploaded)"; exit 1; }
# P1-04 fix 2026-10-14: manifest must list exactly the expected files, no more, no less.
echo "[*] Verifying manifest covers exactly the expected file set..."
manifest_files=$(awk '{print $2}' "$STAGE/SHA256SUMS.staging" | sort)
expected_files=$(printf '%s\n' "${expected[@]}" | sort)
if [[ "$manifest_files" != "$expected_files" ]]; then
    echo "manifest file set does not match expected set; aborting"
    echo "--- manifest ---"
    echo "$manifest_files"
    echo "--- expected ---"
    echo "$expected_files"
    exit 1
fi
echo "[*] Manifest coverage verified." 

# P2-01 fix 2026-10-14: check remote SHA256SUMS for conflicts BEFORE uploading.
# This prevents uploading a binary when the manifest already has a different hash.
echo "[*] Pre-checking remote SHA256SUMS for conflicts..."
tmp2="$(mktemp -d)"; trap 'rm -rf "$tmp" "$tmp2"' EXIT
gh release download "$TAG" --repo "$REPO" -p "SHA256SUMS" -D "$tmp2" 2>/dev/null     || { echo "SHA256SUMS not found in release; aborting (refusing to create from scratch)"; exit 1; }
while read -r sum name _; do
    [[ -n "${sum:-}" && -n "${name:-}" ]] || continue
    staging_sum=$(awk -v n="$name" '$2 == n { print $1; exit }' "$STAGE/SHA256SUMS.staging" || true)
    if [[ -n "$staging_sum" && "$staging_sum" != "$sum" ]]; then
        echo "[CONFLICT] Remote SHA256SUMS has $name with different hash:"
        echo "  remote:  $sum"
        echo "  staging: $staging_sum"
        echo "Aborting before any upload."
        exit 1
    fi
done < "$tmp2/SHA256SUMS"

# 1. Upload binaries (skip if already present WITH MATCHING DIGEST).
# F-03 fix: compare GitHub asset digest with staging SHA-256; conflict aborts.
for name in "${expected[@]}"; do
    f="$STAGE/$name"
    staging_sum=$(sha256sum "$f" | cut -d' ' -f1)
    existing_line=$(grep -F -- "$name " <<< "$existing_json" || true)
    if [[ -n "$existing_line" ]]; then
        # GitHub digest is "sha256:<hex>"; extract hex part.
        remote_digest=$(awk '{print $2}' <<< "$existing_line" | sed 's/^sha256://')
        if [[ "$remote_digest" == "$staging_sum" ]]; then
            echo "[skip] $name already in release with matching digest"
            continue
        else
            echo "[CONFLICT] $name exists in release with DIFFERENT digest:"
            echo "  remote:  $remote_digest"
            echo "  staging: $staging_sum"
            echo "Aborting; resolve manually (delete remote asset or fix staging)."
            exit 1
        fi
    fi
    echo "[upload] $name"
    gh release upload "$TAG" "$f" --repo "$REPO" --clobber
done

# 2. Merge SHA256SUMS (fail closed on hash mismatch for existing entries).
# NOTE: not safe for concurrent runs; run once at a time.
echo "[*] Merging SHA256SUMS..."
gh release download "$TAG" --repo "$REPO" -p "SHA256SUMS" -D "$tmp" 2>/dev/null \
    || { echo "SHA256SUMS not found in release; aborting (refusing to create from scratch)"; exit 1; }
cp "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.new"
while read -r sum name _; do
    [[ -n "${sum:-}" && -n "${name:-}" ]] || continue
    [[ "$sum" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo "invalid hash for $name; aborting"; exit 1; }
    existing_sum=$(awk -v n="$name" '$2 == n { print $1; exit }' "$tmp/SHA256SUMS.new" || true)
    if [[ -n "$existing_sum" ]]; then
        # F-03 fix: same name must have same hash, else conflict.
        if [[ "$existing_sum" != "$sum" ]]; then
            echo "[CONFLICT] SHA256SUMS already has $name with different hash:"
            echo "  release: $existing_sum"
            echo "  staging: $sum"
            echo "Aborting."
            exit 1
        fi
    else
        echo "$sum  $name" >> "$tmp/SHA256SUMS.new"
    fi
done < "$STAGE/SHA256SUMS.staging"

if cmp -s "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.new"; then
    echo "[skip] SHA256SUMS already up to date"
else
    echo "[upload] SHA256SUMS ($(wc -l < "$tmp/SHA256SUMS.new") lines)"
    gh release upload "$TAG" "$tmp/SHA256SUMS.new#SHA256SUMS" --repo "$REPO" --clobber
fi

echo "[done] Verify at: https://github.com/$REPO/releases/tag/$TAG"
