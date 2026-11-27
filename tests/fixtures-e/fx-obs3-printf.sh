#!/usr/bin/env bash
# W7-OBS-3: tprintf must not emit `printf: --: invalid option` for
# translations whose format starts with dashes (e.g. tl_trying =
# "--- 正在尝试最新版 %s（独立事务）---").
# Pre-fix: `printf "$fmt"` treats a leading-dash format as options.
# Post-fix: `printf -- "$fmt"` is used.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fx_extract_i18n "$TMP/i18n.sh" || exit 1
# shellcheck disable=SC1091
source "$TMP/i18n.sh"

failures=0
# 1) The exact call from try_latest_cores_danger (10-users-dns.sh:4078).
out=''; err=''; rc=0
out=$(tprintf tl_trying xray 2>"$TMP/err"); rc=$?
err=$(cat "$TMP/err")
if (( rc != 0 )) || [[ -n "$err" ]] || [[ "$out" != '--- 正在尝试最新版 xray（独立事务）---' ]]; then
    printf 'FAIL: tprintf tl_trying xray: rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
    failures=$((failures + 1))
else
    printf 'ok: tprintf tl_trying xray -> [%s]\n' "$out"
fi

# 2) Sweep: every translation whose value starts with '-', in all six
# languages, called with the right number of %s arguments, must print
# cleanly (rc 0, no stderr). Candidate keys are read straight from the
# source lines (no per-key tr_msg call: the case table is long).
for _lang in zh en ru fa zh-tw ja; do
    export ABOX_LANG="$_lang"
    while IFS= read -r key; do
        val=$(tr_msg "$key" 2>/dev/null || true)
        [[ "$val" == -* ]] || continue
        # Count %s placeholders (%% is a literal percent, never counted).
        n=$(printf '%s' "$val" | grep -o '%s' | wc -l)
        args=()
        for (( i = 0; i < n; i++ )); do args+=('X'); done
        out=''; err=''; rc=0
        out=$(tprintf "$key" "${args[@]}" 2>"$TMP/err2"); rc=$?
        err=$(cat "$TMP/err2")
        if (( rc != 0 )) || [[ -n "$err" ]]; then
            printf 'FAIL: tprintf %s [%s]: rc=%s err=[%s] val=[%s]\n' "$key" "$_lang" "$rc" "$err" "$val" >&2
            failures=$((failures + 1))
        fi
    done < <(grep -E "^[[:space:]]*${_lang}:[A-Za-z_0-9]+\) echo '--" "$FX_DIR/../../src/02-i18n.sh" | sed -E "s/^[[:space:]]*${_lang}:([A-Za-z_0-9]+)\) echo.*/\1/" | sort -u)
done
export ABOX_LANG=zh

if (( failures == 0 )); then fx_pass 'W7-OBS-3 tprintf dash-leading formats print cleanly'; exit 0; fi
fx_fail "W7-OBS-3 $failures check(s) failed"; exit 1
