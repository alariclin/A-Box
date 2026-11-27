# ABOX-MODULE-BEGIN 12-wallos Wallos
#   Source: install.sh lines 57377-64539 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
wallos_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7) printf 'armv7\n' ;;
        *) return 1 ;;
    esac
}

wallos_port_free() {
    local port="$1" out='' _dp=''
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # P3-9: fail closed when ss is missing (was fail-open returning "free").
    command -v ss >/dev/null 2>&1 || return 1
    # Fail closed when ss itself errors, too: an empty result caused
    # by a failed probe is not proof that the port is free.
    out=$(ss -H -ltn "sport = :$port" 2>/dev/null) || return 1
    [[ -z "$out" ]] || return 1
    # R6C14-02: with userland-proxy off, a Docker NAT publication
    # creates no host listening socket, so ss alone misjudges the
    # port as free and the later publish collides. Also consult
    # Docker's published-port allocations; fail closed if the
    # query itself fails. Only running containers hold ports, so
    # plain `docker ps` (no -a) is the right source.
    if command -v docker >/dev/null 2>&1; then
        _dp=$(docker ps --format '{{.Ports}}' 2>/dev/null) || return 1
        # R13-05: parse published ports strictly. Only the HOST side
        # counts, as a single port or a lo-hi range; only a TCP
        # publication blocks a TCP port (UDP/SCTP do not). A malformed
        # published entry, or one without a protocol, fails closed
        # (busy). awk exits 0 = free, non-zero = busy/probe failure.
        if ! printf '%s\n' "$_dp" | awk -v want="$port" '
        BEGIN { busy = 0; bad = 0 }
        {
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                entry = parts[i]
                sub(/^[ \t]+/, "", entry)
                sub(/[ \t]+$/, "", entry)
                if (entry == "") continue
                if (index(entry, "->") == 0) continue
                arrow = index(entry, "->")
                host = substr(entry, 1, arrow - 1)
                rest = substr(entry, arrow + 2)
                slash = 0
                for (k = length(rest); k >= 1; k--) {
                    if (substr(rest, k, 1) == "/") { slash = k; break }
                }
                if (slash == 0) { bad = 1; continue }
                proto = substr(rest, slash + 1)
                if (proto != "tcp") {
                    if (proto == "udp" || proto == "sctp") continue
                    bad = 1; continue
                }
                colon = 0
                for (k = length(host); k >= 1; k--) {
                    if (substr(host, k, 1) == ":") { colon = k; break }
                }
                hpspec = (colon == 0) ? host : substr(host, colon + 1)
                if (hpspec ~ /^[0-9]+$/) {
                    if (hpspec + 0 == want + 0) busy = 1
                } else if (hpspec ~ /^[0-9]+-[0-9]+$/) {
                    dash = index(hpspec, "-")
                    lo = substr(hpspec, 1, dash - 1) + 0
                    hi = substr(hpspec, dash + 1) + 0
                    if (lo > hi) { bad = 1; continue }
                    if (want + 0 >= lo && want + 0 <= hi) busy = 1
                } else {
                    bad = 1
                }
            }
        }
        END { if (busy || bad) exit 1; exit 0 }
'; then
            return 1
        fi
    fi
    return 0
}

wallos_print_host_info() {
    local os_name='unknown' os_version='unknown' arch mem_gb disk_gb cores ipv4 ipv6
    if [[ -r /etc/os-release ]]; then
        os_name=$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
        [[ -n "$os_name" ]] || os_name=$(awk -F= '$1=="ID" {print $2; exit}' /etc/os-release)
        os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
    fi
    arch=$(uname -m)
    mem_gb=$(awk '/MemTotal:/ {printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || printf 'unknown')
    disk_gb=$(df -Pk "$WALLOS_DIR" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1048576}')
    [[ -n "$disk_gb" ]] || disk_gb=$(df -Pk /opt 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1048576}')
    [[ -n "$disk_gb" ]] || disk_gb='unknown'
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')
    ipv4=$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    ipv6=$(curl -6fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
    local _na; _na=$(tr_msg wl_hi_na)
    msg "${CYAN}$(tr_msg wl_hi_title)${NC}"
    msg "$(tprintf wl_hi_info "$os_name" "$os_version" "$arch" "$cores" "$mem_gb" "$disk_gb")"
    msg "$(tprintf wl_hi_ip "${ipv4:-$_na}" "${ipv6:-$_na}")"
}

wallos_install_runtime() {
    local os_id='' answer prompt runtime_error
    [[ -r /etc/os-release ]] || return 1
    os_id=$(awk -F= '$1=="ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
    if command -v docker >/dev/null 2>&1; then
        # If the CLI is already installed, only try to start the existing daemon.
        # Do not install a second Docker package/engine over an unknown installation.
        if docker info >/dev/null 2>&1; then return 0; fi
        case "$os_id" in
            alpine)
                command -v rc-service >/dev/null 2>&1 && rc-service docker start >/dev/null 2>&1 9>&- 10>&- || true
                ;;
            *)
                if systemd_available; then
                    systemctl enable --now docker >/dev/null 2>&1 || true
                elif command -v rc-service >/dev/null 2>&1; then
                    rc-service docker start >/dev/null 2>&1 9>&- 10>&- || true
                elif command -v service >/dev/null 2>&1; then
                    service docker start >/dev/null 2>&1 9>&- 10>&- || true
                fi
                ;;
        esac
        if docker info >/dev/null 2>&1; then return 0; fi
        runtime_error=$(tr_msg wl_rt_daemon_down)
        msg "${RED}${runtime_error}${NC}"
        return 1
    fi
    prompt=$(tr_msg wl_rt_install_prompt)
    # R27-F14-04: a failed read (e.g. `y` then EOF with no newline) must
    # not authorize the install; cf. the conflict prompt below, which
    # already checks the read status.
    read -r -p "$prompt" answer || return 1
    is_yes "$answer" || return 1
    case "$os_id" in
        debian|ubuntu|linuxmint|kali)
            apt-get update && apt-get install -y docker.io ca-certificates curl jq || return 1
            # R27-F14-03: systemctl existing does not mean systemd is
            # PID 1 (it can coexist with sysvinit/OpenRC); judge with
            # systemd_available like the already-installed branch above.
            # If systemctl then fails, fall back to service instead of
            # reporting the install failed while the daemon is startable.
            if systemd_available; then
                systemctl enable --now docker || {
                    command -v service >/dev/null 2>&1 || return 1
                    service docker start 9>&- 10>&- || return 1
                }
            elif command -v service >/dev/null 2>&1; then service docker start 9>&- 10>&- || return 1
            else return 1; fi
            ;;
        alpine)
            apk add --no-cache docker curl jq ca-certificates || return 1
            # R7C14-01: boot-enable failure must fail the install, not swallow
            # (else Docker, and hence Wallos, stays dead after reboot).
            rc-update add docker default >/dev/null 2>&1 || return 1
            rc-service docker start 9>&- 10>&- || return 1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            local -a docker_conflicts=()
            local pkg conflict_prompt
            command -v dnf >/dev/null 2>&1 || return 1
            command -v rpm >/dev/null 2>&1 || return 1
            # M-23(2): Rocky/Alma/Fedora Minimal pre-install curl-minimal;
            # forcing the full curl RPM conflicts with it. Only ask for
            # curl when no curl binary exists (mirrors the
            # init_system_environment avoidance), and pass
            # --allowerasing so a residual swap cannot fail the install.
            local -a _wallos_dnf_pkgs=(dnf-plugins-core ca-certificates jq)
            command -v curl >/dev/null 2>&1 || _wallos_dnf_pkgs+=(curl)
            dnf -y install --allowerasing "${_wallos_dnf_pkgs[@]}" || return 1
            case "$os_id" in
                fedora)
                    if [[ "$(dnf --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)" == '5' ]]; then
                        dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo || return 1
                    else
                        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || return 1
                    fi ;;
                rhel) dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo || return 1 ;;
                centos|rocky|almalinux) dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || return 1 ;;
            esac
            for pkg in docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine docker.io containerd podman podman-docker runc; do
                rpm -q "$pkg" >/dev/null 2>&1 && docker_conflicts+=("$pkg")
            done
            if (("${#docker_conflicts[@]}" > 0)); then
                msg "${YELLOW}$(tprintf wl_rt_conflicts "${docker_conflicts[*]}")${NC}"
                conflict_prompt=$(tr_msg wl_rt_conflict_prompt)
                read -r -p "$conflict_prompt" answer || return 1
                is_yes "$answer" || { msg "${YELLOW}$(tr_msg wl_rt_declined)${NC}"; return 1; }
                dnf -y remove "${docker_conflicts[@]}" || return 1
            fi
            dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin || {
                msg "${RED}$(tr_msg wl_rt_ce_fail)${NC}"
                return 1
            }
            # R27-F14-03 (sibling, same function): same systemd check and
            # service fallback as the Debian branch above. RHEL-family
            # hosts are systemd-native in practice, but the fallback
            # costs nothing when systemctl is present yet failing.
            if systemd_available; then
                systemctl enable --now docker || {
                    command -v service >/dev/null 2>&1 || return 1
                    service docker start 9>&- 10>&- || return 1
                }
            elif command -v service >/dev/null 2>&1; then service docker start 9>&- 10>&- || return 1
            else return 1; fi
            ;;
        *)
            msg "${RED}$(tprintf wl_rt_unsupported "$os_id")${NC}"
            return 1
            ;;
    esac
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

wallos_version_is_older() {
    local older="${1#v}" newer="${2#v}" i a b
    local -a old_parts=() new_parts=()
    [[ "$older" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$newer" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
    IFS=. read -r -a old_parts <<< "$older"
    IFS=. read -r -a new_parts <<< "$newer"
    # No arithmetic on the values: Bash integers wrap past 2^63-1 and
    # invert the comparison. Strip leading zeros, compare by decimal
    # length (longer is larger), then lexicographically on equal
    # length (digit strings, so lexicographic == numeric). LC_ALL=C
    # pins the lexicographic step to byte order regardless of the
    # caller's locale.
    local LC_ALL=C
    for i in 0 1 2; do
        a=${old_parts[$i]}; b=${new_parts[$i]}
        while [[ "$a" == 0?* ]]; do a=${a#0}; done
        while [[ "$b" == 0?* ]]; do b=${b#0}; done
        (( ${#a} < ${#b} )) && return 0
        (( ${#a} > ${#b} )) && return 1
        [[ "$a" < "$b" ]] && return 0
        [[ "$a" > "$b" ]] && return 1
    done
    return 1
}

wallos_candidate_version_allowed() {
    local candidate="${1#v}" installed_image installed_version rc inspect_err
    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "${ABOX_WALLOS_ALLOW_DOWNGRADE:-0}" == 1 ]] && return 0
    inspect_err=$(docker container inspect wallos 2>&1 >/dev/null) || {
        [[ "${inspect_err,,}" == *'no such container'* ]] && return 0
        msg "${RED}$(tprintf wl_cv_inspect_fail "$inspect_err")${NC}"
        return 1
    }
    installed_image=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null || true)
    installed_version="${installed_image##*:}"
    # U115: containers created by digest have no parseable version in
    # Config.Image; fall back to the recorded state VERSION, as the
    # rollback path already does.
    if [[ ! "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        installed_version=$(wallos_state_value VERSION 2>/dev/null || true)
    fi
    [[ "$installed_version" == "$candidate" ]] && return 0
    if [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        wallos_version_is_older "$candidate" "$installed_version"
        rc=$?
        if (( rc == 0 )); then
            msg "${RED}$(tprintf wl_cv_downgrade "$candidate" "$installed_version")${NC}"
            return 1
        fi
        (( rc == 1 )) && return 0
    fi
    msg "${RED}$(tprintf wl_cv_compare "$candidate" "$installed_image")${NC}"
    return 1
}

# N-11: Fetch the retained version list from the A-Box wallos-mirror.
# Outputs one version per line, newest first. Empty on failure; returns 1
# when the list cannot be fetched, so callers can tell 'unavailable' from 'empty'.
wallos_mirror_version_list() {
    local work versions_url
    work=$(umask 077; mktemp -d /tmp/A-Box-Wallos-ver.XXXXXX 2>/dev/null) || return 1
    versions_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/wallos-versions.txt"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 20 "$versions_url" -o "$work/wallos-versions.txt" 2>/dev/null; then
        rm -rf -- "$work"
        return 1
    fi
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' "$work/wallos-versions.txt" 2>/dev/null || true
    rm -rf -- "$work"
}

# N-11: Prune local bellamy/wallos images to keep only the newest 2
# (current + previous verified-good). Enforces the 500MB local cache cap
# by count (2 images). (N-06: removed stale "reports total size" claim.)
# Args: $1 = image tag to always keep (current), $2 = image tag to keep (previous, may be empty).
# R14C14-02: record every wallos image A-Box itself pulls or loads.
# wallos_prune_local_images deletes only recorded images silently;
# an unrecorded same-name image (e.g. the user's own build) is never
# deleted without an explicit confirmation.
wallos_record_image() {
    local img="${1:-}"
    img="${img#docker.io/}"
    [[ "$img" =~ ^bellamy/wallos:[A-Za-z0-9._-]+$ || "$img" =~ ^bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]] || return 0
    # R7-F14-4: bind the record to the image ID, not the tag alone. A tag
    # is mutable: an admin rebuild under the same tag must not inherit
    # silent-prune authorization from an earlier A-Box image. If the ID
    # cannot be determined or is malformed, do not record at all (and do
    # not fall back to a tag-only record); the image then stays
    # unrecorded and pruning asks instead of deleting silently.
    local _img_id=''
    _img_id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
    [[ "$_img_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 0
    # Atomic replace (private temp + chmod + mv): keep only the newest
    # binding per reference, so a stale ID never authorizes a later prune.
    local _rec_file="${ABOX_DIR}/wallos-images.txt" _tmp='' _grep_rc=0
    _tmp=$(mktemp "${ABOX_DIR}/.wallos-images.XXXXXX" 2>/dev/null) || return 0
    if [[ -f "$_rec_file" ]]; then
        grep -Fv "$img|" "$_rec_file" > "$_tmp" 2>/dev/null || _grep_rc=$?
        (( _grep_rc == 0 || _grep_rc == 1 )) || { rm -f -- "$_tmp"; return 0; }
    fi
    printf '%s|%s\n' "$img" "$_img_id" >> "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 0; }
    chmod 600 "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 0; }
    mv -f -- "$_tmp" "$_rec_file" 2>/dev/null || { rm -f -- "$_tmp"; return 0; }
    return 0
}

wallos_prune_local_images() {
    local keep1="${1:-}" keep2="${2:-}" img tag
    # D-05: normalize docker.io/ prefix (docker inspect .Config.Image may include
    # it, while `docker images --format` never does) so keep-list comparison works.
    keep1="${keep1#docker.io/}"
    keep2="${keep2#docker.io/}"
    # U115: keeps may now be digest refs or image IDs (not tags). Resolve
    # each keep to its image ID so the tag list below can honor it.
    local -a keep_ids=()
    local _k _kid
    for _k in "$keep1" "$keep2"; do
        [[ -n "$_k" ]] || continue
        _kid=$(docker image inspect -f '{{.Id}}' "$_k" 2>/dev/null || true)
        if [[ -z "$_kid" ]]; then
            # A digest/ID-form keep that fails to resolve must fail
            # closed: silently dropping it would delete the kept image.
            # A tag-form keep that fails to resolve is simply not
            # present locally, so pruning proceeds as before.
            case "$_k" in
                *@*|sha256:*) return 1 ;;
            esac
            continue
        fi
        keep_ids+=("$_kid")
    done
    local -a all_images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] || continue
        # Only manage bellamy/wallos images.
        [[ "$img" =~ ^bellamy/wallos:[A-Za-z0-9._-]+$ ]] || continue
        all_images+=("$img")
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^bellamy/wallos:' || true)
    # R53-P1: a digest-pulled image has no tag (`<none>`), so the
    # tag-only enumeration above never sees it. Enumerate recorded
    # digest refs too; the delete branch below works unchanged on a
    # digest ref (live inspect, `ref|id` record binding, delete by
    # verified ID). A digest image already covered by a tag entry is
    # safe: the keep-by-ID check skips it when kept, and the
    # unidentifiable-image skip catches it when already deleted.
    local _ref _rid
    if [[ -f "${ABOX_DIR}/wallos-images.txt" ]]; then
        while IFS='|' read -r _ref _rid || [[ -n "$_ref" ]]; do
            [[ "$_ref" =~ ^bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]] || continue
            all_images+=("$_ref")
        done < "${ABOX_DIR}/wallos-images.txt"
    fi
    local removed=0
    for img in "${all_images[@]}"; do
        local _img_id='' _keep_by_id=0 _confirmed_id=''
        _img_id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
        if [[ -n "$_img_id" ]]; then
            for _kid in "${keep_ids[@]}"; do
                [[ "$_img_id" == "$_kid" ]] && _keep_by_id=1
            done
        fi
        if [[ "$img" != "$keep1" && "$img" != "$keep2" && "$_keep_by_id" != 1 ]]; then
            # Keep at most 2: remove anything beyond keep1/keep2.
            # Count how many we would keep; if already 2 kept, remove the rest.
            # R14C14-02: only A-Box-recorded images may be pruned
            # silently. An unrecorded same-name image may be the
            # user's own build: ask on a terminal, else skip.
            # R7-F14-4: silent pruning is authorized only by an exact
            # tag|ID binding for the CURRENT image. A tag-only record
            # (legacy) or a record for a different ID (rebuilt under
            # the same tag) does not authorize deletion.
            # R11E-R7-4/R7-5: an image whose ID cannot be resolved to a
            # well-formed sha256 ID is unidentifiable: skip it without
            # prompting. A confirm here could never authorize the delete
            # below (the recheck could not verify it), and prompting
            # would only mislead. Kept images never reach this gate:
            # it sits inside the delete branch, after the keep check.
            if [[ ! "$_img_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                msg "${YELLOW}$(tprintf wl_pr_skip_unrecorded "$img")${NC}"
                continue
            fi
            if [[ -z "$_img_id" ]] || ! grep -Fqx "$img|$_img_id" "${ABOX_DIR}/wallos-images.txt" 2>/dev/null; then
                if [[ -t 0 ]]; then
                    if confirm_yes_no "$(tprintf wl_pr_confirm_unrecorded "$img")"; then
                        # R11E-R7-4: record the confirmation against the
                        # CURRENT image ID. The recheck below accepts
                        # this ID as well as a live tag|ID record, so a
                        # confirmed delete of an unrecorded image is
                        # reachable again; the ID must still match the
                        # rechecked ID exactly.
                        _confirmed_id="$_img_id"
                    else
                        continue
                    fi
                else
                    msg "${YELLOW}$(tprintf wl_pr_skip_unrecorded "$img")${NC}"
                    continue
                fi
            fi
            # Re-check immediately before the delete: a rebuild between
            # the scan and the delete must not slip through.
            local _img_id_now=''
            _img_id_now=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
            if [[ "$_img_id_now" != "$_img_id" ]]; then
                msg "${YELLOW}$(tprintf wl_pr_skip_unrecorded "$img")${NC}"
                continue
            fi
            # R11E-R7-4: the recheck accepts the confirmed ID as well as
            # a live record binding. Before this fix the record test
            # below was false for unrecorded images by definition, so a
            # confirmed delete could never reach the delete. The
            # confirmed ID must be non-empty and equal to the rechecked
            # ID; a revoked binding with no confirmation still skips.
            if ! grep -Fqx "$img|$_img_id_now" "${ABOX_DIR}/wallos-images.txt" 2>/dev/null && [[ -z "$_confirmed_id" || "$_confirmed_id" != "$_img_id_now" ]]; then
                msg "${YELLOW}$(tprintf wl_pr_skip_unrecorded "$img")${NC}"
                continue
            fi
            # R11E-R7-5: delete by the verified immutable ID, never by
            # the mutable tag: a retarget between the recheck and the
            # delete must not remove the wrong image. (A multi-tag
            # image may fail ID deletion without -f; that is accepted
            # and reported, never forced.)
            if docker rmi "$_img_id_now" >/dev/null 2>&1; then
                removed=$((removed + 1))
            else
                # D-09: was silently swallowed by `|| true`.
                msg "${YELLOW}$(tprintf wl_pr_rm_fail "$img")${NC}"
            fi
        fi
    done
    # D-08: removed dead 500MB-cap computation (total was calculated but never
    # used for enforcement or warning). Pruning is count-based (keep 2).
    if (( removed > 0 )); then
        local _keeps="${keep1:-none}"
        [[ -n "${keep2:-}" ]] && _keeps="$_keeps, $keep2"
        msg "${CYAN}$(tprintf wl_pr_done "$removed" "$_keeps")${NC}"
    fi
    return 0
}

# N-11: Roll back Wallos to a specific version.
# Args: $1 = version tag (e.g. v2.5.1). Fetches the versioned image from the
# mirror if not present locally, restores the latest backup, recreates the container.
# D-02: best-effort recovery if rollback fails after the old container was removed.
# Tries to bring Wallos back up with the previous image so the service is not
# left completely down. Data on disk is already the restored backup.
_wallos_rollback_recover_impl() {
    local prev_image="$1" port="$2" tz="$3" bind_address="$4" _pre_version="${5:-}" _pre_mode="${6:-}" _pre_pubport="${7:-}" _pre_cfhost="${8:-}"
    local -a _pub_args=()
    # X-03: use explicit bind:port form like the install path (L15630).
    # The old 0.0.0.0 -> "-p port:80" special case also published IPv6 [::]:port.
    [[ -n "$bind_address" ]] && _pub_args=(-p "${bind_address}:${port}:80/tcp")
    [[ -n "$prev_image" ]] || return 1
    # R13-09: the previous version must be known before the
    # container is touched; an unknown version must fail, never
    # silently keep the backup's VERSION/IMAGE as the recovered state.
    [[ "$_pre_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    # X-01: remove any existing 'wallos' container first. Callers may invoke
    # this after a failed docker run or unhealthy new container is still present;
    # without this, the second 'docker run --name wallos' always hits a name conflict.
    # H7rest ($9 = the pre-rollback container ID, already gone): the
    # container to clear is the failed new one, so remove by ID only;
    # a foreign holder refuses instead of being removed by name.
    _wallos_rm_named_id "${9:-}" || return 1
    docker run -d --name wallos --label com.alariclin.abox.managed=true \
        "${WALLOS_DOCKER_HARDENING[@]}" \
        -v "$WALLOS_DIR/db:/var/www/html/db" \
        -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
        -e TZ="$tz" "${_pub_args[@]}" --restart unless-stopped "$prev_image" >/dev/null 2>&1 || return 1
    # U118: the caller reports "recovered" only if this returns 0, so verify
    # the old image and the old database are actually usable, and the
    # container answers healthily, instead of trusting a started container.
    # R14-F14-02: verify the captured image is the exact immutable ID,
    # not merely that some image answers to the name: after a retag, a
    # tag lookup could confirm a different image.
    [[ "$(docker image inspect -f '{{.Id}}' "$prev_image" 2>/dev/null || true)" == "$prev_image" ]] || return 1
    [[ -s "$WALLOS_DIR/db/wallos.db" && ! -L "$WALLOS_DIR/db/wallos.db" ]] || return 1
    # U217 (same rule as the restore/install paths): an omitted -p
    # means the recovered container is unpublished, so the health gate
    # must not demand a publication it will never have.
    local _health_mode=published
    (( ${#_pub_args[@]} == 0 )) && _health_mode=unpublished
    wallos_wait_healthy "$port" "$_health_mode" || return 1
    # R13-09: commit the recovered deployment's state from the
    # captured pre-rollback metadata (restore mode: a captured
    # empty field stays absent instead of inheriting the backup's
    # value). A failed write is reported distinctly: the container
    # is healthy, but the recovery is incomplete.
    if ! wallos_write_state "$prev_image" "$port" "$tz" "$bind_address" "$_pre_mode" "$_pre_pubport" "$_pre_cfhost" "$_pre_version" 1; then
        msg "${RED}Previous Wallos container is healthy, but state recovery failed; VERSION/IMAGE were not restored to the pre-rollback values.${NC}"
        return 1
    fi
}

# M-NEW-02: failure wrapper (same reason as
# wallos_recover_interrupted_upgrade above): a failed rollback
# leaves the Wallos jail pointing at a removed overlay; drop it when
# provably dangling so `fail2ban-client -t` passes again. The
# rollback's own return status is preserved unchanged. On success the
# jail is refreshed to the recovered container's log path (R54-M3):
# the caller's success-path refresh is skipped when recovery is
# reached from a failure branch, and the old jail would otherwise
# guard a deleted overlay forever.
_wallos_rollback_recover() {
    _wallos_rollback_recover_impl "$@"
    local _rc=$?
    if (( _rc != 0 )); then
        wallos_fail2ban_drop_stale_jail >/dev/null 2>&1 || true
    else
        # R54-M3: recovery recreated the container, so the jail still
        # points at the removed overlay; refresh it to the recovered
        # container's log path (best-effort, like the rollback success
        # path). If the refresh fails, drop the provably stale jail
        # rather than leaving a dead jail behind.
        wallos_bruteforce_protection "$2" "$4" 2>/dev/null || wallos_fail2ban_drop_stale_jail >/dev/null 2>&1 || true
    fi
    return "$_rc"
}

# Normalize a Wallos image digest to canonical form
# bellamy/wallos@sha256:<hex>. The mirror manifest carries bare digests
# (sha256:<hex>) since PR #161; older manifests and docker RepoDigests
# use bellamy/wallos@sha256:<hex>, optionally docker.io/-prefixed.
# Anything else is rejected (fail-closed). Hex is lowercased so the
# canonical form compares equal across spellings.
wallos_normalize_digest() {
    local d="${1:-}" hex
    d="${d//[[:space:]]/}"
    d="${d#docker.io/}"
    case "$d" in
        bellamy/wallos@sha256:*) hex="${d#bellamy/wallos@sha256:}" ;;
        sha256:*) hex="${d#sha256:}" ;;
        *) return 1 ;;
    esac
    [[ "$hex" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf 'bellamy/wallos@sha256:%s' "${hex,,}"
}

# R13-08: check whether the local image with the captured ID
# carries the expected registry manifest digest in its RepoDigests.
# The image is inspected by its captured ID, never by a mutable tag:
# the tag could be retargeted between the .Id capture and this check.
# An empty RepoDigests, a malformed expected digest, or an inspection
# failure all fail (the caller falls back to the verified-fetch path).
# Note: `docker load` does not reliably populate RepoDigests, so this
# is a conservative optimization only; offline reuse of mirror-loaded
# images still needs a trusted manifest-to-image-ID binding.
wallos_local_image_has_digest() {
    local image_ref="$1" expected="$2" _norm_expected _digests _d _norm
    [[ -n "$image_ref" && -n "$expected" ]] || return 1
    _norm_expected=$(wallos_normalize_digest "$expected") || return 1
    _digests=$(docker image inspect -f '{{join .RepoDigests "\n"}}' "$image_ref" 2>/dev/null) || return 1
    while IFS= read -r _d || [[ -n "$_d" ]]; do
        [[ -n "$_d" ]] || continue
        _norm=$(wallos_normalize_digest "$_d") || continue
        [[ "$_norm" == "$_norm_expected" ]] && return 0
    done <<< "$_digests"
    return 1
}

# R54-M1: store-aware binding for a loaded image ID. Under the Docker
# (graphdriver) store the daemon .Id is the config digest; under the
# containerd store it is the manifest digest. The adopted ID must equal
# one of them; anything else means the tag was retargeted between load
# and inspect (or the load produced a different image), and the load
# must be refused. A missing/malformed manifest digest simply disables
# the containerd branch (the Docker-store branch still applies).
wallos_loaded_id_matches_archive() {
    local _daemon_id="${1:-}" _config_id="${2:-}" _manifest_digest="${3:-}" _hex _mhex
    [[ "$_daemon_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "$_config_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    _hex="${_daemon_id#sha256:}"
    [[ "$_hex" == "${_config_id#sha256:}" ]] && return 0
    _mhex="${_manifest_digest#docker.io/}"
    _mhex="${_mhex#bellamy/wallos@}"
    _mhex="${_mhex#sha256:}"
    _mhex="${_mhex,,}"
    [[ "$_mhex" =~ ^[0-9a-f]{64}$ && "$_hex" == "$_mhex" ]] && return 0
    return 1
}

# Validate `docker load` output for a Wallos archive. Accepts exactly one
# loaded image, either tag-form ("Loaded image: bellamy/wallos:<tag>",
# what `docker save` of a tag produces) or digest-form ("Loaded image ID:
# sha256:<hex>", what `docker save` of a digest reference produces, as
# the mirror archives have been since PR #161). A digest-form load
# carries no tag, so the image is re-tagged by ID for the downstream
# `docker image inspect bellamy/wallos:<tag>` checks.
# Args: $1 = load output, $2 = expected tag (e.g. 5.10.4).
# R10-F14-3: image ID from an authenticated archive. The config
# blob's SHA256 IS the image ID; reading it from the tarball (not from
# a post-load tag query) closes the load-to-run TOCTOU.
wallos_image_id_from_archive() {
    local archive="$1"
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    python3 -I - "$archive" <<'PY_WALLOS_ARCHIVE_ID'
import sys, tarfile, hashlib, json
import resource
# S7 (R51-M1 follow-up): same bound as S6 -- tarfile reads PAX/GNU
# longname extension headers whole into memory before yielding the next
# member (getmember/getnames scan them), so no member/size cap can bound
# them. A 512 MiB RLIMIT_AS fails closed (MemoryError -> non-zero exit)
# on a crafted giant header; see the R51-M1 note in
# validate_legacy_backup_archive for the measured headroom.
try:
    _hard = resource.getrlimit(resource.RLIMIT_AS)[1]
    if _hard != resource.RLIM_INFINITY:
        _cap = min(512 * 1024 * 1024, _hard)
    else:
        _cap = 512 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (_cap, _hard))
except Exception:
    sys.exit(1)
archive = sys.argv[1]
try:
    tf = tarfile.open(archive, 'r:gz')
except Exception:
    sys.exit(1)
with tf:
    try:
        manifest_member = tf.getmember('manifest.json')
    except KeyError:
        sys.exit(1)
    if not manifest_member.isfile():
        sys.exit(1)
    names = tf.getnames()
    if names.count('manifest.json') != 1:
        sys.exit(1)
    try:
        raw = tf.extractfile(manifest_member).read()
        entries = json.loads(raw)
    except Exception:
        sys.exit(1)
    if not isinstance(entries, list) or len(entries) != 1:
        sys.exit(1)
    entry = entries[0]
    if not isinstance(entry, dict):
        sys.exit(1)
    config_name = entry.get('Config')
    if not isinstance(config_name, str) or not config_name:
        sys.exit(1)
    if names.count(config_name) != 1:
        sys.exit(1)
    try:
        member = tf.getmember(config_name)
    except KeyError:
        sys.exit(1)
    if not member.isfile():
        sys.exit(1)
    f = tf.extractfile(member)
    if f is None:
        sys.exit(1)
    h = hashlib.sha256()
    while True:
        chunk = f.read(65536)
        if not chunk:
            break
        h.update(chunk)
    sys.stdout.write('sha256:' + h.hexdigest() + '\n')
PY_WALLOS_ARCHIVE_ID
}

wallos_check_loaded_image() {
    local load_out="${1:-}" image_tag="${2:-}" loaded_id
    # R13-07: exactly one recognized load-result record, total.
    # Each branch below counts only its own kind, so a mixed
    # tag+ID output used to pass either branch; the total count
    # closes that bypass.
    [[ "$(grep -Ec '^Loaded image( ID)?:' <<< "$load_out")" == 1 ]] || return 1
    if [[ "$(grep -c '^Loaded image:' <<< "$load_out")" == 1 ]] &&
       grep -Fqx "Loaded image: bellamy/wallos:$image_tag" <<< "$load_out"; then
        return 0
    fi
    if [[ "$(grep -c '^Loaded image ID:' <<< "$load_out")" == 1 ]]; then
        loaded_id=$(grep '^Loaded image ID:' <<< "$load_out" | awk '{print $NF}')
        [[ "$loaded_id" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || return 1
        docker tag "$loaded_id" "bellamy/wallos:$image_tag" >/dev/null 2>&1 || return 1
        docker image inspect "bellamy/wallos:$image_tag" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

# Fetch the versioned Wallos manifest (signed-SHA256SUMS verified,
# tag matched, mirroring _wallos_pull_versioned_image) and print
# image_digest.<arch>. Used to authenticate a local image before
# rollback trusts it. Returns 1 when unavailable.
wallos_versioned_image_digest() {
    local tag="$1" arch work ver_manifest manifest_url sum_url
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    arch=$(wallos_detect_arch) || return 1
    work=$(umask 077; mktemp -d /tmp/A-Box-Wallos-digest.XXXXXX) || return 1
    ver_manifest="wallos-manifest-${tag}.txt"
    manifest_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/$ver_manifest"
    sum_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/SHA256SUMS"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$manifest_url" -o "$work/$ver_manifest" ||
       ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$sum_url" -o "$work/SHA256SUMS"; then
        rm -rf -- "$work"; return 1
    fi
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "${sum_url}.sig" -o "$work/SHA256SUMS.sig" 2>/dev/null || true
    if ! abox_verify_sig_gate "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "Wallos versioned SHA256SUMS"; then
        rm -rf -- "$work"; return 1
    fi
    local manifest_expected manifest_actual mtag digest
    manifest_expected=$(awk -v f="$ver_manifest" '$2==f || $2==("*" f) {print $1; exit}' "$work/SHA256SUMS" 2>/dev/null || true)
    manifest_actual=$(sha256sum "$work/$ver_manifest" 2>/dev/null | awk '{print $1}' || true)
    if [[ ! "$manifest_expected" =~ ^[A-Fa-f0-9]{64}$ || "${manifest_expected,,}" != "${manifest_actual,,}" ]]; then
        rm -rf -- "$work"; return 1
    fi
    mtag=$(awk -F= '$1=="tag" {print $2; exit}' "$work/$ver_manifest" 2>/dev/null || true)
    [[ "$mtag" == "$tag" ]] || { rm -rf -- "$work"; return 1; }
    digest=$(awk -F= -v a="$arch" '$1==("image_digest." a) {print $2; exit}' "$work/$ver_manifest" 2>/dev/null || true)
    rm -rf -- "$work"
    [[ -n "$digest" ]] || return 1
    printf '%s' "$digest"
}

wallos_rollback_to_version() {
    local target_tag="$1" arch image_tag port tz bind_address backup=''
    [[ "$target_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { msg "${RED}$(tprintf wl_rb_invalid_ver "$target_tag")${NC}"; return 1; }
    # R11C14-01: refuse a foreign container squatting on the
    # 'wallos' name before any destructive step.
    # R15-F14-03: a failed first inspect is "state unknown", never a
    # skipped gate: only a confirmed-absent container (see
    # _wallos_container_gone) may pass without the label check; any
    # other inspect failure refuses here, before the version/backup
    # gates can pass a never-verified container on to stop/rm.
    local _rb_inspect_err=''
    local _rb_cid=''
    if _rb_inspect_err=$(docker inspect wallos 2>&1 >/dev/null); then
        local _wallos_managed=''
        _wallos_managed=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null || true)
        if [[ "$_wallos_managed" != "true" ]]; then
            msg "${RED}Refusing rollback: existing 'wallos' container is not A-Box-managed (missing com.alariclin.abox.managed label).${NC}"
            return 1
        fi
        # H7rest: pin the container ID next to the label check; all
        # stop/start/rm below address the pinned ID, never the name.
        _rb_cid=$(_wallos_container_id) || {
            msg "${RED}Refusing rollback: cannot determine the 'wallos' container ID; refusing to roll back without a pinned container.${NC}"
            return 1
        }
    elif _wallos_container_gone "$_rb_inspect_err"; then
        : # confirmed absent: nothing to protect; later gates still apply.
    else
        msg "${RED}Refusing rollback: cannot determine the state of the 'wallos' container; refusing to roll back without a verified ownership check.${NC}"
        _wallos_show_docker_err "$_rb_inspect_err"
        return 1
    fi
    # X-04: rollback's purpose IS downgrade; do not reuse the install-path
    # anti-downgrade gate (wallos_candidate_version_allowed) here. Instead
    # require the target to be strictly older than the installed version.
    local _installed_img _installed_ver
    _installed_img=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null || true)
    _installed_img="${_installed_img#docker.io/}"
    _installed_ver="${_installed_img##*:}"
    # U115: containers created by digest have no parseable version in
    # Config.Image; fall back to the recorded state VERSION.
    if [[ ! "$_installed_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _installed_ver=$(wallos_state_value VERSION 2>/dev/null || true)
    fi
    if [[ "$_installed_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        wallos_version_is_older "${target_tag#v}" "$_installed_ver" || {
            msg "${RED}$(tprintf wl_rb_not_older "$target_tag" "$_installed_ver")${NC}"; return 1; }
    else
        msg "${RED}$(tprintf wl_rb_unknown_ver "$_installed_img")${NC}"; return 1
    fi
    image_tag="${target_tag#v}"
    # R13-09: capture the pre-rollback Wallos metadata BEFORE any
    # destructive rollback step, and refuse the rollback when the
    # previous version cannot be established. A rollback that
    # cannot record its own previous version must not start:
    # recovery could otherwise leave the backup's VERSION/IMAGE
    # standing as the recovered state.
    # R10-F14-5: reuse the version established above: explicit
    # container tag first, recorded state VERSION as the U115
    # fallback. The final format check below stays.
    local _pre_rb_version='' _pre_rb_mode='' _pre_rb_pubport='' _pre_rb_cfhost=''
    _pre_rb_version="$_installed_ver"
    if [[ ! "$_pre_rb_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        msg "${RED}Refusing rollback: cannot establish the current Wallos version; refusing to roll back without a known previous version.${NC}"
        return 1
    fi
    _pre_rb_mode=$(wallos_state_value MODE 2>/dev/null || true)
    _pre_rb_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
    _pre_rb_cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
    # L-NEW-07: the U112 backup gate runs HERE, right after the
    # version is established and BEFORE any image fetch: with no
    # usable backup the rollback refuses now instead of after a pull.
    # U112: select the newest backup whose recorded Wallos version is not
    # newer than the rollback target. Each backup's .abox-state carries the
    # IMAGE it was taken under; a backup from a newer Wallos may hold a
    # migrated database the old image cannot load. Backups without a
    # parseable recorded version are skipped, never assumed compatible.
    local _rb_list=() _rb_cand _rb_state _rb_image _rb_ver _rb_skipped=''
    local _target_ver="${target_tag#v}"
    mapfile -t _rb_list < <(ls -t "$WALLOS_DIR"/backups/wallos-*.tar.gz 2>/dev/null || true)
    for _rb_cand in "${_rb_list[@]}"; do
        [[ -f "$_rb_cand" && ! -L "$_rb_cand" ]] || continue
        _rb_state=$(tar -xzOf "$_rb_cand" .abox-state 2>/dev/null | head -c 65537 || true)
        if (( ${#_rb_state} > 65536 )); then
            _rb_skipped+="$_rb_cand(oversized-state) "
            continue
        fi
        # U115: prefer the recorded VERSION (new backups carry a digest IMAGE
        # with no parseable version); fall back to the IMAGE tag for old backups.
        _rb_ver=$(printf '%s\n' "$_rb_state" | awk -F= '$1=="VERSION" {print $2; exit}' 2>/dev/null || true)
        if [[ ! "$_rb_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _rb_image=$(printf '%s\n' "$_rb_state" | awk -F= '$1=="IMAGE" {print $2; exit}' 2>/dev/null || true)
            _rb_image="${_rb_image#docker.io/}"
            _rb_ver="${_rb_image##*:}"
        fi
        if [[ ! "$_rb_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _rb_skipped+="$_rb_cand(unknown) "
            continue
        fi
        if wallos_version_is_older "$_target_ver" "$_rb_ver"; then
            _rb_skipped+="$_rb_cand($_rb_ver) "
            continue
        fi
        backup="$_rb_cand"
        break
    done
    [[ -n "$backup" && -f "$backup" && ! -L "$backup" ]] || { msg "${RED}$(tr_msg wl_rb_no_backup)${NC}"; [[ -n "$_rb_skipped" ]] && msg "${YELLOW}Skipped backups newer than $target_tag or without a recorded version: ${_rb_skipped% }${NC}"; return 1; }
    # R15C14-02: never trust a mutable local tag. Authenticate
    # the local image against the versioned manifest digest; on
    # match run by the immutable digest, else verified pull and
    # run by the freshly loaded image ID.
    local run_image='' _local_id='' _expected_digest=''
    _local_id=$(docker image inspect -f '{{.Id}}' "bellamy/wallos:$image_tag" 2>/dev/null || true)
    _expected_digest=$(wallos_versioned_image_digest "$target_tag" 2>/dev/null || true)
    if [[ "$_local_id" =~ ^sha256:[0-9a-f]{64}$ ]] &&
       wallos_local_image_has_digest "$_local_id" "$_expected_digest"; then
        run_image="$_local_id"
    else
        msg "${YELLOW}$(tprintf wl_rb_fetching "$image_tag")${NC}"
        # Use the versioned mirror path: temporarily override tag selection.
        local _saved_result="${WALLOS_IMAGE_RESULT:-}"
        if ! _wallos_pull_versioned_image "$target_tag"; then
            WALLOS_IMAGE_RESULT="$_saved_result"
            msg "${RED}$(tprintf wl_rb_fetch_fail "$target_tag")${NC}"
            return 1
        fi
        # R11-C (R2-10-1): take the freshly loaded image's daemon
        # store-native ID FIRST, then restore the saved global.
        run_image="${WALLOS_IMAGE_RESULT:-}"
        WALLOS_IMAGE_RESULT="$_saved_result"
        [[ "$run_image" =~ ^sha256:[0-9a-f]{64}$ ]] || { msg "${RED}$(tprintf wl_rb_fetch_fail "$target_tag")${NC}"; return 1; }
    fi
    # Stop and remove current container, restore latest backup, recreate.
    port=$(wallos_state_value PORT 2>/dev/null || true)
    tz=$(wallos_state_value TZ 2>/dev/null || printf 'UTC')
    bind_address=$(wallos_state_value BIND 2>/dev/null || printf '127.0.0.1')
    valid_canonical_port "$port" || { msg "${RED}$(tr_msg wl_rb_bad_port)${NC}"; return 1; }
    # R7-F14-2: pin the backup to a private copy before any validation or
    # restore reads it. The shared backups/ path is writable by root
    # processes outside this function; a swap between the version screen,
    # the pre-validation and the restore would restore a different
    # (newer, incompatible) archive. All later steps consume the pinned
    # copy only, and it is deleted on every exit path (success included).
    local _rb_stage_dir='' _rb_pinned=''
    _rb_stage_dir=$(umask 077; mktemp -d /tmp/A-Box-rollback.XXXXXX) || { msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1; }
    _rb_pinned="$_rb_stage_dir/wallos-rollback.tar.gz"
    cp -- "$backup" "$_rb_pinned" || { rm -rf -- "$_rb_stage_dir"; msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1; }
    chmod 600 "$_rb_pinned" || { rm -rf -- "$_rb_stage_dir"; msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1; }
    # Re-run the version gate on the pinned copy (canonical copy of the
    # U112/U115 screening logic above): the pinned archive must carry
    # the same recorded-version decision as the screened candidate.
    local _rb_pinned_state='' _rb_pinned_image='' _rb_pinned_ver=''
    _rb_pinned_state=$(tar -xzOf "$_rb_pinned" .abox-state 2>/dev/null | head -c 65537 || true)
    if (( ${#_rb_pinned_state} > 65536 )); then
        rm -rf -- "$_rb_stage_dir"; msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1
    fi
    _rb_pinned_ver=$(printf '%s\n' "$_rb_pinned_state" | awk -F= '$1=="VERSION" {print $2; exit}' 2>/dev/null || true)
    if [[ ! "$_rb_pinned_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _rb_pinned_image=$(printf '%s\n' "$_rb_pinned_state" | awk -F= '$1=="IMAGE" {print $2; exit}' 2>/dev/null || true)
        _rb_pinned_image="${_rb_pinned_image#docker.io/}"
        _rb_pinned_ver="${_rb_pinned_image##*:}"
    fi
    if [[ ! "$_rb_pinned_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || wallos_version_is_older "$_target_ver" "$_rb_pinned_ver"; then
        rm -rf -- "$_rb_stage_dir"; msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1
    fi
    # U118: validate the backup fully BEFORE touching the running container;
    # a bad backup must abort here, not after the service is already removed.
    wallos_validate_backup "$_rb_pinned" || { rm -rf -- "$_rb_stage_dir"; msg "${RED}$(tr_msg wl_rb_bad_backup)${NC}"; return 1; }
    # H7rest: stop the pinned container; an empty pin means the
    # container was confirmed absent above, so there is nothing to stop.
    if [[ -n "$_rb_cid" ]]; then _wallos_stop_id "$_rb_cid" || true; fi
    # N-11: capture the pre-rollback image BEFORE removing the container,
    # so the prune step can retain 2 images (new current + previous). (NEW-1)
    local prev_image
    prev_image=$(docker inspect -f '{{.Image}}' wallos 2>/dev/null || true)
    # Normalize docker.io/ prefix (matches _installed_img and old_image handling).
    prev_image="${prev_image#docker.io/}"
    # R14-F14-02: the captured reference is the immutable image ID
    # (.Image), not the mutable creation-time reference (.Config.Image):
    # after a retag, recovery must restart the exact image, never a
    # different image that later took over the tag. Refuse before
    # docker rm if the ID is not a well-formed digest.
    # R27-F14-01: the container was already stopped above; if the
    # identity gate refuses, restart it (A-04 precedent at the rm branch
    # below) instead of leaving a running service in Exited state.
    [[ "$prev_image" =~ ^sha256:[0-9a-f]{64}$ ]] || { if [[ -n "$_rb_cid" ]]; then _wallos_start_id "$_rb_cid" || true; fi; rm -rf -- "$_rb_stage_dir"; msg "${RED}Cannot determine the pre-rollback image ID; refusing rollback.${NC}"; return 1; }
    # H7rest: remove the pinned container; an empty pin means the
    # container was confirmed absent above, so there is nothing to remove.
    if [[ -n "$_rb_cid" ]]; then
        _wallos_rm_id "$_rb_cid" || {
            # A-04: rm failed after stop succeeded; try to restart the original
            # container instead of leaving it in Exited state.
            _wallos_start_id "$_rb_cid" || true
            msg "${RED}$(tr_msg wl_rb_rm_fail)${NC}"
            rm -rf -- "$_rb_stage_dir"
            return 1
        }
    fi
    wallos_restore_backup "$_rb_pinned" || { msg "${RED}$(tr_msg wl_rb_restore_fail)${NC}"
        _wallos_rollback_recover "$prev_image" "$port" "$tz" "$bind_address" "$_pre_rb_version" "$_pre_rb_mode" "$_pre_rb_pubport" "$_pre_rb_cfhost" "$_rb_cid" && \
            msg "${YELLOW}$(tr_msg wl_rb_recovered)${NC}"
        rm -rf -- "$_rb_stage_dir"
        return 1; }
    # The pinned copy has been consumed by the restore; delete it now so
    # no later exit path can mistake it for a live backup.
    rm -rf -- "$_rb_stage_dir"
    _rb_stage_dir=''

    local -a _pub_args=()
    # X-03: explicit bind:port form (matches install path); bare "-p port:80"
    # would also publish IPv6 [::]:port when bind is 0.0.0.0.
    [[ -n "$bind_address" ]] && _pub_args=(-p "${bind_address}:${port}:80/tcp")
    # Empty bind_address: omit -p entirely (no port publication, fail-closed).
    docker run -d --name wallos --label com.alariclin.abox.managed=true \
        "${WALLOS_DOCKER_HARDENING[@]}" \
        -v "$WALLOS_DIR/db:/var/www/html/db" \
        -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
        -e TZ="$tz" "${_pub_args[@]}" --restart unless-stopped "$run_image" >/dev/null || {
        msg "${RED}$(tprintf wl_rb_start_fail "$target_tag")${NC}"
        _wallos_rollback_recover "$prev_image" "$port" "$tz" "$bind_address" "$_pre_rb_version" "$_pre_rb_mode" "$_pre_rb_pubport" "$_pre_rb_cfhost" "$_rb_cid" && \
            msg "${YELLOW}$(tr_msg wl_rb_recovered)${NC}"
        return 1; }
    # U217: an omitted -p means the rolled-back container is
    # unpublished; do not demand a publication it will never have.
    local _health_mode=published
    (( ${#_pub_args[@]} == 0 )) && _health_mode=unpublished
    wallos_wait_healthy "$port" "$_health_mode" || { msg "${RED}$(tprintf wl_rb_unhealthy "$target_tag")${NC}"
        _wallos_rollback_recover "$prev_image" "$port" "$tz" "$bind_address" "$_pre_rb_version" "$_pre_rb_mode" "$_pre_rb_pubport" "$_pre_rb_cfhost" "$_rb_cid" && \
            msg "${YELLOW}$(tr_msg wl_rb_recovered)${NC}"
        return 1; }
    wallos_write_state "$run_image" "$port" "$tz" "$bind_address" "$_pre_rb_mode" "$_pre_rb_pubport" "$_pre_rb_cfhost" "${target_tag#v}" 1 || {
        msg "${RED}$(tr_msg wl_rb_state_fail)${NC}"; return 1; }
    # N-11: prune to 2 images (new current + previous).
    wallos_prune_local_images "$run_image" "$prev_image"
    # R5C15-02: refresh the fail2ban jail after rebuild; the
    # container UpperDir changed, so a stale jail guards a
    # deleted log path and never bans. Best-effort: the
    # restore itself already succeeded.
    wallos_bruteforce_protection "$port" "$bind_address" 2>/dev/null || true
    msg "${GREEN}$(tprintf wl_rb_done "$target_tag")${NC}"
    return 0
}

# N-11: Pull a specific versioned image from the A-Box mirror.
# Args: $1 = version tag. Sets WALLOS_IMAGE_RESULT on success.
_wallos_pull_versioned_image() {
    local tag="$1" arch asset expected actual work manifest_url sum_url
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    arch=$(wallos_detect_arch) || return 1
    work=$(umask 077; mktemp -d /tmp/A-Box-Wallos-ver.XXXXXX) || return 1
    local ver_manifest="wallos-manifest-${tag}.txt"
    manifest_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/$ver_manifest"
    sum_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/SHA256SUMS"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$manifest_url" -o "$work/$ver_manifest" ||
       ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$sum_url" -o "$work/SHA256SUMS"; then
        rm -rf -- "$work"; return 1
    fi
    # P1-2: verify SHA256SUMS signature before trusting it.
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "${sum_url}.sig" -o "$work/SHA256SUMS.sig" 2>/dev/null || true
    if ! abox_verify_sig_gate "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "Wallos versioned SHA256SUMS"; then
        rm -rf -- "$work"; return 1
    fi
    # Verify manifest against SHA256SUMS (fail-closed).
    local manifest_expected manifest_actual
    manifest_expected=$(awk -v f="$ver_manifest" '$2==f || $2==("*" f) {print $1; exit}' "$work/SHA256SUMS" 2>/dev/null || true)
    manifest_actual=$(sha256sum "$work/$ver_manifest" 2>/dev/null | awk '{print $1}' || true)
    if [[ ! "$manifest_expected" =~ ^[A-Fa-f0-9]{64}$ || "${manifest_expected,,}" != "${manifest_actual,,}" ]]; then
        rm -rf -- "$work"
        msg "${RED}Wallos versioned manifest checksum mismatch; refusing.${NC}"
        return 1
    fi
    # Verify the manifest's tag matches the requested version.
    local mtag
    mtag=$(awk -F= '$1=="tag" {print $2; exit}' "$work/$ver_manifest" 2>/dev/null || true)
    [[ "$mtag" == "$tag" ]] || { rm -rf -- "$work"; return 1; }
    case "$arch" in amd64|arm64|armv7) asset="wallos-linux-$arch-${tag}.tar.gz" ;; *) rm -rf -- "$work"; return 1 ;; esac
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 600 \
        "https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/$asset" -o "$work/$asset"; then
        rm -rf -- "$work"; return 1
    fi
    expected=$(awk -v f="$asset" '$2==f || $2==("*" f) {print $1; exit}' "$work/SHA256SUMS" 2>/dev/null || true)
    actual=$(sha256sum "$work/$asset" 2>/dev/null | awk '{print $1}' || true)
    if [[ ! "$expected" =~ ^[A-Fa-f0-9]{64}$ || "${expected,,}" != "${actual,,}" ]]; then
        rm -rf -- "$work"
        msg "${RED}Wallos versioned archive checksum mismatch; refusing.${NC}"
        return 1
    fi
    # R11-C (R2-10-1): derive the config digest from the authenticated
    # archive as a sanity check only. Under a containerd image store
    # the daemon's .Id is the manifest/index digest, not the config
    # digest, so this value must never be used as the run target or
    # for an image inspect; the run target comes from the daemon.
    local _archive_id
    _archive_id=$(wallos_image_id_from_archive "$work/$asset") || { rm -rf -- "$work"; return 1; }
    [[ "$_archive_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { rm -rf -- "$work"; return 1; }
    local load_out image_tag="${tag#v}"
    # R54-M1: the manifest digest is the containerd store's image ID;
    # capture it before $work is removed (the binding check below runs
    # after the load, when $work is gone).
    local _manifest_digest=''
    _manifest_digest=$(awk -F= -v a="$arch" '$1==("image_digest." a) {print $2; exit}' "$work/$ver_manifest" 2>/dev/null || true)
    _manifest_digest=$(wallos_normalize_digest "$_manifest_digest" 2>/dev/null || true)
    load_out=$(gzip -dc "$work/$asset" | docker load 2>&1) || { rm -rf -- "$work"; return 1; }
    if ! wallos_check_loaded_image "$load_out" "$image_tag"; then
        rm -rf -- "$work"; return 1
    fi
    rm -rf -- "$work"
    # R11-C (R2-10-1): adopt the daemon-reported store-native .Id.
    # An inspect failure refuses; a malformed ID refuses. The config
    # digest above is not the daemon's addressable image ID.
    local _archive_tag_id
    _archive_tag_id=$(docker image inspect --format '{{.Id}}' "bellamy/wallos:$image_tag" 2>/dev/null) || return 1
    [[ "$_archive_tag_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    # R54-M1: bind the adopted ID to the authenticated archive. The
    # daemon .Id is the config digest under the Docker store and the
    # manifest digest under the containerd store; anything else means
    # the tag was retargeted between load and inspect (or the load
    # produced a different image), and the load must be refused.
    wallos_loaded_id_matches_archive "$_archive_tag_id" "$_archive_id" "$_manifest_digest" || return 1
    wallos_record_image "bellamy/wallos:$image_tag"
    WALLOS_IMAGE_RESULT="$_archive_tag_id"
    WALLOS_IMAGE_VERSION="$image_tag"
    return 0
}

wallos_latest_stable_tag() {
    local response tag
    response=$(curl -fLsS --proto =https --proto-redir =https --retry 1 --connect-timeout 8 --max-time 20 https://api.github.com/repos/ellite/Wallos/releases/latest 2>/dev/null) || return 1
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' <<< "$response" 2>/dev/null) || return 1
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$tag"
}

wallos_pull_or_restore_image() {
    local arch="$1" tag='' asset='' expected actual work manifest_url sum_url _w_ts=''
    WALLOS_IMAGE_RESULT=''
    WALLOS_IMAGE_VERSION=''
    tag=$(wallos_latest_stable_tag 2>/dev/null || true)
    if [[ -n "$tag" ]] && wallos_candidate_version_allowed "$tag"; then
        local image_tag="${tag#v}"
        # N-2: If the A-Box mirror manifest has the same tag, pull by immutable
        # digest (not mutable tag).
        # FINAL-AUDIT fix: download the manifest ONCE to a protected temp file,
        # verify it against SHA256SUMS (same check as the fallback path below),
        # then derive BOTH digest and tag from that single verified copy. The
        # old code used two separate curl fetches with no verification, so the
        # digest and tag could come from different manifest versions.
        # TRUST BOUNDARY NOTE: SHA256SUMS and the manifest are fetched from
        # the same mutable Release. The checksum comparison alone detects
        # inconsistency and corruption; it is NOT an independent authenticity
        # proof. Detached Ed25519 signature checks for both files are handled
        # by abox_verify_sig_gate (F-05) below, under its verification policy.
        local _n2_work="" _mirror_digest="" _manifest_tag="" _n2_ts="" _n2_fail_reason=""
        local _n2_manifest_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/wallos-manifest.txt"
        local _n2_sum_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/SHA256SUMS"
        _n2_work=$(umask 077; mktemp -d /tmp/A-Box-Wallos-n2.XXXXXX 2>/dev/null) || true
        [[ -n "$_n2_work" && -d "$_n2_work" ]] || _n2_fail_reason='download'
        if [[ -n "$_n2_work" && -d "$_n2_work" ]]; then
            # TRAP-3: EXIT trap ensures temp dir cleanup even on abnormal exit.
            # Expand $_n2_work now (double quotes); the local is gone when EXIT fires.
            # FIX: Save any pre-existing EXIT trap (e.g. runtime lock cleanup)
            # and restore it afterward, instead of discarding it with bare
            # "trap - EXIT" (follows the restore_saved_trap pattern).
            local _n2_prev_trap_exit _n2_trap_cmd _n2_old_cmd
            _n2_prev_trap_exit=$(trap -p EXIT 2>/dev/null || true)
            # Chain the saved handler into the temp trap: a bare temp
            # trap would swallow the original handler on an abnormal
            # exit inside this window. Both parts are expanded now
            # (locals are gone when EXIT fires); the saved string is
            # `trap -- 'cmd' EXIT`, so strip the wrapper and eval cmd.
            _n2_trap_cmd="rm -rf -- '$_n2_work' 2>/dev/null"
            if [[ -n "$_n2_prev_trap_exit" ]]; then
                _n2_old_cmd="${_n2_prev_trap_exit#trap -- }"
                _n2_old_cmd="${_n2_old_cmd% EXIT}"
                _n2_trap_cmd="$_n2_trap_cmd; eval $_n2_old_cmd"
            fi
            trap "$_n2_trap_cmd" EXIT
            if curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$_n2_manifest_url" -o "$_n2_work/wallos-manifest.txt" 2>/dev/null &&
               curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$_n2_sum_url" -o "$_n2_work/SHA256SUMS" 2>/dev/null; then
                local _n2_expected _n2_actual
                # TRAP-3: filename anchored exactly via awk -v (not unanchored grep).
                _n2_expected=$(awk -v f="wallos-manifest.txt" '$2==f || $2==("*" f) {print $1; exit}' "$_n2_work/SHA256SUMS" 2>/dev/null || true)
                _n2_actual=$(sha256sum "$_n2_work/wallos-manifest.txt" 2>/dev/null | awk '{print $1}' || true)
                if [[ "$_n2_expected" =~ ^[A-Fa-f0-9]{64}$ && "${_n2_expected,,}" == "${_n2_actual,,}" ]]; then
                    # F-05: verify detached Ed25519 signature of the manifest.
                    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$_n2_sum_url.sig" -o "$_n2_work/SHA256SUMS.sig" 2>/dev/null || true
                    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "${_n2_manifest_url}.sig" -o "$_n2_work/wallos-manifest.txt.sig" 2>/dev/null || true
                    # DS-Q4: SHA256SUMS 本身也要验签 (之前只下载不验证)
                    if ! abox_verify_sig_gate "$_n2_work/SHA256SUMS" "$_n2_work/SHA256SUMS.sig" "Wallos SHA256SUMS (N-2 fast path)"; then
                        msg "${RED}$(tr_msg wl_pi_sig_sums)${NC}"
                        trap - EXIT
                        restore_saved_trap EXIT "$_n2_prev_trap_exit"
                        rm -rf -- "$_n2_work"
                        return 1
                    fi
                    if ! abox_verify_sig_gate "$_n2_work/wallos-manifest.txt" "$_n2_work/wallos-manifest.txt.sig" "Wallos manifest (N-2 fast path)"; then
                        # D-10: abox_verify_sig_gate only returns 1 when ABOX_SIGNING_ENFORCE=1.
                        # In that mode, falling back to an unsigned tag pull would defeat
                        # enforcement, so fail hard instead of silently downgrading.
                        msg "${RED}$(tr_msg wl_pi_sig_manifest)${NC}"
                        trap - EXIT
                        restore_saved_trap EXIT "$_n2_prev_trap_exit"
                        rm -rf -- "$_n2_work"
                        return 1
                    else
                        # F-05 anti-replay on manifest timestamp.
                        _n2_ts=$(awk -F= '$1=="retrieved_at_utc" {print $2; exit}' "$_n2_work/wallos-manifest.txt" 2>/dev/null || true)
                        if ! abox_signing_timestamp_ok "$_n2_ts"; then
                            printf '[A-Box][F-05] FATAL: Wallos manifest timestamp %s predates trust floor\n' "$_n2_ts" >&2
                            # X-02: under ENFORCE=1, a stale timestamp must fail hard
                            # like a bad signature (D-10); falling back to an
                            # unsigned tag pull would defeat enforcement.
                            if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
                                msg "${RED}$(tr_msg wl_pi_ts_reject_on)${NC}"
                                trap - EXIT
                                restore_saved_trap EXIT "$_n2_prev_trap_exit"
                                rm -rf -- "$_n2_work"
                                return 1
                            fi
                            msg "${YELLOW}$(tr_msg wl_pi_ts_reject_off)${NC}"
                        else
                            _mirror_digest=$(awk -F= -v a="$arch" '$1==("image_digest." a) {print $2; exit}' "$_n2_work/wallos-manifest.txt" 2>/dev/null || true)
                            # PR #161: the manifest carries bare digests
                            # (sha256:<hex>); normalize to the canonical
                            # prefixed form the checks and docker pull need.
                            _mirror_digest=$(wallos_normalize_digest "$_mirror_digest" 2>/dev/null || true)
                            _manifest_tag=$(awk -F= '$1=="tag" {print $2; exit}' "$_n2_work/wallos-manifest.txt" 2>/dev/null || true)
                        fi
                    fi
                else
                    _n2_fail_reason='hash'
                fi
            else
                _n2_fail_reason='download'
            fi
            trap - EXIT
            restore_saved_trap EXIT "$_n2_prev_trap_exit"
            rm -rf -- "$_n2_work"
        fi
        if [[ -n "$_n2_fail_reason" ]]; then
            if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
                msg "${RED}Wallos manifest verification failed and signing enforcement is ON; refusing unsigned tag pull.${NC}"
                return 1
            elif [[ "$_n2_fail_reason" == 'hash' ]]; then
                msg "${YELLOW}$(tr_msg wl_pi_fp_mismatch)${NC}"
            else
                msg "${YELLOW}Wallos mirror manifest unavailable; falling back to unsigned tag pull.${NC}"
            fi
        fi
        if [[ "$_mirror_digest" =~ ^(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]]; then
            if [[ "$_manifest_tag" == "$tag" ]]; then
                # N-2: docker pull by digest creates NO tag. Must docker tag
                # for downstream checks (require ^bellamy/wallos:[A-Za-z0-9._-]+$).
                # U115: the verified digest is the identity; the tag created
                # alongside is a convenience alias only, never the run identity.
                if abox_run_wait "$(tr_msg wallos_pull_or_restore_image_pulling)" docker pull "$_mirror_digest" && docker tag "$_mirror_digest" "bellamy/wallos:$image_tag"; then
                    wallos_record_image "bellamy/wallos:$image_tag"
                    WALLOS_IMAGE_RESULT="$_mirror_digest"
                    WALLOS_IMAGE_VERSION="$image_tag"
                    return 0
                fi
                msg "${YELLOW}$(tr_msg wl_pi_digest_fail)${NC}"
            elif [[ "$_manifest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                msg "${YELLOW}$(tprintf wl_pi_manifest_mismatch "$tag" "$_manifest_tag")${NC}"
            fi
        fi
        # S133: under ENFORCE=1, never fall back to the unsigned tag pull:
        # the observed RepoDigest is not the manifest-verified digest.
        # Skip it and fall through to the manifest-verified recovery path.
        if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
            msg "${YELLOW}Wallos upstream digest-pinned path did not provide an image; signing enforcement is ON, so unsigned tag pull is skipped.${NC}"
        elif abox_run_wait "$(tr_msg wallos_pull_or_restore_image_pulling)" docker pull "bellamy/wallos:$image_tag"; then
            wallos_record_image "bellamy/wallos:$image_tag"
            # P2-1: record RepoDigest for auditability (mutable tag alone is not identity).
            # G11 FIX: Use digest reference instead of mutable tag to prevent TOCTOU.
            # After pull, immediately pin to digest so subsequent operations
            # cannot be affected by tag mutation.
            local _pulled_digest
            _pulled_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "bellamy/wallos:$image_tag" 2>/dev/null || true)
            # Normalize to the same canonical form as manifest digests.
            _pulled_digest=$(wallos_normalize_digest "$_pulled_digest" 2>/dev/null || true)
            # U115: run by the exact digest just pulled, not the mutable tag.
            # The digest here is observed (not manifest-verified); it still
            # closes the pull-to-run TOCTOU window. No digest observed -> fall through to the manifest-verified recovery path below; running by mutable tag would reopen the TOCTOU window.
            if [[ "$_pulled_digest" =~ ^(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]]; then
                msg "${CYAN}$(tprintf wl_pi_digest "$_pulled_digest")${NC}"
                docker tag "$_pulled_digest" "bellamy/wallos:$image_tag" >/dev/null 2>&1 || true
                WALLOS_IMAGE_RESULT="$_pulled_digest"
                WALLOS_IMAGE_VERSION="$image_tag"
                return 0
            fi
            msg "${YELLOW}$(tr_msg wl_pi_digest_fail)${NC}"
        fi
    fi
    msg "${YELLOW}$(tr_msg wl_pi_recovery)${NC}"
    work=$(umask 077; mktemp -d /tmp/A-Box-Wallos.XXXXXX) || return 1
    manifest_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/wallos-manifest.txt"
    sum_url="https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/SHA256SUMS"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$manifest_url" -o "$work/wallos-manifest.txt" ||
       ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "$sum_url" -o "$work/SHA256SUMS"; then
        rm -rf -- "$work"
        return 1
    fi
    # D-2-FIX: Verify manifest itself against SHA256SUMS (manifest was unverified).
    manifest_expected=$(awk -v f="wallos-manifest.txt" '$2==f || $2==("*" f) {print $1; exit}' "$work/SHA256SUMS")
    manifest_actual=$(sha256sum "$work/wallos-manifest.txt" | awk '{print $1}')
    if [[ ! "$manifest_expected" =~ ^[A-Fa-f0-9]{64}$ || "${manifest_expected,,}" != "${manifest_actual,,}" ]]; then
        rm -rf -- "$work"
        msg "${RED}$(tr_msg wl_pi_manifest_sum)${NC}"
        return 1
    fi
    # P1-2: verify SHA256SUMS signature before trusting it.
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "${sum_url}.sig" -o "$work/SHA256SUMS.sig" 2>/dev/null || true
    if ! abox_verify_sig_gate "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "Wallos SHA256SUMS (fallback path)"; then
        rm -rf -- "$work"
        return 1
    fi
    # F-05: verify detached Ed25519 signature of the manifest.
    curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 30 "${manifest_url}.sig" -o "$work/wallos-manifest.txt.sig" 2>/dev/null || true
    if ! abox_verify_sig_gate "$work/wallos-manifest.txt" "$work/wallos-manifest.txt.sig" "Wallos manifest (fallback path)"; then
        rm -rf -- "$work"
        return 1
    fi
    # F-05 anti-replay on manifest timestamp.
    _w_ts=$(awk -F= '$1=="retrieved_at_utc" {print $2; exit}' "$work/wallos-manifest.txt" 2>/dev/null || true)
    if ! abox_signing_timestamp_ok "$_w_ts"; then
        # X-10: gate on ENFORCE like the core path (L5297); unconditional
        # reject breaks the default ENFORCE=0 flow on a stale mirror.
        if [[ "${ABOX_SIGNING_ENFORCE:-1}" == '1' ]]; then
            printf '[A-Box][F-05] FATAL: Wallos manifest timestamp %s predates trust floor\n' "$_w_ts" >&2
            rm -rf -- "$work"
            return 1
        fi
        printf '[A-Box][F-05] WARNING: Wallos manifest timestamp %s predates trust floor (enforcement off)\n' "$_w_ts" >&2
    fi
    tag=$(awk -F= '$1=="tag" {print $2; exit}' "$work/wallos-manifest.txt")
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { rm -rf -- "$work"; return 1; }
    wallos_candidate_version_allowed "$tag" || { rm -rf -- "$work"; return 1; }
    case "$arch" in amd64|arm64|armv7) asset="wallos-linux-$arch.tar.gz" ;; *) rm -rf -- "$work"; return 1 ;; esac
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 --max-time 600 \
        "https://github.com/alariclin/A-Box/releases/download/$WALLOS_MIRROR_RELEASE/$asset" -o "$work/$asset"; then
        rm -rf -- "$work"
        return 1
    fi
    expected=$(awk -v f="$asset" '$2==f || $2==("*" f) {print $1; exit}' "$work/SHA256SUMS")
    actual=$(sha256sum "$work/$asset" | awk '{print $1}')
    if [[ ! "$expected" =~ ^[A-Fa-f0-9]{64}$ || "${expected,,}" != "${actual,,}" ]]; then
        rm -rf -- "$work"
        msg "${RED}$(tr_msg wl_pi_mirror_sum)${NC}"
        return 1
    fi
    # N-3: Verify docker load loaded exactly the single expected image.
    # Do NOT docker rmi beforehand (would destroy rollback image on load failure).
    # R11-C (R2-10-1): derive the config digest from the authenticated
    # archive as a sanity check only. It is the config JSON SHA256;
    # under a containerd image store the daemon's .Id differs, so
    # this value must never be used as the run target or for an
    # image inspect; the run target is resolved from the daemon
    # right after the load check below.
    local _archive_id
    _archive_id=$(wallos_image_id_from_archive "$work/$asset") || { rm -rf -- "$work"; return 1; }
    [[ "$_archive_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { rm -rf -- "$work"; return 1; }
    local load_out
    load_out=$(gzip -dc "$work/$asset" | docker load 2>&1) || { rm -rf -- "$work"; return 1; }
    if ! wallos_check_loaded_image "$load_out" "${tag#v}"; then
        rm -rf -- "$work"
        msg "${RED}$(tprintf wl_pi_archive "${tag#v}")${NC}"
        return 1
    fi
    # R11-C (R2-10-1): resolve the daemon's store-native image ID once,
    # right after the load check. Every later step (RepoDigests query,
    # final adopt) uses this saved value; the tag is never re-resolved,
    # so a concurrent retag cannot change which image is adopted.
    local image_tag="${tag#v}" _loaded_id
    if ! _loaded_id=$(docker image inspect --format '{{.Id}}' "bellamy/wallos:$image_tag" 2>/dev/null) || [[ ! "$_loaded_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        rm -rf -- "$work"
        msg "${RED}Wallos loaded image ID could not be resolved from the daemon; refusing.${NC}"
        return 1
    fi
    # D-2-FIX: Fail-closed digest check. Manifest is now hash-verified above.
    # NOTE: docker load does NOT populate .RepoDigests (only docker pull does),
    # so RepoDigest comparison is skipped for loaded images. The tarball SHA
    # (verified above) + verified manifest together authenticate the image.
    local expected_digest
    expected_digest=$(awk -F= -v a="$arch" '$1==("image_digest." a) {print $2; exit}' "$work/wallos-manifest.txt")
    # PR #161: the manifest carries bare digests (sha256:<hex>); normalize
    # to the canonical prefixed form before the format check below.
    expected_digest=$(wallos_normalize_digest "$expected_digest" 2>/dev/null || true)
    # Require digest present and format-valid (fail-closed if missing/malformed).
    # Allow optional docker.io/ prefix (containerd image store).
    if [[ ! "$expected_digest" =~ ^(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]]; then
        rm -rf -- "$work"
        msg "${RED}$(tprintf wl_pi_no_digest "$arch")${NC}"
        return 1
    fi
    # R54-M1: bind the resolved ID to the authenticated archive (same
    # store-aware rule as _wallos_pull_versioned_image): config digest
    # (Docker store) or manifest digest (containerd store).
    wallos_loaded_id_matches_archive "$_loaded_id" "$_archive_id" "$expected_digest" || { rm -rf -- "$work"; msg "${RED}Wallos loaded image ID does not match the verified archive; refusing.${NC}"; return 1; }
    # Defense-in-depth: If RepoDigests is populated (e.g. image was pulled), verify it matches.
    # F04: RepoDigests can hold several entries (multi-platform
    # plus platform-specific pulls of the same image); checking
    # only index 0 rejects a qualified image whose expected
    # digest is present but not first. Check full-list
    # membership instead. An empty list still skips the check
    # (docker load populates no RepoDigest; see the NOTE above).
    local loaded_digests
    # R11-C (R2-10-1): query by the daemon ID resolved above, not the
    # mutable tag and not the config digest. A failed inspect is a
    # refusal, not an empty digest list.
    if ! loaded_digests=$(docker image inspect --format '{{join .RepoDigests "\n"}}' "$_loaded_id" 2>/dev/null); then
        rm -rf -- "$work"
        msg "${RED}Wallos loaded image digest check failed; refusing.${NC}"
        return 1
    fi
    # U116: normalize both sides (whitespace, docker.io/ prefix, case) before
    # comparing; the format check above allows the prefix, so a raw string
    # comparison would reject the same digest in a different spelling.
    local _expected_norm="${expected_digest//[[:space:]]/}"
    _expected_norm="${_expected_norm#docker.io/}"
    _expected_norm="${_expected_norm,,}"
    local _found=0 _one='' _one_norm=''
    while IFS= read -r _one; do
        [[ -n "$_one" ]] || continue
        _one_norm="${_one//[[:space:]]/}"
        _one_norm="${_one_norm#docker.io/}"
        if [[ "${_one_norm,,}" == "$_expected_norm" ]]; then _found=1; break; fi
    done <<< "$loaded_digests"
    if [[ -n "${loaded_digests//[[:space:]]/}" && "$_found" == 0 ]]; then
        rm -rf -- "$work"
        msg "${RED}$(tr_msg wl_pi_digest_mismatch)${NC}"
        return 1
    fi
    rm -rf -- "$work"
    # R11-C (R2-10-1): adopt the daemon ID resolved after the load
    # check above. Do not resolve the tag again here: the saved value
    # is the single source of truth for the run target.
    WALLOS_IMAGE_RESULT="$_loaded_id"
    wallos_record_image "bellamy/wallos:$image_tag"
    WALLOS_IMAGE_VERSION="$image_tag"
    return 0
}
wallos_wait_healthy() {
    # U117: a bare port check is not attribution. The container must exist
    # and be running, and docker must publish this port from it; otherwise
    # any local service holding the port would fake a healthy Wallos.
    # Inspect failure means the container is gone -> fail fast (all callers
    # invoke this right after docker run, so the container must exist).
    # No body-marker check: docker's publication record is the attribution
    # (only the container can serve its published port), and it needs no
    # unverified Wallos HTML string that could false-negative every install.
    # $2=mode: published (default) or unpublished. An unpublished
    # container has no host port to attribute: requiring a publication
    # would fail-closed forever, and curling the host port could
    # fake-healthy off a foreign service (the U117 hazard), so running
    # state is the only host-visible signal there.
    local port="$1" _mode="${2:-published}" i code state running pub _publine _pubhost _cip
    for i in $(seq 1 60); do
        state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' wallos 2>/dev/null || true)
        [[ -z "$state" ]] && return 1
        # R14C15-01: never accept a stale healthy status from a stopped
        # container; Running is verified before any health acceptance,
        # and published mode additionally verifies the requested
        # publication below instead of returning on healthy alone.
        running=$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null || true)
        [[ "$running" == true ]] || { sleep 1; continue; }
        [[ "$state" == unhealthy ]] && return 1
        if [[ "$state" == healthy && "$_mode" == unpublished ]]; then return 0; fi
        if [[ "$_mode" == unpublished ]]; then
            # Running alone does not mean the app inside listens. Verify
            # via the container IP (host-reachable on the docker bridge)
            # instead of returning on Running state.
            _cip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' wallos 2>/dev/null || true)
            [[ -n "$_cip" ]] || { sleep 1; continue; }
            code=$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 1 --max-time 2 "http://$_cip:80/" 2>/dev/null || true)
            case "$code" in 200|301|302|303|307|308) return 0 ;; esac
            sleep 1; continue
        fi
        pub=$(docker port wallos 2>/dev/null || true)
        _publine=$(grep -E ":$port\$" <<< "$pub" | head -1 || true)
        [[ -n "$_publine" ]] || { sleep 1; continue; }
        _pubhost=${_publine##*-> }
        _pubhost=${_pubhost%:*}
        case "$_pubhost" in
            '0.0.0.0') _pubhost='127.0.0.1' ;;
            '::'|'[::]') _pubhost='[::1]' ;;
            '['*']') ;;
            *:* ) _pubhost="[$_pubhost]" ;;
        esac
        code=$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 1 --max-time 2 "http://$_pubhost:$port/" 2>/dev/null || true)
        case "$code" in 200|301|302|303|307|308) return 0 ;; esac
        sleep 1
    done
    return 1
}

# H7-STATE: rebuild a missing .abox-state from the live container.
# Installs before this fix never wrote state on the fresh-install /
# upgrade success path (only the HTTPS->HTTP fallback branch did), so
# deployed instances have db + logos but no state, and every backup
# fails at wallos_create_backup's pre-check. The rebuild recovers
# IMAGE / PORT / TZ / BIND from `docker inspect` and MODE from the
# bind address plus the live frontends; VERSION comes only from a
# version tag attached to the very image the container runs
# (Config.Image tag, else the image ID's RepoTags) -- a digest with
# no resolvable tag leaves VERSION absent, never invented, so the
# U112 rollback gate still skips such backups instead of trusting a
# fabricated version. Provenance is recorded in the rebuilt file
# (STATE_SOURCE, VERSION_SOURCE) so a reconstructed state is never
# mistaken for an install-written one. Returns 1 on anything
# unrecoverable (foreign container, no port binding, invalid values):
# the caller then fails exactly as before (fail-closed).
# NOTE: this writes no stdout -- wallos_create_backup's output is
# captured as the backup path, so diagnostics go to stderr.
wallos_rebuild_state_from_live() {
    local image='' image_id='' port='' tz='' bind='' mode='' pubport='' cfhost='' version='' ver_src='' _jq_caddy=''
    local _label='' _env='' _tags='' _tag=''
    # R14-07 idiom: only a container carrying the A-Box managed label
    # may donate its metadata; a foreign same-name holder refuses.
    _label=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null || true)
    [[ "$_label" == 'true' ]] || return 1
    image=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null || true)
    image="${image#docker.io/}"
    [[ -n "$image" ]] || return 1
    image_id=$(docker inspect -f '{{.Image}}' wallos 2>/dev/null || true)
    [[ "$image_id" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || return 1
    port=$(docker inspect -f '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostPort}}' wallos 2>/dev/null || true)
    # U217: an unpublished container has no recoverable port; refuse
    # rather than inventing one (an empty PORT would break the upgrade
    # C-03 gate on the next run).
    valid_canonical_port "$port" || return 1
    bind=$(docker inspect -f '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostIp}}' wallos 2>/dev/null || true)
    # F-08: preserve a legitimate HostIp verbatim; an empty HostIp
    # with a port is not expected -- refuse instead of guessing.
    [[ -n "$bind" ]] || return 1
    valid_ip_address "$bind" || return 1
    _env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' wallos 2>/dev/null || true)
    tz=$(printf '%s\n' "$_env" | awk -F= '$1=="TZ" {print $2; exit}')
    [[ -n "$tz" ]] || tz='UTC'
    valid_timezone_name "$tz" || return 1
    # VERSION: the container's own image tag first (tag-created
    # containers); digest-created containers fall back to a tag
    # attached to the same image ID in the local image store (the
    # install path tags the pulled digest, so this is normally the
    # version that was installed). Neither source may invent a
    # version: no tag, no VERSION line.
    if [[ "$image" =~ ^bellamy/wallos:([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        version="${BASH_REMATCH[1]}"
        ver_src='container-image-tag'
    else
        _tags=$(docker image inspect -f '{{join .RepoTags "\n"}}' "$image_id" 2>/dev/null || true)
        while IFS= read -r _tag; do
            _tag="${_tag#docker.io/}"
            if [[ "$_tag" =~ ^bellamy/wallos:([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
                version="${BASH_REMATCH[1]}"
                ver_src='image-repo-tag'
                break
            fi
        done <<< "$_tags"
    fi
    # MODE: a live frontend wins over the bind address; otherwise the
    # bind decides (loopback -> local, public -> http). CFHOST is not
    # persisted anywhere outside state (the tunnel unit carries no
    # hostname), so a rebuilt cftunnel state omits it; PUBPORT for
    # https comes from the Caddy JSON the setup wrote atomically.
    if is_service_running abox-wallos-cftunnel 2>/dev/null; then
        mode='cftunnel'
    elif is_service_running abox-wallos-caddy 2>/dev/null && [[ -f /etc/ddr/wallos-caddy.json && ! -L /etc/ddr/wallos-caddy.json ]]; then
        mode='https'
        # M-6 (AP-01 C-leg): this file is a persistent live file, read
        # in a later invocation than the install that wrote it; a hand
        # edit or backup restore can leave comments in it, so bare jq
        # fails and PUBPORT is silently lost (stale/omitted in the
        # rebuilt state). Strip once, read the stripped view.
        _jq_caddy=$(jsonc_strip_comments /etc/ddr/wallos-caddy.json 2>/dev/null || true)
        pubport=$(printf '%s' "$_jq_caddy" | jq -r '.apps.http.servers.wallos.listen[0] // empty' 2>/dev/null || true)
        pubport="${pubport#:}"
        [[ "$pubport" =~ ^[0-9]+$ ]] || pubport=''
    elif [[ "$bind" == 0.0.0.0 ]]; then
        mode='http'
    else
        mode='local'
    fi
    wallos_write_state "$image" "$port" "$tz" "$bind" "$mode" "$pubport" "$cfhost" "$version" || return 1
    # Provenance: a reconstructed state must say so. Appended after
    # the atomic write; a failed append only warns (the state itself
    # is already valid and complete).
    if [[ -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]]; then
        {
            printf 'STATE_SOURCE=live-container\n'
            [[ -n "$ver_src" ]] && printf 'VERSION_SOURCE=%s\n' "$ver_src"
        } >> "$WALLOS_DIR/.abox-state" 2>/dev/null || true
        grep -Fxq 'STATE_SOURCE=live-container' "$WALLOS_DIR/.abox-state" 2>/dev/null || \
            msg "${YELLOW}[!] Wallos state was rebuilt from the live container but the provenance marker could not be recorded.${NC}" >&2
    fi
    return 0
}

# H-4 (Gemini): update only the IMAGE and VERSION keys of an existing
# .abox-state in place, preserving every other persisted key
# (PORT/BIND/MODE/PUBPORT/CFHOST/TZ). wallos_write_state cannot do
# this: it rewrites the whole file and drops MODE-gated keys (CFHOST
# only when mode==cftunnel, PUBPORT only when mode==https), so a
# rebuild from a stopped frontend silently destroyed them. A stale
# VERSION_SOURCE line (it described how the OLD version was derived)
# is dropped with the old VERSION. Returns 1 when there is no state
# file to update or the version is malformed.
wallos_state_update_image_version() {
    local image="$1" version="$2" state="$WALLOS_DIR/.abox-state" tmp
    [[ -f "$state" && ! -L "$state" ]] || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    tmp=$(umask 077; mktemp "$WALLOS_DIR/.abox-state.new.XXXXXX") || return 1
    if ! awk -F= -v img="$image" -v ver="$version" '
        BEGIN { seen_img=0; seen_ver=0 }
        $1=="IMAGE" && !seen_img { print "IMAGE=" img; seen_img=1; next }
        $1=="IMAGE" { next }
        $1=="VERSION" && !seen_ver { print "VERSION=" ver; seen_ver=1; next }
        $1=="VERSION" { next }
        $1=="VERSION_SOURCE" { next }
        { print }
        END {
            if (!seen_img) print "IMAGE=" img
            if (!seen_ver) print "VERSION=" ver
        }' "$state" > "$tmp"; then
        rm -f -- "$tmp"; return 1
    fi
    if [[ -d "$WALLOS_DIR/.abox-state" ]]; then rm -f -- "$tmp"; return 1; fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$WALLOS_DIR/.abox-state" || { rm -f -- "$tmp"; return 1; }
    [[ -f "$WALLOS_DIR/.abox-state" ]] || return 1
    return 0
}

# LOW-1: a backup trusts the state file's VERSION, but the state
# is only a record -- a container swapped out-of-band (e.g. a manual
# docker run of another Wallos image) leaves the state stale, and the
# backup then embeds a version that does not match the live
# container (observed: live 5.11.1 with state 5.11.3). Cross-check
# the live container's version before the backup is taken: the
# container's own image tag first, else the first bellamy/wallos
# RepoTag for the live image ID (same sources as
# wallos_rebuild_state_from_live). No live container, or either
# version unparseable -> return 0 (old behavior, no opinion).
# A mismatch warns and updates the state from live: an existing state
# file gets only its IMAGE/VERSION keys updated in place (a full
# rebuild from a stopped frontend would destroy the persisted
# MODE/PUBPORT/CFHOST); only a missing state file is rebuilt whole.
# A successful update/rebuild -> 0 (backup proceeds with fresh state),
# a failed one -> loud message + return 1 (backup refuses rather than
# embedding a known-stale version). An empty state VERSION with a
# parseable live version counts as a mismatch (the update fills it).
# Diagnostics go to stderr: callers capture stdout.
wallos_backup_state_matches_live() {
    local _live_img='' _live_img_id='' _live_ver='' _state_ver='' _tags='' _tag='' _label=''
    # H-4: a foreign same-name holder is not a live (managed) container
    # for this check; treat it as "no live container" (return 0, no
    # opinion), like the function's own header comment promises.
    _label=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null || true)
    [[ "$_label" == 'true' ]] || return 0
    _live_img=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null || true)
    [[ -n "$_live_img" ]] || return 0
    if [[ "$_live_img" =~ ^(docker\.io/)?bellamy/wallos:([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        _live_ver="${BASH_REMATCH[2]}"
    else
        _live_img_id=$(docker inspect -f '{{.Image}}' wallos 2>/dev/null || true)
        [[ -n "$_live_img_id" ]] || return 0
        _tags=$(docker image inspect -f '{{join .RepoTags "\n"}}' "$_live_img_id" 2>/dev/null || true)
        while IFS= read -r _tag; do
            _tag="${_tag#docker.io/}"
            if [[ "$_tag" =~ ^bellamy/wallos:([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
                _live_ver="${BASH_REMATCH[1]}"
                break
            fi
        done <<< "$_tags"
    fi
    [[ -n "$_live_ver" ]] || return 0
    _state_ver=$(wallos_state_value VERSION 2>/dev/null || true)
    if [[ "$_state_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$_state_ver" == "$_live_ver" ]]; then
        return 0
    fi
    msg "${YELLOW}[!] Wallos state VERSION (${_state_ver:-empty}) does not match the live container (${_live_ver}); updating state from the live container before backup.${NC}" >&2
    # H-4: when a state file exists, only IMAGE/VERSION can be stale --
    # this check only ever compared versions. Update those two keys in
    # place so a stopped frontend cannot destroy the persisted
    # PORT/BIND/MODE/PUBPORT/CFHOST/TZ, and an unpublished container
    # (no recoverable port) no longer refuses the backup. Only a
    # missing state file gets the full rebuild from live.
    if [[ -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]]; then
        _live_img="${_live_img#docker.io/}"
        if wallos_state_update_image_version "$_live_img" "$_live_ver"; then
            return 0
        fi
    elif wallos_rebuild_state_from_live; then
        return 0
    fi
    msg "${RED}[!] Wallos state VERSION (${_state_ver:-empty}) does not match the live container (${_live_ver}) and the state could not be updated; refusing to back up a known-stale version.${NC}" >&2
    return 1
}

wallos_create_backup() {
    local stamp="$1" backup="$WALLOS_DIR/backups/wallos-$1.tar.gz" temp list old
    if ! [[ -d "$WALLOS_DIR/db" && ! -L "$WALLOS_DIR/db" &&
       -d "$WALLOS_DIR/logos" && ! -L "$WALLOS_DIR/logos" &&
       -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]]; then
        # H7-STATE: db + logos present but state absent means an
        # instance installed before the install path wrote state on
        # every success path. Rebuild the state from the live
        # container and re-check; anything unrecoverable (or a
        # missing db/logos, or a state symlink/directory) still
        # fails exactly as before. One successful backup rebuilds
        # the state, which then also unblocks the upgrade C-03
        # gate and the rollback version check.
        if [[ -d "$WALLOS_DIR/db" && ! -L "$WALLOS_DIR/db" &&
              -d "$WALLOS_DIR/logos" && ! -L "$WALLOS_DIR/logos" &&
              ! -e "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]] &&
           wallos_rebuild_state_from_live &&
           [[ -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]]; then
            :
        else
            return 1
        fi
    fi
    # LOW-1: cross-check the state against the live container
    # before anything is archived; a stale VERSION must not be
    # baked into the backup.
    wallos_backup_state_matches_live || return 1
    # R6C15-02: only create (at 700) when missing; an existing
    # backups dir keeps its mode, a symlink target is refused.
    mkdir_private "$WALLOS_DIR/backups" || return 1
    temp=$(umask 077; mktemp "$backup.tmp.XXXXXX") || return 1
    if ! tar -czf "$temp" -C "$WALLOS_DIR" db logos .abox-state ||
       ! gzip -t "$temp" ||
       ! tar -tzf "$temp" > "$temp.list"; then
        rm -f -- "$temp" "$temp.list"
        return 1
    fi
    list=$(cat "$temp.list") || { rm -f -- "$temp" "$temp.list"; return 1; }
    [[ "$list" == *"db/"* && "$list" == *"logos/"* && "$list" == *".abox-state"* ]] || {
        rm -f -- "$temp" "$temp.list"; return 1;
    }
    rm -f -- "$temp.list"
    chmod 600 "$temp" || { rm -f -- "$temp"; return 1; }
    # R9C15-01: full validation before publishing; a backup with
    # links must fail here, not at restore after rotation.
    wallos_validate_backup "$temp" || { rm -f -- "$temp"; return 1; }
    sync -f "$temp" || { rm -f -- "$temp"; return 1; }
    # R27-F14-02: refuse a directory (or symlink-to-directory) backup
    # target: mv without -T would move the archive INTO the directory
    # and still return 0, reporting a "successful" backup path that can
    # never be restored. A regular-file target is still overwritten.
    [[ -d "$backup" ]] && { rm -f -- "$temp"; return 1; }
    mv -f "$temp" "$backup" || { rm -f -- "$temp"; return 1; }
    sync -f "$WALLOS_DIR/backups" || { rm -f -- "$backup"; return 1; }
    # D-07: BusyBox find (Alpine) lacks -printf; python3 is already a hard
    # dependency, so rotate by mtime in python. Keeps the newest 5 backups.
    # Rotation is best-effort: the backup itself already succeeded above.
    # R5C15-01: never rotate away the backup an active upgrade
    # journal references; recovery depends on it.
    local _journal_ref=''
    if [[ -f "$WALLOS_DIR/.upgrade-transaction" && ! -L "$WALLOS_DIR/.upgrade-transaction" ]]; then
        local _jphase _jbackup
        _jphase=$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" phase 2>/dev/null || true)
        _jbackup=$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" backup 2>/dev/null || true)
        if [[ "$_jphase" == "active" && -n "$_jbackup" ]]; then
            _journal_ref="$_jbackup"
        fi
    fi
    python3 -I - "$WALLOS_DIR/backups" "$backup" "$_journal_ref" <<'PY_WALLOS_ROTATE' 2>/dev/null || true
import os, sys
_d, _keep, _jref = sys.argv[1], sys.argv[2], sys.argv[3]
_ents = []
try:
    _names = os.listdir(_d)
except OSError:
    _names = []
for _n in _names:
    _p = os.path.join(_d, _n)
    if _n.startswith('wallos-') and _n.endswith('.tar.gz') and os.path.isfile(_p) and not os.path.islink(_p):
        try:
            _ents.append((os.stat(_p).st_mtime, _p))
        except OSError:
            continue
_ents.sort(key=lambda e: e[0], reverse=True)
for _, _p in _ents[5:]:
    if _p != _keep and _p != _jref:
        try:
            os.unlink(_p)
        except OSError:
            pass
PY_WALLOS_ROTATE
    printf '%s\n' "$backup"
}

# U118: full backup validation WITHOUT touching live data. When $2 names a
# variable, the stage directory is returned in it (caller-owned); otherwise
# the stage is discarded. wallos_restore_backup reuses this so the
# pre-removal check and the restore share one implementation (no drift).
wallos_validate_backup() {
    local backup="$1" stage_out="${2:-}" member_count=0 total_usize=0 _vstage
    local seen_db=0 seen_logos=0 seen_state=0
    [[ -f "$backup" && ! -L "$backup" ]] || return 1
    # S138: stream, don't slurp. Both listings used to be read fully
    # into shell variables (memory blowup) and limited only afterwards.
    # Both passes below abort the moment a limit is crossed; the
    # producer tar then dies on SIGPIPE. No standalone gzip -t pass:
    # tar's own decompression plus the staged extraction below are the
    # integrity gates (a corrupt stream fails the listing or the
    # extraction; trailing gzip members past tar's EOF marker are inert
    # for the restore).
    while IFS= read -r member; do
        member_count=$((member_count + 1))
        if (( member_count > 10000 )); then
            msg "${RED}$(tprintf wl_rs_toomany "$member_count")${NC}" >&2
            return 1
        fi
        # Traversal: absolute path or a dot-only path component.
        if [[ "$member" == /* || "$member" =~ (^|/)\.+(/|$) ]]; then
            return 1
        fi
        # Allowlist: only db/, logos/, .abox-state.
        if ! [[ "$member" =~ ^(db(/.*)?|logos(/.*)?|\.abox-state)$ ]]; then
            return 1
        fi
        case "$member" in
            db|db/) seen_db=1 ;;
            logos|logos/) seen_logos=1 ;;
            .abox-state) seen_state=1 ;;
        esac
    done < <(tar -tzf "$backup" 2>/dev/null)
    (( seen_db == 1 && seen_logos == 1 && seen_state == 1 )) || return 1
    # N-02 fix: reject symlinks, hardlinks, and special files inside the archive.
    # N-07 fix: enforce per-file and total size limits while streaming.
    # F07: list with --numeric-owner so the owner field is a single
    # numeric token and $3 is always the size (a space-bearing owner
    # used to shift fields and make $3 non-numeric, silently skipping
    # both guards below). A non-numeric $3 is unparseable and is
    # rejected, never skipped; zero lines means tar failed and also
    # rejects (fail closed).
    local _vseen=0
    while IFS= read -r line; do
        _vseen=1
        # tar -tv output starts with file type char: - regular, d dir, l symlink, h hardlink, c/b/p/s/D special
        case "${line:0:1}" in
            -|d) ;;
            *) msg "${RED}$(tr_msg wl_rs_nonregular)${NC}" >&2; return 1 ;;
        esac
        # Size is the 3rd field in tar -tv output (guaranteed by
        # --numeric-owner above; see the F07 comment at the loop head).
        local fsize
        fsize=$(awk '{print $3}' <<< "$line" 2>/dev/null || true)
        if ! [[ "$fsize" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if (( 10#$fsize > 536870912 )); then
            msg "${RED}$(tr_msg wl_rs_oversized)${NC}" >&2
            return 1
        fi
        # Total decompressed size guard uses summed tar member sizes.
        # (gzip -l is unreliable for multi-member streams; it reports only the last member.)
        total_usize=$((total_usize + 10#$fsize))
        if (( total_usize > 1073741824 )); then
            msg "${RED}$(tprintf wl_rs_toobig "$total_usize")${NC}" >&2
            return 1
        fi
    done < <(tar --numeric-owner -tvzf "$backup" 2>/dev/null)
    (( _vseen == 1 )) || return 1
    _vstage=$(umask 077; mktemp -d "$WALLOS_DIR/.restore-stage.XXXXXX") || return 1
    if ! tar -xzf "$backup" -C "$_vstage" ||
       [[ ! -d "$_vstage/db" || -L "$_vstage/db" ||
          ! -d "$_vstage/logos" || -L "$_vstage/logos" ||
          ! -f "$_vstage/.abox-state" || -L "$_vstage/.abox-state" ]]; then
        rm -rf -- "$_vstage"
        return 1
    fi
    if [[ -n "$stage_out" ]]; then
        printf -v "$stage_out" '%s' "$_vstage"
    else
        rm -rf -- "$_vstage"
    fi
    return 0
}

wallos_restore_backup() {
    local backup="$1" stamp stage rescue name restore_name
    wallos_validate_backup "$backup" stage || return 1
    # S139: the archive's recorded owner/mode are attacker-controlled
    # (validate checks type/size only) and root extraction preserves
    # them. Normalize the stage before moving anything into place.
    if [[ $EUID -eq 0 ]]; then
        chown -R root:root -- "$stage" 2>/dev/null || { rm -rf -- "$stage"; return 1; }
    fi
    chmod -R a-s,go-w -- "$stage" 2>/dev/null || { rm -rf -- "$stage"; return 1; }
    chmod 600 -- "$stage/.abox-state" 2>/dev/null || { rm -rf -- "$stage"; return 1; }
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    rescue="$WALLOS_DIR/.restore-preserve-$stamp-$$"
    mkdir -m 700 "$rescue" || { rm -rf -- "$stage"; return 1; }
    # R7C15-01: refuse live trees that contain a mountpoint before moving
    # them into rescue; mv would carry a nested bind mount along and the
    # final rm -rf would delete shared backing data while reporting success.
    for name in db logos .abox-state; do
        if [[ (-e "$WALLOS_DIR/$name" || -L "$WALLOS_DIR/$name") ]] && path_tree_has_mountpoint "$WALLOS_DIR/$name"; then
            msg "${RED}$(tprintf wl_rs_mount "$WALLOS_DIR/$name")${NC}" >&2
            rm -rf -- "$stage" "$rescue"
            return 1
        fi
    done
    for name in db logos .abox-state; do
        if [[ -e "$WALLOS_DIR/$name" || -L "$WALLOS_DIR/$name" ]]; then
            mv -- "$WALLOS_DIR/$name" "$rescue/$name" || {
                # B-07 fix: verify each rollback move; report incomplete state.
                local rb_failed=0
                for restore_name in db logos .abox-state; do
                    if [[ (-e "$rescue/$restore_name" || -L "$rescue/$restore_name") && ! -e "$WALLOS_DIR/$restore_name" ]]; then
                        mv -- "$rescue/$restore_name" "$WALLOS_DIR/$restore_name" 2>/dev/null || rb_failed=1
                    fi
                done
                rm -rf -- "$stage"
                (( rb_failed == 0 )) || msg "${RED}$(tprintf wl_rs_incomplete_check "$rescue")${NC}" >&2
                return 1
            }
        fi
    done
    for name in db logos .abox-state; do
        if ! mv -- "$stage/$name" "$WALLOS_DIR/$name"; then
            local rb_failed=0
            for restore_name in db logos .abox-state; do
                if [[ -e "$WALLOS_DIR/$restore_name" ]]; then
                    mv -- "$WALLOS_DIR/$restore_name" "$stage/$restore_name" 2>/dev/null || rb_failed=1
                fi
            done
            for restore_name in db logos .abox-state; do
                if [[ (-e "$rescue/$restore_name" || -L "$rescue/$restore_name") && ! -e "$WALLOS_DIR/$restore_name" ]]; then
                    mv -- "$rescue/$restore_name" "$WALLOS_DIR/$restore_name" 2>/dev/null || rb_failed=1
                fi
            done
            rm -rf -- "$stage"
            (( rb_failed == 0 )) || msg "${RED}$(tprintf wl_rs_incomplete_at "$rescue")${NC}" >&2
            return 1
        fi
    done
    rm -rf -- "$stage" "$rescue"
    return 0
}

wallos_upgrade_journal_write() {
    local phase="$1" old_image="$2" old_port="$3" old_tz="$4" old_bind="$5" backup="$6" was_running="$7" old_image_id="${8:-}" old_container_id="${9:-}" new_container_id="${10:-}"
    local journal="$WALLOS_DIR/.upgrade-transaction"
    [[ "$phase" == active || "$phase" == committed ]] || return 1
    [[ "$old_image" =~ ^((docker\.io/)?bellamy/wallos:[A-Za-z0-9._-]+|(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}|sha256:[A-Fa-f0-9]{64})$ ]] || return 1
    valid_canonical_port "$old_port" || return 1
    valid_timezone_name "$old_tz" || return 1
    # F-08: accept any valid IP for rollback (was loopback/wildcard only, forcing coercion).
    { [[ -z "$old_bind" ]] || valid_ip_address "$old_bind"; } || return 1
    [[ "$was_running" == 0 || "$was_running" == 1 ]] || return 1
    { [[ -z "$old_image_id" ]] || [[ "$old_image_id" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; } || return 1
    # H7rest: the pre-upgrade container ID (empty for old callers).
    # H7-ID: stored bare-hex (the form Docker accepts); a sha256:
    # spelling is normalized, never stored.
    if [[ -n "$old_container_id" ]]; then
        old_container_id=$(_wallos_normalize_container_id "$old_container_id" 2>/dev/null) || return 1
    fi
    # H7-F1: the container ID this transaction created (10th line).
    # Empty while no replacement exists yet; once docker run has
    # created B, the journal names B here, so recovery can tell B
    # (expected, proceed) from a foreign retaker (refuse). Same
    # normalization as the old ID; an invalid non-empty value
    # refuses the write.
    if [[ -n "$new_container_id" ]]; then
        new_container_id=$(_wallos_normalize_container_id "$new_container_id" 2>/dev/null) || return 1
    fi
    [[ "$backup" == "$WALLOS_DIR/backups/wallos-"*.tar.gz && -f "$backup" && ! -L "$backup" ]] || return 1
    write_file_atomically_from_stdin "$journal" 600 <<EOF_WALLOS_TXN
phase=$phase
old_image=$old_image
old_port=$old_port
old_tz=$old_tz
old_bind=$old_bind
backup=$backup
was_running=$was_running
old_image_id=$old_image_id
old_container_id=$old_container_id
new_container_id=$new_container_id
EOF_WALLOS_TXN
}

# H7-F1: record the container a (re)build just created in the
# active journal's new_container_id field. $1 = cidfile path docker
# was told to write (--cidfile); $2..$9 = the journal's existing
# fields (old_image old_port old_tz old_bind backup was_running
# old_image_id old_container_id). The ID comes from the cidfile when
# usable; when docker left no usable cidfile, the live 'wallos'
# container is pinned immediately -- but only when it carries the
# A-Box managed label, so a concurrent foreign retaker is never
# recorded as this transaction's container. A failed journal write
# removes the just-created container (label-checked, by ID only)
# and returns 1, so a retry rebuilds from scratch instead of
# wedging on a stale new ID. On success the global
# WALLOS_CREATED_CONTAINER_ID names the recorded container; the
# caller removes the cidfile (the journal is authoritative then).
_wallos_record_created_from_cidfile() {
    local _cidfile="$1" _new_id='' _lbl=''
    shift
    if [[ -f "$_cidfile" ]]; then
        IFS= read -r _new_id < "$_cidfile" || true
    fi
    if [[ ! "$_new_id" =~ ^[0-9a-f]{64}$ ]]; then
        _new_id=$(_wallos_container_id 2>/dev/null || true)
        if [[ -n "$_new_id" ]]; then
            _lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_new_id" 2>/dev/null || true)
            [[ "$_lbl" == 'true' ]] || _new_id=''
        fi
    fi
    [[ "$_new_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    if ! wallos_upgrade_journal_write active "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$_new_id"; then
        _lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_new_id" 2>/dev/null || true)
        if [[ "$_lbl" == 'true' ]]; then
            docker rm -f "$_new_id" >/dev/null 2>&1 || true
        fi
        return 1
    fi
    WALLOS_CREATED_CONTAINER_ID="$_new_id"
    return 0
}

# H7-C (H7-F1 residual): a docker run/create that fails AFTER creating
# the container leaves a legitimate transaction container holding the
# 'wallos' name while the journal still names the previous one; the
# next recovery then refuses its own rebuild (live != journal
# new_container_id, journal kept forever). Remove only the container
# THIS attempt created, by its --cidfile ID (label-checked, same idiom
# as the install path's run-failure cleanup and the helper above), so
# a retry rebuilds from scratch. No cidfile (e.g. a name conflict
# created nothing) means nothing to remove: leave it alone
# (fail-closed); a non-managed holder is likewise never removed.
# $1 = cidfile path docker was told to write. Always returns 0.
_wallos_cleanup_failed_create() {
    local _f="${1:-}" _id='' _lbl=''
    [[ -f "$_f" && ! -L "$_f" ]] || return 0
    IFS= read -r _id < "$_f" || true
    _id=$(_wallos_normalize_container_id "$_id" 2>/dev/null || true)
    [[ -n "$_id" ]] || return 0
    _lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_id" 2>/dev/null || true)
    [[ "$_lbl" == 'true' ]] || return 0
    docker rm -f "$_id" >/dev/null 2>&1 || true
    rm -f -- "$_f" 2>/dev/null || true
    return 0
}

wallos_txn_value() {
    local file="$1" key="$2"
    awk -F= -v key="$key" '
        $1 == key {
            count++
            value = substr($0, index($0, "=") + 1)
        }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "$file"
}

_wallos_recover_interrupted_upgrade_impl() {
    local journal="$WALLOS_DIR/.upgrade-transaction"
    local owner mode phase old_image old_port old_tz old_bind backup was_running old_image_id _run_image _lines
    [[ -e "$journal" || -L "$journal" ]] || return 0
    [[ -f "$journal" && ! -L "$journal" ]] || {
        msg "${RED}$(tr_msg wl_rc_journal_type)${NC}"
        return 1
    }
    owner=$(stat -c %u:%g "$journal" 2>/dev/null) || return 1
    mode=$(stat -c %a "$journal" 2>/dev/null) || return 1
    [[ "$owner" == 0:0 && "$mode" == 600 ]] || {
        msg "${RED}$(tr_msg wl_rc_journal_perm)${NC}"
        return 1
    }
    _lines=$(wc -l < "$journal" | tr -d '[:space:]')
    # H7rest: 9 lines carry old_container_id; 7/8-line journals from
    # before it are still accepted (live pin below is used instead).
    # H7-F1: 10 lines carry new_container_id (the container this
    # transaction created); older journals are still accepted.
    [[ "$_lines" == 7 || "$_lines" == 8 || "$_lines" == 9 || "$_lines" == 10 ]] || {
        msg "${RED}$(tprintf wl_rc_journal_incomplete "$journal")${NC}"
        return 1
    }
    phase=$(wallos_txn_value "$journal" phase) || return 1
    [[ "$phase" == active || "$phase" == committed ]] || return 1
    old_image=$(wallos_txn_value "$journal" old_image) || return 1
    # R16-F15-05: freeze the journal's old_image as the sidecar binding
    # key. The N-11 pull below may rewrite old_image from a tag to an
    # image ID, but the journal is never rewritten, so on retry the
    # sidecar (ID) and the journal (tag) disagreed and the sidecar was
    # dropped as stale, silently losing the target mode. The frozen tag
    # is identical on every retry; the run identity stays _run_image.
    local _journal_old_image="$old_image"
    old_port=$(wallos_txn_value "$journal" old_port) || return 1
    old_tz=$(wallos_txn_value "$journal" old_tz) || return 1
    old_bind=$(wallos_txn_value "$journal" old_bind) || return 1
    backup=$(wallos_txn_value "$journal" backup) || return 1
    was_running=$(wallos_txn_value "$journal" was_running) || return 1
    if [[ "$phase" == committed ]]; then
        # R55a-M1: drop the old-tunnel-token sidecar too; the journal
        # is the only record that could ever trigger its cleanup, and
        # a failure here must keep the journal so a retry can remove it.
        rm -f -- "$WALLOS_DIR/.upgrade-transaction.cftoken" || return 1
        # H7-F1: the transaction is done; its cidfile evidence is spent.
        rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
        rm -f -- "$journal" || return 1
        rm -f -- "$WALLOS_DIR/.upgrade-transaction.frontend" 2>/dev/null || true
        msg "${YELLOW}$(tr_msg wl_rc_cleanup_done)${NC}"
        return 0
    fi
    [[ "$old_image" =~ ^((docker\.io/)?bellamy/wallos:[A-Za-z0-9._-]+|(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}|sha256:[A-Fa-f0-9]{64})$ ]] || return 1
    # S135: the pinned image ID, when present, is the run identity.
    old_image_id=$(wallos_txn_value "$journal" old_image_id 2>/dev/null || true)
    { [[ -z "$old_image_id" ]] || [[ "$old_image_id" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; } || return 1
    # H7rest: the journal may carry the pre-upgrade container ID
    # (9th line). An old journal has no such line; the live pin below
    # is used instead.
    local _journal_container_id=''
    _journal_container_id=$(wallos_txn_value "$journal" old_container_id 2>/dev/null || true)
    # H7-ID: a journal written before the fix may carry a sha256:
    # spelling; normalize to bare hex so the pin comparison below
    # (live bare hex vs journal) cannot false-mismatch.
    if [[ -n "$_journal_container_id" ]]; then
        _journal_container_id=$(_wallos_normalize_container_id "$_journal_container_id" 2>/dev/null) || return 1
    fi
    # H7-F1: the container this transaction created (10th line).
    # Empty in journals written before B existed, or before the
    # field existed at all. A trusted transaction cidfile (docker's
    # own --cidfile record) is the fallback evidence for the crash
    # window between docker run and the journal refresh that names B.
    local _journal_new_id=''
    _journal_new_id=$(wallos_txn_value "$journal" new_container_id 2>/dev/null || true)
    if [[ -n "$_journal_new_id" ]]; then
        _journal_new_id=$(_wallos_normalize_container_id "$_journal_new_id" 2>/dev/null) || return 1
    fi
    local _txn_cid=''
    _txn_cid=$(_wallos_txn_cidfile_id 2>/dev/null || true)
    _run_image="${old_image_id:-$old_image}"
    valid_canonical_port "$old_port" || return 1
    valid_timezone_name "$old_tz" || return 1
    # F-08: accept any valid IP for rollback (was loopback/wildcard only).
    { [[ -z "$old_bind" ]] || valid_ip_address "$old_bind"; } || return 1
    [[ "$was_running" == 0 || "$was_running" == 1 ]] || return 1
    [[ "$backup" == "$WALLOS_DIR/backups/wallos-"*.tar.gz && -f "$backup" && ! -L "$backup" ]] || return 1
    # S135: a missing pinned image must refuse, never substitute a tag fetch.
    if [[ -n "$old_image_id" ]] && ! docker image inspect "$old_image_id" >/dev/null 2>&1; then
        msg "${RED}$(tprintf wl_rc_no_image "$old_image_id")${NC}"
        return 1
    fi
    # S134: a digest-ref old image is fetchable by digest directly,
    # without a version-list lookup (which only resolves tags).
    if [[ -z "$old_image_id" ]] && [[ "$old_image" =~ ^(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}$ ]] && ! docker image inspect "$old_image" >/dev/null 2>&1; then
        docker pull "$old_image" >/dev/null 2>&1 || { msg "${RED}$(tprintf wl_rc_no_image "$old_image")${NC}"; return 1; }
        wallos_record_image "$old_image"
    fi
    if [[ -z "$old_image_id" ]] && ! docker image inspect "$old_image" >/dev/null 2>&1; then
        # N-11: old image not present locally. Try fetching the exact previous
        # version from the versioned mirror instead of refusing.
        # N-03: look up the journal's old_image tag in the version list.
        # 07e-01: the old blind N-1 fallback (2nd line of the list) is
        # removed: it is wrong if the user had rolled back before, and
        # the pull helper binds the returned image ID to the requested
        # tag, so recovery would run a different version against the
        # old backup data. When the journal's version is not in the
        # mirror list, refuse instead of substituting any other version.
        local _n1_tag _old_tag
        _old_tag="${old_image##*:}"
        _n1_tag=''
        if [[ "$_old_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
           wallos_mirror_version_list 2>/dev/null | grep -qx "v${_old_tag}"; then
            _n1_tag="v${_old_tag}"
        else
            msg "${RED}$(tprintf wl_rc_no_image "$old_image")${NC}"
            return 1
        fi
        if [[ "$_n1_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && _wallos_pull_versioned_image "$_n1_tag"; then
            # N-03: verify the fetched image matches the journal's old_image.
            # R14-F15-03: since R11-C the pull helper returns the
            # daemon-reported store-native .Id (sha256:...), not a tag;
            # a well-formed ID is accepted because the helper binds it
            # to the requested tag (manifest + load + daemon inspect).
            if [[ "$WALLOS_IMAGE_RESULT" == "$old_image" || "$WALLOS_IMAGE_RESULT" == "bellamy/wallos:${_old_tag}" || "$WALLOS_IMAGE_RESULT" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                old_image="$WALLOS_IMAGE_RESULT"
                # R15-F15-01: _run_image was frozen before the pull;
                # the verified pulled image must become the run
                # identity too, or recovery still runs the old tag
                # (which may re-pull another version or fail).
                _run_image="$WALLOS_IMAGE_RESULT"
                msg "${YELLOW}$(tprintf wl_rc_fetched "$_n1_tag")${NC}"
            else
                msg "${RED}$(tprintf wl_rc_mismatch "$WALLOS_IMAGE_RESULT" "$old_image")${NC}"
                return 1
            fi
        else
            msg "${RED}$(tprintf wl_rc_no_image "$old_image")${NC}"
            return 1
        fi
    fi
    # S137: validate backup content BEFORE deleting the container; a
    # corrupt backup must refuse while the old container still exists.
    wallos_validate_backup "$backup" || return 1
    # R16-F15-03: tri-state the inspect (same rule as the install entry
    # and wallos_stack_teardown): a failed query is "state unknown",
    # not "container absent". Only Docker's own "No such container"
    # (plus `docker ps -a` confirmation, via _wallos_container_gone)
    # proves absence; anything else refuses instead of skipping the
    # ownership gate and restoring data under a live foreign container.
    local _rc_inspect_err=''
    if _rc_inspect_err=$(docker container inspect wallos 2>&1 >/dev/null); then
        # R13C15-01: verify ownership before stop/rm: managed label
        # AND both expected Wallos bind mounts; refuse on mismatch.
        local _rc_lbl='' _rc_mounts=''
        _rc_lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null || true)
        _rc_mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' wallos 2>/dev/null || true)
        # 07e-02: match each bind mount as one whole space-separated
        # token, not a substring: a source with a prefix
        # (/other$WALLOS_DIR/db) or a destination with a suffix
        # (/var/www/html/db-extra) must not pass. The quoted token
        # expansions are literal; the surrounding spaces anchor both ends.
        if [[ "$_rc_lbl" != "true" ]] || [[ " $_rc_mounts " != *" ""$WALLOS_DIR/db:/var/www/html/db"" "* ]] || [[ " $_rc_mounts " != *" ""$WALLOS_DIR/logos:/var/www/html/images/uploads/logos"" "* ]]; then
            msg "${RED}Refusing recovery: existing 'wallos' container is not A-Box-managed (label or bind mounts mismatch).${NC}"
            return 1
        fi
        # H7rest: pin the container ID next to the ownership gate.
        # H7-F1: compare against the container this transaction
        # stage expects, NOT always the pre-upgrade one -- that was
        # the wedge: after B was created, live==B no longer equaled
        # old==A and recovery refused its own replacement. When the
        # journal names a created container, live must be exactly
        # that; when it names none, live must be the pre-upgrade
        # container or the container the transaction cidfile records
        # (crash window: docker ran, journal refresh never landed).
        # With neither record, legacy behavior applies (no ID check).
        # A foreign retaker matches none of them and still refuses.
        local _rc_cid=''
        _rc_cid=$(_wallos_container_id) || return 1
        if [[ -n "$_journal_new_id" ]]; then
            if [[ "$_rc_cid" != "$_journal_new_id" ]]; then
                msg "${RED}Refusing recovery: the 'wallos' container changed since the upgrade journal was written; refusing to stop/remove a different container.${NC}"
                return 1
            fi
        elif [[ -n "$_journal_container_id" || -n "$_txn_cid" ]]; then
            if [[ "$_rc_cid" != "$_journal_container_id" && "$_rc_cid" != "$_txn_cid" ]]; then
                msg "${RED}Refusing recovery: the 'wallos' container changed since the upgrade journal was written; refusing to stop/remove a different container.${NC}"
                return 1
            fi
        fi
        _wallos_stop_id "$_rc_cid" || true
        _wallos_rm_id "$_rc_cid" || {
            # A-04: rm failed after stop; restart the original instead
            # of leaving it Exited -- but only when the journal says
            # it was running. R15-F15-03: with was_running==0 the
            # normal path only docker-creates (never starts), so an
            # unconditional start here would boot an instance that
            # must stay stopped.
            if (( was_running == 1 )); then
                _wallos_start_id "$_rc_cid" || true
            fi
            msg "${RED}$(tr_msg wl_rc_rm_fail)${NC}"
            return 1
        }
    elif _wallos_container_gone "$_rc_inspect_err"; then
        : # genuinely absent; proceed with the restore below
    else
        msg "${RED}Wallos container state unknown; refusing recovery.${NC}"
        _wallos_show_docker_err "$_rc_inspect_err"
        return 1
    fi
    # H7-F1: the live container (if any) has been removed above, so
    # the transaction cidfile's evidence is spent -- a retry must not
    # treat the removed container as the expected one. Best-effort:
    # a failed removal only leaves a stale file a later run ignores.
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
    # B15-1 (durable A): the backup restore below overwrites the live
    # .abox-state with the pre-upgrade mode, so a local->https (or
    # local->cftunnel) switch committed before the interrupt would be
    # silently rolled back when R1-15-01 later reads MODE. Preserve the
    # target frontend BEFORE the destructive restore, in a durable
    # sidecar bound to this transaction (journal backup+old_image), so
    # a retry after a crash between restore and re-apply still honors
    # the target instead of snapshotting the already-restored state.
    # Only https/cftunnel targets change the R1-15-01 branch; http and
    # local both take the teardown branch, so they need no preserve.
    local _fs_sidecar="$WALLOS_DIR/.upgrade-transaction.frontend"
    local _fs_mode='' _fs_pubport='' _fs_cfhost='' _fs_have=0 _fs_wrc=0
    if [[ -f "$_fs_sidecar" && ! -L "$_fs_sidecar" ]]; then
        local _fs_backup='' _fs_old_image=''
        _fs_backup=$(wallos_txn_value "$_fs_sidecar" backup 2>/dev/null || true)
        _fs_old_image=$(wallos_txn_value "$_fs_sidecar" old_image 2>/dev/null || true)
        if [[ "$_fs_backup" == "$backup" && "$_fs_old_image" == "$_journal_old_image" ]]; then
            _fs_mode=$(wallos_txn_value "$_fs_sidecar" mode 2>/dev/null || true)
            _fs_pubport=$(wallos_txn_value "$_fs_sidecar" pubport 2>/dev/null || true)
            _fs_cfhost=$(wallos_txn_value "$_fs_sidecar" cfhost 2>/dev/null || true)
            if [[ "$_fs_mode" == https || "$_fs_mode" == cftunnel ]]; then
                _fs_have=1
            else
                msg "${RED}Recovery found a corrupt frontend record for this upgrade; refusing to report success, journal kept.${NC}"
                return 1
            fi
        else
            # Stale record from another transaction: drop it; the live
            # snapshot below decides this transaction's intent.
            rm -f -- "$_fs_sidecar" 2>/dev/null || true
        fi
    fi
    if (( _fs_have == 0 )); then
        _fs_mode=$(wallos_state_value MODE 2>/dev/null || true)
        _fs_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
        _fs_cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
        if [[ "$_fs_mode" == https || "$_fs_mode" == cftunnel ]]; then
            write_file_atomically_from_stdin "$_fs_sidecar" 600 <<EOF_B15_SIDECAR
backup=$backup
old_image=$_journal_old_image
mode=$_fs_mode
pubport=$_fs_pubport
cfhost=$_fs_cfhost
EOF_B15_SIDECAR
            _fs_wrc=$?
            if (( _fs_wrc != 0 )); then
                msg "${RED}Recovery could not record the interrupted switch target; refusing to report success, journal kept.${NC}"
                return 1
            fi
        else
            _fs_mode=''
        fi
    fi
    wallos_restore_backup "$backup" || {
        msg "${RED}$(tprintf wl_rc_restore_fail "$journal" "$backup")${NC}"
        return 1
    }
    # B15-1: re-apply the preserved target frontend (sidecar or live
    # snapshot) BEFORE R1-15-01 reads MODE. The tuple is compared, not
    # just MODE: a same-mode endpoint change (e.g. a new PUBPORT) must
    # also survive. A failed re-apply returns 1 with the journal (and
    # the sidecar) kept, so a retry re-applies from the durable record
    # instead of snapshotting the restored state. Endpoint validity
    # itself is still enforced by R1-15-01 exactly as before (missing
    # PUBPORT / bad CFHOST fail closed there, like L4/L5).
    # F15-1: the re-apply also covers the https internal layout: when
    # the target is https, the container port is moved off the public
    # port (re-randomized when it equals PUBPORT) and bound to
    # 127.0.0.1, so the rebuild cannot collide with Caddy on :P.
    if [[ -n "$_fs_mode" ]]; then
        local _rb_image='' _rb_port='' _rb_tz='' _rb_bind='' _rb_version=''
        local _rb_mode='' _rb_pubport='' _rb_cfhost=''
        local _rb_layout_changed=0
        _rb_image=$(wallos_state_value IMAGE 2>/dev/null || true)
        _rb_port=$(wallos_state_value PORT 2>/dev/null || true)
        _rb_tz=$(wallos_state_value TZ 2>/dev/null || true)
        _rb_bind=$(wallos_state_value BIND 2>/dev/null || true)
        _rb_version=$(wallos_state_value VERSION 2>/dev/null || true)
        _rb_mode=$(wallos_state_value MODE 2>/dev/null || true)
        _rb_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
        _rb_cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
        # F15-1: when the interrupted target is https, the internal
        # container port must also move off the public port: the journal
        # kept old_port == PUBPORT with a 0.0.0.0 bind, and re-applying
        # only the frontend triple would leave docker -p 0.0.0.0:P:80
        # colliding with Caddy on :P. Compute the layout first; an
        # invalid port refuses with the journal kept, exactly like the
        # incomplete-state refusal below.
        if [[ "$_fs_mode" == https ]]; then
            if [[ ! "$_fs_pubport" =~ ^[0-9]+$ ]] || [[ ${#_fs_pubport} -gt 5 ]] || (( 10#$_fs_pubport < 1 || 10#$_fs_pubport > 65535 )); then
                msg "${RED}Recovery cannot re-apply the interrupted https target: invalid public port; journal kept.${NC}"
                return 1
            fi
            if [[ ! "$_rb_port" =~ ^[0-9]+$ ]] || [[ ${#_rb_port} -gt 5 ]] || (( 10#$_rb_port < 1 || 10#$_rb_port > 65535 )); then
                msg "${RED}Recovery restored Wallos but its state has an invalid container port; refusing to report success, journal kept.${NC}"
                return 1
            fi
            local _rb_bind_orig="$_rb_bind"
            _rb_bind=127.0.0.1
            if [[ "$old_bind" != 127.0.0.1 || "$old_port" != "$_rb_port" || "$_rb_bind_orig" != 127.0.0.1 ]]; then
                _rb_layout_changed=1
            fi
            if (( 10#$_rb_port == 10#$_fs_pubport )); then
                local _rb_tries=0 _rb_cand='' _rb_found=0
                while (( _rb_tries < 50 )); do
                    _rb_tries=$(( _rb_tries + 1 ))
                    _rb_cand=$(( (RANDOM * 32768 + RANDOM) % 40000 + 20000 ))
                    (( 10#$_rb_cand == 10#$_fs_pubport )) && continue
                    if wallos_port_free "$_rb_cand"; then _rb_found=1; break; fi
                done
                if (( _rb_found == 0 )); then
                    msg "${RED}Recovery could not pick a free internal port for the https target; journal kept.${NC}"
                    return 1
                fi
                _rb_port="$_rb_cand"
                _rb_layout_changed=1
            fi
        elif [[ "$_fs_mode" == cftunnel ]]; then
            # R55a-H1: a cftunnel target binds loopback (the tunnel
            # daemon reaches the container through loopback; S149/F05).
            # The journal's old_bind may be 0.0.0.0 (pre-switch http
            # mode); re-applying it would publish plaintext HTTP on
            # the public interface. Force loopback and persist it.
            local _rb_bind_orig="$_rb_bind"
            _rb_bind=127.0.0.1
            if [[ "$_rb_bind_orig" != 127.0.0.1 ]]; then
                _rb_layout_changed=1
            fi
        fi
        if [[ "$_rb_mode" != "$_fs_mode" || "$_rb_pubport" != "$_fs_pubport" || "$_rb_cfhost" != "$_fs_cfhost" || "$_rb_layout_changed" == 1 ]]; then
            if [[ -z "$_rb_image" || -z "$_rb_port" || -z "$_rb_tz" ]]; then
                msg "${RED}Recovery restored Wallos but its state is incomplete; refusing to report success, journal kept.${NC}"
                return 1
            fi
            if ! wallos_write_state "$_rb_image" "$_rb_port" "$_rb_tz" "$_rb_bind" "$_fs_mode" "$_fs_pubport" "$_fs_cfhost" "$_rb_version" 1; then
                msg "${RED}Recovery restored Wallos but could not preserve the interrupted switch target mode ($_fs_mode); refusing to report success, journal kept.${NC}"
                return 1
            fi
            msg "${YELLOW}Recovery preserved the interrupted switch target mode ($_fs_mode); rebuilding its frontend.${NC}"
        fi
    fi
    # F15-1: in https mode the B15 re-apply may have moved the internal
    # layout (re-randomized port, 127.0.0.1 bind); the rebuild below
    # must use the effective layout even when no state write was
    # required, so sync the journal values now.
    if [[ "$_fs_mode" == https ]]; then
        old_port="$_rb_port"
        old_bind="$_rb_bind"
    elif [[ "$_fs_mode" == cftunnel ]]; then
        # R55a-H1: the cftunnel target binds loopback; the journal's
        # old_bind may be 0.0.0.0. old_port stays the journal's
        # validated value (no Caddy collision to avoid here).
        old_bind="$_rb_bind"
    fi
    # FIX: When old_bind is empty (legacy containers had no IP binding),
    # "-p :<port>:80/tcp" makes Docker publish on 0.0.0.0 (fail-open,
    # exposing plaintext HTTP on all interfaces). Omit -p entirely instead.
    local -a wallos_pub_args=()
    if [[ -n "$old_bind" ]]; then
        wallos_pub_args=(-p "$old_bind:$old_port:80/tcp")
    fi
    # H7-F1: recovery's own rebuild also binds its created container
    # to the transaction cidfile, then refreshes the journal with it:
    # otherwise a retry after this rebuild sees live==B2 (the container
    # recovery just created) matching neither old A nor new B, and
    # refuses its own rebuild. A stale cidfile from an earlier attempt
    # is dropped first; the journal is authoritative once refreshed.
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
    if (( was_running == 1 )); then
        docker run -d --cidfile "$WALLOS_DIR/.upgrade-transaction.cid" --name wallos --label com.alariclin.abox.managed=true \
            "${WALLOS_DOCKER_HARDENING[@]}" \
            -v "$WALLOS_DIR/db:/var/www/html/db" \
            -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
            -e TZ="$old_tz" "${wallos_pub_args[@]}" --restart unless-stopped "$_run_image" >/dev/null || { _wallos_cleanup_failed_create "$WALLOS_DIR/.upgrade-transaction.cid"; return 1; }
        # H7-F1: record the rebuilt container in the journal BEFORE
        # the health gate below: a health failure returns 1 with the
        # journal kept, and a retry must see live==new. old_image is
        # the FROZEN journal value (_journal_old_image), not the
        # N-11-rewritten $old_image, so the frontend sidecar binding
        # (which keys on the journal's old_image) survives a retry.
        if ! _wallos_record_created_from_cidfile "$WALLOS_DIR/.upgrade-transaction.cid" "$_journal_old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$_journal_container_id"; then
            rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
            msg "${RED}Recovery created a container but could not record it in the upgrade journal; refusing to report success, journal kept.${NC}"
            return 1
        fi
        rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
        # Same U217 rule as the install path: an omitted -p means the
        # recovered container is unpublished, so the health gate must
        # not demand a publication it will never have.
        if (( ${#wallos_pub_args[@]} == 0 )); then
            wallos_wait_healthy "$old_port" unpublished || {
                msg "${RED}$(tr_msg wl_rc_unhealthy)${NC}"
                return 1
            }
        elif ! wallos_wait_healthy "$old_port"; then
            msg "${RED}$(tr_msg wl_rc_unhealthy)${NC}"
            return 1
        fi
    else
        docker create --cidfile "$WALLOS_DIR/.upgrade-transaction.cid" --name wallos --label com.alariclin.abox.managed=true \
            "${WALLOS_DOCKER_HARDENING[@]}" \
            -v "$WALLOS_DIR/db:/var/www/html/db" \
            -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
            -e TZ="$old_tz" "${wallos_pub_args[@]}" --restart unless-stopped "$_run_image" >/dev/null || { _wallos_cleanup_failed_create "$WALLOS_DIR/.upgrade-transaction.cid"; return 1; }
        # H7-F1: same journal refresh as the run branch above.
        if ! _wallos_record_created_from_cidfile "$WALLOS_DIR/.upgrade-transaction.cid" "$_journal_old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$_journal_container_id"; then
            rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
            msg "${RED}Recovery created a container but could not record it in the upgrade journal; refusing to report success, journal kept.${NC}"
            return 1
        fi
        rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
    fi
    # R15C15-01: restore the pre-replacement tunnel token (if the
    # upgrade overwrote it) so the recovered tunnel can authenticate.
    # 2ez follow-up: this MUST precede the R1-15-01 block below — the
    # cftunnel rebuild calls wallos_cftunnel_setup, which requires a
    # non-empty token file.
    if [[ -f "$WALLOS_DIR/.upgrade-transaction.cftoken" && ! -L "$WALLOS_DIR/.upgrade-transaction.cftoken" ]]; then
        # R14-01: a failed restore must fail recovery — restarting the
        # tunnel with an unrestored token would keep the new identity.
        cp -a "$WALLOS_DIR/.upgrade-transaction.cftoken" "$WALLOS_CF_TOKEN_FILE" 2>/dev/null || { msg "${RED}Recovery could not restore the tunnel token; refusing to report success, journal kept.${NC}"; return 1; }
        chmod 600 "$WALLOS_CF_TOKEN_FILE" 2>/dev/null || { msg "${RED}Recovery could not secure the restored tunnel token; refusing to report success, journal kept.${NC}"; return 1; }
    fi
    # R1-15-01: align both frontends with the recovered mode before
    # deleting the journal; never report success on a misaligned
    # frontend (leftover exposure, or a missing required front).
    # 2ez follow-up: when the required frontend is missing (e.g. the
    # F02-GATE teardown removed it before a later write_state failure),
    # rebuild it from the state file — which still holds the old mode /
    # pubport / cfhost because the failed commit never overwrote it —
    # instead of refusing and wedging on the kept journal. A failed
    # rebuild still refuses exactly as before.
    local _rec_mode='' _rec_pubport='' _rec_cfhost='' _rc=0
    _rec_mode=$(wallos_state_value MODE 2>/dev/null || true)
    case "$_rec_mode" in
        https)
            wallos_cftunnel_teardown || return 1
            if ! is_service_running abox-wallos-caddy 2>/dev/null; then
                _rec_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
                if [[ ! "$_rec_pubport" =~ ^[0-9]+$ ]] || ! wallos_https_setup "$_rec_pubport" "$old_port"; then
                    # 429 follow-up: a failed setup can leave Caddy
                    # running on :80 with no usable config (crash-loop
                    # after reboot); tear the orphan front down so the
                    # refused rebuild leaves nothing behind. The
                    # teardown never touches the cert store, so a later
                    # retry can still reuse a certificate.
                    if ! wallos_https_teardown >/dev/null 2>&1; then
                        msg "${RED}$(tr_msg wl_rc_caddy_teardown_fail)${NC}"
                    fi
                    msg "${RED}Recovery restored Wallos but its Caddy frontend is not running; refusing to report success, journal kept.${NC}"
                    return 1
                fi
                if ! is_service_running abox-wallos-caddy 2>/dev/null; then
                    # Same orphan rule: setup reported success but the
                    # front is already down — drop the stale unit and
                    # config instead of leaving a crash-loop behind.
                    wallos_https_teardown >/dev/null 2>&1 || msg "${RED}$(tr_msg wl_rc_caddy_teardown_fail)${NC}"
                    msg "${RED}Recovery restored Wallos but its Caddy frontend is not running; refusing to report success, journal kept.${NC}"
                    return 1
                fi
            else
                # R11-C (R5-2): Caddy is already running. Always verify
                # the live config against the effective layout (the
                # rebuild port in $old_port): a port change that did
                # not come from the re-randomize path above (e.g. a
                # journal/backup mismatch, or a restored state with
                # no sidecar) leaves the live config proxying a dead
                # port, and no flag can see it. A config that already
                # matches is left alone (no restart, no cert work).
                _rec_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
                if ! _wallos_caddy_config_matches "$_rec_pubport" "$old_port"; then
                    if [[ ! "$_rec_pubport" =~ ^[0-9]+$ ]] || ! wallos_https_setup "$_rec_pubport" "$old_port"; then
                        if ! wallos_https_teardown >/dev/null 2>&1; then
                            msg "${RED}$(tr_msg wl_rc_caddy_teardown_fail)${NC}"
                        fi
                        msg "${RED}Recovery restored Wallos but its Caddy frontend is not running; refusing to report success, journal kept.${NC}"
                        return 1
                    fi
                    if ! is_service_running abox-wallos-caddy 2>/dev/null; then
                        wallos_https_teardown >/dev/null 2>&1 || msg "${RED}$(tr_msg wl_rc_caddy_teardown_fail)${NC}"
                        msg "${RED}Recovery restored Wallos but its Caddy frontend is not running; refusing to report success, journal kept.${NC}"
                        return 1
                    fi
                fi
            fi
            ;;
        cftunnel)
            wallos_https_teardown || return 1
            if ! is_service_running abox-wallos-cftunnel 2>/dev/null; then
                _rec_cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
                if [[ ! "$_rec_cfhost" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || ! wallos_cftunnel_setup "$_rec_cfhost"; then
                    msg "${RED}Recovery restored Wallos but its tunnel frontend is not running; refusing to report success, journal kept.${NC}"
                    return 1
                fi
                is_service_running abox-wallos-cftunnel 2>/dev/null || { msg "${RED}Recovery restored Wallos but its tunnel frontend is not running; refusing to report success, journal kept.${NC}"; return 1; }
            else
                # R14-01: the running cloudflared still uses the token it
                # started with; restart so it re-reads the restored file.
                # rc 1 = restart failed, rc 2 = not running afterwards.
                wallos_cftunnel_restart
                _rc=$?
                if (( _rc == 1 )); then
                    msg "${RED}Recovery restored Wallos but could not re-establish its tunnel frontend with the restored token; refusing to report success, journal kept.${NC}"
                    return 1
                elif (( _rc == 2 )); then
                    msg "${RED}Recovery restored Wallos but its tunnel frontend is not running; refusing to report success, journal kept.${NC}"
                    return 1
                fi
            fi
            ;;
        *)
            wallos_https_teardown || return 1
            wallos_cftunnel_teardown || return 1
            ;;
    esac
    rm -f -- "$journal" || return 1
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.frontend" 2>/dev/null || true
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.cftoken" 2>/dev/null || true
    # H7-F1: recovery succeeded; any transaction cidfile left by an
    # interrupted retry is spent (best-effort).
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.cid" 2>/dev/null || true
    # R5C15-02: refresh the fail2ban jail after rebuild; see
    # the rollback path. _rec_mode is the recovered mode.
    wallos_bruteforce_protection "$old_port" "$old_bind" "$_rec_mode" 2>/dev/null || true
    msg "${YELLOW}$(tr_msg wl_rc_done)${NC}"
}

# M-NEW-02: failure wrapper around the recovery implementation. A
# failed recovery leaves the Wallos jail pointing at whatever the
# failed run removed; drop it when it is provably dangling (see
# wallos_fail2ban_drop_stale_jail) so `fail2ban-client -t` passes
# again. The recovery's own return status is preserved unchanged,
# and a successful recovery is untouched (it rebuilds the jail
# itself at the end).
wallos_recover_interrupted_upgrade() {
    _wallos_recover_interrupted_upgrade_impl "$@"
    local _rc=$?
    if (( _rc != 0 )); then
        wallos_fail2ban_drop_stale_jail >/dev/null 2>&1 || true
    fi
    return "$_rc"
}

# ============ Wallos brute-force protection (fail2ban on nginx access log) ============
# Wallos keeps nginx access log inside the container's writable layer; fail2ban
# reads it from the host at <UpperDir>/var/log/nginx/access.log.
# Re-run after every (re)create of the container (install / upgrade / rollback).
# Prints the Wallos container's merged rootfs dir (the live union view
# of its filesystem), or nothing. Docker 29 with the containerd
# snapshotter exposes no GraphDriver, so the merged view is found by
# container ID under Docker's rootfs mount; the classic GraphDriver
# MergedDir covers older Docker.
wallos_container_mergeddir() {
    local _md=''
    _md=$(docker inspect -f '{{.GraphDriver.Data.MergedDir}}' wallos 2>/dev/null || true)
    if [[ -n "$_md" && -d "$_md" ]]; then printf '%s\n' "$_md"; return 0; fi
    local _id=''
    _id=$(docker inspect -f '{{.Id}}' wallos 2>/dev/null || true)
    [[ "$_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    _md="/var/lib/docker/rootfs/overlayfs/$_id"
    [[ -d "$_md" ]] || return 1
    printf '%s\n' "$_md"; return 0
}

# Prints the upperdir= value of the root (/) overlay mount in a
# mountinfo file ($1), or nothing. Docker 29 with the containerd
# snapshotter exposes no GraphDriver, so this is how the writable
# layer is located (the snapshot number is containerd-assigned and
# cannot be derived from the container ID).
wallos_upperdir_from_mountinfo() {
    local _mi="${1:-}" _line='' _opts=''
    [[ -r "$_mi" ]] || return 1
    _line=$(awk '$5 == "/" && / - overlay / { print; exit }' "$_mi" 2>/dev/null || true)
    [[ -n "$_line" ]] || return 1
    _opts="${_line##* }"
    [[ "$_opts" == *upperdir=* ]] || return 1
    _opts="${_opts##*upperdir=}"
    _opts="${_opts%%,*}"
    [[ -n "$_opts" ]] || return 1
    printf '%s\n' "$_opts"; return 0
}

# Prints the Wallos container's writable-layer dir (UpperDir), or
# nothing. Tries the classic GraphDriver inspect first, then the
# containerd snapshotter upperdir from the container init's mountinfo.
wallos_container_upperdir() {
    local _ud=''
    _ud=$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' wallos 2>/dev/null || true)
    if [[ -n "$_ud" && -d "$_ud" ]]; then printf '%s\n' "$_ud"; return 0; fi
    local _pid=''
    _pid=$(docker inspect -f '{{.State.Pid}}' wallos 2>/dev/null || true)
    [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
    _ud=$(wallos_upperdir_from_mountinfo "/proc/$_pid/mountinfo" 2>/dev/null || true)
    [[ -n "$_ud" ]] || return 1
    printf '%s\n' "$_ud"; return 0
}

# True (0) iff the A-Box-wallos fail2ban jail is live in the running
# daemon. This is the ground truth for every user-facing claim that
# login brute force is being watched.
wallos_fail2ban_jail_active() {
    command -v fail2ban-client >/dev/null 2>&1 || return 1
    fail2ban-client status A-Box-wallos >/dev/null 2>&1
}

wallos_bruteforce_protection() {
    local port="$1" bind_address="$2" wmode="${3:-}"
    local filter='/etc/fail2ban/filter.d/A-Box-wallos.conf'
    local jail='/etc/fail2ban/jail.d/A-Box-wallos.local'
    local dockeruser_action='/etc/fail2ban/action.d/A-Box-wallos-dockeruser.conf'
    [[ -n "$wmode" ]] || wmode=$(wallos_state_value MODE 2>/dev/null || true)
    if [[ "$wmode" == https ]]; then
        # The jail watches Caddy's access log and bans on the public
        # port; the action port is the public (Caddy) port.
        local _pp=''; _pp=$(wallos_state_value PUBPORT 2>/dev/null || true)
        [[ "$_pp" =~ ^[0-9]+$ ]] && port="$_pp"
    fi
    # Localhost-only Wallos cannot be reached remotely; no jail needed.
    # S149 (amended by F05): cftunnel also binds loopback but IS
    # publicly reachable through the tunnel, so it is NOT dropped
    # here — it gets its own handling below (no DOCKER-USER jail can
    # bite tunneled traffic); only a true local install drops it here.
    if [[ "$bind_address" == 127.0.0.1 && "$wmode" != https && "$wmode" != cftunnel ]]; then
        rm -f -- "$jail" 2>/dev/null || true
        # A running fail2ban keeps the removed jail (and its bans)
        # until reloaded; reload, and restart only if the jail survives
        # the reload, so the localhost-only switch takes effect now.
        if command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban-client reload >/dev/null 2>&1 || true
            if fail2ban-client status A-Box-wallos >/dev/null 2>&1; then
                fail2ban-client restart >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi
    # F05 (R1C15-05): cftunnel mode gets no DOCKER-USER jail. The
    # tunnel daemon runs on the host and reaches the container
    # through loopback, so that traffic traverses OUTPUT, never
    # FORWARD/DOCKER-USER — a DOCKER-USER ban can never match it.
    # The container-side log also sees only the local proxy, never
    # the real client (visible only at Cloudflare's edge), so there
    # is no host-visible client IP to ban at all. Installing the
    # jail would pretend protection that cannot bite; drop any
    # stale jail instead and leave edge/app-layer protection to
    # Cloudflare and Wallos itself.
    if [[ "$wmode" == cftunnel ]]; then
        rm -f -- "$jail" 2>/dev/null || true
        if command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban-client reload >/dev/null 2>&1 || true
            if fail2ban-client status A-Box-wallos >/dev/null 2>&1; then
                fail2ban-client restart >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi
    command -v fail2ban-client >/dev/null 2>&1 || return 0
    command -v docker >/dev/null 2>&1 || return 0
    # U119: container-mode bans are iptables DOCKER-USER rules (see below);
    # without the iptables binary such a jail could never bite.
    if [[ "$wmode" != https ]]; then command -v iptables >/dev/null 2>&1 || return 0; fi
    local upperdir logpath
    if [[ "$wmode" == https ]]; then
        logpath="$WALLOS_CADDY_LOG"
        # fail2ban needs the log file to exist; Caddy creates it on
        # start, but make sure an idle system still gets a jail.
        # R14-F15-01: create atomically (noclobber) and never through
        # a symlink: the -e check and the truncate were not atomic, so
        # a symlink swapped in (or pre-placed dangling) let root
        # truncate the link target. noclobber refuses a symlink whose
        # target exists, a dangling symlink, and an existing file.
        [[ -e "$logpath" ]] || ( [[ ! -L "$logpath" ]] && set -o noclobber && : > "$logpath" ) 2>/dev/null || return 0
    else
        # 2hp: Docker 29 with the containerd snapshotter exposes no
        # GraphDriver, so the old inspect-only lookup always came back
        # empty and the jail was silently skipped. Resolve the log
        # through the merged view first (stable across restarts), then
        # the writable layer. If nothing resolves, fail LOUDLY: a
        # missing jail must never again look like protection.
        local _mroot=''
        _mroot=$(wallos_container_mergeddir 2>/dev/null || true)
        if [[ -n "$_mroot" ]]; then
            logpath="$_mroot/var/log/nginx/access.log"
        else
            upperdir=$(wallos_container_upperdir 2>/dev/null || true)
            if [[ -z "$upperdir" || ! -d "$upperdir" ]]; then
                msg "${YELLOW}[!] Wallos fail2ban jail NOT created: cannot locate the container log path (Docker exposes no GraphDriver UpperDir and no containerd snapshotter path). Login brute-force protection is OFF.${NC}"
                return 1
            fi
            logpath="$upperdir/var/log/nginx/access.log"
        fi
        # The log file appears at nginx start; create the empty file
        # if missing so the jail is built even before the first
        # request (creating through the merged view lets the overlay
        # do a proper copy-up; through the upperdir it lands in the
        # writable layer directly).
        if [[ ! -e "$logpath" ]]; then
            mkdir -p -- "$(dirname -- "$logpath")" 2>/dev/null || true
            # R14-F15-01: create atomically (noclobber) and never
            # through a symlink: the -e check and the truncate were
            # not atomic, so a symlink swapped in after the check (or
            # pre-placed dangling) let root truncate the link target.
            ( [[ ! -L "$logpath" ]] && set -o noclobber && : > "$logpath" ) 2>/dev/null || {
                msg "${YELLOW}[!] Wallos fail2ban jail NOT created: cannot create $logpath. Login brute-force protection is OFF.${NC}"
                return 1
            }
        fi
    fi
    local backend action
    backend=$(firewall_backend 2>/dev/null || true)
    case "$backend" in
        firewalld) action='firewallcmd-multiport' ;;
        ufw) action='ufw' ;;
        iptables) action='iptables-multiport' ;;
        *) return 0 ;;
    esac
    # U119: the backend-native action is only checked in https mode. In
    # container mode the ban is always an iptables DOCKER-USER rule (below),
    # so the iptables action config is the one that must exist.
    # R5C15-03: container mode no longer uses a stock action
    # (the custom dockeruser action below is written by us);
    # only https mode still needs its stock action file.
    if [[ "$wmode" == https ]]; then
        [[ -r "/etc/fail2ban/action.d/${action}.conf" ]] || return 0
    fi
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban/action.d || return 0
    assert_abox_auxiliary_safe "$filter" 2>/dev/null || return 0
    assert_abox_auxiliary_safe "$jail" 2>/dev/null || return 0
    assert_abox_auxiliary_safe "$dockeruser_action" 2>/dev/null || return 0
    if [[ "$wmode" == https ]]; then
        # Caddy JSON access log: remote_ip comes first in the line.
        # Failed Wallos logins are POST /login.php answered 200; a
        # successful login redirects (302), so only 200s are counted
        # (verified against upstream login.php, 2026-10-20).
        write_file_atomically_from_stdin "$filter" 644 <<'EOF_WF2B_FILTER_HTTPS' || return 0
# Managed by A-Box
[Definition]
# H-19: Caddy JSON access lines carry the time only as "ts":<epoch>;
# without this datepattern fail2ban detects no date at all (verified
# with fail2ban-regex 1.0.2 on real-format Caddy JSON lines).
datepattern = "ts":\s*{EPOCH}
failregex = "remote_ip":\s*"<HOST>".*"method":\s*"POST".*"uri":\s*"/(?:/|./)?login\.php(\?[^\"]*)?".*"status":\s*200
ignoreregex =
EOF_WF2B_FILTER_HTTPS
    else
        # Same login.php semantics as the HTTPS filter (verified
        # against upstream login.php, 2026-10-20): a failed login is
        # answered 200 (form re-rendered), a success redirects (302).
        # Matching any status would ban ten successful logins in 10 min.
        write_file_atomically_from_stdin "$filter" 644 <<'EOF_WF2B_FILTER' || return 0
# Managed by A-Box
[Definition]
failregex = ^<HOST> - \S+ \[[^\]]*\] "POST /(?:/|./)?login\.php(\?\S*)? HTTP/[0-9.]+" 200 [0-9]+
ignoreregex =
EOF_WF2B_FILTER
    fi
    if command -v fail2ban-regex >/dev/null 2>&1; then
        # 2hp: prove the filter matches a real failed-login line before
        # the jail goes live; a filter that matches nothing (e.g. the
        # old \[[^\]]+\] after DateDetector strips the date) must never
        # again ship as protection. Fail closed: no jail, loud warning.
        # H-19: https mode was previously skipped entirely; its sample
        # is a real-format Caddy JSON access line (encoder format json;
        # field order per Caddy docs: level, ts, logger, msg, request,
        # duration, size, status).
        local _sample=''
        _sample=$(umask 077; mktemp /tmp/A-Box-wallos-f2b-sample.XXXXXX) || return 1
        if [[ "$wmode" == https ]]; then
            printf '%s\n' '{"level":"info","ts":1781609400.1234,"logger":"http.log.access.wallos-access","msg":"handled request","request":{"remote_ip":"203.0.113.7","remote_port":"52314","client_ip":"203.0.113.7","proto":"HTTP/1.1","method":"POST","host":"203.0.113.5","uri":"/login.php","headers":{"Content-Type":["application/x-www-form-urlencoded"]}},"user_id":"","duration":0.002345,"size":1234,"status":200,"resp_headers":{"Content-Type":["text/html; charset=UTF-8"]}}' > "$_sample" || { rm -f -- "$_sample"; return 1; }
        else
            printf '%s\n' '203.0.113.7 - - [06/Nov/2026:10:00:00 +0000] "POST /login.php HTTP/1.1" 200 1234' > "$_sample" || { rm -f -- "$_sample"; return 1; }
            printf '%s\n' '203.0.113.8 - - [06/Nov/2026:10:00:00 +0000] "POST //login.php HTTP/1.1" 200 1234' >> "$_sample" || { rm -f -- "$_sample"; return 1; }
        fi
        local _f2b_out
        _f2b_out=$(fail2ban-regex --print-all-matched "$_sample" A-Box-wallos 2>&1 || true)
        # 07f-M02: grepping the whole output for the sample IP passes
        # on zero matches -- --print-all-matched shows the sample
        # lines as unmatched lines too. Parse the `Lines:` summary's
        # matched count instead (same shape as the main script's
        # self-check): https has 1 sample line, the rest 2; an
        # unparseable summary fails closed.
        local _f2b_summary='' _f2b_matched='' _f2b_need=1
        [[ "$wmode" != https ]] && _f2b_need=2
        _f2b_summary=$(grep -E '^[[:space:]]*Lines: [0-9]+ lines?, [0-9]+ ignored, [0-9]+ matched, [0-9]+ missed' <<< "$_f2b_out" | tail -n 1)
        _f2b_matched=$(sed -nE 's/^[[:space:]]*Lines: [0-9]+ lines?, [0-9]+ ignored, ([0-9]+) matched, [0-9]+ missed.*/\1/p' <<< "$_f2b_summary")
        if [[ ! "$_f2b_matched" =~ ^[0-9]+$ ]] || (( _f2b_matched < _f2b_need )); then
            rm -f -- "$_sample" "$jail" "$filter"
            # R55b-M2: deleting the config does not unload a jail
            # the daemon already runs; stop it explicitly so the
            # runtime matches the "protection OFF" message.
            # `stop <JAIL>` is surgical (unlike a server restart)
            # and works even when the on-disk config is invalid.
            if command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client stop A-Box-wallos >/dev/null 2>&1 || true
                if fail2ban-client status A-Box-wallos >/dev/null 2>&1; then
                    msg "${YELLOW}[!] Wallos fail2ban jail could not be stopped; it may still be monitoring the old log path.${NC}"
                fi
            fi
            msg "${YELLOW}[!] Wallos fail2ban jail NOT created: the login filter matches no failed-login line. Login brute-force protection is OFF.${NC}"
            return 1
        fi
        rm -f -- "$_sample"
    fi
    if [[ "$wmode" != https ]]; then
        # U119+U120 container mode: the Wallos port is Docker-published, so
        # traffic is DNAT'd and traverses FORWARD/DOCKER-USER, never INPUT.
        # The backend-native actions cannot target DOCKER-USER (ufw has no
        # chain parameter; firewalld does not manage docker's chains), so
        # the ban is always an iptables-multiport DOCKER-USER rule,
        # regardless of which backend was detected. (The https mode is
        # different: Caddy is a host process, where INPUT is correct.)
        # U120: after DNAT the destination port is the container's 80, not
        # the published port, so the rule matches port 80. The jail's
        # `port` line keeps the published port for display only.
        # R5C15-03: the stock iptables-multiport DOCKER-USER
        # rule matches post-DNAT port 80, so a Wallos ban also
        # blocks other containers' HTTP. The custom dockeruser
        # action (written below) additionally matches the
        # conntrack original destination port, i.e. only
        # traffic originally destined for the published
        # Wallos port is banned.
        action="A-Box-wallos-dockeruser[name=A-Box-wallos, port=\"${port}\"]"
    elif [[ "$action" == 'ufw' ]]; then
        action="ufw[name=A-Box-wallos]"
    else
        action="${action}[name=A-Box-wallos, port=\"${port}\", protocol=tcp]"
    fi
    if [[ "$wmode" != https ]]; then
        # R5C15-03: custom DOCKER-USER action. ban/unban are
        # exact inverses (only -I vs -D differs) so unban
        # removes precisely what ban added. actioncheck only
        # verifies the chain exists; DOCKER-USER is owned by
        # Docker and must never be created or flushed here.
        # Unquoted heredoc: <port>/<ip> stay literal for fail2ban
        # to substitute from the jail action line; only the two
        # R55b-M1 destination fragments are interpolated.
        # R55b-M1: also match the original destination address.
        # Without --ctorigdst, another container published on the
        # same port at a different address is also blocked for a
        # banned IP. Only a specific (non-wildcard) bind can be
        # scoped: with 0.0.0.0/:: every address maps to Wallos, so
        # no other container can share the port at all.
        local _dst4='' _dst6=''
        if [[ "$bind_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$bind_address" != 0.0.0.0 ]]; then
            _dst4=" --ctorigdst $bind_address"
        elif [[ "$bind_address" == *:* && "$bind_address" != "::" ]]; then
            _dst6=" --ctorigdst $bind_address"
        fi
        write_file_atomically_from_stdin "$dockeruser_action" 644 <<EOF_WF2B_ACTION || return 0
# Managed by A-Box
[Definition]
actionstart =
actionstop =
actioncheck = iptables -n -L DOCKER-USER >/dev/null 2>&1
actionban = case "<ip>" in *:*) ip6tables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport <port>$_dst6 --dport 80 -s <ip> -j REJECT --reject-with icmp6-port-unreachable;; *) iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport <port>$_dst4 --dport 80 -s <ip> -j REJECT --reject-with icmp-port-unreachable;; esac
actionunban = case "<ip>" in *:*) ip6tables -D DOCKER-USER -p tcp -m conntrack --ctorigdstport <port>$_dst6 --dport 80 -s <ip> -j REJECT --reject-with icmp6-port-unreachable;; *) iptables -D DOCKER-USER -p tcp -m conntrack --ctorigdstport <port>$_dst4 --dport 80 -s <ip> -j REJECT --reject-with icmp-port-unreachable;; esac

[Init]
port = 80
EOF_WF2B_ACTION
    fi
    write_file_atomically_from_stdin "$jail" 644 <<EOF_WF2B_JAIL || return 0
# Managed by A-Box
[A-Box-wallos]
enabled = true
ignoreip = 127.0.0.1/8 ::1
port = ${port}
filter = A-Box-wallos
logpath = ${logpath}
backend = polling
maxretry = 10
findtime = 600
bantime = 86400
action = ${action}
EOF_WF2B_JAIL
    if ! validate_fail2ban_config >/dev/null 2>&1; then
        msg "${RED}Wallos fail2ban jail NOT created: fail2ban configuration validation failed. Login brute-force protection is OFF.${NC}" >&2
        rm -f -- "$jail"
        # R55b-M2: deleting the config does not unload a jail
        # the daemon already runs; stop it explicitly so the
        # runtime matches the "protection OFF" message.
        # `stop <JAIL>` is surgical (unlike a server restart)
        # and works even when the on-disk config is invalid.
        if command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban-client stop A-Box-wallos >/dev/null 2>&1 || true
            if fail2ban-client status A-Box-wallos >/dev/null 2>&1; then
                msg "${YELLOW}[!] Wallos fail2ban jail could not be stopped; it may still be monitoring the old log path.${NC}"
            fi
        fi
        return 1
    fi
    # 07f-M03: a failed restart used to be swallowed by `|| true`
    # and the function returned 0, so callers could not tell the
    # jail was written but never loaded. Report loudly (msg goes to
    # stdout, which the callers do not discard) and fail.
    local _f2b_restart_rc=0
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        systemctl restart fail2ban >/dev/null 2>&1 || _f2b_restart_rc=$?
    else
        rc-service fail2ban restart >/dev/null 2>&1 9>&- 10>&- || _f2b_restart_rc=$?
    fi
    if (( _f2b_restart_rc != 0 )); then
        msg "${RED}[!] Wallos fail2ban jail written but fail2ban restart failed (rc=${_f2b_restart_rc}); login brute-force protection is NOT live.${NC}"
        return 1
    fi
    return 0
}

wallos_public_urls() {
    local port="$1" ipv4 ipv6 host_ip
    local _cmode=''; _cmode=$(wallos_state_value MODE 2>/dev/null || true)
    if [[ "$_cmode" == cftunnel ]]; then
        local _ch=''; _ch=$(wallos_state_value CFHOST 2>/dev/null || true)
        if [[ -n "$_ch" ]]; then
            msg "${GREEN}$(tprintf wl_pu_url_cf "$_ch")${NC}"
            msg ''
            msg "${BOLD}$(tr_msg wl_pu_guide_cf_t)${NC}"
            msg "$(tr_msg wl_pu_guide_cf_1)"
            msg "$(tprintf wl_pu_guide_cf_2 "$port")"
            msg "$(tr_msg wl_pu_guide_cf_3)"
            return 0
        fi
    fi
    local _hmode=''; _hmode=$(wallos_state_value MODE 2>/dev/null || true)
    if [[ "$_hmode" == https ]] && is_service_running abox-wallos-caddy 2>/dev/null; then
        local _hp='' _hip=''
        _hp=$(wallos_state_value PUBPORT 2>/dev/null || true)
        # 07f-M01: use the preference-independent IPv4 lookup,
        # not get_public_ip: with IP_PREF=ipv6 the latter returns
        # an IPv6 address, but the Caddy certificate subject,
        # default SNI and sole Host route all use the IPv4 address
        # from wallos_public_ipv4, so an IPv6 URL is not a valid
        # entry point. The GLOBAL_PUBLIC_IP fallback is kept for a
        # stale-but-valid IPv4, but it must pass the same IPv4
        # shape gate (GLOBAL_PUBLIC_IP itself comes from the
        # preference-respecting SWR lookup, so it can be IPv6 too);
        # with no usable IPv4 the branch falls through to the
        # docker-inspect fallback below instead of printing a URL
        # that cannot serve the site.
        _hip=$(wallos_public_ipv4 2>/dev/null || true)
        [[ "$_hip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || _hip="${GLOBAL_PUBLIC_IP:-}"
        if [[ "$_hp" =~ ^[0-9]+$ && "$_hip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            msg "${GREEN}$(tprintf wl_pu_url_https "$_hip" "$_hp")${NC}"
            msg ''
            msg "${BOLD}$(tr_msg wl_pu_guide_https_t)${NC}"
            msg "$(tr_msg wl_pu_guide_https_1)"
            msg "$(tprintf wl_pu_guide_https_2 "$_hp")"
            if wallos_fail2ban_jail_active 2>/dev/null; then msg "$(tr_msg wl_pu_guide_https_3)"; else msg "$(tr_msg wl_pu_guide_https_3_off)"; fi
            return 0
        fi
    fi
    if [[ "$_hmode" == http ]]; then
        local _pip=''; _pip=$(get_public_ip 2>/dev/null || true); [[ -n "$_pip" ]] || _pip="${GLOBAL_PUBLIC_IP:-<VPS public IP>}"
        msg "${GREEN}$(tprintf wl_pu_url_http "$_pip" "$port")${NC}"
        msg ''
        msg "${BOLD}$(tr_msg wl_pu_guide_http_t)${NC}"
        msg "$(tr_msg wl_pu_guide_http_1)"
        msg "$(tprintf wl_pu_guide_http_2 "$port")"
        if wallos_fail2ban_jail_active 2>/dev/null; then msg "$(tr_msg wl_pu_guide_http_3)"; else msg "$(tr_msg wl_pu_guide_http_3_off)"; fi
        return 0
    fi
    host_ip=$(docker inspect -f '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostIp}}' wallos 2>/dev/null || true)
    # P3-8: handle empty binding and LAN-specific IPs explicitly (was: fell through to public-IP URL).
    if [[ -z "$host_ip" ]]; then
        msg "${YELLOW}$(tr_msg wl_pu_no_bind)${NC}"
        return 0
    fi
    if [[ "$host_ip" != 127.0.0.1 && "$host_ip" != 0.0.0.0 ]]; then
        msg "${GREEN}$(tprintf wl_pu_url_bound "$host_ip" "$port" "$host_ip")${NC}"
        return 0
    fi
    if [[ "$host_ip" == 127.0.0.1 ]]; then
        local _pub="${GLOBAL_PUBLIC_IP:-}"
        [[ -z "$_pub" ]] && _pub=$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
        [[ -z "$_pub" ]] && _pub="$(tr_msg wallos_public_urls_vps_ip)"
        local _who="${SUDO_USER:-$(whoami)}"
        msg "${GREEN}$(tprintf wl_pu_local_url "$port")${NC}"; msg "${YELLOW}$(tr_msg wl_pu_local_warn)${NC}"
        msg "${CYAN}$(tr_msg wl_pu_ssh_t)${NC}"; msg "  ssh -L $port:127.0.0.1:$port $_who@$_pub"; msg "${CYAN}$(tprintf wl_pu_ssh_then "$port")${NC}"
        return 0
    fi
    ipv4=$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    ipv6=$(curl -6fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
    [[ -z "$ipv4" ]] || msg "${GREEN}$(tprintf wl_pu_url "$ipv4" "$port")${NC}"
    [[ -z "$ipv6" ]] || msg "${GREEN}$(tprintf wl_pu_url6 "$ipv6" "$port")${NC}"
    [[ -n "$ipv4" || -n "$ipv6" ]] || msg "${YELLOW}$(tprintf wl_pu_no_pub "$port")${NC}"
    if [[ "$host_ip" == 0.0.0.0 ]]; then
        msg ''
        msg "${BOLD}$(tr_msg wl_pu_guide_t)${NC}"
        msg "$(tr_msg wl_pu_guide_1)"
        msg "$(tprintf wl_pu_guide_2 "$port" "$port")"
        if wallos_fail2ban_jail_active 2>/dev/null; then msg "$(tr_msg wl_pu_guide_3)"; else msg "$(tr_msg wl_pu_guide_3_off)"; fi
    fi
}


install_wallos_caddy() {
    # R55b-M3: exact version comparison: a substring grep accepts
    # v2.11.70 as pinned v2.11.7, and `.` in the pattern is a regex
    # wildcard. Compare the first field of `caddy version` as a
    # plain string.
    if [[ -x /usr/local/bin/caddy ]] && [[ "$(/usr/local/bin/caddy version 2>/dev/null | awk '{print $1}')" == "v${WALLOS_CADDY_VERSION}" ]]; then
        return 0
    fi
    # R7-F15-5: refuse to overwrite a foreign caddy binary. The early
    # return above only recognizes a same-version binary; a
    # different-version (or non-executable, or dangling-link) foreign
    # binary would otherwise be replaced by the pinned download and
    # then marked A-Box-owned. Only a valid ownership marker proves
    # the binary is ours. (A dangling link is already refused by the
    # atomic installer, but this gate refuses before any download.)
    if [[ -e /usr/local/bin/caddy || -L /usr/local/bin/caddy ]] && [[ ! -f /etc/ddr/.abox-caddy-owned || -L /etc/ddr/.abox-caddy-owned ]]; then
        msg "${RED}$(tr_msg wl_caddy_external_conflict)${NC}"
        return 1
    fi
    get_architecture
    local want='' url='' tmp got
    case "$SB_ARCH" in
        amd64) want="$WALLOS_CADDY_SHA256_AMD64" ;;
        arm64) want="$WALLOS_CADDY_SHA256_ARM64" ;;
        *) msg "${RED}$(tprintf wl_caddy_arch "$SB_ARCH")${NC}"; return 1 ;;
    esac
    url="https://github.com/caddyserver/caddy/releases/download/v${WALLOS_CADDY_VERSION}/caddy_${WALLOS_CADDY_VERSION}_linux_${SB_ARCH}.tar.gz"
    tmp=$(mktemp -d /tmp/A-Box-caddy.XXXXXX) || return 1
    abox_run_wait 'Caddy download' curl -fL --proto =https --proto-redir =https --retry 2 --connect-timeout 15 -o "$tmp/caddy.tgz" "$url" || { rm -rf "$tmp"; msg "${RED}$(tr_msg wl_caddy_download)${NC}"; return 1; }
    got=$(sha256sum "$tmp/caddy.tgz" 2>/dev/null | awk '{print $1}')
    if [[ "$got" != "$want" ]]; then
        rm -rf "$tmp"; msg "${RED}$(tr_msg wl_caddy_sha)${NC}"; return 1
    fi
    tar -xzf "$tmp/caddy.tgz" -C "$tmp" caddy 2>/dev/null || { rm -rf "$tmp"; msg "${RED}$(tr_msg wl_caddy_unpack)${NC}"; return 1; }
    chmod 755 "$tmp/caddy" || { rm -rf "$tmp"; return 1; }
    "$tmp/caddy" version >/dev/null 2>&1 || { rm -rf "$tmp"; msg "${RED}$(tr_msg wl_caddy_exec)${NC}"; return 1; }
    install_binary_atomically "$tmp/caddy" /usr/local/bin/caddy || { rm -rf "$tmp"; msg "${RED}$(tr_msg wl_caddy_install)${NC}"; return 1; }
    # S-UNINSTALL-01 (cf. R7C9-01 for cloudflared): record A-Box
    # ownership so uninstall can tell an A-Box-installed binary from
    # a foreign same-version one that install_wallos_caddy
    # early-returned on. Best-effort: if the marker cannot be written,
    # uninstall conservatively keeps the binary instead of deleting a
    # possibly foreign one. The early return above deliberately
    # writes no marker.
    # R7-F15-5: the refusal gate above (before the download) already
    # rejects a foreign binary, so this marker is only ever written
    # for a binary this function installed.
    touch /etc/ddr/.abox-caddy-owned 2>/dev/null || true
    rm -rf "$tmp"
}

wallos_https_write_unit() {
    # R16-F15-04: refuse a foreign same-name unit/script before
    # overwriting it (same ownership helper the teardowns use).
    _wallos_front_unit_owned_or_absent abox-wallos-caddy || {
        msg "${RED}Refusing to overwrite a foreign 'abox-wallos-caddy' service; it is not A-Box-managed.${NC}"
        return 1
    }
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin "/etc/systemd/system/abox-wallos-caddy.service" 600 <<'EOF_WCADDY' || return 1
# Managed by A-Box
[Unit]
Description=A-Box Wallos HTTPS front (Caddy)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Environment=XDG_DATA_HOME=/etc/ddr/wallos-caddy/data
Environment=XDG_CONFIG_HOME=/etc/ddr/wallos-caddy/conf
ExecStart=/usr/local/bin/caddy run --config /etc/ddr/wallos-caddy.json
Restart=on-failure
RestartSec=5
StandardOutput=append:/etc/ddr/abox-wallos-caddy.log
StandardError=append:/etc/ddr/abox-wallos-caddy.log

[Install]
WantedBy=multi-user.target
EOF_WCADDY
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        # R8C15-03: a failed boot registration must fail setup, not be swallowed.
        systemctl enable abox-wallos-caddy.service >/dev/null 2>&1 || return 1
        systemctl restart abox-wallos-caddy.service >/dev/null 2>&1 || return 1
    else
        write_file_atomically_from_stdin "/etc/init.d/abox-wallos-caddy" 755 <<'EOF_WCADDY_RC' || return 1
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Wallos HTTPS front (Caddy)"
command="/usr/local/bin/caddy"
command_args="run --config /etc/ddr/wallos-caddy.json"
# C9-N02: command_env is not an OpenRC runscript variable; export the
# daemon's environment instead (see argo_write_unit).
export XDG_DATA_HOME=/etc/ddr/wallos-caddy/data XDG_CONFIG_HOME=/etc/ddr/wallos-caddy/conf
command_background="yes"
pidfile="/run/abox-wallos-caddy.pid"
output_log="/etc/ddr/abox-wallos-caddy.log"
error_log="/etc/ddr/abox-wallos-caddy.log"
depend() { need net; }
EOF_WCADDY_RC
        chmod +x "/etc/init.d/abox-wallos-caddy" || return 1
        # R8C15-03: a failed boot registration must fail setup, not be swallowed.
        rc-update add abox-wallos-caddy default >/dev/null 2>&1 || return 1
        rc-service abox-wallos-caddy restart >/dev/null 2>&1 9>&- 10>&- || return 1
    fi
}

# R14-F15-04: tri-state confirmed-stopped check for the Wallos front
# teardowns. is_service_running returns 1 both when the service is
# confirmed stopped and when the state query itself fails, so it cannot
# gate a teardown: a failed query looked like a stopped front and the
# unit (and, for the tunnel, the token) was deleted under a
# still-listening service. Returns 0 only on a confirmed stopped state.
_wallos_service_confirmed_stopped() {
    local _state
    _state=$(service_active_state_value "$1" 2>/dev/null) || return 1
    [[ "$_state" == 0 ]]
}

# R15-F15-04: ownership gate for the Wallos front teardowns. True iff the
# named front unit is absent (nothing to tear down) or is a regular file
# carrying the A-Box marker. A foreign unit sharing the name, a symlink, or
# any non-regular path refuses: the caller must not stop or delete a service
# an administrator replaced with an external deployment. Mirrors the
# argo_remove_unit marker check; unlike it, an absent unit is OK here
# (teardown returns 0 when the front is absent).
# 07f-H01: systemd resolves a unit by its full load path, so the check
# must cover every load path, not just /etc: a same-name foreign unit in
# /run, /usr/local/lib, /usr/lib or /lib is the effective unit when /etc
# has none (teardown would stop it by name), and a write to /etc would
# shadow it. Any load-path copy that exists must be a regular file
# carrying the marker; any foreign copy (or symlink / non-regular path)
# refuses, even when /etc already holds an A-Box copy.
_wallos_front_unit_owned_or_absent() {
    local _unit
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # R56-M1: ask systemd for the actually-loaded unit first
        # (same idiom as systemd_same_name_unit_path): a same-named
        # foreign unit in a transient/generator path is invisible
        # to a fixed-directory scan, yet teardown stops it by name.
        _unit=$(systemd_same_name_unit_path "$1" 2>/dev/null || true)
        if [[ -n "$_unit" ]]; then
            [[ -f "$_unit" && ! -L "$_unit" ]] && grep -Fxq '# Managed by A-Box' "$_unit" 2>/dev/null
            return $?
        fi
        return 0
    else
        _unit="/etc/init.d/${1}"
        [[ -e "$_unit" || -L "$_unit" ]] || return 0
        [[ -f "$_unit" && ! -L "$_unit" ]] && grep -Fxq '# Managed by A-Box' "$_unit" 2>/dev/null
    fi
}

wallos_https_teardown() { # stop the HTTPS front, drop its config/data; returns 1 if the front is still running or if disable/removal fails
    # R15-F15-04: refuse a foreign unit before stopping it (see helper above).
    _wallos_front_unit_owned_or_absent abox-wallos-caddy || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl stop abox-wallos-caddy.service >/dev/null 2>&1 || true
        # S148: verify the stop before removing the unit: deleting the
        # unit of a still-running front orphans it and leaves the
        # public entrance live while the caller reports it closed.
        # R14-F15-04: require a confirmed stopped state; a failed
        # state query must not look like a stopped front.
        if ! _wallos_service_confirmed_stopped abox-wallos-caddy; then
            return 1
        fi
        systemctl disable abox-wallos-caddy.service >/dev/null 2>&1 || {
            # R14-02: a failed disable is OK only if no boot
            # registration remains (repeat / partial teardown).
            # R56-M4: check EVERY wants link, and count a dangling
            # symlink (-L) as residue too: -e is false for a
            # dangling link, and checking only [0] misses later links.
            local _w _wants=(/etc/systemd/system/*.wants/abox-wallos-caddy.service)
            for _w in "${_wants[@]}"; do
                [[ -e "$_w" || -L "$_w" ]] && return 1
            done
        }
        rm -f "/etc/systemd/system/abox-wallos-caddy.service" || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
    else
        rc-service abox-wallos-caddy stop >/dev/null 2>&1 || true
        # R14-F15-04: require a confirmed stopped state; a failed
        # state query must not look like a stopped front.
        if ! _wallos_service_confirmed_stopped abox-wallos-caddy; then
            return 1
        fi
        rc-update del abox-wallos-caddy default >/dev/null 2>&1 || {
            # R14-02: same idempotency rule for the runlevel link.
            # R56-M4: a dangling link is residue too (-e is false
            # for a dangling link).
            [[ ! -e /etc/runlevels/default/abox-wallos-caddy && ! -L /etc/runlevels/default/abox-wallos-caddy ]] || return 1
        }
        rm -f "/etc/init.d/abox-wallos-caddy" || return 1
    fi
    # R14-02: the required config must go; a stale log need not fail.
    rm -f /etc/ddr/wallos-caddy.json || return 1
    rm -f /etc/ddr/abox-wallos-caddy.log "$WALLOS_CADDY_LOG" || true
    # Keep /etc/ddr/wallos-caddy (certificates + ACME account): a
    # reinstall reuses the stored certificate instead of issuing a
    # new one, so repeated installs stop burning the Let's Encrypt
    # budget of 5 certificates per exact identifier set per week
    # (2026-11-07: five https installs in seven days hit HTTP 429
    # and no certificate could be issued until the window reopened).
    # Full uninstall still wipes it: do_cleanup destroys /etc/ddr
    # wholesale after this teardown returns.
    return 0
}

# Real TLS handshake probe against the local Caddy listener.
# $1=port $2=servername ("" sends no SNI at all — the way browsers and
# curl treat IP-literal URLs). Returns 0 only if a TLS session is
# established without a fatal alert; 2 when openssl is unavailable.
wallos_tls_probe() {
    local port="$1" sni="${2:-}" host="${3:-127.0.0.1}" out=''
    command -v openssl >/dev/null 2>&1 || return 2
    if [[ -n "$sni" ]]; then
        out=$(printf '' | timeout 12 openssl s_client -connect "${host}:${port}" -servername "$sni" 2>&1 || true)
    else
        out=$(printf '' | timeout 12 openssl s_client -connect "${host}:${port}" 2>&1 || true)
    fi
    printf '%s' "$out" | grep -qiE 'alert (internal error|handshake failure|protocol version)' && return 1
    printf '%s' "$out" | grep -q 'CONNECTED(' || return 1
    # CONNECTED( is printed before the handshake completes; require a
    # negotiated cipher as positive proof a session was established
    # (failed handshakes report "Cipher is (NONE)").
    printf '%s' "$out" | grep -qE 'Cipher is [A-Za-z0-9]' || return 1
    return 0
}

# Both handshake legs with a few retries while Caddy settles. On failure
# echoes the failing leg names and returns 1. Loopback first: a host
# without NAT loopback fails public-IP probes even when the local
# listener is fine, so loopback success alone passes the check; the
# public-IP legs run only as a fallback and their failure is reported,
# not mistaken for a local failure.
wallos_tls_handshake_check() { # $1=port $2=ip
    local port="$1" ip="$2" _try=0 legs=''
    command -v openssl >/dev/null 2>&1 || return 2
    while (( _try < 5 )); do
        if wallos_tls_probe "$port" "$ip" '127.0.0.1' && wallos_tls_probe "$port" '' '127.0.0.1'; then return 0; fi
        sleep 3; _try=$((_try + 1))
    done
    if wallos_tls_probe "$port" "$ip" "$ip" && wallos_tls_probe "$port" '' "$ip"; then return 0; fi
    wallos_tls_probe "$port" "$ip" '127.0.0.1' || legs="${legs} SNI(loopback)"
    wallos_tls_probe "$port" '' '127.0.0.1' || legs="${legs} no-SNI(loopback)"
    wallos_tls_probe "$port" "$ip" "$ip" || legs="${legs} SNI(public)"
    wallos_tls_probe "$port" '' "$ip" || legs="${legs} no-SNI(public)"
    printf '%s' "${legs# }"
    return 1
}

# R14C15-02: true (0) iff an A-Box-owned 80/tcp rule already exists;
# 1 iff certainly absent; 2 iff the state cannot be determined.
wallos_https_80_owned() {
    local backend rc rc6
    backend=$(firewall_backend 2>/dev/null) || return 2
    case "$backend" in
        ufw)
            ufw_owned_rule_exists "80" "tcp"
            ;;
        firewalld)
            [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]] || return 1
            validate_native_firewall_state_file "$ABOX_FW_STATE" 2>/dev/null || return 2
            if grep -qF 'firewalld|80|tcp|runtime' "$ABOX_FW_STATE" 2>/dev/null || grep -qF 'firewalld|80|tcp|permanent' "$ABOX_FW_STATE" 2>/dev/null; then
                return 0
            fi
            return 1
            ;;
        iptables)
            # NOTE: never capture rc after a bare if without else: such an
            # if returns 0 when the condition is false, masking the real rc.
            iptables_rule_check "$IPT" INPUT -p tcp --dport 80 -m comment --comment "A-Box-80-tcp" -j ACCEPT
            rc=$?
            [[ "$rc" == 0 ]] && return 0
            [[ "$rc" == 1 ]] || return 2
            if command -v ip6tables >/dev/null 2>&1 && _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                iptables_rule_check "$IPT6" INPUT -p tcp --dport 80 -m comment --comment "A-Box-80-tcp" -j ACCEPT
                rc6=$?
                [[ "$rc6" == 0 ]] && return 0
                [[ "$rc6" == 1 ]] || return 2
            fi
            return 1
            ;;
        *) return 2 ;;
    esac
}

# R14C15-02: revoke a newly added 80/tcp allow on setup failure.
# $1 = 1 iff this setup newly added the rule; otherwise a no-op.
wallos_https_80_rollback() {
    [[ "${1:-0}" == 1 ]] || return 0
    remove_abox_native_firewall_rule "80" "tcp" >/dev/null 2>&1 || msg "${YELLOW}[!] Failed to revoke the newly added 80/tcp allow; remove it manually.${NC}"
}

# F15-1: true (0) only when the live Caddy config already proxies
# public port $1 to internal 127.0.0.1:$2. A missing/unreadable file,
# missing jq, bad JSON, or any mismatch returns 1 (setup must run).
_wallos_caddy_config_matches() { # $1=public port $2=internal port
    local pubport="${1:-}" internal="${2:-}" cfg='/etc/ddr/wallos-caddy.json' listen='' dial='' _jq_caddy=''
    [[ "$pubport" =~ ^[0-9]+$ ]] || return 1
    [[ "$internal" =~ ^[0-9]+$ ]] || return 1
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # M-6 (AP-01 C-leg): $cfg is a persistent live file, not installed
    # in this invocation; comments (hand edit / restore) make bare jq
    # fail, so a matching config misreports as no-match and the caller
    # tears down and redoes the whole HTTPS setup. Strip once.
    _jq_caddy=$(jsonc_strip_comments "$cfg" 2>/dev/null || true)
    listen=$(printf '%s' "$_jq_caddy" | jq -r '.apps.http.servers.wallos.listen[0] // empty' 2>/dev/null) || return 1
    dial=$(printf '%s' "$_jq_caddy" | jq -r '.apps.http.servers.wallos.routes[0].handle[0].upstreams[0].dial // empty' 2>/dev/null) || return 1
    [[ "$listen" == ":$pubport" && "$dial" == "127.0.0.1:$internal" ]]
}

# M-28: public-IPv4 lookup that ignores the user's IP preference
# (/etc/ddr/.ip-pref). Wallos HTTPS needs the IPv4 address itself
# for its IP certificate: with IP_PREF=ipv6, get_public_ip returns
# the host's IPv6 address and the IPv4 check below used to misreport
# "no public IPv4". Tries the cache first (IPv4 entries only, same
# ownership/mode/TTL gates as read_cached_public_ip, minus the
# preference gate), then a fresh IPv4-only probe.
wallos_public_ipv4() {
    local ip='' now mtime age _ip2=''
    if [[ -r "$PUBLIC_IP_CACHE" && -f "$PUBLIC_IP_CACHE" && ! -L "$PUBLIC_IP_CACHE" ]] \
        && [[ "$(stat -c %u:%g "$PUBLIC_IP_CACHE" 2>/dev/null || true)" == 0:0 ]] \
        && [[ "$(stat -c %a "$PUBLIC_IP_CACHE" 2>/dev/null || true)" =~ ^0?600$ ]]; then
        ip=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
        now=$(date +%s); mtime=$(stat -c %Y "$PUBLIC_IP_CACHE" 2>/dev/null || echo 0); age=$(( now - mtime ))
        # R13-01: same snapshot race as read_cached_public_ip --
        # re-read and require identical bytes before serving.
        _ip2=$(head -n 1 "$PUBLIC_IP_CACHE" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$_ip2" == "$ip" ]] && valid_public_ip "$ip" && (( age >= 0 && age <= PUBLIC_IP_CACHE_TTL )); then
            printf '%s\n' "$ip"
            return 0
        fi
    fi
    __abox_try_v4 && return 0
    return 1
}

wallos_https_setup() { # $1 = public port, $2 = internal container port
    local pubport="$1" internal="$2" pub_ip='' tmp_json='' tmpd='' _t=0 _cert='' _code='' _http80_new=0 _http80_pre=2 _http80_post=2 _cand=''
    # M-28: must not go through get_public_ip: with IP_PREF=ipv6 it
    # returns an IPv6 address and this setup would misreport "no
    # public IPv4" on a dual-stack host that has one.
    pub_ip=$(wallos_public_ipv4 2>/dev/null || true)
    if [[ ! "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        msg "${RED}$(tr_msg wl_hs_no_ipv4)${NC}"
        return 1
    fi
    install_wallos_caddy || return 1
    mkdir -p /etc/ddr/wallos-caddy/data /etc/ddr/wallos-caddy/conf || return 1
    tmpd=$(mktemp -d /tmp/wallos-caddy.XXXXXX) || return 1
    tmp_json="$tmpd/wallos-caddy.json"
    # Explicit automation policy is REQUIRED: with a plain Caddyfile,
    # IP subjects silently fall back to Caddy's internal CA (verified
    # locally 2026-10-20). The JSON policy pins subject + shortlived.
    # tls_connection_policies.default_sni is equally load-bearing:
    # browsers and curl send NO SNI for IP-literal URLs, and certmagic's
    # no-SNI fallback selects by the connection's local address — on
    # 1:1-NAT clouds (Lightsail/EC2) that is the PRIVATE address, which
    # matches no certificate, so every no-SNI handshake died with
    # internal_error (root-caused and A/B-verified locally 2026-10-21).
    if ! jq -n --arg ip "$pub_ip" --argjson pub "$pubport" --arg dial "127.0.0.1:${internal}" \
            --arg ca "${WALLOS_CADDY_CA_URL:-}" --arg caroot "${WALLOS_CADDY_CA_ROOT:-}" \
            --arg logf "$WALLOS_CADDY_LOG" '
        {
          admin: {disabled: true},
          logging: {logs: {
            "wallos-access": {writer: {output: "file", filename: $logf}, encoder: {format: "json"}}
          }},
          apps: {
            tls: {automation: {policies: [
              {subjects: [$ip], issuers: [
                ({module: "acme", profile: "shortlived"}
                 + (if $ca != "" then {ca: $ca} else {} end)
                 + (if $caroot != "" then {trusted_roots_pem_files: [$caroot]} else {} end))
              ]}
            ]}},
            http: {servers: {wallos: {
              listen: [(":" + ($pub | tostring))],
              logs: {logger_names: {($ip): "wallos-access"}, default_logger_name: "wallos-access"},
              tls_connection_policies: [{default_sni: $ip}],
              routes: [{match: [{host: [$ip]}],
                        handle: [{handler: "reverse_proxy", upstreams: [{dial: $dial}]}],
                        terminal: true}]
            }}}
          }
        }' > "$tmp_json"; then
        rm -f "$tmp_json"; rm -rf "$tmpd"; msg "${RED}$(tr_msg wl_hs_cfg_fail)${NC}"; return 1
    fi
    install_file_atomically "$tmp_json" /etc/ddr/wallos-caddy.json 600 || { rm -f "$tmp_json"; rm -rf "$tmpd"; return 1; }
    rm -f "$tmp_json"; rm -rf "$tmpd"
    # ACME HTTP-01 for the IP certificate needs inbound 80/tcp on
    # the host (certmagic listens there during issuance). M-28: 80/tcp
    # is shared with the Hysteria HTTP-01 challenge (altPort: 80);
    # reclaim must check that first (wallos_fw_reclaim_registered).
    # Open it
    # through the standard owned-rule path before starting Caddy;
    # failure only warns — issuance may still succeed where the
    # host firewall already permits 80.
    # R14C15-02: record whether 80/tcp is already owned before opening it,
    # so a later failure revokes only a rule this setup newly added.
    wallos_https_80_owned; _http80_pre=$?
    if [[ "$_http80_pre" == 2 ]]; then
        # R56-M2: unknown pre-state must not lead to an untracked
        # rule: allowPort could add a rule that neither the rollback
        # nor the registration below would ever see (_http80_new
        # stays 0). Skip the firewall change and warn; issuance may
        # still succeed where 80 is already open.
        msg "${YELLOW}[!] Wallos HTTPS setup: the 80/tcp firewall state could not be determined; skipping the firewall change so no untracked rule is added.${NC}"
    else
        ( allowPort 80 tcp ) >/dev/null 2>&1 || msg "${YELLOW}[!] $(tr_msg wl_fw_80_fail)${NC}"
    fi
    wallos_https_80_owned; _http80_post=$?
    if [[ "$_http80_pre" == 1 && "$_http80_post" == 0 ]]; then _http80_new=1; fi
    wallos_https_write_unit || { msg "${RED}$(tr_msg wl_hs_unit_fail)${NC}"; wallos_https_80_rollback "$_http80_new"; return 1; }
    # Wait for the IP certificate (ACME HTTP-01 runs over port 80).
    while (( _t < 120 )); do
        _cert=''
        # R56-M3: check EVERY candidate, not just the first one: a
        # preserved store may hold an expired shortlived cert
        # (6-day validity) ahead of a valid one (e.g. after a CA
        # change), and the old `head -1` never looked past it.
        # NUL-separated traversal: certificate paths come from the
        # filesystem and must not be split on whitespace.
        while IFS= read -r -d '' _cand; do
            # Accept only a still-valid cert, so Caddy gets the
            # window to renew instead of the TLS check failing on
            # a dead certificate. Without openssl, accept the file
            # as before.
            if ! command -v openssl >/dev/null 2>&1 || openssl x509 -in "$_cand" -noout -checkend 0 2>/dev/null; then
                _cert="$_cand"
                break
            fi
        done < <(find /etc/ddr/wallos-caddy/data/caddy/certificates -name "${pub_ip}.crt" -print0 2>/dev/null)
        if [[ -n "$_cert" ]]; then
            break
        fi
        is_service_running abox-wallos-caddy 2>/dev/null || break
        sleep 3; _t=$((_t + 3))
    done
    if [[ -z "$_cert" ]]; then
        # Preserve the ACME evidence before the caller's teardown
        # deletes the live log: the timeout message cites this
        # preserved copy, which the teardown never removes.
        local _hs_log='/etc/ddr/abox-wallos-caddy.log' _hs_rl=''
        if [[ -f "$_hs_log" ]] && cp "$_hs_log" /etc/ddr/abox-wallos-caddy.failed.log 2>/dev/null; then
            _hs_log='/etc/ddr/abox-wallos-caddy.failed.log'
        fi
        _hs_rl=$(grep -o 'retry after [0-9][0-9-]* [0-9:]* UTC' "$_hs_log" 2>/dev/null | tail -1 || true)
        msg "${RED}$(tprintf wl_hs_cert_timeout "$_hs_log")${NC}"
        if [[ -n "$_hs_rl" ]]; then
            msg "${RED}$(tprintf wl_hs_cert_ratelimit "${_hs_rl#retry after }")${NC}"
        fi
        wallos_https_80_rollback "$_http80_new"
        return 1
    fi
    # A successful issuance supersedes any earlier failure record.
    rm -f /etc/ddr/abox-wallos-caddy.failed.log 2>/dev/null || true
    # Readiness probe via loopback with SNI pinning: dialing the
    # public IP from the host itself fails on NAT-hairpin clouds
    # (e.g. Lightsail) even when external access is perfectly fine.
    _code=$(curl -ks --max-time 6 --resolve "${pub_ip}:${pubport}:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${pub_ip}:${pubport}/" 2>/dev/null || true)
    if [[ ! "$_code" =~ ^[0-9]+$ || "$_code" == '000' ]]; then
        msg "${YELLOW}$(tprintf wl_hs_probe_warn "$pubport")${NC}"
    fi
    # Real-handshake self-check. The probe above pins SNI via --resolve,
    # which is NOT how browsers reach an IP URL: they send no SNI, and
    # without default_sni those handshakes were rejected even while this
    # probe passed (the false "healthy" of 2026-10-21). Probe both legs
    # the way real clients connect and shout in red when one fails.
    if command -v openssl >/dev/null 2>&1; then
        local _legs=''
        if _legs=$(wallos_tls_handshake_check "$pubport" "$pub_ip"); then
            msg "${GREEN}$(tr_msg wl_hs_tls_ok)${NC}"
        else
            msg "${RED}$(tprintf wl_hs_tls_fail "$_legs")${NC}"
            wallos_https_80_rollback "$_http80_new"
            return 1
        fi
    fi
    # M-28: the front is live, so the 80/tcp opening made above is
    # now a lasting one; record it for later switch/uninstall
    # reclaim (a later failure teardown removes the rule again and
    # the stale registry line is dropped on the next reclaim).
    if (( _http80_new == 1 )); then wallos_fw_register_opened 80 tcp || msg "${YELLOW}[!] Failed to record the Wallos firewall opening 80/tcp; a later uninstall may leave the port open.${NC}"; fi
    return 0
}


wallos_cftunnel_write_unit() {
    # R16-F15-04: refuse a foreign same-name unit/script before
    # overwriting it (same ownership helper the teardowns use).
    _wallos_front_unit_owned_or_absent abox-wallos-cftunnel || {
        msg "${RED}Refusing to overwrite a foreign 'abox-wallos-cftunnel' service; it is not A-Box-managed.${NC}"
        return 1
    }
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        write_file_atomically_from_stdin "/etc/systemd/system/abox-wallos-cftunnel.service" 600 <<'EOF_WCFT' || return 1
# Managed by A-Box
[Unit]
Description=A-Box Wallos Cloudflare Tunnel
After=network-online.target docker.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/ddr/.wallos-cf-token
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5
StandardOutput=append:/etc/ddr/abox-wallos-cftunnel.log
StandardError=append:/etc/ddr/abox-wallos-cftunnel.log

[Install]
WantedBy=multi-user.target
EOF_WCFT
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        # R8C15-03: a failed boot registration must fail setup, not be swallowed.
        systemctl enable abox-wallos-cftunnel.service >/dev/null 2>&1 || return 1
        systemctl restart abox-wallos-cftunnel.service >/dev/null 2>&1 || return 1
    else
        local _tok=''
        _tok=$(sed -n 's/^TUNNEL_TOKEN=//p' "$WALLOS_CF_TOKEN_FILE" 2>/dev/null | head -1)
        [[ -n "$_tok" ]] || return 1
        write_file_atomically_from_stdin "/etc/init.d/abox-wallos-cftunnel" 700 <<'EOF_WCFTRC' || return 1
#!/sbin/openrc-run
# Managed by A-Box
description="A-Box Wallos Cloudflare Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run"
command_background="yes"
pidfile="/run/abox-wallos-cftunnel.pid"
output_log="/etc/ddr/abox-wallos-cftunnel.log"
error_log="/etc/ddr/abox-wallos-cftunnel.log"
depend() { need net; }
start_pre() {
    # Read the token at start time so the secret lives only in the
    # 600 token file, never in this script (systemd parity).
    # C9-N02: export, not command_env (not an OpenRC variable).
    local _tok=''
    _tok=$(sed -n 's/^TUNNEL_TOKEN=//p' /etc/ddr/.wallos-cf-token 2>/dev/null | head -1)
    [ -n "$_tok" ] || return 1
    export TUNNEL_TOKEN="$_tok"
}
EOF_WCFTRC
        chmod +x "/etc/init.d/abox-wallos-cftunnel" || return 1
        # R8C15-03: a failed boot registration must fail setup, not be swallowed.
        rc-update add abox-wallos-cftunnel default >/dev/null 2>&1 || return 1
        rc-service abox-wallos-cftunnel restart >/dev/null 2>&1 9>&- 10>&- || return 1
    fi
}

# 2ez follow-up: preserve the tunnel token before the F02-GATE teardown
# destroys it (wallos_cftunnel_teardown rm -f's the token file). The token
# is a secret with no other copy: without this backup, a torn-down tunnel
# could never be rebuilt by recovery. Mirrors the R15C15-01 setup-path
# backup (same file, same 600). Returns 0 when there is nothing to
# preserve; a failed backup refuses the switch (caller checks).
wallos_preserve_cftoken() {
    [[ -f "$WALLOS_CF_TOKEN_FILE" && ! -L "$WALLOS_CF_TOKEN_FILE" ]] || return 0
    cp -a "$WALLOS_CF_TOKEN_FILE" "$WALLOS_DIR/.upgrade-transaction.cftoken" || return 1
    chmod 600 "$WALLOS_DIR/.upgrade-transaction.cftoken" || return 1
    return 0
}

wallos_cftunnel_teardown() { # stop the tunnel front; returns 1 if it is still running (see S148) or if disable/removal fails
    # R15-F15-04: refuse a foreign unit before stopping it (see helper above).
    _wallos_front_unit_owned_or_absent abox-wallos-cftunnel || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl stop abox-wallos-cftunnel.service >/dev/null 2>&1 || true
        # R14-F15-04: require a confirmed stopped state; a failed
        # state query must not look like a stopped front.
        if ! _wallos_service_confirmed_stopped abox-wallos-cftunnel; then
            return 1
        fi
        systemctl disable abox-wallos-cftunnel.service >/dev/null 2>&1 || {
            # R14-02: a failed disable is OK only if no boot
            # registration remains (repeat / partial teardown).
            # R56-M4: check EVERY wants link, and count a dangling
            # symlink (-L) as residue too: -e is false for a
            # dangling link, and checking only [0] misses later links.
            local _w _wants=(/etc/systemd/system/*.wants/abox-wallos-cftunnel.service)
            for _w in "${_wants[@]}"; do
                [[ -e "$_w" || -L "$_w" ]] && return 1
            done
        }
        rm -f "/etc/systemd/system/abox-wallos-cftunnel.service" || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
    else
        rc-service abox-wallos-cftunnel stop >/dev/null 2>&1 || true
        # R14-F15-04: require a confirmed stopped state; a failed
        # state query must not look like a stopped front.
        if ! _wallos_service_confirmed_stopped abox-wallos-cftunnel; then
            return 1
        fi
        rc-update del abox-wallos-cftunnel default >/dev/null 2>&1 || {
            # R14-02: same idempotency rule for the runlevel link.
            # R56-M4: a dangling link is residue too (-e is false
            # for a dangling link).
            [[ ! -e /etc/runlevels/default/abox-wallos-cftunnel && ! -L /etc/runlevels/default/abox-wallos-cftunnel ]] || return 1
        }
        rm -f "/etc/init.d/abox-wallos-cftunnel" || return 1
    fi
    # R14-02: the required token file must go; a stale log need not fail.
    rm -f "$WALLOS_CF_TOKEN_FILE" || return 1
    rm -f /etc/ddr/abox-wallos-cftunnel.log || true
    return 0
}
# Stop and remove the Wallos container itself. The container is
# A-Box-managed only when it carries the managed label or the
# /opt/wallos ownership state file exists; anything else is left
# alone. With $1=purge-data the A-Box Wallos data dir is removed
# too (full uninstall); other flows keep the subscription data.
# H7 (R58b-M1, hardening): pin a Wallos container by ID, not by name.
# The ownership label proves the container found by name is managed
# at check time, but a later stop/start/rm by name re-resolves the
# name and can touch a different container if the name was retaken
# in between (docker run --name wallos fails while the managed
# container exists, so the swap needs a privileged actor in the
# window -- hence hardening, not a confirmed vulnerability). Capture
# the ID once (docker inspect -f '{{.Id}}', validated as bare 64-hex)
# and address the ID: docker resolves an ID unambiguously,
# so stop/start/rm by ID can only ever touch that exact container.
# H7-ID: Docker reports a *container* .Id as bare 64-hex; the sha256:
# prefix belongs to *image* IDs. A sha256: form addresses no
# container (inspect/stop/start fail; rm -f exits 0 without removing),
# so the canonical internal form is bare hex everywhere.
_wallos_container_id() {
    local _id=''
    _id=$(docker inspect -f '{{.Id}}' wallos 2>/dev/null || true)
    _id="${_id#sha256:}"
    [[ "$_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$_id"
}
_wallos_valid_container_id() { [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; }
_wallos_stop_id() { local _id=''; _id=$(_wallos_normalize_container_id "${1:-}" 2>/dev/null) || return 1; docker stop "$_id" >/dev/null 2>&1; }
_wallos_start_id() { local _id=''; _id=$(_wallos_normalize_container_id "${1:-}" 2>/dev/null) || return 1; docker start "$_id" >/dev/null 2>&1; }
_wallos_rm_id() { local _id=''; _id=$(_wallos_normalize_container_id "${1:-}" 2>/dev/null) || return 1; docker rm -f "$_id" >/dev/null 2>&1; }
# H7-ID: normalize a container ID to canonical bare-hex form.
# _wallos_container_id returns bare hex; --cidfile records bare hex.
# A sha256: spelling (e.g. from an old journal) is accepted and
# stripped, never passed to docker.
_wallos_normalize_container_id() { # $1 -> canonical ID on stdout
    # H7-F3: canonical form is bare lowercase hex. Lowercase FIRST
    # (so a SHA256: prefix normalizes too), then strip the prefix.
    # Bare uppercase and prefixed uppercase both canonicalize; the
    # old code accepted prefixed uppercase verbatim (bare only
    # lowercase) -- an inconsistent case contract.
    local _id="${1:-}"
    _id="${_id,,}"
    _id="${_id#sha256:}"
    _wallos_valid_container_id "$_id" || return 1
    printf '%s' "$_id"
}
# H7rest: remove whatever holds the 'wallos' name, by ID only. $1 is
# the expected container ID (optional, either form): it is removed by
# ID first (a no-op when already gone), then the live holder is
# pinned -- only a holder carrying the A-Box managed label is removed
# by its pinned ID; a foreign holder refuses (returns 1) instead of
# being removed by name.
_wallos_rm_named_id() {
    # H7-F2: the old code treated every pin failure as "name free"
    # (return 0): a daemon error or an illegal ID looked exactly
    # like "container gone", so callers proceeded as if the name
    # were free. Tri-state the live pin instead, reusing the
    # _wallos_container_gone classifier: proven-gone -> 0;
    # daemon/permission error or an illegal .Id -> 1 (unknown).
    # H7-F3: a non-empty $1 that does not normalize is an illegal
    # expected ID -> 1; only an empty $1 means "no expectation".
    local _expected='' _live='' _lbl='' _inspect_err=''
    if [[ -n "${1:-}" ]]; then
        _expected=$(_wallos_normalize_container_id "$1" 2>/dev/null) || return 1
    fi
    if [[ -n "$_expected" ]]; then
        _wallos_rm_id "$_expected" >/dev/null 2>&1 || true
    fi
    # H7-F2: the tri-state capture uses `docker container inspect`
    # (same idiom as the install entry and recovery): its stderr is
    # what _wallos_container_gone classifies.
    _inspect_err=$(docker container inspect wallos 2>&1 >/dev/null || true)
    _live=$(_wallos_container_id 2>/dev/null || true)
    if [[ -z "$_live" ]]; then
        _wallos_container_gone "$_inspect_err" || return 1
        return 0
    fi
    [[ "$_live" == "$_expected" ]] && return 1
    _lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_live" 2>/dev/null || true)
    [[ "$_lbl" == 'true' ]] || return 1
    _wallos_rm_id "$_live" >/dev/null 2>&1 || return 1
    return 0
}

# R21-WALLOS: classify a failed `docker inspect wallos` as "container gone"
# only when Docker's own "no such container/object" wording is present
# (matched case-insensitively: Docker 29 reports it lowercase) AND a
# second, independent check (`docker ps -a`) also shows no container
# named wallos (same idiom as the B-06 fix at the Wallos menu remove
# path). Any other inspect failure, a failing ps, or a ps listing that
# still names wallos leaves the state unknown (fail-closed, R11E-R7-7
# preserved). $1 = inspect stderr text. Returns 0 iff gone is proven.
_wallos_container_gone() {
    local _err_lc _names
    _err_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$_err_lc" in
        *'no such container'*|*'no such object'*) ;;
        *) return 1 ;;
    esac
    _names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) || return 1
    [[ $'\n'"$_names"$'\n' == *$'\n'wallos$'\n'* ]] && return 1
    return 0
}

# H7-F1: read the upgrade-transaction cidfile
# ($WALLOS_DIR/.upgrade-transaction.cid) as a trusted container ID.
# The file is written by docker itself (--cidfile) at container
# creation, so its content is the ID docker assigned -- but only
# when the file is a regular file (not a symlink) owned by root.
# No mode check: docker chooses the cidfile mode, and WALLOS_DIR is
# 0750 root-only. Prints the normalized (bare lowercase) ID, or
# returns 1 when absent/untrusted/invalid. The caller treats 1 as
# "no transaction evidence", never as a refusal by itself.
_wallos_txn_cidfile_id() {
    local _f="$WALLOS_DIR/.upgrade-transaction.cid" _id='' _owner=''
    [[ -f "$_f" && ! -L "$_f" ]] || return 1
    _owner=$(stat -c %u:%g "$_f" 2>/dev/null || true)
    [[ "$_owner" == 0:0 ]] || return 1
    # NB: docker writes the cidfile with NO trailing newline, so
    # read returns 1 at EOF even when it read the ID; accept the
    # content anyway and let the normalize below validate it.
    IFS= read -r _id < "$_f" || true
    _wallos_normalize_container_id "$_id" 2>/dev/null
}

# R21-WALLOS: surface the captured docker error text when a teardown
# refusal is caused by an unknown container state, so the operator can
# see WHY instead of only the generic refusal. Prints nothing when
# there is no captured error (e.g. an unmanaged container left in place).
_wallos_show_docker_err() { # $1 = inspect/recheck stderr (may be empty)
    [[ -n "${1:-}" ]] && msg "${RED}$(tprintf wl_td_docker_err "$1")${NC}"
}

# R25-F-C-M20: "never installed" vs "state unknown" on a host without a
# docker binary. A host that never had Wallos leaves no trace at all (no
# data dir, no unit, no A-Box wallos state, no docker socket); only then
# is the container state "gone". Any trace keeps the fail-closed unknown.
_wallos_no_trace() {
    [[ -e "$WALLOS_DIR" || -L "$WALLOS_DIR" ]] && return 1
    local _u
    _u=$(same_name_service_unit_path wallos 2>/dev/null || true)
    [[ -n "$_u" && ( -e "$_u" || -L "$_u" ) ]] && return 1
    local _g
    for _g in /etc/systemd/system/wallos*.service /run/systemd/system/wallos*.service /etc/init.d/wallos; do
        [[ -e "$_g" || -L "$_g" ]] && return 1
    done
    local _a="${ABOX_DIR:-/etc/ddr}"
    [[ -e "$_a/.wallos-cf-token" || -L "$_a/.wallos-cf-token" ]] && return 1
    [[ -e "$_a/wallos-images.txt" || -L "$_a/wallos-images.txt" ]] && return 1
    [[ -e /var/run/docker.sock || -L /var/run/docker.sock ]] && return 1
    return 0
}

wallos_stack_teardown() {
    local _purge="${1:-keep-data}" _rm_failed=0 _docker_ok=0 _gone=0 _unknown=0 _inspect_err='' _recheck_err=''
    if command -v docker >/dev/null 2>&1; then
        _docker_ok=1
        # R11E-R7-7: classify an inspect failure by its own error text,
        # never by whether `docker info` happens to succeed. A daemon
        # that answers `info` can still fail an `inspect` (timeout,
        # auth-plugin refusal, transient error) while the container
        # keeps running; treating that as "gone" let keep-data return
        # 0 with the container still alive. Only Docker's own
        # "No such container" / "No such object" proves absence (same
        # wording the backup/repair paths already use), matched
        # case-insensitively by _wallos_container_gone (Docker 29
        # reports it lowercase) and confirmed by `docker ps -a`.
        if _inspect_err=$(docker inspect wallos 2>&1 >/dev/null); then
            local _lbl='' _tid=''
            _lbl=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null || true)
            # R16C15-01: only the managed label authorizes removal;
            # a leftover state file alone is not proof of ownership.
            # H7 (R58b-M1): pin the ID next to the label check; the rm
            # below addresses the ID, and the recheck must also prove
            # that ID gone (a same-name recreation must not pass as
            # the removal of the pinned container).
            _tid=$(_wallos_container_id) || _tid=''
            if [[ "$_lbl" == 'true' && -n "$_tid" ]]; then
                if _wallos_rm_id "$_tid"; then
                    # Same three-state classification for the post-rm
                    # recheck: _wallos_container_gone (case-insensitive
                    # "no such container/object" + `docker ps -a`
                    # confirmation) proves the removal; any other failure
                    # (or a still-present container) leaves _gone at 0,
                    # so purge refuses, and an unknown recheck fails
                    # keep-data instead of reporting success.
                    if _recheck_err=$(docker inspect wallos 2>&1 >/dev/null); then
                        # 07g1-M04: inspect still succeeds after rm -f,
                        # so the container is present (recreated). That
                        # is an unknown state for keep-data: set
                        # _unknown so the tail below fails instead of
                        # reporting success (purge already refuses via
                        # _gone == 0).
                        _unknown=1
                    elif _wallos_container_gone "$_recheck_err"; then
                        # H7: the name is gone, but the pinned container
                        # may have been renamed instead of removed; only
                        # the ID being gone proves the removal.
                        if docker container inspect "$_tid" >/dev/null 2>&1; then
                            _unknown=1
                        else
                            _gone=1
                        fi
                    else
                        _unknown=1
                    fi
                else
                    _rm_failed=1
                fi
            fi
            # An unmanaged container is deliberately left running (as
            # before); _gone stays 0 so purge below refuses.
        elif _wallos_container_gone "$_inspect_err"; then
            _gone=1
        else
            _unknown=1
        fi
    else
        # R25-F-C-M20: no docker binary at all. R7-F15-7 keeps the
        # fail-closed rule (state unknown, not "gone") whenever any
        # Wallos trace remains; only a host with no trace at all
        # (never installed) counts as gone.
        if _wallos_no_trace; then
            _gone=1
        else
            _unknown=1
        fi
    fi
    if [[ "$_purge" == 'purge-data' && -f "$WALLOS_DIR/.abox-state" && ! -L "$WALLOS_DIR/.abox-state" ]]; then
        # U121: never delete data under a container that may still be alive.
        if (( _rm_failed == 1 )); then
            msg "${RED}$(tr_msg wl_td_rm_fail)${NC}"
            return 1
        fi
        if (( _docker_ok == 0 )) || (( _gone == 0 )); then
            msg "${RED}$(tr_msg wl_td_purge_refuse)${NC}"
            _wallos_show_docker_err "${_inspect_err:-$_recheck_err}"
            return 1
        fi
        # R8C15-01: refuse before deleting when a mount sits at
        # or under the data dir; rm -rf would cross it and destroy
        # backing data before the post-check could report failure.
        if path_tree_has_mountpoint "$WALLOS_DIR"; then
            msg "${RED}$(tr_msg wl_td_purge_refuse)${NC}"
            return 1
        fi
        rm -rf "$WALLOS_DIR" 2>/dev/null || true
        [[ ! -e "$WALLOS_DIR" ]] || { msg "${RED}$(tr_msg wl_td_purge_refuse)${NC}"; return 1; }
    fi
    # R1-15-06: a failed container removal must fail teardown in
    # keep-data mode too, not report success while it still runs.
    if (( _rm_failed == 1 )); then
        msg "${RED}$(tr_msg wl_td_rm_fail)${NC}"
        return 1
    fi
    # R7-F15-7: in keep-data mode an unknown container state (docker
    # missing, or inspect failed without Docker reporting the
    # container absent) must fail the teardown, not report success
    # while a container may still be running. (A container that was
    # inspected and found unmanaged is deliberately left in place and
    # still returns 0 here.)
    if [[ "$_purge" == 'keep-data' ]] && (( _unknown == 1 )); then
        msg "${RED}$(tr_msg wl_td_purge_refuse)${NC}"
        _wallos_show_docker_err "${_inspect_err:-$_recheck_err}"
        return 1
    fi
    return 0
}


# Restart the tunnel frontend so it re-reads the token file.
# Returns 0 only if the service is running afterwards; 1 if the restart
# command failed, 2 if it is not running after the restart.
wallos_cftunnel_restart() {
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl restart abox-wallos-cftunnel.service >/dev/null 2>&1 || return 1
    else
        rc-service abox-wallos-cftunnel restart >/dev/null 2>&1 9>&- 10>&- || return 1
    fi
    is_service_running abox-wallos-cftunnel 2>/dev/null || return 2
    return 0
}

wallos_cftunnel_setup() { # $1 = public hostname (wallos.example.com)
    local host="$1" _t=0 _code='' _iport=''
    if [[ ! "$host" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        msg "${RED}$(tprintf wl_cf_bad_host "$host")${NC}"
        return 1
    fi
    if [[ ! -s "$WALLOS_CF_TOKEN_FILE" ]]; then
        msg "${RED}$(tprintf wl_cf_no_token "$WALLOS_CF_TOKEN_FILE")${NC}"
        return 1
    fi
    install_cloudflared || return 1
    wallos_cftunnel_write_unit || { msg "${RED}$(tr_msg wl_cf_unit_fail)${NC}"; return 1; }
    while (( _t < 30 )); do
        is_service_running abox-wallos-cftunnel 2>/dev/null && break
        sleep 3; _t=$((_t + 3))
    done
    if ! is_service_running abox-wallos-cftunnel 2>/dev/null; then
        msg "${RED}$(tr_msg wl_cf_not_running)${NC}"
        return 1
    fi
    # R14-03: accept only the healthy codes (same allowlist as
    # wallos_wait_healthy); a Cloudflare tunnel error (e.g. 530 Error
    # 1033) means the tunnel is not connected even if cloudflared runs.
    # Retry empty/000/5xx briefly: cloudflared can be running while the
    # tunnel is still registering, so one immediate 530 is a race.
    local _tries=0
    while (( _tries < 6 )); do
        _code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://${host}/" 2>/dev/null || true)
        case "$_code" in
            200|301|302|303|307|308) return 0 ;;
            ''|000|5*) sleep 2; _tries=$((_tries + 1)); continue ;;
            *) break ;;
        esac
    done
    _iport=$(wallos_state_value PORT 2>/dev/null || true)
    msg "${RED}$(tprintf wl_cf_no_resp "$host" "$_iport")${NC}"
    return 1
}

wallos_write_state() {
    # P3-6: persist BIND so backup/restore and rebuild-from-state preserve network exposure.
    # Round 15: persist MODE (local|http|https|cftunnel), PUBPORT and CFHOST.
    # Unless $9 == 1, omitted or empty $5..$8 inherit current-state values.
    local image="$1" port="$2" tz="$3" bind="${4-127.0.0.1}" mode="${5:-}" pubport="${6:-}" cfhost="${7:-}" version="${8:-}" restore="${9:-}" tmp
    # R13-09 / F14-1: $9 == 1 disables carry-over for
    # MODE/PUBPORT/CFHOST/VERSION; existing output validation still applies.
    # Rollback success and failure recovery use pre-rollback frontend
    # metadata, not the backup metadata now in the current state file.
    # VERSION is explicit: target on success, previous on recovery.
    if [[ "$restore" != 1 ]]; then
        if [[ -z "$mode" ]]; then mode=$(wallos_state_value MODE 2>/dev/null || true); fi
        if [[ -z "$pubport" ]]; then pubport=$(wallos_state_value PUBPORT 2>/dev/null || true); fi
        if [[ -z "$cfhost" ]]; then cfhost=$(wallos_state_value CFHOST 2>/dev/null || true); fi
        if [[ -z "$version" ]]; then version=$(wallos_state_value VERSION 2>/dev/null || true); fi
    fi
    tmp=$(umask 077; mktemp "$WALLOS_DIR/.abox-state.new.XXXXXX") || return 1
    if ! printf 'IMAGE=%s\nPORT=%s\nTZ=%s\nBIND=%s\n' "$image" "$port" "$tz" "$bind" > "$tmp"; then
        rm -f -- "$tmp"; return 1
    fi
    if [[ "$mode" == https || "$mode" == cftunnel || "$mode" == http || "$mode" == local ]]; then printf 'MODE=%s\n' "$mode" >> "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
    if [[ "$mode" == cftunnel && "$cfhost" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then printf 'CFHOST=%s\n' "$cfhost" >> "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
    # M-28: PUBPORT is only meaningful for the https front. In any
    # other mode an inherited/stale PUBPORT must not be written back
    # (a switch to cftunnel/local used to keep advertising the old
    # public port). Restore calls ($9==1) pass the pre-rollback mode
    # explicitly, so they keep PUBPORT exactly when that mode is https.
    if [[ "$mode" == https && "$pubport" =~ ^[0-9]+$ ]]; then printf 'PUBPORT=%s\n' "$pubport" >> "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf 'VERSION=%s\n' "$version" >> "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
    # R7-F15-6 (R10-06 clone, M-15): a directory at the state path must
    # fail, not be silently swallowed: without -T, mv renames the temp
    # file INTO the directory and reports success. BusyBox mv has no
    # -T, so the guarantee is kept with a pre-check plus a post-commit
    # verification instead: if a directory was swapped in between the
    # check and the move, the temp file lands inside it and the
    # destination is still a directory — that must fail, and the stray
    # file inside it is removed so no state is left behind.
    if [[ -d "$WALLOS_DIR/.abox-state" ]]; then rm -f -- "$tmp"; return 1; fi
    if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$WALLOS_DIR/.abox-state"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ ! -f "$WALLOS_DIR/.abox-state" ]]; then
        rm -f -- "$WALLOS_DIR/.abox-state/$(basename -- "$tmp")" 2>/dev/null || true
        return 1
    fi
    return 0
}

wallos_db_health() { # $1=quick skips the restart-stability sampling
    docker container inspect wallos >/dev/null 2>&1 || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null || true)" == true ]] || return 1
    [[ "$(docker inspect -f '{{.State.Restarting}}' wallos 2>/dev/null || true)" == false ]] || return 1
    if [[ "${1:-}" != quick ]]; then
        local _rc1 _rc2
        _rc1=$(docker inspect -f '{{.RestartCount}}' wallos 2>/dev/null || echo '?')
        sleep 6
        _rc2=$(docker inspect -f '{{.RestartCount}}' wallos 2>/dev/null || echo '?')
        # 07g1-M02: two failed reads both produce '?', and '? == ?'
        # would pass as healthy. Require both to be numbers first.
        [[ "$_rc1" =~ ^[0-9]+$ && "$_rc2" =~ ^[0-9]+$ ]] || return 1
        [[ "$_rc1" == "$_rc2" ]] || return 1
        [[ "$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null || true)" == true ]] || return 1
    fi
    # Core-table check: a half-initialized db (missing user /
    # subscriptions) crash-loops on migration 000013 while nginx and
    # php-fpm still answer HTTP, so an HTTP probe cannot see it.
    # S142: a missing python3 or a missing db file must fail, not skip
    # to healthy: python3 is a declared install prerequisite, and a
    # running Wallos at install-complete time must have created its db.
    command -v python3 >/dev/null 2>&1 || return 1
    [[ -f "$WALLOS_DIR/db/wallos.db" ]] || return 1
    if true; then
        python3 -I - "$WALLOS_DIR/db/wallos.db" <<'PY_WALLOS_HEALTH' || return 1
import sqlite3, sys
try:
    tables = {r[0] for r in sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True).execute("select name from sqlite_master where type='table'")}
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if {'user', 'subscriptions'} <= tables else 1)
PY_WALLOS_HEALTH
    fi
    return 0
}

# U122: rebuild the direct container after a failed HTTP fallback, from the
# (still correct) install state params. Returns 0 only if the container is
# recreated, healthy, and the state is corrected to the direct mode.
# The journal is not involved: it holds the pre-upgrade image, while the
# pre-fallback container is the just-installed one.
wallos_restore_direct_container() {
    local image="$1" port="$2" tz="$3" bind_address="$4" version="${5:-}" container_id="${6:-}" mode='http'
    [[ "$bind_address" == 127.0.0.1 ]] && mode='local'
    # H7rest: clear the name by ID only ($6 = the container this
    # attempt created, passed by the caller; a live labeled holder is
    # removed by its pinned ID, a foreign holder refuses).
    _wallos_rm_named_id "$container_id" || return 1
    local -a _pub_args=()
    [[ -n "$bind_address" ]] && _pub_args=(-p "${bind_address}:${port}:80/tcp")
    # H7-F1: record the replacement container's ID (--cidfile) in
    # WALLOS_CREATED_CONTAINER_ID, so the caller can refresh the
    # upgrade journal with it: this function removes the container
    # the attempt created (B) and builds a new one (B2), and a
    # journal still naming B would wedge the next recovery.
    WALLOS_CREATED_CONTAINER_ID=''
    local _rdc_cid_dir='' _rdc_created_id=''
    _rdc_cid_dir=$(mktemp -d "${TMPDIR:-/tmp}/abox-wallos-cid.XXXXXXXXXX") || return 1
    docker run -d --cidfile "$_rdc_cid_dir/id" --name wallos --label com.alariclin.abox.managed=true \
        "${WALLOS_DOCKER_HARDENING[@]}" \
        -v "$WALLOS_DIR/db:/var/www/html/db" \
        -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
        -e TZ="$tz" "${_pub_args[@]}" --restart unless-stopped "$image" >/dev/null || { _wallos_cleanup_failed_create "$_rdc_cid_dir/id"; rm -rf -- "$_rdc_cid_dir"; return 1; }
    if [[ -f "$_rdc_cid_dir/id" ]]; then
        IFS= read -r _rdc_created_id < "$_rdc_cid_dir/id" || true
    fi
    rm -rf -- "$_rdc_cid_dir"
    if [[ "$_rdc_created_id" =~ ^[0-9a-f]{64}$ ]]; then
        WALLOS_CREATED_CONTAINER_ID="$_rdc_created_id"
    else
        # docker ran but left no usable cidfile: pin the live
        # container immediately (managed-label only; see
        # _wallos_record_created_from_cidfile).
        local _rdc_pin=''
        _rdc_pin=$(_wallos_container_id 2>/dev/null || true)
        if [[ -n "$_rdc_pin" ]] && [[ "$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_rdc_pin" 2>/dev/null || true)" == "true" ]]; then
            WALLOS_CREATED_CONTAINER_ID="$_rdc_pin"
        fi
    fi
    # S8 (R54-M2 follow-up): same U217 rule as the rollback/install
    # paths -- an omitted -p means the rebuilt container is unpublished,
    # so the health gate must not demand a publication it will never
    # have (the bare call above failed every unpublished restore).
    local _health_mode=published
    (( ${#_pub_args[@]} == 0 )) && _health_mode=unpublished
    wallos_wait_healthy "$port" "$_health_mode" || return 1
    wallos_write_state "$image" "$port" "$tz" "$bind_address" "$mode" '' '' "$version" || return 1
    return 0
}

wallos_http_rebind() { # $1=public port $2=image $3=tz $4=container ID (optional): republish the container on 0.0.0.0 (HTTP fallback)
    # H7rest: clear the name by ID only (see wallos_restore_direct_container).
    _wallos_rm_named_id "${4:-}" || return 1
    # H7-F1: record the replacement container's ID (--cidfile) in
    # WALLOS_CREATED_CONTAINER_ID, so the caller can refresh the
    # upgrade journal with it (see wallos_restore_direct_container).
    # Recorded even when the health gate below fails: a failed
    # rebind still leaves the replacement live, and the caller's
    # recovery must see it as this transaction's container.
    WALLOS_CREATED_CONTAINER_ID=''
    local _rbd_cid_dir='' _rbd_created_id=''
    _rbd_cid_dir=$(mktemp -d "${TMPDIR:-/tmp}/abox-wallos-cid.XXXXXXXXXX") || return 1
    docker run -d --cidfile "$_rbd_cid_dir/id" --name wallos --label com.alariclin.abox.managed=true \
        "${WALLOS_DOCKER_HARDENING[@]}" \
        -v "$WALLOS_DIR/db:/var/www/html/db" \
        -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
        -e TZ="$3" -p "0.0.0.0:$1:80/tcp" --restart unless-stopped "$2" >/dev/null || { rm -rf -- "$_rbd_cid_dir"; return 1; }
    if [[ -f "$_rbd_cid_dir/id" ]]; then
        IFS= read -r _rbd_created_id < "$_rbd_cid_dir/id" || true
    fi
    rm -rf -- "$_rbd_cid_dir"
    if [[ "$_rbd_created_id" =~ ^[0-9a-f]{64}$ ]]; then
        WALLOS_CREATED_CONTAINER_ID="$_rbd_created_id"
    else
        # docker ran but left no usable cidfile: pin the live
        # container immediately (managed-label only; see
        # _wallos_record_created_from_cidfile).
        local _rbd_pin=''
        _rbd_pin=$(_wallos_container_id 2>/dev/null || true)
        if [[ -n "$_rbd_pin" ]] && [[ "$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_rbd_pin" 2>/dev/null || true)" == "true" ]]; then
            WALLOS_CREATED_CONTAINER_ID="$_rbd_pin"
        fi
    fi
    wallos_wait_healthy "$1"
}

# W1: pre-seed a fresh Wallos database from the image's own template.
# Wallos startup launches nginx/php-fpm before createdatabase.php, so any
# HTTP request inside that window makes the app auto-create an empty
# wallos.db; createdatabase.php then sees the file and skips base-table
# creation, and migration 000013 dies on the missing user table. The
# container then restart-loops forever because the empty file persists.
# Seeding the image's wallos.empty.db (all base tables, zero users) before
# the first docker run closes that window. Only acts when wallos.db is
# absent: existing databases (including already-poisoned ones) are left
# untouched. Any extraction failure aborts the install instead of
# starting a container that is guaranteed to crash-loop.
wallos_preseed_db() { # $1=image
    local image="$1" _cid="" _tmp=""
    [[ -f "$WALLOS_DIR/db/wallos.db" ]] && return 0
    _cid=$(docker create "$image" 2>/dev/null) || return 1
    _tmp=$(mktemp -d) || { docker rm "$_cid" >/dev/null 2>&1 || true; return 1; }
    if ! docker cp "$_cid:/var/www/html/db/wallos.empty.db" "$_tmp/wallos.db" >/dev/null 2>&1; then
        docker rm "$_cid" >/dev/null 2>&1 || true
        rm -rf "$_tmp"
        return 1
    fi
    docker rm "$_cid" >/dev/null 2>&1 || true
    # 07g1-M01: publish atomically, so a failed copy never leaves a
    # partial target that the next call mistakes for a seeded database.
    install_file_atomically "$_tmp/wallos.db" "$WALLOS_DIR/db/wallos.db" 644 || { rm -rf "$_tmp"; return 1; }
    rm -rf "$_tmp"
    # An empty or root-owned seed must not survive either: the next
    # call returns 0 on [[ -f ]] alone and would start the container
    # against a broken database (the crash-loop this preseed exists
    # to prevent).
    [[ -s "$WALLOS_DIR/db/wallos.db" ]] || { rm -f -- "$WALLOS_DIR/db/wallos.db"; return 1; }
    # The installer passes no PUID/PGID, so the container runs as the
    # image default www-data (82:82); a root-owned seed would leave
    # migrations unable to write.
    chown 82:82 "$WALLOS_DIR/db/wallos.db" || { rm -f -- "$WALLOS_DIR/db/wallos.db"; return 1; }
    return 0
}

# Wallos poisoned-DB diagnosis (read-only) and repair.
# The 1s first-start race can leave an empty database file: the web
# service starts before the database is built, a request creates an
# empty db, the build then skips creating tables, and migration fails
# on the missing user table. Preseed only prevents new cases; this
# repairs installs that are already poisoned (GPT-arbitrated design A:
# explicit submenu action, strict detection (ii), diagnosed/journaled
# flow, verified backup, atomic replacement, full-health verification).

# Extract the empty-database template from the image into $2 (staged
# file), validating it independently before the caller may use it.
# $1 = image, $2 = destination path (parent dir must exist).
# Returns 0 with a validated template at $2, else 1.
wallos_db_template_extract() {
    local image="$1" dest="$2" _cid='' _tmp=''
    [[ -n "$image" && -n "$dest" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    _cid=$(docker create "$image" 2>/dev/null) || return 1
    _tmp=$(mktemp -d) || { docker rm "$_cid" >/dev/null 2>&1 || true; return 1; }
    if ! docker cp "$_cid:/var/www/html/db/wallos.empty.db" "$_tmp/wallos.db" >/dev/null 2>&1; then
        docker rm "$_cid" >/dev/null 2>&1 || true
        rm -rf "$_tmp"
        return 1
    fi
    docker rm "$_cid" >/dev/null 2>&1 || true
    # Validate the template independently: readable SQLite, integrity
    # ok, base tables present, zero users. A template with users or a
    # damaged schema must never seed a live database.
    if true; then
        python3 -I - "$_tmp/wallos.db" <<'PY_WALLOS_TEMPLATE' 2>/dev/null || { rm -rf "$_tmp"; return 1; }
import sqlite3, sys
con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
try:
    ok = con.execute("PRAGMA integrity_check").fetchone()
    if ok is None or ok[0] != 'ok':
        raise SystemExit(1)
    tables = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    if not {'user', 'subscriptions'} <= tables:
        raise SystemExit(1)
    if con.execute("select count(*) from user").fetchone()[0] != 0:
        raise SystemExit(1)
finally:
    con.close()
PY_WALLOS_TEMPLATE
    fi
    # R14-04: never write through a pre-existing destination (a
    # planted symlink would redirect the write); callers must pass a
    # fresh path inside a protected directory.
    [[ ! -e "$dest" && ! -L "$dest" ]] || { rm -rf "$_tmp"; return 1; }
    cp "$_tmp/wallos.db" "$dest" || { rm -rf "$_tmp"; return 1; }
    rm -rf "$_tmp"
    [[ -s "$dest" ]] || return 1
    return 0
}

# Classify the live database without mutating anything.
# Prints one word to stdout: poisoned | healthy | unknown:<reason>.
# Returns 0 = poisoned (repair applicable), 1 = healthy (nothing to
# do), 2 = unknown (refuse; left untouched).
# $1 = image to extract the template from (for the schema reference;
# only needed when the core tables are missing).
wallos_db_diagnose() {
    local image="$1" _db="$WALLOS_DIR/db/wallos.db" _tmp='' _cls='' _side=''
    [[ -f "$_db" && ! -L "$_db" ]] || { printf 'unknown:database file missing or not a regular file\n'; return 2; }
    command -v python3 >/dev/null 2>&1 || { printf 'unknown:python3 unavailable\n'; return 2; }
    _tmp=$(mktemp -d) || { printf 'unknown:temp directory creation failed\n'; return 2; }
    # Classify a COPY, never the live file: opening a SQLite database
    # (even read-only) can delete its -wal sidecar during recovery, so
    # diagnosing the live file would destroy the very sidecars the
    # repair must back up. The copy carries the sidecars along, so
    # WAL-resident rows are still visible to the classifier.
    cp -a "$_db" "$_tmp/live.db" || { rm -rf "$_tmp"; printf 'unknown:database copy failed\n'; return 2; }
    for _side in wallos.db-wal wallos.db-shm wallos.db-journal; do
        # R14-05: a present sidecar that cannot be copied means the
        # diagnosis is unknowable — never silently continue without it.
        if [[ -e "$WALLOS_DIR/db/$_side" ]]; then
            cp -a "$WALLOS_DIR/db/$_side" "$_tmp/live.db-${_side#wallos.db-}" 2>/dev/null || { rm -rf "$_tmp"; printf 'unknown:sidecar copy failed (%s)\n' "$_side"; return 2; }
        fi
    done
    # Phase 1: integrity + core tables + rows (no template needed).
    # A database with both core tables is complete; one with rows in
    # any table holds user data. Only a rowless database missing a
    # core table needs the template schema comparison.
    _cls=$(python3 -I - "$_tmp/live.db" <<'PY_WALLOS_DIAGNOSE1' 2>/dev/null || echo "unknown:inspection failed"
import sqlite3, sys
try:
    con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
    try:
        ok = con.execute("PRAGMA integrity_check").fetchone()
        if ok is None or ok[0] != 'ok':
            print("unknown:inspection failed"); sys.exit(0)
        counts = {}
        for (t,) in con.execute("select name from sqlite_master where type='table'"):
            counts[t] = con.execute('select count(*) from "%s"' % t.replace('"', '""')).fetchone()[0]
    finally:
        con.close()
    if 'user' in counts and 'subscriptions' in counts:
        print("healthy"); sys.exit(0)
    if any(n > 0 for n in counts.values()):
        print("unknown:a table contains rows; not the known empty poison"); sys.exit(0)
    print("need-template")
except Exception:
    print("unknown:inspection failed")
PY_WALLOS_DIAGNOSE1
)
    case "$_cls" in
        healthy) rm -rf "$_tmp"; printf 'healthy\n'; return 1 ;;
        need-template) : ;;
        *) rm -rf "$_tmp"; printf '%s\n' "$_cls"; return 2 ;;
    esac
    # Phase 2: every schema object must belong to the known template.
    [[ -n "$image" ]] || { rm -rf "$_tmp"; printf 'unknown:cannot determine the deployed image\n'; return 2; }
    if ! wallos_db_template_extract "$image" "$_tmp/template.db"; then
        rm -rf "$_tmp"
        printf 'unknown:template extraction or validation failed\n'; return 2
    fi
    _cls=$(python3 -I - "$_tmp/live.db" "$_tmp/template.db" <<'PY_WALLOS_DIAGNOSE2' 2>/dev/null || echo "unknown:inspection failed"
import sqlite3, sys
live, tpl = sys.argv[1], sys.argv[2]
try:
    def _objs(path):
        con = sqlite3.connect('file:%s?mode=ro' % path, uri=True)
        try:
            ok = con.execute("PRAGMA integrity_check").fetchone()
            if ok is None or ok[0] != 'ok':
                return None
            # 07g1-M03: compare the definition too, not just (type,
            # name): a same-name table with a different schema (an
            # extra column, a changed type) is a different object, not
            # the known template's. sql is NULL for auto-indexes and
            # sqlite_sequence; normalise it to ''.
            return {(r[0], r[1], r[2] or '') for r in con.execute("select type, name, sql from sqlite_master")}
        finally:
            con.close()
    l = _objs(live)
    t = _objs(tpl)
    if l is None or t is None:
        print("unknown:inspection failed"); sys.exit(0)
    if not l <= t:
        print("unknown:schema contains objects outside the known template"); sys.exit(0)
    print("poisoned")
except Exception:
    print("unknown:inspection failed")
PY_WALLOS_DIAGNOSE2
)
    rm -rf "$_tmp"
    case "$_cls" in
        poisoned) printf 'poisoned\n'; return 0 ;;
        *) printf '%s\n' "$_cls"; return 2 ;;
    esac
}

# Explicit repair of a poisoned Wallos database (menu item 6).
# Sequence: diagnose (no mutation) -> confirm -> stop container
# (quiesce writers) -> revalidate (hash + re-diagnose) -> verified
# backup (db + sidecars) -> stage + validate template in a protected
# staging dir -> atomic rename over the live db -> start -> full
# health check. On verification failure the container is stopped and
# the backup location is reported; a stop that cannot be confirmed
# is reported as unconfirmed, never claimed stopped. The original
# (poisoned) database is NOT restored, because restoring it restores
# a known-broken state.
# Returns 0 on success (or when no repair was needed), 1 otherwise.
wallos_db_repair_poisoned() {
    local _db="$WALLOS_DIR/db/wallos.db" _image='' _diag='' _drc=0 _image_rc=0 _cid=''
    local _had_container=0 _was_running=0 _backup_dir='' _journal='' _inspect_err='' _managed=''
    local _staged='' _hash_before='' _hash_after='' _staged_hash='' _ts='' _stage_dir='' _src_hash='' _dst_hash=''
    local _side=''
    (( EUID == 0 )) || { msg "${RED}$(tr_msg wl_iu_need_root)${NC}"; return 1; }
    # R7-F15-4: three states. Inspect success -> label gate (a foreign
    # same-name container is refused, never stopped/started); daemon
    # confirms absence ("No such container/object", matched
    # case-insensitively by _wallos_container_gone -- Docker 29 reports
    # it lowercase -- and confirmed by `docker ps -a`) -> no-container
    # path; any other inspect failure (daemon unreachable) -> refuse: the
    # container state is unknown and a live replace would be unsafe.
    if _inspect_err=$(docker container inspect wallos 2>&1 >/dev/null); then
        _had_container=1
        if ! _managed=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null) || [[ "$_managed" != 'true' ]]; then
            msg "${RED}$(tr_msg wl_iu_unmanaged)${NC}"
            return 1
        fi
        # H7rest: pin the container ID next to the label check; the
        # stop/start below address the pinned ID, never the name.
        _cid=$(_wallos_container_id) || { msg "${RED}$(tprintf wl_repair_abort 'container ID unknown')${NC}"; return 1; }
        # R14-F15-02: a failed .State.Running query is "unknown",
        # never "stopped": the old `|| true` swallowed the failure and
        # the repair then skipped docker stop while a writer could
        # still run. Refuse like the first inspect above.
        local _running_out='' _running_rc=0
        _running_out=$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null); _running_rc=$?
        if (( _running_rc != 0 )); then
            msg "${RED}$(tprintf wl_repair_abort 'container state unknown')${NC}"
            return 1
        fi
        [[ "$_running_out" == true ]] && _was_running=1
        # R15-F15-05: take the immutable image ID (.Image), not the
        # creation-time reference (.Config.Image): a tag retargeted
        # after the container was created would otherwise make the
        # repair seed another version's template over the live db.
        # R14-F14-02 fixed the same confusion at the rollback
        # capture point; this is the database-repair call site.
        _image=$(docker inspect -f '{{.Image}}' wallos 2>/dev/null); _image_rc=$?
        # 07g2-M1: when the container exists, its image ID is the
        # only trusted reference. A failed or empty .Image query (or
        # a non-digest value) must refuse here; falling back to the
        # state-file IMAGE would let a stale/mutable tag (latest)
        # seed the repair template and bypass R15-F15-05.
        if (( _image_rc != 0 )) || [[ -z "$_image" ]] || [[ ! "$_image" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            msg "${RED}$(tprintf wl_repair_abort 'container image ID unknown')${NC}"
            return 1
        fi
        _image="${_image#docker.io/}"
    elif _wallos_container_gone "$_inspect_err"; then
        _had_container=0
    else
        msg "${RED}$(tprintf wl_repair_abort 'container state unknown')${NC}"
        _wallos_show_docker_err "$_inspect_err"
        return 1
    fi
    if [[ -z "$_image" ]]; then
        _image=$(wallos_state_value IMAGE 2>/dev/null || true)
    fi
    # Same image-reference gate as the upgrade path; a repair must
    # never become an implicit upgrade by pulling a latest image.
    [[ "$_image" =~ ^((docker\.io/)?bellamy/wallos:[A-Za-z0-9._-]+|(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}|sha256:[A-Fa-f0-9]{64})$ ]] || _image=''
    # 07g2-M1: the tag regex above still matches the mutable `latest`
    # tag; refuse it explicitly. A repair seeded from latest would
    # pull the current latest image and upgrade the database.
    case "$_image" in
        bellamy/wallos:latest|docker.io/bellamy/wallos:latest) _image='' ;;
    esac
    _diag=$(wallos_db_diagnose "$_image"); _drc=$?
    case "$_drc" in
        1) msg "${GREEN}$(tr_msg wl_repair_healthy)${NC}"; return 0 ;;
        0) : ;; # poisoned, continue
        *) msg "${RED}$(tprintf wl_repair_unknown "$_diag")${NC}"; return 1 ;;
    esac
    _hash_before=$(sha256sum "$_db" 2>/dev/null | awk '{print $1}')
    _ts=$(date +%Y%m%d-%H%M%S)
    _backup_dir="$WALLOS_DIR/backups/db-repair-$_ts-$$"
    if [[ -t 0 ]]; then
        confirm_yes_no "$(tprintf wl_repair_confirm "$_db" "$_backup_dir")" || return 1
    elif [[ "${WALLOS_DB_REPAIR_CONFIRM:-0}" != 1 ]]; then
        msg "${RED}$(tr_msg wl_repair_need_confirm)${NC}"; return 1
    fi
    # Quiesce writers before any mutation: a running container (or a
    # restart) writing to the db or its sidecars during the replace
    # would corrupt the new template or resurrect the poison.
    if (( _had_container == 1 )) && (( _was_running == 1 )); then
        _wallos_stop_id "$_cid" || { msg "${RED}$(tprintf wl_repair_abort 'container stop failed')${NC}"; return 1; }
    fi
    # Revalidate after quiescing: the database must still be the same
    # poisoned file (hash) and still classify as poisoned. A dry-run
    # diagnosis is not an authorization token.
    _hash_after=$(sha256sum "$_db" 2>/dev/null | awk '{print $1}')
    if [[ -z "$_hash_after" || "$_hash_after" != "$_hash_before" ]]; then
        msg "${RED}$(tprintf wl_repair_abort 'database changed during preparation')${NC}"; return 1
    fi
    _diag=$(wallos_db_diagnose "$_image"); _drc=$?
    if [[ "$_drc" != 0 || "$_diag" != poisoned ]]; then
        msg "${RED}$(tprintf wl_repair_abort 'database no longer classifies as poisoned')${NC}"; return 1
    fi
    # Verified backup (db + SQLite sidecars) before any replacement.
    # wallos_create_backup is not used here: it requires .abox-state
    # and logos, which a poisoned install may not have yet.
    # R7-F15-3: reject a symlinked live database BEFORE creating the
    # backup directory: the backup loop below follows links, and a chmod
    # on a linked backup would retarget the link's host file. (The later
    # pre-commit check is kept as a second gate.)
    [[ ! -L "$_db" ]] || { msg "${RED}$(tprintf wl_repair_abort 'live database is a symlink')${NC}"; return 1; }
    mkdir_private "$WALLOS_DIR/backups" || { msg "${RED}$(tprintf wl_repair_abort 'backup directory creation failed')${NC}"; return 1; }
    mkdir -m 700 "$_backup_dir" || { msg "${RED}$(tprintf wl_repair_abort 'backup directory creation failed')${NC}"; return 1; }
    for _side in wallos.db wallos.db-wal wallos.db-shm wallos.db-journal; do
        [[ -e "$WALLOS_DIR/db/$_side" || -L "$WALLOS_DIR/db/$_side" ]] || continue
        # R7-F15-3: a backup must be a faithful COPY of regular-file
        # content. cp -a preserves symlinks, so a linked sidecar (or a
        # linked wallos.db) would leave a symlink in the backup and the
        # chmod below would retarget the link's host file. A dangling
        # link, a directory or a FIFO aborts instead of being copied.
        [[ -f "$WALLOS_DIR/db/$_side" ]] || { msg "${RED}$(tprintf wl_repair_abort 'backup source is not a regular file')${NC}"; return 1; }
        cp -- "$WALLOS_DIR/db/$_side" "$_backup_dir/$_side" || { msg "${RED}$(tprintf wl_repair_abort 'backup copy failed')${NC}"; return 1; }
        [[ -f "$_backup_dir/$_side" && ! -L "$_backup_dir/$_side" ]] || { msg "${RED}$(tprintf wl_repair_abort 'backup verification failed')${NC}"; return 1; }
        chmod 600 "$_backup_dir/$_side" || { msg "${RED}$(tprintf wl_repair_abort 'backup permission failed')${NC}"; return 1; }
        _src_hash=$(sha256sum "$WALLOS_DIR/db/$_side" 2>/dev/null | awk '{print $1}')
        _dst_hash=$(sha256sum "$_backup_dir/$_side" 2>/dev/null | awk '{print $1}')
        [[ "$_src_hash" =~ ^[0-9a-f]{64}$ && "$_dst_hash" =~ ^[0-9a-f]{64}$ && "$_src_hash" == "$_dst_hash" ]] || { msg "${RED}$(tprintf wl_repair_abort 'backup verification failed')${NC}"; return 1; }
    done
    [[ "$(sha256sum "$_backup_dir/wallos.db" 2>/dev/null | awk '{print $1}')" == "$_hash_after" ]] || { msg "${RED}$(tprintf wl_repair_abort 'backup verification failed')${NC}"; return 1; }
    # Journal the repair before the destructive step, so an interrupted
    # run leaves a record of what was backed up.
    _journal="$WALLOS_DIR/.db-repair-journal"
    {
        echo "phase=active"
        echo "db=$_db"
        echo "backup=$_backup_dir"
        echo "image=$_image"
        echo "container=$_cid"
        echo "started=$(now_iso)"
    } > "$_journal" || { msg "${RED}$(tprintf wl_repair_abort 'journal write failed')${NC}"; return 1; }
    chmod 600 "$_journal" || { msg "${RED}$(tprintf wl_repair_abort 'journal permission failed')${NC}"; return 1; }
    # R14-04: stage inside a private root-owned directory under
    # $WALLOS_DIR (root-owned parent, same filesystem as db/), never
    # under a predictable name inside db/ itself, where a writer could
    # pre-plant or swap the staged path mid-repair. The helper refuses
    # any pre-existing destination, so the staged file is created
    # fresh and cannot be a planted symlink. Never copy over the live
    # file in place. Move the old sidecars aside first (they are
    # preserved in the backup) so they cannot attach to the new db.
    _stage_dir=$(umask 077; mktemp -d "$WALLOS_DIR/.wallos-db-repair.XXXXXXXXXX") || { msg "${RED}$(tprintf wl_repair_abort 'staging directory creation failed')${NC}"; return 1; }
    _staged="$_stage_dir/wallos.db"
    if ! wallos_db_template_extract "$_image" "$_staged"; then
        rm -rf -- "$_stage_dir" 2>/dev/null || true
        rm -f -- "$_journal"
        msg "${RED}$(tprintf wl_repair_abort 'template extraction/validation failed')${NC}"; return 1
    fi
    chown 82:82 "$_staged" || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'template ownership failed')${NC}"; return 1; }
    chmod 600 "$_staged" || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'template permission failed')${NC}"; return 1; }
    _staged_hash=$(sha256sum "$_staged" 2>/dev/null | awk '{print $1}')
    for _side in wallos.db-wal wallos.db-shm wallos.db-journal; do
        rm -f -- "$WALLOS_DIR/db/$_side" || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'sidecar removal failed')${NC}"; return 1; }
    done
    # Exact-destination rename: -T refuses to treat a symlinked $_db
    # as a directory. The live-symlink check is a policy rejection
    # (fail closed on an unexpected live symlink); the device check
    # fails closed instead of silently copying on EXDEV.
    [[ ! -L "$_db" ]] || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'live database is a symlink')${NC}"; return 1; }
    [[ "$(stat -c %d -- "$_staged" 2>/dev/null || echo x)" == "$(stat -c %d -- "$WALLOS_DIR/db" 2>/dev/null || echo y)" ]] || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'staging directory is on another filesystem')${NC}"; return 1; }
    mv -fT -- "$_staged" "$_db" || { rm -rf -- "$_stage_dir" 2>/dev/null || true; rm -f -- "$_journal"; msg "${RED}$(tprintf wl_repair_abort 'replacement install failed')${NC}"; return 1; }
    rm -rf -- "$_stage_dir" 2>/dev/null || true
    [[ "$(sha256sum "$_db" 2>/dev/null | awk '{print $1}')" == "$_staged_hash" ]] || { printf '%s\n' "phase=failed" >> "$_journal" 2>/dev/null || true; msg "${RED}$(tprintf wl_repair_fail "$_backup_dir")${NC}"; return 1; }
    if (( _had_container == 1 )); then
        _wallos_start_id "$_cid" || { printf '%s\n' "phase=failed" >> "$_journal" 2>/dev/null || true; msg "${RED}$(tprintf wl_repair_start_fail "$_backup_dir")${NC}"; return 1; }
        if ! wallos_db_health; then
            # R14-06: leave the failed instance stopped, as promised;
            # a stop that cannot be confirmed is reported, not claimed.
            printf '%s\n' "phase=failed" >> "$_journal" 2>/dev/null || true
            if _wallos_stop_id "$_cid"; then
                msg "${RED}$(tprintf wl_repair_fail "$_backup_dir")${NC}"
            else
                msg "${RED}$(tprintf wl_repair_fail_stop_unconfirmed "$_backup_dir")${NC}"
            fi
            return 1
        fi
        rm -f -- "$_journal"
        msg "${GREEN}$(tprintf wl_repair_done "$_backup_dir")${NC}"
        return 0
    fi
    # No container: the database is repaired; the install recreates
    # the container. Verify by classification only.
    _diag=$(wallos_db_diagnose "$_image"); _drc=$?
    if [[ "$_drc" != 1 || "$_diag" != healthy ]]; then
        printf '%s\n' "phase=failed" >> "$_journal" 2>/dev/null || true
        msg "${RED}$(tprintf wl_repair_fail "$_backup_dir")${NC}"; return 1
    fi
    rm -f -- "$_journal"
    msg "${GREEN}$(tprintf wl_repair_done_nocontainer "$_backup_dir")${NC}"
    return 0
}

# 2do-refusal: on a refused HTTPS firewall opening, pre-existing
# A-Box ACCEPT rules for the front ports must go too. The rules were
# added by an earlier successful install (allowPort) and sit at the
# head of INPUT, ahead of the ufw jump, so they bypass UFW entirely;
# leaving them means the refusal is silently ineffective -- the front
# stays reachable while the user believes they refused. This removes
# the raw iptables ACCEPT rules (v4+v6) with the A-Box-<port>-<proto>
# comment, using the same check/delete/verify loop as
# remove_abox_native_firewall_rule's iptables branch and
# remove_ss_open_accept_rules. Returns 1 if a rule survives or a
# query fails (fail closed: the caller must shout).
wallos_remove_abox_iptables_accept() {
    local spec="$1" proto="${2:-tcp}" comment cmd check_rc failed=0
    spec=$(normalize_port_spec "$spec") || return 1
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    # M-12(2): same shared-port guard as remove_abox_native_firewall_rule.
    if [[ "$spec" == 80 && "$proto" == tcp ]] && hy2_http01_port_still_needed; then
        msg "${YELLOW}[!] Keeping 80/tcp: still needed by Hy2 HTTP-01 certificate renewal.${NC}" >&2
        return 0
    fi
    comment="A-Box-${spec}-${proto}"
    for cmd in "$IPT" "$IPT6"; do
        [[ "$cmd" == "$IPT" || -x "$cmd" || -n "$(command -v "$cmd" 2>/dev/null)" ]] || continue
        if [[ "$cmd" == "$IPT6" ]]; then
            # S27: binary missing: this script could not have built
            # v6 rules; skip (accepted narrow residue: the binary
            # was removed after the rules were built).
            command -v ip6tables >/dev/null 2>&1 || continue
            if ! _iptables_q "$IPT6" -S INPUT >/dev/null 2>&1; then
                # S27: query failure (permission/lock/module) means
                # v6 rules may still be present; never report success.
                # R4C6-03: excuse only when IPv6 is confirmed
                # unusable (kernel-disabled): then no v6 rules can
                # exist to delete.
                if host_has_usable_ipv6; then failed=1; fi
                continue
            fi
        fi
        while :; do
            if iptables_rule_check "$cmd" INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
            case "$check_rc" in
                0) _iptables_do "$cmd" -D INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT >/dev/null 2>&1 || { failed=1; break; } ;;
                1) break ;;
                *) failed=1; break ;;
            esac
        done
        if iptables_rule_check "$cmd" INPUT -p "$proto" --dport "$spec" -m comment --comment "$comment" -j ACCEPT; then check_rc=0; else check_rc=$?; fi
        [[ "$check_rc" == 1 ]] || failed=1
    done
    (( failed == 0 ))
}

# R7-F15-2: non-fatal single-port opening for the Wallos install path.
# Unlike allowPort (which dies on any failure), this never exits the
# process: it returns 0 when the port is open (newly created or already
# open) and 1 when the state is unknown or the opening failed, after
# warning and removing any partial opening it made. When it creates a
# new rule it prints exactly one line "backend|spec|proto" on stdout
# (the caller's rollback-set entry); all diagnostics go to stderr so
# the increment can be captured with $(...). A reused rule (owned and
# complete, or foreign) prints nothing and is NOT an increment: a later
# install failure must not delete a rule this attempt did not create.
# An owned rule that covers only one address family is warned about and
# left unchanged (the record has no family dimension, so a completion
# could not be rolled back without deleting the pre-existing family
# too); it still returns 0 because the port is open in the family that
# exists and the deployment can proceed.
# R11-D (R7-6): roll back one firewalld scope this call added, then
# forget its ledger record ONLY if the port is confirmed gone afterwards
# (firewalld_port_state rc 1). $1=spec $2=type $3=scope $4=zone $5=fw_spec
# $6=record_if_still_present (0/1: when 1 and the port is not confirmed
# gone, record the scope so a later cleanup can find it — the rule was
# created by this call, and the ledger deleter re-verifies live state
# before deleting, so a possibly-stale record self-heals).
# Returns 0 when the scope is confirmed gone; 1 otherwise (record kept
# or (re)written, RED warning emitted).
_fw_rollback_firewalld_scope() {
    local _spec="$1" _type="$2" _scope="$3" _zone="$4" _fw_spec="$5" _rec="$6" _rc=0
    if [[ "$_scope" == permanent ]]; then
        firewalld_cmd_zone "$_zone" --permanent --remove-port="${_fw_spec}/${_type}" >/dev/null 2>&1 || true
    else
        firewalld_cmd_zone "$_zone" --remove-port="${_fw_spec}/${_type}" >/dev/null 2>&1 || true
    fi
    firewalld_port_state "$_spec" "$_type" "$_scope" "$_zone" >/dev/null 2>&1; _rc=$?
    if (( _rc == 1 )); then
        if forget_native_firewall_rule "$_spec" "$_type" firewalld "$_zone" "$_scope" >/dev/null 2>&1; then
            return 0
        fi
        msg "${RED}[!] Firewalld ${_scope} rule for ${_spec}/${_type} (zone ${_zone}) is gone, but its ledger record could not be forgotten; a stale record may be replayed by a later rollback.${NC}" >&2
        return 1
    fi
    if (( _rec == 1 )); then
        if record_native_firewall_rule firewalld "$_spec" "$_type" "$_scope" "$_zone"; then
            msg "${RED}[!] Failed to remove the firewalld ${_scope} rule for ${_spec}/${_type} (zone ${_zone}); the port may still be open, but its ledger record is kept for later cleanup.${NC}" >&2
        else
            msg "${RED}[!] Failed to remove the firewalld ${_scope} rule for ${_spec}/${_type} (zone ${_zone}) and its ledger record could not be written; manual cleanup may be required.${NC}" >&2
        fi
    else
        msg "${RED}[!] Failed to remove the firewalld ${_scope} rule for ${_spec}/${_type} (zone ${_zone}); the port may still be open, but its ledger record is kept for later cleanup.${NC}" >&2
    fi
    return 1
}

# R14-F15-05 (Scheme B, ledger diff): print the native-firewall ledger
# lines for one spec/proto, matched on exact fields, never substrings.
# A missing ledger file is empty (rc 0); a symlink, a non-regular file,
# an unreadable file, or a file holding a malformed line is an error
# (rc 1, no output), so a caller never mistakes a blind read for
# "nothing changed". Ownership/mode is deliberately NOT gated here (that
# gate belongs to the mutating record/remove paths): a mode anomaly must
# not abort an install whose attribution data is intact, and allowPort's
# own record attempt still fails loudly on such a file. Lines are
# buffered and only printed after every line validates.
_wallos_fw_ledger_lines() {
    local _spec _proto _line _f1 _f2 _f3 _rest _out='' _content=''
    _spec=$(normalize_port_spec "${1:-}") || return 1
    _proto="${2:-}"
    [[ "$_proto" == tcp || "$_proto" == udp ]] || return 1
    [[ ! -e "$ABOX_FW_STATE" && ! -L "$ABOX_FW_STATE" ]] && return 0
    [[ -f "$ABOX_FW_STATE" && ! -L "$ABOX_FW_STATE" ]] || return 1
    # R57-M3 (same 07h1-03 principle as the registry read in reclaim):
    # read the whole ledger up front and check the read. A `while
    # read` loop cannot report a mid-read I/O failure (its exit
    # status is the last body command's): a failed read with an empty
    # line ends the loop normally and the caller gets a partial
    # snapshot as a valid one. On a read failure, return 1 with no
    # output. The old fd-based open had the same gap for mid-read
    # failures (it only fixed the failed-redirect case).
    local _bad=0
    _content=$(cat -- "$ABOX_FW_STATE" 2>/dev/null) || return 1
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -n "$_line" ]] || continue
        if ! native_firewall_record_valid "$_line"; then _bad=1; break; fi
        IFS='|' read -r _f1 _f2 _f3 _rest <<< "$_line"
        if [[ ( "$_f1" == ufw || "$_f1" == firewalld ) && "$_f2" == "$_spec" && "$_f3" == "$_proto" ]]; then
            _out+="${_line}"$'\n'
        fi
    done <<< "$_content"
    (( _bad == 0 )) || return 1
    printf '%s' "$_out"
    return 0
}

# R14-F15-05: print the ledger lines present in $2 (after) but absent
# from $1 (before), converted to _fw_added entry form: ufw 4-field
# "ufw|spec|proto|rule" lines become 3-field "ufw|spec|proto";
# firewalld 5-field lines pass through unchanged (scope and zone are
# part of the identity). Duplicates are collapsed. A line that fails
# ledger validation, or a firewalld line without a zone (no rollback
# entry can be built from it without inventing one), is skipped, never
# synthesised. A ufw partial-family completion adds no new ledger
# identity and must NOT be compensated by enqueueing the pre-existing
# identity: the before/after diff already excludes it.
_wallos_fw_ledger_new_entries() {
    local _before="$1" _after="$2" _line _pipes _seen=''
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -n "$_line" ]] || continue
        grep -qxF -e "$_line" <<< "$_before" && continue
        grep -qxF -e "$_line" <<< "$_seen" && continue
        native_firewall_record_valid "$_line" || continue
        _pipes=${_line//[^|]/}
        case "$_line" in
            ufw\|*)
                if (( ${#_pipes} == 3 )) && [[ "$_line" == *'|rule' ]]; then
                    printf '%s\n' "${_line%|rule}"
                    _seen+="${_line}"$'\n'
                fi
                ;;
            firewalld\|*)
                if (( ${#_pipes} == 4 )); then
                    printf '%s\n' "$_line"
                    _seen+="${_line}"$'\n'
                fi
                ;;
            *) continue ;;
        esac
    done <<< "$_after"
    return 0
}

# R14-F15-05: open one post-deployment port through allowPort and print
# any NEW ledger entries it created (one per line, _fw_added form) so
# the caller can register them for rollback. Prints nothing when the
# call added no new ledger identity (already-open port, foreign rule,
# iptables backend, ufw partial-family completion). Returns the
# allowPort status; a ledger-read failure returns 1 before opening
# (before-snapshot) or after opening (after-snapshot) - the caller
# must then roll back and refuse, because an opening whose ledger
# delta cannot be read cannot be tracked. Known limits: iptables
# openings have no ledger entry and stay untracked, and a ufw allow
# that succeeds but dies in its own post-verify inside allowPort
# leaves a live rule with no ledger identity.
_wallos_fw_open_tracked() {
    local _port="$1" _proto="${2:-tcp}" _before='' _after='' _new='' _rc=0
    _before=$(_wallos_fw_ledger_lines "$_port" "$_proto") || return 1
    ( allowPort "$_port" "$_proto" ) || _rc=$?
    _after=$(_wallos_fw_ledger_lines "$_port" "$_proto") || return 1
    _new=$(_wallos_fw_ledger_new_entries "$_before" "$_after")
    [[ -n "$_new" ]] && printf '%s\n' "$_new"
    return "$_rc"
}

wallos_fw_open_once() {
    local raw_port="$1" type="${2:-tcp}" backend spec _orc=0 _rrc=0
    local _fw_zone='' _fw_spec='' _fw_rt=0 _fw_pm=0 _fw_rc=0 _fw_added_rt=0
    spec=$(normalize_port_spec "$raw_port") || { msg "${YELLOW}[!] Invalid port for firewall opening: ${raw_port}${NC}" >&2; return 1; }
    [[ "$type" == tcp || "$type" == udp ]] || { msg "${YELLOW}[!] Invalid protocol for firewall opening: ${type}${NC}" >&2; return 1; }
    backend=$(firewall_backend) || { msg "${YELLOW}[!] Cannot determine the firewall backend; leaving ${spec}/${type} closed.${NC}" >&2; return 1; }
    case "$backend" in
        ufw)
            ufw_owned_rule_exists "$spec" "$type"; _orc=$?
            if (( _orc == 0 )); then
                if _ufw_owned_families_complete "$spec" "$type"; then
                    return 0
                fi
                msg "${YELLOW}[!] A-Box firewall rule for ${spec}/${type} covers only one address family; leaving it unchanged.${NC}" >&2
                return 0
            elif (( _orc == 2 )); then
                msg "${YELLOW}[!] Cannot determine the A-Box firewall state for ${spec}/${type}; leaving it unchanged.${NC}" >&2
                return 1
            fi
            ufw_rule_exists "$spec" "$type"; _rrc=$?
            if (( _rrc == 0 )); then
                msg "${YELLOW}[!] ${spec}/${type} is already allowed by a non-A-Box firewall rule; keeping it without claiming ownership.${NC}" >&2
                return 0
            elif (( _rrc == 2 )); then
                msg "${YELLOW}[!] Cannot determine the firewall state for ${spec}/${type}; leaving it unchanged.${NC}" >&2
                return 1
            fi
            # 07g2-H1: ufw allow applies v4/v6 in two steps; a failure
            # may leave the v4 rule already live, so a failed allow
            # must NOT return here. Fall through to the tri-state
            # verify below, but a live partial rule is compensated
            # (deleted), never adopted: delete it, re-check, and only
            # when it cannot be verified gone record the ledger entry
            # so a later cleanup can find it. Always return 1.
            local _allow_rc=0
            ufw allow proto "$type" from any to any port "$spec" comment "A-Box-${spec}-${type}" >/dev/null 2>&1 || _allow_rc=$?
            if (( _allow_rc != 0 )); then
                ufw_owned_rule_exists "$spec" "$type"; _orc=$?
                if (( _orc == 1 )); then
                    # Confirmed absent: nothing live to track.
                    msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}" >&2
                    return 1
                fi
                # Present (0) or unknown (2): try to delete the
                # partial rule this call may have left live, then
                # re-check tri-state.
                ufw_delete_owned_rules "$spec" "$type" >/dev/null 2>&1 || true
                ufw_owned_rule_exists "$spec" "$type"; _orc=$?
                if (( _orc == 1 )); then
                    msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}" >&2
                    return 1
                fi
                # Still present (0) or still unknown (2): the partial
                # rule may still be live with no record. Record it so
                # a later cleanup can find it (the ledger deleter
                # re-verifies live state before deleting).
                if record_native_firewall_rule ufw "$spec" "$type" rule; then
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed; the port may still be open, but its ledger record is kept for later cleanup.${NC}" >&2
                else
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed and its ledger record could not be written; manual cleanup may be required.${NC}" >&2
                fi
                return 1
            fi
            ufw_owned_rule_exists "$spec" "$type"; _orc=$?
            # 03d-M02: first creation must verify ALL families, not
            # just any. An owned rule that covers only one family is
            # a partial allow: compensate like unknown state (delete
            # the partial rule, record it for cleanup if it survives).
            if (( _orc == 0 )) && ! _ufw_owned_families_complete "$spec" "$type"; then
                _orc=2
            fi
            if (( _orc == 1 )); then
                # Confirmed absent: allow reported success but no owned
                # rule exists. Nothing is live to track.
                msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}" >&2
                return 1
            elif (( _orc == 2 )); then
                # State unknown: try to delete, then re-check tri-state.
                ufw_delete_owned_rules "$spec" "$type" >/dev/null 2>&1 || true
                ufw_owned_rule_exists "$spec" "$type"; _orc=$?
                if (( _orc == 1 )); then
                    msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}" >&2
                    return 1
                fi
                # Still present (0) or still unknown (2): the rule this
                # call just added may still be live with no record.
                # Record it so a later cleanup can find it (the ledger
                # deleter re-verifies live state before deleting).
                if record_native_firewall_rule ufw "$spec" "$type" rule; then
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed; the port may still be open, but its ledger record is kept for later cleanup.${NC}" >&2
                else
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed and its ledger record could not be written; manual cleanup may be required.${NC}" >&2
                fi
                return 1
            fi
            if ! record_native_firewall_rule ufw "$spec" "$type" rule; then
                ufw_delete_owned_rules "$spec" "$type" >/dev/null 2>&1 || true
                ufw_owned_rule_exists "$spec" "$type"; _orc=$?
                if (( _orc == 1 )); then
                    msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}" >&2
                    return 1
                fi
                # Still present (0) or still unknown (2): retry the record
                # so the possibly-live rule stays tracked for later cleanup.
                if record_native_firewall_rule ufw "$spec" "$type" rule; then
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed; the port may still be open, but its ledger record is kept for later cleanup.${NC}" >&2
                else
                    msg "${RED}[!] UFW rule for ${spec}/${type} could not be verified removed and its ledger record could not be written; manual cleanup may be required.${NC}" >&2
                fi
                return 1
            fi
            printf '%s\n' "ufw|${spec}|${type}"
            return 0
            ;;
        firewalld)
            # Pin the zone once (R9C6-01), then open the single port in
            # runtime and permanent, recording each scope. A single
            # port has no subrange coalescing to track, so the record
            # is the port itself in each scope. Any failure removes
            # the increments already made in this call before returning
            # 1; a scope is forgotten from the ledger only once its
            # port is confirmed gone (R11-D R7-6), so a failed removal
            # keeps its record (or records the scope) for later cleanup
            # instead of leaving an untracked opening.
            _fw_zone=$(firewalld_zone_for_abox) || { msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1; }
            _fw_spec=$(port_spec_for_firewalld "$spec") || { msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1; }
            firewalld_port_state "$spec" "$type" runtime "$_fw_zone"; _fw_rc=$?
            case "$_fw_rc" in 0) _fw_rt=1 ;; 1) _fw_rt=0 ;; *) msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1 ;; esac
            firewalld_port_state "$spec" "$type" permanent "$_fw_zone"; _fw_rc=$?
            case "$_fw_rc" in 0) _fw_pm=1 ;; 1) _fw_pm=0 ;; *) msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1 ;; esac
            if (( _fw_rt == 1 && _fw_pm == 1 )); then
                return 0
            fi
            if (( _fw_rt == 0 )); then
                firewalld_cmd_zone "$_fw_zone" --add-port="${_fw_spec}/${type}" >/dev/null 2>&1 || { msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1; }
                _fw_added_rt=1
                if ! firewalld_port_state "$spec" "$type" runtime "$_fw_zone" >/dev/null 2>&1; then
                    _fw_rollback_firewalld_scope "$spec" "$type" runtime "$_fw_zone" "$_fw_spec" 1 || true
                    msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1
                fi
                if ! record_native_firewall_rule firewalld "$spec" "$type" runtime "$_fw_zone"; then
                    _fw_rollback_firewalld_scope "$spec" "$type" runtime "$_fw_zone" "$_fw_spec" 1 || true
                    msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1
                fi
            fi
            if (( _fw_pm == 0 )); then
                if ! firewalld_cmd_zone "$_fw_zone" --permanent --add-port="${_fw_spec}/${type}" >/dev/null 2>&1; then
                    if (( _fw_added_rt == 1 )); then
                        _fw_rollback_firewalld_scope "$spec" "$type" runtime "$_fw_zone" "$_fw_spec" 0 || true
                    fi
                    msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1
                fi
                if ! firewalld_port_state "$spec" "$type" permanent "$_fw_zone" >/dev/null 2>&1; then
                    _fw_rollback_firewalld_scope "$spec" "$type" permanent "$_fw_zone" "$_fw_spec" 1 || true
                    if (( _fw_added_rt == 1 )); then
                        _fw_rollback_firewalld_scope "$spec" "$type" runtime "$_fw_zone" "$_fw_spec" 0 || true
                    fi
                    msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1
                fi
                if ! record_native_firewall_rule firewalld "$spec" "$type" permanent "$_fw_zone"; then
                    _fw_rollback_firewalld_scope "$spec" "$type" permanent "$_fw_zone" "$_fw_spec" 1 || true
                    if (( _fw_added_rt == 1 )); then
                        _fw_rollback_firewalld_scope "$spec" "$type" runtime "$_fw_zone" "$_fw_spec" 0 || true
                    fi
                    msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}" >&2; return 1
                fi
            fi
            # R11-B (R7-1): emit one increment per scope actually added
            # by this call, carrying scope and the pinned zone, so a
            # rollback can only remove what this call added. _fw_rt /
            # _fw_pm are the pre-call states: reaching here means any
            # scope that was missing is now added, verified and recorded.
            if (( _fw_rt == 0 )); then
                printf '%s\n' "firewalld|${spec}|${type}|runtime|${_fw_zone}"
            fi
            if (( _fw_pm == 0 )); then
                printf '%s\n' "firewalld|${spec}|${type}|permanent|${_fw_zone}"
            fi
            return 0
            ;;
        *)
            msg "${YELLOW}[!] Firewall backend ${backend} cannot be opened by this installer; leaving ${spec}/${type} closed.${NC}" >&2
            return 1
            ;;
    esac
}

# R7-F15-2: roll back firewall increments opened by this install attempt
# (entries "backend|spec|proto"; firewalld entries are "backend|spec|proto|scope|zone"). Each entry is removed through the
# ledger deleter (which verifies the rule is really gone); a failure is
# reported loudly and returns 1, so a caller that must not claim success
# can fold it into its own failure flag. An empty set is a no-op success.
# M-28: persistent registry of firewall openings this Wallos install
# created, so a later mode switch / port change / uninstall can
# reclaim ports the per-attempt _fw_added ledger no longer knows.
# One line per opening: "spec/proto" (e.g. "8443/tcp", "80/tcp").
# 80/tcp is shared with the Hysteria HTTP-01 ACME challenge
# (altPort: 80 in /etc/hysteria/config.yaml); it is only reclaimed
# when no such challenge still needs it, and the caller is told so.
wallos_fw_registry_file() { printf '%s/.fw-opened' "$WALLOS_DIR"; }

wallos_fw_register_opened() { # $1=spec $2=proto
    local spec proto reg
    spec=$(normalize_port_spec "${1:-}") || return 1
    proto="${2:-tcp}"
    [[ "$proto" == tcp || "$proto" == udp ]] || return 1
    reg=$(wallos_fw_registry_file)
    [[ -d "$WALLOS_DIR" ]] || return 1
    [[ ! -e "$reg" && ! -L "$reg" ]] || { [[ -f "$reg" && ! -L "$reg" ]] || return 1; }
    if [[ -f "$reg" ]]; then
        grep -qxF "${spec}/${proto}" "$reg" 2>/dev/null && return 0
    fi
    ( umask 077; printf '%s/%s\n' "$spec" "$proto" >> "$reg" ) || return 1
    chmod 600 "$reg" 2>/dev/null || true
    return 0
}

# Tri-state probe: does a live A-Box-owned rule for spec/proto exist?
# Returns 0 = yes (iptables v4/v6 or the native ledger), 1 = no,
# 2 = unknown (a probe errored while the rule could still exist).
# A missing iptables binary means that backend holds no rules (the same
# reading as capture_abox_iptables_snapshot); a probe error on a present
# binary is unknown, never "absent".
_wallos_fw_rule_live() {
    local spec="$1" proto="$2" _rc=0 _grep_rc=0
    spec=$(normalize_port_spec "$spec") || return 2
    [[ "$proto" == tcp || "$proto" == udp ]] || return 2
    if command -v "$IPT" >/dev/null 2>&1; then
        iptables_rule_check "$IPT" INPUT -p "$proto" --dport "$spec" -m comment --comment "A-Box-${spec}-${proto}" -j ACCEPT
        _rc=$?
        case "$_rc" in 0) return 0 ;; 1) ;; *) return 2 ;; esac
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        iptables_rule_check "$IPT6" INPUT -p "$proto" --dport "$spec" -m comment --comment "A-Box-${spec}-${proto}" -j ACCEPT
        _rc=$?
        case "$_rc" in 0) return 0 ;; 1) ;; *) host_has_usable_ipv6 && return 2 ;; esac
    fi
    # Native backends (ufw/firewalld) keep their own ledger of live rules.
    if [[ -e "$ABOX_FW_STATE" || -L "$ABOX_FW_STATE" ]]; then
        validate_native_firewall_state_file "$ABOX_FW_STATE" || return 2
        # 07h1-02: a grep read failure (exit 2) is a probe error,
        # not a confirmed absence: it must return 2 per this
        # function's tri-state contract, never fall through to 1.
        grep -qE "^(ufw|firewalld)\\|${spec}\\|${proto}\\|" "$ABOX_FW_STATE" 2>/dev/null || _grep_rc=$?
        case "$_grep_rc" in
            0) return 0 ;;
            1) ;;
            *) return 2 ;;
        esac
    fi
    return 1
}

# Rebuild a missing Wallos firewall registry from live firewall state.
# M-28 follow-up: installs predating the registry (.fw-opened) opened
# ports but recorded them nowhere durable, so reclaiming them later was
# a silent no-op and the openings leaked. The import is scoped to ports
# Wallos is known to have used, so other features' A-Box rules are never
# claimed: the Wallos state PORT/PUBPORT, 80/tcp (HTTP-01), plus any
# spec/proto the caller passes explicitly (the mode-switch path passes
# the previous port/pubport, which the state file no longer holds - it
# was just rewritten with the new values).
# $@ = optional "spec/proto" entries to import. Returns 0 when the live
# state was fully determined (the registry may now exist, or nothing was
# live to import); 1 when the live state could not be determined or the
# registry could not be written - callers must fail loudly instead of
# reporting success with rules leaking.
wallos_fw_import_legacy_registry() {
    local reg spec proto _entry _port _pubport _state_known=0 _rc=0 _reg_exists=0
    local -a _candidates=()
    reg=$(wallos_fw_registry_file)
    # Caller-verified Wallos ports first (mode switch: the previous
    # port/pubport). These are imported even when a registry already
    # exists: a previous install may have failed to register them.
    for _entry in "$@"; do
        case "$_entry" in */tcp|*/udp) ;; *) return 1 ;; esac
        spec="${_entry%/*}"; proto="${_entry##*/}"
        spec=$(normalize_port_spec "$spec") || return 1
        [[ "$proto" == tcp || "$proto" == udp ]] || return 1
        _wallos_fw_rule_live "$spec" "$proto"; _rc=$?
        case "$_rc" in
            0) wallos_fw_register_opened "$spec" "$proto" || return 1 ;;
            1) : ;;
            *) return 1 ;;
        esac
    done
    # 07h1-01: an existing registry may be PARTIAL (an earlier import
    # registered the explicit entries, then failed before probing the
    # state candidates below), so it must never short-circuit the
    # candidate probe. Registering is idempotent, so re-probing a
    # complete registry is harmless; skipping it leaks the unprobed
    # candidates out of reclaim forever.
    [[ -f "$reg" && ! -L "$reg" ]] && _reg_exists=1
    # Then the ports the current Wallos state records.
    _port=$(wallos_state_value PORT 2>/dev/null || true)
    if [[ -n "$_port" ]] && valid_canonical_port "$_port"; then
        _state_known=1
        _candidates+=("${_port}/tcp")
    fi
    _pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
    if [[ -n "$_pubport" ]] && valid_canonical_port "$_pubport"; then
        _state_known=1
        _candidates+=("${_pubport}/tcp")
    fi
    # 80/tcp is shared with the Hysteria HTTP-01 challenge; the reclaim
    # loop keeps it while the challenge still needs it, so importing it
    # here is safe even when another feature opened it.
    _candidates+=('80/tcp')
    # A Wallos directory with no readable state port means the install
    # predates state tracking: its openings cannot be identified, so
    # fail loudly rather than claim a verified clean slate - unless the
    # caller already supplied explicit ports to import, or a registry
    # already exists (it identifies openings to reclaim, and 80/tcp
    # is still probed below).
    if (( _state_known == 0 )) && (( $# == 0 )) && [[ -d "$WALLOS_DIR" ]] && (( _reg_exists == 0 )); then
        msg "${YELLOW}[!] Wallos state has no readable port, so pre-registry firewall openings cannot be identified; check the firewall rules manually.${NC}"
        return 1
    fi
    for _entry in "${_candidates[@]}"; do
        spec="${_entry%/*}"; proto="${_entry##*/}"
        _wallos_fw_rule_live "$spec" "$proto"; _rc=$?
        case "$_rc" in
            0) wallos_fw_register_opened "$spec" "$proto" || return 1 ;;
            1) : ;;
            *) return 1 ;;
        esac
    done
    return 0
}

_wallos_hy2_http01_keeps_80() {
    # Hysteria HTTP-01 ACME listens on 80/tcp via `altPort: 80` in
    # its config; reclaiming 80 would break its issuance/renewal.
    # The config path is overridable for fixtures.
    # Tri-state (M-28 follow-up N5): 0 = definitely needs 80/tcp
    # (altPort 80 present; a trailing comment and leading-zero /
    # quoted forms are legal YAML and count); 1 = definitely not
    # needed (config readable, no such altPort); 2 = cannot determine
    # (config missing, unreadable, or a symlink) -- the caller must
    # keep 80/tcp rather than delete on an unknown.
    local _hy2cfg="${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}" _grep_rc=0
    [[ -f "$_hy2cfg" && ! -L "$_hy2cfg" ]] || return 2
    [[ -r "$_hy2cfg" ]] || return 2
    grep -qE '^[[:space:]]*altPort:[[:space:]]*"?0*80"?[[:space:]]*(#.*)?$' "$_hy2cfg" 2>/dev/null || _grep_rc=$?
    case "$_grep_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

wallos_fw_reclaim_registered() { # $@ = "spec/proto" entries to KEEP
    local reg line spec proto keep _k _removed=0 _failed=0 _del_failed=0 _hy2_rc=0 _kept='' _reg_content='' _tmp='' _vline=''
    reg=$(wallos_fw_registry_file)
    # 07h1-01: always (re-)run the migration, not just when the
    # registry is missing: an earlier interrupted import may have
    # left a partial registry, and its unprobed candidates would
    # otherwise stay outside reclaim forever.
    # M-28 follow-up: a missing registry used to mean silent
    # success, leaking every opening a pre-registry install made.
    # Rebuild the registry from the live firewall state first; a
    # failed rebuild with no registry at all means the live state is
    # unknown, so fail loudly instead of claiming success with rules
    # leaking. A failed rebuild with a registry in place warns and
    # marks the reclaim failed (R57-M1): the registered openings are
    # still reclaimed below, but unprobed candidates were never verified.
    if ! wallos_fw_import_legacy_registry; then
        if [[ ! -f "$reg" || -L "$reg" ]]; then
            msg "${YELLOW}[!] Could not rebuild the missing Wallos firewall registry from the live firewall rules; check the firewall rules manually.${NC}"
            return 1
        fi
        # R57-M1: the registered openings are still reclaimed below,
        # but the rebuild failure must reach the caller: unprobed
        # candidates were never verified, so a 0 return would claim
        # a complete reclaim.
        _failed=1
        msg "${YELLOW}[!] Could not fully verify the Wallos firewall registry from the live firewall rules; reclaiming the registered openings only.${NC}"
    fi
    [[ -f "$reg" && ! -L "$reg" ]] || return 0
    # 07h1-03: read the whole registry up front and check the read:
    # a `while read` loop cannot report a mid-read I/O failure (its
    # exit status is the last body command's), and the old in-place
    # truncate below would then deregister entries that were never
    # read, let alone deleted. On a read failure, return 1 with the
    # file untouched.
    _reg_content=$(cat -- "$reg" 2>/dev/null) || return 1
    # R57-M2: validate the whole snapshot before deleting anything:
    # a malformed non-empty line would otherwise be silently skipped
    # by the loop below and then permanently discarded by the atomic
    # publish, losing the only record of an opening whose rule may
    # still be live. Fail with the file untouched.
    while IFS= read -r _vline || [[ -n "$_vline" ]]; do
        [[ -n "$_vline" ]] || continue
        case "$_vline" in */tcp|*/udp) ;; *) msg "${YELLOW}[!] Wallos firewall registry contains a malformed entry; refusing to reclaim with the file untouched.${NC}"; return 1 ;; esac
    done <<< "$_reg_content"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        case "$line" in */tcp|*/udp) ;; *) continue ;; esac
        spec="${line%/*}"; proto="${line##*/}"
        keep=0
        for _k in "$@"; do [[ "$_k" == "$line" ]] && keep=1; done
        if (( keep == 1 )); then _kept+="${line}"$'\n'; continue; fi
        if [[ "$line" == '80/tcp' ]]; then
            _wallos_hy2_http01_keeps_80
            _hy2_rc=$?
            if (( _hy2_rc == 0 )); then
                msg "${YELLOW}[!] 80/tcp is shared with the Hysteria HTTP-01 ACME challenge; keeping it open.${NC}"
                _kept+="${line}"$'\n'; continue
            elif (( _hy2_rc == 2 )); then
                msg "${YELLOW}[!] Cannot determine whether Hysteria needs 80/tcp (its config is missing, unreadable, or a symlink); keeping it open.${NC}"
                _kept+="${line}"$'\n'; continue
            fi
        fi
        # M-28 (follow-up N4): both delete helpers verify their own
        # removal (an absent rule is success), so a failure here means
        # the rule may still be live: keep the registry line and fail,
        # the same ledger principle as wallos_fw_rollback_added. Never
        # deregister on an unverified delete.
        _del_failed=0
        wallos_remove_abox_iptables_accept "$spec" "$proto" >/dev/null 2>&1 || _del_failed=1
        remove_abox_native_firewall_rule "$spec" "$proto" >/dev/null 2>&1 || _del_failed=1
        if (( _del_failed == 1 )); then
            msg "${YELLOW}[!] Failed to reclaim the Wallos firewall opening ${line}; keeping it registered for a later retry.${NC}"
            _kept+="${line}"$'\n'; _failed=1; continue
        fi
        _removed=1
    done <<< "$_reg_content"
    # 07h1-03: publish the new registry atomically (temp file in the
    # same directory + mv): the old in-place truncate destroyed the
    # original the moment the write failed, deregistering entries
    # whose rules may still be live. Any failure here leaves the
    # original file untouched.
    _tmp=$(mktemp "${reg}.tmp.XXXXXX") || return 1
    printf '%s' "$_kept" > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$reg" || { rm -f -- "$_tmp"; return 1; }
    if (( _removed == 1 )); then save_firewall_rules || return 1; fi
    (( _failed == 0 ))
}

wallos_fw_rollback_added() {
    local _entry _backend _spec _proto _scope _zone _failed=0 _pipes _scoped=0
    for _entry in "$@"; do
        _scoped=0; _scope=''; _zone=''
        # R11-B (R7-1): one entry is one line: legacy three-field
        # "backend|spec|proto", or a firewalld five-field line with
        # "|scope|zone". Anything else (wrong pipe count, multi-line,
        # non-firewalld scoped line, illegal scope/zone) fails loudly
        # without deleting anything; it must never degrade to an
        # unscoped delete.
        case "$_entry" in *$'\n'*) _failed=1; continue ;; esac
        _pipes=${_entry//[^|]/}
        if (( ${#_pipes} == 2 )); then
            IFS='|' read -r _backend _spec _proto <<< "$_entry"
        elif (( ${#_pipes} == 4 )); then
            IFS='|' read -r _backend _spec _proto _scope _zone <<< "$_entry"
            _scoped=1
        else
            _failed=1; continue
        fi
        [[ -n "$_spec" && -n "$_proto" ]] || { _failed=1; continue; }
        if (( _scoped == 1 )); then
            [[ "$_backend" == firewalld ]] || { _failed=1; continue; }
            [[ "$_scope" == runtime || "$_scope" == permanent ]] || { _failed=1; continue; }
            [[ "$_zone" =~ ^[A-Za-z0-9_.:@+-]*$ ]] || { _failed=1; continue; }
            if ! remove_abox_native_firewall_rule "$_spec" "$_proto" "$_scope" "$_zone" >/dev/null 2>&1; then
                msg "${YELLOW}[!] Failed to roll back the firewall opening for ${_spec}/${_proto} opened by this install attempt; the port may still be open.${NC}" >&2
                _failed=1
            fi
        elif ! remove_abox_native_firewall_rule "$_spec" "$_proto" >/dev/null 2>&1; then
            msg "${YELLOW}[!] Failed to roll back the firewall opening for ${_spec}/${_proto} opened by this install attempt; the port may still be open.${NC}" >&2
            _failed=1
        fi
    done
    (( _failed == 0 ))
}

# M-36: explicit Wallos access-mode choice. Persian/Arabic-Indic digits
# are normalized; an unknown choice is rejected and re-prompted instead
# of silently defaulting to public HTTPS (a publish authorization).
# EOF (Ctrl-D) cancels (return 1). Sets the caller's `wmode` via
# dynamic scope; the caller sets _bind_chosen=1 only on success.
wallos_choose_access_mode() {
    local _ans=''
    while true; do
        case "${ABOX_LANG:-zh}" in
            *) msg "$(tr_msg wl_mode_title)"; msg "$(tr_msg wl_mode_1)"; msg "$(tr_msg wl_mode_2)"; msg "$(tr_msg wl_mode_3)"; msg "$(tr_msg wl_mode_4)"; printf '%s' "$(tr_msg wl_choose)" ;;
        esac
        if ! read -r _ans; then
            return 1
        fi
        _ans=$(normalize_fa_ar_digits "$_ans")
        case "$_ans" in
            1) wmode='https'; return 0 ;;
            2) wmode='local'; return 0 ;;
            3) wmode='cftunnel'; return 0 ;;
            4) wmode='http'; return 0 ;;
            *) msg "${RED}$(tr_msg invalid_input): $_ans${NC}" ;;
        esac
    done
}

# H-3 (Gemini): abort helper for failures after the new container B has
# started. Upgrade path (running==1): recover the old container from
# the journal. Fresh-install path (running==0): there is no journal,
# so delete B itself -- by its --cidfile ID plus the managed-label
# re-check, same idiom as the health gate above -- otherwise the next
# call finds a managed container with no .abox-state and no journal
# and refuses at the old_port gate, deadlocking the install entry.
# No verified ID means leave it and fail loudly (fail-closed).
_wallos_abort_started_install() {
    if (( running == 1 )); then
        wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_fail "$WALLOS_DIR/.upgrade-transaction" "$backup")${NC}"
    elif [[ "$_wallos_created_id" =~ ^[0-9a-f]{64}$ ]] &&
        [[ "$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_wallos_created_id" 2>/dev/null || true)" == "true" ]]; then
        docker rm -f "$_wallos_created_id" >/dev/null 2>&1 || true
    else
        msg "${YELLOW}No verified container ID for this attempt; not deleting 'wallos' by name.${NC}" >&2
    fi
}

wallos_install_or_update() {
    local arch image port tz bind_address="${WALLOS_BIND_ADDRESS:-127.0.0.1}" old_bind='0.0.0.0' old_image='' old_image_id='' old_container_id='' old_port='' old_tz='UTC' backup='' stamp code running=0 was_running=0 marker security_note restore_ok=0 backup_listing='' _wl_label=''
    (( EUID == 0 )) || { msg "${RED}$(tr_msg wl_iu_need_root)${NC}"; return 1; }
    command -v jq >/dev/null 2>&1 || { msg "${RED}$(tr_msg wl_iu_need_jq)${NC}"; return 1; }
    wallos_print_host_info
    arch=$(wallos_detect_arch) || { msg "${RED}$(tr_msg wl_iu_arch)${NC}"; return 1; }
    wallos_install_runtime || { msg "${RED}$(tr_msg wl_iu_docker_fail)${NC}"; return 1; }
    docker info >/dev/null 2>&1 || return 1
    if [[ -e "$WALLOS_DIR/.upgrade-transaction" || -L "$WALLOS_DIR/.upgrade-transaction" ]]; then
        wallos_recover_interrupted_upgrade || return 1
        return 0
    fi

    local _wallos_inspect_err=''
    if _wallos_inspect_err=$(docker container inspect wallos 2>&1 >/dev/null); then
        [[ -f "$WALLOS_DIR/.A-Box-managed" && ! -L "$WALLOS_DIR/.A-Box-managed" ]] || {
            msg "${RED}$(tr_msg wl_iu_unmanaged)${NC}"
            return 1
        }
        # R14-07: the marker alone does not prove the live 'wallos'
        # container is A-Box-managed; require the ownership label
        # (same evidence as wallos_stack_teardown / recovery). The
        # inspect exit status is checked too: a failed inspect is a
        # refusal, not an empty label to be re-tested.
        if ! _wl_label=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null) || [[ "$_wl_label" != 'true' ]]; then
            msg "${RED}$(tr_msg wl_iu_unmanaged)${NC}"
            return 1
        fi
        running=1
        # R16-F15-02: a failed .State.Running query is "state unknown",
        # never "stopped": the old `|| true` swallowed the failure into
        # an empty string, leaving was_running=0 so the running instance
        # was later left stopped (same pattern as R14-F15-02 at the
        # db-repair entry). Refuse, like the first inspect above.
        local _wl_running=''
        if ! _wl_running=$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null); then
            msg "${RED}Wallos container state unknown; refusing installation.${NC}"
            return 1
        fi
        [[ "$_wl_running" == true ]] && was_running=1
        old_image=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null || true)
        # X-09: normalize docker.io/ prefix (containerd image store / Podman
        # return docker.io/bellamy/wallos:tag); D-05 fixed the prune path only.
        old_image="${old_image#docker.io/}"
        # S135: pin the immutable image ID at capture time; the tag in
        # .Config.Image can be retagged before recovery runs.
        old_image_id=$(docker inspect -f '{{.Image}}' wallos 2>/dev/null || true)
        [[ "$old_image_id" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || {
            msg "${RED}$(tr_msg wl_iu_state_incomplete)${NC}"; return 1;
        }
        # H7 (R58b-M1): pin the container ID at capture time, next to
        # the S135 image-ID pin; the stop/rm/start below address the
        # ID, never the re-resolved name.
        old_container_id=$(_wallos_container_id) || {
            msg "${RED}$(tr_msg wl_iu_state_incomplete)${NC}"; return 1;
        }
        old_bind=$(docker inspect -f '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostIp}}' wallos 2>/dev/null || true)
        # F-08: preserve legitimate HostIp verbatim; do NOT coerce unknown IPs to 0.0.0.0.
        # Empty means no port binding — preserve empty (do not invent a publication).
        # Invalid values refuse the upgrade rather than silently expanding exposure.
        if [[ -n "$old_bind" ]]; then
            valid_ip_address "$old_bind" || { msg "${RED}$(tprintf wl_iu_bad_bind "$old_bind")${NC}"; return 1; }
        fi
        # C-03: Read old_port from state (was never assigned, causing 100% upgrade failure).
        old_port=$(wallos_state_value PORT 2>/dev/null || true)
        # C-03: Validate port is canonical (1-65535, no leading zeros) BEFORE any
        # destructive step (docker stop / backup / journal). Old check only ^[0-9]+$
        # admitted 0, 080, 70000.
        valid_canonical_port "$old_port" || { msg "${RED}$(tprintf wl_iu_bad_port "$old_port")${NC}"; return 1; }
        old_tz=$(wallos_state_value TZ 2>/dev/null || printf 'UTC')
        [[ -n "$old_tz" ]] || old_tz='UTC'
        # P3-7: refuse on invalid persisted TZ (was silent fallback to UTC).
        valid_timezone_name "$old_tz" || { msg "${RED}$(tprintf wl_iu_bad_tz "$old_tz")${NC}"; return 1; }
        tz="$old_tz"
        # F-09: preserve old bind address for the new container when WALLOS_BIND_ADDRESS is unset.
        if [[ -z "${WALLOS_BIND_ADDRESS:-}" && -n "$old_bind" ]]; then
            bind_address="$old_bind"
        fi
        [[ -n "$old_image" && "$old_image" =~ ^((docker\.io/)?bellamy/wallos:[A-Za-z0-9._-]+|(docker\.io/)?bellamy/wallos@sha256:[A-Fa-f0-9]{64}|sha256:[A-Fa-f0-9]{64})$ && "$old_port" =~ ^[0-9]+$ ]] || {
            msg "${RED}$(tr_msg wl_iu_state_incomplete)${NC}"; return 1;
        }
        port="$old_port"
    elif _wallos_container_gone "$_wallos_inspect_err"; then
        [[ ! -e "$WALLOS_DIR" || -f "$WALLOS_DIR/.A-Box-managed" ]] || {
            msg "${RED}$(tprintf wl_iu_no_marker "$WALLOS_DIR")${NC}"; return 1;
        }
        # Fresh install: random high port (20000-60000) instead of predictable 8282.
        port=''
        local _try
        for _try in $(seq 1 50); do
            local _cand=$(( (RANDOM * 32768 + RANDOM) % 40001 + 20000 ))
            if wallos_port_free "$_cand"; then port="$_cand"; break; fi
        done
        [[ "$port" =~ ^[0-9]+$ ]] || { msg "${RED}$(tr_msg wl_iu_no_free_port)${NC}"; return 1; }
        tz=$(current_timezone_name 2>/dev/null || printf 'UTC')
        valid_timezone_name "$tz" || tz='UTC'
    else
        # R15-F15-02: a failed inspect is "state unknown", not "fresh
        # install": treating it as fresh skips the upgrade backup and
        # journal, and a later name-conflict cleanup could delete the
        # healthy instance. (GPT astra/high agreed with the 3-state
        # entry; the refusal wording follows the db-repair path.)
        msg "${RED}Wallos container state unknown; refusing installation.${NC}"
        _wallos_show_docker_err "$_wallos_inspect_err"
        return 1
    fi
    # C-03: Wallos container listens on IPv4 only. Require IPv4 (no CIDR suffix).
    # F-09 preserved bind (any valid IPv4, e.g. LAN/Tailscale) is allowed.
    # Only an explicit WALLOS_BIND_ADDRESS override is restricted to loopback/all.
    valid_ipv4_cidr "$bind_address" && [[ "$bind_address" != */* ]] || { msg "${RED}$(tprintf wl_iu_bind_invalid "$bind_address")${NC}"; return 1; }
    if [[ -n "${WALLOS_BIND_ADDRESS:-}" && "$bind_address" != 127.0.0.1 && "$bind_address" != 0.0.0.0 ]]; then
        msg "${RED}$(tr_msg wl_iu_bind_override)${NC}"; return 1
    fi
    # Access mode: [1] public HTTPS (Caddy + Let's Encrypt IP cert),
    # [2] localhost only (SSH tunnel), [3] Cloudflare Tunnel (needs a
    # domain on Cloudflare; zero inbound ports), [4] plain public
    # HTTP (disaster recovery; also offered when HTTPS setup fails).
    # An existing public-HTTP install keeps its public port.
    local _bind_chosen=0 wmode='local' pubport='' cfhost='' cftoken=''
    local _old_mode='' _old_pubport=''
    _old_mode=$(wallos_state_value MODE 2>/dev/null || true)
    _old_pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
    if [[ -n "${WALLOS_ACCESS_MODE:-}" ]]; then
        _bind_chosen=1
        case "$WALLOS_ACCESS_MODE" in https|cftunnel|local|http) wmode="$WALLOS_ACCESS_MODE" ;; *) wmode='local' ;; esac
        cfhost="${WALLOS_CF_HOSTNAME:-}"
    elif [[ -n "${WALLOS_BIND_ADDRESS:-}" ]]; then
        _bind_chosen=1
        [[ "$bind_address" == 0.0.0.0 ]] && wmode='https'
    elif [[ -t 0 ]]; then
        # R16-F15-01: EOF (Ctrl-D) is a cancel, never a choice. The
        # helper returns 1 on EOF, _bind_chosen stays unset and the
        # confirm gate below is not skipped.
        wallos_choose_access_mode || return 0
        _bind_chosen=1
    elif [[ "$_old_mode" == https && "$_old_pubport" =~ ^[0-9]+$ ]]; then
        # Non-interactive rerun of an HTTPS install: keep HTTPS.
        wmode='https'; pubport="$_old_pubport"; _bind_chosen=1
    elif [[ "$_old_mode" == cftunnel ]]; then
        # Non-interactive rerun of a tunnel install: keep the tunnel.
        wmode='cftunnel'; _bind_chosen=1
        cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
    elif [[ "$_old_mode" == http ]]; then
        # Non-interactive rerun of an HTTP fallback install: keep HTTP.
        wmode='http'; _bind_chosen=1
    fi
    if [[ "$wmode" == cftunnel ]]; then
        bind_address='127.0.0.1'
        [[ -n "$cfhost" ]] || cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
        if [[ -t 0 ]]; then
            msg "$(tr_msg wl_iu_cf_guide_t)"
            msg "  $(tr_msg wl_iu_cf_guide_1)"
            msg "  $(tprintf wl_iu_cf_guide_2 "$port")"
            msg "  $(tr_msg wl_iu_cf_guide_3)"
            local _h=''
            printf '%s' "$(tprintf wl_iu_host_prompt "${cfhost:-wallos.example.com}")"
            read -r _h || _h=''
            [[ -n "$_h" ]] && cfhost="$_h"
            if [[ -s "$WALLOS_CF_TOKEN_FILE" ]]; then
                printf '%s' "$(tr_msg wl_iu_token_keep)"
            else
                printf '%s' "$(tr_msg wl_iu_token_paste)"
            fi
            read -rs cftoken || cftoken=''
            printf '\n'
        fi
        if [[ ! "$cfhost" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            case "${ABOX_LANG:-zh}" in
                *) msg "${RED}$(tr_msg wl_no_hostname)${NC}" ;;
            esac
            wmode='local'
        elif [[ -z "$cftoken" && ! -s "$WALLOS_CF_TOKEN_FILE" ]]; then
            case "${ABOX_LANG:-zh}" in
                *) msg "${RED}$(tr_msg wl_no_token)${NC}" ;;
            esac
            wmode='local'
        fi
    elif [[ "$wmode" == https ]]; then
        bind_address='127.0.0.1'
        if [[ -z "$pubport" ]]; then
            if [[ "$old_bind" == 0.0.0.0 && "$old_port" =~ ^[0-9]+$ ]]; then pubport="$old_port"
            elif [[ "$_old_pubport" =~ ^[0-9]+$ ]]; then pubport="$_old_pubport"; fi
        fi
        if [[ ! "$pubport" =~ ^[0-9]+$ ]] || (( pubport < 20000 )); then
            # Public exposure never uses a predictable port.
            local _np='' _try
            for _try in $(seq 1 50); do
                local _cand=$(( (RANDOM * 32768 + RANDOM) % 40001 + 20000 ))
                if wallos_port_free "$_cand"; then _np="$_cand"; break; fi
            done
            if [[ -n "$_np" ]]; then
                if [[ "$pubport" =~ ^[0-9]+$ ]]; then
                    case "${ABOX_LANG:-zh}" in
                        *) msg "${YELLOW}$(tprintf wl_port_swap "$pubport" "$_np")${NC}" ;;
                    esac
                fi
                pubport="$_np"
            else
                case "${ABOX_LANG:-zh}" in
                    *) msg "${RED}$(tr_msg wl_no_free_port)${NC}" ;;
                esac
                return 1
            fi
        fi
        # The container port is internal in HTTPS mode and must differ
        # from the public port Caddy binds.
        if [[ "$port" == "$pubport" ]]; then
            local _ip2='' _try2
            for _try2 in $(seq 1 50); do
                local _cand2=$(( (RANDOM * 32768 + RANDOM) % 40001 + 20000 ))
                if [[ "$_cand2" != "$pubport" ]] && wallos_port_free "$_cand2"; then _ip2="$_cand2"; break; fi
            done
            if [[ -n "$_ip2" ]]; then
                port="$_ip2"
            else
                case "${ABOX_LANG:-zh}" in
                    *) msg "${RED}$(tr_msg wl_no_free_port)${NC}" ;;
                esac
                return 1
            fi
        fi
    elif [[ "$wmode" == http ]]; then
        bind_address='0.0.0.0'
    elif (( _bind_chosen )); then
        # An explicit localhost choice also unpublishes a legacy
        # public-HTTP install.
        bind_address='127.0.0.1'
    fi
    local confirm_prompt
    case "${ABOX_LANG:-zh}" in
        en)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='WARNING: Wallos will be published on every IPv4 interface over plain HTTP. Continue only behind a trusted firewall/HTTPS reverse proxy. [Y/N]: '
            else confirm_prompt='Wallos stores personal financial data and binds only to 127.0.0.1 by default. Use an HTTPS reverse proxy or SSH tunnel for remote access. Continue? [Y/N]: '; fi ;;
        ru)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='ВНИМАНИЕ: Wallos будет доступен на всех IPv4-интерфейсах без TLS. Продолжайте только при наличии firewall/HTTPS reverse proxy. [Y/N]: '
            else confirm_prompt='Wallos хранит личные данные и по умолчанию привязан только к 127.0.0.1; используйте HTTPS reverse proxy или SSH-туннель. Продолжить? [Y/N]: '; fi ;;
        fa)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='هشدار: Wallos روی همه رابط‌های IPv4 با HTTP بدون TLS منتشر می‌شود؛ فقط با فایروال/پروکسی HTTPS مطمئن ادامه دهید. [Y/N]: '
            else confirm_prompt='Wallos به‌طور پیش‌فرض فقط به 127.0.0.1 متصل است؛ برای دسترسی راه دور از HTTPS reverse proxy یا SSH tunnel استفاده کنید. ادامه؟ [Y/N]: '; fi ;;
        zh-tw)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='警告：Wallos 將以明文 HTTP 繫結所有 IPv4 網絡卡。只有已配置防火牆/HTTPS 反向代理時才繼續。[Y/N]: '
            else confirm_prompt='Wallos 儲存個人財務資料，預設僅繫結 127.0.0.1；遠端訪問請配置 HTTPS 反向代理或 SSH 隧道。是否繼續？[Y/N]: '; fi ;;
        ja)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='警告: Wallos はすべての IPv4 インターフェースで平文 HTTP を公開します。信頼できるファイアウォールまたは HTTPS リバースプロキシの背後でのみ続行してください。[Y/N]: '
            else confirm_prompt='Wallos は個人のサブスクリプション / 財務データを保存します。デフォルトでは 127.0.0.1 のみにバインドされます。リモートアクセスには HTTPS リバースプロキシまたは SSH トンネルを設定してください。続行しますか？[Y/N]: '; fi ;;
        *)
            if [[ "$bind_address" == 0.0.0.0 ]]; then confirm_prompt='警告：Wallos 将以明文 HTTP 绑定所有 IPv4 网卡。只有已配置防火墙/HTTPS 反向代理时才继续。[Y/N]: '
            else confirm_prompt='Wallos 存储个人财务数据，默认仅绑定 127.0.0.1；远程访问请配置 HTTPS 反向代理或 SSH 隧道。是否继续？[Y/N]: '; fi ;;
    esac
    if [[ "$wmode" != local && "$_bind_chosen" != 1 ]]; then
        if [[ "$wmode" == https ]]; then
            case "${ABOX_LANG:-zh}" in
                *) confirm_prompt="$(tr_msg wl_confirm_https)" ;;
            esac
        elif [[ "$wmode" == http ]]; then
            case "${ABOX_LANG:-zh}" in
                *) confirm_prompt="$(tr_msg wl_confirm_http)" ;;
            esac
        else
            case "${ABOX_LANG:-zh}" in
                *) confirm_prompt="$(tr_msg wl_confirm_cf)" ;;
            esac
        fi
    fi
    if (( ! _bind_chosen )) && ! confirm_yes_no "$confirm_prompt"; then return 0; fi

    wallos_pull_or_restore_image "$arch" || { msg "${RED}$(tr_msg wl_iu_src_unavail)${NC}"; return 1; }
    image="$WALLOS_IMAGE_RESULT"
    image_version="$WALLOS_IMAGE_VERSION"
    mkdir -p "$WALLOS_DIR/db" "$WALLOS_DIR/logos" "$WALLOS_DIR/backups" || return 1
    chmod 750 "$WALLOS_DIR" "$WALLOS_DIR/db" "$WALLOS_DIR/logos" || return 1
    if [[ ! -f "$WALLOS_DIR/.A-Box-managed" ]]; then
        printf '%s\n' 'A-Box managed Wallos' > "$WALLOS_DIR/.A-Box-managed" || return 1
        chmod 600 "$WALLOS_DIR/.A-Box-managed" || return 1
    fi
    if (( running == 1 )); then
        if (( was_running == 1 )); then _wallos_stop_id "$old_container_id" || return 1; fi
        stamp=$(date -u '+%Y%m%dT%H%M%SZ')
        backup=$(wallos_create_backup "$stamp") || { (( was_running == 0 )) || _wallos_start_id "$old_container_id" || true; msg "${RED}$(tr_msg wl_iu_backup_fail)${NC}"; return 1; }
        wallos_upgrade_journal_write active "$old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$old_container_id" || {
            (( was_running == 0 )) || _wallos_start_id "$old_container_id" || true
            msg "${RED}$(tr_msg wl_iu_journal_fail)${NC}"
            return 1
        }
        docker rm "$old_container_id" >/dev/null 2>&1 || {
            wallos_recover_interrupted_upgrade || msg "${RED}$(tr_msg wl_iu_start_fail)${NC}"
            return 1
        }
    fi

    # R8C15-02: ask before docker run publishes the port. A refusal must
    # not leave a public Docker DNAT publication: DNAT bypasses UFW INPUT,
    # so skipping allowPort alone does not honor the refusal. When a
    # refused public bind would otherwise be published, force loopback.
    # R7-F15-2: firewall increments opened by this attempt, as
    # "backend|spec|proto" lines (firewalld lines carry "|scope|zone"; see wallos_fw_open_once). Rolled back
    # if the install fails after opening them.
    local -a _fw_added=()
    local _fw_open_out=''
    local _fw_refused=0
    local _fw_open_rc=0
    if [[ "$bind_address" == 0.0.0.0 ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        if confirm_yes_no "$(tprintf wl_iu_ufw_q "$port")"; then
            _fw_open_out=$(wallos_fw_open_once "$port" tcp) || msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}"
            [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        else
            _fw_refused=1
        fi
    elif [[ "$bind_address" == 0.0.0.0 ]] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if confirm_yes_no "$(tprintf wl_iu_fwd_q "$port")"; then
            _fw_open_out=$(wallos_fw_open_once "$port" tcp) || msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}"
            [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        else
            _fw_refused=1
        fi
    fi
    if (( _fw_refused == 1 )) && { [[ -n "$old_bind" ]] || (( _bind_chosen == 1 )); }; then
        # R14-08: a refused public opening demotes the mode to local as
        # well as the bind; MODE=http would otherwise keep advertising
        # a public URL and survive as 'keep public HTTP' on rerun.
        bind_address='127.0.0.1'
        if [[ "$wmode" == http ]]; then
            wmode='local'
        fi
    fi

    # 2do: the https front (Caddy on $pubport, plus 80/tcp for ACME
    # issuance) publishes just like the http front, but the prompt
    # above only ever fires for a 0.0.0.0 container bind — https mode
    # sets bind_address=127.0.0.1, so no firewall question was ever
    # asked and the front went public unasked. Refusal cannot mean
    # "loopback Caddy" (that defeats https mode), so it aborts the
    # switch instead: the old container is restored from the upgrade
    # journal, like the other failure paths at this stage. The
    # question is interactive-only: confirm_yes_no reads EOF as a
    # refusal, so an unguarded prompt would abort every automated
    # https upgrade on a firewalled host.
    local _fw_https_refused=0
    if [[ "$wmode" == https ]] && [[ -t 0 ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        if confirm_yes_no "$(tprintf wl_iu_ufw_q_https "$pubport")"; then
            _fw_open_out=$(wallos_fw_open_once "$pubport" tcp) || msg "${YELLOW}$(tr_msg wl_iu_ufw_fail)${NC}"
            [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        else
            _fw_https_refused=1
        fi
    elif [[ "$wmode" == https ]] && [[ -t 0 ]] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if confirm_yes_no "$(tprintf wl_iu_fwd_q_https "$pubport")"; then
            _fw_open_out=$(wallos_fw_open_once "$pubport" tcp) || msg "${YELLOW}$(tr_msg wl_iu_fwd_fail)${NC}"
            [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        else
            _fw_https_refused=1
        fi
    fi
    if (( _fw_https_refused == 1 )); then
        msg "${RED}$(tr_msg wl_iu_https_fw_abort)${NC}"
        if (( running == 1 )); then
            wallos_recover_interrupted_upgrade >/dev/null 2>&1 || true
        fi
        # 2do-refusal: the abort above does not close the front. The
        # A-Box ACCEPT rules for the front ports were added by an
        # earlier successful install (allowPort) and sit at the head
        # of INPUT, ahead of the ufw jump, so they bypass UFW
        # entirely -- the front stays reachable while the user
        # believes they refused. Remove the raw iptables ACCEPT
        # rules (v4+v6) for the public port and 80, plus any
        # UFW/firewalld-owned form of the same ports, and persist
        # the removal so a reboot cannot bring the rules back. A
        # removal failure is LOUD: never report the refusal as
        # honored while a port may still be open.
        local _refuse_cleanup_failed=0 _rp=''
        for _rp in "$pubport" 80; do
            wallos_remove_abox_iptables_accept "$_rp" tcp || _refuse_cleanup_failed=1
            remove_abox_native_firewall_rule "$_rp" tcp || _refuse_cleanup_failed=1
        done
        # R7-F15-2: also roll back any firewall opening made by this
        # attempt; a failed rollback joins the loud refusal-cleanup
        # failure flag below (the port may still be open).
        wallos_fw_rollback_added "${_fw_added[@]}" || _refuse_cleanup_failed=1
        save_firewall_rules || _refuse_cleanup_failed=1
        if (( _refuse_cleanup_failed == 1 )); then
            msg "${RED}$(tr_msg wl_iu_https_fw_refuse_cleanup_fail)${NC}"
        fi
        return 1
    fi

    # U217: in the fully non-interactive preserve path (_bind_chosen==0),
    # an empty old_bind means the old container published nothing; do
    # not invent a loopback publication from the 127.0.0.1 default.
    # Any explicit mode choice (_bind_chosen==1) or a non-empty old_bind
    # keeps the publication, and the health gate runs in unpublished
    # mode when nothing is published.
    local -a _pub_args=()
    if [[ -n "$old_bind" ]] || (( _bind_chosen == 1 )); then
        _pub_args=(-p "$bind_address:$port:80/tcp")
    fi
    # W1: pre-seed a fresh database before the first docker run (see
    # wallos_preseed_db). A failed seed aborts here, before any container
    # exists; on the upgrade path an interrupted-upgrade recovery is
    # attempted instead of starting a doomed container.
    if ! wallos_preseed_db "$image"; then
        if (( running == 1 )); then
            wallos_recover_interrupted_upgrade >/dev/null 2>&1 || true
        fi
        msg "${RED}$(tr_msg wl_iu_preseed_fail)${NC}"
        wallos_fw_rollback_added "${_fw_added[@]}" || true
        return 1
    fi
    # R15-F15-02: record the container ID THIS attempt creates
    # (--cidfile), so failure cleanup can delete exactly that
    # container instead of whatever now owns the 'wallos' name.
    # GPT (astra, high) supplied the --cidfile design; a fresh
    # docker run that creates a container and then fails to start
    # it is still recorded (and cleaned up), while a name conflict
    # writes no cidfile and is therefore never deleted.
    local _wallos_cid_dir='' _wallos_created_id='' _wallos_cid_path=''
    if (( running == 1 )); then
        # H7-F1: the upgrade path binds the created container to the
        # durable transaction cidfile in WALLOS_DIR (not a /tmp mktemp
        # dir): a crash between docker run and the journal refresh
        # below must leave evidence recovery can trust. A stale
        # cidfile from an earlier attempt is dropped first.
        _wallos_cid_path="$WALLOS_DIR/.upgrade-transaction.cid"
        rm -f -- "$_wallos_cid_path" 2>/dev/null || true
    else
        if ! _wallos_cid_dir=$(mktemp -d "${TMPDIR:-/tmp}/abox-wallos-cid.XXXXXXXXXX"); then
            msg "${RED}Cannot allocate Wallos container-ID file.${NC}"
            # R16-F15-06: roll back this attempt's firewall increments,
            # like the adjacent preseed-failure exit; otherwise the opened
            # ports (and their ledger) survive a failed install.
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            return 1
        fi
        _wallos_cid_path="$_wallos_cid_dir/id"
    fi
    docker run -d --cidfile "$_wallos_cid_path" --name wallos --label com.alariclin.abox.managed=true \
        "${WALLOS_DOCKER_HARDENING[@]}" \
        -v "$WALLOS_DIR/db:/var/www/html/db" \
        -v "$WALLOS_DIR/logos:/var/www/html/images/uploads/logos" \
        -e TZ="$tz" "${_pub_args[@]}" --restart unless-stopped "$image" >/dev/null
    code=$?
    if [[ -f "$_wallos_cid_path" ]]; then
        IFS= read -r _wallos_created_id < "$_wallos_cid_path" || true
    fi
    if (( running == 1 )); then
        # H7-F1: record B in the journal BEFORE the health gate: a
        # health failure (or a crash) after this point must leave
        # recovery able to recognize B as this transaction's own
        # container. A failed refresh deletes B (inside the helper),
        # then recovers, exactly like the health-failure branch.
        if (( code == 0 )) && [[ "$_wallos_created_id" =~ ^[0-9a-f]{64}$ ]]; then
            if ! _wallos_record_created_from_cidfile "$_wallos_cid_path" "$old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$old_container_id"; then
                wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_incomplete "${WALLOS_DIR}/.upgrade-transaction" "${backup:-unavailable}")${NC}"
                msg "${RED}$(tr_msg wl_iu_health_kept)${NC}"
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                return 1
            fi
        elif (( code == 0 )); then
            # docker run succeeded but left no usable container ID
            # (no cidfile, no pinnable container): fail closed rather
            # than run the health gate against an unidentified
            # container. The container (if any) is left live and the
            # journal kept, so a later recovery refuses instead of
            # touching an unidentified container.
            msg "${RED}Wallos container created but its ID could not be recorded; refusing to proceed without a pinned container.${NC}"
            wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_incomplete "${WALLOS_DIR}/.upgrade-transaction" "${backup:-unavailable}")${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            return 1
        fi
        rm -f -- "$_wallos_cid_path" 2>/dev/null || true
    else
        rm -f -- "$_wallos_cid_dir/id" 2>/dev/null || true
        rmdir -- "$_wallos_cid_dir" 2>/dev/null || true
    fi
    if (( code != 0 )); then
        :
    elif (( ${#_pub_args[@]} == 0 )); then
        wallos_wait_healthy "$port" unpublished || code=1
    elif ! wallos_wait_healthy "$port"; then
        code=1
    fi
    if (( code != 0 )); then
        # R15-F15-02: delete only the container this attempt created,
        # by the --cidfile ID recorded after docker run (plus the
        # R10C15-01 ownership-label re-check). A name conflict writes
        # no cidfile, so a pre-existing or concurrently appearing
        # container (managed or foreign) is never deleted by name.
        # No recorded ID means leave it and fail loudly (fail-closed).
        if [[ "$_wallos_created_id" =~ ^[0-9a-f]{64}$ ]] &&
            [[ "$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_wallos_created_id" 2>/dev/null || true)" == "true" ]]; then
            docker rm -f "$_wallos_created_id" >/dev/null 2>&1 || true
        else
            msg "${YELLOW}No verified container ID for this attempt; not deleting 'wallos' by name.${NC}" >&2
        fi
        if (( running == 1 )); then
            wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_incomplete "${WALLOS_DIR}/.upgrade-transaction" "${backup:-unavailable}")${NC}"
        fi
        msg "${RED}$(tr_msg wl_iu_health_kept)${NC}"
        wallos_fw_rollback_added "${_fw_added[@]}" || true
        return 1
    fi

    # 2ez follow-up: back up the tunnel token BEFORE the gate tears the
    # old frontend down — wallos_cftunnel_teardown deletes the token
    # file, and without this copy a torn-down tunnel could never be
    # rebuilt by recovery. A failed backup refuses the switch here,
    # with the old frontend still serving (fail-closed).
    if ! wallos_preserve_cftoken; then
        msg "${RED}$(tr_msg wl_iu_cftoken_backup_fail)${NC}"
        wallos_fw_rollback_added "${_fw_added[@]}" || true
        _wallos_abort_started_install
        return 1
    fi

    # F02-GATE-START (R1C15-02): the old public frontend must be gone
    # BEFORE the new mode is committed. The old order committed first
    # and discarded teardown failure (|| true), so a stuck old Caddy /
    # tunnel kept serving publicly under a new-mode record. Any
    # teardown failure fails the switch here, before any commit.
    # Teardown returns 0 when the front is absent (nothing to stop),
    # so a fresh install or a switch from a frontless mode is unaffected.
    # NOTE (2ez follow-up): on a later write_state failure the torn-down
    # old front IS rebuilt by recovery from the state file, which still
    # holds the old mode/pubport/cfhost because the failed commit never
    # overwrote it; the tunnel token is preserved by wallos_preserve_cftoken
    # above so a torn-down tunnel can authenticate again. A failed
    # rebuild still refuses and keeps the journal (fail-closed).
    if [[ "$wmode" == https ]]; then
        if ! wallos_cftunnel_teardown >/dev/null 2>&1; then
            msg "${RED}$(tr_msg wl_iu_teardown_fail)${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
    elif [[ "$wmode" == cftunnel ]]; then
        if ! wallos_https_teardown >/dev/null 2>&1; then
            msg "${RED}$(tr_msg wl_iu_teardown_fail)${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
    elif [[ "$_old_mode" == https || "$_old_mode" == cftunnel ]]; then
        # S148 (moved here from the post-commit branch): both fronts
        # always run (no short-circuit) before judging.
        local _td_ok=1
        wallos_https_teardown >/dev/null 2>&1 || _td_ok=0
        wallos_cftunnel_teardown >/dev/null 2>&1 || _td_ok=0
        if (( _td_ok == 0 )); then
            msg "${RED}$(tr_msg wl_iu_teardown_fail)${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
    fi
    # F02-GATE-END
    msg "${GREEN}$(tprintf wl_iu_running "${image_version:-$image}")${NC}"
    if [[ "$bind_address" == 127.0.0.1 ]]; then security_note=$(tr_msg wl_iu_note_local)
    else security_note=$(tprintf wl_iu_note_http_pub "$port"); fi
    if [[ "$wmode" == https ]]; then
        if ! wallos_https_setup "$pubport" "$port"; then
            wallos_https_teardown >/dev/null 2>&1 || true
            local _fb=0
            if [[ -t 0 ]]; then
                case "${ABOX_LANG:-zh}" in
                    *) confirm_yes_no "$(tr_msg wl_fb_prompt)" && _fb=1 ;;
                esac
            fi
            local _rebind_ok=0
            if (( _fb == 1 )) && wallos_http_rebind "$pubport" "$image" "$tz" "$_wallos_created_id"; then _rebind_ok=1; fi
            if (( _rebind_ok == 1 )); then
                # H7-F1: the rebind replaced B with B2; the journal
                # must name B2 before anything commits it. Refresh the
                # local ID from the global the rebind recorded. A
                # missing/invalid ID on the upgrade path refuses the
                # install (the journal still names B, which the rebind
                # removed) and recovers the old container.
                if [[ "$WALLOS_CREATED_CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]]; then
                    _wallos_created_id="$WALLOS_CREATED_CONTAINER_ID"
                elif (( running == 1 )); then
                    msg "${RED}Wallos rebind succeeded but the replacement container ID could not be recorded; refusing to commit an unidentified container.${NC}"
                    wallos_fw_rollback_added "${_fw_added[@]}" || true
                    _wallos_abort_started_install
                    return 1
                fi
                if (( running == 1 )) && ! wallos_upgrade_journal_write active "$old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$old_container_id" "$_wallos_created_id"; then
                    msg "${RED}$(tr_msg wl_iu_health_meta_fail)${NC}"
                    wallos_fw_rollback_added "${_fw_added[@]}" || true
                    _wallos_abort_started_install
                    return 1
                fi
                wmode='http'; port="$pubport"; bind_address='0.0.0.0'
                # 07h2-H1: a failed state save after the HTTP fallback
                # must fail the install, not just warn: the live
                # service is now HTTP on 0.0.0.0 while the persisted
                # state may still hold the old mode/port, and
                # continuing would commit the journal and delete the
                # recovery material (S143). Same failure handling as
                # the sibling branches below: roll the firewall
                # increments back and recover the old container, so
                # the journal stays active for the next run.
                if ! wallos_write_state "$image" "$port" "$tz" "$bind_address" http '' "$cfhost" "$image_version"; then
                    msg "${RED}$(tr_msg wl_iu_state_save_fail)${NC}"
                    wallos_fw_rollback_added "${_fw_added[@]}" || true
                    _wallos_abort_started_install
                    return 1
                fi
                case "${ABOX_LANG:-zh}" in
                    *) security_note="$(tr_msg wl_note_http)" ;;
                esac
            elif (( _fb == 1 )); then
                # U122: rebind already removed the healthy container; rebuild
                # the pre-fallback container instead of leaving no service.
                # A declined fallback (_fb==0) never removed anything, so it
                # takes the plain failure branch below.
                local _fb_restored=0
                if wallos_restore_direct_container "$image" "$port" "$tz" "$bind_address" "$image_version" "$_wallos_created_id"; then
                    msg "${YELLOW}$(tr_msg wl_iu_fb_restored)${NC}"
                    _fb_restored=1
                else
                    msg "${RED}$(tr_msg wl_iu_https_incomplete)${NC}"
                fi
                # H7-F1: the restore replaced the (rebind-removed)
                # container with a fresh one; refresh the journal with
                # the ID it recorded, so the recovery below sees the
                # live container as this transaction's own. Best effort
                # here: the install is already failing, and a failed
                # refresh must not mask the recovery below.
                if [[ "$WALLOS_CREATED_CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]]; then
                    _wallos_created_id="$WALLOS_CREATED_CONTAINER_ID"
                    if (( running == 1 )); then
                        wallos_upgrade_journal_write active "$old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$old_container_id" "$_wallos_created_id" || true
                    fi
                fi
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                if (( running == 1 )); then
                    wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_fail "$WALLOS_DIR/.upgrade-transaction" "$backup")${NC}"
                elif (( _fb_restored == 0 )); then
                    # H-3: the restore above rebuilt a healthy,
                    # state-backed container; only delete B when the
                    # restore failed and left no state behind.
                    _wallos_abort_started_install
                fi
                return 1
            else
                msg "${RED}$(tr_msg wl_iu_https_incomplete)${NC}"
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                _wallos_abort_started_install
                return 1
            fi
        fi
        # U123: only when https is still the final mode; a downgrade to http
        # above must keep its plaintext warning, not be overwritten here.
        if [[ "$wmode" == https ]]; then
            case "${ABOX_LANG:-zh}" in
                *) security_note="$(tr_msg wl_note_https)" ;;
            esac
        fi
    elif [[ "$wmode" == cftunnel ]]; then
        if [[ -n "$cftoken" ]]; then
        # R15C15-01: back up the existing token into the upgrade
        # transaction before overwriting; restored on setup
        # failure and by interrupted-upgrade recovery.
        if [[ -f "$WALLOS_CF_TOKEN_FILE" && ! -L "$WALLOS_CF_TOKEN_FILE" ]]; then
            if ! cp -a "$WALLOS_CF_TOKEN_FILE" "$WALLOS_DIR/.upgrade-transaction.cftoken"; then
                msg "${RED}[!] Failed to back up the existing tunnel token; refusing to overwrite it.${NC}"
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                _wallos_abort_started_install
                return 1
            fi
            if ! chmod 600 "$WALLOS_DIR/.upgrade-transaction.cftoken"; then
                msg "${RED}[!] Failed to secure the tunnel token backup; refusing to overwrite it.${NC}"
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                _wallos_abort_started_install
                return 1
            fi
        fi
            write_file_atomically_from_stdin "$WALLOS_CF_TOKEN_FILE" 600 <<< "TUNNEL_TOKEN=${cftoken}" || {
                msg "${RED}$(tr_msg wallos_install_or_update_token_save_failed)${NC}"
                wallos_fw_rollback_added "${_fw_added[@]}" || true
                _wallos_abort_started_install
                return 1
            }
            cftoken=''
        fi
        if ! wallos_cftunnel_setup "$cfhost"; then
            msg "${RED}$(tr_msg wl_iu_cf_incomplete)${NC}"
        # R15C15-01: restore the pre-replacement token so the
        # original tunnel can be rebuilt.
        if [[ -f "$WALLOS_DIR/.upgrade-transaction.cftoken" && ! -L "$WALLOS_DIR/.upgrade-transaction.cftoken" ]]; then
            # R14-01: a failed restore is reported, and a tunnel still
            # running on the new token is restarted so it re-reads the
            # restored file; the original setup failure is returned.
            if cp -a "$WALLOS_DIR/.upgrade-transaction.cftoken" "$WALLOS_CF_TOKEN_FILE" 2>/dev/null && chmod 600 "$WALLOS_CF_TOKEN_FILE" 2>/dev/null; then
                if is_service_running abox-wallos-cftunnel 2>/dev/null; then
                    if ! wallos_cftunnel_restart; then
                        # Conservative containment: do not leave the
                        # tunnel running on the new token.
                        if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
                            systemctl stop abox-wallos-cftunnel.service >/dev/null 2>&1 || msg "${RED}The tunnel frontend could not be stopped; it may still be running on the new token.${NC}"
                        else
                            rc-service abox-wallos-cftunnel stop >/dev/null 2>&1 || msg "${RED}The tunnel frontend could not be stopped; it may still be running on the new token.${NC}"
                        fi
                        msg "${RED}Recovery could not re-establish the tunnel frontend with the restored token.${NC}"
                    fi
                fi
            else
                msg "${RED}Recovery could not restore the tunnel token; the running tunnel may still use the new token.${NC}"
            fi
        fi
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        case "${ABOX_LANG:-zh}" in
            *) security_note="$(tr_msg wl_note_cf)" ;;
        esac
    fi
    if ! wallos_db_health; then
        case "${ABOX_LANG:-zh}" in
            *) msg "${RED}$(tr_msg wl_health_fail)${NC}" ; msg "$(tr_msg wl_health_fail_repair_hint)" ;;
        esac
        wallos_fw_rollback_added "${_fw_added[@]}" || true
        _wallos_abort_started_install
        return 1
    fi
    # R9C15-02: firewall opens are a post-deployment check, not a
    # best-effort epilogue. They must pass BEFORE the journal is
    # committed below (S143): a persistence failure swallowed after
    # commit left the public port unreachable (and unrecoverable after
    # reboot) while the install reported success. On failure the
    # journal stays active, so the next run recovers. H-10: the failure
    # exits below recover the old container at once instead; only a
    # failed recovery leaves the journal active for the next run.
    if (( _fw_refused == 0 )) && [[ "$wmode" == https ]]; then
        _fw_open_out=$(_wallos_fw_open_tracked "$pubport" tcp); _fw_open_rc=$?
        [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        if (( _fw_open_rc != 0 )); then
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        # R3-NEW-03: _wallos_fw_open_tracked only reports NEW ufw/firewalld
        # ledger entries; on the iptables backend it prints nothing even
        # though allowPort just added the rule, so the registration loop
        # below would never see this port. Register it directly once the
        # open succeeded: reclaim only removes A-Box-owned rules
        # (comment/ledger-gated), so registering an already-open foreign
        # port is a harmless no-op.
        if ! wallos_fw_register_opened "$pubport" tcp; then
            msg "${RED}[!] Failed to record the Wallos firewall opening ${pubport}/tcp; refusing to commit an untracked opening.${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        _fw_open_out=$(_wallos_fw_open_tracked 80 tcp); _fw_open_rc=$?
        [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        if (( _fw_open_rc != 0 )); then
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        # R3-NEW-03: same ledger gap as the public port above (and 80/tcp
        # may already be open from wallos_https_setup's own allowPort,
        # which also leaves no ledger entry). Register directly.
        if ! wallos_fw_register_opened 80 tcp; then
            msg "${RED}[!] Failed to record the Wallos firewall opening 80/tcp; refusing to commit an untracked opening.${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        if ! save_firewall_rules; then
            msg "${RED}$(tr_msg wl_iu_fw_save_fail)${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
    elif (( _fw_refused == 0 )) && [[ "$bind_address" == 0.0.0.0 ]]; then
        _fw_open_out=$(_wallos_fw_open_tracked "$port" tcp); _fw_open_rc=$?
        [[ -n "$_fw_open_out" ]] && mapfile -t -O "${#_fw_added[@]}" _fw_added <<< "$_fw_open_out"
        if (( _fw_open_rc != 0 )); then
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
        # R3-NEW-03: same ledger gap as the https ports above; the http
        # container port (e.g. 29503) would otherwise never be registered.
        wallos_fw_register_opened "$port" tcp || msg "${YELLOW}[!] Failed to record the Wallos firewall opening ${port}/tcp; a later uninstall may leave the port open.${NC}"
        if ! save_firewall_rules; then
            msg "${RED}$(tr_msg wl_iu_fw_save_fail)${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            _wallos_abort_started_install
            return 1
        fi
    fi
    # H7-STATE: persist the install state on EVERY successful path
    # (local / http / https / cftunnel, fresh install and upgrade) at
    # this single commit point, before the S143 journal commit below:
    # the M-28 reclaim below and the backup pre-check both assume
    # this file already holds the NEW port/pubport, and no success
    # path wrote it before (only the HTTPS->HTTP fallback branch
    # did). A failed save fails the install like the 07h2-H1
    # fallback branch above: roll the firewall increments back and
    # recover the old container, so the journal stays active for the
    # next run.
    if ! wallos_write_state "$image" "$port" "$tz" "$bind_address" "$wmode" "$pubport" "$cfhost" "$image_version"; then
        msg "${RED}$(tr_msg wl_iu_state_save_fail)${NC}"
        wallos_fw_rollback_added "${_fw_added[@]}" || true
        _wallos_abort_started_install
        return 1
    fi
    # S143: the upgrade journal is the rollback material. It must not be
    # committed (phase=committed, which recover treats as "already done"
    # and only deletes) or deleted before the post-deployment checks
    # (HTTPS setup, tunnel setup, database health) have passed: a
    # post-check failure after deletion left a half-deployed state with
    # no journal to recover from. Commit and delete it only now, after
    # all checks passed.
    if (( running == 1 )); then
        if ! wallos_upgrade_journal_write committed "$old_image" "$old_port" "$old_tz" "$old_bind" "$backup" "$was_running" "$old_image_id" "$old_container_id" "$_wallos_created_id"; then
            msg "${RED}$(tr_msg wl_iu_health_meta_fail)${NC}"
            # 07h2-M2: same R15-F15-02 protection as the health-check
            # failure branch above: delete only the container THIS
            # attempt created, by its --cidfile ID plus the ownership-
            # label re-check. Never delete by name here: a concurrently
            # appearing container that now owns 'wallos' must survive.
            # No verified ID means leave it and fail loudly.
            if [[ "$_wallos_created_id" =~ ^[0-9a-f]{64}$ ]] &&
                [[ "$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' "$_wallos_created_id" 2>/dev/null || true)" == "true" ]]; then
                docker rm -f "$_wallos_created_id" >/dev/null 2>&1 || true
            else
                msg "${YELLOW}No verified container ID for this attempt; not deleting 'wallos' by name.${NC}" >&2
            fi
            wallos_recover_interrupted_upgrade || msg "${RED}$(tprintf wl_iu_rb_fail "$WALLOS_DIR/.upgrade-transaction" "$backup")${NC}"
            wallos_fw_rollback_added "${_fw_added[@]}" || true
            return 1
        fi
        # 07h2-M1: the journal is already committed at this point, so
        # a failed cleanup must only warn: rolling back the firewall
        # increments would leave the new (running) deployment
        # unreachable, and recovery treats a committed journal as
        # delete-only, so no later recovery could restore it. The
        # leftover journal is cleared on the next run.
        rm -f -- "$WALLOS_DIR/.upgrade-transaction" || msg "${YELLOW}$(tr_msg wl_iu_journal_pending)${NC}"
    fi
    # M-28: this attempt's firewall openings are now live with the new
    # mode; register them, then reclaim any previously registered
    # Wallos port the new mode no longer needs (mode switch, port
    # change). Keep-set: https keeps its public port + 80/tcp (ACME
    # HTTP-01); http keeps the container port; local/cftunnel keep
    # none (the tunnel/local front needs no inbound port).
    local _fw_entry='' _fw_spec='' _fw_proto=''
    local -a _fw_keep=()
    for _fw_entry in "${_fw_added[@]}"; do
        IFS='|' read -r _ _fw_spec _fw_proto _ <<< "$_fw_entry"
        if [[ -n "$_fw_spec" && -n "$_fw_proto" ]]; then wallos_fw_register_opened "$_fw_spec" "$_fw_proto" || msg "${YELLOW}[!] Failed to record the Wallos firewall opening ${_fw_spec}/${_fw_proto}; a later uninstall may leave the port open.${NC}"; fi
    done
    # M-28 follow-up: a pre-registry install switching modes or ports
    # leaks its old openings - the state file above already holds the
    # NEW port/pubport, so the reclaim's own import cannot see them.
    # Import the previous ports explicitly (live-checked, so a port
    # that was never opened registers nothing). Best effort here: a
    # failed import is retried by the reclaim below, which warns.
    if [[ -n "$old_port" ]]; then wallos_fw_import_legacy_registry "${old_port}/tcp" || true; fi
    if [[ -n "$_old_pubport" ]]; then wallos_fw_import_legacy_registry "${_old_pubport}/tcp" || true; fi
    if [[ "$wmode" == https ]]; then _fw_keep=("${pubport}/tcp" '80/tcp');
    elif [[ "$wmode" == http ]]; then _fw_keep=("${port}/tcp"); fi
    wallos_fw_reclaim_registered "${_fw_keep[@]}" || msg "${YELLOW}[!] Failed to reclaim a stale Wallos firewall opening; check the firewall rules manually.${NC}"
    wallos_php_gate_warn || true
    # 2hp: build the jail BEFORE printing URLs/checklist, so the
    # fail2ban claims below reflect the live jail state.
    wallos_bruteforce_protection "$port" "$bind_address" "$wmode" || true
    wallos_public_urls "$port"
    msg "${YELLOW}${security_note}${NC}"
    if [[ "$bind_address" == 0.0.0.0 ]]; then
        msg "${CYAN}$(tr_msg wl_iu_check_t)${NC}"
        msg "  $(tprintf wl_iu_check_1 "$port")"
        msg "  $(tr_msg wl_iu_check_2)"
        if wallos_fail2ban_jail_active 2>/dev/null; then
            msg "  $(tr_msg wl_iu_check_3)"
        else
            msg "  $(tr_msg wl_iu_check_3_off)"
        fi
    fi
    # R15C15-01: success (all checks passed); the new token is
    # verified, so the pre-replacement backup is no longer needed.
    rm -f -- "$WALLOS_DIR/.upgrade-transaction.cftoken" 2>/dev/null || true
    [[ -z "$backup" ]] || msg "$(tprintf wl_backup "$backup")"
}

wallos_container_php_version() {
    command -v docker >/dev/null 2>&1 || return 1
    # H7rest: address the pinned container ID, not the name, so a
    # retaken name cannot report a foreign container's PHP version.
    # Read-only: an unpinnable container simply reports nothing.
    local _cid=''
    _cid=$(_wallos_container_id 2>/dev/null || true)
    [[ -n "$_cid" ]] || return 1
    docker exec "$_cid" php -v 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# php2shell fix line per PHP branch (2026-10-21 PHP security release):
# 8.2 -> 8.2.35, 8.3 -> 8.3.36, 8.4 -> 8.4.27, 8.5 -> 8.5.12.
wallos_php_fixline() { # $1 = x.y.z
    case "${1%.*}" in
        8.2) echo '8.2.35' ;;
        8.3) echo '8.3.36' ;;
        8.4) echo '8.4.27' ;;
        8.5) echo '8.5.12' ;;
        *) return 1 ;;
    esac
}

wallos_php_is_patched() { # $1 = x.y.z (branch must have a fix line)
    local _fix='' _x='' _y='' _z='' _fx='' _fy='' _fz=''
    _fix=$(wallos_php_fixline "$1") || return 1
    IFS=. read -r _x _y _z <<< "$1"
    IFS=. read -r _fx _fy _fz <<< "$_fix"
    (( 10#${_x:-0} > 10#${_fx:-0} )) && return 0
    (( 10#${_x:-0} < 10#${_fx:-0} )) && return 1
    (( 10#${_y:-0} > 10#${_fy:-0} )) && return 0
    (( 10#${_y:-0} < 10#${_fy:-0} )) && return 1
    (( 10#${_z:-0} >= 10#${_fz:-0} ))
}

# Echoes one of: patched | vulnerable | unknown.
wallos_php2shell_state() { # $1 = x.y.z (may be empty)
    local _v="${1:-}" _mj='' _mm=''
    [[ "$_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo unknown; return 0; }
    if wallos_php_fixline "$_v" >/dev/null 2>&1; then
        if wallos_php_is_patched "$_v"; then echo patched; else echo vulnerable; fi
        return 0
    fi
    # Branch outside the advisory table: anything newer than 8.5
    # postdates the advisory; anything older has no fix at all.
    _mj="${_v%%.*}"; _mm="${_v#*.}"; _mm="${_mm%%.*}"
    if (( 10#${_mj:-0} > 8 || ( 10#${_mj:-0} == 8 && 10#${_mm:-0} > 5 ) )); then echo patched; else echo vulnerable; fi
}

wallos_php_gate_warn() {
    local _v='' _st='' _fix=''
    _v=$(wallos_container_php_version) || true
    [[ "$_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    _st=$(wallos_php2shell_state "$_v")
    if [[ "$_st" == vulnerable ]]; then
        _fix=$(wallos_php_fixline "$_v" || echo '-')
        msg "${RED}$(tprintf wl_php_bad "$_v" "$_fix")${NC}"
    else
        msg "${GREEN}$(tprintf wl_php_ok "$_v")${NC}"
    fi
}

wallos_status() {
    local port
    if ! docker container inspect wallos >/dev/null 2>&1; then
        msg "$(tr_msg wl_st_not_installed)"
        return 0
    fi
    docker ps -a --filter name='^/wallos$' --format 'Container: {{.Names}} | Status: {{.Status}} | Image: {{.Image}}'
    if wallos_db_health quick; then
        msg "${GREEN}$(tr_msg wl_st_health_ok)${NC}"
    else
        msg "${RED}$(tr_msg wl_st_health_bad)${NC}"
    fi
    local _php_v='' _php_st=''
    _php_v=$(wallos_container_php_version) || true
    if [[ "$_php_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _php_st=$(wallos_php2shell_state "$_php_v")
        if [[ "$_php_st" == vulnerable ]]; then
            msg "${RED}$(tprintf wl_st_php_bad "$_php_v")${NC}"
        else
            msg "${GREEN}$(tprintf wl_st_php_ok "$_php_v")${NC}"
        fi
    fi
    if [[ "$(wallos_state_value MODE 2>/dev/null || true)" == https ]]; then
        local _crt='' _exp=''
        _crt=$(find /etc/ddr/wallos-caddy/data -name '*.crt' -type f 2>/dev/null | head -n 1 || true)
        if [[ -n "$_crt" ]] && command -v openssl >/dev/null 2>&1; then
            _exp=$(openssl x509 -enddate -noout -in "$_crt" 2>/dev/null | sed 's/^notAfter=//')
            msg "$(tprintf wl_st_cert_exp "$_exp")"
        fi
        # Real handshake state (both legs), not just certificate files:
        # a present-but-unselectable certificate reports healthy here no
        # longer (2026-10-21 lesson).
        local _wport='' _wip='' _legs=''
        _wport=$(wallos_state_value PUBPORT 2>/dev/null || true)
        # M-28: same pref-independent lookup as https_setup; with
        # IP_PREF=ipv6 the old get_public_ip call returned IPv6 and
        # this check was silently skipped on dual-stack hosts.
        _wip=$(wallos_public_ipv4 2>/dev/null || true)
        if [[ "$_wport" =~ ^[0-9]+$ && "$_wip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if command -v openssl >/dev/null 2>&1; then
                if _legs=$(wallos_tls_handshake_check "$_wport" "$_wip"); then
                    msg "${GREEN}$(tr_msg wl_st_tls_ok)${NC}"
                else
                    msg "${RED}$(tprintf wl_st_tls_fail "$_legs")${NC}"
                fi
            fi
        else
            # M-28: say so instead of silently skipping: no public
            # IPv4 means the TLS handshake check cannot run (Wallos
            # HTTPS needs IPv4). 80/tcp is shared with the Hy2
            # HTTP-01 challenge (altPort 80), so the TLS front and
            # the challenge coexist on the same port by design.
            if [[ ! "$_wport" =~ ^[0-9]+$ ]]; then
                msg "No Wallos public port (PUBPORT) recorded; TLS handshake check skipped."
            else
                msg "No public IPv4 address detected; TLS handshake check skipped (Wallos HTTPS needs IPv4)."
            fi
        fi
    fi
    port=$(wallos_state_value PORT 2>/dev/null || true)
    if [[ "$port" =~ ^[0-9]+$ ]]; then wallos_public_urls "$port"; else
        msg "$(tr_msg wl_st_state_missing)"
    fi
}

wallos_resume_after_backup() {
    local was_running="${1:-0}" backup_path="${2:-}" _cid="${3:-}"
    [[ "$was_running" == 0 || "$was_running" == 1 ]] || return 2
    [[ "$was_running" == 1 ]] || return 0
    # H7 (R58b-M1): when the caller pinned the container ID, restart
    # that ID, never the re-resolved name. No ID (old callers and the
    # self-test) keeps the previous by-name behaviour.
    if [[ -n "$_cid" ]]; then
        if _wallos_start_id "$_cid"; then return 0; fi
    elif docker start wallos >/dev/null 2>&1; then
        return 0
    fi
    msg "${RED}$(tprintf wl_bn_restart_fail "${backup_path:-not-created}")${NC}" >&2
    return 1
}

wallos_backup_now() {
    local stamp backup was_running=0 _inspect_err _running _managed _cid=''
    [[ -f "$WALLOS_DIR/.A-Box-managed" && ! -L "$WALLOS_DIR/.A-Box-managed" ]] || { msg "$(tr_msg wl_bn_none)"; return 1; }
    # R6C15-03: an inspect failure is NOT "stopped". Only a daemon-confirmed
    # absence ("No such container/object", matched case-insensitively by
    # _wallos_container_gone -- Docker 29 reports it lowercase -- and
    # confirmed by `docker ps -a`) allows an offline backup; any other
    # failure (daemon unreachable, state query failure, unexpected state)
    # leaves the running state unknown, and a live tar of a WAL-mode database
    # can silently drop committed records at checkpoint timing while gzip/tar
    # checks still pass. Fail closed instead.
    if _inspect_err=$(docker container inspect wallos 2>&1 >/dev/null); then
        # R7-F15-4: refuse a foreign same-name container (R14-07 idiom):
        # the stop/start below must only ever touch an A-Box-managed one.
        if ! _managed=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null) || [[ "$_managed" != 'true' ]]; then
            msg "${RED}$(tr_msg wl_iu_unmanaged)${NC}" >&2
            return 1
        fi
        # H7 (R58b-M1): pin the container ID next to the label check;
        # the stop below and the resume after the backup address the
        # ID, never the re-resolved name.
        _cid=$(_wallos_container_id) || { msg "${RED}$(tr_msg wl_bn_docker_unknown)${NC}" >&2; return 1; }
        _running=$(docker inspect -f '{{.State.Running}}' wallos 2>/dev/null) || { msg "${RED}$(tr_msg wl_bn_docker_unknown)${NC}" >&2; return 1; }
        if [[ "$_running" == true ]]; then
            _wallos_stop_id "$_cid" || return 1
            was_running=1
        elif [[ "$_running" != false ]]; then
            msg "${RED}$(tr_msg wl_bn_docker_unknown)${NC}" >&2
            return 1
        fi
    elif _wallos_container_gone "$_inspect_err"; then
        : # daemon confirmed the container is absent: offline backup is safe
    else
        msg "${RED}$(tr_msg wl_bn_docker_unknown)${NC}" >&2
        _wallos_show_docker_err "$_inspect_err" >&2
        return 1
    fi
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    if ! backup=$(wallos_create_backup "$stamp"); then
        wallos_resume_after_backup "$was_running" '' "$_cid" || true
        msg "${RED}$(tr_msg wl_bn_fail)${NC}"
        return 1
    fi
    if ! wallos_resume_after_backup "$was_running" "$backup" "$_cid"; then
        return 1
    fi
    case "${ABOX_LANG:-zh}" in
        *) msg "${GREEN}$(tprintf wl_bn_saved "$backup")${NC}" ;;
    esac
}

# N-11: Interactive / env-driven manual rollback.
_wallos_manual_rollback() {
    local target sel versions
    # Non-interactive fast path: env var selects the version directly.
    if [[ -n "${WALLOS_ROLLBACK_VERSION:-}" ]]; then
        target="$WALLOS_ROLLBACK_VERSION"
        [[ "$target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            msg "${RED}$(tprintf wl_rb_bad_version "$target")${NC}"
            return 1
        }
        wallos_rollback_to_version "$target"
        return $?
    fi
    # Interactive: list retained versions from the mirror (newest first).
    # L3-11-15: a failed mirror-list fetch is loud, never a silent empty
    # list. Capture the list to a temp file so the function's exit status
    # stays observable (mapfile + process substitution would hide it).
    local _mirror_list_failed=0 _local_fallback=0 _vlist_tmp
    _vlist_tmp=$(mktemp /tmp/A-Box-Wallos-verlist.XXXXXX) || return 1
    if ! wallos_mirror_version_list >"$_vlist_tmp" 2>/dev/null; then
        _mirror_list_failed=1
    fi
    mapfile -t versions <"$_vlist_tmp"
    rm -f -- "$_vlist_tmp"
    if (( _mirror_list_failed == 1 )); then
        msg "${RED}$(tr_msg wl_rb_mirror_list_fail)${NC}"
    fi
    if ((${#versions[@]} == 0)); then
        # Fall back to locally available images.
        _local_fallback=1
        # X-12: POSIX field-numeric sort instead of GNU sort -V (BusyBox may lack -V).
        mapfile -t versions < <(docker images --format '{{.Tag}}' 'bellamy/wallos' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | uniq | sed 's/^/v/' || true)
    fi
    if ((${#versions[@]} == 0)); then
        msg "${RED}$(tr_msg wl_rb_none)${NC}"
        return 1
    fi
    # U126: keep only versions strictly older than the installed one; a
    # newer version must never be offered as a "rollback" default.
    # Installed version: container tag first, state VERSION for
    # digest-created containers (their Config.Image has no version).
    local current_tag
    current_tag=$(docker inspect -f '{{.Config.Image}}' wallos 2>/dev/null | sed 's/.*://' || true)
    local _inst_ver="${current_tag#v}"
    if [[ ! "$_inst_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _inst_ver=$(wallos_state_value VERSION 2>/dev/null || true)
    fi
    local _rb_no_default=0
    if [[ ! "$_inst_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _rb_no_default=1
    fi
    local -a _rb_versions=()
    local v
    for v in "${versions[@]}"; do
        if (( _rb_no_default == 1 )); then
            _rb_versions+=("$v")
        elif wallos_version_is_older "${v#v}" "$_inst_ver"; then
            _rb_versions+=("$v")
        fi
    done
    if (( ${#_rb_versions[@]} == 0 )); then
        msg "${YELLOW}$(tr_msg wl_rb_no_other)${NC}"
        return 1
    fi
    versions=("${_rb_versions[@]}")
    # L3-11-15: a local-fallback list is annotated at the menu, so "locally
    # present" is never misread as "the mirror can provide it".
    if (( _local_fallback == 1 )); then
        msg "${YELLOW}$(tr_msg wl_rb_local_only)${NC}"
    fi
    local i=1
    for v in "${versions[@]}"; do
        msg "${YELLOW}$i. $v${NC}"
        i=$((i + 1))
    done
    local prompt
    case "${ABOX_LANG:-zh}" in
        en) prompt="Select version to roll back to [1-${#versions[@]}] (Enter=1): " ;;
        ru) prompt="Выберите версию для отката [1-${#versions[@]}] (Enter=1): " ;;
        fa) prompt="نسخه برای بازگشت انتخاب کنید [1-${#versions[@]}] (Enter=1): " ;;
        zh-tw) prompt="選擇要回滾的版本 [1-${#versions[@]}]（回車=1）： " ;;
        ja)
            prompt="ロールバックするバージョンを選択してください [1-${#versions[@]}]（Enter=1）: " ;;
        *) prompt="选择要回滚的版本 [1-${#versions[@]}]（回车=1）： " ;;
    esac
    read -r -p "$prompt" sel || return 1
    sel=$(normalize_fa_ar_digits "${sel:-}")
    if (( _rb_no_default == 1 )) && [[ -z "$sel" ]]; then
        msg "${RED}$(tr_msg wl_rb_no_default)${NC}"; return 1
    fi
    [[ -z "$sel" ]] && sel=1
    valid_decimal_upto "$sel" "${#versions[@]}" || {
        msg "${RED}$(tr_msg wl_rb_invalid)${NC}"; return 1; }
    sel=$((10#$sel))
    (( sel >= 1 && sel <= ${#versions[@]} )) || {
        msg "${RED}$(tr_msg wl_rb_invalid)${NC}"; return 1; }
    target="${versions[$((sel - 1))]}"
    if (( _rb_no_default == 1 )); then
        confirm_yes_no "$(tprintf wl_rb_confirm_target "$target")" || return 1
    fi
    wallos_rollback_to_version "$target"
}

# M-NEW-02: drop the A-Box-wallos fail2ban jail when its logpath is
# provably gone. After a failed Wallos upgrade whose rollback also
# fails, the container the jail watched is deleted, so the jail's
# logpath points at a removed overlay and `fail2ban-client -t` fails
# (rc=255), which blocks any fail2ban reload/restart and makes the
# next proxy deploy's validate_fail2ban_config warn and roll back
# A-Box's own jail config. Only acts when the jail file carries the
# '# Managed by A-Box' marker AND names a logpath that is not a
# regular file; a jail whose log exists is left untouched, so a
# healthy or still-running instance (including https mode, whose
# logpath is the Caddy log) keeps its protection. The jail is rebuilt
# by wallos_bruteforce_protection on the next successful (re)create,
# so dropping a dangling jail never loses protection permanently.
# Best-effort: always returns 0, never fails a caller.
wallos_fail2ban_drop_stale_jail() {
    local _jail='/etc/fail2ban/jail.d/A-Box-wallos.local' _logpath=''
    [[ -f "$_jail" && ! -L "$_jail" ]] || return 0
    grep -Fxq '# Managed by A-Box' "$_jail" 2>/dev/null || return 0
    _logpath=$(sed -n 's/^logpath[[:space:]]*=[[:space:]]*//p' "$_jail" 2>/dev/null | head -n 1 || true)
    _logpath="${_logpath%"${_logpath##*[![:space:]]}"}"
    [[ "$_logpath" == /* ]] || return 0
    [[ -f "$_logpath" ]] && return 0
    wallos_cleanup_fail2ban_leftovers >/dev/null 2>&1 || true
    return 0
}

# H-10(4): remove the Wallos jail/filter/action files left behind by a
# menu-4 uninstall. A jail whose logpath is gone (Caddy log deleted by
# the https teardown, container overlay gone with `docker rm -f`) makes
# `fail2ban-client -t` fail and blocks the daemon. Only files carrying
# the '# Managed by A-Box' marker are removed (same rule as do_cleanup);
# then reload, and restart only if the jail survives the reload (same
# shape as wallos_bruteforce_protection). Returns 1 on any failure; the
# caller warns only and must not mask an otherwise successful uninstall.
wallos_cleanup_fail2ban_leftovers() {
    local _f _fail=0
    for _f in /etc/fail2ban/jail.d/A-Box-wallos.local /etc/fail2ban/filter.d/A-Box-wallos.conf /etc/fail2ban/action.d/A-Box-wallos-dockeruser.conf; do
        if [[ -f "$_f" ]] && grep -Fxq '# Managed by A-Box' "$_f" 2>/dev/null; then
            rm -f -- "$_f" 2>/dev/null || _fail=1
        fi
    done
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client reload >/dev/null 2>&1 || _fail=1
        if fail2ban-client status A-Box-wallos >/dev/null 2>&1; then
            fail2ban-client restart >/dev/null 2>&1 || _fail=1
        fi
    fi
    return "$_fail"
}

# H-10(3): menu escape hatch for a deterministically failing frontend.
# An interrupted upgrade whose frontend rebuild always fails (port 80
# taken, LE rate-limit, no public IP) loops forever: every install entry
# re-runs recovery, recovery rebuilds the same failing frontend, and the
# journal stays active. Abandoning deletes the transaction record so the
# next install starts from mode selection again, then re-aligns the live
# frontend with the current .abox-state (or says plainly that it could
# not). The running container and its data are never touched here.
wallos_abandon_interrupted_upgrade() {
    local _journal="$WALLOS_DIR/.upgrade-transaction"
    if [[ ! -e "$_journal" && ! -L "$_journal" ]]; then
        msg "${YELLOW}$(tr_msg wl_abandon_none)${NC}"
        return 0
    fi
    confirm_yes_no "$(tr_msg wl_abandon_q)" || return 0
    rm -f -- "$_journal" "$WALLOS_DIR/.upgrade-transaction.frontend" "$WALLOS_DIR/.upgrade-transaction.cftoken" "$WALLOS_DIR/.upgrade-transaction.cid" || {
        msg "${RED}$(tr_msg wl_abandon_rm_fail)${NC}"
        return 1
    }
    local _mode='' _port='' _pubport='' _cfhost=''
    _mode=$(wallos_state_value MODE 2>/dev/null || true)
    _port=$(wallos_state_value PORT 2>/dev/null || true)
    _pubport=$(wallos_state_value PUBPORT 2>/dev/null || true)
    _cfhost=$(wallos_state_value CFHOST 2>/dev/null || true)
    case "$_mode" in
        https)
            if [[ "$_pubport" =~ ^[0-9]+$ && "$_port" =~ ^[0-9]+$ ]] && wallos_https_setup "$_pubport" "$_port"; then
                msg "${GREEN}$(tr_msg wl_abandon_done)${NC}"
            else
                msg "${RED}$(tr_msg wl_abandon_frontend_fail)${NC}"
            fi
            ;;
        cftunnel)
            if [[ "$_cfhost" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && wallos_cftunnel_setup "$_cfhost"; then
                msg "${GREEN}$(tr_msg wl_abandon_done)${NC}"
            else
                msg "${RED}$(tr_msg wl_abandon_frontend_fail)${NC}"
            fi
            ;;
        *)
            wallos_https_teardown >/dev/null 2>&1 || true
            wallos_cftunnel_teardown >/dev/null 2>&1 || true
            msg "${GREEN}$(tr_msg wl_abandon_done)${NC}"
            ;;
    esac
    return 0
}

wallos_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    clear
    msg "${BOLD}${GREEN}$(tr_msg wl_menu_title)${NC}"
    msg "${CYAN}1.${NC} $(tr_msg wl_menu_install)"
    msg "${CYAN}2.${NC} $(tr_msg wl_menu_status)"
    msg "${CYAN}3.${NC} $(tr_msg wl_menu_backup)"
    msg "${CYAN}4.${NC} $(tr_msg wl_menu_remove)"
    msg "${CYAN}5.${NC} $(tr_msg wl_menu_rollback)"
    msg "${CYAN}6.${NC} $(tr_msg wl_menu_repair)"
    msg "${CYAN}7.${NC} $(tr_msg wl_menu_abandon)"
    msg "${CYAN}0.${NC} $(tr_msg mu_back_word)"
    local c
    read -r -p "$(tr_msg wl_menu_prompt)" c || return 0
    c=$(normalize_fa_ar_digits "${c:-}")

    case "$c" in
        1) wallos_install_or_update; pause_return ;;
        2) wallos_status; pause_return ;;
        3) wallos_backup_now; pause_return ;;
        4)
            if [[ -f "$WALLOS_DIR/.A-Box-managed" ]] && confirm_yes_no "$(tprintf wl_remove_q "$WALLOS_DIR")"; then
                # R14-07: only a container carrying the A-Box ownership
                # label may be removed; a same-name foreign container is
                # left alone (the marker alone is not ownership). An
                # absent container is reported as already-gone, not as
                # a removal failure (W6-OBS-2).
                local _wl_label='' _wl_names='' _wl_id=''
                # W6-OBS-2: an absent container is not a removal
                # failure -- it is already gone (e.g. this option was
                # run once already). Say so instead of the misleading
                # wl_remove_fail ("may still exist"). The R14-07
                # outcome below (removal attempted but not verified
                # gone) keeps the failure message.
                if ! docker container inspect wallos >/dev/null 2>&1; then
                    msg "${YELLOW}$(tr_msg wl_remove_absent)${NC}"
                elif ! _wl_label=$(docker inspect -f '{{index .Config.Labels "com.alariclin.abox.managed"}}' wallos 2>/dev/null) || [[ "$_wl_label" != 'true' ]] || ! _wl_id=$(_wallos_container_id); then
                    msg "${RED}$(tr_msg wl_iu_unmanaged)${NC}"
                # B-06 fix: verify the container is actually gone before reporting success.
                # R15-F15-07: verify the container is gone without a pipe.
                # The old `! docker ps ... | grep -qx` read a `docker ps`
                # failure (or a SIGPIPE 141 under pipefail) as "gone" and
                # announced success. Capture the listing first: a failed
                # enumeration refuses, and the exact-line test (same shape
                # as _wallos_container_gone) only passes when the name is
                # truly absent. _wl_names is assigned separately from its
                # `local` declaration: `local x=$(...)` would mask the
                # command's exit status.
                # H7 (R58b-M1): remove by the pinned ID and verify the
                # ID is gone too, not just the name -- a same-name
                # recreation must not pass as the removal.
                elif _wallos_rm_id "$_wl_id" && _wl_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) && [[ $'\n'"$_wl_names"$'\n' != *$'\n'wallos$'\n'* ]] && ! docker container inspect "$_wl_id" >/dev/null 2>&1; then
                    msg "${GREEN}$(tr_msg wl_removed)${NC}"
                    wallos_https_teardown >/dev/null 2>&1 || true
                    wallos_cftunnel_teardown >/dev/null 2>&1 || true
                    # R3-NEW-03: the menu delete never reclaimed the firewall
                    # openings. Seed the registry from the live state
                    # first (a pre-fix install never wrote .fw-opened),
                    # then reclaim everything registered. 80/tcp stays
                    # when the Hysteria HTTP-01 challenge still needs it
                    # (guard inside the reclaim helper).
                    local _wl_pub='' _wl_port=''
                    _wl_pub=$(wallos_state_value PUBPORT 2>/dev/null || true)
                    _wl_port=$(wallos_state_value PORT 2>/dev/null || true)
                    if [[ -n "$_wl_pub" ]]; then wallos_fw_register_opened "$_wl_pub" tcp || msg "${YELLOW}[!] Failed to record the Wallos firewall opening ${_wl_pub}/tcp; a later uninstall may leave the port open.${NC}"; fi
                    if [[ -n "$_wl_port" ]]; then wallos_fw_register_opened "$_wl_port" tcp || msg "${YELLOW}[!] Failed to record the Wallos firewall opening ${_wl_port}/tcp; a later uninstall may leave the port open.${NC}"; fi
                    wallos_fw_reclaim_registered || msg "${YELLOW}[!] Failed to reclaim a Wallos firewall opening during uninstall; check the firewall rules manually.${NC}"
                    wallos_cleanup_fail2ban_leftovers || msg "${YELLOW}$(tr_msg wl_f2b_cleanup_warn)${NC}"
                else
                    msg "${RED}$(tr_msg wl_remove_fail)${NC}"
                fi
            fi
            pause_return ;;
        5)
            # N-11: Manual rollback to a previous version.
            # Non-interactive: WALLOS_ROLLBACK_VERSION=vX.Y.Z selects directly.
            # Interactive: show retained versions, Enter defaults to 1 (previous).
            _wallos_manual_rollback
            pause_return ;;
        6)
            wallos_db_repair_poisoned
            pause_return ;;
        7)
            wallos_abandon_interrupted_upgrade
            pause_return ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $c${NC}"; sleep 1 ;;
    esac
    done
}
other_protocols_menu() {
    # Other protocols submenu: standalone deployments (Trojan-Reality, TUIC,
    # AnyTLS, SOCKS5) that used to live in the toolbox. Self-looping like the
    # other submenus; 0/Enter returns to the main menu.
    while true; do
    clear
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}More Protocols${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  Back"
            ;;
        ru)
            msg "${BOLD}${GREEN}Ещё протоколы${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  Назад"
            ;;
        fa)
            msg "${BOLD}${GREEN}پروتکل‌های بیشتر${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  بازگشت"
            ;;
        zh-tw)
            msg "${BOLD}${GREEN}更多協議${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  返回主選單"
            ;;
        ja)
            msg "${BOLD}${GREEN}追加のプロトコル${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  メインメニューに戻る"
            ;;
        *)
            msg "${BOLD}${GREEN}更多协议${NC}"
            msg "${CYAN}1.${NC}  Trojan-Reality (Xray/sing-box)"
            msg "${CYAN}2.${NC}  TUIC (sing-box)"
            msg "${CYAN}3.${NC}  AnyTLS (sing-box)"
            msg "${CYAN}4.${NC}  SOCKS5/Mixed (Xray/sing-box)"
            msg "${CYAN}5.${NC}  ShadowTLS (sing-box)"
            msg "${CYAN}6.${NC}  Argo (CDN)"
            msg "${CYAN}0.${NC}  返回主菜单"
            ;;
    esac
    local op_choice select_prompt
    case "${ABOX_LANG:-zh}" in en) select_prompt='Select [0-6]: ' ;; ru) select_prompt='Выберите [0–6]: ' ;; fa) select_prompt='انتخاب [۰ تا ۶]: ' ;; ja) select_prompt='選択してください [0-6]: ' ;; zh-tw) select_prompt='請選擇 [0-6]：' ;; *) select_prompt='请选择 [0-6]：' ;; esac
    read -r -p "$select_prompt" op_choice || return 0
    op_choice=$(normalize_fa_ar_digits "${op_choice:-}")
    case "$op_choice" in
        1) trojan_toolbox_entry; pause_return ;;
        2) deploy_with_instance_choice sing-box tuic-in deploy_singbox_tuic; pause_return ;;
        3) deploy_with_instance_choice sing-box anytls-in deploy_singbox_anytls; pause_return ;;
        4) socks5_toolbox_entry; pause_return ;;
        5) deploy_with_instance_choice sing-box shadowtls-in deploy_singbox_shadowtls; pause_return ;;
        6) argo_menu ;;
        0|"") return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $op_choice${NC}"; sleep 1 ;;
    esac
    done
}


# A-Check (companion IP checker): fetched from the pinned test-tools-mirror
# release (see run_acheck_tool), so A-Box tracks the latest A-Check without
# waiting for an A-Box update. Integrity is enforced by the Ed25519
# signature gate: a download only runs when its SHA256 matches the signed
# SHA256SUMS entry and it passes the structural checks (python shebang,
# VERSION marker, project URL, size floor, py_compile). There is
# deliberately NO offline fallback to a previously cached copy: a stale
# cache may predate the signature gate and must never be executed
# without fresh verification.
_acheck_file_valid() {
    local _f="$1" _sz=''
    [[ -f "$_f" ]] || return 1
    _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
    [[ "$_sz" =~ ^[0-9]+$ ]] && (( _sz >= 100000 )) || return 1
    head -n 1 -- "$_f" 2>/dev/null | grep -qx '#!/usr/bin/env python3' || return 1
    grep -Eq '^VERSION = "[0-9]+\.[0-9]+\.[0-9]+"' -- "$_f" || return 1
    grep -qF 'github.com/alariclin/A-Check' -- "$_f" || return 1
    python3 -I -c 'import sys; compile(open(sys.argv[1], "rb").read(), "acheck.py", "exec")' "$_f" 2>/dev/null
}

run_acheck_tool() {
    command -v python3 >/dev/null 2>&1 || { msg "${RED}$(tr_msg acheck_no_python)${NC}"; return 1; }
    local _dir='/etc/ddr/tools' _f='/etc/ddr/tools/acheck.py' _md='' _exp='' _sha=''
    mkdir -p "$_dir" 2>/dev/null
    # Signature gate (mandatory, not a fallback tier): only the pinned
    # test-tools-mirror release is trusted. Every candidate must match the
    # Ed25519-signed SHA256SUMS entry before it is installed or executed;
    # an unsigned main/proxy download is never executed, and a stale cache
    # is never trusted without fresh verification.
    _md=$(abox_mktemp_exec_dir acheck-mirror 2>/dev/null) || { msg "${RED}$(tr_msg acheck_failed)${NC}"; return 1; }
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 45 "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/SHA256SUMS" -o "$_md/SHA256SUMS" \
       || ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 45 "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/SHA256SUMS.sig" -o "$_md/SHA256SUMS.sig" 2>/dev/null \
       || ! abox_verify_sig_gate "$_md/SHA256SUMS" "$_md/SHA256SUMS.sig" "A-Check SHA256SUMS" \
       || ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 "https://github.com/alariclin/A-Box/releases/download/$ABOX_TEST_MIRROR_RELEASE/acheck.py" -o "$_md/acheck.py"; then
        rm -rf -- "$_md"
        msg "${RED}$(tr_msg acheck_failed)${NC}"
        return 1
    fi
    _exp=$(awk -v f='acheck.py' '$2==f || $2==("*" f) {print $1; exit}' "$_md/SHA256SUMS")
    _sha=$(sha256sum "$_md/acheck.py" 2>/dev/null | awk '{print $1}')
    if [[ ! "$_exp" =~ ^[A-Fa-f0-9]{64}$ || "${_sha,,}" != "${_exp,,}" ]] || ! _acheck_file_valid "$_md/acheck.py"; then
        rm -rf -- "$_md"
        msg "${RED}$(tr_msg acheck_failed)${NC}"
        return 1
    fi
    # R8C16-N01: dest must be a plain regular file (or absent). A
    # directory (or symlink) dest would make install/cp drop the verified
    # file inside it while execution later used the dest path.
    if [[ ( -e "$_f" || -L "$_f" ) && ( ! -f "$_f" || -L "$_f" ) ]]; then
        rm -rf -- "$_md"
        msg "${RED}$(tr_msg acheck_failed)${NC}"
        return 1
    fi
    # Both installers failing must NOT fall through to executing the
    # stale $_f (possibly a pre-gate unsigned cache).
    if ! install -m 600 "$_md/acheck.py" "$_f" 2>/dev/null && ! cp "$_md/acheck.py" "$_f" 2>/dev/null; then
        rm -rf -- "$_md"
        msg "${RED}$(tr_msg acheck_failed)${NC}"
        return 1
    fi
    # R11C16-01: run the verified temp file, not the shared cache
    # path, so no install-to-execute window in /etc/ddr/tools exists.
    python3 -I "$_md/acheck.py"
    local _rc=$?
    rm -rf -- "$_md"
    return $_rc
}


vps_benchmark_menu() {
    # Toolbox is a submenu loop: sub-functions return here, 0/Enter goes back
    # to the main menu.
    while true; do
    clear
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
            msg "${BOLD}${GREEN}Toolbox${NC}"
            msg "${CYAN}[ Test & Diagnostics ]                    [ System Tuning ]${NC}"
            msg " ${CYAN}1.${NC}  A-Check IP reputation check           ${CYAN}5.${NC}  WARP & split-routing"
            msg " ${CYAN}2.${NC}  System benchmark & download speed     ${CYAN}6.${NC}  Swap / zram swap"
            msg " ${CYAN}3.${NC}  IP quality / streaming / route test   ${CYAN}7.${NC}  VPS one-click optimization"
            msg " ${CYAN}4.${NC}  Export redacted diagnostics           ${CYAN}8.${NC}  IP / DNS / timezone / download-source"
            msg ""
            msg "${CYAN}[ SNI Optimization ]                      [ Config Management ]${NC}"
            msg " ${CYAN}9.${NC}  Local SNI selection                  ${CYAN}13.${NC}  Backup / restore configuration"
            msg "${CYAN}10.${NC}  Mini-host SNI selection              ${CYAN}14.${NC}  Multi-user / subscription link export"
            msg "${CYAN}11.${NC}  SNI selection records                ${CYAN}15.${NC}  Wallos install / update / backup"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                      ${CYAN}16.${NC}  SS-2022 IP whitelist"
            msg ""
            msg " ${CYAN}0.${NC}  Back                                 ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
        ru)
            msg "${BOLD}${GREEN}Инструменты${NC}"
            msg "${CYAN}[ Тесты и диагностика ]                   [ Оптимизация системы ]${NC}"
            msg " ${CYAN}1.${NC}  A-Check: проверка IP                  ${CYAN}5.${NC}  WARP и разделение трафика"
            msg " ${CYAN}2.${NC}  Тест системы и скорости               ${CYAN}6.${NC}  Swap / zram"
            msg " ${CYAN}3.${NC}  Качество IP / стриминг / маршрут      ${CYAN}7.${NC}  Оптимизация VPS"
            msg " ${CYAN}4.${NC}  Экспорт обезличенной диагностики      ${CYAN}8.${NC}  IP / DNS / часовой пояс / источники"
            msg ""
            msg "${CYAN}[ Подбор SNI ]                            [ Управление конфигурацией ]${NC}"
            msg " ${CYAN}9.${NC}  Подбор SNI                           ${CYAN}13.${NC}  Бэкап / восстановление"
            msg "${CYAN}10.${NC}  Подбор SNI (мини-хост)               ${CYAN}14.${NC}  Пользователи / экспорт подписки"
            msg "${CYAN}11.${NC}  Записи подбора SNI                   ${CYAN}15.${NC}  Wallos: установка / обновление / резервная копия"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                    ${CYAN}16.${NC}  Белый список IP (SS-2022)"
            msg ""
            msg " ${CYAN}0.${NC}  Назад                                ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
        fa)
            msg "${BOLD}${GREEN}جعبه ابزار${NC}"
            msg "${CYAN}[ تست و عیب‌یابی ]                        [ بهینه‌سازی سیستم ]${NC}"
            msg " ${CYAN}1.${NC}  بررسی IP با A-Check                   ${CYAN}5.${NC}  مدیریت WARP و تفکیک ترافیک"
            msg " ${CYAN}2.${NC}  تست سیستم و سرعت دانلود               ${CYAN}6.${NC}  Swap / zram"
            msg " ${CYAN}3.${NC}  کیفیت IP / استریم / مسیر              ${CYAN}7.${NC}  بهینه‌سازی تک‌کلیکی VPS"
            msg " ${CYAN}4.${NC}  خروجی تشخیص عیب‌یابی پالایش‌شده       ${CYAN}8.${NC}  تنظیمات IP / DNS / منطقه زمانی / منبع"
            msg ""
            msg "${CYAN}[ بهینه‌سازی SNI ]                        [ مدیریت پیکربندی ]${NC}"
            msg " ${CYAN}9.${NC}  بهینه‌سازی SNI محلی                  ${CYAN}13.${NC}  پشتیبان‌گیری / بازیابی"
            msg "${CYAN}10.${NC}  بهینه‌سازی SNI مینی‌هاست             ${CYAN}14.${NC}  کاربران / خروجی لینک اشتراک"
            msg "${CYAN}11.${NC}  سوابق بهینه‌سازی SNI                 ${CYAN}15.${NC}  نصب / به‌روزرسانی / پشتیبان‌گیری Wallos"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                        ${CYAN}16.${NC}  لیست سفید آی‌پی SS-2022"
            msg ""
            msg " ${CYAN}0.${NC}  بازگشت                               ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
        zh-tw)
            msg "${BOLD}${GREEN}綜合工具箱${NC}"
            msg "${CYAN}[ 測試診斷 ]                              [ 系統優化 ]${NC}"
            msg " ${CYAN}1.${NC}  A-Check IP 純淨度檢測                 ${CYAN}5.${NC}  WARP 與分流管理"
            msg " ${CYAN}2.${NC}  系統性能與下載測速                    ${CYAN}6.${NC}  Swap / zram 交換"
            msg " ${CYAN}3.${NC}  IP 質量/流媒體解鎖/回程測試           ${CYAN}7.${NC}  VPS 一鍵優化"
            msg " ${CYAN}4.${NC}  導出脫敏診斷包                        ${CYAN}8.${NC}  IP / DNS / 時區 / 下載源設置"
            msg ""
            msg "${CYAN}[ SNI 優選 ]                              [ 配置管理 ]${NC}"
            msg " ${CYAN}9.${NC}  本地 SNI 優選                        ${CYAN}13.${NC}  配置備份 / 恢復"
            msg "${CYAN}10.${NC}  微型主機 SNI 優選                    ${CYAN}14.${NC}  多用戶 / 訂閱連結導出"
            msg "${CYAN}11.${NC}  SNI 優選記錄                         ${CYAN}15.${NC}  Wallos 安裝 / 升級 / 備份"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                         ${CYAN}16.${NC}  SS-2022 訪問白名單"
            msg ""
            msg " ${CYAN}0.${NC}  返回主選單                           ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
        ja)
            msg "${BOLD}${GREEN}ツールボックス${NC}"
            msg "${CYAN}[ テストと診断 ]                          [ システム最適化 ]${NC}"
            msg " ${CYAN}1.${NC}  A-Check IP 品質チェック               ${CYAN}5.${NC}  WARP と振り分け管理"
            msg " ${CYAN}2.${NC}  システムベンチマークと速度測定        ${CYAN}6.${NC}  Swap / zram スワップ"
            msg " ${CYAN}3.${NC}  IP品質/ストリーミング/ルートテスト    ${CYAN}7.${NC}  VPS ワンクリック最適化"
            msg " ${CYAN}4.${NC}  匿名化診断パッケージのエクスポート    ${CYAN}8.${NC}  IP / DNS / タイムゾーン / ダウンロードソース設定"
            msg ""
            msg "${CYAN}[ SNI 最適化 ]                            [ 構成管理 ]${NC}"
            msg " ${CYAN}9.${NC}  ローカル SNI 最適化                  ${CYAN}13.${NC}  設定のバックアップ/復元"
            msg "${CYAN}10.${NC}  ミニホスト SNI 最適化                ${CYAN}14.${NC}  複数ユーザー / サブスクリプション出力"
            msg "${CYAN}11.${NC}  SNI 最適化記録                       ${CYAN}15.${NC}  Wallos インストール/更新/バックアップ"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                  ${CYAN}16.${NC}  SS-2022 IPホワイトリスト"
            msg ""
            msg " ${CYAN}0.${NC}  メインメニューに戻る                 ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
        *)
            msg "${BOLD}${GREEN}综合工具箱${NC}"
            msg "${CYAN}[ 测试诊断 ]                              [ 系统优化 ]${NC}"
            msg " ${CYAN}1.${NC}  A-Check IP 纯净度检测                 ${CYAN}5.${NC}  WARP 与分流管理"
            msg " ${CYAN}2.${NC}  系统性能与下载测速                    ${CYAN}6.${NC}  Swap / zram 交换"
            msg " ${CYAN}3.${NC}  IP 质量/流媒体解锁/回程测试           ${CYAN}7.${NC}  VPS 一键优化"
            msg " ${CYAN}4.${NC}  导出脱敏诊断包                        ${CYAN}8.${NC}  IP / DNS / 时区 / 下载源设置"
            msg ""
            msg "${CYAN}[ SNI 优选 ]                              [ 配置管理 ]${NC}"
            msg " ${CYAN}9.${NC}  本地 SNI 优选                        ${CYAN}13.${NC}  配置备份 / 恢复"
            msg "${CYAN}10.${NC}  微型主机 SNI 优选                    ${CYAN}14.${NC}  多用户 / 订阅链接导出"
            msg "${CYAN}11.${NC}  SNI 优选记录                         ${CYAN}15.${NC}  Wallos 安装 / 升级 / 备份"
        msg "${CYAN}12.${NC}  $(tr_msg tb_nsni)                         ${CYAN}16.${NC}  SS-2022 访问白名单"
            msg ""
            msg " ${CYAN}0.${NC}  返回主菜单                           ${CYAN}17.${NC}  $(tr_msg tb_shortcut)"
            ;;
    esac
    local bench_choice select_prompt
    case "${ABOX_LANG:-zh}" in en) select_prompt='Select [0-17]: ' ;; ru) select_prompt='Выберите [0–17]: ' ;; fa) select_prompt='انتخاب [۰ تا ۱۷]: ' ;; ja) select_prompt='選択してください [0-17]: ' ;; zh-tw) select_prompt='請選擇 [0-17]：' ;; *) select_prompt='请选择 [0-17]：' ;; esac
    read -r -p "$select_prompt" bench_choice || return 0
    bench_choice=$(normalize_fa_ar_digits "${bench_choice:-}")
    case "$bench_choice" in
        1) run_acheck_tool; pause_return ;;
        2) run_mirrored_test_script 'System benchmark and download speed' 'https://bench.sh' 'bench.sh'; pause_return ;;
        3) run_mirrored_test_script 'IP quality, streaming unlock and route test' 'https://Check.Place' 'Check.Place.sh' -I; pause_return ;;
        4) export_diagnostic_bundle ;;
        5) warp_split_menu ;;
        6) swap_menu ;;
        7) tune_vps ;;
        8) host_network_menu ;;
        9) run_local_sni_benchmark ;;
        10) run_local_sni_mini_benchmark ;;
        11) show_sni_preference_records ;;
        12) node_sni_menu ;;
        13) backup_restore_menu ;;
        14) multi_user_menu ;;
        15) wallos_menu ;;
        16) manage_ss_whitelist ;;
        17) shortcut_custom_menu ;;
        # R16-F16-03: honor the header comment ("0/Enter goes back"):
        # an empty input (Enter) returns to the main menu instead of
        # falling into `*)` as "invalid input".
        "") return 0 ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $bench_choice${NC}"; sleep 1 ;;
    esac
    done
}

# Other-protocols entry: let the user freely choose the core for standalone SOCKS5.
# Defaults to the currently deployed core when detectable.
socks5_toolbox_entry() {
    local _core_choice='' _default='1'
    load_optional_abox_env_or_die 2>/dev/null || true
    if [[ "${CORE:-}" == "singbox" ]]; then
        _default='2'
    fi
    read -r -p "$(tr_msg socks5_core_prompt) [${_default}]: " _core_choice || _core_choice=''
    _core_choice="${_core_choice:-$_default}"
    _core_choice=$(normalize_fa_ar_digits "$_core_choice")
    case "$_core_choice" in
        1) deploy_with_instance_choice xray socks5-landing deploy_socks5_landing ;;
        2) deploy_with_instance_choice sing-box socks5-landing deploy_singbox_socks5_landing ;;
        *) msg "${RED}$(tr_msg invalid_input): $_core_choice${NC}"; return 1 ;;
    esac
}
clean_uninstall_menu() {
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${RED}$(tr_msg um_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    msg "${CYAN}1.${NC} $(tr_msg um_item1)"
    msg "${CYAN}2.${NC} $(tr_msg um_item2)"
    msg "${CYAN}0.${NC} $(tr_msg um_back)"
    read -r -p "$(tr_msg um_prompt)" un_choice
    un_choice=$(normalize_fa_ar_digits "${un_choice:-}")
    case "$un_choice" in
        1) auto_backup_prompt bk_op_keep '/root/A-Box-backups'; do_cleanup wipe ;;
        2) auto_backup_prompt bk_op_full '/root/A-Box-backups'; do_cleanup full ;;
        *) return 0 ;;
    esac
}


uri_host() { if [[ "$1" == *:* && "$1" != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }

urlencode() {
    local raw="${1:-}"
    if command -v jq >/dev/null 2>&1; then
        jq -rn --rawfile v <(printf '%s' "$raw") '$v|@uri'
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$raw" | python3 -I -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'
        return $?
    fi
    # Last-resort RFC3986-ish encoder for environments missing jq/python3.
    local i c LC_ALL=C
    for ((i = 0; i < ${#raw}; i++)); do
        c=${raw:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

# OBS-S1-08: verify a registry server_secret against the live SS inbound
# before ss_effective_password() issues it as serverKey:userKey.
# Returns 0 (use the registry key) when the live inbound is clients-form
# with a server key equal to $2, or when the live config cannot be read
# (fail open: previous behaviour). Returns 1 (do not use it) when live
# is positively read as a legacy single-password inbound, or as a
# clients-form inbound with a different server key: an overwrite
# redeploy writes exactly that fresh legacy form while the registry
# still holds the pre-redeploy key, and issuing it would be a dead link.
_ss_live_server_key_matches() {
    local core="$1" want="$2" cfg='' probe=''
    cfg=$(users_cfg_of "$core" 2>/dev/null) || return 0
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 0
    case "$core" in
        xray)
            probe=$(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r --arg t 'ss' '
                [.inbounds[]? | select(.tag == $t)][0]
                | if . == null then "__ABOX_NO_INBOUND__"
                  elif ((.settings.clients // null) | type) == "array" then (.settings.password // "__ABOX_NO_KEY__")
                  else "__ABOX_LEGACY__" end' 2>/dev/null) || return 0
            ;;
        sing-box)
            probe=$(jsonc_strip_comments "$cfg" 2>/dev/null | jq -r --arg t 'ss' '
                [.inbounds[]? | select(.tag == $t)][0]
                | if . == null then "__ABOX_NO_INBOUND__"
                  elif ((.users // []) | length) > 0 then (.password // "__ABOX_NO_KEY__")
                  else "__ABOX_LEGACY__" end' 2>/dev/null) || return 0
            ;;
        *) return 0 ;;
    esac
    case "$probe" in
        ''|__ABOX_NO_INBOUND__|__ABOX_NO_KEY__) return 0 ;;
        __ABOX_LEGACY__) return 1 ;;
        *) [[ "$probe" == "$want" ]] ;;
    esac
}

# Effective SS-2022 client password for the primary (main) node user.
# OBS-S1-07: once multi-user promotion stores a server_secret, the live
# inbound is clients-form and a bare server key can never authenticate --
# the SS-2022 multi-user server requires an EIH, so the client password
# must be "serverKey:userKey" (Xray ParsePSKList splits on ':', sing-box /
# Mihomo / shadowsocks-rust document the same form). Before promotion the
# live password is SS_PASS. $1 (optional) overrides the core
# ('xray' | 'sing-box'); otherwise ${CORE} decides ('singbox' -> sing-box).
# Prints the password; rc 1 when no credential can be determined (callers
# fall back to SS_PASS).
ss_effective_password() {
    local want="${1:-}" core='' reg='' ssecret='' main_secret=''
    case "${want:-${CORE:-}}" in
        sing-box|singbox) core='sing-box' ;;
        *) core='xray' ;;
    esac
    reg=$(users_reg_file "$core" 'ss')
    if [[ -f "$reg" && ! -L "$reg" ]]; then
        ssecret=$(jq -r '.server_secret // ""' "$reg" 2>/dev/null || true)
        if [[ -n "$ssecret" ]] && _ss_live_server_key_matches "$core" "$ssecret"; then
            # The credential must belong to a user the server actually
            # has: primary user (main) first, else first enabled user.
            main_secret=$(jq -r '.users[] | select(.name == "main" and .disabled != true and ((.blocked // "") == "")) | .secret // ""' "$reg" 2>/dev/null | head -1 || true)
            if [[ -z "$main_secret" ]]; then
                main_secret=$(jq -r '.users[] | select(.disabled != true and ((.blocked // "") == "")) | .secret // ""' "$reg" 2>/dev/null | head -1 || true)
            fi
            if [[ -n "$main_secret" ]]; then
                printf '%s' "${ssecret}:${main_secret}"
                return 0
            fi
        fi
    fi
    if [[ -n "${SS_PASS:-}" ]]; then
        printf '%s' "${SS_PASS:-}"
        return 0
    fi
    return 1
}

# Per-user effective SS-2022 client password (H-24(3) follow-up).
# Mirrors ss_effective_password but for the named registry user:
# clients-form (server_secret set) -> "serverKey:userSecret" when
# the live inbound's server key matches the registry key (the
# OBS-S1-08 guard, fail-open when live is unreadable); legacy
# single-password (no server_secret) -> the user's bare secret.
# Prints the password; rc 1 when the user is missing/disabled, has
# no secret, or the live server key positively mismatches the
# registry key (emitting either form would be a dead node, so the
# caller skips that user instead of guessing a credential).
# $1 = user name; $2 = optional core override (as ss_effective_password).
ss_effective_password_for_user() {
    local name="$1" want="${2:-}" core='' reg='' ssecret='' secret=''
    [[ -n "$name" ]] || return 1
    case "${want:-${CORE:-}}" in
        sing-box|singbox) core='sing-box' ;;
        *) core='xray' ;;
    esac
    reg=$(users_reg_file "$core" 'ss')
    [[ -f "$reg" && ! -L "$reg" ]] || return 1
    secret=$(jq -r --arg n "$name" '.users[] | select(.name == $n and .disabled != true and ((.blocked // "") == "")) | .secret // ""' "$reg" 2>/dev/null | head -1 || true)
    [[ -n "$secret" ]] || return 1
    ssecret=$(jq -r '.server_secret // ""' "$reg" 2>/dev/null || true)
    if [[ -n "$ssecret" ]]; then
        _ss_live_server_key_matches "$core" "$ssecret" || return 1
        printf '%s' "${ssecret}:${secret}"
        return 0
    fi
    printf '%s' "$secret"
    return 0
}

# H-24 (Carbon R3): the effective Hy2 credential for display/export.
# userpass needs "login:secret" (the server authenticates by
# .login // .name, R10-10), whatever the user count; only password
# mode needs the bare secret. Mirrors
# ss_effective_password's fail-open: when the live config cannot be
# read (or yields no usable credential), fall back to $HY2_PASS;
# return 1 only when neither yields a credential. On success prints
# the credential followed by __ABOX_TRAILING_NL_KEEP__ (no trailing
# newline): callers strip the suffix, which keeps a trailing-newline
# secret intact through $(...) (same sentinel convention as
# users_hy2_yaml_scalar / rebuild_standalone_links).
hy2_effective_password() {
    # ABOX_HY2_CONFIG is the config-path override (fixture hook, same
    # convention as hy2_effective_password_for_user).
    local cfg="${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}" users='' pw_only='' login='' secret='' _pick='' _read_rc=0 _live_readable=0
    # L6: "no usable credential" must not fall back to .env HY2_PASS.
    # users_hy2_read_users prints [] with rc 0 for a live deny password
    # (ABOX-DENY-*), and rc 1 for an unreadable file -- but also rc 1
    # for a READABLE file with no usable credential (empty userpass,
    # missing password). Only a missing/symlinked live config keeps
    # the old fail-open to $HY2_PASS; a present, regular live config
    # that yields no usable credential is authoritative: return 1 so
    # no caller can publish the stale .env password as a live node.
    [[ -f "$cfg" && ! -L "$cfg" ]] && _live_readable=1
    users=$(users_hy2_read_users "$cfg" 2>/dev/null) || _read_rc=$?
    if (( _live_readable == 1 )) && { (( _read_rc != 0 )) || [[ "$users" == '[]' ]]; }; then
        return 1
    fi
    if [[ -n "$users" && "$users" != '[]' ]]; then
        # M41-NEW-01 follow-up: the single-node/combo display must
        # show main's credential, not the first registered user's.
        # The live user list is in registration order (e62hy1 can
        # precede main), so .[0] printed another user's composite
        # link and main's composite link never appeared anywhere in
        # menu 12. Prefer the user named "main"; fall back to .[0]
        # when no main exists (single-user deploys, renamed main).
        # The picked entry carries the password_only flag too
        # (password mode has a single entry).
        _pick=$(printf '%s' "$users" | jq -c '(first(.[] | select((.login // .name // "") == "main")) // .[0])' 2>/dev/null || true)
        [[ -n "$_pick" && "$_pick" != 'null' ]] || _pick=$(printf '%s' "$users" | jq -c '.[0]' 2>/dev/null || true)
        pw_only=$(printf '%s' "$_pick" | jq -r '.password_only // false' 2>/dev/null || echo false)
        if [[ "$pw_only" == 'true' ]]; then
            secret=$(printf '%s' "$_pick" | jq -r '((.secret // "") + "__ABOX_TRAILING_NL_KEEP__")' 2>/dev/null || true)
            secret=${secret%__ABOX_TRAILING_NL_KEEP__}
            if [[ -n "$secret" ]]; then
                printf '%s__ABOX_TRAILING_NL_KEEP__' "$secret"
                return 0
            fi
        else
            # D-5: userpass auth (any user count) authenticates by
            # login/name, so even a single userpass user needs
            # "login:secret"; only password-only auth takes the
            # bare secret (handled above).
            login=$(printf '%s' "$_pick" | jq -r '((.login // .name // "main") + "__ABOX_TRAILING_NL_KEEP__")' 2>/dev/null || true)
            login=${login%__ABOX_TRAILING_NL_KEEP__}
            secret=$(printf '%s' "$_pick" | jq -r '((.secret // "") + "__ABOX_TRAILING_NL_KEEP__")' 2>/dev/null || true)
            secret=${secret%__ABOX_TRAILING_NL_KEEP__}
            if [[ -n "$login" && -n "$secret" ]]; then
                printf '%s__ABOX_TRAILING_NL_KEEP__' "${login}:${secret}"
                return 0
            fi
        fi
    fi
    if [[ -n "${HY2_PASS:-}" ]]; then
        printf '%s__ABOX_TRAILING_NL_KEEP__' "${HY2_PASS:-}"
        return 0
    fi
    return 1
}
# Per-user effective Hy2 password (H-24(1) follow-up): the server
# authenticates ONE credential per connection. In userpass mode that
# credential is "login:secret" OF THE TARGET USER (not main's, which
# the no-arg hy2_effective_password returns); in
# password-only mode it is the bare server password for every user.
# Prints the effective password with the trailing-newline sentinel,
# like hy2_effective_password. $1 = login (registry .login // .name);
# $2 = optional config path (default /etc/hysteria/config.yaml, for
# fixtures). Returns 1 when the live config has no such user (a link
# built from the registry alone would 404) or is unreadable.
hy2_effective_password_for_user() {
    local login="$1" cfg="${2:-${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}}" users='' pw_only='' entry='' secret=''
    [[ -n "$login" ]] || return 1
    users=$(users_hy2_read_users "$cfg" 2>/dev/null) || return 1
    [[ -n "$users" && "$users" != '[]' ]] || return 1
    pw_only=$(printf '%s' "$users" | jq -r '.[0].password_only // false' 2>/dev/null || echo false)
    if [[ "$pw_only" == 'true' ]]; then
        secret=$(printf '%s' "$users" | jq -r '((.[0].secret // "") + "__ABOX_TRAILING_NL_KEEP__")' 2>/dev/null || true)
        secret=${secret%__ABOX_TRAILING_NL_KEEP__}
        [[ -n "$secret" ]] || return 1
        printf '%s__ABOX_TRAILING_NL_KEEP__' "$secret"
        return 0
    fi
    entry=$(printf '%s' "$users" | jq -c --arg n "$login" '.[] | select(.name == $n)' 2>/dev/null) || return 1
    [[ -n "$entry" && "$entry" != 'null' ]] || return 1
    secret=$(printf '%s' "$entry" | jq -r '((.secret // "") + "__ABOX_TRAILING_NL_KEEP__")' 2>/dev/null || true)
    secret=${secret%__ABOX_TRAILING_NL_KEEP__}
    [[ -n "$secret" ]] || return 1
    printf '%s__ABOX_TRAILING_NL_KEEP__' "${login}:${secret}"
    return 0
}

build_ss2022_uri() {
    local host="$1" port="$2" pass="$3"
    # SIP002/SIP022: AEAD-2022 userinfo must not be Base64URL encoded;
    # method and password are percent-encoded as RFC3986 userinfo.
    printf 'ss://%s:%s@%s:%s#SS\n' \
        "$(urlencode '2022-blake3-aes-128-gcm')" \
        "$(urlencode "$pass")" \
        "$host" "$port"
}

singbox_hy2_tls_json() {
    if [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]]; then
        cat <<EOF_TLS
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}"
      }
EOF_TLS
    else
        # N-18 fix: validate the base64 SHA-256 fingerprint before embedding.
        # Must be 44-char base64 (32 bytes) to prevent JSON injection via .env.
        if [[ -z "${HY2_CERT_PUBKEY_SHA256_B64:-}" || ! "${HY2_CERT_PUBKEY_SHA256_B64}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            msg "${RED}[!] $(tr_msg singbox_hy2_tls_json_pubkey_invalid)${NC}" >&2
            return 1
        fi
        cat <<EOF_TLS
      "tls": {
        "enabled": true,
        "insecure": true,
        "certificate_public_key_sha256": ["${HY2_CERT_PUBKEY_SHA256_B64:-}"]
      }
EOF_TLS
    fi
}

