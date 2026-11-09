#!/usr/bin/env bash
# Prune superseded old-version assets from the core-binaries Release.
# Shared by the direct publish path (scripts/update-core-mirror.sh) and
# the workflow publish job (.github/workflows/update-core-mirror.yml).
# C2 (Q6 / GPT D8), 2026-11-09.
#
# Publish order (both paths): upload + verify new data assets ->
# publish + verify the new metadata pair (CORE-VERSIONS / SHA256SUMS) ->
# prune superseded old assets (this script) -> verify the final set.
# Never delete old assets before the new ones are uploaded and verified.
# A prune failure does NOT roll the manifest back: the new version stays
# current; the run reports "new version published, cleanup incomplete"
# and a re-run continues deleting from the current list.
#
# Delete rule -- an old asset is deleted only when ALL hold:
#   * its name fully matches a known versioned-asset syntax, and its
#     core, slot and version parse unambiguously;
#   * the slot is in the core's currently supported slot table;
#   * its version differs from the new CORE-VERSIONS version for that core;
#   * the new CORE-VERSIONS gives a replacement file for the same
#     core+slot, and that replacement is present in the new manifest;
#   * the core's required slot set is complete in the new CORE-VERSIONS;
#   * (real mode) the replacement asset is uploaded and its Release
#     digest matches the new manifest digest;
#   * the old name is NOT retained in the new manifest (manifest and
#     prune plan must agree; deleting a retained record would orphan it).
#     --ignore-retention skips this rule: planning use only, for the
#     publish gate's R14 comparison (which must catch a manifest that
#     kept a superseded record). Real deletion must never use it.
# CORE-VERSIONS, SHA256SUMS, *.sig, unknown assets and unparseable names
# are never deleted, only reported.
#
# Concurrency: a local flock mutex serialises runs on one machine.
# Workflow `concurrency` does NOT cover local direct runs, so the
# pointer re-check below is the real cross-machine guard: immediately
# before deleting, the script re-downloads CORE-VERSIONS from the
# Release and aborts unless its digest still equals the verified one.
# Deletions bind to asset IDs (not replaceable names) where possible.
#
# Output: `DELETE <name>` lines go to stdout (planned in --dry-run,
# actually deleted in real mode) so callers can parse the plan.
# Everything else goes to stderr. Dry-run uploads/deletes nothing and
# verifies replacements against the local manifest only.
#
# Usage:
#   prune-core-mirror.sh --repo owner/name --tag core-binaries \
#     --core-versions PATH --new-manifest PATH --old-manifest PATH \
#     [--expected-core-versions-digest SHA256] [--dry-run]
set -Eeuo pipefail

REPO=""; TAG=""; CV_FILE=""; NEW_MANIFEST=""; OLD_MANIFEST=""
EXPECTED_CV_DIGEST=""; DRY_RUN=0; IGNORE_RETENTION=0

while (( $# > 0 )); do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --core-versions) CV_FILE="${2:-}"; shift 2 ;;
    --new-manifest) NEW_MANIFEST="${2:-}"; shift 2 ;;
    --old-manifest) OLD_MANIFEST="${2:-}"; shift 2 ;;
    --expected-core-versions-digest) EXPECTED_CV_DIGEST="${2:-}"; shift 2 ;;
    --ignore-retention) IGNORE_RETENTION=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "ERROR: --repo must be owner/name, got: $REPO" >&2; exit 1; }
[[ -n "$TAG" ]] || { echo "ERROR: --tag is required" >&2; exit 1; }
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid --tag: $TAG" >&2; exit 1; }
for _f in "$CV_FILE" "$NEW_MANIFEST" "$OLD_MANIFEST"; do
  [[ -f "$_f" ]] || { echo "ERROR: file not found: $_f" >&2; exit 1; }
done
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- CORE-VERSIONS accessors -------------------------------------------
cv_get() { # $1 = key; prints value or empty
  awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$CV_FILE"
}
norm_ver() { # strip v / app/v prefixes for comparison
  local v="${1:-}"
  v="${v#app/}"; v="${v#v}"
  printf '%s\n' "$v"
}

