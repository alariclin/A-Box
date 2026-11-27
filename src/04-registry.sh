# ABOX-MODULE-BEGIN 04-registry managed inventory, shortcuts, services, firewall persistence
#   Source: install.sh lines 15453-20003 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
managed_auxiliary_paths() {
    # Shortcut entries come from the resolver (the active name set in
    # /etc/ddr/.shortcut, default "ab abox"); the old /usr/local/bin/sb
    # is out of scope and is never listed here.
    shortcut_primary_paths
    printf '%s\n' \
        /etc/logrotate.d/A-Box \
        /etc/fail2ban/filter.d/A-Box.conf \
        /etc/fail2ban/jail.d/A-Box.local \
        /etc/sysctl.d/99-A-Box-tune.conf \
        /etc/security/limits.d/A-Box.conf \
        /etc/modules-load.d/A-Box-bbr.conf \
        /etc/systemd/resolved.conf.d/99-abox-dns.conf \
        /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf \
        /etc/systemd/system/A-Box-firewall.service \
        /etc/init.d/A-Box-firewall \
        /usr/local/bin/abox-hy2-xtables-lock-grant \
        /etc/tmpfiles.d/abox-xtables-lock.conf
}

auxiliary_content_is_abox_managed() {
    local file="$1" logical_path="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ "$logical_path" == /usr/local/bin/sb ]]; then
        grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null && return 0
        grep -Fq 'exec bash /etc/ddr/A-Box.sh "$@"' "$file" 2>/dev/null || return 1
        grep -Fq 'exec sudo bash /etc/ddr/A-Box.sh "$@"' "$file" 2>/dev/null || return 1
        return 0
    fi
    # R4-06: the three runtime helpers need marker AND content. The old
    # early return made their content checks dead code; the self-test
    # requires content without the marker to be foreign, so the early
    # return is skipped for these three paths only. Other paths keep the
    # marker-or-fingerprint contract.
    case "$logical_path" in
        /etc/ddr/traffic_monitor.sh|/etc/ddr/geo_update.sh|/etc/ddr/socket_probe.sh) ;;
        *) grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null && return 0 ;;
    esac
    # Path-specific legacy fingerprints allow a one-time migration. New files
    # always carry the exact marker above.
    case "$logical_path" in
        /etc/logrotate.d/A-Box)
            grep -Fq '/var/log/A-Box-*.log' "$file" && grep -Fq 'copytruncate' "$file"
            ;;
        /etc/fail2ban/filter.d/A-Box.conf)
            grep -Fq '[Definition]' "$file" && grep -Fq 'message authentication failed' "$file"
            ;;
        /etc/fail2ban/jail.d/A-Box.local)
            grep -Eq '^\[A-Box-(tcp|udp)\]$' "$file" && grep -Fq 'filter = A-Box' "$file"
            ;;
        /etc/sysctl.d/99-A-Box-tune.conf)
            grep -Eq '^fs\.file-max[[:space:]]*=' "$file" && grep -Eq '^net\.ipv4\.tcp_syncookies[[:space:]]*=' "$file"
            ;;
        /etc/security/limits.d/A-Box.conf)
            grep -Fxq '* soft nofile 1048576' "$file" && grep -Fxq 'root hard nofile 1048576' "$file"
            ;;
        /etc/systemd/resolved.conf.d/99-abox-dns.conf)
            # Legacy fingerprint: files written before the marker line
            # was added carry the exact A-Box drop-in shape.
            grep -Fq '[Resolve]' "$file" && grep -Fq 'FallbackDNS=' "$file" && grep -Fq 'Domains=~.' "$file"
            ;;
        /etc/systemd/system/A-Box-firewall.service|/etc/init.d/A-Box-firewall)
            grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null
            ;;
        /etc/ddr/traffic_monitor.sh)
            grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null && grep -Fq 'TRAFFIC_LIMIT_GB' "$file" 2>/dev/null && grep -Fq 'month_bytes()' "$file" 2>/dev/null
            ;;
        /etc/ddr/geo_update.sh)
            grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null && grep -Fq 'Geo' "$file" 2>/dev/null && (grep -Fq 'update_geo_ownership' "$file" 2>/dev/null || grep -Fq 'refresh_dynamic_core_subtree_ownership' "$file" 2>/dev/null)
            ;;
        /etc/ddr/socket_probe.sh)
            grep -Fxq '# Managed by A-Box' "$file" 2>/dev/null && grep -Fq '/run/A-Box-socket-probe.lock' "$file" 2>/dev/null && grep -Fq 'socket_owned_by_pid' "$file" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

auxiliary_path_is_abox_managed() {
    auxiliary_content_is_abox_managed "$1" "$1"
}

assert_abox_auxiliary_safe() {
    local path="$1"
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    auxiliary_path_is_abox_managed "$path" && return 0
    # B2-01: return 1 (not die) so callers with cleanup handlers
    # (e.g. tx_dir removal) actually run; bare callers must add || die.
    return 1
}

remove_owned_auxiliary_path() {
    local path="$1"
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    auxiliary_path_is_abox_managed "$path" || return 0
    path_tree_has_mountpoint "$path" && return 1
    rm -rf -- "$path" || return 1
    [[ ! -e "$path" && ! -L "$path" ]]
}


# SYD-B E3: remove every user registry belonging to one core family.
# Hysteria registries carry both hy2 and hysteria prefixes.
users_registries_remove_core() {
    local _dir="${ABOX_USERS_DIR:-/etc/ddr/users.d}" _f='' _prefix _prefixes=''
    case "$1" in
        hysteria) _prefixes='hy2 hysteria' ;;
        xray|sing-box) _prefixes="$1" ;;
        *) return 0 ;;
    esac
    # R8-F04-2: refuse a symlinked registry dir before the glob can
    # follow it into the link target. The leaf ! -L guard only covers
    # the last component; a linked ancestor would delete ordinary
    # files outside the registry. A missing dir stays a no-op success.
    # H2 (R15b residual, hardening): also check the ancestor chain
    # (path_parent_chain_safe) -- the leaf guard alone misses a
    # symlinked ancestor, which the glob then follows out of the
    # registry. Same guard added to users_registries_wipe below.
    [[ ! -L "$_dir" ]] || return 1
    path_parent_chain_safe "$_dir" || return 1
    [[ -d "$_dir" ]] || return 0
    for _prefix in $_prefixes; do
        for _f in "$_dir"/${_prefix}__*.json; do
            [[ -f "$_f" && ! -L "$_f" ]] || continue
            rm -f -- "$_f" || return 1
        done
    done
    return 0
}

# SYD-B2 E18: a pruned stack must not leave orphaned panel links.
# Mirrors _protocol_removed_side_effects: remove a family's standalone
# link files when no live inbound still references them. The Argo link
# dies with the sing-box ws inbounds; the hysteria links are removed
# only once the Hysteria config is confirmed gone (H-26(3)).
# H-26(3): exact-tag survivorship for a -N instance link (e.g. the
# tuic-in-2.link / trojan-landing-2.link files, whose stem is the raw
# tag). The family survivor regex would count the BASE instance as
# evidence for the -N link, so the -N stem needs its own check: rc 0 =
# the exact tag is still served, rc 1 = confirmed absent (a missing
# config counts as absent, as in _standalone_link_survivor), rc 2 =
# unverifiable (empty / unparseable config) -- callers must only delete
# on rc 1.
_standalone_link_tag_survivor() {
    local _tag="$1" _cfg="$2" _stripped='' _jq_rc=0
    # M-29: a symlinked config is unverifiable (rc 2), not "confirmed
    # absent" (rc 1) -- the link target may still serve the tag, and
    # callers delete the link only on rc 1.
    [[ -L "$_cfg" ]] && return 2
    # R15b-M2: only a fully missing config is "confirmed absent"
    # (rc 1). A path that exists but is not a regular file (a
    # directory, FIFO, ...) is unverifiable (rc 2).
    [[ -e "$_cfg" ]] || return 1
    [[ -f "$_cfg" ]] || return 2
    [[ -s "$_cfg" ]] || return 2
    _stripped=$(jsonc_strip_comments "$_cfg" 2>/dev/null) || return 2
    [[ -n "${_stripped//[[:space:]]/}" ]] || return 2
    # R15b-M2: reject a structurally broken config instead of
    # folding it into "no tag": the top level must be a single
    # object, and inbounds, when present, must be an array.
    # (.inbounds[]? silently yields nothing for false/null, which
    # used to return rc 1.) An absent or empty inbounds is still
    # "confirmed absent" (rc 1) via the query below.
    printf '%s' "$_stripped" | jq -s -e 'if length != 1 then error("config is not a single JSON document") elif (.[0] | type) != "object" then error("config top level is not an object") elif (.[0] | has("inbounds")) and ((.[0].inbounds | type) != "array") then error("config inbounds is not an array") else true end' >/dev/null 2>&1 || return 2
    printf '%s' "$_stripped" | jq -s -e --arg tag "$_tag" '([.[] | (.inbounds[]? | select((.tag // "") == $tag))] | length) > 0' >/dev/null 2>&1 || _jq_rc=$?
    case "$_jq_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# H-26(3): map one on-disk link stem to its survivor key(s) and delete
# only when EVERY candidate survivor confirms rc 1. An unmapped stem is
# left alone (fail-closed). Ambiguous stems (trojan-landing-N,
# socks5-landing-N) can belong to either core, so both survivors must
# confirm "gone" before the link is deleted. -N instance stems are
# checked by exact tag (_standalone_link_tag_survivor): the family
# regex would count the base instance as evidence for the -N link.
# Per-core -N stems (trojan-landing-N-sb/-xray, socks5-landing-N-sb/-xray)
# belong to one core: only that core's config is consulted; the legacy
# ambiguous stem keeps the both-gone rule above.
# Always returns 0.
_prune_standalone_link_file() {
    local srv="$1" stem="$2" link="$3" _key='' _rc=0 _all_gone=1 _tag='' _cfg=''
    local -a _keys=() _cfgs=()
    # R15b-M1: [0-9]* in the case below matches a digit followed by
    # anything, so a user-kept backup such as trojan-xray-2-backup.link
    # would be treated as instance 2 and deleted. Any stem carrying
    # a -<digit> segment must be exactly <family>-<digits> (after
    # stripping an optional -sb/-xray core suffix); anything else is
    # not a numbered instance and is left alone (fail-closed).
    local _m1_base="$stem"
    case "$_m1_base" in *-sb) _m1_base="${_m1_base%-sb}" ;; *-xray) _m1_base="${_m1_base%-xray}" ;; esac
    if [[ "$_m1_base" =~ -[0-9] ]]; then
        [[ "$_m1_base" =~ ^(trojan-landing|socks5-landing|trojan-xray|trojan-sb|socks5-xray|socks5-sb|tuic-in|anytls-in|shadowtls-in|mixed-in|socks-in)-[0-9]+$ ]] || return 0
    fi
    case "$stem" in
        trojan-xray) [[ "$srv" == xray ]] || return 0; _keys=(trojan-xray) ;;
        socks5-xray) [[ "$srv" == xray ]] || return 0; _keys=(socks5-xray) ;;
        trojan-sb) [[ "$srv" == sing-box ]] || return 0; _keys=(trojan-sb) ;;
        tuic) [[ "$srv" == sing-box ]] || return 0; _keys=(tuic) ;;
        anytls) [[ "$srv" == sing-box ]] || return 0; _keys=(anytls) ;;
        shadowtls) [[ "$srv" == sing-box ]] || return 0; _keys=(shadowtls) ;;
        socks5-sb) [[ "$srv" == sing-box ]] || return 0; _keys=(socks5-sb) ;;
        trojan-landing)
            [[ "$srv" == xray || "$srv" == sing-box ]] || return 0
            _keys=(trojan-xray trojan-sb) ;;
        trojan-landing-[0-9]*-sb)
            [[ "$srv" == sing-box ]] || return 0
            _tag="${stem%-sb}"; _cfgs=(/etc/sing-box/config.json) ;;
        trojan-landing-[0-9]*-xray)
            [[ "$srv" == xray ]] || return 0
            _tag="${stem%-xray}"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}") ;;
        trojan-landing-[0-9]*)
            [[ "$srv" == xray || "$srv" == sing-box ]] || return 0
            _tag="$stem"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" /etc/sing-box/config.json) ;;
        socks5-landing)
            [[ "$srv" == xray || "$srv" == sing-box ]] || return 0
            _keys=(socks5-xray socks5-sb) ;;
        socks5-landing-[0-9]*-sb)
            [[ "$srv" == sing-box ]] || return 0
            _tag="${stem%-sb}"; _cfgs=(/etc/sing-box/config.json) ;;
        socks5-landing-[0-9]*-xray)
            [[ "$srv" == xray ]] || return 0
            _tag="${stem%-xray}"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}") ;;
        socks5-landing-[0-9]*)
            [[ "$srv" == xray || "$srv" == sing-box ]] || return 0
            _tag="$stem"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" /etc/sing-box/config.json) ;;
        trojan-xray-[0-9]*)
            [[ "$srv" == xray ]] || return 0
            _tag="trojan-landing-${stem#trojan-xray-}"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}") ;;
        trojan-sb-[0-9]*)
            [[ "$srv" == sing-box ]] || return 0
            _tag="trojan-landing-${stem#trojan-sb-}"; _cfgs=(/etc/sing-box/config.json) ;;
        socks5-xray-[0-9]*)
            [[ "$srv" == xray ]] || return 0
            _tag="socks5-landing-${stem#socks5-xray-}"; _cfgs=("${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}") ;;
        socks5-sb-[0-9]*)
            [[ "$srv" == sing-box ]] || return 0
            _tag="socks5-landing-${stem#socks5-sb-}"; _cfgs=(/etc/sing-box/config.json) ;;
        tuic-in) [[ "$srv" == sing-box ]] || return 0; _keys=(tuic) ;;
        tuic-in-[0-9]*) [[ "$srv" == sing-box ]] || return 0; _tag="$stem"; _cfgs=(/etc/sing-box/config.json) ;;
        anytls-in) [[ "$srv" == sing-box ]] || return 0; _keys=(anytls) ;;
        anytls-in-[0-9]*) [[ "$srv" == sing-box ]] || return 0; _tag="$stem"; _cfgs=(/etc/sing-box/config.json) ;;
        shadowtls-in) [[ "$srv" == sing-box ]] || return 0; _keys=(shadowtls) ;;
        shadowtls-in-[0-9]*) [[ "$srv" == sing-box ]] || return 0; _tag="$stem"; _cfgs=(/etc/sing-box/config.json) ;;
        mixed-in) [[ "$srv" == sing-box ]] || return 0; _keys=(socks5-sb) ;;
        mixed-in-[0-9]*|socks-in-[0-9]*) [[ "$srv" == sing-box ]] || return 0; _tag="$stem"; _cfgs=(/etc/sing-box/config.json) ;;
        socks-in) [[ "$srv" == sing-box ]] || return 0; _keys=(socks5-sb) ;;
        *) return 0 ;;
    esac
    # M-02: one-time migration -- a pre-fix shared -N file (one file,
    # last writer wins) is removed when its title proves it belongs to
    # this core; the per-core stem (trojan-xray-N / trojan-sb-N) is now
    # the canonical carrier for the live link.
    case "$stem" in
        *-sb|*-xray)
            # Guard: live per-core links (trojan-landing-2-sb/-xray)
            # must never be pruned by the broad M-02 pattern below.
            ;;
        trojan-landing-[0-9]*|socks5-landing-[0-9]*)
            if { [[ "$srv" == xray ]] && grep -Fq '(Xray)' "$link" 2>/dev/null; } ||
               { [[ "$srv" == sing-box ]] && grep -Fq '(sing-box)' "$link" 2>/dev/null; }; then
                rm -f -- "$link" 2>/dev/null || true
                return 0
            fi ;;
    esac
    if [[ -n "$_tag" ]]; then
        # -N instance stem: only the exact tag counts as a survivor;
        # every owning config must confirm rc 1 before deleting.
        for _cfg in "${_cfgs[@]}"; do
            _rc=0
            _standalone_link_tag_survivor "$_tag" "$_cfg" || _rc=$?
            [[ "$_rc" == 1 ]] || _all_gone=0
        done
    else
        for _key in "${_keys[@]}"; do
            _rc=0
            _standalone_link_survivor "$_key" || _rc=$?
            [[ "$_rc" == 1 ]] || _all_gone=0
        done
    fi
    if [[ "$_all_gone" == 1 ]]; then rm -f -- "$link" 2>/dev/null || true; fi
    return 0
}

_prune_standalone_links() {
    local srv="$1" dir="${ABOX_DIR:-/etc/ddr}/standalone-links.d" link='' stem='' _ws_out='' _stripped=''
    [[ -d "$dir" ]] || return 0
    # H-26(3): sweep the links actually on disk (base stems AND -N
    # variants such as tuic-in-2.link, whose stem is the raw tag) and
    # delete only on confirmed rc 1 via _prune_standalone_link_file.
    # latest-*.link is out of scope here; argo.link is handled below.
    for link in "$dir"/*.link; do
        [[ -e "$link" || -L "$link" ]] || continue
        stem="${link##*/}"; stem="${stem%.link}"
        case "$stem" in
            latest-*) continue ;;
            argo) continue ;;
            hy2|hysteria)
                [[ "$srv" == hysteria ]] || continue
                # H-26(3): no longer unconditional. Only delete once
                # the Hysteria config is confirmed gone; a config
                # that survived removal keeps its links.
                # M-29 (02b2a-M1): a dangling symlink config is
                # unverifiable, not "confirmed absent" (-e is false
                # for a dangling link); only a fully missing config
                # deletes the link.
                if [[ ! -e /etc/hysteria/config.yaml && ! -L /etc/hysteria/config.yaml ]]; then
                    rm -f -- "$link" 2>/dev/null || true
                fi
                ;;
            *) _prune_standalone_link_file "$srv" "$stem" "$link" ;;
        esac
    done
    if [[ "$srv" == sing-box ]]; then
        # M-29 (02b2a-M1): a symlinked config is unverifiable (rc 2),
        # not "confirmed absent" -- a dangling link must keep argo.link,
        # as must a non-regular config; only a fully missing config
        # deletes it.
        if [[ -L /etc/sing-box/config.json ]]; then
            :
        elif [[ ! -e /etc/sing-box/config.json ]]; then
            rm -f -- "$dir/argo.link" 2>/dev/null || true
        elif [[ ! -f /etc/sing-box/config.json ]]; then
            :
        else
            # H-26(3): strip JSONC before jq (bare jq fails rc 5 on a
            # commented config). A jq failure is unverifiable, so the
            # link is kept; only a clean "no ws inbound" deletes it.
            # H-26(3b): an empty / comment-only config is likewise
            # unverifiable (same non-empty check as
            # _standalone_link_tag_survivor's rc 2): keep the link.
            _stripped=$(jsonc_strip_comments /etc/sing-box/config.json 2>/dev/null) || _stripped=''
            if [[ -z "${_stripped//[[:space:]]/}" ]]; then
                :
            elif ! _ws_out=$(printf '%s' "$_stripped" | jq -r '.inbounds[]? | select(.tag == "vmess-ws-in" or .tag == "vless-ws-in")' 2>/dev/null); then
                :
            elif [[ -z "$_ws_out" ]]; then
                rm -f -- "$dir/argo.link" 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

prune_owned_core_families_except() {
    local allowed=" $* " srv
    for srv in xray sing-box hysteria; do
        [[ "$allowed" == *" $srv "* ]] && continue
        { abox_owns_service "$srv" || abox_owns_config_only_core_dir "$srv"; } || continue
        stop_abox_service "$srv" || die "$(tprintf pr_stop "$srv")"
        # L3 (2026-11-27): a pruned hysteria family must not leave
        # its official-hop NAT rules behind. The prune path never
        # calls _remove_hy2_official, so reclaim them here, after
        # the stop and before the manifest/force family removal
        # (same cleanup-first ordering: a failure aborts the deploy
        # before anything irreversible is deleted, and a retry
        # re-runs this step).
        if [[ "$srv" == 'hysteria' ]]; then
            remove_hy2_official_hop_rules || die "$(tprintf pr_remove "$srv")"
        fi
        remove_owned_core_family "$srv" 0 1 || die "$(tprintf pr_remove "$srv")"
        # M-18 (supplement): pruning hysteria leaves no consumer of
        # the xtables-lock grant; revoke it (service already stopped,
        # unit already deleted above).
        if [[ "$srv" == 'hysteria' ]]; then
            hy2_hop_xtables_lock_revoke || die "$(tprintf pr_remove "$srv")"
        fi
        # R23 F-ARGO-ORPHAN: the sing-box stack owns the Argo tunnels
        # (argo-vless/argo-vmess temp units and the shared fixed `argo`
        # unit all serve its ws inbounds). Pruning the stack deletes
        # those inbounds, so the tunnels must go too; otherwise their
        # cloudflared processes keep running against dead origins.
        # Best-effort: argo_remove_unit refuses foreign units, and a
        # missing unit is not an error here.
        if [[ "$srv" == 'sing-box' ]]; then
            argo_remove_unit argo-vless || true
            argo_remove_unit argo-vmess || true
            argo_remove_unit argo || true
            # F-R23-01: remove Argo metadata only after confirmed teardown.
            local _argo_prune_clean=1 _argo_name _argo_unit
            for _argo_name in argo-vless argo-vmess argo; do
                if [[ "${INIT_SYS:-}" == systemd ]]; then
                    _argo_unit="/etc/systemd/system/${_argo_name}.service"
                else
                    _argo_unit="/etc/init.d/${_argo_name}"
                fi
                if [[ -e "$_argo_unit" || -L "$_argo_unit" ]] ||
                   ! argo_unit_stopped_confirmed "$_argo_name"; then
                    _argo_prune_clean=0
                fi
            done
            if [[ "$_argo_prune_clean" == 1 ]]; then
                rm -f -- "$ARGO_STATE_FILE" /etc/ddr/.argo-token || true
            fi
        fi
        # SYD-B E3: a pruned stack must not leave ghost panel entries.
        users_registries_remove_core "$srv" || die "$(tprintf pr_remove "$srv")"
        # SYD-B2 E18: a pruned stack must not leave orphaned panel links.
        _prune_standalone_links "$srv"
    done
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || die "$(tr_msg pr_reload)"
    fi
}

_core_residue_dir_known_only() {
    # Read-only: $1 dir, rest allowed basenames (glob patterns). A pattern
    # ending in '/' allows a subdirectory of that name (checked by the
    # caller, never deleted on this proof alone). Absent dir: ok.
    # Symlink dir, unknown files, unknown/empty subdirs, links, or
    # abnormal entries: refuse. No deletion, no writes.
    local _d="$1"; shift
    [[ -e "$_d" || -L "$_d" ]] || return 0
    [[ -d "$_d" && ! -L "$_d" ]] || return 1
    local _tmp _n _base _pat _ok
    _tmp=$(mktemp) || return 1
    if ! find "$_d" -mindepth 1 -maxdepth 1 -print0 >"$_tmp" 2>/dev/null; then rm -f -- "$_tmp"; return 1; fi
    while IFS= read -r -d '' _n; do
        # R11-F R8-01: ${...##*/} keeps trailing newlines that
        # command substitution strips, so $'acme\n' / $'config.yaml\n'
        # no longer false-match the whitelist. Inputs come from
        # find -mindepth 1 -print0, so no trailing-slash form reaches here.
        _base=${_n##*/}
        _ok=0
        for _pat in "$@"; do
            if [[ "$_pat" == */ ]]; then
                [[ -d "$_n" && ! -L "$_n" && "$_base" == "${_pat%/}" ]] && _ok=1
            else
                [[ -f "$_n" && ! -L "$_n" ]] || continue
                case "$_base" in $_pat) _ok=1 ;; esac
            fi
            [[ "$_ok" == 1 ]] && break
        done
        if [[ "$_ok" != 1 ]]; then rm -f -- "$_tmp"; return 1; fi
    done < "$_tmp"
    rm -f -- "$_tmp"
    return 0
}

_core_residue_tree_plain_files_only() {
    # Read-only: every entry under $1 must be a plain dir or regular file;
    # any link, fifo, socket, or device refuses. Used for the hysteria
    # acme/ subtree once its ownership marker has proven it.
    local _d="$1" _tmp _n
    [[ -d "$_d" && ! -L "$_d" ]] || return 1
    _tmp=$(mktemp) || return 1
    if ! find "$_d" -mindepth 1 -print0 >"$_tmp" 2>/dev/null; then rm -f -- "$_tmp"; return 1; fi
    while IFS= read -r -d '' _n; do
        if [[ ! -d "$_n" && ! -f "$_n" ]] || [[ -L "$_n" ]]; then rm -f -- "$_tmp"; return 1; fi
    done < "$_tmp"
    rm -f -- "$_tmp"
    return 0
}

