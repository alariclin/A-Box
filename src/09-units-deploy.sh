# ABOX-MODULE-BEGIN 09-units-deploy service units, protocol inventory, deploy entry
#   Source: install.sh lines 38402-42574 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
disable_traffic_monitor() {
    remove_abox_cron_block TRAFFIC || return 1
    remove_owned_runtime_helper "$ABOX_DIR/traffic_monitor.sh" || return 1
    clear_traffic_block_period || return 1
}

traffic_snapshot_file_hash() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
}

capture_traffic_env_state_file() {
    local source_file="$1" out="$2"
    # Symlink: reject (security, unchanged).
    [[ ! -L "$source_file" ]] || return 1
    # Missing env file: fresh system where no core was installed yet; treat as
    # "no traffic limit configured" instead of a fatal error.
    if [[ ! -e "$source_file" ]]; then
        : > "$out" || return 1
        return 0
    fi
    # 05c2-M2: a present but non-regular file (directory, FIFO, ...)
    # is not "missing": snapshotting it as empty would make the
    # caller believe no limit was configured. Fail instead.
    [[ -f "$source_file" ]] || return 1
    awk '/^TRAFFIC_LIMIT_(GB|MODE)=/{print}' "$source_file" | LC_ALL=C sort > "$out"
}

capture_traffic_optional_state() {
    local source_file="$1" out="$2" hash
    [[ "$out" == /* || "$out" == */* ]] || return 1
    if [[ -e "$source_file" || -L "$source_file" ]]; then
        [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
        hash=$(traffic_snapshot_file_hash "$source_file") || return 1
        printf 'present|%s\n' "$hash" > "$out"
    else
        printf '%s\n' 'absent' > "$out"
    fi
}

traffic_optional_state_matches_expected() {
    local source_file="$1" expected_file="$2" expected='' actual=''
    [[ -f "$expected_file" && ! -L "$expected_file" ]] || return 1
    IFS= read -r expected < "$expected_file" || return 1
    if [[ "$expected" == absent ]]; then
        [[ ! -e "$source_file" && ! -L "$source_file" ]]
        return $?
    fi
    [[ "$expected" == present\|* ]] || return 1
    [[ -f "$source_file" && ! -L "$source_file" ]] || return 2
    actual=$(traffic_snapshot_file_hash "$source_file" 2>/dev/null || true)
    [[ "$actual" == "${expected#present|}" ]]
}

capture_vnstat_runtime_state() {
    local name='' active enabled _st='' _ufs='' _ufs_rc=0 _ru='' _luf=''
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        # 05c2-M3: the old pipeline's exit status was awk's, so a failed
        # query (no output) was indistinguishable from "unit absent" and
        # misreported as absent. List once without a pattern and check
        # ITS return code: a failed listing is a query failure (return 1,
        # fail-closed); only a successful listing with neither name
        # present is absent. (A patterned query exits 1 for "no match"
        # too, so its rc cannot serve as the failure signal.)
        _luf=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null) || return 1
        if awk -v wanted="vnstat.service" '$1 == wanted { found=1 } END { exit !found }' <<< "$_luf"; then
            name=vnstat
        elif awk -v wanted="vnstatd.service" '$1 == wanted { found=1 } END { exit !found }' <<< "$_luf"; then
            name=vnstatd
        else
            printf '%s\n' 'absent'
            return 0
        fi
        # R14-F10-03: a query failure is not "stopped / disabled".
        # is-active --quiet is non-zero both for a confirmed
        # inactive service and for a query failure (e.g. D-Bus
        # down); only a read-back of a known inactive state proves
        # active=0, anything else is unknown ('?') so rollback
        # leaves the service alone.
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            active=1
        else
            _st=$(systemctl is-active "$name" 2>/dev/null) || true
            case "$_st" in
                inactive|failed|activating|deactivating|reloading|maintenance) active=0 ;;
                *) active='?' ;;
            esac
        fi
        # R7C10-02: is-enabled --quiet is 0 for enabled-runtime
        # too, so it cannot distinguish runtime-only from
        # persistent enablement. Read the verbatim UnitFileState.
        # R14-F10-03: a failed / empty read is unknown ('?'), not
        # disabled; only a successful read of a non-enabled state is 0.
        _ufs=$(systemctl show -p UnitFileState --value "$name" 2>/dev/null); _ufs_rc=$?
        if (( _ufs_rc != 0 )) || [[ -z "$_ufs" ]]; then
            enabled='?'
        else
            case "$_ufs" in
                enabled) enabled=1 ;;
                enabled-runtime) enabled=2 ;;
                *) enabled=0 ;;
            esac
        fi
        printf 'systemd|%s|%s|%s\n' "$name" "$active" "$enabled"
    elif [[ "${INIT_SYS:-}" == openrc ]] && command -v rc-service >/dev/null 2>&1; then
        [[ -x /etc/init.d/vnstatd ]] || { printf '%s\n' 'absent'; return 0; }
        # R14-F10-03: same unknown-state rule as the systemd branch
        # above: only a read-back of a known stopped state proves
        # active=0; a failed / silent query is unknown ('?').
        if rc-service vnstatd status >/dev/null 2>&1; then
            active=1
        else
            _st=$(rc-service vnstatd status 2>/dev/null) || true
            case "$_st" in
                *'status: stopped'*|*'is stopped'*|*'not running'*) active=0 ;;
                *) active='?' ;;
            esac
        fi
        # R14-F10-03: a failed rc-update show is unknown ('?'), not
        # "not enabled"; only a successful listing proves 0/1.
        if ! _ru=$(rc-update show default 2>/dev/null); then
            enabled='?'
        elif grep -Eq '(^|[[:space:]])vnstatd([[:space:]]|$)' <<< "$_ru"; then
            enabled=1
        else
            enabled=0
        fi
        printf 'openrc|vnstatd|%s|%s\n' "$active" "$enabled"
    else
        return 1
    fi
}

# FINAL-AUDIT fix: the old hard requirement that the CURRENT state be 1|1
# caused false rollback failures (e.g. pre-state 0|1 restored correctly, but
# the gate demanded 1|1). Conflict detection (current vs recorded post-state)
# is done by the caller in preflight; this function only restores the given
# pre-state.
restore_vnstat_runtime_state() {
    local state="$1" kind name active enabled
    IFS='|' read -r kind name active enabled <<< "$state"
    case "$kind" in
        absent) return 0 ;;
        systemd)
            # R14-F10-03: an unknown ('?') field is left untouched;
            # only a known pre-state is restored.
            case "$enabled" in
                1) systemctl enable "$name" >/dev/null 2>&1 || return 1 ;;
                2) systemctl disable "$name" >/dev/null 2>&1 || return 1; systemctl enable --runtime "$name" >/dev/null 2>&1 || return 1 ;;
                '?') : ;;
                *) systemctl disable "$name" >/dev/null 2>&1 || return 1 ;;
            esac
            case "$active" in
                1) systemctl start "$name" >/dev/null 2>&1 || systemctl restart "$name" >/dev/null 2>&1 || return 1 ;;
                '?') : ;;
                *) systemctl stop "$name" >/dev/null 2>&1 || return 1 ;;
            esac
            ;;
        openrc)
            # R14-F10-03: an unknown ('?') field is left untouched.
            case "$enabled" in
                1) rc-update add "$name" default >/dev/null 2>&1 || return 1 ;;
                '?') : ;;
                # R36b-M1: a failed listing is unknown, not "not in
                # default" -- the capture side (R14-F10-03) already
                # records it as '?'; silently skipping the del here
                # returned success with the known enabled=0 un-restored.
                *) _ru=$(rc-update show default 2>/dev/null) || return 1
                   if grep -Eq "(^|[[:space:]])${name}([[:space:]]|$)" <<< "$_ru"; then rc-update del "$name" default >/dev/null 2>&1 || return 1; fi ;;
            esac
            case "$active" in
                1) rc-service "$name" start >/dev/null 2>&1 9>&- 10>&- || rc-service "$name" restart >/dev/null 2>&1 9>&- 10>&- || return 1 ;;
                '?') : ;;
                *) rc-service "$name" stop >/dev/null 2>&1 || return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    return 0
}

# FINAL-AUDIT fix: undo a vnstat installation performed by the current
# transaction. Stops and disables the service; removes the package ONLY if
# the transaction installed it (pre.vnstat.binary == 0). Never removes a
# package that pre-existed, as other tools may depend on it.
rollback_newly_installed_vnstat() {
    local tx_dir="$1" svc_name="" _rc=0
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        if systemctl list-unit-files --type=service --no-legend vnstat.service 2>/dev/null | awk -v wanted="vnstat.service" '$1 == wanted { found=1 } END { exit !found }' ; then svc_name=vnstat
        elif systemctl list-unit-files --type=service --no-legend vnstatd.service 2>/dev/null | awk -v wanted="vnstatd.service" '$1 == wanted { found=1 } END { exit !found }' ; then svc_name=vnstatd
        fi
        # 05d-M2: a missing service unit must not skip the package
        # cleanup below. The package may have been installed by this
        # transaction even though its unit never registered (or was
        # removed by another actor); only the stop/disable is skipped
        # when there is no unit to act on.
        if [[ -n "$svc_name" ]]; then
            systemctl stop "$svc_name" >/dev/null 2>&1 || _rc=1
            systemctl disable "$svc_name" >/dev/null 2>&1 || _rc=1
        fi
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        if [[ -x /etc/init.d/vnstatd ]]; then
            rc-service vnstatd stop >/dev/null 2>&1 || _rc=1
            rc-update del vnstatd default >/dev/null 2>&1 || _rc=1
        fi
    else
        return 0
    fi
    # Only uninstall the package if this transaction installed it.
    local pre_binary=1
    [[ -f "$tx_dir/pre.vnstat.binary" ]] && IFS= read -r pre_binary < "$tx_dir/pre.vnstat.binary" 2>/dev/null || pre_binary=1
    if [[ "$pre_binary" == 0 ]]; then
        remove_optional_package vnstat 2>/dev/null || _rc=1
    fi
    return "$_rc"
}

traffic_restore_cron_block() {
    local pre_file="$1" expected_block="$2" current tmp stripped rc=0
    current=$(umask 077; mktemp /tmp/A-Box-traffic-cron-current.XXXXXX) || return 1
    tmp=$(umask 077; mktemp /tmp/A-Box-traffic-cron-restore.XXXXXX) || { rm -f -- "$current"; return 1; }
    if ! read_crontab_to_file "$current"; then rm -f -- "$current" "$tmp"; return 1; fi
    stripped=$(umask 077; mktemp /tmp/A-Box-traffic-cron-stripped.XXXXXX) || { rm -f -- "$current" "$tmp"; return 1; }
    if ! strip_abox_cron_blocks_from_file "$current" "$stripped" TRAFFIC; then rm -f -- "$current" "$tmp" "$stripped"; return 1; fi
    local current_block
    current_block=$(awk 'BEGIN{p=0} $0=="# A-Box TRAFFIC BEGIN"{p=1} p{print} $0=="# A-Box TRAFFIC END"{exit}' "$current")
    if [[ -n "$expected_block" ]]; then
        [[ "$current_block" == "$expected_block" ]] || { rm -f -- "$current" "$tmp" "$stripped"; return 2; }
    else
        [[ -z "$current_block" ]] || { rm -f -- "$current" "$tmp" "$stripped"; return 2; }
    fi
    cat "$stripped" > "$tmp" || { rm -f -- "$current" "$tmp" "$stripped"; return 1; }
    if [[ -s "$pre_file" ]]; then cat "$pre_file" >> "$tmp" || { rm -f -- "$current" "$tmp" "$stripped"; return 1; }; fi
    if commit_crontab_if_unchanged "$current" "$tmp"; then
        rc=0
    else
        rc=$?
    fi
    rm -f -- "$current" "$tmp" "$stripped"
    return "$rc"
}

capture_traffic_quota_expected_state() {
    local tx_dir="$1" current monitor_hash
    [[ -d "$tx_dir" && ! -L "$tx_dir" ]] || return 1
    capture_traffic_env_state_file "$ABOX_ENV" "$tx_dir/post-traffic.env" || return 1
    capture_traffic_optional_state "$ABOX_DESIRED_STATE" "$tx_dir/post.desired" || return 1
    capture_traffic_optional_state "$ABOX_TRAFFIC_BLOCK_STATE" "$tx_dir/post.block" || return 1
    # C-06: Capture pair-state so rollback can detect external changes.
    capture_traffic_optional_state "$ABOX_TRAFFIC_PAIR_STATE" "$tx_dir/post.pair" || return 1
    current=$(umask 077; mktemp /tmp/A-Box-traffic-postcron.XXXXXX) || return 1
    read_crontab_to_file "$current" || { rm -f -- "$current"; return 1; }
    awk 'BEGIN{p=0} $0=="# A-Box TRAFFIC BEGIN"{p=1} p{print} $0=="# A-Box TRAFFIC END"{exit}' "$current" > "$tx_dir/post.cron.traffic" || { rm -f -- "$current"; return 1; }
    rm -f -- "$current"
    if [[ -e "$ABOX_DIR/traffic_monitor.sh" || -L "$ABOX_DIR/traffic_monitor.sh" ]]; then
        [[ -f "$ABOX_DIR/traffic_monitor.sh" && ! -L "$ABOX_DIR/traffic_monitor.sh" ]] || return 1
        auxiliary_content_is_abox_managed "$ABOX_DIR/traffic_monitor.sh" /etc/ddr/traffic_monitor.sh || return 1
        monitor_hash=$(traffic_snapshot_file_hash "$ABOX_DIR/traffic_monitor.sh") || return 1
        printf '%s\n' "$monitor_hash" > "$tx_dir/post.monitor.hash" || return 1
    else
        printf '%s\n' none > "$tx_dir/post.monitor.hash" || return 1
    fi
    if ! capture_vnstat_runtime_state > "$tx_dir/post.vnstat"; then
        return 1
    fi
}

