# ABOX-MODULE-BEGIN 06-env-geo env/logging/fail2ban, geo fetch
#   Source: install.sh lines 24969-27913 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
write_file_atomically_from_stdin() {
    local dest="$1" mode="${2:-600}" dir base
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ ! -e "$dest" && ! -L "$dest" || -f "$dest" ]] || return 1
    [[ ! -L "$dest" && ! -d "$dest" ]] || return 1
    path_parent_chain_safe "$dest" || return 1
    if [[ -e "$dest" || -L "$dest" ]] && path_is_mountpoint "$dest"; then
        return 1
    fi
    dir=$(dirname "$dest")
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
        return 1
    fi
    [[ -d "$dir" ]] || mkdir -p "$dir" || return 1
    base=$(basename "$dest")
    # R16C7-01: the temp file is created, written, chmodded, chowned,
    # fsynced and renamed only through a held directory fd. Stdin is
    # written to the creation fd itself, never to a reopened pathname,
    # so a symlink swap in the destination directory cannot redirect
    # the write (or the chmod/chown) onto another file.
    python3 -I - "$dir" "$base" "$mode" 3<&0 <<'PY_ABOX_ATOMIC_WRITE'
import os
import secrets
import stat
import sys

dirpath, basename, mode_s = sys.argv[1], sys.argv[2], sys.argv[3]
mode = int(mode_s, 8)
try:
    dfd = os.open(dirpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(1)
tmpname = None
fd = None
try:
    for _ in range(100):
        cand = ".A-Box-new." + secrets.token_hex(8)
        try:
            fd = os.open(cand, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            tmpname = cand
            break
        except FileExistsError:
            continue
    if fd is None:
        sys.exit(1)
    while True:
        chunk = os.read(3, 65536)  # fd 3 = caller stdin (fd 0 is the script heredoc)
        if not chunk:
            break
        view = memoryview(chunk)
        while view:
            n = os.write(fd, view)
            view = view[n:]
    os.fchmod(fd, mode)
    if os.geteuid() == 0:
        os.fchown(fd, 0, 0)
    os.fsync(fd)
    st_fd = os.fstat(fd)
    st_name = os.stat(tmpname, dir_fd=dfd, follow_symlinks=False)
    if (st_fd.st_dev, st_fd.st_ino) != (st_name.st_dev, st_name.st_ino) or not stat.S_ISREG(st_name.st_mode):
        sys.exit(1)
    os.rename(tmpname, basename, src_dir_fd=dfd, dst_dir_fd=dfd)
    # R25 (F07-01): the replacement is committed. A directory-fsync
    # failure after rename must not fail the write (cf.
    # install_file_atomically, R10-F08-5): warn and succeed.
    try:
        os.fsync(dfd)
    except OSError:
        sys.stderr.write('A-Box: WARNING: file replaced, but parent directory sync failed; crash durability is not guaranteed.\n')
except OSError:
    try:
        if tmpname is not None and fd is not None:
            st = os.stat(tmpname, dir_fd=dfd, follow_symlinks=False)
            fst = os.fstat(fd)
            if (st.st_dev, st.st_ino) == (fst.st_dev, fst.st_ino):
                os.unlink(tmpname, dir_fd=dfd)
    except OSError:
        pass
    sys.exit(1)
finally:
    try:
        if fd is not None:
            os.close(fd)
    except OSError:
        pass
    try:
        os.close(dfd)
    except OSError:
        pass
sys.exit(0)
PY_ABOX_ATOMIC_WRITE
}
write_env() {
    local env_core="${1:-${CORE:-}}" env_mode="${2:-${MODE:-}}" old_traffic_limit_gb='' old_traffic_limit_mode='' tmp
    [[ -n "$env_core" && -n "$env_mode" ]] || die "$(tr_msg we_missing)"
    [[ ! -L "$ABOX_DIR" ]] || die "$(tr_msg we_dir_symlink)"
    if [[ -e "$ABOX_ENV" ]]; then
        [[ -f "$ABOX_ENV" && ! -L "$ABOX_ENV" ]] || die "$(tr_msg we_file_unsafe)"
        path_owned_by_root "$ABOX_ENV" || die "$(tr_msg we_file_owner)"
        path_mode_has_no_group_other_write "$ABOX_ENV" || die "$(tr_msg we_file_mode)"
    fi
    if [[ -f "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]; then
        # R3C7-04: decode with the verified shlex parser (as in
        # load_abox_env), not by deleting '"' characters: a
        # single-quoted old value must decode, not be cleared.
        local _old_parsed=''
        if ! _old_parsed=$(python3 -I - "$ABOX_ENV" 2>/dev/null <<'PY_WRITE_ENV_OLD'
import shlex, sys
gb = mode = ""
gb_ok = mode_ok = True
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="strict") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.startswith("TRAFFIC_LIMIT_GB="):
                rawv = line.split("=", 1)[1]
                if not rawv.strip():
                    gb = ""; gb_ok = True
                else:
                    parts = shlex.split(rawv, posix=True)
                    if len(parts) == 1:
                        gb = parts[0]; gb_ok = True
                    else:
                        gb_ok = False
            elif line.startswith("TRAFFIC_LIMIT_MODE="):
                rawv = line.split("=", 1)[1]
                if not rawv.strip():
                    mode = ""; mode_ok = True
                else:
                    parts = shlex.split(rawv, posix=True)
                    if len(parts) == 1:
                        mode = parts[0]; mode_ok = True
                    else:
                        mode_ok = False
except Exception:
    gb_ok = mode_ok = False
if not (gb_ok and mode_ok):
    sys.exit(1)
sys.stdout.write(gb + "\n" + mode + "\n")
PY_WRITE_ENV_OLD
        ); then
            die "$(tr_msg we_old_quota)"
        fi
        if [[ -n "$_old_parsed" ]]; then
            old_traffic_limit_gb=$(printf '%s\n' "$_old_parsed" | sed -n '1p')
            old_traffic_limit_mode=$(printf '%s\n' "$_old_parsed" | sed -n '2p')
        else
            old_traffic_limit_gb=''
            old_traffic_limit_mode=''
        fi
        # R6-05: a valid quota survives a missing mode (default total);
        # an explicit invalid mode aborts instead of silently cancelling
        # the quota; an invalid/empty GB keeps the old clear-both path.
        if [[ -n "$old_traffic_limit_gb" ]] &&
            valid_traffic_limit_gb "$old_traffic_limit_gb"; then
            case "$old_traffic_limit_mode" in
                '')
                    old_traffic_limit_mode='total'
                    ;;
                total|rx|tx)
                    ;;
                *)
                    die "$(tr_msg we_old_quota)"
                    ;;
            esac
        else
            old_traffic_limit_gb=''
            old_traffic_limit_mode=''
        fi
    fi
    # H-09: save/restore the caller umask (a bare umask 077 here used to
    # leak into the main shell and make later mkdir -p create 0700 dirs).
    local _we_umask
    _we_umask=$(umask)
    umask 077
    install -d -m 711 "$ABOX_DIR" || die "$(tr_msg we_dir_create)"
    tmp=$(mktemp "$ABOX_DIR/.env.A-Box-new.XXXXXX") || die "$(tr_msg we_tmp)"
    # R1-07-F2: run the write group under set -e so any printf
    # failure aborts it (the tail ifs alone would mask failures
    # with rc 0 when their conditions are false). The status is
    # captured explicitly: a subshell inside an || list has its
    # inner set -e suppressed by bash, so || die alone would not
    # catch the failure.
    ( set -e
        printf 'CORE=%s\n' "$(env_quote "$env_core")"
        printf 'MODE=%s\n' "$(env_quote "$env_mode")"
        printf 'UUID=%s\n' "$(env_quote "${UUID:-}")"
        printf 'VLESS_SNI=%s\n' "$(env_quote "${VLESS_SNI:-}")"
        printf 'VISION_SNI=%s\n' "$(env_quote "${VISION_SNI:-}")"
        printf 'XHTTP_SNI=%s\n' "$(env_quote "${XHTTP_SNI:-}")"
        printf 'VLESS_PORT=%s\n' "$(env_quote "${VLESS_PORT:-}")"
        printf 'XHTTP_PORT=%s\n' "$(env_quote "${XHTTP_PORT:-}")"
        printf 'HY2_BASE_PORT=%s\n' "$(env_quote "${HY2_BASE_PORT:-}")"
        printf 'HY2_DOMAIN=%s\n' "$(env_quote "${HY2_DOMAIN:-}")"
        printf 'HY2_UP=%s\n' "$(env_quote "${HY2_UP:-}")"
        printf 'HY2_DOWN=%s\n' "$(env_quote "${HY2_DOWN:-}")"
        printf 'HY2_MASQ_URL=%s\n' "$(env_quote "${HY2_MASQ_URL:-}")"
        printf 'SS_PORT=%s\n' "$(env_quote "${SS_PORT:-}")"
        printf 'SS_WHITELIST_IP=%s\n' "$(env_quote "${SS_WHITELIST_IP:-}")"
        printf 'SOCKS_PORT=%s\n' "$(env_quote "${SOCKS_PORT:-}")"
        printf 'TROJAN_PORT=%s\n' "$(env_quote "${TROJAN_PORT:-}")"
        printf 'SOCKS_USER=%s\n' "$(env_quote "${SOCKS_USER:-}")"
        printf 'SOCKS_PASS=%s\n' "$(env_quote "${SOCKS_PASS:-}")"
        printf 'SOCKS_PROTO=%s\n' "$(env_quote "${SOCKS_PROTO:-}")"
        printf 'PUBLIC_KEY=%s\n' "$(env_quote "${PUBLIC_KEY:-${PBK:-}}")"
        printf 'SHORT_ID=%s\n' "$(env_quote "${SHORT_ID:-}")"
        printf 'HY2_PASS=%s\n' "$(env_quote "${HY2_PASS:-}")"
        printf 'HY2_OBFS=%s\n' "$(env_quote "${HY2_OBFS:-}")"
        printf 'SS_PASS=%s\n' "$(env_quote "${SS_PASS:-}")"
        printf 'LINK_IP=%s\n' "$(env_quote "${LINK_IP:-${GLOBAL_PUBLIC_IP:-}}")"
        printf 'HY2_CERT_SHA256_FP=%s\n' "$(env_quote "${HY2_CERT_SHA256_FP:-}")"
        printf 'HY2_CERT_PUBKEY_SHA256_B64=%s\n' "$(env_quote "${HY2_CERT_PUBKEY_SHA256_B64:-}")"
        printf 'HY2_HOP=%s\n' "$(env_quote "${HY2_HOP:-}")"
        printf 'HY2_HOP_IMPL=%s\n' "$(env_quote "${HY2_HOP_IMPL:-none}")"
        printf 'HY2_MONITOR_PORT=%s\n' "$(env_quote "${HY2_MONITOR_PORT:-}")"
        printf 'HY2_ACME_TYPE=%s\n' "$(env_quote "${HY2_ACME_TYPE:-http}")"
        printf 'HY2_ACME_DNS_PROVIDER=%s\n' "$(env_quote "${HY2_ACME_DNS_PROVIDER:-}")"
        printf 'HY2_ACME_DNS_CF_API_TOKEN=%s\n' "$(env_quote "${HY2_ACME_DNS_CF_API_TOKEN:-}")"
        printf 'HY2_URI_PORTS=%s\n' "$(env_quote "${HY2_URI_PORTS:-}")"
        printf 'HY2_CLASH_PORTS=%s\n' "$(env_quote "${HY2_CLASH_PORTS:-}")"
        printf 'HY2_SB_PORTS=%s\n' "$(env_quote "${HY2_SB_PORTS:-}")"
        printf 'HY2_RANGE_START=%s\n' "$(env_quote "${HY2_RANGE_START:-}")"
        printf 'HY2_RANGE_END=%s\n' "$(env_quote "${HY2_RANGE_END:-}")"
        printf 'INGRESS_IF=%s\n' "$(env_quote "${INGRESS_IF:-}")"
        printf 'ENABLE_KEEPALIVE=%s\n' "$(env_quote "${ENABLE_KEEPALIVE:-}")"
        # Empty limits still yield rc 0 via the false ifs; printf
        # failures are caught by the set -e subshell (rc checked
        # explicitly below), not by if-form.
        if [[ -n "$old_traffic_limit_gb" ]]; then printf 'TRAFFIC_LIMIT_GB=%s\n' "$(env_quote "$old_traffic_limit_gb")"; fi
        if [[ -n "$old_traffic_limit_mode" ]]; then printf 'TRAFFIC_LIMIT_MODE=%s\n' "$(env_quote "$old_traffic_limit_mode")"; fi
    ) > "$tmp"; _write_rc=$?
    if (( _write_rc != 0 )); then rm -f -- "$tmp"; die "$(tr_msg we_write)"; fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; die "$(tr_msg we_chmod)"; }
    mv -f -- "$tmp" "$ABOX_ENV" || { rm -f -- "$tmp"; die "$(tr_msg we_commit)"; }
    umask "$_we_umask"
}

# F-NEW-04/CD (U5/NF-06(a)): record the standalone Trojan listener port in
# .env so the self-heal coverage gate can expect it. Single-key upsert
# (replace-or-append) so a standalone deploy never rewrites the whole
# .env the way write_env does. Best-effort for callers: rc 0 recorded,
# rc 1 not recorded (missing/symlink .env, invalid port, write failure).
env_set_trojan_port() {
    local _port="${1:-}" _envf="${ABOX_ENV:-/etc/ddr/.env}"
    valid_canonical_port "$_port" || return 1
    [[ -f "$_envf" && ! -L "$_envf" ]] || return 1
    if grep -q '^TROJAN_PORT=' "$_envf" 2>/dev/null; then
        sed -i "s/^TROJAN_PORT=.*/TROJAN_PORT='$_port'/" "$_envf" 2>/dev/null || return 1
    else
        if [[ -n "$(tail -c 1 "$_envf" 2>/dev/null)" ]]; then
            printf '\n' >> "$_envf" 2>/dev/null || return 1
        fi
        printf "TROJAN_PORT='%s'\n" "$_port" >> "$_envf" 2>/dev/null || return 1
    fi
    TROJAN_PORT="$_port"
    return 0
}

validate_fail2ban_config() {
    command -v fail2ban-client >/dev/null 2>&1 || return 0
    local out sample
    if fail2ban-client -h 2>&1 | grep -E -- '(^|[[:space:]])-t([,[:space:]]|$)|--test' >/dev/null; then
        if ! out=$(fail2ban-client -t 2>&1); then
            msg "${YELLOW}[!] $(tr_msg validate_fail2ban_config_global_failed)${NC}"
            printf '%s\n' "$out" >&2
            return 1
        fi
    else
        if ! out=$(fail2ban-client -d 2>&1); then
            msg "${YELLOW}[!] $(tr_msg validate_fail2ban_config_dump_failed)${NC}"
            printf '%s\n' "$out" >&2
            return 1
        fi
    fi
    if command -v fail2ban-regex >/dev/null 2>&1 && [[ -r /etc/fail2ban/filter.d/A-Box.conf ]]; then
        sample=$(umask 077; mktemp /tmp/A-Box-f2b-sample.XXXXXX) || { printf '%s\n' "${RED}[!] Fail2Ban sample creation failed.${NC}" >&2; return 1; }
        cat > "$sample" <<'EOF_F2B_SAMPLE' || { rm -f -- "$sample"; printf '%s\n' "${RED}[!] Fail2Ban sample write failed.${NC}" >&2; return 1; }
+0000 2026-07-25 10:00:00 ERROR [1253312684 0ms] inbound/vless[vless-in]: process connection from 203.0.113.7:54321: unknown UUID: 99999999-8888-4777-8666-555555555555
-0800 2026-07-25 10:00:00 ERROR [1253312684 0ms] inbound/vless[vless-in]: process connection from 203.0.113.12:54326: unknown UUID: 99999999-8888-4777-8666-555555555555
2026/07/25 10:00:01.123456 from 203.0.113.8:54322 rejected  proxy/vless/encoding: invalid request user id: 99999999-8888-4777-8666-555555555555
+0000 2026-07-25 10:00:02 ERROR [2126696436 0ms] inbound/shadowsocks[ss-in]: process connection from 203.0.113.9:54323: shadowsocks: serve TCP from 203.0.113.9:54323: cipher: message authentication failed
+0000 2026-07-25 10:00:03 ERROR [2451458976 3.60s] inbound/vless[vless-in]: process connection from 203.0.113.10:54324: EOF
2026/07/25 10:00:04.123456 from 203.0.113.11:54325 accepted tcp:1.1.1.1:80 [direct]
EOF_F2B_SAMPLE
        out=$(fail2ban-regex --print-all-matched --print-all-missed "$sample" /etc/fail2ban/filter.d/A-Box.conf 2>&1) || {
            rm -f -- "$sample"
            printf '%s\n' "$out" >&2
            printf '%s\n' "${RED}[!] $(tr_msg fb_regex_fail)${NC}" >&2
            return 1
        }
        rm -f "$sample"
        # T-3 (follow-up): a -0800 sing-box line (TZ=America/Los_Angeles)
        # must still yield a date hit; the old ^\+ datepattern matched
        # the failregex but detected no date, so the line was silently
        # dropped from banning. Fail closed if the Date template hits
        # section parses to zero hits.
        local _f2b_date_hits
        _f2b_date_hits=$(sed -n '/^Date template hits:/,/^`-$/p' <<< "$out" | grep -cE '^[|] +\[[1-9][0-9]*\]' || true)
        [[ "$_f2b_date_hits" =~ ^[0-9]+$ ]] && (( _f2b_date_hits >= 1 )) || { printf '%s\n' "$out" >&2; printf '%s\n' "${RED}[!] Fail2Ban date detection failed for a sample log line.${NC}" >&2; return 1; }
        local summary matched_count missed_count matched_lines
        summary=$(grep -E '^[[:space:]]*Lines: [0-9]+ lines?, [0-9]+ ignored, [0-9]+ matched, [0-9]+ missed' <<< "$out" | tail -n 1)
        matched_count=$(sed -nE 's/^[[:space:]]*Lines: [0-9]+ lines?, [0-9]+ ignored, ([0-9]+) matched, [0-9]+ missed.*/\1/p' <<< "$summary")
        missed_count=$(sed -nE 's/^[[:space:]]*Lines: [0-9]+ lines?, [0-9]+ ignored, [0-9]+ matched, ([0-9]+) missed.*/\1/p' <<< "$summary")
        [[ "$matched_count" =~ ^[0-9]+$ && "$missed_count" =~ ^[0-9]+$ ]] && (( matched_count >= 1 && missed_count >= 1 )) || { printf '%s\n' "$out" >&2; printf '%s\n' "${RED}[!] Fail2Ban must match a representative failure log and leave a benign log unmatched.${NC}" >&2; return 1; }
        # S40 (GPT-21): totals alone also pass a REVERSED filter (matches
        # only the benign line: "1 matched, 4 missed"). Require per-line
        # proof: at least one known failure line in the matched section,
        # and the benign line absent from it. The matched section is the
        # "|  "-prefixed lines after "Matched line(s):" up to the first
        # line that is not such a line; if the format drifts so no
        # section parses, this fails closed (return 1) rather than falling
        # back to totals.
        matched_lines=$(awk '/Matched line[(]s[)]:/ { m = 1; next } m && /^[|]  / { sub(/^[|]  /, ""); print; next } m { m = 0 }' <<< "$out")
        grep -Fq -e '203.0.113.7' -e '2001:db8::7' -e '198.51.100.9' -e '198.51.100.8' <<< "$matched_lines" || { printf '%s\n' "$out" >&2; printf '%s\n' "${RED}[!] Fail2Ban must match a representative failure log and leave a benign log unmatched.${NC}" >&2; return 1; }
        # NOTE: if-form, not "grep && { ...; return 1; }": as the block's last
        # statement the && form would leak grep's failing status (1)
        # as the function's return code exactly when the check PASSES.
        # R24-M02: the benign sample is the accepted line
        # (203.0.113.11:54325), not a 'health check succeeded' line --
        # no such line exists in the current sample, so the old check
        # could never fire and an over-broad filter passed validation.
        if grep -Fq '203.0.113.11:54325 accepted' <<< "$matched_lines"; then
            printf '%s\n' "$out" >&2
            printf '%s\n' "${RED}[!] Fail2Ban must match a representative failure log and leave a benign log unmatched.${NC}" >&2
            return 1
        fi
    fi
    return 0
}

abox_log_files() {
    printf '%s\n' /var/log/A-Box-xray-access.log /var/log/A-Box-xray-error.log /var/log/A-Box-singbox.log /var/log/A-Box-hysteria.log /var/log/A-Box-traffic.log
}

abox_runtime_identity() {
    local family="$1"
    case "$family" in
        xray) printf '%s\t%s\n' "$ABOX_RUNTIME_XRAY_USER" "$ABOX_RUNTIME_XRAY_GROUP" ;;
        xray-latest) printf '%s\t%s\n' "$ABOX_RUNTIME_XRAY_USER" "$ABOX_RUNTIME_XRAY_GROUP" ;;
        sing-box|singbox) printf '%s\t%s\n' "$ABOX_RUNTIME_SINGBOX_USER" "$ABOX_RUNTIME_SINGBOX_GROUP" ;;
        hysteria) printf '%s\t%s\n' "$ABOX_RUNTIME_HYSTERIA_USER" "$ABOX_RUNTIME_HYSTERIA_GROUP" ;;
        *) return 1 ;;
    esac
}

