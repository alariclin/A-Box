#!/usr/bin/env bash
# W7-OBS-5 (wording half): on uninstall with no DNS snapshot the box
# prints BOTH "systemd-resolved restart failed during uninstall" AND
# "No valid DNS rollback snapshot found; ... systemd-resolved was
# restarted with distribution defaults." — the second claim is false
# when the restart just failed (and also when systemd is absent).
# Fixture: extract the REAL no-snapshot else-branch from the built
# install.sh, run it with a systemctl whose resolved restart fails,
# and assert the output never claims a restart that did not happen.
set -u
source "$(dirname "$0")/fx-lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Fake systemctl: daemon-reload ok, dnscrypt socket not present,
# resolved restart FAILS (the matrix-box outcome).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'EOF_SYS'
#!/usr/bin/env bash
case "$1" in
    daemon-reload) exit 0 ;;
    is-enabled|is-active) exit 1 ;;
    restart) exit 1 ;;
    *) exit 1 ;;
esac
EOF_SYS
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# Extract the no-snapshot else-branch: from the `else` above the
# "No valid snapshot" comment to just before the tz-rollback block.
START=$(grep -nF '# No valid snapshot: remove A-Box' "$INSTALL_SH" | head -1 | cut -d: -f1)
[[ -n "$START" ]] || { printf 'SETUP: no-snapshot anchor not found\n' >&2; exit 2; }
START=$((START - 1))
END=$(awk -v s="$START" 'NR > s && /if \[\[ -d "\$ABOX_DIR\/.tz-rollback" \]\]; then/ { print NR - 1; exit }' "$INSTALL_SH")
[[ -n "$END" ]] || { printf 'SETUP: tz-rollback anchor not found\n' >&2; exit 2; }
{
    fx_msg_stub
    fx_extract_colors "$TMP/colors.sh" || exit 1
    cat "$TMP/colors.sh"
    printf 'fx_uninstall_dns_nosnap() {\n'
    # The extracted text is an `else ... fi` branch; run it under a
    # never-true `if` so it executes standalone exactly as written.
    printf '    if false; then\n        :\n'
    sed -n "${START},${END}p" "$INSTALL_SH"
    printf '}\n'
} > "$TMP/harness.sh"
# shellcheck disable=SC1091
source "$TMP/harness.sh"
remove_owned_auxiliary_path() { return 0; }

out=$(fx_uninstall_dns_nosnap 2>&1)
printf 'uninstall output:\n%s\n' "$out"
failures=0
if [[ "$out" != *'systemd-resolved restart failed'* ]]; then
    printf 'FAIL: restart-failure warning lost\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" == *'was restarted with distribution defaults'* ]]; then
    printf 'FAIL: claims resolved was restarted although the restart failed\n' >&2; failures=$((failures + 1))
fi
if [[ "$out" != *'No valid DNS rollback snapshot found'* ]]; then
    printf 'FAIL: no-snapshot notice lost\n' >&2; failures=$((failures + 1))
fi
if (( failures == 0 )); then fx_pass 'W7-OBS-5 uninstall no longer claims a failed restart happened'; exit 0; fi
fx_fail "W7-OBS-5 $failures check(s) failed"; exit 1