# --- Filename grammar (keep in sync with update-core-mirror.sh's
# manifest_row_superseded and verify-publish-gate.sh's R14 check) ---
# parse_asset_name <name>: prints "core slot version" or returns 1.
parse_asset_name() {
  local name="$1"
  if [[ "$name" =~ ^Xray-(v[0-9]+\.[0-9]+\.[0-9]+)-linux-(64|arm64-v8a)\.zip$ ]]; then
    printf 'Xray %s %s\n' "$([ "${BASH_REMATCH[2]}" == "64" ] && echo amd64 || echo arm64)" "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^sing-box-([0-9]+\.[0-9]+\.[0-9]+)-linux-(amd64|arm64)-(glibc|musl)\.tar\.gz$ ]]; then
    printf 'sing-box %s-%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "v${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^hysteria-app-(v[0-9]+\.[0-9]+\.[0-9]+)-linux-(amd64|arm64)$ ]]; then
    printf 'Hysteria %s %s\n' "${BASH_REMATCH[2]}" "app/${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^cloudflared-([0-9]+\.[0-9]+\.[0-9]+)-linux-(amd64|arm64)$ ]]; then
    printf 'cloudflared %s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^wgcf_([0-9]+\.[0-9]+\.[0-9]+)_linux_(amd64|arm64)$ ]]; then
    printf 'wgcf %s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}
# Required slot set per core (space-separated).
core_slots() {
  case "$1" in
    Xray) echo "amd64 arm64" ;;
    sing-box) echo "amd64-glibc amd64-musl arm64-glibc arm64-musl" ;;
    Hysteria|cloudflared|wgcf) echo "amd64 arm64" ;;
    *) return 1 ;;
  esac
}
# Replacement filename for core+slot from the new CORE-VERSIONS.
slot_file() { # $1 = core, $2 = slot
  case "$1" in
    Xray) cv_get "Xray-$2" ;;
    sing-box) cv_get "sing-box-$2" ;;
    Hysteria) cv_get "Hysteria-$2" ;;
    cloudflared) cv_get "cloudflared-$2" ;;
    wgcf) cv_get "wgcf-$2" ;;
    *) return 1 ;;
  esac
}
manifest_has() { # $1 = manifest, $2 = name
  awk -v n="$2" '$2 == n {found=1; exit} END {exit !found}' "$1" 2>/dev/null
}
manifest_digest() { # $1 = manifest, $2 = name
  awk -v n="$2" '$2 == n {print $1; exit}' "$1" 2>/dev/null
}

