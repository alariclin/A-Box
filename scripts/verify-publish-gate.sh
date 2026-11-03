#!/bin/bash
# Publish-side gate for update-core-mirror.yml (runs BEFORE signing).
# The publish job previously trusted the verify job's artifacts for:
#   - version tags (R9C19-N2: old genuine Q substituted for pinned P)
#   - per-arch mapping (R4N19-02: Xray-amd64 record pointing at the arm64 file)
#   - history baseline (R5C19-01: manifest + assets swapped together)
#   - full history (R14C19-01: a historical record silently deleted)
#   - immutable binaries (R11C19-02: --clobber overwrote a same-name asset)
#   - stability (R5C19-02: numeric-tag prerelease bypassed cooling)
# This gate independently re-checks all six before anything is signed.
# It NEVER executes a binary; it only reads manifests and queries APIs.
#
# Usage: verify-publish-gate.sh <verified-dir>
# Env: GITHUB_REPOSITORY (required), ABOX_TRUSTED_PUBKEY_B64 (optional
# override for testing; defaults to the install.sh trust anchor).
# Exit 0 only when every applicable check passes.
set -uo pipefail

VERIFIED="${1:-}"
[[ -n "$VERIFIED" && -d "$VERIFIED" ]] || { echo "ERROR: verified dir missing: $VERIFIED"; exit 1; }
[[ -n "${GITHUB_REPOSITORY:-}" ]] || { echo "ERROR: GITHUB_REPOSITORY not set"; exit 1; }
[[ -f "$VERIFIED/CORE-VERSIONS" && -f "$VERIFIED/SHA256SUMS" ]] || {
  echo "ERROR: verified/CORE-VERSIONS or verified/SHA256SUMS missing"; exit 1; }

TRUSTED_PUBKEY_B64="${ABOX_TRUSTED_PUBKEY_B64:-7V4PBUUVpnfYhKu5LBxACxywpYEtvnDpVpvFnSrOujQ=}"
COOLDOWN_SECS=604800  # 7 days, same as update-core-mirror.sh enforce_cooldown.

tag_of() { grep "^$1=" "$VERIFIED/CORE-VERSIONS" | cut -d= -f2; }

