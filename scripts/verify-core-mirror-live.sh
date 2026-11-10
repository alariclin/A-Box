#!/bin/bash
# verify-core-mirror-live.sh — live verification of the core-binaries mirror.
#
# Downloads CORE-VERSIONS + SHA256SUMS + both detached Ed25519 signatures
# from the core-binaries Release and verifies them, fail-closed.
#
#   verify-core-mirror-live.sh          # default: API digest cross-check
#   verify-core-mirror-live.sh --full   # full: download every listed asset
#                                       # and verify its bytes with sha256sum
#
# Exit 0 = PASS, non-zero = FAIL (1 = verification failure, 2 = usage).
# Default mode proves: signatures valid; CORE-VERSIONS bytes match the
# signed manifest record; every manifest record matches the GitHub Release
# asset digest. It does NOT download the binaries, so it cannot claim the
# binaries themselves were byte-verified — see the --full boundary note.
# --full proves the listed files' downloaded bytes match the signed
# manifest, but does not prove the Release holds no unlisted assets.
#
# Trust anchor is HARDCODED (same as install.sh ABOX_SIGNING_PUBKEYS
# release-2026): a key fetched from the Release being verified would prove
# nothing. Timestamp floor and required-key list are likewise hardcoded to
# the install.sh / verify-core-versions-gate.sh values; keep them in sync
# by test, not by reading a remote install.sh at runtime.
#
# Env overrides (testability only; none of them can skip a check):
#   ABOX_MIRROR_BASE_URL   default https://github.com/alariclin/A-Box/releases/download/core-binaries
#   ABOX_MIRROR_REPO       default alariclin/A-Box (default mode only)
#   ABOX_MIRROR_TAG        default core-binaries (default mode only)
#   ABOX_VERIFY_PUBKEY_B64 default release-2026 anchor; any other value is
#                          reported as a custom trust anchor
#   ABOX_GITHUB_API_BASE_URL default https://api.github.com (default mode only)
#   ABOX_GITHUB_TOKEN      optional, only sent to the API host, never on
#                          redirect (curl strips auth across hosts)
#   ABOX_VERIFY_TEST_FILE_URL=1  allows a file:// ABOX_MIRROR_BASE_URL
#                          (fixture only; production is HTTPS-only)
set -uo pipefail

ANCHOR_PUBKEY_B64='7V4PBUUVpnfYhKu5LBxACxywpYEtvnDpVpvFnSrOujQ='
ANCHOR_LABEL='release-2026'
MIN_TS='20261015225900'
DEFAULT_BASE_URL='https://github.com/alariclin/A-Box/releases/download/core-binaries'
DEFAULT_REPO='alariclin/A-Box'
DEFAULT_TAG='core-binaries'
DEFAULT_API_BASE='https://api.github.com'
REQUIRED_KEYS='schema updated_at_utc Xray Xray-amd64 Xray-arm64 sing-box sing-box-amd64-glibc sing-box-amd64-musl sing-box-arm64-glibc sing-box-arm64-musl Hysteria Hysteria-amd64 Hysteria-arm64 cloudflared cloudflared-amd64 cloudflared-arm64 wgcf wgcf-amd64 wgcf-arm64'

FULL=0
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,30p' "$0"
  exit 0