core_family_residue_known_only() {
    # R8-F04-3 (hardening): read-only residue precheck for the config-only
    # removal branch. Returns 0 only when every path
    # remove_core_family_force would delete for this family is a known
    # A-Box path, matched by family-relative path (never by bare
    # basename), with no symlink or abnormal entry anywhere in the tree.
    # The binary and the service unit must be absent here (the config-only
    # identification already requires that); one that reappears is unknown
    # and refuses. The hysteria acme/ subtree is allowed only through its
    # existing marker/manifest proof, never by name. A whitelist match is
    # legacy compatibility, not proof that a known file is unmodified —
    # when a trusted manifest exists, the manifest path is used instead.
    local srv="$1" path core_paths=''
    case "$srv" in
        xray|sing-box|hysteria|xray-latest) ;;
        *) return 1 ;;
    esac
    core_paths=$(core_family_paths "$srv") || return 1
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" || -L "$path" ]] || continue
        case "$path" in
            /usr/local/bin/*)
                return 1 ;;
            /etc/init.d/*|/etc/systemd/system/*)
                return 1 ;;
            /etc/conf.d/*)
                [[ -f "$path" && ! -L "$path" ]] || return 1 ;;
            *)
                case "$srv:$path" in
                    xray:/usr/local/etc/xray)
                        _core_residue_dir_known_only "$path" config.json || return 1 ;;
                    xray:/usr/local/share/xray)
                        _core_residue_dir_known_only "$path" geoip.dat geosite.dat || return 1 ;;
                    sing-box:/etc/sing-box)
                        _core_residue_dir_known_only "$path" config.json hy2.crt hy2.key tuic.crt tuic.key 'tuic-*.crt' 'tuic-*.key' || return 1 ;;
                    hysteria:/etc/hysteria)
                        _core_residue_dir_known_only "$path" config.yaml server.crt server.key 'acme/' || return 1
                        if [[ -e /etc/hysteria/acme || -L /etc/hysteria/acme ]]; then
                            { hysteria_acme_owner_marker_valid /etc/hysteria/acme/.A-Box-managed \
                                || hysteria_acme_current_tree_matches_manifest "$ABOX_CORE_OWNERSHIP" /etc/hysteria/acme; } || return 1
                            _core_residue_tree_plain_files_only /etc/hysteria/acme || return 1
                        fi ;;
                    xray-latest:/etc/ddr/xray-latest)
                        _core_residue_dir_known_only "$path" config.json || return 1 ;;
                    *) return 1 ;;
                esac
                ;;
        esac
    done <<< "$core_paths"
    return 0
}

abox_owns_config_only_core_dir() {
    local srv="$1" cfg_dir='' bin='' _u='' _g='' _gid=''
    same_name_service_unit_path "$srv" >/dev/null 2>&1 && return 1
    case "$srv" in
        xray) cfg_dir=/usr/local/etc/xray; bin=/usr/local/bin/xray ;;
        sing-box) cfg_dir=/etc/sing-box; bin=/usr/local/bin/sing-box ;;
        hysteria) cfg_dir=/etc/hysteria; bin=/usr/local/bin/hysteria ;;
        # SYD-B5e R2: latest needs the same config-only branch, or a
        # unit-deleted latest stack is judged foreign and unrestorable.
        xray-latest) cfg_dir=/etc/ddr/xray-latest; bin=/usr/local/bin/xray-latest ;;
        *) return 1 ;;
    esac
    [[ ! -e "$bin" && ! -L "$bin" && -d "$cfg_dir" && ! -L "$cfg_dir" ]] || return 1
    IFS=$'\t' read -r _u _g < <(abox_runtime_identity "$srv" 2>/dev/null) || return 1
    _gid=$(getent group "$_g" 2>/dev/null | awk -F: '{print $3}')
    [[ -n "$_gid" && "$(stat -c %u:%g "$cfg_dir" 2>/dev/null || true)" == "0:$_gid" ]]
}

list_foreign_core_conflicts() {
    local srv path unit key core_paths=''
    local -A seen=()
    for srv in "$@"; do
        # R8-F04-3 (hardening): a config-only residue is skipped only when the
        # read-only residue precheck also passes; unknown files stay listed
        # as conflicts instead of being silently treated as ours.
        { abox_owns_service "$srv" || { abox_owns_config_only_core_dir "$srv" && core_family_residue_known_only "$srv"; }; } && continue
        unit=$(same_name_service_unit_path "$srv" 2>/dev/null || true)
        if [[ -n "$unit" ]]; then
            key="${srv}|${unit}"
            if [[ -z "${seen[$key]:-}" ]]; then printf '%s|%s\n' "$srv" "$unit"; seen[$key]=1; fi
        fi
        core_paths=$(core_family_paths "$srv") || return 1
        while IFS= read -r path; do
            [[ -e "$path" || -L "$path" ]] || continue
            key="${srv}|${path}"
            [[ -n "${seen[$key]:-}" ]] && continue
            printf '%s|%s\n' "$srv" "$path"
            seen[$key]=1
        done <<< "$core_paths"
    done
}

# SYD-B E6: the canonical binary path of a core family (same
# mapping as core_family_binary_orphaned, without the checks).
core_family_binary_of() {
    case "$1" in
        xray) printf '%s\n' /usr/local/bin/xray ;;
        sing-box) printf '%s\n' /usr/local/bin/sing-box ;;
        hysteria) printf '%s\n' /usr/local/bin/hysteria ;;
        *) return 1 ;;
    esac
}

# SYD-B E11: the two paths a residue takeover may delete for one
# family: its binary and its config dir. Shared data (e.g.
# /usr/local/share/xray) is never in this list.
core_family_residue_paths() {
    case "$1" in
        xray) printf '%s\n' /usr/local/bin/xray /usr/local/etc/xray ;;
        sing-box) printf '%s\n' /usr/local/bin/sing-box /etc/sing-box ;;
        hysteria) printf '%s\n' /usr/local/bin/hysteria /etc/hysteria ;;
        *) return 1 ;;
    esac
}

# R26-H-NF-S1-02: auxiliary residue paths a takeover may delete for one
# family: only an EMPTY, non-symlink directory that is part of the
# family's canonical tree but is neither its binary nor its config dir
# (today: /usr/local/share/xray, the geoip/geosite dir). A non-empty
# dir is never listed: its contents are user data until proven
# otherwise, and the assert keeps hard-refusing it (fail-closed). A
# mountpoint is never listed either. An absent path is not listed.
core_family_residue_aux_paths() {
    local _dir='' _first=''
    case "$1" in
        xray) _dir=/usr/local/share/xray ;;
        *) return 0 ;;
    esac
    [[ -d "$_dir" && ! -L "$_dir" ]] || return 0
    path_tree_has_mountpoint "$_dir" && return 0
    _first=$(find "$_dir" -mindepth 1 -print -quit 2>/dev/null) || return 0
    [[ -z "$_first" ]] || return 0
    printf '%s\n' "$_dir"
}

# SYD-B E11: plan a residue takeover. Runs BEFORE the assert and
# BEFORE begin (no backup yet): it only lists residue-shaped
# stacks (binary + config dir present, no unit, not owned) and
# records an explicit yes in ABOX_RESIDUE_TAKEOVER (space-
# separated srv|path pairs). Decline / EOF / non-Y aborts.
residue_takeover_plan() {
    local _srv='' _bin='' _cfg='' _unit='' _paths='' _ans='' _aux='' _ap=''
    ABOX_RESIDUE_TAKEOVER=''
    for _srv in "$@"; do
        { abox_owns_service "$_srv" || abox_owns_config_only_core_dir "$_srv"; } && continue
        _paths=$(core_family_residue_paths "$_srv") || continue
        _bin=$(printf '%s' "$_paths" | sed -n '1p')
        _cfg=$(printf '%s' "$_paths" | sed -n '2p')
        _unit=$(same_name_service_unit_path "$_srv" 2>/dev/null || true)
        [[ -z "$_unit" || ( ! -e "$_unit" && ! -L "$_unit" ) ]] || continue
        _aux=$(core_family_residue_aux_paths "$_srv" 2>/dev/null || true)
        # R26-H-NF-S1-02: an empty auxiliary dir (e.g.
        # /usr/local/share/xray) belongs to the same residue stack;
        # leaving it out of the plan makes the later assert hard-refuse
        # it after the user already said yes. A stack with only an
        # empty aux dir (binary + config dir already gone) is takeable
        # on its own; a stack with neither is skipped.
        # 02b2b-M-01: a real directory at the binary slot is not a
        # binary (existence alone admitted it); admitting it would let
        # the executor rm -rf it. A regular file or a symlink is the
        # only residue shape for a binary.
        if [[ ( -f "$_bin" || -L "$_bin" ) ]] && [[ -d "$_cfg" && ! -L "$_cfg" ]]; then
            ABOX_RESIDUE_TAKEOVER+="$_srv|$_bin $_srv|$_cfg "
        elif [[ -z "$_aux" ]]; then
            continue
        fi
        while IFS= read -r _ap; do
            [[ -n "$_ap" ]] || continue
            ABOX_RESIDUE_TAKEOVER+="$_srv|$_ap "
        done <<< "$_aux"
    done
    [[ -n "$ABOX_RESIDUE_TAKEOVER" ]] || return 0
    ABOX_RESIDUE_TAKEOVER="${ABOX_RESIDUE_TAKEOVER% }"
    msg "${YELLOW}$(tprintf rs_takeover_warn "$ABOX_RESIDUE_TAKEOVER")${NC}"
    read -r -p "$(tr_msg rs_takeover_prompt)" _ans || return 1
    is_yes "$_ans" || return 1
    return 0
}

# SYD-B E11: execute a planned takeover. Runs AFTER begin (backup
# taken): re-verifies each path is still residue-shaped (listed
# for its family, unit still absent) before deleting it. A path
# that changed shape since the plan is left alone.
residue_takeover_clear() {
    local _item='' _srv='' _path='' _unit='' _rp='' _failed=0 _rp_bin='' _rp_cfg=''
    [[ -n "${ABOX_RESIDUE_TAKEOVER:-}" ]] || return 0
    for _item in $ABOX_RESIDUE_TAKEOVER; do
        _srv="${_item%%|*}"; _path="${_item#*|}"
        # R26-H-NF-S1-02: aux paths are re-verified here too (the aux
        # function only lists a dir while it is still empty), so a dir
        # that gained files after the plan is left alone, never rm -rf'd.
        _rp=$( { core_family_residue_paths "$_srv" 2>/dev/null; core_family_residue_aux_paths "$_srv" 2>/dev/null; } || true)
        # R16-01: a path that vanished entirely is idempotent success;
        # a path that still exists but is no longer listed changed
        # shape since the plan (e.g. an aux dir that gained files)
        # and must fail, not be silently skipped while the plan is
        # cleared below. Same for a same-name unit that appeared.
        if ! printf '%s\n' "$_rp" | grep -Fxq -- "$_path"; then
            [[ ! -e "$_path" && ! -L "$_path" ]] || _failed=1
            continue
        fi
        _unit=$(same_name_service_unit_path "$_srv" 2>/dev/null || true)
        if [[ -n "$_unit" && ( -e "$_unit" || -L "$_unit" ) ]]; then _failed=1; continue; fi
        # 02b2b-M-01: re-verify the shape, not just the listing: the
        # family path list is static, so a binary slot that is (or
        # became) a real directory, or a config slot that is no longer
        # a real directory, is left alone and fails the takeover
        # instead of being rm -rf/rm -f'd. Aux paths need no extra
        # check here: the aux listing above only emits a still-empty
        # real directory, so a changed aux path already fails the
        # grep -Fxq above.
        _rp_bin=$(printf '%s\n' "$_rp" | sed -n '1p')
        _rp_cfg=$(printf '%s\n' "$_rp" | sed -n '2p')
        if [[ "$_path" == "$_rp_bin" ]]; then
            if [[ -d "$_path" && ! -L "$_path" ]]; then _failed=1; continue; fi
        elif [[ "$_path" == "$_rp_cfg" ]]; then
            if [[ ! -d "$_path" || -L "$_path" ]]; then _failed=1; continue; fi
        fi
        # R6C6-01: refuse mounted trees before rm; a bind mount would
        # delete shared foreign data. Failures propagate (no || true).
        # 3B-U3: ancestor-aware (same shape as R16-F05-02): a bind
        # mount on an ancestor is invisible to the subtree-only check.
        if path_tree_or_ancestors_mounted "$_path"; then _failed=1; continue; fi
        if [[ -d "$_path" && ! -L "$_path" ]]; then rm -rf -- "$_path" 2>/dev/null || _failed=1
        elif [[ -e "$_path" || -L "$_path" ]]; then rm -f -- "$_path" 2>/dev/null || _failed=1
        fi
    done
    (( _failed == 0 )) || return 1
    ABOX_RESIDUE_TAKEOVER=''
    return 0
}

# R25-F-S1-01 (GPT-tightened option A): a binary the ownership manifest
# registers (type F, service + path + matching SHA256) is A-Box-managed
# residue, not a foreign install. A missing row, a hash mismatch, or an
# unreadable manifest/file stays foreign (fail-closed); registration is
# classification only, never a deletion authorization (the prompt stays).
core_binary_managed_registered() {
    local srv="$1" path="$2"
    local _mf="${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}" _want='' _have=''
    [[ -f "$_mf" && ! -L "$_mf" ]] || return 1
    # R16-F05-01: the manifest is a trust anchor for the no-confirm
    # deletion below; a drifted (non-root-owned or group/other-writable)
    # manifest must not authorise it. Same 0:0/0600 gate as
    # remove_recorded_core_family() applies to this manifest.
    [[ "$(stat -c %u:%g "$_mf" 2>/dev/null || true)" == 0:0 ]] || return 1
    [[ "$(stat -c %a "$_mf" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    _want=$(awk -F'\t' -v s="$srv" -v p="$path" '$1=="F" && $2==s && $3==p {print $4; exit}' "$_mf" 2>/dev/null || true)
    [[ -n "$_want" ]] || return 1
    _have=$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}') || return 1
    [[ -n "$_have" && "${_have,,}" == "${_want,,}" ]]
}

assert_no_foreign_core_conflicts() {
    local conflicts _kept='' _srv='' _path='' _bin='' _all_orphan=1 _all_managed=1 _ans=''
    conflicts=$(list_foreign_core_conflicts "$@") || die "$(tr_msg af_enum)"
    [[ -z "$conflicts" ]] && return 0
    # SYD-B E11: paths the user already approved for residue
    # takeover in this deployment are not conflicts.
    if [[ -n "${ABOX_RESIDUE_TAKEOVER:-}" ]]; then
        while IFS='|' read -r _srv _path; do
            [[ -n "$_path" ]] || continue
            case " ${ABOX_RESIDUE_TAKEOVER} " in *" ${_srv}|${_path} "*) continue ;; esac
            _kept+="${_srv}|${_path}"$'\n'
        done <<< "$conflicts"
        conflicts="$_kept"
        [[ -z "$conflicts" ]] && return 0
    fi
    # SYD-B E6: orphan shape alone proves nothing, so only when
    # EVERY conflict is an orphan binary at its canonical path
    # is an explicit inline cleanup offered; anything else keeps
    # the hard refusal, and EOF/non-Y refuses as well.
    while IFS='|' read -r _srv _path; do
        [[ -n "$_path" ]] || continue
        _bin=$(core_family_binary_of "$_srv" 2>/dev/null || true)
        if [[ "$_path" != "$_bin" ]] || ! core_family_binary_orphaned "$_srv"; then
            _all_orphan=0; break
        fi
        # Orphan shape alone does not tell whose binary this is; only a
        # manifest row with a matching SHA256 proves A-Box ownership.
        # Anything else stays "unowned" (existing wording and refusal).
        core_binary_managed_registered "$_srv" "$_path" || _all_managed=0
    done <<< "$conflicts"
    if (( _all_orphan == 1 )); then
        # R26-H-F-S1-01: every conflict is a TSV-registered, SHA-matched
        # A-Box binary left by an earlier clear (cores are kept by design,
        # so this residue is expected, not foreign). Clean it up inline
        # with no prompt: the redeploy is about to reinstall the same
        # core family, and prompting here is what the S1 retest proved
        # unachieved ("re-deploy must not be intercepted"). Unregistered
        # or SHA-mismatched orphans still go through the prompt below.
        if (( _all_managed == 1 )); then
            msg "${YELLOW}$(tprintf af_managed_orphan_warn "$conflicts")${NC}"
            while IFS='|' read -r _srv _path; do
                [[ -n "$_path" ]] || continue
                # R16-F05-02: refuse mounted trees before rm; a bind
                # mount on the file, below it, or on any ancestor
                # would delete shared foreign data (same rule as
                # residue_takeover_clear, R6C6-01, extended to
                # ancestors: path_tree_has_mountpoint alone cannot
                # see them). The orphan check above already refuses
                # mounted binaries; this re-check closes the window
                # between classification and delete.
                if path_tree_or_ancestors_mounted "$_path"; then
                    msg "${RED}[!] Refusing to delete mounted core binary: ${_path}${NC}"
                    die "$(tr_msg af_migrate)"
                fi
                rm -f -- "$_path" || die "$(tr_msg af_migrate)"
            done <<< "$conflicts"
            return 0
        fi
        msg "${YELLOW}$(tprintf af_orphan_warn "$conflicts")${NC}"
        read -r -p "$(tr_msg af_orphan_prompt)" _ans || die "$(tr_msg af_migrate)"
        if is_yes "$_ans"; then
            while IFS='|' read -r _srv _path; do
                [[ -n "$_path" ]] || continue
                # R16-F05-02: same ancestor-aware mount guard as the
                # no-confirm loop: confirming the orphan identity does
                # not authorise deleting shared backend data (the
                # prompt never shows mount state), and the window
                # since classification is larger here because of the
                # user interaction.
                if path_tree_or_ancestors_mounted "$_path"; then
                    msg "${RED}[!] Refusing to delete mounted core binary: ${_path}${NC}"
                    die "$(tr_msg af_migrate)"
                fi
                rm -f -- "$_path" || die "$(tr_msg af_migrate)"
            done <<< "$conflicts"
            return 0
        fi
    fi
    msg "${RED}[!] Refusing to overwrite non-A-Box core files/services:${NC}"
    while IFS='|' read -r srv path; do [[ -n "$path" ]] && msg "${RED}    ${srv}: ${path}${NC}"; done <<< "$conflicts"
    die "$(tr_msg af_migrate)"
}

# Legacy residue check: the core's unit file and config dir are
# already gone (an earlier cleanup removed them together with the
# ownership proof) and only the binary remains at the canonical
# path. Such a binary is inert - no working foreign install keeps
# its binary while losing both its unit and its config dir.
core_family_binary_orphaned() {
    local srv="$1" cfg_dir='' bin='' unit=''
    case "$srv" in
        xray) cfg_dir=/usr/local/etc/xray; bin=/usr/local/bin/xray ;;
        sing-box) cfg_dir=/etc/sing-box; bin=/usr/local/bin/sing-box ;;
        hysteria) cfg_dir=/etc/hysteria; bin=/usr/local/bin/hysteria ;;
        *) return 1 ;;
    esac
    [[ -x "$bin" && ! -L "$bin" ]] || return 1
    # R16-F05-02: a mounted binary is never an orphan: deleting it
    # would delete shared backend data, not a local residue. The
    # check covers the binary itself, below it, and every ancestor
    # up to / (a bind mount on /usr/local/bin is the threat, and
    # path_tree_has_mountpoint alone cannot see ancestor mounts).
    path_tree_or_ancestors_mounted "$bin" && return 1
    [[ ! -e "$cfg_dir" && ! -L "$cfg_dir" ]] || return 1
    unit=$(same_name_service_unit_path "$srv" 2>/dev/null || true)
    [[ -z "$unit" || ( ! -e "$unit" && ! -L "$unit" ) ]]
}

# S2-NEW-05: re-register a core family whose recorded files changed after
# registration, when the ONLY defect is content change. Refuses (rc 1) on
# every other defect: unrecorded children, symlinks, ownership/mode
# violations, mountpoints, a missing/tampered manifest, or no changed
# file at all. Deletes nothing itself; the caller retries the verified
# removal after a successful re-registration. Runtime identity must
# resolve; if the service user/group is gone, refuse (fail closed).
core_family_reregister_changed() {
    local srv="$1" _u='' _g='' _uid='' _gid=''
    case "$srv" in xray|sing-box|hysteria|xray-latest) ;; *) return 1 ;; esac
    [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || return 1
    IFS=$'\t' read -r _u _g < <(abox_runtime_identity "$srv") || return 1
    _uid=$(id -u "$_u" 2>/dev/null || true)
    _gid=$(getent group "$_g" 2>/dev/null | awk -F: '{print $3}')
    [[ "$_uid" =~ ^[0-9]+$ && "$_gid" =~ ^[0-9]+$ ]] || return 1
    python3 -I - "$srv" "$ABOX_CORE_OWNERSHIP" "$_uid" "$_gid" "$ABOX_DIR" <<'PY_CORE_REREGISTER'
import hashlib, os, re, stat, sys, tempfile
srv, manifest, runtime_uid, runtime_gid, abox_dir = sys.argv[1:]
runtime_uid = int(runtime_uid)
runtime_gid = int(runtime_gid)
try:
    _mst = os.lstat(manifest)
except OSError:
    raise SystemExit(1)
if (not stat.S_ISREG(_mst.st_mode) or stat.S_ISLNK(_mst.st_mode)
        or _mst.st_uid != 0 or _mst.st_gid != 0
        or (_mst.st_mode & 0o7777) != 0o600 or _mst.st_size > 4194304):
    raise SystemExit(1)
rows = []
with open(manifest, 'r', encoding='utf-8') as f:
    for line in f:
        p=line.rstrip('\n').split('\t')
        if len(p)!=4 or p[0] not in {'F','D'} or not p[2].startswith('/') or '\x00' in line:
            raise SystemExit(1)
        rows.append(p)
fam = [r for r in rows if r[1] == srv]
if not fam:
    raise SystemExit(1)
if len({(r[0], r[1], r[2]) for r in rows}) != len(rows):
    raise SystemExit(1)
files = {r[2]: r[3] for r in fam if r[0] == 'F'}
dirs = {r[2] for r in fam if r[0] == 'D'}
expected = set(files) | dirs
def _is_mountpoint(path):
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
        raise SystemExit(1)
    return False
_trusted = set()
for _p in os.environ.get('ABOX_TRUSTED_UNINSTALL_ANCESTORS', '').split(':'):
    if not _p:
        continue
    if not os.path.isabs(_p):
        raise SystemExit(1)
    _trusted.add(os.path.abspath(os.path.normpath(_p)))
def _ancestors_mounted(path):
    recorded = os.path.abspath(os.path.normpath(path))
    cur = recorded
    while cur != '/':
        if _is_mountpoint(cur):
            if cur == recorded or cur not in _trusted:
                return True
        cur = os.path.dirname(cur)
    return False
try:
    _ad_st = os.lstat(abox_dir)
except OSError:
    raise SystemExit(1)
if stat.S_ISLNK(_ad_st.st_mode) or not stat.S_ISDIR(_ad_st.st_mode):
    raise SystemExit(1)
changed = []
for path in sorted(expected, key=os.fsencode):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        continue
    if _ancestors_mounted(path):
        raise SystemExit(1)
    acme = srv == 'hysteria' and (path == '/etc/hysteria/acme' or path.startswith('/etc/hysteria/acme/'))
    uid_ok = st.st_uid in ({0} if not acme else {0, runtime_uid})
    gid_ok = st.st_gid in ({0, runtime_gid})
    group_write_ok = acme and path == '/etc/hysteria/acme' and st.st_uid == 0 and st.st_gid == runtime_gid and stat.S_ISDIR(st.st_mode)
    if (not uid_ok or not gid_ok or stat.S_ISLNK(st.st_mode)
            or (st.st_mode & 0o002) or ((st.st_mode & 0o020) and not group_write_ok)):
        raise SystemExit(1)
    if path in files:
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise SystemExit(1)
        h = hashlib.sha256()
        try:
            with open(path, 'rb') as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b''):
                    h.update(chunk)
        except OSError:
            raise SystemExit(1)
        if h.hexdigest() != files[path]:
            changed.append(path)
    else:
        if not stat.S_ISDIR(st.st_mode):
            raise SystemExit(1)
        try:
            names = os.listdir(path)
        except OSError:
            raise SystemExit(1)
        for name in names:
            if os.path.join(path, name) not in expected:
                raise SystemExit(1)
if not changed:
    raise SystemExit(1)
new_files = dict(files)
for path in changed:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    new_files[path] = h.hexdigest()
    print(f"[!] Re-registering changed {srv} file (content only): {path}", file=sys.stderr)
dirname = os.path.dirname(manifest)
fd, tmp = tempfile.mkstemp(prefix='.managed-core-files.', dir=dirname, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        for row in rows:
            if row[0] == 'F' and row[1] == srv and row[2] in new_files:
                row = ['F', srv, row[2], new_files[row[2]]]
            f.write('\t'.join(row) + '\n')
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.chown(tmp, 0, 0)
    os.replace(tmp, manifest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY_CORE_REREGISTER
}

# S2-NEW-05: after a failed verified removal (rc 3), try the narrow
# re-registration (pure content changes only) and retry the verified
# removal once. Returns 0 only when the retry removal succeeds.
_remove_owned_core_family_after_reregister() {
    local srv="$1" rc
    core_family_reregister_changed "$srv" || return 1
    msg "${YELLOW}[!] Re-registered changed ${srv} files (content only); retrying the verified removal.${NC}"
    remove_recorded_core_family "$srv"; rc=$?
    (( rc == 0 ))
}

remove_owned_core_family() {
    # $2 force_heal: only explicit callers (menu 17 / full uninstall) may pass 1.
    # Ambient ABOX_HEAL_MISSING_MANIFEST from the environment is never consulted.
    local srv="$1" force_heal="${2:-0}" path rc core_paths=''
    if ! abox_owns_service "$srv"; then
        if abox_owns_config_only_core_dir "$srv"; then
            # R8-F04-3 (hardening): a config-only residue is not proof of
            # ownership — the old code deleted the whole family tree here
            # without consulting the manifest. Prefer the manifest path;
            # only a truly missing manifest may fall back to the read-only
            # legacy residue precheck (an existing-but-unusable manifest
            # refuses unless an explicit force-heal is in progress), and
            # a modified/malformed manifest refuses outright. A whitelist
            # match is legacy compatibility,
            # not proof that a known file is unmodified.
            remove_recorded_core_family "$srv"; rc=$?
            case "$rc" in
                0) return 0 ;;
                2)
                    if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
                        # Manifest exists but covers nothing usable for this
                        # family (non-compliant path, or no rows for it).
                        # Only an explicit force-heal may fall back to the
                        # whitelist; otherwise refuse.
                        if [[ "$force_heal" != 1 ]]; then
                            msg "${RED}[!] $(tprintf remove_owned_core_family_manifest_unusable "${srv}")${NC}"
                            return 1
                        fi
                    fi
                    core_family_residue_known_only "$srv" || return 1
                    msg "${YELLOW}[!] $(tprintf remove_owned_core_family_no_manifest_legacy "${srv}")${NC}"
                    remove_core_family_force "$srv" || return 1
                    return 0
                    ;;
                3)
                    if [[ "$force_heal" == 1 ]]; then
                        msg "${YELLOW}[!] One or more ${srv} files changed after ownership registration; force-heal is removing the known core-family paths.${NC}"
                        remove_core_family_force "$srv" || return 1
                        return 0
                    fi
                    if [[ "${3:-0}" == 1 ]] && _remove_owned_core_family_after_reregister "$srv"; then
                        return 0
                    fi
                    msg "${RED}[!] $(tprintf remove_owned_core_family_manifest_failed "${srv}")${NC}"
                    return 1
                    ;;
                *)
                    msg "${RED}[!] $(tprintf remove_owned_core_family_manifest_failed "${srv}")${NC}"
                    return 1
                    ;;
            esac
        fi
        if [[ "$force_heal" == 1 ]] && core_family_binary_orphaned "$srv"; then
            msg "${YELLOW}[!] $(tprintf remove_owned_core_family_orphan_binary "${srv}")${NC}"
            remove_core_family_force "$srv" || return 1
            return 0
        fi
        core_paths=$(core_family_paths "$srv") || return 1
        while IFS= read -r path; do [[ -e "$path" || -L "$path" ]] && msg "${YELLOW}[!] Skip non-A-Box path: ${path}${NC}"; done <<< "$core_paths"
        return 0
    fi
    if [[ "$srv" == hysteria && -d /etc/hysteria/acme && ! -L /etc/hysteria/acme ]]; then
        if hysteria_acme_owner_marker_valid /etc/hysteria/acme/.A-Box-managed || hysteria_acme_current_tree_matches_manifest "$ABOX_CORE_OWNERSHIP" /etc/hysteria/acme; then
            prepare_hysteria_acme_dir_ownership || true
            refresh_dynamic_core_subtree_ownership hysteria /etc/hysteria/acme || return 1
            prepare_hysteria_acme_dir_ownership || return 1
        fi
    fi
    remove_recorded_core_family "$srv"; rc=$?
    case "$rc" in
        0) return 0 ;;
        2)
            if [[ "$force_heal" == 1 ]]; then
                msg "${YELLOW}[!] No per-file ownership manifest for ${srv}; performing unit-proven force heal of known core-family paths.${NC}"
                remove_core_family_force "$srv" || return 1
                return 0
            fi
            msg "${YELLOW}[!] No per-file ownership manifest exists for ${srv}; refusing destructive family deletion. Start/restart the managed service once to register exact files.${NC}"
            return 1
            ;;
        3)
            if [[ "$force_heal" == 1 ]]; then
                msg "${YELLOW}[!] One or more ${srv} files changed after ownership registration; force-heal is removing the known core-family paths.${NC}"
                remove_core_family_force "$srv" || return 1
                return 0
            fi
            if [[ "${3:-0}" == 1 ]] && _remove_owned_core_family_after_reregister "$srv"; then
                return 0
            fi
            msg "${RED}[!] One or more ${srv} files changed after ownership registration; they were preserved instead of being deleted.${NC}"
            return 1
            ;;
        *) return 1 ;;
    esac
}

remove_all_owned_core_families() {
    # $1 force_heal forwarded to each family (1 = menu 17 / full uninstall only).
    local force_heal="${1:-0}" failed=0 _hy2_hop_ok=1
    remove_owned_core_family xray "$force_heal" || failed=1
    remove_owned_core_family sing-box "$force_heal" || failed=1
    # L3 (2026-11-27, menu-17 follow-up): a hysteria family removed
    # here never passes through _remove_hy2_official, so reclaim its
    # official-hop NAT rules here, after the caller's stop and before
    # the family removal (same cleanup-first ordering as the prune
    # hook: a failure leaves the unit/config/identity in place for a
    # retry and fails the uninstall instead of reporting success over
    # a residue). Only an A-Box-owned (or config-only) hysteria is
    # cleaned: a foreign install's rules are not ours, and an absent
    # install has no resolvable hop identity.
    if { abox_owns_service hysteria || abox_owns_config_only_core_dir hysteria; }; then
        remove_hy2_official_hop_rules || _hy2_hop_ok=0
    fi
    if (( _hy2_hop_ok == 1 )); then
        remove_owned_core_family hysteria "$force_heal" || failed=1
    else
        failed=1
    fi
    remove_owned_core_family xray-latest "$force_heal" || failed=1
    (( failed == 0 ))
}

# Pre-restore cleanup for backup restore only: a config-only backup (config
# dir present, no unit, no binary) must NOT lose the live binary/unit, so
# its family is left untouched here and restore_core_family_from_backup
# only overwrites paths the backup actually provides. A service absent
# from the backup entirely keeps the old blanket-delete behavior.
remove_owned_core_families_for_restore() {
    local root="$1" srv failed=0 _latest_in_backup_rc=0
    for srv in xray sing-box hysteria; do
        if backup_root_contains_service "$root" "$srv" && backup_root_service_is_config_only "$root" "$srv"; then
            continue
        fi
        # L3 (2026-11-27, menu-17 follow-up): same as the prune hook
        # and remove_all_owned_core_families -- a hysteria family
        # removed here never passes through _remove_hy2_official, so
        # reclaim its official-hop NAT rules after the caller's stop
        # and before the family removal, for hysteria only. A failure
        # skips this family's removal (unit/config/identity stay for
        # a retry) and fails the restore instead of reporting success
        # over a residue. The config-only skip above already ran, so
        # a preserved live family never reaches this cleanup.
        if [[ "$srv" == 'hysteria' ]] && { abox_owns_service hysteria || abox_owns_config_only_core_dir hysteria; }; then
            if ! remove_hy2_official_hop_rules; then
                failed=1
                continue
            fi
        fi
        remove_owned_core_family "$srv" 0 1 || failed=1
    done
    (( failed == 0 ))
}


shortcut_is_abox_managed() {
    local path="${1:-/usr/local/bin/sb}" _mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    # R16-F05-03: content alone must not bless a wrapper: a root:root
    # 0777 or non-root-owned wrapper with the right marker would
    # otherwise be committed as usable, and whoever can write it then
    # gets root code execution. Gate (B): root:root, no group/other
    # write, owner-executable. 0700/0750 history stays managed; only
    # writability by non-root is refused. The content check itself
    # stays in auxiliary_content_is_abox_managed().
    path_owned_by_root "$path" || return 1
    path_mode_has_no_group_other_write "$path" || return 1
    _mode=$(stat -c %a "$path" 2>/dev/null) || return 1
    [[ "$_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$_mode & 8#100) != 0 )) || return 1
    auxiliary_content_is_abox_managed "$path" "$path"
}

remove_abox_shortcut() {
    local path="${1:-/usr/local/bin/sb}"
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    if shortcut_is_abox_managed "$path"; then
        path_tree_has_mountpoint "$path" && { msg "${RED}[!] Refusing to remove mounted A-Box shortcut: ${path}${NC}"; return 1; }
        rm -f -- "$path"
    else
        msg "${YELLOW}[!] Skip non-A-Box shortcut: ${path}${NC}"
    fi
}

# =====================================================================
# Shortcut subsystem (ab/abox rename + custom names).
# Design: central resolver + /etc/ddr/.shortcut state file (F1-B),
# unified change transaction shared by install/upgrade/Toolbox/restore.
# State file format (strict, never sourced/evaluated):
#   # comment lines allowed
#   version=1
#   names=ab abox
#   - version: format version, must be 1.
#   - names: space-separated SET of managed shortcut names
#     (default "ab abox" when no state file exists).
#   - Missing file = no persisted setting yet (defaults apply).
#   - The file is root-owned mode 600, updated atomically.
#   - A migration record ($ABOX_DIR/.shortcut-migrate) tracks an
#     in-flight change: old names, new names, stage, pending cleanup.
#   - The old /usr/local/bin/sb is OUT OF SCOPE for this code: it is
#     never deleted, migrated, tracked, listed, or reported (user
#     decision 2026-11-05; nobody uses it, leaving it is harmless).
# All functions in this block return status instead of dying, so callers
# decide explicitly (install tolerates a shortcut failure; uninstall dies).
# =====================================================================

# Paths derived from ABOX_DIR (default /etc/ddr).
shortcut_state_path() { printf '%s/.shortcut' "${ABOX_DIR:-/etc/ddr}"; }
shortcut_migrate_path() { printf '%s/.shortcut-migrate' "${ABOX_DIR:-/etc/ddr}"; }
shortcut_lock_path() { printf '%s/.shortcut.lock' "${ABOX_DIR:-/etc/ddr}"; }

# Reserved names: core binaries (refused even when not installed, so a
# later core install can never collide) and commands the wrapper itself
# depends on. ab/abox/sb are NOT reserved; they must pass the real
# conflict checks below.
SHORTCUT_RESERVED_NAMES='xray sing-box hysteria bash sh sudo env xray-latest'

# SHORTCUT_ERR: machine-readable reason set by the validators/checkers.
SHORTCUT_ERR=''

# shortcut_validate_name <name>
# Name rule: [A-Za-z][A-Za-z0-9_-]{0,31} (1-32 ASCII chars, first char a
# letter, case-sensitive, no auto-lowercasing), plus the reserved list.
# Returns 0 when valid, 1 otherwise (SHORTCUT_ERR = invalid_syntax /
# reserved / empty).
shortcut_validate_name() {
    local name="${1:-}"
    SHORTCUT_ERR=''
    if [[ -z "$name" ]]; then SHORTCUT_ERR='empty'; return 1; fi
    local _lc_all="${LC_ALL:-}"
    LC_ALL=C
    if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]; then
        LC_ALL="$_lc_all"; SHORTCUT_ERR='invalid_syntax'; return 1
    fi
    LC_ALL="$_lc_all"
    local _r
    for _r in $SHORTCUT_RESERVED_NAMES; do
        if [[ "$name" == "$_r" ]]; then SHORTCUT_ERR='reserved'; return 1; fi
    done
    return 0
}

# shortcut_parse_state_file <file>
# Strictly parses a state file into global SHORTCUT_NAMES. Never sources
# or evaluates file content. Returns 0 on success, 1 when corrupt
# (SHORTCUT_ERR set: bad_type / bad_owner / bad_mode / dup_version /
# bad_version / dup_names / unknown_key / missing_field / empty_names /
# bad_name:<name> / dup_name:<name>). A CRLF-edited file fails cleanly
# (the CR becomes part of the last name and fails validation).
shortcut_parse_state_file() {
    local _file="$1" _version='' _names='' _seen_version=0 _seen_names=0
    SHORTCUT_ERR=''
    # Abnormal file type (symlink, directory, FIFO, ...) is corrupt.
    [[ -f "$_file" && ! -L "$_file" ]] || { SHORTCUT_ERR='bad_type'; return 1; }
    # M-34: the state file is created 0600 root:root (see
    # shortcut_write_state); a drifted mode or owner means this
    # is no longer the file this code wrote, so refuse it
    # fail-closed instead of trusting the names inside it.
    local _owner _mode
    _owner=$(stat -c %u:%g "$_file" 2>/dev/null || echo -1:-1)
    [[ "$_owner" == '0:0' ]] || { SHORTCUT_ERR='bad_owner'; return 1; }
    _mode=$(stat -c %a "$_file" 2>/dev/null || echo 999)
    [[ "$_mode" =~ ^0?600$ ]] || { SHORTCUT_ERR='bad_mode'; return 1; }
    local _line _val
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        case "$_line" in
            ''|'#'*) continue ;;
        esac
        case "$_line" in
            version=*)
                (( _seen_version == 0 )) || { SHORTCUT_ERR='dup_version'; return 1; }
                _seen_version=1; _val="${_line#version=}"
                [[ "$_val" == '1' ]] || { SHORTCUT_ERR='bad_version'; return 1; }
                _version="$_val" ;;
            names=*)
                (( _seen_names == 0 )) || { SHORTCUT_ERR='dup_names'; return 1; }
                _seen_names=1; _val="${_line#names=}"
                _names="$_val" ;;
            *) SHORTCUT_ERR='unknown_key'; return 1 ;;
        esac
    done < "$_file"
    (( _seen_version == 1 && _seen_names == 1 )) || { SHORTCUT_ERR='missing_field'; return 1; }
    # Validate every name in the set; also reject duplicates in the set.
    local _n _seen
    local -a _arr=()
    [[ "$_names" != *$'\n'* ]] || { SHORTCUT_ERR='bad_name:<newline>'; return 1; }
    IFS=$' \t' read -r -a _arr <<< "$_names"
    ((${#_arr[@]} > 0)) || { SHORTCUT_ERR='empty_names'; return 1; }
    _seen=' '
    for _n in "${_arr[@]}"; do
        shortcut_validate_name "$_n" || { SHORTCUT_ERR="bad_name:$_n"; return 1; }
        case "$_seen" in *" $_n "*) SHORTCUT_ERR="dup_name:$_n"; return 1 ;; esac
        _seen="$_seen$_n "
    done
    SHORTCUT_NAMES="$_names"
    return 0
}

# shortcut_read_state
# Parses the live state file into global SHORTCUT_NAMES.
# Returns: 0 = file read (global set); 2 = no file (global = default
# "ab abox"); 1 = corrupt (SHORTCUT_ERR set, global untouched).
shortcut_read_state() {
    local _file
    _file=$(shortcut_state_path)
    SHORTCUT_ERR=''
    if [[ ! -e "$_file" && ! -L "$_file" ]]; then
        SHORTCUT_NAMES='ab abox'; return 2
    fi
    shortcut_parse_state_file "$_file"
}

# shortcut_write_state <names>
# Validates the name set, then atomically writes the state file
# (temp file in the same directory, mode 600, root:root, rename).
# Returns 0 on success, 1 on failure (SHORTCUT_ERR set).
shortcut_write_state() {
    local _names="${1:-}" _file _tmp _n _seen=' '
    local -a _arr=()
    SHORTCUT_ERR=''
    [[ "$_names" != *$'\n'* ]] || { SHORTCUT_ERR='bad_name:<newline>'; return 1; }
    IFS=$' \t' read -r -a _arr <<< "$_names"
    ((${#_arr[@]} > 0)) || { SHORTCUT_ERR='empty_names'; return 1; }
    for _n in "${_arr[@]}"; do
        shortcut_validate_name "$_n" || { SHORTCUT_ERR="bad_name:$_n"; return 1; }
        # R8-F04-4: reject duplicates before any write, mirroring the
        # reader — a duplicated name must never reach the state file.
        case "$_seen" in
            *" $_n "*) SHORTCUT_ERR="dup_name:$_n"; return 1 ;;
        esac
        _seen="$_seen$_n "
    done
    _file=$(shortcut_state_path)
    _tmp=$(umask 077; mktemp "${_file}.XXXXXX" 2>/dev/null) || { SHORTCUT_ERR='mktemp'; return 1; }
    {
        printf '%s\n' '# A-Box shortcut state v1 (do not edit by hand)'
        printf 'version=1\n'
        printf 'names=%s\n' "$_names"
    } > "$_tmp" || { rm -f -- "$_tmp"; SHORTCUT_ERR='write'; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; SHORTCUT_ERR='chmod'; return 1; }
    chown root:root -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; SHORTCUT_ERR='chown'; return 1; }
    # R14-F05-03: refuse a directory target: `mv tmp dir` succeeds
    # by moving the temp file inside the directory and returns 0,
    # while the state path itself stays a (still corrupt) directory.
    [[ ! -d "$_file" ]] || { rm -f -- "$_tmp"; SHORTCUT_ERR='target_is_dir'; return 1; }
    mv -f -- "$_tmp" "$_file" || { rm -f -- "$_tmp"; SHORTCUT_ERR='rename'; return 1; }
    return 0
}

# shortcut_primary_names
# Prints the active name set (state file, or the default "ab abox").
# Never fails on a missing file; on a corrupt file prints the default
# and returns 1 (SHORTCUT_ERR set) so the caller can decide.
shortcut_primary_names() {
    local _rc=0
    shortcut_read_state || _rc=$?
    if (( _rc == 1 )); then printf '%s\n' 'ab abox'; return 1; fi
    printf '%s\n' "$SHORTCUT_NAMES"
    return 0
}

# shortcut_primary_paths
# Prints one /usr/local/bin/<name> line per active name.
shortcut_primary_paths() {
    local _names _n
    _names=$(shortcut_primary_names) || true
    for _n in $_names; do printf '%s\n' "/usr/local/bin/$_n"; done
    return 0
}

# shortcut_managed_paths
# Enumerator for everything this code manages: the primary paths plus
# any names pending cleanup in the migration record (if present and
# parseable). The old /usr/local/bin/sb is deliberately NOT listed.
shortcut_managed_paths() {
    local _p _seen=' '
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        case "$_seen" in *" $_p "*) continue ;; esac
        _seen="$_seen$_p "
        printf '%s\n' "$_p"
    done < <(shortcut_primary_paths)
    local _mfile _line _stage='' _new_vals=''
    _mfile=$(shortcut_migrate_path)
    if [[ -f "$_mfile" && ! -L "$_mfile" ]]; then
        # R15-F05-04: enumerate new= names as well as pending= names. A
        # transaction whose state commit failed leaves its new wrappers
        # installed but uncommitted (record stage 'committed', new=...);
        # reading only pending= orphaned them from backup/cleanup scans.
        # The record writes new= before stage=, so collect first and
        # emit after the stage is known; a 'rolled-back' record's new
        # names were removed again and must not be listed.
        local _pending_vals=''
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            case "$_line" in
                pending=*) _pending_vals="$_pending_vals ${_line#pending=}" ;;
                new=*) _new_vals="$_new_vals ${_line#new=}" ;;
                stage=*) _stage="${_line#stage=}" ;;
            esac
        done < "$_mfile"
        if [[ "$_stage" != 'rolled-back' ]]; then
            _pending_vals="$_pending_vals $_new_vals"
        fi
        local _n
        for _n in $_pending_vals; do
            shortcut_validate_name "$_n" 2>/dev/null || continue
            _p="/usr/local/bin/$_n"
            case "$_seen" in *" $_p "*) continue ;; esac
            _seen="$_seen$_p "
            printf '%s\n' "$_p"
        done
    fi
    return 0
}

# shortcut_is_managed_path <path>
# Returns 0 when the path is one of the currently managed shortcut paths
# (primary set plus any names pending cleanup in the migration record).
shortcut_is_managed_path() {
    local _p _q="$1"
    while IFS= read -r _p; do [[ "$_p" == "$_q" ]] && return 0; done < <(shortcut_managed_paths)
    return 1
}

# shortcut_check_candidate <name>
# The unified 7-step candidate check. Returns 0 = usable, 1 = conflict,
# 2 = invalid. SHORTCUT_ERR carries the machine reason; SHORTCUT_DETAIL
# carries the conflicting path or value for messages.
#   1. name syntax; 2. reserved names; 3. build target /usr/local/bin/<name>;
#   4. target directory entry (absent ok; managed regular file ok; foreign
#      file/dir/FIFO conflict; symlink incl. dangling conflict, never followed);
#   5. command -v + type (resolves to the target managed file itself: ok;
#      anything else: conflict); 6. other same-name executables in PATH,
#      plus explicit /usr/bin/<name> even when /usr/bin is not in PATH;
#   7. (in-lock re-check) is done by the transaction caller, not here.
shortcut_check_candidate() {
    local _name="${1:-}" _target _t _p _dir
    SHORTCUT_ERR=''; SHORTCUT_DETAIL=''
    # Step 1: syntax.
    if ! shortcut_validate_name "$_name"; then
        SHORTCUT_DETAIL="$_name"; return 2
    fi
    # Step 2 is inside shortcut_validate_name (reserved).
    # Step 3: target.
    _target="/usr/local/bin/$_name"
    # Step 4: target directory entry.
    if [[ -L "$_target" ]]; then
        SHORTCUT_ERR='target_symlink'; SHORTCUT_DETAIL="$_target"; return 1
    fi
    if [[ -e "$_target" ]]; then
        if [[ -f "$_target" ]] && shortcut_is_abox_managed "$_target"; then
            : # managed regular file: usable, continue to steps 5-6.
        else
            SHORTCUT_ERR='target_foreign'; SHORTCUT_DETAIL="$_target"; return 1
        fi
    fi
    # Step 5: command resolution in this shell.
    _t=$(type -t "$_name" 2>/dev/null || true)
    case "$_t" in
        '')
            : # not found: continue to step 6.
            ;;
        file)
            _p=$(command -v "$_name" 2>/dev/null || true)
            # R16-F05-05: normalise equivalent spellings before
            # comparing: command -v returns the spelling PATH used,
            # so '/usr/local/bin//' yields a double-slash path.
            while [[ "$_p" == *'//'* ]]; do _p="${_p//\/\//\/}"; done
            if [[ "$_p" != "$_target" ]]; then
                SHORTCUT_ERR='cmd_shadow'; SHORTCUT_DETAIL="$_p"; return 1
            fi
            ;;
        *)
            # alias / function / builtin / keyword would shadow the name.
            SHORTCUT_ERR='cmd_shadow'; SHORTCUT_DETAIL="$_t $_name"; return 1
            ;;
    esac
    # Step 6: other same-name executables in PATH (+ explicit /usr/bin).
    local _seen_dirs=' '
    local _path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    _path="$_path:/usr/bin"
    local _old_ifs="$IFS"
    IFS=':'
    for _dir in $_path; do
        IFS="$_old_ifs"
        [[ -n "$_dir" ]] || _dir='.'
        # R16-F05-05: normalise the spelling before dedup/exclusion:
        # '/usr/local/bin/' and '/usr/local/bin//' are the same
        # directory as '/usr/local/bin'; without this the exclusion
        # below misses and the managed wrapper is misreported as
        # path_shadow (bash resolves // as / when testing -f).
        while [[ "$_dir" == *'//'* ]]; do _dir="${_dir//\/\//\/}"; done
        while [[ "$_dir" != '/' && "$_dir" == */ ]]; do _dir="${_dir%/}"; done
        case "$_seen_dirs" in *" $_dir "*) continue ;; esac
        _seen_dirs="$_seen_dirs$_dir "
        [[ "$_dir" == '/usr/local/bin' ]] && continue
        if [[ -f "$_dir/$_name" && -x "$_dir/$_name" ]]; then
            SHORTCUT_ERR='path_shadow'; SHORTCUT_DETAIL="$_dir/$_name"; return 1
        fi
        IFS=':'
    done
    IFS="$_old_ifs"
    return 0
}