traffic_quota_transaction_rollback() {
    local tx_dir="$1" rc=0 current_monitor='' expected_monitor='' pre_monitor=0 current_block='' expected_block='' cron_rc=0 vnstat_state='' expected_vnstat='' current_state current_traffic_env current_vnstat
    [[ -d "$tx_dir" && ! -L "$tx_dir" ]] || return 2

    # Establish every expected post-state before changing anything. This prevents
    # rollback from overwriting state changed by another actor after provisioning.
    if [[ -f "$tx_dir/post-traffic.env" ]]; then
        current_traffic_env=$(umask 077; mktemp /tmp/A-Box-traffic-current-env.XXXXXX) || return 2
        if ! capture_traffic_env_state_file "$ABOX_ENV" "$current_traffic_env" || ! cmp -s "$current_traffic_env" "$tx_dir/post-traffic.env"; then
            rm -f -- "$current_traffic_env"
            printf '%s\n' "A-Box traffic rollback conflict: traffic quota environment changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        fi
        rm -f -- "$current_traffic_env"
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected quota environment; recovery state preserved at $tx_dir" >&2
        return 2
    fi
    if [[ -f "$tx_dir/post.desired" ]]; then
        traffic_optional_state_matches_expected "$ABOX_DESIRED_STATE" "$tx_dir/post.desired" || {
            printf '%s\n' "A-Box traffic rollback conflict: desired state changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        }
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected desired state; recovery state preserved at $tx_dir" >&2
        return 2
    fi
    if [[ -f "$tx_dir/post.block" ]]; then
        traffic_optional_state_matches_expected "$ABOX_TRAFFIC_BLOCK_STATE" "$tx_dir/post.block" || {
            printf '%s\n' "A-Box traffic rollback conflict: traffic block state changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        }
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected block state; recovery state preserved at $tx_dir" >&2
        return 2
    fi
    if [[ -f "$tx_dir/post.pair" ]]; then
        traffic_optional_state_matches_expected "$ABOX_TRAFFIC_PAIR_STATE" "$tx_dir/post.pair" || {
            printf '%s\n' "A-Box traffic rollback conflict: traffic pair state changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        }
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected pair state; recovery state preserved at $tx_dir" >&2
        return 2
    fi

    if [[ -f "$tx_dir/post.cron.traffic" ]]; then
        expected_block=$(cat "$tx_dir/post.cron.traffic") || return 2
        current=$(umask 077; mktemp /tmp/A-Box-traffic-current-cron.XXXXXX) || return 2
        if ! read_crontab_to_file "$current"; then rm -f -- "$current"; return 2; fi
        current_block=$(awk 'BEGIN{p=0} $0=="# A-Box TRAFFIC BEGIN"{p=1} p{print} $0=="# A-Box TRAFFIC END"{exit}' "$current")
        rm -f -- "$current"
        [[ "$current_block" == "$expected_block" ]] || {
            printf '%s\n' "A-Box traffic rollback conflict: crontab TRAFFIC block changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        }
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected TRAFFIC cron state; recovery state preserved at $tx_dir" >&2
        return 2
    fi

    if [[ -s "$tx_dir/post.monitor.hash" ]]; then
        IFS= read -r expected_monitor < "$tx_dir/post.monitor.hash" || return 2
        if [[ "$expected_monitor" == none ]]; then
            [[ ! -e "$ABOX_DIR/traffic_monitor.sh" && ! -L "$ABOX_DIR/traffic_monitor.sh" ]] || {
                printf '%s\n' "A-Box traffic rollback conflict: traffic_monitor.sh was created externally; recovery state preserved at $tx_dir" >&2
                return 2
            }
        else
            current_monitor=$(traffic_snapshot_file_hash "$ABOX_DIR/traffic_monitor.sh" 2>/dev/null || true)
            [[ "$current_monitor" == "$expected_monitor" ]] || {
                printf '%s\n' "A-Box traffic rollback conflict: traffic_monitor.sh changed externally; recovery state preserved at $tx_dir" >&2
                return 2
            }
        fi
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected monitor state; recovery state preserved at $tx_dir" >&2
        return 2
    fi

    if [[ -s "$tx_dir/post.vnstat" ]]; then
        IFS= read -r current_vnstat < <(capture_vnstat_runtime_state) || {
            printf '%s\n' "A-Box traffic rollback could not read current vnStat state; recovery state preserved at $tx_dir" >&2
            return 2
        }
        IFS= read -r expected_vnstat < "$tx_dir/post.vnstat" || return 2
        # 3B-U9 (R14-F10-03 residual): '?' marks an unknown field
        # (transient query failure), not a value, so it matches any
        # counterpart on either side; only a known-field mismatch, or a
        # field-count change, proves an external change. Compare
        # field-wise (kind|name|active|enabled).
        local -a _cur_vnstat_fields=() _exp_vnstat_fields=()
        local _vnstat_match=1 _vnstat_i=0
        IFS='|' read -r -a _cur_vnstat_fields <<< "$current_vnstat" || _vnstat_match=0
        IFS='|' read -r -a _exp_vnstat_fields <<< "$expected_vnstat" || _vnstat_match=0
        if (( ${#_cur_vnstat_fields[@]} != ${#_exp_vnstat_fields[@]} )); then
            _vnstat_match=0
        else
            for _vnstat_i in "${!_cur_vnstat_fields[@]}"; do
                if [[ "${_cur_vnstat_fields[$_vnstat_i]}" != "${_exp_vnstat_fields[$_vnstat_i]}" && "${_cur_vnstat_fields[$_vnstat_i]}" != '?' && "${_exp_vnstat_fields[$_vnstat_i]}" != '?' ]]; then
                    _vnstat_match=0
                    break
                fi
            done
        fi
        (( _vnstat_match )) || {
            printf '%s\n' "A-Box traffic rollback conflict: vnStat state changed externally; recovery state preserved at $tx_dir" >&2
            return 2
        }
    else
        printf '%s\n' "A-Box traffic rollback could not establish the expected vnStat state; recovery state preserved at $tx_dir" >&2
        return 2
    fi

    # Restore only A-Box-owned traffic state after the complete conflict preflight.
    if [[ -f "$tx_dir/pre.env.absent" ]]; then
        # F3: the quota preflight above only compares quota fields,
        # so non-quota lines added externally after provisioning are
        # invisible to it. Deleting the whole file would destroy
        # them; strip only the transaction's quota lines, and remove
        # the file only when nothing remains (true absent state).
        if [[ -f "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]; then
            local envtmp
            envtmp=$(mktemp "$ABOX_DIR/.env.A-Box-traffic-rollback.XXXXXX") || rc=1
            if (( rc == 0 )); then
                awk '!/^TRAFFIC_LIMIT_(GB|MODE)=/' "$ABOX_ENV" > "$envtmp" || rc=1
                if (( rc == 0 )); then
                    if [[ -s "$envtmp" ]]; then
                        chmod 600 "$envtmp" || rc=1
                        if (( rc == 0 )); then
                            mv -f -- "$envtmp" "$ABOX_ENV" || { rc=1; rm -f -- "$envtmp"; }
                        else
                            rm -f -- "$envtmp"
                        fi
                    else
                        rm -f -- "$envtmp" "$ABOX_ENV" || rc=1
                    fi
                else
                    rm -f -- "$envtmp"
                fi
            fi
        else
            rm -f -- "$ABOX_ENV" 2>/dev/null || rc=1
        fi
    elif [[ -f "$tx_dir/pre-traffic.env" ]]; then
        local envtmp
        envtmp=$(mktemp "$ABOX_DIR/.env.A-Box-traffic-rollback.XXXXXX") || rc=1
        if (( rc == 0 )); then
            # .env may not exist on fresh boxes; treat as empty in that case.
            if [[ -f "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]; then
                awk '!/^TRAFFIC_LIMIT_(GB|MODE)=/' "$ABOX_ENV" > "$envtmp" || rc=1
            else
                : > "$envtmp" || rc=1
            fi
            cat "$tx_dir/pre-traffic.env" >> "$envtmp" || rc=1
            chmod 600 "$envtmp" || rc=1
            if (( rc == 0 )); then
                mv -f -- "$envtmp" "$ABOX_ENV" || { rc=1; rm -f -- "$envtmp"; }
            else
                rm -f -- "$envtmp"
            fi
        fi
    fi
    # C-06: write_private_line undefined in main script (only in generated traffic_monitor.sh).
    if [[ -s "$tx_dir/pre.desired" ]]; then IFS= read -r current_state < "$tx_dir/pre.desired" && printf '%s\n' "$current_state" | write_file_atomically_from_stdin "$ABOX_DESIRED_STATE" 600 || rc=1; else rm -f -- "$ABOX_DESIRED_STATE" 2>/dev/null || rc=1; fi
    if [[ -s "$tx_dir/pre.block" ]]; then IFS= read -r current_state < "$tx_dir/pre.block" && printf '%s\n' "$current_state" | write_file_atomically_from_stdin "$ABOX_TRAFFIC_BLOCK_STATE" 600 || rc=1; else rm -f -- "$ABOX_TRAFFIC_BLOCK_STATE" 2>/dev/null || rc=1; fi
    # C-06: Restore authoritative pair-state atomically (was cp -a: non-atomic, symlink-unsafe).
    if [[ -s "$tx_dir/pre.pair" ]]; then IFS= read -r current_state < "$tx_dir/pre.pair" && printf '%s\n' "$current_state" | write_file_atomically_from_stdin "$ABOX_TRAFFIC_PAIR_STATE" 600 || rc=1; else rm -f -- "$ABOX_TRAFFIC_PAIR_STATE" 2>/dev/null || rc=1; fi

    if [[ -f "$tx_dir/pre.cron.traffic" ]]; then
        if traffic_restore_cron_block "$tx_dir/pre.cron.traffic" "$expected_block"; then :; else cron_rc=$?; rc=1; fi
        if (( cron_rc == 2 )); then printf '%s\n' "A-Box traffic rollback conflict: crontab TRAFFIC block changed externally; recovery state preserved at $tx_dir" >&2; fi
    fi

    if [[ -s "$tx_dir/pre.monitor.meta" ]]; then
        IFS='|' read -r pre_monitor _ < "$tx_dir/pre.monitor.meta" || rc=1
        if (( pre_monitor == 1 )); then
            cp -a -- "$tx_dir/traffic_monitor.pre" "$ABOX_DIR/traffic_monitor.sh" || rc=1
        else
            remove_owned_runtime_helper "$ABOX_DIR/traffic_monitor.sh" || rc=1
        fi
    else
        rc=1
    fi

    if [[ -s "$tx_dir/pre.vnstat" ]]; then
        IFS= read -r vnstat_state < "$tx_dir/pre.vnstat" || rc=1
        if [[ -n "$vnstat_state" && "$vnstat_state" != absent ]]; then
            restore_vnstat_runtime_state "$vnstat_state" || { printf '%s\n' "A-Box traffic rollback incomplete: vnStat state restore failed; recovery state preserved at $tx_dir" >&2; rc=1; }
        elif [[ "$vnstat_state" == absent ]]; then
            # FINAL-AUDIT: pre-state was absent. If the transaction installed
            # vnstat (post.vnstat shows it present), undo the installation:
            # stop/disable the service, and uninstall the package only if
            # this transaction installed it (pre.vnstat.binary == 0).
            local _post_vnstat=""
            [[ -s "$tx_dir/post.vnstat" ]] && IFS= read -r _post_vnstat < "$tx_dir/post.vnstat" 2>/dev/null || true
            if [[ -n "$_post_vnstat" && "$_post_vnstat" != absent ]]; then
                rollback_newly_installed_vnstat "$tx_dir" || { printf '%s\n' "A-Box traffic rollback incomplete: newly-installed vnStat cleanup failed; recovery state preserved at $tx_dir" >&2; rc=1; }
            fi
        fi
    else
        rc=1
    fi
    return "$rc"
}

prepare_traffic_quota_transaction() {
    local tx_dir="$1" traffic_env_tmp current grep_rc
    mkdir -p "$tx_dir" || return 1
    chmod 700 "$tx_dir" || return 1
    traffic_env_tmp="$tx_dir/pre-traffic.env"
    if [[ ! -e "$ABOX_ENV" && ! -L "$ABOX_ENV" ]]; then
        : > "$tx_dir/pre.env.absent" || return 1
        : > "$traffic_env_tmp" || return 1
    else
        grep -E '^TRAFFIC_LIMIT_(GB|MODE)=' "$ABOX_ENV" > "$traffic_env_tmp" 2>/dev/null
        grep_rc=$?
        (( grep_rc == 0 || grep_rc == 1 )) || return 1
    fi
    [[ -f "$ABOX_DESIRED_STATE" ]] && { cp -a -- "$ABOX_DESIRED_STATE" "$tx_dir/pre.desired" || return 1; } || :
    [[ -f "$ABOX_TRAFFIC_BLOCK_STATE" ]] && { cp -a -- "$ABOX_TRAFFIC_BLOCK_STATE" "$tx_dir/pre.block" || return 1; } || :
    # C-06: Backup authoritative pair-state (was missing). Reject symlinks.
    if [[ -e "$ABOX_TRAFFIC_PAIR_STATE" || -L "$ABOX_TRAFFIC_PAIR_STATE" ]]; then
        [[ -f "$ABOX_TRAFFIC_PAIR_STATE" && ! -L "$ABOX_TRAFFIC_PAIR_STATE" ]] || return 1
        cp -a -- "$ABOX_TRAFFIC_PAIR_STATE" "$tx_dir/pre.pair" || return 1
    fi
    current=$(umask 077; mktemp /tmp/A-Box-traffic-precron.XXXXXX) || return 1
    read_crontab_to_file "$current" || { rm -f -- "$current"; return 1; }
    awk 'BEGIN{p=0} $0=="# A-Box TRAFFIC BEGIN"{p=1} p{print} $0=="# A-Box TRAFFIC END"{exit}' "$current" > "$tx_dir/pre.cron.traffic" || { rm -f -- "$current"; return 1; }
    rm -f -- "$current"
    if [[ -e "$ABOX_DIR/traffic_monitor.sh" || -L "$ABOX_DIR/traffic_monitor.sh" ]]; then
        [[ -f "$ABOX_DIR/traffic_monitor.sh" && ! -L "$ABOX_DIR/traffic_monitor.sh" ]] || return 1
        auxiliary_content_is_abox_managed "$ABOX_DIR/traffic_monitor.sh" /etc/ddr/traffic_monitor.sh || return 1
        printf '1|%s\n' "$(traffic_snapshot_file_hash "$ABOX_DIR/traffic_monitor.sh")" > "$tx_dir/pre.monitor.meta" || return 1
        cp -a -- "$ABOX_DIR/traffic_monitor.sh" "$tx_dir/traffic_monitor.pre" || return 1
    else
        printf '%s\n' '0|none' > "$tx_dir/pre.monitor.meta" || return 1
    fi
    capture_vnstat_runtime_state > "$tx_dir/pre.vnstat" || return 1
    # FINAL-AUDIT: record whether the vnstat binary/package pre-existed, so
    # rollback only uninstalls it if THIS transaction installed it.
    if command -v vnstat >/dev/null 2>&1; then
        printf '1\n' > "$tx_dir/pre.vnstat.binary" || return 1
    else
        printf '0\n' > "$tx_dir/pre.vnstat.binary" || return 1
    fi
}

finalize_traffic_quota_transaction() {
    local tx_dir="$1"
    capture_traffic_quota_expected_state "$tx_dir"
}


start_services_for_traffic_unblock() {
    local pre_state="$1" changed_pre="$2" changed_expected="$3"
    local services srv before after active enabled op_rc final_state
    services=$(expected_managed_services) || return 1
    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        abox_owns_service "$srv" || return 1
        before=$(managed_service_state_value "$srv" 2>/dev/null) || return 1
        [[ "$before" == "$srv|1|enabled" || "$before" == "$srv|1|enabled-runtime" || "$before" == "$srv|1|indirect" ]] && continue
        IFS='|' read -r _ active enabled <<< "$before"
        append_managed_service_state_entry "$pre_state" "$changed_pre" "$srv" || return 1
        if [[ "$active" == 1 ]]; then
            if enable_abox_service_soft "$srv"; then op_rc=0; else op_rc=$?; fi
        else
            if start_abox_service_soft "$srv"; then op_rc=0; else op_rc=$?; fi
        fi
        after=$(managed_service_state_value "$srv" 2>/dev/null || true)
        if [[ -n "$after" ]]; then
            printf '%s\n' "$after" >> "$changed_expected" || return 1
        else
            # Keep the expected post-state explicit; rollback will refuse to
            # mutate if the actual state cannot later be proven to match it.
            printf '%s\n' "$srv|1|enabled" >> "$changed_expected" || return 1
        fi
        (( op_rc == 0 )) || return 1
        # 05d-M3: the post-operation check must accept the same three
        # states the initial and final checks accept: a soft start /
        # enable that lands on enabled-runtime or indirect has
        # succeeded, and rejecting it here forces a spurious rollback.
        [[ "$after" == "$srv|1|enabled" || "$after" == "$srv|1|enabled-runtime" || "$after" == "$srv|1|indirect" ]] || return 1
    done <<< "$services"
    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        final_state=$(managed_service_state_value "$srv" 2>/dev/null) || return 1
        [[ "$final_state" == "$srv|1|enabled" || "$final_state" == "$srv|1|enabled-runtime" || "$final_state" == "$srv|1|indirect" ]] || return 1
    done <<< "$services"
}

# Traffic transaction failure: run the rollback hook (fail-closed), clean up the
# die hook so a stale hook cannot fire later, show the error, and return to the
# traffic menu instead of exiting the script. Must be followed by `continue`
# (we are inside the menu's while loop).
_traffic_txn_fail() {
    local _rb_fn="$1" _oldhook_vn="$2" _reason="$3" _old=''
    if declare -F "$_rb_fn" >/dev/null 2>&1; then
        "$_rb_fn" "$_reason" || msg "${RED}[!] WARNING: rollback failed; manual recovery may be required.${NC}"
    fi
    unset ABOX_DIE_HOOK
    _old="${!_oldhook_vn:-}"
    if [[ -n "$_old" ]]; then ABOX_DIE_HOOK="$_old"; fi
    ABOX_TRAFFIC_TX_DIR=''
    msg "${RED}[!] $_reason${NC}"
    pause_return
}


traffic_management_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    clear
    local INTERFACE limit_gb mode_choice previous_state
    load_optional_abox_env_or_die
    INTERFACE="${INGRESS_IF:-$(get_active_interface)}"
    # Traffic dashboard (2026-10-19, per traffic-table.png): progress bar +
    # clean monthly table instead of raw vnStat ASCII boxes.
    local _tjson='' _tlimit="${TRAFFIC_LIMIT_GB:-}"
    if command -v vnstat >/dev/null 2>&1; then
        _tjson=$(vnstat -i "$INTERFACE" --json m 2>/dev/null) || _tjson=''
    fi
    # R21-F1B: dashboard strings come from tr_msg (6 langs) via argv,
    # so the embedded Python report renders in the selected language.
    local _tm_args=(
        "$(tr_msg traffic_management_menu_dash_title)"
        "$(tr_msg traffic_management_menu_this_month)"
        "$(tr_msg traffic_management_menu_used_this_month)"
        "$(tr_msg traffic_management_menu_remaining)"
        "$(tr_msg traffic_management_menu_over_limit)"
        "$(tr_msg traffic_management_menu_used_with_limit)"
        "$(tr_msg traffic_management_menu_used_no_limit)"
        "$(tr_msg traffic_management_menu_no_current_month_data)"
        "$(tr_msg traffic_management_menu_history_title)"
        "$(tr_msg traffic_management_menu_col_month)"
        "$(tr_msg traffic_management_menu_col_total)"
        "$(tr_msg traffic_management_menu_col_rx)"
        "$(tr_msg traffic_management_menu_col_tx)"
        "$(tr_msg traffic_management_menu_col_status)"
        "$(tr_msg traffic_management_menu_status_running)"
        "$(tr_msg traffic_management_menu_status_over)"
        "$(tr_msg traffic_management_menu_status_ok)"
        "$(tr_msg traffic_management_menu_no_month_stats)"
    )
    if [[ -z "$_tjson" ]]; then
        # W7-OBS-1: without vnStat the menu showed only this warning
        # and no dashboard at all. Keep the warning, but still render
        # the dashboard frame over an empty dataset: the Python report
        # below renders its title + "no month stats" line for `{}`.
        msg "${YELLOW}[!] $(tr_msg traffic_management_menu_vnstat_missing)${NC}"
        _tjson='{}'
    fi
    python3 -I - "$_tjson" "$INTERFACE" "$_tlimit" "${TRAFFIC_LIMIT_MODE:-total}" "${_tm_args[@]}" <<'PY_TRAFFIC_DASH' 2>/dev/null || \
            msg "${YELLOW}[!] $(tr_msg traffic_management_menu_parse_failed)${NC}"
import datetime, json, sys, unicodedata

def dw(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)

def pad(s, w, right=False):
    p = " " * max(0, w - dw(s))
    return (p + s) if right else (s + p)

def center(s, w=80):
    return " " * max(0, (w - dw(s)) // 2) + s

YELLOW = "\033[0;33m"; CYAN = "\033[0;36m"; GREEN = "\033[0;32m"
RED = "\033[0;31m"; GRAY = "\033[0;37m"; BLUE = "\033[0;34m"
BOLD = "\033[1m"; NC = "\033[0m"
BAR = "─" * 80
GIB = 1073741824

raw, iface, limit_s = sys.argv[1], sys.argv[2], sys.argv[3]
(TM_TITLE, TM_THIS_MONTH, TM_USED_THIS_MONTH, TM_REMAINING, TM_OVER_LIMIT,
 TM_USED_WITH_LIMIT, TM_USED_NO_LIMIT, TM_NO_CURRENT_MONTH_DATA,
 TM_HISTORY_TITLE, TM_COL_MONTH, TM_COL_TOTAL, TM_COL_RX, TM_COL_TX,
 TM_COL_STATUS, TM_STATUS_RUNNING, TM_STATUS_OVER, TM_STATUS_OK,
 TM_NO_MONTH_STATS) = sys.argv[5:23]
mode = sys.argv[4] if len(sys.argv) > 4 else 'total'
if mode not in ('total', 'rx', 'tx'):
    mode = 'total'
try:
    limit_gb = float(limit_s)
except (ValueError, TypeError):
    limit_gb = 0.0

def fmt_gb(n):
    return f"{n / GIB:,.1f} GB"

def used_value(r, t):
    return r if mode == 'rx' else t if mode == 'tx' else r + t

def progress_bar(pct, width=60):
    pct = max(0.0, min(pct, 1.0))
    filled = int(width * pct)
    label = f"{pct * 100:.1f}%"
    ls = (width - len(label)) // 2
    parts = []
    for i in range(width):
        if ls <= i < ls + len(label):
            parts.append(f"{BOLD}{label[i - ls]}{NC}")
        elif i < filled:
            parts.append(f"{YELLOW}\u2588{NC}")
        else:
            parts.append(f"{GRAY}\u2591{NC}")
    return "".join(parts)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
_traffic = (data.get("interfaces") or [{}])[0].get("traffic") or {}
months = _traffic.get("month") or _traffic.get("months") or []
if not _traffic.get("month") and _traffic.get("months"):
    # R6C10-02: vnStat 1.x months are KiB counts; normalize to bytes.
    # R14-F10-05: 1.x entries also carry the date as top-level
    # year/month, while every read below uses .date.year/.date.month
    # (month_bytes already accepts both shapes). Normalize the date
    # here too, keeping an existing .date when one is present, so the
    # sort key and the current-month check work on 1.x data.
    def _norm_1x(m):
        _d = m.get("date") or {}
        return {**m, "rx": int(m.get("rx", 0)) * 1024,
                "tx": int(m.get("tx", 0)) * 1024,
                "date": {"year": _d.get("year") or m.get("year") or 0,
                         "month": _d.get("month") or m.get("month") or 0}}
    months = [_norm_1x(m) for m in months]
months = sorted(months,
                key=lambda m: (m.get("date", {}).get("year", 0),
                               m.get("date", {}).get("month", 0)),
                reverse=True)

out = []
out.append(f"{BLUE}{BAR}{NC}")
out.append(f"{YELLOW}{center(TM_TITLE)}{NC}")
out.append(f"{BLUE}{BAR}{NC}")
if months:
    cur = months[0]
    rx = int(cur.get("rx", 0)); tx = int(cur.get("tx", 0)); total = rx + tx
    used = used_value(rx, tx)
    d = cur.get("date", {})
    ym = f"{d.get('year', '--')}-{int(d.get('month', 0)):02d}" if d.get("year") else TM_THIS_MONTH
    now = datetime.datetime.now()
    is_current = (d.get("year") == now.year and d.get("month") == now.month)
    if is_current:
        out.append(TM_USED_THIS_MONTH % (iface, ym))
        if limit_gb > 0:
            cap = limit_gb * GIB
            out.append(progress_bar(used / cap))
            rem = cap - used
            rem_s = f"{GREEN}{TM_REMAINING % fmt_gb(rem)}{NC}" if rem >= 0 else f"{RED}{TM_OVER_LIMIT % fmt_gb(-rem)}{NC}"
            _uw = TM_USED_WITH_LIMIT.split('%s', 1)
            out.append(f"{YELLOW}{_uw[0]}{fmt_gb(used)}{NC}{_uw[1] % (format(limit_gb, ',.0f'), rem_s)}")
        else:
            _un = TM_USED_NO_LIMIT.split('%s', 1)
            out.append(f"{YELLOW}{_un[0]}{fmt_gb(used)}{NC}{_un[1]}")
    else:
        out.append(f"{YELLOW}{TM_NO_CURRENT_MONTH_DATA % ym}{NC}")
    out.append(f"{BLUE}{BAR}{NC}")
    out.append(f"{CYAN}{center(TM_HISTORY_TITLE)}{NC}")
    out.append(f"{YELLOW}{pad(TM_COL_MONTH, 10)}{pad(TM_COL_TOTAL, 15, True)}"
               f"{pad(TM_COL_RX, 15, True)}{pad(TM_COL_TX, 15, True)}  {TM_COL_STATUS}{NC}")
    out.append(f"{GRAY}{'─' * 66}{NC}")
    for i, m in enumerate(months):
        dd = m.get("date", {})
        yymm = f"{dd.get('year', '--')}-{int(dd.get('month', 0)):02d}"
        r = int(m.get("rx", 0)); t = int(m.get("tx", 0)); tot = r + t
        m_used = used_value(r, t)
        m_current = (dd.get("year") == now.year and dd.get("month") == now.month)
        if m_current:
            st = f"{YELLOW}{TM_STATUS_RUNNING}{NC}"
        elif limit_gb > 0 and m_used > limit_gb * GIB:
            st = f"{RED}{TM_STATUS_OVER}{NC}"
        else:
            st = f"{GREEN}{TM_STATUS_OK}{NC}"
        out.append(f"{pad(yymm, 10)}{pad(fmt_gb(tot), 15, True)}"
                   f"{pad(fmt_gb(r), 15, True)}{pad(fmt_gb(t), 15, True)}  {st}")
else:
    out.append(f"{YELLOW}{TM_NO_MONTH_STATS}{NC}")
sys.stdout.write("\n".join(out) + "\n")
PY_TRAFFIC_DASH
    msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
    msg "${CYAN}1.${NC}  $(tr_msg traffic_management_menu_set_limit)"
    msg "${CYAN}2.${NC}  $(tr_msg traffic_management_menu_remove_limit)"
    msg "${CYAN}0.${NC}  $(tr_msg traffic_management_menu_back)"
    read -r -p "$(tr_msg tf_pick)" tr_choice || return 0
    tr_choice=$(normalize_fa_ar_digits "${tr_choice:-}")
    case "$tr_choice" in
        1)
            read -r -p "$(tr_msg tf_limit_prompt)" limit_gb
            limit_gb=$(normalize_fa_ar_digits "$limit_gb")
            valid_traffic_limit_gb "$limit_gb" || { msg "${RED}[!] $(tr_msg traffic_management_menu_limit_range)${NC}"; pause_return; return; }
            read -r -p "$(tr_msg tf_mode_prompt)" mode_choice
            mode_choice=$(normalize_fa_ar_digits "${mode_choice:-}")
            mode_choice=${mode_choice:-total}
            [[ "$mode_choice" =~ ^(total|rx|tx)$ ]] || { msg "${RED}[!] $(tr_msg traffic_management_menu_mode_invalid)${NC}"; pause_return; return; }
            # R6C10-03: drop any stale rollback from a previous round
            # before reading state, so a read failure never invokes a
            # callback over locals this round has not bound.
            unset -f traffic_quota_menu_die_rollback
            local traffic_tx_dir="" old_die_hook="" traffic_previous_state='' traffic_service_pre='' traffic_service_changed_pre='' traffic_service_changed_expected='' traffic_op_rc=0 traffic_target_state=''
            # 05d-M1: save the caller's die hook BEFORE the first step
            # that can fail: every failure below calls _traffic_txn_fail,
            # which unsets ABOX_DIE_HOOK and restores it from this
            # variable. Saving it only later (after prepare) loses the
            # caller's hook on any early failure.
            if [[ ${ABOX_DIE_HOOK+x} ]]; then old_die_hook="$ABOX_DIE_HOOK"; fi
            traffic_previous_state=$(get_desired_state) || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_read_state)"; continue; }
            traffic_tx_dir=$(mktemp -d /run/A-Box-traffic-tx.XXXXXX) || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_tx_dir)"; continue; }
            chmod 700 "$traffic_tx_dir" || { rm -rf -- "$traffic_tx_dir"; _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_tx_dir_mode)"; continue; }
            prepare_traffic_quota_transaction "$traffic_tx_dir" || { rm -rf -- "$traffic_tx_dir"; _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_tx_presave)"; continue; }
            if [[ "$traffic_previous_state" == TRAFFIC_BLOCKED ]]; then
                traffic_service_pre="$traffic_tx_dir/pre-services.state"
                traffic_service_changed_pre="$traffic_tx_dir/changed-services-pre.state"
                traffic_service_changed_expected="$traffic_tx_dir/changed-services-expected.state"
                capture_managed_service_state "$traffic_service_pre" || { rm -rf -- "$traffic_tx_dir"; _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_unblock_presave)"; continue; }
                : > "$traffic_service_changed_pre"; : > "$traffic_service_changed_expected"
            fi
            if [[ ${ABOX_DIE_HOOK+x} ]]; then old_die_hook="$ABOX_DIE_HOOK"; fi
            ABOX_TRAFFIC_TX_DIR="$traffic_tx_dir"
            ABOX_DIE_HOOK=traffic_quota_menu_die_rollback
            traffic_quota_menu_die_rollback() {
                local rollback_rc=0 reason="${1:-traffic quota change failed}"
                if [[ -n "$traffic_service_changed_pre" && -s "$traffic_service_changed_pre" ]]; then
                    if [[ -s "$traffic_service_changed_expected" ]]; then
                        restore_managed_service_state "$traffic_service_changed_pre" "$traffic_service_changed_expected" || rollback_rc=1
                    else
                        rollback_rc=1
                    fi
                fi
                traffic_quota_transaction_rollback "$traffic_tx_dir" || rollback_rc=1
                if (( rollback_rc != 0 )); then
                    printf '%s\n' "A-Box traffic quota rollback incomplete/conflicted; recovery state preserved at $traffic_tx_dir" >&2
                else
                    rm -rf -- "$traffic_tx_dir" || rollback_rc=1
                fi
                if (( rollback_rc != 0 )); then
                    printf '%s\n' "A-Box traffic quota/service rollback incomplete; inspect recovery state at $traffic_tx_dir" >&2
                fi
                if [[ -n "$old_die_hook" && "$old_die_hook" != traffic_quota_menu_die_rollback ]] && declare -F "$old_die_hook" >/dev/null 2>&1; then
                    "$old_die_hook" "$reason" || true
                fi
                return "$rollback_rc"
            }
            if ! setup_traffic_monitor; then
                _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_monitor_init)"; continue
            fi
            if update_traffic_state_atomically "$limit_gb" "$mode_choice"; then traffic_op_rc=0; else traffic_op_rc=$?; fi
            capture_traffic_quota_expected_state "$traffic_tx_dir" || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_verify_after_update)"; continue; }
            (( traffic_op_rc == 0 )) || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_commit)"; continue; }
            if clear_traffic_block_period; then traffic_op_rc=0; else traffic_op_rc=$?; fi
            capture_traffic_quota_expected_state "$traffic_tx_dir" || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_verify_after_purge)"; continue; }
            (( traffic_op_rc == 0 )) || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_purge_old)"; continue; }
            case "$traffic_previous_state" in
                TRAFFIC_BLOCKED)
                    start_services_for_traffic_unblock "$traffic_service_pre" "$traffic_service_changed_pre" "$traffic_service_changed_expected" || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_services_restore)"; continue; }
                    traffic_target_state=RUNNING
                    ;;
                RUNNING|MANUAL_STOPPED|MAINTENANCE)
                    traffic_target_state="$traffic_previous_state"
                    ;;
                *) _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tprintf tf_unknown_state "$traffic_previous_state")"; continue ;;
            esac
            if set_desired_state "$traffic_target_state"; then traffic_op_rc=0; else traffic_op_rc=$?; fi
            capture_traffic_quota_expected_state "$traffic_tx_dir" || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_verify_after_desired)"; continue; }
            (( traffic_op_rc == 0 )) || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_desired_write)"; continue; }
            finalize_traffic_quota_transaction "$traffic_tx_dir" || { _traffic_txn_fail traffic_quota_menu_die_rollback old_die_hook "$(tr_msg tf_finalize)"; continue; }
            unset ABOX_DIE_HOOK
            if [[ -n "$old_die_hook" ]]; then ABOX_DIE_HOOK="$old_die_hook"; fi
            ABOX_TRAFFIC_TX_DIR=''
            # 05d-M4: the quota is committed at this point. A cleanup
            # failure must NOT invoke the business rollback: rolling
            # back would restore the service to stopped while the
            # quota stays submitted. Warn, leave the directory for
            # manual cleanup, and report success.
            if ! rm -rf -- "$traffic_tx_dir"; then
                msg "${YELLOW}[!] $(tr_msg tf_tx_cleanup) $traffic_tx_dir${NC}"
            fi
            unset -f traffic_quota_menu_die_rollback
            msg "${GREEN}$(tprintf traffic_management_menu_limit_set "${limit_gb}" "${mode_choice}")${NC}"
            pause_return
            ;;
        2)
            # R6C10-03: bind this round's locals and drop any stale
            # rollback BEFORE reading state (the read failure below
            # invokes _traffic_txn_fail, which would otherwise call
            # a previous round's callback over unbound locals).
            unset -f traffic_unblock_menu_die_rollback
            local unblock_tx_dir='' unblock_old_die_hook='' unblock_state_pre='' unblock_changed_pre='' unblock_changed_expected='' unblock_op_rc=0 target_state=''
            # 05d-M1: same early save as the quota branch above.
            if [[ ${ABOX_DIE_HOOK+x} ]]; then unblock_old_die_hook="$ABOX_DIE_HOOK"; fi
            previous_state=$(get_desired_state) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_read_state_unblock)"; continue; }
            unblock_tx_dir=$(mktemp -d /run/A-Box-traffic-unblock.XXXXXX) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_tx_dir)"; continue; }
            chmod 700 "$unblock_tx_dir" || { rm -rf -- "$unblock_tx_dir"; _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_tx_mode)"; continue; }
            prepare_traffic_quota_transaction "$unblock_tx_dir" || { rm -rf -- "$unblock_tx_dir"; _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_presave)"; continue; }
            unblock_state_pre="$unblock_tx_dir/pre-services.state"
            unblock_changed_pre="$unblock_tx_dir/changed-services-pre.state"
            unblock_changed_expected="$unblock_tx_dir/changed-services-expected.state"
            capture_managed_service_state "$unblock_state_pre" || { rm -rf -- "$unblock_tx_dir"; _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_svc_presave)"; continue; }
            : > "$unblock_changed_pre"; : > "$unblock_changed_expected"
            if [[ ${ABOX_DIE_HOOK+x} ]]; then unblock_old_die_hook="$ABOX_DIE_HOOK"; fi
            ABOX_TRAFFIC_TX_DIR="$unblock_tx_dir"
            ABOX_DIE_HOOK=traffic_unblock_menu_die_rollback
            traffic_unblock_menu_die_rollback() {
                local rollback_rc=0 reason="${1:-traffic unblock failed}"
                if [[ -s "$unblock_changed_pre" ]]; then
                    if [[ -s "$unblock_changed_expected" ]]; then
                        restore_managed_service_state "$unblock_changed_pre" "$unblock_changed_expected" || rollback_rc=1
                    else
                        rollback_rc=1
                    fi
                fi
                traffic_quota_transaction_rollback "$unblock_tx_dir" || rollback_rc=1
                if (( rollback_rc == 0 )); then
                    rm -rf -- "$unblock_tx_dir" || rollback_rc=1
                fi
                if (( rollback_rc != 0 )); then
                    printf '%s\n' "A-Box traffic-unblock rollback incomplete; recovery state preserved at $unblock_tx_dir" >&2
                fi
                if [[ -n "$unblock_old_die_hook" && "$unblock_old_die_hook" != traffic_unblock_menu_die_rollback ]] && declare -F "$unblock_old_die_hook" >/dev/null 2>&1; then
                    "$unblock_old_die_hook" "$reason" || true
                fi
                return "$rollback_rc"
            }

            if update_traffic_state_atomically '' ''; then unblock_op_rc=0; else unblock_op_rc=$?; fi
            capture_traffic_quota_expected_state "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_verify_new)"; continue; }
            (( unblock_op_rc == 0 )) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_commit)"; continue; }
            if remove_abox_cron_block TRAFFIC; then unblock_op_rc=0; else unblock_op_rc=$?; fi
            capture_traffic_quota_expected_state "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_verify_cron)"; continue; }
            (( unblock_op_rc == 0 )) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_rm_cron)"; continue; }
            if remove_owned_runtime_helper "$ABOX_DIR/traffic_monitor.sh"; then unblock_op_rc=0; else unblock_op_rc=$?; fi
            capture_traffic_quota_expected_state "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_verify_script)"; continue; }
            (( unblock_op_rc == 0 )) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_rm_script)"; continue; }
            if clear_traffic_block_period; then unblock_op_rc=0; else unblock_op_rc=$?; fi
            capture_traffic_quota_expected_state "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_verify_purge)"; continue; }
            (( unblock_op_rc == 0 )) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_purge)"; continue; }
            load_abox_env "$ABOX_ENV" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_reload)"; continue; }
            case "$previous_state" in
                TRAFFIC_BLOCKED)
                    start_services_for_traffic_unblock "$unblock_state_pre" "$unblock_changed_pre" "$unblock_changed_expected" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_services)"; continue; }
                    target_state=RUNNING
                    ;;
                RUNNING|MANUAL_STOPPED|MAINTENANCE)
                    target_state="$previous_state"
                    ;;
                *) _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tprintf tf_unknown_state_unblock "$previous_state")"; continue ;;
            esac
            if set_desired_state "$target_state"; then unblock_op_rc=0; else unblock_op_rc=$?; fi
            capture_traffic_quota_expected_state "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_verify_desired)"; continue; }
            (( unblock_op_rc == 0 )) || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_desired_write)"; continue; }
            finalize_traffic_quota_transaction "$unblock_tx_dir" || { _traffic_txn_fail traffic_unblock_menu_die_rollback unblock_old_die_hook "$(tr_msg tf_unblock_finalize)"; continue; }
            unset ABOX_DIE_HOOK
            if [[ -n "$unblock_old_die_hook" ]]; then ABOX_DIE_HOOK="$unblock_old_die_hook"; fi
            ABOX_TRAFFIC_TX_DIR=''
            # 05d-M4: same as the quota branch above: the unblock is
            # committed; a cleanup failure only warns.
            if ! rm -rf -- "$unblock_tx_dir"; then
                msg "${YELLOW}[!] $(tr_msg tf_unblock_cleanup) $unblock_tx_dir${NC}"
            fi
            unset -f traffic_unblock_menu_die_rollback
            msg "${GREEN}$(tr_msg traffic_management_menu_limit_removed)${NC}"
            pause_return
            ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $tr_choice${NC}"; sleep 1 ;;
    esac
    done
}

remove_ss_source_whitelist_rules() {
    local failed=0 cmd proto line rule ipt_out
    local -a argv=()
    [[ -n "${SS_PORT:-}" ]] || return 0
    for cmd in "$IPT" "$IPT6"; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        _iptables_q "$cmd" -S INPUT >/dev/null 2>&1 || { failed=1; continue; }
        for proto in tcp udp; do
            while :; do
                ipt_out=$(_iptables_q "$cmd" -S INPUT 2>/dev/null) || { failed=1; break; }
                line=$(awk -v p="$proto" -v port="$SS_PORT" '$0 ~ "^-A INPUT " && $0 ~ ("-p " p) && $0 ~ ("--dport " port) && $0 ~ ("--comment \"?A-Box-" port "-" p "-WL6?(:A-Box-tmp-[0-9]+-[0-9]+)?\"?($|[ \t\r])") {print; exit}' <<< "$ipt_out") || { failed=1; break; }
                [[ -n "$line" ]] || break
                line=${line//\"/}
                rule="${line#-A INPUT }"
                read -r -a argv <<< "$rule"
                _iptables_do "$cmd" -D INPUT "${argv[@]}" >/dev/null 2>&1 || { failed=1; break; }
            done
        done
    done
    (( failed == 0 ))
}

# B-12: Rebuild SS_WHITELIST_IP from live iptables rules and persist to .env,
# so menu edits (add/remove) don't leave .env stale for redeploy wizards.
sync_ss_whitelist_ip_to_env() {
    local ips='' v6ips='' ipt_output ip6_output
    [[ -n "${SS_PORT:-}" ]] || return 1
    if ! ipt_output=$(_iptables_q "$IPT" -S INPUT 2>&1); then
        printf '[A-Box] WARNING: iptables query failed, not syncing whitelist to .env: %s\n' "$ipt_output" >&2
        return 1
    fi
    ips=$(awk -v port="$SS_PORT" '
        $0 ~ ("--comment \"?A-Box-" port "-(tcp|udp)-WL(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([ \t\r]|$)") && $0 ~ /-j ACCEPT([ \t\r]|$)/ {
            for (i = 1; i < NF; i++) {
                if ($i == "-s") { sub(/\/32$/, "", $(i+1)); print $(i+1) }
            }
        }
    ' <<< "$ipt_output" | LC_ALL=C sort -u | tr '\n' ' ')
    if host_has_usable_ipv6 && ip6tables_usable; then
        if ! ip6_output=$(_iptables_q "$IPT6" -S INPUT 2>&1); then
            printf '[A-Box] WARNING: ip6tables query failed, not syncing whitelist to .env: %s\n' "$ip6_output" >&2
            return 1
        fi
        v6ips=$(awk -v port="$SS_PORT" '
            $0 ~ ("--comment \"?A-Box-" port "-(tcp|udp)-WL6(:A-Box-tmp-[0-9]+-[0-9]+)?\"?([ \t\r]|$)") && $0 ~ /-j ACCEPT([ \t\r]|$)/ {
                for (i = 1; i < NF; i++) {
                    if ($i == "-s") { sub(/\/128$/, "", $(i+1)); print $(i+1) }
                }
            }
        ' <<< "$ip6_output" | LC_ALL=C sort -u | tr '\n' ' ')
        ips+="$v6ips"
    else
        # IPv6 query unavailable: keep the IPv6 entries already in .env
        # instead of silently dropping them from the whitelist.
        v6ips=$(printf '%s' "${SS_WHITELIST_IP:-}" | tr ' ' '\n' | grep ':' | tr '\n' ' ' || true)
        ips+="$v6ips"
    fi
    SS_WHITELIST_IP=$(printf '%s' "$ips" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    write_env || return 1
}
manage_ss_whitelist() {
    local check_rc=0
    clear
    local _wl_backend
    _wl_backend=$(firewall_backend)
    [[ "$_wl_backend" == 'iptables' ]] || {
        msg "${RED}[!] $(tprintf manage_ss_whitelist_iptables_only_backend "${_wl_backend}")${NC}"
        pause_return
        return 1
    }
    load_optional_abox_env_or_die
    [[ -z "${SS_PORT:-}" ]] && { msg "${RED}[!] $(tr_msg manage_ss_whitelist_no_ss_port)${NC}"; pause_return; return; }
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg manage_ss_whitelist_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    msg "${YELLOW}$(tprintf manage_ss_whitelist_listen_port "$SS_PORT")${NC}"
    msg "$(tr_msg manage_ss_whitelist_ipv4_label)"
    $IPT -nL INPUT --line-numbers 2>/dev/null | grep -E "(tcp|udp) dpt:$SS_PORT([^0-9]|$)" | grep 'ACCEPT' | awk '{print $5}' | grep -v '0.0.0.0/0' | sort -u || true
    if command -v ip6tables >/dev/null 2>&1 && $IPT6 -nL INPUT >/dev/null 2>&1; then
        msg "$(tr_msg manage_ss_whitelist_ipv6_label)"
        $IPT6 -nL INPUT --line-numbers 2>/dev/null | grep -E "(tcp|udp) dpt:$SS_PORT([^0-9]|$)" | grep 'ACCEPT' | awk '{print $5}' | grep -v '::/0' | sort -u || true
    fi
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${CYAN}1.${NC} $(tr_msg manage_ss_whitelist_add_ip)"
    msg "${CYAN}2.${NC} $(tr_msg manage_ss_whitelist_remove_ip)"
    msg "${CYAN}3.${NC} $(tr_msg manage_ss_whitelist_enable_mode)"
    msg "${CYAN}4.${NC} $(tr_msg manage_ss_whitelist_open_all)"
    msg "${CYAN}0.${NC} $(tr_msg manage_ss_whitelist_back_to_menu)"
    read -r -p "$(tr_msg wl_pick_prompt)" wl_choice
    wl_choice=$(normalize_fa_ar_digits "${wl_choice:-}")
    local add_ip del_ip rule found proto
    case "$wl_choice" in
        1)
            read -r -p "$(tr_msg wl_add_prompt)" add_ip
            [[ -z "$add_ip" ]] && return
            _ss_wl_snapshot_rules || die "$(tr_msg pi_ss_snapshot)"
            if [[ "$add_ip" == *:* ]]; then
                valid_ipv6_cidr "$add_ip" || { msg "${RED}[!] $(tprintf manage_ss_whitelist_ipv6_addr_invalid "$add_ip")${NC}"; pause_return; return; }
                # N-04: objective check (not preference-aware has_ipv6), consistent
                # with option 2/3 and pre_install_setup.
                host_has_usable_ipv6 && command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1 || die "$(tr_msg mw_no_v6fw)"
                for proto in tcp udp; do
                    # F-06: check existence first (idempotent) — do not insert duplicates.
                    if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -s "$add_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in
                        0) ;;
                        1) _iptables_do "$IPT6" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -s "$add_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_wl6_fail "$add_ip" "$proto")"; } ;;
                        *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
                    esac
                done
            else
                valid_ipv4_cidr "$add_ip" || { msg "${RED}[!] $(tprintf manage_ss_whitelist_ipv4_addr_invalid "$add_ip")${NC}"; pause_return; return; }
                for proto in tcp udp; do
                    # F-06: check existence first (idempotent) — do not insert duplicates.
                    if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -s "$add_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in
                        0) ;;
                        1) _iptables_do "$IPT" -I INPUT 1 -p "$proto" --dport "$SS_PORT" -s "$add_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf pi_ss_wl4_fail "$add_ip" "$proto")"; } ;;
                        *) { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_fw_check)"; } ;;
                    esac
                done
            fi
            save_firewall_rules || { if _ss_wl_rollback_to_snapshot; then die "$(tr_msg pi_fw_persist_rb)"; else die "$(tr_msg pi_fw_persist_norb)"; fi; }
            sync_ss_whitelist_ip_to_env || { if _ss_wl_rollback_to_snapshot && save_firewall_rules; then die "$(tr_msg mw_env_sync)"; else die "$(tr_msg mw_env_sync_norb)"; fi; }
            msg "${GREEN}$(tprintf manage_ss_whitelist_added "$add_ip")${NC}"
            pause_return
            ;;
        2)
            read -r -p "$(tr_msg wl_del_prompt)" del_ip
            [[ -z "$del_ip" ]] && return
            _ss_wl_snapshot_rules || die "$(tr_msg pi_ss_snapshot)"
            found=0
            if [[ "$del_ip" == *:* ]]; then
                valid_ipv6_cidr "$del_ip" || { msg "${RED}[!] $(tprintf manage_ss_whitelist_ipv6_addr_invalid "$del_ip")${NC}"; pause_return; return; }
                if ! host_has_usable_ipv6 || ! command -v ip6tables >/dev/null 2>&1 || ! _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                    msg "${YELLOW}[!] $(tr_msg manage_ss_whitelist_no_ipv6_firewall)${NC}"
                    pause_return
                    return
                fi
                for proto in tcp udp; do
                    while :; do
                        if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -s "$del_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                        case "$check_rc" in
                            0) ;;
                            1) break ;;
                            *) { _ss_wl_rollback_to_snapshot; die "$(tprintf mw_wl6_check "$del_ip/$proto")"; } ;;
                        esac
                        _iptables_do "$IPT6" -D INPUT -p "$proto" --dport "$SS_PORT" -s "$del_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL6" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf mw_wl6_del "$del_ip/$proto")"; }
                        found=1
                    done
                done
            else
                valid_ipv4_cidr "$del_ip" || { msg "${RED}[!] $(tprintf manage_ss_whitelist_ipv4_addr_invalid "$del_ip")${NC}"; pause_return; return; }
                for proto in tcp udp; do
                    while :; do
                        if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -s "$del_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
                        case "$check_rc" in
                            0) ;;
                            1) break ;;
                            *) { _ss_wl_rollback_to_snapshot; die "$(tprintf mw_wl4_check "$del_ip/$proto")"; } ;;
                        esac
                        _iptables_do "$IPT" -D INPUT -p "$proto" --dport "$SS_PORT" -s "$del_ip" -m comment --comment "A-Box-${SS_PORT}-${proto}-WL" -j ACCEPT >/dev/null 2>&1 || { _ss_wl_rollback_to_snapshot; die "$(tprintf mw_wl4_del "$del_ip/$proto")"; }
                        found=1
                    done
                done
            fi
            save_firewall_rules || { if _ss_wl_rollback_to_snapshot; then die "$(tr_msg pi_fw_persist_rb)"; else die "$(tr_msg pi_fw_persist_norb)"; fi; }
            sync_ss_whitelist_ip_to_env || { if _ss_wl_rollback_to_snapshot && save_firewall_rules; then die "$(tr_msg mw_env_sync)"; else die "$(tr_msg mw_env_sync_norb)"; fi; }
            if [[ "$found" == 1 ]]; then msg "${GREEN}$(tprintf manage_ss_whitelist_removed "$del_ip")${NC}"; else msg "${YELLOW}$(tr_msg manage_ss_whitelist_rule_not_found)${NC}"; fi
            pause_return
            ;;
        3)
            ss_whitelist_ipv6_precheck || die "$(tr_msg pi_ss_v6_fw)"
            _ss_wl_snapshot_rules || die "$(tr_msg pi_ss_snapshot)"
            remove_ss_open_accept_rules || { _ss_wl_rollback_to_snapshot; die "$(tr_msg pi_ss_old_accept)"; }
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
            save_firewall_rules || { if _ss_wl_rollback_to_snapshot; then die "$(tr_msg pi_fw_persist_rb)"; else die "$(tr_msg pi_fw_persist_norb)"; fi; }
            msg "${GREEN}$(tr_msg manage_ss_whitelist_protect_enabled)${NC}"
            pause_return
            ;;
        4)
            _ss_wl_snapshot_rules || die "$(tr_msg pi_ss_snapshot)"
            # Use DIE_HOOK so that allowPort's internal die() calls trigger rollback
            # (allowPort calls die directly, outer || cannot catch it)
            local _old_die_hook="${ABOX_DIE_HOOK:-}"
            ABOX_DIE_HOOK=_ss_wl_rollback_to_snapshot
            remove_ss_source_whitelist_rules || { ABOX_DIE_HOOK="$_old_die_hook"; if _ss_wl_rollback_to_snapshot; then die "$(tr_msg mw_old_rb)"; else die "$(tr_msg mw_old_norb)"; fi; }
            for proto in tcp udp; do
                while :; do
                    if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP" -j DROP; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in
                        0) ;;
                        1) break ;;
                        *) die "$(tprintf mw_drop4_check "$proto")" ;;
                    esac
                    _iptables_do "$IPT" -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP" -j DROP >/dev/null 2>&1 || die "$(tprintf mw_drop4_del "$proto")"
                done
                if iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP" -j DROP; then check_rc=0; else check_rc=$?; fi
                case "$check_rc" in 1) ;; 0) die "$(tprintf mw_drop4_still "$proto")" ;; *) die "$(tprintf mw_drop4_verify "$proto")" ;; esac
                if command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                    while :; do
                        if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP6" -j DROP; then check_rc=0; else check_rc=$?; fi
                        case "$check_rc" in
                            0) ;;
                            1) break ;;
                            *) die "$(tprintf mw_drop6_check "$proto")" ;;
                        esac
                        _iptables_do "$IPT6" -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP6" -j DROP >/dev/null 2>&1 || die "$(tprintf mw_drop6_del "$proto")"
                    done
                    if iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "A-Box-${SS_PORT}-${proto}-DROP6" -j DROP; then check_rc=0; else check_rc=$?; fi
                    case "$check_rc" in 1) ;; 0) die "$(tprintf mw_drop6_still "$proto")" ;; *) die "$(tprintf mw_drop6_verify "$proto")" ;; esac
                fi
                allowPort "$SS_PORT" "$proto"
            done
            save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
            sync_ss_whitelist_ip_to_env || die "$(tr_msg mw_env_sync)"
            ABOX_DIE_HOOK="$_old_die_hook"
            msg "${GREEN}$(tr_msg manage_ss_whitelist_open_mode)${NC}"
            pause_return
            ;;
        *) return 0 ;;
    esac
}

