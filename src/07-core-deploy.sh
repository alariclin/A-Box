# ABOX-MODULE-BEGIN 07-core-deploy core deploy, deployment transactions
#   Source: install.sh lines 27914-32420 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
# C2 (fix2c): single canonical top-level is_systemd + xray_owned.
# WARNING: copies of these one-liners also exist inside the
# socket_probe.sh (EOF_PROBE) and geo_update.sh (EOF_GEO) heredocs --
# those are different programs' copies. Never "deduplicate" them away:
# fix2 deleted the only real definitions (HEAD 25640 + XL 41920/41921)
# and kept only heredoc copies; the self-test caught it.
is_systemd() { [[ "${INIT_SYS_EXPECTED:-${INIT_SYS:-}}" == systemd ]]; }
xray_owned() { local u; if is_systemd; then u=/etc/systemd/system/xray.service; else u=/etc/init.d/xray; fi; [[ -f "$u" && ! -L "$u" ]] && grep -Fxq '# Managed by A-Box' "$u"; }

# R27a-L01: SS whitelist firewall transaction, extracted from
# pre_install_setup (which only does interactive input and protocol
# setup). Failure semantics are unchanged: every failure rolls the
# snapshot back and dies with the same message as before; the helper
# is only ever called from pre_install_setup, so die() there exits
# the setup exactly as the inline code did. $1 = whitelist string.
_apply_ss_whitelist_txn() {
    local -a ss_whitelist_ips=()
    local ip proto check_rc
    if [[ "$(firewall_backend)" != 'iptables' ]]; then
        die "$(tr_msg pi_ss_backend)"
    fi
    ss_whitelist_ipv6_precheck || die "$(tr_msg pi_ss_v6_fw)"
    _ss_wl_snapshot_rules || die "$(tr_msg pi_ss_snapshot)"
    remove_ss_open_accept_rules || { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_old_accept)"; }
    read -r -a ss_whitelist_ips <<< "$1"
    for ip in "${ss_whitelist_ips[@]}"; do
        for proto in tcp udp; do
            if [[ "$ip" == *:* ]]; then
                if ! host_has_usable_ipv6 || ! command -v ip6tables >/dev/null 2>&1 || ! _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                    _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_v6_dropped "$ip" "$proto")"
                fi
                if host_has_usable_ipv6 && command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                    if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -s "$ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in
                        0) ;;
                        1) _iptables_do "$IPT6" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -s "$ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_wl6_fail "$ip" "$proto")"; } ;;
                        *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
                    esac
                fi
            else
                if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -s "$ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                case "$check_rc" in
                    0) ;;
                    1) _iptables_do "$IPT" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -s "$ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_wl4_fail "$ip" "$proto")"; } ;;
                    *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
                esac
            fi
        done
    done
    for proto in tcp udp; do
        if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP" -j DROP; then check_rc=0; else check_rc=$?; fi
        case "$check_rc" in
            0) ;;
            1) _iptables_do "$IPT" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP" -j DROP >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_drop4_fail "$proto")"; } ;;
            *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
        esac
        if host_has_usable_ipv6 && command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
            if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP6" -j DROP; then check_rc=0; else check_rc=$?; fi
            case "$check_rc" in
                0) ;;
                1) _iptables_do "$IPT6" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP6" -j DROP >/dev/null 2>&1 || { if _ss_wl_rollback_to_snapshot; then die "$(tprintf pi_ss_drop6_fail_rb "$proto")"; else die "$(tprintf pi_ss_drop6_fail_norb "$proto")"; fi; } ;;
                *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
            esac
        fi
    done
    enforce_ss_whitelist_order "$SS_PORT" || { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_order)"; }
}
pre_install_setup() {
    local CORE_IN=$1 MODE_IN=$2
    reset_protocol_vars
    local DEF_V_PORT=443 DEF_X_PORT=8443 DEF_H_PORT=443 DEF_S_PORT=2053
    local INPUT_H_DOMAIN INPUT_H_HOP INPUT_SS_WL INPUT_KA ip prompt proto holder check_rc
    local -a ss_whitelist_ips=()
    local HAS_VISION=false HAS_XHTTP=false HAS_HY2=false HAS_SS=false
    local L_VISION L_XHTTP L_HY2 L_SS L_GLOBAL
    L_VISION=$(proto_label 'VLESS-Vision')
    L_XHTTP=$(proto_label 'VLESS-XHTTP')
    L_HY2=$(proto_label 'HY2')
    L_SS=$(proto_label 'SS-2022')
    case "${ABOX_LANG:-zh}" in
        en) L_GLOBAL=$(proto_label 'Global') ;;
        ru) L_GLOBAL=$(proto_label 'Глобальный') ;;
        fa) L_GLOBAL=$(proto_label 'گلوبال') ;;
        ja)
            L_GLOBAL=$(proto_label 'グローバル') ;;
        zh-tw) L_GLOBAL=$(proto_label '全域性') ;;
        *) L_GLOBAL=$(proto_label '全局') ;;
    esac
    [[ "$MODE_IN" == *'VISION'* || "$MODE_IN" == *'ALL'* || "$MODE_IN" == 'VLESS_SS' ]] && HAS_VISION=true
    [[ "$CORE_IN" == 'xray' && ( "$MODE_IN" == *'XHTTP'* || "$MODE_IN" == *'ALL'* ) ]] && HAS_XHTTP=true
    [[ "$MODE_IN" == *'HY2'* || "$MODE_IN" == *'ALL'* ]] && HAS_HY2=true
    [[ "$MODE_IN" == *'SS'* || "$MODE_IN" == *'ALL'* || "$MODE_IN" == 'VLESS_SS' ]] && HAS_SS=true

    # Xray ALL: Vision TCP 443 + XHTTP TCP 8443 + HY2 UDP 443 + SS-2022 TCP/UDP 2053.
    # sing-box ALL: Vision TCP 443 + HY2 UDP 443 + SS-2022 TCP/UDP 2053. XHTTP is intentionally excluded.

    INGRESS_IF=$(get_active_interface)
    [[ -z "$INGRESS_IF" ]] && die "$(tr_msg pi_no_iface)"
    # A-02: Validate interface name before interpolating into ExecStartPre (command injection).
    valid_interface_name "$INGRESS_IF" || die "$(tr_msg pi_bad_iface)"
    GLOBAL_PUBLIC_IP=$(refresh_public_ip)

    # Resolve one SNI per REALITY deployment. Amazon is used only after a live
    # TLS 1.3, HTTP/2 ALPN, and certificate-SAN check. If neither a preferred
    # candidate nor the fallback can be verified, interactive setup asks for a
    # manually entered SNI; the one-click path fails closed.
    ABOX_AUTO_SNI_SELECTED=''
    if [[ "$HAS_VISION" == 'true' || "$HAS_XHTTP" == 'true' ]]; then
        ABOX_AUTO_SNI_SELECTED=$(sni_auto_select_default) || ABOX_AUTO_SNI_SELECTED=''
        if valid_sni "$ABOX_AUTO_SNI_SELECTED"; then
            msg "$(tprintf pi_sni_ok "$ABOX_AUTO_SNI_SELECTED")"
        else
            ABOX_AUTO_SNI_SELECTED=''
            msg "${YELLOW}$(tr_msg pi_sni_none)${NC}"
        fi
    fi

    # U1 one-click / quick path: Vision-only defaults, reuse remaining setup (ports/firewall).
    if [[ "${ABOX_QUICK_DEPLOY:-0}" == '1' && "$HAS_VISION" == 'true' && "$HAS_XHTTP" != 'true' && "$HAS_HY2" != 'true' && "$HAS_SS" != 'true' ]]; then
        VLESS_PORT="$DEF_V_PORT"
        if ! valid_sni "$ABOX_AUTO_SNI_SELECTED"; then
            # W2-FAIL-2 (matrix4-C): no verified auto-select candidate.
            # ABOX_QUICK_DEPLOY cannot tell interactive from unattended
            # (the R menu itself sets it), so the discriminator is the
            # TTY test, the codebase's established idiom ([[ -t 0 ]]).
            # Interactive: one manual retry through prompt_reality_sni,
            # the same live validation as the wizard (format + DNS
            # resolvability gate + TLS/SAN tier probe; tier R/D/N
            # warn-and-confirm). Cancel/EOF makes prompt_reality_sni
            # return 1, and this function returns 1 (never die) so
            # deploy_xray/deploy_singbox rolls the transaction back and
            # the menu loop redraws. Unattended: keep the fail-closed
            # die() -- nonzero exit, never prompts.
            if [[ -t 0 ]]; then
                ABOX_AUTO_SNI_SELECTED=$(prompt_reality_sni "$L_VISION" "$DEF_V_PORT") || return 1
            else
                die "$(tr_msg pi_oneclick_sni_fail)"
            fi
        fi
        VISION_SNI="$ABOX_AUTO_SNI_SELECTED"
        VLESS_SNI="$VISION_SNI"
        ENABLE_KEEPALIVE='false'
        msg "${GREEN}$(tprintf pi_oneclick_defaults "$VLESS_PORT" "$VISION_SNI")${NC}"
        check_selected_ports_free
        allowPort "$VLESS_PORT" tcp
        save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
        return 0
    fi

    printf '\n%s\n' "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en|ru|fa)
            msg "${BOLD}$(tprintf pi_wizard "$CORE_IN" "$MODE_IN")${NC}"
            ;;
        ja)
            msg "${BOLD}$(tprintf pi_wizard "$CORE_IN" "$MODE_IN")${NC}"
            ;;
        zh-tw)
            msg "${BOLD}$(tprintf pi_wizard "$CORE_IN" "$MODE_IN")${NC}"
            ;;
        *)
            msg "${BOLD}$(tprintf pi_wizard "$CORE_IN" "$MODE_IN")${NC}"
            ;;
    esac
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"

    if [[ "$HAS_VISION" == 'true' ]]; then
        VLESS_PORT=$(prompt_port_input "$L_VISION" "$DEF_V_PORT") || die "$(tprintf pi_port_closed "$L_VISION")"
        VISION_SNI=$(prompt_reality_sni "$L_VISION" "$VLESS_PORT") || die "$(tprintf pi_sni_closed "$L_VISION")"
    fi
    if [[ "$HAS_XHTTP" == 'true' ]]; then
        XHTTP_PORT=$(prompt_port_input "$L_XHTTP" "$DEF_X_PORT") || die "$(tprintf pi_port_closed "$L_XHTTP")"
        XHTTP_SNI=$(prompt_reality_sni "$L_XHTTP" "$XHTTP_PORT") || die "$(tprintf pi_sni_closed "$L_XHTTP")"
    fi
    VLESS_SNI=${VISION_SNI:-${XHTTP_SNI:-${ABOX_AUTO_SNI_SELECTED:-}}}

    if [[ "$HAS_HY2" == 'true' ]]; then
        HY2_BASE_PORT=$(prompt_port_input "$L_HY2" "$DEF_H_PORT") || die "$(tprintf pi_port_closed "$L_HY2")"

        if [[ "$CORE_IN" == 'singbox' ]]; then
            read -r -p "   ${L_HY2} $(tr_msg pi_hy2_domain_sb)" INPUT_H_DOMAIN || die "$(tr_msg pi_input_closed)"
        else
            read -r -p "   ${L_HY2} $(tr_msg pi_hy2_domain)" INPUT_H_DOMAIN || die "$(tr_msg pi_input_closed)"
        fi
        HY2_DOMAIN="$INPUT_H_DOMAIN"
        if [[ -n "$HY2_DOMAIN" ]]; then
            valid_domain "$HY2_DOMAIN" || die "$(tprintf pi_bad_domain "$HY2_DOMAIN")"
            [[ "${GLOBAL_PUBLIC_IP:-N/A}" != 'N/A' ]] && verify_domain_points_to_self "$HY2_DOMAIN" "$GLOBAL_PUBLIC_IP"
            HY2_ACME_TYPE='http'
            HY2_ACME_DNS_PROVIDER=''
            HY2_ACME_DNS_CF_API_TOKEN=''
            if [[ "$CORE_IN" == 'hysteria' || ( "$CORE_IN" == 'xray' && "$MODE_IN" == *'ALL'* ) ]]; then
                if [[ -n "${ABOX_HY2_ACME_DNS_PROVIDER:-${ABOX_ACME_DNS_PROVIDER:-}}" ]]; then
                    HY2_ACME_TYPE='dns'
                    HY2_ACME_DNS_PROVIDER="${ABOX_HY2_ACME_DNS_PROVIDER:-${ABOX_ACME_DNS_PROVIDER:-}}"
                    HY2_ACME_DNS_CF_API_TOKEN="${ABOX_HY2_ACME_DNS_CF_API_TOKEN:-${ABOX_ACME_DNS_CF_API_TOKEN:-}}"
                else
                    local INPUT_ACME_DNS INPUT_CF_TOKEN
                    case "${ABOX_LANG:-zh}" in
                        en)
                        read -r -p "   ${L_HY2} Use Cloudflare DNS-01 ACME instead of HTTP-01? [Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                        ru)
                        read -r -p "   ${L_HY2} Использовать Cloudflare DNS-01 ACME вместо HTTP-01? [Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                        fa)
                        read -r -p "   ${L_HY2} استفاده از Cloudflare DNS-01 ACME به جای HTTP-01؟ [Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                        ja)
                            read -r -p "   ${L_HY2} HTTP-01 の代わりに Cloudflare DNS-01 ACME で証明書を取得しますか？[Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                        zh-tw)
                        read -r -p "   ${L_HY2} 是否使用 Cloudflare DNS-01 申請證書以避免佔用 80 埠？[Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                        *)
                        read -r -p "   ${L_HY2} 是否使用 Cloudflare DNS-01 申请证书以避免占用 80 端口？[Y/N]: " INPUT_ACME_DNS || die "$(tr_msg pi_input_closed)"
                            ;;
                    esac
                    if is_yes "$INPUT_ACME_DNS"; then
                        HY2_ACME_TYPE='dns'
                        HY2_ACME_DNS_PROVIDER='cloudflare'
                        IFS= read -r -s -p "   ${L_HY2} Cloudflare API Token: " INPUT_CF_TOKEN || die "$(tr_msg pi_input_closed)"
                        echo
                        HY2_ACME_DNS_CF_API_TOKEN="$INPUT_CF_TOKEN"
                    fi
                fi
                if [[ "${HY2_ACME_TYPE:-http}" == 'dns' ]]; then
                    [[ "${HY2_ACME_DNS_PROVIDER:-}" == 'cloudflare' ]] || die "$(tr_msg pi_acme_cf_only)"
                    valid_single_line_secret "${HY2_ACME_DNS_CF_API_TOKEN:-}" 512 || die "$(tr_msg pi_acme_token_bad)"
                fi
            fi
        fi

        read -r -p "   ${L_HY2} $(tr_msg pi_hop)" INPUT_H_HOP || die "$(tr_msg pi_input_closed)"
        if is_yes "$INPUT_H_HOP"; then
            HY2_HOP='true'
            HY2_RANGE_START=20000
            HY2_RANGE_END=25000
            if [[ "$CORE_IN" == 'hysteria' || ( "$CORE_IN" == 'xray' && "$MODE_IN" == *'ALL'* ) ]]; then
                HY2_HOP_IMPL='official'
                HY2_URI_PORTS="${HY2_RANGE_START}-${HY2_RANGE_END}"
                HY2_MONITOR_PORT="$HY2_RANGE_START"
            else
                HY2_HOP_IMPL='manual'
                HY2_URI_PORTS="${HY2_BASE_PORT}"
                HY2_MONITOR_PORT="$HY2_BASE_PORT"
                if has_ipv6; then
                    command -v ip6tables >/dev/null 2>&1 || die "$(tr_msg pi_hop_v6a)"
                    _iptables_q ip6tables -t nat -L PREROUTING >/dev/null 2>&1 || die "$(tr_msg pi_hop_v6b)"
                fi
            fi
            HY2_CLASH_PORTS="${HY2_RANGE_START}-${HY2_RANGE_END}"
            HY2_SB_PORTS="${HY2_RANGE_START}:${HY2_RANGE_END}"
        else
            HY2_HOP='false'
            HY2_HOP_IMPL='none'
            HY2_URI_PORTS="$HY2_BASE_PORT"
            HY2_CLASH_PORTS=''
            HY2_SB_PORTS=''
            HY2_MONITOR_PORT="$HY2_BASE_PORT"
        fi

        HY2_DOWN=$(prompt_hy2_bandwidth_mbps_input "   ${L_HY2} $(tr_msg pi_down)" 1000) || die "$(tr_msg pi_down_closed)"
        HY2_UP=$(prompt_hy2_bandwidth_mbps_input "   ${L_HY2} $(tr_msg pi_up)" 100) || die "$(tr_msg pi_up_closed)"

        local masq_default="https://${VISION_SNI:-${XHTTP_SNI:-www.samsung.com}}/"
        HY2_MASQ_URL=$(prompt_https_url "   ${L_HY2} $(tprintf pi_hy2_masq_prompt "$masq_default")" "$masq_default") || die "$(tr_msg pi_hy2_masq_closed)"
    fi
    if [[ "$HAS_SS" == 'true' ]]; then
        SS_PORT=$(prompt_ss_port_input "$L_SS" "$DEF_S_PORT") || die "$(tr_msg pi_ss_port_closed)"
        read -r -p "   ${L_SS} $(tr_msg pi_ss_wl)" INPUT_SS_WL || die "$(tr_msg pi_input_closed)"
        SS_WHITELIST_IP="$INPUT_SS_WL"
        if [[ -n "$SS_WHITELIST_IP" ]]; then
            read -r -a ss_whitelist_ips <<< "$SS_WHITELIST_IP"
            for ip in "${ss_whitelist_ips[@]}"; do
                if [[ "$ip" == *:* ]]; then
                    valid_ipv6_cidr "$ip" || die "$(tprintf pi_wl6_bad "$ip")"
                else
                    valid_ipv4_cidr "$ip" || die "$(tprintf pi_wl4_bad "$ip")"
                fi
            done
        fi
    fi

    if abox_is_fast; then
        ENABLE_KEEPALIVE='false'
        msg "${YELLOW}$(tr_msg pi_fast_ka_off)${NC}"
    else
        case "${ABOX_LANG:-zh}" in
            en)
            read -r -p "   ${L_GLOBAL} Enable TCP KeepAlive 45s to prevent NAT idle disconnect? [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
            ru)
            read -r -p "   ${L_GLOBAL} Включить TCP KeepAlive 45с для предотвращения разрыва соединения NAT? [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
            fa)
            read -r -p "   ${L_GLOBAL} فعال‌سازی TCP KeepAlive به مدت 45 ثانیه برای جلوگیری از قطع اتصال بی‌فعال NAT؟ [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
            ja)
                read -r -p "   ${L_GLOBAL} NAT のアイドル時切断を防ぐため、TCP KeepAlive (45s) を有効にしますか？ [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
            zh-tw)
            read -r -p "   ${L_GLOBAL} 是否開啟 TCP KeepAlive (45s) 防治 NAT 空閒斷連? [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
            *)
            read -r -p "   ${L_GLOBAL} 是否开启 TCP KeepAlive (45s) 防治 NAT 空闲断连? [Y/N]: " INPUT_KA || die "$(tr_msg pi_input_closed)"
                ;;
        esac
        is_yes "$INPUT_KA" && ENABLE_KEEPALIVE='true' || ENABLE_KEEPALIVE='false'
    fi
    printf '%s\n\n' "${CYAN}======================================================================${NC}"

    check_selected_ports_free
    if [[ "$HAS_HY2" == 'true' ]] && hy2_http01_enabled "$CORE_IN" "$MODE_IN"; then
        if ! holder=$(ss -H -n -l -p -A tcp 2>/dev/null); then
            die "$(tr_msg pi_ss_check_fail)"
        fi
        holder=$(awk '{if ($4 ~ /[:.]80$/ || $5 ~ /[:.]80$/) { print; found=1 }} END { if (!found) exit 0 }' <<< "$holder" || true)
        if [[ -n "$holder" ]]; then
            msg "${RED}$(tr_msg pi_acme_port_busy)${NC}"
            echo "$holder"
            die "$(tr_msg pi_acme_port_advice)"
        fi
    fi

    [[ "$HAS_VISION" == 'true' ]] && allowPort "$VLESS_PORT" tcp
    [[ "$HAS_XHTTP" == 'true' ]] && allowPort "$XHTTP_PORT" tcp
    if [[ "$HAS_HY2" == 'true' ]]; then
        if hy2_http01_enabled "$CORE_IN" "$MODE_IN"; then
            allowPort 80 tcp
        fi
        if [[ "$HY2_HOP" == 'true' ]]; then
            allowPort "${HY2_RANGE_START}:${HY2_RANGE_END}" udp
            [[ "$HY2_HOP_IMPL" == 'manual' ]] && allowPort "$HY2_BASE_PORT" udp
        else
            allowPort "$HY2_BASE_PORT" udp
        fi
    fi
    if [[ "$HAS_SS" == 'true' ]]; then
        if [[ -n "${SS_WHITELIST_IP:-}" ]]; then
            _apply_ss_whitelist_txn "$SS_WHITELIST_IP"
        else
            allowPort "$SS_PORT" tcp
            allowPort "$SS_PORT" udp
        fi
    fi
    save_firewall_rules || { if _ss_wl_rollback_to_snapshot; then die "$(tr_msg pi_fw_persist_rb)"; else die "$(tr_msg pi_fw_persist_norb)"; fi; }
}

json_sockopt_xray() {
    if [[ "${ENABLE_KEEPALIVE:-}" == 'true' ]]; then
        jq -n '{tcpKeepAliveIdle:45,tcpKeepAliveInterval:45}'
    else
        jq -n 'null'
    fi
}

build_xray_config() {
    local mode="$1" sockopt_json inbounds_json out="${2:-/usr/local/etc/xray/config.json}" tmp_out listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    sockopt_json=$(json_sockopt_xray)
    inbounds_json=$(jq -n \
        --arg mode "$mode" \
        --arg listen_addr "$listen_addr" \
        --rawfile uuid <(printf '%s' "${UUID:-}") \
        --arg v_sni "${VISION_SNI:-${VLESS_SNI:-${ABOX_AUTO_SNI_SELECTED:-}}}" \
        --arg x_sni "${XHTTP_SNI:-${VLESS_SNI:-${ABOX_AUTO_SNI_SELECTED:-}}}" \
        --rawfile pk <(printf '%s' "${PK:-}") \
        --rawfile sid <(printf '%s' "${SHORT_ID:-}") \
        --argjson vport "${VLESS_PORT:-443}" \
        --argjson xport "${XHTTP_PORT:-8443}" \
        --argjson ssport "${SS_PORT:-2053}" \
        --rawfile ss_pass <(printf '%s' "${SS_PASS:-}") \
        --argjson sock "$sockopt_json" '
        def maybe_sock: if $sock == null then {} else {sockopt:$sock} end;
        def vision:
          {
            listen:$listen_addr, port:$vport, protocol:"vless", tag:"vision",
            settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision", email:"vision/main"}], decryption:"none"},
            streamSettings:({network:"tcp", security:"reality", realitySettings:{target:($v_sni + ":443"), serverNames:[$v_sni], privateKey:$pk, shortIds:[$sid], minClientVer:"1.8.2"}} + maybe_sock),
            sniffing:{enabled:true, destOverride:["http","tls","quic"]}
          };
        def xhttp:
          {
            listen:$listen_addr, port:$xport, protocol:"vless", tag:"xhttp",
            settings:{clients:[{id:$uuid, email:"xhttp/main"}], decryption:"none"},
            streamSettings:({network:"xhttp", security:"reality", xhttpSettings:{mode:"auto", path:"/xhttp"}, realitySettings:{target:($x_sni + ":443"), serverNames:[$x_sni], privateKey:$pk, shortIds:[$sid], minClientVer:"1.8.2"}} + maybe_sock),
            sniffing:{enabled:true, destOverride:["http","tls","quic"]}
          };
        def ss:
          ({listen:$listen_addr, port:$ssport, protocol:"shadowsocks", tag:"ss", settings:{method:"2022-blake3-aes-128-gcm", password:$ss_pass, network:"tcp,udp"}}
           + (if $sock == null then {} else {streamSettings:{sockopt:$sock}} end));
        []
        | if ($mode|contains("VISION")) or ($mode|contains("ALL")) or $mode == "VLESS_SS" then . + [vision] else . end
        | if ($mode|contains("XHTTP")) or ($mode|contains("ALL")) then . + [xhttp] else . end
        | if ($mode|contains("SS")) or ($mode|contains("ALL")) or $mode == "VLESS_SS" then . + [ss] else . end
    ') || die "$(tr_msg bx_inbounds)"
    local out_dir
    out_dir=$(dirname -- "$out")
    [[ ! -L "$out_dir" && ! -L "$out" ]] || die "$(tr_msg bx_symlink)"
    [[ ! -e "$out_dir" || -d "$out_dir" ]] || die "$(tr_msg bx_parent)"
    # R9C8-01: $out itself must be a regular file (or absent).
    # Without this, mv installs the generated config INSIDE a
    # pre-existing directory and still reports success.
    [[ ! -e "$out" || -f "$out" ]] || die "Refusing to install build_xray_config config: output path exists and is not a regular file: $out"
    [[ -d "$out_dir" ]] || install -d -m 755 -- "$out_dir" || die "$(tr_msg bx_dir)"
    tmp_out=$(mktemp "$out_dir/.A-Box-xray-config.XXXXXX") || die "$(tr_msg bx_tmp)"
    # H-09: save/restore the caller umask (bare umask 077 leaked).
    local _bx_umask
    _bx_umask=$(umask)
    umask 077
    # XRAY-API (Version A experiment): gRPC control plane for hot-reload.
    # SECURITY: the API has NO authentication. listen is hardcoded to 127.0.0.1
    # and NEVER derived from wildcard_listen_address (which may be 0.0.0.0/::).
    # Binding it to anything but loopback would expose full config control.
    # Merge routing state (WARP / split-routing outbounds + rules); survives redeploys.
    local _rs_ob='[]' _rs_rules='[]'
    if [[ -L "$ROUTING_STATE_FILE" ]]; then
        die 'Routing state file is a symbolic link; refusing to deploy without routing policy.'
    fi
    # R15-F08-03: a path that exists but is not a regular file
    # (directory / FIFO / socket) is damage, not absence: fail
    # closed like a symlink or invalid content instead of
    # silently deploying with an empty routing set.
    if [[ -e "$ROUTING_STATE_FILE" && ! -f "$ROUTING_STATE_FILE" && ! -L "$ROUTING_STATE_FILE" ]]; then
        die 'Routing state path exists but is not a regular file; refusing to deploy without routing policy.'
    fi
    if [[ -f "$ROUTING_STATE_FILE" && ! -L "$ROUTING_STATE_FILE" ]]; then
        jq -e '.version == 1 and (.outbounds | type == "array") and (.rules | type == "array")' "$ROUTING_STATE_FILE" >/dev/null 2>&1 || die 'Routing state file is invalid; refusing to deploy without routing policy.'
        _rs_ob=$(jq -c '[.outbounds[]?.xray]' "$ROUTING_STATE_FILE" 2>/dev/null) || die 'Routing state outbound merge failed.'
        _rs_rules=$(jq -c '[.rules[]?.xray_rule]' "$ROUTING_STATE_FILE" 2>/dev/null) || die 'Routing state rule merge failed.'
    fi
    jq -n --slurpfile inbounds <(printf '%s' "$inbounds_json") --slurpfile rs_ob <(printf '%s' "$_rs_ob") --slurpfile rs_rules <(printf '%s' "$_rs_rules") '{
        log:{loglevel:"warning", access:"/var/log/A-Box-xray-access.log", error:"/var/log/A-Box-xray-error.log"},
        api:{tag:"api", services:["HandlerService","LoggerService","StatsService"]},
        stats:{},
        policy:{levels:{"0":{statsUserUplink:true, statsUserDownlink:true}}, system:{statsInboundUplink:true, statsInboundDownlink:true}},
        routing:{domainStrategy:"IPOnDemand", rules: ([
            {type:"field", inboundTag:["api"], outboundTag:"api"},
            # R2C8-01: proxy clients must not reach loopback (the API has
            # no auth); the api-inbound rule above matches first, so the
            # legitimate control plane is unaffected. IP-based, so it also
            # covers the normal Xray API port and any other local service.
            {type:"field", ip:["127.0.0.0/8", "::1/128"], outboundTag:"block"},
            {type:"field", protocol:["bittorrent"], outboundTag:"block"},
            {type:"field", domain:["geosite:category-ads-all"], outboundTag:"block"}
        ] + $rs_rules[0]) },
        inbounds:([{listen:"127.0.0.1", port:10085, protocol:"dokodemo-door", settings:{address:"127.0.0.1"}, tag:"api"}] + $inbounds[0]),
        outbounds: ([{protocol:"freedom", tag:"direct"}, {protocol:"blackhole", tag:"block"}, {protocol:"freedom", tag:"api"}] + $rs_ob[0])
    }' > "$tmp_out" || { rm -f "$tmp_out"; die "$(tr_msg bx_json)"; }
    chmod 600 "$tmp_out" || { rm -f "$tmp_out"; die "$(tr_msg bx_chmod)"; }
    [[ $EUID -eq 0 ]] && chown root:root "$tmp_out" || true
    [[ -d "$out" ]] && { rm -f "$tmp_out"; die "$(tr_msg bx_commit)"; }
    mv -f -- "$tmp_out" "$out" || { rm -f "$tmp_out"; die "$(tr_msg bx_commit)"; }
    umask "$_bx_umask"
}