ensure_abox_runtime_identity() {
    local family="$1" user group uid gid shell
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || return 1
    getent group "$group" >/dev/null 2>&1 || {
        if command -v groupadd >/dev/null 2>&1; then
            groupadd --system "$group" >/dev/null 2>&1 || getent group "$group" >/dev/null 2>&1 || return 1
        elif [[ "${release:-}" == 'alpine' ]] && command -v addgroup >/dev/null 2>&1; then
            addgroup -S "$group" >/dev/null 2>&1 || getent group "$group" >/dev/null 2>&1 || return 1
        elif command -v addgroup >/dev/null 2>&1; then
            addgroup --system "$group" >/dev/null 2>&1 || getent group "$group" >/dev/null 2>&1 || return 1
        else
            return 1
        fi
    }
    local _created=0
    if ! getent passwd "$user" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "$group" "$user" >/dev/null 2>&1 || return 1
        elif [[ "${release:-}" == 'alpine' ]] && command -v adduser >/dev/null 2>&1; then
            adduser -S -D -H -s /sbin/nologin -G "$group" "$user" >/dev/null 2>&1 || return 1
        elif command -v adduser >/dev/null 2>&1; then
            adduser --system --no-create-home --home /nonexistent --shell /sbin/nologin --ingroup "$group" "$user" >/dev/null 2>&1 || return 1
        else
            return 1
        fi
        _created=1
    fi
    # R5C7-03: a pre-existing user must actually belong to the requested
    # group; otherwise root:$group 750/640 runtime files are unreadable.
    if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxF "$group"; then
        return 1
    fi
    # SYD-B E22: record proven self-created users as name:uid (only
    # the branch above sets _created); cleanup removes exactly
    # these name+uid pairs.
    if (( _created == 1 )) && [[ -n "${ABOX_DIR:-}" ]]; then
        local _rec="${ABOX_DIR}/.created-service-users"
        # R8C7-01: never chmod through a symlink; a linked
        # record is a tamper signal, fail closed.
        if [[ -L "$_rec" ]]; then return 1; fi
        if [[ ! -f "$_rec" ]]; then ( umask 077; : > "$_rec" ) 2>/dev/null || return 1; fi
        if [[ -f "$_rec" && ! -L "$_rec" ]] && ! grep -qxF "$user" "$_rec" 2>/dev/null && ! grep -q "^$user:" "$_rec" 2>/dev/null; then
            local _new_uid=''
            _new_uid=$(id -u "$user" 2>/dev/null || true)
            if [[ "$_new_uid" =~ ^[0-9]+$ ]]; then printf '%s:%s\n' "$user" "$_new_uid" >> "$_rec" 2>/dev/null || return 1; else printf '%s\n' "$user" >> "$_rec" 2>/dev/null || return 1; fi
        fi
        if [[ -L "$_rec" ]]; then return 1; fi
        chmod 600 "$_rec" 2>/dev/null || return 1
    fi
    uid=$(id -u "$user" 2>/dev/null) || return 1
    gid=$(id -g "$user" 2>/dev/null) || return 1
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
    (( uid != 0 && gid != 0 )) || return 1
    shell=$(getent passwd "$user" | awk -F: '{print $7}')
    [[ "$shell" == '/usr/sbin/nologin' || "$shell" == '/sbin/nologin' || "$shell" == '/bin/false' ]] || return 1
}

prepare_abox_runtime_config_dir() {
    local family="$1" dir="$2" user group gid mode nlink
    case "$family:$dir" in
        sing-box:/etc/sing-box|hysteria:/etc/hysteria|xray:/usr/local/etc/xray) ;;
        *) return 1 ;;
    esac
    ensure_abox_runtime_identity "$family" || return 1
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || return 1
    path_parent_chain_safe "$dir/.A-Box-config" || return 1
    [[ ! -L "$dir" && (! -e "$dir" || -d "$dir") ]] || return 1
    install -d -o root -g "$group" -m 750 -- "$dir" || return 1
    gid=$(getent group "$group" 2>/dev/null | awk -F: '{print $3}')
    [[ "$gid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$(stat -c %u:%g "$dir" 2>/dev/null || true)" == "0:$gid" ]] || return 1
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
    nlink=$(stat -c %h "$dir" 2>/dev/null) || return 1
    [[ "$nlink" =~ ^[1-9][0-9]*$ && "$mode" =~ ^0?750$ ]] || return 1
}

# fd_secure_chown_chmod: chown/chmod a single file via a pinned fd.
# $1=path $2=uid $3=gid $4=mode(octal string) [$5=required uid or -1]
# [$6=required nlink or -1]. Opens with O_NOFOLLOW through a pinned
# ancestor walk, verifies the opened fd with fstat (regular file,
# optional uid/nlink), then fchown/fchmod on the same fd. Returns 1
# on any failure (missing, symlink, wrong type/uid/nlink, chown/chmod
# error); a swapped path is refused, never followed.
fd_secure_chown_chmod() {
    local _path="$1" _uid="$2" _gid="$3" _mode="$4" _req_uid="${5:--1}" _req_nlink="${6:--1}"
    python3 -I - "$_path" "$_uid" "$_gid" "$_mode" "$_req_uid" "$_req_nlink" <<'PY_FD_CHOWN'
import os, stat, sys
path, uid, gid, mode, req_uid, req_nlink = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4], 8), int(sys.argv[5]), int(sys.argv[6])
parts = [p for p in os.path.abspath(os.path.normpath(path)).split(os.sep) if p]
if not parts:
    raise SystemExit(1)
parent_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    for comp in parts[:-1]:
        nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        os.close(parent_fd)
        parent_fd = nxt
    try:
        ffd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
except OSError:
    raise SystemExit(1)
try:
    st = os.fstat(ffd)
    if not stat.S_ISREG(st.st_mode):
        raise SystemExit(1)
    if req_uid >= 0 and st.st_uid != req_uid:
        raise SystemExit(1)
    if req_nlink >= 0 and st.st_nlink != req_nlink:
        raise SystemExit(1)
    os.fchown(ffd, uid, gid)
    os.fchmod(ffd, mode)
finally:
    os.close(ffd)
PY_FD_CHOWN
}

prepare_abox_runtime_read_file() {
    local path="$1" family="$2" user group
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    path_parent_chain_safe "$path" || return 1
    [[ "$(stat -c %u:%g "$path" 2>/dev/null || true)" == 0:* ]] || return 1
    [[ "$(stat -c %h "$path" 2>/dev/null || true)" == 1 ]] || return 1
    # R15C7-01: fd-pinned fchown/fchmod; a post-stat symlink
    # swap is refused, never followed to /etc/shadow.
    local _gid
    _gid=$(getent group "$group" 2>/dev/null | awk -F: '{print $3}')
    [[ "$_gid" =~ ^[0-9]+$ ]] || return 1
    fd_secure_chown_chmod "$path" 0 "$_gid" 640 0 1 || return 1
}

prepare_abox_runtime_write_file() {
    local path="$1" family="$2" user group
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || return 1
    path_parent_chain_safe "$path" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        install -o root -g "$group" -m 660 /dev/null "$path" || return 1
        return 0
    fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    # S47 (argon P2-5): accept uid 0 or this family's service user (gid
    # unrestricted), matching what assert_abox_log_file_safe accepts;
    # the file is still normalized to root:group + 660 below, so the
    # end state is unchanged. A missing/empty service uid never matches
    # (the -n guards), and a stat failure fails closed.
    local _uid _svc_uid
    _uid=$(stat -c %u "$path" 2>/dev/null || true)
    _svc_uid=$(id -u "$user" 2>/dev/null || true)
    [[ -n "$_uid" && ( "$_uid" == 0 || ( -n "$_svc_uid" && "$_uid" == "$_svc_uid" ) ) ]] || return 1
    [[ "$(stat -c %h "$path" 2>/dev/null || true)" == 1 ]] || return 1
    chown "root:$group" "$path" || return 1
    chmod 660 "$path" || return 1
}

prepare_abox_runtime_permissions() {
    local family="$1"
    ensure_abox_runtime_identity "$family" || return 1
    case "$family" in
        xray)
            prepare_abox_runtime_config_dir xray /usr/local/etc/xray || return 1
            prepare_abox_runtime_read_file /usr/local/etc/xray/config.json xray || return 1
            prepare_abox_runtime_write_file /var/log/A-Box-xray-access.log xray || return 1
            prepare_abox_runtime_write_file /var/log/A-Box-xray-error.log xray || return 1
            ;;
        sing-box)
            prepare_abox_runtime_config_dir sing-box /etc/sing-box || return 1
            prepare_abox_runtime_read_file /etc/sing-box/config.json sing-box || return 1
            [[ ! -e /etc/sing-box/hy2.crt ]] || prepare_abox_runtime_read_file /etc/sing-box/hy2.crt sing-box || return 1
            [[ ! -e /etc/sing-box/hy2.key ]] || prepare_abox_runtime_read_file /etc/sing-box/hy2.key sing-box || return 1
            [[ ! -e /etc/sing-box/tuic.crt ]] || prepare_abox_runtime_read_file /etc/sing-box/tuic.crt sing-box || return 1
            [[ ! -e /etc/sing-box/tuic.key ]] || prepare_abox_runtime_read_file /etc/sing-box/tuic.key sing-box || return 1
            local _tuic_cert
            for _tuic_cert in /etc/sing-box/tuic-*.crt /etc/sing-box/tuic-*.key; do
                [[ -e "$_tuic_cert" ]] || continue
                prepare_abox_runtime_read_file "$_tuic_cert" sing-box || return 1
            done
            prepare_abox_runtime_write_file /var/log/A-Box-singbox.log sing-box || return 1
            ;;
        hysteria)
            prepare_abox_runtime_config_dir hysteria /etc/hysteria || return 1
            [[ ! -e /etc/hysteria/acme ]] || prepare_hysteria_acme_dir_ownership || return 1
            prepare_abox_runtime_read_file /etc/hysteria/config.yaml hysteria || return 1
            [[ ! -e /etc/hysteria/server.crt ]] || prepare_abox_runtime_read_file /etc/hysteria/server.crt hysteria || return 1
            [[ ! -e /etc/hysteria/server.key ]] || prepare_abox_runtime_read_file /etc/hysteria/server.key hysteria || return 1
            prepare_abox_runtime_write_file /var/log/A-Box-hysteria.log hysteria || return 1
            ;;
        *) return 1 ;;
    esac
}

assert_abox_log_file_safe() {
    local path="$1" uid gid mode nlink _group _gid _svc_uid
    [[ "$path" == /var/log/A-Box-*.log ]] || return 1
    [[ -d /var/log && ! -L /var/log ]] || return 1
    path_parent_chain_safe "$path" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    uid=$(stat -c %u "$path" 2>/dev/null) || return 1
    gid=$(stat -c %g "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a "$path" 2>/dev/null) || return 1
    nlink=$(stat -c %h "$path" 2>/dev/null) || return 1
    [[ "$nlink" == 1 ]] || return 1
    if [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^0?600$ ]]; then return 0; fi
    local _family _user
    for _family in xray sing-box hysteria; do
        IFS=$'\t' read -r _user _group < <(abox_runtime_identity "$_family") || continue
        [[ -n "${_group:-}" ]] || continue
        _gid=$(getent group "$_group" 2>/dev/null | awk -F: '{print $3}')
        _svc_uid=$(id -u "$_user" 2>/dev/null || true)
        if [[ -n "$_gid" && "$gid" == "$_gid" ]] && [[ "$uid" == 0 || ( -n "$_svc_uid" && "$uid" == "$_svc_uid" ) ]] && [[ "$mode" =~ ^0?6[046]0$ ]]; then
            return 0
        fi
    done
    # SYD-B2 E22: an orphaned gid (group deleted by an earlier cleanup
    # step, e.g. userdel removing its primary group) can only belong to
    # a previously existing A-Box runtime group: the path is already
    # pinned to /var/log/A-Box-*.log, the parent chain is safe, the
    # file is a regular root-owned file with nlink 1 and a log-safe
    # mode. Accept it so a half-finished cleanup can complete.
    if [[ "$uid" == 0 ]] && [[ "$mode" =~ ^0?6[046]0$ ]] && ! getent group "$gid" >/dev/null 2>&1; then return 0; fi
    return 1
}

ensure_abox_log_file() {
    local path="$1" family='' user group
    assert_abox_log_file_safe "$path" || die "$(tprintf lg_refuse "$path")"
    [[ -e "$path" ]] && return 0
    case "$path" in
        /var/log/A-Box-xray-*.log) family=xray ;;
        /var/log/A-Box-singbox.log) family=sing-box ;;
        /var/log/A-Box-hysteria.log) family=hysteria ;;
        /var/log/A-Box-traffic.log) install -o root -g root -m 600 /dev/null "$path" || die "$(tprintf lg_create "$path")"; return 0 ;;
        *) return 1 ;;
    esac
    ensure_abox_runtime_identity "$family" || die "$(tprintf lg_user "$family")"
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || die "$(tprintf lg_user_parse "$family")"
    install -o root -g "$group" -m 660 /dev/null "$path" || die "$(tprintf lg_create "$path")"
}

remove_abox_log_files() {
    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" || -L "$path" ]] || continue
        assert_abox_log_file_safe "$path" || { msg "[!] Unsafe A-Box log file refused: $path" >&2; return 1; }
        path_tree_has_mountpoint "$path" && { msg "[!] A-Box log file is on a mountpoint: $path" >&2; return 1; }
        rm -f -- "$path" || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
    done < <(abox_log_files)
}

ensure_fail2ban() {
    # R5C8-01: a pre-installed binary must not skip enablement;
    # only the install step is skippable, enablement is verified.
    if ! command -v fail2ban-client >/dev/null 2>&1; then
    msg "${YELLOW}[*] $(tr_msg ensure_fail2ban_installing)${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -q >/dev/null 2>&1 || true
        apt-get -y install fail2ban >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y install fail2ban >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum -y install fail2ban >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache fail2ban >/dev/null 2>&1 || true
    fi
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        msg "${RED}[!] $(tr_msg ensure_fail2ban_install_failed)${NC}"
        return 1
    fi
    fi
    # M-23 (follow-up): backend = systemd needs the python3 systemd
    # bindings; Debian/Ubuntu install fail2ban without them when
    # Recommends are off, so the stock [sshd] jail fails to load.
    # Cover fresh and pre-installed fail2ban alike; fail-open, never
    # blocks setup. Only apt hosts (Debian/Ubuntu) carry this package.
    # Probe with -I so a planted systemd.py (cwd/PYTHONPATH) cannot shadow the real bindings.
    if command -v apt-get >/dev/null 2>&1 && ! python3 -I -c 'import systemd' >/dev/null 2>&1; then
        apt-get update -y -q >/dev/null 2>&1 || true
        apt-get -y install python3-systemd >/dev/null 2>&1 || true
    fi
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl enable fail2ban >/dev/null 2>&1 || return 1
        systemctl is-enabled --quiet fail2ban >/dev/null 2>&1 || return 1
        systemctl start fail2ban >/dev/null 2>&1 || true
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        rc-update add fail2ban default >/dev/null 2>&1 || return 1
        rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])fail2ban([[:space:]]|$)' || return 1
        rc-service fail2ban start >/dev/null 2>&1 9>&- 10>&- || true
    fi
    return 0
}

