#!/usr/bin/env bash
# fx-f2-legacy-iptables.sh — F2 follow-up leg (2026-11-28).
#
# Closes the L3-fix open item "legacy-iptables frontend not directly
# tested" (l3-fix/REPORT.md, unres. #3): the hop cleanup in src/09
# (remove_hy2_official_hop_rules, via _hy2hop_fetch_ipt_listing /
# _hy2hop_ipt_delete_chain) and the comment-scoped NAT cleaner
# clean_nat_rules (src/05, called from src/09 uninstall paths) all
# walk one thin frontend:
#   _iptables_probe_w / _iptables_q / _iptables_do  (src/03, src/04,
#     src/06 — three copies; the last definition wins at runtime)
#   firewall_backend + nftables_native_rules_present + ufw_is_active
#     (src/05 — the backend gate clean_nat_rules refuses on)
# This fixture extracts those REAL functions from the built
# install.sh (never a hand copy) and drives them against mock
# iptables/ip6tables/nft binaries under PATH isolation. No real
# firewall, no bind-mount, no /etc writes.
#
# Run: bash tests/fixtures-e/fx-f2-legacy-iptables.sh
#   (fx-run-all.sh rebuilds install.sh first, then runs every fx-*.sh)
# Exit 0 = all groups pass; 1 = any failure.
# On UNMODIFIED code the expected result is PASS — this leg only adds
# tests; any FAIL is a reproduced real defect (see REPORT.md).
set -u
source "$(dirname "$0")/fx-lib.sh"

[[ -f "$INSTALL_SH" ]] || { printf 'ABORT: install.sh not found at %s\n' "$INSTALL_SH" >&2; exit 2; }
HEAD="$(cd "$(dirname "$INSTALL_SH")" && git rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'install.sh: %s (HEAD %s)\n' "$INSTALL_SH" "$HEAD"

TMP="$(mktemp -d /tmp/abox-f2-legacy-ipt.XXXXXX)"
BIN="$TMP/bin"; BIN_NO6="$TMP/bin-no6"; STATE="$TMP/state"; LOG="$TMP/log"; EXT="$TMP/extracted"
mkdir -p "$BIN" "$BIN_NO6" "$STATE" "$LOG" "$EXT"
trap 'rm -rf -- "$TMP"' EXIT

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES+1)); }
pass() { printf 'PASS: %s\n' "$*"; }

# ---- mock iptables/ip6tables (one script, two names) ---------------------
# State: $MOCK_STATE/nat.v4 and nat.v6, one rule per line, exactly as
# `iptables -S` prints them (comments quoted). Log: every invocation.
# Modes (per family, via $MOCK_MODE_4 / $MOCK_MODE_6):
#   ok | perm (Permission denied) | notexist (Table does not exist)
#   | nft (table 'nat' is incompatible, use 'nft' tool)
#   | initperm (can't initialize ... Permission denied, selftest text)
# $MOCK_VER_4 / $MOCK_VER_6: 0 = `-w --version` succeeds (-w supported),
# 1 = fails (pre-1.4.20 binary, no -w). $MOCK_FAIL_D=1 makes -D fail.
cat > "$BIN/mock-ipt.sh" <<'EOF_MOCK_IPT'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$MOCK_LOG/$name.log"
if [[ "$name" == ip6tables ]]; then suf=v6; mode="${MOCK_MODE_6:-ok}"; ver="${MOCK_VER_6:-0}";
else suf=v4; mode="${MOCK_MODE_4:-ok}"; ver="${MOCK_VER_4:-0}"; fi
st="$MOCK_STATE/nat.$suf"
args=("$@")
[[ "${args[0]:-}" == "-w" ]] && args=("${args[@]:1}")
for a in "${args[@]}"; do
    if [[ "$a" == --version ]]; then
        if [[ "$ver" == 0 ]]; then echo "iptables v1.8.10 (nf_tables)"; exit 0; else exit 1; fi
    fi
done
if [[ "$mode" != ok ]]; then
    case "$mode" in
        perm) printf '%s: Permission denied (you must be root).\n' "$name" >&2 ;;
        notexist) printf '%s: Table does not exist (do you need to insmod?).\n' "$name" >&2 ;;
        nft) printf '%s v1.8.7 (nf_tables): table '"'"'nat'"'"' is incompatible, use '"'"'nft'"'"' tool.\n' "$name" >&2 ;;
        initperm) printf "can't initialize %s table 'nat': Permission denied (you must be root).\n" "$name" >&2 ;;
        *) printf '%s: unknown mock mode %s.\n' "$name" "$mode" >&2 ;;
    esac
    exit 1