# ============ Xray API hot-reload (Version A experiment, 233boy style) ============
# Control plane: 127.0.0.1:10085 ONLY. The gRPC API has no authentication, so the
# address is a hardcoded constant here and in build_xray_config -- never derived
# from wildcard_listen_address, never 0.0.0.0, never ::.
XRAY_API_SERVER='127.0.0.1:10085'
XRAY_API_PORT='10085'

# Returns 0 if the Xray API endpoint answers on loopback.
xray_api_available() {
    [[ -x /usr/local/bin/xray ]] || return 1
    is_service_running xray 2>/dev/null || return 1
    local pid
    pid=$(managed_service_pid xray 2>/dev/null || true)
    pid=${pid%%$'\n'*}
    [[ -n "$pid" ]] || return 1
    if command -v ss >/dev/null 2>&1; then
        # No -q: grep reads the whole listing, so no SIGPIPE under
        # pipefail can turn a found api socket into a false negative.
        ss -tlnp 2>/dev/null | grep -E ":${XRAY_API_PORT}[[:space:]].*pid=${pid}," >/dev/null
        return $?
    fi
    # Loopback-only TCP probe; never touches the network. The probe
    # runs in a subshell, so its fd 3 dies with it: nothing to close
    # here, and a bare exec close would only redirect stderr to
    # /dev/null for the rest of the process.
    (exec 3<>/dev/tcp/127.0.0.1/10085) >/dev/null 2>&1 || return 1
    return 0
}

# Low-level: push ONE inbound object to the running Xray via gRPC API.
# $1 = path to a JSON file containing a single inbound OBJECT (not an array).
# Prints nothing; returns 0 on success, 1 on failure (caller falls back).
xray_api_add_inbound() {
    local json_file="$1"
    [[ -n "$json_file" && -f "$json_file" && ! -L "$json_file" ]] || return 1
    [[ -x /usr/local/bin/xray ]] || return 1
    # The object must carry a usable, non-reserved tag.
    local tag
    tag=$(jq -r '.tag // empty' "$json_file" 2>/dev/null) || return 1
    [[ -n "$tag" && "$tag" != 'api' ]] || return 1
    # adi loads a config document (inbounds array), not a bare object:
    # a bare object adds zero inbounds yet can exit 0, so wrap it.
    local doc
    # R16-F08-02: create the .json target directly with mktemp
    # (O_CREAT|O_EXCL, random suffix). The old reserve+mv derived a
    # predictable "$doc.json" name from the bare mktemp path, and a
    # pre-planted FIFO there blocked the noclobber redirect forever.
    local _adi_d=''
    _adi_d=$(mktemp -d /tmp/A-Box-xray-adi.XXXXXX) || return 1
    doc="$_adi_d/adi.json"
    if ! jq -s '{inbounds: .}' "$json_file" > "$doc" 2>/dev/null; then rm -f "$doc"; rm -rf -- "$_adi_d"; return 1; fi
    if ! jq -e '.inbounds | length == 1' "$doc" >/dev/null 2>&1; then rm -f "$doc"; rm -rf -- "$_adi_d"; return 1; fi
    if ! /usr/local/bin/xray api adi --server="$XRAY_API_SERVER" "$doc" >/dev/null 2>&1; then rm -f "$doc"; rm -rf -- "$_adi_d"; return 1; fi
    rm -f "$doc"; rm -rf -- "$_adi_d"
    return 0
}

# Low-level: remove an inbound from the running Xray by tag via gRPC API.
# $1 = inbound tag. The built-in "api" tag is protected and always refused.
xray_api_remove_inbound() {
    local tag="$1"
    [[ -n "$tag" && "$tag" != 'api' ]] || return 1
    [[ -x /usr/local/bin/xray ]] || return 1
    /usr/local/bin/xray api rmi --server="$XRAY_API_SERVER" "$tag" >/dev/null 2>&1
}


