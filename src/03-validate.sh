# ABOX-MODULE-BEGIN 03-validate tprintf, validation, prompts, SNI, env, UUID, public IP
#   Source: install.sh lines 12010-15452 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
tprintf() {
    local key="$1" fmt placeholder_count=0 i=0 len next
    shift
    fmt=$(tr_msg "$key")
    # Translation strings are internal, but validate their printf grammar before
    # passing them to printf. Only %s and %% are supported, with %% treated as
    # a literal percent and never counted as a placeholder.
    # Error paths inside tprintf must never call tprintf itself: if the
    # tp_bad_fmt/tp_arg_mismatch translations were the broken ones, the
    # error report would recurse forever (found by the self-test stubs,
    # which return a bad format for every key). Use literal fallbacks.
    [[ "$fmt" != *\\* ]] || die "tprintf: invalid format in translation '$key'"
    len=${#fmt}
    while (( i < len )); do
        if [[ "${fmt:i:1}" == '%' ]]; then
            (( i + 1 < len )) || die "tprintf: invalid format in translation '$key'"
            next=${fmt:i+1:1}
            case "$next" in
                '%') i=$((i + 2)) ;;
                s) placeholder_count=$((placeholder_count + 1)); i=$((i + 2)) ;;
                *) die "tprintf: invalid format in translation '$key'" ;;
            esac
        else
            i=$((i + 1))
        fi
    done
    (( placeholder_count == $# )) || die "tprintf: argument count mismatch in translation '$key'"
    # W7-OBS-3: a format starting with dashes (e.g. tl_trying's "--- ...")
    # is parsed as printf options without `--` ("printf: --: invalid
    # option", stderr noise, empty output). `--` ends option parsing.
    printf -- "$fmt" "$@"
}

proto_label() {
    printf '%b[%s]%b' "${BOLD}${CYAN}" "$1" "${NC}"
}

pause_return() {
    # Piped-menu automation: skip pause when stdin is not a TTY (non-interactive).
    [[ ! -t 0 ]] && return 0
    local released=0
    if [[ -t 0 ]]; then
        # Briefly release exclusive flock during idle prompt so cron helpers can run.
        if [[ "${ABOX_RUNTIME_LOCK_MODE:-}" == flock ]] && [[ -e /proc/$$/fd/9 ]]; then
            flock -u 9 2>/dev/null && released=1 || true
        fi
        read -r -p "$(tr_msg press_return)" _ || true
        if (( released == 1 )); then
            # M-03: a failed re-lock must not kill the session; warn and
            # return to the menu (the next prompt retries the lock).
            if ! flock -w 15 9; then
                msg "${YELLOW}[!] $(tr_msg tp_lock)${NC}"
            fi
        fi
    fi
}

is_yes() { [[ "${1:-}" =~ ^[Yy]$ ]]; }

confirm_yes_no() {
    local prompt="$1" answer
    # R8-F3-1: a failed read must refuse, even when it already stored
    # a 'y' (e.g. 'y' with no trailing newline, then EOF): only a
    # successful read plus is_yes counts as confirmation.
    read -r -p "$prompt" answer || return 1
    is_yes "$answer"
}

detect_lang() {
    if [[ -n "${ABOX_LANG_OVERRIDE:-}" ]]; then
        ABOX_LANG=$(normalize_lang "$ABOX_LANG_OVERRIDE")
    elif [[ -n "${ABOX_LANG:-}" && "${ABOX_LANG:-}" != 'zh' ]]; then
        ABOX_LANG=$(normalize_lang "$ABOX_LANG")
    elif [[ -r "$LANG_FILE" ]]; then
        ABOX_LANG=$(normalize_lang "$(tr -d '[:space:]' < "$LANG_FILE" 2>/dev/null)")
    else
        ABOX_LANG='zh'
    fi
}

save_lang() {
    ensure_abox_dir_owned "$ABOX_DIR"
    write_file_atomically_from_stdin "$LANG_FILE" 600 <<< "${ABOX_LANG:-zh}" || die "$(tr_msg tp_lang_write)"
}

initial_language_select() {
    [[ -f "$LANG_FILE" || -n "${ABOX_LANG_OVERRIDE:-}" ]] && return 0
    local c
    echo 'Language / 语言 / 語言 / 言語 / Язык / زبان'
    echo '1. 简体中文'
    echo '2. 繁體中文'
    echo '3. English'
    echo '4. 日本語'
    echo '5. Русский'
    echo '6. فارسی'
    read -r -p 'Select [1-6, default 1]: ' c || true
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        2) ABOX_LANG='zh-tw' ;;
        3) ABOX_LANG='en' ;;
        4) ABOX_LANG='ja' ;;
        5) ABOX_LANG='ru' ;;
        6) ABOX_LANG='fa' ;;
        *) ABOX_LANG='zh' ;;
    esac
    save_lang
}
language_menu() {
    # Submenu loop: 0/Enter returns to the parent menu.
    while true; do
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg lang_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    msg "${CYAN}1.${NC} $(tr_msg language_menu_simplified_chinese)"
    msg "${CYAN}2.${NC} $(tr_msg language_menu_traditional_chinese)"
    msg "${CYAN}3.${NC} English"
    msg "${CYAN}4.${NC} $(tr_msg language_menu_japanese)"
    msg "${CYAN}5.${NC} Русский"
    msg "${CYAN}6.${NC} فارسی"
    msg "${CYAN}0.${NC} $(tr_msg language_menu_back)"
    local c
    read -r -p 'Select [0-6]: ' c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) ABOX_LANG='zh'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        2) ABOX_LANG='zh-tw'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        3) ABOX_LANG='en'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        4) ABOX_LANG='ja'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        5) ABOX_LANG='ru'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        6) ABOX_LANG='fa'; save_lang; msg "${GREEN}$(tr_msg lang_saved)${NC}"; pause_return ;;
        0|'') return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}