fi
if [[ "${1:-}" == "--full" ]]; then FULL=1; shift; fi
if [[ $# -ne 0 ]]; then
  printf '[FAIL] usage: unknown argument: %s\n' "$1" >&2
  printf 'usage: %s [--full]\n' "$0" >&2
  exit 2
fi

BASE_URL="${ABOX_MIRROR_BASE_URL:-$DEFAULT_BASE_URL}"
REPO="${ABOX_MIRROR_REPO:-$DEFAULT_REPO}"
TAG="${ABOX_MIRROR_TAG:-$DEFAULT_TAG}"
API_BASE="${ABOX_GITHUB_API_BASE_URL:-$DEFAULT_API_BASE}"
PUBKEY_B64="${ABOX_VERIFY_PUBKEY_B64:-$ANCHOR_PUBKEY_B64}"

WORK="$(mktemp -d /tmp/abox-verify-live.XXXXXX)" || { echo '[FAIL] setup: cannot create temp dir' >&2; exit 1; }
RC=1
cleanup() { rm -rf -- "$WORK"; }
trap 'cleanup' EXIT

fail() { printf '[FAIL] %s: %s\n' "$1" "$2" >&2; exit 1; }
pass() { printf '[PASS] %s: %s\n' "$1" "$2"; }

# --- deps ---------------------------------------------------------------
for cmd in curl openssl python3 sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || fail deps "missing command: $cmd"
done
pass deps 'curl openssl python3 sha256sum present'

# --- trust anchor -------------------------------------------------------
if [[ "$PUBKEY_B64" != "$ANCHOR_PUBKEY_B64" ]]; then
  printf '[NOTE] custom trust anchor in use (NOT %s)\n' "$ANCHOR_LABEL"
fi
python3 -I -c '
import base64, sys
try:
    raw = base64.b64decode(sys.argv[1], validate=True)
except Exception:
    sys.exit(1)
sys.exit(0 if len(raw) == 32 else 1)
' "$PUBKEY_B64" 2>/dev/null || fail pubkey 'public key is not strict base64 of 32 raw bytes'
python3 -I -c '
import base64, sys
raw = base64.b64decode(sys.argv[1], validate=True)
der = bytes.fromhex("302a300506032b6570032100") + raw
pem = "-----BEGIN PUBLIC KEY-----\n" + base64.encodebytes(der).decode().strip() + "\n-----END PUBLIC KEY-----\n"
open(sys.argv[2], "w").write(pem)
' "$PUBKEY_B64" "$WORK/pub.pem" 2>/dev/null || fail pubkey 'cannot build SPKI PEM from public key'
pass pubkey 'anchor public key is 32 raw bytes, SPKI PEM built'

# --- openssl Ed25519 capability probe (real trial, not a version sniff) --
# NOTE: pkeyutl -rawin cannot read from a pipe/stdin (it needs a seekable
# file to size the oneshot buffer), so the trial uses real files throughout.
printf 'probe' > "$WORK/probe.msg"
if ! openssl genpkey -algorithm ed25519 -out "$WORK/probe-priv.pem" 2>/dev/null \
  || ! openssl pkey -in "$WORK/probe-priv.pem" -pubout -out "$WORK/probe-pub.pem" 2>/dev/null \
  || ! openssl pkeyutl -sign -inkey "$WORK/probe-priv.pem" -rawin -in "$WORK/probe.msg" -out "$WORK/probe.sig" 2>/dev/null \
  || ! openssl pkeyutl -verify -pubin -inkey "$WORK/probe-pub.pem" -rawin -in "$WORK/probe.msg" -sigfile "$WORK/probe.sig" >/dev/null 2>&1; then
  fail openssl 'openssl cannot perform Ed25519 sign/verify with -rawin'
fi
rm -f "$WORK/probe-priv.pem" "$WORK/probe-pub.pem" "$WORK/probe.sig" "$WORK/probe.msg"
pass openssl 'Ed25519 sign/verify trial succeeded'

# --- download metadata + signatures --------------------------------------
case "$BASE_URL" in
  https://*) : ;;
  file://*)
    [[ "${ABOX_VERIFY_TEST_FILE_URL:-}" == "1" ]] \
      || fail source 'file:// base URL requires ABOX_VERIFY_TEST_FILE_URL=1 (test only)'
    ;;
  *) fail source "unsupported base URL scheme (want https://, got ${BASE_URL%%:*}://)" ;;
esac
dl() { # $1=url $2=dest $3=max-bytes
  curl -fLsS --connect-timeout 10 --max-time 120 --max-filesize "$3" "$1" -o "$2" \
    || fail download "cannot download $1"
}
dl "$BASE_URL/CORE-VERSIONS" "$WORK/CORE-VERSIONS" 1048576
dl "$BASE_URL/SHA256SUMS" "$WORK/SHA256SUMS" 1048576
dl "$BASE_URL/CORE-VERSIONS.sig" "$WORK/CORE-VERSIONS.sig" 1048576
dl "$BASE_URL/SHA256SUMS.sig" "$WORK/SHA256SUMS.sig" 1048576
pass download 'CORE-VERSIONS, SHA256SUMS, CORE-VERSIONS.sig, SHA256SUMS.sig downloaded'

# --- signature encoding: strict base64 -> exactly 64 raw bytes ----------
for meta in CORE-VERSIONS SHA256SUMS; do
  python3 -I -c '
import base64, sys
text = open(sys.argv[1]).read()
try:
    raw = base64.b64decode("".join(text.split()), validate=True)
except Exception:
    sys.exit(1)
sys.exit(0 if len(raw) == 64 else 1)
' "$WORK/$meta.sig" 2>/dev/null || fail sig-format "$meta.sig is not base64 of exactly 64 raw bytes"
  python3 -I -c '
import base64, sys
text = open(sys.argv[1]).read()
raw = base64.b64decode("".join(text.split()), validate=True)
open(sys.argv[2], "wb").write(raw)
' "$WORK/$meta.sig" "$WORK/$meta.sig.bin" 2>/dev/null || fail sig-format "cannot decode $meta.sig"
done
pass sig-format 'both .sig files decode to exactly 64 raw bytes'

# --- signature verification (exit status, never output text) -------------
for meta in CORE-VERSIONS SHA256SUMS; do
  if openssl pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin \
      -in "$WORK/$meta" -sigfile "$WORK/$meta.sig.bin" >/dev/null 2>&1; then
    pass "sig-$meta" "$meta signature verifies"
  else
    fail "sig-$meta" "$meta signature does NOT verify with the trust anchor"
  fi
done

# --- CORE-VERSIONS compliance (signed bytes are now trusted to parse) ----
# No duplicate keys, no unknown keys, all 19 required keys present and
# non-empty, schema == 1, updated_at_utc strictly parsed and >= floor.
python3 -I - "$WORK/CORE-VERSIONS" "$MIN_TS" <<'PYEOF' || fail metadata 'CORE-VERSIONS compliance check failed (see above)'
import sys
path, floor = sys.argv[1], sys.argv[2]
required = "schema updated_at_utc Xray Xray-amd64 Xray-arm64 sing-box sing-box-amd64-glibc sing-box-amd64-musl sing-box-arm64-glibc sing-box-arm64-musl Hysteria Hysteria-amd64 Hysteria-arm64 cloudflared cloudflared-amd64 cloudflared-arm64 wgcf wgcf-amd64 wgcf-arm64".split()
data = open(path, "rb").read()
if b"\x00" in data:
    print("[FAIL] metadata: CORE-VERSIONS contains NUL", file=sys.stderr); sys.exit(1)
lines = data.decode("utf-8", errors="strict").splitlines()
seen = {}
for line in lines:
    if not line or "=" not in line:
        print(f"[FAIL] metadata: malformed CORE-VERSIONS line: {line!r}", file=sys.stderr); sys.exit(1)
    k, v = line.split("=", 1)
    if k in seen:
        print(f"[FAIL] metadata: duplicate CORE-VERSIONS key: {k}", file=sys.stderr); sys.exit(1)
    seen[k] = v
    if not v:
        print(f"[FAIL] metadata: empty CORE-VERSIONS value: {k}", file=sys.stderr); sys.exit(1)
unknown = sorted(set(seen) - set(required))
if unknown:
    print(f"[FAIL] metadata: unknown CORE-VERSIONS key(s): {','.join(unknown)}", file=sys.stderr); sys.exit(1)
missing = [k for k in required if k not in seen]
if missing:
    print(f"[FAIL] metadata: missing CORE-VERSIONS key(s): {','.join(missing)}", file=sys.stderr); sys.exit(1)
if seen["schema"] != "1":
    print(f"[FAIL] metadata: schema={seen['schema']}, expected 1", file=sys.stderr); sys.exit(1)
ts = seen["updated_at_utc"]
import re
m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z", ts)
if not m:
    print(f"[FAIL] metadata: updated_at_utc not strict ISO UTC: {ts}", file=sys.stderr); sys.exit(1)
compact = "".join(m.groups())
if compact < floor:
    print(f"[FAIL] metadata: updated_at_utc {ts} is older than trust floor {floor}", file=sys.stderr); sys.exit(1)
print(f"[PASS] metadata: CORE-VERSIONS 19 keys, schema 1, updated_at_utc {ts} >= floor")
PYEOF

# --- SHA256SUMS format gate (publish-job F-12 + traversal hardening) -----
python3 -I - "$WORK/SHA256SUMS" <<'PYEOF' || fail manifest 'SHA256SUMS format check failed (see above)'
import re, sys
path = sys.argv[1]
data = open(path, "rb").read()
if b"\x00" in data or b"\r" in data:
    print("[FAIL] manifest: SHA256SUMS contains NUL or CR", file=sys.stderr); sys.exit(1)
lines = data.decode("utf-8", errors="strict").splitlines()
names = set()
for line in lines:
    # sha256sum emits "<hash>  <name>" (two spaces, binary-mode marker);
    # split() on any run of whitespace handles both one- and two-space forms.
    parts = line.split()
    if len(parts) != 2 or not re.fullmatch(r"[A-Fa-f0-9]{64}", parts[0]):
        print(f"[FAIL] manifest: malformed SHA256SUMS line: {line!r}", file=sys.stderr); sys.exit(1)
    name = parts[1]
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name in ("SHA256SUMS", "CORE-VERSIONS.sig", "SHA256SUMS.sig") \
       or name.startswith(".") or ".." in name:
        print(f"[FAIL] manifest: disallowed filename in SHA256SUMS: {name!r}", file=sys.stderr); sys.exit(1)
    if name in names:
        print(f"[FAIL] manifest: duplicate filename in SHA256SUMS: {name}", file=sys.stderr); sys.exit(1)
    names.add(name)
if "CORE-VERSIONS" not in names:
    print("[FAIL] manifest: SHA256SUMS has no CORE-VERSIONS record", file=sys.stderr); sys.exit(1)
print(f"[PASS] manifest: SHA256SUMS format OK ({len(lines)} records)")
PYEOF

# --- bind the pair: CORE-VERSIONS bytes must match the signed record -----
cv_actual="$(sha256sum "$WORK/CORE-VERSIONS" | awk '{print $1}')"
cv_record="$(awk '$2 == "CORE-VERSIONS" {print $1}' "$WORK/SHA256SUMS")"
[[ "${cv_actual,,}" == "${cv_record,,}" ]] \
  || fail pairing 'CORE-VERSIONS bytes do not match the signed SHA256SUMS record'
pass pairing 'CORE-VERSIONS bytes match the signed SHA256SUMS record'

if [[ "$FULL" == "1" ]]; then
  # --- full mode: download every listed file, verify bytes --------------
  mkdir -p "$WORK/full"
  while read -r sum name extra || [[ -n "$sum" ]]; do
    [[ -n "${sum:-}" ]] || continue
    if [[ "$name" == "CORE-VERSIONS" ]]; then continue; fi
    dl "$BASE_URL/$name" "$WORK/full/$name" 268435456
  done < "$WORK/SHA256SUMS"
  cp "$WORK/CORE-VERSIONS" "$WORK/full/CORE-VERSIONS"
  (cd "$WORK/full" && sha256sum -c "$WORK/SHA256SUMS" > "$WORK/full-check.log" 2>&1) \
    || { cat "$WORK/full-check.log" >&2; fail hashes 'full-mode sha256sum -c failed'; }
  pass hashes "full mode: all $(wc -l < "$WORK/SHA256SUMS") listed files byte-verified"
  printf 'RESULT: PASS (full mode: signatures valid, all listed files byte-verified; unlisted Release assets, if any, were not checked)\n'
  RC=0
  exit 0
fi

# --- default mode: API digest cross-check (curl + python, no gh dep) -----
# The API host must match the download repo/tag; a custom BASE_URL that does
# not belong to REPO/TAG is refused rather than silently compared against
# the official Release.
case "$BASE_URL" in
  "https://github.com/$REPO/releases/download/$TAG") : ;;
  file://*) [[ "${ABOX_VERIFY_TEST_FILE_URL:-}" == "1" ]] || fail source 'file:// base URL requires ABOX_VERIFY_TEST_FILE_URL=1 (test only)' ;;
  *) fail source "base URL $BASE_URL does not match repo $REPO tag $TAG; set ABOX_MIRROR_REPO/ABOX_MIRROR_TAG to match" ;;