# SYD-B E22: remove service users ONLY when this script provably
# created them (recorded in .created-service-users by
# ensure_abox_runtime_identity). A pre-existing abox-* user with no
# record is kept, however it looks: appearance is not provenance.
# Best-effort: a failure warns and never blocks cleanup. Groups are
# not removed.
remove_abox_created_service_users() {
    local rec='' u='' shell='' _pu='' _rest='' _line='' _rec_uid='' _uid='' _safe_grp='' _g='' _kept='' _new='' _moved=0 _orig_gid=''
    rec="${ABOX_DIR:-/etc/ddr}/.created-service-users"
    if [[ ! -f "$rec" || -L "$rec" ]]; then
        for u in abox-xray abox-singbox abox-hysteria; do
            if getent passwd "$u" >/dev/null 2>&1; then
                msg "${YELLOW}[!] Service user ${u} exists but is not recorded as created by this script; keeping it.${NC}" >&2
            fi
        done
        return 0
    fi
    _kept=$(mktemp /tmp/A-Box-kept-users.XXXXXX) || return 1
    while IFS= read -r _line; do
        [[ -n "$_line" ]] || continue
        case "$_line" in
            *:* ) u="${_line%%:*}"; _rec_uid="${_line#*:}" ;;
            * ) u="$_line"; _rec_uid='' ;;
        esac
        case "$u" in abox-xray|abox-singbox|abox-hysteria) ;; *) msg "${YELLOW}[!] Ignoring unexpected recorded service user ${u}.${NC}" >&2; printf '%s\n' "$_line" >> "$_kept"; continue ;; esac
        if ! getent passwd "$u" >/dev/null 2>&1; then continue; fi
        # R14C10-02: an old name-only record cannot verify the UID;
        # keep it conservatively instead of deleting by name alone.
        if [[ -z "$_rec_uid" ]]; then
            msg "${YELLOW}[!] Service user ${u} has an old name-only record; UID cannot be verified, keeping it (manual cleanup required).${NC}" >&2
            printf '%s\n' "$_line" >> "$_kept"
            continue
        fi
        _uid=$(getent passwd "$u" | awk -F: '{print $3}')
        if [[ "$_uid" != "$_rec_uid" ]]; then
            msg "${YELLOW}[!] Service user ${u} UID changed (recorded ${_rec_uid}, now ${_uid}); name may have been reused, keeping it.${NC}" >&2
            printf '%s\n' "$_line" >> "$_kept"
            continue
        fi
        shell=$(getent passwd "$u" | awk -F: '{print $7}')
        case "$shell" in /usr/sbin/nologin|/sbin/nologin|/bin/false) ;; *) msg "${YELLOW}[!] Service user ${u} has an interactive shell; keeping it.${NC}" >&2; printf '%s\n' "$_line" >> "$_kept"; continue ;; esac
        if command -v pgrep >/dev/null 2>&1 && pgrep -u "$u" >/dev/null 2>&1; then
            msg "${YELLOW}[!] Service user ${u} still has running processes; keeping it.${NC}" >&2
            printf '%s\n' "$_line" >> "$_kept"
            continue
        fi
        # R9-06 (supersedes the R10C10-01 shape test): protect a
        # pre-existing same-name group from userdel (USERGROUPS_ENAB
        # deletes the primary group). Shape cannot prove provenance —
        # a foreign group can have GID == UID with no other members,
        # exactly like a clean A-Box user-private group — so the user
        # is ALWAYS moved off the same-name group first; userdel then
        # cannot delete it. The group itself is left behind, per
        # "Groups are not removed" above.
        _moved=0
        # R37-01: record the ORIGINAL primary group (passwd field 4)
        # before any move. The old code restored to the same-name
        # group, which was never this user's group when its primary
        # group was a foreign one.
        _orig_gid=$(getent passwd "$u" | awk -F: '{print $4}')
        if [[ ! "$_orig_gid" =~ ^[0-9]+$ ]]; then
            msg "${YELLOW}[!] Service user ${u} has no readable primary GID; keeping it.${NC}" >&2
            printf '%s\n' "$_line" >> "$_kept"
            continue
        fi
        if getent group "$u" >/dev/null 2>&1; then
            _safe_grp=''
            for _g in nogroup nobody; do
                if getent group "$_g" >/dev/null 2>&1; then _safe_grp="$_g"; break; fi
            done
            if [[ -z "$_safe_grp" ]] || ! usermod -g "$_safe_grp" "$u" >/dev/null 2>&1; then
                msg "${YELLOW}[!] Service user ${u} has a pre-existing group that cannot be protected; keeping it.${NC}" >&2
                printf '%s\n' "$_line" >> "$_kept"
                continue
            fi
            _moved=1
        fi
        if command -v userdel >/dev/null 2>&1; then
            if userdel "$u" >/dev/null 2>&1; then
                : # deleted: drop the entry
            else
                msg "${YELLOW}[!] Could not remove service user ${u}; keeping it.${NC}" >&2
                printf '%s\n' "$_line" >> "$_kept"
                # R37-01: the user was moved off its same-name group
                # above to protect that group from userdel. Since the
                # user is kept, move it back to its ORIGINAL primary
                # group (passwd field 4, saved above): the same-name
                # group was never its group when its primary group
                # was a foreign one (userdel never ran, so the
                # original group is still there).
                if (( _moved == 1 )); then
                    usermod -g "$_orig_gid" "$u" >/dev/null 2>&1 || msg "${YELLOW}[!] Could not restore the primary group of service user ${u}; it remains on ${_safe_grp}.${NC}" >&2
                fi
            fi
        else
            msg "${YELLOW}[!] userdel unavailable; keeping service user ${u}.${NC}" >&2
            printf '%s\n' "$_line" >> "$_kept"
            if (( _moved == 1 )); then
                usermod -g "$_orig_gid" "$u" >/dev/null 2>&1 || msg "${YELLOW}[!] Could not restore the primary group of service user ${u}; it remains on ${_safe_grp}.${NC}" >&2
            fi
        fi
    done < "$rec"
    # SYD-B2 E22: also list unrecorded abox-* users (kept, never
    # deleted): a previous cleanup may have removed the record file
    # but left users behind, or users may predate the record.
    while IFS=: read -r _pu _rest || [[ -n "$_pu" ]]; do
        [[ "$_pu" == abox-* ]] || continue
        grep -Eq "^${_pu}(:.*)?$" "$rec" 2>/dev/null || msg "${YELLOW}[!] Service user ${_pu} exists but is not recorded as created by this script; keeping it.${NC}" >&2
    done < <(getent passwd 2>/dev/null || true)
    # R3F06: drop the registry only when nothing was kept; otherwise
    # rewrite it with exactly the kept entries so a transient
    # failure keeps its retry basis.
    if [[ -s "$_kept" ]]; then
        # 05e1-M1: rewrite the registry atomically (temp file + cp +
        # chmod 600 + mv). The old `cat > "$rec"` truncated the
        # registry before copying, swallowed the failure, and the
        # kept-entries file was then deleted, leaving no copy of the
        # retry basis. On any failure here the kept file is NOT
        # deleted (its path is in the warning) and the function fails.
        # Atomicity also means a failed write leaves the old registry
        # untruncated, so it stays a valid retry basis.
        _new=$(mktemp /tmp/A-Box-kept-users-new.XXXXXX) || { msg "${YELLOW}[!] Could not rewrite the service-user registry; kept entries preserved at ${_kept}.${NC}" >&2; return 1; }
        cp -- "$_kept" "$_new" 2>/dev/null || { rm -f -- "$_new"; msg "${YELLOW}[!] Could not rewrite the service-user registry; kept entries preserved at ${_kept}.${NC}" >&2; return 1; }
        chmod 600 "$_new" 2>/dev/null || { rm -f -- "$_new"; msg "${YELLOW}[!] Could not rewrite the service-user registry; kept entries preserved at ${_kept}.${NC}" >&2; return 1; }
        mv -f -- "$_new" "$rec" || { rm -f -- "$_new"; msg "${YELLOW}[!] Could not rewrite the service-user registry; kept entries preserved at ${_kept}.${NC}" >&2; return 1; }
    else
        rm -f -- "$rec" 2>/dev/null || { msg "${YELLOW}[!] Could not remove the service-user registry ${rec}.${NC}" >&2; rm -f -- "$_kept" 2>/dev/null || true; return 1; }
    fi
    rm -f -- "$_kept" 2>/dev/null || true
    return 0
}