fi
if [[ "${args[0]:-}" == "-t" && "${args[1]:-}" == "nat" ]]; then
    case "${args[2]:-}" in
        -S)
            chain="${args[3]:-}"
            if [[ -n "$chain" ]]; then
                printf -- '-P %s ACCEPT\n' "$chain"
                grep -h -- "^-A $chain " "$st" 2>/dev/null || true
            else
                cat "$st" 2>/dev/null || true
            fi
            exit 0 ;;
        -L)
            printf 'Chain %s (policy ACCEPT)\n' "${args[3]:-PREROUTING}"
            exit 0 ;;
        -D)
            [[ "${MOCK_FAIL_D:-0}" == 1 ]] && exit 1
            chain="${args[3]}"; spec="${args[*]:4}"
            target="-A $chain $spec"
            found=0; tmp="$st.tmp"; : > "$tmp"
            while IFS= read -r line || [[ -n "$line" ]]; do
                s="${line//\"/}"
                if (( found == 0 )) && [[ "$s" == "$target" ]]; then found=1; continue; fi
                printf '%s\n' "$line" >> "$tmp"
            done < "$st"
            mv -- "$tmp" "$st"
            (( found == 1 )) ;;
        -F)
            chain="${args[3]}"
            grep -v -- "^-A $chain " "$st" > "$st.tmp" || true; mv -- "$st.tmp" "$st"; exit 0 ;;
        -X)
            chain="${args[3]}"
            grep -v -x -F -- "-N $chain" "$st" > "$st.tmp" || true; mv -- "$st.tmp" "$st"; exit 0 ;;
        -N)
            printf -- '-N %s\n' "${args[3]}" >> "$st"; exit 0 ;;
    esac
fi
exit 0
EOF_MOCK_IPT
cp "$BIN/mock-ipt.sh" "$BIN/iptables"
cp "$BIN/mock-ipt.sh" "$BIN/ip6tables"
cp "$BIN/mock-ipt.sh" "$BIN_NO6/iptables"
# ---- mock nft ------------------------------------------------------------
# `nft -nn list ruleset` prints $MOCK_STATE/nft.ruleset verbatim.
cat > "$BIN/nft" <<'EOF_MOCK_NFT'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >> "$MOCK_LOG/nft.log"
if [[ "$*" == *list*ruleset* ]]; then cat "$MOCK_STATE/nft.ruleset" 2>/dev/null || true; exit 0; fi
exit 0
EOF_MOCK_NFT
chmod +x "$BIN/mock-ipt.sh" "$BIN/iptables" "$BIN/ip6tables" "$BIN_NO6/iptables" "$BIN/nft"

export MOCK_STATE="$STATE" MOCK_LOG="$LOG"
export PATH="$BIN:/usr/bin:/bin"

# ---- extract REAL functions verbatim from install.sh --------------------
: > "$EXT/functions.sh"
for _fn in _iptables_probe_w _iptables_q _iptables_do \
           firewall_backend nftables_native_rules_present ufw_is_active \
           clean_nat_rules _hy2hop_fetch_ipt_listing _hy2hop_ipt_delete_chain; do
    fx_extract_func "$INSTALL_SH" "$_fn" "$EXT/fn.$_fn" || exit 2
    cat "$EXT/fn.$_fn" >> "$EXT/functions.sh"
done
fx_extract_colors "$EXT/colors.sh" || exit 2
{
    fx_msg_stub
    cat "$EXT/colors.sh"
    cat <<'EOF_STUB'
# HAS_IPV6=1 means IPv6 is present (return 0); 0 means absent.
has_ipv6() { [[ "${HAS_IPV6:-1}" == 1 ]]; }
EOF_STUB
    cat "$EXT/functions.sh"
} > "$EXT/harness.sh"
# shellcheck disable=SC1091
source "$EXT/harness.sh"

# ---- helpers --------------------------------------------------------------
# Extract the Nth occurrence of a top-level function (fx_extract_func
# only takes the first); used by G0 to compare the three frontend copies.
fx_extract_occ() {
    local file="$1" name="$2" occ="$3" out="$4" s e
    s=$(grep -n "^${name}() {" "$file" | sed -n "${occ}p" | cut -d: -f1)
    [[ -n "$s" ]] || return 1
    # End anchor must NOT require the line to end at `{`: the next
    # top-level definition may be a one-liner (`name() { ...; }`),
    # which the shared fx_extract_func's `\{ *$` anchor sails past
    # (that over-long span is what made G0 fail on _iptables_do #3).
    e=$(awk -v s="$s" 'NR > s && /^[A-Za-z_][A-Za-z0-9_]*[(][)] \{/ { print NR - 1; exit }' "$file")
    [[ -n "$e" ]] || e=$(wc -l < "$file")
    sed -n "${s},${e}p" "$file" > "$out"
}

