#!/usr/bin/env bash
# W7-OBS-2: update_script has no "already latest" branch: when the
# downloaded OTA script is byte-identical to the installed one it
# still asks "是否安装此下载的 A-Box 脚本？[Y/N]".
# Fixture: the short-circuit is factored as ota_local_sha_matches
# (unit-testable without network); assert it matches an identical
# installed script, rejects a different one, and fails closed when
# the installed script is absent. Also assert update_script calls it
# and reports the already-latest message.
set -u
source "$(dirname "$0")/fx-lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ABOX_DIR="$TMP/ddr"; mkdir -p "$ABOX_DIR"
export ABOX_DIR
printf 'fake installed A-Box script v1\n' > "$ABOX_DIR/A-Box.sh"
SHA=$(sha256sum "$ABOX_DIR/A-Box.sh" | awk '{print $1}')

failures=0
if ! grep -q '^ota_local_sha_matches() {' "$INSTALL_SH"; then
    printf 'FAIL: ota_local_sha_matches helper missing from install.sh\n' >&2
    failures=$((failures + 1))
else
    fx_extract_func "$INSTALL_SH" ota_local_sha_matches "$TMP/helper.sh" || exit 1
    # shellcheck disable=SC1091
    source "$TMP/helper.sh"
    if ota_local_sha_matches "$SHA"; then
        printf 'ok: identical sha matches\n'
    else
        printf 'FAIL: identical sha did not match\n' >&2; failures=$((failures + 1))
    fi
    if ota_local_sha_matches '0000000000000000000000000000000000000000000000000000000000000000'; then
        printf 'FAIL: different sha matched\n' >&2; failures=$((failures + 1))
    else
        printf 'ok: different sha rejected\n'
    fi
    if ota_local_sha_matches ''; then
        printf 'FAIL: empty sha matched\n' >&2; failures=$((failures + 1))
    else
        printf 'ok: empty sha rejected\n'
    fi
    rm -f -- "$ABOX_DIR/A-Box.sh"
    if ota_local_sha_matches "$SHA"; then
        printf 'FAIL: missing installed script matched\n' >&2; failures=$((failures + 1))
    else
        printf 'ok: missing installed script fails closed\n'
    fi
fi
# The caller wires the helper to the already-latest message.
if ! sed -n '/^update_script() {/,/^force_update_geo() {/p' "$INSTALL_SH" | grep -q 'ota_local_sha_matches'; then
    printf 'FAIL: update_script does not call ota_local_sha_matches\n' >&2; failures=$((failures + 1))
fi
if ! sed -n '/^update_script() {/,/^force_update_geo() {/p' "$INSTALL_SH" | grep -q 'update_script_already_latest'; then
    printf 'FAIL: update_script has no already-latest message\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W7-OBS-2 already-latest short-circuit present and correct'; exit 0; fi
fx_fail "W7-OBS-2 $failures check(s) failed"; exit 1