esac
api_auth=()
if [[ -n "${ABOX_GITHUB_TOKEN:-}" ]]; then api_auth=(-H "Authorization: Bearer $ABOX_GITHUB_TOKEN"); fi
api_url="$API_BASE/repos/$REPO/releases/tags/$TAG"
page=1
: > "$WORK/api-assets.tsv"
while [[ -n "$api_url" ]]; do
  [[ "$page" -le 10 ]] || fail api 'too many API pages (pagination loop)'
  hdr="$WORK/api-hdr.$page"; body="$WORK/api-body.$page"
  curl -fLsS --connect-timeout 10 --max-time 60 -D "$hdr" "${api_auth[@]}" \
    -H 'Accept: application/vnd.github+json' "$api_url" -o "$body" \
    || fail api "cannot fetch $api_url (network/rate-limit/auth; try --full)"
  python3 -I - "$body" "$WORK/api-assets.tsv" <<'PYEOF' || fail api 'API response is not valid release JSON (see above)'
import json, sys
body, out = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(body))
except Exception as e:
    print(f"[FAIL] api: invalid JSON: {e}", file=sys.stderr); sys.exit(1)
assets = doc.get("assets")
if not isinstance(assets, list):
    print("[FAIL] api: response has no assets list", file=sys.stderr); sys.exit(1)