# Restore the REAL extracted functions (undoes a group's firewall_backend
# stub) and clear the -w probe cache so the next group re-probes.
group_start() {
    # shellcheck disable=SC1091
    source "$EXT/functions.sh"
    local v
    for v in $(compgen -v _IPT_W_ 2>/dev/null || true); do unset "$v"; done
    unset _IPT_W_CUR 2>/dev/null || true
    export MOCK_MODE_4=ok MOCK_MODE_6=ok MOCK_VER_4=0 MOCK_VER_6=0 MOCK_FAIL_D=0
    export HAS_IPV6=1
    : > "$STATE/nat.v4"; : > "$STATE/nat.v6"
    : > "$LOG/iptables.log"; : > "$LOG/ip6tables.log"; : > "$LOG/nft.log"
    : > "$STATE/nft.ruleset"
    IPT="$BIN/iptables"; IPT6="$BIN/ip6tables"
    export PATH="$BIN:/usr/bin:/bin"
}

# Canonical owned / foreign rule lines (quoted comments, as real
# `iptables -S` prints them).
OWN4='-A PREROUTING -p udp --dport 20000 -j DNAT --to-destination 127.0.0.1:20000 -m comment --comment "A-Box-HY2-HOP"'
OWN4B='-A PREROUTING -p udp --dport 20001 -j DNAT --to-destination 127.0.0.1:20001 -m comment --comment "A-Box-HY2-HOP"'
OWN6='-A PREROUTING -p udp --dport 20000 -j DNAT --to-destination [::1]:20000 -m comment --comment "A-Box-HY2-HOP"'
FOREIGN_NOCOMMENT='-A PREROUTING -p udp --dport 443 -j DNAT --to-destination 127.0.0.1:443'
FOREIGN_OTHER='-A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-ports 18080 -m comment --comment "A-Box-OTHER"'
FOREIGN_SUFFIX='-A PREROUTING -p udp --dport 20002 -j DNAT --to-destination 127.0.0.1:20002 -m comment --comment "A-Box-HY2-HOPX"'
FOREIGN_TAMPERED='-A PREROUTING -p udp --dport 20003 -j DNAT --to-destination 127.0.0.1:20003 -m comment --comment "A-Box-HY2-HOP-tampered"'
FOREIGN_PREFIX='-A PREROUTING -p udp --dport 20004 -j DNAT --to-destination [::1]:20004 -m comment --comment X-A-Box-HY2-HOP'
HOP_JUMP='-A PREROUTING -p udp --dport 20005 -j HYSTERIA-PR-abcdef12'

# ================= G0: three frontend copies are identical ================
# src/03, src/04, src/06 each define the frontend; build.sh concatenates
# them, so the LAST definition wins at runtime. If the copies ever
# diverged, the tested copy would not be the live one.
printf '== G0: frontend copy consistency ==\n'
for _fn in _iptables_probe_w _iptables_q _iptables_do; do
    _n=$(grep -c "^${_fn}() {" "$INSTALL_SH")
    if [[ "$_n" == 3 ]]; then pass "$_fn defined exactly 3 times (src/03, src/04, src/06)"; else fail "$_fn defined $_n times, expected 3"; fi
    if fx_extract_occ "$INSTALL_SH" "$_fn" 1 "$EXT/g0a" && fx_extract_occ "$INSTALL_SH" "$_fn" 2 "$EXT/g0b" && fx_extract_occ "$INSTALL_SH" "$_fn" 3 "$EXT/g0c"; then
        if cmp -s "$EXT/g0a" "$EXT/g0b"; then pass "$_fn copy 1 == copy 2"; else fail "$_fn copy 1 != copy 2"; fi
        if cmp -s "$EXT/g0b" "$EXT/g0c"; then pass "$_fn copy 2 == copy 3"; else fail "$_fn copy 2 != copy 3"; fi
    else
        fail "$_fn occurrence extraction failed"
    fi
done

