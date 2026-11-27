#!/usr/bin/env bash
# W6-OBS-2: §3.16-4 re-run after the wallos container is already gone
# prints "[!] 删除 wallos 容器失败，容器可能仍然存在。" — misleading:
# the container does not exist at all (it was deleted by the previous
# run); nothing failed except the assumption that it should be there.
# Fixture: run the REAL wallos_menu with a stubbed docker whose
# `container inspect wallos` fails, and assert the absent-container
# message (not the failure message) is shown.
set -u
source "$(dirname "$0")/fx-lib.sh"

export ABOX_LANG=zh
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
WALLOS_DIR="$TMP/wallos"; mkdir -p "$WALLOS_DIR"
touch "$WALLOS_DIR/.A-Box-managed"
export WALLOS_DIR

# Fake docker: no wallos container exists.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF_DOCK'
#!/usr/bin/env bash
exit 1
EOF_DOCK
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

fx_extract_i18n "$TMP/i18n.sh" || exit 1
fx_extract_colors "$TMP/colors.sh" || exit 1
fx_extract_func "$INSTALL_SH" is_yes "$TMP/isyes.sh" || exit 1
fx_extract_func "$INSTALL_SH" confirm_yes_no "$TMP/confirm.sh" || exit 1
fx_extract_func "$INSTALL_SH" normalize_fa_ar_digits "$TMP/norm.sh" || exit 1
fx_extract_func "$INSTALL_SH" wallos_menu "$TMP/menu.sh" || exit 1
{
    fx_msg_stub
    cat "$TMP/colors.sh" "$TMP/i18n.sh" "$TMP/isyes.sh" "$TMP/confirm.sh" "$TMP/norm.sh" "$TMP/menu.sh"
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"

# 4 = remove, Y = confirm, 0 = back out of the menu.
out=$(printf '4\nY\n0\n' | wallos_menu 2>&1)
printf 'menu output:\n%s\n' "$out"
failures=0
if [[ "$out" == *'删除 wallos 容器失败'* ]]; then
    printf 'FAIL: absent container reported as a removal failure\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" != *'容器不存在'* ]]; then
    printf 'FAIL: no explicit "container does not exist" message\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W6-OBS-2 absent wallos container says so explicitly'; exit 0; fi
fx_fail "W6-OBS-2 $failures check(s) failed"; exit 1