# S-UNINSTALL-01: is /usr/local/bin/caddy an A-Box install?
# Authoritative proof is the install-time marker
# /etc/ddr/.abox-caddy-owned, written by install_wallos_caddy after its
# own atomic install (cf. R7C9-01 for cloudflared). A foreign
# same-version binary that install_wallos_caddy early-returned on gets
# no marker. Legacy (pre-marker) installs are removed only when every
# conjunct below holds; any doubt keeps the binary. Fail closed.
abox_caddy_owned() {
    local _unit='' _unit_found=0 _ref='' _dpkg_err='' _dpkg_rc=0 _rpm_err='' _rpm_rc=0
    [[ -f /usr/local/bin/caddy && ! -L /usr/local/bin/caddy ]] || return 1
    if [[ -f /etc/ddr/.abox-caddy-owned ]]; then
        return 0
    fi
    # Legacy: pinned version only. A-Box installs exactly
    # WALLOS_CADDY_VERSION; any other version was not put here by us.
    # A binary that cannot even report a version fails closed here.
    [[ "$(/usr/local/bin/caddy version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" == "v${WALLOS_CADDY_VERSION}" ]] || return 1
    # Legacy: an A-Box-managed caddy front unit must exist, proving
    # A-Box set up the front that uses this binary.
    for _unit in /etc/systemd/system/abox-wallos-caddy.service /etc/init.d/abox-wallos-caddy; do
        if [[ -f "$_unit" ]] && grep -Fxq '# Managed by A-Box' "$_unit" 2>/dev/null; then
            _unit_found=1
            break
        fi
    done
    (( _unit_found == 1 )) || return 1
    # Legacy: a package-owned path is foreign. dpkg -S / rpm -qf exit 0
    # only when a package owns the path; their explicit "not owned"
    # verdicts mean proceed, anything else (e.g. a database error)
    # means unknown, so keep the binary.
    if command -v dpkg >/dev/null 2>&1; then
        _dpkg_err="$(dpkg -S /usr/local/bin/caddy 2>&1 >/dev/null)" || _dpkg_rc=$?
        if (( _dpkg_rc == 0 )); then
            return 1
        fi
        grep -q 'no path found matching pattern' <<< "$_dpkg_err" 2>/dev/null || return 1
    fi
    if command -v rpm >/dev/null 2>&1; then
        _rpm_err="$(rpm -qf /usr/local/bin/caddy 2>&1 >/dev/null)" || _rpm_rc=$?
        if (( _rpm_rc == 0 )); then
            return 1
        fi
        grep -q 'is not owned by any package' <<< "$_rpm_err" 2>/dev/null || return 1
    fi
    # Legacy: any non-A-Box unit/script referencing the binary means
    # something else uses it; keep it. 05e1-M4: the scan must also cover
    # systemd drop-ins (*.service.d/*.conf): an external service can
    # reference the binary only from a drop-in while its main unit
    # shows no trace of it.
    for _ref in /etc/systemd/system/*.service /run/systemd/system/*.service /usr/local/lib/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service /etc/systemd/system/*.service.d/*.conf /run/systemd/system/*.service.d/*.conf /usr/local/lib/systemd/system/*.service.d/*.conf /usr/lib/systemd/system/*.service.d/*.conf /lib/systemd/system/*.service.d/*.conf /etc/init.d/*; do
        [[ -f "$_ref" ]] || continue
        case "$_ref" in
            /etc/systemd/system/abox-wallos-caddy.service|/etc/init.d/abox-wallos-caddy) continue ;;
        esac
        if grep -qF '/usr/local/bin/caddy' "$_ref" 2>/dev/null; then
            return 1
        fi
        # R37-02: a bare `ExecStart=caddy ...` is resolved by systemd
        # through its executable search path to /usr/local/bin/caddy;
        # the absolute-path grep above misses it, so a foreign service
        # using the bare name would lose its binary on cleanup. The
        # second pattern covers indirection (`/usr/bin/env caddy`,
        # `sh -c 'caddy ...'`).
        if grep -qE '^[[:space:]]*Exec[A-Za-z]*=[[:space:]]*[-+:@]*caddy([[:space:]]|$)' "$_ref" 2>/dev/null ||
           grep -qE '^[[:space:]]*Exec[A-Za-z]*=.*[[:space:]]caddy([[:space:]]|$)' "$_ref" 2>/dev/null; then
            return 1
        fi
        # S2 (R37-02 follow-up): init scripts have no Exec* lines, so a
        # foreign init service calling bare `caddy` (a direct command, an
        # OpenRC `command="caddy"` assignment, or `sh -c 'caddy ...'`)
        # was invisible to the checks above and would lose its binary on
        # cleanup. Comment lines are stripped first (a comment merely
        # mentioning caddy is not a consumer); any other match keeps the
        # binary (fail-closed direction).
        case "$_ref" in
            /etc/init.d/*)
                if grep -vE '^[[:space:]]*#' "$_ref" 2>/dev/null | grep -qE $'^[[:space:]]*caddy([[:space:]]|$)' ||
                   grep -vE '^[[:space:]]*#' "$_ref" 2>/dev/null | grep -qE $'[[:space:]\'"(=]caddy([[:space:]]|[\'\";)]|$)'; then
                    return 1
                fi
                ;;
        esac
    done
    return 0
}

# L-07: runtime state files a protocol/environment reset must remove.
# Shared by do_cleanup (outside the Argo failure gate) and
# check_virgin_state so the two enumerations cannot drift apart.
# Best-effort throughout (rm -f ... || true): a reset must not die
# on a single stale file. The traffic quartet (.desired_state,
# .traffic-block-state, .traffic-pre-block-states*,
# .traffic-rollover-in-progress) is removed as one group on purpose:
# H-05 needs the pre-block snapshot to unblock across months, so the
# block state and its snapshot must never be separated.
remove_ddr_runtime_state_files() {
    rm -f "$ROUTING_STATE_FILE" "$ABOX_DIR/.extra-uuids" "$ABOX_DIR/.traffic-pair-state" \
        "$ABOX_DIR/.desired_state" "$ABOX_DIR/.traffic-block-state" \
        "$ABOX_DIR/user-guard-runner.sh" \
        "${ROUTING_STATE_FILE}.applied" "${ROUTING_STATE_FILE}.applied-xray" "${ROUTING_STATE_FILE}.applied-singbox" \
        "$ABOX_DIR"/.traffic-pre-block-states* \
        "$ABOX_DIR/.traffic-rollover-in-progress" \
        "$ABOX_DIR/.xray-cfg-autorecover" "$ABOX_DIR/.xray-cfg-autorecover.status" \
        "$ABOX_DIR/argo.log" "$ABOX_DIR/argo-vmess.log" "$ABOX_DIR/argo-vless.log" \
        2>/dev/null || true
}

do_cleanup() {
    clear; msg "${RED}$(tr_msg cu_running)${NC}"
    init_system_environment
    local uninstall_tx_dir='' uninstall_tx_key='' uninstall_tx_value='' _argo_rm_failed=0 _an='' _au='' _argo_state_moved=0 _argo_f='' _argo_state_expected=0 _argo_state_copied=0 _reg_wipe_failed=0
    if [[ "${1:-}" == full || "${1:-}" == wipe ]]; then
        uninstall_tx_dir=$(mktemp -d /run/A-Box-uninstall-tx.XXXXXX) || die "$(tr_msg cu_tx_dir)"
        chmod 700 "$uninstall_tx_dir" || { rm -rf -- "$uninstall_tx_dir"; die "$(tr_msg cu_tx_perm)"; }
        ABOX_DEPLOY_TX_BACKUP_DIR="$uninstall_tx_dir"
        ABOX_DEPLOY_TX_EPHEMERAL_DIR="$uninstall_tx_dir"
        ABOX_DIE_HOOK='cleanup_ephemeral_deployment_transaction_dir'
    fi
    begin_deployment_transaction 'full A-Box cleanup' xray sing-box hysteria || die 'Cleanup aborted: could not open the backup transaction.'
    if [[ -n "$uninstall_tx_dir" ]]; then
        ensure_backup_auth_key || die "$(tr_msg cu_tx_key_new)"
        IFS= read -r uninstall_tx_value < "$ABOX_BACKUP_KEY" || die "$(tr_msg cu_tx_key_read)"
        uninstall_tx_key="$uninstall_tx_dir/recovery.key"
        write_private_sidecar "$uninstall_tx_key" "$uninstall_tx_value" || die "$(tr_msg cu_tx_key_save)"
        ABOX_DEPLOY_TX_KEY_FILE="$uninstall_tx_key"
    fi
    stop_all_managed_services || die "$(tr_msg cu_stop)"
    clean_nat_rules || die "$(tr_msg cl_nat)"
    clean_input_rules || die "$(tr_msg cl_input)"
    save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
    kill_managed_residual_pids || die "$(tr_msg cu_residual)"
    remove_all_owned_core_families 1 || die "$(tr_msg cl_cores_clean)"
    # M-18 (supplement): all core families are gone (units deleted),
    # so no service can re-apply the grant; revoke the xtables-lock
    # grant before the service users are removed below.
    hy2_hop_xtables_lock_revoke || die "$(tr_msg cl_cores_clean)"
    if [[ -d "$ABOX_DIR/tune-backup" ]]; then
        restore_vps_tune 1 >/dev/null 2>&1 || die "$(tr_msg cu_tune)"
    else
        remove_owned_auxiliary_path /etc/sysctl.d/99-A-Box-tune.conf || die "$(tr_msg cu_sysctl)"
        remove_owned_auxiliary_path /etc/security/limits.d/A-Box.conf || die "$(tr_msg cu_limits)"
        remove_owned_auxiliary_path /etc/modules-load.d/A-Box-bbr.conf || die 'Failed to remove the A-Box BBR module-load config.'
    fi
    remove_all_abox_cron_blocks || die "$(tr_msg cl_cron)"
    remove_owned_auxiliary_path /etc/fail2ban/jail.d/A-Box.local || die "$(tr_msg cl_f2b_jail)"
    remove_owned_auxiliary_path /etc/fail2ban/filter.d/A-Box.conf || die "$(tr_msg cl_f2b_filter)"
    remove_owned_auxiliary_path /etc/logrotate.d/A-Box || die "$(tr_msg cl_logrotate)"
    remove_abox_log_files || die "$(tr_msg cl_log_files)"
    # SYD-B2 E22: logs BEFORE users. userdel also deletes the user's
    # primary group; deleting users first orphans the log files' gid
    # and the safety gate below can never match it again.
    # SYD-B E22: remove only provably self-created service users;
    # best-effort, never blocks the cleanup itself.
    remove_abox_created_service_users || true
    # Argo units/binary, WARP/Argo/traffic state and the Wallos fail2ban
    # pair are outside the managed-path lists; remove them best-effort.
    # R15-F10-02: a removal failure must never be swallowed and then
    # followed by destroying the binary, token and state: on any failure
    # the Argo assets are kept for retry and the cleanup reports failure.
    argo_remove_unit argo || _argo_rm_failed=1
    argo_remove_unit argo-vmess || _argo_rm_failed=1
    argo_remove_unit argo-vless || _argo_rm_failed=1
    # Final verification before any Argo asset is destroyed: no unit
    # file and no manager residue for any of the three units.
    if (( _argo_rm_failed == 0 )); then
        for _an in argo argo-vmess argo-vless; do
            if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                _au="/etc/systemd/system/${_an}.service"
            else
                _au="/etc/init.d/${_an}"
            fi
            if [[ -e "$_au" || -L "$_au" ]] || ! argo_unit_stopped_confirmed "$_an"; then
                _argo_rm_failed=1
            fi
        done
    fi
    if (( _argo_rm_failed == 1 )); then
        msg "${YELLOW}[!] Argo unit removal incomplete; cloudflared binary, token and Argo state are kept for retry.${NC}"
    else
        # R1-10-F4: cloudflared is deleted only when A-Box ownership is recorded;
        # a foreign binary is kept. (do_cleanup tears Wallos down below, so no
        # remaining-consumer gate is needed here, unlike check_virgin_state.)
        if [[ -f /etc/ddr/.abox-cloudflared-owned ]]; then
            # 05e1-M2: remove the binary first and the ownership marker
            # only once the binary is gone: a failed binary removal in
            # the same rm as the marker still deletes the marker, and
            # the leftover binary can then never be removed again (the
            # marker is the deletion gate). Record the failure.
            if rm -f /usr/local/bin/cloudflared; then
                rm -f /etc/ddr/.abox-cloudflared-owned || true
            else
                msg "${YELLOW}[!] Failed to remove /usr/local/bin/cloudflared; keeping the ownership marker so the leftover binary can be removed later.${NC}"
            fi
        fi
        # L-07: only Argo's own state stays gated on a successful unit
        # removal (a retry needs its token and state). Everything else
        # is removed unconditionally below, outside the gate.
        rm -f "$ARGO_STATE_FILE" "$ABOX_DIR/.argo-token" 2>/dev/null || true
        # R37-03: a failed token/state removal must not be swallowed --
        # the success branches below only check _argo_rm_failed, so a
        # leftover credential would be reported as cleaned. Verify
        # both paths are really gone; on failure keep the assets for
        # retry (the existing _argo_rm_failed machinery) and report.
        if [[ -e "$ARGO_STATE_FILE" || -L "$ARGO_STATE_FILE" || -e "$ABOX_DIR/.argo-token" || -L "$ABOX_DIR/.argo-token" ]]; then
            msg "${YELLOW}[!] Argo token/state removal failed; cloudflared binary, token and Argo state were kept for retry.${NC}"
            _argo_rm_failed=1
        fi
    fi
    # L-07: the non-Argo runtime state leaves the Argo failure gate as
    # one group (remove_ddr_runtime_state_files): a failed Argo removal
    # must never keep routing/traffic state behind, and the traffic
    # quartet must never be split, or a reset leaves "blocked, no
    # snapshot" behind (H-05). Best-effort, like the old rm line.
    remove_ddr_runtime_state_files
    # R12C10-01: refuse a mountpoint at or under standalone-links.d before
    # deleting, and propagate deletion failures instead of suppressing them.
    path_tree_has_mountpoint /etc/ddr/standalone-links.d && die 'Refusing to delete /etc/ddr/standalone-links.d: mountpoint present in its tree.'
    rm -rf -- /etc/ddr/standalone-links.d || die 'Failed to delete /etc/ddr/standalone-links.d.'

    for _wf in /etc/fail2ban/filter.d/A-Box-wallos.conf /etc/fail2ban/jail.d/A-Box-wallos.local /etc/fail2ban/action.d/A-Box-wallos-dockeruser.conf; do
        if [[ -f "$_wf" ]] && grep -Fxq '# Managed by A-Box' "$_wf" 2>/dev/null; then rm -f "$_wf" || true; fi
    done
    # M-12(3): /usr/local/bin/wgcf is intentionally NOT removed here:
    # no A-Box ownership marker exists for it, so deleting it could
    # destroy a foreign binary. Removal waits for an unmarked-binary
    # ownership rule (see arbitration).
    # S-UNINSTALL-01: decide caddy ownership BEFORE wallos_https_teardown
    # deletes the front unit the legacy rule needs as evidence. The
    # binary itself is removed below, after the front is down.
    local _caddy_owned=0
    abox_caddy_owned && _caddy_owned=1
    wallos_https_teardown >/dev/null 2>&1 || die 'Wallos HTTPS teardown failed; aborting cleanup.'
    wallos_cftunnel_teardown >/dev/null 2>&1 || die 'Wallos tunnel teardown failed; aborting cleanup.'
    wallos_stack_teardown || die 'Wallos stack teardown failed; aborting cleanup.'
    # M-28: reclaim every firewall opening the Wallos install
    # registered (public port + 80/tcp). 80/tcp is kept when the
    # Hysteria HTTP-01 challenge still needs it; the helper says so.
    wallos_fw_reclaim_registered || msg "${YELLOW}[!] Failed to reclaim a Wallos firewall opening during uninstall; check the firewall rules manually.${NC}"
    # S-UNINSTALL-01: remove the caddy binary only when ownership was
    # proven above AND the front is confirmed stopped; a still-running
    # front, or any doubt in the ownership verdict, keeps the binary.
    if (( _caddy_owned == 1 )) && ! is_service_running abox-wallos-caddy 2>/dev/null; then
        # 05e1-M2: binary first, marker only once the binary is gone
        # (same reason as the cloudflared block above).
        if rm -f /usr/local/bin/caddy; then
            rm -f /etc/ddr/.abox-caddy-owned || true
        else
            msg "${YELLOW}[!] Failed to remove /usr/local/bin/caddy; keeping the ownership marker so the leftover binary can be removed later.${NC}"
        fi
    fi
    # R39-M1: track the failure for the non-full tail below (the
    # full/wipe path needs no such check: rm -rf $ABOX_DIR destroys
    # the registries anyway, and its failure already dies).
    users_registries_wipe || { msg "${YELLOW}[!] $(tprintf cu_users_note '/etc/ddr/users.d')${NC}"; _reg_wipe_failed=1; }
    abox_zram_teardown || die 'zram teardown failed; aborting cleanup.'
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        if systemctl list-unit-files fail2ban.service >/dev/null 2>&1 && systemctl cat fail2ban.service >/dev/null 2>&1; then
            systemctl try-restart fail2ban >/dev/null 2>&1 || msg "${YELLOW}[!] $(tr_msg cl_f2b_restart_clean)${NC}"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || die "$(tr_msg cl_reload_clean)"
    elif [[ "${INIT_SYS:-}" == openrc ]] && [[ -x /etc/init.d/fail2ban ]]; then
        { rc-service fail2ban status >/dev/null 2>&1 && rc-service fail2ban restart >/dev/null 2>&1 9>&- 10>&-; } || msg "${YELLOW}[!] $(tr_msg cl_f2b_restart_clean)${NC}"
    fi
    if [[ "${1:-}" == full || "${1:-}" == wipe ]]; then
        # Wipe tier (keep the script): stash the persisted script copy
        # inside the transaction dir before ABOX_DIR is destroyed; it
        # is restored below as the sole resident and the managed
        # shortcuts (the current .shortcut state names) are re-installed by setup_shortcut.
        # Full tier: the managed shortcuts go with everything else;
        # a pre-existing /usr/local/bin/sb is out of scope and left alone.
        local _wipe_script_copy=''
        local _wipe_copy_failed=0
        local _wipe_shortcut_failed=0
        if [[ "${1:-}" == wipe ]]; then
            if [[ -f "$ABOX_DIR/A-Box.sh" && ! -L "$ABOX_DIR/A-Box.sh" ]]; then
                _wipe_script_copy="$ABOX_DIR/A-Box.sh"
            elif [[ -f "$0" && ! -L "$0" ]]; then
                _wipe_script_copy="$0"
            fi
            if [[ -n "$_wipe_script_copy" && -n "$uninstall_tx_dir" ]]; then
                cp -- "$_wipe_script_copy" "$uninstall_tx_dir/wipe-keep-A-Box.sh" 2>/dev/null || { _wipe_copy_failed=1; _wipe_script_copy=''; }
            else
                _wipe_script_copy=''
            fi
            # M-12(3): stash the shortcut state alongside the script so
            # setup_shortcut below re-installs the same command names.
            # The state files live under ABOX_DIR and would otherwise be
            # destroyed with it. A missing state file is fine (fresh
            # install); a present-but-uncopyable one aborts like the
            # script copy below.
            if [[ -f "$(shortcut_state_path)" && ! -L "$(shortcut_state_path)" ]]; then
                cp -- "$(shortcut_state_path)" "$uninstall_tx_dir/wipe-keep-shortcut" 2>/dev/null || _wipe_shortcut_failed=1
            fi
            if [[ -f "$(shortcut_migrate_path)" && ! -L "$(shortcut_migrate_path)" ]]; then
                cp -- "$(shortcut_migrate_path)" "$uninstall_tx_dir/wipe-keep-shortcut-migrate" 2>/dev/null || _wipe_shortcut_failed=1
            fi
        else
            local _sc_path='' _sc_rc=0
            shortcut_read_state || _sc_rc=$?
            if (( _sc_rc == 1 )); then
                msg "${YELLOW}[!] $(tprintf cu_shortcut_state_bad "$SHORTCUT_ERR")${NC}"
            fi
            while IFS= read -r _sc_path; do
                remove_abox_shortcut "$_sc_path" || die "$(tprintf cu_shortcut_path "$_sc_path")"
            done < <(shortcut_managed_paths)
            rm -f -- "$(shortcut_state_path)" "$(shortcut_migrate_path)" 2>/dev/null || die "$(tr_msg cu_shortcut)"
        fi
        # R12C10-02: a selected keep-script whose copy failed must abort
        # before ABOX_DIR is destroyed; otherwise the wipe promise is lost.
        if (( _wipe_copy_failed == 1 )); then die 'Wipe keep-script copy failed; aborting before ABOX_DIR is destroyed.'; fi
        if (( _wipe_shortcut_failed == 1 )); then die 'Wipe shortcut-state copy failed; aborting before ABOX_DIR is destroyed.'; fi
        # Do not destroy ABOX_DIR until managed Swap has been removed successfully.
        # The ownership marker is required for a safe retry when /etc/fstab or swapoff fails.
        if ! remove_abox_swap; then
            msg "${YELLOW}[!] $(tprintf cu_swap_note "$ABOX_DIR")${NC}"
            die "$(tr_msg cu_swap_die)"
        fi
        wallos_stack_teardown purge-data || die 'Wallos stack teardown (purge-data) failed; aborting cleanup before ABOX_DIR is deleted.'
        # M-21(2): restore the pre-A-Box DNS (and timezone) BEFORE
        # $ABOX_DIR is destroyed: the rollback snapshots live inside
        # it, and deleting them first would leave the A-Box DNS
        # takeover in place permanently with no way back. A failed
        # restore aborts the uninstall: the snapshot is destroyed by
        # the rm below and cannot be retried afterwards.
        if [[ -f "$DNS_BACKUP_DIR/COMPLETE" ]]; then
            restore_dns_snapshot "$DNS_BACKUP_DIR" || die 'DNS rollback snapshot restore failed; aborting uninstall before the snapshot is destroyed.'
        else
            # No valid snapshot: remove A-Box's own DNS drop-ins so
            # resolved falls back to the distribution default, and
            # leave any proxy service alone (without a snapshot it
            # cannot be told apart from a user-owned one). Check DNS
            # manually after the uninstall, and stop/disable
            # dnscrypt-proxy yourself if A-Box installed it.
            remove_owned_auxiliary_path /etc/systemd/resolved.conf.d/99-abox-dns.conf || die 'Failed to remove the A-Box DNS drop-in.'
            remove_owned_auxiliary_path /etc/systemd/system/dnscrypt-proxy.socket.d/abox-listen.conf || die 'Failed to remove the A-Box dnscrypt-proxy socket drop-in.'
            local _resolved_restarted=0
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload >/dev/null 2>&1 || msg "${YELLOW}[!] systemd daemon-reload failed during uninstall; DNS drop-in removal may not have taken effect.${NC}"
                if systemctl is-enabled dnscrypt-proxy.socket >/dev/null 2>&1 || systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
                    systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || true
                fi
                if systemctl restart systemd-resolved >/dev/null 2>&1; then
                    _resolved_restarted=1
                else
                    msg "${YELLOW}[!] systemd-resolved restart failed during uninstall; check DNS manually.${NC}"
                fi
            fi
            # W7-OBS-5: the old unconditional message claimed resolved
            # "was restarted with distribution defaults" even when the
            # restart above just failed (or systemd is absent). Word
            # it by the observed outcome instead.
            if (( _resolved_restarted == 1 )); then
                msg "${YELLOW}[!] No valid DNS rollback snapshot found; A-Box DNS drop-ins were removed and systemd-resolved was restarted with distribution defaults. Check DNS manually.${NC}"
            else
                msg "${YELLOW}[!] No valid DNS rollback snapshot found; A-Box DNS drop-ins were removed but systemd-resolved was not restarted. DNS is left as-is; check DNS manually.${NC}"
            fi
        fi
        if [[ -d "$ABOX_DIR/.tz-rollback" ]]; then
            restore_timezone_snapshot "$ABOX_DIR/.tz-rollback" || die 'Timezone rollback snapshot restore failed; aborting uninstall before the snapshot is destroyed.'
        fi
        path_tree_has_mountpoint "$ABOX_DIR" && die "$(tr_msg cu_mount)"
        # M-12(3): when Argo removal failed, its token/state were kept
        # above for retry; move them into the transaction dir before
        # ABOX_DIR is destroyed, so the retry still has them.
        if (( _argo_rm_failed == 1 )) && [[ -n "$uninstall_tx_dir" ]]; then
            install -d -m 700 "$uninstall_tx_dir/argo-retry" 2>/dev/null || true
            for _argo_f in .argo-token .extra-uuids .traffic-pair-state .desired_state .traffic-block-state .argo-state .routing-state .abox-cloudflared-owned; do
                if [[ -f "$ABOX_DIR/$_argo_f" && ! -L "$ABOX_DIR/$_argo_f" ]]; then
                    # 05e1-M3: count what should be preserved and what
                    # actually was. The old code only recorded "at
                    # least one copy succeeded", so a partially failed
                    # copy still deleted every original below.
                    _argo_state_expected=$(( _argo_state_expected + 1 ))
                    if cp -a -- "$ABOX_DIR/$_argo_f" "$uninstall_tx_dir/argo-retry/$_argo_f" 2>/dev/null; then
                        _argo_state_copied=$(( _argo_state_copied + 1 ))
                        _argo_state_moved=1
                    fi
                fi
            done
            # Abort before ABOX_DIR is destroyed when the preserve
            # copy is incomplete: the originals are the retry basis,
            # and the deployment transaction is still active, so die
            # can still roll the pre-uninstall backup back.
            if (( _argo_state_expected > 0 && _argo_state_copied < _argo_state_expected )); then
                die "Argo state preservation incomplete (${_argo_state_copied}/${_argo_state_expected} files copied); aborting uninstall before ABOX_DIR is destroyed so the originals can be retried."
            fi
        fi
        # Keep the deployment transaction active until the final data-directory
        # deletion has been confirmed. If rm/race/permission errors occur, the
        # transaction hook must still be able to restore the pre-uninstall backup.
        rm -rf -- "$ABOX_DIR" || die "$(tr_msg cu_datadir)"
        [[ ! -e "$ABOX_DIR" && ! -L "$ABOX_DIR" ]] || die "$(tr_msg cu_datadir_left)"
        if [[ "${1:-}" == wipe ]]; then
            install -d -m 755 "$ABOX_DIR" || die "$(tr_msg cu_datadir)"
            if [[ -n "$_wipe_script_copy" ]]; then
                install_file_atomically "$uninstall_tx_dir/wipe-keep-A-Box.sh" "$ABOX_DIR/A-Box.sh" 755 || die "$(tr_msg cu_datadir)"
            else
                msg "${YELLOW}[!] $(tr_msg cu_wipe_noscript)${NC}"
            fi
            # M-12(3): restore the stashed shortcut state (mode 600,
            # like shortcut_write_state writes it) so setup_shortcut
            # re-installs the pre-wipe command names.
            if [[ -f "$uninstall_tx_dir/wipe-keep-shortcut" && ! -L "$uninstall_tx_dir/wipe-keep-shortcut" ]]; then
                install_file_atomically "$uninstall_tx_dir/wipe-keep-shortcut" "$ABOX_DIR/.shortcut" 600 || die "$(tr_msg cu_datadir)"
            fi
            if [[ -f "$uninstall_tx_dir/wipe-keep-shortcut-migrate" && ! -L "$uninstall_tx_dir/wipe-keep-shortcut-migrate" ]]; then
                install_file_atomically "$uninstall_tx_dir/wipe-keep-shortcut-migrate" "$ABOX_DIR/.shortcut-migrate" 600 || die "$(tr_msg cu_datadir)"
            fi
            setup_shortcut || die "$(tr_msg cu_shortcut)"
        fi
        # L6: preserve the transaction backup BEFORE the commit clears
        # the transaction directory; a failed transfer aborts the
        # cleanup (die rolls the pre-uninstall snapshot back) instead
        # of silently deleting the only backup.
        preserve_uninstall_transaction_backup || die 'Uninstall transaction backup preservation failed; aborting before commit so the pre-uninstall backup is not lost.'
        commit_deployment_transaction
        if (( _argo_rm_failed == 1 )); then
            if (( _argo_state_moved == 1 )); then
                msg "${YELLOW}[!] Cleanup finished with Argo removal incomplete; cloudflared binary was kept and Argo token/state were moved to ${uninstall_tx_dir}/argo-retry for retry.${NC}"
            else
                msg "${YELLOW}[!] Cleanup finished with Argo removal incomplete; cloudflared binary, token and Argo state were kept for retry.${NC}"
            fi
            exit 1
        fi
        msg "${GREEN}$(tr_msg cu_full_done)${NC}"
        exit 0
    fi
    remove_abox_env_file || die "$(tr_msg cl_env_clean)"
    for runtime_file in "$ABOX_DIR/traffic_monitor.sh" "$ABOX_DIR/geo_update.sh" "$ABOX_DIR/socket_probe.sh"; do
        remove_owned_runtime_helper "$runtime_file" || die "$(tprintf cl_runtime_clean "$runtime_file")"
    done
    remove_sni_candidate_cache || die "$(tr_msg cl_sni_clean)"
    if [[ -f "$DEPS_MARKER" && ! -L "$DEPS_MARKER" ]]; then rm -f -- "$DEPS_MARKER" || die "$(tr_msg cl_deps_clean)"; fi
    setup_shortcut
    commit_deployment_transaction
    remove_abox_swap || msg "${YELLOW}[!] $(tr_msg cl_swap_keep)${NC}"
    if (( _argo_rm_failed == 1 )); then
        msg "${YELLOW}[!] Cleanup finished with Argo removal incomplete; cloudflared binary, token and Argo state were kept for retry.${NC}"
        pause_return
        return 1
    fi
    if (( _reg_wipe_failed == 1 )); then
        msg "${YELLOW}[!] Cleanup finished with user registry removal incomplete; credentials may remain on disk.${NC}"
        pause_return
        return 1
    fi
    msg "${GREEN}$(tr_msg cu_proxy_done)${NC}"
    pause_return
}

preflight_reset_ownership() {
    [[ -n "${ABOX_DIR:-}" ]] || return 1
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        validate_abox_env_file_for_write || return 1
    fi
    local runtime_file srv core_paths path sni_cache="$ABOX_DIR/A-Box-sni-candidates.txt"
    if [[ -e "$sni_cache" || -L "$sni_cache" ]]; then
        [[ -f "$sni_cache" && ! -L "$sni_cache" ]] || return 1
        path_owned_by_root "$sni_cache" || return 1
        path_mode_has_no_group_other_write "$sni_cache" || return 1
        path_tree_has_mountpoint "$sni_cache" && return 1
    fi
    for runtime_file in "$ABOX_DIR/traffic_monitor.sh" "$ABOX_DIR/geo_update.sh" "$ABOX_DIR/socket_probe.sh"; do
        [[ ! -e "$runtime_file" && ! -L "$runtime_file" ]] && continue
        auxiliary_content_is_abox_managed "$runtime_file" "$runtime_file" || return 1
        path_tree_has_mountpoint "$runtime_file" && return 1
    done
    for srv in xray sing-box hysteria; do
        abox_owns_service "$srv" || continue
        core_paths=$(core_family_paths "$srv") || return 1
        while IFS= read -r path; do
            [[ -e "$path" || -L "$path" ]] || continue
            path_tree_has_mountpoint "$path" && return 1
        done <<< "$core_paths"
    done
    return 0
}


# ================= Protocol removal (menu 16) =================
# Inbounds are enumerated from the live core configs (ground truth), and
# removed per-tag with the same discipline as deployments: the new config
# must pass the core's own check before it is installed atomically, and a
# failed restart restores the snapshot.
protocol_label() { # $1 = config tag, $2 = protocol/type (fallback display)
    local tag="${1:-}" proto="${2:-}"
    case "$tag" in
        latest-vision) printf '%s' 'VLESS-Vision-Reality (Latest Xray)' ;;
        latest-xhttp) printf '%s' 'VLESS-XHTTP-Reality (Latest Xray)' ;;
        latest-ss) printf '%s' 'SS-2022 (Latest Xray)' ;;
        vmess-ws-in) printf '%s' 'VMess-WS (Argo)' ;;
        vless-ws-in) printf '%s' 'VLESS-WS (Argo)' ;;
        *vision*) printf '%s' 'VLESS-Vision-Reality' ;;
        *xhttp*) printf '%s' 'VLESS-XHTTP-Reality' ;;
        *shadowtls*) printf '%s' 'ShadowTLS' ;;
        *trojan*) printf '%s' 'Trojan-Reality' ;;
        *tuic*) printf '%s' 'TUIC' ;;
        *anytls*) printf '%s' 'AnyTLS' ;;
        *socks*|*mixed*) printf '%s' 'SOCKS5/Mixed' ;;
        *hysteria*|*hy2*) printf '%s' 'Hysteria 2' ;;
        *ss*) printf '%s' 'Shadowsocks-2022' ;;
        *) printf '%s' "${proto:-$tag}" ;;
    esac
}

# One line per deployed inbound: core<TAB>tag<TAB>protocol<TAB>port
# (the internal "api" inbound is infrastructure, never listed).
# Moved out of the deleted xray-latest block (2026-11-09): reads the
# Hysteria listen port for protocol_inventory.
xl_hy2_port() {
    local cfg='/etc/hysteria/config.yaml' line val q
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 0
    line=$(grep -E '^[[:space:]]*listen:' "$cfg" 2>/dev/null | head -1) || return 0
    [[ -n "$line" ]] || return 0
    val="${line#*:}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    [[ -n "$val" ]] || return 0
    q="${val:0:1}"
    if [[ "$q" == '"' || "$q" == "'" ]]; then
        val="${val:1}"
        val="${val%%"$q"*}"
    else
        val="${val%%#*}"
        val="${val%"${val##*[![:space:]]}"}"
    fi
    [[ -n "$val" ]] || return 0
    if [[ "$val" == *:* ]]; then val="${val##*:}"; fi
    val="${val//[[:space:]]/}"
    [[ "$val" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$val"
}

protocol_inventory() {
    local cfg='' failed=0 _stripped=''
    cfg="$XRAY_SLOT_CFG"
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        # R38-M3: jq returns 0 with no output on empty input, so a
        # config that strips to blank was misread as "no protocols".
        # Require non-blank stripped content (same guard as
        # sync_env_ports_after_removal 05e2-M3); a valid
        # {"inbounds":[]} still reports no protocols.
        _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || { echo "A-Box: protocol_inventory: cannot parse $cfg" >&2; failed=1; _stripped=''; }
        if [[ -n "${_stripped//[[:space:]]/}" ]]; then
            printf '%s' "$_stripped" | jq -r '.inbounds[]? | select(.tag != null and .tag != "" and .tag != "api") | "xray\t\(.tag)\t\(.protocol // "")\t\(.port // "")"' || { echo "A-Box: protocol_inventory: cannot parse $cfg" >&2; failed=1; }
        elif (( failed == 0 )); then
            echo "A-Box: protocol_inventory: $cfg is empty after stripping comments" >&2
            failed=1
        fi
    fi
    cfg='/etc/sing-box/config.json'
    if [[ -f "$cfg" && ! -L "$cfg" ]]; then
        # R38-M3: same non-blank guard as the xray branch above.
        _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || { echo "A-Box: protocol_inventory: cannot parse $cfg" >&2; failed=1; _stripped=''; }
        if [[ -n "${_stripped//[[:space:]]/}" ]]; then
            printf '%s' "$_stripped" | jq -r '.inbounds[]? | select(.tag != null and .tag != "" and .tag != "api") | "sing-box\t\(.tag)\t\(.type // "")\t\(.listen_port // "")"' || { echo "A-Box: protocol_inventory: cannot parse $cfg" >&2; failed=1; }
        elif (( failed == 0 )); then
            echo "A-Box: protocol_inventory: $cfg is empty after stripping comments" >&2
            failed=1
        fi
    fi
    if [[ -f /etc/hysteria/config.yaml && ! -L /etc/hysteria/config.yaml ]]; then
        printf 'hy2\thy2-official\thysteria2\t%s\n' "$(xl_hy2_port)"
    fi
    return "$failed"
}

_protocol_cfg_of() { # $1 = core -> cfg|bin|svc
    case "$1" in
        xray) printf '%s|%s|%s' "$XRAY_SLOT_CFG" '/usr/local/bin/xray' 'xray' ;;
        sing-box) printf '%s|%s|%s' "${ABOX_SB_CFG:-/etc/sing-box/config.json}" '/usr/local/bin/sing-box' 'sing-box' ;;
        *) return 1 ;;
    esac
}

# W2-FAIL-1: the automatic xray-config recovery (xray_config_autorecover,
# src/06) restores from historical deployment backups. A backup taken at
# deploy time still carries every protocol the user later deleted, so
# after a genuine config fault it would resurrect deleted protocols.
# Publish the live xray config as the recovery's desired state whenever
# a removal rewrites it. The file is separate from the historical
# backups (manual restore keeps using those) and is only ever consumed
# when it matches the current .env expectations exactly (see
# _xrc_desired_config_usable in src/06), so a stale file is ignored.
_xrc_desired_config_path() {
    printf '%s' "${ABOX_DIR:-/etc/ddr}/.xray-desired-config.json"
}

# Publish the live xray config as the auto-recovery desired state.
# Best-effort: the config was just validated by the caller's own
# xray run -test and installed atomically, so a publish failure only
# degrades the corruption-restore layer to the historical backups;
# the .env expectations (the probe's live trigger) are unaffected.
# rc 0 = published, 1 = not published (caller warns, delete stands).
_xrc_publish_desired_config() {
    local cfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" dest='' _sz=''
    dest=$(_xrc_desired_config_path) || return 1
    [[ -f "$cfg" && ! -L "$cfg" && -r "$cfg" ]] || return 1
    _sz=$(stat -c %s -- "$cfg" 2>/dev/null || echo 0)
    [[ "$_sz" =~ ^[0-9]+$ && "$_sz" -gt 0 && "$_sz" -le 1048576 ]] || return 1
    install_file_atomically "$cfg" "$dest" 600 || return 1
    return 0
}

# _remove_inbounds_from_config CORE TAG...   |   CORE --all
_remove_inbounds_from_config() {
    local core="$1"; shift
    local info='' cfg='' bin='' svc='' bak='' tmp_cfg='' tags_json='' filter='' route_filter='' routes_before=0 routes_after=0 src_cfg=''
    info=$(_protocol_cfg_of "$core") || return 1
    IFS='|' read -r cfg bin svc <<< "$info"
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    # Delete through the same JSONC-stripped view the inventory
    # uses. Prepare backup + stripped input BEFORE reading tags,
    # so all three jq reads share one input snapshot; the live
    # file is never rewritten before the new config validates.
    [[ "${1:-}" == '--all' || $# -ge 1 ]] || return 1
    bak=$(mktemp /tmp/A-Box-rm-bak.XXXXXX) || return 1
    cp -f -- "$cfg" "$bak" || { rm -f "$bak"; return 1; }
    src_cfg=$(mktemp /tmp/A-Box-rm-cfg.XXXXXX) || { rm -f "$bak"; return 1; }
    # R16-F08-02: create the jq output directly with mktemp
    # (O_CREAT|O_EXCL, random suffix); the old reserve derived a
    # predictable "$src_cfg.json" name a pre-planted FIFO could block.
    local _rm_cfg_d=''
    _rm_cfg_d=$(mktemp -d /tmp/A-Box-rm-cfg.XXXXXX) || { rm -f "$src_cfg" "$bak"; return 1; }
    tmp_cfg="$_rm_cfg_d/config.json"
    if ! jsonc_strip_comments "$bak" > "$src_cfg" 2>/dev/null; then
        rm -f "$src_cfg" "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"
        return 1
    fi
    if [[ "${1:-}" == '--all' ]]; then
        # Clear-all keeps the internal "api" inbound (traffic-stats
        # infrastructure, not a node protocol) and drops everything else.
        filter='.inbounds |= map(select(.tag == "api"))'
        # Routing cleanup needs the removed set: every non-api tag.
        tags_json=$(set -o pipefail; jq -r '.inbounds[]? | .tag // empty | select(. != "api")' "$src_cfg" 2>/dev/null | jq -R . | jq -s .) || { rm -f "$src_cfg" "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1; }
    else
        tags_json=$(set -o pipefail; printf '%s\n' "$@" | jq -R . | jq -s .) || { rm -f "$src_cfg" "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1; }
        filter='.inbounds |= map(select(.tag as $t | ($tags | index($t)) == null))'
    fi
    # U147: drop/strip routing rules that reference a removed inbound.
    # xray uses inboundTag, sing-box uses inbound; either may be a
    # string or an array. A rule survives when at least one inbound
    # reference survives; a rule left with no inbound reference at all
    # is dropped (an emptied list would otherwise match all traffic).
    # Rules without any inbound field are untouched. An invert rule
    # is never stripped: it rejects everything except the listed
    # inbounds, so deleting it would revoke the reject policy.
    route_filter='def strip_field(f):
      if .invert == true then .
      elif has(f) then
        if (.[f] | type) == "string" then
          if (.[f] as $t | ($tags | index($t)) != null) then del(.[f]) else . end
        elif (.[f] | type) == "array" then
          if (.[f] | length) > 0 then
            (.[f] |= map(select(. as $t | ($tags | index($t)) == null))) | if (.[f] | length) == 0 then del(.[f]) else . end
          else . end
        else . end
      else . end;
    def strip_rule:
      (strip_field("inboundTag") | strip_field("inbound")) as $r
      | (if ($r | has("rules") and ($r.rules | type) == "array") then
           ($r | .rules |= map(strip_rule)
                | if (.invert == true and (.rules != ($r.rules))) then error("cannot safely rewrite inverted logical rule")
                  elif (.mode == "and" and (.rules | length) < ($r.rules | length)) then empty else . end)
         else $r end) as $r2
      | if (($r2 | has("inboundTag") or has("inbound")) or ($r2 | has("rules") and ($r2.rules | length) > 0)) then $r2
        elif (has("inboundTag") or has("inbound") or has("rules")) then empty
        else $r2 end;
    (if .routing.rules then .routing.rules |= map(strip_rule) else . end)
    | (if .route.rules then .route.rules |= map(strip_rule) else . end)'
    filter="$filter | $route_filter"
    routes_before=$(jq -r '[(.routing.rules // []), (.route.rules // [])] | map(length) | add' "$src_cfg" 2>/dev/null || echo 0)
    if ! jq --argjson tags "$tags_json" "$filter" "$src_cfg" > "$tmp_cfg" 2>/dev/null; then
        rm -f "$src_cfg" "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1
    fi
    rm -f "$src_cfg"
    routes_after=$(jq -r '[(.routing.rules // []), (.route.rules // [])] | map(length) | add' "$tmp_cfg" 2>/dev/null || echo 0)
    if [[ "$core" == 'sing-box' ]]; then
        "$bin" check -c "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1; }
    else
        XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$tmp_cfg" >/dev/null 2>&1 || { rm -f "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1; }
    fi
    install_file_atomically "$tmp_cfg" "$cfg" 600 || { rm -f "$tmp_cfg" "$bak"; rm -rf -- "$_rm_cfg_d"; return 1; }
    rm -f "$tmp_cfg"; rm -rf -- "$_rm_cfg_d"
    case "$core" in
        xray) prepare_abox_runtime_permissions xray 2>/dev/null || true ;;
        sing-box) prepare_abox_runtime_read_file "$cfg" sing-box 2>/dev/null || true ;;
    esac
    # H-23 (Carbon R3): restart only when the desired state is RUNNING
    # and the service was already running; the replacement config is
    # already installed, so a stopped stack stays stopped instead of
    # being revived (or rolled back when the restart fails on a down
    # service).
    if service_restart_permitted "$svc"; then
        if ! restart_service_soft "$svc"; then
            local restore_ok=0
            if install_file_atomically "$bak" "$cfg" 600 2>/dev/null || cp -f -- "$bak" "$cfg"; then restore_ok=1; fi
            case "$core" in
                xray) prepare_abox_runtime_permissions xray 2>/dev/null || true ;;
                sing-box) prepare_abox_runtime_read_file "$cfg" sing-box 2>/dev/null || true ;;
            esac
            restart_service_soft "$svc" || true
            if [[ "$restore_ok" == 1 ]]; then
                rm -f "$bak"
            else
                msg "${RED}[!] $(tprintf _remove_inbounds_from_config_restore_failed "$bak")${NC}" >&2
            fi
            return 1
        fi
    fi
    if (( routes_before - routes_after > 0 )); then
        msg "${YELLOW}$(tprintf cl_routes_cleaned "$(( routes_before - routes_after ))")${NC}"
    fi
    # W2-FAIL-1: publish the post-removal config as the auto-recovery
    # desired state (separate from historical backups). Best-effort:
    # a publish failure only degrades the corruption-restore layer
    # to the backups; the delete itself stands.
    if [[ "$core" == 'xray' ]]; then
        _xrc_publish_desired_config || msg "${YELLOW}[!] Could not publish the xray desired config for auto-recovery; a later config fault would restore from a historical backup instead.${NC}"
    fi
    rm -f "$bak"; return 0
}

# Side effects after inbounds were removed from CORE: Argo tunnel units for
# ws inbounds, and the standalone link registrations of the removed tags.
# Remove one node's multi-user registry (single-delete path).
users_registry_remove() { # $1 = core, $2 = tag
    # D1: build the path through the encoder (users_reg_file), never
    # raw. The old regex guard rejected '%' and '/' — the very
    # characters the encoder exists to handle — so registries for
    # such tags were silently never removed. The encoder output is
    # always a single filename component, so no guard is needed.
    local _f=''
    _f=$(users_reg_file "$1" "$2") || return 0
    # R16-F10-02: propagate a failed rm like the adjacent
    # users_registries_wipe does (`rm -f ... || return 1`); the old
    # unconditional `return 0` reported a surviving registry as deleted.
    if [[ -f "$_f" && ! -L "$_f" ]]; then rm -f -- "$_f" || return 1; fi
    # M-29(3): the guard's retry sidecar is part of the registry; leaving
    # it behind resurrects a sync debt for a registry that no longer exists.
    if [[ -f "${_f}.sync-pending" && ! -L "${_f}.sync-pending" ]]; then rm -f -- "${_f}.sync-pending" || return 1; fi
    return 0
}

# Remove every multi-user registry (clear-all / virgin reset):
# once the inbounds are gone the registries are orphans and the
# panel would keep listing ghost users from them.
users_registries_wipe() {
    local _dir="${ABOX_USERS_DIR:-/etc/ddr/users.d}" _f=''
    # R14-F10-02: refuse a symlinked registry dir before the glob can
    # follow it into the link target (same guard as
    # users_registries_remove_core, R8-F04-2). The leaf ! -L guard only
    # covers the last component; a linked dir would delete ordinary
    # files outside the registry. A missing dir stays a no-op success.
    # H2 (R15b residual, hardening): ancestor chain too, like
    # users_registries_remove_core above.
    [[ ! -L "$_dir" ]] || return 1
    path_parent_chain_safe "$_dir" || return 1
    [[ -d "$_dir" ]] || return 0
    for _f in "$_dir"/*.json; do
        [[ -f "$_f" && ! -L "$_f" ]] || continue
        rm -f -- "$_f" || return 1
        # M-29(3): same sidecar cleanup as users_registry_remove.
        if [[ -f "${_f}.sync-pending" && ! -L "${_f}.sync-pending" ]]; then rm -f -- "${_f}.sync-pending" || return 1; fi
    done
    # M-29 follow-up (wipe orphan sidecar): the loop above only visits
    # *.json, so a sidecar whose registry is already gone is never seen
    # and survives the wipe. Sweep *.sync-pending too and delete the
    # sidecar when no corresponding .json exists in any form (a
    # symlinked .json is deliberately never deleted, so its debt marker
    # must survive with it).
    local _s='' _j=''
    for _s in "$_dir"/*.sync-pending; do
        [[ -f "$_s" && ! -L "$_s" ]] || continue
        _j="${_s%.sync-pending}"
        case "$_j" in *.json) ;; *) _j="${_j}.json" ;; esac
        if [[ ! -e "$_j" && ! -L "$_j" ]]; then rm -f -- "$_s" || return 1; fi
    done
    return 0
}

sync_env_ports_after_removal() {
    # U148: after an inbound deletion, any .env listener port with no
    # surviving inbound is stale (setup_active_defense rebuilds its
    # fail2ban port list from .env, so a dead port would linger in the
    # jail). Clear the var (file line emptied, shell var unset) only
    # when no surviving inbound OF THE PROTOCOL THAT OWNS THE VAR
    # listens on it.
    # W2-FAIL-1 (2026-11-26 matrix): the old rule pooled every live
    # listener port across all cores, so a Hysteria 2 inbound on UDP
    # 443 kept VLESS_PORT=443 alive after the xray Vision inbound was
    # deleted. The health probe then read VLESS_PORT as an xray
    # expectation, found no xray inbound on 443, and auto-restored the
    # stale ALL backup -- resurrecting the just-deleted protocols.
    # A port shared by two protocols survives only while a listener
    # of the VAR'S OWN protocol remains (e.g. VLESS_PORT survives on
    # an xray/sing-box Vision inbound, never on a Hy2 listener).
    # HY2 hop-range vars are not listener ports and are out of scope
    # here.
    local envf="${ABOX_ENV:-/etc/ddr/.env}" var='' val='' cleared='' info='' cfg='' hy2p='' core='' p='' _ports='' _stripped='' _read_failed=0 _write_failed=0 _keep=0 _vp='' _lp='' _rlo='' _rhi='' _vlo='' _vhi='' _lrlo='' _lrhi='' _hy2line=''
    local -a live_ports=()
    local -a _live_vless=() _live_xhttp=() _live_ss=() _live_socks=() _live_trojan=() _live_hy2=()
    local -a _val_parts=()
    local _jq_prog='' _cv='' _cp=''
    [[ -f "$envf" && ! -L "$envf" ]] || return 0
    for core in xray sing-box; do
        info=$(_protocol_cfg_of "$core" 2>/dev/null) || continue
        IFS='|' read -r cfg _ _ <<< "$info"
        [[ -f "$cfg" && ! -L "$cfg" ]] || continue
        # 05e2-M3: the live config may carry // or /* */ comments
        # (Xray/sing-box accept JSONC); strip them before jq, like
        # the inbound-removal path does. A strip failure, or a
        # stripped-to-blank config, stays fail-closed: jq returns 0
        # with no output on empty input, which would otherwise be
        # misread as "no live ports" and clear live .env ports.
        _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || { _read_failed=1; continue; }
        [[ "$_stripped" =~ [^[:space:]] ]] || { _read_failed=1; continue; }
        # Classify each live inbound by the protocol that owns its
        # .env var (tag first, protocol/type second). The untagged
        # xray vless fallback keys on the stream network: xhttp
        # network is XHTTP, anything else vless is Vision. Argo
        # vless-ws-in carries no "vision" tag and never lands in
        # VLESS_PORT.
        if [[ "$core" == 'xray' ]]; then
            _jq_prog='.inbounds[]? | if ((.tag // "") | test("vision")) then "VLESS \(.port // empty)" elif ((.tag // "") | test("xhttp")) then "XHTTP \(.port // empty)" elif .protocol == "shadowsocks" then "SS \(.port // empty)" elif .protocol == "socks" then "SOCKS \(.port // empty)" elif .protocol == "trojan" then "TROJAN \(.port // empty)" elif .protocol == "vless" then (if ((.streamSettings.network // "") == "xhttp") then "XHTTP \(.port // empty)" else "VLESS \(.port // empty)" end) else empty end'
        else
            _jq_prog='.inbounds[]? | if .type == "vless" and ((.tag // "") | test("vision")) then "VLESS \(.listen_port // empty)" elif .type == "shadowsocks" then "SS \(.listen_port // empty)" elif .type == "socks" or .type == "mixed" then "SOCKS \(.listen_port // empty)" elif .type == "trojan" then "TROJAN \(.listen_port // empty)" elif .type == "hysteria2" then "HY2 \(.listen_port // empty)" else empty end'
        fi
        _ports=$(jq -r "$_jq_prog" <<< "$_stripped" 2>/dev/null) || { _read_failed=1; continue; }
        # No IFS= here: the "VAR port" line must word-split into
        # the two fields (IFS= would put the whole line in _cv and
        # leave _cp empty, dropping every classification).
        while read -r _cv _cp; do
            [[ -n "$_cv" && -n "$_cp" ]] || continue
            case "$_cv" in
                VLESS) _live_vless+=("$_cp") ;;
                XHTTP) _live_xhttp+=("$_cp") ;;
                SS) _live_ss+=("$_cp") ;;
                SOCKS) _live_socks+=("$_cp") ;;
                TROJAN) _live_trojan+=("$_cp") ;;
                # W7-OBS-4: the sing-box hysteria2 inbound listens on
                # HY2_BASE_PORT (build_singbox_config, src/07), so it
                # is a live Hy2 port source exactly like the official
                # yaml below. Without this arm the per-owner rewrite
                # cleared HY2_BASE_PORT on any sing-box delete while
                # the Hy2 inbound still listened (the pre-fix pooled
                # harvest kept it via the all-ports jq).
                HY2) _live_hy2+=("$_cp") ;;
            esac
        done <<< "$_ports"
    done
    if [[ -f "${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}" && ! -L "${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}" ]]; then
        # R7C11-02: collect every listen port (top-level and
        # trafficStats.listen), not just the first top-level one.
        local _hy2_lines='' _hy2_rc=0 _hy2_value='' _hy2_re='' _hy2_key_re="^[[:space:]]*(listen|'listen'|\"listen\")[[:space:]]*:"
        local _hy2_endpoint_re='^([[:alnum:]_.%-]*|\[[[:alnum:]_.%:-]+\]):([0-9]+(-[0-9]+)?)$'
        _hy2_lines=$(grep -E "$_hy2_key_re" "${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}" 2>/dev/null) || _hy2_rc=$?
        if (( _hy2_rc > 1 )); then
            _read_failed=1
        else
            while IFS= read -r _hy2line; do
                [[ -n "$_hy2line" ]] || continue
                _hy2_value="${_hy2line#*:}"
                _hy2_value="${_hy2_value#"${_hy2_value%%[![:space:]]*}"}"
                if [[ "$_hy2_value" == '"'* ]]; then
                    _hy2_re='^"([^"\\]*)"([[:space:]]+#.*)?[[:space:]]*$'
                elif [[ "$_hy2_value" == "'"* ]]; then
                    _hy2_re="^'([^']*)'([[:space:]]+#.*)?[[:space:]]*$"
                else
                    _hy2_re='^([^[:space:]]+)([[:space:]]+#.*)?[[:space:]]*$'
                fi
                if [[ "$_hy2_value" =~ $_hy2_re ]]; then
                    _hy2_value="${BASH_REMATCH[1]}"
                else
                    _read_failed=1
                    continue
                fi
                if [[ "$_hy2_value" =~ $_hy2_endpoint_re ]]; then
                    hy2p="${BASH_REMATCH[2]}"
                    _live_hy2+=("$hy2p")
                else
                    _read_failed=1
                fi
            done <<< "$_hy2_lines"
        fi
    fi
    # A config that exists but fails to parse must fail closed: treating
    # its ports as absent would clear live .env ports.
    if (( _read_failed == 1 )); then
        return 1
    fi
    for var in VLESS_PORT XHTTP_PORT HY2_BASE_PORT SS_PORT SOCKS_PORT TROJAN_PORT HY2_MONITOR_PORT HY2_URI_PORTS; do
        val=$(sed -n "s/^${var}=//p" "$envf" 2>/dev/null | head -n 1 | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
        [[ -n "$val" ]] || continue
        # W2-FAIL-1: each var is kept only by a live inbound of its
        # own protocol. A Hy2 listener on 443 must not keep
        # VLESS_PORT, and an xray Vision inbound must not keep
        # HY2_BASE_PORT. The keep-check below is unchanged; only its
        # input set is now per-var.
        case "$var" in
            VLESS_PORT) live_ports=("${_live_vless[@]}") ;;
            XHTTP_PORT) live_ports=("${_live_xhttp[@]}") ;;
            SS_PORT) live_ports=("${_live_ss[@]}") ;;
            SOCKS_PORT) live_ports=("${_live_socks[@]}") ;;
            TROJAN_PORT) live_ports=("${_live_trojan[@]}") ;;
            *) live_ports=("${_live_hy2[@]}") ;;
        esac
        # R6C11-02: evaluate numeric/range/list specs, not literal
        # membership. Keep if any element is covered (exact or
        # within a range), or if any live entry is unparseable
        # (cannot prove the port is dead).
        _keep=0
        IFS=',' read -r -a _val_parts <<< "$val"
        for _vp in "${_val_parts[@]}"; do
            _vp="${_vp#"${_vp%%[![:space:]]*}"}"; _vp="${_vp%"${_vp##*[![:space:]]}"}"
            [[ -n "$_vp" ]] || continue
            for _lp in "${live_ports[@]}"; do
                if [[ "$_lp" == "$_vp" ]]; then _keep=1; break; fi
                # R15-F10-04: same numeric value, different spelling
                # ("00443" live vs "443" in .env): compare numerically.
                if [[ "$_lp" =~ ^[0-9]+$ && "$_vp" =~ ^[0-9]+$ ]] && (( 10#$_lp == 10#$_vp )); then _keep=1; break; fi
                if [[ "$_lp" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    _rlo="${BASH_REMATCH[1]}"; _rhi="${BASH_REMATCH[2]}"
                    if (( 10#$_rlo > 10#$_rhi )); then _keep=1; break;
                    elif [[ "$_vp" =~ ^[0-9]+$ ]] && (( 10#$_rlo <= 10#$_vp && 10#$_vp <= 10#$_rhi )); then _keep=1; break; fi
                elif [[ ! "$_lp" =~ ^[0-9]+$ ]]; then
                    _keep=1; break
                fi
                # R14-F10-04: the reverse direction the loop above
                # misses: the .env value itself is a range and a live
                # entry is one of its members (or overlaps it). A
                # malformed (reversed) range is unparseable: keep,
                # fail-closed, like an unparseable live entry.
                if [[ "$_vp" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    _vlo="${BASH_REMATCH[1]}"; _vhi="${BASH_REMATCH[2]}"
                    if (( 10#$_vlo > 10#$_vhi )); then _keep=1; break;
                    elif [[ "$_lp" =~ ^[0-9]+$ ]] && (( 10#$_vlo <= 10#$_lp && 10#$_lp <= 10#$_vhi )); then _keep=1; break;
                    elif [[ "$_lp" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        _lrlo="${BASH_REMATCH[1]}"; _lrhi="${BASH_REMATCH[2]}"
                        if (( 10#$_lrlo > 10#$_lrhi )); then _keep=1; break;
                        elif (( 10#$_vlo <= 10#$_lrhi && 10#$_lrlo <= 10#$_vhi )); then _keep=1; break; fi
                    fi
                fi
            done
            (( _keep == 1 )) && break
        done
        (( _keep == 1 )) && continue
        if ! sed -i "s/^${var}=.*/${var}=\"\"/" "$envf" 2>/dev/null; then
            _write_failed=1
            continue
        fi
        unset "$var" 2>/dev/null || true
        cleared+="${var} "
    done
    [[ -n "$cleared" ]] && msg "${YELLOW}$(tprintf cl_env_ports_cleared "${cleared% }")${NC}"
    if (( _write_failed == 1 )); then
        return 1
    fi
    return 0
}

# W7-OBS-4 (E-leg handoff, adjudicated in the W2-FAIL-1 leg):
# deleting Hy2 must also clear its non-port .env keys. Two live
# readers prove they are expectations, not dead data: the health
# probe reads HY2_HOP/HY2_HOP_IMPL/HY2_RANGE_START/HY2_RANGE_END
# (hop firewall check, src/06, plus the fail2ban port harvest), and
# the Clash YAML emitter resurrects a deleted Hy2 from stale
# HY2_DOMAIN/HY2_CERT_SHA256_FP/HY2_PASS fallbacks while MODE still
# says ALL (src/13 write_clash_yaml; HY2_BASE_PORT empty is NOT a
# stop there -- it defaults to 443). Deploy regenerates every one
# of these keys (HY2_PASS/HY2_OBFS/cert fingerprints; domain and hop
# settings are re-prompted), so clearing them cannot break a later
# re-deploy. Port vars are NOT listed here: HY2_BASE_PORT,
# HY2_MONITOR_PORT and HY2_URI_PORTS stay with
# sync_env_ports_after_removal above, and the hop-range vars stay
# out of sync by the original design note (they are not listener
# ports) -- they are cleared here instead, under the same gate.
# Gate: only when no Hy2 remains anywhere (official config gone AND
# no hysteria2 inbound in the sing-box config). Anything
# unverifiable keeps the keys and returns 0 (skip, mirroring the
# M-12(1) hop-rule reclamation next door); only a real write failure
# returns 1.
_clear_hy2_nonport_env_vars() {
    local envf="${ABOX_ENV:-/etc/ddr/.env}"
    local _hy2cfg="${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}"
    local _sbcfg="${ABOX_SB_CFG:-/etc/sing-box/config.json}"
    local _stripped='' _jq_rc=0 _key='' _failed=0
    # Official binary still installed -> Hy2 lives.
    [[ -e "$_hy2cfg" || -L "$_hy2cfg" ]] && return 0
    # Sing-box hysteria2 inbound still present -> Hy2 lives. A
    # missing/empty sing-box config means no sing-box Hy2; an
    # unreadable or unparseable one is unverifiable -> keep keys.
    if [[ -f "$_sbcfg" && ! -L "$_sbcfg" && -s "$_sbcfg" ]]; then
        _stripped=$(jsonc_strip_comments "$_sbcfg" 2>/dev/null) || return 0
        [[ -n "${_stripped//[[:space:]]/}" ]] || return 0
        printf '%s' "$_stripped" | jq -s -e '([.[] | .inbounds[]? | select(.type == "hysteria2")] | length) > 0' >/dev/null 2>&1 || _jq_rc=$?
        (( _jq_rc == 1 )) || return 0
    fi
    [[ -f "$envf" && ! -L "$envf" ]] || return 0
    for _key in HY2_DOMAIN HY2_UP HY2_DOWN HY2_MASQ_URL HY2_PASS HY2_OBFS HY2_CERT_SHA256_FP HY2_CERT_PUBKEY_SHA256_B64 HY2_HOP HY2_HOP_IMPL HY2_ACME_TYPE HY2_ACME_DNS_PROVIDER HY2_ACME_DNS_CF_API_TOKEN HY2_CLASH_PORTS HY2_SB_PORTS HY2_RANGE_START HY2_RANGE_END; do
        if ! sed -i "s/^${_key}=.*/${_key}=\"\"/" "$envf" 2>/dev/null; then
            _failed=1
            continue
        fi
        unset "$_key" 2>/dev/null || true
    done
    if (( _failed == 1 )); then
        msg "${YELLOW}[!] Failed to clear stale Hy2 settings from .env after removing Hysteria 2; stale values may remain.${NC}"
        return 1
    fi
    return 0
}

# A protocol's .link file belongs to the core that serves it: deleting
# one core's inbound must not delete the other core's still-valid link.
# Returns 0 when the given core still serves that protocol, 1 when it
# confirmedly does not, 2 when survivorship is unverifiable (jq failed
# or is missing) — callers must only delete on rc 1.
_standalone_link_survivor() {
    local key="$1" xcfg="${XRAY_SLOT_CFG:-/usr/local/etc/xray/config.json}" scfg='/etc/sing-box/config.json'
    local _cfg='' _prog='' _jq_rc=0 _stripped=''
    # M-29(3): one .link file per base tag -- the survivor test must
    # match that tag exactly, not the whole -2 family. socks5-sb stays
    # type-based (mixed-in/socks-in genuinely share one link) and the
    # xray keys stay protocol-based (old xray configs may be untagged;
    # a tag match there could delete a live link).
    # M-02: numbered stems map to the same-numbered config tag
    # (trojan-xray-2 -> trojan-landing-2, ...), so the numbered link
    # is survivor-gated on its own tag, never on the base instance.
    case "$key" in
        trojan-xray) _cfg="$xcfg"; _prog='.inbounds[]? | select(.protocol == "trojan")' ;;
        trojan-xray-[0-9]*) _cfg="$xcfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"trojan-landing-${key#trojan-xray-}\")" ;;
        trojan-sb) _cfg="$scfg"; _prog='.inbounds[]? | select((.tag // "") == "trojan-landing")' ;;
        trojan-sb-[0-9]*) _cfg="$scfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"trojan-landing-${key#trojan-sb-}\")" ;;
        tuic) _cfg="$scfg"; _prog='.inbounds[]? | select((.tag // "") == "tuic-in")' ;;
        tuic-in-[0-9]*) _cfg="$scfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"$key\")" ;;
        anytls) _cfg="$scfg"; _prog='.inbounds[]? | select((.tag // "") == "anytls-in")' ;;
        anytls-in-[0-9]*) _cfg="$scfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"$key\")" ;;
        shadowtls) _cfg="$scfg"; _prog='.inbounds[]? | select((.tag // "") == "shadowtls-in")' ;;
        shadowtls-in-[0-9]*) _cfg="$scfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"$key\")" ;;
        socks5-sb) _cfg="$scfg"; _prog='.inbounds[]? | select(.type == "socks" or .type == "mixed")' ;;
        socks5-sb-[0-9]*) _cfg="$scfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"socks5-landing-${key#socks5-sb-}\")" ;;
        socks5-xray) _cfg="$xcfg"; _prog='.inbounds[]? | select(.protocol == "socks")' ;;
        socks5-xray-[0-9]*) _cfg="$xcfg"; _prog=".inbounds[]? | select((.tag // \"\") == \"socks5-landing-${key#socks5-xray-}\")" ;;
        *) return 1 ;;
    esac
    # 2gq: a missing config is a confirmed "not served" (as before); a
    # jq failure is NOT — it must never be read as "no survivor".
    # One-pass Boolean slurp: rc 0 = survivor, rc 1 = confirmed
    # absence, anything else = unverifiable. The slurp reads the
    # whole file once, so a validate-then-reread race cannot flip
    # the answer. An empty file slurps to [] (false -> rc 1), so
    # it is rejected up front as unverifiable, not "confirmed gone".
    # (jq 1.6 parse-fail is rc 4, jq 1.7 is rc 5 — both land in *.)
    # M-29: a symlinked config is unverifiable (rc 2), not "confirmed
    # absent" (rc 1) -- the link target may still serve the protocol.
    [[ -L "$_cfg" ]] && return 2
    # R15b-M2: only a fully missing config is "confirmed absent"
    # (rc 1); an existing non-regular file is unverifiable (rc 2).
    [[ -e "$_cfg" ]] || return 1
    [[ -f "$_cfg" ]] || { msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (config is not a regular file); keeping the link.${NC}" >&2; return 2; }
    [[ -s "$_cfg" ]] || { msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (empty config); keeping the link.${NC}" >&2; return 2; }
    # H-26(3): strip JSONC comments before jq: the live config may
    # legally carry // or /* */ comments, and a bare jq read fails
    # (rc 5) on them. An empty result after stripping is
    # unverifiable, not "confirmed gone".
    _stripped=$(jsonc_strip_comments "$_cfg" 2>/dev/null) || { msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (cannot strip comments); keeping the link.${NC}" >&2; return 2; }
    [[ -n "${_stripped//[[:space:]]/}" ]] || { msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (empty config after stripping comments); keeping the link.${NC}" >&2; return 2; }
    # R15b-M2: same structure gate as _standalone_link_tag_survivor:
    # a non-object top level or a present-but-non-array inbounds is
    # unverifiable, not "confirmed absent".
    printf '%s' "$_stripped" | jq -s -e 'if length != 1 then error("config is not a single JSON document") elif (.[0] | type) != "object" then error("config top level is not an object") elif (.[0] | has("inbounds")) and ((.[0].inbounds | type) != "array") then error("config inbounds is not an array") else true end' >/dev/null 2>&1 || { msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (bad config structure); keeping the link.${NC}" >&2; return 2; }
    printf '%s' "$_stripped" | jq -s -e "([.[] | (${_prog})] | length) > 0" >/dev/null 2>&1 || _jq_rc=$?
    case "$_jq_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) msg "${YELLOW}[!] standalone link '$key': survivorship unverifiable (jq rc ${_jq_rc}); keeping the link.${NC}" >&2; return 2 ;;
    esac
}

# 2gq: delete a standalone link only on confirmed rc 1. An unverifiable
# check (rc 2) keeps the link: deleting a possibly-live link breaks
# clients, while a stale leftover is cleaned by rebuild/prune.
_standalone_link_prune_if_gone() {
    local key="$1" link="$2" _rc=0
    _standalone_link_survivor "$key" || _rc=$?
    if [[ "$_rc" == 1 ]]; then rm -f -- "$link" 2>/dev/null || true; fi
    return 0
}

# S1-NEW-04 (final-round followup 4): drop manifest rows for paths
# that were just deleted from disk. The ownership manifest records
# files that exist; a row for a deleted file drifts (a same-name,
# same-hash rebuild would then compare against a stale row) and is
# never healed until the next full record_core_family_ownership walk.
# Callers pass the exact paths they deleted; only rows whose field 3
# matches one of those paths are dropped, so live rows are untouched.
# Same atomic-rewrite shape as _xl_legacy_drop_manifest_rows (mktemp
# in place + 600 + mv). Best-effort, always returns 0: the file
# deletion already happened, and a stale row is low-severity drift
# that must never fail the caller's deploy/cleanup path.
_manifest_drop_paths() {
    local _mf="${ABOX_CORE_OWNERSHIP:-/etc/ddr/.managed-core-files.tsv}" _tmp='' _list=''
    [[ -f "$_mf" && ! -L "$_mf" ]] || return 0
    [[ $# -gt 0 ]] || return 0
    _tmp=$(mktemp "${_mf}.drop.XXXXXX" 2>/dev/null) || return 0
    _list=$(mktemp "${_mf}.droplist.XXXXXX" 2>/dev/null) || { rm -f -- "$_tmp"; return 0; }
    printf '%s\n' "$@" > "$_list" 2>/dev/null || { rm -f -- "$_tmp" "$_list"; return 0; }
    # Exact match on field 3 via an associative set: paths may contain
    # regex metacharacters, so they are never matched as patterns.
    if ! awk -F'\t' 'NR==FNR {drop[$0]=1; next} !($3 in drop)' "$_list" "$_mf" > "$_tmp" 2>/dev/null; then
        rm -f -- "$_tmp" "$_list"
        return 0
    fi
    rm -f -- "$_list"
    chmod 600 -- "$_tmp" 2>/dev/null || true
    chown root:root -- "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$_mf" 2>/dev/null || rm -f -- "$_tmp"
    return 0
}

# L-NEW-11: a removed sing-box TUIC inbound owns its per-tag self-signed
# cert/key pair (/etc/sing-box/tuic-<tag>-<hash>.crt/.key). Delete the pair
# only when no tuic inbound remains in the live config (mirror of the Hy2
# pair cleanup in _protocol_removed_side_effects below); a strip/jq failure,
# a missing/empty config, or a surviving tuic inbound keeps the files.
# R38-H2: a surviving inbound of ANY protocol referencing a file keeps
# it too (the helper only proved no TUIC inbound remains).
# Only regular files are removed, never symlinks; the legacy unprefixed
# tuic.crt/tuic.key do not match tuic-*.crt/.key and stay. Best-effort,
# always returns 0.
# 05f-H-05f-02: a cert/key file is referenced when ANY inbound of any
# protocol names it as certificate_path/key_path. Returns 0 when the
# path is referenced (or when the reference set cannot be determined --
# fail-closed, keep the file); returns 1 only when the live config is
# readable and no inbound references the path. Checking only the
# owning protocol's inbounds deletes a file another protocol still uses.
_singbox_cert_referenced() {
    local _cfg="$1" _path="$2" _stripped='' _refs=''
    [[ -n "$_cfg" && -n "$_path" ]] || return 0
    _stripped=$(jsonc_strip_comments "$_cfg" 2>/dev/null) || return 0
    [[ -n "${_stripped//[[:space:]]/}" ]] || return 0
    _refs=$(printf '%s' "$_stripped" | jq -r '.inbounds[]? | (.tls.certificate_path // empty), (.tls.key_path // empty)' 2>/dev/null) || return 0
    grep -Fxq -- "$_path" <<< "$_refs" || return 1
    return 0
}

_singbox_cleanup_tuic_certs_when_none_remain() {
    local cfg="${ABOX_SB_CFG:-/etc/sing-box/config.json}" _sb_dir='' _stripped='' _tuic_jq_rc=0 _f=''
    [[ -f "$cfg" && ! -L "$cfg" && -s "$cfg" ]] || return 0
    _sb_dir=$(dirname -- "$cfg")
    _stripped=$(mktemp /tmp/A-Box-sb-tuic-strip.XXXXXX) || return 0
    if ! jsonc_strip_comments "$cfg" > "$_stripped" 2>/dev/null; then
        rm -f -- "$_stripped"
        return 0
    fi
    # 05e2-M1: a comment/blank-only config strips to empty, and jq -s
    # on empty input yields [] (rc 1) -- the same code as "confirmed no
    # TUIC inbound". An empty-after-strip config is unverifiable, not a
    # confirmation: keep the certs (same guard as the standalone link
    # check, which refuses an empty-after-strip config).
    if ! grep -q '[^[:space:]]' "$_stripped" 2>/dev/null; then
        rm -f -- "$_stripped"
        return 0
    fi
    # 2gq: delete only when jq confirms no tuic inbound remains
    # (one-pass Boolean, rc 1); a jq failure keeps the files.
    jq -s -e '([.[] | .inbounds[]? | select(.type == "tuic")] | length) > 0' "$_stripped" >/dev/null 2>&1 || _tuic_jq_rc=$?
    rm -f -- "$_stripped"
    [[ "$_tuic_jq_rc" == 1 ]] || return 0
    # S1-NEW-04: a deleted file's manifest row must go with it, or
    # the manifest drifts from disk (stale hash vs a same-name rebuild).
    # Only rows for files this loop actually removed are dropped: a
    # failed rm leaves the file (and its row) in place.
    local _deleted=()
    for _f in "$_sb_dir"/tuic-*.crt "$_sb_dir"/tuic-*.key; do
        [[ -f "$_f" && ! -L "$_f" ]] || continue
        # R38-H2: _singbox_cert_referenced is fail-closed (an unreadable
        # config keeps the file), so a referenced file is never deleted.
        _singbox_cert_referenced "$cfg" "$_f" && continue
        rm -f -- "$_f" 2>/dev/null || true
        [[ -e "$_f" ]] || _deleted+=("$_f")
    done
    (( ${#_deleted[@]} > 0 )) && _manifest_drop_paths "${_deleted[@]}" || true
    return 0
}

# M-12(1): the per-tag TUIC cert filename suffix (same construction as
# the TUIC deployer): sanitized tag + first 8 hex of its sha256.
tuic_cert_tag() {
    local _t
    _t=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')
    printf '%s-%s\n' "$_t" "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
}

# M-12(1): delete the Hy2 HOP REDIRECT NAT rules (v4+v6) for one hop
# range. Idempotent: a rule that is already gone is not an error.
# Returns 1 only when a rule that is still present cannot be deleted.
remove_hy2_hop_nat_rules() {
    local _start="$1" _end="$2" _base="$3" _iface="$4" cmd _probe _spec _crc _probe_rc
    local _failed=0
    for cmd in "$IPT" "$IPT6"; do
        if [[ "$cmd" == "$IPT6" ]]; then
            if ! command -v "$IPT6" >/dev/null 2>&1; then continue; fi
            # 05e2-M4: an -S query failure must not silently skip the
            # whole v6 branch (it used to bypass the -L fail-closed
            # probe below too). S27/R4C6-03: a failed query means v6
            # rules may still be present; fail unless IPv6 is
            # confirmed unusable, in which case no v6 rules can exist.
            if ! _iptables_q "$IPT6" -t nat -S PREROUTING >/dev/null 2>&1; then
                if host_has_usable_ipv6; then _failed=1; fi
                continue
            fi
            if ! _iptables_q "$IPT6" -t nat -L PREROUTING >/dev/null 2>&1; then
                # Usable IPv6 is not guaranteed; a non-empty IPv6
                # rulebase we cannot enumerate is fail-closed: leave
                # the v6 rules in place and report failure. A probe
                # that itself errors proves nothing about emptiness,
                # so it fails closed the same way.
                _probe=$(_iptables_q "$IPT6" -t nat -S PREROUTING 2>/dev/null); _probe_rc=$?
                if (( _probe_rc != 0 )); then
                    if host_has_usable_ipv6; then _failed=1; fi
                    continue
                fi
                [[ -z "$_probe" ]] && continue
                _failed=1
                continue
            fi
        fi
        _spec=(-i "$_iface" -p udp --dport "${_start}:${_end}" -j REDIRECT --to-ports "$_base")
        # 05e2-M4: tri-state -C (same contract as
        # iptables_rule_check): 0 = present, 1 = absent, anything
        # else = query error, which must fail, never read as absent.
        while :; do
            _iptables_q "$cmd" -t nat -C PREROUTING "${_spec[@]}" 2>/dev/null; _crc=$?
            case "$_crc" in
                0) _iptables_q "$cmd" -t nat -D PREROUTING "${_spec[@]}" 2>/dev/null || { _failed=1; break; } ;;
                1) break ;;
                *) _failed=1; break ;;
            esac
        done
    done
    (( _failed == 0 ))
}

# M-12(1): enumerate "proto/port" lines for the given inbound tags in a
# JSONC-stripped core config file ($1). Transport mapping mirrors
# core_expected_listen_ports (Xray socks is tcp+udp exactly when
# settings.udp is true, SS follows settings.network; sing-box
# shadowsocks follows .network, socks/mixed are tcp-only). Loopback
# inbounds and the api inbound have no public firewall surface and are
# skipped. Prints nothing and returns 0 when no tag matches.
removed_inbound_ports() {
    local cfg="$1"; shift
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    (( $# > 0 )) || return 0
    local _tags_json=''
    _tags_json=$(printf '%s\n' "$@" | jq -R . | jq -sc . 2>/dev/null) || return 1
    jq -r --argjson tags "$_tags_json" '
    # 03b-M1: same shared transport rule as snapshot/restore (see
    # standalone_preserve_snapshot); renamed from `transports`.
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
    ($tags) as $want
    | .inbounds[]?
    | select(.tag as $t | ($want | index($t)) != null)
    | select(.tag != "api")
    | select(.listen == null or (.listen != "127.0.0.1" and .listen != "::1"))
    | select((.port // .listen_port) != null)
    | (transport_set) as $trs
    | ((.port // .listen_port) | tostring | split(",")) as $ps
    | $ps[] as $p | $trs[] | "\(.)/\($p)"' "$cfg" 2>/dev/null
}

# M-12(1): true when the given single proto/port is still listened on
# by a surviving inbound, per the live-set text ($3, "proto/port"
# lines as produced by core_expected_listen_ports, plus the Hysteria
# YAML listen port). A live range that contains the port also counts.
_firewall_port_live() {
    local _proto="$1" _port="$2" _live="$3" _l _lp _lr _lo _hi
    # 05e2-M2: live ports may carry leading zeros ("00443" from jq
    # tostring / Hy2 strings): compare numerically with 10# so they
    # are never read as octal (00443 is 443, not 291; 00800 is a
    # hard arithmetic error, not a miss). A malformed live entry --
    # reversed range, unparseable value, unparseable query port --
    # is treated as live (fail-closed), like _firewall_range_live.
    [[ "$_port" =~ ^[0-9]+$ ]] || return 0
    while IFS= read -r _l; do
        [[ "$_l" == "$_proto/$_port" ]] && return 0
        if [[ "$_l" =~ ^$_proto/([0-9]+)$ ]]; then
            if (( 10#$_port == 10#${BASH_REMATCH[1]} )); then return 0; fi
            continue
        fi
        if [[ "$_l" =~ ^$_proto/([0-9]+)[-:]([0-9]+)$ ]]; then
            _lo="${BASH_REMATCH[1]}"; _hi="${BASH_REMATCH[2]}"
            if (( 10#$_lo > 10#$_hi )); then return 0; fi
            if (( 10#$_port >= 10#$_lo && 10#$_port <= 10#$_hi )); then return 0; fi
            continue
        fi
        [[ "$_l" == "$_proto/"* ]] && return 0
    done <<< "$_live"
    return 1
}

# M-12(1): true when the given proto/range overlaps any live port or
# live range in the live-set text ($4). A malformed live range is
# treated as live (fail-closed).
_firewall_range_live() {
    local _proto="$1" _lo="$2" _hi="$3" _live="$4" _l _lp _lr _rlo _rhi
    # 05e2-M2: same 10# normalization as _firewall_port_live
    # (leading-zero endpoints are decimal, never octal); a reversed
    # live range or a reversed query range is malformed and treated
    # as live (fail-closed), per this function's header contract.
    [[ "$_lo" =~ ^[0-9]+$ && "$_hi" =~ ^[0-9]+$ ]] || return 0
    if (( 10#$_lo > 10#$_hi )); then return 0; fi
    while IFS= read -r _l; do
        [[ "$_l" == "$_proto/"* ]] || continue
        _lr="${_l#*/}"
        if [[ "$_lr" =~ ^([0-9]+)[-:]([0-9]+)$ ]]; then
            _rlo="${BASH_REMATCH[1]}"; _rhi="${BASH_REMATCH[2]}"
            if (( 10#$_rlo > 10#$_rhi )); then return 0; fi
            if (( 10#$_lo <= 10#$_rhi && 10#$_hi >= 10#$_rlo )); then return 0; fi
        elif [[ "$_lr" =~ ^[0-9]+$ ]]; then
            if (( 10#$_lr >= 10#$_lo && 10#$_lr <= 10#$_hi )); then return 0; fi
        else
            return 0
        fi
    done <<< "$_live"
    return 1
}

# M-12(1): recycle firewall openings for removed inbounds. Reads
# "proto/port" lines on stdin; for each, removes the native rule and
# the iptables ACCEPT rule only when no surviving inbound in either
# core config (or the Hysteria YAML) still listens on it. One
# save_firewall_rules at the end when anything was removed.
# Best-effort: a failure to enumerate live ports leaves every rule in
# place, and a removal failure only warns; the removal itself never
# fails because of this recycling.
firewall_recycle_freed_ports() {
    local spec='' proto='' port='' _live='' _out='' _removed=0 _live_failed=0 _line='' _lo='' _hi='' _rspec='' _hy2p=''
    if [[ -f /usr/local/etc/xray/config.json && ! -L /usr/local/etc/xray/config.json ]]; then
        _out=$(core_expected_listen_ports xray /usr/local/etc/xray/config.json 2>/dev/null) || _live_failed=1
        _live+="$_out"$'\n'
    fi
    if [[ -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json ]]; then
        _out=$(core_expected_listen_ports singbox /etc/sing-box/config.json 2>/dev/null) || _live_failed=1
        _live+="$_out"$'\n'
    fi
    if [[ -f /etc/hysteria/config.yaml && ! -L /etc/hysteria/config.yaml ]]; then
        # R38-M2: enumerate EVERY listen value -- the top-level UDP
        # listen and trafficStats.listen (TCP) -- with quoted keys.
        # xl_hy2_port only returns the first unquoted top-level
        # listen, so a quoted key or the stats listener was missing
        # from the live set and its firewall rule could be recycled
        # while still in use. Any listen line that cannot be parsed
        # fails closed (_live_failed): unknown means keep the rules.
        # Value parsing mirrors sync_env_ports_after_removal (R7C11-02).
        local _hy2_key_re="^[[:space:]]*(listen|'listen'|\"listen\")[[:space:]]*:"
        local _hy2_endpoint_re='^([[:alnum:]_.%-]*|\[[[:alnum:]_.%:-]+\]):([0-9]+(-[0-9]+)?)$'
        local _hy2_in_stats=0 _hy2_line='' _hy2_value='' _hy2_re='' _hy2_port=''
        while IFS= read -r _hy2_line; do
            [[ -n "${_hy2_line//[[:space:]]/}" ]] || continue
            if [[ "$_hy2_line" =~ ^[^[:space:]#] ]]; then
                if [[ "$_hy2_line" =~ ^trafficStats[[:space:]]*: ]]; then _hy2_in_stats=1; else _hy2_in_stats=0; fi
            fi
            [[ "$_hy2_line" =~ $_hy2_key_re ]] || continue
            # An indented listen outside trafficStats is unknown: no
            # other hysteria2 block has a nested listen.
            if [[ "$_hy2_line" =~ ^[[:space:]] ]] && (( _hy2_in_stats == 0 )); then
                _live_failed=1
                continue
            fi
            _hy2_value="${_hy2_line#*:}"
            _hy2_value="${_hy2_value#"${_hy2_value%%[![:space:]]*}"}"
            if [[ "$_hy2_value" == '"'* ]]; then
                _hy2_re='^"([^"\\]*)"([[:space:]]+#.*)?[[:space:]]*$'
            elif [[ "$_hy2_value" == "'"* ]]; then
                _hy2_re="^'([^']*)'([[:space:]]+#.*)?[[:space:]]*$"
            else
                _hy2_re='^([^[:space:]]+)([[:space:]]+#.*)?[[:space:]]*$'
            fi
            if [[ "$_hy2_value" =~ $_hy2_re ]]; then
                _hy2_value="${BASH_REMATCH[1]}"
            else
                _live_failed=1
                continue
            fi
            if [[ "$_hy2_value" =~ $_hy2_endpoint_re ]]; then
                _hy2_port="${BASH_REMATCH[2]}"
                if (( _hy2_in_stats == 1 )); then
                    _live+="tcp/$_hy2_port"$'\n'
                else
                    _live+="udp/$_hy2_port"$'\n'
                fi
            else
                _live_failed=1
            fi
        done < /etc/hysteria/config.yaml || _live_failed=1
    fi
    if (( _live_failed == 1 )); then
        msg "${YELLOW}[!] Cannot enumerate live ports; leaving removed inbounds' firewall rules in place.${NC}"
        return 0
    fi
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        proto="${spec%%/*}"; port="${spec#*/}"
        [[ "$proto" == tcp || "$proto" == udp ]] || continue
        if [[ "$port" =~ ^([0-9]+)[-:]([0-9]+)$ ]]; then
            _lo="${BASH_REMATCH[1]}"; _hi="${BASH_REMATCH[2]}"
            _firewall_range_live "$proto" "$_lo" "$_hi" "$_live" && continue
            _rspec="$_lo:$_hi"
        else
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            _firewall_port_live "$proto" "$port" "$_live" && continue
            _rspec="$port"
        fi
        remove_abox_native_firewall_rule "$_rspec" "$proto" >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to remove the native firewall rule for ${_rspec}/${proto} of a removed inbound.${NC}"
        wallos_remove_abox_iptables_accept "$_rspec" "$proto" >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to remove the iptables ACCEPT rule for ${_rspec}/${proto} of a removed inbound.${NC}"
        _removed=1
    done
    if (( _removed == 1 )); then
        save_firewall_rules >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to persist firewall rules after recycling removed inbounds' ports.${NC}"
    fi
    return 0
}

# $1 = core, rest = removed tags
_protocol_removed_side_effects() {
    local core="$1"; shift
    local tag='' cfg='' _stem2='' _tuic_removed=0 _reg_failed=0 _sync_failed=0 _hy2env_failed=0 _sb_stripped=''
    local _ld="${ABOX_DIR:-/etc/ddr}"
    # M-12(1): hop parameters are captured up front: the .env port
    # reconciliation below may unset HY2_BASE_PORT before the tail
    # block deletes the hop NAT rules.
    local _hop_start="${HY2_RANGE_START:-}" _hop_end="${HY2_RANGE_END:-}" _hop_base="${HY2_BASE_PORT:-}" _hop_iface="${INGRESS_IF:-}" _hop_on="${HY2_HOP:-}"
    local _tuic_ct='' _tuic_f=''
    local -a _deleted=()
    for tag in "$@"; do
        case "$tag" in
            # R15-F10-03: the Argo source inbounds live in sing-box;
            # an Xray-side tag of the same name must not tear down
            # the other core's tunnel (cf. the Hy2 cleanup below,
            # which already guards on core == sing-box). Callers pass
            # the tags removed from that core's own config, so for
            # core == sing-box the named inbound is confirmed gone
            # by the deletion that just ran.
            vmess-ws-in) [[ "$core" == 'sing-box' ]] && argo_remove_unit argo-vmess || true ;;
            vless-ws-in) [[ "$core" == 'sing-box' ]] && argo_remove_unit argo-vless || true ;;
            *trojan*) _standalone_link_prune_if_gone trojan-xray "${_ld}/standalone-links.d/trojan-xray.link"; _standalone_link_prune_if_gone trojan-sb "${_ld}/standalone-links.d/trojan-sb.link"; case "$tag" in trojan-landing-[0-9]*) _stem2=$(users_link_stem "$core" "$tag" 2>/dev/null || printf '%s' "$tag"); _prune_standalone_link_file "$core" "$_stem2" "${_ld}/standalone-links.d/${_stem2}.link" ;; esac ;;
            *tuic*) _standalone_link_prune_if_gone tuic /etc/ddr/standalone-links.d/tuic.link; _tuic_removed=1 ;;
            *anytls*) _standalone_link_prune_if_gone anytls /etc/ddr/standalone-links.d/anytls.link ;;
            *shadowtls*) _standalone_link_prune_if_gone shadowtls /etc/ddr/standalone-links.d/shadowtls.link ;;
            *socks*|*mixed*) _standalone_link_prune_if_gone socks5-sb "${_ld}/standalone-links.d/socks5-sb.link"; _standalone_link_prune_if_gone socks5-xray "${_ld}/standalone-links.d/socks5-xray.link"; case "$tag" in socks5-landing-[0-9]*|socks-in-[0-9]*|mixed-in-[0-9]*) _stem2=$(users_link_stem "$core" "$tag" 2>/dev/null || printf '%s' "$tag"); _prune_standalone_link_file "$core" "$_stem2" "${_ld}/standalone-links.d/${_stem2}.link"; _prune_standalone_link_file "$core" "$tag" "${_ld}/standalone-links.d/${tag}.link" ;; esac ;;
        esac
        # R16-F10-01: never let the generic delete undo a prune that
        # just kept a link: when $tag is itself a prune key, the link
        # is owned by _standalone_link_prune_if_gone (delete only on
        # confirmed rc 1); the generic rm would delete it unconditionally.
        # M-29(3): these inbound tags' links are owned by
        # _standalone_link_prune_if_gone above under a different
        # filename (tuic-in -> tuic.link, trojan-landing ->
        # trojan-sb.link, ...); the generic rm would delete a
        # nonexistent ${tag}.link and must not run for them.
        case "$tag" in
            trojan-xray|trojan-sb|tuic|anytls|shadowtls|socks5-sb|socks5-xray) ;;
            *)
                if [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
                    rm -f -- "/etc/ddr/standalone-links.d/${tag}.link" 2>/dev/null || true
                    # M-02: a numbered trojan/socks5 instance owns a
                    # per-core stem link (trojan-xray-2, trojan-sb-2,
                    # ...), not ${tag}.link. Remove this core's stem
                    # link, survivor-gated so an unverifiable config
                    # keeps the link; the rm above already removed a
                    # pre-fix legacy shared-name file, if any.
                    case "$tag" in
                        trojan-landing-[0-9]*)
                            if [[ "$core" == 'xray' ]]; then
                                _standalone_link_prune_if_gone "trojan-xray-${tag#trojan-landing-}" "/etc/ddr/standalone-links.d/trojan-xray-${tag#trojan-landing-}.link"
                            elif [[ "$core" == 'sing-box' ]]; then
                                _standalone_link_prune_if_gone "trojan-sb-${tag#trojan-landing-}" "/etc/ddr/standalone-links.d/trojan-sb-${tag#trojan-landing-}.link"
                            fi ;;
                        socks5-landing-[0-9]*)
                            if [[ "$core" == 'xray' ]]; then
                                _standalone_link_prune_if_gone "socks5-xray-${tag#socks5-landing-}" "/etc/ddr/standalone-links.d/socks5-xray-${tag#socks5-landing-}.link"
                            elif [[ "$core" == 'sing-box' ]]; then
                                _standalone_link_prune_if_gone "socks5-sb-${tag#socks5-landing-}" "/etc/ddr/standalone-links.d/socks5-sb-${tag#socks5-landing-}.link"
                            fi ;;
                    esac
                fi ;;
        esac
        # R38-M1: a failed registry removal must not be swallowed --
        # the registry holds user credentials, and the callers report
        # success unless this function says otherwise.
        if ! users_registry_remove "$core" "$tag"; then
            msg "${YELLOW}[!] Failed to remove the user registry for ${core}/${tag}; credentials may remain on disk.${NC}"
            _reg_failed=1
        fi
    done
    # SYD-B E16: a removed sing-box Hy2 inbound owns its cert/key
    # pair. Delete it only when no hysteria2 inbound remains and
    # the pair is the script-managed /etc/sing-box/hy2.crt+key;
    # anything else (shared, external path, still referenced) stays.
    if [[ "$core" == 'sing-box' ]]; then
        if [[ -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json && -s /etc/sing-box/config.json ]]; then
            # 2gq: delete the cert pair only when jq confirms no
            # hysteria2 inbound remains (one-pass Boolean, rc 1);
            # a jq failure or an empty config keeps it.
            local _hy2_jq_rc=0
            # M-6-residual (A-leg): jq -s over the stripped view; raw jq
            # on a commented config fails with a parse error (rc 5),
            # neither 0 nor 1, so the cert pair would wrongly survive
            # when no hysteria2 inbound remains. Strip once here; the
            # M-12 block below reuses the same view (the config is not
            # rewritten between the two blocks). An empty-after-strip
            # config is unverifiable, not a confirmation: keep the pair
            # (rc 5, same as a jq failure).
            if [[ -z "${_sb_stripped//[[:space:]]/}" ]]; then
                _sb_stripped=$(jsonc_strip_comments /etc/sing-box/config.json 2>/dev/null) || _sb_stripped=''
            fi
            if [[ -n "${_sb_stripped//[[:space:]]/}" ]]; then
                printf '%s' "$_sb_stripped" | jq -s -e '([.[] | .inbounds[]? | select(.type == "hysteria2")] | length) > 0' >/dev/null 2>&1 || _hy2_jq_rc=$?
            else
                _hy2_jq_rc=5
            fi
            if [[ "$_hy2_jq_rc" == 1 ]]; then
                # 05f-H-05f-02: delete each file only when no inbound
                # of ANY protocol still references it (a manual or
                # other-protocol inbound may share the pair).
                if ! _singbox_cert_referenced /etc/sing-box/config.json /etc/sing-box/hy2.crt; then
                    if [[ -f /etc/sing-box/hy2.crt && ! -L /etc/sing-box/hy2.crt ]]; then
                        rm -f -- /etc/sing-box/hy2.crt 2>/dev/null || true
                        [[ -e /etc/sing-box/hy2.crt ]] || _deleted+=("/etc/sing-box/hy2.crt")
                    fi
                fi
                if ! _singbox_cert_referenced /etc/sing-box/config.json /etc/sing-box/hy2.key; then
                    if [[ -f /etc/sing-box/hy2.key && ! -L /etc/sing-box/hy2.key ]]; then
                        rm -f -- /etc/sing-box/hy2.key 2>/dev/null || true
                        [[ -e /etc/sing-box/hy2.key ]] || _deleted+=("/etc/sing-box/hy2.key")
                    fi
                fi
            fi
        fi
    fi
    # N5 (followup5 D-leg): a removed sing-box TUIC inbound owns its
    # per-tag cert/key pair (/etc/sing-box/tuic-<tag>-<hash>.crt/key,
    # plus the .A-Box-bak a failed redeploy may have left). The Hy2
    # block above has this cleanup; TUIC never did, so clear_all left
    # orphaned pairs behind. Delete only files no live TUIC inbound
    # still references (paths read from the live config, so a
    # surviving inbound's pair is never touched); an unreadable or
    # unparseable config keeps everything (fail-closed, same as Hy2).
    if [[ "$core" == 'sing-box' && "$_tuic_removed" == 1 ]]; then
        cfg='/etc/sing-box/config.json'
        if [[ -f "$cfg" && ! -L "$cfg" && -s "$cfg" ]]; then
            local _tuic_stripped='' _tuic_refs='' _tuic_cert_file='' _tuic_base=''
            _tuic_stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || _tuic_stripped=''
            if [[ -n "${_tuic_stripped//[[:space:]]/}" ]] && _tuic_refs=$(printf '%s' "$_tuic_stripped" | jq -r '.inbounds[]? | (.tls.certificate_path // empty), (.tls.key_path // empty)' 2>/dev/null); then
                for _tuic_cert_file in /etc/sing-box/tuic-*.crt /etc/sing-box/tuic-*.key /etc/sing-box/tuic-*.crt.A-Box-bak /etc/sing-box/tuic-*.key.A-Box-bak; do
                    [[ -f "$_tuic_cert_file" && ! -L "$_tuic_cert_file" ]] || continue
                    _tuic_base="${_tuic_cert_file%.A-Box-bak}"
                    # R38-H1: check the file's ACTUAL path too: a
                    # surviving inbound may reference the .A-Box-bak
                    # file directly, not its live base path.
                    grep -Fxq -- "$_tuic_cert_file" <<< "$_tuic_refs" 2>/dev/null && continue
                    grep -Fxq -- "$_tuic_base" <<< "$_tuic_refs" 2>/dev/null || rm -f -- "$_tuic_cert_file" 2>/dev/null || true
                done
            fi
        fi
    fi
    # U148: reconcile .env listener ports now, before the caller's
    # defense refresh rebuilds the fail2ban port list from .env.
    # W2-FAIL-1: a failed reconciliation leaves stale expectations
    # behind -- exactly the trigger the probe restores on. Surface
    # it (like the registry failure above) instead of swallowing it
    # with `|| true`: the caller then reports the delete as failed
    # rather than printing "已删除" over an inconsistent state.
    if ! sync_env_ports_after_removal; then
        msg "${YELLOW}[!] .env port reconciliation failed after removing ${core} protocol(s); stale listener ports may remain and the health probe may restore them.${NC}"
        _sync_failed=1
    fi
    # W7-OBS-4: once the last Hy2 is gone, its non-port .env keys
    # (domain/password/fingerprint/hop settings) must go too -- the
    # probe reads the hop keys and the Clash emitter resurrects a
    # deleted Hy2 from the stale fallbacks. The helper verifies
    # "no Hy2 remains" itself; a failure is surfaced like the sync
    # failure above. (Runs after sync; the M-12(1) hop-rule block
    # below uses the _hop_* values captured up front, so clearing
    # the live vars here cannot starve it.)
    if ! _clear_hy2_nonport_env_vars; then
        msg "${YELLOW}[!] Hy2 settings cleanup failed after removing ${core} protocol(s); stale Hy2 values may remain in .env.${NC}"
        _hy2env_failed=1
    fi
    # The shared Argo link registration goes only when no ws inbound remains.
    if [[ "$core" == 'sing-box' ]]; then
        cfg='/etc/sing-box/config.json'
        if [[ -f "$cfg" && ! -L "$cfg" && -s "$cfg" ]]; then
            # 2gq: remove the shared Argo link only when jq confirms no
            # ws inbound remains (one-pass Boolean, rc 1); a jq
            # failure or an empty config keeps it.
            local _argo_jq_rc=0
            # M-6-rescan (D-leg): jq -s over the stripped view; raw jq
            # on a commented config fails with a parse error (rc 5),
            # neither 0 nor 1, so the shared Argo link would wrongly
            # survive when no ws inbound remains. -s slurp over stdin
            # keeps the same one-document array shape as file input.
            jsonc_strip_comments "$cfg" 2>/dev/null | jq -s -e '([.[] | .inbounds[]? | select(.tag == "vmess-ws-in" or .tag == "vless-ws-in")] | length) > 0' >/dev/null 2>&1 || _argo_jq_rc=$?
            if [[ "$_argo_jq_rc" == 1 ]]; then
                rm -f -- /etc/ddr/standalone-links.d/argo.link 2>/dev/null || true
                argo_remove_unit argo || true
            fi
        fi
    fi
    # M-12(1): reclaim Hy2 hop NAT rules and per-tag TUIC certs when
    # the last inbound of that kind is gone. The HOP REDIRECT rules
    # live in the sing-box unit's ExecStartPre/ExecStopPost and would
    # otherwise keep hijacking the hop range into a base port with no
    # inbound behind it; note the unit file itself is not rewritten
    # here, so a later service restart re-adds the rules until the
    # next deploy regenerates the unit.
    if [[ "$core" == 'sing-box' && -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json && -s /etc/sing-box/config.json ]]; then
        local _hop_left_rc=0
        # M-6-residual (A-leg): reuse the stripped view from the Hy2
        # block above (strip-once); re-strip only if it is still blank
        # (Hy2 block never ran, or the config strips to nothing -- the
        # blank case stays unverifiable, rc 5, same as a jq failure).
        if [[ -z "${_sb_stripped//[[:space:]]/}" ]]; then
            _sb_stripped=$(jsonc_strip_comments /etc/sing-box/config.json 2>/dev/null) || _sb_stripped=''
        fi
        if [[ -n "${_sb_stripped//[[:space:]]/}" ]]; then
            printf '%s' "$_sb_stripped" | jq -s -e '([.[] | .inbounds[]? | select(.type == "hysteria2")] | length) > 0' >/dev/null 2>&1 || _hop_left_rc=$?
        else
            _hop_left_rc=5
        fi
        if [[ "$_hop_left_rc" == 1 && "$_hop_on" == 'true' && -n "$_hop_start" && -n "$_hop_end" && -n "$_hop_base" && -n "$_hop_iface" ]]; then
            if remove_hy2_hop_nat_rules "$_hop_start" "$_hop_end" "$_hop_base" "$_hop_iface"; then
                save_firewall_rules >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to persist firewall rules after removing Hy2 hop NAT rules.${NC}"
            else
                msg "${YELLOW}[!] Failed to remove Hy2 hop NAT rules after the last Hy2 inbound was removed.${NC}"
            fi
        fi
        local _tuic_left_rc=0
        # M-6-residual (A-leg): same stripped view as the hop check
        # above; blank-after-strip stays unverifiable (rc 5).
        if [[ -n "${_sb_stripped//[[:space:]]/}" ]]; then
            printf '%s' "$_sb_stripped" | jq -s -e '([.[] | .inbounds[]? | select(.type == "tuic")] | length) > 0' >/dev/null 2>&1 || _tuic_left_rc=$?
        else
            _tuic_left_rc=5
        fi
        if [[ "$_tuic_left_rc" == 1 ]]; then
            for tag in "$@"; do
                case "$tag" in
                    *tuic*)
                        _tuic_ct=$(tuic_cert_tag "$tag")
                        for _tuic_f in "/etc/sing-box/tuic-${_tuic_ct}.crt" "/etc/sing-box/tuic-${_tuic_ct}.key" "/etc/sing-box/tuic-${_tuic_ct}.crt.A-Box-bak" "/etc/sing-box/tuic-${_tuic_ct}.key.A-Box-bak"; do
                            [[ -f "$_tuic_f" && ! -L "$_tuic_f" ]] || continue
                            # R38-H1 (05f-H-05f-02): keep when any inbound
                            # of any protocol still references this file:
                            # the file's ACTUAL path first -- a surviving
                            # inbound may reference the .A-Box-bak file
                            # directly -- then, for a .A-Box-bak file,
                            # its live base path.
                            _singbox_cert_referenced /etc/sing-box/config.json "$_tuic_f" && continue
                            if [[ "$_tuic_f" == *.A-Box-bak ]]; then
                                _singbox_cert_referenced /etc/sing-box/config.json "${_tuic_f%.A-Box-bak}" && continue
                            fi
                            rm -f -- "$_tuic_f" 2>/dev/null || true
                            [[ -e "$_tuic_f" ]] || _deleted+=("$_tuic_f")
                        done
                        ;;
                esac
            done
        fi
    fi
    # L-5: a deleted cert's manifest row must go with it (same as
    # _singbox_cleanup_tuic_certs_when_none_remain), or the manifest
    # drifts from disk (stale hash vs a same-name rebuild).
    (( ${#_deleted[@]} > 0 )) && _manifest_drop_paths "${_deleted[@]}" || true
    if (( _reg_failed == 1 || _sync_failed == 1 || _hy2env_failed == 1 )); then return 1; fi
    return 0
}

# W2-FAIL-1 (point 2): post-delete verification -- confirm every
# removed tag is actually absent from the live config before the
# caller reports success. rc 0 = all absent, 1 = a tag survives or
# the config cannot be verified (fail-closed: an unverifiable config
# is never reported as cleaned).
_removed_tags_absent_from_config() { # $1 = cfg, rest = tags
    local cfg="$1"; shift
    local _stripped='' _t='' _jq_rc=0
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null) || return 1
    [[ -n "${_stripped//[[:space:]]/}" ]] || return 1
    for _t in "$@"; do
        printf '%s' "$_stripped" | jq -e --arg t "$_t" 'any(.inbounds[]?; .tag == $t)' >/dev/null 2>&1 || _jq_rc=$?
        case "$_jq_rc" in
            0) return 1 ;; # tag still present
            1) : ;;        # confirmed absent
            *) return 1 ;; # unverifiable: fail closed
        esac
        _jq_rc=0
    done
    return 0
}

_remove_hy2_official() {
    # Destructive: only ever remove a hysteria install whose service
    # unit is A-Box-managed. A foreign official install shares the
    # same name and paths and must not be deleted by name alone.
    if ! abox_owns_service hysteria; then
        msg "${YELLOW}[!] $(tr_msg hy2_skip_foreign)${NC}"
        return 1
    fi
    # R6C11-01 (moved up, R10-03): refuse if /etc/hysteria (or
    # anything under it) is a mountpoint BEFORE stopping or
    # deleting anything; rm -rf would delete shared foreign data.
    path_tree_has_mountpoint /etc/hysteria && return 1
    stop_abox_service_soft hysteria >/dev/null 2>&1 || {
        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then systemctl stop hysteria >/dev/null 2>&1 || true
        elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then rc-service hysteria stop >/dev/null 2>&1 || true; fi
    }
    # Verify the service actually stopped before deleting anything:
    # a failed stop must not be reported as a successful uninstall.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        local hy2_state
        hy2_state=$(systemctl show -p ActiveState --value hysteria 2>/dev/null) || return 1
        [[ "$hy2_state" == inactive || "$hy2_state" == failed ]] || return 1
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        local hy2_rc
        rc-service hysteria status >/dev/null 2>&1; hy2_rc=$?
        case "$hy2_rc" in
            3|16|32) : ;;
            *) return 1 ;;
        esac
    fi
    # R16C11-02: refuse while any hysteria process remains: the
    # service MainPID (if any) or any process named hysteria.
    local _hy2_main_pid=''
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        _hy2_main_pid=$(systemctl show -p MainPID --value hysteria 2>/dev/null || echo 0)
        if [[ "$_hy2_main_pid" =~ ^[0-9]+$ ]] && (( _hy2_main_pid > 0 )) && [[ -d /proc/$_hy2_main_pid ]]; then return 1; fi
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -x hysteria >/dev/null 2>&1; then return 1; fi
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl disable hysteria >/dev/null 2>&1 || true
        rm -f -- /etc/systemd/system/hysteria.service || return 1
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        rc-update del hysteria default >/dev/null 2>&1 || true
        rm -f -- /etc/init.d/hysteria /etc/conf.d/hysteria || return 1
    fi
    # 2fv: remove the grant script and the tmpfiles.d persistence
    # entry (both are deploy artifacts of the official-hop grant),
    # and reset the xtables lock permissions (M-18 supplement).
    # Service is stopped and the unit deleted above, so the grant
    # cannot be re-applied after revoke.
    hy2_hop_xtables_lock_revoke || return 1
    rm -rf -- /etc/hysteria || return 1
    rm -f -- /etc/ddr/standalone-links.d/hy2.link /etc/ddr/standalone-links.d/hysteria.link 2>/dev/null || true
    # R38-M1: propagate a failed registry removal (the caller
    # reports the Hy2 removal as failed); the old unconditional
    # `return 0` reported a surviving credential registry as deleted.
    users_registry_remove hy2 hy2-official || return 1
    return 0
}

remove_single_protocol_menu() {
    local -a rows=() tags=()
    local row='' core='' tag='' proto='' port='' label='' idx=0 choice='' answer='' info='' cfg='' deps='' d='' _detour_target='' _refs='' _cfg_stripped='' _freed_ports=''
    local _inv_tmp='' _inv_rc=0 _side_rc=0
    _inv_tmp=$(mktemp /tmp/A-Box-inventory.XXXXXX) || return 1
    protocol_inventory > "$_inv_tmp"; _inv_rc=$?
    mapfile -t rows < "$_inv_tmp"
    rm -f -- "$_inv_tmp"
    if (( _inv_rc != 0 )); then
        return 1
    fi
    # D-leg O2 (same symptom as 124bfe8-leg O2): the inventory also
    # lists the ShadowTLS inner detour inbounds (shadowtls-ss,
    # shadowtls-in-2-ss), which have no listen_port, so the delete
    # list showed them as "ShadowTLS · sing-box · :—" -- and selecting
    # one deleted the live outer node with it (the deps query finds
    # the outer inbound detouring to it). Helpers are never standalone
    # nodes: drop them from the delete list, using the same regex
    # view_config already uses (L30386/L30420). They are still removed
    # together with their outer node via the E12 detour-target
    # absorption below, never standalone.
    if (( ${#rows[@]} > 0 )); then
        local -a _rows_f=()
        local _r='' _c='' _t='' _p='' _port=''
        for _r in "${rows[@]}"; do
            IFS=$'\t' read -r _c _t _p _port <<< "$_r"
            if [[ "$_t" =~ ^(shadowtls-ss|shadowtls-in(-[0-9]+)?-ss)$ ]]; then
                continue
            fi
            _rows_f+=("$_r")
        done
        rows=("${_rows_f[@]}")
    fi
    if (( ${#rows[@]} == 0 )); then
        msg "${YELLOW}$(tr_msg cl_none)${NC}"
        return 0
    fi
    msg "${BOLD}${GREEN}$(tr_msg cl_m_single)${NC}"
    for row in "${rows[@]}"; do
        idx=$((idx + 1))
        IFS=$'\t' read -r core tag proto port <<< "$row"
        label=$(protocol_label "$tag" "$proto")
        local _idxf=''; printf -v _idxf '%2d' "$idx"
        msg "${YELLOW}${_idxf}.  ${label} · ${core} · :${port:-—}${NC}"
    done
    read -r -p "$(tr_msg cl_select)" choice || return 0
    choice=$(normalize_fa_ar_digits "$choice")
    # Length-gated first: an unbounded digit string wraps in bash
    # arithmetic (2^64+1 becomes 1) and would select the first row.
    # 10# stays for the octal rule (08 errors, 010 selects index 7).
    if ! valid_decimal_upto "$choice" "${#rows[@]}"; then
        msg "${RED}$(tr_msg invalid_input)${NC}"
        return 0
    fi
    choice=$((10#$choice))
    if (( choice < 1 )); then
        msg "${RED}$(tr_msg invalid_input)${NC}"
        return 0
    fi
    row="${rows[$((choice - 1))]}"
    IFS=$'\t' read -r core tag proto port <<< "$row"
    label=$(protocol_label "$tag" "$proto")
    tags=("$tag")
    if [[ "$core" != 'hy2' ]]; then
        info=$(_protocol_cfg_of "$core")
        IFS='|' read -r cfg _ _ <<< "$info"
        # R16-F11-01: run the dependency queries against the same
        # JSONC-stripped view _remove_inbounds_from_config deletes
        # through: raw jq on a commented config fails and the
        # `|| true` turns the failure into an empty dependency set,
        # orphaning ShadowTLS detour targets/referrers. A strip
        # failure fails closed instead of deleting with unknown deps.
        _cfg_stripped=$(mktemp /tmp/A-Box-rm-deps.XXXXXX) || return 1
        if ! jsonc_strip_comments "$cfg" > "$_cfg_stripped" 2>/dev/null; then
            rm -f -- "$_cfg_stripped"
            return 1
        fi
        deps=$(jq -r --arg t "$tag" '.inbounds[]? | select(.detour == $t) | .tag' "$_cfg_stripped" 2>/dev/null || true)
        # SYD-B E12: the reverse query above misses the case where
        # the deleted inbound IS the detour source (ShadowTLS:
        # shadowtls-in detours to shadowtls-ss; the ss inbound is
        # the detour TARGET, not a referrer). Look the target up
        # by the deleted tag itself and absorb it only when it is
        # an inbound of this config and no other surviving inbound
        # still detours to it.
        _detour_target=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .detour // empty' "$_cfg_stripped" 2>/dev/null || true)
        if [[ -n "$_detour_target" ]]; then
            if jq -e --arg dt "$_detour_target" '.inbounds[]? | select(.tag == $dt)' "$_cfg_stripped" >/dev/null 2>&1; then
                _refs=$(jq -r --arg dt "$_detour_target" --arg t "$tag" '.inbounds[]? | select(.detour == $dt and .tag != $t) | .tag' "$_cfg_stripped" 2>/dev/null || true)
                if [[ -z "$_refs" ]] && ! grep -qx "$_detour_target" <<< "${deps:-}"; then
                    if [[ -n "$deps" ]]; then deps+=$'\n'"$_detour_target"; else deps="$_detour_target"; fi
                fi
            fi
        fi
        if [[ -n "$deps" ]]; then
            while IFS= read -r d; do [[ -n "$d" ]] && tags+=("$d"); done <<< "$deps"
            msg "${YELLOW}$(tr_msg cl_dep_warn): ${deps//$'\n'/, }${NC}"
        fi
        # M-12(1): capture the doomed inbounds' ports now (the stripped
        # config is deleted below); the firewall openings are recycled
        # after the side effects, only for ports nothing else uses.
        _freed_ports=$(removed_inbound_ports "$_cfg_stripped" "${tags[@]}" 2>/dev/null | sort -u || true)
        rm -f -- "$_cfg_stripped"
    fi
    read -r -p "$(tr_msg cl_confirm_one) ${label} [Y/N]: " answer || return 0
    is_yes "$answer" || { msg "${GREEN}$(tr_msg remove_cancelled)${NC}"; return 0; }
    if [[ "$core" == 'hy2' ]]; then
        if ! _remove_hy2_official; then
            msg "${RED}$(tr_msg cl_fail)${NC}"
            return 1
        fi
        # SYD-B E4: the hy2 branch previously skipped side effects,
        # so stale .env port keys (incl. HY2_URI_PORTS) survived.
        _protocol_removed_side_effects hy2 hy2-official || _side_rc=1
        # M-12(1): recycle the Hy2 UDP port when nothing else uses it.
        if [[ "$port" =~ ^[0-9]+$ ]]; then printf 'udp/%s\n' "$port" | firewall_recycle_freed_ports; fi
    else
        if ! _remove_inbounds_from_config "$core" "${tags[@]}"; then
            msg "${RED}$(tr_msg cl_fail)${NC}"
            return 1
        fi
        _protocol_removed_side_effects "$core" "${tags[@]}" || _side_rc=1
        if [[ -n "$_freed_ports" ]]; then printf '%s\n' "$_freed_ports" | firewall_recycle_freed_ports; fi
    fi
    ( setup_active_defense ) >/dev/null 2>&1 || true
    # R38-M1: the protocol is deleted, but a failed side effect
    # (registry cleanup or .env port reconciliation) must not be
    # reported as a clean success. The specific warning was already
    # printed by _protocol_removed_side_effects.
    if (( _side_rc == 1 )); then
        msg "${YELLOW}[!] Protocol ${label} removed, but post-delete cleanup failed; the committed state may be inconsistent (see the warning above).${NC}"
        return 1
    fi
    # W2-FAIL-1 (point 2): verify the delete actually landed in the
    # live config before reporting success. A tag that survives (or
    # an unreadable config) is a failed delete, not a deleted one.
    if [[ "$core" == 'hy2' ]]; then
        if [[ -e "${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}" || -L "${ABOX_HY2_CFG:-/etc/hysteria/config.yaml}" ]]; then
            msg "${RED}$(tr_msg cl_fail)${NC}"
            return 1
        fi
    else
        if ! _removed_tags_absent_from_config "$cfg" "${tags[@]}"; then
            msg "${RED}$(tr_msg cl_fail)${NC}"
            return 1
        fi
    fi
    refresh_subscription_after_deploy || true
    msg "${GREEN}$(tr_msg cl_done): ${label}${NC}"
    return 0
}

# R26-H-NF-04: after a clear-all, a core config holding only the
# internal "api" inbound (tag "api", dokodemo-door 127.0.0.1:10085) is
# an empty stack that still listens. The api inbound is stats
# infrastructure for live nodes; with no nodes left it serves nothing,
# and the next deploy rebuilds it from scratch. Remove it when it is
# the SOLE remaining inbound; a config with any other inbound is left
# alone (the caller already failed to clear it). A missing config is a
# no-op success; an unreadable config fails closed (returns 1).
clear_all_remove_sole_api_inbound() {
    local core="$1" info='' cfg='' tags=''
    info=$(_protocol_cfg_of "$core") || return 1
    IFS='|' read -r cfg _ _ <<< "$info"
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 0
    # jq first (its failure must fail closed), paste second: a
    # jq | paste pipeline would report paste's status and hide a
    # corrupt config.
    # M-6-rescan (D-leg): read tags through the stripped view; raw jq
    # on a commented config yields no tags and a sole-api config
    # would never be recognised as such.
    tags=$(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r '.inbounds[]? | .tag // empty' 2>/dev/null) || return 1
    tags=$(printf '%s' "$tags" | paste -sd, -)
    [[ "$tags" == 'api' ]] || return 0
    _remove_inbounds_from_config "$core" api
}

# M41-NEW-03 follow-up: the stop family below is the MAIN-SCRIPT copy of
# the functions that previously existed ONLY inside the traffic_monitor.sh
# template (EOF_TRAFFIC heredoc, setup_traffic_monitor). clear_all_protocols
# calls stop_owned, but in the main-script process that name did not exist
# (bash rc 127, "command not found"), so clear_all could never stop a
# service and always reported stop failure for xray/sing-box/hysteria
# (S1 + S2 real-device legs). The template keeps its own copies for the
# standalone cron script; run_self_tests asserts the two copies stay
# byte-identical (drift guard next to the traffic_body checks).
# BEGIN MAIN STOP FAMILY

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

# END MAIN STOP FAMILY

clear_all_protocols() {
    local answer='' core='' info='' cfg='' wipe_ok=1 _tags_tmp='' _tags_stripped='' _cmv='' _freed_tmp='' _hy2port=''
    local -a all_tags=()
    read -r -p "$(tr_msg cl_confirm_all) [Y/N]: " answer || return 0
    is_yes "$answer" || { msg "${GREEN}$(tr_msg remove_cancelled)${NC}"; return 0; }
    # R26-H-NF-04: record the cleared desired state BEFORE removing
    # anything, so the health probe cannot restart or self-heal a stack
    # that is being cleared. If the suppression cannot be recorded
    # (e.g. corrupt pair state), abort the clear instead of leaving a
    # half-cleared stack under a stale RUNNING desired state.
    # (Serialized against the probe by the menu runtime lock.)
    if ! set_desired_state MANUAL_STOPPED; then
        msg "${RED}[!] $(tr_msg cl_desired_commit_fail)${NC}" >&2
        return 1
    fi
    _freed_tmp=$(mktemp /tmp/A-Box-cl-ports.XXXXXX) || { msg "${RED}$(tr_msg cl_fail)${NC}"; return 1; }
    for core in xray sing-box; do
        info=$(_protocol_cfg_of "$core") || continue
        IFS='|' read -r cfg _ _ <<< "$info"
        if [[ -L "$cfg" ]]; then
            # R12C11-01: an existing but refused (symlink) config counts as
            # a clear failure; otherwise the global wipe below would delete
            # registries/links while this core's inbounds survive.
            msg "${YELLOW}[!] ${core}: $(tr_msg cl_fail)${NC}"
            wipe_ok=0
            continue
        fi
        [[ -f "$cfg" ]] || continue
        # R15-F11-01: enumerate through the JSONC-stripped view,
        # like _remove_inbounds_from_config does: raw jq on a
        # commented config fails and the process substitution hides
        # it, leaving all_tags empty so the side effects below are
        # silently skipped while the wipe still reports success. An
        # enumeration failure is a wipe failure for this core: fail
        # closed here instead of deleting inbounds whose follow-up
        # cleanup cannot run.
        _tags_tmp=$(mktemp /tmp/A-Box-cl-tags.XXXXXX) || { msg "${YELLOW}[!] ${core}: $(tr_msg cl_fail)${NC}"; wipe_ok=0; continue; }
        _tags_stripped=$(mktemp /tmp/A-Box-cl-strip.XXXXXX) || { rm -f "$_tags_tmp"; msg "${YELLOW}[!] ${core}: $(tr_msg cl_fail)${NC}"; wipe_ok=0; continue; }
        if ! jsonc_strip_comments "$cfg" > "$_tags_stripped" 2>/dev/null || ! jq -r '.inbounds[]? | .tag // empty' "$_tags_stripped" > "$_tags_tmp" 2>/dev/null; then
            rm -f "$_tags_tmp" "$_tags_stripped"
            msg "${YELLOW}[!] ${core}: $(tr_msg cl_fail)${NC}"
            wipe_ok=0
            continue
        fi
        mapfile -t all_tags < "$_tags_tmp"
        # M-12(1): snapshot this core's doomed inbounds' ports before
        # the stripped config is deleted; recycled later (wipe_ok only).
        removed_inbound_ports "$_tags_stripped" "${all_tags[@]}" 2>/dev/null >> "$_freed_tmp" || true
        rm -f "$_tags_tmp" "$_tags_stripped"
        if ! _remove_inbounds_from_config "$core" --all; then
            msg "${YELLOW}[!] ${core}: $(tr_msg cl_fail)${NC}"
            wipe_ok=0
            continue
        fi
        (( ${#all_tags[@]} )) && _protocol_removed_side_effects "$core" "${all_tags[@]}"
    done
    if [[ -f /etc/hysteria/config.yaml ]]; then
        _hy2port=$(xl_hy2_port 2>/dev/null || true)
        if _remove_hy2_official; then
            # R1-11-F09 (SYD-B E4 mirror): Hy2 removal must run side effects
            # (notably .env port reconciliation) just like the JSON cores.
            _protocol_removed_side_effects hy2 hy2-official
            if [[ "$_hy2port" =~ ^[0-9]+$ ]]; then printf 'udp/%s\n' "$_hy2port" >> "$_freed_tmp"; fi
        else
            wipe_ok=0
        fi
    fi
    # R26-H-NF-04: a lone api inbound left by the clear above is an
    # empty stack that still listens (e.g. a self-heal-restored
    # dokodemo-door:10085). Remove it; the next deploy rebuilds it.
    # Anything else left means the clear itself failed, and wipe_ok
    # already records that.
    if (( wipe_ok == 1 )); then
        for core in xray sing-box; do
            clear_all_remove_sole_api_inbound "$core" || wipe_ok=0
        done
    fi
    # Wipe the user registries, standalone links and the shared Argo
    # tunnel only when every core was actually cleared; otherwise
    # surviving nodes would lose their user policies, links and tunnel.
    if (( wipe_ok == 1 )); then
        # R27-H-NF-04-variant: reconcile .env listener ports here, not
        # only inside _protocol_removed_side_effects. When a core's
        # config holds no inbounds at all (e.g. the self-heal-restored
        # empty config), clear_all_protocols skips side effects for
        # that core (empty tag list) and a stale VLESS_PORT survives
        # the clear. Gated on wipe_ok so a partial wipe never clears
        # ports of surviving nodes; best-effort (a failed sync keeps
        # the ports, exactly like a skipped one did).
        sync_env_ports_after_removal || true
        # M-12(1): recycle the freed ports now that every removal has
        # succeeded; on partial wipe the rules stay (fail-closed).
        if [[ -s "$_freed_tmp" ]]; then firewall_recycle_freed_ports < "$_freed_tmp"; fi
        argo_remove_unit argo || true
        # L-NEW-11: also run when the sing-box config held no inbounds
        # at clear time (side effects above are skipped for an empty
        # tag list), so orphan TUIC certs cannot survive a clear-all.
        _singbox_cleanup_tuic_certs_when_none_remain || true
        # R39-M1: a failed registry wipe used to only warn while
        # wipe_ok stayed 1, so the clear reported green success with
        # user credentials still on disk. Fold it into the verdict.
        users_registries_wipe || { msg "${YELLOW}[!] $(tprintf cu_users_note '/etc/ddr/users.d')${NC}"; wipe_ok=0; }
        rm -f -- /etc/ddr/standalone-links.d/*.link 2>/dev/null || true
        # R26-H-NF-04: the cleared stack has no core/mode anymore.
        # Both vars go together: validate_abox_env_semantics rejects a
        # half-present pair (CORE set + MODE empty) as corrupt, while
        # both-empty is the accepted pre-deployment state. The lines
        # stay (set-but-empty) so `set -u` readers stay safe.
        if [[ -f "${ABOX_ENV:-/etc/ddr/.env}" && ! -L "${ABOX_ENV:-/etc/ddr/.env}" ]]; then
            for _cmv in CORE MODE; do
                sed -i "s/^${_cmv}=.*/${_cmv}=\"\"/" "${ABOX_ENV:-/etc/ddr/.env}" 2>/dev/null || wipe_ok=0
            done
        fi
        # M41-NEW-03: the subscription export still lists the cleared
        # nodes; refresh it now (empty registries export as empty files)
        # so a stale subscription cannot keep serving revoked links.
        # Best-effort: if the refresh itself fails, delete both files
        # outright (fail closed — a missing export is safe, a stale one
        # is not); only if even that fails is the clear reported failed.
        if ! refresh_subscription_after_deploy; then
            rm -f -- "${SUBSCRIBE_DIR:-/etc/ddr/subscribe}/uri-list.txt" "${SUBSCRIBE_DIR:-/etc/ddr/subscribe}/subscription.base64" 2>/dev/null || wipe_ok=0
        fi
        # H-23 (Carbon R3): the stack is now empty (all inbounds gone,
        # registries wiped, CORE/MODE cleared above); stop + disable
        # the core services explicitly so a cleared stack does not
        # keep running as an empty shell. Only on a full wipe
        # (wipe_ok still 1): a partial wipe leaves surviving nodes
        # that must keep running. Best-effort: a never-deployed
        # service reports success (already stopped) via stop_owned.
        # R3-NEW-04: a stop failure is no longer swallowed (see the loop
        # below): stop_owned refuses a running service whose family is
        # not registered, and clear_all must say so and fail instead of
        # reporting success while the service keeps listening.
        if (( wipe_ok == 1 )); then
            for _clr_svc in xray sing-box hysteria; do
                # R3-NEW-04: a stop failure used to be swallowed by
                # `|| true` while the wipe still reported success, so a
                # cleared stack could keep running as an empty shell
                # with no warning at all. Report it visibly and fail
                # the clear: the stack is not fully cleared while a
                # core service keeps listening.
                if ! stop_owned "$_clr_svc" >/dev/null 2>&1; then
                    msg "${YELLOW}[!] ${_clr_svc}: $(tr_msg cl_stop_fail)${NC}"
                    wipe_ok=0
                fi
            done
            # L6-NEW-01: WARP routing state + live residue survive a
            # clear-all: _remove_inbounds_from_config only strips
            # rules referencing removed inbounds, and nothing else
            # in this function touches the routing state or the
            # warp-out endpoint, so a cleared stack kept a live
            # warp-out + its rules while the menu kept reporting
            # WARP as deployed. Scrub both live configs, then drop
            # the state entry (gated on wipe_ok: a partial wipe leaves
            # surviving nodes whose WARP routing must stay). Either
            # failure fails the clear instead of reporting success
            # over a residue.
            if (( wipe_ok == 1 )); then
                # S1-NEW-06: scrub BEFORE dropping the state entry
                # (same order as warp_undeploy's no-core path): a
                # scrub failure keeps the state flag, so the menu
                # stays truthful (WARP still deployed) instead of
                # reporting "not deployed" over a live warp-out.
                # The state entry is dropped only after the live
                # configs are actually clean.
                if ! warp_scrub_live_config; then
                    msg "${YELLOW}[!] warp-out: $(tr_msg cl_fail)${NC}"
                    wipe_ok=0
                elif ! routing_outbound_del 'warp-out'; then
                    msg "${YELLOW}[!] warp-out: $(tr_msg cl_fail)${NC}"
                    wipe_ok=0
                fi
            fi
            # In-memory CORE/MODE are stale after the wipe; main_loop
            # reloads .env on its next iteration, but reset them here
            # so nothing later in this iteration reads the old values.
            CORE='' MODE=''
        fi
    else
        msg "${YELLOW}[!] $(tr_msg cl_wipe_partial)${NC}"
    fi
    rm -f -- "$_freed_tmp"
    ( setup_active_defense ) >/dev/null 2>&1 || true
    if (( wipe_ok == 1 )); then
        msg "${GREEN}$(tr_msg cl_all_done)${NC}"
        return 0
    else
        # S1-NEW-06: a failed clear used to end in a silent
        # `return 1` here (the menu caller ignores the code),
        # so the user saw no failure verdict at all. Always say so.
        msg "${RED}[!] $(tr_msg cl_all_fail)${NC}"
        return 1
    fi
}

cleanup_protocols_menu() {
    local c=''
    while true; do
        clear
        msg "${CYAN}======================================================================${NC}"
        msg "${BOLD}${GREEN}$(tr_msg cl_title)${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC}  $(tr_msg cl_m_single)"
        msg "${CYAN}2.${NC}  $(tr_msg cl_m_all)"
        msg "${CYAN}3.${NC}  $(tr_msg cl_m_reset)"
        msg "${CYAN}0.${NC}  $(tr_msg back_main)"
        read -r -p "$(tr_msg cl_select)" c || return 0
        c=$(normalize_fa_ar_digits "$c")
        case "$c" in
            1) remove_single_protocol_menu; pause_return ;;
            2) clear_all_protocols; pause_return ;;
            3) check_virgin_state ;;
            0) return 0 ;;
            *) msg "${RED}$(tr_msg invalid_input)${NC}" ;;
        esac
    done
}

check_virgin_state() {
    if [[ -t 1 ]]; then
        command clear || true
    fi
    init_system_environment || die "$(tr_msg vg_init_fail)"
    msg "${YELLOW}$(tr_msg vg_title)${NC}"
    local confirm_virgin=""
    if [[ -t 0 ]]; then
        read -r -p "$(tr_msg vg_confirm)" confirm_virgin || confirm_virgin='N'
    else
        confirm_virgin="${ABOX_YES:-N}"
    fi
    [[ -n "$confirm_virgin" ]] || confirm_virgin='N'
    is_yes "$confirm_virgin" || { msg "${GREEN}$(tr_msg vg_cancelled)${NC}"; pause_return; return 0; }
    : "${ABOX_DIR:?$(tr_msg check_virgin_state_abox_dir_undefined)}"
    begin_deployment_transaction 'environment reset' xray sing-box hysteria || die "$(tr_msg vg_tx_fail)"
    preflight_reset_ownership || die "$(tr_msg vg_preflight_fail)"
    stop_all_managed_services || die "$(tr_msg vg_stop)"
    # M-12(2): snapshot the Wallos ports before the input rules are
    # reset: clean_input_rules deletes the A-Box ACCEPT rules the
    # Wallos HTTP/HTTPS front (and its 80/tcp HTTP-01 listener) needs,
    # and the reset must not strand a running Wallos stack.
    local _vg_wallos_mode='' _vg_wallos_pubport=''
    _vg_wallos_mode=$(wallos_state_value MODE 2>/dev/null || true)
    _vg_wallos_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
    clean_nat_rules || die "$(tr_msg cl_nat)"
    clean_input_rules || die "$(tr_msg cl_input)"
    save_firewall_rules || die "$(tr_msg pi_fw_persist_fail)"
    # M-12(2): replay the snapshotted Wallos ports after the reset.
    # Best-effort: a failed replay only warns and never rolls the
    # reset back (the reset itself is the requested outcome).
    if [[ "$_vg_wallos_mode" == 'http' || "$_vg_wallos_mode" == 'https' ]] && [[ "$_vg_wallos_pubport" =~ ^[0-9]+$ ]]; then
        ( allowPort "$_vg_wallos_pubport" tcp ) >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to restore the Wallos public port ${_vg_wallos_pubport}/tcp after the environment reset.${NC}"
        if [[ "$_vg_wallos_mode" == 'https' ]]; then
            ( allowPort 80 tcp ) >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to restore 80/tcp for Wallos HTTPS after the environment reset.${NC}"
        fi
        save_firewall_rules >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to persist firewall rules after restoring Wallos ports.${NC}"
    fi
    remove_all_abox_cron_blocks || die "$(tr_msg cl_cron)"
    # Menu 17 deep self-heal: pass force_heal=1 explicitly (never via environment).
    remove_all_owned_core_families 1 || die "$(tr_msg cl_cores_reset)"
    # M-18 (supplement): all core families are gone (units deleted),
    # so no service can re-apply the grant; revoke the xtables-lock
    # grant now that the hysteria service is stopped and removed.
    hy2_hop_xtables_lock_revoke || die "$(tr_msg cl_cores_reset)"
    remove_abox_env_file || die "$(tr_msg cl_env_reset)"
    for runtime_file in "$ABOX_DIR/traffic_monitor.sh" "$ABOX_DIR/geo_update.sh" "$ABOX_DIR/socket_probe.sh"; do
        remove_owned_runtime_helper "$runtime_file" || die "$(tprintf cl_runtime_reset "$runtime_file")"
    done
    remove_sni_candidate_cache || die "$(tr_msg cl_sni_reset)"
    if [[ -f "$DEPS_MARKER" && ! -L "$DEPS_MARKER" ]]; then rm -f -- "$DEPS_MARKER" || die "$(tr_msg cl_deps_reset)"; fi
    remove_owned_auxiliary_path /etc/fail2ban/jail.d/A-Box.local || die "$(tr_msg cl_f2b_jail)"
    remove_owned_auxiliary_path /etc/fail2ban/filter.d/A-Box.conf || die "$(tr_msg cl_f2b_filter)"
    remove_owned_auxiliary_path /etc/logrotate.d/A-Box || die "$(tr_msg cl_logrotate)"
    remove_abox_log_files || die "$(tr_msg cl_log_files)"
    # Argo units/binary, WARP/Argo/traffic state and the Wallos fail2ban
    # pair are outside the managed-path lists; remove them best-effort.
    argo_remove_unit argo || true
    argo_remove_unit argo-vmess || true
    argo_remove_unit argo-vless || true
    # R12C11-02: cloudflared is deleted only when A-Box ownership is recorded
    # and no Wallos cftunnel consumer remains; a foreign binary is kept.
    if [[ -f /etc/ddr/.abox-cloudflared-owned && ! -e /etc/systemd/system/abox-wallos-cftunnel.service && ! -e /etc/init.d/abox-wallos-cftunnel ]]; then
        # 05e1-M2: binary first, marker only once the binary is gone
        # (same reason as the do_cleanup block).
        if rm -f /usr/local/bin/cloudflared; then
            rm -f /etc/ddr/.abox-cloudflared-owned || true
        else
            msg "${YELLOW}[!] Failed to remove /usr/local/bin/cloudflared; keeping the ownership marker so the leftover binary can be removed later.${NC}"
        fi
    fi
    rm -f "$ROUTING_STATE_FILE" "$ARGO_STATE_FILE" /etc/ddr/.argo-token /etc/ddr/.extra-uuids /etc/ddr/.traffic-pair-state /etc/ddr/.desired_state /etc/ddr/.traffic-block-state 2>/dev/null || true; path_tree_has_mountpoint /etc/ddr/standalone-links.d && die 'Refusing to delete /etc/ddr/standalone-links.d: mountpoint present in its tree.'; rm -rf -- /etc/ddr/standalone-links.d || die 'Failed to delete /etc/ddr/standalone-links.d.'
    # L-07: the same runtime-state sweep as do_cleanup (shared helper):
    # runner, .applied records, pre-block snapshots, rollover marker,
    # autorecover marker, Argo logs.
    remove_ddr_runtime_state_files
    local _vg_reg_failed=0
    # R39-M1: a failed registry wipe used to be swallowed (|| true)
    # and the reset still committed + printed vg_done. Track it and
    # report the reset incomplete instead of full success.
    users_registries_wipe || { msg "${YELLOW}[!] $(tprintf cu_users_note '/etc/ddr/users.d')${NC}"; _vg_reg_failed=1; }
    abox_zram_teardown || die 'zram teardown failed; aborting environment reset.'
    # Wallos is a standalone addon, not a protocol/core: environment
    # resets and protocol removal never tear it down, and its
    # fail2ban files stay with it. Only the deep uninstall tiers
    # (do_cleanup) remove Wallos.
    msg "${YELLOW}[!] $(tr_msg vg_wallos_kept)${NC}"
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        if systemctl list-unit-files fail2ban.service >/dev/null 2>&1 && systemctl cat fail2ban.service >/dev/null 2>&1; then
            systemctl try-restart fail2ban >/dev/null 2>&1 || msg "${YELLOW}[!] $(tr_msg cl_f2b_restart_reset)${NC}"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || die "$(tr_msg cl_reload_reset)"
    elif [[ "${INIT_SYS:-}" == openrc ]] && [[ -x /etc/init.d/fail2ban ]]; then
        { rc-service fail2ban status >/dev/null 2>&1 && rc-service fail2ban restart >/dev/null 2>&1 9>&- 10>&-; } || msg "${YELLOW}[!] $(tr_msg cl_f2b_restart_reset)${NC}"
    fi
    commit_deployment_transaction
    remove_abox_swap || msg "${YELLOW}[!] $(tr_msg cl_swap_keep)${NC}"
    if (( _vg_reg_failed == 1 )); then
        msg "${YELLOW}[!] Environment reset finished with user registry cleanup incomplete; credentials may remain on disk.${NC}"
        pause_return
        return 1
    fi
    msg "${GREEN}$(tr_msg vg_done)${NC}"
    pause_return
}

restore_vps_tune() {
    local quiet="${1:-0}" dir="$ABOX_DIR/tune-backup" line key value path failed=0 _live
    local bbr_module_file='/etc/modules-load.d/A-Box-bbr.conf'
    [[ -d "$dir" ]] || { [[ "$quiet" == 1 ]] || msg "${YELLOW}[!] $(tr_msg restore_vps_tune_no_snapshot)${NC}"; return 1; }
    path_tree_has_mountpoint "$dir" && { [[ "$quiet" == 1 ]] || msg "${RED}[!] $(tr_msg restore_vps_tune_mountpoint_refused)${NC}"; return 1; }
    path_parent_chain_safe /etc/sysctl.d/99-A-Box-tune.conf || return 1
    path_parent_chain_safe /etc/security/limits.d/A-Box.conf || return 1
    path_parent_chain_safe "$bbr_module_file" || return 1
    [[ ! -L /etc/sysctl.d && (! -e /etc/sysctl.d || -d /etc/sysctl.d) ]] || return 1
    [[ ! -L /etc/security/limits.d && (! -e /etc/security/limits.d || -d /etc/security/limits.d) ]] || return 1
    [[ ! -L /etc/modules-load.d && (! -e /etc/modules-load.d || -d /etc/modules-load.d) ]] || return 1
    for path in /etc/sysctl.d/99-A-Box-tune.conf /etc/security/limits.d/A-Box.conf "$bbr_module_file"; do
        [[ ! -e "$path" && ! -L "$path" ]] || auxiliary_path_is_abox_managed "$path" || return 1
    done
    if [[ -f "$dir/sysctl.original" ]]; then
        while IFS='=' read -r key value; do
            [[ -n "$key" ]] || continue
            # N-02 (M-32 follow-up): skip keys already at the
            # snapshot value. A key that cannot be read is skipped
            # explicitly -- never probe-write an empty value into
            # a key we could not read. A failed probe write is
            # retried with the snapshot value itself: if that
            # applies, the failure was transient and the restore
            # succeeded; if it also fails, the key is read-only
            # here, so skip it without failing the restore or
            # leaving the snapshot behind.
            _live=$(sysctl -n "$key" 2>/dev/null) || continue
            [[ "$_live" == "$value" ]] && continue
            if sysctl -w "$key=$_live" >/dev/null 2>&1; then
                sysctl -w "$key=$value" >/dev/null 2>&1 || failed=1
            elif sysctl -w "$key=$value" >/dev/null 2>&1; then
                # Probe write failed but the snapshot value applied:
                # transient probe failure; the restore succeeded.
                :
            else
                # Both writes failed: treat as read-only here and skip
                # without failing the restore or keeping the snapshot.
                :
            fi
        done < "$dir/sysctl.original"
    fi
    if [[ -f "$dir/sysctl.conf" ]]; then install -d -m 755 /etc/sysctl.d || failed=1; cp -a "$dir/sysctl.conf" /etc/sysctl.d/99-A-Box-tune.conf || failed=1; else rm -f /etc/sysctl.d/99-A-Box-tune.conf || failed=1; fi
    if [[ -f "$dir/limits.conf" ]]; then install -d -m 755 /etc/security/limits.d || failed=1; cp -a "$dir/limits.conf" /etc/security/limits.d/A-Box.conf || failed=1; else rm -f /etc/security/limits.d/A-Box.conf || failed=1; fi
    if [[ -f "$dir/bbr-modules.conf" ]]; then
        install -d -m 755 /etc/modules-load.d || failed=1
        cp -a "$dir/bbr-modules.conf" "$bbr_module_file" || failed=1
    else
        rm -f -- "$bbr_module_file" || failed=1
    fi
    # No sysctl --system here: it would reload the restored disk file
    # over the runtime snapshot replayed above, clobbering pre-tune
    # runtime values that only ever lived in memory. The disk files are
    # restored for future boots; the replayed values are final.
    (( failed == 0 )) || return 1
    path_tree_has_mountpoint "$dir" && return 1
    rm -rf -- "$dir" || return 1
    [[ "$quiet" == 1 ]] || msg "${GREEN}$(tr_msg restore_vps_tune_restored)${NC}"
}

# Desired sysctl tune set, one "key value" per line. BBR/FQ keys are included
# only when the running kernel actually offers BBR.
_tune_desired_sysctl() {
    local available
    printf '%s\n' \
        'fs.file-max 1048576' \
        'fs.inotify.max_user_instances 8192' \
        'net.ipv4.tcp_syncookies 1' \
        'net.ipv4.tcp_fin_timeout 30' \
        'net.ipv4.tcp_max_syn_backlog 8192' \
        'net.ipv4.tcp_fastopen 3' \
        'net.ipv4.tcp_mtu_probing 1' \
        'net.ipv4.tcp_notsent_lowat 16384' \
        'net.core.netdev_max_backlog 250000' \
        'net.core.somaxconn 32768' \
        'net.core.rmem_max 16777216' \
        'net.core.wmem_max 16777216' \
        'net.ipv4.tcp_rmem 4096 87380 16777216' \
        'net.ipv4.tcp_wmem 4096 65536 16777216' \
        'net.ipv4.tcp_keepalive_time 600' \
        'net.ipv4.tcp_slow_start_after_idle 0' \
        'net.ipv4.ip_local_port_range 10240 65535'
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available"; then
        printf '%s\n' 'net.core.default_qdisc fq' 'net.ipv4.tcp_congestion_control bbr'
    fi
}

# Prints one line per tune item that is missing or drifted from the desired
# state (sysctl live values, limits file, BBR persistence). Empty output means
# the VPS is fully tuned.
_tune_missing_items() {
    local key want got missing_list='' available
    while read -r key want; do
        [[ -n "$key" ]] || continue
        sysctl -n "$key" >/dev/null 2>&1 || continue
        got=$(sysctl -n "$key" 2>/dev/null | tr -s ' \t' ' ')
        [[ "$got" == "$want" ]] || missing_list+="$(tprintf _tune_missing_items_sysctl_detail "${key}" "${got:-$(tr_msg _tune_missing_items_empty)}" "$want")"$'\n'
    done < <(_tune_desired_sysctl)
    if ! grep -q '^# Managed by A-Box' /etc/security/limits.d/A-Box.conf 2>/dev/null \
        || ! grep -qx '\* soft nofile 1048576' /etc/security/limits.d/A-Box.conf 2>/dev/null \
        || ! grep -qx '\* hard nofile 1048576' /etc/security/limits.d/A-Box.conf 2>/dev/null \
        || ! grep -qx 'root soft nofile 1048576' /etc/security/limits.d/A-Box.conf 2>/dev/null \
        || ! grep -qx 'root hard nofile 1048576' /etc/security/limits.d/A-Box.conf 2>/dev/null; then
        missing_list+="$(tr_msg _tune_missing_items_limits_nofile)"$'\n'
    fi
    # The persist file itself: a runtime value can be right while the
    # file that reapplies it at boot is missing or drifted.
    if [[ ! -f /etc/sysctl.d/99-A-Box-tune.conf ]]; then
        missing_list+="$(tr_msg _tune_missing_items_persist_missing)"$'\n'
    else
        while read -r key want; do
            [[ -n "$key" ]] || continue
            sysctl -n "$key" >/dev/null 2>&1 || continue
            # Exact, last-assignment-wins match: a commented line, a
            # longer value, or an earlier line overridden later must not pass.
            awk -v k="$key" -v w="$want" '{l=$0; sub(/^[ \t]+/,"",l); if(l==""||substr(l,1,1)=="#")next; e=index(l,"="); if(!e)next; kk=substr(l,1,e-1); vv=substr(l,e+1); sub(/[ \t]+$/,"",kk); sub(/^[ \t]+/,"",kk); sub(/^[ \t]+/,"",vv); sub(/[ \t]+$/,"",vv); sub(/[ \t]+#.*$/,"",vv); gsub(/[ \t]+/, " ", vv); if(kk==k){v=vv; f=1} } END{exit !(f&&v==w)}' /etc/sysctl.d/99-A-Box-tune.conf 2>/dev/null \
                || missing_list+="$(tprintf _tune_missing_items_persist_mismatch "${key}" "$want")"$'\n'
        done < <(_tune_desired_sysctl)
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available" && modprobe tcp_bbr >/dev/null 2>&1; then
        grep -qx 'tcp_bbr' /etc/modules-load.d/A-Box-bbr.conf 2>/dev/null \
            || missing_list+="$(tr_msg _tune_missing_items_bbr_autoload)"$'\n'
    fi
    printf '%s' "$missing_list"
}

# BUG-28: hoisted from apply_vps_tune(). $3 = destination file.
__abox_add_sysctl() {
    # Unsupported key: explicit skip-success, not an error.
    sysctl -n "$1" >/dev/null 2>&1 || return 0
    # Append error (e.g. /tmp full) must propagate to the caller.
    printf '%s = %s\n' "$1" "$2" >> "$3" || return 1
}
apply_vps_tune() {
    local dir="$ABOX_DIR/tune-backup" tmp key value available bbr_loaded=0
    local bbr_module_file='/etc/modules-load.d/A-Box-bbr.conf'
    local missing snapshot_exists=0 snapshot_tmp
    assert_abox_auxiliary_safe /etc/security/limits.d/A-Box.conf || die "$(tprintf ax_refuse "/etc/security/limits.d/A-Box.conf")"
    assert_abox_auxiliary_safe /etc/sysctl.d/99-A-Box-tune.conf || die "$(tprintf ax_refuse "/etc/sysctl.d/99-A-Box-tune.conf")"
    assert_abox_auxiliary_safe "$bbr_module_file" || die "$(tprintf ax_refuse "$bbr_module_file")"
    # Snapshot state validation stays strict: a half-written snapshot is unsafe.
    if [[ -f "$dir/.captured" ]]; then
        snapshot_exists=1
    elif [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" ]] || die "$(tr_msg tn_backup_unsafe)"
        [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || { msg "${RED}[!] $(tr_msg apply_vps_tune_snapshot_incomplete)${NC}"; return 1; }
    fi
    # R39-M3: load tcp_bbr BEFORE the idempotency check. The desired
    # set and the missing-items check only see BBR once the module is
    # loaded, so an available-but-unloaded module made a fully tuned
    # (non-BBR) system report "already applied" and skip BBR forever.
    # A failed load keeps the existing skip behaviour (the desired set
    # simply omits BBR, as before).
    modprobe tcp_bbr >/dev/null 2>&1 || true
    # Idempotent re-run: inspect live state first, never error out on re-apply.
    missing=$(_tune_missing_items)
    if [[ -z "$missing" ]]; then
        msg "${GREEN}$(tr_msg apply_vps_tune_already_applied)${NC}"
        return 0
    fi
    msg "${YELLOW}$(tr_msg apply_vps_tune_missing_items_found)${NC}"
    msg "$missing"
    if (( snapshot_exists == 1 )); then
        msg "${YELLOW}[!] $(tr_msg apply_vps_tune_keep_snapshot_fill_missing)${NC}"
    else
        snapshot_tmp=$(mktemp -d "$ABOX_DIR/.tune-backup-new.XXXXXX") || die "$(tr_msg tn_backup_tmp)"
        if [[ -f /etc/sysctl.d/99-A-Box-tune.conf ]] && ! cp -a /etc/sysctl.d/99-A-Box-tune.conf "$snapshot_tmp/sysctl.conf"; then
            rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_sysctl_backup)"
        fi
        if [[ -f /etc/security/limits.d/A-Box.conf ]] && ! cp -a /etc/security/limits.d/A-Box.conf "$snapshot_tmp/limits.conf"; then
            rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_limits_backup)"
        fi
        if [[ -f "$bbr_module_file" ]] && ! cp -a "$bbr_module_file" "$snapshot_tmp/bbr-modules.conf"; then
            rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_bbr_backup)"
        fi
        : > "$snapshot_tmp/sysctl.original" || { rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_snapshot_create)"; }
        for key in fs.file-max fs.inotify.max_user_instances net.ipv4.tcp_syncookies net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.core.netdev_max_backlog net.core.somaxconn net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle net.ipv4.ip_local_port_range net.core.default_qdisc net.ipv4.tcp_congestion_control; do
            value=$(sysctl -n "$key" 2>/dev/null) || continue
            printf '%s=%s\n' "$key" "$value" >> "$snapshot_tmp/sysctl.original" || { rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_snapshot_write)"; }
        done
        touch "$snapshot_tmp/.captured" || { rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_snapshot_mark)"; }
        if [[ -d "$dir" ]]; then
            rmdir -- "$dir" || { rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_replace_dir)"; }
        fi
        mv -f -- "$snapshot_tmp" "$dir" || { rm -rf -- "$snapshot_tmp"; die "$(tr_msg tn_commit)"; }
    fi
    write_file_atomically_from_stdin /etc/security/limits.d/A-Box.conf 644 <<'EOF_LIMITS' || { restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_limits_write_failed)"; }
# Managed by A-Box
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF_LIMITS
    tmp=$(umask 077; mktemp /tmp/A-Box-sysctl.XXXXXX) || { restore_vps_tune 1 || true; die "$(tr_msg tn_tmp)"; }
    printf '%s\n' '# Managed by A-Box' > "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg tn_tmp_init)"; }
    __abox_add_sysctl fs.file-max 1048576 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl fs.inotify.max_user_instances 8192 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_syncookies 1 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_fin_timeout 30 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_max_syn_backlog 8192 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_fastopen 3 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_mtu_probing 1 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_notsent_lowat 16384 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.core.netdev_max_backlog 250000 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.core.somaxconn 32768 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.core.rmem_max 16777216 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.core.wmem_max 16777216 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_rmem '4096 87380 16777216' "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_wmem '4096 65536 16777216' "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_keepalive_time 600 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.tcp_slow_start_after_idle 0 "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    __abox_add_sysctl net.ipv4.ip_local_port_range '10240 65535' "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
    if modprobe tcp_bbr >/dev/null 2>&1; then bbr_loaded=1; fi
    # M-32(2): fq is a requested qdisc (net.core.default_qdisc fq
    # below), so its module must be loaded the same way tcp_bbr is.
    modprobe sch_fq >/dev/null 2>&1 || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available"; then
        __abox_add_sysctl net.core.default_qdisc fq "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
        __abox_add_sysctl net.ipv4.tcp_congestion_control bbr "$tmp" || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_sysctl_write_failed)"; }
        if (( bbr_loaded == 1 )); then
            path_parent_chain_safe "$bbr_module_file" || { rm -f -- "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg tn_bbr_chain)"; }
            [[ ! -L /etc/modules-load.d && (! -e /etc/modules-load.d || -d /etc/modules-load.d) ]] || { rm -f -- "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg tn_moddir_unsafe)"; }
            install -d -m 755 /etc/modules-load.d || { rm -f -- "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg tn_moddir_create)"; }
            write_file_atomically_from_stdin "$bbr_module_file" 644 <<'EOF_BBR' || { rm -f -- "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg apply_vps_tune_bbr_module_write_failed)"; }
# Managed by A-Box
tcp_bbr
EOF_BBR
        fi
    else
        msg "${YELLOW}[!] $(tr_msg apply_vps_tune_no_bbr_skip)${NC}"
    fi
    install_file_atomically "$tmp" /etc/sysctl.d/99-A-Box-tune.conf 600 || { rm -f "$tmp"; restore_vps_tune 1 || true; die "$(tr_msg tn_atomic_write)"; }
    rm -f "$tmp"
    if ! sysctl -p /etc/sysctl.d/99-A-Box-tune.conf >/dev/null 2>&1; then
        # M-32(2): report what is still missing before rolling
        # back, so the failure is diagnosable instead of silent.
        missing=$(_tune_missing_items)
        if [[ -n "$missing" ]]; then
            msg "${YELLOW}[!] $(tr_msg apply_vps_tune_items_still_inactive)${NC}"
            msg "$missing"
        fi
        restore_vps_tune 1; die "$(tr_msg tn_apply)"
    fi
    missing=$(_tune_missing_items)
    if [[ -z "$missing" ]]; then
        msg "${GREEN}$(tr_msg apply_vps_tune_missing_filled)${NC}"
    else
        msg "${YELLOW}[!] $(tr_msg apply_vps_tune_items_still_inactive)${NC}"
        msg "$missing"
    fi
}



# Operations helpers
abox_is_fast() {
    [[ "${ABOX_FAST:-}" =~ ^(1|true|yes|YES|True)$ ]] && return 0
    [[ -r "$FAST_MODE_FILE" && -f "$FAST_MODE_FILE" && ! -L "$FAST_MODE_FILE" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$FAST_MODE_FILE" 2>/dev/null || true)" == '1' ]]
}

read_fast_mode_label() {
    # Menu target look (2026-10-19): mode word follows UI language (display only).
    local _m=strict
    abox_is_fast && _m=fast
    case "${ABOX_LANG:-zh}" in
        en)    printf '%s\n' "$_m" ;;
        ru)    [[ "$_m" == fast ]] && printf 'быстрый\n' || printf 'строгий\n' ;;
        fa)    [[ "$_m" == fast ]] && printf 'سریع\n' || printf 'سخت‌گیرانه\n' ;;
        zh-tw) [[ "$_m" == fast ]] && printf '快速\n' || printf '嚴格\n' ;;
        ja)    [[ "$_m" == fast ]] && printf '高速\n' || printf '厳格\n' ;;
        *)     [[ "$_m" == fast ]] && printf '快速\n' || printf '严格\n' ;;
    esac
}

save_fast_mode() {
    local v="${1:-0}"
    [[ "$v" =~ ^(0|1)$ ]] || die "$(tr_msg fm_bad)"
    ensure_abox_dir_owned "$ABOX_DIR" || die "$(tr_msg state_dir_prep)"
    write_file_atomically_from_stdin "$FAST_MODE_FILE" 600 <<< "$v" || die "$(tr_msg fm_write)"
}

confirm_soft() {
    # Non-critical confirm: auto-yes in fast mode. Never use for uninstall/digest/destructive wipe.
    local prompt="$1" answer
    if abox_is_fast; then
        msg "${YELLOW}[fast] ${prompt} → Y${NC}"
        return 0
    fi
    read -r -p "$prompt" answer || return 1
    is_yes "$answer"
}


show_core_pin_docs() {
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg show_core_pin_docs_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    # C2 (latest-first): all three cores default to auto-stable; the
    # fallback constants are the explicit pinned-policy targets only.
    msg "Update policy per core: Xray ${YELLOW}auto-stable${NC}; sing-box ${YELLOW}auto-stable${NC}; Hysteria ${YELLOW}auto-stable${NC}. Fallback versions (explicit pinned policy only): Xray ${ABOX_XRAY_DEFAULT_VERSION}, sing-box ${ABOX_SINGBOX_DEFAULT_VERSION}, Hysteria ${ABOX_HYSTERIA_DEFAULT_VERSION}."
    msg "Auto-stable selects the latest official stable tag at install/update time (draft/prerelease excluded); config, client compatibility, and post-upgrade health gates still apply."
    msg "Disaster recovery: an upstream failure first tries the exact-tag versioned mirror, then the current verified mirror version from ${YELLOW}${ABOX_CORE_MIRROR_RELEASE}${NC}; explicit/pinned targets never switch versions."
    msg "CORE-VERSIONS is accepted only when its digest matches SHA256SUMS; superseded versioned assets are pruned after the replacement assets and metadata are verified (no multi-version rollback)."
    msg "Explicit version overrides: ABOX_XRAY_VERSION / ABOX_SINGBOX_VERSION / ABOX_HYSTERIA_APP_VERSION; failed explicit pins do not silently switch versions."
    msg "Every candidate must pass tag/URL, SHA-256, archive structure and actual binary-version checks."
    msg "Mode: ${YELLOW}$(read_fast_mode_label)${NC} (ABOX_FAST=1 or ${FAST_MODE_FILE})"
    pause_return
}

probe_core_sources_banner() {
    local pref='latest-stable-first' api_code mirror_code base repo="${1:-}" ref="${2:-}" api_url
    [[ "${ABOX_TRY_LATEST_CORE_STABLE:-0}" == '1' ]] && pref='latest-official-stable-first'
    base="${ABOX_CORE_MIRROR_BASE:-$ABOX_CORE_MIRROR_BASE_DEFAULT}"
    # B-C2: probe the exact release tag the fetch is about to pull, not
    # the release list: a 200 on the list endpoint never proved the tag
    # fetch would succeed (list 200 + tag fetch 403 was observed). With
    # no repo/ref given, keep the legacy list probe for compatibility.
    if [[ -n "$repo" && -n "$ref" ]]; then
        api_url="https://api.github.com/repos/${repo}/releases/tags/${ref//\//%2F}"
    else
        api_url='https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100'
    fi
    # SYD-B E13: the release-API probe was single-shot, so one
    # transient blip reported the API dead. Retry it (max 3);
    # the mirror probe stays single-shot by design.
    api_code='000'
    local _try=0
    while (( _try < 3 )); do
        api_code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "$api_url" 2>/dev/null || printf '000')
        [[ "$api_code" == 200 ]] && break
        _try=$((_try + 1))
        (( _try < 3 )) && sleep 1
    done
    mirror_code=$(curl -sSL --proto =https --proto-redir =https -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "${base%/}/SHA256SUMS" 2>/dev/null || printf '000')
    case "$api_code" in 200) api_code='available (HTTP 200)' ;; *) api_code="unavailable (HTTP ${api_code:-000})" ;; esac
    case "$mirror_code" in 200) mirror_code='available (HTTP 200)' ;; *) mirror_code="unavailable (HTTP ${mirror_code:-000})" ;; esac
    if [[ -n "$repo" && -n "$ref" ]]; then
        msg "${CYAN}[download sources] order=${pref} → current mirror recovery; release tag ${repo}@${ref}: ${api_code}; recovery SHA256SUMS: ${mirror_code}; custom base=${ABOX_CORE_MIRROR_BASE:-<unset>}${NC}"
    else
        msg "${CYAN}[download sources] order=${pref} → current mirror recovery; release API: ${api_code}; recovery SHA256SUMS: ${mirror_code}; custom base=${ABOX_CORE_MIRROR_BASE:-<unset>}${NC}"
    fi
}

# Pinned-utility mirror fetch (cloudflared / wgcf). The caller's in-script
# SHA-256 pin remains the verification anchor for BOTH sources: mirror bytes
# are used only when they match the pin exactly, so this adds an
# availability fallback without any new trust assumption.
fetch_util_mirror_asset() {
    local leaf="${1:-}" dest="${2:-}" base="${ABOX_CORE_MIRROR_BASE:-$ABOX_CORE_MIRROR_BASE_DEFAULT}"
    [[ -n "$leaf" && -n "$dest" && -n "$base" ]] || return 1
    case "$base" in https://*) ;; *) return 1 ;; esac
    msg "${YELLOW} -> A-Box recovery mirror: ${base%/}/${leaf}${NC}"
    curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 10 -m 180 "${base%/}/${leaf}" -o "$dest" 2>/dev/null
}

fetch_abox_mirror_asset() {
    local repo="${1:-}" output_file="${2:-}" dest_file="${3:-}" requested_version="${4:-}" prefer_versioned="${5:-0}"
    local mirror_base mirror_url mirror_sum expect_sum got_sum asset_leaf tmp_file _core_ver_rc _mirror_max_time=30 _mirror_retry=2
    mirror_base="${ABOX_CORE_MIRROR_BASE:-$ABOX_CORE_MIRROR_BASE_DEFAULT}"
    [[ -n "$mirror_base" ]] || return 1
    # Integrity depends on TLS: a plaintext HTTP mirror lets a network attacker
    # serve a backdoored binary with a matching forged SHA256SUMS. Refuse.
    case "$mirror_base" in
        https://*) ;;
        *) msg "${RED}[!] ABOX_CORE_MIRROR_BASE must use https://; refusing plaintext mirror (integrity bypass).${NC}" >&2; return 1 ;;
    esac
    if [[ -z "$requested_version" ]]; then requested_version=$(core_release_mirror_version "$repo") || return 1; fi
    core_release_ref_valid "$repo" "$requested_version" || return 1
    asset_leaf=$(core_mirror_asset_leaf "$repo" "$output_file" "$requested_version" "$prefer_versioned") || return 1
    mirror_url="${mirror_base%/}/${asset_leaf}"; mirror_sum="${mirror_base%/}/SHA256SUMS"
    msg "${YELLOW} -> A-Box recovery mirror: ${mirror_url} [${requested_version}]${NC}"
    # S32 (GPT-11 mirror part): fetch + verify SHA256SUMS BEFORE downloading
    # the asset, so a bad asset is rejected by digest before any full parse.
    # The expected digest is extracted here for the initial leaf; if the
    # F-02 fallback below switches the leaf, it is re-extracted for the
    # new leaf (the sums file stays on disk until the leaf is final).
    # N-16 fix: use fixed-string matching, not regex. The old $2~(f"$") treated
    # dots in filenames as regex wildcards.
    # DS-High-02: verify SHA256SUMS signature before trusting it (F-05 trust root).
    # U68: the old code derived the .sig path from a mktemp file name
    # ("${sum_file}.sig") without creating it: the name is observable
    # in /tmp and the second curl follows a planted symlink. Download
    # both files into a fresh mktemp -d (random, 0700) instead, so no
    # attacker-plantable path exists, and refuse symlinks before use.
    local sum_dir sum_file sum_sig
    sum_dir=$(mktemp -d) || return 1
    sum_file="$sum_dir/SHA256SUMS"; sum_sig="$sum_dir/SHA256SUMS.sig"
    # B-C2: total fetch budget applies to the mirror leg too. The curl
    # line below stays byte-identical: a self-test pins it verbatim for
    # the follow-redirects property. The budget is enforced by refusing
    # to start when spent, plus a `timeout` cap when one is available
    # (the plain line is the fallback where timeout is absent).
    _mirror_max_time=30
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_abox_mirror_asset $repo $requested_version (SHA256SUMS)" || { rm -rf -- "$sum_dir"; return 1; }
        _mirror_max_time=$(abox_fetch_curl_max_time 30) || { rm -rf -- "$sum_dir"; return 1; }
    fi
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]] && command -v timeout >/dev/null 2>&1; then
        if ! timeout "$_mirror_max_time" curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 8 -m 30 "$mirror_sum" -o "$sum_file" 2>/dev/null; then
            rm -rf -- "$sum_dir"; return 1
        fi
    elif ! curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 8 -m 30 "$mirror_sum" -o "$sum_file" 2>/dev/null; then
        rm -rf -- "$sum_dir"; return 1
    fi
    # 05g-M4: the .sig download below used to have no deadline check and
    # no `timeout` wrapper (fixed -m 30, 2 retries, up to ~94s past the
    # budget), while the SHA256SUMS download just above and the asset
    # downloads below both re-check the deadline. Mirror the SHA256SUMS
    # pattern: refuse to start when the budget is spent, else cap with
    # `timeout` when available (plain curl stays the fallback where
    # timeout is absent). A failed .sig download stays tolerated
    # (`|| true`): the sig gate below still fails closed when the
    # signature is missing or bad.
    _mirror_max_time=30
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_abox_mirror_asset $repo $requested_version (SHA256SUMS.sig)" || { rm -rf -- "$sum_dir"; return 1; }
        _mirror_max_time=$(abox_fetch_curl_max_time 30) || { rm -rf -- "$sum_dir"; return 1; }
    fi
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]] && command -v timeout >/dev/null 2>&1; then
        timeout "$_mirror_max_time" curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 8 -m 30 "${mirror_sum}.sig" -o "$sum_sig" 2>/dev/null || true
    else
        curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 8 -m 30 "${mirror_sum}.sig" -o "$sum_sig" 2>/dev/null || true
    fi
    if [[ -L "$sum_file" || -L "$sum_sig" ]]; then
        rm -rf -- "$sum_dir"; return 1
    fi
    # DS-High-02: abox_verify_sig_gate 本身就是 (c) 语义 (默认 fail-closed,
    # ABOX_SIGNING_ENFORCE=0 为显式逃生门)。无需新造变量。
    if ! abox_verify_sig_gate "$sum_file" "$sum_sig" "recovery mirror SHA256SUMS"; then
        rm -rf -- "$sum_dir"; return 1
    fi
    expect_sum=$(awk -v f="$asset_leaf" '{ g=$2; sub(/^\*/, "", g); n=length(f); if (g==f || g==("./" f) || (substr(g, length(g)-n+1)==f && (length(g)==n || substr(g, length(g)-n, 1)=="/"))) {print $1; exit} }' "$sum_file") || expect_sum=''
    tmp_file=$(mktemp "${dest_file}.download.XXXXXX") || { rm -rf -- "$sum_dir"; return 1; }
    # F-02 fix: if fixed-name asset 404s, fall back to versioned filename.
    _mirror_max_time=180
    _mirror_retry=2
    if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
        abox_fetch_deadline_check "fetch_abox_mirror_asset $repo $requested_version (asset)" || { rm -f -- "$tmp_file"; rm -rf -- "$sum_dir"; return 1; }
        _mirror_max_time=$(abox_fetch_curl_max_time 180) || { rm -f -- "$tmp_file"; rm -rf -- "$sum_dir"; return 1; }
        abox_fetch_deadline_remaining >/dev/null 2>&1 && _mirror_retry=0
    fi
    if ! curl -fLsS --proto =https --proto-redir =https --retry "$_mirror_retry" --retry-delay 2 --connect-timeout 10 -m "$_mirror_max_time" "$mirror_url" -o "$tmp_file"; then
        rm -f -- "$tmp_file"
        if [[ "$prefer_versioned" != '1' ]]; then
            local versioned_leaf
            versioned_leaf=$(core_mirror_asset_leaf "$repo" "$output_file" "$requested_version" 1) || { rm -rf -- "$sum_dir"; return 1; }
            if [[ "$versioned_leaf" != "$asset_leaf" ]]; then
                msg "${YELLOW} -> Fixed-name asset not found, trying versioned: ${versioned_leaf}${NC}" >&2
                asset_leaf="$versioned_leaf"
                mirror_url="${mirror_base%/}/${asset_leaf}"
                # S32: leaf switched -- re-extract the expected digest for it.
                expect_sum=$(awk -v f="$asset_leaf" '{ g=$2; sub(/^\*/, "", g); n=length(f); if (g==f || g==("./" f) || (substr(g, length(g)-n+1)==f && (length(g)==n || substr(g, length(g)-n, 1)=="/"))) {print $1; exit} }' "$sum_file") || expect_sum=''
                tmp_file=$(mktemp "${dest_file}.download.XXXXXX") || { rm -rf -- "$sum_dir"; return 1; }
                _mirror_max_time=180
                _mirror_retry=2
                if [[ -n "${ABOX_FETCH_DEADLINE_EPOCH:-}" ]]; then
                    abox_fetch_deadline_check "fetch_abox_mirror_asset $repo $requested_version (asset versioned)" || { rm -f -- "$tmp_file"; rm -rf -- "$sum_dir"; return 1; }
                    _mirror_max_time=$(abox_fetch_curl_max_time 180) || { rm -f -- "$tmp_file"; rm -rf -- "$sum_dir"; return 1; }
                    abox_fetch_deadline_remaining >/dev/null 2>&1 && _mirror_retry=0
                fi
                if ! curl -fLsS --proto =https --proto-redir =https --retry "$_mirror_retry" --retry-delay 2 --connect-timeout 10 -m "$_mirror_max_time" "$mirror_url" -o "$tmp_file"; then rm -f -- "$tmp_file"; rm -rf -- "$sum_dir"; return 1; fi
            else
                rm -rf -- "$sum_dir"; return 1
            fi
        else
            rm -rf -- "$sum_dir"; return 1
        fi
    fi
    rm -rf -- "$sum_dir"
    got_sum=$(sha256sum < "$tmp_file" 2>/dev/null | awk '{print $1}') || got_sum=''
    if [[ -z "$expect_sum" || ! "$expect_sum" =~ ^[A-Fa-f0-9]{64}$ || "${got_sum,,}" != "${expect_sum,,}" ]]; then msg "${YELLOW}[!] recovery mirror SHA-256 mismatch or missing SHA256SUMS${NC}" >&2; rm -f -- "$tmp_file"; return 1; fi
    # S32: digest first, format second (mirrors the upstream reorder).
    if ! validate_downloaded_asset "$output_file" "$tmp_file"; then rm -f -- "$tmp_file"; return 1; fi
    validate_core_asset_binary_version "$output_file" "$tmp_file" "$requested_version"; _core_ver_rc=$?
    if (( _core_ver_rc == 2 )); then msg "${YELLOW}[!] recovery binary cannot be executed (not a version mismatch); check the workdir mount options (/tmp noexec is common) or TMPDIR${NC}" >&2; rm -f -- "$tmp_file"; return 1; fi
    if (( _core_ver_rc != 0 )); then msg "${YELLOW}[!] recovery binary version does not match requested version ${requested_version}${NC}" >&2; rm -f -- "$tmp_file"; return 1; fi
    if [[ -d "$dest_file" ]]; then msg "${YELLOW}[!] recovery destination is a directory, refusing to move asset into it${NC}" >&2; rm -f -- "$tmp_file"; return 1; fi
    mv -fT -- "$tmp_file" "$dest_file" || { rm -f -- "$tmp_file"; return 1; }
    msg "${GREEN}   recovery SHA-256 and actual binary version verified: ${requested_version}${NC}"
    return 0
}
