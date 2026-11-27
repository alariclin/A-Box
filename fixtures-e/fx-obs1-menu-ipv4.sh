#!/usr/bin/env bash
# W5-OBS-1: the main-menu network row prints ${GLOBAL_PUBLIC_IP} under
# the `IPv4` label. When the IP cache holds a v6 address (e.g. written
# while the preference was ipv6, then switched to dual), the IPv4 cell
# shows an IPv6 address.
# Fixture: stub _menu_info_collect to a deployed state, set
# GLOBAL_PUBLIC_IP to a v6 address, run the REAL _menu_info_display,
# and assert the IPv4 row never contains a v6 address.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_func "$INSTALL_SH" _mi_cell "$TMP/cell.sh" || exit 1
fx_extract_func "$INSTALL_SH" _menu_info_display "$TMP/display.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/i18n.sh" "$TMP/cell.sh"
    cat <<'EOF_STUB2'
_str_dwidth() { printf '4\n'; }
_menu_info_collect() {
    _MI_OS='Debian 13'; _MI_KERNEL='6.18.54'; _MI_CPU='4'; _MI_CPU_MODEL='AMD EPYC'
    _MI_MEM='7.8'; _MI_MEM_USED='1.1'; _MI_DISK='16G'; _MI_DISK_KIND='HDD'
    _MI_VIRT='kvm'; _MI_UP='0'; _MI_IPV6='2600:1f14:34cf:7b4f:211d::95'
    _MI_GEO_COUNTRY=''; _MI_GEO_CITY=''; _MI_GEO_KIND=''; _MI_GEO_ORIGIN=''
    _MI_XST=run; _MI_SST=none; _MI_HST=none; _MI_F2B=run; _MI_WALLOS=none
    _MI_TRAFFIC=none; _MI_DOCKER=none; _MI_BBR=none; _MI_FW=run
    _MI_WARP=''; _MI_TROJAN=none; _MI_TUIC=none; _MI_ANYTLS=none; _MI_STLS=none
    _MI_SOCKS_ST=none; _MI_CF=none; _MI_ARGO=none
    _MI_DNS4=''; _MI_DNS6=''; _MI_DNSMODE=''
    _MI_USER_RECS=''; _MI_NODES=''; _MI_SNI=''
    return 0
}
EOF_STUB2
    cat "$TMP/display.sh"
} > "$TMP/harness.sh"

CYAN='' NC='' GREEN='' LBLW='' GRAY='' BOLD='' YELLOW='' RED='' BLUE=''
export CYAN NC GREEN LBLW GRAY BOLD YELLOW RED BLUE
# The exact matrix-box state: cache held the v6 address after the
# preference was switched to dual.
GLOBAL_PUBLIC_IP='2600:1f14:34cf:7b4f:211d::95'
export GLOBAL_PUBLIC_IP
# shellcheck disable=SC1091
source "$TMP/harness.sh"

out=$(_menu_info_display 2>"$TMP/err")
rc=$?
ipv4line=$(printf '%s\n' "$out" | grep 'IPv4' | head -1)
ipv6line=$(printf '%s\n' "$out" | grep 'IPv6' | head -1)
printf 'IPv4 row: [%s]\nIPv6 row: [%s]\n' "$ipv4line" "$ipv6line"
failures=0
if (( rc != 0 )); then printf 'FAIL: _menu_info_display rc=%s\n' "$rc" >&2; failures=$((failures + 1)); fi
if [[ "$ipv4line" == *'2600:'* ]]; then
    printf 'FAIL: IPv4 cell shows an IPv6 address\n' >&2; failures=$((failures + 1))
fi
if [[ "$ipv6line" != *'2600:1f14:34cf:7b4f:211d::95'* ]]; then
    printf 'FAIL: IPv6 row lost the v6 address\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W5-OBS-1 IPv4 cell never shows an IPv6 address'; exit 0; fi
fx_fail "W5-OBS-1 $failures check(s) failed"; exit 1