# Group a comma-separated port list into multiport-safe chunks: the
# iptables multiport match accepts at most 15 slots and a port range
# consumes 2 slots. Prints one comma-separated group per line.
f2b_port_groups() {
    local list="$1" item='' cost=0 slots=0 group='' old_ifs="$IFS"
    IFS=','
    for item in $list; do
        [[ -n "$item" ]] || continue
        # S52 (argon P2-7): only multiport-safe values reach the jail.
        # A hyphen range (e.g. a hand-edited Xray string port
        # "20000-20010") is converted to colon form, which multiport
        # accepts; anything else is logged and skipped, never failing
        # the whole jail. Whitespace is trimmed first so a space-padded
        # valid port is not falsely dropped.
        while [[ "$item" == ' '* || "$item" == *' ' ]]; do item="${item# }"; item="${item% }"; done
        while [[ "$item" == $'\t'* || "$item" == *$'\t' ]]; do item="${item#$'\t'}"; item="${item%$'\t'}"; done
        [[ -n "$item" ]] || continue
        if [[ "$item" =~ ^[0-9]+-[0-9]+$ ]]; then
            item="${item/-/:}"
        elif [[ ! "$item" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
            printf '%s\n' "[!] Fail2Ban port group: skipping invalid port value: $item" >&2
            continue
        fi
        if [[ "$item" == *:* ]]; then cost=2; else cost=1; fi
        if (( slots > 0 && slots + cost > 15 )); then
            printf '%s\n' "$group"
            group=''; slots=0
        fi
        group+="${group:+,}$item"
        slots=$((slots + cost))
    done
    IFS="$old_ifs"
    [[ -n "$group" ]] && printf '%s\n' "$group"
    return 0
}

# S38 (GPT-18): back up a file before it is replaced, and restore it.
# Paths are parameters so the behavior is fixture-testable. A missing
# source backs up as "absent" (any stale backup removed). M-23: restoring
# an absent backup must NOT delete the target -- bak absent means the
# target is new this round (first install), and deleting it on a
# validation failure destroys a legitimate new config. Only a backup
# that really exists is restored. Symlinks are never followed.
_f2b_backup_file() {
    local src="$1" bak="$2"
    if [[ -f "$src" && ! -L "$src" ]]; then
        cp -p -- "$src" "$bak" || return 1
    else
        rm -f -- "$bak" || return 1
    fi
    return 0
}
_f2b_restore_file() {
    local src="$1" bak="$2"
    if [[ -f "$bak" && ! -L "$bak" ]]; then
        cp -p -- "$bak" "$src" || return 1
    else
        # M-23: no backup exists, so the target is new this round;
        # keep it instead of deleting a legitimate new config.
        :
    fi
    return 0
}
# Restore fail2ban filter/jail from backups taken by setup_active_defense.
# Backups are deleted only if BOTH restores succeed; otherwise they are kept
# with a warning so the old configs are not lost on a failed build.
_f2b_restore_backups_or_keep() {
    local filter_bak="$1" jail_bak="$2" ok=1
    _f2b_restore_file /etc/fail2ban/filter.d/A-Box.conf "$filter_bak" || ok=0
    _f2b_restore_file /etc/fail2ban/jail.d/A-Box.local "$jail_bak" || ok=0
    if (( ok == 1 )); then
        rm -f -- "$filter_bak" "$jail_bak"
    else
        msg "${YELLOW}[!] $(tprintf _f2b_restore_backups_or_keep_restore_failed "${filter_bak}" "${jail_bak}")${NC}"
    fi
}

# S38 (GPT-18): restart fail2ban, returning its status (unlike the
# inline warn-only sites). Used by the backup/restore retry flow.
_f2b_restart() {
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        systemctl restart fail2ban >/dev/null 2>&1
    else
        rc-service fail2ban restart >/dev/null 2>&1 9>&- 10>&-
    fi
}

setup_active_defense() {
    local log_file
    msg "${YELLOW}[*] $(tr_msg setup_active_defense_mounting)${NC}"
    while IFS= read -r log_file; do
        [[ -n "$log_file" ]] || continue
        ensure_abox_log_file "$log_file"
    done < <(abox_log_files)
    assert_abox_auxiliary_safe /etc/logrotate.d/A-Box || die "$(tprintf ax_refuse "/etc/logrotate.d/A-Box")"
    write_file_atomically_from_stdin /etc/logrotate.d/A-Box 644 <<'EOF_LOGROTATE' || die "$(tr_msg setup_active_defense_logrotate_write_fail)"
# Managed by A-Box
/var/log/A-Box-*.log {
    su root root
    daily
    rotate 2
    size 50M
    missingok
    notifempty
    copytruncate
    compress
    # No "create …": copytruncate keeps the existing inode/ownership so
    # abox-xray / abox-singbox / abox-hysteria (mode 0660 root:group) can keep writing.
}
EOF_LOGROTATE
    ensure_fail2ban || true
    if command -v fail2ban-client >/dev/null 2>&1; then
        local tcp_ports='' udp_ports='' jail_tmp='' f2b_action='' f2b_backend='' f2b_tcp_action='' f2b_udp_action='' sb_harv='' xr_harv='' f2b_inc='' f2b_ver='' filter_bak='' jail_bak='' f2b_harv_failed=0
        path_parent_chain_safe /etc/fail2ban/filter.d/A-Box.conf || die "$(tr_msg ad_filter_chain)"
        path_parent_chain_safe /etc/fail2ban/jail.d/A-Box.local || die "$(tr_msg ad_jail_chain)"
        mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d || die "$(tr_msg ad_dirs)"
        assert_abox_auxiliary_safe /etc/fail2ban/filter.d/A-Box.conf || die "$(tprintf ax_refuse "/etc/fail2ban/filter.d/A-Box.conf")"
        assert_abox_auxiliary_safe /etc/fail2ban/jail.d/A-Box.local || die "$(tprintf ax_refuse "/etc/fail2ban/jail.d/A-Box.local")"
        jail_tmp=$(mktemp /etc/fail2ban/jail.d/.A-Box.local.A-Box-new.XXXXXX) || die "$(tr_msg ad_jail_tmp)"
        # S38 (GPT-18): back up the live filter/jail BEFORE replacing
        # them, so a broken new config can be rolled back instead of
        # leaving fail2ban down with no way back. Backup names carry
        # no .conf/.local suffix, so fail2ban ignores them even if a
        # later die leaves them behind.
        filter_bak=$(mktemp /etc/fail2ban/filter.d/.A-Box.conf.A-Box-bak.XXXXXX) || { rm -f -- "$jail_tmp"; die "$(tr_msg ad_jail_tmp)"; }
        jail_bak=$(mktemp /etc/fail2ban/jail.d/.A-Box.local.A-Box-bak.XXXXXX) || { rm -f -- "$jail_tmp" "$filter_bak"; die "$(tr_msg ad_jail_tmp)"; }
        _f2b_backup_file /etc/fail2ban/filter.d/A-Box.conf "$filter_bak" || { rm -f -- "$jail_tmp" "$filter_bak" "$jail_bak"; die "$(tr_msg setup_active_defense_filter_backup_fail)"; }
        _f2b_backup_file /etc/fail2ban/jail.d/A-Box.local "$jail_bak" || { rm -f -- "$jail_tmp" "$filter_bak" "$jail_bak"; die "$(tr_msg setup_active_defense_jail_backup_fail)"; }
        write_file_atomically_from_stdin /etc/fail2ban/filter.d/A-Box.conf 644 <<'EOF_F2B_FILTER' || { rm -f -- "$jail_tmp" "$filter_bak" "$jail_bak"; die "$(tr_msg setup_active_defense_filter_write_fail)"; }
# Managed by A-Box
[Definition]
# H-19: datepatterns for the two real log formats (verified with
# fail2ban-regex 1.0.2 against live sing-box 1.14.3 / Xray 26.7.28
# output): sing-box timestamp:true lines start "+0000/-0800 YYYY-MM-DD
# HH:MM:SS"; Xray access/error.log lines start "YYYY/MM/DD
# HH:MM:SS.micro". Without these, no date is detected at all.
# Hysteria is deliberately absent: at default level info it logs no
# auth-failure line at all (core/v2.13.0 falls through to masquerade).
datepattern = ^[-+][0-9]{4} %%Y-%%m-%%d %%H:%%M:%%S
              ^%%Y/%%m/%%d %%H:%%M:%%S
failregex = ^.*(?:authentication failed|message authentication failed).*?(?:from|client[=:])\s*\[?<HOST>\]?(?::[0-9]+)?(?:\s|:|$).*$
            ^.*(?:from|client[=:])\s*\[?<HOST>\]?(?::[0-9]+)?(?:\s|:).*?(?:authentication failed|message authentication failed).*$
            ^.*inbound/(?:vless|trojan|vmess|shadowsocks)\[[^]]*\]: process connection from\s+\[?<HOST>\]?(?::[0-9]+)?: (?:unknown UUID|unknown version|bad request).*$
            ^.*from\s+\[?<HOST>\]?(?::[0-9]+)?\s+rejected\s+.*(?:invalid request|invalid user|not a valid user|failed to match an user).*$
ignoreregex =
EOF_F2B_FILTER
        [[ -n "${VLESS_PORT:-}" ]] && tcp_ports+="${VLESS_PORT},"
        [[ -n "${XHTTP_PORT:-}" ]] && tcp_ports+="${XHTTP_PORT},"
        [[ -n "${SS_PORT:-}" ]] && { tcp_ports+="${SS_PORT},"; udp_ports+="${SS_PORT},"; }
        [[ -n "${SOCKS_PORT:-}" ]] && { tcp_ports+="${SOCKS_PORT},"; udp_ports+="${SOCKS_PORT},"; }
        if [[ "${HY2_HOP:-}" == true && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" ]]; then
            # P2-2: manual hop REDIRECTs to HY2_BASE_PORT in PREROUTING, so Fail2Ban
            # must monitor HY2_BASE_PORT in INPUT chain, not just the hop range.
            [[ "${HY2_HOP_IMPL:-}" == manual && -n "${HY2_BASE_PORT:-}" ]] && udp_ports+="${HY2_BASE_PORT},"
            udp_ports+="${HY2_RANGE_START}:${HY2_RANGE_END},"
        elif [[ -n "${HY2_BASE_PORT:-}" ]]; then
            udp_ports+="${HY2_BASE_PORT},"
        fi
        # Harvest public ports from the live core configs so standalone
        # protocols (TUIC/AnyTLS/ShadowTLS/Trojan/SOCKS landings) are covered
        # by the jails too. Loopback inbounds (Argo WS, detour targets) are
        # excluded: they have no public attack surface.
        if command -v jq >/dev/null 2>&1 && [[ -r /etc/sing-box/config.json ]]; then
            sb_harv=$(jsonc_strip_comments /etc/sing-box/config.json 2>/dev/null | jq -r '.inbounds[]? | select(.listen_port != null) | select(.listen != "127.0.0.1" and .listen != "::1") | (if .type == "tuic" or .type == "hysteria2" then "udp/\(.listen_port)" elif .type == "shadowsocks" or .type == "socks" or .type == "mixed" then "tcp/\(.listen_port),udp/\(.listen_port)" else "tcp/\(.listen_port)" end)' 2>/dev/null | paste -sd, -) || { sb_harv=''; f2b_harv_failed=1; }
            if [[ -n "$sb_harv" ]]; then
                tcp_ports+=",$(printf '%s' "$sb_harv" | tr ',' '\n' | awk -F/ '$1=="tcp" {print $2}' | paste -sd, -)"
                udp_ports+=",$(printf '%s' "$sb_harv" | tr ',' '\n' | awk -F/ '$1=="udp" {print $2}' | paste -sd, -)"
            fi
        fi
        if command -v jq >/dev/null 2>&1 && [[ -r /usr/local/etc/xray/config.json ]]; then
            xr_harv=$(jsonc_strip_comments /usr/local/etc/xray/config.json 2>/dev/null | jq -r '.inbounds[]? | select(.port != null and .tag != "api") | select(.listen == null or (.listen != "127.0.0.1" and .listen != "::1")) | (.port | tostring | split(",")) as $ports | (if .protocol == "shadowsocks" or .protocol == "socks" then ($ports[] | "tcp/\(.)"), ($ports[] | "udp/\(.)") else ($ports[] | "tcp/\(.)") end)' 2>/dev/null | paste -sd, -) || { xr_harv=''; f2b_harv_failed=1; }
            if [[ -n "$xr_harv" ]]; then
                tcp_ports+=",$(printf '%s' "$xr_harv" | tr ',' '\n' | awk -F/ '$1=="tcp" {print $2}' | paste -sd, -)"
                udp_ports+=",$(printf '%s' "$xr_harv" | tr ',' '\n' | awk -F/ '$1=="udp" {print $2}' | paste -sd, -)"
            fi
        fi
        tcp_ports=$(printf '%s' "$tcp_ports" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
        udp_ports=$(printf '%s' "$udp_ports" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
        # Repeat offenders: exponential bantime growth (fail2ban >= 0.11 only;
        # older parsers reject the keys, so gate on the client version).
        f2b_ver=$(fail2ban-client --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$f2b_ver" ]] && awk -v v="$f2b_ver" 'BEGIN { split(v, a, "."); exit !(a[1] > 0 || (a[1] == 0 && a[2] >= 11)) }'; then
            f2b_inc='bantime.increment = true
bantime.factor = 2
bantime.maxtime = 86400'
        fi
        tcp_ports="${tcp_ports%,}"; udp_ports="${udp_ports%,}"
        # R15-F07-05: a harvest failure is not "no ports to protect".
        # Deleting the jail on unparseable input would silently revoke
        # the existing protection; keep the previous configuration.
        if (( f2b_harv_failed == 1 )); then
            _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"
            rm -f -- "$jail_tmp"
            die 'Fail2Ban port harvest failed (a live core config could not be parsed); previous configuration kept.'
        fi
        if [[ -n "$tcp_ports" || -n "$udp_ports" ]]; then
            f2b_backend=$(firewall_backend) || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tr_msg ad_backend_unknown)"; }
            case "$f2b_backend" in
                firewalld)
                    # firewallcmd-multiport invokes iptables -m multiport --dports (requires colon port ranges).
                    f2b_action='firewallcmd-multiport'
                    ;;
                ufw) f2b_action='ufw' ;;
                iptables) f2b_action='iptables-multiport' ;;
                *) _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tprintf ad_backend_unsupported "$f2b_backend")" ;;
            esac
            [[ -r "/etc/fail2ban/action.d/${f2b_action}.conf" ]] || {
                _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"
                die "$(tprintf ad_action_missing "$f2b_action")"
            }
            # Per-group action strings are built while emitting the jail
            # sections below: multiport actions are slot-grouped (see
            # f2b_port_groups); the stock ufw action blocks the offending
            # source host-wide and takes no port/protocol arguments.
        fi
        printf '%s\n' '# Managed by A-Box' > "$jail_tmp" || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die 'Fail2Ban jail file initialization failed.'; }
        # M-23: pin the default backend to systemd journal for jails
        # without their own backend (notably the stock [sshd] jail on
        # Debian 12, where backend=auto + no /var/log/auth.log makes
        # the global `fail2ban-client -t` fail). Per-jail
        # `backend = polling` below still overrides this for A-Box
        # jails, which read log files.
        # M-23 (follow-up N1): only pin backend=systemd when this host
        # is systemd AND the python3-systemd bindings are confirmed
        # importable (checked with -I so a stray systemd.py in cwd or
        # PYTHONPATH cannot fake it). Anywhere else -- non-systemd, or
        # systemd without the bindings (dnf/yum/apk hosts have no
        # install path for them) -- the block is omitted and stock
        # file-log jails keep backend=auto.
        if [[ "${INIT_SYS:-}" == 'systemd' ]] && python3 -I -c 'import systemd' >/dev/null 2>&1; then
            cat >> "$jail_tmp" <<'EOF_F2B_DEFAULT' || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die 'Fail2Ban jail file initialization failed.'; }
[DEFAULT]
backend = systemd
EOF_F2B_DEFAULT
        fi
        if [[ -n "$tcp_ports" ]]; then
            local -a tcp_groups=()
            if [[ "$f2b_action" == 'ufw' ]]; then tcp_groups=("$tcp_ports"); else mapfile -t tcp_groups < <(f2b_port_groups "$tcp_ports"); fi
            local tcp_gi=0 tcp_grp='' tcp_jail=''
            for tcp_grp in "${tcp_groups[@]}"; do
                tcp_gi=$((tcp_gi + 1))
                if (( ${#tcp_groups[@]} > 1 )); then tcp_jail="A-Box-tcp-${tcp_gi}"; else tcp_jail='A-Box-tcp'; fi
                if [[ "$f2b_action" == 'ufw' ]]; then
                    f2b_tcp_action="ufw[name=${tcp_jail}]"
                else
                    f2b_tcp_action="${f2b_action}[name=${tcp_jail}, port=\"${tcp_grp}\", protocol=tcp]"
                fi
                cat >> "$jail_tmp" <<EOF_F2B_TCP || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tr_msg setup_active_defense_jail_append_fail)"; }
[${tcp_jail}]
enabled = true
ignoreip = 127.0.0.1/8 ::1
port = ${tcp_grp}
filter = A-Box
logpath = /var/log/A-Box-xray-error.log
          /var/log/A-Box-xray-access.log
          /var/log/A-Box-singbox.log
          /var/log/A-Box-hysteria.log
backend = polling
maxretry = 8
findtime = 120
bantime = 3600
${f2b_inc}
action = ${f2b_tcp_action}

EOF_F2B_TCP
            done
        fi
        if [[ -n "$udp_ports" ]]; then
            local -a udp_groups=()
            if [[ "$f2b_action" == 'ufw' ]]; then udp_groups=("$udp_ports"); else mapfile -t udp_groups < <(f2b_port_groups "$udp_ports"); fi
            local udp_gi=0 udp_grp='' udp_jail=''
            for udp_grp in "${udp_groups[@]}"; do
                udp_gi=$((udp_gi + 1))
                if (( ${#udp_groups[@]} > 1 )); then udp_jail="A-Box-udp-${udp_gi}"; else udp_jail='A-Box-udp'; fi
                if [[ "$f2b_action" == 'ufw' ]]; then
                    f2b_udp_action="ufw[name=${udp_jail}]"
                else
                    f2b_udp_action="${f2b_action}[name=${udp_jail}, port=\"${udp_grp}\", protocol=udp]"
                fi
                # S44 (GPT-19 + argon P1-5): the UDP jail reads xray-error.log
                # too -- Xray SS/SOCKS dual-stack ports land here, but Xray UDP
                # auth failures are only logged to xray-error.log (the TCP jail
                # already reads it; without this, a TCP-jail ban leaves UDP open).
                cat >> "$jail_tmp" <<EOF_F2B_UDP || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tr_msg setup_active_defense_jail_append_fail)"; }
[${udp_jail}]
enabled = true
ignoreip = 127.0.0.1/8 ::1
port = ${udp_grp}
filter = A-Box
logpath = /var/log/A-Box-xray-error.log
          /var/log/A-Box-xray-access.log
          /var/log/A-Box-singbox.log
          /var/log/A-Box-hysteria.log
backend = polling
maxretry = 8
findtime = 120
bantime = 3600
${f2b_inc}
action = ${f2b_udp_action}
EOF_F2B_UDP
            done
        fi
        if [[ -n "$tcp_ports" || -n "$udp_ports" ]]; then
            chmod 644 "$jail_tmp" || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tr_msg ad_jail_chmod)"; }
            mv -f -- "$jail_tmp" /etc/fail2ban/jail.d/A-Box.local || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; rm -f -- "$jail_tmp"; die "$(tr_msg ad_jail_commit)"; }
            # S38 (GPT-18): validate, then restart; on either failure
            # restore the backed-up configs and retry the restart once.
            # A retry that still fails leaves Fail2Ban protection
            # unconfirmed, so warn only (a failed restore dies above).
            local f2b_restored=0
            if ! validate_fail2ban_config; then
                msg "${YELLOW}[!] $(tr_msg setup_active_defense_new_config_invalid)${NC}"
                f2b_restored=1
            elif ! _f2b_restart; then
                msg "${YELLOW}[!] $(tr_msg setup_active_defense_restart_fail)${NC}"
                f2b_restored=1
            fi
            if (( f2b_restored == 1 )); then
                local f2b_restore_ok=1
                _f2b_restore_file /etc/fail2ban/filter.d/A-Box.conf "$filter_bak" || f2b_restore_ok=0
                _f2b_restore_file /etc/fail2ban/jail.d/A-Box.local "$jail_bak" || f2b_restore_ok=0
                if (( f2b_restore_ok == 1 )); then
                    rm -f -- "$filter_bak" "$jail_bak"
                else
                    msg "${YELLOW}[!] $(tprintf setup_active_defense_old_config_restore_fail "${filter_bak}" "${jail_bak}")${NC}"
                    die 'Fail2Ban previous configuration could not be fully restored; aborting this operation.'
                fi
                _f2b_restart || msg "${YELLOW}[!] $(tr_msg setup_active_defense_restored_restart_fail)${NC}"
            else
                rm -f -- "$filter_bak" "$jail_bak"
            fi
        else
            # R6C8-02: deleting the jail config without unloading the running
            # jail leaves old bans/actions live; restart and verify, keeping
            # backups until the restart succeeds (mirror the S38 pattern).
            rm -f -- "$jail_tmp"
            remove_owned_auxiliary_path /etc/fail2ban/jail.d/A-Box.local || { _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"; die "$(tr_msg ad_jail_remove)"; }
            if _f2b_restart; then
                rm -f -- "$filter_bak" "$jail_bak"
            else
                _f2b_restore_backups_or_keep "$filter_bak" "$jail_bak"
                # R25a-M01: retry the restart after restoring (mirror the
                # S38 pattern above); a restored config with the service
                # still stopped leaves every jail unprotected.
                _f2b_restart || msg "${YELLOW}[!] $(tr_msg setup_active_defense_restart_fail_restored)${NC}"
            fi
        fi
    fi
}


hysteria_official_hop_firewall_ok() {
    local start="${1:-${HY2_RANGE_START:-}}" end="${2:-${HY2_RANGE_END:-}}" first="${3:-${HY2_MONITOR_PORT:-${HY2_RANGE_START:-}}}"
    local first_other=''
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$first" =~ ^[0-9]+$ ]] || return 1
    (( 10#$start <= 10#$end && 10#$first <= 10#$end )) || return 1
    first_other=$((10#$start + 1))
    if command -v iptables >/dev/null 2>&1; then
        # R6C8-03: no -q: grep reads the whole listing, so no
        # SIGPIPE under pipefail can turn a found rule into
        # a false negative (healthy Hysteria restarted).
        # R25a-M03: a candidate line is not coverage when its --dport is
        # negated (`! --dport` matches outside the range) or when it is
        # source-restricted (`-s` covers only that source). Filter those
        # out; the second grep reads the whole listing too (no -q), so
        # the R6C8-03 SIGPIPE reasoning still holds.
        if _iptables_q iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp[[:space:]].*--dport (${start}:${end}|${first_other}:${end}) .*REDIRECT --to-ports ${first}([[:space:]]|$)" | grep -vE -- '! --dport|(^|[[:space:]])-s[[:space:]]' >/dev/null; then
            if has_ipv6; then
                command -v ip6tables >/dev/null 2>&1 && _iptables_q ip6tables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp[[:space:]].*--dport (${start}:${end}|${first_other}:${end}) .*REDIRECT --to-ports ${first}([[:space:]]|$)" | grep -vE -- '! --dport|(^|[[:space:]])-s[[:space:]]' >/dev/null || return 1
            fi
            return 0
        fi
    fi
    if command -v nft >/dev/null 2>&1; then
        # S39 (GPT-20): the old whole-ruleset grep matched redirects in
        # any chain/table/family. Scope it to nat PREROUTING, and when
        # the host has IPv6 require both ip and ip6 (an inet table
        # counts per its rules' meta nfproto (unrestricted counts for both)).
        # F-hop (2026-11-27): Hysteria 2.14.0 official hop builds its
        # own per-family tables `hysteria_<hash>` (ip + ip6) with a
        # lowercase `prerouting` base chain (`type nat hook prerouting`),
        # invisible to iptables-nft and to the old `tbl == "nat" &&
        # chain == "PREROUTING"` gate — every official-hop deploy on a
        # nft-default host failed on it. Accept those tables too, with
        # the same hook + saddr + family accounting below; any other
        # table still does not count.
        local _nft_need6=0
        has_ipv6 && _nft_need6=1
        if nft list ruleset 2>/dev/null | awk -v need6="$_nft_need6" -v pat="udp dport (${start}-${end}|${first_other}-${end}).*redirect to :${first}([[:space:]]|$)" '
            BEGIN { depth = 0; fam = ""; tbl = ""; chain = ""; hookok = 0; hit4 = 0; hit6 = 0 }
            /^[[:space:]]*table[[:space:]]/ { fam = $2; tbl = $3 }
            /^[[:space:]]*chain[[:space:]]/ { chain = $2; hookok = 0 }
            # 04b-04: only a base chain with an ingress hook counts:
            # a plain chain merely named PREROUTING (no type line, or
            # a filter/input hook) has no entry point, so its rules
            # must not count as coverage.
            /^[[:space:]]*type[[:space:]]+nat[[:space:]]+hook[[:space:]]+prerouting([[:space:]]|;)/ { if (chain != "") hookok = 1 }
            /\{[[:space:]]*$/ { depth++ }
            /^[[:space:]]*\}/ { depth--; if (depth == 1) { chain = ""; hookok = 0 } if (depth == 0) { fam = ""; tbl = ""; chain = ""; hookok = 0 } next }
            # R25a-M03: a source-restricted redirect (ip/ip6 saddr) covers
            # only that source, not the whole hop range; it must not count.
            # (A negated dport cannot match `pat`: the range must follow
            # `udp dport ` directly, so `udp dport != ...` never matches.)
            tolower(chain) == "prerouting" && (tbl == "nat" || tbl ~ /^hysteria_[0-9a-fA-F]+$/) && hookok && $0 ~ pat && $0 !~ /(^|[^A-Za-z0-9_])ip saddr/ && $0 !~ /(^|[^A-Za-z0-9_])ip6 saddr/ {
                if (fam == "ip") hit4 = 1
                if (fam == "ip6") hit6 = 1
                if (fam == "inet") {
                    # R10C8-02: an inet rule covers only the families
                    # its meta nfproto selects; an unrestricted rule
                    # covers both. Without this, a pure-IPv4 inet
                    # redirect counted as dual-stack coverage.
                    v4 = ($0 ~ /meta nfproto ipv4/ || $0 ~ /meta nfproto != ipv6/)
                    v6 = ($0 ~ /meta nfproto ipv6/ || $0 ~ /meta nfproto != ipv4/)
                    if (!v4 && !v6) { v4 = 1; v6 = 1 }
                    # R10C8-02b (04a-M1): family-specific expressions
                    # narrow the rule the same way: `ip saddr/daddr/
                    # protocol/...` can only match IPv4, `ip6 ...` and
                    # `icmpv6` only IPv6, even with no meta nfproto
                    # marker. A rule carrying expressions of only one
                    # family must not count for the other.
                    has4 = ($0 ~ /(^|[^A-Za-z0-9_])ip (saddr|daddr|protocol|ttl|frag-off|length|tos|dscp|ecn|ihl|version|id|checksum)/ || $0 ~ /(^|[^A-Za-z0-9_])icmp type/)
                    has6 = ($0 ~ /(^|[^A-Za-z0-9_])ip6 (saddr|daddr|nexthdr|hoplimit|flowlabel|priority|length)/ || $0 ~ /(^|[^A-Za-z0-9_])icmpv6/)
                    if (has4 && !has6) v6 = 0
                    if (has6 && !has4) v4 = 0
                    if (v4) hit4 = 1
                    if (v6) hit6 = 1
                }
            }
            END { if (hit4 && (need6 == 0 || hit6)) exit 0; exit 1 }
        '; then
            return 0
        fi
    fi
    return 1
}


# R25-F-S1-11 (GPT-arbitrated bounded option A, failure exit = C):
# auto-recovery for a broken xray config, driven by the per-minute probe.
# Invoked non-interactively as: install.sh --xray-config-autorecover
# (the probe runs it under its own runtime guard; see socket_probe.sh).
# Only a CONFIRMED config fault triggers a restore; ordinary crashes
# (the offline test passes) are untouched, and an inconclusive test
# (timeout / binary problem) never authorizes an overwrite.
# One online attempt only: the first trusted backup whose config passes
# the offline test is installed; if the service still does not come up,
# no older backup is tried. A failed recovery latches: the service is
# stopped explicitly (systemd Restart=always alone would keep spinning
# it) and the probe must not restart it (rc 1 tells the probe to exit).
# rc: 0 = restored from a trusted backup and the service is up again;
# 1 = config fault with no recovery (latched; restore manually, see the
# .status file); 2 = not applicable (no xray / config valid / test
# inconclusive / desired state not RUNNING).
# Marker records (one line per attempt: "<status> <sha> <epoch> <detail>"):
# restored = this broken content was already auto-restored once (never
# again); failed/attempt within 3600s = cool-down (covers an interrupted
# attempt too); 3 restores in 86400s = rate limit. The attempt line is
# written BEFORE any side effect, so a crash mid-restore cannot look
# like "never tried".
_xrc_marker_append() {
    local marker="$1" _st="$2" _sha="$3" _detail="${4:-}"
    local _tmp
    _tmp=$(umask 077; mktemp "$(dirname "$marker")/.xray-cfg-autorecover.XXXXXX") || return 1
    # R25a-M02: read the existing history and append the new record as
    # separate checked steps. A failed read must not be masked by the
    # following printf (a command group's status comes from its last
    # command); overwriting the marker then would discard the cooldown
    # and rate-limit history the marker exists to keep.
    if [[ -f "$marker" && ! -L "$marker" ]]; then
        cat -- "$marker" > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    fi
    printf '%s %s %s %s\n' "$_st" "$_sha" "$(date +%s)" "$_detail" >> "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$marker" || { rm -f -- "$_tmp"; return 1; }
}

# Report the xray unit's activity state: ActiveState on systemd, or
# stopped/running on OpenRC. A failed query is "unknown" (rc 1), never
# "stopped": callers must not read a query failure as a stopped service.
_xrc_xray_state() {
    if [[ "$(effective_init_system 2>/dev/null || true)" == 'systemd' ]]; then
        systemctl show -p ActiveState --value xray 2>/dev/null || return 1
    else
        rc-service xray status >/dev/null 2>&1 9>&- 10>&-; local _rc=$?
        case "$_rc" in
            0) printf 'active\n' ;;
            3|16|32) printf 'inactive\n' ;;
            *) return 1 ;;
        esac
    fi
}

# Stop the managed xray service so the restart loop halts, and record
# the stop. Never touches the desired state: the stack still WANTS to
# run, the config recovery failed.
# Order matters (R15-F07-04): the service is stopped and verified stopped
# BEFORE the latch file is written. rc: 0 = stopped and latched;
# 1 = stopped but the latch write failed; 2 = stop not verified.
# A return of 1 promises the probe "stopped + latched", so no path may
# return 1 while the service is still (or unknown to be) running.
_xrc_stop_xray() {
    local statusf="$1" _sha="$2" _reason="${3:-}"
    local _tmp _i _state
    if [[ "$(effective_init_system 2>/dev/null || true)" == 'systemd' ]]; then
        systemctl stop xray >/dev/null 2>&1 || true
    else
        rc-service xray stop >/dev/null 2>&1 9>&- 10>&- || true
    fi
    # Verify the stop, allowing a bounded wait for a deactivating unit.
    # The first check runs immediately, so a stopped service costs no wait.
    for _i in $(seq 1 10); do
        _state=$(_xrc_xray_state 2>/dev/null) || _state='unknown'
        case "$_state" in
            inactive|failed) break ;;
            *) sleep 1 ;;
        esac
    done
    case "$_state" in
        inactive|failed) : ;;
        *) return 2 ;;
    esac
    # R15-F07-06: always (re)write the status with the latest outcome.
    # A stale "service up" record from an earlier success must not mask
    # a later failure; the .marker file keeps the full history.
    _tmp=$(umask 077; mktemp "$(dirname "$statusf")/.xray-cfg-autorecover.status.XXXXXX") 2>/dev/null || return 1
    printf '%s xray config auto-recovery STOPPED: %s (broken config sha %s; restore manually from a backup)\n' "$(date -u +%FT%TZ)" "$_reason" "$_sha" > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$statusf" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    return 0
}

