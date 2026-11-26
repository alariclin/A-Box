# ABOX-MODULE-BEGIN 05-firewall firewall backends, ports, remote script install
#   Source: install.sh lines 20004-24968 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
save_firewall_rules() {
    local tmp4 tmp6 backend target target4="$ABOX_DIR/iptables.v4" target6="$ABOX_DIR/iptables.v6"
    local backup4='' backup6='' restore_failed=0
    backend=$(firewall_backend) || return 1
    case "$backend" in
        nftables-unsupported)
            msg "${RED}Native nftables rules detected; A-Box cannot safely persist or roll them back. No firewall rules were changed.${NC}"
            return 1
            ;;
        ufw|firewalld)
            remove_abox_firewall_persistence || return 1
            return 0
            ;;
    esac
    command -v iptables-save >/dev/null 2>&1 || return 1
    install -d -m 711 "$ABOX_DIR" || return 1

    # Refuse unsafe existing persistence files, then snapshot them before the
    # two-file replacement so a later failure cannot leave a mixed v4/v6 state.
    for target in "$target4" "$target6"; do
        if [[ -L "$target" ]]; then return 1; fi
        if [[ -e "$target" ]]; then
            [[ -f "$target" ]] || return 1
            [[ "$(stat -c %h "$target" 2>/dev/null || echo 0)" == 1 ]] || return 1
        fi
    done
    if [[ -f "$target4" ]]; then
        backup4=$(mktemp "$ABOX_DIR/.iptables.v4.rollback.XXXXXX") || return 1
        rm -f -- "$backup4"
        cp -a -- "$target4" "$backup4" || { rm -f -- "$backup4"; return 1; }
    fi
    if [[ -f "$target6" ]]; then
        backup6=$(mktemp "$ABOX_DIR/.iptables.v6.rollback.XXXXXX") || { rm -f -- "$backup4"; return 1; }
        rm -f -- "$backup6"
        cp -a -- "$target6" "$backup6" || { rm -f -- "$backup4" "$backup6"; return 1; }
    fi

    tmp4=$(mktemp "$ABOX_DIR/.iptables.v4.XXXXXX") || { rm -f -- "$backup4" "$backup6"; return 1; }
    tmp6=$(mktemp "$ABOX_DIR/.iptables.v6.XXXXXX") || { rm -f -- "$tmp4" "$backup4" "$backup6"; return 1; }
    iptables-save > "${tmp4}.all" 2>/dev/null || { rm -f "$tmp4" "$tmp6" "${tmp4}.all" "$backup4" "$backup6"; return 1; }
    extract_abox_iptables_rules "${tmp4}.all" all 1 > "$tmp4" || { rm -f "$tmp4" "$tmp6" "${tmp4}.all" "$backup4" "$backup6"; return 1; }
    rm -f "${tmp4}.all"
    if command -v ip6tables-save >/dev/null 2>&1; then
        if ip6tables-save > "${tmp6}.all" 2>/dev/null; then
            extract_abox_iptables_rules "${tmp6}.all" all 1 > "$tmp6" || { rm -f "$tmp4" "$tmp6" "${tmp6}.all" "$backup4" "$backup6"; return 1; }
            rm -f "${tmp6}.all"
        elif ! host_has_usable_ipv6; then
            # A present userspace binary does not prove that the kernel IPv6
            # firewall backend is enabled. Ignore only a failed v6 query when
            # no global IPv6 address/default route is available.
            # R19b-M1: "no usable address" is not "no IPv6 firewall
            # state": rules can persist in the kernel while the address
            # is temporarily unavailable, and the save itself can fail
            # transiently (e.g. xtables lock contention). If an
            # existing IPv6 snapshot holds rules, a failed save must
            # fail the whole save and keep the old file, not silently
            # downgrade it to an empty snapshot and delete it below.
            if grep -q '^\*' "$target6" 2>/dev/null; then
                rm -f "$tmp4" "$tmp6" "${tmp6}.all" "$backup4" "$backup6"
                return 1
            fi
            rm -f "${tmp6}.all"
            : > "$tmp6"
        else
            rm -f "$tmp4" "$tmp6" "${tmp6}.all" "$backup4" "$backup6"
            return 1
        fi
    else
        if host_has_usable_ipv6; then
            rm -f -- "$tmp4" "$tmp6" "$backup4" "$backup6"
            return 1
        fi
        # R19b-M1: same guard as the failed-save branch above: a
        # missing ip6tables-save binary does not prove the persisted
        # IPv6 snapshot is worthless.
        if grep -q '^\*' "$target6" 2>/dev/null; then
            rm -f -- "$tmp4" "$tmp6" "$backup4" "$backup6"
            return 1
        fi
        : > "$tmp6"
    fi
    chmod 600 "$tmp4" "$tmp6" || { rm -f "$tmp4" "$tmp6" "$backup4" "$backup6"; return 1; }
    # M-30(2): mktemp inherits the caller's egid, so under
    # `sudo -g <non-root>` the published files would be 0:<non-root>
    # and firewall_state_file_safe (0:0) would refuse them later.
    chown root:root "$tmp4" "$tmp6" || { rm -f "$tmp4" "$tmp6" "$backup4" "$backup6"; return 1; }
    if ! grep -q '^\*' "$tmp4" && ! grep -q '^\*' "$tmp6"; then
        rm -f "$tmp4" "$tmp6" "$backup4" "$backup6"
        remove_abox_firewall_persistence || return 1
        return 0
    fi

    if grep -q '^\*' "$tmp4"; then
        if ! mv -f -- "$tmp4" "$target4"; then
            rm -f -- "$tmp4" "$tmp6" "$backup4" "$backup6"
            return 1
        fi
    else
        rm -f -- "$target4" || { rm -f -- "$tmp4" "$tmp6" "$backup4" "$backup6"; return 1; }
        rm -f -- "$tmp4"
    fi
    if grep -q '^\*' "$tmp6"; then
        if ! mv -f -- "$tmp6" "$target6"; then
            if [[ -n "$backup4" ]]; then cp -a -- "$backup4" "$target4" || restore_failed=1; else rm -f -- "$target4" || restore_failed=1; fi
            rm -f -- "$tmp6"
            if (( restore_failed == 0 )); then rm -f -- "$backup4" "$backup6"; else printf '%s\n' "A-Box firewall restore FAILED; pre-change backup(s) preserved: ${backup4:-none} ${backup6:-none} (restore iptables.v4/v6 from them manually)" >&2; fi
            (( restore_failed == 0 )) || return 1
            return 1
        fi
    else
        if ! rm -f -- "$target6"; then
            if [[ -n "$backup4" ]]; then cp -a -- "$backup4" "$target4" || restore_failed=1; else rm -f -- "$target4" || restore_failed=1; fi
            rm -f -- "$tmp6"
            if (( restore_failed == 0 )); then rm -f -- "$backup4" "$backup6"; else echo "A-Box firewall save FAILED; pre-change backup(s) preserved: ${backup4:-none} ${backup6:-none} (restore iptables.v4/v6 from them manually)" >&2; fi
            return 1
        fi
        rm -f -- "$tmp6"
    fi
    if ! install_abox_firewall_persistence_service; then
        if [[ -n "$backup4" ]]; then cp -a -- "$backup4" "$target4" || restore_failed=1; else rm -f -- "$target4" || restore_failed=1; fi
        if [[ -n "$backup6" ]]; then cp -a -- "$backup6" "$target6" || restore_failed=1; else rm -f -- "$target6" || restore_failed=1; fi
        if (( restore_failed == 0 )); then rm -f -- "$backup4" "$backup6"; else printf '%s\n' "A-Box firewall restore FAILED; pre-change backup(s) preserved: ${backup4:-none} ${backup6:-none} (restore iptables.v4/v6 from them manually)" >&2; fi
        (( restore_failed == 0 )) || return 1
        return 1
    fi
    rm -f -- "$backup4" "$backup6"
    return 0
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    local out
    out=$(LC_ALL=C ufw status 2>/dev/null || true)
    [[ "$out" =~ Status: ]] || return 2
    printf '%s\n' "$out" | awk 'tolower($0) ~ /^status:[ \t\r]*active/ { found=1 } END { exit !found }'
}

nftables_native_rules_present() {
    command -v nft >/dev/null 2>&1 || return 1
    local ruleset rc
    ruleset=$(nft -nn list ruleset 2>/dev/null); rc=$?
    (( rc == 0 )) || return 2
    # SYD-B E1a: a fail2ban-only ruleset is not native-nftables
    # evidence. Drop fail2ban-namespace tables (name f2b, f2b-...,
    # f2b_... whose chains are all f2b-named) before classifying,
    # so the backend falls through to iptables instead of routing
    # the backup into the nftables-unsupported dead end.
    ruleset=$(printf '%s\n' "$ruleset" | awk '
        function flush() {
            if (buf != "" && !(f2b_table && f2b_only)) printf "%s", buf
            buf=""; f2b_table=0; f2b_only=1
        }
        /^[ \t\r]*table[ \t\r]+/ {
            flush()
            nm=$3; gsub(/[{}]/, "", nm)
            f2b_table = (nm == "f2b" || nm ~ /^f2b[-_]/)
            f2b_only = 1
            buf = buf $0 "\n"
            in_table = 1
            next
        }
        in_table && /^[ \t\r]*chain[ \t\r]+/ {
            cn=$2; gsub(/\{/, "", cn)
            if (!(cn == "f2b" || cn ~ /^f2b[-_]/)) f2b_only = 0
            buf = buf $0 "\n"
            next
        }
        in_table && /^}/ {
            buf = buf $0 "\n"
            flush()
            in_table = 0
            next
        }
        { if (in_table) buf = buf $0 "\n"; else print }
        END { flush() }
    ')
    printf '%s\n' "$ruleset" | awk '
        # U24/U25 (2026-10-24): a chain name alone never proves native
        # nftables. Only a BASE chain (its declaration block carries a
        # "type ... hook ..." header) counts, and only when it cannot
        # come from iptables-nft: a custom-named base chain anywhere, or
        # a lowercase standard-named base chain outside the standard
        # compat tables (ip/ip6 filter/nat/mangle/raw/security).
        # iptables-nft base chains are UPPERCASE (INPUT/FORWARD/OUTPUT/
        # PREROUTING/POSTROUTING); a lowercase user chain (no type/hook)
        # inside a compat table is not native evidence either.
        function is_std(c, lc) {
            lc = tolower(c)
            return (lc == "input" || lc == "forward" || lc == "output" || lc == "prerouting" || lc == "postrouting")
        }
        function is_lower_std(c) {
            return (c == "input" || c == "forward" || c == "output" || c == "prerouting" || c == "postrouting")
        }
        function is_compat_table(f, n) {
            return ((f == "ip" || f == "ip6") && (n == "filter" || n == "nat" || n == "mangle" || n == "raw" || n == "security"))
        }
        function eval_chain() {
            if (!is_std(pend_cname)) { native = 1; return }
            if (is_lower_std(pend_cname)) { native = 1; return }
        }
        /^[ \t\r]*table[ \t\r]+/ {
            family=$2
            name=$3
            gsub(/[{}]/, "", name)
            if (family == "inet" || family == "bridge" || family == "netdev" || family == "arp")
                native=1
            else if ((family == "ip" || family == "ip6") &&
                     name !~ /^(filter|nat|mangle|raw|security)$/)
                native=1
            pend = 0
            next
        }
        /^[ \t\r]*chain[ \t\r]+/ {
            cname=$2
            gsub(/\{/, "", cname)
            pend = 1
            pend_cname = cname
            pend_family = family
            pend_name = name
            # Single-line declaration: base-chain header on the same line.
            if ($0 ~ /type[ \t\r]+[A-Za-z]+[ \t\r]+hook[ \t\r]+[A-Za-z]+/) {
                eval_chain()
                pend = 0
            }
            next
        }
        # G6: a comment line may sit between the chain line and its
        # base-chain header; skip it without judging its content.
        pend && /^[ \t\r]*comment/ { next }
        pend && /^[ \t\r]*type[ \t\r]+/ {
            if ($0 ~ /type[ \t\r]+[A-Za-z]+[ \t\r]+hook[ \t\r]+[A-Za-z]+/)
                eval_chain()
            pend = 0
            next
        }
        { pend = 0 }
        END { exit !native }
    '
}

firewall_backend() {
    local rc fw_state
    ufw_is_active; rc=$?
    if (( rc == 0 )); then printf 'ufw\n'; return 0; fi
    if (( rc == 2 )); then return 1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        fw_state=$(firewall-cmd --state 2>/dev/null || true)
        if [[ "$fw_state" == running ]]; then printf 'firewalld\n'; return 0; fi
        if [[ "$fw_state" != 'not running' ]]; then return 1; fi
    fi
    nftables_native_rules_present; rc=$?
    if (( rc == 0 )); then printf 'nftables-unsupported\n'; return 0; fi
    if (( rc == 2 )); then return 1; fi
    printf 'iptables\n'
}

native_firewall_record_valid() {
    local line="$1" backend spec proto scope zone extra normalized
    IFS='|' read -r backend spec proto scope zone extra <<< "$line"
    [[ -z "$extra" ]] || return 1
    normalized=$(normalize_port_spec "$spec") || return 1
    [[ "$normalized" == "$spec" ]] || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    case "$backend:$scope" in
        ufw:rule) [[ -z "$zone" ]] || return 1 ;;
        firewalld:runtime|firewalld:permanent)
            if [[ -n "$zone" ]]; then
                [[ "$zone" =~ ^[A-Za-z0-9_.:@+-]+$ ]] || return 1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

firewall_state_file_safe() {
    local file="${1:-$ABOX_FW_STATE}" uid gid mode
    [[ -f "$file" && ! -L "$file" ]] || return 1
    uid=$(stat -c %u "$file" 2>/dev/null) || return 1
    gid=$(stat -c %g "$file" 2>/dev/null) || return 1
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

validate_native_firewall_state_file() {
    local file="${1:-$ABOX_FW_STATE}" line
    firewall_state_file_safe "$file" || return 1
    declare -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        native_firewall_record_valid "$line" || return 1
        [[ -z "${seen[$line]:-}" ]] || return 1
        seen[$line]=1
    done < "$file"
}

record_native_firewall_rule() {
    local backend="$1" spec proto="$3" scope="${4:-}" record tmp zone='' zone_override="${5:-}"
    spec=$(normalize_port_spec "$2") || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    case "$backend:$scope" in
        ufw:rule) ;;
        firewalld:runtime|firewalld:permanent)
            if [[ -n "$zone_override" ]]; then
                zone="$zone_override"
            else
                zone=$(firewalld_zone_for_abox) || return 1
            fi
            ;;
        *) return 1 ;;
    esac
    if [[ -n "$zone" ]]; then
        record="${backend}|${spec}|${proto}|${scope}|${zone}"
    else
        record="${backend}|${spec}|${proto}|${scope}"
    fi
    native_firewall_record_valid "$record" || return 1
    install -d -o root -g root -m 711 "$ABOX_DIR" || return 1
    if [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]]; then
        validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
    fi
    tmp=$(mktemp "$ABOX_DIR/.firewall-native.XXXXXX") || return 1
    if [[ -f "$ABOX_FW_STATE" ]]; then
        cat "$ABOX_FW_STATE" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    # D1: ensure tmp ends with a newline before appending, so a previous
    # no-trailing-newline state file cannot concatenate with the new record.
    if [[ -s "$tmp" ]] && [[ -n "$(tail -c 1 "$tmp" | tr -d '\n')" ]]; then
        printf '\n' >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    grep -qxF "$record" "$tmp" 2>/dev/null || printf '%s\n' "$record" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    # R10C6-02: normalize ownership/mode BEFORE re-validating. Under
    # sudo -g <non-root-group> mktemp inherits the non-root egid, so
    # validating first rejects a file chown would have fixed. The
    # re-check still gates the mv below, so a corrupted append can
    # never become the formal state file.
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    validate_native_firewall_state_file "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ABOX_FW_STATE" || { rm -f -- "$tmp"; return 1; }
}

# R20a-L1: one shared UFW query + record parser for the three consumers
# below (rule numbers, owned-families completeness, missing-family
# foreign check). Emits one TSV record per rule line matching
# <spec>/<proto>: "number<TAB>is6<TAB>owned" (owned=1 when the trailing
# comment is exactly the A-Box ownership comment for this spec/proto).
# Returns 2 when the UFW state cannot be determined (bad spec/proto,
# missing ufw binary, failed query, or a first line other than
# `Status: active`): callers must never treat that as "absent".
_ufw_matching_rules() {
    local spec proto target expected_comment output line number body rest is6 owned
    spec=$(normalize_port_spec "$1") || return 2
    [[ "$2" == tcp || "$2" == udp ]] || return 2
    proto="$2"
    target="${spec}/${proto}"
    expected_comment="# A-Box-${spec}-${proto}"
    command -v ufw >/dev/null 2>&1 || return 2
    output=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 2
    # R3C6-06 / R20a-M1 (moved here from the three consumers): an
    # inactive UFW lists no rules, so an empty parse cannot prove
    # absence; and the liveness check must be on the same snapshot
    # that is parsed, not on a prior separate `ufw status` query.
    [[ "$(head -n 1 <<< "$output")" == 'Status: active' ]] || return 2
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]] || continue
        number="${BASH_REMATCH[1]}"
        body="${BASH_REMATCH[2]}"
        [[ "$body" == "$target"* ]] || continue
        rest="${body#"$target"}"
        is6=0
        [[ "$rest" == " (v6)"* ]] && is6=1
        rest="${rest# (v6)}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest" in
            'ALLOW IN '*) rest="${rest#ALLOW IN }" ;;
            'LIMIT IN '*) rest="${rest#LIMIT IN }" ;;
            *) continue ;;
        esac
        rest="${rest#"${rest%%[![:space:]]*}"}"
        [[ "$rest" =~ ^Anywhere([[:space:]]+\(v6\))?([[:space:]]+#.*)?$ ]] || continue
        owned=0
        if [[ "$rest" == *"$expected_comment" && "${rest##*# }" == "A-Box-${spec}-${proto}" ]]; then owned=1; fi
        printf '%s\t%s\t%s\n' "$number" "$is6" "$owned"
    done <<< "$output"
}

ufw_global_rule_numbers() {
    local owned_only="${3:-0}" records rc number is6 owned
    records=$(_ufw_matching_rules "$1" "$2"); rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    while IFS=$'\t' read -r number is6 owned || [[ -n "$number" ]]; do
        [[ -n "$number" ]] || continue
        [[ "$owned_only" == 1 && "$owned" != 1 ]] && continue
        printf '%s\n' "$number"
    done <<< "$records"
}

ufw_rule_state() {
    local numbers rc
    numbers=$(ufw_global_rule_numbers "$1" "$2" 0); rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ -n "$numbers" ]]
}

ufw_rule_exists() { ufw_rule_state "$1" "$2"; }

# M-13(1): whether UFW itself manages IPv6 rules. This is UFW's own
# IPV6= switch in /etc/default/ufw, NOT the host's IPv6 preference
# or address state (has_ipv6): a host with .ip-pref=ipv4 or no
# global v6 address can still have UFW IPv6 rules enabled, and
# gating the v6 family check on has_ipv6 let a half-owned rule pass
# verification, then die on the second install/restore. UFW defaults
# to IPV6=yes, so a missing file, a missing key, or a commented-out
# key all count as enabled.
ufw_ipv6_enabled() {
    [[ -f /etc/default/ufw ]] || return 0
    # 03d-M01: /etc/default/ufw is a shell-sourced file, so the last
    # effective assignment wins and the value may be quoted
    # (IPV6="yes" / IPV6='yes'). A missing key (or a commented-out
    # one) counts as enabled: UFW defaults to IPV6=yes. Only an
    # explicit last value of "yes" (case-insensitive) counts as
    # enabled; anything else (no, empty, garbage) is disabled.
    local _line='' _val='' _sq='' _dq=''
    _line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?IPV6[[:space:]]*=' /etc/default/ufw 2>/dev/null | tail -n 1)
    [[ -n "$_line" ]] || return 0
    _val="${_line#*=}"
    _val="${_val#${_val%%[![:space:]]*}}"
    # Quote chars via printf, not literals: a literal-quote glob
    # pattern is easy to misquote (a star inside the quotes turns
    # literal and never matches). Compare the first character
    # against the generated quote chars instead.
    _sq=$(printf '\x27'); _dq=$(printf '\x22')
    if [[ "${_val:0:1}" == "$_dq" ]]; then
        _val="${_val:1}"; _val="${_val%%\"*}"
    elif [[ "${_val:0:1}" == "$_sq" ]]; then
        _val="${_val:1}"; _val="${_val%%\'*}"
    else
        _val="${_val%%[[:space:]#]*}"
    fi
    [[ "${_val,,}" == yes ]]
}

# R5C6-03: true when the A-Box-owned rule exists for every
# applicable family (v4 always; v6 only when UFW has IPv6
# enabled). A single surviving family must not count as fully
# owned, or restore would skip replenishing the deleted
# counterpart. Parse mirrors ufw_global_rule_numbers
# (owned_only=1) but tracks families instead of numbers.
# R5C6-03: true when the A-Box-owned rule exists for every
# applicable family (v4 always; v6 only when UFW has IPv6
# enabled). A single surviving family must not count as fully
# owned, or restore would skip replenishing the deleted
# counterpart. Records come from _ufw_matching_rules (R20a-L1).
_ufw_owned_families_complete() {
    local records rc number is6 owned has4=0 has6=0
    records=$(_ufw_matching_rules "$1" "$2"); rc=$?
    [[ "$rc" == 0 ]] || return 1
    while IFS=$'\t' read -r number is6 owned || [[ -n "$number" ]]; do
        [[ -n "$number" ]] || continue
        [[ "$owned" == 1 ]] || continue
        if (( is6 )); then has6=1; else has4=1; fi
    done <<< "$records"
    (( has4 == 1 )) || return 1
    if ufw_ipv6_enabled; then (( has6 == 1 )) || return 1; fi
    return 0
}

# R5-13/R5-14: 0 = an applicable family that lacks an A-Box-owned rule
# already has a foreign same-spec rule there, 1 = the missing families
# are empty (safe to add), 2 = the UFW state could not be determined
# (never mutate blindly). Parse mirrors _ufw_owned_families_complete
# but tracks any rule per family.
# R5-13/R5-14: 0 = an applicable family that lacks an A-Box-owned rule
# already has a foreign same-spec rule there, 1 = the missing families
# are empty (safe to add), 2 = the UFW state could not be determined
# (never mutate blindly). Records come from _ufw_matching_rules (R20a-L1).
_ufw_missing_family_has_foreign() {
    local records rc number is6 owned
    local has4_owned=0 has6_owned=0 has4_any=0 has6_any=0
    records=$(_ufw_matching_rules "$1" "$2"); rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    while IFS=$'\t' read -r number is6 owned || [[ -n "$number" ]]; do
        [[ -n "$number" ]] || continue
        if (( is6 )); then has6_any=1; else has4_any=1; fi
        [[ "$owned" == 1 ]] || continue
        if (( is6 )); then has6_owned=1; else has4_owned=1; fi
    done <<< "$records"
    if (( has4_owned == 0 && has4_any == 1 )); then return 0; fi
    if ufw_ipv6_enabled; then
        if (( has6_owned == 0 && has6_any == 1 )); then return 0; fi
    fi
    return 1
}

ufw_owned_rule_exists() {
    local numbers rc
    numbers=$(ufw_global_rule_numbers "$1" "$2" 1); rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ -n "$numbers" ]]
}

ufw_delete_owned_rules() {
    local spec proto="$2" numbers
    spec=$(normalize_port_spec "$1") || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    # R11C6-01: an inactive UFW lists no rules, so an empty result
    # cannot prove the persistent rules are gone; treat it as unknown
    # state and fail, keeping the ownership record.
    if LC_ALL=C ufw status 2>/dev/null | head -n 1 | grep -q 'inactive'; then
        return 1
    fi
    numbers=$(ufw_global_rule_numbers "$spec" "$proto" 1) || return 1
    [[ -n "$numbers" ]] || return 0
    # R2C6-02: never delete by spec -- UFW matches by spec regardless
    # of comment, so a foreign same-spec rule would be deleted too.
    # Delete owned rules by number only: re-query before each delete
    # and always take the largest current owned number (deleting it
    # cannot shift lower numbers).
    local _guard=0 _fresh _max _verify
    while ufw_owned_rule_exists "$spec" "$proto"; do
        ((_guard++ < 50)) || return 1
        _fresh=$(ufw_global_rule_numbers "$spec" "$proto" 1) || return 1
        _max=$(printf '%s\n' "$_fresh" | LC_ALL=C sort -rn | sed -n '1p')
        [[ "$_max" =~ ^[0-9]+$ ]] || return 1
        # S25: re-verify _max is still owned immediately before deleting:
        # a concurrent insertion between query and delete can shift
        # numbers onto a foreign rule. On mismatch, re-query instead
        # of deleting blindly (the loop condition re-checks ownership).
        _verify=$(ufw_global_rule_numbers "$spec" "$proto" 1) || return 1
        printf '%s\n' "$_verify" | grep -qx "$_max" || continue
        ufw --force delete "$_max" >/dev/null 2>&1 || return 1
    done
    local _verify_rc
    ufw_owned_rule_exists "$spec" "$proto"; _verify_rc=$?
    # Only a confirmed absence (rc 1) is success: rules still present
    # (rc 0) and a failed verification query (rc 2) must both report
    # failure, so callers never clear ownership records on unknown state.
    # Residual TOCTOU (narrowed, not eliminated): ufw has no transaction
    # lock, so a concurrent insertion between the verify query and the
    # delete can still shift numbers onto a foreign rule. The verify
    # immediately before delete shrinks that window to a single ufw call
    # pair, mismatches retry via the loop, and the 50-round guard bounds
    # churn; any failure returns 1.
    (( _verify_rc == 1 ))
}

firewalld_zone_for_abox() {
    local zone=''
    if [[ -n "${INGRESS_IF:-}" ]] && command -v firewall-cmd >/dev/null 2>&1; then
        # S28: daemon/transient error is not "no zone": the interface's
        # real zone is unknown; never fall back to the default zone.
        # R21-FWZONE: real firewalld prints "no zone" to STDERR (not
        # stdout) with rc 2 for an interface bound to no zone (od-verified
        # on firewalld 2.3.1), so the query must capture stderr (2>&1)
        # for the check to see it. On success stderr is empty (bound case
        # prints only the zone name to stdout), so the captured zone stays
        # clean. Only that exact text falls back to the default zone; any
        # other failure (empty or other output) still returns 1.
        if ! zone=$(firewall-cmd --get-zone-of-interface="$INGRESS_IF" 2>&1); then
            [[ "$zone" == 'no zone' ]] || return 1
        fi
        [[ -n "$zone" && "$zone" != 'no zone' ]] && { printf '%s\n' "$zone"; return 0; }
    fi
    zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    [[ -n "$zone" && "$zone" != 'no zone' ]] || return 1
    printf '%s\n' "$zone"
}

firewalld_cmd_zone() {
    local zone="$1"
    [[ -n "$zone" ]] || return 2
    shift
    command firewall-cmd --zone="$zone" "$@"
}
firewalld_cmd() {
    local zone=''
    # S28: never run without --zone: an unresolved zone used to execute
    # against the implicit default zone. Return 2 (error channel, not
    # "absent") so firewalld_port_state maps it to error, never to absent.
    zone=$(firewalld_zone_for_abox 2>/dev/null) || return 2
    [[ -n "$zone" ]] || return 2
    firewalld_cmd_zone "$zone" "$@"
}

