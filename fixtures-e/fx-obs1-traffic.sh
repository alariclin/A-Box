#!/usr/bin/env bash
# W7-OBS-1: without vnStat the traffic menu shows only the one-line
# warning "[!] vnStat 未安装或暂无数据；设定上限时会按需安装。" —
# no dashboard title, no monthly table. The task book says entering
# the menu renders the dashboard.
# Fixture: run the REAL traffic_management_menu with vnStat absent
# (this sandbox has none) and assert the dashboard frame (title +
# empty-state line) renders alongside the warning.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
command -v vnstat >/dev/null 2>&1 && { printf 'SETUP: vnstat present, fixture not applicable\n' >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ABOX_DIR="$TMP/ddr"; mkdir -p "$ABOX_DIR"
ABOX_ENV="$ABOX_DIR/.env"; : > "$ABOX_ENV"
export ABOX_DIR ABOX_ENV INGRESS_IF=eth0

fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_colors "$TMP/colors.sh" || exit 1
fx_extract_func "$INSTALL_SH" traffic_management_menu "$TMP/menu.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/colors.sh" "$TMP/i18n.sh"
    cat <<'EOF_STUB2'
load_optional_abox_env_or_die() { return 0; }
get_active_interface() { printf 'eth0\n'; }
EOF_STUB2
    cat "$TMP/menu.sh"
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"

out=$(printf '0\n' | traffic_management_menu 2>&1)
printf 'menu output:\n%s\n' "$out"
failures=0
if [[ "$out" != *'vnStat 未安装'* ]]; then
    printf 'FAIL: vnStat-missing warning lost\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" != *'每月流量管控'* ]]; then
    printf 'FAIL: dashboard title not rendered without vnStat\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" != *'暂无本月统计数据'* ]]; then
    printf 'FAIL: dashboard empty-state line not rendered\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W7-OBS-1 dashboard frame renders without vnStat'; exit 0; fi
fx_fail "W7-OBS-1 $failures check(s) failed"; exit 1