# shortcut_lock_acquire / shortcut_lock_release
# mkdir-type lock (no new flock dependency). The lock directory holds a
# pid file; a lock whose pid is dead or older than 120 seconds is stale
# and may be stolen. Waits up to 30 seconds, then fails (never infinite).
# Sets SHORTCUT_LOCK_HELD=1 while held. Release removes only a lock this
# process owns (pid file matches $$).
# 03a-01: reclaim a shortcut lock dir only if the PID recorded in it
# is STILL the same dead PID when re-read immediately before removing.
# Without the re-read, two reclaimers can both read the old PID and the
# second deletes the first's fresh lock; and an age-only delete kills a
# live holder whose transaction simply ran past 120 s. A missing /
# unreadable PID (holder crashed between mkdir and the pid write) with
# age > 120 is still reclaimable: the caller only passes such an
# expectation from the age branch.
_shortcut_lock_remove_if_pid_still() {
    local _lock="$1" _expect="$2" _cur
    if command -v flock >/dev/null 2>&1; then
        # H3 (R17-M1 = L2, hardening): serialise the re-read + delete
        # under a guard-file flock (flock -n, same idiom as
        # acquire_abox_runtime_guard), so two concurrent reclaimers
        # cannot both pass the re-read and the second delete the
        # first's fresh lock. The guard file lives next to the lock
        # dir and is never deleted (it is the lock inode, like
        # RUNTIME_LOCK). A dynamically allocated fd avoids colliding
        # with the runtime lock's fd 9/10. If the guard cannot be
        # taken (busy or uncreatable) return 1: the caller retries
        # later instead of deleting blind. No flock binary at all
        # falls back to the old unguarded behaviour below.
        local _guard="${_lock}.guard" _gfd=''
        ( exec {_gfd}>>"$_guard" 2>/dev/null || exit 1
          flock -n "$_gfd" 2>/dev/null || exit 1
          _cur=$(cat "$_lock/pid" 2>/dev/null || true)
          [[ "$_cur" == "$_expect" ]] || exit 1
          if [[ "$_expect" =~ ^[0-9]+$ ]]; then
              kill -0 "$_expect" 2>/dev/null && exit 1
          fi
          rm -rf -- "$_lock" 2>/dev/null || true
          exit 0 )
        return $?
    fi
    _cur=$(cat "$_lock/pid" 2>/dev/null || true)
    [[ "$_cur" == "$_expect" ]] || return 1
    if [[ "$_expect" =~ ^[0-9]+$ ]]; then
        kill -0 "$_expect" 2>/dev/null && return 1
    fi
    rm -rf -- "$_lock" 2>/dev/null || true
    return 0
}