need_interactive_tty() {
    if [[ ! -t 0 ]]; then
        # Version B: piped-menu automation. Honor non-TTY stdin (pipe/file redirect)
        # for scripted menu runs instead of stealing /dev/tty. The main menu
        # already exits cleanly on EOF (read ... || exit 0), and pause_return()
        # skips when stdin is not a TTY.
        # Default: reattach /dev/tty for interactive safety (prevents curl|bash early exit).
        # Automation: set ABOX_PIPED=1 to explicitly enable piped-menu mode.
        [[ "${ABOX_PIPED:-0}" == 1 ]] && return 0
        if [[ -r /dev/tty ]] && ( : < /dev/tty ) 2>/dev/null; then
            exec < /dev/tty || die "$(tr_msg tp_tty_open)"
        else
            die "$(tr_msg tp_tty_menu)"
        fi
    fi
}
valid_decimal_upto() {
    local input="${1:-}" max="${2:-}" normalized
    [[ "$input" =~ ^[0-9]+$ ]] || return 1
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || return 1
    normalized="${input#"${input%%[!0]*}"}"
    [[ -n "$normalized" ]] || normalized='0'
    (( ${#normalized} < ${#max} )) && return 0
    (( ${#normalized} > ${#max} )) && return 1
    (( 10#$normalized <= 10#$max ))
}

valid_port() {
    local input="${1:-}" normalized
    valid_decimal_upto "$input" 65535 || return 1
    normalized="${input#"${input%%[!0]*}"}"
    [[ -n "$normalized" ]] || return 1
    (( 10#$normalized >= 1 ))
}

valid_canonical_port() {
    local input="${1:-}"
    valid_port "$input" || return 1
    [[ "$input" == "$((10#$input))" ]]
}

valid_canonical_port_range() {
    local input="${1:-}" start end
    if [[ "$input" =~ ^([0-9]+):([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    valid_canonical_port "$start" && valid_canonical_port "$end" && (( 10#$start <= 10#$end ))
}

valid_port_range() {
    local input="${1:-}" start end
    if [[ "$input" =~ ^([0-9]+):([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    valid_port "$start" && valid_port "$end" && (( 10#$start <= 10#$end ))
}

normalize_port_spec() {
    local input="${1:-}" start end
    if valid_port "$input"; then
        printf '%s\n' "$((10#$input))"
        return 0
    fi
    valid_port_range "$input" || return 1
    if [[ "$input" == *:* ]]; then
        start="${input%%:*}"; end="${input##*:}"
    else
        start="${input%%-*}"; end="${input##*-}"
    fi
    printf '%s:%s\n' "$((10#$start))" "$((10#$end))"
}

valid_port_spec() { normalize_port_spec "${1:-}" >/dev/null 2>&1; }

valid_hy2_uri_ports() {
    local input="${1:-}" part
    [[ "$input" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    local IFS=,
    local -a _parts=()
    read -r -a _parts <<< "$input"
    ((${#_parts[@]} > 0)) || return 1
    for part in "${_parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            valid_canonical_port_range "$part" || return 1
        else
            valid_canonical_port "$part" || return 1
        fi
    done
}

valid_hy2_clash_ports() {
    local input="${1:-}"
    [[ "$input" =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
    if [[ "$input" == *-* ]]; then
        valid_canonical_port_range "$input" || return 1
    else
        valid_canonical_port "$input" || return 1
    fi
}

valid_hy2_sb_ports() {
    local input="${1:-}"
    [[ "$input" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    valid_canonical_port_range "$input" || return 1
}

port_spec_for_firewalld() {
    local spec
    spec=$(normalize_port_spec "${1:-}") || return 1
    printf '%s\n' "${spec/:/-}"
}

port_list_for_firewalld() {
    local input="${1:-}" item normalized result=''
    local -a items=()
    [[ -n "$input" ]] || return 1
    local IFS=,
    read -r -a items <<< "$input"
    (("${#items[@]}" > 0)) || return 1
    for item in "${items[@]}"; do
        normalized=$(port_spec_for_firewalld "$item") || return 1
        result+="${result:+,}${normalized}"
    done
    printf '%s\n' "$result"
}

valid_positive_int() {
    # Keep decimal integers within a range safe for Bash arithmetic on
    # standard 64-bit Linux; callers may still impose a tighter domain limit.
    [[ "${1:-}" =~ ^[1-9][0-9]{0,17}$ ]]
}

valid_traffic_limit_gb() {
    local input="${1:-}"
    [[ "$input" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    (( 10#$input <= 8589934591 ))
}
valid_backup_retention_count() {
    local input="${1:-}"
    [[ "$input" =~ ^[0-9]{1,4}$ ]] || return 1
    (( 10#$input <= 1000 ))
}
valid_hy2_bandwidth_mbps() {
    # Keep the interactive HY2 bandwidth domain identical to the persisted .env validator.
    valid_traffic_limit_gb "${1:-}"
}

valid_domain() {
    local domain="${1:-}"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9]([A-Za-z0-9-]{0,57}[A-Za-z0-9])?)$ ]]
}

valid_sni() { valid_domain "$1"; }

valid_single_line_secret() {
    local value="${1:-}" max_len="${2:-512}"
    [[ -n "$value" && ${#value} -le $max_len ]] || return 1
    [[ "$value" != *[[:cntrl:]]* ]]
}

# ============ Version C: unified validation framework ============
# valid_uuid: standalone UUIDv4 shape check (was inline at config validation).
valid_uuid() {
    local input="${1:-}"
    [[ "$input" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# valid_path: must start with /, no whitespace/control/quotes/backslash.
valid_path() {
    local input="${1:-}"
    [[ -n "$input" ]] || return 1
    [[ "$input" == /* ]] || return 1
    case "$input" in
        *[[:space:][:cntrl:]]*|*\"*|*\'*|*\\*) return 1 ;;
    esac
    return 0
}

# port_is_free: true when nothing is listening on the port locally.
# $2 = proto: tcp (default), udp, or both. TCP and UDP are
# independent port spaces, so a UDP-only protocol (TUIC) must not be
# refused because TCP is busy, and vice versa.
# Without ss/netstat the answer is unknown, so it returns false (fail closed).
port_is_free() {
    local port="${1:-}" proto="${2:-tcp}" out='' _probe='' _netid=''
    [[ -n "$port" ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    port="$((10#$port))"
    case "$proto" in
        tcp) _netid='^tcp' ;;
        udp) _netid='^udp' ;;
        both) _netid='^(tcp|udp)' ;;
        *) return 1 ;;
    esac
    if command -v ss >/dev/null 2>&1; then
        # A failed ss probe is "unknown", never "free" (fail closed).
        out=$(ss -tuln 2>/dev/null) || return 1
        # awk reads the whole listing: no grep -q early exit, so no
        # SIGPIPE under pipefail can flip a busy result into "free".
        # M-01: $proto selects which Netid rows count — -tuln lists
        # both TCP and UDP, and the two port spaces are independent.
        # (Do NOT switch to
        # -tln: ss drops the Netid column there, moving Local from
        # $5 to $4, which would turn real TCP listeners free.)
        _probe=$(printf '%s\n' "$out" | awk -v port="$port" -v pat="$_netid" 'NR>1 && $1 ~ pat && $5 ~ (":" port "$") {found=1} END {print (found ? "busy" : "free")}') || return 1
        [[ "$_probe" == 'free' ]] && return 0
        return 1
    elif command -v netstat >/dev/null 2>&1; then
        out=$(netstat -tuln 2>/dev/null) || return 1
        _probe=$(printf '%s\n' "$out" | awk -v port="$port" -v pat="$_netid" 'NR>2 && $1 ~ pat && $4 ~ (":" port "$") {found=1} END {print (found ? "busy" : "free")}') || return 1
        [[ "$_probe" == 'free' ]] && return 0
        return 1
    else
        # R6C5-01: no reliable listener listing tool. The old
        # /dev/tcp loopback probe missed non-loopback binds and
        # misreported them as free (a later 0.0.0.0 bind then
        # collided with EADDRINUSE). Unknown is never free.
        return 1
    fi
}

# is_test: single dispatcher for all input validation types (233boy pattern).
#   port   -> 1-65535 and not occupied
#   domain -> valid_domain regex
#   uuid   -> UUIDv4 shape
#   ip     -> plain IPv4 or IPv6 address (no CIDR)
#   path   -> /-prefixed, no whitespace/control chars
#   cidr   -> IPv4 or IPv6 with optional /mask
is_test() {
    local type="${1:-}" value="${2:-}" proto="${3:-tcp}"
    case "$type" in
        port)   valid_port "$value" && port_is_free "$value" "$proto" ;;
        domain) valid_domain "$value" ;;
        uuid)   valid_uuid "$value" ;;
        ip)     valid_ip_address "$value" ;;
        path)   valid_path "$value" ;;
        cidr)   valid_ipv4_cidr "$value" || valid_ipv6_cidr "$value" ;;
        *)      return 1 ;;
    esac
}

# R3-NEW-02: system/management reserved ports, shared by every port
# prompt so the table cannot drift between the main deployer and the
# independent deployers again (22 SSH, 53 DNS, 68 DHCP client, 80 HTTP,
# 123 NTP, 161 SNMP, 323 chrony, 10085 Xray API). A reserved port is
# refused even when nothing listens on it: the slot belongs to the
# system/management plane, not to the next deployer that asks.
is_reserved_port() {
    local port="${1:-}"
    valid_port "$port" || return 1
    case "$((10#$port))" in
        22|53|68|80|123|161|323|10085) return 0 ;;
        *) return 1 ;;
    esac
}

# prompt_validated: read from stdin, apply default on empty, re-prompt until
# is_test passes. Prints the accepted value to stdout.
prompt_validated() {
    local prompt="$1" type="$2" default="${3:-}" proto="${4:-tcp}"
    local val
    while true; do
        if ! read -r -p "$prompt" val; then
            val="$default"
            if [[ "$type" == 'port' ]] && is_reserved_port "$val"; then
                msg "${RED}$(tprintf pt_reserved "$((10#$val))")${NC}" >&2
                return 1
            fi
            if is_test "$type" "$val" "$proto"; then
                printf '%s' "$val"
                return 0
            fi
            msg "${RED}$(tprintf pv_eof "$type")${NC}" >&2
            return 1
        fi
        val="${val:-$default}"
        val=$(normalize_fa_ar_digits "$val")
        # M-25: normalize a leading-zero port here, at the entry point,
        # so every downstream consumer (incl. the eight independent
        # deployers' `jq --argjson port`) sees the canonical spelling.
        # valid_port already accepts 0443/01080; only the spelling
        # changes, never the value. (jq --argjson itself accepts
        # leading zeros -- this is canonicalization, not a crash fix.)
        if [[ "$type" == 'port' ]] && valid_port "$val"; then
            val="$((10#$val))"
            if is_reserved_port "$val"; then
                msg "${RED}$(tprintf pt_reserved "$val")${NC}" >&2
                continue
            fi
        fi
        if is_test "$type" "$val" "$proto"; then
            printf '%s' "$val"
            return 0
        fi
        if [[ "$type" == 'port' ]] && valid_port "$val"; then
            msg "${RED}$(tprintf pv_port_busy "$val")${NC}" >&2
        else
            msg "${RED}$(tprintf pv_invalid "$type" "$val")${NC}" >&2
        fi
    done
}
# ============ end Version C ============

is_apple_like_sni() {
    local sni="${1,,}"
    [[ "$sni" == 'apple.com' || "$sni" == *.apple.com || "$sni" == 'icloud.com' || "$sni" == *.icloud.com ]]
}

default_sni_for_port() {
    local selected="${ABOX_AUTO_SNI_SELECTED:-}"
    if valid_sni "$selected"; then
        printf '%s\n' "$selected"
    else
        # An unverified fallback is not a default; interactive setup must ask.
        printf '\n'
    fi
}

# F-NEW-03: DNS resolvability gate for a typed SNI. rc 0 = the domain
# resolves, rc 1 = it positively does not resolve, rc 2 = resolution
# cannot be tested on this host (no getent/python3). A resolving answer
# is necessary, not sufficient: TLS/SAN tiering still applies afterwards.
# getent is preferred; python3 (already a hard dependency) is the fallback
# for hosts without it (e.g. musl-based systems).
sni_dns_resolvable() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || return 1
    valid_domain "$domain" || return 1
    if command -v getent >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            if timeout 10 getent ahosts "$domain" >/dev/null 2>&1; then return 0; else return 1; fi
        fi
        if getent ahosts "$domain" >/dev/null 2>&1; then return 0; else return 1; fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        if python3 -I -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], 443, 0, socket.SOCK_STREAM)' "$domain" >/dev/null 2>&1; then return 0; else return 1; fi
    fi
    return 2
}

sni_probe_candidate_tier() {
    local domain="${1:-}" workdir='' raw='' raw_sorted='' verified='' timeout_s=2
    local score actual_domain app ttfb total_time http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty tier
    [[ -n "$domain" ]] || { printf 'N\n'; return 0; }
    command -v curl >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || { printf 'N\n'; return 0; }
    workdir=$(mktemp -d /tmp/A-Box-sni-custom.XXXXXX) || { printf 'N\n'; return 0; }
    chmod 700 "$workdir" 2>/dev/null || { rm -rf -- "$workdir"; printf 'N\n'; return 0; }
    raw="$workdir/raw.tsv"
    raw_sorted="$workdir/raw.sorted.tsv"
    verified="$workdir/verified.tsv"
    : > "$raw"
    ABOX_CURL_TLS13_SUPPORTED=0
    ABOX_CURL_HTTP2_SUPPORTED=0
    { curl --help all 2>/dev/null || curl --help 2>/dev/null; } | grep -F -- '--tlsv1.3' >/dev/null && ABOX_CURL_TLS13_SUPPORTED=1
    curl --version 2>/dev/null | grep -qw 'HTTP2' && ABOX_CURL_HTTP2_SUPPORTED=1
    sni_probe_domain "$domain" "$raw" "$timeout_s" >&2 || true
    if [[ ! -s "$raw" ]]; then
        rm -rf -- "$workdir"
        printf 'D\n'
        return 0
    fi
    if ! LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$raw" > "$raw_sorted"; then
        rm -rf -- "$workdir"
        printf 'N\n'
        return 0
    fi
    if ! sni_verify_raw_report "$raw_sorted" "$verified" 1 3 >&2 || [[ ! -s "$verified" ]]; then
        rm -rf -- "$workdir"
        printf 'N\n'
        return 0
    fi
    IFS=$'\t' read -r score actual_domain app ttfb total_time http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty < "$verified" || {
        rm -rf -- "$workdir"
        printf 'N\n'
        return 0
    }
    tier=$(sni_report_fit_tier "$tls13" "$alpn" "$san" "$asnmatch" "$samecountry" "$cdnpenalty")
    rm -rf -- "$workdir"
    printf '%s\n' "$tier"
}

sni_verified_amazon_fallback() {
    local fallback='www.amazon.com' tier=''
    tier=$(sni_probe_candidate_tier "$fallback" 2>/dev/null) || tier='N'
    case "$tier" in
        A|B|C)
            printf '[SNI auto] Amazon fallback passed TLS 1.3, h2, and certificate SAN checks.\n' >&2
            printf '%s\n' "$fallback"
            ;;
        R)
            printf '[SNI auto] Amazon fallback passed TLS 1.3, h2, and certificate SAN checks, but its CDN/shared-edge risk is elevated; using it only as a fallback.\n' >&2
            printf '%s\n' "$fallback"
            ;;
        *)
            printf '[SNI auto] Amazon fallback failed or could not complete TLS 1.3/h2/SAN verification; no automatic SNI will be selected.\n' >&2
            return 1
            ;;
    esac
}

prompt_reality_sni() {
    local label="$1" port="$2" default_sni input answer prompt warned custom_tier dns_rc
    default_sni=$(default_sni_for_port "$port")
    while true; do
        prompt=$(tprintf reality_sni_prompt "$label" "$port" "$default_sni")
        read -r -p "$prompt" input || return 1
        input=${input:-$default_sni}
        if ! valid_sni "$input"; then
            printf '%s\n' "${RED}[!] $(tprintf bad_sni "$input")$NC" >&2
            continue
        fi
        warned=0
        if [[ "$port" != '443' ]]; then
            printf '%s\n' "$YELLOW$(tprintf reality_non443_warn "$port")$NC" >&2
            warned=1
        fi
        if is_apple_like_sni "$input"; then
            printf '%s\n' "$YELLOW$(tprintf apple_sni_warn "$input")$NC" >&2
            warned=1
        fi
        if [[ "$input" != "$default_sni" ]]; then
            # F-NEW-03: a custom SNI that does not resolve can never pass
            # a Reality handshake (the server cannot dial its target), so
            # it is refused outright instead of warned-and-confirmed.
            # An untestable resolver falls through to tiering below.
            sni_dns_resolvable "$input"; dns_rc=$?
            if (( dns_rc == 1 )); then
                printf '%s\n' "${RED}[SNI custom] $(tprintf sni_unresolvable "$input")$NC" >&2
                continue
            fi
            custom_tier=$(sni_probe_candidate_tier "$input" 2>/dev/null || printf 'N')
            case "$custom_tier" in
                A|B|C)
                    printf '%s\n' "${GREEN}[SNI custom] $(tprintf sni_ok_tier "$custom_tier")$NC" >&2
                    ;;
                R)
                    printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_risky)$NC" >&2
                    warned=1
                    ;;
                D)
                    printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_fail)$NC" >&2
                    warned=1
                    ;;
                *)
                    printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_untestable)$NC" >&2
                    warned=1
                    ;;
            esac
        fi
        if [[ "$warned" == 1 ]]; then
            prompt=$(tprintf continue_or_reset "$label")
            read -r -p "$prompt" answer || return 1
            is_yes "$answer" && { printf '%s\n' "$input"; return 0; }
            continue
        fi
        printf '%s\n' "$input"
        return 0
    done
}

valid_url_https() {
    local url="${1:-}" rest host port
    [[ "$url" == https://* ]] || return 1
    [[ "$url" =~ [\"\`\$\\] ]] && return 1
    [[ "$url" =~ [[:space:]] ]] && return 1
    rest="${url#https://}"
    host="${rest%%/*}"
    host="${host%%\?*}"
    host="${host%%#*}"
    [[ -n "$host" ]] || return 1
    if [[ "$host" == *:* ]]; then
        # This parser intentionally accepts DNS host[:port] only. Reject
        # multiple/empty colons instead of truncating them into a different
        # hostname+port pair (for example example.com:443:444).
        [[ "$host" =~ ^([^:]+):([0-9]+)$ ]] || return 1
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        valid_port "$port" || return 1
    fi
    valid_domain "$host" || return 1
}

normalize_https_url_input() {
    local input="${1:-}" rest auth tail
    input="$(printf '%s' "$input" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$input" ]] || return 1
    if [[ "$input" != http://* && "$input" != https://* ]]; then
        input="https://${input}"
    fi
    if [[ "$input" == https://* ]]; then
        rest="${input#https://}"
        auth="${rest%%/*}"
        auth="${auth%%\?*}"
        auth="${auth%%#*}"
        if [[ "$rest" == "$auth" ]]; then
            input="${input}/"
        elif [[ -n "$auth" ]]; then
            tail="${rest:${#auth}}"
            case "$tail" in
                /*) ;;
                *) input="https://${auth}/${tail}" ;;
            esac
        fi
    fi
    printf '%s\n' "$input"
}

prompt_https_url() {
    local prompt="$1" default_url="$2" input normalized
    while true; do
        read -r -p "$prompt" input || return 1
        input="${input:-$default_url}"
        normalized="$(normalize_https_url_input "$input" 2>/dev/null || true)"
        if [[ -n "$normalized" ]] && valid_url_https "$normalized"; then
            printf '%s\n' "$normalized"
            return 0
        fi
        printf '%s\n' "${RED}[!] $(tprintf hy2_url_bad "$input")${NC}" >&2
        printf '%s\n' "${YELLOW}    $(tr_msg hy2_url_example)${NC}" >&2
    done
}

prompt_port_input() {
    local label="$1" default_port="$2" input prompt
    while true; do
        prompt=$(tprintf port_prompt "$label" "$default_port")
        read -r -p "$prompt" input || return 1
        input="${input:-$default_port}"
        input=$(normalize_fa_ar_digits "$input")
        if valid_port "$input"; then
            if is_reserved_port "$input"; then
                printf '%s\n' "${RED}[!] $(tprintf pt_reserved "$((10#$input))")${NC}" >&2; continue
            fi
            printf '%s\n' "$((10#$input))"
            return 0
        fi
        printf '%s\n' "${RED}[!] $(tprintf bad_port "$input")${NC}" >&2
    done
}

prompt_ss_port_input() {
    local label="$1" default_port="$2" input prompt
    while true; do
        prompt=$(tprintf ss_port_prompt "$label" "$default_port")
        read -r -p "$prompt" input || return 1
        input="${input:-$default_port}"
        input=$(normalize_fa_ar_digits "$input")
        if valid_port "$input"; then
            if is_reserved_port "$input"; then
                printf '%s\n' "${RED}[!] $(tprintf pt_reserved "$((10#$input))")${NC}" >&2; continue
            fi
            printf '%s\n' "$((10#$input))"
            return 0
        fi
        printf '%s\n' "${RED}[!] $(tprintf bad_port "$input")${NC}" >&2
    done
}

prompt_hy2_bandwidth_mbps_input() {
    local prompt="$1" default_value="$2" input
    while true; do
        read -r -p "$prompt" input || return 1
        input="${input:-$default_value}"
        input=$(normalize_fa_ar_digits "$input")
        if valid_hy2_bandwidth_mbps "$input"; then
            printf '%s\n' "$input"
            return 0
        fi
        printf '%s\n' "${RED}[!] $(tprintf hy2_bw_bad "$input")${NC}" >&2
    done
}
normalize_ip_literal() {
    # Canonicalize an IP literal for comparison (expanded vs compressed
    # IPv6, etc.). Falls back to the input unchanged when python3 is
    # missing or the input is not a valid literal, so callers degrade
    # to literal comparison instead of failing.
    local input="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$input" 2>/dev/null <<'PY' || printf '%s\n' "$input"
import ipaddress, sys
try:
    print(ipaddress.ip_address(sys.argv[1]).compressed)
except Exception:
    print(sys.argv[1])
PY
    else
        printf '%s\n' "$input"
    fi
}

valid_ipv4_cidr() {
    local input="${1:-}" addr mask n
    addr="${input%/*}"
    mask=''
    if [[ "$input" == */* ]]; then
        mask="${input#*/}"
        [[ -n "$mask" ]] || return 1
    fi
    if [[ -n "$mask" ]]; then
        valid_decimal_upto "$mask" 32 || return 1
    fi
    [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    local -a octets
    read -r -a octets <<< "$addr"
    for n in "${octets[@]}"; do
        valid_decimal_upto "$n" 255 || return 1
        # Keep IPv4 text canonical enough for downstream parsers such as Go's
        # net.ParseIP/net.ParseCIDR, which reject octets with leading zeroes.
        [[ "$n" == "0" || "$n" != 0* ]] || return 1
    done
}

valid_ipv6_cidr() {
    local input="${1:-}" addr mask
    addr="${input%/*}"
    mask=''
    if [[ "$input" == */* ]]; then
        mask="${input#*/}"
        [[ -n "$mask" ]] || return 1
    fi
    if [[ -n "$mask" ]]; then
        valid_decimal_upto "$mask" 128 || return 1
    fi
    [[ "$addr" == *:* ]] || return 1
    [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$addr" != *':::'* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$input" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_network(sys.argv[1], strict=False)
PY
        return $?
    fi
    return 1
}

valid_ip_address() {
    local input="${1:-}"
    [[ "$input" != */* && -n "$input" ]] || return 1
    valid_ipv4_cidr "$input" || valid_ipv6_cidr "$input"
}

valid_interface_name() {
    local iface="${1:-}"
    # Linux IFNAMSIZ is 16 bytes including the terminating NUL; the usable
    # interface-name limit is therefore 15 characters.
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ && ${#iface} -le 15 ]]
}

# M-08(3): single-quote a value for a shell/crontab command line.
# Single quotes defeat $/backtick/command substitution entirely; an
# embedded ' is closed, escaped, and reopened ('\'').
shell_single_quote() {
    local v=${1:-}
    printf "'%s'" "${v//\'/\'\\\'\'}"
}
# M-08(3) quoter split: .env values are read by Python shlex
# (load_abox_env), NOT by bash. Inside double quotes shlex only
# unescapes backslash-quote and backslash-backslash; a backslash
# before $, backtick, ! or n survives, so the bash double-quote style
# corrupts those values on load (see fixture
# fx-quoter-roundtrip.sh). env_quote therefore uses the shlex-correct
# single-quote form: everything inside single quotes is literal to
# shlex, and an embedded single quote is spliced as '\'' (same
# algorithm as shell_single_quote, kept as a separate function because
# the two have different readers: shlex vs bash). NEVER use a
# double-quote quoter for .env values; bash-evaluated contexts
# (cron command lines) use shell_single_quote.
env_quote() {
    local v=${1:-}
    printf "'%s'" "${v//\'/\'\\\'\'}"
}
json_escape() { jq -n --rawfile v <(printf '%s' "${1:-}") '$v'; }

clear_abox_env_vars() {
    unset CORE MODE UUID VLESS_SNI VISION_SNI XHTTP_SNI VLESS_PORT XHTTP_PORT HY2_BASE_PORT HY2_DOMAIN HY2_UP HY2_DOWN HY2_MASQ_URL
    unset SS_PORT SS_WHITELIST_IP PUBLIC_KEY PBK SHORT_ID HY2_PASS HY2_OBFS SS_PASS LINK_IP HY2_CERT_SHA256_FP HY2_CERT_PUBKEY_SHA256_B64
    unset HY2_HOP HY2_HOP_IMPL HY2_MONITOR_PORT HY2_ACME_TYPE HY2_ACME_DNS_PROVIDER HY2_ACME_DNS_CF_API_TOKEN
    unset HY2_URI_PORTS HY2_CLASH_PORTS HY2_SB_PORTS HY2_RANGE_START HY2_RANGE_END INGRESS_IF ENABLE_KEEPALIVE
    unset TRAFFIC_LIMIT_GB TRAFFIC_LIMIT_MODE
    unset SOCKS_PORT SOCKS_USER SOCKS_PASS SOCKS_PROTO TROJAN_PORT
}

validate_abox_env_semantics() {
    local p value
    # Pre-deployment state (e.g. traffic limit set before any protocol is
    # deployed) has neither CORE nor MODE; accept it. A half-present pair
    # (one set, one empty/mismatched) is still rejected as corrupt.
    if [[ -n "${CORE:-}${MODE:-}" ]]; then
        [[ "${CORE:-}" =~ ^(xray|singbox|hysteria)$ ]] || return 1
        [[ "${MODE:-}" =~ ^(VISION|XHTTP|SS|ALL|VLESS_SS|HY2|SOCKS)$ ]] || return 1
        case "${CORE}:${MODE}" in
            xray:VISION|xray:XHTTP|xray:SS|xray:ALL|xray:VLESS_SS|xray:SOCKS|singbox:VISION|singbox:SS|singbox:VLESS_SS|singbox:HY2|singbox:ALL|singbox:SOCKS|hysteria:HY2) ;;
            *) return 1 ;;
        esac
    fi
    for p in VLESS_PORT XHTTP_PORT HY2_BASE_PORT SS_PORT HY2_MONITOR_PORT HY2_RANGE_START HY2_RANGE_END SOCKS_PORT TROJAN_PORT; do
        value=${!p:-}
        [[ -z "$value" ]] || valid_canonical_port "$value" || return 1
    done
    if [[ -n "${HY2_RANGE_START:-}${HY2_RANGE_END:-}" ]]; then
        valid_canonical_port "${HY2_RANGE_START:-}" && valid_canonical_port "${HY2_RANGE_END:-}" || return 1
        (( 10#$HY2_RANGE_START <= 10#$HY2_RANGE_END )) || return 1
    fi
    for p in VLESS_SNI VISION_SNI XHTTP_SNI HY2_DOMAIN; do
        value=${!p:-}
        [[ -z "$value" ]] || valid_domain "$value" || return 1
    done
    for p in HY2_UP HY2_DOWN; do
        value=${!p:-}
        [[ -z "$value" ]] || valid_traffic_limit_gb "$value" || return 1
    done
    [[ -z "${HY2_MASQ_URL:-}" ]] || valid_url_https "$HY2_MASQ_URL" || return 1
    [[ -z "${UUID:-}" || "${UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
    # R10C5-01: Reality shortId caps at 8 bytes / 16 hex.
    [[ -z "${SHORT_ID:-}" || "${SHORT_ID:-}" =~ ^[0-9A-Fa-f]{2,16}$ ]] || return 1
    [[ -z "${SHORT_ID:-}" || $(( ${#SHORT_ID} % 2 )) -eq 0 ]] || return 1
    [[ -z "${HY2_CERT_SHA256_FP:-}" || "${HY2_CERT_SHA256_FP:-}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    [[ -z "${LINK_IP:-}" || "${LINK_IP:-}" == N/A ]] || valid_ip_address "$LINK_IP" || return 1
    [[ -z "${HY2_HOP:-}" || "${HY2_HOP:-}" =~ ^(true|false)$ ]] || return 1
    [[ -z "${HY2_HOP_IMPL:-}" || "${HY2_HOP_IMPL:-}" =~ ^(none|manual|official)$ ]] || return 1
    [[ -z "${HY2_ACME_TYPE:-}" || "${HY2_ACME_TYPE:-}" =~ ^(http|dns)$ ]] || return 1
    [[ -z "${ENABLE_KEEPALIVE:-}" || "${ENABLE_KEEPALIVE:-}" =~ ^(true|false)$ ]] || return 1
    [[ -z "${INGRESS_IF:-}" ]] || valid_interface_name "$INGRESS_IF" || return 1
    if [[ -n "${TRAFFIC_LIMIT_GB:-}" ]]; then
        valid_traffic_limit_gb "$TRAFFIC_LIMIT_GB" || return 1
        [[ "${TRAFFIC_LIMIT_MODE:-total}" =~ ^(total|rx|tx)$ ]] || return 1
    else
        [[ -z "${TRAFFIC_LIMIT_MODE:-}" || "${TRAFFIC_LIMIT_MODE:-}" =~ ^(total|rx|tx)$ ]] || return 1
    fi
    if [[ -n "${HY2_URI_PORTS:-}" ]]; then
        valid_hy2_uri_ports "$HY2_URI_PORTS" || return 1
    fi
    if [[ -n "${HY2_CLASH_PORTS:-}" ]]; then
        valid_hy2_clash_ports "$HY2_CLASH_PORTS" || return 1
    fi
    if [[ -n "${HY2_SB_PORTS:-}" ]]; then
        valid_hy2_sb_ports "$HY2_SB_PORTS" || return 1
    fi
    # F-04: validate persisted fields that were previously unchecked on load.
    if [[ -n "${SS_WHITELIST_IP:-}" ]]; then
        local _wl_ip
        local -a _wl_ips=()
        read -r -a _wl_ips <<< "${SS_WHITELIST_IP:-}"
        for _wl_ip in "${_wl_ips[@]}"; do
            valid_ipv4_cidr "$_wl_ip" || valid_ipv6_cidr "$_wl_ip" || return 1
        done
    fi
    [[ -z "${HY2_ACME_DNS_PROVIDER:-}" || "${HY2_ACME_DNS_PROVIDER:-}" == cloudflare ]] || return 1
    [[ -z "${HY2_ACME_DNS_CF_API_TOKEN:-}" ]] || valid_single_line_secret "$HY2_ACME_DNS_CF_API_TOKEN" 512 || return 1
    # P3-1: PUBLIC_KEY (X25519) accepts 43-char RawURLEncoding (Xray/sing-box native, no padding) or 44-char padded base64.
    [[ -z "${PUBLIC_KEY:-}" || "${PUBLIC_KEY:-}" =~ ^[A-Za-z0-9+/_-]{43}=?$ ]] || return 1
    # P3-3: HY2_CERT_PUBKEY_SHA256_B64 validated here on load, not only at use-site.
    [[ -z "${HY2_CERT_PUBKEY_SHA256_B64:-}" || "${HY2_CERT_PUBKEY_SHA256_B64:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    # P3-2: passwords must be single-line secrets (prevents JSON injection via .env).
    [[ -z "${HY2_PASS:-}" ]] || valid_single_line_secret "$HY2_PASS" 512 || return 1
    [[ -z "${HY2_OBFS:-}" ]] || valid_single_line_secret "$HY2_OBFS" 512 || return 1
    [[ -z "${SS_PASS:-}" ]] || valid_single_line_secret "$SS_PASS" 512 || return 1
    # SOCKS5: validate port/user/pass/proto when enabled.
    # S2-NEW-02: both-empty credentials are the anonymous SOCKS5 state
    # (sing-box treats an empty users list as no-auth, so a preserved
    # anonymous inbound is a legal live state, not corruption). One-sided
    # credentials are still rejected as corrupt; non-empty pairs keep the
    # single-line secret checks below.
    if [[ -n "${SOCKS_PORT:-}" ]]; then
        valid_canonical_port "$SOCKS_PORT" || return 1
        if [[ -n "${SOCKS_USER:-}" || -n "${SOCKS_PASS:-}" ]]; then
            [[ -n "${SOCKS_USER:-}" ]] || return 1
            valid_single_line_secret "$SOCKS_USER" 64 || return 1
            [[ -n "${SOCKS_PASS:-}" ]] || return 1
            valid_single_line_secret "$SOCKS_PASS" 128 || return 1
        fi
        [[ "${SOCKS_PROTO:-socks}" =~ ^(socks|mixed)$ ]] || return 1
        [[ "$SOCKS_PORT" != "${VLESS_PORT:-}" && "$SOCKS_PORT" != "${SS_PORT:-}" && "$SOCKS_PORT" != "${HY2_BASE_PORT:-}" && "$SOCKS_PORT" != "10085" ]] || return 1
    fi
    if [[ "${MODE:-}" == "SOCKS" && -z "${SOCKS_PORT:-}" ]]; then
        return 1
    fi
}

load_abox_env() {
    local file="${1:-$ABOX_ENV}" parsed key value uid gid mode i
    local -a staged_keys=() staged_values=()
    clear_abox_env_vars
    [[ -r "$file" && -f "$file" && ! -L "$file" ]] || return 1
    uid=$(stat -c %u "$file" 2>/dev/null) || return 1
    gid=$(stat -c %g "$file" 2>/dev/null) || return 1
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
    [[ "$uid" == '0' && "$gid" == '0' && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    parsed=$(umask 077; mktemp /tmp/A-Box-env.XXXXXX) || return 1
    if ! python3 -I - "$file" > "$parsed" <<'PY_ABOX_ENV'; then
import os
import shlex
import sys

if os.path.getsize(sys.argv[1]) > 65536:
    raise SystemExit("state file too large")

allowed = {
    "CORE", "MODE", "UUID", "VLESS_SNI", "VISION_SNI", "XHTTP_SNI",
    "VLESS_PORT", "XHTTP_PORT", "HY2_BASE_PORT", "HY2_DOMAIN", "HY2_UP",
    "HY2_DOWN", "HY2_MASQ_URL", "SS_PORT", "PUBLIC_KEY", "SHORT_ID",
    "HY2_PASS", "HY2_OBFS", "SS_PASS", "LINK_IP", "HY2_CERT_SHA256_FP",
    "HY2_CERT_PUBKEY_SHA256_B64", "HY2_HOP", "HY2_HOP_IMPL",
    "HY2_MONITOR_PORT", "HY2_ACME_TYPE", "HY2_ACME_DNS_PROVIDER",
    "HY2_ACME_DNS_CF_API_TOKEN", "HY2_URI_PORTS", "HY2_CLASH_PORTS",
    "HY2_SB_PORTS", "HY2_RANGE_START", "HY2_RANGE_END", "INGRESS_IF",
    "ENABLE_KEEPALIVE", "TRAFFIC_LIMIT_GB", "TRAFFIC_LIMIT_MODE",
    "SS_WHITELIST_IP", "SOCKS_PORT", "SOCKS_USER", "SOCKS_PASS", "SOCKS_PROTO",
    "TROJAN_PORT",
}
seen = set()
with open(sys.argv[1], "r", encoding="utf-8", errors="strict") as handle:
    for number, raw_line in enumerate(handle, 1):
        if len(raw_line) > 8192:
            raise SystemExit(f"state line too long at line {number}")
        line = raw_line.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"invalid state line {number}")
        key, raw_value = line.split("=", 1)
        if key not in allowed or key in seen:
            raise SystemExit(f"invalid or duplicate state key at line {number}")
        if not raw_value.strip():
            value = ""
        else:
            parts = shlex.split(raw_value, posix=True)
            if len(parts) != 1:
                raise SystemExit(f"invalid state value at line {number}")
            value = parts[0]
        if len(value.encode("utf-8")) > 4096:
            raise SystemExit(f"state value too long at line {number}")
        if "\x00" in value or "\n" in value or "\r" in value:
            raise SystemExit(f"invalid control character at line {number}")
        seen.add(key)
        sys.stdout.buffer.write(key.encode("ascii") + b"\0" + value.encode("utf-8") + b"\0")
PY_ABOX_ENV
        rm -f "$parsed"
        clear_abox_env_vars
        return 1
    fi
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
        staged_keys+=("$key")
        staged_values+=("$value")
    done < "$parsed"
    rm -f "$parsed"
    clear_abox_env_vars
    for ((i=0; i<${#staged_keys[@]}; i++)); do
        printf -v "${staged_keys[i]}" '%s' "${staged_values[i]}"
    done
    if ! validate_abox_env_semantics; then
        clear_abox_env_vars
        return 1
    fi
}


load_optional_abox_env_or_die() {
    # A missing .env is valid during first-time setup. An existing but invalid,
    # unsafe, or unreadable .env must never be treated as an empty installation.
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        load_abox_env "$ABOX_ENV" 2>/dev/null || die "$(tr_msg env_bad)"
    else
        clear_abox_env_vars
    fi
}

rand_alnum() {
    local len="$1" out='' chunk attempt target max_attempts
    valid_positive_int "$len" && (( 10#$len <= 4096 )) || { printf '%s\n' "$(tr_msg rnd_len)" >&2; return 1; }
    target=$((10#$len))
    # The previous fixed 16 rounds could never produce 4096 alphanumeric chars.
    max_attempts=$(( (target + 255) / 256 + 16 ))
    for ((attempt=0; attempt<max_attempts && ${#out}<target; attempt++)); do
        chunk=$(openssl rand -base64 256 2>/dev/null | tr -dc 'a-zA-Z0-9') || chunk=''
        [[ -n "$chunk" ]] && out+="$chunk"
    done
    (( ${#out} >= target )) || { printf '%s\n' "$(tr_msg rnd_src)" >&2; return 1; }
    printf '%s\n' "${out:0:target}"
}

generate_robust_uuid() {
    local candidate u variant
    if command -v uuidgen >/dev/null 2>&1; then
        candidate=$(uuidgen 2>/dev/null || true)
        if [[ "$candidate" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        candidate=$(tr -d '\n\r' < /proc/sys/kernel/random/uuid 2>/dev/null || true)
        if [[ "$candidate" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    {
        local u variant
        u=$(openssl rand -hex 16 2>/dev/null) || u=''
        [[ ${#u} -eq 32 ]] || { printf '%s\n' "$(tr_msg rnd_uuid)" >&2; return 1; }
        case "${u:16:1}" in
            0|1|2|3) variant=8 ;;
            4|5|6|7) variant=9 ;;
            8|9|a|b) variant=a ;;
            *) variant=b ;;
        esac
        printf '%s-%s-4%s-%s%s-%s\n' "${u:0:8}" "${u:8:4}" "${u:13:3}" "$variant" "${u:17:3}" "${u:20:12}"
    }
}

pin_sha256_colon() {
    openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2
}

valid_public_ip() {
    local ip="${1:-}"
    valid_ip_address "$ip" || return 1
    python3 -I - "$ip" <<'PY_PUBLIC_IP'
import ipaddress, sys
try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if (addr.is_multicast or addr.is_reserved or addr.is_loopback or
    addr.is_link_local or addr.is_unspecified or addr.is_private):
    raise SystemExit(1)
if addr.version == 6 and addr.ipv4_mapped is not None:
    raise SystemExit(1)
if addr.version == 4:
    blocked = (
        ipaddress.ip_network('0.0.0.0/8'),
        ipaddress.ip_network('192.0.0.0/24'),
        ipaddress.ip_network('192.88.99.0/24'),
        ipaddress.ip_network('198.18.0.0/15'),
        ipaddress.ip_network('198.51.100.0/24'),
        ipaddress.ip_network('203.0.113.0/24'),
        ipaddress.ip_network('240.0.0.0/4'),
    )
else:
    blocked = (
        ipaddress.ip_network('2001:db8::/32'),
        ipaddress.ip_network('2001:2::/48'),
        ipaddress.ip_network('2001:20::/28'),
        ipaddress.ip_network('64:ff9b::/96'),
    )
if any(addr in network for network in blocked):
    raise SystemExit(1)
if not addr.is_global:
    raise SystemExit(1)
raise SystemExit(0)
PY_PUBLIC_IP
}

# BUG-28: hoisted from get_public_ip_fresh().
# $1 (optional): deadline epoch seconds for the whole fresh-probe round;
# each attempt is capped at min(PUBLIC_IP_MAX_TIME, remaining budget) and
# the round stops when the budget is spent. Empty $1 keeps the old
# per-endpoint-only behaviour (standalone callers).
__abox_try_v4() {
    local api ip _now _remain _mt
    for api in 'https://api.ipify.org' 'https://ifconfig.me/ip' 'https://icanhazip.com'; do
        _mt="$PUBLIC_IP_MAX_TIME"
        if [[ -n "${1:-}" ]]; then
            _now=$(date +%s 2>/dev/null || printf '0')
            _remain=$(( $1 - _now ))
            (( _remain > 0 )) || return 1
            (( _remain < _mt )) && _mt="$_remain"
            (( _mt >= 1 )) || _mt=1
        fi
        ip=$(curl -fsS4 --noproxy '*' --connect-timeout "$PUBLIC_IP_CONNECT_TIMEOUT" -m "$_mt" "$api" 2>/dev/null | tr -d '[:space:]')
        if valid_public_ip "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}
# BUG-28: hoisted from get_public_ip_fresh().
# $1 (optional): deadline epoch seconds; see __abox_try_v4.
__abox_try_v6() {
    local api ip _now _remain _mt
    for api in 'https://api64.ipify.org' 'https://ifconfig.me/ip' 'https://icanhazip.com'; do
        _mt="$PUBLIC_IP_MAX_TIME"
        if [[ -n "${1:-}" ]]; then
            _now=$(date +%s 2>/dev/null || printf '0')
            _remain=$(( $1 - _now ))
            (( _remain > 0 )) || return 1
            (( _remain < _mt )) && _mt="$_remain"
            (( _mt >= 1 )) || _mt=1
        fi
        ip=$(curl -fsS6 --noproxy '*' --connect-timeout "$PUBLIC_IP_CONNECT_TIMEOUT" -m "$_mt" "$api" 2>/dev/null | tr -d '[:space:]')
        if valid_public_ip "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}
get_public_ip_fresh() {
    local ip api pref _ip_deadline='' _ip_budget=12
    [[ "${PUBLIC_IP_TOTAL_BUDGET:-12}" =~ ^[0-9]+$ ]] && _ip_budget="$PUBLIC_IP_TOTAL_BUDGET"
    _ip_deadline=$(( $(date +%s 2>/dev/null || printf '0') + _ip_budget ))
    pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    case "$pref" in
        ipv4)
            __abox_try_v4 "$_ip_deadline" && return 0
            ;;
        ipv6)
            __abox_try_v6 "$_ip_deadline" && return 0
            ;;
        *)
            __abox_try_v4 "$_ip_deadline" && return 0
            __abox_try_v6 "$_ip_deadline" && return 0
            ;;
    esac
    printf 'N/A\n'
    return 1
}

cache_public_ip() {
    local ip="$1"
    [[ -n "$ip" && "$ip" != 'N/A' ]] || return 0
    ensure_abox_dir_owned "$ABOX_DIR"
    write_file_atomically_from_stdin "$PUBLIC_IP_CACHE" 600 <<< "$ip" || return 1
}

read_cached_public_ip() {
    local ip now mtime age pref='' _ip2=''
    [[ -r "$PUBLIC_IP_CACHE" && -f "$PUBLIC_IP_CACHE" && ! -L "$PUBLIC_IP_CACHE" ]] || return 1
    [[ "$(stat -c %u:%g "$PUBLIC_IP_CACHE" 2>/dev/null || true)" == 0:0 ]] || return 1
    # R14-F04-01: the owner gate alone is not enough: a root-owned
    # but group/other-writable cache (e.g. 0666) can be rewritten
    # by a non-root user, so the mode must be exactly 0600 (what
    # the writer creates) or the entry is refused.
    [[ "$(stat -c %a "$PUBLIC_IP_CACHE" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
    ip=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
    if ! valid_public_ip "$ip"; then
        return 1
    fi
    # A cache entry written before an IP-preference switch must not
    # be served when its address family no longer matches the
    # configured preference.
    pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    case "$pref" in
        ipv4) [[ "$ip" != *:* ]] || return 1 ;;
        ipv6) [[ "$ip" == *:* ]] || return 1 ;;
    esac
    now=$(date +%s)
    mtime=$(stat -c %Y "$PUBLIC_IP_CACHE" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    (( age >= 0 && age <= PUBLIC_IP_CACHE_TTL )) || return 1
    # R13-01: the content above and this mtime were read by separate
    # path lookups; an atomic-rename refresh landing between them
    # pairs stale bytes with a fresh mtime. Re-read the content and
    # serve only if the bytes are unchanged -- a replaced file with
    # different bytes is always caught, identical bytes are always
    # safe to serve.
    _ip2=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
    [[ "$_ip2" == "$ip" ]] || return 1
    printf '%s\n' "$ip"
}

get_public_ip() {
    local ip stale age now mtime
    ip=$(read_cached_public_ip 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
    fi
    ip=$(get_public_ip_fresh || true)
    if [[ -n "$ip" && "$ip" != 'N/A' ]]; then
        cache_public_ip "$ip"
        printf '%s\n' "$ip"
        return 0
    fi
    # Never silently use an expired address for generated client links.  A
    # stale address can route users to an unrelated host after VPS renumbering.
    if [[ -r "$PUBLIC_IP_CACHE" && -f "$PUBLIC_IP_CACHE" && ! -L "$PUBLIC_IP_CACHE" ]]; then
        stale=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
        if valid_public_ip "$stale"; then
            now=$(date +%s)
            mtime=$(stat -c %Y "$PUBLIC_IP_CACHE" 2>/dev/null || echo 0)
            age=$(( now - mtime ))
            printf '[!] Cached public IP is stale (%ss old); refusing to use it.\n' "$age" >&2
        fi
    fi
    printf 'N/A\n'
    return 1
}

# Background refresh of the public-IP cache (best effort, detached).
refresh_public_ip_bg() {
    # M-33: 9>&- 10>&- closes the menu lock FDs in the detached
    # child; without it the child holds the lock after the menu
    # exits and the next menu run blocks on flock.
    ( refresh_public_ip >/dev/null 2>&1 || true ) 9>&- 10>&- >/dev/null 2>&1 &
}

# Startup/menu path: stale-while-revalidate. A fresh cache (strict TTL)
# is used as-is; a stale-but-recent (<=24h) cache is served immediately
# and refreshed in the background, so entering the menu never blocks on
# the serial IP-echo endpoints. Only a missing/unusable cache pays the
# synchronous fetch. Link generation keeps the strict code paths.
get_public_ip_swr() {
    local ip=''
    if ip=$(read_cached_public_ip 2>/dev/null) && [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"; return 0
    fi
    # Same owner + mode gate as read_cached_public_ip: a
    # non-root-owned or non-0600 cache must not be served through
    # the SWR fallback either.
    if [[ -r "$PUBLIC_IP_CACHE" && -f "$PUBLIC_IP_CACHE" && ! -L "$PUBLIC_IP_CACHE" && "$(stat -c %u:%g "$PUBLIC_IP_CACHE" 2>/dev/null || true)" == 0:0 && "$(stat -c %a "$PUBLIC_IP_CACHE" 2>/dev/null || true)" =~ ^0?600$ ]]; then
        local _ip='' _now=0 _mt=0 _pref='' _fam_ok=1 _ip2=''
        _ip=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
        if valid_public_ip "$_ip"; then
            # Same family gate as read_cached_public_ip: a cache entry
            # written before a preference switch must not be served
            # when its family no longer matches (it falls through to
            # a fresh fetch below instead).
            _pref=$(read_ip_pref 2>/dev/null || printf 'dual')
            case "$_pref" in
                ipv4) [[ "$_ip" == *:* ]] && _fam_ok=0 ;;
                ipv6) [[ "$_ip" != *:* ]] && _fam_ok=0 ;;
            esac
            _now=$(date +%s); _mt=$(stat -c %Y "$PUBLIC_IP_CACHE" 2>/dev/null || echo 0)
            # R13-01: same snapshot race as read_cached_public_ip --
            # re-read and require identical bytes before serving.
            _ip2=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
            if (( _fam_ok == 1 )) && [[ "$_ip2" == "$_ip" ]] && (( _now - _mt >= 0 && _now - _mt <= 86400 )); then
                refresh_public_ip_bg
                printf '%s\n' "$_ip"; return 0
            fi
        fi
    fi
    get_public_ip
}

refresh_public_ip() {
    local ip
    ip=$(get_public_ip_fresh || true)
    if [[ -n "$ip" && "$ip" != 'N/A' ]]; then
        cache_public_ip "$ip"
        printf '%s\n' "$ip"
        return 0
    fi
    # M-33: do not fall through to get_public_ip here: with a
    # stale or missing cache it re-probes the same endpoints
    # (a second full round offline), and an expired address
    # must never be served for link generation. A still-fresh
    # cache (strict TTL/owner/mode/family gates) is reused as-is.
    ip=$(read_cached_public_ip 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
    fi
    printf 'N/A\n'
    return 1
}
get_active_interface() {
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 !~ /^(lo|vir|wl)/ {sub(/@.*/,"",$2); print $2; exit}')
    printf '%s\n' "$iface"
}

resolve_domain_addresses() {
    local domain="${1:-}" resolved=''
    valid_domain "$domain" || return 1
    # N-05 fix: wrap getent in timeout; a hanging DNS resolver must not
    # block the SNI batch worker forever.
    if command -v getent >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            resolved=$(timeout 5 getent ahosts "$domain" 2>/dev/null | awk 'NF {print $1}' | sort -u) || resolved=''
            if [[ -z "$resolved" ]]; then
                resolved=$(timeout 5 getent hosts "$domain" 2>/dev/null | awk 'NF {print $1}' | sort -u) || resolved=''
            fi
        else
            resolved=$(getent ahosts "$domain" 2>/dev/null | awk 'NF {print $1}' | sort -u) || resolved=''
            if [[ -z "$resolved" ]]; then
                resolved=$(getent hosts "$domain" 2>/dev/null | awk 'NF {print $1}' | sort -u) || resolved=''
            fi
        fi
    fi
    [[ -n "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

verify_domain_points_to_self() {
    local domain="$1" pub_ip="$2" resolved _norm_pub='' _norm_resolved=''
    resolved=$(resolve_domain_addresses "$domain") || die "$(tprintf dom_unresolved "$domain")"
    # Compare normalized forms (expanded vs compressed IPv6 must match).
    _norm_pub=$(normalize_ip_literal "$pub_ip")
    _norm_resolved=$(printf '%s\n' "$resolved" | while IFS= read -r _rl; do normalize_ip_literal "$_rl"; done)
    if [[ "$pub_ip" != 'N/A' ]] && ! grep -Fxq "$_norm_pub" <<< "$_norm_resolved"; then
        msg "${YELLOW}[!] $(tprintf verify_domain_points_to_self_not_pointing_here "$pub_ip")${NC}"
        printf '%s\n\n%s\n' "${YELLOW}$(tr_msg dom_resolved_label)${NC}" "$resolved"
        # R15-F04-03: use confirm_yes_no (R8-F3-1): only a successful
        # read plus an answer of y counts as confirmation. A bare read
        # stores a partial 'y' before EOF and returns non-zero, which
        # the old is_yes check ignored, continuing a deployment the
        # user never confirmed.
        confirm_yes_no "$(tr_msg dom_continue)" || die "$(tr_msg dom_cancelled)"
    fi
}

openrc_cron_service_name() {
    case "$1" in
        debian|ubuntu) printf '%s\n' cron ;;
        alpine)
            # Prefer an installed alternate cron OpenRC unit. BusyBox ships
            # /etc/init.d/crond by default; apk add cronie/dcron adds a different
            # unit name and must not leave the BusyBox unit as the only target.
            if [[ -x /etc/init.d/cronie ]]; then
                printf '%s\n' cronie
            elif [[ -x /etc/init.d/dcron ]]; then
                printf '%s\n' dcron
            else
                printf '%s\n' crond
            fi
            ;;
        *) printf '%s\n' crond ;;
    esac
}

# BUG-28: hoisted from init_system_environment().
__abox_reconcile_systemd_unit() {
    local unit="$1"
    local _list=''
    # R14-F04-02: never conflate "query failed" with "unit
    # absent": a named-pattern list-unit-files exits non-zero
    # for a missing unit too, so the old pipeline (pipefail)
    # returned 0 for both. List all units instead: a failed
    # listing dies, a successful listing without the unit is
    # the only "absent" path.
    _list=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null) || die "$(tprintf sv_unit_list "$unit")"
    if ! printf '%s\n' "$_list" | awk -v wanted="${unit}.service" '$1 == wanted { found=1 } END { exit !found }'; then
        return 0
    fi
    systemctl enable --now "$unit" >/dev/null 2>&1 || die "$(tprintf sv_unit_enable "$unit")"
    systemctl is-active --quiet "$unit" || die "$(tprintf sv_unit_inactive "$unit")"
}
# BUG-28: hoisted from init_system_environment().
__abox_reconcile_openrc_service() {
    local unit="$1"
    [[ -x "/etc/init.d/${unit}" ]] || return 0
    rc-update add "$unit" default >/dev/null 2>&1 || die "$(tprintf sv_orc_add "$unit")"
    rc-service "$unit" status >/dev/null 2>&1 || rc-service "$unit" start >/dev/null 2>&1 9>&- 10>&- || die "$(tprintf sv_orc_start "$unit")"
    rc-service "$unit" status >/dev/null 2>&1 || die "$(tprintf sv_orc_notrunning "$unit")"
}
init_system_environment() {
    local _init_soft="${1:-}"
    release=''
    local -a install_cmd=()
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            debian) release='debian'; install_cmd=(apt-get -y install) ;;
            ubuntu) release='ubuntu'; install_cmd=(apt-get -y install) ;;
            alpine) release='alpine'; install_cmd=(apk add) ;;
            centos|rhel|rocky|almalinux|fedora|amzn|ol|oracle) release='centos'; install_cmd=(yum -y install) ;;
        esac
        # ID_LIKE fallback for derivatives (e.g. ID=pop ID_LIKE="ubuntu debian").
        if [[ -z "$release" && -n "${ID_LIKE:-}" ]]; then
            case " ${ID_LIKE} " in
                *' debian '*|*' ubuntu '*) release='debian'; install_cmd=(apt-get -y install) ;;
                *' rhel '*|*' fedora '*|*' centos '*) release='centos'; install_cmd=(yum -y install) ;;
            esac
        fi
    fi
    if [[ -z "$release" ]]; then
        if [[ -f /etc/redhat-release ]] || grep -qiE 'centos|red hat|rocky|almalinux|fedora|amazon|oracle' /proc/version 2>/dev/null; then
            release='centos'; install_cmd=(yum -y install)
        elif grep -qi 'Alpine' /etc/issue /proc/version 2>/dev/null; then
            release='alpine'; install_cmd=(apk add)
        elif grep -qi 'debian' /etc/issue /proc/version 2>/dev/null; then
            release='debian'; install_cmd=(apt-get -y install)
        elif grep -qi 'ubuntu' /etc/issue /proc/version 2>/dev/null; then
            release='ubuntu'; install_cmd=(apt-get -y install)
        fi
    fi
    [[ -z "$release" ]] && die "$(tr_msg ie_unsupported)"
    if [[ "$release" == 'centos' ]] && command -v dnf >/dev/null 2>&1; then
        install_cmd=(dnf -y install)
    fi

    if systemd_available; then
        INIT_SYS='systemd'
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYS='openrc'
    elif [[ "$_init_soft" == 'soft' ]]; then
        # Menu-open path only: browsing needs no init system. Every
        # deployment entry calls this function without 'soft' and
        # keeps the hard gate below.
        INIT_SYS='unknown'
        msg "${YELLOW}[!] $(tr_msg init_soft_warn)${NC}"
    else
        die "$(tr_msg ie_no_init)"
    fi

    if [[ ! -f "$DEPS_MARKER" ]]; then
        msg "${YELLOW}[*] $(tprintf init_system_environment_syncing_deps "${release}" "${INIT_SYS}")${NC}"
        case "$release" in
            debian|ubuntu) apt-get update -y -q >/dev/null 2>&1 ;;
            centos) if command -v dnf >/dev/null 2>&1; then dnf makecache -y -q >/dev/null 2>&1 || true; else yum makecache -y -q >/dev/null 2>&1 || true; fi; "${install_cmd[@]}" epel-release >/dev/null 2>&1 || true ;;
            alpine) apk update -q >/dev/null 2>&1 ;;
        esac
        local deps=()
        case "$release" in
            debian|ubuntu)
                deps=(curl jq openssl bc unzip iptables tar psmisc lsof ca-certificates iproute2 coreutils cron logrotate uuid-runtime python3 util-linux diffutils)
                ;;
            centos)
                # Do not force the full 'curl' RPM when curl-minimal already provides
                # /usr/bin/curl (Rocky/Alma/RHEL 8+/9). Forcing curl conflicts with curl-minimal.
                # diffutils provides cmp(1), required by atomic install / OTA / traffic helpers.
                # Fix 2026-10-14: epel-release removed from required deps (EPEL does not exist
                # on Fedora; the opportunistic install above already tries it with || true
                # for RHEL derivatives that need it).
                deps=(jq openssl bc unzip iptables tar psmisc lsof ca-certificates coreutils cronie logrotate util-linux bind-utils iproute python3 diffutils)
                command -v curl >/dev/null 2>&1 || deps+=(curl)
                ;;
            alpine)
                # Use BusyBox crond (OpenRC unit name: crond). Do not apk-add cronie by
                # default: it lives in community and registers unit 'cronie', which used
                # to disagree with openrc_cron_service_name returning 'crond'.
                # Explicit 'tar' pulls GNU tar so backup fixtures and archives support
                # GNU long options where needed.
                # M-27: tzdata provides /usr/share/zoneinfo; without it
                # valid_timezone_name (TZif magic check) fails for every
                # zone including UTC on Alpine.
                deps=(bash curl jq openssl bc unzip iptables tar psmisc lsof ca-certificates iproute2 coreutils logrotate util-linux bind-tools procps iptables-openrc python3 shadow tzdata)
                # H-20(a): ip6tables ships in its own APK package on
                # Alpine 3.18 (pkgs.alpinelinux.org: ip6tables 1.8.9-r2
                # provides /sbin/ip6tables*). Whether 3.19+ still ships
                # it is unverified, so only add it on 3.18; the
                # ensure_commands command -v gate below is the final
                # check on every release.
                if [[ "$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)" == '3.18' ]]; then
                    deps+=(ip6tables)
                fi
                ;;
        esac
        if [[ "$release" == 'centos' ]] && command -v dnf >/dev/null 2>&1; then
            # --allowerasing covers residual curl <-> curl-minimal swaps if curl is needed.
            dnf -y install --allowerasing "${deps[@]}" >/dev/null 2>&1 || die "$(tr_msg ie_deps)"
        else
            "${install_cmd[@]}" "${deps[@]}" >/dev/null 2>&1 || die "$(tr_msg ie_deps)"
        fi
        ensure_abox_dir_owned "$ABOX_DIR"
        install -m 600 /dev/null "$DEPS_MARKER" || die "$(tr_msg ie_deps_marker)"
    fi

    ensure_commands

    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        case "$release" in
            debian|ubuntu) __abox_reconcile_systemd_unit cron ;;
            centos) __abox_reconcile_systemd_unit crond ;;
        esac
        if [[ "$release" == 'centos' ]]; then
            if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
                msg "${YELLOW}[*] firewalld is active; A-Box will add required ports natively and will not disable it.${NC}"
            else
                msg "${YELLOW}[*] firewalld is inactive; A-Box will persist only its own rules through A-Box-firewall.service.${NC}"
            fi
        fi
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        local cron_unit
        cron_unit=$(openrc_cron_service_name "$release")
        if [[ "$release" == 'alpine' && "$cron_unit" != 'crond' && -x /etc/init.d/crond ]]; then
            # Avoid dual schedulers after apk add cronie/dcron (Alpine wiki guidance).
            rc-service crond stop >/dev/null 2>&1 || true
            if command -v rc-update >/dev/null 2>&1 && rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])crond([[:space:]]|$)'; then
                rc-update del crond default >/dev/null 2>&1 || true
            fi
        fi
        __abox_reconcile_openrc_service "$cron_unit"
    fi

    IPT=$(command -v iptables || echo '/sbin/iptables')
    IPT6=$(command -v ip6tables || echo '/sbin/ip6tables')
}

install_optional_package() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    case "${release:-}" in
        debian|ubuntu) command -v apt-get >/dev/null 2>&1 && apt-get -y install "$pkg" >/dev/null 2>&1 ;;
        centos) if command -v dnf >/dev/null 2>&1; then dnf -y install --allowerasing "$pkg" >/dev/null 2>&1; elif command -v yum >/dev/null 2>&1; then yum -y install "$pkg" >/dev/null 2>&1; else return 1; fi ;;
        alpine) command -v apk >/dev/null 2>&1 && apk add "$pkg" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# FINAL-AUDIT: counterpart of install_optional_package, used only by rollback
# to undo a package installation performed by the current transaction.
remove_optional_package() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    case "${release:-}" in
        debian|ubuntu) command -v apt-get >/dev/null 2>&1 && apt-get -y remove "$pkg" >/dev/null 2>&1 ;;
        centos) if command -v dnf >/dev/null 2>&1; then dnf -y remove "$pkg" >/dev/null 2>&1; elif command -v yum >/dev/null 2>&1; then yum -y remove "$pkg" >/dev/null 2>&1; else return 1; fi ;;
        alpine) command -v apk >/dev/null 2>&1 && apk del "$pkg" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# BUG-28: hoisted from ensure_commands(). Redesigned as a query function:
# prints the package name to install when $2 is missing, prints nothing when present.
# $1=release (debian|ubuntu|centos|alpine); unknown release prints nothing (no-op).
__abox_missing_pkg_for() {
    local release="$1" cmd="$2" deb="$3" rpm="$4" apk="$5"
    type -aP -- "$cmd" >/dev/null 2>&1 && return 0
    case "$release" in
        debian|ubuntu) printf '%s\n' "$deb" ;;
        centos) printf '%s\n' "$rpm" ;;
        alpine) printf '%s\n' "$apk" ;;
    esac
}
# M-15(2): presence is not capability. A BusyBox applet satisfies
# `type -aP` but may lack the options this script relies on (flock -w,
# mv -T, base64 -w), so probe the options, not just the binary.
_abox_flock_w_ok() {
    command -v flock >/dev/null 2>&1 || return 1
    local _probe _rc
    _probe=$(mktemp) || return 1
    ( exec 9>"$_probe"; flock -w 0 9 ) >/dev/null 2>&1
    _rc=$?
    rm -f -- "$_probe"
    return "$_rc"
}

_abox_mv_t_ok() {
    command -v mv >/dev/null 2>&1 || return 1
    mv --help 2>&1 | grep -q -- '-T'
}

_abox_mktemp_json_ok() {
    # H-6: BusyBox mktemp rejects a suffix after the XXXXXX template
    # (e.g. /tmp/X.XXXXXX.json fails rc=1); GNU mktemp accepts it.
    # Probe the exact template the deploy paths used to use.
    command -v mktemp >/dev/null 2>&1 || return 1
    local _probe=''
    _probe=$(mktemp /tmp/A-Box-mktemp-probe.XXXXXX.json 2>/dev/null) || return 1
    rm -f -- "$_probe"
    return 0
}

_abox_base64_w_ok() {
    command -v base64 >/dev/null 2>&1 || return 1
    base64 -w0 </dev/null >/dev/null 2>&1
}

ensure_commands() {
    local missing_pkgs=()
    local -a _ens_install_cmd=()
    case "${release:-}" in
        debian|ubuntu) _ens_install_cmd=(apt-get -y install) ;;
        alpine) _ens_install_cmd=(apk add) ;;
        centos) if command -v dnf >/dev/null 2>&1; then _ens_install_cmd=(dnf -y install --allowerasing); else _ens_install_cmd=(yum -y install); fi ;;
    esac
    local _pkg
    _pkg=$(__abox_missing_pkg_for "$release" curl curl curl curl)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" jq jq jq jq)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" openssl openssl openssl openssl)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" bc bc bc bc)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" unzip unzip unzip unzip)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" tar tar tar tar)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" iptables iptables iptables iptables)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    # H-20(a): same 3.18-only rule as the deps list above: only
    # request the standalone ip6tables package where it is known to
    # exist (Alpine 3.18). On other releases the command -v gate
    # below is the final check.
    if [[ "${release:-}" != 'alpine' ]] || [[ "$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)" == '3.18' ]]; then
        _pkg=$(__abox_missing_pkg_for "$release" ip6tables iptables iptables ip6tables)
        [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    fi
    _pkg=$(__abox_missing_pkg_for "$release" ss iproute2 iproute iproute2)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" lsof lsof lsof lsof)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" getent libc-bin glibc-common libc-utils)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" flock util-linux util-linux util-linux)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" cmp diffutils diffutils diffutils)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" crontab cron cronie busybox)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" logrotate logrotate logrotate logrotate)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" python3 python3 python3 python3)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" groupadd passwd shadow-utils shadow)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    _pkg=$(__abox_missing_pkg_for "$release" useradd passwd shadow-utils shadow)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    # W4-tb3: Check.Place needs whiptail; without it the upstream script
    # stops at an interactive apt prompt. Package names: deb whiptail,
    # rpm newt (the newt package contains /usr/bin/whiptail), apk newt.
    _pkg=$(__abox_missing_pkg_for "$release" whiptail whiptail newt newt)
    [[ -n "$_pkg" ]] && missing_pkgs+=("$_pkg")
    # M-15(2): option-capability probes. A present-but-crippled applet
    # (BusyBox) queues its GNU package for the best-effort install below;
    # the install never dies here, so a host that cannot install keeps
    # working via the fallbacks (base64 -w0 fallback at the vmess link
    # site, plain mv, and the fallback runtime lock when flock -w stays
    # broken -- see the acquire/upgrade gates on _abox_flock_w_ok).
    local -a _cap_pkgs=()
    if command -v flock >/dev/null 2>&1 && ! _abox_flock_w_ok; then
        case "${release:-}" in debian|ubuntu|centos|alpine) _cap_pkgs+=("util-linux") ;; esac
    fi
    if command -v base64 >/dev/null 2>&1 && ! _abox_base64_w_ok; then
        case "${release:-}" in debian|ubuntu|centos|alpine) _cap_pkgs+=("coreutils") ;; esac
    fi
    if command -v mv >/dev/null 2>&1 && ! _abox_mv_t_ok; then
        case "${release:-}" in debian|ubuntu|centos|alpine) _cap_pkgs+=("coreutils") ;; esac
    fi
    if command -v mktemp >/dev/null 2>&1 && ! _abox_mktemp_json_ok; then
        case "${release:-}" in debian|ubuntu|centos|alpine) _cap_pkgs+=("coreutils") ;; esac
    fi
    if (( ${#missing_pkgs[@]} > 0 )); then
        local -a unique_pkgs=()
        mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | awk 'NF && !seen[$0]++')
        msg "${YELLOW}[*] $(tr_msg ensure_commands_installing_missing)${NC}"
        "${_ens_install_cmd[@]}" "${unique_pkgs[@]}" >/dev/null 2>&1 || die "$(tr_msg ec_reinstall)"
    fi
    if (( ${#_cap_pkgs[@]} > 0 )) && (( ${#_ens_install_cmd[@]} > 0 )); then
        local -a _cap_unique=()
        mapfile -t _cap_unique < <(printf '%s\n' "${_cap_pkgs[@]}" | awk 'NF && !seen[$0]++')
        msg "${YELLOW}[*] $(tr_msg ensure_commands_installing_missing)${NC}"
        "${_ens_install_cmd[@]}" "${_cap_unique[@]}" >/dev/null 2>&1 || true
    fi
    local required=(curl jq openssl bc unzip tar iptables ip6tables ss lsof crontab logrotate python3 flock cmp)
    local c
    for c in "${required[@]}"; do
        type -aP -- "$c" >/dev/null 2>&1 || die "$(tprintf ec_missing "$c")"
    done
    # flock is now guaranteed; upgrade any pre-ensure fallback lock onto LOCK_FILE.
    if [[ "${ABOX_RUNTIME_LOCK_MODE:-}" == fallback ]]; then
        upgrade_runtime_lock_to_flock_if_possible || die "$(tr_msg ec_lock)"
    fi
}

has_ipv6() {
    local _pref
    _pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    [[ "$_pref" == 'ipv4' ]] && return 1
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { found=1 } END { exit !found }' && return 0
    ip -6 route show default 2>/dev/null | awk '/^default/ { found=1 } END { exit !found }' && return 0
    return 1
}

has_ipv4() {
    local _pref
    _pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    [[ "$_pref" == 'ipv6' ]] && return 1
    ip -4 addr show scope global 2>/dev/null | awk '/inet / { found=1 } END { exit !found }' && return 0
    ip -4 route show default 2>/dev/null | awk '/^default/ { found=1 } END { exit !found }' && return 0
    return 1
}

wildcard_listen_address() {
    local bindv6only='0' pref
    pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    case "$pref" in
        ipv4)
            printf '0.0.0.0'
            return 0
            ;;
        ipv6)
            has_ipv6 || { printf '%s\n' "$(tr_msg wl_v6_only)" >&2; return 1; }
            printf '::'
            return 0
            ;;
    esac
    # dual (default): prefer :: when the kernel dual-stacks IPv4-mapped traffic.
    bindv6only=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf '0')
    if has_ipv6 && [[ "$bindv6only" == '0' ]]; then
        printf '::'
    elif has_ipv6 && ! has_ipv4; then
        # IPv6-only host: 0.0.0.0 binds nothing usable, so :: is the
        # only reachable wildcard even with bindv6only=1 (R7C5-01).
        printf '::'
    else
        # Preserve IPv4 reachability on IPv4-only or dual-stack hosts.
        printf '0.0.0.0'
    fi
}

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
ipv6_nat_redirect_usable() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    _iptables_q "$IPT6" -t nat -L PREROUTING >/dev/null 2>&1 || return 1
}

get_architecture() {
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) XRAY_ARCH='64'; SB_ARCH='amd64'; HY2_ARCH='amd64' ;;
        # armv8l is a 32-bit ARMv8 target, not AArch64; fail closed rather than
        # installing 64-bit arm64/aarch64 binaries into a 32-bit userspace.
        aarch64|arm64) XRAY_ARCH='arm64-v8a'; SB_ARCH='arm64'; HY2_ARCH='arm64' ;;
        *) die "$(tprintf ga_unknown "$ARCH")" ;;
    esac
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -r /proc/1/comm ]] || return 1
    [[ "$(cat /proc/1/comm 2>/dev/null || true)" == 'systemd' ]] || return 1
}