firewalld_port_state() {
    local spec proto="$2" scope="${3:-runtime}" zone="${4:-}" fw_spec rc
    spec=$(normalize_port_spec "$1") || return 2
    [[ "$proto" == tcp || "$proto" == udp ]] || return 2
    fw_spec=$(port_spec_for_firewalld "$spec") || return 2
    command -v firewall-cmd >/dev/null 2>&1 || return 2
    firewall-cmd --state >/dev/null 2>&1 || return 2
    if [[ -n "$zone" ]]; then
        if [[ "$scope" == permanent ]]; then
            command firewall-cmd --zone="$zone" --permanent --query-port="${fw_spec}/${proto}" >/dev/null 2>&1
        else
            command firewall-cmd --zone="$zone" --query-port="${fw_spec}/${proto}" >/dev/null 2>&1
        fi
    elif [[ "$scope" == permanent ]]; then
        firewalld_cmd --permanent --query-port="${fw_spec}/${proto}" >/dev/null 2>&1
    else
        firewalld_cmd --query-port="${fw_spec}/${proto}" >/dev/null 2>&1
    fi
    rc=$?
    case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# R8C6-02: print the subranges of $1/$2 not yet allowed in the $3 scope
# (runtime|permanent), one colon-form spec per line; no output means the
# whole spec is already allowed. Returns 2 when the current port list
# cannot be determined, so callers die instead of recording blindly.
firewalld_uncovered_port_specs() {
    local spec proto="$2" scope="$3" zone="${4:-}" lo hi out item pfx a b line
    local -a covered=() merged=()
    local cur_lo cur_hi m_lo m_hi c_lo c_hi cursor u_hi
    spec=$(normalize_port_spec "$1") || return 2
    [[ "$proto" == tcp || "$proto" == udp ]] || return 2
    if [[ "$spec" == *:* ]]; then lo="${spec%%:*}"; hi="${spec##*:}"; else lo="$spec"; hi="$spec"; fi
    if [[ -n "$zone" ]]; then
        if [[ "$scope" == permanent ]]; then
            out=$(firewalld_cmd_zone "$zone" --permanent --list-ports 2>/dev/null) || return 2
        elif [[ "$scope" == runtime ]]; then
            out=$(firewalld_cmd_zone "$zone" --list-ports 2>/dev/null) || return 2
        else
            return 2
        fi
    elif [[ "$scope" == permanent ]]; then
        out=$(firewalld_cmd --permanent --list-ports 2>/dev/null) || return 2
    elif [[ "$scope" == runtime ]]; then
        out=$(firewalld_cmd --list-ports 2>/dev/null) || return 2
    else
        return 2
    fi
    for item in $out; do
        [[ "$item" == */"$proto" ]] || continue
        pfx="${item%/*}"
        if [[ "$pfx" == *-* ]]; then a="${pfx%%-*}"; b="${pfx##*-}"; else a="$pfx"; b="$pfx"; fi
        [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 2
        (( 10#$a <= 10#$b )) || return 2
        covered+=("$a $b")
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r m_lo m_hi <<< "$line"
        if [[ -z "${cur_lo:-}" ]]; then cur_lo="$m_lo"; cur_hi="$m_hi"; continue; fi
        if (( 10#$m_lo <= 10#$cur_hi + 1 )); then
            (( 10#$m_hi > 10#$cur_hi )) && cur_hi="$m_hi"
        else
            merged+=("$cur_lo $cur_hi"); cur_lo="$m_lo"; cur_hi="$m_hi"
        fi
    done < <(printf '%s\n' "${covered[@]}" | sort -t' ' -k1,1n -k2,2n)
    [[ -n "${cur_lo:-}" ]] && merged+=("$cur_lo $cur_hi")
    cursor="$lo"
    for line in "${merged[@]}"; do
        read -r c_lo c_hi <<< "$line"
        (( 10#$c_hi < 10#$lo || 10#$c_lo > 10#$hi )) && continue
        if (( 10#$c_lo > 10#$cursor )); then
            u_hi=$(( 10#$c_lo - 1 ))
            if (( 10#$cursor == 10#$u_hi )); then printf '%s\n' "$cursor"; else printf '%s:%s\n' "$cursor" "$u_hi"; fi
        fi
        (( 10#$c_hi >= 10#$cursor )) && cursor=$(( 10#$c_hi + 1 ))
        (( 10#$cursor > 10#$hi )) && break
    done
    if (( 10#$cursor <= 10#$hi )); then
        if (( 10#$cursor == 10#$hi )); then printf '%s\n' "$cursor"; else printf '%s:%s\n' "$cursor" "$hi"; fi
    fi
}
remove_native_firewall_rules() {
    [[ ! -e "$ABOX_FW_STATE" && ! -L "$ABOX_FW_STATE" ]] && return 0
    validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
    local backend spec proto scope zone extra fw_spec any_failed=0 record_failed tmp
    tmp=$(mktemp "$ABOX_DIR/.firewall-native.remaining.XXXXXX") || return 1
    while IFS='|' read -r backend spec proto scope zone extra || [[ -n "$backend$spec$proto$scope$zone$extra" ]]; do
        [[ -n "$backend" ]] || continue
        record_failed=0
        case "$backend" in
            ufw)
                if ! command -v ufw >/dev/null 2>&1; then
                    record_failed=1
                elif ! ufw_delete_owned_rules "$spec" "$proto"; then
                    record_failed=1
                fi
                ;;
            firewalld)
                fw_spec=$(port_spec_for_firewalld "$spec" 2>/dev/null || true)
                if [[ -z "$fw_spec" ]] || ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
                    record_failed=1
                elif [[ "$scope" == runtime ]]; then
                    if [[ -n "$zone" ]]; then command firewall-cmd --zone="$zone" --remove-port="${fw_spec}/${proto}" >/dev/null 2>&1 || true; else firewalld_cmd --remove-port="${fw_spec}/${proto}" >/dev/null 2>&1 || true; fi
                    firewalld_port_state "$spec" "$proto" runtime "$zone"
                    [[ $? == 1 ]] || record_failed=1
                elif [[ "$scope" == permanent ]]; then
                    if [[ -n "$zone" ]]; then command firewall-cmd --zone="$zone" --permanent --remove-port="${fw_spec}/${proto}" >/dev/null 2>&1 || true; else firewalld_cmd --permanent --remove-port="${fw_spec}/${proto}" >/dev/null 2>&1 || true; fi
                    firewalld_port_state "$spec" "$proto" permanent "$zone"
                    [[ $? == 1 ]] || record_failed=1
                else
                    record_failed=1
                fi
                ;;
            *) record_failed=1 ;;
        esac
        if [[ "$record_failed" == 1 ]]; then
            if [[ -n "$zone" ]]; then
                printf '%s|%s|%s|%s|%s\n' "$backend" "$spec" "$proto" "$scope" "$zone" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
            else
                printf '%s|%s|%s|%s\n' "$backend" "$spec" "$proto" "$scope" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
            fi
            any_failed=1
        fi
    done < "$ABOX_FW_STATE"
    chown root:root "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    if [[ "$any_failed" == 1 ]]; then
        mv -f -- "$tmp" "$ABOX_FW_STATE" || { rm -f -- "$tmp"; return 1; }
        return 1
    fi
    rm -f -- "$tmp" "$ABOX_FW_STATE" || return 1
    return 0
}

forget_native_firewall_rule() {
    local raw_spec="$1" proto="$2" target_backend="$3" target_zone target_scope spec tmp kept=0 rec_backend rec_spec rec_proto rec_scope rec_zone _rec_extra zone_given=0 scope_given=0
    # R3C6-07: a 4th/5th argument, when provided (even empty), restricts
    # the match to that exact zone/scope; when omitted, that dimension
    # matches all. A caller that rolled back one record must pass that
    # record's zone and scope, or it would also forget other live rules.
    if [[ $# -ge 4 ]]; then target_zone="$4"; zone_given=1; fi
    if [[ $# -ge 5 ]]; then target_scope="$5"; scope_given=1; fi
    spec=$(normalize_port_spec "$raw_spec") || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    [[ "$target_backend" == ufw || "$target_backend" == firewalld || "$target_backend" == iptables ]] || return 1
    [[ ! -e "$ABOX_FW_STATE" && ! -L "$ABOX_FW_STATE" ]] && return 0
    validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
    tmp=$(mktemp "$ABOX_DIR/.firewall-native.forget.XXXXXX") || return 1
    while IFS='|' read -r rec_backend rec_spec rec_proto rec_scope rec_zone _rec_extra || [[ -n "$rec_backend$rec_spec$rec_proto$rec_scope$rec_zone$_rec_extra" ]]; do
        # Empty lines are legal in the state file (the validator skips
        # them); without this skip they would be rewritten as '|||'
        # records and poison the whole file on the next validation.
        [[ -n "$rec_backend$rec_spec$rec_proto$rec_scope$rec_zone$_rec_extra" ]] || continue
        if [[ "$rec_backend" == "$target_backend" && "$rec_spec" == "$spec" && "$rec_proto" == "$proto" ]]; then
            if (( zone_given == 0 )) || [[ "$rec_zone" == "$target_zone" ]]; then
                if (( scope_given == 0 )) || [[ "$rec_scope" == "$target_scope" ]]; then
                    continue
                fi
            fi
        fi
        if [[ -n "$rec_zone" ]]; then
            printf '%s|%s|%s|%s|%s\n' "$rec_backend" "$rec_spec" "$rec_proto" "$rec_scope" "$rec_zone" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
        else
            printf '%s|%s|%s|%s\n' "$rec_backend" "$rec_spec" "$rec_proto" "$rec_scope" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
        kept=1
    done < "$ABOX_FW_STATE"
    chown root:root "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    if (( kept == 1 )); then
        mv -f -- "$tmp" "$ABOX_FW_STATE" || { rm -f -- "$tmp"; return 1; }
    else
        rm -f -- "$tmp" "$ABOX_FW_STATE" || return 1
    fi
    return 0
}

# M-12(2): Hy2 HTTP-01 shares the A-Box 80/tcp opening with Wallos:
# both are recorded under the same "A-Box-80-tcp" comment, so refusing
# a Wallos opening (or rolling a Wallos rule back) would also delete
# the port Hy2 ACME renewal needs. Keep 80/tcp while Hy2 HTTP-01 is
# enabled and its certificate still needs renewal: no cert on disk
# yet (HTTP-01 must be able to run to obtain one), unreadable, or
# expiring within the 30-day renewal window. A cert valid beyond the
# window does not need the port right now.
hy2_http01_port_still_needed() {
    local cert=''
    hy2_http01_enabled || return 1
    for cert in /etc/hysteria/server.crt /etc/sing-box/hy2.crt; do
        [[ -f "$cert" && ! -L "$cert" ]] || continue
        command -v openssl >/dev/null 2>&1 || return 0
        if openssl x509 -in "$cert" -noout -checkend 2592000 2>/dev/null; then
            return 1
        else
            return 0
        fi
    done
    return 0
}

remove_abox_native_firewall_rule() {
    local raw_spec="$1" proto="$2" spec backend fw_spec failed=0 record _backend _spec _proto _scope _zone _extra
    local _target_scope='' _target_zone='' _scope_given=0 _zone_given=0
    # R11-B (R7-1): optional scope/zone restriction. When given (even
    # empty), that dimension matches exactly; when omitted, it matches
    # all (same "provided means restrict" convention as
    # forget_native_firewall_rule). An explicit empty/illegal scope or
    # a non-empty illegal zone fails instead of degrading to unscoped.
    if [[ $# -ge 3 ]]; then _target_scope="$3"; _scope_given=1; fi
    if [[ $# -ge 4 ]]; then _target_zone="$4"; _zone_given=1; fi
    if (( _scope_given == 1 )) && [[ "$_target_scope" != runtime && "$_target_scope" != permanent ]]; then return 1; fi
    if (( _zone_given == 1 )) && [[ -n "$_target_zone" ]] && [[ ! "$_target_zone" =~ ^[A-Za-z0-9_.:@+-]+$ ]]; then return 1; fi
    spec=$(normalize_port_spec "$raw_spec") || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    # M-12(2): never delete the shared 80/tcp opening while Hy2
    # HTTP-01 renewal still needs it; report success (the port stays
    # open, which is what the renewal wants).
    if [[ "$spec" == 80 && "$proto" == tcp ]] && hy2_http01_port_still_needed; then
        msg "${YELLOW}[!] Keeping 80/tcp: still needed by Hy2 HTTP-01 certificate renewal.${NC}" >&2
        return 0
    fi
    backend=$(firewall_backend) || return 1
    case "$backend" in
        ufw)
            (( _scope_given == 0 && _zone_given == 0 )) || return 1
            if [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]]; then
                validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
                while IFS='|' read -r _backend _spec _proto _scope _zone _extra || [[ -n "$_backend$_spec$_proto$_scope$_zone$_extra" ]]; do
                    [[ "$_spec" == "$spec" && "$_proto" == "$proto" && "$_backend" == ufw ]] || continue
                    [[ "$_scope" == rule && -z "$_zone" && -z "$_extra" ]] || return 1
                    ufw_delete_owned_rules "$spec" "$proto" || return 1
                    break
                done < "$ABOX_FW_STATE"
                forget_native_firewall_rule "$spec" "$proto" ufw "" "rule" || return 1
            fi
            return 0
            ;;
        firewalld)
            [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]] || return 0
            validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
            # R5-11: two passes. Pass 1 only selects and pre-checks: a
            # record that merely overlaps the request (partial overlap)
            # is rejected BEFORE anything is deleted; pass 2 then
            # deletes, verifies and forgets each selected record by
            # its own spec/zone/scope. No overlap -> idempotent success.
            local _req_lo _req_hi _lo _hi _rec _sirc _record_fw_spec
            local -a _selected=() _args=()
            _req_lo=${spec%%:*}; _req_hi=${spec##*:}
            _req_lo=$((10#$_req_lo)); _req_hi=$((10#$_req_hi))
            while IFS='|' read -r _backend _spec _proto _scope _zone _extra || [[ -n "$_backend$_spec$_proto$_scope$_zone$_extra" ]]; do
                [[ "$_backend" == firewalld && "$_proto" == "$proto" ]] || continue
                [[ "$_scope" == runtime || "$_scope" == permanent ]] || return 1
                if (( _scope_given == 1 )) && [[ "$_scope" != "$_target_scope" ]]; then
                    continue
                fi
                if (( _zone_given == 1 )) && [[ "$_zone" != "$_target_zone" ]]; then
                    continue
                fi
                _lo=${_spec%%:*}; _hi=${_spec##*:}
                _lo=$((10#$_lo)); _hi=$((10#$_hi))
                (( _lo <= _req_hi && _hi >= _req_lo )) || continue
                if (( _lo < _req_lo || _hi > _req_hi )); then
                    return 1
                fi
                # R20b-M01: never delete the shared 80/tcp opening while
                # Hy2 HTTP-01 renewal still needs it, even when the
                # request is a range that contains it (the top gate only
                # catches an exact-80 request). Skip just the protected
                # record; the rest of the range is still deleted, and the
                # skipped record stays registered (its rule stays live).
                if [[ "$proto" == tcp && "$_spec" == 80 ]] && hy2_http01_port_still_needed; then
                    continue
                fi
                _selected+=("$_spec|$_scope|$_zone")
            done < "$ABOX_FW_STATE"
            for _rec in "${_selected[@]}"; do
                IFS='|' read -r _spec _scope _zone <<< "$_rec"
                firewall-cmd --state >/dev/null 2>&1 || return 1
                _record_fw_spec=$(port_spec_for_firewalld "$_spec") || return 1
                _args=("--remove-port=${_record_fw_spec}/${proto}")
                if [[ "$_scope" == permanent ]]; then
                    _args=(--permanent "${_args[@]}")
                fi
                if [[ -n "$_zone" ]]; then
                    firewall-cmd --zone="$_zone" "${_args[@]}" >/dev/null 2>&1 || true
                else
                    firewalld_cmd "${_args[@]}" >/dev/null 2>&1 || true
                fi
                if firewalld_port_state "$_spec" "$proto" "$_scope" "$_zone"; then
                    _sirc=0
                else
                    _sirc=$?
                fi
                if (( _sirc == 1 )); then
                    forget_native_firewall_rule "$_spec" "$proto" firewalld "$_zone" "$_scope" || failed=1
                else
                    failed=1
                fi
            done
            (( failed == 0 )) || return 1
            ;;
        iptables)
            (( _scope_given == 0 && _zone_given == 0 )) || return 1
            local comment="A-Box-${spec}-${proto}" cmd check_rc
            for cmd in "$IPT" "$IPT6"; do
                [[ "$cmd" == "$IPT" || -x "$cmd" || -n "$(command -v "$cmd" 2>/dev/null)" ]] || continue
                if [[ "$cmd" == "$IPT6" ]]; then
                    # S27: binary missing: this script could not have built
                    # v6 rules; skip (accepted narrow residue: the binary
                    # was removed after the rules were built).
                    command -v ip6tables >/dev/null 2>&1 || continue
                    # S27: query failure (permission/lock/module) means v6
                    # rules may still be present; never report success.
                    # R4C6-03: excuse only when IPv6 is confirmed
                    # unusable (kernel-disabled): then no v6 rules can
                    # exist to delete.
                    if ! _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                        if host_has_usable_ipv6; then return 1; fi
                        continue
                    fi
                fi
                while :; do
                    if iptables_rule_check "$cmd" INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in
                        0) _iptables_do "$cmd" -D INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT >/dev/null 2>&1 || return 1 ;;
                        1) break ;;
                        *) return 1 ;;
                    esac
                done
                iptables_rule_check "$cmd" INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT
                [[ $? == 1 ]] || return 1
            done
            ;;
        *) return 1 ;;
    esac
    if [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]]; then
        validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
    fi
    return 0
}

apply_native_firewall_rules_from_state() {
    [[ ! -e "$ABOX_FW_STATE" && ! -L "$ABOX_FW_STATE" ]] && return 0
    validate_native_firewall_state_file "$ABOX_FW_STATE" || return 1
    local backend spec proto scope zone extra fw_spec failed=0 _orc=0 _rrc=0 backend_out=''
    # R5-12: a failed backend probe prints nothing, so the old text-only
    # test passed an empty string through this gate. Require rc 0 too.
    backend_out=$(firewall_backend 2>/dev/null) || return 1
    [[ -n "$backend_out" && "$backend_out" != 'nftables-unsupported' ]] || return 1
    while IFS='|' read -r backend spec proto scope zone extra || [[ -n "$backend$spec$proto$scope$zone$extra" ]]; do
        [[ -n "$backend" ]] || continue
        case "$backend" in
            ufw)
                if ! command -v ufw >/dev/null 2>&1; then failed=1; continue; fi
                ufw_owned_rule_exists "$spec" "$proto"; _orc=$?
                if (( _orc == 0 )); then
                    # R5C6-03: owned means ANY family survives; a
                    # deleted v6 counterpart must still be restored.
                    # Only skip when every applicable family is present.
                    if _ufw_owned_families_complete "$spec" "$proto"; then
                        :
                    else
                        # R5-13: re-running `ufw allow` here would adopt
                        # a foreign same-spec rule in the missing family
                        # by rewriting its comment to A-Box. After
                        # completing, verify ALL families, not just any.
                        local _foreign_rc=0
                        if _ufw_missing_family_has_foreign "$spec" "$proto"; then
                            _foreign_rc=0
                        else
                            _foreign_rc=$?
                        fi
                        case "$_foreign_rc" in
                            1)
                                ufw allow proto "$proto" from any to any port "$spec" comment "A-Box-${spec}-${proto}" >/dev/null 2>&1 || { failed=1; continue; }
                                _ufw_owned_families_complete "$spec" "$proto" || { failed=1; continue; }
                                ;;
                            *)
                                failed=1
                                continue
                                ;;
                        esac
                    fi
                elif (( _orc == 2 )); then
                    # R3C6-06: unknown UFW state; never mutate on a blind "absent".
                    failed=1; continue
                else
                    ufw_rule_exists "$spec" "$proto"; _rrc=$?
                    if (( _rrc == 0 )); then
                        # A foreign equivalent rule must never be adopted as A-Box-owned.
                        failed=1
                        continue
                    elif (( _rrc == 2 )); then
                        failed=1; continue
                    else
                        ufw allow proto "$proto" from any to any port "$spec" comment "A-Box-${spec}-${proto}" >/dev/null 2>&1 || { failed=1; continue; }
                        # 03d-M02: first creation must verify ALL
                        # families, not just any: a single surviving
                        # family must not count as success, or the
                        # deleted counterpart is never replenished.
                        _ufw_owned_families_complete "$spec" "$proto" || { failed=1; continue; }
                    fi
                fi
                ;;
            firewalld)
                fw_spec=$(port_spec_for_firewalld "$spec") || { failed=1; continue; }
                command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 || { failed=1; continue; }
                if [[ "$scope" == runtime ]]; then
                    firewalld_port_state "$spec" "$proto" runtime "$zone"
                    case $? in
                        0) : ;;
                        1) if [[ -n "$zone" ]]; then command firewall-cmd --zone="$zone" --add-port="${fw_spec}/${proto}" >/dev/null 2>&1; else firewalld_cmd --add-port="${fw_spec}/${proto}" >/dev/null 2>&1; fi || { failed=1; continue; } ;;
                        *) failed=1; continue ;;
                    esac
                    firewalld_port_state "$spec" "$proto" runtime "$zone" || failed=1
                elif [[ "$scope" == permanent ]]; then
                    firewalld_port_state "$spec" "$proto" permanent "$zone"
                    case $? in
                        0) : ;;
                        1) if [[ -n "$zone" ]]; then command firewall-cmd --zone="$zone" --permanent --add-port="${fw_spec}/${proto}" >/dev/null 2>&1; else firewalld_cmd --permanent --add-port="${fw_spec}/${proto}" >/dev/null 2>&1; fi || { failed=1; continue; } ;;
                        *) failed=1; continue ;;
                    esac
                    firewalld_port_state "$spec" "$proto" permanent "$zone" || failed=1
                else
                    failed=1
                fi
                ;;
            *) failed=1 ;;
        esac
    done < "$ABOX_FW_STATE"
    (( failed == 0 ))
}

iptables_rule_check() {
    local cmd="$1" rc; shift
    if _iptables_q "$cmd" -C "$@" 2>/dev/null; then
        return 0
    else
        rc=$?
    fi
    case "$rc" in
        1) return 1 ;;
        *) return 2 ;;
    esac
}
# F12: removed zero-call restore_iptables_saved_snapshot (duplicate dead code)

allowPort() {
    local raw_port="$1" type="${2:-tcp}" backend spec fw_spec runtime=0 permanent=0 added_runtime=0 _orc=0 _rrc=0 _zone='' _uncovered_out='' _sub='' _rec_failed=0 _rb_failed=0 _sirc=0
    local _before_numbers='' _after_numbers='' _rb_num=''
    local -a _uncovered_runtime=() _uncovered_permanent=()
    spec=$(normalize_port_spec "$raw_port") || die "$(tprintf fw2_bad_port "$raw_port")"
    [[ "$type" == tcp || "$type" == udp ]] || die "$(tprintf fw2_bad_proto "$type")"
    backend=$(firewall_backend)
    case "$backend" in
        iptables|ufw|firewalld) ;;
        *) die "$(tprintf fw2_nft "$backend")" ;;
    esac
    case "$backend" in
        ufw)
            ufw_owned_rule_exists "$spec" "$type"; _orc=$?
            if (( _orc == 0 )); then
                # R5-14: owned in one family is not complete; complete
                # the other family, unless it holds a foreign rule or
                # its state is unknown (die either way: the record has
                # no family dimension, so a partial success cannot be
                # recorded honestly). Verify ALL families afterwards.
                if ! _ufw_owned_families_complete "$spec" "$type"; then
                    local _foreign_rc=0
                    if _ufw_missing_family_has_foreign "$spec" "$type"; then
                        _foreign_rc=0
                    else
                        _foreign_rc=$?
                    fi
                    case "$_foreign_rc" in
                        1)
                            # R20b-M02: snapshot the owned rule numbers
                            # before completing the missing family, so a
                            # later record failure can roll back ONLY the
                            # rule this call added (the pre-existing
                            # family's rule must survive: a blanket
                            # ufw_delete_owned_rules would delete it too).
                            _before_numbers=$(ufw_global_rule_numbers "$spec" "$type" 1 2>/dev/null || true)
                            ufw allow proto "$type" from any to any port "$spec" comment "A-Box-${spec}-${type}" >/dev/null 2>&1 || die "$(tprintf fw2_ufw_allow "${spec}/${type}")"
                            _ufw_owned_families_complete "$spec" "$type" || die "$(tprintf fw2_ufw_verify "${spec}/${type}")"
                            ;;
                        0)
                            die "$(tprintf fw2_ufw_partial_foreign "${spec}/${type}")"
                            ;;
                        *)
                            die "$(tprintf fw2_ufw_unknown "${spec}/${type}")"
                            ;;
                    esac
                fi
                if ! record_native_firewall_rule ufw "$spec" "$type" rule; then
                    # R20b-M02: the record failed after this call added
                    # the missing family: roll back ONLY the newly added
                    # rule(s) (owned numbers not present before the
                    # completion), largest-first so lower numbers do not
                    # shift. When no completion happened (_before_numbers
                    # empty) there is nothing to roll back. A failed
                    # rollback still dies below; the record failure is
                    # reported either way.
                    if [[ -n "$_before_numbers" ]]; then
                        _after_numbers=$(ufw_global_rule_numbers "$spec" "$type" 1 2>/dev/null || true)
                        for _rb_num in $(printf '%s\n' $_after_numbers | LC_ALL=C sort -rn); do
                            printf '%s\n' "$_before_numbers" | grep -qx "$_rb_num" || ufw --force delete "$_rb_num" >/dev/null 2>&1 || true
                        done
                    fi
                    die "$(tr_msg fw2_ufw_record)"
                fi
            elif (( _orc == 2 )); then
                die "$(tprintf fw2_ufw_unknown "${spec}/${type}")"
            else
                ufw_rule_exists "$spec" "$type"; _rrc=$?
                if (( _rrc == 0 )); then
                    msg "${YELLOW}[!] $(tprintf allowport_ufw_global_rule "${spec}" "${type}")${NC}"
                elif (( _rrc == 2 )); then
                    die "$(tprintf fw2_ufw_unknown "${spec}/${type}")"
                else
                    ufw allow proto "$type" from any to any port "$spec" comment "A-Box-${spec}-${type}" >/dev/null 2>&1 || die "$(tprintf fw2_ufw_allow "${spec}/${type}")"
                    # 03d-M02: first creation must verify ALL
                    # families, not just any: a single surviving
                    # family is a failed install, compensated by
                    # deleting the partial rule, never recorded.
                    if ! _ufw_owned_families_complete "$spec" "$type"; then
                        ufw_delete_owned_rules "$spec" "$type" >/dev/null 2>&1 || true
                        die "$(tprintf fw2_ufw_verify "${spec}/${type}")"
                    fi
                    if ! record_native_firewall_rule ufw "$spec" "$type" rule; then
                        ufw_delete_owned_rules "$spec" "$type" >/dev/null 2>&1 || true
                        die "$(tprintf fw2_ufw_record_rb "${spec}/${type}")"
                    fi
                fi
            fi
            return 0
            ;;
        firewalld)
            fw_spec=$(port_spec_for_firewalld "$spec") || die "$(tprintf fw2_fwd_convert "$spec")"
            # R9C6-01: pin the zone once for the whole operation.
            # Resolving it per call lets a mid-operation default-zone
            # change record an A-zone add as B-zone owned (and later
            # delete B's foreign rule while leaving the A opening).
            _zone=$(firewalld_zone_for_abox) || die "$(tr_msg fw2_fwd_runtime_q)"
            firewalld_port_state "$spec" "$type" runtime "$_zone"
            case $? in 0) runtime=1 ;; 1) runtime=0 ;; *) die "$(tr_msg fw2_fwd_runtime_q)" ;; esac
            firewalld_port_state "$spec" "$type" permanent "$_zone"
            case $? in 0) permanent=1 ;; 1) permanent=0 ;; *) die "$(tr_msg fw2_fwd_perm_q)" ;; esac
            if [[ "$runtime" == 0 ]]; then
                # R8C6-02: firewalld coalesces an added range with
                # already-allowed ports, so recording the whole range
                # would claim (and later delete) foreign allowances.
                # Snapshot the not-yet-allowed subranges first; only
                # those are recorded and, on rollback, removed.
                _uncovered_out=$(firewalld_uncovered_port_specs "$spec" "$type" runtime "$_zone") || die "$(tr_msg fw2_fwd_runtime_q)"
                _uncovered_runtime=()
                while IFS= read -r _sub; do [[ -n "$_sub" ]] && _uncovered_runtime+=("$_sub"); done <<< "$_uncovered_out"
                if (( ${#_uncovered_runtime[@]} == 0 )); then die "$(tr_msg fw2_fwd_runtime_q)"; fi
                firewalld_cmd_zone "$_zone" --add-port="${fw_spec}/${type}" >/dev/null 2>&1 || die "$(tprintf fw2_fwd_runtime_add "${fw_spec}/${type}")"
                added_runtime=1
                _rec_failed=0
                for _sub in "${_uncovered_runtime[@]}"; do
                    record_native_firewall_rule firewalld "$_sub" "$type" runtime "$_zone" || { _rec_failed=1; break; }
                done
                if (( _rec_failed == 1 )); then
                    # R5-15: mirror the permanent 2qp rollback: verify
                    # each runtime port is really gone, forget its
                    # record only then; a failed forget still counts
                    # as rollback failure (do not swallow it).
                    _rb_failed=0
                    for _sub in "${_uncovered_runtime[@]}"; do
                        _rrc=0
                        firewalld_cmd_zone "$_zone" --remove-port="$(port_spec_for_firewalld "$_sub")/${type}" >/dev/null 2>&1 || _rrc=1
                        if firewalld_port_state "$_sub" "$type" runtime "$_zone"; then
                            _sirc=0
                        else
                            _sirc=$?
                        fi
                        if (( _rrc == 0 && _sirc == 1 )); then
                            forget_native_firewall_rule "$_sub" "$type" firewalld "$_zone" runtime >/dev/null 2>&1 || _rb_failed=1
                        else
                            _rb_failed=1
                        fi
                    done
                    if (( _rb_failed == 1 )); then
                        msg "${YELLOW}$(tprintf fw2_fwd_rb_fail "${fw_spec}/${type}")${NC}"
                    fi
                    die "$(tr_msg fw2_fwd_runtime_record)"
                fi
            fi
            if [[ "$permanent" == 0 ]]; then
                _uncovered_out=$(firewalld_uncovered_port_specs "$spec" "$type" permanent "$_zone") || die "$(tr_msg fw2_fwd_perm_q)"
                _uncovered_permanent=()
                while IFS= read -r _sub; do [[ -n "$_sub" ]] && _uncovered_permanent+=("$_sub"); done <<< "$_uncovered_out"
                if (( ${#_uncovered_permanent[@]} == 0 )); then die "$(tr_msg fw2_fwd_perm_q)"; fi
                if ! firewalld_cmd_zone "$_zone" --permanent --add-port="${fw_spec}/${type}" >/dev/null 2>&1; then
                    if [[ "$added_runtime" == 1 ]]; then
                        # R15C6-02: forget a runtime record only after its
                        # removal succeeded AND absence is confirmed
                        # (state query == 1). A failed removal keeps its
                        # record, or the still-open port becomes untracked.
                        _rb_failed=0
                        for _sub in "${_uncovered_runtime[@]}"; do
                            _rrc=0
                            firewalld_cmd_zone "$_zone" --remove-port="$(port_spec_for_firewalld "$_sub")/${type}" >/dev/null 2>&1 || _rrc=1
                            firewalld_port_state "$_sub" "$type" runtime "$_zone"; _sirc=$?
                            if (( _rrc == 0 && _sirc == 1 )); then
                                forget_native_firewall_rule "$_sub" "$type" firewalld "$_zone" "runtime" >/dev/null 2>&1 || _rb_failed=1
                            else
                                _rb_failed=1
                            fi
                        done
                        if (( _rb_failed == 1 )); then
                            msg "${YELLOW}$(tprintf fw2_fwd_rb_fail "${fw_spec}/${type}")${NC}"
                        fi
                    fi
                    die "$(tprintf fw2_fwd_perm_add "${fw_spec}/${type}")"
                fi
                _rec_failed=0
                for _sub in "${_uncovered_permanent[@]}"; do
                    record_native_firewall_rule firewalld "$_sub" "$type" permanent "$_zone" || { _rec_failed=1; break; }
                done
                if (( _rec_failed == 1 )); then
                    # 2qp: mirror the R15C6-02 runtime gate for the
                    # permanent records — forget a permanent record only
                    # after its removal succeeded AND absence is
                    # confirmed (state query == 1). A failed removal
                    # keeps its record; a later cleanup finds the port
                    # already absent and forgets the stale record.
                    _rb_failed=0
                    for _sub in "${_uncovered_permanent[@]}"; do
                        _rrc=0
                        firewalld_cmd_zone "$_zone" --permanent --remove-port="$(port_spec_for_firewalld "$_sub")/${type}" >/dev/null 2>&1 || _rrc=1
                        firewalld_port_state "$_sub" "$type" permanent "$_zone"; _sirc=$?
                        if (( _rrc == 0 && _sirc == 1 )); then
                            forget_native_firewall_rule "$_sub" "$type" firewalld "$_zone" "permanent" >/dev/null 2>&1 || _rb_failed=1
                        else
                            _rb_failed=1
                        fi
                    done
                    if (( _rb_failed == 1 )); then
                        msg "${YELLOW}$(tprintf fw2_fwd_rb_fail "${fw_spec}/${type}")${NC}"
                    fi
                    if [[ "$added_runtime" == 1 ]]; then
                        # R15C6-02: forget a runtime record only after its
                        # removal succeeded AND absence is confirmed
                        # (state query == 1). A failed removal keeps its
                        # record, or the still-open port becomes untracked.
                        _rb_failed=0
                        for _sub in "${_uncovered_runtime[@]}"; do
                            _rrc=0
                            firewalld_cmd_zone "$_zone" --remove-port="$(port_spec_for_firewalld "$_sub")/${type}" >/dev/null 2>&1 || _rrc=1
                            firewalld_port_state "$_sub" "$type" runtime "$_zone"; _sirc=$?
                            if (( _rrc == 0 && _sirc == 1 )); then
                                forget_native_firewall_rule "$_sub" "$type" firewalld "$_zone" "runtime" >/dev/null 2>&1 || _rb_failed=1
                            else
                                _rb_failed=1
                            fi
                        done
                        if (( _rb_failed == 1 )); then
                            msg "${YELLOW}$(tprintf fw2_fwd_rb_fail "${fw_spec}/${type}")${NC}"
                        fi
                    fi
                    die "$(tr_msg fw2_fwd_perm_record)"
                fi
            fi
            firewalld_port_state "$spec" "$type" runtime "$_zone" || die "$(tr_msg fw2_fwd_runtime_verify)"
            firewalld_port_state "$spec" "$type" permanent "$_zone" || die "$(tr_msg fw2_fwd_perm_verify)"
            return 0
            ;;
    esac
    # R3C6-08: when the host has IPv6, the v6 rule is required, not
    # optional. Fail BEFORE touching IPv4 if ip6tables is missing or
    # the v6 table cannot be queried, instead of silently skipping v6
    # and reporting success with the port still unreachable over v6.
    if has_ipv6; then
        command -v ip6tables >/dev/null 2>&1 || die "$(tprintf fw2_v6_missing "${spec}/${type}")"
        _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1 || die "$(tprintf fw2_v6_check "${spec}/${type}")"
    fi
    local check_rc=0
    if iptables_rule_check "$IPT" INPUT -p "$type" --dport "$spec" -m comment --comment "A-Box-${spec}-${type}" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
    case "$check_rc" in
        0) ;;
        1) _iptables_do "$IPT" -I INPUT -p "$type" --dport "$spec" -m comment --comment "A-Box-${spec}-${type}" -j ACCEPT >/dev/null 2>&1 || die "$(tprintf fw2_v4_allow "${spec}/${type}")" ;;
        *) die "$(tprintf fw2_v4_check "${spec}/${type}")" ;;
    esac
    # R16-F06-04: the second v6 query (after the IPv4 change) must fail
    # the function, like the pre-check above -- never silently skip v6 and
    # report success with the port still unreachable over v6.
    if has_ipv6; then
        command -v ip6tables >/dev/null 2>&1 || die "$(tprintf fw2_v6_missing "${spec}/${type}")"
        _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1 || die "$(tprintf fw2_v6_check "${spec}/${type}")"
        if iptables_rule_check "$IPT6" INPUT -p "$type" --dport "$spec" -m comment --comment "A-Box-${spec}-${type}" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
        case "$check_rc" in
            0) ;;
            1) _iptables_do "$IPT6" -I INPUT -p "$type" --dport "$spec" -m comment --comment "A-Box-${spec}-${type}" -j ACCEPT >/dev/null 2>&1 || die "$(tprintf fw2_v6_allow "${spec}/${type}")" ;;
            *) die "$(tprintf fw2_v6_check "${spec}/${type}")" ;;
        esac
    fi
}

remove_ss_open_accept_rules() {
    local proto failed=0 comment check_rc
    [[ -n "${SS_PORT:-}" ]] || return 0
    for proto in tcp udp; do
        comment="A-Box-${SS_PORT}-${proto}"
        while :; do
            if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
            case "$check_rc" in
                0) ;;
                1) break ;;
                *) failed=1; break ;;
            esac
            _iptables_do "$IPT" -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT >/dev/null 2>&1 || { failed=1; break; }
        done
        if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
        [[ "$check_rc" == 1 ]] || failed=1
        if ! command -v ip6tables >/dev/null 2>&1; then
            # S27: binary missing: this script could not have built v6
            # rules; skip the v6 segment (accepted narrow residue: the
            # binary was removed after the rules were built).
            :
        elif ! _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
            # S27: query failure (permission/lock/module) means v6 rules
            # may still be present; never report the cleanup as done.
            # R16-F06-07: no address evidence can excuse this -- having
            # no IPv6 address does not prove the kernel has no IPv6
            # firewall or no leftover rules.
            failed=1
        else
            while :; do
                if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                case "$check_rc" in
                    0) ;;
                    1) break ;;
                    *) failed=1; break ;;
                esac
                _iptables_do "$IPT6" -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT >/dev/null 2>&1 || { failed=1; break; }
            done
            if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
            [[ "$check_rc" == 1 ]] || failed=1
        fi
    done
    (( failed == 0 ))
}