shortcut_lock_acquire() {
    local _lock _wait=0 _pid _age _now
    _lock=$(shortcut_lock_path)
    SHORTCUT_ERR=''
    while true; do
        if mkdir -- "$_lock" 2>/dev/null; then
            # R17-M2: the pid write is a precondition of holding the
            # lock, not best-effort: without a readable pid the
            # release cannot remove the dir, and the lock becomes an
            # unreleasable stale entry. Verify the write by reading
            # it back; on any failure remove the fresh dir and fail.
            if printf '%s\n' "$$" > "$_lock/pid" 2>/dev/null && [[ "$(cat "$_lock/pid" 2>/dev/null || true)" == "$$" ]]; then
                SHORTCUT_LOCK_HELD=1
                return 0
            fi
            rm -rf -- "$_lock" 2>/dev/null || true
            SHORTCUT_ERR='pid_write'
            return 1
        fi
        # Lock exists: stale?
        _pid=$(cat "$_lock/pid" 2>/dev/null || true)
        _now=$(date +%s 2>/dev/null || echo 0)
        if [[ "$_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_pid" 2>/dev/null; then
            _shortcut_lock_remove_if_pid_still "$_lock" "$_pid" || true
        fi
        _age=0
        if [[ -n "$_now" && "$_now" =~ ^[0-9]+$ ]]; then
            local _mtime
            _mtime=$(stat -c %Y "$_lock" 2>/dev/null || echo "$_now")
            [[ "$_mtime" =~ ^[0-9]+$ ]] && _age=$(( _now - _mtime ))
        fi
        if (( _age > 120 )); then
            _shortcut_lock_remove_if_pid_still "$_lock" "$_pid" || true
        fi
        if (( _wait >= 60 )); then SHORTCUT_ERR='lock_timeout'; return 1; fi
        sleep 0.5
        _wait=$(( _wait + 1 ))
    done
}

shortcut_lock_release() {
    local _lock _pid
    _lock=$(shortcut_lock_path)
    if [[ "${SHORTCUT_LOCK_HELD:-0}" == 1 ]]; then
        _pid=$(cat "$_lock/pid" 2>/dev/null || true)
        if [[ "$_pid" == "$$" ]]; then rm -rf -- "$_lock" 2>/dev/null || true; fi
        SHORTCUT_LOCK_HELD=0
    fi
    return 0
}

# shortcut_migrate_write <old_names> <new_names> <stage> <pending>
# Writes the migration record (same strict style as the state file).
# Fields: version=1, old=<space names>, new=<space names>, stage=<text>,
# pending=<space names to clean up>. Atomic via temp + rename, 600.
shortcut_migrate_write() {
    local _old="${1:-}" _new="${2:-}" _stage="${3:-}" _pending="${4:-}" _file _tmp
    _file=$(shortcut_migrate_path)
    _tmp=$(umask 077; mktemp "${_file}.XXXXXX" 2>/dev/null) || return 1
    {
        printf '%s\n' '# A-Box shortcut migration record v1 (do not edit by hand)'
        printf 'version=1\n'
        printf 'old=%s\n' "$_old"
        printf 'new=%s\n' "$_new"
        printf 'stage=%s\n' "$_stage"
        printf 'pending=%s\n' "$_pending"
    } > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    chown root:root -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    # R14-F05-03: refuse a directory target: `mv tmp dir` succeeds
    # by moving the temp file inside the directory and returns 0,
    # while the record path itself stays a directory.
    # 03a-02: refuse a symlink target too: `mv -f` would replace the
    # link itself, discarding the pending/new debt recorded in the
    # file it points at.
    [[ ! -d "$_file" && ! -L "$_file" ]] || { rm -f -- "$_tmp"; return 1; }
    mv -f -- "$_tmp" "$_file" || { rm -f -- "$_tmp"; return 1; }
    return 0
}

shortcut_migrate_clear() {
    rm -f -- "$(shortcut_migrate_path)" 2>/dev/null || true
    return 0
}

# shortcut_build_wrapper <tmpfile>
# Writes the wrapper content (same semantics as the current ab/abox wrapper:
# managed marker, root direct exec, sudo fallback, "$@" passthrough).
# Returns 0 on success.
shortcut_build_wrapper() {
    local _tmp="$1" _target
    _target=$(printf '%q' "${ABOX_DIR:-/etc/ddr}/A-Box.sh")
    cat > "$_tmp" <<EOS || return 1
#!/usr/bin/env bash
# Managed by A-Box
if [[ \$EUID -eq 0 ]]; then
    exec bash $_target "\$@"
elif command -v sudo >/dev/null 2>&1; then
    exec sudo bash $_target "\$@"
else
    echo 'Root privileges required. Please run: su -'
    exit 1
fi
EOS
    chmod 755 -- "$_tmp" || return 1
    return 0
}

# shortcut_change_transaction <new-names...>
# The unified change transaction (install / upgrade / Toolbox / restore).
# Steps: read old state -> (caller already interacted, outside the lock)
# -> take lock -> re-read state + re-check candidates -> prepare wrapper
# + new-state temp files -> write migration record -> atomically install
# new wrappers (skip identical content) -> atomically commit new state ->
# clean old managed entries per policy -> clear migration record.
# /usr/local/bin and /etc/ddr are NOT one atomic operation; the rules are:
#  - before state commit: only roll back files THIS transaction created
#    and can still confirm belong to it; old entries stay valid.
#  - after state commit: keep the new entries, keep cleaning up.
#  - cleanup finds an old path replaced by a foreign file: do NOT delete,
#    report it, keep the migration record (pending) and return 2.
# Returns: 0 = full success; 2 = installed + state committed but cleanup
# pending (migration record kept, SHORTCUT_ERR set); 1 = failed.
shortcut_change_transaction() {
    local _new_names="$*" _old_names='' _rc=0 _stage='init'
    local _old_paths='' _n _p _tmp _new_state_tmp
    local -a _arr=()
    SHORTCUT_ERR=''
    [[ "$_new_names" != *$'\n'* ]] || { SHORTCUT_ERR='bad_name:<newline>'; return 1; }
    IFS=$' \t' read -r -a _arr <<< "$_new_names"
    ((${#_arr[@]} > 0)) || { SHORTCUT_ERR='empty_names'; return 1; }
    for _n in "${_arr[@]}"; do
        shortcut_validate_name "$_n" || { SHORTCUT_ERR="bad_name:$_n"; return 1; }
    done
    # C2 (D5): migrate the retired xray-latest name before the strict read.
    shortcut_migrate_legacy_xray_latest || true
    # 1. Read old state (corrupt -> fail closed, never guess).
    shortcut_read_state
    _rc=$?
    if (( _rc == 1 )); then return 1; fi
    _old_names="$SHORTCUT_NAMES"
    # 2-3. Take the lock (interaction already happened outside it).
    shortcut_lock_acquire || return 1
    # 4. Re-read state + re-check candidates inside the lock.
    shortcut_read_state
    _rc=$?
    if (( _rc == 1 )); then shortcut_lock_release; return 1; fi
    if [[ "$SHORTCUT_NAMES" != "$_old_names" ]]; then
        # State moved under us; re-derive the old set and continue with
        # the caller's (already confirmed) new set.
        _old_names="$SHORTCUT_NAMES"
    fi
    for _n in $_new_names; do
        if ! shortcut_check_candidate "$_n"; then
            _rc=$?
            shortcut_lock_release
            SHORTCUT_ERR="recheck:$_n:$SHORTCUT_ERR"
            return 1
        fi
    done
    # 5. Prepare the wrapper temp file (one content for all names).
    _tmp=$(umask 077; mktemp /tmp/A-Box-shortcut.XXXXXX 2>/dev/null) || { shortcut_lock_release; SHORTCUT_ERR='mktemp'; return 1; }
    shortcut_build_wrapper "$_tmp" || { rm -f -- "$_tmp"; shortcut_lock_release; SHORTCUT_ERR='wrapper'; return 1; }
    # 6. Migration record: old names, new names, stage, pending cleanup.
    local _pending=''
    for _n in $_old_names; do
        case " $_new_names " in *" $_n "*) : ;; *) _pending="$_pending$_n " ;; esac
    done
    _pending="${_pending% }"
    # R9 (F05-3): merge the previous record's pending cleanup debt before
    # overwriting it: the writer replaces the record wholesale, so an
    # interrupted earlier transaction's pending names would otherwise be
    # dropped by an empty _pending. Inherit every valid name that is not
    # a new name of this transaction; step 9 re-checks ownership before
    # deleting anything, so foreign or already-gone names stay safe.
    # Any stage qualifies: this record is first written as 'installing',
    # so a stage whitelist would reopen the loss on the next interruption.
    # A record that exists but cannot be read fails closed (old record
    # kept, temp cleaned, lock released).
    local _mfile _mcontent _mline _mval _mn
    _mfile=$(shortcut_migrate_path)
    # 03a-02: a symlinked record is fail-closed, not silently
    # skipped: skipping the merge and then overwriting the link
    # would discard the pending/new debt it points at.
    if [[ -L "$_mfile" ]]; then
        rm -f -- "$_tmp"; shortcut_lock_release; SHORTCUT_ERR='migrate_symlink'; return 1
    fi
    if [[ -f "$_mfile" && ! -L "$_mfile" ]]; then
        # M-34: same owner/mode gate as the state file (the
        # writer creates the record 0600 root:root); a drifted
        # record is refused fail-closed instead of merged into
        # the pending set.
        if [[ "$(stat -c %u:%g "$_mfile" 2>/dev/null || echo -1:-1)" != '0:0' ]] || [[ ! "$(stat -c %a "$_mfile" 2>/dev/null || echo 999)" =~ ^0?600$ ]]; then
            rm -f -- "$_tmp"; shortcut_lock_release; SHORTCUT_ERR='migrate_mode'; return 1
        fi
        _mcontent=$(cat -- "$_mfile" 2>/dev/null) || { rm -f -- "$_tmp"; shortcut_lock_release; SHORTCUT_ERR='migrate_read'; return 1; }
        _pending="$_pending "
        while IFS= read -r _mline || [[ -n "$_mline" ]]; do
            # R14-F05-04: merge uncommitted new= names as well as
            # pending= names. A previous transaction whose state
            # commit failed leaves its new names installed but
            # uncommitted; merging only pending= let the next
            # noop/ensure transaction clear the record and orphan
            # those wrappers. Merged names land in _pending, so
            # step 9 either removes them (managed) or keeps them
            # tracked as blocked (foreign) -- never forgotten.
            case "$_mline" in pending=*) _mval="${_mline#pending=}" ;; new=*) _mval="${_mline#new=}" ;; *) continue ;; esac
            for _mn in $_mval; do
                shortcut_validate_name "$_mn" 2>/dev/null || continue
                case " $_new_names " in *" $_mn "*) continue ;; esac
                case " $_pending " in *" $_mn "*) continue ;; esac
                _pending="$_pending$_mn "
            done
        done <<< "$_mcontent"
        _pending="${_pending% }"
    fi
    shortcut_migrate_write "$_old_names" "$_new_names" 'installing' "$_pending" || { rm -f -- "$_tmp"; shortcut_lock_release; SHORTCUT_ERR='migrate_write'; return 1; }
    # 7. Atomically install new wrappers (skip identical executable
    # content). R9 (F05-4): a content-identical but non-executable wrapper
    # must be reinstalled, not skipped: skipping it left a 0644 wrapper
    # committed as usable.
    # Track which targets this transaction CREATED (did not exist before).
    local _created=''
    for _n in $_new_names; do
        _p="/usr/local/bin/$_n"
        if [[ ! -e "$_p" && ! -L "$_p" ]]; then _created="$_created$_n "; fi
        if [[ -f "$_p" && -x "$_p" ]] && cmp -s "$_tmp" "$_p"; then continue; fi
        if ! install_binary_atomically "$_tmp" "$_p"; then
            # Roll back ONLY files this transaction created and can still
            # confirm belong to it (content matches what we just built).
            local _c _cp
            for _c in $_created; do
                _cp="/usr/local/bin/$_c"
                if [[ -f "$_cp" ]] && cmp -s "$_tmp" "$_cp"; then rm -f -- "$_cp" 2>/dev/null || true; fi
            done
            rm -f -- "$_tmp"
            shortcut_migrate_write "$_old_names" "$_new_names" 'rolled-back' "$_pending" 2>/dev/null || true
            shortcut_lock_release
            SHORTCUT_ERR="install:$_n"; return 1
        fi
    done
    # Verify every new entry before touching the old ones: it must exist,
    # be executable, be a managed regular file, and match the wrapper we
    # just built. R9 (F05-4): the -x check closes the 0644 commit hole.
    local _vtmp
    _vtmp=$(umask 077; mktemp /tmp/A-Box-shortcut.XXXXXX 2>/dev/null) || { shortcut_lock_release; SHORTCUT_ERR='mktemp'; return 1; }
    if ! shortcut_build_wrapper "$_vtmp"; then
        # M-13(2): pre-commit failure must roll back like the
        # install-failure exit above: remove only files this
        # transaction created and can still confirm belong to it,
        # and mark the migration record rolled-back.
        local _c _cp
        for _c in $_created; do
            _cp="/usr/local/bin/$_c"
            if [[ -f "$_cp" ]] && cmp -s "$_tmp" "$_cp"; then rm -f -- "$_cp" 2>/dev/null || true; fi
        done
        rm -f -- "$_tmp" "$_vtmp"
        shortcut_migrate_write "$_old_names" "$_new_names" 'rolled-back' "$_pending" 2>/dev/null || true
        shortcut_lock_release; SHORTCUT_ERR='wrapper'; return 1
    fi
    for _n in $_new_names; do
        _p="/usr/local/bin/$_n"
        if [[ ! -f "$_p" || ! -x "$_p" ]] || ! shortcut_is_abox_managed "$_p" || ! cmp -s "$_vtmp" "$_p"; then
            # M-13(2): pre-commit failure must roll back like the
            # install-failure exit above: remove only files this
            # transaction created and can still confirm belong to it,
            # and mark the migration record rolled-back.
            local _c _cp
            for _c in $_created; do
                _cp="/usr/local/bin/$_c"
                if [[ -f "$_cp" ]] && cmp -s "$_tmp" "$_cp"; then rm -f -- "$_cp" 2>/dev/null || true; fi
            done
            rm -f -- "$_tmp" "$_vtmp"
            shortcut_migrate_write "$_old_names" "$_new_names" 'rolled-back' "$_pending" 2>/dev/null || true
            shortcut_lock_release
            SHORTCUT_ERR="verify:$_n"; return 1
        fi
    done
    rm -f -- "$_tmp" "$_vtmp"
    # 8. Atomically commit the new state.
    shortcut_migrate_write "$_old_names" "$_new_names" 'committed' "$_pending" || { shortcut_lock_release; SHORTCUT_ERR='migrate_write'; return 1; }
    if ! shortcut_write_state "$_new_names"; then
        # State commit failed AFTER wrappers installed: keep the new
        # entries (they are valid), keep the migration record so the
        # next run can reconcile, and report.
        shortcut_lock_release
        SHORTCUT_ERR='state_commit'; return 1
    fi
    # 9. Clean old managed entries that are no longer in the new set.
    local _blocked=''
    for _n in $_pending; do
        _p="/usr/local/bin/$_n"
        if [[ ! -e "$_p" && ! -L "$_p" ]]; then continue; fi
        if shortcut_is_abox_managed "$_p"; then
            if ! remove_abox_shortcut "$_p"; then
                _blocked="$_blocked$_n "
            fi
        else
            # Old path was replaced by a foreign file: never delete.
            _blocked="$_blocked$_n "
        fi
    done
    _blocked="${_blocked% }"
    if [[ -n "$_blocked" ]]; then
        shortcut_migrate_write "$_old_names" "$_new_names" 'cleanup-blocked' "$_blocked" 2>/dev/null || true
        shortcut_lock_release
        # rc 2 already means "cleanup blocked"; SHORTCUT_ERR carries just
        # the blocked names for the message.
        SHORTCUT_ERR="$_blocked"; return 2
    fi
    # 10. Clear the migration record.
    shortcut_migrate_clear
    shortcut_lock_release
    return 0
}

# shortcut_tty_available
# Returns 0 only when /dev/tty can actually be OPENED for read+write.
# (-r/-w tests are not enough: they are true even with no controlling
# terminal, while opening then fails with ENXIO. The open runs in a
# subshell so it can never disturb the caller's file descriptors --
# notably fd 9/10, which the runtime guard uses.)
shortcut_tty_available() {
    ( exec 9<> /dev/tty ) 2>/dev/null
}

# shortcut_resolve_desired <name...>
# Resolves a desired name set to an installable set: each name passes the
# 7-step check; on conflict an interactive session is prompted via /dev/tty
# (replacement or skip), a non-interactive session just skips the name.
# Sets SHORTCUT_RESOLVED (space-separated, deduplicated). Returns 0 when
# the resolved set is non-empty, 1 when empty.
shortcut_resolve_desired() {
    local _name
    SHORTCUT_RESOLVED=''
    for _name in "$@"; do
        if shortcut_check_candidate "$_name"; then
            case " $SHORTCUT_RESOLVED " in *" $_name "*) : ;; *) SHORTCUT_RESOLVED="$SHORTCUT_RESOLVED$_name " ;; esac
        else
            if shortcut_tty_available && shortcut_prompt_conflict "$_name"; then
                if [[ -n "$SHORTCUT_PROMPT_RESULT" ]]; then
                    case " $SHORTCUT_RESOLVED " in *" $SHORTCUT_PROMPT_RESULT "*) : ;; *) SHORTCUT_RESOLVED="$SHORTCUT_RESOLVED$SHORTCUT_PROMPT_RESULT " ;; esac
                fi
                # Empty result = skip this name; keep the existing startup.
            else
                # Non-interactive or input closed: skip, never fail here.
                printf '%s\n' "$(tprintf sc_conflict_detail "$SHORTCUT_DETAIL")" >&2
            fi
        fi
    done
    SHORTCUT_RESOLVED="${SHORTCUT_RESOLVED% }"
    [[ -n "$SHORTCUT_RESOLVED" ]]
}

# shortcut_prompt_conflict <name>
# Interactive conflict resolution for ONE desired name, via /dev/tty
# (never the script's stdin, so piped installs are not disturbed).
# Sets SHORTCUT_PROMPT_RESULT: the other default name, a validated custom
# name, or "" (skip this name). Returns 0 on a decision, 1 when there is
# no usable TTY or the input closed.
shortcut_prompt_conflict() {
    local _name="$1" _alt='abox' _choice _custom
    SHORTCUT_PROMPT_RESULT=''
    shortcut_tty_available || return 1
    [[ "$_name" == 'abox' ]] && _alt='ab'
    printf '%s\n' "$(tprintf sc_prompt_head "$_name" "$SHORTCUT_DETAIL")" > /dev/tty 2>/dev/null || return 1
    printf '%s\n' "$(tprintf sc_prompt_opt1 "$_alt")" > /dev/tty 2>/dev/null || return 1
    printf '%s\n' "$(tr_msg sc_prompt_opt2)" > /dev/tty 2>/dev/null || return 1
    printf '%s\n' "$(tr_msg sc_prompt_opt0)" > /dev/tty 2>/dev/null || return 1
    while true; do
        printf '%s' "$(tr_msg sc_prompt_choice)" > /dev/tty 2>/dev/null || return 1
        IFS= read -r _choice < /dev/tty || return 1
        case "$_choice" in
            1)
                if shortcut_check_candidate "$_alt"; then
                    SHORTCUT_PROMPT_RESULT="$_alt"; return 0
                fi
                printf '%s\n' "$(tprintf sc_conflict_detail "$SHORTCUT_DETAIL")" > /dev/tty
                ;;
            2)
                printf '%s' "$(tr_msg sc_custom_prompt)" > /dev/tty 2>/dev/null || return 1
                IFS= read -r _custom < /dev/tty || return 1
                if ! shortcut_validate_name "$_custom"; then
                    printf '%s\n' "$(tprintf sc_invalid_name "$_custom")" > /dev/tty
                    continue
                fi
                if ! shortcut_check_candidate "$_custom"; then
                    printf '%s\n' "$(tprintf sc_conflict_detail "$SHORTCUT_DETAIL")" > /dev/tty 2>/dev/null || true
                    continue
                fi
                SHORTCUT_PROMPT_RESULT="$_custom"; return 0
                ;;
            0|'')
                SHORTCUT_PROMPT_RESULT=''; return 0
                ;;
            *) continue ;;
        esac
    done
}

# shortcut_ensure
# Ensures the desired shortcut set (state file, or the default "ab abox")
# is installed. Interactive conflicts go through the /dev/tty prompt;
# non-interactive conflicts are skipped (the install never fails over a
# shortcut). A corrupt state file fails closed unless an interactive user
# confirms resetting it to the defaults.
# Returns 0 when at least one shortcut is installed, 1 otherwise. On
# failure it prints the direct launch path; the caller decides whether to
# die (wipe) or continue (menu refresh).
# NOTE on the "keep sb" fallback: the old /usr/local/bin/sb is out of
# scope for this code (user decision 2026-11-05) — it is never installed,
# tracked, or recorded. "Keep sb" in the prompt means "skip the
# conflicting name and leave whatever exists alone"; the state records
# only names this code actually installed. When nothing is installed the
# state file is left unwritten, so the next run prompts again.
# R5-04: reset helper for the confirmed-reset path only. The state is
# re-read INSIDE the lock: another process may have repaired it while
# the user was confirming, and a lock-outside rewrite would clobber
# that valid set. rc 0 = ok/missing (leave alone), 1 = still corrupt.
shortcut_reset_corrupt_state_confirmed() {
    local _rc=0
    shortcut_lock_acquire || return 1
    if shortcut_read_state; then
        _rc=0
    else
        _rc=$?
    fi
    case "$_rc" in
        0|2)
            _rc=0
            ;;
        1)
            if shortcut_write_state 'ab abox'; then
                _rc=0
            else
                _rc=1
            fi
            ;;
        *)
            _rc=1
            ;;
    esac
    shortcut_lock_release
    return "$_rc"
}

