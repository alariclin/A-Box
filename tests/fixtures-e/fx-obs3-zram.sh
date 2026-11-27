#!/usr/bin/env bash
# W5-OBS-3: Swap 4 (remove zram) prints "zram 已移除…" even when no
# A-Box zram exists at all (helper/state/conf/unit all absent, no
# active zram device): abox_zram_teardown returns 0 for a no-op
# cleanup and remove_zram_swap cannot tell it apart from a real
# removal. Swap 5 (disk swap) by contrast prints "没有 A-Box 创建的
# 磁盘 Swap 文件。" when there is nothing to remove.
# Fixture: run the REAL remove_zram_swap with a systemd init, a fake
# systemctl (LoadState not-found), no zram artifacts anywhere, and
# assert it does NOT claim a removal.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ABOX_DIR="$TMP/ddr"; mkdir -p "$ABOX_DIR"
export ABOX_DIR INIT_SYS=systemd

# Precondition guard: the sandbox must really have no A-Box zram.
for p in /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state /etc/init.d/abox-zram; do
    [[ ! -e "$p" && ! -L "$p" ]] || { printf 'SETUP: %s exists, fixture not applicable\n' "$p" >&2; exit 2; }
done
for p in /etc/systemd/system/abox-zram.service /run/systemd/system/abox-zram.service /usr/local/lib/systemd/system/abox-zram.service /usr/lib/systemd/system/abox-zram.service /lib/systemd/system/abox-zram.service; do
    [[ ! -e "$p" && ! -L "$p" ]] || { printf 'SETUP: %s exists, fixture not applicable\n' "$p" >&2; exit 2; }
done
grep -qE '^/dev/zram[0-9]+[[:space:]]' /proc/swaps 2>/dev/null && { printf 'SETUP: active zram device present, fixture not applicable\n' >&2; exit 2; }

# Fake systemctl: no abox-zram unit (LoadState not-found), everything else ok.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'EOF_SYS'
#!/usr/bin/env bash
if [[ "$1" == 'show' ]]; then printf 'not-found\n'; exit 0; fi
exit 0
EOF_SYS
# Fake swapon: no swap at all.
cat > "$TMP/bin/swapon" <<'EOF_SW'
#!/usr/bin/env bash
exit 0
EOF_SW
chmod +x "$TMP/bin/systemctl" "$TMP/bin/swapon"
export PATH="$TMP/bin:$PATH"

fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_colors "$TMP/colors.sh" || exit 1
fx_extract_func "$INSTALL_SH" effective_init_system "$TMP/init.sh" || exit 1
fx_extract_func "$INSTALL_SH" abox_zram_teardown "$TMP/teardown.sh" || exit 1
fx_extract_func "$INSTALL_SH" remove_zram_swap "$TMP/remove.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/colors.sh" "$TMP/i18n.sh" "$TMP/init.sh" "$TMP/teardown.sh" "$TMP/remove.sh"
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"

out=$(remove_zram_swap 2>&1)
printf 'output: [%s]\n' "$out"
failures=0
if [[ "$out" == *'zram 已移除'* ]]; then
    printf 'FAIL: claims a removal when no A-Box zram exists\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" != *'没有 A-Box 创建的 zram'* ]]; then
    printf 'FAIL: no explicit "nothing to remove" message\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W5-OBS-3 remove-zram reports nothing-to-remove when empty'; exit 0; fi
fx_fail "W5-OBS-3 $failures check(s) failed"; exit 1