# Perf 2026-10-14: batch version to avoid 3x systemctl per menu refresh.
# Usage: service_active_states_batch xray sing-box hysteria
# Output: lines of "srv:1" or "srv:0" or "srv:?" 
service_active_states_batch() {
    local srv state out
    if [[ "${INIT_SYS:-}" == systemd ]] && systemd_available; then
        # Single systemctl call for all services
        out=$(systemctl show -p Id -p ActiveState --value "$@" 2>/dev/null) || return 1
        # Parse: output is pairs of Id, ActiveState lines
        local id=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ -z "$id" ]]; then
                id="${line%.service}"
            else
                case "$line" in
                    active) printf '%s:1\n' "$id" ;;
                    inactive|failed|dead|exited) printf '%s:0\n' "$id" ;;
                    *) printf '%s:?\n' "$id" ;;
                esac
                id=""
            fi
        done <<< "$out"
        return 0
    fi
    return 1
}

service_active_state_value() {
    local srv="$1" state rc
    if [[ "${INIT_SYS:-}" == systemd ]] && systemd_available; then
        state=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
        case "$state" in
            active) printf '1\n' ;;
            inactive|failed|dead|exited) printf '0\n' ;;
            *) return 1 ;;
        esac
        return 0
    elif [[ "${INIT_SYS:-}" == openrc ]]; then
        command -v rc-service >/dev/null 2>&1 || return 1
        rc-service "$srv" status >/dev/null 2>&1
        rc=$?
        case "$rc" in
            0) printf '1\n' ;;
            3|16|32) printf '0\n' ;;
            *) return 1 ;;
        esac
        return 0
    fi
    return 1
}