with open(out, "a") as f:
    for a in assets:
        name = a.get("name")
        digest = a.get("digest")
        if not isinstance(name, str) or not name:
            print("[FAIL] api: asset without a name", file=sys.stderr); sys.exit(1)
        if not isinstance(digest, str) or not digest:
            print(f"[FAIL] api: asset {name} has no digest", file=sys.stderr); sys.exit(1)
        f.write(f"{name}\t{digest}\n")
PYEOF
  next="$(python3 -I - "$hdr" <<'PYEOF'
import re, sys
for line in open(sys.argv[1], errors="replace"):
    if line.lower().startswith("link:"):
        for part in line[5:].split(","):
            m = re.search(r'<([^>]+)>\s*;\s*rel="next"', part)
            if m:
                print(m.group(1)); sys.exit(0)
PYEOF
)"
  api_url="$next"
  page=$((page + 1))
done
python3 -I - "$WORK/SHA256SUMS" "$WORK/api-assets.tsv" <<'PYEOF' || fail hashes 'API digest cross-check failed (see above)'
import re, sys
man_path, api_path = sys.argv[1], sys.argv[2]
records = {}
for line in open(man_path).read().splitlines():
    h, n = line.split()
    records[n] = h
api = {}
for line in open(api_path).read().splitlines():
    if not line:
        continue
    name, digest = line.split("\t")
    if name in api:
        print(f"[FAIL] hashes: duplicate asset name in API response: {name}", file=sys.stderr); sys.exit(1)
    api[name] = digest