# --- Release asset list (fully paginated) ------------------------------
# Writes $WORK/assets.json: [{id, name, digest}] for every asset.
fetch_assets() {
  local rel_id
  rel_id="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.id' 2>/dev/null)" || {
    echo "ERROR: cannot read Release $TAG in $REPO" >&2; return 1; }
  [[ "$rel_id" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid Release id for $TAG" >&2; return 1; }
  gh api "repos/$REPO/releases/$rel_id/assets?per_page=100" --paginate \
    --jq '[.[] | {id: .id, name: .name, digest: (.digest // "")}]' \
    > "$WORK/assets.json" 2>/dev/null || {
    echo "ERROR: cannot list assets of Release $TAG" >&2; return 1; }
  jq -e 'type == "array"' "$WORK/assets.json" >/dev/null || {
    echo "ERROR: asset list is not a JSON array" >&2; return 1; }
}
asset_field() { # $1 = name, $2 = jq field (id|digest)
  jq -r --arg n "$1" --arg f "$2" \
    '[.[] | select(.name == $n)] | if length == 1 then .[0][$f] // empty else empty end' \
    "$WORK/assets.json" 2>/dev/null
}

# --- Plan ---------------------------------------------------------------
# Compute the delete set. Prints DELETE lines to stdout in dry-run mode;
# in real mode fills DELETE_NAMES and returns 0.
declare -a DELETE_NAMES=()
plan_deletes() {
  local name core slot ver parsed new_ver repl
  local -a kept_unknown=()
  # Core slot-set completeness first: an incomplete core keeps all its
  # old assets (never prune by trimming a record whose replacement is
  # unverified or missing).
  declare -A COMPLETE_CORES=()
  local c s ok
  for c in Xray sing-box Hysteria cloudflared wgcf; do
    ok=1
    for s in $(core_slots "$c"); do
      repl="$(slot_file "$c" "$s")"
      if [[ -z "$repl" ]] || ! manifest_has "$NEW_MANIFEST" "$repl"; then ok=0; break; fi
    done
    (( ok == 1 )) && COMPLETE_CORES["$c"]=1
  done
  while read -r _sum name _extra || [[ -n "${name:-}" ]]; do
    [[ -n "${name:-}" ]] || continue
    case "$name" in
      CORE-VERSIONS|SHA256SUMS|*.sig) continue ;;  # protected, never delete
    esac
    parsed="$(parse_asset_name "$name" 2>/dev/null)" || {
      kept_unknown+=("$name"); continue; }
    read -r core slot ver <<< "$parsed"
    [[ -n "${COMPLETE_CORES[$core]:-}" ]] || {
      echo "KEEP (core slot set incomplete): $name" >&2; continue; }
    new_ver="$(cv_get "$core")"
    [[ "$(norm_ver "$ver")" != "$(norm_ver "$new_ver")" ]] || {
      echo "KEEP (current version): $name" >&2; continue; }
    repl="$(slot_file "$core" "$slot")"
    [[ -n "$repl" ]] || { echo "KEEP (no replacement record): $name" >&2; continue; }
    manifest_has "$NEW_MANIFEST" "$repl" || {
      echo "KEEP (replacement not in new manifest): $name" >&2; continue; }
    manifest_has "$NEW_MANIFEST" "$name" && (( IGNORE_RETENTION == 0 )) && {
      echo "KEEP (still retained in new manifest): $name" >&2; continue; }
    if (( DRY_RUN == 0 )); then
      # Real mode: replacement must be uploaded and digest-verified.
      local r_digest m_digest
      r_digest="$(asset_field "$repl" digest)"
      m_digest="$(manifest_digest "$NEW_MANIFEST" "$repl")"
      if [[ -z "$r_digest" || "${r_digest#sha256:}" != "${m_digest,,}" ]]; then
        echo "KEEP (replacement not uploaded/verified): $name" >&2; continue
      fi
    fi
    DELETE_NAMES+=("$name")
  done < "$OLD_MANIFEST"
  if (( ${#kept_unknown[@]} > 0 )); then
    echo "Unknown/unparseable old assets (kept, never guessed-deleted):" >&2
    printf '  %s\n' "${kept_unknown[@]}" >&2
  fi
  return 0
}

# --- Pointer re-check (real mode only) ----------------------------------
# The Release's CORE-VERSIONS must still equal the verified digest;
# a concurrent publish aborts the prune before any deletion.
check_pointer() {
  local expected current tmpd
  if [[ -n "$EXPECTED_CV_DIGEST" ]]; then
    expected="$EXPECTED_CV_DIGEST"
  else
    expected="$(sha256sum "$CV_FILE" | awk '{print $1}')"
  fi
  tmpd="$(mktemp -d)"
  gh release download "$TAG" --repo "$REPO" --pattern CORE-VERSIONS --dir "$tmpd" >/dev/null 2>&1 || {
    echo "ERROR: cannot re-download CORE-VERSIONS for pointer check" >&2
    rm -rf "$tmpd"; return 1; }
  current="$(sha256sum "$tmpd/CORE-VERSIONS" | awk '{print $1}')"
  rm -rf "$tmpd"
  [[ "${current,,}" == "${expected,,}" ]] || {
    echo "ERROR: remote CORE-VERSIONS pointer changed (concurrent publish?); refusing to delete" >&2
    return 1; }
  echo "Pointer check OK: remote CORE-VERSIONS still matches the verified digest." >&2
}

# --- Final verification (real mode only) ---------------------------------
verify_final() {
  fetch_assets || return 1
  local name repl core slot ver parsed
  for name in "${DELETE_NAMES[@]}"; do
    [[ -z "$(asset_field "$name" id)" ]] || {
      echo "ERROR: deleted asset still present: $name" >&2; return 1; }
  done
  # Current slot set complete + digests match the new manifest.
  for c in Xray sing-box Hysteria cloudflared wgcf; do
    for s in $(core_slots "$c"); do
      repl="$(slot_file "$c" "$s")"
      [[ -n "$repl" ]] || { echo "ERROR: missing slot record: $c/$s" >&2; return 1; }
      local r_digest m_digest
      r_digest="$(asset_field "$repl" digest)"
      m_digest="$(manifest_digest "$NEW_MANIFEST" "$repl")"
      [[ -n "$r_digest" && "${r_digest#sha256:}" == "${m_digest,,}" ]] || {
        echo "ERROR: replacement missing or digest mismatch: $repl" >&2; return 1; }
    done
  done
  # Retained assets still present.
  while read -r _sum name _extra || [[ -n "${name:-}" ]]; do
    [[ -n "${name:-}" ]] || continue
    case "$name" in CORE-VERSIONS|SHA256SUMS|*.sig) continue ;; esac
    manifest_has "$NEW_MANIFEST" "$name" || continue
    [[ -n "$(asset_field "$name" id)" ]] || {
      echo "ERROR: retained asset missing from Release: $name" >&2; return 1; }
  done < "$OLD_MANIFEST"
  echo "Final set verified: delete set empty, current slots complete, retained assets present." >&2
  return 0
}

# --- Main ----------------------------------------------------------------
# Lock: serialises runs on one machine (flock, bounded wait). This does
# NOT cover a concurrent local direct run on another machine -- the
# pointer re-check above is the guard for that case.
LOCK_FILE="${PRUNE_LOCK_FILE:-${RUNNER_TEMP:-/tmp}/core-mirror-publish.lock}"
exec 9>"$LOCK_FILE" || { echo "ERROR: cannot open lock file: $LOCK_FILE" >&2; exit 1; }
if ! flock -w 120 9; then
  echo "ERROR: cannot acquire publish lock within 120s (another publish in progress?)" >&2
  exit 1
fi

if (( DRY_RUN == 1 )); then
  echo "Dry-run: computing prune plan only (no upload check, nothing deleted)." >&2
  plan_deletes
  for _n in "${DELETE_NAMES[@]}"; do printf 'DELETE %s\n' "$_n"; done
  if (( ${#DELETE_NAMES[@]} == 0 )); then
    echo "Prune plan: nothing to delete." >&2
  else
    echo "Prune plan: ${#DELETE_NAMES[@]} asset(s) would be deleted after publish + verification." >&2
  fi
  exit 0
fi

fetch_assets || exit 1
plan_deletes
if (( ${#DELETE_NAMES[@]} == 0 )); then
  echo "Nothing to prune: no superseded old-version assets." >&2
  exit 0
fi
check_pointer || exit 1
# Delete by asset ID (not by replaceable name). Stop at the first
# failure: the new version stays published; cleanup is incomplete and
# a re-run continues from the current list. Never roll the manifest back.
_failed=0
for _n in "${DELETE_NAMES[@]}"; do
  _id="$(asset_field "$_n" id)"
  if [[ -z "$_id" ]]; then
    echo "NOTE: asset already gone (concurrent cleanup?): $_n" >&2
    printf 'DELETE %s\n' "$_n"
    continue
  fi
  printf 'DELETE %s\n' "$_n"
  if ! gh api -X DELETE "repos/$REPO/releases/assets/$_id" >/dev/null 2>&1; then
    echo "ERROR: failed to delete asset $_n (id $_id); new version published, cleanup incomplete" >&2
    _failed=1
    break
  fi
  echo "Deleted: $_n (id $_id)" >&2
done
if (( _failed == 1 )); then
  echo "ERROR: prune incomplete; re-run to continue deleting superseded assets" >&2
  exit 1
fi
verify_final || {
  echo "ERROR: post-prune verification failed; new version published, cleanup incomplete" >&2
  exit 1
}
echo "Prune complete: ${#DELETE_NAMES[@]} superseded asset(s) deleted; final set verified." >&2
exit 0