service_manager() {
    local action=$1; shift
    local srv
    for srv in "$@"; do
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
            case "$action" in
                stop)
                    systemctl stop "$srv" >/dev/null 2>&1 || true
                    [[ "$(service_active_state_value "$srv" 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
                    systemctl disable "$srv" >/dev/null 2>&1 || return 1
                    [[ "$(service_active_state_value "$srv" 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
                    ;;
                start)
                    systemctl daemon-reload >/dev/null 2>&1 || die 'systemd daemon-reload failed.'
                    systemctl enable "$srv" >/dev/null 2>&1 || die "$(tprintf sv_enable_boot "$srv")"
                    if ! systemctl restart "$srv" >/dev/null 2>&1; then
                        journalctl -u "$srv" --no-pager -n 80 2>/dev/null || true
                        die "$(tprintf sv_restart_fail "$srv")"
                    fi
                    sleep 2
                    if ! systemctl is-active --quiet "$srv"; then
                        journalctl -u "$srv" --no-pager -n 80 2>/dev/null || true
                        case "$srv" in sing-box|hysteria) clean_nat_rules 2>/dev/null || true; save_firewall_rules 2>/dev/null || true ;; esac
                        die "$(tprintf sv_up_fail "$srv")"
                    fi
                    record_core_family_ownership "$srv" || die "$(tprintf sv_ownership "$srv")"
                    ;;
                *) die "$(tprintf sv_unknown_action "$action")" ;;
            esac
        else
            case "$action" in
                stop)
                    rc-service "$srv" stop >/dev/null 2>&1 || true
                    [[ "$(service_active_state_value "$srv" 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
                    # R8-F04-1: query failure is failure — a failed
                    # rc-update show must not be read as "not in the
                    # default runlevel". Only a confirmed absence
                    # (grep rc 1) may skip the del; a grep error
                    # (rc > 1) fails like the query itself.
                    local _openrc_default _openrc_match_rc
                    _openrc_default=$(rc-update show default 2>/dev/null) || return 1
                    if grep -Eq "(^|[[:space:]])${srv}([[:space:]]|$)" <<< "$_openrc_default"; then
                        rc-update del "$srv" default >/dev/null 2>&1 || return 1
                    else
                        _openrc_match_rc=$?
                        [[ "$_openrc_match_rc" == 1 ]] || return 1
                    fi
                    [[ "$(service_active_state_value "$srv" 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
                    ;;
                start)
                    rc-update add "$srv" default >/dev/null 2>&1 || die "$(tprintf sv_orc_add2 "$srv")"
                    rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || die "$(tprintf sv_orc_restart "$srv")"
                    sleep 2
                    if ! rc-service "$srv" status >/dev/null 2>&1; then
                        case "$srv" in sing-box|hysteria) clean_nat_rules 2>/dev/null || true; save_firewall_rules 2>/dev/null || true ;; esac
                        die "$(tprintf sv_up_fail "$srv")"
                    fi
                    record_core_family_ownership "$srv" || die "$(tprintf sv_ownership "$srv")"
                    ;;
                *) die "$(tprintf sv_unknown_action "$action")" ;;
            esac
        fi
    done
}