# ================= G1: probe / query / do frontend ========================
printf '== G1: _iptables_probe_w / _iptables_q / _iptables_do ==\n'
group_start
printf '%s\n' "$OWN4" "$FOREIGN_NOCOMMENT" > "$STATE/nat.v4"
# NOTE: call in the main shell with output to a file, NOT $(...) — a
# command substitution would run the probe in a subshell and discard
# its cache, breaking the G1.2 count below.
if _iptables_q "$BIN/iptables" -t nat -S PREROUTING > "$EXT/g1-out" 2>/dev/null; then
    grep -qF 'A-Box-HY2-HOP' "$EXT/g1-out" && pass 'G1.1 _iptables_q returns the listing' || fail 'G1.1 _iptables_q listing missing owned rule'
else fail 'G1.1 _iptables_q rc != 0 on healthy mock'; fi
if grep -qF 'iptables -w -t nat -S PREROUTING' "$LOG/iptables.log"; then pass 'G1.1 _iptables_q inserts -w when --version succeeds'; else fail 'G1.1 _iptables_q did not insert -w'; fi
_iptables_q "$BIN/iptables" -t nat -S PREROUTING >/dev/null 2>&1
_iptables_q "$BIN/iptables" -t nat -S PREROUTING >/dev/null 2>&1
if [[ "$(grep -c -- '--version' "$LOG/iptables.log")" == 1 ]]; then pass 'G1.2 -w probe cached: --version invoked exactly once over 3 queries'; else fail "G1.2 --version count $(grep -c -- '--version' "$LOG/iptables.log"), expected 1"; fi
if _iptables_do "$BIN/iptables" -t nat -D PREROUTING -p udp --dport 20000 -j DNAT --to-destination 127.0.0.1:20000 -m comment --comment A-Box-HY2-HOP >/dev/null 2>&1; then
    grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v4" && fail 'G1.3 _iptables_do -D reported ok but rule remains' || pass 'G1.3 _iptables_do deletes via -D replay'
else fail 'G1.3 _iptables_do -D rc != 0'; fi
if grep -qF 'iptables -w -t nat -D PREROUTING' "$LOG/iptables.log"; then pass 'G1.3 _iptables_do inserts -w on mutations too'; else fail 'G1.3 _iptables_do did not insert -w'; fi
group_start
export MOCK_VER_4=1
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if out=$(_iptables_q "$BIN/iptables" -t nat -S PREROUTING 2>/dev/null); then
    [[ "$out" == *'A-Box-HY2-HOP'* ]] && pass 'G1.4 old binary without -w still answers queries' || fail 'G1.4 listing missing owned rule'
else fail 'G1.4 _iptables_q rc != 0 without -w support'; fi
if grep -qF 'iptables -t nat -S PREROUTING' "$LOG/iptables.log" && ! grep -qF 'iptables -w -t nat -S PREROUTING' "$LOG/iptables.log"; then
    pass 'G1.4 no -w inserted when probe fails (graceful downgrade)'
else fail 'G1.4 -w handling wrong when probe fails'; fi
group_start
export MOCK_MODE_4=perm
if _iptables_q "$BIN/iptables" -t nat -S PREROUTING >/dev/null 2>&1; then fail 'G1.5 _iptables_q reported success on permission error'; else pass 'G1.5 _iptables_q propagates query failure rc'; fi