__abox_normalize_managed_rule_line() {
    local line="$1"
    line=${line//\"/}
    # H-12: no backreferences in ERE (musl treats \3 as literal '3');
    # one plain -e per protocol instead of a shared \3 group.
    line=$(printf '%s\n' "$line" | sed -E -e 's/(^|[[:space:]])-p[[:space:]]+tcp[[:space:]]+-m[[:space:]]+tcp([[:space:]]|$)/\1-p tcp\2/' -e 's/(^|[[:space:]])-p[[:space:]]+udp[[:space:]]+-m[[:space:]]+udp([[:space:]]|$)/\1-p udp\2/')
    printf '%s\n' "$line"
}

# D-01: main-script copy of __abox_firewall_unlock (heredoc copy at L3032 is
# written to firewall_restore.sh and never executed by the main shell).
# $1 = lock fd value. Closes it; caller clears its own lock_fd variable.
__abox_firewall_unlock() {
    local lock_fd="$1"
    # Guard empty lock_fd: `exec >&-` would close stdout.
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        eval "exec ${lock_fd}>&-" 2>/dev/null || true
    fi
}

reorder_ss_whitelist_rules_one() {
    local cmd="$1" port="$2" proto="$3" wl_suffix="$4" drop_suffix="$5"
    local wl_comment="A-Box-${port}-${proto}-${wl_suffix}" drop_comment="A-Box-${port}-${proto}-${drop_suffix}"
    local wl_re="--comment[[:space:]]+\"?${wl_comment}(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)" drop_re="--comment[[:space:]]+\"?${drop_comment}(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)"
    local save_cmd="${cmd}-save" rules_output='' recovery_snapshot='' lock_file=/run/A-Box-firewall-reorder.lock lock_fd=''
    local original_rules_output='' current_rules_output='' current_line line i j n rule_no target_idx del_idx check_rc=0 mutated=0
    # R9 (F06-2, 加固): temporary markers distinguish the copies this
    # transaction inserts from pre-existing identical copies, so a
    # content delete can never remove the wrong twin. See P1'/P2'/P4'/P5'.
    local _tmp_marker="A-Box-tmp-$$-$RANDOM$RANDOM" _marked_line='' _marked_drop_line='' _delete_norm=''
    local -a _tmp_lines=()
    local current_interleave='' original_interleave='' expected_interleave=''
    local -a rules=() argv=() current_lines=() delete_lines=() delete_target_indices=() delete_rule_numbers=()
    local -A _rules_seen=()
    local _stripped_rule=''
    local -a original_target_lines=() original_target_positions=() expected_target_lines=()
    local -a current_target_lines=() current_foreign_lines=() original_foreign_rules=()

    # S54 (argon P3-2): unload the nested helpers on every return path
    # (RETURN trap fires once, when this function returns -- not on
    # nested calls -- and unset -f on an undefined name is harmless,
    # so early returns before the definitions below are safe).
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    local _reorder_caller_trap=''
    _reorder_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'unset -f capture_firewall_views firewall_state_matches_expected firewall_rollback firewall_rollback_inner _marked_line_for _expected_remove_first; if [[ -n "${_reorder_caller_trap:-}" ]]; then eval "$_reorder_caller_trap"; else trap - RETURN; fi; true' RETURN

    command -v "$cmd" >/dev/null 2>&1 || return 0
    command -v "$save_cmd" >/dev/null 2>&1 || return 1
    if ! _iptables_q "$cmd" -S INPUT >/dev/null 2>&1; then
        if [[ "${cmd##*/}" == ip6tables ]] && ! host_has_usable_ipv6; then return 0; fi
        return 1
    fi
    if iptables_rule_check "$cmd" INPUT -p "$proto" --dport "$port" -m comment --comment "$drop_comment" -j DROP; then check_rc=0; else check_rc=$?; fi
    if (( check_rc == 1 )); then
        # R26 (F06-2): the -C check above only recognises the
        # canonical DROP. After an interrupted run only
        # tmp-marked copies may remain (P4' deleted the
        # canonical rules, P5' never ran); reorder_policy's
        # scan still triggers on them, so a tmp-marked DROP is
        # also a reason to proceed and rebuild the canonical
        # rules. No DROP of either form means nothing to do.
        # A failed scan query fails closed (return 1).
        local _scan_out='' _scan_rc=0 _scan_line _found_tmp_drop=0
        _scan_out=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || _scan_rc=$?
        if (( _scan_rc != 0 )); then return 1; fi
        while IFS= read -r _scan_line; do
            if [[ "$_scan_line" =~ $drop_re ]]; then _found_tmp_drop=1; break; fi
        done <<< "$_scan_out"
        if (( _found_tmp_drop )); then check_rc=0; fi
    fi
    case "$check_rc" in 0) ;; 1) return 0 ;; *) return 1 ;; esac

    [[ -d /run && ! -L /run ]] || return 1
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
        [[ "$(stat -c %u:%g "$lock_file" 2>/dev/null || true)" == 0:0 ]] || return 1
        local lock_mode
        lock_mode=$(stat -c %a "$lock_file" 2>/dev/null) || return 1
        if [[ "$lock_mode" =~ ^[0-7]{3,4}$ ]]; then
            (( (8#$lock_mode & 8#077) == 0 )) || return 1
        else
            return 1
        fi
    else
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || return 1
    fi
    # Open+flock before chown/chmod so the critical section starts immediately.
    exec {lock_fd}>>"$lock_file" || return 1
    flock -n "$lock_fd" || { [[ "$lock_fd" =~ ^[0-9]+$ ]] && eval "exec ${lock_fd}>&-"; return 1; }
    chown root:root "$lock_file" 2>/dev/null || { [[ "$lock_fd" =~ ^[0-9]+$ ]] && eval "exec ${lock_fd}>&-"; rm -f -- "$lock_file"; return 1; }
    chmod 600 "$lock_file" 2>/dev/null || { [[ "$lock_fd" =~ ^[0-9]+$ ]] && eval "exec ${lock_fd}>&-"; rm -f -- "$lock_file"; return 1; }

    capture_firewall_views() {
        local item normalized
        current_rules_output=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || return 1
        current_target_lines=()
        current_foreign_lines=()
        current_interleave=''
        while IFS= read -r item; do
            [[ "$item" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue
            if [[ "$item" =~ $wl_re || "$item" =~ $drop_re ]]; then
                normalized=$(__abox_normalize_managed_rule_line "$item") || return 1
                current_target_lines+=("$normalized")
                current_interleave+='T'
            else
                current_foreign_lines+=("$item")
                current_interleave+='F'
            fi
        done <<< "$current_rules_output"
    }
    firewall_state_matches_expected() {
        capture_firewall_views || return 1
        [[ "$(printf '%s\n' "${current_target_lines[@]}")" == "$(printf '%s\n' "${expected_target_lines[@]}")" ]] || return 1
        [[ "$(printf '%s\n' "${current_foreign_lines[@]}")" == "$(printf '%s\n' "${original_foreign_rules[@]}")" ]] || return 1
        [[ "$current_interleave" == "$expected_interleave" ]]
    }
    firewall_rollback_inner() {
        local rollback_line
        local -a rollback_lines=()
        [[ -n "$recovery_snapshot" && -s "$recovery_snapshot" ]] || return 1
        capture_firewall_views || return 1
        [[ "$(printf '%s\n' "${current_target_lines[@]}")" == "$(printf '%s\n' "${expected_target_lines[@]}")" ]] || {
            printf '%s\n' "A-Box firewall rollback conflict: target rules changed outside this transaction; recovery snapshot preserved at $recovery_snapshot" >&2
            return 2
        }
        [[ "$(printf '%s\n' "${current_foreign_lines[@]}")" == "$(printf '%s\n' "${original_foreign_rules[@]}")" ]] || {
            printf '%s\n' "A-Box firewall rollback conflict: non-A-Box INPUT rules changed outside this transaction; recovery snapshot preserved at $recovery_snapshot" >&2
            return 2
        }
        [[ "$current_interleave" == "$expected_interleave" ]] || {
            printf '%s\n' "A-Box firewall rollback conflict: INPUT rule order changed outside this transaction; recovery snapshot preserved at $recovery_snapshot" >&2
            return 2
        }
        rollback_lines=("${current_target_lines[@]}")
        # R26 (R15-F06-01): atomic single-transaction rollback. The old
        # sequential delete-then-reinsert left a hole: after the target
        # WL/DROP rules were deleted and before they were re-inserted, a
        # pre-existing foreign ACCEPT for the same port (which sits below
        # the deleted rules) took effect. Build one iptables-restore
        # transaction instead: -D the current target lines, then -I the
        # original target lines at their original 1-based positions.
        # X-01/X-02 still apply: -I lines go in FORWARD order at absolute
        # positions; reverse insertion would scramble the chain.
        local _restore_bin="${cmd}-restore" _restore_input='*filter'
        local _cmd_ver='' _restore_ver='' _rl='' _spec=''
        # Backend matching (mirrors _ss_wl_rollback_to_snapshot): the
        # restore binary must speak the same backend (nf_tables vs
        # legacy) as the iptables binary, or the transaction would
        # silently operate on a different table. On any mismatch or a
        # missing restore binary, refuse and keep the recovery snapshot
        # (never fall back to sequential delete+reinsert).
        if ! command -v "$_restore_bin" >/dev/null 2>&1; then
            printf '%s\n' 'A-Box firewall rollback: iptables-restore not found; inner rollback not started; recovery snapshot retained.' >&2
            return 1
        fi
        _cmd_ver="$("$cmd" --version 2>/dev/null || true)"
        _restore_ver="$("$_restore_bin" --version 2>/dev/null || true)"
        if [[ "$_cmd_ver" == *'nf_tables'* && "$_restore_ver" != *'nf_tables'* ]]; then
            command -v "${cmd}-nft-restore" >/dev/null 2>&1 && _restore_bin="${cmd}-nft-restore"
        elif [[ "$_cmd_ver" != *'nf_tables'* && "$_restore_ver" == *'nf_tables'* ]]; then
            command -v "${cmd}-legacy-restore" >/dev/null 2>&1 && _restore_bin="${cmd}-legacy-restore"
        fi
        _restore_ver="$("$_restore_bin" --version 2>/dev/null || true)"
        if [[ "$_cmd_ver" == *'nf_tables'* && "$_restore_ver" != *'nf_tables'* ]] || [[ "$_cmd_ver" != *'nf_tables'* && "$_restore_ver" == *'nf_tables'* ]]; then
            printf '%s\n' 'A-Box firewall rollback: iptables-restore backend mismatch; inner rollback not started; recovery snapshot retained.' >&2
            return 1
        fi
        for _rl in "${rollback_lines[@]}"; do
            [[ "$_rl" == '-A INPUT '* ]] || return 1
            _spec="${_rl#-A INPUT }"
            [[ -n "$_spec" ]] || return 1
            _restore_input+=$'\n-D INPUT '"$_spec"
        done
        for ((i=0; i<${#original_target_lines[@]}; i++)); do
            [[ "${original_target_positions[i]:-}" =~ ^[0-9]+$ ]] || return 1
            _rl="${original_target_lines[i]}"
            [[ "$_rl" == '-A INPUT '* ]] || return 1
            _spec="${_rl#-A INPUT }"
            [[ -n "$_spec" ]] || return 1
            _restore_input+=$'\n-I INPUT '"${original_target_positions[i]}"' '"$_spec"
        done
        _restore_input+=$'\nCOMMIT'
        # Strict payload guard (mirrors _ss_wl_rollback_to_snapshot):
        # *filter header, COMMIT trailer, and every other line a -D/-I
        # INPUT op; no :CHAIN/policy lines, no control characters.
        if ! awk '
            NR == 1 { if ($0 != "*filter") exit 1; next }
            { lines[NR] = $0 }
            END {
                if (NR < 2 || lines[NR] != "COMMIT") exit 1
                for (i = 2; i < NR; i++) {
                    if (lines[i] !~ /^-(D|I) INPUT /) exit 1
                }
            }
        ' <<< "$_restore_input" || [[ "${_restore_input//$'\n'/}" == *[[:cntrl:]]* ]]; then
            printf '%s\n' 'A-Box firewall rollback: internal error: restore payload failed strict line guard; recovery snapshot retained.' >&2
            return 1
        fi
        local _restore_rc=0 _w_probe_err=''
        if "$_restore_bin" --help 2>&1 | grep -q -- '--test'; then
            if ! printf '%s\n' "$_restore_input" | "$_restore_bin" --noflush -w 5 --test >/dev/null 2>&1 &&
               ! printf '%s\n' "$_restore_input" | "$_restore_bin" --noflush --test >/dev/null 2>&1; then
                printf '%s\n' 'A-Box firewall rollback: restore payload failed --test pre-check; recovery snapshot retained.' >&2
                return 1
            fi
        fi
        _w_probe_err="$(printf '*filter\nCOMMIT\n' | "$_restore_bin" --noflush -w 0 --test 2>&1 >/dev/null || true)"
        if ! grep -qiE 'unrecognized option|unknown option|invalid option|bad argument' <<< "$_w_probe_err"; then
            printf '%s\n' "$_restore_input" | "$_restore_bin" --noflush -w 5 >/dev/null 2>&1
            _restore_rc=$?
        elif command -v flock >/dev/null 2>&1 && [[ -e /run/xtables.lock || -e /var/run/xtables.lock ]]; then
            local _xt_lock='/run/xtables.lock'
            [[ -e "$_xt_lock" ]] || _xt_lock='/var/run/xtables.lock'
            printf '%s\n' "$_restore_input" | flock -w 5 "$_xt_lock" "$_restore_bin" --noflush >/dev/null 2>&1
            _restore_rc=$?
        else
            printf '%s\n' 'WARNING: pre-1.6.2 iptables has no file lock; running unlocked rollback (best effort).' >&2
            printf '%s\n' "$_restore_input" | "$_restore_bin" --noflush >/dev/null 2>&1
            _restore_rc=$?
        fi
        if (( _restore_rc != 0 )); then
            printf '%s\n' 'A-Box firewall rollback: restore transaction failed; recovery snapshot retained.' >&2
            return 1
        fi
        capture_firewall_views || return 1
        # R5-06: compare rule lines only. `iptables -S` prints the -P
        # policy line first; the policy is clamped to DROP during
        # rollback while the snapshot holds ACCEPT, so a full-string
        # comparison can never match even when every rule is restored.
        # The inner check must not require the policy to be restored;
        # that is the outer rollback's job (R5-07).
        local _current_no_policy _original_no_policy
        _current_no_policy=$(printf '%s\n' "$current_rules_output" | awk '!/^-P[[:space:]]/') || return 1
        _original_no_policy=$(printf '%s\n' "$original_rules_output" | awk '!/^-P[[:space:]]/') || return 1
        [[ "$_current_no_policy" == "$_original_no_policy" ]] || return 1
        return 0
    }
    firewall_rollback() {
        # R6C6-02: clamp INPUT policy to DROP while the inner rollback
        # deletes and re-inserts managed rules: with an ACCEPT policy
        # the gap would leave the port unfiltered. DROP makes "no rule"
        # fail closed instead of fail open.
        # R9 (F05-2/F06-1): if the clamp cannot be established (or the
        # policy cannot be read), refuse the inner rollback outright and
        # keep the recovery snapshot: deleting rules under an unclamped
        # ACCEPT policy would open the port with no fail-closed cover.
        local _saved_policy='' _clamped=0 _inner_rc=0
        _saved_policy=$("$save_cmd" -t filter 2>/dev/null | awk '/^:INPUT / && !seen {print $2; seen=1}') || _saved_policy=''
        if [[ "$_saved_policy" == ACCEPT ]]; then
            if _iptables_do "$cmd" -P INPUT DROP >/dev/null 2>&1; then
                _clamped=1
            else
                printf '%s\n' 'A-Box firewall rollback: could not clamp INPUT policy to DROP; inner rollback not started; recovery snapshot retained.' >&2
                return 1
            fi
        elif [[ -z "$_saved_policy" ]]; then
            printf '%s\n' 'A-Box firewall rollback: could not read INPUT policy; inner rollback not started; recovery snapshot retained.' >&2
            return 1
        fi
        firewall_rollback_inner
        _inner_rc=$?
        if (( _clamped )); then
            if (( _inner_rc != 0 )); then
                printf '%s\n' "A-Box firewall rollback: inner rollback failed; leaving INPUT policy at DROP (fail-closed). Recovery snapshot retained at $recovery_snapshot; restore it manually with: ${cmd}-restore < $recovery_snapshot" >&2
            elif ! _iptables_do "$cmd" -P INPUT "$_saved_policy" >/dev/null 2>&1; then
                printf '%s\n' 'A-Box firewall rollback: could not restore INPUT policy; recovery snapshot retained.' >&2
                _inner_rc=1
            fi
        fi
        # R5-07: the snapshot is deleted only on full success (inner ok
        # AND policy restored); every failure keeps it for manual use.
        if (( _inner_rc == 0 )); then
            if rm -f -- "$recovery_snapshot"; then
                recovery_snapshot=''
            else
                _inner_rc=1
            fi
        fi
        return "$_inner_rc"
    }
    _marked_line_for() {
        # R11-A (R9-1): one comment carries both identities. nft backends
        # keep a single comment per rule (iptables-translate drops all but
        # the last; nft rejects two comments), so the ownership comment and
        # the transaction marker share ONE comment value, "<owner>:<marker>".
        # The input must be a canonical managed rule with exactly one
        # -m comment clause (callers only pass such lines); anything else
        # fails closed instead of silently producing an unmatchable rule.
        local _in="$1"
        [[ "$_in" == *' -j '* ]] || return 1
        [[ "$_in" == *'-m comment'* ]] || return 1
        [[ "$_in" == *'-m comment'*'-m comment'* ]] && return 1
        if [[ "$_in" =~ (.*--comment[[:space:]]+\"?)([A-Za-z0-9_.-]+)(\"?)(.*) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}:${_tmp_marker}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
        else
            return 1
        fi
        return 0
    }
    _expected_remove_first() {
        # R9 (F06-2, 加固): remove the first occurrence of $1 from
        # expected_target_lines and its matching 'T' from
        # expected_interleave. Returns 1 if the line is not expected
        # (bookkeeping is wrong; the caller must roll back).
        local _spec="$1" _k=0 _t=0 _idx=0 _found=0 _new_interleave='' _c
        local -a _kept=()
        for (( _idx=0; _idx<${#expected_target_lines[@]}; _idx++ )); do
            if (( _found == 0 )) && [[ "${expected_target_lines[_idx]}" == "$_spec" ]]; then
                _found=1; _k=$_idx
            else
                _kept+=("${expected_target_lines[_idx]}")
            fi
        done
        (( _found )) || return 1
        expected_target_lines=("${_kept[@]}")
        for (( _idx=0; _idx<${#expected_interleave}; _idx++ )); do
            _c="${expected_interleave:_idx:1}"
            if [[ "$_c" == T ]]; then
                if (( _t == _k )); then _t=$((_t + 1)); continue; fi
                _t=$((_t + 1))
            fi
            _new_interleave+="$_c"
        done
        expected_interleave="$_new_interleave"
        return 0
    }

    recovery_snapshot=$(mktemp /run/A-Box-firewall-recovery.XXXXXX) || { __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    if ! "$save_cmd" -t filter > "$recovery_snapshot" 2>/dev/null; then
        rm -f -- "$recovery_snapshot"
        __abox_firewall_unlock "$lock_fd"; lock_fd=''
        return 1
    fi
    original_rules_output=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || { rm -f -- "$recovery_snapshot"; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    capture_firewall_views || { rm -f -- "$recovery_snapshot"; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    original_target_lines=("${current_target_lines[@]}")
    original_foreign_rules=("${current_foreign_lines[@]}")
    expected_target_lines=("${original_target_lines[@]}")
    original_interleave="$current_interleave"
    expected_interleave="$current_interleave"
    for line in "${original_target_lines[@]}"; do
        if [[ "$line" =~ $wl_re ]]; then
            # R11-A (R9-1): strip a stale temporary marker left by an
            # interrupted earlier run, so the leftover copy is rebuilt as
            # its canonical rule and the old marked copy is cleaned by
            # the normal delete flow instead of being re-marked. Both the
            # legacy standalone marker clause and the composite ":tmp"
            # suffix are removed; the ownership comment is kept.
            # M-30(1): first occurrence wins -- an interrupted earlier
            # run leaves a tmp-marked twin beside the canonical rule;
            # stripping the marker without dedup re-inserts both and the
            # rule count doubles on every interrupted run.
            _stripped_rule="$(printf '%s' "$line" | sed -E -e 's/ -m comment --comment "?A-Box-tmp-[0-9]+-[0-9]+"?//g' -e 's/:A-Box-tmp-[0-9]+-[0-9]+("?)([[:space:]]|$)/\1\2/g')"
            if [[ -z "${_rules_seen["$_stripped_rule"]+x}" ]]; then
                _rules_seen["$_stripped_rule"]=1
                rules+=("$_stripped_rule")
            fi
        fi
    done
    rule_no=0
    while IFS= read -r line; do
        [[ "$line" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue
        rule_no=$((rule_no + 1))
        if [[ "$line" =~ $wl_re || "$line" =~ $drop_re ]]; then
            original_target_positions+=("$rule_no")
        fi
    done <<< "$original_rules_output"
    n=${#rules[@]}

    for ((i=n-1; i>=0; i--)); do
        local expected_line="${rules[i]}"
        # R9 (F06-2, 加固) P1': insert a MARKED copy, not the canonical
        # line: the marker is what lets the delete phase tell this copy
        # apart from an identical pre-existing one. expected_line stays
        # the marked line until P5' swaps in the canonical rules.
        _marked_line=$(_marked_line_for "${rules[i]}") || { firewall_rollback >/dev/null 2>&1 || printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        expected_line="$_marked_line"
        line=${_marked_line//\"/}
        read -r -a argv <<< "$line"
        [[ "${argv[0]:-}" == -A && "${argv[1]:-}" == INPUT ]] || { firewall_rollback >/dev/null 2>&1 || printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        firewall_state_matches_expected || {
            if (( mutated )); then
                if ! firewall_rollback; then
                    printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2
                fi
            else
                rm -f -- "$recovery_snapshot" || true
            fi
            __abox_firewall_unlock "$lock_fd"; lock_fd=''
            return 1
        }
        if ! _iptables_do "$cmd" -I INPUT 1 "${argv[@]:2}" >/dev/null 2>&1; then
            if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
            __abox_firewall_unlock "$lock_fd"; lock_fd=''
            return 1
        fi
        mutated=1
        _tmp_lines=("$_marked_line" "${_tmp_lines[@]}")
        expected_target_lines=("$expected_line" "${expected_target_lines[@]}")
        expected_interleave="T$expected_interleave"
    done
    local expected_drop_line="-A INPUT -p ${proto} -m ${proto} --dport ${port} -m comment --comment ${drop_comment} -j DROP"
    # H-12 depth: build the canonical DROP in kernel form (-m tcp/-m udp,
    # exactly as iptables -S prints it), then normalize it like every
    # live line before it enters the expected state, so the comparison
    # stays exact whether the normalizer strips -m tcp (glibc / fixed
    # musl) or is a no-op (broken musl). A bad normalize result fails
    # closed at _marked_line_for below (it requires ' -j ' and
    # '-m comment').
    expected_drop_line=$(__abox_normalize_managed_rule_line "$expected_drop_line")
    # R9 (F06-2, 加固) P2': the DROP is a duplicated spec too (old and new
    # DROP are textually identical), so it is marked exactly like the WL
    # copies. The marked DROP is recorded in _tmp_lines at position n.
    _marked_drop_line=$(_marked_line_for "$expected_drop_line") || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    line=${_marked_drop_line//\"/}
    read -r -a argv <<< "$line"
    [[ "${argv[0]:-}" == -A && "${argv[1]:-}" == INPUT ]] || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    if ! _iptables_do "$cmd" -I INPUT "$((n + 1))" "${argv[@]:2}" >/dev/null 2>&1; then
        if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
        __abox_firewall_unlock "$lock_fd"; lock_fd=''
        return 1
    fi
    _tmp_lines=("${_tmp_lines[@]:0:n}" "$_marked_drop_line" "${_tmp_lines[@]:n}")
    expected_target_lines=("${expected_target_lines[@]:0:n}" "$_marked_drop_line" "${expected_target_lines[@]:n}")
    expected_interleave="${expected_interleave:0:n}T${expected_interleave:n}"

    rules_output=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    current_lines=(); mapfile -t current_lines <<< "$rules_output"
    delete_lines=(); delete_target_indices=(); target_idx=0; rule_no=0
    for i in "${!current_lines[@]}"; do
        current_line="${current_lines[i]}"
        [[ "$current_line" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue
        rule_no=$((rule_no + 1))
        if [[ "$current_line" =~ $wl_re || "$current_line" =~ $drop_re ]]; then
            if (( target_idx > n )); then
                delete_lines+=("$current_line")
                delete_target_indices+=("$target_idx")
                delete_rule_numbers+=("$rule_no")
            fi
            target_idx=$((target_idx + 1))
        fi
    done
    for ((j=${#delete_lines[@]}-1; j>=0; j--)); do
        firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        # R9 (F06-2, 加固) P4': delete by content spec, not by number, and
        # verify the result. The pre-delete state check above already
        # failed closed on any external change; a numbered delete would
        # still be a second, unguarded window (S26's recheck and the
        # delete were two independent calls). The spec deletes the first
        # matching rule, which is the old copy: the marked copies above
        # it carry the extra marker text, so they never match a
        # canonical spec. _expected_remove_first drops the same first
        # occurrence from the expected state, but only after the delete
        # succeeds (R11-A/R9-2: updating it first would make a failed
        # delete look like an external change and self-lock the rollback);
        # the post-delete state check below proves the live chain equals
        # it -- a wrong-copy delete is caught here instead of passing
        # silently.
        line=${delete_lines[j]//\"/}
        read -r -a argv <<< "$line"
        [[ "${argv[0]:-}" == -A && "${argv[1]:-}" == INPUT ]] || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        _delete_norm=$(__abox_normalize_managed_rule_line "${delete_lines[j]}") || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        if ! _iptables_do "$cmd" -D INPUT "${argv[@]:2}" >/dev/null 2>&1; then
            if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
            __abox_firewall_unlock "$lock_fd"; lock_fd=''
            return 1
        fi
        # R11-A (R9-2): only after the -D succeeds -- updating expected
        # first would make a failed delete look like an external change
        # and self-lock the rollback (live==expected mismatch, rc 2).
        _expected_remove_first "$_delete_norm" || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    done
    # R9 (F06-2, 加固) P5': swap the temporary marked copies for the
    # canonical rules at the same positions, then delete the marked
    # copies. The final state check below then sees only canonical
    # rules; any surviving marked copy fails it.
    for ((i=n-1; i>=0; i--)); do
        line=${rules[i]//\"/}
        read -r -a argv <<< "$line"
        [[ "${argv[0]:-}" == -A && "${argv[1]:-}" == INPUT ]] || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        if ! _iptables_do "$cmd" -I INPUT 1 "${argv[@]:2}" >/dev/null 2>&1; then
            if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
            __abox_firewall_unlock "$lock_fd"; lock_fd=''
            return 1
        fi
        mutated=1
        expected_target_lines=("${rules[i]}" "${expected_target_lines[@]}")
        expected_interleave="T$expected_interleave"
    done
    firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    if ! _iptables_do "$cmd" -I INPUT "$((n + 1))" -p "$proto" -m "$proto" --dport "$port" -m comment --comment "$drop_comment" -j DROP >/dev/null 2>&1; then
        if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
        __abox_firewall_unlock "$lock_fd"; lock_fd=''
        return 1
    fi
    expected_target_lines=("${expected_target_lines[@]:0:n}" "$expected_drop_line" "${expected_target_lines[@]:n}")
    expected_interleave="${expected_interleave:0:n}T${expected_interleave:n}"
    # Delete every temporary marked copy by content spec. Each spec is
    # unique to this transaction (marker), so the delete can only remove
    # this transaction's own copies, never an old or foreign rule.
    for ((i=0; i<${#_tmp_lines[@]}; i++)); do
        firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        line=${_tmp_lines[i]//\"/}
        read -r -a argv <<< "$line"
        [[ "${argv[0]:-}" == -A && "${argv[1]:-}" == INPUT ]] || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        if ! _iptables_do "$cmd" -D INPUT "${argv[@]:2}" >/dev/null 2>&1; then
            if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
            __abox_firewall_unlock "$lock_fd"; lock_fd=''
            return 1
        fi
        # R11-A (R9-2): expected state only after the -D succeeds (see P4').
        _expected_remove_first "${_tmp_lines[i]}" || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
        firewall_state_matches_expected || { if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi; __abox_firewall_unlock "$lock_fd"; lock_fd=''; return 1; }
    done
    if ! firewall_state_matches_expected; then
        if ! firewall_rollback >/dev/null 2>&1; then printf '%s\n' "A-Box firewall rollback incomplete; recovery snapshot: $recovery_snapshot" >&2; fi
        __abox_firewall_unlock "$lock_fd"; lock_fd=''
        return 1
    fi
    if ! rm -f -- "$recovery_snapshot"; then
        printf '%s\n' "A-Box firewall change completed, but recovery snapshot cleanup failed; snapshot retained at $recovery_snapshot" >&2
        __abox_firewall_unlock "$lock_fd"; lock_fd=''
        return 1
    fi
    recovery_snapshot=''
    __abox_firewall_unlock "$lock_fd"; lock_fd=''
    return 0
}

# FINAL-AUDIT fix: fail-closed IPv6 firewall pre-check for SS whitelist mode.
# If the host has IPv6 but ip6tables is missing or unusable, the IPv6 DROP
# rules would be silently skipped while IPv4 gets WL ACCEPT + DROP, leaving
# SS reachable from any IPv6 address under a default-ACCEPT INPUT policy.
# Refuse BEFORE any rule is touched. Returns 1 (callers die/return).
# Objective IPv6 availability check: ignores the user's IP-preference
# setting (read_ip_pref). has_ipv6() returns false in IPv4-preferred mode
# even when the host actually has working IPv6, which would let an
# IPv6-reachable service slip through a whitelist that only filtered IPv4.
# A host with IPv6 enabled in the kernel can be reached via link-local
# (fe80::/10) even with no global address, so we check broadly. Returns 0
# if IPv6 traffic can plausibly reach the host.
host_has_usable_ipv6() {
    # R6-02: address evidence is required, and no sysctl gate may veto
    # it: net.ipv6.conf.all.disable_ipv6=1 can still be overridden
    # per-interface back to 0 with a real IPv6 address, and a failed
    # sysctl query is not evidence that addresses are absent. Enabled-
    # but-unaddressed is still not usable (R1-12-F4).
    # Address evidence (any scope, incl. link-local). R10C6-03:
    # /proc/net/if_inet6 is procfs and reports st_size 0, so -s is
    # always false; test content, not size.
    grep -qs . /proc/net/if_inet6 2>/dev/null && return 0
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && return 0
    ip -6 addr show scope link 2>/dev/null | grep -q 'inet6 ' && return 0
    return 1
}

# Actual ip6tables functionality probe (not just binary presence): the
# binary may exist without the kernel modules loaded.
ip6tables_usable() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1
}

# Snapshot all A-Box SS rules for $SS_PORT before whitelist modification,
# enabling exact restoration if a later step fails mid-setup.
# Must be called before remove_ss_open_accept_rules in each whitelist flow.
# Stores newline-separated rule specs (without the leading "-A INPUT").
_ss_wl_snapshot_rules() {
    local port="${1:-${SS_PORT:-}}"
    [[ -n "$port" ]] || return 1
    _SS_WL_SNAP_PORT="$port"
    # P2-01: distinguish "no rules" from "read failed". A failed iptables
    # query must abort the snapshot instead of being mistaken for empty.
    local out rc
    out="$(_iptables_q "$IPT" -S INPUT 2>/dev/null)"; rc=$?
    (( rc == 0 )) || return 1
    _SS_WL_SNAP_V4="$(printf '%s\n' "$out" | grep -E -- "--comment \"?A-Box-${port}-(tcp|udp)(-(WL6?|DROP6?))?(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)" | sed 's/^-A INPUT //')"
    _SS_WL_SNAP_V6=""
    _SS_WL_SNAP_V6_TAKEN=0
    # S34 (GPT-13): snapshot v6 gate is ip6tables_usable alone, aligned
    # with the delete gate. The host check can go false between rule
    # build and reorder (address lost) while ip6tables stays queryable;
    # the old gate then left deleted v6 rules with no snapshot to restore.
    if ip6tables_usable; then
        out="$(_iptables_q "$IPT6" -S INPUT 2>/dev/null)"; rc=$?
        (( rc == 0 )) || return 1
        _SS_WL_SNAP_V6="$(printf '%s\n' "$out" | grep -E -- "--comment \"?A-Box-${port}-(tcp|udp)(-(WL6?|DROP6?))?(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)" | sed 's/^-A INPUT //')"
        _SS_WL_SNAP_V6_TAKEN=1
    fi
    _SS_WL_SNAP_TAKEN=1
    return 0
}

# Rollback SS whitelist firewall rules to snapshot state.
# Uses a single iptables-restore transaction per address family.
# Policy: A-Box rules are placed at chain head in snapshot order
# ("unified top" strategy). This is NOT exact restoration of original
# absolute positions - non-A-Box rules that were before A-Box rules
# will shift down. This is an explicit priority policy choice.
# CRITICAL: Never add :CHAIN declarations to the restore input.
# Even with --noflush, iptables-restore will flush any user-defined
# chain explicitly declared in the input stream.
_ss_wl_rollback_to_snapshot() {
    local ipt snap failed=0 restore_bin v4_ok=0 v6_ok=0 v6_needed=0
    [[ "${_SS_WL_SNAP_TAKEN:-0}" == 1 ]] || return 1
    [[ -n "${_SS_WL_SNAP_PORT:-}" ]] || return 1
    # Check if IPv6 was snapshotted and needs recovery
    [[ "${_SS_WL_SNAP_V6_TAKEN:-0}" == 1 ]] && v6_needed=1
    for ipt in "$IPT" "$IPT6"; do
        if [[ "$ipt" == "$IPT" ]]; then
            snap="$_SS_WL_SNAP_V4"
            # Match restore binary to actual backend (nft vs legacy).
            # update-alternatives may point iptables/iptables-restore to different
            # backends; detect via --version output.
            local ipt_ver restore_ver
            ipt_ver="$("$ipt" --version 2>/dev/null || echo "")"
            # Default to iptables-restore; refine if version strings indicate mismatch
            restore_bin="iptables-restore"
            if command -v "$restore_bin" >/dev/null 2>&1; then
                restore_ver="$("$restore_bin" --version 2>/dev/null || echo "")"
                # If $IPT reports nf_tables but restore does not (or vice versa),
                # try the alternative binary name
                if [[ "$ipt_ver" == *"nf_tables"* && "$restore_ver" != *"nf_tables"* ]]; then
                    command -v iptables-nft-restore >/dev/null 2>&1 && restore_bin="iptables-nft-restore"
                elif [[ "$ipt_ver" != *"nf_tables"* && "$restore_ver" == *"nf_tables"* ]]; then
                    command -v iptables-legacy-restore >/dev/null 2>&1 && restore_bin="iptables-legacy-restore"
                fi
            fi
            # S33 (GPT-12): re-verify the final binary. If the alternative
            # was missing, restore_bin is still the KNOWN-mismatched default;
            # executing it would write to the parallel ruleset, which the
            # post-verify cannot undo. Fail this family instead of running.
            if command -v "$restore_bin" >/dev/null 2>&1; then
                restore_ver="$("$restore_bin" --version 2>/dev/null || echo "")"
                if [[ "$ipt_ver" == *"nf_tables"* && "$restore_ver" != *"nf_tables"* ]] ||
                   [[ "$ipt_ver" != *"nf_tables"* && "$restore_ver" == *"nf_tables"* ]]; then
                    failed=1; continue
                fi
            fi
        else
            # Skip IPv6 if it was not snapshotted (unusable at snapshot time).
            [[ "$v6_needed" == 1 ]] || continue
            snap="$_SS_WL_SNAP_V6"
            # If IPv6 was snapshotted but now unusable, mark as failed
            # (don't silently skip)
            if ! ip6tables_usable; then failed=1; continue; fi
            # G7: match IPv6 restore binary to actual backend (nft vs legacy)
            local ipt6_ver restore6_ver
            ipt6_ver="$("$ipt" --version 2>/dev/null || echo "")"
            restore_bin="ip6tables-restore"
            if command -v "$restore_bin" >/dev/null 2>&1; then
                restore6_ver="$("$restore_bin" --version 2>/dev/null || echo "")"
                if [[ "$ipt6_ver" == *"nf_tables"* && "$restore6_ver" != *"nf_tables"* ]]; then
                    command -v ip6tables-nft-restore >/dev/null 2>&1 && restore_bin="ip6tables-nft-restore"
                elif [[ "$ipt6_ver" != *"nf_tables"* && "$restore6_ver" == *"nf_tables"* ]]; then
                    command -v ip6tables-legacy-restore >/dev/null 2>&1 && restore_bin="ip6tables-legacy-restore"
                fi
            fi
            # S33 (GPT-12): same re-verify as v4 -- a missing alternative
            # must not leave a known-mismatched default to be executed.
            if command -v "$restore_bin" >/dev/null 2>&1; then
                restore6_ver="$("$restore_bin" --version 2>/dev/null || echo "")"
                if [[ "$ipt6_ver" == *"nf_tables"* && "$restore6_ver" != *"nf_tables"* ]] ||
                   [[ "$ipt6_ver" != *"nf_tables"* && "$restore6_ver" == *"nf_tables"* ]]; then
                    failed=1; continue
                fi
            fi
        fi
        command -v "$restore_bin" >/dev/null 2>&1 || { failed=1; continue; }
        local cur_out cur_rc
        cur_out="$(_iptables_q "$ipt" -S INPUT 2>/dev/null)"; cur_rc=$?
        if (( cur_rc != 0 )); then failed=1; continue; fi
        local cur
        cur="$(printf '%s\n' "$cur_out" | grep -E -- "--comment \"?A-Box-${_SS_WL_SNAP_PORT}-(tcp|udp)(-(WL6?|DROP6?))?(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)" | sed 's/^-A INPUT //')"
        local restore_input="*filter"
        local line pos
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            restore_input+=$'\n-D INPUT '"$line"
        done <<< "$cur"
        pos=1
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            restore_input+=$'\n-I INPUT '"$pos"' '"$line"
            (( pos++ ))
        done <<< "$snap"
        restore_input+=$'\nCOMMIT'
        # G5: strict payload guard
        if ! awk '
            NR == 1 { if ($0 != "*filter") exit 1; next }
            { lines[NR] = $0 }
            END {
                if (NR < 2 || lines[NR] != "COMMIT") exit 1
                for (i = 2; i < NR; i++) {
                    if (lines[i] !~ /^-(D|I) INPUT /) exit 1
                }
            }
        ' <<< "$restore_input" || [[ "${restore_input//$'\n'/}" == *[[:cntrl:]]* ]]; then
            printf '%s\n' 'ERROR: internal error: restore payload failed strict line guard' >&2
            failed=1
            continue
        fi
        if "$restore_bin" --help 2>&1 | grep -q -- "--test"; then
            if ! printf '%s\n' "$restore_input" | "$restore_bin" --noflush -w 5 --test >/dev/null 2>&1 &&
               ! printf '%s\n' "$restore_input" | "$restore_bin" --noflush --test >/dev/null 2>&1; then
                printf '%s\n' 'ERROR: restore payload failed --test pre-check' >&2
                failed=1
                continue
            fi
        fi
        local restore_rc=0 w_probe_err=''
        # F10: distinguish option syntax error from lock contention timeout
        w_probe_err="$(printf '*filter\nCOMMIT\n' | "$restore_bin" --noflush -w 0 --test 2>&1 >/dev/null || true)"
        if ! grep -qiE 'unrecognized option|unknown option|invalid option|bad argument' <<< "$w_probe_err"; then
            # Modern: use built-in wait
            printf '%s\n' "$restore_input" | "$restore_bin" --noflush -w 5 >/dev/null 2>&1
            restore_rc=$?
        elif command -v flock >/dev/null 2>&1 && [[ -e /run/xtables.lock || -e /var/run/xtables.lock ]]; then
            # Legacy: wrap with flock (do not combine with -w to avoid self-deadlock)
            local lock_file="/run/xtables.lock"
            [[ -e "$lock_file" ]] || lock_file="/var/run/xtables.lock"
            printf '%s\n' "$restore_input" | flock -w 5 "$lock_file" "$restore_bin" --noflush >/dev/null 2>&1
            restore_rc=$?
        else
            # Pre-1.6.2 (e.g. 1.4.x): no -w support and no file lock.
            # 1.4.x restore never locked natively, so run unlocked best-effort.
            printf '%s\n' 'WARNING: pre-1.6.2 iptables has no file lock; running unlocked rollback (best effort).' >&2
            printf '%s\n' "$restore_input" | "$restore_bin" --noflush >/dev/null 2>&1
            restore_rc=$?
        fi
        if (( restore_rc != 0 )); then
            failed=1
            continue
        fi
        # Verify: check that first N rules of INPUT match snapshot in order
        # (N = number of snapshot rules), proving they are at chain head.
        # Use normalized comparison to handle -m tcp / quote variations.
        local final_out final_rc
        final_out="$(_iptables_q "$ipt" -S INPUT 2>/dev/null)"; final_rc=$?
        if (( final_rc != 0 )); then failed=1; continue; fi
        local snap_count
        snap_count="$(printf '%s\n' "$snap" | grep -c -v '^$' || true)"
        local head_rules normalized_head normalized_expected
        head_rules="$(printf '%s\n' "$final_out" | grep "^-A INPUT " | head -n "$snap_count" | sed 's/^-A INPUT //')"
        # Normalize both sides for comparison
        normalized_head=""
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            line="$(__abox_normalize_managed_rule_line "$line" 2>/dev/null || printf '%s' "$line")"
            normalized_head+="$line"$'\n'
        done <<< "$head_rules"
        normalized_expected=""
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            line="$(__abox_normalize_managed_rule_line "$line" 2>/dev/null || printf '%s' "$line")"
            normalized_expected+="$line"$'\n'
        done <<< "$snap"
        if [[ "$normalized_head" != "$normalized_expected" ]]; then
            failed=1
            continue
        fi
        # Also verify full A-Box rule set matches (no extras/missing)
        # Compare normalized full sets (order-independent for this check,
        # as head-order was already verified above)
        local final normalized_final
        final="$(printf '%s\n' "$final_out" | grep -E -- "--comment \"?A-Box-${_SS_WL_SNAP_PORT}-(tcp|udp)(-(WL6?|DROP6?))?(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$)" | sed 's/^-A INPUT //')"
        normalized_final=""
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            line="$(__abox_normalize_managed_rule_line "$line" 2>/dev/null || printf '%s' "$line")"
            normalized_final+="$line"$'\n'
        done <<< "$final"
        # Sort both for order-independent comparison
        if [[ "$(printf '%s' "$normalized_final" | sort)" != "$(printf '%s' "$normalized_expected" | sort)" ]]; then
            failed=1
            continue
        fi
        # S53 (argon P3-1): track each family directly; the error report
        # below synthesizes fail_fams from these, never by reverse
        # inference (the old "v4 failed iff v6 not needed or ok" logic
        # dropped IPv4 when both families failed).
        if [[ "$ipt" == "$IPT" ]]; then v4_ok=1; else v6_ok=1; fi
    done
    # Cross-family check: if IPv6 was needed but not recovered, fail overall
    if (( v6_needed == 1 && v6_ok == 0 )); then
        failed=1
    fi
    if (( failed != 0 )); then
        local fail_fams=""
        (( v4_ok == 0 )) && fail_fams="IPv4"
        (( v6_needed == 1 && v6_ok == 0 )) && fail_fams="${fail_fams:+$fail_fams,}IPv6"
        printf '%s\n' "ERROR: firewall rollback incomplete (${fail_fams:-unknown}); manual recovery required." >&2
        printf '%s\n' "Check: iptables -S INPUT / ip6tables -S INPUT against snapshot." >&2
        return 1
    fi
    _SS_WL_SNAP_TAKEN=0
    _SS_WL_SNAP_PORT=""
    return 0
}

ss_whitelist_ipv6_precheck() {
    # Use the objective check, not has_ipv6(): a host in IPv4-preferred mode
    # may still be reachable over IPv6, and the whitelist must cover it.
    # The ip6tables_usable() probe is a real functionality test, not just
    # a binary-presence check.
    if host_has_usable_ipv6; then
        ip6tables_usable || return 1
    fi
    return 0
}

enforce_ss_whitelist_order() {
    local port="${1:-${SS_PORT:-}}" failed=0 proto
    if (( $# == 0 )) && [[ -z "${SS_PORT:-}" ]]; then
        return 0
    fi
    # G8: invalid port must fail, not silently succeed.
    valid_port "$port" || return 1
    # FINAL-AUDIT: fail closed here too (defense in depth for restore paths).
    ss_whitelist_ipv6_precheck || return 1
    for proto in tcp udp; do
        reorder_ss_whitelist_rules_one "$IPT" "$port" "$proto" WL DROP || failed=1
        # Objective check (not has_ipv6()): never silently skip the IPv6 path
        # when the host is actually IPv6-reachable. The precheck above already
        # guaranteed ip6tables works in that case, so a failure here is real.
        if host_has_usable_ipv6; then
            reorder_ss_whitelist_rules_one "$IPT6" "$port" "$proto" WL6 DROP6 || failed=1
        fi
    done
    (( failed == 0 ))
}

clean_nat_rules() {
    # R9 (F06-3): check the probe exit code, not just its output: a
    # failed probe used to fall through and delete rules. Empty output
    # is not a backend identity either (hardening on top of the R5-12
    # gate in remove_abox_native_firewall_rule).
    local backend
    backend=$(firewall_backend 2>/dev/null) || return 1
    [[ -n "$backend" ]] || return 1
    [[ "$backend" != 'nftables-unsupported' ]] || {
        msg "${RED}Native nftables rules detected; refusing to mutate a parallel iptables ruleset.${NC}"
        return 1
    }
    local output rule failed=0 owned_re ipv6_nat_error
    local -a argv=()
    owned_re='--comment "?A-Box-HY2-HOP"?([ \t\r]|$)'
    while :; do
        output=$(_iptables_q "$IPT" -t nat -S PREROUTING 2>/dev/null) || {
            # M-14(3): a missing nat table (container VPS without
            # iptable_nat) means "no NAT rules to clean", not a
            # failure -- same exemption as clean_chain. Any other
            # probe failure still fails the cleanup.
            local _nat_err
            _nat_err=$(_iptables_q "$IPT" -t nat -S PREROUTING 2>&1 >/dev/null || true)
            if printf '%s\n' "$_nat_err" | grep -qiE "table .* does not exist|table does not exist|table nat is not supported|protocol not supported"; then
                break
            fi
            failed=1; break
        }
        rule=$(awk -v re="$owned_re" '$0 ~ re { sub(/^-A /,"-D "); print; exit }' <<< "$output")
        [[ -n "$rule" ]] || break
        rule=${rule//\"/}
        read -r -a argv <<< "$rule"
        _iptables_do "$IPT" -t nat "${argv[@]}" >/dev/null 2>&1 || { failed=1; break; }
    done
    if command -v ip6tables >/dev/null 2>&1; then
        if _iptables_q "$IPT6" -t nat -S PREROUTING >/dev/null 2>&1; then
            while :; do
                output=$(_iptables_q "$IPT6" -t nat -S PREROUTING 2>/dev/null) || { failed=1; break; }
                rule=$(awk -v re="$owned_re" '$0 ~ re { sub(/^-A /,"-D "); print; exit }' <<< "$output")
                [[ -n "$rule" ]] || break
                rule=${rule//\"/}
                read -r -a argv <<< "$rule"
                _iptables_do "$IPT6" -t nat "${argv[@]}" >/dev/null 2>&1 || { failed=1; break; }
            done
        else
            ipv6_nat_error=$(_iptables_q "$IPT6" -t nat -S PREROUTING 2>&1 >/dev/null || true)
            if ! grep -Eiq "table ['\"]?nat['\"]? does not exist|table does not exist|table nat is not supported|protocol not supported|table ['\"]nat['\"] is incompatible, use ['\"]nft['\"] tool" <<< "$ipv6_nat_error"; then
                failed=1
            fi
        fi
    elif has_ipv6; then
        # Without the binary, previously managed IPv6 rules cannot be inspected.
        failed=1
    fi
    (( failed == 0 ))
}

clean_input_rules() {
    # R9 (F06-3): check the probe exit code, not just its output: a
    # failed probe used to fall through and delete rules. Empty output
    # is not a backend identity either (hardening on top of the R5-12
    # gate in remove_abox_native_firewall_rule).
    local backend
    backend=$(firewall_backend 2>/dev/null) || return 1
    [[ -n "$backend" ]] || return 1
    [[ "$backend" != 'nftables-unsupported' ]] || {
        msg "${RED}Native nftables rules detected; refusing to mutate a parallel iptables ruleset.${NC}"
        return 1
    }
    local output rule failed=0 owned_re
    local -a argv=()
    owned_re='--comment "?A-Box-[0-9]+(:[0-9]+)?-(tcp|udp)(-(WL6?|DROP6?))?(:A-Box-tmp-[0-9]+-[0-9]+)?"?([ \t\r]|$)'
    remove_native_firewall_rules 2>/dev/null || failed=1
    while :; do
        output=$(_iptables_q "$IPT" -S INPUT 2>/dev/null) || { failed=1; break; }
        rule=$(awk -v re="$owned_re" '$0 ~ re { sub(/^-A /,"-D "); print; exit }' <<< "$output")
        [[ -n "$rule" ]] || break
        rule=${rule//\"/}
        read -r -a argv <<< "$rule"
        _iptables_do "$IPT" "${argv[@]}" >/dev/null 2>&1 || { failed=1; break; }
    done
    # Objective v6 gate, not preference-aware has_ipv6: SS-whitelist
    # v6 rules are created on objective reachability, so cleanup
    # must not silently skip v6 on ipv4-preference hosts.
    if command -v ip6tables >/dev/null 2>&1; then
        if _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
            while :; do
                output=$(_iptables_q "$IPT6" -S INPUT 2>/dev/null) || { failed=1; break; }
                rule=$(awk -v re="$owned_re" '$0 ~ re { sub(/^-A /,"-D "); print; exit }' <<< "$output")
                [[ -n "$rule" ]] || break
                rule=${rule//\"/}
                read -r -a argv <<< "$rule"
                _iptables_do "$IPT6" "${argv[@]}" >/dev/null 2>&1 || { failed=1; break; }
            done
        else
            # R16-F06-07: a v6 query failure is a failure, never excused
            # by address evidence (see remove_ss_open_accept_rules).
            failed=1
        fi
    elif host_has_usable_ipv6; then
        failed=1
    fi
    (( failed == 0 ))
}

add_port_pair() {
    local arr_name="$1" proto="$2" port="$3"
    [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] || return 0
    # Leading zeros normalized here: tcp/0443 and tcp/443 are the same port.
    port=$((10#$port))
    printf -v "$arr_name" '%s%s/%s\n' "${!arr_name}" "$proto" "$port"
}

hy2_http01_enabled() {
    local core="${1:-${CORE_IN:-${CORE:-}}}" mode="${2:-${MODE_IN:-${MODE:-}}}"
    [[ -n "${HY2_DOMAIN:-}" && "${HY2_ACME_TYPE:-http}" == http &&
       ( "$core" == 'hysteria' || ( "$core" == 'xray' && "$mode" == *'ALL'* ) ) ]]
}

selected_port_pairs() {
    local pairs=''
    add_port_pair pairs tcp "${VLESS_PORT:-}"
    add_port_pair pairs tcp "${XHTTP_PORT:-}"
    add_port_pair pairs tcp "${SS_PORT:-}"
    add_port_pair pairs udp "${SS_PORT:-}"
    # S30 (GPT-8): SOCKS was never listed, so check_selected_ports_free
    # and release_ports both skipped it (XHTTP/80 dup, hopping-range and
    # occupancy all uncaught). TCP+UDP, matching deploy + fail2ban.
    add_port_pair pairs tcp "${SOCKS_PORT:-}"
    add_port_pair pairs udp "${SOCKS_PORT:-}"
    if hy2_http01_enabled; then
        add_port_pair pairs tcp 80
    fi
    # Native Hysteria official range mode listens on the first range port; the
    # separate base port is only real for non-hopping/manual redirect modes.
    if [[ "${HY2_HOP:-}" != true || "${HY2_HOP_IMPL:-none}" != official ]]; then
        add_port_pair pairs udp "${HY2_BASE_PORT:-}"
    fi
    printf '%s' "$pairs"
}

# SYD-B E2: same-port reinstall tolerance. The old deployment still
# listens while the wizard runs (the stop moved after the wizard),
# so an A-Box-owned holder is not a conflict. Every holder line
# must resolve to a standard core binary; anything else (foreign
# process, unparseable pid, deleted-suffix aside) fails closed.
ss_holder_is_abox_owned() {
    local line pid exe srv pids
    [[ -n "${1:-}" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        # R2C7-F06: validate EVERY pid on the line; the old greedy sed took
        # only the last pid, letting earlier foreign holders pass unchecked.
        pids=$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | sed 's/^pid=//' || true)
        [[ -n "$pids" ]] || return 1
        while IFS= read -r pid || [[ -n "$pid" ]]; do
            [[ -n "$pid" ]] || continue
            exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
            exe=${exe%' (deleted)'}
            case "$exe" in
                /usr/local/bin/xray) srv=xray ;;
                /usr/local/bin/sing-box) srv=sing-box ;;
                /usr/local/bin/hysteria) srv=hysteria ;;
                /usr/local/bin/xray-latest) srv=xray-latest ;;
                *) return 1 ;;
            esac
            # R4C7-01: the exe path alone does not prove an A-Box instance
            # (an independent install at a standard path shares it); the pid
            # must be that managed service's own pid.
            [[ "$(managed_service_pid "$srv" 2>/dev/null || true)" == "$pid" ]] || return 1
        done <<< "$pids"
    done <<< "$1"
    return 0
}

# H-26(2b): does the preserve snapshot hold an inbound bound to
# proto:port? rc 0 = yes, rc 1 = confirmed no binding (no snapshot
# file, empty snapshot, or no inbound covers it), rc 2 = unverifiable
# (jq missing / snapshot unreadable / an inbound binding is
# unparseable). Callers must only take the tolerance branch on rc 1;
# rc 2 stays fail-closed (prompt). The binding model (port ranges,
# transport sets) mirrors standalone_preserve_snapshot's drop filter.
_preserve_snapshot_binds_port() {
    local proto="$1" p="$2" _file="${ABOX_PRESERVE_FILE:-}" _res=''
    [[ -n "$_file" && -f "$_file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 2
    _res=$(jq -r --arg proto "$proto" --argjson port "$p" '
            def parse_range:
              if type == "number" then [., .]
              elif type == "string" then
                if test("^[0-9]+$") then [(tonumber), (tonumber)]
                elif test("^[0-9]+-[0-9]+$") then
                  (split("-") | map(tonumber) | if .[0] <= .[1] then . else [.[1], .[0]] end)
                else null end
              else null end;
            # 03b-M1: same shared transport rule as snapshot/restore
            # (see standalone_preserve_snapshot); a socks inbound
            # with settings.udp=true binds UDP too, so a udp:port
            # probe must see it here as well.
            def transport_set:
              if (.protocol // null) != null then
                (if .protocol == "tuic" or .protocol == "hysteria" or .protocol == "hysteria2" or .protocol == "quic" then ["udp"]
                 elif .protocol == "socks" then (if .settings.udp == true then ["tcp", "udp"] else ["tcp"] end)
                 elif .protocol == "shadowsocks" then (if (.settings.network // "tcp") == "tcp" then ["tcp"] elif (.settings.network // "tcp") == "udp" then ["udp"] else ["tcp", "udp"] end)
                 elif .protocol == "dokodemo-door" then (if (.settings.network // "tcp") == "tcp" then ["tcp"] elif (.settings.network // "tcp") == "udp" then ["udp"] else ["tcp", "udp"] end)
                 elif (.streamSettings.network // null) != null then
                   (.streamSettings.network
                    | if . == "tcp" or . == "ws" or . == "http" or . == "grpc" then ["tcp"]
                      elif . == "kcp" or . == "quic" then ["udp"]
                      elif . == "tcp,udp" or . == "udp,tcp" then ["tcp", "udp"]
                      else ["tcp"] end)
                 else ["tcp"] end)
              elif (.type // null) != null then
                (if .type == "tuic" or .type == "hysteria2" or .type == "quic" then ["udp"]
                 elif .type == "shadowsocks" then (if .network == "tcp" then ["tcp"] elif .network == "udp" then ["udp"] else ["tcp", "udp"] end)
                 elif (.network // null) != null then (.network | split(",") | map(select(. == "tcp" or . == "udp")))
                 else ["tcp"] end)
              elif (.network // null) != null then
                (.network | split(",") | map(select(. == "tcp" or . == "udp")))
              else ["tcp"] end;
            def binding:
              ((.listen_port // .port) as $ps
               | if $ps == null then null
                 else
                   (($ps | parse_range) as $r
                    | if $r == null then {addr: (.listen // "0.0.0.0"), transports: transport_set, range: null, unparseable: true}
                      else {addr: (.listen // "0.0.0.0"), transports: transport_set, range: $r, unparseable: false} end)
                 end);
            def binds($proto; $port):
              ([.[] | (binding) as $b | select($b != null and ($b.unparseable | not) and (($b.transports | index($proto)) != null) and ($port >= $b.range[0] and $port <= $b.range[1]))] | length) > 0;
            def any_unparseable:
              ([.[] | (binding) as $b | select($b != null and $b.unparseable)] | length) > 0;
            if any_unparseable then "unknown"
            elif binds($proto; $port) then "binds"
            else "none" end' "$_file" 2>/dev/null) || return 2
    case "$_res" in
        binds) return 0 ;;
        none) return 1 ;;
        *) return 2 ;;
    esac
}

# H-26(2): preserve-mode port conflict. The selected port is held by an
# A-Box-owned process AND preserve mode would restore a standalone
# inbound onto the same port; silently tolerating it (same-port
# reinstall) lets restore drop that node without the user knowing.
# Ask the user: 1 release the preserved inbound on this port (recorded
# in ABOX_PRESERVE_DROP_PORTS; standalone_preserve_snapshot filters it
# out), 2 change port (die so the wizard is re-run with another port),
# 3 abandon preserve (the whole preserve set is dropped). A failed or
# closed read dies fail-closed. Returns 0 on 1/3.
_preserve_port_conflict() {
    local proto="$1" p="$2" _ans='' _prompt='' _rel_msg='' _aban_msg=''
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${RED}[!] Port ${p}/${proto} is held by an A-Box-owned process, but preserve mode would restore a standalone inbound onto the same port; that node would be lost on restore.${NC}"
            msg "  1) Release the preserved inbound on ${p}/${proto} and continue"
            msg "  2) Change port (stop here and pick another port)"
            msg "  3) Abandon preserve and continue (no preserved nodes will be restored)"
            _prompt='Choose [1/2/3]: '
            _rel_msg="Preserved inbound on ${p}/${proto} will not be restored."
            _aban_msg='Preserve mode abandoned; no standalone nodes will be restored.'
            ;;
        ru)
            msg "${RED}[!] Порт ${p}/${proto} занят собственным процессом A-Box, а режим сохранения восстановит на этот же порт отдельный узел; при восстановлении этот узел будет потерян.${NC}"
            msg "  1) Освободить сохранённый узел на порту ${p}/${proto} и продолжить"
            msg "  2) Сменить порт (остановиться и выбрать другой порт)"
            msg "  3) Отказаться от сохранения и продолжить (сохранённые узлы не будут восстановлены)"
            _prompt='Выберите [1/2/3]: '
            _rel_msg="Сохранённый узел на порту ${p}/${proto} не будет восстановлен."
            _aban_msg='Режим сохранения отменён; сохранённые узлы не будут восстановлены.'
            ;;
        fa)
            msg "${RED}[!] پورت ${p}/${proto} توسط فرایند متعلق به A-Box اشغال شده است و حالت حفظ، یک گره مستقل را روی همین پورت بازمی‌گرداند؛ آن گره هنگام بازیابی از دست می‌رود.${NC}"
            msg "  1) گره حفظ‌شده روی ${p}/${proto} را آزاد کن و ادامه بده"
            msg "  2) تغییر پورت (اینجا توقف و انتخاب پورتی دیگر)"
            msg "  3) انصراف از حفظ و ادامه (هیچ گره حفظ‌شده‌ای بازیابی نمی‌شود)"
            _prompt='انتخاب کنید [1/2/3]: '
            _rel_msg="گره حفظ‌شده روی ${p}/${proto} بازیابی نمی‌شود."
            _aban_msg='حالت حفظ کنار گذاشته شد؛ هیچ گره حفظ‌شده‌ای بازیابی نمی‌شود.'
            ;;
        zh-tw)
            msg "${RED}[!] 連接埠 ${p}/${proto} 正由 A-Box 自有處理程序佔用，且保留模式會把一個獨立節點恢復到同一連接埠；恢復時會丟掉該節點。${NC}"
            msg "  1) 釋放該連接埠上的保留節點並繼續"
            msg "  2) 改連接埠（停在這裡，重新選連接埠）"
            msg "  3) 放棄保留並繼續（全部保留節點都不恢復）"
            _prompt='請選擇 [1/2/3]： '
            _rel_msg="該連接埠上的保留節點將不再恢復。"
            _aban_msg='已放棄保留模式；全部保留節點都不恢復。'
            ;;
        ja)
            msg "${RED}[!] ポート ${p}/${proto} は A-Box 自身のプロセスが使用しており、保持モードでは同じポートにスタンドアロンノードが復元されるため、そのノードは復元時に失われます。${NC}"
            msg "  1) このポート上の保持ノードを解放して続行"
            msg "  2) ポートを変更（ここで停止し、別のポートを選択）"
            msg "  3) 保持を破棄して続行（保持ノードはすべて破棄）"
            _prompt='選択してください [1/2/3]: '
            _rel_msg="ポート ${p}/${proto} 上の保持ノードは復元されません。"
            _aban_msg='保持モードを破棄しました。保持ノードは復元されません。'
            ;;
        *)
            msg "${RED}[!] 端口 ${p}/${proto} 正由 A-Box 自有进程占用，且保留模式会把一个独立节点恢复到同一端口；恢复时会丢掉该节点。${NC}"
            msg "  1) 释放该端口上的保留节点并继续"
            msg "  2) 改端口（停在这里，重新选端口）"
            msg "  3) 放弃保留并继续（全部保留节点都不恢复）"
            _prompt='请选择 [1/2/3]： '
            _rel_msg="该端口上的保留节点将不再恢复。"
            _aban_msg='已放弃保留模式；全部保留节点都不恢复。'
            ;;
    esac
    read -r -p "$_prompt" _ans || { die "$(tr_msg dp_cancelled)"; return 1; }
    # M-36: normalize Persian/Arabic digits (e.g. ۱ -> 1) so a digit
    # choice is not misread as invalid input and die-cancelled.
    _ans=$(normalize_fa_ar_digits "$_ans")
    case "$_ans" in
        1)
            ABOX_PRESERVE_DROP_PORTS="${ABOX_PRESERVE_DROP_PORTS:+$ABOX_PRESERVE_DROP_PORTS }${proto}:${p}"
            export ABOX_PRESERVE_DROP_PORTS
            msg "${YELLOW}[*] ${_rel_msg}${NC}"
            ;;
        2) die "$(tprintf pt_release_manual "${p}/${proto}")" ;;
        3)
            ABOX_PRESERVE_STANDALONE=0
            export ABOX_PRESERVE_STANDALONE
            msg "${YELLOW}[*] ${_aban_msg}${NC}"
            ;;
        *) die "$(tr_msg dp_cancelled)" ;;
    esac
    return 0
}

check_selected_ports_free() {
    msg "${YELLOW}[*] $(tr_msg check_selected_ports_free_checking)${NC}"
    local pairs pair proto p holder dup line _foreign_holder
    pairs=$(selected_port_pairs | awk 'NF')
    dup=$(printf '%s\n' "$pairs" | awk 'NF { seen[$0]++ } END { for (k in seen) if (seen[k] > 1) { print k; break } }')
    [[ -n "$dup" ]] && die "$(tprintf pt_dup "$dup")"

    if [[ "${HY2_HOP:-}" == 'true' && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" ]]; then
        for pair in $pairs; do
            proto=${pair%/*}; p=${pair#*/}
            if [[ "$proto" == 'udp' ]] && (( 10#$p >= 10#$HY2_RANGE_START && 10#$p <= 10#$HY2_RANGE_END )); then
                die "$(tprintf pt_hy2_range "$p" "$HY2_RANGE_START" "$HY2_RANGE_END")"
            fi
        done
    fi

    command -v ss >/dev/null 2>&1 || die "$(tr_msg pt_no_ss)"
    for pair in $pairs; do
        proto=${pair%/*}; p=${pair#*/}
        # R4C7-02: ss -l omits connected UDP sockets, whose local port is
        # still bound (a new listener gets EADDRINUSE). Enumerate all UDP
        # sockets; TCP keeps -l (only listeners block a new listener).
        if [[ "$proto" == 'udp' ]]; then
            if ! holder=$(ss -H -n -a -p -A udp 2>/dev/null); then
                die "$(tprintf pt_ss_fail "${p}/${proto}")"
            fi
        elif ! holder=$(ss -H -n -l -p -A "$proto" 2>/dev/null); then
            die "$(tprintf pt_ss_fail "${p}/${proto}")"
        fi
        holder=$(awk -v p="$p" '
            {
                # R6-03: ss -A omits Netid, so $4 is Local and $5 is
                # Peer; with Netid, $4 is Send-Q and $5 is Local.
                # Select the Local column by layout; never match Peer.
                local_addr = ($4 ~ /:/ ? $4 : $5)
                if (local_addr ~ ("[:.]" p "$"))
                    print
            }
        ' <<< "$holder" || true)
        [[ -z "$holder" ]] && continue
        # SYD-B E2: an A-Box-owned holder is the old deployment itself
        # (still listening until release_ports runs after the wizard);
        # same-port reinstall must not die on it.
        if ss_holder_is_abox_owned "$holder"; then
            if [[ "${ABOX_PRESERVE_STANDALONE:-0}" == '1' ]]; then
                # H-26(2): in preserve mode this port belongs to a
                # standalone inbound that will be restored; the old
                # same-port tolerance would let restore silently drop
                # it. Treat it as a hard conflict instead.
                # H-26(2b): only when the preserve snapshot really
                # holds an inbound bound to this port. With no such
                # binding (no snapshot, or no inbound on this port)
                # there is nothing to lose, so the old tolerance
                # applies; an unverifiable snapshot stays fail-closed
                # (rc 2 falls through to the prompt below).
                _preserve_snapshot_binds_port "$proto" "$p"
                case "$?" in
                    1)
                        msg "${YELLOW}[*] $(tprintf check_selected_ports_free_owned_process "${p}" "${proto}")${NC}"
                        continue
                        ;;
                esac
                _preserve_port_conflict "$proto" "$p" || return 1
                continue
            fi
            msg "${YELLOW}[*] $(tprintf check_selected_ports_free_owned_process "${p}" "${proto}")${NC}"
            continue
        fi
        msg "${RED}[!] $(tprintf check_selected_ports_free_occupied "${p}" "${proto}")${NC}"
        printf '%s\n' "$holder"
        die "$(tprintf pt_release_manual "${p}/${proto}")"
    done

    if [[ "${HY2_HOP:-}" == 'true' && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" ]]; then
        local ss_udp_output
        # R4C7-02: same as above; connected UDP sockets must be enumerated.
        if ! ss_udp_output=$(ss -H -n -a -p -A udp 2>/dev/null); then
            die "$(tr_msg pt_hy2_ss_fail)"
        fi
        holder=''
        if [[ -n "$ss_udp_output" ]]; then
            while IFS= read -r line; do
                # R6-03: ss -A omits Netid, so $4 is Local and $5 is
                # Peer; with Netid, $4 is Send-Q and $5 is Local. Select
                # the Local column once by layout; never fall back to
                # Peer when port extraction fails.
                p=$(awk '{ print ($4 ~ /:/ ? $4 : $5) }' <<< "$line" | sed -nE 's/.*[:.]([0-9]+)$/\1/p')
                [[ "$p" =~ ^[0-9]+$ ]] || continue
                if (( 10#$p >= 10#$HY2_RANGE_START && 10#$p <= 10#$HY2_RANGE_END )); then
                    holder+="$line"$'\n'
                fi
            done <<< "$ss_udp_output"
        fi
        # SYD-B E2: same tolerance for the hop range: only foreign
        # holders in range are a conflict; A-Box-owned ones are the
        # old deployment still listening during the wizard.
        if [[ -n "$holder" ]]; then
            _foreign_holder=''
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -n "$line" ]] || continue
                ss_holder_is_abox_owned "$line" || _foreign_holder+="$line"$'\n'
            done <<< "$holder"
            holder="$_foreign_holder"
        fi
        if [[ -n "$holder" ]]; then
            msg "${RED}[!] $(tprintf check_selected_ports_free_hy2_range_occupied "${HY2_RANGE_START}" "${HY2_RANGE_END}")${NC}"
            printf '%s' "$holder"
            die "$(tr_msg pt_hy2_release)"
        fi
    fi
}

release_ports() {
    msg "${YELLOW}[*] $(tr_msg release_ports_stopping_services)${NC}"
    # S1-low2 (final-round-followup2-WC): record which owned services are
    # actually running before the stop, so the deploy can say plainly that
    # only the newly deployed core(s) are restarted afterwards. The
    # deploying cores come from the deployment transaction
    # (ABOX_DEPLOY_TX_TARGETS, set by begin_deployment_transaction before
    # this runs); any other running service stays stopped — and a covering
    # deploy prunes its stack (prune_owned_core_families_except), so it
    # must be re-deployed, not merely restarted. Read-only probe; a probe
    # failure simply omits that service from the list (no false warning).
    local _s1low2_stopped='' _s1low2_srv _s1low2_state
    for _s1low2_srv in xray sing-box hysteria; do
        abox_owns_service "$_s1low2_srv" 2>/dev/null || continue
        case " ${ABOX_DEPLOY_TX_TARGETS:-} " in *" $_s1low2_srv "*) continue ;; esac
        _s1low2_state=$(service_active_state_value "$_s1low2_srv" 2>/dev/null || true)
        [[ "$_s1low2_state" == '1' ]] || continue
        _s1low2_stopped+="$_s1low2_srv "
    done
    stop_all_managed_services || die "$(tr_msg pt_stop_all)"
    if [[ -n "$_s1low2_stopped" ]]; then
        msg "${YELLOW}[!] $(tprintf release_ports_other_stopped "${_s1low2_stopped% }")${NC}"
    fi
    sleep 1
    local pairs pair proto p holder
    pairs=$(selected_port_pairs | awk 'NF' | sort -u)
    if [[ -z "$pairs" ]]; then
        # Fresh install / empty .env: ports are chosen in the wizard after this
        # step. Occupancy for the newly selected ports is enforced by
        # check_selected_ports_free at the end of pre_install_setup.
        msg "${YELLOW}[*] $(tr_msg release_ports_no_ports_selected)${NC}"
        return 0
    fi
    msg "${YELLOW}[*] $(tr_msg release_ports_checking_configured)${NC}"
    command -v ss >/dev/null 2>&1 || die "$(tr_msg pt_no_ss)"
    for pair in $pairs; do
        proto=${pair%/*}; p=${pair#*/}
        if ! holder=$(ss -H -n -l -p -A "$proto" 2>/dev/null); then
            die "$(tprintf pt_ss_fail "${p}/${proto}")"
        fi
        holder=$(awk -v p="$p" '
            {
                # R6-03: ss -A omits Netid, so $4 is Local and $5 is
                # Peer; with Netid, $4 is Send-Q and $5 is Local.
                # Select the Local column by layout; never match Peer.
                local_addr = ($4 ~ /:/ ? $4 : $5)
                if (local_addr ~ ("[:.]" p "$"))
                    print
            }
        ' <<< "$holder" || true)
        [[ -z "$holder" ]] && continue
        msg "${YELLOW}[!] $(tprintf release_ports_old_port_occupied "${p}" "${proto}")${NC}"
    done
}


write_if_changed() {
    local target="$1" tmp="$2" mode="${3:-700}"
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$tmp" "$target"; then
        # S36 (GPT-16): same content is not "already correct" -- the
        # requested mode (and, when root, owner 0:0) must also hold,
        # else fall through to the atomic install that enforces them.
        local need_install=0 cur_mode cur_owner
        cur_mode=$(stat -c '%a' "$target" 2>/dev/null || echo '')
        if [[ -z "$cur_mode" || ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( 8#$cur_mode != 8#$mode )); then
            need_install=1
        elif (( EUID == 0 )); then
            cur_owner=$(stat -c '%u:%g' "$target" 2>/dev/null || echo '')
            [[ "$cur_owner" == '0:0' ]] || need_install=1
        fi
        if (( need_install == 1 )); then
            install_file_atomically "$tmp" "$target" "$mode" || { rm -f "$tmp"; return 1; }
        fi
        rm -f "$tmp"
    else
        install_file_atomically "$tmp" "$target" "$mode" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
}

validate_abox_script_file() {
    local f="$1" context="${2:-script}"
    [[ -s "$f" ]] || { printf '%s\n' "$(tprintf vs_empty "$context")" >&2; return 1; }
    bash -n "$f" >/dev/null 2>&1 || { printf '%s\n' "$(tprintf vs_syntax "$context")" >&2; return 1; }
    grep -q '==============================A-Box===============================' "$f" || { printf '%s\n' "$(tprintf vs_fingerprint "$context")" >&2; return 1; }
    grep -q '^main "\$@"' "$f" || { printf '%s\n' "$(tprintf vs_entry "$context")" >&2; return 1; }
}


resolve_abox_main_commit_url() {
    local api='https://api.github.com/repos/alariclin/A-Box/commits/main' json sha
    json=$(github_api_get "$api") || return 1
    sha=$(jq -r '.sha // empty' <<< "$json" 2>/dev/null)
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf 'https://raw.githubusercontent.com/alariclin/A-Box/%s/install.sh\n' "$sha"
}

install_remote_abox_script_guarded() {
    local url="$1" dest="$2" tmp sha resolved_url
    if [[ "$url" == 'https://raw.githubusercontent.com/alariclin/A-Box/main/install.sh' ]]; then
        resolved_url=$(resolve_abox_main_commit_url) || die "$(tr_msg ir_resolve)"
        url="$resolved_url"
    fi
    tmp=$(umask 077; mktemp /tmp/A-Box-script.XXXXXX) || die "$(tr_msg ir_tmp)"
    abox_run_wait "$(tr_msg ir_dl_label)" curl -fLs --proto =https --proto-redir =https --connect-timeout 10 -m 60 "$url" -o "$tmp" || { rm -f -- "$tmp"; die "$(tr_msg ir_download)"; }
    if ! ( validate_abox_script_file "$tmp" "$(tr_msg install_remote_abox_script_guarded_remote_script)" && validate_ota_version_direction "$tmp" ); then
        rm -f -- "$tmp"
        die "$(tr_msg ir_verify)"
    fi
    sha=$(sha256sum "$tmp" | awk '{print $1}')
    msg "${YELLOW}[*] Remote script SHA256: ${sha}${NC}"
    confirm_ota_script_hash "$sha" "$url" || { rm -f -- "$tmp"; die "$(tr_msg ir_cancelled)"; }
    write_if_changed "$dest" "$tmp" 700 || { rm -f -- "$tmp"; die "$(tr_msg ir_persist)"; }
    rm -f -- "$tmp"
    # H-08: a successful OTA write must not leave a stale guard runner
    # behind: rebuild it from the running script -- but only when $0
    # is a real script file (under `curl | bash`, $0 is /bin/bash and
    # must never be copied into the runner).
    local _ota_zero_base
    _ota_zero_base=$(basename -- "$0" 2>/dev/null || printf '%s' "$0")
    if [[ "$_ota_zero_base" != 'bash' && "$_ota_zero_base" != '-bash' ]]; then
        setup_user_guard >/dev/null 2>&1 || msg "${YELLOW}[!] User-guard runner was not refreshed after the script update; open the multi-user menu once to rebuild it.${NC}" >&2
    fi
}

setup_shortcut() {
    ensure_abox_dir_owned "$ABOX_DIR" || return 1
    # S49 (argon P2-3): compare basename($0), not $0 itself: under
    # 'curl ... | /bin/bash', $0 is /bin/bash -- an existing readable
    # file that is neither bare 'bash' nor '-bash' -- so the old test
    # took the file branch and died validating the bash binary, while
    # the pipe branch (which downloads the guarded remote script) was
    # unreachable. Normal script paths are unaffected (their basename
    # is the script name, never bash/-bash, unless the script itself is
    # named bash -- a fail-safe misroute into re-downloading).
    local _zero_base
    _zero_base=$(basename -- "$0" 2>/dev/null || printf '%s' "$0")
    if [[ -f "$0" && -r "$0" && "$_zero_base" != 'bash' && "$_zero_base" != '-bash' ]]; then
        validate_abox_script_file "$0" "$(tr_msg ss2_ctx_current)" || die "$(tr_msg ss2_self_verify)"
        if [[ -f "$ABOX_DIR/A-Box.sh" ]]; then
            local current_build_epoch remote_build_epoch
            current_build_epoch=$(awk -F= '/^ABOX_BUILD_EPOCH=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$ABOX_DIR/A-Box.sh" 2>/dev/null || true)
            remote_build_epoch=$(awk -F= '/^ABOX_BUILD_EPOCH=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$0" 2>/dev/null || true)
            if [[ "$current_build_epoch" =~ ^[0-9]+$ && "$remote_build_epoch" =~ ^[0-9]+$ ]] && (( 10#$remote_build_epoch < 10#$current_build_epoch )); then
                confirm_yes_no "$(tr_msg ss2_downgrade_prompt)" || die "$(tr_msg ss2_refuse_downgrade)"
            fi
        fi
        if [[ ! -f "$ABOX_DIR/A-Box.sh" ]] || ! cmp -s "$0" "$ABOX_DIR/A-Box.sh"; then
            install_binary_atomically "$0" "$ABOX_DIR/A-Box.sh" || die "$(tr_msg ss2_persist)"
        fi
    else
        # A piped invocation has no readable $0 file to persist.
        if [[ -f "$ABOX_DIR/A-Box.sh" && ! -L "$ABOX_DIR/A-Box.sh" ]]; then
            local installed_epoch=''
            installed_epoch=$(awk -F= '/^ABOX_BUILD_EPOCH=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$ABOX_DIR/A-Box.sh" 2>/dev/null || true)
            if [[ "$installed_epoch" =~ ^[0-9]+$ ]] && (( 10#$installed_epoch > 10#$ABOX_BUILD_EPOCH )); then
                msg "${YELLOW}[!] $(tprintf setup_shortcut_keep_newer "${installed_epoch}")${NC}"
            else
                install_remote_abox_script_guarded "$SCRIPT_URL" "$ABOX_DIR/A-Box.sh"
            fi
        else
            install_remote_abox_script_guarded "$SCRIPT_URL" "$ABOX_DIR/A-Box.sh"
        fi
    fi
    # R6-04: a content-identical install must not preserve dangerous
    # write perms on the persisted script: strip group/other write
    # (go-w only -- never force 755, which would loosen 0700/0750),
    # and refuse a symlinked destination instead of chmod-following it.
    [[ -f "$ABOX_DIR/A-Box.sh" && ! -L "$ABOX_DIR/A-Box.sh" ]] || die "$(tr_msg ss2_persist_missing)"
    validate_abox_script_file "$ABOX_DIR/A-Box.sh" "$(tr_msg ss2_ctx_persisted)" || die "$(tr_msg ss2_persist_verify)"
    # R16-F06-02: a content-identical install must not preserve a non-root
    # owner on the persisted script (the atomic install that would have
    # normalized it is skipped): repair the owner to 0:0; a failed lookup
    # or repair is fatal. Owner only -- group write is handled by go-w
    # below, and the group itself is harmless once go-w is stripped.
    local _abox_owner_uid
    _abox_owner_uid=$(stat -c %u "$ABOX_DIR/A-Box.sh" 2>/dev/null) || die "$(tr_msg ss2_chmod)"
    if [[ "$_abox_owner_uid" != 0 ]]; then
        chown 0:0 -- "$ABOX_DIR/A-Box.sh" || die "$(tr_msg ss2_chmod)"
    fi
    if ! path_mode_has_no_group_other_write "$ABOX_DIR/A-Box.sh"; then
        chmod go-w -- "$ABOX_DIR/A-Box.sh" || die "$(tr_msg ss2_chmod)"
    fi
    chmod +x -- "$ABOX_DIR/A-Box.sh" || die "$(tr_msg ss2_chmod)"

    # Shortcut entries are managed centrally (shortcut_ensure): the active
    # name set lives in /etc/ddr/.shortcut (default "ab abox"); the old
    # /usr/local/bin/sb is out of scope and is never touched here. A
    # shortcut failure never fails the install: shortcut_ensure already
    # reports the direct launch path (bash /etc/ddr/A-Box.sh).
    shortcut_ensure || true
}
validate_downloaded_asset() {
    local asset_name="$1" f="${2:-/tmp/$1}" magic=''
    [[ -s "$f" ]] || { printf '%s\n' "$(tprintf va_empty "$asset_name")" >&2; return 1; }
    case "$asset_name" in
        xray_core.zip)
            unzip -tqq "$f" >/dev/null 2>&1 || { printf '%s\n' "$(tr_msg va_xray_zip)" >&2; return 1; }
            ;;
        singbox_core.tar.gz)
            tar -tzf "$f" >/dev/null 2>&1 || { printf '%s\n' "$(tr_msg va_sb_tar)" >&2; return 1; }
            ;;
        hysteria_core)
            magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n' || true)
            [[ "$magic" == '7f454c46' ]] || { printf '%s\n' "$(tr_msg va_hy2_elf)" >&2; return 1; }
            ;;
        *)
            printf '%s\n' "$(tprintf va_undefined "$asset_name")" >&2
            return 1
            ;;
    esac
}


# M-15(4): temp dir for executing a staged binary/script. /tmp is often
# mounted noexec, and $TMPDIR is caller-controlled, so probe each candidate
# by actually executing a trivial script inside it; fall back to /var/tmp,
# then /etc/ddr, then /tmp. Prints the directory path. Returns 1 when no
# candidate can both hold and execute a file, so callers keep their
# fail-closed behaviour.
abox_mktemp_exec_dir() {
    local prefix="$1" base='' dir='' probe=''
    local -a _bases=()
    _bases=("${TMPDIR:-/tmp}" /var/tmp /etc/ddr /tmp)
    for base in "${_bases[@]}"; do
        [[ "$base" == /* && -d "$base" ]] || continue
        dir=$(mktemp -d "$base/$prefix.XXXXXX" 2>/dev/null) || continue
        probe="$dir/.abox-exec-probe"
        if printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null && chmod 700 "$probe" 2>/dev/null && "$probe" >/dev/null 2>&1; then
            rm -f -- "$probe"
            printf '%s\n' "$dir"
            return 0
        fi
        rm -rf -- "$dir"
    done
    return 1
}

# Return codes: 0 = version matches the tag; 1 = version mismatch (or
# a setup failure: bad input, extract/chmod failure, unknown asset);
# 2 = the binary could not be executed (e.g. a noexec workdir) or
# produced no output -- NOT a version mismatch; callers must report
# 2 separately (S50, argon P2-2).
validate_core_asset_binary_version() {
    local asset_name="${1:-}" f="${2:-}" expected_ref="${3:-}" workdir='' binary='' output=''
    [[ -s "$f" && -n "$expected_ref" ]] || return 1
    workdir=$(abox_mktemp_exec_dir A-Box-core-version) || return 1
    case "$asset_name" in
        xray_core.zip)
            binary="$workdir/xray"
            if ! extract_zip_member_safely "$f" xray "$binary"; then rm -rf -- "$workdir"; return 1; fi
            chmod 700 "$binary" || { rm -rf -- "$workdir"; return 1; }
            output=$("$binary" version 2>&1) || { rm -rf -- "$workdir"; return 2; }
            [[ -n "$output" ]] || { rm -rf -- "$workdir"; return 2; }
            ;;
        singbox_core.tar.gz)
            binary="$workdir/sing-box"
            if ! extract_tar_regular_basename_safely "$f" sing-box "$binary"; then rm -rf -- "$workdir"; return 1; fi
            chmod 700 "$binary" || { rm -rf -- "$workdir"; return 1; }
            output=$("$binary" version 2>&1) || { rm -rf -- "$workdir"; return 2; }
            [[ -n "$output" ]] || { rm -rf -- "$workdir"; return 2; }
            ;;
        hysteria_core)
            # R6-06: a bare $f with no '/' would resolve through PATH
            # instead of the downloaded file; pin it to this directory.
            [[ "$f" == */* ]] || f="./$f"
            chmod 700 "$f" 2>/dev/null || { rm -rf -- "$workdir"; return 1; }
            output=$("$f" version 2>&1) || { rm -rf -- "$workdir"; return 2; }
            [[ -n "$output" ]] || { rm -rf -- "$workdir"; return 2; }
            ;;
        *) rm -rf -- "$workdir"; return 1 ;;
    esac
    if ! core_binary_matches_release_ref "$expected_ref" "$output"; then
        printf 'Core binary version does not match selected Release tag %s: %s\n' "$expected_ref" "$output" >&2
        rm -rf -- "$workdir"
        return 1
    fi
    rm -rf -- "$workdir"
    return 0
}

extract_zip_member_safely() {
    local archive="$1" member="$2" dest="$3"
    [[ -s "$archive" && -n "$member" && -n "$dest" ]] || return 1
    python3 -I - "$archive" "$member" "$dest" <<'PY_ZIP_EXTRACT'
import os, shutil, stat, sys, zipfile
archive, member, dest = sys.argv[1:]
MAX_FILE = 512 * 1024 * 1024
created = False
try:
    if os.path.lexists(dest): raise ValueError('destination exists')
    with zipfile.ZipFile(archive) as zf:
        matches = [x for x in zf.infolist() if x.filename == member]
        if len(matches) != 1: raise ValueError('member count')
        info = matches[0]
        mode = (info.external_attr >> 16) & 0o170000
        if info.is_dir() or mode == stat.S_IFLNK: raise ValueError('not regular')
        if info.file_size <= 0 or info.file_size > MAX_FILE: raise ValueError('size')
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, 'O_NOFOLLOW'): flags |= os.O_NOFOLLOW
        fd = os.open(dest, flags, 0o600)
        created = True
        try:
            with zf.open(info, 'r') as src, os.fdopen(fd, 'wb', closefd=False) as out:
                remaining = MAX_FILE + 1
                while True:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk: break
                    out.write(chunk); remaining -= len(chunk)
                    if remaining <= 0: raise ValueError('expanded size')
                out.flush(); os.fsync(out.fileno())
        finally:
            os.close(fd)
except Exception:
    if created:
        try: os.unlink(dest)
        except OSError: pass
    raise SystemExit(1)
PY_ZIP_EXTRACT
}

extract_tar_regular_basename_safely() {
    local archive="$1" basename="$2" dest="$3"
    [[ -s "$archive" && "$basename" =~ ^[A-Za-z0-9._-]+$ && -n "$dest" ]] || return 1
    python3 -I - "$archive" "$basename" "$dest" <<'PY_TAR_EXTRACT'
import os, posixpath, sys, tarfile
import resource
# S6 (R51-M1 follow-up): bound this process's address space. tarfile
# reads PAX/GNU longname extension headers whole into memory before
# yielding the next member, so the member/size/total caps cannot bound
# them (a 100 MB header peaked at 612 MB RSS in trial; the extractor
# peaked at 912 MB). A 512 MiB cap fails closed (MemoryError -> non-zero
# exit) on a crafted giant header while leaving ~30x headroom over
# legitimate archives (baseline VSZ ~17 MB, legit RSS ~12 MB).
try:
    _hard = resource.getrlimit(resource.RLIMIT_AS)[1]
    if _hard != resource.RLIM_INFINITY:
        _cap = min(512 * 1024 * 1024, _hard)
    else:
        _cap = 512 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (_cap, _hard))
except Exception:
    raise SystemExit(1)
archive, wanted, dest = sys.argv[1:]
MAX_MEMBERS = 10000
MAX_FILE = 512 * 1024 * 1024
created = False
try:
    if os.path.lexists(dest): raise ValueError('destination exists')
    with tarfile.open(archive, 'r:gz') as tf:
        # Stream enumeration, bounded by MAX_MEMBERS: CPython caches
        # iterated TarInfo objects, so this is bounded-by-cap, not
        # constant memory. The count check runs before further
        # enumeration, so a hostile archive cannot force unbounded
        # member materialization (same discipline as the U209 validators).
        matches = []
        _count = 0
        for m in tf:
            _count += 1
            if _count > MAX_MEMBERS: raise ValueError('member count')
            raw = m.name
            if '\x00' in raw or raw.startswith('/'): raise ValueError('path')
            while raw.startswith('./'): raw = raw[2:]
            norm = posixpath.normpath(raw)
            if norm in ('', '.'):
                continue
            if norm == '..' or norm.startswith('../'): raise ValueError('path')
            if m.issym() or m.islnk() or m.ischr() or m.isblk() or m.isfifo() or m.isdev():
                raise ValueError('special member')
            if not (m.isfile() or m.isdir()): raise ValueError('unknown member')
            if m.isfile() and posixpath.basename(norm) == wanted:
                matches.append(m)
        if len(matches) != 1: raise ValueError('binary member count')
        target = matches[0]
        if target.size <= 0 or target.size > MAX_FILE: raise ValueError('size')
        src = tf.extractfile(target)
        if src is None: raise ValueError('extract')
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, 'O_NOFOLLOW'): flags |= os.O_NOFOLLOW
        fd = os.open(dest, flags, 0o600)
        created = True
        try:
            with src, os.fdopen(fd, 'wb', closefd=False) as out:
                remaining = MAX_FILE + 1
                while True:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk: break
                    out.write(chunk); remaining -= len(chunk)
                    if remaining <= 0: raise ValueError('expanded size')
                out.flush(); os.fsync(out.fileno())
        finally:
            os.close(fd)
except Exception:
    if created:
        try: os.unlink(dest)
        except OSError: pass
    raise SystemExit(1)
PY_TAR_EXTRACT
}

# B-C2 (final-round): total budget for the "services stopped, config not
# yet written" fetch segment of a (re)deployment. The guard is armed by
# abox_fetch_guard_start just before release_ports and disarmed by
# abox_fetch_guard_stop once every download is verified and staged; every
# fetch primitive checks the deadline at each retry boundary and caps its
# own curl -m at the remaining budget, so a hung download can never
# outlive the budget by more than one in-flight call. On expiry the
# caller dies and the existing deployment transaction rolls the
# pre-deployment snapshot back -- no kill, no signal trap required.
# ABOX_FETCH_TOTAL_BUDGET_SECONDS may be overridden in the environment;
# the watchdog grace is ABOX_FETCH_WATCHDOG_GRACE_SECONDS (60s).
ABOX_FETCH_TOTAL_BUDGET_SECONDS="${ABOX_FETCH_TOTAL_BUDGET_SECONDS:-300}"
ABOX_FETCH_DEADLINE_EPOCH=''
ABOX_FETCH_SEGMENT_START=''
ABOX_FETCH_SEGMENT_LABEL=''
ABOX_FETCH_WATCHDOG_DIR=''
ABOX_FETCH_WATCHDOG_PID=''
ABOX_DEPLOY_ROLLBACK_STATE_FILE='/run/A-Box-deploy-rollback-state'
ABOX_DEPLOY_WATCHDOG_STALL_FILE='/run/A-Box-deploy-watchdog-stall.log'

abox_fetch_deadline_remaining() {
    local _now
    [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]] || return 1
    [[ "$ABOX_FETCH_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] || return 1
    _now=$(date +%s 2>/dev/null || printf '0')
    [[ "$_now" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( ABOX_FETCH_DEADLINE_EPOCH - _now ))"
    return 0
}

# Returns 0 when no budget is armed or budget remains; 1 when expired.
abox_fetch_deadline_check() {
    local _label="${1:-fetch}" _remaining
    _remaining=$(abox_fetch_deadline_remaining 2>/dev/null) || return 0
    (( _remaining > 0 )) && return 0
    printf '%s\n' "[A-Box][fetch-budget] total fetch budget (${ABOX_FETCH_TOTAL_BUDGET_SECONDS:-300}s) expired during ${_label}; aborting so the deployment transaction rolls back." >&2
    return 1
}

# Prints the curl -m cap for one call: min(default, remaining budget).
# Returns 1 when the budget is already spent (caller must not start).
abox_fetch_curl_max_time() {
    local _def="${1:-60}" _remaining
    [[ "$_def" =~ ^[0-9]+$ ]] || _def=60
    _remaining=$(abox_fetch_deadline_remaining 2>/dev/null) || { printf '%s\n' "$_def"; return 0; }
    (( _remaining <= 0 )) && return 1
    (( _remaining < _def )) && printf '%s\n' "$_remaining" || printf '%s\n' "$_def"
    return 0
}

abox_fetch_heartbeat() {
    [[ -n "${ABOX_FETCH_WATCHDOG_DIR:-}" && -d "$ABOX_FETCH_WATCHDOG_DIR" ]] || return 0
    : > "$ABOX_FETCH_WATCHDOG_DIR/heartbeat" 2>/dev/null || true
    return 0
}

abox_fetch_guard_start() {
    local _label="${1:-deploy}" _seconds="${2:-${ABOX_FETCH_TOTAL_BUDGET_SECONDS:-300}}" _now _srv
    [[ "$_seconds" =~ ^[0-9]+$ ]] || _seconds=300
    # R22-01: normalize to decimal -- a leading zero (08/010) would
    # otherwise be read as octal by $((...)) (08 errors and aborts
    # the guard, 010 silently means 8).
    _seconds=$((10#$_seconds))
    _now=$(date +%s 2>/dev/null || printf '0')
    ABOX_FETCH_DEADLINE_EPOCH=$(( _now + _seconds ))
    ABOX_FETCH_TOTAL_BUDGET_SECONDS="$_seconds"
    ABOX_FETCH_SEGMENT_START="$_now"
    ABOX_FETCH_SEGMENT_LABEL="$_label"
    ABOX_FETCH_WATCHDOG_DIR=$(mktemp -d /tmp/A-Box-fetch-watchdog.XXXXXX 2>/dev/null) || ABOX_FETCH_WATCHDOG_DIR=''
    if [[ -n "$ABOX_FETCH_WATCHDOG_DIR" ]]; then
        : > "$ABOX_FETCH_WATCHDOG_DIR/heartbeat" 2>/dev/null || true
        # Snapshot of the services running right now (pre-stop): if the
        # foreground stalls past the budget, the watchdog restarts exactly
        # these with their still-untouched configs.
        : > "$ABOX_FETCH_WATCHDOG_DIR/services" 2>/dev/null || true
        for _srv in xray sing-box hysteria; do
            if abox_owns_service "$_srv" 2>/dev/null && is_service_running "$_srv" 2>/dev/null; then
                printf '%s\n' "$_srv" >> "$ABOX_FETCH_WATCHDOG_DIR/services" 2>/dev/null || true
            fi
        done
        ( trap - EXIT INT TERM HUP; ABOX_DIE_HOOK=''; ABOX_DEPLOY_TX_ACTIVE=0; abox_deploy_watchdog_loop "$ABOX_FETCH_WATCHDOG_DIR" "$$" "$ABOX_FETCH_DEADLINE_EPOCH" "$_label" ) & ABOX_FETCH_WATCHDOG_PID=$!
    fi
    msg "[fetch] ${_label}: fetch segment started at $(now_iso) (total budget ${_seconds}s; on timeout the deployment rolls back)"
    return 0
}

abox_fetch_guard_stop() {
    local _now _elapsed
    if [[ -n "${ABOX_FETCH_WATCHDOG_DIR:-}" && -d "$ABOX_FETCH_WATCHDOG_DIR" ]]; then
        : > "$ABOX_FETCH_WATCHDOG_DIR/done" 2>/dev/null || true
    fi
    if [[ -n "${ABOX_FETCH_WATCHDOG_PID:-}" ]]; then
        kill "$ABOX_FETCH_WATCHDOG_PID" 2>/dev/null || true
        wait "$ABOX_FETCH_WATCHDOG_PID" 2>/dev/null || true
        ABOX_FETCH_WATCHDOG_PID=''
    fi
    if [[ -n "${ABOX_FETCH_WATCHDOG_DIR:-}" ]]; then
        rm -rf -- "$ABOX_FETCH_WATCHDOG_DIR" 2>/dev/null || true
        ABOX_FETCH_WATCHDOG_DIR=''
    fi
    if [[ -n "${ABOX_FETCH_SEGMENT_START:-}" ]]; then
        _now=$(date +%s 2>/dev/null || printf '0')
        if [[ "$_now" =~ ^[0-9]+$ && "$ABOX_FETCH_SEGMENT_START" =~ ^[0-9]+$ ]]; then
            _elapsed=$(( _now - ABOX_FETCH_SEGMENT_START ))
            msg "[fetch] ${ABOX_FETCH_SEGMENT_LABEL:-deploy}: fetch segment finished in ${_elapsed}s"
        fi
    fi
    ABOX_FETCH_DEADLINE_EPOCH=''
    ABOX_FETCH_SEGMENT_START=''
    return 0
}

# Background watchdog for the fetch segment. Runs in a child subshell;
# its first act is to drop the inherited deployment transaction traps,
# so it can never roll back from the child. It exits silently when the
# parent dies or the segment completes (done marker). Only when the
# deadline plus grace has passed with no completion does it fire once:
# it lands a stall state file and best-effort restarts the pre-stop
# snapshot services. It never kills anything and never touches config;
# the foreground, on regaining control, still hits its deadline checks
# and dies into the normal transaction rollback.
abox_deploy_watchdog_loop() {
    trap - EXIT INT TERM HUP
    ABOX_DIE_HOOK=''
    ABOX_DEPLOY_TX_ACTIVE=0
    local _dir="$1" _parent="$2" _deadline="$3" _label="$4"
    local _grace _now _stall _last_hb _srv _rc _rs_mtime _rollback_state
    _grace="${ABOX_FETCH_WATCHDOG_GRACE_SECONDS:-60}"
    [[ "$_grace" =~ ^[0-9]+$ ]] || _grace=60
    # R22-01: normalize to decimal (see abox_fetch_guard_start) --
    # 08 would make (( _now < _deadline + _grace )) fail and the
    # watchdog would enter the recovery branch on its first poll.
    _grace=$((10#$_grace))
    _stall="${ABOX_DEPLOY_WATCHDOG_STALL_FILE:-/run/A-Box-deploy-watchdog-stall.log}"
    _rollback_state="${ABOX_DEPLOY_ROLLBACK_STATE_FILE:-/run/A-Box-deploy-rollback-state}"
    while true; do
        sleep 5
        kill -0 "$_parent" 2>/dev/null || exit 0
        [[ -f "$_dir/done" ]] && exit 0
        _now=$(date +%s 2>/dev/null || printf '0')
        [[ "$_now" =~ ^[0-9]+$ ]] || continue
        (( _now < _deadline + _grace )) && continue
        # A rollback already in progress owns recovery now; stand down.
        if [[ -f "$_rollback_state" ]]; then
            _rs_mtime=$(stat -c %Y "$_rollback_state" 2>/dev/null || printf '0')
            if [[ "$_rs_mtime" =~ ^[0-9]+$ ]] && (( _rs_mtime >= _deadline )); then exit 0; fi
        fi
        _last_hb='unknown'
        [[ -f "$_dir/heartbeat" ]] && _last_hb=$(stat -c %y "$_dir/heartbeat" 2>/dev/null || printf 'unknown')
        {
            printf 'A-Box deploy watchdog stall\n'
            printf 'label: %s\n' "$_label"
            printf 'time: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'unknown')"
            printf 'watchdog_pid: %s\n' "$BASHPID"
            printf 'deadline_epoch: %s\n' "$_deadline"
            printf 'last_heartbeat: %s\n' "$_last_hb"
        } > "$_stall" 2>/dev/null || true
        if [[ -f "$_dir/services" ]]; then
            while IFS= read -r _srv || [[ -n "$_srv" ]]; do
                [[ -n "$_srv" ]] || continue
                _rc=0
                if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                    systemctl start "$_srv" >/dev/null 2>&1 || _rc=$?
                elif command -v rc-service >/dev/null 2>&1; then
                    rc-service "$_srv" start >/dev/null 2>&1 || _rc=$?
                else
                    _rc=127
                fi
                printf 'restart %s: rc=%s\n' "$_srv" "$_rc" >> "$_stall" 2>/dev/null || true
            done < "$_dir/services"
        fi
        exit 0
    done
}

github_api_get() {
    local url="$1" attempt=1 max_attempts=3 delay=1 rc http_code tmp headers retry_after remaining reset_epoch now _api_max_time=60 _sleep_for=0 _sleep_remaining=''
    local -a args=()
    [[ -n "$url" ]] || return 1
    if [[ "${GITHUB_API_RETRY_DELAY:-1}" =~ ^[0-9]+$ ]]; then
        delay=$((10#${GITHUB_API_RETRY_DELAY:-1}))
    elif [[ -n "${GITHUB_API_RETRY_DELAY:-}" ]]; then
        return 1
    fi
    tmp=$(umask 077; mktemp /tmp/A-Box-github-api.XXXXXX) || return 1
    headers=$(umask 077; mktemp /tmp/A-Box-github-api-headers.XXXXXX) || { rm -f -- "$tmp"; return 1; }
    args=(-sS -L --proto =https --proto-redir =https --connect-timeout 10 -m 60 -D "$headers"
        -H 'Accept: application/vnd.github+json'
        -H 'X-GitHub-Api-Version: 2026-03-10' -o "$tmp")
    while (( attempt <= max_attempts )); do
        # B-C2: total fetch budget -- stop the retry course at once when
        # the deploy fetch segment budget is spent; never sleep past it.
        # Helpers are consulted only when a budget is armed
        # (ABOX_FETCH_DEADLINE_EPOCH); unarmed callers -- including
        # fixtures that extract this function standalone -- keep the
        # previous uncapped behaviour verbatim.
        _api_max_time=60
        if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
            abox_fetch_deadline_check "github_api_get $url" || { rm -f -- "$tmp" "$headers"; return 1; }
            _api_max_time=$(abox_fetch_curl_max_time 60) || { rm -f -- "$tmp" "$headers"; return 1; }
        fi
        args=(-sS -L --proto =https --proto-redir =https --connect-timeout 10 -m "$_api_max_time" -D "$headers"
            -H 'Accept: application/vnd.github+json'
            -H 'X-GitHub-Api-Version: 2026-03-10' -o "$tmp")
        : > "$headers" || { rm -f -- "$tmp" "$headers"; return 1; }
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
            [[ "${GITHUB_TOKEN}" != *[$'\r\n"\\']* ]] || { rm -f -- "$tmp" "$headers"; return 1; }
            http_code=$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" | curl "${args[@]}" -w '%{http_code}' --config - "$url" 2>/dev/null)
            rc=$?
        else
            http_code=$(curl "${args[@]}" -w '%{http_code}' "$url" 2>/dev/null)
            rc=$?
        fi
        if (( rc == 0 )) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            cat -- "$tmp"
            rc=$?
            rm -f -- "$tmp" "$headers"
            return "$rc"
        fi
        retry_after=$(awk 'tolower($1)=="retry-after:" {gsub("\r","",$2); value=$2} END {print value}' "$headers" 2>/dev/null)
        remaining=$(awk 'tolower($1)=="x-ratelimit-remaining:" {gsub("\r","",$2); value=$2} END {print value}' "$headers" 2>/dev/null)
        reset_epoch=$(awk 'tolower($1)=="x-ratelimit-reset:" {gsub("\r","",$2); value=$2} END {print value}' "$headers" 2>/dev/null)
        if (( rc == 0 )) && [[ "$http_code" =~ ^5[0-9][0-9]$ ]]; then
            :
        elif (( rc == 0 )) && { [[ "$http_code" == 429 ]] || { [[ "$http_code" == 403 ]] && { [[ "$remaining" == 0 ]] || [[ -n "$retry_after" ]]; }; }; }; then
            if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
                delay=$((10#$retry_after))
            elif [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
                now=$(date +%s 2>/dev/null || printf '0')
                if [[ "$now" =~ ^[0-9]+$ ]] && (( 10#$reset_epoch > now )); then
                    delay=$((10#$reset_epoch - now))
                fi
            fi
            [[ -n "${GITHUB_TOKEN:-}" ]] || printf '%s\n' 'GitHub API rate limit detected; set GITHUB_TOKEN for a higher authenticated limit.' >&2
        elif (( rc == 5 || rc == 6 || rc == 7 || rc == 18 || rc == 28 || rc == 35 || rc == 52 || rc == 56 )); then
            :
        else
            if [[ "$http_code" == 403 && -z "${GITHUB_TOKEN:-}" ]]; then
                printf '%s\n' 'GitHub API returned 403; shared anonymous API rate limits may be exhausted.' >&2
            fi
            rm -f -- "$tmp" "$headers"
            return 1
        fi
        if (( attempt == max_attempts )); then break; fi
        if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
            abox_fetch_deadline_check "github_api_get $url" || { rm -f -- "$tmp" "$headers"; return 1; }
        fi
        if (( delay > 30 )); then delay=30; fi
        # R22-02 (B-C2): never sleep past the remaining budget -- cap
        # the retry wait at the seconds left, and abort at once when
        # none remain. Unarmed callers keep the uncapped behaviour.
        _sleep_for=$delay
        if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
            _sleep_remaining=$(abox_fetch_deadline_remaining 2>/dev/null) || _sleep_remaining=''
            if [[ "$_sleep_remaining" =~ ^-?[0-9]+$ ]]; then
                (( _sleep_remaining <= 0 )) && { rm -f -- "$tmp" "$headers"; return 1; }
                (( _sleep_remaining < _sleep_for )) && _sleep_for=$_sleep_remaining
            fi
        fi
        if (( _sleep_for > 0 )); then sleep "$_sleep_for"; fi
        if (( delay < 30 )); then delay=$((delay * 2)); fi
        attempt=$((attempt + 1))
    done
    rm -f -- "$tmp" "$headers"
    return 1
}

verify_github_asset_digest() {
    local file="$1" digest="${2:-}" expected actual
    if [[ -z "$digest" || "$digest" == 'null' ]]; then
        printf '%s\n' "$(tr_msg vg_missing)" >&2
        return 1
    fi
    [[ "$digest" == sha256:* ]] || { printf '%s\n' "$(tr_msg vg_not_sha)" >&2; return 1; }
    expected="${digest#sha256:}"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || { printf '%s\n' "$(tr_msg vg_bad_format)" >&2; return 1; }
    actual=$(sha256sum < "$file" 2>/dev/null | awk '{print $1}') || actual=''
    [[ "${actual,,}" == "${expected,,}" ]] || { printf '%s\n' "$(tr_msg vg_mismatch)" >&2; return 1; }
}

# ============ F-05: Ed25519 detached signature verification ============
# Uses ONLY openssl + python3 (both guaranteed by ensure_commands).
# .sig files are base64 text of the raw 64-byte Ed25519 signature.
# F8: probe OpenSSL Ed25519/rawin capability. Ed25519 needs OpenSSL 1.1.1+;
# -rawin for pkeyutl needs 3.0+. Cache the result.
# Contract (S41-V-C): a cached "unsupported" verdict (OK=1) means the
# platform OpenSSL CLI deterministically lacks Ed25519 or pkeyutl -rawin.
# It does NOT mean verification is impossible: the gate first tries the
# ctypes libcrypto verifier (verify_ed25519_detached_ctypes), which uses
# the same libcrypto EVP one-shot API the CLI -rawin path uses internally.
# Only when no verifier confirms the signature does the gate fail closed
# under ABOX_SIGNING_ENFORCE=1 (FATAL, return 1); under ENFORCE=0 it warns
# and returns 0. Only a definitive algorithm-unsupported error may set
# the cached verdict; anything else is PROBE_FAILED (also fail-closed).
_openssl_has_ed25519() {
    if [[ -n "${_OPENSSL_ED25519_OK:-}" ]]; then
        _OPENSSL_ED25519_PROBE_FAILED=0
        return "$_OPENSSL_ED25519_OK"
    fi
    _OPENSSL_ED25519_PROBE_FAILED=0
    # PROBE-ERROR must not be cached: only a DEFINITIVE "algorithm unsupported"
    # is a platform capability answer. Infrastructure failures (mktemp, ENOSPC)
    # are transient and must force fail-closed, not fail-open.
    local _t _err
    _t=$(mktemp -d 2>/dev/null) || { _OPENSSL_ED25519_PROBE_FAILED=1; return 1; }
    printf 'test' > "$_t/in.bin" 2>/dev/null || { _OPENSSL_ED25519_PROBE_FAILED=1; rm -rf -- "$_t"; return 1; }
    _err="$_t/err"
    if ! openssl genpkey -algorithm ed25519 -out "$_t/priv.pem" 2>"$_err"; then
        # S41 (GPT-9 + argon P1-2): cache "unsupported" ONLY on
        # algorithm-specific signals. The cached verdict is what the gate
        # treats as the DS-Q4 exemption (CentOS 7 / OpenSSL 1.0.2, warn
        # and continue even under ENFORCE), so a bare "not found" /
        # "no such" must never reach it: "command not found" (openssl
        # binary missing), a missing shared object, or a missing
        # OPENSSL_CONF file are infrastructure failures, not platform
        # capability answers. They set PROBE_FAILED, so the gate fails
        # closed (FATAL under ENFORCE, retryable) instead of silently
        # exempting. A genuine-but-unlisted message likewise fails
        # closed via PROBE_FAILED; that is the safe direction.
        if grep -qiE 'unknown[ _]algorithm|no such algorithm|unsupported algorithm|algorithm.*not found' "$_err" 2>/dev/null; then
            _OPENSSL_ED25519_OK=1
        else
            _OPENSSL_ED25519_PROBE_FAILED=1
        fi
        rm -rf -- "$_t"
        return 1
    fi
    # Probe: pkeyutl -rawin support. Note: -rawin requires file input,
    # not stdin pipe (oneshot operation needs file size).
    if ! openssl pkeyutl -sign -inkey "$_t/priv.pem" -rawin -in "$_t/in.bin" -out "$_t/sig.bin" 2>"$_err"; then
        # Only cache when the error definitively indicates -rawin is
        # unsupported (mirrors the genpkey branch). Any other failure
        # (disk, tmp, config) is transient: mark probe-failed, do NOT
        # cache, so the gate fails closed under enforcement instead of
        # permanently treating the platform as unverifiable.
        if grep -qiE 'unknown option|invalid option|unrecogni[sz]ed|not supported|no such option' "$_err" 2>/dev/null; then
            _OPENSSL_ED25519_OK=1
        else
            _OPENSSL_ED25519_PROBE_FAILED=1
        fi
        rm -rf -- "$_t"
        return 1
    fi
    rm -rf -- "$_t"
    _OPENSSL_ED25519_OK=0
    return 0
}
# Returns 0 iff ANY non-revoked pubkey in ABOX_SIGNING_PUBKEYS verifies.
verify_ed25519_detached() {
    local file="$1" sigfile="$2"
    local entry label pubkey_b64 fp keydir keypem sigbin r revoked
    [[ -f "$file" && -f "$sigfile" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v base64 >/dev/null 2>&1 || return 1
    # S42 (GPT-10): sha256sum joins the front checks as dual insurance.
    # The fingerprint below is Python-computed, but the environment
    # contract stays fail-closed: a missing sha256sum must never again
    # silently disable the revocation check.
    command -v sha256sum >/dev/null 2>&1 || return 1
    keydir=$(umask 077; mktemp -d /tmp/A-Box-ed25519.XXXXXX 2>/dev/null) || return 1
    keypem="$keydir/pub.pem"
    sigbin="$keydir/sig.bin"
    # Signature must decode to exactly 64 raw bytes (Ed25519).
    if ! base64 -d "$sigfile" > "$sigbin" 2>/dev/null || [[ $(wc -c < "$sigbin") -ne 64 ]]; then
        rm -rf -- "$keydir"
        return 1
    fi
    # H-14: the CLI path needs pkeyutl -rawin (OpenSSL 3.0+); on hosts
    # without it (e.g. OpenSSL 1.1.1) delegate to the ctypes libcrypto
    # verifier instead of rejecting every valid signature. rc 0 =
    # verified; any other rc (invalid signature, or 2 = no verifier
    # available) maps to 1, preserving the fail-closed contract of the
    # direct callers (e.g. run_mirrored_test_script, which deliberately
    # bypasses abox_verify_sig_gate).
    if ! _openssl_has_ed25519; then
        if verify_ed25519_detached_ctypes "$file" "$sigfile"; then
            rm -rf -- "$keydir"
            return 0
        fi
        rm -rf -- "$keydir"
        return 1
    fi
    for entry in "${ABOX_SIGNING_PUBKEYS[@]}"; do
        label="${entry%%:*}"
        pubkey_b64="${entry#*:}"
        # Malformed entry (no colon) or empty key: skip.
        [[ -n "$label" && -n "$pubkey_b64" && "$pubkey_b64" != "$entry" ]] || continue
        # S42 (GPT-10 + argon P1-6b): fingerprint = SHA-256 hex of the
        # raw 32-byte pubkey, computed by Python (not the shell
        # pipeline). A decode failure or a length other than 32 yields
        # no fingerprint, and a key without a valid fingerprint is
        # skipped -- never silently treated as unrevoked (the old
        # pipeline hashed empty input to e3b0c442... on decode failure,
        # and yielded empty -- hence "unrevoked" -- when sha256sum was
        # missing). The 64-hex check states the invariant explicitly.
        fp=$(python3 -I -c "
import base64, hashlib, sys
try:
    raw = base64.b64decode(sys.argv[1], validate=True)
except Exception:
    sys.exit(1)
if len(raw) != 32:
    sys.exit(1)
print(hashlib.sha256(raw).hexdigest())
" "$pubkey_b64" 2>/dev/null)
        [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || continue
        revoked=0
        for r in "${ABOX_REVOKED_PUBKEY_FPS[@]}"; do
            if [[ "${r,,}" == "${fp,,}" ]]; then revoked=1; break; fi
        done
        (( revoked == 0 )) || continue
        # Convert base64 raw 32-byte pubkey -> PEM (SubjectPublicKeyInfo).
        # Uses python3 -c (not heredoc) to avoid multi-level escaping fragility.
        if ! python3 -I -c "
import base64, sys
try:
    raw = base64.b64decode(sys.argv[1], validate=True)
except Exception:
    sys.exit(1)
if len(raw) != 32:
    sys.exit(1)
der = bytes.fromhex('302a300506032b6570032100') + raw
pem = '-----BEGIN PUBLIC KEY-----' + chr(10) + base64.encodebytes(der).decode().strip() + chr(10) + '-----END PUBLIC KEY-----' + chr(10)
open(sys.argv[2], 'w').write(pem)
" "$pubkey_b64" "$keypem" 2>/dev/null; then
            continue
        fi
        if openssl pkeyutl -verify -pubin -inkey "$keypem" -rawin -in "$file" -sigfile "$sigbin" >/dev/null 2>&1; then
            rm -rf -- "$keydir"
            return 0
        fi
    done
    rm -rf -- "$keydir"
    return 1
}

# F-05 anti-replay: metadata timestamp (ISO UTC, e.g. 2026-10-15T02:30:00Z
# or already-compact YYYYMMDDHHMMSS) must not be older than
# ABOX_SIGNING_MIN_TIMESTAMP_UTC. Returns 0 iff acceptable.
abox_signing_timestamp_ok() {
    local ts compact min_ts min_compact
    ts="${1:-}"
    # Normalize: strip everything except digits.
    compact=$(printf '%s' "$ts" | tr -cd '0-9')
    [[ "$compact" =~ ^[0-9]{14}$ ]] || return 1
    # S46 (argon P1-6a): normalize the floor the same way. A raw floor
    # must never reach the lexicographic comparison: an ISO floor such
    # as 2026-10-15T00:00:00Z compares SMALLER than any same-year stamp
    # (character 5: '-'=45 < '0'=48), letting an earlier stamp slip past
    # the anti-replay floor. The :-0 default stays its own valid case
    # ("0" = no floor); any other non-14-digit normalized floor fails
    # closed (including fractional-second ISO floors, which strip to
    # more than 14 digits).
    min_ts="${ABOX_SIGNING_MIN_TIMESTAMP_UTC:-0}"
    min_compact=$(printf '%s' "$min_ts" | tr -cd '0-9')
    [[ "$min_compact" == "0" || "$min_compact" =~ ^[0-9]{14}$ ]] || return 1
    [[ "$compact" > "$min_compact" || "$compact" == "$min_compact" ]] || return 1
    return 0
}

# V-C: Ed25519 detached verification via python3 ctypes calling libcrypto EVP.
# Used ONLY when the OpenSSL CLI path is unavailable (no pkeyutl -rawin, i.e.
# OpenSSL 1.1.1): the underlying libcrypto has the same one-shot EVP API in
# 1.1.1 and 3.x; only the CLI flag is missing. Returns 0 = verified,
# 1 = signature invalid (or malformed input), 2 = no verifier available
# (python3/base64/sha256sum/mktemp missing, or libcrypto unloadable).
# Front checks (file/sig existence, 64-byte sig, 32-byte pubkey, fingerprint,
# revocation) mirror verify_ed25519_detached exactly.
verify_ed25519_detached_ctypes() {
    local file="$1" sigfile="$2"
    local entry label pubkey_b64 fp keydir sigbin py r revoked rc _py_write_rc
    [[ -f "$file" && -f "$sigfile" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 2
    command -v base64 >/dev/null 2>&1 || return 2
    command -v sha256sum >/dev/null 2>&1 || return 2
    keydir=$(umask 077; mktemp -d /tmp/A-Box-ed25519ct.XXXXXX 2>/dev/null) || return 2
    sigbin="$keydir/sig.bin"
    if ! base64 -d "$sigfile" > "$sigbin" 2>/dev/null || [[ $(wc -c < "$sigbin") -ne 64 ]]; then
        rm -rf -- "$keydir"
        return 1
    fi
    py="$keydir/ctypes_verify.py"
    cat > "$py" <<'PYEOF'
import base64, ctypes, ctypes.util, sys
pub_b64 = sys.argv[1]
msg_path = sys.argv[2]
sig_path = sys.argv[3]
try:
    pub = base64.b64decode(pub_b64, validate=True)
    msg = open(msg_path, 'rb').read()
    sig = open(sig_path, 'rb').read()
except Exception:
    sys.exit(1)
if len(pub) != 32 or len(sig) != 64:
    sys.exit(1)
def _capable(cand):
    try:
        cand.OBJ_sn2nid.restype = ctypes.c_int
        cand.OBJ_sn2nid.argtypes = [ctypes.c_char_p]
        _nid = cand.OBJ_sn2nid(b'ED25519')
        if _nid == 0:
            return False
        for _sym in ('EVP_MD_CTX_new', 'EVP_MD_CTX_free', 'EVP_PKEY_new_raw_public_key', 'EVP_PKEY_free', 'EVP_DigestVerifyInit', 'EVP_DigestVerify'):
            getattr(cand, _sym)
        # Trial operation: a symbol-complete but algorithm-incapable lib
        # (no-ec build, missing provider) answers the NID query yet cannot
        # create an Ed25519 key. Only a working method passes this.
        cand.EVP_PKEY_new_raw_public_key.restype = ctypes.c_void_p
        cand.EVP_PKEY_new_raw_public_key.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        cand.EVP_PKEY_free.argtypes = [ctypes.c_void_p]
        _trial = cand.EVP_PKEY_new_raw_public_key(_nid, None, bytes(32), 32)
        if not _trial:
            return False
        cand.EVP_PKEY_free(_trial)
        return True
    except Exception:
        return False
lib = None
for name in ('libcrypto.so.1.1', 'libcrypto.so.3', 'libcrypto.so'):
    try:
        _cand = ctypes.CDLL(name)
    except Exception:
        continue
    if _capable(_cand):
        lib = _cand
        break
if lib is None:
    try:
        found = ctypes.util.find_library('crypto')
        if found:
            _cand = ctypes.CDLL(found)
            if _capable(_cand):
                lib = _cand
    except Exception:
        pass
if lib is None:
    sys.exit(2)
ctx = None
pkey = None
try:
    lib.OBJ_sn2nid.restype = ctypes.c_int
    lib.OBJ_sn2nid.argtypes = [ctypes.c_char_p]
    nid = lib.OBJ_sn2nid(b'ED25519')
    if nid == 0:
        sys.exit(1)
    lib.EVP_MD_CTX_new.restype = ctypes.c_void_p
    lib.EVP_MD_CTX_new.argtypes = []
    lib.EVP_MD_CTX_free.argtypes = [ctypes.c_void_p]
    lib.EVP_MD_CTX_free.restype = None
    lib.EVP_PKEY_new_raw_public_key.restype = ctypes.c_void_p
    lib.EVP_PKEY_new_raw_public_key.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.EVP_PKEY_free.argtypes = [ctypes.c_void_p]
    lib.EVP_PKEY_free.restype = None
    lib.EVP_DigestVerifyInit.restype = ctypes.c_int
    lib.EVP_DigestVerifyInit.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.EVP_DigestVerify.restype = ctypes.c_int
    lib.EVP_DigestVerify.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
    pkey = lib.EVP_PKEY_new_raw_public_key(nid, None, pub, len(pub))
    if not pkey:
        sys.exit(1)
    ctx = lib.EVP_MD_CTX_new()
    if not ctx:
        sys.exit(1)
    if lib.EVP_DigestVerifyInit(ctx, None, None, None, pkey) != 1:
        sys.exit(1)
    rc = lib.EVP_DigestVerify(ctx, sig, len(sig), msg, len(msg))
    sys.exit(0 if rc == 1 else 1)
finally:
    if ctx:
        lib.EVP_MD_CTX_free(ctx)
    if pkey:
        lib.EVP_PKEY_free(pkey)
PYEOF
    # R6-01: a failed/empty script write must never read as "verified":
    # python3 exits 0 on an empty script, and a truncated-but-complete
    # prefix can execute and exit 0 without verifying anything. The cat
    # status (not just -s) is the guard for partial writes.
    _py_write_rc=$?
    if (( _py_write_rc != 0 )) || [[ ! -s "$py" ]]; then
        rm -rf -- "$keydir"
        return 2
    fi
    for entry in "${ABOX_SIGNING_PUBKEYS[@]}"; do
        label="${entry%%:*}"
        pubkey_b64="${entry#*:}"
        [[ -n "$label" && -n "$pubkey_b64" && "$pubkey_b64" != "$entry" ]] || continue
        fp=$(python3 -I -c "
import base64, hashlib, sys
try:
    raw = base64.b64decode(sys.argv[1], validate=True)
except Exception:
    sys.exit(1)
if len(raw) != 32:
    sys.exit(1)
print(hashlib.sha256(raw).hexdigest())
" "$pubkey_b64" 2>/dev/null)
        [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || continue
        revoked=0
        for r in "${ABOX_REVOKED_PUBKEY_FPS[@]}"; do
            if [[ "${r,,}" == "${fp,,}" ]]; then revoked=1; break; fi
        done
        (( revoked == 0 )) || continue
        python3 -I "$py" "$pubkey_b64" "$file" "$sigbin" >/dev/null 2>&1
        rc=$?
        if [[ "$rc" == "0" ]]; then rm -rf -- "$keydir"; return 0; fi
        if [[ "$rc" == "2" ]]; then rm -rf -- "$keydir"; return 2; fi
    done
    rm -rf -- "$keydir"
    return 1
}

# F-05 enforcement gate for a downloaded metadata file + its .sig.
#   $1 = metadata file path, $2 = .sig file path, $3 = description
# Returns 0 if signature verifies (CLI or ctypes), or if enforcement is off (warns).
# Returns 1 (fail-closed) iff ABOX_SIGNING_ENFORCE=1 and sig missing/invalid/unverifiable.
abox_verify_sig_gate() {
    local file="$1" sigfile="$2" desc="${3:-metadata}"
    # V-C: CLI path unavailable; try the ctypes libcrypto verifier first.
    # ctypes rc: 0 = verified, 1 = signature invalid, 2 = no verifier.
    if ! _openssl_has_ed25519; then
        local _ct_rc=2
        if [[ -f "$sigfile" ]]; then
            verify_ed25519_detached_ctypes "$file" "$sigfile"
            _ct_rc=$?
            if [[ "$_ct_rc" == "0" ]]; then
                return 0
            fi
        fi
        if [[ ! -f "$sigfile" ]]; then
            printf '[A-Box][F-05] WARNING: missing signature for %s (%s not found)\n' "$desc" "$sigfile" >&2
        elif [[ "$_ct_rc" == "1" ]]; then
            printf '[A-Box][F-05] WARNING: invalid Ed25519 signature for %s\n' "$desc" >&2
        elif [[ "${_OPENSSL_ED25519_PROBE_FAILED:-0}" == '1' ]]; then
            printf '[A-Box][F-05] WARNING: Ed25519 capability probe failed (transient infrastructure error); no ctypes verifier available for %s.\n' "$desc" >&2
        else
            printf '[A-Box][F-05] WARNING: OpenSSL lacks Ed25519/rawin support; no ctypes verifier available for %s.\n' "$desc" >&2
        fi
        if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
            printf '[A-Box][F-05] FATAL: signature enforcement is ON; rejecting %s\n' "$desc" >&2
            return 1
        fi
        return 0
    fi
    if [[ -f "$sigfile" ]]; then
        if verify_ed25519_detached "$file" "$sigfile"; then
            return 0
        fi
        printf '[A-Box][F-05] WARNING: invalid Ed25519 signature for %s\n' "$desc" >&2
    else
        printf '[A-Box][F-05] WARNING: missing signature for %s (%s not found)\n' "$desc" "$sigfile" >&2
    fi
    if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
        printf '[A-Box][F-05] FATAL: signature enforcement is ON; rejecting %s\n' "$desc" >&2
        return 1
    fi
    return 0
}
# ========== end F-05 verification ==========

valid_github_download_url() {
    local repo="$1" url="$2" expected_ref="${3:-}" expected_asset="${4:-}"
    local repo_lower="${repo,,}" url_lower="${url,,}"
    [[ "$repo_lower" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || return 1
    [[ "$url" != *$'\r'* && "$url" != *$'\n'* && "$url" != *$'\t'* ]] || return 1
    if [[ -n "$expected_ref" ]]; then
        [[ "$expected_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
        if [[ -n "$expected_asset" ]]; then
            python3 -I - "$url" "$repo" "$expected_ref" "$expected_asset" <<'PY_GITHUB_URL'
from urllib.parse import urlsplit, unquote
import sys
url, repo, ref, asset = sys.argv[1:]
try:
    u = urlsplit(url)
except ValueError:
    raise SystemExit(1)
if u.scheme != 'https' or u.hostname != 'github.com' or u.username or u.password or u.query or u.fragment:
    raise SystemExit(1)
# R6C7-01: normalize percent-encoding before comparison:
# a namespaced tag URL may carry %2F where the expected
# ref has a literal slash. Single unquote + exact match
# keeps encoded traversal rejected (it cannot equal the
# expected path).
if unquote(u.path) != f'/{repo}/releases/download/{ref}/{asset}':
    raise SystemExit(1)
raise SystemExit(0)
PY_GITHUB_URL
            return $?
        fi
        [[ "$url" == "https://github.com/${repo}/releases/download/${expected_ref}/"* ]] || return 1
        local tail="${url#https://github.com/${repo}/releases/download/${expected_ref}/}"
        [[ -n "$tail" && "$tail" != */* && "$tail" != *'?'* && "$tail" != *'#'* && "$tail" != *'..'* && "$tail" != *'\\'* ]] || return 1
    else
        [[ "$url_lower" == "https://github.com/${repo_lower}/releases/download/"* ]] || return 1
        local tail="${url#https://github.com/${repo_lower}/releases/download/}"
        [[ -n "$tail" && "$tail" != *'?'* && "$tail" != *'#'* && "$tail" != *'..'* && "$tail" != *'\\'* ]] || return 1
    fi
}

singbox_asset_regex() {
    if [[ "${release:-}" == 'alpine' ]]; then
        printf '%s\n' "^sing-box-.*-linux-${SB_ARCH}-musl\.tar\.gz$"
    else
        printf '%s\n' "^sing-box-.*-linux-${SB_ARCH}-glibc\.tar\.gz$"
    fi
}

decimal_component_compare() {
    local a="${1:-}" b="${2:-}" LC_ALL=C
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 2
    a="${a#"${a%%[!0]*}"}"; b="${b#"${b%%[!0]*}"}"
    [[ -n "$a" ]] || a='0'
    [[ -n "$b" ]] || b='0'
    if (( ${#a} < ${#b} )); then printf '%s\n' -1; return 0; fi
    if (( ${#a} > ${#b} )); then printf '%s\n' 1; return 0; fi
    # Equal-length digit strings order identically lexicographically
    # and numerically; a string compare avoids int64 overflow on
    # absurdly large components that 10# arithmetic would wrap.
    # shellcheck disable=SC2071
    if [[ "$a" == "$b" ]]; then printf '%s\n' 0; elif [[ "$a" < "$b" ]]; then printf '%s\n' -1; else printf '%s\n' 1; fi
}

xray_version_at_least() {
    local version="${1:-}" min_major="${2:-0}" min_minor="${3:-0}" min_patch="${4:-0}" major minor patch cmp pre=''
    version="${version#v}"
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]] || return 2
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"; pre="${BASH_REMATCH[5]:-}"
    cmp=$(decimal_component_compare "$major" "$min_major") || return 2
    (( cmp > 0 )) && return 0; (( cmp < 0 )) && return 1
    cmp=$(decimal_component_compare "$minor" "$min_minor") || return 2
    (( cmp > 0 )) && return 0; (( cmp < 0 )) && return 1
    cmp=$(decimal_component_compare "$patch" "$min_patch") || return 2
    (( cmp > 0 )) && return 0; (( cmp < 0 )) && return 1
    # Equal numeric triple: a prerelease precedes its own release (SemVer),
    # so it is NOT at least the release version. Malformed input still
    # returns 2, so the explicit ML-KEM path keeps dying on real garbage.
    [[ -n "$pre" ]] && return 1
    return 0
}

xray_version_compare() {
    local a="${1:-}" b="${2:-}" am aj ap bm bj bp cmp
    a="${a#v}"; b="${b#v}"
    [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 2
    am="${BASH_REMATCH[1]}"; aj="${BASH_REMATCH[2]}"; ap="${BASH_REMATCH[3]}"
    [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 2
    bm="${BASH_REMATCH[1]}"; bj="${BASH_REMATCH[2]}"; bp="${BASH_REMATCH[3]}"
    cmp=$(decimal_component_compare "$am" "$bm") || return 2; (( cmp != 0 )) && { printf '%s\n' "$cmp"; return 0; }
    cmp=$(decimal_component_compare "$aj" "$bj") || return 2; (( cmp != 0 )) && { printf '%s\n' "$cmp"; return 0; }
    decimal_component_compare "$ap" "$bp"
}

# Extract a semantic version from the first-line output of a core binary.
core_version_from_output() {
    local output="${1:-}"
    if [[ "$output" =~ (^|[^[:alnum:]])(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

# Compare SemVer tags, including prerelease tags and release refs such as app/v2.13.0.
# Prints -1/0/1 for target ordering and 2 on malformed input.
core_version_compare() {
    local a="${1:-}" b="${2:-}" a_pre='' b_pre='' cmp i id_a id_b norm_a norm_b
    local LC_ALL=C
    local -a a_ids=() b_ids=()
    a="${a##*/}"; b="${b##*/}"; a="${a#v}"; b="${b#v}"
    [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]] || return 2
    local am="${BASH_REMATCH[1]}" aj="${BASH_REMATCH[2]}" ap="${BASH_REMATCH[3]}"
    a_pre="${BASH_REMATCH[5]:-}"
    [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]] || return 2
    local bm="${BASH_REMATCH[1]}" bj="${BASH_REMATCH[2]}" bp="${BASH_REMATCH[3]}"
    b_pre="${BASH_REMATCH[5]:-}"
    cmp=$(xray_version_compare "$am.$aj.$ap" "$bm.$bj.$bp") || return 2
    if (( cmp != 0 )); then printf '%s\n' "$cmp"; return 0; fi
    if [[ -z "$a_pre" && -n "$b_pre" ]]; then printf '%s\n' 1; return 0; fi
    if [[ -n "$a_pre" && -z "$b_pre" ]]; then printf '%s\n' -1; return 0; fi
    if [[ -z "$a_pre" && -z "$b_pre" ]]; then printf '%s\n' 0; return 0; fi
    IFS='.' read -r -a a_ids <<< "$a_pre"
    IFS='.' read -r -a b_ids <<< "$b_pre"
    for ((i=0; i<${#a_ids[@]} && i<${#b_ids[@]}; i++)); do
        id_a="${a_ids[i]}"; id_b="${b_ids[i]}"
        [[ "$id_a" == "$id_b" ]] && continue
        if [[ "$id_a" =~ ^[0-9]+$ && "$id_b" =~ ^[0-9]+$ ]]; then
            norm_a="$id_a"; norm_b="$id_b"
            while [[ "${#norm_a}" -gt 1 && "$norm_a" == 0* ]]; do norm_a="${norm_a#0}"; done
            while [[ "${#norm_b}" -gt 1 && "$norm_b" == 0* ]]; do norm_b="${norm_b#0}"; done
            if (( ${#norm_a} < ${#norm_b} )); then cmp=-1
            elif (( ${#norm_a} > ${#norm_b} )); then cmp=1
            elif [[ "$norm_a" < "$norm_b" ]]; then cmp=-1
            elif [[ "$norm_a" > "$norm_b" ]]; then cmp=1
            else continue
            fi
        elif [[ "$id_a" =~ ^[0-9]+$ ]]; then
            cmp=-1
        elif [[ "$id_b" =~ ^[0-9]+$ ]]; then
            cmp=1
        elif [[ "$id_a" < "$id_b" ]]; then
            cmp=-1
        else
            cmp=1
        fi
        printf '%s\n' "$cmp"
        return 0
    done
    if (( ${#a_ids[@]} < ${#b_ids[@]} )); then printf '%s\n' -1
    elif (( ${#a_ids[@]} > ${#b_ids[@]} )); then printf '%s\n' 1
    else printf '%s\n' 0
    fi
}

# Return codes: 0=proceed, 1=explicit downgrade needs opt-in, 2=invalid versions,
# 3=installed version is newer than the default pin (safe no-op), 4=already pinned.
core_binary_matches_release_ref() {
    local expected_ref="${1:-}" output="${2:-}" expected actual cmp
    [[ -n "$expected_ref" && -n "$output" ]] || return 1
    expected="${expected_ref##*/}"
    expected="${expected#v}"
    actual=$(core_version_from_output "$output" 2>/dev/null) || return 1
    actual="${actual#v}"
    cmp=$(core_version_compare "$actual" "$expected" 2>/dev/null) || return 1
    [[ "$cmp" == '0' ]]
}

core_version_upgrade_decision() {
    local current="${1:-}" target="${2:-}" explicit="${3:-0}" allow="${4:-0}" cmp
    [[ "$explicit" == 0 || "$explicit" == 1 ]] || return 2
    [[ "$allow" == 0 || "$allow" == 1 ]] || return 2
    cmp=$(core_version_compare "$current" "$target") || return 2
    [[ "$allow" == 1 ]] && return 0
    if (( cmp > 0 )); then
        [[ "$explicit" == 1 ]] && return 1
        return 3
    fi
    if (( cmp == 0 )) && [[ "$explicit" == 0 ]]; then return 4; fi
    return 0
}

core_version_downgrade_allowed() {
    core_version_upgrade_decision "${1:-}" "${2:-}" 1 "${3:-0}"
}

# A present binary whose version command failed is not safe to replace silently:
# it may be a newer/custom build that the version guard cannot order.
core_version_probe_safe() {
    local binary_path="${1:-}" output="${2:-}" allow="${3:-0}"
    [[ "$allow" == 0 || "$allow" == 1 ]] || return 2
    if [[ -e "$binary_path" || -L "$binary_path" ]]; then
        [[ -n "$output" || "$allow" == 1 ]]
    else
        return 0
    fi
}

core_release_ref_valid() {
    local repo="${1:-}" ref="${2:-}"
    case "$repo" in
        XTLS/Xray-core|SagerNet/sing-box) [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] ;;
        HyNetworks/hysteria) [[ "$ref" =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] ;;
        *) return 1 ;;
    esac
}

core_latest_stable_tag_from_json() {
    local repo="${1:-}" release_json="${2:-}" pattern tag
    case "$repo" in
        XTLS/Xray-core|SagerNet/sing-box) pattern='^v[0-9]+\.[0-9]+\.[0-9]+$' ;;
        HyNetworks/hysteria) pattern='^app/v[0-9]+\.[0-9]+\.[0-9]+$' ;;
        *) return 1 ;;
    esac
    [[ -n "$release_json" ]] || return 1
    # GitHub's release feed is ordered by publication time, not semantic version.
    # Sort the validated stable tags numerically so a late-published older release
    # cannot shadow a newer version. Prereleases and drafts are filtered above.
    tag=$(jq -er --arg pattern "$pattern" '
        if type != "array" then empty
        else
          [ .[]?
            | select(.draft == false and .prerelease == false)
            | select(((.tag_name // "") | type) == "string")
            | select((.tag_name // "") | test($pattern))
          ]
          | sort_by(
              .tag_name
              | capture("^(?:app/)?v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)$")
              | [(.major | tonumber), (.minor | tonumber), (.patch | tonumber)]
            )
          | last
          | .tag_name // empty
        end
    ' <<< "$release_json" 2>/dev/null) || return 1
    core_release_ref_valid "$repo" "$tag" || return 1
    printf '%s\n' "$tag"
}

core_latest_stable_release_ref() {
    # Return codes: 0 = qualified stable tag printed; 1 = bad repo/call;
    # 2 = upstream API request failed; 3 = API worked but the release list
    # has no qualified stable candidate; 4 = API returned a response that
    # is not a valid release list. Callers must not collapse these codes.
    local repo="${1:-}" json tag
    case "$repo" in
        XTLS/Xray-core|SagerNet/sing-box|HyNetworks/hysteria) ;;
        *) return 1 ;;
    esac
    json=$(github_api_get "https://api.github.com/repos/$repo/releases?per_page=100") || return 2
    # A successful request with a corrupt response must not be
    # misreported as "no stable candidate".
    jq -e '
        if type == "array"
        then all(.[]; type == "object")
        else false
        end
    ' <<< "$json" >/dev/null 2>&1 || return 4
    tag=$(core_latest_stable_tag_from_json "$repo" "$json") || return 3
    printf '%s\n' "$tag"
}

core_release_mirror_version() {
    case "${1:-}" in
        XTLS/Xray-core) printf '%s\n' "$ABOX_XRAY_MIRROR_VERSION" ;;
        SagerNet/sing-box) printf '%s\n' "$ABOX_SINGBOX_MIRROR_VERSION" ;;
        HyNetworks/hysteria) printf '%s\n' "$ABOX_HYSTERIA_MIRROR_VERSION" ;;
        *) return 1 ;;
    esac
}

core_latest_mirror_tag_from_text() {
    local repo="${1:-}" versions="${2:-}" key ref
    case "$repo" in XTLS/Xray-core) key='Xray' ;; SagerNet/sing-box) key='sing-box' ;; HyNetworks/hysteria) key='Hysteria' ;; *) return 1 ;; esac
    [[ -n "$versions" ]] || return 1
    ref=$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' <<< "$versions") || return 1
    core_release_ref_valid "$repo" "$ref" || return 1
    [[ "$ref" != *-* ]] || return 1
    printf '%s\n' "$ref"
}

core_latest_mirror_release_ref() {
    local repo="${1:-}" base='' workdir='' expected='' actual='' versions='' _f05_ts=''
    case "$repo" in XTLS/Xray-core|SagerNet/sing-box|HyNetworks/hysteria) ;; *) return 1 ;; esac
    base="${ABOX_CORE_MIRROR_BASE:-$ABOX_CORE_MIRROR_BASE_DEFAULT}"
    [[ -n "$base" ]] || return 1
    case "$base" in
        https://*) ;;
        *) msg "${RED}[!] ABOX_CORE_MIRROR_BASE must use https://; refusing plaintext mirror (integrity bypass).${NC}" >&2; return 1 ;;
    esac
    workdir=$(mktemp -d /tmp/A-Box-core-mirror-meta.XXXXXX) || return 1
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 5 -m 15 "${base%/}/CORE-VERSIONS" -o "$workdir/CORE-VERSIONS" || ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 5 -m 15 "${base%/}/SHA256SUMS" -o "$workdir/SHA256SUMS"; then
        rm -rf -- "$workdir"; return 1
    fi
    # F-05: fetch detached signatures (best-effort); gate enforces when on.
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 5 -m 15 "${base%/}/CORE-VERSIONS.sig" -o "$workdir/CORE-VERSIONS.sig" 2>/dev/null || true
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 5 -m 15 "${base%/}/SHA256SUMS.sig" -o "$workdir/SHA256SUMS.sig" 2>/dev/null || true
    if ! abox_verify_sig_gate "$workdir/CORE-VERSIONS" "$workdir/CORE-VERSIONS.sig" "core mirror CORE-VERSIONS"; then
        rm -rf -- "$workdir"; return 1
    fi
    if ! abox_verify_sig_gate "$workdir/SHA256SUMS" "$workdir/SHA256SUMS.sig" "core mirror SHA256SUMS"; then
        rm -rf -- "$workdir"; return 1
    fi
    # F-05 anti-replay: CORE-VERSIONS timestamp must not predate trust floor.
    _f05_ts=$(awk -F= '$1=="updated_at_utc" {print $2; exit}' "$workdir/CORE-VERSIONS" 2>/dev/null || true)
    if [[ -z "$_f05_ts" ]]; then
        if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
            printf '[A-Box][F-05] FATAL: CORE-VERSIONS missing updated_at_utc (anti-replay timestamp required)\n' >&2
            rm -rf -- "$workdir"; return 1
        fi
        printf '[A-Box][F-05] WARNING: CORE-VERSIONS missing updated_at_utc (anti-replay check skipped, enforcement off)\n' >&2
    elif ! abox_signing_timestamp_ok "$_f05_ts"; then
        if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
            printf '[A-Box][F-05] FATAL: CORE-VERSIONS timestamp %s is older than trust floor %s\n' "$_f05_ts" "$ABOX_SIGNING_MIN_TIMESTAMP_UTC" >&2
            rm -rf -- "$workdir"; return 1
        fi
        printf '[A-Box][F-05] WARNING: CORE-VERSIONS timestamp %s is older than trust floor %s (enforcement off)\n' "$_f05_ts" "$ABOX_SIGNING_MIN_TIMESTAMP_UTC" >&2
    fi
    expected=$(awk '$2 == "CORE-VERSIONS" {print $1; exit}' "$workdir/SHA256SUMS")
    actual=$(sha256sum "$workdir/CORE-VERSIONS" 2>/dev/null | awk '{print $1}') || actual=''
    if [[ ! "$expected" =~ ^[A-Fa-f0-9]{64}$ || "${actual,,}" != "${expected,,}" ]]; then rm -rf -- "$workdir"; return 1; fi
    versions=$(cat "$workdir/CORE-VERSIONS") || { rm -rf -- "$workdir"; return 1; }
    rm -rf -- "$workdir"
    core_latest_mirror_tag_from_text "$repo" "$versions"
}

core_mirror_asset_leaf() {
    local repo="${1:-}" output_file="${2:-}" version="${3:-}" prefer_versioned="${4:-0}" pin='' sb_ver='' hysteria_leaf=''
    pin=$(core_release_mirror_version "$repo") || return 1
    core_release_ref_valid "$repo" "$version" || return 1
    case "$repo:$output_file" in
        XTLS/Xray-core:xray_core.zip)
            if [[ "$version" == "$pin" && "$prefer_versioned" != '1' ]]; then
                printf 'Xray-linux-%s.zip\n' "$XRAY_ARCH"
            else
                printf 'Xray-%s-linux-%s.zip\n' "$version" "$XRAY_ARCH"
            fi
            ;;
        SagerNet/sing-box:singbox_core.tar.gz)
            sb_ver="${version#v}"
            if [[ "${release:-}" == 'alpine' ]]; then
                printf 'sing-box-%s-linux-%s-musl.tar.gz\n' "$sb_ver" "$SB_ARCH"
            else
                printf 'sing-box-%s-linux-%s-glibc.tar.gz\n' "$sb_ver" "$SB_ARCH"
            fi
            ;;
        HyNetworks/hysteria:hysteria_core)
            if [[ "$version" == "$pin" && "$prefer_versioned" != '1' ]]; then
                printf 'hysteria-linux-%s\n' "$HY2_ARCH"
            else
                hysteria_leaf=$(tr '/' '-' <<< "$version" | tr -d '\n')
                printf 'hysteria-%s-linux-%s\n' "$hysteria_leaf" "$HY2_ARCH"
            fi
            ;;
        *) return 1 ;;
    esac
}

core_resolved_version() {
    case "${1:-}" in
        XTLS/Xray-core) printf '%s\n' "${ABOX_RESOLVED_XRAY_VERSION:-}" ;;
        SagerNet/sing-box) printf '%s\n' "${ABOX_RESOLVED_SINGBOX_VERSION:-}" ;;
        HyNetworks/hysteria) printf '%s\n' "${ABOX_RESOLVED_HYSTERIA_VERSION:-}" ;;
        *) return 1 ;;
    esac
}

core_resolved_source() {
    case "${1:-}" in
        XTLS/Xray-core) printf '%s\n' "${ABOX_RESOLVED_XRAY_SOURCE:-}" ;;
        SagerNet/sing-box) printf '%s\n' "${ABOX_RESOLVED_SINGBOX_SOURCE:-}" ;;
        HyNetworks/hysteria) printf '%s\n' "${ABOX_RESOLVED_HYSTERIA_SOURCE:-}" ;;
        *) return 1 ;;
    esac
}

core_set_resolved_target() {
    local repo="${1:-}" ref="${2:-}" source="${3:-}"
    core_release_ref_valid "$repo" "$ref" || return 1
    case "$source" in upstream|mirror|mirror-latest|mirror-exact|explicit|pinned) ;; *) return 1 ;; esac
    case "$repo" in
        XTLS/Xray-core) ABOX_RESOLVED_XRAY_VERSION="$ref"; ABOX_RESOLVED_XRAY_SOURCE="$source" ;;
        SagerNet/sing-box) ABOX_RESOLVED_SINGBOX_VERSION="$ref"; ABOX_RESOLVED_SINGBOX_SOURCE="$source" ;;
        HyNetworks/hysteria) ABOX_RESOLVED_HYSTERIA_VERSION="$ref"; ABOX_RESOLVED_HYSTERIA_SOURCE="$source" ;;
        *) return 1 ;;
    esac
}

clear_core_release_resolution() {
    case "${1:-}" in
        XTLS/Xray-core) ABOX_RESOLVED_XRAY_VERSION=''; ABOX_RESOLVED_XRAY_SOURCE='' ;;
        SagerNet/sing-box) ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE='' ;;
        HyNetworks/hysteria) ABOX_RESOLVED_HYSTERIA_VERSION=''; ABOX_RESOLVED_HYSTERIA_SOURCE='' ;;
        *) return 1 ;;
    esac
}

core_update_policy() {
    # Returns the update policy for a core repo: 'pinned' or 'auto-stable'.
    # All three cores default to auto-stable (latest stable);
    # the ML-KEM compat risk is handled by the version threshold, not by
    # pinning. Explicit ABOX_*_VERSION overrides always win.
    case "${1:-}" in
        XTLS/Xray-core) printf '%s\n' "${ABOX_XRAY_UPDATE_POLICY:-auto-stable}" ;;
        SagerNet/sing-box) printf '%s\n' "${ABOX_SINGBOX_UPDATE_POLICY:-auto-stable}" ;;
        HyNetworks/hysteria) printf '%s\n' "${ABOX_HYSTERIA_UPDATE_POLICY:-auto-stable}" ;;
        *) return 1 ;;
    esac
}

resolve_core_release_target() {
    local repo="${1:-}" override='' latest='' target='' source='' resolved='' resolved_source='' default_ref='' latest_rc=0
    case "$repo" in
        XTLS/Xray-core) override="${ABOX_XRAY_VERSION:-}"; default_ref="$ABOX_XRAY_DEFAULT_VERSION" ;;
        SagerNet/sing-box) override="${ABOX_SINGBOX_VERSION:-}"; default_ref="$ABOX_SINGBOX_DEFAULT_VERSION" ;;
        HyNetworks/hysteria) override="${ABOX_HYSTERIA_APP_VERSION:-}"; default_ref="$ABOX_HYSTERIA_DEFAULT_VERSION" ;;
        *) return 1 ;;
    esac
    if [[ -n "$override" ]]; then
        core_release_ref_valid "$repo" "$override" || { msg "${RED}[!] $(tprintf rc_bad_override "$repo" "$override")${NC}" >&2; return 1; }
        target="$override"; source='explicit'
    else
        resolved=$(core_resolved_version "$repo" 2>/dev/null || true)
        resolved_source=$(core_resolved_source "$repo" 2>/dev/null || true)
        if core_release_ref_valid "$repo" "$resolved" && [[ "$resolved_source" == 'upstream' || "$resolved_source" == 'mirror' || "$resolved_source" == 'mirror-latest' || "$resolved_source" == 'mirror-exact' || "$resolved_source" == 'pinned' ]]; then
            target="$resolved"; source="$resolved_source"
        elif [[ "${ABOX_TRY_LATEST_CORE_STABLE:-0}" == '1' ]] || [[ "$(core_update_policy "$repo" 2>/dev/null || true)" == 'auto-stable' ]]; then
            if latest=$(core_latest_stable_release_ref "$repo" 2>/dev/null); then
                latest_rc=0
            else
                latest_rc=$?
            fi
            if (( latest_rc == 0 )) && core_release_ref_valid "$repo" "$latest" && [[ "$latest" != *-* ]]; then
                # No cooling period (2026-11-10 policy): the latest stable
                # release is adopted immediately; draft/prerelease are
                # already excluded by core_latest_stable_release_ref.
                # Binary verification, config check and health gate still apply.
                target="$latest"; source='upstream'
            else
                # C2 (D2): distinguish why there is no upstream candidate
                # before entering the mirror branch. Return codes from
                # core_latest_stable_release_ref: 2 = API request failed,
                # 3 = no qualified stable candidate, 4 = invalid response.
                # A 0 return with an invalid tag is an internal
                # inconsistency, not an API failure.
                case "$latest_rc" in
                    2) msg "${YELLOW}[!] $(tprintf rc_upstream_unavailable "$repo")${NC}" >&2 ;;
                    3) msg "${YELLOW}[!] $(tprintf rc_no_stable_candidate "$repo")${NC}" >&2 ;;
                    4) msg "${YELLOW}[!] $(tprintf rc_upstream_bad_response "$repo")${NC}" >&2 ;;
                    *) msg "${RED}[!] $(tprintf fg_resolve "$repo")${NC}" >&2; return 1 ;;
                esac
                # No usable upstream candidate: try mirror-latest.
                latest=$(core_latest_mirror_release_ref "$repo" 2>/dev/null || true)
                if core_release_ref_valid "$repo" "$latest" && [[ "$latest" != *-* ]]; then
                    # No local cooling check (2026-11-10 policy): the current
                    # verified mirror version is adopted immediately.
                    target="$latest"; source='mirror-latest'
                    msg "${YELLOW}[!] No usable upstream candidate for $repo; using current mirror version ${target}.${NC}" >&2
                else msg "${RED}[!] $(tr_msg resolve_core_release_target_metadata_unavailable)${NC}" >&2; return 1; fi
            fi
        else core_release_ref_valid "$repo" "$default_ref" || return 1; target="$default_ref"; source='pinned'
        fi
    fi
    core_set_resolved_target "$repo" "$target" "$source"
}


effective_xray_version() {
    # Explicit operator override (ABOX_XRAY_VERSION) always wins first;
    # otherwise prefer the actual installed binary version over intent-based values.
    # ABOX_XRAY_VERSION_PROBE_SKIP=1 disables the binary probe (self-test).
    local actual
    if [[ -n "${ABOX_XRAY_VERSION:-}" ]]; then
        printf '%s\n' "$ABOX_XRAY_VERSION"
        return 0
    fi
    if [[ "${ABOX_XRAY_VERSION_PROBE_SKIP:-0}" != '1' && -x /usr/local/bin/xray ]]; then
        actual=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 || true)
        actual=$(core_version_from_output "$actual" 2>/dev/null || true)
        if [[ -n "$actual" ]]; then
            # Normalize to v-prefixed tag for downstream comparisons.
            [[ "$actual" == v* ]] || actual="v$actual"
            printf '%s\n' "$actual"
            return 0
        fi
    fi
    if [[ -n "${ABOX_RESOLVED_XRAY_VERSION:-}" ]]; then
        printf '%s\n' "$ABOX_RESOLVED_XRAY_VERSION"
    else
        printf '%s\n' "$ABOX_XRAY_DEFAULT_VERSION"
    fi
}

xray_reality_requires_mlkem() {
    local threshold="${ABOX_XRAY_REALITY_MLKEM_MIN_VERSION#v}" min_major min_minor min_patch
    IFS=. read -r min_major min_minor min_patch <<< "$threshold"
    [[ "$min_major" =~ ^[0-9]+$ && "$min_minor" =~ ^[0-9]+$ && "$min_patch" =~ ^[0-9]+$ ]] || return 2
    xray_version_at_least "$(effective_xray_version)" "$min_major" "$min_minor" "$min_patch"
}

clash_reality_mlkem_enabled() {
    [[ "${CORE:-}" == 'xray' ]] || return 1
    xray_reality_requires_mlkem
}

# N1: print "R X" Reality/XHTTP presence flags for an Xray config file.
# Fail-open silent: missing/unreadable/malformed config (or no jq) prints
# "0 0" and returns 0 -- this is an optional notice, never a deploy failure.
xray_config_reality_flags() {
    local cfg="${1:-$XRAY_SLOT_CFG}" _r='0' _x='0'
    if [[ -n "$cfg" && -r "$cfg" ]] && command -v jq >/dev/null 2>&1; then
        if jsonc_strip_comments "$cfg" 2>/dev/null | jq -e 'any(.inbounds[]?; (.protocol == "vless" or .protocol == "trojan") and .streamSettings.security == "reality")' >/dev/null 2>&1; then _r='1'; fi
        if jsonc_strip_comments "$cfg" 2>/dev/null | jq -e 'any(.inbounds[]?; .protocol == "vless" and .streamSettings.security == "reality" and .streamSettings.network == "xhttp")' >/dev/null 2>&1; then _x='1'; fi
    fi
    printf '%s %s\n' "$_r" "$_x"
}

# N1: deploy-time REALITY compatibility notice (tr_msg, RED+BOLD).
# $1: XHTTP flag (1 = this install includes an XHTTP+Reality leg).
# $2: trojan flag (1 = trojan path: print the trojan-variant mihomo line
# instead of the standard one, which refers to YAML that does not exist
# on the trojan path). Prints nothing and returns 0 when the installed
# Xray version does not require ML-KEM (or the version is unparsable).
show_reality_mlkem_notice() {
    local _xhttp="${1:-0}" _trojan="${2:-0}"
    xray_reality_requires_mlkem || return 0
    msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_title)${NC}"
    msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_cannot)${NC}"
    if [[ "$_trojan" == '1' ]]; then
        msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_mihomo_trojan)${NC}"
    else
        msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_mihomo)${NC}"
    fi
    msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_ok)${NC}"
    if [[ "$_xhttp" == '1' ]]; then
        msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_xhttp)${NC}"
    fi
    msg "${RED}${BOLD}$(tr_msg reality_mlkem_notice_unverified)${NC}"
}

singbox_asset_json_from_release() {
    local release_json="${1:-}" preferred asset_json
    preferred="$(singbox_asset_regex)"
    # Fail closed on libc selection. A generic linux-ARCH asset is not accepted
    # because it can silently select the wrong libc family and fail after install.
    asset_json=$(jq -c --arg re "$preferred" 'first(.assets[]? | select(.name | test($re)) | {name:.name,url:.browser_download_url,digest:(.digest // "")}) // empty' <<< "$release_json")
    [[ -n "$asset_json" && "$asset_json" != 'null' ]] || return 1
    printf '%s\n' "$asset_json"
}

core_fetch_upstream_release_asset() {
    local repo="${1:-}" output_file="${2:-}" dest_file="${3:-}" release_ref="${4:-}" asset_re="${5:-}" source="${6:-upstream}"
    local api_url release_json asset_array count asset_json asset_name download_url digest mirror tmp_file require_stable=1 _core_ver_rc _up_max_time=180 _up_retry=2
    api_url="https://api.github.com/repos/${repo}/releases/tags/${release_ref//\//%2F}"
    release_json=$(github_api_get "$api_url" 2>/dev/null) || { msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_api_unavailable "${repo}" "${release_ref}")${NC}" >&2; return 1; }
    [[ "$source" == 'explicit' || "$source" == 'pinned' ]] && require_stable=0
    if ! jq -e --arg tag "$release_ref" --argjson stable "$require_stable" '
        type == "object" and .tag_name == $tag and .draft == false
        and (if $stable == 1 then .prerelease == false else true end)
    ' <<< "$release_json" >/dev/null 2>&1; then
        msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_metadata_mismatch "${repo}" "${release_ref}")${NC}" >&2; return 1
    fi
    if [[ "$repo:$output_file" == 'SagerNet/sing-box:singbox_core.tar.gz' ]]; then asset_re="$(singbox_asset_regex)"; fi
    asset_array=$(jq -c --arg re "$asset_re" '[.assets[]? | select(((.name // "") | type) == "string") | select((.name // "") | test($re)) | {name:.name,url:(.browser_download_url // ""),digest:(.digest // "")}]' <<< "$release_json" 2>/dev/null) || return 1
    count=$(jq -r 'length' <<< "$asset_array" 2>/dev/null) || return 1
    [[ "$count" == '1' ]] || { msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_asset_match_count "${count:-0}" "${repo}" "${release_ref}")${NC}" >&2; return 1; }
    asset_json=$(jq -c '.[0]' <<< "$asset_array") || return 1
    asset_name=$(jq -r '.name // ""' <<< "$asset_json"); download_url=$(jq -r '.url // ""' <<< "$asset_json"); digest=$(jq -r '.digest // ""' <<< "$asset_json")
    [[ -n "$asset_name" ]] || return 1
    valid_github_download_url "$repo" "$download_url" "$release_ref" "$asset_name" || { msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_url_mismatch)${NC}" >&2; return 1; }
    [[ "$digest" == sha256:* && "${digest#sha256:}" =~ ^[A-Fa-f0-9]{64}$ ]] || { msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_digest_missing)${NC}" >&2; return 1; }
    # R10C7-01: refuse a directory target before any download; mv would
    # otherwise move the verified asset INTO the directory, report success,
    # and update resolved state while the requested path holds no file.
    if [[ -e "$dest_file" && -d "$dest_file" ]]; then msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_dest_is_dir "${dest_file}")${NC}" >&2; return 1; fi
    for mirror in '' 'https://ghp.ci/' 'https://gh-proxy.com/'; do
        # B-C2: total fetch budget -- one spent budget ends the mirror
        # course; with a budget armed, curl gets no per-call retries so
        # a single attempt can never overrun the remaining budget.
        _up_max_time=180
        _up_retry=2
        if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
            abox_fetch_deadline_check "core_fetch_upstream_release_asset $repo $release_ref" || return 1
            _up_max_time=$(abox_fetch_curl_max_time 180) || return 1
            abox_fetch_deadline_remaining >/dev/null 2>&1 && _up_retry=0
        fi
        tmp_file=$(mktemp "${dest_file}.download.XXXXXX") || return 1
        if abox_run_wait "$(tprintf core_fetch_upstream_release_asset_downloading "${asset_name}")" curl -fLsS --proto =https --proto-redir =https --retry "$_up_retry" --retry-delay 2 --connect-timeout 10 -m "$_up_max_time" "${mirror}${download_url}" -o "$tmp_file"; then
            # S31 (GPT-11): digest first -- the digest is already in hand
            # from release metadata, so the cheap SHA-256 check must reject
            # a bad archive before the expensive full-archive parse runs.
            if ! verify_github_asset_digest "$tmp_file" "$digest"; then rm -f -- "$tmp_file"; msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_digest_mismatch)${NC}" >&2; continue; fi
            if ! validate_downloaded_asset "$output_file" "$tmp_file"; then rm -f -- "$tmp_file"; msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_archive_invalid)${NC}" >&2; continue; fi
            validate_core_asset_binary_version "$output_file" "$tmp_file" "$release_ref"; _core_ver_rc=$?
            if (( _core_ver_rc == 2 )); then rm -f -- "$tmp_file"; msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_binary_not_executable)${NC}" >&2; continue; fi
            if (( _core_ver_rc != 0 )); then rm -f -- "$tmp_file"; msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_binary_version_mismatch)${NC}" >&2; continue; fi
            # R9 (F06-5): recheck for a clear diagnostic; -T prevents
            # moving INTO a directory even if the target changes after
            # this check (mirrors the fetch_abox_mirror_asset commit).
            if [[ -d "$dest_file" ]]; then
                rm -f -- "$tmp_file"
                msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_dest_is_dir "${dest_file}")${NC}" >&2
                return 1
            fi
            mv -fT -- "$tmp_file" "$dest_file" || { rm -f -- "$tmp_file"; return 1; }

            # Best-effort post-commit check before updating resolved state.
            # This does not prevent a later concurrent replacement.
            if [[ ! -f "$dest_file" ]]; then
                msg "${YELLOW}[!] $(tprintf core_fetch_upstream_release_asset_committed_not_file "${dest_file}")${NC}" >&2
                return 1
            fi
            ABOX_LAST_CORE_RELEASE_REF="$release_ref"; ABOX_LAST_CORE_SOURCE="$source"
            core_set_resolved_target "$repo" "$release_ref" "$source" || return 1
            msg "${GREEN}$(tprintf core_fetch_upstream_release_asset_candidate_verified "${repo}" "${release_ref}")${NC}"
            return 0
        fi
        rm -f -- "$tmp_file"
    done
    msg "${YELLOW}[!] $(tr_msg core_fetch_upstream_release_asset_all_channels_fail)${NC}" >&2
    return 1
}

fetch_github_release() {
    local repo="${1:-}" output_file="${2:-}" dest_file="${3:-}" asset_re='' target_ref='' target_source='' mirror_ref='' _pin_ref=''
    case "$repo:$output_file" in XTLS/Xray-core:xray_core.zip) asset_re="^Xray-linux-${XRAY_ARCH}[.]zip$" ;; SagerNet/sing-box:singbox_core.tar.gz) asset_re="$(singbox_asset_regex)" ;; HyNetworks/hysteria:hysteria_core) asset_re="^hysteria-linux-${HY2_ARCH}$" ;; *) die "$(tprintf fg_no_rule "$repo" "$output_file")" ;; esac
    resolve_core_release_target "$repo" || die "$(tprintf fg_resolve "$repo")"
    target_ref=$(core_resolved_version "$repo") || die "$(tprintf fg_read_ver "$repo")"
    target_source=$(core_resolved_source "$repo") || die "$(tprintf fg_read_src "$repo")"
    core_release_ref_valid "$repo" "$target_ref" || die "$(tprintf fg_bad_ref "$repo" "$target_ref")"
    [[ -n "$dest_file" ]] || { local tmp_dir; tmp_dir=$(mktemp -d /tmp/A-Box-asset.XXXXXX) || die "$(tr_msg fg_tmpdir)"; dest_file="$tmp_dir/$output_file"; }
    mkdir -p "$(dirname "$dest_file")" || die "$(tr_msg fg_outdir)"
    if [[ "$repo:$output_file" == 'XTLS/Xray-core:xray_core.zip' ]]; then
        if ABOX_XRAY_VERSION="$target_ref" xray_reality_requires_mlkem; then msg "${YELLOW}[!] $(tprintf fg_mlkem "$target_ref")${NC}"; else local mlkem_rc=$?; (( mlkem_rc == 1 )) || die "$(tr_msg fg_unparsable)"; fi
    fi
    msg "${YELLOW}$(tprintf fetch_github_release_candidate "${repo}" "${target_ref}" "${target_source}")${NC}"
    probe_core_sources_banner "$repo" "$target_ref"

    if [[ "$target_source" == 'mirror-exact' ]]; then
        if fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 1; then return 0; fi
        mirror_ref=$(core_release_mirror_version "$repo") || die "$(tprintf fg_no_pin "$repo")"
        if [[ "$target_ref" == "$mirror_ref" ]] && fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 0; then return 0; fi
        die "$(tprintf fg_exact_unavail "$target_ref")"
    fi

    if [[ "$target_source" == 'upstream' || "$target_source" == 'explicit' || "$target_source" == 'pinned' ]]; then
        if core_fetch_upstream_release_asset "$repo" "$output_file" "$dest_file" "$target_ref" "$asset_re" "$target_source"; then return 0; fi
        # F-02 fix: for auto-stable (source=upstream), try the same-tag versioned
        # mirror after upstream failure; if unavailable, try the current verified
        # mirror version (source=mirror). There is no fixed-pin fallback.
        if [[ "$target_source" == 'upstream' ]]; then
            if fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 1; then
                core_set_resolved_target "$repo" "$target_ref" mirror-exact || die "$(tr_msg fg_record_exact)"
                ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE='mirror-exact'
                msg "${GREEN}$(tprintf fetch_github_release_mirror_versioned_restored "${target_ref}")${NC}"
                return 0
            fi
            # R9 (F06-4): same-tag fixed-name retry for Xray/Hysteria only.
            # The versioned attempt above (prefer_versioned=1) and the
            # fixed-name asset are different download targets; when the
            # mirror pin equals the target, the fixed name is a valid
            # same-version recovery. sing-box has no fixed-name leaf
            # (core_mirror_asset_leaf always returns the versioned leaf),
            # so it is excluded. A failed pin read skips this optional
            # retry and falls through to C2; it never dies here.
            if [[ "$repo:$output_file" == 'XTLS/Xray-core:xray_core.zip' ||
                  "$repo:$output_file" == 'HyNetworks/hysteria:hysteria_core' ]] &&
                _pin_ref=$(core_release_mirror_version "$repo") &&
                [[ "$target_ref" == "$_pin_ref" ]] &&
                fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 0; then
                core_set_resolved_target "$repo" "$target_ref" mirror-exact || die "$(tr_msg fg_record_exact)"
                ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE='mirror-exact'
                msg "${GREEN}$(tprintf fetch_github_release_mirror_pinned_restored "${target_ref}")${NC}"
                return 0
            fi
            msg "${YELLOW}[!] $(tr_msg fetch_github_release_mirror_unavailable)${NC}" >&2
        fi
        if [[ "$target_source" == 'explicit' || "$target_source" == 'pinned' ]]; then
            if fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 1; then
                core_set_resolved_target "$repo" "$target_ref" mirror-exact || die "$(tr_msg fg_record_exact)"
                ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE='mirror-exact'
                msg "${GREEN}$(tr_msg fetch_github_release_explicit_mirror_restored)${NC}"
                return 0
            fi
            mirror_ref=$(core_release_mirror_version "$repo") || die "$(tprintf fg_no_pin "$repo")"
            if [[ "$target_ref" == "$mirror_ref" ]] && fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 0; then
                core_set_resolved_target "$repo" "$target_ref" mirror-exact || die "$(tr_msg fg_record_exact)"
                ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE='mirror-exact'
                msg "${GREEN}$(tr_msg fetch_github_release_explicit_pinned_restored)${NC}"
                return 0
            fi
            die "$(tprintf fg_explicit_unavail "$target_ref")"
        fi
    fi

    # S55 (argon P3-3a): the (upstream && TRY_LATEST) clause duplicated
    # the mirror-exact fallback above with identical arguments (and
    # mislabeled a second-attempt success as mirror-latest); upstream
    # is already covered there, so this block is mirror-latest only.
    if [[ "$target_source" == 'mirror-latest' || "$target_source" == 'mirror' ]]; then
        if fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 1; then
            core_set_resolved_target "$repo" "$target_ref" "$target_source" || die "$(tr_msg fg_record_latest)"
            ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE="$target_source"
            msg "${GREEN}$(tprintf fetch_github_release_latest_mirror_verified "${target_ref}")${NC}"
            return 0
        fi
        # R9 (F06-4): same-tag fixed-name retry for Xray/Hysteria only (see
        # the upstream branch above for the rationale). Bookkeeping copies
        # this branch's versioned-success block: source stays $target_source.
        if [[ "$repo:$output_file" == 'XTLS/Xray-core:xray_core.zip' ||
              "$repo:$output_file" == 'HyNetworks/hysteria:hysteria_core' ]] &&
            _pin_ref=$(core_release_mirror_version "$repo") &&
            [[ "$target_ref" == "$_pin_ref" ]] &&
            fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$target_ref" 0; then
            core_set_resolved_target "$repo" "$target_ref" "$target_source" || die "$(tr_msg fg_record_latest)"
            ABOX_LAST_CORE_RELEASE_REF="$target_ref"; ABOX_LAST_CORE_SOURCE="$target_source"
            msg "${GREEN}$(tprintf fetch_github_release_latest_pinned_verified "${target_ref}")${NC}"
            return 0
        fi
        msg "${YELLOW}[!] $(tr_msg fetch_github_release_latest_mirror_unavailable)${NC}" >&2
    fi

    # C2 (latest-first): no fixed-pin fallback HERE. Auto-stable sources may
    # fall back to the current verified mirror version (source 'mirror');
    # explicit/pinned/mirror-exact sources must fail instead of silently
    # switching to a different version. A mirror candidate equal to the
    # failed target was already tried as the same-tag mirror above, as was
    # the fixed-name asset where it applies (R9 F06-4).
    if [[ "$target_source" == 'upstream' || "$target_source" == 'mirror-latest' ]]; then
        mirror_ref=$(core_latest_mirror_release_ref "$repo" 2>/dev/null || true)
        if core_release_ref_valid "$repo" "$mirror_ref" && [[ "$mirror_ref" != *-* ]] && [[ "$mirror_ref" != "$target_ref" ]] && fetch_abox_mirror_asset "$repo" "$output_file" "$dest_file" "$mirror_ref"; then
            core_set_resolved_target "$repo" "$mirror_ref" mirror || die "$(tr_msg fg_record_pin)"
            ABOX_LAST_CORE_RELEASE_REF="$mirror_ref"; ABOX_LAST_CORE_SOURCE='mirror'
            msg "${GREEN}$(tprintf fetch_github_release_current_mirror_verified "${mirror_ref}")${NC}"
            return 0
        fi
    fi
    die "$(tr_msg fg_none_valid)"
}

# Geo upstream leg (extracted from fetch_geo_data, die -> return 1).
# Downloads $3 (tmp file) from the GitHub Release named by $2 for asset $1,
# verifying the official API digest. Prints the failure reason to stderr
# and returns 1 on any failure; the caller decides whether to fall back.
# Never dies: a failure here must not abort the install before the mirror
# leg has been tried. GEO-F3: $3 is left in place on failure -- the
# caller owns it (mktemp, 0600); deleting it here would make the mirror
# leg's curl -o recreate it under the ambient umask.
fetch_geo_upstream_data() {
    local file_name="${1:-}" official_url="${2:-}" tmp_out="${3:-}"
    local repo asset release_json asset_json asset_name download_url digest release_ref _geo_max_time=90
    [[ -n "$file_name" && -n "$official_url" && -n "$tmp_out" ]] || return 1
    [[ "$official_url" =~ ^https://github.com/([^/]+/[^/]+)/releases/latest/download/([^/?#]+)$ ]] || return 1
    repo="${BASH_REMATCH[1]}"
    asset="${BASH_REMATCH[2]}"
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_geo_data ${file_name} (release metadata)" || return 1
    fi
    release_json=$(github_api_get "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || release_json=''
    [[ -n "$release_json" ]] || { printf '%s\n' "$(tprintf gd_api "$repo")" >&2; return 1; }
    asset_json=$(jq -c --arg name "$asset" 'first(.assets[]? | select(.name == $name) | {name:.name,url:.browser_download_url,digest:(.digest // "")}) // empty' <<< "$release_json")
    [[ -n "$asset_json" && "$asset_json" != 'null' ]] || { printf '%s\n' "$(tprintf gd_asset_missing "$asset")" >&2; return 1; }
    asset_name=$(jq -r '.name // ""' <<< "$asset_json")
    release_ref=$(jq -r '.tag_name // ""' <<< "$release_json")
    download_url=$(jq -r '.url' <<< "$asset_json")
    digest=$(jq -r '.digest // ""' <<< "$asset_json")
    [[ -n "$asset_name" && -n "$release_ref" ]] || { printf '%s\n' 'Geo Release metadata missing asset name or tag.' >&2; return 1; }
    valid_github_download_url "$repo" "$download_url" "$release_ref" "$asset_name" || { printf '%s\n' "$(tr_msg gd_url_mismatch)" >&2; return 1; }
    _geo_max_time=90
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_geo_data ${file_name} (download)" || return 1
        _geo_max_time=$(abox_fetch_curl_max_time 90) || return 1
    fi
    abox_run_wait "$(tprintf gd_dl_label "$file_name")" curl -fLs --proto =https --proto-redir =https --connect-timeout 10 -m "$_geo_max_time" "$download_url" -o "$tmp_out" || { printf '%s\n' "$(tprintf gd_download "$file_name")" >&2; return 1; }
    if ! verify_github_asset_digest "$tmp_out" "$digest"; then
        printf '%s\n' "$(tprintf gd_digest "$file_name")" >&2
        return 1
    fi
}

# Geo mirror fallback (test-tools-mirror trust model, same verification
# strength as the upstream leg, never weaker):
#   1. Fetch SHA256SUMS + SHA256SUMS.sig from the A-Box geo-mirror Release
#      (https only; ABOX_GEO_MIRROR_BASE override must also be https).
#   2. Verify the detached Ed25519 signature DIRECTLY with
#      verify_ed25519_detached (the run_mirrored_test_script P3-02 pattern),
#      NOT the degradable abox_verify_sig_gate: a missing or invalid
#      signature rejects the mirror even when ABOX_SIGNING_ENFORCE=0.
#   3. Download the asset and SHA-256-check it against the signed manifest.
# Any failure returns 1 (mirror file refused, never executed/installed);
# the caller keeps the old geo file and dies only after both legs fail.
# $1=file_name (geoip.dat|geosite.dat only), $2=tmp file to fill.
fetch_geo_mirror_data() {
    local file_name="${1:-}" tmp_out="${2:-}"
    local base='' sum_dir='' sums='' sums_sig='' expected='' actual='' _m_max_time=90 _m_retry=2
    [[ -n "$file_name" && -n "$tmp_out" ]] || return 1
    case "$file_name" in geoip.dat|geosite.dat) ;; *) return 1 ;; esac
    base="${ABOX_GEO_MIRROR_BASE:-${ABOX_GEO_MIRROR_BASE_DEFAULT:-}}"
    [[ -n "$base" ]] || return 1
    case "$base" in
        https://*) ;;
        *) printf '%s\n' '[fetch] geo mirror base must use https://; refusing plaintext mirror.' >&2; return 1 ;;
    esac
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_geo_mirror_data ${file_name} (SHA256SUMS)" || return 1
        _m_max_time=$(abox_fetch_curl_max_time 90) || return 1
        _m_retry=0
    fi
    sum_dir=$(mktemp -d /tmp/A-Box-geo-mirror.XXXXXX) || return 1
    sums="$sum_dir/SHA256SUMS"; sums_sig="$sum_dir/SHA256SUMS.sig"
    if ! curl -fLsS --proto =https --proto-redir =https --retry "$_m_retry" --retry-delay 2 --connect-timeout 10 -m "$_m_max_time" "${base%/}/SHA256SUMS" -o "$sums" 2>/dev/null; then
        rm -rf -- "$sum_dir"; return 1
    fi
    # GEO-F1: re-check the budget and recompute the per-call cap
    # before the .sig request: the manifest fetch above may have
    # consumed most of it, and reusing the pre-manifest value lets
    # this request overrun by up to one _m_max_time (<=90s). The
    # asset stage below already recomputes the same way.
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_geo_mirror_data ${file_name} (SHA256SUMS.sig)" || { rm -rf -- "$sum_dir"; return 1; }
        _m_max_time=$(abox_fetch_curl_max_time 90) || { rm -rf -- "$sum_dir"; return 1; }
    fi
    curl -fLsS --proto =https --proto-redir =https --retry "$_m_retry" --retry-delay 2 --connect-timeout 10 -m "$_m_max_time" "${base%/}/SHA256SUMS.sig" -o "$sums_sig" 2>/dev/null || true
    if [[ -L "$sums" || ( -e "$sums_sig" && -L "$sums_sig" ) ]]; then rm -rf -- "$sum_dir"; return 1; fi
    if ! verify_ed25519_detached "$sums" "$sums_sig" >/dev/null 2>&1; then
        printf '%s\n' "[fetch] geo mirror SHA256SUMS signature verification failed; refusing mirror ${file_name}." >&2
        rm -rf -- "$sum_dir"; return 1
    fi
    expected=$(awk -v f="$file_name" '$2==f || $2==("*" f) {print $1; exit}' "$sums") || expected=''
    if [[ ! "$expected" =~ ^[A-Fa-f0-9]{64}$ ]]; then rm -rf -- "$sum_dir"; return 1; fi
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_geo_mirror_data ${file_name} (asset)" || { rm -rf -- "$sum_dir"; return 1; }
        _m_max_time=$(abox_fetch_curl_max_time 90) || { rm -rf -- "$sum_dir"; return 1; }
    fi
    if ! abox_run_wait "$(tprintf gd_dl_label "$file_name")" curl -fLs --proto =https --proto-redir =https --retry "$_m_retry" --retry-delay 2 --connect-timeout 10 -m "$_m_max_time" "${base%/}/${file_name}" -o "$tmp_out"; then
        rm -rf -- "$sum_dir"; return 1
    fi
    rm -rf -- "$sum_dir"
    actual=$(sha256sum < "$tmp_out" 2>/dev/null | awk '{print $1}') || actual=''
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        printf '%s\n' "[fetch] geo mirror SHA-256 mismatch for ${file_name}; refusing." >&2
        return 1
    fi
}

# GEO-F4: payload gate shared by both legs. Returns 0 iff $1 is a
# regular file larger than 500000 bytes whose first 256 bytes are not
# an HTML error page. Never dies: the caller decides whether to try
# the other leg. A failed validation is a leg failure, not a local
# error -- only the atomic commit below still dies.
validate_geo_payload() {
    local _f="${1:-}" _size
    [[ -n "$_f" && -f "$_f" && ! -L "$_f" ]] || return 1
    _size=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
    [[ -n "$_size" && "$_size" -gt 500000 ]] || return 1
    if head -c 256 "$_f" 2>/dev/null | grep -Eiq '<(html|!doctype)'; then
        return 1
    fi
    return 0
}

fetch_geo_data() {
    local file_name official_url out tmp_out out_created=0 _geo_t0 _geo_now _geo_leg_ok=0
    file_name="${1:-}"
    official_url="${2:-}"
    out="${3:-}"
    [[ -n "$file_name" && -n "$official_url" ]] || die "$(tr_msg gd_params)"
    [[ "$file_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "$(tprintf gd_bad_name "$file_name")"
    if [[ -z "$out" ]]; then
        out="$(umask 077; mktemp "/tmp/${file_name}.XXXXXX")" || die "$(tr_msg gd_out_tmp)"
        out_created=1
        rm -f -- "$out" || die "$(tr_msg gd_out_init)"
    fi
    [[ ! -L "$out" && ! -d "$out" ]] || die "$(tprintf gd_out_notfile "$out")"
    mkdir -p "$(dirname "$out")" || die "$(tr_msg gd_out_dir)"
    _geo_t0=$(date +%s 2>/dev/null || printf '0')
    msg "[fetch] geo ${file_name}: download started at $(now_iso)"
    tmp_out=$(umask 077; mktemp "${out}.download.XXXXXX") || { (( out_created == 1 )) && rm -f -- "$out"; die "$(tr_msg gd_tmp)"; }

    if [[ "$official_url" =~ ^https://github.com/([^/]+/[^/]+)/releases/latest/download/([^/?#]+)$ ]]; then
        # Upstream first; on ANY upstream failure (API rate-limit included)
        # fall back to the A-Box signed mirror before giving up. A non-GitHub
        # URL still refuses outright below (URL contract unchanged).
        # GEO-F4: a leg only counts when its payload passes
        # validate_geo_payload (size + HTML gates). A digest-valid but
        # too-small/HTML upstream payload falls back to the mirror
        # instead of dying here; only both legs failing dies.
        if fetch_geo_upstream_data "$file_name" "$official_url" "$tmp_out"; then
            if validate_geo_payload "$tmp_out"; then
                _geo_leg_ok=1
            else
                msg "[fetch] geo ${file_name}: upstream payload failed validation (size or HTML); trying the signed mirror."
            fi
        fi
        if (( _geo_leg_ok == 0 )) && fetch_geo_mirror_data "$file_name" "$tmp_out"; then
            if validate_geo_payload "$tmp_out"; then
                _geo_leg_ok=1
                msg "[fetch] geo ${file_name}: recovered from A-Box signed mirror (${ABOX_GEO_MIRROR_RELEASE:-geo-mirror})"
            else
                msg "[fetch] geo ${file_name}: mirror payload failed validation (size or HTML)."
            fi
        fi
        if (( _geo_leg_ok == 0 )); then
            rm -f -- "$tmp_out"; (( out_created == 1 )) && rm -f -- "$out"
            die "$(tprintf gd_both_failed "$file_name")"
        fi
    else
        rm -f -- "$tmp_out"
        die "$(tprintf gd_no_digest "$file_name")"
    fi
    # R9C7-01: re-check the target just before commit: $out may have
    # been swapped for a directory during the (up to 90s) download, and a
    # plain mv would silently move the validated file INTO it and report
    # success while the expected file path never materializes.
    [[ ! -L "$out" && ! -d "$out" ]] || { rm -f -- "$tmp_out"; (( out_created == 1 )) && rm -f -- "$out"; die "$(tprintf gd_commit "$file_name")"; }
    mv -f -- "$tmp_out" "$out" || { rm -f -- "$tmp_out"; (( out_created == 1 )) && rm -f -- "$out"; die "$(tprintf gd_commit "$file_name")"; }
    # Post-commit verification: even a final-microsecond swap must not
    # pass silently. If $out is now a directory, the file landed inside
    # it; remove the misplaced file and fail loudly.
    if [[ ! -f "$out" ]]; then
        [[ -d "$out" ]] && rm -f -- "$out/$(basename "$tmp_out")" 2>/dev/null
        die "$(tprintf gd_commit "$file_name")"
    fi
    _geo_now=$(date +%s 2>/dev/null || printf '0')
    if [[ "$_geo_t0" =~ ^[0-9]+$ && "$_geo_now" =~ ^[0-9]+$ ]]; then
        msg "[fetch] geo ${file_name}: finished in $(( _geo_now - _geo_t0 ))s"
    fi
}

desired_state_valid() { [[ "${1:-}" =~ ^(RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE)$ ]]; }
traffic_period_valid() { [[ "${1:-}" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; }

# Authoritative traffic state is PAIR ("DESIRED|PERIOD"; PERIOD empty => no block).
# Legacy .desired_state / .traffic-block-state are derived ONLY after pair publish
# succeeds, for older helper readers that have not yet migrated.
read_traffic_pair_fields() {
    local line desired period uid gid mode
    [[ -r "$ABOX_TRAFFIC_PAIR_STATE" && -f "$ABOX_TRAFFIC_PAIR_STATE" && ! -L "$ABOX_TRAFFIC_PAIR_STATE" ]] || return 1
    uid=$(stat -c %u "$ABOX_TRAFFIC_PAIR_STATE" 2>/dev/null) || return 1
    gid=$(stat -c %g "$ABOX_TRAFFIC_PAIR_STATE" 2>/dev/null) || return 1
    mode=$(stat -c %a "$ABOX_TRAFFIC_PAIR_STATE" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    IFS= read -r line < "$ABOX_TRAFFIC_PAIR_STATE" || return 1
    [[ "$line" == *'|'* ]] || return 1
    desired=${line%%|*}
    period=${line#*|}
    desired_state_valid "$desired" || return 1
    if [[ -n "$period" ]]; then
        traffic_period_valid "$period" || return 1
    fi
    printf '%s\n%s\n' "$desired" "$period"
}

# BUG-28: hoisted from commit_traffic_pair_state().
# Restores traffic state files from backups. Args are triplets:
# $1/$2/$3=pair_existed/pair_backup/pair_target, $4/$5/$6=desired_*, $7/$8/$9=block_*.
__abox_traffic_state_rollback() {
    local pair_existed="$1" pair_backup="$2" pair_target="$3"
    local desired_existed="$4" desired_backup="$5" desired_target="$6"
    local block_existed="$7" block_backup="$8" block_target="$9"
    local restore_failed=0
    # S45 (argon P1-4): write-back never follows a symlink. If a target
    # was swapped for a link after the snapshot, rm -f breaks the link
    # first so cp creates a fresh regular file; if the break fails,
    # that file is not written at all (cp would write through to the
    # link's target).
    if (( pair_existed == 1 )); then
        # S45: break a swapped-in link before cp (never follow).
        if [[ -L "$pair_target" ]] && ! rm -f -- "$pair_target" 2>/dev/null; then
            restore_failed=1
        else
            cp -p -- "$pair_backup" "$pair_target" 2>/dev/null || restore_failed=1
        fi
    else
        rm -f -- "$pair_target" 2>/dev/null || restore_failed=1
    fi
    if (( desired_existed == 1 )); then
        # S45: break a swapped-in link before cp (never follow).
        if [[ -L "$desired_target" ]] && ! rm -f -- "$desired_target" 2>/dev/null; then
            restore_failed=1
        else
            cp -p -- "$desired_backup" "$desired_target" 2>/dev/null || restore_failed=1
        fi
    else
        rm -f -- "$desired_target" 2>/dev/null || restore_failed=1
    fi
    if (( block_existed == 1 )); then
        # S45: break a swapped-in link before cp (never follow).
        if [[ -L "$block_target" ]] && ! rm -f -- "$block_target" 2>/dev/null; then
            restore_failed=1
        else
            cp -p -- "$block_backup" "$block_target" 2>/dev/null || restore_failed=1
        fi
    else
        rm -f -- "$block_target" 2>/dev/null || restore_failed=1
    fi
    # Keep the transaction backups when the restore failed: they are
    # the only manual-recovery material left.
    if (( restore_failed == 0 )); then
        rm -f -- "$pair_backup" "$desired_backup" "$block_backup"
    fi
    return "$restore_failed"
}
commit_traffic_pair_state() {
    local desired="$1" period="${2:-}"
    local pair_backup="" desired_backup="" block_backup=""
    local pair_existed=0 desired_existed=0 block_existed=0
    local restore_failed=0
    desired_state_valid "$desired" || return 1
    if [[ -n "$period" ]]; then
        traffic_period_valid "$period" || return 1
    fi
    ensure_abox_dir_owned "$ABOX_DIR" >/dev/null 2>&1 || return 1
    # Snapshot all three files for full transactional rollback.
    # S45 (argon P1-4): a symlink is damaged, not a file to snapshot
    # (-f alone is true for a link to a regular file, so require ! -L).
    # A linked state file then fails loudly at the atomic-write step
    # (the writer refuses -L) and rollback removes the link itself.
    if [[ -f "$ABOX_TRAFFIC_PAIR_STATE" && ! -L "$ABOX_TRAFFIC_PAIR_STATE" ]]; then
        pair_existed=1; pair_backup=$(mktemp) || return 1
        cp -p -- "$ABOX_TRAFFIC_PAIR_STATE" "$pair_backup" || { rm -f -- "$pair_backup"; return 1; }
    fi
    if [[ -f "$ABOX_DESIRED_STATE" && ! -L "$ABOX_DESIRED_STATE" ]]; then
        desired_existed=1; desired_backup=$(mktemp) || { rm -f -- "$pair_backup"; return 1; }
        cp -p -- "$ABOX_DESIRED_STATE" "$desired_backup" || { rm -f -- "$pair_backup" "$desired_backup"; return 1; }
    fi
    if [[ -f "$ABOX_TRAFFIC_BLOCK_STATE" && ! -L "$ABOX_TRAFFIC_BLOCK_STATE" ]]; then
        block_existed=1; block_backup=$(mktemp) || { rm -f -- "$pair_backup" "$desired_backup"; return 1; }
        cp -p -- "$ABOX_TRAFFIC_BLOCK_STATE" "$block_backup" || { rm -f -- "$pair_backup" "$desired_backup" "$block_backup"; return 1; }
    fi
    # Rollback helper: restore all three files to snapshot state. Reports failure.
    # 1) Atomic pair publish (sole authority for modern readers).
    write_file_atomically_from_stdin "$ABOX_TRAFFIC_PAIR_STATE" 600 <<< "${desired}|${period}" || { __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE"; return 1; }
    # 2) Derive legacy files only after pair is durable.
    if ! write_file_atomically_from_stdin "$ABOX_DESIRED_STATE" 600 <<< "$desired"; then
        __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE" || msg "${RED}[!] Traffic state rollback incomplete; manual check required.${NC}" >&2
        return 1
    fi
    if [[ -n "$period" ]]; then
        if ! write_file_atomically_from_stdin "$ABOX_TRAFFIC_BLOCK_STATE" 600 <<< "$period"; then
            __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE" || msg "${RED}[!] Traffic state rollback incomplete; manual check required.${NC}" >&2
            return 1
        fi
    else
        if [[ -e "$ABOX_TRAFFIC_BLOCK_STATE" || -L "$ABOX_TRAFFIC_BLOCK_STATE" ]]; then
            path_tree_has_mountpoint "$ABOX_TRAFFIC_BLOCK_STATE" && { __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE" >/dev/null 2>&1; return 1; }
            rm -f -- "$ABOX_TRAFFIC_BLOCK_STATE" || { __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE" >/dev/null 2>&1; return 1; }
            [[ ! -e "$ABOX_TRAFFIC_BLOCK_STATE" && ! -L "$ABOX_TRAFFIC_BLOCK_STATE" ]] || { __abox_traffic_state_rollback "$pair_existed" "$pair_backup" "$ABOX_TRAFFIC_PAIR_STATE" "$desired_existed" "$desired_backup" "$ABOX_DESIRED_STATE" "$block_existed" "$block_backup" "$ABOX_TRAFFIC_BLOCK_STATE" >/dev/null 2>&1; return 1; }
        fi
    fi
    rm -f -- "$pair_backup" "$desired_backup" "$block_backup"
}

get_desired_state() {
    local state='RUNNING' uid gid mode pair desired period
    # S22: a pair file that exists but is unreadable/corrupt is an error,
    # not a cue to fall back to legacy or the RUNNING default (a quota
    # block or MANUAL_STOPPED state must never be silently flipped).
    if traffic_pair_file_exists && ! pair=$(read_traffic_pair_fields); then
        return 1
    fi
    if [[ -n "${pair:-}" ]]; then
        IFS= read -r desired <<< "$pair"
        printf '%s\n' "$desired"
        return 0
    fi
    if [[ -e "$ABOX_DESIRED_STATE" || -L "$ABOX_DESIRED_STATE" ]]; then
        [[ -r "$ABOX_DESIRED_STATE" && -f "$ABOX_DESIRED_STATE" && ! -L "$ABOX_DESIRED_STATE" ]] || return 1
        uid=$(stat -c %u "$ABOX_DESIRED_STATE" 2>/dev/null) || return 1
        gid=$(stat -c %g "$ABOX_DESIRED_STATE" 2>/dev/null) || return 1
        mode=$(stat -c %a "$ABOX_DESIRED_STATE" 2>/dev/null) || return 1
        [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#077) == 0 )) || return 1
        IFS= read -r state < "$ABOX_DESIRED_STATE" || return 1
        desired_state_valid "$state" || return 1
    fi
    printf '%s\n' "$state"
}

# FINAL-AUDIT fix: distinguish "pair file does not exist" (safe to create
# with defaults) from "pair file exists but is unreadable/corrupt" (must
# refuse to overwrite, or a quota block could be silently cleared / a
# MANUAL_STOPPED state silently flipped by committing defaults).
traffic_pair_file_exists() {
    [[ -e "$ABOX_TRAFFIC_PAIR_STATE" || -L "$ABOX_TRAFFIC_PAIR_STATE" ]]
}

set_desired_state() {
    local state="$1" period=''
    desired_state_valid "$state" || return 1
    if traffic_pair_file_exists && ! read_traffic_pair_fields >/dev/null 2>&1; then
        msg "${RED}[!] Traffic pair state exists but is unreadable or corrupt; refusing to overwrite. Manual repair required.${NC}" >&2
        return 1
    fi
    period=$(get_traffic_block_period 2>/dev/null || true)
    # S22: when no pair exists, the period must come from the legacy block
    # file; a block file that exists but yields no period is corrupt, not
    # "no block" -- refusing beats letting commit delete it as a side effect.
    if ! traffic_pair_file_exists && [[ -e "$ABOX_TRAFFIC_BLOCK_STATE" || -L "$ABOX_TRAFFIC_BLOCK_STATE" ]] && [[ -z "$period" ]]; then
        msg "${RED}[!] Traffic block state exists but its period is unreadable; refusing to overwrite. Manual repair required.${NC}" >&2
        return 1
    fi
    commit_traffic_pair_state "$state" "$period"
}

get_traffic_block_period() {
    local period uid gid mode pair desired
    if pair=$(read_traffic_pair_fields); then
        desired=${pair%%$'\n'*}
        # FIX: When the period is empty, command substitution strips the
        # trailing newline, so pair="RUNNING" with no newline at all. The
        # naive ${pair#*$'\n'} then returns "RUNNING" unchanged (no match),
        # which passes -n and later fails commit validation. Detect the
        # missing newline explicitly and treat the period as empty.
        if [[ "$pair" == *$'\n'* ]]; then
            period=${pair#*$'\n'}
        else
            period=""
        fi
        [[ -n "$period" ]] || return 1
        printf '%s\n' "$period"
        return 0
    fi
    # R2F05: a present-but-unreadable/corrupt pair must fail, not
    # silently fall back to a stale legacy period; legacy is only a
    # migration path when no pair ever existed.
    if traffic_pair_file_exists; then
        return 1
    fi
    [[ -r "$ABOX_TRAFFIC_BLOCK_STATE" && -f "$ABOX_TRAFFIC_BLOCK_STATE" && ! -L "$ABOX_TRAFFIC_BLOCK_STATE" ]] || return 1
    uid=$(stat -c %u "$ABOX_TRAFFIC_BLOCK_STATE" 2>/dev/null) || return 1
    gid=$(stat -c %g "$ABOX_TRAFFIC_BLOCK_STATE" 2>/dev/null) || return 1
    mode=$(stat -c %a "$ABOX_TRAFFIC_BLOCK_STATE" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    IFS= read -r period < "$ABOX_TRAFFIC_BLOCK_STATE" || return 1
    traffic_period_valid "$period" || return 1
    printf '%s\n' "$period"
}

set_traffic_block_period() {
    local period="$1" state
    traffic_period_valid "$period" || return 1
    if traffic_pair_file_exists && ! read_traffic_pair_fields >/dev/null 2>&1; then
        msg "${RED}[!] Traffic pair state exists but is unreadable or corrupt; refusing to overwrite. Manual repair required.${NC}" >&2
        return 1
    fi
    state=$(get_desired_state) || return 1
    commit_traffic_pair_state "$state" "$period"
}

clear_traffic_block_period() {
    local state pair_fields
    # B-03 fix: if the block file is absent AND the pair state exists but is
    # unreadable/corrupt, that is an error, not "nothing to clean".
    # If neither file ever existed (fresh box / never configured), there is
    # genuinely nothing to clean.
    if [[ ! -e "$ABOX_TRAFFIC_BLOCK_STATE" && ! -L "$ABOX_TRAFFIC_BLOCK_STATE" ]]; then
        if [[ ! -e "$ABOX_TRAFFIC_PAIR_STATE" && ! -L "$ABOX_TRAFFIC_PAIR_STATE" ]]; then
            return 0
        fi
        if ! pair_fields=$(read_traffic_pair_fields 2>/dev/null); then
            msg "${RED}[!] Traffic pair state is unreadable or corrupt; refusing to treat as clean.${NC}" >&2
            return 1
        fi
        [[ -z "$(sed -n '2p' <<< "$pair_fields")" ]] && return 0
    fi
    state=$(get_desired_state) || return 1
    commit_traffic_pair_state "$state" ""
}

validate_abox_env_file_for_write() {
    [[ -f "$ABOX_ENV" && ! -L "$ABOX_ENV" ]] || return 1
    path_owned_by_root "$ABOX_ENV" || return 1
    path_mode_has_no_group_other_write "$ABOX_ENV" || return 1
    load_abox_env "$ABOX_ENV" >/dev/null 2>&1 || return 1
}

remove_abox_env_file() {
    [[ ! -e "$ABOX_ENV" && ! -L "$ABOX_ENV" ]] && return 0
    validate_abox_env_file_for_write || return 1
    path_tree_has_mountpoint "$ABOX_ENV" && return 1
    rm -f -- "$ABOX_ENV" || return 1
    [[ ! -e "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]
}

remove_owned_runtime_helper() {
    local path="$1"
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    auxiliary_content_is_abox_managed "$path" "$path" || return 1
    path_tree_has_mountpoint "$path" && return 1
    rm -f -- "$path" || return 1
    [[ ! -e "$path" && ! -L "$path" ]]
}

update_traffic_state_atomically() {
    local limit="${1:-}" mode="${2:-}" tmp
    # Fresh boxes may have no .env yet (no deployment); create it securely
    # so a traffic limit can be set standalone.
    if [[ ! -e "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]; then
        ensure_abox_dir_owned "$ABOX_DIR" >/dev/null 2>&1 || return 1
        install -m 600 /dev/null "$ABOX_ENV" || return 1
        if [[ $EUID -eq 0 ]]; then chown root:root "$ABOX_ENV" || { rm -f -- "$ABOX_ENV"; return 1; }; fi
    fi
    validate_abox_env_file_for_write || return 1
    ensure_abox_dir_owned "$ABOX_DIR" >/dev/null 2>&1 || return 1
    # H-05 (Carbon): a standalone quota must not leave INGRESS_IF unset —
    # the per-minute monitor fail-closes to TRAFFIC_BLOCKED on a missing
    # interface before any traffic query. When a non-empty limit is set
    # and .env carries no valid INGRESS_IF, infer the active interface
    # now and persist it alongside the limit. An empty or multi-value
    # inference is a hard failure: never persist an empty value.
    local _iface='' _inferred='' _write_iface=0
    if [[ -n "$limit" ]]; then
        _iface=$(awk -F= '$1=="INGRESS_IF" {print substr($0, length($1)+2); exit}' "$ABOX_ENV" 2>/dev/null || true)
        # Strip one layer of shell quoting (%q/env_quote output).
        case "$_iface" in
            \"*\") _iface="${_iface#\"}"; _iface="${_iface%\"}";;
            \'*\') _iface="${_iface#\'}"; _iface="${_iface%\'}";;
        esac
        if valid_interface_name "$_iface" 2>/dev/null; then
            _write_iface=0
        else
            _inferred=$(get_active_interface 2>/dev/null || true)
            if [[ -z "$_inferred" || "$_inferred" == *$'\n'* ]] || ! valid_interface_name "$_inferred" 2>/dev/null; then
                return 1
            fi
            _iface="$_inferred"; _write_iface=1
        fi
    fi
    tmp=$(mktemp "$ABOX_DIR/.env.A-Box-update.XXXXXX") || return 1
    if (( _write_iface == 1 )); then
        awk '!/^TRAFFIC_LIMIT_GB=/ && !/^TRAFFIC_LIMIT_MODE=/ && !/^INGRESS_IF=/' "$ABOX_ENV" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        awk '!/^TRAFFIC_LIMIT_GB=/ && !/^TRAFFIC_LIMIT_MODE=/' "$ABOX_ENV" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if [[ -n "$limit" ]]; then
        valid_traffic_limit_gb "$limit" || { rm -f "$tmp"; return 1; }
        [[ "$mode" =~ ^(total|rx|tx)$ ]] || { rm -f "$tmp"; return 1; }
        if (( _write_iface == 1 )); then
            printf 'INGRESS_IF=%q\n' "$_iface" >> "$tmp" || { rm -f "$tmp"; return 1; }
        fi
        printf 'TRAFFIC_LIMIT_GB=%q\nTRAFFIC_LIMIT_MODE=%q\n' "$limit" "$mode" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ $EUID -eq 0 ]]; then chown root:root "$tmp" || { rm -f "$tmp"; return 1; }; fi
    _abox_sync_file "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$ABOX_ENV" || { rm -f "$tmp"; return 1; }
    _abox_sync_file "$ABOX_DIR" || return 1
}

reset_protocol_vars() {
    unset UUID VLESS_SNI VISION_SNI XHTTP_SNI VLESS_PORT XHTTP_PORT HY2_BASE_PORT HY2_DOMAIN HY2_UP HY2_DOWN HY2_MASQ_URL
    unset SS_PORT SS_WHITELIST_IP PUBLIC_KEY PBK SHORT_ID HY2_PASS HY2_OBFS SS_PASS
    unset HY2_CERT_SHA256_FP HY2_CERT_PUBKEY_SHA256_B64 HY2_HOP HY2_HOP_IMPL HY2_MONITOR_PORT
    unset HY2_ACME_TYPE HY2_ACME_DNS_PROVIDER HY2_ACME_DNS_CF_API_TOKEN
    unset HY2_URI_PORTS HY2_CLASH_PORTS HY2_SB_PORTS HY2_RANGE_START HY2_RANGE_END ENABLE_KEEPALIVE
    unset SOCKS_PORT SOCKS_USER SOCKS_PASS SOCKS_PROTO TROJAN_PORT
}

path_parent_chain_safe() {
    local target="$1" current
    [[ "$target" == /* ]] || return 1
    current=$(dirname -- "$target")
    while :; do
        [[ "$current" == '/' ]] && return 0
        [[ ! -L "$current" ]] || return 1
        if [[ -e "$current" && ! -d "$current" ]]; then
            return 1
        fi
        current=$(dirname -- "$current")
    done
}

# S37 (GPT-17): sync one file (or directory) to stable storage,
# distinguishing "sync -f unsupported" from a real I/O failure.
# Returns 0 on success or on an option error (busybox sync on Alpine
# may not accept -f: that is "unsupported", not a failure, and stays
# best-effort); returns 1 on a real I/O failure so callers never
# report persistence they did not get.
_abox_sync_file() {
    local target="$1" err
    # R6C7-02: capture diagnostics under LC_ALL=C before
    # classifying: under a translated locale an old sync
    # option error would not match the English patterns
    # and be misjudged as an IO failure.
    err=$(LC_ALL=C sync -f "$target" 2>&1) || {
        case "$err" in
            *'invalid option'*|*'unrecognized option'*|*'illegal option'*) return 0 ;;
            *) return 1 ;;
        esac
    }
    return 0
}