service_unit_path() {
    local srv="$1"
    case "${INIT_SYS:-}" in
        systemd) printf '/etc/systemd/system/%s.service\n' "$srv" ;;
        openrc) printf '/etc/init.d/%s\n' "$srv" ;;
        *)
            if [[ -e "/etc/systemd/system/${srv}.service" || -L "/etc/systemd/system/${srv}.service" ]]; then
                printf '/etc/systemd/system/%s.service\n' "$srv"
            elif [[ -e "/etc/init.d/${srv}" || -L "/etc/init.d/${srv}" ]]; then
                printf '/etc/init.d/%s\n' "$srv"
            else
                return 1
            fi
            ;;
    esac
}


service_file_is_abox_managed() {
    local srv="$1" unit=''
    unit=$(service_unit_path "$srv" 2>/dev/null || true)
    [[ -n "$unit" && -f "$unit" && ! -L "$unit" ]] || return 1
    # Destructive ownership decisions require the exact marker.  Names,
    # standard paths, descriptions, or a stale .env file are not proof.
    grep -Fxq '# Managed by A-Box' "$unit"
}


abox_owns_service() {
    local srv="$1" unit=''
    unit=$(service_unit_path "$srv" 2>/dev/null || true)
    # Destructive ownership decisions require a concrete managed unit.  A
    # stale .env file is state, not proof that standard system paths are ours.
    [[ -n "$unit" && ( -e "$unit" || -L "$unit" ) ]] || return 1
    service_file_is_abox_managed "$srv"
}

effective_init_system() {
    if [[ "${INIT_SYS:-}" == systemd || "${INIT_SYS:-}" == openrc ]]; then
        printf '%s\n' "$INIT_SYS"
    elif systemd_available; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null 2>&1; then
        printf 'openrc\n'
    else
        printf 'unknown\n'
    fi
}

systemd_same_name_unit_path() {
    local srv="$1" path candidate
    if command -v systemctl >/dev/null 2>&1; then
        path=$(systemctl show -p FragmentPath --value "${srv}.service" 2>/dev/null || true)
        if [[ -n "$path" && ( -e "$path" || -L "$path" ) ]]; then printf '%s\n' "$path"; return 0; fi
    fi
    for candidate in "/etc/systemd/system/${srv}.service" "/run/systemd/system/${srv}.service" "/usr/local/lib/systemd/system/${srv}.service" "/usr/lib/systemd/system/${srv}.service" "/lib/systemd/system/${srv}.service"; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

same_name_service_unit_path() {
    local srv="$1" init
    init=$(effective_init_system)
    case "$init" in
        systemd) systemd_same_name_unit_path "$srv" ;;
        openrc) [[ -e "/etc/init.d/${srv}" || -L "/etc/init.d/${srv}" ]] && printf '/etc/init.d/%s\n' "$srv" ;;
        *) return 1 ;;
    esac
}

core_family_paths() {
    local init
    init=$(effective_init_system) || return 1
    case "$init" in
        systemd|openrc) ;;
        *) return 1 ;;
    esac
    case "$1" in
        xray)
            printf '%s\n' /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray
            case "$init" in systemd) printf '%s\n' /etc/systemd/system/xray.service ;; openrc) printf '%s\n' /etc/init.d/xray /etc/conf.d/xray ;; esac
            ;;
        sing-box)
            printf '%s\n' /usr/local/bin/sing-box /etc/sing-box
            case "$init" in systemd) printf '%s\n' /etc/systemd/system/sing-box.service ;; openrc) printf '%s\n' /etc/init.d/sing-box /etc/conf.d/sing-box ;; esac
            ;;
        hysteria)
            printf '%s\n' /usr/local/bin/hysteria /etc/hysteria
            case "$init" in systemd) printf '%s\n' /etc/systemd/system/hysteria.service ;; openrc) printf '%s\n' /etc/init.d/hysteria /etc/conf.d/hysteria ;; esac
            ;;
        xray-latest)
            printf '%s\n' /usr/local/bin/xray-latest /etc/ddr/xray-latest
            case "$init" in systemd) printf '%s\n' /etc/systemd/system/xray-latest.service ;; openrc) printf '%s\n' /etc/init.d/xray-latest /etc/conf.d/xray-latest ;; esac
            ;;
        *) return 1 ;;
    esac
}


record_core_family_ownership() {
    local srv="$1" tmp
    local -a owned_roots=()
    abox_owns_service "$srv" || return 1
    ensure_abox_dir_owned "$ABOX_DIR"
    if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
        [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || return 1
        [[ "$(stat -c %u:%g "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" == 0:0 ]] || return 1
        [[ "$(stat -c %a "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
        [[ "$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null || echo 99999999)" -le 4194304 ]] || return 1
    fi
    local core_paths=''
    core_paths=$(core_family_paths "$srv") || return 1
    if [[ -n "$core_paths" ]]; then
        mapfile -t owned_roots <<< "$core_paths" || return 1
    fi
    local _root
    for _root in "${owned_roots[@]}"; do
        [[ -e "$_root" || -L "$_root" ]] || continue
        path_tree_has_mountpoint "$_root" && return 1
    done
    tmp=$(umask 077; mktemp "$ABOX_DIR/.managed-core-files.XXXXXX") || return 1
    local runtime_uid runtime_gid _u _g
    IFS=$'\t' read -r _u _g < <(abox_runtime_identity "$srv") || { rm -f -- "$tmp"; return 1; }
    runtime_uid=$(id -u "$_u" 2>/dev/null) || { rm -f -- "$tmp"; return 1; }
    runtime_gid=$(getent group "$_g" 2>/dev/null | awk -F: '{print $3}')
    [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]] || { rm -f -- "$tmp"; return 1; }
    python3 -I - "$srv" "$ABOX_CORE_OWNERSHIP" "$tmp" "$runtime_uid" "$runtime_gid" "${owned_roots[@]}" <<'PY_CORE_RECORD'
import hashlib, os, stat, sys
srv, old_name, out_name, runtime_uid, runtime_gid, *roots = sys.argv[1:]
runtime_uid=int(runtime_uid)
runtime_gid=int(runtime_gid)
old=[]
try:
    st=os.lstat(old_name)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_mode & 0o077 or st.st_size > 4*1024*1024:
        raise SystemExit(1)
    with open(old_name, 'r', encoding='utf-8') as f:
        for line in f:
            parts=line.rstrip('\n').split('\t')
            if len(parts)!=4 or parts[0] not in {'F','D'} or not parts[2].startswith('/') or '\x00' in line:
                raise SystemExit(1)
            if parts[1] != srv:
                old.append(parts)
except FileNotFoundError:
    pass
except Exception:
    raise SystemExit(1)
entries=[]

def path_is_mountpoint(path):
    path=os.path.abspath(os.path.normpath(path))
    if os.path.islink(path):
        return False
    path=os.path.realpath(path).rstrip('/') or '/'
    try:
        with open('/proc/self/mountinfo','r',encoding='utf-8',errors='strict') as mf:
            for line in mf:
                fields=line.rstrip('\n').split(' ')
                if len(fields) < 5:
                    continue
                mp=__import__('re').sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1),8)), fields[4])
                mp=os.path.realpath(mp).rstrip('/') or '/'
                if mp == path:
                    return True
    except (OSError, UnicodeError):
        raise SystemExit(1)
    return False

# R16-F04-03: traverse by directory descriptor, not by path (same
# pattern as add_fd in refresh_dynamic_core_subtree_ownership): the
# old add_path() lstat'ed a subdirectory and then re-resolved the
# same path with os.listdir(), so a validated subdirectory could be
# swapped for a symlink before the listing and the walk escaped the
# recorded tree. Every object below is now opened relative to its
# parent's held fd (os.open with dir_fd, O_NOFOLLOW), validated by
# fstat on that fd, and read through that fd; the logical path is
# only the manifest identity, never re-resolved. Premise (same trust
# model as add_fd): the ancestors above each root are root-owned
# and not writable by the runtime user, so opening the root itself
# with O_NOFOLLOW is sound. Mountpoint checks stay on the logical
# path, as in add_fd.
if os.open not in os.supports_dir_fd or os.listdir not in os.supports_fd:
    raise SystemExit(1)
def add_fd(fd, path):
    try:
        # R5C5-02: a TSV separator in a path corrupts the manifest;
        # refuse before commit (bash drops tmp, old manifest kept).
        if '\t' in path or '\n' in path or '\r' in path:
            raise SystemExit(1)
        st = os.fstat(fd)
        if path_is_mountpoint(path):
            raise SystemExit(1)
        acme = srv == 'hysteria' and (path == '/etc/hysteria/acme' or path.startswith('/etc/hysteria/acme/'))
        uid_ok = st.st_uid in ({0, runtime_uid} if acme else {0})
        gid_ok = st.st_gid in ({0, runtime_gid})
        group_write_ok = acme and path == '/etc/hysteria/acme' and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
        if not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode) or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok):
            raise SystemExit(1)
        if stat.S_ISREG(st.st_mode):
            if st.st_nlink != 1: raise SystemExit(1)
            h=hashlib.sha256()
            with os.fdopen(fd,'rb') as f:
                for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
            fd=None
            entries.append(['F',srv,path,h.hexdigest()])
        elif stat.S_ISDIR(st.st_mode):
            entries.append(['D',srv,path,'-'])
            try:
                names=sorted(os.listdir(fd), key=os.fsencode)
            except OSError:
                raise SystemExit(1)
            for name in names:
                try:
                    _cfd=os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                except OSError:
                    raise SystemExit(1)
                add_fd(_cfd, os.path.join(path,name))
        else:
            raise SystemExit(1)
    finally:
        if fd is not None:
            try: os.close(fd)
            except OSError: pass
