# ABOX-MODULE-BEGIN 10-users-dns one-click reality, users, timezone, DNS
#   Source: install.sh lines 42575-50470 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
one_click_reality_deploy() {
    local choice answer prompt
    clear
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${RED}${BOLD}One-click Vision REALITY${NC}"
            msg "Defaults: port 443, SNI auto-selected from this VPS; www.amazon.com is used only after TLS 1.3/h2/SAN verification. If no target verifies, one-click setup stops. KeepAlive off."
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='Deploy one-click Vision REALITY now? [Y/N]: ' ;;
        ru)
            msg "${RED}${BOLD}Vision REALITY в один клик${NC}"
            msg "По умолчанию SNI выбирается по тестам этого VPS; www.amazon.com используется только после проверки TLS 1.3/h2/SAN. Если цель не подтверждена, установка в один клик остановится. KeepAlive выключен."
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='Запустить установку Vision REALITY в один клик? [Y/N]: ' ;;
        fa)
            msg "${RED}${BOLD}نصب یک‌کلیکی Vision REALITY${NC}"
            msg "پیش‌فرض SNI بر اساس آزمون‌های همین VPS انتخاب می‌شود؛ www.amazon.com فقط پس از بررسی TLS 1.3/h2/SAN استفاده می‌شود. اگر هیچ مقصدی تأیید نشود، نصب یک‌کلیکی متوقف می‌شود. KeepAlive خاموش است."
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='نصب یک‌کلیکی Vision REALITY آغاز شود؟ [Y/N]: ' ;;
        ja)
            msg "${RED}${BOLD}ワンクリック Vision REALITY${NC}"
            msg "デフォルト: port 443。SNI はこの VPS の TLS/ASN/地域に関する実測結果に基づいて自動選択されます。www.amazon.com は TLS 1.3/h2/証明書 SAN の検証に成功した場合のみフォールバック先として使用されます。検証可能な接続先がない場合、ワンクリックインストールは停止します。KeepAlive は無効です。"
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='今すぐ Vision REALITY をワンクリックでデプロイしますか？[Y/N]: ' ;;
        zh-tw)
            msg "${RED}${BOLD}一鍵 Vision REALITY${NC}"
            msg "預設 SNI 根據當前 VPS 的 TLS/ASN/地區實測自動選擇；僅在 www.amazon.com 透過 TLS 1.3/h2/證書 SAN 驗證後才用作回退。無可驗證目標時一鍵安裝會停止。KeepAlive 關閉。"
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='現在開始一鍵部署 Vision REALITY？[Y/N]: ' ;;
        *)
            msg "${RED}${BOLD}一键 Vision REALITY${NC}"
            msg "默认 SNI 根据当前 VPS 的 TLS/ASN/地区实测自动选择；仅在 www.amazon.com 通过 TLS 1.3/h2/证书 SAN 验证后才用作回退。无可验证目标时一键安装会停止。KeepAlive 关闭。"
            msg "${CYAN}1.${NC} Xray Vision REALITY"
            msg "${CYAN}2.${NC} sing-box Vision REALITY"
            prompt='现在开始一键部署 Vision REALITY？[Y/N]: ' ;;
    esac
    msg "${CYAN}0.${NC} $(tr_msg one_click_reality_deploy_cancel_back)"
    read -r -p 'Select [0-2]: ' choice || return 0
    choice=$(normalize_fa_ar_digits "${choice:-}")
    case "$choice" in 1|2) ;; *) return 0 ;; esac
    load_abox_env "$ABOX_ENV" >/dev/null 2>&1 || true
    if deployment_evidence_exists || [[ -n "${CORE:-}" || -n "${MODE:-}" ]]; then
        local _oc_cur="${CORE:-?}-${MODE:-?}"
        [[ -n "${CORE:-}" || -n "${MODE:-}" ]] || _oc_cur="$(tr_msg dp_existing)"
        msg "${RED}[!] $(tprintf oc_replace_warn "$_oc_cur")${NC}"
    fi
    if ! confirm_soft "$prompt"; then
        case "${ABOX_LANG:-zh}" in
            en) msg "${YELLOW}Cancelled.${NC}" ;;
            ru) msg "${YELLOW}Отменено.${NC}" ;;
            fa) msg "${YELLOW}لغو شد.${NC}" ;;
            zh-tw) msg "${YELLOW}已取消。${NC}" ;;
            ja)
                msg "${YELLOW}キャンセルしました。${NC}" ;;
            *) msg "${YELLOW}已取消。${NC}" ;;
        esac
        pause_return; return 0
    fi
    export ABOX_QUICK_DEPLOY=1
    case "$choice" in 1) deploy_xray VISION || pause_return ;; 2) deploy_singbox VISION || pause_return ;; esac
    unset ABOX_QUICK_DEPLOY
}
ux_mode_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    clear
    local c
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}Runtime mode and core version policy${NC}"
            msg "Current mode: ${YELLOW}$(read_fast_mode_label)${NC} | Core order: official stable → fixed recovery mirror"
            msg "${CYAN}1.${NC} Strict mode"
            msg "${CYAN}2.${NC} Fast mode (skips only non-critical confirmations)"
            msg "${CYAN}3.${NC} Show stable version policy and recovery pins"
            msg "${CYAN}0.${NC} Back" ;;
        ru)
            msg "${BOLD}${GREEN}Режим работы и политика версий ядер${NC}"
            msg "Режим: ${YELLOW}$(read_fast_mode_label)${NC} | Источник: стабильная upstream-версия → фиксированное резервное зеркало"
            msg "${CYAN}1.${NC} Строгий режим"
            msg "${CYAN}2.${NC} Быстрый режим (пропускаются только некритичные подтверждения)"
            msg "${CYAN}3.${NC} Политика стабильных версий и закреплённые резервные версии"
            msg "${CYAN}0.${NC} Назад" ;;
        fa)
            msg "${BOLD}${GREEN}حالت اجرا و سیاست نسخه هسته‌ها${NC}"
            msg "حالت: ${YELLOW}$(read_fast_mode_label)${NC} | منبع: نسخه پایدار upstream سپس نسخه بازیابی"
            msg "${CYAN}1.${NC} حالت سخت‌گیرانه"
            msg "${CYAN}2.${NC} حالت سریع (فقط از تأییدهای غیرحیاتی صرف‌نظر می‌شود)"
            msg "${CYAN}3.${NC} سیاست نسخه پایدار و نسخه‌های بازیابی"
            msg "${CYAN}0.${NC} بازگشت" ;;
        zh-tw)
            msg "${BOLD}${GREEN}執行模式與核心版本策略${NC}"
            msg "當前模式: ${YELLOW}$(read_fast_mode_label)${NC} | 核心來源：上游正式穩定版 → 固定容災映象"
            msg "${CYAN}1.${NC} 嚴格模式"
            msg "${CYAN}2.${NC} 快速模式（只跳過非關鍵確認）"
            msg "${CYAN}3.${NC} 檢視正式穩定版策略與固定容災版本"
            msg "${CYAN}0.${NC} 返回" ;;
        ja)
            msg "${BOLD}${GREEN}実行モードとコアバージョンのポリシー${NC}"
            msg "現在のモード: ${YELLOW}$(read_fast_mode_label)${NC} | コアの取得順序: 公式の安定版 → 固定リカバリミラー"
            msg "${CYAN}1.${NC} 厳格モード"
            msg "${CYAN}2.${NC} 高速モード（重要でない確認のみをスキップ）"
            msg "${CYAN}3.${NC} 公式安定版のポリシーと固定リカバリバージョンを表示"
            msg "${CYAN}0.${NC} 戻る" ;;
        *)
            msg "${BOLD}${GREEN}运行模式与核心版本策略${NC}"
            msg "当前模式: ${YELLOW}$(read_fast_mode_label)${NC} | 核心来源：上游正式稳定版 → 固定容灾镜像"
            msg "${CYAN}1.${NC} 严格模式"
            msg "${CYAN}2.${NC} 快速模式（只跳过非关键确认）"
            msg "${CYAN}3.${NC} 查看正式稳定版策略与固定容灾版本"
            msg "${CYAN}0.${NC} 返回" ;;
    esac
    read -r -p 'Select [0-3]: ' c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) save_fast_mode 0; pause_return ;;
        2) save_fast_mode 1; pause_return ;;
        3) show_core_pin_docs ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}
list_extra_uuids() {
    # FINAL-AUDIT fix: only a TRULY ABSENT file is an empty list. A file that
    # exists but is a symlink, unreadable, or not a regular file is a hard
    # failure; otherwise callers silently overwrite it and revoke all stored
    # extra UUIDs.
    if [[ ! -e "$EXTRA_UUID_FILE" && ! -L "$EXTRA_UUID_FILE" ]]; then
        return 0
    fi
    [[ -r "$EXTRA_UUID_FILE" && -f "$EXTRA_UUID_FILE" && ! -L "$EXTRA_UUID_FILE" ]] || return 1
    # Validate UUID shape without interval-regex operators such as {8}. Older
    # mawk versions shipped by supported legacy distributions do not implement
    # interval expressions, which would otherwise silently hide every UUID.
    ABOX_PRIMARY_UUID="${UUID:-}" awk '
        BEGIN { primary = ENVIRON["ABOX_PRIMARY_UUID"] }
        {
            if (split($0, part, "-") != 5) next
            if (length(part[1]) != 8 || length(part[2]) != 4 || length(part[3]) != 4 || length(part[4]) != 4 || length(part[5]) != 12) next
            if ($0 !~ /^[0-9A-Fa-f-]+$/) next
            if (tolower($0) != tolower(primary) && !seen[tolower($0)]++) print $0
        }
    ' "$EXTRA_UUID_FILE" 2>/dev/null
}

# H-24 (Carbon R3): UUIDs carried by multi-user registries
# (${ABOX_USERS_DIR:-/etc/ddr/users.d}/*.json). Prints one UUID per
# line, in glob order. Fail-closed like list_extra_uuids: a corrupt
# or symlinked registry file is a hard failure (return 1), never an
# empty list. A missing directory is an empty list.
# H-24(3) follow-up: vless/vmess registries carry the UUID in .secret
# (users_adopt sets secret=.id and leaves .uuid empty), so .secret is
# also accepted as a candidate for those protocols only -- a
# UUID-shaped password in any other registry must never leak in.
list_usersd_uuids() {
    local dir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}" f='' _u='' _proto=''
    # 05g-M2: check the symlink FIRST. The old order tested -d first,
    # so a dangling symlink (or a present-but-not-a-directory path)
    # returned 0 before the symlink check ran, and callers treated a
    # broken registry store as a legitimate empty list, silently
    # dropping users.d users in merge/sync/export. A wholly absent
    # directory is still a legitimate empty list (fresh install).
    [[ -L "$dir" ]] && return 1
    [[ -e "$dir" && ! -d "$dir" ]] && return 1
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.json; do
        [[ -e "$f" || -L "$f" ]] || continue
        [[ ! -L "$f" ]] || return 1
        [[ -f "$f" && -r "$f" ]] || return 1
        _proto=$(jq -r '.protocol // ""' "$f" 2>/dev/null) || return 1
        # O1 (followup5 D-leg): a registry whose inbound is confirmed
        # gone from the live config must not contribute UUIDs -- after
        # a cross-core overlay the other core's registries survive
        # deliberately (S2-NEW-04 merge), and merging their UUIDs
        # re-emits dead Vision nodes (old main UUID with new pbk/sid)
        # in the YAML and the subscription. This mirrors the
        # M41-NEW-01 export gate in users_link (rc 1 = confirmed
        # absent drops; rc 2 / missing config keeps the old
        # fail-open behaviour).
        local _o1_reg_core='' _o1_reg_tag='' _o1_reg_cfg='' _o1_live_rc=0
        _o1_reg_core=$(jq -r '.core // ""' "$f" 2>/dev/null) || return 1
        _o1_reg_tag=$(jq -r '.tag // ""' "$f" 2>/dev/null) || return 1
        if [[ ( "$_o1_reg_core" == 'xray' || "$_o1_reg_core" == 'sing-box' ) && -n "$_o1_reg_tag" ]] && declare -F _users_live_inbound_exists >/dev/null 2>&1; then
            _o1_reg_cfg=$(users_cfg_of "$_o1_reg_core" 2>/dev/null || printf '%s' '')
            if [[ -n "$_o1_reg_cfg" && -f "$_o1_reg_cfg" && ! -L "$_o1_reg_cfg" ]]; then
                _o1_live_rc=0
                _users_live_inbound_exists "$_o1_reg_core" "$_o1_reg_tag" || _o1_live_rc=$?
                [[ "$_o1_live_rc" == 1 ]] && continue
            fi
        fi
        # R40-H1: only ENABLED users contribute UUIDs (same filter as
        # users_sync SYNC-05 and _clash_registry_users_json). Without it
        # a disabled user's UUID was re-emitted into the merged list
        # (and, by the sync below, into every VLESS inbound's clients).
        _u=$(jq -r --arg proto "$_proto" '.users[]? | select(.disabled != true and ((.blocked // "") == "")) | [(.uuid // ""), (if ($proto == "vless" or $proto == "vmess") then (.secret // "") else "" end)] | map(select(test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))) | .[0] // empty' "$f" 2>/dev/null) || return 1
        printf '%s\n' "$_u"
    done
    return 0
}

# Write the full UUID list (primary UUID first, then extras) to $1.
# Returns 1 if the extra-UUID list is unreadable/untrusted. Callers MUST
# abort on failure; never treat a failed read as an empty list.
# (TRAP-7: do NOT use `done < <(list_extra_uuids)` -- process substitution
# swallows the exit status. Use this helper with an explicit status check.)
# E62-NEW-01 (candidate B): UUIDs the live Xray XHTTP inbound actually
# accepts, one per line. rc 0 iff the live config is readable and contains
# an xhttp inbound (the list itself may be empty: then no user can auth
# over XHTTP); rc 1 when the live state cannot be read or has no xhttp
# inbound, in which case the caller falls back to the merged registry list
# (the historical .env-driven behaviour, e.g. not-installed / self-test
# contexts where no live inbound exists to be authoritative).
list_xhttp_live_uuids() {
    local cfg='' _jq_cfg=''
    cfg=$(users_cfg_of xray 2>/dev/null) || return 1
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    _jq_cfg=$(mktemp /tmp/A-Box-xhttp-live.XXXXXX) || return 1
    jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { rm -f -- "$_jq_cfg"; return 1; }
    jq -e --arg t xhttp '[.inbounds[]? | select(.tag == $t)] | length > 0' "$_jq_cfg" >/dev/null 2>&1 || { rm -f -- "$_jq_cfg"; return 1; }
    jq -r --arg t xhttp '.inbounds[]? | select(.tag == $t) | .settings.clients[]?.id // empty' "$_jq_cfg" 2>/dev/null || { rm -f -- "$_jq_cfg"; return 1; }
    rm -f -- "$_jq_cfg"
    return 0
}
write_full_uuid_list_to_file() {
    local out="$1" _tmp='' _rc=0
    # TRAP-7(c): declare first, assign separately -- `local x=$(cmd)` masks
    # the exit code (local always returns 0).
    _tmp=$(umask 077; mktemp /tmp/A-Box-uuid-merge.XXXXXX) || return 1
    # H-24 (Carbon R3): three UUID sources, merged (parent decision: no
    # silent dropping of multi-user UUIDs). Each list read is checked
    # explicitly: the block's exit status would only reflect the last
    # command and mask an earlier failure.
    {
        printf '%s\n' "${UUID:-}"
        list_extra_uuids || _rc=1
        list_usersd_uuids || _rc=1
    } > "$_tmp"
    if (( _rc != 0 )); then
        rm -f -- "$_tmp"
        return 1
    fi
    # Dedupe case-insensitively, preserving first-seen order; drop
    # empty lines (an unset $UUID prints one). A users.d UUID equal to
    # $UUID or an extra UUID cannot produce a duplicate node name.
    awk '{
        if ($0 == "") next
        k = tolower($0)
        if (!seen[k]++) print $0
    }' "$_tmp" > "$out" || { rm -f -- "$_tmp"; return 1; }
    rm -f -- "$_tmp"
    return 0
}

export_lightweight_subscription() {
    local CALLER=${1:-manual} F_IP VISION_SNI_E XHTTP_SNI_E PUBLIC_KEY_E SHORT_ID_E uri_file b64_file clash_file u url client_uuid proxy_name
    ensure_abox_dir_owned "$ABOX_DIR" || die 'subscribe dir prepare failed'
    mkdir -p "$SUBSCRIBE_DIR" || die 'subscribe dir create failed'
    # A-05c-FIX: Directory chmod failure is fatal (was || true, fail-open).
    chmod 700 "$SUBSCRIBE_DIR" || return 1
    [[ -f "$ABOX_ENV" ]] || { msg "${RED}No deployment env.${NC}"; pause_return; return 1; }
    load_abox_env "$ABOX_ENV" || die 'env invalid'
    F_IP=$(uri_host "${LINK_IP:-}")
    VISION_SNI=${VISION_SNI:-${VLESS_SNI:-}}
    XHTTP_SNI=${XHTTP_SNI:-${VLESS_SNI:-}}
    VISION_SNI_E=$(urlencode "${VISION_SNI:-}")
    XHTTP_SNI_E=$(urlencode "${XHTTP_SNI:-}")
    PUBLIC_KEY_E=$(urlencode "${PUBLIC_KEY:-}")
    SHORT_ID_E=$(urlencode "${SHORT_ID:-}")
    uri_file="$SUBSCRIBE_DIR/uri-list.txt"
    b64_file="$SUBSCRIBE_DIR/subscription.base64"
    # A-05c-FIX: Build URI content in temp file (umask 077), then atomic install 600.
    # Previously: ": > uri_file" created 0644 under umask 022, then chmod 600 (window).
    local uri_tmp
    uri_tmp=$(umask 077; mktemp "$SUBSCRIBE_DIR/.uri-list.XXXXXX") || return 1
    # TRAP-7: capture UUID list to temp file with explicit status check.
    # Process substitution would swallow a list_extra_uuids failure.
    local _uuid_list_tmp
    _uuid_list_tmp=$(umask 077; mktemp /tmp/A-Box-uuid-list.XXXXXX) || { rm -f -- "$uri_tmp"; return 1; }
    if ! write_full_uuid_list_to_file "$_uuid_list_tmp"; then
        rm -f -- "$uri_tmp" "$_uuid_list_tmp"
        msg "${RED}UUID list unreadable or untrusted; refusing to generate incomplete subscription.${NC}" >&2
        return 1
    fi
    # R9C11-03: a stale MODE (e.g. ALL after Vision deletion) with a
    # cleared VLESS_PORT must not emit vless://...@host:? malformed URLs.
    if [[ -n "${VLESS_PORT:-}" && "${VLESS_PORT:-}" =~ ^[0-9]+$ ]] && [[ "${MODE:-}" == *'VISION'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]]; then
        while IFS= read -r client_uuid; do
            [[ -n "$client_uuid" ]] || continue
            if [[ "$client_uuid" == "${UUID:-}" ]]; then proxy_name='Vision'; else proxy_name="Vision-$client_uuid"; fi
            url="vless://$client_uuid@$F_IP:${VLESS_PORT:-}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$VISION_SNI_E&fp=chrome&pbk=$PUBLIC_KEY_E&sid=$SHORT_ID_E&type=tcp#$proxy_name"
            printf '%s\n' "$url" >> "$uri_tmp" || { rm -f -- "$uri_tmp" "$_uuid_list_tmp"; return 1; }
        done < "$_uuid_list_tmp"
    fi
    # R9C11-03 (same mechanism): skip XHTTP when its port is gone.
    if [[ -n "${XHTTP_PORT:-}" && "${XHTTP_PORT:-}" =~ ^[0-9]+$ ]] && [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]]; then
        # 05g-M1 (E62-NEW-01 parity, same as write_clash_yaml):
        # XHTTP links are emitted only for UUIDs the live XHTTP
        # inbound actually has. list_xhttp_live_uuids rc 0 is
        # authoritative even when the list is empty; only an
        # unreadable live state (or no xhttp inbound) falls back
        # to the merged registry list.
        local _xhttp_uuid_list_tmp=''
        _xhttp_uuid_list_tmp=$(umask 077; mktemp /tmp/A-Box-xhttp-uuid-list.XXXXXX) || { rm -f -- "$uri_tmp" "$_uuid_list_tmp"; return 1; }
        if list_xhttp_live_uuids > "$_xhttp_uuid_list_tmp" 2>/dev/null; then
            : # live list is authoritative (it may be empty)
        else
            cp -f -- "$_uuid_list_tmp" "$_xhttp_uuid_list_tmp" || { rm -f -- "$uri_tmp" "$_uuid_list_tmp" "$_xhttp_uuid_list_tmp"; return 1; }
        fi
        while IFS= read -r client_uuid; do
            [[ -n "$client_uuid" ]] || continue
            if [[ "$client_uuid" == "${UUID:-}" ]]; then proxy_name='XHTTP'; else proxy_name="XHTTP-$client_uuid"; fi
            url="vless://$client_uuid@$F_IP:${XHTTP_PORT:-}?encryption=none&security=reality&sni=$XHTTP_SNI_E&fp=chrome&pbk=$PUBLIC_KEY_E&sid=$SHORT_ID_E&type=xhttp&host=$XHTTP_SNI_E&path=%2Fxhttp&mode=stream-one#$proxy_name"
            printf '%s\n' "$url" >> "$uri_tmp" || { rm -f -- "$uri_tmp" "$_uuid_list_tmp" "$_xhttp_uuid_list_tmp"; return 1; }
        done < "$_xhttp_uuid_list_tmp"
        rm -f -- "$_xhttp_uuid_list_tmp"
    fi
    rm -f -- "$_uuid_list_tmp"
    # FIX: If neither VISION nor XHTTP branch ran (e.g. HY2-only or SS-only
    # deployment), no URIs were written. Do NOT install an empty subscription
    # file and claim success — report clearly instead.
    if [[ ! -s "$uri_tmp" ]]; then
        rm -f -- "$uri_tmp"
        msg "${YELLOW}[!] No subscription URIs generated: current MODE (${MODE:-}) has no VLESS/VISION/XHTTP inbound. Subscription files were not written.${NC}" >&2
        return 1
    fi
    # A-05c-FIX: Atomic install of URI list (600). Temp file cleaned up.
    install_file_atomically "$uri_tmp" "$uri_file" 600 || { rm -f -- "$uri_tmp"; return 1; }
    rm -f -- "$uri_tmp"
    if command -v base64 >/dev/null 2>&1; then
        # A-05c-FIX: Pipe base64 through atomic writer (600). Previously: redirect
        # created 0644, then chmod 600 with || true (fail-open, window).
        ( base64 -w0 < "$uri_file" 2>/dev/null || base64 < "$uri_file" | tr -d '\n' ) \
            | write_file_atomically_from_stdin "$b64_file" 600 || return 1
    fi
    clash_file=$(write_clash_yaml 2>/dev/null || true)
    msg "${GREEN}URI list: ${uri_file}${NC}"
    [[ -f "$b64_file" ]] && msg "${GREEN}Base64 subscription: ${b64_file}${NC}"
    [[ -n "${clash_file:-}" ]] && msg "${GREEN}Clash YAML: ${clash_file}${NC}"
    if [[ "$CALLER" != 'quiet' ]]; then
        msg "${YELLOW}Host these files via HTTPS for remote import; this is not a full panel.${NC}"
        pause_return
    fi
}

# ================= Multi-user manager (fix47) =================
# Per-inbound user registries live in /etc/ddr/users.d/<core>__<tag>.json
# (600). The registry is the source of truth for who may connect;
# users_sync rewrites the core config's user list from it inside the
# usual transaction (validate -> atomic install -> restart -> rollback).
# Xray-family users carry email "<tag>/<name>", which is what the
# StatsService counters and `xray api rmu` key on.
USERS_DIR='/etc/ddr/users.d'

# R11C11-01/R15C11-01: encode a registry component so it is always a
# single filename component. Only '%' and '/' are escaped: '/' is the only
# traversal character on Linux, and escaping '%' first keeps the mapping
# injective. Safe tags are byte-identical, so legacy safe records need no
# migration; readers take core/tag from JSON content, never the filename.
users_reg_encode_component() {
    local out="${1//%/%25}"
    out="${out//\//%2F}"
    printf '%s' "$out"
}
users_reg_file() { printf '%s/%s__%s.json' "${ABOX_USERS_DIR:-$USERS_DIR}" "$(users_reg_encode_component "$1")" "$(users_reg_encode_component "$2")"; }
# Rename the historical default label 'abox' to 'main' so every
# node's default user reads the same. SOCKS-type registries are
# excluded: there the name IS the login username (a credential).
users_normalize_default_name() {
    local core="$1" tag="$2" reg='' proto='' new=''
    reg=$(users_reg_file "$core" "$tag")
    [[ -f "$reg" && ! -L "$reg" ]] || return 0
    proto=$(jq -r '.protocol // ""' "$reg" 2>/dev/null) || return 0
    # R9C11-02: Hy2 userpass names are credentials (like SOCKS
    # logins), not display labels; renaming would break auth.
    case "$proto" in *socks*|mixed|*hysteria*|*hy2*) return 0 ;; esac
    jq -e '([.users[].name] | (index("abox") != null) and (index("main") == null))' "$reg" >/dev/null 2>&1 || return 0
    new=$(jq -c --arg tag "$tag" '.users |= map(if .name == "abox" then .name = "main" | (if .email == ($tag + "/abox") then .email = ($tag + "/main") else . end) else . end)' "$reg" 2>/dev/null) || return 0
    [[ -n "$new" ]] || return 0
    # Keep the pre-migration registry: if the core sync fails, the
    # registry must not keep 'main' while the core still has 'abox' —
    # the abox-gone guard above would then skip every later retry and
    # strand the user identity permanently.
    local old_reg=''
    old_reg=$(cat "$reg" 2>/dev/null) || return 0
    users_reg_write "$core" "$tag" "$new" >/dev/null 2>&1 || return 0
    if ! users_sync "$core" "$tag" >/dev/null 2>&1; then
        if ! users_reg_write "$core" "$tag" "$old_reg" >/dev/null 2>&1; then
            msg "${RED}[!] $(tprintf users_normalize_default_name_migrate_failed "${core}" "${tag}")${NC}" >&2
            return 1
        fi
    fi
}
# Startup sweep: normalize every registry's default label without
# waiting for the toolbox or the guard tick to visit it.
users_normalize_all_default_names() {
    local _dir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}" _f='' _c='' _t=''
    [[ -d "$_dir" ]] || return 0
    for _f in "$_dir"/*.json; do
        [[ -f "$_f" && ! -L "$_f" ]] || continue
        _c=$(jq -r '.core // ""' "$_f" 2>/dev/null) || continue
        _t=$(jq -r '.tag // ""' "$_f" 2>/dev/null) || continue
        [[ -n "$_c" && -n "$_t" ]] && users_normalize_default_name "$_c" "$_t"
    done
    return 0
}



users_cfg_of() {
    case "$1" in
        xray) printf '%s' "${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" ;;
        sing-box) printf '%s' '/etc/sing-box/config.json' ;;
        hy2) printf '%s' '/etc/hysteria/config.yaml' ;;
        *) return 1 ;;
    esac
}

users_svc_of() {
    case "$1" in
        xray) printf '%s' 'xray' ;;
        sing-box) printf '%s' 'sing-box' ;;
        hy2) printf '%s' 'hysteria' ;;
        *) return 1 ;;
    esac
}

users_bin_of() {
    case "$1" in
        xray) printf '%s' "${XRAY_SLOT_BIN:-/usr/local/bin/xray}" ;;
        sing-box) printf '%s' '/usr/local/bin/sing-box' ;;
        hy2) printf '%s' '/usr/local/bin/hysteria' ;;
        *) return 1 ;;
    esac
}

users_api_port_of() {
    case "$1" in
        xray) printf '%s' '10085' ;;
        # xray-latest is retired: never fall through to the default
        # 10085 arm, which would point callers at the normal Xray API.
        xray-latest) return 1 ;;
        *) printf '%s' '10085' ;;
    esac
}

users_valid_name() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,23}$ ]]; }

# Atomic registry write: $1=core $2=tag $3=json-content
# D1 (S0 + core allowlist): the filename encoder is injective, but a
# pre-encoder raw file can still occupy the encoded name of a different
# tag (literal tag a%2Fb vs encoded a/b), and a core containing __ would
# collide with the __ separator. So before any write can overwrite:
# - the core must be one of the known cores (a __-bearing core can never
#   create a file here);
# - a symlink at the destination is refused outright (never followed);
# - a regular file already there must belong to this (core, tag) by its
#   JSON content (.core/.tag — readers already trust content, never the
#   filename). A file belonging to another identity is a misplaced /
#   legacy file: it is moved aside to its own encoded home (non-
#   overwriting, only when that home is free) and the write proceeds.
#   If the home is occupied, or the file carries no readable identity,
#   the write fails closed — the existing file is never overwritten.
users_reg_write() {
    local core="$1" tag="$2" content="$3" dest='' ec='' et='' home=''
    case "$core" in xray|sing-box|hy2) ;; *) return 1 ;; esac
    dest=$(users_reg_file "$core" "$tag") || return 1
    if [[ -L "$dest" ]]; then
        msg "${RED}[!] $(tprintf users_reg_write_symlink_refused "$dest")${NC}" >&2
        return 1
    fi
    if [[ -f "$dest" ]]; then
        ec=$(jq -r '.core // ""' "$dest" 2>/dev/null || true)
        et=$(jq -r '.tag // ""' "$dest" 2>/dev/null || true)
        if [[ "$ec" == "$core" && "$et" == "$tag" ]]; then
            : # owned by this identity: overwrite below
        elif [[ -n "$ec" && -n "$et" ]]; then
            home=$(users_reg_file "$ec" "$et") || return 1
            if [[ -e "$home" || -L "$home" ]]; then
                msg "${RED}[!] $(tprintf users_reg_write_owned_elsewhere "$dest" "${ec}" "${et}" "$home")${NC}" >&2
                return 1
            fi
            mv -n -- "$dest" "$home" 2>/dev/null && [[ ! -e "$dest" && -f "$home" ]] || {
                msg "${RED}[!] $(tprintf users_reg_write_move_failed "$dest" "$home")${NC}" >&2
                return 1
            }
            msg "${YELLOW}[!] $(tprintf users_reg_write_moved "${ec}" "${et}" "$dest" "$home")${NC}" >&2
        else
            msg "${RED}[!] $(tprintf users_reg_write_identity_unreadable "$dest")${NC}" >&2
            return 1
        fi
    fi
    users_reg_write_path "$dest" "$content"
}

# Atomic registry write to an explicit path: $1=path $2=json-content
# mkdir_private: create a directory with 700 ONLY if it does not exist.
# Never change the mode of an existing directory (it may be shared),
# and never follow a symlink. Returns 1 on symlink / non-dir / failure.
mkdir_private() {
    local _d="$1"
    [[ -n "$_d" ]] || return 1
    if [[ -L "$_d" ]]; then return 1; fi
    if [[ -d "$_d" ]]; then return 0; fi
    if [[ -e "$_d" ]]; then return 1; fi
    mkdir -p -m 700 "$_d"
}

users_reg_write_path() {
    local dest="$1" content="$2" dir='' tmp=''
    dir=$(dirname -- "$dest") || return 1
    mkdir_private "$dir" 2>/dev/null || return 1
    tmp=$(mktemp "$dir/.reg.XXXXXX") || return 1
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    # R10-06: a directory at the destination must fail, not be
    # silently swallowed: without -T, mv renames the temp file
    # INTO the directory and reports success.
    if [[ -d "$dest" ]]; then rm -f "$tmp"; return 1; fi
    mv -f -- "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    return 0
}

# Validate + install a prepared config file with the core's own checker,
# restart its service, roll back on any failure.
# $1=core $2=cfg-path $3=new-file $4=backup-file
users_commit_cfg() {
    local core="$1" cfg="$2" newf="$3" bak="$4" bin='' svc=''
    bin=$(users_bin_of "$core") || return 1
    svc=$(users_svc_of "$core") || return 1
    case "$core" in
        xray)
            [[ -x "$bin" ]] || return 1
            XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$newf" >/dev/null 2>&1 || return 1 ;;
        sing-box)
            [[ -x "$bin" ]] || return 1
            "$bin" check -c "$newf" >/dev/null 2>&1 || return 1 ;;
        hy2) : ;; # no offline checker; service restart is the validation
    esac
    install_file_atomically "$newf" "$cfg" 600 || return 1
    local _perm_ok=1
    case "$core" in
        xray) prepare_abox_runtime_permissions xray >/dev/null 2>&1 || _perm_ok=0 ;;
        sing-box) prepare_abox_runtime_permissions sing-box >/dev/null 2>&1 || _perm_ok=0 ;;
        hy2) prepare_abox_runtime_permissions hysteria >/dev/null 2>&1 || _perm_ok=0 ;;
    esac
    # 05g-M3: a failed permission prep used to be swallowed (|| true)
    # and the commit reported success -- with the service deliberately
    # stopped the restart/rollback branch below never ran, so the
    # caller deleted $bak while the live config was root:root 600 and
    # the service could not start on it. Treat it like the restart
    # failure below: restore $bak when possible (rc 1, callers delete
    # $bak because the disk holds the old config again); when the
    # restore itself fails (including a failed prep on the restored
    # file) it is a failed restore, rc 2, callers keep $bak -- the
    # same R15-F11-02定性 as the rollback branch. No restart is
    # attempted here: there is no validly committed config to
    # restart into, and a stopped service must stay stopped (H-23).
    if (( _perm_ok == 0 )); then
        if [[ -n "$bak" && -f "$bak" ]]; then
            if install_file_atomically "$bak" "$cfg" 600 >/dev/null 2>&1 || cp -f -- "$bak" "$cfg"; then
                case "$core" in
                    xray) prepare_abox_runtime_permissions xray >/dev/null 2>&1 || return 2 ;;
                    sing-box) prepare_abox_runtime_permissions sing-box >/dev/null 2>&1 || return 2 ;;
                    hy2) prepare_abox_runtime_permissions hysteria >/dev/null 2>&1 || return 2 ;;
                esac
                return 1
            fi
            return 2
        fi
        return 1
    fi
    # H-23 (Carbon R3): restart only when the desired state is RUNNING
    # and the service was already running; otherwise the new config is
    # already on disk and restarting would resurrect a deliberately
    # stopped stack (or fail and roll back a valid commit when the
    # service is down).
    if service_restart_permitted "$svc"; then
        if ! restart_service_soft "$svc"; then
            if [[ -n "$bak" && -f "$bak" ]]; then
                if install_file_atomically "$bak" "$cfg" 600 >/dev/null 2>&1 || cp -f -- "$bak" "$cfg"; then
                    # R15-F11-02: the file copy alone does not prove the
                    # rollback is usable. If the permission prep fails,
                    # the restored live config is unreadable by the
                    # runtime user and the service stays down; if the
                    # restart then fails, the rollback did not restore
                    # service either. Either failure is a failed restore
                    # (rc 2, callers keep $bak), never a plain failed
                    # commit (rc 1, callers delete $bak).
                    case "$core" in
                        xray) prepare_abox_runtime_permissions xray >/dev/null 2>&1 || return 2 ;;
                        sing-box) prepare_abox_runtime_permissions sing-box >/dev/null 2>&1 || return 2 ;;
                        hy2) prepare_abox_runtime_permissions hysteria >/dev/null 2>&1 || return 2 ;;
                    esac
                    restart_service_soft "$svc" >/dev/null 2>&1 || return 2
                    return 1
                fi
                # Restore failed: $cfg still holds the failed replacement and
                # $bak is the only good copy. Distinct code so the caller keeps
                # $bak for manual recovery instead of deleting it.
                return 2
            fi
            return 1
        fi
    fi
    return 0
}

# Tag retrofit for combo inbounds built before fix47 (they had no tags,
# which kept them invisible to per-tag management). Assigns tags by
# protocol/network shape only when the tag is still free; VLESS gets
# "vision" only with an xtls-rprx-vision flow (a plain VLESS-WS inbound
# is not a vision node and stays untagged). Duplicate candidates get a
# numeric suffix (vision-2, ...) so tags stay unique.
users_xray_ensure_tags() {
    local cfg="$1" bak='' tmp='' tmpd='' _commit_rc='' _jq_cfg='' _jq_caller_trap=''
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    # R40-M2: read through a JSONC-stripped view (same approach as
    # users_adopt): raw jq on a commented config fails the probe and
    # the retrofit silently never runs. The commit still writes the
    # transformed JSON over the original file, with the original kept
    # as backup.
    _jq_cfg=$(mktemp /tmp/A-Box-utag-json.XXXXXX) || return 1
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'rm -f -- "$_jq_cfg" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
    jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || return 1
    jq empty "$_jq_cfg" >/dev/null 2>&1 || return 1
    jq -e '[.inbounds[]? | select(.tag == null or .tag == "")] | length > 0' "$_jq_cfg" >/dev/null 2>&1 || return 0
    bak=$(mktemp /tmp/A-Box-utag-bak.XXXXXX) || return 1
    cp -f -- "$cfg" "$bak" || { rm -f "$bak"; return 1; }
    tmpd=$(mktemp -d /tmp/A-Box-utag.XXXXXX) || { rm -f "$bak"; return 1; }
    tmp="$tmpd/config.json"
    if ! jq '
        def pick($base; $used): (first(range(0; 1000) | (if . == 0 then $base else ($base + "-" + ((. + 1) | tostring)) end) | select(. as $c | ($used | index($c) | not))) // null);
        ([.inbounds[]?.tag | select(. != null and . != "")]) as $init
        | .inbounds = (reduce .inbounds[] as $ib ({used: $init, out: []};
            if ($ib.tag != null and $ib.tag != "") then {used: .used, out: (.out + [$ib])}
            elif $ib.protocol == "vless" and (($ib.streamSettings.network // "tcp") == "xhttp") then
                (pick("xhttp"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            elif $ib.protocol == "vless" and ([$ib.settings.clients[]? | select(.flow == "xtls-rprx-vision")] | length > 0) then
                (pick("vision"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            elif $ib.protocol == "shadowsocks" then
                (pick("ss"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            else {used: .used, out: (.out + [$ib])} end)
          | .out)
    ' "$_jq_cfg" > "$tmp"; then rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 1; fi
    users_commit_cfg xray "$cfg" "$tmp" "$bak"; _commit_rc=$?
    if (( _commit_rc == 0 )); then
        if jq -e '[.inbounds[]? | select((.tag == null or .tag == "") and .protocol == "vless")] | length > 0' "$cfg" >/dev/null 2>&1; then
            msg "${RED}[!] xray: untagged VLESS inbound(s) left without a tag; they stay invisible to per-tag management.${NC}"
        fi
        rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 0
    fi
    if (( _commit_rc == 2 )); then
        msg "${RED}[!] config commit failed and restore failed; backup kept at $bak for manual recovery.${NC}"
        rm -f "$tmp"; rm -rf "$tmpd"; return 1
    fi
    rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 1
}

users_sb_ensure_tags() {
    local cfg="$1" bak='' tmp='' tmpd='' _commit_rc='' _jq_cfg='' _jq_caller_trap=''
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    # R40-M2: read through a JSONC-stripped view (same approach as
    # users_adopt): raw jq on a commented config fails the probe and
    # the retrofit silently never runs. The commit still writes the
    # transformed JSON over the original file, with the original kept
    # as backup.
    _jq_cfg=$(mktemp /tmp/A-Box-utag-json.XXXXXX) || return 1
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'rm -f -- "$_jq_cfg" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
    jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || return 1
    jq empty "$_jq_cfg" >/dev/null 2>&1 || return 1
    jq -e '[.inbounds[]? | select(.tag == null or .tag == "")] | length > 0' "$_jq_cfg" >/dev/null 2>&1 || return 0
    bak=$(mktemp /tmp/A-Box-utag-bak.XXXXXX) || return 1
    cp -f -- "$cfg" "$bak" || { rm -f "$bak"; return 1; }
    tmpd=$(mktemp -d /tmp/A-Box-utag.XXXXXX) || { rm -f "$bak"; return 1; }
    tmp="$tmpd/config.json"
    if ! jq '
        def pick($base; $used): (first(range(0; 1000) | (if . == 0 then $base else ($base + "-" + ((. + 1) | tostring)) end) | select(. as $c | ($used | index($c) | not))) // null);
        ([.inbounds[]?.tag | select(. != null and . != "")]) as $init
        | .inbounds = (reduce .inbounds[] as $ib ({used: $init, out: []};
            if ($ib.tag != null and $ib.tag != "") then {used: .used, out: (.out + [$ib])}
            elif $ib.type == "vless" and ([$ib.users[]? | select(.flow == "xtls-rprx-vision")] | length > 0) then
                (pick("vision"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            elif $ib.type == "hysteria2" then
                (pick("hy2"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            elif $ib.type == "shadowsocks" then
                (pick("ss"; .used) as $c | if $c then {used: (.used + [$c]), out: (.out + [$ib + {tag: $c}])} else {used: .used, out: (.out + [$ib])} end)
            else {used: .used, out: (.out + [$ib])} end)
          | .out)
    ' "$_jq_cfg" > "$tmp"; then rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 1; fi
    users_commit_cfg sing-box "$cfg" "$tmp" "$bak"; _commit_rc=$?
    if (( _commit_rc == 0 )); then
        if jq -e '[.inbounds[]? | select((.tag == null or .tag == "") and .type == "vless")] | length > 0' "$cfg" >/dev/null 2>&1; then
            msg "${RED}[!] sing-box: untagged VLESS inbound(s) left without a tag; they stay invisible to per-tag management.${NC}"
        fi
        rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 0
    fi
    if (( _commit_rc == 2 )); then
        msg "${RED}[!] config commit failed and restore failed; backup kept at $bak for manual recovery.${NC}"
        rm -f "$tmp"; rm -rf "$tmpd"; return 1
    fi
    rm -f "$tmp" "$bak"; rm -rf "$tmpd"; return 1
}

# ---- adoption: build a registry from the live config ----
# Shared jq: turn a raw [{name,secret,...}] list into registry users,
# sanitising/deduping names and stamping defaults.
USERS_JQ_DEDUPE='
def cleanname: (tostring | gsub("[^a-zA-Z0-9_-]"; "_") | .[0:24] | if . == "" then "main" end);
def freshname($seen; $start): first(range($start; infinite) | ("u" + tostring) | select(. as $c | ($seen | has($c) | not)));
def dedupe: reduce .[] as $u ({seen:{}, out:[]};
    if .seen[$u.name] then (freshname(.seen; (.out | length) + 1) as $cand | .out += [$u + {name: $cand}] | .seen += {($cand): 1})
    else .seen += {($u.name): 1} | .out += [$u] end) | .out;
def mkusers($tag): map({
    name: ((.name // "main") | cleanname),
    login: (.name // "main"),
    password_only: (.password_only // false),
    secret: (.secret // ""),
    uuid: (.uuid // ""),
    flow: (.flow // ""),
    alterId: (.alterId // 0),
    email: (if $tag != "" then ($tag + "/" + ((.name // "main") | cleanname)) else "" end),
    created: "",
    expire_at: 0, quota_gb: 0, window: "",
    disabled: false, blocked: "",
    period: "", used_up: 0, used_down: 0, last_up: 0, last_down: 0
}) | dedupe | map(.email = (if $tag != "" then ($tag + "/" + .name) else "" end))'

users_adopt() {
    local core="$1" tag="$2" outfile="${3:-}" cfg='' proto='' users='[]' ssecret='' raw='' _jq_cfg='' _jq_tmp=0
    cfg=$(users_cfg_of "$core") || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    [[ -f "$cfg" && ! -L "$cfg" ]] || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    # R16-F11-02: xray/sing-box jq reads go through the
    # JSONC-stripped view: a commented config makes raw jq fail and
    # the empty protocol below is misread as "no such protocol".
    # Hy2 keeps the raw file (YAML, not JSONC).
    if [[ "$core" == xray || "$core" == sing-box ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-adopt-json.XXXXXX) || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
        _jq_tmp=1
        jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    else
        _jq_cfg="$cfg"
    fi
    case "$core" in
        xray)
            proto=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .protocol // ""' "$_jq_cfg" 2>/dev/null | head -1)
            [[ -n "$proto" ]] || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            raw=$(jq -c --arg t "$tag" '
                .inbounds[]? | select(.tag == $t) | .settings as $st
                | if .protocol == "vless" then [$st.clients[]? | {name: (if .email then (if .email == "" then "main" else (.email | split("/") | .[-1]) end) else "main" end), secret: .id, flow: (.flow // "")}]
                  elif .protocol == "trojan" then [$st.clients[]? | {name: (if .email then (if .email == "" then "main" else (.email | split("/") | .[-1]) end) else "main" end), secret: .password}]
                  elif .protocol == "shadowsocks" then
                      (if (($st.clients // null) | type) == "array"
                       then [$st.clients[] | {name: (if .email then (if .email == "" then "main" else (.email | split("/") | .[-1]) end) else "main" end), secret: .password}]
                       else [{name: "main", secret: ($st.password // ""), password_only: true}] end)
                  elif .protocol == "socks" then [$st.accounts[]? | {name: (.user // "main"), secret: (.pass // "")}]
                  elif .protocol == "vmess" then [$st.clients[]? | {name: (if .email then (if .email == "" then "main" else (.email | split("/") | .[-1]) end) else "main" end), secret: .id, uuid: .id, alterId: (.alterId // 0)}]
                  else [] end' "$_jq_cfg" 2>/dev/null) || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            if [[ "$proto" == 'shadowsocks' ]]; then
                # clients-form SS keeps the server key separately.
                if jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.settings.clients // null | type) == "array"' "$_jq_cfg" >/dev/null 2>&1; then
                    ssecret=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .settings.password // ""' "$_jq_cfg" 2>/dev/null | head -1)
                fi
            fi
            ;;
        sing-box)
            proto=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .type // ""' "$_jq_cfg" 2>/dev/null | head -1)
            [[ -n "$proto" ]] || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            raw=$(jq -c --arg t "$tag" '
                .inbounds[]? | select(.tag == $t)
                | if .type == "vmess" then [.users[]? | {name: (.name // "main"), secret: (.uuid // .password // ""), uuid: (.uuid // .password // ""), flow: (.flow // ""), alterId: (.alterId // 0)}]
                  elif .type == "vless" then [.users[]? | {name: (.name // "main"), secret: (.uuid // .password // ""), flow: (.flow // ""), alterId: (.alterId // 0)}]
                  elif .type == "tuic" then [.users[]? | {name: (.name // "main"), secret: (.password // ""), uuid: (.uuid // "")}]
                  elif .type == "shadowsocks" then
                      (if ((.users // null) | type) == "array" and ((.users // []) | length) > 0
                       then [.users[] | {name: (.name // "main"), secret: (.password // "")}]
                       else [{name: "main", secret: (.password // ""), password_only: true}] end)
                  elif .type == "mixed" or .type == "socks" then [.users[]? | {name: (.username // "main"), secret: (.password // "")}]
                  else [.users[]? | {name: (.name // "main"), secret: (.password // "")}] end' "$_jq_cfg" 2>/dev/null) || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            if [[ "$proto" == 'shadowsocks' ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t) | ((.users // []) | length) > 0' "$_jq_cfg" >/dev/null 2>&1; then
                ssecret=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .password // ""' "$_jq_cfg" 2>/dev/null | head -1)
            fi
            ;;
        hy2)
            proto='hysteria2'
            raw=$(users_hy2_read_users "$cfg") || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            ;;
        *) (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1 ;;
    esac
    [[ -n "$raw" ]] || raw='[]'
    users=$(printf '%s' "$raw" | jq -c --arg tag "$tag" "$USERS_JQ_DEDUPE; mkusers(\$tag)") || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    local now=''
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')
    users=$(printf '%s' "$users" | jq -c --arg now "$now" 'map(.created = (if .created == "" then $now else .created end))') || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    local reg=''
    reg=$(jq -cn --arg core "$core" --arg tag "$tag" --arg proto "$proto" --rawfile ss <(printf '%s' "$ssecret") --slurpfile users <(printf '%s' "$users") \
        '{core: $core, tag: $tag, protocol: $proto, server_secret: $ss, users: $users[0]}') || { (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    if [[ -n "$outfile" ]]; then users_reg_write_path "$outfile" "$reg"; else users_reg_write "$core" "$tag" "$reg"; fi
    local _adopt_rc=$?
    (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }
    return "$_adopt_rc"
}

# Read the official Hy2 auth block into a raw users list [{name,secret}].
# Decode one YAML scalar value (plain / single-quoted / double-quoted).
# Double-quoted keeps the existing jq decode (escapes + trailing-newline
# sentinel). Single-quoted strips the quotes and unescapes '' -> '.
# Plain strips the first ' #' inline comment and trailing whitespace.
users_hy2_yaml_scalar() {
    local v="$1" _tok='' _rest='' _sfx='' _dec=''
    local _i=0 _len=0 _c='' _close=-1 _out=''
    local q="'"
    # Double-quoted: scan for the closing quote, consuming backslash
    # pairs; decode the token with jq (staged, so a failed decode
    # cannot emit partial output plus the fallback); validate the
    # suffix (empty, whitespace, or whitespace + '#...' comment).
    # Anything else (unterminated quote, malformed suffix, invalid
    # escape) falls back to the original input unchanged.
    if [[ "$v" == '"'* ]]; then
        _len=${#v}
        _i=1
        while (( _i < _len )); do
            _c=${v:_i:1}
            if [[ "$_c" == '\' ]]; then _i=$(( _i + 2 )); continue; fi
            if [[ "$_c" == '"' ]]; then _close=$_i; break; fi
            _i=$(( _i + 1 ))
        done
        if (( _close < 0 )); then
            printf '%s__ABOX_TRAILING_NL_KEEP__' "$v"
            return 0
        fi
        _tok=${v:0:_close+1}
        _rest=${v:_close+1}
        _sfx="$_rest"
        while [[ "$_sfx" == ' '* || "$_sfx" == $'\t'* || "$_sfx" == $'\r'* ]]; do _sfx=${_sfx:1}; done
        if [[ -n "$_sfx" && "$_sfx" != '#'* ]]; then
            printf '%s__ABOX_TRAILING_NL_KEEP__' "$v"
            return 0
        fi
        # R14-F11-02: translate YAML-only double-quoted escapes to
        # their JSON equivalents before jq: \xHH -> \u00HH, \UHHHHHHHH
        # -> a surrogate pair, and the single-letter YAML escapes
        # \0 \a \v \e \N \_ \L \P -> \uXXXX. JSON cannot decode these,
        # so without translation a legal YAML password such as
        # "\x61\x62\x63" (real secret "abc") fell through to the raw
        # token fallback and was adopted as the literal "\x61\x62\x63".
        # The scan is escape-aware: a doubled backslash is consumed as
        # one literal backslash, so "\\x61" stays literal "\x61".
        # A still-undecodable token is a genuinely invalid escape: fail
        # closed (rc 1, no output) instead of returning the raw token
        # with rc 0, which callers adopted as a real credential.
        local _j='' _k=0 _tlen=${#_tok} _ch='' _nx='' _hx='' _cp=0 _hi=0 _lo=0
        while (( _k < _tlen )); do
            _ch=${_tok:_k:1}
            if [[ "$_ch" == '\' && $(( _k + 1 )) -lt _tlen ]]; then
                _nx=${_tok:_k+1:1}
                case "$_nx" in
                    x)
                        _hx=${_tok:_k+2:2}
                        if [[ "${#_hx}" == 2 && "$_hx" =~ ^[0-9A-Fa-f]{2}$ ]]; then
                            _j+="\\u00$_hx"; _k=$(( _k + 4 )); continue
                        fi
                        ;;
                    U)
                        _hx=${_tok:_k+2:8}
                        if [[ "${#_hx}" == 8 && "$_hx" =~ ^[0-9A-Fa-f]{8}$ ]]; then
                            _cp=$(( 16#$_hx ))
                            if (( _cp <= 0x10FFFF )); then
                                if (( _cp <= 0xFFFF )); then
                                    printf -v _hx '%04x' "$_cp"; _j+="\\u$_hx"
                                else
                                    _hi=$(( 0xD800 + ((_cp - 0x10000) >> 10) ))
                                    _lo=$(( 0xDC00 + ((_cp - 0x10000) & 0x3FF) ))
                                    printf -v _hx '%04x' "$_hi"; _j+="\\u$_hx"
                                    printf -v _hx '%04x' "$_lo"; _j+="\\u$_hx"
                                fi
                                _k=$(( _k + 10 )); continue
                            fi
                        fi
                        ;;
                    0) _j+='\u0000'; _k=$(( _k + 2 )); continue ;;
                    a) _j+='\u0007'; _k=$(( _k + 2 )); continue ;;
                    v) _j+='\u000B'; _k=$(( _k + 2 )); continue ;;
                    e) _j+='\u001B'; _k=$(( _k + 2 )); continue ;;
                    N) _j+='\u0085'; _k=$(( _k + 2 )); continue ;;
                    _) _j+='\u00A0'; _k=$(( _k + 2 )); continue ;;
                    L) _j+='\u2028'; _k=$(( _k + 2 )); continue ;;
                    P) _j+='\u2029'; _k=$(( _k + 2 )); continue ;;
                    '\') _j+='\\'; _k=$(( _k + 2 )); continue ;;
                esac
            fi
            _j+="$_ch"; _k=$(( _k + 1 ))
        done
        _tok="$_j"
        # R15-F11-04: a NUL in the decoded value cannot survive
        # Bash command substitution (it is silently deleted), so a
        # password such as "ab\0cd" would be adopted as "abcd".
        # Refuse it inside jq, before the value ever reaches the
        # shell: a literal backslash-u0000 text decodes to plain
        # characters and is unaffected.
        _dec=$(printf '%s' "$_tok" | jq -r 'if contains("\u0000") then error("NUL in double-quoted scalar") else . + "__ABOX_TRAILING_NL_KEEP__" end' 2>/dev/null) || return 1
        printf '%s' "$_dec"
        return 0
    fi
    # Single-quoted: scan for the closing quote; '' inside the
    # quotes is a literal quote, '#' inside is content.
    if [[ "$v" == "$q"* ]]; then
        _len=${#v}
        _i=1
        while (( _i < _len )); do
            _c=${v:_i:1}
            if [[ "$_c" == "$q" ]]; then
                if [[ "${v:_i+1:1}" == "$q" ]]; then _out+="$_c"; _i=$(( _i + 2 )); continue; fi
                _close=$_i; break
            fi
            _out+="$_c"; _i=$(( _i + 1 ))
        done
        if (( _close < 0 )); then
            # Unterminated: old fallback — strip the leading quote
            # only, then unescape '' -> '.
            _out=${v:1}
            _out=${_out//"$q$q"/"$q"}
            printf '%s__ABOX_TRAILING_NL_KEEP__' "$_out"
            return 0
        fi
        _rest=${v:_close+1}
        _sfx="$_rest"
        while [[ "$_sfx" == ' '* || "$_sfx" == $'\t'* || "$_sfx" == $'\r'* ]]; do _sfx=${_sfx:1}; done
        if [[ -n "$_sfx" && "$_sfx" != '#'* ]]; then
            printf '%s__ABOX_TRAILING_NL_KEEP__' "$v"
            return 0
        fi
        printf '%s__ABOX_TRAILING_NL_KEEP__' "$_out"
        return 0
    fi
    # Plain: cut at the first ' #' (YAML comment) and trim trailing space.
    case "$v" in
        *' #'*) v=${v%%' #'*} ;;
    esac
    while [[ "$v" == *' ' || "$v" == *$'\t' ]]; do v=${v%?}; done
    printf '%s__ABOX_TRAILING_NL_KEEP__' "$v"
}

# Decode a YAML block scalar body already collected in _bs_lines (base
# indent stripped, blank lines kept as empty entries). Inputs (globals
# set by the caller): _bs_lines (array), _bs_folded (0 literal / 1
# folded), _bs_chomp (strip/clip/keep). Outputs _hy2_bs_pw (decoded
# value) and _hy2_bs_count (non-empty body lines). Returns 1 on an
# empty body, or on a literal body with more than one non-empty line
# (a password/secret is a single line; a multi-line literal body is
# refused fail-closed, mirroring the R15-F11-03 password path).
# Shared by the password: path and the userpass: entries: a
# block-scalar header ('|-', '|', '>-', ...) is never a credential.
_hy2_decode_block_scalar_lines() {
    local _bs_started=0 _bs_nl='' _bs_line='' _bs_prev_more=0 _bs_more=0
    _hy2_bs_pw=''; _hy2_bs_count=0
    if (( _bs_folded == 1 )); then
        for _bs_line in "${_bs_lines[@]}"; do
            if [[ -z "$_bs_line" ]]; then
                _bs_nl+=$'\n'
                continue
            fi
            # 05h-M2: a more-indented line keeps the line breaks
            # around it. The old code only looked at the current
            # line, so an ordinary line after a more-indented one
            # was folded to a space instead of keeping the break.
            # R41a-M2: a blank line next to a more-indented line
            # needs one extra break: the blank contributes one newline
            # and the more-indented transition another (PyYAML oracle:
            # 'a\n  b\n\nc', 'a\n\n  b'). The old claim that blank
            # lines never matter was wrong in exactly this case.
            if [[ "$_bs_line" == ' '* || "$_bs_line" == $'\t'* ]]; then _bs_more=1; else _bs_more=0; fi
            _hy2_bs_count=$(( _hy2_bs_count + 1 ))
            if (( _bs_started == 0 )); then
                _hy2_bs_pw="$_bs_nl$_bs_line"
                _bs_started=1
            elif [[ -n "$_bs_nl" ]]; then
                if (( _bs_prev_more == 1 || _bs_more == 1 )); then
                    _hy2_bs_pw+="$_bs_nl"$'\n'"$_bs_line"
                else
                    _hy2_bs_pw+="$_bs_nl$_bs_line"
                fi
            elif (( _bs_more == 1 )); then
                _hy2_bs_pw+=$'\n'"$_bs_line"
            elif (( _bs_prev_more == 1 )); then
                _hy2_bs_pw+=$'\n'"$_bs_line"
            else
                _hy2_bs_pw+=" $_bs_line"
            fi
            _bs_prev_more=$_bs_more
            _bs_nl=''
        done
        (( _bs_started == 1 )) || return 1
        case "$_bs_chomp" in
            strip) : ;;
            clip) _hy2_bs_pw+=$'\n' ;;
            keep) _hy2_bs_pw+="$_bs_nl"$'\n' ;;
        esac
    else
        for _bs_line in "${_bs_lines[@]}"; do
            if [[ -n "$_bs_line" ]]; then
                _hy2_bs_count=$(( _hy2_bs_count + 1 ))
                if (( _hy2_bs_count > 1 )); then
                    return 1
                fi
            fi
            if (( _bs_started == 0 )); then
                _hy2_bs_pw="$_bs_line"
                _bs_started=1
            else
                _hy2_bs_pw+=$'\n'"$_bs_line"
            fi
        done
        (( _bs_started == 1 )) || return 1
        case "$_bs_chomp" in
            strip) while [[ "$_hy2_bs_pw" == *$'\n' ]]; do _hy2_bs_pw=${_hy2_bs_pw%$'\n'}; done ;;
            clip) while [[ "$_hy2_bs_pw" == *$'\n' ]]; do _hy2_bs_pw=${_hy2_bs_pw%$'\n'}; done; _hy2_bs_pw+=$'\n' ;;
            keep) _hy2_bs_pw+=$'\n' ;;
        esac
    fi
    (( _hy2_bs_count >= 1 )) || return 1
    return 0
}

users_hy2_read_users() {
    local cfg="$1" block='' type='' pw='' out='[]' _bs_folded=0 _bs_chomp='' _bs_ind='' _bs_count=0 _bs_line='' _bs_re='' _bs_lines=()
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    # R16-F11-03: the block carries a sentinel last line so blank
    # lines at its end survive command substitution (a keep-chomped
    # block scalar needs them); the sentinel ends parsing like a
    # following top-level key would.
    block=$(awk '/^auth:/{f=1} f && /^[^[:space:]#]/{if ($0 !~ /^auth:/) exit} f{print} END { print "__ABOX_HY2_BLOCK_END__" }' "$cfg" 2>/dev/null) || return 1
    [[ -n "$block" ]] || return 1
        # R41a-M3: strip a trailing ' #' comment before comparing:
        # tr only deletes quotes/spaces, so 'type: userpass # x'
        # became 'userpass#x' and fell through to the password path
        # (fail-closed, but a legal config failed to read). The
        # password: value needs no such strip: its block-scalar header
        # regex allows a comment, and users_hy2_yaml_scalar strips
        # ' #' itself.
        type=$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*type:[[:space:]]*//p' | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"' \r')
    if [[ "$type" == 'userpass' ]]; then
        # Indent-relative: userpass at any indent, entries at +2.
        out=$(printf '%s\n' "$block" | awk '
            u == "" && /^[[:space:]]*userpass:/{match($0, /^ */); u=RLENGTH; next}
            u != "" && /^[[:space:]]*$/ { if (bs) print "B"; next }
            u != "" && /^[[:space:]]*#/ && !bs { next }
            u != "" {
                match($0, /^ */); ind=RLENGTH
                if (ind <= u) exit
                if (bs && ind != u + 2) {
                    if (!bind) bind=ind
                    line=substr($0, bind+1); sub(/\r$/, "", line)
                    printf "B%s\n", line
                    next
                }
                if (ind != u + 2) next
                bs=0; bind=0
                line=$0; sub(/^ */, "", line)
                sq=sprintf("%c", 39)
                q=substr(line, 1, 1)
                k=1
                if (q == "\"" || q == sq) k=2
                else q=""
                sep=0
                for (; k <= length(line); k++) {
                    c=substr(line, k, 1)
                    nx=substr(line, k+1, 1)
                    if (q == "\"") {
                        if (c == "\\") { k++; continue }
                        if (c == "\"") q=""
                        continue
                    }
                    if (q == sq) {
                        if (c == sq) {
                            if (nx == sq) k++
                            else q=""
                        }
                        continue
                    }
                    if (c == "#" && (k == 1 || substr(line, k-1, 1) ~ /[ \t]/))
                        break
                    if (c == ":" && (nx == "" || nx ~ /[ \t]/)) {
                        sep=k
                        break
                    }
                }
                if (!sep) exit 1
                name=substr(line, 1, sep-1)
                val=substr(line, sep+1)
                sub(/^[ \t]*/, "", val)
                # H10 (05h-H1): a block-scalar header is not a
                # secret; emit a W record (folded:chomp) and let the
                # following B records carry the body.
                if (val ~ /^[|>]([+-][0-9]?|[0-9][+-]?)?[[:space:]]*(#.*)?$/) {
                    bs=1
                    folded=(substr(val, 1, 1) == ">") ? 1 : 0
                    chomp="clip"
                    # R41a-M1: decide chomping from the indicator
                    # characters only (positions 2-3, also read below
                    # for the indent). The old code searched the whole
                    # header line, so a '-' / '+' inside a trailing
                    # comment flipped clip to strip/keep. (The
                    # password: path already does it this way: it
                    # matches the indicator group only.)
                    _c2=substr(val, 2, 1); _c3=substr(val, 3, 1)
                    if (_c2 == "-" || _c3 == "-") chomp="strip"
                    else if (_c2 == "+" || _c3 == "+") chomp="keep"
                    # 05h-M1: an explicit indentation indicator N
                    # fixes the content indent at (key indent) + N;
                    # without it the first body line indent is used
                    # (the B branch below only sets bind when unset).
                    bind=0
                    if (_c2 ~ /[0-9]/) bind=(u+2)+_c2
                    else if (_c3 ~ /[0-9]/) bind=(u+2)+_c3
                    printf "K%s\nW%d:%s\n", name, folded, chomp
                } else {
                    printf "K%s\nV%s\n", name, val
                }
            }') || return 1
        local list='[]' n='' v='' _rec='' _pend_n='' _pend_v='' _pend_block=0
        _bs_lines=()
        _bs_folded=0; _bs_chomp='clip'
        # Records from awk: K<name>, V<plain value>, W<folded>:<chomp>
        # (block-scalar header), B<body line>. A K record ends the
        # previous entry, so a block body is decoded when the next K
        # arrives; the trailing sentinel K flushes the last entry.
        while IFS= read -r _rec; do
            case "${_rec:0:1}" in
            K)
                if [[ -n "$_pend_n" ]]; then
                    if (( _pend_block == 1 )); then
                        _hy2_decode_block_scalar_lines || return 1
                        v="$_hy2_bs_pw"
                    else
                        v=$(users_hy2_yaml_scalar "$_pend_v") || return 1
                        v=${v%__ABOX_TRAILING_NL_KEEP__}
                    fi
                    n=$(users_hy2_yaml_scalar "$_pend_n") || return 1
                    n=${n%__ABOX_TRAILING_NL_KEEP__}
                    list=$(printf '%s' "$list" | jq -c --arg n "$n" --rawfile v <(printf '%s' "$v") '. + [{name: $n, secret: $v}]') || return 1
                fi
                _pend_n=${_rec#K}
                _pend_v=''; _pend_block=0; _bs_lines=()
                ;;
            V)
                _pend_v=${_rec#V}
                _pend_block=0
                ;;
            W)
                _pend_block=1
                _bs_folded=0; _bs_chomp='clip'
                case "${_rec#W}" in
                    1:*) _bs_folded=1 ;;
                esac
                case "${_rec#W}" in
                    *:strip) _bs_chomp='strip' ;;
                    *:keep) _bs_chomp='keep' ;;
                esac
                _bs_lines=()
                ;;
            B)
                _bs_lines+=("${_rec#B}")
                ;;
            esac
        done <<< "$out"$'\nK'
        # R6C11-03 fail-closed: a userpass section that yields nothing is
        # an unrecognized mapping, not an empty user list. Returning []
        # would let adoption revoke the live credentials.
        if [[ "$list" == '[]' ]]; then return 1; fi
        printf '%s' "$list"
        return 0
    fi
    pw=$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*password:[[:space:]]*//p' | head -1)
    [[ -n "$pw" ]] || return 1
    # R15-F11-03: a block-scalar password is read from the block body.
    # The header marker itself ('|-', '|', '>-', ...) is not a password:
    # adopting it would rewrite the server secret to a public constant.
    _bs_re='^[|>]([+-][0-9]?|[0-9][+-]?)?[[:space:]]*(#.*)?$'
    if [[ "$pw" =~ $_bs_re ]]; then
        _bs_folded=0
        [[ "$pw" == '>'* ]] && _bs_folded=1
        # R16-F11-03: the chomping indicator decides the final line
        # break ('-' strips it, '+' keeps it plus trailing blank
        # lines, default clip keeps exactly one). Trailing spaces
        # and blank lines are part of the scalar value and must not
        # be trimmed or skipped: a literal body keeps its lines
        # verbatim, a folded body folds single breaks to a space and
        # keeps one break per blank line (more-indented lines keep
        # their break and indent).
        _bs_chomp='clip'
        _bs_ind="${BASH_REMATCH[1]:-}"
        case "$_bs_ind" in *'-'*) _bs_chomp='strip' ;; *'+'*) _bs_chomp='keep' ;; esac
        # 05h-M1: an explicit indentation indicator N fixes the
        # content indent at (key indent) + N; without it the first
        # body line's indent is the content indent.
        _bs_ind_num="${_bs_ind//[^0-9]/}"
        # Read the body lines verbatim via mapfile: command
        # substitution would strip the trailing blank lines a
        # keep-chomped scalar needs.
        _bs_lines=()
        mapfile -t _bs_lines < <(printf '%s\n' "$block" | awk -v _bs_ind_num="$_bs_ind_num" '
            !found && /^[[:space:]]*password:/ { match($0, /^ */); pind = RLENGTH; found = 1; next }
            found {
                if ($0 ~ /^[[:space:]]*$/) { print ""; next }
                match($0, /^ */); ind = RLENGTH
                if (ind <= pind) exit
                if (!started) { bind = (_bs_ind_num != "" ? pind + _bs_ind_num : ind); started = 1 }
                line = substr($0, bind + 1)
                sub(/\r$/, "", line)
                print line
            }')
        _hy2_decode_block_scalar_lines || return 1
        pw="$_hy2_bs_pw"
        _bs_count="$_hy2_bs_count"
    else
        pw=$(users_hy2_yaml_scalar "$pw") || return 1
        pw=${pw%__ABOX_TRAILING_NL_KEEP__}
    fi
    # R3C11-04: a deny password is not a user; returning [] keeps the
    # registry's (disabled) users intact without resurrecting the deny
    # as an enabled user on the next menu visit.
    if [[ "$pw" =~ ^ABOX-DENY-[0-9a-f]{32}$ ]]; then
        printf '[]'
        return 0
    fi
    jq -cn --rawfile v <(printf '%s' "$pw") '[{name: "main", secret: $v, password_only: true}]'
}


# Merge a fresh adoption into an existing registry (S2-NEW-04).
# $1=core $2=tag $3=registry-file $4=fresh-file (users_adopt output).
# Identity is the user NAME (login for credential-type registries): a
# fresh user with the same name is a credential ROTATION of that user
# -- its secret/uuid/flow/alterId/login/password_only update in place
# while registry metadata (created, expire_at, quota, disabled,
# blocked, usage counters) is kept. A fresh user with a new name is
# appended (auto-renamed with -N only on collision). Users in the
# registry but absent from fresh are KEPT: an overwrite redeploy
# rebuilds live config with fresh single credentials, and dropping
# them would silently delete users. server_secret: fresh wins when
# non-empty. Writes the merged registry with users_reg_write.
users_reg_merge_fresh() {
    local core="$1" tag="$2" regfile="$3" freshfile="$4" merged=''
    [[ -f "$regfile" && ! -L "$regfile" && -f "$freshfile" && ! -L "$freshfile" ]] || return 1
    merged=$(jq -c --slurpfile s "$freshfile" '
        def name_matches($f; $u):
            ($f.name == $u.name)
            or ((($f.login // "") != "") and ($f.login == ($u.login // $u.name)))
            or ((($u.login // "") != "") and ($f.name == $u.login));
        . as $r | ($s[0].users // []) as $fresh
        | .users = (
            [.users[] | . as $u
             | ([$fresh[] | select(.secret == $u.secret and (if (.password_only // false) then true else (.name == $u.name) end) and (.uuid // "") == ($u.uuid // ""))] | .[0]) as $m
             | ([$fresh[] | select(name_matches(.; $u))] | .[0]) as $nm
             # R41a-M4: the $m branch must also take password_only
             # from fresh: a mode switch with the same secret kept the
             # stale mode (the header comment already promises this
             # field updates in place).
             | if $m != null then ((if ($m.password_only // false) then $u elif (.login // "") != "" then $u elif ($m.login // "") == "" then $u else $u + {login: $m.login} end) + (if ($m.password_only // false) then {} else {flow: ($m.flow // ""), alterId: ($m.alterId // 0)} end) + {password_only: ($m.password_only // false)})
               elif $nm != null then $u + {secret: $nm.secret, uuid: ($nm.uuid // ""), flow: ($nm.flow // ""), alterId: ($nm.alterId // 0), login: ($nm.login // $nm.name), password_only: ($nm.password_only // false)}
               else $u end]
            + (reduce ([$fresh[] | . as $f | select(
                ([$r.users[] | select(.secret == $f.secret and (if ($f.password_only // false) then true else (.name == $f.name) end) and (.uuid // "") == ($f.uuid // ""))] | length == 0)
                and ([$r.users[] | select(name_matches($f; .))] | length == 0)
              )])[] as $f (
                {used: [.users[].name], out: []};
                (.used) as $used
                | (first(range(0; 1000) | (if . == 0 then $f.name else ($f.name + "-" + ((. + 1) | tostring)) end) | select(. as $c | ($used | index($c) | not))) // $f.name) as $c
                | {used: ($used + [$c]), out: (.out + [$f + (if ($f.email // "") == ($r.tag + "/" + $f.name) then {name: $c, email: ($r.tag + "/" + $c)} else {name: $c} end)])}
              ) | .out)
          )
        | .server_secret = ($s[0].server_secret // .server_secret)
    ' "$regfile" 2>/dev/null) || return 1
    [[ -n "$merged" ]] || return 1
    users_reg_write "$core" "$tag" "$merged"
}

# OBS-S1-08: reconcile user registries after an overwrite redeploy.
# A redeploy writes a fresh live config (new passwords/UUIDs) but the
# registries still hold the pre-redeploy credentials; the next issued
# link then carries stale keys while live has already moved on (for SS
# this is a dead serverKey:userKey against a fresh legacy password,
# with no error anywhere). Re-adopt every existing registry of this
# core whose tag is still present in the new live config, so the
# registry matches live before any link is issued. A registry whose
# tag is gone from live is left alone (removed-inbound behaviour is
# unchanged). Returns 1 if any present-tag re-adopt fails; the deploy
# caller treats that as a best-effort warning, never a deploy failure.
users_reg_reconcile_after_deploy() {
    local core="$1" dir='' f='' c='' t='' rc=0 _scratch='' _preserved=0 _live_rc=0
    dir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}"
    [[ -d "$dir" ]] || return 0
    for f in "$dir/$core"__*.json; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        c=$(jq -r '.core // ""' "$f" 2>/dev/null || true)
        t=$(jq -r '.tag // ""' "$f" 2>/dev/null || true)
        [[ "$c" == "$core" && -n "$t" ]] || continue
        # S2-NEW-04: adopt to scratch and MERGE (users_reg_merge_fresh)
        # instead of overwriting the registry: users absent from the
        # rebuilt live config are deploy casualties, not deletions --
        # overwriting dropped them silently (vision mu1). A registry
        # whose tag is gone from live still fails adopt and is left
        # alone (see header).
        _scratch=$(mktemp /tmp/A-Box-urecon.XXXXXX) || { rc=1; continue; }
        if users_adopt "$core" "$t" "$_scratch" >/dev/null 2>&1 && jq -e '.users' "$_scratch" >/dev/null 2>&1; then
            if users_reg_merge_fresh "$core" "$t" "$f" "$_scratch"; then
                users_normalize_default_name "$core" "$t" >/dev/null 2>&1 || rc=1
                # Restore preserved users into the live config: the
                # merge kept users the rebuilt config does not know,
                # and their links stay dead until the live config
                # regains them. Best-effort (the deploy already
                # committed): a sync failure warns but never fails
                # the deploy.
                _preserved=$(jq -r --slurpfile s "$_scratch" '[.users[] | .name] - ($s[0].users // [] | map(.name)) | length' "$f" 2>/dev/null || echo 0)
                if [[ "$_preserved" =~ ^[0-9]+$ ]] && (( _preserved > 0 )); then
                    users_sync "$core" "$t" >/dev/null 2>&1 || msg "S2-NEW-04: preserved ${_preserved} user(s) in ${core}/${t} could not be restored into the live config; their links stay dead until the next user-management sync." >&2
                fi
            else
                rc=1
            fi
        else
            # 05h-M3: the adopt failure used to be swallowed (the
            # whole if body was skipped and rc stayed 0), so a
            # present tag whose re-adopt genuinely failed looked
            # like success, and the discarded diagnostics could not
            # tell "tag deleted" from a real failure. Distinguish
            # them with the live gate: only a confirmed-absent tag
            # (rc 1) is left alone silently; a live tag (rc 0) or
            # an unverifiable config (rc 2, or no helper) is a real
            # reconcile failure, rc 1, with a warning.
            _live_rc=0
            if declare -F _users_live_inbound_exists >/dev/null 2>&1; then
                _users_live_inbound_exists "$core" "$t" || _live_rc=$?
            else
                _live_rc=2
            fi
            if [[ "$_live_rc" != 1 ]]; then
                rc=1
                msg "S2-NEW-04: re-adopt failed for ${core}/${t} though the tag could not be confirmed absent from the live config; registry left unchanged." >&2
            fi
        fi
        rm -f -- "$_scratch"
        # users_adopt fails when the tag is gone from live: leave that
        # registry alone (see header).
    done
    return "$rc"
}

# O1 (followup6 B-leg): prune stale user registries after an overwrite
# deploy. deploy_xray/deploy_singbox rebuild the live config wholesale,
# so tags the new config drops (e.g. Vision single-protocol coverage
# over an xray4 stack drops ss/xhttp) leave registries behind that no
# live inbound serves. users_reg_reconcile_after_deploy deliberately
# leaves tag-gone registries alone (S2-NEW-04 merge / F06 snapshot
# re-enable), and users_export_all then trips over them: users_link
# refuses them via the M41-NEW-01 live gate, so every deploy prints
# "Skipped user main (xray/ss)" / "(xray/xhttp)" noise (S1 O1).
# This closes that gap at the deploy tail, after reconcile and after
# standalone_preserve_restore, so a restored tag is live and kept.
# Only a registry that is ALL of the following is removed:
# - its JSON content reads as this core + a non-empty tag (identity
#   from content, never the filename; unreadable identity is kept);
# - it carries NO valid inbound_snapshot for its own tag (a snapshot
#   is the F06 multi-user-menu re-enable candidate: users_reg_ensure
#   admits it, so deleting it would destroy that path);
# - _users_live_inbound_exists confirms the tag ABSENT from the live
#   config (rc 1). A live tag (rc 0) is kept; an unverifiable config
#   (rc 2) or a missing helper is kept (fail-closed).
# Removal goes through users_registry_remove (encoder path + sidecar
# cleanup). Returns 1 if the registry dir is a symlink or a removal
# fails; deploy callers treat it as a best-effort warning, never a
# deploy failure.
users_reg_prune_stale_after_deploy() {
    local core="$1" dir='' f='' c='' t='' _live_rc=0
    dir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}"
    [[ ! -L "$dir" ]] || return 1
    [[ -d "$dir" ]] || return 0
    for f in "$dir/$core"__*.json; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        c=$(jq -r '.core // ""' "$f" 2>/dev/null || true)
        t=$(jq -r '.tag // ""' "$f" 2>/dev/null || true)
        [[ "$c" == "$core" && -n "$t" ]] || continue
        # F06 re-enable candidate: keep any registry whose snapshot
        # names its own tag (users_reg_ensure admits exactly this).
        if jq -e --arg t "$t" '.inbound_snapshot | type == "object" and .tag == $t' "$f" >/dev/null 2>&1; then
            continue
        fi
        _live_rc=0
        if declare -F _users_live_inbound_exists >/dev/null 2>&1; then
            _users_live_inbound_exists "$core" "$t" || _live_rc=$?
        else
            continue
        fi
        # rc 1 = confirmed absent: stale, remove. rc 0 = live: keep.
        # rc 2 = unverifiable: keep (fail-closed).
        if [[ "$_live_rc" == 1 ]]; then
            users_registry_remove "$core" "$t" || return 1
        fi
    done
    return 0
}

# Ensure a registry exists for (core, tag): adopt from the live config
# when missing, then merge in any config credentials the registry does
# not know yet (out-of-band changes) as auto-named users.
users_reg_ensure() {
    local core="$1" tag="$2" reg=''
    reg=$(users_reg_file "$core" "$tag")
    if [[ ! -f "$reg" ]]; then
        users_adopt "$core" "$tag" || return 1
        # R41b-M3: propagate the normalize failure, like the
        # existing-registry path below: callers must be able to tell
        # "adopted and normalized" from "adopted but not normalized".
        users_normalize_default_name "$core" "$tag" || return 1
        return 0
    fi
    jq -e '.users | type == "array"' "$reg" >/dev/null 2>&1 || return 1
    local scratch='' merged=''
    scratch=$(mktemp /tmp/A-Box-ureg.XXXXXX) || return 1
    if users_adopt "$core" "$tag" "$scratch" >/dev/null 2>&1 && jq -e '.users' "$scratch" >/dev/null 2>&1; then
        # R11C11-02: refuse a fresh-vs-registry server_secret
        # mismatch instead of silently keeping incompatible keys.
        local fresh_ss='' reg_ss=''
        fresh_ss=$(jq -r '.server_secret // ""' "$scratch" 2>/dev/null)
        reg_ss=$(jq -r '.server_secret // ""' "$reg" 2>/dev/null)
        if [[ -n "$fresh_ss" && -n "$reg_ss" && "$fresh_ss" != "$reg_ss" ]]; then
            msg "users_reg_ensure: server_secret mismatch between registry and live config; refusing to keep incompatible credentials. Reconcile manually." >&2
            rm -f -- "$scratch"; return 1
        fi
        users_reg_merge_fresh "$core" "$tag" "$reg" "$scratch" || { rm -f -- "$scratch"; return 1; }
    else
        # R10-09: a registry whose inbound was deleted keeps its
        # snapshot, but the snapshot alone must not resurrect it:
        # admit it only when the snapshot matches this tag AND a
        # live-config lookup positively confirms no inbound with
        # this tag exists. Any other adopt failure stays rc 1,
        # and the registry is left untouched (read-only).
        rm -f -- "$scratch"
        local _snap_ok=0 _live_rc=0 _cfg09=''
        if jq -e --arg t "$tag" '.inbound_snapshot | type == "object" and .tag == $t' "$reg" >/dev/null 2>&1; then
            _cfg09=$(users_cfg_of "$core" 2>/dev/null || echo '')
            if [[ -n "$_cfg09" && -f "$_cfg09" && ! -L "$_cfg09" && -s "$_cfg09" ]]; then
                # R41b-M1: probe the JSONC-stripped view for
                # xray/sing-box (same idiom as users_sync R16-F11-02):
                # raw jq on a commented config fails to parse (rc !=
                # 1), so a legal JSONC config could never prove the
                # inbound absent and the snapshot was refused. A strip
                # failure still refuses admission; on the stripped
                # view rc 1 still means "confirmed absent" and any
                # other rc means "unverifiable". Hy2 keeps the raw
                # file (YAML; the probe cannot confirm absence there).
                local _cfg09v="$_cfg09"
                if [[ "$core" == xray || "$core" == sing-box ]]; then
                    _cfg09v=$(mktemp /tmp/A-Box-ureg-json.XXXXXX) || _cfg09v=''
                    if [[ -n "$_cfg09v" ]]; then
                        jsonc_strip_comments "$_cfg09" > "$_cfg09v" 2>/dev/null || { rm -f -- "$_cfg09v"; _cfg09v=''; }
                    fi
                fi
                if [[ -n "$_cfg09v" ]]; then
                    jq -s -e --arg t "$tag" '([.[] | .inbounds[]? | select(.tag == $t)] | length) > 0' "$_cfg09v" >/dev/null 2>&1 || _live_rc=$?
                    if [[ "$_live_rc" == 1 ]]; then _snap_ok=1; fi
                fi
                [[ "$_cfg09v" != "$_cfg09" ]] && rm -f -- "$_cfg09v"
            fi
        fi
        if (( _snap_ok == 1 )); then
            return 0
        fi
        return 1
    fi
    rm -f -- "$scratch"
    users_normalize_default_name "$core" "$tag" || return 1
    return 0
}

# ---- sync: rewrite the core config's user list from the registry ----
users_sync() {
    local core="$1" tag="$2" cfg='' reg='' bak='' tmp='' tmpd='' enabled='' proto='' ssecret='' _commit_rc='' _jq_cfg='' _jq_tmp=0
    cfg=$(users_cfg_of "$core") || { msg "users_sync stage SYNC-01: users_cfg_of failed" >&2; return 1; }
    reg=$(users_reg_file "$core" "$tag")
    [[ -f "$cfg" && ! -L "$cfg" && -f "$reg" ]] || { msg "users_sync stage SYNC-02: config or registry missing" >&2; return 1; }
    proto=$(jq -r '.protocol // ""' "$reg" 2>/dev/null) || { msg "users_sync stage SYNC-03: registry protocol unreadable" >&2; return 1; }
    [[ -n "$proto" ]] || { msg "users_sync stage SYNC-04: registry protocol empty" >&2; return 1; }
    ssecret=$(jq -r '.server_secret // ""' "$reg" 2>/dev/null)
    enabled=$(jq -c '[.users[] | select(.disabled != true and ((.blocked // "") == ""))]' "$reg" 2>/dev/null) || { msg "users_sync stage SYNC-05: enabled-users filter failed" >&2; return 1; }
    bak=$(mktemp /tmp/A-Box-usync-bak.XXXXXX) || { msg "users_sync stage SYNC-06: backup temp creation failed" >&2; return 1; }
    cp -f -- "$cfg" "$bak" || { msg "users_sync stage SYNC-07: config backup copy failed" >&2; rm -f "$bak"; return 1; }
    tmpd=$(mktemp -d /tmp/A-Box-usync.XXXXXX) || { msg "users_sync stage SYNC-08: work temp creation failed" >&2; rm -f "$bak"; return 1; }
    tmp="$tmpd/config.json"
    # R16-F11-02: xray/sing-box jq reads (server-key lookup, inbound
    # snapshot reads, config rewrite) go through the JSONC-stripped
    # view, like users_adopt: raw jq on a commented config fails and
    # sync misreads the live state. Hy2 keeps the raw file (YAML).
    if [[ "$core" == xray || "$core" == sing-box ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-usync-json.XXXXXX) || { msg "users_sync stage SYNC-09: stripped-view temp creation failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
        _jq_tmp=1
        jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { msg "users_sync stage SYNC-09: JSONC strip failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    else
        _jq_cfg="$cfg"
    fi
    # SS multi-user promotion: with no stored server_secret and >1
    # enabled users, the CURRENT password becomes the server key and
    # each user's secret becomes their uPSK (their link changes; the
    # menu warns about this when the second user is added).
    local eff_ss="$ssecret" promote=0 encount=0
    encount=$(printf '%s' "$enabled" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$proto" == 'shadowsocks' && -z "$eff_ss" ]] && (( encount > 1 )); then
        case "$core" in
            xray) eff_ss=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .settings.password // ""' "$_jq_cfg" 2>/dev/null | head -1) ;;
            sing-box) eff_ss=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .password // ""' "$_jq_cfg" 2>/dev/null | head -1) ;;
            hy2) : ;;
        esac
        [[ -n "$eff_ss" ]] && promote=1
    fi
    if [[ "$proto" == 'shadowsocks' ]] && (( encount > 1 )) && [[ -z "$eff_ss" ]]; then
        msg "users_sync stage SYNC-10: shadowsocks multi-user without server key" >&2; 
        msg "${RED}[!] $(tprintf users_ss_no_server_key "$tag")${NC}"
        rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1
    fi
    # sing-box socks/mixed inbounds treat an empty users list as "no
    # authentication required" (upstream docs), so syncing zero enabled
    # users must remove the inbound instead of leaving a public
    # unauthenticated relay. The removed inbound is snapshotted into
    # the registry so a later sync with enabled users rebuilds it.
    # Route rules referencing it are KEPT: sing-box check accepts
    # dangling inbound references (top-level and logical-nested, verified
    # against 1.14.3), the rules go dead while disabled and revive on
    # rebuild, so no routing policy is lost across a disable cycle.
    local sb_snap='null' sb_snap_obj='' sb_will_delete=0 sb_will_rebuild=0 sb_snap_eligible=0
    if [[ "$proto" == 'shadowsocks' ]]; then
        case "$core" in xray|sing-box) sb_snap_eligible=1 ;; esac
    elif [[ "$core" == 'sing-box' ]] && [[ "$proto" == 'mixed' || "$proto" == 'socks' ]]; then
        sb_snap_eligible=1
    fi
    if (( sb_snap_eligible == 1 )); then
        sb_snap=$(jq -c '.inbound_snapshot // null' "$reg" 2>/dev/null || echo null)
        if (( encount == 0 )); then
            if jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" >/dev/null 2>&1; then
                sb_will_delete=1
                sb_snap_obj=$(jq -c --arg t "$tag" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" 2>/dev/null) || { msg "users_sync stage SYNC-11: inbound snapshot read failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            fi
        elif [[ "$sb_snap" != 'null' ]]; then
            jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" >/dev/null 2>&1 || sb_will_rebuild=1
        elif ! jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t)' "$_jq_cfg" >/dev/null 2>&1; then
            # U65: enabled users, inbound gone, no snapshot to rebuild from.
            # Syncing would silently do nothing; fail loudly instead.
            msg "users_sync stage SYNC-12: inbound missing with no snapshot" >&2; 
            msg "${RED}[!] ${core} ${proto} inbound ${tag} is missing and no registry snapshot exists; cannot rebuild. Re-deploy the node, then re-run sync.${NC}"
            rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1
        fi
    fi
    # U65: persist the deletion snapshot BEFORE the commit, not after it.
    # A write failure (or interruption) after commit left the registry
    # without a snapshot while the inbound was already gone, and a later
    # re-enable then silently succeeded without rebuilding.
    if (( sb_will_delete == 1 )); then
        [[ -n "$sb_snap_obj" ]] || { msg "users_sync stage SYNC-13: deletion snapshot empty" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
        local regj_pre=''
        regj_pre=$(jq -c --slurpfile ib <(printf '%s' "$sb_snap_obj") '.inbound_snapshot = $ib[0]' "$reg" 2>/dev/null) && users_reg_write "$core" "$tag" "$regj_pre" || { msg "users_sync stage SYNC-14: deletion snapshot persist failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    fi
    case "$core" in
        xray)
            xray_ensure_stats "$cfg" "$(users_api_port_of "$core")" >/dev/null 2>&1 || true
            if ! jq --arg t "$tag" --arg proto "$proto" --slurpfile users <(printf '%s' "$enabled") --rawfile ss <(printf '%s' "$eff_ss") --slurpfile snap <(printf '%s' "$sb_snap") '
                (if $proto == "shadowsocks" and ($users[0] | length) > 0 and $snap[0] != null
                    and ((.inbounds | map(.tag == $t) | any) | not)
                 then .inbounds += [$snap[0]] else . end)
                | .inbounds |= map(if .tag == $t then
                    (if $proto == "vless" then
                        .settings.clients = [$users[0][] | {id: .secret, email: .email} + (if (.flow // "") != "" then {flow: .flow} else {} end)]
                     elif $proto == "trojan" then
                        .settings.clients = [$users[0][] | {password: .secret, email: .email}]
                     elif $proto == "shadowsocks" then
                        (if ($users[0] | length) == 0 then empty
                         elif $ss != "" then
                            .settings.password = $ss
                            | .settings.clients = [$users[0][] | {password: .secret, email: .email}]
                         else
                            .settings.password = $users[0][0].secret | .settings.email = $users[0][0].email | .settings |= del(.clients) end)
                     elif $proto == "socks" then
                        .settings.auth = "password"
                        | .settings.accounts = [$users[0][] | {user: (.login // .name), pass: .secret}]
                     elif $proto == "vmess" then
                        .settings.clients = [$users[0][] | {id: .secret, email: .email} + (if (.alterId // 0) > 0 then {alterId: .alterId} else {} end)]
                     else . end)
                else . end)
                # E62-NEW-01 (candidate A): Vision and XHTTP serve the
                # same VLESS identity on two transports, and the YAML
                # generator advertises every registry UUID on both. A
                # Vision-only sync therefore left the live XHTTP inbound
                # with just main while YAML advertised XHTTP-<mu UUID>:
                # a dead chain by construction. Mirror the same enabled
                # users into the XHTTP inbound (when it exists; the map
                # is a no-op when it does not). No flow: XHTTP carries
                # no xtls-rprx-vision flow. Email is rewritten into the
                # xhttp/ namespace so stats attribution stays
                # per-inbound. The xhttp registry itself catches up on
                # the next users_reg_ensure via users_reg_merge_fresh
                # (live -> registry merge from the adopted inbound).
                | .inbounds |= map(if $t == "vision" and $proto == "vless" and .tag == "xhttp" then
                    .settings.clients = [$users[0][] | {id: .secret, email: ("xhttp/" + (.name // "main"))}]
                else . end)
            ' "$_jq_cfg" > "$tmp" 2>/dev/null; then
                msg "users_sync stage SYNC-15: xray config rewrite failed" >&2; 
                rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1
            fi
            ;;
        sing-box)
            if ! jq --arg t "$tag" --arg proto "$proto" --slurpfile users <(printf '%s' "$enabled") --rawfile ss <(printf '%s' "$eff_ss") --slurpfile snap <(printf '%s' "$sb_snap") '
                (if ($proto == "mixed" or $proto == "socks" or $proto == "shadowsocks") and ($users[0] | length) > 0 and $snap[0] != null
                    and ((.inbounds | map(.tag == $t) | any) | not)
                 then .inbounds += [$snap[0]] else . end)
                | .inbounds |= map(if .tag == $t then
                    (if $proto == "vless" or $proto == "vmess" then
                        .users = [$users[0][] | {name: .name, uuid: .secret} + (if (.flow // "") != "" then {flow: .flow} else {} end) + (if $proto == "vmess" and (.alterId // 0) > 0 then {alterId: .alterId} else {} end)]
                     elif $proto == "tuic" then
                        .users = [$users[0][] | {name: .name, uuid: .uuid, password: .secret}]
                     elif $proto == "shadowsocks" then
                        (if ($users[0] | length) == 0 then empty
                         elif $ss != "" then
                            .password = $ss | .users = [$users[0][] | {name: .name, password: .secret}]
                         else
                            .password = $users[0][0].secret | del(.users) end)
                     elif $proto == "mixed" or $proto == "socks" then
                        (if ($users[0] | length) == 0 then empty
                         else .users = [$users[0][] | {username: (.login // .name), password: .secret}] end)
                     else
                        .users = [$users[0][] | {name: .name, password: .secret}] end)
                else . end)
            ' "$_jq_cfg" > "$tmp" 2>/dev/null; then
                msg "users_sync stage SYNC-16: sing-box config rewrite failed" >&2; 
                rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1
            fi
            ;;
        hy2)
            users_hy2_write_users "$cfg" "$enabled" "$tmp" || { msg "users_sync stage SYNC-17: hy2 users write failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
            ;;
        *) msg "users_sync stage SYNC-18: unknown core" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1 ;;
    esac
    # SS promotion persistence BEFORE the commit (see U65 precedent above):
    # the config below already uses eff_ss as the server key.
    if (( promote == 1 )); then
        local regj=''
        regj=$(jq -c --rawfile ss <(printf '%s' "$eff_ss") '.server_secret = $ss' "$reg" 2>/dev/null) && users_reg_write "$core" "$tag" "$regj" || { msg "users_sync stage SYNC-19: server-secret promotion persist failed" >&2; rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1; }
    fi
    users_commit_cfg "$core" "$cfg" "$tmp" "$bak"; _commit_rc=$?
    if (( _commit_rc == 0 )); then
        rm -f "$tmp" "$bak"; rm -rf "$tmpd"
        if (( sb_will_delete == 1 )) && [[ -n "$sb_snap_obj" ]]; then
            # Snapshot already persisted pre-commit (U65); only the notice remains here.
            if [[ "$proto" == 'shadowsocks' ]]; then
                msg "${RED}[!] ${core} shadowsocks inbound ${tag}: all users are disabled, so the inbound was removed (a disabled SS inbound must not stay up with a shared password). Re-enable any user to rebuild it automatically.${NC}"
            else
                msg "${RED}[!] sing-box ${proto} inbound ${tag}: all users are disabled, so the inbound was removed (an empty users list is an unauthenticated open relay in sing-box). Re-enable any user to rebuild it automatically.${NC}"
            fi
        fi
        if (( sb_will_rebuild == 1 )); then
            local regj3=''
            regj3=$(jq -c 'del(.inbound_snapshot)' "$reg" 2>/dev/null) && users_reg_write "$core" "$tag" "$regj3" || true
            msg "${GREEN}[+] ${core} ${proto} inbound ${tag} rebuilt from the registry snapshot.${NC}"
        fi
        (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }
        return 0
    fi
    if (( _commit_rc == 2 )); then
        msg "users_sync stage SYNC-20: config commit failed and restore failed; backup kept at $bak for manual recovery" >&2
        rm -f "$tmp"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 2
    fi
    msg "users_sync stage SYNC-20: config commit failed" >&2; 
    rm -f "$tmp" "$bak"; rm -rf "$tmpd"; (( _jq_tmp == 1 )) && { rm -f -- "$_jq_cfg" 2>/dev/null; trap - RETURN; }; return 1
}

# Write a new hysteria config with the auth block replaced by $enabled
# users (JSON array). One user -> password auth; more -> userpass.
users_hy2_write_users() {
    local cfg="$1" users_json="$2" out="$3" auth_block='' count=0
    count=$(printf '%s' "$users_json" | jq 'length' 2>/dev/null || echo 0)
    if (( count == 1 )); then
        local sec=''
        # R16-F11-04: keep a trailing newline in the secret through
        # command substitution with the same sentinel the read side
        # uses: bare `jq -r` output loses it (the capture strips all
        # trailing LFs, including the value's own). Non-string values
        # pass through unchanged, as before.
        sec=$(printf '%s' "$users_json" | jq -r '.[0].secret | if type == "string" then . + "__ABOX_TRAILING_NL_KEEP__" else . end' 2>/dev/null)
        sec=${sec%__ABOX_TRAILING_NL_KEEP__}
        auth_block=$(printf 'auth:\n  type: password\n  password: %s' "$(json_escape "$sec")")
    elif (( count == 0 )); then
        # R3C11-04: mark the deny credential persistently so adoption
        # can exclude it. The prefix + 32 hex can never collide with a
        # generated user secret (rand_alnum/base64 have no such form).
        local rnd=''
        rnd=$(openssl rand -hex 16 2>/dev/null)
        [[ -n "$rnd" ]] || return 1
        rnd="ABOX-DENY-$rnd"
        auth_block=$(printf 'auth:\n  type: password\n  password: %s' "$(json_escape "$rnd")")
    else
        local lines=''
        lines=$(printf '%s' "$users_json" | jq -r '.[] | "    " + ((.login // .name) | @json) + ": " + (.secret | @json)' 2>/dev/null) || return 1
        auth_block=$(printf 'auth:\n  type: userpass\n  userpass:\n%s' "$lines")
    fi
    AUTH_BLOCK="$auth_block" awk '
        BEGIN { block = ENVIRON["AUTH_BLOCK"] }
        /^auth:/ { print block; skip = 1; next }
        skip && /^[^[:space:]#]/ { skip = 0 }
        skip && /^[[:space:]]/ { next }
        skip && /^$/ { next }
        { print }
    ' "$cfg" > "$out" || return 1
    grep -q '^auth:' "$out" || return 1
    return 0
}

# ---- per-user links ----
users_link_stem() {
    local core="$1" tag="$2"
    case "$core:$tag" in
        xray:trojan-landing) printf '%s' 'trojan-xray' ;;
        sing-box:trojan-landing) printf '%s' 'trojan-sb' ;;
        xray:trojan-landing-[0-9]*) printf 'trojan-xray-%s' "${tag#trojan-landing-}" ;;
        sing-box:trojan-landing-[0-9]*) printf 'trojan-sb-%s' "${tag#trojan-landing-}" ;;
        xray:socks5-landing) printf '%s' 'socks5-xray' ;;
        sing-box:socks5-landing) printf '%s' 'socks5-sb' ;;
        xray:socks5-landing-[0-9]*) printf 'socks5-xray-%s' "${tag#socks5-landing-}" ;;
        sing-box:socks5-landing-[0-9]*) printf 'socks5-sb-%s' "${tag#socks5-landing-}" ;;
        sing-box:tuic-in) printf '%s' 'tuic' ;;
        sing-box:anytls-in) printf '%s' 'anytls' ;;
        sing-box:shadowtls-in) printf '%s' 'shadowtls' ;;
        sing-box:vmess-ws-in|sing-box:vless-ws-in) printf '%s' 'argo' ;;
        sing-box:mixed-in|sing-box:socks-in) printf '%s' 'socks5-sb' ;;
        hy2:*) printf '%s' 'hy2' ;;
        *) printf '%s' "$tag" ;;
    esac
}

users_registered_link() {
    # $1=core $2=tag [$3=line-number, default by tag]
    # argo.link packs two URIs (register_standalone_link writes the
    # title first, then URIs in argo_links_for order): line 2 = vmess,
    # line 3 = vless. Every other stem carries one URI on line 2.
    local stem='' f='' _line="${3:-}"
    stem=$(users_link_stem "$1" "$2") || return 1
    if [[ -z "$_line" ]]; then
        case "$1:$2" in
            sing-box:vmess-ws-in) _line=2 ;;
            sing-box:vless-ws-in) _line=3 ;;
            *) _line=2 ;;
        esac
    fi
    [[ "$_line" =~ ^[1-9][0-9]*$ ]] || return 1
    f="${ABOX_DIR:-/etc/ddr}/standalone-links.d/${stem}.link"
    [[ -f "$f" && ! -L "$f" ]] || return 1
    sed -n "${_line}p" "$f" | tr -d '\r'
}

users_b64url_dec() { printf '%s' "$1" | tr '_-' '/+' | awk '{l=length($0); if (l%4==2) print $0"=="; else if (l%4==3) print $0"="; else print $0}' | base64 -d 2>/dev/null; }

# Strict percent-decoder for SS userinfo (SIP002): '%HH' must be two hex
# digits; '+' stays a literal plus; decode exactly once. '%00' is
# refused: bash cannot hold a NUL byte, so silently dropping it would
# change the credential.
_ss_pct_dec() {
    local s="$1" out='' i=0 c='' h=''
    while (( i < ${#s} )); do
        c=${s:i:1}
        if [[ "$c" == '%' ]]; then
            h=${s:i+1:2}
            [[ "${#h}" == 2 && "$h" =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
            [[ "${h,,}" != "00" ]] || return 1
            printf -v c '%b' "\x$h"
            out+="$c"
            i=$(( i + 3 ))
        else
            out+="$c"
            i=$(( i + 1 ))
        fi
    done
    printf '%s' "$out"
}

# Strict Base64/Base64URL validator for SS userinfo: charset, padding
# (1-2 '=' at the very end only), single alphabet, and length are
# checked before decoding. The shared users_b64url_dec does the decode.
_ss_b64_strict() {
    local s="$1" body='' pad=''
    [[ "$s" =~ ^[A-Za-z0-9+/=_-]+$ ]] || return 1
    body="${s%%=*}"
    pad="${s:${#body}}"
    [[ "$pad" == "" || "$pad" == "=" || "$pad" == "==" ]] || return 1
    [[ "$body" =~ ^[A-Za-z0-9+/_-]+$ ]] || return 1
    if [[ "$body" == *[-_]* ]]; then [[ "$body" != *[+/]* ]] || return 1; fi
    (( (${#s} % 4) != 1 )) || return 1
    users_b64url_dec "$s"
}

# M41-NEW-01 follow-up (S2-NEW-09): does the live config still serve
# (core, tag)? rc 0 = served, rc 1 = confirmed gone, rc 2 =
# unverifiable (symlinked / empty / unparseable config). A missing
# config file is confirmed gone: no inbound can exist without it.
# hy2-family tags on xray/hy2 cores are served by the standalone
# hysteria server, not by the xray config (xray has no hysteria2
# inbound); the sing-box hy2 inbound is a real sing-box inbound, so
# (sing-box, hy2) consults the sing-box config like any other tag.
# Registries for deleted inbounds are deliberately preserved (the
# S2-NEW-04 merge keeps their users, and the F06 snapshot path can
# re-enable them), so callers must treat rc 1 as "link dead", never
# as "registry broken". Callers must only refuse on rc 1; rc 2 keeps
# the old fail-open behaviour. The hysteria config path honours
# ABOX_HY2_CONFIG (fixture hook, same convention as
# hy2_effective_password_for_user).
_users_live_inbound_exists() {
    local _core="$1" _tag="$2" _cfg='' _stripped='' _jq_rc=0
    if [[ "$_core" == hy2 ]] || { [[ "$_core" == xray ]] && [[ "$_tag" == hy2* ]]; }; then
        _cfg="${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}"
        [[ -L "$_cfg" ]] && return 2
        [[ -f "$_cfg" ]] || return 1
        [[ -s "$_cfg" ]] || return 2
        return 0
    fi
    _cfg=$(users_cfg_of "$_core" 2>/dev/null || echo '')
    [[ -n "$_cfg" ]] || return 2
    [[ -L "$_cfg" ]] && return 2
    [[ -f "$_cfg" ]] || return 1
    [[ -s "$_cfg" ]] || return 2
    _stripped=$(jsonc_strip_comments "$_cfg" 2>/dev/null) || return 2
    [[ -n "${_stripped//[[:space:]]/}" ]] || return 2
    printf '%s' "$_stripped" | jq -s -e --arg t "$_tag" '([.[] | (.inbounds[]? | select((.tag // "") == $t))] | length) > 0' >/dev/null 2>&1 || _jq_rc=$?
    case "$_jq_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Build the connection link for one registry user.
# $1=core $2=tag $3=name -> prints link on stdout
users_link() {
    local core="$1" tag="$2" name="$3" reg='' user='' main='' proto='' ssecret=''
    reg=$(users_reg_file "$core" "$tag")
    [[ -f "$reg" ]] || return 1
    user=$(jq -c --arg n "$name" '.users[] | select(.name == $n)' "$reg" 2>/dev/null) || return 1
    [[ -n "$user" && "$user" != 'null' ]] || return 1
    main=$(jq -c '.users[] | select(.name == "main")' "$reg" 2>/dev/null)
    proto=$(jq -r '.protocol // ""' "$reg" 2>/dev/null)
    # R41b-M2: keep trailing newlines (same sentinel idiom as
    # users_sync): plain command substitution strips them, so a
    # secret "p\n" became "p" in the link while the server config
    # keeps "p\n". Same for server_secret: it joins the same eff.
    ssecret=$(jq -r '(.server_secret // "") | if type == "string" then . + "__ABOX_TRAILING_NL_KEEP__" else . end' "$reg" 2>/dev/null)
    ssecret=${ssecret%__ABOX_TRAILING_NL_KEEP__}
    local enabled_count=0
    enabled_count=$(jq -r '[.users[] | select(.disabled != true and ((.blocked // "") == ""))] | length' "$reg" 2>/dev/null) || return 1
    local secret='' use_uuid=''
    secret=$(printf '%s' "$user" | jq -r '(.secret // "") | if type == "string" then . + "__ABOX_TRAILING_NL_KEEP__" else . end')
    secret=${secret%__ABOX_TRAILING_NL_KEEP__}
    use_uuid=$(printf '%s' "$user" | jq -r '.uuid // ""')
    [[ -n "$secret" ]] || return 1
    # M41-NEW-01 follow-up (S2-NEW-09): a registry whose inbound is
    # gone from the live config must not yield a link. The deploy
    # preserves such registries deliberately (S2-NEW-04 merge), so
    # the export layer has to skip them, or the subscription keeps
    # serving the dead chain. Only a CONFIRMED absence refuses
    # (rc 1); an unverifiable config (rc 2) keeps the old fail-open
    # behaviour. The declare -F guard keeps pre-fix callers working
    # (the helper is new; without it the gate is skipped).
    if declare -F _users_live_inbound_exists >/dev/null 2>&1; then
        local _live_rc=0
        _users_live_inbound_exists "$core" "$tag" || _live_rc=$?
        if [[ "$_live_rc" == 1 ]]; then return 1; fi
    fi
    # Combo inbounds (either core) build from .env + live config values.
    if [[ "$tag" == 'vision' || "$tag" == 'xhttp' || "$tag" == 'ss' || "$tag" == 'hy2' ]] && [[ "$core" == 'xray' || "$core" == 'sing-box' ]]; then
        users_link_combo "$core" "$tag" "$name" "$secret" "$ssecret" "$proto" "$enabled_count"
        return $?
    fi
    local link='' msecret=''
    link=$(users_registered_link "$core" "$tag") || return 1
    [[ -n "$link" ]] || return 1
    msecret=$(printf '%s' "$main" | jq -r '.secret // ""')
    local frag="#$(urlencode "$tag")-$(urlencode "$name")"
    if [[ "$link" == ss://* ]]; then
        # SIP002 plaintext (method:credential, percent-encoded) or
        # legacy Base64 userinfo; split on structure, never guess:
        # a literal ':' means plaintext, anything else must be strict
        # Base64 decoding to method:credential. A stored link with no
        # outer '@' (e.g. ShadowTLS ss://<b64>?shadow-tls=...) is
        # refused explicitly (return 1): its inner/outer credentials
        # cannot be mapped to this user's secret here.
        local rest="${link#ss://}" userinfo='' hostpart='' plain='' method='' eff='' query=''
        rest="${rest%%#*}"
        if [[ "$rest" == *\?* ]]; then
            query="?${rest#*\?}"
            rest="${rest%%\?*}"
        fi
        [[ "$rest" == *@* ]] || return 1
        userinfo="${rest%%@*}"; hostpart="${rest#*@}"
        [[ -n "$userinfo" && -n "$hostpart" ]] || return 1
        [[ "$hostpart" != *@* ]] || return 1
        if [[ "$userinfo" == *:* ]]; then
            # Plaintext: split on the FIRST literal ':' only, then
            # strict percent-decode each side once ('+' stays literal).
            local _m_enc="${userinfo%%:*}" _c_enc="${userinfo#*:}" _m_dec='' _c_dec=''
            _m_dec=$(_ss_pct_dec "$_m_enc") || return 1
            _c_dec=$(_ss_pct_dec "$_c_enc") || return 1
            method="$_m_dec"
        else
            plain=$(_ss_b64_strict "$userinfo") || return 1
            [[ "$plain" == *:* ]] || return 1
            method="${plain%%:*}"
        fi
        case "$method" in
            2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) ;;
            *) return 1 ;;
        esac
        if [[ -n "$ssecret" ]]; then eff="${ssecret}:${secret}"; else eff="$secret"; fi
        printf 'ss://%s:%s@%s%s%s' \
            "$(urlencode "$method")" "$(urlencode "$eff")" "$hostpart" "$query" "$frag"
        return 0
    fi
    # R5C11-04: vmess://BASE64 has no userinfo@host; decode the
    # JSON, replace id (target uuid) and ps (target name),
    # re-encode. Standard base64 first, url-safe fallback.
    if [[ "$link" == vmess://* ]]; then
        # R10-11: legacy rows may carry the uuid only in .secret
        # (add-user used to leave .uuid empty for vmess); fall
        # back to it before the guard so the link still builds.
        use_uuid="${use_uuid:-$secret}"
        [[ -n "$use_uuid" ]] || return 1
        local vblob='' vjson='' vnew=''
        vblob="${link#vmess://}"
        vjson=$(printf '%s' "$vblob" | base64 -d 2>/dev/null) || vjson=$(users_b64url_dec "$vblob") || return 1
        [[ "$vjson" =~ [^[:space:]] ]] || return 1
        [[ -n "$vjson" ]] || return 1
        # 2fp: the template link's aid is the deploy-time default (0);
        # follow the registry user's preserved alterId so the link
        # agrees with the server config.
        local _aid=''
        _aid=$(printf '%s' "$user" | jq -r '.alterId // 0' 2>/dev/null)
        [[ "$_aid" =~ ^[0-9]+$ ]] || _aid=0
        vnew=$(printf '%s' "$vjson" | jq -c --rawfile id <(printf '%s' "$use_uuid") --arg ps "$name" --arg aid "$_aid" '.id = $id | .ps = $ps | .aid = $aid' 2>/dev/null) || return 1
        printf 'vmess://%s' "$(printf '%s' "$vnew" | (base64 -w0 2>/dev/null || base64) | tr -d '\n')"
        return 0
    fi
    # Generic userinfo substitution: scheme://userinfo@rest
    local scheme='' rest2='' userinfo2='' hostpart2=''
    scheme="${link%%://*}"; rest2="${link#*://}"
    userinfo2="${rest2%%@*}"; hostpart2="${rest2#*@}"
    hostpart2="${hostpart2%%#*}"
    local newinfo=''
    if [[ "$proto" == 'tuic' ]]; then
        # R10C11-02: a stale template (old uuid/secret) must not
        # lose the whole inbound; substitute current credentials.
        newinfo="$(urlencode "$use_uuid"):$(urlencode "$secret")" 
    elif [[ "$core" == 'hy2' ]]; then
        # H-24(1) follow-up: the userinfo is the EFFECTIVE password for
        # THIS user, from the live server config: in userpass mode
        # "login:secret" as ONE urlencoded string (a literal ':' is
        # parsed by sing-box as password=<secret> only and the server
        # 404s); in password-only mode the bare server password. The
        # old code urlencoded login and secret separately, leaving a
        # literal ':' -- and used the stale registry secret.
        local ulogin='' _hy2_eff=''
        ulogin=$(printf '%s' "$user" | jq -r '(.login // .name) // ""')
        _hy2_eff=$(hy2_effective_password_for_user "$ulogin" 2>/dev/null || true)
        if [[ -n "$_hy2_eff" ]]; then
            _hy2_eff=${_hy2_eff%__ABOX_TRAILING_NL_KEEP__}
            newinfo="$(urlencode "$_hy2_eff")"
        elif (( enabled_count >= 2 )) && [[ -n "$ulogin" ]]; then
            # Live lookup failed (stale user or unreadable config):
            # fall back to the registry credential, still as ONE
            # urlencoded userinfo so no literal colon leaks.
            newinfo="$(urlencode "$ulogin:$secret")"
        else
            newinfo="$(urlencode "$secret")"
        fi
    else
        if [[ "$scheme" == 'socks5' || "$scheme" == 'mixed' ]]; then
            # R1-11-F07: server authenticates by .login // .name;
            # use the login for the target userinfo. R10C11-02:
            # a stale template must not fail the link.
            local ulogin=''
            ulogin=$(printf '%s' "$user" | jq -r '(.login // .name) // ""')
            newinfo="$(urlencode "$ulogin"):$(urlencode "$secret")"
        else
            # R10C11-02: stale template -> substitute anyway.
            newinfo="$(urlencode "$secret")"
        fi
    fi
    printf '%s://%s@%s%s' "$scheme" "$newinfo" "$hostpart2" "$frag"
    return 0
}

# Combo link builder (vision / xhttp / ss / sing-box hy2) from .env for
# shared REALITY parameters plus the live config for ports and method.
users_link_combo() {
    local core="$1" tag="$2" name="$3" secret="$4" ssecret="$5" proto="$6" encount="${7:-1}"
    [[ -f "${ABOX_ENV:-/etc/ddr/.env}" ]] && load_abox_env "$ABOX_ENV" 2>/dev/null || true
    local ip='' cfg='' port=''
    ip="${LINK_IP:-}"
    [[ -n "$ip" ]] || ip=$(read_cached_public_ip 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(get_public_ip 2>/dev/null || true)
    [[ -n "$ip" ]] || ip='<server-ip>'
    cfg=$(users_cfg_of "$core") || return 1
    # M-6-rescan (B-leg): Xray configs may carry // comments jq
    # rejects, so strip once here and read the stripped view at
    # every jq point below. sing-box configs are strict JSON, so
    # the strip is a no-op for them; any other core keeps the raw
    # file (hy2 is YAML, never JSONC) so behaviour is unchanged.
    # jsonc_strip_comments falls back to cat on failure, so a
    # strip failure reads exactly as before (fail-closed).
    local _jq_stripped=''
    if [[ "$core" == xray || "$core" == sing-box ]]; then
        _jq_stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null)
    else
        _jq_stripped=$(cat "$cfg" 2>/dev/null || true)
    fi
    local pbk="${PUBLIC_KEY:-}" sid="${SHORT_ID:-}"
    case "$tag" in
        vision)
            port=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.port // .listen_port // "")' 2>/dev/null | head -1)
            local sni="${VISION_SNI:-${VLESS_SNI:-}}"
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-%s' \
                "$(urlencode "$secret")" "$(uri_host "$ip")" "${port:-${VLESS_PORT:-443}}" "$sni" "$pbk" "$sid" "$(urlencode "$tag")" "$(urlencode "$name")" ;;
        xhttp)
            port=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.port // .listen_port // "")' 2>/dev/null | head -1)
            local sni="${XHTTP_SNI:-${VLESS_SNI:-}}"
            # R15-F11-05: the path is not always /xhttp: read it from
            # the live inbound (other readers, e.g. the TSV extract
            # and the SNI check, already do), defaulting to /xhttp.
            local xpath=''
            xpath=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.xhttpSettings.path // "/xhttp"' 2>/dev/null | head -1)
            [[ -n "$xpath" ]] || xpath='/xhttp'
            printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&host=%s&path=%s&mode=stream-one#%s-%s' \
                "$(urlencode "$secret")" "$(uri_host "$ip")" "${port:-${XHTTP_PORT:-8443}}" "$sni" "$pbk" "$sid" "$sni" "$(urlencode "$xpath")" "$(urlencode "$tag")" "$(urlencode "$name")" ;;
        ss)
            port=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.port // .listen_port // "")' 2>/dev/null | head -1)
            local method='' eff=''
            method=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.method // .settings.method // "")' 2>/dev/null | head -1)
            [[ -n "$method" ]] || method='2022-blake3-aes-128-gcm'
            if [[ -n "$ssecret" ]]; then eff="${ssecret}:${secret}"; else eff="$secret"; fi
            printf 'ss://%s:%s@%s:%s#%s-%s' \
                "$(urlencode "$method")" "$(urlencode "$eff")" \
                "$(uri_host "$ip")" "${port:-${SS_PORT:-2053}}" "$(urlencode "$tag")" "$(urlencode "$name")" ;;
        hy2)
            local obfs='' obfs_type='' sni='' cert_path='' acme_domain='' insecure=1 q='' pin='' _hy2_ep='' _hy2_qp='' _hy2_host=''
            obfs=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .obfs.password // ""' 2>/dev/null | head -1)
            obfs_type=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .obfs.type // ""' 2>/dev/null | head -1)
            sni=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tls.server_name // ""' 2>/dev/null | head -1)
            # R15C11-03: keep certificate validation for trusted
            # certificates; only self-signed (or undeterminable)
            # keeps insecure=1. ACME implies publicly trusted.
            # 06a1-M4: .tls.acme.domain is an ARRAY in sing-box:
            # plain `jq -r` prints it as several lines whose first
            # is `[`, so the old `| head -1` read `[` as the domain
            # (non-empty, so it misjudged the link trusted AND used
            # `[` as the URI host). Take the first element when it
            # is an array (empty array -> no domain), and keep
            # accepting a plain string for tolerance.
            acme_domain=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.tls.acme.domain | if type == "array" then (.[0] // "") elif type == "string" then . else "" end)' 2>/dev/null | head -1)
            if [[ -n "$acme_domain" ]]; then
                insecure=0
            else
                cert_path=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tls.certificate_path // ""' 2>/dev/null | head -1)
                if [[ -n "$cert_path" && -f "$cert_path" ]] && command -v openssl >/dev/null 2>&1; then
                    local _iss='' _sub=''
                    _iss=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
                    _sub=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/^subject= *//')
                    if [[ -n "$_iss" && -n "$_sub" && "$_iss" != "$_sub" ]]; then insecure=0; fi
                fi
            fi
            # H-07: port-hop endpoint, like the standalone path; a bad
            # endpoint refuses this user link only.
            IFS=$'\t' read -r _hy2_ep _hy2_qp < <(build_hy2_uri_endpoint 2>/dev/null || true) || return 1
            [[ -n "$_hy2_ep" ]] || return 1
            # H-07 (SYD-B4 A3, standalone parity): insecure=1 requires a
            # non-empty pinSHA256. Try the live certificate first, then
            # the .env fingerprint; refuse the link when neither yields
            # a pin. The trusted-certificate branch (insecure=0) never
            # carries a pin and is unaffected.
            if (( insecure == 1 )); then
                pin=$(hy2_cert_pin_colon "$cert_path" 2>/dev/null || true)
                if [[ -z "$pin" && "${HY2_CERT_SHA256_FP:-}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
                    pin=$(sed 's/\(..\)/\1:/g; s/:$//' <<< "${HY2_CERT_SHA256_FP}")
                fi
                [[ -n "$pin" ]] || return 1
            fi
            [[ -n "$sni" ]] || sni='localhost'
            if (( insecure == 1 )); then q="insecure=1&pinSHA256=$(urlencode "$pin")"; fi
            if [[ -n "$q" ]]; then q+="&sni=$sni"; else q="sni=$sni"; fi
            if [[ -n "$obfs_type" ]]; then q+="&obfs=$obfs_type&obfs-password=$(urlencode "$obfs")"; fi
            # M-35: host priority is the live ACME domain, then the
            # deployment domain, then the IP -- never a bare IP when a
            # domain is configured for this Hy2 node.
            _hy2_host="${acme_domain:-}"
            [[ -n "$_hy2_host" ]] || _hy2_host="${HY2_DOMAIN:-}"
            [[ -n "$_hy2_host" ]] || _hy2_host="$ip"
            # M41-NEW-01 (Carbon R3 follow-up 2): mode-aware userinfo.
            # The standalone hysteria server switches to
            # `auth: type: userpass` once a second Hy2 user exists, and
            # a bare password then has no matching user (live 404).
            # Mirror the users_link core==hy2 path (H-24(1)): ask the
            # live server config for THIS user's effective credential --
            # "login:secret" as ONE urlencoded string in userpass mode,
            # the bare server password in password mode. A lookup
            # failure (no standalone server: a pure sing-box deploy
            # prunes /etc/hysteria, and its own hysteria2 inbound is
            # password-only with a display-only name, R1-11-F05) keeps
            # the historical bare registry secret, so the sing-box link
            # is byte-identical. The helper honors ABOX_HY2_CONFIG as
            # its config-path override (fixture hook, same convention
            # as _wallos_hy2_http01_keeps_80).
            local _hy2_eff='' _hy2_userinfo=''
            _hy2_eff=$(hy2_effective_password_for_user "$name" 2>/dev/null || true)
            if [[ -n "$_hy2_eff" ]]; then
                _hy2_eff=${_hy2_eff%__ABOX_TRAILING_NL_KEEP__}
                _hy2_userinfo="$(urlencode "$_hy2_eff")"
            else
                _hy2_userinfo="$(urlencode "$secret")"
            fi
            printf 'hysteria2://%s@%s:%s?%s#%s-%s' \
                "$_hy2_userinfo" "$(uri_host "$_hy2_host")" "$_hy2_ep" "$q" "$(urlencode "$tag")" "$(urlencode "$name")" ;;
        *) return 1 ;;
    esac
    return 0
}

# S2-NEW-03: subscription files are deployment products. Refresh the
# export at the end of every deploy so subscribers never keep serving
# links the deploy just deleted or rotated (a stale file otherwise
# survives until menu E). Best-effort: the deploy already committed,
# so an export failure warns but must not fail it; callers use `|| true`.
# S2-NEW-03 follow-up: also called after a committed registry change
# (users_apply_reg) and on a manual menu-12 reprint (view_config,
# CALLER != deploy); the "after_deploy" name is historical.
refresh_subscription_after_deploy() {
    local _n
    # S2-NEW-12: the deploy-time export used to run before any
    # standalone link existed (rebuild_standalone_links runs only at
    # the END of view_config), so the hy2 registry -- whose link comes
    # from hy2.link, not from the combo builder -- was always skipped
    # on a fresh deploy, until the first menu 12 reprint. Rebuild
    # first so the export reads the same links menu 12 would print.
    # F_IP is derived here because rebuild reads the caller's F_IP
    # (bash dynamic scoping) and view_config is the only caller that
    # sets it; without this the rebuild early-returns when there is
    # no HY2_DOMAIN. Best-effort like the export itself: a rebuild
    # failure must not fail the deploy.
    # S2-NEW-12 follow-up 5: LINK_IP is unset in a fresh-deploy
    # process (main_loop loads .env only if it exists; deploy_xray's
    # load_optional_abox_env_or_die clears it when there is no .env;
    # pre_install_setup sets only GLOBAL_PUBLIC_IP; write_env writes
    # LINK_IP to .env but never sets the shell variable), so deriving
    # F_IP from LINK_IP alone left the rebuild early-returning and
    # the deploy-time export without Hy2. Fall back through the
    # sources that do exist on the deploy path: GLOBAL_PUBLIC_IP
    # (set by pre_install_setup / main_loop), the LINK_IP just
    # written to .env (single-key read -- never a full load_abox_env
    # here: it clears every deploy variable on entry and wipes them
    # again on any validation failure), then the public-IP cache.
    # 'N/A' is treated as empty, like the view_config gate.
    local _s2n12_fip="${LINK_IP:-}"
    # 06a1-M3: normalize 'N/A' to empty at EACH step, not only at
    # the end of the chain. 'N/A' is non-empty, so it used to block
    # every later fallback (GLOBAL_PUBLIC_IP, .env, cache) and the
    # final F_IP came out empty, even though the comment calls
    # 'N/A' empty "like the view_config gate".
    [[ "$_s2n12_fip" == 'N/A' ]] && _s2n12_fip=''
    [[ -n "$_s2n12_fip" ]] || _s2n12_fip="${GLOBAL_PUBLIC_IP:-}"
    [[ "$_s2n12_fip" == 'N/A' ]] && _s2n12_fip=''
    if [[ -z "$_s2n12_fip" && -f "${ABOX_ENV:-/etc/ddr/.env}" ]]; then
        _s2n12_fip=$(sed -n 's/^LINK_IP="\([^"]*\)"$/\1/p' "${ABOX_ENV}" 2>/dev/null | head -1)
    fi
    [[ "$_s2n12_fip" == 'N/A' ]] && _s2n12_fip=''
    [[ -n "$_s2n12_fip" ]] || _s2n12_fip=$(read_cached_public_ip 2>/dev/null || true)
    [[ "$_s2n12_fip" == 'N/A' ]] && _s2n12_fip=''
    [[ "$_s2n12_fip" =~ : ]] && _s2n12_fip="[$_s2n12_fip]"
    local F_IP="$_s2n12_fip"
    rebuild_standalone_links || true
    _n=$(users_export_all || true)
    if [[ -n "$_n" ]]; then
        msg "${GREEN}Subscription export refreshed: ${_n} link(s) (uri-list.txt / subscription.base64)${NC}"
        return 0
    fi
    msg "${YELLOW}[!] Subscription export refresh failed; subscription files may be stale until the next multi-user export (menu E).${NC}" >&2
    return 1
}

# Export every enabled user's link (all registries) in the subscription
# file formats the legacy exporter produced.
users_export_all() {
    local dir='' out='' count=0 reg='' core='' tag='' failed=0 skipped=0 seen=0
    dir="${SUBSCRIBE_DIR:-/etc/ddr/subscribe}"
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
    local tmp=''
    tmp=$(umask 077; mktemp "$dir/.uri-list.XXXXXX") || return 1
    for reg in "${ABOX_USERS_DIR:-$USERS_DIR}"/*.json; do
        [[ -f "$reg" ]] || continue
        seen=1
        core=$(jq -r '.core // ""' "$reg" 2>/dev/null) || { msg "${YELLOW}[!] Skipped registry $reg: core unreadable.${NC}" >&2; skipped=$((skipped + 1)); continue; }
        tag=$(jq -r '.tag // ""' "$reg" 2>/dev/null) || { msg "${YELLOW}[!] Skipped registry $reg: tag unreadable.${NC}" >&2; skipped=$((skipped + 1)); continue; }
        [[ -n "$core" && -n "$tag" ]] || { msg "${YELLOW}[!] Skipped registry $reg: missing core or tag.${NC}" >&2; skipped=$((skipped + 1)); continue; }
        local uname='' link='' ulist=''
        ulist=$(jq -r '.users[] | select(.disabled != true and ((.blocked // "") == "")) | .name' "$reg" 2>/dev/null) || { msg "${YELLOW}[!] Skipped registry $reg: users unreadable.${NC}" >&2; skipped=$((skipped + 1)); continue; }
        while IFS= read -r uname; do
            [[ -n "$uname" ]] || continue
            link=$(users_link "$core" "$tag" "$uname" 2>/dev/null) || { msg "${YELLOW}[!] Skipped user ${uname} (${core}/${tag}): link build failed.${NC}" >&2; skipped=$((skipped + 1)); continue; }
            [[ -n "$link" ]] || { msg "${YELLOW}[!] Skipped user ${uname} (${core}/${tag}): empty link.${NC}" >&2; skipped=$((skipped + 1)); continue; }
            printf '%s\n' "$link" >> "$tmp" && count=$((count + 1)) || failed=1
        done <<< "$ulist"
    done
    if (( failed == 1 )); then rm -f -- "$tmp"; return 1; fi
    # SYD-B E19: skipped users no longer fail the whole export.
    # With at least one success the export commits (partial
    # success, explicitly reported); with zero successes the
    # existing clear-out below still runs, so stale links never
    # keep serving revoked users.
    if (( skipped > 0 && count > 0 )); then
        msg "${YELLOW}[!] Subscription export partially succeeded: ${skipped} user(s) skipped, ${count} link(s) exported.${NC}" >&2
    elif (( skipped > 0 )); then
        msg "${YELLOW}[!] Subscription export: ${skipped} user(s) skipped and no links exported; stale subscription will be cleared.${NC}" >&2
    fi
    if (( count == 0 )); then
        # N1 diagnostic (followup5): a zero-link export is silent by
        # design when registries exist but all their links failed
        # (those paths print Skipped lines above), but it is ALSO the
        # signature of a wiped registry dir (menu 20 "all clear"), where
        # no registry was seen at all. Tell the two apart so a
        # transcript can self-explain which case it is. Export
        # semantics are unchanged: the clear-out below still runs.
        if (( seen == 0 )); then
            msg "${YELLOW}[!] Subscription export: no user registries found (users.d empty or missing); clearing subscription to 0 links.${NC}" >&2
        fi
        # No enabled users: stale links must not keep serving. Atomically
        # replace both files with empty content (the old code left the
        # previous users' links in place and only failed the export).
        # 06a1-M2: the same fail-closed rule covers the FIRST install:
        # when the empty uri-list cannot be installed, the old files
        # still hold revoked users' links -- remove them rather than
        # leaving the stale subscription serving (a missing
        # subscription fails closed; a stale one does not).
        install_file_atomically "$tmp" "$dir/uri-list.txt" 600 || { rm -f -- "$tmp" "$dir/uri-list.txt" "$dir/subscription.base64"; return 1; }
        rm -f -- "$tmp"
        local etmp=''
        # uri-list is already cleared above: if the empty base64 cannot
        # be staged or installed, remove the stale file rather than
        # leaving revoked users' links serving. A missing subscription
        # fails closed; a stale one does not.
        etmp=$(umask 077; mktemp "$dir/.sub-b64.XXXXXX") || { rm -f -- "$dir/subscription.base64"; return 1; }
        install_file_atomically "$etmp" "$dir/subscription.base64" 600 || { rm -f -- "$etmp" "$dir/subscription.base64"; return 1; }
        rm -f -- "$etmp"
        printf '%s' '0'
        return 0
    fi
    local old_list_bak='' old_existed=0
    [[ -f "$dir/uri-list.txt" ]] && old_existed=1
    old_list_bak=$(umask 077; mktemp "$dir/.uri-list-bak.XXXXXX") || { rm -f -- "$tmp"; return 1; }
    if (( old_existed == 1 )); then
        cp -f -- "$dir/uri-list.txt" "$old_list_bak" || { rm -f -- "$tmp" "$old_list_bak"; return 1; }
    fi
    install_file_atomically "$tmp" "$dir/uri-list.txt" 600 || { rm -f -- "$tmp" "$old_list_bak"; return 1; }
    rm -f -- "$tmp"
    local btmp='' b64_ok=0
    if command -v base64 >/dev/null 2>&1; then
        btmp=$(umask 077; mktemp "$dir/.sub-b64.XXXXXX") 2>/dev/null
        if [[ -n "$btmp" ]] && ( base64 -w0 < "$dir/uri-list.txt" > "$btmp" 2>/dev/null || base64 < "$dir/uri-list.txt" | tr -d '\n' > "$btmp" 2>/dev/null ) && [[ -s "$btmp" ]] && install_file_atomically "$btmp" "$dir/subscription.base64" 600; then
            b64_ok=1
        fi
        rm -f -- "$btmp"
    fi
    if (( b64_ok == 0 )); then
        if (( old_existed == 1 )); then
            install_file_atomically "$old_list_bak" "$dir/uri-list.txt" 600 || rm -f -- "$dir/uri-list.txt"
        else
            rm -f -- "$dir/uri-list.txt" "$dir/subscription.base64"
        fi
        rm -f -- "$old_list_bak"
        return 1
    fi
    rm -f -- "$old_list_bak"
    printf '%s' "$count"
    return 0
}

# ---- menu ----
users_fmt_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if (( b == 0 )); then printf '-'; return 0; fi
    awk -v b="$b" 'BEGIN { if (b < 1073741824) printf "%.1fM", b/1048576; else { v = sprintf("%.2f", b/1073741824); sub(/\.?0+$/, "", v); printf "%sG", v } }' 2>/dev/null || {
        # awk unavailable: pure-bash mirror of the same M/G format.
        if (( b < 1073741824 )); then
            local _m10=$(( (b * 10 + 524288) / 1048576 ))
            printf '%d.%dM' $(( _m10 / 10 )) $(( _m10 % 10 ))
        else
            local _g100=$(( (b * 100 + 536870912) / 1073741824 )) _frac
            _frac=$(( _g100 % 100 ))
            if (( _frac == 0 )); then printf '%dG' $(( _g100 / 100 ));
            elif (( _frac % 10 == 0 )); then printf '%d.%dG' $(( _g100 / 100 )) $(( _frac / 10 ));
            else printf '%d.%02dG' $(( _g100 / 100 )) "$_frac"; fi
        fi
    }
}
# Display width of a string: wide (CJK/fullwidth) codepoints count 2.
_str_dwidth() {
    # Locale-proof display-cell width: UTF-8 is decoded from od hex, so
    # the result is identical even where the pinned LANG locale is not
    # installed (minimal images ship only C.UTF-8; bash then counts
    # bytes, not cells). Truncated or invalid sequences degrade to one
    # cell per byte and never abort the caller.
    local hex b i=0 n cp w=0
    hex=$(printf '%s' "${1:-}" | od -An -tx1 -v | tr -d ' \n')
    n=${#hex}
    while (( i < n )); do
        b=$((16#${hex:i:2}))
        if (( b < 0x80 )); then cp=$b; i=$((i + 2))
        elif (( b >= 0xC0 && b < 0xE0 && i + 3 < n )); then cp=$(( ((b & 0x1F) << 6) | (16#${hex:i+2:2} & 0x3F) )); i=$((i + 4))
        elif (( b >= 0xE0 && b < 0xF0 && i + 5 < n )); then cp=$(( ((b & 0x0F) << 12) | ((16#${hex:i+2:2} & 0x3F) << 6) | (16#${hex:i+4:2} & 0x3F) )); i=$((i + 6))
        elif (( b >= 0xF0 && i + 7 < n )); then cp=$(( ((b & 0x07) << 18) | ((16#${hex:i+2:2} & 0x3F) << 12) | ((16#${hex:i+4:2} & 0x3F) << 6) | (16#${hex:i+6:2} & 0x3F) )); i=$((i + 8))
        else cp=0; i=$((i + 2)); fi
        if (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x33FF) || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xA000 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1FAFF) || cp >= 0x20000 )); then w=$((w + 2)); else w=$((w + 1)); fi
    done
    printf '%d' "$w"
}


# Write a mutated registry and sync it; roll the registry back when the
# sync fails. $1=core $2=tag $3=new-json $4=old-json
# Fold one live-counters snapshot into EVERY registry of a core.
# M-29 follow-up: users_apply_reg's sync restarts the whole core
# service, zeroing all tags' in-memory counters, so a snapshot taken
# here must be folded into all of the core's registries, not just the
# one being applied. Same delta rule as the guard's normal branch and
# the old single-registry fold (live >= last: delta; live < last, i.e.
# a counter reset: add the live value, never a negative delta).
# $1=core $2=snapshot-json. Best effort per registry: an unreadable or
# unwritable registry is skipped, never fails the caller.
users_fold_all_core_counters() {
    local _core="$1" _snap="$2" _dir="${ABOX_USERS_DIR:-$USERS_DIR}" _f='' _c='' _t='' _folded=''
    [[ -n "$_snap" ]] || return 0
    [[ -d "$_dir" ]] || return 0
    for _f in "$_dir"/"$(users_reg_encode_component "$_core")"__*.json; do
        [[ -f "$_f" && ! -L "$_f" ]] || continue
        _c=$(jq -r '.core // ""' "$_f" 2>/dev/null) || continue
        _t=$(jq -r '.tag // ""' "$_f" 2>/dev/null) || continue
        [[ "$_c" == "$_core" && -n "$_t" ]] || continue
        _folded=$(jq -c --argjson stats "$_snap" '
            .users |= map(
                if (.email // "") != "" and ($stats[.email] != null) then
                    .used_up += (if $stats[.email].up >= (.last_up // 0) then $stats[.email].up - (.last_up // 0) else $stats[.email].up end)
                    | .used_down += (if $stats[.email].down >= (.last_down // 0) then $stats[.email].down - (.last_down // 0) else $stats[.email].down end)
                    | .last_up = $stats[.email].up | .last_down = $stats[.email].down
                else . end
            )' "$_f" 2>/dev/null || true)
        [[ -n "$_folded" ]] && users_reg_write "$_c" "$_t" "$_folded" >/dev/null 2>&1 || true
    done
    return 0
}

users_apply_reg() {
    # SYD-B E21: collapse duplicate names (keep the first) before
    # writing; a duplicated registry must not reach sync. This is
    # registry hygiene only, not a claim about the sync gate.
    local _new="$3"
    if command -v jq >/dev/null 2>&1; then
        _new=$(printf '%s' "$3" | jq -c 'if (.users | type) == "array" then .users |= unique_by(.name) else . end' 2>/dev/null || printf '%s' "$3")
    fi
    # R5C11-01: plant the sync-pending marker BEFORE the registry
    # rename, so a SIGKILL between registry write and core sync
    # leaves a durable debt the guard retries instead of a
    # fail-open nothing ever repairs. The marker path matches
    # the guard's "${reg}.sync-pending" sidecar.
    local _reg=''
    _reg=$(users_reg_file "$1" "$2") || return 1
    [[ -n "$_reg" ]] || return 1
    # 06a1-M1: remember whether the debt marker pre-existed. A
    # pre-existing marker is an older interrupted apply's debt, not
    # this run's: if the write below fails, only a marker planted by
    # this run may be removed.
    local _pending_pre=0
    [[ -e "${_reg}.sync-pending" ]] && _pending_pre=1
    : > "${_reg}.sync-pending" || return 1
    users_reg_write "$1" "$2" "$_new" || { (( _pending_pre == 0 )) && rm -f -- "${_reg}.sync-pending"; return 1; }
    # M-29(2): fold the live Xray counters into the registry BEFORE the
    # sync restarts the core. A restart zeroes the in-memory
    # StatsService counters, so traffic between the last guard tick and
    # this restart would otherwise never be counted (the guard only
    # snapshots on its own tick, L38285). Same delta rule as the
    # guard's normal branch; best effort: a failed snapshot (core
    # down / API error) leaves the registry as written and the sync
    # proceeds exactly as before.
    # M-29 follow-up (single-registry fold): the sync below restarts
    # the WHOLE core service, not one tag, so folding only this
    # registry strands every other tag's delta since the last tick.
    # Fold one service-wide snapshot into every registry of this core.
    if [[ "$1" == 'xray' ]] && is_service_running xray 2>/dev/null; then
        local _snap=''
        _snap=$(users_stats_snapshot /usr/local/bin/xray 10085 2>/dev/null || true)
        if [[ -n "$_snap" ]]; then
            users_fold_all_core_counters "$1" "$_snap" >/dev/null 2>&1 || true
        fi
    fi
    local _sync_rc=0
    users_sync "$1" "$2" || _sync_rc=$?
    if (( _sync_rc != 0 )); then
        # Roll back, and clear the marker only after verifying
        # the rollback landed (re-read matches the old content).
        # If the rollback or its verification fails, the marker
        # stays so the guard retries the sync. A config-restore
        # failure (sync rc 2) also keeps the marker: the live
        # config may still hold the new users, so the guard must
        # retry the sync instead of treating the debt as settled.
        # R42-H1: a pre-existing marker is an OLDER interrupted
        # apply's debt, not this run's (06a1-M1): rolling back to
        # the old registry proves nothing about the service, which
        # may still be one apply behind. Only a marker planted by
        # this run may be cleared here.
        if users_reg_write "$1" "$2" "$4" >/dev/null 2>&1; then
            if (( _pending_pre == 0 && _sync_rc != 2 )) && [[ "$(jq -c . "$_reg" 2>/dev/null)" == "$(printf '%s' "$4" | jq -c . 2>/dev/null)" ]]; then
                rm -f -- "${_reg}.sync-pending"
            fi
        fi
        return 1
    fi
    rm -f -- "${_reg}.sync-pending"
    # D-leg OBS-02: the xray E62-NEW-01 mirror writes a newly added
    # Vision user into the live xhttp inbound, but the xhttp registry
    # only catches up on the next multi_user_menu render (users_reg_
    # ensure), while the subscription export below is built purely
    # from the registries -- so the export lags by one chain and only
    # self-heals on the next menu render. Pull that merge forward
    # here (best-effort, sync already committed): users_reg_ensure is
    # exactly the merge the menu already performs, so the registry /
    # export state after an add is the same as after the next menu
    # render -- just earlier. No-op when there is no xhttp inbound
    # (vision-only stack: adopt fails, swallowed by || true).
    if [[ "$1" == 'xray' && "$2" == 'vision' ]]; then
        users_reg_ensure xray xhttp >/dev/null 2>&1 || true
    fi
    # S2-NEW-03 follow-up: a committed registry change is a users.d
    # change, and the subscription export is built from the registries.
    # Refresh it here so add/delete/toggle/quota/expiry/window/reset/
    # reimport all land in uri-list.txt / subscription.base64 at once,
    # instead of waiting for the next deploy or a manual menu-E export
    # (a fresh deploy + add-user otherwise leaves 0-byte files).
    # Best-effort (helper warns on failure): the user change already
    # committed, so an export failure must not fail the apply.
    refresh_subscription_after_deploy || true
    return 0
}

users_pick_user() {
    # $1=reg-file $2=prompt -> echoes the chosen name
    local reg="$1" names='' sel='' total=0
    names=$(jq -r '.users[].name' "$reg" 2>/dev/null) || return 1
    [[ -n "$names" ]] || return 1
    local i=0 n=''
    while IFS= read -r n; do i=$((i + 1)); printf '%3d. %s\n' "$i" "$n" >&2; done <<< "$names"
    read -r -p "$2" sel || return 1
    sel=$(normalize_fa_ar_digits "$sel")
    total=$(printf '%s\n' "$names" | wc -l | tr -d '[:space:]')
    # Length-gated first: an unbounded digit string wraps in bash
    # arithmetic (2^64+1 becomes 1) and would select the first user.
    # 10# stays for the octal rule (08/010 must not parse as octal).
    valid_decimal_upto "$sel" "$total" || return 1
    sel=$((10#$sel))
    (( sel >= 1 )) || return 1
    printf '%s\n' "$names" | sed -n "${sel}p"
}

# F08: SS-2022 key length follows the inbound method: any 256
# method needs 32 bytes; 128-gcm and legacy passphrase methods
# use 16. An unreadable method keeps the historical 16-byte
# default (sync rollback protects a wrong guess).
users_ss_new_secret() {
    local core="$1" tag="$2" method='' keylen=16 cfg='' _jq_stripped=''
    cfg=$(users_cfg_of "$core" 2>/dev/null || echo "")
    if [[ -n "$cfg" && -f "$cfg" && ! -L "$cfg" ]]; then
        # M-6-rescan (B-leg): Xray configs may carry // comments jq
        # rejects; strip once here (same rule as users_link_combo:
        # strip xray/sing-box, raw file otherwise so a hy2 YAML
        # config is never mangled by the JSONC stripper).
        if [[ "$core" == xray || "$core" == sing-box ]]; then
            _jq_stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null)
        else
            _jq_stripped=$(cat "$cfg" 2>/dev/null || true)
        fi
        method=$(printf '%s' "$_jq_stripped" | jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.settings.method // .method // "")' 2>/dev/null | head -1)
    fi
    [[ "$method" == *256* || "$method" == "2022-blake3-chacha20-poly1305" ]] && keylen=32
    openssl rand -base64 "$keylen" 2>/dev/null | tr -d '\n\r'
}
users_inbound_menu() {
    local core="$1" tag="$2" proto="$3" port="$4" reg=''
    reg=$(users_reg_file "$core" "$tag")
    users_reg_ensure "$core" "$tag" || { msg "${RED}$(tr_msg mu_reg_bad)${NC}"; pause_return; return 1; }
    while true; do
        clear
        msg "${BOLD}${GREEN}$(protocol_label "$tag" "$proto" 2>/dev/null || printf '%s' "$tag") · ${core} · :${port}${NC}"
        if [[ "$core" == 'sing-box' || "$core" == 'hy2' ]]; then
            msg "${YELLOW}$(tr_msg mu_note_sb)${NC}"
        fi
        msg "--------------------------------------------------------------------------------"
        local line='' name='' dis='' blk='' qu='' exp='' win='' used=''
        local idx=0
        while IFS= read -r line; do
            idx=$((idx + 1))
            name=$(printf '%s' "$line" | jq -r '.name')
            dis=$(printf '%s' "$line" | jq -r '.disabled')
            blk=$(printf '%s' "$line" | jq -r '.blocked // ""')
            qu=$(printf '%s' "$line" | jq -r '.quota_gb // 0')
            exp=$(printf '%s' "$line" | jq -r '.expire_at // 0')
            win=$(printf '%s' "$line" | jq -r '.window // ""')
            local st="$(tr_msg mu_st_ok)"
            [[ "$dis" == 'true' ]] && st="$(tr_msg mu_st_disabled)"
            [[ -n "$blk" ]] && st="$(tr_msg mu_st_blocked)($blk)"
            local expd="$(tr_msg mu_exp_forever)"
            if [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > 0 )); then expd=$(date -d "@$exp" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$exp"); fi
            local usd='-'
            if [[ "$core" == xray* ]]; then
                local uu='' ud=''
                uu=$(printf '%s' "$line" | jq -r '.used_up // 0'); ud=$(printf '%s' "$line" | jq -r '.used_down // 0')
                usd="$(users_fmt_bytes $((uu + ud)))"
                [[ "$qu" != '0' ]] && usd="${usd}/${qu}G"
            fi
            printf '%3d. %-18s %-12s %s:%-14s %s:%-12s %s:%s\n' "$idx" "$name" "$st" "$(tr_msg mu_col_usage)" "$usd" "$(tr_msg mu_col_expiry)" "$expd" "$(tr_msg mu_col_window)" "${win:-$(tr_msg mu_allday)}"
        done < <(jq -c '.users[]' "$reg" 2>/dev/null)
        msg "--------------------------------------------------------------------------------"
        local -a _oacts=("" "$(tr_msg mu_a1)" "$(tr_msg mu_a2)" "$(tr_msg mu_a3)" "$(tr_msg mu_a4)" "$(tr_msg mu_a5)" "$(tr_msg mu_a6)" "$(tr_msg mu_a7)" "$(tr_msg mu_a8)" "$(tr_msg mu_a9)")
        local _or=0 _oleft='' _opad='' _oleftc=''
        for _or in 1 2 3 4 5; do
            _oleft="${_or}. ${_oacts[$_or]}"
            _oleftc="${CYAN}${_or}.${NC} ${_oacts[$_or]}"
            printf -v _opad '%*s' $(( 36 - $(_str_dwidth "$_oleft") )) ''
            (( ${#_opad} < 2 )) && _opad='  '
            if (( _or == 5 )); then
                msg "${_oleftc}${_opad}${CYAN}0.${NC} $(tr_msg mu_back_word)"
            else
                msg "${_oleftc}${_opad}${CYAN}$((_or + 5)).${NC} ${_oacts[$((_or + 5))]}"
            fi
        done
        local c=''
        read -r -p "$(tr_msg select_prompt) [0-9]: " c || return 0
        c=$(normalize_fa_ar_digits "$c")
        local old='' new='' nm='' now=''
        old=$(cat "$reg" 2>/dev/null) || return 1
        now=$(date +%s)
        case "$c" in
            1)
                read -r -p "$(tr_msg mu_name_prompt)" nm || continue
                users_valid_name "$nm" || { msg "${RED}$(tr_msg mu_name_bad)${NC}"; pause_return; continue; }
                jq -e --arg n "$nm" '.users[] | select(.name == $n)' "$reg" >/dev/null 2>&1 && { msg "${RED}$(tr_msg mu_name_dup)${NC}"; pause_return; continue; }
                local secret='' nuuid='' flow='' email=''
                # R7C11-03: inherit main's flow when non-empty, else the first
                # non-empty flow among existing users (main-only lookup left a
                # new user flowless on a vision inbound with no main).
                flow=$(jq -r '([.users[] | select(.name == "main" and (.flow // "") != "") | .flow] + [.users[] | select(.flow != null and .flow != "") | .flow] | first) // ""' "$reg" 2>/dev/null)
                case "$proto" in
                    vless) secret=$(generate_robust_uuid) || continue ;;
                    vmess) secret=$(generate_robust_uuid) || continue; nuuid="$secret" ;;
                    tuic) nuuid=$(generate_robust_uuid) || continue; secret=$(rand_alnum 16) || continue ;;
                    shadowsocks) secret=$(users_ss_new_secret "$core" "$tag"); [[ -n "$secret" ]] || continue ;;
                    *) secret=$(rand_alnum 16) || continue ;;
                esac
                [[ "$core" == xray* ]] && email="${tag}/${nm}"
                local created=''
                created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" --rawfile s <(printf '%s' "$secret") --rawfile u <(printf '%s' "$nuuid") --arg f "$flow" --arg e "$email" --arg now "$created" '
                    .users += [{name: $n, secret: $s, uuid: $u, flow: $f, email: $e, created: $now,
                                expire_at: 0, quota_gb: 0, window: "", disabled: false, blocked: "",
                                period: "", used_up: 0, used_down: 0, last_up: 0, last_down: 0, count_from_zero: true}]') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then
                    msg "${GREEN}$(tr_msg mu_added): ${nm}${NC}"
                    if [[ "$proto" == 'shadowsocks' ]] && (( $(printf '%s' "$new" | jq '.users | length') == 2 )) && [[ -z "$(printf '%s' "$old" | jq -r '.server_secret // ""')" ]]; then
                        msg "${YELLOW}$(tr_msg mu_ss_warn)${NC}"
                    fi
                    local lk=''
                    lk=$(users_link "$core" "$tag" "$nm" 2>/dev/null || true)
                    [[ -n "$lk" ]] && { msg "$lk"; generate_qr "$lk"; }
                else
                    msg "${RED}$(tr_msg mu_add_fail)${NC}"
                fi
                pause_return ;;
            2)
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick_del)") || { pause_return; continue; }
                [[ -n "$nm" && "$nm" != 'main' ]] || { msg "${RED}$(tr_msg mu_main_keep)${NC}"; pause_return; continue; }
                local del_answer=''
                read -r -p "$(printf '%s %s ? [Y/N]: ' "$(tr_msg mu_del_confirm)" "$nm")" del_answer || { msg "$(tr_msg mu_cancelled)"; pause_return; continue; }
                is_yes "$del_answer" || { msg "$(tr_msg mu_cancelled)"; pause_return; continue; }
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" '.users |= map(select(.name != $n))') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_deleted): ${nm}${NC}"; else msg "${RED}$(tr_msg mu_del_fail)${NC}"; fi
                pause_return ;;
            3)
                user_guard_installed || { msg "${RED}$(tr_msg mu_set_fail)${NC}"; pause_return; continue; }
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                local gb=''
                read -r -p "$(tr_msg mu_gb_prompt)" gb || continue
                gb=$(normalize_fa_ar_digits "$gb")
                # 06a2-M1: a bare digit check lets an over-long value
                # wrap in $((10#...)) (2^64 -> 0 = unlimited, and the
                # jq branch below clears a quota block on $g == 0).
                # Same cap style as the expiry input next door; the
                # cap (1,000,000 GB) also keeps $g * 1073741824 inside
                # jq's exact-integer range. valid_decimal_upto
                # length-gates first, so a 19-digit input is rejected
                # before any arithmetic can wrap it.
                valid_decimal_upto "$gb" 1000000 || { msg "${RED}$(tr_msg mu_int_err)${NC}"; pause_return; continue; }
                gb=$((10#$gb))
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" --argjson g "$gb" '
                    .users |= map(if .name == $n then .quota_gb = $g | (if .blocked == "quota" and ($g == 0 or ((.used_up // 0) + (.used_down // 0) < ($g * 1073741824))) then .blocked = "" else . end) else . end)') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_quota_set): ${nm} = ${gb} GB${NC}"; else msg "${RED}$(tr_msg mu_set_fail)${NC}"; fi
                pause_return ;;
            4)
                user_guard_installed || { msg "${RED}$(tr_msg mu_set_fail)${NC}"; pause_return; continue; }
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                local days=''
                read -r -p "$(tr_msg mu_days_prompt)" days || continue
                days=$(normalize_fa_ar_digits "$days")
                valid_decimal_upto "$days" 36500 || { msg "${RED}$(tr_msg mu_int_err)${NC}"; pause_return; continue; }
                days=$((10#$days))
                local expat=0
                (( days > 0 )) && expat=$((now + days * 86400))
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" --argjson e "$expat" '
                    .users |= map(if .name == $n then .expire_at = $e | (if .blocked == "expired" then .blocked = "" else . end) else . end)') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_expiry_set): ${nm}${NC}"; else msg "${RED}$(tr_msg mu_set_fail)${NC}"; fi
                pause_return ;;
            5)
                user_guard_installed || { msg "${RED}$(tr_msg mu_set_fail)${NC}"; pause_return; continue; }
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                local w=''
                read -r -p "$(tr_msg mu_win_prompt)" w || continue
                w=$(normalize_fa_ar_digits "$w")
                if [[ -n "$w" && ! "$w" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    msg "${RED}$(tr_msg mu_win_bad)${NC}"; pause_return; continue
                fi
                if [[ -n "$w" && "${w%-*}" == "${w#*-}" ]]; then
                    msg "${RED}$(tr_msg mu_win_bad)${NC}"; pause_return; continue
                fi
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" --arg w "$w" '
                    .users |= map(if .name == $n then .window = $w | (if .blocked == "window" then .blocked = "" else . end) else . end)') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_win_set): ${nm}${NC}"; else msg "${RED}$(tr_msg mu_set_fail)${NC}"; fi
                pause_return ;;
            6)
                user_guard_installed || { msg "${RED}$(tr_msg mu_set_fail)${NC}"; pause_return; continue; }
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                local per=''
                per=$(date '+%Y-%m')
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" --arg p "$per" '
                    .users |= map(if .name == $n then .used_up = 0 | .used_down = 0 | .period = $p | (if .blocked == "quota" then .blocked = "" else . end) else . end)') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_reset_done): ${nm}${NC}"; else msg "${RED}$(tr_msg mu_reset_fail)${NC}"; fi
                pause_return ;;
            7)
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                local lk=''
                lk=$(users_link "$core" "$tag" "$nm" 2>/dev/null || true)
                if [[ -n "$lk" ]]; then msg "$lk"; generate_qr "$lk"; else msg "${RED}$(tr_msg mu_nolink)${NC}"; fi
                pause_return ;;
            8)
                nm=$(users_pick_user "$reg" "$(tr_msg mu_pick)") || { pause_return; continue; }
                new=$(printf '%s' "$old" | jq -c --arg n "$nm" '
                    .users |= map(if .name == $n then .disabled = (.disabled != true) | (if .disabled == false then .blocked = "" else . end) else . end)') || continue
                if users_apply_reg "$core" "$tag" "$new" "$old"; then msg "${GREEN}$(tr_msg mu_toggled): ${nm}${NC}"; else msg "${RED}$(tr_msg mu_op_fail)${NC}"; fi
                pause_return ;;
            9)
                confirm_yes_no "$(tr_msg mu_reimport_confirm) [Y/N]: " || { msg "$(tr_msg mu_cancelled)"; pause_return; continue; }
                local re_old='' re_new='' re_tmp=''
                re_old=$(cat "$reg" 2>/dev/null) || { msg "${RED}$(tr_msg mu_import_fail)${NC}"; pause_return; continue; }
                re_tmp=$(mktemp /tmp/A-Box-reimport.XXXXXX) || { msg "${RED}$(tr_msg mu_import_fail)${NC}"; pause_return; continue; }
                if users_adopt "$core" "$tag" "$re_tmp" && re_new=$(cat "$re_tmp" 2>/dev/null) && [[ -n "$re_new" ]] && users_apply_reg "$core" "$tag" "$re_new" "$re_old"; then msg "${GREEN}$(tr_msg mu_reimported)${NC}"; else msg "${RED}$(tr_msg mu_import_fail)${NC}"; fi
                rm -f -- "$re_tmp"
                pause_return ;;
            0) return 0 ;;
            *) msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1 ;;
        esac
    done
}

multi_user_menu() {
    # Bring pre-fix47 combo inbounds into per-tag management (idempotent,
    # no-op when everything is already tagged).
    local slot_cfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}"
    [[ -f "$slot_cfg" && ! -L "$slot_cfg" ]] && users_xray_ensure_tags "$slot_cfg" >/dev/null 2>&1 || true
    [[ -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json ]] && users_sb_ensure_tags /etc/sing-box/config.json >/dev/null 2>&1 || true
    local _mu_guard_fail='' _mu_guard_shown=0
    if ! setup_user_guard >/dev/null 2>&1; then
        # M-06: name the cause instead of a bare "failed to apply": under
        # bash <(curl ...) $0 is /dev/fd/N, so no regular script file is
        # available to build the guard runner from.
        if [[ ! -f "$0" || -L "$0" ]]; then
            _mu_guard_fail="$(tr_msg mu_guard_no_file)"
        else
            _mu_guard_fail="$(tr_msg mu_set_fail)"
        fi
    fi
    while true; do
        clear
        if [[ -n "$_mu_guard_fail" && "$_mu_guard_shown" == 0 ]]; then
            msg "${RED}${_mu_guard_fail}${NC}"
            _mu_guard_shown=1
            pause_return
        fi
        msg "${CYAN}======================================================================${NC}"
        msg "${BOLD}${GREEN}$(tr_msg mu_title)${NC}"
        msg "${CYAN}======================================================================${NC}"
        local rows='' i=0 core='' tag='' proto='' port=''
        rows=$(protocol_inventory 2>/dev/null || true)
        local -a cores=() tags=() protos=() ports=()
        while IFS=$'\t' read -r core tag proto port; do
            [[ -n "$core" && -n "$tag" ]] || continue
            [[ "$proto" == 'shadowtls' ]] && continue
            users_reg_ensure "$core" "$tag" >/dev/null 2>&1 || continue
            local cnt=0
            cnt=$(jq '.users | length' "$(users_reg_file "$core" "$tag")" 2>/dev/null || echo 0)
            i=$((i + 1))
            cores+=("$core"); tags+=("$tag"); protos+=("$proto"); ports+=("$port")
            printf '%3d. %-46s %-11s :%-6s %s %s\n' "$i" "$(protocol_label "$tag" "$proto" 2>/dev/null || printf '%s' "$tag")" "$core" "$port" "$(tr_msg mu_users_word)" "$cnt"
        done <<< "$rows"
        # F06: registries whose inbound was deleted (all users
        # disabled) vanish from protocol_inventory, stranding
        # their intact inbound_snapshot: the node cannot be
        # re-enabled from the menu. List every registry with a
        # valid snapshot that is not already live.
        local _sudir="${ABOX_USERS_DIR:-${USERS_DIR:-/etc/ddr/users.d}}" _srf='' _sc='' _st='' _sp='' _sport='' _sfound=0 _sj=0 _scnt=0
        if [[ -d "$_sudir" ]]; then
            for _srf in "$_sudir"/*.json; do
                [[ -f "$_srf" && ! -L "$_srf" ]] || continue
                _sc=$(jq -r '.core // ""' "$_srf" 2>/dev/null || echo "")
                _st=$(jq -r '.tag // ""' "$_srf" 2>/dev/null || echo "")
                [[ -n "$_sc" && -n "$_st" ]] || continue
                _sp=$(jq -r '.protocol // ""' "$_srf" 2>/dev/null || echo "")
                [[ "$_sp" == 'shadowtls' ]] && continue
                jq -e --arg t "$_st" '.inbound_snapshot | type == "object" and .tag == $t' "$_srf" >/dev/null 2>&1 || continue
                _sfound=0
                for (( _sj=0; _sj<${#cores[@]}; _sj++ )); do
                    if [[ "${cores[$_sj]}" == "$_sc" && "${tags[$_sj]}" == "$_st" ]]; then _sfound=1; break; fi
                done
                (( _sfound == 1 )) && continue
                _sport=$(jq -r '.inbound_snapshot.port // .inbound_snapshot.listen_port // 0' "$_srf" 2>/dev/null || echo 0)
                _scnt=$(jq '.users | length' "$_srf" 2>/dev/null || echo 0)
                i=$((i + 1))
                cores+=("$_sc"); tags+=("$_st"); protos+=("$_sp"); ports+=("$_sport")
                printf '%3d. %-46s %-11s :%-6s %s %s\n' "$i" "$(protocol_label "$_st" "$_sp" 2>/dev/null || printf '%s' "$_st")" "$_sc" "$_sport" "$(tr_msg mu_users_word)" "$_scnt"
            done
        fi
        if (( i == 0 )); then msg "${YELLOW}$(tr_msg mu_none)${NC}"; fi
        msg "  ${CYAN}E.${NC} $(tr_msg mu_export)"
        msg "  ${CYAN}0.${NC} $(tr_msg mu_back_word)"
        local c=''
        read -r -p "$(tr_msg select_prompt) [0-${i}/E]: " c || return 0
        c=$(normalize_fa_ar_digits "$c")
        case "$c" in
            0) return 0 ;;
            E|e)
                local n='' _ef=''
                _ef=$(umask 077; mktemp /tmp/A-Box-export.XXXXXX 2>/dev/null) || _ef=''
                if [[ -n "$_ef" ]]; then
                    n=$(users_export_all 2>"$_ef" || true)
                    if [[ -s "$_ef" ]]; then cat "$_ef"; fi
                    rm -f -- "$_ef"
                fi
                if [[ -n "$n" ]]; then msg "${GREEN}$(tr_msg mu_exported): ${n} (uri-list.txt / subscription.base64)${NC}"; else msg "${RED}$(tr_msg mu_export_fail)${NC}"; fi
                pause_return ;;
            ''|*[!0-9]*) msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1 ;;
            *)
                if valid_decimal_upto "$c" "$i" && (( 10#$c >= 1 && 10#$c <= i )); then
                    users_inbound_menu "${cores[$((10#$c - 1))]}" "${tags[$((10#$c - 1))]}" "${protos[$((10#$c - 1))]}" "${ports[$((10#$c - 1))]}"
                else
                    msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1
                fi ;;
        esac
    done
}

# ================= User guard (fix47 stage 3) =================
# Enforcement engine for per-user quota / expiry / time-window rules.
# A cron tick every 5 minutes runs a stamped copy of this script with
# --user-guard-tick: it folds Xray StatsService counters into the
# registries, re-evaluates each user's blocked state, and applies
# transitions. Xray blocks go through the hot path (config edit + API
# rmu, no restart); unblocks and sing-box/Hy2 changes use users_sync.

# R4C11-03: guard is installed only when both the runner copy and the
# USERGUARD cron block exist; policy saves must refuse otherwise.
user_guard_installed() {
    local runner="${ABOX_DIR:-/etc/ddr}/user-guard-runner.sh"
    [[ -f "$runner" && ! -L "$runner" && -x "$runner" ]] || return 1
    crontab -l 2>/dev/null | grep -q '# A-Box USERGUARD BEGIN' || return 1
    return 0
}

setup_user_guard() {
    local runner="${ABOX_DIR:-/etc/ddr}/user-guard-runner.sh"
    local _src="$0"
    # M-06 (Carbon audit): under bash <(curl ...) $0 is /dev/fd/N, not a
    # regular file. Fall back to the installed copy, but only when it is
    # the same build: its ABOX_BUILD_EPOCH must match this running
    # script, so a stale copy is never silently used to build the runner.
    if [[ ! -f "$_src" || -L "$_src" ]]; then
        local _fb="${ABOX_DIR:-/etc/ddr}/A-Box.sh" _fb_epoch=''
        [[ -f "$_fb" && ! -L "$_fb" ]] || return 1
        _fb_epoch=$(awk -F= '/^ABOX_BUILD_EPOCH=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$_fb" 2>/dev/null || true)
        [[ -n "$_fb_epoch" && -n "${ABOX_BUILD_EPOCH:-}" && "$_fb_epoch" == "$ABOX_BUILD_EPOCH" ]] || return 1
        _src="$_fb"
    fi
    mkdir_private "$(dirname -- "$runner")" 2>/dev/null || return 1
    local sha_new='' sha_old=''
    sha_new=$(sha256sum -- "$_src" 2>/dev/null | awk '{print $1}')
    sha_old=$(sha256sum -- "$runner" 2>/dev/null | awk '{print $1}')
    # R42-M1: sha256sum follows symlinks, so a symlink runner with
    # the same content skips the replace below, and both repair
    # branches require a regular file -- yet user_guard_installed
    # rejects any symlink. Replace a symlink runner outright (mv
    # onto the link replaces the link itself with a regular file).
    if [[ -L "$runner" || -z "$sha_new" || "$sha_new" != "$sha_old" ]]; then
        local tmp=''
        tmp=$(mktemp "$(dirname -- "$runner")/.guard-runner.XXXXXX") || return 1
        cp -f -- "$_src" "$tmp" || { rm -f -- "$tmp"; return 1; }
        chmod 700 "$tmp" || { rm -f -- "$tmp"; return 1; }
        mv -f -- "$tmp" "$runner" || { rm -f -- "$tmp"; return 1; }
    fi
    # R14-F11-05: the sha256 comparison above cannot see a lost exec
    # bit: a runner with identical content but mode 0600/0644 is left
    # unrepaired while setup reports success, and every later policy
    # save that requires user_guard_installed (-x) is refused — with no
    # way for a reinstall to fix it. Repair the mode in place.
    if [[ ! -x "$runner" && -f "$runner" && ! -L "$runner" ]]; then
        chmod 700 "$runner" || return 1
    fi
    # R16-F11-05: the repair above only covers a lost exec bit: a
    # runner that is already executable but group/other-writable
    # (e.g. 0777 after an external chmod) is left in place, and root
    # cron executes it every 5 minutes. Repair dangerous write bits
    # in place too; an unreadable mode leaves the file untouched.
    if [[ -x "$runner" && -f "$runner" && ! -L "$runner" ]]; then
        local _runner_mode=''
        _runner_mode=$(stat -c %a "$runner" 2>/dev/null || true)
        if [[ "$_runner_mode" =~ ^0?[0-7]{3,4}$ ]] && (( (8#$_runner_mode & 8#022) != 0 )); then
            chmod 700 "$runner" || return 1
        fi
    fi
    # R10C11-03: quote the runner path only when it contains whitespace;
    # the default path must stay byte-identical (collect_abox_cron
    # matches the unquoted USERGUARD line exactly).
    local _runner_q="$runner"
    if [[ "$runner" == *[[:space:]]* ]]; then _runner_q=$(shell_single_quote "$runner"); fi
    ( ABOX_DIE_HOOK=''; install_abox_cron_block USERGUARD "*/5 * * * * /bin/bash $_runner_q --user-guard-tick >/dev/null 2>&1" ) || return 1
    return 0
}

# Query one Xray-family API for per-user counters.
# $1=binary $2=port -> JSON map: email -> {up, down}; rc 1 when down.
users_stats_snapshot() {
    local bin="$1" port="$2" out=''
    [[ -x "$bin" ]] || return 1
    out=$("$bin" api statsquery --server "127.0.0.1:$port" -pattern 'user>>>' 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out" | jq -c '
        [(.stat[]? | (.name | split(">>>")) as $p | select($p[0] == "user") | {e: $p[1], d: $p[3], v: ((.value // 0) | tonumber)})]
        | group_by(.e)
        | map({(.[0].e): {up: ([.[] | select(.d == "uplink") | .v] | add // 0),
                          down: ([.[] | select(.d == "downlink") | .v] | add // 0)}})
        | add // {}' 2>/dev/null || return 1
}

# Hot-remove one user from a RUNNING Xray-family core: first drop the
# client from the on-disk config (so a restart cannot resurrect it),
# then rmu it from the live process. No restart. rc 1 -> caller falls
# back to a full users_sync.
users_hot_remove() {
    local core="$1" tag="$2" email="$3" cfg='' bin='' reg='' proto='' tmp='' tmpd=''
    [[ -n "$email" ]] || return 1
    cfg=$(users_cfg_of "$core") || return 1
    bin=$(users_bin_of "$core") || return 1
    reg=$(users_reg_file "$core" "$tag")
    proto=$(jq -r '.protocol // ""' "$reg" 2>/dev/null) || return 1
    [[ -f "$cfg" && ! -L "$cfg" && -x "$bin" ]] || return 1
    # M-6-rescan (B-leg): Xray configs may carry // comments jq
    # rejects; strip once here and read the stripped view at every
    # jq point below (same rule as users_link_combo: strip
    # xray/sing-box, raw file otherwise). The snapshot below
    # reads this same stripped view (its L-01 per-point strip was
    # removed as redundant: the xray branch already stripped into
    # a mktemp file, the sing-box branch read the raw file). The
    # write path (install_file_atomically "$tmp" "$cfg") still
    # targets the ORIGINAL $cfg, never the stripped view.
    local _jq_stripped=''
    if [[ "$core" == xray || "$core" == sing-box ]]; then
        _jq_stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null)
    else
        _jq_stripped=$(cat "$cfg" 2>/dev/null || true)
    fi
    # Single-password SS: the jq below DELETES the whole inbound (no
    # clients array to remove one user from). Snapshot it into the
    # registry first, or a later re-enable sync can never rebuild it
    # (users_sync only rebuilds from .inbound_snapshot, which only its
    # own all-disabled path writes). Snapshot failure fails closed:
    # keep the inbound rather than delete it unsnapshotted.
    if [[ "$proto" == 'shadowsocks' ]]; then
        local _snap_obj='' _snap_reg=''
        # M-6-rescan (B-leg): the snapshot reads the entry-stripped
        # view above. This replaces the L-01 per-point strip (xray
        # stripped into a mktemp file, sing-box read the raw file,
        # so a commented sing-box config still failed this read).
        _snap_obj=$(printf '%s' "$_jq_stripped" | jq -c --arg t "$tag" '.inbounds[]? | select(.tag == $t)' 2>/dev/null) || return 1
        # R10C11-01: also snapshot when removing the last client: the
        # removal below deletes the whole inbound (an empty clients
        # array plus the retained password would fall back to
        # single-password mode), and the snapshot lets a later sync
        # rebuild it.
        local _snap_needed=0
        if ! printf '%s' "$_jq_stripped" | jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t) | ((.settings.clients // null) | type) == "array"' >/dev/null 2>&1; then
            _snap_needed=1
        elif printf '%s' "$_jq_stripped" | jq -e --arg t "$tag" --arg e "$email" '.inbounds[]? | select(.tag == $t) | ((.settings.clients // null) | type) == "array" and ((.settings.clients | map(select(.email != $e)) | length) == 0)' >/dev/null 2>&1; then
            _snap_needed=1
        fi
        if [[ -n "$_snap_obj" && "$_snap_needed" == 1 ]]; then
            _snap_reg=$(jq -c --slurpfile ib <(printf '%s' "$_snap_obj") '.inbound_snapshot = $ib[0]' "$reg" 2>/dev/null) || return 1
            users_reg_write "$core" "$tag" "$_snap_reg" || return 1
        fi
    fi
    # M-25(2): a single-password SS inbound has no clients array, so
    # the live validator holds no such email: `api rmu` would fail
    # with "not found" and the `api rmi` below is unreachable for it.
    # Remember that here; the disk edit below still runs, and the
    # return-1 after it sends the caller to a full users_sync restart
    # (which reloads the already-edited disk config).
    local _ss_no_clients=0
    if [[ "$proto" == 'shadowsocks' ]] && ! printf '%s' "$_jq_stripped" | jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t) | ((.settings.clients // null) | type) == "array"' >/dev/null 2>&1; then
        _ss_no_clients=1
    fi
    tmpd=$(mktemp -d /tmp/A-Box-uhot.XXXXXX) || return 1
    tmp="$tmpd/config.json"
    local ok=0
    case "$proto" in
        vless|trojan)
            printf '%s' "$_jq_stripped" | jq --arg t "$tag" --arg e "$email" '
                .inbounds |= map(if .tag == $t then .settings.clients |= map(select(.email != $e)) else . end)
            ' > "$tmp" 2>/dev/null && ok=1 ;;
        shadowsocks)
            printf '%s' "$_jq_stripped" | jq --arg t "$tag" --arg e "$email" '
                .inbounds |= map(if .tag == $t then
                    (if ((.settings.clients // null) | type) == "array"
                     then (if (.settings.clients | map(select(.email != $e)) | length) == 0
                           then empty
                           else .settings.clients |= map(select(.email != $e)) end)
                     else empty end)
                else . end)
            ' > "$tmp" 2>/dev/null && ok=1 ;;
        *) : ;;
    esac
    (( ok == 1 )) || { rm -f -- "$tmp"; rm -rf "$tmpd"; return 1; }
    jq empty "$tmp" >/dev/null 2>&1 || { rm -f -- "$tmp"; rm -rf "$tmpd"; return 1; }
    install_file_atomically "$tmp" "$cfg" 600 || { rm -f -- "$tmp"; rm -rf "$tmpd"; return 1; }
    rm -f -- "$tmp"; rm -rf "$tmpd"
    case "$core" in
        xray) prepare_abox_runtime_permissions xray >/dev/null 2>&1 || true ;;
    esac
    # M-25(2): no clients array (single-password SS) -> skip rmu/rmi
    # entirely; rc 1 makes the caller fall back to users_sync.
    if (( _ss_no_clients == 1 )); then return 1; fi
    "$bin" api rmu --server "127.0.0.1:$(users_api_port_of "$core")" -tag "$tag" "$email" >/dev/null 2>&1 || return 1
    # 2mv residual: rmu removes the user from the live daemon, but a
    # zero-client SS handler still serves the inbound password until
    # the sync's commit restart reloads the file (where this inbound
    # is already deleted). Close that window now by removing the
    # whole inbound from the live daemon when the file no longer has
    # it. Best-effort: the sync restart is the backstop, so an rmi
    # failure never changes this function's return. Per-core API port
    # (not xray_api_remove_inbound's hardcoded 10085): the normal Xray
    # slot listens on 10085. jq -e rc 1 (jq <= 1.6) or 4
    # (jq >= 1.7) means "no output", i.e. the tag is absent (same rc
    # semantics as 2gq); any other non-zero rc is a read error, not a
    # deletion.
    # M-25(2): this rmi branch is reachable ONLY for the multi-user
    # last-user case: the deleted user was a real validator entry (the
    # rmu above succeeded) and the file no longer has the tag, so the
    # whole inbound must also leave the live daemon. Single-password
    # SS never reaches here (it returned above).
    if [[ "$proto" == 'shadowsocks' ]]; then
        local _rmi_rc=0
        # M-6-rescan (B-leg): NOT stripped, by the D-leg precedent
        # (cf. users_xray_ensure_tags L43046): every path reaching
        # here passed install_file_atomically "$tmp" "$cfg" above,
        # which atomically installed jq-generated (comment-free)
        # output as $cfg in this same invocation, so no comment can
        # be present; the intervening steps touch only permissions
        # and the live API, never the file content.
        jq -e --arg t "$tag" '.inbounds[]? | select(.tag == $t)' "$cfg" >/dev/null 2>&1 || _rmi_rc=$?
        if [[ "$_rmi_rc" == 1 || "$_rmi_rc" == 4 ]]; then
            "$bin" api rmi --server "127.0.0.1:$(users_api_port_of "$core")" "$tag" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# Evaluate one registry: fold counters in, recompute blocked states,
# write back, and apply transitions. All inputs are parameters so the
# policy core is directly testable.
# $1=reg $2=core $3=tag $4=now-epoch $5=period(YYYY-MM) $6=hh:mm $7=stats-json $8=have-stats(0/1)
users_core_generation() { # $1 = core -> generation string, or empty if undeterminable
    local core="$1" svc='' pid='' mono='' start=''
    svc=$(users_svc_of "$core" 2>/dev/null) || return 0
    if [[ "${INIT_SYS:-}" == 'systemd' ]] && systemd_available; then
        mono=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$svc" 2>/dev/null || true)
        if [[ "$mono" =~ ^[0-9]+$ && "$mono" -gt 0 ]]; then printf 'sys:%s' "$mono"; return 0; fi
    fi
    pid=$(managed_service_pid "$svc" 2>/dev/null || true)
    [[ -n "$pid" ]] || return 0
    # 3B-U8: robust starttime - a plain field-22 read shifts when the
    # comm contains spaces; proc_starttime() strips through the last
    # ')' and takes field 22 (position 20 after pid+comm).
    start=$(proc_starttime "$pid" 2>/dev/null || true)
    [[ "$start" =~ ^[0-9]+$ && "$start" -gt 0 ]] || return 0
    printf 'proc:%s:%s' "$pid" "$start"
}

users_guard_eval() {
    local reg="$1" core="$2" tag="$3" now_s="$4" period="$5" hhmm="$6" stats="$7" have="$8"
    local gen="${9:-}"
    local per_start="${10:-null}"
    local per_end="${11:-null}"
    # H-23 (Carbon R3): the service name this registry's sync would
    # restart (xray family) or touch (sing-box/hy2); used to gate
    # the users_sync calls below on the restart permission.
    local _guard_svc=''
    _guard_svc=$(users_svc_of "$core" 2>/dev/null || printf '%s' "$core")
    local old_json='' updated=''
    # Retry a previously failed config sync: its registry transition
    # was already committed, so no new transition would ever re-fire
    # it. A sidecar marker keeps the debt visible until sync succeeds.
    if [[ -f "${reg}.sync-pending" ]]; then
        # H-23: only retry the sync when a restart is permitted;
        # under a stopped desired state the marker stays so the sync
        # is retried after RUNNING resumes, while the evaluation
        # below still records new registry transitions (bookkeeping
        # without touching the service).
        if service_restart_permitted "$_guard_svc"; then
            if users_sync "$core" "$tag" >/dev/null 2>&1; then
                rm -f -- "${reg}.sync-pending"
            else
                return 0
            fi
        fi
    fi
    old_json=$(jq -c . "$reg" 2>/dev/null) || return 0
    [[ -n "$old_json" ]] || return 0
    updated=$(jq -c --arg per "$period" --argjson now "$now_s" --arg hhmm "$hhmm" --argjson stats "${stats:-{\}}" --argjson have "$have" --arg gen "$gen" --argjson per_start "$per_start" --argjson per_end "$per_end" '
        def created_in_period($s; $e):
            .created as $c
            | if ($c | type) != "string" then false
              elif ($c | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then false
              elif (($s | type) != "number") or
                   (($e | type) != "number") then false
              elif $s >= $e then false
              else (try (
                        ($c | fromdateiso8601) as $t
                        | ((($t | todateiso8601) == $c)
                           and ($t >= $s)
                           and ($t < $e))
                    ) catch false)
              end;
        def inwindow($w; $t):
            if $w == "" then true
            else ($w | split("-")) as $r
                 | (if $r[0] <= $r[1] then ($t >= $r[0] and $t < $r[1]) else ($t >= $r[0] or $t < $r[1]) end)
            end;
        ([.users[] | select($have == 1 and (.email // "") != "" and ($stats[.email] != null))] | length) as $n_with
        | ([.users[] | select($have == 1 and (.email // "") != "" and ($stats[.email] != null) and ((($stats[.email].up // 0) < (.last_up // 0)) or (($stats[.email].down // 0) < (.last_down // 0))))] | length) as $n_dec
        | (($n_with > 0) and ($n_dec == $n_with)) as $restarted
        | (($gen != "") and ((.core_gen // "") != "") and ($gen != .core_gen)) as $gen_changed
        | (if $gen != "" and $have == 1 then .core_gen = $gen else . end)
        | .users |= map(
            (if $have == 1 and (.email // "") != "" and ($stats[.email] != null) then
                (if .period != $per then
                    (if .period == "" then
                        (if .count_from_zero == true and created_in_period($per_start; $per_end) then
                            .used_up += $stats[.email].up | .used_down += $stats[.email].down
                         else . end)
                        | .period = $per | .last_up = $stats[.email].up | .last_down = $stats[.email].down | .baseline_stale = false | del(.count_from_zero)
                     else
                        .used_up = 0 | .used_down = 0 | .period = $per
                        | .last_up = $stats[.email].up | .last_down = $stats[.email].down | .baseline_stale = false
                     end)
                 elif (.baseline_stale // false) then
                    .used_up = 0 | .used_down = 0
                    | .last_up = $stats[.email].up | .last_down = $stats[.email].down | .baseline_stale = false
                 elif $gen_changed then
                    .used_up += $stats[.email].up | .used_down += $stats[.email].down
                    | .last_up = $stats[.email].up | .last_down = $stats[.email].down | .baseline_stale = false
                 elif $restarted then
                    .used_up += $stats[.email].up | .used_down += $stats[.email].down
                    | .last_up = $stats[.email].up | .last_down = $stats[.email].down
                 else
                    .used_up += (if $stats[.email].up >= (.last_up // 0) then $stats[.email].up - (.last_up // 0) else $stats[.email].up end)
                    | .used_down += (if $stats[.email].down >= (.last_down // 0) then $stats[.email].down - (.last_down // 0) else $stats[.email].down end)
                    | .last_up = $stats[.email].up | .last_down = $stats[.email].down
                 end)
             elif .period != $per then
                (if .period == "" then
                    .
                 else
                    .used_up = 0 | .used_down = 0 | .period = $per | .baseline_stale = true
                 end)
             else . end)
            | (if .disabled == true then .
               else
                 .blocked = (
                    if (.expire_at // 0) > 0 and $now >= .expire_at then "expired"
                    elif $have == 0 and .blocked == "quota" then "quota"
                    elif (.quota_gb // 0) > 0 and ((.used_up + .used_down) >= (.quota_gb * 1073741824)) then "quota"
                    elif (inwindow(.window // ""; $hhmm) | not) then "window"
                    else "" end)
               end)
        )' "$reg" 2>/dev/null) || return 0
    [[ -n "$updated" && "$updated" != "$old_json" ]] || return 0
    # Transitions, by name (emails only exist on the Xray family).
    local new_blocked='' unblocked=''
    new_blocked=$(jq -rn --slurpfile oldj <(printf '%s' "$old_json") --slurpfile newj <(printf '%s' "$updated") '
        [$newj[0].users[] | select((.blocked // "") != "" and .disabled != true) | .name
         | select(. as $n | [$oldj[0].users[] | select(.name == $n) | (.blocked // "")] | .[0] == "")] | .[]' 2>/dev/null) || return 1
    unblocked=$(jq -cn --slurpfile oldj <(printf '%s' "$old_json") --slurpfile newj <(printf '%s' "$updated") '
        [$oldj[0].users[] | select((.blocked // "") != "" and .disabled != true) | .name
         | select(. as $n | [$newj[0].users[] | select(.name == $n) | (.blocked // "")] | .[0] == "")] | length' 2>/dev/null) || return 1
    # Fail-closed ordering: the sync need is decided from the transition
    # lists BEFORE committing, and the retry marker is planted BEFORE the
    # commit. A failed plant or a failed registry write aborts with the
    # old registry intact, so the next tick re-evaluates the still-pending
    # transition instead of losing it. A leftover marker from a failed
    # write is harmless: the next tick syncs the unchanged registry (a
    # no-op), clears the marker, and re-evaluates.
    local need_sync=0
    [[ -n "$new_blocked" || "$unblocked" != '0' ]] && need_sync=1
    if (( need_sync == 1 )); then
        : > "${reg}.sync-pending" || return 1
    fi
    users_reg_write "$core" "$tag" "$updated" || return 1
    if [[ "$core" != 'sing-box' && "$core" != 'hy2' ]]; then
        # Xray family: hot-remove each newly blocked user, then sync
        # anyway: rmu removes the user from the config but does not
        # kill already-established connections, and only the sync's
        # commit restart ends them. Skipping sync on success left
        # live connections able to outlast expiry/quota/window blocks.
        if [[ -n "$new_blocked" ]]; then
            local nm='' em=''
            while IFS= read -r nm; do
                [[ -n "$nm" ]] || continue
                em=$(jq -r --arg n "$nm" '.users[] | select(.name == $n) | .email // ""' "$reg" 2>/dev/null)
                users_hot_remove "$core" "$tag" "$em" || true
            done <<< "$new_blocked"
        fi
    fi
    if (( need_sync == 1 )); then
        # H-23: under a stopped desired state the registry transition
        # above is already committed; skip the sync (no restart) and
        # leave the marker planted so the next tick after RUNNING
        # resumes retries the sync.
        if service_restart_permitted "$_guard_svc"; then
            if users_sync "$core" "$tag" >/dev/null 2>&1; then
                rm -f -- "${reg}.sync-pending"
            fi
        fi
    fi
    return 0
}


# ---- change one deployed node's SNI (credentials untouched) ----
# Probe one inbound: echoes kind|current|key_path|crt_path|cfg_path.
_nsni_probe() {
    local core="$1" tag="$2" cfg='' j='' _jq_cfg='' _jq_rc=0
    case "$core" in
        xray) cfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" ;;
        sing-box) cfg='/etc/sing-box/config.json' ;;
        *) return 0 ;;
    esac
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 0
    # R43-01: Xray configs may carry // comments jq rejects; probe
    # the JSONC-stripped view like _nsni_apply does, or a legal
    # commented config is silently skipped by the menu as
    # "unsupported". sing-box configs are strict JSON and keep the
    # raw file. A jq parse failure is distinguished from "no such
    # inbound": it returns 1 with a credential-free diagnostic
    # (core/tag only); the printed probe still carries the ORIGINAL
    # $cfg path, which the callers edit.
    _jq_cfg="$cfg"
    if [[ "$core" == 'xray' ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-nsni-probe-json.XXXXXX) || return 1
        jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { rm -f -- "$_jq_cfg"; msg "${RED}[!] SNI probe: cannot read $core/$tag config.${NC}" >&2; return 1; }
    fi
    if [[ "$core" == 'sing-box' ]]; then
        j=$(jq -r --arg t "$tag" '
            .inbounds[]? | select(.tag == $t) |
            if (.tls.reality.handshake.server // "") != "" then "reality-sb|" + (if (.tls.server_name // "") != "" then .tls.server_name else .tls.reality.handshake.server end) + "||"
            elif .type == "tuic" then "tuic|" + (.tls.server_name // "") + "|" + (.tls.key_path // "") + "|" + (.tls.certificate_path // "")
            elif .type == "shadowtls" then "shadowtls|" + (.handshake.server // "") + "||"
            else "" end' "$_jq_cfg" 2>/dev/null) || _jq_rc=$?
    else
        j=$(jq -r --arg t "$tag" '
            .inbounds[]? | select(.tag == $t) |
            if (.streamSettings.realitySettings.serverNames[0] // "") != "" then "reality-xray|" + .streamSettings.realitySettings.serverNames[0] + "||"
            else "" end' "$_jq_cfg" 2>/dev/null) || _jq_rc=$?
    fi
    if (( _jq_rc != 0 )); then
        [[ "$_jq_cfg" != "$cfg" ]] && rm -f -- "$_jq_cfg"
        msg "${RED}[!] SNI probe: cannot parse $core/$tag config.${NC}" >&2
        return 1
    fi
    [[ "$_jq_cfg" != "$cfg" ]] && rm -f -- "$_jq_cfg"
    [[ -n "$j" ]] && printf '%s|%s' "$j" "$cfg"
    return 0
}

# Apply a new SNI: validated config edit, TUIC cert re-issue, restart,
# standalone-link and .env follow-through. Prints the updated link.
# Restore config + TUIC certs after a failed _nsni_apply step, and retry
# one restart with the old state when the service was running before.
# Returns 0 only when the disk state is fully restored (and the retry
# restart, when applicable, succeeded). Backups are left in place on
# failure so the operator can recover by hand.
_nsni_rollback() {
    local _cfg="$1" _bak="$2" _key="$3" _crt="$4" _kebak="$5" _crtbak="$6" _core="$7" _was_running="$8"
    local _link="${9:-}" _linkbak="${10:-}"
    local _kemode="${11:-}" _crtmode="${12:-}"
    local _ok=1
    # H-06(3b): atomic config restore; mode/owner are taken from the
    # live file (already normalized by the atomic commit), so a rollback
    # never silently drops 0600/root.
    if [[ -f "$_bak" && -r "$_bak" ]]; then
        local _rbmode='600' _rbowner='root:root'
        _rbmode=$(stat -c %a "$_cfg" 2>/dev/null || printf '600')
        _rbowner=$(stat -c %U:%G "$_cfg" 2>/dev/null || printf 'root:root')
        install_file_atomically "$_bak" "$_cfg" "$_rbmode" 2>/dev/null && chown "$_rbowner" "$_cfg" 2>/dev/null || _ok=0
    else
        _ok=0
    fi
    if [[ -n "$_kebak" && -f "$_kebak" ]]; then if cp -a "$_kebak" "$_key" 2>/dev/null; then if [[ -n "$_kemode" ]]; then chmod -- "$_kemode" "$_key" 2>/dev/null || _ok=0; fi; else _ok=0; fi; fi
    if [[ -n "$_crtbak" && -f "$_crtbak" ]]; then if cp -a "$_crtbak" "$_crt" 2>/dev/null; then if [[ -n "$_crtmode" ]]; then chmod -- "$_crtmode" "$_crt" 2>/dev/null || _ok=0; fi; else _ok=0; fi; fi
    if [[ -n "$_link" && -n "$_linkbak" && -f "$_linkbak" ]]; then
        if cp -a "$_linkbak" "$_link" 2>/dev/null; then rm -f "$_linkbak"; else _ok=0; fi
    fi
    if (( _ok == 1 && _was_running == 1 )); then
        if is_systemd; then systemctl restart "$_core" >/dev/null 2>&1 || _ok=0; else rc-service "$_core" restart >/dev/null 2>&1 9>&- 10>&- || _ok=0; fi
    fi
    (( _ok == 1 ))
}

# SYD-B E20: live handshake self-check for a reality SNI change.
# Returns 0 when a real client handshake through the new SNI succeeds,
# 1 when it deterministically fails, 2 when the check cannot be run
# (missing binary/curl/python3/jq, unreadable config, or no public
# key). A config-valid SNI can still fail the live handshake
# (microsoft case); run -test / check -c alone cannot catch that.
# The caller rolls back on 1 and only warns on 2. Live behaviour is
# NOT provable in a sandbox (no server side); Sydney microsoft retest
# is the proof.
# SYD-B2 E20: wait until host:port accepts TCP (default 60 x 0.25s).
_wait_tcp_port() {
    local host="$1" port="$2" tries="${3:-60}" i=0
    [[ -n "$host" && -n "$port" ]] || return 1
    while (( i < tries )); do
        if command -v timeout >/dev/null 2>&1; then
            if timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null; then return 0; fi
        else
            # J02 (06b1-M3): no `timeout` binary here, so bound the bare
            # /dev/tcp connect the same way `timeout 2` bounds it above:
            # run the connect in a background subshell that records its
            # exit status in a flag file, poll for up to 2s, then kill it.
            # A blackholed SYN otherwise blocks one attempt for kernel
            # TCP-retry time (up to ~100s+), and tries=60 only limits the
            # count, not the total. The connect primitive is a plain
            # `printf` (a regular builtin, so a failed redirection ends
            # the command with rc 1 instead of killing the subshell, and
            # the flag is still written).
            local _wflag _wpid _wrc _wwait
            _wrc=1; _wwait=0
            _wflag=$(mktemp) || { sleep 0.25; i=$((i + 1)); continue; }
            ( printf '' <>"/dev/tcp/$host/$port" 2>/dev/null; printf '%s' "$?" > "$_wflag" ) &
            _wpid=$!
            while (( _wwait < 40 )); do
                [[ -s "$_wflag" ]] && break
                kill -0 "$_wpid" 2>/dev/null || break
                sleep 0.05; _wwait=$(( _wwait + 1 ))
            done
            if [[ -s "$_wflag" ]]; then
                _wrc=$(cat "$_wflag")
                wait "$_wpid" 2>/dev/null || true
            else
                kill "$_wpid" 2>/dev/null || true
                wait "$_wpid" 2>/dev/null || true
            fi
            rm -f -- "$_wflag"
            if (( _wrc == 0 )); then return 0; fi
        fi
        sleep 0.25; i=$((i + 1))
    done
    return 1
}

# SYD-B2 E20: derive a REALITY public key (base64url, unpadded) from a
# raw 32-byte Curve25519 private key (base64url). openssl does the
# scalar multiplication via a PKCS#8 DER wrapper; python3 only moves
# bytes around. Proven against `sing-box generate reality-keypair`.
# H-16: Bash+OpenSSL derivation first (x25519_pub_from_priv); the
# Python call below is only a fallback (PIPE, not capture_output,
# so it stays valid on Python 3.6).
_reality_pbk_from_private() {
    local priv="$1" _pbk=''
    [[ -n "$priv" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    # H-16: prefer the pure Bash+OpenSSL derivation
    # (x25519_pub_from_priv): it needs no Python at all, so it works
    # on Python 3.6 (Rocky/Alma 8), where subprocess.run() has no
    # capture_output keyword. The PIPE-based Python call below stays
    # as a fallback for inputs outside the 43-char base64url form.
    if _pbk=$(x25519_pub_from_priv "$priv" 2>/dev/null); then
        printf '%s' "$_pbk"
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - 3<<<"$priv" <<'PYEOF' || return 1
import base64, subprocess, os
priv = os.fdopen(3).read().strip()
try:
    raw = base64.b64decode(priv.translate(str.maketrans("-_", "+/")) + "=" * (-len(priv) % 4))
except Exception:
    raise SystemExit(1)
if len(raw) != 32:
    raise SystemExit(1)
der = bytes.fromhex("302e020100300506032b656e04220420") + raw
p = subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
                   input=der, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if p.returncode != 0 or len(p.stdout) < 32:
    raise SystemExit(1)
print(base64.urlsafe_b64encode(p.stdout[-32:]).decode().rstrip("="))
PYEOF
}

# 06b1-M2: print the PID listening on TCP 127.0.0.1:$1, or fail.
# /proc/net/tcp based (no ss dependency): match the LISTEN socket inode
# for the port, then map the inode to its owner via /proc/*/fd.
_nsni_tcp_listener_pid() {
    local _port="$1" _hex='' _inode='' _fd='' _pid=''
    [[ "$_port" =~ ^[0-9]+$ ]] || return 1
    printf -v _hex '%04X' "$_port"
    _inode=$(awk -v p="$_hex" '$2 ~ ("^0100007F:" p "$") && $4 == "0A" { print $10; exit }' /proc/net/tcp 2>/dev/null || true)
    [[ -n "$_inode" ]] || return 1
    for _fd in /proc/[0-9]*/fd/*; do
        [[ -e "$_fd" ]] || continue
        if [[ "$(readlink "$_fd" 2>/dev/null || true)" == "socket:[$_inode]" ]]; then
            _pid=${_fd#/proc/}; _pid=${_pid%%/*}; printf '%s\n' "$_pid"; return 0
        fi
    done
    return 1
}

_nsni_handshake_check() {
    local core="$1" tag="$2" cfg="$3" sni="$4"
    local bin='' port='' listen='' dial='' uuid='' flow='' net='' xpath='' xhost='' xmode='' grpc_service='' sid='' pbk=''
    local lf='' sport='' cc='' tmpd='' pid='' code='' i=0 up=0 _try=0 _envf='' pbk_src='' logf='' cerr='' cerr_curl='' curl_rc=0 ready=0 _priv='' tport='443' _tgt='' _tport_cand='' _thost='' _transport='' _owner=''
    case "$core" in
        xray) bin='/usr/local/bin/xray' ;;
        sing-box) bin="${SB_PATH:-/usr/local/bin/sing-box}" ;;
        *) return 2 ;;
    esac
    [[ -x "$bin" ]] || return 2
    command -v curl >/dev/null 2>&1 || return 2
    command -v python3 >/dev/null 2>&1 || return 2
    command -v jq >/dev/null 2>&1 || return 2
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 2
    # M-6 rescan (leg A): $cfg is a live core config. Xray's is JSONC
    # (a user // or /* */ comment is legal there) and every bare jq
    # read below fails on it, emptying port/uuid and returning 2
    # (unavailable) instead of verifying the handshake; the sing-box
    # file is strict JSON, so stripping is a no-op there, but the same
    # read path keeps both branches consistent (jq still fails first
    # on a commented file). Strip once here; all 21 jq reads below use
    # the stripped temp file. This function never writes $cfg, so no
    # write path is touched.
    local _jq_cfg='' _jq_caller_trap=''
    _jq_cfg=$(mktemp /tmp/A-Box-nsni-json.XXXXXX) || return 2
    # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
    _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
    trap 'rm -f -- "$_jq_cfg" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
    # jsonc_strip_comments falls back to `cat` on failure, so a failed
    # strip still leaves the raw file in $_jq_cfg (reads then fail
    # exactly as before the fix); only a temp-file failure returns 2.
    jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || return 2
    if [[ "$core" == 'sing-box' ]]; then
        port=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        listen=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        uuid=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .users[0].uuid // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        sid=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | if (.tls.reality.short_id | type) == "array" then (.tls.reality.short_id[0] // "") else (.tls.reality.short_id // "") end' "$_jq_cfg" 2>/dev/null | head -n 1)
        flow=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .users[0].flow // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
        # R15-F11-06: $net is Xray-shaped (.streamSettings), so it
        # is always "tcp" for a sing-box inbound; the transport type
        # lives in .transport. Copy the whole transport object into
        # the temp client below: a gRPC/xhttp/ws inbound probed with
        # a bare-TCP client fails the handshake and the caller rolls
        # back a valid SNI change.
        net=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.transport.type // "tcp")' "$_jq_cfg" 2>/dev/null | head -n 1)
        _transport=$(jq -c --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.transport // null)' "$_jq_cfg" 2>/dev/null | head -n 1)
        [[ -n "$_transport" ]] || _transport='null'
    else
        port=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .port // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        listen=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        uuid=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .settings.clients[0].id // empty' "$_jq_cfg" 2>/dev/null | head -n 1)
        flow=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .settings.clients[0].flow // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
        net=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.network // "tcp"' "$_jq_cfg" 2>/dev/null | head -n 1)
        xpath=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.xhttpSettings.path // "/xhttp"' "$_jq_cfg" 2>/dev/null | head -n 1)
        xhost=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.xhttpSettings.host // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
        xmode=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.xhttpSettings.mode // "stream-one"' "$_jq_cfg" 2>/dev/null | head -n 1)
        grpc_service=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.grpcSettings.serviceName // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
        sid=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | if (.streamSettings.realitySettings.shortIds | type) == "array" then (.streamSettings.realitySettings.shortIds[0] // "") else (.streamSettings.realitySettings.shortIds // "") end' "$_jq_cfg" 2>/dev/null | head -n 1)
    fi
    [[ -n "$port" && -n "$uuid" ]] || return 2
    # R9C12-01: a range port ("443-445") is not dialable; probe the
    # range start (the inbound listens there) instead of failing
    # every /dev/tcp attempt and rolling back a healthy inbound.
    if [[ "$port" == *-* ]]; then port="${port%%-*}"; fi
    # R11-01: the probe URL needs the REALITY target's HTTPS port,
    # not the inbound listen port. Derive it from the live target:
    # xray keeps it in realitySettings.target/dest (custom ports are
    # preserved by _nsni_apply); sing-box keeps it in
    # tls.reality.handshake.server_port. An absent port (or a socket
    # target, which has none) falls back to 443 as a documented
    # application-probe fallback, not a claim about the REALITY
    # target. A malformed target or port returns 2 (unavailable): a
    # wrong probe must not roll back a healthy SNI. Validated here,
    # before any temp resource is allocated.
    if [[ "$core" == 'sing-box' ]]; then
        tport=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.tls.reality.handshake.server_port // 443)' "$_jq_cfg" 2>/dev/null | head -n 1)
        if [[ ! "$tport" =~ ^[0-9]+$ ]] || (( 10#$tport < 1 || 10#$tport > 65535 )); then return 2; fi
    else
        _tgt=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | (.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // "")' "$_jq_cfg" 2>/dev/null | head -n 1)
        case "$_tgt" in
            '') tport='443' ;;
            /*|@*) tport='443' ;;
            \[*\]:*)
                _tport_cand="${_tgt##*:}"
                if [[ "$_tport_cand" =~ ^[0-9]+$ ]] && (( 10#$_tport_cand >= 1 && 10#$_tport_cand <= 65535 )); then tport="$_tport_cand"; else return 2; fi ;;
            \[*\]) tport='443' ;;
            *:*)
                _thost="${_tgt%:*}"
                if [[ -z "$_thost" || "$_thost" == *:* ]]; then return 2; fi
                _tport_cand="${_tgt##*:}"
                if [[ "$_tport_cand" =~ ^[0-9]+$ ]] && (( 10#$_tport_cand >= 1 && 10#$_tport_cand <= 65535 )); then tport="$_tport_cand"; else return 2; fi ;;
            *)
                if [[ "$_tgt" =~ ^[0-9]+$ ]]; then return 2; fi
                tport='443' ;;
        esac
    fi
    # R1-12-F2: ''/0.0.0.0 stay on IPv4 loopback; :: goes via ::1.
    case "$listen" in ''|0.0.0.0) dial='127.0.0.1' ;; '::') dial='::1' ;; *) dial="$listen" ;; esac
    [[ -z "$xhost" ]] && xhost="$sni"
    lf="${ABOX_DIR:-/etc/ddr}/standalone-links.d/$(users_link_stem "$core" "$tag" 2>/dev/null || printf '%s' "$tag").link"
    # SYD-B2 E20: derive the pbk from the LIVE server private key first.
    # Link-file and .env copies go stale on redeploy (new keypair), and
    # a stale pbk fails REALITY auth outright (proven: wrong pbk -> 000).
    if [[ "$core" == 'sing-box' ]]; then
        _priv=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tls.reality.private_key // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
    else
        _priv=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.realitySettings.privateKey // ""' "$_jq_cfg" 2>/dev/null | head -n 1)
    fi
    if [[ -n "$_priv" ]]; then
        pbk=$(_reality_pbk_from_private "$_priv" 2>/dev/null || true)
        [[ -n "$pbk" ]] && pbk_src='live'
    fi
    if [[ -z "$pbk" && -f "$lf" && ! -L "$lf" ]]; then
        pbk=$(grep -o 'pbk=[^&#]*' "$lf" 2>/dev/null | head -n 1 | cut -d= -f2-)
        [[ -n "$pbk" ]] && pbk_src='link'
    fi
    if [[ -z "$pbk" ]]; then
        _envf="${ABOX_ENV:-/etc/ddr/.env}"
        if [[ -f "$_envf" && ! -L "$_envf" ]]; then
            pbk=$(grep -E '^PUBLIC_KEY=' "$_envf" 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
            [[ -n "$pbk" ]] && pbk_src='env'
        fi
    fi
    [[ -n "$pbk" ]] || return 2
    sport=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null) || return 2
    [[ -n "$sport" ]] || return 2
    tmpd=$(mktemp -d /tmp/A-Box-nsni-client.XXXXXX) || return 2
    cc="$tmpd/client.json"
    cerr=$(mktemp /tmp/A-Box-nsni-client-err.XXXXXX) || { rm -rf "$tmpd"; return 2; }
    cerr_curl=$(mktemp /tmp/A-Box-nsni-curl-err.XXXXXX) || { rm -rf "$tmpd"; rm -f "$cerr"; return 2; }
    # SYD-B2 E20: the server was just restarted by the caller; systemctl
    # restart returns before the new process listens. Without this wait
    # the temp client dials a dead port and the check false-negatives.
    # Diagnostics go to a fixed log (non-secret fields only: pbk length
    # and sid presence, never values).
    logf='/tmp/A-Box-nsni-check.log'
    # R1-12-F1: never append through a pre-planted symlink or a
    # foreign-owned file. A symlink is removed and the file is
    # recreated exclusively (noclobber), so a re-plant fails instead
    # of being followed; otherwise logging is disabled (/dev/null).
    if [[ -L "$logf" ]]; then rm -f -- "$logf"; fi
    if [[ -e "$logf" ]]; then
        if [[ ! -f "$logf" ]] || [[ -L "$logf" ]] || [[ "$(stat -c %u "$logf" 2>/dev/null)" != "0" ]]; then
            logf='/dev/null'
        fi
    else
        if ! (set -o noclobber; : > "$logf") 2>/dev/null; then
            logf='/dev/null'
        else
            chmod 600 "$logf" 2>/dev/null || true
        fi
    fi
    { printf 'nsni-check core=%s tag=%s sni=%s dial=%s port=%s tport=%s pbk_src=%s pbk_len=%s sid_set=%s flow=%s\n' "$core" "$tag" "$sni" "$dial" "$port" "$tport" "$pbk_src" "${#pbk}" "$([ -n "$sid" ] && printf yes || printf no)" "${flow:-}"; } >> "$logf" 2>/dev/null || true
    if _wait_tcp_port "$dial" "$port" 60; then ready=1; else ready=0; fi
    printf 'nsni-check server-ready=%s\n' "$ready" >> "$logf" 2>/dev/null || true
    if [[ "$ready" != 1 ]]; then printf 'nsni-check verdict=FAIL server-not-ready\n' >> "$logf" 2>/dev/null || true; rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"; return 1; fi
    if [[ "$core" != 'sing-box' && "$net" == 'grpc' && -z "$grpc_service" ]]; then
        # R4C12-02: a grpc inbound without a serviceName cannot be
        # reproduced; report unavailable (2, warn-and-continue),
        # not a definitive handshake failure (1, rollback).
        { printf 'nsni-check verdict=UNAVAILABLE grpc-no-service\n'; } >> "$logf" 2>/dev/null || true
        rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"
        return 2
    fi
    if [[ "$core" == 'sing-box' ]]; then
        jq -n --arg dial "$dial" --argjson port "$port" --rawfile uuid <(printf '%s' "$uuid") --arg sni "$sni" --arg pbk "$pbk" --rawfile sid <(printf '%s' "$sid") --arg flow "$flow" --argjson transport "$_transport" --argjson sport "$sport" '{
            log: {level: "warning"},
            inbounds: [{type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: $sport}],
            outbounds: [({type: "vless", tag: "proxy", server: $dial, server_port: $port, uuid: $uuid} + (if $flow != "" then {flow: $flow} else {} end) + (if $transport != null then {transport: $transport} else {} end) + {
                tls: {enabled: true, server_name: $sni, reality: {enabled: true, public_key: $pbk, short_id: $sid}, utls: {enabled: true, fingerprint: "chrome"}}})]
        }' > "$cc" 2>/dev/null || { rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"; return 2; }
        "$bin" run -c "$cc" >"$cerr" 2>&1 & pid=$!
    else
        jq -n --arg dial "$dial" --argjson port "$port" --rawfile uuid <(printf '%s' "$uuid") --arg flow "$flow" --arg net "$net" --arg sni "$sni" --arg pbk "$pbk" --rawfile sid <(printf '%s' "$sid") --arg xpath "$xpath" --arg xhost "$xhost" --arg xmode "$xmode" --arg grpc_service "$grpc_service" --argjson sport "$sport" '{
            log: {loglevel: "warning"},
            inbounds: [{port: $sport, listen: "127.0.0.1", protocol: "socks", settings: {auth: "noauth", udp: true}, tag: "socks-in"}],
            outbounds: [{protocol: "vless", settings: {vnext: [{address: $dial, port: $port, users: [{id: $uuid, flow: $flow, encryption: "none"}]}]},
                streamSettings: ({network: $net, security: "reality",
                    realitySettings: {serverName: $sni, publicKey: $pbk, shortId: $sid, fingerprint: "chrome"}}
                    + (if $net == "xhttp" then {xhttpSettings: {path: $xpath, host: $xhost, mode: $xmode}} elif $net == "grpc" then {grpcSettings: {serviceName: $grpc_service}} else {} end))}]
        }' > "$cc" 2>/dev/null || { rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"; return 2; }
        "$bin" run -config "$cc" >"$cerr" 2>&1 & pid=$!
    fi
    while (( i < 40 )); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$sport") 2>/dev/null; then
            # 06b1-M2: a connectable port is not proof OUR temp client
            # owns it: the port was picked then released, so a squatter
            # may have bound it first (our client then fails to bind
            # and curl would probe through the stranger). Verify the
            # listener's PID before trusting the port; anything else is
            # unavailable (2), never a handshake verdict.
            _owner=$(_nsni_tcp_listener_pid "$sport" 2>/dev/null || true)
            if [[ "$_owner" == "$pid" ]]; then up=1; break; fi
            { printf 'nsni-check temp-socks-squatted owner=%s\n' "${_owner:-unknown}"; } >> "$logf" 2>/dev/null || true
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"; return 2
        fi
        sleep 0.25; i=$((i + 1))
    done
    if (( up == 0 )); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; { printf 'nsni-check temp-socks-down\n'; tail -n 20 "$cerr" 2>/dev/null; } >> "$logf" 2>/dev/null || true; rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"; return 2; fi
    code=''
    # TB12: on the geo-enabled production path, the first handshake
    # after an xray restart takes ~5s (the server loads its geo/
    # routing data on first use: box measured 5.02s twice, server-side;
    # sandbox geo rig 5.75s), while steady state is ~0.04s. A minimal
    # server WITHOUT the geo rule serves its first handshake in <3s.
    # The killing matters: a handshake killed mid-load aborts the
    # server-side geo-load step, so the next try restarts it and is
    # killed again -- retries at the SAME timeout can never win. Only
    # a single attempt longer than the slow step can. A 12s cold-path
    # probe failed both tries at the old 10s connect-timeout.
    # Per-try timeouts therefore grow: try 1 (20s connect / 30s max)
    # already exceeds the measured cold path (5.02s box, 5.75s
    # sandbox, 12s probe); try 2 (40s / 60s) is the fallback for
    # slower machines. Loop budget 30+1+60 = 91s worst case. The
    # boundary is now 40s: a cold path slower than that still
    # false-negatives -- no finite timeout eliminates it. The dial
    # address is irrelevant (both ::1 and 127.0.0.1 need the same
    # ~5s on the first handshake).
    for _try in 1 2; do
        case "$_try" in
            1) _ct=20; _mt=30 ;;
            *) _ct=40; _mt=60 ;;
        esac
        code=$(curl -sS -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$sport" --noproxy '' --connect-timeout "$_ct" --max-time "$_mt" "https://$sni:$tport/" 2>"$cerr_curl")
        curl_rc=$?
        [[ "$curl_rc" != 0 ]] && code='000'
        printf 'nsni-check try=%s curl-rc=%s http=%s\n' "$_try" "$curl_rc" "$code" >> "$logf" 2>/dev/null || true
        [[ "$code" =~ ^[0-9][0-9][0-9]$ && "$code" != '000' ]] && break
        sleep 1
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    { printf 'nsni-check temp-client-stderr-tail:\n'; tail -n 20 "$cerr" 2>/dev/null; printf 'nsni-check curl-stderr-tail:\n'; tail -n 5 "$cerr_curl" 2>/dev/null; } >> "$logf" 2>/dev/null || true
    rm -f "$cerr" "$cerr_curl"; rm -rf "$tmpd"
    # 06b1-M1: a TLS-layer curl failure proves the tunnel carried the
    # handshake to the target, so it is indeterminate (2), never a
    # deterministic REALITY failure (1). curl 60 (peer cert untrusted
    # by the local CA store), 51 (peer cert not OK) and 35 (TLS
    # handshake error) can only happen after the SOCKS/REALITY leg
    # delivered the ClientHello and the target answered with TLS.
    # Connection-layer failures (7, 28, 97, ...) stay 1: the tunnel
    # itself never proved up.
    if [[ "$curl_rc" == 60 || "$curl_rc" == 51 || "$curl_rc" == 35 ]]; then
        printf 'nsni-check verdict=INDETERMINATE curl-rc=%s (TLS-layer failure; tunnel proven up)\n' "$curl_rc" >> "$logf" 2>/dev/null || true
        msg "${YELLOW}[!] SNI handshake check indeterminate (curl rc $curl_rc: TLS-layer failure, tunnel proven up); new SNI is unverified.${NC}" >&2
        return 2
    fi
    if [[ "$code" =~ ^[0-9][0-9][0-9]$ && "$code" != '000' ]]; then
        printf 'nsni-check verdict=PASS\n' >> "$logf" 2>/dev/null || true
        return 0
    else
        printf 'nsni-check verdict=FAIL\n' >> "$logf" 2>/dev/null || true
        msg "[!] SNI handshake check failed; diagnostics: $logf"
        return 1
    fi
}

_nsni_apply() {
    local core="$1" tag="$2" kind="$3" cfg="$4" old="$5" new="$6" key="${7:-}" crt="${8:-}"
    local bak='' tmp='' bin='' filter=''
    bak=$(mktemp /tmp/A-Box-nsni-bak.XXXXXX) || return 1
    cp -a "$cfg" "$bak" && chmod 600 "$bak" || { rm -f "$bak"; return 1; }
    # H-06(3b): record the live config's mode/owner before any replace:
    # install_file_atomically swaps the inode (mv), so mode/owner must
    # be restored explicitly (plain `cat >` used to keep them).
    local _cfgmode='600' _cfgowner='root:root'
    _cfgmode=$(stat -c %a "$cfg" 2>/dev/null || printf '600')
    _cfgowner=$(stat -c %U:%G "$cfg" 2>/dev/null || printf 'root:root')
    local _was_running=0
    is_service_running "$core" 2>/dev/null && _was_running=1
    local _nsni_d=''
    _nsni_d=$(mktemp -d /tmp/A-Box-nsni.XXXXXX) || { rm -f "$bak"; return 1; }
    tmp="$_nsni_d/config.json"
    case "$kind" in
        reality-xray) filter='.inbounds |= map(if .tag == $t then (.streamSettings.realitySettings |= (.serverNames = [$s] | .target = (if .target then (if (.target | type) == "string" then (if (.target | test("^[/@]")) then .target else ($s + (.target | if contains(":") then (if test("^\\[.*\\]:") then sub("^\\[.*\\]"; "") elif test("^[^:]*:[^:]*$") then sub("^[^:]*"; "") else "" end) else "" end)) end) else .target end) else .target end) | .dest = (if .dest then (if (.dest | type) == "string" then (if (.dest | test("^[/@]")) then .dest else ($s + (.dest | if contains(":") then (if test("^\\[.*\\]:") then sub("^\\[.*\\]"; "") elif test("^[^:]*:[^:]*$") then sub("^[^:]*"; "") else "" end) else "" end)) end) else .dest end) else .dest end))) else . end)' ;;
        reality-sb) filter='.inbounds |= map(if .tag == $t then (.tls.reality.handshake.server = $s | if .tls.server_name then .tls.server_name = $s else . end) else . end)' ;;
        tuic) filter='.inbounds |= map(if .tag == $t then .tls.server_name = $s else . end)' ;;
        shadowtls) filter='.inbounds |= map(if .tag == $t then .handshake.server = $s else . end)' ;;
        *) rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1 ;;
    esac
    # L-01 (顺带): Xray configs are JSONC; read through the stripped
    # view like users_adopt/users_sync, so a commented config does not
    # fail the transform. sing-box configs are strict JSON: read raw.
    local _jq_cfg="$cfg"
    if [[ "$core" == xray ]]; then
        _jq_cfg=$(mktemp /tmp/A-Box-nsni-json.XXXXXX) || { rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1; }
        # C-2 (Gemini): save/restore the caller's RETURN trap (L10-fix pattern): a lingering trap refires on ancestor returns (fatal under set -u) and can delete an ancestor's live temp file.
        local _jq_caller_trap=''
        _jq_caller_trap=$(trap -p RETURN 2>/dev/null || true)
        trap 'rm -f -- "$_jq_cfg" 2>/dev/null || true; if [[ -n "${_jq_caller_trap:-}" ]]; then eval "$_jq_caller_trap"; else trap - RETURN; fi; true' RETURN
        jsonc_strip_comments "$cfg" > "$_jq_cfg" 2>/dev/null || { rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1; }
    fi
    if ! jq --arg t "$tag" --arg s "$new" "$filter" "$_jq_cfg" > "$tmp" 2>/dev/null; then rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1; fi
    case "$core" in
        xray) bin='/usr/local/bin/xray'; if [[ -x "$bin" ]]; then XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1; }; fi ;;
        sing-box) bin="${SB_PATH:-/usr/local/bin/sing-box}"; if [[ -x "$bin" ]]; then "$bin" check -c "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1; }; fi ;;
        *) rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; return 1 ;;
    esac
    # H-06(3b): atomic commit via install_file_atomically (mv), with the
    # recorded mode/owner restored explicitly; the rollback write below
    # is atomic the same way. A failed rollback keeps $bak for manual
    # recovery, as before.
    if ! install_file_atomically "$tmp" "$cfg" "$_cfgmode" || ! chown "$_cfgowner" "$cfg" 2>/dev/null; then
        if [[ -f "$bak" && -r "$bak" ]] && install_file_atomically "$bak" "$cfg" "$_cfgmode" && chown "$_cfgowner" "$cfg" 2>/dev/null; then rm -f "$tmp" "$bak"; rm -rf -- "$_nsni_d"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; rm -f "$tmp"; rm -rf -- "$_nsni_d"; fi
        return 1
    fi
    rm -f "$tmp"; rm -rf -- "$_nsni_d"
    local _kebak='' _crtbak='' _kemode='' _crtmode='' _tuic_cert_regen=0
    if [[ "$kind" == 'tuic' && -n "$key" && -n "$crt" ]]; then
        _kebak=$(mktemp /tmp/A-Box-nsni-keybak.XXXXXX 2>/dev/null || true)
        _crtbak=$(mktemp /tmp/A-Box-nsni-crtbak.XXXXXX 2>/dev/null || true)
        # R11-03: record the original modes before the backups are
        # tightened to 0600, so rollback can restore them (a 0640
        # file readable by a non-root core must stay readable).
        # Checked stat is part of the failure chain: a failed
        # capture aborts here, never silently with an empty mode.
        if [[ -z "$_kebak" || -z "$_crtbak" ]] || ! cp -a "$key" "$_kebak" 2>/dev/null || ! chmod 600 "$_kebak" 2>/dev/null || ! cp -a "$crt" "$_crtbak" 2>/dev/null || ! chmod 600 "$_crtbak" 2>/dev/null || ! _kemode=$(stat -c %a "$key" 2>/dev/null) || ! _crtmode=$(stat -c %a "$crt" 2>/dev/null); then
            if [[ -f "$bak" && -r "$bak" ]] && install_file_atomically "$bak" "$cfg" "$_cfgmode" && chown "$_cfgowner" "$cfg" 2>/dev/null; then rm -f "$bak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"; fi
            rm -f "$_kebak" "$_crtbak"
            return 1
        fi
        if ! generate_self_signed_cert_atomically "$key" "$crt" "$new" >/dev/null 2>&1; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        # R14-F11-04: the regenerated certificate is self-signed by
        # construction; the link must stop trusting it as a CA cert.
        _tuic_cert_regen=1
    fi
    # C-3 (Gemini): the regenerated key/crt are 0600 root:root (see
    # generate_self_signed_cert_atomically); the sing-box service user
    # cannot read them, so the service crash-loops under Restart=always
    # while _nsni_apply reports success. Restore the runtime permissions
    # BEFORE restarting; failure rolls back (old cert + config + modes).
    if (( _tuic_cert_regen == 1 )); then
        if ! prepare_abox_runtime_permissions "$core"; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
    fi
    if is_service_running "$core" 2>/dev/null; then
        # C-3 (Gemini): restart through restart_service_soft (daemon-reload
        # + restart + is-active check + ownership record) and confirm the
        # process is actually alive with ensure_service_running_soft (PID
        # liveness). A bare systemctl restart returns 0 for a Type=simple
        # job even while the service crash-loops, and the old code never
        # checked afterwards. Either failing rolls back.
        if ! restart_service_soft "$core"; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        if ! ensure_service_running_soft "$core"; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
    fi
    # SYD-B E20: a config-valid new SNI can still fail the live
    # handshake (microsoft case); run -test / check -c cannot catch
    # that. For reality kinds with a previously running service,
    # verify the live handshake BEFORE links or .env move to the new
    # SNI: failure (1) rolls back to the old SNI and returns 1;
    # indeterminate (2) only warns and continues. The message goes to
    # stderr so a caller capturing stdout cannot swallow it.
    if [[ "$kind" == reality-xray || "$kind" == reality-sb ]] && (( _was_running == 1 )); then
        msg "${CYAN}$(tr_msg nsni_checking)${NC}"
        _nsni_handshake_check "$core" "$tag" "$cfg" "$new"
        local _hs_rc=$?
        if (( _hs_rc == 1 )); then
            msg "${RED}[!] New SNI handshake failed; rolling back to the previous SNI.${NC}" >&2
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        elif (( _hs_rc == 2 )); then
            msg "${YELLOW}[!] Handshake self-check unavailable; new SNI is unverified.${NC}" >&2
        fi
    fi
    local _ldir="${ABOX_DIR:-/etc/ddr}/standalone-links.d" _lf='' _shown='' _stem='' _esc_old='' _esc_new='' _lbak=''
    _stem=$(users_link_stem "$core" "$tag" 2>/dev/null || printf '%s' "$tag")
    _lf="${_stem}.link"
    # H-06(1): ShadowTLS links carry no sni= parameter; the SNI lives in
    # the Base64 JSON behind ?shadow-tls=. Decode it, replace only .host
    # with the new SNI (password taken from the old JSON, never
    # regenerated), and re-encode with the deploy-time jq expression.
    if [[ "$kind" == shadowtls && -f "$_ldir/$_lf" && ! -L "$_ldir/$_lf" ]] && grep -q 'shadow-tls=' "$_ldir/$_lf" 2>/dev/null; then
        _lbak=$(mktemp /tmp/A-Box-nsni-linkbak.XXXXXX 2>/dev/null || true)
        if [[ -z "$_lbak" ]] || ! cp -a "$_ldir/$_lf" "$_lbak" 2>/dev/null; then
            rm -f "$_lbak" 2>/dev/null || true
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        local _st_b64='' _st_json='' _st_pass='' _st_new=''
        _st_b64=$(grep -o 'shadow-tls=[^#&]*' "$_ldir/$_lf" 2>/dev/null | cut -d= -f2- | head -1)
        _st_json=$(users_b64url_dec "$_st_b64" 2>/dev/null)
        _st_pass=$(printf '%s' "$_st_json" | jq -r '.password // ""' 2>/dev/null)
        if [[ -z "$_st_b64" || -z "$_st_json" || -z "$_st_pass" ]] || ! _st_new=$(jq -cn --arg h "$new" --arg p "$_st_pass" '{version:"3", host:$h, password:$p}' 2>/dev/null | base64 | tr -d '\n\r') || [[ -z "$_st_new" ]]; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        if ! sed -i -e "s|\(shadow-tls=\)[^#&]*|\1${_st_new}|" "$_ldir/$_lf" 2>/dev/null; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        _shown=$(cat "$_ldir/$_lf" 2>/dev/null)
    fi
    if [[ "$kind" != shadowtls && -f "$_ldir/$_lf" && ! -L "$_ldir/$_lf" ]] && grep -qF "sni=${old}" "$_ldir/$_lf" 2>/dev/null; then
        _esc_old=$(printf '%s' "$old" | sed 's/[][\\.|*^$]/\\&/g')
        _esc_new=$(printf '%s' "$new" | sed 's/[\\|&]/\\&/g')
        _lbak=$(mktemp /tmp/A-Box-nsni-linkbak.XXXXXX 2>/dev/null || true)
        # R11-04: a failed link backup must stop the edit here. The
        # old code cleared _lbak and ran sed -i anyway, so a later
        # .env failure rolled the config back but left the NEW SNI
        # in the link (service old SNI, link new SNI).
        if [[ -z "$_lbak" ]] || ! cp -a "$_ldir/$_lf" "$_lbak" 2>/dev/null; then
            rm -f "$_lbak" 2>/dev/null || true
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "" "" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        if ! sed -i -e "s|\([?&]sni=\)${_esc_old}\([&#]\)|\1${_esc_new}\2|g" -e "s|\([?&]sni=\)${_esc_old}\$|\1${_esc_new}|g" "$_ldir/$_lf" 2>/dev/null; then
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
        # R14-F11-04: the SNI change regenerated the TUIC certificate as
        # self-signed. A link kept from a CA-cert node carries no
        # allow_insecure, so the client would still try to verify the
        # new self-signed certificate and fail. Re-derive the trust
        # parameter from the regenerated certificate: force
        # allow_insecure=1 (adding it when absent).
        if [[ "$kind" == 'tuic' && "$_tuic_cert_regen" == 1 ]]; then
            if grep -q 'allow_insecure=' "$_ldir/$_lf" 2>/dev/null; then
                if ! sed -i '/tuic:\/\// s|allow_insecure=[^&#]*|allow_insecure=1|g' "$_ldir/$_lf" 2>/dev/null; then
                    if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                    return 1
                fi
            elif ! sed -i '/tuic:\/\//{s|#|\&allow_insecure=1#|;t;s|$|\&allow_insecure=1|}' "$_ldir/$_lf" 2>/dev/null; then
                if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                return 1
            fi
        fi
        _shown=$(cat "$_ldir/$_lf" 2>/dev/null)
    fi
    local _envf="${ABOX_ENV:-/etc/ddr/.env}" _envvar='' _etmp='' _ebak=''
    case "$tag" in
        vision) _envvar='VISION_SNI' ;;
        xhttp) _envvar='XHTTP_SNI' ;;
    esac
    if [[ -n "$_envvar" && -f "$_envf" && ! -L "$_envf" ]]; then
        _etmp=$(mktemp /tmp/A-Box-nsni-env.XXXXXX 2>/dev/null || true)
        if [[ -n "$_etmp" ]]; then
            if awk -v var="$_envvar" -v o="$old" -v n="$new" '{ v = $0; sub(/=.*/, "", v); if (v == var) { val = substr($0, length(v) + 2); q = ""; if (substr(val, 1, 1) == "\"" && substr(val, length(val), 1) == "\"") { q = "\""; val = substr(val, 2, length(val) - 2); } else if (substr(val, 1, 1) == "\047" && substr(val, length(val), 1) == "\047") { q = "\047"; val = substr(val, 2, length(val) - 2); } if (val == o || val == "") $0 = v "=" q n q; } print }' "$_envf" > "$_etmp" 2>/dev/null; then
                # R14-F11-03: the awk above only rewrites a key that
                # already exists with the old value. When the
                # per-protocol key is missing entirely (only VLESS_SNI
                # is set), append it: the link generator falls back to
                # VLESS_SNI, so without this later links keep the old SNI.
                # H-06(2): an empty value (VISION_SNI="") is rewritten
                # by the awk as well: write_env always writes the key,
                # so the missing-key append below never fires for it,
                # and the old SNI would otherwise survive through the
                # VLESS_SNI fallback.
                if ! grep -q "^${_envvar}=" "$_etmp" 2>/dev/null; then
                    if ! printf '%s=%s\n' "$_envvar" "$new" >> "$_etmp" 2>/dev/null; then
                        rm -f "$_etmp"
                        if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                        return 1
                    fi
                fi
                _ebak=$(mktemp /tmp/A-Box-nsni-envbak.XXXXXX 2>/dev/null || true)
                if [[ -n "$_ebak" ]] && cp -a "$_envf" "$_ebak" 2>/dev/null && chmod 600 "$_ebak" 2>/dev/null; then
                    # 06b2-M1: commit the .env atomically (tmp+mv) with
                    # the original mode/owner restored, like the config
                    # commit above. The old `cat tmp > envf` truncated
                    # the live file first: a SIGKILL mid-copy left an
                    # empty/truncated .env with no fallback.
                    local _envmode='600' _envowner='root:root'
                    _envmode=$(stat -c %a "$_envf" 2>/dev/null || printf '600')
                    _envowner=$(stat -c %U:%G "$_envf" 2>/dev/null || printf 'root:root')
                    if install_file_atomically "$_etmp" "$_envf" "$_envmode" && chown "$_envowner" "$_envf" 2>/dev/null; then
                        rm -f "$_ebak"
                    elif cp -a "$_ebak" "$_envf" 2>/dev/null; then
                        rm -f "$_etmp" "$_ebak"
                        if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                        return 1
                    else
                        msg "${RED}[!] $(tr_msg rollback_copy_fail)${NC}"
                        rm -f "$_etmp"
                        if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                        return 1
                    fi
                else
                    rm -f "$_etmp" "$_ebak"
                    if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                    return 1
                fi
            else
                # 06b2-L1: clean up the temp file on the awk-failure
                # path too, like every other failure branch here.
                if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
                rm -f "$_etmp"
                return 1
            fi
            rm -f "$_etmp"
        else
            if _nsni_rollback "$cfg" "$bak" "$key" "$crt" "$_kebak" "$_crtbak" "$core" "$_was_running" "$_ldir/$_lf" "$_lbak" "$_kemode" "$_crtmode"; then rm -f "$bak" "$_kebak" "$_crtbak"; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $bak${NC}"; fi
            return 1
        fi
    fi
    rm -f "$bak" "$_kebak" "$_crtbak" "$_lbak"
    [[ -n "$_shown" ]] && printf '%s' "$_shown"
    refresh_subscription_after_deploy || true
    return 0
}

node_sni_menu() {
    while true; do
        clear
        msg "${CYAN}======================================================================${NC}"
        msg "${BOLD}${GREEN}$(tr_msg tb_nsni)${NC}"
        msg "${CYAN}======================================================================${NC}"
        local rows='' i=0 core='' tag='' proto='' port='' probe='' kind='' cur='' key='' crt='' cfg=''
        rows=$(protocol_inventory 2>/dev/null || true)
        local -a _cs=() _ts=() _ks=() _os=() _cfgs=()
        while IFS=$'\t' read -r core tag proto port; do
            [[ -n "$core" && -n "$tag" ]] || continue
            case "$proto" in socks|mixed|shadowsocks|hysteria2) continue ;; esac
            case "$tag" in *-ws-in) continue ;; esac
            probe=$(_nsni_probe "$core" "$tag")
            [[ -n "$probe" ]] || continue
            IFS='|' read -r kind cur key crt cfg <<< "$probe"
            [[ -n "$cur" ]] || continue
            i=$((i + 1))
            _cs+=("$core"); _ts+=("$tag"); _ks+=("$kind"); _os+=("$cur"); _cfgs+=("$cfg")
            printf '%3d. %-40s %-11s :%-6s %s: %s\n' "$i" "$(protocol_label "$tag" "$proto" 2>/dev/null || printf '%s' "$tag")" "$core" "$port" "$(tr_msg nsni_cur)" "$cur"
        done <<< "$rows"
        if (( i == 0 )); then msg "${YELLOW}$(tr_msg nsni_none)${NC}"; fi
        msg "  ${CYAN}0.${NC} $(tr_msg mu_back_word)"
        local c=''
        read -r -p "$(tr_msg select_prompt) [0-${i}]: " c || return 0
        c=$(normalize_fa_ar_digits "$c")
        case "$c" in
            0|'') return 0 ;;
            *[!0-9]*) msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1 ;;
            *)
                if valid_decimal_upto "$c" "$i" && (( 10#$c >= 1 && 10#$c <= i )); then
                    local _ix=$((10#$c - 1)) _probe2='' _k2='' _c2='' _new='' _shown='' _dns_rc=0 _tier='' _answer=''
                    _probe2=$(_nsni_probe "${_cs[$_ix]}" "${_ts[$_ix]}")
                    IFS='|' read -r _ _ _k2 _c2 _ <<< "$_probe2"
                    printf '%s: %s\n' "$(tr_msg nsni_cur)" "${_os[$_ix]}"
                    read -r -p "$(tr_msg nsni_prompt)" _new || continue
                    _new=$(printf '%s' "$_new" | tr -d '[:space:]')
                    [[ -n "$_new" ]] || continue
                    if ! valid_sni "$_new"; then msg "${RED}$(tr_msg nsni_invalid)${NC}"; pause_return; continue; fi
                    # F-NEW-03: same three-tier gate as deploy-time SNI input.
                    sni_dns_resolvable "$_new"; _dns_rc=$?
                    if (( _dns_rc == 1 )); then
                        msg "${RED}[SNI] $(tprintf sni_unresolvable "$_new")${NC}"
                        pause_return; continue
                    fi
                    _tier=$(sni_probe_candidate_tier "$_new" 2>/dev/null || printf 'N')
                    case "$_tier" in
                        A|B|C) ;;
                        *)
                            case "$_tier" in
                                R) msg "${YELLOW}[SNI] $(tr_msg sni_risky)${NC}" ;;
                                D) msg "${YELLOW}[SNI] $(tr_msg sni_fail)${NC}" ;;
                                *) msg "${YELLOW}[SNI] $(tr_msg sni_untestable)${NC}" ;;
                            esac
                            read -r -p "$(tprintf continue_or_reset 'SNI')" _answer || continue
                            is_yes "$_answer" || continue
                            ;;
                    esac
                    if _shown=$(_nsni_apply "${_cs[$_ix]}" "${_ts[$_ix]}" "${_ks[$_ix]}" "${_cfgs[$_ix]}" "${_os[$_ix]}" "$_new" "$_k2" "$_c2"); then
                        msg "${GREEN}$(tr_msg nsni_done)${NC}"
                        [[ -n "$_shown" ]] && msg "${LBLW}${_shown}${NC}"
                        msg "${YELLOW}$(tr_msg nsni_warn)${NC}"
                    else
                        msg "${RED}$(tr_msg nsni_fail)${NC}"
                    fi
                    pause_return
                else
                    msg "${RED}$(tr_msg invalid_input)${NC}"; sleep 1
                fi ;;
        esac
    done
}

user_guard_tick() {
    # R14-F12-03: no `2>/dev/null` here. A bare `exec` with
    # redirections applies them to the current shell permanently, so
    # the stderr redirect used to swallow every later diagnostic in
    # this tick — including the flock-failure error the comment below
    # requires to stay visible. The open failure itself is still
    # caught by `|| return 0` (a failed exec redirect does not exit
    # the shell when it is part of an || list).
    exec 9>>/run/A-Box-user-guard.lock || return 0
    flock -n 9; _flock_rc=$?
    if (( _flock_rc != 0 )); then
        # rc 1 is contention: another tick holds the lock, skip silently.
        # Any other rc (127 = flock missing, ...) must not masquerade as
        # success: the quota enforcement after this point would be
        # silently disabled (R10C12-01).
        (( _flock_rc == 1 )) || { msg "${RED}A-Box: flock failed (rc=$_flock_rc), not contention.${NC}" >&2; return 1; }
        return 0
    fi
    # The tick entry point bypasses enter_runtime, so detect the
    # init system here: service-state helpers key off INIT_SYS and
    # would otherwise report every service as down (no stats would
    # ever fold in and quota blocks would never trigger).
    if systemd_available; then INIT_SYS='systemd'; elif command -v rc-service >/dev/null 2>&1; then INIT_SYS='openrc'; else return 0; fi
    # Serialize against interactive sessions (which hold the main
    # runtime lock): skip this round instead of racing users_sync.
    # fd 8 is used because fd 9 carries both this guard lock and,
    # in interactive processes, the runtime flock itself.
    if command -v flock >/dev/null 2>&1; then
        # 06b2-M2: same rc rule as the fd 9 block above: rc 1 is
        # contention (skip silently); an open failure or any other
        # flock error must not masquerade as success, or the quota
        # enforcement after this point would be silently disabled
        # (R10C12-01).
        exec 8>>"${LOCK_FILE:-/run/A-Box.lock}" || { msg "${RED}A-Box: cannot open main runtime lock ${LOCK_FILE:-/run/A-Box.lock}.${NC}" >&2; return 1; }
        flock -n 8; _flock_rc=$?
        if (( _flock_rc != 0 )); then
            (( _flock_rc == 1 )) || { msg "${RED}A-Box: flock failed (rc=$_flock_rc), not contention.${NC}" >&2; return 1; }
            return 0
        fi
    fi
    local now_s='' period='' hhmm=''
    now_s=$(date +%s); period=$(date '+%Y-%m'); hhmm=$(date '+%H:%M')
    # R3-04-C1: the period is a local-month interval, so resolve it to UTC
    # boundary epochs in the same timezone context that produced $period.
    # The next month is computed by integer year/month arithmetic: GNU date
    # relative '+1 month' is DST-unsafe (2026-11-01 +1 month lands 9h short).
    # On conversion failure the bounds stay null and created_in_period()
    # returns false (first sample baselined, fail-open undercount).
    local _per_start=null _per_end=null
    local _per_year _per_month _next_year _next_month _next_period
    local _start_epoch _end_epoch
    if [[ "$period" =~ ^([0-9]{4})-(0[1-9]|1[0-2])$ ]]; then
        _per_year=$((10#${BASH_REMATCH[1]}))
        _per_month=$((10#${BASH_REMATCH[2]}))
        _next_year=$((_per_year + (_per_month == 12)))
        _next_month=$((_per_month % 12 + 1))
        printf -v _next_period '%04d-%02d' "$_next_year" "$_next_month"
        if _start_epoch=$(date -d "${period}-01 00:00:00" +%s 2>/dev/null) &&
           _end_epoch=$(date -d "${_next_period}-01 00:00:00" +%s 2>/dev/null) &&
           [[ "$_start_epoch" =~ ^-?[0-9]+$ &&
              "$_end_epoch" =~ ^-?[0-9]+$ ]] &&
           (( _end_epoch > _start_epoch )); then
            _per_start=$_start_epoch
            _per_end=$_end_epoch
        fi
    fi
    local core='' tag='' proto='' port=''
    while IFS=$'\t' read -r core tag proto port; do
        [[ -n "$core" && -n "$tag" && "$proto" != 'shadowtls' ]] || continue
        users_reg_ensure "$core" "$tag" >/dev/null 2>&1 || true
    done < <(protocol_inventory 2>/dev/null || true)
    local stats_xray='' have_xray=0
    local gen_xray=''
    if is_service_running xray 2>/dev/null; then
        stats_xray=$(users_stats_snapshot /usr/local/bin/xray 10085) && have_xray=1
        gen_xray=$(users_core_generation xray 2>/dev/null || true)
    fi
    local reg='' rcore='' rtag='' stats='' have=0 gen=''
    # R43-02: accumulate evaluation failures instead of dropping
    # them: users_guard_eval returns 1 when the registry commit
    # fails, and the tick used to report success anyway. Keep
    # processing the other registries; the .sync-pending retry
    # mechanism is unchanged (the marker is planted before the
    # commit, so the next tick retries). Diagnostic is core/tag
    # only -- no credentials.
    local _eval_failed=0
    for reg in "${ABOX_USERS_DIR:-$USERS_DIR}"/*.json; do
        [[ -f "$reg" ]] || continue
        rcore=$(jq -r '.core // ""' "$reg" 2>/dev/null); rtag=$(jq -r '.tag // ""' "$reg" 2>/dev/null)
        [[ -n "$rcore" && -n "$rtag" ]] || continue
        case "$rcore" in
            xray) stats="$stats_xray"; have=$have_xray; gen="$gen_xray" ;;
            hy2) stats=''; have=0; gen='' ;;  # M-38: this script does not currently consume any Hy2 stats source; only expiry/window are enforced, quota never triggers
            *) stats=''; have=0; gen='' ;;
        esac
        users_guard_eval "$reg" "$rcore" "$rtag" "$now_s" "$period" "$hhmm" "$stats" "$have" "$gen" "$_per_start" "$_per_end" || { _eval_failed=1; msg "${RED}[!] A-Box user guard: evaluation failed for ${rcore}/${rtag}; the registry change was not committed and will be retried next tick.${NC}" >&2; }
    done
    (( _eval_failed == 0 )) || return 1
    return 0
}


try_latest_cores_danger() {
    local answer targets=() t latest
    clear
    msg "${RED}${BOLD}$(tr_msg try_latest_cores_danger_title)${NC}"
    msg "$(tprintf tl_body "${ABOX_XRAY_DEFAULT_VERSION}" "${ABOX_SINGBOX_DEFAULT_VERSION}" "${ABOX_HYSTERIA_DEFAULT_VERSION}")"
    msg "$(tr_msg tl_risk)"
    read -r -p "$(tr_msg tl_type_yes)" answer
    [[ "$answer" == 'YES' ]] || { msg "${YELLOW}$(tr_msg tl_cancelled)${NC}"; pause_return; return 0; }
    init_system_environment
    load_optional_abox_env_or_die
    if abox_owns_service xray && [[ -x /usr/local/bin/xray ]]; then targets+=(xray); fi
    if abox_owns_service sing-box && [[ -x /usr/local/bin/sing-box ]]; then targets+=(singbox); fi
    if abox_owns_service hysteria && [[ -x /usr/local/bin/hysteria ]]; then targets+=(hysteria); fi
    (( ${#targets[@]} > 0 )) || { msg "${YELLOW}$(tr_msg tl_no_owned)${NC}"; pause_return; return 0; }
    # Each core gets an independent transaction in a subshell, with a
    # rollback-status file like upgrade_current_cores_only (M-11): a
    # failed/unknown rollback stops the loop instead of letting the
    # next core's begin snapshot the already-damaged state.
    local failed_cores=() stopped=0 idx=0
    for t in "${targets[@]}"; do
        msg "${CYAN}$(tprintf tl_trying "$t")${NC}"
        local rb_status rb_state
        rb_status=$(mktemp) || { msg "${RED}[!] [$t] cannot create rollback status file; aborting latest-core attempts.${NC}"; return 1; }
        printf 'not-started\n' > "$rb_status" || { rm -f -- "$rb_status"; msg "${RED}[!] [$t] cannot create rollback status file; aborting latest-core attempts.${NC}"; return 1; }
        ABOX_CORE_TX_RB_STATUS="$rb_status"
        if core_upgrade_transaction_attempt "$t" try_latest_upgrade_one "$t"; then
            rm -f -- "$rb_status"
            msg "${GREEN}$(tprintf tl_done_one "$t")${NC}"
        else
            rb_state=$(cat "$rb_status" 2>/dev/null || echo unknown)
            rm -f -- "$rb_status"
            case "$rb_state" in
                ok)
                    msg "${YELLOW}$(tprintf tl_failed_one "$t")${NC}"
                    failed_cores+=("$t")
                    ;;
                not-started)
                    msg "${YELLOW}[!] [$t] latest attempt failed before any change was made; no rollback needed; continuing.${NC}"
                    failed_cores+=("$t")
                    ;;
                not-modified)
                    msg "${YELLOW}[!] [$t] latest attempt failed during precheck; installed binary was not changed, no rollback needed; continuing.${NC}"
                    failed_cores+=("$t")
                    ;;
                failed)
                    msg "${RED}[!] [$t] latest attempt failed and its rollback FAILED; stopping further latest-core attempts.${NC}"
                    failed_cores+=("$t"); stopped=1
                    break
                    ;;
                *)
                    msg "${RED}[!] [$t] latest attempt failed with rollback state unknown (interrupted mid-transaction); stopping further latest-core attempts.${NC}"
                    failed_cores+=("$t"); stopped=1
                    break
                    ;;
            esac
        fi
        idx=$((idx+1))
    done
    ABOX_CORE_TX_RB_STATUS=''
    if (( stopped == 1 )); then
        # R16C16-02 mirror: the unattempted cores are the targets after
        # the one that stopped the loop, not failed_cores.
        local unattempted=() j
        for (( j=idx+1; j<${#targets[@]}; j++ )); do unattempted+=("${targets[j]}"); done
        msg "${YELLOW}[!] Latest-core loop stopped early; failed cores: ${failed_cores[*]}; remaining cores not attempted: ${unattempted[*]}${NC}"
    fi
    if (( ${#failed_cores[@]} > 0 )); then
        msg "${YELLOW}$(tprintf tl_finished_fail "${failed_cores[*]}")${NC}"
    else
        msg "${GREEN}$(tr_msg tl_finished_ok)${NC}"
    fi
    pause_return
}


valid_ip_pref() {
    [[ "${1:-}" =~ ^(ipv4|ipv6|dual)$ ]]
}

read_ip_pref() {
    local v='dual'
    if [[ -r "$IP_PREF_FILE" && -f "$IP_PREF_FILE" && ! -L "$IP_PREF_FILE" ]]; then
        [[ "$(stat -c %u:%g "$IP_PREF_FILE" 2>/dev/null || true)" == '0:0' ]] || { printf 'dual\n'; return 0; }
        local _m; _m=$(stat -c %a "$IP_PREF_FILE" 2>/dev/null || echo 777)
        [[ "$_m" =~ ^[0-7]{3,4}$ ]] && (( (8#$_m & 8#022) == 0 )) || { printf 'dual\n'; return 0; }
        v=$(tr -d '[:space:]' < "$IP_PREF_FILE" 2>/dev/null || true)
    fi
    valid_ip_pref "$v" || v='dual'
    printf '%s\n' "$v"
}

save_ip_pref() {
    local v="${1:-}"
    valid_ip_pref "$v" || die "$(tr_msg ip_pref_bad)"
    ensure_abox_dir_owned "$ABOX_DIR" || die "$(tr_msg state_dir_prep)"
    write_file_atomically_from_stdin "$IP_PREF_FILE" 600 <<< "$v" || die "$(tr_msg ip_pref_write)"
}

ip_preference_menu() {
    # Submenu loop: 0/Enter returns to the parent menu.
    while true; do
    clear
    local cur c title ipv4 ipv6 dual back
    cur=$(read_ip_pref)
    case "${ABOX_LANG:-zh}" in
        en) title='IP protocol preference'; ipv4='IPv4 only (0.0.0.0 listener; prefer IPv4 share links)'; ipv6='IPv6 only (:: listener; requires working global IPv6)'; dual='Dual stack (prefer IPv6 when available, otherwise IPv4)'; back='Back' ;;
        ru) title='Предпочтение IP-протокола'; ipv4='Только IPv4 (слушатель 0.0.0.0)'; ipv6='Только IPv6 (требуется глобальный IPv6)'; dual='Два стека (IPv6 при доступности, иначе IPv4)'; back='Назад' ;;
        fa) title='ترجیح پروتکل IP'; ipv4='فقط IPv4 (نشانی شنونده 0.0.0.0)'; ipv6='فقط IPv6 (نیازمند IPv6 عمومی فعال)'; dual='دوپشته (در صورت دسترسی IPv6، وگرنه IPv4)'; back='بازگشت' ;;
        zh-tw) title='IP 協議偏好'; ipv4='僅 IPv4（監聽 0.0.0.0，分享連結優先 IPv4）'; ipv6='僅 IPv6（需要可用的全域性 IPv6）'; dual='雙棧（優先可用 IPv6，否則 IPv4）'; back='返回' ;;
        ja)
            title='IP プロトコルの設定'; ipv4='IPv4 のみ（0.0.0.0 でリッスンし、共有リンクでは IPv4 を優先）'; ipv6='IPv6 のみ（利用可能なグローバル IPv6 が必要）'; dual='デュアルスタック（IPv6 が利用可能な場合は優先し、それ以外は IPv4）'; back='戻る' ;;
        *) title='IP 协议偏好'; ipv4='仅 IPv4（监听 0.0.0.0，分享链接优先 IPv4）'; ipv6='仅 IPv6（需要可用的全局 IPv6）'; dual='双栈（优先可用 IPv6，否则 IPv4）'; back='返回' ;;
    esac
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$title${NC}"
    msg "$(tprintf ip_pref_current "${YELLOW}$cur${NC}")"
    msg "${CYAN}1.${NC} $ipv4"
    msg "${CYAN}2.${NC} $ipv6"
    msg "${CYAN}3.${NC} $dual"
    msg "${CYAN}0.${NC} $back"
    read -r -p "$(tr_msg ip_select_0_3)" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) save_ip_pref ipv4 ;;
        2)
            # Objective check (not has_ipv6()): the gate must test what
            # the host can do, not the current preference -- has_ipv6()
            # is false in IPv4-preferred mode even with working global
            # IPv6, which made IPv6-only unreachable directly from IPv4.
            # R15-F12-01: BOTH conditions are required for usable global
            # IPv6 -- an address without a default route has no exit,
            # and a default route without a global address has no source.
            # The old '!A && !B' rejected only when both were missing.
            if ! ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { found=1 } END { exit !found }' || ! ip -6 route show default 2>/dev/null | awk '/^default/ { found=1 } END { exit !found }'; then
                case "${ABOX_LANG:-zh}" in
                    en) msg "${RED}No usable global IPv6 was detected; IPv6-only mode was not saved.${NC}" ;;
                    ru) msg "${RED}Рабочий глобальный IPv6 не обнаружен; режим IPv6-only не сохранён.${NC}" ;;
                    fa) msg "${RED}IPv6 عمومی قابل استفاده یافت نشد؛ حالت فقط IPv6 ذخیره نشد.${NC}" ;;
                    zh-tw) msg "${RED}系統當前無可用全域性 IPv6，未儲存僅 IPv6 模式。${NC}" ;;
                    ja)
                        msg "${RED}利用可能なグローバル IPv6 が検出されなかったため、IPv6 のみのモードは保存されませんでした。${NC}" ;;
                    *) msg "${RED}系统当前无可用全局 IPv6，未保存仅 IPv6 模式。${NC}" ;;
                esac
                pause_return; return 1
            fi
            save_ip_pref ipv6 ;;
        3) save_ip_pref dual ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1; continue ;;
    esac
    case "${ABOX_LANG:-zh}" in
        en) msg "${GREEN}Saved: $(read_ip_pref). New listener preference applies to future deployments; running nodes require redeployment or an applicable restart.${NC}" ;;
        ru) msg "${GREEN}Сохранено: $(read_ip_pref). Настройка слушателя применяется к новым узлам; существующие узлы нужно переустановить или перезапустить.${NC}" ;;
        fa) msg "${GREEN}ذخیره شد: $(read_ip_pref). این تنظیم برای استقرارهای بعدی اعمال می‌شود؛ نودهای فعال به استقرار مجدد یا راه‌اندازی مجدد نیاز دارند.${NC}" ;;
        zh-tw) msg "${GREEN}已儲存：$(read_ip_pref)。新監聽偏好對後續部署生效；已執行節點需重新部署或適當重啟。${NC}" ;;
        ja)
            msg "${GREEN}保存しました: $(read_ip_pref)。新しいリスナー設定は今後のデプロイに適用されます。稼働中のノードには再デプロイまたは適切な再起動が必要です。${NC}" ;;
        *) msg "${GREEN}已保存：$(read_ip_pref)。新监听偏好对后续部署生效；已运行节点需重新部署或适当重启。${NC}" ;;
    esac
    pause_return
    done
}
host_network_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    clear
    local prompt
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}Network and regional settings${NC}"
            msg "${CYAN}1.${NC} IP protocol preference"
            msg "${CYAN}2.${NC} Host DNS, DNS benchmark, DoT and DoH"
            msg "${CYAN}3.${NC} Timezone, locale and NTP"
            msg "${CYAN}4.${NC} Fast/strict mode and download source"
            msg "${CYAN}0.${NC} Back"
            ;;
        ru)
            msg "${BOLD}${GREEN}Сеть и региональные настройки${NC}"
            msg "${CYAN}1.${NC} Предпочтение IP"
            msg "${CYAN}2.${NC} DNS, автоматическое тестирование производительности, DoT и DoH"
            msg "${CYAN}3.${NC} Часовой пояс, локаль и NTP"
            msg "${CYAN}4.${NC} Режим и источник загрузки"
            msg "${CYAN}0.${NC} Назад"
            ;;
        fa)
            msg "${BOLD}${GREEN}تنظیمات شبکه و منطقه‌ای${NC}"
            msg "${CYAN}1.${NC} ترجیح IP"
            msg "${CYAN}2.${NC} DNS، سنجش خودکار عملکرد، DoT و DoH"
            msg "${CYAN}3.${NC} منطقه زمانی، locale و NTP"
            msg "${CYAN}4.${NC} حالت و منبع دانلود"
            msg "${CYAN}0.${NC} بازگشت"
            ;;
        zh-tw)
            msg "${BOLD}${GREEN}網路與地區設定${NC}"
            msg "${CYAN}1.${NC} IP 協議偏好（IPv4 / IPv6 / 雙棧）"
            msg "${CYAN}2.${NC} 本機 DNS（自動測速 / DoT / DoH / 回滾）"
            msg "${CYAN}3.${NC} 時區、Locale 與 NTP"
            msg "${CYAN}4.${NC} 快速/嚴格模式與下載源"
            msg "${CYAN}0.${NC} 返回"
            ;;
        ja)
            msg "${BOLD}${GREEN}ネットワークと地域の設定${NC}"
            msg "${CYAN}1.${NC} IP プロトコルの設定（IPv4 / IPv6 / デュアルスタック）"
            msg "${CYAN}2.${NC} ホスト DNS（自動ベンチマーク / DoT / DoH / ロールバック）"
            msg "${CYAN}3.${NC} タイムゾーン、Locale、NTP"
            msg "${CYAN}4.${NC} 高速モード / 厳格モードとダウンロード元"
            msg "${CYAN}0.${NC} 戻る"
            ;;
        *)
            msg "${BOLD}${GREEN}网络与地区设置${NC}"
            msg "${CYAN}1.${NC} IP 协议偏好（IPv4 / IPv6 / 双栈）"
            msg "${CYAN}2.${NC} 本机 DNS（自动测速 / DoT / DoH / 回滚）"
            msg "${CYAN}3.${NC} 时区、Locale 与 NTP"
            msg "${CYAN}4.${NC} 快速/严格模式与下载源"
            msg "${CYAN}0.${NC} 返回"
            ;;
    esac
    local c
    case "${ABOX_LANG:-zh}" in en) prompt='Select [0-4]: ' ;; ru) prompt='Выберите [0–4]: ' ;; fa) prompt='انتخاب [۰ تا ۴]: ' ;; ja) prompt='選択してください [0-4]: ' ;; zh-tw) prompt='請選擇 [0-4]：' ;; *) prompt='请选择 [0-4]：' ;; esac
    read -r -p "$prompt" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) ip_preference_menu ;;
        2) dns_menu ;;
        3) timezone_menu ;;
        4) ux_mode_menu ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}

timezone_for_country() {
    case "${1^^}" in
        CN) printf 'Asia/Shanghai\n' ;;
        HK) printf 'Asia/Hong_Kong\n' ;;
        TW) printf 'Asia/Taipei\n' ;;
        SG) printf 'Asia/Singapore\n' ;;
        JP) printf 'Asia/Tokyo\n' ;;
        KR) printf 'Asia/Seoul\n' ;;
        IN) printf 'Asia/Kolkata\n' ;;
        ID) printf 'Asia/Jakarta\n' ;;
        TH) printf 'Asia/Bangkok\n' ;;
        VN) printf 'Asia/Ho_Chi_Minh\n' ;;
        MY) printf 'Asia/Kuala_Lumpur\n' ;;
        PH) printf 'Asia/Manila\n' ;;
        AU) printf 'Australia/Sydney\n' ;;
        NZ) printf 'Pacific/Auckland\n' ;;
        US) printf 'America/New_York\n' ;;
        CA) printf 'America/Toronto\n' ;;
        BR) printf 'America/Sao_Paulo\n' ;;
        MX) printf 'America/Mexico_City\n' ;;
        GB|UK) printf 'Europe/London\n' ;;
        IE) printf 'Europe/Dublin\n' ;;
        FR) printf 'Europe/Paris\n' ;;
        DE) printf 'Europe/Berlin\n' ;;
        NL) printf 'Europe/Amsterdam\n' ;;
        BE) printf 'Europe/Brussels\n' ;;
        CH) printf 'Europe/Zurich\n' ;;
        AT) printf 'Europe/Vienna\n' ;;
        SE) printf 'Europe/Stockholm\n' ;;
        NO) printf 'Europe/Oslo\n' ;;
        FI) printf 'Europe/Helsinki\n' ;;
        PL) printf 'Europe/Warsaw\n' ;;
        CZ) printf 'Europe/Prague\n' ;;
        ES) printf 'Europe/Madrid\n' ;;
        IT) printf 'Europe/Rome\n' ;;
        PT) printf 'Europe/Lisbon\n' ;;
        RU) printf 'Europe/Moscow\n' ;;
        TR) printf 'Europe/Istanbul\n' ;;
        AE) printf 'Asia/Dubai\n' ;;
        SA) printf 'Asia/Riyadh\n' ;;
        IL) printf 'Asia/Jerusalem\n' ;;
        ZA) printf 'Africa/Johannesburg\n' ;;
        EG) printf 'Africa/Cairo\n' ;;
        NG) printf 'Africa/Lagos\n' ;;
        AR) printf 'America/Argentina/Buenos_Aires\n' ;;
        CL) printf 'America/Santiago\n' ;;
        *) printf '\n' ;;
    esac
}

valid_timezone_name() {
    local tz="${1:-}" _zf=''
    [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
    for _zf in "/usr/share/zoneinfo/$tz" "/usr/share/zoneinfo/posix/$tz"; do
        if [[ -f "$_zf" ]] && [[ "$(head -c 4 "$_zf" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == '545a6966' ]]; then
            return 0
        fi
    done
    return 1
}

current_timezone_name() {
    local tz
    if command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        [[ -n "$tz" ]] && { printf '%s\n' "$tz"; return 0; }
    fi
    if [[ -L /etc/localtime ]]; then
        tz=$(readlink /etc/localtime 2>/dev/null || true)
        tz=${tz#*/zoneinfo/}
        [[ -n "$tz" ]] && { printf '%s\n' "$tz"; return 0; }
    fi
    if [[ -r /etc/timezone ]]; then
        tr -d '[:space:]' < /etc/timezone
        return 0
    fi
    printf 'UTC\n'
}

snapshot_timezone_state() {
    local dir="$1" cur='' candidate resolved
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" || return 1
    # Only store a symbolic IANA name when it is actually discoverable. Returning
    # a guessed UTC value for an unlabelled localtime file would make rollback
    # overwrite the original zone with UTC instead of restoring the saved file.
    if command -v timedatectl >/dev/null 2>&1; then
        candidate=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        valid_timezone_name "$candidate" && cur="$candidate"
    fi
    if [[ -z "$cur" && -r /etc/timezone ]]; then
        candidate=$(tr -d '[:space:]' < /etc/timezone 2>/dev/null || true)
        valid_timezone_name "$candidate" && cur="$candidate"
    fi
    if [[ -z "$cur" && -L /etc/localtime ]]; then
        resolved=$(readlink -f /etc/localtime 2>/dev/null || true)
        case "$resolved" in
            /usr/share/zoneinfo/*)
                candidate=${resolved#/usr/share/zoneinfo/}
                valid_timezone_name "$candidate" && cur="$candidate"
                ;;
        esac
    fi
    printf '%s\n' "$cur" > "$dir/timezone" || return 1
    if [[ -e /etc/localtime || -L /etc/localtime ]]; then
        cp -a /etc/localtime "$dir/localtime" || return 1
    else
        : > "$dir/localtime.absent" || return 1
    fi
    if [[ -f /etc/timezone ]]; then
        cp -a /etc/timezone "$dir/etc-timezone" || return 1
        # 06c1-M1: a symlinked /etc/timezone stores the link itself
        # above, but an apply writes THROUGH the link and changes the
        # target file's content. Save the target content too, so
        # restore can put it back.
        if [[ -L /etc/timezone ]]; then
            cp -aL /etc/timezone "$dir/etc-timezone-target" || return 1
        fi
    else
        : > "$dir/etc-timezone.absent" || return 1
    fi
    return 0
}

# R14-F12-05: timedatectl presence proves nothing on a host where systemd
# is not PID 1: the binary exists but every call fails. A read-only
# `show` query is the usability probe (the same query
# snapshot_timezone_state already uses to learn the zone name).
timedatectl_usable() {
    command -v timedatectl >/dev/null 2>&1 || return 1
    timedatectl show -p Timezone --value >/dev/null 2>&1
}

restore_timezone_snapshot() {
    local dir="$1" tz
    [[ -d "$dir" && -f "$dir/timezone" ]] || return 1
    tz=$(tr -d '[:space:]' < "$dir/timezone" 2>/dev/null || true)
    # Files first, logical apply last: the old order returned early when
    # the logical apply failed, leaving /etc/localtime and /etc/timezone
    # unrestored even though the snapshot held them.
    # Restore the original filesystem representation as well as the logical
    # zone name. This also covers systems without timedatectl and localtime files
    # that have no discoverable IANA name.
    if [[ -e "$dir/localtime" || -L "$dir/localtime" ]]; then
        rm -f /etc/localtime || return 1
        cp -a "$dir/localtime" /etc/localtime || return 1
    elif [[ -f "$dir/localtime.absent" ]]; then
        rm -f /etc/localtime || return 1
    else
        return 1
    fi
    # R44-M1: -e || -L, not bare -f (same as the localtime
    # site above): a snapshot symlink with a relative target
    # dangles inside the snap dir.
    if [[ -e "$dir/etc-timezone" || -L "$dir/etc-timezone" ]]; then
        rm -f /etc/timezone || return 1
        cp -a "$dir/etc-timezone" /etc/timezone || return 1
        # 06c1-M1: if the snapshot held a symlink, also write the
        # saved target content back THROUGH the link (plain cp
        # follows it), or the apply's write to the target survives.
        if [[ -f "$dir/etc-timezone-target" ]]; then
            cp "$dir/etc-timezone-target" /etc/timezone || return 1
        fi
    elif [[ -f "$dir/etc-timezone.absent" ]]; then
        rm -f /etc/timezone || return 1
    else
        return 1
    fi
    # Only timedatectl may re-apply the zone name: without it the fallback
    # would rewrite /etc/localtime as a symlink and recreate /etc/timezone,
    # destroying the representation restored above.
    # R14-F12-05: "timedatectl exists" does not mean "timedatectl works":
    # on a non-systemd host (container, systemd not PID 1) the binary is
    # present but set-timezone fails, and the old guard still called
    # apply_timezone_name, whose fallback then overwrote the files just
    # restored. Probe usability with a read-only timedatectl query and
    # pass timedatectl-only so a later set failure cannot fall through
    # to the file rewrite either.
    if [[ -n "$tz" ]] && valid_timezone_name "$tz" && timedatectl_usable; then
        apply_timezone_name "$tz" timedatectl-only || return 1
        # R15-F12-02: timedatectl set-timezone always rebuilds
        # /etc/localtime as a symlink, even when the snapshot held a
        # regular file. The apply above still runs (its kernel/RTC
        # side effects are wanted), but the filesystem
        # representation must then be put back: re-copy the snapshot
        # files over whatever set-timezone just wrote. A symlink
        # snapshot needs no repair; a snapshot with no localtime
        # (R16-F12-04) or no /etc/timezone must be deleted again
        # after the apply, or set-timezone recreates what the first
        # restore removed.
        if [[ -e "$dir/localtime" || -L "$dir/localtime" ]] && [[ ! -L "$dir/localtime" ]]; then
            rm -f /etc/localtime || return 1
            cp -a "$dir/localtime" /etc/localtime || return 1
            [[ ! -L /etc/localtime ]] || return 1
        elif [[ -f "$dir/localtime.absent" ]]; then
            # R16-F12-04: the snapshot records no localtime at all,
            # but the apply above rebuilt one: remove it again, or
            # the restored system runs the snapshot zone instead of
            # falling back to UTC as it did before.
            rm -f /etc/localtime || return 1
        fi
        # R44-M1: -e || -L, not bare -f (same as the localtime
        # sites above): a snapshot symlink with a relative target
        # dangles inside the snap dir.
        if [[ -e "$dir/etc-timezone" || -L "$dir/etc-timezone" ]]; then
            rm -f /etc/timezone || return 1
            cp -a "$dir/etc-timezone" /etc/timezone || return 1
            # 06c1-M1: same target-content write-back as the initial
            # restore above: set-timezone just wrote through the
            # link, so the saved target content must be put back.
            if [[ -f "$dir/etc-timezone-target" ]]; then
                cp "$dir/etc-timezone-target" /etc/timezone || return 1
            fi
        elif [[ -f "$dir/etc-timezone.absent" ]]; then
            rm -f /etc/timezone || return 1
        fi
    fi
    return 0
}

apply_timezone_name() {
    local tz="$1" _mode="${2:-}"
    valid_timezone_name "$tz" || return 1
    # R14-F12-05: timedatectl-only mode is for timezone restore, where the
    # files are already correct: a failed set must never fall through to
    # the zoneinfo file rewrite below. Normal callers (menu timezone
    # change) keep the old fallback behaviour.
    if [[ "$_mode" == 'timedatectl-only' ]]; then
        command -v timedatectl >/dev/null 2>&1 || return 1
        timedatectl set-timezone "$tz" 2>/dev/null || return 1
        return 0
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl set-timezone "$tz" 2>/dev/null; then return 0; fi
        # timedatectl exists but cannot set (systemd not PID 1,
        # container, etc.): fall through to zoneinfo below.
    fi
    # Alpine / BusyBox path
    if [[ -f "/usr/share/zoneinfo/$tz" ]]; then
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime || return 1
        # R15-F12-03: a failed /etc/timezone write must fail the
        # apply (the caller rolls back); swallowing it leaves
        # /etc/localtime on the new zone while /etc/timezone still
        # names the old one, and the next snapshot trusts the stale
        # file.
        printf '%s\n' "$tz" > /etc/timezone || return 1
        return 0
    fi
    return 1
}


timezone_list_entries() {
    local zones=''
    if command -v timedatectl >/dev/null 2>&1; then
        zones=$(timedatectl list-timezones 2>/dev/null || true)
        if [[ -n "$zones" ]]; then printf '%s\n' "$zones"; return 0; fi
    fi
    if [[ -d /usr/share/zoneinfo ]]; then
        find /usr/share/zoneinfo \( -type f -o -type l \) 2>/dev/null |
            sed 's#^/usr/share/zoneinfo/##' |
            grep -E '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+.-]+)*$' |
            grep -Ev '^(posix|right|SystemV)/|^(zone|iso3166|tzdata|leap|localtime|posixrules|Factory)$'
    fi
    printf '%s\n' UTC
}

timezone_apply_with_rollback() {
    local target="$1" snap stage
    valid_timezone_name "$target" || {
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}Invalid timezone: $target${NC}" ;;
            ru) msg "${RED}Недопустимый часовой пояс: $target${NC}" ;;
            fa) msg "${RED}منطقه زمانی نامعتبر است: $target${NC}" ;;
            zh-tw) msg "${RED}非法或不存在的時區: $target${NC}" ;;
            ja)
                msg "${RED}無効なタイムゾーン、または存在しないタイムゾーンです: $target${NC}" ;;
            *) msg "${RED}非法或不存在的时区: $target${NC}" ;;
        esac
        return 1
    }
    snap=$(mktemp -d "$ABOX_DIR/.tz-snap.XXXXXX") || return 1
    chmod 700 "$snap" && snapshot_timezone_state "$snap" || {
        rm -rf -- "$snap"
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}Could not save the timezone snapshot; no change was applied.${NC}" ;;
            ru) msg "${RED}Не удалось сохранить снимок часового пояса; изменения не применены.${NC}" ;;
            fa) msg "${RED}ذخیره snapshot منطقه زمانی شکست خورد؛ تغییری اعمال نشد.${NC}" ;;
            zh-tw) msg "${RED}時區快照失敗，未修改設定。${NC}" ;;
            ja)
                msg "${RED}タイムゾーンのスナップショットを保存できませんでした。設定は変更されていません。${NC}" ;;
            *) msg "${RED}时区快照失败，未修改设置。${NC}" ;;
        esac
        return 1
    }
    if ! apply_timezone_name "$target"; then
        if ! restore_timezone_snapshot "$snap"; then
            msg "${RED}Timezone rollback failed; snapshot kept at $snap${NC}"
        else
            rm -rf -- "$snap"
        fi
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}Timezone update failed; rollback was attempted.${NC}" ;;
            ru) msg "${RED}Не удалось изменить часовой пояс; выполнена попытка отката.${NC}" ;;
            fa) msg "${RED}تغییر منطقه زمانی شکست خورد؛ تلاش برای بازگردانی انجام شد.${NC}" ;;
            zh-tw) msg "${RED}時區應用失敗；已嘗試回滾。${NC}" ;;
            ja)
                msg "${RED}タイムゾーンの更新に失敗しました。ロールバックを試みました。${NC}" ;;
            *) msg "${RED}时区应用失败；已尝试回滚。${NC}" ;;
        esac
        return 1
    fi
    stage=$(mktemp -d "$ABOX_DIR/.tz-rollback-new.XXXXXX") || {
        if ! restore_timezone_snapshot "$snap"; then
            msg "${RED}Timezone rollback failed; snapshot kept at $snap${NC}"
        else
            rm -rf -- "$snap"
        fi
        return 1
    }
    cp -a "$snap"/. "$stage"/ || {
        if ! restore_timezone_snapshot "$snap"; then
            msg "${RED}Timezone rollback failed; snapshot kept at $snap${NC}"
        else
            rm -rf -- "$snap" "$stage"
        fi
        return 1
    }
    # M-27 note: this overwrites the previous .tz-rollback, so only a
    # single rollback step is kept by design. Multi-step rollback
    # would need a separate design (retention + selection); out of
    # scope for this batch, recorded as a design limitation.
    # 06c1-M2: the old rollback dir's removal must be checked: if it
    # cannot be deleted, an unchecked mv would nest the new snapshot
    # inside the old directory and report success. Roll back and fail
    # instead; mv -T below is the second line of defence.
    rm -rf -- "$ABOX_DIR/.tz-rollback" || {
        if ! restore_timezone_snapshot "$snap"; then
            msg "${RED}Timezone rollback failed; snapshot kept at $snap${NC}"
        else
            rm -rf -- "$snap" "$stage"
        fi
        return 1
    }
    mv -T -- "$stage" "$ABOX_DIR/.tz-rollback" || {
        if ! restore_timezone_snapshot "$snap"; then
            msg "${RED}Timezone rollback failed; snapshot kept at $snap${NC}"
        else
            rm -rf -- "$snap" "$stage"
        fi
        return 1
    }
    # B-05 fix: timezone state metadata write failure is no longer ignored.
    # The system timezone was already changed at this point, so we warn
    # loudly instead of claiming rollback state is available.
    if ! write_file_atomically_from_stdin "$TZ_STATE_FILE" 600 <<< "applied=$target"; then
        rm -rf -- "$snap"
        msg "${RED}$(tprintf tz_meta_fail "$target")${NC}" >&2
        return 1
    fi
    rm -rf -- "$snap"
    case "${ABOX_LANG:-zh}" in
        en) msg "${GREEN}Timezone set to $target; the previous state is available for rollback.${NC}" ;;
        ru) msg "${GREEN}Часовой пояс установлен: $target; предыдущее состояние можно восстановить.${NC}" ;;
        fa) msg "${GREEN}منطقه زمانی روی $target تنظیم شد؛ امکان بازگردانی وضعیت قبلی وجود دارد.${NC}" ;;
        zh-tw) msg "${GREEN}時區已設定為 ${target}；修改前的狀態可透過回滾選單恢復。${NC}" ;;
        ja)
            msg "${GREEN}タイムゾーンを $target に設定しました。変更前の状態はロールバックメニューから復元できます。${NC}" ;;
        *) msg "${GREEN}时区已设置为 ${target}；修改前的状态可通过回滚菜单恢复。${NC}" ;;
    esac
}
timezone_choose_from_list() {
    local query="${1:-}" page=0 page_size=25 input tz confirm idx first last title page_label number_prompt search_prompt invalid_prompt range_prompt confirm_prompt _formatted_prompt
    local -a all=() filtered=()
    case "${ABOX_LANG:-zh}" in
        en)
            title='IANA time zones'; page_label='Current: %s | Search: %s | Total: %s'; number_prompt='Select number; n/p next/previous; s search; 0 back: '; search_prompt='Search timezone: '; invalid_prompt='Enter a number or n/p/s/0.'; range_prompt='Number out of range.'; confirm_prompt='Set timezone to %s? [Y/N]: ' ;;
        ru)
            title='Часовые пояса IANA'; page_label='Текущий: %s | Поиск: %s | Всего: %s'; number_prompt='Номер; n/p страницы; s поиск; 0 назад: '; search_prompt='Поиск часового пояса: '; invalid_prompt='Введите номер или n/p/s/0.'; range_prompt='Номер вне диапазона.'; confirm_prompt='Установить часовой пояс %s? [Y/N]: ' ;;
        fa)
            title='منطقه‌های زمانی IANA'; page_label='فعلی: %s | جست‌وجو: %s | تعداد: %s'; number_prompt='شماره؛ n/p صفحه؛ s جست‌وجو؛ 0 بازگشت: '; search_prompt='جست‌وجوی منطقه زمانی: '; invalid_prompt='شماره یا n/p/s/0 را وارد کنید.'; range_prompt='شماره خارج از محدوده است.'; confirm_prompt='منطقه زمانی روی %s تنظیم شود؟ [Y/N]: ' ;;
        zh-tw)
            title='IANA 時區列表'; page_label='當前: %s | 搜尋: %s | 共 %s 項'; number_prompt='輸入編號；n/p 翻頁；s 搜尋；0 返回: '; search_prompt='時區關鍵詞: '; invalid_prompt='請輸入編號或 n/p/s/0。'; range_prompt='編號超出範圍。'; confirm_prompt='確認將時區改為 %s？[Y/N]: ' ;;
        ja)
            title='IANA タイムゾーン一覧'; page_label='現在: %s | 検索: %s | 合計: %s'; number_prompt='番号を選択してください。n/p: 次/前のページ、s: 検索、0: 戻る: '; search_prompt='タイムゾーンを検索: '; invalid_prompt='番号、または n/p/s/0 を入力してください。'; range_prompt='番号が範囲外です。'; confirm_prompt='タイムゾーンを %s に変更しますか？[Y/N]: ' ;;
        *)
            title='IANA 时区列表'; page_label='当前: %s | 搜索: %s | 共 %s 项'; number_prompt='输入编号；n/p 翻页；s 搜索；0 返回: '; search_prompt='时区关键词: '; invalid_prompt='请输入编号或 n/p/s/0。'; range_prompt='编号超出范围。'; confirm_prompt='确认将时区改为 %s？[Y/N]: ' ;;
    esac
    mapfile -t all < <(timezone_list_entries | awk 'NF && !seen[$0]++' | LC_ALL=C sort -u)
    for tz in "${all[@]}"; do
        [[ -z "$query" || "${tz,,}" == *"${query,,}"* ]] && filtered+=("$tz")
    done
    (( ${#filtered[@]} > 0 )) || { msg "${YELLOW}$(tr_msg timezone_choose_from_list_no_match)${NC}"; return 1; }
    while true; do
        clear
        msg "${CYAN}================ $title ================${NC}"
        printf "$page_label\n" "$(current_timezone_name)" "${query:-ALL}" "${#filtered[@]}"
        first=$((page*page_size)); last=$((first+page_size)); ((last>${#filtered[@]})) && last=${#filtered[@]}
        for ((idx=first; idx<last; idx++)); do printf '%4d. %s\n' "$((idx+1))" "${filtered[$idx]}"; done
        read -r -p "$number_prompt" input || return 0
        input=$(normalize_fa_ar_digits "${input:-}")
        case "${input,,}" in
            n|next) ((last<${#filtered[@]})) && page=$((page+1)) ;;
            p|prev) ((page>0)) && page=$((page-1)) ;;
            s|search)
                read -r -p "$search_prompt" query || return 0
                page=0; filtered=()
                for tz in "${all[@]}"; do [[ -z "$query" || "${tz,,}" == *"${query,,}"* ]] && filtered+=("$tz"); done
                (( ${#filtered[@]} > 0 )) || msg "${YELLOW}$(tr_msg timezone_choose_from_list_no_match)${NC}"
                ;;
            0|'') return 0 ;;
            *[!0-9]*) msg "${YELLOW}$invalid_prompt${NC}"; sleep 1 ;;
            *)
                valid_decimal_upto "$input" "${#filtered[@]}" || { msg "${YELLOW}$range_prompt${NC}"; sleep 1; continue; }
                input=$((10#$input))
                ((input>=1 && input<=${#filtered[@]})) || { msg "${YELLOW}$range_prompt${NC}"; sleep 1; continue; }
                tz="${filtered[$((input-1))]}"
                printf -v _formatted_prompt "$confirm_prompt" "$tz"
                read -r -p "$_formatted_prompt" confirm
                is_yes "$confirm" || continue
                timezone_apply_with_rollback "$tz"
                pause_return
                return 0
                ;;
        esac
    done
}
timezone_choose_locale() {
    local page=0 page_size=25 first last i value answer title prompt invalid_prompt range_prompt confirm_prompt _formatted_prompt
    local -a locales=()
    case "${ABOX_LANG:-zh}" in
        en) title='Available system locales'; prompt='Enter number; n/p next/previous; 0 back: '; invalid_prompt='Enter a number, n, p or 0.'; range_prompt='Number out of range.'; confirm_prompt='Set system LANG to %s? [Y/N]: ' ;;
        ru) title='Доступные системные локали'; prompt='Номер; n/p страницы; 0 назад: '; invalid_prompt='Введите номер, n, p или 0.'; range_prompt='Номер вне диапазона.'; confirm_prompt='Установить системную локаль LANG=%s? [Y/N]: ' ;;
        fa) title='زبان‌های محلی نصب‌شده'; prompt='شماره؛ n/p صفحه؛ 0 بازگشت: '; invalid_prompt='شماره، n، p یا 0 را وارد کنید.'; range_prompt='شماره خارج از محدوده است.'; confirm_prompt='مقدار LANG سیستم روی %s تنظیم شود؟ [Y/N]: ' ;;
        zh-tw) title='可用系統 Locale'; prompt='輸入編號；n/p 翻頁；0 返回: '; invalid_prompt='請輸入編號、n、p 或 0。'; range_prompt='編號超出範圍。'; confirm_prompt='將系統 LANG 設定為 %s？[Y/N]: ' ;;
        ja)
            title='利用可能なシステム Locale'; prompt='番号を入力してください。n/p: 次/前のページ、0: 戻る: '; invalid_prompt='番号、n、p、または 0 を入力してください。'; range_prompt='番号が範囲外です。'; confirm_prompt='システムの LANG を %s に設定しますか？[Y/N]: ' ;;
        *) title='可用系统 Locale'; prompt='输入编号；n/p 翻页；0 返回: '; invalid_prompt='请输入编号、n、p 或 0。'; range_prompt='编号超出范围。'; confirm_prompt='将系统 LANG 设置为 %s？[Y/N]: ' ;;
    esac
    if command -v localectl >/dev/null 2>&1; then
        mapfile -t locales < <(localectl list-locales 2>/dev/null | awk 'NF && !seen[$0]++' | LC_ALL=C sort -u)
    fi
    if (( ${#locales[@]} == 0 )); then
        mapfile -t locales < <(locale -a 2>/dev/null | awk 'NF && !seen[$0]++' | LC_ALL=C sort -u)
    fi
    (( ${#locales[@]} > 0 )) || { msg "${YELLOW}No installed locales were found; install or generate a locale first.${NC}"; pause_return; return 1; }
    while true; do
        clear
        msg "${CYAN}================ $title ================${NC}"
        first=$((page*page_size)); last=$((first+page_size)); ((last>${#locales[@]})) && last=${#locales[@]}
        for ((i=first; i<last; i++)); do printf '%4d. %s\n' "$((i+1))" "${locales[$i]}"; done
        read -r -p "$prompt" value || return 0
        value=$(normalize_fa_ar_digits "${value:-}")
        case "${value,,}" in
            n|next) ((last<${#locales[@]})) && page=$((page+1)) ;;
            p|prev) ((page>0)) && page=$((page-1)) ;;
            0|'') return 0 ;;
            *[!0-9]*) msg "${YELLOW}$invalid_prompt${NC}"; sleep 1 ;;
            *)
                valid_decimal_upto "$value" "${#locales[@]}" || { msg "${YELLOW}$range_prompt${NC}"; sleep 1; continue; }
                value=$((10#$value))
                ((value>=1 && value<=${#locales[@]})) || { msg "${YELLOW}$range_prompt${NC}"; sleep 1; continue; }
                value="${locales[$((value-1))]}"
                printf -v _formatted_prompt "$confirm_prompt" "$value"
                read -r -p "$_formatted_prompt" answer
                is_yes "$answer" || continue
                # localectl may exist yet fail (e.g. non-systemd): fall
                # back to update-locale instead of failing outright.
                _locale_done=0
                if command -v localectl >/dev/null 2>&1; then
                    localectl set-locale "LANG=$value" && _locale_done=1
                fi
                if (( _locale_done == 0 )) && command -v update-locale >/dev/null 2>&1; then
                    update-locale "LANG=$value" && _locale_done=1
                fi
                if (( _locale_done == 0 )); then
                    if command -v localectl >/dev/null 2>&1 || command -v update-locale >/dev/null 2>&1; then
                        msg "${RED}Locale update failed.${NC}"
                    else
                        msg "${RED}Neither localectl nor update-locale is available; no locale was changed.${NC}"
                    fi
                    pause_return; return 1
                fi
                msg "${GREEN}Locale updated. Some running services may need a restart.${NC}"
                pause_return
                return 0
                ;;
        esac
    done
}
timezone_locale_ntp_menu() {
    clear
    local c ntp synced now prompt back_word ntp_ok ntp_fail ntp_none rb_ok rb_fail rb_none
    now=$(date '+%Y-%m-%d %H:%M:%S %Z (%z)' 2>/dev/null || date)
    ntp='unknown'; synced='unknown'
    if command -v timedatectl >/dev/null 2>&1; then
        ntp=$(timedatectl show -p NTP --value 2>/dev/null || printf unknown)
        synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf unknown)
    fi
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}Time, timezone and locale${NC}"
            msg "Current time: $now | timezone: $(current_timezone_name) | NTP: $ntp | synced: $synced"
            msg "${CYAN}1.${NC} Browse all time zones by number"
            msg "${CYAN}2.${NC} Search a time zone and select by number"
            msg "${CYAN}3.${NC} Select an installed system locale"
            msg "${CYAN}4.${NC} Enable NTP time synchronization"
            msg "${CYAN}5.${NC} Restore the previous timezone"
            ;;
        ru)
            msg "${BOLD}${GREEN}Время, часовой пояс и локаль${NC}"
            msg "Сейчас: $now | часовой пояс: $(current_timezone_name) | NTP: $ntp | синхронизация: $synced"
            msg "${CYAN}1.${NC} Все часовые пояса по номерам"
            msg "${CYAN}2.${NC} Поиск часового пояса"
            msg "${CYAN}3.${NC} Выбрать установленную локаль"
            msg "${CYAN}4.${NC} Включить синхронизацию времени NTP"
            msg "${CYAN}5.${NC} Восстановить предыдущий часовой пояс"
            ;;
        fa)
            msg "${BOLD}${GREEN}زمان، منطقه زمانی و locale${NC}"
            msg "اکنون: $now | منطقه زمانی: $(current_timezone_name) | NTP: $ntp | همگام‌سازی: $synced"
            msg "${CYAN}1.${NC} نمایش همه مناطق زمانی با شماره"
            msg "${CYAN}2.${NC} جست‌وجو و انتخاب منطقه زمانی"
            msg "${CYAN}3.${NC} انتخاب locale نصب‌شده"
            msg "${CYAN}4.${NC} فعال‌کردن همگام‌سازی زمان NTP"
            msg "${CYAN}5.${NC} بازگردانی منطقه زمانی قبلی"
            ;;
        zh-tw)
            msg "${BOLD}${GREEN}時間、時區與地區${NC}"
            msg "當前時間: $now | 時區: $(current_timezone_name) | NTP: $ntp | 已同步: $synced"
            msg "${CYAN}1.${NC} 檢視全部時區並按編號選擇"
            msg "${CYAN}2.${NC} 搜尋時區後按編號選擇"
            msg "${CYAN}3.${NC} 選擇已安裝的系統 Locale"
            msg "${CYAN}4.${NC} 啟用 NTP 自動時間同步"
            msg "${CYAN}5.${NC} 回滾到時區修改前快照"
            ;;
        ja)
            msg "${BOLD}${GREEN}時刻、タイムゾーン、Locale${NC}"
            msg "現在の時刻: $now | タイムゾーン: $(current_timezone_name) | NTP: $ntp | 同期済み: $synced"
            msg "${CYAN}1.${NC} すべてのタイムゾーンを一覧表示し、番号で選択"
            msg "${CYAN}2.${NC} タイムゾーンを検索して番号で選択"
            msg "${CYAN}3.${NC} インストール済みのシステム Locale を選択"
            msg "${CYAN}4.${NC} NTP による時刻の自動同期を有効化"
            msg "${CYAN}5.${NC} タイムゾーン変更前のスナップショットにロールバック"
            ;;
        *)
            msg "${BOLD}${GREEN}时间、时区与地区${NC}"
            msg "当前时间: $now | 时区: $(current_timezone_name) | NTP: $ntp | 已同步: $synced"
            msg "${CYAN}1.${NC} 查看全部时区并按编号选择"
            msg "${CYAN}2.${NC} 搜索时区后按编号选择"
            msg "${CYAN}3.${NC} 选择已安装的系统 Locale"
            msg "${CYAN}4.${NC} 启用 NTP 自动时间同步"
            msg "${CYAN}5.${NC} 回滚到时区修改前快照"
            ;;
    esac
    case "${ABOX_LANG:-zh}" in en) back_word='Back' ;; ru) back_word='Назад' ;; fa) back_word='بازگشت' ;; zh-tw) back_word='返回' ;; ja) back_word='戻る' ;; *) back_word='返回' ;; esac
    msg "${CYAN}0.${NC} $back_word"
    case "${ABOX_LANG:-zh}" in en) prompt='Select [0-5]: ' ;; ru) prompt='Выберите [0–5]: ' ;; fa) prompt='انتخاب [۰ تا ۵]: ' ;; ja) prompt='選択してください [0-5]: ' ;; zh-tw) prompt='請選擇 [0-5]：' ;; *) prompt='请选择 [0-5]：' ;; esac
    read -r -p "$prompt" c
    c=$(normalize_fa_ar_digits "${c:-}")
    case "$c" in
        1) timezone_choose_from_list '' ;;
        2) local query search_prompt; case "${ABOX_LANG:-zh}" in en) search_prompt='Timezone search: ' ;; ru) search_prompt='Поиск часового пояса: ' ;; fa) search_prompt='جست‌وجوی منطقه زمانی: ' ;; zh-tw) search_prompt='時區關鍵詞: ' ;; ja) search_prompt='タイムゾーンを検索: ' ;; *) search_prompt='时区关键词: ' ;; esac; read -r -p "$search_prompt" query || return 0; timezone_choose_from_list "$query" ;;
        3) timezone_choose_locale ;;
        4)
            case "${ABOX_LANG:-zh}" in
                en) ntp_ok='NTP enable requested; check the sync status.'; ntp_fail='Failed to enable NTP; check the time sync service.'; ntp_none='This system has no timedatectl; use the chrony/openntpd method for your distro.' ;;
                ru) ntp_ok='Включение NTP запрошено; проверьте состояние синхронизации.'; ntp_fail='Не удалось включить NTP; проверьте службу синхронизации времени.'; ntp_none='В системе нет timedatectl; используйте способ chrony/openntpd для вашего дистрибутива.' ;;
                fa) ntp_ok='فعال‌سازی NTP درخواست شد؛ وضعیت همگام‌سازی را بررسی کنید.'; ntp_fail='فعال‌سازی NTP ناموفق بود؛ سرویس همگام‌سازی زمان را بررسی کنید.'; ntp_none='این سیستم timedatectl ندارد؛ از روش chrony/openntpd توزیع خود استفاده کنید.' ;;
                zh-tw) ntp_ok='已請求啟用 NTP；請檢查同步狀態。'; ntp_fail='啟用 NTP 失敗，請檢查時間同步服務。'; ntp_none='目前系統沒有 timedatectl；請使用發行版對應的 chrony/openntpd 管理方式。' ;;
                ja) ntp_ok='NTP の有効化を要求しました。同期状態を確認してください。'; ntp_fail='NTP の有効化に失敗しました。時刻同期サービスを確認してください。'; ntp_none='このシステムには timedatectl がありません。ディストリビューションに応じた chrony/openntpd の管理方法を使ってください。' ;;
                *) ntp_ok='已请求启用 NTP；请检查同步状态。'; ntp_fail='启用 NTP 失败，请检查时间同步服务。'; ntp_none='当前系统没有 timedatectl；请使用发行版对应的 chrony/openntpd 管理方式。' ;;
            esac
            if command -v timedatectl >/dev/null 2>&1; then
                if timedatectl set-ntp true; then msg "${GREEN}$ntp_ok${NC}"; else msg "${RED}$ntp_fail${NC}"; fi
            else
                msg "${YELLOW}$ntp_none${NC}"
            fi
            pause_return
            ;;
        5)
            case "${ABOX_LANG:-zh}" in
                en) rb_ok='Previous timezone restored.'; rb_fail='Timezone rollback failed.'; rb_none='No timezone rollback snapshot available.' ;;
                ru) rb_ok='Предыдущий часовой пояс восстановлен.'; rb_fail='Откат часового пояса не удался.'; rb_none='Снимок для отката часового пояса отсутствует.' ;;
                fa) rb_ok='منطقه زمانی قبلی بازیابی شد.'; rb_fail='بازگشت منطقه زمانی ناموفق بود.'; rb_none='اسنپ‌شات فوری برای بازگشت منطقه زمانی موجود نیست.' ;;
                zh-tw) rb_ok='已恢復修改前時區。'; rb_fail='時區回滾失敗。'; rb_none='沒有可用的時區回滾快照。' ;;
                ja) rb_ok='変更前のタイムゾーンを復元しました。'; rb_fail='タイムゾーンのロールバックに失敗しました。'; rb_none='利用可能なタイムゾーンのロールバック用スナップショットがありません。' ;;
                *) rb_ok='已恢复修改前时区。'; rb_fail='时区回滚失败。'; rb_none='没有可用的时区回滚快照。' ;;
            esac
            if [[ -d "$ABOX_DIR/.tz-rollback" ]]; then
                if restore_timezone_snapshot "$ABOX_DIR/.tz-rollback"; then msg "${GREEN}$rb_ok${NC}"; else msg "${RED}$rb_fail${NC}"; fi
            else
                msg "${YELLOW}$rb_none${NC}"
            fi
            pause_return
            ;;
        *) return 0 ;;
    esac
}

timezone_menu() { timezone_locale_ntp_menu; }
dns_backend_detect() {
    local _rc="${1:-/etc/resolv.conf}" _link=''
    _link=$(readlink -f "$_rc" 2>/dev/null || true)
    # systemd-resolved only counts when queries really flow through
    # it: the stub file (NOT the upstream-list file
    # /run/systemd/resolve/resolv.conf, which glibc reads directly
    # and which bypasses resolved DoT), or a resolv.conf whose every
    # nameserver is a 127.0.0.53 / 127.0.0.54 stub entry (.54 is
    # systemd 253+'s proxy stub). Any direct (non-stub) nameserver
    # means glibc can query it first, so the file is not resolved.
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null \
        && { [[ "$_link" == */stub-resolv.conf ]] \
             || LC_ALL=C awk '{ sub(/^[[:space:]]+/, ""); if ($1 != "nameserver") next; seen=1; addr=$2; sub(/\r$/, "", addr); if (addr != "127.0.0.53" && addr != "127.0.0.54") bad=1 } END { exit ((seen && !bad) ? 0 : 1) }' "$_rc" 2>/dev/null; }; then
        printf 'resolved\n'
    elif command -v nmcli >/dev/null 2>&1 && nmcli general status >/dev/null 2>&1 \
        && { [[ "$(readlink "$_rc" 2>/dev/null)" == *NetworkManager* ]] \
             || grep -q 'Generated by NetworkManager' "$_rc" 2>/dev/null; }; then
        printf 'networkmanager\n'
    else
        printf 'resolvconf\n'
    fi
}

systemd_major_version() {
    local version
    version=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
    [[ "$version" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$version"
}

snapshot_dns_state() {
    local dir="$1" backend iface connection key value _ens _link_target='' _dnscrypt_dir_mode=''
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" || return 1
    backend=$(dns_backend_detect) || return 1
    printf '%s\n' "$backend" > "$dir/backend" || return 1
    if command -v lsattr >/dev/null 2>&1 && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then printf '1\n' > "$dir/resolv-immutable"; else printf '0\n' > "$dir/resolv-immutable"; fi
    if [[ -f /etc/resolv.conf || -L /etc/resolv.conf ]]; then cp -a /etc/resolv.conf "$dir/resolv.conf" || return 1; else printf absent > "$dir/resolv.conf.absent"; fi
    if [[ -f /etc/systemd/resolved.conf ]]; then cp -a /etc/systemd/resolved.conf "$dir/resolved.conf" || return 1; else printf absent > "$dir/resolved.conf.absent"; fi
    if [[ -f /etc/systemd/resolved.conf.d/99-abox-dns.conf ]]; then
        mkdir -p "$dir/resolved.conf.d" || return 1
        cp -a /etc/systemd/resolved.conf.d/99-abox-dns.conf "$dir/resolved.conf.d/99-abox-dns.conf" || return 1
    fi
    # R11-06: capture the OTHER DNS-bearing drop-ins into this
    # snapshot's resolved-cleanup/ (the layout
    # restore_dns_snapshot_body already restores). The strip helper
    # only backs them up to the baseline dir, so without this a
    # rollback from the current snapshot cannot put them back.
    local _df='' _dbase='' _dsub='' _grc=0
    for _df in /etc/systemd/resolved.conf.d/*.conf /run/systemd/resolved.conf.d/*.conf /usr/lib/systemd/resolved.conf.d/*.conf /usr/local/lib/systemd/resolved.conf.d/*.conf; do
        [[ -f "$_df" ]] || continue
        [[ "$_df" == /etc/systemd/resolved.conf.d/99-abox-dns.conf ]] && continue
        [[ -L "$_df" ]] && continue
        [[ -r "$_df" ]] || return 1
        _grc=0
        grep -qiE '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)[[:space:]]*=' "$_df" 2>/dev/null || _grc=$?
        (( _grc == 2 )) && return 1
        (( _grc != 0 )) && continue
        _dbase=$(basename "$_df")
        case "$_df" in
            /etc/systemd/resolved.conf.d/*) _dsub='etc' ;;
            /run/systemd/resolved.conf.d/*) _dsub='run' ;;
            /usr/lib/systemd/resolved.conf.d/*) _dsub='usr-lib' ;;
            /usr/local/lib/systemd/resolved.conf.d/*) _dsub='usr-local-lib' ;;
            *) continue ;;
        esac
        mkdir -p "$dir/resolved-cleanup/$_dsub" || return 1
        cp -a "$_df" "$dir/resolved-cleanup/$_dsub/$_dbase" || return 1
    done
    if [[ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]]; then
        mkdir -p "$dir/dnscrypt-proxy" || return 1
        cp -a /etc/dnscrypt-proxy/dnscrypt-proxy.toml "$dir/dnscrypt-proxy/dnscrypt-proxy.toml" || return 1
        # R44-M2: a symlinked toml stores the link itself above, but
        # its relative target is not in the snapshot dir, so the
        # snapshot link dangles and restore skips it. Save the
        # target content too (same idiom as the timezone -target).
        if [[ -L /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]]; then
            cp -aL /etc/dnscrypt-proxy/dnscrypt-proxy.toml "$dir/dnscrypt-proxy/dnscrypt-proxy.toml-target" || return 1
        fi
        # R16-F12-03: record the config directory's mode as well as
        # the file: rollback must restore the directory it found, not
        # force it to 0755 (GNU install -d -m re-modes an existing
        # directory). An unreadable mode fails the snapshot.
        _dnscrypt_dir_mode=$(stat -c %a /etc/dnscrypt-proxy 2>/dev/null || true)
        [[ "$_dnscrypt_dir_mode" =~ ^0?[0-7]{3,4}$ ]] || return 1
        printf '%s\n' "$_dnscrypt_dir_mode" > "$dir/dnscrypt-proxy-dir-mode" || return 1
        printf present > "$dir/dnscrypt-config-state"
    else printf absent > "$dir/dnscrypt-config-state"; fi
    # M-21(1)/M-09: the socket drop-in and the socket's Listen list are
    # part of the DNS state. Without them a rollback cannot put back a
    # removed abox-listen.conf, and a switch-out cannot tell what the
    # socket listened on before A-Box.
    local _abox_listen='/etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf'
    local _sock_listen=''
    if [[ -f "$_abox_listen" && ! -L "$_abox_listen" ]]; then
        [[ -r "$_abox_listen" ]] || return 1
        mkdir -p "$dir/dnscrypt-socket" || return 1
        cp -a "$_abox_listen" "$dir/dnscrypt-socket/abox-listen.conf" || return 1
        printf present > "$dir/dnscrypt-socket-state" || return 1
    elif [[ ! -e "$_abox_listen" && ! -L "$_abox_listen" ]]; then
        printf absent > "$dir/dnscrypt-socket-state" || return 1
    else
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        _sock_listen=$(systemctl show --property=Listen --value dnscrypt-proxy.socket 2>/dev/null || true)
        printf '%s\n' "$_sock_listen" > "$dir/dnscrypt-socket-listen" || return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then printf active > "$dir/dnscrypt-service-state"; else printf inactive > "$dir/dnscrypt-service-state"; fi
    if command -v systemctl >/dev/null 2>&1; then
        _ens=$(systemctl is-enabled dnscrypt-proxy 2>/dev/null || true)
        printf '%s\n' "${_ens:-disabled}" > "$dir/dnscrypt-service-enabled" || return 1
        # R15-F12-04: a `linked` enablement is a symlink created by
        # `systemctl link`; record its target now, while it still
        # exists, so rollback can re-create it. Without the target
        # the restore cannot tell `linked` from `disabled`.
        if [[ "$_ens" == linked ]]; then
            # R28-NF-08: record the REAL target of the link, not
            # FragmentPath: for a linked unit FragmentPath is the
            # symlink itself (/etc/systemd/system/...) and `systemctl
            # link` on it fails once the restore-side disable has
            # deleted the link. readlink -f canonicalises (also for
            # a relative link target); fall back to the raw readlink
            # and absolutise it against the link's directory.
            _link_target=$(readlink -f /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null || true)
            [[ -n "$_link_target" ]] || _link_target=$(readlink /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null || true)
            case "$_link_target" in
                /*) ;;
                ?*) _link_target="/etc/systemd/system/$_link_target" ;;
            esac
            if [[ -n "$_link_target" ]]; then
                printf '%s\n' "$_link_target" > "$dir/dnscrypt-service-link-target" || return 1
            fi
        fi
    else printf disabled > "$dir/dnscrypt-service-enabled" || return 1; fi
    # 06d-H1: record whether dnscrypt-proxy.socket is in play at
    # baseline (enabled or active). dns_disable_doh must not stop a
    # socket-activated foreign proxy whose service is inactive/
    # disabled; without this record the decision can only see the
    # service state. Same exit-code predicate as the socket-in-play
    # checks elsewhere in this file.
    if command -v systemctl >/dev/null 2>&1 && { systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; }; then
        printf yes > "$dir/dnscrypt-socket-inplay" || return 1
    else
        printf no > "$dir/dnscrypt-socket-inplay" || return 1
    fi
    # M-09: record dnscrypt-proxy.socket Listen endpoints and the
    # A-Box socket drop-in. dns_enable_doh snapshots BEFORE normalize
    # rebinds the socket; without these, a rollback restores the
    # service state but leaves the rebound socket and a stale
    # abox-listen.conf behind. Old snapshots without these records
    # are skipped by the restore below.
    local _sock_listen=''
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --type=socket --no-legend --no-pager dnscrypt-proxy.socket 2>/dev/null | grep -q '^dnscrypt-proxy\.socket'; then
        _sock_listen=$(systemctl show --property=Listen --value dnscrypt-proxy.socket 2>/dev/null) || return 1
        printf '%s\n' "$_sock_listen" > "$dir/dnscrypt-socket-listen" || return 1
    else
        printf absent > "$dir/dnscrypt-socket-listen.absent" || return 1
    fi
    # S4 (R44-M2 follow-up): refuse a symlinked live drop-in here too.
    # The dnscrypt-socket branch above already fails closed on the same
    # path, so this is defense-in-depth (a future reorder cannot reopen
    # it): cp -a would otherwise store the link itself in the snapshot
    # and the restore below would put a live symlink back.
    if [[ -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf && ! -L /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf ]]; then
        mkdir -p "$dir/dnscrypt-socket-dropin" || return 1
        cp -a /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf "$dir/dnscrypt-socket-dropin/abox-listen.conf" || return 1
        printf present > "$dir/dnscrypt-socket-dropin-state" || return 1
    elif [[ ! -e /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf && ! -L /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf ]]; then
        printf absent > "$dir/dnscrypt-socket-dropin-state" || return 1
    else
        return 1
    fi
    if [[ -f "$DNS_STATE_FILE" && ! -L "$DNS_STATE_FILE" ]]; then cp -a "$DNS_STATE_FILE" "$dir/dns-state" || return 1; else printf absent > "$dir/dns-state.absent"; fi
    if [[ "$backend" == networkmanager ]] && command -v nmcli >/dev/null 2>&1; then
        iface=$(nm_effective_device 2>/dev/null || true)
        [[ -n "$iface" ]] || return 1
        connection=$(nmcli --escape no -g GENERAL.CONNECTION device show "$iface" 2>/dev/null) || return 1
        [[ -n "$connection" && "$connection" != '--' ]] || return 1
        printf '%s\n' "$connection" > "$dir/nm-connection" || return 1
        for key in ipv4.ignore-auto-dns ipv4.dns ipv6.ignore-auto-dns ipv6.dns; do
            value=$(nmcli --escape no -g "$key" connection show "$connection" 2>/dev/null) || return 1
            value=${value%%$'\n'*}
            printf '%s\n' "$value" > "$dir/nm-${key//./-}" || return 1
        done
    fi
    printf ok > "$dir/COMPLETE" || return 1
}
# Reapply an NM connection on the device it is actually bound to
# (not the first connected device); a failed reapply propagates and
# the snapshot is preserved by the caller. An inactive connection
# (no device) needs no reapply: stored settings apply on activation.
nm_reapply_connection() {
    local connection="$1" out='' iface=''
    out=$(nmcli -g GENERAL.DEVICES connection show "$connection" 2>/dev/null) || return 1
    iface=$(printf '%s\n' "$out" | head -1)
    if [[ -z "$iface" || "$iface" == '--' ]]; then return 0; fi
    nmcli device reapply "$iface" >/dev/null 2>&1 || return 1
    return 0
}

restore_dns_snapshot_body() {
    local dir="$1" backend state key value connection iface dnscrypt_state _dnscrypt_dir_mode=''
    [[ -f "$dir/COMPLETE" ]] || return 1
    # M-26(2): in a non-systemd container systemctl exists but there is
    # no bus/PID 1. disable/is-enabled/list-unit-files are offline
    # operations and succeed there, so they must NOT be treated as the
    # failure point; the fatal steps are restart/stop/is-active. Only
    # the file-level rollback (resolv.conf, drop-ins, symlinks, state
    # files) runs when systemd is unavailable.
    local _dns_no_systemd=0
    systemd_available 2>/dev/null || _dns_no_systemd=1
    backend=$(tr -d '[:space:]' < "$dir/backend" 2>/dev/null || true)
    if [[ -e "$dir/resolv.conf" || -L "$dir/resolv.conf" ]]; then
        # FIX: cp -a follows a symlink at the destination and would overwrite
        # its TARGET (e.g. systemd-resolved stub target), reporting success
        # while the snapshot is never applied. Remove destination first
        # (mirrors restore_timezone_snapshot's rm -f /etc/localtime), so a
        # symlinked snapshot can replace a regular file and vice versa.
        # R11C12-01: a bind-mounted resolv.conf cannot be unlinked
        # (rm fails EBUSY); restore its content in place instead
        # of aborting the whole rollback (which would leave
        # resolved.conf, drop-ins and service states unrestored).
        if ! rm -f /etc/resolv.conf 2>/dev/null; then
            if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf && -f "$dir/resolv.conf" && ! -L "$dir/resolv.conf" ]]; then
                cat "$dir/resolv.conf" > /etc/resolv.conf || return 1
            else
                return 1
            fi
        else
            cp -a "$dir/resolv.conf" /etc/resolv.conf || return 1
        fi
    elif [[ -f "$dir/resolv.conf.absent" ]]; then rm -f /etc/resolv.conf || return 1; fi
    if [[ -f "$dir/resolved.conf" ]]; then rm -f /etc/systemd/resolved.conf || return 1; cp -a "$dir/resolved.conf" /etc/systemd/resolved.conf || return 1
    elif [[ -f "$dir/resolved.conf.absent" ]]; then rm -f /etc/systemd/resolved.conf || return 1; fi
    if [[ -f "$dir/resolved.conf.d/99-abox-dns.conf" ]]; then
        install -d -m 755 /etc/systemd/resolved.conf.d || return 1
        rm -f /etc/systemd/resolved.conf.d/99-abox-dns.conf || return 1
        cp -a "$dir/resolved.conf.d/99-abox-dns.conf" /etc/systemd/resolved.conf.d/99-abox-dns.conf || return 1
    else
        rm -f /etc/systemd/resolved.conf.d/99-abox-dns.conf 2>/dev/null || true
    fi
    if [[ -d "$dir/resolved-cleanup" ]]; then
        local _cf=''
        for _cf in "$dir"/resolved-cleanup/*.conf; do
            [[ -f "$_cf" ]] || continue
            rm -f -- "/etc/systemd/resolved.conf.d/$(basename "$_cf")" || return 1
            cp -a "$_cf" "/etc/systemd/resolved.conf.d/$(basename "$_cf")" || return 1
        done
        local _sub='' _dir=''
        for _sub in etc run usr-lib usr-local-lib; do
            case "$_sub" in
                etc) _dir='/etc/systemd/resolved.conf.d' ;;
                run) _dir='/run/systemd/resolved.conf.d' ;;
                usr-lib) _dir='/usr/lib/systemd/resolved.conf.d' ;;
                usr-local-lib) _dir='/usr/local/lib/systemd/resolved.conf.d' ;;
            esac
            install -d -m 755 "$_dir" 2>/dev/null || true
            for _cf in "$dir"/resolved-cleanup/"$_sub"/*.conf; do
                [[ -f "$_cf" ]] || continue
                rm -f -- "$_dir/$(basename "$_cf")" || return 1
                cp -a "$_cf" "$_dir/$(basename "$_cf")" || return 1
            done
        done
    fi
    dnscrypt_state=$(tr -d '[:space:]' < "$dir/dnscrypt-config-state" 2>/dev/null || true)
    if [[ "$dnscrypt_state" == present && ( -e "$dir/dnscrypt-proxy/dnscrypt-proxy.toml" || -L "$dir/dnscrypt-proxy/dnscrypt-proxy.toml" ) ]]; then
        # R16-F12-03: never force the directory to 0755: restore the
        # mode the snapshot recorded, and leave an existing directory
        # alone when the snapshot predates the mode record. A missing
        # directory is recreated with the recorded mode, else the
        # legacy 0755. A present-but-malformed mode record fails
        # closed instead of guessing.
        if [[ -f "$dir/dnscrypt-proxy-dir-mode" ]]; then
            _dnscrypt_dir_mode=$(tr -d '[:space:]' < "$dir/dnscrypt-proxy-dir-mode" 2>/dev/null || true)
            [[ "$_dnscrypt_dir_mode" =~ ^0?[0-7]{3,4}$ ]] || return 1
            if [[ -d /etc/dnscrypt-proxy ]]; then
                chmod "$_dnscrypt_dir_mode" /etc/dnscrypt-proxy || return 1
            else
                install -d -m "$_dnscrypt_dir_mode" /etc/dnscrypt-proxy || return 1
            fi
        elif [[ ! -d /etc/dnscrypt-proxy ]]; then
            install -d -m 755 /etc/dnscrypt-proxy || return 1
        fi
        rm -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml || return 1
        cp -a "$dir/dnscrypt-proxy/dnscrypt-proxy.toml" /etc/dnscrypt-proxy/dnscrypt-proxy.toml || return 1
        # R44-M2: write the saved target content back through the
        # restored link (plain cp follows it); a bare link alone
        # restores a dangling pointer.
        if [[ -f "$dir/dnscrypt-proxy/dnscrypt-proxy.toml-target" ]]; then
            cp "$dir/dnscrypt-proxy/dnscrypt-proxy.toml-target" /etc/dnscrypt-proxy/dnscrypt-proxy.toml || return 1
        fi
    elif [[ "$dnscrypt_state" == absent ]]; then
        rm -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml || return 1
    elif [[ "$dnscrypt_state" == present ]]; then
        # R44-M2: present but unrestorable (snapshot toml missing
        # entirely) must fail loudly, not silently skip the config.
        return 1
    fi
    # M-21(1)/M-09: restore the socket drop-in the snapshot recorded.
    # A snapshot that predates this record leaves a live drop-in
    # alone (no state file = no knowledge, not "absent").
    if [[ -f "$dir/dnscrypt-socket-state" ]]; then
        local _abox_listen='/etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf'
        local _listen_state='' _socket_changed=0
        _listen_state=$(tr -d '[:space:]' < "$dir/dnscrypt-socket-state" 2>/dev/null || true)
        if [[ "$_listen_state" == present && -f "$dir/dnscrypt-socket/abox-listen.conf" ]]; then
            # S4 (R44-M2 follow-up): a symlinked snapshot entry must fail
            # closed, not be restored as a live symlink (cp -a preserves
            # the link); the dnscrypt toml got the same treatment in R44-M2.
            [[ ! -L "$dir/dnscrypt-socket/abox-listen.conf" ]] || return 1
            mkdir -p /etc/systemd/system/dnscrypt-proxy.socket.d || return 1
            if [[ ! -f "$_abox_listen" ]] || ! cmp -s "$dir/dnscrypt-socket/abox-listen.conf" "$_abox_listen" 2>/dev/null; then
                _socket_changed=1
            fi
            rm -f -- "$_abox_listen" || return 1
            cp -a "$dir/dnscrypt-socket/abox-listen.conf" "$_abox_listen" || return 1
            [[ -f "$_abox_listen" && ! -L "$_abox_listen" ]] || return 1
        elif [[ "$_listen_state" == absent ]]; then
            if [[ -f "$_abox_listen" ]]; then
                # 06c2-02: same marker gate as the dropin-state restore
                # below: a foreign admin drop-in created after the
                # snapshot must never be deleted. Only a drop-in
                # carrying the A-Box marker may go; an unmarked one
                # fails closed instead of being silently removed (the
                # second set's protection never fires once this branch
                # has already deleted the file).
                grep -Fq '# Managed by A-Box' "$_abox_listen" 2>/dev/null || return 1
                _socket_changed=1
                rm -f -- "$_abox_listen" 2>/dev/null || true
                rmdir /etc/systemd/system/dnscrypt-proxy.socket.d 2>/dev/null || true
            fi
        else
            return 1
        fi
        # Only bounce the socket when the drop-in actually changed, and
        # only when the socket unit is enabled or active: restarting an
        # inactive socket would start listening on the packaged
        # endpoints (and socket-activate the service on first query).
        # 06c2-01: same _dns_no_systemd gate as the resolved restart
        # and service-state blocks below: on a host without a bus,
        # list-unit-files succeeds offline but daemon-reload fails
        # and would truncate the rest of the restore.
        if (( _socket_changed == 1 )) && (( _dns_no_systemd == 0 )) && command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
                systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || true
            fi
        fi
    fi
    # M-26 (follow-up N3): no _dns_no_systemd gate here -- nmcli needs
    # no systemd bus, and the application path uses nmcli on non-systemd
    # hosts too. The systemctl gate stays only on steps that truly need
    # the bus (resolved restart / socket reload below).
    if [[ "$backend" == networkmanager && -f "$dir/nm-connection" ]] && command -v nmcli >/dev/null 2>&1; then
        connection=$(cat "$dir/nm-connection")
        for key in ipv4.ignore-auto-dns ipv4.dns ipv6.ignore-auto-dns ipv6.dns; do
            value=$(cat "$dir/nm-${key//./-}" 2>/dev/null || true)
            [[ "$value" == '--' ]] && value=''
            nmcli connection modify "$connection" "$key" "$value" || return 1
        done
        nm_reapply_connection "$connection" || return 1
    fi
    if [[ -f "$dir/dns-state" ]]; then rm -f -- "$DNS_STATE_FILE" || return 1; cp -a "$dir/dns-state" "$DNS_STATE_FILE" || return 1
    elif [[ -f "$dir/dns-state.absent" ]]; then rm -f "$DNS_STATE_FILE" || return 1; fi
    # H-25(3b): a failed socket-drop-in rollback step must not report
    # success: record it here and fail at the end of the function
    # instead of swallowing it with "|| true".
    local _abox_listen_rollback_failed=0
    # H-25(3): the snapshot never recorded the A-Box socket drop-in
    # (abox-listen.conf), so a restore left 127.0.0.1:5353 bound after
    # the rollback. Remove it and rebind the socket to the distro
    # default -- unless the snapshot itself is a DoH-active state
    # (mode=doh), in which case the drop-in belongs to the restored
    # state and must stay. Only a drop-in carrying the A-Box marker
    # is ever removed; a foreign admin override is left alone.
    if [[ ! -f "$dir/dns-state" ]] || ! grep -qE '(^|;)[ \t]*mode=doh([; \t]|$)' "$dir/dns-state" 2>/dev/null; then
        if [[ -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf ]] && grep -Fxq '# Managed by A-Box' /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf 2>/dev/null; then
            rm -f -- /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf 2>/dev/null || { msg "${YELLOW}[!] Failed to remove A-Box DNS socket drop-in abox-listen.conf; DNS rollback incomplete.${NC}" >&2; _abox_listen_rollback_failed=1; }
            rmdir /etc/systemd/system/dnscrypt-proxy.socket.d 2>/dev/null || true
            if (( _dns_no_systemd == 0 )) && command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload >/dev/null 2>&1 || { msg "${YELLOW}[!] systemctl daemon-reload failed; DNS socket rollback incomplete.${NC}" >&2; _abox_listen_rollback_failed=1; }
                if systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
                    systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || { msg "${YELLOW}[!] Failed to restart dnscrypt-proxy.socket; DNS socket rollback incomplete.${NC}" >&2; _abox_listen_rollback_failed=1; }
                fi
            fi
        fi
    fi
    if (( _dns_no_systemd == 0 )) && [[ "$backend" == resolved ]] && command -v systemctl >/dev/null 2>&1; then systemctl restart systemd-resolved >/dev/null 2>&1 || return 1; fi
    # M-09: restore the socket Listen state recorded at snapshot time,
    # before the service state below is restored (under socket
    # activation the service inherits the socket's own FDs). Rebuild
    # the A-Box drop-in from the snapshot, or remove it when the
    # snapshot had none (back to the distro default). A foreign
    # abox-listen.conf (no A-Box marker) is never removed: fail
    # closed instead of clobbering an admin-pinned override.
    if [[ -f "$dir/dnscrypt-socket-dropin/abox-listen.conf" ]]; then
        # S4 (R44-M2 follow-up): same symlink refusal as the
        # dnscrypt-socket branch above -- a symlinked snapshot entry
        # fails closed instead of being restored as a live symlink.
        [[ ! -L "$dir/dnscrypt-socket-dropin/abox-listen.conf" ]] || return 1
        [[ -d /etc/systemd/system/dnscrypt-proxy.socket.d ]] || install -d -m 755 /etc/systemd/system/dnscrypt-proxy.socket.d || return 1
        rm -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf || return 1
        cp -a "$dir/dnscrypt-socket-dropin/abox-listen.conf" /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf || return 1
        [[ -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf && ! -L /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf ]] || return 1
    elif [[ -f "$dir/dnscrypt-socket-dropin-state" ]] && [[ "$(tr -d '[:space:]' < "$dir/dnscrypt-socket-dropin-state" 2>/dev/null || true)" == absent ]]; then
        if [[ -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf ]]; then
            grep -Fq '# Managed by A-Box' /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf 2>/dev/null || return 1
            rm -f /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf || return 1
            rmdir /etc/systemd/system/dnscrypt-proxy.socket.d 2>/dev/null || true
        fi
    fi
    # 06c2-01: same _dns_no_systemd gate as above: list-unit-files
    # succeeds offline on a bus-less host, and the daemon-reload
    # inside would then fail and truncate the rest of the restore.
    if (( _dns_no_systemd == 0 )) && [[ -f "$dir/dnscrypt-socket-listen" ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --type=socket --no-legend --no-pager dnscrypt-proxy.socket 2>/dev/null | grep -q '^dnscrypt-proxy\.socket'; then
        local _sock_listen_now='' _sock_listen_want=''
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
            systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || return 1
        fi
        _sock_listen_now=$(systemctl show --property=Listen --value dnscrypt-proxy.socket 2>/dev/null || true)
        _sock_listen_want=$(cat "$dir/dnscrypt-socket-listen" 2>/dev/null || true)
        [[ "$_sock_listen_now" == "$_sock_listen_want" ]] || return 1
    fi
    if (( _dns_no_systemd == 0 )) && command -v systemctl >/dev/null 2>&1; then
        local _dnscrypt_units='' _dnscrypt_list_rc=0
        # W5-FAIL-1 (matrix4-D): list-unit-files with a unit-name filter
        # exits 1 when the unit does not exist, so a box that never
        # installed dnscrypt-proxy failed the whole rollback even though
        # resolv.conf was already restored. List unfiltered instead and
        # check the exit status explicitly: a listing error fails closed
        # (return 1, snapshot preserved for retry), while an absent unit
        # in a successful listing simply skips this optional step via
        # the awk gate below (empty input exits 1, branch not taken).
        # The rc capture is ||-guarded, so it is safe under errexit too.
        _dnscrypt_units=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null) || _dnscrypt_list_rc=$?
        if (( _dnscrypt_list_rc != 0 )); then return 1; fi
        if awk -v wanted='dnscrypt-proxy.service' '$1 == wanted { found=1 } END { exit !found }' <<< "$_dnscrypt_units"; then
        state=$(tr -d '[:space:]' < "$dir/dnscrypt-service-state" 2>/dev/null || printf inactive)
        local enabled_state _got_ens _link_target='' _cur_ens='' _got_link=''
        enabled_state=$(tr -d '[:space:]' < "$dir/dnscrypt-service-enabled" 2>/dev/null || printf disabled)
        # R13C12-03: enabled-runtime restores as runtime-only,
        # not as a persistent enablement that never existed.
        if [[ "$enabled_state" == enabled ]]; then systemctl enable dnscrypt-proxy >/dev/null 2>&1 || return 1
        elif [[ "$enabled_state" == enabled-runtime ]]; then systemctl disable dnscrypt-proxy >/dev/null 2>&1 || return 1; systemctl enable --runtime dnscrypt-proxy >/dev/null 2>&1 || return 1
        # R14C12-02: disable/stop failures propagate (no || true).
        # R15-F12-04: `linked` is not a flavour of disabled: disable
        # deletes the link, so re-create it with `systemctl link`
        # to the target recorded at snapshot time. If the link is
        # already in place there is nothing to re-create; if no
        # target was recorded the link cannot be rebuilt, so fail
        # closed instead of silently converting linked to disabled.
        elif [[ "$enabled_state" == linked ]]; then
            _link_target=$(tr -d '[:space:]' < "$dir/dnscrypt-service-link-target" 2>/dev/null || true)
            _cur_ens=$(systemctl is-enabled dnscrypt-proxy 2>/dev/null || true)
            # R28-NF-08: pre-fix snapshots recorded FragmentPath,
            # i.e. the link itself
            # (/etc/systemd/system/dnscrypt-proxy.service), not its
            # real target. That path is deleted by the disable below,
            # so `systemctl link` on it fails. Recover the real target
            # from the live link before disabling; if the live link is
            # already gone there is nothing to recover from, so fail
            # closed instead of silently converting linked to disabled.
            if [[ "$_link_target" == /etc/systemd/system/dnscrypt-proxy.service ]]; then
                _link_target=$(readlink -f /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null || true)
                [[ -n "$_link_target" ]] || return 1
            fi
            if [[ "$_cur_ens" != linked ]]; then
                [[ -n "$_link_target" ]] || return 1
                # R16-F12-02: `systemctl link` only re-creates the unit
                # symlink; it does not remove the .wants/ enable links
                # a rolled-back `enable` created, so a currently
                # enabled/enabled-runtime unit would stay enabled
                # after the link and fail the verification below.
                # Disable first (which also drops the link, if any),
                # then re-create it.
                if [[ "$_cur_ens" == enabled || "$_cur_ens" == enabled-runtime ]]; then
                    systemctl disable dnscrypt-proxy >/dev/null 2>&1 || return 1
                fi
                systemctl link "$_link_target" >/dev/null 2>&1 || return 1
            fi
        else systemctl disable dnscrypt-proxy >/dev/null 2>&1 || return 1; fi
        if [[ "$state" == active ]]; then systemctl restart dnscrypt-proxy >/dev/null 2>&1 || return 1; else systemctl stop dnscrypt-proxy >/dev/null 2>&1 || return 1; fi
        # R14C12-02: verify the requested states before success.
        if [[ "$state" == active ]]; then
            systemctl is-active --quiet dnscrypt-proxy 2>/dev/null || return 1
        else
            systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && return 1 || true
        fi
        _got_ens=$(systemctl is-enabled dnscrypt-proxy 2>/dev/null || true)
        case "$enabled_state" in
            enabled) [[ "$_got_ens" == enabled ]] || return 1 ;;
            enabled-runtime) [[ "$_got_ens" == enabled-runtime ]] || return 1 ;;
            linked)
                [[ "$_got_ens" == linked ]] || return 1
                # The link itself must point at the recorded target,
                # not merely exist in some form.
                if [[ -n "$_link_target" ]]; then
                    _got_link=$(readlink /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null || true)
                    if [[ "$_got_link" != "$_link_target" ]]; then
                        _got_link=$(readlink -f /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null || true)
                        [[ "$_got_link" == "$_link_target" ]] || return 1
                    fi
                fi ;;
            *) [[ "$_got_ens" != enabled && "$_got_ens" != enabled-runtime ]] || return 1 ;;
        esac
        fi
    fi
    # H-25(3b): see above -- a failed drop-in rollback step fails
    # the whole restore instead of reporting success.
    (( _abox_listen_rollback_failed == 0 )) || return 1
    return 0
}
# Crash-recovery for interrupted DNS snapshot swaps. Called on entry to
# restore_dns_snapshot() and dns_menu(). Completes or rolls back based on
# actual disk state (not assumptions).
dns_snapshot_recover_pending_swap() {
    local pending="${DNS_BACKUP_DIR}.pending-swap"
    local old_path='' new_path=''
    [[ -f "$pending" && ! -L "$pending" ]] || return 0
    old_path=$(sed -n 's/^old=//p' "$pending" 2>/dev/null | head -1 || true)
    new_path=$(sed -n 's/^new=//p' "$pending" 2>/dev/null | head -1 || true)
    # Validate paths are in the expected namespace (avoid path injection).
    case "$old_path" in "${DNS_BACKUP_DIR}.old."*) ;; *) old_path='' ;; esac
    case "$new_path" in "${DNS_BACKUP_DIR}.new."*) ;; *) new_path='' ;; esac
    # Recovery matrix based on actual disk state:
    if [[ -f "$DNS_BACKUP_DIR/COMPLETE" ]]; then
        # Target complete: swap finished. Clean up leftovers.
        [[ -n "$old_path" ]] && rm -rf -- "$old_path" 2>/dev/null || true
        [[ -n "$new_path" ]] && rm -rf -- "$new_path" 2>/dev/null || true
    elif [[ -n "$old_path" && -f "$old_path/COMPLETE" ]]; then
        # Interrupted after rename, before new moved in: restore old FIRST
        # so a subsequent restore always finds a complete snapshot.
        rm -rf -- "$DNS_BACKUP_DIR" 2>/dev/null || return 1
        mv -- "$old_path" "$DNS_BACKUP_DIR" 2>/dev/null || return 1
        [[ -n "$new_path" ]] && rm -rf -- "$new_path" 2>/dev/null || true
    elif [[ -n "$new_path" && -f "$new_path/COMPLETE" ]]; then
        # Old renamed aside, new never moved: complete the swap.
        rm -rf -- "$DNS_BACKUP_DIR" 2>/dev/null || return 1
        mv -- "$new_path" "$DNS_BACKUP_DIR" 2>/dev/null || return 1
        [[ -n "$old_path" ]] && rm -rf -- "$old_path" 2>/dev/null || true
    else
        # Total loss: none of target/old/new has COMPLETE. The pre-existing
        # snapshot is unrecoverable (e.g. kill -9 during staging write, old
        # renamed aside, staging cleaned externally). Preserve the pending
        # record for forensics and report loudly; do NOT silently discard it.
        # Callers must NOT swallow this: restore/install_new propagate
        # the failure, so the FATAL stays visible and no new swap record
        # can overwrite this pending record.
        printf '%s\n' "[A-Box][FATAL] DNS snapshot total loss: no COMPLETE snapshot in $DNS_BACKUP_DIR, $old_path, or $new_path. Pre-existing DNS rollback data is unrecoverable. Pending record preserved at $pending for forensics." >&2
        return 1
    fi
    rm -f -- "$pending"
    return 0
}

# Unified DNS snapshot replacement primitive (used by apply_host_dns and
# dns_enable_doh). Installs $1 (a COMPLETE staging dir) as $DNS_BACKUP_DIR.
# - Moves existing target aside before `mv --`, so target is replaced and
#   staging is never moved inside it (POSIX mv, no GNU -T required).
# - Idempotency: if a COMPLETE baseline already exists, it is PRESERVED and
#   the new staging dir is discarded. The snapshot's purpose is rollback to
#   the pre-change state; overwriting it on re-run would destroy that.
#   Pass force=1 as $2 to replace it anyway (post-success refresh only, via
#   dns_snapshot_refresh_baseline; never at install time: a failed deploy
#   must not move the baseline).
# - Crash safety: pending-swap record written before rename; recovery via
#   dns_snapshot_recover_pending_swap().
dns_snapshot_install_new() {
    local staging="$1"
    local _force="${2:-0}"
    local pending="${DNS_BACKUP_DIR}.pending-swap"
    local old_backup=""
    [[ -d "$staging" && -f "$staging/COMPLETE" ]] || return 1
    # Recover any interrupted previous swap first.
    dns_snapshot_recover_pending_swap || return 1
    # Idempotency: baseline already exists, preserve it -- unless the
    # caller passes force=1 (post-success baseline refresh: the deploy
    # already landed, so the staging snapshot IS the pre-change state a
    # later rollback must restore; see dns_snapshot_refresh_baseline).
    if [[ "$_force" != 1 ]] && [[ -f "$DNS_BACKUP_DIR/COMPLETE" ]]; then
        rm -rf -- "$staging"
        return 0
    fi
    if [[ -e "$DNS_BACKUP_DIR" || -L "$DNS_BACKUP_DIR" ]]; then
        old_backup="${DNS_BACKUP_DIR}.old.$$"
        rm -rf -- "$old_backup" 2>/dev/null || true
        printf 'old=%s\nnew=%s\n' "$old_backup" "$staging" > "$pending" || return 1
        chmod 600 "$pending" 2>/dev/null || true
        mv -- "$DNS_BACKUP_DIR" "$old_backup" || { rm -f -- "$pending"; rm -rf -- "$staging"; return 1; }
        # Target was moved to $old_backup above, so plain POSIX mv replaces cleanly.
        if ! mv -- "$staging" "$DNS_BACKUP_DIR"; then
            # 06d-M3: only delete the pending record when the old
            # snapshot was actually moved back. If the move-back
            # fails too, the old snapshot is intact at $old_backup
            # and the pending record is the only pointer to it:
            # keep it so dns_snapshot_recover_pending_swap can find
            # and restore it.
            if mv -- "$old_backup" "$DNS_BACKUP_DIR" 2>/dev/null; then
                rm -f -- "$pending"
            else
                msg "${YELLOW}[!] DNS snapshot swap failed and the old snapshot could not be moved back; pending record kept at ${pending}, old snapshot at ${old_backup}.${NC}" >&2
            fi
            return 1
        fi
        rm -rf -- "$old_backup"
        rm -f -- "$pending"
    else
        mv -- "$staging" "$DNS_BACKUP_DIR" || { rm -rf -- "$staging"; return 1; }
    fi
    return 0
}

# M-NEW-01: true (0) iff snapshot $1 records a clean A-Box DoH install:
# the .dns-state file says mode=doh, the resolved drop-in points at
# 127.0.0.1:5353, the A-Box socket drop-in is present, and the socket
# listens on 127.0.0.1:5353 with no distro-default 127.0.2.1:53 endpoint.
# All four markers must agree: any manual tampering (dropped drop-in,
# rebound socket, cleared state file) breaks the agreement and the
# snapshot is NOT a clean DoH state, so the baseline gets refreshed.
# Runtime liveness (service active/enabled) is deliberately NOT checked:
# a dead service after a good deploy is still A-Box's DoH state, and
# refreshing on liveness alone would strand the rollback on it.
dns_snapshot_is_clean_doh_state() {
    local dir="$1"
    [[ -f "$dir/dns-state" ]] || return 1
    grep -Fq 'mode=doh' "$dir/dns-state" 2>/dev/null || return 1
    [[ -f "$dir/resolved.conf.d/99-abox-dns.conf" ]] || return 1
    grep -Fq 'DNS=127.0.0.1:5353' "$dir/resolved.conf.d/99-abox-dns.conf" 2>/dev/null || return 1
    [[ -f "$dir/dnscrypt-socket-dropin-state" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$dir/dnscrypt-socket-dropin-state" 2>/dev/null || true)" == present ]] || return 1
    [[ -f "$dir/dnscrypt-socket-listen" ]] || return 1
    grep -Fq '127.0.0.1:5353' "$dir/dnscrypt-socket-listen" 2>/dev/null || return 1
    ! grep -Fq '127.0.2.1:53' "$dir/dnscrypt-socket-listen" 2>/dev/null || return 1
    return 0
}

# M-NEW-01: post-success baseline refresh. Replaces $DNS_BACKUP_DIR with
# the pre-deploy snapshot $1 (the per-attempt keep copy dns_enable_doh
# already holds) through the same atomic swap as dns_snapshot_install_new,
# so a later menu/uninstall rollback restores the immediate pre-deploy
# state instead of a stale first-ever baseline. Call ONLY after the deploy
# has fully succeeded: a failed deploy must leave the baseline alone, and
# the per-attempt failure rollback already covers the failure path. The
# keep copy is staged through a fresh ${DNS_BACKUP_DIR}.new.* dir so the
# pending-swap record stays in-namespace for crash recovery.
dns_snapshot_refresh_baseline() {
    local keep="$1" staging=""
    [[ -d "$keep" && -f "$keep/COMPLETE" ]] || return 1
    staging=$(mktemp -d "${DNS_BACKUP_DIR}.new.XXXXXX") || return 1
    if ! cp -a "$keep/." "$staging/" 2>/dev/null || [[ ! -f "$staging/COMPLETE" ]]; then
        rm -rf -- "$staging" 2>/dev/null || true
        return 1
    fi
    dns_snapshot_install_new "$staging" 1
}

restore_dns_snapshot() {
    # Recover from any interrupted swap before attempting restore.
    dns_snapshot_recover_pending_swap || return 1
    local dir="$1" immutable_state='0' rc=0
    [[ -f "$dir/COMPLETE" ]] || return 1
    immutable_state=$(tr -d '[:space:]' < "$dir/resolv-immutable" 2>/dev/null || printf '0')
    # Always remove the current immutable bit before replacing resolv.conf. If
    # any later restore step fails, still attempt to put the original bit back.
    if command -v chattr >/dev/null 2>&1; then
        if { command -v lsattr >/dev/null 2>&1 && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; } || [[ "$immutable_state" == 1 ]]; then
            chattr -i /etc/resolv.conf 2>/dev/null || {
                [[ "$immutable_state" == 1 ]] && chattr +i /etc/resolv.conf 2>/dev/null || true
                return 1
            }
        fi
    elif [[ "$immutable_state" == 1 ]]; then
        return 1
    fi
    restore_dns_snapshot_body "$dir" || rc=$?
    if [[ "$immutable_state" == 1 ]]; then
        if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
            command -v chattr >/dev/null 2>&1 && chattr +i /etc/resolv.conf 2>/dev/null || rc=1
        else
            rc=1
        fi
    fi
    return "$rc"
}

# R28-OBS-S1-05: a failed per-attempt rollback must never leave its
# staging dir behind. The staging dir holds a symlinked resolv.conf
# copy (snapshot_dns_state uses cp -a), and the pre-deploy backup's
# symlink scan refuses any symlink under $ABOX_DIR outside the pruned
# scratch dirs, so one leaked `${DNS_BACKUP_DIR}.new.*` dir blocks
# every later deployment ("Backup aborted because an existing A-Box
# path could not be copied."). The staging dir is only this attempt's
# rollback source: it is never referenced by any crash-recovery
# record (the pending swap names the `.install` copy, not the
# original), and install_new leaves a COMPLETE baseline in
# $DNS_BACKUP_DIR for manual rollback via the DNS menu. A failed
# restore is reported loudly instead of silently retaining the dir.
dns_rollback_drop_staging() {
    local _dir="$1"
    [[ -n "$_dir" ]] || return 0
    case "$_dir" in "${DNS_BACKUP_DIR}.new."*) ;; *) return 0 ;; esac
    if restore_dns_snapshot "$_dir"; then
        rm -rf -- "$_dir" 2>/dev/null || true
    else
        msg "${RED}[!] $(tr_msg dns_rollback_failed_staging_removed): $_dir${NC}"
        rm -rf -- "$_dir" 2>/dev/null || true
    fi
    return 0
}
# Verify an NM DNS change actually landed: the connection's stored
# servers must match, and the generated resolv.conf must carry the new
# nameserver unless a local plugin (127.0.0.1/127.0.0.53) fronts it.
# $4 (test-only): resolv.conf path; default /etc/resolv.conf.
# Normalize a DNS list to a sorted-unique token set (one per line):
# separators are comma, space, tab and newline; empty tokens dropped.
_nm_dns_norm_set() {
    local _raw="$1" _norm='' _tok=''
    local -a _toks=()
    _norm="${_raw//$'\n'/ }"
    IFS=$', \t' read -ra _toks <<< "$_norm" || true
    for _tok in "${_toks[@]}"; do [[ -n "$_tok" ]] && printf '%s\n' "$(normalize_ip_literal "$_tok")"; done | sort -u
}

# R6C12-02: the connection whose DNS is actually effective (the
# one providing the first nameserver in /etc/resolv.conf).
# apply_host_dns and snapshot_dns_state MUST agree on this device,
# or rollback would restore a different connection than the one
# modified. Falls back to the first connected device when no
# device matches (loopback-only resolv.conf, or DNS from elsewhere).
nm_effective_device() {
    local first_ns='' dev='' _st='' d4='' d6='' tok='' _n_conn=0
    first_ns=$(awk '/^nameserver[[:space:]]/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    while IFS=: read -r dev _st; do
        [[ "$_st" == "connected" ]] || continue
        _n_conn=$(( _n_conn + 1 ))
        if [[ -n "$first_ns" ]]; then
            d4=$(nmcli -g IP4.DNS device show "$dev" 2>/dev/null || true)
            d6=$(nmcli -g IP6.DNS device show "$dev" 2>/dev/null || true)
            for tok in ${d4//,/ } ${d6//,/ }; do
                if [[ "$tok" == "$first_ns" ]]; then printf '%s\n' "$dev"; return 0; fi
            done
        fi
    done < <(LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null || true)
    # R45-M1: when the first nameserver is a loopback front-end, no
    # device's upstream can match it, so the fallback below would
    # guess the first connected device -- and apply_host_dns would
    # then modify (and verify) the wrong connection while another
    # one still serves the old DNS. With exactly one connected
    # device there is nothing to guess; with several, refuse
    # instead (both callers fail closed on an empty result).
    if [[ "$first_ns" =~ ^127\. ]] && (( _n_conn != 1 )); then
        return 1
    fi
    LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$2=="connected"{print $1; exit}'
}

# R15-F12-05: a loopback first nameserver is trusted ONLY when it is
# provably NetworkManager-fed. A loopback resolver NM does not manage
# (e.g. an independent Unbound under rc-manager=unmanaged) forwards
# from unchanged upstreams, so trusting it unconditionally verifies
# DNS that was never applied. Two tiers, both fail-closed:
#   1. LIVE: ask the running daemon -- DnsManager Mode plus the
#      backend's D-Bus owner. A concrete mode other than the expected
#      backend is positive evidence against trust; "default" is
#      inconclusive and falls through; any query failure falls through.
#   2. CONFIG: the merged view from 'NetworkManager --print-config'
#      (never a hand-rolled file scan: same-basename shadowing and
#      intern.conf semantics make last-key-wins over files unreliable).
#      rc-manager=unmanaged, or dns=none (man page: "implies rc-manager
#      unmanaged"), means NOT managed. dns= must name the expected
#      backend (R16-F12-01): dns=default runs no loopback resolver,
#      so "no value = managed" cannot prove a loopback nameserver is
#      NM-fed.
# GPT (astra, high) supplied the live-check design and caught the
# rc-manager spelling (unmanaged, not unmanage); the print-config
# fallback and the two-tier combination are this worker's.
_nm_dns_loopback_trusted() {
    local _first_ns="$1" _want='' _bus='' _mode='' _owned=''
    case "$_first_ns" in
        127.0.0.1) _want=dnsmasq; _bus=org.freedesktop.NetworkManager.dnsmasq ;;
        127.0.0.53) _want=systemd-resolved; _bus=org.freedesktop.resolve1 ;;
        *) return 1 ;;
    esac
    if command -v busctl >/dev/null 2>&1; then
        _mode=$(busctl --system --auto-start=no --timeout=5s get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager/DnsManager org.freedesktop.NetworkManager.DnsManager Mode 2>/dev/null || true)
        case "$_mode" in
            "s \"$_want\"")
                _owned=$(busctl --system --auto-start=no --timeout=5s call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s "$_bus" 2>/dev/null || true)
                [[ "$_owned" == 'b true' ]] && return 0
                return 1 ;;
            's "default"'|'')
                : # inconclusive (or bus query failed): fall to config
                ;;
            *) return 1 ;; # concrete other backend: positively not NM-fed
        esac
    fi
    _nm_dns_resolv_managed "$_want"
}

# Merged-config view only: last uncommented rc-manager=/dns= in [main]
# wins (commented lines are build defaults, not set values).
# $1 = the backend the loopback address needs (dnsmasq for 127.0.0.1,
# systemd-resolved for 127.0.0.53). Returns 0 iff the merged view
# proves NM itself runs that backend: dns= must name it. dns=default
# (or unset) only proves NM writes the connection upstreams into
# resolv.conf -- it runs no loopback resolver at all -- so it is not
# evidence for a loopback first nameserver, and neither is a merely
# managed rc-manager.
_nm_dns_resolv_managed() {
    local _want="${1:-}" _out='' _rcm='' _dns=''
    _out=$(NetworkManager --print-config 2>/dev/null || true)
    [[ -n "$_out" ]] || return 1
    _rcm=$(printf '%s\n' "$_out" | awk '/^\[main\]/{m=1;next} /^\[/{m=0} m && /^rc-manager=/{v=$0; sub(/^rc-manager=/,"",v); gsub(/[[:space:]]+$/,"",v); print v}' | tail -1)
    _dns=$(printf '%s\n' "$_out" | awk '/^\[main\]/{m=1;next} /^\[/{m=0} m && /^dns=/{v=$0; sub(/^dns=/,"",v); gsub(/[[:space:]]+$/,"",v); print v}' | tail -1)
    [[ "$_rcm" == unmanaged || "$_dns" == none ]] && return 1
    [[ -n "$_want" ]] || return 1
    [[ "$_dns" == "$_want" ]] || return 1
    return 0
}

# H5 (R45-M1 residual, hardening): complete effective-upstream check
# (resolvectl). nm_dns_verify_applied below proves the connection
# profile carries the requested servers and that resolv.conf's first
# nameserver is one of them (or a provably NM-fed loopback stub) -- but
# neither proves the requested servers are the ones actually serving
# queries on the effective link: a stale DHCP upstream or a
# higher-priority link can still win while the profile looks right.
# Ask the running resolver directly, on the effective device
# (nm_effective_device, the same device apply_host_dns modified):
#   1. `resolvectl dns <dev>` must list exactly the requested server
#      set (normalised, order-insensitive); a link reporting no
#      servers at all is a definite mismatch, not an inconclusive
#      query.
#   2. `resolvectl status <dev>` "Current DNS Server", when resolved
#      reports one, must be one of the requested servers -- the
#      configured list alone does not prove which server answers.
#      Absent (no query yet) is inconclusive and is skipped.
# Fail-open only when the evidence itself is unavailable: no
# resolvectl binary, no determinable effective device, or resolvectl
# answering nothing at all for the device (resolved not managing it).
# A present-but-different server set is positive evidence of a wrong
# upstream and fails closed. One retry after 1s on mismatch: resolved
# updates asynchronously after `nmcli device reapply`.
_nm_dns_effective_upstream_matches() {
    local dev="$1" v4="$2" v6="${3:-}" _out='' _line='' _servers='' _cur='' _found=0 _tok=''
    local -a _req_toks=()
    IFS=$', \t' read -ra _req_toks <<< "$v4${v6:+,$v6}" || true
    _out=$(resolvectl dns "$dev" 2>/dev/null || true)
    [[ -n "$_out" ]] || return 0
    _servers=''
    while IFS= read -r _line; do
        case "$_line" in
            *"(${dev}):"*) _servers="${_line#*:}"; _found=1 ;;
        esac
    done <<< "$_out"
    (( _found == 1 )) || return 0
    [[ -n "${_servers//[[:space:]]/}" ]] || return 1
    [[ "$(_nm_dns_norm_set "$_servers")" == "$(_nm_dns_norm_set "$v4${v6:+ $v6}")" ]] || return 1
    _out=$(LC_ALL=C resolvectl status "$dev" 2>/dev/null || true)
    _cur=$(printf '%s\n' "$_out" | awk '/^[[:space:]]*Current DNS Server:/ {print $NF; exit}' || true)
    if [[ -n "$_cur" ]]; then
        _cur=$(normalize_ip_literal "$_cur")
        for _tok in "${_req_toks[@]}"; do
            [[ "$(normalize_ip_literal "$_tok")" == "$_cur" ]] && return 0
        done
        return 1
    fi
    return 0
}

_nm_dns_verify_effective_upstream() {
    local v4="$1" v6="${2:-}" dev='' _try=0
    command -v resolvectl >/dev/null 2>&1 || return 0
    dev=$(nm_effective_device 2>/dev/null || true)
    [[ -n "$dev" ]] || return 0
    while (( _try < 2 )); do
        if _nm_dns_effective_upstream_matches "$dev" "$v4" "$v6"; then return 0; fi
        _try=$(( _try + 1 ))
        (( _try < 2 )) && sleep 1
    done
    return 1
}

nm_dns_verify_applied() {
    local connection="$1" v4="$2" v6="${3:-}" rc="${4:-/etc/resolv.conf}" v=''
    v=$(nmcli --escape no -g ipv4.dns connection show "$connection" 2>/dev/null || true)
    [[ "$(_nm_dns_norm_set "$v")" == "$(_nm_dns_norm_set "$v4")" ]] || return 1
    if [[ -n "$v6" ]]; then
        v=$(nmcli --escape no -g ipv6.dns connection show "$connection" 2>/dev/null || true)
        [[ "$(_nm_dns_norm_set "$v")" == "$(_nm_dns_norm_set "$v6")" ]] || return 1
    fi
    # R6C12-02: the EFFECTIVE resolver is the FIRST nameserver.
    # A loopback first entry is trusted only when provably
    # NM-fed (_nm_dns_loopback_trusted, R15-F12-05); an unmanaged
    # loopback resolver falls through to the requested-set compare
    # below and FAILS unless it is one of the requested servers.
    # Any other first entry must be one of the requested servers,
    # or an old higher-priority resolver is still winning and this
    # FAILS.
    local _first_ns='' _req_tok=''
    _first_ns=$(awk '/^nameserver[[:space:]]/{print $2; exit}' "$rc" 2>/dev/null || true)
    [[ -n "$_first_ns" ]] || return 1
    if [[ "$_first_ns" =~ ^127\.0\.0\.(1|53)$ ]]; then
        if _nm_dns_loopback_trusted "$_first_ns"; then
            # H5: a trusted stub only proves the backend provenance; the
            # requested upstreams behind it still have to win.
            _nm_dns_verify_effective_upstream "$v4" "$v6"
            return $?
        fi
    fi
    local -a _req_toks=()
    IFS=$', \t' read -ra _req_toks <<< "$v4${v6:+,$v6}" || true
    # R15-F12-06: compare canonical forms, like the connection-config
    # compare above (_nm_dns_norm_set): an expanded IPv6 literal and
    # the compressed form resolv.conf carries are the same address.
    local _first_ns_norm=''
    _first_ns_norm=$(normalize_ip_literal "$_first_ns")
    for _req_tok in "${_req_toks[@]}"; do
        if [[ "$(normalize_ip_literal "$_req_tok")" == "$_first_ns_norm" ]]; then
            # H5: first-nameserver match is necessary, not sufficient;
            # confirm the requested servers are the effective upstream.
            _nm_dns_verify_effective_upstream "$v4" "$v6"
            return $?
        fi
    done
    return 1
}

# Strip pre-existing global DNS sources (main resolved.conf + every
# drop-in except our own 99-abox-dns.conf) so a new DNS= set REPLACES
# rather than accumulates: systemd-resolved collects DNS= across all
# files. Main resolved.conf is covered by the snapshot; other drop-ins
# are backed up under $DNS_BACKUP_DIR/resolved-cleanup/ and restored by
# restore_dns_snapshot_body. A symlinked DNS-bearing file is refused:
# editing through a symlink would rewrite an unknown target.
resolved_strip_global_dns_sources() {
    local f='' tmp='' base='' sub=''
    local -a files=()
    if [[ -f /etc/systemd/resolved.conf ]]; then
        if [[ -L /etc/systemd/resolved.conf ]]; then
            grep -qiE '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)[[:space:]]*=' /etc/systemd/resolved.conf 2>/dev/null && return 1
        else
            files+=(/etc/systemd/resolved.conf)
        fi
    fi
    for f in /etc/systemd/resolved.conf.d/*.conf /run/systemd/resolved.conf.d/*.conf /usr/lib/systemd/resolved.conf.d/*.conf /usr/local/lib/systemd/resolved.conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        [[ "$f" == /etc/systemd/resolved.conf.d/99-abox-dns.conf ]] && continue
        if [[ -L "$f" ]]; then
            grep -qiE '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)[[:space:]]*=' "$f" 2>/dev/null && return 1
            continue
        fi
        files+=("$f")
    done
    for f in "${files[@]}"; do
        grep -qiE '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)[[:space:]]*=' "$f" 2>/dev/null || continue
        if [[ "$f" != /etc/systemd/resolved.conf ]]; then
            base=$(basename "$f")
            case "$f" in
                /etc/systemd/resolved.conf.d/*) sub='etc' ;;
                /run/systemd/resolved.conf.d/*) sub='run' ;;
                /usr/lib/systemd/resolved.conf.d/*) sub='usr-lib' ;;
                /usr/local/lib/systemd/resolved.conf.d/*) sub='usr-local-lib' ;;
                *) return 1 ;;
            esac
            mkdir -p "$DNS_BACKUP_DIR/resolved-cleanup/$sub" 2>/dev/null || return 1
            if [[ ! -f "$DNS_BACKUP_DIR/resolved-cleanup/$sub/$base" ]]; then
                # R16C12-01: write to a temp name (no .conf suffix,
                # so the restore glob never sees it), verify, then
                # publish by rename. A failed copy leaves no
                # partial final file for a later run to trust.
                local _btmp=''
                _btmp=$(mktemp "$DNS_BACKUP_DIR/resolved-cleanup/$sub/.tmp.XXXXXX" 2>/dev/null || true)
                [[ -n "$_btmp" ]] || return 1
                if ! cp -a "$f" "$_btmp" 2>/dev/null; then rm -f -- "$_btmp"; return 1; fi
                if ! cmp -s "$f" "$_btmp"; then rm -f -- "$_btmp"; return 1; fi
                mv -- "$_btmp" "$DNS_BACKUP_DIR/resolved-cleanup/$sub/$base" 2>/dev/null || { rm -f -- "$_btmp"; return 1; }
            fi
        fi
        tmp=$(mktemp /tmp/A-Box-resolved-strip.XXXXXX 2>/dev/null || true)
        [[ -n "$tmp" ]] || return 1
        if ! awk '{ line = $0; k = line; sub(/^[ \t]+/, "", k); lk = tolower(k); if (lk ~ /^(dns|fallbackdns|dnsovertls)[ \t]*=/) next; print line }' "$f" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
        cat "$tmp" > "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    done
    return 0
}

# Check the global server set reported by resolvectl equals exactly the
# expected space-separated list. '#...' (DoT SNI) and ':port' (IPv4)
# suffixes are ignored on both sides. resolvectl missing => no check
# possible, treated as pass: the strip above is the actual fix, this is
# defense in depth.
# H-25(1): liveness probe for resolved_global_dns_check. Matching the
# drop-in values proves nothing about reachability: 127.0.0.1:53 with
# the proxy on :5353 matches no value yet resolves nothing. Send one
# real query to each expected server; at least one must answer.
# Returns 0 if any server answers.
_resolved_dns_probe_any() {
    local _tok='' _host='' _port=53 _dot_host="${2:-}"
    local -a _toks=()
    IFS=$' \t\n' read -ra _toks <<< "$1" || true
    for _tok in "${_toks[@]}"; do
        _tok="${_tok%%#*}"
        _host="$_tok"; _port=53
        case "$_tok" in
            # N-3 (H-25 hardening): bracketed IPv6 with port, e.g.
            # [::1]:5353 -- the *.*:* arm below cannot split it (no dot),
            # and without this arm the whole token becomes the host with
            # port 53. Unreachable today (no caller emits this form), and
            # dns_probe_once would fail-closed on the bad host anyway.
            \[*\]:*) _host="${_tok#\[}"; _host="${_host%%\]*}"; _port="${_tok##*:}" ;;
            *.*:*) _host="${_tok%:*}"; _port="${_tok##*:}" ;;
        esac
        [[ "$_port" =~ ^[0-9]+$ ]] || _port=53
        # 06d-M2: a DoT deployment must be verified on its real TLS path
        # (853 + SNI handshake), never by plain UDP: UDP answering while
        # 853/TLS is blocked is a false pass, and UDP blocked while DoT
        # works is a false rollback.
        if [[ -n "$_dot_host" ]]; then
            if dns_dot_probe_once "$_host" "$_dot_host" example.com >/dev/null 2>&1; then return 0; fi
        elif dns_probe_once "$_host" "$_port" example.com >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

resolved_global_dns_check() {
    local expected="$1" policy="${2:-strict}" dot_host="${3:-}" line='' tok='' got='' dline='' _dom_out='' _lline='' _ltoks='' _fail_domains=''
    local -a exp=() gottok=() norm_exp=() norm_got=()
    # OBS-S1-06: record WHY the check failed so the caller can say it.
    # The verdict itself is unchanged (still fail-closed, F06/R11-15);
    # only the diagnosis becomes specific. A stale value would blame
    # the previous call, so always reset on entry.
    RESOLVED_DNS_CHECK_FAIL=''
    RESOLVED_DNS_CHECK_WARN=''
    # R30-OBS-S1-02: explicit policy. strict (default, preset path):
    # any link domain fails. doh_search_warn (DoH install only):
    # ordinary search domains warn-and-continue, any ~ route domain
    # still fails. An unknown policy fails closed.
    case "$policy" in
        strict|doh_search_warn) ;;
        *) RESOLVED_DNS_CHECK_FAIL='unknown_dns_check_policy'; return 1 ;;
    esac
    command -v resolvectl >/dev/null 2>&1 || return 0
    line=$(resolvectl dns 2>/dev/null | awk '/^Global:/ {print; exit}' || true)
    [[ -n "$line" ]] || { RESOLVED_DNS_CHECK_FAIL='no_global_dns'; return 1; }
    line="${line#Global:}"
    IFS=$' \t\n' read -ra exp <<< "$expected" || true
    IFS=$' \t\n' read -ra gottok <<< "$line" || true
    for tok in "${exp[@]}"; do tok="${tok%%#*}"; case "$tok" in *.*:*) tok="${tok%:*}";; esac; norm_exp+=("$(normalize_ip_literal "$tok")"); done
    for tok in "${gottok[@]}"; do tok="${tok%%#*}"; case "$tok" in *.*:*) tok="${tok%:*}";; esac; norm_got+=("$(normalize_ip_literal "$tok")"); done
    [[ "$(printf '%s\n' "${norm_exp[@]}" | sort -u | tr '\n' ' ')" == "$(printf '%s\n' "${norm_got[@]}" | sort -u | tr '\n' ' ')" ]] || { RESOLVED_DNS_CHECK_FAIL='dns_mismatch'; return 1; }
    # F06/R11-15: a global DNS list alone does not keep link DHCP
    # resolvers out of the query path, and a global route domain
    # of ~. alone does not either: any link domain (route-only
    # or ordinary) can still select that link for matching names.
    # Require global ~. AND no link domain at all, else roll back.
    # R30-OBS-S1-02: under doh_search_warn ordinary search domains
    # are a warned exception (recorded in RESOLVED_DNS_CHECK_WARN),
    # not a failure; ~ route domains still fail in both policies.
    _dom_out=$(LC_ALL=C resolvectl domain 2>/dev/null) || { RESOLVED_DNS_CHECK_FAIL='domain_query_failed'; return 1; }
    dline=$(printf '%s\n' "$_dom_out" | awk '/^Global:/ {print; exit}' || true)
    [[ -n "$dline" ]] || { RESOLVED_DNS_CHECK_FAIL='no_global_domain'; return 1; }
    [[ " $dline " == *' ~. '* ]] || { RESOLVED_DNS_CHECK_FAIL='no_global_route_domain'; return 1; }
    while IFS= read -r _lline; do
        case "$_lline" in
            'Global:'*) ;;
            'Link '*:*)
                _ltoks="${_lline#*:}"
                if [[ -n "${_ltoks//[[:space:]]/}" ]]; then
                    # Keep the whole line (e.g. "Link 2 (ens5):
                    # ap-southeast-2.compute.internal") so the failure
                    # message can name the exact link and domain.
                    _fail_domains="${_fail_domains:+${_fail_domains}; }${_lline}"
                fi ;;
            '') ;;
            *) RESOLVED_DNS_CHECK_FAIL="unexpected_domain_line:${_lline}"; return 1 ;;
        esac
    done <<< "$_dom_out"
    if [[ -n "$_fail_domains" ]]; then
        if [[ "$policy" == 'doh_search_warn' ]]; then
            # Any ~ route domain still fails; ordinary search
            # domains only warn. Re-scan the collected lines:
            # a ~ token anywhere keeps the strict verdict.
            local _has_route=0 _entry='' _doms='' _tok=''
            local -a _entries=() _toks=()
            IFS=';' read -ra _entries <<< "$_fail_domains" || true
            for _entry in "${_entries[@]}"; do
                _doms="${_entry#*:}"
                IFS=$' \t' read -ra _toks <<< "$_doms" || true
                for _tok in "${_toks[@]}"; do
                    case "$_tok" in '~'*) _has_route=1 ;; esac
                done
            done
            if (( _has_route == 0 )); then
                # H-25(1): values match, but a matching value can still
                # be dead (127.0.0.1:53 with the proxy on :5353).
                # Probe liveness before passing the check.
                if ! _resolved_dns_probe_any "$expected" "$dot_host"; then RESOLVED_DNS_CHECK_FAIL='dns_unreachable'; return 1; fi
                RESOLVED_DNS_CHECK_WARN="$_fail_domains"
                return 0
            fi
        fi
        RESOLVED_DNS_CHECK_FAIL="link_domain:${_fail_domains}"
        return 1
    fi
    # H-25(1): same liveness probe as the warn path above.
    if ! _resolved_dns_probe_any "$expected" "$dot_host"; then RESOLVED_DNS_CHECK_FAIL='dns_unreachable'; return 1; fi
    return 0
}

# OBS-S1-06: when the check fails only because a link still carries a
# (usually DHCP-supplied) search/route domain, name the link instead of
# blaming the global DNS set: the set itself matched in that case, so
# the generic "global DNS set mismatch" text misdescribes the failure.
# The guard itself stays fail-closed (F06/R11-15): any link domain can
# still select that link for matching names, so this only changes the
# message, never the verdict.
resolved_dns_check_fail_message() {
    local detail="${RESOLVED_DNS_CHECK_FAIL:-}"
    case "$detail" in
        link_domain:*)
            tprintf apply_host_dns_verify_link_domain "${detail#link_domain:}" ;;
        *) tr_msg apply_host_dns_verify_mismatch ;;
    esac
}

# R30-OBS-S1-02: render the doh_search_warn exception recorded by
# resolved_global_dns_check (RESOLVED_DNS_CHECK_WARN holds the
# "Link N (iface): domain..." list). Empty when nothing was warned;
# the message never claims all DNS goes via DoH.
resolved_dns_check_warn_message() {
    local detail="${RESOLVED_DNS_CHECK_WARN:-}"
    [[ -n "$detail" ]] || return 0
    tprintf doh_link_search_domains_warn "$detail"
}

# M-21(1): tear down a DoH deployment when the host DNS moves away from
# DoH (plain / DoT / NM / direct resolv.conf). The signal is
# $DNS_STATE_FILE's mode=doh (written by dns_enable_doh). Layered by
# ownership, so a proxy the user installed themselves is never stopped
# or disabled:
#   - A-Box-enabled proxy (the pre-DoH baseline snapshot records its
#     service inactive/disabled AND its socket not in play): stop +
#     disable the service and the socket.
#   - Any proxy (A-Box or foreign): remove only A-Box's own socket
#     drop-in (marker-gated) and reload the socket unit, so a foreign
#     proxy keeps its own Listen endpoints.
# Returns 0 when there was nothing to tear down or the teardown
# succeeded; 1 on failure (callers roll back).
dns_disable_doh() {
    local _dns_state='' _base_state='' _base_enabled='' _base_sock_inplay='' _abox_owned=0
    local _dropin='/etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf'
    local _dropin_dir='/etc/systemd/system/dnscrypt-proxy.socket.d'
    if [[ -f "$DNS_STATE_FILE" && ! -L "$DNS_STATE_FILE" ]]; then
        _dns_state=$(tr -d '\r\n' < "$DNS_STATE_FILE" 2>/dev/null || true)
    fi
    case "$_dns_state" in
        *';mode=doh;'*|*';mode=doh'|*'mode=doh;'*) ;;
        *) return 0 ;;
    esac
    # The pre-DoH baseline is the only durable record of whether the
    # proxy predates A-Box: A-Box installs it fresh (inactive/disabled
    # in the baseline, socket not in play), a foreign one is
    # active/enabled there -- or socket-activated, with an
    # inactive/disabled service and an enabled socket. Without a
    # baseline the service is left alone and only the drop-in goes.
    if [[ -f "$DNS_BACKUP_DIR/dnscrypt-service-state" ]]; then
        _base_state=$(tr -d '[:space:]' < "$DNS_BACKUP_DIR/dnscrypt-service-state" 2>/dev/null || true)
    fi
    if [[ -f "$DNS_BACKUP_DIR/dnscrypt-service-enabled" ]]; then
        _base_enabled=$(tr -d '[:space:]' < "$DNS_BACKUP_DIR/dnscrypt-service-enabled" 2>/dev/null || true)
    fi
    # 06d-H1: the service state alone cannot prove ownership: a
    # socket-activated foreign proxy has an inactive/disabled service
    # at baseline while its socket is enabled. Only a baseline that
    # also records the socket as not in play proves A-Box ownership.
    # A missing or unreadable socket record is "unknown", not "not in
    # play": fail closed and leave the proxy alone (only the A-Box
    # drop-in is removed below). A present A-Box drop-in does not
    # change this: it proves A-Box configured the socket, not that
    # the service behind it is A-Box's.
    if [[ -f "$DNS_BACKUP_DIR/dnscrypt-socket-inplay" ]]; then
        _base_sock_inplay=$(tr -d '[:space:]' < "$DNS_BACKUP_DIR/dnscrypt-socket-inplay" 2>/dev/null || true)
    fi
    if [[ "$_base_state" == inactive && "$_base_enabled" == disabled && "$_base_sock_inplay" == no ]]; then
        _abox_owned=1
    fi
    if (( _abox_owned == 1 )); then
        command -v systemctl >/dev/null 2>&1 || return 1
        systemctl stop dnscrypt-proxy >/dev/null 2>&1 || return 1
        systemctl stop dnscrypt-proxy.socket >/dev/null 2>&1 || return 1
        systemctl disable dnscrypt-proxy >/dev/null 2>&1 || return 1
        systemctl disable dnscrypt-proxy.socket >/dev/null 2>&1 || return 1
    fi
    # Socket drop-in: only A-Box's own marker-carrying file is ever
    # removed; a foreign override stays.
    if [[ -f "$_dropin" ]] && grep -Fq '# Managed by A-Box' "$_dropin" 2>/dev/null; then
        rm -f -- "$_dropin" || return 1
        rmdir "$_dropin_dir" 2>/dev/null || true
        command -v systemctl >/dev/null 2>&1 || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        if (( _abox_owned == 0 )); then
            # The socket is already stopped above for an A-Box-owned
            # proxy; a foreign one rebinds to its packaged endpoints.
            # 06d-M1: a failed restart leaves the socket stopped and
            # unable to rebind -- report it (the function's contract
            # is "failure returns 1, the caller rolls back") instead
            # of swallowing it with || true and returning success.
            if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
                systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || return 1
            fi
        fi
    fi
    return 0
}

apply_host_dns() {
    local mode="$1" v4="$2" v6="$3" tls_name="${4:-}" backend dropin answer confirm_prompt immutable_prompt dot_error dot_verify_error dns_servers immutable_before=0 resolved_major=''
    local _ns='' _tok=''
    local -a _ns_list=()
    case "${ABOX_LANG:-zh}" in
        en) confirm_prompt='Apply this host DNS change? A rollback snapshot is kept. [Y/N]: '; immutable_prompt='/etc/resolv.conf has the immutable flag. Remove it and continue? [Y/N]: '; dot_error='The active DNS backend does not support DoT; DNS was not changed.'; dot_verify_error='DoT verification failed: no configured resolver answered the TLS (port 853) probe; DNS was not changed.' ;;
        ru) confirm_prompt='Применить DNS для системы? Снимок для отката будет сохранён. [Y/N]: '; immutable_prompt='/etc/resolv.conf имеет immutable-флаг. Снять флаг и продолжить? [Y/N]: '; dot_error='Текущий DNS backend не поддерживает DoT; DNS не изменён.'; dot_verify_error='Проверка DoT не удалась: ни один настроенный resolver не ответил на TLS-пробу (порт 853); DNS не изменён.' ;;
        fa) confirm_prompt='تنظیم DNS سیستم اعمال شود؟ نسخه بازگشت ذخیره می‌شود. [Y/N]: '; immutable_prompt='پرچم immutable روی /etc/resolv.conf وجود دارد. حذف و ادامه داده شود؟ [Y/N]: '; dot_error='بک‌اند DNS فعلی از DoT پشتیبانی نمی‌کند؛ DNS تغییر نکرد.'; dot_verify_error='راستی‌آزمایی DoT ناموفق بود: هیچ‌یک از resolverهای پیکربندی‌شده به آزمون TLS (درگاه 853) پاسخ نداد؛ DNS تغییر نکرد.' ;;
        zh-tw) confirm_prompt='確認修改本機 DNS？可回滾。[Y/N]: '; immutable_prompt='/etc/resolv.conf 帶 immutable 屬性；是否移除後繼續？[Y/N]: '; dot_error='當前 DNS 後端不支援 DoT；未修改 DNS。'; dot_verify_error='DoT 驗證失敗：設定的解析器未回應 TLS（853 連接埠）探測；未修改 DNS。' ;;
        ja)
            confirm_prompt='このホストの DNS 設定を適用しますか？ロールバック用スナップショットを保存します。[Y/N]: '; immutable_prompt='/etc/resolv.conf に immutable フラグが設定されています。解除して続行しますか？[Y/N]: '; dot_error='現在の DNS バックエンドは DoT をサポートしていません。DNS は変更されていません。'; dot_verify_error='DoT の検証に失敗しました。設定したリゾルバーが TLS（853 番ポート）のプローブに応答しませんでした。DNS は変更されていません。' ;;
        *) confirm_prompt='确认修改本机 DNS？可回滚。[Y/N]: '; immutable_prompt='/etc/resolv.conf 带 immutable 属性；是否移除后继续？[Y/N]: '; dot_error='当前 DNS 后端不支持 DoT；未修改 DNS。'; dot_verify_error='DoT 验证失败：配置的解析器未响应 TLS（853 端口）探测；未修改 DNS。' ;;
    esac
    # DoT requires systemd-resolved; unsupported backends fail closed.
    backend=$(dns_backend_detect)
    if [[ "$mode" == dot && "$backend" != resolved ]]; then
        msg "${RED}$dot_error${NC}"
        return 1
    fi
    if [[ "$mode" == dot ]]; then
        resolved_major=$(systemd_major_version 2>/dev/null || true)
        if [[ ! "$resolved_major" =~ ^[0-9]+$ ]] || (( resolved_major < 245 )); then
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}DoT with authenticated server names requires systemd-resolved 245 or later; DNS was not changed.${NC}" ;;
                ru) msg "${YELLOW}Для DoT с проверкой имени сервера требуется systemd-resolved версии 245 или новее; DNS не изменён.${NC}" ;;
                fa) msg "${YELLOW}برای DoT با احراز هویت نام سرور، systemd-resolved نسخه 245 یا جدیدتر لازم است؛ DNS تغییر نکرد.${NC}" ;;
                zh-tw) msg "${YELLOW}帶伺服器名稱校驗的 DoT 需要 systemd-resolved 245 或更高版本；未修改 DNS。${NC}" ;;
                ja)
                    msg "${YELLOW}サーバー名認証付きの DoT には systemd-resolved 245 以降が必要です。DNS は変更されていません。${NC}" ;;
                *) msg "${YELLOW}带服务器名称校验的 DoT 需要 systemd-resolved 245 或更高版本；未修改 DNS。${NC}" ;;
            esac
            return 1
        fi
        if ! valid_domain "$tls_name"; then
            case "${ABOX_LANG:-zh}" in
                en) msg "${RED}DoT requires a valid TLS authentication hostname, such as dns.google or cloudflare-dns.com.${NC}" ;;
                ru) msg "${RED}Для DoT требуется корректное имя TLS-аутентификации, например dns.google или cloudflare-dns.com.${NC}" ;;
                fa) msg "${RED}برای DoT نام معتبر احراز هویت TLS لازم است؛ مانند dns.google یا cloudflare-dns.com.${NC}" ;;
                zh-tw) msg "${RED}DoT 需要有效的 TLS 認證主機名，例如 dns.google 或 cloudflare-dns.com。${NC}" ;;
                ja)
                    msg "${RED}DoT には有効な TLS 認証ホスト名が必要です（例: dns.google または cloudflare-dns.com）。${NC}" ;;
                *) msg "${RED}DoT 需要有效的 TLS 认证主机名，例如 dns.google 或 cloudflare-dns.com。${NC}" ;;
            esac
            return 1
        fi
        dns_servers=''
        IFS=$' \t\n' read -ra _ns_list <<< "$v4 $v6" || true
        for _tok in "${_ns_list[@]}"; do dns_servers+="${dns_servers:+ }${_tok}#${tls_name}"; done
    else
        dns_servers="$v4${v6:+ $v6}"
    fi
    msg "${CYAN}DNS backend: ${backend} | IPv4: ${v4} | IPv6: ${v6:-none} | mode: ${mode}${tls_name:+ | TLS name: ${tls_name}}${NC}"
    read -r -p "$confirm_prompt" answer
    is_yes "$answer" || { msg "${YELLOW}$(tr_msg apply_host_dns_cancelled)${NC}"; return 0; }
    # Preserve the original immutable flag so rollback can restore it, too.
    if command -v lsattr >/dev/null 2>&1 && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        immutable_before=1
        read -r -p "$immutable_prompt" answer
        is_yes "$answer" || return 0
    fi
    # B-04 fix: snapshot to a temp dir first, then atomically swap. The old
    # snapshot is only removed after the new one is fully written.
    local dns_snap_tmp=""
    dns_snap_tmp=$(mktemp -d "${DNS_BACKUP_DIR}.new.XXXXXX") || die "Failed to create DNS snapshot staging directory."
    chmod 700 "$dns_snap_tmp"
    if ! snapshot_dns_state "$dns_snap_tmp"; then
        rm -rf -- "$dns_snap_tmp"
        die "Failed to snapshot DNS state; previous rollback snapshot preserved."
    fi
    printf '%s\n' "$immutable_before" > "$dns_snap_tmp/resolv-immutable" || { rm -rf -- "$dns_snap_tmp"; die "Failed to save DNS immutable-flag state."; }
    # R4C12-03: the per-attempt snapshot must survive for failure
    # rollback. install_new consumes its argument (moves it as the
    # baseline, or discards it when a COMPLETE baseline already
    # exists), so hand it a COPY and keep the original as this
    # attempt's rollback source. Otherwise a v4-ok/v6-fail attempt
    # rolls back to the old baseline, leaving the new profile's v4
    # changes as residue.
    # TRAP-5: use the unified snapshot primitive (POSIX mv + pre-move-aside, idempotency,
    # crash-safe pending-swap). Preserves an existing COMPLETE baseline.
    local dns_snap_install="${dns_snap_tmp}.install"
    cp -a -- "$dns_snap_tmp" "$dns_snap_install" || { rm -rf -- "$dns_snap_tmp" "$dns_snap_install"; die "Failed to copy DNS snapshot for baseline install."; }
    dns_snapshot_install_new "$dns_snap_install" || { rm -rf -- "$dns_snap_tmp"; if ! grep -Fxq "new=$dns_snap_install" "${DNS_BACKUP_DIR}.pending-swap" 2>/dev/null; then rm -rf -- "$dns_snap_install"; fi; die "Failed to install new DNS rollback snapshot."; }
    if (( immutable_before == 1 )); then
        chattr -i /etc/resolv.conf 2>/dev/null || { rm -rf -- "$dns_snap_tmp"; die "Failed to clear immutable flag on /etc/resolv.conf."; }
    fi
    # M-21(1): leaving DoH: stop/disable an A-Box-enabled dnscrypt-proxy
    # and remove A-Box's abox-listen.conf socket drop-in (dns_disable_doh
    # is layered by ownership; a foreign proxy is left running and only
    # loses the drop-in). Runs before the new plain/DoT config is written
    # so a failure here still rolls back to the pre-change snapshot.
    if [[ "$mode" != doh ]]; then
        dns_disable_doh || { dns_rollback_drop_staging "$dns_snap_tmp"; die "Failed to tear down the DoH proxy; the DNS change was rolled back."; }
    fi
    case "$backend" in
        resolved)
            # H-09: install -d -m 755 creates the dir at 0755 and also
            # repairs an existing 0700 dir left by the old umask 077
            # leak (mkdir -p never fixes an existing dir mode).
            # 06d-M4: the old DoH was already torn down above, so a
            # failed install -d must roll back first (like the next
            # failure branch), not die directly.
            install -d -m 755 /etc/systemd/resolved.conf.d || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_resolved_dir)"; }
            resolved_strip_global_dns_sources || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg apply_host_dns_clear_sources_failed)"; }
            dropin=/etc/systemd/resolved.conf.d/99-abox-dns.conf
            if [[ "$mode" == 'dot' ]]; then
                write_file_atomically_from_stdin "$dropin" 644 <<EOF_DNS || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg apply_host_dns_dot_write_failed)"; }
# Managed by A-Box
[Resolve]
DNS=${dns_servers}
FallbackDNS=
Domains=~.
DNSOverTLS=yes
EOF_DNS
            else
                write_file_atomically_from_stdin "$dropin" 644 <<EOF_DNS || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg apply_host_dns_dropin_write_failed)"; }
# Managed by A-Box
[Resolve]
DNS=${v4}${v6:+ $v6}
FallbackDNS=
Domains=~.
DNSOverTLS=no
EOF_DNS
            fi
            systemctl restart systemd-resolved >/dev/null 2>&1 || { dns_rollback_drop_staging "$dns_snap_tmp"; die "systemd-resolved restart failed; rollback was attempted."; }
            if [[ "$mode" == 'dot' ]]; then
                # 06d-M2: verify the DoT path with the real TLS probe:
                # the plain-UDP liveness probe below would pass while
                # 853/TLS is blocked and fail while only DoT works.
                resolved_global_dns_check "$v4${v6:+ $v6}" strict "$tls_name" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$dot_verify_error"; }
            else
                resolved_global_dns_check "$v4${v6:+ $v6}" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(resolved_dns_check_fail_message)"; }
            fi
            ;;
        networkmanager)
            local iface connection
            iface=$(nm_effective_device 2>/dev/null || true)
            [[ -n "$iface" ]] || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_no_iface)"; }
            connection=$(nmcli --escape no -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)
            [[ -n "$connection" && "$connection" != '--' ]] || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_no_conn)"; }
            # M-26(1): NetworkManager verify() refuses dns/dns-search
            # on a family whose method is disabled/link-local/shared
            # (the profile can never apply). Read both methods first
            # and skip the forbidden family instead of writing a
            # combination that fails at apply time. A method nmcli
            # fails to report fails open (empty = no restriction).
            local _nm_methods='' _nm_v4method='' _nm_v6method=''
            local _nm_skip_v4=0 _nm_skip_v6=0 _nm_eff_v4="$v4" _nm_eff_v6="${v6:-}"
            _nm_methods=$(nmcli --escape no -g ipv4.method,ipv6.method connection show "$connection" 2>/dev/null || true)
            _nm_v4method=$(printf '%s' "$_nm_methods" | sed -n '1p')
            _nm_v6method=$(printf '%s' "$_nm_methods" | sed -n '2p')
            case "$_nm_v4method" in disabled|link-local|shared) _nm_skip_v4=1; _nm_eff_v4='' ;; esac
            case "$_nm_v6method" in disabled|link-local|shared) _nm_skip_v6=1; _nm_eff_v6='' ;; esac
            if (( _nm_skip_v4 == 1 )) && (( _nm_skip_v6 == 1 )); then
                dns_rollback_drop_staging "$dns_snap_tmp"
                die "NetworkManager connection '$connection' has both IPv4 and IPv6 disabled; no DNS family can be applied."
            fi
            if (( _nm_skip_v4 == 1 )); then
                msg "${YELLOW}[!] IPv4 is disabled on NetworkManager connection '$connection'; IPv4 DNS was not applied.${NC}"
            else
                nmcli connection modify "$connection" ipv4.ignore-auto-dns yes ipv4.dns "$v4" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_nm_v4)"; }
            fi
            if (( _nm_skip_v6 == 1 )); then
                [[ -n "${v6:-}" ]] && msg "${YELLOW}[!] IPv6 is disabled on NetworkManager connection '$connection'; IPv6 DNS was not applied.${NC}"
            else
                nmcli connection modify "$connection" ipv6.ignore-auto-dns yes ipv6.dns "${v6:-}" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_nm_v6)"; }
            fi
            nmcli device reapply "$iface" >/dev/null 2>&1 || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_nm_apply)"; }
            nm_dns_verify_applied "$connection" "$_nm_eff_v4" "$_nm_eff_v6" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_nm_apply)"; }
            ;;
        *)
            [[ ! -L /etc/resolv.conf ]] || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_resolv_symlink)"; }
            # R7C12-02: preserve search/domain/options from the
            # existing resolv.conf; the old code dropped them.
            local _pd_search_domain='' _pd_options=''
            if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
                _pd_search_domain=$(grep -E '^[[:space:]]*(search|domain)[[:space:]]' /etc/resolv.conf 2>/dev/null || true)
                _pd_options=$(grep -E '^[[:space:]]*options[[:space:]]' /etc/resolv.conf 2>/dev/null || true)
            fi
            # A-01 fix: build resolv.conf lines explicitly to avoid the
            # command-substitution newline-stripping bug that used to produce
            # "nameserver 2001:db8::53options timeout:2 attempts:3".
            {
                printf '# Managed by A-Box host DNS helper\n'
                if [[ -n "$v4" ]]; then IFS=$' \t\n' read -ra _ns_list <<< "$v4" || true; for _ns in "${_ns_list[@]}"; do printf 'nameserver %s\n' "$_ns"; done; fi
                if [[ -n "$v6" ]]; then IFS=$' \t\n' read -ra _ns_list <<< "$v6" || true; for _ns in "${_ns_list[@]}"; do printf 'nameserver %s\n' "$_ns"; done; fi
                if [[ -n "$_pd_search_domain" ]]; then printf '%s\n' "$_pd_search_domain"; fi
                if [[ -n "$_pd_options" ]]; then printf '%s\n' "$_pd_options"; else printf 'options timeout:2 attempts:3\n'; fi
            } > "$DNS_BACKUP_DIR/resolv.conf.new" || { dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_resolv_gen)"; }
            write_file_atomically_from_stdin /etc/resolv.conf 644 < "$DNS_BACKUP_DIR/resolv.conf.new" || { rm -f "$DNS_BACKUP_DIR/resolv.conf.new"; dns_rollback_drop_staging "$dns_snap_tmp"; die "$(tr_msg hd_resolv_write)"; }
            rm -f "$DNS_BACKUP_DIR/resolv.conf.new"
            ;;
    esac
    if ! write_file_atomically_from_stdin "$DNS_STATE_FILE" 600 <<< "backend=${backend};mode=${mode};v4=${v4};v6=${v6}"; then
        if restore_dns_snapshot "$dns_snap_tmp"; then
            msg "${RED}DNS state metadata could not be committed; the previous DNS configuration was restored.${NC}"
            rm -rf -- "$dns_snap_tmp"
        else
            msg "${RED}DNS state metadata could not be committed and automatic rollback failed. The pre-change snapshot is retained at $dns_snap_tmp; preserve it for manual recovery. $DNS_BACKUP_DIR may contain an older baseline.${NC}"
        fi
        return 1
    fi
    case "${ABOX_LANG:-zh}" in
        en) msg "${GREEN}Host DNS was updated. Use the DNS menu to roll back.${NC}" ;;
        ru) msg "${GREEN}Системный DNS обновлён. Для отката используйте меню DNS.${NC}" ;;
        fa) msg "${GREEN}DNS سیستم به‌روزرسانی شد؛ برای بازگشت از منوی DNS استفاده کنید.${NC}" ;;
        zh-tw) msg "${GREEN}本機 DNS 已更新。可用選單回滾。${NC}" ;;
        ja)
            msg "${GREEN}ホストの DNS を更新しました。ロールバックするには DNS メニューを使用してください。${NC}" ;;
        *) msg "${GREEN}本机 DNS 已更新。可用菜单回滚。${NC}" ;;
    esac
    rm -rf -- "$dns_snap_tmp"
}

dns_probe_once() {
    local server="$1" port="${2:-53}" name="${3:-example.com}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - "$server" "$port" "$name" <<'PY_DNS_PROBE'
import ipaddress, os, socket, struct, sys, time
server, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    addr = ipaddress.ip_address(server)
    family = socket.AF_INET6 if addr.version == 6 else socket.AF_INET
    ident = int.from_bytes(os.urandom(2), 'big')
    qname = b''.join(bytes([len(x)]) + x for x in name.rstrip('.').encode('ascii').split(b'.')) + b'\0'
    packet = struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', 1, 1)
    sock = socket.socket(family, socket.SOCK_DGRAM); sock.settimeout(1.8)
    start = time.monotonic(); sock.sendto(packet, (server, port)); response, _ = sock.recvfrom(4096)
    elapsed = (time.monotonic() - start) * 1000; sock.close()
    if len(response) < 12: raise RuntimeError('short response')
    rid, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', response[:12])
    if rid != ident or not (flags & 0x8000) or (flags & 15) != 0 or an < 1: raise RuntimeError('query failed')
    print(f'{elapsed:.1f}')
except Exception:
    raise SystemExit(1)
PY_DNS_PROBE
}

dns_dot_probe_once() {
    local server="$1" host="$2" name="${3:-example.com}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - "$server" "$host" "$name" <<'PY_DOT_PROBE'
import os, socket, ssl, struct, sys, time
server, host, name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ident = int.from_bytes(os.urandom(2), 'big')
    qname = b''.join(bytes([len(x)]) + x for x in name.rstrip('.').encode('ascii').split(b'.')) + b'\0'
    query = struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', 1, 1)
    ctx = ssl.create_default_context()
    start = time.monotonic()
    raw = socket.create_connection((server, 853), timeout=4)
    conn = ctx.wrap_socket(raw, server_hostname=host)
    conn.settimeout(4)
    conn.sendall(struct.pack('!H', len(query)) + query)
    def readn(n):
        buf = b''
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk: raise RuntimeError('eof')
            buf += chunk
        return buf
    (rlen,) = struct.unpack('!H', readn(2))
    response = readn(rlen)
    elapsed = (time.monotonic() - start) * 1000
    conn.close()
    if len(response) < 12: raise RuntimeError('short response')
    rid, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', response[:12])
    if rid != ident or not (flags & 0x8000) or (flags & 15) != 0 or an < 1: raise RuntimeError('query failed')
    print(f'{elapsed:.1f}')
except Exception:
    raise SystemExit(1)
PY_DOT_PROBE
}

dns_dot_prefer() {
    local result successes median best='' best_ms=999999 best_success=0 round prompt canceled
    local -a names=('Cloudflare' 'Google' 'Quad9' 'AdGuard')
    local -a v4s=('1.1.1.1' '8.8.8.8' '9.9.9.9' '94.140.14.14')
    local -a v6s=('2606:4700:4700::1111' '2001:4860:4860::8888' '2620:fe::fe' '2a10:50c0::ad1:ff')
    local -a hosts=('cloudflare-dns.com' 'dns.google' 'dns.quad9.net' 'dns.adguard-dns.com')
    local i name v4 v6 host label best_v4='' best_v6='' best_host=''
    local -a timings=()
    command -v python3 >/dev/null 2>&1 || { msg "${RED}DNS benchmark requires Python 3.${NC}"; pause_return; return 1; }
    clear
    case "${ABOX_LANG:-zh}" in
        en) msg "${CYAN}DoT preference test: three real example.com queries per candidate (TLS handshake included)${NC}" ;;
        ru) msg "${CYAN}Проверка DoT: три реальных запроса example.com к каждому серверу (включая TLS-рукопожатие)${NC}" ;;
        fa) msg "${CYAN}آزمون DoT: سه پرس‌وجوی واقعی example.com برای هر سرور (شامل دست‌دهی TLS)${NC}" ;;
        zh-tw) msg "${CYAN}DoT 自動測速：每個候選對 example.com 發起 3 次真實查詢（含 TLS 握手）${NC}" ;;
        ja) msg "${CYAN}DoT 優先度テスト: 各候補について example.com への実際のクエリを 3 回（TLS ハンドシェイク込み）${NC}" ;;
        *) msg "${CYAN}DoT 自动测速：每个候选对 example.com 发起 3 次真实查询（含 TLS 握手）${NC}" ;;
    esac
    for i in 0 1 2 3; do
        name="${names[$i]}"; v4="${v4s[$i]}"; v6="${v6s[$i]}"; host="${hosts[$i]}"; label="$name ($v4)"
        timings=(); successes=0
        for round in 1 2 3; do
            result=$(dns_dot_probe_once "$v4" "$host" example.com 2>/dev/null || true)
            if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then timings+=("$result"); successes=$((successes+1)); fi
        done
        if (( successes > 0 )); then
            median=$(printf '%s\n' "${timings[@]}" | LC_ALL=C sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.1f", (v[NR/2]+v[NR/2+1])/2}')
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$label${NC}: $successes/3 successful, median ${median} ms" ;;
                ru) msg "${YELLOW}$label${NC}: успешно $successes/3, медиана ${median} мс" ;;
                fa) msg "${YELLOW}$label${NC}: موفق $successes/3، میانه ${median} میلی‌ثانیه" ;;
                zh-tw) msg "${YELLOW}$label${NC}: 成功 $successes/3，中位數 ${median} ms" ;;
                ja) msg "${YELLOW}$label${NC}: 成功: $successes/3、中央値: ${median} ms" ;;
                *) msg "${YELLOW}$label${NC}: 成功 $successes/3，中位数 ${median} ms" ;;
            esac
            if (( successes > best_success )) || { (( successes == best_success )) && awk -v a="$median" -v b="$best_ms" 'BEGIN{exit !(a+0 < b+0)}'; }; then best="$label"; best_ms="$median"; best_success=$successes; best_v4="$v4"; best_v6="$v6"; best_host="$host"; fi
        else
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$label${NC}: 0/3 successful" ;;
                ru) msg "${YELLOW}$label${NC}: успешно 0/3" ;;
                fa) msg "${YELLOW}$label${NC}: موفق 0/3" ;;
                zh-tw) msg "${YELLOW}$label${NC}: 成功 0/3" ;;
                ja) msg "${YELLOW}$label${NC}: 成功: 0/3" ;;
                *) msg "${YELLOW}$label${NC}: 成功 0/3" ;;
            esac
        fi
    done
    [[ -n "$best" && $best_success -ge 2 ]] || {
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}No DoT resolver passed the availability threshold; DNS was not changed.${NC}" ;;
            ru) msg "${RED}Ни один DoT-сервер не прошёл проверку доступности; DNS не изменён.${NC}" ;;
            fa) msg "${RED}هیچ سرور DoT از آستانه دسترس‌پذیری عبور نکرد؛ DNS تغییر نکرد.${NC}" ;;
            zh-tw) msg "${RED}沒有 DoT 候選透過可用性門檻；未修改 DNS。${NC}" ;;
            ja) msg "${RED}可用性のしきい値を満たす DoT リゾルバーがありません。DNS は変更されていません。${NC}" ;;
            *) msg "${RED}没有 DoT 候选通过可用性门槛；未修改 DNS。${NC}" ;;
        esac
        pause_return; return 1;
    }
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${GREEN}Best measured DoT candidate now: $best, ${best_success}/3 successful, median ${best_ms} ms.${NC}"
            msg 'This result describes this VPS and this test window; timings include the TLS handshake. The winner is applied with its IPv4, IPv6 and TLS hostname.'
            prompt='Apply this DoT resolver as host DNS? [Y/N]: '
            canceled='Canceled; host DNS was not changed.' ;;
        ru)
            msg "${GREEN}Лучший DoT сейчас: $best; успешно ${best_success}/3, медиана ${best_ms} мс.${NC}"
            msg 'Результат относится к этому VPS и времени проверки; время включает TLS-рукопожатие. Применяются IPv4, IPv6 и TLS-имя победителя.'
            prompt='Применить этот DoT для системы? [Y/N]: '
            canceled='Отменено; системный DNS не изменён.' ;;
        fa)
            msg "${GREEN}بهترین DoT فعلی: ${best}؛ موفق ${best_success}/3، میانه ${best_ms} میلی‌ثانیه.${NC}"
            msg 'این نتیجه مربوط به همین VPS و همین زمان آزمون است؛ زمان شامل دست‌دهی TLS است. IPv4 و IPv6 و نام TLS برنده اعمال می‌شود.'
            prompt='این DoT برای سیستم اعمال شود؟ [Y/N]: '
            canceled='لغو شد؛ DNS سیستم تغییر نکرد.' ;;
        zh-tw)
            msg "${GREEN}本次測試最佳 DoT 候選：${best}，成功 ${best_success}/3，中位數 ${best_ms} ms。${NC}"
            msg '結果僅適用於當前 VPS 和當前測試時段；延遲含 TLS 握手。將以勝出者的 IPv4、IPv6 與 TLS 主機名應用。'
            prompt='將該 DoT 解析器應用為本機 DNS？[Y/N]: '
            canceled='已取消，未修改本機 DNS。' ;;
        ja)
            msg "${GREEN}今回の測定で最良の DoT 候補: $best、成功: ${best_success}/3、中央値: ${best_ms} ms。${NC}"
            msg 'この結果はこの VPS および今回の測定時間帯に限られます。時間には TLS ハンドシェイクを含みます。勝者の IPv4 / IPv6 / TLS ホスト名で適用します。'
            prompt='この DoT リゾルバーをホストの DNS として適用しますか？ [Y/N]: '
            canceled='キャンセルしました。ホストの DNS は変更されていません。' ;;
        *)
            msg "${GREEN}本次测试最佳 DoT 候选：${best}，成功 ${best_success}/3，中位数 ${best_ms} ms。${NC}"
            msg '结果仅适用于当前 VPS 和当前测试时段；延迟含 TLS 握手。将以胜出者的 IPv4、IPv6 与 TLS 主机名应用。'
            prompt='将该 DoT 解析器应用为本机 DNS？[Y/N]: '
            canceled='已取消，未修改本机 DNS。' ;;
    esac
    read -r -p "$prompt" result
    is_yes "$result" || { msg "$canceled"; pause_return; return 0; }
    # R46-01: pause_return always returns 0, so a bare apply call
    # followed by it reports a failed DNS switch as success. Save
    # the apply result first, pause, then return it.
    local _apply_rc=0
    apply_host_dns dot "$best_v4" "$best_v6" "$best_host" || _apply_rc=$?
    pause_return
    return "$_apply_rc"
}

dns_doh_probe_once() {
    local server="$1" host="$2" name="${3:-example.com}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I - "$server" "$host" "$name" <<'PY_DOH_PROBE'
import os, socket, ssl, struct, sys, time
server, host, name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ident = int.from_bytes(os.urandom(2), 'big')
    qname = b''.join(bytes([len(x)]) + x for x in name.rstrip('.').encode('ascii').split(b'.')) + b'\0'
    query = struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', 1, 1)
    ctx = ssl.create_default_context()
    start = time.monotonic()
    raw = socket.create_connection((server, 443), timeout=4)
    conn = ctx.wrap_socket(raw, server_hostname=host)
    conn.settimeout(4)
    req = (f"POST /dns-query HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nContent-Length: {len(query)}\r\nConnection: close\r\n\r\n").encode('ascii') + query
    conn.sendall(req)
    chunks = []
    while True:
        data = conn.recv(65536)
        if not data: break
        chunks.append(data)
    elapsed = (time.monotonic() - start) * 1000
    conn.close()
    resp = b''.join(chunks)
    head, _, body = resp.partition(b'\r\n\r\n')
    parts = head.split(b' ')
    if len(parts) < 2: raise RuntimeError('bad response')
    if int(parts[1]) != 200: raise RuntimeError('http status')
    if b'transfer-encoding: chunked' in head.lower():
        out = b''; rest = body
        while True:
            line, _, rest = rest.partition(b'\r\n')
            n = int(line.strip(), 16)
            if n == 0: break
            out += rest[:n]; rest = rest[n + 2:]
        body = out
    if len(body) < 12: raise RuntimeError('short response')
    rid, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', body[:12])
    if rid != ident or not (flags & 0x8000) or (flags & 15) != 0 or an < 1: raise RuntimeError('query failed')
    print(f'{elapsed:.1f}')
except Exception:
    raise SystemExit(1)
PY_DOH_PROBE
}

dns_doh_prefer() {
    local result successes median best='' best_ms=999999 best_success=0 round prompt canceled
    local -a names=('Cloudflare' 'Google' 'AdGuard')
    local -a v4s=('1.1.1.1' '8.8.8.8' '94.140.14.14')
    local -a hosts=('cloudflare-dns.com' 'dns.google' 'dns.adguard-dns.com')
    local -a srvs=('cloudflare' 'google' 'adguard-dns-doh')
    local i name v4 host srv label best_srv=''
    local -a timings=()
    command -v python3 >/dev/null 2>&1 || { msg "${RED}DNS benchmark requires Python 3.${NC}"; pause_return; return 1; }
    clear
    case "${ABOX_LANG:-zh}" in
        en) msg "${CYAN}DoH preference test: three real example.com queries per candidate (TLS handshake included). Quad9 is excluded: its DoH requires HTTP/2, which this probe cannot speak.${NC}" ;;
        ru) msg "${CYAN}Проверка DoH: три реальных запроса example.com к каждому серверу (включая TLS-рукопожатие). Quad9 исключён: его DoH требует HTTP/2.${NC}" ;;
        fa) msg "${CYAN}آزمون DoH: سه پرس‌وجوی واقعی example.com برای هر سرور (شامل دست‌دهی TLS). Quad9 حذف شده: DoH آن HTTP/2 می‌خواهد.${NC}" ;;
        zh-tw) msg "${CYAN}DoH 自動測速：每個候選對 example.com 發起 3 次真實查詢（含 TLS 握手）。Quad9 的 DoH 強制 HTTP/2，探針無法測量，未納入。${NC}" ;;
        ja) msg "${CYAN}DoH 優先度テスト: 各候補について example.com への実際のクエリを 3 回（TLS ハンドシェイク込み）。Quad9 は DoH に HTTP/2 を必須とするため除外。${NC}" ;;
        *) msg "${CYAN}DoH 自动测速：每个候选对 example.com 发起 3 次真实查询（含 TLS 握手）。Quad9 的 DoH 强制 HTTP/2，探针无法测量，未纳入。${NC}" ;;
    esac
    for i in 0 1 2; do
        name="${names[$i]}"; v4="${v4s[$i]}"; host="${hosts[$i]}"; srv="${srvs[$i]}"; label="$name ($v4)"
        timings=(); successes=0
        for round in 1 2 3; do
            result=$(dns_doh_probe_once "$v4" "$host" example.com 2>/dev/null || true)
            if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then timings+=("$result"); successes=$((successes+1)); fi
        done
        if (( successes > 0 )); then
            median=$(printf '%s\n' "${timings[@]}" | LC_ALL=C sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.1f", (v[NR/2]+v[NR/2+1])/2}')
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$label${NC}: $successes/3 successful, median ${median} ms" ;;
                ru) msg "${YELLOW}$label${NC}: успешно $successes/3, медиана ${median} мс" ;;
                fa) msg "${YELLOW}$label${NC}: موفق $successes/3، میانه ${median} میلی‌ثانیه" ;;
                zh-tw) msg "${YELLOW}$label${NC}: 成功 $successes/3，中位數 ${median} ms" ;;
                ja) msg "${YELLOW}$label${NC}: 成功: $successes/3、中央値: ${median} ms" ;;
                *) msg "${YELLOW}$label${NC}: 成功 $successes/3，中位数 ${median} ms" ;;
            esac
            if (( successes > best_success )) || { (( successes == best_success )) && awk -v a="$median" -v b="$best_ms" 'BEGIN{exit !(a+0 < b+0)}'; }; then best="$label"; best_ms="$median"; best_success=$successes; best_srv="$srv"; fi
        else
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$label${NC}: 0/3 successful" ;;
                ru) msg "${YELLOW}$label${NC}: успешно 0/3" ;;
                fa) msg "${YELLOW}$label${NC}: موفق 0/3" ;;
                zh-tw) msg "${YELLOW}$label${NC}: 成功 0/3" ;;
                ja) msg "${YELLOW}$label${NC}: 成功: 0/3" ;;
                *) msg "${YELLOW}$label${NC}: 成功 0/3" ;;
            esac
        fi
    done
    [[ -n "$best" && $best_success -ge 2 ]] || {
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}No DoH resolver passed the availability threshold; DNS was not changed.${NC}" ;;
            ru) msg "${RED}Ни один DoH-сервер не прошёл проверку доступности; DNS не изменён.${NC}" ;;
            fa) msg "${RED}هیچ سرور DoH از آستانه دسترس‌پذیری عبور نکرد؛ DNS تغییر نکرد.${NC}" ;;
            zh-tw) msg "${RED}沒有 DoH 候選透過可用性門檻；未修改 DNS。${NC}" ;;
            ja) msg "${RED}可用性のしきい値を満たす DoH リゾルバーがありません。DNS は変更されていません。${NC}" ;;
            *) msg "${RED}没有 DoH 候选通过可用性门槛；未修改 DNS。${NC}" ;;
        esac
        pause_return; return 1;
    }
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${GREEN}Best measured DoH candidate now: $best, ${best_success}/3 successful, median ${best_ms} ms.${NC}"
            msg 'This result describes this VPS and this test window; timings include the TLS handshake. The winner is applied through the local dnscrypt-proxy forwarder.'
            prompt='Apply this DoH resolver as host DNS? [Y/N]: '
            canceled='Canceled; host DNS was not changed.' ;;
        ru)
            msg "${GREEN}Лучший DoH сейчас: $best; успешно ${best_success}/3, медиана ${best_ms} мс.${NC}"
            msg 'Результат относится к этому VPS и времени проверки; время включает TLS-рукопожатие. Победитель применяется через локальный dnscrypt-proxy.'
            prompt='Применить этот DoH для системы? [Y/N]: '
            canceled='Отменено; системный DNS не изменён.' ;;
        fa)
            msg "${GREEN}بهترین DoH فعلی: ${best}؛ موفق ${best_success}/3، میانه ${best_ms} میلی‌ثانیه.${NC}"
            msg 'این نتیجه مربوط به همین VPS و همین زمان آزمون است؛ زمان شامل دست‌دهی TLS است. برنده از طریق dnscrypt-proxy محلی اعمال می‌شود.'
            prompt='این DoH برای سیستم اعمال شود؟ [Y/N]: '
            canceled='لغو شد؛ DNS سیستم تغییر نکرد.' ;;
        zh-tw)
            msg "${GREEN}本次測試最佳 DoH 候選：${best}，成功 ${best_success}/3，中位數 ${best_ms} ms。${NC}"
            msg '結果僅適用於當前 VPS 和當前測試時段；延遲含 TLS 握手。將透過本地 dnscrypt-proxy 轉發應用勝出者。'
            prompt='將該 DoH 解析器應用為本機 DNS？[Y/N]: '
            canceled='已取消，未修改本機 DNS。' ;;
        ja)
            msg "${GREEN}今回の測定で最良の DoH 候補: $best、成功: ${best_success}/3、中央値: ${best_ms} ms。${NC}"
            msg 'この結果はこの VPS および今回の測定時間帯に限られます。時間には TLS ハンドシェイクを含みます。勝者はローカル dnscrypt-proxy 経由で適用されます。'
            prompt='この DoH リゾルバーをホストの DNS として適用しますか？ [Y/N]: '
            canceled='キャンセルしました。ホストの DNS は変更されていません。' ;;
        *)
            msg "${GREEN}本次测试最佳 DoH 候选：${best}，成功 ${best_success}/3，中位数 ${best_ms} ms。${NC}"
            msg '结果仅适用于当前 VPS 和当前测试时段；延迟含 TLS 握手。将通过本地 dnscrypt-proxy 转发应用胜出者。'
            prompt='将该 DoH 解析器应用为本机 DNS？[Y/N]: '
            canceled='已取消，未修改本机 DNS。' ;;
    esac
    read -r -p "$prompt" result
    is_yes "$result" || { msg "$canceled"; pause_return; return 0; }
    # R46-01: pause_return always returns 0, so a bare apply call
    # followed by it reports a failed DNS switch as success. Save
    # the apply result first, pause, then return it.
    local _apply_rc=0
    ABOX_DOH_YES=1 dns_enable_doh "$best_srv" "$best" || _apply_rc=$?
    pause_return
    return "$_apply_rc"
}

dns_auto_prefer() {
    local server result successes median best='' best_ms=999999 best_success=0 round v6 prompt canceled
    local -a candidates=('1.1.1.1' '8.8.8.8' '9.9.9.9' '208.67.222.222') timings=()
    command -v python3 >/dev/null 2>&1 || { msg "${RED}DNS benchmark requires Python 3.${NC}"; pause_return; return 1; }
    clear
    case "${ABOX_LANG:-zh}" in
        en) msg "${CYAN}DNS preference test: three real example.com queries per candidate${NC}" ;;
        ru) msg "${CYAN}Проверка DNS: три реальных запроса example.com к каждому серверу${NC}" ;;
        fa) msg "${CYAN}آزمون DNS: سه پرس‌وجوی واقعی example.com برای هر سرور${NC}" ;;
        zh-tw) msg "${CYAN}DNS 自動測速：每個候選對 example.com 發起 3 次真實查詢${NC}" ;;
        ja)
            msg "${CYAN}DNS 優先度テスト: 各候補について example.com への実際のクエリを 3 回実行します${NC}" ;;
        *) msg "${CYAN}DNS 自动测速：每个候选对 example.com 发起 3 次真实查询${NC}" ;;
    esac
    for server in "${candidates[@]}"; do
        timings=(); successes=0
        for round in 1 2 3; do
            result=$(dns_probe_once "$server" 53 example.com 2>/dev/null || true)
            if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then timings+=("$result"); successes=$((successes+1)); fi
        done
        if (( successes > 0 )); then
            median=$(printf '%s\n' "${timings[@]}" | LC_ALL=C sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.1f", (v[NR/2]+v[NR/2+1])/2}')
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$server${NC}: $successes/3 successful, median ${median} ms" ;;
                ru) msg "${YELLOW}$server${NC}: успешно $successes/3, медиана ${median} мс" ;;
                fa) msg "${YELLOW}$server${NC}: موفق $successes/3، میانه ${median} میلی‌ثانیه" ;;
                zh-tw) msg "${YELLOW}$server${NC}: 成功 $successes/3，中位數 ${median} ms" ;;
                ja)
                    msg "${YELLOW}$server${NC}: 成功: $successes/3、中央値: ${median} ms" ;;
                *) msg "${YELLOW}$server${NC}: 成功 $successes/3，中位数 ${median} ms" ;;
            esac
            if (( successes > best_success )) || { (( successes == best_success )) && awk -v a="$median" -v b="$best_ms" 'BEGIN{exit !(a+0 < b+0)}'; }; then best="$server"; best_ms="$median"; best_success=$successes; fi
        else
            case "${ABOX_LANG:-zh}" in
                en) msg "${YELLOW}$server${NC}: 0/3 successful" ;;
                ru) msg "${YELLOW}$server${NC}: успешно 0/3" ;;
                fa) msg "${YELLOW}$server${NC}: موفق 0/3" ;;
                zh-tw) msg "${YELLOW}$server${NC}: 成功 0/3" ;;
                ja)
                    msg "${YELLOW}$server${NC}: 成功: 0/3" ;;
                *) msg "${YELLOW}$server${NC}: 成功 0/3" ;;
            esac
        fi
    done
    [[ -n "$best" && $best_success -ge 2 ]] || {
        case "${ABOX_LANG:-zh}" in
            en) msg "${RED}No resolver passed the availability threshold; DNS was not changed.${NC}" ;;
            ru) msg "${RED}Ни один DNS не прошёл проверку доступности; DNS не изменён.${NC}" ;;
            fa) msg "${RED}هیچ DNS از آستانه دسترس‌پذیری عبور نکرد؛ تنظیمات تغییر نکرد.${NC}" ;;
            zh-tw) msg "${RED}沒有候選透過可用性門檻；未修改 DNS。${NC}" ;;
            ja)
                msg "${RED}可用性のしきい値を満たす DNS リゾルバーがありません。DNS は変更されていません。${NC}" ;;
            *) msg "${RED}没有候选通过可用性门槛；未修改 DNS。${NC}" ;;
        esac
        pause_return; return 1;
    }
    # Only the measured IPv4 resolver is applied; IPv6 resolvers require their own measurement.
    v6=''
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${GREEN}Best measured candidate now: $best, ${best_success}/3 successful, median ${best_ms} ms.${NC}"
            msg 'This result describes this VPS and this test window; it is not a universal DNS ranking. Only the measured IPv4 resolver is applied.'
            prompt='Apply this resolver as host DNS? [Y/N]: '
            canceled='Canceled; host DNS was not changed.' ;;
        ru)
            msg "${GREEN}Лучший результат сейчас: $best; успешно ${best_success}/3, медиана ${best_ms} мс.${NC}"
            msg 'Результат относится к этому VPS и времени проверки; это не универсальный рейтинг DNS. Применяется только измеренный IPv4-резолвер.'
            prompt='Применить этот DNS для системы? [Y/N]: '
            canceled='Отменено; системный DNS не изменён.' ;;
        fa)
            msg "${GREEN}بهترین نتیجه فعلی: ${best}؛ موفق ${best_success}/3، میانه ${best_ms} میلی‌ثانیه.${NC}"
            msg 'این نتیجه مربوط به همین VPS و همین زمان آزمون است و رتبه‌بندی جهانی DNS نیست؛ فقط DNS IPv4 اندازه‌گیری‌شده اعمال می‌شود.'
            prompt='این DNS برای سیستم اعمال شود؟ [Y/N]: '
            canceled='لغو شد؛ DNS سیستم تغییر نکرد.' ;;
        zh-tw)
            msg "${GREEN}本次測試最佳候選：${best}，成功 ${best_success}/3，中位數 ${best_ms} ms。${NC}"
            msg '結果僅適用於當前 VPS 和當前測試時段，不代表全球通用最佳 DNS。只應用已實測的 IPv4 解析器。'
            prompt='將該解析器應用為本機 DNS？[Y/N]: '
            canceled='已取消，未修改本機 DNS。' ;;
        ja)
            msg "${GREEN}今回の測定で最良の候補: $best、成功: ${best_success}/3、中央値: ${best_ms} ms。${NC}"
            msg 'この結果はこの VPS および今回の測定時間帯に限られ、世界共通の最適な DNS を示すものではありません。実測済みの IPv4 リゾルバーのみを適用します。'
            prompt='このリゾルバーをホストの DNS として適用しますか？[Y/N]: '
            canceled='キャンセルしました。ホストの DNS は変更されていません。' ;;
        *)
            msg "${GREEN}本次测试最佳候选：${best}，成功 ${best_success}/3，中位数 ${best_ms} ms。${NC}"
            msg '结果仅适用于当前 VPS 和当前测试时段，不代表全球通用最佳 DNS。只应用已实测的 IPv4 解析器。'
            prompt='将该解析器应用为本机 DNS？[Y/N]: '
            canceled='已取消，未修改本机 DNS。' ;;
    esac
    read -r -p "$prompt" result
    is_yes "$result" || { msg "$canceled"; pause_return; return 0; }
    # R46-01: pause_return always returns 0, so a bare apply call
    # followed by it reports a failed DNS switch as success. Save
    # the apply result first, pause, then return it.
    local _apply_rc=0
    apply_host_dns plain "$best" "$v6" || _apply_rc=$?
    pause_return
    return "$_apply_rc"
}

dns_install_dnscrypt_proxy() {
    local _cfg="${DNSCRYPT_CONFIG:-/etc/dnscrypt-proxy/dnscrypt-proxy.toml}"
    local prompt answer
    # R11C12-02: ready requires BOTH binary and config; a binary
    # left behind by a config-deleting rollback is not ready.
    if command -v dnscrypt-proxy >/dev/null 2>&1 && [[ -f "$_cfg" && ! -L "$_cfg" ]]; then return 0; fi
    # Binary present but config missing: offer a confirmed
    # reinstall to restore the default config.
    if command -v dnscrypt-proxy >/dev/null 2>&1; then
        case "${ABOX_LANG:-zh}" in
            en) prompt='dnscrypt-proxy is installed but its config is missing. Reinstall to restore the default config? [Y/N]: ' ;;
            ru) prompt='dnscrypt-proxy установлен, но его конфигурация отсутствует. Переустановить для восстановления конфигурации по умолчанию? [Y/N]: ' ;;
            fa) prompt='dnscrypt-proxy نصب است اما پیکربندی آن موجود نیست. برای بازیابی پیکربندی پیش‌فرض دوباره نصب شود؟ [Y/N]: ' ;;
            zh-tw) prompt='dnscrypt-proxy 已安裝但設定檔遺失。是否重新安裝以恢復預設設定？[Y/N]: ' ;;
            ja) prompt='dnscrypt-proxy はインストール済みですが設定ファイルがありません。既定の設定を復元するため再インストールしますか？[Y/N]: ' ;;
            *) prompt='dnscrypt-proxy 已安装但配置文件缺失。是否重新安装以恢复默认配置？[Y/N]: ' ;;
        esac
        read -r -p "$prompt" answer
        is_yes "$answer" || { msg "${YELLOW}dnscrypt-proxy config missing and reinstall declined; DNS was not changed.${NC}"; return 1; }
        if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y --reinstall -o Dpkg::Options::=--force-confmiss dnscrypt-proxy || return 1
        elif command -v apk >/dev/null 2>&1; then apk fix dnscrypt-proxy || return 1
        elif command -v dnf >/dev/null 2>&1; then dnf reinstall -y dnscrypt-proxy || return 1
        else msg "${YELLOW}Automatic DoH setup is not enabled for this package manager; DNS was not changed.${NC}"; return 1; fi
        [[ -f "$_cfg" && ! -L "$_cfg" ]] || { msg "${YELLOW}dnscrypt-proxy config still missing after reinstall; DNS was not changed.${NC}"; return 1; }
        return 0
    fi
    case "${ABOX_LANG:-zh}" in
        en) prompt='Install dnscrypt-proxy from the configured OS package repository to provide DoH? [Y/N]: ' ;;
        ru) prompt='Установить dnscrypt-proxy из системного репозитория для DoH? [Y/N]: ' ;;
        fa) prompt='برای DoH، dnscrypt-proxy از مخزن سیستم نصب شود؟ [Y/N]: ' ;;
        zh-tw) prompt='是否從當前系統軟體源安裝 dnscrypt-proxy 以提供 DoH？[Y/N]: ' ;;
        ja)
            prompt='DoH を提供するため、設定済みの OS パッケージリポジトリから dnscrypt-proxy をインストールしますか？[Y/N]: ' ;;
        *) prompt='是否从当前系统软件源安装 dnscrypt-proxy 以提供 DoH？[Y/N]: ' ;;
    esac
    read -r -p "$prompt" answer
    is_yes "$answer" || return 1
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y dnscrypt-proxy || return 1
    elif command -v apk >/dev/null 2>&1; then apk add dnscrypt-proxy || return 1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y dnscrypt-proxy || return 1
    else msg "${YELLOW}Automatic DoH setup is not enabled for this package manager; DNS was not changed.${NC}"; return 1; fi
    command -v dnscrypt-proxy >/dev/null 2>&1 || return 1
    [[ -f "$_cfg" && ! -L "$_cfg" ]] || { msg "${YELLOW}dnscrypt-proxy config missing after install; DNS was not changed.${NC}"; return 1; }
}

# OBS-S1-02: the stock dnscrypt-proxy.socket shipped by Debian /
# Ubuntu listens on 127.0.2.1:53 (Stream + Datagram). Everything
# downstream in dns_enable_doh is pinned to 127.0.0.1:5353 (menu
# promise, config listen_addresses, probe, resolved DNS=), so the
# guard below used to fail deterministically on such hosts -- after
# the package was already installed and left running. Normalise the
# socket to the pinned address with a drop-in override instead of
# relaxing the guard: relaxing it would also mean re-threading the
# effective listen address through the config, the probe and the
# resolved drop-in, and the promised address would change.
# Returns 0 when socket activation is not in play, when Listen is
# already exactly the pinned pair, or after a successful rebind.
# Returns 1 (fail closed) when Listen cannot be queried, when a
# foreign drop-in already owns the override, or when any systemd
# step fails. Sets the caller's local _doh_dropin_written=1 (bash
# dynamic scoping) iff this call wrote the drop-in file.
dns_normalize_dnscrypt_socket() {
    local _sock_listen='' _dropin_dir='/etc/systemd/system/dnscrypt-proxy.socket.d'
    local _dropin_file="$_dropin_dir/abox-listen.conf" _dtmp=''
    local _listen_norm='' _ln='' _n_listen=0 _seen_stream=0 _seen_dgram=0 _bad_listen=0
    systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null || return 0
    _sock_listen=$(systemctl show --property=Listen --value dnscrypt-proxy.socket 2>/dev/null) || return 1
    _listen_norm=$(printf '%s' "$_sock_listen" | sed -e 's/)[[:space:]]*/)\n/g' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _n_listen=$(( _n_listen + 1 ))
        case "$_ln" in
            '127.0.0.1:5353 (Stream)') _seen_stream=1 ;;
            '127.0.0.1:5353 (Datagram)') _seen_dgram=1 ;;
            *) _bad_listen=1 ;;
        esac
    done <<< "$_listen_norm"
    (( _n_listen == 2 && _seen_stream == 1 && _seen_dgram == 1 && _bad_listen == 0 )) && return 0
    # Never clobber an override owned by someone else: a foreign
    # drop-in means the admin pinned the socket deliberately.
    if [[ -f "$_dropin_file" ]]; then
        grep -Fq '# Managed by A-Box' "$_dropin_file" 2>/dev/null || return 1
    fi
    # H-09: install -d -m 755 (same self-heal as apply_host_dns).
    install -d -m 755 "$_dropin_dir" || return 1
    _dtmp=$(mktemp "$_dropin_dir/.abox-listen.XXXXXX") || return 1
    {
        printf '%s\n' '# Managed by A-Box'
        printf '%s\n' '[Socket]'
        printf '%s\n' 'ListenStream='
        printf '%s\n' 'ListenDatagram='
        printf '%s\n' 'ListenStream=127.0.0.1:5353'
        printf '%s\n' 'ListenDatagram=127.0.0.1:5353'
    } > "$_dtmp" || { rm -f -- "$_dtmp"; return 1; }
    chmod 644 "$_dtmp" || { rm -f -- "$_dtmp"; return 1; }
    mv -- "$_dtmp" "$_dropin_file" || { rm -f -- "$_dtmp"; return 1; }
    _doh_dropin_written=1
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        rm -f -- "$_dropin_file"; systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    # The running service holds the old socket FDs; stop it so the
    # restart below hands it the new ones. A stop failure is
    # tolerated: the guard re-validates Listen right after.
    systemctl stop dnscrypt-proxy >/dev/null 2>&1 || true
    if ! systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1; then
        rm -f -- "$_dropin_file"; systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# OBS-S1-02: pre-snapshot failure cleanup for dns_enable_doh. No
# rollback snapshot exists yet at the guard stage, so a bare
# `return 1` used to leave the just-installed proxy running.
# $1: 1 if dnscrypt-proxy was already installed before this run
#     (a pre-existing proxy is left alone -- only this run's
#     residue is removed). $2: 1 if this run wrote the socket
#     drop-in (remove it). Best effort throughout; always returns 0.
dns_doh_cleanup_fresh_proxy() {
    local _pre_installed="${1:-0}" _dropin_written="${2:-0}"
    if [[ "$_dropin_written" == 1 ]]; then
        rm -f -- /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf 2>/dev/null || true
        rmdir /etc/systemd/system/dnscrypt-proxy.socket.d 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        # H-25(3): rebind the socket to the distro default: the running
        # socket still holds 127.0.0.1:5353 until restarted. Only when
        # the proxy predates this run -- a fresh install is stopped and
        # disabled below instead, and restarting it would undo that.
        # An inactive socket stays inactive.
        if [[ "$_pre_installed" == 1 ]] && systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || true; fi
    fi
    if [[ "$_pre_installed" != 1 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop dnscrypt-proxy.socket >/dev/null 2>&1 || true
        systemctl stop dnscrypt-proxy >/dev/null 2>&1 || true
        systemctl disable dnscrypt-proxy.socket >/dev/null 2>&1 || true
        systemctl disable dnscrypt-proxy >/dev/null 2>&1 || true
    fi
    return 0
}

dns_enable_doh() {
    local backend config answer temp rc prompt resolved_major
    local _doh_fr_present _doh_fr_out
    local doh_server="${1:-cloudflare}" doh_label="${2:-Cloudflare}"
    backend=$(dns_backend_detect)
    [[ "$backend" == resolved ]] && command -v systemctl >/dev/null 2>&1 || {
        msg "${YELLOW}$(tprintf dh_backend "$backend")${NC}"
        return 1
    }
    resolved_major=$(systemd_major_version 2>/dev/null || true)
    if [[ ! "$resolved_major" =~ ^[0-9]+$ ]] || (( resolved_major < 247 )); then
        case "${ABOX_LANG:-zh}" in
            en) msg "${YELLOW}DoH via DNS=127.0.0.1:5353 requires systemd-resolved 247 or later; DNS was not changed.${NC}" ;;
            ru) msg "${YELLOW}Для DoH через DNS=127.0.0.1:5353 требуется systemd-resolved версии 247 или новее; DNS не изменён.${NC}" ;;
            fa) msg "${YELLOW}برای DoH از طریق DNS=127.0.0.1:5353، systemd-resolved نسخه 247 یا جدیدتر لازم است؛ DNS تغییر نکرد.${NC}" ;;
            zh-tw) msg "${YELLOW}透過 DNS=127.0.0.1:5353 使用 DoH 需要 systemd-resolved 247 或更高版本；未修改 DNS。${NC}" ;;
            ja)
                msg "${YELLOW}DNS=127.0.0.1:5353 経由で DoH を使用するには systemd-resolved 247 以降が必要です。DNS は変更されていません。${NC}" ;;
            *) msg "${YELLOW}通过 DNS=127.0.0.1:5353 使用 DoH 需要 systemd-resolved 247 或更高版本；未修改 DNS。${NC}" ;;
        esac
        return 1
    fi
    case "${ABOX_LANG:-zh}" in
        en) prompt='Configure Cloudflare DoH through the local proxy at 127.0.0.1:5353? [Y/N]: ' ;;
        ru) prompt='Настроить Cloudflare DoH через локальный прокси 127.0.0.1:5353? [Y/N]: ' ;;
        fa) prompt='Cloudflare DoH از طریق پراکسی محلی 127.0.0.1:5353 تنظیم شود؟ [Y/N]: ' ;;
        zh-tw) prompt='是否配置 Cloudflare DoH，透過本地代理 127.0.0.1:5353 轉發？[Y/N]: ' ;;
        ja)
            prompt='127.0.0.1:5353 のローカルプロキシ経由で Cloudflare DoH を設定しますか？[Y/N]: ' ;;
        *) prompt='是否配置 Cloudflare DoH，通过本地代理 127.0.0.1:5353 转发？[Y/N]: ' ;;
    esac
    if [[ "${ABOX_DOH_YES:-}" == 1 ]]; then answer='y'
    else prompt=${prompt/Cloudflare/$doh_label}; read -r -p "$prompt" answer; fi
    is_yes "$answer" || return 0
    # X-04: install only after user confirmation; the pre-confirm install left
    # dnscrypt-proxy present even on "N", skewing the rollback snapshot.
    # OBS-S1-02: record whether the proxy predates this run, so a
    # pre-snapshot failure can clean up only what this run installed.
    local _doh_pre_installed=0 _doh_dropin_written=0
    command -v dnscrypt-proxy >/dev/null 2>&1 && _doh_pre_installed=1
    dns_install_dnscrypt_proxy || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; msg "${YELLOW}$(tr_msg dh_unavailable)${NC}"; return 1; }
    config='/etc/dnscrypt-proxy/dnscrypt-proxy.toml'
    [[ -f "$config" && ! -L "$config" ]] || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; msg "${RED}$(tr_msg dh_cfg_missing)${NC}"; return 1; }
    # R10-F12-4: a top-level forwarding_rules entry would keep some
    # queries on plaintext forwarding after DoH is enabled. Warn
    # before anything is changed; declining leaves the config
    # untouched (remove the entry by hand, or keep the current DNS).
    # R11E-R2-10-2: the old awk scope check below treated any '['
    # line as a table header (including lines inside multiline
    # strings / nested arrays) and never decoded TOML escapes, so it
    # missed real top-level forwarding_rules entries. With tomllib
    # (Python 3.11+) the check is exact; without it, the awk program
    # is a warning-only fallback -- removal is enforced by the
    # rewriter, never by this pre-check.
    _doh_fr_present=0
    _doh_disable_fr=1
    if _doh_fr_out=$(python3 -I -c 'import sys, tomllib; print("forwarding_rules" in tomllib.load(open(sys.argv[1], "rb")))' "$config" 2>/dev/null); then
        [[ "$_doh_fr_out" == 'True' ]] && _doh_fr_present=1
    elif python3 -I -c 'import tomllib' 2>/dev/null; then
        # tomllib exists but the file did not parse: refuse outright,
        # never warn-and-continue on an unverifiable config.
        msg "${RED}[!] Cannot parse $config as TOML; refusing to enable DoH on an unverifiable config.${NC}"
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        return 1
    elif python3 -I - "$config" <<'PY_DOH_FR_SCAN' 2>/dev/null; then
import re, sys
# 06e-01: Python exists but has no tomllib (Python < 3.11). Scan the
# top-level keys with escape decoding, so an escaped key such as
# "\u0066orwarding_rules" is not missed and then silently removed by
# the rewriter without the warning above. Mirrors the rewriter's
# _parse_key_path for the first segment: bare segments are
# [A-Za-z0-9_-]+, double-quoted segments decode \uXXXX / \UXXXXXXXX
# and the basic escapes, single-quoted segments are literal. A dotted
# key counts by its first segment (forwarding_rules.sub IS a root
# key); a quoted "forwarding_rules.sub" is one segment and does not
# count. Stops at the first '[' line (same scope rule as the awk
# fallback below). Exit 0 on a hit, 1 otherwise; python3 missing
# falls through to the awk branch.
_BASIC = {'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r', '"': '"', '\\': '\\'}

def _decode_basic(raw):
    out = []
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c != '\\':
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            raise ValueError('trailing backslash')
        e = raw[i + 1]
        if e in _BASIC:
            out.append(_BASIC[e])
            i += 2
        elif e == 'u':
            if i + 6 > n:
                raise ValueError('short \\u escape')
            out.append(chr(int(raw[i + 2:i + 6], 16)))
            i += 6
        elif e == 'U':
            if i + 10 > n:
                raise ValueError('short \\U escape')
            out.append(chr(int(raw[i + 2:i + 10], 16)))
            i += 10
        else:
            raise ValueError('unknown escape')
    return ''.join(out)

def _first_segment(line):
    i = 0
    n = len(line)
    while i < n and line[i] in ' \t':
        i += 1
    if i >= n:
        return None
    if line[i] == '"':
        j = i + 1
        parts = []
        while j < n:
            if line[j] == '\\':
                if j + 1 >= n:
                    return None
                parts.append(line[j:j + 2])
                j += 2
                continue
            if line[j] == '"':
                try:
                    return _decode_basic(''.join(parts)), j + 1
                except ValueError:
                    return None
            parts.append(line[j])
            j += 1
        return None
    if line[i] == "'":
        j = line.find("'", i + 1)
        if j == -1:
            return None
        return line[i + 1:j], j + 1
    m = re.match(r'[A-Za-z0-9_-]+', line[i:])
    if m is None:
        return None
    return m.group(0), i + len(m.group(0))

# R46-02: same character scanner as the rewriter below (verbatim
# copy -- keep in sync). A '[' line is a table header only in normal
# state at bracket depth 0, never inside a multiline string or a
# nested array.
_TRIPLE_DQ = '"' * 3
_TRIPLE_SQ = "'" * 3
def _scan_line_chars(seg, state, depth, brace):
    # Scan one line's characters (seg excludes the trailing newline).
    # Returns (state, depth, brace). States: 'normal', 'dq'/'sq'
    # (single-line basic/literal), 'dq_ml'/'sq_ml' (triple-quoted).
    # A '#' outside a string starts a comment: the rest of the line
    # is skipped. Brackets inside strings/comments do not count.
    # A triple-quoted string ends at a run of 3+ quotes: the last
    # three close it, any earlier quotes in the run are content (so
    # four/five-quote endings scan right). Raises ValueError on an
    # unterminated single-line string (a raw newline inside one).
    i = 0
    n = len(seg)
    while i < n:
        c = seg[i]
        if state == 'dq':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                state = 'normal'
                i += 1
                continue
            i += 1
            continue
        if state == 'sq':
            if c == "'":
                state = 'normal'
                i += 1
                continue
            i += 1
            continue
        if state == 'dq_ml':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                j = i
                while j < n and seg[j] == '"':
                    j += 1
                if j - i >= 3:
                    state = 'normal'
                i = j
                continue
            i += 1
            continue
        if state == 'sq_ml':
            if c == "'":
                j = i
                while j < n and seg[j] == "'":
                    j += 1
                if j - i >= 3:
                    state = 'normal'
                i = j
                continue
            i += 1
            continue
        # state == 'normal'
        if c == '#':
            break
        if c == '"':
            if seg.startswith(_TRIPLE_DQ, i):
                state = 'dq_ml'
                i += 3
            else:
                state = 'dq'
                i += 1
            continue
        if c == "'":
            if seg.startswith(_TRIPLE_SQ, i):
                state = 'sq_ml'
                i += 3
            else:
                state = 'sq'
                i += 1
            continue
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
        elif c == '{':
            brace += 1
        elif c == '}':
            brace -= 1
        i += 1
    if state in ('dq', 'sq'):
        raise ValueError('unterminated string')
    return state, depth, brace

def main():
    try:
        f = open(sys.argv[1], 'r', encoding='utf-8', errors='strict')
    except (OSError, ValueError):
        return 1
    # R46-02: the old loop broke at ANY line starting with '[',
    # including one inside a multiline string or a nested array, so
    # a real top-level forwarding_rules after it was missed, the
    # H-25(2) confirmation was skipped, and the rewriter deleted
    # the entry silently (disable_fr defaults to 1). Thread the
    # scanner state through the loop instead. Unparseable input
    # counts as present (fail closed toward asking); the rewriter
    # refuses it anyway.
    _state, _depth, _brace = 'normal', 0, 0
    with f:
        for raw in f:
            line = raw.rstrip('\r\n')
            if _state != 'normal' or _depth > 0 or _brace > 0:
                try:
                    _state, _depth, _brace = _scan_line_chars(line, _state, _depth, _brace)
                except ValueError:
                    return 0
                continue
            s = line.lstrip(' \t')
            if not s or s.startswith('#'):
                pass
            elif s.startswith('['):
                break
            else:
                parsed = _first_segment(line)
                if parsed is not None:
                    seg, end = parsed
                    rest = line[end:].lstrip(' \t')
                    if seg == 'forwarding_rules' and rest[:1] in ('=', '.'):
                        return 0
            try:
                _state, _depth, _brace = _scan_line_chars(line, _state, _depth, _brace)
            except ValueError:
                return 0
    return 1

sys.exit(main())
PY_DOH_FR_SCAN
        # No tomllib (Python < 3.11): the escape-aware scan above
        # matched a top-level forwarding_rules key the awk fallback
        # below cannot see.
        _doh_fr_present=1
    elif awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ { exit }
        /^[[:space:]]*["'"'"']?forwarding_rules["'"'"']?[[:space:]]*=/ { found=1; exit }
        END { exit !found }
    ' "$config"; then
        # No tomllib (Python < 3.11): the awk fallback matched.
        _doh_fr_present=1
    fi
    if [[ "$_doh_fr_present" == 1 ]]; then
        case "${ABOX_LANG:-zh}" in
            en) msg "${YELLOW}Enabling DoH will disable the custom forwarding_rules entry in $config; domains listed there will no longer be forwarded as configured.${NC}"; prompt='Continue and disable forwarding_rules? [Y/N]: ' ;;
            ru) msg "${YELLOW}Включение DoH отключит пользовательскую запись forwarding_rules в $config; домены из неё больше не будут перенаправляться как настроено.${NC}"; prompt='Продолжить и отключить forwarding_rules? [Y/N]: ' ;;
            fa) msg "${YELLOW}فعال‌سازی DoH ورودی سفارشی forwarding_rules در $config را غیرفعال می‌کند؛ دامنه‌های فهرست‌شده دیگر طبق پیکربندی هدایت نمی‌شوند.${NC}"; prompt='ادامه و غیرفعال‌سازی forwarding_rules؟ [Y/N]: ' ;;
            zh-tw) msg "${YELLOW}啟用 DoH 將停用 $config 中的自訂 forwarding_rules 條目；其中列出的網域將不再按原設定轉發。${NC}"; prompt='繼續並停用 forwarding_rules？[Y/N]: ' ;;
            ja) msg "${YELLOW}DoH を有効にすると $config のカスタム forwarding_rules エントリが無効になり、一覧のドメインは設定どおり転送されなくなります。${NC}"; prompt='続行して forwarding_rules を無効にしますか？[Y/N]: ' ;;
            *) msg "${YELLOW}启用 DoH 将停用 $config 中的自定义 forwarding_rules 条目；其中列出的域名将不再按原配置转发。${NC}"; prompt='继续并停用 forwarding_rules？[Y/N]: ' ;;
        esac
        # H-25(2): this consent is independent of ABOX_DOH_YES (that
        # variable only covers the initial "enable DoH?" confirmation
        # above). Declining skips only this step: forwarding_rules
        # stays and the rest of the enable continues.
        if [[ "${ABOX_DOH_DISABLE_FORWARDING_RULES:-}" == 1 ]]; then answer='y'
        elif [[ "${ABOX_DOH_DISABLE_FORWARDING_RULES:-}" == 0 ]]; then answer='n'
        else read -r -p "$prompt" answer; fi
        if is_yes "$answer"; then
            _doh_disable_fr=1
        else
            _doh_disable_fr=0
            msg "${YELLOW}Keeping the forwarding_rules entry; DoH will not apply to the domains listed there. Remove the entry by hand to route them through DoH.${NC}"
        fi
    fi
    # M-09: snapshot BEFORE normalize rebinds the socket: the
    # snapshot must capture the pre-change socket Listen list,
    # drop-in, and service state (normalize stops the service and
    # rewrites the socket). Install is already done above, so the
    # snapshot can still restore the proxy itself.
    # R11-11: capture owner/mode BEFORE any work touches the config.
    local _cfg_meta='' _cfg_uid='' _cfg_gid='' _cfg_mode=''
    _cfg_meta=$(stat -c '%u %g %a' "$config" 2>/dev/null) || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; msg "${RED}[!] Cannot read ownership/mode of $config; refusing to replace it.${NC}"; return 1; }
    read -r _cfg_uid _cfg_gid _cfg_mode <<< "$_cfg_meta"
    [[ "$_cfg_uid" =~ ^[0-9]+$ && "$_cfg_gid" =~ ^[0-9]+$ && "$_cfg_mode" =~ ^[0-7]{3,4}$ ]] || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; msg "${RED}[!] Cannot read ownership/mode of $config; refusing to replace it.${NC}"; return 1; }
    # FINAL-AUDIT fix: stage the new snapshot in a temp dir and verify it
    # is COMPLETE before replacing the old one. The old code ran
    # `rm -rf $DNS_BACKUP_DIR` first, so a mkdir/snapshot failure destroyed
    # the previous rollback snapshot with no way to recover it.
    local _doh_snap_new=""
    _doh_snap_new=$(mktemp -d "${DNS_BACKUP_DIR}.new.XXXXXX") || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; msg "${RED}$(tr_msg dh_snap_staging)${NC}"; return 1; }
    chmod 700 "$_doh_snap_new" || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; rm -rf -- "$_doh_snap_new"; msg "${RED}$(tr_msg dh_snap_staging)${NC}"; return 1; }
    if ! snapshot_dns_state "$_doh_snap_new" || [[ ! -f "$_doh_snap_new/COMPLETE" ]]; then
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        rm -rf -- "$_doh_snap_new"
        msg "${RED}$(tr_msg dh_snap_rollback)${NC}"
        return 1
    fi
    # R11-09: retain a copy of THIS run's pre-change snapshot before
    # the install primitive runs: when a COMPLETE baseline already
    # exists it preserves the baseline and discards the staging dir,
    # so restoring from $DNS_BACKUP_DIR on failure would undo the
    # previous successful DNS change instead of this run's pre-state.
    # Removed after a successful restore and on success; retained
    # (and reported) only when a restore fails.
    local _doh_snap_keep=''
    _doh_snap_keep=$(mktemp -d /tmp/A-Box-doh-snap.XXXXXX) || { dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; rm -rf -- "$_doh_snap_new"; msg "${RED}$(tr_msg dh_snap_install)${NC}"; return 1; }
    if ! chmod 700 "$_doh_snap_keep" 2>/dev/null || ! cp -a "$_doh_snap_new/." "$_doh_snap_keep/" 2>/dev/null || [[ ! -f "$_doh_snap_keep/COMPLETE" ]]; then dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; rm -rf -- "$_doh_snap_new" "$_doh_snap_keep"; msg "${RED}$(tr_msg dh_snap_install)${NC}"; return 1; fi
    # TRAP-5: use the unified snapshot primitive (POSIX mv + pre-move-aside, idempotency,
    # crash-safe pending-swap). Preserves an existing COMPLETE baseline.
    if ! dns_snapshot_install_new "$_doh_snap_new"; then
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        rm -rf -- "$_doh_snap_keep" 2>/dev/null || true
        msg "${RED}$(tr_msg dh_snap_install)${NC}"
        return 1
    fi
    # OBS-S1-02: rebind the stock socket (127.0.2.1:53) to the
    # pinned 127.0.0.1:5353 before the guard validates it.
    if ! dns_normalize_dnscrypt_socket; then
        if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
        msg "${RED}[!] Could not move dnscrypt-proxy.socket to 127.0.0.1:5353; resolver configuration was not switched.${NC}"
        return 1
    fi
    # R11-10: socket activation hands the service the socket's own
    # listen addresses; verify BOTH typed endpoints (Stream for TCP,
    # Datagram for UDP) are exactly 127.0.0.1:5353 before any
    # snapshot or temp file is created. The hardcoded probe below
    # targets 127.0.0.1:5353, so a differently-bound socket would
    # fail only after a full install/restart churn. Empty,
    # unparseable, or mismatched output fails closed.
    if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
        local _sock_listen=''
        _sock_listen=$(systemctl show --property=Listen --value dnscrypt-proxy.socket 2>/dev/null) || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}[!] Cannot query dnscrypt-proxy.socket endpoints; resolver configuration was not switched.${NC}"; return 1; }
        # R14-F12-02: presence is not exclusivity. The socket hands the
        # service every address it listens on (doh_listen='[]' below),
        # so any extra endpoint (e.g. 0.0.0.0:5353) would make the
        # resolver publicly reachable. Require the Listen list to be
        # exactly the two loopback endpoints, in any order: one line per
        # endpoint after normalising separators (systemctl prints one
        # per line; tolerate a space-joined form as well).
        local _listen_norm='' _ln='' _n_listen=0 _seen_stream=0 _seen_dgram=0 _bad_listen=0
        _listen_norm=$(printf '%s' "$_sock_listen" | sed -e 's/)[[:space:]]*/)\n/g' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            _n_listen=$(( _n_listen + 1 ))
            case "$_ln" in
                '127.0.0.1:5353 (Stream)') _seen_stream=1 ;;
                '127.0.0.1:5353 (Datagram)') _seen_dgram=1 ;;
                *) _bad_listen=1 ;;
            esac
        done <<< "$_listen_norm"
        if (( _n_listen != 2 || _seen_stream != 1 || _seen_dgram != 1 || _bad_listen != 0 )); then
            if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
            msg "${RED}[!] dnscrypt-proxy.socket must listen on exactly 127.0.0.1:5353 (Stream and Datagram); resolver configuration was not switched. Effective Listen: ${_sock_listen:-none} -- correct the socket configuration or disable socket activation.${NC}"
            return 1
        fi
    fi
    temp=$(umask 077; mktemp /tmp/A-Box-doh.XXXXXX) || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_cfg_temp)${NC}"; return 1; }
    # R8C12-N02: under socket activation the socket unit binds
    # the address; the service must inherit it (empty list).
    local doh_listen="['127.0.0.1:5353']"
    if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
        doh_listen='[]'
    fi
    # R29-OBS-S1-02: dnscrypt-proxy 2.0.x does not know the
    # `bootstrap_resolvers` key (renamed from `fallback_resolvers`
    # in 2.1.0); writing it makes `-check` fail with
    # `[FATAL] Unsupported key in configuration file` (rc=255) on
    # stock Ubuntu 24.04 (2.0.45). Probe the installed version and
    # pass a flag to the rewriter below, which writes the key the
    # binary understands. Unparseable output fails closed before
    # any config is touched (the _doh_snap_keep staging copy is
    # discarded; the installed snapshot stays a valid rollback).
    local _dcrypt_ver='' _dcrypt_major='' _dcrypt_minor='' _dcrypt_bootstrap=0
    _dcrypt_ver=$(dnscrypt-proxy --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
    if [[ "$_dcrypt_ver" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
        _dcrypt_major="${BASH_REMATCH[1]}"
        _dcrypt_minor="${BASH_REMATCH[2]}"
    else
        msg "${RED}[!] Cannot determine dnscrypt-proxy version; DNS was not changed.${NC}"
        if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
        return 1
    fi
    if (( _dcrypt_major > 2 || (_dcrypt_major == 2 && _dcrypt_minor >= 1) )); then
        _dcrypt_bootstrap=1
    fi
    python3 -I - "$config" "$temp" "$doh_server" "$doh_listen" "$_dcrypt_bootstrap" "$_doh_disable_fr" <<'PY_DOH_CONFIG'
import re, sys
source, target = sys.argv[1:3]
server = sys.argv[3] if len(sys.argv) > 3 else 'cloudflare'
listen = sys.argv[4] if len(sys.argv) > 4 else "['127.0.0.1:5353']"
bootstrap = sys.argv[5] if len(sys.argv) > 5 else '1'
# H-25(2): '1' disables forwarding_rules, '0' keeps it (user declined).
disable_fr = sys.argv[6] if len(sys.argv) > 6 else '1'
# R29-OBS-S1-02: `bootstrap_resolvers` exists only since 2.1.0
# (renamed from `fallback_resolvers`); a 2.0.x binary rejects the
# new key with [FATAL] Unsupported key (rc=255). Write the key the
# installed version understands; the values are identical either way.
_bootstrap_key = 'bootstrap_resolvers' if bootstrap == '1' else 'fallback_resolvers'

with open(source, encoding='utf-8') as handle: text = handle.read()

# R11E-R2-10-2: TOML-aware statement scanner. The old line-based scope
# detector treated ANY line starting with '[' as a table header --
# including a '[' line inside a multiline string or a nested array --
# and the key regex never decoded TOML quoted-key escapes, so delete
# and re-check missed the same real top-level forwarding_rules entry
# while the post-rewrite check passed and plaintext forwarding stayed
# live. This scanner walks the document once, tracking string state
# (single-line and triple-quoted basic/literal), comments, and bracket
# / brace depth, and returns real statements with decoded key paths.
# Input that cannot be bounded reliably (unterminated string,
# unbalanced brackets at end of input, malformed key/header) fails
# closed instead of leaving a partial assignment behind.
_TRIPLE_DQ = '"' * 3
_TRIPLE_SQ = "'" * 3
_BASIC_ESCAPES = {
    'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r',
    '"': '"', '\\': '\\',
}


def _decode_basic_escapes(raw):
    # Decode the escape sequences of a basic-string body (without the
    # surrounding quotes): \b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX,
    # plus the multiline line-ending backslash (backslash, optional
    # blanks, newline, and all following whitespace are trimmed).
    # Raises ValueError on an unknown escape (invalid TOML).
    out = []
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c != '\\':
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            raise ValueError('trailing backslash in basic string')
        e = raw[i + 1]
        if e in _BASIC_ESCAPES:
            out.append(_BASIC_ESCAPES[e])
            i += 2
        elif e == 'u':
            if i + 6 > n:
                raise ValueError('short \\u escape')
            out.append(chr(int(raw[i + 2:i + 6], 16)))
            i += 6
        elif e == 'U':
            if i + 10 > n:
                raise ValueError('short \\U escape')
            out.append(chr(int(raw[i + 2:i + 10], 16)))
            i += 10
        elif e in ' \t\r\n':
            # Line-ending backslash (multiline strings only): trim
            # the backslash, the blanks, the newline, and all
            # following whitespace up to the next real character.
            j = i + 1
            while j < n and raw[j] in ' \t':
                j += 1
            if j < n and raw[j] == '\r':
                j += 1
            if j < n and raw[j] == '\n':
                j += 1
                while j < n and raw[j] in ' \t\r\n':
                    j += 1
                i = j
            else:
                raise ValueError('backslash without following newline')
        else:
            raise ValueError('unknown escape \\' + e)
    return ''.join(out)


def _parse_key_path(s, i):
    # Parse a (possibly dotted) key starting at offset i in string s.
    # Returns (path_tuple, end_index) with end_index just past the last
    # segment (trailing blanks skipped). Raises ValueError on a
    # malformed key. Bare segments are [A-Za-z0-9_-]+; quoted segments
    # are basic (escapes decoded) or literal (raw, no escapes, so a
    # literal '\u0066...' is a DIFFERENT key from 'f...').
    segments = []
    n = len(s)
    while True:
        while i < n and s[i] in ' \t':
            i += 1
        if i >= n:
            raise ValueError('key with no terminator')
        if s[i] == '"':
            j = i + 1
            parts = []
            closed = False
            while j < n:
                if s[j] == '\\':
                    if j + 1 >= n:
                        raise ValueError('bad escape in quoted key')
                    parts.append(s[j:j + 2])
                    j += 2
                    continue
                if s[j] == '"':
                    closed = True
                    j += 1
                    break
                parts.append(s[j])
                j += 1
            if not closed:
                raise ValueError('unterminated quoted key')
            segments.append(_decode_basic_escapes(''.join(parts)))
            i = j
        elif s[i] == "'":
            j = s.find("'", i + 1)
            if j == -1:
                raise ValueError('unterminated quoted key')
            segments.append(s[i + 1:j])
            i = j + 1
        else:
            m = re.match(r'[A-Za-z0-9_-]+', s[i:])
            if m is None:
                raise ValueError('bad key character %r' % s[i])
            segments.append(m.group(0))
            i += len(m.group(0))
        while i < n and s[i] in ' \t':
            i += 1
        if i < n and s[i] == '.':
            i += 1
            continue
        return tuple(segments), i


def _scan_line_chars(seg, state, depth, brace):
    # Scan one line's characters (seg excludes the trailing newline).
    # Returns (state, depth, brace). States: 'normal', 'dq'/'sq'
    # (single-line basic/literal), 'dq_ml'/'sq_ml' (triple-quoted).
    # A '#' outside a string starts a comment: the rest of the line
    # is skipped. Brackets inside strings/comments do not count.
    # A triple-quoted string ends at a run of 3+ quotes: the last
    # three close it, any earlier quotes in the run are content (so
    # four/five-quote endings scan right). Raises ValueError on an
    # unterminated single-line string (a raw newline inside one).
    i = 0
    n = len(seg)
    while i < n:
        c = seg[i]
        if state == 'dq':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                state = 'normal'
                i += 1
                continue
            i += 1
            continue
        if state == 'sq':
            if c == "'":
                state = 'normal'
                i += 1
                continue
            i += 1
            continue
        if state == 'dq_ml':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                j = i
                while j < n and seg[j] == '"':
                    j += 1
                if j - i >= 3:
                    state = 'normal'
                i = j
                continue
            i += 1
            continue
        if state == 'sq_ml':
            if c == "'":
                j = i
                while j < n and seg[j] == "'":
                    j += 1
                if j - i >= 3:
                    state = 'normal'
                i = j
                continue
            i += 1
            continue
        # state == 'normal'
        if c == '#':
            break
        if c == '"':
            if seg.startswith(_TRIPLE_DQ, i):
                state = 'dq_ml'
                i += 3
            else:
                state = 'dq'
                i += 1
            continue
        if c == "'":
            if seg.startswith(_TRIPLE_SQ, i):
                state = 'sq_ml'
                i += 3
            else:
                state = 'sq'
                i += 1
            continue
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
        elif c == '{':
            brace += 1
        elif c == '}':
            brace -= 1
        i += 1
    if state in ('dq', 'sq'):
        raise ValueError('unterminated string')
    return state, depth, brace

def _scan_text(text):
    # Returns a list of statements. Each is a dict:
    #   kind: 'kv' | 'table' | 'array_table'
    #   path: tuple of decoded key segments
    #   scope: enclosing table path, or None at top level (kv only)
    #   start_off, end_off: char offsets of the whole-line span
    #     (start of the first line to start of the line after the last)
    #   start_line, end_line: 0-based line indexes, end exclusive
    #   value_text: raw value text for kv (no trailing newline)
    # A '[' line is a table header ONLY when seen in normal state at
    # bracket depth 0 at a line start -- never inside a multiline
    # string or a nested array. Raises ValueError on input that cannot
    # be bounded reliably.
    # 06e-02: TOML lines end only at LF (CRLF keeps the \r).
    # str.splitlines() also splits on U+2028/U+2029 and other Unicode
    # boundaries, so a legal comment containing U+2028 was cut into a
    # second segment with no '=' and raised ValueError below. Split
    # on '\n' only; ''.join(lines) == text is preserved.
    parts = text.split('\n')
    lines = [p + '\n' for p in parts[:-1]]
    if parts[-1] != '':
        lines.append(parts[-1])
    line_start = []
    off = 0
    for ln in lines:
        line_start.append(off)
        off += len(ln)
    statements = []
    state = 'normal'
    depth = 0
    brace = 0
    cur = None       # open kv statement being built, or None
    cur_scope = None # path of the enclosing table, or None
    i = 0
    while i < len(lines):
        raw = lines[i]
        seg = raw.rstrip('\r\n')
        if cur is not None or state in ('dq_ml', 'sq_ml') or depth > 0 or brace > 0:
            # Continuation of an open multiline value/string: this line
            # is value content, never a new statement or a header.
            state, depth, brace = _scan_line_chars(seg, state, depth, brace)
            if depth < 0 or brace < 0:
                raise ValueError('unbalanced brackets')
            if state == 'normal' and depth == 0 and brace == 0:
                cur['end_line'] = i + 1
                cur['end_off'] = line_start[i] + len(raw)
                cur['value_text'] = text[cur['value_off']:cur['end_off']].rstrip('\r\n')
                statements.append(cur)
                cur = None
            i += 1
            continue
        # Fresh line: blank, comment, header, or key = value.
        stripped = seg.lstrip()
        if stripped == '' or stripped.startswith('#'):
            i += 1
            continue
        if stripped[0] == '[':
            is_array = stripped.startswith('[[')
            inner = stripped[2:] if is_array else stripped[1:]
            path, end = _parse_key_path(inner, 0)
            rest = inner[end:]
            close = ']]' if is_array else ']'
            if not rest.startswith(close):
                raise ValueError('malformed table header')
            tail = rest[len(close):].lstrip(' \t')
            if tail != '' and not tail.startswith('#'):
                raise ValueError('trailing content after table header')
            statements.append({
                'kind': 'array_table' if is_array else 'table',
                'path': path, 'scope': None,
                'start_off': line_start[i], 'end_off': line_start[i] + len(raw),
                'start_line': i, 'end_line': i + 1, 'value_text': None,
            })
            cur_scope = path
            i += 1
            continue
        # Key = value. Parse the key path from the first non-blank char.
        key_start = len(seg) - len(stripped)
        path, end = _parse_key_path(seg, key_start)
        if end >= len(seg) or seg[end] != '=':
            raise ValueError('expected "=" after key')
        rel_value_off = end + 1
        cur = {
            'kind': 'kv', 'path': path, 'scope': cur_scope,
            'start_off': line_start[i], 'end_off': None,
            'start_line': i, 'end_line': None, 'value_text': None,
            'value_off': line_start[i] + rel_value_off,
        }
        state, depth, brace = _scan_line_chars(seg[rel_value_off:], state, depth, brace)
        if depth < 0 or brace < 0:
            raise ValueError('unbalanced brackets')
        if state == 'normal' and depth == 0 and brace == 0:
            cur['end_line'] = i + 1
            cur['end_off'] = line_start[i] + len(raw)
            cur['value_text'] = text[cur['value_off']:cur['end_off']].rstrip('\r\n')
            statements.append(cur)
            cur = None
        i += 1
    if state in ('dq_ml', 'sq_ml'):
        raise ValueError('unterminated multiline string')
    if depth > 0 or brace > 0 or cur is not None:
        raise ValueError('unterminated value')
    return statements


def _scan_or_fail():
    # Fresh scan of the current text; unparseable input fails closed.
    try:
        return _scan_text(text)
    except ValueError as _e:
        sys.stderr.write('cannot parse config as TOML: %s\n' % _e)
        sys.exit(1)


def _top_level_has_option(name):
    # Same-scope presence check for the post-rewrite verification: a
    # same-named key under a [table] must not be misread as a
    # top-level entry (a plain full-text grep would misjudge it). A
    # dotted key counts (forwarding_rules.sub IS a root
    # forwarding_rules key); a quoted "forwarding_rules.sub" is one
    # literal segment and does not count.
    for st in _scan_or_fail():
        if st['path'] and st['path'][0] == name:
            if st['kind'] == 'kv' and st['scope'] is None:
                return True
            if st['kind'] in ('table', 'array_table'):
                return True
    return False


def _top_level_option_canonical(name):
    # Raw value text of the single top-level statement whose key path
    # is exactly (name,), or None. Fresh scan; never reuses indexes.
    for st in _scan_or_fail():
        if st['kind'] == 'kv' and st['scope'] is None and st['path'] == (name,):
            return st['value_text']
    return None


def set_option(name, value):
    global text
    stmts = _scan_or_fail()
    targets = []
    first_header_off = None
    for st in stmts:
        if st['kind'] in ('table', 'array_table') and first_header_off is None:
            first_header_off = st['start_off']
        if st['scope'] is not None:
            continue
        if st['path'] and st['path'][0] == name:
            if st['kind'] == 'kv' and st['path'] == (name,):
                targets.append(st)
            else:
                # A dotted `name.sub` or a `[name]` table would
                # conflict with a plain assignment: fail closed.
                sys.stderr.write("conflicting definition of '%s'\n" % name)
                sys.exit(1)
    if len(targets) > 1:
        sys.stderr.write("duplicate definition of '%s'\n" % name)
        sys.exit(1)
    if targets:
        st = targets[0]
        text = text[:st['start_off']] + name + ' = ' + value + '\n' + text[st['end_off']:]
    else:
        # Insert before the first table header: appending at end of file
        # would land a top-level option inside the last [table].
        if first_header_off is not None:
            text = text[:first_header_off] + name + ' = ' + value + '\n' + text[first_header_off:]
        else:
            if text and not text.endswith('\n'):
                text += '\n'
            text += name + ' = ' + value + '\n'


def remove_option(name):
    # R10-F12-4: delete a top-level option entry (complete assignment
    # span), or do nothing when it is absent. Shares the top-level
    # scope rule with set_option; unlike set_option it never inserts.
    # Deletes ALL top-level statements whose first key segment matches
    # (a dotted `name.sub` is two segments; a quoted "name.sub" is
    # one literal segment and is kept). A `[name]` table header is
    # deleted together with its whole scope, or its entries would be
    # orphaned into the top level.
    global text
    stmts = _scan_or_fail()
    spans = []
    i = 0
    while i < len(stmts):
        st = stmts[i]
        if st['kind'] == 'kv' and st['scope'] is None and st['path'] and st['path'][0] == name:
            spans.append((st['start_off'], st['end_off']))
            i += 1
        elif st['kind'] in ('table', 'array_table') and st['path'] and st['path'][0] == name:
            j = i + 1
            while j < len(stmts) and stmts[j]['kind'] not in ('table', 'array_table'):
                j += 1
            end = stmts[j]['start_off'] if j < len(stmts) else len(text)
            spans.append((st['start_off'], end))
            i = j
        else:
            i += 1
    for s, e in reversed(spans):
        text = text[:s] + text[e:]


set_option('server_names', "['%s']" % server)
set_option('listen_addresses', listen)
set_option('dnscrypt_servers', 'false')
set_option('doh_servers', 'true')
set_option('ipv4_servers', 'true')
set_option('ipv6_servers', 'false')
if bootstrap == '1':
    set_option('bootstrap_resolvers', "['9.9.9.9:53', '1.1.1.1:53']")
else:
    # Drop a stale new-style key first: on 2.0.x it would break
    # -check even if the old-style key is written alongside it.
    remove_option('bootstrap_resolvers')
    set_option('fallback_resolvers', "['9.9.9.9:53', '1.1.1.1:53']")
set_option('ignore_system_dns', 'true')
# R10-F12-4: a top-level forwarding_rules entry would keep matching
# domains on plaintext forwarding after DoH is enabled. Remove the
# entry (the rules file itself is left alone, and the pre-change
# snapshot stays available for rollback).
if disable_fr == '1':
    remove_option('forwarding_rules')
# R11E-R2-10-2: final verification, independent of the mutation passes
# above (fresh scan; never reuses indexes from set/remove). With
# tomllib (Python 3.11+) verify the parsed document; without it,
# re-scan with the statement scanner and compare canonical value text
# (whitespace-insensitive; managed values are single-line canonical
# after set_option, so a trailing comment cannot survive on them).
_expected_values = {
    'server_names': "['%s']" % server,
    'listen_addresses': listen,
    'dnscrypt_servers': 'false',
    'doh_servers': 'true',
    'ipv4_servers': 'true',
    'ipv6_servers': 'false',
    _bootstrap_key: "['9.9.9.9:53', '1.1.1.1:53']",
    'ignore_system_dns': 'true',
}
try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib is not None:
    try:
        _doc = tomllib.loads(text)
    except Exception as _e:
        sys.stderr.write('rewritten config is not valid TOML: %s\n' % _e)
        sys.exit(1)
    if disable_fr == '1' and 'forwarding_rules' in _doc:
        sys.stderr.write('forwarding_rules still present at top level after rewrite\n')
        sys.exit(1)
    _expected_doc = {
        'server_names': [server],
        'listen_addresses': tomllib.loads('x = ' + listen)['x'],
        'dnscrypt_servers': False,
        'doh_servers': True,
        'ipv4_servers': True,
        'ipv6_servers': False,
        _bootstrap_key: ['9.9.9.9:53', '1.1.1.1:53'],
        'ignore_system_dns': True,
    }
    for _k, _want in _expected_doc.items():
        if _doc.get(_k) != _want:
            sys.stderr.write('option %s has unexpected value %r (want %r)\n' % (_k, _doc.get(_k), _want))
            sys.exit(1)
    if bootstrap != '1' and 'bootstrap_resolvers' in _doc:
        sys.stderr.write('bootstrap_resolvers must be absent on dnscrypt-proxy < 2.1\n')
        sys.exit(1)
else:
    if disable_fr == '1' and _top_level_has_option('forwarding_rules'):
        sys.stderr.write('forwarding_rules still present at top level after rewrite\n')
        sys.exit(1)
    for _k, _want in _expected_values.items():
        _got = _top_level_option_canonical(_k)
        if _got is None or ''.join(_got.split()) != ''.join(_want.split()):
            sys.stderr.write('option %s has unexpected value %r (want %r)\n' % (_k, _got, _want))
            sys.exit(1)
    if bootstrap != '1' and _top_level_has_option('bootstrap_resolvers'):
        sys.stderr.write('bootstrap_resolvers must be absent on dnscrypt-proxy < 2.1\n')
        sys.exit(1)
with open(target, 'w', encoding='utf-8') as handle: handle.write(text)
PY_DOH_CONFIG
    rc=$?
    if (( rc != 0 )); then rm -f -- "$temp"; if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_cfg_rewrite)${NC}"; return 1; fi
    # R1-12-F7: preserve the original mode (a 0640 credential
    # file must not be loosened to 0644 by the rewrite).
    install -o "$_cfg_uid" -g "$_cfg_gid" -m "$_cfg_mode" "$temp" "$config" || { rm -f -- "$temp"; if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_cfg_install)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
    rm -f -- "$temp"
    if ! dnscrypt-proxy -config "$config" -check >/dev/null 2>&1; then
        if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
        msg "${RED}$(tr_msg dh_cfg_check)${NC}"
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        return 1
    fi
    # enable --now is a no-op on an already-running instance, which
    # would keep serving the old config; restart a live instance so
    # the new config is really loaded before probing it.
    if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
        systemctl enable dnscrypt-proxy >/dev/null 2>&1 || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_proxy_enable)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
        systemctl restart dnscrypt-proxy >/dev/null 2>&1 || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_proxy_restart)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
    else
        systemctl enable --now dnscrypt-proxy >/dev/null 2>&1 || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_proxy_enable)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
    fi
    # R10-F12-4: this probe is an availability check only (the local
    # proxy answers); it does not prove queries travel over DoH. The
    # forwarding_rules entry is disabled by the rewrite above and
    # verified absent before install, which is the actual gate.
    # R2C12-10: retry the probe (cold start needs a few
    # seconds); rollback only if every attempt fails.
    local _probe_ok=0 _probe_i=0
    while (( _probe_i < 5 )); do
        if dns_probe_once 127.0.0.1 5353 example.com >/dev/null 2>&1; then _probe_ok=1; break; fi
        _probe_i=$(( _probe_i + 1 ))
        (( _probe_i < 5 )) && sleep 2
    done
    if (( _probe_ok == 0 )); then
        if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
        msg "${RED}$(tr_msg dh_test_resolve)${NC}"
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        return 1
    fi
    resolved_strip_global_dns_sources || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg apply_host_dns_clear_sources_failed)${NC}"; return 1; }
    # H-09: ensure resolved.conf.d exists at 0755 before the drop-in
    # write (install -d also repairs an existing 0700 dir left by the
    # old umask 077 leak; the atomic writer's mkdir -p cannot).
    install -d -m 755 /etc/systemd/resolved.conf.d || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_dropin_write)${NC}"; return 1; }
    write_file_atomically_from_stdin /etc/systemd/resolved.conf.d/99-abox-dns.conf 644 <<'EOF_DOH' || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_dropin_write)${NC}"; return 1; }
# Managed by A-Box
[Resolve]
DNS=127.0.0.1:5353
FallbackDNS=
Domains=~.
DNSOverTLS=no
EOF_DOH
    systemctl restart systemd-resolved >/dev/null 2>&1 || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(tr_msg dh_resolved_restart)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
    resolved_global_dns_check '127.0.0.1:5353' 'doh_search_warn' || { if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi; msg "${RED}$(resolved_dns_check_fail_message)${NC}"; dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"; return 1; }
    if resolvectl query example.com >/dev/null 2>&1; then
        if ! write_file_atomically_from_stdin "$DNS_STATE_FILE" 600 <<< 'backend=resolved;mode=doh;proxy=dnscrypt-proxy'; then
            if restore_dns_snapshot "$_doh_snap_keep"; then
                rm -rf -- "$_doh_snap_keep" 2>/dev/null || true
                systemctl restart systemd-resolved >/dev/null 2>&1 || true
                msg "${RED}$(tr_msg dh_meta_commit)${NC}"
            else
                msg "${RED}$(tprintf dh_meta_commit_fail "$_doh_snap_keep")${NC}"
            fi
            dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
            return 1
        fi
        msg "${GREEN}$(tr_msg dh_ok)${NC}"
        msg "${YELLOW}$(tr_msg dh_note)${NC}"
        if [[ -n "${RESOLVED_DNS_CHECK_WARN:-}" ]]; then
            msg "${YELLOW}$(resolved_dns_check_warn_message)${NC}"
        fi
        # M-NEW-01: refresh the rollback baseline ONLY when this run's
        # pre-deploy state is not already a clean A-Box DoH state. A
        # pure re-deploy over a live DoH install changes nothing, so
        # the baseline (the pre-change state) must stay put; overwriting
        # it with the live DoH state would make a later rollback a no-op.
        if ! dns_snapshot_is_clean_doh_state "$_doh_snap_keep"; then
            if ! dns_snapshot_refresh_baseline "$_doh_snap_keep"; then
                if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
                msg "${RED}[!] Could not refresh the DNS rollback snapshot; the DoH change was rolled back.${NC}"
                return 1
            fi
        fi
        rm -rf -- "$_doh_snap_keep" 2>/dev/null || true
    else
        if restore_dns_snapshot "$_doh_snap_keep"; then rm -rf -- "$_doh_snap_keep" || true; else msg "${RED}[!] $(tr_msg rollback_copy_fail): $_doh_snap_keep${NC}"; fi
        msg "${RED}$(tr_msg dh_resolved_health)${NC}"
        dns_doh_cleanup_fresh_proxy "$_doh_pre_installed" "$_doh_dropin_written"
        return 1
    fi
}