# Ensure an Xray-family config carries the stats/policy blocks and the
# loopback API inbound that per-user accounting (fix47) relies on.
# Idempotent. Used when the multi-user manager first touches a config
# that predates fix47 (standalone-only slot configs). Callers
# snapshot first and validate with the core's -test
# afterwards; this helper only transforms and atomically installs.
# $1 = config path, $2 = api port (10085 normal slot).
xray_ensure_stats() {
    local cfg="$1" api_port="${2:-10085}" tmp=''
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    # 04c1-M1: the live config may carry // or /* */ comments (Xray
    # accepts JSONC); strip them before jq, like xray_hot_add_inbound
    # does -- bare jq rejects a commented config at both steps below.
    if jsonc_strip_comments "$cfg" 2>/dev/null | jq -e --argjson ap "$api_port" '
        def abox_loopback_rule:
            {type:"field", ip:["127.0.0.0/8","::1/128"], outboundTag:"block"};
        def abox_api_rule($t):
            {type:"field", inboundTag:[$t], outboundTag:$t};
        (.api.tag // "api") as $t
        | (.policy.levels // {}) as $levels
        | (([.. | objects | .level? // empty] | unique) as $reflevels
           | (.stats != null)
           and (.policy.levels."0".statsUserUplink == true)
           and (.policy.levels."0".statsUserDownlink == true)
           and ([(.policy.levels // {}) | to_entries[] | select(.value.statsUserUplink != true or .value.statsUserDownlink != true)] | length == 0)
           and ([$reflevels[] | select(($levels[(. | tostring)] // {}).statsUserUplink != true or ($levels[(. | tostring)] // {}).statsUserDownlink != true)] | length == 0)
           and (.policy.system.statsInboundUplink == true)
           and (.policy.system.statsInboundDownlink == true)
           and ((.api.services // []) | index("StatsService") != null)
           and ( ( ([.inbounds[]? | select(.tag == $t and .port == $ap and .protocol == "dokodemo-door" and .listen == "127.0.0.1")] | length > 0)
                   and ([.outbounds[]? | select(.tag == $t)] | length > 0)
                   and ([.routing.rules[]? | select(.outboundTag == $t)] | length > 0) )
                 or (.api.listen == ("127.0.0.1:" + ($ap | tostring))) )
           and ($t != "block")
           and (.routing.domainStrategy == "IPOnDemand")
           and (
               [.outbounds[]? | select(.tag == "block")] as $blocks
               | (($blocks | length) == 1
                  and $blocks[0].protocol == "blackhole")
           )
           and (
               if .api.listen != null then
                   # H1 (04c1): the loopback routing rule does not protect
                   # .api.listen -- it is an independent gRPC socket, not
                   # traffic through inbounds/routing. A non-loopback
                   # listen (e.g. 0.0.0.0) must fail the fast check so
                   # the normalisation below rewrites it to loopback.
                   (.api.listen == ("127.0.0.1:" + ($ap | tostring)))
                   and (.routing.rules[0] == abox_loopback_rule)
               else
                   (.routing.rules[0] == abox_api_rule($t)
                    and .routing.rules[1] == abox_loopback_rule)
               end
           )
    )
    ' >/dev/null 2>&1; then
        return 0
    fi
    tmp=$(mktemp /tmp/A-Box-xstats.XXXXXX) || return 1
    if ! jsonc_strip_comments "$cfg" 2>/dev/null | jq --argjson ap "$api_port" '
        def abox_loopback_rule:
            {type:"field", ip:["127.0.0.0/8","::1/128"], outboundTag:"block"};
        def abox_api_rule($t):
            {type:"field", inboundTag:[$t], outboundTag:$t};
        (.api.tag // "api") as $t
        | ([.. | objects | .level? // empty] | unique) as $reflevels
        | .stats = (.stats // {})
        | .policy.levels = (((.policy.levels // {}) | with_entries(.value.statsUserUplink = true | .value.statsUserDownlink = true))
            * (reduce $reflevels[] as $lv ({}; .[($lv | tostring)] = {statsUserUplink: true, statsUserDownlink: true}))
            * {"0": {statsUserUplink: true, statsUserDownlink: true}})
        | .policy.system.statsInboundUplink = true
        | .policy.system.statsInboundDownlink = true
        | .api = (.api // {tag:"api", services:["HandlerService","LoggerService","StatsService"]})
        | .api.services = (((.api.services // []) + ["StatsService"]) | unique)
        | (if .api.listen != null then
               .api.listen = ("127.0.0.1:" + ($ap | tostring))
               | .inbounds = ((.inbounds // []) | map(select(.tag != $t or .port != $ap)))
           else
               .inbounds = (([.inbounds[]? | select(.tag == $t)] | if length == 0 then [{listen:"127.0.0.1", port:$ap, protocol:"dokodemo-door", settings:{address:"127.0.0.1"}, tag:$t}] else [.[0] | .listen = "127.0.0.1" | .port = $ap | .protocol = "dokodemo-door"] end) + ([.inbounds[]? | select(.tag != $t)]))
               | (if ([.outbounds[]? | select(.tag == $t)] | length) == 0
                  then .outbounds = ((.outbounds // []) + [{protocol:"freedom", tag:$t}]) else . end)
               | .routing = (.routing // {domainStrategy:"IPOnDemand", rules:[]})
               | (if ([.routing.rules[]? | select(.outboundTag == $t)] | length) == 0
                  then .routing.rules = ([{type:"field", inboundTag:[$t], outboundTag:$t}] + (.routing.rules // [])) else . end)
           end)
        | if $t == "block" then
              error("Xray API tag conflicts with the loopback block tag")
          else . end
        | [.outbounds[]? | select(.tag == "block")] as $blocks
        | if ($blocks | length) == 0 then
              .outbounds = ((.outbounds // []) + [
                  {protocol:"blackhole", tag:"block"}
              ])
          elif (($blocks | length) == 1
                and $blocks[0].protocol == "blackhole") then
              .
          else
              error("Xray outbound tag block is not a unique blackhole outbound")
          end
        | (.api.listen == null) as $legacy_api
        | abox_loopback_rule as $guard
        | abox_api_rule($t) as $control
        | .routing.domainStrategy = "IPOnDemand"
        | .routing.rules = (
              (if $legacy_api then [$control, $guard] else [$guard] end)
              + (
                  (.routing.rules // [])
                  | map(select(
                      . != $guard
                      and (if $legacy_api then . != $control else true end)
                  ))
              )
          )
    ' > "$tmp"; then rm -f "$tmp"; return 1; fi
    # A stripped-to-empty input makes jq emit nothing with rc 0, and
    # `jq empty` also passes on an empty file: refuse an empty
    # transform output instead of installing an empty config.
    [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    install_file_atomically "$tmp" "$cfg" 600 || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

xray_hot_add_inbound() {
    local json_file="$1" cfg='/usr/local/etc/xray/config.json' tmp tmpd tag
    [[ -n "$json_file" && -f "$json_file" && ! -L "$json_file" ]] || return 1
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    tag=$(jq -r '.tag // empty' "$json_file" 2>/dev/null) || return 1
    [[ -n "$tag" && "$tag" != 'api' ]] || return 1
    # M-24(3): the live config may carry // and /* */ comments (Xray
    # accepts JSONC); bare jq rejects it. Strip comments first, like
    # the snapshot path does.
    if jsonc_strip_comments "$cfg" 2>/dev/null | jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' >/dev/null 2>&1; then
        return 1  # duplicate tag already persisted
    fi
    # M-24(1): probe-bind the new inbound's port BEFORE overwriting the
    # live config. `xray run -test` only validates syntax, it never
    # binds: without this, a port already held by another process is
    # only discovered when the api-add fails, after which the restart
    # loads a config that cannot bind and the whole Xray dies. Refuse
    # here instead, leaving disk and the running daemon untouched.
    # (No python3 -> no probe; the api-add + restart fallback below
    # still applies, as before. TCP probe only; the SOCKS UDP twin
    # shares the same port number.)
    local _hot_port='' _hot_listen=''
    _hot_port=$(jq -r '.port // empty' "$json_file" 2>/dev/null || true)
    _hot_listen=$(jq -r '.listen // "0.0.0.0"' "$json_file" 2>/dev/null || true)
    if [[ "$_hot_port" =~ ^[0-9]+$ ]] && command -v python3 >/dev/null 2>&1; then
        python3 -I - "$_hot_listen" "$_hot_port" <<'PY_HOT_BIND' 2>/dev/null || return 1
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
fam = socket.AF_INET6 if ':' in host else socket.AF_INET
s = socket.socket(fam, socket.SOCK_STREAM)
try:
    s.bind((host, port))
finally:
    s.close()
PY_HOT_BIND
    fi
    tmpd=$(mktemp -d /tmp/A-Box-xray-hotadd.XXXXXX) || return 1
    tmp="$tmpd/config.json"
    # H2 (04c1): the guard below only fixes the disk config. Record
    # whether the pre-merge disk config already carries it: if it does
    # not, the running config (loaded from disk) cannot be proven
    # guarded either, so a successful hot-add must restart onto the
    # guarded disk config instead of returning 0 with the window open.
    # An unreadable config reads as unguarded (fail closed: restart).
    local _hot_pre_guarded=0
    # R27b-H1: the old predicate only checked that the guard rule and a
    # "block" tag EXIST: a rule AFTER a direct allow rule never matches
    # first, and a freedom outbound tagged "block" forwards loopback
    # traffic, yet both read as guarded and skipped the restart. Use
    # the same semantic predicate as xray_ensure_stats: exactly one
    # blackhole "block" outbound, and the guard in the canonical
    # position (first, or second after the API control rule for a
    # legacy dokodemo-door API; first when .api.listen is set). Any
    # other layout reads as unguarded (fail closed: restart).
    if jsonc_strip_comments "$cfg" 2>/dev/null | jq -e '
        def abox_loopback_rule:
            {type: "field", ip: ["127.0.0.0/8", "::1/128"], outboundTag: "block"};
        def abox_api_rule($t):
            {type: "field", inboundTag: [$t], outboundTag: $t};
        (.api.tag // "api") as $t
        | abox_loopback_rule as $guard
        | abox_api_rule($t) as $control
        | ($t != "block")
          and (([.outbounds[]? | select(.tag == "block")] as $blocks
                | ($blocks | length) == 1 and $blocks[0].protocol == "blackhole")
          and (if .api.listen != null then (.routing.rules[0] == $guard)
               elif ([.routing.rules[]? | select(. == $control)] | length) > 0 then
                   (.routing.rules[0] == $control and .routing.rules[1] == $guard)
               else (.routing.rules[0] == $guard) end))
    ' >/dev/null 2>&1; then
        _hot_pre_guarded=1
    fi
    if ! jsonc_strip_comments "$cfg" 2>/dev/null | jq --slurpfile nb "$json_file" '.inbounds += $nb' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; rm -rf "$tmpd"; return 1
    fi
    jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf "$tmpd"; return 1; }
    # H-07: enforce the loopback guard on the merged config before
    # validation; refuse to install an unguarded config.
    xray_apply_loopback_guard "$tmp" || { rm -f "$tmp"; rm -rf "$tmpd"; return 1; }
    if [[ -x /usr/local/bin/xray ]]; then
        XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; rm -rf "$tmpd"; return 1; }
    fi
    install_file_atomically "$tmp" "$cfg" 600 || { rm -f "$tmp"; rm -rf "$tmpd"; return 1; }
    prepare_abox_runtime_permissions xray || {
        rm -f "$tmp"
        rm -rf "$tmpd"
        return 1
    }
    rm -f "$tmp"; rm -rf "$tmpd"
    # Hot path first: no connection drop. Fallback: restart (old behavior).
    if xray_api_available && xray_api_add_inbound "$json_file"; then
        if (( _hot_pre_guarded == 0 )); then
            # H2 (04c1): disk is guarded now, but the running config was
            # never proven guarded -- restart so live loads the guarded
            # config. Otherwise the new inbound stays reachable via the
            # old unguarded routes (incl. the unauthenticated loopback
            # API) until the next restart.
            restart_service_soft xray
            return $?
        fi
        return 0
    fi
    restart_service_soft xray
}

# High-level: remove an inbound from disk config AND from the running Xray.
# $1 = inbound tag (never "api").
# Fallback: if the API call fails, restart_service_soft picks up the persisted
# config, so the change is never lost and existing behavior is preserved.
# R7-05B: enforce the loopback guard on a sing-box config file in place.
# Prepends [{action:"resolve"}, {ip_cidr:[loopbacks], action:"reject"}]
# to .route.rules (idempotent: no-op when the guard pair is already
# present once, either at the front or in the built position just after
# the sniff rule). Refuses non-object configs and non-array route.rules.
# The input file is never modified on failure.
# N4 (followup5 D-leg, same root cause as 4e83495-line S2-NEW-03):
# build_singbox_config emits the base rules sniff-first
# ([sniff, resolve, loopback-reject, bittorrent-reject]), so the old
# "[0:2] == guard" check never matched a fresh build and the first
# apply prepended a second guard pair (live 6 rules vs baseline 4);
# routing_apply_live keeps non-state rules, so the duplicate survived
# warp_undeploy and clear_all. A missing / partial / duplicated guard
# is therefore rebuilt as exactly one pair at the front, which also
# repairs an already-duplicated live config on the next apply
# (warp_undeploy included); a single intact pair is left untouched
# in place.
# D-leg OBS-04: the guard pair alone is not the baseline. After a
# prune, the first independent-instance deploy seeds a minimal
# config with no .route at all, and this guard only ever added the
# pair -- so live route rules sat at 2 (sniff and bittorrent-reject
# missing) until a full-stack rebuild. Enforce the whole 4-rule
# baseline build_singbox_config emits ([sniff, resolve,
# loopback-reject, bittorrent-reject]) instead: every apply rebuilds
# the rules as the baseline followed by the surviving non-baseline
# rules, in order. A config that is already canonical rebuilds to
# itself, so healthy configs are untouched; a duplicated baseline
# (extra guard-pair copies after the first four) collapses to one.
# The fail-closed refusals above are unchanged.
singbox_apply_loopback_guard() {
    local src="$1" _tmp _dir
    [[ -f "$src" && ! -L "$src" ]] || return 1
    _dir=$(dirname -- "$src") || return 1
    _tmp=$(mktemp "$_dir/.A-Box-sb-guard.XXXXXX") || return 1
    if ! jq '
        [
          {network: ["tcp"], action: "sniff"},
          {action: "resolve"},
          {ip_cidr: ["127.0.0.0/8", "::1/128"], action: "reject"},
          {protocol: "bittorrent", action: "reject"}
        ] as $base
        | if type != "object" then error("sing-box config must be an object") else . end
        | if .route == null then .route = {} elif (.route | type) != "object" then error("sing-box route must be an object") else . end
        | if .route.rules == null then .route.rules = [] elif (.route.rules | type) != "array" then error("sing-box route.rules must be an array") else . end
        # OBS-3 (D1): $base[0] must be exactly what build_singbox_config
        # emits ({network:["tcp"], action:"sniff"}). The old
        # {protocol:"tcp", action:"sniff"} never matched it, so every
        # routing_apply_live prepended a second sniff rule and the
        # duplicate survived warp_undeploy and clear_all. The legacy
        # protocol-form sniff is collapsed as well, so configs already
        # duplicated by the old guard repair to canonical on next apply.
        | .route.rules = ($base + (.route.rules | map(select(. != $base[0] and . != $base[1] and . != $base[2] and . != $base[3] and . != {protocol: "tcp", action: "sniff"}))))
    ' "$src" > "$_tmp" 2>/dev/null; then rm -f -- "$_tmp"; return 1; fi
    # R27b-M2: a stripped-to-empty input makes jq emit nothing with rc
    # 0, and `jq empty` also passes on an empty file: refuse an empty
    # transform output instead of installing an empty config (same fix
    # as xray_ensure_stats).
    [[ -s "$_tmp" ]] || { rm -f -- "$_tmp"; return 1; }
    jq empty "$_tmp" >/dev/null 2>&1 || { rm -f -- "$_tmp"; return 1; }
    chmod 600 "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    mv -f -- "$_tmp" "$src" || { rm -f -- "$_tmp"; return 1; }
}

# H-07: enforce the loopback guard on an Xray config file in place.
# Ensures .routing.rules carries {type:"field", ip:["127.0.0.0/8",
# "::1/128"], outboundTag:"block"} and .outbounds carries a blackhole
# outbound tagged "block" (idempotent: no-op when both already
# present in the canonical order). Standalone configs have no api
# inbound, so the rule is a pure IP block (unlike the main stack,
# whose first rule lets the api inbound through). Refuses non-object
# configs and non-array routing.rules/outbounds. The input file is
# never modified on failure.
xray_apply_loopback_guard() {
    local src="$1" _tmp _dir
    [[ -f "$src" && ! -L "$src" ]] || return 1
    _dir=$(dirname -- "$src") || return 1
    _tmp=$(mktemp "$_dir/.A-Box-xray-guard.XXXXXX") || return 1
    if ! jq '
        {type: "field", ip: ["127.0.0.0/8", "::1/128"], outboundTag: "block"} as $rule
        | {protocol: "blackhole", tag: "block"} as $blk
        | if type != "object" then error("xray config must be an object") else . end
        | if .routing == null then .routing = {} elif (.routing | type) != "object" then error("xray routing must be an object") else . end
        | if .routing.rules == null then .routing.rules = [] elif (.routing.rules | type) != "array" then error("xray routing.rules must be an array") else . end
        | if .outbounds == null then .outbounds = [] elif (.outbounds | type) != "array" then error("xray outbounds must be an array") else . end
        # R27b-H1/M1: the old existence-only logic (prepend the rule
        # when absent, add a blackhole when no "block" tag exists) did
        # not enforce the guard: a rule AFTER a direct allow rule never
        # matches first, and a freedom outbound tagged "block" forwards
        # loopback traffic. Normalise like xray_ensure_stats: the
        # block outbound must be a unique blackhole (else error), and
        # the guard sits first -- or second, after the canonical API
        # control rule when one exists (a legacy dokodemo-door API
        # inbound routes 127.0.0.1 through it; prepending the guard
        # ahead of it blackholes the API itself after restart).
        | (.api.tag // "api") as $t
        | {type: "field", inboundTag: [$t], outboundTag: $t} as $control
        | if $t == "block" then error("Xray API tag conflicts with the loopback block tag") else . end
        | [.outbounds[]? | select(.tag == "block")] as $blocks
        | if ($blocks | length) == 0 then .outbounds += [$blk]
          elif (($blocks | length) == 1 and $blocks[0].protocol == "blackhole") then .
          else error("Xray outbound tag block is not a unique blackhole outbound") end
        | (.api.listen == null) as $legacy_api
        | (if $legacy_api then ([.routing.rules[]? | select(. == $control)] | length) > 0 else false end) as $has_control
        | .routing.rules = (
              (if $has_control then [$control, $rule] else [$rule] end)
              + (.routing.rules | map(select(. != $rule and (if $has_control then . != $control else true end))))
          )
    ' "$src" > "$_tmp" 2>/dev/null; then rm -f -- "$_tmp"; return 1; fi
    # R27b-M2: a stripped-to-empty input makes jq emit nothing with rc
    # 0, and `jq empty` also passes on an empty file: refuse an empty
    # transform output instead of installing an empty config (same fix
    # as xray_ensure_stats).
    [[ -s "$_tmp" ]] || { rm -f -- "$_tmp"; return 1; }
    jq empty "$_tmp" >/dev/null 2>&1 || { rm -f -- "$_tmp"; return 1; }
    chmod 600 "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    mv -f -- "$_tmp" "$src" || { rm -f -- "$_tmp"; return 1; }
}

build_singbox_config() {
    local mode="$1" inbounds_json ka_obj cert_cn='localhost' out="${2:-/etc/sing-box/config.json}" tmp_out listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    [[ -n "${HY2_DOMAIN:-}" ]] && cert_cn="$HY2_DOMAIN"
    if [[ "${ENABLE_KEEPALIVE:-}" == true ]]; then ka_obj='{"tcp_keep_alive":"45s","tcp_keep_alive_interval":"45s"}'; else ka_obj='{}'; fi
    # HY2_UP/HY2_DOWN are client-facing rates. On the server endpoint,
    # server up == client download and server down == client upload, so the
    # values intentionally map to up_mbps=HY2_DOWN and down_mbps=HY2_UP.
    inbounds_json=$(jq -n \
        --arg mode "$mode" --rawfile uuid <(printf '%s' "${UUID:-}") --arg listen_addr "$listen_addr" \
        --arg v_sni "${VISION_SNI:-${VLESS_SNI:-${ABOX_AUTO_SNI_SELECTED:-}}}" \
        --arg x_sni "${XHTTP_SNI:-${VLESS_SNI:-${ABOX_AUTO_SNI_SELECTED:-}}}" \
        --rawfile pk <(printf '%s' "${PK:-}") --rawfile sid <(printf '%s' "${SHORT_ID:-}") \
        --argjson vport "${VLESS_PORT:-443}" --argjson hy2port "${HY2_BASE_PORT:-443}" --argjson ssport "${SS_PORT:-2053}" \
        --argjson hy2up "${HY2_DOWN:-1000}" --argjson hy2down "${HY2_UP:-100}" \
        --rawfile hy2pass <(printf '%s' "${HY2_PASS:-}") --rawfile hy2obfs <(printf '%s' "${HY2_OBFS:-}") --arg cert_cn "$cert_cn" \
        --arg masq "${HY2_MASQ_URL:-https://www.samsung.com/}" --rawfile ss_pass <(printf '%s' "${SS_PASS:-}") --argjson ka "$ka_obj" '
        def vision($tag):
          ({tag:$tag, type:"vless", listen:$listen_addr, listen_port:$vport, tcp_fast_open:true,
            users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
            tls:{enabled:true, server_name:$v_sni, reality:{enabled:true, handshake:{server:$v_sni, server_port:443}, private_key:$pk, short_id:[$sid]}}} + $ka);
        def hy2($tag):
          {tag:$tag, type:"hysteria2", listen:$listen_addr, listen_port:$hy2port, up_mbps:$hy2up, down_mbps:$hy2down,
            obfs:{type:"salamander", password:$hy2obfs}, users:[{password:$hy2pass}],
            tls:{enabled:true, server_name:$cert_cn, alpn:["h3"], certificate_path:"/etc/sing-box/hy2.crt", key_path:"/etc/sing-box/hy2.key"}, masquerade:$masq};
        def ss($tag):
          ({tag:$tag, type:"shadowsocks", listen:$listen_addr, listen_port:$ssport, tcp_fast_open:true,
            method:"2022-blake3-aes-128-gcm", password:$ss_pass} + $ka);
        []
        | if ($mode|contains("VISION")) or ($mode|contains("ALL")) or $mode == "VLESS_SS" then . + [vision("vision")] else . end
        | if ($mode|contains("HY2")) or ($mode|contains("ALL")) then . + [hy2("hy2")] else . end
        | if ($mode|contains("SS")) or ($mode|contains("ALL")) or $mode == "VLESS_SS" then . + [ss("ss")] else . end') || die "$(tr_msg bs2_inbounds)"
    local out_dir
    out_dir=$(dirname -- "$out")
    [[ ! -L "$out_dir" && ! -L "$out" ]] || die "$(tr_msg bs2_symlink)"
    [[ ! -e "$out_dir" || -d "$out_dir" ]] || die "$(tr_msg bs2_parent)"
    # R9C8-01: $out itself must be a regular file (or absent).
    # Without this, mv installs the generated config INSIDE a
    # pre-existing directory and still reports success.
    [[ ! -e "$out" || -f "$out" ]] || die "Refusing to install build_singbox_config config: output path exists and is not a regular file: $out"
    if [[ "$out" == /etc/sing-box/config.json ]]; then
        prepare_abox_runtime_config_dir sing-box /etc/sing-box || die "$(tr_msg bs2_cfgdir)"
    else
        [[ -d "$out_dir" ]] || install -d -m 755 -- "$out_dir" || die "$(tr_msg bs2_dir)"
    fi
    tmp_out=$(mktemp "$out_dir/.A-Box-singbox-config.XXXXXX") || die "$(tr_msg bs2_tmp)"
    # H-09: save/restore the caller umask (bare umask 077 leaked).
    local _bs_umask
    _bs_umask=$(umask)
    umask 077
    # Merge routing state (WARP / split-routing outbounds + rules); survives redeploys.
    local _rs_ob='[]' _rs_rules='[]'
    if [[ -L "$ROUTING_STATE_FILE" ]]; then
        die 'Routing state file is a symbolic link; refusing to deploy without routing policy.'
    fi
    # R15-F08-03: a path that exists but is not a regular file
    # (directory / FIFO / socket) is damage, not absence: fail
    # closed like a symlink or invalid content instead of
    # silently deploying with an empty routing set.
    if [[ -e "$ROUTING_STATE_FILE" && ! -f "$ROUTING_STATE_FILE" && ! -L "$ROUTING_STATE_FILE" ]]; then
        die 'Routing state path exists but is not a regular file; refusing to deploy without routing policy.'
    fi
    if [[ -f "$ROUTING_STATE_FILE" && ! -L "$ROUTING_STATE_FILE" ]]; then
        jq -e '.version == 1 and (.outbounds | type == "array") and (.rules | type == "array")' "$ROUTING_STATE_FILE" >/dev/null 2>&1 || die 'Routing state file is invalid; refusing to deploy without routing policy.'
        _rs_ob=$(jq -c '[.outbounds[]?.singbox
            | if (.type == "wireguard" and has("server")) then
                ((.pre_shared_key // null) as $psk
                 | {type:"wireguard", tag:.tag, address:.local_address, private_key:.private_key,
                    mtu:(.mtu // 1280),
                    peers:[({address:.server, port:.server_port, public_key:.peer_public_key,
                        persistent_keepalive_interval:(.keepalive // 25),
                        allowed_ips:["0.0.0.0/0","::/0"]}
                       + (if ($psk | type == "string" and . != "") then {pre_shared_key:$psk} else {} end))]})
              else . end]' "$ROUTING_STATE_FILE" 2>/dev/null) || die 'Routing state outbound merge failed.'
        _rs_rules=$(jq -c '[.rules[]?.singbox_rule
            | if has("geosite") then
                (.rule_set = (((.rule_set) // []) + (.geosite | map("geosite-" + .))) | del(.geosite))
              else . end]' "$ROUTING_STATE_FILE" 2>/dev/null) || die 'Routing state rule merge failed.'
    fi
    jq -n --slurpfile inbounds <(printf '%s' "$inbounds_json") --slurpfile rs_ob <(printf '%s' "$_rs_ob") --slurpfile rs_rules <(printf '%s' "$_rs_rules") '
        ($rs_ob[0] | map(select(.type == "wireguard"))) as $eps
        | ($rs_ob[0] | map(select(.type != "wireguard"))) as $obs
        | ($rs_rules[0] | map(.rule_set[]?) | unique) as $tags
        | {
        log:{level:"warn", timestamp:true, output:"/var/log/A-Box-singbox.log"},
        route: ({rules: (([{network:["tcp"], action:"sniff"},{action:"resolve"},{ip_cidr:["127.0.0.0/8","::1/128"], action:"reject"},{protocol:"bittorrent", action:"reject"}] + $rs_rules[0])), auto_detect_interface:true}
            + (if ($tags | length) > 0 then {rule_set: ($tags | map({type:"remote", tag:., format:"binary",
                url:("https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/" + . + ".srs"),
                http_client:"abox-dl"}))} else {} end)),
        inbounds:$inbounds[0],
        outbounds: ([{type:"direct", tag:"direct"}] + $obs)
    } + (if ($eps | length) > 0 then {endpoints:$eps} else {} end) + (if ($tags | length) > 0 then {http_clients:[{tag:"abox-dl"}]} else {} end)' > "$tmp_out" || { rm -f "$tmp_out"; die "$(tr_msg bs2_json)"; }
    chmod 600 "$tmp_out" || { rm -f "$tmp_out"; die "$(tr_msg bs2_chmod)"; }
    [[ $EUID -eq 0 ]] && chown root:root "$tmp_out" || true
    [[ -d "$out" ]] && { rm -f "$tmp_out"; die "$(tr_msg bs2_commit)"; }
    mv -f -- "$tmp_out" "$out" || { rm -f "$tmp_out"; die "$(tr_msg bs2_commit)"; }
    umask "$_bs_umask"
}

# Restore one file from backup and verify the result. $1=bak (may be
# empty), $2=dest. Empty bak means dest was newly created: remove it.
# Returns 0 only when the post-state is verified (byte-identical copy
# when cmp exists, else cp success + non-empty dest).
restore_file_or_remove() {
    local bak="${1:-}" dest="$2"
    if [[ -n "$bak" ]]; then
        cp -a -- "$bak" "$dest" || return 1
        if command -v cmp >/dev/null 2>&1; then
            cmp -s -- "$bak" "$dest" || return 1
        else
            [[ -s "$dest" ]] || return 1
        fi
    else
        rm -f -- "$dest" || return 1
        [[ ! -e "$dest" ]] || return 1
    fi
}

# Restore a file from its pre-commit backup. $1=bak, $2=dest.
# Returns 1 if the backup path is empty, does not name a regular file,
# or the copy fails; returns 0 once the copy succeeds.
# No stdout output. Backup removal is best-effort; a cleanup failure
# is reported on stderr and does not change the copy-success status.
# If cleanup fails, a later rollback using the same backup can restore
# stale data.
restore_cfg_backup() {
    local bak="${1:-}" dest="$2"
    [[ -n "$bak" && -f "$bak" ]] || return 1
    cp -f -- "$bak" "$dest" 2>/dev/null || return 1
    if ! rm -f -- "$bak" 2>/dev/null; then
        msg "${RED}[!] $(tr_msg rollback_cleanup_fail)${NC}" >&2 || true
    fi
    return 0
}

# Restore a TUIC deploy's pre-commit backups: the old cert pair (from
# sibling .A-Box-bak files, when present) and the old config (when a
# cfg backup was taken). Silent per file; prints the rollback failure
# note once when any restore fails. Returns 0 only if every attempted
# restore succeeded.
restore_tuic_backups() {
    local key="$1" crt="$2" cfg_bak="${3:-}" cfg="$4" rc=0
    # 3B-U16: same best-effort cleanup semantics as restore_cfg_backup
    # (P1 Q3d): a copy success with a backup-cleanup failure only warns
    # (rollback_cleanup_fail) and keeps rc=0; only a copy failure is a
    # rollback failure (rollback_copy_fail below).
    if [[ -f "${key}.A-Box-bak" ]]; then
        restore_cfg_backup "${key}.A-Box-bak" "$key" || rc=1
    fi
    if [[ -f "${crt}.A-Box-bak" ]]; then
        restore_cfg_backup "${crt}.A-Box-bak" "$crt" || rc=1
    fi
    if [[ -n "$cfg_bak" ]]; then
        restore_cfg_backup "$cfg_bak" "$cfg" || rc=1
    fi
    if (( rc )); then
        msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}" >&2
        return 1
    fi
    # H-2 (Gemini) dim 2: a restored TUIC key/cert comes back with the
    # backup's 0600 mode (cp -f keeps the destination inode's mode, and
    # the backup itself was chmod 600), but sing-box runs as
    # abox-singbox and needs 0640 root:abox-singbox. Re-apply the runtime
    # permissions now; a failure here is explicit (the rollback itself
    # succeeded, so the message must not claim a copy failure) and
    # refuses, so the caller never restarts a service that is about to
    # fail with permission denied.
    if ! prepare_abox_runtime_permissions sing-box; then
        msg "${RED}[!] $(tr_msg rollback_perm_fail)${NC}" >&2
        return 1
    fi
    return 0
}

# H-2 (Gemini) dim 3: remove stale tuic-*.A-Box-bak files that no live
# inbound references (via .tls.certificate_path / .tls.key_path in $1).
# A stale backup otherwise drifts the recorded core-family ownership
# list and makes a later removal fail closed. $2 overrides the cert
# directory (default /etc/sing-box; the self-test passes a temp dir).
# Best-effort and fail-closed: an unreadable config keeps every backup.
_tuic_cleanup_stale_backups() {
    local cfg="$1" dir="${2:-/etc/sing-box}" bak base _stripped='' _refs=''
    # Fail-closed: a config that cannot be stripped at all keeps every
    # backup. An empty jq result must mean "no references", never "the
    # read failed" -- jq exits 0 on empty input, so the strip status
    # is checked separately first.
    _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || return 0
    if ! _refs=$(printf '%s' "$_stripped" | jq -r '.inbounds[]? | (.tls.certificate_path // empty), (.tls.key_path // empty)' 2>/dev/null); then
        return 0
    fi
    for bak in "$dir"/tuic-*.A-Box-bak; do
        [[ -e "$bak" || -L "$bak" ]] || continue
        base="${bak%.A-Box-bak}"
        grep -Fxq -- "$base" <<< "$_refs" || rm -f -- "$bak" 2>/dev/null || true
    done
    return 0
}

generate_self_signed_cert_atomically() {
    local key="$1" cert="$2" cn="$3" extra_host="${4:-}" dir tmp key_tmp cert_tmp cnf san_list pub1 pub2 key_bak='' cert_bak='' _cert_rb_fail=0
    dir=$(dirname "$key")
    [[ "$dir" == "$(dirname "$cert")" ]] || return 1
    path_parent_chain_safe "$key" || return 1
    path_parent_chain_safe "$cert" || return 1
    case "$dir" in
        /etc/sing-box)
            prepare_abox_runtime_config_dir sing-box /etc/sing-box || return 1
            ;;
        /etc/hysteria)
            prepare_abox_runtime_config_dir hysteria /etc/hysteria || return 1
            ;;
        *)
            install -d -m 700 "$dir" || return 1
            ;;
    esac
    [[ ! -L "$key" && ! -L "$cert" ]] || return 1
    [[ ! -e "$key" || -f "$key" ]] || return 1
    [[ ! -e "$cert" || -f "$cert" ]] || return 1
    tmp=$(mktemp -d "$dir/.A-Box-cert.XXXXXX") || return 1
    key_tmp="$tmp/key.pem"; cert_tmp="$tmp/cert.pem"
    openssl ecparam -genkey -name prime256v1 -out "$key_tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    # SYD-B2 E15: always emit SANs (see header comment). Built via a
    # config file, not -addext, so it works on OpenSSL and LibreSSL.
    san_list="DNS:localhost,IP:127.0.0.1"
    if [[ "$cn" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        [[ "$cn" != '127.0.0.1' ]] && san_list="${san_list},IP:${cn}"
    elif [[ "$cn" != 'localhost' ]]; then
        san_list="${san_list},DNS:${cn}"
    fi
    if [[ "$extra_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        case ",${san_list}," in *"IP:${extra_host},"*) ;; *) san_list="${san_list},IP:${extra_host}" ;; esac
    elif [[ "$extra_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        case ",${san_list}," in *"DNS:${extra_host},"*) ;; *) san_list="${san_list},DNS:${extra_host}" ;; esac
    fi
    cnf="$tmp/openssl.cnf"
    { printf '[req]\n'; printf 'distinguished_name = dn\n'; printf 'x509_extensions = v3_req\n'; printf 'prompt = no\n'; printf '[dn]\n'; printf '[v3_req]\n'; printf 'subjectAltName = %s\n' "$san_list"; } > "$cnf" || { rm -rf "$tmp"; return 1; }
    openssl req -new -x509 -days 3650 -key "$key_tmp" -out "$cert_tmp" -subj "/CN=${cn}" -config "$cnf" -extensions v3_req >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    openssl x509 -in "$cert_tmp" -noout >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    pub1=$(openssl pkey -in "$key_tmp" -pubout -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
    pub2=$(openssl x509 -in "$cert_tmp" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
    [[ -n "$pub1" && "$pub1" == "$pub2" ]] || { rm -rf "$tmp"; return 1; }
    chmod 600 "$key_tmp" "$cert_tmp" || { rm -rf "$tmp"; return 1; }

    if [[ -e "$key" ]]; then key_bak="$tmp/key.old"; cp -a -- "$key" "$key_bak" || { rm -rf "$tmp"; return 1; }; fi
    if [[ -e "$cert" ]]; then cert_bak="$tmp/cert.old"; cp -a -- "$cert" "$cert_bak" || { rm -rf "$tmp"; return 1; }; fi
    mv -f -- "$key_tmp" "$key" || { rm -rf "$tmp"; return 1; }
    if ! mv -f -- "$cert_tmp" "$cert"; then
        _cert_rb_fail=0
        restore_file_or_remove "$key_bak" "$key" || _cert_rb_fail=1
        restore_file_or_remove "$cert_bak" "$cert" || _cert_rb_fail=1
        if (( _cert_rb_fail )); then
            msg "[!] Certificate rollback incomplete; old key/cert backups kept in ${tmp} (key.old/cert.old). Restore them manually." >&2
        else
            rm -rf "$tmp"
        fi
        return 1
    fi
    chmod 600 "$key" "$cert" || {
        _cert_rb_fail=0
        restore_file_or_remove "$key_bak" "$key" || _cert_rb_fail=1
        restore_file_or_remove "$cert_bak" "$cert" || _cert_rb_fail=1
        if (( _cert_rb_fail )); then
            msg "[!] Certificate rollback incomplete; old key/cert backups kept in ${tmp} (key.old/cert.old). Restore them manually." >&2
        else
            rm -rf "$tmp"
        fi
        return 1
    }
    rm -rf "$tmp"
}

build_hysteria_config() {
    local out="$1" tls_config="$2" listen_spec="$3" tmp pass_yaml obfs_yaml masq_yaml out_dir
    [[ -n "$out" && -n "$listen_spec" ]] || return 1
    [[ "$out" == /etc/hysteria/config.yaml ]] || return 1
    path_parent_chain_safe "$out" || return 1
    out_dir=$(dirname "$out")
    [[ "$out_dir" == /etc/hysteria ]] || return 1
    [[ ! -L "$out_dir" && ! -L "$out" ]] || return 1
    prepare_abox_runtime_config_dir hysteria "$out_dir" || return 1
    pass_yaml=$(json_escape "$HY2_PASS") || return 1
    obfs_yaml=$(json_escape "$HY2_OBFS") || return 1
    masq_yaml=$(json_escape "$HY2_MASQ_URL") || return 1
    tmp=$(mktemp "${out}.tmp.XXXXXX") || return 1
    cat > "$tmp" <<EOF_HY2
listen: ${listen_spec}
${tls_config}
obfs:
  type: salamander
  salamander:
    password: ${obfs_yaml}
auth:
  type: password
  password: ${pass_yaml}
# Server up = server -> client (client download); server down = client -> server (client upload).
bandwidth:
  up: ${HY2_DOWN} mbps
  down: ${HY2_UP} mbps
masquerade:
  type: proxy
  proxy:
    url: ${masq_yaml}
    rewriteHost: true
EOF_HY2
    [[ $? -eq 0 ]] || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    [[ ! -L "$out" && ( ! -e "$out" || -f "$out" ) ]] || {
        rm -f -- "$tmp"
        return 1
    }

    mv -f -- "$tmp" "$out" || {
        rm -f -- "$tmp"
        return 1
    }

    [[ -s "$out" && -f "$out" && ! -L "$out" ]]
}

# R3C8-03: official HY2 port hopping runs as abox-hysteria with
# CAP_NET_ADMIN only. When nft is missing, Hysteria falls back to
# iptables-legacy, which must open /run/xtables.lock; a pre-existing
# root:root 0600 lock is unopenable by the service user (CAP_NET_ADMIN
# does not bypass file permissions), so the hop rules are never built.
# Grant the service group narrow access now, and persist it across
# reboots via tmpfiles.d (systemd only; /run is tmpfs). No-op when
# nft exists (the fallback is never used). No world access is added.
hy2_hop_xtables_lock_grant() {
    command -v nft >/dev/null 2>&1 && return 0
    local lock
    for lock in /run/xtables.lock /var/run/xtables.lock; do
        if [[ ! -e "$lock" && ! -L "$lock" ]]; then
            (umask 077; set -C; : > "$lock") 2>/dev/null || {
                [[ -f "$lock" && ! -L "$lock" ]] || return 1
            }
        fi
        [[ -f "$lock" && ! -L "$lock" ]] || return 1
        chown root:abox-hysteria "$lock" 2>/dev/null || return 1
        chmod 0660 "$lock" 2>/dev/null || return 1
    done
    if is_systemd; then
        mkdir -p /etc/tmpfiles.d || return 1
        write_file_atomically_from_stdin /etc/tmpfiles.d/abox-xtables-lock.conf 644 <<'EOF_XTABLES_TMPFILES' || return 1
# Managed by A-Box
# A-Box: official HY2 port hopping (nft missing, iptables-legacy
# fallback) needs the abox-hysteria service user to open the xtables
# lock. Narrow: group access only, no world access. /run is tmpfs, so
# this entry recreates the lock with these permissions at every boot.
f /run/xtables.lock 0660 root abox-hysteria - -
EOF_XTABLES_TMPFILES
    fi
    return 0
}

# 2fv: the xtables-lock grant as a standalone script, run at every
# hysteria service start (systemd ExecStartPre, OpenRC start_pre).
# tmpfiles.d persists the grant across reboots on systemd only; on
# OpenRC /run is tmpfs and the lock is recreated root:root 0600, so
# the grant must be re-applied when the service starts. The script is
# strict (non-zero on failure); service-start callers treat it as
# best-effort (ExecStartPre=-, start_pre || true) — the deploy-time
# grant in hy2_hop_xtables_lock_grant is the real gate.
write_hy2_xtables_lock_grant_script() {
    write_file_atomically_from_stdin /usr/local/bin/abox-hy2-xtables-lock-grant 755 <<'EOF_XTABLES_GRANT' || return 1
#!/bin/sh
# Managed by A-Box
# A-Box: grant the abox-hysteria group access to the xtables lock.
# Official HY2 port hopping runs as abox-hysteria with CAP_NET_ADMIN
# only; when nft is missing, Hysteria falls back to iptables-legacy,
# which must open /run/xtables.lock. A pre-existing root:root 0600
# lock is unopenable by the service user, so the hop rules are never
# built. This script is run at every hysteria service start so the
# grant survives reboots on init systems without tmpfiles.d (OpenRC:
# /run is tmpfs, the lock is recreated root:root 0600 at boot).
# No-op when nft exists (the fallback is never used). Narrow: group
# access only, no world access. Exits non-zero on failure; callers at
# service start treat it as best-effort.
command -v nft >/dev/null 2>&1 && exit 0
for lock in ${ABOX_XTABLES_LOCK_PATHS:-/run/xtables.lock /var/run/xtables.lock}; do
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
        (umask 077; set -C; : > "$lock") 2>/dev/null || {
            [ -f "$lock" ] && [ ! -L "$lock" ] || exit 1
        }
    fi
    [ -f "$lock" ] && [ ! -L "$lock" ] || exit 1
    chown root:abox-hysteria "$lock" || exit 1
    chmod 0660 "$lock" || exit 1
done
exit 0
EOF_XTABLES_GRANT
}

# S2-NEW-06: reconcile the running Hysteria with the config the
# post-deploy registry reconcile may have rewritten under it.
# $1 = sha256 of the config captured BEFORE
# users_reg_reconcile_after_deploy ran; $2 =
# optional config path (default /etc/hysteria/config.yaml).
# Returns 0 when the running process already serves the on-disk
# config. When the reconcile rewrote the config without restarting
# the service, restarts it and verifies the restart landed on the
# current disk config. Any failure returns 1: a deploy that ends
# with a stale Hysteria must fail loudly, never report success.
# Why a restart can be missing at all: users_commit_cfg restarts
# only when service_restart_permitted, which requires desired ==
# RUNNING -- and a SILENT sub-deploy (four-in-one, deploy_xray ALL)
# has not set RUNNING yet when its reconcile runs (the caller sets
# it only after this function returns), so with a pre-redeploy
# desired state of MANUAL_STOPPED the rewrite lands on disk while
# the process keeps the pre-reconcile single-password config and
# every Hy2 chain 404s until a manual restart.
hy2_resync_running_config() {
    local pre_sha="$1" cfg="${2:-/etc/hysteria/config.yaml}"
    local post_sha='' post_pid='' restart_sha=''
    [[ -n "$pre_sha" ]] || { msg "S2-NEW-06: cannot verify Hysteria running config (pre-reconcile checksum unreadable)." >&2; return 1; }
    post_sha=$(sha256sum -- "$cfg" 2>/dev/null | awk '{print $1}') || post_sha=''
    [[ -n "$post_sha" ]] || { msg "S2-NEW-06: cannot verify Hysteria running config (config unreadable after reconcile)." >&2; return 1; }
    # 04c2-M2: an unchanged checksum proves nothing about liveness: the
    # service may have died after it started (reconcile rewrote nothing,
    # so this branch is exactly the one a dead-after-start service takes).
    # Verify the PID before reporting a successful deploy; the caller
    # treats this function as the fail-closed deploy gate.
    if [[ "$post_sha" == "$pre_sha" ]]; then
        post_pid=$(managed_service_pid hysteria 2>/dev/null || true)
        if [[ -z "$post_pid" ]]; then
            msg "S2-NEW-06: Hysteria config unchanged but the service is not running; refusing to report a successful deploy." >&2
            return 1
        fi
        return 0
    fi
    # The reconcile rewrote the config after the service started.
    post_pid=$(managed_service_pid hysteria 2>/dev/null || true)
    if [[ -z "$post_pid" ]]; then
        msg "S2-NEW-06: Hysteria config changed after start but the service is not running; refusing to report a successful deploy." >&2
        return 1
    fi
    # R28-M1: a changed PID is NOT proof the running process loaded
    # the new config, so there is no shortcut here. A PID change only
    # proves the process is different, not that it started AFTER the
    # rewrite: with Restart=always + RestartSec=10, an auto-restart
    # (crash) landing before the rewrite yields a new PID serving the
    # OLD config, yet the old shortcut returned 0. (users_commit_cfg's
    # restart predates the pre-reconcile capture, so it cannot cause
    # the PID change this shortcut relied on.) Always restart onto the
    # rewritten config and verify below.
    if ! restart_service_soft hysteria; then
        msg "S2-NEW-06: Hysteria config changed after start and the restart onto the new config failed; the running service still serves the pre-reconcile config." >&2
        return 1
    fi
    restart_sha=$(sha256sum -- "$cfg" 2>/dev/null | awk '{print $1}') || restart_sha=''
    if [[ -z "$restart_sha" || "$restart_sha" != "$post_sha" ]]; then
        msg "S2-NEW-06: Hysteria config changed again during the resync restart; running state cannot be verified against disk." >&2
        return 1
    fi
    return 0
}

# M-18 (supplement): revoke the xtables-lock grant created by
# hy2_hop_xtables_lock_grant / write_hy2_xtables_lock_grant_script.
# Deletes the two A-Box grant artifacts and resets the lock file
# permissions to the iptables default (0600 root:root) — but only when
# the lock is provably our own grant: a regular file (never a symlink)
# whose group is abox-hysteria, or whose group GID is unnamed while we
# are removing A-Box's own grant artifacts. A lock owned by any other
# known group is left untouched. The lock file itself is never deleted
# (deleting a locked inode does not release flock). Callers must have
# stopped the hysteria service and deleted its unit first: the grant
# script runs as ExecStartPre, so a live unit could re-apply the grant
# after revoke. Returns non-zero on failure.
hy2_hop_xtables_lock_revoke() {
    local lock _first_inode='' _inode _gid _gname _reset _grant_existed=0
    # 04c2-M1: the unnamed-GID branch below is only valid while
    # removing A-Box's own grant artifacts, so record whether either
    # grant file existed BEFORE deleting them: rm -f succeeds on a
    # missing file and must never serve as proof of prior existence.
    [[ -e /usr/local/bin/abox-hy2-xtables-lock-grant || -L /usr/local/bin/abox-hy2-xtables-lock-grant ]] && _grant_existed=1
    [[ -e /etc/tmpfiles.d/abox-xtables-lock.conf || -L /etc/tmpfiles.d/abox-xtables-lock.conf ]] && _grant_existed=1
    for lock in /run/xtables.lock /var/run/xtables.lock; do
        [[ -e "$lock" || -L "$lock" ]] || continue
        [[ -f "$lock" && ! -L "$lock" ]] || continue
        _inode=$(stat -c '%d:%i' "$lock" 2>/dev/null) || return 1
        if [[ -n "$_first_inode" && "$_inode" == "$_first_inode" ]]; then continue; fi
        _first_inode="$_inode"
        _gid=$(stat -c %g "$lock" 2>/dev/null) || return 1
        _gname=$(stat -c %G "$lock" 2>/dev/null) || return 1
        _reset=0
        if [[ "$_gname" == abox-hysteria ]]; then
            _reset=1
        elif (( _grant_existed == 1 )) && ! getent group "$_gid" >/dev/null 2>&1; then
            # Unnamed GID while removing A-Box's own grant artifacts:
            # the group is gone (or never existed); reset to default.
            # With no grant file pre-existing, an unnamed GID proves
            # nothing about ownership (another program's lock, a
            # container GID) and the lock is left untouched.
            _reset=1
        fi
        if (( _reset == 1 )); then
            chown root:root "$lock" 2>/dev/null || return 1
            chmod 0600 "$lock" 2>/dev/null || return 1
        fi
    done
    # R28-M2: delete the grant artifacts only AFTER every lock is
    # confirmed reset. Deleting them first destroys the retry
    # evidence: if the reset above fails, a retry finds no grant
    # files (_grant_existed=0), the unnamed-GID branch no longer
    # applies, and the function returns 0 with the lock never reset.
    # A failed revoke now leaves the artifacts in place, so the retry
    # sees them again and can complete the reset.
    rm -f -- /usr/local/bin/abox-hy2-xtables-lock-grant /etc/tmpfiles.d/abox-xtables-lock.conf || return 1
    return 0
}

deploy_official_hy2() {
    local IS_SILENT=${1:-NORMAL} TLS_CONFIG HY2_LISTEN cert_cn HY2_CAPS='CAP_NET_BIND_SERVICE' hy2_tmp hy2_bin domain_yaml token_yaml SKIP_REPLACE_AND_PRUNE=${2:-0} _hy2_url='' _hy2_port=''
    if [[ "$IS_SILENT" != 'SILENT' ]]; then
        clear; msg "${BOLD}${GREEN}$(tr_msg deploy_official_hy2_title)${NC}"
        init_system_environment
        load_optional_abox_env_or_die
        light_preflight_check
        residue_takeover_plan hysteria || return 1
        assert_no_foreign_core_conflicts hysteria
        [[ "$SKIP_REPLACE_AND_PRUNE" == '1' ]] || confirm_deployment_replacement hysteria HY2
        begin_deployment_transaction 'official Hysteria 2 deployment' hysteria || return 1
        residue_takeover_clear || { deployment_transaction_rollback; return 1; }
        clean_nat_rules || die "$(tr_msg cl_nat)"
        clean_input_rules || die "$(tr_msg cl_input)"
        save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
        pre_install_setup hysteria HY2 || { deployment_transaction_rollback; return 1; }
        abox_fetch_guard_start "hysteria HY2"
        release_ports
        get_architecture
    fi

    hy2_tmp=$(abox_mktemp_exec_dir A-Box-hysteria) || die "$(tr_msg hy2b_tmp)"
    ABOX_DEPLOY_TX_TMP="$hy2_tmp"
    hy2_bin="$hy2_tmp/hysteria_core"
    abox_fetch_heartbeat
    clear_core_release_resolution HyNetworks/hysteria
    fetch_github_release HyNetworks/hysteria hysteria_core "$hy2_bin"
    abox_fetch_heartbeat
    chmod 755 "$hy2_bin" || die 'Hysteria staged binary chmod failed.'
    "$hy2_bin" version >/dev/null 2>&1 || die 'Hysteria staged binary execution check failed.'
    install_binary_atomically "$hy2_bin" /usr/local/bin/hysteria || die 'Hysteria binary atomic install failed.'
    rm -rf -- "$hy2_tmp"
    ABOX_DEPLOY_TX_TMP=''
    /usr/local/bin/hysteria version >/dev/null 2>&1 || die "$(tr_msg hy2b_exec)"
    abox_fetch_guard_stop

    HY2_PASS=$(rand_alnum 20) || die 'Hysteria 2 password generation failed.'
    HY2_OBFS=$(rand_alnum 16) || die 'Hysteria 2 obfuscation password generation failed.'

    if [[ -n "${HY2_DOMAIN:-}" ]]; then
        prepare_hysteria_acme_dir_ownership || die "$(tr_msg hy2b_acme)"
        if [[ "${HY2_ACME_TYPE:-http}" == 'dns' ]]; then
            [[ "${HY2_ACME_DNS_PROVIDER:-}" == 'cloudflare' ]] || die "$(tr_msg pi_acme_cf_only)"
            valid_single_line_secret "${HY2_ACME_DNS_CF_API_TOKEN:-}" 512 || die "$(tr_msg pi_acme_token_bad)"
            domain_yaml=$(json_escape "$HY2_DOMAIN")
            token_yaml=$(json_escape "$HY2_ACME_DNS_CF_API_TOKEN")
            TLS_CONFIG="acme:
  dir: /etc/hysteria/acme
  domains:
    - ${domain_yaml}
  email: $(json_escape "admin@${HY2_DOMAIN}")
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${token_yaml}"
        else
            domain_yaml=$(json_escape "$HY2_DOMAIN")
            TLS_CONFIG="acme:
  dir: /etc/hysteria/acme
  domains:
    - ${domain_yaml}
  email: $(json_escape "admin@${HY2_DOMAIN}")
  type: http
  http:
    altPort: 80"
        fi
        HY2_CERT_SHA256_FP=''
        HY2_CERT_PUBKEY_SHA256_B64=''
    else
        generate_self_signed_cert_atomically /etc/hysteria/server.key /etc/hysteria/server.crt localhost "${LINK_IP:-}" || die "$(tr_msg hy2b_cert)"
        HY2_CERT_SHA256_FP=$(pin_sha256_colon /etc/hysteria/server.crt | tr -d ':')
        HY2_CERT_PUBKEY_SHA256_B64=$(openssl x509 -in /etc/hysteria/server.crt -noout -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64 | tr -d '\n')
        TLS_CONFIG="tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key"
    fi

    if [[ "${HY2_HOP:-}" == 'true' ]]; then
        HY2_LISTEN=":${HY2_RANGE_START}-${HY2_RANGE_END}"
        # R-02: Hysteria NEEDS CAP_NET_ADMIN (sets up its own iptables REDIRECT for port hopping;
        # unlike sing-box, hysteria.service has NO ExecStartPre+ running as root).
        # A-02 removal was wrong for Hysteria; restored.
        HY2_CAPS='CAP_NET_ADMIN CAP_NET_BIND_SERVICE'
    else
        HY2_LISTEN=":${HY2_BASE_PORT}"
    fi
    HY2_RC_CAPS='^cap_net_bind_service'
    [[ "${HY2_HOP:-false}" == 'true' ]] && HY2_RC_CAPS='^cap_net_admin,^cap_net_bind_service'

    build_hysteria_config /etc/hysteria/config.yaml "$TLS_CONFIG" "$HY2_LISTEN" || die "$(tr_msg hy2b_cfg)"

    # 2fv: when official hop is enabled, write the standalone grant
    # script and reference it from the service units below, so the
    # xtables-lock grant is re-applied at every service start (the
    # tmpfiles.d entry only persists it on systemd; OpenRC recreates
    # the lock root:root 0600 at every boot).
    local _hy2_lock_grant_pre='' _hy2_lock_grant_start_pre=''
    if [[ "${HY2_HOP:-false}" == true && "${HY2_HOP_IMPL:-none}" == official ]]; then
        write_hy2_xtables_lock_grant_script || die "$(tprintf hy2b_hop_lock)"
        _hy2_lock_grant_pre='ExecStartPre=-+/usr/local/bin/abox-hy2-xtables-lock-grant'
        _hy2_lock_grant_start_pre='start_pre() { /usr/local/bin/abox-hy2-xtables-lock-grant || true; }'
    fi

    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin /etc/systemd/system/hysteria.service 644 <<EOF_SVC || die "$(tr_msg deploy_official_hy2_systemd_write_failed)"
# Managed by A-Box
[Unit]
Description=A-Box Hysteria 2 Service
After=network-online.target
Wants=network-online.target

[Service]
User=abox-hysteria
Group=abox-hysteria
CapabilityBoundingSet=${HY2_CAPS}
AmbientCapabilities=${HY2_CAPS}
UMask=0077
${_hy2_lock_grant_pre}
ExecStart=/bin/sh -c 'exec /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml >>/var/log/A-Box-hysteria.log 2>&1'
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
        path_parent_chain_safe /etc/conf.d/hysteria || die "$(tr_msg dp_orc_parent)"
        [[ ! -L /etc/conf.d && (! -e /etc/conf.d || -d /etc/conf.d) ]] || die "$(tr_msg dp_orc_dir_unsafe)"
        mkdir -p /etc/conf.d || die "$(tr_msg dp_orc_dir)"
        write_file_atomically_from_stdin /etc/conf.d/hysteria 644 <<'EOF_HY2_CONFD' || die "$(tr_msg deploy_official_hy2_confd_write_failed)"
rc_ulimit="-n 1048576"
EOF_HY2_CONFD
        write_file_atomically_from_stdin /etc/init.d/hysteria 755 <<EOF_SVC || die "$(tr_msg deploy_official_hy2_openrc_write_failed)"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Hysteria 2 Service"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
command_user="abox-hysteria:abox-hysteria"
capabilities="${HY2_RC_CAPS}"
umask=077
output_log="/var/log/A-Box-hysteria.log"
error_log="/var/log/A-Box-hysteria.log"
pidfile="/run/hysteria.pid"
${_hy2_lock_grant_start_pre}
depend() { need net; }
EOF_SVC
        chmod +x /etc/init.d/hysteria || die "$(tr_msg hy2b_chmod)"
    fi
    prepare_abox_runtime_permissions hysteria || die "$(tr_msg hy2b_runtime)"
    if [[ "${HY2_HOP:-false}" == true && "${HY2_HOP_IMPL:-none}" == official ]]; then
        hy2_hop_xtables_lock_grant || die "$(tprintf hy2b_hop_lock)"
    fi
    service_manager start hysteria
    if [[ "${HY2_HOP:-false}" == true && "${HY2_HOP_IMPL:-none}" == official ]]; then
        if ! hysteria_official_hop_firewall_ok "$HY2_RANGE_START" "$HY2_RANGE_END" "$HY2_MONITOR_PORT"; then
            msg "${YELLOW}[!] $(tr_msg depend_hy2_hop_rules_restart)${NC}"
            restart_service_soft hysteria >/dev/null 2>&1 || die "$(tr_msg hy2b_hop_restart)"
            sleep 1
            hysteria_official_hop_firewall_ok "$HY2_RANGE_START" "$HY2_RANGE_END" "$HY2_MONITOR_PORT" || die "$(tr_msg hy2b_hop_missing)"
        fi
    fi
    setup_active_defense
    setup_health_monitor
    # E19: register the standalone Hy2 link at deploy time, like
    # every other deployer does. Without this, hy2.link is never
    # generated and menu 12 / export show no Hy2 node. A failure
    # here is non-fatal (the link is best-effort at deploy; the
    # rebuild branch in rebuild_standalone_links regenerates it
    # on the next menu 12 visit).
    # R31-AX5: moved out of the IS_SILENT gate (was below, inside the
    # NORMAL-only tail). The SILENT sub-deploy in the four-in-one
    # recasts HY2_PASS/HY2_OBFS but skipped registration, so the
    # reprinted link kept the previous round's password while live
    # config used the new one; rebuild_standalone_links only fills a
    # missing file, so it never healed the stale one. This runs in
    # both modes, after service start + hop check, before the
    # NORMAL-only tail, so menu 4 keeps register-then-view order.
    _hy2_eff_pass=$(hy2_effective_password 2>/dev/null || printf '%s' "${HY2_PASS:-}")
    _hy2_eff_pass=${_hy2_eff_pass%__ABOX_TRAILING_NL_KEEP__}
    _hy2_url=$(hy2_standalone_url "$_hy2_eff_pass" "${HY2_OBFS:-}" "" 2>/dev/null || true)
    if [[ -n "$_hy2_url" ]]; then
        IFS=$'\t' read -r _hy2_port _ < <(build_hy2_uri_endpoint 2>/dev/null || true)
        [[ -n "$_hy2_port" ]] && register_standalone_link "${ABOX_DEPLOY_STEM:-hy2}" "$(tprintf sl_node_port 'Hysteria 2' "$_hy2_port")" "$_hy2_url"
    fi
    if [[ "$IS_SILENT" != 'SILENT' ]]; then
        write_env hysteria HY2
        set_desired_state RUNNING || die "$(tr_msg hy2b_desired)"
        [[ "$SKIP_REPLACE_AND_PRUNE" == '1' ]] || prune_owned_core_families_except hysteria
        setup_geo_cron
        commit_deployment_transaction
        # R27-H-NF-06 (M-6): same post-deployment snapshot as the
        # xray and sing-box deployers (NORMAL mode only: a SILENT
        # sub-deploy commits nothing here). Best-effort: warns,
        # never fails the deploy.
        auto_backup_silent "post-deployment snapshot: hysteria2 HY2" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
        # S2-NEW-03: refresh the subscription export so the deployed node
        # set is what subscribers see; without this the files keep serving
        # dead links until menu E. Best-effort (see helper): the deploy
        # already committed, so an export failure warns but must not fail it.
        refresh_subscription_after_deploy || true
        view_config deploy
    fi
    # S2-NEW-04: reconcile the hy2 registry like the xray/sing-box
    # deployers do (OBS-S1-08 pattern): an overwrite redeploy writes a
    # fresh password-mode config, and without this the registry keeps
    # stale credentials until a menu visit -- where the merge used to
    # duplicate main as main-2. Best-effort: the deploy already
    # committed, so a failure warns but must not fail it.
    # S2-NEW-06: capture the config sha before the
    # reconcile so the resync below can tell whether the reconcile
    # rewrote the config under the running service without
    # restarting it. (No PID is captured: R28-M1 -- a changed PID
    # does not prove the process started after the rewrite.)
    local _hy2_recon_cfg_sha=''
    _hy2_recon_cfg_sha=$(sha256sum -- /etc/hysteria/config.yaml 2>/dev/null | awk '{print $1}') || _hy2_recon_cfg_sha=''
    users_reg_reconcile_after_deploy hy2 || msg "S2-NEW-04: user registry reconcile after deploy failed; issued links may carry pre-redeploy credentials until the next user-management visit." >&2
    # S2-NEW-06: if the reconcile rewrote the config after the
    # service started (preserved multi-user restore switches auth
    # password -> userpass on disk) and nothing restarted the service
    # onto it, restart now and verify -- otherwise the deploy ends
    # with every Hy2 chain 404ing until a manual restart. Fail
    # closed: in SILENT mode the caller turns this into a deploy
    # failure (and transaction rollback); in NORMAL mode the menu
    # reports the failure instead of a false success.
    hy2_resync_running_config "$_hy2_recon_cfg_sha" || return 1
}

install_file_atomically() {
    local src="$1" dest="$2" mode="${3:-600}" staged dir
    [[ -f "$src" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
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
    [[ -d "$dir" ]] || install -d -m 755 "$dir" || return 1
    staged=$(mktemp "${dest}.A-Box-new.XXXXXX") || return 1
    # M-14(2): on a setgid parent (Debian 10 /usr/local/bin is 2775
    # root:staff) mktemp inherits gid=staff and plain `install -m`
    # preserves it, so the installed file fails path_owned_by_root
    # (uid==0 && gid==0). As root, pin owner/group explicitly; as
    # non-root keep the old behaviour (`install -o/-g` would fail).
    if (( EUID == 0 )); then
        command install -o root -g root -m "$mode" "$src" "$staged" || { rm -f -- "$staged"; return 1; }
    else
        command install -m "$mode" "$src" "$staged" || { rm -f -- "$staged"; return 1; }
    fi
    # R7C8-01: before commit, a real staged-file sync failure must
    # fail the install. Unsupported sync options remain best-effort.
    _abox_sync_file "$staged" || { rm -f -- "$staged"; return 1; }
    mv -f -- "$staged" "$dest" || { rm -f -- "$staged"; return 1; }

    # R10-F08-5: the replacement is committed. Return 0 means installed,
    # not guaranteed crash durability of the directory entry.
    if ! _abox_sync_file "$dir"; then
        builtin printf \
            'A-Box: WARNING: target "%s" has been replaced, but parent directory "%s" sync failed; crash durability is not guaranteed.\n' \
            "$dest" "$dir" >&2 || :
    fi
    return 0
}

install_binary_atomically() { install_file_atomically "$1" "$2" 755; }

rollback_binary_install() {
    local bin="$1" backup="${2:-}"
    if [[ -n "$backup" && -f "$backup" ]]; then
        install_binary_atomically "$backup" "$bin"
    elif [[ -n "$backup" ]]; then
        # Backup was recorded but is gone: the current binary is the
        # only working copy left. Never delete it to fake a rollback.
        msg "[!] Rollback backup missing (${backup}); keeping current binary." >&2
        return 1
    else
        # First install: no backup ever existed. Removing the
        # just-installed destination IS the rollback, but report
        # failure (no backup restored) so callers never claim a
        # successful restore they did not perform.
        path_tree_has_mountpoint "$bin" && return 1
        rm -f -- "$bin"
        msg "[!] No rollback backup recorded; newly installed binary removed." >&2
        return 1
    fi
}

# Verified rollback for a core binary upgrade. Every step is checked; nothing
# is swallowed. On full success the tmp dir is cleaned and we die with the
# standard "rolled back" message. On ANY failure the tmp dir (with backups)
# is preserved and die reports exactly what failed plus manual recovery steps.
# Args: $1=service name, $2=binary path, $3=backup path (may be empty), $4=tmp dir,
#   $5=was_active (1/0, default 1). When was_active=0 the service is left stopped.
rollback_core_upgrade_verified() {
    local svc="$1" bin="$2" backup="${3:-}" tmp="${4:-}" was_active="${5:-1}"
    local rb_ok=0 rs_ok=0
    msg "${RED}[!] New ${svc} failed post-upgrade health checks. Rolling back binary...${NC}"
    if rollback_binary_install "$bin" "$backup" >/dev/null 2>&1; then
        rb_ok=1
    else
        msg "${RED}[!] Rollback binary restore FAILED for ${svc} (backup: ${backup:-none}).${NC}" >&2
    fi
    # X-06: do not start a service that was intentionally stopped (e.g.
    # MANUAL_STOPPED or TRAFFIC_BLOCKED); just restore the binary + ownership.
    if [[ "$was_active" == '0' ]]; then
        record_core_family_ownership "$svc" >/dev/null 2>&1 && rs_ok=1 || rs_ok=0
    elif restart_service_soft "$svc" >/dev/null 2>&1; then
        rs_ok=1
    else
        msg "${RED}[!] Service restart after rollback FAILED for ${svc}.${NC}" >&2
    fi
    if (( rb_ok == 1 && rs_ok == 1 )); then
        [[ -n "$tmp" ]] && rm -rf -- "$tmp"
        die "${svc} core upgrade rolled back because post-upgrade health checks failed."
    fi
    die "${svc} core upgrade ROLLBACK INCOMPLETE (binary_restore_ok=${rb_ok} service_restart_ok=${rs_ok}). Backup and logs preserved at: ${tmp:-unknown}. Manual recovery: restore '${backup:-none}' to '${bin}', then restart '${svc}'."
}

remove_core_family_force() {
    local srv="$1" path failed=0 core_paths=''
    local -a paths=()
    core_paths=$(core_family_paths "$srv") || return 1
    if [[ -n "$core_paths" ]]; then
        mapfile -t paths <<< "$core_paths" || return 1
    fi

    # Complete the safety preflight before deleting any sibling path. A mount
    # or symlink in one target must abort the whole forced cleanup rather than
    # leaving a partially removed core family before backup restoration.
    for path in "${paths[@]}"; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" || -L "$path" ]] || continue
        [[ ! -L "$path" ]] || { failed=1; continue; }
        path_tree_has_mountpoint "$path" && { failed=1; continue; }
    done
    (( failed == 0 )) || return 1

    for path in "${paths[@]}"; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" || -L "$path" ]] || continue
        rm -rf -- "$path" || failed=1
    done
    (( failed == 0 ))
}

restore_saved_trap() {
    local signal="$1" saved="$2"
    trap - "$signal"
    [[ -n "$saved" ]] && eval "$saved"
}

restore_deployment_transaction_traps() {
    restore_saved_trap EXIT "$ABOX_TX_PREV_TRAP_EXIT"
    restore_saved_trap INT "$ABOX_TX_PREV_TRAP_INT"
    restore_saved_trap TERM "$ABOX_TX_PREV_TRAP_TERM"
    restore_saved_trap HUP "$ABOX_TX_PREV_TRAP_HUP"
    ABOX_TX_PREV_TRAP_EXIT=''; ABOX_TX_PREV_TRAP_INT=''; ABOX_TX_PREV_TRAP_TERM=''; ABOX_TX_PREV_TRAP_HUP=''
}

deployment_transaction_signal_abort() {
    local signal="$1" code=1
    case "$signal" in INT) code=130 ;; HUP) code=129 ;; TERM) code=143 ;; esac
    deployment_transaction_rollback "signal ${signal}" || true
    exit "$code"
}

deployment_transaction_exit_abort() {
    local code=$? _tx_abort_old_exit="${ABOX_TX_PREV_TRAP_EXIT:-}" _tx_abort_old_cmd=''
    trap - EXIT
    if [[ "${ABOX_DEPLOY_TX_ACTIVE:-0}" == 1 ]]; then deployment_transaction_rollback "unexpected shell exit ${code}" || true; fi
    # The old EXIT handler must run explicitly: restoring it here and
    # then exiting does NOT re-trigger it (verified by experiment).
    # The saved string is trap -p output ("trap -- 'cmd' SIGNAL").
    # Strip the prefix and the trailing SIGNAL, then double-eval the
    # quoted command (first eval unquotes it, second executes it).
    # Without stripping, SIGNAL would become an extra argument to the
    # handler (an rm handler would delete a target named EXIT).
    if [[ -n "$_tx_abort_old_exit" ]]; then
        _tx_abort_old_cmd="${_tx_abort_old_exit#trap -- }"
        _tx_abort_old_cmd="${_tx_abort_old_cmd% *}"
        # Restore the original exit status for the old handler:
        # $? was clobbered to 0 by the commands above, so the
        # handler would otherwise see success on a failed exit.
        (exit "$code")
        eval "eval $_tx_abort_old_cmd" || true
    fi
    restore_deployment_transaction_traps
    exit "$code"
}

install_deployment_transaction_traps() {
    ABOX_TX_PREV_TRAP_EXIT=$(trap -p EXIT || true)
    ABOX_TX_PREV_TRAP_INT=$(trap -p INT || true)
    ABOX_TX_PREV_TRAP_TERM=$(trap -p TERM || true)
    ABOX_TX_PREV_TRAP_HUP=$(trap -p HUP || true)
    trap 'deployment_transaction_exit_abort' EXIT
    trap 'deployment_transaction_signal_abort INT' INT
    trap 'deployment_transaction_signal_abort TERM' TERM
    trap 'deployment_transaction_signal_abort HUP' HUP
}

cleanup_ephemeral_deployment_transaction_dir() {
    local dir="${ABOX_DEPLOY_TX_EPHEMERAL_DIR:-}"
    [[ -n "$dir" && "$dir" == /run/A-Box-uninstall-tx.* && "$dir" != /run/ ]] || return 0
    rm -rf -- "$dir" 2>/dev/null || true
    ABOX_DEPLOY_TX_EPHEMERAL_DIR=''
}

# SYD-B E14: read-only pre-verification of a backup: the checksum,
# hmac, archive, safety and init-compat gates of a restore, run
# BEFORE any target is deleted. Returns 0 only when the backup
# would pass the restore's own pre-destructive gates.
verify_backup_restorable() {
    # R15-09 (sibling of the core-upgrade defect): this used to verify
    # the SHARED archive directly and keep no private copy at all, so
    # the deployment rollback could delete the core and then find the
    # shared backup rotated away. Pin FIRST (archive + sidecars into a
    # private work dir), run every check against the pin, and retain it
    # on opt-in (3rd arg retain=1) for the rollback to consume through
    # the existing restore arguments. A retained pin is published as
    # ABOX_VERIFY_PINNED_WORK only after every gate succeeds. The
    # explicit key file keeps its caller-provided path (it is not a
    # shared-backup sidecar).
    local backup="${1:-}" key_file="${2:-}" retain="${3:-0}" work root _pbc _rbs=''
    [[ -n "$backup" && -f "$backup" && ! -L "$backup" ]] || return 1
    if [[ -n "${ABOX_VERIFY_PINNED_WORK:-}" ]]; then
        if [[ -d "$ABOX_VERIFY_PINNED_WORK" ]]; then
            return 1
        fi
        ABOX_VERIFY_PINNED_WORK=''
    fi
    work=$(mktemp -d /tmp/A-Box-verify.XXXXXX) || return 1
    chmod 700 "$work" 2>/dev/null || true
    _pbc="$work/$(basename "$backup")"
    cp -- "$backup" "$_pbc" || { rm -rf "$work"; return 1; }
    chmod 600 "$_pbc" || { rm -rf "$work"; return 1; }
    for _rbs in "${backup}.sha256" "${backup}.hmac" "${backup}.key"; do
        if [[ -e "$_rbs" ]]; then
            cp -- "$_rbs" "$work/$(basename "$_rbs")" || { rm -rf "$work"; return 1; }
        fi
    done
    backup_checksum_verify "$_pbc" "${_pbc}.sha256" || { rm -rf "$work"; return 1; }
    if [[ -n "$key_file" ]]; then
        backup_auth_verify_with_key_file "$_pbc" "${_pbc}.hmac" "$key_file" || { rm -rf "$work"; return 1; }
    else
        backup_auth_verify "$_pbc" "${_pbc}.hmac" || { rm -rf "$work"; return 1; }
    fi
    validate_backup_archive "$_pbc" || { rm -rf "$work"; return 1; }
    tar -xzf "$_pbc" -C "$work" 2>/dev/null || { rm -rf "$work"; return 1; }
    root="$work/root"
    assert_restore_target_safe "$root" || { rm -rf "$work"; return 1; }
    assert_restore_shortcut_safe "$root" || { rm -rf "$work"; return 1; }
    validate_backup_core_init_compatibility "$root" || { rm -rf "$work"; return 1; }
    if [[ "$retain" == 1 ]]; then
        ABOX_VERIFY_PINNED_WORK="$work"
    else
        rm -rf "$work"
    fi
    return 0
}

# SYD-B E14: restart services from a backup's recorded state, used
# when a rollback cannot restore the backup itself (or when the
# backup fails pre-verification): the old deployment must not be
# left stopped. Best-effort; never masks the caller's failure.
# SYD-B2 E13/E14: best-effort restart of snapshot-active services.
# Used when the strict service-state restore fails (e.g. a stale 644
# state file from an old backup): starting a service whose config is
# intact restores availability; starting one whose config is broken
# fails silently, no worse than leaving it down. Only services the
# snapshot marks active=1 are started, and only the three managed
# families; anything else is ignored.
_rollback_start_snapshot_services() {
    local state_file="$1" _srv _active _enabled _extra
    [[ -r "$state_file" && -f "$state_file" && ! -L "$state_file" ]] || return 1
    while IFS='|' read -r _srv _active _enabled _extra || [[ -n "$_srv" ]]; do
        [[ -n "$_srv" ]] || continue
        [[ "$_active" == 1 ]] || continue
        case "$_srv" in xray|sing-box|hysteria|xray-latest) ;; *) continue ;; esac
        abox_owns_service "$_srv" || { msg "[!] Rollback fallback: skipping ${_srv} from snapshot (not A-Box-owned)."; continue; }
        if [[ "${INIT_SYS:-}" == systemd ]]; then
            systemctl start "$_srv" >/dev/null 2>&1 || true
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service "$_srv" start >/dev/null 2>&1 9>&- 10>&- || true
        fi
        msg "[!] Rollback fallback: attempted to start ${_srv} from snapshot (strict service-state restore failed)."
    done < "$state_file"
    return 0
}

# N6-A: pre-deployment snapshot of services.state, kept OUTSIDE the
# backup archive. The rollback restart gate reads meta/services.state
# out of the backup tarball; an in-place tamper of the gzip stream
# before that member (S2) makes the state unrecoverable and leaves
# every service down. The snapshot is a private copy taken at
# transaction begin, while the just-created archive is still intact.
ABOX_DEPLOY_TX_STATE_SNAPSHOT=''

# Drop the snapshot file (if any) and clear the pointer. Called on
# commit and at the end of every rollback; begin also clears a stale
# snapshot before taking a new one, so no stale state is ever reused.
_tx_clear_services_state_snapshot() {
    if [[ -n "${ABOX_DEPLOY_TX_STATE_SNAPSHOT:-}" && -f "$ABOX_DEPLOY_TX_STATE_SNAPSHOT" ]]; then
        rm -f -- "$ABOX_DEPLOY_TX_STATE_SNAPSHOT" 2>/dev/null || true
    fi
    ABOX_DEPLOY_TX_STATE_SNAPSHOT=''
}

# deployment_transaction_snapshot_services_state <backup>: copy the
# backup's own recorded meta/services.state into a private file
# outside the archive (mode 600, validated) and point
# ABOX_DEPLOY_TX_STATE_SNAPSHOT at it. The copy records exactly the
# state the rollback would have used. Fails closed (non-zero, no
# pointer left) when the state cannot be extracted or fails
# validation: deploying without the snapshot would silently reopen
# the N6 hole. Tar's exit code is not the gate (see the N6 note in
# rollback_restart_services_from_backup): file presence plus
# validate_services_state_file decides.
deployment_transaction_snapshot_services_state() {
    local backup="${1:-}" snap work
    _tx_clear_services_state_snapshot
    [[ -n "$backup" && -f "$backup" && ! -L "$backup" ]] || return 1
    snap=$(mktemp /tmp/A-Box-tx-services-state.XXXXXX) || return 1
    chmod 600 "$snap" || { rm -f -- "$snap"; return 1; }
    work=$(mktemp -d /tmp/A-Box-tx-state-extract.XXXXXX) || { rm -f -- "$snap"; return 1; }
    tar -xzf "$backup" -C "$work" meta/services.state 2>/dev/null || true
    if [[ ! -f "$work/meta/services.state" ]] || ! validate_services_state_file "$work/meta/services.state"; then
        rm -rf -- "$work" "$snap"
        return 1
    fi
    cp -- "$work/meta/services.state" "$snap" || { rm -rf -- "$work" "$snap"; return 1; }
    chmod 600 "$snap" || { rm -rf -- "$work" "$snap"; return 1; }
    rm -rf -- "$work"
    ABOX_DEPLOY_TX_STATE_SNAPSHOT="$snap"
    return 0
}

rollback_restart_services_from_backup() {
    local backup="${1:-}" work state rc=0
    [[ -n "$backup" && -f "$backup" && ! -L "$backup" ]] || return 1
    work=$(mktemp -d /tmp/A-Box-rollback-state.XXXXXX) || return 1
    # N6: do not gate on tar's exit code. A damaged compressed stream
    # can still yield an intact meta/services.state (tar reports the
    # gzip CRC error only at the end of the stream, rc=2); the state
    # file's presence is the gate, not tar's rc. The state must also
    # pass validate_services_state_file: the strict restore validates
    # too, but the fallback below parses loosely and would otherwise
    # start a service from a corrupt/truncated state line.
    tar -xzf "$backup" -C "$work" meta/services.state 2>/dev/null || true
    if [[ -f "$work/meta/services.state" ]] && validate_services_state_file "$work/meta/services.state"; then
        state="$work/meta/services.state"
        if restore_managed_service_state "$state"; then
            rc=0
        else
            rc=$?
            # SYD-B2 E13/E14: strict restore failed; still bring back
            # whatever the snapshot marks active, best-effort, so a
            # failed deployment never leaves services down.
            _rollback_start_snapshot_services "$state" || true
        fi
        rm -rf -- "$work"
        return $rc
    fi
    # N6-A: the archive's state could not be recovered (S2: gzip damage
    # before the state member, or a corrupt in-archive state). Fall back
    # to the pre-deployment snapshot taken at transaction begin.
    # Restart-only: _rollback_start_snapshot_services only starts
    # services the snapshot marks active=1, never restores files, and
    # the snapshot itself must pass validate_services_state_file, so a
    # corrupt/truncated snapshot starts nothing. The archive file must
    # still exist (gate above): a missing archive fails closed.
    if [[ -n "${ABOX_DEPLOY_TX_STATE_SNAPSHOT:-}" && -f "$ABOX_DEPLOY_TX_STATE_SNAPSHOT" && ! -L "$ABOX_DEPLOY_TX_STATE_SNAPSHOT" ]] \
        && validate_services_state_file "$ABOX_DEPLOY_TX_STATE_SNAPSHOT"; then
        msg "[!] Rollback fallback: archive state unrecoverable; restarting services from the pre-deployment snapshot."
        _rollback_start_snapshot_services "$ABOX_DEPLOY_TX_STATE_SNAPSHOT" || true
        rm -rf -- "$work"
        return 0
    fi
    rm -rf -- "$work"
    return 1
}

# L8: inventory of A-Box residue left behind by an aborted rollback.
# Prints one line per item (cron blocks present, jail/filter files,
# loaded A-Box jails, fail2ban running state). Never fails (rc 0); an
# unqueryable source is reported as unknown, never guessed.
rollback_residual_inventory() {
    local _blocks='' _f='' _loaded=''
    _blocks=$(_current_abox_cron_blocks 2>/dev/null | cut -f1 | paste -sd, - 2>/dev/null || true)
    printf 'cron blocks present: %s\n' "${_blocks:-none}"
    for _f in /etc/fail2ban/jail.d/A-Box.local /etc/fail2ban/filter.d/A-Box.conf; do
        if [[ -e "$_f" || -L "$_f" ]]; then printf 'file present: %s\n' "$_f"; else printf 'file absent: %s\n' "$_f"; fi
    done
    if command -v fail2ban-client >/dev/null 2>&1; then
        if fail2ban_service_running 2>/dev/null; then
            _loaded=$(fail2ban_loaded_jails 2>/dev/null | grep '^A-Box-' | paste -sd, - || true)
            printf 'fail2ban running; loaded A-Box jails: %s\n' "${_loaded:-none}"
        else
            printf 'fail2ban not running\n'
        fi
    else
        printf 'fail2ban not installed\n'
    fi
    return 0
}

# L8: unified abort exit for deployment_transaction_rollback_inner.
# Records WHICH stage the rollback reached and the residual inventory
# in the rollback state file, and reports both; preserves the caller's
# rc. This function deletes nothing: the default abort policy is to
# KEEP the running state and report, never to clean up silently (see
# _rollback_abort_cron_best_effort for the single narrow exception).
_rollback_record_abort() {
    local _stage="${1:-unknown}" _rc="${2:-1}"
    {
        printf 'abort-stage: %s\n' "$_stage"
        printf 'abort-rc: %s\n' "$_rc"
        rollback_residual_inventory
    } >> "${ABOX_DEPLOY_ROLLBACK_STATE_FILE:-/run/A-Box-deploy-rollback-state}" 2>/dev/null || true
    msg "${RED}[!] Rollback aborted at stage: ${_stage} (rc=${_rc}). Residual A-Box state was preserved; inventory:${NC}" >&2
    rollback_residual_inventory >&2 || true
    return "$_rc"
}

# L8: narrow best-effort cron cleanup for abort exits AFTER the backup
# was verified. Only removes a block when the VERIFIED backup's cron
# proves it absent there (so it was created by this transaction) AND
# it is present now. Never touches fail2ban files or loaded jails on
# abort paths, and never runs when pre-verification failed (an
# untrusted backup must not decide deletions). Failures are ignored.
_rollback_abort_cron_best_effort() {
    local _pinned_dir="${1:-}" _cron='' _name _known _bare_found _present_now
    [[ -n "$_pinned_dir" ]] || return 0
    _cron="$_pinned_dir/meta/cron.abox.txt"
    [[ -f "$_cron" && ! -L "$_cron" ]] || return 0
    validate_abox_cron_file "$_cron" 2>/dev/null || return 0
    _present_now=$(_current_abox_cron_blocks 2>/dev/null | cut -f1 || true)
    for _name in PROBE GEO TRAFFIC USERGUARD; do
        grep -Fq "# A-Box ${_name} BEGIN" "$_cron" 2>/dev/null && continue
        _bare_found=0
        while IFS= read -r _known || [[ -n "$_known" ]]; do
            if grep -Fxq "$_known" "$_cron" 2>/dev/null; then _bare_found=1; break; fi
        done < <(_abox_cron_block_known_lines "$_name")
        (( _bare_found == 1 )) && continue
        grep -Fxq "$_name" <<< "$_present_now" || continue
        remove_abox_cron_block "$_name" >/dev/null 2>&1 || true
        msg "[!] Rollback abort: removed ${_name} cron block created by this transaction (absent from the verified backup)." >&2
    done
    return 0
}

deployment_transaction_rollback_inner() {
    [[ "${ABOX_DEPLOY_TX_ACTIVE:-0}" == 1 ]] || return 0
    # B-C2: land a rollback state file FIRST, so a later inspection can
    # tell a rollback happened, when, why, and from which backup -- even
    # when the operator only killed the hung deploy or it timed out.
    # Best-effort: a failed write must never fail the rollback itself.
    {
        printf 'time: %s\n' "$(now_iso)"
        printf 'pid: %s\n' "$$"
        printf 'reason: %s\n' "${ABOX_DEPLOY_TX_REASON:-deployment}"
        printf 'backup: %s\n' "${ABOX_DEPLOY_TX_BACKUP:-}"
        printf 'targets: %s\n' "${ABOX_DEPLOY_TX_TARGETS:-}"
    } > "${ABOX_DEPLOY_ROLLBACK_STATE_FILE:-/run/A-Box-deploy-rollback-state}" 2>/dev/null || true
    local targets="${ABOX_DEPLOY_TX_TARGETS:-}" reason="${ABOX_DEPLOY_TX_REASON:-deployment}" backup="${ABOX_DEPLOY_TX_BACKUP:-}" tx_tmp="${ABOX_DEPLOY_TX_TMP:-}" tx_backup_dir="${ABOX_DEPLOY_TX_BACKUP_DIR:-$ABOX_DIR/backups}" tx_key_file="${ABOX_DEPLOY_TX_KEY_FILE:-}" tx_ephemeral_dir="${ABOX_DEPLOY_TX_EPHEMERAL_DIR:-}" srv cleanup_failed=0
    [[ -n "${1:-}" ]] && reason="${reason}; $1"
    # Disable recursive EXIT rollback, but keep the snapshot/context fields until
    # rollback truly completes so an incomplete recovery remains diagnosable.
    ABOX_DEPLOY_TX_ACTIVE=0
    ABOX_DEPLOY_TX_OWNER=''
    ABOX_DIE_HOOK=''
    msg "${YELLOW}[!] ${reason} failed; restoring the exact pre-operation snapshot.${NC}"

    # SYD-B E14 + R4C8-03: pre-verify the backup BEFORE stopping
    # services or clearing firewall rules (not just before deleting
    # targets). A backup that fails checksum/hmac/archive/safety/
    # compat must abort while services still run and rules still
    # stand; discovering a missing archive after stop + firewall
    # clear leaves every service down with no usable restore
    # (rollback_restart_services_from_backup is a no-op for a
    # missing archive).
    # R15-09: same pinning as the core-upgrade rollback (see
    # restore_backup_prevalidate): the verified copy is retained and is
    # the object the restore consumes. A pin from an earlier
    # transaction is a recovery bundle: refuse, never overwrite it.
    if [[ -n "${ABOX_VERIFY_PINNED_WORK:-}" ]]; then
        if [[ -d "$ABOX_VERIFY_PINNED_WORK" ]]; then
            msg "${RED}[!] Rollback aborted: a retained recovery bundle already exists: ${ABOX_VERIFY_PINNED_WORK}; manual handling required.${NC}" >&2
            _rollback_record_abort 'retained-bundle' 1
            return 1
        fi
        ABOX_VERIFY_PINNED_WORK=''
    fi
    if ! verify_backup_restorable "$backup" "$tx_key_file" 1; then
        msg "${RED}[!] Rollback aborted before stopping services: backup failed pre-verification. Recovery backup retained: ${backup:-missing}${NC}" >&2
        _rollback_record_abort 'pre-verify' 1
        return 1
    fi

    # The retained bundle is the restore source from here on. It must
    # be complete before any destructive step; a failed stop/cleanup/
    # remove/restore RETAINS it and names it. Only a successful restore
    # deletes it.
    local _pinned_dir="$ABOX_VERIFY_PINNED_WORK"
    local _pinned_archive="$_pinned_dir/$(basename "$backup")"
    if [[ -n "$_pinned_dir" && -f "$_pinned_archive" && ! -L "$_pinned_archive" ]]; then
        :
    else
        msg "${RED}[!] Rollback aborted: the retained recovery bundle is incomplete: ${_pinned_archive:-missing}.${NC}" >&2
        _rollback_record_abort 'pinned-incomplete' 1
        return 1
    fi
    if ! stop_all_managed_services >/dev/null 2>&1; then
        msg "${RED}[!] Rollback aborted before destructive cleanup: one or more managed services could not be confirmed stopped. Recovery bundle retained: $_pinned_archive${NC}" >&2
        _rollback_abort_cron_best_effort "$_pinned_dir"
        _rollback_record_abort 'stop-services' 1
        return 1
    fi
    clean_nat_rules >/dev/null 2>&1 || cleanup_failed=1
    clean_input_rules >/dev/null 2>&1 || cleanup_failed=1
    remove_native_firewall_rules >/dev/null 2>&1 || cleanup_failed=1
    if (( cleanup_failed != 0 )); then
        msg "${RED}[!] Rollback aborted before removing core files: firewall cleanup could not be verified. Recovery bundle retained: $_pinned_archive${NC}" >&2
        _rollback_abort_cron_best_effort "$_pinned_dir"
        _rollback_record_abort 'firewall-cleanup' 1
        return 1
    fi

    # (Backup pre-verified above, before any service stop or
    # firewall clear; see R4C8-03.)

    for srv in $targets; do
        if ! remove_core_family_force "$srv"; then
            msg "${RED}[!] Rollback aborted: unable to remove the staged/current ${srv} core family. No backup restore was attempted; recovery bundle retained: $_pinned_archive${NC}" >&2
            _rollback_abort_cron_best_effort "$_pinned_dir"
            _rollback_record_abort 'remove-core-family' 1
            return 1
        fi
    done

    if [[ -n "$tx_key_file" ]]; then
        if ! restore_latest_backup_silent "$_pinned_dir" "$_pinned_archive" "$tx_key_file"; then
            msg "${RED}[!] Automatic rollback could not restore the exact pre-operation backup: ${_pinned_archive}. Recovery bundle retained: ${_pinned_archive}${NC}" >&2
            _rollback_abort_cron_best_effort "$_pinned_dir"
            _rollback_record_abort 'restore' 1
            rollback_restart_services_from_backup "$_pinned_archive" || true
            return 1
        fi
    else
        if ! restore_latest_backup_silent "$_pinned_dir" "$_pinned_archive"; then
            msg "${RED}[!] Automatic rollback could not restore the exact pre-operation backup: ${_pinned_archive}. Recovery bundle retained: ${_pinned_archive}${NC}" >&2
            _rollback_abort_cron_best_effort "$_pinned_dir"
            _rollback_record_abort 'restore' 1
            rollback_restart_services_from_backup "$_pinned_archive" || true
            return 1
        fi
    fi
    rm -rf -- "$_pinned_dir" || { msg "${RED}[!] Prior state restored, but retained-bundle cleanup failed: $_pinned_dir${NC}" >&2; _rollback_record_abort 'bundle-cleanup' 1; return 1; }
    ABOX_VERIFY_PINNED_WORK=''

    if [[ -n "$tx_tmp" ]]; then
        rm -rf -- "$tx_tmp" || { msg "${RED}[!] Prior state restored, but transaction staging cleanup failed: $tx_tmp${NC}" >&2; _rollback_record_abort 'tx-tmp-cleanup' 1; return 1; }
    fi
    if [[ -n "$tx_ephemeral_dir" && "$tx_ephemeral_dir" == /run/A-Box-uninstall-tx.* && "$tx_ephemeral_dir" != /run/ ]]; then
        rm -rf -- "$tx_ephemeral_dir" 2>/dev/null || { msg "${RED}[!] Prior state restored, but ephemeral transaction cleanup failed: $tx_ephemeral_dir${NC}" >&2; _rollback_record_abort 'ephemeral-cleanup' 1; return 1; }
    fi
    ABOX_DEPLOY_TX_TARGETS=''
    ABOX_DEPLOY_TX_REASON=''
    ABOX_DEPLOY_TX_BACKUP=''
    ABOX_DEPLOY_TX_TMP=''
    ABOX_DEPLOY_TX_BACKUP_DIR=''
    ABOX_DEPLOY_TX_KEY_FILE=''
    ABOX_DEPLOY_TX_EPHEMERAL_DIR=''
    ABOX_DEPLOY_TX_OWNER=''
    # Carbon H-11(4): a deploy that reached rollback may have left a
    # preserve snapshot behind; reap it now that the pre-operation
    # state is restored (diagnostics copy first, then remove).
    standalone_preserve_cleanup
    printf '%s\n' 'rollback: complete' >> "${ABOX_DEPLOY_ROLLBACK_STATE_FILE:-/run/A-Box-deploy-rollback-state}" 2>/dev/null || true
    return 0
}

# R7C8-02: rollback must restore the pre-transaction traps on
# EVERY exit (not just via exit/signal abort). Otherwise a
# second begin captures exit_abort itself as PREV, and a normal
# exit evals it forever (the global PREV never changes).
# The wrapper guarantees the restore for all inner returns.
deployment_transaction_rollback() {
    local _rc
    # OBS-2: record whether the best-effort fallback restart ran and
    # what it returned, so die() can tier its warning (restart
    # attempted vs restart failed). Cleared on entry so a stale value
    # can never downgrade an unrelated later failure. The rollback
    # itself is unchanged: the failure rc is never masked.
    ABOX_ROLLBACK_FALLBACK_RC=''
    deployment_transaction_rollback_inner "$@"
    _rc=$?
    # N6-A: the inner rollback can fail BEFORE any service restart
    # (pre-verification, retained pin, stop/firewall/remove failure)
    # while the deploy already stopped the services. A failed rollback
    # must never leave a service down that the snapshot marks active:
    # best-effort restart from the transaction backup (starts only
    # A-Box-owned services the snapshot marks active=1; restores no
    # files). The failure rc is never masked.
    if (( _rc != 0 )); then
        if rollback_restart_services_from_backup "${ABOX_DEPLOY_TX_BACKUP:-}"; then
            ABOX_ROLLBACK_FALLBACK_RC='0'
        else
            ABOX_ROLLBACK_FALLBACK_RC='1'
        fi
    fi
    # N6-A: the snapshot served its purpose (or there was no failure to
    # cover); drop it so a later transaction can never reuse stale state.
    _tx_clear_services_state_snapshot
    restore_deployment_transaction_traps
    return "$_rc"
}

begin_deployment_transaction() {
    local reason="$1"; shift
    [[ "${ABOX_DEPLOY_TX_ACTIVE:-0}" == 1 ]] && die "$(tr_msg tx_nested)"
    ABOX_LAST_BACKUP=''
    local backup_dir="${ABOX_DEPLOY_TX_BACKUP_DIR:-$ABOX_DIR/backups}"
    auto_backup_silent "$reason" "$backup_dir" || return 1
    [[ -n "$ABOX_LAST_BACKUP" && -f "$ABOX_LAST_BACKUP" ]] || return 1
    # N6-A: snapshot services.state outside the archive before any
    # service is stopped, so a later in-place tamper of the tarball
    # cannot take the restart fallback down with it. Fails closed: a
    # transaction that cannot snapshot its pre-state must not start.
    deployment_transaction_snapshot_services_state "$ABOX_LAST_BACKUP" || return 1
    ABOX_DEPLOY_TX_BACKUP_DIR="$backup_dir"
    ABOX_DEPLOY_TX_ACTIVE=1
    ABOX_DEPLOY_TX_REASON="$reason"
    ABOX_DEPLOY_TX_TARGETS="$*"
    ABOX_DEPLOY_TX_BACKUP="$ABOX_LAST_BACKUP"
    ABOX_DEPLOY_TX_OWNER=$BASHPID
    ABOX_DIE_HOOK=deployment_transaction_rollback
    install_deployment_transaction_traps
}

# L6 (final-round): preserve the uninstall transaction backup before the
# commit clears the transaction directory. The transaction backup is the
# only pre-uninstall snapshot when the user answered N to the prompt
# backup; deleting it with the tx dir left only a dangling separated
# key. The archive + sha256 + hmac are copied to /root/A-Box-backups
# (the same retention pool as the prompt backup), verified, and only
# then may the commit proceed. Any failure here returns 1; the caller
# must die so the transaction rolls back with the backup still in place.
# The separated recovery key already lives in /root/A-Box-backup-keys
# (written by backup_current_config); this step never touches keys, so
# an old dangling key is left alone, never silently deleted.
preserve_uninstall_transaction_backup() {
    local tx_backup="${ABOX_DEPLOY_TX_BACKUP:-}" tx_dir="${ABOX_DEPLOY_TX_EPHEMERAL_DIR:-}"
    local safe_dir="${ABOX_UNINSTALL_BACKUP_SAFE_DIR:-/root/A-Box-backups}"
    local base dest key_path _sfx
    [[ -n "$tx_backup" && -f "$tx_backup" && ! -L "$tx_backup" ]] || return 1
    [[ -n "$tx_dir" && "$tx_backup" == "$tx_dir"/* ]] || return 1
    [[ -n "$safe_dir" && "$safe_dir" == /* ]] || return 1
    mkdir_private "$safe_dir" || return 1
    path_owned_by_root "$safe_dir" || return 1
    path_mode_has_no_group_other_write "$safe_dir" || return 1
    base=$(basename -- "$tx_backup")
    dest="$safe_dir/$base"
    [[ ! -e "$dest" && ! -L "$dest" ]] || return 1
    [[ -f "${tx_backup}.sha256" && ! -L "${tx_backup}.sha256" ]] || return 1
    [[ -f "${tx_backup}.hmac" && ! -L "${tx_backup}.hmac" ]] || return 1
    cp -- "$tx_backup" "$dest.tmp.$$" 2>/dev/null || return 1
    chmod 600 "$dest.tmp.$$" 2>/dev/null || { rm -f -- "$dest.tmp.$$"; return 1; }
    for _sfx in .sha256 .hmac; do
        cp -- "$tx_backup$_sfx" "$dest$_sfx.tmp.$$" 2>/dev/null || { rm -f -- "$dest.tmp.$$" "$dest.sha256.tmp.$$" "$dest.hmac.tmp.$$"; return 1; }
        chmod 600 "$dest$_sfx.tmp.$$" 2>/dev/null || { rm -f -- "$dest.tmp.$$" "$dest.sha256.tmp.$$" "$dest.hmac.tmp.$$"; return 1; }
    done
    mv -f -T -- "$dest.tmp.$$" "$dest" || { rm -f -- "$dest.tmp.$$" "$dest.sha256.tmp.$$" "$dest.hmac.tmp.$$"; return 1; }
    mv -f -T -- "$dest.sha256.tmp.$$" "$dest.sha256" || { rm -f -- "$dest" "$dest.sha256.tmp.$$" "$dest.hmac.tmp.$$"; return 1; }
    mv -f -T -- "$dest.hmac.tmp.$$" "$dest.hmac" || { rm -f -- "$dest" "$dest.sha256" "$dest.hmac.tmp.$$"; return 1; }
    backup_checksum_verify "$dest" "$dest.sha256" || { rm -f -- "$dest" "$dest.sha256" "$dest.hmac"; return 1; }
    key_path="/root/A-Box-backup-keys/$base.key"
    if [[ -f "$key_path" && ! -L "$key_path" ]]; then
        msg "[*] Uninstall transaction backup preserved: $dest (recovery key: $key_path)"
    else
        msg "[*] Uninstall transaction backup preserved: $dest"
    fi
    msg "[*] This is the uninstall transaction backup; the prompt backup (if any) is a separate file in $safe_dir under the same retention policy."
    return 0
}

commit_deployment_transaction() {
    local tx_ephemeral_dir="${ABOX_DEPLOY_TX_EPHEMERAL_DIR:-}"
    _tx_clear_services_state_snapshot
    ABOX_DEPLOY_TX_ACTIVE=0
    ABOX_DEPLOY_TX_TARGETS=''
    ABOX_DEPLOY_TX_REASON=''
    ABOX_DEPLOY_TX_BACKUP=''
    ABOX_DEPLOY_TX_TMP=''
    ABOX_DEPLOY_TX_BACKUP_DIR=''
    ABOX_DEPLOY_TX_KEY_FILE=''
    ABOX_DEPLOY_TX_EPHEMERAL_DIR=''
    ABOX_DEPLOY_TX_OWNER=''
    ABOX_DIE_HOOK=''
    restore_deployment_transaction_traps
    if [[ -n "$tx_ephemeral_dir" && "$tx_ephemeral_dir" == /run/A-Box-uninstall-tx.* && "$tx_ephemeral_dir" != /run/ ]]; then
        rm -rf -- "$tx_ephemeral_dir" 2>/dev/null || true
    fi
}


parse_x25519_keypair_output() {
    local input="${1:-}" line key value private_key='' public_key=''
    [[ -n "$input" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" == *:* ]] || continue
        key=${line%%:*}
        value=${line#*:}
        key=${key#"${key%%[!$' \t']*}"}; key=${key%"${key##*[!$' \t']}"}
        value=${value#"${value%%[!$' \t']*}"}; value=${value%"${value##*[!$' \t']}"}
        case "${key,,}" in
            privatekey|private\ key)
                [[ -z "$private_key" ]] || continue
                private_key="$value"
                ;;
            password\ \(publickey\)|password\ \(public\ key\)|publickey|public\ key)
                [[ -z "$public_key" ]] || continue
                public_key="$value"
                ;;
            password)
                [[ -n "$public_key" ]] || public_key="$value"
                ;;
        esac
    done <<< "$input"
    [[ -n "$private_key" && -n "$public_key" ]] || return 1
    printf '%s\t%s\n' "$private_key" "$public_key"
}


# Interactive: port (default 1080), username (default abox), password (default random).
# If Xray is already installed, the socks5-landing inbound is added/updated via
# xray_hot_add_inbound (hot-push when the API is available, restart fallback).
# Otherwise a minimal Xray install (binary + config + systemd unit) is performed.
# Interactive: port (default 1080), username (default abox), password (default random).
# If Xray is already installed, the socks5-landing inbound is added/updated via
# xray_hot_add_inbound (hot-push when the API is available, restart fallback).
# Otherwise a minimal Xray install (binary + config + systemd unit) is performed.
# sing-box variant: uses type "mixed" (default, SOCKS5+HTTP auto-detect) or "socks".
# No API hot-push on sing-box: config rewrite + `sing-box check` + service restart.
singbox_vendor_takeover_gate() {
    local vendor_unit='' state_enabled='unknown' state_active='unknown' backup='' answer='' _orc_rc='' _u=''
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # Prefer systemd's selected fragment, including nonstandard locations.
        _u=$(systemctl show -p FragmentPath --value sing-box.service 2>/dev/null || true)
        if [[ -n "$_u" && -f "$_u" ]]; then
            vendor_unit="$_u"
        else
            for _u in \
                /etc/systemd/system/sing-box.service \
                /run/systemd/system/sing-box.service \
                /usr/local/lib/systemd/system/sing-box.service \
                /usr/lib/systemd/system/sing-box.service \
                /lib/systemd/system/sing-box.service; do
                if [[ -f "$_u" ]]; then
                    vendor_unit="$_u"
                    break
                fi
            done
        fi
        if [[ -n "$vendor_unit" ]] && grep -Fxq '# Managed by A-Box' "$vendor_unit" 2>/dev/null; then return 0; fi
        if [[ -z "$vendor_unit" ]]; then
            if systemctl is-enabled --quiet sing-box.service 2>/dev/null ||
               systemctl is-active --quiet sing-box.service 2>/dev/null; then
                vendor_unit='(service without unit file)'
            else
                return 0
            fi
        fi
        state_enabled=$(systemctl is-enabled sing-box.service 2>/dev/null || echo unknown)
        state_active=$(systemctl is-active sing-box.service 2>/dev/null || echo unknown)
        msg "Existing non-A-Box sing-box service detected: unit=$vendor_unit, enabled=$state_enabled, active=$state_active. Takeover will replace its unit with the A-Box unit."
        read -r -p "Continue takeover and replace the existing sing-box service? [Y/N]: " answer || return 1
        case "$answer" in
            Y|y|Yes|YES|yes) ;;
            *) return 1 ;;
        esac
        backup='/etc/systemd/system/sing-box.service.abox-vendor-backup'
        if [[ -f "$vendor_unit" ]]; then
            cp -a -- "$vendor_unit" "$backup" || return 1
        fi
        echo "unit=$vendor_unit" > "${backup}.state" || return 1
        echo "enabled=$state_enabled" >> "${backup}.state" || return 1
        echo "active=$state_active" >> "${backup}.state" || return 1
        return 0
    fi
    if [[ -f /etc/init.d/sing-box ]] && grep -Fxq '# Managed by A-Box' /etc/init.d/sing-box 2>/dev/null; then return 0; fi
    if [[ ! -f /etc/init.d/sing-box ]]; then return 0; fi
    vendor_unit='/etc/init.d/sing-box'
    rc-service sing-box status >/dev/null 2>&1; _orc_rc=$?
    msg "Existing non-A-Box sing-box service detected: unit=$vendor_unit, rc-status=$_orc_rc. Takeover will replace its init script with the A-Box one."
    read -r -p "Continue takeover and replace the existing sing-box service? [Y/N]: " answer || return 1
    case "$answer" in
        Y|y|Yes|YES|yes) ;;
        *) return 1 ;;
    esac
    backup='/etc/init.d/sing-box.abox-vendor-backup'
    cp -a -- "$vendor_unit" "$backup" || return 1
    if [[ -f /etc/conf.d/sing-box ]]; then
        cp -a -- /etc/conf.d/sing-box /etc/conf.d/sing-box.abox-vendor-backup || return 1
    fi
    echo "unit=$vendor_unit" > "${backup}.state" || return 1
    echo "rc-status=$_orc_rc" >> "${backup}.state" || return 1
    return 0
}

# R5C8-04: Hysteria listeners count for port recycling; a
# port still used by Hysteria must keep its UDP rule. Listen
# extraction mirrors the live-ports collector (top-level and
# trafficStats.listen both match the indented listen pattern).
_hysteria_listens_on_port() {
    local port="$1" cfg=/etc/hysteria/config.yaml
    local text line value spec span lo hi p found=0
    local -a spans=()

    # Return 1 only when absence/non-coverage is established.
    [[ ! -e "$cfg" && ! -L "$cfg" ]] && return 1
    [[ -f "$cfg" ]] || return 0
    text=$(cat -- "$cfg" 2>/dev/null) || return 0

    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 0
    p=$((10#$port))
    (( p >= 1 && p <= 65535 )) || return 0

    # 04d2-M1: a quoted key ("listen": / 'listen':) is legal YAML; the
    # old pattern required a bare key, so the main listen line was
    # skipped while a later listen line still set found=1 and the
    # function reported the port uncovered without ever having parsed
    # the main listen line. The pattern lives in a variable: bare
    # double quotes inside [[ =~ ]] would be parsed as shell quoting
    # and break the [[ ]] close.
    # R29a-M2: a space between the key and the colon (`listen :`) is
    # legal YAML too; allow blank space there as well.
    local _hy_listen_re="^[[:space:]]*[\"']?listen[\"']?[[:space:]]*:[[:space:]]*(.*)$"
    # R29a-M2: a listen-like key the strict pattern cannot parse (an
    # unexpected separator or form) means non-coverage cannot be
    # established: stay conservative instead of letting a later nested
    # listen set found=1 and report the main port uncovered.
    local _hy_listen_like_re="^[[:space:]]*[\"']?listen[\"']?([[:space:]]|:|$)"
    while IFS= read -r line; do
        if [[ ! "$line" =~ $_hy_listen_re ]]; then
            [[ "$line" =~ $_hy_listen_like_re ]] && return 0
            continue
        fi
        value="${BASH_REMATCH[1]}"

        # Managed single-line YAML scalar; other forms are conservative.
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi

        [[ "$value" == *:* ]] || return 0
        spec="${value##*:}"
        [[ "$spec" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 0

        IFS=, read -r -a spans <<< "$spec"
        for span in "${spans[@]}"; do
            if [[ "$span" == *-* ]]; then
                lo="${span%-*}"
                hi="${span#*-}"
            else
                lo="$span"
                hi="$span"
            fi

            # Bound arithmetic and reject malformed/reversed ranges.
            [[ "$lo" =~ ^[0-9]{1,5}$ && "$hi" =~ ^[0-9]{1,5}$ ]] || return 0
            lo=$((10#$lo))
            hi=$((10#$hi))
            (( lo >= 1 && hi <= 65535 && lo <= hi )) || return 0

            (( p >= lo && p <= hi )) && return 0
        done
        found=1
    done <<< "$text"

    (( found == 1 )) || return 0
    return 1
}

ensure_singbox_service_unit() {
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        if [[ -f /etc/systemd/system/sing-box.service && ! -L /etc/systemd/system/sing-box.service ]]; then
            grep -Fxq '# Managed by A-Box' /etc/systemd/system/sing-box.service && return 0 || return 1
        fi
    else
        if [[ -f /etc/init.d/sing-box && ! -L /etc/init.d/sing-box ]]; then
            grep -Fxq '# Managed by A-Box' /etc/init.d/sing-box && return 0 || return 1
        fi
    fi
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # Do not shadow a foreign runtime/vendor unit with an /etc unit.
        local vendor_unit
        for vendor_unit in \
            /run/systemd/system/sing-box.service \
            /usr/local/lib/systemd/system/sing-box.service \
            /usr/lib/systemd/system/sing-box.service \
            /lib/systemd/system/sing-box.service; do
            [[ -e "$vendor_unit" || -L "$vendor_unit" ]] || continue
            if [[ -f "$vendor_unit" && ! -L "$vendor_unit" ]] &&
                grep -Fxq '# Managed by A-Box' "$vendor_unit" 2>/dev/null; then
                continue
            fi
            printf 'Refusing to shadow foreign service unit %s; resolve the conflict explicitly before retrying.\n' \
                "$vendor_unit" >&2
            return 1
        done
        write_file_atomically_from_stdin /etc/systemd/system/sing-box.service 644 <<'EOF_SVC' || return 1
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
        # R29b-M4: if the reload fails, remove the unit this call just
        # wrote. Otherwise the file (with the marker) survives and the
        # next call takes the early return 0 above without ever
        # retrying the reload -- while systemd may still cache the old
        # unit. The write only happens when the file was absent, so
        # removing it restores the pre-call state.
        systemctl daemon-reload >/dev/null 2>&1 || { rm -f -- /etc/systemd/system/sing-box.service; return 1; }
    else
        path_parent_chain_safe /etc/conf.d/sing-box || return 1
        mkdir -p /etc/conf.d || return 1
        write_file_atomically_from_stdin /etc/conf.d/sing-box 644 <<'EOF_SB_CONFD' || return 1
rc_ulimit="-n 1048576"
EOF_SB_CONFD
        write_file_atomically_from_stdin /etc/init.d/sing-box 755 <<'EOF_SVC' || return 1
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
        chmod +x /etc/init.d/sing-box || return 1
    fi
    # M41-NEW-02 (same class as xray): several landing deploys call
    # ensure before the function-level config seed when the binary is
    # present but the config is missing; a missing config must not fail
    # unit creation. Skip the permission prep in that case — the caller
    # re-runs the full prep after seeding and merging. When the config
    # exists, prep still runs here, as before.
    if [[ -e /etc/sing-box/config.json ]]; then
        prepare_abox_runtime_permissions sing-box || return 1
    fi
    return 0
}

# R29b-M1/M2/M3: recycle a port's A-Box native firewall rules only
# when no live inbound in any core still uses it. Each coverage query
# outputs an explicit boolean (true = port free); only an explicit
# true (jq rc 0) counts as free. A false (rc 1, covered), a query
# error, or an empty result all keep the rules (fail closed). This
# replaces the old inline '! jq -e' pattern, which conflated a
# runtime error inside the coverage query (e.g. a non-object
# .inbounds element) with "not covered" and deleted rules for a port
# the running core still serves. Malformed elements, a malformed
# .inbounds, and a non-object top level are all treated as covering.
# Always returns 0: cleanup failure never fails the caller.
_recycle_port_rules_if_unused() {
    local port="$1" sb_cfg="${2:-/etc/sing-box/config.json}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    # sing-box config must parse and explicitly show the port free.
    # AP-01 residual (A-leg): strip JSONC comments first -- the live
    # config may legally carry // or /* */ comments, which bare jq
    # rejects; the probe then failed and the rules were silently
    # never recycled on commented configs. Same strip-once idiom as
    # the Xray side below.
    jsonc_strip_comments "$sb_cfg" 2>/dev/null | jq -e . >/dev/null 2>&1 || return 0
    jsonc_strip_comments "$sb_cfg" 2>/dev/null | jq -e --argjson p "$port" '
        if type != "object" then false
        elif (.inbounds | type) == "array" then
            ([.inbounds[] | select(if type == "object" then .listen_port == $p else true end)] | length) == 0
        elif (.inbounds | type) == "null" then true
        else false end' >/dev/null 2>&1 || return 0
    # Xray config: a missing file counts as free; a present one must
    # parse and explicitly show the port free.
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        jsonc_strip_comments /usr/local/etc/xray/config.json 2>/dev/null | jq -e . >/dev/null 2>&1 || return 0
        jsonc_strip_comments /usr/local/etc/xray/config.json 2>/dev/null | jq -e --argjson p "$port" '
            def covers($p): ((if type == "object" then .port else null end) as $v | if ($v|type)=="number" then $v==$p elif ($v|type)=="string" then ((($v|gsub(" ";"")) as $s | if ($s|test("^[0-9]+$")) then ($s|tonumber)==$p elif ($s|test("^[0-9]+-[0-9]+$")) then (($s|split("-")|map(tonumber)) as [$a,$b] | if $a>$b then true else ($a<=$p and $p<=$b) end) elif ($s|test("^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$")) then (([$s|split(",")[] | ((split("-")|map(tonumber)) as $r | if ($r|length)==1 then $r[0]==$p elif $r[0]>$r[1] then true else ($r[0]<=$p and $p<=$r[1]) end)] | index(true) != null)) else true end)) else true end);
            if type != "object" then false
            elif (.inbounds | type) == "array" then
                ([.inbounds[] | select(covers($p))] | length) == 0
            elif (.inbounds | type) == "null" then true
            else false end' >/dev/null 2>&1 || return 0
    fi
    # Hysteria returns 1 only when non-coverage is established; 0
    # (covered or unknown) keeps the rules.
    if _hysteria_listens_on_port "$port"; then return 0; fi
    remove_abox_native_firewall_rule "$port" tcp 2>/dev/null || true
    remove_abox_native_firewall_rule "$port" udp 2>/dev/null || true
    save_firewall_rules 2>/dev/null || true
    return 0
}

deploy_singbox_socks5_landing() {
    local port user pass proto cfg='/etc/sing-box/config.json'
    local tag="${ABOX_DEPLOY_TAG:-socks5-landing}" tmp_json
    # SX-TMP: $tmp_json holds the cleartext SOCKS5 password and
    # $cfg_bak a copy of the live config (all credentials); die()
    # exits the process, so only an EXIT trap cleans them on the
    # type-gate die path (same chained idiom as
    # deploy_socks5_landing). Restored on the success path below,
    # once both files are removed explicitly.
    local _sb_socks5_prev_trap_exit='' _sb_socks5_exit_trap_cmd='' _sb_socks5_old_cmd=''
    _sb_socks5_prev_trap_exit=$(trap -p EXIT || true)
    _sb_socks5_exit_trap_cmd='[[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; true'
    if [[ -n "$_sb_socks5_prev_trap_exit" ]]; then
        _sb_socks5_old_cmd="${_sb_socks5_prev_trap_exit#trap -- }"
        _sb_socks5_old_cmd="${_sb_socks5_old_cmd% EXIT}"
        _sb_socks5_exit_trap_cmd="$_sb_socks5_exit_trap_cmd; eval $_sb_socks5_old_cmd"
    fi
    trap "$_sb_socks5_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg socks5_sb_title)${NC}"
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
    # R7C8-03: SOCKS5 (RFC 1929) username/password lengths are
    # single-byte (max 255); longer credentials deploy but can
    # never authenticate. Byte count, not character count.
    local _socks5_user_len _socks5_pass_len
    _socks5_user_len=$(printf '%s' "$user" | wc -c)
    _socks5_pass_len=$(printf '%s' "$pass" | wc -c)
    if (( _socks5_user_len > 255 || _socks5_pass_len > 255 )); then
        die 'SOCKS5 username/password must be at most 255 bytes (RFC 1929).'
    fi
    local _proto_choice=''
    read -r -p "$(tr_msg socks5_proto_prompt)" _proto_choice || die "$(tr_msg pi_input_closed)"
    _proto_choice=$(normalize_fa_ar_digits "$_proto_choice")
    case "$_proto_choice" in
        1|'') proto='mixed' ;;
        2) proto='socks' ;;
        *) die "$(tr_msg invalid_input): $_proto_choice" ;;
    esac
    # R8C8-02: mixed emits an http:// link; HTTP Basic splits on
    # the first ':', so a colon in the username misaligns
    # user/password (URI percent-encoding does not change Basic
    # split semantics). SOCKS5 alone is length-prefixed and fine.
    if [[ "$proto" == 'mixed' && "$user" == *:* ]]; then
        die 'Mixed (HTTP) username must not contain ":"; pick a username without a colon.'
    fi

    # Minimal sing-box install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "sing-box socks5-landing"
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-socks5) || die "$(tr_msg dp_sb_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$sb_tmp"
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
        ABOX_DEPLOY_TX_TMP=''
        # Seed a minimal config shell; the socks/mixed inbound is appended below.
        # U31: install the seed only when no usable config exists; an
        # existing valid config is kept and merged in place below.
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
    abox_fetch_guard_stop
    # R7-13: a pre-existing binary does not imply a service unit exists
    # (e.g. the R4C8-04 seed branch never writes one); ensure it here,
    # before the config merge and restart.
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"

    # Build the socks/mixed inbound object.
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    tmp_json=$(mktemp /tmp/A-Box-singbox-socks5-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --arg proto "$proto" --arg user "$user" --rawfile pass <(printf '%s' "$pass") --arg tag "$tag" --arg listen_addr "$listen_addr" \
        '{type:$proto,tag:$tag,listen:$listen_addr,listen_port:$port,
          users:[{username:$user,password:$pass}]}' \
        > "$tmp_json" || die "$(tr_msg dp_socks5_json)"

    # Replace in place if the tag exists; otherwise append. No API: restart after check.
    # Capture the replaced port now: after the merge it is gone.
    local tmp_cfg old_port='' cfg_bak=''
    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the
    # old_port read, the uniqueness gate and the merge below all
    # read the stripped copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        old_port=$(jq -r --arg t "$tag" 'first(.inbounds[]? | select(.tag==$t)) | (.listen_port // empty)' "$_cfg_stripped" 2>/dev/null || true)
    fi
    # S-X (R30-M02 same-shape): same guard as ShadowTLS (2dh): an
    # independent inbound that merely shares $tag must not be
    # silently replaced by the merge below; only a single genuine
    # SOCKS5 inbound (type socks or mixed) proceeds. SX-F1: the
    # gate is a uniqueness gate, not an existence check -- a
    # duplicated tag (two inbounds sharing $tag, whatever their
    # types) refuses, because the merge below deletes the whole
    # tag group and would silently drop the alien inbound.
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_cfg_stripped" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and ($same[0].type == "socks" or $same[0].type == "mixed"))' "$_cfg_stripped" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg socks5_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not a SOCKS5 inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    # R4C8-04: the seed above only runs when the binary was
    # missing. If the binary exists but the config is missing /
    # empty / a symlink, seed a minimal config here instead of
    # letting the unconditional jq merge below abort on a
    # missing file. An existing non-empty config is never
    # overwritten, even if jq rejects it (see R5C8-02).
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        local _seed2_json
        _seed2_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$_seed2_json" \
            || { rm -f "$_seed2_json"; die "$(tr_msg dp_sb_seed)"; }
        install_file_atomically "$_seed2_json" "$cfg" 600 || { rm -f "$_seed2_json"; die "$(tr_msg dp_sb_cfg)"; }
        rm -f "$_seed2_json"
    fi
    # M-6 rescan: re-strip here -- the seed block above may just
    # have installed a fresh $cfg, which the stripped copy made
    # before the gate does not reflect. The merge below must read
    # the live file as it is now.
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    if ! jq --arg t "$tag" --slurpfile nb "$tmp_json" \
            '.inbounds = (.inbounds // [])
             | (.inbounds | map(select(.tag==$t))) as $old
             | .inbounds |= (
                 map(select(.tag!=$t))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array") and ($ex.users | length) > 1
                                and ($new.users | type == "array") and ($new.users | length) > 0) then
                               $new | .users = ([$new.users[0]] + $ex.users[1:])
                           else $new
                           end
                       )
                   ]
               )' \
            "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_socks5_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_check)"; }
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_cfg)"; }
    rm -f "$tmp_cfg" "$tmp_json"
    prepare_abox_runtime_permissions sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_runtime)"; }
    restart_service_soft sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_restart)"; }

    # Firewall: TCP + UDP.
    ( allowPort "$port" tcp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    ( allowPort "$port" udp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/udp")"; }
    save_firewall_rules || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    rm -f -- "$cfg_bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    # Recycle the replaced port's rules when no inbound still uses it.
    # Either core's config counts: a port rule shared with another
    # core's live inbound must survive. Cleanup failure never fails
    # the deployment itself. _recycle_port_rules_if_unused fails
    # closed: a corrupt config or a query error keeps the rules.
    if [[ "$old_port" =~ ^[0-9]+$ && "$old_port" != "$port" ]]; then
        _recycle_port_rules_if_unused "$old_port" "$cfg" 2>/dev/null || true
    fi

    # Ensure the service is running (minimal-install path).
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_sb_socks5_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    msg "${GREEN}$(tr_msg socks5_done)${NC}"
    if [[ "$proto" == "mixed" ]]; then
        # mixed:// is a sing-box inbound type, not a client-importable
        # URI scheme: share one link per protocol the port serves.
        # The .link file holds both URIs (the panel shows each with
        # its own QR); the stem is unchanged so removal still finds it.
        msg "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
        msg "http://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    else
        msg "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    fi
    if [[ "$proto" == "mixed" ]]; then
        generate_qr "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
        generate_qr "http://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
        register_standalone_link "${ABOX_DEPLOY_STEM:-socks5-sb}" "$(tprintf sl_node_port 'Mixed (sing-box)' "$port")" "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}" "http://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    else
        generate_qr "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
        register_standalone_link "${ABOX_DEPLOY_STEM:-socks5-sb}" "$(tprintf sl_node_port 'SOCKS5 (sing-box)' "$port")" "socks5://$(urlencode "$user"):$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}"
    fi
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    auto_backup_silent "post-deployment snapshot: socks5 (sing-box)" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}

# Standalone Trojan-Reality via Xray-core (toolbox entry).
# Reuses A-Box Reality key/SNI flow: xray x25519 + sni_auto_select_default.
# Tag: trojan-landing. Hot-push via API when available, restart fallback.
# SYD-B E10: ensure the xray service unit exists and is A-Box-
# managed. A unit that exists with the marker is left alone; a
# missing unit is written (systemd reloads only on write;
# OpenRC writes confd + initd and chmods); a foreign unit is
# never overwritten (return 1).
ensure_xray_service_unit() {
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        if [[ -f /etc/systemd/system/xray.service && ! -L /etc/systemd/system/xray.service ]]; then
            grep -Fxq '# Managed by A-Box' /etc/systemd/system/xray.service && return 0 || return 1
        fi
    else
        if [[ -f /etc/init.d/xray && ! -L /etc/init.d/xray ]]; then
            grep -Fxq '# Managed by A-Box' /etc/init.d/xray && return 0 || return 1
        fi
    fi
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # Do not shadow a foreign runtime/vendor unit with an /etc unit.
        local vendor_unit
        for vendor_unit in \
            /run/systemd/system/xray.service \
            /usr/local/lib/systemd/system/xray.service \
            /usr/lib/systemd/system/xray.service \
            /lib/systemd/system/xray.service; do
            [[ -e "$vendor_unit" || -L "$vendor_unit" ]] || continue
            if [[ -f "$vendor_unit" && ! -L "$vendor_unit" ]] &&
                grep -Fxq '# Managed by A-Box' "$vendor_unit" 2>/dev/null; then
                continue
            fi
            printf 'Refusing to shadow foreign service unit %s; resolve the conflict explicitly before retrying.\n' \
                "$vendor_unit" >&2
            return 1
        done
        write_file_atomically_from_stdin /etc/systemd/system/xray.service 644 <<'EOF_SVC' || return 1
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
        # R29b-M4: if the reload fails, remove the unit this call just
        # wrote. Otherwise the file (with the marker) survives and the
        # next call takes the early return 0 above without ever
        # retrying the reload -- while systemd may still cache the old
        # unit. The write only happens when the file was absent, so
        # removing it restores the pre-call state.
        systemctl daemon-reload >/dev/null 2>&1 || { rm -f -- /etc/systemd/system/xray.service; return 1; }
    else
        path_parent_chain_safe /etc/conf.d/xray || return 1
        mkdir -p /etc/conf.d || return 1
        write_file_atomically_from_stdin /etc/conf.d/xray 644 <<'EOF_XRAY_CONFD' || return 1
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
EOF_XRAY_CONFD
        write_file_atomically_from_stdin /etc/init.d/xray 755 <<'EOF_SVC' || return 1
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
        chmod +x /etc/init.d/xray || return 1
    fi
    # M41-NEW-02: the config seed may not exist yet when a minimal
    # landing install calls ensure before seeding (deploy_socks5_landing
    # calls ensure before the seed); a missing config must not fail
    # unit creation. Skip the permission prep in that case — the caller
    # re-runs the full prep after seeding (S-SOCKS5-01). When the config
    # exists, prep still runs here, as before.
    if [[ -e /usr/local/etc/xray/config.json ]]; then
        prepare_abox_runtime_permissions xray || return 1
    fi
    return 0
}

deploy_xray_trojan_landing() {
    local port pass sni pk pbk sid cfg='/usr/local/etc/xray/config.json'
    local tag="${ABOX_DEPLOY_TAG:-trojan-landing}" tmp_json cfg_bak='' old_port=''
    # SX-TMP (M-1): $tmp_json holds the cleartext password / REALITY
    # private key and $cfg_bak a copy of the live config (all
    # credentials); die() exits the process, so only an EXIT trap
    # cleans them on the gate / post-install die paths (same chained
    # idiom as deploy_socks5_landing). Restored on the success path
    # below, once both files are removed explicitly. The trap saves
    # $? in _ec first and restores it with (exit "$_ec") before
    # chaining the previous trap, so the outer trap still sees the
    # real exit code instead of the cleanup's status.
    local _xj_trojan_prev_trap_exit='' _xj_trojan_exit_trap_cmd='' _xj_trojan_old_cmd=''
    _xj_trojan_prev_trap_exit=$(trap -p EXIT || true)
    _xj_trojan_exit_trap_cmd='local _ec=$?; [[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; (exit "$_ec")'
    if [[ -n "$_xj_trojan_prev_trap_exit" ]]; then
        _xj_trojan_old_cmd="${_xj_trojan_prev_trap_exit#trap -- }"
        _xj_trojan_old_cmd="${_xj_trojan_old_cmd% EXIT}"
        _xj_trojan_exit_trap_cmd="$_xj_trojan_exit_trap_cmd; eval $_xj_trojan_old_cmd"
    fi
    trap "$_xj_trojan_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg trojan_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg trojan_port_prompt)" port '443') || die 'Trojan port input failed.'
    IFS= read -r -p "$(tr_msg trojan_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'Trojan password generation failed.'
        [[ -n "$pass" ]] || die 'Trojan password generation failed.'
    fi

    # Minimal Xray install when the binary is missing (mirror SOCKS5 flow).
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "xray trojan-landing"
    if [[ ! -x /usr/local/bin/xray ]]; then
        local xray_tmp xray_zip xray_ext
        get_architecture
        xray_tmp=$(abox_mktemp_exec_dir A-Box-xray-trojan) || die "$(tr_msg dp_xray_tmpdir)"
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
        tmp_json=$(mktemp /tmp/A-Box-xray-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{loglevel:"warning",access:"/var/log/A-Box-xray-access.log",error:"/var/log/A-Box-xray-error.log"},inbounds:[],routing:{rules:[{type:"field",ip:["127.0.0.0/8","::1/128"],outboundTag:"block"}]},outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_xray_seed)"
        # U31: same guard as the sing-box landing seed above.
        # R2C9-01: do NOT treat jq-reject as "needs seed": Xray accepts
        # // comments that jq rejects, and seeding here would overwrite a
        # live commented config with an empty seed and no backup. Only a
        # missing/empty/symlink config is seeded; a jq-invalid existing
        # config is preserved and the merge below fails closed.
        if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
            install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_xray_cfg)"
        fi
        rm -f "$tmp_json"
    fi
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
    abox_fetch_guard_stop
    ensure_xray_service_unit || die "$(tr_msg dp_xray_unit)"

    # Reality keypair + SNI (reuse A-Box flow).
    local keypair
    keypair=$(/usr/local/bin/xray x25519) || die "$(tr_msg dp_xray_keypair)"
    IFS=$'\t' read -r pk pbk < <(parse_x25519_keypair_output "$keypair") || die "$(tr_msg dp_xray_keyparse)"
    [[ -n "${pk:-}" && -n "${pbk:-}" ]] || die "$(tr_msg dp_xray_keyempty)"
    sid=$(openssl rand -hex 4 | tr -d '\n\r') || die "$(tr_msg dp_shortid)"
    sni=$(sni_prompt_or_auto)
    valid_sni "$sni" || die "No verified SNI candidate available; refusing to deploy with an empty SNI."

    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the
    # uniqueness gate below, the old_port read and the merge all
    # read the stripped copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    # M-1: uniqueness gate runs BEFORE $tmp_json is written, so a
    # refused redeploy leaves no secret temp file behind.
    # R30-M02: same guard as ShadowTLS (2dh): an independent inbound
    # that merely shares $tag must not be silently replaced by the
    # merge below; only a single genuine Trojan inbound proceeds.
    # SX-F1: uniqueness gate, not an existence check -- a
    # duplicated tag refuses, because the merge below deletes
    # the whole tag group.
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_cfg_stripped" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].protocol == "trojan")' "$_cfg_stripped" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg trojan_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not a Trojan inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    # Build the trojan+reality inbound object (A-Box realitySettings format).
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    tmp_json=$(mktemp /tmp/A-Box-trojan-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --rawfile pass <(printf '%s' "$pass") --arg sni "$sni" --arg tag "$tag" --arg listen_addr "$listen_addr" \
        --rawfile pk <(printf '%s' "$pk") --rawfile sid <(printf '%s' "$sid") \
        '{tag:$tag,port:$port,listen:$listen_addr,protocol:"trojan",
          settings:{clients:[{password:$pass,email:($tag + "/main")}]},
          streamSettings:{network:"tcp",security:"reality",
            realitySettings:{target:($sni+":443"),serverNames:[$sni],privateKey:$pk,shortIds:[$sid],minClientVer:"1.8.2"}}}' \
        > "$tmp_json" || die "$(tr_msg dp_trojan_json)"

    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        local seed_json
        seed_json=$(mktemp /tmp/A-Box-xray-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{loglevel:"warning",access:"/var/log/A-Box-xray-access.log",error:"/var/log/A-Box-xray-error.log"},inbounds:[],routing:{rules:[{type:"field",ip:["127.0.0.0/8","::1/128"],outboundTag:"block"}]},outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$seed_json" || { rm -f "$seed_json"; die "$(tr_msg dp_xray_seed)"; }
        prepare_abox_runtime_config_dir xray /usr/local/etc/xray || { rm -f "$seed_json"; die 'Xray config directory creation failed.'; }
        install_file_atomically "$seed_json" "$cfg" 600 || { rm -f "$seed_json"; die "$(tr_msg dp_xray_cfg)"; }
        rm -f "$seed_json"
    fi
    # M-6 rescan: re-strip here -- the seed block above may just
    # have installed a fresh $cfg, which the stripped copy made
    # before the gate does not reflect. The old_port read and the
    # merge below must read the live file as it is now.
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        local tmp_cfg
        # R29b-M3: capture the replaced inbound's port before the merge
        # discards it, so the old port's firewall rules can be recycled
        # below. Only a numeric .port is taken; a range/string port
        # (hand-edited config) is left alone.
        old_port=$(jq -r --arg t "$tag" 'first(.inbounds[]? | select(.tag==$t)) | (if (.port | type) == "number" then (.port | tostring) else empty end)' "$_cfg_stripped" 2>/dev/null || true)
        # R16-F08-02: create the .json target directly with mktemp
        # (O_CREAT|O_EXCL, random suffix); the old reserve+mv derived
        # a predictable name a pre-planted FIFO could block forever.
        local _tcfg_d=''
        _tcfg_d=$(mktemp -d /tmp/A-Box-xray-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        tmp_cfg="$_tcfg_d/config.json"
        if ! jq --arg t "$tag" --slurpfile nb "$tmp_json" \
                '.inbounds = (.inbounds // [])
                 | (.inbounds | map(select(.tag==$t))) as $old
                 | .inbounds |= (
                     map(select(.tag!=$t))
                     + [
                         $nb[] as $new
                         | (
                             ($old | map(select(.tag==$new.tag)) | first) as $ex
                             | if ($ex and ($ex.settings.clients | type == "array") and ($ex.settings.clients | length) > 1
                                    and ($new.settings.clients | type == "array") and ($new.settings.clients | length) > 0) then
                                   $new | .settings.clients = ([$new.settings.clients[0]] + $ex.settings.clients[1:])
                               else $new
                               end
                           )
                       ]
                   )' \
                "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
            rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_tcfg_d"; die "$(tr_msg dp_trojan_update)"
        fi
        jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_tcfg_d"; die "$(tr_msg dp_xray_json)"; }
        # H-07: enforce the loopback guard on the merged config before
        # validation; refuse to install an unguarded config.
        xray_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_tcfg_d"; die 'Xray loopback guard enforcement failed; refusing to install the unguarded config.'; }
        if ! XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp_cfg" >/dev/null 2>&1; then
            msg "${RED}$(tr_msg deploy_xray_trojan_landing_config_check_failed)${NC}"
            XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config "$tmp_cfg" 2>&1 | tail -5
            rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_tcfg_d"; die "$(tr_msg dp_xray_check)"
        fi
        cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
        install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; rm -rf -- "$_tcfg_d"; die "$(tr_msg dp_xray_cfg)"; }
        rm -f "$tmp_cfg"; rm -rf -- "$_tcfg_d"
        prepare_abox_runtime_permissions xray 2>/dev/null || true
        restart_service_soft xray || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft xray 2>/dev/null || true; die "$(tr_msg dp_xray_restart)"; }
    fi
    rm -f "$tmp_json"

    ( allowPort "$port" tcp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft xray 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    save_firewall_rules || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft xray 2>/dev/null || true; _recycle_port_rules_if_unused "$port" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    # R29b-M3: recycle the replaced port's rules when no inbound still
    # uses it (same helper as the sing-box SOCKS5 deploy).
    if [[ "$old_port" =~ ^[0-9]+$ && "$old_port" != "$port" ]]; then
        _recycle_port_rules_if_unused "$old_port" 2>/dev/null || true
    fi
    rm -f -- "$cfg_bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    ensure_service_running_soft xray || die "$(tr_msg dp_xray_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_xj_trojan_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_xray)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    msg "${GREEN}$(tr_msg trojan_done)${NC}"
    msg "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    generate_qr "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    register_standalone_link "${ABOX_DEPLOY_STEM:-trojan-xray}" "$(tprintf sl_node_port 'Trojan-Reality (Xray)' "$port")" "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    # N1: trojan-path REALITY notice (trojan-variant mihomo line; no YAML here).
    show_reality_mlkem_notice 0 1
    # F-NEW-04/CD (U5/NF-06(a)): record the Trojan port so self-heal
    # expects it, then snapshot so the newest trusted backup carries
    # this inbound. Best-effort: the deploy already committed.
    env_set_trojan_port "$port" || msg "${YELLOW}[!] $(tprintf trojan_env_port_fail "$port")${NC}"
    auto_backup_silent "post-deployment snapshot: trojan (xray)" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}

# Standalone Trojan-Reality via sing-box (toolbox entry).
# Mirrors the Xray flow; no API hot-push: config rewrite + `sing-box check` + restart.
deploy_singbox_trojan_landing() {
    local port pass sni pk pbk sid cfg='/etc/sing-box/config.json'
    local tag="${ABOX_DEPLOY_TAG:-trojan-landing}" tmp_json cfg_bak=''
    # SX-TMP: $tmp_json holds the cleartext Trojan password and
    # $cfg_bak a copy of the live config (all credentials); die()
    # exits the process, so only an EXIT trap cleans them on the
    # type-gate die path (same chained idiom as
    # deploy_socks5_landing). Restored on the success path below,
    # once both files are removed explicitly.
    local _sb_trojan_prev_trap_exit='' _sb_trojan_exit_trap_cmd='' _sb_trojan_old_cmd=''
    _sb_trojan_prev_trap_exit=$(trap -p EXIT || true)
    _sb_trojan_exit_trap_cmd='[[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; true'
    if [[ -n "$_sb_trojan_prev_trap_exit" ]]; then
        _sb_trojan_old_cmd="${_sb_trojan_prev_trap_exit#trap -- }"
        _sb_trojan_old_cmd="${_sb_trojan_old_cmd% EXIT}"
        _sb_trojan_exit_trap_cmd="$_sb_trojan_exit_trap_cmd; eval $_sb_trojan_old_cmd"
    fi
    trap "$_sb_trojan_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg trojan_sb_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg trojan_port_prompt)" port '443') || die 'Trojan port input failed.'
    IFS= read -r -p "$(tr_msg trojan_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'Trojan password generation failed.'
        [[ -n "$pass" ]] || die 'Trojan password generation failed.'
    fi

    # Minimal sing-box install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "sing-box trojan-landing"
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-trojan) || die "$(tr_msg dp_sb_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$sb_tmp"
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
        ABOX_DEPLOY_TX_TMP=''
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
    abox_fetch_guard_stop
    # R16-F08-01: a pre-existing binary does not imply a service unit
    # exists (same gap as R7-13 on the SOCKS5 path); ensure it here,
    # before the config merge and restart.
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"

    # R1-09-C01/R10C9-01: function-level seed: the in-branch seed only
    # runs when the binary was missing; a present binary with a missing
    # config must also be seeded before the merge below reads it.
    # Missing/empty/symlink only; a jq-invalid existing config is kept
    # and the merge fails closed, it is not silently seeded over.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi

    # Reality keypair + SNI (reuse A-Box flow).
    local keypair
    keypair=$(/usr/local/bin/sing-box generate reality-keypair) || die "$(tr_msg dp_sb_keypair)"
    IFS=$'\t' read -r pk pbk < <(parse_x25519_keypair_output "$keypair") || die "$(tr_msg dp_sb_keyparse)"
    [[ -n "${pk:-}" && -n "${pbk:-}" ]] || die "$(tr_msg dp_sb_keyempty)"
    sid=$(openssl rand -hex 4 | tr -d '\n\r') || die "$(tr_msg dp_shortid)"
    sni=$(sni_prompt_or_auto)
    valid_sni "$sni" || die "No verified SNI candidate available; refusing to deploy with an empty SNI."

    # Build the trojan+reality inbound object.
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    tmp_json=$(mktemp /tmp/A-Box-sb-trojan-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --rawfile pass <(printf '%s' "$pass") --arg sni "$sni" --arg tag "$tag" --arg listen_addr "$listen_addr" \
        --rawfile pk <(printf '%s' "$pk") --rawfile sid <(printf '%s' "$sid") \
        '{type:"trojan",tag:$tag,listen:$listen_addr,listen_port:$port,
          users:[{password:$pass}],
          tls:{enabled:true,server_name:$sni,
            reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' \
        > "$tmp_json" || die "$(tr_msg dp_trojan_json)"

    local tmp_cfg
    # S-X (R30-M02 same-shape): same guard as ShadowTLS (2dh): an
    # independent inbound that merely shares $tag must not be
    # silently replaced by the merge below; only a single genuine
    # Trojan inbound proceeds. SX-F1: uniqueness gate, not an
    # existence check -- a duplicated tag refuses, because the
    # merge below deletes the whole tag group.
    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the
    # uniqueness gate below and the merge both read the stripped
    # copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_cfg_stripped" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].type == "trojan")' "$_cfg_stripped" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg trojan_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not a Trojan inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    if ! jq --arg t "$tag" --slurpfile nb "$tmp_json" \
            '.inbounds = (.inbounds // [])
             | (.inbounds | map(select(.tag==$t))) as $old
             | .inbounds |= (
                 map(select(.tag!=$t))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array") and ($ex.users | length) > 1
                                and ($new.users | type == "array") and ($new.users | length) > 0) then
                               $new | .users = ([$new.users[0]] + $ex.users[1:])
                           else $new
                           end
                       )
                   ]
               )' \
            "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_trojan_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_check)"; }
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_cfg)"; }
    rm -f "$tmp_cfg" "$tmp_json"
    prepare_abox_runtime_permissions sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; die "$(tr_msg dp_sb_runtime)"; }
    restart_service_soft sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_restart)"; }

    ( allowPort "$port" tcp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    save_firewall_rules || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    rm -f -- "$cfg_bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_sb_trojan_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    msg "${GREEN}$(tr_msg trojan_done)${NC}"
    msg "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    generate_qr "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    register_standalone_link "${ABOX_DEPLOY_STEM:-trojan-sb}" "$(tprintf sl_node_port 'Trojan-Reality (sing-box)' "$port")" "trojan://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Trojan-Reality"
    # F-NEW-04/CD (U5/NF-06(a)): record the Trojan port so self-heal
    # expects it, then snapshot so the newest trusted backup carries
    # this inbound. Best-effort: the deploy already committed.
    env_set_trojan_port "$port" || msg "${YELLOW}[!] $(tprintf trojan_env_port_fail "$port")${NC}"
    auto_backup_silent "post-deployment snapshot: trojan (sing-box)" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}


# TUIC deployment (sing-box only; Xray has no TUIC inbound).
# Modeled on deploy_singbox_trojan_landing: standalone inbound merged into the
# live sing-box config by tag, validated with `sing-box check` before install.
deploy_singbox_tuic() {
    local port pass uuid sni cc cfg='/etc/sing-box/config.json'
    local tag="${ABOX_DEPLOY_TAG:-tuic-in}" tmp_json cfg_bak=''
    # SX-TMP (M-1): $tmp_json holds the cleartext password / REALITY
    # private key and $cfg_bak a copy of the live config (all
    # credentials); die() exits the process, so only an EXIT trap
    # cleans them on the gate / post-install die paths (same chained
    # idiom as deploy_socks5_landing). Restored on the success path
    # below, once both files are removed explicitly. The trap saves
    # $? in _ec first and restores it with (exit "$_ec") before
    # chaining the previous trap, so the outer trap still sees the
    # real exit code instead of the cleanup's status.
    local _sb_tuic_prev_trap_exit='' _sb_tuic_exit_trap_cmd='' _sb_tuic_old_cmd=''
    _sb_tuic_prev_trap_exit=$(trap -p EXIT || true)
    _sb_tuic_exit_trap_cmd='local _ec=$?; [[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; (exit "$_ec")'
    if [[ -n "$_sb_tuic_prev_trap_exit" ]]; then
        _sb_tuic_old_cmd="${_sb_tuic_prev_trap_exit#trap -- }"
        _sb_tuic_old_cmd="${_sb_tuic_old_cmd% EXIT}"
        _sb_tuic_exit_trap_cmd="$_sb_tuic_exit_trap_cmd; eval $_sb_tuic_old_cmd"
    fi
    trap "$_sb_tuic_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg tuic_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg tuic_port_prompt)" port '443' udp) || die 'TUIC port input failed.'
    IFS= read -r -p "$(tr_msg tuic_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'TUIC password generation failed.'
        [[ -n "$pass" ]] || die 'TUIC password generation failed.'
    fi
    local cc_choice=''
    read -r -p "$(tr_msg tuic_cc_prompt)" cc_choice || cc_choice=''
    cc_choice=$(normalize_fa_ar_digits "$cc_choice")
    case "$cc_choice" in
        1|'') cc='bbr' ;;
        2) cc='cubic' ;;
        3) cc='new_reno' ;;
        *) die "$(tr_msg invalid_input): $cc_choice" ;;
    esac
    uuid=$(generate_robust_uuid) || die 'TUIC UUID generation failed.'

    # Minimal sing-box install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "sing-box tuic"
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-tuic) || die "$(tr_msg dp_sb_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$sb_tmp"
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
        ABOX_DEPLOY_TX_TMP=''
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
    abox_fetch_guard_stop
    # R16-F08-01: a pre-existing binary does not imply a service unit
    # exists (same gap as R7-13 on the SOCKS5 path); ensure it here,
    # before the config merge and restart.
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"

    # R1-09-C01/R10C9-01: function-level seed: the in-branch seed only
    # runs when the binary was missing; a present binary with a missing
    # config must also be seeded before the merge below reads it.
    # Missing/empty/symlink only; a jq-invalid existing config is kept
    # and the merge fails closed, it is not silently seeded over.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi

    # Self-signed TLS cert (TUIC requires TLS; clients pin/skip-verify).
    # U37: per-tag cert files; deploying a new TUIC node must not overwrite
    # the cert an existing node already pinned. Unsafe tag characters are
    # sanitized, with a hash suffix always appended, so
    # distinct tags can never collide on one file.
    sni=$(sni_prompt_or_auto 'TUIC')
    valid_sni "$sni" || die "No verified SNI candidate available; refusing to deploy with an empty SNI."
    local _tuic_cert_tag _tuic_key _tuic_crt
    _tuic_cert_tag=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_-' '_')
    _tuic_cert_tag="${_tuic_cert_tag}-$(printf '%s' "$tag" | sha256sum | cut -c1-8)"
    _tuic_key="/etc/sing-box/tuic-${_tuic_cert_tag}.key"
    _tuic_crt="/etc/sing-box/tuic-${_tuic_cert_tag}.crt"
    # R30-M03: determine the listen address BEFORE replacing the cert:
    # a failure here must die before any mutation, so no certificate
    # rollback is needed on this path.
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    # LOW-2: uniqueness gate runs BEFORE any cert backup/generation, so
    # a refused redeploy leaves the live cert/key byte-identical and no
    # rollback is needed on this path.
    # R30-M02: same guard as ShadowTLS (2dh): an independent inbound
    # that merely shares $tag must not be silently replaced by the
    # merge below; only a single genuine TUIC inbound proceeds.
    # R-1 (SX-F1 same-shape): uniqueness gate, not an existence
    # check -- a duplicated tag refuses, because the merge below
    # deletes the whole tag group.
    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the
    # uniqueness gate below and the merge both read the stripped
    # copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_cfg_stripped" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].type == "tuic")' "$_cfg_stripped" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg tuic_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not a TUIC inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    # H-2 (Gemini) dim 3: drop stale tuic-*.A-Box-bak files left by an
    # earlier failed deploy, but only when no live inbound still
    # references the underlying cert/key path -- a referenced backup is
    # the last-good copy for the live inbound and must survive. An
    # unreadable config keeps every backup (fail-closed).
    _tuic_cleanup_stale_backups "$cfg"
    # Back up any existing cert pair before regenerating: sing-box
    # check requires the new cert in place, so generation cannot be
    # deferred past the commit point. An existing .bak is kept (it
    # holds the last good cert from an earlier failed deploy); the
    # backups are removed only after full success.
    if [[ -f "$_tuic_key" && ! -f "${_tuic_key}.A-Box-bak" ]]; then
        cp -a -- "$_tuic_key" "${_tuic_key}.A-Box-bak" && chmod 600 -- "${_tuic_key}.A-Box-bak" || die 'TUIC key backup failed; refusing to overwrite the live key without a backup.'
    fi
    if [[ -f "$_tuic_crt" && ! -f "${_tuic_crt}.A-Box-bak" ]]; then
        cp -a -- "$_tuic_crt" "${_tuic_crt}.A-Box-bak" && chmod 600 -- "${_tuic_crt}.A-Box-bak" || die 'TUIC cert backup failed; refusing to overwrite the live cert without a backup.'
    fi
    generate_self_signed_cert_atomically "$_tuic_key" "$_tuic_crt" "$sni" \
        || die "$(tr_msg dp_tuic_cert)"

    # Build the TUIC inbound object.
    tmp_json=$(mktemp /tmp/A-Box-sb-tuic-inbound.XXXXXX) || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_tmpfile)"; }
    jq -n --argjson port "$port" --rawfile uuid <(printf '%s' "$uuid") --rawfile pass <(printf '%s' "$pass") --arg sni "$sni" --arg cc "$cc" --arg tag "$tag" --arg cert "$_tuic_crt" --arg key "$_tuic_key" --arg listen_addr "$listen_addr" \
        '{type:"tuic",tag:$tag,listen:$listen_addr,listen_port:$port,
          users:[{uuid:$uuid,password:$pass}],
          congestion_control:$cc,
          tls:{enabled:true,server_name:$sni,alpn:["h3"],
            certificate_path:$cert,key_path:$key}}' \
        > "$tmp_json" || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_tuic_json)"; }

    local tmp_cfg
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_tmpfile)"; }
    if ! jq --slurpfile nb "$tmp_json" --arg t "$tag" \
            '.inbounds = (.inbounds // [])
             | (.inbounds | map(select(.tag==$t))) as $old
             | .inbounds |= (
                 map(select(.tag!=$t))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array") and ($ex.users | length) > 1
                                and ($new.users | type == "array") and ($new.users | length) > 0) then
                               $new | .users = ([$new.users[0]] + $ex.users[1:])
                           else $new
                           end
                       )
                   ]
               )' \
            "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_tuic_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_sb_check)"; }
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die "$(tr_msg dp_tmpfile)"; }
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" '' "$cfg"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; restore_tuic_backups "$_tuic_key" "$_tuic_crt" "$cfg_bak" "$cfg"; die "$(tr_msg dp_sb_cfg)"; }
    rm -f "$tmp_cfg" "$tmp_json"
    prepare_abox_runtime_permissions sing-box || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" "$cfg_bak" "$cfg"; die "$(tr_msg dp_sb_runtime)"; }
    restart_service_soft sing-box || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" "$cfg_bak" "$cfg"; die "$(tr_msg dp_sb_restart)"; }

    ( allowPort "$port" udp ) || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" "$cfg_bak" "$cfg"; restart_service_soft sing-box 2>/dev/null || msg "${RED}[!] $(tr_msg rollback_restart_fail)${NC}"; die "$(tprintf dp_fw_allow "${port}/udp")"; }
    save_firewall_rules || { restore_tuic_backups "$_tuic_key" "$_tuic_crt" "$cfg_bak" "$cfg"; restart_service_soft sing-box 2>/dev/null || msg "${RED}[!] $(tr_msg rollback_restart_fail)${NC}"; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    rm -f -- "$cfg_bak" "${_tuic_key}.A-Box-bak" "${_tuic_crt}.A-Box-bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_sb_tuic_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    local link="tuic://${uuid}:$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?congestion_control=${cc}&alpn=h3&sni=${sni}&allow_insecure=1#TUIC"
    msg "${GREEN}$(tr_msg tuic_done)${NC}"
    msg "$link"
    generate_qr "$link"
    register_standalone_link "${ABOX_DEPLOY_STEM:-tuic}" "$(tprintf sl_node_port 'TUIC' "$port")" "$link"
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    auto_backup_silent "post-deployment snapshot: tuic" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}


# AnyTLS deployment (sing-box only; Xray has no AnyTLS inbound).
# AnyTLS + REALITY, same shape as deploy_singbox_trojan_landing: standalone
# inbound merged into the live sing-box config by tag, `sing-box check` first.
deploy_singbox_anytls() {
    local port pass sni pk pbk sid cfg='/etc/sing-box/config.json'
    local tag="${ABOX_DEPLOY_TAG:-anytls-in}" tmp_json cfg_bak=''
    # SX-TMP (M-1): $tmp_json holds the cleartext password / REALITY
    # private key and $cfg_bak a copy of the live config (all
    # credentials); die() exits the process, so only an EXIT trap
    # cleans them on the gate / post-install die paths (same chained
    # idiom as deploy_socks5_landing). Restored on the success path
    # below, once both files are removed explicitly. The trap saves
    # $? in _ec first and restores it with (exit "$_ec") before
    # chaining the previous trap, so the outer trap still sees the
    # real exit code instead of the cleanup's status.
    local _sb_anytls_prev_trap_exit='' _sb_anytls_exit_trap_cmd='' _sb_anytls_old_cmd=''
    _sb_anytls_prev_trap_exit=$(trap -p EXIT || true)
    _sb_anytls_exit_trap_cmd='local _ec=$?; [[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; (exit "$_ec")'
    if [[ -n "$_sb_anytls_prev_trap_exit" ]]; then
        _sb_anytls_old_cmd="${_sb_anytls_prev_trap_exit#trap -- }"
        _sb_anytls_old_cmd="${_sb_anytls_old_cmd% EXIT}"
        _sb_anytls_exit_trap_cmd="$_sb_anytls_exit_trap_cmd; eval $_sb_anytls_old_cmd"
    fi
    trap "$_sb_anytls_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg anytls_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg anytls_port_prompt)" port '443') || die 'AnyTLS port input failed.'
    IFS= read -r -p "$(tr_msg anytls_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'AnyTLS password generation failed.'
        [[ -n "$pass" ]] || die 'AnyTLS password generation failed.'
    fi

    # Minimal sing-box install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "sing-box anytls"
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-anytls) || die "$(tr_msg dp_sb_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$sb_tmp"
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
        ABOX_DEPLOY_TX_TMP=''
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
    abox_fetch_guard_stop
    # R16-F08-01: a pre-existing binary does not imply a service unit
    # exists (same gap as R7-13 on the SOCKS5 path); ensure it here,
    # before the config merge and restart.
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"

    # R1-09-C01/R10C9-01: function-level seed: the in-branch seed only
    # runs when the binary was missing; a present binary with a missing
    # config must also be seeded before the merge below reads it.
    # Missing/empty/symlink only; a jq-invalid existing config is kept
    # and the merge fails closed, it is not silently seeded over.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi

    # Reality keypair + SNI (reuse A-Box flow).
    local keypair
    keypair=$(/usr/local/bin/sing-box generate reality-keypair) || die "$(tr_msg dp_sb_keypair)"
    IFS=$'\t' read -r pk pbk < <(parse_x25519_keypair_output "$keypair") || die "$(tr_msg dp_sb_keyparse)"
    [[ -n "${pk:-}" && -n "${pbk:-}" ]] || die "$(tr_msg dp_sb_keyempty)"
    sid=$(openssl rand -hex 4 | tr -d '\n\r') || die "$(tr_msg dp_shortid)"
    sni=$(sni_prompt_or_auto 'AnyTLS')
    valid_sni "$sni" || die "No verified SNI candidate available; refusing to deploy with an empty SNI."

    # M-1: uniqueness gate runs BEFORE $tmp_json is written, so a
    # refused redeploy leaves no secret temp file behind.
    # R30-M02: same guard as ShadowTLS (2dh): an independent inbound
    # that merely shares $tag must not be silently replaced by the
    # merge below; only a single genuine AnyTLS inbound proceeds.
    # R-1 (SX-F1 same-shape): uniqueness gate, not an existence
    # check -- a duplicated tag refuses, because the merge below
    # deletes the whole tag group.
    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the
    # uniqueness gate below and the merge both read the stripped
    # copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_cfg_stripped" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].type == "anytls")' "$_cfg_stripped" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg anytls_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not an AnyTLS inbound) or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    # Build the anytls+reality inbound object.
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    tmp_json=$(mktemp /tmp/A-Box-sb-anytls-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --rawfile pass <(printf '%s' "$pass") --arg sni "$sni" --arg tag "$tag" --arg listen_addr "$listen_addr" \
        --rawfile pk <(printf '%s' "$pk") --rawfile sid <(printf '%s' "$sid") \
        '{type:"anytls",tag:$tag,listen:$listen_addr,listen_port:$port,
          users:[{name:"main",password:$pass}],
          tls:{enabled:true,server_name:$sni,
            reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' \
        > "$tmp_json" || die "$(tr_msg dp_anytls_json)"

    local tmp_cfg
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    if ! jq --arg t "$tag" --slurpfile nb "$tmp_json" \
            '.inbounds = (.inbounds // [])
             | (.inbounds | map(select(.tag==$t))) as $old
             | .inbounds |= (
                 map(select(.tag!=$t))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array") and ($ex.users | length) > 1
                                and ($new.users | type == "array") and ($new.users | length) > 0) then
                               $new | .users = ([$new.users[0]] + $ex.users[1:])
                           else $new
                           end
                       )
                   ]
               )' \
            "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_anytls_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_check)"; }
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_cfg)"; }
    rm -f "$tmp_cfg" "$tmp_json"
    prepare_abox_runtime_permissions sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; die "$(tr_msg dp_sb_runtime)"; }
    restart_service_soft sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_restart)"; }

    ( allowPort "$port" tcp ) || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    save_firewall_rules || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    rm -f -- "$cfg_bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_sb_anytls_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    local link="anytls://$(urlencode "$pass")@$(uri_host "$pub_ip"):${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}#AnyTLS-Reality"
    msg "${GREEN}$(tr_msg anytls_done)${NC}"
    msg "$link"
    generate_qr "$link"
    register_standalone_link "${ABOX_DEPLOY_STEM:-anytls}" "$(tprintf sl_node_port 'AnyTLS-Reality' "$port")" "$link"
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    auto_backup_silent "post-deployment snapshot: anytls" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}



deploy_singbox_shadowtls() {
    local port pass inner sni cfg='/etc/sing-box/config.json'
    local tag="${ABOX_DEPLOY_TAG:-shadowtls-in}" tmp_json
    local itag='shadowtls-ss'; [[ "$tag" != 'shadowtls-in' ]] && itag="${tag}-ss"
    # SX-TMP (M-1): $tmp_json holds the cleartext password / REALITY
    # private key and $cfg_bak a copy of the live config (all
    # credentials); die() exits the process, so only an EXIT trap
    # cleans them on the gate / post-install die paths (same chained
    # idiom as deploy_socks5_landing). Restored on the success path
    # below, once both files are removed explicitly. The trap saves
    # $? in _ec first and restores it with (exit "$_ec") before
    # chaining the previous trap, so the outer trap still sees the
    # real exit code instead of the cleanup's status.
    local _sb_sh_prev_trap_exit='' _sb_sh_exit_trap_cmd='' _sb_sh_old_cmd=''
    _sb_sh_prev_trap_exit=$(trap -p EXIT || true)
    _sb_sh_exit_trap_cmd='local _ec=$?; [[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_jq_cfg:-}" ]] && (( ${_jq_tmp:-0} == 1 )) && rm -f -- "$_jq_cfg" 2>/dev/null; (exit "$_ec")'
    if [[ -n "$_sb_sh_prev_trap_exit" ]]; then
        _sb_sh_old_cmd="${_sb_sh_prev_trap_exit#trap -- }"
        _sb_sh_old_cmd="${_sb_sh_old_cmd% EXIT}"
        _sb_sh_exit_trap_cmd="$_sb_sh_exit_trap_cmd; eval $_sb_sh_old_cmd"
    fi
    trap "$_sb_sh_exit_trap_cmd" EXIT
    clear; msg "${BOLD}${GREEN}$(tr_msg shadowtls_title)${NC}"
    init_system_environment
    load_optional_abox_env_or_die
    light_preflight_check

    port=$(prompt_validated "$(tr_msg shadowtls_port_prompt)" port '443') || die 'ShadowTLS port input failed.'
    IFS= read -r -p "$(tr_msg shadowtls_pass_prompt)" pass || die "$(tr_msg pi_input_closed)"
    if [[ -z "$pass" ]]; then
        pass=$(rand_alnum 16) || die 'ShadowTLS password generation failed.'
        [[ -n "$pass" ]] || die 'ShadowTLS password generation failed.'
    fi
    inner=$(openssl rand -base64 16 | tr -d '\n\r') || die 'ShadowTLS SS password generation failed.'
    [[ -n "$inner" ]] || die 'ShadowTLS SS password generation failed.'

    # Minimal sing-box install when the binary is missing.
    # S1-Low-B (final-round follow-up): arm the same [fetch] segment
    # guard as the main-stack deploys (B-C2), so a hung core download
    # here is bounded by the 300s budget and logged the same way.
    abox_fetch_guard_start "sing-box shadowtls"
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        singbox_vendor_takeover_gate || die 'sing-box vendor takeover declined or backup failed.'
        local sb_tmp sb_tar sb_ext SB_PATH
        get_architecture
        sb_tmp=$(abox_mktemp_exec_dir A-Box-singbox-shadowtls) || die "$(tr_msg dp_sb_tmpdir)"
        ABOX_DEPLOY_TX_TMP="$sb_tmp"
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
        ABOX_DEPLOY_TX_TMP=''
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
    abox_fetch_guard_stop
    # R16-F08-01: a pre-existing binary does not imply a service unit
    # exists (same gap as R7-13 on the SOCKS5 path); ensure it here,
    # before the config merge and restart.
    ensure_singbox_service_unit || die "$(tr_msg dp_sb_unit)"

    # R1-09-C01/R10C9-01: function-level seed: the in-branch seed only
    # runs when the binary was missing; a present binary with a missing
    # config must also be seeded before the merge below reads it.
    # Missing/empty/symlink only; a jq-invalid existing config is kept
    # and the merge fails closed, it is not silently seeded over.
    if [[ ! -f "$cfg" || -L "$cfg" || ! -s "$cfg" ]]; then
        tmp_json=$(mktemp /tmp/A-Box-singbox-seed.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        jq -n '{log:{level:"warn",timestamp:true,output:"/var/log/A-Box-singbox.log"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_json" \
            || die "$(tr_msg dp_sb_seed)"
        install_file_atomically "$tmp_json" "$cfg" 600 || die "$(tr_msg dp_sb_cfg)"
        rm -f "$tmp_json"
    fi

    sni=$(sni_prompt_or_auto 'ShadowTLS')
    valid_sni "$sni" || die "No verified SNI candidate available; refusing to deploy with an empty SNI."

    # shadowtls v3 (strict) detouring to a loopback-only SS-2022 inbound that
    # has no listen_port of its own (reachable only through the detour).
    local listen_addr
    listen_addr=$(wildcard_listen_address) || die 'Failed to determine the wildcard listen address.'
    # M-6-rescan (D-leg): read the live config through a JSONC-stripped
    # snapshot (same _jq_cfg pattern as users_adopt): raw jq on a
    # commented config fails the uniqueness gates AND the merge below.
    # The snapshot is taken after the seed above, so it is current for
    # both; the merge input switches to it as well. On strip failure
    # fall back to the raw file (strip failure != read failure);
    # _jq_tmp marks whether _jq_cfg is a temp file (safe to delete).
    local _jq_cfg='' _jq_tmp=0
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-sb-shadowtls-json.XXXXXX) || _jq_cfg=''
        if [[ -n "$_jq_cfg" ]] && jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null; then
            _jq_tmp=1
        else
            [[ -n "$_jq_cfg" ]] && rm -f -- "$_jq_cfg"
            _jq_cfg="$cfg"
        fi
    else
        _jq_cfg="$cfg"
    fi
    # M-1: uniqueness gate runs BEFORE $tmp_json is written, so a
    # refused redeploy leaves no secret temp file behind.
    # 2dh: same guard as R14C9-01, for the outer tag. An independent
    # inbound that merely shares $tag must not be silently replaced by
    # the merge below; only a single existing ShadowTLS pair (or an
    # unoccupied tag) proceeds. The "updating its config" notice is
    # shown only for the genuine pair.
    # R-1 (SX-F1 same-shape): uniqueness gate, not an existence
    # check -- a duplicated tag refuses, because the merge below
    # deletes the whole tag group.
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$_jq_cfg" >/dev/null 2>&1; then
        if jq -e --arg t "$tag" --arg it "$itag" '[.inbounds[]? | select(.tag==$t)] as $same | (($same | length) == 1 and $same[0].type == "shadowtls" and $same[0].detour == $it)' "$_jq_cfg" >/dev/null 2>&1; then
            msg "${YELLOW}$(tr_msg shadowtls_exists)${NC}"
        else
            die "Tag '$tag' is already used by an independent inbound (not part of a ShadowTLS pair with '$itag') or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    # R14C9-01: refuse if the companion tag is already used by an inbound
    # that is not part of the existing ShadowTLS pair with $tag; the merge
    # below would otherwise silently destroy that independent inbound.
    # A jq read failure (invalid config) skips the check and lets the
    # merge fail closed as before; only a confirmed conflict refuses.
    if jq -e --arg it "$itag" '.inbounds[]? | select(.tag==$it)' "$_jq_cfg" >/dev/null 2>&1; then
        if ! jq -e --arg t "$tag" --arg it "$itag" '.inbounds[]? | select(.tag==$t and .type=="shadowtls" and .detour==$it)' "$_jq_cfg" >/dev/null 2>&1; then
            die "Companion tag '$itag' is already used by an independent inbound (not part of a ShadowTLS pair with '$tag'); refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
        # R-1 (SX-F1 same-shape): the pair check above is an existence
        # check; a duplicated companion tag still passes it, and the
        # merge below deletes the whole companion group. Require
        # exactly one companion object of type shadowsocks.
        if ! jq -e --arg it "$itag" '[.inbounds[]? | select(.tag==$it)] as $same | (($same | length) == 1 and $same[0].type == "shadowsocks")' "$_jq_cfg" >/dev/null 2>&1; then
            die "Companion tag '$itag' is already used by an independent inbound (not part of a ShadowTLS pair with '$tag') or appears more than once; refusing to replace it. Remove or rename that inbound, or deploy with a different tag."
        fi
    fi
    tmp_json=$(mktemp /tmp/A-Box-sb-shadowtls-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --argjson port "$port" --rawfile pass <(printf '%s' "$pass") --rawfile inner <(printf '%s' "$inner") --arg sni "$sni" --arg tag "$tag" --arg itag "$itag" --arg listen_addr "$listen_addr" \
        '({type:"shadowtls",tag:$tag,listen:$listen_addr,listen_port:$port,version:3,strict_mode:true,
           users:[{password:$pass}],handshake:{server:$sni,server_port:443},detour:$itag}),
         ({type:"shadowsocks",tag:$itag,listen:"127.0.0.1",network:"tcp",
           method:"2022-blake3-aes-128-gcm",password:$inner,multiplex:{enabled:true,padding:true}})' \
        > "$tmp_json" || die "$(tr_msg dp_shadowtls_json)"

    local tmp_cfg cfg_bak=''
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    if ! jq --slurpfile nb "$tmp_json" --arg t "$tag" --arg it "$itag" \
            '.inbounds = (.inbounds // [])
             | (.inbounds | map(select(.tag==$t or .tag==$it))) as $old
             | .inbounds |= (
                 map(select(.tag!=$t and .tag!=$it))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array") and ($ex.users | length) > 1
                                and ($new.users | type == "array") and ($new.users | length) > 0) then
                               $new | .users = ([$new.users[0]] + $ex.users[1:])
                           else $new
                           end
                       )
                   ]
               )' \
            "$_jq_cfg" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_shadowtls_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_check)"; }
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
        cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; cfg_bak=''; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    fi
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json"; [[ -n "$cfg_bak" ]] && rm -f -- "$cfg_bak"; die "$(tr_msg dp_sb_cfg)"; }
    prepare_abox_runtime_permissions sing-box || { if [[ -n "$cfg_bak" ]]; then restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; fi; die "$(tr_msg dp_sb_runtime)"; }
    rm -f "$tmp_cfg" "$tmp_json"

    restart_service_soft sing-box || { if [[ -n "$cfg_bak" ]]; then restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; fi; die "$(tr_msg dp_sb_restart)"; }
    ( allowPort "$port" tcp ) || { if [[ -n "$cfg_bak" ]]; then if restore_cfg_backup "$cfg_bak" "$cfg"; then restart_service_soft sing-box 2>/dev/null || msg "${RED}[!] $(tr_msg rollback_restart_fail)${NC}"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; fi; die "$(tprintf dp_fw_allow "${port}/tcp")"; }
    save_firewall_rules || { if [[ -n "$cfg_bak" ]]; then if restore_cfg_backup "$cfg_bak" "$cfg"; then restart_service_soft sing-box 2>/dev/null || msg "${RED}[!] $(tr_msg rollback_restart_fail)${NC}"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi; fi; _recycle_port_rules_if_unused "$port" "$cfg" 2>/dev/null || true; die "$(tr_msg pi_fw_persist_fail)"; }
    [[ -n "$cfg_bak" ]] && rm -f -- "$cfg_bak"
    (( ${_jq_tmp:-0} == 1 )) && rm -f -- "$_jq_cfg" 2>/dev/null || true
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_sb_sh_prev_trap_exit"
    set_desired_state RUNNING || die "$(tr_msg dp_desired_sb)"

    local pub_ip
    pub_ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip=$(get_public_ip_fresh 2>/dev/null || true)
    [[ -n "$pub_ip" ]] || pub_ip='<server-ip>'
    local user_b64 plugin_b64
    user_b64=$(printf '%s' "2022-blake3-aes-128-gcm:${inner}@$(uri_host "$pub_ip"):${port}" | base64 | tr -d '\n\r')
    plugin_b64=$(jq -cn --arg h "$sni" --rawfile p <(printf '%s' "$pass") '{version:"3", host:$h, password:$p}' | base64 | tr -d '\n\r')
    local link="ss://${user_b64}?shadow-tls=${plugin_b64}#ShadowTLS"
    msg "${GREEN}$(tr_msg shadowtls_done)${NC}"
    msg "$link"
    local yq_inner yq_sni yq_pass
    yq_inner="'${inner//\'/\'\'}'"; yq_sni="'${sni//\'/\'\'}'"; yq_pass="'${pass//\'/\'\'}'"
    msg "Clash: - {name: \"ShadowTLS\", type: ss, server: ${pub_ip}, port: ${port}, cipher: 2022-blake3-aes-128-gcm, password: ${yq_inner}, plugin: shadow-tls, client-fingerprint: chrome, plugin-opts: {host: ${yq_sni}, password: ${yq_pass}, version: 3}}"
    generate_qr "$link"
    register_standalone_link "${ABOX_DEPLOY_STEM:-shadowtls}" "$(tprintf sl_node_port 'ShadowTLS' "$port")" "$link"
    ( setup_active_defense ) || msg "${YELLOW}[!] $(tr_msg defense_mount_fail)${NC}"
    auto_backup_silent "post-deployment snapshot: shadowtls" || msg "${YELLOW}[!] $(tr_msg bk_postdeploy_fail)${NC}"
    # S2-NEW-03: refresh the subscription export so the deployed node
    # set is what subscribers see; without this the files keep serving
    # dead links until menu E. Best-effort (see helper): the deploy
    # already committed, so an export failure warns but must not fail it.
    refresh_subscription_after_deploy || true
}

# ================= Argo / CDN front (sing-box WS + cloudflared) =================
CLOUDFLARED_VERSION='2026.10.2'
CLOUDFLARED_SHA256_AMD64='35fbdd2beb378436c7da377d7358cea8e33f9c94a6705d1d8036bf9b0d6d8005'
CLOUDFLARED_SHA256_ARM64='b7e55b4d9702c2ab5f8348f780bb1db044527fc555367714c78e0595750a4665'
# Wallos HTTPS front (Caddy). Tarball SHA256 pins; the tarballs were
# cross-verified against Caddy's official SHA512 checksums file.
WALLOS_CADDY_VERSION='2.11.7'
WALLOS_CADDY_SHA256_AMD64='727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b'
WALLOS_CADDY_SHA256_ARM64='d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42'
WALLOS_CADDY_LOG='/var/log/A-Box-wallos-caddy.log'
WALLOS_CF_TOKEN_FILE='/etc/ddr/.wallos-cf-token'
ARGO_STATE_FILE='/etc/ddr/.argo-state'
ARGO_UUID='' ARGO_VMESS_PORT='' ARGO_VLESS_PORT=''

_argo_state_get() {
    [[ -f "$ARGO_STATE_FILE" && ! -L "$ARGO_STATE_FILE" ]] || return 0
    awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ARGO_STATE_FILE" 2>/dev/null
}

_argo_state_write() { # $1 = full file content
    mkdir -p /etc/ddr || die "$(tr_msg ag_state_dir)"
    local tmp_f
    tmp_f=$(mktemp /tmp/A-Box-argo-state.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    printf '%s\n' "$1" > "$tmp_f" || { rm -f "$tmp_f"; die "$(tr_msg ag_state_write)"; }
    install_file_atomically "$tmp_f" "$ARGO_STATE_FILE" 600 || { rm -f "$tmp_f"; die "$(tr_msg ag_state_atomic)"; }
    rm -f "$tmp_f"
}

install_cloudflared() {
    local _cf_installed=''
    _cf_installed=$(/usr/local/bin/cloudflared --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [[ -x /usr/local/bin/cloudflared && "$_cf_installed" == "$CLOUDFLARED_VERSION" ]]; then
        return 0
    fi
    get_architecture
    local want='' url='' tmp got
    case "$SB_ARCH" in
        amd64) want="$CLOUDFLARED_SHA256_AMD64" ;;
        arm64) want="$CLOUDFLARED_SHA256_ARM64" ;;
        *) die "$(tprintf cf_arch "$SB_ARCH")" ;;
    esac
    url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${SB_ARCH}"
    tmp=$(abox_mktemp_exec_dir A-Box-cloudflared) || die "$(tr_msg cf_tmp)"
    # M-1: register the staging dir so die() cleans it if a later
    # step in this download fails (defence in depth: every die
    # branch below already removes "$tmp" explicitly).
    ABOX_DEPLOY_TX_TMP="$tmp"
    msg "$(tr_msg argo_cf_installing)"
    if ! fetch_util_mirror_asset "cloudflared-${CLOUDFLARED_VERSION}-linux-${SB_ARCH}" "$tmp/cloudflared" \
        || [[ "$(sha256sum "$tmp/cloudflared" 2>/dev/null | awk '{print $1}')" != "$want" ]]; then
        if ! curl -fL --proto =https --proto-redir =https --retry 2 --connect-timeout 15 -o "$tmp/cloudflared" "$url"; then
            rm -rf "$tmp"; die "$(tr_msg cf_download)"
        fi
    fi
    got=$(sha256sum "$tmp/cloudflared" 2>/dev/null | awk '{print $1}')
    if [[ "$got" != "$want" ]]; then
        rm -rf "$tmp"; die "$(tr_msg cf_sha)"
    fi
    chmod 755 "$tmp/cloudflared" || { rm -rf "$tmp"; die "$(tr_msg cf_chmod)"; }
    "$tmp/cloudflared" --version >/dev/null 2>&1 || { rm -rf "$tmp"; die "$(tr_msg cf_exec)"; }
    install_binary_atomically "$tmp/cloudflared" /usr/local/bin/cloudflared || { rm -rf "$tmp"; die "$(tr_msg cf_install)"; }
    # R7C9-01: record A-Box ownership so uninstall can tell an
    # A-Box-installed binary from a foreign same-version one
    # that install_cloudflared early-returned on. Best-effort:
    # if the marker cannot be written, uninstall conservatively
    # keeps the binary instead of deleting a possibly foreign one.
    touch /etc/ddr/.abox-cloudflared-owned 2>/dev/null || true
    rm -rf "$tmp"
    ABOX_DEPLOY_TX_TMP=''
}

_argo_pick_port() {
    # Optional $1: a port that must never be returned (the caller's
    # already-picked peer port). An ss failure fails closed: a query
    # error must never read as "port free" (the old pipeline yielded
    # no output on ss errors, and grep's no-match meant "free").
    local p tries=0 ss_out exclude="${1:-}"
    while (( tries < 40 )); do
        # R7C9-04: when shuf is missing/broken the old constant
        # fallback (28080) retried the same port 40 times: abort
        # whenever 28080 was occupied or excluded. Fall back to
        # $RANDOM picks in range instead.
        p=$(shuf -i 20000-55000 -n 1 2>/dev/null || printf '%s' $((20000 + RANDOM % 35001)))
        if [[ -n "$exclude" && "$exclude" =~ ^[0-9]+$ ]] && (( p == exclude )); then
            tries=$((tries + 1))
            continue
        fi
        ss_out=$(ss -lnt 2>/dev/null) || return 1
        # R14-F09-01: no `grep -q` here. Under global pipefail, grep -q
        # exits on the first match; with a large listen table and an
        # early match the upstream awk/printf die on SIGPIPE (rc 141),
        # which `!` then reads as "port free" and returns an occupied
        # port. A plain grep drains the whole stream, so no SIGPIPE.
        if ! printf '%s\n' "$ss_out" | awk '{print $4}' | grep ":${p}\$" >/dev/null; then
            printf '%s' "$p"; return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

# Build/refresh the two loopback WS inbounds in the sing-box config.
argo_deploy_ws() {
    local cfg='/etc/sing-box/config.json' tmp_json tmp_cfg cfg_bak=''
    # SX-TMP (M-1): $tmp_json holds the cleartext password / REALITY
    # private key and $cfg_bak a copy of the live config (all
    # credentials); die() exits the process, so only an EXIT trap
    # cleans them on the gate / post-install die paths (same chained
    # idiom as deploy_socks5_landing). Restored on the success path
    # below, once both files are removed explicitly. The trap saves
    # $? in _ec first and restores it with (exit "$_ec") before
    # chaining the previous trap, so the outer trap still sees the
    # real exit code instead of the cleanup's status.
    local _argo_ws_prev_trap_exit='' _argo_ws_exit_trap_cmd='' _argo_ws_old_cmd=''
    _argo_ws_prev_trap_exit=$(trap -p EXIT || true)
    _argo_ws_exit_trap_cmd='local _ec=$?; [[ -n "${tmp_json:-}" ]] && rm -f -- "$tmp_json" 2>/dev/null; [[ -n "${cfg_bak:-}" ]] && rm -f -- "$cfg_bak" 2>/dev/null; [[ -n "${tmp_cfg:-}" ]] && rm -f -- "$tmp_cfg" 2>/dev/null; [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null; (exit "$_ec")'
    if [[ -n "$_argo_ws_prev_trap_exit" ]]; then
        _argo_ws_old_cmd="${_argo_ws_prev_trap_exit#trap -- }"
        _argo_ws_old_cmd="${_argo_ws_old_cmd% EXIT}"
        _argo_ws_exit_trap_cmd="$_argo_ws_exit_trap_cmd; eval $_argo_ws_old_cmd"
    fi
    trap "$_argo_ws_exit_trap_cmd" EXIT
    ARGO_UUID=$(_argo_state_get uuid)
    if [[ ! "$ARGO_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; then
        ARGO_UUID=$(generate_robust_uuid) || die "$(tr_msg ag_uuid)"
    fi
    ARGO_VMESS_PORT=$(_argo_state_get vmess_port)
    [[ "$ARGO_VMESS_PORT" =~ ^[0-9]+$ ]] || ARGO_VMESS_PORT=$(_argo_pick_port) || die "$(tr_msg ag_vmess_port)"
    ARGO_VLESS_PORT=$(_argo_state_get vless_port)
    if [[ ! "$ARGO_VLESS_PORT" =~ ^[0-9]+$ || "$ARGO_VLESS_PORT" == "$ARGO_VMESS_PORT" ]]; then
        # Re-pick with the VMESS port excluded: a +1 fallback would
        # never be occupancy-checked, so it is deleted, not repaired.
        ARGO_VLESS_PORT=$(_argo_pick_port "$ARGO_VMESS_PORT") || die "$(tr_msg ag_vless_port)"
    fi
    tmp_json=$(mktemp /tmp/A-Box-sb-argo-inbound.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jq -n --rawfile uuid <(printf '%s' "$ARGO_UUID") --argjson vp "$ARGO_VMESS_PORT" --argjson vlp "$ARGO_VLESS_PORT" \
        '({type:"vmess",tag:"vmess-ws-in",listen:"127.0.0.1",listen_port:$vp,
           users:[{uuid:$uuid,alterId:0}],
           transport:{type:"ws",path:("/" + $uuid + "-vmess"),max_early_data:2560,early_data_header_name:"Sec-WebSocket-Protocol"}}),
         ({type:"vless",tag:"vless-ws-in",listen:"127.0.0.1",listen_port:$vlp,
           users:[{uuid:$uuid}],
           transport:{type:"ws",path:("/" + $uuid + "-vless"),max_early_data:2560,early_data_header_name:"Sec-WebSocket-Protocol"}})' \
        > "$tmp_json" || die "$(tr_msg ag_ws_json)"
    tmp_cfg=$(mktemp /tmp/A-Box-singbox-cfg.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    # R14C9-02: refresh preserves existing users on the two argo inbounds
    # (additional credentials are not wiped); the main UUID is prepended
    # only when it is missing. A new inbound, or users that are not an
    # array, falls back to the single-user array built above.
    # M-6 rescan: the live config may legally carry // or /* */
    # comments, which bare jq rejects. Strip once here; the merge
    # below reads the stripped copy. Write paths still target $cfg.
    local _cfg_stripped=''
    _cfg_stripped=$(mktemp /tmp/A-Box-cfg-stripped.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    jsonc_strip_comments "$cfg" 2>/dev/null > "$_cfg_stripped" || true
    # S-X (R30-M02 same-shape, double-tag): same guard as the other
    # seven deploy sites (e.g. deploy_singbox_trojan_landing, and the
    # ShadowTLS companion gate): an independent inbound that merely
    # shares vmess-ws-in / vless-ws-in must not be silently replaced by
    # the merge below; only a single genuine argo WS inbound of each
    # type proceeds. SX-F1: uniqueness gate, not an existence check --
    # a duplicated tag refuses, because the merge below deletes the
    # whole tag group. An unoccupied tag proceeds as before. Genuine
    # here means type vmess / vless, the same type-only test the other
    # seven gates use (ShadowTLS additionally checks its detour pair,
    # which argo has none of). A jq read failure (invalid config)
    # skips the check and lets the merge fail closed as before. The
    # "deploy with a different tag" clause of the other gates is
    # dropped here: these two tags are function-owned constants.
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e '.inbounds[]? | select(.tag=="vmess-ws-in")' "$_cfg_stripped" >/dev/null 2>&1; then
        if ! jq -e '[.inbounds[]? | select(.tag=="vmess-ws-in")] as $same | (($same | length) == 1 and $same[0].type == "vmess")' "$_cfg_stripped" >/dev/null 2>&1; then
            die "Tag 'vmess-ws-in' is already used by an independent inbound (not a VMess inbound) or appears more than once; refusing to replace it. Remove or rename that inbound."
        fi
    fi
    if [[ -f "$cfg" && ! -L "$cfg" ]] && jq -e '.inbounds[]? | select(.tag=="vless-ws-in")' "$_cfg_stripped" >/dev/null 2>&1; then
        if ! jq -e '[.inbounds[]? | select(.tag=="vless-ws-in")] as $same | (($same | length) == 1 and $same[0].type == "vless")' "$_cfg_stripped" >/dev/null 2>&1; then
            die "Tag 'vless-ws-in' is already used by an independent inbound (not a VLESS inbound) or appears more than once; refusing to replace it. Remove or rename that inbound."
        fi
    fi
    if ! jq --slurpfile nb "$tmp_json" --rawfile uuid <(printf '%s' "$ARGO_UUID") \
            '(.inbounds | map(select(.tag=="vmess-ws-in" or .tag=="vless-ws-in"))) as $old
             | .inbounds |= (
                 map(select(.tag!="vmess-ws-in" and .tag!="vless-ws-in"))
                 + [
                     $nb[] as $new
                     | (
                         ($old | map(select(.tag==$new.tag)) | first) as $ex
                         | if ($ex and ($ex.users | type == "array")) then
                               $new | .users = (
                                   if ($ex.users | map(.uuid?) | index($uuid)) then $ex.users
                                   elif $new.type == "vmess" then [{uuid:$uuid,alterId:0}] + $ex.users
                                   else [{uuid:$uuid}] + $ex.users
                                   end
                               )
                           else $new
                           end
                       )
                   ]
               )' \
            "$_cfg_stripped" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg ag_ws_update)"
    fi
    jq empty "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_json)"; }
    singbox_apply_loopback_guard "$tmp_cfg" || { rm -f "$tmp_cfg" "$tmp_json"; die 'sing-box loopback guard enforcement failed; refusing to install the unguarded config.'; }
    /usr/local/bin/sing-box check -c "$tmp_cfg" >/dev/null 2>&1 \
        || { rm -f "$tmp_cfg" "$tmp_json"; die "$(tr_msg dp_sb_check)"; }
    # R8C9-01: back up the live config before replacing it; without
    # a backup a later restart failure leaves the new config in place
    # with no way back and the existing nodes stalled.
    cfg_bak=$(mktemp /tmp/A-Box-cfg-bak.XXXXXX) || die "$(tr_msg dp_tmpfile)"
    cp -a -- "$cfg" "$cfg_bak" && chmod 600 -- "$cfg_bak" || { rm -f -- "$cfg_bak"; die 'Config backup failed; refusing to replace the live config without a backup.'; }
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$tmp_json" "$cfg_bak"; die "$(tr_msg dp_sb_cfg)"; }
    prepare_abox_runtime_permissions sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_runtime)"; }
    rm -f "$tmp_cfg" "$tmp_json"
    restart_service_soft sing-box || { restore_cfg_backup "$cfg_bak" "$cfg" || msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; restart_service_soft sing-box 2>/dev/null || true; die "$(tr_msg dp_sb_restart)"; }
    rm -f -- "$cfg_bak"
    [[ -n "${_cfg_stripped:-}" ]] && rm -f -- "$_cfg_stripped" 2>/dev/null
    ensure_service_running_soft sing-box || die "$(tr_msg dp_sb_restart)"
    trap - EXIT
    restore_saved_trap EXIT "$_argo_ws_prev_trap_exit"
}

# $1 = unit name (argo-vmess | argo-vless | argo), $2 = cloudflared args (no binary)
argo_write_unit() {
    local name="$1" args="$2"
    local env_file_line='' rc_env_line=''
    local unit
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        unit="/etc/systemd/system/${name}.service"
    else
        unit="/etc/init.d/${name}"
    fi
    # 2ei: refuse to overwrite a foreign unit sharing the name — only
    # A-Box-managed units (written by this function with the marker)
    # may be replaced; same gate as argo_remove_unit. A symlink is
    # refused as well: writing through it would follow the link.
    # R8C9-03: occupancy is -e/-L, not -f: a dangling symlink or a
    # directory at the /etc path must not slip past as "absent".
    if [[ -e "$unit" || -L "$unit" ]]; then
        [[ -f "$unit" && ! -L "$unit" ]] && grep -Fxq '# Managed by A-Box' "$unit" 2>/dev/null || die "Refusing to overwrite foreign service unit ${unit} (not managed by A-Box). Remove or rename it, or deploy with a different name."
    elif [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # systemd also resolves the same name from runtime and vendor unit
        # dirs; with no /etc unit, a foreign vendor unit must
        # still refuse the takeover (the /etc write + restart below
        # would otherwise shadow and restart an external service).
        local vendor_unit
        for vendor_unit in \
            "/run/systemd/system/${name}.service" \
            "/usr/local/lib/systemd/system/${name}.service" \
            "/usr/lib/systemd/system/${name}.service" \
            "/lib/systemd/system/${name}.service"; do
            if [[ -e "$vendor_unit" || -L "$vendor_unit" ]]; then
                [[ -f "$vendor_unit" && ! -L "$vendor_unit" ]] && grep -Fxq '# Managed by A-Box' "$vendor_unit" 2>/dev/null || die "Refusing to overwrite foreign service unit ${vendor_unit} (not managed by A-Box). Remove or rename it, or deploy with a different name."
            fi
        done
    fi
    if [[ "$name" == 'argo' ]]; then
        env_file_line='EnvironmentFile=/etc/ddr/.argo-token'
        # C9-N02: command_env is not an OpenRC runscript variable
        # (openrc-run(8) lists no such entry) — a plain assignment
        # never reaches the daemon. export does: the runscript shell's
        # exported variables are inherited by start-stop-daemon's child.
        rc_env_line='export TUNNEL_TOKEN="$(cut -d= -f2- /etc/ddr/.argo-token 2>/dev/null)"'
    fi
    # M-08(2): never leave the tunnel log 0644: drop any stale log,
    # then recreate it 0600 at once (systemd appends to the existing
    # file, so the mode survives; OpenRC has no UMask equivalent, so
    # the pre-created file is the only protection there). noclobber
    # refuses a symlink swapped in between the remove and the create.
    rm -f "/etc/ddr/${name}.log"
    ( umask 077; set -o noclobber; : > "/etc/ddr/${name}.log" ) 2>/dev/null || true
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin "/etc/systemd/system/${name}.service" 600 <<EOF_UNIT || die "$(tprintf ag_unit_fail 'systemd' "$name")"
# Managed by A-Box
[Unit]
Description=A-Box Argo Tunnel (${name})
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
${env_file_line}
UMask=0077
ExecStart=/usr/local/bin/cloudflared ${args}
Restart=on-failure
RestartSec=5
StandardOutput=append:/etc/ddr/${name}.log
StandardError=append:/etc/ddr/${name}.log

[Install]
WantedBy=multi-user.target
EOF_UNIT
        if [[ "$name" == 'argo' && "${_argo_service_touched+x}" == 'x' ]]; then
            _argo_service_touched=1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || die "$(tr_msg ag_reload)"
        # R6C9-03: do not swallow enable failure: restart can
        # succeed now while the tunnel is missing after reboot.
        systemctl enable "${name}.service" >/dev/null 2>&1 || die "$(tr_msg ag_enable)"
        systemctl restart "${name}.service" >/dev/null 2>&1 || die "$(tprintf ag_start "$name")"
    else
        write_file_atomically_from_stdin "/etc/init.d/${name}" 755 <<EOF_RC || die "$(tprintf ag_unit_fail 'OpenRC' "$name")"
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Argo Tunnel (${name})"
command="/usr/local/bin/cloudflared"
command_args="${args}"
${rc_env_line}
command_background="yes"
pidfile="/run/${name}.pid"
output_log="/etc/ddr/${name}.log"
error_log="/etc/ddr/${name}.log"
depend() { need net; }
EOF_RC
        if [[ "$name" == 'argo' && "${_argo_service_touched+x}" == 'x' ]]; then
            _argo_service_touched=1
        fi
        chmod +x "/etc/init.d/${name}" || die "$(tr_msg ag_orc_chmod)"
        # R6C9-03: do not swallow runlevel registration failure.
        rc-update add "$name" default >/dev/null 2>&1 || die "$(tr_msg ag_enable)"
        rc-service "$name" restart >/dev/null 2>&1 9>&- 10>&- || die "$(tprintf ag_start "$name")"
    fi
}