for root in roots:
    # A missing root is skipped, as before (the old lstat
    # FileNotFoundError returned). Any other open failure fails the
    # whole recording instead of publishing a partial manifest.
    try:
        _rfd=os.open(root, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        continue
    except OSError:
        raise SystemExit(1)
    add_fd(_rfd, root)
all_entries=old+entries
seen=set()
with open(out_name,'w',encoding='utf-8',newline='\n') as f:
    for row in sorted(all_entries,key=lambda r:(r[1],os.fsencode(r[2]))):
        key=(row[0],row[1],row[2])
        if key in seen: raise SystemExit(1)
        seen.add(key)
        f.write('\t'.join(row)+'\n')
    f.flush(); os.fsync(f.fileno())
os.chmod(out_name,0o600)
PY_CORE_RECORD
    local rc=$?
    if (( rc != 0 )); then rm -f -- "$tmp"; return 1; fi
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    # R16C5-01: check the COMPLETED temp manifest against the
    # same 4MiB limit before publishing. A published oversize
    # manifest blocks all later recordings and cleanups for
    # this family (entry gate rejects it, cleanup gate rejects it).
    [[ "$(stat -c %s "$tmp" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ABOX_CORE_OWNERSHIP" || { rm -f -- "$tmp"; return 1; }
}

refresh_dynamic_core_subtree_ownership() {
    local srv="$1" target="$2" tmp
    [[ "$srv" =~ ^(xray|sing-box|hysteria)$ ]] || return 1
    [[ "$target" == /etc/hysteria/acme ]] || return 1
    hysteria_acme_owner_marker_valid "$target/.A-Box-managed" || return 1
    path_tree_has_mountpoint "$target" && return 1
    [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || return 1
    [[ "$(stat -c %u:%g "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" == 0:0 ]] || return 1
    [[ "$(stat -c %a "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
    tmp=$(umask 077; mktemp "$ABOX_DIR/.managed-core-files.dynamic.XXXXXX") || return 1
    python3 -I - "$srv" "$ABOX_CORE_OWNERSHIP" "$target" "$tmp" <<'PY_DYNAMIC_OWNER'
import hashlib, os, stat, sys
srv, manifest, target, out_name = sys.argv[1:]
try:
    import pwd, grp
    runtime_uid = pwd.getpwnam("abox-hysteria").pw_uid
    runtime_gid = grp.getgrnam("abox-hysteria").gr_gid
except KeyError:
    raise SystemExit(1)

def validate_stat(st, path):
    # R15-F04-02: same ownership/mode rules safe_stat used to enforce,
    # now enforced on the fstat of an already-opened object, so the
    # checked inode is the one actually read — never a stale lstat
    # result for a path that may since have been swapped.
    acme = srv == 'hysteria' and (path == target or path.startswith(target + '/'))
    uid_ok = st.st_uid in ({0, runtime_uid} if acme else {0})
    gid_ok = st.st_gid in ({0, runtime_gid})
    legacy_root_dir_ok = acme and path == target and st.st_uid == 0 and st.st_gid == 0 and stat.S_ISDIR(st.st_mode) and (st.st_mode & 0o077) == 0
    group_write_ok = acme and path == target and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
    if not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode) or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok) or (acme and path == target and not (group_write_ok or legacy_root_dir_ok)):
        raise SystemExit(1)

target = target.rstrip('/')
rows=[]
with open(manifest, 'r', encoding='utf-8') as f:
    for line in f:
        p=line.rstrip('\n').split('\t')
        if len(p)!=4 or p[0] not in {'F','D'} or p[1] not in {'xray','sing-box','hysteria','xray-latest'} or not p[2].startswith('/') or '\x00' in line:
            raise SystemExit(1)
        rows.append(p)
if len({(r[0],r[1],r[2]) for r in rows}) != len(rows):
    raise SystemExit(1)
# Only refresh the runtime-owned ACME subtree. Static Hysteria files keep their
# original hashes, so a user edit to config.yaml/certs still fails closed.
rows=[r for r in rows if not (r[1]==srv and (r[2]==target or r[2].startswith(target + '/')))]
entries=[]
mountpoints=set()
try:
    with open('/proc/self/mountinfo','r',encoding='utf-8',errors='strict') as mf:
        for line in mf:
            fields=line.rstrip('\n').split(' ')
            if len(fields) < 5:
                continue
            mp=__import__('re').sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1),8)), fields[4])
            mountpoints.add(os.path.abspath(os.path.normpath(mp)))
except (OSError, UnicodeError):
    raise SystemExit(1)

def is_mountpoint(path):
    return os.path.abspath(os.path.normpath(path)) in mountpoints

# R15-F04-02: traverse by directory descriptor, not by path. The old
# add() lstat'ed a subdirectory and then re-resolved the same path with
# os.listdir(); the runtime user could swap a validated subdirectory
# for a symlink in between, and the leaf O_NOFOLLOW+fstat only bound
# the already-escaped lstat result. Every object below is now opened
# relative to its parent's held fd (os.open with dir_fd, O_NOFOLLOW),
# validated by fstat on that fd, and read through that fd; the logical
# path is only the manifest identity, never re-resolved. Premise (same
# trust model as the pre-existing parent checks): the ancestors above
# the target are root-owned and not writable by the runtime user, so
# opening the target itself with O_NOFOLLOW is sound.
if os.open not in os.supports_dir_fd or os.listdir not in os.supports_fd:
    raise SystemExit(1)
try:
    _tfd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except FileNotFoundError:
    _tfd = None
except OSError:
    raise SystemExit(1)
if _tfd is not None:
    _tst = os.fstat(_tfd)
    validate_stat(_tst, target)
    if not stat.S_ISDIR(_tst.st_mode) or is_mountpoint(target):
        try: os.close(_tfd)
        except OSError: pass
        raise SystemExit(1)
    def add_fd(fd, path):
        # R5C5-02: same TSV separator refusal as add_path.
        if '\t' in path or '\n' in path or '\r' in path:
            raise SystemExit(1)
        try:
            st = os.fstat(fd)
            validate_stat(st, path)
            if stat.S_ISREG(st.st_mode):
                if st.st_nlink != 1: raise SystemExit(1)
                h=hashlib.sha256()
                with os.fdopen(fd,'rb') as f:
                    for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
                fd=None
                entries.append(['F',srv,path,h.hexdigest()])
            elif stat.S_ISDIR(st.st_mode):
                if is_mountpoint(path): raise SystemExit(1)
                entries.append(['D',srv,path,'-'])
                for name in sorted(os.listdir(fd), key=os.fsencode):
                    try:
                        _cfd=os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                    except OSError:
                        raise SystemExit(1)
                    add_fd(_cfd, os.path.join(path,name))
            else:
                raise SystemExit(1)
        finally:
            if fd is not None:
                try: os.close(fd)
                except OSError: pass
    add_fd(_tfd, target)
rows.extend(entries)
seen=set()
with open(out_name,'w',encoding='utf-8',newline='\n') as f:
    for row in sorted(rows,key=lambda r:(r[1],os.fsencode(r[2]))):
        key=(row[0],row[1],row[2])
        if key in seen: raise SystemExit(1)
        seen.add(key)
        f.write('\t'.join(row)+'\n')
    f.flush(); os.fsync(f.fileno())
os.chmod(out_name,0o600)
PY_DYNAMIC_OWNER
    local rc=$?
    if (( rc != 0 )); then rm -f -- "$tmp"; return 1; fi
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    # R16C5-01: check the COMPLETED temp manifest against the
    # same 4MiB limit before publishing. A published oversize
    # manifest blocks all later recordings and cleanups for
    # this family (entry gate rejects it, cleanup gate rejects it).
    [[ "$(stat -c %s "$tmp" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ABOX_CORE_OWNERSHIP" || { rm -f -- "$tmp"; return 1; }
}

hysteria_acme_owner_marker_valid() {
    local marker="${1:-$HY2_ACME_OWNER_MARKER}"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    path_owned_by_root "$marker" || return 1
    path_mode_has_no_group_other_write "$marker" || return 1
    grep -Fxq 'A-Box managed Hysteria ACME directory v1' "$marker" 2>/dev/null
}

mark_hysteria_acme_dir_managed() {
    local dir="${1:-/etc/hysteria/acme}" marker="${2:-$HY2_ACME_OWNER_MARKER}" tmp _mode
    [[ "$dir" == /etc/hysteria/acme ]] || return 1
    [[ "$marker" == "$dir/.A-Box-managed" ]] || return 1
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    hysteria_acme_dir_runtime_permissions_valid "$dir" || return 1
    # H1 (R14-01 residual, hardening): the shared validator above also
    # accepts 770, so require 1770 HERE instead of relying on the
    # caller's pre-step: without the sticky bit a group member can
    # delete/replace root's tmp files. The validator itself is shared
    # (manifest checks accept a 770 top dir) and is deliberately NOT
    # tightened here.
    _mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
    [[ "$_mode" == 1770 ]] || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        hysteria_acme_owner_marker_valid "$marker"
        return
    fi
    tmp=$(umask 077; mktemp "$dir/.A-Box-managed.XXXXXX") || return 1
    printf '%s\n' 'A-Box managed Hysteria ACME directory v1' > "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
    hysteria_acme_owner_marker_valid "$marker"
}

hysteria_acme_current_tree_matches_manifest() {
    local manifest="${1:-$ABOX_CORE_OWNERSHIP}" target="${2:-/etc/hysteria/acme}"
    [[ "$target" == /etc/hysteria/acme ]] || return 1
    path_tree_has_mountpoint "$target" && return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    python3 -I - "$manifest" "$target" <<'PY_ACME_MATCH'
import hashlib, os, stat, sys
manifest, target = sys.argv[1:]
try:
    import pwd, grp
    runtime_uid = pwd.getpwnam("abox-hysteria").pw_uid
    runtime_gid = grp.getgrnam("abox-hysteria").gr_gid
except KeyError:
    raise SystemExit(1)
rows=[]
with open(manifest,'r',encoding='utf-8') as f:
    for line in f:
        p=line.rstrip('\n').split('\t')
        if len(p)!=4 or p[0] not in {'F','D'} or p[1] != 'hysteria' or not p[2].startswith('/') or '\x00' in line:
            continue
        rows.append(p)
recorded={r[2]:(r[0],r[3]) for r in rows if r[2]==target or r[2].startswith(target+'/')}
if recorded.get(target,('', ''))[0] != 'D':
    raise SystemExit(1)
# R16-F04-02 / Q4: check by directory descriptor, not by path.
# The old check() lstat'ed each object and then re-resolved it by
# path (os.listdir()/open()), so a validated subdirectory could be
# swapped for a symlink before the listing (same hole as R16-F04-03)
# and a validated file for a FIFO before the open (root blocks
# forever in open()). Hash comparison happens after the read, so it
# cannot prevent the out-of-tree read. Every object is now opened
# relative to its parent's held fd (os.open with dir_fd,
# O_NOFOLLOW|O_NONBLOCK), validated by fstat on that fd, and read
# through that fd; the logical path is only the manifest identity,
# never re-resolved.
def check_fd(fd, path):
    try:
        st=os.fstat(fd)
        acme = path == target or path.startswith(target + '/')
        # U1 (F05-02): the ownership marker is the trust anchor and
        # must stay root:root. The generic ACME rule that also accepts
        # runtime ownership must never apply to it: a runtime-owned
        # marker used to pass this check while marker_valid() rejected
        # it, so prepare failed on a fully canonical tree.
        is_marker = (path == os.path.join(target, '.A-Box-managed'))
        uid_ok = (st.st_uid == 0) if is_marker else st.st_uid in ({0, runtime_uid} if acme else {0})
        gid_ok = (st.st_gid == 0) if is_marker else st.st_gid in ({0, runtime_gid})
        legacy_root_dir_ok = acme and path == target and st.st_uid == 0 and st.st_gid == 0 and stat.S_ISDIR(st.st_mode) and (st.st_mode & 0o077) == 0
        group_write_ok = acme and path == target and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
        if not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode) or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok) or (acme and path == target and not (group_write_ok or legacy_root_dir_ok)):
            raise SystemExit(1)
        rec=recorded.get(path)
        if rec is None: raise SystemExit(1)
        typ,_=rec
        if stat.S_ISDIR(st.st_mode):
            if typ!='D': raise SystemExit(1)
            try:
                names=sorted(os.listdir(fd), key=os.fsencode)
            except OSError:
                raise SystemExit(1)
            for name in names:
                try:
                    _cfd=os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                except OSError:
                    raise SystemExit(1)
                check_fd(_cfd, os.path.join(path,name))
        elif stat.S_ISREG(st.st_mode):
            if typ!='F' or st.st_nlink != 1: raise SystemExit(1)
            h=hashlib.sha256()
            with os.fdopen(fd,'rb') as f:
                for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
            fd=None
            if h.hexdigest() != rec[1]: raise SystemExit(1)
        else:
            raise SystemExit(1)
    finally:
        if fd is not None:
            try: os.close(fd)
            except OSError: pass
if os.open not in os.supports_dir_fd or os.listdir not in os.supports_fd:
    raise SystemExit(1)
try:
    _tfd=os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    raise SystemExit(1)
check_fd(_tfd, target)
# No recorded file below the subtree may disappear from the current tree.
for path,(typ,_) in recorded.items():
    if path==target: continue
    if not os.path.lexists(path): raise SystemExit(1)
raise SystemExit(0)
PY_ACME_MATCH
}

hysteria_acme_dir_runtime_permissions_valid() {
    local dir="${1:-/etc/hysteria/acme}" user group uid gid mode nlink
    [[ "$dir" == /etc/hysteria/acme && -d "$dir" && ! -L "$dir" ]] || return 1
    IFS=$'\t' read -r user group < <(abox_runtime_identity hysteria) || return 1
    uid=$(id -u "$user" 2>/dev/null) || return 1
    gid=$(getent group "$group" 2>/dev/null | awk -F: '{print $3}')
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
    [[ "$(stat -c %u:%g "$dir" 2>/dev/null || true)" == "0:$gid" ]] || return 1
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
    nlink=$(stat -c %h "$dir" 2>/dev/null) || return 1
    # R-01: Accept 1770 (sticky bit) as well as 770.
    [[ "$nlink" =~ ^[1-9][0-9]*$ && "$mode" =~ ^0?1?770$ ]] || return 1
    return 0
}

hysteria_acme_repair_tree_ownership() {
    # Manifest-guided ownership/mode repair for recorded ACME subtree
    # paths (top dir excluded: the caller sets it to 1770). Content is
    # never touched, so a hash/content drift or a foreign file still
    # fails the manifest re-check and the caller refuses instead of
    # proceeding on a half-fixed tree. Symlinks, hard-linked files and
    # unrecorded paths are skipped, never followed or modified.
    # U1 (F05-02): the ownership marker (.A-Box-managed) is special:
    # it is never handed to the runtime user; see the restricted
    # marker branch below (root:root 0600, manifest-verified only).
    local manifest="${1:-$ABOX_CORE_OWNERSHIP}" target="${2:-/etc/hysteria/acme}" group="${3:-}"
    local gid=''
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ -d "$target" && ! -L "$target" ]] || return 1
    gid=$(getent group "$group" 2>/dev/null | awk -F: '{print $3}')
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    python3 -I - "$manifest" "$target" "$gid" <<'PY_ACME_REPAIR'
import hashlib, os, re, stat, sys
manifest, target, gid = sys.argv[1], sys.argv[2], int(sys.argv[3])
target = os.path.normpath(target)
# U1 (F05-02): the ownership marker is the trust anchor; its
# canonical state is root:root 0600 (see marker_valid()).
marker_path = os.path.join(target, '.A-Box-managed')
marker_magic = b'A-Box managed Hysteria ACME directory v1'
# R15C5-01: manifest preconditions on the OPEN file, not a
# re-resolved path. fstat pins the inode; lstat must agree (else the
# path was swapped for a symlink between the bash check and the open).
f = open(manifest, 'r', encoding='utf-8')
fst = os.fstat(f.fileno())
lst = os.lstat(manifest)
if (fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino):
    raise SystemExit(3)
if fst.st_uid != 0 or fst.st_gid != 0 or (fst.st_mode & 0o777) != 0o600:
    raise SystemExit(3)
def _tree_has_mount(t, mountinfo='/proc/self/mountinfo'):
    # R11C5-01: any mountpoint at or under the target means the tree
    # holds foreign files; refuse the whole repair, change nothing.
    try:
        with open(mountinfo, 'r', encoding='utf-8', errors='strict') as mf:
            for line in mf:
                fields = line.rstrip('\n').split(' ')
                if len(fields) < 5:
                    continue
                mp = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), fields[4])
                if os.path.normpath(mp) == t or os.path.normpath(mp).startswith(t + '/'):
                    return True
    except (OSError, UnicodeError):
        raise SystemExit(4)
    return False
if _tree_has_mount(target):
    raise SystemExit(3)
def _open_parent_fd(path):
    # R1-05-F01: pin every ancestor via O_NOFOLLOW fds (same pattern
    # as the remove_recorded_core_family fd deletion). A swap before
    # a step is refused (ELOOP); a swap after it cannot redirect the
    # already-open fd.
    parts = [p for p in os.path.abspath(os.path.normpath(path)).split(os.sep) if p]
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for comp in parts[:-1]:
            nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise
try:
    import pwd
    runtime_uid = pwd.getpwnam('abox-hysteria').pw_uid
except (ImportError, KeyError):
    runtime_uid = None
if runtime_uid is None:
    # R26 (F05-1): without the runtime user there is nobody to
    # hand write access to; silently leaving root ownership
    # would re-create the renewal breakage below. Fail closed.
    # (Unreachable via prepare_hysteria_acme_dir_ownership,
    # which ensures the identity first; this guards direct
    # callers.)
    raise SystemExit(1)
rows = []
for line in f:
    p = line.rstrip('\n').split('\t')
    if len(p) != 4 or p[0] not in {'F', 'D'} or p[1] != 'hysteria' or not p[2].startswith('/') or '\x00' in line:
        continue
    rows.append(p)