# --- Tag formats (same regexes as the upload step; before any API use) ---
XRAY_TAG="$(tag_of Xray)"; SB_TAG="$(tag_of sing-box)"; HY_TAG="$(tag_of Hysteria)"
CF_TAG="$(tag_of cloudflared)"; WG_TAG="$(tag_of wgcf)"
[[ "$XRAY_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid Xray tag: $XRAY_TAG"; exit 1; }
[[ "$SB_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid sing-box tag: $SB_TAG"; exit 1; }
[[ "$HY_TAG" =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid Hysteria tag: $HY_TAG"; exit 1; }
[[ "$CF_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid cloudflared tag: $CF_TAG"; exit 1; }
[[ "$WG_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid wgcf tag: $WG_TAG"; exit 1; }

# --- R4N19-02: per-arch record filenames must carry the key's arch marker ---
# A swapped mapping (Xray-amd64 -> arm64 file) passes every digest check
# because the files themselves are genuine; only the key<->filename link
# exposes it. Markers are per-core (wgcf uses underscores, Xray uses linux-64).
arch_fail=0
check_arch() { # $1 = key, $2 = required substring, $3 = forbidden substring (may be empty)
  local val
  val="$(tag_of "$1")"
  [[ -n "$val" ]] || { echo "ERROR: CORE-VERSIONS record missing: $1"; arch_fail=1; return; }
  if [[ "$val" != *"$2"* ]]; then echo "ERROR: $1 record '$val' lacks arch marker '$2'"; arch_fail=1; fi
  if [[ -n "${3:-}" && "$val" == *"$3"* ]]; then echo "ERROR: $1 record '$val' carries forbidden marker '$3'"; arch_fail=1; fi
}
check_arch Xray-amd64 "linux-64.zip" "arm64"
check_arch Xray-arm64 "linux-arm64-v8a.zip" ""
check_arch sing-box-amd64-glibc "linux-amd64-glibc" "arm64"
check_arch sing-box-amd64-musl "linux-amd64-musl" "arm64"
check_arch sing-box-arm64-glibc "linux-arm64-glibc" ""
check_arch sing-box-arm64-musl "linux-arm64-musl" ""
check_arch Hysteria-amd64 "linux-amd64" "arm64"
check_arch Hysteria-arm64 "linux-arm64" ""
check_arch cloudflared-amd64 "linux-amd64" "arm64"
check_arch cloudflared-arm64 "linux-arm64" ""
check_arch wgcf-amd64 "linux_amd64" "arm64"
check_arch wgcf-arm64 "linux_arm64" ""
[[ "$arch_fail" -eq 0 ]] || exit 1
echo "Per-arch mapping OK."

# SemVer compare on prefix-stripped versions: echoes -1, 0, or 1.
semver_cmp() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3
  a="${a#app/}"; b="${b#app/}"
  IFS=. read -r a1 a2 a3 <<< "$a"; IFS=. read -r b1 b2 b3 <<< "$b"
  for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3"; do
    local x="${pair%%:*}" y="${pair##*:}"
    [[ "$x" -lt "$y" ]] && { echo -1; return; }
    [[ "$x" -gt "$y" ]] && { echo 1; return; }
  done
  echo 0
}

# --- R5C19-02: each tag must be a stable release past the 7-day cooldown ---
check_stable_cooldown() { # $1 = repo, $2 = tag for API, $3 = display tag
  local repo="$1" tag="$2" disp="$3" rel pre draft pub age now
  rel="$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null)" || {
    echo "ERROR: upstream release not found: $repo:$disp"; return 1; }
  # NOTE: do NOT use '.prerelease // empty' -- jq's // treats false as
  # missing, so a stable release (prerelease=false) would read as empty.
  pre="$(jq -r '.prerelease' <<< "$rel")"
  draft="$(jq -r '.draft' <<< "$rel")"
  pub="$(jq -r '.published_at // empty' <<< "$rel")"
  [[ "$pre" == "false" && "$draft" == "false" && -n "$pub" ]] || {
    echo "ERROR: $repo:$disp is not a stable release (prerelease=$pre draft=$draft published_at=$pub)"; return 1; }
  now="$(date +%s)"
  age=$(( now - $(date -d "$pub" +%s 2>/dev/null || echo 0) ))
  [[ "$age" -ge "$COOLDOWN_SECS" ]] || {
    echo "ERROR: $repo:$disp is in cooldown (age ${age}s < ${COOLDOWN_SECS}s)"; return 1; }
  echo "Stable+cooldown OK: $repo:$disp"
}
check_stable_cooldown "XTLS/Xray-core" "$XRAY_TAG" "$XRAY_TAG" || exit 1
check_stable_cooldown "SagerNet/sing-box" "$SB_TAG" "$SB_TAG" || exit 1
check_stable_cooldown "HyNetworks/hysteria" "$HY_TAG" "$HY_TAG" || exit 1
check_stable_cooldown "cloudflare/cloudflared" "$CF_TAG" "$CF_TAG" || exit 1
check_stable_cooldown "ViRb3/wgcf" "v$WG_TAG" "$WG_TAG" || exit 1

# --- Current Release baseline (for history / monotonicity / no-clobber) ---
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
if ! release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/core-binaries" 2>/dev/null)"; then
  echo "NOTE: no existing core-binaries Release; history/monotonicity/no-clobber checks skipped (first publish)."
  echo "Publish gate PASSED (first publish; arch + stable/cooldown verified)."
  exit 0
fi

# R11C19-02: no-clobber -- a same-name binary asset must be byte-identical.
# (Manifests are excluded: CORE-VERSIONS/SHA256SUMS change every publish by design.)
for f in "$VERIFIED"/*; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  case "$name" in
    Xray-*.zip|sing-box-*.tar.gz|hysteria-*|cloudflared-*|wgcf_*) ;;
    *) continue ;;
  esac
  gh_digest="$(jq -r --arg n "$name" '[.assets[]? | select(.name == $n)] | if length == 1 then .[0].digest // empty else empty end' <<< "$release_json")"
  if [[ -n "$gh_digest" ]]; then
    actual="sha256:$(sha256sum "$f" | awk '{print $1}')"
    [[ "${actual,,}" == "${gh_digest,,}" ]] || {
      echo "ERROR: existing Release asset $name digest differs from incoming file; refusing to clobber an immutable binary"; exit 1; }
    echo "No-clobber OK: $name matches existing asset."
  fi
done

# Download current manifests for the authenticated-baseline checks.
gh release download core-binaries -p SHA256SUMS -D "$TMPD" >/dev/null 2>&1 || true
gh release download core-binaries -p SHA256SUMS.sig -D "$TMPD" >/dev/null 2>&1 || true
gh release download core-binaries -p CORE-VERSIONS -D "$TMPD" >/dev/null 2>&1 || true
if [[ ! -f "$TMPD/SHA256SUMS" ]]; then
  echo "NOTE: current Release has no SHA256SUMS asset; history/monotonicity checks skipped."
  echo "Publish gate PASSED (no manifest baseline; arch + stable/cooldown + no-clobber verified)."
  exit 0
fi
# R5C19-01: authenticate the baseline manifest before trusting it.
# Missing .sig = bootstrap (the Release predates F-05 signing): warn and
# skip baseline-dependent checks, but do NOT abort -- otherwise the first
# signed publish could never happen. A PRESENT but INVALID .sig aborts.
BASELINE_AUTH=0
if [[ -f "$TMPD/SHA256SUMS.sig" ]]; then
  python3 -c 'import base64,sys;raw=base64.b64decode(sys.argv[1],validate=True);assert len(raw)==32;der=bytes.fromhex("302a300506032b6570032100")+raw;sys.stdout.write("-----BEGIN PUBLIC KEY-----\n"+base64.encodebytes(der).decode().strip()+"\n-----END PUBLIC KEY-----\n")' "$TRUSTED_PUBKEY_B64" > "$TMPD/trusted.pub"
  if openssl pkeyutl -verify -pubin -inkey "$TMPD/trusted.pub" -rawin \
      -in "$TMPD/SHA256SUMS" -sigfile <(base64 -d "$TMPD/SHA256SUMS.sig") >/dev/null 2>&1; then
    BASELINE_AUTH=1
    echo "Baseline manifest signature OK."
  else
    echo "ERROR: current Release SHA256SUMS signature invalid; refusing to trust a tampered baseline"; exit 1
  fi
else
  echo "WARNING: current Release has no SHA256SUMS.sig (pre-signing baseline); history/monotonicity checks skipped until the first signed publish."
fi

if [[ "$BASELINE_AUTH" -eq 1 ]]; then
  # R14C19-01: no silent truncation -- every current record must survive unchanged.
  while read -r sum name extra || [[ -n "$sum" ]]; do
    [[ -n "${sum:-}" ]] || continue
    new_sum="$(awk -v n="$name" '$2 == n {print $1; exit}' "$VERIFIED/SHA256SUMS")"
    [[ -n "$new_sum" ]] || { echo "ERROR: historical record dropped from new manifest: $name"; exit 1; }
    [[ "${new_sum,,}" == "${sum,,}" ]] || { echo "ERROR: historical record digest changed: $name"; exit 1; }
  done < "$TMPD/SHA256SUMS"
  echo "History preservation OK (no truncation, no digest change)."
  # R9C19-N2: no downgrade vs the authenticated current pins.
  if [[ -f "$TMPD/CORE-VERSIONS" ]]; then
    cur() { grep "^$1=" "$TMPD/CORE-VERSIONS" | cut -d= -f2; }
    for key in Xray sing-box Hysteria cloudflared wgcf; do
      old="$(cur "$key")"; new="$(tag_of "$key")"
      [[ -n "$old" && -n "$new" ]] || continue
      cmp="$(semver_cmp "$new" "$old")"
      [[ "$cmp" -ge 0 ]] || { echo "ERROR: downgrade vs current Release: $key $old -> $new"; exit 1; }
    done
    echo "Monotonicity OK (no downgrade vs current Release)."
  fi
fi
echo "Publish gate PASSED."
exit 0