# shortcut_migrate_legacy_file <file>
# Strictly parse a shortcut state file, allowing exactly one retired
# token (xray-latest) which is removed; every other rule is the normal
# strict parser's (file type, complete fields, version must be 1,
# unknown keys refused, no duplicate fields, names validated, no
# duplicate names). Returns 0 = migrated (file rewritten), 2 = valid
# and no migration needed (file untouched), 1 = failure (file untouched,
# SHORTCUT_ERR set). The caller must hold the shortcut lock for live
# files; a staged backup copy owned exclusively by the current operation
# needs no live lock.
shortcut_migrate_legacy_file() {
    local _file="${1:-}" _version='' _names='' _seen_version=0 _seen_names=0
    SHORTCUT_ERR=''
    [[ -n "$_file" ]] || { SHORTCUT_ERR='no_file'; return 1; }
    if [[ ! -e "$_file" && ! -L "$_file" ]]; then return 2; fi
    [[ -f "$_file" && ! -L "$_file" ]] || { SHORTCUT_ERR='bad_type'; return 1; }
    # Parent chain must be trusted (no symlink jumps above the file).
    path_parent_chain_safe "$_file" || { SHORTCUT_ERR='bad_parent'; return 1; }
    # R17-C1: the file itself must pass the same owner/mode gate the
    # strict reader enforces (M-34: 0:0 + 0600). The parent chain
    # check above covers ancestors only; without this gate a
    # drifted-but-parseable file naming xray-latest is rewritten
    # root:root 0600 first, laundering untrusted names into the
    # trusted set before the strict read ever sees them.
    local _owner _mode
    _owner=$(stat -c %u:%g "$_file" 2>/dev/null || echo -1:-1)
    [[ "$_owner" == '0:0' ]] || { SHORTCUT_ERR='bad_owner'; return 1; }
    _mode=$(stat -c %a "$_file" 2>/dev/null || echo 999)
    [[ "$_mode" =~ ^0?600$ ]] || { SHORTCUT_ERR='bad_mode'; return 1; }
    local _orig
    _orig=$(cat -- "$_file" 2>/dev/null) || { SHORTCUT_ERR='read'; return 1; }
    local _line _val
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        case "$_line" in
            ''|'#'*) continue ;;
        esac
        case "$_line" in
            version=*)
                (( _seen_version == 0 )) || { SHORTCUT_ERR='dup_version'; return 1; }
                _seen_version=1; _val="${_line#version=}"
                [[ "$_val" == '1' ]] || { SHORTCUT_ERR='bad_version'; return 1; }
                _version="$_val" ;;
            names=*)
                (( _seen_names == 0 )) || { SHORTCUT_ERR='dup_names'; return 1; }
                _seen_names=1; _val="${_line#names=}"
                _names="$_val" ;;
            *) SHORTCUT_ERR='unknown_key'; return 1 ;;
        esac
    done <<< "$_orig"
    (( _seen_version == 1 && _seen_names == 1 )) || { SHORTCUT_ERR='missing_field'; return 1; }
    [[ "$_names" != *$'\n'* ]] || { SHORTCUT_ERR='bad_name:<newline>'; return 1; }
    local -a _arr=()
    IFS=$' \t' read -r -a _arr <<< "$_names"
    ((${#_arr[@]} > 0)) || { SHORTCUT_ERR='empty_names'; return 1; }
    # Duplicate check FIRST (a duplicated legacy token must not mask
    # corruption by being silently deleted).
    local _n _seen=' ' _legacy=0
    for _n in "${_arr[@]}"; do
        case "$_seen" in *" $_n "*) SHORTCUT_ERR="dup_name:$_n"; return 1 ;; esac
        _seen="$_seen$_n "
    done
    # Validate each name; exactly one token, 'xray-latest', may bypass
    # the reserved-name check and is removed instead.
    local -a _kept=()
    for _n in "${_arr[@]}"; do
        if [[ "$_n" == 'xray-latest' ]]; then _legacy=1; continue; fi
        shortcut_validate_name "$_n" || { SHORTCUT_ERR="bad_name:$_n"; return 1; }
        _kept+=("$_n")
    done
    if (( _legacy == 0 )); then return 2; fi
    # Build the migrated set. A legally non-empty set that becomes empty
    # falls back to the default names; an originally empty set is
    # corrupt (already rejected above).
    local _new=''
    if (( ${#_kept[@]} == 0 )); then _new='ab abox'; else _new="${_kept[*]}"; fi
    # Validate the migrated result with the normal strict validator.
    local _chk
    for _chk in $_new; do
        shortcut_validate_name "$_chk" || { SHORTCUT_ERR="bad_name:$_chk"; return 1; }
    done
    # Re-read before commit: if the file changed since the first read,
    # abort without writing (a concurrent writer owns the new content).
    local _now
    _now=$(cat -- "$_file" 2>/dev/null) || { SHORTCUT_ERR='read'; return 1; }
    [[ "$_now" == "$_orig" ]] || { SHORTCUT_ERR='changed'; return 1; }
    # Atomic commit: temp file in the same directory, mode 600,
    # root:root, rename. Clean up the temp file on any failure.
    local _tmp
    _tmp=$(umask 077; mktemp "${_file}.XXXXXX" 2>/dev/null) || { SHORTCUT_ERR='mktemp'; return 1; }
    {
        printf '%s\n' '# A-Box shortcut state v1 (do not edit by hand)'
        printf 'version=1\n'
        printf 'names=%s\n' "$_new"
    } > "$_tmp" || { rm -f -- "$_tmp"; SHORTCUT_ERR='write'; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; SHORTCUT_ERR='chmod'; return 1; }
    chown root:root -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; SHORTCUT_ERR='chown'; return 1; }
    # R14-F05-03: refuse a directory target: `mv tmp dir` succeeds
    # by moving the temp file inside the directory and returns 0,
    # while the state path itself stays a (still corrupt) directory.
    [[ ! -d "$_file" ]] || { rm -f -- "$_tmp"; SHORTCUT_ERR='target_is_dir'; return 1; }
    mv -f -- "$_tmp" "$_file" || { rm -f -- "$_tmp"; SHORTCUT_ERR='rename'; return 1; }
    return 0
}

# shortcut_migrate_legacy_xray_latest
# Live-path wrapper: migrate the retired name out of the live shortcut
# state file. Holds the shortcut lock across read + migrate + commit
# (unless the caller already holds it). Prints the migration notice on
# stderr only when a migration actually happened. Returns 0 = migrated,
# 2 = no migration needed, 1 = failure. Never deletes /usr/local/bin/xray-latest
# (it may be a core binary, not a shortcut wrapper).
shortcut_migrate_legacy_xray_latest() {
    local _file _rc=0 _mine=0
    _file=$(shortcut_state_path)
    if [[ "${SHORTCUT_LOCK_HELD:-0}" != 1 ]]; then
        shortcut_lock_acquire || return 1
        _mine=1
    fi
    shortcut_migrate_legacy_file "$_file"; _rc=$?
    if (( _mine == 1 )); then shortcut_lock_release; fi
    if (( _rc == 0 )); then
        printf '%s\n' "$(tr_msg sc_legacy_xl_migrated)" >&2
    fi
    return "$_rc"
}


shortcut_ensure() {
    local _desired='' _rc=0 _reset_confirmed=0
    SHORTCUT_ERR=''
    # C2 (D5): migrate the retired xray-latest name before the strict read.
    shortcut_migrate_legacy_xray_latest || true
    shortcut_read_state
    _rc=$?
    if (( _rc == 1 )); then
        printf '%s\n' "$(tprintf sc_state_corrupt "$SHORTCUT_ERR")" >&2
        if shortcut_tty_available; then
            local _ans
            printf '%s' "$(tr_msg sc_state_reset_prompt)" > /dev/tty 2>/dev/null || { printf '%s\n' "$(tr_msg sc_none_installed)" >&2; return 1; }
            IFS= read -r _ans < /dev/tty || { printf '%s\n' "$(tr_msg sc_none_installed)" >&2; return 1; }
            case "$_ans" in
                y|Y|yes|YES) _desired='ab abox'; _reset_confirmed=1 ;;
                *) printf '%s\n' "$(tr_msg sc_none_installed)" >&2; return 1 ;;
            esac
        else
            printf '%s\n' "$(tr_msg sc_none_installed)" >&2
            return 1
        fi
    elif (( _rc == 2 )); then
        _desired='ab abox'
    else
        _desired="$SHORTCUT_NAMES"
    fi
    if ! shortcut_resolve_desired $_desired; then
        printf '%s\n' "$(tr_msg sc_none_installed)" >&2
        return 1
    fi
    if (( _reset_confirmed )); then
        if ! shortcut_reset_corrupt_state_confirmed; then
            printf '%s\n' "$(tr_msg sc_none_installed)" >&2
            return 1
        fi
    fi
    shortcut_change_transaction $SHORTCUT_RESOLVED
    _rc=$?
    if (( _rc == 0 )); then
        printf '%s\n' "$(tprintf sc_installed "$SHORTCUT_RESOLVED")" >&2
        return 0
    elif (( _rc == 2 )); then
        printf '%s\n' "$(tprintf sc_cleanup_blocked "$SHORTCUT_ERR")" >&2
        printf '%s\n' "$(tprintf sc_installed "$SHORTCUT_RESOLVED")" >&2
        return 0
    fi
    printf '%s\n' "$(tr_msg sc_none_installed)" >&2
    return 1
}

# shortcut_custom_menu
# Toolbox 17: view the current managed shortcuts, set a custom name
# (replaces the set), reset to the defaults (ab abox, conflicts still go
# through the unified prompt), or remove one managed shortcut (at least
# one must remain). All changes go through shortcut_change_transaction.
# Returns 0 when the user exits normally (0 / EOF).
shortcut_custom_menu() {
    local _names _choice _custom _rc _n _p _i _sel _new
    while true; do
        _names=$(shortcut_primary_names) || true
        printf '%s\n' "$(tr_msg sc_tb_title)" >&2
        printf '%s\n' "$(tprintf sc_tb_current "$_names")" >&2
        for _n in $_names; do
            _p="/usr/local/bin/$_n"
            if [[ -f "$_p" ]] && shortcut_is_abox_managed "$_p"; then
                printf '  %s = %s\n' "$_p" "$(tr_msg sc_st_managed)" >&2
            elif [[ -e "$_p" || -L "$_p" ]]; then
                printf '  %s = %s\n' "$_p" "$(tr_msg sc_st_foreign)" >&2
            else
                printf '  %s = %s\n' "$_p" "$(tr_msg sc_st_missing)" >&2
            fi
        done
        printf '%s\n' "$(tr_msg sc_tb_opt1)" >&2
        printf '%s\n' "$(tr_msg sc_tb_opt2)" >&2
        printf '%s\n' "$(tr_msg sc_tb_opt3)" >&2
        printf '%s\n' "$(tr_msg sc_tb_opt0)" >&2
        printf '%s' "$(tr_msg sc_tb_choice)" >&2
        IFS= read -r _choice || return 0
        _choice=$(normalize_fa_ar_digits "${_choice:-}")
        case "$_choice" in
            1)
                printf '%s' "$(tr_msg sc_custom_prompt)" >&2
                IFS= read -r _custom || continue
                if ! shortcut_validate_name "$_custom"; then
                    printf '%s\n' "$(tprintf sc_invalid_name "$_custom")" >&2; continue
                fi
                if ! shortcut_check_candidate "$_custom"; then
                    printf '%s\n' "$(tprintf sc_conflict_detail "$SHORTCUT_DETAIL")" >&2; continue
                fi
                shortcut_change_transaction "$_custom"
                _rc=$?
                if (( _rc == 0 )); then
                    printf '%s\n' "$(tprintf sc_tb_done "$_custom")" >&2
                elif (( _rc == 2 )); then
                    printf '%s\n' "$(tprintf sc_cleanup_blocked "$SHORTCUT_ERR")" >&2
                    printf '%s\n' "$(tprintf sc_tb_done "$_custom")" >&2
                else
                    printf '%s\n' "$(tprintf sc_tb_fail "$SHORTCUT_ERR")" >&2
                fi
                ;;
            2)
                if ! shortcut_resolve_desired ab abox; then
                    printf '%s\n' "$(tr_msg sc_tb_noop)" >&2; continue
                fi
                # W6-OBS-3: already the default set with every wrapper
                # installed and managed: nothing to do. Previously the
                # transaction re-ran and re-announced completion.
                # Only a readable state counts: a corrupt state also
                # prints the default but must still go through the
                # M-34 heal path below, and missing/foreign wrappers
                # must still be (re)installed by the transaction.
                _names=$(shortcut_primary_names); _rc=$?
                if (( _rc == 0 )) && [[ "$_names" == "$SHORTCUT_RESOLVED" ]]; then
                    local _sc_all_managed=1
                    for _n in $_names; do
                        # shortcut_is_abox_managed already requires a
                        # regular file (plus root ownership, safe mode
                        # and the A-Box marker); no separate -f test.
                        if shortcut_is_abox_managed "/usr/local/bin/$_n"; then
                            :
                        else
                            _sc_all_managed=0; break
                        fi
                    done
                    if (( _sc_all_managed == 1 )); then
                        printf '%s\n' "$(tr_msg sc_tb_noop)" >&2; continue
                    fi
                fi
                # M-34: a corrupt live state makes the transaction
                # fail closed with no menu-reachable recovery;
                # heal it to the default first (the reset is what
                # this option asks for), then run the transaction.
                shortcut_read_state >/dev/null 2>&1
                _rc=$?
                if (( _rc == 1 )); then
                    if ! shortcut_reset_corrupt_state_confirmed; then
                        printf '%s\n' "$(tprintf sc_tb_fail "$SHORTCUT_ERR")" >&2; continue
                    fi
                fi
                shortcut_change_transaction $SHORTCUT_RESOLVED
                _rc=$?
                if (( _rc == 0 )); then
                    printf '%s\n' "$(tprintf sc_tb_done "$SHORTCUT_RESOLVED")" >&2
                elif (( _rc == 2 )); then
                    printf '%s\n' "$(tprintf sc_cleanup_blocked "$SHORTCUT_ERR")" >&2
                    printf '%s\n' "$(tprintf sc_tb_done "$SHORTCUT_RESOLVED")" >&2
                else
                    printf '%s\n' "$(tprintf sc_tb_fail "$SHORTCUT_ERR")" >&2
                fi
                ;;
            3)
                _names=$(shortcut_primary_names) || true
                # At least one shortcut must remain.
                _i=0
                for _n in $_names; do _i=$(( _i + 1 )); done
                if (( _i <= 1 )); then
                    printf '%s\n' "$(tr_msg sc_tb_last)" >&2; continue
                fi
                printf '%s' "$(tr_msg sc_tb_remove_prompt)" >&2
                IFS= read -r _sel || continue
                _new=''
                for _n in $_names; do
                    [[ "$_n" == "$_sel" ]] && continue
                    _new="$_new$_n "
                done
                _new="${_new% }"
                if [[ "$_new" == "$_names" ]]; then
                    printf '%s\n' "$(tprintf sc_tb_notfound "$_sel")" >&2; continue
                fi
                shortcut_change_transaction $_new
                _rc=$?
                if (( _rc == 0 )); then
                    printf '%s\n' "$(tprintf sc_tb_done "$_new")" >&2
                elif (( _rc == 2 )); then
                    printf '%s\n' "$(tprintf sc_cleanup_blocked "$SHORTCUT_ERR")" >&2
                    printf '%s\n' "$(tprintf sc_tb_done "$_new")" >&2
                else
                    printf '%s\n' "$(tprintf sc_tb_fail "$SHORTCUT_ERR")" >&2
                fi
                ;;
            0|'')
                return 0
                ;;
            *)
                continue
                ;;
        esac
    done
}

stop_abox_service() {
    local srv="$1"
    if abox_owns_service "$srv"; then
        service_manager stop "$srv"
    else
        msg "${YELLOW}[!] Skip non-A-Box service: ${srv}${NC}"
        return 0
    fi
}

stop_all_managed_services() {
    local failed=0
    stop_abox_service xray || failed=1
    stop_abox_service sing-box || failed=1
    stop_abox_service hysteria || failed=1
    # R17-M3: xray-latest needs the same service-level stop. Residual
    # pid cleanup alone cannot stop it: with Restart=always the
    # manager relaunches a fresh instance that no longer matches the
    # collected (pid,starttime,exe) identity, so the wait can return
    # 0 while the service is still running. (stop_abox_service is a
    # no-op returning 0 when the service is not A-Box-owned.)
    stop_abox_service xray-latest || failed=1
    kill_managed_residual_pids >/dev/null 2>&1 || failed=1
    (( failed == 0 ))
}

managed_service_pid() {
    local srv="$1" pid='' pidfile='' exe='' owner mode nlink
    if [[ "${INIT_SYS:-}" == 'systemd' ]] && systemd_available; then
        pid=$(systemctl show -p MainPID --value "$srv" 2>/dev/null || true)
        [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] && printf '%s\n' "$pid"
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        case "$srv" in
            xray) pidfile=/run/xray.pid; exe=/usr/local/bin/xray ;;
            sing-box) pidfile=/run/sing-box.pid; exe=/usr/local/bin/sing-box ;;
            hysteria) pidfile=/run/hysteria.pid; exe=/usr/local/bin/hysteria ;;
            xray-latest) pidfile=/run/xray-latest.pid; exe=/usr/local/bin/xray-latest ;;
            *) return 1 ;;
        esac
        [[ -f "$pidfile" && ! -L "$pidfile" ]] || return 1
        [[ "$(stat -c %h "$pidfile" 2>/dev/null)" == 1 ]] || return 1
        owner=$(stat -c %u "$pidfile" 2>/dev/null) || return 1
        [[ "$owner" == 0 ]] || return 1
        mode=$(stat -c %a "$pidfile" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
        pid=$(tr -d '[:space:]' < "$pidfile" 2>/dev/null) || return 1
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 ]] || return 1
        pid_exe_matches "$pid" "$exe" || return 1
        printf '%s\n' "$pid"
    fi
}


pid_exe_matches() {
    local pid="$1" expect="$2" exe
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    # The kernel reports a deleted executable as "<path> (deleted)".
    # Accept the live path and the deleted form; the caller verifies
    # the PID is the managed service's own PID (and, in
    # kill_managed_residual_pids, its starttime), so a deleted suffix
    # alone never authorises a kill.
    [[ "$exe" == "$expect" || "$exe" == "$expect (deleted)" ]]
}

# Process starttime (field 22 of /proc/pid/stat), robust to a comm
# containing spaces or parens: strip through the last ')' then take
# position 20 (field 22 minus pid and comm). Empty output = unreadable.
proc_starttime() {
    local pid="$1" st
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    st=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    st=${st##*) }
    set -- $st
    [[ -n "${20:-}" ]] || return 1
    printf '%s\n' "${20}"
}

kill_managed_residual_pids() {
    local srv pid exe failed=0 i skip_srv="${1:-}" start
    local -a pids=() exes=() starts=()
    for srv in xray sing-box hysteria xray-latest; do
        [[ -n "$skip_srv" && "$srv" == "$skip_srv" ]] && continue
        abox_owns_service "$srv" || continue
        pid=$(managed_service_pid "$srv" 2>/dev/null || true)
        pid=${pid%%$'\n'*}
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 ]] || continue
        case "$srv" in
            xray) exe='/usr/local/bin/xray' ;;
            sing-box) exe='/usr/local/bin/sing-box' ;;
            hysteria) exe='/usr/local/bin/hysteria' ;;
            xray-latest) exe='/usr/local/bin/xray-latest' ;;
            *) continue ;;
        esac
        pid_exe_matches "$pid" "$exe" || continue
        start=$(proc_starttime "$pid" 2>/dev/null || true)
        [[ -n "$start" ]] || continue
        pids+=("$pid")
        exes+=("$exe")
        starts+=("$start")
    done

    (( ${#pids[@]} == 0 )) && return 0

    # Re-verify identity immediately before the first signal: a PID
    # collected above may already have exited and been reused, and the
    # old code's post-TERM re-check could not protect the first signal.
    local -a live=() live_exes=() live_starts=()
    for i in "${!pids[@]}"; do
        pid="${pids[i]}"; exe="${exes[i]}"; start="${starts[i]}"
        if kill -0 "$pid" 2>/dev/null && [[ "$(proc_starttime "$pid" 2>/dev/null || true)" == "$start" ]] && pid_exe_matches "$pid" "$exe"; then
            live+=("$pid"); live_exes+=("$exe"); live_starts+=("$start")
        fi
    done
    (( ${#live[@]} == 0 )) && return 0
    pids=("${live[@]}"); exes=("${live_exes[@]}"); starts=("${live_starts[@]}")

    # Broadcast TERM to the whole managed set before waiting.
    for pid in "${pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 1

    # Re-check identity before escalating (starttime + exe).
    for i in "${!pids[@]}"; do
        pid="${pids[i]}"; exe="${exes[i]}"; start="${starts[i]}"
        if kill -0 "$pid" 2>/dev/null && [[ "$(proc_starttime "$pid" 2>/dev/null || true)" == "$start" ]] && pid_exe_matches "$pid" "$exe"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done

    # SIGKILL is asynchronous: poll (bounded) for the same instances to
    # die instead of judging immediately. Only a same-instance survivor
    # after the timeout is a cleanup failure; a reused PID is ignored.
    local waited=0 still=1
    while (( waited < 50 )); do
        still=0
        for i in "${!pids[@]}"; do
            pid="${pids[i]}"; exe="${exes[i]}"; start="${starts[i]}"
            if kill -0 "$pid" 2>/dev/null && [[ "$(proc_starttime "$pid" 2>/dev/null || true)" == "$start" ]] && pid_exe_matches "$pid" "$exe"; then
                still=1; break
            fi
        done
        (( still == 0 )) && break
        sleep 0.1
        waited=$((waited + 1))
    done
    (( still == 1 )) && failed=1
    return "$failed"
}

is_service_running() {
    local srv=$1 state
    state=$(service_active_state_value "$srv") || return 1
    [[ "$state" == 1 ]]
}

build_status_str() {
    local status_str='' srv state unknown=0 batch_out
    # Perf 2026-10-14: single systemctl call instead of 3x per refresh
    batch_out=$(service_active_states_batch xray sing-box hysteria 2>/dev/null) || batch_out=""
    for srv in xray sing-box hysteria; do
        abox_owns_service "$srv" || continue
        # Try batch result first, fall back to single query
        state=$(grep "^${srv}:" <<< "$batch_out" | cut -d: -f2)
        if [[ -z "$state" ]]; then
            if state=$(service_active_state_value "$srv" 2>/dev/null); then
                : # got it
            else
                unknown=1
                continue
            fi
        fi
        case "$state" in
            1)
                case "$srv" in xray) status_str+="${GREEN}Xray${NC} ";; sing-box) status_str+="${CYAN}Sing-Box${NC} ";; hysteria) status_str+="${GREEN}Hy2${NC} ";; esac
                ;;
            0) ;;
            *) unknown=1 ;;
        esac
    done
    # Menu target look (2026-10-19): stack-state words follow UI language.
    local _w_stopped _w_unknown _w_svc_unknown
    case "${ABOX_LANG:-zh}" in
        en)    _w_stopped='Stopped';              _w_unknown='State Unknown';          _w_svc_unknown='Service State Unknown' ;;
        ru)    _w_stopped='Остановлен';            _w_unknown='Состояние неизвестно';   _w_svc_unknown='Состояние служб неизвестно' ;;
        fa)    _w_stopped='متوقف';                 _w_unknown='وضعیت نامشخص';            _w_svc_unknown='وضعیت سرویس نامشخص' ;;
        zh-tw) _w_stopped='已停止';                _w_unknown='狀態未知';                _w_svc_unknown='服務狀態未知' ;;
        ja)    _w_stopped='停止中';                _w_unknown='状態不明';                _w_svc_unknown='サービス状態不明' ;;
        *)     _w_stopped='已停止';                _w_unknown='状态未知';                _w_svc_unknown='服务状态未知' ;;
    esac
    if [[ -n "$status_str" ]]; then
        (( unknown == 1 )) && status_str+="${YELLOW}${_w_unknown}${NC} "
    elif (( unknown == 1 )); then
        status_str="${YELLOW}${_w_svc_unknown}${NC}"
    else
        status_str="${RED}${_w_stopped}${NC}"
    fi
    printf '%s' "$status_str"
}

managed_services_active() {
    local srv state unknown=0
    for srv in xray sing-box hysteria; do
        abox_owns_service "$srv" || continue
        if state=$(service_active_state_value "$srv" 2>/dev/null); then
            [[ "$state" == '1' ]] && return 0
        else
            unknown=1
        fi
    done
    (( unknown == 0 )) && return 1
    return 2
}


deployment_evidence_exists() {
    [[ -s /usr/local/etc/xray/config.json ]] && return 0
    [[ -s /etc/sing-box/config.json ]] && return 0
    [[ -s /etc/hysteria/config.yaml ]] && return 0
    local _d="${ABOX_DIR:-/etc/ddr}"
    [[ -d "$_d/standalone-links.d" ]] && [[ -n "$(ls -A "$_d/standalone-links.d" 2>/dev/null)" ]] && return 0
    [[ -d "$_d/users.d" ]] && [[ -n "$(ls -A "$_d/users.d" 2>/dev/null)" ]] && return 0
    return 1
}

confirm_deployment_replacement() {
    local next_core="$1" next_mode="$2" answer current="none" active_rc=1 _other_stacks='' _next_norm='' _c='' _answer2=''
    ABOX_PRESERVE_STANDALONE=0
    # M-5: a previous deploy in this process may have recorded drops
    # (ABOX_PRESERVE_DROP_PORTS); a stale value would filter this
    # deploy's snapshot. Drops are collected again below, in
    # pre_install_setup, so reset here and in cleanup.
    ABOX_PRESERVE_DROP_PORTS=''
    export ABOX_PRESERVE_DROP_PORTS
    [[ -n "${CORE:-}" || -n "${MODE:-}" ]] && current="${CORE:-unknown}-${MODE:-unknown}"
    if [[ "$current" == 'none' ]]; then
        # Do not trust ambient globals alone: reload the recorded
        # deployment from .env before deciding this host is fresh.
        load_abox_env "$ABOX_ENV" >/dev/null 2>&1 || true
        [[ -n "${CORE:-}" || -n "${MODE:-}" ]] && current="${CORE:-unknown}-${MODE:-unknown}"
    fi
    if [[ "$current" == 'none' ]]; then
        managed_services_active
        active_rc=$?
        case $active_rc in
            1)
                # No live services. Silent only when the disk also
                # shows no deployment; existing configs, links or
                # user registries always earn a prompt - a stopped
                # or misprobed stack must never be wiped silently.
                if deployment_evidence_exists; then
                    current="$(tr_msg dp_existing)"
                else
                    if abox_is_fast || [[ "${ABOX_QUICK_DEPLOY:-0}" == '1' ]]; then
                        msg "${YELLOW}$(tr_msg dp_fast_skip)${NC}"
                    fi
                    return 0
                fi
                ;;
            0|2) current="$(tr_msg dp_existing)" ;;
            *) return 1 ;;
        esac
    fi
    msg "${YELLOW}[!] $(tr_msg dp_stop_warn)${NC}"
    msg "${YELLOW}[!] $(tr_msg dp_cred_regen)${NC}"
    msg "$(tprintf dp_current "$current" "${next_core}-${next_mode}")"
    # Critical when replacing existing config/services: never auto-yes in fast mode.
    print_port_occupancy
    msg "$(tr_msg dp_choice_overwrite)"
    msg "$(tr_msg dp_choice_preserve)"
    # R14-F05-05: a failed read must refuse, even when it already
    # stored a partial answer (e.g. '1' with no trailing newline,
    # then EOF): only a successful read counts as confirmation.
    read -r -p "$(tr_msg dp_choice_prompt)" answer || { die "$(tr_msg dp_cancelled)"; return 1; }
    answer=$(normalize_fa_ar_digits "${answer:-}")
    case "$answer" in
        2)
            # SYD-B E3: preserve never covered the main stack itself.
            # Choosing it while another main stack is alive used to
            # silently continue into prune, which wipes that stack.
            # List the living other stacks and require a second yes.
            _other_stacks=''
            _next_norm="$next_core"
            [[ "$_next_norm" == singbox ]] && _next_norm='sing-box'
            for _c in xray sing-box hysteria; do
                [[ "$_c" == "$_next_norm" ]] && continue
                if abox_owns_service "$_c" || abox_owns_config_only_core_dir "$_c"; then
                    _other_stacks+="$_c "
                fi
            done
            if [[ -n "$_other_stacks" ]]; then
                msg "${YELLOW}$(tprintf dp_prune_warn "${next_core}-${next_mode}" "${_other_stacks% }")${NC}"
                read -r -p "$(tr_msg dp_prune_confirm)" _answer2 || { die "$(tr_msg dp_cancelled)"; return 1; }
                is_yes "$_answer2" || { die "$(tr_msg dp_cancelled)"; return 1; }
            fi
            ABOX_PRESERVE_STANDALONE=1; msg "${GREEN}$(tr_msg dp_preserve_on)${NC}"
            ;;
        1) ;;
        *) is_yes "$answer" || { die "$(tr_msg dp_cancelled)"; return 1; } ;;
    esac
    export ABOX_PRESERVE_STANDALONE
    return 0
}