for typ, _fam, rawpath, _h in rows:
    # R15C5-01: normalize lexically FIRST, then contain. A raw '..'
    # row (acme/../../shadow) passes a text-prefix filter but
    # normalizes outside the tree and must be rejected.
    path = os.path.normpath(rawpath)
    if path == target or not path.startswith(target + '/'):
        continue
    try:
        parent_fd, leaf = _open_parent_fd(path)
    except OSError:
        continue
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
    except OSError:
        os.close(parent_fd)
        continue
    os.close(parent_fd)
    try:
        st = os.fstat(fd)
        if stat.S_ISLNK(st.st_mode):
            continue
        # U1 (F05-02): the ownership marker is the trust anchor and
        # must NEVER be handed to the runtime user below. A marker
        # that is already root:root 0600 is left alone. Any other
        # state is restored to root:root 0600 only through the
        # restricted recovery below, and only when all of these hold:
        # the file was opened via its pinned parent fd (O_NOFOLLOW),
        # it is a recorded regular file with a single link, its
        # content read through the held fd hashes to the hash recorded
        # for it in the trusted root-owned manifest (the manifest
        # preconditions above already pinned it to root:root 0600),
        # and it carries the magic marker line. Anything else is
        # skipped, so the manifest re-check refuses and the operator
        # must recover it by hand. The magic line alone never
        # authorises recovery, and content is never rewritten here.
        if path == marker_path:
            if typ != 'F' or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                continue
            _mdata = bytearray()
            _moff = 0
            _mtoolarge = False
            try:
                while True:
                    _mchunk = os.pread(fd, 1024 * 1024, _moff)
                    if not _mchunk:
                        break
                    _moff += len(_mchunk)
                    if _moff > 4 * 1024 * 1024:
                        _mtoolarge = True
                        break
                    _mdata += _mchunk
            except OSError:
                continue
            if _mtoolarge:
                continue
            if hashlib.sha256(bytes(_mdata)).hexdigest() != _h:
                continue
            if marker_magic not in bytes(_mdata).split(b'\n'):
                continue
            if st.st_uid != 0 or st.st_gid != 0:
                os.fchown(fd, 0, 0)
            if stat.S_IMODE(st.st_mode) != 0o600:
                os.fchmod(fd, 0o600)
            continue
        if stat.S_ISDIR(st.st_mode):
            if typ != 'D':
                continue
            want_mode = 0o750
        elif stat.S_ISREG(st.st_mode):
            if typ != 'F' or st.st_nlink != 1:
                continue
            want_mode = 0o640
        else:
            continue
        # R1-05-F02: leave check-compliant items alone. The manifest
        # check allows uid {0, runtime} and gid {0, runtime} with no
        # other/group write; a compliant runtime-owned entry already
        # has its owner write, so it needs no change. Normalize
        # only violators (handed to the runtime user below).
        uid_ok = st.st_uid in ({0, runtime_uid} if runtime_uid is not None else {0})
        gid_ok = st.st_gid in {0, gid}
        mode_ok = (st.st_mode & 0o022) == 0
        mode = stat.S_IMODE(st.st_mode)
        # R26 (F05-1): renewal writes, it does not just read.
        # need is writability (dir 0o7 / file 0o6), not the old
        # readability (0o5 / 0o4): a root-owned 0750 dir with
        # the runtime gid was previously skipped as compliant
        # while the runtime user could not create/replace files.
        need = 0o7 if stat.S_ISDIR(st.st_mode) else 0o6
        runtime_owns = (runtime_uid is not None and st.st_uid == runtime_uid)
        # R4-03: DAC selects ONE permission class by identity; it does
        # not OR owner/group/other. Renewal is done by the runtime
        # user itself (no root-side renewer exists), so the entry
        # must be WRITABLE by it, not merely readable: a root-owned
        # 0750/0640 entry is readable but renewal-dead. Violators
        # are handed to the runtime user (owner write, modes stay
        # 0750/0640); a runtime-owned entry that only lacks write
        # gets its owner bits topped up instead of losing its
        # ownership (R1-05-F02).
        if runtime_owns:
            access_bits = (mode >> 6) & 0o7
        elif st.st_gid == gid:
            access_bits = (mode >> 3) & 0o7
        else:
            access_bits = mode & 0o7
        can_runtime = (access_bits & need) == need
        if uid_ok and gid_ok and mode_ok:
            if can_runtime:
                continue
            if runtime_owns:
                os.fchmod(fd, mode | (need << 6))
                continue
        os.fchown(fd, runtime_uid, gid)
        os.fchmod(fd, want_mode)
    finally:
        os.close(fd)
PY_ACME_REPAIR
}

hysteria_acme_readopt_manifest() {
    # R8: atomically append the D record for an ACME dir and the F
    # record for its marker to the ownership manifest. Only for a
    # marker-only tree (interrupted first setup); any other entry
    # refuses without touching the manifest. The caller re-verifies
    # the whole tree afterwards.
    local manifest="${1:-$ABOX_CORE_OWNERSHIP}" target="${2:-/etc/hysteria/acme}" marker="${3:-$HY2_ACME_OWNER_MARKER}"
    [[ "$target" == /etc/hysteria/acme ]] || return 1
    [[ "$marker" == "$target/.A-Box-managed" ]] || return 1
    python3 -I - "$manifest" "$target" "$marker" <<'PY_ACME_READOPT'
import hashlib, os, stat, sys, tempfile
manifest, target, marker = sys.argv[1:]
try:
    st = os.lstat(manifest)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or (st.st_mode & 0o777) != 0o600 or st.st_size > 4 * 1024 * 1024:
        raise SystemExit(1)
    with open(manifest, 'r', encoding='utf-8') as f:
        rows = []
        for line in f:
            p = line.rstrip('\n').split('\t')
            if len(p) != 4 or p[0] not in {'F', 'D'} or not p[2].startswith('/') or '\x00' in line:
                raise SystemExit(1)
            rows.append(p)
except OSError:
    raise SystemExit(1)
# Marker-only tree: every entry under the target must be the marker.
try:
    names = os.listdir(target)
except OSError:
    raise SystemExit(1)
if any(n != '.A-Box-managed' for n in names):
    raise SystemExit(1)
try:
    mst = os.lstat(marker)
    if not stat.S_ISREG(mst.st_mode) or stat.S_ISLNK(mst.st_mode):
        raise SystemExit(1)
    h = hashlib.sha256()
    with open(marker, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
except OSError:
    raise SystemExit(1)
kept = [r for r in rows if not (r[1] == 'hysteria' and (r[2] == target or r[2].startswith(target + '/')))]
new = kept + [['D', 'hysteria', target, '-'], ['F', 'hysteria', marker, h.hexdigest()]]
seen = set()
for r in new:
    key = (r[0], r[1], r[2])
    if key in seen:
        raise SystemExit(1)
    seen.add(key)
new.sort(key=lambda r: (r[1], os.fsencode(r[2])))
# R4-04: gate the FINAL serialized manifest, not the old size: the two
# appended rows can push it over the 4 MiB limit the readers enforce.
text = ''.join('\t'.join(r) + '\n' for r in new)
if len(text.encode('utf-8')) > 4 * 1024 * 1024:
    raise SystemExit(1)
# M-19 (supplement): mkstemp, not a fixed name: 0600 regardless of
# the inherited umask (the old open(tmp,'w') created 0644 under
# umask 022) and never reuses a pre-placed path. Same shape as the
# manifest rewrite at the end of remove_recorded_core_family.
_dirname = os.path.dirname(manifest)
_fd, tmp = tempfile.mkstemp(prefix='.readopt.', dir=_dirname, text=True)
try:
    with os.fdopen(_fd, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.chown(tmp, 0, 0)
    os.replace(tmp, manifest)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY_ACME_READOPT
}

hysteria_acme_marker_recovery_evidence() {
    # U1 (F05-02): restricted recovery evidence for a marker damaged by
    # the old repair (e.g. runtime-owned 0640 with intact content).
    # Returns 0 only when the marker is proven to be OUR marker from
    # evidence independent of its current ownership:
    #   * a manifest record for this exact marker path, in the trusted
    #     root-owned manifest (open-file fstat pinned, lstat agrees,
    #     uid/gid 0:0, mode 0600 — same preconditions as the repair);
    #   * the marker file opened via its pinned parent fd (O_NOFOLLOW),
    #     a regular file with a single link (symlink/hard-link refused);
    #   * its content, read through the held fd, hashes to the recorded
    #     hash AND carries the magic marker line.
    # The magic line alone never suffices, content is never rewritten
    # here, and this changes nothing: the caller still runs the repair
    # (which re-verifies every condition) and the strict manifest
    # re-check afterwards. Without this evidence the gate refuses and
    # the operator must recover the marker by hand.
    local manifest="${1:-$ABOX_CORE_OWNERSHIP}" target="${2:-/etc/hysteria/acme}" marker="${3:-$HY2_ACME_OWNER_MARKER}"
    [[ "$target" == /etc/hysteria/acme ]] || return 1
    [[ "$marker" == "$target/.A-Box-managed" ]] || return 1
    path_parent_chain_safe "$marker" || return 1
    path_tree_has_mountpoint "$target" && return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    python3 -I - "$manifest" "$target" "$marker" <<'PY_ACME_MARKER_EVIDENCE'
import hashlib, os, stat, sys
manifest, target, marker = sys.argv[1:]
try:
    f = open(manifest, 'r', encoding='utf-8')
except OSError:
    raise SystemExit(1)
fst = os.fstat(f.fileno())
try:
    lst = os.lstat(manifest)
except OSError:
    raise SystemExit(1)
if (fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino):
    raise SystemExit(1)
if fst.st_uid != 0 or fst.st_gid != 0 or (fst.st_mode & 0o777) != 0o600:
    raise SystemExit(1)
recorded = None
for line in f:
    p = line.rstrip('\n').split('\t')
    if len(p) != 4 or p[0] not in {'F', 'D'} or p[1] != 'hysteria' or not p[2].startswith('/') or '\x00' in line:
        continue
    if p[0] == 'F' and p[2] == marker:
        recorded = p[3]
f.close()
if recorded is None:
    raise SystemExit(1)
def _open_parent_fd(path):
    # Same fd-pinning pattern as the repair: a swap before a step is
    # refused (ELOOP); a swap after it cannot redirect the held fd.
    parts = [p for p in os.path.abspath(os.path.normpath(path)).split(os.sep) if p]
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for comp in parts[:-1]:
            nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise
try:
    parent_fd, leaf = _open_parent_fd(marker)
except OSError:
    raise SystemExit(1)
try:
    mfd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
except OSError:
    os.close(parent_fd)
    raise SystemExit(1)
os.close(parent_fd)
try:
    st = os.fstat(mfd)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise SystemExit(1)
    data = bytearray()
    off = 0
    while True:
        chunk = os.pread(mfd, 1024 * 1024, off)
        if not chunk:
            break
        off += len(chunk)
        if off > 4 * 1024 * 1024:
            raise SystemExit(1)
        data += chunk
finally:
    os.close(mfd)
if hashlib.sha256(bytes(data)).hexdigest() != recorded:
    raise SystemExit(1)
if b'A-Box managed Hysteria ACME directory v1' not in bytes(data).split(b'\n'):
    raise SystemExit(1)
raise SystemExit(0)
PY_ACME_MARKER_EVIDENCE
}

prepare_hysteria_acme_dir_ownership() {
    local dir=/etc/hysteria/acme marker=$HY2_ACME_OWNER_MARKER user group _pgroup _pmode
    IFS=$'\t' read -r user group < <(abox_runtime_identity hysteria) || return 1
    ensure_abox_runtime_identity hysteria || return 1
    path_parent_chain_safe "$dir/.A-Box-managed" || return 1
    [[ ! -L /etc/hysteria && (! -e /etc/hysteria || -d /etc/hysteria) ]] || return 1
    if [[ -e /etc/hysteria ]]; then
        # R12/R15: an existing parent must already be traversable by
        # the runtime group; its group is never rewritten here.
        _pgroup=$(stat -c %G /etc/hysteria 2>/dev/null || true)
        _pmode=$(stat -c %a /etc/hysteria 2>/dev/null || true)
        if [[ "$_pgroup" == "$group" ]]; then
            chmod g+x /etc/hysteria 2>/dev/null || return 1
        elif [[ "$(( 8#${_pmode:-0} & 1 ))" == "0" ]]; then
            msg "${RED}$(tr_msg hy2_acme_parent_untraversable)${NC}" >&2
            return 1
        fi
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ ! -L "$dir" && -d "$dir" ]] || return 1
        # U1 (F05-02): the tree is managed if the marker is valid, the
        # manifest matches, or the marker carries restricted recovery
        # evidence (manifest-verified content, independent of its
        # current ownership). The repair still re-verifies everything
        # and the strict manifest re-check below has the final word.
        if ! hysteria_acme_owner_marker_valid "$marker" && ! hysteria_acme_current_tree_matches_manifest "$ABOX_CORE_OWNERSHIP" "$dir" && ! hysteria_acme_marker_recovery_evidence "$ABOX_CORE_OWNERSHIP" "$dir" "$marker"; then
            # U1 (F05-02): a marker that exists but cannot be verified
            # (bad ownership/content, or no matching manifest record)
            # is never auto-certified. Refuse and point the operator
            # at manual recovery.
            if [[ -e "$marker" || -L "$marker" ]]; then
                msg "${RED}$(tr_msg hy2_acme_tree_drift)${NC}"
            fi
            return 1
        fi
        # U145: the gate above passes on a valid marker even when the
        # subtree drifted, and the old top-only chown/chmod left the
        # drifted subdirs broken. Repair recorded paths, then re-verify
        # the whole tree; a content drift or foreign file still fails
        # the manifest check and the migration refuses with a hint.
        if [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]]; then
            hysteria_acme_repair_tree_ownership "$ABOX_CORE_OWNERSHIP" "$dir" "$group" 2>/dev/null || true
            # R15-F05-02: repair the top level BEFORE the manifest check
            # below: the subtree repair skips the top, and the check
            # requires root:<group> with group write (or legacy
            # root:root 0700). A drifted top used to fail the check and
            # return before the top chown/chmod further down could run.
            # The gate above already proved this tree is managed (valid
            # marker or matching manifest), so normalising the top to
            # its canonical state here is safe.
            chown "root:$group" "$dir" || return 1
            chmod 1770 "$dir" || return 1
            # H-18(2): files legitimately issued after the manifest was
            # written (e.g. ACME certificates) are unrecorded, so the
            # manifest gate below fails; re-adopt refuses any
            # non-marker-only tree, so prepare deadlocks. Refresh the
            # manifest first. The marker gate above already passed, so
            # refresh's own marker requirement is satisfied on a
            # valid-marker tree; on a marker-invalid tree the refresh is
            # skipped and the previous fail-closed behaviour is kept.
            if hysteria_acme_owner_marker_valid "$marker"; then
                refresh_dynamic_core_subtree_ownership hysteria "$dir" || return 1
            fi
            if ! hysteria_acme_current_tree_matches_manifest "$ABOX_CORE_OWNERSHIP" "$dir"; then
                # R8: interrupted first setup leaves dir + valid marker
                # but no D record; repair cannot add records, so retry
                # deadlocked. Re-adopt only a marker-only tree (the
                # empty interrupted case); any other content still
                # fails closed below.
                if ! hysteria_acme_owner_marker_valid "$marker" \
                    || ! hysteria_acme_readopt_manifest "$ABOX_CORE_OWNERSHIP" "$dir" "$marker" \
                    || ! hysteria_acme_current_tree_matches_manifest "$ABOX_CORE_OWNERSHIP" "$dir"; then
                    msg "${RED}$(tr_msg hy2_acme_tree_drift)${NC}"
                    return 1
                fi
            fi
        fi
        chown "root:$group" "$dir" || return 1
        # A-03: Sticky bit (1770) prevents group members from deleting/replacing others' files (TOCTOU).
        chmod 1770 "$dir" || return 1
        hysteria_acme_dir_runtime_permissions_valid "$dir" || return 1
        mark_hysteria_acme_dir_managed "$dir" "$marker" || return 1
        return 0
    fi
    # R-01-FIX: Parent 750, acme dir 1770 (sticky). Fresh-dir was still 770.
    # R15: only create a missing parent; an existing parent keeps its
    # group (the top-of-function traversal check already validated it).
    if [[ ! -e /etc/hysteria ]]; then
        install -d -o root -g "$group" -m 750 /etc/hysteria || return 1
    fi
    install -d -o root -g "$group" -m 1770 "$dir" || return 1
    hysteria_acme_dir_runtime_permissions_valid "$dir" || return 1
    mark_hysteria_acme_dir_managed "$dir" "$marker" || return 1
    return 0
}