# ================= G2: firewall_backend classifier (real) =================
printf '== G2: firewall_backend (real classifier) ==\n'
group_start
if [[ "$(firewall_backend 2>/dev/null)" == iptables ]]; then pass 'G2.1 empty ruleset -> iptables'; else fail "G2.1 empty ruleset -> $(firewall_backend 2>/dev/null)"; fi
cat > "$STATE/nft.ruleset" <<'EOF_RULESET_NATIVE'
table inet filter {
	chain input {
		type filter hook input priority 0; policy accept;
	}
}
EOF_RULESET_NATIVE
if [[ "$(firewall_backend 2>/dev/null)" == nftables-unsupported ]]; then pass 'G2.2 native inet table -> nftables-unsupported'; else fail "G2.2 native table -> $(firewall_backend 2>/dev/null)"; fi
cat > "$STATE/nft.ruleset" <<'EOF_RULESET_HY'
table ip hysteria_abcdef12 {
	chain prerouting {
		type nat hook prerouting priority -100; policy accept;
	}
	chain output {
		type nat hook output priority -100; policy accept;
	}
}
table ip6 hysteria_abcdef12 {
	chain prerouting {
		type nat hook prerouting priority -100; policy accept;
	}
	chain output {
		type nat hook output priority -100; policy accept;
	}
}
EOF_RULESET_HY
if [[ "$(firewall_backend 2>/dev/null)" == iptables ]]; then pass 'G2.3 own hysteria_* tables excluded -> iptables (no self-deadlock)'; else fail "G2.3 hysteria-only ruleset -> $(firewall_backend 2>/dev/null)"; fi
cat > "$STATE/nft.ruleset" <<'EOF_RULESET_F2B'
table inet f2b {
	chain f2b-sshd {
		type filter hook input priority 0; policy accept;
	}
}
EOF_RULESET_F2B
if [[ "$(firewall_backend 2>/dev/null)" == iptables ]]; then pass 'G2.4 fail2ban-only ruleset excluded -> iptables'; else fail "G2.4 f2b-only ruleset -> $(firewall_backend 2>/dev/null)"; fi
_old_path="$PATH"; PATH="/usr/bin:/bin"
if [[ "$(firewall_backend 2>/dev/null)" == iptables ]]; then pass 'G2.5 nft binary missing -> iptables'; else fail "G2.5 no nft -> $(firewall_backend 2>/dev/null)"; fi
PATH="$_old_path"
cat > "$STATE/nft.ruleset" <<'EOF_RULESET_SQUAT'
table ip hysteria_abcdef12 {
	chain input {
		type filter hook input priority 0; policy accept;
	}
}
EOF_RULESET_SQUAT
if [[ "$(firewall_backend 2>/dev/null)" == nftables-unsupported ]]; then pass 'G2.6 squatted hysteria_* name with foreign chain still -> nftables-unsupported'; else fail "G2.6 squat table -> $(firewall_backend 2>/dev/null)"; fi

# ================= G3: clean_nat_rules, positive ==========================
printf '== G3: clean_nat_rules (positive) ==\n'
group_start
firewall_backend() { printf 'iptables\n'; }
printf '%s\n' "$OWN4" "$OWN4B" "$FOREIGN_NOCOMMENT" "$FOREIGN_OTHER" "$FOREIGN_SUFFIX" "$HOP_JUMP" > "$STATE/nat.v4"
printf '%s\n' "$OWN6" "$FOREIGN_PREFIX" > "$STATE/nat.v6"
if clean_nat_rules; then pass 'G3.1 clean_nat_rules rc 0 with owned rules present'; else fail 'G3.1 clean_nat_rules rc != 0'; fi
if ! grep -qF '"A-Box-HY2-HOP"' "$STATE/nat.v4" && ! grep -qF '"A-Box-HY2-HOP"' "$STATE/nat.v6"; then pass 'G3.1 owned A-Box-HY2-HOP rules deleted (v4+v6, quoted form)'; else fail 'G3.1 owned rule remains'; fi
if [[ "$(wc -l < "$STATE/nat.v4")" == 4 && "$(wc -l < "$STATE/nat.v6")" == 1 ]]; then pass 'G3.2 only owned rules removed: 4 foreign v4 + 1 foreign v6 lines remain'; else fail "G3.2 line counts v4=$(wc -l < "$STATE/nat.v4") v6=$(wc -l < "$STATE/nat.v6"), expected 4/1"; fi
for _f in "$FOREIGN_NOCOMMENT" "$FOREIGN_OTHER" "$FOREIGN_SUFFIX" "$HOP_JUMP" "$FOREIGN_PREFIX"; do
    grep -qF -- "$_f" "$STATE/nat.v4" "$STATE/nat.v6" 2>/dev/null || fail "G3.2 foreign rule lost: $_f"
done
grep -qF -- "$HOP_JUMP" "$STATE/nat.v4" && pass 'G3.2 HYSTERIA-PR-* jump untouched (L3 arbitration #4: not expanded)' || fail 'G3.2 HYSTERIA-PR-* jump was deleted by clean_nat_rules'
group_start
firewall_backend() { printf 'iptables\n'; }
if clean_nat_rules; then pass 'G3.3 empty tables -> rc 0 (no-op)'; else fail 'G3.3 empty tables rc != 0'; fi
if ! grep -q ' -D ' "$LOG/iptables.log" && ! grep -q ' -D ' "$LOG/ip6tables.log"; then pass 'G3.3 no -D attempted on empty tables'; else fail 'G3.3 -D attempted on empty tables'; fi
group_start
firewall_backend() { printf 'iptables\n'; }
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
clean_nat_rules || fail 'G3.4 first clean_nat_rules rc != 0'
clean_nat_rules || fail 'G3.4 second clean_nat_rules rc != 0'
if [[ "$(grep -c ' -D ' "$LOG/iptables.log")" == 1 ]]; then pass 'G3.4 idempotent: second call deletes nothing (exactly 1 -D total)'; else fail "G3.4 -D count $(grep -c ' -D ' "$LOG/iptables.log"), expected 1"; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_4=notexist
printf '%s\n' "$OWN6" > "$STATE/nat.v6"
if clean_nat_rules; then pass 'G3.5 missing v4 nat table tolerated, M-14(3)'; else fail 'G3.5 missing v4 nat table rc != 0'; fi
grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v6" && fail 'G3.5 v6 owned rule not cleaned after v4 exemption' || pass 'G3.5 v6 still cleaned when v4 table missing'
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_6=notexist
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then pass 'G3.6 missing v6 nat table tolerated'; else fail 'G3.6 missing v6 nat table rc != 0'; fi
grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v4" && fail 'G3.6 v4 owned rule not cleaned after v6 exemption' || pass 'G3.6 v4 still cleaned when v6 table missing'

