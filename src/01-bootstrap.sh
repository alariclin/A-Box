# ABOX-MODULE-BEGIN 01-bootstrap jq rawfile shim, globals, msg/die, path trust, lang
#   Source: install.sh lines 52-1568 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
# jq < 1.6 lacks --rawfile (added in 1.6; e.g. Debian 10 ships jq 1.5).
# This shim translates --rawfile NAME FILE pairs to --slurpfile NAME FILE
# on old jq, so secret values never pass through argv: the raw content is
# JSON-encoded with `command jq -Rs.` (secret via stdin, never argv) and
# materialized to a 0600 temp file in a 0700 dir (removed explicitly
# after the final `command jq`, RETURN trap as backstop),
# which is handed to the real jq as --slurpfile NAME FILE (only a temp
# path in argv). A temp file (not a /dev/fd/N pipe) is required: bash 5.0
# (Debian 10) closes sibling process-substitution fds when a new one is
# created via `exec {fd}< <(...)`, so a pipe handoff breaks with 2+
# --rawfile pipes ("cannot read --rawfile file: /dev/fd/62", Debian 10
# self-test rc=1 with no verdict line). --slurpfile binds an array, so
# the program is rewritten, replacing bare $NAME with $NAME[0]. On jq >=
# 1.6 it is a pure pass-through (no arg parsing, no behavior change); the
# version decision is cached in _ABOX_JQ_RAWFILE_SHIM so it is computed
# once per shell. --slurpfile exists since jq 1.4 (jq 1.5 manual,
# "Invoking jq"), so this is safe on the oldest supported jq. ($ENV is
# NOT an option
# here: it arrived in jq 1.6, the very version that already has --rawfile.)
# Rewrite guard: a program that uses $NAME as literal text inside a
# double-quoted jq string (outside \(...\) interpolation) cannot be
# rewritten safely — that name falls back to the old --arg path with a
# one-time warning (the value is then visible in the process list, as
# before). The same fallback applies when the name is not a plain
# identifier or the program comes from a file (-f/--from-file). The shim
# assumes --rawfile appears only as a flag or as the value of
# --arg/--argjson/--slurpfile (all current call sites); a value literally
# equal to --rawfile anywhere else would misparse (not a current case).
_ABOX_JQ_RAWFILE_SHIM=''
_ABOX_JQ_RAWFILE_WARNED=''
_ABOX_JQ_SLURP_FALLBACK_WARNED=''
# _jq_prog_has_literal_name PROGRAM NAME: return 0 if $NAME occurs as
# literal text inside a double-quoted jq string (outside \(...\)
# interpolation). Such a program must NOT be rewritten ($NAME[0] would
# change the emitted text). Nested strings inside interpolation are not
# tracked (no current call site interpolates these names); a missed
# literal there would rewrite string text — the fallback only covers the
# plain-literal case, which is what exists today.
_jq_prog_has_literal_name() {
    local _prog="$1" _name="$2" _i=0 _len=${#1} _c='' _in_str=0 _interp=0 _after=''
    while (( _i < _len )); do
        _c=${_prog:_i:1}
        if (( _in_str )); then
            if [[ "$_c" == '\' ]]; then
                if [[ "${_prog:_i+1:1}" == '(' ]]; then _interp=1; _i=$(( _i + 2 )); continue; fi
                _i=$(( _i + 2 )); continue
            fi
            if (( _interp > 0 )); then
                if [[ "$_c" == '(' ]]; then _interp=$(( _interp + 1 ));
                elif [[ "$_c" == ')' ]]; then _interp=$(( _interp - 1 )); fi
                _i=$(( _i + 1 )); continue
            fi
            if [[ "$_c" == '"' ]]; then _in_str=0; _i=$(( _i + 1 )); continue; fi
            if [[ "$_c" == '$' && "${_prog:_i+1:${#_name}}" == "$_name" ]]; then
                _after=${_prog:_i+1+${#_name}:1}
                if [[ "$_after" != [A-Za-z0-9_] ]]; then return 0; fi
            fi
            _i=$(( _i + 1 )); continue
        fi
        # R01a-M01: outside a string, '#' starts a jq comment running to
        # the end of the line -- a '"' inside it must not flip string
        # state, or a later real string literal is misread as its close
        # and $NAME inside it gets rewritten ($NAME -> $NAME[0]).
        if [[ "$_c" == '#' ]]; then
            while (( _i < _len )) && [[ "${_prog:_i:1}" != $'\n' ]]; do _i=$(( _i + 1 )); done
            continue
        fi
        if [[ "$_c" == '"' ]]; then _in_str=1; fi
        _i=$(( _i + 1 ))
    done
    return 1
}
# L-12(2): probe the jq version once and cache it in
# _ABOX_JQ_RAWFILE_SHIM (exported, so $(...) subshells -- which inherit
# exported variables via fork -- see it). Without this, every command
# substitution re-probed: a subshell's assignment never flows back to
# the parent, so the parent's variable stayed empty forever. Leaves the
# variable unset when no jq binary exists, so the lazy probe inside
# jq() still runs later if jq is installed mid-run.
_abox_jq_probe_rawfile_shim() {
    [[ -n "${_ABOX_JQ_RAWFILE_SHIM:-}" ]] && return 0
    local _ver _maj _min
    _ver=$(command jq --version 2>/dev/null || echo '')
    if [[ "$_ver" =~ ^jq-([0-9]+)\.([0-9]+) ]]; then
        _maj="${BASH_REMATCH[1]}"
        _min="${BASH_REMATCH[2]}"
        if (( _maj > 1 || (_maj == 1 && _min >= 6) )); then
            _ABOX_JQ_RAWFILE_SHIM=0
        else
            _ABOX_JQ_RAWFILE_SHIM=1
        fi
        export _ABOX_JQ_RAWFILE_SHIM
    fi
}
jq() {
    if [[ -z "${_ABOX_JQ_RAWFILE_SHIM:-}" ]]; then
        local _ver _maj _min
        _ver=$(command jq --version 2>/dev/null || echo '')
        if [[ "$_ver" =~ ^jq-([0-9]+)\.([0-9]+) ]]; then
            _maj="${BASH_REMATCH[1]}"
            _min="${BASH_REMATCH[2]}"
            if (( _maj > 1 || (_maj == 1 && _min >= 6) )); then
                _ABOX_JQ_RAWFILE_SHIM=0
            else
                _ABOX_JQ_RAWFILE_SHIM=1
            fi
        else
            _ABOX_JQ_RAWFILE_SHIM=0
        fi
    fi
    if [[ "$_ABOX_JQ_RAWFILE_SHIM" == 0 ]]; then
        command jq "$@"
        return $?
    fi
    local -a _all=( "$@" ) _args=() _raw_names=() _raw_files=() _raw_slurp=() _slurp_names=()
    local _n=${#_all[@]} _i=0 _a='' _prog_idx=-1 _ri=0 _rn='' _rf='' _tmpf='' _content='' _prog='' _prog_new='' _jq_tmpdir=''
    # Pass 1: collect --rawfile pairs and find the program (first
    # non-flag arg). Value-taking flags consume their values so a value
    # literally equal to --rawfile is not mistaken for a flag.
    while (( _i < _n )); do
        _a=${_all[_i]}
        case "$_a" in
            --rawfile)
                if (( _i + 2 < _n )); then _raw_names+=("${_all[_i+1]}"); _raw_files+=("${_all[_i+2]}"); _i=$(( _i + 3 )); else _i=$(( _i + 1 )); fi ;;
            --arg|--argjson|--slurpfile|--argfile) _i=$(( _i + 3 )) ;;
            -f|--from-file) _prog_idx=-2; _i=$(( _i + 2 )) ;;
            --indent|-L) _i=$(( _i + 2 )) ;;
            --)
                if (( _prog_idx == -1 && _i + 1 < _n )); then _prog_idx=$(( _i + 1 )); fi
                _i=$(( _i + 1 )) ;;
            -*)
                _i=$(( _i + 1 )) ;;
            *)
                if (( _prog_idx == -1 )); then _prog_idx=$_i; fi
                _i=$(( _i + 1 )) ;;
        esac
    done
    # L-12(2): warn only when the shim will actually rewrite
    # (--rawfile present); plain jq calls on old jq need no warning.
    if (( ${#_raw_names[@]} > 0 )) && [[ -z "${_ABOX_JQ_RAWFILE_WARNED:-}" ]]; then
        _ABOX_JQ_RAWFILE_WARNED=1
        printf '%s\n' "[!] Old jq (< 1.6) detected: --rawfile is emulated via --slurpfile; values no longer pass through argv." >&2
    fi
    # Decide per name: slurpfile + rewrite, or --arg fallback.
    if (( ${#_raw_names[@]} > 0 )); then
        _prog=''
        if (( _prog_idx >= 0 )); then _prog=${_all[_prog_idx]}; fi
        for _rn in "${_raw_names[@]}"; do
            if (( _prog_idx >= 0 )) && [[ "$_rn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && ! _jq_prog_has_literal_name "$_prog" "$_rn"; then
                _raw_slurp+=(1); _slurp_names+=("$_rn")
            else
                _raw_slurp+=(0)
                if [[ -z "${_ABOX_JQ_SLURP_FALLBACK_WARNED:-}" ]]; then
                    _ABOX_JQ_SLURP_FALLBACK_WARNED=1
                    printf '%s\n' "[!] jq shim: --rawfile '$_rn' cannot use --slurpfile here; falling back to --arg (value visible in the process list)." >&2
                fi
            fi
        done
        # Rewrite the program for every slurpfile name: bare $NAME (not
        # followed by an identifier char or '[') becomes $NAME[0].
        # Legacy slurpfile adaptation supports bare $NAME and the existing
        # explicit $NAME[0] convention only. Refuse other directly attached
        # bracket forms (e.g. $NAME[0:2]) instead of silently applying them
        # to the wrapper array (R1-03): a slice of the one-element slurp
        # array is not a slice of the raw string. jq >= 1.6 is required
        # for those programs. This is deliberately a text check, not a jq
        # lexer: text in comments or unrecognized string contexts may also
        # be refused.
        local _raw_scan='' _raw_needle=''
        for _rn in "${_slurp_names[@]}"; do
            _raw_scan="$_prog"
            _raw_needle="\$${_rn}["
            while [[ "$_raw_scan" == *"$_raw_needle"* ]]; do
                _raw_scan=${_raw_scan#*"$_raw_needle"}
                if [[ "$_raw_scan" != '0]'* ]]; then
                    printf '%s\n' "[!] jq shim: unsupported bracket use of --rawfile '$_rn'; jq >= 1.6 is required." >&2
                    return 2
                fi
            done
        done
        _prog_new="$_prog"
        for _rn in "${_slurp_names[@]}"; do
            _prog_new=$(printf '%s' "$_prog_new" | sed -E "s/\\\$${_rn}([^A-Za-z0-9_\[]|\$)/\\\$${_rn}[0]\\1/g")
        done
    fi
    # Temp files created below hold secrets briefly; remove the whole
    # temp dir on every return path (including early return 2). The guard
    # only removes dirs this function created (basename abox-jq.*).
    # H-15 + M-37: the RETURN trap is a single global slot: save the
    # caller's trap before installing ours, and restore it from inside
    # the trap action when this function returns, so a direct jq() call
    # can no longer clobber the caller's cleanup (e.g. users_sync's
    # _jq_cfg removal). Restoring inside the action (not before `return`)
    # is deliberate: a restored caller trap must fire when the CALLER
    # returns, not when this shim returns. Every return path below ALSO
    # removes the temp dir explicitly (belt and braces; the rm is
    # idempotent, so a double cleanup is harmless).
    local _jq_caller_trap=''
    _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap '[[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
    # Pass 2: rebuild argv, reading each --rawfile source exactly once.
    _i=0; _ri=0
    while (( _i < _n )); do
        _a=${_all[_i]}
        case "$_a" in
            --rawfile)
                if (( _i + 2 < _n )); then
                    _rn=${_all[_i+1]}; _rf=${_all[_i+2]}; _i=$(( _i + 3 ))
                    if [[ ! -r "$_rf" ]]; then
                        printf '%s\n' "[!] jq shim: cannot read --rawfile file: $_rf" >&2
                        [[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null
                        return 2
                    fi
                    if [[ "${_raw_slurp[_ri]:-0}" == 1 ]]; then
                        # Materialize to a real temp file (see header):
                        # a /dev/fd/N pipe handoff breaks on bash 5.0
                        # with 2+ pipes. Encode straight to the file
                        # with redirections only (no nested $(...) while
                        # pipe fds are still open). mktemp makes the
                        # file 0600; the dir is 0700; both are removed
                        # explicitly after the final `command jq`, and
                        # each early `return 2` removes the dir first
                        # (M-37: no RETURN trap -- it would clobber the
                        # caller's trap).
                        if [[ -z "${_jq_tmpdir:-}" ]]; then
                            _jq_tmpdir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/abox-jq.XXXXXX") || { printf '%s\n' "[!] jq shim: cannot create temp dir" >&2; return 2; }
                        fi
                        _tmpf=$(umask 077; mktemp "$_jq_tmpdir/raw.XXXXXX") || { printf '%s\n' "[!] jq shim: cannot create temp file for: $_rn" >&2; [[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null; return 2; }
                        command jq -R -s . < "$_rf" > "$_tmpf" 2>/dev/null || { printf '%s\n' "[!] jq shim: cannot encode --rawfile file: $_rf" >&2; [[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null; return 2; }
                        _args+=(--slurpfile "$_rn" "$_tmpf")
                    else
                        _content=$(cat -- "$_rf" && printf x) || { printf '%s\n' "[!] jq shim: cannot read --rawfile file: $_rf" >&2; [[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null; return 2; }
                        _content=${_content%x}
                        _args+=(--arg "$_rn" "$_content")
                    fi
                    _ri=$(( _ri + 1 ))
                else
                    _args+=("$_a"); _i=$(( _i + 1 ))
                fi ;;
            --arg|--argjson|--slurpfile|--argfile)
                _args+=("$_a")
                if (( _i + 1 < _n )); then _args+=("${_all[_i+1]}"); fi
                if (( _i + 2 < _n )); then _args+=("${_all[_i+2]}"); fi
                _i=$(( _i + 3 )) ;;
            -f|--from-file|--indent|-L)
                _args+=("$_a")
                if (( _i + 1 < _n )); then _args+=("${_all[_i+1]}"); fi
                _i=$(( _i + 2 )) ;;
            *)
                if (( _i == _prog_idx && ${#_slurp_names[@]} > 0 )); then _args+=("$_prog_new"); else _args+=("$_a"); fi
                _i=$(( _i + 1 )) ;;
        esac
    done
    command jq "${_args[@]}"
    local _rc=$?
    # Explicit cleanup: this function sets no RETURN trap (M-37 -- it
    # would clobber the caller's trap), so the temp dir is removed on
    # every return path, including each early `return 2` in Pass 2
    # above. A trailing `command` in a command-substitution subshell
    # may be exec-optimized, so the function may never return; the
    # removal here is the primary path for the success path.
    [[ -n "${_jq_tmpdir:-}" && "${_jq_tmpdir##*/}" == abox-jq.* ]] && rm -rf -- "$_jq_tmpdir" 2>/dev/null
    return "$_rc"
}

# L-12(2): one startup probe (see _abox_jq_probe_rawfile_shim above).
_abox_jq_probe_rawfile_shim


# Display width: accurate for CJK, symbols, 2-byte Latin/Cyrillic, emoji
# 14-system safe: byte-based, no locale dependency
# Optimized: single awk (was 2x grep + 3x wc = 5 subprocesses)

DEPS_MARKER='/etc/ddr/.deps.v20260725'
SCRIPT_URL='https://raw.githubusercontent.com/alariclin/A-Box/main/install.sh'
# ABOX_DIR is FIXED at /etc/ddr and is NOT customisable: this
# assignment is unconditional, so an ABOX_DIR exported in the
# environment has no effect. The ABOX_DIR default-value fallbacks
# elsewhere are same-value defensive reads, not a customisation
# hook -- do not "fix" them by parameterising the directory.
ABOX_DIR='/etc/ddr'
ABOX_ENV='/etc/ddr/.env'
ABOX_FW_STATE='/etc/ddr/.firewall-native.rules'
ABOX_BACKUP_KEY='/etc/ddr/.backup-hmac.key'
ABOX_CORE_OWNERSHIP='/etc/ddr/.managed-core-files.tsv'
LOCK_FILE='/run/A-Box.lock'
LANG_FILE='/etc/ddr/.lang'
IP_PREF_FILE='/etc/ddr/.ip-pref'
DNS_STATE_FILE='/etc/ddr/.dns-state'
DNS_BACKUP_DIR='/etc/ddr/.dns-backup'
TZ_STATE_FILE="${ABOX_DIR}/.timezone-state"
ABOX_CORE_MIRROR_RELEASE='core-binaries'
ABOX_CORE_MIRROR_BASE_DEFAULT='https://github.com/alariclin/A-Box/releases/download/core-binaries'
FAST_MODE_FILE='/etc/ddr/.fast-mode'
MIRROR_PREFER_FILE='/etc/ddr/.mirror-prefer'
EXTRA_UUID_FILE='/etc/ddr/.extra-uuids'
SUBSCRIBE_DIR='/etc/ddr/subscribe'
PUBLIC_IP_CACHE='/etc/ddr/.public_ip.cache'
PUBLIC_IP_CACHE_TTL=600
BACKUP_RETENTION_COUNT=${BACKUP_RETENTION_COUNT:-10}
LOCK_FALLBACK_DIR='/run/A-Box.lock.d'
ABOX_LANG='zh'
ABOX_BUILD='2026-11-10-arbitrated-fix-v193'
ABOX_BUILD_EPOCH=20261110193
WALLOS_DIR='/opt/wallos'
# P2-03 (hardening, not a confirmed vulnerability): one shared Docker
# launch-hardening profile for every Wallos container (install,
# rollback, recovery, rebind). Narrow profile only: drop NET_RAW and
# forbid privilege gains at exec. The fuller candidate (cap-drop ALL +
# minimal cap-add set + memory/cpus/pids limits) is NOT enabled here:
# it is unproven against the real Wallos image and must be validated
# on real Docker before it becomes the default. --read-only is
# deliberately absent: Wallos needs writable paths beyond the db/logos
# volumes and the tmpfs recipe for them is unverified.
WALLOS_DOCKER_HARDENING=(
    --cap-drop NET_RAW
    --security-opt no-new-privileges
)
# D-04: top-level init (set -u is active; rollback reads this before any writer runs).
WALLOS_IMAGE_RESULT=''
# H7-F1: the container ID most recently created by a Wallos (re)build
# helper (wallos_http_rebind / wallos_restore_direct_container), so the
# installer can refresh the upgrade journal with it. Same idiom as
# WALLOS_IMAGE_RESULT (a global because the helpers cannot return a
# value through a command substitution without losing side effects).
WALLOS_CREATED_CONTAINER_ID=''
WALLOS_MIRROR_RELEASE='wallos-mirror'
ABOX_TEST_MIRROR_RELEASE='test-tools-mirror'
# Geo mirror fallback (fetch_geo_data): A-Box-signed mirror of the
# Loyalsoldier geoip.dat/geosite.dat assets, same trust model as
# test-tools-mirror (detached Ed25519 SHA256SUMS.sig + SHA-256 of the
# asset itself; any verification failure refuses the mirror file).
# NOTE: the 'geo-mirror' Release does not exist yet — it must be populated
# by CI (assets geoip.dat, geosite.dat, SHA256SUMS + SHA256SUMS.sig signed
# with the F-05 key) before the fallback can succeed; until then the mirror
# leg fails closed and fetch_geo_data keeps its old die behaviour.
# Override the base with ABOX_GEO_MIRROR_BASE (https:// only).
ABOX_GEO_MIRROR_RELEASE='geo-mirror'
ABOX_GEO_MIRROR_BASE_DEFAULT='https://github.com/alariclin/A-Box/releases/download/geo-mirror'
# Xray target for an explicitly selected pinned policy;
# not an automatic disaster-recovery fallback.
# It is NOT the default install target: Xray now tracks the latest stable
# release by default (auto-stable, draft/prerelease excluded),
# like sing-box and Hysteria. Xray 26.9.8/26.9.9 introduces the newer REALITY
# ML-KEM ClientHello gate; public interoperability reports show breakage with
# common non-PQ clients, so the ML-KEM threshold is still enforced separately
# (ABOX_XRAY_REALITY_MLKEM_MIN_VERSION). Explicit ABOX_XRAY_VERSION overrides
# remain available for operators who intentionally pin a version.
ABOX_XRAY_DEFAULT_VERSION='v26.11.9'
# Stable sing-box compatibility pin; refresh and validate client/config
# compatibility before changing the pinned version.
ABOX_SINGBOX_DEFAULT_VERSION='v1.14.4'
# Historical mirror asset mapping, NOT a promise that the version is still in
# the mirror: superseded mirror assets are pruned on update. Automatic
# disaster recovery reads the current verified mirror version instead
# (core_latest_mirror_release_ref). Recovery is refused for other pins.
ABOX_XRAY_MIRROR_VERSION='v26.11.9'
ABOX_SINGBOX_MIRROR_VERSION='v1.14.4'
ABOX_HYSTERIA_MIRROR_VERSION='app/v2.14.0'
ABOX_HYSTERIA_DEFAULT_VERSION='app/v2.14.0'
# Per-core update policy (2026-11-10, latest-first):
#   xray:     auto-stable - track the latest official stable release
#                           (draft/prerelease excluded).
#                           Xray >=v26.9.8 requires an ML-KEM key share and
#                           breaks sing-box/mihomo/Karing clients (see
#                           sing-box#4520, mihomo#3193); the ML-KEM threshold
#                           is enforced separately (see
#                           ABOX_XRAY_REALITY_MLKEM_MIN_VERSION).
#   sing-box: auto-stable - track latest official stable release; verify
#                           generated config with the new binary before switch;
#                           rollback to the current mirror version on failure.
#   hysteria: auto-stable - track latest official stable release; Hy2 protocol
#                           guarantees old/new client interop; rollback on failure.
# Override via environment: ABOX_XRAY_UPDATE_POLICY / ABOX_SINGBOX_UPDATE_POLICY /
# ABOX_HYSTERIA_UPDATE_POLICY. Explicit ABOX_*_VERSION always wins over policy.
# Explicit ABOX_*_UPDATE_POLICY=pinned keeps the fallback version below as
# the install target; it is not a promise that the mirror still holds it.
ABOX_XRAY_UPDATE_POLICY="${ABOX_XRAY_UPDATE_POLICY:-auto-stable}"
ABOX_SINGBOX_UPDATE_POLICY="${ABOX_SINGBOX_UPDATE_POLICY:-auto-stable}"
ABOX_HYSTERIA_UPDATE_POLICY="${ABOX_HYSTERIA_UPDATE_POLICY:-auto-stable}"
# Normal Xray slot paths. Moved here when the xray-latest coexistence block
# was deleted (2026-11-09); generic code still addresses the slot through
# these names. XRAY_SLOT_DIR was XL-only and is gone with the block.
XRAY_SLOT_BIN='/usr/local/bin/xray'
XRAY_SLOT_CFG='/usr/local/etc/xray/config.json'
# ============ F-05: Ed25519 detached-signature trust root ============
# Mirror metadata (CORE-VERSIONS, SHA256SUMS, wallos-manifest.txt) is
# published as detached-signed files (<name>.sig, base64 of raw 64-byte
# Ed25519 signature). Verification uses ONLY openssl + python3 (both are
# already in ensure_commands); no GPG/minisign/signify dependency.
#
# PUBLIC KEYS ARE HARDCODED HERE — never fetched from the Release being
# verified (that would let an attacker replace metadata + sig + key together).
# Format per entry: "label:base64(raw 32-byte Ed25519 pubkey)".
# Dual-key window: keep primary + next/backup during rotation.
#   1. New install.sh adds the new pubkey to this array.
#   2. CI switches to signing with the new private key.
#   3. A later release removes the old pubkey.
ABOX_SIGNING_PUBKEYS=(
    # Production Ed25519 public key (base64 raw 32 bytes).
    # Private key held in GitHub Actions Secret ABOX_SIGNING_PRIVKEY_B64.
    'release-2026:7V4PBUUVpnfYhKu5LBxACxywpYEtvnDpVpvFnSrOujQ='
)
# SHA256 fingerprints (lowercase hex) of REVOKED public keys.
# A key listed here is skipped during verification even if present above.
# Emergency revocation: add the compromised key's fingerprint here, bump
# ABOX_BUILD_EPOCH, generate a new keypair per docs/SIGNING.md, and have CI
# re-sign all Release metadata with the new key.
ABOX_REVOKED_PUBKEY_FPS=(
)
# Minimum trusted metadata timestamp (UTC, YYYYMMDDHHMMSS). Metadata carrying
# an older updated_at_utc/retrieved_at_utc is rejected (anti-replay /
# anti-downgrade). Bump when rotating keys or after a revocation event.
ABOX_SIGNING_MIN_TIMESTAMP_UTC='20261015225900'
# Enforcement: 0 = verify-if-sig-present, warn-only on failure; 1 = STRICT fail-closed (default) —
# missing/invalid signature rejects the asset source (falls back to next
# trusted source, dies if none remain). NEVER warn-and-continue when 1.
ABOX_SIGNING_ENFORCE="${ABOX_SIGNING_ENFORCE:-1}"
# ========== end F-05 ==========
ABOX_RESOLVED_XRAY_VERSION=''
ABOX_RESOLVED_SINGBOX_VERSION=''
ABOX_RESOLVED_HYSTERIA_VERSION=''
ABOX_RESOLVED_XRAY_SOURCE=''
ABOX_RESOLVED_SINGBOX_SOURCE=''
ABOX_RESOLVED_HYSTERIA_SOURCE=''
ABOX_LAST_CORE_RELEASE_REF=''
ABOX_LAST_CORE_SOURCE=''
# Candidate library sizing. 0 uses the hard ceiling instead of the historical
# 4096 seed-only boundary; default 8192 keeps generated variants reachable.
ABOX_SNI_DEFAULT_MAX=8192
ABOX_SNI_HARD_MAX=16384
ABOX_SNI_CANDIDATE_URL_DEFAULT='https://raw.githubusercontent.com/alariclin/A-Box/main/data/sni-candidates.txt'
ABOX_SNI_CANDIDATE_MAX_BYTES=1048576
ABOX_SNI_CANDIDATE_MAX_ROWS=12000
ABOX_SNI_CANDIDATE_MIN_ROWS=100
ABOX_XRAY_REALITY_MLKEM_MIN_VERSION='v26.9.8'
ABOX_RUNTIME_XRAY_USER='abox-xray'
ABOX_RUNTIME_XRAY_GROUP='abox-xray'
ABOX_RUNTIME_SINGBOX_USER='abox-singbox'
ABOX_RUNTIME_SINGBOX_GROUP='abox-singbox'
ABOX_RUNTIME_HYSTERIA_USER='abox-hysteria'
ABOX_RUNTIME_HYSTERIA_GROUP='abox-hysteria'
ABOX_DESIRED_STATE='/etc/ddr/.desired_state'
ABOX_TRAFFIC_BLOCK_STATE='/etc/ddr/.traffic-block-state'
ABOX_TRAFFIC_PAIR_STATE='/etc/ddr/.traffic-pair-state'
HY2_ACME_OWNER_MARKER='/etc/hysteria/acme/.A-Box-managed'
PUBLIC_IP_CONNECT_TIMEOUT=${PUBLIC_IP_CONNECT_TIMEOUT:-3}
PUBLIC_IP_MAX_TIME=${PUBLIC_IP_MAX_TIME:-6}
# M2: total wall-clock budget (seconds) for one get_public_ip_fresh() round
# (all v4+v6 endpoints combined). Without it, three v4 endpoints at 6 s each
# plus three v6 endpoints could block the menu for ~36 s on a dead network;
# with the default 12 s the worst case is about one slow round plus a
# second attempt. The menu already serves a stale cache while refreshing
# in the background (get_public_ip_swr); this caps only the synchronous
# missing-cache path.
PUBLIC_IP_TOTAL_BUDGET=${PUBLIC_IP_TOTAL_BUDGET:-12}
ABOX_DEPLOY_TX_ACTIVE=0
ABOX_DEPLOY_TX_OWNER=''
ABOX_DEPLOY_TX_TARGETS=''
ABOX_DEPLOY_TX_REASON=''
ABOX_DEPLOY_TX_BACKUP=''
ABOX_DEPLOY_TX_TMP=''
ABOX_ROLLBACK_FALLBACK_RC=''
ABOX_DEPLOY_TX_BACKUP_DIR=''
ABOX_DEPLOY_TX_KEY_FILE=''
ABOX_DEPLOY_TX_EPHEMERAL_DIR=''
ABOX_LAST_BACKUP=''
ABOX_RUNTIME_LOCK_MODE=''
ABOX_TX_PREV_TRAP_EXIT=''
ABOX_TX_PREV_TRAP_INT=''
ABOX_TX_PREV_TRAP_TERM=''
ABOX_TX_PREV_TRAP_HUP=''
ABOX_CORE_TX_PREV_TRAP_EXIT=''
ABOX_CORE_TX_PREV_TRAP_INT=''
ABOX_CORE_TX_PREV_TRAP_TERM=''
ABOX_CORE_TX_PREV_TRAP_HUP=''
ABOX_CORE_UPGRADE_TARGETS=''
ABOX_CORE_UPGRADE_TMP=''
ABOX_TRAFFIC_TX_DIR=''

msg() { printf '%s\n' "$*"; }

# Activity indicator for long leaf commands (downloads, image pulls):
# ASCII spinner + label + elapsed seconds on stderr while the command
# runs; the command's exit code is returned unchanged. When stderr is
# not a TTY only a plain label line is printed. Wrap leaf commands only
# (never interactive ones, never functions that rely on die/exit).
abox_run_wait() {
    local _label="$1"; shift
    if [[ ! -t 2 ]]; then
        # The indicator belongs on stderr in both branches: callers
        # may capture the wrapped command's stdout.
        msg "  [*] ${_label} ..." >&2
        "$@"
        return $?
    fi
    # R15-F01-01: duplicate the caller's stdin into the background
    # job: without job control a background command inherits /dev/null
    # as stdin unless redirected, so the TTY branch used to read
    # different input from the foreground branch for the same command.
    "$@" <&0 9>&- 10>&- &
    local _pid=$! _i=0 _t0=$SECONDS _frames='|/-\\'
    while kill -0 "$_pid" 2>/dev/null; do
        printf '\r  [%s] %s ... %ds ' "${_frames:$((_i % 4)):1}" "$_label" "$((SECONDS - _t0))" >&2
        _i=$((_i + 1)); sleep 0.2
    done
    wait "$_pid"; local _rc=$?
    printf '\r\033[K' >&2
    return "$_rc"
}

# Standalone protocols register their share links here at deploy time so
# menu 12 can reproduce them later (combo links are rebuilt from .env,
# but standalone credentials live only inside the core configs).
# File format: line 1 = display title, lines 2+ = share URIs. Display
# cache only: every failure is swallowed, never fails a deployment.
register_standalone_link() {
    local _key="$1" _title="$2"; shift 2
    local _dir="${ABOX_DIR:-/etc/ddr}/standalone-links.d" _tmp _owner
    mkdir -p "$_dir" 2>/dev/null || return 0
    # R8-F1-1 (hardening/加固，防御纵深，非已确认漏洞): refuse a
    # symlinked or non-root-owned cache dir before chmod/mktemp
    # can follow it: chmod would retarget an outside dir and the
    # credential would land in the link target. Display cache
    # only, so every refusal is a silent return 0, never a
    # deployment failure.
    [[ -d "$_dir" && ! -L "$_dir" ]] || return 0
    _owner=$(stat -c '%u' -- "$_dir" 2>/dev/null) || return 0
    [[ "$_owner" == 0 ]] || return 0
    chmod 700 "$_dir" 2>/dev/null || return 0
    _tmp=$(mktemp "$_dir/.tmp.XXXXXX" 2>/dev/null) || return 0
    { printf '%s\n' "$_title"; printf '%s\n' "$@"; } > "$_tmp" 2>/dev/null         || { rm -f -- "$_tmp"; return 0; }
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$_dir/${_key}.link" 2>/dev/null || rm -f -- "$_tmp"
    return 0
}

# Derive an X25519 public key (base64url) from a raw private key
# (base64url) through an openssl PKCS#8 wrap; prints nothing on failure.
x25519_pub_from_priv() {
    local _priv="$1" _der _raw _pub
    [[ "$_priv" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    _der=$(mktemp /tmp/A-Box-x25519.XXXXXX) || return 1
    _raw=$(printf '%s' "$_priv" | tr '_-' '/+')
    while (( ${#_raw} % 4 )); do _raw+='='; done
    { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
      printf '%s' "$_raw" | base64 -d 2>/dev/null
    } > "$_der" || { rm -f -- "$_der"; return 1; }
    _pub=$(openssl pkey -inform DER -in "$_der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    rm -f -- "$_der"
    [[ "$_pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    printf '%s' "$_pub"
}

# Unescape one jq @tsv field value (\\ -> \, \t -> TAB, \n -> LF, \r -> CR).
# Unescape one jq @tsv field value: double backslash -> backslash, \t -> TAB, \n -> LF, \r -> CR.
# Single-pass scan: no placeholder, so no placeholder collision. Output via
# nameref (not stdout) so a trailing LF in the value survives: command
# substitution would strip it.
# Split a jq @tsv line on tabs, preserving empty fields, and assign the fields
# positionally to the caller's variables named after the line.
# (Plain IFS-tab read collapses consecutive tabs, losing empty middle columns,
# so it cannot be used for @tsv output.)
_tsv_split() {
    local _ts_line="$1" _ts_i=0 _ts_name
    local -a _ts_parts=()
    local _ts_rest="$_ts_line"
    shift
    while [[ "$_ts_rest" == *$'\t'* ]]; do
        _ts_parts+=( "${_ts_rest%%$'\t'*}" )
        _ts_rest="${_ts_rest#*$'\t'}"
    done
    _ts_parts+=( "$_ts_rest" )
    for _ts_name in "$@"; do
        local -n _ts_dst="$_ts_name"
        _ts_dst="${_ts_parts[_ts_i]:-}"
        _ts_i=$(( _ts_i + 1 ))
    done
}

_tsv_unescape() {
    [[ $# -eq 2 ]] || return 2
    local _tu_s="$1" _tu_out='' _tu_i=0 _tu_c='' _tu_n=''
    local -n _tu_res="$2"
    while (( _tu_i < ${#_tu_s} )); do
        _tu_c="${_tu_s:_tu_i:1}"
        if [[ "$_tu_c" == '\' && $(( _tu_i + 1 )) -lt ${#_tu_s} ]]; then
            _tu_n="${_tu_s:_tu_i+1:1}"
            case "$_tu_n" in
                '\') _tu_out+='\' ;;
                t) _tu_out+=$'\t' ;;
                n) _tu_out+=$'\n' ;;
                r) _tu_out+=$'\r' ;;
                *) _tu_out+="\\$_tu_n" ;;
            esac
            _tu_i=$(( _tu_i + 2 ))
        else
            _tu_out+="$_tu_c"
            _tu_i=$(( _tu_i + 1 ))
        fi
    done
    _tu_res="$_tu_out"
}

# R8-F1-3: a cached shadowtls link whose ss:// URI carries exactly one
# shadow-tls query parameter, and that parameter is empty, is a proven-bad
# link published by the old unchecked pipeline. The rebuild gate treats
# it as missing so the next rebuild retries. Anything else that exists (a
# valid link, unparseable content, a duplicate parameter) is left alone —
# never deleted or rebuilt on suspicion.
# R14-F01-02: an ss:// URI with an empty userinfo part (nothing
# before '?') carrying a shadow-tls parameter is likewise
# proven-bad: it is the "ss://?shadow-tls=<nonempty>" the old
# unchecked _ub step published.
# Rebuild missing standalone registry entries from the live core configs
# (nodes deployed before the registry existed). Best-effort: a node with
# no data at all for a link is skipped silently; partial data warns. Argo is registry-only - its
# domains live in cloudflared logs, not in the core config.
# _tuic_cert_self_signed <cert-file>
# Returns 0 only when the certificate at <cert-file> is positively proven
# self-signed. R15-F01-02: issuer==subject alone only proves the
# certificate is self-issued (RFC 5280); a self-issued certificate may
# still be signed by another key, so the signature must also verify
# against the certificate's own public key. openssl verify -check_ss_sig
# with the certificate as its own trust anchor checks exactly that; the
# first certificate is isolated first (the file may carry a chain) and
# trust is restricted to it (-no-CApath, plus -no-CAstore on
# OpenSSL 3.x; R16-F01-01). Any other outcome
# (not self-issued, signature failure, unreadable, OpenSSL without
# -check_ss_sig) returns 1, "not proven" — never "proven otherwise", so
# callers stay fail-closed. -no_check_time keeps the question purely "is
# the signature self-made": expiry is moot once verification is skipped,
# and it preserves the old behaviour for genuinely self-signed certs.
_tuic_cert_self_signed() {
    local _cert_file="$1" _iss='' _sub='' _meta='' _tmp=''
    [[ -f "$_cert_file" && ! -L "$_cert_file" && -r "$_cert_file" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    _meta=$(openssl x509 -noout -in "$_cert_file" -issuer -subject 2>/dev/null) || return 1
    _iss=$(printf '%s\n' "$_meta" | sed -n 's/^issuer=//p')
    _sub=$(printf '%s\n' "$_meta" | sed -n 's/^subject=//p')
    [[ -n "$_iss" && -n "$_sub" && "$_iss" == "$_sub" ]] || return 1
    _tmp=$(umask 077; mktemp /tmp/A-Box-tuic-cert.XXXXXX 2>/dev/null) || return 1
    if ! openssl x509 -in "$_cert_file" -out "$_tmp" 2>/dev/null; then rm -f -- "$_tmp"; return 1; fi
    # R16-F01-01: -no-CAstore is an OpenSSL 3.x option; 1.1.1
    # (Debian 10/11, Ubuntu 20.04) rejects it as unknown, so the
    # check always fails there. Probe for the option once and use
    # the 3.x form only when it exists. The 1.1.1 fallback keeps
    # trust isolated the same way: with -CAfile given, 1.1.1 loads
    # no default store, and -no-CApath excludes the default dir.
    # Dropping -no-CAstore on 3.x would NOT be equivalent: there
    # the default store is still consulted alongside -CAfile, so a
    # store-trusted CA could vouch for a self-issued certificate.
    # The help text is captured first, not piped into grep -q:
    # under pipefail an early grep exit can SIGPIPE openssl and
    # flip this test to the 1.1.1 branch on a 3.x host.
    local _verify_args=(-check_ss_sig -no-CApath -no_check_time) _verify_help=''
    _verify_help=$(openssl verify -help 2>&1 || :)
    if [[ "$_verify_help" == *'-no-CAstore'* ]]; then
        _verify_args=(-check_ss_sig -no-CApath -no-CAstore -no_check_time)
    fi
    if openssl verify "${_verify_args[@]}" -CAfile "$_tmp" "$_tmp" >/dev/null 2>&1; then
        rm -f -- "$_tmp"
        return 0
    fi
    rm -f -- "$_tmp"
    return 1
}

# Port on line 2 of a standalone .link file (the URI's dial port), or
# nothing when the file is missing/unreadable. Used by the Trojan -2
# legacy migration: a port identifies the inbound, so a legacy
# trojan-landing-N.link whose port matches a per-core file is that
# inbound's duplicate/stale copy.
_standalone_link_port() {
    local _f="$1" _u=''
    [[ -f "$_f" && ! -L "$_f" ]] || return 1
    _u=$(sed -n '2p' "$_f" 2>/dev/null) || return 1
    [[ "$_u" =~ :([0-9]+)(\?|#|$) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

rebuild_standalone_links() {
    local _dir="${ABOX_DIR:-/etc/ddr}/standalone-links.d" _ip="${F_IP:-}"
    [[ "$_ip" == 'N/A' ]] && _ip=''
    # M-35: a domain-only deployment (no usable public IP) must still
    # rebuild the Hy2 link from HY2_DOMAIN; return early only when
    # there is neither an IP nor a domain.
    # M41-NEW-01 follow-up (S2-NEW-09/E62-NEW-02): rebuild used to
    # only add missing links and never delete stale ones, so a
    # same-core overwrite left orphaned .link files that menu 12
    # reprinted as dead nodes. Prune both cores' stale links first --
    # the survivor check deletes only a link whose inbound is
    # confirmed gone from live config (H-26(3) rc-1-only semantics)
    # -- then the blocks below re-create any missing live link.
    # Runs before the early return so stale links are pruned even
    # when the IP is unknown. Hysteria is not pruned here: hy2.link
    # is refreshed from live config in the Hy2 block below (deleted
    # there only once the Hysteria config is confirmed gone).
    _prune_standalone_links xray || true
    _prune_standalone_links sing-box || true
    [[ -n "$_ip" || -n "${HY2_DOMAIN:-}" ]] || return 0
    local _xc="${ABOX_XRAY_CFG:-/usr/local/etc/xray/config.json}" _sc="${ABOX_SB_CFG:-/etc/sing-box/config.json}"
    local _port='' _pass='' _sni='' _sid='' _pk='' _pub='' _uuid='' _cc='' _inner='' _user='' _cert='' _insecure='' _iss='' _sub='' _obfs='' _obfs_raw='' _url='' _cert_inline='' _meta='' _nul='' _net='' _svc='' _wspath='' _wshost='' _xpath='' _ttype='' _alpn='' _has_pass='' _detour='' _inner_method='' _inner_user='' _inner_nul=''
    local _tj_row='' _tj_rows='' _tj_tag='' _tj_stem='' _tj_seen='' _tj_legacy_n='' _tj_n='' _tj_leg='' _tj_leg_port='' _tj_sfx='' _tj_pc='' _tj_pc_port=''
    local _sk_row='' _sk_rows='' _sk_tag='' _sk_stem='' _sk_seen='' _sk_legacy_n='' _sk_n='' _sk_leg='' _sk_leg_port='' _sk_sfx='' _sk_pc='' _sk_pc_port='' _sk_type=''
    local _tuic_row='' _tuic_rows='' _tuic_seen='' _anytls_row='' _anytls_rows='' _anytls_seen='' _sh_row='' _sh_rows='' _sh_seen='' _tuic_tag='' _tuic_stem='' _anytls_tag='' _anytls_stem='' _sh_tag='' _sh_stem=''
    if [[ -n "$_ip" && -f "$_xc" ]]; then
        _tj_rows=$(jsonc_strip_comments "$_xc" 2>/dev/null | jq -r '.inbounds[]? | select(.protocol=="trojan" and ((.streamSettings.realitySettings.privateKey // "") != "")) | [(.tag // ""), (.port|tostring), (.settings.clients[0].password // ""), (.streamSettings.realitySettings.privateKey // ""), (.streamSettings.realitySettings.serverNames[0] // ""), (.streamSettings.realitySettings.shortIds[0] // ""), ((.settings.clients[0].password // "") | contains("\u0000")), (.streamSettings.network // "tcp"), (.streamSettings.grpcSettings.serviceName // ""), (.streamSettings.wsSettings.path // ""), (.streamSettings.wsSettings.headers.Host // ""), (.streamSettings.xhttpSettings.path // "")] | @tsv' 2>/dev/null) || _tj_rows=''
        _tj_seen=''
        while IFS= read -r _tj_row; do
            [[ -n "$_tj_row" ]] || continue
            _port=''; _pass=''; _pk=''; _sni=''; _sid=''; _nul=''; _net=''; _svc=''; _wspath=''; _wshost=''; _xpath=''
            _tsv_split "$_tj_row" _tj_tag _port _pass _pk _sni _sid _nul _net _svc _wspath _wshost _xpath
            # R01b-01: a non-managed tag is NOT the default node --
            # renaming it to trojan-landing lets a foreign inbound
            # sorted first claim the trojan-xray stem and the real
            # default is then skipped by _tj_seen. Skip it.
            case "$_tj_tag" in
                trojan-landing|trojan-landing-[0-9]*) ;;
                *) continue ;;
            esac
            _tj_stem=$(users_link_stem xray "$_tj_tag" 2>/dev/null || printf '%s' "$_tj_tag")
            case " $_tj_seen " in *" $_tj_stem "*) continue ;; esac
            _tj_seen+=" $_tj_stem"
            # R01b-X: derive the legacy number from the original
            # tag -- the per-core stem (trojan-xray-N) never matched
            # trojan-landing-[0-9]*, so _tj_legacy_n stayed empty.
            case "$_tj_tag" in
                trojan-landing-[0-9]*)
                    _tj_n="${_tj_tag#trojan-landing-}"
                    case " $_tj_legacy_n " in *" $_tj_n "*) ;; *) _tj_legacy_n+=" $_tj_n" ;; esac ;;
            esac
            _tsv_unescape "$_pass" _pass; _tsv_unescape "$_pk" _pk; _tsv_unescape "$_sni" _sni; _tsv_unescape "$_sid" _sid; _tsv_unescape "$_net" _net; _tsv_unescape "$_svc" _svc; _tsv_unescape "$_wspath" _wspath; _tsv_unescape "$_wshost" _wshost; _tsv_unescape "$_xpath" _xpath
            if [[ "$_nul" == 'true' ]]; then
                printf '%s\n' "${YELLOW}trojan password contains a NUL byte, link skipped (${_tj_stem})${NC}" >&2
            elif [[ "$_port" =~ ^[0-9]+$ && -n "$_pass" && -n "$_pk" ]]; then
                # 2bf: emit the real transport instead of a wrong
                # type=tcp — ws/xhttp clients dial the wrong transport
                # on a tcp link. Unknown networks stay type=tcp.
                _ttype='type=tcp'
                if [[ "$_net" == 'grpc' ]]; then _ttype='type=grpc'; [[ -n "$_svc" ]] && _ttype="${_ttype}&serviceName=$(urlencode "$_svc")";
                elif [[ "$_net" == 'ws' ]]; then
                    _ttype='type=ws'
                    [[ -n "$_wspath" ]] && _ttype="${_ttype}&path=$(urlencode "$_wspath")"
                    [[ -n "$_wshost" ]] && _ttype="${_ttype}&host=$(urlencode "$_wshost")"
                elif [[ "$_net" == 'xhttp' ]]; then
                    _ttype='type=xhttp'
                    [[ -n "$_xpath" ]] && _ttype="${_ttype}&path=$(urlencode "$_xpath")"
                fi
                _pub=$(x25519_pub_from_priv "$_pk") && [[ -n "$_pub" ]] && \
                register_standalone_link "$_tj_stem" "$(tprintf sl_node_port 'Trojan-Reality (Xray)' "$_port")" "trojan://$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}?security=reality&sni=${_sni}&fp=chrome&pbk=${_pub}&sid=${_sid}&${_ttype}#Trojan-Reality"
            elif [[ -n "$_port$_pass$_pk$_sni$_sid" ]]; then
                printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_tj_stem")${NC}" >&2
            fi
        done <<< "$_tj_rows"
        if true; then  # S1-NEW-02 (ported): always refresh from the live survivor
            _sk_rows=$(jsonc_strip_comments "$_xc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^socks5-landing(-[0-9]+)?$")) | [(.tag // ""), (.port|tostring), (.settings.accounts[0].user // ""), (.settings.accounts[0].pass // ""), (((.settings.accounts[0].user // "") | contains("\u0000")) or ((.settings.accounts[0].pass // "") | contains("\u0000")))] | @tsv' 2>/dev/null) || _sk_rows=''
            _sk_seen=''
            while IFS= read -r _sk_row; do
                [[ -n "$_sk_row" ]] || continue
                _port=''; _user=''; _pass=''
                _tsv_split "$_sk_row" _sk_tag _port _user _pass _nul
                case "$_sk_tag" in
                    socks5-landing|socks5-landing-[0-9]*) ;;
                    *) _sk_tag='socks5-landing' ;;
                esac
                _sk_stem=$(users_link_stem xray "$_sk_tag" 2>/dev/null || printf '%s' "$_sk_tag")
                case " $_sk_seen " in *" $_sk_stem "*) continue ;; esac
                _sk_seen+=" $_sk_stem"
                # R01b-X: derive the legacy number from the original
                # tag -- the per-core stem (socks5-xray-N) never matched
                # socks5-landing-[0-9]*, so _sk_legacy_n stayed empty.
                case "$_sk_tag" in
                    socks5-landing-[0-9]*)
                        _sk_n="${_sk_tag#socks5-landing-}"
                        case " $_sk_legacy_n " in *" $_sk_n "*) ;; *) _sk_legacy_n+=" $_sk_n" ;; esac ;;
                esac
                _tsv_unescape "$_user" _user; _tsv_unescape "$_pass" _pass
                if [[ "$_nul" == 'true' ]]; then
                    printf '%s\n' "${YELLOW}socks5 credentials contain a NUL byte, link skipped (${_sk_stem})${NC}" >&2
                elif [[ "$_port" =~ ^[0-9]+$ && -n "$_user" ]]; then
                    register_standalone_link "$_sk_stem" "$(tprintf sl_node_port 'SOCKS5 (Xray)' "$_port")" "socks5://$(urlencode "$_user"):$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}"
                elif [[ -n "$_port$_user$_pass" ]]; then
                    printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sk_stem")${NC}" >&2
                fi
            done <<< "$_sk_rows"
        fi
    fi
    if [[ -n "$_ip" && -f "$_sc" ]]; then
        _tj_rows=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^trojan-landing(-[0-9]+)?$")) | [(.tag // ""), (.listen_port|tostring), (.password // .users[0].password // ""), (.tls.reality.private_key // ""), (.tls.server_name // ""), ((.tls.reality.short_id | if type == "array" then .[0] else . end) // ""), ((.password // .users[0].password // "") | contains("\u0000")), (.transport.type // "tcp"), (.transport.path // ""), (((.transport.headers.Host // "") | if type == "array" then .[0] else . end)), (.transport.service_name // "")] | @tsv' 2>/dev/null) || _tj_rows=''
        _tj_seen=''
        while IFS= read -r _tj_row; do
            [[ -n "$_tj_row" ]] || continue
            _port=''; _pass=''; _pk=''; _sni=''; _sid=''; _nul=''; _net=''; _wspath=''; _wshost=''; _svc=''
            _tsv_split "$_tj_row" _tj_tag _port _pass _pk _sni _sid _nul _net _wspath _wshost _svc
            case "$_tj_tag" in
                trojan-landing|trojan-landing-[0-9]*) ;;
                *) _tj_tag='trojan-landing' ;;
            esac
            _tj_stem=$(users_link_stem sing-box "$_tj_tag" 2>/dev/null || printf '%s' "$_tj_tag")
            case " $_tj_seen " in *" $_tj_stem "*) continue ;; esac
            _tj_seen+=" $_tj_stem"
            # R01b-X: derive the legacy number from the original
            # tag -- the per-core stem (trojan-xray-N) never matched
            # trojan-landing-[0-9]*, so _tj_legacy_n stayed empty.
            case "$_tj_tag" in
                trojan-landing-[0-9]*)
                    _tj_n="${_tj_tag#trojan-landing-}"
                    case " $_tj_legacy_n " in *" $_tj_n "*) ;; *) _tj_legacy_n+=" $_tj_n" ;; esac ;;
            esac
            _tsv_unescape "$_pass" _pass; _tsv_unescape "$_pk" _pk; _tsv_unescape "$_sni" _sni; _tsv_unescape "$_sid" _sid; _tsv_unescape "$_net" _net; _tsv_unescape "$_wspath" _wspath; _tsv_unescape "$_wshost" _wshost; _tsv_unescape "$_svc" _svc
            if [[ "$_nul" == 'true' ]]; then
                printf '%s\n' "${YELLOW}trojan password contains a NUL byte, link skipped (${_tj_stem})${NC}" >&2
            elif [[ "$_port" =~ ^[0-9]+$ && -n "$_pass" && -n "$_pk" ]]; then
                # 2bf: same transport mapping as the Xray arm — a ws /
                # xhttp / grpc trojan must not be emitted as type=tcp.
                _ttype='type=tcp'
                if [[ "$_net" == 'grpc' ]]; then _ttype='type=grpc'; [[ -n "$_svc" ]] && _ttype="${_ttype}&serviceName=$(urlencode "$_svc")";
                elif [[ "$_net" == 'ws' ]]; then
                    _ttype='type=ws'
                    [[ -n "$_wspath" ]] && _ttype="${_ttype}&path=$(urlencode "$_wspath")"
                    [[ -n "$_wshost" ]] && _ttype="${_ttype}&host=$(urlencode "$_wshost")"
                elif [[ "$_net" == 'xhttp' ]]; then
                    _ttype='type=xhttp'
                    [[ -n "$_wspath" ]] && _ttype="${_ttype}&path=$(urlencode "$_wspath")"
                fi
                _pub=$(x25519_pub_from_priv "$_pk") && [[ -n "$_pub" ]] && \
                register_standalone_link "$_tj_stem" "$(tprintf sl_node_port 'Trojan-Reality (sing-box)' "$_port")" "trojan://$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}?security=reality&sni=${_sni}&fp=chrome&pbk=${_pub}&sid=${_sid}&${_ttype}#Trojan-Reality"
            elif [[ -n "$_port$_pass$_pk$_sni$_sid" ]]; then
                printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_tj_stem")${NC}" >&2
            fi
        done <<< "$_tj_rows"
        if true; then  # S1-NEW-02 (ported): always refresh from the live survivor
            # B01-01: iterate every matching inbound (same rows loop
            # as Trojan/SOCKS5 above); first(...) only rebuilt the
            # first tuic-in and left tuic-in-2 stale.
            _tuic_rows=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^tuic-in(-[0-9]+)?$")) | [(.listen_port|tostring), (.users[0].uuid // ""), (.users[0].password // ""), (.congestion_control // "bbr"), (.tls.server_name // ""), ((.tls.alpn | if type == "array" then .[0] else . end) // "h3"), (.users[0] | has("password")), (.tls.certificate_path // ""), ((.users[0].password // "") | contains("\u0000")), (.tag // "")] | @tsv' 2>/dev/null) || _tuic_rows=''
            _tuic_seen=''
            while IFS= read -r _tuic_row; do
            [[ -n "$_tuic_row" ]] || continue
            _port=''; _uuid=''; _pass=''; _cc=''; _sni=''; _nul=''
            _tsv_split "$_tuic_row" _port _uuid _pass _cc _sni _alpn _has_pass _cert _nul _tuic_tag
            _tsv_unescape "$_uuid" _uuid; _tsv_unescape "$_pass" _pass; _tsv_unescape "$_cc" _cc; _tsv_unescape "$_sni" _sni; _tsv_unescape "$_alpn" _alpn; _tsv_unescape "$_cert" _cert
            # N3 (followup5 D-leg): register under the matched
            # inbound's own stem (tuic-in -> tuic, tuic-in-2 ->
            # tuic-in-2). The old fixed stem `tuic` rewrote
            # tuic.link from the -2 survivor, duplicating the
            # tuic-in-2.link URI in menu 12 output.
            _tuic_stem=$(users_link_stem sing-box "${_tuic_tag:-}" 2>/dev/null || printf '%s' 'tuic')
            [[ -n "$_tuic_stem" ]] || _tuic_stem='tuic'
            case " $_tuic_seen " in *" $_tuic_stem "*) continue ;; esac
            _tuic_seen+=" $_tuic_stem"
            if [[ "$_nul" == 'true' ]]; then
                printf '%s\n' "${YELLOW}tuic password contains a NUL byte, link skipped (${_tuic_stem})${NC}" >&2
            elif [[ "$_port" =~ ^[0-9]+$ && -n "$_uuid" && ( -n "$_pass" || "$_has_pass" == 'true' ) ]]; then
                # R8-F1-2: fail-closed default — allow_insecure=1 is
                # written only when the certificate is positively
                # proven self-signed: the signature must also verify
                # against the certificate's own public key (R15-F01-02;
                # issuer==subject alone only proves self-issued).
                # Unknown or
                # unverifiable material never authorises skipping
                # verification. Inline .tls.certificate takes
                # priority over certificate_path (it is the cert
                # sing-box actually uses); a failed inline parse
                # must not fall back to the path for an insecure
                # conclusion.
                _insecure=''
                # R11-F R8-02: inline-certificate presence is a
                # three-state fact (present/absent/unknown). Only a
                # positively confirmed absence authorises the
                # certificate_path branch below; an unusable or
                # unextractable inline value never falls back to
                # the path for an insecure conclusion. The link is
                # still registered, just without allow_insecure=1.
                local _cert_inline_state='unknown' _cert_inline_present='' _inline_tmp=''
                _cert_inline=''
                if _cert_inline_present=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r --arg t "$_tuic_tag" 'first(.inbounds[]? | select(.tag == $t)) | .tls | if . == null then false elif type == "object" then (has("certificate") and (.certificate != null)) else error("invalid tls type") end' 2>/dev/null); then
                    case "$_cert_inline_present" in
                        true) _cert_inline_state='present' ;;
                        false) _cert_inline_state='absent' ;;
                    esac
                fi
                if [[ "$_cert_inline_state" == 'present' ]]; then
                    _cert_inline=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r --arg t "$_tuic_tag" 'first(.inbounds[]? | select(.tag == $t)) | .tls.certificate | if type == "string" then . elif type == "array" then if all(.[]; type == "string") then join("\n") else error("inline certificate array must contain only strings") end else error("unsupported inline certificate type") end' 2>/dev/null) || _cert_inline=''
                fi
                if [[ -n "$_cert_inline" ]]; then
                    # R15-F01-02: the inline PEM goes through the same
                    # proof as a file certificate (see
                    # _tuic_cert_self_signed) via a temp file.
                    _inline_tmp=$(umask 077; mktemp /tmp/A-Box-tuic-cert.XXXXXX 2>/dev/null) || _inline_tmp=''
                    if [[ -n "$_inline_tmp" ]] && printf '%s\n' "$_cert_inline" > "$_inline_tmp" 2>/dev/null && _tuic_cert_self_signed "$_inline_tmp"; then _insecure='allow_insecure=1'; fi
                    [[ -n "$_inline_tmp" ]] && rm -f -- "$_inline_tmp"
                elif [[ "$_cert_inline_state" == 'absent' && -n "$_cert" && -f "$_cert" && ! -L "$_cert" && -r "$_cert" ]]; then
                    if _tuic_cert_self_signed "$_cert"; then _insecure='allow_insecure=1'; fi
                fi
                register_standalone_link "$_tuic_stem" "$(tprintf sl_node_port 'TUIC' "$_port")" "tuic://${_uuid}:$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}?congestion_control=${_cc}&alpn=$(urlencode "$_alpn")&sni=${_sni}${_insecure:+&${_insecure}}#TUIC"
            elif [[ -n "$_port$_uuid$_pass$_cc$_sni" ]]; then
                printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_tuic_stem")${NC}" >&2
            fi
            done <<< "$_tuic_rows"
        fi
        if true; then  # S1-NEW-02 (ported): always refresh from the live survivor
            # B01-01: iterate every matching inbound (same rows loop
            # as Trojan/SOCKS5 above); first(...) only rebuilt the
            # first anytls-in and left anytls-in-2 stale.
            _anytls_rows=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^anytls-in(-[0-9]+)?$")) | [(.listen_port|tostring), (.users[0].password // .password // ""), (.tls.reality.private_key // ""), (.tls.server_name // ""), ((.tls.reality.short_id | if type == "array" then .[0] else . end) // ""), ((.users[0].password // .password // "") | contains("\u0000")), (.tag // "")] | @tsv' 2>/dev/null) || _anytls_rows=''
            _anytls_seen=''
            while IFS= read -r _anytls_row; do
            [[ -n "$_anytls_row" ]] || continue
            _port=''; _pass=''; _pk=''; _sni=''; _sid=''; _nul=''
            _tsv_split "$_anytls_row" _port _pass _pk _sni _sid _nul _anytls_tag
            _tsv_unescape "$_pass" _pass; _tsv_unescape "$_pk" _pk; _tsv_unescape "$_sni" _sni; _tsv_unescape "$_sid" _sid
            # N3 (followup5 D-leg): register under the matched
            # inbound's own stem (anytls-in -> anytls, anytls-in-2
            # -> anytls-in-2).
            _anytls_stem=$(users_link_stem sing-box "${_anytls_tag:-}" 2>/dev/null || printf '%s' 'anytls')
            [[ -n "$_anytls_stem" ]] || _anytls_stem='anytls'
            case " $_anytls_seen " in *" $_anytls_stem "*) continue ;; esac
            _anytls_seen+=" $_anytls_stem"
            if [[ "$_nul" == 'true' ]]; then
                printf '%s\n' "${YELLOW}anytls password contains a NUL byte, link skipped (${_anytls_stem})${NC}" >&2
            elif [[ "$_port" =~ ^[0-9]+$ && -n "$_pass" && -n "$_pk" ]]; then
                # B01-02: derivation and registration must NOT be one
                # && chain with comments in between. Bash skips comment
                # lines when looking for the && operand, so the stem
                # assignment below IS the chain's right operand: a
                # failed derivation short-circuits it, and under the
                # script's set -u the later unbound _anytls_stem
                # aborts the whole script (|| true cannot save it);
                # without set -u it registers a pbk= bad link over
                # the good cache. Gate the registration on a
                # non-empty derived key explicitly instead.
                _pub=$(x25519_pub_from_priv "$_pk" 2>/dev/null) || _pub=''
                if [[ -n "$_pub" ]]; then
                    register_standalone_link "$_anytls_stem" "$(tprintf sl_node_port 'AnyTLS-Reality' "$_port")" "anytls://$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}?security=reality&sni=${_sni}&fp=chrome&pbk=${_pub}&sid=${_sid}#AnyTLS-Reality"
                else
                    printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_anytls_stem")${NC}" >&2
                fi
            elif [[ -n "$_port$_pass$_pk$_sni$_sid" ]]; then
                printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_anytls_stem")${NC}" >&2
            fi
            done <<< "$_anytls_rows"
        fi
        # R8-F1-3: an existing link is trusted. The old
        # empty-shadow-tls exception was subsumed by S1-NEW-02
        # (always refresh from the live survivor).
        if true; then  # S1-NEW-02 (ported): always refresh from the live survivor (empty-shadowtls retry subsumed)
            # B01-01: iterate every matching inbound (same rows loop
            # as Trojan/SOCKS5 above); first(...) only rebuilt the
            # first shadowtls-in and left shadowtls-in-2 stale.
            _sh_rows=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^shadowtls-in(-[0-9]+)?$")) | [(.listen_port|tostring), (.users[0].password // ""), (.handshake.server // ""), (.detour // ""), (.tag // ""), ((.users[0].password // "") | contains("\u0000"))] | @tsv' 2>/dev/null) || _sh_rows=''
            _sh_seen=''
            while IFS= read -r _sh_row; do
            [[ -n "$_sh_row" ]] || continue
            _port=''; _pass=''; _sni=''; _inner=''
            _tsv_split "$_sh_row" _port _pass _sni _detour _sh_tag _nul
            _tsv_unescape "$_pass" _pass; _tsv_unescape "$_sni" _sni; _tsv_unescape "$_detour" _detour
            # N3 (followup5 D-leg): register under the matched
            # inbound's own stem (shadowtls-in -> shadowtls,
            # shadowtls-in-2 -> shadowtls-in-2).
            _sh_stem=$(users_link_stem sing-box "${_sh_tag:-}" 2>/dev/null || printf '%s' 'shadowtls')
            [[ -n "$_sh_stem" ]] || _sh_stem='shadowtls'
            case " $_sh_seen " in *" $_sh_stem "*) continue ;; esac
            _sh_seen+=" $_sh_stem"
            if [[ "$_nul" == 'true' ]]; then
                printf '%s\n' "${YELLOW}shadowtls password contains a NUL byte, link skipped (${_sh_stem})${NC}" >&2
            elif [[ "$_port" =~ ^[0-9]+$ && -n "$_pass" ]]; then
                if [[ -z "$_detour" ]]; then
                    printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sh_stem")${NC}" >&2
                else
                    _tsv_split "$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r --arg t "$_detour" 'first(.inbounds[]? | select(.tag == $t)) | [(.password // ""), (.method // ""), (.users[0].password // ""), (((.password // "") | contains("\u0000")) or ((.users[0].password // "") | contains("\u0000")))] | @tsv' 2>/dev/null)" _inner _inner_method _inner_user _inner_nul
                    _tsv_unescape "$_inner" _inner; _tsv_unescape "$_inner_method" _inner_method; _tsv_unescape "$_inner_user" _inner_user
                    [[ -n "$_inner_method" ]] || _inner_method='2022-blake3-aes-128-gcm'
                    if [[ "$_inner_nul" == 'true' ]]; then
                        printf '%s\n' "${YELLOW}shadowtls password contains a NUL byte, link skipped (${_sh_stem})${NC}" >&2
                    elif [[ -n "$_inner" ]]; then
                        local _ub _pb _pb_json _cred
                        if [[ -n "$_inner_user" ]]; then _cred="${_inner_method}:${_inner}:${_inner_user}"; else _cred="${_inner_method}:${_inner}"; fi
                        # R14-F01-02: check this encoding step too
                        # (same pipefail + non-empty discipline as
                        # _pb below): a failed base64 must leave
                        # _ub empty so the link is skipped, not
                        # published as "ss://?shadow-tls=<nonempty>".
                        _ub=$(set -o pipefail; printf '%s' "${_cred}@$(uri_host "$_ip"):${_port}" | base64 | tr -d '\n\r') || _ub=''
                    # R8-F1-3: check every encoding step before
                    # publishing. jq runs alone so its status is
                    # visible (the old pipeline's status was tr's);
                    # the base64 step runs under a subshell-local
                    # pipefail so a partial non-empty output from a
                    # failed upstream cannot slip through. Any
                    # failure warns and skips this registration only
                    # (no file is published, so the next rebuild
                    # retries); other protocols are unaffected.
                    if [[ -n "$_ub" ]] &&
                       _pb_json=$(jq -cn --arg h "$_sni" --rawfile p <(printf '%s' "$_pass") '{version:"3", host:$h, password:$p}') &&
                       [[ -n "$_pb_json" ]] &&
                       _pb=$(set -o pipefail; printf '%s' "$_pb_json" | base64 | tr -d '\n\r') &&
                       [[ -n "$_pb" ]]; then
                        register_standalone_link "$_sh_stem" "$(tprintf sl_node_port 'ShadowTLS' "$_port")" "ss://${_ub}?shadow-tls=${_pb}#ShadowTLS"
                    else
                        printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sh_stem")${NC}" >&2
                    fi
                    else
                        printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sh_stem")${NC}" >&2
                    fi
                fi
            elif [[ -n "$_port$_pass$_sni$_inner" ]]; then
                printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sh_stem")${NC}" >&2
            fi
            done <<< "$_sh_rows"
        fi
        if true; then  # S1-NEW-02 (ported): always refresh from the live survivor
            _sk_rows=$(jsonc_strip_comments "$_sc" 2>/dev/null | jq -r '.inbounds[]? | select((.tag // "") | test("^socks5-landing(-[0-9]+)?$")) | [(.tag // ""), (.listen_port|tostring), (.users[0].username // ""), (.users[0].password // ""), (((.users[0].username // "") | contains("\u0000")) or ((.users[0].password // "") | contains("\u0000"))), (.type // "socks")] | @tsv' 2>/dev/null) || _sk_rows=''
            _sk_seen=''
            while IFS= read -r _sk_row; do
                [[ -n "$_sk_row" ]] || continue
                _port=''; _user=''; _pass=''; _sk_type=''
                _tsv_split "$_sk_row" _sk_tag _port _user _pass _nul _sk_type
                case "$_sk_tag" in
                    socks5-landing|socks5-landing-[0-9]*) ;;
                    *) _sk_tag='socks5-landing' ;;
                esac
                _sk_stem=$(users_link_stem sing-box "$_sk_tag" 2>/dev/null || printf '%s' "$_sk_tag")
                case " $_sk_seen " in *" $_sk_stem "*) continue ;; esac
                _sk_seen+=" $_sk_stem"
                # R01b-X: derive the legacy number from the original
                # tag -- the per-core stem (socks5-xray-N) never matched
                # socks5-landing-[0-9]*, so _sk_legacy_n stayed empty.
                case "$_sk_tag" in
                    socks5-landing-[0-9]*)
                        _sk_n="${_sk_tag#socks5-landing-}"
                        case " $_sk_legacy_n " in *" $_sk_n "*) ;; *) _sk_legacy_n+=" $_sk_n" ;; esac ;;
                esac
                _tsv_unescape "$_user" _user; _tsv_unescape "$_pass" _pass
                if [[ "$_nul" == 'true' ]]; then
                    printf '%s\n' "${YELLOW}socks5 credentials contain a NUL byte, link skipped (${_sk_stem})${NC}" >&2
                elif [[ "$_port" =~ ^[0-9]+$ && -n "$_user" ]]; then
                    if [[ "$_sk_type" == 'mixed' ]]; then
                        register_standalone_link "$_sk_stem" "$(tprintf sl_node_port 'Mixed (sing-box)' "$_port")" "socks5://$(urlencode "$_user"):$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}" "http://$(urlencode "$_user"):$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}"
                    else
                        register_standalone_link "$_sk_stem" "$(tprintf sl_node_port 'SOCKS5 (sing-box)' "$_port")" "socks5://$(urlencode "$_user"):$(urlencode "$_pass")@$(uri_host "$_ip"):${_port}"
                    fi
                elif [[ -n "$_port$_user$_pass" ]]; then
                    printf '%s\n' "${YELLOW}$(tprintf standalone_link_incomplete "$_sk_stem")${NC}" >&2
                fi
            done <<< "$_sk_rows"
        fi
    fi
    # Trojan -2 migration: a pre-fix deploy wrote both cores' -2 chains
    # into one ambiguous trojan-landing-N.link. Once this rebuild has
    # written the per-core stem files, the legacy file is a duplicate
    # (same port) or stale (superseded by its own core's per-core
    # file); drop it only when its port matches a live per-core file,
    # so a chain whose core did not rebuild this run is kept.
    for _tj_n in $_tj_legacy_n; do
        _tj_leg="$_dir/trojan-landing-${_tj_n}.link"
        [[ -f "$_tj_leg" && ! -L "$_tj_leg" ]] || continue
        _tj_leg_port=$(_standalone_link_port "$_tj_leg" 2>/dev/null || true)
        [[ -n "$_tj_leg_port" ]] || continue
        for _tj_sfx in sb xray; do
            _tj_pc="$_dir/trojan-${_tj_sfx}-${_tj_n}.link"
            [[ -f "$_tj_pc" && ! -L "$_tj_pc" ]] || continue
            _tj_pc_port=$(_standalone_link_port "$_tj_pc" 2>/dev/null || true)
            if [[ -n "$_tj_pc_port" && "$_tj_pc_port" == "$_tj_leg_port" ]]; then
                rm -f -- "$_tj_leg" 2>/dev/null || true
                break
            fi
        done
    done
    # SOCKS5 -2 migration: same shape as the Trojan -2 migration above
    # (a pre-fix deploy wrote both cores' -2 chains into one ambiguous
    # socks5-landing-N.link). Drop the legacy file only when its port
    # matches a live per-core file, so a chain whose core did not
    # rebuild this run is kept.
    for _sk_n in $_sk_legacy_n; do
        _sk_leg="$_dir/socks5-landing-${_sk_n}.link"
        [[ -f "$_sk_leg" && ! -L "$_sk_leg" ]] || continue
        _sk_leg_port=$(_standalone_link_port "$_sk_leg" 2>/dev/null || true)
        [[ -n "$_sk_leg_port" ]] || continue
        for _sk_sfx in sb xray; do
            _sk_pc="$_dir/socks5-${_sk_sfx}-${_sk_n}.link"
            [[ -f "$_sk_pc" && ! -L "$_sk_pc" ]] || continue
            _sk_pc_port=$(_standalone_link_port "$_sk_pc" 2>/dev/null || true)
            if [[ -n "$_sk_pc_port" && "$_sk_pc_port" == "$_sk_leg_port" ]]; then
                rm -f -- "$_sk_leg" 2>/dev/null || true
                break
            fi
        done
    done
    # E19: official Hy2 never registered a standalone link, so menu 12 /
    # export showed no Hy2 node even though view_config prints the URL.
    # Secrets come from config.yaml itself, the port list from the
    # environment (same source view_config uses); a missing/unusable
    # pin refuses the link.
    # M41-NEW-01 follow-up: the file is refreshed on every rebuild,
    # not only when missing -- a deploy-time bare password goes stale
    # the moment the server switches to userpass (the S1 404), and a
    # link for a deleted server must not survive. The config path
    # honours ABOX_HY2_CONFIG (fixture hook, same convention as
    # hy2_effective_password_for_user); a symlinked config is
    # unverifiable, so the old file is kept (fail-closed, same as
    # the prune rc-2 rule), while a confirmed-gone config deletes it.
    local _hycfg="${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}"
    if [[ -L "$_hycfg" ]]; then
        :
    elif [[ ! -e "$_hycfg" ]]; then
        rm -f -- "$_dir/hy2.link" 2>/dev/null || true
    elif [[ -f "$_hycfg" ]]; then
        _pass=''; _obfs=''; _url=''; _port=''
        # R16-F01-02: same trailing-LF sentinel as the obfs branch
        # below: jq -r + $() strips a trailing LF from the password,
        # caching a wrong credential for a password that ends in LF.
        # hy2_effective_password now prefers main (M41-NEW-01
        # follow-up), so the refreshed link is main's composite in
        # userpass mode, never the deploy-time bare password.
        _pass=$(hy2_effective_password 2>/dev/null || printf '%s' "${HY2_PASS:-}")
        _pass=${_pass%__ABOX_TRAILING_NL_KEEP__}
        _obfs_raw=$(awk '/^obfs:/{f=1} f && /^[^[:space:]#]/{if ($0 !~ /^obfs:/) exit} f{print}' "$_hycfg" 2>/dev/null | sed -n 's/^[[:space:]]*password:[[:space:]]*//p' | head -1)
        if [[ -n "${_obfs_raw:-}" ]]; then
            _obfs=$(users_hy2_yaml_scalar "$_obfs_raw" 2>/dev/null) || _obfs=''
            _obfs=${_obfs%__ABOX_TRAILING_NL_KEEP__}
        fi
        if [[ -n "$_pass" && -n "${_obfs:-}" ]]; then
            _url=$(hy2_standalone_url "$_pass" "$_obfs" "" 2>/dev/null || true)
            if [[ -n "$_url" ]]; then
                IFS=$'\t' read -r _port _ < <(build_hy2_uri_endpoint 2>/dev/null || true)
                [[ -n "$_port" ]] && register_standalone_link hy2 "$(tprintf sl_node_port 'Hysteria 2' "$_port")" "$_url"
            fi
        fi
    fi
    return 0
}
die() {
    printf '%s\n' "${RED}[!] $*${NC}" >&2
    # OBS-2: capture the hook name BEFORE invoking it. The hook itself
    # (deployment_transaction_rollback_inner) clears ABOX_DIE_HOOK on
    # entry, so formatting the message after the call printed ''.
    local _die_hook="${ABOX_DIE_HOOK:-}"
    if [[ -n "$_die_hook" ]] && declare -F "$_die_hook" >/dev/null 2>&1; then
        # H-17: only the transaction owner process (or a top-level shell)
        # may run the rollback hook. A die() inside a command substitution
        # runs in a child shell whose BASHPID differs from the transaction
        # owner; running the hook there would roll back (destructively)
        # while the parent keeps deploying with empty values. The subshell
        # still exits 1, so the parent's || die fires the hook exactly
        # once, in the right process.
        if [[ "${BASH_SUBSHELL:-0}" == 0 || "${BASHPID:-}" == "${ABOX_DEPLOY_TX_OWNER:-}" ]]; then
            if ! "$_die_hook" "$*"; then
                # OBS-2: two tiers. When the deployment rollback ran its
                # best-effort service restart from the snapshot
                # (ABOX_ROLLBACK_FALLBACK_RC==0), the strong "manual
                # recovery may be required" claim misleads: the services
                # were restarted. Downgrade to a verify-first notice.
                # When the restart itself failed (or no fallback ran),
                # keep the strong warning.
                if [[ "$_die_hook" == 'deployment_transaction_rollback' && "${ABOX_ROLLBACK_FALLBACK_RC:-}" == '0' ]]; then
                    printf '%s\n' "${RED}[!] WARNING: rollback hook '$_die_hook' reported failure, but services were restarted from the pre-operation snapshot (best-effort); verify services before manual recovery.${NC}" >&2
                else
                    printf '%s\n' "${RED}[!] WARNING: rollback hook '$_die_hook' failed; manual recovery may be required.${NC}" >&2
                fi
            fi
        fi
    fi
    # OBS-1: a failed deploy must not leak its staging. The transaction
    # rollback removes ABOX_DEPLOY_TX_TMP when it runs, but landing
    # deploys run with no transaction, and the rollback itself can abort
    # before reaching its staging cleanup. Remove this process's own
    # staging here, under the same owner-process gate as the hook, so a
    # die() inside a command substitution never deletes the parent's
    # live staging. Only a /tmp, /var/tmp or ${ABOX_DIR:-/etc/ddr} A-Box-* directory is ever removed (never
    # /tmp itself, never a path with '..', never a symlink or a file).
    if [[ "${BASH_SUBSHELL:-0}" == 0 || "${BASHPID:-}" == "${ABOX_DEPLOY_TX_OWNER:-}" ]]; then
        if [[ -n "${ABOX_DEPLOY_TX_TMP:-}" && ( "${ABOX_DEPLOY_TX_TMP}" == /tmp/A-Box-?* || "${ABOX_DEPLOY_TX_TMP}" == /var/tmp/A-Box-?* || "${ABOX_DEPLOY_TX_TMP}" == "${ABOX_DIR:-/etc/ddr}"/A-Box-?* ) && "${ABOX_DEPLOY_TX_TMP}" != *..* && -d "${ABOX_DEPLOY_TX_TMP}" && ! -L "${ABOX_DEPLOY_TX_TMP}" ]]; then
            rm -rf -- "${ABOX_DEPLOY_TX_TMP}" 2>/dev/null || true
            ABOX_DEPLOY_TX_TMP=''
        fi
    fi
    exit 1
}
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }


abox_dir_has_legacy_fingerprint() {
    local dir="${1:-$ABOX_DIR}" count=0 only='' entry base
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    if [[ -f "$dir/A-Box.sh" && ! -L "$dir/A-Box.sh" ]] &&
       grep -q '==============================A-Box===============================' "$dir/A-Box.sh" 2>/dev/null &&
       grep -q '^main "\$@"' "$dir/A-Box.sh" 2>/dev/null; then
        return 0
    fi
    if [[ -f "$dir/.env" && ! -L "$dir/.env" ]]; then
        if ( load_abox_env "$dir/.env" >/dev/null 2>&1 && [[ "${CORE:-}" =~ ^(xray|singbox|hysteria)$ ]] ); then
            return 0
        fi
    fi
    while IFS= read -r -d '' entry; do
        base=${entry##*/}
        [[ "$base" == '.' || "$base" == '..' ]] && continue
        count=$((count + 1))
        only="$base"
        (( count <= 1 )) || return 1
    done < <(
        shopt -s nullglob dotglob
        for entry in "$dir"/*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            printf '%s\0' "$entry"
        done
    )
    if (( count == 0 )); then
        return 0
    fi
    if (( count == 1 )) && [[ "$only" == '.lang' && -f "$dir/.lang" && ! -L "$dir/.lang" ]]; then
        grep -Eq '^(zh|zh-tw|en|ja|ru|fa)[[:space:]]*$' "$dir/.lang"
        return
    fi
    return 1
}

path_owned_by_root() {
    local path="$1" uid gid
    [[ -e "$path" && ! -L "$path" ]] || return 1
    uid=$(stat -c %u "$path" 2>/dev/null) || return 1
    gid=$(stat -c %g "$path" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 ]]
}

path_mode_has_no_group_other_write() {
    local path="$1" mode
    mode=$(stat -c %a "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

path_is_mountpoint() {
    local path="$1" rc
    [[ -e "$path" || -L "$path" ]] || return 1
    if python3 -I - "$path" <<'PY_EXACT_MOUNT' >/dev/null 2>&1
import os, re, sys

# R8C1-01: never collapse link/.. lexically before resolving:
# normpath turns link/../live into a sibling path and misses the real mount.
# Check the final component on the raw argument, then realpath it.
arg = sys.argv[1].rstrip('/') or '/'
if os.path.islink(arg):
    raise SystemExit(3)
path = os.path.realpath(arg).rstrip('/') or '/'
try:
    with open('/proc/self/mountinfo', 'r', encoding='utf-8', errors='strict') as f:
        for line in f:
            fields = line.rstrip('\n').split(' ')
            if len(fields) < 5:
                continue
            raw = fields[4]
            mp = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), raw)
            mp = os.path.realpath(mp).rstrip('/') or '/'
            if mp == path:
                raise SystemExit(0)
except (OSError, UnicodeError):
    # mountinfo is the authoritative source for Linux mount topology. If it
    # cannot be read, the caller cannot safely prove that the path is not a
    # mountpoint; fail closed rather than falling back to ismount().
    raise SystemExit(0)
raise SystemExit(3)
PY_EXACT_MOUNT
    then
        rc=0
    else
        rc=$?
    fi
    # R7C1-02: only rc=3 is a definitive "not a mountpoint" verdict. A
    # Python interpreter/init failure also exits 1, so 1 must fail closed
    # like any other helper failure, not pass as "not a mountpoint".
    case "$rc" in
        0) return 0 ;;
        3) return 1 ;;
        *) return 0 ;;
    esac
}

path_tree_has_nested_mountpoint() {
    local path="${1:-}" rc
    [[ -n "$path" && ( -d "$path" || -f "$path" ) && ! -L "$path" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -I - "$path" <<'PY_TREE_NESTED_MOUNT'
import os, re, sys
def decode_mountinfo_path(value):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), value)
try:
    target=os.path.realpath(sys.argv[1]).rstrip('/') or '/'
    prefix='/' if target == '/' else target + '/'
    with open('/proc/self/mountinfo','r',encoding='utf-8',errors='strict') as f:
        for raw in f:
            # R10C1-02: ASCII space only. Bare split() also splits
            # U+00A0 (unescaped in mountinfo), shifting parts[4].
            parts=raw.rstrip('\n').split(' ')
            if len(parts) < 5:
                raise RuntimeError('malformed mountinfo')
            mountpoint=decode_mountinfo_path(parts[4])
            mountpoint=os.path.realpath(mountpoint).rstrip('/') or '/'
            if mountpoint.startswith(prefix):
                raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
raise SystemExit(3)
PY_TREE_NESTED_MOUNT
    rc=$?
    # R7C1-02: only rc=3 is a definitive "no nested mountpoint" verdict.
    # A Python interpreter/init failure also exits 1, so 1 must fail closed
    # like any other helper failure.
    case "$rc" in
        0) return 0 ;;
        3) return 1 ;;
        *) return 0 ;;
    esac
}

path_tree_has_mountpoint() {
    local path="$1" rc
    [[ -e "$path" || -L "$path" ]] || return 1
    if python3 -I - "$path" <<'PY_TREE_MOUNT' >/dev/null 2>&1
import os, sys

# Linux os.path.ismount() can miss bind mounts when the mount and parent
# reside on the same device. /proc/self/mountinfo is authoritative for the
# current mount namespace and also catches nested bind mounts.
# R8C1-01: same as path_is_mountpoint: resolve the raw argument,
# do not let normpath collapse link/.. before symlink resolution.
arg = sys.argv[1].rstrip('/') or '/'
if os.path.islink(arg):
    raise SystemExit(3)
root = os.path.realpath(arg).rstrip('/') or '/'

import re
def decode_mountinfo_path(value):
    # Decode each kernel mountinfo octal escape exactly once. Sequential
    # replacement can turn a literal backslash sequence into a different
    # escape and corrupt a legitimate path.
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), value)

mountpoints = []
try:
    with open('/proc/self/mountinfo', 'r', encoding='utf-8', errors='strict') as f:
        for line in f:
            fields = line.rstrip('\n').split(' ')
            if len(fields) >= 5:
                mp = os.path.realpath(decode_mountinfo_path(fields[4])).rstrip('/') or '/'
                mountpoints.append(mp)
except (OSError, UnicodeError):
    # mountinfo is the authoritative source for Linux mount topology. If it
    # cannot be read, the caller cannot safely prove that the tree is free of
    # mounts; fail closed rather than using weaker ismount()/os.walk() checks.
    raise SystemExit(0)

if root == '/':
    raise SystemExit(0)
for mp in mountpoints:
    if mp == root or mp.startswith(root + os.sep):
        raise SystemExit(0)
raise SystemExit(3)
PY_TREE_MOUNT
    then
        rc=0
    else
        rc=$?
    fi
    # R7C1-02: only rc=3 is a definitive "not a mountpoint" verdict. A
    # Python interpreter/init failure also exits 1, so 1 must fail closed
    # like any other helper failure, not pass as "not a mountpoint".
    case "$rc" in
        0) return 0 ;;
        3) return 1 ;;
        *) return 0 ;;
    esac
}
# R16-F05-02: ancestor-aware mount check (bash mirror of
# _path_or_ancestors_mounted in remove_recorded_core_family).
# path_tree_has_mountpoint only sees the path itself and below it:
# a bind mount on /usr/local/bin (an ancestor of the binary) is
# invisible to it — proven by fixture (bind over /usr/local/bin,
# rm -f still deleted the shared backend file). Walk from the path
# up to (excluding) / and exact-check each level with
# path_is_mountpoint. Each level is canonicalised first: a symlink
# ancestor is short-circuited to "not a mountpoint" by
# path_is_mountpoint without resolving it, so lexical dirname steps
# would miss a symlink that resolves under a mountpoint (M-13(3)).
# Self/subtree coverage is kept by also calling
# path_tree_has_mountpoint first.
# No trust allowlist: redeploy orphan cleanup defaults to deny
# (unlike the uninstall flow's ABOX_TRUSTED_UNINSTALL_ANCESTORS);
# a separately-mounted /usr must be cleaned up manually.
path_tree_or_ancestors_mounted() {
    local path="$1" cur _real
    [[ -e "$path" || -L "$path" ]] || return 1
    path_tree_has_mountpoint "$path" && return 0
    cur="$path"
    while [[ "$cur" != '/' && "$cur" == */ ]]; do cur="${cur%/}"; done
    while [[ "$cur" != '/' ]]; do
        # M-13(3): judge this level by its target chain, not by the
        # link itself: path_is_mountpoint short-circuits a symlink
        # to "not a mountpoint" without resolving it. A failed
        # canonicalisation keeps the lexical level (fail closed is
        # handled by path_is_mountpoint's own rc mapping).
        _real=$(realpath "$cur" 2>/dev/null || readlink -f "$cur" 2>/dev/null || true)
        [[ -n "$_real" ]] && cur="$_real"
        if path_is_mountpoint "$cur"; then return 0; fi
        cur=$(dirname "$cur")
    done
    return 1
}

assert_default_abox_parent_chain_trusted() {
    local dir="$1" parent uid gid mode
    [[ "$dir" == '/etc/ddr' ]] || return 0
    for parent in / /etc; do
        [[ -d "$parent" && ! -L "$parent" ]] || die "$(tprintf pc_untrusted "$parent")"
        uid=$(stat -c %u "$parent" 2>/dev/null) || die "$(tprintf pc_owner_read "$parent")"
        gid=$(stat -c %g "$parent" 2>/dev/null) || die "$(tprintf pc_group_read "$parent")"
        mode=$(stat -c %a "$parent" 2>/dev/null) || die "$(tprintf pc_mode_read "$parent")"
        [[ "$uid" == 0 && "$gid" == 0 ]] || die "$(tprintf pc_not_root "$parent")"
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || die "$(tprintf pc_writable "$parent")"
    done
}

abox_dir_tighten_secrets() {
    # F01 (R2C1-01): /etc/ddr is 711 (traverse-only), so file
    # contents are gated only by their own modes. Tightening the
    # marker alone left a loose secret file readable by every local
    # user who knows its predictable name. Tighten the known
    # top-level secret files to root-owned 600 before the dir is
    # opened to traversal; a symlinked secret is refused, never
    # followed. Subdirectories are not recursed into: service
    # config dirs keep their own 750/group gating, and the link
    # dir (standalone-links.d, 700) is verified by
    # register_standalone_link before every write (R8-F1-1
    # hardening/加固: a symlinked or non-root-owned link dir is
    # refused instead of assumed to gate its files).
    local dir="$1" f
    for f in "$dir/.env" "$dir/.env".* "$dir/.backup-hmac.key" "$dir/.argo-token" "$dir/.routing-state" "$dir/.wallos-cf-token" "$dir/.shortcut" "$dir/.shortcut-migrate" "$dir"/*.tar.gz; do
        [[ -e "$f" || -L "$f" ]] || continue
        [[ ! -L "$f" ]] || die "$(tprintf do_secret_symlink "$f")"
        [[ -f "$f" ]] || continue
        chown root:root "$f" || die "$(tprintf do_secret_chown "$f")"
        chmod 600 "$f" || die "$(tprintf do_secret_chmod "$f")"
    done
    if [[ -d "$dir/backups" && ! -L "$dir/backups" ]]; then
        # R02-01: the per-file [[ ! -L ]] check below is only sound
        # when no non-root user can swap entries in this directory.
        # The parent $dir is pinned by ensure_abox_dir_owned, but the
        # backups subdir itself was never asserted: refuse an
        # untrusted one instead of chown/chmod-ing through it.
        path_owned_by_root "$dir/backups" || die "$(tprintf do_not_root "$dir/backups")"
        path_mode_has_no_group_other_write "$dir/backups" || die "$(tprintf do_writable "$dir/backups")"
        for f in "$dir/backups"/*.tar.gz; do
            [[ -e "$f" || -L "$f" ]] || continue
            [[ ! -L "$f" ]] || die "$(tprintf do_secret_symlink "$f")"
            [[ -f "$f" ]] || continue
            chown root:root "$f" || die "$(tprintf do_secret_chown "$f")"
            chmod 600 "$f" || die "$(tprintf do_secret_chmod "$f")"
        done
    fi
}

ensure_abox_dir_owned() {
    # SYD-B E9: ABOX_DIR is fixed at 0711 (traverse-only for others).
    # The old 0700 here re-tightened the dir on every menu entry and
    # revoked the o+x that prepare_abox_runtime_config_dir (U28) grants
    # so the abox-xray service user can traverse config directories.
    local dir="${1:-$ABOX_DIR}" owner tmp uid gid mode
    owner="$dir/.A-Box-owner"
    assert_default_abox_parent_chain_trusted "$dir"
    [[ ! -L "$dir" ]] || die "$(tprintf do_symlink "$dir")"
    if [[ -e "$dir" && ! -d "$dir" ]]; then
        die "$(tprintf do_notdir "$dir")"
    fi
    if [[ -d "$dir" ]]; then
        path_owned_by_root "$dir" || die "$(tprintf do_not_root "$dir")"
        path_mode_has_no_group_other_write "$dir" || die "$(tprintf do_writable "$dir")"
        if [[ -f "$owner" && ! -L "$owner" ]] && grep -Fxq 'A-Box managed directory v1' "$owner" 2>/dev/null; then
            path_owned_by_root "$owner" || die "$(tprintf do_mark_not_root "$owner")"
            mode=$(stat -c %a "$owner" 2>/dev/null) || die "$(tprintf do_mark_mode_read "$owner")"
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || die "$(tprintf do_mark_mode_unsafe "$owner")"
            abox_dir_tighten_secrets "$dir"
            chmod 711 "$dir" || die "$(tprintf do_tighten_dir "$dir")"
            chmod 600 "$owner" || die "$(tprintf do_tighten_mark "$owner")"
            return 0
        fi
        abox_dir_has_legacy_fingerprint "$dir" || die "$(tprintf do_legacy "$dir")"
    else
        mkdir -p "$dir" || die "$(tprintf do_mkdir "$dir")"
    fi
    chown root:root "$dir" || die "$(tprintf do_chown "$dir")"
    abox_dir_tighten_secrets "$dir"
    chmod 711 "$dir" || die "$(tprintf do_chmod "$dir")"
    tmp=$(umask 077; mktemp "$dir/.A-Box-owner.XXXXXX") || die "$(tr_msg do_mark_tmp)"
    printf '%s\n' 'A-Box managed directory v1' > "$tmp" || { rm -f "$tmp"; die "$(tr_msg do_mark_write)"; }
    chown root:root "$tmp" || { rm -f "$tmp"; die "$(tr_msg do_mark_chown)"; }
    chmod 600 "$tmp" || { rm -f "$tmp"; die "$(tr_msg do_mark_chmod)"; }
    [[ ! -d "$owner" && ! -L "$owner" ]] || { rm -f "$tmp"; die "$(tr_msg do_mark_commit)"; }
    mv -f "$tmp" "$owner" || { rm -f "$tmp"; die "$(tr_msg do_mark_commit)"; }
    path_owned_by_root "$owner" || die "$(tr_msg do_mark_verify)"
}

normalize_lang() {
    case "${1:-}" in
        en|en_US|en-US|english|English) printf 'en' ;;
        ru|ru_RU|ru-RU|russian|Русский) printf 'ru' ;;
        fa|fa_IR|fa-IR|persian|فارسی) printf 'fa' ;;
        ja|ja_JP|ja-JP|japanese|日本語) printf 'ja' ;;
        zh-tw|zh_TW|zh-TW|tw|TW|繁體中文|繁体中文) printf 'zh-tw' ;;
        zh|zh_CN|zh-CN|cn|CN|中文|'') printf 'zh' ;;
        *) printf 'zh' ;;
    esac
}