standalone_tag_set() { # $1 = core -> standalone inbound tags, one per line
    case "$1" in
        sing-box) printf '%s\n' trojan-landing tuic-in anytls-in shadowtls-in socks5-landing mixed-in socks-in vmess-ws-in vless-ws-in ;;
        xray) printf '%s\n' trojan-landing socks5-landing ;;
        *) return 1 ;;
    esac
}

# R18a-L1: live core configs are JSONC, so strip comments before jq:
# raw jq on a commented config fails silently (2>/dev/null) and the
# inbound ports vanish from this read-only report. Prints TSV rows
# "port<TAB>proto<TAB>tag<TAB>transport" to stdout; transport is
# tcp, udp, or tcp+udp (derived from the inbound type/protocol).
_port_occupancy_config_rows() {
    local cfg="$1" jq_prog="$2"
    [[ -f "$cfg" ]] || return 0
    jsonc_strip_comments "$cfg" 2>/dev/null | jq -r "$jq_prog" 2>/dev/null
}

print_port_occupancy() { # read-only: port -> protocol/owner map
    local any=0 known='' seen_ext='' cfg='' port='' proto='' tag='' _netid='' _local='' _transport=''
    msg "${CYAN}$(tr_msg dp_ports_title)${NC}"
    # R18a-L2: known/seen_ext are keyed "transport:port", not bare
    # port: a configured TCP/443 must not hide another process's
    # UDP/443 (and vice versa).
    # Rows are consumed via mapfile + field splitting, never the read
    # builtin: a caller (or the self-test) may shadow read, and a
    # while-read loop over process substitution would then never see
    # EOF and spin forever (2026-10-22 self-test hang).
    if command -v jq >/dev/null 2>&1; then
        cfg='/etc/sing-box/config.json'
        if [[ -f "$cfg" ]]; then
            local -a _rows=()
            mapfile -t _rows < <(_port_occupancy_config_rows "$cfg" '.inbounds[]? | select(.listen_port != null) | [(.listen_port|tostring), (.type // "?"), (.tag // "-"), ((.type // "?") | if . == "tuic" or . == "hysteria2" or . == "quic" then "udp" elif . == "shadowsocks" then "tcp+udp" else "tcp" end)] | @tsv')
            local _row='' _rest=''
            for _row in "${_rows[@]}"; do
                port="${_row%%$'\t'*}"; _rest="${_row#*$'\t'}"; proto="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"; tag="${_rest%%$'\t'*}"; _transport="${_rest#*$'\t'}"
                [[ -n "$port" ]] || continue
                msg "  ${port} -> ${proto} [${tag}] (sing-box)"
                case "$_transport" in tcp+udp) known+=" tcp:$port udp:$port" ;; *) known+=" $_transport:$port" ;; esac
                any=1
            done
        fi
        cfg='/usr/local/etc/xray/config.json'
        if [[ -f "$cfg" ]]; then
            local -a _rows2=()
            mapfile -t _rows2 < <(_port_occupancy_config_rows "$cfg" '.inbounds[]? | select(.port != null) | [(.port|tostring), (.protocol // "?"), (.tag // "-"), ((.protocol // "?") | if . == "tuic" or . == "hysteria2" or . == "quic" then "udp" elif . == "shadowsocks" then "tcp+udp" else "tcp" end)] | @tsv')
            local _row='' _rest=''
            for _row in "${_rows2[@]}"; do
                port="${_row%%$'\t'*}"; _rest="${_row#*$'\t'}"; proto="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"; tag="${_rest%%$'\t'*}"; _transport="${_rest#*$'\t'}"
                [[ -n "$port" ]] || continue
                msg "  ${port} -> ${proto} [${tag}] (xray)"
                case "$_transport" in tcp+udp) known+=" tcp:$port udp:$port" ;; *) known+=" $_transport:$port" ;; esac
                any=1
            done
        fi
    fi
    if [[ -n "${HY2_BASE_PORT:-}" ]]; then
        msg "  ${HY2_BASE_PORT} -> hysteria2 [hy2-official] (hysteria)"
        known+=" udp:${HY2_BASE_PORT}"; any=1
    fi
    if command -v ss >/dev/null 2>&1; then
        local -a _srows=()
        mapfile -t _srows < <(ss -tulnH 2>/dev/null | awk '{print $1, $5}')
        local _srow=''
        for _srow in "${_srows[@]}"; do
            _netid="${_srow%% *}"
            _local="${_srow#* }"
            port="${_local##*:}"
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            case " $known " in *" ${_netid}:${port} "*) continue ;; esac
            case " $seen_ext " in *" ${_netid}:${port} "*) continue ;; esac
            seen_ext+=" ${_netid}:${port}"
            msg "  ${port}/${_netid} -> $(tr_msg dp_ports_external)"
            any=1
        done
    fi
    [[ "$any" == 1 ]] || msg "  $(tr_msg dp_ports_none)"
    return 0
}