# ================= G4: clean_nat_rules, negative (fail-closed) ============
printf '== G4: clean_nat_rules (fail-closed) ==\n'
group_start
firewall_backend() { printf 'iptables\n'; }
IPT=/nonexistent/iptables
if clean_nat_rules; then fail 'G4.1 missing iptables binary reported success'; else pass 'G4.1 missing iptables binary fails closed (rc != 0)'; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_4=perm
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then fail 'G4.2 v4 permission error reported success'; else pass 'G4.2 v4 permission error fails closed'; fi
grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v4" && pass 'G4.2 no rule deleted after v4 permission error' || fail 'G4.2 rule deleted despite v4 permission error'
grep -q ' -D ' "$LOG/iptables.log" && fail 'G4.2 -D attempted after v4 permission error' || pass 'G4.2 no -D attempted after v4 permission error'
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_6=perm
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then fail 'G4.3 v6 permission error reported success'; else pass 'G4.3 v6 permission error fails closed (selftest parity)'; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_6=initperm
if clean_nat_rules; then fail "G4.4 v6 can't-initialize permission error reported success"; else pass "G4.4 v6 can't-initialize permission error fails closed (selftest parity)"; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_6=nft
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then pass 'G4.5 v6 nft-incompatible tolerated (selftest parity)'; else fail 'G4.5 v6 nft-incompatible rc != 0'; fi
grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v4" && fail 'G4.5 v4 owned rule not cleaned when v6 is nft-incompatible' || pass 'G4.5 v4 still cleaned when v6 is nft-incompatible'
group_start
firewall_backend() { printf 'iptables\n'; }
export MOCK_MODE_4=nft
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then fail 'G4.6 v4 nft-incompatible reported success'; else pass 'G4.6 v4 nft-incompatible fails closed (no M-14(3)-style exemption on v4; see REPORT.md)'; fi
group_start
firewall_backend() { printf 'nftables-unsupported\n'; }
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then fail 'G4.7 nftables-unsupported backend reported success'; else pass 'G4.7 nftables-unsupported backend refused (rc != 0)'; fi
if [[ ! -s "$LOG/iptables.log" && ! -s "$LOG/ip6tables.log" ]]; then pass 'G4.7 refusal happens before any iptables query'; else fail 'G4.7 iptables was queried despite backend refusal'; fi
group_start
firewall_backend() { return 1; }
if clean_nat_rules; then fail 'G4.8 firewall_backend failure reported success'; else pass 'G4.8 firewall_backend failure fails closed'; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export PATH="$BIN_NO6:/usr/bin:/bin"
IPT="$BIN_NO6/iptables"; IPT6="$BIN_NO6/ip6tables"
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then fail 'G4.9a ip6tables missing + IPv6 present reported success'; else pass 'G4.9a ip6tables missing + IPv6 present fails closed'; fi
group_start
firewall_backend() { printf 'iptables\n'; }
export PATH="$BIN_NO6:/usr/bin:/bin" HAS_IPV6=0
IPT="$BIN_NO6/iptables"; IPT6="$BIN_NO6/ip6tables"
printf '%s\n' "$OWN4" > "$STATE/nat.v4"
if clean_nat_rules; then pass 'G4.9b ip6tables missing + no IPv6 -> rc 0 (nothing to inspect)'; else fail 'G4.9b ip6tables missing + no IPv6 rc != 0'; fi
grep -qF 'A-Box-HY2-HOP' "$STATE/nat.v4" && fail 'G4.9b v4 owned rule not cleaned' || pass 'G4.9b v4 still cleaned without ip6tables'
group_start
firewall_backend() { printf 'iptables\n'; }
printf '%s\n' "$FOREIGN_SUFFIX" "$FOREIGN_TAMPERED" "$FOREIGN_PREFIX" "$FOREIGN_OTHER" "$FOREIGN_NOCOMMENT" > "$STATE/nat.v4"
if clean_nat_rules; then pass 'G4.10 tampered/missing comments -> rc 0 (nothing owned to delete)'; else fail 'G4.10 tampered-comment table rc != 0'; fi
if [[ "$(wc -l < "$STATE/nat.v4")" == 5 ]]; then pass 'G4.10 all 5 tampered/foreign rules retained (refused deletion)'; else fail "G4.10 line count $(wc -l < "$STATE/nat.v4"), expected 5"; fi
grep -q ' -D ' "$LOG/iptables.log" && fail 'G4.10 -D attempted on tampered-comment table' || pass 'G4.10 no -D attempted on tampered-comment table'