remove_recorded_core_family() {
    local srv="$1" runtime_uid runtime_gid
    # R15a-01: the derivation while-read loop below assigns _t/_s/_p/_h;
    # keep them local so bash dynamic scoping cannot clobber a caller's
    # same-named locals.
    local _t='' _s='' _p='' _h=''
    [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || return 2
    [[ "$(stat -c %u:%g "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" == 0:0 ]] || return 1
    [[ "$(stat -c %a "$ABOX_CORE_OWNERSHIP" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
    [[ "$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null || echo 99999999)" -le 4194304 ]] || return 1
    local _u _g
    IFS=$'\t' read -r _u _g < <(abox_runtime_identity "$srv") || return 1
    runtime_uid=$(id -u "$_u" 2>/dev/null || true)
    runtime_gid=$(getent group "$_g" 2>/dev/null | awk -F: '{print $3}')
    if [[ ! "$runtime_uid" =~ ^[0-9]+$ || ! "$runtime_gid" =~ ^[0-9]+$ ]]; then
        # SYD-B3 E22: the recorded service user/group may already be gone
        # (deleted outside a cleanup run, e.g. a prior partial cleanup).
        # Derive the runtime identity from the surviving recorded files:
        # the unique non-root uid/gid, else 0:0; ambiguous -> fail closed.
        local _derived_uid='' _derived_gid='' _ambig=0 _fu='' _fg=''
        while IFS=$'\t' read -r _t _s _p _h || [[ -n "$_t$_s$_p$_h" ]]; do
            [[ "$_s" == "$srv" ]] || continue
            [[ -e "$_p" ]] || continue
            _fu=$(stat -c %u "$_p" 2>/dev/null || true)
            _fg=$(stat -c %g "$_p" 2>/dev/null || true)
            [[ "$_fu" =~ ^[0-9]+$ && "$_fg" =~ ^[0-9]+$ ]] || { _ambig=1; break; }
            if [[ "$_fu" != 0 ]]; then
                if [[ -z "$_derived_uid" ]]; then _derived_uid="$_fu"; elif [[ "$_derived_uid" != "$_fu" ]]; then _ambig=1; break; fi
            fi
            if [[ "$_fg" != 0 ]]; then
                if [[ -z "$_derived_gid" ]]; then _derived_gid="$_fg"; elif [[ "$_derived_gid" != "$_fg" ]]; then _ambig=1; break; fi
            fi
        done < "$ABOX_CORE_OWNERSHIP"
        [[ "$_ambig" == 0 ]] || return 1
        # SYD-B4 B9: fill only the missing item. A resolved value must
        # never be overwritten by derivation from recorded files, or the
        # Python preflight (gid in {0, runtime_gid}) would bless a file
        # owned by an unrelated orphan gid.
        [[ "$runtime_uid" =~ ^[0-9]+$ ]] || runtime_uid="${_derived_uid:-0}"
        [[ "$runtime_gid" =~ ^[0-9]+$ ]] || runtime_gid="${_derived_gid:-0}"
    fi
    [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]] || return 1
    python3 -I - "$srv" "$ABOX_CORE_OWNERSHIP" "$runtime_uid" "$runtime_gid" "$ABOX_DIR" <<'PY_CORE_REMOVE'
import hashlib, os, re, stat, sys, tempfile
srv, manifest, runtime_uid, runtime_gid, abox_dir=sys.argv[1:]
runtime_uid=int(runtime_uid)
runtime_gid=int(runtime_gid)
rows=[]; keep=[]; all_rows=[]
with open(manifest,'r',encoding='utf-8') as f:
    for line in f:
        p=line.rstrip('\n').split('\t')
        if len(p)!=4 or p[0] not in {'F','D'} or not p[2].startswith('/') or '\x00' in line:
            raise SystemExit(1)
        all_rows.append(p)
        (rows if p[1]==srv else keep).append(p)
if not rows: raise SystemExit(2)
if len({(r[0],r[1],r[2]) for r in all_rows}) != len(all_rows): raise SystemExit(1)
files={r[2]:r[3] for r in rows if r[0]=='F'}
dirs={r[2] for r in rows if r[0]=='D'}
expected=set(files)|dirs
def _repair_is_mountpoint(path):
    path = os.path.abspath(os.path.normpath(path))
    if os.path.islink(path):
        return False
    try:
        with open('/proc/self/mountinfo', 'r', encoding='utf-8', errors='strict') as mf:
            for line in mf:
                fields = line.rstrip('\n').split(' ')
                if len(fields) < 5:
                    continue
                mp = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), fields[4])
                mp = os.path.abspath(os.path.normpath(mp))
                if mp == path:
                    return True
    except (OSError, UnicodeError):
        raise SystemExit(4)
    return False
# SYD-B5e R1: repair product doubling artifacts before the strict preflight.
# Backup used to nest <dir>/<basename(dir)>/ copies of recorded files; a
# restore writes them back to live, and the strict rule below then refuses
# the whole family. An unrecorded entry is an artifact only if stripping
# repeated "<basename(dir)>/" insertions maps it onto a recorded entry: a
# file must map onto a recorded file with an identical hash; a directory
# must map onto a recorded directory (the doubling directory itself maps
# onto its own recorded parent) and every descendant must itself be an
# artifact. All entries must also meet the same regular-file/dir,
# ownership, mode, link and mountpoint bars as recorded files. Anything
# else still fails closed with exit 3.
# Accepted identification boundary: a user-saved copy that is byte-identical
# and follows the doubling path rule, or a user directory named exactly like
# the doubling pattern, is indistinguishable from a product artifact. Block 5
# F03: that is exactly why it is NOT deleted by default — deletion of an
# unrecorded entry requires the explicit opt-in
# ABOX_ALLOW_DELETE_UNRECORDED=1; without it the family removal refuses and
# reports the paths. This layer never claims zero user-copy deletion.
def _artifact_target(path):
    for d in sorted(dirs, key=len, reverse=True):
        if path.startswith(d + os.sep):
            rest = path[len(d) + 1:]
            prefix = os.path.basename(d) + os.sep
            while rest.startswith(prefix):
                rest = rest[len(prefix):]
            cand = d + os.sep + rest
            if cand in files:
                return cand
    return None
def _artifact_dir_target(path):
    for d in sorted(dirs, key=len, reverse=True):
        if path.startswith(d + os.sep):
            rest = path[len(d) + 1:]
            prefix = os.path.basename(d) + os.sep
            while rest.startswith(prefix):
                rest = rest[len(prefix):]
            if rest == os.path.basename(d):
                return d
            cand = d + os.sep + rest
            if cand in dirs:
                return cand
    return None
def _artifact_mode_ok(st):
    return (not stat.S_ISLNK(st.st_mode)) and (not (st.st_mode & 0o002)) and (not (st.st_mode & 0o020))
def _artifact_owner_ok(st):
    return st.st_uid == 0 and st.st_gid in (0, runtime_gid)
def _is_artifact_file_fd(fd, path):
    # M-19 (supplement): same bar as _is_artifact_file, but validated
    # by fstat on an already-opened fd and read through that fd, so a
    # swap between check and read cannot redirect the read.
    try:
        st = os.fstat(fd)
    except OSError:
        return False
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or not _artifact_mode_ok(st) or not _artifact_owner_ok(st):
        return False
    tgt = _artifact_target(path)
    if tgt is None:
        return False
    h = hashlib.sha256()
    try:
        while True:
            _chunk = os.read(fd, 1024 * 1024)
            if not _chunk:
                break
            h.update(_chunk)
    except OSError:
        return False
    return h.hexdigest() == files[tgt]
def _is_artifact_file(path):
    if _repair_is_mountpoint(path):
        return False
    try:
        _pfd, _leaf = _open_parent_fd(path)
    except OSError:
        return False
    try:
        try:
            _fd = os.open(_leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=_pfd)
        except OSError:
            return False
        try:
            return _is_artifact_file_fd(_fd, path)
        finally:
            try: os.close(_fd)
            except OSError: pass
    finally:
        try: os.close(_pfd)
        except OSError: pass
def _is_artifact_tree_fd(fd, path):
    # M-19 (supplement): fd-recursive twin of _is_artifact_tree. Every
    # child is opened relative to its parent's held fd (O_NOFOLLOW |
    # O_NONBLOCK) and validated by fstat on that fd; a swapped-in
    # symlink is refused (ELOOP) and a FIFO is refused by fstat
    # without ever blocking in open().
    # H1 (02b2a-H1): a bind mount nested inside the tree is a real
    # directory (or a real file), so the type/owner/mode/hash bars
    # above cannot see it -- and st_dev cannot either, a same-
    # filesystem bind mount shares the parent's st_dev. A mountpoint
    # at any depth is foreign data, never a doubling artifact: refuse
    # the whole tree when any recursive child is a mountpoint (the
    # root itself is already checked by _is_artifact_tree).
    if _repair_is_mountpoint(path):
        return False
    try:
        st = os.fstat(fd)
    except OSError:
        return False
    if stat.S_ISDIR(st.st_mode):
        if not _artifact_mode_ok(st) or not _artifact_owner_ok(st):
            return False
        if _artifact_dir_target(path) is None:
            return False
        try:
            names = os.listdir(fd)
        except OSError:
            return False
        for n in names:
            try:
                _cfd = os.open(n, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            except OSError:
                return False
            try:
                if not _is_artifact_tree_fd(_cfd, os.path.join(path, n)):
                    return False
            finally:
                try: os.close(_cfd)
                except OSError: pass
        return True
    return _is_artifact_file_fd(fd, path)
def _is_artifact_tree(path):
    if _repair_is_mountpoint(path):
        return False
    try:
        _pfd, _leaf = _open_parent_fd(path)
    except OSError:
        return False
    try:
        try:
            _fd = os.open(_leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=_pfd)
        except OSError:
            return False
        try:
            return _is_artifact_tree_fd(_fd, path)
        finally:
            try: os.close(_fd)
            except OSError: pass
    finally:
        try: os.close(_pfd)
        except OSError: pass
# SYD-B7: a symlinked ABOX_DIR would let listdir walk an external tree;
# per-dir islink checks cannot see an ancestor symlink. Fail closed here.
# (TOCTOU swap after this check is a root-race window, accepted as-is.)
try:
    _ad_st = os.lstat(abox_dir)
except OSError:
    raise SystemExit(3)
if stat.S_ISLNK(_ad_st.st_mode) or not stat.S_ISDIR(_ad_st.st_mode):
    raise SystemExit(3)
_repair = []
for _d in sorted(dirs, key=os.fsencode):
    if os.path.islink(_d):
        raise SystemExit(3)
    try:
        _names = os.listdir(_d)
    except FileNotFoundError:
        continue
    except OSError:
        raise SystemExit(3)
    for _n in _names:
        _child = os.path.join(_d, _n)
        if _child not in expected:
            _repair.append(_child)
# R3F03: mount pre-check on every recorded directory and its ancestors,
# BEFORE any deletion. A recorded dir that is itself (or sits under) a
# bind mount must refuse: nested copies inside it are foreign data even
# when they are not themselves mountpoints and pass the artifact checks.
# '/' itself is always a mountpoint and is excluded from the walk.
# R4-05: an ordinary separate partition (e.g. /usr on its own filesystem)
# is NOT a bind mount, but mountinfo alone cannot reliably tell the two
# apart (a root bind has root '/', a btrfs subvolume mount has root !=
# '/'), so the layout is never auto-trusted. An administrator who has
# verified the current layout may explicitly trust specific ancestor
# mounts for THIS invocation only, via ABOX_TRUSTED_UNINSTALL_ANCESTORS
# (colon-separated absolute paths, e.g. /usr:/usr/local). The recorded
# dir itself, when it is a mountpoint, is never trusted. The list is
# never read from the manifest or old state, and never persisted.
_trusted_ancestor_mounts = set()
for _p in os.environ.get('ABOX_TRUSTED_UNINSTALL_ANCESTORS', '').split(':'):
    if not _p:
        continue
    if not os.path.isabs(_p):
        raise SystemExit(4)
    _trusted_ancestor_mounts.add(os.path.abspath(os.path.normpath(_p)))
def _path_or_ancestors_mounted(path):
    recorded = os.path.abspath(os.path.normpath(path))
    cur = recorded
    while cur != '/':
        if _repair_is_mountpoint(cur):
            if cur == recorded or cur not in _trusted_ancestor_mounts:
                return True
        cur = os.path.dirname(cur)
    return False
for _d in sorted(dirs):
    if _path_or_ancestors_mounted(_d):
        raise SystemExit(3)
def _open_parent_fd(path):
    parts = [p for p in os.path.abspath(os.path.normpath(path)).split(os.sep) if p]
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for comp in parts[:-1]:
            nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise
def _unlink_fd(path):
    fd, leaf = _open_parent_fd(path)
    try:
        os.unlink(leaf, dir_fd=fd)
    finally:
        os.close(fd)
def _rmdir_fd(path):
    fd, leaf = _open_parent_fd(path)
    try:
        os.rmdir(leaf, dir_fd=fd)
    finally:
        os.close(fd)
def _clear_fd_tree(dfd, path):
    for name in os.listdir(dfd):
        _child = os.path.join(path, name)
        # H1 (02b2a-H1) defence in depth: the validation gate above
        # already refuses mountpoints, but a mount swapped in between
        # validation and deletion must never be descended into -- the
        # unlink/rmdir below would delete the mount source's data.
        if _repair_is_mountpoint(_child):
            raise OSError('refusing to delete inside mountpoint: ' + _child)
        st = os.lstat(name, dir_fd=dfd)
        if stat.S_ISDIR(st.st_mode):
            cfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
            try:
                _clear_fd_tree(cfd, _child)
            finally:
                os.close(cfd)
            os.rmdir(name, dir_fd=dfd)
        else:
            os.unlink(name, dir_fd=dfd)
def _rmtree_fd(path):
    if _repair_is_mountpoint(path):
        raise OSError('refusing to delete mountpoint tree: ' + path)
    parent_fd, leaf = _open_parent_fd(path)
    try:
        dfd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            _clear_fd_tree(dfd, path)
        finally:
            os.close(dfd)
        os.rmdir(leaf, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)

# R1-05-F03: verify live recorded hashes BEFORE deleting any doubling
# artifact. The artifact test below compares an unrecorded file's hash
# to the manifest hash; if the live recorded file were tampered, an
# artifact matching the manifest would be deleted while the live tree
# is untrusted, and the later strict preflight would fail only after
# that destructive change. No deletion may happen before the live tree
# is proven. This loop checks recorded entries only (no children
# enumeration: doubling artifacts are still present); the full strict
# preflight after artifact removal re-checks everything including
# children.
for path in sorted(expected, key=os.fsencode):
    # (fd-model open follows the mount check below)
    # R26 (F05-3): check ancestors, not just the file itself. A
    # bind mount on an ancestor dir (e.g. /usr/local/bin) leaves
    # the recorded file a non-mountpoint with a matching hash.
    if _path_or_ancestors_mounted(path):
        raise SystemExit(3)
    # M-19 (supplement): open once via the pinned parent fd and
    # validate by fstat on that fd. Never lstat-then-re-resolve by
    # path: the object can be swapped for a FIFO between the check
    # and the open, and root then blocks forever in open() (no
    # O_NONBLOCK, no timeout). O_NOFOLLOW refuses a swapped-in
    # symlink ancestor (ELOOP); O_NONBLOCK lets the open succeed on
    # a FIFO so fstat can refuse it without blocking.
    try:
        _pfd, _leaf = _open_parent_fd(path)
    except FileNotFoundError:
        continue
    except OSError:
        raise SystemExit(3)
    try:
        _fd = os.open(_leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=_pfd)
    except FileNotFoundError:
        os.close(_pfd)
        continue
    except OSError:
        os.close(_pfd)
        raise SystemExit(3)
    st = os.fstat(_fd)
    acme = srv == 'hysteria' and (path == '/etc/hysteria/acme' or path.startswith('/etc/hysteria/acme/'))
    uid_ok = st.st_uid in ({0} if not acme else {0, runtime_uid})
    gid_ok = st.st_gid in ({0, runtime_gid})
    group_write_ok = acme and path == '/etc/hysteria/acme' and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
    if not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode) or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok):
        raise SystemExit(3)
    if path in files:
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1: raise SystemExit(3)
        h=hashlib.sha256()
        try:
            with os.fdopen(_fd,'rb') as f:
                for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
        except OSError: raise SystemExit(3)
        _fd = None
        if h.hexdigest()!=files[path]: raise SystemExit(3)
    else:
        if not stat.S_ISDIR(st.st_mode): raise SystemExit(3)
    if _fd is not None:
        try: os.close(_fd)
        except OSError: pass
    try: os.close(_pfd)
    except OSError: pass
if _repair:
    if all(_is_artifact_tree(_p) for _p in _repair):
        # Block 5 F03: an unrecorded entry classified as a doubling
        # artifact is still not a recorded file. A user-saved copy that
        # is byte-identical and follows the doubling path rule is
        # indistinguishable from a product artifact; deleting it without
        # authorization has destroyed user data. Default: refuse and
        # report the paths. Deletion requires the explicit opt-in
        # ABOX_ALLOW_DELETE_UNRECORDED=1 (same opt-in pattern as
        # ABOX_ALLOW_CORE_DOWNGRADE).
        if os.environ.get('ABOX_ALLOW_DELETE_UNRECORDED') != '1':
            for _p in sorted(_repair, key=os.fsencode):
                print(f"[!] Refusing to delete unrecorded entry (doubling artifact?): {_p}", file=sys.stderr)
            print("[!] Set ABOX_ALLOW_DELETE_UNRECORDED=1 to authorize deleting these unrecorded entries.", file=sys.stderr)
            raise SystemExit(3)
        for _p in sorted(_repair, key=os.fsencode, reverse=True):
            if os.path.isdir(_p) and not os.path.islink(_p):
                _rmtree_fd(_p)
            else:
                _unlink_fd(_p)
            print(f"[!] Removed doubling artifact (authorized by ABOX_ALLOW_DELETE_UNRECORDED=1): {_p}", file=sys.stderr)
    else:
        for _p in sorted(_repair, key=os.fsencode):
            print(f"[!] Refusing to delete unrecorded entry (not a doubling artifact): {_p}", file=sys.stderr)
        raise SystemExit(3)
# Complete fail-closed preflight before deleting anything. Every actual entry
# below a recorded directory must itself be recorded, correctly typed, root
# owned, non-link, non-writable by group/other, and (for files) hash-identical.
for path in sorted(expected, key=os.fsencode):
    # (fd-model open follows the mount check below)
    # R26 (F05-3): same ancestor check as the dirs preflight and
    # the R1-05-F03 loop above; the old self-only is_mountpoint()
    # missed a bind mount on an ancestor dir of a recorded file.
    # mountinfo is authoritative for this destructive operation;
    # on read failure _repair_is_mountpoint raises SystemExit(4),
    # i.e. fail closed instead of using the weaker ismount().
    if _path_or_ancestors_mounted(path):
        raise SystemExit(3)
    # M-19 (supplement): open once via the pinned parent fd and
    # validate by fstat on that fd. Never lstat-then-re-resolve by
    # path: the object can be swapped for a FIFO between the check
    # and the open, and root then blocks forever in open() (no
    # O_NONBLOCK, no timeout). O_NOFOLLOW refuses a swapped-in
    # symlink ancestor (ELOOP); O_NONBLOCK lets the open succeed on
    # a FIFO so fstat can refuse it without blocking.
    try:
        _pfd, _leaf = _open_parent_fd(path)
    except FileNotFoundError:
        continue
    except OSError:
        raise SystemExit(3)
    try:
        _fd = os.open(_leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=_pfd)
    except FileNotFoundError:
        os.close(_pfd)
        continue
    except OSError:
        os.close(_pfd)
        raise SystemExit(3)
    st = os.fstat(_fd)
    acme = srv == 'hysteria' and (path == '/etc/hysteria/acme' or path.startswith('/etc/hysteria/acme/'))
    uid_ok = st.st_uid in ({0} if not acme else {0, runtime_uid})
    gid_ok = st.st_gid in ({0, runtime_gid})
    group_write_ok = acme and path == '/etc/hysteria/acme' and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
    if not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode) or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok):
        raise SystemExit(3)
    if path in files:
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1: raise SystemExit(3)
        h=hashlib.sha256()
        try:
            with os.fdopen(_fd,'rb') as f:
                for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
        except OSError: raise SystemExit(3)
        _fd = None
        if h.hexdigest()!=files[path]: raise SystemExit(3)
    else:
        if not stat.S_ISDIR(st.st_mode): raise SystemExit(3)
        try: names=os.listdir(_fd)
        except OSError: raise SystemExit(3)
        for name in names:
            child=os.path.join(path,name)
            if child not in expected: raise SystemExit(3)
    if _fd is not None:
        try: os.close(_fd)
        except OSError: pass
    try: os.close(_pfd)
    except OSError: pass
# R4C5-01: delete via dir_fd + O_NOFOLLOW relative operations, not
# absolute paths. Walking down from a pinned '/' fd with O_NOFOLLOW at
# each step pins every ancestor: a swap before the step is refused
# (ELOOP), a swap after it cannot redirect the already-open fd. The
# leaf itself is safe: unlink/rmdir never follow the final component.
# Only after the complete tree is proven exact may deletion begin.
for path in sorted(files, key=lambda p:(p.count(os.sep),len(p)), reverse=True):
    try: _unlink_fd(path)
    except FileNotFoundError: pass
    except OSError: raise SystemExit(1)
for path in sorted(dirs, key=lambda p:(p.count(os.sep),len(p)), reverse=True):
    try: _rmdir_fd(path)
    except FileNotFoundError: pass
    except OSError: raise SystemExit(1)
dirname=os.path.dirname(manifest)
fd,tmp=tempfile.mkstemp(prefix='.managed-core-files.',dir=dirname,text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8',newline='\n') as f:
        for row in keep: f.write('\t'.join(row)+'\n')
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.chown(tmp,0,0); os.replace(tmp,manifest)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY_CORE_REMOVE
}

