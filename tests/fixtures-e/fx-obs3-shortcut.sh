#!/usr/bin/env bash
# W6-OBS-3: §3.18-2 (restore default shortcuts) re-runs the whole
# transaction and prints "完成：当前快捷键为 ab abox" even when the
# set is already the default; the "未做任何更改。" branch only fires
# when shortcut_resolve_desired fails outright.
# Fixture: run the REAL shortcut_custom_menu with stubbed state
# (default set, wrappers managed) and assert the transaction is NOT
# re-run and the noop message IS printed. Two guards: wrappers
# missing -> transaction MUST run; corrupt state -> transaction MUST
# run (heal path, never a false noop).
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
export FX_CASE=present FX_RECORD="$TMP/called" FAKEBIN

fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_colors "$TMP/colors.sh" || exit 1
fx_extract_func "$INSTALL_SH" normalize_fa_ar_digits "$TMP/norm.sh" || exit 1
fx_extract_func "$INSTALL_SH" shortcut_custom_menu "$TMP/menu.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/colors.sh" "$TMP/i18n.sh" "$TMP/norm.sh"
    cat <<'EOF_STUB2'
# State seam: default set, readable state (rc 0) -- unless FX_CASE=corrupt.
shortcut_primary_names() {
    if [[ "${FX_CASE:-}" == 'corrupt' ]]; then printf '%s\n' 'ab abox'; return 1; fi
    printf '%s\n' 'ab abox'; return 0
}
shortcut_resolve_desired() { SHORTCUT_RESOLVED='ab abox'; return 0; }
shortcut_is_abox_managed() { [[ -f "$FAKEBIN/$(basename -- "$1")" ]]; }
shortcut_change_transaction() { printf 'CALLED %s\n' "$*" >> "$FX_RECORD"; return 0; }
shortcut_read_state() { return 0; }
shortcut_reset_corrupt_state_confirmed() { return 0; }
EOF_STUB2
    cat "$TMP/menu.sh"
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"

run_case() {
    local case_name="$1" expect_called="$2" expect_noop="$3"
    export FX_CASE="$case_name"
    rm -f -- "$FX_RECORD"
    if [[ "$case_name" == 'present' ]]; then
        touch "$FAKEBIN/ab" "$FAKEBIN/abox"
    else
        rm -f -- "$FAKEBIN/ab" "$FAKEBIN/abox"
    fi
    local out
    out=$(printf '2\n0\n' | shortcut_custom_menu 2>&1)
    local called=0 noop=0
    [[ -f "$FX_RECORD" ]] && called=1
    [[ "$out" == *'未做任何更改'* ]] && noop=1
    printf 'case %s: called=%s noop=%s\n' "$case_name" "$called" "$noop"
    if [[ "$expect_called" == "$called" && "$expect_noop" == "$noop" ]]; then return 0; fi
    printf 'FAIL: case %s expected called=%s noop=%s\n' "$case_name" "$expect_called" "$expect_noop" >&2
    return 1
}

failures=0
run_case present 0 1 || failures=$((failures + 1))
run_case missing 1 0 || failures=$((failures + 1))
run_case corrupt 1 0 || failures=$((failures + 1))
if (( failures == 0 )); then fx_pass 'W6-OBS-3 already-default restore is a noop, guards intact'; exit 0; fi
fx_fail "W6-OBS-3 $failures case(s) failed"; exit 1