for name, want in records.items():
    if name == "CORE-VERSIONS":
        continue  # bound to local bytes in the pairing step
    got = api.get(name)
    if got is None:
        print(f"[FAIL] hashes: manifest record {name} has no Release asset", file=sys.stderr); sys.exit(1)
    if not re.fullmatch(r"sha256:[A-Fa-f0-9]{64}", got or ""):
        print(f"[FAIL] hashes: asset {name} digest is not sha256: {got!r}", file=sys.stderr); sys.exit(1)
    if got[7:].lower() != want.lower():
        print(f"[FAIL] hashes: manifest record {name} does not match Release asset digest", file=sys.stderr); sys.exit(1)
for name in api:
    if name in ("CORE-VERSIONS", "SHA256SUMS", "CORE-VERSIONS.sig", "SHA256SUMS.sig"):
        continue
    if name not in records:
        print(f"[FAIL] hashes: Release asset {name} has no SHA256SUMS record", file=sys.stderr); sys.exit(1)
print(f"[PASS] hashes: all {len(records)} manifest records match Release asset digests (API cross-check)")
PYEOF
printf 'RESULT: PASS (default mode: signatures valid, CORE-VERSIONS bound to signed manifest, manifest matches Release asset digests; binaries were NOT downloaded and byte-verified — run --full for that)\n'
RC=0
exit 0
