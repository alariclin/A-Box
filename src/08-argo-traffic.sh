# ABOX-MODULE-BEGIN 08-argo-traffic argo/panel, routing/WARP, traffic monitor
#   Source: install.sh lines 32421-38401 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
argo_remove_unit() { # $1 = unit name; best-effort, refuses foreign units
    local name="$1" unit
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        unit="/etc/systemd/system/${name}.service"
    else
        unit="/etc/init.d/${name}"
    fi
    # Only A-Box-managed units (written by argo_write_unit with the
    # marker) may be removed; a foreign service sharing the name
    # must survive.
    # R15-F09-01: "no unit file" is not a removal failure (a first
    # deploy has nothing to tear down) -- but only when the manager
    # also confirms nothing of this unit survives. A loaded unit whose
    # file was deleted, or a residue process, still blocks the removal.
    if [[ ! -e "$unit" && ! -L "$unit" ]]; then
        argo_unit_stopped_confirmed "$name" && return 0 || return 1
    fi
    [[ -f "$unit" && ! -L "$unit" ]] || return 1
    grep -Fxq '# Managed by A-Box' "$unit" 2>/dev/null || return 1
    # R6-F08-6 (A'): verify each step's OUTCOME, not just its rc. A stop/disable
    # rc alone is not proof (repeat stop may fail while already stopped);
    # the unit file and its enable entries are verified gone BEFORE the
    # marker-bearing unit is deleted, so a failure keeps the unit identifiable.
    # R11-C (R6-1): the stop check below is argo_unit_stopped_confirmed, not
    # argo_unit_active: a failed status query must refuse, never read as
    # "stopped", and a live daemon must block deletion even when the
    # manager reports the unit inactive.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl stop "${name}.service" >/dev/null 2>&1 || true
        if ! argo_unit_stopped_confirmed "$name"; then return 1; fi
        systemctl disable "${name}.service" >/dev/null 2>&1 || true
        systemctl disable --runtime "${name}.service" >/dev/null 2>&1 || true
        local _link
        for _link in /etc/systemd/system/*.wants/"${name}.service" /etc/systemd/system/*.requires/"${name}.service" /run/systemd/system/*.wants/"${name}.service" /run/systemd/system/*.requires/"${name}.service"; do
            [[ -e "$_link" || -L "$_link" ]] || continue
            return 1
        done
        rm -f "/etc/systemd/system/${name}.service" || return 1
        [[ ! -e "/etc/systemd/system/${name}.service" && ! -L "/etc/systemd/system/${name}.service" ]] || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
    else
        rc-service "$name" stop >/dev/null 2>&1 || true
        if ! argo_unit_stopped_confirmed "$name"; then return 1; fi
        rc-update del "$name" default >/dev/null 2>&1 || true
        local _rl _entry
        for _rl in /etc/runlevels/*; do
            [[ -d "$_rl" ]] || continue
            _entry="$_rl/$name"
            [[ -L "$_entry" ]] || continue
            case "$(readlink -- "$_entry" 2>/dev/null || true)" in
                */init.d/"$name"|/etc/init.d/"$name") rm -f -- "$_entry" || return 1 ;;
            esac
        done
        for _rl in /etc/runlevels/*; do
            [[ -d "$_rl" ]] || continue
            _entry="$_rl/$name"
            [[ -e "$_entry" || -L "$_entry" ]] && return 1
        done
        rm -f "/etc/init.d/${name}" || return 1
        [[ ! -e "/etc/init.d/${name}" && ! -L "/etc/init.d/${name}" ]] || return 1
    fi
    # Non-critical log cleanup: must not decide the return value.
    rm -f "/etc/ddr/${name}.log" || true
    return 0
}

argo_unit_active() { # $1 = unit name -> 0 active
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl is-active --quiet "$1" 2>/dev/null
    else
        rc-service "$1" status >/dev/null 2>&1
    fi
}

# R11-C (R6-1): confirmed-stopped predicate. argo_unit_active() only
# returns the manager's raw rc, so "query failed" and "inactive" look
# identical; callers that delete a unit on "not active" therefore delete
# over a live daemon. This predicate returns 0 ONLY when the unit is
# positively confirmed stopped; every other outcome (running, query
# failure, unattributable residue process, unavailable check tool)
# returns 1 and records a short reason in _ARGO_STOPPED_DETAIL for the
# caller's diagnostic. "Not installed" counts as confirmed stopped:
# there is no unit to run, but this says nothing about the unit file,
# so argo_remove_unit still enforces its managed-file check first.
_ARGO_STOPPED_DETAIL=''

_argo_live_cloudflared_pids() { # prints one pid per line; rc 2 = check unavailable
    local _x='' _f='' _rc=0 _p _seen=''
    command -v pgrep >/dev/null 2>&1 || return 2
    _x=$(pgrep -x cloudflared 2>/dev/null); _rc=$?
    (( _rc == 0 || _rc == 1 )) || return 2
    _f=$(pgrep -f '^/usr/local/bin/cloudflared([[:space:]]|$)' 2>/dev/null); _rc=$?
    (( _rc == 0 || _rc == 1 )) || return 2
    for _p in $_x $_f; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        case " $_seen " in *" $_p "*) continue ;; esac
        _seen+=" $_p"
        printf '%s\n' "$_p"
    done
    return 0
}

_argo_cloudflared_pid_attributed() { # $1 = pid, $2 = own unit -> 0 if the pid belongs to another known instance
    local _pid="$1" _own="$2" _u _mp _pf _pp
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        for _u in argo argo-vmess argo-vless abox-wallos-cftunnel; do
            [[ "$_u" == "$_own" ]] && continue
            _mp=$(systemctl show -p MainPID --value "${_u}.service" 2>/dev/null || true)
            [[ "$_mp" =~ ^[0-9]+$ ]] || continue
            (( 10#$_mp != 0 )) || continue
            [[ "$_mp" == "$_pid" ]] && return 0
        done
    else
        for _u in argo argo-vmess argo-vless abox-wallos-cftunnel; do
            [[ "$_u" == "$_own" ]] && continue
            _pf="/run/${_u}.pid"
            [[ -f "$_pf" && ! -L "$_pf" ]] || continue
            _pp=$(< "$_pf")
            [[ "$_pp" =~ ^[0-9]+$ ]] || continue
            [[ "$_pp" == "$_pid" ]] && return 0
        done
    fi
    return 1
}

_argo_stopped_confirmed_systemd() { # $1 = unit name -> 0 iff confirmed stopped
    local _name="$1" _out='' _rc=0 _l1='' _l2='' _l3=''
    _out=$(systemctl show --property=LoadState,ActiveState,MainPID "${_name}.service" 2>/dev/null); _rc=$?
    (( _rc == 0 )) || { _ARGO_STOPPED_DETAIL='status query failed'; return 1; }
    _l1=$(sed -n 's/^LoadState=//p' <<< "$_out"); _l2=$(sed -n 's/^ActiveState=//p' <<< "$_out"); _l3=$(sed -n 's/^MainPID=//p' <<< "$_out")
    [[ -n "$_l1" && -n "$_l2" && -n "$_l3" ]] || { _ARGO_STOPPED_DETAIL='status query failed'; return 1; }
    if [[ "$_l1" == not-found ]]; then
        # Not loaded by the manager: stopped only if no unit file exists
        # (and no dangling link) and no residue process survives.
        if [[ -e "/etc/systemd/system/${_name}.service" || -L "/etc/systemd/system/${_name}.service" ]]; then
            _ARGO_STOPPED_DETAIL='unit file present but not loaded by systemd'
            return 1
        fi
    elif [[ "$_l1" == loaded ]]; then
        case "$_l2" in
            active) _ARGO_STOPPED_DETAIL='still running'; return 1 ;;
            inactive)
                [[ "$_l3" == 0 ]] || { _ARGO_STOPPED_DETAIL='inconsistent manager state'; return 1; }
                ;;
            *) _ARGO_STOPPED_DETAIL='unit state unknown'; return 1 ;;
        esac
    else
        _ARGO_STOPPED_DETAIL='unit state unknown'
        return 1
    fi
    local _residue='' _p
    if ! _residue=$(_argo_live_cloudflared_pids); then
        _ARGO_STOPPED_DETAIL='process check unavailable'
        return 1
    fi
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        if ! _argo_cloudflared_pid_attributed "$_p" "$_name"; then
            _ARGO_STOPPED_DETAIL="unattributed cloudflared process (pid $_p)"
            return 1
        fi
    done <<< "$_residue"
    _ARGO_STOPPED_DETAIL='stopped'
    return 0
}

_argo_stopped_confirmed_openrc() { # $1 = unit name -> 0 iff confirmed stopped
    local _name="$1" _pid='' _p
    local _pf="/run/${_name}.pid"
    if [[ -e "$_pf" || -L "$_pf" ]]; then
        [[ -f "$_pf" && ! -L "$_pf" ]] || { _ARGO_STOPPED_DETAIL='pidfile unreadable'; return 1; }
        _pid=$(< "$_pf")
        [[ "$_pid" =~ ^[0-9]+$ ]] && (( 10#$_pid > 0 )) || { _ARGO_STOPPED_DETAIL='pidfile unreadable'; return 1; }
        if kill -0 "$_pid" 2>/dev/null; then
            _ARGO_STOPPED_DETAIL='still running'
            return 1
        fi
        # kill -0 failed: ESRCH means dead; a /proc entry means the
        # process exists but cannot be signalled: unknown, not dead.
        if [[ -d "/proc/$_pid" ]]; then
            _ARGO_STOPPED_DETAIL='status query failed'
            return 1
        fi
        # Stale pidfile: fall through to the process scan below, in case
        # a live cloudflared survives under another pid.
    fi
    local _residue=''
    if ! _residue=$(_argo_live_cloudflared_pids); then
        _ARGO_STOPPED_DETAIL='process check unavailable'
        return 1
    fi
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        if ! _argo_cloudflared_pid_attributed "$_p" "$_name"; then
            _ARGO_STOPPED_DETAIL="unattributed cloudflared process (pid $_p)"
            return 1
        fi
    done <<< "$_residue"
    _ARGO_STOPPED_DETAIL='stopped'
    return 0
}

argo_unit_stopped_confirmed() { # $1 = unit name -> 0 iff confirmed stopped
    local name="$1"
    _ARGO_STOPPED_DETAIL=''
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        _argo_stopped_confirmed_systemd "$name"
    else
        _argo_stopped_confirmed_openrc "$name"
    fi
}

# L-07(D): a log line proves the CURRENT tunnel only if its leading
# timestamp is fresh (not older than $2, an epoch). The timestamp
# must be a zone-qualified RFC3339 stamp (cloudflared's log format);
# a line without one is stale, never fresh: an undated line can never
# prove the current tunnel is up, and accepting it reopens the
# stale-log false-ready. date -d parses RFC3339 on GNU and BusyBox
# date; python3 is the fallback for runtimes whose date cannot.
# Both failing is stale (fail closed).
_argo_line_fresh() { # $1 = log line, $2 = earliest acceptable epoch -> 0 iff fresh
    local _ts _ep
    [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})) ]] || return 1
    _ts="${BASH_REMATCH[1]}"
    _ep=$(date -d "$_ts" +%s 2>/dev/null || true)
    if [[ ! "$_ep" =~ ^[0-9]+$ ]]; then
        _ep=$(python3 -I -c 'import sys; from datetime import datetime; print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$_ts" 2>/dev/null || true)
    fi
    [[ "$_ep" =~ ^[0-9]+$ ]] || return 1
    (( _ep >= $2 ))
}

argo_capture_domain() { # $1 = log file -> domain on stdout
    local i d _line _fresh_since
    # L-07(D): only a domain logged by the CURRENT tunnel counts. The
    # log is append-only across redeploys, so a line from a dead tunnel
    # would otherwise be returned on the first poll. Lines logged up
    # to 300s before this wait started still count (the unit was
    # (re)started just before this call; a slow edge handshake can
    # delay the first lines, and the second tunnel's wait starts only
    # after the first tunnel's capture finishes).
    _fresh_since=$(($(date +%s) - 300))
    for i in $(seq 1 45); do
        d=$(grep -aoE '[a-z0-9-]+\.trycloudflare\.com' "$1" 2>/dev/null | grep -v '^api\.trycloudflare\.com$' | tail -1)
        if [[ -n "$d" ]]; then
            _line=$(grep -aF "$d" "$1" 2>/dev/null | tail -1)
            if [[ -n "$_line" ]] && _argo_line_fresh "$_line" "$_fresh_since"; then
                printf '%s' "$d"; return 0
            fi
        fi
        sleep 2
    done
    return 1
}

argo_links_for() { # $1 = vmess domain, $2 = vless domain
    local vm_json vm_b64 vless_link
    vm_json=$(jq -nc --arg d "$1" --rawfile id <(printf '%s' "$ARGO_UUID") \
        '{v:"2",ps:"VMess-Argo",add:$d,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$d,path:("/" + $id + "-vmess"),tls:"tls",sni:$d,fp:"chrome"}') \
        || die "$(tr_msg ag_vmess_link)"
    vm_b64=$(printf '%s' "$vm_json" | base64 | tr -d '\n\r')
    vless_link="vless://${ARGO_UUID}@${2}:443?encryption=none&security=tls&sni=${2}&type=ws&host=${2}&path=%2F${ARGO_UUID}-vless%3Fed%3D2560#VLESS-Argo"
    msg "VMess: vmess://${vm_b64}"
    msg "VLESS: ${vless_link}"
    generate_qr "$vless_link"
    register_standalone_link argo "Argo (CDN)" "vmess://${vm_b64}" "${vless_link}"
}

# R15C9-01: temp tunnels must prove edge connections before the fixed
# deployment is torn down; a bare trycloudflare.com domain in the log
# does not prove the tunnel can serve traffic. Mirrors
# argo_wait_fixed_ready, parameterized by unit + log.
argo_wait_temp_ready() { # $1=unit $2=log $3=timeout(sec, default 60)
    local unit="$1" log="$2" timeout="${3:-60}" i _line _fresh_since
    # L-07(D): see argo_capture_domain: only a FRESH 'Registered
    # tunnel connection' line proves the current tunnel. A stale
    # auth-failure line likewise must not fail a new tunnel: only a
    # fresh one fails the wait.
    _fresh_since=$(($(date +%s) - 300))
    for i in $(seq 1 "$timeout"); do
        _line=$(grep -a 'Registered tunnel connection' "$log" 2>/dev/null | tail -1)
        if [[ -n "$_line" ]] && _argo_line_fresh "$_line" "$_fresh_since"; then
            argo_unit_active "$unit" || return 1
            return 0
        fi
        _line=$(grep -aiE 'authentication failed|failed to authenticate|unable to authenticate' "$log" 2>/dev/null | tail -1)
        if [[ -n "$_line" ]] && _argo_line_fresh "$_line" "$_fresh_since"; then
            return 1
        fi
        sleep 1
    done
    return 1
}

# 2qu: probe a temp tunnel's public origin WebSocket endpoint. A bare
# HTTP/1.1 Upgrade request to the exact ws path must return 101 from
# the sing-box ws inbound (early data is optional: no
# Sec-WebSocket-Protocol header is sent, and ServeHTTP proceeds to
# the upgrade without it; a wrong path returns 404, a dead origin
# surfaces as 502/503/1033 or no response). Curl receives 101 and
# then stays connected until --max-time, so success is judged ONLY
# by the observed 101 in the response headers -- curl's exit code is
# ignored (rc 28 after a 101 is still success). Bounded retries:
# 6 attempts, 2s apart, 10s max / 5s connect-timeout each.
# $1 = domain, $2 = ws path (e.g. /<UUID>-vmess). Returns 0 on 101.
argo_origin_probe() {
    local domain="$1" path="$2" tmpd='' hdr='' i http_code=''
    # B15-3 (observability only): record every attempt's HTTP status
    # plus curl's exit status, and print the bounded six-entry summary
    # on exhaustion. A single first code cannot separate "no HTTP status"
    # (000) from a curl-level failure (e.g. rc 28 timeout) or show a
    # mixed 400/000/400 pattern; the summary can, without per-attempt
    # noise. msg goes to stderr so stdout stays empty as before.
    # R26-H-NF-02: the verdict is now deadline-gated (below), not a
    # fixed 6 attempts: a single rc 6 cannot separate "DNS not yet
    # propagated" from "dead origin", and a transient resolver/edge
    # fault can surface as a timeout or a non-101 status instead.
    local curl_rc=0
    local url_cfg=''
    local -a probe_pipe_rc=()
    local _url_q='"'

    # R6-F08-3: the probe URL carries the auth UUID; it must never reach
    # any child argv (/proc/<pid>/cmdline). Pass it via a curl config on
    # stdin instead. Bash builtins only; no external encoder sees the URL.
    # NOTE (deviation from GPT's literal line): GPT wrote
    # url_cfg=${url_cfg//\"/\\"}, which is INVALID bash: inside ${}
    # the bare \" opens an unterminated double quote (bash -n fails:
    # unexpected EOF while looking for matching `"'). The quote is
    # therefore held in _url_q and matched as "$_url_q" (fixture-verified
    # byte-exact on the full escape matrix: backslash/quote/tab/LF/CR/VT).
    url_cfg="https://${domain}${path}"
    url_cfg=${url_cfg//\\/\\\\}
    url_cfg=${url_cfg//"$_url_q"/\\"$_url_q"}
    url_cfg=${url_cfg//$'\t'/\\t}
    url_cfg=${url_cfg//$'\n'/\\n}
    url_cfg=${url_cfg//$'\r'/\\r}
    url_cfg=${url_cfg//$'\v'/\\v}
    tmpd=$(mktemp -d /tmp/A-Box-argo-probe.XXXXXX) || return 1
    hdr="$tmpd/headers"
    # R26-H-NF-02 (GPT-arbitrated): retry transient failures until a
    # monotonic deadline (default 300s; ABOX_ARGO_PROBE_DEADLINE_SEC
    # overrides it for tests). Each curl/sleep is capped to the
    # remaining budget, so the probe never overruns the deadline by
    # more than one attempt. Only a demonstrably permanent local error
    # (curl rc 3, malformed URL) fails immediately.
    local deadline_sec="${ABOX_ARGO_PROBE_DEADLINE_SEC:-300}"
    [[ "$deadline_sec" =~ ^[0-9]+$ ]] && (( deadline_sec > 0 )) || deadline_sec=300
    local start_sec=$SECONDS
    i=0
    local remaining=0 mt=0 ct=0 slp=0
    local -a obs_arr=()
    local _obs_show=() _obs_joined=''
    while :; do
        i=$((i + 1))
        remaining=$(( deadline_sec - (SECONDS - start_sec) ))
        (( remaining > 0 )) || break
        mt=$(( remaining < 10 ? remaining : 10 ))
        ct=$(( remaining < 5 ? remaining : 5 ))
        : > "$hdr"
        curl_rc=0
        http_code=$(
            builtin printf 'url = "%s"\n' "$url_cfg" 2>/dev/null |
                curl -K - -s -D "$hdr" --http1.1 \
                    --connect-timeout "$ct" --max-time "$mt" \
                    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
                    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
                    -H 'Sec-WebSocket-Version: 13' \
                    -w '%{http_code}' -o /dev/null 2>/dev/null
            probe_pipe_rc=("${PIPESTATUS[@]}")
            exit "${probe_pipe_rc[1]}"
        ) || curl_rc=$?
        if [[ "$http_code" == 101 ]]; then
            rm -rf -- "$tmpd"
            return 0
        fi
        obs_arr+=("HTTP=${http_code:-<empty>} curl_rc=$curl_rc")
        # Permanent local error: retrying cannot help.
        if [[ "$curl_rc" == 3 ]]; then
            _obs_show=("${obs_arr[@]}")
            if (( ${#_obs_show[@]} > 6 )); then _obs_show=("${_obs_show[@]: -6}"); fi
            _obs_joined=$(printf '%s; ' "${_obs_show[@]}"); _obs_joined=${_obs_joined%'; '}
            msg "[!] Argo origin probe failed (malformed URL, curl rc 3); attempts: $_obs_joined" >&2 || :
            rm -rf -- "$tmpd"
            return 1
        fi
        remaining=$(( deadline_sec - (SECONDS - start_sec) ))
        (( remaining > 0 )) || break
        slp=$(( remaining < 2 ? remaining : 2 ))
        sleep "$slp"
    done
    _obs_show=("${obs_arr[@]}")
    if (( ${#_obs_show[@]} > 6 )); then _obs_show=("${_obs_show[@]: -6}"); fi
    _obs_joined=$(printf '%s; ' "${_obs_show[@]}"); _obs_joined=${_obs_joined%'; '}
    msg "[!] Argo origin probe failed after $i attempt(s) in ~${deadline_sec}s; attempts: $_obs_joined" >&2 || :
    rm -rf -- "$tmpd"
    return 1
}

# R26-H-NF-02: best-effort teardown of a just-started temp Argo
# deployment after a probe/wait failure. The temp units + ws inbounds
# are live at that point; dying without removing them leaks running
# residue with no state and no links (S2 A-AG 2/2). Never fatal: the
# caller's die carries the failure; a cleanup failure is reported,
# not fatal. Callers run under the menu runtime lock, so no concurrent
# deploy can own these fixed temp tags while this runs.
# R16-F09-01: tri-state probe for the temp-cleanup decision.
# _argo_ws_inbound_present <cfg> <tag>: 0 when the inbound tag is
# present in the (JSONC) config, 1 when the config parses and the
# tag is absent, 2 when the answer cannot be determined (missing,
# unreadable or unparsable config, or no inbounds array). Callers
# treat 2 as "keep": deleting on an unknown answer could destroy
# a fixed deployment's origin inbound.
_argo_ws_inbound_present() {
    local _cfg="$1" _tag="$2" _has=''
    [[ -f "$_cfg" && ! -L "$_cfg" && -r "$_cfg" ]] || return 2
    _has=$(jsonc_strip_comments "$_cfg" 2>/dev/null | jq -r --arg t "$_tag" 'if (.inbounds | type) == "array" then (if any(.inbounds[]?; .tag == $t) then "yes" else "no" end) else "unknown" end' 2>/dev/null) || return 2
    case "$_has" in
        yes) return 0 ;;
        no) return 1 ;;
        *) return 2 ;;
    esac
}

argo_temp_cleanup_on_failure() {
    # R16-F09-01: the ws inbounds are SHARED with a fixed deployment
    # (argo_deploy_ws merges them in place, preserving existing
    # users), so they are deleted only when this temp deployment
    # created them. $1/$2 (1 = pre-existing, keep; 0 = created here,
    # delete) come from the deploy_argo_temp snapshot taken before
    # argo_deploy_ws; with no arguments both are kept (fail-closed).
    local _keep_vmess="${1:-1}" _keep_vless="${2:-1}" _del=()
    argo_remove_unit argo-vmess 2>/dev/null || msg "${YELLOW}[!] Argo temp cleanup: the temp VMess unit could not be removed; check it manually.${NC}" >&2
    argo_remove_unit argo-vless 2>/dev/null || msg "${YELLOW}[!] Argo temp cleanup: the temp VLESS unit could not be removed; check it manually.${NC}" >&2
    [[ "$_keep_vmess" == 0 ]] && _del+=(vmess-ws-in)
    [[ "$_keep_vless" == 0 ]] && _del+=(vless-ws-in)
    if (( ${#_del[@]} > 0 )); then
        _remove_inbounds_from_config sing-box "${_del[@]}" 2>/dev/null || msg "${YELLOW}[!] Argo temp cleanup: the temp ws inbounds could not be removed; check them manually.${NC}" >&2
    fi
    return 0
}

deploy_argo_temp() {
    clear; msg "${BOLD}${GREEN}$(tr_msg argo_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check
    install_cloudflared
    local cfg='/etc/sing-box/config.json' tmp_json
    # Minimal sing-box install when the binary is missing.
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-argo) || die "$(tr_msg dp_sb_tmpdir)"
        sb_tar="$sb_tmp/singbox_core.tar.gz"
        sb_ext="$sb_tmp/extract"
        mkdir -p "$sb_ext" || die "$(tr_msg dp_sb_extdir)"
        clear_core_release_resolution SagerNet/sing-box
        fetch_github_release SagerNet/sing-box singbox_core.tar.gz "$sb_tar"
        SB_PATH="$sb_ext/sing-box"
        extract_tar_regular_basename_safely "$sb_tar" sing-box "$SB_PATH" || die "$(tr_msg dp_sb_extract)"
        [[ -f "$SB_PATH" && ! -L "$SB_PATH" ]] || die "$(tr_msg dp_sb_bin)"
        chmod 755 "$SB_PATH" || die 'sing-box staged binary chmod failed.'
        "$SB_PATH" version >/dev/null 2>&1 || die 'sing-box staged binary execution check failed.'
        install_binary_atomically "$SB_PATH" /usr/local/bin/sing-box || die 'sing-box binary atomic install failed.'
        /usr/local/bin/sing-box version >/dev/null 2>&1 || die "$(tr_msg dp_sb_exec)"
        prepare_abox_runtime_config_dir sing-box /etc/sing-box || die 'sing-box config directory preparation failed.'
        rm -rf -- "$sb_tmp"
        # U31/U34: install the seed only when no usable config exists; an
        # existing valid config is kept and merged in place below.
        # R6C9-02: do NOT treat jq-reject as "needs seed": sing-box
        # accepts JSONC comments that jq rejects; seeding here would
        # overwrite a live commented config. A jq-invalid existing
        # config is kept and the merge below fails closed.
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
            install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        fi
        rm -f "$tmp_json"
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
            write_file_atomically_from_stdin /etc/systemd/system/sing-box.service 644 <<'EOF_SVC' || die "$(tr_msg dp_sb_unit)"
# Managed by A-Box
[Unit]
Description=A-Box Sing-Box Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=abox-singbox
Group=abox-singbox
UMask=0077
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
NoNewPrivileges=true
PrivateTmp=true
Restart=always
RestartSec=10
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF_SVC
        else
            path_parent_chain_safe /etc/conf.d/sing-box || die "$(tr_msg dp_orc_parent)"
            mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
            write_file_atomically_from_stdin /etc/conf.d/sing-box 644 <<'EOF_SB_CONFD' || die "$(tr_msg dp_sb_confd)"
rc_ulimit="-n 1048576"
EOF_SB_CONFD
            write_file_atomically_from_stdin /etc/init.d/sing-box 755 <<'EOF_SVC' || die "$(tr_msg dp_sb_initd)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Sing-Box Service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
command_user="abox-singbox:abox-singbox"
capabilities="^cap_net_bind_service"
umask=077
pidfile="/run/sing-box.pid"
depend() { need net; }
EOF_SVC
            chmod +x /etc/init.d/sing-box || die "$(tr_msg dp_sb_chmod)"
        fi
        prepare_abox_runtime_permissions sing-box || die "$(tr_msg dp_sb_runtime)"
    fi
    # R12C9-01: seed a missing config independent of the binary
    # install above: with the binary already present the in-branch
    # seed is skipped, and argo_deploy_ws below dies reading the
    # missing config. An existing config (even jq-invalid JSONC,
    # per R6C9-02) is never overwritten.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        prepare_abox_runtime_config_dir sing-box /etc/sing-box || die 'sing-box config directory preparation failed.'
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi
    # R15-F09-03: a present binary does not imply a service unit
    # exists (interrupted install / deleted unit). Ensure it here,
    # before argo_deploy_ws restarts sing-box (R7-13 precedent on
    # the sing-box deploy path).
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"
    # R16-F09-01: snapshot which ws inbounds already exist before
    # argo_deploy_ws merges the temp ones in place: a pre-existing
    # inbound belongs to the fixed deployment and the failure
    # cleanup below must keep it; only a tag this deploy created
    # may be deleted. An undeterminable answer (rc 2) keeps it.
    local _argo_pre_vmess=1 _argo_pre_vless=1 _argo_pre_rc=0
    _argo_ws_inbound_present "$cfg" vmess-ws-in; _argo_pre_rc=$?
    [[ "$_argo_pre_rc" == 1 ]] && _argo_pre_vmess=0
    _argo_ws_inbound_present "$cfg" vless-ws-in; _argo_pre_rc=$?
    [[ "$_argo_pre_rc" == 1 ]] && _argo_pre_vless=0
    argo_deploy_ws
    argo_write_unit argo-vmess "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:${ARGO_VMESS_PORT}"
    argo_write_unit argo-vless "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:${ARGO_VLESS_PORT}"
    local d1='' d2=''
    d1=$(argo_capture_domain /etc/ddr/argo-vmess.log) || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die "$(tr_msg ag_vmess_domain)"; }
    d2=$(argo_capture_domain /etc/ddr/argo-vless.log) || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die "$(tr_msg ag_vless_domain)"; }
    # R15C9-01: both temp tunnels must prove edge connections BEFORE
    # the fixed deployment is torn down. A domain in the log alone
    # does not prove usability; on failure die here so the fixed
    # unit, token and state stay intact (no dead links published).
    argo_wait_temp_ready argo-vmess /etc/ddr/argo-vmess.log 60 || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die 'Temp Argo VMess tunnel did not establish an edge connection; fixed deployment kept.'; }
    argo_wait_temp_ready argo-vless /etc/ddr/argo-vless.log 60 || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die 'Temp Argo VLESS tunnel did not establish an edge connection; fixed deployment kept.'; }
    # 2qu: edge registration does not prove the origin answers. Probe
    # each temp tunnel's public WebSocket endpoint (expect HTTP 101
    # from the sing-box ws inbound) before tearing down the fixed
    # deployment; a dead origin dies here with the fixed unit, token
    # and state intact (no dead links published).
    argo_origin_probe "$d1" "/${ARGO_UUID}-vmess" || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die 'Temp Argo VMess tunnel origin did not answer the WebSocket probe; fixed deployment kept.'; }
    argo_origin_probe "$d2" "/${ARGO_UUID}-vless" || { argo_temp_cleanup_on_failure "$_argo_pre_vmess" "$_argo_pre_vless"; die 'Temp Argo VLESS tunnel origin did not answer the WebSocket probe; fixed deployment kept.'; }
    # Switching to temp mode: tear down any fixed deployment.
    # R14-F09-02: a failed teardown must not be papered over: the token
    # and the new mode are committed only after the old unit is gone.
    argo_remove_unit argo || die 'Failed to remove the fixed Argo unit; fixed deployment kept.'
    rm -f /etc/ddr/.argo-token
    _argo_state_write "mode=temp
uuid=${ARGO_UUID}
vmess_port=${ARGO_VMESS_PORT}
vless_port=${ARGO_VLESS_PORT}
vmess_domain=${d1}
vless_domain=${d2}"
    # M-20(3): record the expected state like the other standalone
    # deployers, so the health probe and the manual start/stop paths
    # supervise this stack (without it the desired gate never runs).
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"
    msg "${GREEN}$(tr_msg argo_done)${NC}"
    argo_links_for "$d1" "$d2"
    msg "${YELLOW}$(tr_msg argo_temp_note)${NC}"
}

# Wait (bounded) for a fixed tunnel to show an authenticated connection.
# Returns 0 when the log shows a registered tunnel connection and the
# unit is still active; returns 1 on auth failure or timeout. A token
# rejected by Cloudflare must fail the deploy, not commit mode=fixed.
argo_wait_fixed_ready() { # $1=log $2=timeout(sec, default 60)
    local log="$1" timeout="${2:-60}" i _line _fresh_since
    # L-07(D): see argo_capture_domain: only a FRESH 'Registered
    # tunnel connection' line proves the current tunnel; only a fresh
    # auth-failure line fails the wait.
    _fresh_since=$(($(date +%s) - 300))
    for i in $(seq 1 "$timeout"); do
        _line=$(grep -a 'Registered tunnel connection' "$log" 2>/dev/null | tail -1)
        if [[ -n "$_line" ]] && _argo_line_fresh "$_line" "$_fresh_since"; then
            argo_unit_active argo || return 1
            return 0
        fi
        _line=$(grep -aiE 'authentication failed|failed to authenticate|unable to authenticate' "$log" 2>/dev/null | tail -1)
        if [[ -n "$_line" ]] && _argo_line_fresh "$_line" "$_fresh_since"; then
            return 1
        fi
        sleep 1
    done
    return 1
}

# R8C9-05/R8C9-06: EXIT handler for the fixed-Argo token backup.
# Restores the previous token on failure, restores the previous run
# state (restarts a tunnel that was running before the change, stops
# one that was not), then runs the EXIT trap that was installed before
# deploy_argo_fixed (a caller cleanup must not be dropped). The
# saved-trap replay mirrors deployment_transaction_exit_abort; the
# entry status is preserved for the old handler and rollback failures
# are diagnosed without masking the original failure.
_argo_token_exit_restore() {
    local _code=$? _prev_cmd=''
    trap - EXIT
    if [[ "${_argo_token_ok:-0}" != "1" && -n "${_argo_token_bak:-}" && -f "${_argo_token_bak:-}" ]]; then
        if cp -a "${_argo_token_bak}" /etc/ddr/.argo-token 2>/dev/null; then
            # M-10: the backup has served its purpose; drop it now so a
            # successful restore never leaves a stale token copy behind.
            rm -f -- "${_argo_token_bak}" 2>/dev/null || true
            if [[ "${_argo_service_touched:-0}" == "1" ]]; then
                if [[ "${_argo_was_running:-0}" == "1" ]]; then
                    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                        systemctl restart argo.service >/dev/null 2>&1 || msg "${RED}[!] Argo tunnel restart failed during token rollback; the old token was restored but the tunnel may not be running.${NC}"
                    else
                        rc-service argo restart >/dev/null 2>&1 9>&- 10>&- || msg "${RED}[!] Argo tunnel restart failed during token rollback; the old token was restored but the tunnel may not be running.${NC}"
                    fi
                else
                    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                        systemctl stop argo.service >/dev/null 2>&1 || true
                    else
                        rc-service argo stop >/dev/null 2>&1 || true
                    fi
                fi
            fi
        else
            msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"
        fi
    elif [[ "${_argo_token_ok:-0}" != "1" && -z "${_argo_token_bak:-}" ]]; then
        # M-10: first deploy — there is no old token to restore. Delete
        # the newly written token and remove the new unit, so a bad
        # token cannot keep a crash-looping service alive. There is no
        # previous service state to restore to, so the unit is removed
        # rather than restarted whatever _argo_was_running says.
        rm -f -- /etc/ddr/.argo-token 2>/dev/null || true
        if [[ "${_argo_service_touched:-0}" == "1" ]]; then
            argo_remove_unit argo 2>/dev/null || true
        fi
    fi
    if [[ -n "${_argo_prev_trap_exit:-}" ]]; then
        _prev_cmd="${_argo_prev_trap_exit#trap -- }"
        _prev_cmd="${_prev_cmd% *}"
        (exit "$_code")
        eval "eval $_prev_cmd" || true
    fi
}

deploy_argo_fixed() {
    clear; msg "${BOLD}${GREEN}$(tr_msg argo_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check
    local domain='' token=''
    read -r -p "$(tr_msg argo_domain_prompt)" domain || domain=''
    valid_domain "$domain" || die "$(tr_msg ag_bad_domain)"
    IFS= read -r -s -p "$(tr_msg argo_token_prompt)" token || token=''
    msg ''
    [[ -n "$token" ]] || die "$(tr_msg ag_token_empty)"
    valid_single_line_secret "$token" 512 || die "$(tr_msg ag_token_bad)"
    [[ "$token" =~ ^[A-Za-z0-9_+/=.-]+$ ]] || die "$(tr_msg ag_token_bad)"
    install_cloudflared
    # R5C9-02: back up the existing token before overwriting; the
    # EXIT trap restores it on any failure (die exits), and it is
    # cleared only after the fixed tunnel is verified ready.
    local _argo_token_bak='' _argo_token_ok=0 _argo_prev_trap_exit='' _argo_exit_trap_installed=0 _argo_service_touched=0 _argo_was_running=0
    if [[ -f /etc/ddr/.argo-token ]]; then
        _argo_token_bak=$(mktemp /etc/ddr/.argo-token.bak.XXXXXX) || die "Failed to back up the existing Argo token."
        cp -a /etc/ddr/.argo-token "$_argo_token_bak" || die "Failed to back up the existing Argo token."
    fi
    # M-10: register the EXIT trap unconditionally. A first deploy has
    # no old token (_argo_token_bak stays empty); on failure the trap
    # then deletes the newly written (bad) token and removes the new
    # unit instead of restoring a backup.
    _argo_prev_trap_exit=$(trap -p EXIT || true)
    trap '_argo_token_exit_restore' EXIT
    _argo_exit_trap_installed=1
    write_file_atomically_from_stdin /etc/ddr/.argo-token 600 <<< "TUNNEL_TOKEN=${token}" || die "$(tr_msg ag_token_write)"
    local cfg='/etc/sing-box/config.json' tmp_json
    # Minimal sing-box install when the binary is missing.
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-argo) || die "$(tr_msg dp_sb_tmpdir)"
        sb_tar="$sb_tmp/singbox_core.tar.gz"
        sb_ext="$sb_tmp/extract"
        mkdir -p "$sb_ext" || die "$(tr_msg dp_sb_extdir)"
        clear_core_release_resolution SagerNet/sing-box
        fetch_github_release SagerNet/sing-box singbox_core.tar.gz "$sb_tar"
        SB_PATH="$sb_ext/sing-box"
        extract_tar_regular_basename_safely "$sb_tar" sing-box "$SB_PATH" || die "$(tr_msg dp_sb_extract)"
        [[ -f "$SB_PATH" && ! -L "$SB_PATH" ]] || die "$(tr_msg dp_sb_bin)"
        chmod 755 "$SB_PATH" || die 'sing-box staged binary chmod failed.'
        "$SB_PATH" version >/dev/null 2>&1 || die 'sing-box staged binary execution check failed.'
        install_binary_atomically "$SB_PATH" /usr/local/bin/sing-box || die 'sing-box binary atomic install failed.'
        /usr/local/bin/sing-box version >/dev/null 2>&1 || die "$(tr_msg dp_sb_exec)"
        prepare_abox_runtime_config_dir sing-box /etc/sing-box || die 'sing-box config directory preparation failed.'
        rm -rf -- "$sb_tmp"
        # U31/U34: install the seed only when no usable config exists; an
        # existing valid config is kept and merged in place below.
        # R6C9-02: do NOT treat jq-reject as "needs seed": sing-box
        # accepts JSONC comments that jq rejects; seeding here would
        # overwrite a live commented config. A jq-invalid existing
        # config is kept and the merge below fails closed.
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
            install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        fi
        rm -f "$tmp_json"
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
            write_file_atomically_from_stdin /etc/systemd/system/sing-box.service 644 <<'EOF_SVC' || die "$(tr_msg dp_sb_unit)"
# Managed by A-Box
[Unit]
Description=A-Box Sing-Box Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=abox-singbox
Group=abox-singbox
UMask=0077
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
NoNewPrivileges=true
PrivateTmp=true
Restart=always
RestartSec=10
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF_SVC
        else
            path_parent_chain_safe /etc/conf.d/sing-box || die "$(tr_msg dp_orc_parent)"
            mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
            write_file_atomically_from_stdin /etc/conf.d/sing-box 644 <<'EOF_SB_CONFD' || die "$(tr_msg dp_sb_confd)"
rc_ulimit="-n 1048576"
EOF_SB_CONFD
            write_file_atomically_from_stdin /etc/init.d/sing-box 755 <<'EOF_SVC' || die "$(tr_msg dp_sb_initd)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Sing-Box Service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
command_user="abox-singbox:abox-singbox"
capabilities="^cap_net_bind_service"
umask=077
pidfile="/run/sing-box.pid"
depend() { need net; }
EOF_SVC
            chmod +x /etc/init.d/sing-box || die "$(tr_msg dp_sb_chmod)"
        fi
        prepare_abox_runtime_permissions sing-box || die "$(tr_msg dp_sb_runtime)"
    fi
    # R12C9-01: seed a missing config independent of the binary
    # install above: with the binary already present the in-branch
    # seed is skipped, and argo_deploy_ws below dies reading the
    # missing config. An existing config (even jq-invalid JSONC,
    # per R6C9-02) is never overwritten.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        prepare_abox_runtime_config_dir sing-box /etc/sing-box || die 'sing-box config directory preparation failed.'
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi
    # R15-F09-03: a present binary does not imply a service unit
    # exists (interrupted install / deleted unit). Ensure it here,
    # before argo_deploy_ws restarts sing-box (R7-13 precedent on
    # the sing-box deploy path).
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"
    argo_deploy_ws
    if argo_unit_active argo 2>/dev/null; then _argo_was_running=1; fi
    argo_write_unit argo "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run"
    # R13C9-01: restart succeeds before cloudflared authenticates;
    # do not commit mode=fixed until an authenticated connection
    # is seen, or fail the deploy (no state commit, no success).
    # M-10: stop the newly created service explicitly on failure: its
    # unit has Restart=on-failure, so leaving it running would
    # crash-loop on the bad token until the EXIT trap removes it. The
    # trap still runs on die and deletes the bad token.
    if ! argo_wait_fixed_ready /etc/ddr/argo.log 60; then
        # R31-H2: never delete the unit on an UPDATE failure. The
        # EXIT trap restores the old token and restarts the service;
        # with the unit file gone that restart cannot succeed and a
        # working deployment is destroyed. Only a first deploy (no
        # token backup) removes the new unit. Stop the crash-looping
        # service either way so a bad token cannot spin
        # Restart=on-failure until the trap runs.
        if [[ -n "$_argo_token_bak" ]]; then
            if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                systemctl stop argo.service >/dev/null 2>&1 || true
            else
                rc-service argo stop >/dev/null 2>&1 9>&- 10>&- || true
            fi
        else
            argo_remove_unit argo 2>/dev/null || true
        fi
        die 'Fixed Argo tunnel did not become ready (authentication or connection failed); check /etc/ddr/argo.log.'
    fi
    # R5C9-02: fixed tunnel verified; the new token is good, so
    # clear the restore trap and drop the backup. R1-09-C04: only
    # now (fixed ready) delete the temp units, then commit state.
    # R8C9-05: only now (token verified) clear the restore trap —
    # and restore the caller's EXIT trap instead of wiping it.
    # The trap is registered unconditionally now (M-10), so this
    # cleanup always runs once the tunnel is verified ready.
    if (( _argo_exit_trap_installed == 1 )); then
        _argo_token_ok=1
        restore_saved_trap EXIT "$_argo_prev_trap_exit"
        rm -f -- "$_argo_token_bak"
    fi
    # R14-F09-02: both temp units must be gone before the fixed mode is
    # committed; a failed removal keeps the temp state, never a lie.
    argo_remove_unit argo-vmess || die 'Failed to remove the temp Argo VMess unit; temp deployment kept.'
    argo_remove_unit argo-vless || die 'Failed to remove the temp Argo VLESS unit; temp deployment kept.'
    _argo_state_write "mode=fixed
uuid=${ARGO_UUID}
vmess_port=${ARGO_VMESS_PORT}
vless_port=${ARGO_VLESS_PORT}
domain=${domain}"
    # M-20(3): record the expected state like the other standalone
    # deployers, so the health probe and the manual start/stop paths
    # supervise this stack (without it the desired gate never runs).
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"
    msg "${GREEN}$(tr_msg argo_done)${NC}"
    msg "${YELLOW}$(tr_msg argo_fixed_steps)${NC}"
    msg "  ${domain}  path /${ARGO_UUID}-vmess  ->  http://localhost:${ARGO_VMESS_PORT}"
    msg "  ${domain}  path /${ARGO_UUID}-vless  ->  http://localhost:${ARGO_VLESS_PORT}"
    argo_links_for "$domain" "$domain"
}

argo_status() {
    clear; msg "${BOLD}${GREEN}$(tr_msg argo_title)${NC}"
    local mode
    mode=$(_argo_state_get mode)
    if [[ -z "$mode" ]]; then
        msg "${YELLOW}$(tr_msg argo_not_deployed)${NC}"
        return 0
    fi
    ARGO_UUID=$(_argo_state_get uuid)
    ARGO_VMESS_PORT=$(_argo_state_get vmess_port)
    ARGO_VLESS_PORT=$(_argo_state_get vless_port)
    msg "Mode: ${mode} | UUID: ${ARGO_UUID} | VMess-WS: 127.0.0.1:${ARGO_VMESS_PORT} | VLESS-WS: 127.0.0.1:${ARGO_VLESS_PORT}"
    if [[ "$mode" == 'temp' ]]; then
        local u1='' u2='' live1='' live2=''
        argo_unit_active argo-vmess && u1='running' || u1='stopped'
        argo_unit_active argo-vless && u2='running' || u2='stopped'
        msg "argo-vmess: ${u1} | argo-vless: ${u2}"
        # R1-09-C06: Quick Tunnel domains change on restart; the
        # saved state goes stale. Prefer the live domains from
        # the unit logs, falling back to saved state.
        live1=$(grep -aoE '[a-z0-9-]+\.trycloudflare\.com' /etc/ddr/argo-vmess.log 2>/dev/null | grep -v '^api\.trycloudflare\.com$' | tail -1)
        live2=$(grep -aoE '[a-z0-9-]+\.trycloudflare\.com' /etc/ddr/argo-vless.log 2>/dev/null | grep -v '^api\.trycloudflare\.com$' | tail -1)
        [[ -n "$live1" ]] || live1="$(_argo_state_get vmess_domain)"
        [[ -n "$live2" ]] || live2="$(_argo_state_get vless_domain)"
        argo_links_for "$live1" "$live2"
        msg "${YELLOW}$(tr_msg argo_temp_note)${NC}"
    else
        local u=''
        argo_unit_active argo && u='running' || u='stopped'
        msg "argo: ${u}"
        argo_links_for "$(_argo_state_get domain)" "$(_argo_state_get domain)"
    fi
}

# R8C9-09: ownership predicate shared with argo_remove_unit: only an
# /etc unit that exists, is not a symlink and carries the A-Box marker
# may be stopped or removed. A foreign same-name service is left
# running; the strict stop check below then fails the uninstall
# instead of stopping someone else's service.
argo_unit_managed() { # $1 = unit name -> 0 iff A-Box-managed /etc unit
    local unit
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        unit="/etc/systemd/system/${1}.service"
    else
        unit="/etc/init.d/${1}"
    fi
    [[ -f "$unit" && ! -L "$unit" ]] && grep -Fxq '# Managed by A-Box' "$unit" 2>/dev/null
}

# R31-M2: restore the shared sing-box config from the uninstall backup
# and reload it, so a failure after the rewrite does not leave a
# half-uninstalled deployment (argo inbounds gone, backup deleted).
# Consumes the backup (restore_cfg_backup deletes it); safe to call
# when no backup exists. The on-disk config is restored even if the
# reload fails, so the state stays retryable instead of a lie.
_argo_uninstall_restore_cfg() { # $1 = cfg_bak, $2 = cfg
    local _bak="${1:-}" _cfg="${2:-}"
    [[ -n "$_bak" && -f "$_bak" ]] || return 0
    restore_cfg_backup "$_bak" "$_cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"
    restart_service_soft sing-box || true
    return 0
}

argo_uninstall() {
    local ans=''
    read -r -p "$(tr_msg argo_confirm_uninstall)" ans || ans=''
    case "$ans" in
        Y|y) ;;
        *) return 0 ;;
    esac
    # R8C9-09: refuse outright when a same-name service is active
    # but not A-Box-managed, BEFORE any stop, config rewrite or
    # other uninstall side effect: stopping it is forbidden, and
    # proceeding would leave a half-uninstalled state behind the
    # strict stop check below.
    # R11-C (R6-1): the check is argo_unit_stopped_confirmed, so an
    # unconfirmable (unknown) state refuses exactly like an active one.
    local -a _argo_remove_targets=()
    for _u in argo argo-vmess argo-vless; do
        if argo_unit_managed "$_u"; then
            _argo_remove_targets+=("$_u")
        elif ! argo_unit_stopped_confirmed "$_u"; then
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            msg "${YELLOW}[!] Argo unit ${_u} could not be confirmed stopped (${_ARGO_STOPPED_DETAIL:-unknown reason}); refusing to uninstall.${NC}"
            return 1
        fi
    done
    local cfg='/etc/sing-box/config.json' tmp_cfg cfg_bak=''
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        if ! command -v jq >/dev/null 2>&1; then
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            return 1
        fi
        tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        # R31-M1: read through jsonc_strip_comments, like every other
        # Argo reader (_argo_ws_inbound_present). sing-box accepts
        # JSONC comments that jq rejects (R6C9-02); a bare jq read
        # fails the uninstall on a legal commented config. Under
        # pipefail a strip failure also fails the pipeline, so a
        # broken config still fails closed here.
        if jsonc_strip_comments "$cfg" 2>/dev/null | jq '
            # 2ku residual: an inverted rule whose ONLY inbound condition
            # was argo must become FULL-HIT (strip ALL conditions), not
            # NOT(remaining conditions). invert flips the whole match, so
            # once the argo condition is gone the rule matches everything.
            # _strip_conditions keeps only effect fields (sing-box
            # rule_action doc): any condition field, present or future,
            # is dropped by construction (allowlist, not denylist).
            # Logical rules recurse: the transform is compositional, so
            # AND/OR over transformed sub-rules stays faithful. A logical
            # rule that is false before its own invert is dropped — or,
            # when the parent itself is inverted, becomes an unconditional
            # (FULL-HIT) rule keeping the parent effect fields.
            def _keep_fields: ["type","action","outbound","method","no_drop","override_address","override_port","network_strategy","network_type","fallback_network_type","fallback_delay","udp_disable_domain_unmapping","udp_connect","udp_timeout","tls_fragment","tls_fragment_fallback_delay","tls_record_fragment","tls_spoof","tls_spoof_method","sniffer","timeout","server","strategy","disable_cache","disable_optimistic_cache","rewrite_ttl","client_subnet","mode","rules"];
            def _strip_conditions: with_entries(select(.key as $k | _keep_fields | index($k)));
            def _logical_full_hit: _strip_conditions | del(.type, .mode, .rules, .invert);
            def _fixrule:
              if (.type // "default") == "logical" then
                if (.rules | type) == "array" then
                  ((.rules | length) as $n
                   | (.rules |= map(_fixrule))
                   | if (((.mode // "and") == "and" and (.rules | length) < $n)
                         or ((.mode // "and") == "or" and (.rules | length) == 0)) then
                       if (.invert // false) then _logical_full_hit else empty end
                     else select((.rules | length) > 0) end)
                else . end
              elif (.inbound | type) == "string" then
                if (.inbound == "vmess-ws-in" or .inbound == "vless-ws-in") then
                  if (.invert // false) then _strip_conditions else empty end
                else . end
              elif (.inbound | type) == "array" then
                if ((.inbound | index("vmess-ws-in")) != null or (.inbound | index("vless-ws-in")) != null) then
                  (.inbound |= map(select(. != "vmess-ws-in" and . != "vless-ws-in")))
                  | if (.inbound | length) == 0 then
                      if (.invert // false) then _strip_conditions else empty end
                    else . end
                else . end
              else . end;
            .inbounds |= map(select(.tag != "vmess-ws-in" and .tag != "vless-ws-in"))
            | if (.route.rules | type) == "array" then .route.rules |= map(_fixrule) else . end
        ' > "$tmp_cfg" 2>/dev/null \
            && /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1; then
            # R14-F09-05: back up the shared config BEFORE the rewrite:
            # the new config is installed before the permissions setup
            # and the restart, and either step can fail after the old
            # config is already gone (die / return 1, nothing to
            # restore). The backup is consumed by restore on failure
            # and removed on success.
            cfg_bak=$(mktemp /tmp/A-Box-singbox-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
            cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; cfg_bak=''; die 'Config backup failed; refusing to rewrite the shared config without a backup.'; }
            install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f -- "$cfg_bak"; die "$(tr_msg dp_sb_cfg)"; }
            prepare_abox_runtime_permissions sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; die "$(tr_msg dp_sb_runtime)"; }
            restart_service_soft sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"; return 1; }
        else
            rm -f "$tmp_cfg"
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            return 1
        fi
        rm -f "$tmp_cfg"
    fi
    # R1-09-C05: verify the units actually stop BEFORE deleting
    # their files. Checking after deletion is vacuous: a deleted
    # unit reports inactive even when its process survives as
    # an orphan, and uninstall would report success over it.
    # R11-C (R6-1): two phases. Phase 1 stops every frozen managed
    # target unconditionally: the old "worth stopping" gate used
    # argo_unit_active, so a unit whose status query failed was
    # never stopped at all. Phase 2 confirms every frozen target
    # stopped with argo_unit_stopped_confirmed; unknown refuses.
    for _u in "${_argo_remove_targets[@]}"; do
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
            systemctl stop "$_u.service" >/dev/null 2>&1 || true
        else
            rc-service "$_u" stop >/dev/null 2>&1 || true
        fi
    done
    for _u in "${_argo_remove_targets[@]}"; do
        if ! argo_unit_stopped_confirmed "$_u"; then
            _argo_uninstall_restore_cfg "$cfg_bak" "$cfg"
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            msg "${YELLOW}[!] Argo unit ${_u} could not be confirmed stopped (${_ARGO_STOPPED_DETAIL:-unknown reason}); refusing to uninstall.${NC}"
            return 1
        fi
    done
    for _u in "${_argo_remove_targets[@]}"; do
        if ! argo_remove_unit "$_u"; then
            _argo_uninstall_restore_cfg "$cfg_bak" "$cfg"
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            return 1
        fi
    done
    # R6-F08-6: final gate before committing the uninstall. Frozen managed
    # units must be gone (no file, no dangling link); reload so a previous
    # run that deleted files but failed reload can still be retried to green.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || { _argo_uninstall_restore_cfg "$cfg_bak" "$cfg"; msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"; return 1; }
    fi
    local _upath
    for _u in "${_argo_remove_targets[@]}"; do
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then _upath="/etc/systemd/system/${_u}.service"; else _upath="/etc/init.d/${_u}"; fi
        if [[ -e "$_upath" || -L "$_upath" ]]; then
            _argo_uninstall_restore_cfg "$cfg_bak" "$cfg"
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            return 1
        fi
    done
    # R11-C (R6-1): final stop confirmation, AFTER the reload/path
    # re-check above and BEFORE state cleanup: every name must be
    # confirmed stopped (not merely "not active"), so a daemon that
    # survived deletion of its unit file still blocks the uninstall
    # instead of being papered over by deleting state and token.
    # A unit that refused to stop must not be papered over by
    # deleting its state, token and link; state is kept so the
    # uninstall can be retried or the leftover unit inspected.
    for _u in argo argo-vmess argo-vless; do
        if ! argo_unit_stopped_confirmed "$_u"; then
            _argo_uninstall_restore_cfg "$cfg_bak" "$cfg"
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            msg "${YELLOW}[!] Argo unit ${_u} could not be confirmed stopped (${_ARGO_STOPPED_DETAIL:-unknown reason}); refusing to uninstall.${NC}"
            return 1
        fi
    done
    # R31-M2: the shared-config backup lives until this point: every
    # failure above restores it, and only a fully gated uninstall
    # drops it together with the temp file.
    rm -f "$tmp_cfg" "$cfg_bak"
    # R31-M3: credential cleanup must be verified: an unchecked rm
    # reports success while a token or UUID-bearing link survives
    # (read-only fs, immutable flag). Fail instead of printing success.
    if ! rm -f "$ARGO_STATE_FILE" /etc/ddr/.argo-token /etc/ddr/standalone-links.d/argo.link; then
        msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
        return 1
    fi
    for _upath in "$ARGO_STATE_FILE" /etc/ddr/.argo-token /etc/ddr/standalone-links.d/argo.link; do
        if [[ -e "$_upath" || -L "$_upath" ]]; then
            msg "${YELLOW}[!] $(tr_msg dp_argo_uninstall_fail)${NC}"
            return 1
        fi
    done
    # /usr/local/bin/cloudflared is shared with the Wallos CF tunnel
    # and may be a foreign binary install_cloudflared early-returned
    # on (same version, no ownership recorded). Remove it only when
    # A-Box ownership is recorded AND no Wallos tunnel needs it.
    if [[ -f /etc/ddr/.abox-cloudflared-owned && ! -e /etc/systemd/system/abox-wallos-cftunnel.service && ! -e /etc/init.d/abox-wallos-cftunnel ]]; then
        # 05e1-M2: binary first, marker only once the binary is gone
        # (same reason as the do_cleanup block).
        if rm -f /usr/local/bin/cloudflared; then
            rm -f /etc/ddr/.abox-cloudflared-owned || true
        else
            msg "${YELLOW}[!] Failed to remove /usr/local/bin/cloudflared; keeping the ownership marker so the leftover binary can be removed later.${NC}"
        fi
    fi
    msg "${GREEN}$(tr_msg argo_uninstalled)${NC}"
}

argo_menu() {
    local choice
    while true; do
        clear
        msg "${CYAN}============================================================${NC}"
        msg "${BOLD}${GREEN}$(tr_msg argo_title)${NC}"
        msg "${CYAN}1.${NC}  $(tr_msg argo_m_temp)"
        msg "${CYAN}2.${NC}  $(tr_msg argo_m_fixed)"
        msg "${CYAN}3.${NC}  $(tr_msg argo_m_status)"
        msg "${CYAN}4.${NC}  $(tr_msg argo_m_uninstall)"
        msg "${CYAN}0.${NC}  $(tr_msg argo_m_back)"
        read -r -p "$(tr_msg argo_prompt)" choice || choice=0
        choice=$(normalize_fa_ar_digits "${choice:-}")
        case "$choice" in
            1) deploy_argo_temp; pause_return ;;
            2) deploy_argo_fixed; pause_return ;;
            3) argo_status; pause_return ;;
            4) argo_uninstall; pause_return ;;
            0) break ;;
            *) msg "${RED}$(tr_msg invalid_choice)${NC}"; sleep 1 ;;
        esac
    done
}

# Other-protocols entry: standalone Trojan-Reality, free core choice.

# Run a standalone deploy, offering "add another instance" when the
# protocol already exists on that core. Extra instances get tag-<n>
# (and a matching link stem), so inventory, deletion and the
# multi-user manager treat them as independent nodes.
# $1=core $2=base-tag, rest = deploy command
deploy_with_instance_choice() {
    local core="$1" btag="$2"; shift 2
    # xray-latest is retired: refuse before reading config or offering
    # replace/add for a core that no longer exists.
    case "$core" in
        xray-latest) msg "${RED}[!] $(tr_msg inst_retired_xl)${NC}" >&2; return 1 ;;
    esac
    # C2 (Q8): a retired xray-latest instance must be handled before
    # deploying a normal Xray instance (config/choice depends on it).
    if [[ "$core" == 'xray' ]]; then
        xray_latest_legacy_retire || return 1
    fi
    local cfg='' exists=0
    cfg=$(users_cfg_of "$core" 2>/dev/null || true)
    # M-6-rescan (D-leg): strip-once snapshot, built here -- outside the
    # suffix while loop below, which re-reads $cfg per iteration (same
    # _jq_cfg pattern as users_adopt). On strip failure fall back to
    # the raw file (strip failure != read failure); _jq_tmp marks a
    # temp file (safe to delete). No config exists yet: _jq_cfg stays
    # empty and the reads below are guarded by the -f test / exists.
    local _jq_cfg="$cfg" _jq_tmp=0 _jq_caller_trap=''
    if [[ -n "$cfg" && -f "$cfg" && ! -L "$cfg" ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-inst-json.XXXXXX) || _jq_cfg=''
        if [[ -n "$_jq_cfg" ]] && jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null; then
            _jq_tmp=1
        else
            [[ -n "$_jq_cfg" ]] && rm -f -- "$_jq_cfg"
            _jq_cfg="$cfg"
        fi
    fi
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap '(( ${_jq_tmp:-0} == 1 )) && rm -f -- "${_jq_cfg:-}" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
    print_port_occupancy
    if [[ -n "$cfg" && -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$btag" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" >/dev/null 2>&1; then exists=1; fi
    if (( exists == 0 )); then "$@"; return $?; fi
    msg "${YELLOW}$(tr_msg mu_inst_exists) (${btag})${NC}"
    msg "${CYAN}1.${NC} $(tr_msg mu_inst_replace)   ${CYAN}2.${NC} $(tr_msg mu_inst_add)   ${CYAN}0.${NC} $(tr_msg mu_inst_cancel)"
    local ch=''
    read -r -p 'Select [0-2]: ' ch || return 0
    ch=$(normalize_fa_ar_digits "$ch")
    case "$ch" in
        1) "$@" ;;
        2)
            local n=2 _stem=''
            while jq -e --arg t "${btag}-${n}" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" >/dev/null 2>&1; do n=$((n + 1)); done
            msg "${CYAN}$(tr_msg mu_inst_tag): ${btag}-${n} ($(tr_msg mu_inst_port_note))${NC}"
            # M-02: the -2/-3 link stem must be per-core for the shared
            # trojan/socks5 btags, or both cores overwrite the same
            # trojan-landing-2.link / socks5-landing-2.link file.
            # Other btags already point at one core, so keep ${btag}-${n}.
            _stem="${btag}-${n}"
            case "${core}/${btag}" in
                xray/trojan-landing) _stem="trojan-xray-${n}" ;;
                sing-box/trojan-landing) _stem="trojan-sb-${n}" ;;
                xray/socks5-landing) _stem="socks5-xray-${n}" ;;
                sing-box/socks5-landing) _stem="socks5-sb-${n}" ;;
            esac
            ABOX_DEPLOY_TAG="${btag}-${n}" ABOX_DEPLOY_STEM="$_stem" "$@" ;;
        *) msg "$(tr_msg mu_cancelled)"; return 0 ;;
    esac
}

trojan_toolbox_entry() {
    local _core_choice='' _default='1'
    load_optional_abox_env_or_die 2>/dev/null || true
    if [[ "${CORE:-}" == "singbox" ]]; then
        _default='2'
    fi
    read -r -p "$(tr_msg trojan_core_prompt) [${_default}]: " _core_choice || _core_choice=''
    _core_choice="${_core_choice:-$_default}"
    _core_choice=$(normalize_fa_ar_digits "$_core_choice")
    case "$_core_choice" in
        1) deploy_with_instance_choice xray trojan-landing deploy_xray_trojan_landing ;;
        2) deploy_with_instance_choice sing-box trojan-landing deploy_singbox_trojan_landing ;;
        *) msg "${RED}$(tr_msg invalid_input): $_core_choice${NC}"; return 1 ;;
    esac
    # R32-03: keep the deploy rc: the defense line below used to be
    # the function's last command, so a failed deploy read as success
    # whenever the defense mounted fine. Defense still runs on
    # failure; the deploy status is what the function returns.
    local _trojan_rc=$?
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    return "$_trojan_rc"
}
# ============ Main menu info panel (versions / system / nodes / split) ============
# Collected once per main_loop invocation (cached), not per redraw.

# ---- Panel v3 helpers (IP geo + flag) ----
IP_GEO_FILE='/etc/ddr/.ip-geo'

# country code (AU) -> flag emoji (regional indicator pair)

# Fetch IP intelligence into the 24h cache (line format, first line = the IP).
# Source: ip-api.com (free, no key). Fields order = output order.
# ip-api language for the current UI language (fa unsupported -> en).
_geo_lang() {
    case "${ABOX_LANG:-zh}" in
        zh|zh-tw) printf 'zh-CN' ;;
        ja) printf 'ja' ;;
        ru) printf 'ru' ;;
        *) printf 'en' ;;
    esac
}

_ip_geo_refresh() {
    local ip="${GLOBAL_PUBLIC_IP:-}"
    [[ -z "$ip" ]] && return 1
    # Localized country/city names from ip-api (fa unsupported -> en).
    local geo_lang
    geo_lang=$(_geo_lang)
    if [[ -f "$IP_GEO_FILE" && ! -L "$IP_GEO_FILE" ]]; then
        local _cip _clang _now _mt
        IFS= read -r _cip < "$IP_GEO_FILE" 2>/dev/null
        _now=$(date +%s 2>/dev/null || echo 0)
        _mt=$(stat -c %Y "$IP_GEO_FILE" 2>/dev/null || echo 0)
        _clang=$(awk 'NR==12' "$IP_GEO_FILE" 2>/dev/null)
        if [[ "$_cip" == "$ip" && "$_clang" == "$geo_lang" ]]; then
            if (( _now - _mt < 86400 )); then return 0; fi
            # Stale but usable: the panel reads the file as-is; refresh
            # detached so the menu never blocks on the network.
            ( _ip_geo_fetch_now "$ip" "$geo_lang" ) 9>&- 10>&- >/dev/null 2>&1 &
            return 0
        fi
    fi
    # A cache file exists but belongs to another IP/language: refresh
    # detached; the menu never blocks on the network for it.
    if [[ -f "$IP_GEO_FILE" ]]; then
        ( _ip_geo_fetch_now "$ip" "$geo_lang" ) 9>&- 10>&- >/dev/null 2>&1 &
        return 0
    fi
    _ip_geo_fetch_now "$ip" "$geo_lang"
}

# Synchronous geo fetch: the two sources race concurrently and the
# cache file is replaced atomically.
_ip_geo_fetch_now() {
    local ip="$1" geo_lang="$2"
    local resp='' cc2='' tmpd=''
    tmpd=$(mktemp -d /tmp/A-Box-geo.XXXXXX 2>/dev/null) || return 1
    ( curl -fsS --max-time 4 "https://ipwho.is/${ip}?fields=success,country_code" 2>/dev/null | jq -r 'select(.success == true) | .country_code // empty' 2>/dev/null > "$tmpd/cc2" ) &
    resp=$(curl -fsS --max-time 5 "https://ip-api.com/line/${ip}?fields=status,country,countryCode,city,isp,org,as,mobile,hosting&lang=${geo_lang}" 2>/dev/null) || { rm -rf "$tmpd"; return 1; }
    wait
    [[ "$(printf '%s' "$resp" | head -1)" == 'success' ]] || { rm -rf "$tmpd"; return 1; }
    # Second source (ipwho.is) country code, best-effort: only used to flag
    # multi-source country disagreement (broadcast/anycast heuristic).
    cc2=$(cat "$tmpd/cc2" 2>/dev/null || true)
    rm -rf "$tmpd"
    # M-08(4): strip control characters (MITM-injected ANSI escapes)
    # from the upstream response before it is cached; newlines are
    # field separators and are preserved (only tab survives with them).
    resp=$(printf '%s' "$resp" | tr -d '\000-\010\013-\037\177')
    cc2=$(printf '%s' "$cc2" | tr -d '[:cntrl:]')
    local _tmpf
    _tmpf=$(mktemp "${IP_GEO_FILE}.tmp.XXXXXX" 2>/dev/null) || return 1
    printf '%s\n%s\n%s\n%s\n' "$ip" "$resp" "$cc2" "$geo_lang" > "$_tmpf" 2>/dev/null || { rm -f -- "$_tmpf"; return 1; }
    mv -f -- "$_tmpf" "$IP_GEO_FILE" 2>/dev/null || { rm -f -- "$_tmpf"; return 1; }
    return 0
}

_mi_port_listening() {
    # $1 = ss -tuln dump, $2 = port, $3 = protocol (tcp|udp).
    # The protocol column is anchored at line start: without
    # it a TCP listener on the same port would mask a dead UDP
    # service (TUIC) and vice versa. Local-address column only
    # in practice: listener rows carry a wildcard foreign
    # address. The 6? covers ss builds reporting tcp6/udp6.
    [[ -n "$1" && -n "$2" ]] || return 1
    [[ "$3" == tcp || "$3" == udp ]] || return 1
    # R15-F09-04: no `grep -q` here. Under global pipefail, grep -q
    # exits on the first match; with a large listen table and an
    # early match the upstream printf dies on SIGPIPE (rc 141),
    # which the callers read as "not listening". A plain grep drains
    # the whole stream, so no SIGPIPE (R14-F09-01 precedent in
    # _argo_pick_port).
    printf '%s\n' "$1" | grep -E "^${3}6?[[:space:]]+.*[:.]$2[[:space:]]" >/dev/null
}

# Canonical panel order (scheme B): every panel section (nodes, SNI,
# users) sorts by this rank so a node keeps the same relative
# position everywhere. Unknown names rank last, stable.
_panel_rank_of() {
    case "$1" in
        Vision:*) printf '1' ;;
        XHTTP:*) printf '2' ;;
        SS:*) printf '3' ;;
        SOCKS5:*|socks:*) printf '4' ;;
        Trojan:*) printf '5' ;;
        AnyTLS:*) printf '6' ;;
        TUIC:*) printf '7' ;;
        ShadowTLS:*|shadowtls-ss) printf '8' ;;
        Hy2:*) printf '9' ;;
        VMess:*) printf '10' ;;
        VLESS:*) printf '11' ;;
        *) printf '12' ;;
    esac
}

# Stable-sort a '|'-joined cell string by _panel_rank_of.
_panel_sort_cells() {
    local _joined="$1" _c=''
    [[ -n "$_joined" ]] || return 0
    printf '%s\n' "$_joined" | tr '|' '\n' | while IFS= read -r _c; do
        [[ -n "$_c" ]] && printf '%s\t%s\n' "$(_panel_rank_of "$_c")" "$_c"
    done | sort -t "$(printf '\t')" -k1,1n -s | cut -f2- | paste -sd'|' -
}

# SYD-B E18: is a registry entry live? Decided by CONFIG presence,
# not service state: a stopped node still lists, but a registry whose
# inbound is gone from its core config (deleted/pruned/never synced)
# is stale and must not be listed as a node.
users_reg_is_live() {
    local core="$1" tag="$2" cfg=''
    case "$core" in
        xray) cfg=$(users_cfg_of xray 2>/dev/null || true) ;;
        sing-box) cfg='/etc/sing-box/config.json' ;;
        hy2|hysteria)
            [[ -f '/etc/hysteria/config.yaml' && ! -L '/etc/hysteria/config.yaml' ]] && return 0
            return 1 ;;
        *) return 1 ;;
    esac
    [[ -n "$cfg" && -f "$cfg" && ! -L "$cfg" ]] || return 1
    # M-6-rescan (D-leg): single read through the stripped view; raw jq
    # on a commented config returns nothing and the registry entry
    # would wrongly read as stale.
    [[ -n "$(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tag' 2>/dev/null | head -n 1)" ]]
}

_menu_info_collect() {
    [[ -n "${_MI_COLLECTED:-}" ]] && return 0
    _MI_COLLECTED=1

    # AP-01-residual (B-leg): strip-once JSONC views of the two live
    # core configs. Both files may legally carry // or /* */ comments
    # (R16-F05-04/R14-F01-01 class; both cores parse JSONC natively),
    # so every jq below reads the stripped view, never the live file.
    # On strip failure fall back to the raw file (strip failure !=
    # read failure). The views are temp files, removed at the single
    # exit at the end of this function (the only early return is the
    # _MI_COLLECTED guard above, before the views exist).
    local _mi_sb_cfg='/etc/sing-box/config.json' _mi_xr_cfg='/usr/local/etc/xray/config.json'
    local _mi_sb_tmp='' _mi_xr_tmp=''
    if [[ -f "$_mi_sb_cfg" && ! -L "$_mi_sb_cfg" ]]; then
        _mi_sb_tmp=$(mktemp /tmp/A-Box-mi-sb-json.XXXXXX 2>/dev/null || true)
        if [[ -n "$_mi_sb_tmp" ]] && jsonc_strip_comments "$_mi_sb_cfg" > "$_mi_sb_tmp" 2>/dev/null; then
            _mi_sb_cfg="$_mi_sb_tmp"
        else
            [[ -n "$_mi_sb_tmp" ]] && rm -f -- "$_mi_sb_tmp"
            _mi_sb_tmp=''
        fi
    fi
    if [[ -f "$_mi_xr_cfg" && ! -L "$_mi_xr_cfg" ]]; then
        _mi_xr_tmp=$(mktemp /tmp/A-Box-mi-xr-json.XXXXXX 2>/dev/null || true)
        if [[ -n "$_mi_xr_tmp" ]] && jsonc_strip_comments "$_mi_xr_cfg" > "$_mi_xr_tmp" 2>/dev/null; then
            _mi_xr_cfg="$_mi_xr_tmp"
        else
            [[ -n "$_mi_xr_tmp" ]] && rm -f -- "$_mi_xr_tmp"
            _mi_xr_tmp=''
        fi
    fi

    # Slow probes (fail2ban-client/docker/ufw are interpreter CLIs with
    # 0.2-0.8s cold starts) launch concurrently here; results are read
    # back at the original consumption points below. If the temp dir
    # cannot be created, the original serial probes run instead.
    local _mi_pd='' _mi_p_f2='' _mi_p_wl='' _mi_p_di='' _mi_p_uf=''
    _mi_pd=$(mktemp -d /tmp/A-Box-mi.XXXXXX 2>/dev/null || true)
    if [[ -n "$_mi_pd" ]]; then
        ( _v=none; if command -v fail2ban-client >/dev/null 2>&1; then _v=stop; timeout 1 fail2ban-client ping >/dev/null 2>&1 && _v=run; fi; printf '%s' "$_v" > "$_mi_pd/f2" ) </dev/null 9>&- 10>&- &
        _mi_p_f2=$!
        ( _v=none; if command -v docker >/dev/null 2>&1 && timeout 1 docker container inspect wallos >/dev/null 2>&1; then _v=stop; [[ "$(timeout 1 docker inspect -f '{{.State.Running}}' wallos 2>/dev/null)" == 'true' ]] && _v=run; fi; printf '%s' "$_v" > "$_mi_pd/wl" ) </dev/null 9>&- 10>&- &
        _mi_p_wl=$!
        ( _v=''; if command -v docker >/dev/null 2>&1; then _v=stop; timeout 1 docker info >/dev/null 2>&1 && _v=run; fi; printf '%s' "$_v" > "$_mi_pd/di" ) </dev/null 9>&- 10>&- &
        _mi_p_di=$!
        ( _v=''; if command -v ufw >/dev/null 2>&1 && timeout 2 ufw status 2>/dev/null | grep -qi '^Status: active'; then _v=run; fi; printf '%s' "$_v" > "$_mi_pd/uf" ) </dev/null 9>&- 10>&- &
        _mi_p_uf=$!
    fi

    # --- versions + running status (three-state: run/stop/none) ---
    local xv='' sv='' hv='' xrun=0 srun=0 hrun=0
    if [[ -x /usr/local/bin/xray ]]; then
        xv=$(/usr/local/bin/xray version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        xv="${xv#v}"; [[ -z "$xv" ]] && xv='?'
        is_service_running xray 2>/dev/null && xrun=1
    fi
    if [[ -x /usr/local/bin/sing-box ]]; then
        sv=$(/usr/local/bin/sing-box version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        sv="${sv#v}"; [[ -z "$sv" ]] && sv='?'
        is_service_running sing-box 2>/dev/null && srun=1
    fi
    if [[ -x /usr/local/bin/hysteria ]]; then
        hv=$(/usr/local/bin/hysteria version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        hv="${hv#v}"; [[ -z "$hv" ]] && hv='?'
        is_service_running hysteria 2>/dev/null && hrun=1
    fi
    _MI_XV="$xv"; _MI_SV="$sv"; _MI_HV="$hv"
    _MI_XRUN="$xrun"; _MI_SRUN="$srun"; _MI_HRUN="$hrun"
    local xst=none sst=none hst=none
    # fix78: a leftover core binary alone is not a fault. The red
    # "stop" state requires deployment evidence - a live config or an
    # A-Box-managed service unit. Binary-only residue left after a
    # full removal reads as "none", consistent with the nodes row.
    if [[ -x /usr/local/bin/xray ]]; then
        if [[ -s /usr/local/etc/xray/config.json ]] || abox_owns_service xray 2>/dev/null; then xst=stop; fi
        [[ "$xrun" == 1 ]] && xst=run
    fi
    if [[ -x /usr/local/bin/sing-box ]]; then
        if [[ -s /etc/sing-box/config.json ]] || abox_owns_service sing-box 2>/dev/null; then sst=stop; fi
        [[ "$srun" == 1 ]] && sst=run
    fi
    if [[ -x /usr/local/bin/hysteria ]]; then
        if [[ -s /etc/hysteria/config.yaml ]] || abox_owns_service hysteria 2>/dev/null; then hst=stop; fi
        [[ "$hrun" == 1 ]] && hst=run
    fi
    local f2st=none dost=none
    if [[ -n "$_mi_pd" ]]; then
        wait "$_mi_p_f2" 2>/dev/null || true; f2st=$(cat "$_mi_pd/f2" 2>/dev/null || echo none)
        wait "$_mi_p_wl" 2>/dev/null || true; dost=$(cat "$_mi_pd/wl" 2>/dev/null || echo none)
    else
        if command -v fail2ban-client >/dev/null 2>&1; then f2st=stop; timeout 1 fail2ban-client ping >/dev/null 2>&1 && f2st=run; fi
        if command -v docker >/dev/null 2>&1 && timeout 1 docker container inspect wallos >/dev/null 2>&1; then
            dost=stop; [[ "$(timeout 1 docker inspect -f '{{.State.Running}}' wallos 2>/dev/null)" == 'true' ]] && dost=run
        fi
    fi
        # --- standalone protocol listeners (presence + port state) ---
    local tjt='' tut='' ant='' stt='' argo_st='' _ss='' _p='' _t='' _tags=''
    if command -v ss >/dev/null 2>&1; then _ss=$(ss -tuln 2>/dev/null); fi
    if [[ -r /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
        _tags=$(jq -r '(.inbounds // [])[] | select((.tag // "") | test("^(tuic-in|anytls-in|shadowtls-in|trojan-landing)(-[0-9]+)?$")) | "\(.tag) \(.listen_port // empty)"' "$_mi_sb_cfg" 2>/dev/null)
        while read -r _t _p; do
            [[ -n "$_p" ]] || continue
            # Any listening instance wins: a surviving tuic-in-2 must
            # not be hidden by a deleted base instance, and a stopped
            # instance must not mask a running one.
            case "$_t" in
                tuic-in|tuic-in-[0-9]*) _mi_port_listening "$_ss" "$_p" "udp" && tut=run || [[ -n "$tut" ]] || tut=stop ;;
                anytls-in|anytls-in-[0-9]*) _mi_port_listening "$_ss" "$_p" "tcp" && ant=run || [[ -n "$ant" ]] || ant=stop ;;
                shadowtls-in|shadowtls-in-[0-9]*) _mi_port_listening "$_ss" "$_p" "tcp" && stt=run || [[ -n "$stt" ]] || stt=stop ;;
                trojan-landing|trojan-landing-[0-9]*) _mi_port_listening "$_ss" "$_p" "tcp" && tjt=run || [[ -n "$tjt" ]] || tjt=stop ;;
            esac
        done <<< "$_tags"
    fi
    if [[ "$tjt" != 'run' && -r /usr/local/etc/xray/config.json ]] && command -v jq >/dev/null 2>&1; then
        _p=$(jq -r '(.inbounds // [])[] | select(.protocol=="trojan") | (.port // empty)' "$_mi_xr_cfg" 2>/dev/null | head -1)
        if [[ -n "$_p" ]]; then tjt=stop; _mi_port_listening "$_ss" "$_p" "tcp" && tjt=run; fi
    fi
    if [[ -f /etc/ddr/.argo-state ]]; then
        argo_st=stop
        if is_service_running argo 2>/dev/null || is_service_running argo-vmess 2>/dev/null || is_service_running argo-vless 2>/dev/null; then argo_st=run; fi
    fi
    # Cloudflare fronts (panel plan A): Argo tunnels and/or the
    # Wallos CF tunnel - one cell supervises all of them.
    local cf_st=none
    if [[ -f /etc/ddr/.argo-state ]] || [[ "$(wallos_state_value MODE 2>/dev/null || true)" == cftunnel ]]; then cf_st=stop; fi
    if is_service_running argo 2>/dev/null || is_service_running argo-vmess 2>/dev/null || is_service_running argo-vless 2>/dev/null || is_service_running abox-wallos-cftunnel 2>/dev/null; then cf_st=run; fi
    # --- extra probes: traffic / docker / bbr / firewall ---
    local traf='' dock='' bbr='' fwst=''
    # Toggle-type cells: on = run, off/absent = none (red is reserved
    # for installed-but-broken, per the legend).
    if [[ -s "${ABOX_TRAFFIC_PAIR_STATE:-/etc/ddr/.traffic-pair-state}" ]]; then traf=run; fi
    if [[ -n "$_mi_pd" ]]; then
        wait "$_mi_p_di" 2>/dev/null || true; dock=$(cat "$_mi_pd/di" 2>/dev/null || echo '')
    elif command -v docker >/dev/null 2>&1; then dock=stop; timeout 1 docker info >/dev/null 2>&1 && dock=run; fi
    local _cc=''; _cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); _cc=${_cc//[[:space:]]/}
    [[ "$_cc" == "bbr" ]] && bbr=run
    # Any live evidence counts; an installed-but-inactive ufw
    # (Ubuntu default) must not mask A-Box's own rules.
    if [[ -n "$_mi_pd" ]]; then
        wait "$_mi_p_uf" 2>/dev/null || true; fwst=$(cat "$_mi_pd/uf" 2>/dev/null || echo '')
    elif command -v ufw >/dev/null 2>&1 && timeout 2 ufw status 2>/dev/null | grep -qi '^Status: active'; then fwst=run; fi
    if [[ -z "$fwst" ]]; then
        local _ipt=''; _ipt=$(command -v iptables 2>/dev/null || true); [[ -z "$_ipt" && -x /sbin/iptables ]] && _ipt=/sbin/iptables
        if [[ -n "$_ipt" ]] && (( $("$_ipt" -S 2>/dev/null | grep -c .) > 3 )); then fwst=run
        elif command -v nft >/dev/null 2>&1 && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then fwst=run; fi
    fi
    if [[ -z "$fwst" ]] && [[ "${INIT_SYS:-}" == systemd ]] && systemctl is-failed A-Box-firewall.service >/dev/null 2>&1; then fwst=stop; fi
    [[ -n "$_mi_pd" ]] && rm -rf -- "$_mi_pd"
    _MI_XST="$xst"; _MI_SST="$sst"; _MI_HST="$hst"; _MI_F2B="$f2st"; _MI_WALLOS="$dost"; _MI_TROJAN="$tjt"; _MI_TUIC="$tut"; _MI_ANYTLS="$ant"; _MI_STLS="$stt"; _MI_ARGO="$argo_st"; _MI_CF="$cf_st"; _MI_TRAFFIC="$traf"; _MI_DOCKER="$dock"; _MI_BBR="$bbr"; _MI_FW="$fwst"

    # --- system info ---
    local os_name='?' kernel='?' cpu_n='?' cpu_model='' mem_tot='?' mem_used='?'
    local disk_sz='?' disk_kind='' virt='?' up_days='0' ipv6=''
    if [[ -f /etc/os-release ]]; then
        os_name=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 | sed 's/ GNU\/Linux//')
        [[ -z "$os_name" ]] && os_name='?'
    fi
    kernel=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || uname -r)
    cpu_n=$(nproc 2>/dev/null || echo '?')
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//;s/ *$//;s/ Processor//;s/ CPU @ .*//;s/(R)//g;s/(TM)//g')
    cpu_model=$(echo "$cpu_model" | awk '{print $1, $2, $3}')
    if command -v free >/dev/null 2>&1; then
        mem_tot=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.1f", $2/1024}')
        mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.1f", $3/1024}')
        [[ -z "$mem_tot" ]] && mem_tot='?'
    fi
    disk_sz=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')
    [[ -z "$disk_sz" ]] && disk_sz='?'
    if command -v lsblk >/dev/null 2>&1; then
        local _rota
        _rota=$(lsblk -dno ROTA 2>/dev/null | head -1)
        [[ "$_rota" == "0" ]] && disk_kind='SSD'
        [[ "$_rota" == "1" ]] && disk_kind='HDD'
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || echo '?')
    fi
    if [[ -f /proc/uptime ]]; then
        up_days=$(awk '{printf "%d", $1/86400}' /proc/uptime 2>/dev/null)
    fi
    # Global unicast only: drop ULA (fc00::/7) and other non-routable ranges
    ipv6=$(ip -6 addr show scope global 2>/dev/null | grep -oE 'inet6 [0-9a-f:]+' | grep -viE 'inet6 f[cd][0-9a-f]{2}:' | head -1 | awk '{print $2}')
    _MI_OS="$os_name"; _MI_KERNEL="$kernel"; _MI_CPU="$cpu_n"; _MI_CPU_MODEL="$cpu_model"
    _MI_MEM="$mem_tot"; _MI_MEM_USED="$mem_used"; _MI_DISK="$disk_sz"; _MI_DISK_KIND="$disk_kind"
    _MI_VIRT="$virt"; _MI_UP="$up_days"; _MI_IPV6="$ipv6"

    # --- deployed nodes (from live config); SNI captured separately ---
    local nodes='' nodes_x='' nodes_s='' sni=''
    if [[ "$_MI_XRUN" == "1" && -f /usr/local/etc/xray/config.json ]]; then
        nodes_x=$(jq -r '.inbounds[]? | select(.tag != "api") |
            (if .protocol == "vless" and (.settings.clients[0].flow // "" | startswith("xtls")) then "Vision"
             elif .protocol == "vless" and (.streamSettings.network // "") == "xhttp" then "XHTTP"
             elif .protocol == "vless" then "VLESS"
             elif .protocol == "shadowsocks" then "SS"
             elif .protocol == "vmess" then "VMess"
             elif .protocol == "trojan" then "Trojan"
             elif .protocol == "socks" then "SOCKS5"
             else .protocol end) as $n
            | "\($n):\(.port)"' \
            "$_mi_xr_cfg" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
        sni=$(jq -r '[.inbounds[]? | select(.tag != "api") | .streamSettings.realitySettings.serverNames[0] // empty][0] // empty' \
            "$_mi_xr_cfg" 2>/dev/null)
    fi
    if [[ "$_MI_SRUN" == "1" && -f /etc/sing-box/config.json ]]; then
        nodes_s=$(jq -r '.inbounds[]? | select(((.tag // "") | test("^(shadowtls-ss|shadowtls-in(-[0-9]+)?-ss)$") | not) and .tag != "vmess-ws-in" and .tag != "vless-ws-in") |
            (if .type == "vless" then "VLESS" elif .type == "shadowsocks" then "SS"
             elif .type == "hysteria2" then "Hy2" elif .type == "mixed" then "SOCKS5"
             elif .type == "socks" then "SOCKS5" elif .type == "tuic" then "TUIC" elif .type == "anytls" then "AnyTLS" elif .type == "shadowtls" then "ShadowTLS" else .type end) as $n
            | "\($n):\(.listen_port)"' "$_mi_sb_cfg" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    fi
    nodes="${nodes_x:+$nodes_x|}${nodes_s}"
    nodes="${nodes%|}"
    # Hy2: separate service; port + hop range from env
    local hy2_note=''
    if [[ "$_MI_HRUN" == "1" ]]; then
        if load_abox_env "$ABOX_ENV" 2>/dev/null; then
            [[ -n "${HY2_BASE_PORT:-}" ]] && hy2_note="Hy2:${HY2_BASE_PORT}"
            if [[ "${HY2_HOP:-}" == true && -n "${HY2_RANGE_START:-}" && -n "${HY2_RANGE_END:-}" ]]; then
                hy2_note="${hy2_note:+$hy2_note }$(tprintf mi_hy2_hop "${HY2_RANGE_START}-${HY2_RANGE_END}")"
            fi
        fi
    fi
    [[ -n "$hy2_note" ]] && nodes="${nodes:+$nodes|}$hy2_note"
    [[ -n "$nodes" ]] && nodes=$(_panel_sort_cells "$nodes")
    _MI_NODES="$nodes"; _MI_SNI="$sni"
    # --- per-node SNI list (grouped by SNI) for the detail block ---
    _MI_SNI_LIST=''
    local _sni_rows=''
    _sni_rows=$( {
        if [[ "$_MI_XRUN" == "1" && -f /usr/local/etc/xray/config.json ]]; then
            jq -r '.inbounds[]? | select(.tag != "api") | (.streamSettings.realitySettings.serverNames[0] // empty) as $sn | select($sn != "") |
                (if .protocol == "vless" and (.settings.clients[0].flow // "" | startswith("xtls")) then "Vision:\(.port)"
                 elif .protocol == "vless" and (.streamSettings.network // "") == "xhttp" then "XHTTP:\(.port)"
                 elif .protocol == "vless" then "VLESS:\(.port)"
                 elif .protocol == "trojan" then "Trojan:\(.port)"
                 elif .protocol == "vmess" then "VMess:\(.port)" else empty end) + "\t" + $sn' "$_mi_xr_cfg" 2>/dev/null
        fi
        if [[ "$_MI_SRUN" == "1" && -f /etc/sing-box/config.json ]]; then
            jq -r '.inbounds[]? | select(((.tag // "") | test("^(shadowtls-ss|shadowtls-in(-[0-9]+)?-ss)$") | not)) |
                (if .type == "vless" then ((.tls.reality.handshake.server // .tls.server_name // empty)) as $sn | select($sn != "") | "VLESS:\(.listen_port)\t\($sn)"
                 elif .type == "anytls" then ((.tls.reality.handshake.server // .tls.server_name // empty)) as $sn | select($sn != "") | "AnyTLS:\(.listen_port)\t\($sn)"
             elif .type == "trojan" then ((.tls.reality.handshake.server // .tls.server_name // empty)) as $sn | select($sn != "") | "Trojan:\(.listen_port)\t\($sn)"
                 elif .type == "tuic" then ((.tls.server_name // empty)) as $sn | select($sn != "") | "TUIC:\(.listen_port)\t\($sn)"
                 elif .type == "shadowtls" then ((.handshake.server // empty)) as $sn | select($sn != "") | "ShadowTLS:\(.listen_port)\t\($sn)"
                 else empty end)' "$_mi_sb_cfg" 2>/dev/null
        fi
    } 2>/dev/null )
    if [[ -n "$_sni_rows" ]]; then
        _MI_SNI_LIST=$(printf '%s\n' "$_sni_rows" | awk -F '\t' '!seen[$1 "|" $2]++ {printf "%s%s %s", (n++ ? "|" : ""), $1, $2}')
        [[ -n "$_MI_SNI_LIST" ]] && _MI_SNI_LIST=$(_panel_sort_cells "$_MI_SNI_LIST")
    fi
    # --- multi-user summary (registries of the toolbox manager) ---
    # Reset up front: when the registry set becomes empty the branch
    # below is skipped, and a stale global would keep showing deleted
    # users across menu cycles.
    _MI_USER_RECS=''
    _MI_USERS_N=0; _MI_USERS_BLOCKED=0; _MI_USERS_USED=0
    local _udir="${ABOX_USERS_DIR:-/etc/ddr/users.d}" _rf='' _us=''
    local -a _rfiles=()
    local _oc
    for _oc in xray sing-box hy2; do
        for _rf in "$_udir/${_oc}__"*.json; do [[ -f "$_rf" && ! -L "$_rf" ]] && _rfiles+=("$_rf"); done
    done
    if (( ${#_rfiles[@]} > 0 )); then
        _us=$(jq -s -r '[.[].users[]?] as $u | "\($u | length) \($u | map(select((.blocked // "") != "" or .disabled == true)) | length) \($u | map((.used_up // 0) + (.used_down // 0)) | add // 0)"' "${_rfiles[@]}" 2>/dev/null || true)
        read -r _MI_USERS_N _MI_USERS_BLOCKED _MI_USERS_USED <<< "${_us:-0 0 0}"
        # Per-node user records for the panel detail section:
        # SEG\t<segment> / USR\t<name>\t<used bytes>\t<mark>.
        local _rcore='' _rtag='' _rseg='' _rcfg='' _ut='' _usegbuf='' _uhit=0
        # Order registries like the live configs (grid order):
        # per core, inbounds in config order; leftovers by filename.
        local -a _ordered_rf=()
        local _ocore='' _otags='' _ot='' _orf=''
        for _ocore in xray sing-box hy2; do
            case "$_ocore" in
                xray) _otags=$(jq -r '.inbounds[]?.tag' "$_mi_xr_cfg" 2>/dev/null) ;;
                sing-box) _otags=$(jq -r '.inbounds[]?.tag' "$_mi_sb_cfg" 2>/dev/null) ;;
                hy2) _otags='hy2' ;;
            esac
            for _ot in $_otags; do
                # D1: tags go through the encoder — a raw build never
                # matches an encoded filename for a '/' or '%' tag.
                _orf="$_udir/$(users_reg_encode_component "$_ocore")__$(users_reg_encode_component "$_ot").json"
                [[ -f "$_orf" && ! -L "$_orf" ]] && _ordered_rf+=("$_orf")
            done
        done
        local _seen_rf=0 _of=''
        for _rf in "${_rfiles[@]}"; do
            _seen_rf=0
            for _of in "${_ordered_rf[@]}"; do [[ "$_of" == "$_rf" ]] && { _seen_rf=1; break; }; done
            (( _seen_rf )) || _ordered_rf+=("$_rf")
        done
        for _rf in "${_ordered_rf[@]}"; do
            _rcore=$(jq -r '.core // ""' "$_rf" 2>/dev/null)
            _rtag=$(jq -r '.tag // ""' "$_rf" 2>/dev/null)
            _rseg="$_rtag"
            # SYD-B E18: a registry whose inbound no longer exists
            # in its core config is stale and must not be listed
            # as a node. Config presence, not service state,
            # decides: a stopped node still lists.
            users_reg_is_live "$_rcore" "$_rtag" 2>/dev/null || continue
            case "$_rcore" in
                xray)
                    _rcfg='/usr/local/etc/xray/config.json'
                    if [[ -f "$_rcfg" ]]; then
                        _rseg=$(jq -r --arg t "$_rtag" '.inbounds[]? | select(.tag == $t) | select(.port != null) |
                            (if .protocol == "vless" and (.settings.clients[0].flow // "" | startswith("xtls")) then "Vision:\(.port)"
                             elif .protocol == "vless" and (.streamSettings.network // "") == "xhttp" then "XHTTP:\(.port)"
                             elif .protocol == "vless" then "VLESS:\(.port)"
                             elif .protocol == "shadowsocks" then "SS:\(.port)"
                             elif .protocol == "trojan" then "Trojan:\(.port)"
                             elif .protocol == "hysteria2" then "Hy2:\(.port)"
                             else "\(.protocol):\(.port)" end)' "$_mi_xr_cfg" 2>/dev/null)
                        [[ -z "$_rseg" ]] && _rseg="$_rtag"
                    fi ;;
                sing-box)
                    if [[ -f /etc/sing-box/config.json ]]; then
                        _rseg=$(jq -r --arg t "$_rtag" '.inbounds[]? | select(.tag == $t) | select(.listen_port != null) |
                            (if .type == "vless" then "VLESS:\(.listen_port)"
                             elif .type == "shadowsocks" then "SS:\(.listen_port)"
                             elif .type == "tuic" then "TUIC:\(.listen_port)"
                             elif .type == "anytls" then "AnyTLS:\(.listen_port)"
                             elif .type == "shadowtls" then "ShadowTLS:\(.listen_port)"
                             elif .type == "hysteria2" then "Hy2:\(.listen_port)"
                             else "\(.type):\(.listen_port)" end)' "$_mi_sb_cfg" 2>/dev/null)
                        [[ -z "$_rseg" ]] && _rseg="$_rtag"
                        if [[ "$_rtag" == 'shadowtls-ss' ]]; then
                            local _stp=''
                            _stp=$(jq -r '[.inbounds[]? | select(.type == "shadowtls") | .listen_port // empty][0] // empty' "$_mi_sb_cfg" 2>/dev/null)
                            [[ -z "$_stp" ]] && _stp=$(jq -r --arg t "$_rtag" '[.inbounds[]? | select(.tag == $t) | .listen_port // empty][0] // empty' "$_mi_sb_cfg" 2>/dev/null)
                            [[ -n "$_stp" ]] && _rseg="ShadowTLS:$_stp"
                        fi
                    fi ;;
                hy2) _rseg="Hy2:${HY2_BASE_PORT:-?}" ;;
            esac
            _usegbuf=$'SEG\t'"${_rseg}"$'\n'; _uhit=0
            while IFS= read -r _ut; do
                if [[ -n "$_ut" ]]; then _usegbuf+=$'USR\t'"${_ut}"$'\n'; _uhit=1; fi
            done < <(jq -r '(.core // "") as $c | .users[]? | select((.blocked // "") == "" and (.disabled // false) != true) | ([.name, (if $c == "sing-box" then "-" else (((.used_up // 0) + (.used_down // 0)) | tostring) end), (if .disabled == true then "disabled" elif (.blocked // "") != "" then "blocked" else "" end), (if (.expire_at // 0) == 0 then "F" elif (.expire_at // 0) <= now then "E" else (((.expire_at // 0) - now) / 86400 | ceil | tostring) end), (if $c == "sing-box" then "0" else (((.quota_gb // 0) * 1073741824) | floor | tostring) end)] | join("|"))' "$_rf" 2>/dev/null)
            (( _uhit )) && _MI_USER_RECS+="$_usegbuf"
        done
        # Scheme B: reorder segment blocks by the canonical rank
        # (stable; orphan registries keep their relative order last).
        if [[ -n "$_MI_USER_RECS" ]]; then
            local -a _blks=() _ord=()
            local _cur='' _l='' _i=0 _rk='' _oi=''
            while IFS= read -r _l; do
                case "$_l" in
                    SEG$'\t'*)
                        [[ -n "$_cur" ]] && _blks+=("$_cur")
                        _cur="$_l" ;;
                    *) _cur+=$'\n'"$_l" ;;
                esac
            done <<< "$_MI_USER_RECS"
            [[ -n "$_cur" ]] && _blks+=("$_cur")
            if (( ${#_blks[@]} > 1 )); then
                _ord=()
                for _i in "${!_blks[@]}"; do
                    _rk=$(_panel_rank_of "${_blks[$_i]#SEG$'\t'}")
                    [[ "$_rk" =~ ^[0-9]+$ ]] || _rk=12
                    _ord+=("$_rk $_i")
                done
                _MI_USER_RECS=''
                while read -r _rk _oi; do
                    _MI_USER_RECS+="${_blks[$_oi]}"$'\n'
                done < <(printf '%s\n' "${_ord[@]}" | sort -k1,1n -k2,2n -s)
            fi
        fi

    fi

    # SOCKS5 service state: config presence x service running state.
    # (The old nodes gate only collected live configs while a core was
    # running, so a stopped core read as "not deployed".)
    _MI_SOCKS_ST='none'
    if { [[ -f /usr/local/etc/xray/config.json ]] && jq -e '.inbounds[]? | select(.protocol == "socks")' "$_mi_xr_cfg" >/dev/null 2>&1; } \
       || { [[ -f /etc/sing-box/config.json ]] && jq -e '.inbounds[]? | select(.type == "socks" or .type == "mixed")' "$_mi_sb_cfg" >/dev/null 2>&1; }; then
        _MI_SOCKS_ST='stop'
        if [[ "$_MI_XRUN" == "1" && -f /usr/local/etc/xray/config.json ]] \
           && jq -e '.inbounds[]? | select(.protocol == "socks")' "$_mi_xr_cfg" >/dev/null 2>&1; then
            _MI_SOCKS_ST='run'
        elif [[ "$_MI_SRUN" == "1" && -f /etc/sing-box/config.json ]] \
             && jq -e '.inbounds[]? | select(.type == "socks" or .type == "mixed")' "$_mi_sb_cfg" >/dev/null 2>&1; then
            _MI_SOCKS_ST='run'
        fi
    fi

    # --- split/WARP status + exits (display labels; SOCKS5 inbound is separate) ---
    local warp_st='' rule_n=0 exits=''
    if [[ -f "$ROUTING_STATE_FILE" ]]; then
        routing_outbound_has_live 'warp-out' 2>/dev/null && warp_st='on'
        rule_n=$(jq '.rules | length' "$ROUTING_STATE_FILE" 2>/dev/null || echo 0)
        local _tag _lbl
        while IFS= read -r _tag; do
            [[ -z "$_tag" ]] && continue
            case "$_tag" in
                warp-out) _lbl='WARP' ;;
                socks-land*) _lbl="$(tr_msg mi_land)${_tag#socks-land}" ;;
                *) _lbl="$_tag" ;;
            esac
            exits+="${exits:+ }$_lbl"
        done < <(jq -r '.outbounds[]?.tag' "$ROUTING_STATE_FILE" 2>/dev/null)
    fi
    _MI_WARP="$warp_st"; _MI_RULES="$rule_n"; _MI_EXITS="$exits"

    # --- DNS (current resolvers + transport mode) ---
    _MI_DNS4=''; _MI_DNS6=''; _MI_DNSMODE=''
    _MI_DNS4=$(_dns_current_v4 2>/dev/null || true)
    _MI_DNS6=$(_dns_current_v6 2>/dev/null || true)
    local _dnsmode=''
    if [[ -f "$DNS_STATE_FILE" && ! -L "$DNS_STATE_FILE" ]]; then
        _dnsmode=$(awk -F';' '{for(i=1;i<=NF;i++){if($i ~ /^[ \t]*mode=/){sub(/^[ \t]*mode=/, "", $i); gsub(/["'"'"'\r\t ]/, "", $i); print $i; exit}}}' "$DNS_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ -z "$_dnsmode" ]]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && grep -qE '^[ \t]*nameserver[ \t]+127\.0\.0\.1' /etc/resolv.conf 2>/dev/null; then
            _dnsmode='doh'
        elif grep -qs '^DNSOverTLS=yes' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf 2>/dev/null; then
            _dnsmode='dot'
        else
            _dnsmode='plain'
        fi
    fi
    case "$_dnsmode" in
        dot) _MI_DNSMODE='DoT' ;;
        doh) _MI_DNSMODE='DoH' ;;
        *) _MI_DNSMODE="$(tr_msg mi_dns_plain)" ;;
    esac
    if [[ "$_dnsmode" == 'doh' && -z "$_MI_DNS4" && -z "$_MI_DNS6" && -r /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]]; then
        _MI_DNS4=$(grep -E '^server_names' /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null | grep -oE "'[^']+'" | head -1 | tr -d "'")
    fi

    # --- IP intelligence (flag / country / city / hosting type / origin) ---
    _MI_FLAG=''; _MI_BADGE=''; _MI_GEO_COUNTRY=''; _MI_GEO_CITY=''; _MI_GEO_KIND=''; _MI_GEO_ORIGIN=''
    _ip_geo_refresh || true
    if [[ -f "$IP_GEO_FILE" ]]; then
        local _gip _gst _gcountry _gcc _gcity _gmob _ghost _gas _gisp _gorg _gcc2 _glang
        { IFS= read -r _gip; IFS= read -r _gst; IFS= read -r _gcountry; IFS= read -r _gcc
          IFS= read -r _gcity; IFS= read -r _gisp; IFS= read -r _gorg; IFS= read -r _gas
          IFS= read -r _gmob; IFS= read -r _ghost; IFS= read -r _gcc2; IFS= read -r _glang
        } < "$IP_GEO_FILE" 2>/dev/null
        # M-08(4): strip control characters from every cached geo field
        # before any use or display (defense in depth with the fetch
        # filter above: a cache written by an older version may still
        # hold control characters).
        _gcountry=$(printf '%s' "$_gcountry" | tr -d '[:cntrl:]')
        _gcity=$(printf '%s' "$_gcity" | tr -d '[:cntrl:]')
        _gisp=$(printf '%s' "$_gisp" | tr -d '[:cntrl:]')
        _gorg=$(printf '%s' "$_gorg" | tr -d '[:cntrl:]')
        _gas=$(printf '%s' "$_gas" | tr -d '[:cntrl:]')
        # A cache written under another UI language holds foreign-language
        # country/city names; skip the geo suffix for this panel open (a
        # detached refresh is already running) instead of showing them.
        if [[ "$_gip" == "${GLOBAL_PUBLIC_IP:-}" && "$_gst" == 'success' && "$_glang" == "$(_geo_lang)" ]]; then
            _MI_GEO_COUNTRY="$_gcountry"
            _MI_GEO_CITY="$_gcity"
            # Datacenter call (A-Check approach): vendor/hosting keywords in
            # the AS+ISP+Org text outrank ip-api's bare hosting flag, which
            # mislabels several cloud ranges as residential.
            local _gtext _gdc=0
            _gtext=$(printf '%s %s %s' "$_gas" "$_gisp" "$_gorg" | tr '[:upper:]' '[:lower:]')
            case "$_gtext" in
                *amazon*|*google*|*microsoft*|*azure*|*alibaba*|*tencent*|*huawei\ cloud*|*oracle*|*digitalocean*|*linode*|*vultr*|*ovh*|*hetzner*|*contabo*|*leaseweb*|*choopa*|*datacenter*|*data\ center*|*data\ centre*|*hosting*|*vps*|*dedicated*|*colocation*|*cloudflare*|*akamai*|*fastly*|*scaleway*|*upcloud*|*kamatera*|*hostwinds*|*bandwagon*|*buyvm*|*frantech*|*serverius*|*selectel*|*worldstream*|*psychz*|*quadranet*) _gdc=1 ;;
            esac
            if [[ "$_gmob" == 'true' ]]; then _MI_GEO_KIND=$(tr_msg mi_cell)
            elif [[ "$_ghost" == 'true' || "$_gdc" == '1' ]]; then _MI_GEO_KIND=$(tr_msg mi_dc)
            else _MI_GEO_KIND=$(tr_msg mi_res); fi
            # Broadcast call: known anycast ASNs, or the two sources disagree
            # on the country (multi-source mismatch heuristic from A-Check).
            case "$_gas" in
                *'AS13335'*|*'AS209242'*|*'Cloudflare'*) _MI_GEO_ORIGIN=$(tr_msg mi_anycast) ;;
                *) if [[ -n "$_gcc2" && -n "$_gcc" && "$_gcc2" != "$_gcc" ]]; then _MI_GEO_ORIGIN=$(tr_msg mi_anycast); else _MI_GEO_ORIGIN=$(tr_msg mi_native); fi ;;
            esac
        fi
    fi

    # AP-01-residual (B-leg): drop the strip-once views built at the top.
    [[ -n "$_mi_sb_tmp" ]] && rm -f -- "$_mi_sb_tmp" 2>/dev/null
    [[ -n "$_mi_xr_tmp" ]] && rm -f -- "$_mi_xr_tmp" 2>/dev/null
}

# One matrix cell: [ name(padded) dot ]
_mi_cell() {
    local nm="$1" st="$2" dot
    case "$st" in
        run) dot="${GREEN}●${NC}" ;;
        stop) dot="${RED}●${NC}" ;;
        *) dot='○' ;;
    esac
    printf '[ %s%-11s%s %s ]' "$CYAN" "$nm" "$NC" "$dot"
}

# A-BOX pixel banner: 5x5 glyphs, blue gradient (electric -> deep -> cyan),
# boxed by electric-blue double lines. Pixel = 2 foreground full blocks
# (background-colored spaces vanish on terminals that skip cell backgrounds).
_menu_banner() {
    # FIGlet 'ANSI Shadow' line art, A-Check palette, static segments.
    local _eq='════════════════════════════════════════════════════════════════════════════════'
    local _cA=$'\033[38;2;0;95;215m' _cH=$'\033[38;2;0;95;255m' _cB=$'\033[38;2;0;135;215m' _cO=$'\033[38;2;0;135;255m' _cX=$'\033[38;2;0;175;255m'
    local _pad='         '
    printf '\033[38;2;0;170;255m%s\033[0m\n' "$_eq"
    printf '%s' "${_pad}${_cA} █████╗       ${_cH}             ${_cB}██████╗      ${_cO} ██████╗      ${_cX}██╗  ██╗${NC}"; printf '\n'
    printf '%s' "${_pad}${_cA}██╔══██╗      ${_cH}             ${_cB}██╔══██╗     ${_cO}██╔═══██╗     ${_cX}╚██╗██╔╝${NC}"; printf '\n'
    printf '%s' "${_pad}${_cA}███████║      ${_cH}             ${_cB}██████╔╝     ${_cO}██║   ██║     ${_cX} ╚███╔╝ ${NC}"; printf '\n'
    printf '%s' "${_pad}${_cA}██╔══██║      ${_cH}██████╗      ${_cB}██╔══██╗     ${_cO}██║   ██║     ${_cX} ██╔██╗ ${NC}"; printf '\n'
    printf '%s' "${_pad}${_cA}██║  ██║      ${_cH}╚═════╝      ${_cB}██████╔╝     ${_cO}╚██████╔╝     ${_cX}██╔╝╚██╗${NC}"; printf '\n'
    printf '%s' "${_pad}${_cA}╚═╝  ╚═╝      ${_cH}             ${_cB}╚═════╝      ${_cO} ╚═════╝      ${_cX}╚═╝  ╚═╝${NC}"; printf '\n'
    printf '\033[38;2;0;170;255m%s\033[0m\n' "$_eq"
}

# Display the info panel (v3: status matrix + spaced rows, two-color scheme).
_menu_info_display() {
    _menu_info_collect || return 0
    # --- status matrix: fixed 16 cells, always shown, 4 per row ---
    local _mrow='  ' _sep=''
    local _warp_st=none; [[ -n "$_MI_WARP" ]] && _warp_st=run
    local _cells=(
        "Xray|${_MI_XST:-none}" "sing-box|${_MI_SST:-none}" "Hy2|${_MI_HST:-none}"
        "Trojan|${_MI_TROJAN:-none}" "TUIC|${_MI_TUIC:-none}" "AnyTLS|${_MI_ANYTLS:-none}"
        "ShadowTLS|${_MI_STLS:-none}" "SOCKS5|${_MI_SOCKS_ST:-none}" "WARP|$_warp_st"
        "Cloudflare|${_MI_CF:-none}" "Fail2ban|${_MI_F2B:-none}" "Wallos|${_MI_WALLOS:-none}"
        "Traffic|${_MI_TRAFFIC:-none}" "Docker|${_MI_DOCKER:-none}" "BBR|${_MI_BBR:-none}"
        "Firewall|${_MI_FW:-none}"
    )
    local _c _nm _st _n=0
    for _c in "${_cells[@]}"; do
        _nm="${_c%%|*}"; _st="${_c##*|}"
        if (( _n == 4 )); then
            msg "$_mrow"; _mrow='  '; _sep=''; _n=0
        fi
        _mrow+="${_sep}$(_mi_cell "$_nm" "$_st")"; _sep='  '; _n=$((_n + 1))
    done
    msg "$_mrow"
    printf '\033[38;2;0;170;255m%s\033[0m\n' '════════════════════════════════════════════════════════════════════════════════'
    # --- system / hardware ---
    msg "  ${CYAN}$(tr_msg mi_system)：${NC}  ${LBLW}${_MI_OS} · $(tr_msg mi_kernel) ${_MI_KERNEL} · ${_MI_VIRT} · $(tprintf mi_uptime "$_MI_UP")${NC}"
    msg ''
    msg "  ${CYAN}$(tr_msg mi_hw)：${NC}  ${LBLW}${_MI_CPU_MODEL} (${_MI_CPU}$(tr_msg mi_cores)) · $(tr_msg mi_mem) ${_MI_MEM_USED}/${_MI_MEM}G · $(tr_msg mi_disk) ${_MI_DISK}${_MI_DISK_KIND:+ $_MI_DISK_KIND}${NC}"
    msg ''
    # --- network (IPv4 with geo, IPv6) ---
    local _v4dot='○' _geo='' _netpad=''
    # Continuation rows (IPv6/DNS) start in the IPv4 column of the label
    # row: 2 leading spaces + label display width + fullwidth colon (2)
    # + 2 spaces. A fixed indent only aligns when the label is 4 wide.
    printf -v _netpad '%*s' $(( $(_str_dwidth "$(tr_msg mi_net)") + 6 )) ''
    [[ -n "${GLOBAL_PUBLIC_IP:-}" ]] && _v4dot="${GREEN}●${NC}"
    if [[ -n "$_MI_GEO_COUNTRY" ]]; then
        _geo=" ${_MI_GEO_COUNTRY}${_MI_GEO_CITY:+ · ${_MI_GEO_CITY}} · ${_MI_GEO_KIND} · ${_MI_GEO_ORIGIN}"
    fi
    msg "  ${CYAN}$(tr_msg mi_net)：${NC}  ${LBLW}IPv4${NC} ${_v4dot} ${LBLW}${GLOBAL_PUBLIC_IP:-?}${_geo}${NC}"
    if [[ -n "$_MI_IPV6" ]]; then
        msg "${_netpad}${LBLW}IPv6${NC} ${GREEN}●${NC} ${LBLW}${_MI_IPV6}${NC}"
    else
        msg "${_netpad}${LBLW}IPv6${NC} ○ ${GRAY}$(tr_msg mi_none)${NC}"
    fi
    if [[ -n "${_MI_DNS4:-}" || -n "${_MI_DNS6:-}" || -n "${_MI_DNSMODE:-}" ]]; then
        local _dnsv4="${_MI_DNS4:-$(tr_msg mi_none)}" _dnsv6="${_MI_DNS6:-$(tr_msg mi_none)}"
        msg "${_netpad}${LBLW}DNS${NC}  ${LBLW}IPv4 ${_dnsv4} · IPv6 ${_dnsv6}${_MI_DNSMODE:+ · ${_MI_DNSMODE}}${NC}"
    fi
    msg ''
    # --- panel sections, scheme C stacking: users, then nodes
    # (fixed grid), then SNI nested at the end of the nodes block ---
    if [[ -n "${_MI_USER_RECS:-}" || -n "$_MI_NODES" ]]; then
        if [[ -z "${_MI_USER_RECS:-}" ]]; then
            msg "  ${CYAN}$(tr_msg mi_users)：${NC}  ${LBLW}$(tr_msg mi_users_none)${NC}"
        else
            local _urec='' _useg='' _usw=10 _ucnt=0 _unm='' _uused='' _umark='' _utok='' _uexp='' _uqta=0
            local -a _usegs=()
            local _usegtxt='' _ucont=''
            while IFS= read -r _urec; do
                [[ "$_urec" == SEG$'\t'* ]] || continue
                _useg="${_urec#SEG$'\t'}"
                (( ${#_useg} > _usw )) && _usw=${#_useg}
            done <<< "$_MI_USER_RECS"
            (( _usw > 22 )) && _usw=22
            while IFS= read -r _urec; do
                [[ -z "$_urec" ]] && continue
                if [[ "$_urec" == SEG$'\t'* ]]; then
                    [[ -n "$_usegtxt" ]] && _usegs+=("$_usegtxt")
                    _useg="${_urec#SEG$'\t'}"
                    printf -v _usegtxt '%-*s  ' "$_usw" "$_useg"
                    _ucnt=0
                elif [[ "$_urec" == USR$'\t'* ]]; then
                    IFS='|' read -r _unm _uused _umark _uexp _uqta <<< "${_urec#USR$'\t'}"
                    if [[ "$_uused" == '-' || "${_uused:-0}" == '0' ]]; then
                        _utok="$_unm -"
                    else
                        _utok="$_unm $(users_fmt_bytes "${_uused:-0}")"
                        (( ${_uqta:-0} > 0 )) && _utok+="/$(users_fmt_bytes "$_uqta")"
                    fi
                    case "${_uexp:-F}" in
                        F) ;;  # nothing set: name + used only (user rule 2026-10-21)
                        E) _utok+=" · $(tr_msg mi_u_expired)" ;;
                        *[!0-9]*|'') ;;
                        *) _utok+=" · $(tprintf mi_u_days "$_uexp")" ;;
                    esac
                    [[ "$_umark" == 'blocked' ]] && _utok+=" · $(tr_msg mi_u_blocked)"
                    [[ "$_umark" == 'disabled' ]] && _utok+=" · $(tr_msg mi_u_disabled)"
                    if (( _ucnt >= 3 )); then
                        printf -v _ucont '%-*s  ' "$_usw" ''
                        _usegtxt+=$'\n'"$_ucont"
                        _ucnt=0
                    fi
                    if (( _ucnt > 0 )); then _usegtxt+=" · $_utok"; else _usegtxt+="$_utok"; fi
                    _ucnt=$((_ucnt + 1))
                fi
            done <<< "$_MI_USER_RECS"
            [[ -n "$_usegtxt" ]] && _usegs+=("$_usegtxt")
            # Fixed-column grid (same language as the node grid):
            # single-line segments are cells of one shared width,
            # 3 or 2 per row; multi-line segments keep their own line.
            local _cw=0 _pseg='' _uall='' _cols=3
            for _pseg in "${_usegs[@]}"; do
                [[ "$_pseg" == *$'\n'* ]] && continue
                (( ${#_pseg} > 37 )) && continue
                (( ${#_pseg} > _cw )) && _cw=${#_pseg}
            done
            if (( _cw > 37 )); then _cols=1
            elif (( _cw > 24 )); then _cols=2
            fi
            local -a _row=()
            local _cell='' _line=''
            for _pseg in "${_usegs[@]}"; do
                if [[ "$_pseg" == *$'\n'* ]] || (( ${#_pseg} > 37 )); then
                    if (( ${#_row[@]} > 0 )); then
                        _line=''
                        for _cell in "${_row[@]}"; do
                            if [[ -z "$_line" ]]; then printf -v _line '%-*s' "$_cw" "$_cell"; else printf -v _line '%s | %-*s' "$_line" "$_cw" "$_cell"; fi
                        done
                        _uall+="${_line%"${_line##*[! ]}"}"$'\n'
                        _row=()
                    fi
                    _uall+="$_pseg"$'\n'
                else
                    _row+=("$_pseg")
                    if (( ${#_row[@]} >= _cols )); then
                        _line=''
                        for _cell in "${_row[@]}"; do
                            if [[ -z "$_line" ]]; then printf -v _line '%-*s' "$_cw" "$_cell"; else printf -v _line '%s | %-*s' "$_line" "$_cw" "$_cell"; fi
                        done
                        _uall+="${_line%"${_line##*[! ]}"}"$'\n'
                        _row=()
                    fi
                fi
            done
            if (( ${#_row[@]} > 0 )); then
                _line=''
                for _cell in "${_row[@]}"; do
                    if [[ -z "$_line" ]]; then printf -v _line '%-*s' "$_cw" "$_cell"; else printf -v _line '%s | %-*s' "$_line" "$_cw" "$_cell"; fi
                done
                _uall+="${_line%"${_line##*[! ]}"}"$'\n'
            fi
            local _ufirst=1 _upline='' _upad=''
            printf -v _upad '%*s' $(( $(_str_dwidth "$(tr_msg mi_users)") + 6 )) ''
            while IFS= read -r _upline; do
                [[ -z "$_upline" ]] && continue
                if (( _ufirst )); then msg "  ${CYAN}$(tr_msg mi_users)：${NC}  ${LBLW}${_upline}${NC}"; _ufirst=0
                else msg "${_upad}${LBLW}${_upline}${NC}"; fi
            done <<< "$_uall"
        fi
        msg ''
    fi

    if [[ -n "$_MI_NODES" ]]; then
        local _lbl="$(tr_msg mi_nodes)" _seg _row='' _cnt=0 _first=1
        local _segs _rows=()
        IFS='|' read -r -a _segs <<< "$_MI_NODES"
        # Fixed-column grid: pad every column to the widest segment
        # (14..20) so node columns align vertically on every row.
        local _w=14 _cell
        for _seg in "${_segs[@]}"; do (( ${#_seg} > _w )) && _w=${#_seg}; done
        (( _w > 20 )) && _w=20
        local _rsegs=()
        for _seg in "${_segs[@]}"; do
            [[ -z "$_seg" ]] && continue
            _rsegs+=("$_seg")
            if (( ${#_rsegs[@]} == 3 )); then
                printf -v _row '%-*s | %-*s | %s' "$_w" "${_rsegs[0]}" "$_w" "${_rsegs[1]}" "${_rsegs[2]}"
                _rows+=("$_row"); _rsegs=()
            fi
        done
        if (( ${#_rsegs[@]} == 2 )); then printf -v _row '%-*s | %s' "$_w" "${_rsegs[0]}" "${_rsegs[1]}"; _rows+=("$_row")
        elif (( ${#_rsegs[@]} == 1 )); then _rows+=("${_rsegs[0]}"); fi
        local _i _n=${#_rows[@]} _npad=''
        printf -v _npad '%*s' $(( $(_str_dwidth "$_lbl") + 6 )) ''
        for (( _i=0; _i<_n; _i++ )); do
            _row="${_rows[$_i]}"
            if (( _first )); then msg "  ${CYAN}${_lbl}：${NC}  ${LBLW}${_row}${NC}"; _first=0
            else msg "${_npad}${LBLW}${_row}${NC}"; fi
        done
        [[ -n "$_MI_SNI_LIST" ]] && msg ''
        if [[ -n "$_MI_SNI_LIST" ]]; then
            local _se='' _sents=() _sseg='' _ssni='' _sw=14
            IFS='|' read -r -a _sents <<< "$_MI_SNI_LIST"
            for _se in "${_sents[@]}"; do
                [[ -z "$_se" ]] && continue
                _sseg="${_se%% *}"
                (( ${#_sseg} > _sw )) && _sw=${#_sseg}
            done
            (( _sw > 22 )) && _sw=22
            local _si=0
            for _se in "${_sents[@]}"; do
                [[ -z "$_se" ]] && continue
                _sseg="${_se%% *}"; _ssni="${_se#* }"
                if (( _si == 0 )); then msg "  ${CYAN}SNI：${NC}   ${LBLW}$(printf '%-*s' "$_sw" "$_sseg")  ${_ssni}${NC}"
                else msg "          ${LBLW}$(printf '%-*s' "$_sw" "$_sseg")  ${_ssni}${NC}"; fi
                _si=$((_si + 1))
            done
        fi
    else
        msg "  ${CYAN}$(tr_msg mi_nodes)：${NC}  ${LBLW}$(tr_msg mi_no_nodes)${NC}"
    fi
    msg ''
    # --- legend ---
    msg "  ${CYAN}$(tr_msg mi_state)：  ${GREEN}●${NC} ${LBLW}$(tr_msg mi_run)  ·  ○ ${LBLW}$(tr_msg mi_off)${NC}  ·  ${RED}●${NC} ${LBLW}$(tr_msg mi_fault)${NC}        ${LBLW}$(tr_msg mi_quick_r)${NC}"
    printf '\033[38;2;0;170;255m%s\033[0m\n' '════════════════════════════════════════════════════════════════════════════════'
}

# ============ WARP 与分流管理 (routing state + WARP one-click) ============
# State file persists custom outbounds + routing rules across redeploys.
# Builders (build_xray_config / build_singbox_config) merge this state in.
ROUTING_STATE_FILE='/etc/ddr/.routing-state'
WGCF_BIN='/usr/local/bin/wgcf'

routing_state_init() {
    if [[ -f "$ROUTING_STATE_FILE" && ! -L "$ROUTING_STATE_FILE" ]]; then
        return 0
    fi
    [[ ! -e "$ROUTING_STATE_FILE" ]] || return 1
    local tmp _rs_dir
    _rs_dir=$(dirname -- "$ROUTING_STATE_FILE")
    [[ -d "$_rs_dir" ]] || install -d -m 755 -- "$_rs_dir" || return 1
    tmp=$(mktemp "$_rs_dir/.routing-state.XXXXXX") || return 1
    printf '%s\n' '{"version":1,"outbounds":[],"rules":[]}' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$ROUTING_STATE_FILE" || { rm -f "$tmp"; return 1; }
}

routing_state_put() {
    local tmp
    routing_state_init || return 1
    tmp=$(mktemp "$(dirname -- "$ROUTING_STATE_FILE")/.routing-state.XXXXXX") || return 1
    if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
    # R32-01: slurp and require exactly one JSON object. Bare `jq -e`
    # reports the LAST doc of a multi-doc stream, so a bad doc
    # followed by a good one passed and the whole stream was mv'd
    # into state. Empty input, null/array docs and extra docs all
    # fail here (fail closed).
    jq -s -e 'length == 1 and (.[0] | type == "object") and (.[0].version == 1) and ((.[0].outbounds | type) == "array") and ((.[0].rules | type) == "array")' \
        "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$ROUTING_STATE_FILE" || { rm -f "$tmp"; return 1; }
}

routing_outbound_has() {
    local tag="$1"
    [[ -n "$tag" ]] || return 1
    # R6C9-04: 'direct' is sing-box's built-in outbound, but Xray
    # requires it declared in its config, and it is never registered
    # in the routing state file. Do not hardcode it as present: when
    # an Xray config exists, verify it actually declares direct
    # (JSONC-aware, since Xray accepts comments); a missing direct
    # means the rule would fail core validation at apply time.
    # No Xray config means sing-box-only: verify the tag in the
    # sing-box config below (R8C9-10) — type "direct" is not a tag.
    if [[ "$tag" == 'direct' ]]; then
        if [[ -f /usr/local/etc/xray/config.json && ! -L /usr/local/etc/xray/config.json ]]; then
            # jq -e zero-output exits 4, not 1: normalize to 0/1.
            jsonc_strip_comments /usr/local/etc/xray/config.json 2>/dev/null | jq -e --arg t 'direct' '.outbounds[]? | select(.tag == $t)' >/dev/null 2>&1 && return 0 || return 1
        elif [[ -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json ]]; then
            # R8C9-10: sing-box-only: type "direct" is not a tag;
            # the tag must actually be declared (JSONC-aware, like
            # the Xray branch). A missing tag, or an unreadable
            # config, is absent — the tag is never assumed present.
            jsonc_strip_comments /etc/sing-box/config.json 2>/dev/null | jq -e --arg t 'direct' '.outbounds[]? | select(.tag == $t)' >/dev/null 2>&1 && return 0 || return 1
        else
            return 1
        fi
    fi
    routing_state_init || return 1
    jq -e --arg t "$tag" '.outbounds[]? | select(.tag == $t)' \
        "$ROUTING_STATE_FILE" >/dev/null 2>&1
}

# R16-F09-02: the routing state file is not the whole truth about live
# outbounds: a tag may exist in a core config without being registered
# (hand-added, or state lost). Numbering that only consults the state
# file would reuse such a tag and the next routing_apply_live would
# silently replace the unmanaged outbound. Check both live configs
# (JSONC-aware, like the 'direct' branch above). Callers that only
# need managed-state membership keep using routing_outbound_has.
routing_outbound_has_live() {
    local tag="$1" cfg=''
    [[ -n "$tag" ]] || return 1
    for cfg in /usr/local/etc/xray/config.json /etc/sing-box/config.json; do
        [[ -f "$cfg" && ! -L "$cfg" ]] || continue
        # sing-box stores wireguard outbounds (e.g. warp-out) in
        # .endpoints, not .outbounds; without this a live WARP reads
        # as "not in effect" even while it is serving traffic.
        jsonc_strip_comments "$cfg" 2>/dev/null | jq -e --arg t "$tag" '(.outbounds[]?, .endpoints[]?) | select(.tag == $t)' >/dev/null 2>&1 && return 0
    done
    return 1
}

# R32-02: exactly one JSON object, nothing else. `jq empty` accepts
# empty input (rc 0) and --slurpfile then yields [], so $x[0]/$s[0]
# are null and a null outbound would be committed as success.
_routing_single_object_file() { # $1 = file -> 0 iff exactly one JSON object
    [[ -f "$1" && ! -L "$1" ]] || return 1
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

# $1=tag, $2=xray outbound JSON file, $3=singbox outbound JSON file (idempotent)
routing_outbound_add() {
    local tag="$1" xf="$2" sf="$3" tmp rc
    [[ -n "$tag" && -f "$xf" && -f "$sf" && ! -L "$xf" && ! -L "$sf" ]] || return 1
    _routing_single_object_file "$xf" || return 1
    _routing_single_object_file "$sf" || return 1
    routing_state_init || return 1
    tmp=$(mktemp) || return 1
    jq --arg t "$tag" --slurpfile x "$xf" --slurpfile s "$sf" \
        '.outbounds |= (map(select(.tag != $t)) + [{tag:$t, xray:$x[0], singbox:$s[0]}])' \
        "$ROUTING_STATE_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    routing_state_put < "$tmp"; rc=$?; rm -f "$tmp"; return $rc
}

# $1=tag (also drops rules referencing it)
routing_outbound_del() {
    local tag="$1" tmp rc
    [[ -n "$tag" ]] || return 1
    routing_state_init || return 1
    tmp=$(mktemp) || return 1
    jq --arg t "$tag" \
        '.outbounds |= map(select(.tag != $t)) | .rules |= map(select(.outbound != $t))' \
        "$ROUTING_STATE_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    routing_state_put < "$tmp"; rc=$?; rm -f "$tmp"; return $rc
}

# $1=comma-separated domains (geosite:xxx or plain), $2=outbound tag
routing_rule_add() {
    local domains_csv="$1" outbound="$2" tmp rc
    [[ -n "$domains_csv" && -n "$outbound" ]] || return 1
    # U41: a commas-only list parses to an empty domain array, which sing-box
    # treats as an unconditional rule; reject it so no caller can create one.
    [[ -n "${domains_csv//,/}" ]] || return 1
    routing_outbound_has "$outbound" || return 1
    routing_state_init || return 1
    tmp=$(mktemp) || return 1
    jq --arg d "$domains_csv" --arg o "$outbound" '
        ($d | split(",") | map(select(length > 0))) as $doms
        | if $doms == ["all"] then
            .rules += [{
                domains: $doms, outbound: $o,
                xray_rule: {type:"field", network:"tcp,udp", outboundTag:$o},
                singbox_rule: {outbound:$o, network:["tcp","udp"]}
            }]
          else
            ($doms | map(select(startswith("geosite:")) | ltrimstr("geosite:"))) as $geo
            | ($doms | map(select(startswith("geosite:") | not))) as $plain
            | .rules += [{
                domains: $doms, outbound: $o,
                xray_rule: {type:"field", domain: ($doms | map(if startswith("geosite:") then . else "domain:" + . end)), outboundTag:$o},
                singbox_rule: ({outbound:$o}
                    + (if ($geo|length) > 0 then {rule_set: ($geo | map("geosite-" + .))} else {} end)
                    + (if ($plain|length) > 0 then {domain_suffix:$plain} else {} end))
              }]
          end
    ' "$ROUTING_STATE_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    routing_state_put < "$tmp"; rc=$?; rm -f "$tmp"; return $rc
}

# $1=0-based rule index
# 05a-M2: bash $((10#N)) wraps modulo 2^64 (2^64 -> 0, 2^64+1 -> 1)
# and 2^63 wraps negative, so a pure-digit check is not enough: an
# over-long index would wrap and delete the wrong rule (or report a
# deletion that never happened). Return 0 only when the value fits in
# a signed 64-bit integer: strip leading zeros, then at most 18
# significant digits (an 18-digit number is always < 2^63-1).
decimal_fits_int64() {
    local _v="${1:-}" _sig
    _sig="${_v#"${_v%%[!0]*}"}"
    [[ "${#_sig}" -le 18 ]]
}

routing_rule_del() {
    local idx="$1" tmp rc
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    decimal_fits_int64 "$idx" || return 1
    idx=$((10#$idx))
    routing_state_init || return 1
    # Out-of-range indices are a caller error, not a no-op success:
    # jq del() silently keeps the array, which made the menu report
    # a deletion that never happened.
    jq -e --argjson i "$idx" '.rules | length > $i' "$ROUTING_STATE_FILE" >/dev/null 2>&1 || return 1
    tmp=$(mktemp) || return 1
    jq --argjson i "$idx" 'del(.rules[$i])' \
        "$ROUTING_STATE_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    routing_state_put < "$tmp"; rc=$?; rm -f "$tmp"; return $rc
}

routing_rules_clear() {
    local tmp rc
    routing_state_init || return 1
    tmp=$(mktemp) || return 1
    jq '.rules = []' "$ROUTING_STATE_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    routing_state_put < "$tmp"; rc=$?; rm -f "$tmp"; return $rc
}

# F-NEW-02: refuse a remote rule-set URL that provably does not exist
# (HTTP 404) before it can reach the live config. sing-box only
# downloads remote rule-sets at startup, so a 404 kills the service
# after the apply has already committed; sing-box check cannot see it
# (it only validates structure). Any other fetch failure (timeout,
# 5xx, no network) is not treated as proof of non-existence: the
# stability check after restart is the backstop there, and a transient
# network blip must not block routing.
# $1 = merged sing-box config file. Prints the offending URL on 404.
routing_ruleset_urls_ok() {
    local cfg="$1" url code
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        code=$(curl -s -o /dev/null -w '%{http_code}' -I --connect-timeout 5 --max-time 10 -- "$url" 2>/dev/null) || code='000'
        if [[ "$code" == '404' ]]; then
            msg "${RED}[!] $(tr_msg warp_apply_fail)${NC}"
            msg "${RED}[!] ${url}${NC}"
            return 1
        fi
    # M-6-rescan (D-leg): read the remote rule-set URLs through the
    # stripped view; raw jq on a commented config yields no URLs and a
    # 404 rule-set would sail through unchecked.
    done < <(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r '.route.rule_set[]? | select(.type == "remote") | .url // empty' 2>/dev/null)
    return 0
}

# F-NEW-02: stability check for the post-restart commit point.
# restart_service_soft only samples is-active once, 2s after restart;
# a service that FATALs just after that sample (e.g. a remote rule-set
# 404, which sing-box only hits while initializing) was still committed
# as "applied". Require the service to stay active across several
# samples AND its systemd restart counter to stay flat across the
# window: a FATAL followed by a Restart=always auto-restart inside the
# window fails the check instead of being reported as success.
# $1 = service name (xray|sing-box). Non-systemd hosts fall back to
# repeated status probes.
routing_service_stable() {
    local srv="$1" i base now
    case "$srv" in xray|sing-box) ;; *) return 1 ;; esac
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        base=$(systemctl show -p NRestarts --value "$srv" 2>/dev/null || echo '')
        for i in 1 2 3; do
            sleep 3
            systemctl is-active --quiet "$srv" || return 1
        done
        now=$(systemctl show -p NRestarts --value "$srv" 2>/dev/null || echo '')
        if [[ "$base" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then
            (( now == base )) || return 1
        fi
        return 0
    fi
    for i in 1 2 3; do
        sleep 2
        rc-service "$srv" status >/dev/null 2>&1 || return 1
    done
    return 0
}

# Surgically merge routing state into the LIVE config file, validate, restart.
# $1 = xray | singbox (defaults to $CORE). The argument is a preference,
# not an absolute: the effective core is resolved from the live core
# config actually on disk (see below), so a stale .env CORE (e.g.
# "hysteria" after an attach deploy that never wrote .env) cannot fail
# the apply before it touches live.
# R33-03: shared applied-record commit + restart-gate transaction for
# routing_apply_live, used by the xray and sing-box branches (which
# were byte-identical apart from the service name). $1 = service name
# (xray | sing-box), $2 = live config path, $3 = live backup file,
# $4 = applied-record path, $5 = applied-record backup file (empty when
# no applied record existed). Commits the new .applied record, then
# restarts only when the gate permits; on any failure the live config
# and the applied record are rolled back, so the next apply still sees
# the old record and re-pushes the policy.
_routing_commit_applied_and_restart() {
    local core="$1" cfg="$2" live_bak="$3" applied_file="$4" applied_bak="$5"
    local atmp=''
    if ! atmp=$(mktemp); then
        if cp -f -- "$live_bak" "$cfg" 2>/dev/null && prepare_abox_runtime_permissions "$core" 2>/dev/null; then
            rm -f -- "$live_bak" "$applied_bak"
        else
            msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"
        fi
        msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"
        return 1
    fi
    # R16-F09-03: refuse a directory $applied_file target:
    # `mv -f file dir/` succeeds by moving the record INTO the
    # dir, so without this guard the code walks past the commit
    # point with no record file and later rule deletions cannot
    # retire the still-live rules. Failure routes to the
    # existing rollback below.
    if [[ ! -d "$applied_file" ]] && jq -c '{outbounds:[.outbounds[].tag], rules_xray:[.rules[]? | (.xray_rule // empty)], rules_singbox:[.rules[]? | (.singbox_rule // empty) | (if has("geosite") then (.rule_set = (((.rule_set) // []) + (.geosite | map("geosite-" + .))) | del(.geosite)) else . end)]}' "$ROUTING_STATE_FILE" > "$atmp" 2>/dev/null && mv -f "$atmp" "$applied_file" 2>/dev/null; then
        :
    else
        rm -f "$atmp"
        local _rb_ok=1
        cp -f -- "$live_bak" "$cfg" 2>/dev/null || _rb_ok=0
        prepare_abox_runtime_permissions "$core" 2>/dev/null || _rb_ok=0
        if [[ -n "$applied_bak" ]]; then
            cp -f -- "$applied_bak" "$applied_file" 2>/dev/null || _rb_ok=0
        else
            rm -f -- "$applied_file"
        fi
        if (( _rb_ok == 1 )); then
            rm -f -- "$live_bak" "$applied_bak"
        else
            msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"
        fi
        msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"
        return 1
    fi
    # Commit point: the new .applied record and the new live
    # config are only committed after permissions + restart
    # both succeed. On failure both are rolled back (live
    # config from live_bak, .applied from applied_bak or
    # removed when there was none), so the next apply still
    # sees the old record and re-pushes the policy.
    # H-23 (Carbon R3): restart only when the desired state is
    # RUNNING and the service was running before the apply; the
    # new config and .applied record are already on disk, so a
    # stopped stack stays stopped instead of being revived (or
    # rolled back when the restart fails on a down service).
    if service_restart_permitted "$core"; then
        if prepare_abox_runtime_permissions "$core" && restart_service_soft "$core" && routing_service_stable "$core"; then
            rm -f -- "$live_bak" "$applied_bak"
        else
            cp -f -- "$live_bak" "$cfg" 2>/dev/null || { msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; return 1; }
            if [[ -n "$applied_bak" ]]; then
                cp -f -- "$applied_bak" "$applied_file" 2>/dev/null || { msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; return 1; }
            else
                rm -f -- "$applied_file"
            fi
            if prepare_abox_runtime_permissions "$core" && restart_service_soft "$core"; then
                rm -f -- "$live_bak" "$applied_bak"
            else
                return 1
            fi
            return 1
        fi
    else
        # Gate closed: the new config and .applied record
        # are already committed on disk; just drop the
        # backup temp files instead of rolling back.
        rm -f -- "$live_bak" "$applied_bak"
    fi
}
routing_apply_live() {
    local core='' cfg tmp force_json='[]'
    if [[ $# -gt 0 ]]; then core="$1"; shift; fi
    [[ -n "$core" ]] || core="${CORE:-}"
    # F-NEW-02/L3-11-5: dispatch on the live core config actually on
    # disk, not on the .env CORE value. CORE can lag (e.g. it stays
    # "hysteria" after a sing-box TUIC attach deploy that never wrote
    # .env), and hysteria has no outbound-merge branch at all, so a
    # stale CORE used to fail every apply before touching live.
    # Prefer the requested core when its config exists; otherwise fall
    # back to whichever live config exists (xray first); fail only
    # when neither exists.
    local _live_xray='/usr/local/etc/xray/config.json' _live_sb='/etc/sing-box/config.json'
    local _has_xray=0 _has_sb=0
    [[ -f "$_live_xray" && ! -L "$_live_xray" ]] && _has_xray=1
    [[ -f "$_live_sb" && ! -L "$_live_sb" ]] && _has_sb=1
    case "$core" in
        xray) (( _has_xray == 1 )) || { (( _has_sb == 1 )) && core='singbox' || return 1; } ;;
        singbox|sing-box) (( _has_sb == 1 )) || { (( _has_xray == 1 )) && core='xray' || return 1; } ;;
        *) if (( _has_xray == 1 )); then core='xray'; elif (( _has_sb == 1 )); then core='singbox'; else return 1; fi ;;
    esac
    if (( $# > 0 )); then
        force_json=$(printf '%s\n' "$@" | jq -R . | jq -sc . 2>/dev/null) || return 1
    fi
    # Per-core applied records (S57): xray and sing-box must not share
    # one retirement record, or the second core's apply reads a $prev
    # already rewritten by the first and misses retirements. Read and
    # write targets are split on purpose: a missing per-core file
    # reads the legacy shared record once (migration), but the write
    # ALWAYS goes to the per-core file — otherwise the first apply
    # would overwrite the legacy record with the current state and
    # the second core would never see the old $prev (proven by the
    # S57 fixture: single-variable design fails A2/A3/A4).
    local applied_file="${ROUTING_STATE_FILE}.applied"
    case "$core" in
        xray) applied_file="${ROUTING_STATE_FILE}.applied-xray" ;;
        singbox|sing-box) applied_file="${ROUTING_STATE_FILE}.applied-singbox" ;;
    esac
    local applied_src="$applied_file"
    if [[ ! -f "$applied_src" && -f "${ROUTING_STATE_FILE}.applied" ]]; then
        applied_src="${ROUTING_STATE_FILE}.applied"
    fi
    routing_state_init || return 1
    # Tags applied by the previous run: members dropped from the
    # state since then are retired from the live config instead of
    # lingering as orphans (e.g. warp-out after warp_undeploy, which
    # deletes the state entry before re-applying).
    local prev_applied='[]' prev_rules_xray='[]' prev_rules_singbox='[]'
    if [[ -f "$applied_src" ]]; then
        if ! jq empty "$applied_src" >/dev/null 2>&1; then
            msg "${RED}[!] $(tr_msg warp_applied_corrupt)${NC}"
            return 1
        fi
        # R33-02: the applied record must be an array (legacy) or an
        # object whose outbounds/rules_* fields, when present, are
        # arrays. The old `|| printf '[]'` fallback swallowed a type
        # error (e.g. .outbounds = 42 makes map fail) into empty
        # history, so retirements were missed and the next commit
        # overwrote the record, losing the history. A type error now
        # fails the apply like a syntax error: live config and the
        # record stay untouched. Missing/null fields still mean
        # "no history"; non-string array members are still filtered.
        if ! prev_applied=$(jq -c -e 'if type == "array" then map(select(type == "string")) elif type == "object" then ((.outbounds // []) | if type == "array" then map(select(type == "string")) else error("applied .outbounds is not an array") end) else error("applied record is not an array or object") end' "$applied_src" 2>/dev/null); then
            msg "${RED}[!] $(tr_msg warp_applied_corrupt)${NC}"
            return 1
        fi
        if ! prev_rules_xray=$(jq -c -e 'if type == "object" then ((.rules_xray // []) | if type == "array" then . else error("applied .rules_xray is not an array") end) else [] end' "$applied_src" 2>/dev/null); then
            msg "${RED}[!] $(tr_msg warp_applied_corrupt)${NC}"
            return 1
        fi
        if ! prev_rules_singbox=$(jq -c -e 'if type == "object" then ((.rules_singbox // []) | if type == "array" then . else error("applied .rules_singbox is not an array") end) else [] end' "$applied_src" 2>/dev/null); then
            msg "${RED}[!] $(tr_msg warp_applied_corrupt)${NC}"
            return 1
        fi
    fi
    case "$core" in
        xray)
            cfg='/usr/local/etc/xray/config.json'
            [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
            # L-01: Xray configs are JSONC; read through the stripped view
            # (same $_jq_cfg pattern as users_adopt/users_sync): raw jq on
            # a commented live config fails and aborts the apply.
            local _jq_cfg=''
            _jq_cfg=$(mktemp /tmp/A-Box-routing-json.XXXXXX) || return 1
            # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
            local _jq_caller_trap=''
            _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
            trap 'rm -f -- "$_jq_cfg" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
            jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { rm -f "$_jq_cfg"; return 1; }
            local _routing_d=''
            _routing_d=$(mktemp -d /tmp/A-Box-routing.XXXXXX) || return 1
            tmp="$_routing_d/routing.json"
            jq --slurpfile st "$ROUTING_STATE_FILE" --argjson prev "$prev_applied" --argjson force "$force_json" --argjson prevr "$prev_rules_xray" '
                ($st[0].outbounds | map(.tag)) as $managed
                | ((($prev - $managed) + $force) | unique) as $retired
                | .outbounds |= (((. // []) as $orig
                    | ($orig | map(.tag as $t | ($managed + $retired) | index($t) | . != null) | index(true) // ($orig | length)) as $splice
                    | (($orig | map(select(.tag as $t | ($managed + $retired) | index($t) | not))) as $kept
                        | $kept[0:$splice] + [$st[0].outbounds[]?.xray] + $kept[$splice:])))
                | .routing.rules = (((.routing.rules // []) as $orig
                    | ($orig | map((.outboundTag as $t | $retired | index($t) | not) and (. as $r | ((($prevr + [$st[0].rules[]?.xray_rule]) | index($r)) | not)) | not) | index(true) // ($orig | length)) as $splice
                    | (($orig | map(select((.outboundTag as $t | $retired | index($t) | not) and (. as $r | ((($prevr + [$st[0].rules[]?.xray_rule]) | index($r)) | not))))) as $kept
                        | $kept[0:$splice] + [$st[0].rules[]?.xray_rule] + $kept[$splice:])))
            ' "$_jq_cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            if [[ -x /usr/local/bin/xray ]]; then
                local _xray_check_err=''
                if ! _xray_check_err=$(XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp" 2>&1 >/dev/null); then
                    msg "${RED}[!] $(tr_msg warp_apply_fail)${NC}"
                    if [[ -n "$_xray_check_err" ]]; then
                        printf '%s\n' "$_xray_check_err" | head -n 5 | while IFS= read -r _l; do msg "$_l"; done
                    fi
                    rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1
                fi
            fi
            local live_bak=''
            live_bak=$(mktemp) || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            cp -a "$cfg" "$live_bak" && chmod 600 -- "$live_bak" || { rm -f "$tmp" "$live_bak"; rm -rf -- "$_routing_d"; return 1; }
            install_file_atomically "$tmp" "$cfg" 600 || { rm -f "$tmp" "$live_bak"; rm -rf -- "$_routing_d"; return 1; }
            rm -f "$tmp"; rm -rf -- "$_routing_d"
            local atmp='' applied_bak=''
            if [[ -f "$applied_file" ]]; then
                applied_bak=$(mktemp) || { if cp -f -- "$live_bak" "$cfg" 2>/dev/null && prepare_abox_runtime_permissions xray 2>/dev/null; then rm -f -- "$live_bak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"; return 1; }
                cp -a -- "$applied_file" "$applied_bak" && chmod 600 -- "$applied_bak" || { if cp -f -- "$live_bak" "$cfg" 2>/dev/null && prepare_abox_runtime_permissions xray 2>/dev/null; then rm -f -- "$live_bak" "$applied_bak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"; return 1; }
            fi
            _routing_commit_applied_and_restart xray "$cfg" "$live_bak" "$applied_file" "$applied_bak" || return 1
            ;;
        singbox|sing-box)
            cfg='/etc/sing-box/config.json'
            [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
            local _routing_d=''
            _routing_d=$(mktemp -d /tmp/A-Box-routing.XXXXXX) || return 1
            tmp="$_routing_d/routing.json"
            jq --slurpfile st "$ROUTING_STATE_FILE" --argjson prev "$prev_applied" --argjson force "$force_json" --argjson prevr "$prev_rules_singbox" '
                ($st[0].outbounds | map(.tag)) as $managed
                | ((($prev - $managed) + $force) | unique) as $retired
                | ($st[0].outbounds | map(.singbox
                    | if (.type == "wireguard" and has("server")) then
                        ((.pre_shared_key // null) as $psk
                         | {type:"wireguard", tag:.tag, address:.local_address, private_key:.private_key,
                            mtu:(.mtu // 1280),
                            peers:[({address:.server, port:.server_port, public_key:.peer_public_key,
                                persistent_keepalive_interval:(.keepalive // 25),
                                allowed_ips:["0.0.0.0/0","::/0"]}
                               + (if ($psk | type == "string" and . != "") then {pre_shared_key:$psk} else {} end))]})
                      else . end)) as $frag
                | ($frag | map(select(.type == "wireguard"))) as $eps
                | ($frag | map(select(.type != "wireguard"))) as $obs
                | ($st[0].rules | map(.singbox_rule
                    | if has("geosite") then
                        (.rule_set = (((.rule_set) // []) + (.geosite | map("geosite-" + .))) | del(.geosite))
                      else . end)) as $srules
                | ($srules | map(.rule_set[]?) | unique) as $tags
                | .outbounds |= (((. // []) as $orig
                    | ($orig | map(.tag as $t | ($managed + $retired) | index($t) | . != null) | index(true) // ($orig | length)) as $splice
                    | (($orig | map(select(.tag as $t | ($managed + $retired) | index($t) | not))) as $kept
                        | $kept[0:$splice] + $obs + $kept[$splice:])))
                | .endpoints = (((.endpoints // []) | map(select(.tag as $t | ($managed + $retired) | index($t) | not))) + $eps)
                | .route.rules = (((.route.rules // []) as $orig
                    | ($orig | map((.outbound as $t | $retired | index($t) | not) and (. as $r | ((($prevr + $srules) | index($r)) | not)) | not) | index(true) // ($orig | length)) as $splice
                    | (($orig | map(select((.outbound as $t | $retired | index($t) | not) and (. as $r | ((($prevr + $srules) | index($r)) | not))))) as $kept
                        | $kept[0:$splice] + $srules + $kept[$splice:])))
                | ($prevr | [.. | objects | .rule_set[]? | select(type == "string")] | unique) as $prevtags
                | (.route.rules | [.. | objects | .rule_set[]? | select(type == "string")] | unique) as $refd
                | .route.rule_set = (((.route.rule_set // []) | map(select(.tag as $t | (($tags | index($t)) | not) and ((($prevtags | index($t)) | not) or (($refd | index($t)) | . != null))))) + ($tags | map({type:"remote", tag:., format:"binary",
                    url:("https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/" + . + ".srs"),
                    http_client:"abox-dl"})))
                | (if ($tags | length) > 0 then .http_clients = (((.http_clients // []) | map(select(.tag != "abox-dl"))) + [{tag:"abox-dl"}]) else . end)
            ' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            singbox_apply_loopback_guard "$tmp" || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            if [[ -x /usr/local/bin/sing-box ]]; then
                local _sb_check_err=''
                if ! _sb_check_err=$(/usr/local/bin/sing-box check -c "$tmp" 2>&1 >/dev/null); then
                    msg "${RED}[!] $(tr_msg warp_apply_fail)${NC}"
                    if [[ -n "$_sb_check_err" ]]; then
                        printf '%s\n' "$_sb_check_err" | head -n 5 | while IFS= read -r _l; do msg "$_l"; done
                    fi
                    rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1
                fi
            fi
            routing_ruleset_urls_ok "$tmp" || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            local live_bak=''
            live_bak=$(mktemp) || { rm -f "$tmp"; rm -rf -- "$_routing_d"; return 1; }
            cp -a "$cfg" "$live_bak" && chmod 600 -- "$live_bak" || { rm -f "$tmp" "$live_bak"; rm -rf -- "$_routing_d"; return 1; }
            install_file_atomically "$tmp" "$cfg" 600 || { rm -f "$tmp" "$live_bak"; rm -rf -- "$_routing_d"; return 1; }
            rm -f "$tmp"; rm -rf -- "$_routing_d"
            local atmp='' applied_bak=''
            if [[ -f "$applied_file" ]]; then
                applied_bak=$(mktemp) || { if cp -f -- "$live_bak" "$cfg" 2>/dev/null && prepare_abox_runtime_permissions sing-box 2>/dev/null; then rm -f -- "$live_bak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"; return 1; }
                cp -a -- "$applied_file" "$applied_bak" && chmod 600 -- "$applied_bak" || { if cp -f -- "$live_bak" "$cfg" 2>/dev/null && prepare_abox_runtime_permissions sing-box 2>/dev/null; then rm -f -- "$live_bak" "$applied_bak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; msg "${YELLOW}[!] $(tr_msg warp_applied_fail)${NC}"; return 1; }
            fi
            _routing_commit_applied_and_restart sing-box "$cfg" "$live_bak" "$applied_file" "$applied_bak" || return 1
            ;;
        *) return 1 ;;
    esac
}

# M-20: apply the current routing state to every managed core that can
# carry it (xray / sing-box), not just the .env CORE. Enumeration is
# the real managed set (expected_managed_services: main pair + owned
# auxiliary services); each core is applied in isolation, so one
# core's failure never blocks the next. Hysteria has no
# routing_apply_live target and is skipped, not failed. Extra args
# are forwarded to routing_apply_live (force-retire tags).
# Return codes: 0 = every managed routable core applied;
# 1 = no managed service at all (no core);
# 2 = managed service(s) exist but none can carry routing
#     (e.g. hysteria-only);
# 3 = at least one core was attempted and failed (partial failure).
routing_apply_all_managed() {
    local -a _svcs=() _cores=()
    local _svc _core _failed=0
    while IFS= read -r _svc; do
        [[ -n "$_svc" ]] && _svcs+=("$_svc")
    done < <(expected_managed_services 2>/dev/null)
    for _svc in "${_svcs[@]}"; do
        case "$_svc" in
            xray) _cores+=('xray') ;;
            sing-box) _cores+=('singbox') ;;
            *) : ;;
        esac
    done
    if (( ${#_cores[@]} == 0 )); then
        (( ${#_svcs[@]} == 0 )) && return 1
        return 2
    fi
    for _core in "${_cores[@]}"; do
        if ! routing_apply_live "$_core" "$@"; then
            _failed=1
            msg "${YELLOW}[!] $(tr_msg warp_apply_fail) (${_core})${NC}"
        fi
    done
    (( _failed == 0 )) || return 3
    return 0
}

# ---------------- WARP one-click ----------------

# L6-NEW-01: remove warp-out residue directly from the live core
# configs on disk, with no core and no running service needed.
# routing_apply_live is the normal retirement path, but it requires
# a core; the no-core warp_undeploy path and clear_all have none, so
# without this the endpoint and its route rules stay live forever
# (_remove_inbounds_from_config only strips rules referencing
# removed *inbounds*; warp-out is an outbound/endpoint, and its
# rules reference it via outbound/outboundTag). Idempotent: a
# missing config, or one without warp-out, is success. Never
# restarts a service: the callers run with the stack stopped.
warp_scrub_live_config() {
    local cfg stripped tmp
    for cfg in /usr/local/etc/xray/config.json /etc/sing-box/config.json; do
        [[ -f "$cfg" && ! -L "$cfg" ]] || continue
        stripped=$(mktemp) || return 1
        # OBS-3 (D2) / S1-NEW-06: the xray validation below runs `xray run -test`
        # on $tmp, and xray detects the config format from the filename
        # extension: an extensionless mktemp file fails with rc 23
        # ("Failed to get format"), so the scrub aborted at the xray
        # step and never reached the sing-box config on any box with an
        # xray binary. Give the temp file a .json suffix (same pattern
        # as the other xray validation sites in this file).
        local _scrub_d=''
        _scrub_d=$(mktemp -d /tmp/A-Box-scrub.XXXXXX) || { rm -f "$stripped"; return 1; }
        tmp="$_scrub_d/scrub.json"
        if ! jsonc_strip_comments "$cfg" > "$stripped" 2>/dev/null; then
            rm -f "$stripped" "$tmp"; rm -rf -- "$_scrub_d"; return 1
        fi
        if ! jq 'del(.outbounds[]? | select(.tag == "warp-out"))
                | del(.endpoints[]? | select(.tag == "warp-out"))
                | del(.routing.rules[]? | select(.outboundTag == "warp-out"))
                | del(.route.rules[]? | select(.outbound == "warp-out"))' \
                "$stripped" > "$tmp" 2>/dev/null; then
            rm -f "$stripped" "$tmp"; rm -rf -- "$_scrub_d"; return 1
        fi
        rm -f "$stripped"
        jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf -- "$_scrub_d"; return 1; }
        # S1-NEW-06: the jq filter above only deletes the
        # reference shapes it knows (outbounds/endpoints/rules).
        # Any other live reference to warp-out (e.g. an
        # observatory subjectSelector) would survive the delete
        # and still pass `xray run -test`, so the scrub would
        # report success over a residue. Fail closed before
        # installing: no exact "warp-out" string may remain
        # anywhere in the new config.
        if jq -e '[.. | strings | select(. == "warp-out")] | length > 0' "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"; rm -rf -- "$_scrub_d"; return 1
        fi
        case "$cfg" in
            *xray*)
                if [[ -x /usr/local/bin/xray ]]; then
                    XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf -- "$_scrub_d"; return 1; }
                fi ;;
            *sing-box*)
                if [[ -x /usr/local/bin/sing-box ]]; then
                    /usr/local/bin/sing-box check -c "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf -- "$_scrub_d"; return 1; }
                fi ;;
        esac
        if ! install_file_atomically "$tmp" "$cfg" 600; then rm -f "$tmp"; rm -rf -- "$_scrub_d"; return 1; fi
        rm -f "$tmp"; rm -rf -- "$_scrub_d"
        case "$cfg" in
            *xray*) prepare_abox_runtime_permissions xray 2>/dev/null || true ;;
            *sing-box*) prepare_abox_runtime_read_file "$cfg" sing-box 2>/dev/null || true ;;
        esac
    done
    return 0
}

# wgcf tracks the upstream latest release at runtime (no version pin).
# Prints "<version> <sha256:hex>" for the latest ViRb3/wgcf release, bound
# to a single resolution snapshot. Verification policy (A'): prefer the
# GitHub API asset digest; fall back to the release's checksums.txt when
# the digest is absent. No usable verification metadata => fail closed.
# NOTE: the [[ -x $WGCF_BIN ]] early return in warp_fetch_wgcf is kept on
# purpose: latest is resolved when a missing binary is fetched, not as a
# background upgrade of an existing installation.
wgcf_resolve_latest() {
    local arch="${1:-}" release_json tag ver asset digest sums_url sums_tmp hex sums_size
    [[ "$arch" == 'amd64' || "$arch" == 'arm64' ]] || return 1
    release_json=$(github_api_get "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null) || return 1
    tag=$(jq -er '.tag_name // empty' <<< "$release_json" 2>/dev/null) || return 1
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    jq -e '.draft == false and .prerelease == false' <<< "$release_json" >/dev/null 2>&1 || return 1
    ver="${tag#v}"
    asset="wgcf_${ver}_linux_${arch}"
    digest=$(jq -er --arg name "$asset" '[.assets[]? | select(.name == $name) | .digest] | if length == 1 then .[0] else empty end' <<< "$release_json" 2>/dev/null) || digest=''
    if [[ -z "$digest" || "$digest" == 'null' ]]; then
        sums_url="https://github.com/ViRb3/wgcf/releases/download/${tag}/checksums.txt"
        sums_tmp=$(umask 077; mktemp /tmp/A-Box-wgcf-sums.XXXXXX) || return 1
        if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 -m 30 "$sums_url" -o "$sums_tmp" 2>/dev/null; then rm -f -- "$sums_tmp"; return 1; fi
        sums_size=$(wc -c < "$sums_tmp" 2>/dev/null | tr -d ' ') || sums_size=''
        [[ "$sums_size" =~ ^[0-9]+$ ]] && (( sums_size <= 65536 )) || { rm -f -- "$sums_tmp"; return 1; }
        hex=$(awk -v f="$asset" '{ g=$2; sub(/^\*/, "", g); if (g == f) { print $1; n++ } } END { if (n != 1) exit 1 }' "$sums_tmp" 2>/dev/null) || { rm -f -- "$sums_tmp"; return 1; }
        rm -f -- "$sums_tmp"
        [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
        digest="sha256:$hex"
    fi
    [[ "$digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s %s\n' "$ver" "$digest"
}

warp_fetch_wgcf() {
    local arch resolved ver digest url tmp
    [[ -x "$WGCF_BIN" ]] && return 0
    case "$(uname -m)" in
        x86_64|amd64) arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) return 1 ;;
    esac
    # Resolve latest once and bind every step to that release.
    resolved=$(wgcf_resolve_latest "$arch") || return 1
    ver="${resolved%% *}"; digest="${resolved#* }"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || return 1
    tmp=$(mktemp) || return 1
    # Mirror first (best effort: the mirror only hosts the version its own
    # refresh resolved). A mirror miss or hash mismatch falls through to
    # upstream against the SAME expected hash -- never a downgrade, and the
    # mirror never supplies its own verification anchor.
    if fetch_util_mirror_asset "wgcf_${ver}_linux_${arch}" "$tmp" 2>/dev/null \
        && verify_github_asset_digest "$tmp" "$digest" 2>/dev/null; then
        :
    else
        rm -f -- "$tmp"
        tmp=$(mktemp) || return 1
        url="https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
        if ! curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 10 -m 120 "$url" -o "$tmp" 2>/dev/null; then rm -f -- "$tmp"; return 1; fi
    fi
    [[ -s "$tmp" ]] || { rm -f -- "$tmp"; return 1; }
    # sanity: must be an ELF binary
    head -c 4 "$tmp" | grep -q $'\x7fELF' || { rm -f -- "$tmp"; return 1; }
    verify_github_asset_digest "$tmp" "$digest" || { rm -f -- "$tmp"; return 1; }
    install -m 755 "$tmp" "$WGCF_BIN" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

# $1 = work dir. Outputs "OK" on success. Registers WARP account and generates profile.
warp_register_profile() {
    local workdir="$1" profile
    [[ -n "$workdir" && -d "$workdir" ]] || return 1
    warp_fetch_wgcf || return 1
    cd "$workdir" || return 1
    [[ -f wgcf-account.toml ]] || "$WGCF_BIN" register --accept-tos >/dev/null 2>&1 || return 1
    "$WGCF_BIN" generate >/dev/null 2>&1 || return 1
    profile="$workdir/wgcf-profile.conf"
    [[ -f "$profile" ]] || return 1
    grep -q '^PrivateKey' "$profile" || return 1
    echo 'OK'
}

# $1 = wgcf-profile.conf, $2 = output dir for xray/singbox JSON files
warp_build_outbound_json() {
    local profile="$1" outdir="$2"
    local priv peer endpoint addr4 addr6
    [[ -f "$profile" && -d "$outdir" ]] || return 1
    priv=$(grep '^PrivateKey' "$profile" | head -1 | awk '{print $3}') || return 1
    peer=$(grep '^PublicKey' "$profile" | head -1 | awk '{print $3}') || return 1
    endpoint=$(grep '^Endpoint' "$profile" | head -1 | awk '{print $3}') || return 1
    # R9-01: wgcf usually writes both addresses on ONE line, but a valid
    # profile may put IPv4 and IPv6 on separate "Address =" lines. Parse
    # every Address line and classify each token by family.
    local _addr_raw _tok
    _addr_raw=$(grep -E '^[[:blank:]]*Address[[:blank:]]*=' "$profile" | cut -d'=' -f2- | tr -d ' \t\r' | tr ',' '\n')
    [[ -n "$_addr_raw" ]] || return 1
    addr4=''; addr6=''
    while IFS= read -r _tok; do
        [[ -n "$_tok" ]] || continue
        if [[ "$_tok" == *:* ]]; then
            [[ -z "$addr6" ]] && addr6="$_tok"
        else
            [[ -z "$addr4" ]] && addr4="$_tok"
        fi
    done <<< "$_addr_raw"
    [[ "$addr4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
    [[ -n "$addr6" && ! "$addr6" =~ : ]] && addr6='' 
    [[ -n "$priv" && -n "$peer" && -n "$endpoint" ]] || return 1
    local srv sport
    srv="${endpoint%:*}"; sport="${endpoint##*:}"
    # R15C10-01: strip outer brackets for the sing-box peer address
    # (Xray keeps the original endpoint, so this only affects srv).
    if [[ "$srv" == \[*\] ]]; then srv="${srv:1:-1}"; fi
    [[ -n "$srv" && -n "$sport" ]] || return 1
    local addrs_json
    if [[ -n "$addr6" ]]; then
        addrs_json=$(jq -nc --arg a4 "$addr4" --arg a6 "$addr6" '[$a4,$a6]')
    else
        addrs_json=$(jq -nc --arg a4 "$addr4" '[$a4]')
    fi
    jq -n --rawfile priv <(printf '%s' "$priv") --arg peer "$peer" --arg ep "$endpoint" \
        --argjson addrs "$addrs_json" '{
        protocol:"wireguard", tag:"warp-out",
        settings:{secretKey:$priv, address:$addrs, mtu:1280,
            peers:[{publicKey:$peer, endpoint:$ep, keepAlive:25}]}
    }' > "$outdir/warp-xray.json" || return 1
    jq -n --rawfile priv <(printf '%s' "$priv") --arg peer "$peer" --arg srv "$srv" --argjson sport "$sport" \
        --argjson addrs "$addrs_json" '{
        type:"wireguard", tag:"warp-out",
        address:$addrs, private_key:$priv, mtu:1280,
        peers:[{address:$srv, port:$sport, public_key:$peer,
            persistent_keepalive_interval:25, allowed_ips:["0.0.0.0/0","::/0"]}]
    }' > "$outdir/warp-singbox.json" || return 1
}

# R5C10-03: no RETURN trap here. RETURN traps are a single
# global slot: an inner one clobbers the outer cleanup and
# refires on outer/menu returns with out-of-scope locals
# (set -u abort). The wrapper removes the workdir on every
# inner exit path instead; no subshell, so globals set by
# load_optional_abox_env_or_die are preserved.
warp_deploy() {
    local _rc
    _warp_deploy_workdir=''
    warp_deploy_inner "$@"
    _rc=$?
    [[ -n "$_warp_deploy_workdir" ]] && rm -rf -- "$_warp_deploy_workdir"
    _warp_deploy_workdir=''
    return "$_rc"
}

warp_deploy_inner() {
    local workdir xray_json singbox_json core
    workdir=$(mktemp -d) || return 1
    _warp_deploy_workdir="$workdir"
    msg "$(tr_msg warp_deploying)"
    # L6-NEW-01: resolve the core BEFORE registering warp-out in
    # the routing state. An aborted deploy (no core) used to leave
    # the state entry behind, so the menu reported WARP as deployed
    # with nothing live; it also wasted a wgcf register on a deploy
    # that could never apply.
    core="${CORE:-}"
    if [[ -z "$core" ]]; then
        load_optional_abox_env_or_die 2>/dev/null || true
        core="${CORE:-}"
    fi
    # Guard relaxation (coordinator-composed per the worker's formula):
    # CORE empty but a managed aux core exists -> do not abort early;
    # routing_apply_all_managed below applies to every managed core.
    # Abort only when no core at all is known.
    if [[ -z "$core" ]]; then
        if ! abox_owns_service sing-box && ! abox_owns_service xray && ! abox_owns_service hysteria; then
            msg "${RED}[!] $(tr_msg warp_no_core)${NC}"
            # 05a-M1: do NOT delete 'warp-out' here. This deploy has
            # not registered anything yet, so any warp-out in the
            # state is a previous successful deploy's, and the
            # snapshot that could restore it is only created below.
            # A stale entry (if any) is an explicit undeploy/cleanup
            # concern, not this abort path's to destroy.
            return 1
        fi
    fi
    [[ "$(warp_register_profile "$workdir")" == 'OK' ]] || { msg "$(tr_msg warp_register_fail)"; return 1; }
    warp_build_outbound_json "$workdir/wgcf-profile.conf" "$workdir" || { msg "$(tr_msg warp_profile_fail)"; return 1; }
    # M-20: snapshot the whole state file before mutating it (same
    # pattern as warp_apply_preset): if the core check or the live
    # apply fails below, the snapshot is written back so warp_status
    # cannot misreport a failed deploy as deployed.
    local _warp_snap='' _warp_rc=0
    routing_state_init || return 1
    _warp_snap=$(mktemp) || return 1
    cp -- "$ROUTING_STATE_FILE" "$_warp_snap" 2>/dev/null || { rm -f "$_warp_snap"; return 1; }
    routing_outbound_add 'warp-out' "$workdir/warp-xray.json" "$workdir/warp-singbox.json" \
        || { msg "$(tr_msg warp_state_fail)"; rm -f "$_warp_snap"; return 1; }
    routing_apply_all_managed
    _warp_rc=$?
    if (( _warp_rc != 0 )); then
        if routing_state_put < "$_warp_snap" > /dev/null 2>&1; then
            rm -f "$_warp_snap"
        else
            # R6-F09-8: keep the failed rollback snapshot: it is the only copy
            # of the pre-deploy state. Print its path so it can be retried
            # manually; /tmp retention is a rescue window, not a durable backup.
            msg "${YELLOW}[!] $(tr_msg warp_preset_rollback_fail)${NC}"
            msg "${YELLOW}[!] ${_warp_snap}${NC}"
        fi
        case "$_warp_rc" in
            1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
            2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
            *) msg "$(tr_msg warp_apply_fail)" ;;
        esac
        # H1 (05a): the failed apply may have committed the new config
        # to one core before the other failed, leaving live diverged
        # from the restored state: re-push the restored state so live
        # converges back too. Best effort; the failure is reported
        # either way. (Same pattern as warp_apply_preset.)
        routing_apply_all_managed >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$_warp_snap"
    msg "$(tr_msg warp_done)"
}

warp_undeploy() {
    local core="${CORE:-}"
    if [[ -z "$core" ]]; then
        load_optional_abox_env_or_die 2>/dev/null || true
        core="${CORE:-}"
    fi
    if [[ -z "$core" ]]; then
        # R33-01: CORE empty does not mean no core is live. The deploy
        # side already relaxes this guard (CORE empty + a managed aux
        # core -> deploy proceeds via routing_apply_all_managed), so a
        # managed xray/sing-box can be running with warp-out while
        # CORE is empty; the disk-only scrub below would then report
        # success over a still-serving tunnel (scrub never restarts
        # a service). Only scrub when no managed routable core exists
        # at all; otherwise fall through to the transactional path,
        # which retires warp-out through the live apply (and restarts
        # a running service via its own gate). Hysteria is excluded:
        # it cannot carry routing, so a hysteria-only box keeps the
        # scrub path instead of failing the apply.
        if ! abox_owns_service sing-box && ! abox_owns_service xray; then
            # L6-NEW-01: no core means no routing_apply_live to retire
            # the endpoint/rules through, but the residue is still on
            # disk and the menu has no other way to clear it (every
            # no-core undeploy aborted here). Scrub the live configs
            # directly, then drop the state entry: scrub first so a
            # scrub failure keeps the state flag (truthful: the residue
            # is still live) instead of reporting "not deployed" over
            # a live warp-out.
            warp_scrub_live_config || { msg "${YELLOW}[!] $(tr_msg warp_undeploy_fail)${NC}"; return 1; }
            routing_outbound_del 'warp-out' || return 1
            msg "$(tr_msg warp_removed)"
            return 0
        fi
    fi
    # M-20: snapshot the whole state file before mutating it (same
    # pattern as warp_apply_preset / warp_deploy_inner): if the live
    # apply fails, the snapshot is written back so the state and the
    # live config cannot diverge in opposite directions.
    local _warp_snap='' _warp_rc=0
    routing_state_init || return 1
    _warp_snap=$(mktemp) || return 1
    cp -- "$ROUTING_STATE_FILE" "$_warp_snap" 2>/dev/null || { rm -f "$_warp_snap"; return 1; }
    routing_outbound_del 'warp-out' || { rm -f "$_warp_snap"; return 1; }
    routing_apply_all_managed 'warp-out'
    _warp_rc=$?
    if (( _warp_rc != 0 )); then
        if routing_state_put < "$_warp_snap" > /dev/null 2>&1; then
            rm -f "$_warp_snap"
        else
            # R6-F09-8: keep the failed rollback snapshot: it is the only copy
            # of the pre-undeploy state. Print its path so it can be retried
            # manually; /tmp retention is a rescue window, not a durable backup.
            msg "${YELLOW}[!] $(tr_msg warp_preset_rollback_fail)${NC}"
            msg "${YELLOW}[!] ${_warp_snap}${NC}"
        fi
        case "$_warp_rc" in
            1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
            2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
            *) msg "${YELLOW}[!] $(tr_msg warp_undeploy_fail)${NC}" ;;
        esac
        # H1 (05a): same re-push as warp_deploy_inner. No force-retire
        # argument here: the restored state carries warp-out again, so
        # it must be applied back, not retired.
        routing_apply_all_managed >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$_warp_snap"
    msg "$(tr_msg warp_removed)"
}

warp_status() {
    if routing_outbound_has_live 'warp-out'; then
        msg "$(tr_msg warp_status_on)"
    elif routing_outbound_has 'warp-out'; then
        msg "$(tr_msg warp_status_stale)"
    else
        msg "$(tr_msg warp_status_off)"
    fi
    local n_rules
    n_rules=$(jq '.rules | length' "$ROUTING_STATE_FILE" 2>/dev/null || echo 0)
    msg "$(tprintf warp_rules_count "$n_rules")"
    if [[ -f "$ROUTING_STATE_FILE" ]]; then
        local _tag _lbl _exits=''
        while IFS= read -r _tag; do
            [[ -z "$_tag" ]] && continue
            case "$_tag" in
                warp-out) _lbl='WARP' ;;
                socks-land*) _lbl="$(tr_msg mi_land)${_tag#socks-land}" ;;
                *) _lbl="$_tag" ;;
            esac
            _exits+="${_exits:+ · }$_lbl"
        done < <(jq -r '.outbounds[]?.tag' "$ROUTING_STATE_FILE" 2>/dev/null)
        [[ -n "$_exits" ]] && msg "$(tr_msg mi_split): $_exits"
    fi
}

# WARP split presets (single-machine). $1 = preset name
warp_apply_preset() {
    local preset="$1"
    routing_outbound_has 'warp-out' || { msg "$(tr_msg warp_need_deploy)"; return 1; }
    # Validate the preset name before touching state: an unknown preset
    # must not wipe the current rules.
    case "$preset" in
        streaming|cn-direct|global) ;;
        *) msg "${RED}$(tr_msg invalid_input): $preset${NC}"; return 1 ;;
    esac
    # Validate every outbound the preset needs before clearing the
    # current rules, so a preset can never half-apply.
    case "$preset" in
        cn-direct) routing_outbound_has 'direct' || { msg "${RED}$(tr_msg warp_apply_fail)${NC}"; return 1; } ;;
    esac
    # Snapshot the whole state file: any failed add rolls back to this
    # instead of leaving a half-applied rule set behind.
    local snap='' _preset_rc=0
    snap=$(mktemp) || { msg "${RED}$(tr_msg warp_apply_fail)${NC}"; return 1; }
    cp -- "$ROUTING_STATE_FILE" "$snap" 2>/dev/null || { rm -f "$snap"; msg "${RED}$(tr_msg warp_apply_fail)${NC}"; return 1; }
    routing_rules_clear || { rm -f "$snap"; msg "${RED}$(tr_msg warp_apply_fail)${NC}"; return 1; }
    case "$preset" in
        streaming)
            routing_rule_add 'geosite:netflix,geosite:disney,geosite:youtube,geosite:primevideo,geosite:hbo' 'warp-out' || _preset_rc=1
            ;;
        cn-direct)
            routing_rule_add 'geosite:netflix,geosite:disney,geosite:youtube' 'warp-out' || _preset_rc=1
            if (( _preset_rc == 0 )); then
                routing_rule_add 'geosite:cn' 'direct' || _preset_rc=1
            fi
            ;;
        global)
            routing_rule_add 'all' 'warp-out' || _preset_rc=1
            ;;
        *) _preset_rc=1 ;;
    esac
    if (( _preset_rc != 0 )); then
        if routing_state_put < "$snap" > /dev/null 2>&1; then
            rm -f "$snap"
        else
            # R6-F09-8: keep the failed rollback snapshot: it is the only copy
            # of the pre-preset state. Print its path so it can be retried
            # manually; /tmp retention is a rescue window, not a durable backup.
            msg "${YELLOW}[!] $(tr_msg warp_preset_rollback_fail)${NC}"
            msg "${YELLOW}[!] ${snap}${NC}"
        fi
        msg "${RED}$(tr_msg warp_apply_fail)${NC}"
        return 1
    fi
    # M-20: apply to every managed core that can carry routing, not
    # just the .env CORE (routing_apply_all_managed). A failure rolls
    # the preset's rules back to the entry snapshot, as before.
    local _apply_rc=0
    routing_apply_all_managed
    _apply_rc=$?
    if (( _apply_rc != 0 )); then
        if routing_state_put < "$snap" > /dev/null 2>&1; then
            rm -f "$snap"
        else
            # R6-F09-8: keep the failed rollback snapshot: it is the only copy
            # of the pre-preset state. Print its path so it can be retried
            # manually; /tmp retention is a rescue window, not a durable backup.
            msg "${YELLOW}[!] $(tr_msg warp_preset_rollback_fail)${NC}"
            msg "${YELLOW}[!] ${snap}${NC}"
        fi
        case "$_apply_rc" in
            1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
            2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
        esac
        # The failed apply may have committed the bad config before the
        # service died (restart race), leaving live diverged from the
        # restored state: re-push the restored state so live converges
        # back too. Best effort; the failure is reported either way.
        routing_apply_all_managed >/dev/null 2>&1 || true
        msg "${RED}$(tr_msg warp_apply_fail)${NC}"
        return 1
    fi
    rm -f "$snap"
    msg "$(tr_msg warp_preset_done)"
}


# Landing-machine one-click presets: streaming / social / AI.
# $1 = preset name, $2 = outbound tag
split_apply_preset() {
    local preset="$1" outbound="$2" domains
    [[ -n "$preset" && -n "$outbound" ]] || return 1
    routing_outbound_has "$outbound" || { msg "$(tr_msg split_need_outbound)"; return 1; }
    case "$preset" in
        streaming) domains='geosite:netflix,geosite:disney,geosite:hbo,geosite:hulu,geosite:primevideo,geosite:dazn' ;;
        social)    domains='geosite:tiktok,geosite:twitter,geosite:instagram,geosite:facebook,geosite:telegram' ;;
        ai)        domains='geosite:openai' ;;
        *) return 1 ;;
    esac
    routing_rule_add "$domains" "$outbound" || return 1
    local n_rules=0 _apply_rc=0
    n_rules=$(jq '.rules | length' "$ROUTING_STATE_FILE" 2>/dev/null || echo 0)
    # M-20: apply to every managed core that can carry routing, not
    # just the .env CORE (routing_apply_all_managed). A failure rolls
    # the just-added rule back, as before.
    routing_apply_all_managed
    _apply_rc=$?
    if (( _apply_rc != 0 )); then
        routing_rule_del "$((n_rules - 1))" >/dev/null 2>&1 || true
        case "$_apply_rc" in
            1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
            2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
        esac
        # H1 (05a): re-push the rolled-back state so live converges back
        # too (same pattern as split_rule_add_interactive).
        routing_apply_all_managed >/dev/null 2>&1 || true
        return 1
    fi
    msg "$(tr_msg warp_preset_done)"
}

# ---------------- multi-machine split routing ----------------

# $1=landing IP, $2=port, $3=user, $4=pass. Creates tag socks-land<N>.
split_add_socks_outbound() {
    local ip="$1" port="$2" user="$3" pass="$4"
    local tag workdir n
    [[ -n "$ip" && -n "$port" ]] || return 1
    # U43: jq --argjson alone only stops pure non-numeric strings; reject
    # non-integers and out-of-range ports before anything is persisted.
    [[ "$port" =~ ^[0-9]+$ && ${#port} -le 5 ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    n=1
    # R16-F09-02: also skip tags already present in a live core config
    # but not registered in the routing state file (see
    # routing_outbound_has_live); reusing one would silently replace
    # the unmanaged outbound at the next apply.
    while routing_outbound_has "socks-land$n" || routing_outbound_has_live "socks-land$n"; do n=$((n+1)); done
    tag="socks-land$n"
    workdir=$(mktemp -d) || return 1
    # M-37: hardened trap -- ${workdir:-} so a refire on an outer return
    # cannot abort under set -u; silent and rc-safe.
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    local _workdir_caller_trap=''
    _workdir_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_workdir_caller_trap:-}" ]]; then eval "$_workdir_caller_trap"; else trap - RETURN; fi; true' RETURN
    jq -n --arg tag "$tag" --arg ip "$ip" --argjson port "$port" --arg u "$user" --rawfile p <(printf '%s' "$pass") '{
        protocol:"socks", tag:$tag,
        settings:{servers:[{address:$ip, port:$port,
            users:((if $u != "" then [{user:$u, pass:$p}] else [] end))}]}
    }' > "$workdir/socks-xray.json" || return 1
    jq -n --arg ip "$ip" --argjson port "$port" --arg u "$user" --rawfile p <(printf '%s' "$pass") --arg tag "$tag" '{
        type:"socks", tag:$tag, server:$ip, server_port:$port
    } + (if $u != "" then {username:$u, password:$p} else {} end)' > "$workdir/socks-singbox.json" || return 1
    routing_outbound_add "$tag" "$workdir/socks-xray.json" "$workdir/socks-singbox.json" || return 1
    echo "$tag"
}

# ============ WARP 与分流管理菜单 (toolbox 5) ============
warp_split_menu() {
    # Submenu loop: 0/Enter goes back to the parent menu.
    while true; do
    clear
    msg "${BOLD}${GREEN}$(tr_msg warp_split_title)${NC}"
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    warp_status
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    msg "${CYAN}1.${NC} $(tr_msg warp_deploy_item)"
    msg "${CYAN}2.${NC} $(tr_msg warp_preset_item)"
    msg "${CYAN}3.${NC} $(tr_msg split_add_socks_item)"
    msg "${CYAN}4.${NC} $(tr_msg split_rules_item)"
    msg "${CYAN}5.${NC} $(tr_msg warp_uninstall_item)"
    msg "${CYAN}0.${NC} $(tr_msg back_to_parent)"
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    local choice
    read -r -p "$(tr_msg select_prompt) [0-5]: " choice || return 0
    choice=$(normalize_fa_ar_digits "${choice:-}")
    case "$choice" in
        1) warp_deploy; pause_return ;;
        2) warp_preset_menu ;;
        3) split_add_socks_interactive ;;
        4) split_rules_menu ;;
        5)
            if confirm_yes_no "$(tr_msg warp_uninstall_confirm)"; then
                # warp_undeploy applies the removal itself and reports
                # success/failure. Never blanket-clear rules here: that
                # would delete non-WARP split rules as well.
                warp_undeploy || true
            fi
            pause_return ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $choice${NC}"; sleep 1 ;;
    esac
    done
}

warp_preset_menu() {
    while true; do
    clear
    msg "${BOLD}${GREEN}$(tr_msg warp_preset_title)${NC}"
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    msg "${CYAN}1.${NC} $(tr_msg warp_preset_streaming)"
    msg "${CYAN}2.${NC} $(tr_msg warp_preset_cn_direct)"
    msg "${CYAN}3.${NC} $(tr_msg warp_preset_global)"
    msg "${CYAN}0.${NC} $(tr_msg back_to_parent)"
    local choice
    read -r -p "$(tr_msg select_prompt) [0-3]: " choice || return 0
    choice=$(normalize_fa_ar_digits "${choice:-}")
    case "$choice" in
        1) warp_apply_preset streaming || msg "${RED}$(tr_msg warp_apply_fail)${NC}"; pause_return ;;
        2) warp_apply_preset cn-direct || msg "${RED}$(tr_msg warp_apply_fail)${NC}"; pause_return ;;
        3) warp_apply_preset global || msg "${RED}$(tr_msg warp_apply_fail)${NC}"; pause_return ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $choice${NC}"; sleep 1 ;;
    esac
    done
}

split_add_socks_interactive() {
    local ip port user pass tag
    read -r -p "$(tr_msg split_ip_prompt): " ip || return 0
    [[ -n "$ip" ]] || { msg "${RED}$(tr_msg invalid_input)${NC}"; return 1; }
    read -r -p "$(tprintf split_port_prompt '1080'): " port || return 0
    port=$(normalize_fa_ar_digits "$port")
    port="${port:-1080}"
    IFS= read -r -p "$(tr_msg split_user_prompt): " user || return 0
    IFS= read -r -s -p "$(tr_msg split_pass_prompt): " pass || return 0; echo
    tag=$(split_add_socks_outbound "$ip" "$port" "$user" "$pass") || { msg "${RED}$(tr_msg split_add_fail)${NC}"; pause_return; return 1; }
    # M-20: apply to every managed core that can carry routing, not
    # just the .env CORE (routing_apply_all_managed). With no usable
    # core the add is rolled back instead of reporting a state-only
    # success (unified no-core policy with the warp functions).
    local _apply_rc=0
    routing_apply_all_managed
    _apply_rc=$?
    if (( _apply_rc == 0 )); then
        msg "$(tprintf split_add_done "$tag")"
    else
        routing_outbound_del "$tag" || true
        case "$_apply_rc" in
            1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
            2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
            *) msg "${RED}$(tr_msg split_add_fail)${NC}" ;;
        esac
        # H1 (05a): re-push the rolled-back state so live converges back
        # too (same pattern as split_rule_add_interactive).
        routing_apply_all_managed >/dev/null 2>&1 || true
        pause_return; return 1
    fi
    pause_return
}

split_rules_menu() {
    while true; do
    clear
    msg "${BOLD}${GREEN}$(tr_msg split_rules_title)${NC}"
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    local i=0
    while IFS= read -r line; do
        msg "$i. $line"; i=$((i+1))
    done < <(jq -r '.rules[]? | "\(.domains | join(",")) -> \(.outbound)"' "$ROUTING_STATE_FILE" 2>/dev/null)
    [[ "$i" -eq 0 ]] && msg "$(tr_msg split_no_rules)"
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    msg "a. $(tr_msg split_rule_add)"
    msg "d. $(tr_msg split_rule_del)"
    msg "s. $(tr_msg split_preset_streaming)"
    msg "m. $(tr_msg split_preset_social)"
    msg "i. $(tr_msg split_preset_ai)"
    msg "${CYAN}0.${NC} $(tr_msg back_to_parent)"
    local choice
    read -r -p "$(tr_msg select_prompt) [a/d/s/m/i/0]: " choice || return 0
    choice=$(normalize_fa_ar_digits "${choice:-}")
    case "$choice" in
        a|A) split_rule_add_interactive ;;
        d|D) split_rule_del_interactive ;;
        s|S) split_preset_interactive streaming ;;
        m|M) split_preset_interactive social ;;
        i|I) split_preset_interactive ai ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $choice${NC}"; sleep 1 ;;
    esac
    done
}

split_rule_add_interactive() {
    local domains outbound
    msg "$(tr_msg split_domains_hint)"
    read -r -p "$(tr_msg split_domains_prompt): " domains || return 0
    [[ -n "$domains" ]] || return 1
    if [[ -z "${domains//,/}" ]]; then msg "${RED}$(tr_msg split_domains_empty)${NC}"; return 1; fi
    msg "$(tr_msg split_outbound_hint)"
    jq -r '.outbounds[]? | .tag' "$ROUTING_STATE_FILE" 2>/dev/null | while IFS= read -r t; do msg " - $t"; done
    read -r -p "$(tr_msg split_outbound_prompt): " outbound || return 0
    [[ -n "$outbound" ]] || return 1
    if routing_rule_add "$domains" "$outbound"; then
        local n_rules=0 _apply_rc=0
        n_rules=$(jq '.rules | length' "$ROUTING_STATE_FILE" 2>/dev/null || echo 0)
        # M-20: apply to every managed core that can carry routing, not
        # just the .env CORE (routing_apply_all_managed). With no usable
        # core the rule is rolled back instead of reporting a state-only
        # success (unified no-core policy with the warp functions).
        routing_apply_all_managed
        _apply_rc=$?
        if (( _apply_rc != 0 )); then
            # Roll back the just-appended rule (last index) so a retry
            # cannot duplicate it; the state stays the source of truth.
            routing_rule_del "$((n_rules - 1))" >/dev/null 2>&1 || true
            routing_apply_all_managed >/dev/null 2>&1 || true
            case "$_apply_rc" in
                1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
                2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
                *) msg "${RED}$(tr_msg warp_apply_fail)${NC}" ;;
            esac
            pause_return; return 1
        fi
        msg "$(tr_msg split_rule_done)"
    else
        msg "${RED}$(tr_msg split_rule_fail)${NC}"
    fi
    pause_return
}

split_preset_interactive() {
    local preset="$1" outbound
    msg "$(tr_msg split_outbound_hint)"
    jq -r '.outbounds[]? | .tag' "$ROUTING_STATE_FILE" 2>/dev/null | while IFS= read -r t; do msg " - $t"; done
    read -r -p "$(tr_msg split_outbound_prompt): " outbound || return 0
    [[ -n "$outbound" ]] || return 1
    if split_apply_preset "$preset" "$outbound"; then
        msg "$(tr_msg split_rule_done)"
    else
        msg "${RED}$(tr_msg split_rule_fail)${NC}"
    fi
    pause_return
}

split_rule_del_interactive() {
    local idx
    read -r -p "$(tr_msg split_rule_del_prompt): " idx || return 0
    # 05a-M2: convert only when the value fits int64; an over-long
    # input stays a raw string so routing_rule_del rejects it as
    # invalid instead of wrapping to a valid-looking small index.
    if [[ "$idx" =~ ^[0-9]+$ ]] && decimal_fits_int64 "$idx"; then idx=$((10#$idx)); fi
    # Snapshot for rollback: re-adding appends, which would move the rule
    # and change first-match order, so the original object is kept to be
    # re-inserted at this same index if the live apply fails.
    local del_rule=''
    del_rule=$(jq -c --argjson i "$idx" '.rules[$i] // empty' "$ROUTING_STATE_FILE" 2>/dev/null || true)
    if routing_rule_del "$idx"; then
        local _apply_rc=0
        # M-20: apply to every managed core that can carry routing, not
        # just the .env CORE (routing_apply_all_managed).
        routing_apply_all_managed
        _apply_rc=$?
        if (( _apply_rc != 0 )); then
            # Restore the deleted rule at its original index so a retry
            # deletes the same rule; order is preserved (first match wins).
            # If the restore itself fails, the state still holds the
            # deletion intent and converges on the next apply; the
            # failure below is reported either way.
            if [[ -n "$del_rule" ]]; then
                jq --argjson i "$idx" --argjson r "$del_rule" '.rules |= (.[0:$i] + [$r] + .[$i:])' "$ROUTING_STATE_FILE" 2>/dev/null | routing_state_put || true
            fi
            routing_apply_all_managed >/dev/null 2>&1 || true
            case "$_apply_rc" in
                1) msg "${RED}[!] $(tr_msg warp_no_core)${NC}" ;;
                2) msg "${RED}[!] $(tr_msg warp_core_unsupported)${NC}" ;;
                *) msg "${RED}$(tr_msg warp_apply_fail)${NC}" ;;
            esac
            pause_return; return 1
        fi
        msg "$(tr_msg split_rule_del_done)"
    else
        msg "${RED}$(tr_msg invalid_input)${NC}"
    fi
    pause_return
}


deploy_socks5_landing() {
    local port user pass cfg='/usr/local/etc/xray/config.json'
    local tag="${ABOX_DEPLOY_TAG:-socks5-landing}" tmp_json inbound_json cfg_bak=''
    # M-24(2): tmp_json holds the cleartext SOCKS5 password and cfg_bak
    # a copy of the whole live config (all credentials). die() exits
    # the process, so a RETURN trap never fires on those paths; an
    # EXIT trap is the only backstop. Cleared on the success path
    # below, once both files are removed explicitly. (Precedent: the
    # same EXIT-trap idiom is used elsewhere in this file.)
    # M-24 (follow-up N2): save the pre-existing EXIT trap (installed
    # by enter_runtime: runtime_lock_cleanup) and chain it into ours,
    # instead of overwriting it; the success path restores it with
    # restore_saved_trap instead of bare `trap - EXIT`. (Precedent:
    # the _n2 temp-dir trap chain, same strip-and-eval idiom.)
    local _socks5_prev_trap_exit='' _socks5_exit_trap_cmd='' _socks5_old_cmd=''
    _socks5_prev_trap_exit=$(trap -p EXIT || true)
    _socks5_exit_trap_cmd='[[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_jq_cfg:-}" ]] && (( ${_jq_tmp:-0} == 1 )) && rm -f -- "$_jq_cfg" 2>/dev/null; true'
    if [[ -n "$_socks5_prev_trap_exit" ]]; then
        _socks5_old_cmd="${_socks5_prev_trap_exit#trap -- }"
        _socks5_old_cmd="${_socks5_old_cmd% EXIT}"
        _socks5_exit_trap_cmd="$_socks5_exit_trap_cmd; eval $_socks5_old_cmd"
    fi
    trap "$_socks5_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg socks5_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg socks5_port_prompt)" port '1080' both) || die 'SOCKS5 port input failed.'
    IFS= read -r -p "$(tr_msg socks5_user_prompt)" user || die "$(tr_msg pi_input_closed)"
    user="${user:-main}"
    IFS= read -r -s -p "$(tr_msg socks5_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    echo
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'SOCKS5 password generation failed.'
        [[ -n "$pass" ]] || die 'SOCKS5 password generation failed.'
    fi
    # R8C10-F2: SOCKS5 (RFC 1929) username/password lengths are
    # single-byte (max 255); longer credentials deploy but can
    # never authenticate. Byte count, not character count.
    local _socks5_user_len _socks5_pass_len
    _socks5_user_len=$(printf '%s' "$user" | wc -c)
    _socks5_pass_len=$(printf '%s' "$pass" | wc -c)
    if (( _socks5_user_len > 255 || _socks5_pass_len > 255 )); then
        die 'SOCKS5 username/password must be at most 255 bytes (RFC 1929).'
    fi

    # Minimal Xray install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "xray socks5-landing"
    if [[ ! -x /usr/local/bin/xray ]]; then
        local xray_tmp xray_zip xray_ext
        get_architecture
        xray_tmp=$(abox_mktemp_exec_dir A-Box-xray-socks5) || die "$(tr_msg dp_xray_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$xray_tmp"
        xray_zip="$xray_tmp/xray_core.zip"
        xray_ext="$xray_tmp/xray_ext"
        mkdir -p "$xray_ext" || die 'Xray extraction directory creation failed.'
        clear_core_release_resolution XTLS/Xray-core
        fetch_github_release XTLS/Xray-core xray_core.zip "$xray_zip"
        extract_zip_member_safely "$xray_zip" xray "$xray_ext/xray" || die "$(tr_msg dp_xray_extract)"
        [[ -f "$xray_ext/xray" && ! -L "$xray_ext/xray" ]] || die "$(tr_msg dp_xray_bin)"
        chmod 755 "$xray_ext/xray" || die 'Xray staged binary chmod failed.'
        "$xray_ext/xray" version >/dev/null 2>&1 || die 'Xray staged binary execution check failed.'
        install_binary_atomically "$xray_ext/xray" /usr/local/bin/xray || die 'Xray binary atomic install failed.'
        /usr/local/bin/xray version >/dev/null 2>&1 || die "$(tr_msg dp_xray_exec)"
        prepare_abox_runtime_config_dir xray /usr/local/etc/xray || die 'Xray config directory creation failed.'
        rm -rf -- "$xray_tmp"
        ABOX_DEPLOY_TX_TMP=''
        # R14-F09-03: check ownership BEFORE writing any unit below.
        # ensure_xray_service_unit passes vacuously once our own marker
        # is on disk, so the gate at the end of this function (R6-F09-7)
        # can never fire for a unit written here: a foreign unit must
        # be refused here, before it is overwritten.
        ensure_xray_service_unit || die "$(tr_msg dp_xray_unit)"
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
            write_file_atomically_from_stdin /etc/systemd/system/xray.service 644 <<'EOF_SVC' || die "$(tr_msg dp_xray_unit)"
# Managed by A-Box
[Unit]
Description=A-Box Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=abox-xray
Group=abox-xray
UMask=0077
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
NoNewPrivileges=true
PrivateTmp=true
Restart=always
RestartSec=10
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF_SVC
        else
            path_parent_chain_safe /etc/conf.d/xray || die "$(tr_msg dp_orc_parent)"
            mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
            write_file_atomically_from_stdin /etc/conf.d/xray 644 <<'EOF_XRAY_CONFD' || die "$(tr_msg dp_xray_confd)"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
EOF_XRAY_CONFD
            write_file_atomically_from_stdin /etc/init.d/xray 755 <<'EOF_SVC' || die "$(tr_msg dp_xray_initd)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
command_user="abox-xray:abox-xray"
capabilities="^cap_net_bind_service"
umask=077
pidfile="/run/xray.pid"
depend() { need net; }
EOF_SVC
            chmod +x /etc/init.d/xray || die "$(tr_msg dp_xray_chmod)"
        fi
    fi
    abox_fetch_guard_stop

    # R6-F09-7: a pre-existing binary does not imply a service unit exists.
    # Ensure it here, before the config merge and restart (R7-13 precedent
    # on the sing-box path). Managed units are a no-op; foreign units die.
    # H-22 (Carbon R3): the minimal install above never installed Geo
    # data, so a standalone Xray could not serve geoip:/geosite: rules
    # (the full deploy_xray installs both files). Install them when
    # either file is missing; a redeploy with intact Geo skips the
    # download instead of re-fetching on every run.
    if [[ ! -f /usr/local/share/xray/geoip.dat || ! -f /usr/local/share/xray/geosite.dat ]]; then
        local _geo_tmp
        _geo_tmp=$(mktemp -d /tmp/A-Box-xray-geo.XXXXXX) || die "$(tr_msg dp_geo_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$_geo_tmp"
        install -d -m 755 /usr/local/share/xray || die 'Xray data directory creation failed.'
        fetch_geo_data geoip.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat' "$_geo_tmp/geoip.dat"
        fetch_geo_data geosite.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat' "$_geo_tmp/geosite.dat"
        install_file_atomically "$_geo_tmp/geoip.dat" /usr/local/share/xray/geoip.dat 644 || die "$(tr_msg dp_geoip_write)"
        install_file_atomically "$_geo_tmp/geosite.dat" /usr/local/share/xray/geosite.dat 644 || die "$(tr_msg dp_geosite_write)"
        rm -rf -- "$_geo_tmp"
        ABOX_DEPLOY_TX_TMP=''
    fi
    ensure_xray_service_unit || die "$(tr_msg dp_xray_unit)"

    # Build the socks inbound object.
    # Seed a minimal config shell; the socks inbound is appended below.
    # R1-10-F1: the seed is not tied to the binary-missing branch: a
    # present binary with a missing config needs it just as much.
    # R5C10-01: seed only when no config file exists (or it is empty
    # or a symlink); an existing non-empty config is never overwritten,
    # even if jq rejects it (it may carry comments Xray accepts).
    tmp_json=$(mktemp /tmp/A-Box-xray-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n '{log:{loglevel:"warning",access:"/var/log/A-Box-xray-access.log",error:"/var/log/A-Box-xray-error.log"},inbounds:[],routing:{rules:[{type:"field",ip:["127.0.0.0/8","::1/128"],outboundTag:"block"}]},outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$tmp_json" \
        || die "$(tr_msg dp_xray_seed)"
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_xray_cfg)"
    fi
    rm -f "$tmp_json"
    # S-SOCKS5-01: prep must run AFTER the seed: it requires
    # /usr/local/etc/xray/config.json to exist, and the seed is what
    # creates it when both the binary and the config are missing.
    prepare_abox_runtime_permissions xray || die "$(tr_msg dp_xray_runtime)"
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    tmp_json=$(mktemp /tmp/A-Box-socks5-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --arg user "$user" --rawfile pass <(printf '%s' "$pass") --arg tag "$tag" --arg listen_addr "$listen_addr" \
        '{tag:$tag,port:$port,listen:$listen_addr,protocol:"socks",
          settings:{auth:"password",accounts:[{user:$user,pass:$pass}],udp:true,ip:$listen_addr}}' \
        > "$tmp_json" || die "$(tr_msg dp_socks5_json)"
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }

    # M-6-rescan (D-leg): strip-once snapshot for the uniqueness gate
    # and the merge below (same _jq_cfg pattern as users_adopt). The
    # snapshot is taken after the seed above, so it is current for
    # both. On strip failure fall back to the raw file (strip failure
    # != read failure); _jq_tmp marks a temp file (safe to delete).
    local _jq_cfg='' _jq_tmp=0
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-socks5-json.XXXXXX) || _jq_cfg=''
        if [[ -n "$_jq_cfg" ]] && jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null; then
            _jq_tmp=1
        else
            [[ -n "$_jq_cfg" ]] && rm -f -- "$_jq_cfg"
            _jq_cfg="$cfg"
        fi
    else
        _jq_cfg="$cfg"
    fi

    # If the tag already exists, replace it in place; otherwise hot-add.
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_jq_cfg" >/dev/null 2>&1; then
        local tmp_cfg
        # S-X (R30-M02 same-shape): same guard as ShadowTLS (2dh): an
        # independent inbound that merely shares $tag must not be
        # silently replaced by the merge below; only a single genuine
        # SOCKS inbound proceeds.
        # R-1 (SX-F1 same-shape): uniqueness gate, not an existence
        # check -- a duplicated tag refuses, because the merge below
        # deletes the whole tag group.
        if ! jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].protocol == "socks")' "$_jq_cfg" >/dev/null 2>&1; then
            die "Tag '$tag' is already used by an independent inbound (not a SOCKS inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
        msg "${YELLOW}$(tr_msg socks5_exists)${NC}"
        # R16-F08-02: create the .json target directly with mktemp
        # (O_CREAT|O_EXCL, random suffix); the old reserve+mv derived
        # a predictable name a pre-planted FIFO could block forever.
        local _scfg_d=''
        _scfg_d=$(mktemp -d /tmp/A-Box-xray-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        tmp_cfg="$_scfg_d/config.json"
        if ! jq --arg t "$tag" --slurpfile nb "$tmp_json" \
                '.inbounds = (.inbounds // [])
                 | (.inbounds | map(select(.tag==$t))) as $old
                 | .inbounds |= (
                     map(select(.tag!=$t))
                     + [
                         $nb[] as $new
                         | (
                             ($old | map(select(.tag==$new.tag)) | first) as $ex
                             | if ($ex and ($ex.settings.accounts | type == "array") and ($ex.settings.accounts | length) > 1
                                    and ($new.settings.accounts | type == "array") and ($new.settings.accounts | length) > 0) then
                                   $new | .settings.accounts = ([$new.settings.accounts[0]] + $ex.settings.accounts[1:])
                               else $new
                               end
                           )
                       ]
                   )' \
                "$_jq_cfg" > "$tmp_cfg" 2>/dev/null; then
            rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_scfg_d"; die "$(tr_msg dp_socks5_update)"
        fi
        jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_scfg_d"; die "$(tr_msg dp_xray_json)"; }
        # H-07: enforce the loopback guard on the merged config before
        # validation; refuse to install an unguarded config.
        xray_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_scfg_d"; die 'Xray loopback guard enforcement failed; refusing to install the unguarded config.'; }
        XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp_cfg" >/dev/null 2>&1 \
            || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_scfg_d"; die "$(tr_msg dp_xray_check)"; }
        install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_scfg_d"; die "$(tr_msg dp_xray_cfg)"; }
        rm -f "$tmp_cfg"; rm -rf -- "$_scfg_d"
        prepare_abox_runtime_permissions xray 2>/dev/null || true
        if service_restart_permitted xray; then restart_service_soft xray || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; if service_restart_permitted xray; then restart_service_soft xray 2>/dev/null || true; fi; die "$(tr_msg dp_xray_restart)"; }; fi
    else
        xray_hot_add_inbound "$tmp_json" || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; if service_restart_permitted xray; then restart_service_soft xray 2>/dev/null || true; fi; die "$(tr_msg dp_socks5_add)"; }
    fi
    rm -f "$tmp_json"

    # Firewall: TCP + UDP.
    ( allowPort "$port" tcp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; if service_restart_permitted xray; then restart_service_soft xray 2>/dev/null || true; fi; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    ( allowPort "$port" udp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; if service_restart_permitted xray; then restart_service_soft xray 2>/dev/null || true; fi; _recycle_port_rules_if_unused "$port" 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/udp")"; }
    save_firewall_rules || { if restore_cfg_backup "$cfg_bak" "$cfg"; then if service_restart_permitted xray; then restart_service_soft xray 2>/dev/null || msg "${RED}[!] $(tr_msg rollback_restart_fail)${NC}"; fi; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; _recycle_port_rules_if_unused "$port" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    # Ensure the service is running (minimal-install path or API-unavailable hosts).
    ensure_service_running_soft xray || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; die "$(tr_msg dp_xray_restart)"; }
    rm -f -- "$cfg_bak"
    (( ${_jq_tmp:-0} == 1 )) && rm -f -- "$_jq_cfg" 2>/dev/null || true
    trap - EXIT
    restore_saved_trap EXIT "$_socks5_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_xray)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    msg "${GREEN}$(tr_msg socks5_done)${NC}"
    msg "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    generate_qr "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    register_standalone_link "${ABOX_DEPLOY_STEM:-socks5-xray}" "$(tprintf sl_node_port 'SOCKS5 (Xray)' "$port")" "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    auto_backup_silent "post-deployment snapshot: socks5 (xray)" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}


# ============ Retired xray-latest legacy handling (C2, 2026-11-09) ============
# xray-latest is retired: no new instance may be deployed. A host may still
# carry one installed by an older A-Box. Detection is read-only and never
# deletes anything; retirement runs only on an explicit decision
# (interactive confirmation or ABOX_LEGACY_XL_RETIRE=1) and is re-runnable.
# Detector modes are diagnostic values, never a promise: takeover = the old
# install already occupies the normal xray slot; coexist = a separate
# xray-latest service/binary/dir exists; unknown = legacy evidence exists
# but no state file names a mode; mixed = evidence contradicts the state
# file (unclassifiable); none = definitely no legacy evidence.
# Path roots follow the usual env-override conventions so fixtures can
# redirect them (ABOX_DIR, ABOX_USERS_DIR, ABOX_CORE_OWNERSHIP,
# XL_LEGACY_BIN / XL_LEGACY_SYSTEMD_DIR / XL_LEGACY_INITD_DIR /
# XL_LEGACY_CONFD_DIR / XL_LEGACY_SNAPSHOT_DIR); production defaults are
# the real system paths.

xray_latest_legacy_detect() {
    # Prints the mode on stdout. Returns 0 = legacy evidence exists,
    # 1 = definitely none, 2 = detection failed / layout unclassifiable.
    local _abox_dir="${ABOX_DIR:-/etc/ddr}"
    local _state="$_abox_dir/.xray-latest-state"
    local _bin="${XL_LEGACY_BIN:-/usr/local/bin/xray-latest}"
    local _dir="$_abox_dir/xray-latest"
    local _cfg="$_dir/config.json"
    local _sysdir="${XL_LEGACY_SYSTEMD_DIR:-/etc/systemd/system}"
    local _initd="${XL_LEGACY_INITD_DIR:-/etc/init.d}"
    local _confd="${XL_LEGACY_CONFD_DIR:-/etc/conf.d}"
    local _mode='' _have=0 _xl_paths=0 _slot=0 _line _v _seen_mode=0 _seen_ver=0
    # 1. State file: strict parse, never source. A present-but-malformed
    # file is unclassifiable (rc 2), never "none".
    if [[ -e "$_state" || -L "$_state" ]]; then
        [[ -f "$_state" && ! -L "$_state" ]] || { printf 'mixed\n'; return 2; }
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            case "$_line" in
                ''|'#'*) continue ;;
                mode=*)
                    (( _seen_mode == 0 )) || { printf 'mixed\n'; return 2; }
                    _seen_mode=1; _v="${_line#mode=}"
                    case "$_v" in takeover|coexist) _mode="$_v" ;; *) printf 'mixed\n'; return 2 ;; esac ;;
                version=*)
                    (( _seen_ver == 0 )) || { printf 'mixed\n'; return 2; }
                    _seen_ver=1; _v="${_line#version=}"
                    [[ "$_v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'mixed\n'; return 2; } ;;
                *) printf 'mixed\n'; return 2 ;;
            esac
        done < "$_state"
        (( _seen_mode == 1 )) || { printf 'mixed\n'; return 2; }
        _have=1
    fi
    # 2. XL-specific paths (binary / dir / config / units / enable links).
    if [[ -e "$_bin" || -L "$_bin" ]]; then _have=1; _xl_paths=1; fi
    if [[ -e "$_dir" || -L "$_dir" ]]; then _have=1; _xl_paths=1; fi
    if [[ -e "$_cfg" || -L "$_cfg" ]]; then _have=1; _xl_paths=1; fi
    if [[ -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" ]]; then _have=1; _xl_paths=1; fi
    local _w
    for _w in "$_sysdir"/*.wants/xray-latest.service "$_sysdir/xray-latest.service.d"; do
        [[ -e "$_w" || -L "$_w" ]] && { _have=1; _xl_paths=1; }
    done
    if [[ -e "$_initd/xray-latest" || -L "$_initd/xray-latest" ]]; then _have=1; _xl_paths=1; fi
    if [[ -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]]; then _have=1; _xl_paths=1; fi
    abox_owns_service xray-latest 2>/dev/null && { _have=1; _xl_paths=1; }
    # 3. Manifest rows, registry files, link indexes, live processes.
    # NOTE: managed_service_state_value is NOT usable here: systemctl
    # reports "inactive" even for a unit that does not exist.
    local _manifest="${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}"
    if [[ -f "$_manifest" && ! -L "$_manifest" ]]; then
        awk -F'\t' '$2 == "xray-latest" {found=1; exit} END {exit !found}' "$_manifest" 2>/dev/null && _have=1
    fi
    local _udir="${ABOX_USERS_DIR:-$_abox_dir/users.d}"
    local _rf
    for _rf in "$_udir"/xray-latest__*.json; do
        [[ -f "$_rf" && ! -L "$_rf" ]] && _have=1
    done
    local _lf
    for _lf in "$_abox_dir/standalone-links.d"/latest-*.link; do
        [[ -f "$_lf" && ! -L "$_lf" ]] && _have=1
    done
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$_bin" >/dev/null 2>&1 && _have=1
    fi
    # 4. Decide.
    if (( _have == 0 )); then printf 'none\n'; return 1; fi
    if [[ -n "$_mode" ]]; then
        case "$_mode" in
            coexist)
                if (( _xl_paths == 1 )); then printf 'coexist\n'; return 0; fi
                printf 'mixed\n'; return 2 ;;
            takeover)
                # Clean takeover: normal slot occupied, no XL paths.
                # Classification only; adoption verifies strictly.
                local _slot_bin="${XRAY_SLOT_BIN:-/usr/local/bin/xray}"
                local _slot_cfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}"
                if [[ -e "$_slot_bin" || -L "$_slot_bin" ]]; then _slot=1; fi
                if [[ -e "$_slot_cfg" || -L "$_slot_cfg" ]]; then _slot=1; fi
                abox_owns_service xray 2>/dev/null && _slot=1
                if (( _slot == 1 && _xl_paths == 0 )); then printf 'takeover\n'; return 0; fi
                printf 'mixed\n'; return 2 ;;
        esac
    fi
    printf 'unknown\n'; return 0
}

_xl_legacy_drop_manifest_rows() {
    # Remove xray-latest rows (field 2) from the ownership manifest.
    # Records only, never the file itself. Failure is REPORTED (rc 1):
    # callers treat it as a refusal, not a silent best-effort -- the
    # re-detect after adoption/retirement is the gate that catches
    # leftovers, and a silent drop failure would hide them until then.
    local _mf="${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}"
    [[ -f "$_mf" && ! -L "$_mf" ]] || return 0
    local _tmp
    _tmp=$(mktemp "${_mf}.legacy.XXXXXX" 2>/dev/null) || return 1
    awk -F'\t' '$2 != "xray-latest"' "$_mf" > "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp" 2>/dev/null || true
    chown root:root -- "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$_mf" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    return 0
}

_xl_legacy_adopt() {
    # Adopt a takeover that already occupies the normal xray slot.
    # Verifies everything BEFORE touching anything; deletes only the
    # legacy state file, last. A stopped service is never started.
    local _abox_dir="${ABOX_DIR:-/etc/ddr}"
    local _state="$_abox_dir/.xray-latest-state"
    local _bin="${XL_LEGACY_BIN:-/usr/local/bin/xray-latest}"
    local _dir="$_abox_dir/xray-latest"
    local _sysdir="${XL_LEGACY_SYSTEMD_DIR:-/etc/systemd/system}"
    local _initd="${XL_LEGACY_INITD_DIR:-/etc/init.d}"
    local _confd="${XL_LEGACY_CONFD_DIR:-/etc/conf.d}"
    local _slot_bin="${XRAY_SLOT_BIN:-/usr/local/bin/xray}"
    local _slot_cfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}"
    local _ver='' _unit='' _pid='' _cmd='' _m2='' _r2=0
    # No XL-specific paths may survive in a clean takeover.
    if [[ -e "$_bin" || -L "$_bin" || -e "$_dir" || -L "$_dir" || -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" || -e "$_initd/xray-latest" || -L "$_initd/xray-latest" || -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]]; then
        msg "${RED}[!] Takeover adoption refused: xray-latest paths still exist; manual migration required.${NC}" >&2
        return 1
    fi
    # Normal slot: binary + config, root-owned, correct types.
    [[ -f "$_slot_bin" && ! -L "$_slot_bin" && -x "$_slot_bin" ]] || { msg "${RED}[!] Takeover adoption refused: normal Xray binary is missing or not executable.${NC}" >&2; return 1; }
    # Root-owned is necessary but not sufficient: a root-owned file
    # with group/other write bits is writable by non-root users, so
    # the mode gate below is required before executing it as root.
    # (Owner write alone, e.g. 0700/0755, is allowed.)
    local _slot_uid=''
    _slot_uid=$(stat -c %u -- "$_slot_bin" 2>/dev/null) || { msg "${RED}[!] Takeover adoption refused: cannot determine normal Xray binary owner.${NC}" >&2; return 1; }
    [[ "$_slot_uid" == '0' ]] || { msg "${RED}[!] Takeover adoption refused: normal Xray binary is not root-owned.${NC}" >&2; return 1; }
    path_mode_has_no_group_other_write "$_slot_bin" || { msg "${RED}[!] Takeover adoption refused: normal Xray binary is group- or other-writable; manual review required.${NC}" >&2; return 1; }
    [[ -f "$_slot_cfg" && ! -L "$_slot_cfg" ]] || { msg "${RED}[!] Takeover adoption refused: normal Xray config is missing.${NC}" >&2; return 1; }
    jsonc_strip_comments "$_slot_cfg" 2>/dev/null | jq empty >/dev/null 2>&1 || { msg "${RED}[!] Takeover adoption refused: normal Xray config is not valid JSON.${NC}" >&2; return 1; }
    # Config test with the normal Xray runtime identity.
    XRAY_LOCATION_ASSET=/usr/local/share/xray "$_slot_bin" run -test -config "$_slot_cfg" >/dev/null 2>&1 || { msg "${RED}[!] Takeover adoption refused: normal Xray config fails the core self-test.${NC}" >&2; return 1; }
    # Service: A-Box-owned, ExecStart points at the normal slot.
    abox_owns_service xray 2>/dev/null || { msg "${RED}[!] Takeover adoption refused: xray is not an A-Box-managed service.${NC}" >&2; return 1; }
    _unit=$(service_unit_path xray 2>/dev/null || true)
    [[ -n "$_unit" && -f "$_unit" && ! -L "$_unit" ]] || { msg "${RED}[!] Takeover adoption refused: xray unit file is missing.${NC}" >&2; return 1; }
    if grep -Fq 'xray-latest' "$_unit" 2>/dev/null; then
        msg "${RED}[!] Takeover adoption refused: xray unit still references xray-latest.${NC}" >&2; return 1
    fi
    grep -Fq "$_slot_bin" "$_unit" 2>/dev/null || { msg "${RED}[!] Takeover adoption refused: xray unit does not reference the normal Xray binary.${NC}" >&2; return 1; }
    # Live check: if the service runs, it must run the verified binary+config.
    if is_service_running xray 2>/dev/null; then
        _pid=$(managed_service_pid xray 2>/dev/null || true)
        [[ -n "$_pid" && "$_pid" =~ ^[0-9]+$ ]] || { msg "${RED}[!] Takeover adoption refused: xray is running but its PID cannot be determined.${NC}" >&2; return 1; }
        # R34-M3: the old check joined the NUL-separated cmdline with
        # spaces and substring-matched the binary+config paths, so a
        # process running `-config .../config.json.old` passed (the
        # verified path is a substring of it). Match the exact
        # -config argument value instead (last one wins, like Go flag
        # parsing), and confirm the running binary via /proc/PID/exe
        # rather than the joined cmdline.
        local _exe='' _arg='' _cfg_arg=''
        _exe=$(readlink -- "/proc/$_pid/exe" 2>/dev/null || true)
        [[ "$_exe" == "$_slot_bin" ]] || { msg "${RED}[!] Takeover adoption refused: running xray does not use the verified binary.${NC}" >&2; return 1; }
        while IFS= read -r -d '' _arg; do
            case "$_arg" in
                -config) IFS= read -r -d '' _cfg_arg || _cfg_arg='' ;;
                -config=*) _cfg_arg="${_arg#-config=}" ;;
            esac
        done < "/proc/$_pid/cmdline" 2>/dev/null
        [[ "$_cfg_arg" == "$_slot_cfg" ]] || { msg "${RED}[!] Takeover adoption refused: running xray does not use the verified binary+config.${NC}" >&2; return 1; }
    fi
    # Version for the adoption notice.
    _ver=$(core_version_from_output "$("$_slot_bin" version 2>/dev/null | head -n 1 || true)" 2>/dev/null || true)
    [[ -n "$_ver" ]] || _ver='unknown'
    # Adopt: drop stale xray-latest manifest rows FIRST (checked),
    # then delete only the legacy state file, last. The adopted
    # instance's rows are field-2 == xray and stay untouched.
    _xl_legacy_drop_manifest_rows || { msg "${RED}[!] Takeover adoption failed: could not drop stale xray-latest manifest rows.${NC}" >&2; return 1; }
    rm -f -- "$_state" || { msg "${RED}[!] Takeover adoption failed: could not remove the legacy state file.${NC}" >&2; return 1; }
    # Re-detect: must now report none.
    _m2=$(xray_latest_legacy_detect 2>/dev/null); _r2=$?
    if (( _r2 != 1 )); then
        msg "${RED}[!] Takeover adopted, but legacy evidence remains (mode: ${_m2:-unknown}); manual cleanup required.${NC}" >&2
        return 1
    fi
    msg "${GREEN}$(tprintf legacy_xl_adopted "$_ver")${NC}" >&2
    return 0
}

_xl_legacy_retire_coexist() {
    # Retire a separate coexist instance. Explicit authorisation only:
    # ABOX_LEGACY_XL_RETIRE=1, or an interactive confirmation on a tty.
    # Non-interactive default is abort. Re-runnable.
    local _abox_dir="${ABOX_DIR:-/etc/ddr}"
    local _state="$_abox_dir/.xray-latest-state"
    local _bin="${XL_LEGACY_BIN:-/usr/local/bin/xray-latest}"
    local _dir="$_abox_dir/xray-latest"
    local _cfg="$_dir/config.json"
    local _sysdir="${XL_LEGACY_SYSTEMD_DIR:-/etc/systemd/system}"
    local _initd="${XL_LEGACY_INITD_DIR:-/etc/init.d}"
    local _confd="${XL_LEGACY_CONFD_DIR:-/etc/conf.d}"
    local _mode='coexist' _snapfile='' _ans=''
    # R34-M2: the user registry dir honours ABOX_USERS_DIR everywhere
    # else (detect, registries, merge); the four globs below used the
    # fixed default instead, so an overridden dir's credentials were
    # never snapshotted, deleted or residual-checked. One local, used
    # by all four sites.
    local _udir="${ABOX_USERS_DIR:-$_abox_dir/users.d}"
    # 1. Authorisation.
    if [[ "${ABOX_LEGACY_XL_RETIRE:-0}" != '1' ]]; then
        [[ -t 0 ]] || { msg "${RED}[!] Retired xray-latest instance found, but this run is not interactive; set ABOX_LEGACY_XL_RETIRE=1 to retire it explicitly.${NC}" >&2; return 1; }
        printf '%s' "$(tr_msg legacy_xl_retire_prompt)" || return 1
        IFS= read -r _ans || return 1
        case "$_ans" in y|Y|yes|YES) : ;; *) msg "${YELLOW}[!] Retire cancelled; xray-latest instance left untouched.${NC}" >&2; return 1 ;; esac
    fi
    # 1b. Ownership gate (R15-01): the instance to retire must be an
    # A-Box-managed service RIGHT NOW. History (mode=takeover in the
    # state file) is not proof: the same-name service may since have
    # been replaced by a foreign deployment. A foreign service is
    # refused, never stopped or deleted. Exception: the narrow
    # residual-artifact path below -- no same-name service definition
    # anywhere, not running, no live process -- allows artifacts-only
    # cleanup of a partially retired instance whose unit is already
    # gone (the snapshot in step 3 still preserves everything).
    local _residual=0
    if abox_owns_service xray-latest 2>/dev/null; then
        _residual=0
    else
        # Residual-artifact path: verify, in order, that no service
        # definition exists (same-name unit anywhere, plus the
        # retire-local unit/drop-in/enable-link paths, plus the init
        # script on OpenRC where it IS the service definition), that
        # the service is not running, and that no process runs the
        # legacy binary. ANY of these fails -> refuse.
        local _ru _rinit='unknown' _wl0
        _rinit=$(effective_init_system 2>/dev/null || printf 'unknown')
        _ru=$(same_name_service_unit_path xray-latest 2>/dev/null || true)
        if [[ -n "$_ru" ]] || [[ -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" ]] || [[ -d "$_sysdir/xray-latest.service.d" && ! -L "$_sysdir/xray-latest.service.d" ]]; then
            msg "${RED}[!] Refusing to retire: xray-latest is not an A-Box-managed service (a same-name service definition exists); manual handling required.${NC}" >&2
            return 1
        fi
        if [[ "$_rinit" == openrc ]] && [[ -e "$_initd/xray-latest" || -L "$_initd/xray-latest" ]]; then
            msg "${RED}[!] Refusing to retire: xray-latest is not an A-Box-managed service (a same-name init script exists); manual handling required.${NC}" >&2
            return 1
        fi
        for _wl0 in "$_sysdir"/*.wants/xray-latest.service; do
            [[ -e "$_wl0" || -L "$_wl0" ]] || continue
            msg "${RED}[!] Refusing to retire: xray-latest is not an A-Box-managed service (a same-name enable link exists); manual handling required.${NC}" >&2
            return 1
        done
        if is_service_running xray-latest 2>/dev/null; then
            msg "${RED}[!] Refusing to retire: xray-latest is not an A-Box-managed service and is running; manual handling required.${NC}" >&2
            return 1
        fi
        if command -v pgrep >/dev/null 2>&1 && pgrep -f "$_bin" >/dev/null 2>&1; then
            msg "${RED}[!] Refusing to retire: a process is still running the xray-latest binary; manual handling required.${NC}" >&2
            return 1
        fi
        _residual=1
    fi
    # 2. Pre-checks (before stopping or deleting anything).
    # The mount preflight covers the COMPLETE retirement target set --
    # every path a later step deletes or rewrites -- and a mount (or a
    # mount-check failure, which path_tree_has_mountpoint reports as 0,
    # fail-closed) is an explicit refusal, never a silent skip. It runs
    # before the snapshot: nothing has changed yet if it refuses.
    local -a _pre_targets=()
    [[ -e "$_bin" || -L "$_bin" ]] && _pre_targets+=("$_bin")
    [[ -e "$_dir" || -L "$_dir" ]] && _pre_targets+=("$_dir")
    [[ -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" ]] && _pre_targets+=("$_sysdir/xray-latest.service")
    [[ -e "$_sysdir/xray-latest.service.d" || -L "$_sysdir/xray-latest.service.d" ]] && _pre_targets+=("$_sysdir/xray-latest.service.d")
    [[ -e "$_initd/xray-latest" || -L "$_initd/xray-latest" ]] && _pre_targets+=("$_initd/xray-latest")
    [[ -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]] && _pre_targets+=("$_confd/xray-latest")
    [[ -e "$_state" || -L "$_state" ]] && _pre_targets+=("$_state")
    local _pt _sp2
    for _sp2 in "$_udir"/xray-latest__*.json "$_abox_dir/standalone-links.d"/latest-*.link "$_sysdir"/*.wants/xray-latest.service; do
        [[ -e "$_sp2" || -L "$_sp2" ]] && _pre_targets+=("$_sp2")
    done
    for _pt in "${_pre_targets[@]}"; do
        path_tree_has_mountpoint "$_pt" && { msg "${RED}[!] Refusing to retire: mountpoint at or under ${_pt}.${NC}" >&2; return 1; }
    done
    if [[ -e "$_dir" || -L "$_dir" ]]; then
        [[ ! -L "$_dir" ]] || { msg "${RED}[!] Refusing to retire: /etc/ddr/xray-latest is a symlink.${NC}" >&2; return 1; }
        path_parent_chain_safe "$_dir" || { msg "${RED}[!] Refusing to retire: unsafe parent path for the xray-latest directory.${NC}" >&2; return 1; }
    fi
    if [[ -e "$_bin" || -L "$_bin" ]]; then
        [[ ! -L "$_bin" ]] || { msg "${RED}[!] Refusing to retire: xray-latest binary is a symlink.${NC}" >&2; return 1; }
        path_parent_chain_safe "$_bin" || { msg "${RED}[!] Refusing to retire: unsafe parent path for the xray-latest binary.${NC}" >&2; return 1; }
    fi
    # R6-F09-3: a symlinked drop-in dir is refused up front, like the
    # symlinked binary/dir (snapshot must never follow it, and the
    # delete step would skip it, leaving ambiguous residue).
    if [[ -L "$_sysdir/xray-latest.service.d" ]]; then
        msg "${RED}[!] Refusing to retire: symlinked xray-latest unit drop-in directory.${NC}" >&2
        return 1
    fi
    # 3. Snapshot (recoverable copy) before any change.
    local _snapdir="${XL_LEGACY_SNAPSHOT_DIR:-$_abox_dir/backups}"
    mkdir -p "$_snapdir" 2>/dev/null || { msg "${RED}[!] Could not create the retire snapshot directory; refusing to retire.${NC}" >&2; return 1; }
    chmod 700 "$_snapdir" 2>/dev/null || true
    local -a _snap_paths=()
    [[ -e "$_bin" || -L "$_bin" ]] && _snap_paths+=("$_bin")
    [[ -e "$_dir" || -L "$_dir" ]] && _snap_paths+=("$_dir")
    [[ -e "$_state" || -L "$_state" ]] && _snap_paths+=("$_state")
    [[ -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" ]] && _snap_paths+=("$_sysdir/xray-latest.service")
    [[ -d "$_sysdir/xray-latest.service.d" && ! -L "$_sysdir/xray-latest.service.d" ]] && _snap_paths+=("$_sysdir/xray-latest.service.d")
    [[ -e "$_initd/xray-latest" || -L "$_initd/xray-latest" ]] && _snap_paths+=("$_initd/xray-latest")
    [[ -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]] && _snap_paths+=("$_confd/xray-latest")
    local _sp
    for _sp in "$_udir"/xray-latest__*.json "$_abox_dir/standalone-links.d"/latest-*.link; do
        [[ -f "$_sp" && ! -L "$_sp" ]] && _snap_paths+=("$_sp")
    done
    if (( ${#_snap_paths[@]} > 0 )); then
        # 05b-01: the snapshot name must be unique per retire, not just
        # per second. A fixed second-resolution name let a same-second
        # retry overwrite the only complete snapshot of the previous
        # instance. mktemp creates the file atomically; XXXXXX must be
        # the last 6 characters of the template, so the .tar.gz suffix
        # is added by renaming the just-created file, whose name no
        # other process can know. Any failure refuses the retire.
        _snapfile=$(mktemp "$_snapdir/xray-latest-retired-$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null) || { msg "${RED}[!] Could not create the retire snapshot file; refusing to retire.${NC}" >&2; return 1; }
        mv -f -- "$_snapfile" "$_snapfile.tar.gz" || { rm -f -- "$_snapfile"; msg "${RED}[!] Could not name the retire snapshot file; refusing to retire.${NC}" >&2; return 1; }
        _snapfile="$_snapfile.tar.gz"
        tar -czf "$_snapfile" -- "${_snap_paths[@]}" 2>/dev/null || { msg "${RED}[!] Could not snapshot the xray-latest instance; refusing to retire.${NC}" >&2; return 1; }
        chmod 600 "$_snapfile" 2>/dev/null || true
    fi
    # 4. Stop the service and verify it stopped; on failure delete nothing.
    # R15-02: the stop return code AND an explicit state query are BOTH
    # required. A failed stop is a refusal (the old `|| true` discarded
    # it); a failed state query is "state unknown", also a refusal --
    # is_service_running conflates query failure with "not running" and
    # must not be used as the proof. The state value must be exactly 0.
    # The pgrep check stays as an extra guard, not as the state proof.
    # The residual path verified there is no service to stop, so it
    # skips this step entirely.
    if (( _residual == 0 )); then
        stop_abox_service xray-latest 2>/dev/null || { msg "${RED}[!] Refusing to retire: could not stop xray-latest; deleting nothing.${NC}" >&2; return 1; }
        local _stop_state
        _stop_state=$(service_active_state_value xray-latest 2>/dev/null) || { msg "${RED}[!] Refusing to retire: xray-latest state is unknown after stop; deleting nothing.${NC}" >&2; return 1; }
        [[ "$_stop_state" == '0' ]] || { msg "${RED}[!] xray-latest is still active after stop; refusing to delete its files.${NC}" >&2; return 1; }
        if command -v pgrep >/dev/null 2>&1 && pgrep -f "$_bin" >/dev/null 2>&1; then
            msg "${RED}[!] A process is still running the xray-latest binary; refusing to delete its files.${NC}" >&2
            return 1
        fi
    fi
    # 5. Delete the core family via the manifest-verified path, handling
    # its NATIVE return code locally (R15-03). The shared wrapper
    # remove_owned_core_family collapses rc 3 (files changed after
    # registration, preserved) to 1, and its force_heal semantics do not
    # apply to retirement, so it must not be used here.
    #   0: verified removal; the expected family paths must be gone --
    #      leftovers are a refusal, never a reason to force-delete.
    #   2: no manifest rows; the force path is allowed only with current
    #      ownership proof (or the verified residual path) + the
    #      successful preflight above.
    #   3: files changed after registration; they were preserved --
    #      refuse and keep files, records and state.
    #   other: refuse.
    remove_recorded_core_family xray-latest; local _rrc=$?
    case "$_rrc" in
        0) : ;;
        2)
            if (( _residual == 1 )) || abox_owns_service xray-latest 2>/dev/null; then
                remove_core_family_force xray-latest 2>/dev/null || { msg "${RED}[!] Could not remove the xray-latest core family (no manifest); state file kept, re-run after fixing the cause.${NC}" >&2; return 1; }
            else
                msg "${RED}[!] Refusing to retire: no per-file ownership manifest for xray-latest and no current ownership proof; manual handling required.${NC}" >&2
                return 1
            fi
            ;;
        3)
            msg "${RED}[!] Refusing to retire: one or more xray-latest files changed after ownership registration; they were preserved instead of being deleted. State file kept.${NC}" >&2
            return 1
            ;;
        *)
            msg "${RED}[!] Refusing to retire: manifest-verified removal failed (rc=${_rrc}); state file kept.${NC}" >&2
            return 1
            ;;
    esac
    # 6. Verify the files are actually gone. Leftovers after a reported
    # success are a refusal -- the old "files remain, therefore force"
    # fallback deleted files the manifest path had just refused to
    # touch (including rc-3 preserved files).
    if [[ -e "$_bin" || -L "$_bin" || -e "$_dir" || -L "$_dir" || -e "$_cfg" || -L "$_cfg" || -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" || -e "$_initd/xray-latest" || -L "$_initd/xray-latest" || -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]]; then
        msg "${RED}[!] xray-latest files remain after removal; state file kept.${NC}" >&2
        return 1
    fi
    # 6b. Manifest: drop stale xray-latest rows (records only). The
    # manifest-verified path already removes its own rows; the force
    # path does not, so this covers manifest-less old installs. A
    # failure here is a refusal, not a silent best-effort (R15-03).
    _xl_legacy_drop_manifest_rows || { msg "${RED}[!] Could not drop stale xray-latest manifest rows; state file kept.${NC}" >&2; return 1; }
    # 7. Shared indexes: remove records only, per item, never whole files.
    # Enable links (symlinks at the XL unit) and drop-ins go here too.
    local _lf2 _wl
    for _lf2 in "$_abox_dir/standalone-links.d"/latest-*.link; do
        [[ -f "$_lf2" && ! -L "$_lf2" ]] || continue
        rm -f -- "$_lf2" || { msg "${RED}[!] Could not remove link index $_lf2; state file kept.${NC}" >&2; return 1; }
    done
    for _wl in "$_sysdir"/*.wants/xray-latest.service; do
        [[ -L "$_wl" ]] || continue
        case "$(readlink -- "$_wl" 2>/dev/null || true)" in
            *xray-latest*) rm -f -- "$_wl" || { msg "${RED}[!] Could not remove enable link $_wl; state file kept.${NC}" >&2; return 1; } ;;
        esac
    done
    if [[ -d "$_sysdir/xray-latest.service.d" && ! -L "$_sysdir/xray-latest.service.d" ]]; then
        if path_tree_has_nested_mountpoint "$_sysdir/xray-latest.service.d"; then
            msg "${RED}[!] Refusing to retire: mountpoint under the xray-latest unit drop-in directory; state file kept.${NC}" >&2
            return 1
        fi
        rm -rf -- "$_sysdir/xray-latest.service.d" || { msg "${RED}[!] Could not remove unit drop-ins; state file kept.${NC}" >&2; return 1; }
    fi
    local _rg2
    for _rg2 in "$_udir"/xray-latest__*.json; do
        [[ -f "$_rg2" && ! -L "$_rg2" ]] || continue
        rm -f -- "$_rg2" || { msg "${RED}[!] Could not remove registry $_rg2; state file kept.${NC}" >&2; return 1; }
    done
    if systemd_available; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
    # 7b. Residual-evidence verification BEFORE the state file is
    # removed (R15-04): no legacy evidence may remain except the state
    # file itself. The final re-detect in step 9 is the last gate, but
    # it must not be the one that discovers a leftover after the state
    # file is already gone. This check is symlink-inclusive where the
    # re-detect is not: a symlinked registry file or link index is
    # evidence even though the cleanup loops above (correctly) refuse
    # to follow symlinks.
    local _resid=0 _rf2 _lf3 _wl2 _marc=0
    [[ -e "$_bin" || -L "$_bin" || -e "$_dir" || -L "$_dir" || -e "$_cfg" || -L "$_cfg" || -e "$_sysdir/xray-latest.service" || -L "$_sysdir/xray-latest.service" || -e "$_sysdir/xray-latest.service.d" || -L "$_sysdir/xray-latest.service.d" || -e "$_initd/xray-latest" || -L "$_initd/xray-latest" || -e "$_confd/xray-latest" || -L "$_confd/xray-latest" ]] && _resid=1
    for _rf2 in "$_udir"/xray-latest__*.json; do
        [[ -e "$_rf2" || -L "$_rf2" ]] && _resid=1
    done
    for _lf3 in "$_abox_dir/standalone-links.d"/latest-*.link; do
        [[ -e "$_lf3" || -L "$_lf3" ]] && _resid=1
    done
    for _wl2 in "$_sysdir"/*.wants/xray-latest.service; do
        [[ -e "$_wl2" || -L "$_wl2" ]] && _resid=1
    done
    if [[ -f "${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}" && ! -L "${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}" ]]; then
        awk -F'\t' '$2 == "xray-latest" {found=1; exit} END {exit !found}' "$ABOX_CORE_OWNERSHIP" 2>/dev/null; _marc=$?
        (( _marc == 0 || _marc == 2 )) && _resid=1
    fi
    if (( _resid == 1 )); then
        msg "${RED}[!] Refusing to finish retirement: legacy xray-latest evidence remains; state file kept for re-detection.${NC}" >&2
        return 1
    fi
    # 8. State file LAST.
    rm -f -- "$_state" || { msg "${RED}[!] Could not remove the legacy state file.${NC}" >&2; return 1; }
    # 9. Re-detect: must now report none.
    local _m2='' _r2=0
    _m2=$(xray_latest_legacy_detect 2>/dev/null); _r2=$?
    if (( _r2 != 1 )); then
        msg "${RED}[!] xray-latest files removed, but legacy evidence remains (mode: ${_m2:-unknown}); manual cleanup required.${NC}" >&2
        return 1
    fi
    msg "${GREEN}$(tprintf legacy_xl_retired "$_mode")${NC}" >&2
    [[ -n "${_snapfile:-}" && -f "$_snapfile" ]] && msg "${CYAN}[*] Retired instance snapshot: $_snapfile${NC}" >&2
    return 0
}

xray_latest_legacy_retire() {
    # Detect, then adopt (takeover) or retire (coexist) the legacy
    # instance. Returns 0 when there is nothing to do or the legacy
    # instance was handled; 1 when handling was aborted or failed.
    # Never deletes anything without an explicit decision, and never
    # prints a success message on a failed run.
    local _mode='' _rc=0
    _mode=$(xray_latest_legacy_detect 2>/dev/null); _rc=$?
    if (( _rc == 1 )); then return 0; fi
    if (( _rc == 2 )); then
        msg "${RED}[!] $(tprintf legacy_xl_detected "${_mode:-mixed}")${NC}" >&2
        msg "${YELLOW}[!] Legacy xray-latest layout is unclassifiable; resolve it manually before continuing (verify the instance is really gone, then remove ${ABOX_DIR:-/etc/ddr}/.xray-latest-state if it is stale).${NC}" >&2
        return 1
    fi
    msg "${YELLOW}[!] $(tprintf legacy_xl_detected "$_mode")${NC}" >&2
    case "$_mode" in
        takeover) _xl_legacy_adopt ;;
        coexist) _xl_legacy_retire_coexist ;;
        *) msg "${RED}[!] Legacy xray-latest mode '$_mode' needs manual handling; refusing to proceed.${NC}" >&2; return 1 ;;
    esac
}

restore_filter_legacy_xray_latest() {
    # $1 = staged backup root ($work/root), $2 = work dir ($work).
    # Strip retired xray-latest content from the STAGED backup only;
    # live files are never touched. A takeover backup's normal Xray
    # paths stay in the xray set. Returns 0 on success, 1 on failure.
    local _root="${1:-}" _work="${2:-}"
    [[ -n "$_root" && -n "$_work" && -d "$_root" && -d "$_work/meta" ]] || return 1
    local _p=''
    for _p in \
        "$_root/usr/local/bin/xray-latest" \
        "$_root/etc/ddr/xray-latest" \
        "$_root/etc/ddr/.xray-latest-state" \
        "$_root/etc/systemd/system/xray-latest.service" \
        "$_root/etc/systemd/system/xray-latest.service.d" \
        "$_root/etc/systemd/system"/*.wants/xray-latest.service \
        "$_root/etc/init.d/xray-latest" \
        "$_root/etc/conf.d/xray-latest"; do
        if [[ -L "$_p" ]]; then rm -f -- "$_p" || return 1;
        elif [[ -d "$_p" ]]; then rm -rf -- "$_p" || return 1;
        elif [[ -e "$_p" ]]; then rm -f -- "$_p" || return 1; fi
    done
    # R34-M4: the detector treats the drop-in dir and the .wants enable
    # links as legacy evidence, so the filter must strip them too --
    # and verify they are gone before reporting success. (An unmatched
    # wants glob stays literal and fails both tests, so it is a no-op
    # when nothing is linked.)
    local _chk
    for _chk in "$_root/etc/systemd/system/xray-latest.service.d" "$_root/etc/systemd/system"/*.wants/xray-latest.service; do
        [[ -e "$_chk" || -L "$_chk" ]] && return 1
    done
    local _g
    for _g in "$_root/etc/ddr/users.d"/xray-latest__*.json "$_root/etc/ddr/standalone-links.d"/latest-*.link; do
        [[ -e "$_g" || -L "$_g" ]] || continue
        rm -f -- "$_g" || return 1
    done
    # services.state: drop xray-latest lines (pipe-separated service|active|enabled).
    local _ss="$_work/meta/services.state"
    if [[ -f "$_ss" && ! -L "$_ss" ]]; then
        # R6-F09-5 (B'): capture the original metadata and restore+verify it
        # on the temp file BEFORE mv, so the rewrite never downgrades the
        # mode (e.g. 0600 -> 0644 under umask 022) or the owner. Any failure
        # leaves the original file untouched. (Plain mv, not mv -T: the
        # target must stay BusyBox-compatible; the pre-mv stat re-check
        # below guards the replace.)
        local _ss_meta _ss_id _ss_mode _ss_owner _ss_extra
        local _ss_now _ss_tmp_meta _tmp=''

        _ss_meta=$(stat -c '%d:%i %a %u:%g' -- "$_ss" 2>/dev/null) ||
            return 1
        read -r _ss_id _ss_mode _ss_owner _ss_extra <<< "$_ss_meta" ||
            return 1
        [[ "$_ss_id" =~ ^[0-9]+:[0-9]+$ &&
           "$_ss_mode" =~ ^[0-7]{3,4}$ &&
           "$_ss_owner" == 0:0 &&
           -z "$_ss_extra" ]] || return 1
        (( (8#$_ss_mode & 8#077) == 0 )) || return 1

        _tmp=$( ( umask 077; mktemp -- "$_ss.filter.XXXXXX" ) ) ||
            return 1

        ( umask 077
          awk -F'|' '$1 != "xray-latest"' "$_ss" > "$_tmp" 2>/dev/null
        ) || { rm -f -- "$_tmp"; return 1; }

        chown 0:0 -- "$_tmp" ||
            { rm -f -- "$_tmp"; return 1; }
        chmod "$_ss_mode" -- "$_tmp" ||
            { rm -f -- "$_tmp"; return 1; }

        _ss_tmp_meta=$(stat -c '%a %u:%g' -- "$_tmp" 2>/dev/null) ||
            { rm -f -- "$_tmp"; return 1; }
        [[ "$_ss_tmp_meta" == "$_ss_mode 0:0" ]] ||
            { rm -f -- "$_tmp"; return 1; }

        [[ -f "$_ss" && ! -L "$_ss" ]] ||
            { rm -f -- "$_tmp"; return 1; }
        _ss_now=$(stat -c '%d:%i %a %u:%g' -- "$_ss" 2>/dev/null) ||
            { rm -f -- "$_tmp"; return 1; }
        [[ "$_ss_now" == "$_ss_meta" ]] ||
            { rm -f -- "$_tmp"; return 1; }

        mv -f -- "$_tmp" "$_ss" ||
            { rm -f -- "$_tmp"; return 1; }
    fi
    # Ownership manifest: drop field-2 == xray-latest rows.
    local _mf="$_root/etc/ddr/.managed-core-files.tsv"
    if [[ -f "$_mf" && ! -L "$_mf" ]]; then
        # R11-F R6-3: same metadata-preserving rewrite as the
        # services.state branch above (B'): capture the original
        # metadata and restore+verify it on the temp file BEFORE mv,
        # so the rewrite never downgrades the mode (e.g. 0600 ->
        # 0644 under umask 022) or the owner. Any failure leaves
        # the original file untouched. (Plain mv, not mv -T: the
        # target must stay BusyBox-compatible; the pre-mv stat
        # re-check below guards the replace.)
        local _mf_meta _mf_id _mf_mode _mf_owner _mf_extra
        local _mf_now _mf_tmp_meta _tmp2=''

        _mf_meta=$(stat -c '%d:%i %a %u:%g' -- "$_mf" 2>/dev/null) ||
            return 1
        read -r _mf_id _mf_mode _mf_owner _mf_extra <<< "$_mf_meta" ||
            return 1
        [[ "$_mf_id" =~ ^[0-9]+:[0-9]+$ &&
           "$_mf_mode" =~ ^[0-7]{3,4}$ &&
           "$_mf_owner" == 0:0 &&
           -z "$_mf_extra" ]] || return 1
        (( (8#$_mf_mode & 8#077) == 0 )) || return 1

        _tmp2=$( ( umask 077; mktemp -- "$_mf.filter.XXXXXX" ) ) ||
            return 1

        ( umask 077
          awk -F'\t' '$2 != "xray-latest"' "$_mf" > "$_tmp2" 2>/dev/null
        ) || { rm -f -- "$_tmp2"; return 1; }

        chown 0:0 -- "$_tmp2" ||
            { rm -f -- "$_tmp2"; return 1; }
        chmod "$_mf_mode" -- "$_tmp2" ||
            { rm -f -- "$_tmp2"; return 1; }

        _mf_tmp_meta=$(stat -c '%a %u:%g' -- "$_tmp2" 2>/dev/null) ||
            { rm -f -- "$_tmp2"; return 1; }
        [[ "$_mf_tmp_meta" == "$_mf_mode 0:0" ]] ||
            { rm -f -- "$_tmp2"; return 1; }

        [[ -f "$_mf" && ! -L "$_mf" ]] ||
            { rm -f -- "$_tmp2"; return 1; }
        _mf_now=$(stat -c '%d:%i %a %u:%g' -- "$_mf" 2>/dev/null) ||
            { rm -f -- "$_tmp2"; return 1; }
        [[ "$_mf_now" == "$_mf_meta" ]] ||
            { rm -f -- "$_tmp2"; return 1; }

        mv -f -- "$_tmp2" "$_mf" ||
            { rm -f -- "$_tmp2"; return 1; }
    fi
    return 0
}


deploy_xray() {
    local MODE_IN=$1 KEYPAIR
    # C2 (Q8): handle any retired xray-latest instance before any
    # backup or modification. Aborts the deploy until it is handled.
    xray_latest_legacy_retire || return 1
    clear; msg "${BOLD}${GREEN}$(tprintf deploy_xray_title "$MODE_IN")${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check
    if [[ "$MODE_IN" == *'ALL'* ]]; then residue_takeover_plan xray hysteria || return 1; assert_no_foreign_core_conflicts xray hysteria; else residue_takeover_plan xray || return 1; assert_no_foreign_core_conflicts xray; fi
    confirm_deployment_replacement xray "$MODE_IN"
    standalone_preserve_snapshot xray /usr/local/etc/xray/config.json || return 1
    if [[ "$MODE_IN" == *'ALL'* ]]; then begin_deployment_transaction "xray ${MODE_IN} deployment" xray hysteria || return 1; else begin_deployment_transaction "xray ${MODE_IN} deployment" xray || return 1; fi
    residue_takeover_clear || { deployment_transaction_rollback; return 1; }
    clean_nat_rules || die "$(tr_msg cl_nat)"
    clean_input_rules || die "$(tr_msg cl_input)"
    save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
    pre_install_setup xray "$MODE_IN" || { deployment_transaction_rollback; return 1; }
    abox_fetch_guard_start "xray ${MODE_IN}"
    release_ports
    get_architecture

    local xray_tmp xray_zip xray_ext geo_tmp
    xray_tmp=$(abox_mktemp_exec_dir A-Box-xray) || die "$(tr_msg dp_xray_tmpdir)"
    ABOX_DEPLOY_TX_TMP="$xray_tmp"
    xray_zip="$xray_tmp/xray_core.zip"
    xray_ext="$xray_tmp/xray_ext"
    mkdir -p "$xray_ext" || die 'Xray extraction directory creation failed.'
    abox_fetch_heartbeat
    clear_core_release_resolution XTLS/Xray-core
    fetch_github_release XTLS/Xray-core xray_core.zip "$xray_zip"
    abox_fetch_heartbeat
    extract_zip_member_safely "$xray_zip" xray "$xray_ext/xray" || die "$(tr_msg dp_xray_extract)"
    [[ -f "$xray_ext/xray" && ! -L "$xray_ext/xray" ]] || die "$(tr_msg dp_xray_bin)"
    chmod 755 "$xray_ext/xray" || die 'Xray staged binary chmod failed.'
    "$xray_ext/xray" version >/dev/null 2>&1 || die 'Xray staged binary execution check failed.'
    install_binary_atomically "$xray_ext/xray" /usr/local/bin/xray || die 'Xray binary atomic install failed.'
    /usr/local/bin/xray version >/dev/null 2>&1 || die "$(tr_msg dp_xray_exec)"
    install -d -m 755 /usr/local/share/xray || die 'Xray data directory creation failed.'
    # B9-03: config dir 750 root:abox-xray like sing-box/hysteria (was 755).
    # P0-1: use prepare_abox_runtime_config_dir to ensure group exists first.
    prepare_abox_runtime_config_dir xray /usr/local/etc/xray || die 'Xray config directory creation failed.'

    geo_tmp="$xray_tmp/geo"
    mkdir -p "$geo_tmp" || die "$(tr_msg dp_geo_tmpdir)"
    abox_fetch_heartbeat
    fetch_geo_data geoip.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat' "$geo_tmp/geoip.dat"
    abox_fetch_heartbeat
    fetch_geo_data geosite.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat' "$geo_tmp/geosite.dat"
    abox_fetch_heartbeat
    install_file_atomically "$geo_tmp/geoip.dat" /usr/local/share/xray/geoip.dat 644 || die "$(tr_msg dp_geoip_write)"
    install_file_atomically "$geo_tmp/geosite.dat" /usr/local/share/xray/geosite.dat 644 || die "$(tr_msg dp_geosite_write)"
    abox_fetch_guard_stop
    rm -rf -- "$xray_tmp"
    ABOX_DEPLOY_TX_TMP=''

    KEYPAIR=$(/usr/local/bin/xray x25519) || die "$(tr_msg dp_xray_keypair)"
    IFS=$'\t' read -r PK PBK < <(parse_x25519_keypair_output "$KEYPAIR") || die "$(tr_msg dp_xray_keyparse2)"
    [[ -n "$PK" && -n "$PBK" ]] || die "$(tr_msg dp_xray_keyempty2)"
    UUID=$(generate_robust_uuid) || die 'UUID generation failed.'
    SHORT_ID=$(openssl rand -hex 4 | tr -d '\n\r')
    SS_PASS=$(openssl rand -base64 16 | tr -d '\n\r')
    [[ -n "$SS_PASS" ]] || die "$(tr_msg dp_ss_keygen)"

    build_xray_config "$MODE_IN"
    chmod 600 /usr/local/etc/xray/config.json || die 'Xray config permission hardening failed.'
    jsonc_strip_comments /usr/local/etc/xray/config.json 2>/dev/null | jq empty >/dev/null 2>&1 || die "$(tr_msg dp_xray_json)"
    XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 || die "$(tr_msg dp_xray_check)"
    standalone_preserve_restore xray /usr/local/etc/xray/config.json || { deployment_transaction_rollback; return 1; }

    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin /etc/systemd/system/xray.service 644 <<'EOF_SVC' || die "$(tr_msg dp_xray_unit)"
# Managed by A-Box
[Unit]
Description=A-Box Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=abox-xray
Group=abox-xray
UMask=0077
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
NoNewPrivileges=true
PrivateTmp=true
Restart=always
RestartSec=10
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF_SVC
    else
        path_parent_chain_safe /etc/conf.d/xray || die "$(tr_msg dp_orc_parent)"
        [[ ! -L /etc/conf.d && (! -e /etc/conf.d || -d /etc/conf.d) ]] || die "$(tr_msg dp_orc_dir_unsafe)"
        mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
        write_file_atomically_from_stdin /etc/conf.d/xray 644 <<'EOF_XRAY_CONFD' || die "$(tr_msg dp_xray_confd)"
rc_ulimit="-n 1048576"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
EOF_XRAY_CONFD
        write_file_atomically_from_stdin /etc/init.d/xray 755 <<'EOF_SVC' || die "$(tr_msg dp_xray_initd)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
command_user="abox-xray:abox-xray"
capabilities="^cap_net_bind_service"
umask=077
pidfile="/run/xray.pid"
depend() { need net; }
EOF_SVC
        chmod +x /etc/init.d/xray || die "$(tr_msg dp_xray_chmod)"
    fi
    prepare_abox_runtime_permissions xray || die "$(tr_msg dp_xray_runtime)"
    service_manager start xray
    setup_geo_cron
    setup_active_defense
    setup_health_monitor

    if [[ "$MODE_IN" == *'ALL'* ]]; then
        deploy_official_hy2 SILENT || die 'HY2 deployment failed during Xray ALL.'
    fi
    write_env xray "$MODE_IN"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_xray)"
    if [[ "$MODE_IN" == *ALL* ]]; then prune_owned_core_families_except xray hysteria; else prune_owned_core_families_except xray; fi
    # F-NEW-01 (final-round): the cross-core prune above self-skips
    # the core being deployed, so a same-core overwrite never cleaned
    # this core's own standalone links and menu 12 reprinted them as
    # dead nodes. Prune this core's own links now that the new config
    # is on disk and the service is up; the survivor check inside
    # only deletes a link whose inbound is confirmed gone from the
    # live config, so live links are never removed. Best-effort: a
    # prune failure must not fail the deploy.
    _prune_standalone_links xray || true
    commit_deployment_transaction
    # OBS-S1-08: an overwrite redeploy writes fresh credentials into
    # live config but never touched the user registries; re-adopt every
    # existing registry of this core from live before any link is
    # issued, so a stale server_secret cannot produce a dead ss://
    # link. Best-effort: the deploy already committed, so a failure
    # warns but must not fail it (same posture as the post-deploy
    # snapshot below).
    users_reg_reconcile_after_deploy xray || msg "OBS-S1-08: user registry reconcile after deploy failed; issued links may carry pre-redeploy credentials until the next user-management visit." >&2
    # O1 (followup6 B-leg): drop registries of inbounds this overwrite
    # removed (Vision coverage over xray4 leaves stale ss/xhttp files
    # that the export then skips). Best-effort like reconcile above.
    users_reg_prune_stale_after_deploy xray || msg "O1: stale user registry prune after deploy failed; registries of removed inbounds may linger until the next user-management visit." >&2
    # R27-H-NF-06 (GPT-arbitrated B): snapshot the just-deployed config
    # so the newest trusted backup is no longer the pre-deployment
    # empty one; a later self-heal then restores nodes instead of an
    # empty stack. Best-effort: the deploy already committed, so a
    # snapshot failure warns but must not fail it. Committed-state
    # snapshot, not a proven-healthy one: restore-time screening (A)
    # still applies, and the gap (death between commit and snapshot)
    # is exactly what A covers.
    auto_backup_silent "post-deployment snapshot: xray ${MODE_IN}" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # N1: deploy-time REALITY compatibility notice. Flags come from the
    # freshly rebuilt, committed config -- not MODE alone (GPT Q2 hybrid).
    local _n1_flags='' _n1_reality='0' _n1_xhttp='0'
    _n1_flags=$(xray_config_reality_flags "$XRAY_SLOT_CFG" || true)
    read -r _n1_reality _n1_xhttp <<< "${_n1_flags:-0 0}"
    if [[ "$_n1_reality" == '1' ]]; then show_reality_mlkem_notice "$_n1_xhttp" 0; fi
    # S2-NEW-03 follow-up (fresh-deploy segment): the refresh below
    # exports registries only, and on a fresh install no registry
    # exists yet -- main lives only in the live config, so the export
    # is always 0 links. Adopt main into users.d FIRST (the same
    # protocol_inventory + users_reg_ensure loop the guard tick
    # runs), so the refresh runs AFTER main registration.
    # Best-effort: the deploy already committed, so a failure warns
    # but must not fail it.
    local _s2n03_c='' _s2n03_t='' _s2n03_p='' _s2n03_pt=''
    while IFS=$'\t' read -r _s2n03_c _s2n03_t _s2n03_p _s2n03_pt; do
        # Only the stacks THIS deploy built: xray always, hy2 only
        # when this deploy deployed it (ALL). Any other core's config
        # left on disk belongs to a pruned stack -- adopting it here
        # would resurrect its registry and export dead links.
        case "$_s2n03_c" in
            xray) ;;
            hy2) [[ "$MODE_IN" == *'ALL'* ]] || continue ;;
            *) continue ;;
        esac
        [[ -n "$_s2n03_t" && "$_s2n03_p" != 'shadowtls' ]] || continue
        users_reg_ensure "$_s2n03_c" "$_s2n03_t" >/dev/null 2>&1 || true
    done < <(protocol_inventory 2>/dev/null || true)
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
    view_config deploy
}


deploy_singbox() {
    local MODE_IN=$1 KEYPAIR SB_PATH cert_cn='localhost' SB_PRE_START='' SB_POST_STOP='' SB_RC_PRE='' SB_RC_POST='' SB_CAPS='CAP_NET_BIND_SERVICE'
    # G3: Probe -w support for service templates (global compat, not just self-use).
    # Service files run at boot with /bin/sh, no bash functions available,
    # so we bake the correct flag at generation time.
    local IPT_W_FLAG='' IPT6_W_FLAG=''
    $IPT -w --version >/dev/null 2>&1 && IPT_W_FLAG='-w'
    $IPT6 -w --version >/dev/null 2>&1 && IPT6_W_FLAG='-w'
    clear; msg "${BOLD}${GREEN}$(tprintf deploy_singbox_title "$MODE_IN")${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check
    residue_takeover_plan sing-box || return 1
    assert_no_foreign_core_conflicts sing-box
    confirm_deployment_replacement singbox "$MODE_IN"
    standalone_preserve_snapshot sing-box /etc/sing-box/config.json || return 1
    begin_deployment_transaction "sing-box ${MODE_IN} deployment" sing-box || return 1
    residue_takeover_clear || { deployment_transaction_rollback; return 1; }
    clean_nat_rules || die "$(tr_msg cl_nat)"
    clean_input_rules || die "$(tr_msg cl_input)"
    save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
    pre_install_setup singbox "$MODE_IN" || { deployment_transaction_rollback; return 1; }
    abox_fetch_guard_start "sing-box ${MODE_IN}"
    release_ports
    get_architecture

    local sb_tmp sb_tar sb_ext
    sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox) || die "$(tr_msg dp_sb_tmpdir)"
    ABOX_DEPLOY_TX_TMP="$sb_tmp"
    sb_tar="$sb_tmp/singbox_core.tar.gz"
    sb_ext="$sb_tmp/extract"
    mkdir -p "$sb_ext" || die "$(tr_msg dp_sb_extdir_tmp)"
    abox_fetch_heartbeat
    clear_core_release_resolution SagerNet/sing-box
    fetch_github_release SagerNet/sing-box singbox_core.tar.gz "$sb_tar"
    abox_fetch_heartbeat
    SB_PATH="$sb_ext/sing-box"
    extract_tar_regular_basename_safely "$sb_tar" sing-box "$SB_PATH" || die "$(tr_msg dp_sb_extract)"
    [[ -f "$SB_PATH" && ! -L "$SB_PATH" ]] || die "$(tr_msg dp_sb_bin)"
    chmod 755 "$SB_PATH" || die 'sing-box staged binary chmod failed.'
    "$SB_PATH" version >/dev/null 2>&1 || die 'sing-box staged binary execution check failed.'
    install_binary_atomically "$SB_PATH" /usr/local/bin/sing-box || die 'sing-box binary atomic install failed.'
    rm -rf -- "$sb_tmp"
    ABOX_DEPLOY_TX_TMP=''
    /usr/local/bin/sing-box version >/dev/null 2>&1 || die "$(tr_msg dp_sb_exec)"
    abox_fetch_guard_stop

    prepare_abox_runtime_config_dir sing-box /etc/sing-box || die 'sing-box config directory preparation failed.'
    KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair) || die "$(tr_msg dp_sb_keypair)"
    IFS=$'\t' read -r PK PBK < <(parse_x25519_keypair_output "$KEYPAIR") || die "$(tr_msg dp_sb_keyparse)"
    [[ -n "${PK:-}" && -n "${PBK:-}" ]] || die "$(tr_msg dp_sb_keyparse_empty)"
    UUID=$(generate_robust_uuid) || die 'UUID generation failed.'
    SHORT_ID=$(openssl rand -hex 4 | tr -d '\n\r')
    SS_PASS=$(openssl rand -base64 16 | tr -d '\n\r')
    [[ -n "$SS_PASS" ]] || die "$(tr_msg dp_ss_keygen)"

    if [[ "$MODE_IN" == *'HY2'* || "$MODE_IN" == *'ALL'* ]]; then
        HY2_PASS=$(rand_alnum 20) || die 'Hysteria 2 password generation failed.'
        HY2_OBFS=$(rand_alnum 16) || die 'Hysteria 2 obfuscation password generation failed.'
        [[ -n "${HY2_DOMAIN:-}" ]] && cert_cn="$HY2_DOMAIN"
        generate_self_signed_cert_atomically /etc/sing-box/hy2.key /etc/sing-box/hy2.crt "$cert_cn" "${LINK_IP:-}" || die "$(tr_msg dp_sb_hy2_cert)"
        HY2_CERT_SHA256_FP=$(pin_sha256_colon /etc/sing-box/hy2.crt | tr -d ':')
        HY2_CERT_PUBKEY_SHA256_B64=$(openssl x509 -in /etc/sing-box/hy2.crt -noout -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64 | tr -d '\n')
    fi

    build_singbox_config "$MODE_IN"
    chmod 600 /etc/sing-box/config.json || die 'sing-box config permission hardening failed.'
    jq empty /etc/sing-box/config.json >/dev/null 2>&1 || die "$(tr_msg dp_sb_json)"
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || die "$(tr_msg dp_sb_check)"
    standalone_preserve_restore sing-box /etc/sing-box/config.json || { deployment_transaction_rollback; return 1; }

    if [[ "$MODE_IN" == *'HY2'* || "$MODE_IN" == *'ALL'* ]] && [[ "${HY2_HOP:-}" == 'true' ]]; then
        # A-02: CAP_NET_ADMIN removed (see HY2_CAPS).
        SB_CAPS='CAP_NET_BIND_SERVICE'
        SB_PRE_START="ExecStartPre=-+/bin/sh -c '$IPT ${IPT_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true'
ExecStartPre=+/bin/sh -c '$IPT ${IPT_W_FLAG} -t nat -A PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT'"
        SB_POST_STOP="ExecStopPost=-+/bin/sh -c '$IPT ${IPT_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true'"
        SB_RC_PRE="start_pre() {
  $IPT ${IPT_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true
  $IPT ${IPT_W_FLAG} -t nat -A PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT || return 1"
        SB_RC_POST="stop_post() {
  $IPT ${IPT_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true"
        if has_ipv6 && ipv6_nat_redirect_usable; then
            SB_PRE_START+="
ExecStartPre=-+/bin/sh -c '$IPT6 ${IPT6_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true'
ExecStartPre=+/bin/sh -c '$IPT6 ${IPT6_W_FLAG} -t nat -A PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT'"
            SB_POST_STOP+="
ExecStopPost=-+/bin/sh -c '$IPT6 ${IPT6_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true'"
            SB_RC_PRE+="
  $IPT6 ${IPT6_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true
  $IPT6 ${IPT6_W_FLAG} -t nat -A PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT || return 1"
            SB_RC_POST+="
  $IPT6 ${IPT6_W_FLAG} -t nat -D PREROUTING -i $INGRESS_IF -p udp --dport ${HY2_RANGE_START}:${HY2_RANGE_END} -m comment --comment \"A-Box-HY2-HOP\" -j REDIRECT --to-ports $HY2_BASE_PORT 2>/dev/null || true"
        fi
        SB_RC_PRE+="
  return 0
}"
        SB_RC_POST+="
  return 0
}"
    fi

    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin /etc/systemd/system/sing-box.service 644 <<EOF_SVC || die "$(tr_msg dp_sb_unit_lc)"
# Managed by A-Box
[Unit]
Description=A-Box Sing-Box Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=abox-singbox
Group=abox-singbox
UMask=0077
CapabilityBoundingSet=$SB_CAPS
AmbientCapabilities=$SB_CAPS
$SB_PRE_START
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
$SB_POST_STOP
NoNewPrivileges=true
PrivateTmp=true
Restart=always
RestartSec=10
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF_SVC
    else
        path_parent_chain_safe /etc/conf.d/sing-box || die "$(tr_msg dp_orc_parent)"
        [[ ! -L /etc/conf.d && (! -e /etc/conf.d || -d /etc/conf.d) ]] || die "$(tr_msg dp_orc_dir_unsafe)"
        mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
        write_file_atomically_from_stdin /etc/conf.d/sing-box 644 <<'EOF_SB_CONFD' || die "$(tr_msg dp_sb_confd_lc)"
rc_ulimit="-n 1048576"
EOF_SB_CONFD
        write_file_atomically_from_stdin /etc/init.d/sing-box 755 <<EOF_SVC || die "$(tr_msg dp_sb_initd_lc)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Sing-Box Service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
command_user="abox-singbox:abox-singbox"
capabilities="^cap_net_bind_service"
umask=077
pidfile="/run/sing-box.pid"
depend() { need net; }
$SB_RC_PRE
$SB_RC_POST
EOF_SVC
        chmod +x /etc/init.d/sing-box || die "$(tr_msg dp_sb_chmod)"
    fi
    prepare_abox_runtime_permissions sing-box || die "$(tr_msg dp_sb_runtime)"
    service_manager start sing-box
    setup_active_defense
    setup_health_monitor
    write_env singbox "$MODE_IN"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"
    prune_owned_core_families_except sing-box
    # F-NEW-01 (final-round): the cross-core prune above self-skips
    # the core being deployed, so a same-core overwrite never cleaned
    # this core's own standalone links and menu 12 reprinted them as
    # dead nodes. Prune this core's own links now that the new config
    # is on disk and the service is up; the survivor check inside
    # only deletes a link whose inbound is confirmed gone from the
    # live config, so live links are never removed. Best-effort: a
    # prune failure must not fail the deploy.
    _prune_standalone_links sing-box || true
    # S1-NEW-03 (final-round followup 3): an overwrite redeploy rebuilds
    # the sing-box config from scratch (build_singbox_config never emits
    # TUIC inbounds), so removed TUIC nodes leave their per-tag cert/key
    # pairs behind — the delete path runs this cleanup via
    # _protocol_removed_side_effects, but this deploy path never did.
    # Run it here, once the new config (incl. any preserved standalone
    # inbounds) is on disk: the helper re-checks the live config and
    # deletes the pairs only when no tuic inbound remains, so a
    # preserved TUIC keeps its certs. Best-effort: a cleanup failure
    # must not fail the deploy.
    _singbox_cleanup_tuic_certs_when_none_remain || true
    setup_geo_cron
    commit_deployment_transaction
    # R27-H-NF-06 (M-6): snapshot the just-deployed config so the
    # newest trusted backup is no longer the pre-deployment empty
    # one (same posture as deploy_xray above). Best-effort: the
    # deploy already committed, so a snapshot failure warns but
    # must not fail it.
    auto_backup_silent "post-deployment snapshot: sing-box ${MODE_IN}" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # OBS-S1-08: an overwrite redeploy writes fresh credentials into
    # live config but never touched the user registries; re-adopt every
    # existing registry of this core from live before any link is
    # issued, so a stale server_secret cannot produce a dead ss://
    # link. Best-effort: the deploy already committed, so a failure
    # warns but must not fail it.
    users_reg_reconcile_after_deploy sing-box || msg "OBS-S1-08: user registry reconcile after deploy failed; issued links may carry pre-redeploy credentials until the next user-management visit." >&2
    # O1 (followup6 B-leg): same stale-registry prune as the xray
    # deploy above (single-protocol coverage drops the other tags'
    # inbounds; their registries must not linger into the export).
    users_reg_prune_stale_after_deploy sing-box || msg "O1: stale user registry prune after deploy failed; registries of removed inbounds may linger until the next user-management visit." >&2
    # S2-NEW-03 follow-up (fresh-deploy segment): the refresh below
    # exports registries only, and on a fresh install no registry
    # exists yet -- main lives only in the live config, so the export
    # is always 0 links. Adopt main into users.d FIRST (the same
    # protocol_inventory + users_reg_ensure loop the guard tick
    # runs), so the refresh runs AFTER main registration.
    # Best-effort: the deploy already committed, so a failure warns
    # but must not fail it.
    local _s2n03_c='' _s2n03_t='' _s2n03_p='' _s2n03_pt=''
    while IFS=$'\t' read -r _s2n03_c _s2n03_t _s2n03_p _s2n03_pt; do
        # Only the stack THIS deploy built (sing-box). Any other
        # core's config left on disk belongs to a pruned stack --
        # adopting it here would resurrect its registry and export
        # dead links.
        [[ "$_s2n03_c" == 'sing-box' ]] || continue
        [[ -n "$_s2n03_t" && "$_s2n03_p" != 'shadowtls' ]] || continue
        users_reg_ensure "$_s2n03_c" "$_s2n03_t" >/dev/null 2>&1 || true
    done < <(protocol_inventory 2>/dev/null || true)
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
    view_config deploy
}



ensure_vnstat_runtime() {
    if ! command -v vnstat >/dev/null 2>&1; then
        msg "${YELLOW}[*] $(tr_msg ensure_vnstat_runtime_installing)${NC}"
        install_optional_package vnstat || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_install_fail)${NC}" >&2; return 1; }
    fi
    command -v vnstat >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_still_unavailable)${NC}" >&2; return 1; }
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        if systemctl list-unit-files --type=service --no-legend vnstat.service 2>/dev/null | awk -v wanted="vnstat.service" '$1 == wanted { found=1 } END { exit !found }' ; then
            systemctl enable --now vnstat >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_service_start_fail)${NC}" >&2; return 1; }
            systemctl is-active --quiet vnstat || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_service_not_active)${NC}" >&2; return 1; }
        elif systemctl list-unit-files --type=service --no-legend vnstatd.service 2>/dev/null | awk -v wanted="vnstatd.service" '$1 == wanted { found=1 } END { exit !found }' ; then
            systemctl enable --now vnstatd >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_service_start_fail)${NC}" >&2; return 1; }
            systemctl is-active --quiet vnstatd || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_service_not_active)${NC}" >&2; return 1; }
        else
            { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_no_systemd_service)${NC}" >&2; return 1; }
        fi
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        [[ -x /etc/init.d/vnstatd ]] || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_no_openrc_service)${NC}" >&2; return 1; }
        rc-update add vnstatd default >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_openrc_add_fail)${NC}" >&2; return 1; }
        rc-service vnstatd restart >/dev/null 2>&1 9>&- 10>&- || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_openrc_start_fail)${NC}" >&2; return 1; }
        rc-service vnstatd status >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_openrc_not_running)${NC}" >&2; return 1; }
    else
        { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_runtime_unknown)${NC}" >&2; return 1; }
    fi
    # A long-running vnstatd only registers interfaces present at
    # its own start; without this the dashboard stays empty until
    # a reboot restarts the daemon. Verify and repair once here.
    local _viface='' _vunit=''
    _viface="${INGRESS_IF:-}"
    [[ -n "$_viface" ]] || _viface=$(get_active_interface 2>/dev/null || true)
    if [[ -n "$_viface" ]]; then
        if [[ "$(vnstat -i "$_viface" --json m 2>/dev/null | jq -r --arg iface "$_viface" '.interfaces // [] | any(.[]; (.name // .id) == $iface)' 2>/dev/null)" != "true" ]]; then
            if vnstat --version 2>/dev/null | grep -q 'vnStat 1\.'; then
                vnstat -u -i "$_viface" >/dev/null 2>&1 || true
            fi
            if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                if systemctl list-unit-files --type=service --no-legend vnstat.service 2>/dev/null | awk -v wanted="vnstat.service" '$1 == wanted { found=1 } END { exit !found }' ; then _vunit=vnstat;
                elif systemctl list-unit-files --type=service --no-legend vnstatd.service 2>/dev/null | awk -v wanted="vnstatd.service" '$1 == wanted { found=1 } END { exit !found }' ; then _vunit=vnstatd; fi
                [[ -n "$_vunit" ]] && systemctl restart "$_vunit" >/dev/null 2>&1 || true
                [[ -n "$_vunit" ]] && systemctl is-active --quiet "$_vunit" || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_iface_fix_not_active)${NC}" >&2; return 1; }
            elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
                rc-service vnstatd restart >/dev/null 2>&1 9>&- 10>&- || true
                rc-service vnstatd status >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_iface_fix_not_running)${NC}" >&2; return 1; }
            fi
            [[ "$(vnstat -i "$_viface" --json m 2>/dev/null | jq -r --arg iface "$_viface" '.interfaces // [] | any(.[]; (.name // .id) == $iface)' 2>/dev/null)" == "true" ]] || { msg "${RED}[!] $(tr_msg ensure_vnstat_runtime_iface_fix_not_registered)${NC}" >&2; return 1; }
        fi
    fi
}

setup_traffic_monitor() {
    command -v flock >/dev/null 2>&1 || { msg "${RED}[!] $(tr_msg setup_traffic_monitor_flock_missing)${NC}" >&2; return 1; }
    # R9-03: a retired xray-latest coexist instance is outside the managed
    # core set and would never be stopped by a quota block. Refuse to
    # install the monitor until it is retired (fail closed); do not
    # auto-migrate or delete legacy assets here.
    xray_latest_legacy_retire || return 1
    ensure_vnstat_runtime
    local ensure_rc=$?
    [[ -z "${ABOX_TRAFFIC_TX_DIR:-}" ]] || capture_traffic_quota_expected_state "$ABOX_TRAFFIC_TX_DIR" || { msg "${RED}[!] $(tr_msg setup_traffic_monitor_quota_snapshot_failed)${NC}" >&2; return 1; }
    (( ensure_rc == 0 )) || return 1
    install -d -m 711 "$ABOX_DIR" || { msg "${RED}[!] $(tr_msg setup_traffic_monitor_mkdir_failed)${NC}" >&2; return 1; }
    local _tm_tmp='' _ab_esc=''
    _tm_tmp=$(mktemp) || { msg "${RED}[!] $(tr_msg setup_traffic_monitor_tmpfile_failed)${NC}" >&2; return 1; }
    cat > "$_tm_tmp" <<'EOF_TRAFFIC' || { rm -f -- "$_tm_tmp"; msg "${RED}[!] $(tr_msg setup_traffic_monitor_tmp_write_failed)${NC}" >&2; return 1; }
#!/usr/bin/env bash
# Managed by A-Box
# A-06: umask 077 ensures lock/temp files are 0600 (not world-readable 0644).
umask 077
set -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
ENV=/etc/ddr/.env
DESIRED=/etc/ddr/.desired_state
BLOCK_STATE=/etc/ddr/.traffic-block-state
PAIR_STATE=/etc/ddr/.traffic-pair-state
# R6C10-01: rollover-in-progress marker (see recovery below).
ROLLOVER_MARKER=/etc/ddr/.traffic-rollover-in-progress
# R7C10-01: pre-block service-state snapshot prefix (see capture/restore below).
PRE_BLOCK_STATES_PREFIX=/etc/ddr/.traffic-pre-block-states
INIT_SYS_EXPECTED='unknown'
# R14-F10-01: canonical is_systemd for this generated script (same
# one-liner as geo_update.sh and the main script). The template calls
# is_systemd 8 times; without this definition a systemd host took the
# OpenRC branch, owned() failed, and quota protection failed open.
is_systemd() { [[ "${INIT_SYS_EXPECTED:-${INIT_SYS:-}}" == systemd ]]; }
exec 9>>/run/A-Box-traffic-monitor.lock || exit 1
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
acquire_abox_runtime_guard
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
import shlex
import sys
allowed = {"CORE", "MODE", "VLESS_PORT", "XHTTP_PORT", "HY2_MONITOR_PORT", "HY2_HOP", "HY2_HOP_IMPL", "HY2_RANGE_START", "HY2_RANGE_END", "SS_PORT", "TRAFFIC_LIMIT_GB", "TRAFFIC_LIMIT_MODE", "INGRESS_IF", "SOCKS_PORT"}
seen = set()
with open(sys.argv[1], encoding="utf-8", errors="strict") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"): continue
        if "=" not in line: raise SystemExit(1)
        key, raw_value = line.split("=", 1)
        if key not in allowed: continue
        if key in seen or raw_value.startswith("$'"): raise SystemExit(1)
        if not raw_value.strip():
            value = ""
        else:
            parts = shlex.split(raw_value, posix=True)
            if len(parts) != 1: raise SystemExit(1)
            value = parts[0]
        if any(c in value for c in "\x00\r\n"): raise SystemExit(1)
        seen.add(key)
        sys.stdout.buffer.write(key.encode("ascii") + b"\0" + value.encode("utf-8") + b"\0")
PY_HELPER_ENV
        rm -f "$parsed"
        return 1
    fi
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do printf -v "$key" '%s' "$value"; done < "$parsed"
    rm -f "$parsed"
}
write_private_line() {
    local dest="$1" value="$2" tmp parent uid gid mode
    case "$dest" in
        "$DESIRED"|"$BLOCK_STATE"|"$PAIR_STATE") ;;
        *) return 1 ;;
    esac
    parent=$(dirname -- "$dest") || return 1
    [[ "$parent" == /etc/ddr && -d "$parent" && ! -L "$parent" ]] || return 1
    uid=$(stat -c %u "$parent" 2>/dev/null) || return 1
    gid=$(stat -c %g "$parent" 2>/dev/null) || return 1
    mode=$(stat -c %a "$parent" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ ! -L "$dest" && ! -d "$dest" ]] || return 1
    tmp=$(umask 077; mktemp "${dest}.A-Box-new.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" && chown root:root "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}
read_traffic_pair_fields() {
    local line desired period uid gid mode
    [[ -r "$PAIR_STATE" && -f "$PAIR_STATE" && ! -L "$PAIR_STATE" ]] || return 1
    uid=$(stat -c %u "$PAIR_STATE" 2>/dev/null) || return 1
    gid=$(stat -c %g "$PAIR_STATE" 2>/dev/null) || return 1
    mode=$(stat -c %a "$PAIR_STATE" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    IFS= read -r line < "$PAIR_STATE" || return 1
    [[ "$line" == *'|'* ]] || return 1
    desired=${line%%|*}
    period=${line#*|}
    [[ "$desired" =~ ^(RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE)$ ]] || return 1
    if [[ -n "$period" ]]; then
        [[ "$period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 1
    fi
    printf '%s\n%s\n' "$desired" "$period"
}
# Atomic desired+period publish: write PAIR first, then derive legacy files.
# Self-contained: does NOT delegate to commit_traffic_pair_state (not in generated script).
# BUG-28: hoisted from commit_traffic_pair().
# Same triplet convention as __abox_traffic_state_rollback.
__abox_tm_state_rollback() {
    local pair_existed="$1" pair_backup="$2" pair_target="$3"
    local desired_existed="$4" desired_backup="$5" desired_target="$6"
    local block_existed="$7" block_backup="$8" block_target="$9"
    local restore_failed=0
    if (( pair_existed == 1 )); then
        cp -p -- "$pair_backup" "$pair_target" 2>/dev/null || restore_failed=1
    else
        rm -f -- "$pair_target" 2>/dev/null || restore_failed=1
    fi
    if (( desired_existed == 1 )); then
        cp -p -- "$desired_backup" "$desired_target" 2>/dev/null || restore_failed=1
    else
        rm -f -- "$desired_target" 2>/dev/null || restore_failed=1
    fi
    if (( block_existed == 1 )); then
        cp -p -- "$block_backup" "$block_target" 2>/dev/null || restore_failed=1
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
commit_traffic_pair() {
    local desired="$1" period="${2:-}"
    local pair_backup="" desired_backup="" block_backup=""
    local pair_existed=0 desired_existed=0 block_existed=0 restore_failed=0
    [[ "$desired" =~ ^(RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE)$ ]] || return 1
    if [[ -n "$period" ]]; then
        [[ "$period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 1
    fi
    if [[ -f "$PAIR_STATE" ]]; then
        pair_existed=1; pair_backup=$(umask 077; mktemp) || return 1
        cp -p -- "$PAIR_STATE" "$pair_backup" || { rm -f -- "$pair_backup"; return 1; }
    fi
    if [[ -f "$DESIRED" ]]; then
        desired_existed=1; desired_backup=$(umask 077; mktemp) || { rm -f -- "$pair_backup"; return 1; }
        cp -p -- "$DESIRED" "$desired_backup" || { rm -f -- "$pair_backup" "$desired_backup"; return 1; }
    fi
    if [[ -f "$BLOCK_STATE" ]]; then
        block_existed=1; block_backup=$(umask 077; mktemp) || { rm -f -- "$pair_backup" "$desired_backup"; return 1; }
        cp -p -- "$BLOCK_STATE" "$block_backup" || { rm -f -- "$pair_backup" "$desired_backup" "$block_backup"; return 1; }
    fi
    write_private_line "$PAIR_STATE" "${desired}|${period}" || { __abox_tm_state_rollback "$pair_existed" "$pair_backup" "$PAIR_STATE" "$desired_existed" "$desired_backup" "$DESIRED" "$block_existed" "$block_backup" "$BLOCK_STATE"; return 1; }
    write_private_line "$DESIRED" "$desired" || { __abox_tm_state_rollback "$pair_existed" "$pair_backup" "$PAIR_STATE" "$desired_existed" "$desired_backup" "$DESIRED" "$block_existed" "$block_backup" "$BLOCK_STATE"; return 1; }
    if [[ -n "$period" ]]; then
        write_private_line "$BLOCK_STATE" "$period" || { __abox_tm_state_rollback "$pair_existed" "$pair_backup" "$PAIR_STATE" "$desired_existed" "$desired_backup" "$DESIRED" "$block_existed" "$block_backup" "$BLOCK_STATE"; return 1; }
    else
        if [[ -e "$BLOCK_STATE" || -L "$BLOCK_STATE" ]]; then
            rm -f -- "$BLOCK_STATE" || { __abox_tm_state_rollback "$pair_existed" "$pair_backup" "$PAIR_STATE" "$desired_existed" "$desired_backup" "$DESIRED" "$block_existed" "$block_backup" "$BLOCK_STATE"; return 1; }
        fi
    fi
    rm -f -- "$pair_backup" "$desired_backup" "$block_backup"
}
read_desired() {
    local state=RUNNING mode pair desired
    if pair=$(read_traffic_pair_fields); then
        IFS= read -r desired <<< "$pair"
        printf '%s\n' "$desired"
        return 0
    fi
    # S22 (template copy): a pair file that exists but is unreadable
    # or corrupt is an error, not a cue to fall back to legacy or the
    # RUNNING default (a quota block must never be silently flipped).
    if [[ -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
        return 1
    fi
    if [[ -e "$DESIRED" || -L "$DESIRED" ]]; then
        [[ -r "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" ]] || return 1
        [[ "$(stat -c %u:%g "$DESIRED" 2>/dev/null)" == 0:0 ]] || return 1
        mode=$(stat -c %a "$DESIRED" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || return 1
        IFS= read -r state < "$DESIRED" || return 1
    fi
    [[ "$state" =~ ^(RUNNING|TRAFFIC_BLOCKED|MANUAL_STOPPED|MAINTENANCE)$ ]] || return 1
    printf '%s\n' "$state"
}
read_block_period() {
    local period mode pair
    if pair=$(read_traffic_pair_fields); then
        # FIX: Same empty-period bug as get_traffic_block_period — command
        # substitution strips the trailing newline, so a missing newline
        # means the period field is empty (not "RUNNING").
        if [[ "$pair" == *$'\n'* ]]; then
            period=${pair#*$'\n'}
        else
            period=""
        fi
        [[ -n "$period" ]] || return 1
        printf '%s\n' "$period"
        return 0
    fi
    [[ -r "$BLOCK_STATE" && -f "$BLOCK_STATE" && ! -L "$BLOCK_STATE" ]] || return 1
    [[ "$(stat -c %u:%g "$BLOCK_STATE" 2>/dev/null)" == 0:0 ]] || return 1
    mode=$(stat -c %a "$BLOCK_STATE" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || return 1
    IFS= read -r period < "$BLOCK_STATE" || return 1
    [[ "$period" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 1
    printf '%s\n' "$period"
}
month_bytes() {
    local i="$1" mode="${2:-total}" json rx tx line month_count ol_month
    if command -v jq >/dev/null 2>&1 && json=$(vnstat -i "$i" --json m 1 2>/dev/null); then
        # A newly initialized vnStat database may have an interface entry but no
        # monthly sample yet. Treat an empty monthly series as 0 for quota purposes.
        # A failed interface/database query still falls through and remains fail-closed.
        month_count=$(jq -r '(.interfaces[0].traffic.month // .interfaces[0].traffic.months // []) | length' <<< "$json" 2>/dev/null || printf 'x')
        if [[ "$month_count" == '0' ]]; then
            # R35b-M1: an empty month series is 0 only when the document
            # actually names the interface and its traffic object (a new
            # database). A structurally missing document ({}, no
            # interfaces) also yields length 0 through the // [] fallback
            # and must NOT read as 0 bytes: fall through to the validated
            # oneline read below instead.
            if jq -e '.interfaces | type == "array" and length >= 1 and (.[0].traffic // null | type == "object")' <<< "$json" >/dev/null 2>&1; then
                case "$mode" in rx|tx|total) printf '0\n'; return 0 ;; *) return 1 ;; esac
            fi
        fi
        # R6C10-02: 1.x months entries are KiB; normalize to bytes.
        rx=$(jq -r --argjson y "$(date +%Y)" --argjson m "$(date +%-m)" '([.interfaces[0].traffic.month[]? | . + {__unit: "B"}] + [.interfaces[0].traffic.months[]? | . + {__unit: "KiB"}] | map(select(((.year // .date.year // 0) == $y) and ((.month // .date.month // 0) == $m))) | last | if . == null then empty elif .__unit == "KiB" then (.rx * 1024) else .rx end)' <<< "$json" 2>/dev/null)
        tx=$(jq -r --argjson y "$(date +%Y)" --argjson m "$(date +%-m)" '([.interfaces[0].traffic.month[]? | . + {__unit: "B"}] + [.interfaces[0].traffic.months[]? | . + {__unit: "KiB"}] | map(select(((.year // .date.year // 0) == $y) and ((.month // .date.month // 0) == $m))) | last | if . == null then empty elif .__unit == "KiB" then (.tx * 1024) else .tx end)' <<< "$json" 2>/dev/null)
        if [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
            case "$mode" in
                rx) echo "$rx" ;;
                tx) echo "$tx" ;;
                # 05c1-M2: the exact-integer sum must be checked: a failed
                # interpreter prints nothing yet the old code returned 0
                # unconditionally, reporting a successful read.
                total) python3 -I - "$rx" "$tx" <<'PY_VNSTAT_TOTAL_MONITOR' || return 1
import sys
print(int(sys.argv[1]) + int(sys.argv[2]))
PY_VNSTAT_TOTAL_MONITOR
                    ;;
                *) return 1 ;;
            esac
            return 0
        fi
    fi
    line=$(vnstat -i "$i" --oneline b 2>/dev/null) || return 1
    # R2C10-03: field 8 is the oneline month timestamp (yyyy-mm). It must
    # match the current billing cycle; a stalled daemon reports last
    # month's total as current, and the sticky-block logic would turn one
    # stale read into a new-month block. Refuse on mismatch or malformed.
    ol_month=$(awk -F';' '{print $8}' <<< "$line")
    [[ "$ol_month" == "$(date +%Y-%m)" ]] || return 1
    case "$mode" in rx) awk -F';' '{print $9}' <<< "$line";; tx) awk -F';' '{print $10}' <<< "$line";; total) awk -F';' '{print $11}' <<< "$line";; *) return 1;; esac
}
managed_unit_path() {
    case "$1" in
        xray|sing-box|hysteria)
            if is_systemd; then printf '/etc/systemd/system/%s.service\n' "$1"; else printf '/etc/init.d/%s\n' "$1"; fi
            ;;
        *) return 1 ;;
    esac
}
owned() {
    local srv="$1" u
    u=$(managed_unit_path "$srv") || return 1
    [[ -f "$u" && ! -L "$u" ]] && grep -Fxq '# Managed by A-Box' "$u"
}
# H-05 (Carbon): interface inference for the no-owned-service case —
# same single-interface selection as get_active_interface in the main
# script (first default-route device, then first non-loopback up link).
get_active_interface() {
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 !~ /^(lo|vir|wl)/ {sub(/@.*/,"",$2); print $2; exit}')
    printf '%s\n' "$iface"
}
# H-05 (Carbon): same name rule as valid_interface_name in the main
# script (Linux IFNAMSIZ: at most 15 characters).
valid_monitor_interface_name() {
    local iface="${1:-}"
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ && ${#iface} -le 15 ]]
}
any_owned_service() {
    local srv
    for srv in xray sing-box hysteria; do
        owned "$srv" 2>/dev/null && return 0
    done
    return 1
}
force_stop_owned_openrc() {
    local srv="$1" pidfile exe pid owner proc_exe
    case "$srv" in
        xray) pidfile=/run/xray.pid; exe=/usr/local/bin/xray ;;
        sing-box) pidfile=/run/sing-box.pid; exe=/usr/local/bin/sing-box ;;
        hysteria) pidfile=/run/hysteria.pid; exe=/usr/local/bin/hysteria ;;
        *) return 1 ;;
    esac
    [[ -f "$pidfile" && ! -L "$pidfile" ]] || return 1
    [[ "$(stat -c %h "$pidfile" 2>/dev/null)" == 1 ]] || return 1
    owner=$(stat -c %u "$pidfile" 2>/dev/null) || return 1
    [[ "$owner" == 0 ]] || return 1
    pid=$(cat -- "$pidfile" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$pid > 1 )) || return 1
    proc_exe=$(readlink "/proc/${pid}/exe" 2>/dev/null) || return 1
    [[ "$proc_exe" == "$exe" ]] || return 1
    command -v start-stop-daemon >/dev/null 2>&1 || return 1
    # OpenRC's own process helper verifies both the pidfile and executable
    # before signaling. Never fall back to an unqualified kill by PID.
    start-stop-daemon --stop --pidfile "$pidfile" --exec "$exe" --retry TERM/5/KILL/1 >/dev/null 2>&1 || return 1
}

# C-1 (Gemini): the generated traffic_monitor.sh runs standalone -- it
# never sources the main script, so the four helpers below are
# self-contained copies of the main-script definitions (same bodies, no
# other main-script dependency). stop_owned / core_family_unit_registered
# call them; without these copies every call failed with rc 127 and the
# quota stop path silently no-op'd.

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -r /proc/1/comm ]] || return 1
    [[ "$(cat /proc/1/comm 2>/dev/null || true)" == 'systemd' ]] || return 1
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

_manifest_rows_valid() {
    local file="$1" line t f p h rest TAB=$'\t'
    [[ -f "$file" && ! -L "$file" ]] || return 1
    # NUL bytes must fail closed. cmp is not guaranteed: diffutils may be
    # absent on minimal RPM images, so compare byte counts via coreutils
    # (tr + wc), which are always present. tr only removes NULs, so the
    # counts differ exactly when NULs were present.
    local _stripped_len _orig_len
    _stripped_len=$(tr -d '\000' < "$file" | wc -c)
    _orig_len=$(wc -c < "$file")
    (( _stripped_len == _orig_len )) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        # SYD-B7: TAB is IFS whitespace, so a plain read folds empty fields
        # away; require exactly 3 TABs (4 fields) before splitting.
        local _notabs="${line//$TAB/}"
        [[ "$(( ${#line} - ${#_notabs} ))" -eq 3 ]] || return 1
        IFS=$'\t' read -r t f p h rest <<< "$line"
        [[ -z "${rest:-}" ]] || return 1
        case "$t" in F|D) ;; *) return 1 ;; esac
        case "$f" in xray|sing-box|hysteria|xray-latest) ;; *) return 1 ;; esac
        [[ "$p" == /* ]] || return 1
        case "$t" in
            F) [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
            D) [[ "$h" == '-' ]] || return 1 ;;
        esac
    done < "$file"
    return 0
}

# R3-NEW-04: a family recorded in the ownership manifest was deployed by
# A-Box. Recording requires abox_owns_service, i.e. a marked unit at
# record time, and the manifest row below names this exact unit path, so
# a recorded row is proof of A-Box deployment even if the unit file has
# since lost its marker, gone missing, or become a symlink. The manifest
# gates mirror remove_recorded_core_family: regular non-symlink file,
# root-owned 0600, at most 4 MiB, and every row well-formed
# (_manifest_rows_valid). Anything else fails closed (return 1).
core_family_unit_registered() {
    local srv="$1" u mf line t f p h rest _notabs TAB=$'\t'
    u=$(managed_unit_path "$srv") || return 1
    mf="${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}"
    [[ -f "$mf" && ! -L "$mf" ]] || return 1
    [[ "$(stat -c %u:%g "$mf" 2>/dev/null || true)" == 0:0 ]] || return 1
    [[ "$(stat -c %a "$mf" 2>/dev/null || true)" =~ ^0?600$ ]] || return 1
    [[ "$(stat -c %s "$mf" 2>/dev/null || echo 99999999)" -le 4194304 ]] || return 1
    _manifest_rows_valid "$mf" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        _notabs="${line//$TAB/}"
        [[ "$(( ${#line} - ${#_notabs} ))" -eq 3 ]] || return 1
        IFS=$'\t' read -r t f p h rest <<< "$line"
        [[ -z "${rest:-}" ]] || return 1
        if [[ "$t" == F && "$f" == "$srv" && "$p" == "$u" ]]; then return 0; fi
    done < "$mf"
    return 1
}

# M41-NEW-03: live-process ownership evidence. When the unit-file marker
# AND the ownership manifest are both gone, a running core must not be
# treated as foreign by name alone — the running process itself is
# evidence: its exe must be the A-Box core binary AND its command line
# must reference the A-Box config path for that core. Anything else is
# unverified and is never touched.
_core_exe_and_config() {
    case "$1" in
        xray) printf '%s\n%s\n' /usr/local/bin/xray /usr/local/etc/xray/config.json ;;
        sing-box) printf '%s\n%s\n' /usr/local/bin/sing-box /etc/sing-box/config.json ;;
        hysteria) printf '%s\n%s\n' /usr/local/bin/hysteria /etc/hysteria/config.yaml ;;
        *) return 1 ;;
    esac
}
_cmdline_has_arg() {
    # R35b-M2: match one whole argv token by its NUL boundary. The old
    # `tr '\0' '\n'` + grep -Fxq erased the boundary, so a single argv
    # containing a newline (e.g. $'/tmp/foreign\n<cfg>\nsuffix') matched
    # as if <cfg> were a standalone argument, and a foreign process
    # could be mistaken for ours. Unreadable cmdline refuses (rc 1).
    local _pid="$1" _want="$2" _arg=''
    [[ "$_pid" =~ ^[0-9]+$ && "$_pid" -gt 1 && -n "$_want" ]] || return 1
    while IFS= read -r -d '' _arg; do
        [[ "$_arg" == "$_want" ]] && return 0
    done < "/proc/$_pid/cmdline" 2>/dev/null
    return 1
}

core_process_matches() {
    local srv="$1" pid="$2" exe='' cfg='' cmdline=''
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    { IFS= read -r exe; IFS= read -r cfg; } <<< "$(_core_exe_and_config "$srv")" || return 1
    pid_exe_matches "$pid" "$exe" || return 1
    # 05c1-M1: match the config as one whole argv token, not a
    # substring: tr '\0' ' ' erases the NUL boundaries, so
    # .../config.json.foreign.json contains the expected path and a
    # foreign process is misjudged as ours. All three cores pass the
    # config as a standalone argv (xray run -config <cfg>, sing-box
    # run -c <cfg>, hysteria server -c <cfg>).
    [[ -n "$cfg" ]] || return 1
    _cmdline_has_arg "$pid" "$cfg"
}
find_core_residual_pid() {
    local srv="$1" exe='' cfg='' pid='' cmdline=''
    { IFS= read -r exe; IFS= read -r cfg; } <<< "$(_core_exe_and_config "$srv")" || return 1
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || continue
        pid_exe_matches "$pid" "$exe" || continue
        # 05c1-M1: whole-argv-token match, as in core_process_matches
        # above: a foreign .../config.json.foreign.json must not match.
        [[ -n "$cfg" ]] || return 1
        _cmdline_has_arg "$pid" "$cfg" || continue
        printf '%s\n' "$pid"
        return 0
    done
    return 1
}
stop_core_residual_process() {
    # M41-NEW-03: kill a residual core process that systemd no longer
    # tracks (orphan: unit inactive / MainPID 0, process alive with the
    # A-Box exe + config in its cmdline). Identity is re-verified before
    # every signal (exe + cmdline + starttime), mirroring
    # kill_managed_residual_pids; a PID reused in between is never
    # signalled. Returns 0 iff no same-instance residual remains.
    # H2 (05c1): find_core_residual_pid returns only the first match,
    # so handling a single PID reported success while a second
    # same-instance residual kept running. Re-scan after each kill
    # until none remains (bounded: a respawning process fails instead
    # of looping forever).
    local srv="$1" pid='' start='' waited=0 _passes=0
    while (( _passes < 10 )); do
        _passes=$(( _passes + 1 ))
        pid=$(find_core_residual_pid "$srv" 2>/dev/null || true)
        [[ -n "$pid" ]] || return 0
        kill -0 "$pid" 2>/dev/null || continue
        start=$(proc_starttime "$pid" 2>/dev/null || true)
        [[ -n "$start" ]] || return 1
        core_process_matches "$srv" "$pid" || continue
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null && [[ "$(proc_starttime "$pid" 2>/dev/null || true)" == "$start" ]] && core_process_matches "$srv" "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        waited=0
        while (( waited < 50 )); do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            if [[ "$(proc_starttime "$pid" 2>/dev/null || true)" != "$start" ]]; then break; fi
            core_process_matches "$srv" "$pid" || break
            sleep 0.1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null && [[ "$(proc_starttime "$pid" 2>/dev/null || true)" == "$start" ]] && core_process_matches "$srv" "$pid"; then
            return 1
        fi
    done
    # R35b-M3: the 10th pass may have cleared the last residual; a final
    # read-only scan decides instead of unconditionally failing. (An
    # empty result also covers a lookup failure, exactly as the in-loop
    # `[[ -n "$pid" ]] || return 0` already does.)
    pid=$(find_core_residual_pid "$srv" 2>/dev/null || true)
    [[ -n "$pid" ]] && return 1
    return 0
}
stop_owned() {
    local srv="$1" u rc enabled_state rc_show _stop_state _stop_pid
    u=$(managed_unit_path "$srv") || return 1
    # M41-NEW-03 (hardening, not the observed mechanism): if INIT_SYS was
    # never set in this process (e.g. stop_owned called before any init),
    # re-derive it instead of silently taking the OpenRC branch on a
    # systemd host. An explicit openrc value is never overridden.
    if [[ -z "${INIT_SYS:-}" || "${INIT_SYS:-}" == unknown ]] && systemd_available; then
        INIT_SYS='systemd'
        u=$(managed_unit_path "$srv") || return 1
    fi
    if ! owned "$srv"; then
        # R3-NEW-04: the marker gate above refuses a unit whose file lost
        # its marker (or went missing, or became a symlink) after
        # deployment. A family recorded in the ownership manifest was
        # deployed by A-Box -- recording requires abox_owns_service, i.e.
        # a marked unit at record time, and the manifest row names this
        # exact unit path. Refusing to stop such a service leaves a
        # cleared stack running as an empty shell (the H-23 failure:
        # clear_all reported success while sing-box kept listening).
        # Fall through to the normal stop path for a registered family;
        # the post-stop verification below still has to confirm the
        # service is actually stopped before success is reported.
        if ! core_family_unit_registered "$srv"; then
            # M41-NEW-03: ownership is unproven (marker AND manifest
            # both gone). Never stop a foreign service on name alone —
            # but do not report failure for a service that is already
            # stopped, and do not leave a RUNNING service that is
            # verifiably the A-Box stack (live exe + config path) as a
            # ghost. Query the service manager first:
            #   inactive  -> already stopped: success (nothing to do);
            #   active + live-verified -> fall through to the stop path;
            #   active + unverified  -> refuse (foreign protection).
            if is_systemd; then
                local _live_state _live_pid
                _live_state=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
                case "$_live_state" in
                    inactive|failed|dead|not-found) stop_core_residual_process "$srv" || return 1; return 0 ;;
                    active|activating|deactivating|reloading)
                        _live_pid=$(systemctl show -p MainPID --value "$srv" 2>/dev/null || true)
                        if ! core_process_matches "$srv" "$_live_pid"; then
                            # MainPID may be 0 while the service is
                            # activating; fall back to a /proc scan for a
                            # matching live process.
                            _live_pid=$(find_core_residual_pid "$srv" 2>/dev/null || true)
                            core_process_matches "$srv" "$_live_pid" || return 1
                        fi
                        ;;
                    *) return 1 ;;
                esac
            else
                rc-service "$srv" status >/dev/null 2>&1; rc=$?
                case "$rc" in 3|16|32) stop_core_residual_process "$srv" || return 1; return 0 ;; *) return 1 ;; esac
            fi
        fi
    fi
    if is_systemd; then
        systemctl stop "$srv" >/dev/null 2>&1 || true
        # R15-F10-01: verify with ActiveState, not is-active. is-active
        # returns non-zero for activating/deactivating/query-failure too,
        # which is not "stopped"; only inactive|failed (+ MainPID 0) is.
        _stop_state=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
        case "$_stop_state" in
            active|activating|deactivating|reloading)
                # Restart=always can race a failed stop. Disable first, then kill the
                # unit cgroup and re-check actual activity before reporting success.
                # M41-NEW-03: a unit file deleted before this call (e.g.
                # clear_all's own _remove_hy2_official deletes the
                # hysteria unit, then this loop stops hysteria) cannot be
                # disabled; disabling is moot once the file is gone.
                if [[ -f "$u" && ! -L "$u" ]]; then
                    systemctl disable "$srv" >/dev/null 2>&1 || return 1
                fi
                systemctl kill --kill-who=all --signal=SIGKILL "$srv" >/dev/null 2>&1 || true
                systemctl stop "$srv" >/dev/null 2>&1 || true
                ;;
            inactive|failed) : ;;
            *) return 1 ;;
        esac
        # Final verification: confirmed stopped, not merely "not active".
        _stop_state=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
        case "$_stop_state" in
            inactive|failed) : ;;
            *) return 1 ;;
        esac
        _stop_pid=$(systemctl show -p MainPID --value "$srv" 2>/dev/null) || return 1
        [[ "$_stop_pid" == 0 ]] || return 1
        # M41-NEW-03: same absent-file tolerance as above — a stopped
        # service with no unit file left is already disabled.
        if [[ -f "$u" && ! -L "$u" ]]; then
            systemctl disable "$srv" >/dev/null 2>&1 || return 1
            enabled_state=$(systemctl show -p UnitFileState --value "$srv" 2>/dev/null) || return 1
            [[ "$enabled_state" == disabled ]] || return 1
        fi
        # Hardening: a unit that was still activating may reach active
        # after the first check; re-verify before reporting success.
        _stop_state=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
        case "$_stop_state" in
            inactive|failed) : ;;
            *) return 1 ;;
        esac
        # M41-NEW-03: systemd may report stopped while a residual
        # process keeps serving the wiped config (cgroup escapee /
        # orphan). Verify no live A-Box-exe process remains; kill a
        # verified residual, and fail if it survives.
        stop_core_residual_process "$srv" || return 1
        return 0
    else
        rc-service "$srv" stop >/dev/null 2>&1 || true
        rc-service "$srv" status >/dev/null 2>&1; rc=$?
        if (( rc == 0 )); then
            # If OpenRC's stop action failed and the service remains active,
            # try its pidfile-aware TERM/KILL escalation only after validating
            # that the pidfile belongs to root and the PID maps to this core.
            force_stop_owned_openrc "$srv" || return 1
            rc-service "$srv" status >/dev/null 2>&1; rc=$?
        fi
        case "$rc" in
            0) return 1 ;;
            3|16|32) : ;;
            *) return 1 ;;
        esac
        rc_show=$(rc-update show default 2>/dev/null) || return 1
        if grep -Eq "(^|[[:space:]])${srv}([[:space:]]|$)" <<< "$rc_show"; then
            rc-update del "$srv" default >/dev/null 2>&1 || return 1
        fi
        rc_show=$(rc-update show default 2>/dev/null) || return 1
        grep -Eq "(^|[[:space:]])${srv}([[:space:]]|$)" <<< "$rc_show" && return 1
        rc-service "$srv" status >/dev/null 2>&1; rc=$?
        case "$rc" in
            0) return 1 ;;
            3|16|32) : ;;
            *) return 1 ;;
        esac
        # M41-NEW-03: same residual-process verification as the systemd
        # branch — an orphan core keeps serving the wiped config even
        # after OpenRC reports it stopped.
        stop_core_residual_process "$srv" || return 1
    fi
}
start_owned() {
    local srv="$1"
    owned "$srv" || return 0
    if is_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable "$srv" >/dev/null 2>&1 || return 1
        systemctl restart "$srv" >/dev/null 2>&1 || return 1
        systemctl is-active --quiet "$srv"
    else
        rc-update add "$srv" default >/dev/null 2>&1 || return 1
        rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || return 1
        rc-service "$srv" status >/dev/null 2>&1
    fi
}
# R7C10-01: the service set for_expected_services enforces, shared by
# the pre-block snapshot and the rollover restore so all three agree.
expected_service_list() {
    local -a svcs=()
    case "${CORE:-}" in
        xray)
            svcs+=(xray)
            if [[ "${MODE:-}" == *ALL* ]]; then svcs+=(hysteria); fi
            ;;
        singbox) svcs+=(sing-box) ;;
        hysteria) svcs+=(hysteria) ;;
        # R26-H-NF-04 (main side): no main pair is a legitimate
        # undeployed state, not unreadable state — fall through to the
        # owned-services mirror below, exactly like
        # expected_managed_services in the main script.
        *) : ;;
    esac
    # Standalone cores outside the .env CORE/MODE pair (e.g. an official
    # HY2 deployed next to a sing-box main core) are enforced too, but
    # only when their unit is verifiably A-Box-owned; foreign services
    # are never touched.
    local srv _s dup
    for srv in xray sing-box hysteria; do
        dup=0
        for _s in "${svcs[@]}"; do
            if [[ "$_s" == "$srv" ]]; then dup=1; break; fi
        done
        (( dup == 1 )) && continue
        owned "$srv" 2>/dev/null && svcs+=("$srv")
    done
    printf '%s\n' "${svcs[@]}"
}
for_expected_services() {
    local list _rc=0 srv
    list=$(expected_service_list) || return 1
    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        "$1" "$srv" || _rc=1
    done <<< "$list"
    return "$_rc"
}
# R7C10-01: snapshot each expected service's active/enabled state
# BEFORE a quota block stops and disables it, so rollover restores
# exactly what the block took down. Written atomically (tmp+mv) and
# first-write-wins per period: a failed commit's best-effort stop must
# not let a later successful commit overwrite pre-stop states with
# all-stopped. A missing/failed snapshot is not fatal: rollover then
# falls back to the legacy start-all behavior.
capture_pre_block_states() {
    local period="$1" tmp list srv active enabled_state
    local _q='' _load_state='' _active_state='' _key='' _value='' _rc=0 _runlevel='' _member='' _rest=''
    local file="${PRE_BLOCK_STATES_PREFIX}-${period}"
    list=$(expected_service_list) || return 1
    tmp=$(mktemp /tmp/A-Box-pre-block-states.XXXXXX) || return 1
    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        active=0
        if is_systemd; then
            # One show query validates LoadState + ActiveState +
            # UnitFileState together; any query or validation
            # failure fails the whole snapshot (never record
            # "unknown" as "originally stopped").
            _q=$(systemctl show --no-pager --all -p LoadState -p ActiveState -p UnitFileState -- "$srv" 2>/dev/null) || { rm -f -- "$tmp"; return 1; }
            _load_state=''; _active_state=''; enabled_state=''
            while IFS='=' read -r _key _value; do
                case "$_key" in
                    LoadState) [[ -z "$_load_state" && -n "$_value" ]] || { rm -f -- "$tmp"; return 1; }; _load_state="$_value" ;;
                    ActiveState) [[ -z "$_active_state" && -n "$_value" ]] || { rm -f -- "$tmp"; return 1; }; _active_state="$_value" ;;
                    UnitFileState) [[ -z "$enabled_state" && -n "$_value" ]] || { rm -f -- "$tmp"; return 1; }; enabled_state="$_value" ;;
                    *) rm -f -- "$tmp"; return 1 ;;
                esac
            done <<< "$_q"
            case "$_load_state" in
                loaded|masked) ;;
                *) rm -f -- "$tmp"; return 1 ;;
            esac
            case "$_active_state" in
                active|reloading|refreshing) active=1 ;;
                inactive|failed) active=0 ;;
                *) rm -f -- "$tmp"; return 1 ;;
            esac
            case "$enabled_state" in
                enabled|enabled-runtime|disabled|static|indirect|linked|linked-runtime|alias|masked|masked-runtime|generated|transient) ;;
                *) rm -f -- "$tmp"; return 1 ;;
            esac
        else
            # OpenRC: default status contract (in-repo precedent:
            # service_active_state_value / stop_owned /
            # _remove_hy2_official): 0 = started, 3|16|32 =
            # confirmed stopped, anything else = unknown.
            if rc-service "$srv" status >/dev/null 2>&1; then
                active=1
            else
                _rc=$?
                case "$_rc" in
                    3|16|32) active=0 ;;
                    *) rm -f -- "$tmp"; return 1 ;;
                esac
            fi
            _runlevel=$(rc-update show default 2>/dev/null) || { rm -f -- "$tmp"; return 1; }
            enabled_state='disabled'
            while IFS=$' \t' read -r _member _rest; do
                if [[ "$_member" == "$srv" ]]; then enabled_state='enabled'; fi
            done <<< "$_runlevel"
        fi
        printf '%s %s %s\n' "$srv" "$active" "$enabled_state" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    done <<< "$list"
    [[ -s "$tmp" ]] || { rm -f -- "$tmp"; return 1; }
    # L-07(C): stamp the capture epoch on the snapshot so a later
    # capture_pre_block_states_once can tell this cycle's snapshot
    # (fresh, reused on a failed-commit retry) from a leftover of an
    # earlier cycle (stale, recaptured). The stamp is a trailing
    # comment line; restore_pre_block_states skips '#' lines.
    printf '# captured %s\n' "$(date +%s)" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}
# R9-04: a failed snapshot must never be re-taken later in the same
# period: after a block the services are already stopped, so a second
# capture would record post-block states and rollover would restore
# "stopped" as if it were the pre-block state. Two independent guards:
# (1) a per-period failure marker suppresses re-capture; (2) a committed
# TRAFFIC_BLOCKED state for this period proves a block already ran, so
# a missing snapshot must not trigger a post-block re-capture even if
# the marker write itself failed. Either guard failing closed keeps the
# documented start-all-owned fallback (restore_or_start_owned).
capture_pre_block_states_once() {
    local file="${PRE_BLOCK_STATES_PREFIX}-${1:-}"
    local _snap_ts=''
    if [[ -f "$file" ]]; then
        # L-07(C): a snapshot for a block already in effect is this
        # block's own: reuse it untouched (R9-04: a later capture would
        # record post-block states). Only when NO block is in effect
        # for this period can a pre-existing file be a leftover from
        # an earlier cycle, and only then is it stamp-checked: reuse it
        # iff it carries a capture stamp, which proves it was written
        # by the current capture code for this period (the file is
        # per-period, so a new period gets a new file). R36a-M1: the old
        # 600s freshness window broke a failed-commit retry chain that
        # outlasted it -- the monitor retries every minute, but a
        # persistent commit failure (e.g. disk full) can last hours,
        # and the recapture then recorded post-block (stopped) states,
        # so rollover restored nothing. Age is not a period boundary;
        # a stamp older than any window is still this period's first
        # snapshot. No stamp at all (a snapshot written before stamps
        # existed) is stale: fall through and recapture, which
        # overwrites the file atomically. The snapshot is never deleted
        # while a block is in effect, so no "blocked without snapshot"
        # (H-05) combination is created.
        if [[ "$(read_desired 2>/dev/null)" == TRAFFIC_BLOCKED && "$(read_block_period 2>/dev/null)" == "${1:-}" ]]; then
            return 0
        fi
        _snap_ts=$(grep -a '^# captured [0-9][0-9]*$' "$file" 2>/dev/null | tail -1 | awk '{print $3}' || true)
        if [[ "$_snap_ts" =~ ^[0-9]+$ ]]; then
            return 0
        fi
    fi
    [[ -f "${file}.snapshot-failed" ]] && return 1
    if [[ "$(read_desired 2>/dev/null)" == TRAFFIC_BLOCKED && "$(read_block_period 2>/dev/null)" == "${1:-}" ]]; then
        return 1
    fi
    capture_pre_block_states "$1" || {
        : > "${file}.snapshot-failed" 2>/dev/null || true
        chmod 600 -- "${file}.snapshot-failed" 2>/dev/null || true
        return 1
    }
}
# R7C10-01: restore the snapshot. Enablement is restored independently
# of activity (a service enabled-but-stopped before the block keeps its
# boot state but stays stopped), and only previously-active services
# are started. Never enables or starts a deliberately disabled/stopped
# service. Services no longer owned are skipped, mirroring start_owned.
restore_pre_block_states() {
    local period="$1" srv active enabled_state _rc=0 _handled=0
    local file="${PRE_BLOCK_STATES_PREFIX}-${period}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while read -r srv active enabled_state; do
        [[ -n "$srv" ]] || continue
        # L-07(C): skip the '# captured <epoch>' stamp line.
        [[ "$srv" == \#* ]] && continue
        owned "$srv" 2>/dev/null || continue
        # 05c2-M1: count records actually handled. The capture side
        # guarantees a valid snapshot holds at least one record
        # ([[ -s $tmp ]] before publish), so zero handled records
        # means an empty or wholly-skipped snapshot: report failure
        # instead of 0, or the caller would commit RUNNING and delete
        # the snapshot on the strength of nothing restored.
        _handled=$(( _handled + 1 ))
        case "$enabled_state" in
            enabled)
                if is_systemd; then systemctl enable "$srv" >/dev/null 2>&1 || _rc=1;
                else rc-update add "$srv" default >/dev/null 2>&1 || _rc=1; fi
                ;;
            enabled-runtime)
                if is_systemd; then systemctl enable --runtime "$srv" >/dev/null 2>&1 || _rc=1; fi
                ;;
        esac
        if [[ "$active" == 1 ]]; then
            if is_systemd; then systemctl restart "$srv" >/dev/null 2>&1 || _rc=1;
            else rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || _rc=1; fi
            # R16-F10-03: a restart rc of 0 does not prove the service
            # stayed up (Type=simple units report success once the main
            # process is spawned). Verify liveness like start_owned
            # does, or a dead core would be reported as resumed and its
            # snapshot discarded.
            if is_systemd; then systemctl is-active --quiet "$srv" || _rc=1;
            else rc-service "$srv" status >/dev/null 2>&1 9>&- 10>&- || _rc=1; fi
        fi
    done < "$file"
    (( _handled > 0 )) || _rc=1
    return "$_rc"
}
# R7C10-01: rollover entry point. With a snapshot for the blocked
# period, restore exactly that; without one (legacy blocks, snapshot
# failure), keep the old start-everything-owned behavior.
restore_or_start_owned() {
    local file="${PRE_BLOCK_STATES_PREFIX}-${1:-}"
    if [[ -f "$file" && ! -L "$file" ]]; then
        restore_pre_block_states "$1"
    else
        for_expected_services start_owned
    fi
}
traffic_error() {
    local log=/var/log/A-Box-traffic.log
    [[ -d /var/log && ! -L /var/log ]] || return 0
    # R15C10-02: never write by pathname after metadata checks: a
    # symlink swapped in between would be followed by the redirect.
    # Open once with O_NOFOLLOW, re-validate the opened descriptor
    # with fstat, and write through that descriptor only. O_CREAT
    # replaces the old install step (which itself could truncate a
    # swapped-in target); the path-stat block is subsumed by fstat.
    # H-09: save/restore the caller umask (bare umask 077 leaked).
    local _te_umask
    _te_umask=$(umask)
    umask 077
    python3 -I - "$log" "$1" <<'PY_TRAFFIC' 2>/dev/null || true
import os, stat as _stat, sys
from datetime import datetime
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    if not _stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or _stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1:
        sys.exit(1)
    ts = datetime.now().astimezone().strftime('%Y-%m-%dT%H:%M:%S%z')
    os.write(fd, (ts + ' ' + sys.argv[2] + '\n').encode('utf-8', 'surrogateescape'))
finally:
    os.close(fd)
PY_TRAFFIC
    umask "$_te_umask"
}
current_period=$(date +%Y-%m)
stop_all_owned_services() {
    local srv _rc=0
    for srv in xray sing-box hysteria; do
        owned "$srv" || continue
        stop_owned "$srv" || _rc=1
    done
    return "$_rc"
}
traffic_fail_closed() {
    local reason="${1:-traffic accounting failed}" failed=0
    traffic_error "$reason; enforcing fail-closed traffic block"
    commit_traffic_pair TRAFFIC_BLOCKED "$current_period" || failed=1
    stop_all_owned_services || failed=1
    return "$failed"
}
state_load_failed=0
load_state || state_load_failed=1
if (( state_load_failed != 0 )); then
    # A missing initial state is harmless during provisioning; an existing but
    # unreadable/invalid persisted state is fail-closed because its traffic
    # limits cannot be trusted to remain enforceable.
    if [[ -e "$ENV" || -L "$ENV" || -e "$DESIRED" || -L "$DESIRED" || -e "$BLOCK_STATE" || -L "$BLOCK_STATE" || -e "$PAIR_STATE" || -L "$PAIR_STATE" ]]; then
        traffic_fail_closed 'persisted traffic state is unreadable or invalid' || traffic_error 'invalid persisted traffic state could not be fail-closed enforced'
        exit 1
    fi
    exit 0
fi
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
[[ -z "${TRAFFIC_LIMIT_GB:-}" ]] || valid_traffic_limit_gb "$TRAFFIC_LIMIT_GB" || {
    traffic_fail_closed 'persisted traffic limit is invalid' || traffic_error 'invalid persisted traffic limit could not be fail-closed enforced'
    exit 1
}
case "${TRAFFIC_LIMIT_MODE:-}" in
    ''|total|rx|tx) ;;
    *)
        traffic_fail_closed 'persisted traffic limit mode is invalid' || traffic_error 'invalid persisted traffic limit mode could not be fail-closed enforced'
        exit 1
        ;;
esac
desired=$(read_desired) || { traffic_fail_closed 'desired state unreadable or invalid' || traffic_error 'desired state could not be fail-closed enforced'; exit 1; }
blocked_period=$(read_block_period 2>/dev/null || true)
if [[ "$desired" == TRAFFIC_BLOCKED && -z "$blocked_period" ]]; then
    commit_traffic_pair TRAFFIC_BLOCKED "$current_period" || {
        # R36a-H1: the migration failure used to exit here, leaving the
        # U49 stop gate below unreachable while services kept running
        # under a persisted TRAFFIC_BLOCKED state (fail-open). Stop
        # best-effort first -- same pattern as the over-quota branch --
        # then exit 1; the state is still unchanged.
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        traffic_error 'traffic-blocked state migration commit failed; services stopped best-effort, state unchanged'
        exit 1
    }
    blocked_period="$current_period"
    traffic_error "migrated legacy traffic-blocked state into billing period ${current_period}"
fi
if [[ "$desired" == TRAFFIC_BLOCKED && "$blocked_period" != "$current_period" ]]; then
    # R6C10-01: mark the rollover before the MAINTENANCE commit so
    # a kill in the window below is recoverable, not permanent.
    printf '%s\n' "$blocked_period" > "$ROLLOVER_MARKER" && chmod 600 -- "$ROLLOVER_MARKER" || { traffic_error 'monthly quota rollover marker write failed; leaving prior desired state unchanged'; exit 1; }
    commit_traffic_pair MAINTENANCE "$blocked_period" || { traffic_error 'monthly quota rollover state commit failed; leaving prior desired state unchanged'; exit 1; }
    if ! restore_or_start_owned "$blocked_period"; then
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        commit_traffic_pair TRAFFIC_BLOCKED "$blocked_period" || traffic_error 'CRITICAL: failed to restore TRAFFIC_BLOCKED state after service start failure; state may be inconsistent'
        traffic_error 'monthly quota period rolled over but at least one owned service could not be started; block remains active'
        exit 1
    fi
    if ! commit_traffic_pair RUNNING ""; then
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        commit_traffic_pair TRAFFIC_BLOCKED "$blocked_period" || traffic_error 'CRITICAL: failed to restore TRAFFIC_BLOCKED state after rollover commit failure; state may be inconsistent'
        traffic_error 'monthly quota rollover state commit failed; managed services were stopped and block restored'
        exit 1
    fi
    desired=RUNNING
    rm -f -- "$ROLLOVER_MARKER"
    # 2jx: verify the snapshot removal — a stale snapshot would make the
    # next period restore stale pre-block states. Retry once, then log.
    rm -f -- "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}" "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}.snapshot-failed" || { sleep 1; rm -f -- "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}" "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}.snapshot-failed" || traffic_error "stale pre-block snapshot for ${blocked_period} could not be removed; next period may restore stale service states"; }
    traffic_error "monthly quota period rolled over from ${blocked_period} to ${current_period}; managed services resumed"
fi
# R6C10-01: recover an interrupted rollover. A kill after the
# MAINTENANCE commit left a persistent MAINTENANCE state that this
# monitor would otherwise exit on forever; the marker is what
# distinguishes rollover-in-progress from manual maintenance.
if [[ -f "$ROLLOVER_MARKER" && "$desired" == MAINTENANCE ]]; then
    if ! restore_or_start_owned "$blocked_period"; then
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        commit_traffic_pair TRAFFIC_BLOCKED "$blocked_period" || traffic_error 'CRITICAL: failed to restore TRAFFIC_BLOCKED state after interrupted rollover recovery failure; state may be inconsistent'
        rm -f -- "$ROLLOVER_MARKER"
        traffic_error 'interrupted monthly quota rollover recovery failed; block remains active'
        exit 1
    fi
    if ! commit_traffic_pair RUNNING ""; then
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        commit_traffic_pair TRAFFIC_BLOCKED "$blocked_period" || traffic_error 'CRITICAL: failed to restore TRAFFIC_BLOCKED state after interrupted rollover recovery failure; state may be inconsistent'
        rm -f -- "$ROLLOVER_MARKER"
        traffic_error 'interrupted monthly quota rollover recovery commit failed; block restored'
        exit 1
    fi
    rm -f -- "$ROLLOVER_MARKER"
    desired=RUNNING
    # 2jx: verify the snapshot removal — a stale snapshot would make the
    # next period restore stale pre-block states. Retry once, then log.
    rm -f -- "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}" "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}.snapshot-failed" || { sleep 1; rm -f -- "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}" "${PRE_BLOCK_STATES_PREFIX}-${blocked_period}.snapshot-failed" || traffic_error "stale pre-block snapshot for ${blocked_period} could not be removed; next period may restore stale service states"; }
    traffic_error "recovered interrupted monthly quota rollover from ${blocked_period} to ${current_period}; managed services resumed"
elif [[ -f "$ROLLOVER_MARKER" ]]; then
    # Stale marker: the state was changed manually out from under the
    # rollover; drop it so it never blocks normal operation.
    rm -f -- "$ROLLOVER_MARKER"
fi
[[ "$desired" == MANUAL_STOPPED || "$desired" == MAINTENANCE ]] && exit 0
if [[ -z "${TRAFFIC_LIMIT_GB:-}" ]]; then
    if [[ "$desired" == TRAFFIC_BLOCKED ]]; then
        for_expected_services stop_owned || stop_all_owned_services || { traffic_error 'traffic remains blocked but service stop could not be verified'; exit 1; }
    fi
    exit 0
fi
iface="${INGRESS_IF:-}"
if [[ -z "$iface" ]]; then
    # H-05 (Carbon) defense-in-depth: with no owned service there is
    # nothing to block, so inferring the interface now is safe and
    # keeps a fresh quota-only box from poisoning itself to
    # TRAFFIC_BLOCKED before any service exists. With owned services
    # present, keep the fail-closed behavior: never switch traffic
    # accounting under a live stack.
    if ! any_owned_service; then
        iface=$(get_active_interface 2>/dev/null || true)
        if [[ -n "$iface" && "$iface" != *$'\n'* ]] && valid_monitor_interface_name "$iface"; then
            traffic_error "INGRESS_IF missing and no owned service exists; using inferred interface $iface for traffic accounting (not persisted)"
        else
            traffic_fail_closed 'INGRESS_IF missing; refusing to switch traffic accounting to a newly inferred interface' || traffic_error 'missing ingress interface could not be fail-closed enforced'
            exit 1
        fi
    else
        traffic_fail_closed 'INGRESS_IF missing; refusing to switch traffic accounting to a newly inferred interface' || traffic_error 'missing ingress interface could not be fail-closed enforced'
        exit 1
    fi
fi
# U49: enforce an already-blocked state before the usage query, so a
# vnStat query failure can never leave restarted services running.
if [[ "$desired" == TRAFFIC_BLOCKED ]]; then
    for_expected_services stop_owned || stop_all_owned_services || { traffic_error 'traffic-blocked state could not be fully enforced'; exit 1; }
fi
# Transient vnStat/metric blips must not flip desired state to TRAFFIC_BLOCKED.
# Only validated over-quota (below) or corrupt persisted policy (above) fail-closed.
used=$(month_bytes "$iface" "${TRAFFIC_LIMIT_MODE:-total}") || { traffic_error 'traffic accounting query failed; leaving prior desired state unchanged'; exit 1; }
limit=$(python3 -I - "$TRAFFIC_LIMIT_GB" <<'PY_TRAFFIC_LIMIT'
import sys
gb = int(sys.argv[1])
limit = gb * 1024 * 1024 * 1024
if limit > 9223372036854775807:
    raise SystemExit(1)
print(limit)
PY_TRAFFIC_LIMIT
) || { traffic_error 'traffic limit conversion failed; leaving prior desired state unchanged'; exit 1; }
[[ "$used" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || { traffic_error 'traffic accounting result was invalid; leaving prior desired state unchanged'; exit 1; }
if python3 -I - "$used" "$limit" <<PY_TRAFFIC_COMPARE
import sys
raise SystemExit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)
PY_TRAFFIC_COMPARE
then
    # R7C10-01: snapshot pre-block states before the first stop (see capture).
    capture_pre_block_states_once "$current_period" || traffic_error 'pre-block service state snapshot failed; rollover will fall back to starting all owned services'
    if ! commit_traffic_pair TRAFFIC_BLOCKED "$current_period"; then
        # The state commit failed (e.g. disk full): still attempt the
        # stop, otherwise the quota protection fails open.
        for_expected_services stop_owned >/dev/null 2>&1 || stop_all_owned_services >/dev/null 2>&1 || true
        traffic_error 'over-quota state commit failed; services stopped best-effort, state unchanged'
        exit 1
    fi
    for_expected_services stop_owned || stop_all_owned_services || { traffic_error 'traffic limit reached but at least one owned service could not be stopped'; exit 1; }
elif [[ "$desired" == TRAFFIC_BLOCKED ]]; then
    # Same-period blocks remain fail-closed even if vnStat later reports a lower value.
    for_expected_services stop_owned || stop_all_owned_services || { traffic_error 'traffic-blocked state could not be fully enforced'; exit 1; }
fi
EOF_TRAFFIC
    # R11C10-01 + R4N10-03: bake state paths and the init marker into
    # the temp copy, then publish atomically (no post-publish sed, so a
    # failed marker write can never leave a published 'unknown' file for
    # rollback to misread as external modification).
    _ab_esc="${ABOX_DIR//\\/\\\\}"
    _ab_esc="${_ab_esc//&/\\&}"
    _ab_esc="${_ab_esc//#/\\#}"
    sed -i -e "s#/etc/ddr#${_ab_esc}#g" -e "s#^INIT_SYS_EXPECTED=.*#INIT_SYS_EXPECTED='${INIT_SYS}'#" "$_tm_tmp" || { rm -f -- "$_tm_tmp"; msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_marker_write_failed)${NC}" >&2; return 1; }
    write_file_atomically_from_stdin "$ABOX_DIR/traffic_monitor.sh" 700 < "$_tm_tmp" || { rm -f -- "$_tm_tmp"; msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_script_write_failed)${NC}" >&2; return 1; }
    rm -f -- "$_tm_tmp"
    grep -Fxq "INIT_SYS_EXPECTED='${INIT_SYS}'" "$ABOX_DIR/traffic_monitor.sh" || { msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_marker_verify_failed)${NC}" >&2; return 1; }
    chmod 700 "$ABOX_DIR/traffic_monitor.sh" || { msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_chmod_failed)${NC}" >&2; return 1; }
    [[ -z "${ABOX_TRAFFIC_TX_DIR:-}" ]] || capture_traffic_quota_expected_state "$ABOX_TRAFFIC_TX_DIR" || { msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_quota_snapshot_failed)${NC}" >&2; return 1; }
    local _tm_script="$ABOX_DIR/traffic_monitor.sh"
    if [[ "$_tm_script" == *[[:space:]]* ]]; then _tm_script=$(shell_single_quote "$_tm_script"); fi
    ( ABOX_DIE_HOOK=''; install_abox_cron_block TRAFFIC "* * * * * /bin/bash $_tm_script >/dev/null 2>&1" ) || { msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_cron_write_failed)${NC}" >&2; return 1; }
    [[ -z "${ABOX_TRAFFIC_TX_DIR:-}" ]] || capture_traffic_quota_expected_state "$ABOX_TRAFFIC_TX_DIR" || { msg "${RED}[!] $(tr_msg valid_hy2_bandwidth_mbps_cron_snapshot_failed)${NC}" >&2; return 1; }
}