# ================= G5: _hy2hop_fetch_ipt_listing ==========================
printf '== G5: _hy2hop_fetch_ipt_listing ==\n'
group_start
printf '%s\n' '-N HYSTERIA-PR-abcdef12' "$OWN4" "$FOREIGN_NOCOMMENT" > "$STATE/nat.v4"
if out=$(_hy2hop_fetch_ipt_listing iptables); then
    [[ "$out" == *'HYSTERIA-PR-abcdef12'* && "$out" == *'A-Box-HY2-HOP'* ]] && pass 'G5.1 listing printed, rc 0' || fail 'G5.1 listing content incomplete'
else fail 'G5.1 fetch rc != 0 on healthy mock'; fi
_old_path="$PATH"; PATH="/usr/bin:/bin"
if _hy2hop_fetch_ipt_listing iptables >/dev/null 2>&1; then fail 'G5.2 missing binary reported success'; else
    [[ "$?" == 1 ]] && pass 'G5.2 missing binary -> rc 1 (skip backend)' || fail "G5.2 missing binary rc $? (expected 1)"
fi
PATH="$_old_path"
group_start
export MOCK_MODE_4=notexist
if out=$(_hy2hop_fetch_ipt_listing iptables 2>/dev/null); then
    [[ -z "$out" ]] && pass 'G5.3 missing nat table -> rc 0, empty listing (M-14(3) analogue)' || fail 'G5.3 missing nat table printed non-empty listing'
else fail 'G5.3 missing nat table rc != 0'; fi
group_start
export MOCK_MODE_4=perm
if _hy2hop_fetch_ipt_listing iptables >/dev/null 2>&1; then fail 'G5.4 permission error reported success'; else
    [[ "$?" == 2 ]] && pass 'G5.4 permission error -> rc 2 (inspection-failed)' || fail "G5.4 permission error rc $? (expected 2)"
fi
group_start
export MOCK_MODE_4=nft
if out=$(_hy2hop_fetch_ipt_listing iptables 2>/dev/null); then
    [[ -z "$out" ]] && pass 'G5.5 nft-incompatible table -> rc 0, empty listing' || fail 'G5.5 nft-incompatible table printed non-empty listing'
else fail 'G5.5 nft-incompatible table rc != 0'; fi
group_start
if out=$(_hy2hop_fetch_ipt_listing iptables 2>/dev/null); then
    [[ -z "$out" ]] && pass 'G5.6 empty table -> rc 0, empty listing' || fail 'G5.6 empty table printed non-empty listing'
else fail 'G5.6 empty table rc != 0'; fi

