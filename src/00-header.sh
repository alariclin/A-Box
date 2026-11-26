# ABOX-MODULE-BEGIN 00-header shebang/locale/PATH/bash gate/colors
#   Source: install.sh lines 1-51 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
#!/usr/bin/env bash
# Best-effort UTF-8 locale (v2ray-agent pattern): harmless if locale missing,
# makes [[ =~ ]], wc -m and case patterns UTF-8 correct; byte fallback remains.
export LANG=en_US.UTF-8 2>/dev/null || true
# Pin PATH before any external command (R12C1-01): a caller-controlled
# PATH could otherwise redirect the first external command (stty below)
# to a planted program run as root.
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
# Fix backspace/delete key: some terminals (FinalShell) send ^H but tty expects ^?
# Only adjust on explicit opt-in (ABOX_STTY_ERASE_H=1): standard terminals
# send ^? for Backspace, so rewriting erase breaks their Backspace — and
# the change persists on the pty after the script exits (R2C1-03).
if [[ "${ABOX_STTY_ERASE_H:-}" == '1' ]]; then
    stty erase '^H' 2>/dev/null || true
fi
# ==============================A-Box===============================
# SNI profile: built-in candidate library plus per-VPS automatic REALITY target selection; no remote script execution.
# Hardened build: stricter GitHub digest trust, guarded shortcut persistence, Fail2Ban validation, and sing-box HY2 ACME semantics.
# P2-03 Return Code Contract (standardized 2026-10-15):
#   0 = success
#   1 = general failure (operation attempted but failed)
#   2 = preflight failure (preconditions not met; operation not attempted or aborted before mutation)
# This standard applies ONLY to: CLI top-level exit codes and rollback orchestrator
# functions. It does NOT apply to polymorphic internal helpers that intentionally use
# 2/3/4 as business branch signals (callers depend on `case $?`):
#   remove_recorded_core_family, core_version_upgrade_decision, iptables_rule_check,
#   firewalld_port_state, ufw_global_rule_numbers, managed_services_active,
#   decimal_component_compare, core_version_compare, and similar query/state helpers.
# When in doubt, leave the function unchanged.
set -o pipefail
set -u
# D-14: requires 4.4+ (4.4 fixed the empty-array + set -u unbound-variable bug;
# the "${arr[@]:-}" workaround would pass a spurious empty argument to docker).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'A-Box requires Bash 4.4 or newer. Current: %s\n' "$BASH_VERSION" >&2
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive
export LANG=${LANG:-en_US.UTF-8}

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[38;2;0;170;255m'
GRAY=$'\033[0;37m'
LBLW=$'\033[0;97m'
LIGHTBLUE=$'\033[0;94m'
NC=$'\033[0m'
BOLD=$'\033[1m'