# M-5: apply ABOX_PRESERVE_DROP_PORTS to a JSON array of inbounds
# ($1 -> $2). The parse_range / transport_set / binding / is_dropped
# definitions are the same rule as standalone_preserve_snapshot
# (03b-M1 shared transport rule); a dropped inbound's detour target
# goes with it only when no surviving inbound still references it.
# With no drops recorded the filter is the identity (nothing dropped).
_preserve_apply_drop_ports() { # $1 = in file (JSON array), $2 = out file
    local _in="$1" _out="$2"
    [[ -n "$_in" && -n "$_out" ]] || return 1
    jq --arg drops "${ABOX_PRESERVE_DROP_PORTS:-}" '
            def parse_range:
              if type == "number" then [., .]
              elif type == "string" then
                if test("^[0-9]+$") then [(tonumber), (tonumber)]
                elif test("^[0-9]+-[0-9]+$") then
                  (split("-") | map(tonumber) | if .[0] <= .[1] then . else [.[1], .[0]] end)
                else null end
              else null end;
            # 03b-M1: one transport rule shared by snapshot, restore
            # and the firewall enumeration below. Xray socks listens
            # on UDP exactly when settings.udp is true; Xray
            # shadowsocks and dokodemo-door follow settings.network
            # (default tcp); sing-box shadowsocks follows .network
            # (absent means tcp+udp); any other sing-box inbound
            # with .network set follows it; the rest follow
            # streamSettings.network.
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
            def is_dropped($drop):
              (binding) as $b
              | if $b == null or $b.unparseable then false
                else ([$drop[] | select((.proto as $pr | ($b.transports | index($pr) != null)) and (.port >= $b.range[0] and .port <= $b.range[1]))] | length > 0)
                end;
            ($drops | split(" ") | map(select(. != "")) | map(split(":") | {proto: .[0], port: (.[1] | tonumber)})) as $drop
            | ([.[] | select(is_dropped($drop)) | (.detour // empty)] | map(select(. != ""))) as $dd
            | ([.[] | select(is_dropped($drop) | not) | (.detour // empty)] | map(select(. != ""))) as $still
            | ($dd - $still) as $ddx
            | map(select((is_dropped($drop) | not) and (((.tag // "") as $t | ($ddx | index($t)) == null))))' "$_in" > "$_out" 2>/dev/null
}

standalone_preserve_snapshot() { # $1 = core, $2 = config path
    # Carbon H-11(4): a previous snapshot's /tmp dir is orphaned once
    # this function overwrites ABOX_PRESERVE_DIR below. Reap it first
    # (diagnostics copy, then remove) so a failed earlier deploy cannot
    # leave a plaintext preserve.json behind.
    standalone_preserve_cleanup
    ABOX_PRESERVE_FILE=''
    [[ "${ABOX_PRESERVE_STANDALONE:-0}" == '1' ]] || return 0
    local cfg="$2" pat='' out='' n=0 tmpd=''
    [[ -f "$cfg" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"
        return 1
    fi
    pat=$(standalone_tag_set "$1" | paste -sd'|' -) || return 0
    [[ -n "$pat" ]] || return 0
    # S2-NEW-01: numbered second instances (tag-N) are standalone
    # inbounds too, but the base tag set never names them, so a -2
    # inbound was silently dropped from the snapshot and lost on the
    # next deploy. Match the -N form of every base tag as well (any N,
    # no hardcoded cap); only tags actually present in the live config
    # can match, so this stays live-config-driven. The detour capture
    # below keys off the same match, so a numbered inbound's detour
    # target (e.g. shadowtls-ss-2) is kept as well. Still a single jq
    # pass, so its failure still fail-closes (return 1) as before.
    local patn="^(${pat})-[0-9]+$"
    if ! tmpd=$(mktemp -d /tmp/A-Box-preserve.XXXXXX); then
        msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"
        return 1
    fi
    out="$tmpd/preserve.json"
    # R15C6-01: also capture each preserved inbound's detour target
    # (e.g. shadowtls-in -> shadowtls-ss); snapshotting only the outer
    # inbound makes full restore fail validation on the missing target
    # and the nost retry then drops the node.
    # R16-F05-04: strip JSONC comments before jq: the live config may
    # legally carry // or /* */ comments (the same R14-F01-01 class as
    # the other live-config readers, which all strip first).
    if ! jsonc_strip_comments "$cfg" 2>/dev/null | jq --arg pat "^(${pat})(-[0-9]+)?$" '([.inbounds[]? | select((.tag // "") | test($pat))] | map(.detour // empty)) as $detours | [.inbounds[]? | ((.tag // "") as $t | select(($t | test($pat)) or ($detours | index($t) != null)))]' > "$out" 2>/dev/null; then
        rm -f -- "$out"; rm -rf -- "$tmpd"
        msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"
        return 1
    fi
    # H-26(2): drop inbounds the wizard user explicitly released for a
    # port conflict (ABOX_PRESERVE_DROP_PORTS holds "proto:port"
    # entries). An inbound with an unparseable binding is kept
    # (fail-closed); only an inbound whose transports cover the dropped
    # proto AND whose port range covers the dropped port is filtered
    # out. A dropped inbound's detour target goes with it only when no
    # surviving inbound still references it: a detour shared with a kept
    # inbound survives (it was captured as that inbound's detour too).
    if [[ -n "${ABOX_PRESERVE_DROP_PORTS:-}" ]]; then
        if ! _preserve_apply_drop_ports "$out" "$out.drop"; then
            rm -f -- "$out" "$out.drop"; rm -rf -- "$tmpd"
            msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"
            return 1
        fi
        mv -- "$out.drop" "$out" || { rm -f -- "$out" "$out.drop"; rm -rf -- "$tmpd"; msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"; return 1; }
    fi
    # R18a-M1: an empty snapshot must fail, not silently succeed. jq
    # exits 0 on empty input, so neither the snapshot jq above nor
    # `jq length` here can tell "valid config, zero standalone
    # inbounds" (a legitimate `[]`) from "no JSON was read at all"
    # (empty / whitespace-only / comment-only config). Require the
    # snapshot to hold exactly one JSON array; a legal `[]` still
    # passes and returns 0 below.
    if ! jq -s -e 'length == 1 and (.[0] | type == "array")' "$out" >/dev/null 2>&1; then
        rm -f -- "$out"; rm -rf -- "$tmpd"
        msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"
        return 1
    fi
    n=$(jq 'length' "$out" 2>/dev/null) || { rm -f -- "$out"; rm -rf -- "$tmpd"; msg "${YELLOW}[!] $(tr_msg dp_preserve_snapshot_fail)${NC}"; return 1; }
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        # H-26(1): print what was captured, so a dropped -N variant
        # is visible at snapshot time instead of surfacing as a
        # silent loss at restore time.
        msg "[*] Preserved standalone inbounds ($n): $(jq -r '[.[].tag] | join(", ")' "$out" 2>/dev/null)"
        ABOX_PRESERVE_FILE="$out"
        export ABOX_PRESERVE_FILE
        ABOX_PRESERVE_DIR="$tmpd"
        export ABOX_PRESERVE_DIR
        return 0
    fi
    rm -f -- "$out"; rm -rf -- "$tmpd"
    return 0
}

# Final-round follow-up §2 (worker A): after a same-core preserve
# merge, carry the preserved standalone listener ports into the shell
# variables that write_env() later persists to .env. Without this,
# pre_install_setup/reset_protocol_vars leaves TROJAN_PORT empty and
# write_env() rewrites .env with TROJAN_PORT="" even though the merged
# live config still serves trojan on 8444 (same for SOCKS_PORT /
# socks5-landing) -- so the F-NEW-04 coverage gate, which reads its
# expected ports from .env, goes blind to the preserved protocol.
# Fill-if-empty only: a value already set by the new main stack
# (e.g. MODE=SOCKS sets SOCKS_PORT) is never overwritten. Best-effort
# and never fatal: any extraction/validation failure leaves the
# variable untouched and the deploy continues exactly as before.
# $1 = core (xray|sing-box), $2 = merged config path.
_preserve_sync_env_ports() {
    local _cfg="$2" _tag _var _port
    [[ -f "$_cfg" && ! -L "$_cfg" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    for _tag in trojan-landing socks5-landing; do
        case "$_tag" in
            trojan-landing) _var='TROJAN_PORT' ;;
            socks5-landing) _var='SOCKS_PORT' ;;
        esac
        [[ -z "${!_var:-}" ]] || continue
        _port=$(jsonc_strip_comments "$_cfg" 2>/dev/null | jq -r --arg tag "$_tag" '[.inbounds[]? | select(.tag == $tag) | (.port // .listen_port // empty)] | first // empty' 2>/dev/null) || continue
        [[ -n "$_port" ]] || continue
        valid_canonical_port "$_port" || continue
        declare -g "${_var}=${_port}"
    done
    return 0
}

# Carbon H-11(4): reap a stale/failed preserve dir. A preserve.json
# holds plaintext inbound secrets (SS passwords, Reality private
# keys); it must never survive in /tmp after a failed restore or a
# deployment rollback. The file is first copied to the diagnostics
# dir (mode 600) for forensics, then the /tmp dir is removed either
# way: losing the diagnostic copy is acceptable, leaving the secret
# in /tmp is not. Only paths under /tmp/A-Box-preserve.* are ever
# touched. ABOX_PRESERVE_DIAG_DIR overrides the diagnostics dir
# (test seam). Sets ABOX_PRESERVE_DIAG_SAVED to the saved copy path.
standalone_preserve_cleanup() {
    local _diag_dir="${ABOX_PRESERVE_DIAG_DIR:-/etc/ddr/diagnostics}" _ts=''
    ABOX_PRESERVE_DIAG_SAVED=''
    if [[ -n "${ABOX_PRESERVE_DIR:-}" && "${ABOX_PRESERVE_DIR}" == /tmp/A-Box-preserve.* ]]; then
        if [[ -f "${ABOX_PRESERVE_DIR}/preserve.json" && ! -L "${ABOX_PRESERVE_DIR}/preserve.json" ]]; then
            mkdir -p -- "$_diag_dir" 2>/dev/null || true
            _ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'unknown')-$$
            if cp -a -- "${ABOX_PRESERVE_DIR}/preserve.json" "$_diag_dir/preserve-${_ts}.json" 2>/dev/null && chmod 600 -- "$_diag_dir/preserve-${_ts}.json" 2>/dev/null; then
                ABOX_PRESERVE_DIAG_SAVED="$_diag_dir/preserve-${_ts}.json"
            else
                rm -f -- "$_diag_dir/preserve-${_ts}.json" 2>/dev/null || true
                msg "${YELLOW}[!] preserve diagnostics copy failed; removing plaintext preserve dir without a saved copy.${NC}" >&2 || true
            fi
        fi
        rm -rf -- "$ABOX_PRESERVE_DIR" 2>/dev/null || true
    fi
    ABOX_PRESERVE_FILE=''
    ABOX_PRESERVE_DIR=''
    # M-5: drops belong to one deploy only; a stale value must never
    # survive into the next snapshot/restore in this process.
    ABOX_PRESERVE_DROP_PORTS=''
    export ABOX_PRESERVE_DROP_PORTS
}

standalone_preserve_restore() { # $1 = core, $2 = config path; never dies
    [[ "${ABOX_PRESERVE_STANDALONE:-0}" == '1' ]] || return 0
    [[ -n "${ABOX_PRESERVE_FILE:-}" && -f "${ABOX_PRESERVE_FILE:-}" ]] || return 0
    local cfg="$2" bak='' merged='' keepf='' stripped='' attempt='' ok=0 added=0 dropped='' conflict='' before=0 after=0 tmpd=''
    if ! command -v jq >/dev/null 2>&1; then
        msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'jq')${NC}"
        standalone_preserve_cleanup
        return 1
    fi
    tmpd=$(mktemp -d /tmp/A-Box-preserve.XXXXXX) || { msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'tmp')${NC}"; standalone_preserve_cleanup; return 1; }
    bak="$tmpd/bak.json"
    merged="$tmpd/new.json"
    keepf="$tmpd/keep.json"
    cp -- "$cfg" "$bak" 2>/dev/null || { rm -f -- "$bak" "$merged" "$keepf"; rm -rf -- "$tmpd"; msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'copy')${NC}"; standalone_preserve_cleanup; return 1; }
    # 03b-M2: $bak stays the verbatim backup (a rollback restores the
    # original text, comments included); jq reads a comment-stripped
    # copy instead. The live config may legally carry // or /* */
    # comments, which bare jq rejects -- before this, the merge and
    # the firewall enumeration both read $bak, so the full and nost
    # attempts failed on the same file. A stripped copy that is empty
    # or whitespace-only is unparseable too: fail closed instead of
    # installing an empty merged config.
    stripped="$tmpd/bak-stripped.json"
    if ! jsonc_strip_comments "$cfg" 2>/dev/null > "$stripped" || ! grep -q '[^[:space:]]' "$stripped" 2>/dev/null; then
        rm -f -- "$bak" "$merged" "$keepf" "$stripped"; rm -rf -- "$tmpd"
        msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'copy')${NC}"
        standalone_preserve_cleanup
        return 1
    fi
    for attempt in full nost; do
        if [[ "$attempt" == nost ]]; then
            jq '[.[] | select((.tag // "") | test("^shadowtls-in(-[0-9]+)?$") | not)]' "$ABOX_PRESERVE_FILE" > "$keepf" 2>/dev/null || continue
        else
            cp -- "$ABOX_PRESERVE_FILE" "$keepf" || continue
        fi
        # M-5: drops are collected by pre_install_setup AFTER the
        # snapshot, so the snapshot-time filter never saw them.
        # Apply the same drop filter to this attempt's $keepf so a
        # released inbound is silently excluded instead of
        # surfacing as a restore conflict (dp_preserve_conflict).
        if [[ -n "${ABOX_PRESERVE_DROP_PORTS:-}" ]]; then
            _preserve_apply_drop_ports "$keepf" "$keepf.drop" || continue
            mv -- "$keepf.drop" "$keepf" || continue
        fi
        jq --slurpfile keep "$keepf" '
            def parse_range:
              if type == "number" then [., .]
              elif type == "string" then
                if test("^[0-9]+$") then [(tonumber), (tonumber)]
                elif test("^[0-9]+-[0-9]+$") then
                  (split("-") | map(tonumber) | if .[0] <= .[1] then . else [.[1], .[0]] end)
                else null end
              else null end;
            # 03b-M1: same shared transport rule as the snapshot
            # above and the firewall enumeration below; see there.
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
            # R11-B (R9-3): treat both wildcards as possible cross-family
            # overlaps. Go may bind 0.0.0.0 through a dual-stack socket;
            # its IPv4 spelling does not prove an IPv4-only listener.
            # Apply this conservative address rule to both TCP and UDP.
            # bindings_conflict also requires transport and port overlap.
            # Conflicting restored inbounds are skipped with a warning.
            # Legacy IPv6 parsing helpers below remain unused and are
            # retained to keep this patch within the no-deletion scope.
            def v6_groups($s):
              ($s | test("::")) as $has_dd
              | ($s | split("::")) as $parts
              | ($parts[0] | split(":") | map(select(. != ""))) as $left
              | ((($parts[1] // "") | split(":") | map(select(. != "")))) as $right
              | if $has_dd then
                  $left + ([range(0; (8 - ($left | length) - ($right | length))) | "0"] + $right)
                else ($s | split(":")) end;
            def is_pure_v6($s):
              ($s | type == "string")
              and ($s | test(":"))
              and ($s != "::")
              and ($s | test("^[0-9a-fA-F:]+$"))
              and (($s | split("::") | length) <= 2)
              and (($s | test(":::") | not))
              and (($s | test("^:[^:]") | not))
              and (($s | test("[^:]:$") | not))
              and ((v6_groups($s)) as $g
                   | ($g | length) == 8
                   and ($g | map(test("^[0-9a-fA-F]{1,4}$")) | all)
                   and (($g | map(test("^(0+)$")) | all) | not)
                   and ((($g[0:5] | map(test("^(0+)$")) | all) and (($g[5] | ascii_downcase) == "ffff")) | not));
            def addr_overlap($a; $b):
              ($a == $b)
              or ($a == "0.0.0.0")
              or ($b == "0.0.0.0")
              or ($a == "::")
              or ($b == "::");
            def range_overlap($r1; $r2):
              ($r1[0] <= $r2[1]) and ($r2[0] <= $r1[1]);
            def bindings_conflict($x; $y):
              if $x.unparseable then true
              elif $y.unparseable then true
              else
                (addr_overlap($x.addr; $y.addr)
                 and ([$x.transports[], $y.transports[]] | unique | length) < (($x.transports | length) + ($y.transports | length))
                 and range_overlap($x.range; $y.range))
              end;
            (.inbounds // []) as $cur
            | ($cur | map(binding) | map(select(. != null))) as $cur_bindings
            | ($cur | map(.tag)) as $cur_tags
            | [$keep[0][] | select(
                (.tag as $t | ($cur_tags | index($t)) == null)
                and ((binding) as $b | $b == null or ([$cur_bindings[] | select(bindings_conflict($b; .))] | length == 0))
              )] as $add1
            # Carbon H-11(2): a port-less inbound is only a detour
            # target (e.g. shadowtls-ss); keep it only when its detour
            # source survived into $add1, otherwise it is an orphan
            # that inflates the added count and serves nothing.
            | ([$add1[] | .detour // empty] | unique) as $dt
            | [$add1[] | select(if (binding) == null then (.tag as $t | ($dt | index($t)) != null) else true end)] as $add
            | .inbounds = ($cur + $add)' "$stripped" > "$merged" 2>/dev/null || continue
        jq empty "$merged" >/dev/null 2>&1 || continue
        install_file_atomically "$merged" "$cfg" 600 || continue
        case "$1" in
            xray) /usr/local/bin/xray run -test -config "$cfg" >/dev/null 2>&1 && ok=1 ;;
            sing-box) /usr/local/bin/sing-box check -c "$cfg" >/dev/null 2>&1 && ok=1 ;;
            *) ok=1 ;;
        esac
        if (( ok == 1 )); then break; fi
        cp -- "$bak" "$cfg" 2>/dev/null || true
        chmod 600 "$cfg" 2>/dev/null || true
    done
    if (( ok == 1 )); then
        before=$(jq '.inbounds | length' "$stripped" 2>/dev/null || printf '0')
        after=$(jq '.inbounds | length' "$cfg" 2>/dev/null || printf '0')
        added=$(( after - before ))
        # M-5: count drops against the post-drop-filter candidate
        # set, so a user-released inbound is not reported as a
        # conflict; the nost-attempt shadowtls exclusion is
        # unaffected (the drop filter never removes shadowtls).
        local _drop_src="$ABOX_PRESERVE_FILE"
        if [[ -n "${ABOX_PRESERVE_DROP_PORTS:-}" ]] && _preserve_apply_drop_ports "$ABOX_PRESERVE_FILE" "$tmpd/drop-keep.json" 2>/dev/null; then
            _drop_src="$tmpd/drop-keep.json"
        fi
        dropped=$(jq -r --slurpfile now "$cfg" '[.[] | select(.tag as $t | ($now[0].inbounds | map(.tag) | index($t)) == null) | .tag] | join(", ")' "$_drop_src" 2>/dev/null || printf '')
        if (( added > 0 )); then msg "${GREEN}$(tprintf dp_preserve_ok "$added")${NC}"; fi
        if [[ -n "$dropped" ]]; then msg "${YELLOW}[!] $(tprintf dp_preserve_conflict "$dropped")${NC}"; fi
        conflict=$(jq -r --slurpfile now "$cfg" '[.[] | select(.tag != null) | .tag as $t | (($now[0].inbounds // [])[] | select(.tag == $t)) as $cur | select($cur != null and . != $cur) | .tag] | unique | join(", ")' "$ABOX_PRESERVE_FILE" 2>/dev/null || printf '')
        if [[ -n "$conflict" ]]; then msg "${YELLOW}[!] $(tprintf dp_preserve_conflict_tag "$conflict")${NC}"; fi
        # Carbon H-11(1): the deploy wiped the firewall rules before
        # this restore and pre_install_setup only re-opens the main
        # protocol ports. Re-open the ports of the inbounds this
        # restore just added, before the service starts. allowPort
        # dies on failure, so it runs in a subshell; any failure
        # restores $bak and fails the restore (check-fail semantics).
        # Port enumeration mirrors core_expected_listen_ports: Xray
        # socks is tcp+udp exactly when settings.udp is true, SS
        # follows settings.network, the rest follow transport_set.
        if (( added > 0 )); then
            local _fw_ports='' _fw_failed=0 _fw_spec='' _fw_proto='' _fw_port=''
            _fw_ports=$(jq -r --slurpfile bak "$stripped" '
            # 03b-M1: same shared transport rule as snapshot/restore
            # above (renamed from `transports` so the three defs
            # stay textually identical).
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
            [.inbounds[]? | select(.tag as $t | (($bak[0].inbounds // []) | map(.tag) | index($t)) == null)
             | select(.tag != "api")
             | select(.listen == null or (.listen != "127.0.0.1" and .listen != "::1"))
             | select((.port // .listen_port) != null)
             | (transport_set) as $trs
             | ((.port // .listen_port) | tostring | split(",")) as $ps
             | $ps[] as $p | $trs[] | "\(.)/\($p)"] | unique | .[]' "$cfg" 2>/dev/null) || _fw_failed=1
            if (( _fw_failed == 0 )); then
                while IFS= read -r _fw_spec; do
                    [[ -n "$_fw_spec" ]] || continue
                    _fw_proto="${_fw_spec%%/*}"; _fw_port="${_fw_spec#*/}"
                    ( allowPort "$_fw_port" "$_fw_proto" ) || _fw_failed=1
                done <<< "$_fw_ports"
            fi
            if (( _fw_failed == 0 )); then
                ( save_firewall_rules ) || _fw_failed=1
            fi
            if (( _fw_failed == 1 )); then
                if cp -- "$bak" "$cfg" 2>/dev/null && chmod 600 "$cfg" 2>/dev/null; then
                    msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'check')${NC}"
                    rm -f -- "$bak" "$merged" "$keepf" "$stripped"; rm -rf -- "$tmpd"
                    standalone_preserve_cleanup
                    return 1
                else
                    msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'rollback')${NC}"
                    standalone_preserve_cleanup
                    msg "${YELLOW}[!] backup preserved: $bak ; preserve diagnostics: ${ABOX_PRESERVE_DIAG_SAVED:-unavailable}${NC}"
                    return 1
                fi
            fi
        fi
        # H4 (R18a-X1 residual, hardening): sync preserved standalone
        # ports into the shell vars write_env() persists ONLY after
        # the firewall stage succeeded -- the sync has no data
        # dependency on the firewall stage, so the success path is
        # unchanged, and a firewall failure now leaves no residue in
        # TROJAN_PORT/SOCKS_PORT (both failure exits above return
        # before reaching this line).
        _preserve_sync_env_ports "$1" "$cfg" || true
    else
        if cp -- "$bak" "$cfg" 2>/dev/null && chmod 600 "$cfg" 2>/dev/null; then
            msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'check')${NC}"
            rm -f -- "$bak" "$merged" "$keepf" "$stripped"; rm -rf -- "$tmpd"
            standalone_preserve_cleanup
            return 1
        else
            msg "${YELLOW}[!] $(tprintf dp_preserve_fail 'rollback')${NC}"
            standalone_preserve_cleanup
            msg "${YELLOW}[!] backup preserved: $bak ; preserve diagnostics: ${ABOX_PRESERVE_DIAG_SAVED:-unavailable}${NC}"
            return 1
        fi
    fi
    rm -f -- "$bak" "$merged" "$keepf" "$stripped" "$ABOX_PRESERVE_FILE"
    rm -rf -- "$tmpd"
    [[ -n "${ABOX_PRESERVE_DIR:-}" ]] && rm -rf -- "$ABOX_PRESERVE_DIR"
    ABOX_PRESERVE_FILE=''
    ABOX_PRESERVE_DIR=''
    return 0
}

service_report_state() {
    local srv="$1" unit state
    if abox_owns_service "$srv"; then
        if state=$(service_active_state_value "$srv" 2>/dev/null); then
            case "$state" in
                1) printf 'active\n' ;;
                0) printf 'inactive\n' ;;
                *) printf 'unknown\n' ;;
            esac
        else
            printf 'unknown\n'
        fi
        return 0
    fi
    unit=$(same_name_service_unit_path "$srv" 2>/dev/null || true)
    if [[ -n "$unit" ]]; then printf 'foreign/unmanaged\n'; else printf 'absent\n'; fi
}

show_status_report() {
    local init='unknown' xray_state sing_state hy2_state shortcut_state='' desired='UNINITIALIZED' period='' config_loaded=0
    local _status_lock_held=0 _status_stderr_saved=''
    # Best-effort non-blocking exclusive snapshot lock; proceed unlocked if busy.
    if [[ ${EUID:-0} -eq 0 ]] && command -v flock >/dev/null 2>&1 && [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        # Save stderr first: the bare exec below would otherwise
        # redirect stderr to /dev/null for the rest of the process.
        # If the save itself fails, skip the lock and stay unlocked.
        if exec {_status_stderr_saved}>&2; then
            exec 8>>"$LOCK_FILE" 2>/dev/null || true
            # Shared advisory snapshot; does not block writers that hold exclusive fd 9.
            if flock -s -n 8 2>/dev/null; then _status_lock_held=1; fi
        fi
    fi
    clear_abox_env_vars
    if load_abox_env "$ABOX_ENV" 2>/dev/null; then config_loaded=1; fi
    if systemd_available; then INIT_SYS='systemd'; init='systemd'; elif command -v rc-service >/dev/null 2>&1; then INIT_SYS='openrc'; init='openrc'; fi
    xray_state=$(service_report_state xray)
    sing_state=$(service_report_state sing-box)
    hy2_state=$(service_report_state hysteria)
    local _sc_path='' _sc_state=''
    while IFS= read -r _sc_path; do
        if [[ -e "$_sc_path" || -L "$_sc_path" ]]; then
            if shortcut_is_abox_managed "$_sc_path"; then _sc_state='managed'; else _sc_state='foreign/unmanaged'; fi
        else
            _sc_state='missing'
        fi
        shortcut_state+="$_sc_path=$_sc_state "
    done < <(shortcut_primary_paths)
    shortcut_state="${shortcut_state% }"
    [[ -n "$shortcut_state" ]] || shortcut_state='missing'
    if (( config_loaded == 1 )) || [[ -e "$ABOX_DESIRED_STATE" || -L "$ABOX_DESIRED_STATE" ]] || abox_owns_service xray || abox_owns_service sing-box || abox_owns_service hysteria; then
        desired=$(get_desired_state 2>/dev/null || printf 'invalid')
    fi
    period=$(get_traffic_block_period 2>/dev/null || true)
    cat <<EOF_STATUS
A-Box status
Build: ${ABOX_BUILD} (${ABOX_BUILD_EPOCH})
IP preference: $(read_ip_pref 2>/dev/null || echo dual)
Init: ${init}
Config: CORE=${CORE:-} MODE=${MODE:-}
Desired state: ${desired}${period:+ (traffic period ${period})}
Services: xray=${xray_state} sing-box=${sing_state} hysteria=${hy2_state}
Shortcut: ${shortcut_state}
Config file: ${ABOX_ENV}
EOF_STATUS
    if [[ -n "$_status_stderr_saved" ]]; then
        if (( _status_lock_held == 1 )); then
            flock -u 8 2>/dev/null || true
        fi
        eval "exec 8>&-" 2>/dev/null || true
        # Restore the saved stderr (also covers the flock-failure
        # path, where fd 8 was opened but never locked).
        exec 2>&${_status_stderr_saved} || true
        exec {_status_stderr_saved}>&- || true
    fi
}

firewall_snapshot_is_abox_managed() {
    local file="${1:-}"
    firewall_state_file_safe "$file" || return 1
    grep -q '^\*' "$file" || return 1
    grep -q '^COMMIT$' "$file" || return 1
    awk '
      /^\*[^ \t\r]+$/ {table=$0; next}
      /^COMMIT$/ {table=""; next}
      /^:INPUT[ \t]+(ACCEPT|DROP)([ \t]+\[[0-9]+:[0-9]+\])?[ \t]*$/ {
        if (table!="*filter" || ++input_seen > 1) exit 1
        next
      }
      /^-A[ \t\r]/ && /--comment[ \t\r]+"?A-Box-/ {next}
      {exit 1}
    ' "$file"
}

remove_abox_firewall_persistence() {
    local fw_file enabled_state rc_update
    # Complete ownership preflight before any destructive service/file operation.
    for fw_file in "$ABOX_DIR/firewall_restore.sh" "$ABOX_DIR/iptables.v4" "$ABOX_DIR/iptables.v6"; do
        [[ -e "$fw_file" || -L "$fw_file" ]] || continue
        case "$fw_file" in
            "$ABOX_DIR/firewall_restore.sh") auxiliary_content_is_abox_managed "$fw_file" /etc/ddr/firewall_restore.sh || return 1 ;;
            *) firewall_snapshot_is_abox_managed "$fw_file" || return 1 ;;
        esac
    done

    if [[ -e /etc/systemd/system/A-Box-firewall.service || -L /etc/systemd/system/A-Box-firewall.service ]]; then
        [[ -f /etc/systemd/system/A-Box-firewall.service && ! -L /etc/systemd/system/A-Box-firewall.service ]] || return 1
        grep -Fxq '# Managed by A-Box' /etc/systemd/system/A-Box-firewall.service 2>/dev/null || return 1
        systemd_available || return 1
        systemctl disable --now A-Box-firewall.service >/dev/null 2>&1 || return 1
        [[ "$(service_active_state_value A-Box-firewall.service 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
        enabled_state=$(systemctl show -p UnitFileState --value A-Box-firewall.service 2>/dev/null) || return 1
        [[ "$enabled_state" == disabled ]] || return 1
        rm -f -- /etc/systemd/system/A-Box-firewall.service || return 1
        [[ ! -e /etc/systemd/system/A-Box-firewall.service && ! -L /etc/systemd/system/A-Box-firewall.service ]] || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
    fi

    if [[ -e /etc/init.d/A-Box-firewall || -L /etc/init.d/A-Box-firewall ]]; then
        [[ -f /etc/init.d/A-Box-firewall && ! -L /etc/init.d/A-Box-firewall ]] || return 1
        grep -Fxq '# Managed by A-Box' /etc/init.d/A-Box-firewall 2>/dev/null || return 1
        command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 || return 1
        rc-service A-Box-firewall stop >/dev/null 2>&1 || true
        [[ "$(service_active_state_value A-Box-firewall 2>/dev/null || printf '%s' unknown)" == 0 ]] || return 1
        if rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])A-Box-firewall([[:space:]]|$)'; then
            rc-update del A-Box-firewall default >/dev/null 2>&1 || return 1
        fi
        rc_update=$(rc-update show default 2>/dev/null) || return 1
        grep -Eq '(^|[[:space:]])A-Box-firewall([[:space:]]|$)' <<< "$rc_update" && return 1
        rm -f -- /etc/init.d/A-Box-firewall || return 1
        [[ ! -e /etc/init.d/A-Box-firewall && ! -L /etc/init.d/A-Box-firewall ]] || return 1
    fi

    # Recovery script and snapshots remain present until all owning services are
    # confirmed inactive and disabled. A failure above leaves them intact.
    rm -f -- "$ABOX_DIR/firewall_restore.sh" "$ABOX_DIR/iptables.v4" "$ABOX_DIR/iptables.v6" || return 1
    [[ ! -e "$ABOX_DIR/firewall_restore.sh" && ! -e "$ABOX_DIR/iptables.v4" && ! -e "$ABOX_DIR/iptables.v6" ]]
}

write_abox_firewall_restore_script() {
    local tmp target="$ABOX_DIR/firewall_restore.sh" uid gid mode
    install -d -m 711 "$ABOX_DIR" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] || return 1
        uid=$(stat -c %u "$target" 2>/dev/null) || return 1
        gid=$(stat -c %g "$target" 2>/dev/null) || return 1
        mode=$(stat -c %a "$target" 2>/dev/null) || return 1
        [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#077) == 0 )) || return 1
        grep -Fxq '# Managed by A-Box' "$target" 2>/dev/null || return 1
    fi
    tmp=$(mktemp "$ABOX_DIR/.firewall_restore.XXXXXX") || return 1
    cat > "$tmp" <<'EOF_ABOX_FW_RESTORE'
#!/usr/bin/env bash
# Managed by A-Box
# A-06: umask 077 ensures lock/temp files are 0600 (not world-readable 0644).
umask 077
set -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
read_ip_pref() {
    local pref='dual' mode
    local pref_file="$(dirname "$0")/.ip-pref"
    if [[ -r "$pref_file" && -f "$pref_file" && ! -L "$pref_file" && "$(stat -c %u:%g "$pref_file" 2>/dev/null || true)" == '0:0' ]]; then
        mode=$(stat -c %a "$pref_file" 2>/dev/null) || mode='777'
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )); then
            pref=$(tr -d '[:space:]' < "$pref_file" 2>/dev/null || true)
        fi
    fi
    [[ "$pref" =~ ^(ipv4|ipv6|dual)$ ]] || pref='dual'
    printf '%s\n' "$pref"
}
has_ipv6() {
    local _pref
    _pref=$(read_ip_pref 2>/dev/null || printf 'dual')
    [[ "$_pref" == 'ipv4' ]] && return 1
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { found=1 } END { exit !found }' && return 0
    ip -6 route show default 2>/dev/null | awk '/^default/ { found=1 } END { exit !found }' && return 0
    return 1
}
# Objective IPv6 usability check (not preference-aware).
# Used by clean_chain for N-04 "never silently skip IPv6" intent.
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
clean_chain() {
    local cmd="$1" table="$2" chain="$3" output rule
    local owned_re='--comment "?A-Box-(HY2-HOP|[0-9]+(:[0-9]+)?-(tcp|udp)(-(WL6?|DROP6?))?)(:A-Box-tmp-[0-9]+-[0-9]+)?"?([ \t\r]|$)'
    local -a argv=()
    if ! command -v "$cmd" >/dev/null 2>&1; then
        # N-04: use objective host_has_usable_ipv6 (not preference-aware has_ipv6)
        # to match enforce_ss_whitelist_order's "never silently skip IPv6" intent.
        [[ "${cmd##*/}" == ip6tables ]] && ! host_has_usable_ipv6 && return 0
        return 1
    fi
    while :; do
        if ! output=$(_iptables_q "$cmd" -t "$table" -S "$chain" 2>/dev/null); then
            if [[ "$table" == nat ]]; then
                local _nat_err
                _nat_err=$(_iptables_q "$cmd" -t "$table" -S "$chain" 2>&1 >/dev/null || true)
                # R15-F05-07: "can't/cannot initialize" is NOT a
                # not-supported signal: iptables-legacy reports the same
                # text for permission errors ("Permission denied (you
                # must be root)"), which used to be misread as "no NAT
                # table" and returned success without reading or
                # cleaning any rule. A genuinely missing table says
                # "Table does not exist", already matched above, so
                # dropping the initialize alternatives only turns the
                # permission case from false success into failure.
                if printf '%s\n' "$_nat_err" | grep -qiE "table .* does not exist|table does not exist|table nat is not supported|protocol not supported"; then
                    return 0
                fi
            fi
            return 1
        fi
        rule=$(awk -v re="$owned_re" '$0 ~ re { sub(/^-A /,"-D "); print; exit }' <<< "$output")
        [[ -n "$rule" ]] || break
        rule=${rule//\"/}
        read -r -a argv <<< "$rule"
        _iptables_do "$cmd" -t "$table" "${argv[@]}" >/dev/null 2>&1 || return 1
    done
}
restore_one() {
    local file="$1" cmd="$2"
    [[ -s "$file" ]] || return 1
    command -v "$cmd" >/dev/null 2>&1 || return 1
    grep -q '^\*' "$file" || return 1
    "$cmd" -w --noflush < "$file" >/dev/null 2>&1 || "$cmd" --noflush < "$file" >/dev/null 2>&1
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
# BUG-28: hoisted from reorder_one()/reorder_ss_whitelist_rules_one().
# $1 = lock fd value. Closes it; caller clears its own lock_fd variable.
__abox_firewall_unlock() {
    local lock_fd="$1"
    # Guard empty lock_fd: `exec >&-` would close stdout.
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        eval "exec ${lock_fd}>&-" 2>/dev/null || true
    fi
}
__abox_normalize_managed_rule_line() {
    local line="$1"
    line=${line//\"/}
    # H-12: no backreferences in ERE (musl treats \3 as literal '3');
    # one plain -e per protocol instead of a shared \3 group.
    line=$(printf '%s\n' "$line" | sed -E -e 's/(^|[[:space:]])-p[[:space:]]+tcp[[:space:]]+-m[[:space:]]+tcp([[:space:]]|$)/\1-p tcp\2/' -e 's/(^|[[:space:]])-p[[:space:]]+udp[[:space:]]+-m[[:space:]]+udp([[:space:]]|$)/\1-p udp\2/')
    printf '%s\n' "$line"
}
reorder_one() {
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
    local -a rules=() argv=() current_lines=() delete_lines=() delete_target_indices=() delete_rule_numbers=()
    local -A _rules_seen=()
    local _stripped_rule=''
    local -a original_target_lines=() original_target_positions=() expected_target_lines=()
    local -a current_target_lines=() current_foreign_lines=() original_foreign_rules=()

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

# C04: plain ACCEPT rules (allowPort comments without a suffix)
# are invisible to reorder_policy's DROP-pair scan. When a
# foreign unconditional DROP/REJECT terminates INPUT, a
# --noflush-appended plain ACCEPT lands after it and is
# unreachable, yet restore reports success. Move each such
# ACCEPT before the first terminal rule.
reorder_plain_accepts() {
    local cmd="$1" line terminal_idx accept_idx i spec rule_no iter accept_line_idx max_moves _qout _rc=0
    local _fresh='' _fline='' _frule_no=0 _spec=''
    local -A _seen_before=()
    local lock_file=/run/A-Box-firewall-reorder.lock lock_fd=''
    local -a lines=() argv=()
    command -v "$cmd" >/dev/null 2>&1 || return 0
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
    iter=0; max_moves=-1
    while :; do
        iter=$((iter + 1))
        lines=()
        # R9 (F05-6): capture the query output first and propagate its
        # exit code. The old process-substitution form took the while
        # loop's status, so a failing query with no output silently
        # yielded an empty snapshot and a success return. The non-empty
        # guard keeps zero-byte output as zero lines (no phantom empty
        # line inflating max_moves).
        _qout=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || { _rc=1; break; }
        if [[ -n "$_qout" ]]; then
            while IFS= read -r line; do
                lines+=("$line")
            done <<< "$_qout" || { _rc=1; break; }
        fi
        # R5-08: bound the loop on the FIRST snapshot's size: each
        # pass moves one ACCEPT before the terminal rule, so more
        # passes than rules + 1 means no progress. A per-pass re-read
        # count would let a growing chain push the bound up forever.
        (( max_moves < 0 )) && max_moves=${#lines[@]}
        (( iter <= max_moves + 1 )) || { _rc=1; break; }
        terminal_idx=0; accept_idx=0; rule_no=0
        _seen_before=()
        for (( i=0; i<${#lines[@]}; i++ )); do
            line="${lines[$i]}"
            # R5-08: `iptables -S` prints the -P policy line first; only
            # -A lines are chain rules, so only they advance the number.
            [[ "$line" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue
            rule_no=$((rule_no + 1))
            if [[ "$line" =~ ^-A[[:space:]]+INPUT[[:space:]]+(-m[[:space:]]+comment[[:space:]]+--comment[[:space:]]+\"?[^\"]+\"?[[:space:]]+)?-j[[:space:]]+(DROP|REJECT)([[:space:]]|$) ]]; then
                [[ "$terminal_idx" == 0 ]] && terminal_idx=$rule_no
                continue
            fi
            if [[ "$line" =~ --comment[[:space:]]+\"?A-Box-[0-9]{1,5}(:[0-9]{1,5})?-(tcp|udp)\"?([[:space:]]|$) && "$line" =~ [[:space:]]-j[[:space:]]+ACCEPT([[:space:]]|$) ]]; then
                # R19a-01: record the normalised spec (same transform
                # as the delete below) of every A-Box ACCEPT seen
                # before the terminal rule. A post-terminal candidate
                # whose spec already exists before the terminal is
                # redundant for reachability (the front copy already
                # accepts the port) and must be skipped: a spec
                # delete removes the FIRST match, i.e. the front
                # copy, and the move then oscillates until max_moves
                # leaves the chain DROP-first. The redundant rear copy
                # is left in place (harmless, shadowed by the front
                # copy); this function reorders, it does not dedup.
                # (Both copies come from the same -S output, so the
                # textual spec comparison is sound: identical rules
                # have identical -S lines.)
                _spec="${line#-A INPUT }"
                _spec=$(printf '%s' "$_spec" | tr -d '"')
                if [[ "$terminal_idx" == 0 ]]; then
                    _seen_before["$_spec"]=1
                    continue
                fi
                [[ -n "${_seen_before[$_spec]:-}" ]] && continue
                accept_idx=$rule_no; accept_line_idx=$i; break
            fi
        done
        [[ "$accept_idx" == 0 ]] && { _rc=0; break; }
        # R5-08: accept_idx is a CHAIN rule number (for -D/-I), but
        # lines[] also holds the -P line, so index it by the raw line
        # number recorded alongside, not by accept_idx - 1.
        line="${lines[$accept_line_idx]}"
        # R25 (F06-01): re-read the chain immediately before deleting.
        # The snapshot above may be stale: another writer may have
        # inserted rules after it was taken, shifting every rule
        # number. Delete only if the rule still at accept_idx is
        # byte-identical to the snapshot line; otherwise re-snapshot
        # (the iter bound still caps endless churn). The lock covers
        # other A-Box writers; this check covers non-A-Box writers.
        _fresh=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || { _rc=1; break; }
        _fline=''; _frule_no=0
        while IFS= read -r _fline; do
            [[ "$_fline" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue
            _frule_no=$((_frule_no + 1))
            if [[ "$_frule_no" == "$accept_idx" ]]; then
                [[ "$_fline" == "$line" ]] || continue 2
                break
            fi
        done <<< "$_fresh"
        [[ "$_frule_no" == "$accept_idx" ]] || continue
        # H2 (03c): delete by rule spec, not by chain number. The
        # re-read above and this delete are two separate commands: a
        # foreign writer inserting a rule in between shifts every
        # number, and -D <n> then deletes the foreign rule. A spec
        # delete is immune to shifts (iptables matches the rule
        # itself); the re-read stays as a fast pre-check.
        spec="${line#-A INPUT }"
        spec=$(printf '%s' "$spec" | tr -d '"')
        read -r -a argv <<< "$spec"
        _iptables_do "$cmd" -D INPUT "${argv[@]}" >/dev/null 2>&1 || { _rc=1; break; }
        if ! _iptables_do "$cmd" -I INPUT "$terminal_idx" "${argv[@]}" >/dev/null 2>&1; then
            # 03c-M1: the ACCEPT is already deleted; a failed insert
            # must not lose it permanently. Put it back at its old
            # chain number (the rules after it shifted up by one on
            # delete, so this restores the original order) and still
            # report the reorder as failed.
            _iptables_do "$cmd" -I INPUT "$accept_idx" "${argv[@]}" >/dev/null 2>&1 || true
            _rc=1; break
        fi
    done
    __abox_firewall_unlock "$lock_fd"
    return "$_rc"
}
reorder_policy() {
    local cmd="$1" wl_suffix="$2" drop_suffix="$3" line key port proto rules_output=''
    local -A seen=()
    command -v "$cmd" >/dev/null 2>&1 || return 0
    rules_output=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ --comment[[:space:]]+\"?A-Box-([0-9]{1,5})-(tcp|udp)-${drop_suffix}(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([[:space:]]|$) ]]; then
            port="${BASH_REMATCH[1]}"; proto="${BASH_REMATCH[2]}"; key="${port}|${proto}"
            [[ -n "${seen[$key]:-}" ]] && continue
            seen[$key]=1
            reorder_one "$cmd" "$port" "$proto" "$wl_suffix" "$drop_suffix" || return 1
        fi
    done <<< "$rules_output"
    reorder_plain_accepts "$cmd" || return 1
}
# D1: whole-restore lock (separate from the per-port reorder lock).
# flock -n fails loudly on overlap instead of duplicating rules via --noflush.
restore_lock_file=/run/A-Box-firewall-restore.lock
restore_lock_fd=''
if [[ -e "$restore_lock_file" || -L "$restore_lock_file" ]]; then
    [[ -f "$restore_lock_file" && ! -L "$restore_lock_file" ]] || exit 1
    [[ "$(stat -c %u:%g "$restore_lock_file" 2>/dev/null || true)" == 0:0 ]] || exit 1
    [[ "$(stat -c %a "$restore_lock_file" 2>/dev/null || true)" =~ ^0?600$ ]] || exit 1
else
    # R1-06-C01: this lock file is never unlinked on exit, so an
    # unconditional noclobber create fails every second run even when
    # no one holds the lock. Create only when missing.
    (umask 077; set -o noclobber; : > "$restore_lock_file") 2>/dev/null || exit 1
fi
exec {restore_lock_fd}>>"$restore_lock_file" || exit 1
flock -n "$restore_lock_fd" || { eval "exec ${restore_lock_fd}>&-" 2>/dev/null || true; exit 1; }
trap 'flock -u "${restore_lock_fd:-}" 2>/dev/null || true; eval "exec ${restore_lock_fd:-}>&-" 2>/dev/null || true' EXIT
# D1: snapshot validity (exists + non-empty + table header).
snapshot_valid() {
    [[ -s "$1" ]] && grep -q '^\*' "$1"
}
# C02: full validation before any deletion. --test parses the
# snapshot against the kernel without committing; a rule-invalid
# snapshot must be rejected here, not after live rules are gone.
# The restore-failure backup + loud message remains the net for the
# residual test/apply race window; auto-restoring the backup with
# --noflush would duplicate partially restored rules, and restoring
# without --noflush would drop foreign rules, so no auto-rollback
# is added.
snapshot_test_valid() {
    local file="$1" cmd="$2"
    [[ -s "$file" ]] || return 1
    command -v "$cmd" >/dev/null 2>&1 || return 1
    "$cmd" -w --test < "$file" >/dev/null 2>&1 || "$cmd" --test < "$file" >/dev/null 2>&1
}
# C03: NAT PREROUTING guard (HY2-HOP lives here, not in INPUT).
# Exits 1 on surviving owned rules or on an unexplainable query
# failure; returns 0 when clean or when the NAT table does not
# exist (same tolerance as clean_chain).
_fw_nat_guard() {
    local cmd="$1" label="$2" out err
    out=$(_iptables_q "$cmd" -t nat -S PREROUTING 2>/dev/null) || {
        err=$(_iptables_q "$cmd" -t nat -S PREROUTING 2>&1 >/dev/null || true)
        # M-30(3): R15-F05-07 -- "can't/cannot initialize" is NOT a
        # not-supported signal: iptables-legacy reports the same text
        # for permission errors, which used to be misread as "no NAT
        # table" and returned success without reading or cleaning any
        # rule. A genuinely missing table says "Table does not exist".
        if printf '%s' "$err" | grep -qiE "table .* does not exist|table does not exist|table nat is not supported|protocol not supported"; then
            return 0
        fi
        echo "A-Box firewall restore: $label NAT query failed; refusing to delete." >&2
        exit 1
    }
    if [[ "$out" == *'A-Box-'* ]]; then
        echo "A-Box firewall restore: $label snapshot invalid but live A-Box NAT rules exist; refusing to delete." >&2
        exit 1
    fi
    return 0
}
# R5-10: one restore leg (v4 or v6) with a default-deny window. The
# live policy is clamped to DROP before any delete; the snapshot is
# restored from a CLAMPED temp copy (its filter :INPUT policy rewritten
# to DROP), because iptables-restore is not atomic across tables -- a
# failed restore may already have committed the snapshot's ACCEPT.
# Only after restore + reorder fully succeed is the snapshot's own
# policy restored explicitly. On any failure the leg re-enforces DROP
# and keeps the pre-delete backup for manual recovery.
_fw_restore_leg() {
    local cmd="$1" save_cmd="$2" restore_cmd="$3"
    local snapshot="$4" wl_tag="$5" drop_tag="$6"
    local backup tmp='' src='' final_policy=''
    local _rb_ok=0 _rb_clamped='' _rb_src=''
    local _clamp_i=0 _clamp_left=''
    local -a _clamp_argv=( -j DROP -m comment --comment "A-Box-restore-clamp" )

    backup=$(mktemp /run/A-Box-firewall-restore-backup.XXXXXX) || return 1
    "$save_cmd" > "$backup" 2>/dev/null || {
        rm -f -- "$backup"
        return 1
    }

    final_policy=$(awk '
        /^\*/ { f=($0 ~ /^\*filter[ \t]*$/); next }
        /^COMMIT[ \t]*$/ { f=0; next }
        f && $1 == ":INPUT" { print $2 }
    ' "$backup") || return 1

    case "$final_policy" in
        ACCEPT|DROP) ;;
        *) echo "A-Box firewall restore: $cmd INPUT policy unknown; refusing to delete." >&2
           return 1 ;;
    esac

    if snapshot_valid "$snapshot"; then
        src=$(cat -- "$snapshot") || return 1

        local snapshot_policy

        snapshot_policy=$(printf '%s\n' "$src" | awk '
            /^\*/ { f=($0 ~ /^\*filter[ \t]*$/); next }
            /^COMMIT[ \t]*$/ { f=0; next }
            f && $1 == ":INPUT" {
                if (++n > 1 ||
                    $0 !~ /^:INPUT[ \t]+(ACCEPT|DROP)([ \t]+\[[0-9]+:[0-9]+\])?[ \t]*$/) exit 1
                p=$2
            }
            END {
                if (n > 1 ||
                    (n == 1 && p != "ACCEPT" && p != "DROP"))
                    exit 1
                if (n == 1) print p
            }
        ') || {
            echo "A-Box firewall restore: invalid snapshot INPUT policy; refusing to delete." >&2
            return 1
        }

        # Snapshot without :INPUT: keep the live policy captured above.
        if [[ -n "$snapshot_policy" ]]; then
            final_policy="$snapshot_policy"
        fi

        case "$final_policy" in
            ACCEPT|DROP) ;;
            *) echo "A-Box firewall restore: invalid INPUT policy; refusing to delete." >&2
               return 1 ;;
        esac

        tmp=$(mktemp /run/A-Box-firewall-restore-clamped.XXXXXX) || return 1
        if ! printf '%s\n' "$src" | awk '
            /^\*/ { f=($0 ~ /^\*filter[ \t]*$/) }
            /^COMMIT[ \t]*$/ { f=0 }
            f && $1 == ":INPUT" { sub(/ACCEPT|DROP/, "DROP") }
            { print }
        ' > "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi

        snapshot_test_valid "$tmp" "$restore_cmd" || {
            rm -f -- "$tmp"
            return 1
        }
    fi

    if ! _iptables_do "$cmd" -P INPUT DROP >/dev/null 2>&1; then
        echo "A-Box firewall restore: $cmd clamp failed; refusing to delete." >&2
        if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
        return 1
    fi

    # R19b-H-P1: -P INPUT DROP only governs traffic that matches no
    # rule; it does not stop a foreign ACCEPT below the A-Box DROP from
    # becoming effective once clean_chain deletes that DROP. Install a
    # temporary DROP at the head of INPUT before the clean, so the
    # default-deny holds through the clean/restore/reorder window. A
    # stale clamp rule left by a crashed earlier run is removed first
    # (best effort). The comment is outside clean_chain's owned_re, so
    # the clean does not remove it. It is removed on every exit path
    # below; a failed install refuses to delete anything.
    # Note: the clamp is also the first terminal rule while present,
    # so reorder_plain_accepts may move an A-Box ACCEPT above it during
    # the reorder; the final order is unchanged (the ACCEPT still lands
    # before the A-Box DROP) and the window stays closed.
    _iptables_do "$cmd" -D INPUT "${_clamp_argv[@]}" >/dev/null 2>&1 || true
    if ! _iptables_do "$cmd" -I INPUT 1 "${_clamp_argv[@]}" >/dev/null 2>&1; then
        echo "A-Box firewall restore: $cmd temporary clamp rule failed; refusing to delete." >&2
        if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
        return 1
    fi

    if clean_chain "$cmd" filter INPUT &&
       clean_chain "$cmd" nat PREROUTING &&
       { [[ -z "$tmp" ]] || restore_one "$tmp" "$restore_cmd"; } &&
       reorder_policy "$cmd" "$wl_tag" "$drop_tag" &&
       _iptables_do "$cmd" -P INPUT "$final_policy" >/dev/null 2>&1; then
        # R19b-H-P1: remove the temporary clamp rule (loop: a crashed
        # earlier run may have left more than one behind). If it cannot
        # be removed, the host is left dropping all new INPUT traffic:
        # report failure and keep the backup for manual recovery.
        for (( _clamp_i=0; _clamp_i<10; _clamp_i++ )); do
            _iptables_do "$cmd" -D INPUT "${_clamp_argv[@]}" >/dev/null 2>&1 || break
        done
        _clamp_left=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || {
            echo "A-Box firewall restore: $cmd could not verify the temporary clamp rule is gone; check manually." >&2
            return 1
        }
        if grep -q 'A-Box-restore-clamp' <<< "$_clamp_left"; then
            echo "A-Box firewall restore: $cmd temporary clamp rule could not be removed; remove it manually: $cmd -D INPUT -j DROP -m comment --comment \"A-Box-restore-clamp\"" >&2
            return 1
        fi
        if [[ -n "$tmp" ]]; then
            rm -f -- "$tmp" || return 1
        fi
        rm -f -- "$backup" || return 1
        return 0
    fi

    # R16-F06-01: the clean above may already have deleted the A-Box
    # rules; a bare DROP re-clamp does not bring them back, and foreign
    # ACCEPT rules below them become effective at once. Restore the
    # pre-delete backup first (flush-restore of a DROP-clamped copy, so
    # partially restored snapshot rules are not duplicated and the policy
    # cannot come back as ACCEPT), then re-clamp DROP. A failed rollback
    # still reports failure and keeps the backup for manual recovery; the
    # leg still returns 1 (its goal was not achieved).
    if [[ -s "$backup" ]]; then
        _rb_clamped=$(mktemp /run/A-Box-firewall-restore-rollback.XXXXXX 2>/dev/null) || _rb_clamped=''
        if [[ -n "$_rb_clamped" ]] && awk '
            /^\*/ { f=($0 ~ /^\*filter[ \t]*$/) }
            /^COMMIT[ \t]*$/ { f=0 }
            f && $1 == ":INPUT" { sub(/ACCEPT|DROP/, "DROP") }
            { print }
        ' "$backup" > "$_rb_clamped" 2>/dev/null && [[ -s "$_rb_clamped" ]]; then
            _rb_src="$_rb_clamped"
        else
            # R16-F06-01: never flush-restore the raw backup. Its INPUT
            # policy may be ACCEPT, and restoring it re-opens the host
            # (a fail-open window until the re-clamp below, permanent
            # if the re-clamp fails). Keep the backup for manual
            # recovery and report failure instead.
            _rb_src=''
        fi
        if [[ -n "$_rb_src" ]] && { "$restore_cmd" -w < "$_rb_src" >/dev/null 2>&1 || "$restore_cmd" < "$_rb_src" >/dev/null 2>&1; }; then
            _rb_ok=1
        fi
        if [[ -n "$_rb_clamped" ]]; then rm -f -- "$_rb_clamped"; fi
    fi
    if ! _iptables_do "$cmd" -P INPUT DROP >/dev/null 2>&1; then
        echo "A-Box firewall restore: $cmd failed to enforce DROP; manual recovery required." >&2
    fi
    if (( _rb_ok == 1 )); then
        echo "A-Box firewall restore FAILED; pre-delete backup restored: $backup" >&2
    else
        echo "A-Box firewall restore FAILED; pre-delete backup preserved: $backup (restore manually)" >&2
    fi
    if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
    # R19b-H-P1: remove the temporary clamp rule on the failure path
    # too (best effort; the flush-restore above already removes it
    # when it ran, since the backup predates the clamp). If the delete
    # fails here the rule stays and new INPUT traffic stays dropped:
    # say so loudly so the operator removes it by hand.
    for (( _clamp_i=0; _clamp_i<10; _clamp_i++ )); do
        _iptables_do "$cmd" -D INPUT "${_clamp_argv[@]}" >/dev/null 2>&1 || break
    done
    if _iptables_q "$cmd" -S INPUT 2>/dev/null | grep -q 'A-Box-restore-clamp'; then
        echo "A-Box firewall restore: $cmd temporary clamp rule could not be removed; remove it manually: $cmd -D INPUT -j DROP -m comment --comment \"A-Box-restore-clamp\"" >&2
    fi
    return 1
}

# D1: validate before deleting (fail before clean when live A-Box rules
# exist but the snapshot cannot restore them; proceed when nothing live
# to lose, e.g. fresh boot or IPv4-only host with no live v6 rules).
if ! snapshot_valid /etc/ddr/iptables.v4; then
    _fw_input_v4=$(_iptables_q iptables -S INPUT 2>/dev/null) || { echo 'A-Box firewall restore: IPv4 INPUT query failed; refusing to delete.' >&2; exit 1; }
    if [[ "$_fw_input_v4" == *'A-Box-'* ]]; then
        echo 'A-Box firewall restore: IPv4 snapshot invalid but live A-Box rules exist; refusing to delete.' >&2
        exit 1
    fi
    _fw_nat_guard iptables IPv4
elif ! snapshot_test_valid /etc/ddr/iptables.v4 iptables-restore; then
    echo 'A-Box firewall restore: IPv4 snapshot failed full validation (--test); refusing to delete live rules.' >&2
    exit 1
fi
# R5-10: v4 leg via _fw_restore_leg (pre-checks above are unchanged).
_fw_restore_leg iptables iptables-save iptables-restore /etc/ddr/iptables.v4 WL DROP || exit 1
if command -v ip6tables >/dev/null 2>&1 && _iptables_q ip6tables -S INPUT >/dev/null 2>&1; then
    if ! snapshot_valid /etc/ddr/iptables.v6; then
        _fw_input_v6=$(_iptables_q ip6tables -S INPUT 2>/dev/null) || { echo 'A-Box firewall restore: IPv6 INPUT query failed; refusing to delete.' >&2; exit 1; }
        if [[ "$_fw_input_v6" == *'A-Box-'* ]]; then
            echo 'A-Box firewall restore: IPv6 snapshot invalid but live A-Box rules exist; refusing to delete.' >&2
            exit 1
        fi
        _fw_nat_guard ip6tables IPv6
    elif ! snapshot_test_valid /etc/ddr/iptables.v6 ip6tables-restore; then
        echo 'A-Box firewall restore: IPv6 snapshot failed full validation (--test); refusing to delete live rules.' >&2
        exit 1
    fi
    # R5-10: v6 leg via _fw_restore_leg (pre-checks above are unchanged).
    _fw_restore_leg ip6tables ip6tables-save ip6tables-restore /etc/ddr/iptables.v6 WL6 DROP6 || exit 1
elif [[ -s /etc/ddr/iptables.v6 ]]; then
    # A v6 snapshot exists but ip6tables is unusable right now:
    # fail loudly instead of silently booting without v6 rules.
    echo 'A-Box firewall restore: IPv6 snapshot exists but ip6tables is unusable; IPv6 rules were NOT restored.' >&2
    exit 1
fi
exit 0
EOF_ABOX_FW_RESTORE
    [[ $? -eq 0 ]] || { rm -f "$tmp"; return 1; }
    chmod 700 "$tmp" || { rm -f "$tmp"; return 1; }
    # R9 (F05-7): normalize ownership before publish. mktemp inherits the
    # caller's egid, but the precheck above requires 0:0; without this a
    # first publish under egid != 0 succeeds and the second self-refuses.
    chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$ABOX_DIR/firewall_restore.sh" || { rm -f "$tmp"; return 1; }
}

# BUG-28: hoisted from install_abox_firewall_persistence_service().
# $1=old_restore $2=tx_dir $3=old_unit $4=old_unit_path $5=old_unit_enabled
__abox_firewall_persistence_rollback() {
    local old_restore="$1" tx_dir="$2" old_unit="$3" old_unit_path="$4" old_unit_enabled="$5"
    local fail=0 _rb_en='' _rb_links='' _rb_rc=0 _rb_show=''
    if [[ "$old_restore" == 1 ]]; then
        cp -a -- "$tx_dir/firewall_restore.sh" "$ABOX_DIR/firewall_restore.sh" || fail=1
    else
        rm -f -- "$ABOX_DIR/firewall_restore.sh" || fail=1
    fi
    case "${INIT_SYS:-}" in
        systemd)
            if [[ "$old_unit" == 1 ]]; then
                cp -a -- "$tx_dir/A-Box-firewall.service" "$old_unit_path" || fail=1
            else
                systemctl disable A-Box-firewall.service >/dev/null 2>&1 || true
                rm -f -- "$old_unit_path" || fail=1
            fi
            systemctl daemon-reload >/dev/null 2>&1 || fail=1
            if [[ "$old_unit" == 1 ]]; then
                case "$old_unit_enabled" in
                    enabled|indirect) systemctl enable A-Box-firewall.service >/dev/null 2>&1 || fail=1 ;;
                    enabled-runtime) systemctl disable A-Box-firewall.service >/dev/null 2>&1 || fail=1; systemctl enable --runtime A-Box-firewall.service >/dev/null 2>&1 || fail=1; [[ "$(systemctl is-enabled A-Box-firewall.service 2>/dev/null)" == enabled-runtime ]] || fail=1 ;;
                    *) systemctl disable A-Box-firewall.service >/dev/null 2>&1 || fail=1 ;;
                esac
            else
                # 03c-M2: a fresh-install rollback never verified that
                # the new enablement was actually cancelled: a failed
                # disable leaves a dangling .wants/ link behind while
                # the unit file is gone. Verify by the live state, not
                # by the swallowed disable rc: still enabled means the
                # rollback did not land.
                # R19b-M2: `systemctl is-enabled` cannot be that
                # verification: once the unit file is deleted it
                # reports not-found even when a dangling .wants/ link
                # remains (verified on systemd 255), so the check
                # below could never fire. Check the links directly:
                # any symlink named after the unit under the unit
                # file's directory means the enablement was not
                # actually cancelled. A failed find is also a failure
                # (the cleanup cannot be proven).
                _rb_links=$(find "$(dirname -- "$old_unit_path")" -name 'A-Box-firewall.service' -type l 2>/dev/null) || _rb_rc=$?
                if (( _rb_rc != 0 )) || [[ -n "$_rb_links" ]]; then
                    fail=1
                fi
            fi
            ;;
        openrc)
            if [[ "$old_unit" == 1 ]]; then
                cp -a -- "$tx_dir/A-Box-firewall" "$old_unit_path" || fail=1
            else
                if command -v rc-update >/dev/null 2>&1 && rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])A-Box-firewall([[:space:]]|$)'; then
                    rc-update del A-Box-firewall default >/dev/null 2>&1 || true
                fi
                rm -f -- "$old_unit_path" || fail=1
            fi
            if command -v rc-update >/dev/null 2>&1; then
                if [[ "$old_unit_enabled" == 1 ]]; then
                    rc-update add A-Box-firewall default >/dev/null 2>&1 || true
                elif rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])A-Box-firewall([[:space:]]|$)'; then
                    rc-update del A-Box-firewall default >/dev/null 2>&1 || true
                fi
                if [[ "$old_unit" == 1 ]] && [[ "$(service_enabled_state_value A-Box-firewall 2>/dev/null || printf '%s' unknown)" != "$old_unit_enabled" ]]; then
                    fail=1
                fi
                # 03c-M2: same fresh-install gap as the systemd branch:
                # a failed rc-update del leaves the service listed in
                # the default runlevel while the unit file is gone.
                # Verify the listing is actually gone.
                # R19b-M3: a failed query must fail the rollback, not
                # be read as "not listed": the pipeline's status is
                # grep's, and grep finds nothing both when the query
                # succeeded with no match and when it failed with no
                # output (pipefail does not help either — a failed
                # query would only make the condition false). Take the
                # output and the exit code separately.
                if [[ "$old_unit" == 0 ]]; then
                    if ! _rb_show=$(rc-update show default 2>/dev/null); then
                        fail=1
                    elif grep -Eq '(^|[[:space:]])A-Box-firewall([[:space:]]|$)' <<< "$_rb_show"; then
                        fail=1
                    fi
                fi
            else
                fail=1
            fi
            ;;
    esac
    return "$fail"
}
install_abox_firewall_persistence_service() {
    local tx_dir old_restore=0 old_unit=0 old_unit_path='' old_unit_enabled='' rollback_rc=0 _same_unit=''
    tx_dir=$(mktemp -d "$ABOX_DIR/.firewall-persist-tx.XXXXXX") || return 1

    if [[ -e "$ABOX_DIR/firewall_restore.sh" || -L "$ABOX_DIR/firewall_restore.sh" ]]; then
        [[ -f "$ABOX_DIR/firewall_restore.sh" && ! -L "$ABOX_DIR/firewall_restore.sh" ]] || { rm -rf -- "$tx_dir"; return 1; }
        path_owned_by_root "$ABOX_DIR/firewall_restore.sh" || { rm -rf -- "$tx_dir"; return 1; }
        path_mode_has_no_group_other_write "$ABOX_DIR/firewall_restore.sh" || { rm -rf -- "$tx_dir"; return 1; }
        grep -Fxq '# Managed by A-Box' "$ABOX_DIR/firewall_restore.sh" 2>/dev/null || { rm -rf -- "$tx_dir"; return 1; }
        cp -a -- "$ABOX_DIR/firewall_restore.sh" "$tx_dir/firewall_restore.sh" || { rm -rf -- "$tx_dir"; return 1; }
        old_restore=1
    fi

    case "${INIT_SYS:-}" in
        systemd)
            old_unit_path=/etc/systemd/system/A-Box-firewall.service
            _same_unit=$(systemd_same_name_unit_path A-Box-firewall 2>/dev/null || true)
            if [[ -n "$_same_unit" && "$_same_unit" != "$old_unit_path" ]]; then
                rm -rf -- "$tx_dir"
                return 1
            fi
            if [[ -e "$old_unit_path" || -L "$old_unit_path" ]]; then
                assert_abox_auxiliary_safe "$old_unit_path" || { rm -rf -- "$tx_dir"; return 1; }
                cp -a -- "$old_unit_path" "$tx_dir/A-Box-firewall.service" || { rm -rf -- "$tx_dir"; return 1; }
                old_unit=1
                old_unit_enabled=$(service_enabled_state_value A-Box-firewall.service) || { rm -rf -- "$tx_dir"; return 1; }
            fi
            ;;
        openrc)
            old_unit_path=/etc/init.d/A-Box-firewall
            if [[ -e "$old_unit_path" || -L "$old_unit_path" ]]; then
                assert_abox_auxiliary_safe "$old_unit_path" || { rm -rf -- "$tx_dir"; return 1; }
                cp -a -- "$old_unit_path" "$tx_dir/A-Box-firewall" || { rm -rf -- "$tx_dir"; return 1; }
                old_unit=1
                old_unit_enabled=$(service_enabled_state_value A-Box-firewall) || { rm -rf -- "$tx_dir"; return 1; }
            fi
            ;;
        *)
            rm -rf -- "$tx_dir"
            return 1
            ;;
    esac


    if ! write_abox_firewall_restore_script; then
        __abox_firewall_persistence_rollback "$old_restore" "$tx_dir" "$old_unit" "$old_unit_path" "$old_unit_enabled" || rollback_rc=1
        if (( rollback_rc == 0 )); then rm -rf -- "$tx_dir"; else printf '%s\n' "A-Box firewall persistence rollback FAILED; recovery backup preserved at $tx_dir (restore firewall_restore.sh and the A-Box-firewall unit from it manually)" >&2; fi
        (( rollback_rc == 0 )) && return 1
        return 1
    fi
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        if ! write_file_atomically_from_stdin /etc/systemd/system/A-Box-firewall.service 644 <<EOF_ABOX_FW_UNIT
# Managed by A-Box
[Unit]
Description=A-Box isolated firewall rule restore
After=network-pre.target iptables.service ip6tables.service nftables.service ufw.service firewalld.service
Before=xray.service sing-box.service hysteria.service

[Service]
Type=oneshot
ExecStart="$ABOX_DIR/firewall_restore.sh"
NoNewPrivileges=true
PrivateTmp=true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_ABOX_FW_UNIT
        then
            __abox_firewall_persistence_rollback "$old_restore" "$tx_dir" "$old_unit" "$old_unit_path" "$old_unit_enabled" || rollback_rc=1
            if (( rollback_rc == 0 )); then rm -rf -- "$tx_dir"; else printf '%s\n' "A-Box firewall persistence rollback FAILED; recovery backup preserved at $tx_dir (restore firewall_restore.sh and the A-Box-firewall unit from it manually)" >&2; fi
            return 1
        fi
        if ! systemctl daemon-reload >/dev/null 2>&1 || ! systemctl enable A-Box-firewall.service >/dev/null 2>&1; then
            __abox_firewall_persistence_rollback "$old_restore" "$tx_dir" "$old_unit" "$old_unit_path" "$old_unit_enabled" || rollback_rc=1
            if (( rollback_rc == 0 )); then rm -rf -- "$tx_dir"; else printf '%s\n' "A-Box firewall persistence rollback FAILED; recovery backup preserved at $tx_dir (restore firewall_restore.sh and the A-Box-firewall unit from it manually)" >&2; fi
            return 1
        fi
    else
        if ! write_file_atomically_from_stdin /etc/init.d/A-Box-firewall 755 <<EOF_ABOX_FW_OPENRC
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box isolated firewall rule restore"
command="$ABOX_DIR/firewall_restore.sh"
command_background="no"
depend() { need net; after iptables ip6tables nftables ufw firewalld; before xray sing-box hysteria; }
EOF_ABOX_FW_OPENRC
        then
            __abox_firewall_persistence_rollback "$old_restore" "$tx_dir" "$old_unit" "$old_unit_path" "$old_unit_enabled" || rollback_rc=1
            if (( rollback_rc == 0 )); then rm -rf -- "$tx_dir"; else printf '%s\n' "A-Box firewall persistence rollback FAILED; recovery backup preserved at $tx_dir (restore firewall_restore.sh and the A-Box-firewall unit from it manually)" >&2; fi
            return 1
        fi
        if ! chmod 755 /etc/init.d/A-Box-firewall || ! rc-update add A-Box-firewall default >/dev/null 2>&1; then
            __abox_firewall_persistence_rollback "$old_restore" "$tx_dir" "$old_unit" "$old_unit_path" "$old_unit_enabled" || rollback_rc=1
            if (( rollback_rc == 0 )); then rm -rf -- "$tx_dir"; else printf '%s\n' "A-Box firewall persistence rollback FAILED; recovery backup preserved at $tx_dir (restore firewall_restore.sh and the A-Box-firewall unit from it manually)" >&2; fi
            return 1
        fi
    fi

    rm -rf -- "$tx_dir"
    return 0
}