# R27-H-NF-06 (GPT-arbitrated A), F-NEW-04/CD: tri-state coverage check
# for an xray config against the currently expected data inbounds (.env
# listener ports). Set comparison, not existential: EVERY expected port
# must be present, so a backup that drops the newest protocol (e.g. a
# pre-Trojan backup after a Trojan deploy) is a mismatch, not a cover.
# rc 0 = verified full cover, or genuinely no expected ports defined
#        (vacuous pass: fresh host / trojan-landing-only stack);
# rc 1 = verification succeeded and at least one expected port is missing
#        (an empty config is a mismatch whenever expectations exist);
# rc 2 = verification could not be completed (unreadable .env, jq
#        missing or failed). Callers: a covering candidate is installed
#        on rc 0; a valid live config enters recovery only on rc 1; a
#        verified mismatch (rc 1) is kept as a fallback and installed only
#        when no covering candidate exists, with the drop recorded by the
#        post-restore divergence check.
# The dokodemo-door api inbound (tag "api", 127.0.0.1:10085) is
# infrastructure, never an expected data inbound: it is excluded by
# tag before ports are compared, so an api-only config never counts
# as covering. .env is parsed, never sourced.
_xrc_config_has_expected_data_inbound() {
    local cfg="$1" envf="${ABOX_ENV:-/etc/ddr/.env}"
    local _var _val _ports _p _e _found
    local -a _expected=() _live_ports=()
    # 04a-M2: a dangling symlink must reach the symlink ban below (rc 2,
    # unverifiable), never the missing-file early return (rc 0, covered):
    # -e is false for a dangling link, so test -L as well.
    [[ -e "$envf" || -L "$envf" ]] || return 0
    [[ -f "$envf" && ! -L "$envf" && -r "$envf" ]] || return 2
    for _var in VLESS_PORT XHTTP_PORT SS_PORT SOCKS_PORT TROJAN_PORT; do
        _val=$(sed -n "s/^${_var}=//p" "$envf" 2>/dev/null | head -n 1 | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
        [[ "$_val" =~ ^[0-9]+$ ]] || continue
        [[ "${#_val}" -le 5 ]] || continue
        (( 10#$_val >= 1 && 10#$_val <= 65535 )) || continue
        _expected+=("$((10#$_val))")
    done
    (( ${#_expected[@]} )) || return 0
    command -v jq >/dev/null 2>&1 || return 2
    _ports=$(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r '.inbounds[]? | select(.tag != "api") | .port // empty' 2>/dev/null) || return 2
    while IFS= read -r _p; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        [[ "${#_p}" -le 5 ]] || continue
        _live_ports+=("$((10#$_p))")
    done <<< "$_ports"
    for _e in "${_expected[@]}"; do
        _found=0
        for _p in "${_live_ports[@]}"; do
            (( 10#$_p == _e )) && { _found=1; break; }
        done
        (( _found == 1 )) || return 1
    done
    return 0
}

# F-NEW-04/CD: post-restore divergence check. Compares the restored xray
# config against the .env expected listener ports and the xray standalone
# links; a registered/linked protocol the restored config no longer serves
# is recorded in the status file (and warned loudly), never dropped
# silently. No automatic rebuild is attempted here: a Reality inbound
# cannot be rebuilt from its link (the link carries only the public key,
# never the private key), so the durable protection is the
# post-deployment backup plus the covering-candidate gate above.
# $1 = restored config path, $2 = status file to append to.
# rc 0 = no divergence, rc 1 = divergence recorded, rc 2 = unverifiable.
_xrc_restore_divergence_check() {
    local _cfg="$1" _statusf="$2" _envf="${ABOX_ENV:-/etc/ddr/.env}"
    local _var _val _ports _p _e _key _rc _found _missing=''
    local -a _expected=() _live_ports=()
    [[ -f "$_cfg" && ! -L "$_cfg" && -r "$_cfg" ]] || return 2
    [[ -n "$_statusf" ]] || return 2
    command -v jq >/dev/null 2>&1 || return 2
    if [[ -f "$_envf" && ! -L "$_envf" && -r "$_envf" ]]; then
        for _var in VLESS_PORT XHTTP_PORT SS_PORT SOCKS_PORT TROJAN_PORT; do
            _val=$(sed -n "s/^${_var}=//p" "$_envf" 2>/dev/null | head -n 1 | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
            [[ "$_val" =~ ^[0-9]+$ ]] || continue
            [[ "${#_val}" -le 5 ]] || continue
            (( 10#$_val >= 1 && 10#$_val <= 65535 )) || continue
            _expected+=("$((10#$_val))")
        done
    fi
    _ports=$(jsonc_strip_comments "$_cfg" 2>/dev/null | jq -r '.inbounds[]? | select(.tag != "api") | .port // empty' 2>/dev/null) || return 2
    while IFS= read -r _p; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        [[ "${#_p}" -le 5 ]] || continue
        _live_ports+=("$((10#$_p))")
    done <<< "$_ports"
    if (( ${#_expected[@]} )); then
        for _e in "${_expected[@]}"; do
            _found=0
            for _p in "${_live_ports[@]}"; do
                (( 10#$_p == _e )) && { _found=1; break; }
            done
            (( _found == 1 )) || _missing+="expected-port:${_e} "
        done
    fi
    for _key in trojan-xray socks5-xray; do
        [[ -f "${ABOX_DIR:-/etc/ddr}/standalone-links.d/${_key}.link" && ! -L "${ABOX_DIR:-/etc/ddr}/standalone-links.d/${_key}.link" ]] || continue
        XRAY_SLOT_CFG="$_cfg" _standalone_link_survivor "$_key"; _rc=$?
        if (( _rc == 1 )); then
            _missing+="link:${_key} "
        fi
    done
    if [[ -n "$_missing" ]]; then
        msg "${RED}[!] xray config auto-restore DIVERGENCE: restored config is missing ${_missing}(re-deploy the missing protocol or restore a newer backup)${NC}" >&2
        printf '%s xray config auto-restore DIVERGENCE: restored config is missing: %s\n' "$(date -u +%FT%TZ)" "$_missing" >> "$_statusf" 2>/dev/null || true
        printf '%s xray config auto-restore DIVERGENCE: a missing Reality inbound cannot be rebuilt from its link (the link carries only the public key, never the private key); re-deploy the protocol or restore a newer backup.\n' "$(date -u +%FT%TZ)" >> "$_statusf" 2>/dev/null || true
        return 1
    fi
    return 0
}

# W2-FAIL-1: decide whether the published desired config may serve as
# the auto-recovery source. $1 = work file to stage the candidate into.
# The file is trusted only when it is a root-owned 0600 regular file
# (not a symlink) of sane size, passes the xray offline test, AND its
# data-inbound port set EQUALS the current .env expected set exactly.
# Exact equality (not the subset cover the backup gate uses) is what
# makes a stale file harmless: a deploy or a manual restore the file
# does not describe can neither gain nor lose a port through it, so a
# non-matching file is ignored and backup enumeration decides.
# rc 0 = staged and usable, 1 = not usable (any reason).
_xrc_desired_config_usable() {
    local dest="$1" src='' _sz='' _mode='' _test_rc=0
    local _expected='' _have='' _var='' _val=''
    local bin="${XRAY_BIN:-/usr/local/bin/xray}"
    local envf="${ABOX_ENV:-/etc/ddr/.env}"
    [[ -n "$dest" ]] || return 1
    src=$(_xrc_desired_config_path) || return 1
    [[ -f "$src" && ! -L "$src" && -r "$src" ]] || return 1
    [[ "$(stat -c %u:%g "$src" 2>/dev/null || true)" == '0:0' ]] || return 1
    _mode=$(stat -c %a "$src" 2>/dev/null || echo '')
    [[ "$_mode" =~ ^0?600$ ]] || return 1
    _sz=$(stat -c %s -- "$src" 2>/dev/null || echo 0)
    [[ "$_sz" =~ ^[0-9]+$ && "$_sz" -gt 0 && "$_sz" -le 1048576 ]] || return 1
    cp -f -- "$src" "$dest" 2>/dev/null || return 1
    chmod 600 -- "$dest" 2>/dev/null || return 1
    [[ -x "$bin" ]] || return 1
    if command -v timeout >/dev/null 2>&1; then
        XRAY_LOCATION_ASSET=/usr/local/share/xray timeout 30 "$bin" run -test -config "$dest" >/dev/null 2>&1; _test_rc=$?
    else
        XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$dest" >/dev/null 2>&1; _test_rc=$?
    fi
    (( _test_rc == 0 )) || return 1
    # Expected set: same var list and parsing as
    # _xrc_config_has_expected_data_inbound.
    if [[ -f "$envf" && ! -L "$envf" && -r "$envf" ]]; then
        for _var in VLESS_PORT XHTTP_PORT SS_PORT SOCKS_PORT TROJAN_PORT; do
            _val=$(sed -n "s/^${_var}=//p" "$envf" 2>/dev/null | head -n 1 | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
            [[ "$_val" =~ ^[0-9]+$ ]] || continue
            [[ "${#_val}" -le 5 ]] || continue
            (( 10#$_val >= 1 && 10#$_val <= 65535 )) || continue
            _expected+="$((10#$_val))"$'\n'
        done
    fi
    # Only numeric ports count (a string port is invalid xray input
    # and the offline test above already rejected such a file).
    _have=$(jsonc_strip_comments "$dest" 2>/dev/null | jq -r '.inbounds[]? | select(.tag != "api") | .port // empty | select(type == "number")' 2>/dev/null) || return 1
    _expected=$(printf '%s' "$_expected" | sort -n -u | tr '\n' ' ' || true)
    _have=$(printf '%s' "$_have" | sort -n -u | tr '\n' ' ' || true)
    [[ "$_expected" == "$_have" ]] || return 1
    return 0
}

xray_config_autorecover() {
    local cfg="${XRAY_CFG:-/usr/local/etc/xray/config.json}"
    local bin="${XRAY_BIN:-/usr/local/bin/xray}"
    local abox="${ABOX_DIR:-/etc/ddr}"
    local marker="$abox/.xray-cfg-autorecover" statusf="$abox/.xray-cfg-autorecover.status"
    local now test_rc bad_sha gate _desired _xrc_rc _latched _cur_sha _cov_rc
    [[ -x "$bin" ]] || return 2
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 2
    # Desired state must still be RUNNING; a stopped stack is never pulled up.
    # Read the authoritative pair state (R15-F07-03): a corrupt pair file
    # is an error, never a cue to fall back to the legacy file.
    _desired=$(get_desired_state 2>/dev/null) || return 2
    [[ "$_desired" == 'RUNNING' ]] || return 2
    # Offline config test (bounded). rc 23 = xray "Failed to start", the
    # only confirmed config fault (measured on real xray v26.7.28 and
    # v26.10.21: malformed JSON, unknown protocol, wrong type, empty and
    # missing file all exit 23; a valid config exits 0). rc 124 = timeout,
    # 127 = binary problem, anything else (126, signals, ...) is
    # inconclusive and never authorizes an overwrite.
    if command -v timeout >/dev/null 2>&1; then
        XRAY_LOCATION_ASSET=/usr/local/share/xray timeout 30 "$bin" run -test -config "$cfg" >/dev/null 2>&1; test_rc=$?
    else
        XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$cfg" >/dev/null 2>&1; test_rc=$?
    fi
    if (( test_rc == 0 )); then
        # R16-F07-03: a valid config does not clear a latch recorded
        # against the earlier broken config (restart-failed): the probe
        # must not restart a service whose restored config failed to
        # come up, or it restarts the service ~3 rounds later.
        # L-07(B): the latch fires ONLY on a recent, well-formed
        # "failed" record whose detail proves a bring-up of the live
        # config failed ("restart-failed": the restored config was
        # installed but the service did not come up;
        # "restore-perm-failed": the restored config was installed but
        # its runtime permissions could not be set). A record with any
        # other detail ("no-trusted-good-backup",
        # "backup-enumeration-failed") only says recovery of the
        # then-broken config failed; once the live config tests valid
        # that config is gone and the record is spent. A record with no
        # detail is malformed (every writer emits one) and is never
        # latch evidence. The 3600s window matches the existing
        # failed/attempt cooldown and is anchored to the original
        # failure epoch; a future-dated record cannot be a recent
        # failure and never latches. This path never appends a marker
        # record, so it cannot refresh the latch.
        now=$(date +%s)
        if [[ -f "$marker" && ! -L "$marker" ]] && _latched=$(awk -v n="$now" '$1 == "failed" && ($4 == "restart-failed" || $4 == "restore-perm-failed") && ($3 <= n) && (n - $3) < 3600 { print "latched"; exit }' "$marker" 2>/dev/null || true) && [[ "$_latched" == latched ]]; then
            _cur_sha=$(sha256sum -- "$cfg" 2>/dev/null | awk '{print $1}') || _cur_sha=''
            [[ -n "$_cur_sha" ]] || return 2
            _xrc_stop_xray "$statusf" "$_cur_sha" "auto-recovery latch still active (earlier restart failed); manual restore required"
            _xrc_rc=$?
            (( _xrc_rc == 2 )) && return 2
            return 1
        fi
        # R27-H-NF-06 (GPT-arbitrated): test_rc 0 only proves xray accepts
        # the config, not that it carries any currently expected data
        # inbound. A valid-but-empty live config (restored pre-deployment
        # backup) must enter recovery instead of returning 2 on every
        # probe cycle. Only a VERIFIED mismatch (helper rc 1) enters
        # recovery; a covered config (0) and an unverifiable one (2) keep
        # the old return-2 behaviour. Timeouts / binary problems / other
        # test results stay inconclusive exactly as before.
        _xrc_config_has_expected_data_inbound "$cfg"; _cov_rc=$?
        case "$_cov_rc" in
            1) : ;;
            *) return 2 ;;
        esac
    elif (( test_rc == 124 || test_rc == 127 )); then
        return 2
    elif (( test_rc != 23 )); then
        return 2
    fi
    bad_sha=$(sha256sum -- "$cfg" 2>/dev/null | awk '{print $1}') || bad_sha=''
    if [[ -z "$bad_sha" ]]; then
        # H1 (04a): rc 1 promises the probe "stopped + latched", so it
        # may never be returned while the service is still (or unknown
        # to be) running. Stop first, as every other failure branch does.
        _xrc_marker_append "$marker" failed "$bad_sha" "bad-config-sha-unreadable" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery cannot read broken config sha; manual restore required"
        _xrc_rc=$?
        (( _xrc_rc == 2 )) && return 2
        return 1
    fi
    now=$(date +%s)
    if [[ -f "$marker" && ! -L "$marker" ]]; then
        # 3B-U2: the gate must not key on the current config's sha:
        # a changed sha bypassed both the cooldown and the restored
        # doors. Like the R16-F07-03 latch above, it is any-sha now:
        # the most recent marker entry of any sha decides, with the
        # failed/attempt cooldown at 3600s and the restored door at
        # 86400s (a stale restored must not latch recovery forever).
        # R25b-M01: only well-formed, non-future records gate recovery.
        # A future epoch makes (n - $3) negative, which satisfies every
        # window below and would block recovery until that future time
        # plus the window (mirror the R16-F07-03 latch's `($3 <= n)`).
        gate=$(awk -v n="$now" '
            $3 !~ /^[0-9]+$/ || $3 > n { next }
            $1 == "failed" || $1 == "attempt" || $1 == "restored" { st = $1; ep = $3 }
            $1 == "restored" && (n - $3) < 86400 { rc24++ }
            END {
                if (st == "restored" && (n - ep) < 86400) print "restored"
                else if ((st == "failed" || st == "attempt") && (n - ep) < 3600) print "cooldown"
                else if (rc24 >= 3) print "rate"
                else print "go"
            }' "$marker" 2>/dev/null || true)
        case "$gate" in
            restored|cooldown|rate)
                _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery already attempted ($gate); manual restore required"
                _xrc_rc=$?
                (( _xrc_rc == 2 )) && return 2
                return 1
                ;;
        esac
    fi
    # Record the attempt BEFORE any side effect. A failed record must
    # still stop the service first (R15-F07-04): rc 1 promises the probe
    # "stopped + latched", so it may never be returned while the service
    # is still (or unknown to be) running.
    _xrc_marker_append "$marker" attempt "$bad_sha" "" || {
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery attempt could not be recorded"
        _xrc_rc=$?
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    local _cand _count=0 _good='' _good_src='' _work _sz _stage _restart_ok=0 _st_tmp _fallback_good='' _fallback_src='' _enum_rc=0 _div_rc=0
    _work=$(mktemp -d /tmp/A-Box-xray-autorecover.XXXXXX) || {
        # H1 (04a): same "stopped + latched" contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "autorecover-workdir-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery work directory could not be created; manual restore required"
        _xrc_rc=$?
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    chmod 700 "$_work" || {
        # H1 (04a): same contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "autorecover-workdir-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery work directory could not be secured; manual restore required"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    local _cand_file="$_work/candidates"
    # W2-FAIL-1: prefer the published desired state over historical
    # backups. A usable desired file describes exactly the current
    # intent, so a genuine fault after deletions restores the deleted
    # state instead of resurrecting protocols from a deploy-time
    # backup. Any doubt falls through to backup enumeration below.
    if _xrc_desired_config_usable "$_work/desired-config.json"; then
        _good="$_work/desired-config.json"
        _good_src="$(_xrc_desired_config_path)"
    fi
    if [[ -z "$_good" ]]; then
    # R16-F07-01: BusyBox find (Alpine) has no -printf; python3 is already
    # a hard dependency, so enumerate by mtime in python (newest first),
    # as restore_from_backup does (D-07). An enumeration failure is NOT a
    # latched stop: stop the service and record the failure first, so rc 1
    # keeps its "stopped + latched" promise to the probe.
    # R25b-M02: enumerate NUL-separated into a file in the protected
    # $_work dir. A `for _cand in $_list` word-splits (and glob-expands)
    # paths, so a backup under a path with spaces is shredded into
    # nonexistent fragments that also consume the 5-candidate budget.
    # `while IFS= read -r -d ''` (the file's established pattern) reads
    # each path whole; the loop body reads no stdin, so the redirection
    # is safe.
    python3 -I - "$_cand_file" "$abox/backups" /root/A-Box-backups <<'PY_XRC_ENUM'
import os, sys
_out = sys.argv[1]
_ents = []
for _d in sys.argv[2:]:
    try:
        _names = os.listdir(_d)
    except FileNotFoundError:
        continue
    except NotADirectoryError:
        continue
    except OSError:
        sys.exit(1)
    for _n in _names:
        if not (_n.startswith('A-Box-backup-') and _n.endswith('.tar.gz')):
            continue
        _p = os.path.join(_d, _n)
        try:
            if os.path.islink(_p) or not os.path.isfile(_p):
                continue
            _ents.append((os.stat(_p).st_mtime, _p))
        except OSError:
            sys.exit(1)
_ents.sort(key=lambda e: (e[0], e[1]), reverse=True)
with open(_out, 'wb') as _f:
    for _, _p in _ents:
        _f.write(_p.encode() + b'\0')
PY_XRC_ENUM
    _enum_rc=$?
    if (( _enum_rc != 0 )); then
        _xrc_marker_append "$marker" failed "$bad_sha" "backup-enumeration-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery backup enumeration failed; manual restore required"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    fi
    # Newest first; at most 5 candidates examined. A candidate must be
    # TRUSTED (sha256 sidecar + HMAC verify with the live key, the same
    # trust the manual restore path requires) and its config must pass
    # the offline test; anything else is skipped, never installed. Only
    # the single config member is extracted, never the whole archive.
    while IFS= read -r -d '' _cand; do
        (( _count >= 5 )) && break
        _count=$(( _count + 1 ))
        backup_checksum_verify "$_cand" "${_cand}.sha256" 2>/dev/null || continue
        backup_auth_verify "$_cand" "${_cand}.hmac" 2>/dev/null || continue
        rm -rf "$_work/extract"; mkdir -p "$_work/extract" || continue
        tar -xzf "$_cand" -C "$_work/extract" root/usr/local/etc/xray/config.json 2>/dev/null || continue
        _good="$_work/extract/root/usr/local/etc/xray/config.json"
        [[ -f "$_good" && ! -L "$_good" ]] || { _good=''; continue; }
        _sz=$(stat -c %s -- "$_good" 2>/dev/null || echo 0)
        [[ "$_sz" =~ ^[0-9]+$ && "$_sz" -le 1048576 && "$_sz" -gt 0 ]] || { _good=''; continue; }
        if command -v timeout >/dev/null 2>&1; then
            XRAY_LOCATION_ASSET=/usr/local/share/xray timeout 30 "$bin" run -test -config "$_good" >/dev/null 2>&1 || { _good=''; continue; }
        else
            XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$_good" >/dev/null 2>&1 || { _good=''; continue; }
        fi
        # R27-H-NF-06 (GPT-arbitrated A), F-NEW-04/CD: a trusted
        # candidate that passes the offline test but does not cover
        # every expected port is a pre-deployment (or pre-protocol)
        # backup, not a full recovery: keep it as a fallback and keep
        # looking for a covering candidate. Only a verified cover
        # (helper rc 0) is installed outright; a verified mismatch (1)
        # is installed only when no covering candidate exists (with the
        # drop recorded by the post-restore divergence check); an
        # unverifiable candidate (2) is skipped, never installed.
        _xrc_config_has_expected_data_inbound "$_good"; _cov_rc=$?
        case "$_cov_rc" in
            0)
                _good_src="$_cand"
                break
                ;;
            1)
                if [[ -z "${_fallback_good:-}" ]]; then
                    if cp -f -- "$_good" "$_work/fallback-config.json" 2>/dev/null; then
                        _fallback_good="$_work/fallback-config.json"
                        _fallback_src="$_cand"
                    fi
                fi
                _good=''
                continue
                ;;
            *)
                _good=''
                continue
                ;;
        esac
    done < "$_cand_file"
    fi # W2-FAIL-1: end of backup enumeration (skipped when the desired file was usable)
    if [[ -z "$_good" && -n "${_fallback_good:-}" ]]; then
        # F-NEW-04/CD: no candidate covers the full expected set; fall
        # back to the newest trusted, valid backup instead of stopping
        # with no recovery at all. The drop is not silent: the
        # post-restore divergence check below records the missing
        # protocols in the status file.
        _good="$_fallback_good"
        _good_src="$_fallback_src"
    fi
    if [[ -z "$_good" ]]; then
        _xrc_marker_append "$marker" failed "$bad_sha" "no-trusted-good-backup" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "no trusted backup with a valid xray config"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    fi
    # Re-verify: the live config must still be the same broken content and
    # the desired state still RUNNING; anything else aborts this stale verdict.
    if [[ "$(sha256sum -- "$cfg" 2>/dev/null | awk '{print $1}')" != "$bad_sha" ]]; then
        rm -rf "$_work"; return 2
    fi
    _desired=$(get_desired_state 2>/dev/null) || { rm -rf "$_work"; return 2; }
    [[ "$_desired" == 'RUNNING' ]] || { rm -rf "$_work"; return 2; }
    # Preserve the broken config aside (0600; keeps the failure evidence),
    # then atomically install the good config next to the live one.
    install -m 600 -- "$cfg" "$abox/xray-config.broken-${bad_sha:0:12}.json" 2>/dev/null || {
        # H1 (04a): same "stopped + latched" contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "broken-config-preserve-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery could not preserve the broken config; manual restore required"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    _stage=$(umask 077; mktemp "$(dirname "$cfg")/.xray-config.A-Box-new.XXXXXX") || {
        # H1 (04a): same contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "restore-stage-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery could not stage the restored config; manual restore required"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    cp -f -- "$_good" "$_stage" 2>/dev/null || {
        # H1 (04a): same contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "restore-stage-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery could not stage the restored config; manual restore required"
        _xrc_rc=$?
        rm -f -- "$_stage"; rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    mv -f -- "$_stage" "$cfg" || {
        # H1 (04a): same contract as above.
        _xrc_marker_append "$marker" failed "$bad_sha" "restore-commit-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "auto-recovery could not install the restored config; manual restore required"
        _xrc_rc=$?
        rm -f -- "$_stage"; rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    # R15-F07-01: the live config must be readable by the xray runtime
    # user (the unit runs as User=abox-xray). The old 0600 root:root
    # install made every restore fail at restart; use the same
    # root:runtime-group 0640 the normal deploy path sets. A failure
    # here is a failed restore, not a restored service.
    prepare_abox_runtime_read_file "$cfg" xray || {
        _xrc_marker_append "$marker" failed "$bad_sha" "restore-perm-failed" || true
        _xrc_stop_xray "$statusf" "$bad_sha" "restored config installed but its runtime permissions could not be set"
        _xrc_rc=$?
        rm -rf "$_work"
        (( _xrc_rc == 2 )) && return 2
        return 1
    }
    # One controlled restart; verify the service is actually up afterwards.
    # A still-failing service is NOT followed by trying older backups.
    if [[ "$(effective_init_system 2>/dev/null || true)" == 'systemd' ]]; then
        if systemctl restart xray >/dev/null 2>&1; then
            sleep 2
            systemctl is-active --quiet xray >/dev/null 2>&1 && _restart_ok=1
        fi
    else
        if rc-service xray restart >/dev/null 2>&1 9>&- 10>&-; then
            sleep 2
            rc-service xray status >/dev/null 2>&1 9>&- 10>&- && _restart_ok=1
        fi
    fi
    if (( _restart_ok == 1 )); then
        _xrc_marker_append "$marker" restored "$bad_sha" "$_good_src" || true
        _st_tmp=$(umask 077; mktemp "$(dirname "$statusf")/.xray-cfg-autorecover.status.XXXXXX") 2>/dev/null || true
        if [[ -n "$_st_tmp" ]]; then
            printf '%s xray config auto-restored from %s; service up (broken config sha %s preserved aside)\n' "$(date -u +%FT%TZ)" "$_good_src" "$bad_sha" > "$_st_tmp" || true
            # F-NEW-04/CD: record any protocol the restored config no
            # longer serves; a missing protocol must never be silent.
            # R25b-M03: the check returns 2 when it cannot verify at all
            # (jq unavailable, config unreadable, query failed). That
            # must not be swallowed: warn loudly and record UNVERIFIABLE
            # in the status file, so "service up" is not confused with
            # "coverage verified". The function's return code stays 0:
            # rc 1 promises the service was stopped, and it is up.
            _xrc_restore_divergence_check "$cfg" "$_st_tmp"; _div_rc=$?
            if (( _div_rc == 2 )); then
                msg "${RED}[!] xray config auto-restore DIVERGENCE CHECK UNVERIFIABLE: the restored config could not be verified (jq unavailable, config unreadable, or query failed); protocol coverage is unconfirmed, re-check the restored config manually.${NC}" >&2
                printf '%s xray config auto-restore DIVERGENCE CHECK UNVERIFIABLE: protocol coverage could not be verified; re-check the restored config manually.\n' "$(date -u +%FT%TZ)" >> "$_st_tmp" 2>/dev/null || true
            fi
            chmod 600 -- "$_st_tmp" 2>/dev/null || true
            mv -f -- "$_st_tmp" "$statusf" 2>/dev/null || rm -f -- "$_st_tmp"
        else
            # 04a-M4: the status temp file could not be created, so the
            # divergence check has nowhere to stage its record. Never
            # skip it silently: warn loudly and run the check directly
            # against the status file (best-effort append) so a missing
            # protocol is still recorded. rc 1 is forbidden here: it
            # promises the service was stopped, and the service is up.
            msg "${RED}[!] xray config auto-restore DIVERGENCE CHECK DEGRADED: status temp file could not be created; recording divergence directly to the status file (a missing protocol must never be silent).${NC}" >&2
            printf '%s xray config auto-restored from %s; service up (broken config sha %s preserved aside)\n' "$(date -u +%FT%TZ)" "$_good_src" "$bad_sha" >> "$statusf" 2>/dev/null || true
            # R25b-M03: as above, a return of 2 means the check could
            # not verify at all; warn loudly and record UNVERIFIABLE
            # instead of swallowing it.
            _xrc_restore_divergence_check "$cfg" "$statusf"; _div_rc=$?
            if (( _div_rc == 2 )); then
                msg "${RED}[!] xray config auto-restore DIVERGENCE CHECK UNVERIFIABLE: the restored config could not be verified (jq unavailable, config unreadable, or query failed); protocol coverage is unconfirmed, re-check the restored config manually.${NC}" >&2
                printf '%s xray config auto-restore DIVERGENCE CHECK UNVERIFIABLE: protocol coverage could not be verified; re-check the restored config manually.\n' "$(date -u +%FT%TZ)" >> "$statusf" 2>/dev/null || true
            fi
        fi
        rm -rf "$_work"
        return 0
    fi
    _xrc_marker_append "$marker" failed "$bad_sha" "restart-failed" || true
    _xrc_stop_xray "$statusf" "$bad_sha" "restored config installed but the service did not come up"
    _xrc_rc=$?
    rm -rf "$_work"
    (( _xrc_rc == 2 )) && return 2
    return 1
}

setup_health_monitor() {
    command -v flock >/dev/null 2>&1 || die "$(tr_msg setup_health_monitor_flock_missing)"
    msg "${YELLOW}[*] $(tr_msg setup_health_monitor_injecting_probe)${NC}"
    install -d -m 711 "$ABOX_DIR" || die "$(tr_msg hm_dir)"
    write_file_atomically_from_stdin "$ABOX_DIR/socket_probe.sh" 700 <<'EOF_PROBE' || die "$(tr_msg setup_health_monitor_probe_write_failed)"
#!/usr/bin/env bash
# Managed by A-Box
# A-06: umask 077 ensures lock/temp files are 0600 (not world-readable 0644).
umask 077
set -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# R11C8-02: derive the runtime dir from this script's own location so a
# non-default ABOX_DIR still finds its state files (cron invokes by
# absolute path, so $0's dir is the runtime dir).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo /etc/ddr)"
ENV="$SCRIPT_DIR/.env"
read_ip_pref() {
    local pref='dual' mode
    local pref_file="$SCRIPT_DIR/.ip-pref"
    if [[ -r "$pref_file" && -f "$pref_file" && ! -L "$pref_file" && "$(stat -c %u:%g "$pref_file" 2>/dev/null || true)" == '0:0' ]]; then
        mode=$(stat -c %a "$pref_file" 2>/dev/null) || mode='777'
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )); then
            pref=$(tr -d '[:space:]' < "$pref_file" 2>/dev/null || true)
        fi
    fi
    [[ "$pref" =~ ^(ipv4|ipv6|dual)$ ]] || pref='dual'
    printf '%s\n' "$pref"
}
LOCK=/run/A-Box-socket-probe.lock
STATE=/run/A-Box-socket-probe.fail
DESIRED="$SCRIPT_DIR/.desired_state"
PAIR_STATE="$SCRIPT_DIR/.traffic-pair-state"
INIT_SYS_EXPECTED='unknown'
exec 9>>"$LOCK" || exit 0
flock -n 9; _flock_rc=$?
if (( _flock_rc != 0 )); then
    # rc 1 is contention: another run holds the lock, skip silently.
    # Any other rc (127 = flock missing, ...) is a real failure: exiting
    # 0 would silently disable this monitor, so fail loudly instead.
    (( _flock_rc == 1 )) || { echo "A-Box: flock failed (rc=$_flock_rc), not contention" >&2; exit 1; }
    exit 0
fi
RUNTIME_LOCK=/run/A-Box.lock
acquire_abox_runtime_guard() {
    local FALLBACK_DIR=/run/A-Box.lock.d fb_pid fb_start fb_actual mode
    [[ -d /run && ! -L /run ]] || exit 0
    # If a live fallback lock is held by another A-Box process, yield. Helpers
    # must not treat an idle LOCK_FILE flock as free while main owns fallback.
    if [[ -d "$FALLBACK_DIR" && ! -L "$FALLBACK_DIR" ]]; then
        # Unknown/fresh fallback dir (metadata not yet written) counts as
        # held: yielding is safe, taking the flock alongside an
        # initializing owner is not.
        if [[ ! -r "$FALLBACK_DIR/pid" || ! -r "$FALLBACK_DIR/starttime" ]]; then
            exit 0
        fi
        [[ "$(stat -c %u:%g "$FALLBACK_DIR" 2>/dev/null || true)" == 0:0 ]] || exit 0
        mode=$(stat -c %a "$FALLBACK_DIR" 2>/dev/null) || exit 0
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || exit 0
        (( (8#$mode & 8#077) == 0 )) || exit 0
        IFS= read -r fb_pid < "$FALLBACK_DIR/pid" || exit 0
        IFS= read -r fb_start < "$FALLBACK_DIR/starttime" || exit 0
        if [[ "$fb_pid" =~ ^[0-9]+$ && -d "/proc/$fb_pid" ]]; then
            # R6-F09-2: a failed/empty probe is UNKNOWN, never "no holder".
            # R25 (F07-02): robust starttime: strip "pid (comm) " first, so a comm
            # containing spaces cannot shift the field. proc_starttime() is not
            # visible inside this generated script, so the parse is inlined
            # (same text as runtime_lock_proc_starttime).
            fb_actual=$(awk '{ if (sub(/^[^ ]+ \(.*\) /, "") == 0) exit 1; print $20 }' "/proc/${fb_pid}/stat" 2>/dev/null) || exit 0
            [[ -z "$fb_actual" ]] && exit 0
            [[ -n "$fb_actual" && "$fb_actual" == "$fb_start" ]] && exit 0
        fi
    fi
    # /run is recreated on reboot; recreate the shared lock inode on demand.
    if [[ ! -e "$RUNTIME_LOCK" && ! -L "$RUNTIME_LOCK" ]]; then
        ( umask 077; set -C; : > "$RUNTIME_LOCK" ) 2>/dev/null || true
    fi
    [[ -f "$RUNTIME_LOCK" && ! -L "$RUNTIME_LOCK" ]] || exit 0
    [[ "$(stat -c %u:%g "$RUNTIME_LOCK" 2>/dev/null || true)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$RUNTIME_LOCK" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || exit 0
    (( (8#$mode & 8#077) == 0 )) || exit 0
    exec 10>>"$RUNTIME_LOCK" || exit 0
    flock -n 10; _flock_rc=$?
    if (( _flock_rc != 0 )); then
        # Same rc rule as the fd 9 block above.
        (( _flock_rc == 1 )) || { echo "A-Box: flock failed (rc=$_flock_rc), not contention" >&2; exit 1; }
        exit 0
    fi
}
load_state() {
    local parsed key value uid gid mode
    [[ -r "$ENV" && -f "$ENV" && ! -L "$ENV" ]] || return 1
    uid=$(stat -c %u "$ENV" 2>/dev/null) || return 1
    gid=$(stat -c %g "$ENV" 2>/dev/null) || return 1
    mode=$(stat -c %a "$ENV" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    parsed=$(umask 077; mktemp /tmp/A-Box-helper-env.XXXXXX) || return 1
    if ! python3 -I - "$ENV" > "$parsed" <<'PY_HELPER_ENV'; then
import shlex,sys
allowed={"CORE","MODE","VLESS_PORT","XHTTP_PORT","HY2_BASE_PORT","HY2_MONITOR_PORT","HY2_HOP","HY2_HOP_IMPL","HY2_RANGE_START","HY2_RANGE_END","INGRESS_IF","SS_PORT","TRAFFIC_LIMIT_GB","TRAFFIC_LIMIT_MODE","SOCKS_PORT"}
seen=set()
with open(sys.argv[1],encoding="utf-8",errors="strict") as h:
    for raw in h:
        line=raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"): continue
        if "=" not in line: raise SystemExit(1)
        key,val=line.split("=",1)
        if key not in allowed: continue
        if key in seen or val.startswith("$'"): raise SystemExit(1)
        if not val.strip():
            value=""
        else:
            parts=shlex.split(val,posix=True)
            if len(parts)!=1: raise SystemExit(1)
            value=parts[0]
        if any(c in value for c in "\x00\r\n"): raise SystemExit(1)
        seen.add(key)
        sys.stdout.buffer.write(key.encode("ascii")+b"\0"+value.encode("utf-8")+b"\0")
PY_HELPER_ENV
        rm -f "$parsed"
        return 1
    fi
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do printf -v "$key" '%s' "$value"; done < "$parsed"
    rm -f "$parsed"
}
# XL-FIX2 (moved): INIT_SYS_EXPECTED is only ever assigned inside generated
# scripts; in the main script it is unset, which killed takeover under set -u.
# Fall back to INIT_SYS (set by init_system_environment in main flow).
is_systemd() { [[ "${INIT_SYS_EXPECTED:-${INIT_SYS:-}}" == systemd ]]; }
service_is_abox_managed() {
    local srv="$1" unit
    if is_systemd; then unit="/etc/systemd/system/${srv}.service"; else unit="/etc/init.d/${srv}"; fi
    [[ -f "$unit" && ! -L "$unit" ]] && grep -Fxq '# Managed by A-Box' "$unit" 2>/dev/null
}
expected_exe() { case "$1" in xray) echo /usr/local/bin/xray;; sing-box) echo /usr/local/bin/sing-box;; hysteria) echo /usr/local/bin/hysteria;; *) return 1;; esac; }
service_active_owned() {
    local srv="$1" pid='' exe
    service_is_abox_managed "$srv" || return 1
    if is_systemd; then
        systemctl is-active --quiet "$srv" || return 1
        pid=$(systemctl show -p MainPID --value "$srv" 2>/dev/null || true)
    else
        rc-service "$srv" status >/dev/null 2>&1 || return 1
        if [[ -f "/run/${srv}.pid" && ! -L "/run/${srv}.pid" && "$(stat -c %u:%h "/run/${srv}.pid" 2>/dev/null || true)" == "0:1" ]]; then
            pid=$(tr -d '[:space:]' < "/run/${srv}.pid" 2>/dev/null || true)
        fi
    fi
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    exe=$(expected_exe "$srv") || return 1
    [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)" == "$exe" ]] || return 1
    SERVICE_PID="$pid"
}
socket_owned_by_pid() {
    local proto="$1" port="$2" pid="$3" flags
    command -v ss >/dev/null 2>&1 || return 2
    [[ "$port" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ ]] || return 1
    case "$proto" in tcp) flags='-H -nltp' ;; udp) flags='-H -nlup' ;; *) return 1 ;; esac
    # shellcheck disable=SC2086
    # Capture first: a failed ss must return "unknown" (2), never be
    # read as "not listening" (1) via an empty awk input.
    local ss_out
    ss_out=$(ss $flags 2>/dev/null) || return 2
    printf '%s\n' "$ss_out" | awk -v p="$port" -v pid="$pid" '
        # S51 (argon P2-6): also match $5 (Local under a Netid-column
        # ss layout); Peer is '*' for LISTEN/UNCONN rows, so $5 can only
        # match when it is the Local column -- no false positives.
        ($4 ~ ("[:.]" p "$") || $5 ~ ("[:.]" p "$")) && $0 ~ ("pid=" pid "([,)]|$)") { found=1 }
        END { exit(found ? 0 : 1) }
    '
}
check_socket_or_fail() {
    local proto="$1" port="$2" pid="$3" srv="$4" rc
    socket_owned_by_pid "$proto" "$port" "$pid"
    rc=$?
    case "$rc" in
        0) return 0 ;;
        1) failed_srv="$srv"; return 0 ;;
        2) exit 0 ;;
        *) exit 0 ;;
    esac
}
# H-04 (Carbon): users_sync removes an inbound from config.json when its
# last user is disabled, so a silent SS/SOCKS port is expected then —
# not a crashed core. Before treating a missing listen socket as a
# fault, confirm the running config still carries an inbound on that
# port (JSONC-strip + parse). Unknown (no readable config, unparsable
# JSON, python3 missing) keeps the old behavior: check the socket.
# Return 0 = inbound present (or unknown: check the socket);
# 1 = config parsed and the inbound is gone (skip the socket check).
# R35b-M2 follow-up: extract a flag's VALUE from /proc/<pid>/cmdline by
# iterating NUL-delimited argv exactly. The old `tr '\0' '\n'` + awk
# erased the boundary, so a single argv containing a newline (e.g.
# $'xray\n-config\n<evil>\n') split into fake lines and the scan took
# <evil> as the live config. Only argv[0] whose basename is a known core
# is trusted; the value must be the very next argv token and absolute.
# Unreadable cmdline / unknown exe / flag without a value / relative
# value all fail (rc 1) so the caller falls back to the default config
# (fail-open to the socket check, as before).
_cmdline_config_value() {
    local _pid="$1" _arg='' _exe='' _first=1 _want=''
    [[ "$_pid" =~ ^[0-9]+$ && "$_pid" -gt 1 ]] || return 1
    while IFS= read -r -d '' _arg; do
        if (( _first == 1 )); then
            _first=0
            _exe="${_arg##*/}"
            case "$_exe" in
                xray) _want='-config' ;;
                sing-box|hysteria) _want='-c' ;;
                *) return 1 ;;
            esac
            continue
        fi
        if [[ "$_arg" == "$_want" || "$_arg" == '--config' && "$_exe" == 'xray' ]]; then
            IFS= read -r -d '' _arg || return 1
            [[ "$_arg" == /* ]] || return 1
            printf '%s\n' "$_arg"
            return 0
        fi
    done < "/proc/$_pid/cmdline" 2>/dev/null
    return 1
}
config_has_inbound_port() {
    local proto="$1" port="$2" cfg='' pid="${MAIN_PID:-}" _cfg_rc=0
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    # The config the live process actually runs, from its cmdline.
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]]; then
        # Gate the flag on argv[0]: a bare "-c" scan would misread an
        # unrelated "-c" earlier in the argv (e.g. "python3 -c ...")
        # and take the following field as the config path.
        cfg=$(_cmdline_config_value "$pid" 2>/dev/null || true)
    fi
    if [[ -z "$cfg" || "$cfg" != /* ]]; then
        case "${CORE:-}" in
            xray) cfg='/usr/local/etc/xray/config.json' ;;
            singbox) cfg='/etc/sing-box/config.json' ;;
            *) return 0 ;;
        esac
    fi
    [[ -r "$cfg" && -f "$cfg" && ! -L "$cfg" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -I - "$cfg" "$proto" "$port" <<'PY_PROBE_CFG' 2>/dev/null
import json, sys
path, proto, port = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    raw = open(path, encoding='utf-8', errors='strict').read()
except (OSError, UnicodeDecodeError):
    raise SystemExit(2)
out = []
i, n = 0, len(raw)
in_str = False
esc = False
while i < n:
    c = raw[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == '\\':
            esc = True
        elif c == '"':
            in_str = False
        i += 1
        continue
    if c == '"':
        in_str = True
        out.append(c)
        i += 1
        continue
    if c == '/' and i + 1 < n and raw[i+1] == '/':
        j = raw.find('\n', i)
        i = n if j < 0 else j
        continue
    if c == '/' and i + 1 < n and raw[i+1] == '*':
        j = raw.find('*/', i + 2)
        if j < 0:
            raise SystemExit(2)
        i = j + 2
        continue
    out.append(c)
    i += 1
try:
    cfg = json.loads(''.join(out))
except ValueError:
    raise SystemExit(2)
# 04a-M3: a non-dict top level (array, null, ...) has no .get: the old
# code raised AttributeError, exited 1, and the shell read that as
# "inbound confirmed absent" and skipped the socket check. Undecodable
# or unshaped config is unverifiable (2), never proof of absence.
if not isinstance(cfg, dict):
    raise SystemExit(2)
# R26a-M1: an `inbounds` that is not a list (int, string, dict, null)
# or a list holding a non-dict element is unshaped, not proof the
# inbound is absent (same contract as 04a-M3 above): raise 2 so the
# caller keeps checking the socket instead of skipping it. The old
# code raised an uncaught TypeError on a non-iterable `inbounds`
# (exit 1, read as "confirmed absent") and silently skipped string /
# dict / non-dict-element shapes the same way.
inbounds = cfg.get('inbounds', [])
if not isinstance(inbounds, list):
    raise SystemExit(2)
found = False
for ib in inbounds:
    if not isinstance(ib, dict):
        raise SystemExit(2)
    p = ib.get('port', ib.get('listen_port'))
    ports = []
    if isinstance(p, int):
        ports = [str(p)]
    elif isinstance(p, str):
        for part in p.split(','):
            part = part.strip()
            if not part:
                continue
            if '-' in part:
                try:
                    lo, hi = part.split('-', 1)
                    if int(lo) <= int(port) <= int(hi):
                        ports.append(str(port))
                except ValueError:
                    continue
            else:
                ports.append(part)
    if str(port) not in ports:
        continue
    if proto == 'shadowsocks':
        if ib.get('protocol') == 'shadowsocks' or ib.get('type') == 'shadowsocks':
            found = True
    elif proto == 'socks':
        if ib.get('protocol') == 'socks' or ib.get('type') in ('socks', 'mixed'):
            found = True
    if found:
        break
raise SystemExit(0 if found else 1)
PY_PROBE_CFG
    _cfg_rc=$?
    case "$_cfg_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 0 ;;
    esac
}
restart_owned() {
    local srv="$1"
    service_is_abox_managed "$srv" || return 1
    if is_systemd; then systemctl restart "$srv" >/dev/null 2>&1; else rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&-; fi
}
# M41-NEW-03: stop a ghost core — a service that is still running
# although the stack was cleared (desired MANUAL_STOPPED, CORE already
# empty). Only a service that is verifiably A-Box-managed AND active
# with the expected exe is touched; anything else is left alone
# (return 0: nothing to stop).
stop_ghost_owned() {
    local srv="$1"
    service_active_owned "$srv" || return 0
    if is_systemd; then
        systemctl stop "$srv" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$srv"; then return 1; else return 0; fi
    else
        rc-service "$srv" stop >/dev/null 2>&1 9>&- 10>&- || true
        if rc-service "$srv" status >/dev/null 2>&1; then return 1; else return 0; fi
    fi
}
load_state || exit 0
# M-20(3): a clear-all leaves CORE empty while an independently
# deployed Argo (sing-box) stack keeps running; the probe used to
# exit here before the desired-state gate, so the Argo stack was
# never supervised. Fall back to the first A-Box-owned auxiliary
# core (sing-box first: it carries the Argo WS inbounds) so the
# desired gate and the service checks below still run. The tunnel
# itself (cloudflared) is not probed here: only the core service
# liveness is supervised.
if [[ -z "${CORE:-}" ]]; then
    for _aux_srv in sing-box xray hysteria; do
        if service_is_abox_managed "$_aux_srv"; then
            case "$_aux_srv" in
                sing-box) CORE=singbox ;;
                xray) CORE=xray ;;
                hysteria) CORE=hysteria ;;
            esac
            break
        fi
    done
fi
desired=RUNNING
if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
    # S23: a pair file that exists but fails safety checks is an error:
    # exit here, never fall through to legacy/default RUNNING.
    [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] || exit 0
    [[ "$(stat -c %u:%g "$PAIR_STATE" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r _pair < "$PAIR_STATE" || exit 0
    [[ "$_pair" == *'|'* ]] || exit 0
    desired=${_pair%%|*}
    _pair_period=${_pair#*|}
    if [[ -n "$_pair_period" && ! "$_pair_period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then exit 0; fi
    case "$desired" in RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE) ;; *) exit 0 ;; esac
elif [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
    [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] || exit 0
    [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$DESIRED" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r desired < "$DESIRED" || exit 0
fi
if [[ "$desired" != RUNNING ]]; then
    rm -f "$STATE"
    if [[ "$desired" == MANUAL_STOPPED ]]; then
        # M41-NEW-03: the stack was cleared (CORE already empty) but a
        # core may still be running as a ghost; stop any running
        # A-Box-owned core instead of leaving it serving cleared nodes.
        # Other non-RUNNING states (TRAFFIC_BLOCKED/MAINTENANCE) are
        # owned by the traffic monitor, not by this probe.
        # 04a-H2: stopping a service is a mutation, so take the runtime
        # guard FIRST: without it the probe can act on a stale
        # MANUAL_STOPPED read and stop a service the main script has
        # just started. Contention yields this round (the guard exits 0).
        acquire_abox_runtime_guard
        # R26a-H1: the MANUAL_STOPPED read above predates the guard, so
        # the guard alone does NOT validate it: a start that completed
        # (and committed RUNNING) between the read and the guard would
        # otherwise be stopped here. The guard only serialises
        # concurrent mutation. Re-read the desired state under the
        # guard (same safety-checked read as above; keep in sync) and
        # stop only if it is still MANUAL_STOPPED. A changed or
        # unreadable state yields this round.
        desired=RUNNING
        if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
            [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] || exit 0
            [[ "$(stat -c %u:%g "$PAIR_STATE" 2>/dev/null)" == 0:0 ]] || exit 0
            mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || exit 0
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
            IFS= read -r _pair < "$PAIR_STATE" || exit 0
            [[ "$_pair" == *'|'* ]] || exit 0
            desired=${_pair%%|*}
            _pair_period=${_pair#*|}
            if [[ -n "$_pair_period" && ! "$_pair_period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then exit 0; fi
            case "$desired" in RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE) ;; *) exit 0 ;; esac
        elif [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
            [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] || exit 0
            [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]] || exit 0
            mode=$(stat -c %a "$DESIRED" 2>/dev/null) || exit 0
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
            IFS= read -r desired < "$DESIRED" || exit 0
        fi
        [[ "$desired" == MANUAL_STOPPED ]] || exit 0
        for _gs in xray sing-box hysteria; do stop_ghost_owned "$_gs" || true; done
    fi
    exit 0
fi
IPT=$(command -v iptables || echo /sbin/iptables)
IPT6=$(command -v ip6tables || echo /sbin/ip6tables)
has_ipv6() { local _p; _p=$(read_ip_pref 2>/dev/null || printf dual); [[ "$_p" == ipv4 ]] && return 1; ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { found=1 } END { exit !found }' || ip -6 route show default 2>/dev/null | awk '/^default/ { found=1 } END { exit !found }'; }
# G3: probe iptables -w (xtables lock wait) support. -w for the iptables
# command exists since 1.4.20; pre-1.4.20 systems lack it. All callers use
# this helper so very old systems degrade gracefully instead of failing
# on an unrecognized option.
_iptables_probe_w() {
    local cmd="$1"
    local cache_var="_IPT_W_${cmd//[^a-zA-Z0-9]/_}"
    if [[ -z "${!cache_var+x}" ]]; then
        if "$cmd" -w --version >/dev/null 2>&1; then
            printf -v "$cache_var" '%s' '-w'
        else
            printf -v "$cache_var" '%s' ''
        fi
    fi
    _IPT_W_CUR="${!cache_var}"
}
_iptables_q() {
    local cmd="$1"; shift
    _iptables_probe_w "$cmd"
    if [[ -n "$_IPT_W_CUR" ]]; then
        "$cmd" "$_IPT_W_CUR" "$@"
    else
        "$cmd" "$@"
    fi
}
_iptables_do() {
    local cmd="$1"; shift
    _iptables_probe_w "$cmd"
    if [[ -n "$_IPT_W_CUR" ]]; then
        "$cmd" "$_IPT_W_CUR" "$@"
    else
        "$cmd" "$@"
    fi
}
ipv6_nat_redirect_usable() { command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -t nat -L PREROUTING >/dev/null 2>&1; }
hysteria_official_hop_firewall_ok() {
    local start="${HY2_RANGE_START:-}" end="${HY2_RANGE_END:-}" first="${HY2_MONITOR_PORT:-${HY2_RANGE_START:-}}" first_other=''
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$first" =~ ^[0-9]+$ ]] || return 1
    (( 10#$start <= 10#$end && 10#$first <= 10#$end )) || return 1
    first_other=$((10#$start + 1))
    # R6C8-03: no -q: grep reads the whole listing, so no
    # SIGPIPE under pipefail can turn a found rule into
    # a false negative (healthy Hysteria restarted).
    # R25a-M03: a candidate line is not coverage when its --dport is
    # negated (`! --dport` matches outside the range) or when it is
    # source-restricted (`-s` covers only that source). Filter those
    # out; the second grep reads the whole listing too (no -q), so
    # the R6C8-03 SIGPIPE reasoning still holds.
    if command -v iptables >/dev/null 2>&1 && _iptables_q iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp[[:space:]].*--dport (${start}:${end}|${first_other}:${end}) .*REDIRECT --to-ports ${first}([[:space:]]|$)" | grep -vE -- '! --dport|(^|[[:space:]])-s[[:space:]]' >/dev/null; then
        if has_ipv6; then
            command -v ip6tables >/dev/null 2>&1 && _iptables_q ip6tables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp[[:space:]].*--dport (${start}:${end}|${first_other}:${end}) .*REDIRECT --to-ports ${first}([[:space:]]|$)" | grep -vE -- '! --dport|(^|[[:space:]])-s[[:space:]]' >/dev/null || return 1
        fi
        return 0
    fi
    if command -v nft >/dev/null 2>&1; then
        # S39 (GPT-20): the old whole-ruleset grep matched redirects in
        # any chain/table/family. Scope it to nat PREROUTING, and when
        # the host has IPv6 require both ip and ip6 (an inet table
        # counts per its rules' meta nfproto (unrestricted counts for both)).
        # F-hop (2026-11-27): Hysteria 2.14.0 official hop builds its
        # own per-family tables `hysteria_<hash>` (ip + ip6) with a
        # lowercase `prerouting` base chain (`type nat hook prerouting`),
        # invisible to iptables-nft and to the old `tbl == "nat" &&
        # chain == "PREROUTING"` gate — every official-hop deploy on a
        # nft-default host failed on it. Accept those tables too, with
        # the same hook + saddr + family accounting below; any other
        # table still does not count.
        local _nft_need6=0
        has_ipv6 && _nft_need6=1
        if nft list ruleset 2>/dev/null | awk -v need6="$_nft_need6" -v pat="udp dport (${start}-${end}|${first_other}-${end}).*redirect to :${first}([[:space:]]|$)" '
            BEGIN { depth = 0; fam = ""; tbl = ""; chain = ""; hookok = 0; hit4 = 0; hit6 = 0 }
            /^[[:space:]]*table[[:space:]]/ { fam = $2; tbl = $3 }
            /^[[:space:]]*chain[[:space:]]/ { chain = $2; hookok = 0 }
            # 04b-04: only a base chain with an ingress hook counts:
            # a plain chain merely named PREROUTING (no type line, or
            # a filter/input hook) has no entry point, so its rules
            # must not count as coverage.
            /^[[:space:]]*type[[:space:]]+nat[[:space:]]+hook[[:space:]]+prerouting([[:space:]]|;)/ { if (chain != "") hookok = 1 }
            /\{[[:space:]]*$/ { depth++ }
            /^[[:space:]]*\}/ { depth--; if (depth == 1) { chain = ""; hookok = 0 } if (depth == 0) { fam = ""; tbl = ""; chain = ""; hookok = 0 } next }
            # R25a-M03: a source-restricted redirect (ip/ip6 saddr) covers
            # only that source, not the whole hop range; it must not count.
            # (A negated dport cannot match `pat`: the range must follow
            # `udp dport ` directly, so `udp dport != ...` never matches.)
            tolower(chain) == "prerouting" && (tbl == "nat" || tbl ~ /^hysteria_[0-9a-fA-F]+$/) && hookok && $0 ~ pat && $0 !~ /(^|[^A-Za-z0-9_])ip saddr/ && $0 !~ /(^|[^A-Za-z0-9_])ip6 saddr/ {
                if (fam == "ip") hit4 = 1
                if (fam == "ip6") hit6 = 1
                if (fam == "inet") {
                    # R10C8-02: an inet rule covers only the families
                    # its meta nfproto selects; an unrestricted rule
                    # covers both. Without this, a pure-IPv4 inet
                    # redirect counted as dual-stack coverage.
                    v4 = ($0 ~ /meta nfproto ipv4/ || $0 ~ /meta nfproto != ipv6/)
                    v6 = ($0 ~ /meta nfproto ipv6/ || $0 ~ /meta nfproto != ipv4/)
                    if (!v4 && !v6) { v4 = 1; v6 = 1 }
                    # R10C8-02b (04a-M1): family-specific expressions
                    # narrow the rule the same way: `ip saddr/daddr/
                    # protocol/...` can only match IPv4, `ip6 ...` and
                    # `icmpv6` only IPv6, even with no meta nfproto
                    # marker. A rule carrying expressions of only one
                    # family must not count for the other.
                    has4 = ($0 ~ /(^|[^A-Za-z0-9_])ip (saddr|daddr|protocol|ttl|frag-off|length|tos|dscp|ecn|ihl|version|id|checksum)/ || $0 ~ /(^|[^A-Za-z0-9_])icmp type/)
                    has6 = ($0 ~ /(^|[^A-Za-z0-9_])ip6 (saddr|daddr|nexthdr|hoplimit|flowlabel|priority|length)/ || $0 ~ /(^|[^A-Za-z0-9_])icmpv6/)
                    if (has4 && !has6) v6 = 0
                    if (has6 && !has4) v4 = 0
                    if (v4) hit4 = 1
                    if (v6) hit6 = 1
                }
            }
            END { if (hit4 && (need6 == 0 || hit6)) exit 0; exit 1 }
        '; then
            return 0
        fi
    fi
    return 1
}
case "$CORE" in xray) MAIN_SRV=xray;; singbox) MAIN_SRV=sing-box;; hysteria) MAIN_SRV=hysteria;; *) exit 0;; esac
failed_srv=''
service_active_owned "$MAIN_SRV" || failed_srv="$MAIN_SRV"
MAIN_PID=${SERVICE_PID:-}
HY2_SRV="$MAIN_SRV"; HY2_PID="$MAIN_PID"
if [[ "$CORE" == xray && "$MODE" == *ALL* ]]; then
    if [[ -z "$failed_srv" ]]; then service_active_owned hysteria || failed_srv=hysteria; fi
    HY2_SRV=hysteria; HY2_PID=${SERVICE_PID:-}
fi
if [[ -z "$failed_srv" && "${HY2_HOP:-}" == true && "${HY2_HOP_IMPL:-}" == official && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" ]]; then
    hysteria_official_hop_firewall_ok || failed_srv="$HY2_SRV"
fi
if [[ -z "$failed_srv" && "${HY2_HOP:-}" == true && "${HY2_HOP_IMPL:-}" == manual && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" && -n "${INGRESS_IF:-}" ]]; then
    redirect_port="${HY2_MONITOR_PORT:-${HY2_BASE_PORT:-${HY2_RANGE_START}}}"
    _iptables_q "$IPT" -t nat -C PREROUTING -i "$INGRESS_IF" -p udp --dport "${HY2_RANGE_START}:${HY2_RANGE_END}" -m comment --comment A-Box-HY2-HOP -j REDIRECT --to-ports "$redirect_port" 2>/dev/null || failed_srv="$HY2_SRV"
    if has_ipv6 && ipv6_nat_redirect_usable; then
        _iptables_q "$IPT6" -t nat -C PREROUTING -i "$INGRESS_IF" -p udp --dport "${HY2_RANGE_START}:${HY2_RANGE_END}" -m comment --comment A-Box-HY2-HOP -j REDIRECT --to-ports "$redirect_port" 2>/dev/null || failed_srv="$HY2_SRV"
    fi
fi
[[ -n "$failed_srv" || -z "${VLESS_PORT:-}" ]] || check_socket_or_fail tcp "$VLESS_PORT" "$MAIN_PID" "$MAIN_SRV"
[[ -n "$failed_srv" || -z "${XHTTP_PORT:-}" ]] || check_socket_or_fail tcp "$XHTTP_PORT" "$MAIN_PID" "$MAIN_SRV"
[[ -n "$failed_srv" || -z "${HY2_MONITOR_PORT:-}" ]] || check_socket_or_fail udp "$HY2_MONITOR_PORT" "$HY2_PID" "$HY2_SRV"
if [[ -z "$failed_srv" && -n "${SS_PORT:-}" ]]; then
    # H-04: skip when the running config no longer carries this
    # inbound (users_sync removed it); a silent port is expected then.
    if config_has_inbound_port shadowsocks "$SS_PORT"; then
        check_socket_or_fail tcp "$SS_PORT" "$MAIN_PID" "$MAIN_SRV"
        [[ -z "$failed_srv" ]] && check_socket_or_fail udp "$SS_PORT" "$MAIN_PID" "$MAIN_SRV"
    fi
fi
if [[ -z "$failed_srv" && -n "${SOCKS_PORT:-}" ]]; then
    # H-04: skip when the running config no longer carries this
    # inbound (users_sync removed it); a silent port is expected then.
    if config_has_inbound_port socks "$SOCKS_PORT"; then
        check_socket_or_fail tcp "$SOCKS_PORT" "$MAIN_PID" "$MAIN_SRV"
    fi
fi
if [[ -z "$failed_srv" ]]; then rm -f "$STATE"; exit 0; fi
# F-NEW-04/CD: narrow the runtime-guard window. The read-only checks
# above run without the runtime lock, so a healthy per-minute probe
# never contends with an interactive session (the occasional
# "another A-Box instance is running" refusal). Only a failed service
# needs the guard (auto-restore + restart below), so take it here;
# a contender at this point makes the probe yield this round.
acquire_abox_runtime_guard
count=0; last=0
[[ -r "$STATE" ]] && read -r count last < "$STATE" || true
[[ "$count" =~ ^[0-9]+$ ]] || count=0
[[ "$last" =~ ^[0-9]+$ ]] || last=0
now=$(date +%s)
# R25-F-S1-11: a failed xray may be a config fault, not an ordinary crash.
# Offer the bounded auto-restore first (marker/latch-gated inside the
# helper): 0 = restored, service up again (reset the failure count);
# 1 = config fault with no recovery (service stopped + latched by the
# helper; do not restart from here); 2 = not a config fault (fall
# through to the restart gate below). Only runs when the installed
# A-Box.sh actually supports the flag (version skew guard).
# The child inherits this probe's runtime guard: fd 9 is the probe's own
# lock, so dup the held runtime lock (fd 10) onto fd 9 for the child and
# restore it afterwards.
if [[ "$failed_srv" == xray && -f "$SCRIPT_DIR/A-Box.sh" && ! -L "$SCRIPT_DIR/A-Box.sh" ]] && grep -q -- '--xray-config-autorecover' "$SCRIPT_DIR/A-Box.sh" 2>/dev/null; then
    if exec 12>&9 9>&10 2>/dev/null; then
        ABOX_DIR="$SCRIPT_DIR" ABOX_INHERITED_LOCK_MODE=flock bash "$SCRIPT_DIR/A-Box.sh" --xray-config-autorecover
        _xc_rc=$?
        exec 9>&12 12>&- || true
        if (( _xc_rc == 0 )); then printf '0 %s\n' "$now" > "$STATE"; exit 0; fi
        if (( _xc_rc == 1 )); then rm -f "$STATE"; exit 0; fi
    fi
fi
count=$((count+1))
printf '%s %s\n' "$count" "$last" > "$STATE"
(( count >= 3 )) || exit 0
(( now - last >= 600 )) || exit 0
if restart_owned "$failed_srv"; then printf '0 %s\n' "$now" > "$STATE"; else printf '%s %s\n' "$count" "$now" > "$STATE"; fi
EOF_PROBE
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        sed -i "s|^INIT_SYS_EXPECTED=.*|INIT_SYS_EXPECTED='systemd'|" "$ABOX_DIR/socket_probe.sh" || die "$(tr_msg hp_mark)"
    else
        sed -i "s|^INIT_SYS_EXPECTED=.*|INIT_SYS_EXPECTED='openrc'|" "$ABOX_DIR/socket_probe.sh" || die "$(tr_msg hp_mark)"
    fi
    grep -Fxq "INIT_SYS_EXPECTED='${INIT_SYS}'" "$ABOX_DIR/socket_probe.sh" || die "$(tr_msg hp_mark_verify)"
    chmod 700 "$ABOX_DIR/socket_probe.sh" || die "$(tr_msg hp_chmod)"
    # A-06-FIX: No outer flock (script has internal flock -n 9 under umask 077).
    # Outer flock created 0644 lock in /run (tmpfs, cleared on reboot) - removed.
    install_abox_cron_block PROBE "* * * * * /bin/bash $ABOX_DIR/socket_probe.sh >/dev/null 2>&1"
}

setup_geo_cron() {
    command -v flock >/dev/null 2>&1 || die "$(tr_msg setup_geo_cron_flock_missing)"
    if ! abox_owns_service xray; then
        remove_abox_cron_block GEO || die "$(tr_msg gc_rm_cron)"
        remove_owned_runtime_helper "$ABOX_DIR/geo_update.sh" || die "$(tr_msg gc_rm_script)"
        return 0
    fi
    install -d -m 711 "$ABOX_DIR" || die "$(tr_msg gc_dir)"
    write_file_atomically_from_stdin "$ABOX_DIR/geo_update.sh" 700 <<'EOF_GEO' || die "$(tr_msg setup_geo_cron_script_write_failed)"
#!/usr/bin/env bash
# Managed by A-Box
# A-06: umask 077 ensures lock/temp files are 0600 (not world-readable 0644).
umask 077
set -o pipefail
# Self-contained helpers: verbatim copies of the main script's msg and
# abox_run_wait. This generated script runs standalone from cron and
# must never source install.sh.
msg() { printf '%s\n' "$*"; }
# R26b-L1: self-contained download label. This generated script never
# sources install.sh, so the main tr_msg is unavailable here; the label
# is resolved directly (NOT via a tr_msg key: reusing the
# fetch_one_downloading_geo key would give the i18n single-arm check a
# second arm per language and fail the self-test).
geo_download_label() {
    case "${ABOX_LANG:-zh}" in
        en) echo 'Geo data download' ;;
        ru) echo 'Загрузка данных Geo' ;;
        fa) echo 'دانلود داده‌های Geo' ;;
        zh-tw) echo 'Geo 資料下載' ;;
        ja) echo 'Geo データのダウンロード' ;;
        *) echo '下载 Geo 数据' ;;
    esac
}
abox_run_wait() {
    local _label="$1"; shift
    if [[ ! -t 2 ]]; then
        # The indicator belongs on stderr in both branches: callers
        # may capture the wrapped command's stdout.
        msg "  [*] ${_label} ..." >&2
        "$@"
        return $?
    fi
    "$@" &
    local _pid=$! _i=0 _t0=$SECONDS _frames='|/-\\'
    while kill -0 "$_pid" 2>/dev/null; do
        printf '\r  [%s] %s ... %ds ' "${_frames:$((_i % 4)):1}" "$_label" "$((SECONDS - _t0))" >&2
        _i=$((_i + 1)); sleep 0.2
    done
    wait "$_pid"; local _rc=$?
    printf '\r\033[K' >&2
    return "$_rc"
}
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# R11C8-02: derive the runtime dir from this script's own location (see
# socket_probe.sh); GEO_DIR itself is fixed (/usr/local/share/xray).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo /etc/ddr)"
GEO_REPO='Loyalsoldier/v2ray-rules-dat'
DESIRED="$SCRIPT_DIR/.desired_state"
PAIR_STATE="$SCRIPT_DIR/.traffic-pair-state"
INIT_SYS_EXPECTED='unknown'
ABOX_CORE_OWNERSHIP="$SCRIPT_DIR/.managed-core-files.tsv"
GEO_DIR=/usr/local/share/xray
GEO_TXN="$GEO_DIR/.A-Box-geo-transaction"
exec 9>>/run/A-Box-geo-update.lock || exit 1
flock -n 9; _flock_rc=$?
if (( _flock_rc != 0 )); then
    # rc 1 is contention: another run holds the lock, skip silently.
    # Any other rc (127 = flock missing, ...) is a real failure: exiting
    # 0 would silently disable this monitor, so fail loudly instead.
    (( _flock_rc == 1 )) || { echo "A-Box: flock failed (rc=$_flock_rc), not contention" >&2; exit 1; }
    exit 0
fi
RUNTIME_LOCK=/run/A-Box.lock
acquire_abox_runtime_guard() {
    local FALLBACK_DIR=/run/A-Box.lock.d fb_pid fb_start fb_actual mode
    # H-22 (Carbon R3): when the caller already holds the runtime lock
    # (menu force_update_geo runs under the main FD 9 lock), a second
    # flock on a fresh OFD would always fail (flock is per-OFD) and the
    # old code yielded with exit 0, which the caller read as success.
    # The caller passes ABOX_CALLER_HOLDS_LOCK=1; skip the redundant
    # guard. Cron runs without the variable and keeps the normal guard.
    if [[ "${ABOX_CALLER_HOLDS_LOCK:-}" == '1' ]]; then
        return 0
    fi
    [[ -d /run && ! -L /run ]] || exit 0
    # If a live fallback lock is held by another A-Box process, yield. Helpers
    # must not treat an idle LOCK_FILE flock as free while main owns fallback.
    if [[ -d "$FALLBACK_DIR" && ! -L "$FALLBACK_DIR" ]]; then
        # Unknown/fresh fallback dir (metadata not yet written) counts as
        # held: yielding is safe, taking the flock alongside an
        # initializing owner is not.
        if [[ ! -r "$FALLBACK_DIR/pid" || ! -r "$FALLBACK_DIR/starttime" ]]; then
            exit 0
        fi
        [[ "$(stat -c %u:%g "$FALLBACK_DIR" 2>/dev/null || true)" == 0:0 ]] || exit 0
        mode=$(stat -c %a "$FALLBACK_DIR" 2>/dev/null) || exit 0
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || exit 0
        (( (8#$mode & 8#077) == 0 )) || exit 0
        IFS= read -r fb_pid < "$FALLBACK_DIR/pid" || exit 0
        IFS= read -r fb_start < "$FALLBACK_DIR/starttime" || exit 0
        if [[ "$fb_pid" =~ ^[0-9]+$ && -d "/proc/$fb_pid" ]]; then
            # R6-F09-2: a failed/empty probe is UNKNOWN, never "no holder".
            # R25 (F07-02): robust starttime: strip "pid (comm) " first, so a comm
            # containing spaces cannot shift the field. proc_starttime() is not
            # visible inside this generated script, so the parse is inlined
            # (same text as runtime_lock_proc_starttime).
            fb_actual=$(awk '{ if (sub(/^[^ ]+ \(.*\) /, "") == 0) exit 1; print $20 }' "/proc/${fb_pid}/stat" 2>/dev/null) || exit 0
            [[ -z "$fb_actual" ]] && exit 0
            [[ -n "$fb_actual" && "$fb_actual" == "$fb_start" ]] && exit 0
        fi
    fi
    # /run is recreated on reboot; recreate the shared lock inode on demand.
    if [[ ! -e "$RUNTIME_LOCK" && ! -L "$RUNTIME_LOCK" ]]; then
        ( umask 077; set -C; : > "$RUNTIME_LOCK" ) 2>/dev/null || true
    fi
    [[ -f "$RUNTIME_LOCK" && ! -L "$RUNTIME_LOCK" ]] || exit 0
    [[ "$(stat -c %u:%g "$RUNTIME_LOCK" 2>/dev/null || true)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$RUNTIME_LOCK" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || exit 0
    (( (8#$mode & 8#077) == 0 )) || exit 0
    exec 10>>"$RUNTIME_LOCK" || exit 0
    flock -n 10; _flock_rc=$?
    if (( _flock_rc != 0 )); then
        # Same rc rule as the fd 9 block above.
        (( _flock_rc == 1 )) || { echo "A-Box: flock failed (rc=$_flock_rc), not contention" >&2; exit 1; }
        exit 0
    fi
}
# A-07: Do NOT acquire the shared runtime lock here. Downloads below (up to
# 60s + 90s + 90s = 240s) would hold /run/A-Box.lock and kill interactive
# sessions via flock -w 15. Acquired just before txn_stage instead.
is_systemd() { [[ "${INIT_SYS_EXPECTED:-${INIT_SYS:-}}" == systemd ]]; }
xray_owned() { local u; if is_systemd; then u=/etc/systemd/system/xray.service; else u=/etc/init.d/xray; fi; [[ -f "$u" && ! -L "$u" ]] && grep -Fxq '# Managed by A-Box' "$u"; }
update_geo_ownership() {
    python3 -I - "$ABOX_CORE_OWNERSHIP" /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat <<'PY_GEO_OWNER'
import hashlib, os, stat, sys, tempfile
manifest, *targets = sys.argv[1:]
st = os.lstat(manifest)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_mode & 0o077 or st.st_size > 4*1024*1024:
    raise SystemExit(1)
rows = []
with open(manifest, 'r', encoding='utf-8') as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) != 4 or parts[0] not in {'F','D'} or not parts[2].startswith('/') or '\x00' in line:
            raise SystemExit(1)
        rows.append(parts)
if len({(r[0],r[1],r[2]) for r in rows}) != len(rows):
    raise SystemExit(1)
for target in targets:
    st = os.lstat(target)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_mode & 0o022 or st.st_nlink != 1:
        raise SystemExit(1)
    h = hashlib.sha256()
    with open(target, 'rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''):
            h.update(chunk)
    matches = [r for r in rows if r[0] == 'F' and r[1] == 'xray' and r[2] == target]
    if len(matches) > 1:
        raise SystemExit(1)
    if not matches:
        # H-22 (Carbon R3): a host installed by an older minimal flow
        # has the geo files but no manifest rows for them; add the
        # missing row instead of failing (the old len != 1 check
        # failed legacy hosts).
        rows.append(['F', 'xray', target, h.hexdigest()])
    else:
        matches[0][3] = h.hexdigest()
# R26b-M2: cap the published OUTPUT, not just the input. Adding the
# missing geo rows can push a near-limit manifest over 4 MiB, and the
# published file would then be refused by this helper's own input
# check and by _geo_manifest_restore_rows (which loads the current
# manifest first), leaving no in-place repair path. Same bound as
# the R11-F R6-4 merged-output cap in _geo_manifest_restore_rows.
out = ''.join('\t'.join(row) + '\n' for row in sorted(rows, key=lambda r: (r[1], os.fsencode(r[2]))))
if len(out.encode('utf-8')) > 4 * 1024 * 1024:
    raise SystemExit(1)
dirname = os.path.dirname(manifest) or '.'
fd, tmp = tempfile.mkstemp(prefix='.managed-core-files.geo.', dir=dirname, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600); os.chown(tmp, 0, 0); os.replace(tmp, manifest)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY_GEO_OWNER
}
# R7-03 (legacy journals): remove the two geo ownership rows from the
# manifest so it cannot certify hashes of files restored from a
# pre-snapshot journal. Validates the manifest strictly first; a
# missing manifest means nothing to invalidate (return 0). Atomic
# rewrite only when rows were actually dropped.
_geo_manifest_restore_rows() {
    # R6-F07-4: row-level manifest restore. $1 = snapshot|empty, $2 = snapshot path.
    # Merges only the two geo rows (F/xray + geoip/geosite.dat paths) from the
    # snapshot into the current manifest; every other row is kept byte-for-byte
    # (raw line, original order). 'empty' drops the geo rows and keeps the rest.
    # Atomic via tmp+os.replace; any validation/commit failure returns 1.
    local _mode="$1" _snap="${2:-}"
    case "$_mode" in snapshot|empty) ;; *) return 1 ;; esac
    python3 -I - "$ABOX_CORE_OWNERSHIP" "$_mode" "$_snap" /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat <<'PY_GEO_MANIFEST_RESTORE'
import os, stat, sys, tempfile
manifest, mode, snap, *targets = sys.argv[1:]
# R11-F R6-4: merged-output cap, same value as the per-input _load cap.
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
targets = set(targets)
def _load(path, required):
    if not os.path.lexists(path):
        if required:
            raise SystemExit(1)
        return [], [], False
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_mode & 0o077 or st.st_size > MAX_MANIFEST_BYTES:
        raise SystemExit(1)
    rows, raws = [], []
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            if '\x00' in line:
                raise SystemExit(1)
            parts = line.rstrip('\n').split('\t')
            if len(parts) != 4 or parts[0] not in {'F','D'} or not parts[2].startswith('/') :
                raise SystemExit(1)
            rows.append(parts)
            raws.append(line if line.endswith('\n') else line + '\n')
    if len({(r[0],r[1],r[2]) for r in rows}) != len(rows):
        raise SystemExit(1)
    return rows, raws, True
snap_rows, _, _ = _load(snap, mode == 'snapshot') if mode == 'snapshot' else ([], [], False)
cur_rows, cur_raws, cur_exists = _load(manifest, False)
geo = [r for r in snap_rows if r[0] == 'F' and r[1] == 'xray' and r[2] in targets]
kept_raws = [raw for row, raw in zip(cur_rows, cur_raws)
             if not (row[0] == 'F' and row[1] == 'xray' and row[2] in targets)]
if not geo and not kept_raws:
    if not cur_exists:
        raise SystemExit(0)
# R11-F R6-4: verify the merged output size on the exact bytes that
# will be written (geo rows serialised here, kept rows already carry
# their trailing newline from _load) BEFORE creating any tmp file,
# so an oversize merge is refused with the original manifest intact
# and no tmp residue. Boundary: > limit refuses, exactly at limit ok.
geo_raws = ['\t'.join(row) + '\n' for row in geo]
output_bytes = (
    sum(len(raw.encode('utf-8')) for raw in geo_raws)
    + sum(len(raw.encode('utf-8')) for raw in kept_raws)
)
if output_bytes > MAX_MANIFEST_BYTES:
    print(
        f'geo manifest restore: merged output rejected '
        f'(oversize: {output_bytes} > {MAX_MANIFEST_BYTES} bytes); '
        f'not published',
        file=sys.stderr,
    )
    raise SystemExit(1)
dirname = os.path.dirname(manifest) or '.'
fd, tmp = tempfile.mkstemp(prefix='.managed-core-files.geo.', dir=dirname, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        for raw in geo_raws:
            f.write(raw)
        for raw in kept_raws:
            f.write(raw)
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600); os.chown(tmp, 0, 0); os.replace(tmp, manifest)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY_GEO_MANIFEST_RESTORE
}
_geo_manifest_invalidate() {
    python3 -I - "$ABOX_CORE_OWNERSHIP" /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat <<'PY_GEO_MANIFEST_INVALIDATE'
import os, stat, sys, tempfile
manifest, *targets = sys.argv[1:]
if not os.path.exists(manifest):
    raise SystemExit(0)
st = os.lstat(manifest)
if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_mode & 0o077 or st.st_size > 4*1024*1024:
    raise SystemExit(1)
rows = []
with open(manifest, 'r', encoding='utf-8') as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) != 4 or parts[0] not in {'F','D'} or not parts[2].startswith('/') or '\x00' in line:
            raise SystemExit(1)
        rows.append(parts)
if len({(r[0],r[1],r[2]) for r in rows}) != len(rows):
    raise SystemExit(1)
kept = [r for r in rows if not (r[0] == 'F' and r[1] == 'xray' and r[2] in targets)]
if len(kept) == len(rows):
    raise SystemExit(0)
dirname = os.path.dirname(manifest) or '.'
fd, tmp = tempfile.mkstemp(prefix='.managed-core-files.geo.', dir=dirname, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        for row in sorted(kept, key=lambda r: (r[1], os.fsencode(r[2]))):
            f.write('\t'.join(row) + '\n')
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600); os.chown(tmp, 0, 0); os.replace(tmp, manifest)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY_GEO_MANIFEST_INVALIDATE
}
restore_geo_transaction() {
    local base="$GEO_DIR" txn="$GEO_TXN" name had stage _mhad
    [[ -d "$txn" && ! -L "$txn" && "$(stat -c %u:%g "$txn" 2>/dev/null)" == 0:0 ]] || return 1
    for name in geoip geosite; do
        had=$(cat "$txn/had_$name" 2>/dev/null) || return 1
        case "$had" in
            1)
                [[ -f "$txn/$name.old" && ! -L "$txn/$name.old" ]] || return 1
                # R16-F07-04: refuse a directory (or symlink) target before
                # moving anything: without -T, mv would drop the staged
                # file inside the directory and still report success.
                [[ ( ! -e "$base/$name.dat" || -f "$base/$name.dat" ) && ! -L "$base/$name.dat" ]] || return 1
                stage=$(mktemp "$base/.$name.A-Box-restore.XXXXXX") || return 1
                if ! cp -p "$txn/$name.old" "$stage" || ! mv -f -- "$stage" "$base/$name.dat"; then
                    rm -f -- "$stage"
                    return 1
                fi
                ;;
            0) rm -f -- "$base/$name.dat" || return 1 ;;
            2)
                # R13C8-01: recreate the recorded symlink.
                link_target=$(cat "$txn/$name.link" 2>/dev/null) || return 1
                [[ -n "$link_target" ]] || return 1
                rm -f -- "$base/$name.dat" || return 1
                # R26b-M1: a recorded link target may start with '-'
                # (readlink output is recorded verbatim, no leading-dash
                # check): without `--` ln parses it as options and
                # fails AFTER the rm above already deleted the .dat,
                # and every retry fails at the same place.
                ln -s -- "$link_target" "$base/$name.dat" || return 1
                ;;
            *) return 1 ;;
        esac
    done
    # R7-03 (R6-F07-4): restore only the two geo rows from the recorded
    # manifest pre-state (snapshot path) or invalidate the geo rows
    # (legacy journals without a snapshot). Other families' rows are
    # never touched by the restore.
    # Never re-certify restored files via the hash-resync helper: the
    # restored pre-state is authoritative by construction.
    if [[ -f "$txn/had_manifest" && ! -L "$txn/had_manifest" ]]; then
        _mhad=$(cat "$txn/had_manifest" 2>/dev/null) || return 1
        case "$_mhad" in
            1)
                [[ -f "$txn/manifest.old" && ! -L "$txn/manifest.old" ]] || return 1
                [[ ! -L "$ABOX_CORE_OWNERSHIP" ]] || return 1
                _geo_manifest_restore_rows snapshot "$txn/manifest.old" || return 1
                ;;
            0)
                _geo_manifest_restore_rows empty || return 1
                ;;
            *) return 1 ;;
        esac
    else
        # Legacy journal (no manifest snapshot): drop the two geo rows
        # from the manifest so it cannot certify hashes of files that
        # were restored without a recorded pre-state. The next geo
        # update fails closed until the rows are re-registered by a
        # trusted deploy/repair flow.
        _geo_manifest_invalidate || return 1
    fi
    # 04b-02: the transaction log is the recovery intent. It must NOT
    # be deleted here: the caller restarts the service only after this
    # function returns, and a kill or a failed restart in between
    # would leave no log to retry the restore. Callers delete the log
    # once the recovery restart has succeeded (or was correctly
    # skipped because the service must stay stopped).
    return 0
}
fetch_one() {
    local asset="$1" out="$2" release_file="$3" release_json asset_json url digest expected actual size
    [[ -r "$release_file" && -f "$release_file" && ! -L "$release_file" ]] || return 1
    release_json=$(cat -- "$release_file") || return 1
    asset_json=$(jq -c --arg name "$asset" 'first(.assets[]? | select(.name == $name) | {name:.name,url:.browser_download_url,digest:(.digest // "")}) // empty' <<< "$release_json")
    [[ -n "$asset_json" && "$asset_json" != null ]] || return 1
    url=$(jq -r '.url' <<< "$asset_json")
    digest=$(jq -r '.digest // ""' <<< "$asset_json")
    [[ -n "$GEO_RELEASE_TAG" && "$url" == "https://github.com/${GEO_REPO}/releases/download/${GEO_RELEASE_TAG}/${asset}" && "$digest" == sha256:* ]] || return 1
    expected="${digest#sha256:}"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    abox_run_wait "$(geo_download_label)" curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 -m 90 "$url" -o "$out" || return 1
    actual=$(sha256sum "$out" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || return 1
    size=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 500000 ]] || return 1
    ! head -c 256 "$out" 2>/dev/null | grep -Eiq '<(html|!doctype)'
}
[[ -d "$GEO_DIR" && ! -L "$GEO_DIR" ]] || exit 0
xray_owned || exit 0
# Recover if the previous process died between GeoDB renames or during restart.
if [[ -e "$GEO_TXN" || -L "$GEO_TXN" ]]; then
    [[ -d "$GEO_TXN" && ! -L "$GEO_TXN" && "$(stat -c %u:%g "$GEO_TXN" 2>/dev/null)" == 0:0 ]] || exit 1
    # U29: recover under the shared runtime guard, and restart only when
    # the desired state is confirmed RUNNING; an admin-stopped service
    # must not be resurrected by recovery. The guard is released before
    # downloads (A-07) and re-acquired for the file-modification phase.
    acquire_abox_runtime_guard
    desired=STOPPED
    if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
        # S23: pair exists: never fall through to legacy; unsafe or
        # malformed pair keeps the fail-closed STOPPED default.
        if [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] && [[ "$(stat -c %u:%g "$PAIR_STATE" 2>/dev/null)" == 0:0 ]]; then
            mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || mode=''
            if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) && IFS= read -r _pair < "$PAIR_STATE" && [[ "$_pair" == *'|'* ]]; then
                desired=${_pair%%|*}
                _pair_period=${_pair#*|}
                if [[ -n "$_pair_period" && ! "$_pair_period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then desired=STOPPED; fi
                case "$desired" in RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE) ;; *) desired=STOPPED ;; esac
            fi
        fi
    elif [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
        if [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] && [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]]; then
            mode=$(stat -c %a "$DESIRED" 2>/dev/null) || mode=''
            if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) && IFS= read -r _des < "$DESIRED"; then
                desired="$_des"
            fi
        fi
    fi
    restore_geo_transaction || { exec 10>&-; exit 1; }
    # A restart here only flushes data the interrupted run may have loaded
    # into memory; it must never revive a service meant to stay down.
    if [[ "$desired" == RUNNING ]]; then
        if is_systemd; then
            systemctl restart xray >/dev/null 2>&1 || { exec 10>&-; exit 1; }
        else
            rc-service xray restart >/dev/null 2>&1 9>&- 10>&- || { exec 10>&-; exit 1; }
        fi
    fi
    # 04b-02: delete the transaction log only now, after the recovery
    # restart has succeeded (or was correctly skipped because the
    # service must stay stopped). A failed restart above exits with
    # the log intact, so the next run can retry the recovery.
    rm -rf -- "$GEO_TXN" || { exec 10>&-; exit 1; }
    exec 10>&-
fi
desired=RUNNING
if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
    # S23: a pair file that exists but fails safety checks is an error:
    # exit here, never fall through to legacy/default RUNNING.
    [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] || exit 0
    [[ "$(stat -c %u:%g "$PAIR_STATE" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r _pair < "$PAIR_STATE" || exit 0
    [[ "$_pair" == *'|'* ]] || exit 0
    desired=${_pair%%|*}
    _pair_period=${_pair#*|}
    if [[ -n "$_pair_period" && ! "$_pair_period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then exit 0; fi
    case "$desired" in RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE) ;; *) exit 0 ;; esac
elif [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
    [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] || exit 0
    [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$DESIRED" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r desired < "$DESIRED" || exit 0
fi
[[ "$desired" == RUNNING ]] || exit 0
if is_systemd; then systemctl is-active --quiet xray || exit 0; else rc-service xray status >/dev/null 2>&1 || exit 0; fi
tmpdir=$(umask 077; mktemp -d /tmp/A-Box-geo.XXXXXX) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT
release_file="$tmpdir/release.json"
api="https://api.github.com/repos/${GEO_REPO}/releases/latest"
curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 -m 60 -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' "$api" -o "$release_file" || exit 1
GEO_RELEASE_TAG=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type=="string" and test("^[A-Za-z0-9._-]+$"))' "$release_file" 2>/dev/null) || exit 1
fetch_one geoip.dat "$tmpdir/geoip.dat" "$release_file" || exit 1
fetch_one geosite.dat "$tmpdir/geosite.dat" "$release_file" || exit 1
# A-07: Acquire the shared runtime lock ONLY for the file-modification phase
# (txn_stage creation, geo file replacement, xray restart, ownership update).
# Downloads above ran under geo-update.lock only.
acquire_abox_runtime_guard
# A-07-FIX: Revalidate state AFTER downloads (admin may have uninstalled/stopped
# Xray during the download window). If state changed, exit safely without writing.
[[ -d "$GEO_DIR" && ! -L "$GEO_DIR" ]] || exit 0
xray_owned || exit 0
desired=RUNNING
if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
    # S23: a pair file that exists but fails safety checks is an error:
    # exit here, never fall through to legacy/default RUNNING.
    [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] || exit 0
    [[ "$(stat -c %u:%g "$PAIR_STATE" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r _pair < "$PAIR_STATE" || exit 0
    [[ "$_pair" == *'|'* ]] || exit 0
    desired=${_pair%%|*}
    _pair_period=${_pair#*|}
    if [[ -n "$_pair_period" && ! "$_pair_period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then exit 0; fi
    case "$desired" in RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE) ;; *) exit 0 ;; esac
elif [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
    [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] || exit 0
    [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]] || exit 0
    mode=$(stat -c %a "$DESIRED" 2>/dev/null) || exit 0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || exit 0
    IFS= read -r desired < "$DESIRED" || exit 0
fi
[[ "$desired" == RUNNING ]] || exit 0
if is_systemd; then systemctl is-active --quiet xray || exit 0; else rc-service xray status >/dev/null 2>&1 || exit 0; fi
txn_stage=$(umask 077; mktemp -d "$GEO_DIR/.A-Box-geo-txn-new.XXXXXX") || exit 1
chmod 700 "$txn_stage" || { rm -rf -- "$txn_stage"; exit 1; }
if [[ -L "$GEO_DIR/geoip.dat" ]]; then
    # R13C8-01: a symlink is a third state, not "nonexistent": record its
    # target so rollback recreates the link instead of deleting it.
    link_target=$(readlink "$GEO_DIR/geoip.dat" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    [[ -n "$link_target" ]] || { rm -rf -- "$txn_stage"; exit 1; }
    printf '%s\n' "$link_target" > "$txn_stage/geoip.link" || { rm -rf -- "$txn_stage"; exit 1; }
    printf '2\n' > "$txn_stage/had_geoip" || { rm -rf -- "$txn_stage"; exit 1; }
elif [[ -f "$GEO_DIR/geoip.dat" ]]; then
    cp -p "$GEO_DIR/geoip.dat" "$txn_stage/geoip.old" || { rm -rf -- "$txn_stage"; exit 1; }
    printf '1\n' > "$txn_stage/had_geoip" || { rm -rf -- "$txn_stage"; exit 1; }
elif [[ -e "$GEO_DIR/geoip.dat" ]]; then
    # 04b-01: a directory (or other non-regular, non-symlink) target is
    # not "absent": recording had=0 would create a transaction whose
    # restore branch (rm -f) can never satisfy it. Fail closed before
    # the transaction exists.
    rm -rf -- "$txn_stage"; exit 1
else
    printf '0\n' > "$txn_stage/had_geoip" || { rm -rf -- "$txn_stage"; exit 1; }
fi
if [[ -L "$GEO_DIR/geosite.dat" ]]; then
    # R13C8-01: a symlink is a third state, not "nonexistent": record its
    # target so rollback recreates the link instead of deleting it.
    link_target=$(readlink "$GEO_DIR/geosite.dat" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    [[ -n "$link_target" ]] || { rm -rf -- "$txn_stage"; exit 1; }
    printf '%s\n' "$link_target" > "$txn_stage/geosite.link" || { rm -rf -- "$txn_stage"; exit 1; }
    printf '2\n' > "$txn_stage/had_geosite" || { rm -rf -- "$txn_stage"; exit 1; }
elif [[ -f "$GEO_DIR/geosite.dat" ]]; then
    cp -p "$GEO_DIR/geosite.dat" "$txn_stage/geosite.old" || { rm -rf -- "$txn_stage"; exit 1; }
    printf '1\n' > "$txn_stage/had_geosite" || { rm -rf -- "$txn_stage"; exit 1; }
elif [[ -e "$GEO_DIR/geosite.dat" ]]; then
    # 04b-01: same non-regular-target refusal as geoip.dat above.
    rm -rf -- "$txn_stage"; exit 1
else
    printf '0\n' > "$txn_stage/had_geosite" || { rm -rf -- "$txn_stage"; exit 1; }
fi
# S43 (GPT-15 + argon P1-1): chmod 600 only had_*; the .old backups
# keep their original mode (cp -p) so a rollback restores exactly
# what was there (0644 for a fresh install). The txn dir itself is
# 700 root-only, so the .old files are still protected at rest.
chmod 600 "$txn_stage"/had_* 2>/dev/null || true
# R15C8-02: chown only the txn dir itself, NOT the .old backups: cp -p
# already preserved their original UID/GID/mode, and a recursive chown
# would make a restored DB root:root 0640, unreadable by a
# non-privileged runtime service. The 700 root-only txn dir still
# protects the backups at rest.
chown root:root "$txn_stage" || { rm -rf -- "$txn_stage"; exit 1; }
# R7-03: snapshot the ownership manifest pre-state into the transaction
# so rollback can restore the two geo rows (hashes included) instead of
# re-certifying restored files. A symlinked or non-regular manifest
# fails closed here, and so does a manifest the restorer would refuse
# (non-root owner, group/other mode bits, oversize, or malformed rows):
# snapshotting it would publish a snapshot rollback can never restore
# (R11-D R6-2). The update cannot safely record pre-state for it.
if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
    [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || { rm -rf -- "$txn_stage"; exit 1; }
    _r6_uid=$(stat -c %u "$ABOX_CORE_OWNERSHIP" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    _r6_gid=$(stat -c %g "$ABOX_CORE_OWNERSHIP" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    _r6_mode=$(stat -c %a "$ABOX_CORE_OWNERSHIP" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    _r6_size=$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    [[ "$_r6_uid" == 0 && "$_r6_gid" == 0 ]] || { printf '%s\n' "geo_update: ownership manifest snapshot rejected (unsafe owner); update aborted before Geo changes" >&2; rm -rf -- "$txn_stage"; exit 1; }
    (( (8#$_r6_mode & 077) == 0 )) || { printf '%s\n' "geo_update: ownership manifest snapshot rejected (unsafe mode); update aborted before Geo changes" >&2; rm -rf -- "$txn_stage"; exit 1; }
    (( _r6_size <= 4194304 )) || { printf '%s\n' "geo_update: ownership manifest snapshot rejected (oversize); update aborted before Geo changes" >&2; rm -rf -- "$txn_stage"; exit 1; }
    cp -p "$ABOX_CORE_OWNERSHIP" "$txn_stage/manifest.old" || { rm -rf -- "$txn_stage"; exit 1; }
    python3 -I - "$txn_stage/manifest.old" <<'PY_GEO_MANIFEST_SNAPSHOT_CHECK' || { printf '%s\n' "geo_update: ownership manifest snapshot rejected (malformed rows); update aborted before Geo changes" >&2; rm -rf -- "$txn_stage"; exit 1; }
import os, stat, sys
path = sys.argv[1]
st = os.lstat(path)
ok = stat.S_ISREG(st.st_mode) and st.st_uid == 0 and st.st_gid == 0 and not (st.st_mode & 0o077) and st.st_size <= 4 * 1024 * 1024
seen = set()
with open(path, 'r', encoding='utf-8') as f:
    for line in f:
        ok = ok and '\x00' not in line
        parts = line.rstrip('\n').split('\t')
        ok = ok and len(parts) == 4 and parts[0] in {'F', 'D'} and parts[2].startswith('/')
        ok = ok and (parts[0], parts[1], parts[2]) not in seen
        seen.add((parts[0], parts[1], parts[2]))
raise SystemExit(not ok)
PY_GEO_MANIFEST_SNAPSHOT_CHECK
    printf '1\n' > "$txn_stage/had_manifest" || { rm -rf -- "$txn_stage"; exit 1; }
else
    printf '0\n' > "$txn_stage/had_manifest" || { rm -rf -- "$txn_stage"; exit 1; }
fi
# R8C8-01: validate markers before publish: an empty or malformed had_*
# must never reach GEO_TXN, or every later restore fails and updates
# stall permanently.
for _m in geoip geosite; do
    _hv=$(cat "$txn_stage/had_$_m" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
    case "$_hv" in 0|1|2) ;; *) rm -rf -- "$txn_stage"; exit 1 ;; esac
done
_hv=$(cat "$txn_stage/had_manifest" 2>/dev/null) || { rm -rf -- "$txn_stage"; exit 1; }
case "$_hv" in 0|1) ;; *) rm -rf -- "$txn_stage"; exit 1 ;; esac
if [[ "$_hv" == 1 ]]; then
    [[ -f "$txn_stage/manifest.old" && ! -L "$txn_stage/manifest.old" ]] || { rm -rf -- "$txn_stage"; exit 1; }
fi
mv "$txn_stage" "$GEO_TXN" || { rm -rf -- "$txn_stage"; exit 1; }
stage_ip=$(mktemp "$GEO_DIR/.geoip.A-Box-new.XXXXXX") || { restore_geo_transaction || true; exit 1; }
stage_site=$(mktemp "$GEO_DIR/.geosite.A-Box-new.XXXXXX") || { rm -f "$stage_ip"; restore_geo_transaction || true; exit 1; }
install -m 644 "$tmpdir/geoip.dat" "$stage_ip" || { rm -f "$stage_ip" "$stage_site"; restore_geo_transaction || true; exit 1; }
install -m 644 "$tmpdir/geosite.dat" "$stage_site" || { rm -f "$stage_ip" "$stage_site"; restore_geo_transaction || true; exit 1; }
# 04b-01: refuse a directory (or symlink) target before moving, mirroring
# the R16-F07-04 guard in restore_geo_transaction: without -T, mv drops
# the staged file inside the directory and reports success, while the
# target path itself stays a directory.
[[ ( ! -e "$GEO_DIR/geoip.dat" || -f "$GEO_DIR/geoip.dat" ) && ! -L "$GEO_DIR/geoip.dat" ]] || { rm -f "$stage_ip" "$stage_site"; restore_geo_transaction || true; exit 1; }
mv -f "$stage_ip" "$GEO_DIR/geoip.dat" || { rm -f "$stage_ip" "$stage_site"; restore_geo_transaction || true; exit 1; }
[[ ( ! -e "$GEO_DIR/geosite.dat" || -f "$GEO_DIR/geosite.dat" ) && ! -L "$GEO_DIR/geosite.dat" ]] || { rm -f "$stage_site"; restore_geo_transaction || true; exit 1; }
mv -f "$stage_site" "$GEO_DIR/geosite.dat" || { rm -f "$stage_site"; restore_geo_transaction || true; exit 1; }
restart_ok=0
if is_systemd; then
    systemctl restart xray >/dev/null 2>&1 && systemctl is-active --quiet xray && restart_ok=1
else
    rc-service xray restart >/dev/null 2>&1 9>&- 10>&- && rc-service xray status >/dev/null 2>&1 && restart_ok=1
fi
if [[ "$restart_ok" != 1 ]]; then
    restore_geo_transaction || exit 1
    if is_systemd; then systemctl restart xray >/dev/null 2>&1 || true; else rc-service xray restart >/dev/null 2>&1 9>&- 10>&- || true; fi
    exit 1
fi
if ! update_geo_ownership; then
    restore_geo_transaction || exit 1
    if is_systemd; then systemctl restart xray >/dev/null 2>&1 || true; else rc-service xray restart >/dev/null 2>&1 9>&- 10>&- || true; fi
    exit 1
fi
rm -rf -- "$GEO_TXN" || exit 1
EOF_GEO
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        sed -i "s|^INIT_SYS_EXPECTED=.*|INIT_SYS_EXPECTED='systemd'|" "$ABOX_DIR/geo_update.sh" || die "$(tr_msg gu_mark)"
    else
        sed -i "s|^INIT_SYS_EXPECTED=.*|INIT_SYS_EXPECTED='openrc'|" "$ABOX_DIR/geo_update.sh" || die "$(tr_msg gu_mark)"
    fi
    grep -Fxq "INIT_SYS_EXPECTED='${INIT_SYS}'" "$ABOX_DIR/geo_update.sh" || die "$(tr_msg gu_mark_verify)"
    chmod 700 "$ABOX_DIR/geo_update.sh" || die "$(tr_msg gu_chmod)"
    # A-06-FIX: No outer flock (see PROBE above).
    install_abox_cron_block GEO "0 3 * * 1 /bin/bash $ABOX_DIR/geo_update.sh >/dev/null 2>&1"
}