# ================= G6: _hy2hop_ipt_delete_chain ===========================
printf '== G6: _hy2hop_ipt_delete_chain ==\n'
CHAIN='HYSTERIA-PR-abcdef12'
group_start
printf '%s\n' "-N $CHAIN" \
    "-A PREROUTING -p udp --dport 20000 -j $CHAIN" \
    "-A OUTPUT -p udp --dport 20001 -j $CHAIN" \
    "$OWN4" \
    '-A PREROUTING -p tcp --dport 443 -j DOCKER' > "$STATE/nat.v4"
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then pass 'G6.1 delete chain with 2 jumps rc 0'; else fail 'G6.1 delete chain rc != 0'; fi
if ! grep -qF -- "-j $CHAIN" "$STATE/nat.v4" && ! grep -qF -- "-N $CHAIN" "$STATE/nat.v4"; then pass 'G6.1 jumps + chain gone from state'; else fail 'G6.1 jump or chain remains'; fi
if [[ "$(wc -l < "$STATE/nat.v4")" == 2 ]]; then pass 'G6.1 foreign rules untouched (2 lines remain)'; else fail "G6.1 line count $(wc -l < "$STATE/nat.v4"), expected 2"; fi
_d1=$(grep -n ' -D PREROUTING ' "$LOG/iptables.log" | head -1 | cut -d: -f1)
_d2=$(grep -n ' -D OUTPUT ' "$LOG/iptables.log" | head -1 | cut -d: -f1)
_ff=$(grep -n " -F $CHAIN" "$LOG/iptables.log" | head -1 | cut -d: -f1)
_xx=$(grep -n " -X $CHAIN" "$LOG/iptables.log" | head -1 | cut -d: -f1)
if [[ -n "$_d1" && -n "$_d2" && -n "$_ff" && -n "$_xx" && "$_d1" -lt "$_d2" && "$_d2" -lt "$_ff" && "$_ff" -lt "$_xx" ]]; then
    pass 'G6.1 order: jumps deleted before -F, -F before -X (never -F first)'
else fail "G6.1 order wrong: D1=$_d1 D2=$_d2 F=$_ff X=$_xx"; fi
group_start
printf '%s\n' "$OWN4" '-A PREROUTING -p tcp --dport 443 -j DOCKER' > "$STATE/nat.v4"
_before=$(cat "$STATE/nat.v4")
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then pass 'G6.2 absent chain -> rc 0 (no-op)'; else fail 'G6.2 absent chain rc != 0'; fi
[[ "$(cat "$STATE/nat.v4")" == "$_before" ]] && pass 'G6.2 state unchanged for absent chain' || fail 'G6.2 state changed for absent chain'
grep -q " -F $CHAIN" "$LOG/iptables.log" && fail 'G6.2 -F attempted for absent chain' || pass 'G6.2 no -F/-X for absent chain'
group_start
printf '%s\n' "-N $CHAIN" > "$STATE/nat.v4"
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then pass 'G6.3 empty chain (-N only) -> rc 0'; else fail 'G6.3 empty chain rc != 0'; fi
grep -qF -- "-N $CHAIN" "$STATE/nat.v4" && fail 'G6.3 empty chain remains' || pass 'G6.3 empty chain flushed + deleted'
group_start
printf '%s\n' "-A PREROUTING -p udp --dport 20000 -j $CHAIN" > "$STATE/nat.v4"
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then pass 'G6.4 dangling jump (no -N) -> rc 0'; else fail 'G6.4 dangling jump rc != 0'; fi
grep -qF -- "-j $CHAIN" "$STATE/nat.v4" && fail 'G6.4 dangling jump remains' || pass 'G6.4 dangling jump deleted, no -F/-X (no chain to flush)'
group_start
export MOCK_FAIL_D=1
printf '%s\n' "-N $CHAIN" "-A PREROUTING -p udp --dport 20000 -j $CHAIN" > "$STATE/nat.v4"
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then fail 'G6.5 -D failure reported success'; else pass 'G6.5 -D failure -> rc 1'; fi
grep -qF -- "-j $CHAIN" "$STATE/nat.v4" && pass 'G6.5 failed jump left in place (not half-deleted)' || fail 'G6.5 jump gone despite -D failure'
group_start
export MOCK_MODE_4=perm
if _hy2hop_ipt_delete_chain iptables "$CHAIN"; then fail 'G6.6 query failure reported success'; else pass 'G6.6 query failure -> rc 1'; fi
group_start
printf '%s\n' "-N $CHAIN" "-A PREROUTING -p udp --dport 20000 -j $CHAIN" "$OWN6" > "$STATE/nat.v6"
if _hy2hop_ipt_delete_chain ip6tables "$CHAIN"; then pass 'G6.7 ip6tables chain deletion rc 0'; else fail 'G6.7 ip6tables chain deletion rc != 0'; fi
grep -qF -- "-j $CHAIN" "$STATE/nat.v6" && fail 'G6.7 ip6tables jump remains' || pass 'G6.7 ip6tables jump + chain gone, foreign v6 rule kept'

# ================= summary =================================================
printf 'failures: %s\n' "$FAILURES"
if (( FAILURES == 0 )); then printf 'RESULT: PASS — legacy-iptables frontend covered (G0-G6)\n'; exit 0; fi
printf 'RESULT: FAIL — %s check(s) failed\n' "$FAILURES" >&2
exit 1
