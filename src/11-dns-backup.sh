# ABOX-MODULE-BEGIN 11-dns-backup DNS providers, swap/zram, backup
#   Source: install.sh lines 50471-57376 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
# DNS provider list: tag|name|v4|v6
# v4/v6 auto-pairing: selecting a v4 auto-suggests its paired v6 for dual-stack mode
_dns_provider_list() {
    printf '%s\n' \
        'cf-main|Cloudflare|1.1.1.1|2606:4700:4700::1111' \
        "cf-alt|$(tr_msg _dns_provider_list_cloudflare_alt)|1.0.0.1|2606:4700:4700::1001" \
        'google-main|Google|8.8.8.8|2001:4860:4860::8888' \
        "google-alt|$(tr_msg _dns_provider_list_google_alt)|8.8.4.4|2001:4860:4860::8844" \
        'quad9|Quad9|9.9.9.9|2620:fe::fe' \
        'opendns|OpenDNS|208.67.222.222|2620:119:35::35' \
        'alidns|AliDNS|223.5.5.5|2400:3200::1' \
        'dnspod|DNSPod|119.29.29.29|2402:4e00::' \
        'cf-family|Cloudflare Family|1.1.1.2|2606:4700:4700::1112' \
        "quad9-sec|$(tr_msg _dns_provider_list_quad9_sec)|9.9.9.11|2620:fe::11"
}

# Get current DNS from resolv.conf or state file
# Validate a whitespace-separated address group token by token and print
# the valid tokens space-joined (empty if none). Groups must survive
# intact: earlier code deleted spaces, fusing "1.1.1.1 8.8.8.8" into
# "1.1.1.18.8.8.8" and then dropping the whole group.
_dns_valid_v4_group() {
    local -a parts=()
    local tok='' out=''
    local -a line_parts=()
    while IFS=$' \t\n' read -ra line_parts; do
        parts+=("${line_parts[@]}")
    done <<< "$1"
    for tok in "${parts[@]}"; do
        if [[ "$tok" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            local -a oct=()
            local o='' ok=1
            IFS='.' read -ra oct <<< "$tok"
            for o in "${oct[@]}"; do (( 10#$o <= 255 )) || ok=0; done
            (( ok )) && out+="${out:+ }$tok"
        fi
    done
    printf '%s' "$out"
}

_dns_valid_v6_group() {
    local -a parts=()
    local tok='' orig='' out=''
    local -a line_parts=()
    while IFS=$' \t\n' read -ra line_parts; do
        parts+=("${line_parts[@]}")
    done <<< "$1"
    for tok in "${parts[@]}"; do
        orig="$tok"
        tok="${tok%%%*}"
        [[ "$tok" == *:* ]] || continue
        [[ "$tok" == *:::* ]] && continue
        local n=0 t="$tok"
        while [[ "$t" == *::* ]]; do t="${t#*::}"; n=$((n + 1)); done
        local -a groups=()
        local ok=1 g=''
        if (( n == 1 )); then
            local left="${tok%%::*}" right="${tok#*::}"
            # F8: a stray single colon at either edge of the :: split
            # is malformed (IFS splitting would silently drop it).
            [[ "$left" != :* && "$left" != *: && "$right" != :* && "$right" != *: ]] || continue
            local -a lg=() rg=()
            [[ -n "$left" ]] && IFS=':' read -ra lg <<< "$left"
            [[ -n "$right" ]] && IFS=':' read -ra rg <<< "$right"
            groups=("${lg[@]}" "${rg[@]}")
        elif (( n == 0 )); then
            # F8: without ::, a leading or trailing colon is malformed
            # (IFS splitting drops the trailing empty field).
            [[ "$tok" != :* && "$tok" != *: ]] || continue
            IFS=':' read -ra groups <<< "$tok"
        else
            continue
        fi
        # R47-M1: an IPv4 tail (e.g. 64:ff9b::8.8.8.8) is legal and
        # occupies two groups. Validate it as IPv4 and count it
        # double; the hex loop below skips it (it is the last field).
        local _tail=0 _last=''
        if (( ${#groups[@]} > 0 )); then
            _last="${groups[${#groups[@]}-1]}"
            if [[ "$_last" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                [[ -n "$(_dns_valid_v4_group "$_last")" ]] || continue
                _tail=1
            fi
        fi
        if (( n == 1 )); then
            (( ${#groups[@]} + _tail <= 7 )) || continue
        else
            (( ${#groups[@]} + _tail == 8 )) || continue
        fi
        local _gi=0
        for g in "${groups[@]}"; do
            if (( _tail == 1 && _gi == ${#groups[@]} - 1 )); then _gi=$(( _gi + 1 )); continue; fi
            [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || ok=0
            _gi=$(( _gi + 1 ))
        done
        # R7C12-03: output the ORIGINAL token, scope included; the
        # stripped form is only for validation. Callers write the
        # output back, and a stripped fe80::1%eth0 breaks link-local DNS.
        (( ok )) && out+="${out:+ }$orig"
    done
    printf '%s' "$out"
}

# H-25(1): true (rc 0) when the recorded DNS state says DoH is active.
# In that state 127.0.0.1 is the dnscrypt-proxy listener on :5353, not a
# :53 resolver, so callers must never treat it as a plain v4 server.
_dns_state_mode_doh() {
    [[ -f "$DNS_STATE_FILE" ]] || return 1
    grep -qE '(^|;)[ \t]*mode=doh([; \t]|$)' "$DNS_STATE_FILE" 2>/dev/null
}

_dns_current_v4() {
    local cur='' out='' _doh=0 _tok='' _filtered=''
    # H-25(1): when DoH is active, 127.0.0.1 is the dnscrypt-proxy
    # listener on :5353. The sole-loopback fallback below must not hand
    # it back as a plain :53 server, or the tri-mode wizard rewrites
    # resolved to 127.0.0.1:53 (nothing listens there).
    _dns_state_mode_doh && _doh=1
    if [[ -r /etc/resolv.conf ]]; then
        cur=$(awk '/^[ \t]*nameserver[ \t]+/ && $2 !~ /:/ && $2 !~ /^127\./ {print $2}' /etc/resolv.conf 2>/dev/null || true)
        out=$(_dns_valid_v4_group "$cur")
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        if (( _doh == 0 )); then
                # Sole-loopback fallback (R1-12-F9): if only 127.* nameservers
                # exist (e.g. Unbound), return them instead of empty; empty
                # makes the caller fall back to IPv6-only and rewrite away v4.
                cur=$(awk '/^[ \t]*nameserver[ \t]+/ && $2 !~ /:/ && $2 !~ /^127\.0\.0\.(53|54)$/ {print $2}' /etc/resolv.conf 2>/dev/null || true)
                out=$(_dns_valid_v4_group "$cur")
                [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        fi
    fi
    if [[ -r /run/systemd/resolve/resolv.conf ]]; then
        cur=$(awk '/^[ \t]*nameserver[ \t]+/ && $2 !~ /:/ && $2 !~ /^127\./ {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null || true)
        out=$(_dns_valid_v4_group "$cur")
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        if (( _doh == 0 )); then
                # Sole-loopback fallback (R1-12-F9): if only 127.* nameservers
                # exist (e.g. Unbound), return them instead of empty; empty
                # makes the caller fall back to IPv6-only and rewrite away v4.
                cur=$(awk '/^[ \t]*nameserver[ \t]+/ && $2 !~ /:/ && $2 !~ /^127\.0\.0\.(53|54)$/ {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null || true)
                out=$(_dns_valid_v4_group "$cur")
                [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        fi
    fi
    if [[ -f "$DNS_STATE_FILE" ]]; then
        if grep -qE '(^|;)[ \t]*v4=' "$DNS_STATE_FILE" 2>/dev/null; then
            cur=$(awk -F';' '{for(i=1;i<=NF;i++){if($i ~ /^[ \t]*v4=/){sub(/^[ \t]*v4=/, "", $i); gsub(/["'"'"'\r\t]/, "", $i); print $i; exit}}}' "$DNS_STATE_FILE" 2>/dev/null || true)
            out=$(_dns_valid_v4_group "$cur")
            # H-25(1): in DoH mode a recorded 127.0.0.1 is the :5353
            # proxy, not a :53 server; drop that token.
            if (( _doh == 1 )); then
                _filtered=''
                while IFS= read -r _tok; do [[ "$_tok" == '127.0.0.1' ]] || _filtered+="${_filtered:+ }$_tok"; done <<< "$(printf '%s' "$out" | tr ' ' '\n')"
                out="$_filtered"
            fi
            printf '%s' "$out"; return 0
        fi
    fi
    if [[ -f "$ABOX_ENV" ]]; then
        cur=$(awk -F= '/^DNS_V4=/ {val=$2; sub(/#.*$/, "", val); gsub(/["'"'"'\r\t]/, "", val); a=val} END {print a}' "$ABOX_ENV" 2>/dev/null || true)
        out=$(_dns_valid_v4_group "$cur")
        # H-25(1): same recorded-loopback filter as above.
        if (( _doh == 1 )); then
            _filtered=''
            while IFS= read -r _tok; do [[ "$_tok" == '127.0.0.1' ]] || _filtered+="${_filtered:+ }$_tok"; done <<< "$(printf '%s' "$out" | tr ' ' '\n')"
            out="$_filtered"
        fi
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    return 0
}

_dns_current_v6() {
    local cur='' out=''
    if [[ -r /etc/resolv.conf ]]; then
        cur=$(awk '/^[ \t]*nameserver[ \t]+/ {
            addr = $2
            sub(/%.*/, "", addr)
            if (addr ~ /:/)
                print $2
        }' /etc/resolv.conf 2>/dev/null || true)
        out=$(_dns_valid_v6_group "$cur")
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    if [[ -r /run/systemd/resolve/resolv.conf ]]; then
        cur=$(awk '/^[ \t]*nameserver[ \t]+/ {
            addr = $2
            sub(/%.*/, "", addr)
            if (addr ~ /:/)
                print $2
        }' /run/systemd/resolve/resolv.conf 2>/dev/null || true)
        out=$(_dns_valid_v6_group "$cur")
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    if [[ -f "$DNS_STATE_FILE" ]]; then
        if grep -qE '(^|;)[ \t]*v6=' "$DNS_STATE_FILE" 2>/dev/null; then
            cur=$(awk -F';' '{for(i=1;i<=NF;i++){if($i ~ /^[ \t]*v6=/){sub(/^[ \t]*v6=/, "", $i); gsub(/["'"'"'\r\t]/, "", $i); print $i; exit}}}' "$DNS_STATE_FILE" 2>/dev/null || true)
            out=$(_dns_valid_v6_group "$cur")
            printf '%s' "$out"; return 0
        fi
    fi
    if [[ -f "$ABOX_ENV" ]]; then
        cur=$(awk -F= '/^DNS_V6=/ {val=$2; sub(/#.*$/, "", val); gsub(/["'"'"'\r\t]/, "", val); a=val} END {print a}' "$ABOX_ENV" 2>/dev/null || true)
        out=$(_dns_valid_v6_group "$cur")
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    return 0
}

# Tri-mode DNS setup wizard: v4-only / v6-only / dual-stack
# Dual-stack auto-pairs v6 from v4 selection; single mode leaves the other unchanged
# Normalize Persian (۰-۹) and Arabic-Indic (٠-٩) digits to ASCII before
# any numeric match: the fa menu numbers its options in Persian digits,
# but the case/regex below only matches ASCII. Byte-wise tr cannot do
# this (multibyte UTF-8), so use explicit substitutions.
normalize_fa_ar_digits() {
    local v="$1"
    v=${v//۰/0}; v=${v//۱/1}; v=${v//۲/2}; v=${v//۳/3}; v=${v//۴/4}
    v=${v//۵/5}; v=${v//۶/6}; v=${v//۷/7}; v=${v//۸/8}; v=${v//۹/9}
    v=${v//٠/0}; v=${v//١/1}; v=${v//٢/2}; v=${v//٣/3}; v=${v//٤/4}
    v=${v//٥/5}; v=${v//٦/6}; v=${v//٧/7}; v=${v//٨/8}; v=${v//٩/9}
    printf '%s' "$v"
}

dns_setup_tri_mode() {
    local mode='' choice='' v4='' v6='' v6_auto='' input _apply_mode='plain'
    local -a providers=()
    while IFS= read -r line; do providers+=("$line"); done < <(_dns_provider_list)

    clear
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en) msg "${BOLD}${GREEN}DNS Setup: IPv4 / IPv6 / Dual-stack${NC}" ;;
        ru) msg "${BOLD}${GREEN}Настройка DNS: IPv4 / IPv6 / Dual-stack${NC}" ;;
        fa) msg "${BOLD}${GREEN}تنظیم DNS: IPv4 / IPv6 / دوگانه${NC}" ;;
        zh-tw) msg "${BOLD}${GREEN}DNS 設定：IPv4 / IPv6 / 雙棧${NC}" ;;
        ja) msg "${BOLD}${GREEN}DNS 設定: IPv4 / IPv6 / デュアルスタック${NC}" ;;
        *) msg "${BOLD}${GREEN}DNS 设置：IPv4 / IPv6 / 双栈${NC}" ;;
    esac
    msg "${CYAN}======================================================================${NC}"
    msg "$(tprintf dns_current "${YELLOW}$(_dns_current_v4)${NC}" "${YELLOW}$(_dns_current_v6)${NC}")"
    msg ""
    case "${ABOX_LANG:-zh}" in
        en) msg "${CYAN}1.${NC} IPv4 only (IPv6 unchanged)"; msg "${CYAN}2.${NC} IPv6 only (IPv4 unchanged)"; msg "${CYAN}3.${NC} Dual-stack (both)"; msg "${CYAN}0.${NC} Back" ;;
        ru) msg "${CYAN}1.${NC} Только IPv4 (IPv6 без изменений)"; msg "${CYAN}2.${NC} Только IPv6 (IPv4 без изменений)"; msg "${CYAN}3.${NC} Dual-stack (оба)"; msg "${CYAN}0.${NC} Назад" ;;
        fa) msg "${CYAN}۱.${NC} فقط IPv4"; msg "${CYAN}۲.${NC} فقط IPv6"; msg "${CYAN}۳.${NC} دوگانه"; msg "${CYAN}۰.${NC} بازگشت" ;;
        zh-tw) msg "${CYAN}1.${NC} 僅 IPv4（IPv6 不變）"; msg "${CYAN}2.${NC} 僅 IPv6（IPv4 不變）"; msg "${CYAN}3.${NC} 雙棧（兩者都設）"; msg "${CYAN}0.${NC} 返回" ;;
        ja) msg "${CYAN}1.${NC} IPv4 のみ (IPv6 は変更なし)"; msg "${CYAN}2.${NC} IPv6 のみ (IPv4 は変更なし)"; msg "${CYAN}3.${NC} デュアルスタック (両方)"; msg "${CYAN}0.${NC} 戻る" ;;
        *) msg "${CYAN}1.${NC} 仅 IPv4（IPv6 不变）"; msg "${CYAN}2.${NC} 仅 IPv6（IPv4 不变）"; msg "${CYAN}3.${NC} 双栈（两者都设）"; msg "${CYAN}0.${NC} 返回" ;;
    esac
    read -r -p "$(tr_msg dns_select_mode)" mode
    mode=$(normalize_fa_ar_digits "$mode")
    case "$mode" in
        1|2|3) ;;
        *) return 0 ;;
    esac

    # Provider list
    msg ""
    msg "${CYAN}--------------------------------------------------------------------------------${NC}"
    local idx=1
    for p in "${providers[@]}"; do
        IFS='|' read -r tag name pv4 pv6 <<< "$p"
        printf "  ${CYAN}%d.${NC} %-14s ${GREEN}%s${NC} / ${CYAN}%s${NC}\n" "$idx" "$name" "$pv4" "$pv6"
        idx=$((idx+1))
    done
    case "${ABOX_LANG:-zh}" in
        *) msg "${CYAN}0.${NC} $(tr_msg pm_manual)" ;;
    esac
    msg "${CYAN}--------------------------------------------------------------------------------${NC}"

    read -r -p "$(tr_msg dns_select_provider)" choice
    choice=$(normalize_fa_ar_digits "$choice")
    if [[ "$choice" == "0" ]]; then
        # Manual input
        if [[ "$mode" == "1" || "$mode" == "3" ]]; then
            read -r -p "$(tr_msg dns_manual_v4)" v4
            valid_ipv4_cidr "$v4" && [[ "$v4" != */* ]] || { msg "${RED}$(tr_msg dns_invalid_v4)${NC}"; pause_return; return 1; }
        fi
        if [[ "$mode" == "2" || "$mode" == "3" ]]; then
            read -r -p "$(tr_msg dns_manual_v6)" v6
            valid_ipv6_cidr "$v6" && [[ "$v6" != */* ]] || { msg "${RED}$(tr_msg dns_invalid_v6)${NC}"; pause_return; return 1; }
        fi
    elif [[ "$choice" =~ ^([1-9]|10)$ ]]; then
        IFS='|' read -r tag name pv4 pv6 <<< "${providers[$((choice-1))]}"
        case "$mode" in
            1) v4="$pv4" ;;
            2) v6="$pv6" ;;
            3)
                v4="$pv4"
                v6_auto="$pv6"
                # Show auto-paired v6, allow override
                case "${ABOX_LANG:-zh}" in
                    *) msg "$(tprintf pm_paired "${GREEN}$v4${NC}" "${CYAN}$v6_auto${NC}")" ;;
                esac
                read -r -p "$(tprintf dns_v6_override "$v6_auto")" input
                if [[ -n "$input" ]]; then
                    valid_ipv6_cidr "$input" && [[ "$input" != */* ]] || { msg "${RED}$(tr_msg dns_invalid_v6)${NC}"; pause_return; return 1; }
                    v6="$input"
                else
                    v6="$v6_auto"
                fi
                ;;
        esac
    else
        return 0
    fi

    # For single mode, preserve the unchanged side from current config
    if [[ "$mode" == "1" ]]; then
        v6="$(_dns_current_v6)"
    elif [[ "$mode" == "2" ]]; then
        v4="$(_dns_current_v4)"
        # H-25(1): in DoH mode the v4 side is the proxy at
        # 127.0.0.1:5353; "IPv6 only (IPv4 unchanged)" must keep that
        # endpoint, or resolved would be rewritten to 127.0.0.1:53
        # (nothing listens there). The liveness probe in
        # resolved_global_dns_check fails the apply if the proxy is
        # actually dead, so keeping :5353 cannot mask a dead proxy.
        # 06f-X1: applying that endpoint as plain tears the proxy
        # down first (apply_host_dns runs dns_disable_doh for any
        # non-doh mode), so the probe that follows can never pass.
        # Apply as doh instead: the teardown is skipped, the probe
        # still runs, and a dead proxy still fails the apply and
        # rolls back; the state file records mode=doh.
        if _dns_state_mode_doh; then v4='127.0.0.1:5353'; _apply_mode='doh'; fi
    fi

    # Safety: refuse to apply if both are empty (would break DNS)
    if [[ -z "$v4" && -z "$v6" ]]; then
        msg "${RED}$(tr_msg dns_none_valid)${NC}"
        pause_return
        return 1
    fi
    msg ""
    msg "$(tprintf dns_apply "${GREEN}${v4:-none}${NC}" "${CYAN}${v6:-none}${NC}")"
    apply_host_dns "$_apply_mode" "$v4" "$v6"
    pause_return
}

dns_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    # M-21(1): switching away from DoH (plain/DoT items below) tears down
    # dnscrypt-proxy and the abox-listen.conf socket drop-in inside
    # apply_host_dns (dns_disable_doh); the menu itself does not stop the
    # proxy, so every switch-out path shares the one teardown.
    while true; do
    # Recover from any interrupted DNS snapshot swap on menu entry.
    # Total loss must NOT be swallowed (see the recovery function's own
    # comment): surface it, pause, and return to the parent menu
    # instead of entering the DNS menu with no rollback snapshot.
    if ! dns_snapshot_recover_pending_swap; then
        pause_return
        return 1
    fi
    clear
    local c v4 v6 prompt
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}VPS host DNS${NC}"
    msg "Backend: ${YELLOW}$(dns_backend_detect)${NC}"
    if [[ -r /etc/resolv.conf ]]; then grep -E '^(nameserver|search|options)' /etc/resolv.conf 2>/dev/null | head -8 || true; fi
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${CYAN}1.${NC} Auto-benchmark DNS (plain)"
            msg "${CYAN}2.${NC} Auto-benchmark DNS over TLS (DoT)"
            msg "${CYAN}3.${NC} Auto-benchmark DNS over HTTPS (DoH)"
            msg "${CYAN}4.${NC} Custom plain DNS"
            msg "${CYAN}5.${NC} DNS over TLS (presets / custom)"
            msg "${CYAN}6.${NC} DNS over HTTPS via dnscrypt-proxy (Cloudflare)"
            msg "${CYAN}7.${NC} Cloudflare DNS (unencrypted preset)"
            msg "${CYAN}8.${NC} Quad9 DNS (unencrypted preset)"
            msg "${CYAN}9.${NC} Restore the previous DNS snapshot"
            msg "${CYAN}10.${NC} DNS tri-mode setup (v4/v6/dual)"
            ;;
        ru)
            msg "${CYAN}1.${NC} Автоподбор DNS (без шифрования)"
            msg "${CYAN}2.${NC} Автоподбор DNS over TLS (DoT)"
            msg "${CYAN}3.${NC} Автоподбор DNS over HTTPS (DoH)"
            msg "${CYAN}4.${NC} Пользовательский DNS без шифрования"
            msg "${CYAN}5.${NC} DNS over TLS (пресеты / свой)"
            msg "${CYAN}6.${NC} DNS over HTTPS через dnscrypt-proxy (Cloudflare)"
            msg "${CYAN}7.${NC} Cloudflare DNS (предустановленный, без шифрования)"
            msg "${CYAN}8.${NC} Quad9 DNS (предустановленный, без шифрования)"
            msg "${CYAN}9.${NC} Восстановить предыдущую конфигурацию"
            msg "${CYAN}10.${NC} Настройка DNS (v4/v6/dual)"
            ;;
        fa)
            msg "${CYAN}1.${NC} انتخاب خودکار DNS (ساده)"
            msg "${CYAN}2.${NC} انتخاب خودکار DNS روی TLS (DoT)"
            msg "${CYAN}3.${NC} انتخاب خودکار DNS روی HTTPS (DoH)"
            msg "${CYAN}4.${NC} DNS ساده سفارشی"
            msg "${CYAN}5.${NC} DNS روی TLS (پیش‌فرض / سفارشی)"
            msg "${CYAN}6.${NC} DNS روی HTTPS با dnscrypt-proxy (Cloudflare)"
            msg "${CYAN}7.${NC} DNS Cloudflare (پیش‌تنظیم، بدون رمزنگاری)"
            msg "${CYAN}8.${NC} DNS Quad9 (پیش‌تنظیم، بدون رمزنگاری)"
            msg "${CYAN}9.${NC} بازگردانی تنظیمات قبلی DNS"
            msg "${CYAN}10.${NC} تنظیم DNS سه‌حالته (v4/v6/dual)"
            ;;
        zh-tw)
            msg "${CYAN}1.${NC} 自動實測優選 DNS（明文）"
            msg "${CYAN}2.${NC} 自動實測優選 DoT"
            msg "${CYAN}3.${NC} 自動實測優選 DoH"
            msg "${CYAN}4.${NC} 自定義明文 DNS（可選 IPv6）"
            msg "${CYAN}5.${NC} 隱私 DNS DoT（預置 / 自定義）"
            msg "${CYAN}6.${NC} 隱私 DNS DoH（dnscrypt-proxy 本地轉發，Cloudflare）"
            msg "${CYAN}7.${NC} Cloudflare DNS（明文、預設組態）"
            msg "${CYAN}8.${NC} Quad9 DNS（明文、預設組態）"
            msg "${CYAN}9.${NC} 回滾到上次 DNS 修改前快照"
            msg "${CYAN}10.${NC} DNS 三模式設定（v4/v6/雙棧）"
            ;;
        ja)
            msg "${CYAN}1.${NC} DNS 自動ベンチマーク（平文）"
            msg "${CYAN}2.${NC} DoT 自動ベンチマーク"
            msg "${CYAN}3.${NC} DoH 自動ベンチマーク"
            msg "${CYAN}4.${NC} カスタム平文 DNS（IPv6 は任意）"
            msg "${CYAN}5.${NC} プライバシー保護 DNS over TLS（DoT、プリセット / カスタム）"
            msg "${CYAN}6.${NC} プライバシー保護 DNS over HTTPS（DoH、dnscrypt-proxy ローカル転送、Cloudflare）"
            msg "${CYAN}7.${NC} Cloudflare DNS（プリセット・暗号化なし）"
            msg "${CYAN}8.${NC} Quad9 DNS（プリセット・暗号化なし）"
            msg "${CYAN}9.${NC} 前回の DNS 変更前のスナップショットにロールバック"
            msg "${CYAN}10.${NC} DNS 三モード設定 (v4/v6/デュアル)"
            ;;
        *)
            msg "${CYAN}1.${NC} 自动实测优选 DNS（明文）"
            msg "${CYAN}2.${NC} 自动实测优选 DoT"
            msg "${CYAN}3.${NC} 自动实测优选 DoH"
            msg "${CYAN}4.${NC} 自定义明文 DNS（可选 IPv6）"
            msg "${CYAN}5.${NC} 隐私 DNS DoT（预置 / 自定义）"
            msg "${CYAN}6.${NC} 隐私 DNS DoH（dnscrypt-proxy 本地转发，Cloudflare）"
            msg "${CYAN}7.${NC} Cloudflare DNS（明文预置）"
            msg "${CYAN}8.${NC} Quad9 DNS（明文预置）"
            msg "${CYAN}9.${NC} 回滚到上次 DNS 修改前快照"
            msg "${CYAN}10.${NC} DNS 三模式设置（v4/v6/双栈）"
            ;;
    esac
    msg "${CYAN}0.${NC} $(tr_msg dns_menu_back)"
    case "${ABOX_LANG:-zh}" in en) prompt='Select [0-10]: ' ;; ru) prompt='Выберите [0–10]: ' ;; fa) prompt='انتخاب [۰ تا ۱۰]: ' ;; ja) prompt='選択してください [0-10]: ' ;; zh-tw) prompt='請選擇 [0-10]：' ;; *) prompt='请选择 [0-10]：' ;; esac
    read -r -p "$prompt" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) dns_auto_prefer ;;
        2) dns_dot_prefer ;;
        3) dns_doh_prefer ;;
        4)
            read -r -p 'IPv4 DNS: ' v4
            valid_ipv4_cidr "$v4" && [[ "$v4" != */* ]] || { msg "${RED}Invalid IPv4 DNS${NC}"; pause_return; continue; }
            read -r -p 'IPv6 DNS (optional): ' v6
            [[ -z "$v6" ]] || { valid_ipv6_cidr "$v6" && [[ "$v6" != */* ]]; } || { msg "${RED}Invalid IPv6 DNS${NC}"; pause_return; continue; }
            apply_host_dns plain "$v4" "$v6"; pause_return ;;
        5)
            local dot_preset dot_preset_prompt dot_custom_word
            case "${ABOX_LANG:-zh}" in
                en) dot_preset_prompt='DoT provider [1-4]: '; dot_custom_word='Custom' ;;
                ru) dot_preset_prompt='Провайдер DoT [1-4]: '; dot_custom_word='Свой' ;;
                fa) dot_preset_prompt='ارائه‌دهنده DoT [1-4]: '; dot_custom_word='سفارشی' ;;
                zh-tw) dot_preset_prompt='DoT 服務商 [1-4]：'; dot_custom_word='自定義' ;;
                ja) dot_preset_prompt='DoT プロバイダ [1-4]: '; dot_custom_word='カスタム' ;;
                *) dot_preset_prompt='DoT 服务商 [1-4]：'; dot_custom_word='自定义' ;;
            esac
            msg "${CYAN}1.${NC} Cloudflare (1.1.1.1)"
            msg "${CYAN}2.${NC} Google (8.8.8.8)"
            msg "${CYAN}3.${NC} Quad9 (9.9.9.9)"
            msg "${CYAN}4.${NC} $dot_custom_word"
            read -r -p "$dot_preset_prompt" dot_preset
            dot_preset=$(normalize_fa_ar_digits "$dot_preset")
            case "$dot_preset" in
                1) apply_host_dns dot '1.1.1.1' '2606:4700:4700::1111' 'cloudflare-dns.com'; pause_return ;;
                2) apply_host_dns dot '8.8.8.8' '2001:4860:4860::8888' 'dns.google'; pause_return ;;
                3) apply_host_dns dot '9.9.9.9' '2620:fe::fe' 'dns.quad9.net'; pause_return ;;
                4)
            local dot_name dot_ipv4_prompt dot_ipv6_prompt dot_host_prompt dot_host_error
            case "${ABOX_LANG:-zh}" in
                en) dot_ipv4_prompt='DoT resolver IPv4: '; dot_ipv6_prompt='DoT resolver IPv6 (optional): '; dot_host_prompt='TLS authentication hostname (e.g. dns.google): '; dot_host_error='Invalid DoT TLS hostname.' ;;
                ru) dot_ipv4_prompt='IPv4-адрес DNS для DoT: '; dot_ipv6_prompt='IPv6-адрес DNS для DoT (необязательно): '; dot_host_prompt='Имя TLS-аутентификации (например, dns.google): '; dot_host_error='Недопустимое имя TLS для DoT.' ;;
                fa) dot_ipv4_prompt='نشانی IPv4 برای DNS روی TLS: '; dot_ipv6_prompt='نشانی IPv6 (اختیاری): '; dot_host_prompt='نام TLS (مثلاً dns.google): '; dot_host_error='نام TLS برای DoT نامعتبر است.' ;;
                zh-tw) dot_ipv4_prompt='DoT 解析器 IPv4 地址：'; dot_ipv6_prompt='DoT 解析器 IPv6 地址（可選）：'; dot_host_prompt='TLS 認證主機名（例如 dns.google）：'; dot_host_error='DoT TLS 主機名無效。' ;;
                ja)
                    dot_ipv4_prompt='DoT リゾルバーの IPv4 アドレス: '; dot_ipv6_prompt='DoT リゾルバーの IPv6 アドレス（任意）: '; dot_host_prompt='TLS 認証ホスト名（例: dns.google）: '; dot_host_error='DoT の TLS ホスト名が無効です。' ;;
                *) dot_ipv4_prompt='DoT 解析器 IPv4 地址：'; dot_ipv6_prompt='DoT 解析器 IPv6 地址（可选）：'; dot_host_prompt='TLS 认证主机名（例如 dns.google）：'; dot_host_error='DoT TLS 主机名无效。' ;;
            esac
            read -r -p "$dot_ipv4_prompt" v4
            valid_ipv4_cidr "$v4" && [[ "$v4" != */* ]] || { msg "${RED}Invalid IPv4 DNS${NC}"; pause_return; continue; }
            read -r -p "$dot_ipv6_prompt" v6
            [[ -z "$v6" ]] || { valid_ipv6_cidr "$v6" && [[ "$v6" != */* ]]; } || { msg "${RED}Invalid IPv6 DNS${NC}"; pause_return; continue; }
            read -r -p "$dot_host_prompt" dot_name
            valid_domain "$dot_name" || { msg "${RED}$dot_host_error${NC}"; pause_return; continue; }
            apply_host_dns dot "$v4" "$v6" "$dot_name"; pause_return ;;
                *) msg "${RED}$(tr_msg invalid_input): $dot_preset${NC}"; pause_return; return 1 ;;
            esac ;;
        7) if host_has_usable_ipv6 2>/dev/null; then apply_host_dns plain '1.1.1.1' '2606:4700:4700::1111'; else apply_host_dns plain '1.1.1.1' ''; fi; pause_return ;;
        8) if host_has_usable_ipv6 2>/dev/null; then apply_host_dns plain '9.9.9.9' '2620:fe::fe'; else apply_host_dns plain '9.9.9.9' ''; fi; pause_return ;;
        6) dns_enable_doh; pause_return ;;
        9) if [[ -f "$DNS_BACKUP_DIR/COMPLETE" ]]; then if restore_dns_snapshot "$DNS_BACKUP_DIR"; then msg "${GREEN}DNS restored.${NC}"; else msg "${RED}DNS rollback failed.${NC}"; fi; else msg "${YELLOW}No DNS snapshot exists.${NC}"; fi; pause_return ;;
        10) dns_setup_tri_mode ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}
tune_vps() {
    # Submenu loop: sub-functions return here; 0 goes back to the parent menu.
    while true; do
    clear
    local prompt
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}VPS one-click optimization${NC}"
            msg "${CYAN}1.${NC} Apply supported BBR/FQ and system tuning"
            msg "${CYAN}2.${NC} Restore the previous tuning snapshot"
            msg "${CYAN}0.${NC} Back"
            ;;
        ru)
            msg "${BOLD}${GREEN}Оптимизация VPS${NC}"
            msg "${CYAN}1.${NC} Применить поддерживаемые BBR/FQ и системные настройки"
            msg "${CYAN}2.${NC} Восстановить предыдущий снимок настроек"
            msg "${CYAN}0.${NC} Назад"
            ;;
        fa)
            msg "${BOLD}${GREEN}بهینه‌سازی VPS${NC}"
            msg "${CYAN}1.${NC} اعمال تنظیمات پشتیبانی‌شده BBR/FQ"
            msg "${CYAN}2.${NC} بازگردانی وضعیت قبلی"
            msg "${CYAN}0.${NC} بازگشت"
            ;;
        zh-tw)
            msg "${BOLD}${GREEN}VPS 一鍵最佳化${NC}"
            msg "${CYAN}1.${NC} 應用當前核心支援的 BBR/FQ 與系統調優（可回滾）"
            msg "${CYAN}2.${NC} 恢復調優前快照"
            msg "${CYAN}0.${NC} 返回"
            ;;
        ja)
            msg "${BOLD}${GREEN}VPS ワンクリック最適化${NC}"
            msg "${CYAN}1.${NC} 現在のカーネルがサポートする BBR/FQ とシステム最適化を適用（ロールバック可能）"
            msg "${CYAN}2.${NC} 最適化前のスナップショットを復元"
            msg "${CYAN}0.${NC} 戻る"
            ;;
        *)
            msg "${BOLD}${GREEN}VPS 一键优化${NC}"
            msg "${CYAN}1.${NC} 应用当前内核支持的 BBR/FQ 与系统调优（可回滚）"
            msg "${CYAN}2.${NC} 恢复调优前快照"
            msg "${CYAN}0.${NC} 返回"
            ;;
    esac
    local c
    case "${ABOX_LANG:-zh}" in en) prompt='Select [0-2]: ' ;; ru) prompt='Выберите [0–2]: ' ;; fa) prompt='انتخاب [۰ تا ۲]: ' ;; ja) prompt='選択してください [0-2]: ' ;; zh-tw) prompt='請選擇 [0-2]：' ;; *) prompt='请选择 [0-2]：' ;; esac
    read -r -p "$prompt" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) apply_vps_tune; pause_return ;;
        2) restore_vps_tune; pause_return ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}
sha256_in_allowlist() {
    local sha="${1,,}" allowlist="${2:-}"
    [[ "$sha" =~ ^[a-f0-9]{64}$ && -n "$allowlist" ]] || return 1
    awk -v want="$sha" 'BEGIN {
        found=0
        while ((getline line) > 0) {
            gsub(/[,; \t\r]+/, "\n", line)
            count=split(line, values, /\n/)
            for (i=1; i<=count; i++) {
                value=tolower(values[i])
                if (value == want) { found=1; exit }
            }
        }
        exit(found ? 0 : 1)
    }' <<< "$allowlist"
}

canonical_path() {
    local input="${1:-}"
    [[ -n "$input" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - "$input" <<'PY_CANONICAL_PATH'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY_CANONICAL_PATH
}

create_backup_manifest() {
    local tree="${1:-}" output="${2:-}"
    [[ -d "$tree/root" && -d "$tree/meta" && -n "$output" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - "$tree" "$output" <<'PY_BACKUP_MANIFEST'
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path

base = Path(sys.argv[1]).resolve(strict=True)
out = Path(sys.argv[2])
try:
    out_relative = out.resolve(strict=False).relative_to(base)
except (OSError, ValueError):
    raise SystemExit(1)

def _walk_fail(err):
    raise SystemExit(1)


entries = []
for top_name in ("root", "meta"):
    top = base / top_name
    if not top.is_dir() or top.is_symlink():
        raise SystemExit(1)
    for current, dirs, files in os.walk(top, topdown=True, followlinks=False, onerror=_walk_fail):
        current_path = Path(current)
        for name in list(dirs):
            candidate = current_path / name
            try:
                mode = candidate.lstat().st_mode
            except OSError:
                raise SystemExit(1)
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise SystemExit(1)
        for name in files:
            candidate = current_path / name
            relative = candidate.relative_to(base)
            # R8C13-N01: a newline in a relative path splits one
            # record into two lines; refuse instead of writing
            # an invalid manifest while reporting success.
            if '\n' in relative.as_posix() or '\r' in relative.as_posix():
                raise SystemExit(1)
            if relative == out_relative:
                continue
            try:
                mode = candidate.lstat().st_mode
            except OSError:
                raise SystemExit(1)
            if not stat.S_ISREG(mode):
                raise SystemExit(1)
            entries.append((relative.as_posix(), candidate))

entries.sort(key=lambda item: item[0].encode("utf-8"))
out.parent.mkdir(parents=False, exist_ok=True)
tmp_fd, tmp_name = tempfile.mkstemp(prefix=f".{out.name}.", suffix=".tmp", dir=str(out.parent))
tmp = Path(tmp_name)
try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8", newline="\n") as handle:
        for relative, candidate in entries:
            digest = hashlib.sha256()
            with candidate.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            handle.write(f"{digest.hexdigest()}  {relative}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
except Exception:
    try:
        tmp.unlink()
    except OSError:
        pass
    raise SystemExit(1)
PY_BACKUP_MANIFEST
}

confirm_remote_script_hash() {
    local label="$1" url="$2" sha="$3"
    # Refuse without an explicit pin. Interactive confirm alone is not a trust root.
    if [[ -z "${ABOX_REMOTE_SHA256_ALLOWLIST:-}" ]]; then
        msg "${RED}[!] Refusing to run third-party remote script without ABOX_REMOTE_SHA256_ALLOWLIST.${NC}"
        msg "${YELLOW}[*] Set ABOX_REMOTE_SHA256_ALLOWLIST to a comma/space-separated list of expected SHA256 digests, then retry.${NC}"
        msg "${YELLOW}[*] Displayed digest for pinning: ${sha}${NC}"
        return 1
    fi
    if ! sha256_in_allowlist "$sha" "$ABOX_REMOTE_SHA256_ALLOWLIST"; then
        die "Remote script SHA256 is not in ABOX_REMOTE_SHA256_ALLOWLIST: ${label}"
    fi
    msg "${GREEN}[*] Remote script SHA256 matched ABOX_REMOTE_SHA256_ALLOWLIST.${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
        msg "${YELLOW}[!] This is third-party code outside A-Box control even after digest pin.${NC}"
        msg "${YELLOW}[!] Source: ${url}${NC}"
        confirm_yes_no 'Execute this digest-pinned third-party script? [Y/N]: '
            ;;
        ru)
        msg "${YELLOW}[!] Это код третьей стороны вне контроля A-Box, даже после digest pin.${NC}"
        msg "${YELLOW}[!] Источник: ${url}${NC}"
        confirm_yes_no 'Выполнить этот сторонний скрипт с фиксированным digest? [Y/N]: '
            ;;
        fa)
        msg "${YELLOW}[!] این کد سوم‌طرفانه خارج از کنترل A-Box است حتی پس از digest pin.${NC}"
        msg "${YELLOW}[!] منبع: ${url}${NC}"
        confirm_yes_no 'این اسکریپت سوم‌طرف با digest ثابت اجرا شود؟ [Y/N]: '
            ;;
        ja)
            msg "${YELLOW}[!] ダイジェストを固定していても、これは A-Box の管理外にあるサードパーティーコードです。${NC}"
            msg "${YELLOW}[!] ソース: ${url}${NC}"
            confirm_yes_no 'ダイジェストを固定したこのサードパーティースクリプトを実行しますか？[Y/N]: '
            ;;
        zh-tw)
        msg "${YELLOW}[!] 即使摘要已釘扎，仍是 A-Box 無法控制的第三方程式碼。${NC}"
        msg "${YELLOW}[!] 來源：${url}${NC}"
        confirm_yes_no '確認執行此已釘扎摘要的第三方指令碼？[Y/N]: '
            ;;
        *)
        msg "${YELLOW}[!] 即使摘要已钉扎，仍是 A-Box 无法控制的第三方代码。${NC}"
        msg "${YELLOW}[!] 来源：${url}${NC}"
        confirm_yes_no '确认执行此已钉扎摘要的第三方脚本？[Y/N]: '
            ;;
    esac
}

# SYD-B E0 companion: the main script shadows clear() so a dumb/unknown
# TERM never emits ncurses junk into its own logs, but third-party children
# launched via env -i used to get the raw TERM. sudo turns dumb into
# unknown, and under unknown whiptail/newt cannot initialise at all (W4
# tb3: Check.Place exits via *)exit 1 with zero output). Normalise the
# TERM handed to children: unusable values become xterm, a usable caller
# TERM passes through untouched.
_abox_child_term() {
    case "${TERM:-}" in
        ''|dumb|unknown) printf '%s\n' 'xterm' ;;
        *) printf '%s\n' "$TERM" ;;
    esac
}

run_remote_bash_script() {
    local label="$1" url="$2" tmp sha
    shift 2 || true
    tmp=$(umask 077; mktemp /tmp/A-Box-remote.XXXXXX) || die "$(tr_msg run_remote_bash_script_tmpfile_failed)"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 -m 120 "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "$(tprintf run_remote_bash_script_download_failed "$label")"
    fi
    chmod 600 "$tmp"
    sha=$(sha256sum "$tmp" | awk '{print $1}')
    msg "${YELLOW}[*] Remote script: ${label}${NC}"
    msg "${YELLOW}[*] Source: ${url}${NC}"
    msg "${YELLOW}[*] SHA256: ${sha}${NC}"
    bash -n "$tmp" || { rm -f "$tmp"; die "$(tprintf run_remote_bash_script_syntax_failed "$label")"; }
    confirm_remote_script_hash "$label" "$url" "$sha" || { rm -f "$tmp"; msg "${YELLOW}[*] Remote script execution canceled: ${label}${NC}"; return 130; }
    # Third-party code is explicitly opt-in, but must not inherit any exported
    # controller credentials (including secrets unknown to this script). Start
    # from an empty environment and pass only the minimum non-secret runtime context.
    env -i \
        PATH="$PATH" \
        HOME="${HOME:-/root}" \
        LANG="${LANG:-C.UTF-8}" \
        TERM="$(_abox_child_term)" \
        bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}



sni_normalize_candidate_file() {
    local source="${1:-}" output="${2:-}" bytes line domain rows=0
    local -A seen=()
    [[ -n "$source" && -n "$output" && -f "$source" && ! -L "$source" ]] || return 1
    bytes=$(wc -c < "$source" 2>/dev/null | tr -d ' ') || return 1
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    (( bytes > 0 && bytes <= ABOX_SNI_CANDIDATE_MAX_BYTES )) || return 1
    : > "$output" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        domain="${line,,}"
        [[ ${#domain} -le 253 && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
        if [[ -z "${seen[$domain]+x}" ]]; then
            seen["$domain"]=1
            rows=$((rows + 1))
            (( rows <= ABOX_SNI_CANDIDATE_MAX_ROWS )) || return 1
            printf '%s\n' "$domain" >> "$output" || return 1
        fi
    done < "$source"
    (( rows >= ABOX_SNI_CANDIDATE_MIN_ROWS && rows <= ABOX_SNI_CANDIDATE_MAX_ROWS ))
}

sni_store_candidate_cache() {
    local source="${1:-}" cache="${ABOX_DIR}/A-Box-sni-candidates.txt"
    [[ $EUID -eq 0 && -d "$ABOX_DIR" && ! -L "$ABOX_DIR" ]] || return 1
    [[ -f "$source" && ! -L "$source" ]] || return 1
    path_owned_by_root "$ABOX_DIR" || return 1
    path_mode_has_no_group_other_write "$ABOX_DIR" || return 1
    [[ ! -L "$cache" && ( ! -e "$cache" || -f "$cache" ) ]] || return 1
    path_parent_chain_safe "$cache" || return 1
    install_file_atomically "$source" "$cache" 600 || return 1
    path_owned_by_root "$cache" && path_mode_has_no_group_other_write "$cache"
}

sni_load_candidate_seed() {
    local output="${1:-}" override="${ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE:-}"
    local url="${ABOX_SNI_CANDIDATE_URL:-$ABOX_SNI_CANDIDATE_URL_DEFAULT}"
    local downloaded normalized cache local_seed script_dir download_ok=0 _curl_rc=0
    [[ -n "$output" && -f "$output" && ! -L "$output" ]] || return 1
    downloaded=$(umask 077; mktemp /tmp/A-Box-sni-download.XXXXXX) || return 1
    normalized=$(umask 077; mktemp /tmp/A-Box-sni-normalized.XXXXXX) || { rm -f -- "$downloaded"; return 1; }
    cache="${ABOX_DIR}/A-Box-sni-candidates.txt"

    if [[ -n "$override" ]]; then
        if sni_normalize_candidate_file "$override" "$normalized"; then
            cat -- "$normalized" > "$output" || { rm -f -- "$downloaded" "$normalized"; return 1; }
            rm -f -- "$downloaded" "$normalized"
            return 0
        fi
        rm -f -- "$downloaded" "$normalized"
        return 1
    fi

    # This endpoint is data-only. Never execute downloaded content; accept HTTPS only.
    if [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* ]]; then
        # --proto-redir pins redirects to HTTPS. The head -c cap truncates
        # in flight, so an unknown-length response cannot fill the disk even
        # on curl versions whose --max-filesize only bites once the size is
        # known (a version gate would disable downloads on every distro
        # shipping curl < 8.4). Do not fall back to wget: it has no portable
        # hard output-size cap and would defeat this guard.
        if command -v curl >/dev/null 2>&1; then
            curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 35 --max-filesize "$ABOX_SNI_CANDIDATE_MAX_BYTES" "$url" 2>/dev/null | head -c $((ABOX_SNI_CANDIDATE_MAX_BYTES + 1)) > "$downloaded" 2>/dev/null
            _curl_rc=${PIPESTATUS[0]}
            if (( _curl_rc == 0 )) && [[ -f "$downloaded" ]] && (( $(wc -c < "$downloaded" 2>/dev/null || echo 0) <= ABOX_SNI_CANDIDATE_MAX_BYTES )); then
                download_ok=1
            fi
        fi
    fi
    if (( download_ok == 1 )) && sni_normalize_candidate_file "$downloaded" "$normalized"; then
        if cat -- "$normalized" > "$output"; then
            if [[ $EUID -eq 0 && -d "$ABOX_DIR" && ! -L "$ABOX_DIR" ]]; then
                if ! sni_store_candidate_cache "$normalized"; then
                    msg "${YELLOW}[!] $(tr_msg sni_load_candidate_seed_cache_update_failed)${NC}"
                fi
            fi
            rm -f -- "$downloaded" "$normalized"
            return 0
        fi
    fi

    # Network failure or invalid data: prefer a previously validated local cache.
    if [[ -f "$cache" && ! -L "$cache" ]] && \
        { [[ $EUID -ne 0 ]] || { path_owned_by_root "$cache" && path_mode_has_no_group_other_write "$cache" && path_parent_chain_safe "$cache"; }; } && \
        sni_normalize_candidate_file "$cache" "$normalized"; then
        cat -- "$normalized" > "$output" || { rm -f -- "$downloaded" "$normalized"; return 1; }
        msg "${YELLOW}[!] $(tr_msg sni_load_candidate_seed_use_cached)${NC}"
        rm -f -- "$downloaded" "$normalized"
        return 0
    fi

    # Support a source checkout/zip with data/ beside the script (e.g. first CI run).
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || script_dir=''
    local_seed="${script_dir:+$script_dir/data/sni-candidates.txt}"
    if [[ -n "$local_seed" && -f "$local_seed" && ! -L "$local_seed" ]] && sni_normalize_candidate_file "$local_seed" "$normalized"; then
        cat -- "$normalized" > "$output" || { rm -f -- "$downloaded" "$normalized"; return 1; }
        msg "${YELLOW}[!] $(tr_msg sni_load_candidate_seed_use_bundled)${NC}"
        rm -f -- "$downloaded" "$normalized"
        return 0
    fi
    rm -f -- "$downloaded" "$normalized"
    return 1
}

remove_sni_candidate_cache() {
    local cache="${ABOX_DIR}/A-Box-sni-candidates.txt"
    [[ -e "$cache" || -L "$cache" ]] || return 0
    [[ -f "$cache" && ! -L "$cache" ]] || return 1
    path_owned_by_root "$cache" || return 1
    path_mode_has_no_group_other_write "$cache" || return 1
    path_tree_has_mountpoint "$cache" && return 1
    rm -f -- "$cache" || return 1
    [[ ! -e "$cache" && ! -L "$cache" ]]
}

restore_sni_candidate_cache_snapshot() {
    local backup="${1:-}" existed="${2:-0}" cache="${ABOX_DIR}/A-Box-sni-candidates.txt"
    if [[ "$existed" == '1' ]]; then
        [[ -n "$backup" && -f "$backup" && ! -L "$backup" ]] || return 1
        install_file_atomically "$backup" "$cache" 600 || return 1
        path_owned_by_root "$cache" && path_mode_has_no_group_other_write "$cache"
        return $?
    fi
    [[ ! -e "$cache" && ! -L "$cache" ]] && return 0
    remove_sni_candidate_cache
}

sni_resolve_public_ip() {
    local domain="${1:-}" ip any=0 chosen='' resolved=''
    valid_domain "$domain" || return 1
    resolved=$(resolve_domain_addresses "$domain") || return 1
    resolved=$(awk '!seen[$0]++' <<< "$resolved")
    [[ -n "$resolved" ]] || return 1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        any=1
        valid_public_ip "$ip" || return 1
        [[ -n "$chosen" ]] || chosen="$ip"
    done <<< "$resolved"
    (( any == 1 )) && [[ -n "$chosen" ]] || return 1
    printf '%s\n' "$chosen"
}

write_sni_candidate_library() {
    local profile="${1:-full}" out="$2" raw generated tmp append_tmp out_tmp max_count
    [[ -n "$out" ]] || die 'SNI candidate output path missing.'
    path_parent_chain_safe "$out" || die 'SNI candidate output path is unsafe.'
    [[ ! -L "$out" && ( ! -e "$out" || -f "$out" ) ]] || die 'SNI candidate output target is unsafe.'
    raw=$(umask 077; mktemp /tmp/A-Box-sni-lib.XXXXXX) || die 'SNI library temporary file creation failed.'
    generated=$(umask 077; mktemp /tmp/A-Box-sni-lib-generated.XXXXXX) || { rm -f "$raw"; die 'SNI generated library temporary file creation failed.'; }
    tmp=$(umask 077; mktemp /tmp/A-Box-sni-lib-filtered.XXXXXX) || { rm -f "$raw" "$generated"; die 'SNI library filtered temporary file creation failed.'; }

    sni_load_candidate_seed "$raw" || { rm -f -- "$raw" "$generated" "$tmp"; die 'SNI candidate data is unavailable or failed validation; upload data/sni-candidates.txt or restore the validated cache.'; }


    # Generate conservative subdomain variants for strong apexes. Invalid/nonexistent hosts are filtered by TLS probing.
    awk 'NF && $0 !~ /^#/ {print tolower($0)}' "$raw" | \
        sed -E 's#^https?://##; s#/.*$##; s/:443$//; s/[[:space:]]//g' | \
        grep -E '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' | \
        awk '!seen[$0]++' > "$generated"

    append_tmp=$(umask 077; mktemp /tmp/A-Box-sni-lib-append.XXXXXX) || { rm -f "$raw" "$generated" "$tmp"; die 'SNI candidate append temporary file creation failed.'; }
    # D10: match strong apexes by table lookup, not one giant
    # alternation regex: mawk 1.3.3 (Debian 10 buster) rejects regexes
    # over its implementation size limit, which aborted the whole
    # script via die (self-test printed no marker). Table lookup is
    # exact-match, identical semantics, and portable across mawk/gawk.
    if ! awk -F. 'BEGIN {
        n = split("github cloudflare microsoft google apache mozilla docker kubernetes linuxfoundation cncf python rust-lang golang go oracle ibm redhat ubuntu debian nginx postgresql mongodb elastic hashicorp terraform confluent fastly akamai digitalocean linode vultr hetzner ovhcloud scaleway openai anthropic huggingface pytorch tensorflow ietf w3 rfc-editor openssl curl gnu kernel freebsd openbsd netbsd eclipse jetbrains npmjs nodejs typescriptlang redis sqlite mysql wikimedia wikipedia archive stackoverflow stackexchange nasa nist cisa stanford mit berkeley cambridge ox ethz epfl unimelb sydney unsw monash auckland cloudfront amazonaws", _strong, " ")
        for (i = 1; i <= n; i++) strong[_strong[i]] = 1
    }
    NF>=2 {
        base=$(NF-1); apex=base "." $NF
        if (base in strong) print apex
    }' "$generated" | awk '!seen[$0]++' | while IFS= read -r apex; do
        for p in www docs doc developer developers api status support blog cdn static assets download downloads registry repo packages pkg files raw resources community help learn training security; do
            printf '%s.%s\n' "$p" "$apex"
        done
        printf '%s\n' "$apex"
    done > "$append_tmp"; then
        rm -f "$raw" "$generated" "$tmp" "$append_tmp"
        die 'SNI candidate variant generation failed.'
    fi
    cat "$append_tmp" >> "$generated" || { rm -f "$raw" "$generated" "$tmp" "$append_tmp"; die 'SNI candidate merge failed.'; }
    rm -f "$append_tmp"

    if ! awk 'NF && $0 !~ /^#/ {print tolower($0)}' "$generated" | \
        sed -E 's#^https?://##; s#/.*$##; s/:443$//; s/[[:space:]]//g' | \
        grep -E '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' | \
        grep -Ev '(^|\.)(doubleclick|googlesyndication|googleadservices|facebook|tiktok|tracking|track|ads|analytics|telemetry)\.' | \
        awk '!seen[$0]++' > "$tmp"; then
        rm -f "$raw" "$generated" "$tmp" "$append_tmp"
        die 'SNI candidate filtering failed.'
    fi
    [[ -s "$tmp" ]] || { rm -f "$raw" "$generated" "$tmp" "$append_tmp"; die 'SNI candidate filtering produced an empty library.'; }

    if [[ "$profile" == 'mini' ]]; then
        max_count="${ABOX_SNI_MINI_MAX:-$ABOX_SNI_DEFAULT_MAX}"
    else
        max_count="${ABOX_SNI_FULL_MAX:-$ABOX_SNI_DEFAULT_MAX}"
    fi
    if ! [[ "$max_count" =~ ^[0-9]+$ ]]; then
        max_count="$ABOX_SNI_DEFAULT_MAX"
    fi
    # Clamp by digit length before any arithmetic: values beyond int64
    # wrap negative in (( )) and would pass the clamp, while awk would
    # then treat the raw huge string as unbounded (NR<=n always true).
    local _mc="$max_count"
    while [[ "$_mc" == 0?* && ${#_mc} -gt 1 ]]; do _mc="${_mc#0}"; done
    # shellcheck disable=SC2071
    if [[ "$_mc" == '0' ]] || [[ ${#_mc} -gt ${#ABOX_SNI_HARD_MAX} ]] || { [[ ${#_mc} -eq ${#ABOX_SNI_HARD_MAX} ]] && [[ "$_mc" > "$ABOX_SNI_HARD_MAX" ]]; }; then
        max_count="$ABOX_SNI_HARD_MAX"
    else
        max_count="$_mc"
    fi
    out_tmp=$(mktemp "${out}.A-Box-new.XXXXXX") || { rm -f "$raw" "$generated" "$tmp"; die 'SNI candidate output temporary file creation failed.'; }
    if ! awk -v n="$max_count" 'NR<=n {print}' "$tmp" > "$out_tmp"; then
        rm -f "$raw" "$generated" "$tmp" "$out_tmp"
        die 'SNI candidate output generation failed.'
    fi
    [[ -s "$out_tmp" ]] || { rm -f "$raw" "$generated" "$tmp" "$out_tmp"; die 'SNI candidate output is empty.'; }
    chmod 600 "$out_tmp" || { rm -f "$raw" "$generated" "$tmp" "$out_tmp"; die 'SNI candidate output permissions failed.'; }
    [[ $EUID -eq 0 ]] && chown root:root "$out_tmp" || true
    mv -f -- "$out_tmp" "$out" || { rm -f "$raw" "$generated" "$tmp" "$out_tmp"; die 'SNI candidate atomic commit failed.'; }
    rm -f "$raw" "$generated" "$tmp"
}

sni_domain_penalty() {
    local domain="${1,,}" penalty=0
    case "$domain" in
        www.apple.com|www.icloud.com) penalty=$((penalty + 1800)) ;;
        www.nike.com|www.adidas.com|www.google.com|www.youtube.com|www.netflix.com) penalty=$((penalty + 500)) ;;
        *.google.com|*.gstatic.com|*.googleapis.com|*.youtube.com|*.facebook.com|*.instagram.com|*.twitter.com|*.x.com|*.tiktok.com|*.telegram.org|*.whatsapp.com|*.wikipedia.org|*.wikimedia.org|*.openai.com|*.anthropic.com|*.huggingface.co|*.torproject.org|*.nist.gov|*.cisa.gov|*.github.com|*.apple.com|*.icloud.com|apple.com|icloud.com|github.com|*.doubleclick.net|*.googlesyndication.com|*.googleadservices.com) penalty=$((penalty + 2400)) ;;
    esac
    case "$domain" in
        # 2026-10-17: microsoft/bing removed from the -220 preferred tier per SNI research
        # (XTLS #2256: microsoft/apple-class targets heavily abused; te-st.org 2026-09-30:
        # RKN SNI-consistency checks on big-brand SNIs; Xray warns www.microsoft.com raises
        # GFW block probability). amazon likewise neutral: it is the verified safer fallback.
        *.apache.org|*.ietf.org|*.rfc-editor.org|*.w3.org|*.unicode.org|*.icann.org|*.iana.org|*.iso.org|*.itu.int|*.nginx.org|*.openssl.org|*.curl.se|*.kernel.org|*.debian.org|*.ubuntu.com|*.linuxfoundation.org|*.cncf.io) penalty=$((penalty - 220)) ;;
        # B-09: Pure CDN hostnames must not be rewarded in stage 1 (stage 2 assigns +500 -> R tier).
        *.cloudflare.com|*.akamai.com|*.fastly.com) penalty=$((penalty + 400)) ;;
        docs.*|developer.*|developers.*|learn.*|support.*|download.*|downloads.*|packages.*|repo.*|registry.*|resources.*|community.*|help.*|security.*|*.mozilla.org|*.confluent.io|*.python.org|*.rust-lang.org|*.nodejs.org|*.postgresql.org|*.sqlite.org|*.eclipse.org|*.gnu.org|*.git-scm.com|*.cmake.org|*.llvm.org|*.mariadb.org|*.mysql.com) penalty=$((penalty - 120)) ;;
        *.samsung.com|*.lenovo.com|*.dell.com|*.intel.com|*.amd.com|*.nvidia.com|*.cisco.com|*.huawei.com|*.ericsson.com|*.nokia.com|*.siemens.com|*.un.org|*.who.int|*.unesco.org|*.cern.ch|*.esa.int|*.mit.edu|*.stanford.edu|*.berkeley.edu|*.cam.ac.uk|*.ox.ac.uk|*.ethz.ch|*.epfl.ch|*.crossref.org|*.orcid.org|*.openstreetmap.org) penalty=$((penalty - 60)) ;;
    esac
    printf '%s\n' "$penalty"
}

asn_lookup_ip() {
    local ip="${1:-}" cache_dir="${2:-}" cache_file body asn='' country='' org='' uid gid mode http_code
    [[ -n "$ip" && "$ip" != 'N/A' ]] || { printf 'asn=unknown\tcountry=unknown\torg=unknown'; return 0; }
    [[ -n "$cache_dir" && -d "$cache_dir" && ! -L "$cache_dir" ]] || return 1
    uid=$(stat -c %u "$cache_dir" 2>/dev/null) || return 1
    gid=$(stat -c %g "$cache_dir" 2>/dev/null) || return 1
    mode=$(stat -c %a "$cache_dir" 2>/dev/null) || return 1
    # C-05: stat -c %a outputs "700" (no leading 0), not "0700".
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^0?700$ ]] || return 1
    cache_file="$cache_dir/$(printf '%s' "$ip" | tr -c 'A-Za-z0-9_.:-' '_')"
    # Cache first: a 429 short-circuit must not shadow already-known
    # ASN/org (including CDN marks) for cached IPs.
    if [[ -s "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi
    # Global short-circuit after ipinfo.io rate-limit (429) for this SNI run.
    if [[ -f "$cache_dir/.rate_limited" ]]; then
        printf 'asn=unknown\tcountry=unknown\torg=unknown'
        return 0
    fi
    body=$(curl -sS -w $'\n%{http_code}' --connect-timeout 2 -m 4 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)
    http_code=${body##*$'\n'}
    body=${body%$'\n'*}
    if [[ "$http_code" == '429' ]]; then
        : > "$cache_dir/.rate_limited" 2>/dev/null || true
        printf 'asn=unknown\tcountry=unknown\torg=unknown'
        return 0
    fi
    if [[ "$http_code" == '200' && -n "$body" ]] && command -v jq >/dev/null 2>&1; then
        org=$(jq -r '.org // "unknown"' <<< "$body" 2>/dev/null | tr '\t\n\r' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
        country=$(jq -r '.country // "unknown"' <<< "$body" 2>/dev/null | tr '\t\n\r' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
        asn=$(sed -nE 's/^(AS[0-9]+).*/\1/p' <<< "$org")
    fi
    [[ -n "$asn" ]] || asn='unknown'
    [[ -n "$country" ]] || country='unknown'
    [[ -n "$org" ]] || org='unknown'
    printf 'asn=%s\tcountry=%s\torg=%s' "$asn" "$country" "$org" | tee "$cache_file" 2>/dev/null || true
}


sni_org_cdn_penalty() {
    local domain="${1,,}" org="${2,,}" penalty=0
    # This is a risk label, not a site-quality bonus. Do not cancel CDN risk
    # with a negative preference for a familiar brand/domain.
    # R48-M1: the old case matched unbounded substrings on "$org $domain",
    # so an unrelated org such as METANET AG scored as Meta (1000) and
    # was graded R / excluded from auto-select (which only takes A/B/C).
    # Match vendor names as whole words in the org (non-alphanumerics
    # are word separators) and as whole labels in the domain instead.
    # Penalties and branch precedence are unchanged.
    local _ow=" ${org//[^a-z0-9]/ } " _dw=" ${domain//./ } "
    case "$_ow $_dw" in
        *" cloudflare "*|*" cloudfront "*|*" fastly "*|*" akamai "*|*" edgecast "*|*" stackpath "*|*" bunny "*|*" cdn77 "*) penalty=500 ;;
        *" google "*|*" facebook "*|*" meta "*|*" telegram "*|*" twitter "*|*" openai "*|*" anthropic "*|*" huggingface "*|*" apple "*|*" icloud "*) penalty=1000 ;;
        *" amazon "*|*" aws "*) penalty=220 ;;
        *" microsoft "*|*" verizon "*) penalty=180 ;;
    esac
    printf '%s\n' "$penalty"
}

sni_domain_public_dns() {
    sni_resolve_public_ip "${1:-}" >/dev/null
}

sni_raw_score() {
    local app="$1" start="$2" total="$3" penalty="$4"
    # Preserve signed scores. Clamping negative values to 0 made many preferred
    # domains tie at zero and then appear alphabetically instead of by score.
    awk -v app="$app" -v start="$start" -v total="$total" -v p="$penalty" \
        'BEGIN { printf "%d\n", int(app*1000 + start*220 + total*60 + p) }'
}

sni_adjust_score() {
    local score="$1" adjustment="$2"
    # Lower is better; keep ASN/country/CDN adjustments signed and sortable.
    awk -v s="$score" -v a="$adjustment" \
        'BEGIN { printf "%d\n", int(s) + int(a) }'
}

sni_probe_domain() {
    local domain="$1" raw="$2" timeout_s="${3:-6}" metrics code _t_connect t_app t_start t_total http_version remote_ip penalty score target_ip resolve_entry curl_args=()
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 0
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || return 0
    timeout_s=$((10#$timeout_s))
    (( timeout_s > 300 )) && timeout_s=300
    # Resolve once, reject non-public answers, and pin curl to the accepted IP.
    # This avoids mixing validation for one address with a request to another.
    target_ip=$(sni_resolve_public_ip "$domain") || return 0
    if [[ "$target_ip" == *:* ]]; then resolve_entry="${domain}:443:[${target_ip}]"; else resolve_entry="${domain}:443:${target_ip}"; fi
    if [[ "${ABOX_CURL_TLS13_SUPPORTED:-0}" == '1' ]]; then curl_args+=(--tlsv1.3); fi
    if [[ "${ABOX_CURL_HTTP2_SUPPORTED:-0}" == '1' ]]; then curl_args+=(--http2); fi
    metrics=$(curl --noproxy '*' --resolve "$resolve_entry" -sSI "${curl_args[@]}" \
        --connect-timeout "$timeout_s" --max-time "$((timeout_s + 4))" \
        -o /dev/null \
        -w '%{http_code}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{http_version}\t%{remote_ip}' \
        "https://${domain}/" 2>/dev/null) || return 0
    IFS=$'\t' read -r code _t_connect t_app t_start t_total http_version remote_ip <<< "$metrics"
    [[ "$remote_ip" == "$target_ip" ]] || return 0
    [[ "$t_app" =~ ^[0-9.]+$ ]] || return 0
    awk -v v="$t_app" 'BEGIN{exit !(v>0)}' || return 0
    penalty=$(sni_domain_penalty "$domain")
    [[ "$http_version" == '2' || "$http_version" == '3' ]] || penalty=$((penalty + 350))
    [[ "$code" =~ ^(2|3|4)[0-9][0-9]$ ]] || penalty=$((penalty + 120))
    score=$(sni_raw_score "$t_app" "$t_start" "$t_total" "$penalty")
    printf '%s\t%s\tapp=%ss\tttfb=%ss\ttotal=%ss\thttp=%s\tcode=%s\tip=%s\n' "$score" "$domain" "$t_app" "$t_start" "$t_total" "$http_version" "$code" "$remote_ip" >> "$raw"
}

sni_san_matches_domain() {
    local domain="${1,,}" sanext="${2:-}" name suffix rest
    valid_domain "$domain" || return 1
    # Parse DNS SAN names as values, not as a regular expression assembled
    # from user-controlled domain text. Wildcards match exactly one label.
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        name="${name,,}"
        [[ "$name" == "$domain" ]] && return 0
        case "$name" in
            \*.*)
                suffix="${name#*.}"
                [[ "$domain" == *.* ]] || continue
                rest="${domain#*.}"
                [[ "$rest" == "$suffix" ]] && return 0
                ;;
        esac
    done < <(printf '%s\n' "$sanext" | awk '{ while (match($0, /DNS:[^, \t\r]+/)) { item=substr($0,RSTART,RLENGTH); sub(/^DNS:/,"",item); print item; $0=substr($0,RSTART+RLENGTH) } }')
    return 1
}

sni_openssl_check() {
    local domain="$1" timeout_s="${2:-5}" target_ip="${3:-}" connect_target out cert sanext alpn='none' tls13=0 san=0
    command -v openssl >/dev/null 2>&1 || { printf 'tls13=unknown\talpn=unknown\tsan=unknown'; return 0; }
    valid_public_ip "$target_ip" || { printf 'tls13=0\talpn=none\tsan=0'; return 0; }
    if [[ "$target_ip" == *:* ]]; then connect_target="[${target_ip}]:443"; else connect_target="${target_ip}:443"; fi
    out=$(printf '' | timeout "$timeout_s" openssl s_client -connect "$connect_target" -servername "$domain" -alpn 'h2,http/1.1' -tls1_3 -showcerts 2>/dev/null | tr -d '\000') || out=''
    if [[ -n "$out" ]]; then
        grep -qiE 'Protocol *: *TLSv1\.3|New, TLSv1\.3' <<< "$out" && tls13=1
        alpn=$(awk -F': ' '/ALPN protocol/{print $2; exit}' <<< "$out")
        [[ -n "$alpn" ]] || alpn='none'
        cert=$(awk 'BEGIN{p=0}/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}' <<< "$out")
        if [[ -n "$cert" ]]; then
            sanext=$(printf '%s\n' "$cert" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
            sni_san_matches_domain "$domain" "$sanext" && san=1
        fi
    fi
    printf 'tls13=%s\talpn=%s\tsan=%s' "$tls13" "$alpn" "$san"
}

sni_verify_raw_report() {
    local raw_sorted="$1" verified="$2" verify_limit="${3:-240}" timeout_s="${4:-5}" line score domain c3 c4 c5 c6 c7 c8 check tls13 alpn san add adj n=0
    local asn_cache vps_ip vps_meta vps_asn vps_country target_ip target_meta target_asn target_country target_org asn_match same_country cdn_penalty progress_every=20
    : > "$verified" || return 1
    asn_cache=$(mktemp -d /tmp/A-Box-asn-cache.XXXXXX) || die 'SNI ASN cache directory creation failed; refusing to use a shared temporary directory.'
    # R48-L1: the three `|| return 1` exits below run before the
    # explicit cleanup at the end; a RETURN trap guarantees the cache
    # directory is removed on every exit path (same pattern as the
    # _jq_cfg trap in routing_apply_live).
    # L10-fix: a RETURN trap is a single global slot. The trap above
    # stayed installed after this function returned and refired on
    # every later function return with $asn_cache already unbound
    # (fatal under set -u; it killed $(sni_auto_select_default) and
    # emptied the default SNI). Save the caller's trap and restore it
    # from inside the action, else clear the slot, so the cleanup
    # fires exactly once (same pattern as the jq() shim).
    local _asn_caller_trap=''
    _asn_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'rm -rf -- "$asn_cache" 2>/dev/null || true; if [[ -n "${_asn_caller_trap:-}" ]]; then eval "$_asn_caller_trap"; else trap - RETURN; fi; true' RETURN
    vps_ip=$(get_public_ip 2>/dev/null || true)
    vps_meta=$(asn_lookup_ip "$vps_ip" "$asn_cache")
    vps_asn=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="asn"){print $(i+1); exit}}' <<< "$vps_meta")
    vps_country=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="country"){print $(i+1); exit}}' <<< "$vps_meta")
    [[ -n "$vps_asn" ]] || vps_asn='unknown'
    [[ -n "$vps_country" ]] || vps_country='unknown'
    msg "${YELLOW}[*] Stage 2: OpenSSL verification + ASN/topology scoring. VPS ${vps_ip:-N/A} ${vps_asn}/${vps_country}${NC}" >&2
    while IFS=$'\t' read -r score domain c3 c4 c5 c6 c7 c8; do
        n=$((n + 1))
        (( n > verify_limit )) && break
        if (( n == 1 || n % progress_every == 0 )); then
            printf '\r[*] Stage 2 progress: %d/%d verified' "$n" "$verify_limit" >&2
        fi
        # Extract and validate the stage-1 connected IP before stage-2 TLS.
        # Do not perform a second DNS lookup or invoke OpenSSL with an unset IP.
        target_ip="${c8#ip=}"
        if valid_public_ip "$target_ip"; then
            check=$(sni_openssl_check "$domain" "$timeout_s" "$target_ip")
            tls13=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="tls13"){print $(i+1); exit}}' <<< "$check")
            alpn=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="alpn"){print $(i+1); exit}}' <<< "$check")
            san=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="san"){print $(i+1); exit}}' <<< "$check")
        else
            target_ip='N/A'
            check=$'tls13=0\talpn=none\tsan=0'
            tls13=0
            alpn='none'
            san=0
        fi
        target_meta=$(asn_lookup_ip "$target_ip" "$asn_cache")
        target_asn=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="asn"){print $(i+1); exit}}' <<< "$target_meta")
        target_country=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="country"){print $(i+1); exit}}' <<< "$target_meta")
        target_org=$(awk -F'\t|=' '{for(i=1;i<=NF;i++) if($i=="org"){print $(i+1); exit}}' <<< "$target_meta")
        [[ -n "$target_asn" ]] || target_asn='unknown'
        [[ -n "$target_country" ]] || target_country='unknown'
        [[ -n "$target_org" ]] || target_org='unknown'
        asn_match=0
        same_country=0
        [[ "$vps_asn" != 'unknown' && "$target_asn" == "$vps_asn" ]] && asn_match=1
        [[ "$vps_country" != 'unknown' && "$target_country" == "$vps_country" ]] && same_country=1
        add=0
        [[ "$tls13" == '1' ]] || add=$((add + 6000))
        [[ "$san" == '1' ]] || add=$((add + 6000))
        [[ "$alpn" == 'h2' ]] || add=$((add + 700))
        cdn_penalty=$(sni_org_cdn_penalty "$domain" "$target_org")
        add=$((add + cdn_penalty))
        [[ "$same_country" == '1' ]] && add=$((add - 250))
        # Strongly prefer a tested target in the VPS's own ASN, but never let
        # topology override hard TLS/SAN checks or erase explicit CDN risk.
        [[ "$asn_match" == '1' ]] && add=$((add - 1500))
        adj=$(sni_adjust_score "$score" "$add")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tasn=%s\tcountry=%s\tasnmatch=%s\tsamecountry=%s\torg=%s\tcdnpenalty=%s\n' \
            "$adj" "$domain" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$check" "$target_asn" "$target_country" "$asn_match" "$same_country" "$target_org" "$cdn_penalty" >> "$verified" || return 1
    done < "$raw_sorted" || return 1
    printf '\r[*] Stage 2 progress: %d/%d verified\n' "$(( n > verify_limit ? verify_limit : n ))" "$verify_limit" >&2
    LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$verified" -o "$verified" || return 1
    rm -rf "$asn_cache" 2>/dev/null || true
}

# M-7: pad Stage-1 (8-column) rows to the 17-column verified shape so a
# Stage-2 fallback keeps its Stage-1 score instead of misgrading as D.
# Rows that already carry 17 columns pass through unchanged; the
# tls13/alpn/san markers read as tier U (unverified), never A/B/C.
_sni_pad_unverified_rows() { # $1 = 8-col raw_sorted, $2 = out file
    local _in="$1" _out="$2"
    [[ -f "$_in" && -s "$_in" && -n "$_out" ]] || return 1
    awk -F'\t' 'NF == 8 { print $0 "\ttls13=unknown\talpn=unknown\tsan=unknown\tasn=unknown\tcountry=unknown\tasnmatch=0\tsamecountry=0\torg=unknown\tcdnpenalty=0"; next } { print }' "$_in" > "$_out" 2>/dev/null || return 1
    [[ -s "$_out" ]] || return 1
}

sni_report_fit_tier() {
    local tls13="${1#tls13=}" alpn="${2#alpn=}" san="${3#san=}" \
        asn_match="${4#asnmatch=}" same_country="${5#samecountry=}" \
        cdn_penalty="${6#cdnpenalty=}"
    [[ "$cdn_penalty" =~ ^-?[0-9]+$ ]] || cdn_penalty=0
    if [[ "$tls13" == 'unknown' || "$alpn" == 'unknown' || "$san" == 'unknown' ]]; then
        # M-7: Stage 2 never ran for this row (fallback padding, or
        # openssl unavailable): it is unverified, not a failure.
        # Grade U (visible, never a safe fit) instead of the hard D
        # the check below would give. U is skipped by auto-select and
        # refused by the Amazon fallback, so no unverified SNI is
        # ever adopted on this path. (R would mislabel: its messages
        # claim the protocol checks passed.)
        printf 'U\n'
    elif [[ "$tls13" != '1' || "$alpn" != 'h2' || "$san" != '1' ]]; then
        printf 'D\n'
    elif (( cdn_penalty >= 300 )); then
        # Keep risky targets visible for analysis, but do not label them a safe fit.
        printf 'R\n'
    elif [[ "$asn_match" == '1' ]]; then
        printf 'A\n'
    elif [[ "$same_country" == '1' ]]; then
        printf 'B\n'
    else
        printf 'C\n'
    fi
}

sni_build_diverse_candidate_pool() {
    local input="${1:-}" output="${2:-}"
    [[ -f "$input" && ! -L "$input" && -n "$output" ]] || return 1
    awk '
        function root_domain(host, labels, n, suffix) {
            n = split(host, labels, /[.]/)
            if (n < 2) return host
            suffix = labels[n-1] "." labels[n]
            if (multi_suffix[suffix]) {
                if (n < 3) return host
                return labels[n-2] "." suffix
            }
            return suffix
        }
        BEGIN {
            # Compact Public Suffix List subset for common multi-label country suffixes.
            # Unknown suffixes use the conventional final-two-label heuristic.
            n = split("ac.uk co.uk gov.uk ltd.uk me.uk net.uk nhs.uk org.uk plc.uk police.uk sch.uk com.au edu.au gov.au id.au net.au org.au asn.au co.nz net.nz org.nz govt.nz ac.nz school.nz ac.jp co.jp go.jp ne.jp or.jp co.kr go.kr ne.kr or.kr re.kr com.cn edu.cn gov.cn net.cn org.cn com.hk edu.hk gov.hk idv.hk net.hk org.hk com.sg edu.sg gov.sg net.sg org.sg com.tw edu.tw gov.tw idv.tw net.tw org.tw com.br edu.br gov.br net.br org.br com.mx edu.mx gob.mx net.mx org.mx com.tr edu.tr gov.tr net.tr org.tr com.ar edu.ar gov.ar net.ar org.ar com.co net.co org.co com.pe net.pe org.pe com.ve net.ve org.ve com.ec net.ec org.ec com.pl com.ua gov.ua net.ua org.ua co.za gov.za net.za org.za com.my edu.my gov.my net.my org.my com.ph edu.ph gov.ph net.ph org.ph com.vn edu.vn gov.vn net.vn org.vn ac.id co.id go.id or.id sch.id web.id ac.th co.th go.th net.th or.th com.pk edu.pk gov.pk net.pk org.pk com.bd edu.bd gov.bd net.bd org.bd com.ng edu.ng gov.ng net.ng org.ng com.eg edu.eg gov.eg net.eg org.eg com.sa edu.sa gov.sa net.sa org.sa ac.il co.il gov.il net.il org.il co.ke go.ke or.ke com.ps net.ps org.ps com.do net.do org.do com.pr net.pr org.pr com.py net.py org.py com.uy net.uy org.uy com.bo net.bo org.bo com.gt net.gt org.gt com.pa net.pa org.pa com.cy net.cy org.cy com.ro net.ro org.ro com.gr net.gr org.gr com.pt net.pt org.pt com.es org.es", suffixes, /[ ]+/)
            for (i = 1; i <= n; i++) multi_suffix[suffixes[i]] = 1
        }
        {
            line = tolower($0)
            gsub(/^[ \t\r]+/, "", line)
            gsub(/[ \t\r]+$/, "", line)
            if (line == "" || line ~ /^#/) next
            # Portable ERE: avoid {n,m} intervals (mawk does not support them).
            if (line !~ /^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z][a-z]+$/) next
            if (line ~ /(^|[.])microsoft[.]com$/ || line ~ /(^|[.])bing[.]com$/ || line ~ /(^|[.])amazon[.]com$/) next
            if (line ~ /^(api|status|cdn|assets|static|img|images|auth|login|mail|smtp|metrics|telemetry|edge|mobile|support|help|download|downloads|registry|acme-v02)[.]/) next
            count = split(line, labels, /[.]/)
            suffix = labels[count-1] "." labels[count]
            # Permit www.example.co.uk while still rejecting deeper, less predictable hosts.
            if (count > 3 && !(count == 4 && multi_suffix[suffix])) next
            key = root_domain(line)
            if (!seen[key]++) print line
        }
    ' "$input" > "$output"
}

sni_auto_select_default() {
    local fallback='www.amazon.com' workdir seed pool candidates raw raw_sorted verified
    local total step running=0 domain score app ttfb total_time http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty tier selected=''
    local timeout_s=2 candidate_limit=16 verify_limit=6

    # A target is selected from this VPS's real outbound path, not from a global
    # brand preference. VPS ASN/country, TLS 1.3, HTTP/2 ALPN, SAN and measured
    # handshake latency affect ranking. Hardware model is not a reliable SNI predictor.
    command -v curl >/dev/null 2>&1 || { sni_verified_amazon_fallback; return $?; }
    command -v openssl >/dev/null 2>&1 || { sni_verified_amazon_fallback; return $?; }
    workdir=$(mktemp -d /tmp/A-Box-sni-auto.XXXXXX) || { sni_verified_amazon_fallback; return $?; }
    chmod 700 "$workdir" 2>/dev/null || { rm -rf -- "$workdir"; sni_verified_amazon_fallback; return $?; }
    # M-7: save/restore traps (L10-fix pattern). Every return path
    # below already removes $workdir; the RETURN trap guarantees the
    # probe jobs are killed and the workdir reaped even on a return
    # taken before the explicit cleanup, and restores the caller's
    # traps so nothing persists after this function returns. The EXIT
    # trap covers die()/exit inside a callee (e.g. sni_verify_raw_report).
    local _sni_auto_caller_trap='' _sni_auto_caller_exit_trap='' _sni_auto_caller_int_trap='' _sni_auto_caller_term_trap=''
    _sni_auto_caller_exit_trap=$(trap -p EXIT 2>/dev/null || true)
    _sni_auto_caller_int_trap=$(trap -p INT 2>/dev/null || true)
    _sni_auto_caller_term_trap=$(trap -p TERM 2>/dev/null || true)
    _sni_auto_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    # L11: restore the caller's EXIT trap only in the main shell
    # (BASHPID == $$). In a command-substitution subshell (BASHPID != $$,
    # e.g. $(sni_auto_select_default) in pre_install_setup), re-installing
    # it makes deployment_transaction_exit_abort fire at subshell exit;
    # its rollback msg goes to stdout (msg has no >&2) and pollutes the
    # captured SNI, so valid_sni fails although a candidate verified --
    # 11 consecutive main-menu failures vs 5 §7 passes (no transaction
    # trap there). A re-installed EXIT trap in a subshell can only fire
    # at subshell exit, never usefully, so skipping the restore there
    # loses nothing; the main shell keeps its transaction protection.
    # Same hazard class as die()'s H-17 owner gate (a rollback hook must
    # never run in a non-owner child shell); here the gate is the
    # trap-agnostic main-shell check, since any stdout-printing caller
    # EXIT trap would pollute the capture the same way.
    trap 'trap - RETURN EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_auto_caller_trap:-}" ]]; then eval "$_sni_auto_caller_trap"; fi; if [[ "$BASHPID" == "$$" && -n "${_sni_auto_caller_exit_trap:-}" ]]; then eval "$_sni_auto_caller_exit_trap"; fi; if [[ -n "${_sni_auto_caller_int_trap:-}" ]]; then eval "$_sni_auto_caller_int_trap"; fi; if [[ -n "${_sni_auto_caller_term_trap:-}" ]]; then eval "$_sni_auto_caller_term_trap"; fi; true' RETURN
    trap 'trap - RETURN EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_auto_caller_exit_trap:-}" ]]; then eval "$_sni_auto_caller_exit_trap"; fi' EXIT
    trap 'trap - RETURN EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_auto_caller_exit_trap:-}" ]]; then eval "$_sni_auto_caller_exit_trap"; fi; exit 130' INT
    trap 'trap - RETURN EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_auto_caller_exit_trap:-}" ]]; then eval "$_sni_auto_caller_exit_trap"; fi; exit 143' TERM

    seed="$workdir/seed.txt"
    pool="$workdir/pool.txt"
    candidates="$workdir/candidates.txt"
    raw="$workdir/results.raw.tsv"
    raw_sorted="$workdir/results.sorted.tsv"
    verified="$workdir/results.verified.tsv"
    : > "$seed"
    if ! sni_load_candidate_seed "$seed" >&2; then
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    fi

    # Use a registrable-domain-aware pool; unrelated multi-label country domains
    # must not collapse to a shared suffix such as "co.uk" or "com.au".
    sni_build_diverse_candidate_pool "$seed" "$pool" || {
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    }
    [[ -s "$pool" ]] || {
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    }

    total=$(wc -l < "$pool" | tr -d ' ')
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    (( total > 0 )) || {
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    }
    step=$(( (total + candidate_limit - 1) / candidate_limit ))
    (( step >= 1 )) || step=1
    awk -v step="$step" 'NR == 1 || (NR - 1) % step == 0 { print; picked++; if (picked >= 16) exit }' "$pool" > "$candidates"
    [[ -s "$candidates" ]] || {
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    }

    ABOX_CURL_TLS13_SUPPORTED=0
    ABOX_CURL_HTTP2_SUPPORTED=0
    { curl --help all 2>/dev/null || curl --help 2>/dev/null; } | grep -F -- '--tlsv1.3' >/dev/null && ABOX_CURL_TLS13_SUPPORTED=1
    curl --version 2>/dev/null | grep -qw 'HTTP2' && ABOX_CURL_HTTP2_SUPPORTED=1
    : > "$raw"
    while IFS= read -r domain; do
        # Detach probe subshells from the terminal stdin so stray keystrokes
        # during the long run cannot be consumed by them.
        sni_probe_domain "$domain" "$raw" "$timeout_s" </dev/null &
        running=$((running + 1))
        if (( running >= 8 )); then
            wait || true
            running=0
        fi
    done < "$candidates"
    wait || true
    if [[ ! -s "$raw" ]]; then
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    fi

    LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$raw" > "$raw_sorted" || {
        rm -rf -- "$workdir"
        sni_verified_amazon_fallback
        return $?
    }
    # Deep verification is intentionally bounded to keep the install wizard usable.
    if ! sni_verify_raw_report "$raw_sorted" "$verified" "$verify_limit" 3 >&2; then
        # M-7: same fallback as run_builtin_sni_radar: keep the Stage-1
        # rows (padded to 17 columns) instead of discarding them. The
        # padded rows grade U, never A/B/C, so the tier loop below still
        # falls through to the verified Amazon fallback when nothing
        # verified.
        if ! _sni_pad_unverified_rows "$raw_sorted" "$verified"; then
            rm -rf -- "$workdir"
            sni_verified_amazon_fallback
            return $?
        fi
    fi

    while IFS=$'\t' read -r score domain app ttfb total_time http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty; do
        [[ -n "$domain" ]] || continue
        tier=$(sni_report_fit_tier "$tls13" "$alpn" "$san" "$asnmatch" "$samecountry" "$cdnpenalty")
        case "$tier" in
            A|B|C)
                selected="$domain"
                break
                ;;
        esac
    done < "$verified"

    rm -rf -- "$workdir"
    if valid_sni "$selected"; then
        printf '[SNI auto] %s\n' "$(tprintf sni_auto_select_default_chosen "$selected")" >&2
        printf '%s\n' "$selected"
    else
        printf '[SNI auto] %s\n' "$(tr_msg sni_auto_select_default_amazon_fallback)" >&2
        sni_verified_amazon_fallback
    fi
}
# Deploy-time SNI choice: Enter keeps the automatic selection;
# a typed domain is validated and used instead. Prompts go to
# stderr so the result can be captured with $(...).
sni_prompt_or_auto() {
    local _in='' _tier='' _answer='' _dns_rc=0 _label="${1:-Trojan-Reality}"
    while true; do
        printf '%s' "$(tr_msg sni_custom_prompt)" >&2
        read -r _in || _in=''
        _in=$(printf '%s' "$_in" | tr -d '[:space:]')
        # Empty input, or an unparseable typed value, keeps the legacy
        # behaviour: fall back to the verified auto-select.
        if [[ -z "$_in" ]] || ! valid_sni "$_in"; then
            [[ -n "$_in" ]] && printf '%s\n' "$(tr_msg sni_custom_invalid)" >&2
            sni_auto_select_default 2>/dev/null || { printf '%s\n' '[SNI auto] No verified SNI candidate is available; refusing to substitute an unverified fallback.' >&2; return 1; }
            return 0
        fi
        # F-NEW-03: a typed domain that does not resolve can never
        # complete a Reality handshake, so it is refused outright and
        # the user is re-prompted (Enter still falls back to auto-select).
        sni_dns_resolvable "$_in"; _dns_rc=$?
        if (( _dns_rc == 1 )); then
            printf '%s\n' "${RED}[SNI custom] $(tprintf sni_unresolvable "$_in")$NC" >&2
            continue
        fi
        _tier=$(sni_probe_candidate_tier "$_in" 2>/dev/null || printf 'N')
        case "$_tier" in
            A|B|C)
                printf '%s\n' "${GREEN}[SNI custom] $(tprintf sni_ok_tier "$_tier")$NC" >&2
                printf '%s' "$_in"
                return 0
                ;;
            R)
                printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_risky)$NC" >&2
                ;;
            D)
                printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_fail)$NC" >&2
                ;;
            *)
                printf '%s\n' "${YELLOW}[SNI custom] $(tr_msg sni_untestable)$NC" >&2
                ;;
        esac
        # R/D/N: loud warning above; explicit second confirmation, default refuse.
        read -r -p "$(tprintf continue_or_reset "$_label")" _answer || continue
        is_yes "$_answer" && { printf '%s' "$_in"; return 0; }
    done
}


sni_render_ranked_report() {
    local report_file="${1:-}" requested_limit="${2:-100}" display_dir selected_file
    local row score domain app ttfb total http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty tier
    local bucket count color heading rank local_bucket_file
    [[ -s "$report_file" ]] || { msg "${YELLOW}[!] $(tr_msg sni_render_ranked_report_no_records)${NC}"; return 1; }
    valid_decimal_upto "$requested_limit" 200 || requested_limit=100
    (( 10#$requested_limit >= 1 )) || requested_limit=100
    display_dir=$(mktemp -d /tmp/A-Box-sni-display.XXXXXX) || return 1
    selected_file="$display_dir/selected.tsv"
    head -n "$requested_limit" "$report_file" > "$selected_file" || { rm -rf -- "$display_dir"; return 1; }
    for bucket in A R B C D U; do : > "$display_dir/$bucket.tsv"; done
    while IFS= read -r row; do
        IFS=$'\t' read -r score domain app ttfb total http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty <<< "$row"
        [[ "$score" =~ ^-?[0-9]+$ && -n "$domain" ]] || continue
        tier=$(sni_report_fit_tier "$tls13" "$alpn" "$san" "$asnmatch" "$samecountry" "$cdnpenalty")
        printf '%s\n' "$row" >> "$display_dir/$tier.tsv"
    done < "$selected_file"
    msg "${CYAN}$(tprintf sni_show_first "$requested_limit")${NC}"
    for bucket in A R B C D U; do
        local_bucket_file="$display_dir/$bucket.tsv"
        count=$(wc -l < "$local_bucket_file" | tr -d ' ')
        (( count > 0 )) || continue
        case "$bucket" in
            A) color="$GREEN"; heading="$(tr_msg sni_tier_A)" ;;
            R) color="$YELLOW"; heading="$(tr_msg sni_tier_R)" ;;
            B) color="$CYAN"; heading="$(tr_msg sni_tier_B)" ;;
            C) color="$BLUE"; heading="$(tr_msg sni_tier_C)" ;;
            D) color="$RED"; heading="$(tr_msg sni_tier_D)" ;;
            U) color="$YELLOW"; heading="$(tr_msg sni_untestable)" ;;
        esac
        msg "${color}[${heading}｜${count} $(tr_msg sni_count_unit)]${NC}"
        rank=0
        while IFS= read -r row; do
            IFS=$'\t' read -r score domain app ttfb total http code ip tls13 alpn san asn country asnmatch samecountry org cdnpenalty <<< "$row"
            rank=$((rank + 1))
            printf '%s%3d. [score=%s] %-38s app=%-10s ttfb=%-10s total=%-10s HTTP/%s code=%s %s %s %s ASN=%s country=%s sameASN=%s sameRegion=%s cdnRisk=%s IP=%s%s\n' \
                "$color" "$rank" "$score" "$domain" "${app#app=}" "${ttfb#ttfb=}" "${total#total=}" \
                "${http#http=}" "${code#code=}" "$tls13" "$alpn" "$san" "${asn#asn=}" \
                "${country#country=}" "${asnmatch#asnmatch=}" "${samecountry#samecountry=}" \
                "${cdnpenalty#cdnpenalty=}" "${ip#ip=}" "$NC"
        done < "$local_bucket_file"
    done
    rm -rf -- "$display_dir"
    return 0
}

run_builtin_sni_radar() {
    local profile="${1:-full}" title="${2:-Local SNI selection}" workdir candidates raw raw_sorted report total concurrency timeout_s running=0 domain topn verify_limit processed=0 valid_count=0 progress_every
    workdir=$(mktemp -d /tmp/A-Box-sni-radar.XXXXXX) || die "$(tr_msg sn_tmp_fail)"
    # M-7: save/restore EXIT/INT/TERM traps (L10-fix pattern). die()
    # exits mid-function and background probes survive Ctrl-C unless
    # the probe jobs are killed and the workdir reaped here. Each body
    # clears the traps first so cleanup fires exactly once, then
    # re-installs the caller's EXIT trap so a caller cleanup still
    # runs on exit; INT/TERM exit 130/143 after cleanup.
    local _sni_radar_caller_exit_trap='' _sni_radar_caller_int_trap='' _sni_radar_caller_term_trap=''
    _sni_radar_caller_exit_trap=$(trap -p EXIT 2>/dev/null || true)
    _sni_radar_caller_int_trap=$(trap -p INT 2>/dev/null || true)
    _sni_radar_caller_term_trap=$(trap -p TERM 2>/dev/null || true)
    trap 'trap - EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_radar_caller_exit_trap:-}" ]]; then eval "$_sni_radar_caller_exit_trap"; fi' EXIT
    trap 'trap - EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_radar_caller_exit_trap:-}" ]]; then eval "$_sni_radar_caller_exit_trap"; fi; exit 130' INT
    trap 'trap - EXIT INT TERM; kill $(jobs -rp) 2>/dev/null || true; rm -rf -- "${workdir:-}" 2>/dev/null || true; if [[ -n "${_sni_radar_caller_exit_trap:-}" ]]; then eval "$_sni_radar_caller_exit_trap"; fi; exit 143' TERM
    candidates="$workdir/candidates.txt"
    raw="$workdir/results.raw.tsv"
    raw_sorted="$workdir/results.raw.sorted.tsv"
    report="$workdir/results.tsv"
    write_sni_candidate_library "$profile" "$candidates"
    if { curl --help all 2>/dev/null || curl --help 2>/dev/null; } | grep -F -- '--tlsv1.3' >/dev/null; then
        ABOX_CURL_TLS13_SUPPORTED=1
    else
        ABOX_CURL_TLS13_SUPPORTED=0
    fi
    if curl --version 2>/dev/null | grep -qw 'HTTP2'; then
        ABOX_CURL_HTTP2_SUPPORTED=1
    else
        ABOX_CURL_HTTP2_SUPPORTED=0
    fi
    total=$(wc -l < "$candidates" | tr -d ' ')
    if [[ "$profile" == 'mini' ]]; then
        # Mini mode uses the same candidate library as full mode. It reduces concurrency and verification depth only.
        # Mini defaults (2026-10-19): 5-version A/B test on 2 VPS showed
        # concurrency=32/timeout=3 is ~25% faster than 8/5 with identical
        # valid counts and 9/10 top-pick overlap. Env overrides still work.
        concurrency="${ABOX_SNI_MINI_CONCURRENCY:-32}"
        timeout_s="${ABOX_SNI_MINI_TIMEOUT:-3}"
        topn="${ABOX_SNI_MINI_TOPN:-60}"
        verify_limit="${ABOX_SNI_MINI_VERIFY:-60}"
    else
        concurrency="${ABOX_SNI_FULL_CONCURRENCY:-36}"
        timeout_s="${ABOX_SNI_FULL_TIMEOUT:-6}"
        topn="${ABOX_SNI_FULL_TOPN:-100}"
        verify_limit="${ABOX_SNI_FULL_VERIFY:-120}"
    fi
    valid_decimal_upto "$concurrency" 256 || die "$(tr_msg sn_concurrency_range)"
    (( 10#$concurrency >= 1 )) || die "$(tr_msg sn_concurrency_min)"
    valid_decimal_upto "$timeout_s" 60 || die "$(tr_msg sn_timeout_range)"
    (( 10#$timeout_s >= 1 )) || die "$(tr_msg sn_timeout_min)"
    valid_decimal_upto "$verify_limit" 2048 || die "$(tr_msg sn_verify_range)"
    (( 10#$verify_limit >= 1 )) || die "$(tr_msg sn_verify_min)"
    valid_decimal_upto "$topn" 200 || die "$(tr_msg sn_topn_range)"
    (( 10#$topn >= 1 )) || die "$(tr_msg sn_topn_min)"
    # R12-08: validation reads these as decimal but the stored strings
    # keep leading zeros, which later arithmetic re-reads as octal
    # (08 errors, 010 means 8). Canonicalise all four now.
    concurrency=$((10#$concurrency))
    timeout_s=$((10#$timeout_s))
    verify_limit=$((10#$verify_limit))
    topn=$((10#$topn))
    progress_every=$(( concurrency * 2 ))
    (( progress_every < 20 )) && progress_every=20
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}${title}${NC}"
    msg "${CYAN}======================================================================${NC}"
    msg "${YELLOW}$(tprintf sn_lib_line "$total" "$profile" "$concurrency" "$verify_limit" "$topn")${NC}"
    msg "${YELLOW}$(tr_msg sn_stage_line)${NC}"
    msg "${YELLOW}$(tr_msg sn_asn_line)${NC}"
    msg "${YELLOW}$(tr_msg sn_internal_line)${NC}"
    msg "${YELLOW}$(tr_msg sn_progress_line)${NC}"
    : > "$raw"
    while IFS= read -r domain; do
        sni_probe_domain "$domain" "$raw" "$timeout_s" </dev/null &
        running=$((running + 1))
        processed=$((processed + 1))
        if (( running >= concurrency )); then
            # PERF (2026-11-25): work-conserving worker pool. The old code
            # waited for the WHOLE batch here, so one 3 s straggler idled
            # the other (concurrency-1) slots until the batch drained.
            # `wait -n` reaps one finished probe and the loop launches the
            # next domain at once, keeping all slots busy. Bounded
            # concurrency is unchanged (mini 32 / full 36 defaults);
            # `wait -n` needs bash 4.3+ and the script requires 4.4+.
            wait -n || true
            running=$((running - 1))
            valid_count=$(wc -l < "$raw" 2>/dev/null | tr -d ' ')
            printf '\r[*] Stage 1 progress: %d/%d tested | valid=%s' "$(( processed - running ))" "$total" "${valid_count:-0}" >&2
        elif (( processed % progress_every == 0 )); then
            valid_count=$(wc -l < "$raw" 2>/dev/null | tr -d ' ')
            printf '\r[*] Stage 1 progress: %d/%d queued | valid=%s' "$processed" "$total" "${valid_count:-0}" >&2
        fi
    done < "$candidates"
    wait
    valid_count=$(wc -l < "$raw" 2>/dev/null | tr -d ' ')
    printf '\r[*] Stage 1 progress: %d/%d tested | valid=%s\n' "$processed" "$total" "${valid_count:-0}" >&2
    if [[ ! -s "$raw" ]]; then
        rm -rf "$workdir"
        die "$(tr_msg sn_no_results)"
    fi
    LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$raw" > "$raw_sorted"
    if ! sni_verify_raw_report "$raw_sorted" "$report" "$verify_limit" "$timeout_s"; then
        _sni_pad_unverified_rows "$raw_sorted" "$report" || cp -f "$raw_sorted" "$report"
    fi
    if [[ ! -s "$report" ]]; then
        _sni_pad_unverified_rows "$raw_sorted" "$report" || cp -f "$raw_sorted" "$report"
    fi
    ensure_abox_dir_owned "$ABOX_DIR" || die "$(tr_msg sn_dir_untrusted)"
    local saved_report="$ABOX_DIR/A-Box-sni-${profile}.tsv"
    install_file_atomically "$report" "$saved_report" 600 || die "$(tr_msg sn_persist_fail)"
    [[ -s "$saved_report" && ! -L "$saved_report" ]] || die "$(tr_msg sn_persist_verify)"
    path_owned_by_root "$saved_report" || die "$(tr_msg sn_owner_verify)"
    path_mode_has_no_group_other_write "$saved_report" || die "$(tr_msg sn_perm_verify)"
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${YELLOW}[ $(tr_msg sn_top_title) ]${NC}"
    sni_render_ranked_report "$report" "$topn" || msg "${YELLOW}[!] $(tr_msg sn_render_fail)${NC}"
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${GREEN}$(tprintf sn_saved "${ABOX_DIR}/A-Box-sni-${profile}.tsv")${NC}"
    msg "${YELLOW}$(tr_msg sn_grade_note)${NC}"
    rm -rf "$workdir"
    # M-7: normal exit already reaped the workdir above; restore the
    # caller's traps so a later script exit does not re-run this cleanup.
    if [[ -n "$_sni_radar_caller_exit_trap" ]]; then eval "$_sni_radar_caller_exit_trap"; else trap - EXIT; fi
    if [[ -n "$_sni_radar_caller_int_trap" ]]; then eval "$_sni_radar_caller_int_trap"; else trap - INT; fi
    if [[ -n "$_sni_radar_caller_term_trap" ]]; then eval "$_sni_radar_caller_term_trap"; else trap - TERM; fi
    # Drain keystrokes typed during the long run; otherwise pause_return would
    # consume them instantly and the ranked results would flash by.
    while read -r -t 0 _ 2>/dev/null; do
        read -r -t 0.1 _ 2>/dev/null || break
    done
    pause_return
}

show_sni_preference_records() {
    clear
    local files=() f profile topn="${ABOX_SNI_RECORDS_TOPN:-100}" shown=0 mtime
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        *)
            msg "${BOLD}${GREEN}$(tr_msg sr_title)${NC}"
            ;;
    esac
    valid_decimal_upto "$topn" 200 || topn=100
    (( 10#$topn >= 1 )) || topn=100
    msg "${CYAN}======================================================================${NC}"
    for f in "$ABOX_DIR/A-Box-sni-full.tsv" "$ABOX_DIR/A-Box-sni-mini.tsv"; do
        [[ -s "$f" ]] && files+=("$f")
    done
    if (( ${#files[@]} == 0 )); then
        case "${ABOX_LANG:-zh}" in
            en)
            msg "${YELLOW}[!] No SNI selection record found. Run Toolbox option 9 or 10 first.${NC}"
                ;;
            ru)
            msg "${YELLOW}[!] Не найдена запись предпочтений SNI. Сначала запустите опцию 9 или 10 в Toolbox.${NC}"
                ;;
            fa)
            msg "${YELLOW}[!] رکورد ترجیح SNI یافت نشد. ابتدا گزینه 9 یا 10 جعبه‌ابزار را اجرا کنید.${NC}"
                ;;
            ja)
                msg "${YELLOW}[!] SNI の優先設定レコードが見つかりません。先に Toolbox のオプション 9 または 10 を実行してください。${NC}"
                ;;
            zh-tw)
            msg "${YELLOW}[!] 未發現 SNI 優選記錄。請先執行工具箱 9 或 10。${NC}"
                ;;
            *)
            msg "${YELLOW}[!] 未发现 SNI 优选记录。请先运行工具箱 9 或 10。${NC}"
                ;;
        esac
        pause_return
        return 0
    fi
    for f in "${files[@]}"; do
        profile="${f##*/A-Box-sni-}"
        profile="${profile%.tsv}"
        mtime=$(date -r "$f" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo 'unknown')
        msg "${BLUE}--------------------------------------------------------------------------------${NC}"
        case "${ABOX_LANG:-zh}" in
            *)
                msg "${YELLOW}$(tprintf sr_saved "$profile" "$f" "$mtime")${NC}"
                ;;
        esac
        sni_render_ranked_report "$f" "$topn" || msg "${YELLOW}[!] $(tr_msg show_sni_preference_records_unreadable)${NC}"
        shown=1
    done
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    if [[ "$shown" == '1' ]]; then
        msg "${YELLOW}Use only domains with tls13=1 and san=1. Prefer asnmatch=1/samecountry=1 when available.${NC}"
    fi
    pause_return
}

run_local_sni_benchmark() {
    if confirm_yes_no "$(tr_msg confirm_local_sni_full)"; then
        run_builtin_sni_radar 'full' "$(tr_msg run_local_sni_benchmark_title)"
    fi
}

run_local_sni_mini_benchmark() {
    if confirm_yes_no "$(tr_msg confirm_local_sni_mini)"; then
        run_builtin_sni_radar 'mini' "$(tr_msg run_local_sni_mini_benchmark_title)"
    fi
}



swapfile_active_state() {
    # Return 0=active, 1=definitely inactive, 2=query failure.
    # A query failure must never be interpreted as inactivity before a
    # destructive swapfile operation.
    local output='' line
    # N-08: use swapon when available (util-linux syntax); fall back to
    # /proc/swaps when swapon is missing (BusyBox swapon lacks --show).
    if command -v swapon >/dev/null 2>&1; then
        if ! output=$(swapon --show=NAME --noheadings 2>/dev/null); then
            # BusyBox swapon lacks --show: fall back to /proc/swaps
            # instead of reporting query failure (which callers treat
            # as "not active" before destructive operations).
            if [[ -r /proc/swaps ]]; then
                output=$(awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null) || return 2
            else
                return 2
            fi
        fi
    elif [[ -r /proc/swaps ]]; then
        output=$(awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null) || return 2
    else
        return 2
    fi
    while IFS= read -r line; do
        [[ "$line" == '/swapfile' ]] && return 0
    done <<< "$output"
    return 1
}

rollback_new_swap_activation_only() {
    # Used only before /etc/fstab has been modified. Never edits /etc/fstab.
    # This makes early setup failures independent of the generic rollback path,
    # which may remove A-Box swap entries from fstab.
    swapfile_active_state
    case $? in
        0) swapoff /swapfile >/dev/null 2>&1 || return 1 ;;
        1) ;;
        *) return 1 ;;
    esac
    if [[ -e /swapfile || -L /swapfile ]]; then
        rm -f -- /swapfile || return 1
    fi
    [[ ! -e /swapfile && ! -L /swapfile ]]
}

rollback_abox_new_swap() {
    local fstab_backup="${1:-}" rollback_tmp=''
    # R48-L2: _orig_mode must stay local; a bare assignment would
    # clobber a caller's same-named local via dynamic scoping.
    local _orig_mode=''
    if [[ -n "$fstab_backup" && -f "$fstab_backup" && ! -L "$fstab_backup" ]]; then
        if ! cp -a "$fstab_backup" /etc/fstab; then
            msg "${RED}[!] $(tr_msg rollback_abox_new_swap_fstab_unrecoverable)${NC}" >&2
            return 1
        fi
    else
        rollback_tmp=$(mktemp /etc/.fstab.A-Box-swap-rollback.XXXXXX) || return 1
        if ! awk '
          $0 == "# A-Box swap BEGIN" {
            if (skip) { print "A-Box swap: nested BEGIN" > "/dev/stderr"; exit 2 }
            skip=1; begin_seen=1; next
          }
          $0 == "# A-Box swap END" {
            if (!skip) { print "A-Box swap: END without BEGIN" > "/dev/stderr"; exit 2 }
            skip=0; end_seen=1; next
          }
          skip {next}
          {print}
          END {
            if (skip || (begin_seen && !end_seen) || (!begin_seen && end_seen)) {
              print "A-Box swap: unbalanced BEGIN/END markers; refusing to rewrite /etc/fstab" > "/dev/stderr"
              exit 2
            }
          }
        ' /etc/fstab > "$rollback_tmp"; then
            rm -f "$rollback_tmp"
            return 1
        fi
        # R6C13-01: preserve the original fstab mode
        # explicitly. BusyBox chmod lacks --reference;
        # falling back to 644 would loosen a 0600 fstab
        # holding CIFS credentials. Abort if unpreservable.
        _orig_mode=$(stat -c %a /etc/fstab 2>/dev/null) || { rm -f "$rollback_tmp";
            return 1
        }
        chmod "$_orig_mode" "$rollback_tmp" || { rm -f "$rollback_tmp";
            return 1
        }
        chown --reference=/etc/fstab "$rollback_tmp" 2>/dev/null || true
        mv -f "$rollback_tmp" /etc/fstab || { rm -f "$rollback_tmp"; return 1; }
    fi
    swapfile_active_state
    case $? in
        0) swapoff /swapfile >/dev/null 2>&1 || return 1 ;;
        1) ;;
        *) return 1 ;;
    esac
    rm -f /swapfile "$ABOX_DIR/.swapfile.managed"
    [[ ! -e /swapfile && ! -e "$ABOX_DIR/.swapfile.managed" ]]
}

fstab_path_is_safe() {
    [[ -f /etc/fstab && ! -L /etc/fstab ]] || return 1
    path_owned_by_root /etc/fstab || return 1
    path_mode_has_no_group_other_write /etc/fstab || return 1
}

setup_swap_2g() {
    local fstab_tmp='' fstab_backup='' free_kib=0 created_by_abox=0 last_byte="" _swap_nocow=0
    # R48-L2: _orig_mode must stay local (see rollback_abox_new_swap).
    local _orig_mode=''
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg setup_swap_2g_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    fstab_path_is_safe || die "$(tr_msg setup_swap_2g_fstab_not_safe)"
    [[ ! -L /swapfile ]] || die "$(tr_msg setup_swap_2g_no_symlink_swapfile)"
    if [[ -e /swapfile && ! -f /swapfile ]]; then die "$(tr_msg setup_swap_2g_swapfile_not_regular)"; fi
    if [[ -f /swapfile ]]; then
        [[ "$(stat -c %u:%g /swapfile 2>/dev/null || echo -1:-1)" == 0:0 ]] || die "$(tr_msg setup_swap_2g_swapfile_not_root_owned)"
        [[ "$(stat -c %a /swapfile 2>/dev/null || echo 999)" =~ ^0?600$ ]] || die "$(tr_msg setup_swap_2g_swapfile_perm_not_0600)"
        msg "${YELLOW}$(tr_msg swap_exists)${NC}"
    else
        free_kib=$(df -Pk / | awk 'NR==2{print $4}')
        [[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -ge 2300000 ]] || die "$(tprintf setup_swap_2g_root_free_low "${free_kib:-unknown}")"
        # R5C13-02: Btrfs COW swapfiles are rejected by swapon;
        # set NOCOW on the empty file before any extents exist.
        if [[ "$(stat -f -c %T / 2>/dev/null || echo unknown)" == "btrfs" ]]; then
            _swap_nocow=1
        fi
        if (( _swap_nocow == 1 )); then
            (umask 077 && : > /swapfile) || die "$(tr_msg setup_swap_2g_swap_file_create_failed)"
            chattr +C /swapfile 2>/dev/null || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_btrfs_nocow_failed)"; }
        fi
        if ! (umask 077 && fallocate -l 2G /swapfile 2>/dev/null); then
            rm -f /swapfile
            if (( _swap_nocow == 1 )); then
                (umask 077 && : > /swapfile) || die "$(tr_msg setup_swap_2g_swap_file_create_failed)"
                chattr +C /swapfile 2>/dev/null || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_btrfs_nocow_failed)"; }
            fi
            (umask 077 && dd if=/dev/zero of=/swapfile bs=1M count=2048) || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_create_failed)"; }
        fi
        created_by_abox=1
        chmod 600 /swapfile || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_chmod_failed)"; }
        chown root:root /swapfile || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_chown_failed)"; }
        mkswap /swapfile >/dev/null || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_mkswap_failed)"; }
    fi
    swapfile_active_state
    case $? in
        0) ;;
        1) if ! swapon /swapfile; then
            if (( created_by_abox == 1 )); then
                # M-32(1): a fallocate-built file can be rejected
                # by swapon; rebuild it with dd and retry once
                # instead of dying on the first failure. The
                # Btrfs NOCOW setup is re-applied: a COW file is
                # rejected the same way, so the rebuild must be
                # NOCOW again when the original was.
                rm -f -- /swapfile
                if (( _swap_nocow == 1 )); then
                    (umask 077 && : > /swapfile) || die "$(tr_msg setup_swap_2g_swap_file_create_failed)"
                    chattr +C /swapfile 2>/dev/null || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_btrfs_nocow_failed)"; }
                fi
                (umask 077 && dd if=/dev/zero of=/swapfile bs=1M count=2048) || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_create_failed)"; }
                chmod 600 /swapfile || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_chmod_failed)"; }
                chown root:root /swapfile || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_swap_file_chown_failed)"; }
                mkswap /swapfile >/dev/null || { rm -f /swapfile; die "$(tr_msg setup_swap_2g_mkswap_failed)"; }
                swapon /swapfile || { rm -f -- /swapfile; die "$(tr_msg setup_swap_2g_swapon_failed_no_fstab)"; }
            else
                die "$(tr_msg setup_swap_2g_swapon_failed_no_fstab)"
            fi
        fi ;;
        *) die "$(tr_msg setup_swap_2g_swap_active_unknown)" ;;
    esac
    if (( created_by_abox == 1 )); then
        if ! fstab_backup=$(mktemp /etc/.fstab.A-Box-setup-backup.XXXXXX); then
            if ! rollback_new_swap_activation_only; then
                die "$(tr_msg setup_swap_2g_fstab_backup_failed_swap_stuck)"
            fi
            die "$(tr_msg setup_swap_2g_fstab_backup_create_failed_rolled_back)"
        fi
        if ! cp -a /etc/fstab "$fstab_backup"; then
            rm -f -- "$fstab_backup" || true
            if ! rollback_new_swap_activation_only; then
                die "$(tr_msg setup_swap_2g_fstab_backup_unreliable_swap_stuck)"
            fi
            die "$(tr_msg setup_swap_2g_fstab_backup_failed_rolled_back)"
        fi
        if ! grep -qE '^/swapfile[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)' /etc/fstab 2>/dev/null; then
            if ! fstab_tmp=$(mktemp /etc/.fstab.A-Box.XXXXXX); then
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_tmp_create_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_tmp_create_failed_rolled_back)"
            fi
            if ! cat /etc/fstab > "$fstab_tmp"; then
                rm -f "$fstab_tmp"
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_write_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_write_failed_rolled_back)"
            fi
            # Trailing-newline guard: without it the BEGIN marker glues
            # onto a newline-less last line, and the later removal (which
            # looks for a standalone END marker) refuses to run.
            # A failed tail must stop here: its empty output is
            # indistinguishable from "already ends with newline", and
            # skipping the newline would glue the BEGIN marker on.
            if ! last_byte=$(tail -c 1 "$fstab_tmp" 2>/dev/null); then
                rm -f "$fstab_tmp"
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_write_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_write_failed_rolled_back)"
            fi
            if [[ -s "$fstab_tmp" ]] && [[ -n "$last_byte" ]]; then
                printf '\n' >> "$fstab_tmp" || {
                    rm -f "$fstab_tmp"
                    if ! rollback_abox_new_swap "$fstab_backup"; then
                        msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                        die "$(tr_msg setup_swap_2g_fstab_write_failed_swap_stuck)"
                    fi
                    rm -f "$fstab_backup" || true
                    die "$(tr_msg setup_swap_2g_fstab_write_failed_rolled_back)"
                }
            fi
            if ! printf '%s\n' '# A-Box swap BEGIN' '/swapfile none swap sw 0 0' '# A-Box swap END' >> "$fstab_tmp"; then
                rm -f "$fstab_tmp"
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_write_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_write_failed_rolled_back)"
            fi
            # R6C13-01: preserve the original fstab mode
            # explicitly. BusyBox chmod lacks --reference;
            # falling back to 644 would loosen a 0600 fstab
            # holding CIFS credentials. Abort if unpreservable.
            _orig_mode=$(stat -c %a /etc/fstab 2>/dev/null) || { rm -f "$fstab_tmp";
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_perm_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_perm_failed_rolled_back)"
            }
            chmod "$_orig_mode" "$fstab_tmp" || { rm -f "$fstab_tmp";
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_perm_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_perm_failed_rolled_back)"
            }
            chown --reference=/etc/fstab "$fstab_tmp" 2>/dev/null || true
            if ! mv -f "$fstab_tmp" /etc/fstab; then
                rm -f "$fstab_tmp"
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_rollback_incomplete_keep_backup "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_fstab_commit_failed_swap_stuck)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_fstab_commit_failed_rolled_back)"
            fi
        fi
        if grep -q '# A-Box swap BEGIN' /etc/fstab 2>/dev/null; then
            if ! write_file_atomically_from_stdin "$ABOX_DIR/.swapfile.managed" 600 <<'EOF_SWAP_MARK'
A-Box managed swap v1
EOF_SWAP_MARK
            then
                if ! rollback_abox_new_swap "$fstab_backup"; then
                    msg "${RED}[!] $(tprintf setup_swap_2g_ownership_marker_write_failed_incomplete "${fstab_backup}")${NC}" >&2
                    die "$(tr_msg setup_swap_2g_ownership_marker_write_failed_check)"
                fi
                rm -f "$fstab_backup" || true
                die "$(tr_msg setup_swap_2g_ownership_marker_write_failed_rolled_back)"
            fi
        else
            msg "${YELLOW}[!] $(tr_msg setup_swap_2g_fstab_unmarked_entry_skip)${NC}"
        fi
        rm -f "$fstab_backup" || die "$(tr_msg setup_swap_2g_tmp_backup_cleanup_failed)"
    elif ! grep -qE '^/swapfile[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)' /etc/fstab 2>/dev/null; then
        msg "${YELLOW}[!] $(tr_msg setup_swap_2g_existing_swapfile_not_abox)${NC}"
    fi
    swapon --show || true
    msg "${GREEN}$(tr_msg swap_done)${NC}"
    pause_return
}

# --- zram compressed swap -------------------------------------------
# Helper: /usr/local/sbin/abox-zram (start|stop|status); its config
# /etc/ddr/zram.conf pins SIZE_MB/ALGO so a boot-time start reproduces
# exactly what setup created. zram runs at swap priority 100, above
# the disk swapfile, so the kernel prefers it automatically.
abox_zram_write_helper() {
    write_file_atomically_from_stdin /usr/local/sbin/abox-zram 755 <<'EOF_ZRAM_HELPER'
#!/bin/bash
# A-Box zram swap helper: start|stop|status
set -u
CONF=/etc/ddr/zram.conf
SIZE_MB=512
ALGO=zstd
# H-08: never source the config file: only two whitelisted key=value
# lines are accepted; anything else fails closed instead of running
# as shell code (the helper runs as root, even for `status`).
if [[ -f "$CONF" ]]; then
    # 06g-M2: take grep's exit code explicitly. rc 0 means an illegal
    # line was found and rc 2 means the config could not be read; only
    # rc 1 (every line matched the whitelist) may continue. The old
    # `&& exit 1` fired on rc 0 only, so an unreadable config silently
    # kept the SIZE_MB=512/ALGO=zstd defaults.
    grep -qvE '^(SIZE_MB=[0-9]+|ALGO=(zstd|lz4|lzo-rle|lzo))$' "$CONF" 2>/dev/null; _conf_rc=$?
    (( _conf_rc == 1 )) || exit 1
    _conf_size=$(grep -E '^SIZE_MB=[0-9]+$' "$CONF" 2>/dev/null | tail -1 | cut -d= -f2)
    _conf_algo=$(grep -E '^ALGO=(zstd|lz4|lzo-rle|lzo)$' "$CONF" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ -n "$_conf_size" ]] && SIZE_MB="$_conf_size"
    [[ -n "$_conf_algo" ]] && ALGO="$_conf_algo"
fi
# Boot-cycle identity: a recorded device number is only meaningful
# within the boot that created it. Another manager may own the same
# number after a reboot, so the state file is bound to the boot id.
_abox_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}
zram_active_devs() {
    local out
    if ! out=$(swapon --show=NAME --noheadings 2>/dev/null); then
        # BusyBox/Alpine swapon lacks --show: fall back to /proc/swaps.
        # 06g-M3: a failed read must fail (return 1), never be masked by
        # `|| true` into an empty list: the state-write cleanup path
        # treats an empty list as "device down" (exit 1) and its caller
        # then deletes the helper and config -- the only stop tool --
        # while the device is still active. A failure here lets the
        # cleanup fall back to the conservative `active_now="$dev"`.
        [[ -r /proc/swaps ]] || return 1
        out=$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null) || return 1
    fi
    printf '%s\n' "$out" | grep -E '^/dev/zram[0-9]+$' || true
}
# Reset a device we sized but failed to bring up: zramctl when present,
# else the sysfs reset attribute (the same mechanism zramctl uses).
_reset_dev() {
    if command -v zramctl >/dev/null 2>&1; then zramctl --reset "$1" >/dev/null 2>&1 || true;
    elif [[ -e "/sys/block/${1#/dev/}/reset" ]]; then echo 1 > "/sys/block/${1#/dev/}/reset" 2>/dev/null || true; fi
}
# 06g-M1: serialize start/stop under one flock (/run lock inode, so no
# stale file can survive a reboot): without it two concurrent starts
# each hot_add / zramctl --find a different device, swapon both, then
# each overwrite the single state file -- the first writer's device is
# left running with no record, and a later stop only stops the recorded
# one. The wait is bounded (30 s, 0.2 s retry, so any flock works);
# after acquiring, the normal active/state re-check below claims the
# already-running device instead of creating a second one. `status`
# is read-only and takes no lock.
if [[ "${1:-}" == start || "${1:-}" == stop ]]; then
    exec 9>/run/A-Box-zram.lock || exit 1
    _zram_lock_i=0
    while ! flock -n 9 2>/dev/null; do
        _zram_lock_i=$((_zram_lock_i + 1))
        if (( _zram_lock_i >= 150 )); then echo "abox-zram: timed out waiting for the zram lock" >&2; exit 1; fi
        sleep 0.2
    done
fi
case "${1:-}" in
    start)
        active_devs=$(zram_active_devs) || exit 1
        if [[ -n "$active_devs" ]]; then
            # Claim success only if OUR recorded device from THIS boot
            # is active. A stale record (previous boot) or a foreign
            # device must not be claimed: fall through and create our
            # own device instead of succeeding over someone else's swap.
            sdev=$(sed -n 's/^DEV=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
            sboot=$(sed -n 's/^BOOT=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
            if [[ "$sdev" =~ ^/dev/zram[0-9]+$ && -n "$sboot" && "$sboot" == "$(_abox_boot_id)" ]] && printf '%s\n' "$active_devs" | grep -qxF "$sdev"; then
                exit 0
            fi
        fi
        modprobe zram 2>/dev/null || true
        [[ -e /sys/class/zram-control ]] || exit 1
        dev=''
        actual_algo="$ALGO"
        if command -v zramctl >/dev/null 2>&1; then
            dev=$(zramctl --find --size "${SIZE_MB}M" --algorithm "$ALGO" 2>/dev/null) || dev=''
            if [[ -n "$dev" ]]; then
                # L-05: verify the algorithm the kernel actually
                # applied (same readback as the hot_add branch):
                # never record the request as fact unverified.
                _zctl_algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/block/${dev#/dev/}/comp_algorithm" 2>/dev/null | head -1)
                if [[ -z "$_zctl_algo" ]]; then
                    _zctl_algo=$(tr -d '[:space:]' < "/sys/block/${dev#/dev/}/comp_algorithm" 2>/dev/null || true)
                fi
                if [[ "$_zctl_algo" != "$ALGO" ]]; then _reset_dev "$dev"; exit 1; fi
                actual_algo="$_zctl_algo"
            fi
        fi
        if [[ -z "$dev" ]]; then
            id=$(cat /sys/class/zram-control/hot_add 2>/dev/null) || exit 1
            [[ "$id" =~ ^[0-9]+$ ]] || exit 1
            dev="/dev/zram${id}"
            echo "$ALGO" > "/sys/block/zram${id}/comp_algorithm" 2>/dev/null || { _reset_dev "$dev"; exit 1; }
            # Read back what the kernel actually runs: the file marks
            # the current algorithm in brackets ([zstd] lzo), or holds
            # it plain. A mismatch means the requested algorithm is not
            # in effect — fail instead of reporting the request as fact.
            actual_algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/block/zram${id}/comp_algorithm" 2>/dev/null | head -1)
            if [[ -z "$actual_algo" ]]; then
                actual_algo=$(tr -d '[:space:]' < "/sys/block/zram${id}/comp_algorithm" 2>/dev/null || true)
            fi
            if [[ "$actual_algo" != "$ALGO" ]]; then _reset_dev "$dev"; exit 1; fi
            echo "${SIZE_MB}M" > "/sys/block/zram${id}/disksize" || { _reset_dev "$dev"; exit 1; }
        fi
        mkswap "$dev" >/dev/null 2>&1 || { _reset_dev "$dev"; exit 1; }
        swapon -p 100 "$dev" || { swapoff "$dev" 2>/dev/null || true; _reset_dev "$dev"; exit 1; }
        # Record which device this helper activated, bound to this
        # boot: stop only ever swaps off our own device, never a
        # foreign zram swap (distro zram-generator / zram-tools setups
        # share the box, and device numbers are reused across reboots).
        printf 'DEV=%s\nBOOT=%s\nALGO=%s\n' "$dev" "$(_abox_boot_id)" "$actual_algo" > /etc/ddr/zram.state 2>/dev/null || {
            # The swap is up but its record is not: only report plain
            # failure once the device is really down. If cleanup cannot
            # bring it down, exit 2 so the caller keeps the helper and
            # config instead of deleting the only stop tool.
            swapoff "$dev" 2>/dev/null || true
            _reset_dev "$dev"
            active_now=$(zram_active_devs) || active_now="$dev"
            if printf '%s\n' "$active_now" | grep -qxF "$dev"; then
                echo "abox-zram: failed to record and failed to stop $dev; leaving helper and config for manual recovery" >&2
                exit 2
            fi
            exit 1
        }
        ;;
    stop)
        if [[ -f /etc/ddr/zram.state ]]; then
            sdev=$(sed -n 's/^DEV=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
            sboot=$(sed -n 's/^BOOT=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
            if [[ "$sdev" =~ ^/dev/zram[0-9]+$ && -n "$sboot" && "$sboot" == "$(_abox_boot_id)" ]]; then
                # R49-M2a: only swapoff when the device is actually
                # active. After a swapoff-success/reset-failure partial
                # stop, an unconditional swapoff dies on the already-off
                # device before the reset is ever retried. On a read
                # failure assume active (06g-M3 idiom): skipping swapoff
                # for an active device would leave it swapped on.
                _active_now=$(zram_active_devs 2>/dev/null) || _active_now="$sdev"
                if printf '%s\n' "$_active_now" | grep -qxF "$sdev"; then
                    swapoff "$sdev" 2>/dev/null || exit 1
                fi
                # 06h1-M1: a failed reset must fail the stop: the
                # device stays sized and the state file must be kept
                # (teardown deletes helper/config, and the state is
                # the only stop proof). Only when no reset mechanism
                # exists at all is the missing reset not a failure.
                if command -v zramctl >/dev/null 2>&1; then
                    zramctl --reset "$sdev" >/dev/null 2>&1 || exit 1
                elif [[ -e "/sys/block/${sdev#/dev/}/reset" ]]; then
                    echo 1 > "/sys/block/${sdev#/dev/}/reset" 2>/dev/null || exit 1
                fi
                rm -f /etc/ddr/zram.state
            else
                echo "abox-zram: stale or unproven device record in /etc/ddr/zram.state (boot mismatch, missing boot id, or malformed device); refusing to stop, state kept for inspection" >&2
                exit 1
            fi
        else
            # No state file: refuse to stop. The recorded device is the
            # only proof a zram swap is ours; stopping every active zram
            # swap here could kill distro/user swaps. Legacy installs
            # without state must be stopped by hand.
            echo "abox-zram: no /etc/ddr/zram.state; refusing to stop zram swaps not proven to be A-Box's" >&2
            exit 1
        fi
        ;;
    status)
        zram_active_devs
        ;;
    *) echo "usage: abox-zram start|stop|status" >&2; exit 2 ;;
esac
EOF_ZRAM_HELPER
}
# Stop the zram swap and remove its persistence (unit/init script,
# helper, config). Best-effort; used by the toolbox remover, the
# virgin reset and the full uninstaller.
abox_zram_teardown() {
    local stop_rc=0 persist_rc=0
    if [[ -x /usr/local/sbin/abox-zram ]]; then /usr/local/sbin/abox-zram stop >/dev/null 2>&1 || stop_rc=1;
    elif [[ -f /etc/ddr/zram.state ]]; then
        # No helper to stop with, but a state record claims a device
        # may still be active: deleting the record would strand it
        # with no stop tool left. This is a stop failure, not success.
        stop_rc=1
    fi
    local _init=''
    _init=$(effective_init_system)
    if [[ "$_init" == 'systemd' ]]; then
        local _zram_present=0 _zram_load='' _zram_p
        # R21 F-RESET-ZRAM: skip only proven absence; masks and boot-link remnants count.
        for _zram_p in /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/abox-zram.service \
            /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/*.{wants,requires,upholds}/abox-zram.service; do
            if [[ -e "$_zram_p" || -L "$_zram_p" ]]; then
                _zram_present=1
                break
            fi
        done
        if (( _zram_present == 0 )); then
            # Probe errors do not establish absence: use normal cleanup.
            if ! _zram_load=$(systemctl show -p LoadState --value abox-zram.service 2>/dev/null) ||
                [[ "$_zram_load" != 'not-found' ]]; then
                _zram_present=1
            fi
        fi
        if (( _zram_present != 0 )); then
            # H-13 (systemd same-type): `systemctl disable` on a unit
            # with no unit file exits 1 ("Unit file ... does not
            # exist"), the same spurious-failure class as the OpenRC
            # `del` above. Do not let its rc decide the outcome:
            # remove the unit file and any enablement symlinks, then
            # decide by what remains.
            systemctl disable abox-zram.service >/dev/null 2>&1 || true
            # 06h1-M2: delete and re-verify across the same five roots
            # the probe above covers: a unit (or enablement link) left
            # under /run or /usr/lib would otherwise survive with
            # persist_rc == 0 and execute the deleted helper on next boot.
            rm -f /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/abox-zram.service /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/*.{wants,requires,upholds}/abox-zram.service 2>/dev/null || persist_rc=1
            for _zram_p in /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/abox-zram.service /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/*.{wants,requires,upholds}/abox-zram.service; do
                if [[ -e "$_zram_p" || -L "$_zram_p" ]]; then
                    persist_rc=1
                    break
                fi
            done
            systemctl daemon-reload >/dev/null 2>&1 || persist_rc=1
        fi
    elif [[ "$_init" == 'openrc' ]]; then
        # R21 F-RESET-ZRAM: a missing script is harmless only without runlevel remnants.
        if [[ -e /etc/init.d/abox-zram || -L /etc/init.d/abox-zram ]]; then
            if [[ -L /etc/runlevels/default/abox-zram ]]; then
                rc-update del abox-zram default >/dev/null 2>&1 || persist_rc=1
            fi
            rm -f /etc/init.d/abox-zram 2>/dev/null || persist_rc=1
        fi
        local _zram_link
        for _zram_link in /etc/runlevels/*/abox-zram; do
            if [[ -e "$_zram_link" || -L "$_zram_link" ]]; then
                rm -f -- "$_zram_link" 2>/dev/null || persist_rc=1
            fi
        done
        for _zram_link in /etc/runlevels/*/abox-zram; do
            if [[ -e "$_zram_link" || -L "$_zram_link" ]]; then
                persist_rc=1
                break
            fi
        done
    fi
    # R5C13-04: a persistence failure must not be swallowed while
    # the helper is deleted (that orphans a still-enabled boot unit).
    if (( persist_rc != 0 )); then
        msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_persist_remove_failed)${NC}" >&2
        return 1
    fi
    if (( stop_rc == 0 )); then
        local _rm_rc=0 _left=0 _p
        rm -f /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state 2>/dev/null || _rm_rc=$?
        for _p in /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state; do
            if [[ -e "$_p" || -L "$_p" ]]; then
                msg "${YELLOW}[!] $(tprintf abox_zram_teardown_path_remains "${_p}")${NC}" >&2
                _left=1
            fi
        done
        if (( _rm_rc != 0 || _left != 0 )); then
            if (( _left == 0 )); then
                msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_helper_remove_failed)${NC}" >&2
            fi
            return 1
        fi
        return 0
    fi
    # R1-13-F4: stop failed but persistence is gone. If no zram
    # device is actually active, the failure is a stale record
    # (previous boot), not a stranded swap: clean up instead of
    # pinning the helper/config forever. If a device IS active,
    # keep the helper so it can still be stopped.
    local _any_active=0
    if [[ -r /proc/swaps ]]; then
        # R14-F13-04: distinguish grep rc 1 (confirmed no active
        # device) from any other failure (query error): an error must
        # fail closed like the unreadable-/proc/swaps branch above,
        # never drop into the stale-cleanup branch.
        local _grep_rc=0
        grep -qE '^/dev/zram[0-9]+[[:space:]]' /proc/swaps 2>/dev/null; _grep_rc=$?
        case "$_grep_rc" in
            0) _any_active=1 ;;
            1) : ;; # confirmed stopped: stale cleanup may proceed
            *) _any_active=1 ;; # query error: keep helper/config
        esac
    else
        # Cannot verify: fail closed, keep helper/config.
        _any_active=1
    fi
    if (( _any_active == 0 )); then
        # R49-M2b: a swap-inactive record is not necessarily stale. A
        # stop that failed at the reset leaves the device swapped off
        # but unreset, and the state file belongs to THIS boot: deleting
        # the helper/config/state then strands the device with no stop
        # tool. Only a record from another boot (or no record at all)
        # is stale enough to clean up. An unreadable boot id cannot
        # prove staleness either, so keep the files then too.
        local _sboot='' _cur_boot=''
        _sboot=$(sed -n 's/^BOOT=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
        _cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [[ -n "$_sboot" && ( -z "$_cur_boot" || "$_sboot" == "$_cur_boot" ) ]]; then
            msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_stop_failed)${NC}" >&2
            return 1
        fi
        local _rm_rc=0 _left=0 _p
        rm -f /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state 2>/dev/null || _rm_rc=$?
        for _p in /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state; do
            if [[ -e "$_p" || -L "$_p" ]]; then
                msg "${YELLOW}[!] $(tprintf abox_zram_teardown_path_remains "${_p}")${NC}" >&2
                _left=1
            fi
        done
        if (( _rm_rc != 0 || _left != 0 )); then
            if (( _left == 0 )); then
                msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_helper_remove_failed)${NC}" >&2
            fi
            return 1
        fi
        msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_stale_stopped)${NC}" >&2
        return 0
    fi
    msg "${YELLOW}[!] $(tr_msg abox_zram_teardown_stop_failed)${NC}" >&2
    return 1
}


setup_zram_swap() {
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg setup_zram_swap_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    local _swapon_out
    if ! _swapon_out=$(swapon --show=NAME --noheadings 2>/dev/null); then
        # BusyBox/Alpine swapon lacks --show: fall back to /proc/swaps.
        if [[ -r /proc/swaps ]]; then
            _swapon_out=$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null || true)
        else
            msg "${RED}$(tr_msg setup_zram_swap_status_query_fail)${NC}"
            pause_return
            return 0
        fi
    fi
    if printf '%s\n' "$_swapon_out" | grep -qE '^/dev/zram[0-9]+$'; then
        msg "${YELLOW}$(tr_msg setup_zram_swap_already_running)${NC}"
        swapon --show || true
        pause_return
        return 0
    fi
    modprobe zram 2>/dev/null || true
    if [[ ! -e /sys/class/zram-control ]]; then
        msg "${RED}$(tr_msg setup_zram_swap_no_kernel_support)${NC}"
        pause_return
        return 0
    fi
    local algo='' supported='' cand='' _probe_id='' _probe_dev=''
    if [[ -r /sys/block/zram0/comp_algorithm ]]; then
        supported=$(tr -d '[]' < /sys/block/zram0/comp_algorithm)
        for cand in zstd lz4 lzo-rle lzo; do
            if [[ " $supported " == *" $cand "* ]]; then algo="$cand"; break; fi
        done
    fi
    if [[ -z "$algo" ]]; then
        # L-05: no pre-built zram0 (module loaded with num_devices=0
        # or zram0 hot-removed): probe the algorithm list on a freshly
        # hot-added device instead of blindly falling back to lz4,
        # which may not exist on a slim cloud kernel.
        _probe_id=$(cat /sys/class/zram-control/hot_add 2>/dev/null || true)
        if [[ "$_probe_id" =~ ^[0-9]+$ ]]; then
            _probe_dev="/dev/zram${_probe_id}"
            if [[ -r "/sys/block/zram${_probe_id}/comp_algorithm" ]]; then
                supported=$(tr -d '[]' < "/sys/block/zram${_probe_id}/comp_algorithm")
                for cand in zstd lz4 lzo-rle lzo; do
                    if [[ " $supported " == *" $cand "* ]]; then algo="$cand"; break; fi
                done
            fi
            # Release the probe device: reset it, then hot-remove it
            # when the kernel offers that attribute, so setup leaves
            # no claimed device behind.
            if command -v zramctl >/dev/null 2>&1; then
                zramctl --reset "$_probe_dev" >/dev/null 2>&1 || true
            elif [[ -e "/sys/block/zram${_probe_id}/reset" ]]; then
                echo 1 > "/sys/block/zram${_probe_id}/reset" 2>/dev/null || true
            fi
            if [[ -e /sys/class/zram-control/hot_remove ]]; then
                echo "$_probe_id" > /sys/class/zram-control/hot_remove 2>/dev/null || true
            fi
        fi
    fi
    [[ -n "$algo" ]] || algo='lz4'
    local mem_kb=0 size_mb=512
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    [[ "$mem_kb" =~ ^[0-9]+$ ]] || mem_kb=0
    size_mb=$(( mem_kb / 1024 / 2 ))
    (( size_mb < 256 )) && size_mb=256
    (( size_mb > 2048 )) && size_mb=2048
    # R49-M1: the config is overwritten below, then the helper write
    # may fail. Save the pre-existing config first so a failed
    # re-install restores it instead of deleting it (the old helper
    # and boot unit survive, and would fall back to defaults).
    local _zram_conf_bak=''
    if [[ -f /etc/ddr/zram.conf && ! -L /etc/ddr/zram.conf ]]; then
        _zram_conf_bak=$(mktemp /tmp/A-Box-zram-conf.XXXXXX) || _zram_conf_bak=''
        [[ -n "$_zram_conf_bak" ]] && cp -a /etc/ddr/zram.conf "$_zram_conf_bak" 2>/dev/null || _zram_conf_bak=''
    fi
    if ! write_file_atomically_from_stdin /etc/ddr/zram.conf 600 <<EOF_ZRAM_CONF
SIZE_MB=${size_mb}
ALGO=${algo}
EOF_ZRAM_CONF
    then
        [[ -n "$_zram_conf_bak" ]] && rm -f "$_zram_conf_bak"
        msg "${RED}$(tr_msg setup_zram_swap_config_write_fail)${NC}"
        pause_return
        return 0
    fi
    if ! abox_zram_write_helper; then
        if [[ -n "$_zram_conf_bak" ]]; then
            cp -a "$_zram_conf_bak" /etc/ddr/zram.conf 2>/dev/null || rm -f /etc/ddr/zram.conf
            rm -f "$_zram_conf_bak"
        else
            rm -f /etc/ddr/zram.conf
        fi
        msg "${RED}$(tr_msg setup_zram_swap_helper_write_fail)${NC}"
        pause_return
        return 0
    fi
    [[ -n "$_zram_conf_bak" ]] && rm -f "$_zram_conf_bak"
    local _zram_start_rc=0
    /usr/local/sbin/abox-zram start || _zram_start_rc=$?
    if (( _zram_start_rc != 0 )); then
        # Helper exit 2 means cleanup failed and the swap may still be
        # active: keep the helper and config so it can still be stopped.
        # (Plain 1 means failed with the device confirmed down.)
        if (( _zram_start_rc == 2 )); then
            msg "${RED}$(tr_msg setup_zram_swap_enable_cleanup_fail)${NC}"
        else
            # R10C13-02: do not delete helper/config on failure:
            # a pre-existing boot unit points at the helper, and
            # deleting it would orphan that unit. Keep them (a
            # retry overwrites; a first-time failure leaves inert files).
            msg "${RED}$(tr_msg setup_zram_swap_enable_fail)${NC}"
        fi
        pause_return
        return 0
    fi
    local init=''
    init=$(effective_init_system)
    case "$init" in
        systemd)
            # 06h1-M3: a failed unit write must not be swallowed: do
            # not enable a unit that was never written, and do not
            # print the success summary (same shape as the config /
            # helper write-failure paths above).
            if ! write_file_atomically_from_stdin /etc/systemd/system/abox-zram.service 644 <<'EOF_ZRAM_UNIT'
[Unit]
Description=A-Box zram compressed swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/abox-zram start
ExecStop=/usr/local/sbin/abox-zram stop

[Install]
WantedBy=multi-user.target
EOF_ZRAM_UNIT
            then
                msg "${RED}$(tr_msg setup_zram_swap_unit_write_fail)${NC}"
                # R49-M3: the device was just started by this run;
                # without persistence a re-run hits the "already
                # running" early return and can never write the unit.
                # Roll it back so a retry starts clean. The helper
                # stops only our recorded device from this boot.
                if ! /usr/local/sbin/abox-zram stop >/dev/null 2>&1; then
                    msg "${YELLOW}[!] $(tr_msg remove_zram_swap_stop_failed)${NC}" >&2
                fi
                pause_return
                return 0
            fi
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable abox-zram.service >/dev/null 2>&1 || msg "${YELLOW}[!] $(tr_msg setup_zram_swap_autostart_systemd_fail)${NC}"
            ;;
        openrc)
            if ! write_file_atomically_from_stdin /etc/init.d/abox-zram 755 <<'EOF_ZRAM_RC'
#!/sbin/openrc-run
description="A-Box zram compressed swap"
depend() {
    need localmount
    before swap
}
start() {
    ebegin "Starting A-Box zram swap"
    /usr/local/sbin/abox-zram start
    eend $?
}
stop() {
    ebegin "Stopping A-Box zram swap"
    /usr/local/sbin/abox-zram stop
    eend $?
}
EOF_ZRAM_RC
            then
                msg "${RED}$(tr_msg setup_zram_swap_unit_write_fail)${NC}"
                # R49-M3: the device was just started by this run;
                # without persistence a re-run hits the "already
                # running" early return and can never write the unit.
                # Roll it back so a retry starts clean. The helper
                # stops only our recorded device from this boot.
                if ! /usr/local/sbin/abox-zram stop >/dev/null 2>&1; then
                    msg "${YELLOW}[!] $(tr_msg remove_zram_swap_stop_failed)${NC}" >&2
                fi
                pause_return
                return 0
            fi
            rc-update add abox-zram default >/dev/null 2>&1 || msg "${YELLOW}[!] $(tr_msg setup_zram_swap_autostart_openrc_fail)${NC}"
            ;;
        *)
            msg "${YELLOW}[!] $(tr_msg setup_zram_swap_init_unknown)${NC}"
            ;;
    esac
    local _actual_algo=''
    _actual_algo=$(sed -n 's/^ALGO=//p' /etc/ddr/zram.state 2>/dev/null | head -1)
    msg "${GREEN}$(tprintf setup_zram_swap_enabled_summary "${size_mb}" "${_actual_algo:-$algo}")${NC}"
    swapon --show || true
    pause_return
}

remove_zram_swap() {
    # W5-OBS-3: abox_zram_teardown returns 0 for a no-op cleanup, so
    # with no A-Box zram at all this used to print "zram 已移除" for
    # nothing removed. Probe for any A-Box zram trace first (helper,
    # state/conf, unit or enablement link, init script, or an actually
    # active zram device) and say so explicitly when there is none --
    # mirroring the disk-swap "没有 A-Box 创建的磁盘 Swap 文件。" path.
    # The teardown itself is untouched: idempotent cleanup callers
    # (uninstall, reset) still rely on its no-op success.
    local _rz_any=0 _rz_p
    for _rz_p in /usr/local/sbin/abox-zram /etc/ddr/zram.conf /etc/ddr/zram.state /etc/init.d/abox-zram; do
        [[ -e "$_rz_p" || -L "$_rz_p" ]] && _rz_any=1
    done
    for _rz_p in /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/abox-zram.service \
        /{etc,run,usr/local/lib,usr/lib,lib}/systemd/system/*.{wants,requires,upholds}/abox-zram.service; do
        [[ -e "$_rz_p" || -L "$_rz_p" ]] && _rz_any=1
    done
    if grep -qE '^/dev/zram[0-9]+[[:space:]]' /proc/swaps 2>/dev/null; then _rz_any=1; fi
    if (( _rz_any == 0 )); then
        msg "${YELLOW}$(tr_msg swap_menu_no_zram)${NC}"
        swapon --show || true
        pause_return
        return 0
    fi
    if abox_zram_teardown; then
        msg "${GREEN}$(tr_msg remove_zram_swap_removed)${NC}"
    else
        msg "${RED}$(tr_msg remove_zram_swap_stop_failed)${NC}"
    fi
    swapon --show || true
    pause_return
}

swap_status_show() {
    msg "${BOLD}${GREEN}$(tr_msg swap_status_show_title)${NC}"
    swapon --show || true
    if command -v zramctl >/dev/null 2>&1; then zramctl || true; fi
    free -m | grep -iE '^(Mem|Swap|内存|交换)' || free -m || true
    pause_return
}

swap_menu() {
    local choice=''
    while true; do
        clear
        msg "${CYAN}======================================================================${NC}"
        msg "${BOLD}${GREEN}$(tr_msg swap_menu_title)${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg " ${CYAN}1.${NC}  $(tr_msg swap_opt_1)"
        msg " ${CYAN}2.${NC}  $(tr_msg swap_opt_2)"
        msg " ${CYAN}3.${NC}  $(tr_msg swap_opt_3)"
        msg " ${CYAN}4.${NC}  $(tr_msg swap_opt_4)"
        msg " ${CYAN}5.${NC}  $(tr_msg swap_opt_5)"
        msg " ${CYAN}0.${NC}  $(tr_msg swap_opt_0)"
        read -r -p "$(tr_msg swap_select_0_5)" choice || return 0
        choice=$(normalize_fa_ar_digits "$choice")
        case "$choice" in
            1) setup_zram_swap ;;
            2) setup_swap_2g ;;
            3) swap_status_show ;;
            4) remove_zram_swap ;;
            5)
                if [[ -f "$ABOX_DIR/.swapfile.managed" ]]; then
                    if remove_abox_swap; then msg "${GREEN}$(tr_msg swap_menu_disk_removed)${NC}"; else msg "${RED}$(tr_msg swap_menu_remove_failed)${NC}"; fi
                else
                    msg "${YELLOW}$(tr_msg swap_menu_no_disk_swap)${NC}"
                fi
                pause_return
                ;;
            0) return 0 ;;
            *) msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1 ;;
        esac
    done
}


# BUG-28: hoisted from remove_abox_swap(). $1 = fstab backup path.
__abox_restore_fstab_from_swap_backup() {
    local backup="$1"
    if cp -a "$backup" /etc/fstab; then
        return 0
    fi
    msg "${RED}[!] $(tprintf __abox_restore_fstab_from_swap_backup_failed "${backup}")${NC}" >&2
    return 1
}
remove_abox_swap() {
    [[ -f "$ABOX_DIR/.swapfile.managed" && ! -L "$ABOX_DIR/.swapfile.managed" ]] || return 0
    grep -Fxq 'A-Box managed swap v1' "$ABOX_DIR/.swapfile.managed" 2>/dev/null || return 1
    fstab_path_is_safe || return 1
    local tmp backup swap_active=0 swap_state=1
    # R48-L2: _orig_mode must stay local (see rollback_abox_new_swap).
    local _orig_mode=''
    if [[ -f /swapfile && ! -L /swapfile ]]; then
        swapfile_active_state
        swap_state=$?
        case "$swap_state" in
            0) swap_active=1 ;;
            1) ;;
            *) return 1 ;;
        esac
    fi
    tmp=$(mktemp /etc/.fstab.A-Box-remove.XXXXXX) || return 1
    backup=$(mktemp /etc/.fstab.A-Box-backup.XXXXXX) || { rm -f "$tmp"; return 1; }
    cp -a /etc/fstab "$backup" || { rm -f "$tmp" "$backup"; return 1; }
    awk '
      $0 == "# A-Box swap BEGIN" {
        if (skip) { print "A-Box swap: nested BEGIN" > "/dev/stderr"; exit 2 }
        skip=1; begin_seen=1; next
      }
      $0 == "# A-Box swap END" {
        if (!skip) { print "A-Box swap: END without BEGIN" > "/dev/stderr"; exit 2 }
        skip=0; end_seen=1; next
      }
      skip {next}
      {print}
      END {
        if (skip || (begin_seen && !end_seen) || (!begin_seen && end_seen)) {
          print "A-Box swap: unbalanced BEGIN/END markers; refusing to rewrite /etc/fstab" > "/dev/stderr"
          exit 2
        }
      }
    ' /etc/fstab > "$tmp" || { rm -f "$tmp" "$backup"; return 1; }
    # R49-M4: the awk above strips only the managed block; a /swapfile
    # entry outside it (foreign line, or markers removed by hand)
    # survives the rewrite. Deleting /swapfile then leaves a live
    # fstab reference to a missing file. Refuse while the file still
    # exists; when it is already gone, proceed (retry path: clean the
    # residual marker only).
    if grep -qE '^/swapfile[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)' "$tmp" 2>/dev/null && [[ -f /swapfile && ! -L /swapfile ]]; then
        msg "${RED}[!] /etc/fstab still contains a /swapfile swap entry outside the A-Box managed block; refusing to delete /swapfile. Remove the foreign entry first, then retry.${NC}" >&2
        rm -f "$tmp" "$backup"
        return 1
    fi
    # R6C13-01: preserve the original fstab mode
    # explicitly. BusyBox chmod lacks --reference;
    # falling back to 644 would loosen a 0600 fstab
    # holding CIFS credentials. Abort if unpreservable.
    _orig_mode=$(stat -c %a /etc/fstab 2>/dev/null) || { rm -f "$tmp";
        rm -f "$backup"; return 1
    }
    chmod "$_orig_mode" "$tmp" || { rm -f "$tmp";
        rm -f "$backup"; return 1
    }
    chown --reference=/etc/fstab "$tmp" 2>/dev/null || true
    mv -f "$tmp" /etc/fstab || { rm -f "$tmp" "$backup"; return 1; }


    if (( swap_active == 1 )); then
        if ! swapoff /swapfile; then
            __abox_restore_fstab_from_swap_backup "$backup" || return 1
            rm -f "$backup" || true
            return 1
        fi
    fi
    if [[ -f /swapfile && ! -L /swapfile ]]; then
        if ! rm -f /swapfile; then
            # R1-13-F2: a failed restore must not be swallowed
            # with the backup deleted and fstab claimed restored.
            if ! __abox_restore_fstab_from_swap_backup "$backup"; then
                msg "${RED}[!] $(tprintf remove_abox_swap_delete_and_restore_failed "${backup}")${NC}" >&2
                return 1
            fi
            if (( swap_active == 1 )); then
                # The swap was active before we turned it off: bring it
                # back, or the failed removal leaves it inactive.
                swapon /swapfile 2>/dev/null || msg "${RED}[!] $(tr_msg remove_abox_swap_delete_and_reactivate_failed)${NC}" >&2
            fi
            msg "${YELLOW}[!] $(tr_msg remove_abox_swap_delete_failed_kept)${NC}" >&2
            rm -f "$backup" || true
            return 1
        fi
    fi
    if ! rm -f "$ABOX_DIR/.swapfile.managed"; then
        # Do NOT restore the old fstab here: /swapfile is already deleted
        # and the managed block is already stripped, so restoring would
        # resurrect a reference to a deleted file. Keep the marker so a
        # later uninstall can finish the cleanup, and say so loudly.
        msg "${YELLOW}[!] $(tr_msg remove_abox_swap_marker_remove_failed)${NC}" >&2
        rm -f "$backup" || true
        return 1
    fi
    rm -f "$backup" || return 1
}

redact_secrets_stream() {
    # Return contract (D2): 0 = redacted output written; 2 = the whole
    # document was suppressed (python3 unavailable: unconditional
    # whole-document suppression, fixed OMITTED notice only);
    # any other non-zero value = redaction error, output unusable.
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - 3<&0 <<'PY_REDACT'
import json
import os
import re
import sys

text = os.fdopen(3, "r", encoding="utf-8", errors="replace").read()
secret = re.compile(
    r"(?:^|[_-])(uuid|private.?key|public.?key|short.?ids?|fingerprint|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key|authorization|cookie|ss_pass|hy2_pass|hy2_obfs|key|username|user)(?:$|[_-])",
    re.I,
)
link = re.compile(r"(?i)\b(?:vless|hysteria2|hy2|ss|trojan|tuic|anytls|socks5|vmess)://\S+")
pem_span = re.compile(r"-----BEGIN [^-]*KEY-----.*?-----END [^-]*KEY-----", re.S)
url_userinfo = re.compile(r"(?i)(\b(?:https?|ftp)://)[^\s/@]+@")
# R12B-N1: a JSONC comment gap (whitespace plus /* */ or // comments) that
# may sit between a sensitive key and its separator, or between the
# separator and its value. Shared by the two key heads below, by both
# key->value regexes, and by the authorization/cookie prefix groups; a
# comment in the gap is KEPT (it sits inside group 1 of the substitution).
# Noncapturing throughout, so group numbering of the replacements is
# unchanged. \Z (not $) marks the real end of string for a // comment.
_COMMENT_GAP = (
    r"(?:[ \t\r\n]|/\*(?:[^*]|\*+[^*/])*\*+/|//[^\n]*(?:\n|\Z))*"
)

# R12B-C3: stop-head for the tempered authorization value below: the
# assignments the downstream passes actually redact (the inline key table
# plus authorization/proxy-authorization/cookie/set-cookie, whose own rules
# run after authorization). A delimiter stops the auth value only when one
# of these follows; otherwise the delimiter stays part of the redacted
# value (P6). No capturing groups, so replacement \1 stays the prefix.
_AUTH_STOP_HEAD = (
    r"""["']?\b(?:uuid|private.?key|public.?key|short.?ids?|fingerprint"""
    r"""|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key"""
    r"""|authorization|proxy-authorization|cookie|set-cookie"""
    r"""|ss_pass|hy2_pass|hy2_obfs|user|socks_user|socks_pass)\b["']?\s*[:=]"""
)

# R12B-C3: tempered authorization value. Ordinary characters are
# [^\s,;}] (the text path's charset); a delimiter (, ; }) is consumed
# only when NO sensitive assignment follows it (negative lookahead over
# an optional comment gap + the stop-head above). Fixes the JSON-path
# `Bearer abcd,token:` leak without splitting a delimiter tail that has
# no following key (P6), which the plain mirror would have exposed.
_AUTH_QUOTED_TAIL = (
    r"""(?:"(?:\\[^\r\n]|[^"\\\r\n])*(?:"|\\?(?=\r?\n|\Z))"""
    r"""|(?!(?:'(?:''|[^'\r\n])*')[ \t]*[:=])'(?:\\[^\r\n]|''|[^'\\\r\n])*(?:'|\\?(?=\r?\n|\Z)))(?![ \t]*[:=])"""
)

# R16-A (N02): repeatable quoted segment for EXTRA segments after the first one.
# Closed dq/sq, or unterminated whose FIRST content char is not `}` (a leftover JSON
# closing-quote + `}` must never be eaten as a fake segment). The guard `(?![ \t]*:)`
# (applied at each use) keeps quoted KEYs such as `"safe":` out of the value.
_AUTH_QUOTED_TAIL_REPEAT = (
    r"""(?:"(?:\\[^\r\n]|[^"\\\r\n])*"|'(?:\\[^\r\n]|[^'\\\r\n])*'|"(?:(?:\\[^\r\n]|[^"\\\r\n}])(?:\\[^\r\n]|[^"\\\r\n])*\\?|\\)(?=\r?\n|\Z)|'(?:(?:\\[^\r\n]|[^'\\\r\n}])(?:\\[^\r\n]|[^'\\\r\n])*\\?|\\)(?=\r?\n|\Z)|"}[ \t]*(?:(?:\\[^\r\n]|[^"\\\r\n \t])(?:\\[^\r\n]|[^"\\\r\n])*\\?|\\)(?=\r?\n|\Z)|'}[ \t]*(?:(?:\\[^\r\n]|[^'\\\r\n \t])(?:\\[^\r\n]|[^'\\\r\n])*\\?|\\)(?=\r?\n|\Z))"""
)

# R16-A (N02): extra quoted segments after a value (bridge of bare chars, then one
# or more separator + quoted segment, each guarded against quoted keys). No END
# lookahead: it would drop S2 in `"S1" "S2" "safe": "v"` (guard already rejects keys).
_AUTH_EXTRA = (
    r"""(?:[^ \t\r\n,;:}"'\\]*"""
    r"""(?:[ \t]*,?[ \t]*(?!(?:"(?:\\[^\r\n]|[^"\\\r\n])*"|'(?:''|[^'\r\n])*')[ \t]*[:=])""" + _AUTH_QUOTED_TAIL_REPEAT + r"""(?![ \t]*[:=]))+)?"""
)

# R16-A (W-01): precise quoted-key head (escape-aware dq, doubled-apostrophe sq).
_QUOTED_KEY_HEAD = (
    r"""(?:"(?:\\[^\r\n]|[^"\\\r\n])*"|'(?:''|[^'\r\n])*')[ \t]*[:=]"""
)

# R16-A (W-01 b): tempered plain branch; stops before a quoted key-head too
# (not only sensitive HEADs), so `, "safe":` survives the auth rule itself.
_AUTH_PLAIN = (
    r"""(?:[^\s,;}]|[,;}](?!""" + _COMMENT_GAP + r"""(?:""" + _AUTH_STOP_HEAD
    + r"""|""" + _QUOTED_KEY_HEAD + r""")))+"""
)

_AUTH_VALUE = (
    r"(?:[^\s,;}]*[ \t]*:[ \t]+" + _AUTH_QUOTED_TAIL + _AUTH_EXTRA
    + r"|" + _AUTH_PLAIN + _AUTH_EXTRA + r")"
)

# 06h2-H01: generic (non-Bearer/Basic) scheme value. The bare
# _AUTH_VALUE above only swallows the scheme word: its plain branch
# stops at the first space, so the bare token after "Negotiate "
# survived verbatim. A generic value is scheme + whitespace + one
# credential blob (the blob keeps the tempered rules: comma-separated
# Digest params are consumed in full, a following sensitive key-head
# stops it). A lone scheme with no token still redacts (the tail is
# optional). Shared by inline_authorization and the text-path copy.
#
# Digest params (RFC 7616: username/realm/nonce/uri/response/cnonce/
# opaque are quoted-string, qop/nc/algorithm are tokens) are a closed
# name set, so the param tail names them explicitly: a following
# unrelated "key=value" field (e.g. version=2) is never swallowed,
# and a following "key: value" field is never touched at all (the
# tail requires "=").
_AUTH_DIGEST_PARAM = (
    r"(?:[ \t]*,?[ \t]*"
    r"(?:username|realm|nonce|uri|response|cnonce|opaque|qop|nc|algorithm|charset|stale|userhash)"
    r"[ \t]*=[ \t]*"
    r"(?:\"(?:\\[^\r\n]|[^\"\\\r\n])*\"|'(?:''|[^'\r\n])*'|[^\s,;}]+))+"
)

_AUTH_GENERIC_VALUE = (
    r"[^\s,;}]+(?:[ \t]+" + _AUTH_VALUE + r"(?:" + _AUTH_DIGEST_PARAM + r")?)?"
)

inline_authorization = re.compile(
    r"(?i)(\b(?:authorization|proxy-authorization)" + _COMMENT_GAP + r"[:=]" + _COMMENT_GAP + r")"
    r"(?:Bearer\s+" + _AUTH_VALUE + r"|Basic\s+" + _AUTH_VALUE + r"|" + _AUTH_GENERIC_VALUE + r")"
)
inline_cookie = re.compile(r"(?i)(\b(?:cookie|set-cookie)" + _COMMENT_GAP + r"[:=]" + _COMMENT_GAP + r")[^\r\n]+")

# R11-C (R5-1): tempered-greedy unquoted value. A plain [^\r\n}"]+ tail
# swallows a following "key: value" on the same line, so re.sub never
# re-scans the consumed key and its quoted value leaks. The unquoted
# branch now stops before a following secret key-head (after an
# optional , or ; separator), while still consuming a plain comma tail
# in full (F13-2: "abcd,efgh" stays one redacted value). The two rules
# keep their own key tables (inline has \b and no authorization|cookie;
# text has both and no \b); only the constructor is shared.
_INLINE_KEY_HEAD = (
    r"""[\"']?\b(?:uuid|private.?key|public.?key|short.?ids?|fingerprint"""
    r"""|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key"""
    r"""|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)\b[\"']?""" + _COMMENT_GAP + r"""[:=]"""
)
_TEXT_KEY_HEAD = (
    r"""[\"']?(?:uuid|private.?key|public.?key|short.?ids?|fingerprint"""
    r"""|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key"""
    r"""|authorization|cookie|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)[\"']?""" + _COMMENT_GAP + r"""[:=]"""
)


def _unquoted_value(head):
    # (?:(?!STOP)ATOM)+; STOP = optional separator prefix + key-head.
    return (
        r"""(?:(?!(?:[,;][^\S\r\n]*|[ \t]+)?(?:"""
        + head
        + r"""|""" + _QUOTED_KEY_HEAD + r"""))[^\r\n}\"])+"""
    )

# M-08(1): spliced quoted values. A sensitive value may be written as
# adjacent quoted/bare segments ('aa'bbCCdd'): the primary value regex
# only matches the first segment and the tail leaks verbatim. Consume
# immediately-adjacent extra segments, but never a following sensitive
# key-head or quoted key (guarded per character, like _unquoted_value),
# and never across a delimiter. A trailing lone quote (the end of a
# spliced run) is consumed only when a delimiter or end of text follows.
def _spliced_tail(head):
    return (
        r"""(?:(?!(?:"""
        + head
        + r"""|"""
        + _QUOTED_KEY_HEAD
        + r"""))(?:\"(?:\\[\s\S]|[^\"\\])*\"|\"(?:\\[\s\S]|[^\"\\])*|'(?:[^']|'')*'|(?:(?!(?:"""
        + head
        + r"""|"""
        + _QUOTED_KEY_HEAD
        + r"""))[^ \t\r\n,;}\]"'{[])+|['"](?=[\s,;}\]]|\Z)))*"""
    )

inline_secret_assignment = re.compile(
    r"(?i)(" + _INLINE_KEY_HEAD + _COMMENT_GAP + r")(?:(?:!{1,2}[A-Za-z0-9_-]+|&[A-Za-z0-9_-]+)[ \t]+)*(\"(?:\\[\s\S]|[^\"\\])*\"|'(?:[^']|'')*'|\"(?:\\[\s\S]|[^\"\\])*|"
    + _unquoted_value(_INLINE_KEY_HEAD)
    + r")" + _spliced_tail(_INLINE_KEY_HEAD)
)


def redact_text(value):
    _check_key_gaps(value, _INLINE_KEY_CANDIDATE)
    value, _suppress = redact_userpass_mappings(value)
    if _suppress:
        raise _SuppressDocument()
    value = pem_span.sub("***REDACTED-PEM***", value)
    value = redact_block_scalars(value)
    value = link.sub("***CLIENT_LINK_REDACTED***", value)
    value = url_userinfo.sub(r"\1***REDACTED***@", value)
    value = inline_authorization.sub(r"\1***REDACTED***", value)
    value = inline_cookie.sub(r"\1***REDACTED***", value)
    # 06h2-H02: a JSON string may carry a VLESS client id ("id: ...")
    # that the dict walk never sees as a key. The text path already
    # runs _redact_id_text; the walk string branch did not, so the id
    # survived verbatim. Same position as the text path (after the
    # authorization/cookie rules, before the key-assignment rule).
    value = _redact_id_text(value)
    value = inline_secret_assignment.sub(r'\1"***REDACTED***"', value)
    return value


_block_scalar_key = r"(?:uuid|private.?key|public.?key|short.?ids?|fingerprint|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key|authorization|cookie|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)"
_block_scalar_re = re.compile(
    r"(?i)^(\s*[\"']?" + _block_scalar_key + r"[\"']?\s*:\s*(?:(?:!{1,2}[A-Za-z0-9_-]+|&[A-Za-z0-9_-]+)[ \t]+)*)[|>](?:[1-9][+-]?|[+-][1-9]?)?\s*(#.*)?$"
)


# R14-F13-02 (plain scalars): a sensitive key with an unquoted value
# may continue on the following more-indented lines, which same-line
# regexes never see. Those continuation lines are part of the value,
# not a new key: a sibling key sits at the same or a lower indent, and
# a nested mapping under the key has no value on the key line (so it
# never matches: the value group below requires a first value char).
_plain_scalar_re = re.compile(
    r"(?i)^(\s*[\"']?" + _block_scalar_key + r"[\"']?\s*:\s*(?:(?:!{1,2}[A-Za-z0-9_-]+|&[A-Za-z0-9_-]+)[ \t]+)*)([^\"'\[\]{|>&*!#\s][^\r\n]*)$"
)


def redact_block_scalars(text):
    # A sensitive key with | or > puts the secret on the following
    # more-indented lines, which same-line regexes never see (R12C13-01).
    # The same holds for an unquoted plain scalar (R14-F13-02): its
    # continuation lines are redacted here; the value on the key line
    # itself is redacted by the same-line regexes that run after this
    # function. Blank lines inside a block carry no secret and pass
    # through.
    lines = text.split("\n")
    out = []
    block_indent = None
    plain_indent = None
    for line in lines:
        if block_indent is not None:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if stripped == "" or indent > block_indent:
                out.append(" " * indent + "***REDACTED***" if stripped != "" else line)
                continue
            block_indent = None
        if plain_indent is not None:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if stripped == "" or indent > plain_indent:
                out.append(" " * indent + "***REDACTED***" if stripped != "" else line)
                continue
            plain_indent = None
        m = _block_scalar_re.match(line)
        if m:
            out.append(m.group(1) + "***REDACTED***")
            block_indent = len(line) - len(line.lstrip())
            plain_indent = None
        elif _plain_scalar_re.match(line):
            out.append(line)
            plain_indent = len(line) - len(line.lstrip())
        else:
            out.append(line)
    return "\n".join(out)



class _SuppressDocument(Exception):
    pass


_SUPPRESS_NOTICE = "[ABOX REDACTED DOCUMENT OMITTED: this document contains PEM material, a YAML block scalar, a cross-line value, an unsupported credential mapping, or a sensitive array that the redactor cannot verify; it was suppressed in full and no original content is included.]"
_USERPASS_HEADER = re.compile(r"(?i)^(\s*[\"']?)userpass[\"']?\s*:\s*(.*)$")


def _quoted_closed(value, quote):
    i = 0
    while i < len(value):
        c = value[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if c == quote:
            if quote == "'" and i + 1 < len(value) and value[i + 1] == "'":
                i += 2
                continue
            return True
        i += 1
    return False


def redact_userpass_mappings(text):
    # HY2 userpass mappings (R12-02): a `userpass:` header with a
    # mapping value hides every credential in its indented subtree,
    # which the generic scalar regexes never see (they only match
    # `pass:` inside the header line and swallow the first entry).
    # Replace the header with a redacted marker and discard the
    # subtree; blank and comment-only lines do not terminate it.
    # Returns (new_text, suppress): suppress is True when the value
    # is a flow mapping, anchor/alias/tag, or unclosed quote that
    # cannot be verified line by line — the caller must suppress
    # the whole document (D2) instead of guessing.
    lines = text.split("\n")
    out = []
    header_indent = None
    for line in lines:
        if header_indent is not None:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if stripped == "" or stripped.startswith("#") or indent > header_indent:
                continue
            header_indent = None
        m = _USERPASS_HEADER.match(line)
        if not m:
            out.append(line)
            continue
        indent = len(line) - len(line.lstrip())
        rest = m.group(2).strip()
        if rest == "" or rest.startswith("#"):
            out.append(" " * indent + 'userpass: "***REDACTED***"')
        elif rest[0] in "{[":
            return text, True
        elif rest[0] in "|>":
            out.append(" " * indent + 'userpass: "***REDACTED***"')
        elif rest[0] in "&*!":
            return text, True
        elif rest[0] in "\"'":
            if _quoted_closed(rest[1:], rest[0]):
                out.append(" " * indent + 'userpass: "***REDACTED***"')
            else:
                return text, True
        else:
            out.append(" " * indent + 'userpass: "***REDACTED***"')
        header_indent = indent
    return "\n".join(out), False


# A-05b-FIX: UUID regex for "id" key check (Xray clients[].id holds UUIDs).
uuid_val = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


# R7-F13-3: complete-scalar id matcher for the text branch. Xray accepts
# any short string as a VLESS client id (mapped to UUIDv5), so a non-UUID
# string id is a credential too. A bare integer id is a numeric field,
# not a credential, and is kept; a quoted "123" is a string and is
# redacted. The key spelling is unchanged (\bid\b): a `client-id` key
# tail was already matched (and redacted) by the old rule, so narrowing
# the key boundary would regress it.
# R11E-R7-2: comment-aware id matcher. The old `_id_scalar_re` required
# the value immediately after the separator, so a JSONC comment (`/* */`
# or `//` to end of line) sitting between the `id` key and its value was
# itself consumed as the bare scalar and the real credential survived.
# This scanner consumes the whole key-to-value gap (whitespace plus any
# number of JSONC comments, on either side of `:`/`=`), then redacts
# only the real scalar. A comment gap that never yields a verifiable
# value (unterminated block comment, or a structural character / EOF
# right after the comment) raises _SuppressDocument (D2): the document
# is suppressed rather than released with an unverified id value. A
# bare integer id is still a numeric field, not a credential, and is
# kept; a quoted "123" is a string and is redacted. The key boundary
# is unchanged (\\bid\\b): a `client-id` key tail is still matched.
_ID_KEY_RE = re.compile(r"(?i)\bid\b[\"']?")
# (M01: the old _BARE_ID_RE `[^\s,}\]]+` is replaced by _bare_id_end below.)


def _skip_id_gap(text, pos):
    # Skip whitespace and JSONC comments starting at pos. Returns
    # (new_pos, saw_comment). Raises _SuppressDocument on an
    # unterminated block comment or a line comment with no line end.
    saw_comment = False
    n = len(text)
    while pos < n:
        c = text[pos]
        if c in " \t\r\n":
            pos += 1
            continue
        if text.startswith("/*", pos):
            end = text.find("*/", pos + 2)
            if end == -1:
                raise _SuppressDocument()
            saw_comment = True
            pos = end + 2
            continue
        if text.startswith("//", pos):
            end = text.find("\n", pos + 2)
            if end == -1:
                raise _SuppressDocument()
            saw_comment = True
            pos = end + 1
            continue
        break
    return pos, saw_comment


# R12B-N1: sensitive-key candidates for the malformed-gap guard. The key
# word + optional quotes, WITHOUT the separator: an unterminated comment
# between key and separator prevents the full head from matching at all,
# so the guard must start from the key alone. Kept in sync with the two
# key heads above (the inline candidate also covers
# authorization/proxy-authorization/cookie/set-cookie, which redact_text()
# must guard even though _INLINE_KEY_HEAD excludes them).
_TEXT_KEY_CANDIDATE = (
    r"""["']?(?:uuid|private.?key|public.?key|short.?ids?|fingerprint"""
    r"""|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key"""
    r"""|authorization|cookie|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)["']?"""
)
_INLINE_KEY_CANDIDATE = (
    r"""["']?\b(?:uuid|private.?key|public.?key|short.?ids?|fingerprint"""
    r"""|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key"""
    r"""|authorization|proxy-authorization|cookie|set-cookie"""
    r"""|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)\b["']?"""
)


def _check_key_gaps(text, key_re):
    # Fail closed (R12B-N1): a JSONC comment in a sensitive-key gap that
    # never closes (or a // comment with no line end) cannot be verified
    # by the regexes below; suppress the document rather than risk the
    # real value surviving past the comment. Starts from a KEY CANDIDATE
    # (no separator required) and skips the gap after the key, then again
    # after the separator when one follows. Raises _SuppressDocument.
    for _m in re.finditer(r"(?i)" + key_re, text):
        _pos, _saw = _skip_id_gap(text, _m.end())
        if _pos < len(text) and text[_pos] in ":=":
            _skip_id_gap(text, _pos + 1)


# R12B-C2: stop-head for the tempered bare-id scan below, derived from the
# shared _TEXT_KEY_HEAD (plus `id` itself, so a following id field stays
# visible to this scanner). No copying of the key table.
_BARE_ID_STOP_RE = re.compile(
    r"(?i)(?:" + _TEXT_KEY_HEAD + r"|" + r"""["']?id["']?\s*[:=]""" + r")"
)


def _bare_id_end(text, pos):
    # M01 (06h2-M01): a bare id scalar is the WHOLE scalar, not the first
    # whitespace-delimited token. Extend to end of line, or to the first
    # `,`, `}`, `]` (or a `;` that starts a following sensitive key, the
    # R12B-C2 rule), or to a following sensitive-key head after whitespace
    # (`id: alpha beta token: xyz` leaves `token:` for its own redaction).
    # Trailing blanks before the boundary are trimmed from the value.
    # The old _BARE_ID_RE (`[^\s,}\]]+`) stopped at the first blank, so
    # `id: alpha beta` leaked `beta` and `id: 123 beta` was judged (and
    # kept whole) by its first token `123` alone.
    n = len(text)
    end = pos
    i = pos
    while i < n:
        c = text[i]
        # R50-H1: no backslash in the terminator set. The old
        # literal kept a literal backslash (an unrecognised
        # escape in a plain string), so an id value starting with a
        # backslash ended at pos and was skipped whole, and a
        # mid-value backslash leaked the tail after it.
        if c in ",}]\r\n":
            break
        if c == ";":
            if _bare_id_stops(text, i):
                break
            i += 1
            end = i
            continue
        if i > pos and text[i - 1] in " \t" and _BARE_ID_STOP_RE.match(text, i):
            break
        i += 1
        if c not in " \t":
            end = i
    return end


def _bare_id_stops(text, pos):
    # At a ';' inside a bare id value, stop only when a sensitive key-head
    # follows (after optional whitespace / JSONC comments, skipped with the
    # existing gap semantics). An unterminated comment in that gap is
    # treated as "no stop": the comment and everything after it is then
    # consumed into the id value and redacted, so nothing survives.
    try:
        _p2, _saw = _skip_id_gap(text, pos + 1)
    except _SuppressDocument:
        return False
    return _BARE_ID_STOP_RE.match(text, _p2) is not None


def _redact_id_text(text):
    out = []
    cursor = 0
    for m in _ID_KEY_RE.finditer(text):
        if m.start() < cursor:
            continue
        pos = m.end()
        pos, saw_comment = _skip_id_gap(text, pos)
        if pos >= len(text) or text[pos] not in ":=":
            continue
        pos += 1
        pos, saw_comment2 = _skip_id_gap(text, pos)
        saw_comment = saw_comment or saw_comment2
        if pos >= len(text):
            if saw_comment:
                raise _SuppressDocument()
            continue
        c = text[pos]
        if c == '"':
            j = pos + 1
            closed = False
            while j < len(text):
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    closed = True
                    j += 1
                    break
                j += 1
            if not closed:
                raise _SuppressDocument()
            val_end = j
            val_text = text[pos:val_end]
            keep = False
        elif c == "'":
            j = pos + 1
            closed = False
            while j < len(text):
                if text.startswith("''", j):
                    j += 2
                    continue
                if text[j] == "'":
                    closed = True
                    j += 1
                    break
                j += 1
            if not closed:
                raise _SuppressDocument()
            val_end = j
            val_text = text[pos:val_end]
            keep = False
        else:
            # M01 (06h2-M01): complete-scalar boundary (see _bare_id_end):
            # the old _BARE_ID_RE stopped at the first blank, leaking the
            # rest (`id: alpha beta` kept `beta`) and judging `123 beta`
            # by its first token alone (kept whole as an "integer").
            val_end = _bare_id_end(text, pos)
            if val_end <= pos:
                if saw_comment:
                    raise _SuppressDocument()
                if pos >= len(text) or text[pos] != ";":
                    continue
                # Empty value before a `;`-led key (`id: ;token: ...`):
                # the old code redacted the empty span; keep that shape.
            val_text = text[pos:val_end]
            keep = re.fullmatch(r"-?\d+", val_text) is not None
        out.append(text[cursor:m.start()])
        if keep:
            out.append(text[m.start():val_end])
        else:
            out.append(text[m.start():pos])
            out.append('"***REDACTED***"')
        cursor = val_end
    out.append(text[cursor:])
    return "".join(out)



def walk(value, in_clients=False):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            lk = str(key).lower()
            if lk == "userpass":
                if isinstance(item, dict):
                    result[key] = {k: "***REDACTED***" for k in item}
                else:
                    result[key] = "***REDACTED***"
            elif secret.search(str(key)) or (lk == "id" and isinstance(item, str) and (uuid_val.match(item) or in_clients)):
                result[key] = "***REDACTED***"
            elif lk == "clients" and isinstance(item, list):
                result[key] = [walk(element, True) for element in item]
            else:
                result[key] = walk(item, in_clients)
        return result
    if isinstance(value, list):
        return [walk(item, in_clients) for item in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


try:
    parsed = json.loads(text)
except Exception:
    try:
        _check_key_gaps(text, _TEXT_KEY_CANDIDATE)
    except _SuppressDocument:
        sys.stdout.write(_SUPPRESS_NOTICE + "\n")
        raise SystemExit(2)
    text, _suppress = redact_userpass_mappings(text)
    if _suppress:
        sys.stdout.write(_SUPPRESS_NOTICE + "\n")
        raise SystemExit(2)
    text = pem_span.sub("***REDACTED-PEM***", text)
    text = redact_block_scalars(text)
    text = url_userinfo.sub(r"\1***REDACTED***@", text)
    text = re.sub(
        r"(?im)^(UUID|PUBLIC_KEY|SHORT_ID|HY2_CERT_SHA256_FP|HY2_CERT_PUBKEY_SHA256_B64|SS_PASS|HY2_PASS|HY2_OBFS|HY2_ACME_DNS_CF_API_TOKEN|SOCKS_USER|SOCKS_PASS)=.*$",
        r"\1=***REDACTED***",
        text,
    )
    text = re.sub(
        r"(?i)(\b(?:authorization|proxy-authorization)" + _COMMENT_GAP + r":" + _COMMENT_GAP + r")(?:bearer\s+(?:[^\s,;}]*[ \t]*:[ \t]+" + _AUTH_QUOTED_TAIL + _AUTH_EXTRA + r"|[^\s,;}]+" + _AUTH_EXTRA + r")|basic\s+(?:[^\s,;}]*[ \t]*:[ \t]+" + _AUTH_QUOTED_TAIL + _AUTH_EXTRA + r"|[^\s,;}]+" + _AUTH_EXTRA + r")|" + _AUTH_GENERIC_VALUE + r")",
        r'\1***REDACTED***',
        text,
    )
    text = re.sub(
        r"(?i)(\b(?:cookie|set-cookie)" + _COMMENT_GAP + r":" + _COMMENT_GAP + r")[^\r\n]+",
        r'\1***REDACTED***',
        text,
    )
    try:
        text = _redact_id_text(text)
    except _SuppressDocument:
        sys.stdout.write(_SUPPRESS_NOTICE + "\n")
        raise SystemExit(2)
    text = re.sub(
        r"(?i)([\"']?(?:uuid|private.?key|public.?key|short.?ids?|fingerprint|password|passwd|pass|pre[_-]?shared[_-]?key|token|secret|api.?key|authorization|cookie|ss_pass|hy2_pass|hy2_obfs|key|username|user|socks_user|socks_pass)[\"']?\s*[:=]\s*\[)[^\]]*",
        r'\1***REDACTED***',
        text,
    )
    # R27-F13-02: the second double-quote alternative below redacts a
    # value whose closing quote never arrives (truncated input); without
    # it the value passes through verbatim with rc=0. It consumes to the
    # next quote or end of text (fail-closed: once the quote is unclosed
    # the value boundary is unknowable, so nothing after it is trusted).
    text = re.sub(
        r"(?i)(" + _TEXT_KEY_HEAD + _COMMENT_GAP + r")(?:(?:!{1,2}[A-Za-z0-9_-]+|&[A-Za-z0-9_-]+)[ \t]+)*(\"(?:\\[\s\S]|[^\"\\])*\"|\"(?:\\[\s\S]|[^\"\\])*|'(?:[^']|'')*'|"
        + _unquoted_value(_TEXT_KEY_HEAD)
        + r")" + _spliced_tail(_TEXT_KEY_HEAD),
        r'\1"***REDACTED***"',
        text,
    )
    sys.stdout.write(link.sub("***CLIENT_LINK_REDACTED***", text))
else:
    try:
        redacted = walk(parsed)
    except _SuppressDocument:
        sys.stdout.write(_SUPPRESS_NOTICE + "\n")
        raise SystemExit(2)
    json.dump(redacted, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
PY_REDACT
    else
        # No Python, no verified redactor (Scheme A, R19): suppress the
        # whole document unconditionally. Do not read stdin, do not
        # buffer input, do not scan, do not run sed. The fixed notice
        # below is the whole output; a failed notice write is rc=1
        # (never masked as 2).
        if printf '%s\n' '[ABOX REDACTED DOCUMENT OMITTED: python3 is unavailable; diagnostic redaction cannot be verified. This document was suppressed in full and no original content is included.]'; then
            return 2
        else
            return 1
        fi
    fi
}

# Status of the last write_redacted_file call (D2): redacted | omitted |
# absent | failed. Callers (export_diagnostic_bundle) record it in the
# bundle's omissions manifest; a suppressed document must never be
# reported as a redacted one.
WRITE_REDACTED_FILE_STATUS=''
write_redacted_file() {
    local src="$1" dst="$2" _rc
    WRITE_REDACTED_FILE_STATUS='failed'
    [[ -r "$src" ]] || { WRITE_REDACTED_FILE_STATUS='absent'; return 0; }
    mkdir -p "$(dirname "$dst")" || return 1
    redact_secrets_stream < "$src" > "$dst" 2>/dev/null; _rc=$?
    if [[ "$_rc" == 2 ]]; then
        # Whole document suppressed (python3 unavailable: unconditional
        # whole-document suppression): the notice-only file is kept
        # (it says so), but it is an omission, not a redacted copy.
        [[ -s "$dst" ]] || { rm -f -- "$dst"; return 1; }
        WRITE_REDACTED_FILE_STATUS='omitted'
        return 0
    fi
    [[ "$_rc" == 0 ]] || { rm -f -- "$dst"; return 1; }
    [[ -s "$dst" ]] || { rm -f -- "$dst"; return 1; }
    WRITE_REDACTED_FILE_STATUS='redacted'
}

# Append one per-file collection outcome to the diagnostic bundle's
# omissions manifest and bump the matching _diag_n_* counter (D2).
# $1 manifest file, $2 bundle-relative path, $3 status
# (generated|redacted|omitted|absent|failed), $4 reason.
_diagnostic_record() {
    printf '%s: %s (%s)\n' "$2" "$3" "$4" >> "$1"
    case "$3" in
        generated) _diag_n_generated=$(( ${_diag_n_generated:-0} + 1)) ;;
        redacted) _diag_n_redacted=$(( ${_diag_n_redacted:-0} + 1)) ;;
        omitted) _diag_n_omitted=$(( ${_diag_n_omitted:-0} + 1)) ;;
        absent) _diag_n_absent=$(( ${_diag_n_absent:-0} + 1)) ;;
        failed) _diag_n_failed=$(( ${_diag_n_failed:-0} + 1)) ;;
    esac
}

validate_abox_cron_file() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    python3 -I - "$file" <<'PY_ABOX_CRON'
import sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text(encoding='utf-8',errors='strict').splitlines()
# A-06-FIX: Accept BOTH formats (writes only produce new format).
# Old format must still validate for backward compat (existing hosts + v3 backups).
allowed={
 'PROBE':{
  '* * * * * /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1',
  '* * * * * /usr/bin/flock -n /run/A-Box-probe-cron.lock /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1',
 },
 'GEO':{
  '0 3 * * 1 /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1',
  '0 3 * * 1 /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1',
 },
 'TRAFFIC':{
  '* * * * * /bin/bash /etc/ddr/traffic_monitor.sh >/dev/null 2>&1',
 },
 'USERGUARD':{
  '*/5 * * * * /bin/bash /etc/ddr/user-guard-runner.sh --user-guard-tick >/dev/null 2>&1',
 },
}
i=0; seen=set()
bare=set()
for _v in allowed.values(): bare.update(_v)
while i < len(lines):
    if not lines[i]: i+=1; continue
    if lines[i] in bare: i+=1; continue
    if not (lines[i].startswith('# A-Box ') and lines[i].endswith(' BEGIN')): raise SystemExit(1)
    name=lines[i][8:-6]
    if name not in allowed or name in seen or i+2 >= len(lines): raise SystemExit(1)
    if lines[i+1] not in allowed[name] or lines[i+2] != f'# A-Box {name} END': raise SystemExit(1)
    seen.add(name); i+=3
PY_ABOX_CRON
}

collect_abox_cron() {
    local all err extracted
    all=$(umask 077; mktemp /tmp/A-Box-cron-all.XXXXXX) || return 1
    err=$(umask 077; mktemp /tmp/A-Box-cron-err.XXXXXX) || { rm -f "$all"; return 1; }
    extracted=$(umask 077; mktemp /tmp/A-Box-cron-extract.XXXXXX) || { rm -f "$all" "$err"; return 1; }
    if LC_ALL=C crontab -l > "$all" 2> "$err"; then :
    elif grep -Eqi "no crontab|no crontab for|can't open '[^']*': No such file" "$err"; then : > "$all"
    else rm -f "$all" "$err" "$extracted"; return 1
    fi
    awk '
      function norm_line(s,   t, old) { t=s; do { old=t; sub(/[ \t]+$/, "", t); if (length(t) >= 1 && substr(t, length(t), 1) == "\r") t=substr(t, 1, length(t)-1); if (length(t) >= 2 && substr(t, length(t)-1, 2) == "\\r") t=substr(t, 1, length(t)-2); } while (t != old); gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); return t }
      function bare_line_owner(n) {
        if (n == "* * * * * /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1" || n == "* * * * * /usr/bin/flock -n /run/A-Box-probe-cron.lock /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1") return "PROBE"
        if (n == "0 3 * * 1 /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1" || n == "0 3 * * 1 /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1") return "GEO"
        if (n == "* * * * * /bin/bash /etc/ddr/traffic_monitor.sh >/dev/null 2>&1") return "TRAFFIC"
        if (n == "*/5 * * * * /bin/bash /etc/ddr/user-guard-runner.sh --user-guard-tick >/dev/null 2>&1") return "USERGUARD"
        return ""
      }
      /^# A-Box (PROBE|GEO|TRAFFIC|USERGUARD) BEGIN$/ {inblock=1}
      inblock {print}
      /^# A-Box (PROBE|GEO|TRAFFIC|USERGUARD) END$/ {inblock=0}
      !inblock && bare_line_owner(norm_line($0)) != "" {
          # R50-M1: print the same normalised line the recognition
          # used. The old block re-normalised $0 (spaces only), so a
          # bare task ending in a literal backslash-r was recognised
          # but printed with it intact, and the validator (exact
          # allowlist) then failed the whole collection.
          print norm_line($0)
      }
      END {if (inblock) exit 1}
    ' "$all" > "$extracted" || { rm -f "$all" "$err" "$extracted"; return 1; }
    validate_abox_cron_file "$extracted" || { rm -f "$all" "$err" "$extracted"; return 1; }
    local cat_rc=0
    cat "$extracted" || cat_rc=$?
    rm -f "$all" "$err" "$extracted"
    return "$cat_rc"
}

read_crontab_to_file() {
    local out="$1" err
    [[ -n "$out" ]] || return 1
    err=$(umask 077; mktemp /tmp/A-Box-crontab-error.XXXXXX) || return 1
    if LC_ALL=C crontab -l > "$out" 2> "$err"; then
        rm -f -- "$err"
        return 0
    elif grep -Eqi "no crontab|no crontab for|can't open '[^']*': No such file" "$err"; then
        # S5 (R51-M2 follow-up): the truncation must not be silent -- a
        # failed `: >` (e.g. the file vanishing between the two opens)
        # used to fall through to `return 0` and report an empty
        # crontab, the same masking R51-M2 fixed in
        # capture_abox_iptables_snapshot.
        : > "$out" || return 1
        rm -f -- "$err"
        return 0
    fi
    rm -f -- "$err"
    return 1
}

strip_abox_cron_blocks_from_file() {
    local input="$1" output="$2" name="${3:-}"
    [[ -f "$input" && ! -L "$input" && -n "$output" ]] || return 1
    awk -v wanted="$name" '
      function norm_line(s,   t, old) { t=s; do { old=t; sub(/[ \t]+$/, "", t); if (length(t) >= 1 && substr(t, length(t), 1) == "\r") t=substr(t, 1, length(t)-1); if (length(t) >= 2 && substr(t, length(t)-1, 2) == "\\r") t=substr(t, 1, length(t)-2); } while (t != old); gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); return t }
      function bare_line_owner(n) {
        if (n == "* * * * * /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1" || n == "* * * * * /usr/bin/flock -n /run/A-Box-probe-cron.lock /bin/bash /etc/ddr/socket_probe.sh >/dev/null 2>&1") return "PROBE"
        if (n == "0 3 * * 1 /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1" || n == "0 3 * * 1 /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1") return "GEO"
        if (n == "* * * * * /bin/bash /etc/ddr/traffic_monitor.sh >/dev/null 2>&1") return "TRAFFIC"
        if (n == "*/5 * * * * /bin/bash /etc/ddr/user-guard-runner.sh --user-guard-tick >/dev/null 2>&1") return "USERGUARD"
        return ""
      }
      BEGIN { skip=0; seen_wanted=0; open_name=""; depth=0 }
      {
        if (wanted != "" && $0 ~ /^# A-Box [^ ]+ BEGIN$/) {
          if (depth > 0) exit 1
          depth++; stack[depth]=$3
          if ($3 == wanted) { if (skip) exit 1; skip=1; seen_wanted=seen_wanted+1; next }
          if (skip) next
          print; next
      }
        if (wanted != "" && $0 ~ /^# A-Box [^ ]+ END$/) {
          if (depth == 0 || stack[depth] != $3) exit 1
          depth--
          if ($3 == wanted) { if (!skip) exit 1; skip=0; next }
          if (skip) next
          print; next
      }
        if (wanted == "" && $0 ~ /^# A-Box (PROBE|GEO|TRAFFIC|USERGUARD) BEGIN$/) { if (skip) exit 1; skip=1; open_name=$3; next }
        if (wanted == "" && $0 ~ /^# A-Box (PROBE|GEO|TRAFFIC|USERGUARD) END$/) { if (!skip || $3 != open_name) exit 1; skip=0; open_name=""; next }
        if (skip) next
        if (wanted == "" && bare_line_owner(norm_line($0)) != "") next
        if (wanted != "" && bare_line_owner(norm_line($0)) == wanted) next
        print
      }
      END { if (skip) exit 1; if (depth > 0) exit 1; if (wanted != "" && seen_wanted > 1) exit 1 }
    ' "$input" > "$output" || return 1
}

commit_crontab_if_unchanged() {
    local snapshot="$1" candidate="$2" live rc=0
    # R15C13-01 (A-Box side): refuse outside a session. Every legitimate
    # caller runs under enter_runtime, which sets ABOX_RUNTIME_LOCK_MODE;
    # without it, this read-modify-write could silently lose a concurrent
    # change. rc 2 is the existing "aborted, do not overwrite" signal.
    if [[ -z "${ABOX_RUNTIME_LOCK_MODE:-}" ]]; then
        printf '%s\n' 'A-Box cron update refused: no A-Box runtime lock held; refusing to modify crontab outside a session.' >&2
        return 2
    fi
    [[ -f "$snapshot" && ! -L "$snapshot" && -f "$candidate" && ! -L "$candidate" ]] || return 1
    live=$(mktemp) || return 1
    if ! read_crontab_to_file "$live"; then rm -f -- "$live"; return 1; fi
    if ! cmp -s -- "$snapshot" "$live"; then
        rm -f -- "$live"
        printf '%s\n' 'A-Box cron update aborted: crontab changed concurrently; no overwrite was attempted.' >&2
        return 2
    fi
    # Re-read immediately before installing: the first comparison only
    # covers changes up to the first read, not the install itself.
    if ! read_crontab_to_file "$live"; then rm -f -- "$live"; return 1; fi
    if ! cmp -s -- "$snapshot" "$live"; then
        rm -f -- "$live"
        printf '%s\n' 'A-Box cron update aborted: crontab changed concurrently; no overwrite was attempted.' >&2
        return 2
    fi
    rm -f -- "$live"
    crontab "$candidate" >/dev/null 2>&1 || rc=1
    if (( rc == 0 )); then
        # Verify the install: a write interleaving after ours is
        # detectable (installed content differs from the candidate).
        # A write landing between the last check and the install cannot
        # be detected through the crontab CLI, which offers no
        # compare-and-swap; that residual window is inherent to crontab.
        live=$(mktemp) || return 1
        if ! read_crontab_to_file "$live"; then rm -f -- "$live"; return 1; fi
        if ! cmp -s -- "$candidate" "$live"; then
            rm -f -- "$live"
            printf '%s\n' 'A-Box cron update verification failed: crontab changed during install; installed content differs from the candidate.' >&2
            return 1
        fi
        rm -f -- "$live"
    fi
    return "$rc"
}

install_abox_cron_block() {
    local name="$1" line="$2" current tmp
    [[ -n "$name" && -n "$line" ]] || return 1
    # M-08(3): fail closed on a newline or '%' in the cron line:
    # cron treats '%' as a newline, so either would smuggle extra
    # commands past the single-line block format.
    case "$line" in
        *$'\n'*|*%*) return 1 ;;
    esac
    current=$(mktemp) || die "$(tr_msg install_abox_cron_block_current_tmp_failed)"
    tmp=$(mktemp) || { rm -f -- "$current"; die "$(tr_msg install_abox_cron_block_tmp_failed)"; }
    if ! read_crontab_to_file "$current"; then
        rm -f -- "$current" "$tmp"
        die "$(tr_msg install_abox_cron_block_read_failed)"
    fi
    if ! strip_abox_cron_blocks_from_file "$current" "$tmp" "$name"; then
        rm -f -- "$current" "$tmp"
        die "$(tprintf install_abox_cron_block_bad_format "${name}")"
    fi
    {
        printf '%s\n' "# A-Box ${name} BEGIN"
        printf '%s\n' "$line"
        printf '%s\n' "# A-Box ${name} END"
    } >> "$tmp" || { rm -f -- "$current" "$tmp"; die "$(tr_msg install_abox_cron_block_tmp_write_failed)"; }
    local commit_rc=0
    commit_crontab_if_unchanged "$current" "$tmp" || commit_rc=$?
    if (( commit_rc != 0 )); then
        rm -f -- "$current" "$tmp"
        if (( commit_rc == 2 )); then die "$(tr_msg install_abox_cron_block_concurrent_change)"; fi
        die "$(tr_msg install_abox_cron_block_commit_failed)"
    fi
    rm -f -- "$current" "$tmp"
}

remove_abox_cron_block() {
    local name="$1" current tmp rc=0
    [[ -n "$name" ]] || return 1
    current=$(mktemp) || die "$(tr_msg remove_abox_cron_block_current_tmp_failed)"
    tmp=$(mktemp) || { rm -f -- "$current"; die "$(tr_msg remove_abox_cron_block_tmp_failed)"; }
    if ! read_crontab_to_file "$current"; then
        rm -f -- "$current" "$tmp"
        return 1
    fi
    if ! strip_abox_cron_blocks_from_file "$current" "$tmp" "$name"; then
        rm -f -- "$current" "$tmp"
        return 1
    fi
    commit_crontab_if_unchanged "$current" "$tmp" || rc=$?
    rm -f -- "$current" "$tmp"
    return "$rc"
}

# SYD-B4 D13: full-clear residual report. Lines that still reference a
# known managed script after stripping are unknown variants, not silent
# keeps; report them on stderr. Report only, never fail the clear, and
# never report user scripts (unknown basenames are not matched).
# SYD-B7: backslash-continued split paths are a line-scanner limit,
# accepted as-is; the regex is not stretched to cover them.
report_unrecognized_abox_cron_lines() {
    local file="$1" line _abox_report_re='(^|[[:space:]\"'"'"';&|(`=])/etc/ddr/(socket_probe|geo_update|traffic_monitor|user-guard-runner)\.sh([[:space:]"'"'"';<>&|)`]|$)'
    local _abox_report_skip_re='^['' '$'\t'']*((([*0-9,/-]+|(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|SUN|MON|TUE|WED|THU|FRI|SAT)(-(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|SUN|MON|TUE|WED|THU|FRI|SAT))?(,(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|SUN|MON|TUE|WED|THU|FRI|SAT)(-(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|SUN|MON|TUE|WED|THU|FRI|SAT))?)*)['' '$'\t'']+){5}|@[a-z]+['' '$'\t'']+)?[A-Za-z_][A-Za-z0-9_]*=((\\?/etc/ddr/(socket_probe|geo_update|traffic_monitor|user-guard-runner)\.sh|"\\?/etc/ddr/(socket_probe|geo_update|traffic_monitor|user-guard-runner)\.sh"|'"'"'\\?/etc/ddr/(socket_probe|geo_update|traffic_monitor|user-guard-runner)\.sh\\?'"'"')(['' '$'\t'']+#.*|['' '$'\t'']*)|\\?/etc/ddr/(socket_probe|geo_update|traffic_monitor|user-guard-runner)\.sh\\['' '$'\t'']*)$'
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ $_abox_report_re ]] || continue
        # SYD-B12: skip only when the whole line is a single assignment:
        # prefix is empty, exactly 5 schedule-validated fields, or exactly
        # 1 @-field; schedule fields must match cron-field syntax (digits,
        # *, /, -, comma, or JAN-DEC/SUN-SAT names); anything else after
        # the assignment must still be reported: a missed execution
        # reference is worse than report noise, so on doubt, report.
        # The value is an unquoted, double-quoted, or single-quoted path
        # (quotes must pair; the double-quoted closing quote must not be
        # backslash-escaped). A trailing backslash pairs only with a blank
        # tail (B7 continuation limit), never with a comment tail (an
        # escaped space is not a comment start). Single-quoted trailing
        # backslash stays allowed: inside single quotes a backslash is
        # literal, so the closing quote is real. The tail is empty or
        # whitespace plus a #-comment (a # glued to the value is NOT a
        # comment).
        # SYD-B14: skip blanks are literal ASCII space (0x20) + TAB
        # (0x09) embedded as real bytes via single-quote concatenation.
        # Never [[:blank:]]: it expands with locale (U+2003 etc. under
        # UTF-8 locales count as blank, GPT B13 review P2). Never
        # [ \t]: bash ERE reads it as {space, backslash, t}, not tab.
        # Never pin LC_ALL=C here: it would also narrow the entry
        # regex [[:space:]] match (under-match direction change).
        if [[ "$line" =~ $_abox_report_skip_re ]]; then continue; fi
        printf '%s\n' "[!] $(tprintf report_unrecognized_abox_cron_lines_residual "$line")" >&2
    done < "$file"
    # D14: unknown A-Box blocks survive a full clear by design (never
    # deleted); report them so a kept block is never silent.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#\ A-Box\ ([A-Z0-9_-]+)\ BEGIN$ ]] || continue
        case "${BASH_REMATCH[1]}" in
            PROBE|GEO|TRAFFIC|USERGUARD) ;;
            *) printf '%s\n' "[!] A-Box cron residual: unknown block ${BASH_REMATCH[1]} kept" >&2 ;;
        esac
    done < "$file"
    return 0
}

remove_all_abox_cron_blocks() {
    local current tmp rc=0
    current=$(mktemp) || die "$(tr_msg remove_all_abox_cron_blocks_current_tmp_failed)"
    tmp=$(mktemp) || { rm -f -- "$current"; die "$(tr_msg remove_all_abox_cron_blocks_tmp_failed)"; }
    if ! read_crontab_to_file "$current"; then
        rm -f -- "$current" "$tmp"
        return 1
    fi
    if ! strip_abox_cron_blocks_from_file "$current" "$tmp"; then
        rm -f -- "$current" "$tmp"
        return 1
    fi
    report_unrecognized_abox_cron_lines "$tmp" || true
    commit_crontab_if_unchanged "$current" "$tmp" || rc=$?
    rm -f -- "$current" "$tmp"
    return "$rc"
}

service_enabled_state_value() {
    local srv="$1" state output rc
    if [[ "${INIT_SYS:-}" == systemd ]] && systemd_available; then
        output=$(systemctl show -p UnitFileState --value "$srv" 2>/dev/null) || return 1
        state="$output"
        case "$state" in
            enabled|enabled-runtime|indirect|disabled) printf '%s\n' "$state" ;;
            *) return 1 ;;
        esac
        return 0
    elif [[ "${INIT_SYS:-}" == openrc ]]; then
        command -v rc-update >/dev/null 2>&1 || return 1
        output=$(rc-update show default 2>/dev/null) || return 1
        if grep -Eq "(^|[[:space:]])${srv//[^a-zA-Z0-9_.@+-]/}([[:space:]]|$)" <<< "$output"; then
            printf '1\n'
        else
            printf '0\n'
        fi
        return 0
    fi
    return 1
}

# 2mb residual: list the unit(s) whose [Install] Also= names $1.
# Best-effort discovery for the indirect-restore warning: the Also=
# source link lives outside A-Box control, so a restore that lands on
# disabled (snapshot was indirect) names the candidate source(s) it
# can still find, or nothing when the source unit itself is gone.
# Prints one unit name per line; never fails the caller (rc 0 even
# when nothing is found). Search roots are overridable for tests via
# ABOX_SYSTEMD_UNIT_DIRS (space-separated).
managed_service_also_sources() {
    local srv="$1" root='' f='' base=''
    local -a roots=()
    if [[ -n "${ABOX_SYSTEMD_UNIT_DIRS:-}" ]]; then
        read -r -a roots <<< "$ABOX_SYSTEMD_UNIT_DIRS"
    else
        roots=(/etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system)
    fi
    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' f; do
            awk -v srv="$srv" '
                /^\[Install\]/ { in_install = 1; next }
                /^\[/ { in_install = 0 }
                in_install && /^[[:space:]]*Also=/ {
                    sub(/^[[:space:]]*Also=/, "")
                    n = split($0, toks, /[[:space:]]+/)
                    for (i = 1; i <= n; i++) {
                        if (toks[i] == srv || toks[i] == srv ".service") { print FILENAME; exit }
                    }
                }' "$f"
        done < <(find "$root" -type f \( -name '*.service' -o -path '*.service.d/*.conf' \) -print0 2>/dev/null)
    done | while IFS= read -r f; do
        if [[ "$f" == *.service.d/* ]]; then
            base=$(basename "$(dirname "$f")")
            base=${base%.d}
        else
            base=$(basename "$f")
        fi
        printf '%s\n' "${base%.service}"
    done | sort -u
    return 0
}

managed_service_state_value() {
    local srv="$1" active=0 enabled_state enabled=0 output active_state rc
    if [[ "${INIT_SYS:-}" == systemd ]] && systemd_available; then
        output=$(systemctl show -p ActiveState --value "$srv" 2>/dev/null) || return 1
        active_state="$output"
        case "$active_state" in
            active) active=1 ;;
            inactive|failed|dead|exited) active=0 ;;
            # R26-H-NF-05: transitional states are not "active": a
            # crash-looping unit sits in activating for long stretches,
            # and returning 1 here kills every auto-backup (and the
            # redeploy it gates). Map them to 0; a genuinely unknown
            # state still fails closed below.
            # R27-F13-03: reloading is not a stopped state: the unit is
            # still running while it reloads, so it maps to 1. Only
            # activating (not yet up) and deactivating (on its way down)
            # map to 0.
            reloading) active=1 ;;
            activating|deactivating) active=0 ;;
            *) return 1 ;;
        esac
        enabled_state=$(service_enabled_state_value "$srv") || return 1
        case "$enabled_state" in
            enabled) enabled=enabled ;;
            indirect) enabled=indirect ;;
            enabled-runtime) enabled=enabled-runtime ;;
            disabled) enabled=disabled ;;
            *) return 1 ;;
        esac
    elif [[ "${INIT_SYS:-}" == openrc ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$srv" status >/dev/null 2>&1
        rc=$?
        case "$rc" in
            0) active=1 ;;
            3|16|32) active=0 ;;
            *) return 1 ;;
        esac
        enabled_state=$(service_enabled_state_value "$srv") || return 1
        case "$enabled_state" in
            1) enabled=enabled ;;
            0) enabled=disabled ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
    printf '%s|%s|%s\n' "$srv" "$active" "$enabled"
}

capture_managed_service_state() {
    local out="$1" srv
    : > "$out" || return 1
    for srv in xray sing-box hysteria xray-latest; do
        abox_owns_service "$srv" || continue
        managed_service_state_value "$srv" >> "$out" || return 1
    done
    # SYD-B2 E13/E14: the strict restore gate requires (mode & 077) == 0.
    # Without this chmod the file inherits the menu's umask (typically
    # 022 -> 644) and tar preserves 644, so every restore fails at the
    # service-state gate and stopped services are never restarted.
    chmod 600 "$out" || return 1
}


append_managed_service_state_entry() {
    local source="$1" dest="$2" srv="$3" line
    [[ -r "$source" && -f "$source" && ! -L "$source" ]] || return 1
    line=$(awk -F'|' -v target="$srv" '$1 == target {print; found=1; exit} END {if (!found) exit 1}' "$source") || return 1
    printf '%s\n' "$line" >> "$dest"
}

_apply_managed_service_state_file() {
    local state_file="${1:-}" expected_file="${2:-}" changed_file="${3:-}" observed_file="${4:-}" before_observed_file="${5:-}" line srv active enabled extra seen_srvs="|"
    [[ -r "$state_file" && -f "$state_file" && ! -L "$state_file" ]] || return 1
    [[ "$(stat -c %u:%g "$state_file" 2>/dev/null || true)" == 0:0 ]] || return 1
    local mode
    mode=$(stat -c %a "$state_file" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || return 1
    if [[ -n "$expected_file" ]]; then
        validate_services_state_file "$expected_file" || return 1
        [[ "$(stat -c %u:%g "$expected_file" 2>/dev/null || true)" == 0:0 ]] || return 1
        mode=$(stat -c %a "$expected_file" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#077) == 0 )) || return 1
        [[ "$(awk -F'|' '{print $1}' "$state_file" | sort)" == "$(awk -F'|' '{print $1}' "$expected_file" | sort)" ]] || return 1
    fi

    # Preflight the complete expected post-state before changing any service.
    # A mismatch means another actor changed shared service state; never overwrite
    # that state with an A-Box rollback snapshot.
    if [[ -n "$expected_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r srv _ _ extra <<< "$line"
            [[ -z "${extra:-}" ]] || return 1
            local expected_line current_state
            expected_line="$line"
            current_state=$(managed_service_state_value "$srv") || return 2
            [[ "$current_state" == "$expected_line" ]] || return 2
        done < "$expected_file"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r srv active enabled extra <<< "$line"
        [[ -z "${extra:-}" ]] || return 1
        case "$srv" in
            xray|sing-box|hysteria|xray-latest) ;;
            *) return 1 ;;
        esac
        [[ "$active" =~ ^[01]$ && "$enabled" =~ ^(enabled|enabled-runtime|indirect|disabled)$ ]] || return 1
        case "$seen_srvs" in *"|$srv|"*) return 1 ;; esac
        seen_srvs+="$srv|"
        abox_owns_service "$srv" || return 1

        # R1-13-F5/R3C13-03: observe the applier's own before-state
        # for every service (not only when a preflight file is given), so
        # change tracking below does not depend on the preflight path.
        local current_state_before
        current_state_before=$(managed_service_state_value "$srv") || return 1
        if [[ -n "$expected_file" ]]; then
            local expected_state_before
            expected_state_before=$(awk -F'|' -v target="$srv" '$1 == target {print; found=1; exit} END {if (!found) exit 1}' "$expected_file") || return 2
            [[ "$current_state_before" == "$expected_state_before" ]] || return 2
        fi

        # 07a-M1: record the applier's own before-state (observed just
        # before this service is changed) so rollback restores the
        # state the applier actually saw, not the wrapper's
        # pre-capture, which may already be stale. A failed journal
        # append returns the distinct status 3, like the observed /
        # changed appends below.
        if [[ -n "$before_observed_file" ]]; then
            printf '%s\n' "$current_state_before" >> "$before_observed_file" || return 3
        fi

        # Apply with a failure flag instead of immediate returns, so a
        # partial mutation (e.g. enable ok, start failed) is still
        # recorded below as an applier change to roll back.
        local apply_rc=0 post_state
        if [[ "${INIT_SYS:-}" == systemd ]]; then
            systemctl daemon-reload >/dev/null 2>&1 || apply_rc=1
            if (( apply_rc == 0 )); then
                case "$enabled" in
                    enabled) systemctl enable "$srv" >/dev/null 2>&1 || apply_rc=1 ;;
                    enabled-runtime) systemctl disable "$srv" >/dev/null 2>&1 || apply_rc=1; if (( apply_rc == 0 )); then systemctl enable --runtime "$srv" >/dev/null 2>&1 || apply_rc=1; fi; if (( apply_rc == 0 )); then [[ "$(systemctl is-enabled "$srv" 2>/dev/null)" == enabled-runtime ]] || apply_rc=1; fi ;;
                    disabled) systemctl disable "$srv" >/dev/null 2>&1 || apply_rc=1; if (( apply_rc == 0 )); then systemctl disable --runtime "$srv" >/dev/null 2>&1 || apply_rc=1; fi; if (( apply_rc == 0 )); then [[ "$(systemctl is-enabled "$srv" 2>/dev/null)" == disabled ]] || apply_rc=1; fi ;;
                    indirect)
                        # R9C13-03: snapshot state is indirect (enabled only
                        # via another unit's Also=/wants link). Never create
                        # a direct enablement: drop one only if it appeared
                        # after the snapshot; otherwise leave enablement
                        # alone (post-state check below accepts indirect or
                        # disabled, i.e. "not directly enabled").
                        # R50-M2: a runtime-only direct enablement
                        # (enabled-runtime) is direct enablement too:
                        # drop it with disable --runtime, or the
                        # post-state check below (indirect or disabled)
                        # fails the restore.
                        if [[ "$(systemctl show -p UnitFileState --value "$srv" 2>/dev/null)" == enabled ]]; then
                            systemctl disable "$srv" >/dev/null 2>&1 || apply_rc=1
                        elif [[ "$(systemctl show -p UnitFileState --value "$srv" 2>/dev/null)" == enabled-runtime ]]; then
                            systemctl disable --runtime "$srv" >/dev/null 2>&1 || apply_rc=1
                        fi ;;
                esac
            fi
            if (( apply_rc == 0 )); then
                if [[ "$active" == 1 ]]; then
                    systemctl start "$srv" >/dev/null 2>&1 || systemctl restart "$srv" >/dev/null 2>&1 || apply_rc=1
                else
                    systemctl stop "$srv" >/dev/null 2>&1 || apply_rc=1
                fi
            fi
        elif [[ "${INIT_SYS:-}" == openrc ]]; then
            if (( apply_rc == 0 )); then
                if [[ "$enabled" == enabled ]]; then
                    rc-update add "$srv" default >/dev/null 2>&1 || apply_rc=1
                elif rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${srv}([[:space:]]|$)"; then
                    rc-update del "$srv" default >/dev/null 2>&1 || apply_rc=1
                fi
            fi
            if (( apply_rc == 0 )); then
                if [[ "$active" == 1 ]]; then
                    rc-service "$srv" start >/dev/null 2>&1 9>&- 10>&- || rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || apply_rc=1
                else
                    rc-service "$srv" stop >/dev/null 2>&1 || apply_rc=1
                fi
            fi
        else
            apply_rc=1
        fi
        # Record only an observable change by this applier: compare the
        # post-attempt state with the applier's own before-state. A
        # preflight failure (return 2 above) never reaches here, so a
        # service the applier never touched is never recorded.
        post_state=$(managed_service_state_value "$srv" 2>/dev/null) || post_state=''
        # R12-06/R12-07: record the applier's own observation BEFORE
        # the apply_rc return and the target-state verification below,
        # so a failed command can still leave a usable post-state for
        # rollback. A failed post-state query means "possibly
        # changed", never "unchanged": record the service as changed.
        # A failed journal append returns the distinct status 3, so
        # the caller can tell a journal failure from an ordinary
        # apply failure and must not take the empty-journal path.
        if [[ -n "$observed_file" && -n "$post_state" ]]; then
            printf '%s\n' "$post_state" >> "$observed_file" || return 3
        fi
        if [[ -n "$changed_file" ]]; then
            if [[ -n "$post_state" ]]; then
                if [[ "$post_state" != "$current_state_before" ]]; then
                    printf '%s\n' "$srv" >> "$changed_file" || return 3
                fi
            else
                printf '%s\n' "$srv" >> "$changed_file" || return 3
            fi
        fi
        (( apply_rc == 0 )) || return 1
        local restored_srv restored_active restored_enabled restored_extra
        IFS='|' read -r restored_srv restored_active restored_enabled restored_extra <<< "$post_state"
        if [[ "$enabled" == indirect ]]; then
            # R9C13-03: indirect restores to "not directly enabled". The
            # Also= source link is outside A-Box control: if it survives,
            # post-state is indirect; if it is gone, disabled. Both are
            # accepted; a direct enablement is never accepted.
            [[ -z "${restored_extra:-}" && "$restored_srv" == "$srv" && "$restored_active" == "$active" && ( "$restored_enabled" == indirect || "$restored_enabled" == disabled ) ]] || return 1
            # 2mb residual: indirect restored as disabled means the Also=
            # source link is gone (boot policy silently differs from the
            # snapshot). Never re-enable directly and never recreate the
            # foreign link — warn loudly, naming the candidate Also=
            # source(s) still discoverable, so the operator can act.
            if [[ "$restored_enabled" == disabled ]]; then
                local _also_sources=''
                _also_sources=$(managed_service_also_sources "$srv" 2>/dev/null | tr '\n' ' ' || true)
                _also_sources=${_also_sources% }
                msg "${YELLOW}[!] ${srv}: snapshot was indirect but restore left it disabled — the Also= source link is gone, so ${srv} will no longer start at boot via that link. Also= source candidate(s): ${_also_sources:-unknown}. Re-enable the source unit, or enable ${srv} directly, if boot-start is still wanted.${NC}" || true
            fi
        else
            [[ -z "${restored_extra:-}" && "$restored_srv" == "$srv" && "$restored_active" == "$active" && "$restored_enabled" == "$enabled" ]] || return 1
        fi
    done < "$state_file"
}

restore_managed_service_state() {
    local state_file="${1:-}" expected_file="${2:-}" tx_dir before_file post_file changed_file observed_file before_observed_file line srv before after rc=0
    [[ -r "$state_file" && -f "$state_file" && ! -L "$state_file" ]] || return 1
    validate_services_state_file "$state_file" || return 1
    tx_dir=$(mktemp -d /run/A-Box-service-restore.XXXXXX) || return 1
    chmod 700 "$tx_dir" || { rm -rf -- "$tx_dir"; return 1; }
    before_file="$tx_dir/before.state"; post_file="$tx_dir/post.state"
    : > "$before_file" || { rm -rf -- "$tx_dir"; return 1; }
    while IFS='|' read -r srv _active _enabled extra || [[ -n "$srv" ]]; do
        [[ -n "$srv" ]] || continue
        [[ -z "${extra:-}" ]] || { rm -rf -- "$tx_dir"; return 1; }
        before=$(managed_service_state_value "$srv" 2>/dev/null) || { rm -rf -- "$tx_dir"; return 1; }
        printf '%s\n' "$before" >> "$before_file" || { rm -rf -- "$tx_dir"; return 1; }
    done < "$state_file"
    chmod 600 "$before_file" || { rm -rf -- "$tx_dir"; return 1; }
    changed_file="$tx_dir/changed.services"
    : > "$changed_file" || { rm -rf -- "$tx_dir"; return 1; }
    chmod 600 "$changed_file" || { rm -rf -- "$tx_dir"; return 1; }
    observed_file="$tx_dir/observed.state"
    : > "$observed_file" || { rm -rf -- "$tx_dir"; return 1; }
    chmod 600 "$observed_file" || { rm -rf -- "$tx_dir"; return 1; }
    before_observed_file="$tx_dir/before-observed.state"
    : > "$before_observed_file" || { rm -rf -- "$tx_dir"; return 1; }
    chmod 600 "$before_observed_file" || { rm -rf -- "$tx_dir"; return 1; }

    if _apply_managed_service_state_file "$state_file" "$expected_file" "$changed_file" "$observed_file" "$before_observed_file"; then
        rm -rf -- "$tx_dir" || return 1
        return 0
    else
        rc=$?
    fi

    if (( rc == 3 )); then
        # R12-06: the applier could not record its change journal
        # (changed/observed append failed), so the journal may be
        # incomplete. Never take the empty-journal shortcut below:
        # preserve the transaction for operator recovery and do not
        # attempt a rollback against an unverified journal.
        printf '%s\n' "A-Box service restore failed; service-change journal could not be recorded, recovery state preserved at $tx_dir" >&2
        return 1
    fi

    # Roll back ONLY services this restore itself changed (as recorded
    # by the applier). A service the applier never touched is never
    # rolled back, no matter what shape its live state has: F5's admin
    # enable-only and R3C13-03's admin stop both produce states that the
    # old shape matcher mistook for applier work.
    if [[ ! -s "$changed_file" ]]; then
        # The applier changed nothing (typically a preflight-only
        # conflict): there is nothing to roll back. Outside changes
        # observed here are left untouched.
        rm -rf -- "$tx_dir" || return 1
        return "$rc"
    fi

    # Capture the exact observable intermediate state for the rollback
    # preflight and for reporting outside changes; if any query fails,
    # preserve the recovery snapshot instead of guessing.
    : > "$post_file" || { printf '%s\n' "A-Box service restore failed; recovery state preserved at $tx_dir" >&2; return 1; }
    while IFS='|' read -r srv _active _enabled extra || [[ -n "$srv" ]]; do
        [[ -n "$srv" ]] || continue
        after=$(managed_service_state_value "$srv" 2>/dev/null) || { printf '%s\n' "A-Box service restore failed; state query unavailable, recovery state preserved at $tx_dir" >&2; return 1; }
        printf '%s\n' "$after" >> "$post_file" || { printf '%s\n' "A-Box service restore failed; recovery state preserved at $tx_dir" >&2; return 1; }
    done < "$state_file"
    chmod 600 "$post_file" || { printf '%s\n' "A-Box service restore failed; recovery state preserved at $tx_dir" >&2; return 1; }


    # Roll back the recorded services only, to their pre-restore
    # values; the rollback applier's own preflight (current == post)
    # guards against rolling back over a newer outside change.
    local rb_before rb_post excluded=''
    rb_before="$tx_dir/rollback-before.state"; rb_post="$tx_dir/rollback-post.state"
    : > "$rb_before" || { printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2; return 1; }
    : > "$rb_post" || { printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2; return 1; }
    while IFS='|' read -r srv _active _enabled extra || [[ -n "$srv" ]]; do
        [[ -n "$srv" ]] || continue
        local b_line p_line
        b_line=$(awk -F'|' -v target="$srv" '$1 == target {print; exit}' "$before_file") || b_line=''
        if grep -qxF "$srv" "$changed_file" 2>/dev/null; then
            # R12-07: the rollback expectation comes ONLY from the
            # applier's own observation. A later live query must never
            # be adopted as the expected post-state. A changed service
            # with no (or no unique) observation has an unknown
            # post-state: preserve the transaction, do not roll back.
            local obs_count
            obs_count=$(grep -c "^${srv}|" "$observed_file" 2>/dev/null || true)
            if [[ "$obs_count" != 1 ]]; then
                printf '%s\n' "A-Box service restore failed; no recorded post-state for changed service $srv, recovery state preserved at $tx_dir" >&2
                return 1
            fi
            p_line=$(awk -F'|' -v target="$srv" '$1 == target {print; exit}' "$observed_file") || p_line=''
            # 07a-M1: the rollback baseline is the applier's own
            # before-state, recorded just before this service was
            # changed -- not the wrapper's pre-capture in before_file,
            # which may already be stale. A changed service with no
            # (or no unique) before-state has an unknown baseline:
            # preserve the transaction, do not roll back.
            local bo_count bo_line
            bo_count=$(grep -c "^${srv}|" "$before_observed_file" 2>/dev/null || true)
            if [[ "$bo_count" != 1 ]]; then
                printf '%s\n' "A-Box service restore failed; no recorded before-state for changed service $srv, recovery state preserved at $tx_dir" >&2
                return 1
            fi
            bo_line=$(awk -F'|' -v target="$srv" '$1 == target {print; exit}' "$before_observed_file") || bo_line=''
            printf '%s\n' "$bo_line" >> "$rb_before" || { printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2; return 1; }
            printf '%s\n' "$p_line" >> "$rb_post" || { printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2; return 1; }
        else
            # Not changed by this restore: compare the live
            # re-capture against before-state only to REPORT outside
            # changes. These diagnostic values never authorise a
            # rollback.
            p_line=$(awk -F'|' -v target="$srv" '$1 == target {print; exit}' "$post_file") || p_line=''
            if [[ "$p_line" != "$b_line" ]]; then
                # Not changed by this restore but moved by an outside actor
                # during the failure: leave it and report it.
                excluded+="$srv "
            fi
        fi
    done < "$state_file"
    chmod 600 "$rb_before" "$rb_post" || { printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2; return 1; }
    if [[ -s "$rb_before" ]]; then
        if ! _apply_managed_service_state_file "$rb_before" "$rb_post"; then
            printf '%s\n' "A-Box service restore rollback incomplete or conflicted; recovery state preserved at $tx_dir" >&2
            return 1
        fi
    fi
    if [[ -n "$excluded" ]]; then
        printf '%s\n' "A-Box service restore rollback partial: services changed by an outside actor during restore were left untouched: ${excluded% }; recovery state preserved at $tx_dir" >&2
        return 1
    fi
    rm -rf -- "$tx_dir" || return 1
    return "$rc"
}

extract_abox_iptables_rules() {
    local snapshot="$1" mode="${2:-all}" include_input="${3:-0}"
    [[ "$include_input" == 0 || "$include_input" == 1 ]] || return 1
    awk -v mode="$mode" -v include_input="$include_input" '''
      /^\*/ {table=$0; input_policy=""; input_seen=0; next} /^COMMIT$/ {next}
      include_input && table=="*filter" && $1==":INPUT" {
        if (++input_seen > 1 ||
            $0 !~ /^:INPUT[ \t]+(ACCEPT|DROP)([ \t]+\[[0-9]+:[0-9]+\])?[ \t]*$/) {
          bad=1
          exit 1
        }
        input_policy=$2
        next
      }
      /^-A / {
        base=($0 ~ /--comment "?A-Box-[0-9]+(:[0-9]+)?-(tcp|udp)(:A-Box-tmp-[0-9]+-[0-9]+)?"?([ \t\r]|$)/)
        wl=($0 ~ /--comment "?A-Box-[0-9]+-(tcp|udp)-WL6?(:A-Box-tmp-[0-9]+-[0-9]+)?"?([ \t\r]|$)/)
        drop=($0 ~ /--comment "?A-Box-[0-9]+-(tcp|udp)-DROP6?(:A-Box-tmp-[0-9]+-[0-9]+)?"?([ \t\r]|$)/)
        hop=($0 ~ /--comment "?A-Box-HY2-HOP"?([ \t\r]|$)/)
        owned=(base || wl || drop || hop)
        special=(wl || drop || hop)
        if ((mode=="all" && owned) || special) {
          gsub(/:A-Box-tmp-[0-9]+-[0-9]+/, "")
          _k = table SUBSEP $0
          if (_k in seen) next
          seen[_k] = 1
          if (table!=emitted) {if (emitted!="") print "COMMIT"; print table; if (include_input && table=="*filter" && input_policy!="") print ":INPUT " input_policy " [0:0]"; emitted=table}
          print
        }
      }
      END {if (bad) exit 1; if (emitted!="") print "COMMIT"}
    ''' "$snapshot"
}

capture_abox_iptables_snapshot() {
    local out="$1" family="${2:-4}" cmd all
    [[ "$family" == 6 ]] && cmd=ip6tables-save || cmd=iptables-save
    if ! command -v "$cmd" >/dev/null 2>&1; then
        [[ "$family" == 6 ]] && ! host_has_usable_ipv6 || return 1
        : > "$out" || return 1
        return 0
    fi
    all=$(mktemp) || return 1
    if ! "$cmd" > "$all" 2>/dev/null; then
        rm -f "$all"
        if [[ "$family" == 6 ]] && ! host_has_usable_ipv6; then
            : > "$out" || return 1
            return 0
        fi
        return 1
    fi
    extract_abox_iptables_rules "$all" all > "$out" || { rm -f "$all"; return 1; }
    rm -f "$all"
}

restore_abox_iptables_snapshot() {
    local snapshot="$1" family="${2:-4}" mode="${3:-all}" cmd tmp
    [[ "$family" == 6 ]] && ! host_has_usable_ipv6 && return 0
    [[ -s "$snapshot" ]] || return 0
    [[ "$family" == 6 ]] && cmd=ip6tables-restore || cmd=iptables-restore
    tmp=$(mktemp) || return 1
    extract_abox_iptables_rules "$snapshot" "$mode" > "$tmp" || { rm -f "$tmp"; return 1; }
    if grep -q '^\*' "$tmp"; then
        command -v "$cmd" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
        "$cmd" -w --noflush < "$tmp" >/dev/null 2>&1 || "$cmd" --noflush < "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
}

backup_sidecar_safe() {
    local file="$1" uid gid mode
    [[ -f "$file" && ! -L "$file" ]] || return 1
    uid=$(stat -c %u "$file" 2>/dev/null) || return 1
    gid=$(stat -c %g "$file" 2>/dev/null) || return 1
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

write_private_sidecar() {
    local dest="$1" value="$2" dir tmp
    [[ "$dest" == /* ]] || return 1
    path_parent_chain_safe "$dest" || return 1
    dir=$(dirname "$dest")
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    [[ "$(stat -c %u:%g "$dir" 2>/dev/null || true)" == 0:0 ]] || { msg "${RED}[!] Output directory must be owned by root (root-owned output directory required; non-root home directories are not supported).${NC}" >&2; return 1; }
    if ! path_mode_has_no_group_other_write "$dir"; then
        # H-27: allow a sticky directory owned by root (e.g. /tmp,
        # mode 1777): only root can unlink or rename another user's
        # files there, so the group/other write bits cannot be used
        # to swap the sidecar out from under root. Ownership 0:0 was
        # already verified above.
        [[ "$(stat -c %a "$dir" 2>/dev/null || true)" =~ ^1[0-7]{3}$ ]] || return 1
    fi
    [[ ! -L "$dest" ]] || return 1
    # A directory dest would make mv install the tmp file INSIDE it and
    # still report success, with no credential file at the target.
    [[ ! -d "$dest" ]] || return 1
    if [[ -e "$dest" ]] && path_is_mountpoint "$dest"; then return 1; fi
    tmp=$(umask 077; mktemp "$dir/.A-Box-sidecar.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    # H-27: re-check immediately before publish: in a sticky dir
    # another user could plant a symlink at $dest after the early
    # check above.
    [[ ! -L "$dest" ]] || { rm -f -- "$tmp"; return 1; }
    # N-8 (H-27 follow-up): re-check the directory case too -- a directory
    # planted at $dest after the entry check would make mv install the
    # tmp file INSIDE it and still report success.
    [[ ! -d "$dest" ]] || { rm -f -- "$tmp"; return 1; }
    # 07a-M2: the re-check above still leaves a window before mv, so
    # publish with -T as well: a directory appearing in that window
    # must fail loudly instead of swallowing the tmp file inside it.
    mv -Tf -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

ensure_backup_auth_key() {
    local key tmp
    if [[ -e "$ABOX_BACKUP_KEY" || -L "$ABOX_BACKUP_KEY" ]]; then
        backup_sidecar_safe "$ABOX_BACKUP_KEY" || return 1
        IFS= read -r key < "$ABOX_BACKUP_KEY" || return 1
        [[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]]
        return
    fi
    ensure_abox_dir_owned "$ABOX_DIR"
    tmp=$(umask 077; mktemp "$ABOX_DIR/.backup-hmac-key.XXXXXX") || return 1
    key=$(openssl rand -hex 32 2>/dev/null) || { rm -f -- "$tmp"; return 1; }
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || { rm -f -- "$tmp"; return 1; }
    printf '%s\n' "$key" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ABOX_BACKUP_KEY" || { rm -f -- "$tmp"; return 1; }
}

backup_checksum_write() {
    local archive="$1" hash
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    hash=$(sha256sum < "$archive" 2>/dev/null | awk '{print $1}')
    [[ "$hash" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    write_private_sidecar "${archive}.sha256" "$hash  $(basename "$archive")"
}

backup_checksum_verify() {
    local archive="$1" sidecar="${2:-${1}.sha256}" expected actual extra
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    backup_sidecar_safe "$sidecar" || return 2
    read -r expected extra < "$sidecar" || return 1
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    actual=$(sha256sum < "$archive" 2>/dev/null | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]]
}

backup_hmac_sha256() {
    # $1 = hex key, $2 = file. The key travels via the environment,
    # never argv: `openssl -macopt hexkey:...` exposes it in `ps`.
    ABOX_HMAC_KEY="$1" ABOX_HMAC_FILE="$2" python3 -I - <<'PY_ABOX_HMAC'
import hashlib, hmac, os, sys
try:
    key = bytes.fromhex(os.environ["ABOX_HMAC_KEY"])
except Exception:
    sys.exit(1)
digest = hmac.new(key, digestmod=hashlib.sha256)
with open(os.environ["ABOX_HMAC_FILE"], "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY_ABOX_HMAC
}

backup_auth_write() {
    local archive="$1" key mac
    ensure_backup_auth_key || return 1
    IFS= read -r key < "$ABOX_BACKUP_KEY" || return 1
    mac=$(backup_hmac_sha256 "$key" "$archive" 2>/dev/null)
    [[ "$mac" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    write_private_sidecar "${archive}.hmac" "$mac  $(basename "$archive")"
}

backup_auth_verify() {
    local archive="$1" sidecar="${2:-${1}.hmac}" key expected actual extra
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    backup_sidecar_safe "$ABOX_BACKUP_KEY" || return 2
    backup_sidecar_safe "$sidecar" || return 2
    IFS= read -r key < "$ABOX_BACKUP_KEY" || return 1
    read -r expected extra < "$sidecar" || return 1
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ && "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    actual=$(backup_hmac_sha256 "$key" "$archive" 2>/dev/null)
    [[ "${actual,,}" == "${expected,,}" ]]
}

backup_auth_verify_with_key_file() {
    local archive="$1" sidecar="$2" key_file="$3" key expected actual extra
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    backup_sidecar_safe "$sidecar" || return 1
    backup_sidecar_safe "$key_file" || return 1
    IFS= read -r key < "$key_file" || return 1
    read -r expected extra < "$sidecar" || return 1
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ && "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    actual=$(backup_hmac_sha256 "$key" "$archive" 2>/dev/null)
    [[ "${actual,,}" == "${expected,,}" ]]
}

backup_key_fingerprint() {
    local key_file="$1" key
    backup_sidecar_safe "$key_file" || return 1
    IFS= read -r key < "$key_file" || return 1
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s' "${key,,}" | sha256sum | awk '{print $1}'
}

install_recovery_backup_key() {
    local key_file="$1" tmp key
    [[ ! -e "$ABOX_BACKUP_KEY" && ! -L "$ABOX_BACKUP_KEY" ]] || return 1
    backup_sidecar_safe "$key_file" || return 1
    IFS= read -r key < "$key_file" || return 1
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    ensure_abox_dir_owned "$ABOX_DIR"
    tmp=$(umask 077; mktemp "$ABOX_DIR/.backup-hmac-import.XXXXXX") || return 1
    printf '%s\n' "$key" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ABOX_BACKUP_KEY" || { rm -f -- "$tmp"; return 1; }
}

prepare_backup_auth_for_manual_restore() {
    local archive="$1" rc fingerprint answer
    # A-05a: Prefer the separated key in /root/A-Box-backup-keys/; fall back to
    # the archive-adjacent sidecar only if the separated key is absent.
    # (Sidecar-first defeated the separation trust model.)
    local hmac="${archive}.hmac" recovery="/root/A-Box-backup-keys/$(basename "$archive").key"
    # A-05a: Only fall back to sidecar if separated key is entirely absent
    # (not merely unreadable). A present-but-broken separated key must fail closed.
    if [[ ! -e "$recovery" && ! -L "$recovery" ]]; then
        recovery="${archive}.key"
    fi
    if backup_auth_verify "$archive" "$hmac"; then return 0; else rc=$?; fi
    # Never replace an existing trust key automatically. A mismatch may mean
    # the user selected a foreign or malicious backup.
    if [[ -e "$ABOX_BACKUP_KEY" || -L "$ABOX_BACKUP_KEY" ]]; then
        return "$rc"
    fi
    backup_auth_verify_with_key_file "$archive" "$hmac" "$recovery" || return 1
    fingerprint=$(backup_key_fingerprint "$recovery") || return 1
    if [[ -n "${ABOX_BACKUP_KEY_SHA256_ALLOWLIST:-}" ]]; then
        sha256_in_allowlist "$fingerprint" "$ABOX_BACKUP_KEY_SHA256_ALLOWLIST" || return 1
    else
        [[ -t 0 ]] || return 1
        msg "${YELLOW}[!] $(tprintf prepare_backup_auth_for_manual_restore_key_needed "${fingerprint}")${NC}"
        msg "${YELLOW}[!] $(tr_msg prepare_backup_auth_for_manual_restore_key_warning)${NC}"
        # R14-F13-03: a failed read must refuse, even when it already
        # stored the phrase (a phrase with no trailing newline, then
        # EOF/Ctrl-D): only a successful read plus the exact phrase
        # counts as confirmation (mirrors confirm_yes_no, R8-F3-1).
        read -r -p "$(tr_msg prepare_backup_auth_for_manual_restore_import_prompt)" answer || return 130
        [[ "$answer" == 'IMPORT-RECOVERY-KEY' ]] || return 130
    fi
    install_recovery_backup_key "$recovery" || return 1
    backup_auth_verify "$archive" "$hmac"
}


export_backup_recovery_key() {
    local dest="${1:-}" key fingerprint
    [[ $EUID -eq 0 ]] || die "$(tr_msg export_backup_recovery_key_need_root)"
    [[ -n "$dest" ]] || die "$(tr_msg export_backup_recovery_key_usage)"
    [[ "$dest" == /* ]] || die "$(tr_msg export_backup_recovery_key_dest_not_absolute)"
    [[ ! -e "$dest" && ! -L "$dest" ]] || die "$(tprintf export_backup_recovery_key_dest_exists "$dest")"
    ensure_backup_auth_key || die "$(tr_msg export_backup_recovery_key_auth_key_fail)"
    IFS= read -r key < "$ABOX_BACKUP_KEY" || die "$(tr_msg export_backup_recovery_key_read_fail)"
    [[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || die "$(tr_msg export_backup_recovery_key_format_invalid)"
    write_private_sidecar "$dest" "$key" || die "$(tr_msg export_backup_recovery_key_export_fail)"
    fingerprint=$(backup_key_fingerprint "$dest") || die "$(tr_msg export_backup_recovery_key_fingerprint_fail)"
    msg "${GREEN}[*] Recovery key exported:${NC} $dest"
    msg "${GREEN}[*] Key fingerprint (SHA256):${NC} $fingerprint"
    msg "${YELLOW}[!] Store this key separately from backup archives. Anyone holding both can authenticate modified archives.${NC}"
}

validate_legacy_backup_archive() {
    local archive="$1"
    [[ -s "$archive" ]] || return 1
    python3 -I - "$archive" <<'PY_LEGACY_VALIDATE'
import posixpath, stat, sys, tarfile
import resource
# R51-M1: bound this process's address space. tarfile reads PAX/GNU
# longname extension headers whole into memory before yielding the
# next member, so the member/size/total caps cannot bound them (a
# 100 MB header peaked at 612 MB RSS in trial; the extractor peaked
# at 912 MB). A 512 MiB cap fails closed (MemoryError -> non-zero
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
fn=sys.argv[1]; max_members=10000; max_file=512*1024*1024; max_total=1024*1024*1024
allowed_prefixes=(
 'root/etc/ddr','root/usr/local/bin/sb','root/usr/local/bin/xray','root/usr/local/bin/sing-box','root/usr/local/bin/hysteria',
 'root/usr/local/etc/xray','root/usr/local/share/xray','root/etc/sing-box','root/etc/hysteria','root/etc/logrotate.d/A-Box',
 'root/etc/fail2ban/filter.d/A-Box.conf','root/etc/fail2ban/jail.d/A-Box.local','root/etc/systemd/system/xray.service',
 'root/etc/systemd/system/sing-box.service','root/etc/systemd/system/hysteria.service','root/etc/init.d/xray','root/etc/init.d/sing-box',
 'root/etc/init.d/hysteria','meta/metadata.txt','meta/cron.abox.txt','meta/iptables.snapshot','meta/ip6tables.snapshot')
def allowed(n):
 if n in {'root','root/etc','root/usr','root/usr/local','root/usr/local/bin','root/usr/local/etc','root/usr/local/share','root/etc/logrotate.d','root/etc/fail2ban','root/etc/fail2ban/filter.d','root/etc/fail2ban/jail.d','root/etc/systemd','root/etc/systemd/system','root/etc/init.d','root/etc/ddr','meta'}: return True
 prefix='root/etc/ddr/'
 if n.startswith(prefix):
  rel=n[len(prefix):]
  if '/' in rel or not rel: return False
  exact={'.env','.firewall-native.rules','.lang','.desired_state','.traffic-block-state','.A-Box-owner','.public_ip.cache','.backup-hmac.key','.runtime.lock','.managed-core-files.tsv','.ip-pref','.dns-state','.timezone-state','.fast-mode','.mirror-prefer','.extra-uuids','A-Box.sh','socket_probe.sh','geo_update.sh','traffic_monitor.sh','firewall_restore.sh','iptables.v4','iptables.v6','A-Box-sni-full.tsv','A-Box-sni-mini.tsv'}
  return rel in exact or rel.startswith('.deps.v')
 return any(n==x or n.startswith(x+'/') for x in allowed_prefixes if x!='root/etc/ddr')
try: tf=tarfile.open(fn,'r:gz')
except Exception: raise SystemExit(1)
seen=set(); total=0; _count=0
for m in tf:
 _count+=1
 if _count>max_members: raise SystemExit(1)
 raw=m.name
 while raw.startswith('./'): raw=raw[2:]
 n=posixpath.normpath(raw)
 if raw in ('','.'): continue
 if n in ('','.'): raise SystemExit(1)
 if raw.startswith('/') or n=='..' or n.startswith('../') or not allowed(n): raise SystemExit(1)
 if n in seen and not m.isdir(): raise SystemExit(1)
 seen.add(n)
 if m.issym() or m.islnk() or m.ischr() or m.isblk() or m.isfifo() or m.isdev(): raise SystemExit(1)
 if not (m.isfile() or m.isdir()) or m.uid!=0 or m.gid!=0: raise SystemExit(1)
 mode=m.mode & 0o7777
 # R-01: Allow sticky (0o1000) for acme dir 1770; reject only setuid/setgid (0o6000).
 if mode & 0o6000 or mode & 0o022: raise SystemExit(1)
 if m.isfile():
  if m.size<0 or m.size>max_file: raise SystemExit(1)
  total+=m.size
  if total>max_total: raise SystemExit(1)
if 'root/etc/ddr' not in seen or 'meta/metadata.txt' not in seen: raise SystemExit(1)
if 'meta/manifest.version' in seen: raise SystemExit(1)
PY_LEGACY_VALIDATE
}

convert_legacy_backup_archive() {
    local selected="$1" out_dir="${2:-$(dirname -- "$1")}" work root out answer unit srv path
    # H-27: absolutize out_dir (callers may pass a relative OUTPUT_DIR,
    # and path_parent_chain_safe below rejects relative paths outright).
    # realpath -m never requires the path to exist; on failure keep the
    # original value (no regression: the later checks fail as before).
    # N-2 (H-27 follow-up): reject a symlinked raw input BEFORE realpath
    # resolves it -- otherwise a symlink to a real directory (or a dangling
    # symlink, which realpath -m happily resolves to a path that is then
    # created) would pass the ! -L gate below, which only ever sees the
    # resolved target. A symlink input is refused outright.
    [[ ! -L "$out_dir" ]] || die 'Legacy conversion output directory must not be a symbolic link.'
    # G2: BusyBox realpath has no -m/-- and still prints the resolved
    # path to stdout while failing (rc=1); the old $(realpath ... ||
    # printf) shape then concatenated the partial output with the
    # fallback, doubling the path with an embedded newline. Only use
    # the realpath output when it succeeds; on failure keep the
    # original value (the partial output is discarded by the overwrite).
    out_dir=$(realpath -m -- "$out_dir" 2>/dev/null) || out_dir="$out_dir"
    [[ -f "$selected" && ! -L "$selected" ]] || die 'Legacy backup path is invalid.'
    # R6C14-01: private root-only copy BEFORE any validation; every
    # later read uses the copy, so a swap of $selected afterwards
    # cannot smuggle unvalidated content into the conversion.
    work=$(mktemp -d /tmp/A-Box-legacy-import.XXXXXX) || die 'Legacy conversion temp directory failed.'
    chmod 700 "$work"
    local _c_input="$work/.legacy-input.tar.gz"
    python3 -I - "$selected" "$_c_input" <<'PY_LEGACY_COPY' || { rm -rf "$work"; die 'Legacy backup copy failed.'; }
import os, stat, sys
src, dst = sys.argv[1], sys.argv[2]
# J03 (07b-01): cap the private copy BEFORE it can fill /tmp. fstat the
# already-open source: a sparse (or oversized) input is refused without
# reading a byte; the running total is capped too, so growth mid-copy
# (swap/append after open) aborts instead of writing unboundedly.
# Default 2 GiB: validate_legacy_backup_archive caps the EXTRACTED total
# at 1 GiB, and a gzip of 1 GiB of incompressible data is ~1 GiB plus
# small overhead, so 2x leaves generous headroom. ABOX_LEGACY_COPY_MAX_BYTES
# overrides it (operator tuning for small /tmp); a non-numeric or
# non-positive value falls back to the default (fail-closed, no breakage).
try:
    max_copy = int(os.environ.get("ABOX_LEGACY_COPY_MAX_BYTES", "") or "2147483648")
    if max_copy <= 0:
        raise ValueError
except ValueError:
    max_copy = 2147483648
# O_NOFOLLOW on both ends: a symlink at open time fails, and a swap
# after open cannot redirect an already-open fd.
sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
try:
    _st = os.fstat(sfd)
    if not stat.S_ISREG(_st.st_mode) or _st.st_size > max_copy:
        raise SystemExit(1)
    dfd = os.open(dst, os.O_WRONLY | os.O_TRUNC | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        total = 0
        while True:
            chunk = os.read(sfd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > max_copy:
                raise SystemExit(1)
            view = memoryview(chunk)
            while view:
                view = view[os.write(dfd, view):]
    finally:
        os.close(dfd)
finally:
    os.close(sfd)
PY_LEGACY_COPY
    if [[ -f "${selected}.sha256" && ! -L "${selected}.sha256" ]]; then
        backup_checksum_verify "$_c_input" "${selected}.sha256" || { rm -rf "$work"; die 'Legacy backup SHA256 verification failed.'; }
    else
        [[ -t 0 ]] || { rm -rf "$work"; die "$(tr_msg legacy_backup_no_checksum_noninteractive)"; }
        confirm_yes_no 'Legacy backup has no trusted checksum. Import anyway? [Y/N]: ' || { rm -rf "$work"; return 130; }
    fi
    validate_legacy_backup_archive "$_c_input" || { rm -rf "$work"; die 'Legacy backup archive safety validation failed.'; }
    python3 -I - "$_c_input" "$work" <<'PY_LEGACY_EXTRACT' || { rm -rf "$work"; die 'Legacy backup extraction failed.'; }
import os, pathlib, tarfile, sys
import resource
# R51-M1: bound this process's address space. tarfile reads PAX/GNU
# longname extension headers whole into memory before yielding the
# next member, so the member/size/total caps cannot bound them (a
# 100 MB header peaked at 612 MB RSS in trial; the extractor peaked
# at 912 MB). A 512 MiB cap fails closed (MemoryError -> non-zero
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
src,dst=sys.argv[1:]; base=pathlib.Path(dst).resolve()
max_members=10000; max_file=512*1024*1024; max_total=1024*1024*1024
_count=0; total=0
with tarfile.open(src,'r:gz') as tf:
 for m in tf:
  _count+=1
  if _count>max_members: raise SystemExit(1)
  name=m.name
  while name.startswith('./'): name=name[2:]
  if not name or name=='.': continue
  target=(base/name).resolve()
  if target == base or base not in target.parents: raise SystemExit(1)
  if m.isdir(): target.mkdir(parents=True,exist_ok=True); os.chmod(target,m.mode & 0o777)
  elif m.isfile():
   if m.size<0 or m.size>max_file: raise SystemExit(1)
   total+=m.size
   if total>max_total: raise SystemExit(1)
   target.parent.mkdir(parents=True,exist_ok=True)
   f=tf.extractfile(m)
   if f is None: raise SystemExit(1)
   with open(target,'wb') as out:
    while True:
     chunk=f.read(1024*1024)
     if not chunk: break
     out.write(chunk)
   os.chmod(target,m.mode & 0o777)
  else: raise SystemExit(1)
PY_LEGACY_EXTRACT
    root="$work/root"
    rm -rf -- "$root$ABOX_DIR/backups" "$root$ABOX_DIR/diagnostics" "$root$ABOX_DIR/preflight"
    rm -f -- "$root$ABOX_DIR/A-Box.sh" "$root$ABOX_DIR/.backup-hmac.key" "$root$ABOX_DIR/.runtime.lock" \
        "$root$ABOX_DIR/socket_probe.sh" "$root$ABOX_DIR/geo_update.sh" "$root$ABOX_DIR/traffic_monitor.sh" "$root$ABOX_DIR/firewall_restore.sh" \
        "$root$ABOX_DIR/iptables.v4" "$root$ABOX_DIR/iptables.v6" "$root$ABOX_DIR/.managed-core-files.tsv" "$root$ABOX_DIR/.public_ip.cache"
    find "$root$ABOX_DIR" -maxdepth 1 -type f -name '.deps.v*' -delete 2>/dev/null || true
    install -d -m 700 "$root$ABOX_DIR" "$work/meta" || { rm -rf "$work"; die 'Legacy conversion directory normalization failed.'; }
    printf '%s\n' 'A-Box managed directory v1' > "$root$ABOX_DIR/.A-Box-owner"
    chmod 600 "$root$ABOX_DIR/.A-Box-owner"
    # A-04 fix: Never trust executable binaries, OpenRC scripts, or arbitrary systemd directives
    # inside an unauthenticated legacy archive. Strip all binaries/units/auxiliary executables;
    # only import validated state/config/certs, and require binaries/units to be re-deployed cleanly.
    rm -rf -- "$root/usr/local/bin" "$root/etc/systemd" "$root/etc/init.d" "$root/etc/conf.d" \
        "$root/etc/fail2ban" "$root/etc/logrotate.d" "$root/etc/sysctl.d" \
        "$root/etc/security" "$root/etc/modules-load.d"
    if [[ -f "$root$ABOX_DIR/.env" ]]; then
        chown root:root "$root$ABOX_DIR/.env" && chmod 600 "$root$ABOX_DIR/.env"
        load_abox_env "$root$ABOX_DIR/.env" || { rm -rf "$work"; die 'Legacy .env failed strict semantic validation.'; }
    else
        rm -rf "$work"; die 'Legacy backup is missing /etc/ddr/.env.'
    fi
    local _legacy_cfg_dir
    for _legacy_cfg_dir in "$root/usr/local/etc/xray" "$root/etc/sing-box" "$root/etc/hysteria"; do
        if [[ -d "$_legacy_cfg_dir" && ! -L "$_legacy_cfg_dir" ]]; then
            find "$_legacy_cfg_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
            find "$_legacy_cfg_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
        fi
    done
    printf 'iptables\n' > "$work/meta/firewall.backend"
    : > "$work/meta/services.state" || {
        rm -rf -- "$work"
        die 'Legacy services.state initialization failed.'
    }
    chmod 600 "$work/meta/services.state" || {
        rm -rf -- "$work"
        die 'Legacy services.state permission setup failed.'
    }
    : > "$work/meta/managed-paths.txt"
    [[ -f "$work/meta/cron.abox.txt" ]] || : > "$work/meta/cron.abox.txt"
    validate_abox_cron_file "$work/meta/cron.abox.txt" || { rm -rf "$work"; die 'Legacy cron block is not compatible with the strict importer.'; }
    [[ -f "$work/meta/iptables.snapshot" ]] || : > "$work/meta/iptables.snapshot"
    [[ -f "$work/meta/ip6tables.snapshot" ]] || : > "$work/meta/ip6tables.snapshot"
    printf 'iptables\n' > "$work/meta/firewall.backend"
    { managed_auxiliary_paths; printf '%s\n' \
        /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /etc/systemd/system/xray.service /etc/init.d/xray /etc/conf.d/xray \
        /usr/local/bin/sing-box /etc/sing-box /etc/systemd/system/sing-box.service /etc/init.d/sing-box /etc/conf.d/sing-box \
        /usr/local/bin/hysteria /etc/hysteria /etc/systemd/system/hysteria.service /etc/init.d/hysteria /etc/conf.d/hysteria; } | \
        while IFS= read -r path; do [[ -e "$root$path" ]] && printf '%s\n' "$path"; done | awk 'NF && !seen[$0]++' > "$work/meta/managed-paths.txt"
    local legacy_aux_paths=''
    legacy_aux_paths=$(managed_auxiliary_paths) || { rm -rf "$work"; die 'Legacy auxiliary path enumeration failed.'; }
    while IFS= read -r path; do
        [[ -e "$root$path" ]] || continue
        auxiliary_content_is_abox_managed "$root$path" "$path" || { rm -rf "$work"; die "Legacy auxiliary path fingerprint rejected: $path"; }
        if ! grep -Fxq '# Managed by A-Box' "$root$path" 2>/dev/null; then
            if head -n 1 "$root$path" | grep -q '^#!'; then sed -i '1a# Managed by A-Box' "$root$path"; else sed -i '1i# Managed by A-Box' "$root$path"; fi
        fi
    done <<< "$legacy_aux_paths"
    printf '%s\n' 'A-Box backup manifest v3' > "$work/meta/manifest.version"
    printf '\nConverted by %s from legacy archive: %s\n' "$ABOX_BUILD" "$(basename "$selected")" >> "$work/meta/metadata.txt"
    # H-21 (Carbon R3): migrate a legacy .shortcut BEFORE the manifest
    # is created, so the manifest hashes the migrated bytes and the
    # converted backup validates downstream instead of deadlocking.
    shortcut_migrate_legacy_file "$root$ABOX_DIR/.shortcut" || true
    create_backup_manifest "$work" "$work/meta/manifest.sha256" || { rm -rf "$work"; die 'Converted manifest creation failed.'; }
    if [[ -e "$out_dir" || -L "$out_dir" ]]; then
        [[ -d "$out_dir" && ! -L "$out_dir" ]] || { rm -rf "$work"; die 'Legacy conversion output directory is not a safe directory.'; }
    else
        install -d -m 700 "$out_dir" || { rm -rf "$work"; die 'Legacy conversion output directory failed.'; }
    fi
    # R1-14-F02: out_dir itself is not enough; its ancestors must not
    # be links either (a swapped ancestor would redirect the output).
    path_parent_chain_safe "$out_dir" || { rm -rf "$work"; die 'Legacy conversion output directory is not a safe directory.'; }
    out="$out_dir/$(basename "${selected%.tar.gz}")-v3-imported.tar.gz"
    [[ ! -e "$out" && ! -L "$out" ]] || { rm -rf "$work"; die "Converted backup already exists: $out"; }
    # R1-14-F02 + R2C14-02: never tar directly to $out (a swap between
    # the existence check and tar would follow the link), and never
    # let $out appear before its sidecars. Build in a private 600 temp
    # file under umask 077, validate it, write both sidecars for the
    # FINAL name, then publish the archive last via a hardlink (ln
    # fails loudly if $out appeared in any form and never follows one).
    local _c_tmp _c_hash _c_key _c_mac
    _c_tmp=$(umask 077; mktemp "$out_dir/.A-Box-convert.XXXXXX") || { rm -rf "$work"; die 'Converted backup temp file failed.'; }
    ( umask 077; tar -C "$work" -czf "$_c_tmp" root meta ) || { rm -rf "$work"; rm -f "$_c_tmp"; die 'Converted backup archive creation failed.'; }
    chmod 600 "$_c_tmp"
    validate_backup_archive "$_c_tmp" || { rm -rf "$work"; rm -f "$_c_tmp"; die 'Converted backup failed v3 structure validation.'; }
    _c_hash=$(sha256sum < "$_c_tmp" 2>/dev/null | awk '{print $1}')
    [[ "$_c_hash" =~ ^[A-Fa-f0-9]{64}$ ]] || { rm -rf "$work"; rm -f "$_c_tmp"; die 'Converted backup authentication failed.'; }
    write_private_sidecar "${out}.sha256" "$_c_hash  $(basename "$out")" || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256"; die 'Converted backup checksum sidecar write failed.'; }
    ensure_backup_auth_key || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256"; die 'Converted backup authentication failed.'; }
    IFS= read -r _c_key < "$ABOX_BACKUP_KEY" || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256"; die 'Converted backup authentication failed.'; }
    _c_mac=$(backup_hmac_sha256 "$_c_key" "$_c_tmp" 2>/dev/null)
    [[ "$_c_mac" =~ ^[A-Fa-f0-9]{64}$ ]] || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256"; die 'Converted backup authentication failed.'; }
    write_private_sidecar "${out}.hmac" "$_c_mac  $(basename "$out")" || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256" "${out}.hmac"; die 'Converted backup HMAC sidecar write failed.'; }
    # Archive appears last, only when both sidecars already exist.
    # 07b-02: -T: a directory appearing at $out during the long
    # package/validate/sidecar window must fail loudly instead of
    # having the archive hardlinked INSIDE it (and reported success).
    ln -T -- "$_c_tmp" "$out" || { rm -rf "$work"; rm -f "$_c_tmp" "${out}.sha256" "${out}.hmac"; die 'Converted backup already exists.'; }
    rm -f -- "$_c_tmp"
    [[ -f "$out" && ! -L "$out" && "$(sha256sum < "$out" 2>/dev/null | awk '{print $1}')" == "${_c_hash,,}" ]] || { rm -rf "$work"; rm -f "$out" "${out}.sha256" "${out}.hmac"; die 'Converted backup authentication failed.'; }
    rm -rf "$work"
    msg "${GREEN}[*] Legacy backup converted safely:${NC} $out"
    msg "${YELLOW}[*] Services are imported as stopped; review configuration before starting them.${NC}"
}


validate_backup_archive() {
    # R11C14-02: the expected archive root follows the config dir:
    # backups stage $root$ABOX_DIR, so a non-default ABOX_DIR yields
    # root/opt/abox, not root/etc/ddr. Callers may pass the config
    # dir explicitly; default is the current ABOX_DIR.
    local archive="$1" _cfg_dir="${2:-$ABOX_DIR}"
    [[ -s "$archive" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    # UID/GID numbers stored in a backup are source-host metadata. The archive
    # is authenticated separately; restore-time ownership is normalized to the
    # target host's dedicated runtime accounts before any service starts.
    python3 -I - "$archive" "$_cfg_dir" <<'PY_VALIDATE'
import posixpath,stat,sys,tarfile
import resource
# R51-M1: bound this process's address space. tarfile reads PAX/GNU
# longname extension headers whole into memory before yielding the
# next member, so the member/size/total caps cannot bound them (a
# 100 MB header peaked at 612 MB RSS in trial; the extractor peaked
# at 912 MB). A 512 MiB cap fails closed (MemoryError -> non-zero
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
fn=sys.argv[1]
_cfg=sys.argv[2].rstrip('/') if len(sys.argv) > 2 else '/etc/ddr'
REQ_ROOT='root' + _cfg if _cfg.startswith('/') else 'root/' + _cfg
MAX_MEMBERS=10000
MAX_FILE=512*1024*1024
MAX_TOTAL=1024*1024*1024
SB_DIR='root/etc/sing-box'
HY_DIR='root/etc/hysteria'
HY_ACME=HY_DIR + '/acme'
XRAY_DIR='root/usr/local/etc/xray'
XRAY_CFG='root/usr/local/etc/xray/config.json'
XL_DIR='root/etc/ddr/xray-latest'
sb_gid=None
hy_uid=None
hy_gid=None
xray_gid=None
xl_gid=None
try: tf=tarfile.open(fn,'r:gz')
except Exception: raise SystemExit(1)
seen=set(); total=0; _count=0; root_member=None
for m in tf:
    _count+=1
    if _count>MAX_MEMBERS: raise SystemExit(1)
    raw=m.name
    if '\x00' in raw or raw.startswith('/'): raise SystemExit(1)
    while raw.startswith('./'): raw=raw[2:]
    n=posixpath.normpath(raw)
    if n==REQ_ROOT: root_member=m
    if n in ('','.'): raise SystemExit(1)
    if n=='..' or n.startswith('../') or n.split('/',1)[0] not in ('root','meta'): raise SystemExit(1)
    if n in seen and not m.isdir(): raise SystemExit(1)
    seen.add(n)
    # Backup contents are copied regular files/directories only.  Reject all
    # links and special members to avoid re-rooting and extraction ambiguity.
    if m.issym() or m.islnk() or m.ischr() or m.isblk() or m.isfifo() or m.isdev(): raise SystemExit(1)
    if not (m.isfile() or m.isdir()): raise SystemExit(1)
    mode=m.mode & 0o7777
    # R-01: Allow sticky (0o1000) for acme dir 1770; reject only setuid/setgid (0o6000).
    # The sticky bit is validated per-branch (ACME dir allows 0o770/0o1770).
    if mode & 0o6000 or mode & 0o002: raise SystemExit(1)
    in_sb = n == SB_DIR or n.startswith(SB_DIR + '/')
    in_hy = n == HY_DIR or n.startswith(HY_DIR + '/')
    in_hy_acme = n == HY_ACME or n.startswith(HY_ACME + '/')
    in_xray = n == XRAY_DIR or n.startswith(XRAY_DIR + '/')
    in_xray_cfg = (n == XRAY_CFG)
    in_xl = n == XL_DIR or n.startswith(XL_DIR + '/')
    if in_xray_cfg:
        # Boundary 1: Xray config.json is root:abox-xray 0640 (gid != 0).
        # Allow non-root group with consistent gid, mode must not be group/other-writable.
        if m.uid != 0 or not m.isfile(): raise SystemExit(1)
        if m.gid == 0:
            if mode & 0o077: raise SystemExit(1)
        else:
            if mode & 0o027: raise SystemExit(1)
            if xray_gid is None: xray_gid=m.gid
            elif m.gid != xray_gid: raise SystemExit(1)
    elif in_xray:
        # Xray config dir is root:abox-xray 0750 (gid != 0) or legacy root:root (no group/other write).
        if m.uid != 0: raise SystemExit(1)
        if m.gid == 0:
            if n == XRAY_DIR:
                if mode & 0o022: raise SystemExit(1)
            else:
                if mode & 0o077: raise SystemExit(1)
        else:
            if mode & 0o027: raise SystemExit(1)
            if xray_gid is None: xray_gid=m.gid
            elif m.gid != xray_gid: raise SystemExit(1)
        if n == XRAY_DIR and not ((m.gid != 0 and mode == 0o750) or (m.gid == 0 and (mode & 0o022) == 0)): raise SystemExit(1)
    elif in_sb:
        # sing-box config data may be group-readable by its dedicated runtime
        # service account. Preserve root:root compatibility, but when a non-root
        # group is present it must be internally consistent within this archive.
        if m.uid != 0: raise SystemExit(1)
        if m.gid == 0:
            if mode & 0o077: raise SystemExit(1)
        else:
            if mode & 0o020: raise SystemExit(1)
            if sb_gid is None: sb_gid=m.gid
            elif m.gid != sb_gid: raise SystemExit(1)
        if n == SB_DIR and not ((m.gid != 0 and mode == 0o750) or (m.gid == 0 and (mode & 0o077) == 0)): raise SystemExit(1)
    elif in_hy_acme:
        # Hysteria ACME state is runtime-owned to allow non-root renewal. The
        # source UID/GID are portable metadata, but must remain internally
        # consistent so a modified member cannot introduce an unrelated identity.
        if n == HY_ACME:
            if m.uid != 0 or not m.isdir(): raise SystemExit(1)
            if m.gid != 0:
                if hy_gid is None: hy_gid=m.gid
                elif m.gid != hy_gid: raise SystemExit(1)
                if hy_uid is None: hy_uid=0
            # R-01: Allow 1770 (sticky) for acme dir as well as 770.
            if not ((m.gid != 0 and mode in (0o770, 0o1770)) or
                    (m.gid == 0 and (mode & 0o077) == 0)): raise SystemExit(1)
        else:
            if m.gid != 0:
                if hy_gid is None: hy_gid=m.gid
                elif m.gid != hy_gid: raise SystemExit(1)
            if m.uid != 0:
                if hy_uid in (None,0): hy_uid=m.uid
                elif m.uid != hy_uid: raise SystemExit(1)
                if hy_gid in (None,0): hy_gid=m.gid
                elif m.gid != hy_gid: raise SystemExit(1)
            elif m.gid != 0 and hy_uid is None:
                hy_uid=0
            if mode & 0o020: raise SystemExit(1)
    elif in_hy:
        # Hysteria's top-level config tree is group-readable by its dedicated
        # runtime account; source group numbers are portable but must be consistent.
        if m.uid != 0: raise SystemExit(1)
        if m.gid == 0:
            if mode & 0o077: raise SystemExit(1)
        else:
            if mode & 0o020: raise SystemExit(1)
            if hy_gid is None: hy_gid=m.gid
            elif m.gid != hy_gid: raise SystemExit(1)
        if n == HY_DIR and not ((m.gid != 0 and mode == 0o750) or (m.gid == 0 and (mode & 0o077) == 0)): raise SystemExit(1)
    elif in_xl:
        # SYD-B2 E11: coexist xray-latest config mirrors the stable
        # Xray shape (dir root:abox-xray 0750, files root:abox-xray
        # 0640). Without this branch the subtree fell into the
        # catch-all else branch (gid must be 0) and every backup taken
        # while a coexist deployment existed was rejected, blocking
        # any deploy_xray.
        if m.uid != 0: raise SystemExit(1)
        if m.gid == 0:
            if m.isdir():
                if mode & 0o022: raise SystemExit(1)
            else:
                if mode & 0o077: raise SystemExit(1)
        else:
            if mode & 0o027: raise SystemExit(1)
            if xl_gid is None: xl_gid=m.gid
            elif m.gid != xl_gid: raise SystemExit(1)
        if n == XL_DIR and not ((m.gid != 0 and mode == 0o750) or (m.gid == 0 and (mode & 0o022) == 0)): raise SystemExit(1)
    else:
        if m.uid != 0 or m.gid != 0: raise SystemExit(1)
        if mode & 0o020: raise SystemExit(1)
    if m.isfile():
        if m.size < 0 or m.size > MAX_FILE: raise SystemExit(1)
        total += m.size
        if total > MAX_TOTAL: raise SystemExit(1)
required_names={REQ_ROOT,'meta/manifest.version','meta/manifest.sha256','meta/managed-paths.txt','meta/services.state','meta/firewall.backend','meta/iptables.snapshot','meta/ip6tables.snapshot','meta/cron.abox.txt'}
if not required_names.issubset(seen): raise SystemExit(1)
required_root=REQ_ROOT
if required_root not in seen: raise SystemExit(1)
if root_member is None or not root_member.isdir(): raise SystemExit(1)
raise SystemExit(0)
PY_VALIDATE
}

backup_root_contains_service() {
    local root="$1" srv="$2" path
    local -a paths=()
    case "$srv" in
        xray) paths=(
            /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray
            /etc/systemd/system/xray.service /etc/init.d/xray /etc/conf.d/xray
        ) ;;
        sing-box) paths=(
            /usr/local/bin/sing-box /etc/sing-box
            /etc/systemd/system/sing-box.service /etc/init.d/sing-box /etc/conf.d/sing-box
        ) ;;
        hysteria) paths=(
            /usr/local/bin/hysteria /etc/hysteria
            /etc/systemd/system/hysteria.service /etc/init.d/hysteria /etc/conf.d/hysteria
        ) ;;
        xray-latest) paths=(
            /usr/local/bin/xray-latest /etc/ddr/xray-latest
            /etc/systemd/system/xray-latest.service /etc/init.d/xray-latest /etc/conf.d/xray-latest
        ) ;;
        *) return 2 ;;
    esac
    for path in "${paths[@]}"; do
        [[ -e "$root$path" || -L "$root$path" ]] && return 0
    done
    return 1
}

backup_root_service_init() {
    local root="$1" srv="$2" unit found=''
    for unit in "$root/etc/systemd/system/${srv}.service" "$root/etc/init.d/${srv}"; do
        [[ -e "$unit" || -L "$unit" ]] || continue
        if [[ -n "$found" ]]; then
            return 2
        fi
        case "$unit" in
            "$root/etc/systemd/system/${srv}.service") found=systemd ;;
            "$root/etc/init.d/${srv}") found=openrc ;;
        esac
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

validate_backup_core_init_compatibility() {
    local root="$1" srv backup_init current_init contains_rc
    current_init=$(effective_init_system) || return 1
    [[ "$current_init" == systemd || "$current_init" == openrc ]] || return 1
    for srv in xray sing-box hysteria xray-latest; do
        backup_root_contains_service "$root" "$srv"
        contains_rc=$?
        case "$contains_rc" in
            0) ;;
            1) continue ;;
            *) return 1 ;;
        esac
        # A-04: Config-only backups have no unit; skip init compatibility check.
        backup_root_service_is_config_only "$root" "$srv" && continue
        backup_root_service_is_managed "$root" "$srv" || return 1
        backup_init=$(backup_root_service_init "$root" "$srv") || return 1
        [[ "$backup_init" == "$current_init" ]] || {
            msg "${RED}[!] Backup for ${srv} uses ${backup_init}, but this VPS uses ${current_init}; refusing restore before any destructive change.${NC}"
            return 1
        }
    done
    return 0
}

backup_root_service_is_managed() {
    local root="$1" srv="$2" unit found=0
    for unit in "$root/etc/systemd/system/${srv}.service" "$root/etc/init.d/${srv}"; do
        [[ -e "$unit" || -L "$unit" ]] || continue
        [[ -f "$unit" && ! -L "$unit" ]] || return 1
        grep -Fxq '# Managed by A-Box' "$unit" 2>/dev/null || return 1
        found=$((found + 1))
    done
    (( found == 1 ))
}

# A-04: A backup is "config-only" if it has NO unit file AND NO binary for the
# service (A-04 converter strips both). Config-only backups import config files
# only; they must NOT pass the managed-unit check (no unit to check) and must
# NOT declare the service as running in services.state.
backup_root_service_is_config_only() {
    local root="$1" srv="$2" bin
    case "$srv" in
        xray) bin="$root/usr/local/bin/xray" ;;
        sing-box) bin="$root/usr/local/bin/sing-box" ;;
        hysteria) bin="$root/usr/local/bin/hysteria" ;;
        xray-latest) bin="$root/usr/local/bin/xray-latest" ;;
        *) return 1 ;;
    esac
    [[ ! -e "$root/etc/systemd/system/${srv}.service" && ! -L "$root/etc/systemd/system/${srv}.service" ]] || return 1
    [[ ! -e "$root/etc/init.d/${srv}" && ! -L "$root/etc/init.d/${srv}" ]] || return 1
    [[ ! -e "$bin" && ! -L "$bin" ]]
}

validate_backup_manifest_tree() {
    local work="$1"
    python3 -I - "$work" <<'PY_BACKUP_MANIFEST'
import hashlib
import os
import re
import sys
from pathlib import Path, PurePosixPath
root=Path(sys.argv[1]).resolve()
manifest=root/'meta'/'manifest.sha256'
if not manifest.is_file() or manifest.is_symlink(): raise SystemExit(1)
entries={}
for raw in manifest.read_text(encoding='utf-8',errors='strict').splitlines():
    m=re.fullmatch(r'([0-9A-Fa-f]{64})  (.+)',raw)
    if not m: raise SystemExit(1)
    digest,name=m.groups()
    pp=PurePosixPath(name)
    if pp.is_absolute() or '..' in pp.parts or not pp.parts or pp.parts[0] not in {'root','meta'}: raise SystemExit(1)
    if name=='meta/manifest.sha256' or name in entries: raise SystemExit(1)
    entries[name]=digest.lower()
actual={}
for base in (root/'root',root/'meta'):
    for path in base.rglob('*'):
        if path.is_symlink(): raise SystemExit(1)
        if path.is_file():
            rel=path.relative_to(root).as_posix()
            if rel=='meta/manifest.sha256': continue
            actual[rel]=path
if set(entries)!=set(actual): raise SystemExit(1)
for name,path in actual.items():
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    if h.hexdigest()!=entries[name]: raise SystemExit(1)
PY_BACKUP_MANIFEST
}

validate_managed_paths_file() {
    local file="$1" allowed_paths='' srv core_paths
    [[ -f "$file" && ! -L "$file" ]] || return 1
    allowed_paths=$(managed_auxiliary_paths) || return 1
    # Legacy: backups made before the rename list /usr/local/bin/sb in
    # their manifest. It is only tolerated here for validation of old
    # backups; it is never installed, managed, or restored.
    allowed_paths+=$'\n/usr/local/bin/sb'
    for srv in xray sing-box hysteria xray-latest; do
        core_paths=$(core_family_paths "$srv") || return 1
        allowed_paths+=$'\n'"$core_paths"
    done
    python3 -I - "$file" "$allowed_paths" <<'PY_MANAGED_PATHS'
import sys
from pathlib import Path
allowed={x for x in sys.argv[2].splitlines() if x}
lines=[x for x in Path(sys.argv[1]).read_text(encoding='utf-8',errors='strict').splitlines() if x]
if len(lines)!=len(set(lines)) or any(x not in allowed for x in lines): raise SystemExit(1)
PY_MANAGED_PATHS
}

validate_services_state_file() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk -F'|' '
      NF==0 {next}
      NF!=3 || $1 !~ /^(xray|sing-box|hysteria|xray-latest)$/ || $2 !~ /^[01]$/ || $3 !~ /^(enabled|enabled-runtime|indirect|disabled)$/ {bad=1; exit}
      seen[$1]++ {bad=1; exit}
      END {exit bad}
    ' "$file"
}

# S1-NEW-05: a service whose managed unit and config survive but whose
# binary was deleted (e.g. rm /usr/local/bin/xray) is NOT config-only
# (A-04 requires no unit AND no binary), yet its backup is a faithful
# snapshot: the deploy flow refetches the binary unconditionally, and
# uninstall needs no binary at all. Only backup CREATION may treat this
# shape as recoverable; restore gates stay strict (a restore must not
# reinstall a service with no binary).
backup_root_service_is_binary_missing_managed() {
    local root="$1" srv="$2" bin cfg
    case "$srv" in
        xray) bin="$root/usr/local/bin/xray"; cfg="$root/usr/local/etc/xray/config.json" ;;
        sing-box) bin="$root/usr/local/bin/sing-box"; cfg="$root/etc/sing-box/config.json" ;;
        hysteria) bin="$root/usr/local/bin/hysteria"; cfg="$root/etc/hysteria/config.yaml" ;;
        xray-latest) bin="$root/usr/local/bin/xray-latest"; cfg="$root/etc/ddr/xray-latest/config.json" ;;
        *) return 1 ;;
    esac
    [[ ! -e "$bin" && ! -L "$bin" ]] || return 1
    [[ -f "$cfg" ]] || return 1
    backup_root_service_is_managed "$root" "$srv"
}

validate_extracted_backup_content() {
    local root="$1" srv path src work mode="${2:-restore}"
    local live_state row
    work=$(dirname "$root")
    [[ -f "$work/meta/manifest.version" && -f "$work/meta/manifest.sha256" ]] || return 1
    grep -Fxq 'A-Box backup manifest v3' "$work/meta/manifest.version" || return 1
    validate_backup_manifest_tree "$work" || return 1
    # H-21 (Carbon R3): migrate a legacy .shortcut AFTER the manifest
    # tree check (its hashes cover the pre-migration bytes) and BEFORE
    # the strict parse below, so a backup still carrying the retired
    # xray-latest token validates instead of deadlocking. Runs on the
    # private extracted copy only; a file without the legacy token is
    # untouched (migrate returns 2). A corrupt manifest fails above,
    # before any byte is changed.
    shortcut_migrate_legacy_file "$root$ABOX_DIR/.shortcut" || true
    # SYD-B7: tree hashes prove the backup manifest file is intact, not that
    # its rows are well-formed; validate row semantics when present (a missing
    # manifest is left to the merge path, which handles it).
    if [[ -e "$root$ABOX_DIR/.managed-core-files.tsv" || -L "$root$ABOX_DIR/.managed-core-files.tsv" ]]; then
        [[ -f "$root$ABOX_DIR/.managed-core-files.tsv" && ! -L "$root$ABOX_DIR/.managed-core-files.tsv" ]] || return 1
        _manifest_rows_valid "$root$ABOX_DIR/.managed-core-files.tsv" || return 1
    fi
    validate_managed_paths_file "$work/meta/managed-paths.txt" || return 1
    validate_abox_cron_file "$work/meta/cron.abox.txt" || return 1
    grep -Eq '^(iptables|ufw|firewalld)$' "$work/meta/firewall.backend" || return 1
    validate_services_state_file "$work/meta/services.state" || return 1
    [[ -f "$root$ABOX_DIR/.A-Box-owner" && ! -L "$root$ABOX_DIR/.A-Box-owner" ]] || return 1
    grep -Fxq 'A-Box managed directory v1' "$root$ABOX_DIR/.A-Box-owner" 2>/dev/null || return 1
    if [[ -e "$root$ABOX_DIR/.shortcut" || -L "$root$ABOX_DIR/.shortcut" ]]; then
        [[ -f "$root$ABOX_DIR/.shortcut" && ! -L "$root$ABOX_DIR/.shortcut" ]] || return 1
        shortcut_parse_state_file "$root$ABOX_DIR/.shortcut" || return 1
    fi
    # H-08: an archived zram.conf is never sourced (the helper only
    # whitelist-parses it); reject any archived copy whose lines do
    # not match that same whitelist. A runner in the archive must be
    # byte-identical to the script this backup records (meta
    # metadata.txt) -- it is never copied back (preserved name), but
    # a foreign runner must fail validation here.
    if [[ -e "$root$ABOX_DIR/zram.conf" || -L "$root$ABOX_DIR/zram.conf" ]]; then
        [[ -f "$root$ABOX_DIR/zram.conf" && ! -L "$root$ABOX_DIR/zram.conf" ]] || return 1
        grep -qvE '^(SIZE_MB=[0-9]+|ALGO=(zstd|lz4|lzo-rle|lzo))$' "$root$ABOX_DIR/zram.conf" 2>/dev/null && return 1
    fi
    if [[ -e "$root$ABOX_DIR/user-guard-runner.sh" || -L "$root$ABOX_DIR/user-guard-runner.sh" ]]; then
        [[ -f "$root$ABOX_DIR/user-guard-runner.sh" && ! -L "$root$ABOX_DIR/user-guard-runner.sh" ]] || return 1
        local _rec_sha='' _run_sha=''
        _rec_sha=$(sed -n 's/^Script SHA256: \([0-9a-fA-F]\{64\}\)$/\1/p' "$work/meta/metadata.txt" 2>/dev/null | head -1)
        if [[ -z "$_rec_sha" && -f "$0" && ! -L "$0" ]]; then
            _rec_sha=$(sha256sum -- "$0" 2>/dev/null | awk '{print $1}')
        fi
        [[ "$_rec_sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
        _run_sha=$(sha256sum -- "$root$ABOX_DIR/user-guard-runner.sh" 2>/dev/null | awk '{print $1}')
        [[ "${_run_sha,,}" == "${_rec_sha,,}" ]] || return 1
    fi
    for srv in xray sing-box hysteria xray-latest; do
        backup_root_contains_service "$root" "$srv" || continue
        if backup_root_service_is_config_only "$root" "$srv"; then
            # A-04: Config-only backup must NOT declare service as running,
            # and must contain the config file.
            ! grep -Eq "^${srv}\|" "$work/meta/services.state" 2>/dev/null || return 1
            case "$srv" in
                xray) [[ -f "$root/usr/local/etc/xray/config.json" ]] || return 1 ;;
                sing-box) [[ -f "$root/etc/sing-box/config.json" ]] || return 1 ;;
                hysteria) [[ -f "$root/etc/hysteria/config.yaml" ]] || return 1 ;;
                xray-latest) [[ -f "$root/etc/ddr/xray-latest/config.json" ]] || return 1 ;;
            esac
        else
            # S1-NEW-05 residual (followup5 A-leg): the binary can be
            # deleted while the process is still alive (rm
            # /usr/local/bin/xray, then straight into the menu), so the
            # freshly captured services.state TRUTHFULLY claims running
            # (|1|). Accept a |1| row only when it still matches the LIVE
            # reading exactly (whole srv|1|enabled triple): a stale or
            # forged |1| row — live stopped, live unqueryable, or live
            # enablement differing — still fails closed. The |0| path is
            # unchanged (no live query needed). Restore mode is
            # untouched: a backup archive claiming |1| with no binary is
            # still rejected there.
            if [[ "$mode" == backup ]] && backup_root_service_is_binary_missing_managed "$root" "$srv"; then
                if grep -Eq "^${srv}\\|0\\|(enabled|enabled-runtime|indirect|disabled)$" "$work/meta/services.state"; then
                    :
                elif grep -Eq "^${srv}\\|1\\|(enabled|enabled-runtime|indirect|disabled)$" "$work/meta/services.state"; then
                    live_state=$(managed_service_state_value "$srv" 2>/dev/null) || return 1
                    row=$(grep -E "^${srv}\\|1\\|(enabled|enabled-runtime|indirect|disabled)$" "$work/meta/services.state" 2>/dev/null) || return 1
                    [[ "$live_state" == "$row" ]] || return 1
                else
                    return 1
                fi
            else
                backup_root_service_is_managed "$root" "$srv" || return 1
                case "$srv" in
                    xray) [[ -f "$root/usr/local/bin/xray" && -f "$root/usr/local/etc/xray/config.json" ]] || return 1 ;;
                    sing-box) [[ -f "$root/usr/local/bin/sing-box" && -f "$root/etc/sing-box/config.json" ]] || return 1 ;;
                    hysteria) [[ -f "$root/usr/local/bin/hysteria" && -f "$root/etc/hysteria/config.yaml" ]] || return 1 ;;
                    xray-latest) [[ -f "$root/usr/local/bin/xray-latest" && -f "$root/etc/ddr/xray-latest/config.json" ]] || return 1 ;;
                esac
            fi
        fi
    done
    local aux_paths=''
    aux_paths=$(managed_auxiliary_paths) || return 1
    while IFS= read -r path; do
        src="$root$path"
        [[ -e "$src" || -L "$src" ]] || continue
        auxiliary_content_is_abox_managed "$src" "$path" || return 1
    done <<< "$aux_paths"
}

assert_restore_target_safe() {
    local root="$1" srv path c=''
    validate_extracted_backup_content "$root" || { msg "${RED}[!] Backup content ownership markers are invalid.${NC}"; return 1; }
    local conflicts=''
    for srv in xray sing-box hysteria xray-latest; do
        backup_root_contains_service "$root" "$srv" || continue
        conflicts=$(list_foreign_core_conflicts "$srv") || return 1
        c+="$conflicts"$'\n'
    done
    local aux_paths=''
    aux_paths=$(managed_auxiliary_paths) || return 1
    while IFS= read -r path; do
        [[ "$path" == /usr/local/bin/sb ]] && continue
        [[ -e "$root$path" || -L "$root$path" ]] || continue
        [[ ! -e "$path" && ! -L "$path" ]] || auxiliary_path_is_abox_managed "$path" || c+="aux|${path}"$'\n'
    done <<< "$aux_paths"
    [[ -z "${c//$'\n'/}" ]] || { msg "${RED}[!] Restore would overwrite non-A-Box paths:${NC}"; printf '%s' "$c" >&2; return 1; }
}

assert_restore_shortcut_safe() {
    local root="$1"
    # Wrappers are regenerable products: they are never restored by
    # copying the archived files. Only the state file is restored, and
    # only when it parses strictly. (An old backup has no .shortcut at
    # all; the live state is then left alone.)
    local _sc="$root$ABOX_DIR/.shortcut"
    if [[ -e "$_sc" || -L "$_sc" ]]; then
        [[ -f "$_sc" && ! -L "$_sc" ]] || return 1
        shortcut_parse_state_file "$_sc" || return 1
    fi
    return 0
}

abox_restore_preserved_name() {
    case "$1" in
        backups|diagnostics|preflight|.tz-rollback|.dns-backup|A-Box.sh|.backup-hmac.key|.runtime.lock|.runtime.lock.d|socket_probe.sh|geo_update.sh|traffic_monitor.sh|firewall_restore.sh|iptables.v4|iptables.v6|user-guard-runner.sh|zram.conf|zram.state|.swapfile.managed|.wallos-cf-token|wallos-caddy*|.abox-caddy-owned|wallos-images.txt|*.log) return 0 ;;
        *) return 1 ;;
    esac
}

# SYD-B5e R3b: preserve means untouched. When the backup lacks latest, the
# blanket stop would leave the preserved family down (service-state restore
# only touches services listed in the backup), and the residual sweep would
# kill its live PID, so skip latest on both steps here.
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

# SYD-B6m: manifest merge for preserved families. Directory restore copies
# the backup's manifest over the live one, and the ownership loop only
# re-records backup-contained families, so a preserved family's rows would
# be lost permanently. Merge restores them: base = backup manifest rows,
# plus live rows for families still owned but absent from the backup.
# Backup-contained families keep backup rows (never live rows); families
# owned in neither live nor backup gain no rows; a family that stopped
# being owned before the merge (e.g. a rolled-back target) is never
# merged. Malformed rows fail closed; a missing snapshot is a no-op
# (fresh host that never had a manifest).
# SYD-B7: merge failure must not leave the backup manifest in place.
# The wrapper restores the pre-restore live manifest from the snapshot, but
# only when the snapshot itself is valid (rows + size); an invalid snapshot
# is never installed, and the caller preserves the work dir for forensics.
merge_retained_manifest_rows() {
    # Returns: 0 merged; 1 merge failed but live restored from snapshot;
    # 2 merge failed and rollback failed/unavailable (live NOT restored to
    # pre-restore state; caller must preserve forensics).
    # SYD-B8: rollback is atomic (same-dir temp copy + mode/owner + row
    # validation + rename, every step checked), so a failed rollback never
    # truncates or partially writes live; "undetermined" means not restored
    # to pre-restore state, never a torn live file.
    local root="$1" snapshot="$2" _rb_tmp="" _rb_ok=0
    if _merge_retained_manifest_rows_inner "$root" "$snapshot"; then return 0; fi
    if [[ -n "$snapshot" && -n "$ABOX_CORE_OWNERSHIP" && -f "$snapshot" && ! -L "$snapshot" ]] \
        && [[ "$(stat -c %s "$snapshot" 2>/dev/null || echo 99999999)" -le 4194304 ]] \
        && _manifest_rows_valid "$snapshot"; then
        if [[ ! -e "$ABOX_CORE_OWNERSHIP" || ( -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ) ]]; then
            _rb_tmp=$(umask 077; mktemp "$(dirname "$ABOX_CORE_OWNERSHIP")/.managed-core-files.rollback.XXXXXX") || _rb_tmp=""
            if [[ -n "$_rb_tmp" ]] \
                && cp -a -- "$snapshot" "$_rb_tmp" 2>/dev/null \
                && chmod 600 "$_rb_tmp" 2>/dev/null \
                && { [[ $EUID -ne 0 ]] || chown root:root "$_rb_tmp" 2>/dev/null; } \
                && _manifest_rows_valid "$_rb_tmp" \
                && mv -f -- "$_rb_tmp" "$ABOX_CORE_OWNERSHIP" 2>/dev/null; then
                _rb_ok=1
            elif [[ -n "$_rb_tmp" ]]; then
                rm -f -- "$_rb_tmp" 2>/dev/null || true
            fi
        fi
    fi
    if [[ "$_rb_ok" == 1 ]]; then return 1; fi
    return 2
}

_merge_retained_manifest_rows_inner() {
    local root="$1" snapshot="$2" live tmp rows_file srv _brc=0 _orc=0
    local TAB=$'\t'
    [[ -n "$root" && -d "$root" && -n "$snapshot" ]] || return 1
    [[ ! -e "$snapshot" && ! -L "$snapshot" ]] && return 0
    [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
    [[ "$(stat -c %s "$snapshot" 2>/dev/null || echo 99999999)" -le 4194304 ]] || return 1
    _manifest_rows_valid "$snapshot" || return 1
    live="$ABOX_CORE_OWNERSHIP"
    [[ -n "$live" ]] || return 1
    if [[ -e "$live" || -L "$live" ]]; then
        [[ -f "$live" && ! -L "$live" ]] || return 1
        [[ "$(stat -c %s "$live" 2>/dev/null || echo 99999999)" -le 4194304 ]] || return 1
        _manifest_rows_valid "$live" || return 1
    fi
    rows_file=$(mktemp) || return 1
    for srv in xray sing-box hysteria xray-latest; do
        # SYD-B7: containment is a trichotomy (0 contained / 1 absent /
        # anything else error), mirroring regen + manual-ownership loops;
        # a non-0/1 result must fail, never silently drop retained rows.
        backup_root_contains_service "$root" "$srv"; _brc=$?
        if [[ "$_brc" == 1 ]]; then
            :
        elif [[ "$_brc" == 0 ]]; then
            continue
        else
            rm -f -- "$rows_file"; return 1
        fi
        abox_owns_service "$srv"; _orc=$?
        if [[ "$_orc" == 0 ]]; then
            :
        elif [[ "$_orc" == 1 ]]; then
            continue
        else
            rm -f -- "$rows_file"; return 1
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            IFS=$'\t' read -r t f p h rest <<< "$line"
            if [[ "$f" == "$srv" ]]; then
                # SYD-B7: an unchecked append lets ENOSPC silently lose
                # retained rows and install a partial manifest as success.
                printf '%s\n' "$line" >> "$rows_file" || { rm -f -- "$rows_file"; return 1; }
            fi
        done < "$snapshot"
    done
    [[ -s "$rows_file" ]] || { rm -f -- "$rows_file"; return 0; }
    tmp=$(umask 077; mktemp "$ABOX_DIR/.managed-core-files.merge.XXXXXX") || { rm -f -- "$rows_file"; return 1; }
    if [[ -f "$live" ]]; then cat -- "$live" > "$tmp" || { rm -f -- "$tmp" "$rows_file"; return 1; }; fi
    # SYD-B7: a base manifest without trailing LF would concatenate its last
    # row with the first retained row into one bad row; normalize first.
    # (command substitution strips trailing newlines, so a non-empty tail
    # output means the last byte is not LF.)
    if [[ -s "$tmp" ]]; then
        # SYD-B8: tail failure must fail the merge, never be read as
        # "already LF" (output and status are taken separately).
        local _tail_out='' _tail_rc=0
        _tail_out=$(tail -c 1 -- "$tmp" 2>/dev/null) || _tail_rc=$?
        if [[ "$_tail_rc" -ne 0 ]]; then rm -f -- "$tmp" "$rows_file"; return 1; fi
        if [[ -n "$_tail_out" ]]; then printf '\n' >> "$tmp" || { rm -f -- "$tmp" "$rows_file"; return 1; }; fi
    fi
    cat -- "$rows_file" >> "$tmp" || { rm -f -- "$tmp" "$rows_file"; return 1; }
    awk '!seen[$0]++' "$tmp" > "$tmp.dedup" || { rm -f -- "$tmp" "$tmp.dedup" "$rows_file"; return 1; }
    LC_ALL=C sort -t "$TAB" -k2,2 -k3,3 -o "$tmp.dedup" "$tmp.dedup" || { rm -f -- "$tmp" "$tmp.dedup" "$rows_file"; return 1; }
    # SYD-B7: the key-conflict loop below never validates row shape, so
    # re-validate the merged output before it can be installed.
    _manifest_rows_valid "$tmp.dedup" || { rm -f -- "$tmp" "$tmp.dedup" "$rows_file"; return 1; }
    local prev_key='' prev_line='' key cur
    while IFS= read -r cur || [[ -n "$cur" ]]; do
        IFS=$'\t' read -r t f p h rest <<< "$cur"
        key="$f$TAB$p"
        if [[ "$key" == "$prev_key" && "$cur" != "$prev_line" ]]; then
            rm -f -- "$tmp" "$tmp.dedup" "$rows_file"; return 1
        fi
        prev_key="$key"; prev_line="$cur"
    done < "$tmp.dedup"
    mv -f -- "$tmp.dedup" "$tmp" || { rm -f -- "$tmp" "$tmp.dedup" "$rows_file"; return 1; }
    # R13-02: the merged manifest must be re-checked against the
    # 4 MiB cap before it can be installed; a merge that grew past
    # the cap fails instead of silently installing an oversized
    # manifest (the caller restores the live manifest from the
    # snapshot, so the restore fails as a whole, not partially).
    [[ "$(stat -c %s "$tmp" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { rm -f -- "$tmp" "$rows_file"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp" "$rows_file"; return 1; }
    if [[ $EUID -eq 0 ]]; then chown root:root "$tmp" || { rm -f -- "$tmp" "$rows_file"; return 1; }; fi
    mv -f -- "$tmp" "$live" || { rm -f -- "$tmp" "$rows_file"; return 1; }
    rm -f -- "$rows_file"
    return 0
}

stop_managed_services_for_restore() {
    local failed=0 _contains_rc=0
    if [[ -n "${1:-}" && -d "$1" ]]; then
        backup_root_contains_service "$1" xray-latest || _contains_rc=$?
    fi
    if [[ "$_contains_rc" == 1 ]]; then
        stop_abox_service xray || failed=1
        stop_abox_service sing-box || failed=1
        stop_abox_service hysteria || failed=1
        kill_managed_residual_pids xray-latest >/dev/null 2>&1 || failed=1
        (( failed == 0 ))
    else
        stop_all_managed_services
    fi
}

clear_abox_runtime_for_restore() {
    local child base failed=0 preserve_latest=0 preserve_shortcut=0 _contains_rc=0
    [[ -d "$ABOX_DIR" && ! -L "$ABOX_DIR" ]] || return 0
    # SYD-B5e R3: the B5 preserve rule (old backup keeps live latest) must
    # hold across the clear step too, or the preserved family's config dir
    # is wiped here and regen later fails on the missing config.
    if [[ -n "${1:-}" && -d "$1" ]]; then
        backup_root_contains_service "$1" xray-latest || _contains_rc=$?
        [[ "$_contains_rc" == 1 ]] && preserve_latest=1
        # R13-01: an old backup without .shortcut must not delete
        # the live .shortcut state (the backup has nothing to
        # restore in its place; the live file is the only copy).
        if [[ ! -e "$1$ABOX_DIR/.shortcut" && ! -L "$1$ABOX_DIR/.shortcut" ]]; then
            preserve_shortcut=1
        fi
    fi
    for child in "$ABOX_DIR"/* "$ABOX_DIR"/.[!.]* "$ABOX_DIR"/..?*; do
        [[ -e "$child" || -L "$child" ]] || continue
        base=${child##*/}
        abox_restore_preserved_name "$base" && continue
        [[ "$preserve_shortcut" == 1 && "$base" == .shortcut ]] && continue
        [[ "$preserve_latest" == 1 && "$base" == xray-latest ]] && continue
        path_tree_has_mountpoint "$child" && { msg "${RED}[!] Restore cleanup encountered a mountpoint; aborting before deletion: ${child}${NC}"; return 1; }
    done
    for child in "$ABOX_DIR"/* "$ABOX_DIR"/.[!.]* "$ABOX_DIR"/..?*; do
        [[ -e "$child" || -L "$child" ]] || continue
        base=${child##*/}
        abox_restore_preserved_name "$base" && continue
        [[ "$preserve_shortcut" == 1 && "$base" == .shortcut ]] && continue
        [[ "$preserve_latest" == 1 && "$base" == xray-latest ]] && continue
        rm -rf -- "$child" || failed=1
    done
    (( failed == 0 ))
}

restore_abox_directory() {
    local root="$1" src child base
    src="$root$ABOX_DIR"
    [[ -d "$src" && ! -L "$src" ]] || return 1
    path_parent_chain_safe "$ABOX_DIR" || return 1
    if [[ -e "$ABOX_DIR" || -L "$ABOX_DIR" ]]; then
        [[ -d "$ABOX_DIR" && ! -L "$ABOX_DIR" ]] || return 1
    else
        install -d -m 700 "$ABOX_DIR" || return 1
    fi
    # R4C14-01: same criterion as backup (nested only); the data
    # directory itself may live on a separate filesystem.
    path_tree_has_nested_mountpoint "$ABOX_DIR" && return 1
    ensure_abox_dir_owned "$ABOX_DIR" || return 1
    for child in "$src"/* "$src"/.[!.]* "$src"/..?*; do
        [[ -e "$child" || -L "$child" ]] || continue
        base=${child##*/}
        abox_restore_preserved_name "$base" && continue
        [[ ! -L "$child" ]] || return 1
        cp -a -- "$child" "$ABOX_DIR/" || return 1
    done
    ensure_abox_dir_owned "$ABOX_DIR" || return 1
}

normalize_restored_runtime_ownership() {
    local family="$1" user group
    IFS=$'\t' read -r user group < <(abox_runtime_identity "$family") || return 1
    ensure_abox_runtime_identity "$family" || return 1
    case "$family" in
        sing-box)
            [[ -d /etc/sing-box && ! -L /etc/sing-box ]] || return 1
            chown -R "root:$group" /etc/sing-box || return 1
            ;;
        hysteria)
            [[ -d /etc/hysteria && ! -L /etc/hysteria ]] || return 1
            chown -R "root:$group" /etc/hysteria || return 1
            if [[ -d /etc/hysteria/acme ]]; then
                [[ ! -L /etc/hysteria/acme ]] || return 1
                chown -R "$user:$group" /etc/hysteria/acme || return 1
                # R10C14-01: marker via pinned fd; a symlink
                # swap is refused, never followed to /etc/passwd.
                if [[ -e /etc/hysteria/acme/.A-Box-managed || -L /etc/hysteria/acme/.A-Box-managed ]]; then
                    fd_secure_chown_chmod /etc/hysteria/acme/.A-Box-managed 0 0 600 || return 1
                fi
                chown "root:$group" /etc/hysteria/acme || return 1
            fi
            ;;
        xray)
            [[ -d /usr/local/etc/xray && ! -L /usr/local/etc/xray ]] || return 1
            chown -R "root:$group" /usr/local/etc/xray || return 1
            chmod 750 /usr/local/etc/xray || return 1
            ;;
        xray-latest)
            [[ -d /etc/ddr/xray-latest && ! -L /etc/ddr/xray-latest ]] || return 1
            chown -R "root:$group" /etc/ddr/xray-latest || return 1
            chmod 750 /etc/ddr/xray-latest || return 1
            ;;
        *) return 1 ;;
    esac
}

# L4-E10 (final-round): reinstall the USERGUARD cron block after a restore.
# regenerate used to reinstall only PROBE/GEO/TRAFFIC, so a restore always
# dropped the user-guard tick even when the backup carried it. Layered by
# backup fidelity:
#   1. backup meta/cron.abox.txt validates AND carries a USERGUARD block
#      -> reinstall (the validator only allows the default tick line, so a
#        tampered rhythm can never be installed from the backup);
#   2. otherwise, when users exist or the guard runner is present ->
#      rebuild with the default rhythm via setup_user_guard;
#   3. otherwise -> install nothing, but record the explicit
#      "not installed" status so the restore summary cannot hide it.
# Sets ABOX_RESTORE_CRON_USERGUARD to installed (backup|default) or
# "not installed (no users, no runner)". Returns 1 only when an install
# was attempted and failed.
restore_user_guard_cron_block() {
    local _restore_root="${1:-}" _backup_cron='' _users_dir='' _runner='' _have_users=0
    ABOX_RESTORE_CRON_USERGUARD='not installed (no users, no runner)'
    [[ -n "$_restore_root" ]] || return 1
    _backup_cron="$(dirname -- "$_restore_root")/meta/cron.abox.txt"
    _users_dir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}"
    _runner="${ABOX_DIR:-/etc/ddr}/user-guard-runner.sh"
    if [[ -f "$_backup_cron" && ! -L "$_backup_cron" ]] \
        && validate_abox_cron_file "$_backup_cron" 2>/dev/null \
        && { grep -Fq '# A-Box USERGUARD BEGIN' "$_backup_cron" 2>/dev/null \
            || grep -Fq '*/5 * * * * /bin/bash /etc/ddr/user-guard-runner.sh --user-guard-tick >/dev/null 2>&1' "$_backup_cron" 2>/dev/null; }; then
        setup_user_guard || return 1
        ABOX_RESTORE_CRON_USERGUARD='installed (backup)'
        return 0
    fi
    if [[ -d "$_users_dir" ]] && [[ -n "$(ls -A "$_users_dir" 2>/dev/null)" ]]; then _have_users=1; fi
    if (( _have_users == 1 )) || [[ -f "$_runner" && ! -L "$_runner" ]]; then
        setup_user_guard || return 1
        ABOX_RESTORE_CRON_USERGUARD='installed (default)'
        return 0
    fi
    return 0
}

# L4-E10: one-line restore summary of the four cron blocks, so a missing
# block can never hide behind a bare "restore complete".
report_restore_cron_status() {
    msg "[cron restore] PROBE:${ABOX_RESTORE_CRON_PROBE:-unknown} GEO:${ABOX_RESTORE_CRON_GEO:-unknown} TRAFFIC:${ABOX_RESTORE_CRON_TRAFFIC:-unknown} USERGUARD:${ABOX_RESTORE_CRON_USERGUARD:-unknown}"
}

# H-08: a restored zram.state whose BOOT= belongs to another boot
# strands the recorded device: `abox-zram stop` refuses to touch a
# record it cannot prove is this boot's, while the device may still
# be live. After a restore, drop a stale record (never fail the
# restore) and tell the user how to stop a still-active device.
validate_restored_zram_state() {
    local _state='/etc/ddr/zram.state' _sboot='' _sdev='' _boot=''
    [[ -f "$_state" && ! -L "$_state" ]] || return 0
    _sboot=$(sed -n 's/^BOOT=//p' "$_state" 2>/dev/null | head -1)
    _sdev=$(sed -n 's/^DEV=//p' "$_state" 2>/dev/null | head -1)
    _boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    if [[ -n "$_sboot" && -n "$_boot" && "$_sboot" == "$_boot" ]]; then
        return 0
    fi
    rm -f -- "$_state" || true
    msg "${YELLOW}[!] Restored zram.state was stale (BOOT mismatch); removed it. If a zram swap is still active, stop it by hand: swapoff ${_sdev:-/dev/zramN} && zramctl --reset ${_sdev:-/dev/zramN}${NC}" >&2
    return 0
}

regenerate_runtime_assets_after_restore() {
    local _restore_root="${1:-}" _brc=0
    [[ -n "$_restore_root" ]] || return 1
    clear_abox_env_vars
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        load_abox_env "$ABOX_ENV" || return 1
    fi
    for srv in xray sing-box hysteria; do
        abox_owns_service "$srv" || continue
        backup_root_contains_service "$_restore_root" "$srv"; _brc=$?
        if [[ "$_brc" == 0 ]]; then
            prepare_abox_runtime_permissions "$srv" || return 1
        elif [[ "$_brc" != 1 ]]; then
            return 1
        fi
    done
    ABOX_RESTORE_CRON_PROBE='unknown'
    ABOX_RESTORE_CRON_GEO='unknown'
    ABOX_RESTORE_CRON_TRAFFIC='unknown'
    ABOX_RESTORE_CRON_USERGUARD='unknown'
    setup_shortcut || return 1
    setup_health_monitor || return 1
    ABOX_RESTORE_CRON_PROBE='installed'
    setup_geo_cron || return 1
    ABOX_RESTORE_CRON_GEO='installed'
    if valid_traffic_limit_gb "${TRAFFIC_LIMIT_GB:-}"; then
        setup_traffic_monitor || return 1
        ABOX_RESTORE_CRON_TRAFFIC='installed'
    else
        disable_traffic_monitor || return 1
        ABOX_RESTORE_CRON_TRAFFIC='disabled'
    fi
    restore_user_guard_cron_block "$_restore_root" || return 1
}


restore_tree_path() {
    local root="$1" path="$2" src parent current
    src="$root$path"
    [[ "$path" == /* && "$path" != / ]] || return 1
    parent=$(dirname "$path")
    # Refuse to traverse a symlinked live parent directory.
    current='/'
    IFS='/' read -r -a _parts <<< "${parent#/}"
    for _part in "${_parts[@]}"; do
        [[ -n "$_part" ]] || continue
        current="${current%/}/$_part"
        [[ -L "$current" ]] && return 1
    done
    if [[ "$parent" != "/" ]] && path_is_mountpoint "$parent"; then
        return 1
    fi
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        # Even when the backup has no matching target, the live target may
        # contain nested mounts. Treat the whole target tree as protected so
        # cleanup cannot recurse into an unrelated mounted filesystem.
        path_tree_has_mountpoint "$path" && return 1
        rm -rf -- "$path" || return 1
        return 0
    fi
    [[ ! -L "$src" ]] || return 1
    path_tree_has_mountpoint "$path" && return 1
    mkdir -p "$parent" || return 1
    rm -rf -- "$path" || return 1
    cp -a -- "$src" "$parent/" || return 1
    [[ ! -L "$path" ]]
}

restore_shortcut_from_backup() {
    # No-op by design: shortcut wrappers are regenerable and are
    # re-created on the target by regenerate_runtime_assets_after_restore
    # (setup_shortcut -> shortcut_ensure) after the restored state file
    # is validated. Copying archived wrappers here would bypass the
    # conflict checks and the transaction.
    return 0
}

restore_auxiliary_path_from_backup() {
    local root="$1" path="$2" src
    src="$root$path"
    shortcut_is_managed_path "$path" && { restore_shortcut_from_backup "$root"; return; }
    if [[ -e "$src" || -L "$src" ]]; then
        auxiliary_content_is_abox_managed "$src" "$path" || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || auxiliary_path_is_abox_managed "$path" || return 1
        restore_tree_path "$root" "$path"
    else
        remove_owned_auxiliary_path "$path"
    fi
}

restore_core_family_from_backup() {
    local root="$1" srv="$2" path core_paths='' contains_rc=0 backup_init current_init
    backup_root_contains_service "$root" "$srv"
    contains_rc=$?
    case "$contains_rc" in
        0) ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
    # A-04: Config-only backups have no unit; skip init checks.
    local cfg_only=0
    if backup_root_service_is_config_only "$root" "$srv"; then
        cfg_only=1
    else
        backup_root_service_is_managed "$root" "$srv" || return 1
        backup_init=$(backup_root_service_init "$root" "$srv") || return 1
        current_init=$(effective_init_system) || return 1
        [[ "$backup_init" == "$current_init" ]] || {
            msg "${RED}[!] Backup for ${srv} uses ${backup_init}, but this VPS uses ${current_init}; refusing cross-init restore.${NC}"
            return 1
        }
    fi
    core_paths=$(core_family_paths "$srv") || return 1
    [[ -n "$core_paths" ]] || return 1
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        # Config-only restore touches only what the backup provides; a
        # missing binary/unit path must keep the live file, not delete it.
        if (( cfg_only == 1 )) && [[ ! -e "$root$path" && ! -L "$root$path" ]]; then
            continue
        fi
        restore_tree_path "$root" "$path" || return 1
    done <<< "$core_paths"
    normalize_restored_runtime_ownership "$srv" || return 1
}



# BUG-28: hoisted from backup_current_config(). $1=src $2=root (staging dir).
# Returns 0 on success/skip, 1 on failure (caller sets backup_failed=1).
__abox_backup_copy_path() {
    local src="$1" root="$2" dst links
    [[ ! -L "$src" ]] || return 1
    [[ -e "$src" ]] || return 0
    # A managed path may acquire a nested mount after ownership was recorded.
    # Never let cp -a traverse into an external filesystem/bind mount during backup.
    path_tree_has_mountpoint "$src" && return 1
    if [[ -d "$src" ]]; then
        links=$(find "$src" -type l -print 2>/dev/null) || return 1
        [[ -z "$links" ]] || return 1
    fi
    dst="$root$src"
    mkdir -p "$(dirname "$dst")" || return 1
    # SYD-B5e R1: the ABOX_DIR tar branch already staged this dir; cp -a
    # src dst would copy src INTO dst, nesting basename(src) and poisoning
    # every backup with <dir>/<dir>/ copies that later fail the remove
    # preflight. A pre-existing dir dst already holds the staged tree.
    if [[ -d "$src" && -d "$dst" && ! -L "$dst" ]]; then
        return 0
    fi
    cp -a -- "$src" "$dst"
}
backup_current_config() {
    local ts unique backup_dir work root tarball archive_tmp backup_failed=0 backup_fw_unsupported=0 backend srv path _abox_links
    valid_backup_retention_count "$BACKUP_RETENTION_COUNT" || die "$(tr_msg backup_current_config_retention_invalid)"
    ts=$(date +%Y%m%d-%H%M%S); unique=$(openssl rand -hex 3 2>/dev/null || printf '%s' "$$")
    backup_dir="${1:-$ABOX_DIR/backups}"
    [[ "$backup_dir" == /* ]] || die 'Backup directory must be an absolute path.'
    path_parent_chain_safe "$backup_dir/.A-Box-backup-destination" || die 'Backup directory parent chain is unsafe.'
    if [[ -e "$backup_dir" || -L "$backup_dir" ]]; then
        [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || die 'Backup directory is not a safe regular directory.'
        path_owned_by_root "$backup_dir" || die 'Backup directory is not root-owned.'
        path_mode_has_no_group_other_write "$backup_dir" || die 'Backup directory permissions are unsafe.'
    fi
    local backup_extra_excludes=() backup_find_prune=() _abox_noslash="${ABOX_DIR%/}" _backup_noslash="${backup_dir%/}"
    if [[ "$_backup_noslash" == "$_abox_noslash" ]]; then
        die 'Backup directory must not be the A-Box directory itself; choose a subdirectory or an external directory.'
    elif [[ "$_backup_noslash" == "$_abox_noslash"/* ]]; then
        backup_extra_excludes=(--exclude="./${_backup_noslash#"$_abox_noslash"/}")
        # R5C14-03: prune the custom backup target from the link
        # scan too; tar excludes it, so a symlink inside it must
        # not abort the backup.
        backup_find_prune=(-path "$_backup_noslash" -prune -o)
    fi
    work=$(mktemp -d /tmp/A-Box-backup.XXXXXX) || die 'Backup temp directory creation failed.'
    root="$work/root"; mkdir_private "$backup_dir" || { rm -rf "$work"; die 'Backup directory creation failed.'; }
    install -d -m 700 "$root" "$work/meta" || { rm -rf "$work"; die 'Backup directory creation failed.'; }
    path_owned_by_root "$backup_dir" || { rm -rf "$work"; die 'Backup directory ownership verification failed.'; }
    path_mode_has_no_group_other_write "$backup_dir" || { rm -rf "$work"; die 'Backup directory permissions verification failed.'; }
    local managed_paths='' core_paths=''
    managed_paths=$(managed_auxiliary_paths) || { rm -rf "$work"; die 'Managed path list creation failed.'; }
    for srv in xray sing-box hysteria xray-latest; do
        core_paths=$(core_family_paths "$srv") || { rm -rf "$work"; die "Core path enumeration failed: $srv"; }
        managed_paths+=$'\n'"$core_paths"
    done
    printf '%s\n' "$managed_paths" | awk 'NF && !seen[$0]++' > "$work/meta/managed-paths.txt" || { rm -rf "$work"; die 'Managed path list write failed.'; }
    msg "${YELLOW}[*] $(tr_msg bk_creating)${NC}"
    if [[ -d "$ABOX_DIR" ]]; then
        # The A-Box data directory itself can live on a separate filesystem, but
        # a nested mount must never be traversed by tar during backup. This also
        # catches same-device bind mounts that --one-file-system cannot detect.
        path_tree_has_nested_mountpoint "$ABOX_DIR" && backup_failed=1
        # C-04: Exclude .tz-rollback/.dns-backup (contain symlinks from cp -a of /etc/localtime, /etc/resolv.conf). R28-OBS-S1-05: also exclude .dns-backup.new.* staging dirs (same symlinked resolv.conf copy); a leaked staging dir must not abort the backup.
        # M-27: also prune .tz-snap.* (snapshot staging, symlinked
        # /etc/localtime copy), .tz-rollback-new.* and
        # .tune-backup-new.* staging dirs; a leaked staging dir must
        # not abort the backup, like .dns-backup.new.* above.
        _abox_links=$(find "$ABOX_DIR" -path "$ABOX_DIR/backups" -prune -o -path "$ABOX_DIR/diagnostics" -prune -o -path "$ABOX_DIR/preflight" -prune -o -path "$ABOX_DIR/.tz-rollback" -prune -o -path "$ABOX_DIR/.dns-backup" -prune -o -path "$ABOX_DIR/.dns-backup.new.*" -prune -o -path "$ABOX_DIR/.tz-snap.*" -prune -o -path "$ABOX_DIR/.tz-rollback-new.*" -prune -o -path "$ABOX_DIR/.tune-backup-new.*" -prune -o "${backup_find_prune[@]}" -type l -print 2>/dev/null) || backup_failed=1
        if [[ -n "${_abox_links:-}" ]]; then
            backup_failed=1
        else
            mkdir -p "$root$ABOX_DIR" || backup_failed=1
            [[ "$backup_failed" == 0 ]] && (cd "$ABOX_DIR" && tar \
                --exclude='./backups' --exclude='./diagnostics' --exclude='./preflight' \
                --exclude='./.tz-rollback' --exclude='./.dns-backup' --exclude='./.dns-backup.new.*' --exclude='./.tz-snap.*' --exclude='./.tz-rollback-new.*' --exclude='./.tune-backup-new.*' --exclude='./.deps.v*' \
                --exclude='./A-Box.sh' --exclude='./.backup-hmac.key' --exclude='./.runtime.lock' --exclude='./.runtime.lock.d' \
                --exclude='./socket_probe.sh' --exclude='./geo_update.sh' --exclude='./traffic_monitor.sh' \
                --exclude='./firewall_restore.sh' --exclude='./iptables.v4' --exclude='./iptables.v6' \
                --exclude='./.shortcut-migrate' --exclude='./.shortcut.lock' \
                --exclude='./user-guard-runner.sh' --exclude='./zram.conf' --exclude='./zram.state' \
                --exclude='./.swapfile.managed' --exclude='./.wallos-cf-token' --exclude='./wallos-caddy*' \
                --exclude='./.abox-caddy-owned' --exclude='./wallos-images.txt' --exclude='./*.log' \
                "${backup_extra_excludes[@]}" \
                -cpf - . | tar -C "$root$ABOX_DIR" -xpf -) || backup_failed=1
        fi
    fi
    while IFS= read -r _sc_path; do
        shortcut_is_abox_managed "$_sc_path" && { __abox_backup_copy_path "$_sc_path" "$root" || backup_failed=1; }
    done < <(shortcut_primary_paths)
    for srv in xray sing-box hysteria xray-latest; do
        if abox_owns_service "$srv"; then
            core_paths=$(core_family_paths "$srv") || { rm -rf "$work"; die "Core path enumeration failed during backup: $srv"; }
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                __abox_backup_copy_path "$path" "$root" || backup_failed=1
            done <<< "$core_paths"
        fi
    done
    local aux_paths=''
    aux_paths=$(managed_auxiliary_paths) || { rm -rf "$work"; die 'Managed auxiliary path enumeration failed during backup.'; }
    while IFS= read -r path; do
        shortcut_is_managed_path "$path" && continue
        auxiliary_path_is_abox_managed "$path" && { __abox_backup_copy_path "$path" "$root" || backup_failed=1; }
    done <<< "$aux_paths"
    { echo 'A-Box backup'; echo "Created: $(now_iso)"; echo "Host: $(hostname 2>/dev/null || true)"; echo "Kernel: $(uname -a 2>/dev/null || true)"; echo "Init: ${INIT_SYS:-unknown}"; echo "Script SHA256: $(sha256sum "$0" 2>/dev/null | awk '{print $1}')"; } > "$work/meta/metadata.txt"
    collect_abox_cron > "$work/meta/cron.abox.txt" 2>/dev/null || backup_failed=1
    capture_managed_service_state "$work/meta/services.state" || backup_failed=1
    backend=$(firewall_backend) || { backup_failed=1; backup_fw_unsupported=1; }
    printf '%s\n' "$backend" > "$work/meta/firewall.backend"
    [[ "$backend" != 'nftables-unsupported' ]] || { backup_failed=1; backup_fw_unsupported=1; }
    capture_abox_iptables_snapshot "$work/meta/iptables.snapshot" 4 || { backup_failed=1; backup_fw_unsupported=1; }
    capture_abox_iptables_snapshot "$work/meta/ip6tables.snapshot" 6 || { backup_failed=1; backup_fw_unsupported=1; }
    if (( backup_failed != 0 )); then
        rm -rf "$work"
        if (( backup_fw_unsupported == 1 )); then
            die 'Backup aborted: firewall backend is unsupported or its firewall snapshot could not be captured; no A-Box paths were harmed.'
        else
            die 'Backup aborted because an existing A-Box path could not be copied.'
        fi
    fi
    printf '%s\n' 'A-Box backup manifest v3' > "$work/meta/manifest.version"
    create_backup_manifest "$work" "$work/meta/manifest.sha256" || { rm -rf "$work"; die 'Backup manifest creation failed.'; }
    validate_extracted_backup_content "$root" backup || { rm -rf "$work"; die 'Backup content validation failed.'; }
    tarball="$backup_dir/A-Box-backup-${ts}-${unique}.tar.gz"
    # R13-03: create the archive as a private temp file in the same
    # directory (umask 077 mktemp, so no 0644-readable window under
    # umask 022), chmod it under control, then publish it with a
    # same-dir rename. A failure before publication only removes
    # the temp file, never a pre-existing tarball at the final name.
    archive_tmp=$(umask 077; mktemp "$backup_dir/.A-Box-backup.XXXXXXXXXX") || { rm -rf "$work"; die 'Backup temporary file creation failed.'; }
    (umask 077; tar -C "$work" --hard-dereference -czf "$archive_tmp" root meta) || { rm -rf "$work"; rm -f "$archive_tmp"; die 'Backup tarball creation failed.'; }
    chmod 600 "$archive_tmp" || { rm -rf "$work"; rm -f "$archive_tmp"; die 'Backup tarball permission setting failed.'; }
    [[ ! -d "$tarball" ]] || { rm -rf "$work"; rm -f "$archive_tmp"; die 'Backup destination is a directory.'; }
    mv -f -- "$archive_tmp" "$tarball" || { rm -rf "$work"; rm -f "$archive_tmp"; die 'Backup tarball publication failed.'; }
    validate_backup_archive "$tarball" || { rm -rf "$work"; rm -f "$tarball"; die 'Backup archive validation failed.'; }
    backup_checksum_write "$tarball" || { rm -rf "$work"; rm -f "$tarball" "${tarball}.sha256"; die 'Backup SHA256 creation failed.'; }
    backup_auth_write "$tarball" || { rm -rf "$work"; rm -f "$tarball" "${tarball}.sha256" "${tarball}.hmac"; die 'Backup HMAC authentication creation failed.'; }
    local backup_dir_real abox_dir_real
    backup_dir_real=$(canonical_path "$backup_dir") || { rm -rf "$work"; die 'Backup directory canonicalization failed.'; }
    abox_dir_real=$(canonical_path "$ABOX_DIR") || { rm -rf "$work"; die 'A-Box directory canonicalization failed.'; }
    if [[ "$backup_dir_real" != "$abox_dir_real" && "$backup_dir_real" != "$abox_dir_real/"* ]]; then
        # External destinations leave ABOX_DIR (and .backup-hmac.key) behind.
        # Write the recovery key ONLY under /root/A-Box-backup-keys/ (mode 700).
        # A-05a: Do NOT place ${tarball}.key next to archive (co-location defeats HMAC trust model).
        local key_value keys_dir='/root/A-Box-backup-keys' separated_key
        separated_key="$keys_dir/$(basename "$tarball").key"
        IFS= read -r key_value < "$ABOX_BACKUP_KEY" || { rm -rf "$work"; rm -f "$tarball" "${tarball}.sha256" "${tarball}.hmac"; die 'External backup recovery key read failed.'; }
        install -d -m 700 -o root -g root -- "$keys_dir" || { rm -rf "$work"; rm -f "$tarball" "${tarball}.sha256" "${tarball}.hmac"; die 'Backup keys directory creation failed.'; }
        if [[ ! -e "$separated_key" && ! -L "$separated_key" ]]; then
            write_private_sidecar "$separated_key" "$key_value" || { rm -rf "$work"; rm -f "$tarball" "${tarball}.sha256" "${tarball}.hmac" "$separated_key"; die 'Separated recovery key write failed.'; }
        fi
        # A-05a: Do NOT write ${tarball}.key next to archive (co-location defeats HMAC trust model).
        # Key lives ONLY in /root/A-Box-backup-keys/ (mode 700, root-only).
        # H6 (R52-02 = L12): the separated key is PERMANENTLY retained.
        # It is the only copy of the HMAC key for its archive, and the
        # archive may have been copied to external media; retention
        # below therefore never deletes separated keys. The only
        # deletion path is cleanup_separated_backup_keys (explicit
        # name + typed DELETE-KEY confirmation, via backup menu 5).
        msg "${GREEN}[*] $(tr_msg bk_recovery_key)${NC} $separated_key"
        msg "${YELLOW}[!] $(tr_msg bk_keep_key)${NC}"
    fi
    rm -rf "$work"
    ABOX_LAST_BACKUP="$tarball"
    if [[ -n "${ABOX_BACKUP_RESULT_FILE:-}" ]]; then
        printf '%s\n' "$tarball" > "$ABOX_BACKUP_RESULT_FILE" || return 1
    fi
    # R9C14-01: retention deletion lives inside the Python program below
    # (exact Path objects, no name round-trip through bash).
    # H6 (R52-02 = L12): retention deletes archives and their
    # archive-adjacent sidecars (.sha256/.hmac/.key) ONLY -- the
    # separated keys in /root/A-Box-backup-keys/ are never touched
    # (see cleanup_separated_backup_keys for the lifecycle policy).
    if python3 -I - "$backup_dir" "$BACKUP_RETENTION_COUNT" "$tarball" <<'PY_BACKUP_RETENTION'
from pathlib import Path
import sys
root = Path(sys.argv[1]); keep = int(sys.argv[2])
last = Path(sys.argv[3]) if len(sys.argv) > 3 else None
items = []
for p in root.glob('A-Box-backup-*.tar.gz'):
    try:
        if p.is_file() and not p.is_symlink(): items.append((p.stat().st_mtime_ns, p))
    except OSError: pass
retention_failed = False
for _, p in sorted(items, reverse=True)[keep:]:
    # The old code printed names to bash and split them with mapfile: a
    # newline inside an archive name split into a bare tail piece, and rm
    # then deleted same-named unrelated files in the caller's CWD as root
    # while the real archive survived. NUL-delimited output is no fix:
    # bash command substitution cannot carry NUL bytes.
    if last is not None and p == last: continue
    # 07c-M1: a failed archive unlink must not silently continue to
    # delete that archive's authentication sidecars: the surviving
    # archive would lose its verification files. Record the failure
    # and leave its sidecars alone.
    try: p.unlink()
    except OSError:
        retention_failed = True
        continue
    for suffix in ('.sha256', '.hmac', '.key'):
        try: Path(str(p) + suffix).unlink()
        except FileNotFoundError: pass
        except OSError: retention_failed = True
sys.exit(1 if retention_failed else 0)
PY_BACKUP_RETENTION
    then
        :
    else
        msg "${YELLOW}[!] $(tr_msg bk_retention_fail)${NC}"
    fi
    msg "${GREEN}[*] $(tr_msg bk_created)${NC} $tarball"
}

# H6 (R52-02 = L12, hardening): separated recovery-key lifecycle.
# POLICY -- explicit permanent retention + operator-named manual
# cleanup. The key in /root/A-Box-backup-keys/ is the ONLY copy of
# the HMAC key for its archive, and the archive itself may have been
# copied to external media long ago. Local archive absence therefore
# proves nothing about whether the key is still needed: deleting a
# key because no same-named archive survives locally could destroy
# the recovery of an externally stored archive. So:
#   * retention (backup_current_config) NEVER deletes separated keys
#     -- it removes archives and their archive-adjacent sidecars only;
#   * this function is the ONLY deletion path, and it deletes only a
#     key the operator names explicitly (exact basename, no bulk or
#     "orphan" mode), after a typed DELETE-KEY confirmation and a
#     printed warning that the archive may live on external media.
# No argument lists the keys (with advisory local-archive presence)
# and deletes nothing; interactively it then offers one named
# deletion, non-interactively it stops at the list.
# ABOX_BACKUP_KEYS_DIR is a test seam; production is always
# /root/A-Box-backup-keys.
cleanup_separated_backup_keys() {
    local keys_dir="${ABOX_BACKUP_KEYS_DIR:-/root/A-Box-backup-keys}" _name="${1:-}" _f='' _archive='' _present='' _answer='' _target='' _any=0
    (( EUID == 0 )) || return 1
    # W6-OBS-1: a missing keys directory used to fail silently (zero
    # output, straight to "press return"). Say so explicitly, like
    # the empty-directory message below.
    if [[ ! -d "$keys_dir" ]]; then msg '[*] No separated recovery keys (key directory does not exist).'; return 1; fi
    [[ ! -L "$keys_dir" ]] || return 1
    path_parent_chain_safe "$keys_dir" || return 1
    if [[ -z "$_name" ]]; then
        for _f in "$keys_dir"/A-Box-backup-*.tar.gz.key; do
            [[ -f "$_f" && ! -L "$_f" ]] || continue
            _any=1
            _archive="$(basename -- "${_f%.key}")"
            _present='no'
            if [[ -f "${ABOX_DIR:-/etc/ddr}/backups/$_archive" || -f "/root/A-Box-backups/$_archive" ]]; then _present='yes'; fi
            msg "[*] $_f (same-named archive present locally: $_present)"
        done
        (( _any == 0 )) && msg '[*] No separated recovery keys.'
        msg '[!] A separated key is the only copy for its archive, which may live on external media; local archive absence does not mean the key is unneeded. Deletion is by explicit name only.'
        if [[ -t 0 ]]; then
            read -r -p 'Key basename to delete (empty = none): ' _name || return 0
            [[ -n "$_name" ]] || return 0
        else
            return 0
        fi
    fi
    case "$_name" in */*|*..*) return 1 ;; esac
    [[ "$_name" == A-Box-backup-*.tar.gz.key ]] || return 1
    _target="$keys_dir/$_name"
    [[ -f "$_target" && ! -L "$_target" ]] || return 1
    path_parent_chain_safe "$_target" || return 1
    msg "[!] Deleting $_target destroys recovery of its archive, which may be stored on external media. This cannot be undone."
    read -r -p 'Type DELETE-KEY to confirm permanent deletion: ' _answer || return 1
    [[ "$_answer" == 'DELETE-KEY' ]] || return 1
    rm -f -- "$_target" || return 1
    [[ ! -e "$_target" && ! -L "$_target" ]] || return 1
    msg "[*] Deleted separated recovery key: $_target"
    return 0
}

auto_backup_prompt() {
    local reason="${1:-operation}" dest="${2:-$ABOX_DIR/backups}" answer
    local _lbl=''
    _lbl=$(tr_msg "$reason")
    [[ -n "$_lbl" ]] || _lbl="$reason"
    msg "${YELLOW}[!] $(tprintf bk_recommend "$_lbl")${NC}"
    read -r -p "$(tr_msg bk_create_prompt)" answer
    if is_yes "$answer"; then
        backup_current_config "$dest"
    else
        msg "${YELLOW}[*] $(tr_msg bk_skipped)${NC}"
    fi
}

auto_backup_silent() {
    local reason="${1:-operation}" dest="${2:-$ABOX_DIR/backups}" newest
    msg "${YELLOW}[*] Auto backup before: ${reason}${NC}"
    # L6: a backup landing in the uninstall transaction directory is a
    # temporary transaction copy, not a safe backup yet -- say so, or the
    # identical "backup created" line is misread as the prompt backup.
    if [[ "$dest" == */A-Box-uninstall-tx.* ]]; then
        msg "[*] Transaction backup: this copy lives in the temporary uninstall transaction directory and is preserved to /root/A-Box-backups before cleanup completes."
    fi
    # SYD-B E1b: run the backup in a subshell with the die hook
    # cleared, so a backup failure only fails this call (the caller
    # returns to the menu) instead of exiting the whole script.
    # F03: the subshell's ABOX_LAST_BACKUP assignment is lost, so
    # the exact path comes back through a protected result file.
    # Recomputing it with ls -t can pick an older backup (clock
    # skew, same-second ties) or keep a stale value when no new
    # file appears; an empty result now fails closed.
    local result_file=''
    result_file=$(mktemp /tmp/A-Box-backup-result.XXXXXX) || return 1
    chmod 600 "$result_file" || { rm -f "$result_file"; return 1; }
    ( ABOX_DIE_HOOK=''; ABOX_BACKUP_RESULT_FILE="$result_file"; backup_current_config "$dest" ) || { rm -f "$result_file"; return 1; }
    newest=$(cat "$result_file" 2>/dev/null || true)
    rm -f "$result_file"
    [[ -n "$newest" && -f "$newest" ]] || return 1
    ABOX_LAST_BACKUP="$newest"
}

# R13-04: preflight for the preserved retired xray-latest instance.
# Records (port, proto) pairs that have a real prior A-Box firewall
# allow into $1 (plan file, "port|proto" per line). Returns 0 with an
# empty plan when there is no owned instance or no inbounds; returns 1
# when the live config cannot be parsed strictly or a prior-allow
# query fails (unknown state must fail, never silently skip).
preserved_latest_firewall_preflight() {
    local plan="$1" cfg _backend _pairs _port _proto _rc _has _zone _orc
    [[ -n "$plan" ]] || return 1
    # R52-01: abox_owns_service is a trichotomy (0 owned / 1 not
    # owned / anything else a query error, mirroring the
    # 54873 merge-loop handling). A query error must fail the
    # preflight, never pass as "no instance" with no plan:
    # the caller then cleans the firewall rules and the
    # replay treats a missing plan as success, silently
    # losing the retained instance's ports.
    abox_owns_service xray-latest; _orc=$?
    if [[ "$_orc" == 0 ]]; then
        :
    elif [[ "$_orc" == 1 ]]; then
        return 0
    else
        return 1
    fi
    cfg="$ABOX_DIR/xray-latest/config.json"
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    _backend=$(firewall_backend 2>/dev/null) || return 1
    case "$_backend" in
        iptables|ufw|firewalld) ;;
        *) return 1 ;;
    esac
    # Parse the live inbounds strictly: port must be a JSON int
    # (booleans are ints in Python and must be excluded); the transport
    # maps to tcp/udp; an unknown transport, a range or boolean port,
    # or malformed JSON fails the preflight. A config with no inbounds
    # yields an empty plan and success.
    _pairs=$(python3 -I - "$cfg" <<'PY_PREFLIGHT'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)
inbounds = cfg.get("inbounds")
if inbounds is None:
    inbounds = []
if not isinstance(inbounds, list):
    sys.exit(1)
seen = set()
out = []
for ib in inbounds:
    if not isinstance(ib, dict):
        sys.exit(1)
    port = ib.get("port")
    if isinstance(port, bool) or not isinstance(port, int):
        sys.exit(1)
    if not 1 <= port <= 65535:
        sys.exit(1)
    ss = ib.get("streamSettings")
    if ss is None:
        proto = "tcp"
    else:
        if not isinstance(ss, dict):
            sys.exit(1)
        network = ss.get("network")
        if network is None:
            proto = "tcp"
        elif network in ("tcp", "ws", "http", "grpc", "xhttp"):
            proto = "tcp"
        elif network in ("kcp", "quic"):
            proto = "udp"
        else:
            sys.exit(1)
    key = (port, proto)
    if key not in seen:
        seen.add(key)
        out.append("%d|%s" % (port, proto))
print("\n".join(out))
PY_PREFLIGHT
) || return 1
    : > "$plan" || return 1
    chmod 600 "$plan" || { rm -f -- "$plan"; return 1; }
    if [[ -n "$_pairs" ]]; then
        while IFS='|' read -r _port _proto || [[ -n "$_port" ]]; do
            [[ -n "$_port" && -n "$_proto" ]] || { rm -f -- "$plan"; return 1; }
            _has=0
            case "$_backend" in
                iptables)
                    iptables_rule_check "${IPT:-iptables}" INPUT -p "$_proto" --dport "$_port" -m comment --comment "A-Box-${_port}-${_proto}" -j ACCEPT; _rc=$?
                    if [[ "$_rc" == 0 ]]; then
                        _has=1
                    elif [[ "$_rc" == 2 ]]; then
                        rm -f -- "$plan"; return 1
                    elif command -v ip6tables >/dev/null 2>&1; then
                        iptables_rule_check "${IPT6:-ip6tables}" INPUT -p "$_proto" --dport "$_port" -m comment --comment "A-Box-${_port}-${_proto}" -j ACCEPT; _rc=$?
                        if [[ "$_rc" == 0 ]]; then
                            _has=1
                        elif [[ "$_rc" == 2 ]]; then
                            rm -f -- "$plan"; return 1
                        fi
                    fi
                    ;;
                ufw)
                    ufw_owned_rule_exists "$_port" "$_proto"; _rc=$?
                    if [[ "$_rc" == 0 ]]; then
                        _has=1
                    elif [[ "$_rc" == 2 ]]; then
                        rm -f -- "$plan"; return 1
                    fi
                    ;;
                firewalld)
                    if [[ -z "${_zone:-}" ]]; then
                        _zone=$(firewalld_zone_for_abox) || { rm -f -- "$plan"; return 1; }
                    fi
                    firewalld_port_state "$_port" "$_proto" runtime "$_zone"; _rc=$?
                    if [[ "$_rc" == 0 ]]; then
                        _has=1
                    elif [[ "$_rc" == 2 ]]; then
                        rm -f -- "$plan"; return 1
                    fi
                    firewalld_port_state "$_port" "$_proto" permanent "$_zone"; _rc=$?
                    if [[ "$_rc" == 0 ]]; then
                        _has=1
                    elif [[ "$_rc" == 2 ]]; then
                        rm -f -- "$plan"; return 1
                    fi
                    ;;
            esac
            if [[ "$_has" == 1 ]]; then
                printf '%s|%s\n' "$_port" "$_proto" >> "$plan" || { rm -f -- "$plan"; return 1; }
            fi
        done <<< "$_pairs"
    fi
    return 0
}

# R13-04: replay the preflight plan ($1). A missing or empty plan is
# a no-op (success). A non-empty plan with a lost instance fails
# instead of silently succeeding. Each pair is re-allowed through
# allowPort in a subshell, so an allowPort die cannot kill the caller.
restore_preserved_latest_firewall() {
    local plan="$1" _port _proto
    [[ -n "$plan" ]] || return 1
    if [[ ! -e "$plan" && ! -L "$plan" ]]; then return 0; fi
    [[ -f "$plan" && ! -L "$plan" ]] || return 1
    if [[ ! -s "$plan" ]]; then return 0; fi
    abox_owns_service xray-latest || return 1
    while IFS='|' read -r _port _proto || [[ -n "$_port" ]]; do
        [[ "$_port" =~ ^[0-9]+$ ]] || return 1
        [[ "$_proto" == tcp || "$_proto" == udp ]] || return 1
        ( allowPort "$_port" "$_proto" ) < /dev/null || return 1
    done < "$plan"
    return 0
}

restore_latest_backup_silent() {
    local backup_dir="${1:-$ABOX_DIR/backups}" selected="${2:-}" key_file="${3:-}" work root backend mode=all srv
    [[ -d "$backup_dir" ]] || { msg "restore gate failed: backup-dir" >&2; return 1; }
    if [[ -n "$selected" ]]; then
        [[ -f "$selected" && "$(dirname "$selected")" == "$backup_dir" ]] || { msg "restore gate failed: selected-path" >&2; return 1; }
    else
        selected=$(python3 -I - "$backup_dir" <<'PY_LATEST_BACKUP'
from pathlib import Path
import sys
root = Path(sys.argv[1])
items = []
for p in root.glob('A-Box-backup-*.tar.gz'):
    try:
        if p.is_file() and not p.is_symlink():
            items.append((p.stat().st_mtime_ns, str(p)))
    except OSError:
        pass
if items:
    print(sorted(items, reverse=True)[0][1])
PY_LATEST_BACKUP
) || { msg "restore gate failed: latest-select" >&2; return 1; }
    fi
    [[ -n "$selected" ]] || { msg "restore gate failed: selected-empty" >&2; return 1; }
    # F01: verify-and-extract must use one pinned copy, not the
    # shared $selected path (a writer on the backup dir could
    # swap it between verify and tar). Copy the archive plus
    # its sidecars (same basenames, so every derived sidecar
    # and key path stays correct) into the private work dir
    # first; every later step uses the copy.
    work=$(mktemp -d /tmp/A-Box-rollback.XXXXXX) || { msg "restore gate failed: workdir" >&2; return 1; }; chmod 700 "$work"
    local _rbc="$work/$(basename "$selected")" _rbs=''
    cp -- "$selected" "$_rbc" || { rm -rf "$work"; msg "restore gate failed: private-copy" >&2; return 1; }
    chmod 600 "$_rbc" || { rm -rf "$work"; msg "restore gate failed: private-copy" >&2; return 1; }
    for _rbs in "${selected}.sha256" "${selected}.hmac" "${selected}.key"; do
        if [[ -e "$_rbs" ]]; then
            cp -- "$_rbs" "$work/$(basename "$_rbs")" || { rm -rf "$work"; msg "restore gate failed: private-copy" >&2; return 1; }
        fi
    done
    backup_checksum_verify "$_rbc" "${_rbc}.sha256" || { msg "restore gate failed: checksum" >&2; rm -rf "$work"; return 1; }
    if [[ -n "$key_file" ]]; then
        backup_auth_verify_with_key_file "$_rbc" "${_rbc}.hmac" "$key_file" || { msg "restore gate failed: hmac-key" >&2; rm -rf "$work"; return 1; }
    else
        backup_auth_verify "$_rbc" "${_rbc}.hmac" || { msg "restore gate failed: hmac" >&2; rm -rf "$work"; return 1; }
    fi
    validate_backup_archive "$_rbc" || { msg "restore gate failed: archive" >&2; rm -rf "$work"; return 1; }
    tar -xzf "$_rbc" -C "$work" || { msg "restore gate failed: unpack" >&2; rm -rf "$work"; return 1; }
    root="$work/root"; assert_restore_target_safe "$root" || { msg "restore gate failed: target-safe" >&2; rm -rf "$work"; return 1; }; assert_restore_shortcut_safe "$root" || { msg "restore gate failed: shortcut-safe" >&2; rm -rf "$work"; return 1; }; validate_backup_core_init_compatibility "$root" || { msg "restore gate failed: init-compat" >&2; rm -rf "$work"; return 1; }
    local _manifest_snapshot="$work/live-manifest.tsv"
    if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
        [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || { msg "restore gate failed: live-manifest" >&2; rm -rf "$work"; return 1; }
        # SYD-B7: validate the live manifest BEFORE any destructive step;
        # a corrupt live manifest must fail here, not after stop/remove/clear.
        [[ "$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { msg "restore gate failed: live-manifest-size" >&2; rm -rf "$work"; return 1; }
        _manifest_rows_valid "$ABOX_CORE_OWNERSHIP" || { msg "restore gate failed: live-manifest-rows" >&2; rm -rf "$work"; return 1; }
        cp -a -- "$ABOX_CORE_OWNERSHIP" "$_manifest_snapshot" || { msg "restore gate failed: manifest-snapshot" >&2; rm -rf "$work"; return 1; }
        chmod 600 "$_manifest_snapshot" || { msg "restore gate failed: manifest-snapshot" >&2; rm -rf "$work"; return 1; }
    fi
    # C2 (D3/D4): detection only here -- restore never prompts or retires
    # a live instance. An unclassifiable live layout fails the restore.
    _c2_xl_detect_rc=0
    xray_latest_legacy_detect >/dev/null 2>&1 || _c2_xl_detect_rc=$?
    if (( _c2_xl_detect_rc == 2 )); then msg "restore gate failed: legacy xray-latest layout unclassifiable (work preserved at $work)" >&2; return 1; fi
    restore_filter_legacy_xray_latest "$root" "$work" || { msg "restore gate failed: legacy-filter (work preserved at $work)" >&2; return 1; }
    preserved_latest_firewall_preflight "$work/preserved-latest-firewall.plan" || { msg "restore gate failed: legacy-fw-preflight (work preserved at $work)" >&2; return 1; }
    stop_managed_services_for_restore "$root" >/dev/null 2>&1 || { msg "restore gate failed: stop-services" >&2; rm -rf "$work"; return 1; }
    clean_nat_rules >/dev/null 2>&1 || { msg "restore gate failed: clean-nat" >&2; rm -rf "$work"; return 1; }
    clean_input_rules >/dev/null 2>&1 || { msg "restore gate failed: clean-input" >&2; rm -rf "$work"; return 1; }
    # R4C14-01: mount-compatibility check BEFORE any deletion.
    path_tree_has_nested_mountpoint "$ABOX_DIR" && { msg "restore gate failed: abox-dir-nested-mount" >&2; return 1; }
    remove_owned_core_families_for_restore "$root" || { msg "restore gate failed: remove-families (work preserved at $work)" >&2; return 1; }
    clear_abox_runtime_for_restore "$root" || { msg "restore gate failed: clear-runtime (work preserved at $work)" >&2; return 1; }
    restore_abox_directory "$root" || { msg "restore gate failed: restore-dir (work preserved at $work)" >&2; return 1; }
    local _mrc=0
    merge_retained_manifest_rows "$root" "$_manifest_snapshot"; _mrc=$?
    if [[ "$_mrc" == 1 ]]; then msg "restore gate failed: manifest-merge, rolled back (work preserved at $work; snapshot $_manifest_snapshot)" >&2; return 1; fi
    if [[ "$_mrc" != 0 ]]; then msg "restore gate failed: manifest-merge, rollback ALSO failed, live state undetermined (work preserved at $work; snapshot $_manifest_snapshot)" >&2; return 1; fi
    for srv in xray sing-box hysteria; do restore_core_family_from_backup "$root" "$srv" || { msg "restore gate failed: restore-family (work preserved at $work)" >&2; return 1; }; done
    local aux_paths=''
    aux_paths=$(managed_auxiliary_paths) || { msg "restore gate failed: aux-enum (work preserved at $work)" >&2; return 1; }
    while IFS= read -r path; do
        shortcut_is_managed_path "$path" && continue
        restore_auxiliary_path_from_backup "$root" "$path" || { msg "restore gate failed: restore-aux (work preserved at $work)" >&2; return 1; }
    done <<< "$aux_paths"
    regenerate_runtime_assets_after_restore "$root" >/dev/null 2>&1 || { msg "restore gate failed: regen-assets (work preserved at $work)" >&2; return 1; }
    validate_restored_zram_state
    apply_native_firewall_rules_from_state >/dev/null 2>&1 || { msg "restore gate failed: native-fw (work preserved at $work)" >&2; return 1; }
    backend=$(cat "$work/meta/firewall.backend" 2>/dev/null || echo iptables); [[ "$backend" == iptables ]] || mode=special
    restore_abox_iptables_snapshot "$work/meta/iptables.snapshot" 4 "$mode" || { msg "restore gate failed: iptables4 (work preserved at $work)" >&2; return 1; }
    restore_abox_iptables_snapshot "$work/meta/ip6tables.snapshot" 6 "$mode" || { msg "restore gate failed: iptables6 (work preserved at $work)" >&2; return 1; }
    restore_preserved_latest_firewall "$work/preserved-latest-firewall.plan" || { msg "restore gate failed: legacy-fw-replay (work preserved at $work)" >&2; return 1; }
    # X-08: a pre-deployment backup on a fresh host legitimately has no .env;
    # guard like regenerate_runtime_assets_after_restore does (L13851).
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        load_abox_env "$ABOX_ENV" >/dev/null 2>&1 || { msg "restore gate failed: load-env (work preserved at $work)" >&2; return 1; }
        if [[ -n "${SS_PORT:-}" ]]; then enforce_ss_whitelist_order "$SS_PORT" || { msg "restore gate failed: ss-order (work preserved at $work)" >&2; return 1; }; fi
    else
        clear_abox_env_vars
    fi
    save_firewall_rules >/dev/null 2>&1 || { msg "restore gate failed: save-fw (work preserved at $work)" >&2; return 1; }
    if [[ "${INIT_SYS:-}" == systemd ]]; then systemctl daemon-reload >/dev/null 2>&1 || { msg "restore gate failed: daemon-reload (work preserved at $work)" >&2; return 1; }; fi
    restore_managed_service_state "$work/meta/services.state" || { msg "restore gate failed: service-state (work preserved at $work)" >&2; return 1; }
    local preserved_note='' _latest_in_backup_rc=0
    backup_root_contains_service "$root" xray-latest; _latest_in_backup_rc=$?
    if [[ "$_latest_in_backup_rc" == 1 ]] && abox_owns_service xray-latest; then
        preserved_note=' (preserved: retired xray-latest instance left untouched)'
    fi
    report_restore_cron_status
    rm -rf "$work"; msg "${GREEN}[*] Rollback restored backup:${NC} $selected$preserved_note"
}

# R25-F-S1-05: legacy (pre-v3) backups carry no meta/manifest.version
# member (validate_legacy_backup_archive rejects archives that HAVE one).
# Returns 0 only when the archive lists successfully and has no such member;
# a corrupt/unreadable archive returns 1 so later checks fail as before.
backup_archive_is_legacy() {
    local archive="$1" _members
    _members=$(tar -tzf "$archive" 2>/dev/null) || return 1
    grep -Fxq 'meta/manifest.version' <<< "$_members" && return 1
    grep -Fxq './meta/manifest.version' <<< "$_members" && return 1
    return 0
}

restore_from_backup() {
    local backup_dir="$ABOX_DIR/backups" backups i choice selected work root answer backend mode=all srv path targets='' backups_output='' _own_brc=0
    # D-07: BusyBox find (Alpine) lacks -printf; python3 is already a hard
    # dependency, so enumerate by mtime in python (newest first). A missing
    # directory is skipped (as before); an unreadable directory or a stat
    # failure exits non-zero so the caller reports rb_enum_fail.
    if ! backups_output=$(
        python3 -I - "$ABOX_DIR/backups" /root/A-Box-backups <<'PY_RB_ENUM' || exit 1
import os, sys
_ents = []
for _d in sys.argv[1:]:
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
for _, _p in _ents:
    print(_p)
PY_RB_ENUM
    ); then
        msg "${RED}[!] $(tr_msg rb_enum_fail)${NC}"
        pause_return
        return
    fi
    backups=()
    [[ -z "$backups_output" ]] || mapfile -t backups <<< "$backups_output"
    (( ${#backups[@]} )) || { msg "${RED}[!] $(tprintf rb_none_found "$ABOX_DIR")${NC}"; pause_return; return; }
    clear
    for i in "${!backups[@]}"; do printf '%2d. %s\n' "$((i+1))" "${backups[$i]}"; done
    read -r -p "$(tr_msg rb_select)" choice
    choice=$(normalize_fa_ar_digits "${choice:-}")
    [[ "$choice" == 0 ]] && return
    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]] || ! valid_decimal_upto "$choice" "${#backups[@]}"; then
        msg "${RED}[!] $(tr_msg rb_invalid)${NC}"
        pause_return
        return
    fi
    selected="${backups[$((10#$choice-1))]}"
    # F01: verify-and-extract must use one pinned copy, not the
    # shared $selected path (a writer on the backup dir could
    # swap it between verify and tar). Copy the archive plus
    # its sidecars (same basenames, so every derived sidecar
    # and key path stays correct) into the private work dir
    # first; every later step uses the copy.
    work=$(mktemp -d /tmp/A-Box-restore.XXXXXX) || die "$(tr_msg rb_tmp_fail)"
    chmod 700 "$work"
    local _rbc="$work/$(basename "$selected")" _rbs=''
    cp -- "$selected" "$_rbc" || { rm -rf "$work"; die "$(tr_msg rb_tmp_fail)"; }
    chmod 600 "$_rbc" || { rm -rf "$work"; die "$(tr_msg rb_tmp_fail)"; }
    for _rbs in "${selected}.sha256" "${selected}.hmac" "${selected}.key"; do
        if [[ -e "$_rbs" ]]; then
            cp -- "$_rbs" "$work/$(basename "$_rbs")" || { rm -rf "$work"; die "$(tr_msg rb_tmp_fail)"; }
        fi
    done
    backup_checksum_verify "$_rbc" "${_rbc}.sha256" || { rm -rf -- "$work"; die "$(tr_msg rb_sha_bad)"; }
    # R25-F-S1-05: a legacy (manifest v2) backup has no HMAC sidecar, so
    # without this branch it dies below as rb_auth_fail; detect it here
    # and point at the option-4 converter instead of a misleading auth error.
    if backup_archive_is_legacy "$_rbc"; then rm -rf "$work"; die "$(tr_msg rb_legacy_convert)"; fi
    prepare_backup_auth_for_manual_restore "$_rbc" || { rm -rf -- "$work"; die "$(tr_msg rb_auth_fail)"; }
    validate_backup_archive "$_rbc" || { rm -rf -- "$work"; die "$(tr_msg rb_structure_fail)"; }
    tar -xzf "$_rbc" -C "$work" || { rm -rf "$work"; die "$(tr_msg rb_extract_fail)"; }
    root="$work/root"
    assert_restore_target_safe "$root" || { rm -rf "$work"; die "$(tr_msg rb_target_fail)"; }
    assert_restore_shortcut_safe "$root" || { rm -rf "$work"; die "$(tr_msg rb_shortcut_fail)"; }
    validate_backup_core_init_compatibility "$root" || { rm -rf "$work"; die "$(tr_msg rb_init_incompat)"; }
    msg "${YELLOW}[!] $(tr_msg rb_replace_note)${NC}"
    # R15-F14-02: a partial read (input 'y' then EOF) returns non-zero
    # with the content still stored; without checking $?, is_yes would
    # accept an unconfirmed answer and proceed to destructive steps.
    read -r -p "$(tr_msg rb_continue)" answer || { rm -rf "$work"; return; }
    is_yes "$answer" || { rm -rf "$work"; return; }

    ABOX_LAST_BACKUP=''
    backup_current_config "$backup_dir"
    [[ -n "$ABOX_LAST_BACKUP" && -f "$ABOX_LAST_BACKUP" ]] || { rm -rf "$work"; die "$(tr_msg rb_snapshot_fail)"; }
    # SYD-B6m: snapshot the live manifest BEFORE any destructive step;
    # clear + directory restore replace it with the backup manifest.
    local _manifest_snapshot="$work/live-manifest.tsv"
    if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
        [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || { rm -rf "$work"; die 'Live ownership manifest is not a safe regular file; restore was not started.'; }
        # SYD-B7: validate the live manifest BEFORE any destructive step.
        [[ "$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { rm -rf "$work"; die 'Live ownership manifest exceeds size limit; restore was not started.'; }
        _manifest_rows_valid "$ABOX_CORE_OWNERSHIP" || { rm -rf "$work"; die 'Live ownership manifest rows are invalid; restore was not started.'; }
        cp -a -- "$ABOX_CORE_OWNERSHIP" "$_manifest_snapshot" || { rm -rf "$work"; die 'Restore manifest snapshot failed; restore was not started.'; }
        chmod 600 "$_manifest_snapshot" || { rm -rf "$work"; die 'Restore manifest snapshot failed; restore was not started.'; }
    fi
    for srv in xray sing-box hysteria; do
        if abox_owns_service "$srv" || backup_root_contains_service "$root" "$srv"; then
            targets+=" ${srv}"
        fi
    done
    ABOX_DEPLOY_TX_ACTIVE=1
    ABOX_DEPLOY_TX_REASON='manual backup restore'
    ABOX_DEPLOY_TX_TARGETS="${targets# }"
    ABOX_DEPLOY_TX_BACKUP="$ABOX_LAST_BACKUP"
    ABOX_DEPLOY_TX_TMP="$work"
    ABOX_DEPLOY_TX_OWNER=$BASHPID
    ABOX_DIE_HOOK=deployment_transaction_rollback
    install_deployment_transaction_traps

    # C2 (D3/D4): detection only here -- restore never prompts or retires
    # a live instance. An unclassifiable live layout fails the restore.
    _c2_xl_detect_rc=0
    xray_latest_legacy_detect >/dev/null 2>&1 || _c2_xl_detect_rc=$?
    if (( _c2_xl_detect_rc == 2 )); then rm -rf "$work"; die "$(tr_msg restore_from_backup_legacy_layout_unclassified)"; fi
    restore_filter_legacy_xray_latest "$root" "$work" || { rm -rf "$work"; die "$(tr_msg restore_from_backup_legacy_filter_fail)"; }
    preserved_latest_firewall_preflight "$work/preserved-latest-firewall.plan" || { rm -rf "$work"; die "$(tr_msg restore_from_backup_legacy_firewall_preflight_fail)"; }
    stop_managed_services_for_restore "$root" || die "$(tr_msg restore_from_backup_stop_services_fail)"
    clean_nat_rules || die "$(tr_msg restore_from_backup_clean_nat_fail)"
    clean_input_rules || die "$(tr_msg restore_from_backup_clean_input_fail)"
    # R4C14-01: mount-compatibility check BEFORE any deletion.
    path_tree_has_nested_mountpoint "$ABOX_DIR" && die 'Restore refused: nested mount under A-Box directory.'
    remove_owned_core_families_for_restore "$root" || die "$(tr_msg restore_from_backup_remove_cores_fail)"
    clear_abox_runtime_for_restore "$root" || die "$(tr_msg restore_from_backup_clear_runtime_fail)"
    restore_abox_directory "$root" || die 'Restore A-Box directory failed.'
    local _mrc=0
    merge_retained_manifest_rows "$root" "$_manifest_snapshot"; _mrc=$?
    if [[ "$_mrc" == 1 ]]; then die 'Restore manifest merge for preserved families failed; live manifest restored from snapshot, restore was not committed.'; fi
    if [[ "$_mrc" != 0 ]]; then die "Restore manifest merge for preserved families failed AND rollback failed; live manifest state undetermined (snapshot $_manifest_snapshot), restore was not committed."; fi
    for srv in xray sing-box hysteria; do
        restore_core_family_from_backup "$root" "$srv" || die "Restore failed for core family: $srv"
    done
    local aux_paths=''
    aux_paths=$(managed_auxiliary_paths) || die "$(tr_msg restore_from_backup_aux_enum_fail)"
    while IFS= read -r path; do
        shortcut_is_managed_path "$path" && continue
        restore_auxiliary_path_from_backup "$root" "$path" || die "Restore failed: $path"
    done <<< "$aux_paths"
    chmod 711 "$ABOX_DIR" 2>/dev/null || die "$(tr_msg restore_from_backup_dir_perm_fail)"
    # X-08: restoring an initial backup (no .env) must not die here.
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        chmod 600 "$ABOX_ENV" 2>/dev/null || die "$(tr_msg restore_from_backup_env_perm_fail)"
    fi
    if [[ -e "$ABOX_DIR/.shortcut" || -L "$ABOX_DIR/.shortcut" ]]; then
        [[ -f "$ABOX_DIR/.shortcut" && ! -L "$ABOX_DIR/.shortcut" ]] || die "$(tr_msg restore_from_backup_shortcut_type_fail)"
        chown root:root "$ABOX_DIR/.shortcut" 2>/dev/null || die "$(tr_msg restore_from_backup_shortcut_owner_fail)"
        chmod 600 "$ABOX_DIR/.shortcut" 2>/dev/null || die "$(tr_msg restore_from_backup_shortcut_perm_fail)"
    fi
    regenerate_runtime_assets_after_restore "$root" || die 'Regenerate trusted A-Box runtime helpers and cron blocks failed.'
    validate_restored_zram_state
    apply_native_firewall_rules_from_state || die 'Restore native firewall rules failed.'
    backend=$(cat "$work/meta/firewall.backend" 2>/dev/null || echo iptables)
    [[ "$backend" == iptables ]] || mode=special
    restore_abox_iptables_snapshot "$work/meta/iptables.snapshot" 4 "$mode" || die 'IPv4 A-Box firewall restore failed.'
    restore_abox_iptables_snapshot "$work/meta/ip6tables.snapshot" 6 "$mode" || die 'IPv6 A-Box firewall restore failed.'
    restore_preserved_latest_firewall "$work/preserved-latest-firewall.plan" || die "$(tr_msg restore_from_backup_legacy_firewall_restore_fail)"
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        load_abox_env "$ABOX_ENV" >/dev/null 2>&1 || die "$(tr_msg restore_from_backup_env_verify_fail)"
        if [[ -n "${SS_PORT:-}" ]]; then enforce_ss_whitelist_order "$SS_PORT" || die 'Restored SS whitelist order validation failed.'; fi
    else
        clear_abox_env_vars
    fi
    save_firewall_rules || die 'Restored A-Box firewall persistence failed.'
    if [[ "${INIT_SYS:-}" == systemd ]]; then systemctl daemon-reload >/dev/null 2>&1 || die 'systemd daemon-reload after restore failed.'; fi
    restore_managed_service_state "$work/meta/services.state" || die 'Restored service state failed validation/startup.'
    # M-18 (supplement): a restored hopping hysteria on a host without
    # nft needs the grant script, which old backups never contained;
    # without it the service starts but the hop rules are never built,
    # silently. Warn explicitly instead of leaving the degraded hop
    # undiscovered; redeploying official Hy2 re-creates the grant.
    if abox_owns_service hysteria && [[ "${HY2_HOP:-}" == 'true' && "${HY2_HOP_IMPL:-none}" == 'official' ]] && ! command -v nft >/dev/null 2>&1 && [[ ! -f /usr/local/bin/abox-hy2-xtables-lock-grant || -L /usr/local/bin/abox-hy2-xtables-lock-grant ]]; then
        msg "${RED}[!] Restored Hysteria 2 port hopping is enabled but the xtables-lock grant script (/usr/local/bin/abox-hy2-xtables-lock-grant) is missing; on this host (no nft) the service user cannot open /run/xtables.lock, so hop rules will not be built. Redeploy official Hysteria 2 to restore the grant.${NC}"
    fi
    for srv in xray sing-box hysteria; do
        if abox_owns_service "$srv"; then
            backup_root_contains_service "$root" "$srv"; _own_brc=$?
            if [[ "$_own_brc" == 0 ]]; then
                record_core_family_ownership "$srv" || die "Restored ${srv} ownership manifest update failed; restore was not committed."
            elif [[ "$_own_brc" != 1 ]]; then
                die "Restored ${srv} backup containment check failed; restore was not committed."
            fi
        fi
    done
    local preserved_note='' _latest_in_backup_rc=0
    backup_root_contains_service "$root" xray-latest; _latest_in_backup_rc=$?
    if [[ "$_latest_in_backup_rc" == 1 ]] && abox_owns_service xray-latest; then
        preserved_note=' (preserved: retired xray-latest instance left untouched)'
    fi
    # M-10(2): second insurance that the restored directory keeps the
    # 0711 traverse bit the non-root service users need (see
    # ensure_abox_dir_owned). Dies on failure, before the transaction
    # is committed, so a bad mode cannot be reported as restored.
    ensure_abox_dir_owned "$ABOX_DIR"
    commit_deployment_transaction
    rm -rf "$work"
    report_restore_cron_status
    msg "${GREEN}[*] $(tr_msg rb_done)${NC}$preserved_note"
    pause_return
}

backup_restore_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg backup_restore_menu_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
        msg "${CYAN}1.${NC} Backup current A-Box configuration"
        msg "${CYAN}2.${NC} Restore from backup"
        msg "${CYAN}3.${NC} Export recovery key to a separate medium"
        msg "${CYAN}4.${NC} Convert a legacy backup to manifest v3"
        msg "${CYAN}5.${NC} Clean up separated recovery keys"
        msg "${CYAN}0.${NC} Back"
            ;;
        ru)
        msg "${CYAN}1.${NC} Резервное копирование текущей конфигурации A-Box"
        msg "${CYAN}2.${NC} Восстановление из резервной копии"
        msg "${CYAN}3.${NC} Экспорт ключа восстановления на отдельный носитель"
        msg "${CYAN}4.${NC} Конвертация старой резервной копии в manifest v3"
        msg "${CYAN}5.${NC} Очистка отделённых ключей восстановления"
        msg "${CYAN}0.${NC} Назад"
            ;;
        fa)
        msg "${CYAN}1.${NC} پشتیبان‌گیری از پیکربندی فعلی A-Box"
        msg "${CYAN}2.${NC} بازیابی از پشتیبان"
        msg "${CYAN}3.${NC} صدور کلید بازیابی به رسانه جداگانه"
        msg "${CYAN}4.${NC} تبدیل پشتیبان قدیمی به manifest v3"
        msg "${CYAN}5.${NC} پاک‌سازی کلیدهای بازیابی جداگانه"
        msg "${CYAN}0.${NC} بازگشت"
            ;;
        ja)
            msg "${CYAN}1.${NC} 現在の A-Box 設定をバックアップ"
            msg "${CYAN}2.${NC} バックアップから復元"
            msg "${CYAN}3.${NC} 復旧キーを別の媒体にエクスポート"
            msg "${CYAN}4.${NC} 旧バージョンのバックアップを manifest v3 に安全に変換"
            msg "${CYAN}5.${NC} 分離された復旧キーをクリーンアップ"
            msg "${CYAN}0.${NC} 戻る"
            ;;
        zh-tw)
        msg "${CYAN}1.${NC} 備份當前 A-Box 配置"
        msg "${CYAN}2.${NC} 從備份恢復"
        msg "${CYAN}3.${NC} 將恢復金鑰匯出到獨立介質"
        msg "${CYAN}4.${NC} 將舊版備份安全轉換為 manifest v3"
        msg "${CYAN}5.${NC} 清理分離的復原金鑰"
        msg "${CYAN}0.${NC} 返回"
            ;;
        *)
        msg "${CYAN}1.${NC} 备份当前 A-Box 配置"
        msg "${CYAN}2.${NC} 从备份恢复"
        msg "${CYAN}3.${NC} 将恢复密钥导出到独立介质"
        msg "${CYAN}4.${NC} 将旧版备份安全转换为 manifest v3"
        msg "${CYAN}5.${NC} 清理分离的恢复密钥"
        msg "${CYAN}0.${NC} 返回"
            ;;
    esac
    local c
    read -r -p "$(tr_msg bk_select_0_5)" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) backup_current_config; pause_return ;;
        2) restore_from_backup ;;
        3)
            local key_dest
            read -r -p "$(tr_msg bk_key_dest)" key_dest || return 0
            export_backup_recovery_key "$key_dest"; pause_return
            ;;
        4)
            local legacy_path legacy_out
            read -r -p "$(tr_msg bk_legacy_path)" legacy_path || return 0
            read -r -p "$(tr_msg bk_legacy_out)" legacy_out || return 0
            convert_legacy_backup_archive "$legacy_path" "${legacy_out:-$(dirname "$legacy_path")}"; pause_return
            ;;
        5)
            # H6 (R52-02 = L12): the only separated-key deletion entry.
            cleanup_separated_backup_keys; pause_return
            ;;
        0|'') return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}

write_diagnostic_checksum() {
    local bundle="$1" checksum="$2" tmp dir
    [[ -f "$bundle" && ! -L "$bundle" ]] || return 1
    [[ ! -L "$checksum" && (! -e "$checksum" || -f "$checksum") ]] || return 1
    path_parent_chain_safe "$checksum" || return 1
    dir=$(dirname "$checksum")
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    tmp=$(mktemp "${checksum}.A-Box-new.XXXXXX") || return 1
    if ! sha256sum "$bundle" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    if [[ $EUID -eq 0 ]]; then
        chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    mv -f -- "$tmp" "$checksum" || { rm -f -- "$tmp"; return 1; }
    [[ -s "$checksum" && ! -L "$checksum" ]] || return 1
    return 0
}

export_diagnostic_bundle() {
    local ts diag_dir work bundle checksum tmp_bundle
    local _diag_n_generated _diag_n_redacted _diag_n_omitted _diag_n_absent _diag_n_failed
    local _unit _rel _red_rcs _red_rc _jrc _trc _jnote _tnote _gf
    ts=$(date +%Y%m%d-%H%M%S)
    diag_dir="$ABOX_DIR/diagnostics"
    work=$(mktemp -d /tmp/A-Box-diagnostic.XXXXXX) || die 'Diagnostic temp directory creation failed.'
    if [[ -L "$diag_dir" ]]; then rm -rf -- "$work"; die "$(tr_msg export_diagnostic_bundle_symlink_refused)"; fi
    mkdir -p "$diag_dir" "$work/logs" || { rm -rf -- "$work"; die "$(tr_msg export_diagnostic_bundle_mkdir_failed)"; }
    chmod 700 "$diag_dir" 2>/dev/null || { rm -rf -- "$work"; die "$(tr_msg export_diagnostic_bundle_chmod_failed)"; }
    # R5C14-01: refuse a diagnostic directory not owned by root;
    # an attacker-owned directory lets its owner swap symlinks in.
    [[ "$(stat -c %u "$diag_dir" 2>/dev/null || echo -1)" == 0 ]] || { rm -rf -- "$work"; die "$(tr_msg export_diagnostic_bundle_nonroot_refused)"; }

    msg "${YELLOW}[*] Collecting diagnostic information with secret redaction...${NC}"
    # D2: per-file redaction/omission manifest. Every file in the bundle
    # is listed with what happened to it during collection, so a reader
    # can tell a redacted copy from a suppressed (notice-only) document,
    # a missing source, or a file removed after a redaction failure.
    _diag_n_generated=0 _diag_n_redacted=0 _diag_n_omitted=0 _diag_n_absent=0 _diag_n_failed=0
    {
        echo 'A-Box diagnostic bundle - per-file redaction record'
        echo 'Statuses: generated = command output, not passed through the redactor;'
        echo 'redacted = secrets redacted, original values not included;'
        echo 'omitted = whole document suppressed (redactor could not verify its content), notice only;'
        echo 'absent = source not available, file not in the bundle (or placeholder only);'
        echo 'failed = redaction failed, file removed from the bundle.'
        echo
    } > "$work/omissions.txt"
    {
        echo "A-Box diagnostic bundle"
        echo "Created: $(now_iso)"
        echo "Host: $(hostname 2>/dev/null || true)"
        echo "Script: $0"
        echo "Script SHA256: $(sha256sum "$0" 2>/dev/null | awk '{print $1}')"
    } > "$work/summary.txt"

    { uname -a 2>/dev/null; echo; cat /etc/os-release 2>/dev/null || true; echo; command -v systemctl >/dev/null 2>&1 && systemctl --version 2>/dev/null | head -n 3 || true; } > "$work/system.txt"
    { ip addr 2>/dev/null || true; echo; ip route 2>/dev/null || true; echo; ip -6 route 2>/dev/null || true; echo; ss -lntup 2>/dev/null || true; } > "$work/network.txt"
    { show_status_report 2>/dev/null || true; echo; for c in xray sing-box hysteria; do command -v "$c" >/dev/null 2>&1 && "$c" version 2>/dev/null | head -n 5; done; } > "$work/status.txt"
    { iptables -S 2>/dev/null | grep 'A-Box' || true; echo; iptables -t nat -S 2>/dev/null | grep 'A-Box' || true; echo; ip6tables -S 2>/dev/null | grep 'A-Box' || true; echo; ip6tables -t nat -S 2>/dev/null | grep 'A-Box' || true; } > "$work/firewall.txt"
    collect_abox_cron > "$work/cron.txt" 2>/dev/null || true
    for _gf in summary.txt system.txt network.txt status.txt firewall.txt cron.txt; do
        _diagnostic_record "$work/omissions.txt" "$_gf" 'generated' 'command output, not passed through the redactor'
    done
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        write_redacted_file "$ABOX_ENV" "$work/env.redacted" || { rm -rf "$work"; die 'Diagnostic secret redaction failed; refusing to create a misleading bundle.'; }
        case "$WRITE_REDACTED_FILE_STATUS" in
            redacted) _diagnostic_record "$work/omissions.txt" 'env.redacted' 'redacted' 'secrets redacted' ;;
            omitted) _diagnostic_record "$work/omissions.txt" 'env.redacted' 'omitted' 'whole document suppressed: python3 unavailable; diagnostic redaction cannot be verified; notice only' ;;
            absent) _diagnostic_record "$work/omissions.txt" 'env.redacted' 'absent' 'source became unreadable during collection' ;;
        esac
    else
        printf '%s\n' 'A-Box environment file is not present.' > "$work/env.redacted" || { rm -rf "$work"; die 'Diagnostic environment placeholder creation failed.'; }
        _diagnostic_record "$work/omissions.txt" 'env.redacted' 'absent' 'source file not present; placeholder only'
    fi

    if command -v journalctl >/dev/null 2>&1; then
        for _unit in xray sing-box hysteria; do
            journalctl -u "$_unit" --no-pager -n 120 2>/dev/null | redact_secrets_stream > "$work/logs/${_unit}.journal.txt"
            _red_rcs=("${PIPESTATUS[@]}")
            _red_rc=${_red_rcs[1]:-1} _jrc=${_red_rcs[0]:-1}
            if [[ "$_red_rc" == 0 ]]; then
                _jnote="journalctl -u ${_unit} -n 120"
                [[ "$_jrc" != 0 ]] && _jnote="${_jnote}; journalctl exited ${_jrc}, output may be empty"
                _diagnostic_record "$work/omissions.txt" "logs/${_unit}.journal.txt" 'redacted' "$_jnote"
            elif [[ "$_red_rc" == 2 ]]; then
                _diagnostic_record "$work/omissions.txt" "logs/${_unit}.journal.txt" 'omitted' 'whole document suppressed: python3 unavailable; diagnostic redaction cannot be verified; notice only'
            else
                rm -f -- "$work/logs/${_unit}.journal.txt"
                _diagnostic_record "$work/omissions.txt" "logs/${_unit}.journal.txt" 'failed' "redaction failed (rc=${_red_rc}); file removed"
            fi
        done
    else
        for _unit in xray sing-box hysteria; do
            _diagnostic_record "$work/omissions.txt" "logs/${_unit}.journal.txt" 'absent' 'journalctl not available'
        done
    fi
    for f in /var/log/A-Box-xray-error.log /var/log/A-Box-xray-access.log /var/log/A-Box-singbox.log /var/log/A-Box-hysteria.log; do
        _rel="logs/$(basename "$f").tail.txt"
        if [[ -r "$f" ]]; then
            tail -n 200 "$f" 2>/dev/null | redact_secrets_stream > "$work/${_rel}"
            _red_rcs=("${PIPESTATUS[@]}")
            _red_rc=${_red_rcs[1]:-1} _trc=${_red_rcs[0]:-1}
            if [[ "$_red_rc" == 0 ]]; then
                _tnote="tail -n 200 $f"
                [[ "$_trc" != 0 ]] && _tnote="${_tnote}; tail exited ${_trc}, output may be empty"
                _diagnostic_record "$work/omissions.txt" "$_rel" 'redacted' "$_tnote"
            elif [[ "$_red_rc" == 2 ]]; then
                _diagnostic_record "$work/omissions.txt" "$_rel" 'omitted' 'whole document suppressed: python3 unavailable; diagnostic redaction cannot be verified; notice only'
            else
                rm -f -- "$work/${_rel}"
                _diagnostic_record "$work/omissions.txt" "$_rel" 'failed' "redaction failed (rc=${_red_rc}); file removed"
            fi
        else
            _diagnostic_record "$work/omissions.txt" "$_rel" 'absent' 'source log not readable'
        fi
    done

    printf 'Counts: %s files: %s generated, %s redacted, %s omitted, %s absent, %s failed\n' \
        "$(( _diag_n_generated + _diag_n_redacted + _diag_n_omitted + _diag_n_absent + _diag_n_failed ))" \
        "$_diag_n_generated" "$_diag_n_redacted" "$_diag_n_omitted" "$_diag_n_absent" "$_diag_n_failed" \
        >> "$work/omissions.txt"

    if [[ "$_diag_n_omitted" -gt 0 ]]; then
        msg "${YELLOW}[!] $(tr_msg diag_redaction_limited)${NC}"
    fi

    bundle="$diag_dir/A-Box-diagnostic-${ts}.tar.gz"
    # Re-check immediately before writing: a symlink swapped in after
    # the first check (or a pre-placed bundle symlink) is refused
    # here. R5C14-01: tar no longer writes the predictable path
    # directly; it writes a private mktemp file in the same
    # directory and renames it over the bundle, so even a swap
    # between this check and the rename cannot be followed:
    # rename replaces the symlink entry instead of its target.
    if [[ -L "$diag_dir" || -L "$bundle" ]]; then rm -rf -- "$work"; die "$(tr_msg export_diagnostic_bundle_target_symlink_refused)"; fi
    tmp_bundle=$(mktemp "$diag_dir/.A-Box-diagnostic-${ts}.XXXXXX") || { rm -rf -- "$work"; die 'Diagnostic bundle temp file creation failed.'; }
    tar -C "$work" -czf "$tmp_bundle" . || { rm -rf -- "$work"; rm -f "$tmp_bundle"; die 'Diagnostic bundle creation failed.'; }
    chmod 600 "$tmp_bundle" 2>/dev/null || { rm -rf -- "$work"; rm -f "$tmp_bundle"; die 'Diagnostic bundle permission hardening failed.'; }
    mv -f "$tmp_bundle" "$bundle" || { rm -rf -- "$work"; rm -f "$tmp_bundle"; die 'Diagnostic bundle atomic rename failed.'; }
    checksum="${bundle}.sha256"
    write_diagnostic_checksum "$bundle" "$checksum" || { rm -rf "$work"; rm -f "$bundle"; die 'Diagnostic bundle checksum generation failed.'; }
    rm -rf "$work"
    msg "${GREEN}[*] Diagnostic bundle:${NC}" $bundle
    msg "${GREEN}[*] SHA256:${NC}" $checksum
    pause_return
}


default_route_uses_warp() {
    local dev=''
    dev=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    [[ "$dev" =~ ^(wg|warp|tun|CloudflareWARP)[0-9A-Za-z_.-]*$ ]]
}


light_preflight_check() {
    local fail=0 warn=0 c
    msg "${YELLOW}[*] $(tr_msg pf_running)${NC}"
    [[ $EUID -eq 0 ]] || { msg "${RED}[FAIL] $(tr_msg pf_root)${NC}"; fail=$((fail+1)); }
    [[ -t 0 ]] || { msg "${YELLOW}[WARN] $(tr_msg pf_notty)${NC}"; warn=$((warn+1)); }
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in debian|ubuntu|centos|rhel|rocky|almalinux|alpine|fedora|amzn|ol|oracle) msg "${GREEN}[PASS] OS: ${ID:-unknown}${NC}" ;; *) msg "${YELLOW}[WARN] $(tprintf pf_os_maybe "${ID:-unknown}")${NC}"; warn=$((warn+1)) ;; esac
    else
        msg "${YELLOW}[WARN] $(tr_msg pf_os_unreadable)${NC}"; warn=$((warn+1))
    fi
    local route_dev warp_confirm=''
    route_dev=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if default_route_uses_warp; then
        msg "${YELLOW}[WARN] $(tprintf pf_warp_route "$route_dev")${NC}"
        if [[ -t 0 ]]; then
            read -r -p "$(tr_msg pf_warp_confirm)" warp_confirm || warp_confirm='N'
            is_yes "$warp_confirm" || { msg "${RED}[FAIL] $(tr_msg pf_warp_unconfirmed)${NC}"; fail=$((fail+1)); }
        else
            msg "${RED}[FAIL] $(tr_msg pf_warp_noninteractive)${NC}"
            fail=$((fail+1))
        fi
    fi
    if systemd_available; then
        msg "${GREEN}[PASS] init: systemd${NC}"
    elif command -v rc-service >/dev/null 2>&1; then
        msg "${GREEN}[PASS] init: OpenRC${NC}"
    else
        msg "${RED}[FAIL] $(tr_msg pf_no_init)${NC}"; fail=$((fail+1))
    fi
    case "$(uname -m)" in x86_64|amd64|aarch64|arm64) msg "${GREEN}[PASS] arch: $(uname -m)${NC}" ;; *) msg "${RED}[FAIL] $(tprintf pf_bad_arch "$(uname -m)")${NC}"; fail=$((fail+1)) ;; esac
    for c in bash curl jq openssl unzip tar iptables ss lsof python3 getent flock qrencode fail2ban-client; do
        command -v "$c" >/dev/null 2>&1 || { msg "${YELLOW}[WARN] $(tprintf pf_cmd_missing "$c")${NC}"; warn=$((warn+1)); }
    done
    if curl -fsS --connect-timeout 3 -m 6 https://api.github.com >/dev/null 2>&1; then
        msg "${GREEN}[PASS] $(tr_msg pf_gh_ok)${NC}"
    else
        msg "${YELLOW}[WARN] $(tr_msg pf_gh_bad)${NC}"; warn=$((warn+1))
    fi
    if (( fail > 0 )); then
        die "$(tr_msg pf_blocked)"
    fi
    msg "${GREEN}[*] $(tprintf pf_done "$warn")${NC}"
}



validate_test_script() {
    local file="$1" size first
    [[ -f "$file" && ! -L "$file" ]] || return 1
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ') || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && # D-3: Align with update-mirrors.yml (2MB max).
    (( size >= 1000 && size <= 2000000 )) || return 1
    IFS= read -r first < "$file" || return 1
    [[ "$first" =~ ^#!.*(bash|env[[:space:]]+bash)([[:space:]]|$) ]] || return 1
    if head -n 25 "$file" | grep -Eiq '<!doctype[[:space:]]+html|<html'; then return 1; fi
    bash -n "$file" >/dev/null 2>&1 || return 1
}

run_mirrored_test_script() {
    local label="$1" upstream_url="$2" asset="$3" selected='' source='' expected='' sha='' answer work run_prompt
    shift 3
    work=$(abox_mktemp_exec_dir A-Box-test-tool) || return 1
    chmod 700 "$work" || { rm -rf -- "$work"; return 1; }
    local upstream="$work/upstream.sh" mirror="$work/mirror.sh" sums="$work/SHA256SUMS" manifest="$work/manifest.txt"
    # Policy: latest-first (user directive). The upstream script is
    # structurally validated (validate_test_script); on any failure the
    # pinned, signature-verified mirror copy is the fallback.
    if curl -fLsS --proto =https --proto-redir =https --retry 1 --connect-timeout 10 --max-time 180 "$upstream_url" -o "$upstream" && validate_test_script "$upstream"; then
        selected="$upstream"
        source="$upstream_url (LIVE latest)"
    fi
    if [[ -z "$selected" ]]; then
        rm -f -- "$upstream"
        case "${ABOX_LANG:-zh}" in
            en) msg "${YELLOW}[!] Upstream latest unavailable or failed validation; falling back to the pinned A-Box verified mirror.${NC}" ;;
            ru) msg "${YELLOW}[!] Актуальная версия upstream недоступна или не прошла проверку; переход к закреплённому проверенному зеркалу A-Box.${NC}" ;;
            fa) msg "${YELLOW}[!] آخرین نسخه upstream در دسترس نیست یا تأیید نشد؛ بازگشت به آینه تأییدشده و سنجاق‌شده A-Box.${NC}" ;;
            zh-tw) msg "${YELLOW}[!] 上游最新版不可用或校驗未通過，回退到 A-Box 釘版校驗鏡像。${NC}" ;;
            ja) msg "${YELLOW}[!] upstream の最新版が利用できないか検証に失敗しました。固定された A-Box 検証済みミラーにフォールバックします。${NC}" ;;
            *) msg "${YELLOW}[!] 上游最新版不可用或校验未通过，回退到 A-Box 钉版校验镜像。${NC}" ;;
        esac
        local sums_dl_ok=0 sig_dl_ok=0
        if curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 45 \
            "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/SHA256SUMS" -o "$sums"; then
            sums_dl_ok=1
        fi
        if curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 45 \
            "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/SHA256SUMS.sig" -o "$sums.sig" 2>/dev/null; then
            sig_dl_ok=1
        fi
        # P3-02: fail-closed - use verify_ed25519_detached directly (not the
        # degradable gate). Missing .sig or failed verification blocks execution.
        if (( sums_dl_ok == 1 )); then
            if (( sig_dl_ok == 0 )) || ! verify_ed25519_detached "$sums" "$sums.sig" >/dev/null 2>&1; then
                rm -f -- "$sums" "$sums.sig"
                sums_dl_ok=0
            fi
        fi
        if (( sums_dl_ok == 1 )) && curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 45 \
            "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/test-tools-manifest.txt" -o "$manifest" &&
           curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 180 \
            "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/$asset" -o "$mirror"; then
            # Verify manifest digest (manifest is covered by SHA256SUMS signature)
            local manifest_expected manifest_sha
            manifest_expected=$(awk -v f="test-tools-manifest.txt" '$2==f || $2==("*" f) {print $1; exit}' "$sums")
            manifest_sha=$(sha256sum "$manifest" 2>/dev/null | awk '{print $1}')
            if [[ ! "$manifest_expected" =~ ^[A-Fa-f0-9]{64}$ || "${manifest_sha,,}" != "${manifest_expected,,}" ]]; then
                # Manifest digest mismatch - do not trust manifest content
                rm -f -- "$manifest"
            fi
            expected=$(awk -v f="$asset" '$2==f || $2==("*" f) {print $1; exit}' "$sums")
            sha=$(sha256sum "$mirror" | awk '{print $1}')
            if [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ && "${sha,,}" == "${expected,,}" ]] && validate_test_script "$mirror"; then
                selected="$mirror"
                source="A-Box Release $ABOX_TEST_MIRROR_RELEASE"
            fi
        fi
        fi
    if [[ -z "$selected" ]]; then
        rm -rf -- "$work"
case "${ABOX_LANG:-zh}" in
                en) msg "${RED}Upstream and A-Box recovery sources are unavailable; the script was not run.${NC}" ;;
                ru) msg "${RED}Основной и резервный источники недоступны; скрипт не запускался.${NC}" ;;
                fa) msg "${RED}منبع اصلی و پشتیبان در دسترس نیستند؛ اسکریپت اجرا نشد.${NC}" ;;
                zh-tw) msg "${RED}上游與 A-Box 災備源均不可用；未執行指令碼。${NC}" ;;
                ja)
                    msg "${RED}upstream と A-Box のリカバリーソースを利用できません。スクリプトは実行されませんでした。${NC}" ;;
                *) msg "${RED}上游与 A-Box 灾备源均不可用；未执行脚本。${NC}" ;;
            esac
        return 1
    fi
    sha=$(sha256sum "$selected" | awk '{print $1}')
    case "${ABOX_LANG:-zh}" in
        en) msg "${CYAN}Test tool: $label${NC}"; msg "${CYAN}Source: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='Execute this third-party test script? It may contact external endpoints and generate network traffic. [Y/N]: ' ;;
        ru) msg "${CYAN}Тест: $label${NC}"; msg "${CYAN}Источник: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='Запустить сторонний тестовый скрипт? Он может обращаться к внешним узлам и создавать сетевой трафик. [Y/N]: ' ;;
        fa) msg "${CYAN}ابزار آزمون: $label${NC}"; msg "${CYAN}منبع: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='اسکریپت آزمون شخص ثالث اجرا شود؟ ممکن است به مقصدهای بیرونی متصل شود و ترافیک ایجاد کند. [Y/N]: ' ;;
        zh-tw) msg "${CYAN}測試工具: $label${NC}"; msg "${CYAN}來源: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='即將執行第三方測試指令碼。它可能訪問外部檢測端點併產生網路流量；確認執行？[Y/N]: ' ;;
        ja)
            msg "${CYAN}テストツール: $label${NC}"; msg "${CYAN}ソース: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='このサードパーティー製テストスクリプトを実行しますか？外部エンドポイントに接続し、ネットワークトラフィックを発生させる可能性があります。[Y/N]: ' ;;
        *) msg "${CYAN}测试工具: $label${NC}"; msg "${CYAN}来源: $source${NC}"; msg "${CYAN}SHA256: $sha${NC}"; run_prompt='即将执行第三方测试脚本。它可能访问外部检测端点并产生网络流量；确认执行？[Y/N]: ' ;;
    esac
    if [[ "$selected" == "$mirror" ]]; then cat "$manifest" 2>/dev/null | head -12; fi
    # W4-tb2: bench.sh downloads speedtest-cli with wget (upstream lines
    # 333/334); on a host without wget it fails mid-benchmark with no
    # speedtest results. Refuse upfront with the missing command named
    # instead of asking the user to confirm a run that cannot succeed.
    # Scoped to bench.sh only: other mirrored scripts have their own
    # dependencies (tb3 owns whiptail for Check.Place.sh).
    if [[ "$asset" == 'bench.sh' ]] && ! command -v wget >/dev/null 2>&1; then
        rm -rf -- "$work"
        msg "${RED}$(tprintf ec_missing 'wget (bench.sh)')${NC}"
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}bench.sh needs wget to download speedtest-cli. Install wget and retry.${NC}" ;;
            ru) msg "${RED}bench.sh нужен wget для загрузки speedtest-cli. Установите wget и повторите попытку.${NC}" ;;
            fa) msg "${RED}bench.sh برای دانلود speedtest-cli به wget نیاز دارد. wget را نصب کنید و دوباره تلاش کنید.${NC}" ;;
            zh-tw) msg "${RED}bench.sh 需要 wget 才能下載 speedtest-cli。請安裝 wget 後重試。${NC}" ;;
            ja) msg "${RED}bench.sh は speedtest-cli のダウンロードに wget が必要です。wget をインストールして再試行してください。${NC}" ;;
            *) msg "${RED}bench.sh 需要 wget 才能下载 speedtest-cli。请安装 wget 后重试。${NC}" ;;
        esac
        return 1
    fi
    # W4-tb3b: Check.Place.sh needs whiptail for its interactive menu; on a
    # host without whiptail the upstream script stalls at an interactive apt
    # prompt (W4-tb3 note) instead of running. Refuse upfront with the
    # missing command named instead of asking the user to confirm a run
    # that cannot succeed. Scoped to Check.Place.sh only: other mirrored
    # scripts have their own dependencies (tb2 owns wget for bench.sh).
    if [[ "$asset" == 'Check.Place.sh' ]] && ! command -v whiptail >/dev/null 2>&1; then
        rm -rf -- "$work"
        msg "${RED}$(tprintf ec_missing 'whiptail (Check.Place.sh)')${NC}"
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}Check.Place.sh needs whiptail to show its interactive menu. Install whiptail and retry.${NC}" ;;
            ru) msg "${RED}Check.Place.sh нужен whiptail для отображения интерактивного меню. Установите whiptail и повторите попытку.${NC}" ;;
            fa) msg "${RED}Check.Place.sh برای نمایش منوی تعاملی به whiptail نیاز دارد. whiptail را نصب کنید و دوباره تلاش کنید.${NC}" ;;
            zh-tw) msg "${RED}Check.Place.sh 需要 whiptail 才能顯示互動式選單。請安裝 whiptail 後重試。${NC}" ;;
            ja) msg "${RED}Check.Place.sh は対話式メニューの表示に whiptail が必要です。whiptail をインストールして再試行してください。${NC}" ;;
            *) msg "${RED}Check.Place.sh 需要 whiptail 才能显示交互式菜单。请安装 whiptail 后重试。${NC}" ;;
        esac
        return 1
    fi
    if ! confirm_yes_no "$run_prompt"; then
        rm -rf -- "$work"
        return 130
    fi
    chmod 600 "$selected"
    env -i PATH="$PATH" HOME="${HOME:-/root}" LANG="${LANG:-C.UTF-8}" TERM="$(_abox_child_term)" bash "$selected" "$@"
    local rc=$?
    rm -rf -- "$work"
    return "$rc"
}

wallos_state_value() {
    local key="$1" val
    [[ -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]] || return 1
    val=$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$WALLOS_DIR/.abox-state")
    # D-06: awk exits 0 even when the key is missing (empty output), which
    # defeated every `|| printf fallback` caller. Return 1 on empty instead.
    [[ -n "$val" ]] || return 1
    printf '%s\n' "$val"
}

