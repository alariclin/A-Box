#!/bin/bash
# CORE-VERSIONS completeness gate (R1-19-F02).
# Usage: verify-core-versions-gate.sh [verified-dir] (default: verified)
# The publish job previously checked only the 5 version tags, so a
# list missing an asset record, a record pointing at a missing file,
# or a file with no record was still signed and published. This gate
# runs BEFORE signing and fails closed on all three gaps:
#  1. Completeness: every required key present and non-empty.
#  2. Forward: every asset record points at a file in the dir.
#  3. Reverse: every non-metadata file is referenced by a record.
# Exit 0 on pass, 1 with an ERROR line on any gap.
set -euo pipefail
dir="${1:-verified}"
[[ -f "$dir/CORE-VERSIONS" ]] || { echo "ERROR: $dir/CORE-VERSIONS missing"; exit 1; }
required='schema updated_at_utc Xray Xray-amd64 Xray-arm64 sing-box sing-box-amd64-glibc sing-box-amd64-musl sing-box-arm64-glibc sing-box-arm64-musl Hysteria Hysteria-amd64 Hysteria-arm64 cloudflared cloudflared-amd64 cloudflared-arm64 wgcf wgcf-amd64 wgcf-arm64'
get() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$dir/CORE-VERSIONS"; }
for key in $required; do
  [[ -n "$(get "$key")" ]] || { echo "ERROR: CORE-VERSIONS missing or empty record: $key"; exit 1; }
done
[[ "$(get schema)" == 1 ]] || { echo "ERROR: CORE-VERSIONS schema is $(get schema), expected 1"; exit 1; }
assets='Xray-amd64 Xray-arm64 sing-box-amd64-glibc sing-box-amd64-musl sing-box-arm64-glibc sing-box-arm64-musl Hysteria-amd64 Hysteria-arm64 cloudflared-amd64 cloudflared-arm64 wgcf-amd64 wgcf-arm64'
for key in $assets; do
  val="$(get "$key")"
  [[ -f "$dir/$val" ]] || { echo "ERROR: CORE-VERSIONS record $key=$val has no file in $dir/"; exit 1; }
done
for f in "$dir"/*; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  case "$base" in CORE-VERSIONS|SHA256SUMS|SHA256SUMS.incoming|*.sig) continue;; esac
  awk -F= -v b="$base" '$2 == b {found=1} END {exit !found}' "$dir/CORE-VERSIONS" || { echo "ERROR: file $base in $dir/ has no CORE-VERSIONS record"; exit 1; }
done
echo "OK: CORE-VERSIONS complete (forward + reverse coverage pass)"
