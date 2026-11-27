#!/usr/bin/env bash
# W6-OBS-1: §3.13-5 cleanup_separated_backup_keys returns 1 silently
# when /root/A-Box-backup-keys/ does not exist, so the menu prints
# nothing at all (zero output, straight to "press return").
# Fixture: run the REAL function with ABOX_BACKUP_KEYS_DIR pointing
# at a nonexistent dir, and assert some message is printed.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_colors "$TMP/colors.sh" || exit 1
fx_extract_func "$INSTALL_SH" path_parent_chain_safe "$TMP/chain.sh" || exit 1
fx_extract_func "$INSTALL_SH" cleanup_separated_backup_keys "$TMP/fn.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/colors.sh" "$TMP/i18n.sh" "$TMP/chain.sh" "$TMP/fn.sh"
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"

failures=0
# Case A (the OBS): keys directory does not exist at all.
export ABOX_BACKUP_KEYS_DIR="$TMP/does-not-exist"
out=$(cleanup_separated_backup_keys </dev/null 2>&1); rc=$?
printf 'missing-dir output: [%s] rc=%s\n' "$out" "$rc"
if [[ -z "$out" ]]; then
    printf 'FAIL: zero output when the keys directory is missing\n' >&2; failures=$((failures + 1))
fi
# Case B (regression guard): directory exists but is empty — the
# pre-existing explicit message must survive.
mkdir -p "$TMP/empty-keys"
export ABOX_BACKUP_KEYS_DIR="$TMP/empty-keys"
out=$(cleanup_separated_backup_keys </dev/null 2>&1); rc=$?
printf 'empty-dir output: [%s] rc=%s\n' "$out" "$rc"
if [[ "$out" != *'No separated recovery keys'* ]]; then
    printf 'FAIL: empty-dir message lost\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W6-OBS-1 missing keys dir reports explicitly'; exit 0; fi
fx_fail "W6-OBS-1 $failures check(s) failed"; exit 1
