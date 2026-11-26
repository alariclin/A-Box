# ABOX-MODULE-BEGIN 14-selftest-main run_self_tests, main
#   Source: install.sh lines 69270-72525 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
run_self_tests() {
    # E-2-FIX: Disable Xray binary version probe for all self-tests.
    # effective_xray_version() prefers installed /usr/local/bin/xray over ABOX_XRAY_VERSION,
    # which made ML-KEM tests environment-dependent (fail on hosts with Xray installed).
    # PERF accounting note (M5): on the S2 reference run the 30.6 s self-test
    # decomposed as herestring guards ~18.6 s + fetch fixtures ~3.6 s +
    # python ~0.8 s + `bash -n` ~0.16 s; the ~7.0 s remainder is misc
    # builtins plus ~99,550 lines of xtrace overhead (~70 us/line) when
    # tracing -- a reporting gap, not a performance defect.
    local saved_probe_skip="${ABOX_XRAY_VERSION_PROBE_SKIP:-}"
    export ABOX_XRAY_VERSION_PROBE_SKIP=1
    local tmp failures=0 real_abox_sig='' real_abox_exists=0 selftest_prev_exit_trap selftest_prev_umask selftest_sni_seed='' selftest_script_dir=''
    selftest_prev_umask=$(umask)
    umask 077
    tmp=$(mktemp -d /tmp/A-Box-selftest.XXXXXX) || { umask "$selftest_prev_umask"; exit 1; }
    selftest_prev_exit_trap=$(trap -p EXIT || true)
    # Capture the absolute temp path in the EXIT trap itself. Bash function-local
    # variables may be out of scope when an unexpected exit reaches a trap.
    local selftest_tmp_quoted
    printf -v selftest_tmp_quoted '%q' "$tmp"
    # shellcheck disable=SC2064 # expand the %q-quoted absolute path when the trap is registered
    trap "rm -rf -- $selftest_tmp_quoted" EXIT
    selftest_cleanup() {
        rm -rf -- "$tmp"
        trap - EXIT
        if [[ -n "$selftest_prev_exit_trap" ]]; then
            eval "$selftest_prev_exit_trap" || true
        fi
        umask "$selftest_prev_umask"
        # E-2-FIX: Restore PROBE_SKIP to previous value.
        if [[ -n "$saved_probe_skip" ]]; then
            export ABOX_XRAY_VERSION_PROBE_SKIP="$saved_probe_skip"
        else
            unset ABOX_XRAY_VERSION_PROBE_SKIP
        fi
        return 0
    }
    selftest_abox_signature() {
        if [[ ! -e /etc/ddr && ! -L /etc/ddr ]]; then
            printf 'ABSENT\n'
            return 0
        fi
        [[ -d /etc/ddr && ! -L /etc/ddr ]] || return 1
        # D-07: BusyBox find (Alpine) lacks -printf; python3 is already a hard
        # dependency. S168: recursive walk (no symlink following); each
        # record is relpath + type + uid/gid/mode/size/mtime, plus a
        # chunked content sha256 for regular files ('ERR' when unreadable)
        # and the readlink target for symlinks; records sorted,
        # NUL-joined, sha256. A nested same-size content change or a
        # symlink retarget now changes the signature.
        python3 -I - <<'PY_ABOX_SIG' 2>/dev/null || return 1
import os, stat, sys, hashlib
def _ftype(m):
    if stat.S_ISREG(m): return 'f'
    if stat.S_ISDIR(m): return 'd'
    if stat.S_ISLNK(m): return 'l'
    if stat.S_ISFIFO(m): return 'p'
    if stat.S_ISSOCK(m): return 's'
    if stat.S_ISCHR(m): return 'c'
    if stat.S_ISBLK(m): return 'b'
    return '?'
def _sha256_file(p):
    try:
        _h = hashlib.sha256()
        with open(p, 'rb') as _fh:
            while True:
                _chunk = _fh.read(65536)
                if not _chunk:
                    break
                _h.update(_chunk)
        return _h.hexdigest()
    except OSError:
        return 'ERR'
_records = []
for _dirpath, _dirnames, _filenames in os.walk('/etc/ddr', topdown=True, followlinks=False):
    for _name in _dirnames + _filenames:
        _p = os.path.join(_dirpath, _name)
        _rel = os.path.relpath(_p, '/etc/ddr')
        try:
            _st = os.lstat(_p)
        except OSError:
            continue
        _t = _ftype(_st.st_mode)
        _extra = ''
        if _t == 'f':
            _extra = _sha256_file(_p)
        elif _t == 'l':
            try:
                _extra = os.readlink(_p)
            except OSError:
                _extra = 'ERR'
        _records.append(repr((_rel, _t, _st.st_uid, _st.st_gid, oct(stat.S_IMODE(_st.st_mode))[2:], _st.st_size, repr(_st.st_mtime), _extra)))
try:
    _st = os.lstat('/etc/ddr')
    _records.append(repr(('.', 'd', _st.st_uid, _st.st_gid, oct(stat.S_IMODE(_st.st_mode))[2:], _st.st_size, repr(_st.st_mtime), '')))
except OSError:
    sys.exit(1)
_records.sort()
_blob = (chr(0).join(_records) + chr(0)) if _records else ''
sys.stdout.write(hashlib.sha256(_blob.encode()).hexdigest() + chr(10))
PY_ABOX_SIG
    }
    if (( EUID == 0 )); then
        if [[ -e /etc/ddr || -L /etc/ddr ]]; then real_abox_exists=1; fi
        real_abox_sig=$(selftest_abox_signature) || { echo 'FAIL: live /etc/ddr baseline signature unavailable'; failures=$((failures + 1)); }
    fi
    assert_ok() { "$@" >/dev/null 2>&1 || { echo "FAIL: $*"; failures=$((failures + 1)); }; }
    assert_bad() { "$@" >/dev/null 2>&1 && { echo "FAIL expected bad: $*"; failures=$((failures + 1)); } || true; }
    selftest_has() { command -v "$1" >/dev/null 2>&1; }
    selftest_note() { printf 'SELF_TEST_NOTE: %s\n' "$*"; }
    # PERF (2026-11-25): the 215 static guards below used to grep a 4.5 MB
    # in-memory copy via `<<< "$source_body"`, and bash materialised a fresh
    # 4.5 MB here-string for every assertion (~51 ms each in the sandbox,
    # ~14 s per self-test run). The filtered source is now snapshotted once
    # to a file inside $tmp (removed by selftest_cleanup / the EXIT trap on
    # every exit path) and every guard greps the file instead (~3-5 ms each).
    # The snapshot keeps the same sed filter: lines from `run_self_tests() {`
    # through `main() {` are excluded, so an assertion can never match its own
    # assertion line; never grep "$0" directly for these guards. Consistency
    # is checked below (non-empty, no self-test-region marker).
    local source_body_file=""
    source_body_file="$tmp/source-body.txt"
    if ! sed -n '/^run_self_tests() {$/,/^main() {$/!p' "$0" > "$source_body_file"; then
        echo 'FAIL: static source extraction for regression guards'; failures=$((failures + 1))
    elif [[ ! -s "$source_body_file" ]] || grep -q '^run_self_tests() {$' "$source_body_file"; then
        echo 'FAIL: static source snapshot inconsistent (empty or contains self-test region)'; failures=$((failures + 1))
    fi
    # BusyBox tar rejects GNU --owner/--group; prefer GNU flags, else python, else plain tar.
    # Third arg force_root=1 rewrites members to uid/gid 0 (good/bad fixtures). Default preserves
    # on-disk ownership (needed for ACME runtime-owned backup acceptance tests).
    selftest_pack_tar_gz() {
        local src_dir="$1" out="$2" force_root="${3:-0}"
        if tar --help 2>&1 | grep -Fq -- '--owner='; then
            if [[ "$force_root" == '1' ]]; then
                tar -C "$src_dir" --owner=0 --group=0 --numeric-owner -czf "$out" root meta || return 1
            else
                tar -C "$src_dir" --numeric-owner -czf "$out" root meta || return 1
            fi
        elif selftest_has python3; then
            python3 -I - "$src_dir" "$out" "$force_root" <<'PY_SELFTEST_TAR' || return 1
import os, sys, tarfile
src, out, force_root = sys.argv[1], sys.argv[2], sys.argv[3]
with tarfile.open(out, 'w:gz') as tf:
    for name in ('root', 'meta'):
        path = os.path.join(src, name)
        def filt(m, force=force_root):
            if force == '1':
                m.uid = 0
                m.gid = 0
                m.uname = 'root'
                m.gname = 'root'
            return m
        tf.add(path, arcname=name, filter=filt)
PY_SELFTEST_TAR
        else
            tar -C "$src_dir" -czf "$out" root meta || return 1
        fi
    }

    assert_ok valid_port 1
    assert_ok valid_port 65535
    assert_ok valid_port 00065535
    assert_bad valid_port 0
    assert_bad valid_port 000000
    assert_bad valid_port 65536
    assert_bad valid_port 08x
    assert_bad valid_port 999999999999999999999999999999999999
    assert_ok valid_positive_int 999999999999999999
    assert_bad valid_positive_int 1000000000000000000
    if selftest_has openssl; then
        _rand4096=$(rand_alnum 4096 2>/dev/null) || { echo 'FAIL: rand_alnum maximum length'; failures=$((failures + 1)); }
        [[ ${#_rand4096} -eq 4096 && "$_rand4096" =~ ^[A-Za-z0-9]+$ ]] || { echo 'FAIL: rand_alnum maximum-length output'; failures=$((failures + 1)); }
    else
        selftest_note 'rand_alnum maximum-length test skipped (openssl missing)'
    fi
    assert_ok valid_traffic_limit_gb 8589934591
    assert_bad valid_traffic_limit_gb 8589934592
    assert_bad valid_traffic_limit_gb 999999999999999999
    assert_ok valid_hy2_bandwidth_mbps 8589934591
    assert_bad valid_hy2_bandwidth_mbps 8589934592
    assert_bad valid_hy2_bandwidth_mbps 1000000000000000000
    assert_ok valid_backup_retention_count 0
    assert_ok valid_backup_retention_count 1000
    assert_bad valid_backup_retention_count -1
    assert_bad valid_backup_retention_count abc
    assert_bad valid_backup_retention_count 1001
    assert_bad valid_single_line_secret $'secret\tvalue'
    assert_bad valid_single_line_secret $'secret\nvalue'
    assert_ok valid_single_line_secret 'normal-secret'
    assert_ok valid_interface_name abcdefghijklmno
    assert_bad valid_interface_name abcdefghijklmnop
    assert_ok valid_port_range 20000:25000
    assert_ok valid_port_range 20000-25000
    assert_bad valid_port_range 25000:20000
    assert_ok valid_canonical_port 443
    assert_bad valid_canonical_port 000443
    assert_ok valid_canonical_port_range 20000-25000
    assert_bad valid_canonical_port_range 020000-025000
    assert_ok valid_domain example.com
    assert_bad valid_domain -bad.example.com
    [[ "$(sni_raw_score 0.055769 0.064025 0.064121 -340)" == '-266' ]] || { echo 'FAIL: SNI raw scoring must preserve negative values'; failures=$((failures + 1)); }
    [[ "$(sni_adjust_score -266 -1500)" == '-1766' ]] || { echo 'FAIL: SNI adjusted scoring must preserve signed values'; failures=$((failures + 1)); }
    if ! (
        command() {
            if [[ "${1:-}" == '-v' && "${2:-}" == 'python3' ]]; then return 1; fi
            builtin command "$@"
        }
        _fallback_notice='[ABOX REDACTED DOCUMENT OMITTED: python3 is unavailable; diagnostic redaction cannot be verified. This document was suppressed in full and no original content is included.]'
        _fallback_out=$(printf '%s\n' '{"message":"Authorization: Bearer <redacted>", "api_key":"fallback-api-secret", "safe":"visible"}' | redact_secrets_stream 2>/dev/null); _fallback_rc=$?
        [[ "$_fallback_rc" == 2 && "$_fallback_out" == "$_fallback_notice" && "$_fallback_out" != *fallback-api-secret* && "$_fallback_out" != *visible* ]]
    ); then echo 'FAIL: no-Python diagnostic document suppression'; failures=$((failures + 1)); fi
    # R19 (Scheme A): no-Python diagnostic documents are suppressed whole.
    # The cases below keep every historical input and case ID, but the
    # expectation is now uniform: with python3 hidden,
    # redact_secrets_stream returns rc=2 and writes exactly the fixed
    # OMITTED notice (one line + LF); no input byte survives. The old
    # sed-only rules are deleted, not bypassed. _fb_expect_omitted checks
    # rc=2 plus byte-exact notice output via a file (command substitution
    # strips trailing newlines and cannot pin empty-input / NUL bytes).
    # Boundary cases (1 MiB, canary, NUL, /dev/full, stub tripwires) and
    # negative mutations (rc 2->0, one prefix byte, passthrough) live in
    # the same block; write_redacted_file / SIGPIPE / failing-python3
    # integration checks follow it. Python-path assertions below are
    # untouched.
    _fb_bad=$( (
        command() {
            if [[ "${1:-}" == '-v' && "${2:-}" == 'python3' ]]; then return 1; fi
            builtin command "$@"
        }
        _fb_notice='[ABOX REDACTED DOCUMENT OMITTED: python3 is unavailable; diagnostic redaction cannot be verified. This document was suppressed in full and no original content is included.]'
        _fb_expect_omitted() {
            local label="$1" input="$2" rc
            printf '%s' "$input" | redact_secrets_stream > "$tmp/fb-out" 2>/dev/null; rc=$?
            if [[ $rc != 2 ]] || ! {
                if command -v cmp >/dev/null 2>&1; then
                    printf '%s\n' "$_fb_notice" | cmp -s - "$tmp/fb-out"
                else
                    (
                        set -o pipefail
                        _r20_expect_hex=$(printf '%s\n' "$_fb_notice" | LC_ALL=C od -An -v -tx1) || exit 2
                        _r20_actual_hex=$(LC_ALL=C od -An -v -tx1 < "$tmp/fb-out") || exit 2
                        [[ "$_r20_actual_hex" == "$_r20_expect_hex" ]]
                    )
                fi
            }; then printf 'FAIL-SED %s\n' "$label"; fi
        }
        _fb_expect_omitted $'r01-env-quote' $'UUID=ab"cd-01\n'
        _fb_expect_omitted $'r03-mid-sq' $'xx Authorization: \'bare-secret-03\', tail\n'
        _fb_expect_omitted $'r04-mid-sq-cookie' $'xx Cookie: \'sid=cookie-secret-04\', tail\n'
        _fb_expect_omitted $'r05-line-auth-dq' $'Authorization: "Bearer token-05"\n'
        _fb_expect_omitted $'r06-line-cookie-space' $'Cookie: "sid=cookie-06"\n'
        _fb_expect_omitted $'r06-line-cookie-nospace' $'Cookie:"sid=cookie-06"\n'
        _fb_expect_omitted $'r08-dq-comma' $'{"token": "a,b", "safe":"visible"}\n'
        _fb_expect_omitted $'r09-sq-tail' $'\'token\': \'sq-head,sq-tail-secret\' visible\n'
        _fb_expect_omitted $'r10-nested-dq' $'id: "id: \'inner" tail \' visible\n'
        _fb_expect_omitted $'r11-nested-comment-dq' $'xx id: /* id: "comment-secret" */ "outer-secret" visible\n'
        _fb_expect_omitted $'r12-nested-sq' $'id: \'id: /* note */ "inner\' tail " visible\n'
        _fb_expect_omitted $'r13-nested-comment-sq' $'xx id: /* id: \'comment-secret\' */ \'outer-secret\' visible\n'
        _fb_expect_omitted $'r14-line-id-gap-dq' $'id: /* note */ "dq-secret-14" visible\n'
        _fb_expect_omitted $'r15-mid-id-gap-dq' $'xx "id": /* note */ "dq-secret-15" visible\n'
        _fb_expect_omitted $'r16-line-id-gap-sq' $'id: /* note */ \'sq-secret-16\' visible\n'
        _fb_expect_omitted $'r17-mid-id-gap-sq' $'xx \'id\': /* note */ \'sq-secret-17\' visible\n'
        _fb_expect_omitted $'r19-nested-id-gap-bare' $'id: abc-id:/* note */ 456-secret visible\n'
        _fb_expect_omitted $'r20-line-id-gap-bare' $'id: /* note */ 123abc-20 visible\n'
        _fb_expect_omitted $'r21-mid-id-gap-bare' $'xx "id": /* note */ 123abc-21 visible\n'
        _fb_expect_omitted $'r23-nested-num' $'xx id: /* id: 123-secret */ 456-secret visible\n'
        _fb_expect_omitted $'r25-nested-bare' $'xx id: /* id: 123abc */ outerabc visible\n'
        _fb_expect_omitted $'r26-unquoted' $'token: unquoted-secret-26 visible\n'
        _fb_expect_omitted $'r27-unterm-dq' $'token: "unterm-secret-27\n'
        _fb_expect_omitted $'r28-link' $'see vless://link-secret-28@example.test visible\n'
        _fb_expect_omitted $'r29-userinfo' $'see https://user:pw-secret-29@example.test/path visible\n'
        _fb_expect_omitted $'r08-api-key' $'{"api_key": "head,api-tail-secret", "safe":"visible"}\n'
        _fb_expect_omitted $'r08-cert-key' $'{"HY2_CERT_PUBKEY_SHA256_B64": "head,cert-tail-secret", "safe":"visible"}\n'
        _fb_expect_omitted $'r05-proxy-basic' $'Proxy-Authorization: "Basic proxy-secret"\n'
        _fb_expect_omitted $'r06-set-cookie-nospace' $'Set-Cookie:"sid=setcookie-06"\n'
        _fb_expect_omitted $'r01-ss-pass-env' $'SS_PASS=ab"env-tail-secret\n'
        _fb_expect_omitted $'r28-hy2-link' $'see hy2://link-tail-secret@example.test visible\n'
        _fb_expect_omitted $'d2-pem' $'-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n'
        _fb_expect_omitted $'d2-blockscalar' $'token: |\n  scalar-secret\n'
        _fb_expect_omitted $'d2-blockscalar-folded' $'token: >-\n  scalar-tail-secret\n'
        _fb_expect_omitted $'d2-userpass' $'userpass:\n  alice: pass-secret\n'
        _fb_expect_omitted $'d2-array' $'token: ["aaa", "bbb"]\n'
        _fb_expect_omitted $'d2-array-cert-key' $'HY2_CERT_SHA256_FP: ["cert-array-secret"]\n'
        _fb_expect_omitted $'d2-id-gap-eol-comment' $'id: /* note */\n"dq-secret"\n'
        _fb_expect_omitted $'d2-id-gap-slash' $'id: // note\n"dq-secret"\n'
        _fb_expect_omitted $'d2-id-gap-key-sep' $'id /* note */ : "dq-secret"\n'
        _fb_expect_omitted $'d2-id-gap-unterm-block' $'id: /* open\n"id-gap-tail-secret"\n'
        _fb_expect_omitted $'d2-id-gap-slash-key-sep' $'id // note\n"id-gap-tail-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-key-sep' $'token /* note */ : "gap-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-after-sep' $'token: /* note */\n"gap-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-after-sep-slash' $'token: // note\n"gap-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-slash-key-sep' $'token // note : "gap-tail-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-cert-key' $'HY2_CERT_PUBKEY_SHA256_B64 /* note */ : "cert-gap-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-env-eq' $'SS_PASS /* note */ = "env-gap-secret"\n'
        _fb_expect_omitted $'d2-nonid-gap-crlf' $'token: /* note */\r\n"gap-tail-secret"\r\n'
        _fb_expect_omitted $'d2-auth-gap-key-sep' $'Authorization /* note */ : Bearer auth-gap-secret\n'
        _fb_expect_omitted $'d2-auth-gap-slash' $'Authorization: // note\nBearer auth-gap-secret\n'
        _fb_expect_omitted $'d2-auth-gap-proxy-basic' $'Proxy-Authorization // note : Basic proxy-gap-secret\n'
        _fb_expect_omitted $'d2-cookie-gap-key-sep' $'Cookie /* note */ : sid=x\n'
        _fb_expect_omitted $'d2neg-url-value' $'token: "https://example.test"\n'
        _fb_expect_omitted $'d2neg-trailing-comment' $'token: "x" // note\n'
        _fb_expect_omitted $'d2neg-id-trailing-comment' $'id: "x" // note\n'
        _fb_expect_omitted $'d2neg-id-sameline-gap' $'id: /* note */ "dq-secret"\n'
        _fb_expect_omitted $'d2neg-plain' $'name: "visible"\n'
        _fb_expect_omitted $'keep-id-int' $'id: 123\n'
        _fb_expect_omitted $'keep-id-negint' $'id: -123\n'
        _fb_expect_omitted $'keep-id-zero' $'id: 0\n'
        _fb_expect_omitted $'edge-empty' $''
        _fb_expect_omitted $'edge-no-trailing-lf' $'token: "notrail-secret"'
        _fb_expect_omitted $'edge-only-lf' $'\n'
        _fb_expect_omitted $'edge-crlf' $'token: "crlf-secret"\r\n'
        _fb_expect_omitted $'edge-multiline' $'safe one\nsafe two\n'
        _fb_expect_omitted $'edge-safe-then-d2' $'name: "visible"\ntoken: /* note */\n"gap-secret"\n'
        _fb_expect_omitted $'edge-d2-then-safe' $'token: /* note */\n"gap-secret"\nname: "visible"\n'
        # R19 boundary cases (Scheme A): size, canary, NUL, write failure.
        _fb_big_start=$( { printf '%s' 'token: "big-secret-start" '; head -c 1048570 /dev/zero | tr '\0' 'x'; } )
        _fb_expect_omitted $'big-1m-secret-start' "$_fb_big_start"
        _fb_big_end=$( { head -c 1048570 /dev/zero | tr '\0' 'x'; printf '%s' ' token: "big-secret-end"'; } )
        _fb_expect_omitted $'big-1m-secret-end' "$_fb_big_end"
        _fb_expect_omitted $'canary-random' "canary-$RANDOM-$RANDOM-no-python-marker"
        _fb_expect_omitted $'plain-visible' $'normal: visible\n'
        _fb_expect_omitted $'empty' $''
        # NUL bytes cannot travel in a shell variable: direct byte check.
        printf 'token: "nul-secret"\0tail' | redact_secrets_stream > "$tmp/fb-out" 2>/dev/null
        if [[ $? != 2 ]] || ! {
            if command -v cmp >/dev/null 2>&1; then
                printf '%s\n' "$_fb_notice" | cmp -s - "$tmp/fb-out"
            else
                (
                    set -o pipefail
                    _r20_expect_hex=$(printf '%s\n' "$_fb_notice" | LC_ALL=C od -An -v -tx1) || exit 2
                    _r20_actual_hex=$(LC_ALL=C od -An -v -tx1 < "$tmp/fb-out") || exit 2
                    [[ "$_r20_actual_hex" == "$_r20_expect_hex" ]]
                )
            fi
        }; then printf 'FAIL-SED nul-bytes\n'; fi
        # Notice write failure must be rc=1, never masked as 2.
        if [[ -c /dev/full ]]; then
            printf 'token: "x"' | redact_secrets_stream > /dev/full 2>/dev/null
            [[ $? == 1 ]] || printf 'FAIL-SED notice-write-fail\n'
        else
            printf 'FAIL-SED no-dev-full\n'
        fi
        # No-Python path must never invoke sed/grep/cat (stub tripwires).
        sed() { : > "$tmp/sed-called"; return 1; }
        grep() { : > "$tmp/grep-called"; return 1; }
        cat() { : > "$tmp/cat-called"; return 1; }
        _fb_expect_omitted $'no-sed-grep-cat' $'token: "stub-secret"\n'
        [[ ! -e "$tmp/sed-called" && ! -e "$tmp/grep-called" && ! -e "$tmp/cat-called" ]] || printf 'FAIL-SED stub-called\n'
        unset -f sed grep cat
        # Negative mutations: the helper must catch each broken behaviour.
        _fb_neg() {
            local label="$1" got
            got=$(_fb_expect_omitted "$label" $'token: "neg-secret"\n' 2>/dev/null)
            [[ "$got" == FAIL-SED* ]] || printf 'FAIL-SED neg-%s-not-caught\n' "$label"
        }
        redact_secrets_stream() { printf '%s\n' "$_fb_notice"; return 0; }
        _fb_neg $'neg-rc0'
        redact_secrets_stream() { printf 'x%s\n' "$_fb_notice"; return 2; }
        _fb_neg $'neg-prefix-byte'
        redact_secrets_stream() { cat; return 0; }
        _fb_neg $'neg-passthrough'
    ) )
    if [[ -n "$_fb_bad" ]]; then printf '%s\n' "$_fb_bad"; failures=$((failures + $(printf '%s\n' "$_fb_bad" | grep -c '^FAIL-SED'))); fi
    # R19 integration: write_redacted_file() status sequence must not
    # carry state across calls (redacted -> omitted -> failed).
    if ! (
        printf '%s\n' '{"token": "integ-secret", "safe": "visible"}' > "$tmp/integ-redacted-src" &&
        write_redacted_file "$tmp/integ-redacted-src" "$tmp/integ-redacted-dst" &&
        [[ "$WRITE_REDACTED_FILE_STATUS" == 'redacted' ]] &&
        printf '%s\n' '{"token": "integ-secret2"}' > "$tmp/integ-omitted-src" &&
        command() {
            if [[ "${1:-}" == '-v' && "${2:-}" == 'python3' ]]; then return 1; fi
            builtin command "$@"
        } &&
        write_redacted_file "$tmp/integ-omitted-src" "$tmp/integ-omitted-dst" &&
        [[ "$WRITE_REDACTED_FILE_STATUS" == 'omitted' ]] &&
        grep -q 'python3 is unavailable' "$tmp/integ-omitted-dst" &&
        ! grep -q 'integ-secret2' "$tmp/integ-omitted-dst" &&
        printf 'x' > "$tmp/integ-blocker" &&
        ! write_redacted_file "$tmp/integ-omitted-src" "$tmp/integ-blocker/dst" 2>/dev/null &&
        [[ "$WRITE_REDACTED_FILE_STATUS" == 'failed' ]] &&
        [[ ! -e "$tmp/integ-blocker/dst" ]] &&
        unset -f command &&
        [[ "$WRITE_REDACTED_FILE_STATUS" == 'failed' ]]
    ); then echo 'FAIL: write_redacted_file omitted status sequence'; failures=$((failures + 1)); fi
    # R19 integration: a producer dying with SIGPIPE (reader closed
    # without reading) must not break the omitted path: rc=2, notice
    # only, no retry of the original.
    if ! (
        command() {
            if [[ "${1:-}" == '-v' && "${2:-}" == 'python3' ]]; then return 1; fi
            builtin command "$@"
        }
        seq 1 100000 2>/dev/null | redact_secrets_stream > "$tmp/sigpipe-out" 2>/dev/null
        _sp_rcs=("${PIPESTATUS[@]}")
        [[ "${_sp_rcs[1]:-1}" == 2 && "${_sp_rcs[0]:-1}" == 141 ]] &&
        {
            if command -v cmp >/dev/null 2>&1; then
                printf '%s\n' '[ABOX REDACTED DOCUMENT OMITTED: python3 is unavailable; diagnostic redaction cannot be verified. This document was suppressed in full and no original content is included.]' | cmp -s - "$tmp/sigpipe-out"
            else
                (
                    set -o pipefail
                    _r20_expect_hex=$(printf '%s\n' '[ABOX REDACTED DOCUMENT OMITTED: python3 is unavailable; diagnostic redaction cannot be verified. This document was suppressed in full and no original content is included.]' | LC_ALL=C od -An -v -tx1) || exit 2
                    _r20_actual_hex=$(LC_ALL=C od -An -v -tx1 < "$tmp/sigpipe-out") || exit 2
                    [[ "$_r20_actual_hex" == "$_r20_expect_hex" ]]
                )
            fi
        } &&
        unset -f command
    ); then echo 'FAIL: SIGPIPE producer must not break omitted path'; failures=$((failures + 1)); fi
    # R19 integration: python3 present but failing to start must fail
    # closed (rc=1, no output) -- never sed, never a verbatim copy.
    if ! (
        python3() { return 1; }
        _pyfail_out=$(printf '%s\n' '{"token": "pyfail-secret"}' | redact_secrets_stream 2>/dev/null); _pyfail_rc=$?
        [[ "$_pyfail_rc" == 1 && -z "$_pyfail_out" ]]
    ); then echo 'FAIL: failing python3 must fail closed without sed or copy'; failures=$((failures + 1)); fi
    if ! (
        get_public_ip() { printf '1.1.1.9\n'; }
        asn_lookup_ip() {
            case "${1:-}" in
                1.1.1.9) printf 'asn=AS13335\tcountry=US\torg=Test VPS' ;;
                1.1.1.1) printf 'asn=AS13335\tcountry=US\torg=Test target' ;;
                *) printf 'asn=unknown\tcountry=unknown\torg=unknown' ;;
            esac
        }
        sni_openssl_check() { printf '%s\n' "${3:-EMPTY}" >> "$tmp/sni-openssl-ip-capture"; printf 'tls13=1\talpn=h2\tsan=1'; }
        msg() { :; }
        printf '%s\n' $'00001000\texample.org\tapp=0.04s\tttfb=0.1s\ttotal=0.11s\thttp=2\tcode=200\tip=1.1.1.1' > "$tmp/sni-stage1-valid.tsv"
        sni_verify_raw_report "$tmp/sni-stage1-valid.tsv" "$tmp/sni-stage2-valid.tsv" 1 2 >/dev/null 2>&1
        [[ "$(cat "$tmp/sni-openssl-ip-capture")" == '1.1.1.1' ]] &&
        grep -Fq 'tls13=1' "$tmp/sni-stage2-valid.tsv" &&
        printf '%s\n' $'00001000\texample.org\tapp=0.04s\tttfb=0.1s\ttotal=0.11s\thttp=2\tcode=200\tip=127.0.0.1' > "$tmp/sni-stage1-private.tsv" &&
        rm -f -- "$tmp/sni-openssl-ip-capture" &&
        sni_verify_raw_report "$tmp/sni-stage1-private.tsv" "$tmp/sni-stage2-private.tsv" 1 2 >/dev/null 2>&1 &&
        [[ ! -e "$tmp/sni-openssl-ip-capture" ]] &&
        grep -Fq 'tls13=0' "$tmp/sni-stage2-private.tsv"
    ); then echo 'FAIL: SNI stage-2 must pin to validated IP and reject non-public IP'; failures=$((failures + 1)); fi
    assert_ok valid_url_https https://example.com/path
    assert_ok valid_url_https https://example.com:443/path
    assert_bad valid_url_https http://example.com/
    assert_bad valid_url_https 'https://bad example.com/'
    [[ "$(normalize_https_url_input www.microsoft.com)" == 'https://www.microsoft.com/' ]] || { echo 'FAIL: normalize HTTPS URL'; failures=$((failures + 1)); }
    [[ "$(normalize_https_url_input https://www.microsoft.com)" == 'https://www.microsoft.com/' ]] || { echo 'FAIL: normalize HTTPS URL trailing slash'; failures=$((failures + 1)); }
    [[ "$(build_ss2022_uri 203.0.113.10 2053 'abc+/=')" == 'ss://2022-blake3-aes-128-gcm:abc%2B%2F%3D@203.0.113.10:2053#SS' ]] || { echo 'FAIL: SS-2022 SIP002/SIP022 URI percent encoding'; failures=$((failures + 1)); }
    # i18n parity guard: every tr_msg key needs all six language arms.
    # U234: an empty enumeration must fail, not silently pass.
    # Negative samples below prove the guard catches all six failure
    # classes (empty enum, missing arm, duplicate arm, bad pattern,
    # missing-plus-duplicate cancellation, unreadable source) instead
    # of only passing on clean input.
    _i18n_rc=0
    check_i18n_parity_file "$0" || _i18n_rc=$?
    failures=$((failures + _i18n_rc))
    _i18n_syn=$(mktemp -d /tmp/A-Box-i18n-neg.XXXXXX) || { echo 'FAIL: i18n negative sample setup'; failures=$((failures + 1)); }
    if [[ -n "$_i18n_syn" && -d "$_i18n_syn" ]]; then
        # R64-01: a failed sample write must not pass vacuously (the
        # loop below only counts a failure when the checker returns 0,
        # so an empty/missing file -- checker returns 1 -- would be
        # misread as "correctly caught"). Track write failures and
        # verify the files afterwards: a mid-stream printf failure
        # inside a { for ...; } group can be masked by the last
        # printf, so the rc alone is not sufficient evidence.
        local _i18n_gen_failed=0
        : > "$_i18n_syn/empty.txt" || _i18n_gen_failed=1
        printf '%s\n' '        zh:synkey) echo x ;;' '        en:synkey) echo x ;;' '        ru:synkey) echo x ;;' '        fa:synkey) echo x ;;' '        zh-tw:synkey) echo x ;;' > "$_i18n_syn/missing.txt" || _i18n_gen_failed=1
        { for _l in zh en ru fa zh-tw ja; do printf '        %s:synkey) echo x ;;\n' "$_l"; done; printf '        zh:synkey) echo x ;;\n'; } > "$_i18n_syn/dup.txt" || _i18n_gen_failed=1
        { for _l in en ru fa zh-tw ja; do printf '        %s:synkey) echo x ;;\n' "$_l"; done; printf '        zh:synkey echo x ;;\n'; } > "$_i18n_syn/badpat.txt" || _i18n_gen_failed=1
        # S167: cancellation sample: zh twice, ja missing, total still
        # 6 -- the old total-count guard passed this; per-language
        # counting must fail it (on ja with 0 arms and zh with 2).
        { for _l in zh en ru fa zh-tw; do printf '        %s:synkey) echo x ;;\n' "$_l"; done; printf '        zh:synkey) echo x ;;\n'; } > "$_i18n_syn/cancel.txt" || _i18n_gen_failed=1
        for _s in missing dup badpat cancel; do [[ -s "$_i18n_syn/$_s.txt" ]] || _i18n_gen_failed=1; done
        [[ -e "$_i18n_syn/empty.txt" ]] || _i18n_gen_failed=1
        if (( _i18n_gen_failed == 1 )); then
            echo 'FAIL: i18n negative sample generation failed'
            failures=$((failures + 1))
        else
            for _s in empty missing dup badpat cancel; do
                check_i18n_parity_file "$_i18n_syn/$_s.txt" >/dev/null 2>&1 && { echo "FAIL: i18n negative sample $_s not caught"; failures=$((failures + 1)); }
            done
        fi
        check_i18n_parity_file "$_i18n_syn/nofile.txt" >/dev/null 2>&1 && { echo 'FAIL: i18n negative sample nofile not caught'; failures=$((failures + 1)); }
        rm -rf -- "$_i18n_syn"
    fi
    unset _i18n_syn

    selftest_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || selftest_script_dir=''
    if [[ -n "${ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE:-}" && -f "$ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE" && ! -L "$ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE" ]]; then
        selftest_sni_seed="$ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE"
    elif [[ -n "$selftest_script_dir" && -f "$selftest_script_dir/data/sni-candidates.txt" && ! -L "$selftest_script_dir/data/sni-candidates.txt" ]]; then
        selftest_sni_seed="$selftest_script_dir/data/sni-candidates.txt"
    elif [[ -f "$ABOX_DIR/A-Box-sni-candidates.txt" && ! -L "$ABOX_DIR/A-Box-sni-candidates.txt" ]]; then
        selftest_sni_seed="$ABOX_DIR/A-Box-sni-candidates.txt"
    fi
    grep -Fq 'ABOX_SNI_HARD_MAX=16384' "$source_body_file" || { echo 'FAIL: SNI hard ceiling missing'; failures=$((failures + 1)); }
    ! sed -n '/^write_sni_candidate_library() {$/,/^sni_domain_penalty() {$/p' "$0" | grep -Fq 'cat > "$raw" <<' || { echo 'FAIL: SNI candidates must live outside install.sh'; failures=$((failures + 1)); }
    grep -Fq 'data/sni-candidates.txt' "$source_body_file" || { echo 'FAIL: SNI database URL/path missing'; failures=$((failures + 1)); }
    grep -Fq 'sni_store_candidate_cache' "$source_body_file" || { echo 'FAIL: SNI cache synchronization helper missing'; failures=$((failures + 1)); }
    grep -Fq 'remove_sni_candidate_cache' "$source_body_file" || { echo 'FAIL: SNI cache uninstall cleanup helper missing'; failures=$((failures + 1)); }
    grep -Fq 'sni_normalize_candidate_file() {' "$source_body_file" || { echo 'FAIL: SNI database validator missing'; failures=$((failures + 1)); }
    assert_ok sni_san_matches_domain api.example.org $'X509v3 Subject Alternative Name:\n DNS:api.example.org, DNS:*.other.example'
    assert_ok sni_san_matches_domain api.example.org $'X509v3 Subject Alternative Name:\n DNS:*.example.org'
    assert_bad sni_san_matches_domain deep.api.example.org $'X509v3 Subject Alternative Name:\n DNS:*.example.org'
    assert_bad sni_san_matches_domain api.example.org $'X509v3 Subject Alternative Name:\n DNS:apiXexampleXorg'
    if [[ -n "$selftest_sni_seed" ]]; then
        ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE="$selftest_sni_seed" ABOX_SNI_FULL_MAX=0 write_sni_candidate_library full "$tmp/sni-full.txt"
        sni_count=$(wc -l < "$tmp/sni-full.txt" | tr -d ' ')
        [[ "$sni_count" =~ ^[0-9]+$ && "$sni_count" -ge 2500 ]] || { echo "FAIL: SNI library size < 2500 ($sni_count)"; failures=$((failures + 1)); }
        grep -qx 'www.confluent.io' "$tmp/sni-full.txt" || { echo 'FAIL: SNI library missing www.confluent.io'; failures=$((failures + 1)); }
        grep -qx 'www.apache.org' "$tmp/sni-full.txt" || { echo 'FAIL: SNI library missing www.apache.org'; failures=$((failures + 1)); }
        if grep -Eiq '(^|\.)(google|gstatic|googleapis|googleusercontent|youtube|facebook|instagram|twitter|x|tiktok|telegram|whatsapp|wikipedia|wikimedia|openai|anthropic|huggingface|torproject|apple|icloud|nist|cisa|github)\.' "$tmp/sni-full.txt"; then
            echo 'FAIL: SNI library contains high-risk blocked/sanction-sensitive domains'
            failures=$((failures + 1))
        fi
        printf '%s\n' '# malformed candidate fixture' 'valid.example.org' 'bad host.example.org' > "$tmp/sni-invalid-source.txt"
        if sni_normalize_candidate_file "$tmp/sni-invalid-source.txt" "$tmp/sni-invalid-normalized.txt"; then
            echo 'FAIL: SNI database validator accepted an invalid hostname'; failures=$((failures + 1))
        fi
        ABOX_SNI_CANDIDATE_SOURCE_OVERRIDE="$selftest_sni_seed" ABOX_SNI_MINI_MAX=0 write_sni_candidate_library mini "$tmp/sni-mini.txt"
        mini_count=$(wc -l < "$tmp/sni-mini.txt" | tr -d ' ')
        [[ "$mini_count" =~ ^[0-9]+$ && "$mini_count" -eq "$sni_count" ]] || { echo "FAIL: SNI mini library does not match full library ($mini_count vs $sni_count)"; failures=$((failures + 1)); }
    else
        echo 'SELF_TEST_NOTE: SNI candidate integration test skipped (no adjacent database/cache; this skipped test uses no network)' >&2
    fi
    declare -f asn_lookup_ip >/dev/null || { echo 'FAIL: ASN lookup function missing'; failures=$((failures + 1)); }
    declare -f sni_org_cdn_penalty >/dev/null || { echo 'FAIL: ASN/CDN scoring function missing'; failures=$((failures + 1)); }
    [[ "$(tr_msg confirm_local_sni_full)" != *'远程执行第三方脚本'* ]] || { echo 'FAIL: local SNI prompt still says remote third-party'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_non443_warn)' "$source_body_file" || { echo 'FAIL: English non-443 SNI warning translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:apple_sni_warn)' "$source_body_file" || { echo 'FAIL: English Apple/iCloud SNI warning translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_title)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_title translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_cannot)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_cannot translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_mihomo)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_mihomo translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_ok)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_ok translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_xhttp)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_xhttp translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_unverified)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_unverified translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:reality_mlkem_notice_mihomo_trojan)' "$source_body_file" || { echo 'FAIL: English REALITY notice reality_mlkem_notice_mihomo_trojan translation missing'; failures=$((failures + 1)); }
    grep -Fq 'en:we_old_quota)' "$source_body_file" || { echo 'FAIL: English write_env we_old_quota translation missing'; failures=$((failures + 1)); }
    declare -F sni_domain_public_dns >/dev/null 2>&1 || { echo 'FAIL: SNI public-DNS guard missing'; failures=$((failures + 1)); }
    grep -Fq '__abox_missing_pkg_for "$release" groupadd passwd shadow-utils shadow' "$source_body_file" || { echo 'FAIL: group management dependency mapping missing'; failures=$((failures + 1)); }
    grep -Fq '__abox_missing_pkg_for "$release" useradd passwd shadow-utils shadow' "$source_body_file" || { echo 'FAIL: user management dependency mapping missing'; failures=$((failures + 1)); }
    grep -Fq 'addgroup -S "$group"' "$source_body_file" || { echo 'FAIL: Alpine BusyBox addgroup fallback missing'; failures=$((failures + 1)); }
    grep -Fq 'adduser -S -D -H -s /sbin/nologin -G "$group" "$user"' "$source_body_file" || { echo 'FAIL: Alpine BusyBox adduser fallback missing'; failures=$((failures + 1)); }
    assert_ok valid_ipv4_cidr 192.0.2.1/24
    assert_bad valid_ipv4_cidr 001.002.003.004/24
    assert_bad valid_ip_address 001.002.003.004
    assert_bad valid_ipv4_cidr 999.0.2.1/24
    assert_bad valid_ipv4_cidr 192.0.2.1/999999999999999999999999999
    assert_bad valid_ipv4_cidr 192.0.2.999999999999999999999999/24
    assert_bad valid_ipv4_cidr '192.0.2.1/'
    assert_ok valid_ip_address 192.0.2.1
    assert_bad valid_ip_address 192.0.2.1/24
    if selftest_has python3; then
        getent() { printf '%s\n' '1.1.1.1 STREAM example.com'; }
        # N-05: resolve_domain_addresses wraps getent in `timeout`; mock timeout as passthrough.
        timeout() { shift; "$@"; }
        assert_ok sni_domain_public_dns example.com
        getent() { printf '%s\n' '10.0.0.1 STREAM example.com'; }
        assert_bad sni_domain_public_dns example.com
        getent() {
            case "${1:-}" in
                ahosts) return 2 ;;
                hosts) printf '%s\n' '1.1.1.1 example.com' ;;
                *) return 1 ;;
            esac
        }
        [[ "$(resolve_domain_addresses example.com)" == '1.1.1.1' ]] || { echo 'FAIL: DNS resolver must fall back from getent ahosts to getent hosts'; failures=$((failures + 1)); }
        unset -f getent timeout
        assert_ok valid_public_ip 1.1.1.1
        assert_bad valid_public_ip 224.0.0.1
        assert_bad valid_public_ip 239.255.255.255
        assert_bad valid_public_ip 192.88.99.1
        assert_bad valid_public_ip 64:ff9b::8.8.8.8
        assert_bad valid_public_ip ::ffff:8.8.8.8
        assert_ok valid_public_ip 2606:4700:4700::1111
        assert_bad valid_public_ip 10.0.0.1
        assert_bad valid_public_ip 192.168.1.1
        assert_bad valid_public_ip 172.16.0.1
        assert_bad valid_public_ip 100.64.0.1
        assert_bad valid_public_ip 127.0.0.1
        assert_bad valid_public_ip 169.254.1.1
        assert_bad valid_public_ip 198.51.100.1
        assert_bad valid_public_ip fc00::1
        assert_bad valid_public_ip fe80::1
        assert_bad valid_public_ip ::1
        assert_bad valid_public_ip 2001:db8::1
        assert_ok valid_ipv6_cidr 2001:db8::1/64
        assert_bad valid_ipv6_cidr 2001:::1/64
        assert_bad valid_ipv6_cidr 2001:db8::1/999999999999999999999999999
        assert_bad valid_ipv6_cidr '2001:db8::1/'
        # R12C5-02: /0 is a legal prefix (WireGuard itself uses ::/0
        # as allow-all); the old assert_bad encoded the rejected behavior.
        assert_ok valid_ipv6_cidr ::/0
        assert_ok valid_ipv6_cidr 2001:db8::/0
        assert_ok valid_ip_address 2001:db8::1
        assert_bad valid_ip_address 2001:db8::1/64
    else
        selftest_note 'public-IP / IPv6 / SNI DNS validator tests skipped (python3 missing)'
    fi
    declare -F backup_current_config >/dev/null 2>&1 || { echo 'FAIL: backup_current_config missing'; failures=$((failures + 1)); }
    declare -F export_diagnostic_bundle >/dev/null 2>&1 || { echo 'FAIL: export_diagnostic_bundle missing'; failures=$((failures + 1)); }
    grep -Fq 'refusing to report a false Saved state' "$source_body_file" || { echo 'FAIL: SNI persistence must fail closed'; failures=$((failures + 1)); }
    grep -Fq 'Diagnostic bundle checksum generation failed' "$source_body_file" || { echo 'FAIL: diagnostic checksum failures must be blocking'; failures=$((failures + 1)); }
    declare -F write_diagnostic_checksum >/dev/null 2>&1 || { echo 'FAIL: diagnostic checksum helper missing'; failures=$((failures + 1)); }
    bash -n "$0" >/dev/null 2>&1 || { echo 'FAIL: installer source must pass bash -n'; failures=$((failures + 1)); }
    declare -F confirm_remote_script_hash >/dev/null 2>&1 || { echo 'FAIL: remote script hash gate missing'; failures=$((failures + 1)); }
    declare -F confirm_ota_script_hash >/dev/null 2>&1 || { echo 'FAIL: OTA hash gate missing'; failures=$((failures + 1)); }
    declare -F validate_ota_version_direction >/dev/null 2>&1 || { echo 'FAIL: OTA anti-downgrade gate missing'; failures=$((failures + 1)); }
    declare -F install_deployment_transaction_traps >/dev/null 2>&1 || { echo 'FAIL: deployment signal traps missing'; failures=$((failures + 1)); }
    declare -F install_core_upgrade_transaction_traps >/dev/null 2>&1 || { echo 'FAIL: core-upgrade signal traps missing'; failures=$((failures + 1)); }
    declare -F convert_legacy_backup_archive >/dev/null 2>&1 || { echo 'FAIL: legacy backup converter missing'; failures=$((failures + 1)); }
    declare -F record_core_family_ownership >/dev/null 2>&1 || { echo 'FAIL: per-file core ownership missing'; failures=$((failures + 1)); }
    declare -F refresh_dynamic_core_subtree_ownership >/dev/null 2>&1 || { echo 'FAIL: dynamic ACME ownership refresh missing'; failures=$((failures + 1)); }
    declare -F prepare_hysteria_acme_dir_ownership >/dev/null 2>&1 || { echo 'FAIL: Hysteria ACME ownership preparation missing'; failures=$((failures + 1)); }
    grep -q 'refresh_dynamic_core_subtree_ownership hysteria /etc/hysteria/acme' "$source_body_file" || { echo 'FAIL: Hysteria cleanup does not refresh dynamic ACME ownership'; failures=$((failures + 1)); }
    grep -q 'A-Box managed Hysteria ACME directory v1' "$source_body_file" || { echo 'FAIL: Hysteria ACME ownership marker missing'; failures=$((failures + 1)); }
    grep -q 'prepare_hysteria_acme_dir_ownership' "$source_body_file" || { echo 'FAIL: Hysteria ACME ownership gate missing'; failures=$((failures + 1)); }
    grep -q 'prepare_hysteria_acme_dir_ownership || return 1' "$source_body_file" || { echo 'FAIL: Hysteria cleanup legacy ownership migration gate missing'; failures=$((failures + 1)); }
    declare -F validate_abox_cron_file >/dev/null 2>&1 || { echo 'FAIL: cron semantic validator missing'; failures=$((failures + 1)); }
    _managed_paths_fixture="$tmp/all-managed-paths.txt"
    _saved_init_for_paths="${INIT_SYS:-}"
    INIT_SYS=systemd
    { managed_auxiliary_paths; for _srv in xray sing-box hysteria; do core_family_paths "$_srv" || exit 1; done; } | awk 'NF && !seen[$0]++' > "$_managed_paths_fixture" || { echo 'FAIL: authoritative managed-path enumeration'; failures=$((failures + 1)); }
    if selftest_has python3; then
        validate_managed_paths_file "$_managed_paths_fixture" || { echo 'FAIL: full managed-path set must pass recovery whitelist validation'; failures=$((failures + 1)); }
        grep -Fxq '/etc/modules-load.d/A-Box-bbr.conf' "$_managed_paths_fixture" || { echo 'FAIL: BBR managed path missing from authoritative test set'; failures=$((failures + 1)); }
        printf '%s\n' '/etc/A-Box-selftest-unmanaged-path' >> "$_managed_paths_fixture"
        if validate_managed_paths_file "$_managed_paths_fixture"; then echo 'FAIL: unmanaged recovery path accepted'; failures=$((failures + 1)); fi
    else
        selftest_note 'managed-path whitelist validation skipped (python3 missing)'
        grep -Fxq '/etc/modules-load.d/A-Box-bbr.conf' "$_managed_paths_fixture" || { echo 'FAIL: BBR managed path missing from authoritative test set'; failures=$((failures + 1)); }
    fi
    INIT_SYS="$_saved_init_for_paths"
    unset _saved_init_for_paths
    [[ "$ABOX_BUILD_EPOCH" =~ ^[0-9]+$ ]] || { echo 'FAIL: numeric build epoch missing'; failures=$((failures + 1)); }
    declare -F remove_ss_open_accept_rules >/dev/null 2>&1 || { echo 'FAIL: SS open ACCEPT cleanup missing'; failures=$((failures + 1)); }
    declare -F show_sni_preference_records >/dev/null 2>&1 || { echo 'FAIL: SNI record viewer missing'; failures=$((failures + 1)); }
    declare -F validate_abox_script_file >/dev/null 2>&1 || { echo 'FAIL: local script validation gate missing'; failures=$((failures + 1)); }
    declare -F install_remote_abox_script_guarded >/dev/null 2>&1 || { echo 'FAIL: guarded remote shortcut installer missing'; failures=$((failures + 1)); }
    declare -F validate_fail2ban_config >/dev/null 2>&1 || { echo 'FAIL: fail2ban validation gate missing'; failures=$((failures + 1)); }
    declare -F ensure_vnstat_runtime >/dev/null 2>&1 || { echo 'FAIL: vnStat runtime gate missing'; failures=$((failures + 1)); }
    declare -F validate_abox_env_file_for_write >/dev/null 2>&1 || { echo 'FAIL: A-Box env ownership validator missing'; failures=$((failures + 1)); }
    declare -F remove_owned_runtime_helper >/dev/null 2>&1 || { echo 'FAIL: runtime helper ownership remover missing'; failures=$((failures + 1)); }
    grep -Fxq '# Managed by A-Box' <(printf '%s\n' '# Managed by A-Box') || { echo 'FAIL: self-test process substitution'; failures=$((failures + 1)); }
    printf '%s\n' '# Managed by A-Box' 'TRAFFIC_LIMIT_GB' 'month_bytes() {}' > "$tmp/traffic_monitor.sh"
    auxiliary_content_is_abox_managed "$tmp/traffic_monitor.sh" /etc/ddr/traffic_monitor.sh || { echo 'FAIL: managed traffic helper ownership'; failures=$((failures + 1)); }
    printf '%s\n' '# foreign' 'TRAFFIC_LIMIT_GB' 'month_bytes() {}' > "$tmp/foreign-traffic.sh"
    ! auxiliary_content_is_abox_managed "$tmp/foreign-traffic.sh" /etc/ddr/traffic_monitor.sh || { echo 'FAIL: foreign traffic helper accepted as managed'; failures=$((failures + 1)); }
    if (( EUID == 0 )); then
        printf '%s\n' '# Managed by A-Box' > "$tmp/A-Box-firewall.service"
        auxiliary_content_is_abox_managed "$tmp/A-Box-firewall.service" /etc/systemd/system/A-Box-firewall.service || { echo 'FAIL: A-Box firewall service ownership marker'; failures=$((failures + 1)); }
        printf '%s\n' '# foreign' > "$tmp/foreign-firewall.service"
        ! auxiliary_content_is_abox_managed "$tmp/foreign-firewall.service" /etc/systemd/system/A-Box-firewall.service || { echo 'FAIL: foreign firewall service accepted as managed'; failures=$((failures + 1)); }
    fi
    grep -Fq 'User=abox-xray' "$source_body_file" || { echo 'FAIL: Xray systemd unit must drop root UID'; failures=$((failures + 1)); }
    grep -Fq 'command_user="abox-xray:abox-xray"' "$source_body_file" || { echo 'FAIL: Xray OpenRC service must drop root UID'; failures=$((failures + 1)); }
    grep -Fq 'capabilities="${HY2_RC_CAPS}"' "$source_body_file" || { echo 'FAIL: Hysteria OpenRC capabilities missing'; failures=$((failures + 1)); }
    grep -Fq 'write_file_atomically_from_stdin /etc/init.d/hysteria 755 <<EOF_SVC' "$source_body_file" || { echo 'FAIL: Hysteria OpenRC capabilities heredoc must expand deployment-time value'; failures=$((failures + 1)); }
    # 11 real sites (U35 fix; C2: was 13, the retired xray-latest block
    # held 2); source snapshot excludes this assertion line itself.
    [[ "$(grep -Fc 'capabilities="^cap_net_bind_service"' "$source_body_file")" -ge 11 ]] || { echo 'FAIL: Xray/sing-box OpenRC capabilities missing'; failures=$((failures + 1)); }
    grep -Fq 'User=abox-singbox' "$source_body_file" || { echo 'FAIL: sing-box systemd unit must drop root UID'; failures=$((failures + 1)); }
    grep -Fq 'command_user="abox-singbox:abox-singbox"' "$source_body_file" || { echo 'FAIL: sing-box OpenRC service must drop root UID'; failures=$((failures + 1)); }
    grep -Fq 'User=abox-hysteria' "$source_body_file" || { echo 'FAIL: Hysteria systemd unit must drop root UID'; failures=$((failures + 1)); }
    grep -Fq 'command_user="abox-hysteria:abox-hysteria"' "$source_body_file" || { echo 'FAIL: Hysteria OpenRC service must drop root UID'; failures=$((failures + 1)); }
    grep -Fq "ABOX_HYSTERIA_DEFAULT_VERSION='app/v2.14.0'" "$source_body_file" || { echo 'FAIL: Hysteria compatibility pin missing'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_TRY_LATEST_CORE_STABLE:-0' "$source_body_file" || { echo 'FAIL: try-latest danger path must stay opt-in (pinned-policy latest override)'; failures=$((failures + 1)); }
    grep -Fq 'sni_probe_candidate_tier() {' "$source_body_file" || { echo 'FAIL: custom REALITY SNI probe helper missing'; failures=$((failures + 1)); }
    grep -Fq 'custom_tier=$(sni_probe_candidate_tier "$input"' "$source_body_file" || { echo 'FAIL: custom REALITY SNI must be re-probed before acceptance'; failures=$((failures + 1)); }
    grep -Fq 'core_latest_stable_release_ref() {' "$source_body_file" || { echo 'FAIL: dynamic stable Release resolver missing'; failures=$((failures + 1)); }
    grep -Fq "ABOX_SINGBOX_DEFAULT_VERSION='v1.14.4'" "$source_body_file" || { echo 'FAIL: sing-box stable pin missing'; failures=$((failures + 1)); }
    grep -Fq 'core_fetch_upstream_release_asset() {' "$source_body_file" || { echo 'FAIL: upstream-first fetch state machine missing'; failures=$((failures + 1)); }
    [[ "$(awk '/^# Operations helpers$/ { exit } /^core_fetch_upstream_release_asset\(\) \{/ { count++ } END { print count+0 }' "$0")" == '1' ]] || { echo 'FAIL: core asset fetcher must have exactly one live implementation'; failures=$((failures + 1)); }
    # F-06 fix: default-value assertions must not fail when the user legally
    # overrides via environment. Isolate in a subshell with overrides unset.
    # E-2: PROBE_SKIP=1 prevents failure when host has newer Xray installed.
    # C2 (Q7): the effective version is a fallback value when the version
    # is unparsed/unprobed, not a policy default. Fixed inputs only.
    ( unset ABOX_XRAY_VERSION ABOX_RESOLVED_XRAY_VERSION; ABOX_XRAY_VERSION_PROBE_SKIP=1
      [[ "$(effective_xray_version)" == "$ABOX_XRAY_DEFAULT_VERSION" ]] ) || { echo 'FAIL: effective Xray version fallback value when unparsed/unprobed'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.7.28 ABOX_XRAY_VERSION_PROBE_SKIP=1
      [[ "$(effective_xray_version)" == 'v26.7.28' ]] ) || { echo 'FAIL: explicit Xray version must be honored by effective_xray_version'; failures=$((failures + 1)); }
    (
        unset ABOX_XRAY_VERSION ABOX_TRY_LATEST_CORE_STABLE ABOX_XRAY_UPDATE_POLICY
        ABOX_RESOLVED_XRAY_VERSION=''; ABOX_RESOLVED_XRAY_SOURCE=''
        core_latest_stable_release_ref() { printf '%s\n' 'v26.11.9'; }
        core_latest_mirror_release_ref() { printf '%s\n' 'v26.7.28'; }
        resolve_core_release_target XTLS/Xray-core || exit 1
        [[ "$ABOX_RESOLVED_XRAY_VERSION|$ABOX_RESOLVED_XRAY_SOURCE" == 'v26.11.9|upstream' ]]
    ) || { echo 'FAIL: routine core resolver must follow the latest stable Xray release'; failures=$((failures + 1)); }
    (
        unset ABOX_SINGBOX_VERSION ABOX_SINGBOX_UPDATE_POLICY ABOX_TRY_LATEST_CORE_STABLE
        ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE=''
        core_latest_stable_release_ref() { return 3; }
        core_latest_mirror_release_ref() { printf '%s\n' 'v1.14.4'; }
        resolve_core_release_target SagerNet/sing-box || exit 1
        [[ "$ABOX_RESOLVED_SINGBOX_VERSION|$ABOX_RESOLVED_SINGBOX_SOURCE" == 'v1.14.4|mirror-latest' ]]
    ) || { echo 'FAIL: ordinary no-candidate path must fall back to mirror-latest'; failures=$((failures + 1)); }
    (
        unset ABOX_HYSTERIA_APP_VERSION
        ABOX_TRY_LATEST_CORE_STABLE=1
        ABOX_HYSTERIA_UPDATE_POLICY='pinned'
        ABOX_RESOLVED_HYSTERIA_VERSION=''; ABOX_RESOLVED_HYSTERIA_SOURCE=''
        core_latest_stable_release_ref() { printf '%s\n' 'app/v2.14.0'; }
        core_latest_mirror_release_ref() { printf '%s\n' 'app/v2.14.0'; }
        resolve_core_release_target HyNetworks/hysteria || exit 1
        [[ "$ABOX_RESOLVED_HYSTERIA_VERSION|$ABOX_RESOLVED_HYSTERIA_SOURCE" == 'app/v2.14.0|upstream' ]]
    ) || { echo 'FAIL: TRY_LATEST must override pinned policy'; failures=$((failures + 1)); }
    (
        ABOX_SINGBOX_VERSION='v1.14.2'
        ABOX_TRY_LATEST_CORE_STABLE=1
        ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE=''
        resolve_core_release_target SagerNet/sing-box || exit 1
        [[ "$ABOX_RESOLVED_SINGBOX_VERSION|$ABOX_RESOLVED_SINGBOX_SOURCE" == 'v1.14.2|explicit' ]]
    ) || { echo 'FAIL: explicit version must win over TRY_LATEST'; failures=$((failures + 1)); }
    (
        unset ABOX_XRAY_VERSION ABOX_TRY_LATEST_CORE_STABLE
        ABOX_XRAY_UPDATE_POLICY='pinned'
        ABOX_RESOLVED_XRAY_VERSION=''; ABOX_RESOLVED_XRAY_SOURCE=''
        resolve_core_release_target XTLS/Xray-core || exit 1
        [[ "$ABOX_RESOLVED_XRAY_VERSION|$ABOX_RESOLVED_XRAY_SOURCE" == 'v26.11.9|pinned' ]]
    ) || { echo 'FAIL: pinned policy without TRY_LATEST must use the pin'; failures=$((failures + 1)); }
    (
        unset ABOX_SINGBOX_VERSION ABOX_SINGBOX_UPDATE_POLICY ABOX_TRY_LATEST_CORE_STABLE
        ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE=''
        core_latest_stable_release_ref() { return 2; }
        core_latest_mirror_release_ref() { printf '%s\n' 'v9.9.9-rc.1'; }
        ! resolve_core_release_target SagerNet/sing-box
    ) || { echo 'FAIL: invalid mirror candidate must fail the resolve'; failures=$((failures + 1)); }
    (
        unset ABOX_SINGBOX_VERSION
        ABOX_TRY_LATEST_CORE_STABLE=1
        ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE=''
        core_latest_stable_release_ref() { printf '%s\n' 'v1.14.4'; }
        resolve_core_release_target SagerNet/sing-box || exit 1
        [[ "$ABOX_RESOLVED_SINGBOX_VERSION|$ABOX_RESOLVED_SINGBOX_SOURCE" == 'v1.14.4|upstream' ]]
    ) || { echo 'FAIL: explicit latest action must select stable upstream candidate'; failures=$((failures + 1)); }
    local mock_release_json=''
    mock_release_json='[{"tag_name":"v1.17.0-rc.1","draft":false,"prerelease":true,"published_at":"2026-10-12T06:13:25Z"},{"tag_name":"v1.14.2","draft":false,"prerelease":false,"published_at":"2026-10-10T11:47:08Z"},{"tag_name":"v1.14.3","draft":false,"prerelease":false,"published_at":"2026-10-09T05:35:00Z"},{"tag_name":"v1.15.0","draft":false,"prerelease":false,"published_at":"2026-09-01T00:00:00Z"},{"tag_name":"v1.16.0","draft":true,"prerelease":false,"published_at":"2026-10-13T00:00:00Z"}]'
    [[ "$(core_latest_stable_tag_from_json SagerNet/sing-box "$mock_release_json")" == 'v1.15.0' ]] || { echo 'FAIL: stable resolver must use semantic version order and exclude prerelease/draft'; failures=$((failures + 1)); }
    mock_release_json='[{"tag_name":"app/v2.14.0-rc.1","draft":false,"prerelease":true,"published_at":"2026-10-12T00:00:00Z"},{"tag_name":"app/v2.13.0","draft":false,"prerelease":false,"published_at":"2026-10-05T00:00:00Z"},{"tag_name":"app/v2.12.5","draft":false,"prerelease":false,"published_at":"2026-10-11T00:00:00Z"}]'
    [[ "$(core_latest_stable_tag_from_json HyNetworks/hysteria "$mock_release_json")" == 'app/v2.13.0' ]] || { echo 'FAIL: Hysteria stable resolver must use semantic version order'; failures=$((failures + 1)); }
    core_binary_matches_release_ref 'v26.7.28' 'Xray 26.7.28 (Xray, Penetrates Everything.)' || { echo 'FAIL: Xray binary/tag identity'; failures=$((failures + 1)); }
    core_binary_matches_release_ref 'v1.14.3' 'sing-box version 1.14.3' || { echo 'FAIL: sing-box binary/tag identity'; failures=$((failures + 1)); }
    core_binary_matches_release_ref 'app/v2.13.0' 'Hysteria version v2.13.0' || { echo 'FAIL: Hysteria binary/tag identity'; failures=$((failures + 1)); }
    core_binary_matches_release_ref 'v1.14.3' 'sing-box version 1.14.2' && { echo 'FAIL: mismatched binary/tag identity accepted'; failures=$((failures + 1)); }
    [[ "$(core_release_mirror_version SagerNet/sing-box)" == "$ABOX_SINGBOX_MIRROR_VERSION" ]] || { echo 'FAIL: recovery pin resolver'; failures=$((failures + 1)); }
    [[ "$(core_release_mirror_version XTLS/Xray-core)" == 'v26.11.9' ]] || { echo 'FAIL: Xray mirror pin value must be v26.11.9'; failures=$((failures + 1)); }
    local mock_core_versions=$'schema=1\nXray=v26.3.27\nsing-box=v1.14.3\nHysteria=app/v2.13.0'
    [[ "$(core_latest_mirror_tag_from_text XTLS/Xray-core "$mock_core_versions")" == 'v26.3.27' ]] || { echo 'FAIL: latest Xray mirror metadata parser'; failures=$((failures + 1)); }
    awk '/^run_self_tests\(\) \{/ { exit } /curl -fLsS --proto =https --proto-redir =https --retry 2 --retry-delay 2 --connect-timeout 8 -m 30 "\$mirror_sum" -o "\$sum_file"/ { found=1 } END { exit !found }' "$0" || { echo 'FAIL: mirror checksum download must follow GitHub release redirects'; failures=$((failures + 1)); }
    [[ "$(core_latest_mirror_tag_from_text SagerNet/sing-box "$mock_core_versions")" == 'v1.14.3' ]] || { echo 'FAIL: latest sing-box mirror metadata parser'; failures=$((failures + 1)); }
    [[ "$(core_latest_mirror_tag_from_text HyNetworks/hysteria "$mock_core_versions")" == 'app/v2.13.0' ]] || { echo 'FAIL: latest Hysteria mirror metadata parser'; failures=$((failures + 1)); }
    if core_latest_mirror_tag_from_text XTLS/Xray-core $'Xray=v26.7.28-rc.1'; then echo 'FAIL: prerelease mirror metadata accepted as latest stable'; failures=$((failures + 1)); fi
    ( XRAY_ARCH=64; [[ "$(core_mirror_asset_leaf XTLS/Xray-core xray_core.zip v26.3.27)" == 'Xray-v26.3.27-linux-64.zip' ]] ) || { echo 'FAIL: versioned Xray mirror asset naming'; failures=$((failures + 1)); }
    ( XRAY_ARCH=64; [[ "$(core_mirror_asset_leaf XTLS/Xray-core xray_core.zip v26.7.28 1)" == 'Xray-v26.7.28-linux-64.zip' ]] ) || { echo 'FAIL: non-pin Xray mirror should use versioned asset name with prefer set to 1'; failures=$((failures + 1)); }
    ( XRAY_ARCH=64; [[ "$(core_mirror_asset_leaf XTLS/Xray-core xray_core.zip "$ABOX_XRAY_MIRROR_VERSION" 1)" == "Xray-$ABOX_XRAY_MIRROR_VERSION-linux-64.zip" ]] ) || { echo 'FAIL: pinned Xray mirror should prefer versioned asset even when tag matches pin'; failures=$((failures + 1)); }
    ( XRAY_ARCH=64; [[ "$(core_mirror_asset_leaf XTLS/Xray-core xray_core.zip "$ABOX_XRAY_MIRROR_VERSION")" == 'Xray-linux-64.zip' ]] ) || { echo 'FAIL: pinned Xray mirror should use fixed asset name when version matches pin'; failures=$((failures + 1)); }
    ( XRAY_ARCH=64; [[ "$(core_mirror_asset_leaf XTLS/Xray-core xray_core.zip "$ABOX_XRAY_MIRROR_VERSION" 0)" == 'Xray-linux-64.zip' ]] ) || { echo 'FAIL: pinned Xray mirror should use fixed asset name when prefer is 0'; failures=$((failures + 1)); }
    ( release=alpine; SB_ARCH=amd64; [[ "$(core_mirror_asset_leaf SagerNet/sing-box singbox_core.tar.gz v1.14.3)" == 'sing-box-1.14.3-linux-amd64-musl.tar.gz' ]] ) || { echo 'FAIL: versioned sing-box musl mirror asset naming'; failures=$((failures + 1)); }
    ( HY2_ARCH=arm64; [[ "$(core_mirror_asset_leaf HyNetworks/hysteria hysteria_core "$ABOX_HYSTERIA_MIRROR_VERSION" 1)" == 'hysteria-app-v2.14.0-linux-arm64' ]] ) || { echo 'FAIL: pinned Hysteria mirror should prefer versioned asset even when tag matches pin'; failures=$((failures + 1)); }
    ( HY2_ARCH=arm64; [[ "$(core_mirror_asset_leaf HyNetworks/hysteria hysteria_core "$ABOX_HYSTERIA_MIRROR_VERSION")" == 'hysteria-linux-arm64' ]] ) || { echo 'FAIL: pinned Hysteria mirror should use fixed asset name when version matches pin'; failures=$((failures + 1)); }
    ( HY2_ARCH=arm64; [[ "$(core_mirror_asset_leaf HyNetworks/hysteria hysteria_core "$ABOX_HYSTERIA_MIRROR_VERSION" 0)" == 'hysteria-linux-arm64' ]] ) || { echo 'FAIL: pinned Hysteria mirror should use fixed asset name when prefer is 0'; failures=$((failures + 1)); }
    ( HY2_ARCH=arm64; [[ "$(core_mirror_asset_leaf HyNetworks/hysteria hysteria_core app/v2.12.5)" == 'hysteria-app-v2.12.5-linux-arm64' ]] ) || { echo 'FAIL: non-pin Hysteria mirror should use versioned asset name when version does not match pin'; failures=$((failures + 1)); }
    ( HY2_ARCH=arm64; [[ "$(core_mirror_asset_leaf HyNetworks/hysteria hysteria_core app/v2.12.5 1)" == 'hysteria-app-v2.12.5-linux-arm64' ]] ) || { echo 'FAIL: non-pin Hysteria mirror should use versioned asset name with prefer set to 1'; failures=$((failures + 1)); }
    ( ABOX_RESOLVED_XRAY_VERSION=''; ABOX_RESOLVED_XRAY_SOURCE=''; core_set_resolved_target XTLS/Xray-core v26.3.27 mirror-exact && [[ "$ABOX_RESOLVED_XRAY_VERSION|$ABOX_RESOLVED_XRAY_SOURCE" == 'v26.3.27|mirror-exact' ]] ) || { echo 'FAIL: exact-tag mirror source must preserve the requested version'; failures=$((failures + 1)); }
    ( unset ABOX_SINGBOX_VERSION; ABOX_TRY_LATEST_CORE_STABLE=1; ABOX_RESOLVED_SINGBOX_VERSION=''; ABOX_RESOLVED_SINGBOX_SOURCE=''; core_latest_stable_release_ref() { return 2; }; core_latest_mirror_release_ref() { printf '%s\n' 'v1.14.4'; }; resolve_core_release_target SagerNet/sing-box || exit 1; [[ "$ABOX_RESOLVED_SINGBOX_VERSION|$ABOX_RESOLVED_SINGBOX_SOURCE" == 'v1.14.4|mirror-latest' ]] ) || { echo 'FAIL: latest mirror metadata must be used when upstream API fails'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.9.8 xray_reality_requires_mlkem ) || { echo 'FAIL: Xray 26.9.8 must require REALITY ML-KEM'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.7.28 xray_reality_requires_mlkem ) && { echo 'FAIL: Xray 26.7.28 must not require REALITY ML-KEM'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.9.8-rc.1 xray_reality_requires_mlkem ) && { echo 'FAIL: Xray 26.9.8 prerelease must not require REALITY ML-KEM'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.9.9-rc.1 xray_reality_requires_mlkem ) || { echo 'FAIL: Xray 26.9.9 prerelease must require REALITY ML-KEM'; failures=$((failures + 1)); }
    ( ABOX_XRAY_VERSION=v26.9 xray_reality_requires_mlkem ) >/dev/null 2>&1 && { echo 'FAIL: malformed Xray version accepted'; failures=$((failures + 1)); }
    grep -Fq 'support-x25519mlkem768: $clash_mlkem' "$source_body_file" || { echo 'FAIL: Clash REALITY ML-KEM flag must be version-aware'; failures=$((failures + 1)); }
    grep -Fq 'HyNetworks/hysteria) override="${ABOX_HYSTERIA_APP_VERSION:-}"; default_ref="$ABOX_HYSTERIA_DEFAULT_VERSION"' "$source_body_file" || { echo 'FAIL: Hysteria v2.14.0 compatibility pin missing'; failures=$((failures + 1)); }
    # F-06 fix: isolate policy default assertions from user env overrides.
    ( unset ABOX_XRAY_UPDATE_POLICY ABOX_SINGBOX_UPDATE_POLICY ABOX_HYSTERIA_UPDATE_POLICY
      [[ "$(core_update_policy XTLS/Xray-core)" == 'auto-stable' ]] ) || { echo 'FAIL: Xray update policy must default to auto-stable'; failures=$((failures + 1)); }
    ( unset ABOX_XRAY_UPDATE_POLICY ABOX_SINGBOX_UPDATE_POLICY ABOX_HYSTERIA_UPDATE_POLICY
      [[ "$(core_update_policy SagerNet/sing-box)" == 'auto-stable' ]] ) || { echo 'FAIL: sing-box update policy must default to auto-stable'; failures=$((failures + 1)); }
    ( unset ABOX_XRAY_UPDATE_POLICY ABOX_SINGBOX_UPDATE_POLICY ABOX_HYSTERIA_UPDATE_POLICY
      [[ "$(core_update_policy HyNetworks/hysteria)" == 'auto-stable' ]] ) || { echo 'FAIL: Hysteria update policy must default to auto-stable'; failures=$((failures + 1)); }
    ( ABOX_XRAY_UPDATE_POLICY='auto-stable'; [[ "$(core_update_policy XTLS/Xray-core)" == 'auto-stable' ]] ) || { echo 'FAIL: Xray policy override not honored'; failures=$((failures + 1)); }
    ( ABOX_XRAY_UPDATE_POLICY='pinned'; [[ "$(core_update_policy XTLS/Xray-core)" == 'pinned' ]] ) || { echo 'FAIL: Xray pinned policy override not honored'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_XRAY_UPDATE_POLICY="${ABOX_XRAY_UPDATE_POLICY:-auto-stable}"' "$source_body_file" || { echo 'FAIL: Xray update policy init must default to auto-stable'; failures=$((failures + 1)); }
    # C4 (2026-11-10, no-cooling policy): the cooldown helpers are retired;
    # the resolver must no longer define them, and no cooldown variable
    # may remain in the source.
    ! declare -F core_cooldown_allows_age >/dev/null 2>&1 || { echo 'FAIL: retired cooldown helper still exists'; failures=$((failures + 1)); }
    ! declare -F core_stable_release_age_days >/dev/null 2>&1 || { echo 'FAIL: retired release-age helper still exists'; failures=$((failures + 1)); }
    ! grep -Fq 'ABOX_STABLE_COOLDOWN_DAYS' "$source_body_file" || { echo 'FAIL: retired cooldown variable still present'; failures=$((failures + 1)); }

    (
        [[ "$ABOX_BUILD" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9][A-Za-z0-9-]*-v[0-9]+$ ]] || exit 1
        _build_date="${ABOX_BUILD:0:10}"
        _build_date="${_build_date//-/}"
        _build_revision="${ABOX_BUILD##*-v}"
        [[ "$ABOX_BUILD_EPOCH" =~ ^[0-9]+$ ]] || exit 1
        [[ "$ABOX_BUILD_EPOCH" == "${_build_date}${_build_revision}" ]]
    ) || {
        echo 'FAIL: build metadata format or epoch mismatch'
        failures=$((failures + 1))
    }
    grep -Fq 'IP_PREF_FILE=' "$source_body_file" || { echo 'FAIL: IP preference state file missing'; failures=$((failures + 1)); }
    grep -Fq 'ip_preference_menu()' "$source_body_file" || { echo 'FAIL: IP preference menu missing'; failures=$((failures + 1)); }
    grep -Fq 'dns_menu()' "$source_body_file" || { echo 'FAIL: DNS menu missing'; failures=$((failures + 1)); }
    grep -Fq 'dns_auto_prefer()' "$source_body_file" || { echo 'FAIL: DNS auto benchmark missing'; failures=$((failures + 1)); }
    grep -Fq 'dns_enable_doh()' "$source_body_file" || { echo 'FAIL: DoH implementation missing'; failures=$((failures + 1)); }
    grep -Fq 'timezone_choose_from_list()' "$source_body_file" || { echo 'FAIL: numbered timezone selector missing'; failures=$((failures + 1)); }
    grep -Fq 'run_mirrored_test_script()' "$source_body_file" || { echo 'FAIL: test-script disaster fallback missing'; failures=$((failures + 1)); }
    grep -Fq 'wallos_install_or_update()' "$source_body_file" || { echo 'FAIL: Wallos installer missing'; failures=$((failures + 1)); }
    grep -Fq 'timezone_menu()' "$source_body_file" || { echo 'FAIL: timezone menu missing'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_CORE_MIRROR_BASE_DEFAULT=' "$source_body_file" || { echo 'FAIL: core disaster mirror base missing'; failures=$((failures + 1)); }
    grep -Fq "ABOX_CORE_MIRROR_RELEASE='core-binaries'" "$source_body_file" || { echo 'FAIL: stable core mirror tag missing'; failures=$((failures + 1)); }
    grep -Fq "ABOX_CORE_MIRROR_BASE_DEFAULT='https://github.com/alariclin/A-Box/releases/download/core-binaries'" "$source_body_file" || { echo 'FAIL: stable core mirror URL missing'; failures=$((failures + 1)); }
    declare -F fetch_util_mirror_asset >/dev/null 2>&1 || { echo 'FAIL: pinned-utility mirror fetch missing'; failures=$((failures + 1)); }
    # wgcf latest-tracking: the resolver binds one release (version + digest).
    _wgcf_api_json='{"tag_name":"v2.3.1","draft":false,"prerelease":false,"assets":[{"name":"wgcf_2.3.1_linux_amd64","digest":"sha256:4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8"},{"name":"wgcf_2.3.1_linux_arm64","digest":"sha256:710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301"},{"name":"checksums.txt","digest":"sha256:15ab012ba30009ca2183483b246fc3b805318a91be9f35db89dfd85e7ca635ad"}]}'
    _wgcf_sums='4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8  wgcf_2.3.1_linux_amd64
710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301  wgcf_2.3.1_linux_arm64'
    ( github_api_get() { printf '%s' "$_wgcf_api_json"; }
      [[ "$(wgcf_resolve_latest amd64)" == '2.3.1 sha256:4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8' ]] ) || { echo 'FAIL: wgcf resolver API-digest path'; failures=$((failures + 1)); }
    ( github_api_get() { printf '%s' '{"tag_name":"v2.3.1","draft":false,"prerelease":false,"assets":[{"name":"wgcf_2.3.1_linux_amd64","digest":null}]}'; }
      curl() { local a u='' o='' prev=''; for a in "$@"; do [[ "$prev" == '-o' ]] && o="$a"; [[ "$a" == *checksums.txt ]] && u="$a"; prev="$a"; done; [[ -n "$u" && -n "$o" ]] || return 1; printf '%s\n' "$_wgcf_sums" > "$o"; }
      [[ "$(wgcf_resolve_latest amd64)" == '2.3.1 sha256:4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8' ]] ) || { echo 'FAIL: wgcf resolver checksums fallback path'; failures=$((failures + 1)); }
    ( github_api_get() { return 1; }
      ! wgcf_resolve_latest amd64 >/dev/null 2>&1 ) || { echo 'FAIL: wgcf resolver must fail closed on API failure'; failures=$((failures + 1)); }
    ( github_api_get() { printf '%s' '{"tag_name":"v2.3.1","draft":true,"prerelease":false,"assets":[]}'; }
      ! wgcf_resolve_latest amd64 >/dev/null 2>&1 ) || { echo 'FAIL: wgcf resolver must reject draft releases'; failures=$((failures + 1)); }
    # C2 (Q3/Q8): xray-latest is retired -- the menu/install/deploy
    # functions must NOT exist; the legacy layer must exist instead.
    declare -F xray_latest_menu >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest menu still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_install_core >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest core installer still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_deploy >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest deployer still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_deploy_trio >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest trio deployer still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_deploy_quad >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest quad deployer still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_ensure_core >/dev/null 2>&1 && { echo 'FAIL: retired xray-latest core ensure still exists'; failures=$((failures + 1)); } || true
    declare -F xray_latest_legacy_detect >/dev/null 2>&1 || { echo 'FAIL: retired xray-latest legacy detector missing'; failures=$((failures + 1)); }
    declare -F xray_latest_legacy_retire >/dev/null 2>&1 || { echo 'FAIL: retired xray-latest legacy handler missing'; failures=$((failures + 1)); }
    declare -F shortcut_migrate_legacy_xray_latest >/dev/null 2>&1 || { echo 'FAIL: shortcut legacy migration missing'; failures=$((failures + 1)); }
    declare -F is_systemd >/dev/null 2>&1 || { echo 'FAIL: is_systemd missing'; failures=$((failures + 1)); }
    declare -F xray_owned >/dev/null 2>&1 || { echo 'FAIL: xray_owned missing'; failures=$((failures + 1)); }
    ( INIT_SYS_EXPECTED='' INIT_SYS='' is_systemd ) && { echo 'FAIL: is_systemd true with neither variable set'; failures=$((failures + 1)); } || true
    ( INIT_SYS=systemd is_systemd ) || { echo 'FAIL: is_systemd false with INIT_SYS=systemd'; failures=$((failures + 1)); }
    ( INIT_SYS_EXPECTED=systemd is_systemd ) || { echo 'FAIL: is_systemd false with INIT_SYS_EXPECTED=systemd'; failures=$((failures + 1)); }
    declare -F cleanup_protocols_menu >/dev/null 2>&1 || { echo 'FAIL: cleanup protocols menu missing'; failures=$((failures + 1)); }
    declare -F remove_single_protocol_menu >/dev/null 2>&1 || { echo 'FAIL: single protocol remover missing'; failures=$((failures + 1)); }
    declare -F clear_all_protocols >/dev/null 2>&1 || { echo 'FAIL: clear all protocols missing'; failures=$((failures + 1)); }
    grep -Fq "XRAY_LATEST_BIN='/usr/local/bin/xray-latest'" "$source_body_file" && { echo 'FAIL: retired xray-latest binary path constant still defined'; failures=$((failures + 1)); } || true
    grep -Fq '每月流量管控 / Monthly Traffic' "$source_body_file" || { echo 'FAIL: traffic up-to-now banner missing'; failures=$((failures + 1)); }
    grep -Fq 'one_click_reality_deploy()' "$source_body_file" || { echo 'FAIL: one-click Reality missing'; failures=$((failures + 1)); }
    grep -Fq 'abox_is_fast()' "$source_body_file" || { echo 'FAIL: fast mode helper missing'; failures=$((failures + 1)); }
    grep -Fq 'try_latest_cores_danger()' "$source_body_file" || { echo 'FAIL: try-latest cores missing'; failures=$((failures + 1)); }
    grep -Fq 'export_lightweight_subscription()' "$source_body_file" || { echo 'FAIL: lightweight subscription missing'; failures=$((failures + 1)); }
    grep -Fq 'xray_ensure_stats()' "$source_body_file" || { echo 'FAIL: xray_ensure_stats missing'; failures=$((failures + 1)); }
    grep -Fq 'multi_user_menu()' "$source_body_file" || { echo 'FAIL: multi_user_menu missing'; failures=$((failures + 1)); }
    grep -Fq 'users_sync()' "$source_body_file" || { echo 'FAIL: users_sync missing'; failures=$((failures + 1)); }
    grep -Fq 'user_guard_tick()' "$source_body_file" || { echo 'FAIL: user_guard_tick missing'; failures=$((failures + 1)); }
    grep -Fq 'setup_user_guard()' "$source_body_file" || { echo 'FAIL: setup_user_guard missing'; failures=$((failures + 1)); }
    grep -Fq 'users_hot_remove()' "$source_body_file" || { echo 'FAIL: users_hot_remove missing'; failures=$((failures + 1)); }
    grep -Fq 'deploy_with_instance_choice()' "$source_body_file" || { echo 'FAIL: deploy_with_instance_choice missing'; failures=$((failures + 1)); }
    grep -Fq 'get_public_ip_swr()' "$source_body_file" || { echo 'FAIL: get_public_ip_swr missing'; failures=$((failures + 1)); }
    # M2: the fresh-probe round must respect the total budget. Fake clock
    # (file-backed so it survives command substitution) advances 5 s per
    # curl call; with a 12 s budget the round must stop after the 3 v4
    # attempts (caps 6, 6, 2) and never try v6.
    if ! (
        _ip_clock="$tmp/ip-fake-clock"
        _ip_calls="$tmp/ip-calls"
        _ip_caps="$tmp/ip-caps"
        printf '1700000000\n' > "$_ip_clock"
        : > "$_ip_calls"; : > "$_ip_caps"
        date() {
            if [[ "${1:-}" == '+%s' ]]; then cat "$_ip_clock"; else command date "$@"; fi
        }
        curl() {
            local _m='' _prev='' _a _n
            for _a in "$@"; do
                [[ "$_prev" == '-m' ]] && _m="$_a"
                _prev="$_a"
            done
            printf 'x\n' >> "$_ip_calls"
            printf '%s\n' "$_m" >> "$_ip_caps"
            _n=$(cat "$_ip_clock"); printf '%s\n' $(( _n + 5 )) > "$_ip_clock"
            return 1
        }
        PUBLIC_IP_TOTAL_BUDGET=12
        ! get_public_ip_fresh >/dev/null 2>&1
        [[ "$(wc -l < "$_ip_calls" | tr -d ' ')" == '3' ]] || exit 1
        [[ "$(tr '\n' ' ' < "$_ip_caps")" == '6 6 2 ' ]] || exit 1
    ); then echo 'FAIL: public-IP fresh probe must stop at the total budget (3 v4 attempts, caps 6/6/2, no v6)'; failures=$((failures + 1)); fi
    grep -Fq '_ip_geo_fetch_now()' "$source_body_file" || { echo 'FAIL: _ip_geo_fetch_now missing'; failures=$((failures + 1)); }
    grep -Fq '_MI_SNI_LIST' "$source_body_file" || { echo 'FAIL: SNI list missing'; failures=$((failures + 1)); }
    grep -Fq '_MI_USER_RECS' "$source_body_file" || { echo 'FAIL: user records missing'; failures=$((failures + 1)); }
    grep -Fq 'mi_u_blocked' "$source_body_file" || { echo 'FAIL: mi_u_blocked missing'; failures=$((failures + 1)); }
    grep -Fq 'mi_users_none' "$source_body_file" || { echo 'FAIL: mi_users_none missing'; failures=$((failures + 1)); }
    grep -Fq 'mi_u_days' "$source_body_file" || { echo 'FAIL: mi_u_days missing'; failures=$((failures + 1)); }
    grep -Fq 'node_sni_menu' "$source_body_file" || { echo 'FAIL: node_sni_menu missing'; failures=$((failures + 1)); }
    grep -Fq 'sni_prompt_or_auto' "$source_body_file" || { echo 'FAIL: sni_prompt_or_auto missing'; failures=$((failures + 1)); }
    grep -Fq 'statsUserUplink' "$source_body_file" || { echo 'FAIL: per-user stats policy missing'; failures=$((failures + 1)); }
    grep -Fq 'write_full_uuid_list_to_file' "$source_body_file" || { echo 'FAIL: extra-UUID full-list writer missing (server-side revocation path)'; failures=$((failures + 1)); }
    # Exercise multi-UUID validation/deduplication on a temporary fixture; never touch /etc/ddr.
    _saved_extra_uuid_file="$EXTRA_UUID_FILE"
    _saved_uuid_set="${UUID+x}"
    _saved_uuid_value="${UUID:-}"
    EXTRA_UUID_FILE="$tmp/extra-uuids-fixture"
    UUID='11111111-1111-1111-1111-111111111111'
    printf '%s\n' \
        '11111111-1111-1111-1111-111111111111' \
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' \
        'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' \
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' \
        'aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' \
        'zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz' > "$EXTRA_UUID_FILE"
    # TRAP-7: explicit failure check (fail-closed in self-test).
    if ! _extra_uuid_actual=$(list_extra_uuids); then
        echo 'FAIL: list_extra_uuids failed on a readable file'; failures=$((failures + 1))
    fi
    _extra_uuid_expected=$'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\nbbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    [[ "$_extra_uuid_actual" == "$_extra_uuid_expected" ]] || { echo 'FAIL: multi-UUID format validation, primary exclusion, or case-insensitive deduplication'; failures=$((failures + 1)); }
    EXTRA_UUID_FILE="$_saved_extra_uuid_file"
    if [[ "$_saved_uuid_set" == x ]]; then UUID="$_saved_uuid_value"; else unset UUID; fi
    unset _saved_extra_uuid_file _saved_uuid_set _saved_uuid_value _extra_uuid_actual _extra_uuid_expected
    grep -Fq 'type=xhttp&host=$XHTTP_SNI_E&path=%2Fxhttp&mode=stream-one' "$source_body_file" || { echo 'FAIL: lightweight XHTTP subscription URI missing'; failures=$((failures + 1)); }
    grep -Fq 'XHTTP-$client_uuid' "$source_body_file" || { echo 'FAIL: Clash extra UUID XHTTP entries missing'; failures=$((failures + 1)); }
    grep -Fq 'probe_core_sources_banner()' "$source_body_file" || { echo 'FAIL: download source probe missing'; failures=$((failures + 1)); }
    grep -Fq 'abox_fetch_guard_start()' "$source_body_file" || { echo 'FAIL: fetch budget guard missing'; failures=$((failures + 1)); }
    grep -Fq 'abox_deploy_watchdog_loop()' "$source_body_file" || { echo 'FAIL: fetch watchdog missing'; failures=$((failures + 1)); }
    grep -Fq 'preserve_uninstall_transaction_backup()' "$source_body_file" || { echo 'FAIL: uninstall backup preserve missing'; failures=$((failures + 1)); }
    grep -Fq 'restore_user_guard_cron_block()' "$source_body_file" || { echo 'FAIL: restore USERGUARD reinstall missing'; failures=$((failures + 1)); }
    grep -Fq 'report_restore_cron_status()' "$source_body_file" || { echo 'FAIL: restore cron status report missing'; failures=$((failures + 1)); }
    grep -Fq 'fetch_abox_mirror_asset()' "$source_body_file" || { echo 'FAIL: mirror asset helper missing'; failures=$((failures + 1)); }

    assert_ok valid_ip_pref ipv4
    assert_ok valid_ip_pref ipv6
    assert_ok valid_ip_pref dual
    assert_bad valid_ip_pref both
    assert_ok valid_timezone_name UTC
    assert_bad valid_timezone_name '../etc/passwd'
    [[ "$(timezone_for_country CN)" == 'Asia/Shanghai' ]] || { echo 'FAIL: CN timezone heuristic'; failures=$((failures + 1)); }
    [[ "$(timezone_for_country US)" == 'America/New_York' ]] || { echo 'FAIL: US timezone heuristic'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_SNI_DEFAULT_MAX=8192' "$source_body_file" || { echo 'FAIL: SNI default max missing'; failures=$((failures + 1)); }
    [[ "$(xray_version_compare v26.7.28 v26.3.27)" == '1' ]] || { echo 'FAIL: Xray version comparison'; failures=$((failures + 1)); }
    [[ "$(xray_version_compare v26.7.28 v26.7.28)" == '0' ]] || { echo 'FAIL: Xray compatibility pin comparison'; failures=$((failures + 1)); }
    [[ "$(xray_version_compare v26.3.27 v26.3.27)" == '0' ]] || { echo 'FAIL: Xray equal version comparison'; failures=$((failures + 1)); }
    [[ "$(xray_version_compare v26.3.27 v26.7.28)" == '-1' ]] || { echo 'FAIL: Xray reverse version comparison'; failures=$((failures + 1)); }
    [[ "$(core_version_compare v26.7.28 v26.3.27)" == '1' ]] || { echo 'FAIL: Xray prerelease-tag target should not downgrade a newer core'; failures=$((failures + 1)); }
    [[ "$(core_version_compare app/v2.13.0 v2.12.3)" == '1' ]] || { echo 'FAIL: Hysteria app/ release tag comparison'; failures=$((failures + 1)); }
    [[ "$(core_version_compare v1.15.0-alpha.12 v1.15.0)" == '-1' ]] || { echo 'FAIL: SemVer prerelease must sort below final release'; failures=$((failures + 1)); }
    [[ "$(core_version_compare v1.15.0-alpha.12 v1.14.3)" == '1' ]] || { echo 'FAIL: newer SemVer prerelease major/minor/patch ordering'; failures=$((failures + 1)); }
    [[ "$(core_version_compare v1.15.0-alpha.12 v1.15.0-alpha.2)" == '1' ]] || { echo 'FAIL: numeric SemVer prerelease identifier ordering'; failures=$((failures + 1)); }
    assert_ok core_version_from_output 'sing-box version 1.14.3 (go1.25.2 linux/amd64)'
    assert_bad core_version_from_output 'no version string here at all'
    [[ "$(core_version_from_output 'sing-box version 1.14.3 (go1.25.2 linux/amd64)')" == '1.14.3' ]] || { echo 'FAIL: sing-box version parser'; failures=$((failures + 1)); }
    assert_ok core_version_downgrade_allowed v1.14.2 v1.14.3 0
    assert_bad core_version_downgrade_allowed v1.14.3 v1.14.2 0
    assert_ok core_version_downgrade_allowed v1.14.3 v1.14.2 1
    assert_ok core_version_upgrade_decision v1.14.2 v1.14.3 0 0
    assert_bad core_version_upgrade_decision v1.14.3 v1.14.2 1 0
    assert_ok core_version_upgrade_decision v1.14.3 v1.14.2 1 1
    assert_bad core_version_upgrade_decision v1.14.3 invalid 1 1
    assert_bad core_version_compare v1.15
    assert_ok core_version_probe_safe "$tmp/absent-version-probe" '' 0
    : > "$tmp/present-version-probe"
    assert_bad core_version_probe_safe "$tmp/present-version-probe" '' 0
    assert_ok core_version_probe_safe "$tmp/present-version-probe" '' 1
    assert_ok core_version_probe_safe "$tmp/present-version-probe" 'sing-box version 1.14.3' 0
    assert_bad core_version_probe_safe "$tmp/present-version-probe" '' invalid
    if ! ( docker() { return 0; }; wallos_resume_after_backup 1 "$tmp/wallos-test-backup.tar.gz" >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos backup restart success path'; failures=$((failures + 1))
    fi
    if ( docker() { return 1; }; wallos_resume_after_backup 1 "$tmp/wallos-test-backup.tar.gz" >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos backup must report a container restart failure'; failures=$((failures + 1))
    fi
    if ! ( docker() { return 1; }; wallos_resume_after_backup 0 '' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos backup should not start a container that was originally stopped'; failures=$((failures + 1))
    fi
    assert_bad wallos_resume_after_backup invalid ''
    assert_ok wallos_resume_after_backup 0 ''
    # H7 (R58b-M1): resume by pinned container ID, not by name. The
    # recording stub proves the restart addresses the ID; the
    # failing-stub case proves an unstartable pinned container is
    # reported, not silently replaced by whatever holds the name.
    # H7-ID: a sha256: spelling is normalized -- the recorded docker
    # call must carry the bare hex Docker actually accepts.
    if ! ( docker() { printf '%s\n' "$*" >> "$tmp/wallos-id-calls"; return 0; }; wallos_resume_after_backup 1 "$tmp/wallos-test-backup.tar.gz" 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 && grep -qx 'start aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-id-calls" ); then
        echo 'FAIL: Wallos backup restart did not address the pinned container ID'; failures=$((failures + 1))
    fi
    if ( docker() { return 1; }; wallos_resume_after_backup 1 "$tmp/wallos-test-backup.tar.gz" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos backup restart by ID must report an unstartable pinned container'; failures=$((failures + 1))
    fi
    assert_bad wallos_resume_after_backup 1 '' 'not-a-container-id'
    # H7rest: the upgrade journal carries the pinned container ID
    # (9th line) and the created container ID (10th line, H7-F1); an
    # invalid ID is refused; old 7-arg writes keep working with empty
    # container IDs.
    # H7-ID: the journal stores IDs bare-hex; a sha256: input is
    # normalized on write, never stored.
    # H7-F3: an uppercase new ID (even SHA256:-prefixed) normalizes
    # to bare lowercase on write.
    if ! (
        WALLOS_DIR="$tmp/wallos-h7rest-journal"
        mkdir -p "$WALLOS_DIR/backups" || exit 40
        printf 'x' > "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" || exit 41
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" 1 '' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' || exit 42
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" old_container_id)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 43
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" new_container_id)" == 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]] || exit 49
        [[ "$(wc -l < "$WALLOS_DIR/.upgrade-transaction" | tr -d '[:space:]')" == 10 ]] || exit 44
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" 1 '' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' || exit 47
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" old_container_id)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 48
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" new_container_id)" == 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]] || exit 50
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" 1 '' 'not-a-container-id' && exit 45
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" 1 '' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'not-a-container-id' && exit 51
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$WALLOS_DIR/backups/wallos-1.2.3.tar.gz" 1 || exit 46
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" new_container_id)" == '' ]] || exit 52
    ); then
        echo 'FAIL: Wallos upgrade journal must carry the pinned container ID'; failures=$((failures + 1))
    fi
    # H7rest: _wallos_rm_named_id removes by ID (gone expected ID plus
    # no live holder is a no-op success) and refuses a foreign holder.
    # H7-ID: inspect returns bare hex; rm is addressed by bare hex.
    # H7-F2: the gone case needs real evidence -- Docker's own
    # "No such container" wording on inspect stderr, plus an empty
    # `docker ps -a` listing. A bare inspect failure with no wording
    # is "state unknown", not "gone".
    if ! ( docker() { case "$*" in 'container inspect wallos') printf 'Error: No such container: wallos\n' >&2; return 1 ;; *'{{.Id}}'*) printf 'Error: No such container: wallos\n' >&2; return 1 ;; *'ps -a'*) return 0 ;; 'rm -f '*) return 1 ;; *) return 0 ;; esac; }; _wallos_rm_named_id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos named-container removal must succeed when nothing holds the name'; failures=$((failures + 1))
    fi
    if ( docker() { case "$*" in *'{{.Id}}'*) printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'; return 0 ;; *'Config.Labels'*) printf '\n'; return 0 ;; *) return 0 ;; esac; }; _wallos_rm_named_id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos named-container removal must refuse a foreign holder'; failures=$((failures + 1))
    fi
    if ! ( : > "$tmp/wallos-rm-calls"; printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$tmp/wallos-live-id"
        docker() { printf '%s\n' "$*" >> "$tmp/wallos-rm-calls"; case "$*" in
            'container inspect wallos') if [[ -s "$tmp/wallos-live-id" ]]; then return 0; fi; printf 'Error: No such container: wallos\n' >&2; return 1 ;;
            *'{{.Id}}'*) if [[ -s "$tmp/wallos-live-id" ]]; then cat "$tmp/wallos-live-id"; return 0; fi; printf 'Error: No such container: wallos\n' >&2; return 1 ;;
            'rm -f '*) if [[ "${3:-}" == "$(cat "$tmp/wallos-live-id" 2>/dev/null)" ]]; then : > "$tmp/wallos-live-id"; return 0; fi; return 1 ;;
            *'Config.Labels'*) printf 'true\n'; return 0 ;;
            *) return 0 ;; esac; }
        _wallos_rm_named_id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 && grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-rm-calls" ); then
        echo 'FAIL: Wallos named-container removal did not address the pinned container ID'; failures=$((failures + 1))
    fi
    # H7-F2: a Docker daemon error is "state unknown" (refuse), not
    # "name free"; an illegal live .Id refuses too; only a proven
    # "No such container" (plus an empty ps listing) is "gone".
    if ( docker() { case "$*" in 'container inspect wallos') printf 'Error: Cannot connect to the Docker daemon\n' >&2; return 1 ;; *'{{.Id}}'*) printf 'Error: Cannot connect to the Docker daemon\n' >&2; return 1 ;; 'rm -f '*) return 1 ;; *) return 0 ;; esac; }; _wallos_rm_named_id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos named-container removal must refuse on a Docker daemon error'; failures=$((failures + 1))
    fi
    if ( docker() { case "$*" in *'{{.Id}}'*) printf '%s\n' 'ZZZ-not-a-container-id'; return 0 ;; *) return 0 ;; esac; }; _wallos_rm_named_id '' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos named-container removal must refuse an illegal live container ID'; failures=$((failures + 1))
    fi
    # H7-F3: a non-empty expected ID that does not normalize refuses;
    # only an empty expectation means "no expectation".
    if ( docker() { return 0; }; _wallos_rm_named_id 'not-a-container-id' >/dev/null 2>&1 ); then
        echo 'FAIL: Wallos named-container removal must refuse an illegal expected container ID'; failures=$((failures + 1))
    fi
    # H7-C: a run/create that fails after creating the container must
    # not strand it: the failed-create cleanup removes only the
    # --cidfile container (label-checked, by ID), so a retry rebuilds
    # instead of wedging on a stale journal new_container_id.
    if ! ( : > "$tmp/wallos-h7c-calls"; printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$tmp/wallos-h7c-cid"
        docker() { printf '%s\n' "$*" >> "$tmp/wallos-h7c-calls"; case "$*" in *'Config.Labels'*) printf 'true\n'; return 0 ;; 'rm -f '*) return 0 ;; *) return 0 ;; esac; }
        _wallos_cleanup_failed_create "$tmp/wallos-h7c-cid" >/dev/null 2>&1 && [[ ! -e "$tmp/wallos-h7c-cid" ]] && grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-h7c-calls" ); then
        echo 'FAIL: Wallos failed-create cleanup did not remove the cidfile container by ID'; failures=$((failures + 1))
    fi
    if ! ( : > "$tmp/wallos-h7c-calls"
        docker() { printf '%s\n' "$*" >> "$tmp/wallos-h7c-calls"; case "$*" in *'Config.Labels'*) printf '\n'; return 0 ;; *) return 0 ;; esac; }
        printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$tmp/wallos-h7c-cid2"
        _wallos_cleanup_failed_create "$tmp/wallos-h7c-cid2" >/dev/null 2>&1 && [[ -e "$tmp/wallos-h7c-cid2" ]] && ! grep -q 'rm -f ' "$tmp/wallos-h7c-calls" ); then
        echo 'FAIL: Wallos failed-create cleanup must leave a non-managed cidfile container alone'; failures=$((failures + 1))
    fi
    if ! ( : > "$tmp/wallos-h7c-calls"; docker() { printf '%s\n' "$*" >> "$tmp/wallos-h7c-calls"; return 0; }
        _wallos_cleanup_failed_create "$tmp/wallos-h7c-missing" >/dev/null 2>&1 && ! grep -q 'rm -f ' "$tmp/wallos-h7c-calls" ); then
        echo 'FAIL: Wallos failed-create cleanup must be a no-op without a cidfile'; failures=$((failures + 1))
    fi
    # H7rest: the php version probe execs the pinned container ID.
    if ! ( docker() { printf '%s\n' "$*" >> "$tmp/wallos-php-calls"; case "$*" in *'{{.Id}}'*) printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; return 0 ;; 'exec '*) printf 'PHP 8.3.10 (cli)\n'; return 0 ;; *) return 1 ;; esac; }; [[ "$(wallos_container_php_version 2>/dev/null)" == '8.3.10' ]] && grep -qx 'exec aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa php -v' "$tmp/wallos-php-calls" ); then
        echo 'FAIL: Wallos php version did not address the pinned container ID'; failures=$((failures + 1))
    fi
    # H7-ID: Docker reports a container .Id as bare hex, and a sha256:
    # form addresses no container (inspect/stop/start fail; rm -f exits
    # 0 without removing). The ID helpers must accept the bare hex
    # inspect returns, and must never pass a sha256: form to docker --
    # the recording stub below fails any docker call carrying one.
    if ! ( : > "$tmp/wallos-h7id-calls"
        docker() { printf '%s\n' "$*" >> "$tmp/wallos-h7id-calls"; case "$*" in
            *'sha256:'*) return 1 ;;
            *'{{.Id}}'*) printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; return 0 ;;
            *) return 0 ;; esac; }
        [[ "$(_wallos_container_id 2>/dev/null)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 51
        _wallos_stop_id 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 || exit 52
        _wallos_start_id 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 || exit 53
        _wallos_rm_id 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1 || exit 54
        grep -qx 'stop aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-h7id-calls" || exit 55
        grep -qx 'start aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-h7id-calls" || exit 56
        grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/wallos-h7id-calls" || exit 57
        ! grep -q 'sha256:' "$tmp/wallos-h7id-calls" || exit 58
    ); then
        echo 'FAIL: Wallos container ID must be bare hex and never reach docker as sha256:'; failures=$((failures + 1))
    fi
    # H7-F3: normalize canonicalizes to bare lowercase hex: bare
    # uppercase, sha256: uppercase and SHA256: uppercase all map to
    # the same bare lowercase ID; an illegal value still refuses.
    if ! (
        [[ "$(_wallos_normalize_container_id 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 61
        [[ "$(_wallos_normalize_container_id 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 62
        [[ "$(_wallos_normalize_container_id 'sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null)" == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || exit 63
        ! _wallos_normalize_container_id 'not-a-container-id' >/dev/null 2>&1 || exit 64
        ! _wallos_normalize_container_id '' >/dev/null 2>&1 || exit 65
    ); then
        echo 'FAIL: Wallos container ID normalization must canonicalize to bare lowercase hex'; failures=$((failures + 1))
    fi
    # N-11: versioned history — SHA256SUMS append/sort/prune logic.
    {
        local n11_tmp n11_versions
        n11_tmp=$(umask 077; mktemp -d) || exit 40
        # Simulate a cumulative SHA256SUMS with 4 versions (unsorted).
        cat > "$n11_tmp/SHA256SUMS" <<'N11EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  wallos-linux-amd64-v2.5.3.tar.gz
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  wallos-linux-amd64-v2.5.1.tar.gz
cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  wallos-linux-amd64-v2.5.2.tar.gz
dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  wallos-linux-amd64-v2.5.0.tar.gz
N11EOF
        # Parse versions (same pattern as workflow).
        # X-12: POSIX field-numeric sort instead of GNU sort -V.
        mapfile -t n11_versions < <(awk '{print $2}' "$n11_tmp/SHA256SUMS" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u | sed 's/^/v/')
        [[ "${#n11_versions[@]}" == 4 ]] || { echo 'FAIL: N-11 version parse count'; failures=$((failures + 1)); }
        [[ "${n11_versions[3]}" == 'v2.5.3' ]] || { echo 'FAIL: N-11 version sort order'; failures=$((failures + 1)); }
        # Prune to newest 3 (same logic as workflow).
        if ((${#n11_versions[@]} > 3)); then
            local _pv
            for _pv in "${n11_versions[@]:0:$((${#n11_versions[@]} - 3))}"; do
                grep -vF -- "$_pv" "$n11_tmp/SHA256SUMS" > "$n11_tmp/SHA256SUMS.tmp" || true
                mv -f "$n11_tmp/SHA256SUMS.tmp" "$n11_tmp/SHA256SUMS"
            done
        fi
        # v2.5.0 must be gone, others retained.
        grep -q 'v2.5.0' "$n11_tmp/SHA256SUMS" && { echo 'FAIL: N-11 prune did not remove oldest'; failures=$((failures + 1)); }
        grep -q 'v2.5.1' "$n11_tmp/SHA256SUMS" || { echo 'FAIL: N-11 prune removed wrong version'; failures=$((failures + 1)); }
        # Sort stability: sort -k2,2 keeps filename order.
        sort -k2,2 -u "$n11_tmp/SHA256SUMS" -o "$n11_tmp/SHA256SUMS"
        [[ "$(head -n 1 "$n11_tmp/SHA256SUMS" | awk '{print $2}')" == 'wallos-linux-amd64-v2.5.1.tar.gz' ]] || {
            echo 'FAIL: N-11 SHA256SUMS sort order'; failures=$((failures + 1)); }
        rm -rf -- "$n11_tmp"
        # S169: the N-11 version lookup must go through the production
        # path, not a fixed-input sed check. 07e-01: the old blind N-1
        # fallback (2nd line of the list) is removed, so build two
        # 0:0/600 8-line journals and stub docker + version list +
        # backup ops in subshells (stubs do not leak): (a) an old tag
        # absent from the stub list must refuse without pulling
        # anything, keeping the journal; (b) an old tag present in
        # the stub list must pull exactly that tag and recover.
        if (( EUID == 0 )); then
            ( _n1_tmp=$(mktemp -d /tmp/A-Box-n1.XXXXXX) || exit 1
              trap 'rm -rf -- "$_n1_tmp"' EXIT
              WALLOS_DIR="$_n1_tmp"
              mkdir -p "$WALLOS_DIR/backups"
              echo 'backup' > "$WALLOS_DIR/backups/wallos-test.tar.gz"
              { echo 'phase=active'
                echo 'old_image=bellamy/wallos:9.9.9'
                echo 'old_port=8080'
                echo 'old_tz=UTC'
                echo 'old_bind='
                echo "backup=$WALLOS_DIR/backups/wallos-test.tar.gz"
                echo 'was_running=0'
                echo 'old_image_id='; } > "$WALLOS_DIR/.upgrade-transaction"
              chmod 600 "$WALLOS_DIR/.upgrade-transaction"
              _n1_log="$_n1_tmp/pulled"
              # R16-F15-03: the stub must emit the signal real Docker
              # emits for a missing container; a bare rc=1 with empty
              # stderr is "state unknown" under the tri-state rule,
              # not proof of absence.
              docker() { case "$1" in image) return 1 ;; container) printf 'Error: No such container: wallos\n' >&2; return 1 ;; *) return 0 ;; esac; }
              wallos_mirror_version_list() { echo 'v9.9.1'; echo 'v9.9.0'; echo 'v8.8.8'; }
              wallos_validate_backup() { return 0; }
              wallos_restore_backup() { return 0; }
              _wallos_pull_versioned_image() { echo "$1" > "$_n1_log"; WALLOS_IMAGE_RESULT='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; return 0; }
              # R14-F15-04: the front teardowns now require a confirmed
              # stopped state (a failed state query no longer reads as
              # stopped). This sandbox's init system cannot answer the
              # query, and the scenario has no fronts installed, so stub
              # the state query to stopped; the tag assertions below
              # are what this block actually tests.
              service_active_state_value() { printf '0\n'; return 0; }
              wallos_recover_interrupted_upgrade >/dev/null 2>&1 && exit 1
              [[ ! -e "$_n1_log" ]] || exit 1
              [[ -f "$WALLOS_DIR/.upgrade-transaction" ]] || exit 1
            ) || { echo 'FAIL: N-11 recovery must refuse when the old tag is absent from the version list'; failures=$((failures + 1)); }
            ( _n1_tmp=$(mktemp -d /tmp/A-Box-n1.XXXXXX) || exit 1
              trap 'rm -rf -- "$_n1_tmp"' EXIT
              WALLOS_DIR="$_n1_tmp"
              mkdir -p "$WALLOS_DIR/backups"
              echo 'backup' > "$WALLOS_DIR/backups/wallos-test.tar.gz"
              { echo 'phase=active'
                echo 'old_image=bellamy/wallos:9.9.0'
                echo 'old_port=8080'
                echo 'old_tz=UTC'
                echo 'old_bind='
                echo "backup=$WALLOS_DIR/backups/wallos-test.tar.gz"
                echo 'was_running=0'
                echo 'old_image_id='; } > "$WALLOS_DIR/.upgrade-transaction"
              chmod 600 "$WALLOS_DIR/.upgrade-transaction"
              _n1_log="$_n1_tmp/pulled"
              docker() { case "$1" in
                  image) return 1 ;;
                  container) printf 'Error: No such container: wallos\n' >&2; return 1 ;;
                  # H7-F1: recovery records the rebuilt container via
                  # --cidfile, so the stub must write it (real docker
                  # behavior) and answer the post-create pin.
                  create|run)
                      _n1_created=1
                      local _cidfile='' _prev='' _a=''
                      for _a in "$@"; do
                          if [[ "$_prev" == --cidfile ]]; then _cidfile="$_a"; fi
                          _prev="$_a"
                      done
                      [[ -n "$_cidfile" ]] && printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$_cidfile" 2>/dev/null || true
                      return 0 ;;
                  inspect)
                      [[ -n "${_n1_created:-}" ]] && { printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; return 0; }
                      return 1 ;;
                  *) return 0 ;;
              esac; }
              wallos_mirror_version_list() { echo 'v9.9.1'; echo 'v9.9.0'; echo 'v8.8.8'; }
              wallos_validate_backup() { return 0; }
              wallos_restore_backup() { return 0; }
              _wallos_pull_versioned_image() { echo "$1" > "$_n1_log"; WALLOS_IMAGE_RESULT='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; return 0; }
              service_active_state_value() { printf '0\n'; return 0; }
              wallos_recover_interrupted_upgrade || exit 1
              [[ "$(cat "$_n1_log")" == 'v9.9.0' ]] || exit 1
            ) || { echo 'FAIL: N-11 recovery must pull the exact old tag via production path'; failures=$((failures + 1)); }
        # R16-F15-03: an inspect failure WITHOUT Docker's "No such
        # container" text is "state unknown", not "absent": the
        # same journal must refuse instead of restoring data.
        if (( EUID == 0 )); then
            ( _n1u_tmp=$(mktemp -d /tmp/A-Box-n1u.XXXXXX) || exit 1
              trap 'rm -rf -- "$_n1u_tmp"' EXIT
              WALLOS_DIR="$_n1u_tmp"
              mkdir -p "$WALLOS_DIR/backups"
              echo 'backup' > "$WALLOS_DIR/backups/wallos-test.tar.gz"
              { echo 'phase=active'
                echo 'old_image=bellamy/wallos:9.9.9'
                echo 'old_port=8080'
                echo 'old_tz=UTC'
                echo 'old_bind='
                echo "backup=$WALLOS_DIR/backups/wallos-test.tar.gz"
                echo 'was_running=0'
                echo 'old_image_id='; } > "$WALLOS_DIR/.upgrade-transaction"
              chmod 600 "$WALLOS_DIR/.upgrade-transaction"
              docker() { case "$1" in image) return 1 ;; container) printf 'Cannot connect to the Docker daemon\n' >&2; return 1 ;; *) return 0 ;; esac; }
              # M1: the recovery path looks the journal tag up in the
              # mirror version list; without this mock it fetched the
              # real list (the one real-network call left in self-test
              # besides the Cloudflare trace probes). 9.9.9 stays absent
              # from the mocked list, so the refuse path is unchanged.
              wallos_mirror_version_list() { echo 'v9.9.1'; echo 'v9.9.0'; echo 'v8.8.8'; }
              wallos_validate_backup() { return 0; }
              wallos_restore_backup() { echo 'RESTORED' > "$_n1u_tmp/restored"; return 0; }
              wallos_recover_interrupted_upgrade >/dev/null 2>&1 && exit 1
              [[ ! -e "$_n1u_tmp/restored" ]] || exit 1
            ) || { echo 'FAIL: N-11 recovery must refuse on unknown container state'; failures=$((failures + 1)); }
        fi
        else
            selftest_note 'N-11 N-1 auto-select production-path test skipped for non-root execution'
        fi
        # N-11: rollback rejects invalid versions.
        assert_bad wallos_rollback_to_version 'not-a-version'
        assert_bad wallos_rollback_to_version 'v2.5'
        # N-11: required functions exist.
        declare -F wallos_mirror_version_list >/dev/null || { echo 'FAIL: N-11 wallos_mirror_version_list missing'; failures=$((failures + 1)); }
        declare -F wallos_prune_local_images >/dev/null || { echo 'FAIL: N-11 wallos_prune_local_images missing'; failures=$((failures + 1)); }
        declare -F wallos_rollback_to_version >/dev/null || { echo 'FAIL: N-11 wallos_rollback_to_version missing'; failures=$((failures + 1)); }
        declare -F _wallos_pull_versioned_image >/dev/null || { echo 'FAIL: N-11 _wallos_pull_versioned_image missing'; failures=$((failures + 1)); }
        declare -F _wallos_manual_rollback >/dev/null || { echo 'FAIL: N-11 _wallos_manual_rollback missing'; failures=$((failures + 1)); }
    }
    [[ "$(xray_version_compare v9223372036854775808.0.0 v26.9.8)" == '1' ]] || { echo 'FAIL: Xray huge-version comparison overflow regression'; failures=$((failures + 1)); }
    [[ "$(xray_version_compare v18446744073709551616.0.0 v26.9.8)" == '1' ]] || { echo 'FAIL: Xray extra-large version comparison regression'; failures=$((failures + 1)); }
    grep -Fq "ABOX_XRAY_REALITY_MLKEM_MIN_VERSION='v26.9.8'" "$source_body_file" || { echo 'FAIL: Xray REALITY ML-KEM threshold constant missing'; failures=$((failures + 1)); }
    # 3 real sites each; source snapshot excludes these assertion lines themselves.
    runtime_guard_impl_count=$(grep -Fc '( umask 077; set -C; : > "$RUNTIME_LOCK" )' "$source_body_file" || true)
    [[ "$runtime_guard_impl_count" =~ ^[0-9]+$ && "$runtime_guard_impl_count" -ge 3 ]] || { echo 'FAIL: all background helpers must recreate the runtime lock after /run recreation'; failures=$((failures + 1)); }
    runtime_guard_count=$(grep -Fc 'RUNTIME_LOCK=/run/A-Box.lock' "$source_body_file" || true)
    [[ "$runtime_guard_count" =~ ^[0-9]+$ && "$runtime_guard_count" -ge 3 ]] || { echo 'FAIL: all background helpers must honor the global A-Box runtime lock'; failures=$((failures + 1)); }
    grep -Fq 'systemctl disable "$srv"' "$source_body_file" || { echo 'FAIL: traffic quota stop path must disable systemd autostart'; failures=$((failures + 1)); }
    grep -Fq 'rc-update del "$srv" default' "$source_body_file" || { echo 'FAIL: traffic quota stop path must remove OpenRC autostart'; failures=$((failures + 1)); }
    grep -Fq 'start-stop-daemon --stop --pidfile "$pidfile" --exec "$exe" --retry TERM/5/KILL/1' "$source_body_file" || { echo 'FAIL: OpenRC stop fallback must bind PID to expected executable'; failures=$((failures + 1)); }
    ( verify_github_asset_digest /dev/null '' ) >/dev/null 2>&1 && { echo 'FAIL: missing GitHub digest must be rejected'; failures=$((failures + 1)); }
    grep -Fq '[[ "$digest" == sha256:* && "${digest#sha256:}" =~ ^[A-Fa-f0-9]{64}$ ]]' "$source_body_file" || { echo 'FAIL: fetch helper must prevalidate GitHub digest before mirror retry'; failures=$((failures + 1)); }
    ( ABOX_ASSUME_YES_OTA=1 confirm_ota_script_hash 0000000000000000000000000000000000000000000000000000000000000000 https://example.com/script.sh ) >/dev/null 2>&1 && { echo 'FAIL: ABOX_ASSUME_YES_OTA must be rejected without allowlist'; failures=$((failures + 1)); }
    # N-05: assert the REAL env -i call site (not a self-matching pattern).
    grep -Fq "env -i \\" "$source_body_file" || { echo 'FAIL: remote third-party scripts must not inherit GITHUB_TOKEN'; failures=$((failures + 1)); }

    [[ "$(normalize_port_spec 020000-025000)" == '20000:25000' ]] || { echo 'FAIL: normalize port range'; failures=$((failures + 1)); }
    HY2_DOMAIN=example.com HY2_ACME_TYPE=http CORE_IN=hysteria MODE_IN=HY2 VLESS_PORT=8443 XHTTP_PORT=9443 SS_PORT=2053 HY2_BASE_PORT=443 HY2_HOP=false HY2_HOP_IMPL=none
    [[ "$(selected_port_pairs | grep -Fx 'tcp/80')" == 'tcp/80' ]] || { echo 'FAIL: Hysteria HTTP-01 must reserve TCP/80'; failures=$((failures + 1)); }
    CORE_IN=singbox MODE_IN=HY2
    [[ "$(selected_port_pairs | grep -Fx 'tcp/80')" != 'tcp/80' ]] || { echo 'FAIL: sing-box HY2 must not reserve TCP/80'; failures=$((failures + 1)); }
    CORE_IN=xray MODE_IN=ALL HY2_ACME_TYPE=http
    [[ "$(selected_port_pairs | grep -Fx 'tcp/80')" == 'tcp/80' ]] || { echo 'FAIL: Xray ALL HTTP-01 must reserve TCP/80'; failures=$((failures + 1)); }
    HY2_ACME_TYPE=dns
    [[ "$(selected_port_pairs | grep -Fx 'tcp/80')" != 'tcp/80' ]] || { echo 'FAIL: DNS-01 must not reserve TCP/80'; failures=$((failures + 1)); }
    unset HY2_DOMAIN HY2_ACME_TYPE CORE_IN MODE_IN VLESS_PORT XHTTP_PORT SS_PORT HY2_BASE_PORT HY2_HOP HY2_HOP_IMPL
    (
        sni_probe_candidate_tier() { printf 'A\n'; }
        [[ "$(sni_verified_amazon_fallback)" == 'www.amazon.com' ]] || exit 1
        sni_probe_candidate_tier() { printf 'R\n'; }
        [[ "$(sni_verified_amazon_fallback 2>/dev/null)" == 'www.amazon.com' ]] || exit 2
        sni_probe_candidate_tier() { printf 'D\n'; }
        [[ -z "$(sni_verified_amazon_fallback 2>/dev/null)" ]] || exit 3
        sni_probe_candidate_tier() { printf 'N\n'; }
        [[ -z "$(sni_verified_amazon_fallback 2>/dev/null)" ]] || exit 4
        ABOX_AUTO_SNI_SELECTED=''
        [[ -z "$(default_sni_for_port 443)" ]] || exit 5
    ) || { echo 'FAIL: Amazon fallback must pass TLS/h2/SAN checks before use'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty www.apple.com)" == '1800' ]] || { echo 'FAIL: Apple www SNI penalty'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty maps.apple.com)" == '2400' ]] || { echo 'FAIL: Apple subdomain SNI penalty'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty apple.com)" == '2400' ]] || { echo 'FAIL: Apple apex SNI penalty'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty github.com)" == '2400' ]] || { echo 'FAIL: GitHub apex SNI penalty'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty www.amazon.com)" == '0' ]] || { echo 'FAIL: Amazon SNI must be neutral (research-aligned fallback)'; failures=$((failures + 1)); }
    [[ "$(sni_domain_penalty www.microsoft.com)" == '0' ]] || { echo 'FAIL: Microsoft SNI must be neutral (research-aligned)'; failures=$((failures + 1)); }
    [[ "$(sni_raw_score 0.1 0.1 0.1 -220)" == '-92' ]] || { echo 'FAIL: SNI raw score must preserve negative ranking values'; failures=$((failures + 1)); }
    [[ "$(sni_adjust_score -92 -1500)" == '-1592' ]] || { echo 'FAIL: SNI ASN bonus must preserve negative ranking values'; failures=$((failures + 1)); }
    local sni_diverse_in="$tmp/sni-diverse.in" sni_diverse_out="$tmp/sni-diverse.out"
    printf '%s\n' \
        'www.example.co.uk' 'example.co.uk' 'another.co.uk' \
        'www.example.com' 'example.com' 'www.other.com' \
        'www.amazon.com' 'a.b.c.example.com' 'api.example.co.uk' \
        > "$sni_diverse_in"
    sni_build_diverse_candidate_pool "$sni_diverse_in" "$sni_diverse_out" || { echo 'FAIL: SNI diverse candidate pool builder'; failures=$((failures + 1)); }
    [[ "$(wc -l < "$sni_diverse_out" | tr -d ' ')" == '4' ]] || { echo 'FAIL: SNI root-domain deduplication collapsed unrelated country domains'; failures=$((failures + 1)); }
    grep -Fxq 'www.example.co.uk' "$sni_diverse_out" || { echo 'FAIL: SNI multi-label suffix candidate omitted'; failures=$((failures + 1)); }
    grep -Fxq 'another.co.uk' "$sni_diverse_out" || { echo 'FAIL: distinct .co.uk registrable domain must survive deduplication'; failures=$((failures + 1)); }
    ! grep -Fxq 'example.co.uk' "$sni_diverse_out" || { echo 'FAIL: same registrable domain must be deduplicated'; failures=$((failures + 1)); }
    ! grep -Fxq 'www.amazon.com' "$sni_diverse_out" || { echo 'FAIL: Amazon must remain fallback-only'; failures=$((failures + 1)); }
    [[ "$(sni_report_fit_tier tls13=1 alpn=h2 san=1 asnmatch=1 samecountry=1 cdnpenalty=0)" == 'A' ]] || { echo 'FAIL: SNI same-ASN compatible tier'; failures=$((failures + 1)); }
    [[ "$(sni_report_fit_tier tls13=1 alpn=h2 san=1 asnmatch=1 samecountry=1 cdnpenalty=500)" == 'R' ]] || { echo 'FAIL: SNI CDN-risk tier must override green recommendation'; failures=$((failures + 1)); }
    [[ "$(sni_report_fit_tier tls13=1 alpn=h2 san=1 asnmatch=0 samecountry=1 cdnpenalty=0)" == 'B' ]] || { echo 'FAIL: SNI same-country compatible tier'; failures=$((failures + 1)); }
    [[ "$(sni_report_fit_tier tls13=1 alpn=h2 san=1 asnmatch=0 samecountry=0 cdnpenalty=0)" == 'C' ]] || { echo 'FAIL: SNI other-ASN compatible tier'; failures=$((failures + 1)); }
    [[ "$(sni_report_fit_tier tls13=1 alpn=http/1.1 san=1 asnmatch=1 samecountry=1 cdnpenalty=0)" == 'D' ]] || { echo 'FAIL: SNI incompatible ALPN tier'; failures=$((failures + 1)); }
    [[ "$(sni_org_cdn_penalty api.cloudflare.com 'AS13335 Cloudflare, Inc.')" -ge 300 ]] || { echo 'FAIL: Cloudflare first-party target must retain CDN-risk label'; failures=$((failures + 1)); }
    [[ "$(sni_org_cdn_penalty api.fastly.com 'AS54113 Fastly, Inc.')" -ge 300 ]] || { echo 'FAIL: Fastly first-party target must retain CDN-risk label'; failures=$((failures + 1)); }
    ! grep -Fq 'NR <= 8' <(sed -n '/^traffic_management_menu() {$/,/^manage_ss_whitelist()/p' "$0") || { echo 'FAIL: monthly vnStat display must not truncate after 8 raw lines'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_SNI_FULL_TOPN:-100' "$source_body_file" || { echo 'FAIL: full SNI result display count default'; failures=$((failures + 1)); }
    ! grep -q '^MAIN_LOCK=/run/A-Box.lock$' "$0" || { echo 'FAIL: helper health probe still depends on interactive main lock'; failures=$((failures + 1)); }
    traffic_writer_body=$(sed -n '/write_private_line() {/,/^read_desired() {/p' "$0") || { echo 'FAIL: traffic helper writer static extraction'; failures=$((failures + 1)); }
    ! grep -q 'path_parent_chain_safe "\$dest"' <<< "$traffic_writer_body" || { echo 'FAIL: traffic helper calls main-only function'; failures=$((failures + 1)); }
    grep -q 'export XRAY_LOCATION_ASSET="/usr/local/share/xray"' "$source_body_file" || { echo 'FAIL: OpenRC Xray asset path is not exported'; failures=$((failures + 1)); }
    # R11C8-02: the geo updater now resolves the manifest via SCRIPT_DIR
    # (its own location), not a hardcoded /etc/ddr literal.
    grep -q '^ABOX_CORE_OWNERSHIP="$SCRIPT_DIR/.managed-core-files.tsv"$' "$0" || { echo 'FAIL: Geo updater ownership manifest path missing'; failures=$((failures + 1)); }
    grep -q '^update_geo_ownership() {' "$0" || { echo 'FAIL: Geo updater ownership refresh helper missing'; failures=$((failures + 1)); }
    grep -q 'if ! update_geo_ownership; then' "$source_body_file" || { echo 'FAIL: Geo updater does not roll back when ownership refresh fails'; failures=$((failures + 1)); }
    grep -q 'write_file_atomically_from_stdin "$ABOX_DIR/.swapfile.managed"' "$source_body_file" || { echo 'FAIL: managed swap marker missing'; failures=$((failures + 1)); }
    grep -q 'Authorization: Bearer %s' "$source_body_file" || { echo 'FAIL: GitHub bearer token config support missing'; failures=$((failures + 1)); }
    # H-19: the old assertion grepped the fabricated 'invalid request
    # from' format Xray never emits; the new failregex covers real
    # '... rejected ... invalid request|invalid user' access.log lines.
    grep -Fq 'invalid request|invalid user' "$source_body_file" || { echo 'FAIL: Fail2Ban must cover exact Xray invalid-request scanner logs'; failures=$((failures + 1)); }
    grep -q 'backend=\$(firewall_backend)' "$source_body_file" || { echo 'FAIL: firewall backend routing missing'; failures=$((failures + 1)); }
    grep -q '^remove_abox_native_firewall_rule() {' "$0" || { echo 'FAIL: exact owned firewall port removal helper missing'; failures=$((failures + 1)); }
    grep -q '^forget_native_firewall_rule() {' "$0" || { echo 'FAIL: native firewall ownership-state removal helper missing'; failures=$((failures + 1)); }
    _forget_call_prefix='forget_native_firewall_rule'; _ufw_call_suffix=' "$spec" "$proto" ufw'; _fwd_call_suffix=' "$_spec" "$proto" firewalld'
    grep -Fq -- "${_forget_call_prefix}${_ufw_call_suffix}" "$0" || { echo 'FAIL: UFW firewall-state removal must preserve backend ownership'; failures=$((failures + 1)); }
    grep -Fq -- "${_forget_call_prefix}${_fwd_call_suffix}" "$0" || { echo 'FAIL: firewalld firewall-state removal must preserve backend ownership'; failures=$((failures + 1)); }
    grep -q '^preflight_reset_ownership() {' "$0" || { echo 'FAIL: reset ownership preflight missing'; failures=$((failures + 1)); }
    grep -Fq 'command clear || true' "$source_body_file" || { echo 'FAIL: non-interactive clear guard missing'; failures=$((failures + 1)); }
    grep -Fq 'if [[ -t 0 ]]; then' "$source_body_file" || { echo 'FAIL: pause_return TTY guard missing'; failures=$((failures + 1)); }
    _http01_cleanup_call='remove_abox_native_firewall_rule'; _http01_cleanup_args=' 80 tcp'
    ! grep -Fq -- "${_http01_cleanup_call}${_http01_cleanup_args}" "$0" || { echo 'FAIL: HTTP-01 must keep 80/tcp reachable for CertMagic HTTP challenge and renewal'; failures=$((failures + 1)); }
    _hop_udp_regex='-p udp'; _hop_redirect_regex='REDIRECT --to-ports'
    _hop_udp_rule_count=$(grep -F -- "$_hop_udp_regex" "$0" | grep -Fc -- "$_hop_redirect_regex" || true)
    [[ "$_hop_udp_rule_count" -ge 4 ]] || { echo 'FAIL: HY2 official hop iptables checks must require UDP in both verifier copies'; failures=$((failures + 1)); }
    _http01_cleanup_helper='cleanup_http01_port_after_' ; _http01_cleanup_helper+='hy2_start'
    ! grep -Fq -- "$_http01_cleanup_helper" "$0" || { echo 'FAIL: obsolete HTTP-01 post-start cleanup path remains'; failures=$((failures + 1)); }
    grep -Fq 'IPv6 白名单已配置，但系统没有可用 IPv6 防火墙' "$source_body_file" || { echo 'FAIL: IPv6 whitelist silent-skip guard missing'; failures=$((failures + 1)); }
    grep -Fq '[[ "$current_line" =~ ^-A[[:space:]]+INPUT[[:space:]] ]] || continue' "$source_body_file" || { echo 'FAIL: firewall rule numbering must skip policy/header lines'; failures=$((failures + 1)); }
    grep -q 'iptables_rule_check() {' "$source_body_file" || { echo 'FAIL: standalone firewall restore helper missing'; failures=$((failures + 1)); }
    grep -q 'f2b_action='"'"'firewallcmd-multiport'"'"'' "$0" || { echo 'FAIL: Fail2Ban firewalld action mapping missing'; failures=$((failures + 1)); }
    grep -q 'f2b_action='"'"'ufw'"'"'' "$0" || { echo 'FAIL: Fail2Ban UFW action mapping missing'; failures=$((failures + 1)); }
    grep -q 'bbr_module_file=' "$source_body_file" || { echo 'FAIL: BBR module persistence path missing'; failures=$((failures + 1)); }
    grep -q '^    local -a pids=() exes=()' "$0" || { echo 'FAIL: parallel residual PID collection missing'; failures=$((failures + 1)); }
    grep -q 'pid_exe_matches "$pid" "$exe"' "$source_body_file" || { echo 'FAIL: PID reuse executable recheck missing'; failures=$((failures + 1)); }
    declare -F selftest_abox_signature >/dev/null || { echo 'FAIL: live /etc/ddr side-effect regression guard missing'; failures=$((failures + 1)); }
    grep -q -- '--config -' "$source_body_file" || { echo 'FAIL: GitHub token pipe config guard missing'; failures=$((failures + 1)); }
    grep -q '2300000' "$source_body_file" || { echo 'FAIL: swap free-space safety check missing'; failures=$((failures + 1)); }
    grep -q 'created_by_abox == 1' "$source_body_file" || { echo 'FAIL: swap ownership must only be recorded for A-Box-created swap'; failures=$((failures + 1)); }
    grep -Fq 'setup_zram_swap()' "$source_body_file" || { echo 'FAIL: zram swap setup missing'; failures=$((failures + 1)); }
    grep -Fq 'users_registries_wipe' "$source_body_file" || { echo 'FAIL: registry wipe missing from cleanup paths'; failures=$((failures + 1)); }
    grep -Fq 'users_registry_remove "$core" "$tag"' "$source_body_file" || { echo 'FAIL: single-delete must drop the node registry'; failures=$((failures + 1)); }
    grep -Fq 'users_reg_prune_stale_after_deploy' "$source_body_file" || { echo 'FAIL: stale registry prune after deploy missing (O1)'; failures=$((failures + 1)); }
    grep -Fq 'users_reg_prune_stale_after_deploy xray' "$source_body_file" || { echo 'FAIL: xray deploy must prune stale registries (O1)'; failures=$((failures + 1)); }
    grep -Fq 'users_reg_prune_stale_after_deploy sing-box' "$source_body_file" || { echo 'FAIL: sing-box deploy must prune stale registries (O1)'; failures=$((failures + 1)); }
    grep -Fq '6) swap_menu ;;' "$source_body_file" || { echo 'FAIL: toolbox 6 must open the swap submenu'; failures=$((failures + 1)); }
    grep -Fq '/usr/local/sbin/abox-zram' "$source_body_file" || { echo 'FAIL: zram helper path missing'; failures=$((failures + 1)); }
    grep -q '^swapfile_active_state() {' "$0" || { echo 'FAIL: Swap activity query must have explicit three-state error handling'; failures=$((failures + 1)); }
    grep -Fq '无法可靠判断 /swapfile 当前是否已激活' "$source_body_file" || { echo 'FAIL: Swap activity query failure must fail closed'; failures=$((failures + 1)); }
    swapon() { printf '%s\n' '/swapfile'; }
    [[ "$(swapfile_active_state; echo "$?")" == '0' ]] || { echo 'FAIL: Swap activity query active state'; failures=$((failures + 1)); }
    swapon() { :; }
    [[ "$(swapfile_active_state; echo "$?")" == '1' ]] || { echo 'FAIL: Swap activity query inactive state'; failures=$((failures + 1)); }
    swapon() { return 42; }
    # U204: a swapon failure falls back to /proc/swaps instead of
    # reporting query failure; the expectation follows /proc/swaps.
    # When /proc/swaps is unreadable the query fails closed (2).
    if [[ ! -r /proc/swaps ]]; then _swap_expect=2; elif grep -qE '^/swapfile[[:space:]]' /proc/swaps 2>/dev/null; then _swap_expect=0; else _swap_expect=1; fi
    [[ "$(swapfile_active_state; echo "$?")" == "$_swap_expect" ]] || { echo 'FAIL: Swap activity query swapon-failure fallback'; failures=$((failures + 1)); }
    unset -f swapon
    grep -q '^fstab_path_is_safe() {' "$0" || { echo 'FAIL: swap fstab trust helper missing'; failures=$((failures + 1)); }
    grep -q 'fstab_path_is_safe || return 1' "$source_body_file" || { echo 'FAIL: swap removal must validate trusted fstab before mutation'; failures=$((failures + 1)); }
    grep -q '保留 fstab 备份' "$source_body_file" || { echo 'FAIL: Swap rollback must retain fstab recovery material when rollback fails'; failures=$((failures + 1)); }
    grep -q 'Swap 无法安全关闭' "$source_body_file" || { echo 'FAIL: Swap setup must not delete an active swapfile when swapoff fails'; failures=$((failures + 1)); }
    grep -q '检测到全局 IPv6' "$source_body_file" || { echo 'FAIL: IPv6 manual HY2 hop guard missing'; failures=$((failures + 1)); }
    grep -q 'tr_msg cl_f2b_restart_reset' "$source_body_file" || { echo 'FAIL: environment reset must restart Fail2Ban after removing A-Box jail'; failures=$((failures + 1)); }
    grep -Fq '[[ "$value" != *[[:cntrl:]]* ]]' "$source_body_file" || { echo 'FAIL: secret validator must reject control characters'; failures=$((failures + 1)); }
    grep -Fq '[[ "$fmt" != *' "$source_body_file" || { echo 'FAIL: translation printf must reject backslash escapes'; failures=$((failures + 1)); }
    ( tr_msg() { printf '%s' 'bad\q %s'; }; tprintf synthetic test ) >/dev/null 2>&1 && { echo 'FAIL: tprintf accepted a backslash escape in a translation'; failures=$((failures + 1)); }
    ( tr_msg() { printf '%s' '%n'; }; tprintf synthetic ) >/dev/null 2>&1 && { echo 'FAIL: tprintf accepted an unsupported printf conversion'; failures=$((failures + 1)); }
    ( tr_msg() { printf '%s' '%s %s'; }; tprintf synthetic only-one ) >/dev/null 2>&1 && { echo 'FAIL: tprintf accepted mismatched placeholder arguments'; failures=$((failures + 1)); }
    grep -q 'command -v ss >/dev/null 2>&1 || return 2' "$source_body_file" || { echo 'FAIL: health probe socket checker must distinguish unavailable ss'; failures=$((failures + 1)); }
    grep -q '2) exit 0 ;;' "$source_body_file" || { echo 'FAIL: health probe must not restart services when ss is unavailable'; failures=$((failures + 1)); }
    grep -q 'PY_TRAFFIC_DASH' "$source_body_file" || { echo 'FAIL: main vnStat total must use exact integer arithmetic'; failures=$((failures + 1)); }
    grep -q 'PY_VNSTAT_TOTAL_MONITOR' "$source_body_file" || { echo 'FAIL: traffic monitor vnStat total must use exact integer arithmetic'; failures=$((failures + 1)); }
    grep -q 'PY_TRAFFIC_COMPARE' "$source_body_file" || { echo 'FAIL: traffic quota comparison must use exact integer arithmetic'; failures=$((failures + 1)); }
    ! grep -q '^    \[\[ -d /run/systemd/system \]\] && return 0$' "$0" || { echo 'FAIL: systemd detection must not trust /run/systemd/system alone'; failures=$((failures + 1)); }
    cron_guard_in=$(mktemp /tmp/A-Box-selftest-cron-in.XXXXXX) || { echo 'FAIL: cron regression temp creation'; failures=$((failures + 1)); selftest_cleanup; return 1; }
    cron_guard_out=$(mktemp /tmp/A-Box-selftest-cron-out.XXXXXX) || { rm -f "$cron_guard_in"; echo 'FAIL: cron regression temp creation'; failures=$((failures + 1)); selftest_cleanup; return 1; }
    printf '%s\n' '*/5 * * * * /usr/local/bin/user-job /etc/ddr/geo_update.sh --keep-this' '* * * * * /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1' '# A-Box GEO BEGIN' '0 3 * * 1 /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1' '# A-Box GEO END' > "$cron_guard_in"
    strip_abox_cron_blocks_from_file "$cron_guard_in" "$cron_guard_out" GEO || { rm -f "$cron_guard_in" "$cron_guard_out"; echo 'FAIL: cron exact-command cleanup'; failures=$((failures + 1)); }
    grep -Fxq '*/5 * * * * /usr/local/bin/user-job /etc/ddr/geo_update.sh --keep-this' "$cron_guard_out" || { echo 'FAIL: cron cleanup removed a user-owned command containing an A-Box path'; failures=$((failures + 1)); }
    grep -Fxq '* * * * * /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1' "$cron_guard_out" || { echo 'FAIL: unmarked legacy-like GEO cron must be preserved'; failures=$((failures + 1)); }
    ! grep -Fxq '0 3 * * 1 /usr/bin/flock -n /run/A-Box-geo-cron.lock /bin/bash /etc/ddr/geo_update.sh >/dev/null 2>&1' "$cron_guard_out" || { echo 'FAIL: marked A-Box GEO cron block was not removed'; failures=$((failures + 1)); }
    rm -f "$cron_guard_in" "$cron_guard_out"
    # The source snapshot above is the same filtered body (self-test region
    # excluded, except that it also omits the `main() {` line itself, which
    # neither crontab pattern can match); reuse it instead of building a
    # second filtered copy.
    grep -Eq 'crontab -l[^\n]*\|.*\|\| true' "$source_body_file" && { echo 'FAIL: crontab read failure must not be swallowed'; failures=$((failures + 1)); return 1; }
    grep -Eq 'remove_abox_cron_block GEO 2>/dev/null \|\| true' "$source_body_file" && { echo 'FAIL: Geo cron removal failure must not be swallowed'; failures=$((failures + 1)); return 1; }
    _devfd_pattern='/dev/''fd/3'; ! grep -q "python3 ${_devfd_pattern}" "$source_body_file" || { echo 'FAIL: /dev/fd/3 portability dependency remains'; failures=$((failures + 1)); }
    unset _devfd_pattern
    [[ "$(port_spec_for_firewalld 20000:25000)" == '20000-25000' ]] || { echo 'FAIL: firewalld range conversion'; failures=$((failures + 1)); }
    [[ "$(port_list_for_firewalld '443,2053:2500')" == '443,2053-2500' ]] || { echo 'FAIL: firewalld comma-separated port/range conversion'; failures=$((failures + 1)); }
    if ! (
        firewall_backend() { printf '%s\n' iptables; }
        mock_iptables() { return 0; }
        ip6tables() { printf '%s\n' 'ip6tables: Table does not exist (do you need to insmod?)' >&2; return 1; }
        # P0-01 verified: test real _iptables_q / _iptables_do in main script
        IPT=mock_iptables; IPT6=ip6tables
        has_ipv6() { return 1; }
        clean_nat_rules
    ); then
        echo 'FAIL: clean_nat_rules must tolerate an unavailable IPv6 NAT table'; failures=$((failures + 1))
    fi
    if ! (
        firewall_backend() { printf '%s\n' iptables; }
        mock_iptables() { return 0; }
        ip6tables() { printf '%s\n' 'ip6tables: Permission denied' >&2; return 1; }
        IPT=mock_iptables; IPT6=ip6tables
        has_ipv6() { return 1; }
        ! clean_nat_rules
    ); then
        echo 'FAIL: clean_nat_rules must remain fail-closed on IPv6 firewall permission errors'; failures=$((failures + 1))
    fi
    if ! (
        firewall_backend() { printf '%s\n' iptables; }
        mock_iptables() { return 0; }
        ip6tables() { printf '%s\n' "ip6tables v1.8.7 (nf_tables): table 'nat' is incompatible, use 'nft' tool." >&2; return 1; }
        IPT=mock_iptables; IPT6=ip6tables
        has_ipv6() { return 1; }
        clean_nat_rules
    ); then
        echo 'FAIL: clean_nat_rules must tolerate an nft-incompatible IPv6 NAT table'; failures=$((failures + 1))
    fi
    if ! (
        firewall_backend() { printf '%s\n' iptables; }
        mock_iptables() { return 0; }
        ip6tables() { printf '%s\n' "can't initialize ip6tables table 'nat': Permission denied (you must be root)" >&2; return 1; }
        IPT=mock_iptables; IPT6=ip6tables
        has_ipv6() { return 1; }
        ! clean_nat_rules
    ); then
        echo 'FAIL: clean_nat_rules must remain fail-closed on ip6tables initialization permission errors'; failures=$((failures + 1))
    fi
    mkdir -p "$tmp/atomic-dest-dir"
    printf '%s\n' 'payload' > "$tmp/atomic.src2"
    assert_bad install_file_atomically "$tmp/atomic.src2" "$tmp/atomic-dest-dir" 600
    printf '%s\n' 'payload' | (write_file_atomically_from_stdin "$tmp/atomic-dest-dir" 600 >/dev/null 2>&1) && { echo 'FAIL: atomic stdin writer accepted destination directory'; failures=$((failures + 1)); }
    printf '%s\n' '#!/usr/bin/env bash' 'echo /etc/ddr/A-Box.sh' > "$tmp/foreign-shortcut.sh"
    ! auxiliary_content_is_abox_managed "$tmp/foreign-shortcut.sh" /usr/local/bin/sb || { echo 'FAIL: arbitrary shortcut mentioning A-Box path was treated as managed'; failures=$((failures + 1)); }
    printf '%s\n' '#!/usr/bin/env bash' 'exec bash /etc/ddr/A-Box.sh "$@"' 'exec sudo bash /etc/ddr/A-Box.sh "$@"' > "$tmp/legacy-shortcut.sh"
    auxiliary_content_is_abox_managed "$tmp/legacy-shortcut.sh" /usr/local/bin/sb || { echo 'FAIL: valid legacy shortcut fingerprint was rejected'; failures=$((failures + 1)); }
    assert_ok valid_port_spec 20000:25000
    assert_bad valid_port_spec 25000:20000
    _arch_case=$(printf '%s\n' 'armv8l')
    grep -Eq 'aarch64\|arm64\) XRAY_ARCH=.*SB_ARCH=.*HY2_ARCH' "$0" || { echo 'FAIL: AArch64 architecture selector missing'; failures=$((failures + 1)); }
    ! grep -Eq 'armv8\*\)' "$0" || { echo 'FAIL: 32-bit armv8 wildcard must not map to arm64'; failures=$((failures + 1)); }
    unset _arch_case
    for _hy2_uri_case in \
        443 \
        20000-25000 \
        443,8443 \
        443,20000-25000 \
        443,20000-25000,30000-30010 \
        1234,5678,9012 \
        1234,5000-6000,7044,8000-9000; do
        assert_ok valid_hy2_uri_ports "$_hy2_uri_case" || { echo "FAIL: HY2 multi-port validator rejected $_hy2_uri_case"; failures=$((failures + 1)); }
        HY2_URI_PORTS="$_hy2_uri_case"
        HY2_HOP=false
        HY2_HOP_IMPL=none
        if [[ "$(build_hy2_uri_endpoint)" != "$_hy2_uri_case"$'\t' ]]; then
            echo "FAIL: HY2 URI builder mismatch for $_hy2_uri_case"
            failures=$((failures + 1))
        fi
    done
    unset _hy2_uri_case HY2_URI_PORTS HY2_HOP HY2_HOP_IMPL
    assert_bad valid_hy2_uri_ports 443,20000:25000
    assert_bad valid_hy2_uri_ports 443,65535-65536
    assert_ok valid_hy2_clash_ports 20000-25000
    assert_ok valid_hy2_clash_ports 443
    assert_bad valid_hy2_clash_ports 20000:25000
    assert_bad valid_hy2_clash_ports 65535-65536
    assert_ok valid_hy2_sb_ports 20000:25000
    assert_bad valid_hy2_sb_ports 20000-25000
    _x25519_pair=$'PrivateKey: private-test\nPassword (PublicKey): public-test\n'
    [[ "$(parse_x25519_keypair_output "$_x25519_pair")" == $'private-test\tpublic-test' ]] || { echo 'FAIL: Xray x25519 output parser'; failures=$((failures + 1)); }
    _x25519_pair=$'Private key: private-test-2\nPublic key: public-test-2\n'
    [[ "$(parse_x25519_keypair_output "$_x25519_pair")" == $'private-test-2\tpublic-test-2' ]] || { echo 'FAIL: Xray x25519 alternate-label parser'; failures=$((failures + 1)); }
    HY2_URI_PORTS='443,20000-25000'; HY2_HOP=true; HY2_HOP_IMPL=manual
    [[ "$(build_hy2_uri_endpoint)" == $'443,20000-25000\t' ]] || { echo 'FAIL: manual HY2 URI endpoint must serialize documented multi-port address directly'; failures=$((failures + 1)); }
    HY2_URI_PORTS='443'; HY2_HOP=true; HY2_HOP_IMPL=manual; HY2_BASE_PORT=443; HY2_RANGE_START=20000; HY2_RANGE_END=25000
    [[ "$(build_hy2_uri_endpoint)" == $'443\t' ]] || { echo 'FAIL: explicit persisted HY2 URI port must remain canonical'; failures=$((failures + 1)); }
    unset HY2_URI_PORTS
    [[ "$(build_hy2_uri_endpoint)" == $'443,20000-25000\t' ]] || { echo 'FAIL: manual HY2 URI endpoint must derive combined documented multi-port address'; failures=$((failures + 1)); }
    HY2_URI_PORTS='20000-25000'; HY2_HOP=true; HY2_HOP_IMPL=official
    [[ "$(build_hy2_uri_endpoint)" == $'20000-25000\t' ]] || { echo 'FAIL: official HY2 URI endpoint must preserve port range'; failures=$((failures + 1)); }
    unset HY2_URI_PORTS HY2_HOP HY2_HOP_IMPL HY2_RANGE_START HY2_RANGE_END HY2_BASE_PORT
    ( ip() { printf '%s\n' '8.8.8.8 dev wg0 src 192.0.2.2'; }; default_route_uses_warp ) || { echo 'FAIL: overlay default-route detector'; failures=$((failures + 1)); }
    ( ip() { printf '%s\n' '8.8.8.8 dev CloudflareWARP src 192.0.2.2'; }; default_route_uses_warp ) || { echo 'FAIL: CloudflareWARP default-route detector'; failures=$((failures + 1)); }
    ! ( ip() { printf '%s\n' '8.8.8.8 dev eth0 src 192.0.2.2'; }; default_route_uses_warp ) || { echo 'FAIL: ordinary default-route detector false positive'; failures=$((failures + 1)); }
    grep -q '^hysteria_official_hop_firewall_ok() {' "$0" || { echo 'FAIL: official HY2 hop firewall verifier missing'; failures=$((failures + 1)); }
    grep -Fq 'hysteria_official_hop_firewall_ok "$HY2_RANGE_START" "$HY2_RANGE_END" "$HY2_MONITOR_PORT"' "$source_body_file" || { echo 'FAIL: official HY2 deployment must verify hop firewall rules after startup'; failures=$((failures + 1)); }
    CORE=singbox MODE=HY2 HY2_BASE_PORT=443 HY2_UP=100 HY2_DOWN=1000 HY2_HOP=false HY2_HOP_IMPL=none
    validate_abox_env_semantics >/dev/null 2>&1 || { echo 'FAIL: valid HY2 bandwidth state'; failures=$((failures + 1)); }
    HY2_UP='not-a-number'
    validate_abox_env_semantics >/dev/null 2>&1 && { echo 'FAIL: invalid HY2 bandwidth state accepted'; failures=$((failures + 1)); }
    unset CORE MODE HY2_BASE_PORT HY2_UP HY2_DOWN HY2_HOP HY2_HOP_IMPL
    if selftest_has python3; then
    assert_ok valid_github_download_url XTLS/Xray-core https://github.com/XTLS/Xray-core/releases/download/v26.9.30/Xray-linux-64.zip v26.9.30
    assert_ok valid_github_download_url HyNetworks/hysteria https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64 app/v2.13.0 hysteria-linux-amd64
    assert_bad valid_github_download_url HyNetworks/hysteria https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/../../evil app/v2.13.0 hysteria-linux-amd64
    assert_bad valid_github_download_url HyNetworks/hysteria 'https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64?x=1' app/v2.13.0 hysteria-linux-amd64
    assert_bad valid_github_download_url HyNetworks/hysteria 'https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-arm64' app/v2.13.0 hysteria-linux-amd64
    assert_bad valid_github_download_url XTLS/Xray-core https://github.com/XTLS/Xray-core/releases/download/v26.9.29/Xray-linux-64.zip v26.9.30
    assert_bad valid_github_download_url XTLS/Xray-core https://github.com/SagerNet/sing-box/releases/download/v1.14.1/Xray-linux-64.zip v26.9.30
    else
        selftest_note 'asset-pinned GitHub URL validator suite skipped (python3 missing)'
        assert_ok valid_github_download_url XTLS/Xray-core https://github.com/XTLS/Xray-core/releases/download/v26.9.30/Xray-linux-64.zip v26.9.30
    fi

    # Non-GitHub Geo URLs must be refused (digest trust model); old file preserved.
    geo_existing="$tmp/geo-existing.dat"
    printf '%s' 'OLD-GEO-CONTENT' > "$geo_existing"
    if (
        fetch_geo_data geoip.dat https://example.invalid/geo "$geo_existing" >/dev/null 2>&1
    ); then
        echo 'FAIL: insecure non-GitHub Geo URL unexpectedly accepted'
        failures=$((failures + 1))
    fi
    [[ "$(cat "$geo_existing" 2>/dev/null)" == 'OLD-GEO-CONTENT' ]] || { echo 'FAIL: refused Geo update deleted/replaced valid old file'; failures=$((failures + 1)); }

    # M4: the two Geo fixtures below share one immutable 600 KB zero
    # payload and its SHA-256 (the success mock hashes it for the API
    # reply and writes it as the download). Generate once and share;
    # each fixture keeps its own destination file and assertions.
    geo_payload="$tmp/geo-payload-600k.bin"
    dd if=/dev/zero of="$geo_payload" bs=600000 count=1 status=none || { echo 'FAIL: shared Geo fixture payload'; failures=$((failures + 1)); }
    geo_payload_sha=$(sha256sum < "$geo_payload" 2>/dev/null | awk '{print $1}')
    # GitHub Geo path: digest must fail closed and preserve old content.
    geo_bad_digest="$tmp/geo-bad-digest.dat"
    printf '%s' 'OLD-GEO-CONTENT' > "$geo_bad_digest"
    if (
        github_api_get() {
            printf '%s
' '{"tag_name":"latest","assets":[{"name":"geoip.dat","browser_download_url":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/latest/geoip.dat","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
        }
        curl() {
            local out=''
            while (($#)); do
                case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
            done
            printf '%s' 'bad-download' > "$out"
            return 0
        }
        fetch_geo_data geoip.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat' "$geo_bad_digest" >/dev/null 2>&1
    ); then
        echo 'FAIL: Geo digest failure unexpectedly succeeded'
        failures=$((failures + 1))
    fi
    [[ "$(cat "$geo_bad_digest" 2>/dev/null)" == 'OLD-GEO-CONTENT' ]] || { echo 'FAIL: failed Geo digest update deleted/replaced valid old file'; failures=$((failures + 1)); }

    # Valid GitHub Geo replacement after digest+size checks.
    geo_success="$tmp/geo-success.dat"
    printf '%s' 'OLD-GEO-CONTENT' > "$geo_success"
    if ! (
        github_api_get() {
            jq -nc --arg dig "$geo_payload_sha" '{tag_name:"latest",assets:[{name:"geosite.dat",browser_download_url:"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/latest/geosite.dat",digest:("sha256:"+$dig)}]}'
        }
        curl() {
            local out=''
            while (($#)); do
                case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
            done
            cat "$geo_payload" > "$out"
        }
        fetch_geo_data geosite.dat 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat' "$geo_success" >/dev/null 2>&1
    ); then
        echo 'FAIL: valid Geo replacement failed'
        failures=$((failures + 1))
    fi
    [[ "$(stat -c %s "$geo_success" 2>/dev/null || echo 0)" == '600000' ]] || { echo 'FAIL: valid Geo replacement was not atomically committed'; failures=$((failures + 1)); }

    # GEO-F4: validate_geo_payload accepts a large non-HTML payload
    # and rejects small, HTML-headed and missing ones.
    if ! (
        _vgp_tmp=$(umask 077; mktemp -d) || exit 71
        dd if=/dev/zero of="$_vgp_tmp/big" bs=600000 count=1 status=none || exit 72
        validate_geo_payload "$_vgp_tmp/big" || exit 73
        dd if=/dev/zero of="$_vgp_tmp/small" bs=100 count=1 status=none || exit 74
        validate_geo_payload "$_vgp_tmp/small" && exit 75
        printf '<!DOCTYPE html><html></html>' > "$_vgp_tmp/html-head" || exit 76
        dd if=/dev/zero bs=600000 count=1 status=none >> "$_vgp_tmp/html-head" || exit 77
        validate_geo_payload "$_vgp_tmp/html-head" && exit 78
        validate_geo_payload "$_vgp_tmp/missing" && exit 79
        rm -rf -- "$_vgp_tmp"
    ); then
        echo 'FAIL: validate_geo_payload must accept a large non-HTML payload and reject small/HTML/missing ones'; failures=$((failures + 1))
    fi

    # Core download helper must preserve an existing destination until the replacement
    # has passed structural and digest validation.
    github_existing="$tmp/existing-core.zip"
    printf '%s' 'OLD-CORE' > "$github_existing"
    if (
        github_api_get() {
            printf '%s\n' '{"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://github.com/XTLS/Xray-core/releases/download/v26.9.30/Xray-linux-64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
        }
        curl() {
            local out='' _w=''
            while (($#)); do
                case "$1" in
                    -o) out="$2"; shift 2 ;;
                    -w) _w=1; shift 2 ;;
                    -w*) _w=1; shift ;;
                    *) shift ;;
                esac
            done
            # M1: the fetch banner probes availability with `curl -w
            # '%{http_code}'` and retries 3x with `sleep 1` on a non-200
            # code. A mock that prints nothing made the probe read an empty
            # code and burn 2 s of sleep (the 2.37 s S2 hotspot was the
            # sleeps, not network: the mock does intercept the calls).
            # Emit 200 for -w probes (banner text only; the invalid-asset
            # verdict below is unchanged). Download legs carry no -w, so
            # their stdout stays empty as before.
            [[ -n "$_w" ]] && printf '200'
            printf '%s' 'invalid-archive' > "$out"
            return 0
        }
        XRAY_ARCH=64 ABOX_XRAY_VERSION=v26.9.30 fetch_github_release XTLS/Xray-core xray_core.zip "$github_existing" > "$tmp/github-fixture-out" 2>&1
    ); then
        echo 'FAIL: invalid GitHub asset injection unexpectedly succeeded'
        failures=$((failures + 1))
    fi
    # M1: the banner above must have seen the mocked HTTP 200s. If it
    # reports unavailable, either the mock regressed or production added
    # an unmocked probe (real network inside self-test).
    grep -q 'release tag XTLS/Xray-core@v26.9.30: available (HTTP 200)' "$tmp/github-fixture-out" 2>/dev/null || { echo 'FAIL: self-test fetch banner must see mocked HTTP 200 (real network or mock regression)'; failures=$((failures + 1)); }
    [[ "$(cat "$github_existing" 2>/dev/null)" == 'OLD-CORE' ]] || { echo 'FAIL: failed core download deleted/replaced existing destination'; failures=$((failures + 1)); }
    [[ "$(msg 'literal\nbackslash\ttext')" == $'literal\\nbackslash\\ttext' ]] || { echo 'FAIL: msg must not reinterpret backslash escapes'; failures=$((failures + 1)); }
    [[ "$(msg "${RED}X${NC}")" == $'\033[0;31mX\033[0m' ]] || { echo 'FAIL: ANSI color escapes must remain functional'; failures=$((failures + 1)); }

    if ! (
        _curl_counter="$tmp/github-retry-count"
        printf '0\n' > "$_curl_counter"
        curl() {
            local out=''; while (($#)); do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
            local n; n=$(cat "$_curl_counter"); n=$((n + 1)); printf '%s\n' "$n" > "$_curl_counter"
            printf '%s\n' "retry-${n}" > "$out"
            if (( n == 1 )); then printf '500'; else printf '200'; fi
        }
        export GITHUB_API_RETRY_DELAY=0
        [[ "$(github_api_get https://example.invalid/selftest-retry)" == 'retry-2' && "$(cat "$_curl_counter")" == 2 ]]
    ); then echo 'FAIL: GitHub API must retry transient 5xx once'; failures=$((failures + 1)); fi
    if ! (
        _curl_counter="$tmp/github-403-count"
        printf '0\n' > "$_curl_counter"
        curl() {
            local out=''; while (($#)); do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
            local n; n=$(cat "$_curl_counter"); n=$((n + 1)); printf '%s\n' "$n" > "$_curl_counter"
            : > "$out"; printf '403'
        }
        unset GITHUB_TOKEN
        export GITHUB_API_RETRY_DELAY=0
        ! github_api_get https://example.invalid/selftest-403 >/dev/null 2>&1 && [[ "$(cat "$_curl_counter")" == 1 ]]
    ); then echo 'FAIL: GitHub API must not retry 403'; failures=$((failures + 1)); fi
    unset GITHUB_API_RETRY_DELAY
    local redacted_json redacted_headers
    redacted_json=$(printf '%s\n' '{"password":"secret","nested":{"token":"abc"},"uri":"vless://abc@host:443"}' | redact_secrets_stream)
    grep -q '\*\*\*REDACTED\*\*\*' <<< "$redacted_json" || { echo 'FAIL: JSON secret redaction'; failures=$((failures + 1)); }
    grep -q '\*\*\*CLIENT_LINK_REDACTED\*\*\*' <<< "$redacted_json" || { echo 'FAIL: client URI redaction'; failures=$((failures + 1)); }
    grep -qE 'secret|vless://abc' <<< "$redacted_json" && { echo 'FAIL: redaction leaked secret'; failures=$((failures + 1)); }
    redacted_json=$(printf '%s\n' '{"public_key":"pub-secret","short_id":"deadbeef","fingerprint":"cafebabe","normal":"visible"}' | redact_secrets_stream)
    [[ "$redacted_json" != *pub-secret* && "$redacted_json" != *deadbeef* && "$redacted_json" != *cafebabe* && "$redacted_json" == *visible* ]] || { echo 'FAIL: diagnostic redaction leaked public key/short id/fingerprint'; failures=$((failures + 1)); }
    redacted_headers=$(printf '%s\n' 'Authorization: Bearer top-secret-token' 'Cookie: sid=top-secret-cookie' 'normal: visible' | redact_secrets_stream)
    [[ "$redacted_headers" != *top-secret-token* && "$redacted_headers" != *top-secret-cookie* && "$redacted_headers" == *visible* ]] || { echo 'FAIL: diagnostic redaction leaked authorization/cookie header values'; failures=$((failures + 1)); }
    grep -q 'visible' <<< "$redacted_headers" || { echo 'FAIL: redaction removed non-secret diagnostic data'; failures=$((failures + 1)); }
    redacted_embedded=$(printf '%s\n' '{"message":"Authorization: Bearer embedded-json-token", "debug":"api_key=embedded-api-secret", "safe":"visible"}' | redact_secrets_stream)
    [[ "$redacted_embedded" != *embedded-json-token* && "$redacted_embedded" != *embedded-api-secret* && "$redacted_embedded" == *visible* ]] || { echo 'FAIL: JSON string-leaf secret redaction'; failures=$((failures + 1)); }

    printf 'new-content
' > "$tmp/atomic.src"
    printf 'old-content
' > "$tmp/atomic.dest"
    assert_ok install_file_atomically "$tmp/atomic.src" "$tmp/atomic.dest" 600
    mkdir -m 750 "$tmp/atomic-parent" || { echo 'FAIL: atomic parent setup'; failures=$((failures + 1)); }
    assert_ok install_file_atomically "$tmp/atomic.src" "$tmp/atomic-parent/kept-mode" 600
    [[ "$(stat -c %a "$tmp/atomic-parent" 2>/dev/null)" == 750 ]] || { echo 'FAIL: install_file_atomically changed an existing parent directory mode'; failures=$((failures + 1)); }
    ln -s "$tmp/atomic-parent" "$tmp/atomic-parent-link"
    assert_bad install_file_atomically "$tmp/atomic.src" "$tmp/atomic-parent-link/dest" 600
    mkdir -p "$tmp/nested-real"
    ln -s "$tmp/nested-real" "$tmp/nested-link"
    assert_bad install_file_atomically "$tmp/atomic.src" "$tmp/nested-link/deeper/dest" 600
    printf '%s\n' 'nested' | (write_file_atomically_from_stdin "$tmp/nested-link/deeper/state" 600 >/dev/null 2>&1) && { echo 'FAIL: atomic stdin writer traversed a nested parent symlink'; failures=$((failures + 1)); }
    mkdir -p "$tmp/sidecar-real/nested"
    ln -s "$tmp/sidecar-real" "$tmp/sidecar-link"
    assert_bad write_private_sidecar "$tmp/sidecar-link/nested/sidecar" 'secret'
    mkdir "$tmp/cert-key-dir"
    assert_bad generate_self_signed_cert_atomically "$tmp/cert-key-dir" "$tmp/cert.crt" localhost
    # Archive extractors must never remove a caller-owned pre-existing destination
    # when rejecting an extraction. This is a regression test for a destructive
    # cleanup bug found during the independent v70/v71 archive audit.
    if selftest_has python3; then
    python3 -I - "$tmp" <<'PY_SELFTEST_ARCHIVE_CREATE' >/dev/null 2>&1 || { echo 'FAIL: archive regression fixture creation'; failures=$((failures + 1)); }
import io, os, sys, tarfile, zipfile
base=sys.argv[1]
with zipfile.ZipFile(os.path.join(base, 'extract-regress.zip'), 'w') as z:
    z.writestr('target.txt', 'new-content')
with tarfile.open(os.path.join(base, 'extract-regress.tar'), 'w') as t:
    data=b'new-content'
    ti=tarfile.TarInfo('target.txt'); ti.size=len(data)
    t.addfile(ti, io.BytesIO(data))
PY_SELFTEST_ARCHIVE_CREATE
    printf '%s\n' 'preserve-me' > "$tmp/extract-preexisting"
    assert_bad extract_zip_member_safely "$tmp/extract-regress.zip" target.txt "$tmp/extract-preexisting"
    [[ -f "$tmp/extract-preexisting" && "$(cat "$tmp/extract-preexisting")" == 'preserve-me' ]] || { echo 'FAIL: ZIP rejection removed pre-existing destination'; failures=$((failures + 1)); }
    rm -f "$tmp/extract-new"
    assert_ok extract_zip_member_safely "$tmp/extract-regress.zip" target.txt "$tmp/extract-new"
    [[ "$(cat "$tmp/extract-new")" == 'new-content' ]] || { echo 'FAIL: ZIP successful extraction content'; failures=$((failures + 1)); }
    printf '%s\n' 'preserve-me' > "$tmp/extract-preexisting"
    assert_bad extract_tar_regular_basename_safely "$tmp/extract-regress.tar" target.txt "$tmp/extract-preexisting"
    [[ -f "$tmp/extract-preexisting" && "$(cat "$tmp/extract-preexisting")" == 'preserve-me' ]] || { echo 'FAIL: TAR rejection removed pre-existing destination'; failures=$((failures + 1)); }
    python3 -I - "$tmp" <<'PY_SELFTEST_TAR_GZ_CREATE' >/dev/null 2>&1 || { echo 'FAIL: tar.gz fixture creation'; failures=$((failures + 1)); }
import io, os, sys, tarfile
base=sys.argv[1]
with tarfile.open(os.path.join(base, 'extract-regress.tar.gz'), 'w:gz') as t:
    data=b'new-content'
    ti=tarfile.TarInfo('target.txt'); ti.size=len(data)
    t.addfile(ti, io.BytesIO(data))
PY_SELFTEST_TAR_GZ_CREATE
    rm -f "$tmp/extract-new-tar"
    assert_ok extract_tar_regular_basename_safely "$tmp/extract-regress.tar.gz" target.txt "$tmp/extract-new-tar"
    [[ "$(cat "$tmp/extract-new-tar")" == 'new-content' ]] || { echo 'FAIL: TAR successful extraction content'; failures=$((failures + 1)); }
    else
        selftest_note 'archive regression tests skipped (python3 missing)'
    fi
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$tmp/atomic.src" "$tmp/atomic.dest" || { echo 'FAIL: atomic file install content'; failures=$((failures + 1)); }
    else
        [[ "$(cat "$tmp/atomic.src" 2>/dev/null)" == "$(cat "$tmp/atomic.dest" 2>/dev/null)" ]] || { echo 'FAIL: atomic file install content'; failures=$((failures + 1)); }
        selftest_note 'cmp missing; used cat equality for atomic install content check'
    fi
    rollback_binary_install "$tmp/atomic.dest" '' >/dev/null 2>&1 || true
    [[ ! -e "$tmp/atomic.dest" ]] || { echo 'FAIL: first-install rollback must remove destination'; failures=$((failures + 1)); }

    mkdir -p "$tmp/archive-good/root/etc/ddr" "$tmp/archive-good/meta"
    printf 'CORE=xray
' > "$tmp/archive-good/root/etc/ddr/.env"
    printf '%s
' 'A-Box backup manifest v3' > "$tmp/archive-good/meta/manifest.version"
    : > "$tmp/archive-good/meta/managed-paths.txt"
    : > "$tmp/archive-good/meta/services.state"
    printf '%s
' iptables > "$tmp/archive-good/meta/firewall.backend"
    : > "$tmp/archive-good/meta/iptables.snapshot"
    : > "$tmp/archive-good/meta/ip6tables.snapshot"
    : > "$tmp/archive-good/meta/cron.abox.txt"
    printf '%s\n' 'sentinel' > "$tmp/archive-good/meta/manifest-sentinel.txt"
    ln -s "$tmp/archive-good/meta/manifest-sentinel.txt" "$tmp/archive-good/meta/manifest.sha256.tmp"
    if create_backup_manifest "$tmp/archive-good" "$tmp/archive-good/meta/manifest.sha256" >/dev/null 2>&1; then
        echo 'FAIL: backup manifest generation accepted a predictable temp-file symlink'
        failures=$((failures + 1))
    fi
    [[ "$(cat "$tmp/archive-good/meta/manifest-sentinel.txt" 2>/dev/null)" == 'sentinel' ]] || { echo 'FAIL: backup manifest generation followed predictable temp-file symlink'; failures=$((failures + 1)); }
    rm -f "$tmp/archive-good/meta/manifest.sha256.tmp"
    if selftest_has python3; then
        assert_ok create_backup_manifest "$tmp/archive-good" "$tmp/archive-good/meta/manifest.sha256"
        assert_bad create_backup_manifest "$tmp/nonexistent-dir" "$tmp/out.sha256"
        selftest_pack_tar_gz "$tmp/archive-good" "$tmp/good.tar.gz" 1 || { echo 'FAIL: good backup fixture tar creation'; failures=$((failures + 1)); }
        assert_ok validate_backup_archive "$tmp/good.tar.gz"
    else
        selftest_note 'backup archive validation skipped (python3 missing)'
    fi
    if (( EUID == 0 )) && id nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
        old_hy_user="$ABOX_RUNTIME_HYSTERIA_USER"
        old_hy_group="$ABOX_RUNTIME_HYSTERIA_GROUP"
        ABOX_RUNTIME_HYSTERIA_USER=nobody
        ABOX_RUNTIME_HYSTERIA_GROUP=nogroup
        acme_runtime_fixture="$tmp/archive-acme-runtime"
        mkdir -p "$acme_runtime_fixture/root/etc/ddr" "$acme_runtime_fixture/root/etc/hysteria/acme" "$acme_runtime_fixture/meta"
        printf '%s\n' 'CORE=hysteria' > "$acme_runtime_fixture/root/etc/ddr/.env"
        printf '%s\n' 'ACME-CERT' > "$acme_runtime_fixture/root/etc/hysteria/acme/fullchain.pem"
        printf '%s\n' 'A-Box backup manifest v3' > "$acme_runtime_fixture/meta/manifest.version"
        : > "$acme_runtime_fixture/meta/managed-paths.txt"
        : > "$acme_runtime_fixture/meta/services.state"
        printf '%s\n' iptables > "$acme_runtime_fixture/meta/firewall.backend"
        : > "$acme_runtime_fixture/meta/iptables.snapshot"
        : > "$acme_runtime_fixture/meta/ip6tables.snapshot"
        : > "$acme_runtime_fixture/meta/cron.abox.txt"
        chown root:nogroup "$acme_runtime_fixture/root/etc/hysteria" "$acme_runtime_fixture/root/etc/hysteria/acme"
        chmod 750 "$acme_runtime_fixture/root/etc/hysteria"
        chmod 770 "$acme_runtime_fixture/root/etc/hysteria/acme"
        chown nobody:nogroup "$acme_runtime_fixture/root/etc/hysteria/acme/fullchain.pem"
        chmod 600 "$acme_runtime_fixture/root/etc/hysteria/acme/fullchain.pem"
        if selftest_has python3; then
            create_backup_manifest "$acme_runtime_fixture" "$acme_runtime_fixture/meta/manifest.sha256" || { echo 'FAIL: ACME runtime fixture manifest creation'; failures=$((failures + 1)); }
            selftest_pack_tar_gz "$acme_runtime_fixture" "$tmp/acme-runtime-good.tar.gz" || { echo 'FAIL: ACME runtime fixture tar creation'; failures=$((failures + 1)); }
            assert_ok validate_backup_archive "$tmp/acme-runtime-good.tar.gz" || { echo 'FAIL: legal Hysteria ACME runtime-owned backup rejected'; failures=$((failures + 1)); }
            # R-01 regression: 1770 (sticky) ACME dir must also validate.
            chmod 1770 "$acme_runtime_fixture/root/etc/hysteria/acme"
            create_backup_manifest "$acme_runtime_fixture" "$acme_runtime_fixture/meta/manifest.sha256" || { echo 'FAIL: ACME 1770 fixture manifest creation'; failures=$((failures + 1)); }
            selftest_pack_tar_gz "$acme_runtime_fixture" "$tmp/acme-1770-good.tar.gz" || { echo 'FAIL: ACME 1770 fixture tar creation'; failures=$((failures + 1)); }
            assert_ok validate_backup_archive "$tmp/acme-1770-good.tar.gz" || { echo 'FAIL: Hysteria ACME 1770 backup rejected (R-01 regression)'; failures=$((failures + 1)); }
            python3 -I - "$tmp/acme-runtime-good.tar.gz" <<'PY_TAMPER_ACME' >/dev/null 2>&1
import os,sys,tarfile
arc=sys.argv[1]; out=arc+'.bad'
with tarfile.open(arc,'r:gz') as inp, tarfile.open(out,'w:gz') as outfp:
    for m in inp.getmembers():
        if m.name=='root/etc/hysteria/acme/fullchain.pem': m.uid=12345; m.gid=12345
        outfp.addfile(m, inp.extractfile(m) if m.isfile() else None)
os.replace(out,arc)
PY_TAMPER_ACME
            assert_bad validate_backup_archive "$tmp/acme-runtime-good.tar.gz"
        else
            selftest_note 'ACME runtime backup fixture skipped (python3 missing)'
        fi
        ABOX_RUNTIME_HYSTERIA_USER="$old_hy_user"
        ABOX_RUNTIME_HYSTERIA_GROUP="$old_hy_group"
        unset old_hy_user old_hy_group
    fi

    mkdir -p "$tmp/archive-bad/root/etc/ddr" "$tmp/archive-bad/meta"
    ln -s ../../../../etc/shadow "$tmp/archive-bad/root/etc/ddr/escape"
    if selftest_has python3 || tar --help 2>&1 | grep -Fq -- '--owner='; then
        selftest_pack_tar_gz "$tmp/archive-bad" "$tmp/bad.tar.gz" 1 || { echo 'FAIL: bad backup fixture tar creation'; failures=$((failures + 1)); }
        assert_bad validate_backup_archive "$tmp/bad.tar.gz"
    else
        selftest_note 'malicious backup archive rejection skipped (no python3/GNU tar)'
    fi

    if selftest_has python3; then
        python3 -I - "$tmp" <<'PY_SELFTEST_LEGACY_STATE' >/dev/null 2>&1 || { echo 'FAIL: legacy-state backup fixture creation'; failures=$((failures + 1)); }
import io, os, sys, tarfile
base=sys.argv[1]
names=['.ip-pref','.dns-state','.timezone-state','.fast-mode','.mirror-prefer','.extra-uuids']
def add_dir(tf,name,mode=0o755):
    item=tarfile.TarInfo(name); item.type=tarfile.DIRTYPE; item.mode=mode; item.uid=0; item.gid=0; tf.addfile(item)
def add_file(tf,name,data,mode=0o600):
    b=data.encode(); item=tarfile.TarInfo(name); item.size=len(b); item.mode=mode; item.uid=0; item.gid=0; tf.addfile(item,io.BytesIO(b))
for state in names:
    path=os.path.join(base,'legacy-'+state.replace('.','')+'.tar.gz')
    with tarfile.open(path,'w:gz') as tf:
        for d in ('root','root/etc','root/etc/ddr','meta'):
            add_dir(tf,d)
        add_file(tf,'root/etc/ddr/.env','CORE=xray\n')
        add_file(tf,'root/etc/ddr/'+state,'dual\n')
        add_file(tf,'meta/metadata.txt','legacy fixture\n')
PY_SELFTEST_LEGACY_STATE
        for _legacy_state in .ip-pref .dns-state .timezone-state .fast-mode .mirror-prefer .extra-uuids; do
            _legacy_path="$tmp/legacy-${_legacy_state#.}.tar.gz"
            validate_legacy_backup_archive "$_legacy_path" || { echo "FAIL: legacy backup containing $_legacy_state was rejected"; failures=$((failures + 1)); }
        done
        unset _legacy_state _legacy_path
    else
        selftest_note 'legacy state backup regression skipped (python3 missing)'
    fi

    cat > "$tmp/iptables.snapshot" <<'EOF_SELFTEST_IPT'
*filter
-A INPUT -p tcp --dport 443 -m comment --comment A-Box-443-tcp -j ACCEPT
-A INPUT -p tcp --dport 22 -m comment --comment Other -j ACCEPT
COMMIT
EOF_SELFTEST_IPT
    extract_abox_iptables_rules "$tmp/iptables.snapshot" all > "$tmp/iptables.abox"
    grep -q 'A-Box-443-tcp' "$tmp/iptables.abox" || { echo 'FAIL: A-Box firewall extraction'; failures=$((failures + 1)); }
    grep -q 'Other' "$tmp/iptables.abox" && { echo 'FAIL: foreign firewall rule extraction'; failures=$((failures + 1)); }

    if [[ $EUID -eq 0 ]]; then
        local saved_abox_env="$ABOX_ENV"
        ABOX_ENV="$tmp/state.env"
        printf '%s
' 'CORE=xray' 'MODE=ALL' 'HY2_MASQ_URL=https://www.example.com/' > "$ABOX_ENV"
        chmod 600 "$ABOX_ENV"
        unset CORE MODE HY2_MASQ_URL
        assert_ok load_abox_env "$ABOX_ENV"
        [[ "${CORE:-}|${MODE:-}|${HY2_MASQ_URL:-}" == 'xray|ALL|https://www.example.com/' ]] || { echo 'FAIL: strict state load'; failures=$((failures + 1)); }
        printf '%s\n' 'HY2_DOMAIN=' >> "$ABOX_ENV"
        assert_ok load_abox_env "$ABOX_ENV"
        [[ "${HY2_DOMAIN+x}:${HY2_DOMAIN:-}" == 'x:' ]] || { echo 'FAIL: blank optional state value must round-trip'; failures=$((failures + 1)); }
        local selftest_sentinel="$tmp/state-file-command-sentinel"
        printf 'BAD=$(touch %q)\n' "$selftest_sentinel" >> "$ABOX_ENV"
        assert_bad load_abox_env "$ABOX_ENV"
        [[ ! -e "$selftest_sentinel" ]] || { echo 'FAIL: state file command execution'; failures=$((failures + 1)); }
        ABOX_ENV="$saved_abox_env"
    fi

    if (( $EUID == 0 )); then
        local env_tmp="$tmp/write-env"
        mkdir -m 700 "$env_tmp" || { echo 'FAIL: write_env temp directory'; failures=$((failures + 1)); }
        ABOX_ENV="$env_tmp/.env" ABOX_DIR="$env_tmp" LINK_IP=203.0.113.77 GLOBAL_PUBLIC_IP=198.51.100.8 CORE=xray MODE=ALL \
            write_env >/dev/null 2>&1 || { echo 'FAIL: write_env default CORE/MODE path'; failures=$((failures + 1)); }
        load_abox_env "$env_tmp/.env" >/dev/null 2>&1 || { echo 'FAIL: write_env round-trip state load'; failures=$((failures + 1)); }
        [[ "${CORE:-}|${MODE:-}|${LINK_IP:-}" == 'xray|ALL|203.0.113.77' ]] || { echo 'FAIL: write_env no-arg preservation/LINK_IP precedence'; failures=$((failures + 1)); }
        printf '%s\n' MANUAL_STOPPED > "$env_tmp/.desired"
        desired_file="$ABOX_DESIRED_STATE"; ABOX_DESIRED_STATE="$env_tmp/.desired" ABOX_ENV="$env_tmp/.env" ABOX_DIR="$env_tmp" CORE=xray MODE=ALL PUBLIC_KEY=new-public PBK=old-private-derived-public write_env >/dev/null 2>&1 || { echo 'FAIL: write_env state-preservation invocation'; failures=$((failures + 1)); }
        [[ "$(cat "$env_tmp/.desired" 2>/dev/null)" == MANUAL_STOPPED ]] || { echo 'FAIL: write_env must not change desired service state'; failures=$((failures + 1)); }
        ABOX_DESIRED_STATE="$desired_file"
        unset PBK; PUBLIC_KEY=loaded-public ABOX_ENV="$env_tmp/.env" ABOX_DIR="$env_tmp" write_env xray ALL >/dev/null 2>&1 || { echo 'FAIL: write_env persisted-public-key fallback'; failures=$((failures + 1)); }
        grep -Fq "PUBLIC_KEY='loaded-public'" "$env_tmp/.env" || { echo 'FAIL: write_env used stale PBK instead of loaded PUBLIC_KEY'; failures=$((failures + 1)); }
        ln -s "$env_tmp/.env" "$env_tmp/.env-symlink-target"
        ( ABOX_ENV="$env_tmp/.env-symlink-target" ABOX_DIR="$env_tmp" CORE=xray MODE=ALL write_env >/dev/null 2>&1 ) && { echo 'FAIL: write_env must reject symlink state targets'; failures=$((failures + 1)); }
        # R6-05: a corrupt old quota must abort the rewrite, not silently
        # cancel the limit: the old file must survive byte-identical.
        printf '%s\n' 'TRAFFIC_LIMIT_GB="100' 'TRAFFIC_LIMIT_MODE=total' > "$env_tmp/.env-corrupt"
        chmod 600 "$env_tmp/.env-corrupt"
        _corrupt_before=$(sha256sum "$env_tmp/.env-corrupt" | awk '{print $1}')
        ( ABOX_ENV="$env_tmp/.env-corrupt" ABOX_DIR="$env_tmp" CORE=xray MODE=ALL write_env xray ALL >/dev/null 2>&1 ) && { echo 'FAIL: write_env must refuse corrupt old quota'; failures=$((failures + 1)); }
        [[ "$(sha256sum "$env_tmp/.env-corrupt" | awk '{print $1}')" == "$_corrupt_before" ]] || { echo 'FAIL: write_env changed .env despite corrupt old quota'; failures=$((failures + 1)); }
        [[ -L "$env_tmp/.env-symlink-target" ]] || { echo 'FAIL: write_env symlink rejection must not replace the symlink'; failures=$((failures + 1)); }
    fi

    if ! selftest_has jq; then
        selftest_note 'Xray/sing-box JSON builder tests skipped (jq missing)'
    else
    UUID=00000000-0000-4000-8000-000000000000
    VLESS_SNI=www.example.com
    VISION_SNI=www.microsoft.com
    XHTTP_SNI=www.microsoft.com
    VLESS_PORT=8443
    XHTTP_PORT=9443
    SS_PORT=2053
    HY2_BASE_PORT=443
    HY2_UP=100
    HY2_DOWN=1000
    HY2_PASS=testpass
    HY2_OBFS=testobfs
    HY2_MASQ_URL=https://www.example.com/
    PK=privatekey
    PBK=publickey
    SHORT_ID=abcd1234
    SS_PASS=testsspass
    ENABLE_KEEPALIVE=true

    mkdir -p "$tmp/xray" "$tmp/sing-box"
    printf '%s\n' 'sentinel' > "$tmp/xray/sentinel.txt"
    ln -s "$tmp/xray/sentinel.txt" "$tmp/xray/config.json.tmp.$$"
    ( build_xray_config ALL "$tmp/xray/config.json" ) || { echo 'FAIL: build_xray_config ALL'; failures=$((failures + 1)); }
    [[ "$(cat "$tmp/xray/sentinel.txt" 2>/dev/null)" == 'sentinel' ]] || { echo 'FAIL: Xray config generation followed a predictable temp-file symlink'; failures=$((failures + 1)); }
    [[ -L "$tmp/xray/config.json.tmp.$$" ]] || { echo 'FAIL: Xray config generation touched the predictable temp symlink'; failures=$((failures + 1)); }
    rm -f "$tmp/xray/config.json.tmp.$$"
    jq empty "$tmp/xray/config.json" >/dev/null 2>&1 || { echo 'FAIL: build_xray_config JSON'; failures=$((failures + 1)); }
    [[ "$(stat -c %a "$tmp/xray/config.json" 2>/dev/null)" == '600' ]] || { echo 'FAIL: Xray config permissions must be 0600'; failures=$((failures + 1)); }
    local saved_vision_sni="$VISION_SNI" saved_vless_sni="$VLESS_SNI" saved_auto_sni="${ABOX_AUTO_SNI_SELECTED:-}"
    unset VISION_SNI VLESS_SNI
    ABOX_AUTO_SNI_SELECTED='www.amazon.com'
    ( build_xray_config VISION "$tmp/xray/default-sni.json" ) || { echo 'FAIL: build_xray_config VISION'; failures=$((failures + 1)); }
    jq -e '.inbounds[] | select(.protocol=="vless" and .streamSettings.realitySettings.serverNames[0]=="www.amazon.com")' "$tmp/xray/default-sni.json" >/dev/null 2>&1 || { echo 'FAIL: explicitly selected fallback REALITY SNI must be preserved'; failures=$((failures + 1)); }
    ( ABOX_AUTO_SNI_SELECTED='www.recommended.example'; sni_probe_candidate_tier() { printf 'A\n'; }; result=$(printf '\n' | prompt_reality_sni 'Vision test' 443); [[ "$result" == 'www.recommended.example' ]] ) || { echo 'FAIL: pressing Enter must accept the recommended SNI'; failures=$((failures + 1)); }
    ( ABOX_AUTO_SNI_SELECTED='www.recommended.example'; sni_probe_candidate_tier() { printf 'A\n'; }; sni_dns_resolvable() { return 0; }; result=$(printf 'www.custom.example\n' | prompt_reality_sni 'Vision test' 443); [[ "$result" == 'www.custom.example' ]] ) || { echo 'FAIL: a valid custom SNI must override the recommendation'; failures=$((failures + 1)); }
    ( ABOX_AUTO_SNI_SELECTED=''; sni_probe_candidate_tier() { printf 'A\n'; }; sni_dns_resolvable() { return 0; }; result=$(printf 'www.custom.example\n' | prompt_reality_sni 'Vision test' 443); [[ "$result" == 'www.custom.example' ]] ) || { echo 'FAIL: a valid custom SNI must remain available when no recommendation exists'; failures=$((failures + 1)); }
    VISION_SNI="$saved_vision_sni" VLESS_SNI="$saved_vless_sni" ABOX_AUTO_SNI_SELECTED="$saved_auto_sni"
    jq -e '.inbounds[] | select(.protocol=="shadowsocks" and .port==2053 and .settings.network=="tcp,udp")' "$tmp/xray/config.json" >/dev/null 2>&1 || { echo 'FAIL: Xray SS-2022 2053 tcp,udp'; failures=$((failures + 1)); }
    jq -e '.inbounds[] | select(.protocol=="vless" and .port==8443 and .streamSettings.realitySettings.serverNames[0]=="www.microsoft.com")' "$tmp/xray/config.json" >/dev/null 2>&1 || { echo 'FAIL: Xray Vision SNI split'; failures=$((failures + 1)); }
    jq -e '.inbounds[] | select(.protocol=="vless" and .port==9443 and .streamSettings.realitySettings.serverNames[0]=="www.microsoft.com")' "$tmp/xray/config.json" >/dev/null 2>&1 || { echo 'FAIL: Xray XHTTP SNI split'; failures=$((failures + 1)); }
    jq -e 'all(.inbounds[] | select(.protocol=="vless"); .streamSettings.realitySettings.minClientVer == "1.8.2")' "$tmp/xray/config.json" >/dev/null 2>&1 || { echo 'FAIL: Xray REALITY minClientVer compatibility guard'; failures=$((failures + 1)); }
    assert_ok valid_github_download_url HyNetworks/hysteria https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
    assert_bad valid_github_download_url HyNetworks/hysteria https://example.com/HyNetworks/hysteria/releases/download/app/v2.12.2/hysteria-linux-amd64
    printf '%s\n' 'sentinel' > "$tmp/sing-box/sentinel.txt"
    ln -s "$tmp/sing-box/sentinel.txt" "$tmp/sing-box/config.json.tmp.$$"
    ( build_singbox_config ALL "$tmp/sing-box/config.json" ) || { echo 'FAIL: build_singbox_config ALL'; failures=$((failures + 1)); }
    [[ "$(cat "$tmp/sing-box/sentinel.txt" 2>/dev/null)" == 'sentinel' ]] || { echo 'FAIL: sing-box config generation followed a predictable temp-file symlink'; failures=$((failures + 1)); }
    [[ -L "$tmp/sing-box/config.json.tmp.$$" ]] || { echo 'FAIL: sing-box config generation touched the predictable temp symlink'; failures=$((failures + 1)); }
    rm -f "$tmp/sing-box/config.json.tmp.$$"
    jq empty "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: build_singbox_config JSON'; failures=$((failures + 1)); }
    [[ "$(stat -c %a "$tmp/sing-box/config.json" 2>/dev/null)" == '600' ]] || { echo 'FAIL: sing-box config permissions must be 0600'; failures=$((failures + 1)); }
    jq -e '.inbounds[] | select(.type=="shadowsocks" and .listen_port==2053 and (.network|not))' "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: sing-box SS-2022 2053 default network'; failures=$((failures + 1)); }
    jq -e 'all(.inbounds[]; .type != "xhttp")' "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: sing-box ALL must not include XHTTP'; failures=$((failures + 1)); }
    jq -e '(.route.rules[] | select(.action=="sniff")) and (.route.rules[] | select(.protocol=="bittorrent" and .action=="reject"))' "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: sing-box sniff/reject route action'; failures=$((failures + 1)); }
    jq -e '.route.rules[0].action=="sniff" and .route.rules[0].network==["tcp"]' "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: sing-box sniff must remain TCP-only to avoid HY2 UDP sniff coupling'; failures=$((failures + 1)); }
    jq -e 'all(.outbounds[]; .type != "block")' "$tmp/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: sing-box legacy block outbound remains'; failures=$((failures + 1)); }
    fi
    # Parent-directory traversal regression for the dedicated runtime user.
    # R15C17-01: local init so an inherited environment value can never
    # reach the cleanup below (which previously deleted it).
    local runtime_traverse=''
    if (( EUID == 0 )) && id nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
        runtime_traverse=$(mktemp -d /tmp/A-Box-runtime-traverse.XXXXXX) || { echo 'FAIL: runtime traversal regression temp creation'; failures=$((failures + 1)); }
        # U134: never operate on an empty or non-/tmp path; mktemp failure
        # above must skip this block, not degrade to root paths. The body
        # keeps its indentation; the guard's fi closes just before the
        # outer fi below.
        if [[ -n "${runtime_traverse:-}" && "$runtime_traverse" == /tmp/* && -d "$runtime_traverse" ]]; then
        chmod 755 "$runtime_traverse"
        mkdir -p "$runtime_traverse/sing-box" "$runtime_traverse/hysteria"
        printf '%s\n' runtime-readable > "$runtime_traverse/sing-box/config.json"
        printf '%s\n' runtime-readable > "$runtime_traverse/hysteria/config.yaml"
        chown root:root "$runtime_traverse/sing-box" "$runtime_traverse/hysteria"
        chmod 700 "$runtime_traverse/sing-box" "$runtime_traverse/hysteria"
        chown root:nogroup "$runtime_traverse/sing-box/config.json" "$runtime_traverse/hysteria/config.yaml"
        chmod 640 "$runtime_traverse/sing-box/config.json" "$runtime_traverse/hysteria/config.yaml"
        runuser -u nobody -- cat "$runtime_traverse/sing-box/config.json" >/dev/null 2>&1 && { echo 'FAIL: 0700 sing-box parent directory was readable by runtime user'; failures=$((failures + 1)); }
        runuser -u nobody -- cat "$runtime_traverse/hysteria/config.yaml" >/dev/null 2>&1 && { echo 'FAIL: 0700 Hysteria parent directory was readable by runtime user'; failures=$((failures + 1)); }
        chown root:nogroup "$runtime_traverse/sing-box" "$runtime_traverse/hysteria"
        chmod 750 "$runtime_traverse/sing-box" "$runtime_traverse/hysteria"
        runuser -u nobody -- cat "$runtime_traverse/sing-box/config.json" >/dev/null 2>&1 || { echo 'FAIL: 0750 sing-box parent directory blocked runtime user'; failures=$((failures + 1)); }
        runuser -u nobody -- cat "$runtime_traverse/hysteria/config.yaml" >/dev/null 2>&1 || { echo 'FAIL: 0750 Hysteria parent directory blocked runtime user'; failures=$((failures + 1)); }
        fi
    fi
    [[ -n "$runtime_traverse" && "$runtime_traverse" == /tmp/A-Box-runtime-traverse.* && -d "$runtime_traverse" ]] && rm -rf -- "$runtime_traverse"
    unset runtime_traverse

    if (( EUID == 0 )); then
        # S9 (R65 follow-up): the ML-KEM warning check is static (it only
        # greps the source), so it stays outside the python3 gate below
        # and still runs when python3 is missing.
        grep -Fq '较新的 REALITY ML-KEM ClientHello 门槛' "$source_body_file" || { echo 'FAIL: Xray ML-KEM compatibility warning missing'; failures=$((failures + 1)); }
        # Gate the whole Clash YAML generation segment on python3:
        # write_clash_yaml / write_mihomo_user_yaml need it internally
        # (realpath), so without it every generation would count as a
        # failure instead of a skip. R65-01 only gated the three bare
        # `python3 -I` calls; the generation calls themselves were not.
        if ! selftest_has python3; then
            selftest_note 'Clash YAML generation tests skipped (python3 missing)'
        else
        local clash_dir="$tmp/abox"
        mkdir -m 700 "$clash_dir" || { echo 'FAIL: self-test A-Box temp directory'; failures=$((failures + 1)); }
        ensure_abox_dir_owned "$clash_dir" || { echo 'FAIL: self-test A-Box temp ownership setup'; failures=$((failures + 1)); }
        # M1: self-test must not do real network I/O. write_clash_yaml
        # probes the VPS country via a Cloudflare trace fetch; these
        # fixtures only check YAML structure, so fail the detection here
        # and exercise the global-nameserver fallback (1.1.1.1/8.8.8.8).
        _detect_vps_country() { return 1; }
        ABOX_XRAY_VERSION=v26.7.28 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=ALL PUBLIC_KEY=publickey LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 VLESS_PORT=443 XHTTP_PORT=8443 SS_PORT=2053 HY2_BASE_PORT=443 VLESS_SNI=www.microsoft.com VISION_SNI=www.microsoft.com XHTTP_SNI=www.microsoft.com HY2_DOMAIN='' HY2_HOP=false HY2_CERT_SHA256_FP=abcdef HY2_CERT_PUBKEY_SHA256_B64=abcdef CLASH_YAML_PATH="$clash_dir/A-Box-clash.yaml" write_clash_yaml >/dev/null 2>&1 || { echo 'FAIL: Clash YAML generation'; failures=$((failures + 1)); }
        [[ "$(stat -c %a "$clash_dir/A-Box-clash.yaml" 2>/dev/null)" == '600' ]] || { echo 'FAIL: Clash YAML permissions must be 0600'; failures=$((failures + 1)); }
        ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=HY2 PUBLIC_KEY=publickey LINK_IP=203.0.113.10 HY2_DOMAIN=hy2.example.com HY2_HOP=true HY2_BASE_PORT=443 HY2_RANGE_START=20000 HY2_RANGE_END=25000 HY2_CLASH_PORTS=20000-25000 HY2_CERT_SHA256_FP=abcdef CLASH_YAML_PATH="$clash_dir/A-Box-clash-hop.yaml" write_clash_yaml >/dev/null 2>&1 || { echo 'FAIL: Clash Hysteria2 hop YAML generation'; failures=$((failures + 1)); }
        grep -q '^    port: 20000$' "$clash_dir/A-Box-clash-hop.yaml" || { echo 'FAIL: official Clash Hysteria2 hop YAML primary port must be first range port'; failures=$((failures + 1)); }
        grep -q '^    ports: 20000-25000$' "$clash_dir/A-Box-clash-hop.yaml" || { echo 'FAIL: Clash Hysteria2 hop YAML ports missing'; failures=$((failures + 1)); }
        if ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=HY2 PUBLIC_KEY=publickey LINK_IP=203.0.113.10 HY2_DOMAIN=hy2.example.com HY2_HOP=true HY2_BASE_PORT=443 HY2_RANGE_START=20000 HY2_RANGE_END=25000 HY2_URI_PORTS= HY2_CLASH_PORTS= HY2_SB_PORTS= CLASH_YAML_PATH="$clash_dir/A-Box-clash-invalid-hop.yaml" write_clash_yaml >/dev/null 2>&1; then
            echo 'FAIL: client export accepted incomplete port-hop state'; failures=$((failures + 1))
        fi
        [[ ! -e "$clash_dir/A-Box-clash-invalid-hop.yaml" ]] || { echo 'FAIL: invalid port-hop state produced a client config file'; failures=$((failures + 1)); }
        grep -q '^proxy-groups:' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash YAML proxy-groups'; failures=$((failures + 1)); }
        grep -q '^dns:' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash YAML dns'; failures=$((failures + 1)); }
        grep -q '^  listen: 127.0.0.1:1053$' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash DNS listener must stay loopback-only'; failures=$((failures + 1)); }
        grep -q '^  default-nameserver:' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash YAML default-nameserver'; failures=$((failures + 1)); }
        grep -q '^  fake-ip-filter:' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash YAML fake-ip-filter'; failures=$((failures + 1)); }
        grep -q 'host: "www.microsoft.com"' "$clash_dir/A-Box-clash.yaml" || { echo 'FAIL: Clash XHTTP host'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: false' "$clash_dir/A-Box-clash.yaml")" -eq 2 ]] || { echo 'FAIL: Xray 26.7.28 must disable REALITY ML-KEM flags'; failures=$((failures + 1)); }
        ABOX_XRAY_VERSION=v26.9.8 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=ALL PUBLIC_KEY=publickey LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 VLESS_PORT=443 XHTTP_PORT=8443 SS_PORT=2053 HY2_BASE_PORT=443 VLESS_SNI=www.microsoft.com VISION_SNI=www.microsoft.com XHTTP_SNI=www.microsoft.com HY2_DOMAIN='' HY2_HOP=false HY2_CERT_SHA256_FP=abcdef HY2_CERT_PUBKEY_SHA256_B64=abcdef CLASH_YAML_PATH="$clash_dir/A-Box-clash-mlkem.yaml" write_clash_yaml >/dev/null 2>&1 || { echo 'FAIL: new-Xray Clash YAML generation'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: true' "$clash_dir/A-Box-clash-mlkem.yaml")" -eq 2 ]] || { echo 'FAIL: Xray >= ML-KEM threshold must enable REALITY ML-KEM flags'; failures=$((failures + 1)); }
        ABOX_XRAY_VERSION=v26.11.9 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=ALL PUBLIC_KEY=publickey LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 VLESS_PORT=443 XHTTP_PORT=8443 SS_PORT=2053 HY2_BASE_PORT=443 VLESS_SNI=www.microsoft.com VISION_SNI=www.microsoft.com XHTTP_SNI=www.microsoft.com HY2_DOMAIN='' HY2_HOP=false HY2_CERT_SHA256_FP=abcdef HY2_CERT_PUBKEY_SHA256_B64=abcdef CLASH_YAML_PATH="$clash_dir/A-Box-clash-mlkem-new.yaml" write_clash_yaml >/dev/null 2>&1 || { echo 'FAIL: new-Xray Clash YAML generation'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: true' "$clash_dir/A-Box-clash-mlkem-new.yaml")" -eq 2 ]] || { echo 'FAIL: Xray 26.11.9 must enable REALITY ML-KEM flags'; failures=$((failures + 1)); }
        ABOX_XRAY_VERSION=v26.11.9 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=ALL PUBLIC_KEY=publickey LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 VLESS_PORT=443 XHTTP_PORT=8443 SS_PORT=2053 HY2_BASE_PORT=443 VLESS_SNI=www.microsoft.com VISION_SNI=www.microsoft.com XHTTP_SNI=www.microsoft.com HY2_DOMAIN='' HY2_HOP=false HY2_CERT_SHA256_FP=abcdef HY2_CERT_PUBKEY_SHA256_B64=abcdef MIHOMO_USER_YAML_PATH="$clash_dir/A-Box-mihomo-single.yaml" write_mihomo_user_yaml >/dev/null 2>&1 || { echo 'FAIL: Mihomo single-user YAML generation'; failures=$((failures + 1)); }
        [[ "$(stat -c %a "$clash_dir/A-Box-mihomo-single.yaml" 2>/dev/null)" == '600' ]] || { echo 'FAIL: Mihomo single-user YAML permissions must be 0600'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: true' "$clash_dir/A-Box-mihomo-single.yaml")" -eq 2 ]] || { echo 'FAIL: Mihomo single-user YAML must enable REALITY ML-KEM flags on new Xray'; failures=$((failures + 1)); }
        [[ "$(grep -Fc '11111111-1111-4111-8111-111111111111' "$clash_dir/A-Box-mihomo-single.yaml")" -eq 2 ]] || { echo 'FAIL: Mihomo single-user YAML must carry only the current user UUID'; failures=$((failures + 1)); }
        ABOX_XRAY_VERSION=v26.7.28 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=ALL PUBLIC_KEY=publickey LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 VLESS_PORT=443 XHTTP_PORT=8443 SS_PORT=2053 HY2_BASE_PORT=443 VLESS_SNI=www.microsoft.com VISION_SNI=www.microsoft.com XHTTP_SNI=www.microsoft.com HY2_DOMAIN='' HY2_HOP=false HY2_CERT_SHA256_FP=abcdef HY2_CERT_PUBKEY_SHA256_B64=abcdef MIHOMO_USER_YAML_PATH="$clash_dir/A-Box-mihomo-single-old.yaml" write_mihomo_user_yaml >/dev/null 2>&1 || { echo 'FAIL: Mihomo single-user YAML generation on old Xray'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: false' "$clash_dir/A-Box-mihomo-single-old.yaml")" -eq 2 ]] || { echo 'FAIL: Mihomo single-user YAML must disable REALITY ML-KEM flags on old Xray'; failures=$((failures + 1)); }
        # H-5 (Gemini): the standalone exporter must carry the ML-KEM
        # flag on its Xray Trojan-Reality node too (the main-stack count
        # assertions above are blind to it: standalone nodes are
        # appended by write_clash_standalone_yaml, not by the emit
        # helper). Fake sb/xray configs with one Trojan-Reality
        # inbound each; the sing-box node must NOT get the field.
        local _sa_sb="$clash_dir/sa-sb.json" _sa_xr="$clash_dir/sa-xray.json"
        printf '%s' '{"inbounds": [{"tag": "trojan-landing", "type": "trojan", "listen_port": 8444, "users": [{"password": "sbpass123"}], "tls": {"enabled": true, "server_name": "www.jetbrains.com", "reality": {"enabled": true, "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "short_id": "0123456789abcdef"}}}]}' > "$_sa_sb" || { echo 'FAIL: standalone ML-KEM fixture (sb config)'; failures=$((failures + 1)); }
        printf '%s' '{"inbounds": [{"tag": "trojan-landing", "protocol": "trojan", "port": 8443, "settings": {"clients": [{"password": "testpassword123"}]}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"serverNames": ["www.jetbrains.com"], "privateKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortIds": ["0123456789abcdef"]}}}]}' > "$_sa_xr" || { echo 'FAIL: standalone ML-KEM fixture (xray config)'; failures=$((failures + 1)); }
        chmod 600 "$_sa_sb" "$_sa_xr" || { echo 'FAIL: standalone ML-KEM fixture (perms)'; failures=$((failures + 1)); }
        ABOX_SB_CFG="$_sa_sb" ABOX_XRAY_CFG="$_sa_xr" ABOX_XRAY_VERSION=v26.11.9 LINK_IP=203.0.113.10 write_clash_standalone_yaml "$clash_dir/sa-nodes-new.yaml" "$clash_dir/sa-groups-new.yaml" >/dev/null 2>&1 || { echo 'FAIL: standalone Clash YAML generation (new Xray)'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: true' "$clash_dir/sa-nodes-new.yaml")" -eq 1 ]] || { echo 'FAIL: standalone Xray Trojan-Reality node must enable REALITY ML-KEM flag on new Xray'; failures=$((failures + 1)); }
        grep -q 'Trojan-Reality-sing-box' "$clash_dir/sa-nodes-new.yaml" || { echo 'FAIL: standalone sing-box Trojan-Reality node missing'; failures=$((failures + 1)); }
        ABOX_SB_CFG="$_sa_sb" ABOX_XRAY_CFG="$_sa_xr" ABOX_XRAY_VERSION=v26.7.28 LINK_IP=203.0.113.10 write_clash_standalone_yaml "$clash_dir/sa-nodes-old.yaml" "$clash_dir/sa-groups-old.yaml" >/dev/null 2>&1 || { echo 'FAIL: standalone Clash YAML generation (old Xray)'; failures=$((failures + 1)); }
        [[ "$(grep -Fc 'support-x25519mlkem768: false' "$clash_dir/sa-nodes-old.yaml")" -eq 1 ]] || { echo 'FAIL: standalone Xray Trojan-Reality node must disable REALITY ML-KEM flag on old Xray'; failures=$((failures + 1)); }
        if ABOX_XRAY_VERSION=v26.11.9 ABOX_DIR="$clash_dir" ABOX_ENV="$clash_dir/.env" CORE=xray MODE=SS LINK_IP=203.0.113.10 UUID=11111111-1111-4111-8111-111111111111 SS_PORT=2053 MIHOMO_USER_YAML_PATH="$clash_dir/A-Box-mihomo-single-ss.yaml" write_mihomo_user_yaml >/dev/null 2>&1; then
            echo 'FAIL: Mihomo single-user YAML must refuse a mode with no VLESS leg'; failures=$((failures + 1))
        fi
        [[ ! -e "$clash_dir/A-Box-mihomo-single-ss.yaml" ]] || { echo 'FAIL: refused single-user YAML must not leave a file behind'; failures=$((failures + 1)); }
        ABOX_DIR="$clash_dir" CORE=xray MODE=SS LINK_IP=203.0.113.10 SS_PORT=2053 SS_PASS='a"b\c' HY2_PASS='h"p' HY2_OBFS='o\b' CLASH_YAML_PATH="$clash_dir/A-Box-clash-escaped.yaml" write_clash_yaml >/dev/null 2>&1 || { echo 'FAIL: Clash YAML escaped secret generation'; failures=$((failures + 1)); }
        if selftest_has python3; then
        python3 -I - "$clash_dir/A-Box-clash-escaped.yaml" <<'PY_SELFTEST_YAML' >/dev/null 2>&1 || { echo 'FAIL: Clash YAML secret escaping'; failures=$((failures + 1)); }
import json, sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
values=[]
for line in text.splitlines():
    stripped=line.strip()
    if stripped.startswith('password:'):
        values.append(json.loads(stripped.split(':',1)[1].strip()))
if values != ['a"b\\c']:
    raise SystemExit(1)
PY_SELFTEST_YAML
        else
            selftest_note 'Clash YAML secret escaping check skipped (python3 missing)'
        fi
        unset -f _detect_vps_country
        fi
    else
        echo 'SELF_TEST_NOTE: root-only Clash YAML ownership tests skipped for non-root execution'
    fi
    CORE=xray HY2_DOMAIN=hy2.example.com HY2_CERT_PUBKEY_SHA256_B64='' singbox_hy2_tls_json | grep -q '"server_name": "hy2.example.com"' || { echo 'FAIL: sing-box HY2 ACME TLS sample'; failures=$((failures + 1)); }
    CORE=singbox HY2_DOMAIN=hy2.example.com HY2_CERT_PUBKEY_SHA256_B64=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= singbox_hy2_tls_json | grep -q 'certificate_public_key_sha256' || { echo 'FAIL: sing-box HY2 self-signed TLS sample'; failures=$((failures + 1)); }
    # N-18: invalid fingerprint must be rejected.
    CORE=singbox HY2_CERT_PUBKEY_SHA256_B64='abcdef"; evil' singbox_hy2_tls_json >/dev/null 2>&1 && { echo 'FAIL: singbox_hy2_tls_json accepted invalid fingerprint'; failures=$((failures + 1)); }
    local _saved_release="${release:-}" _saved_sb_arch="${SB_ARCH:-}" _regex
    SB_ARCH=amd64
    release=alpine
    _regex=$(singbox_asset_regex)
    [[ "$_regex" == '^sing-box-.*-linux-amd64-musl\.tar\.gz$' ]] || { echo 'FAIL: sing-box Alpine musl asset selector'; failures=$((failures + 1)); }
    release=debian
    _regex=$(singbox_asset_regex)
    [[ "$_regex" == '^sing-box-.*-linux-amd64-glibc\.tar\.gz$' ]] || { echo 'FAIL: sing-box glibc asset selector'; failures=$((failures + 1)); }
    _fake_sb_release='{"assets":[{"name":"sing-box-1.14.2-linux-amd64.tar.gz","browser_download_url":"https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    SB_ARCH=amd64 release=debian
    assert_bad singbox_asset_json_from_release "$_fake_sb_release"
    _fake_sb_release='{"assets":[{"name":"sing-box-1.14.2-linux-amd64-musl.tar.gz","browser_download_url":"https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64-musl.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    release=debian
    assert_bad singbox_asset_json_from_release "$_fake_sb_release"
    _fake_sb_release='{"assets":[{"name":"sing-box-1.14.2-linux-amd64-glibc.tar.gz","browser_download_url":"https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64-glibc.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    assert_ok singbox_asset_json_from_release "$_fake_sb_release"
    unset _fake_sb_release
    assert_ok valid_github_download_url XTLS/Xray-core 'https://github.com/XTLS/Xray-core/releases/download/v26.9.30/Xray-linux-64.zip' v26.9.30
    assert_bad valid_github_download_url XTLS/Xray-core 'https://github.com/XTLS/Xray-core/releases/download/V26.9.30/Xray-linux-64.zip' v26.9.30
    assert_bad valid_github_download_url XTLS/Xray-core 'https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip' v26.9.30
    assert_bad valid_github_download_url XTLS/Xray-core 'https://github.com/Evil/Xray-core/releases/download/v26.9.30/Xray-linux-64.zip' v26.9.30
    assert_bad valid_url_https 'https://example.com:443:444/'
    assert_bad valid_url_https 'https://example.com::443/'
    [[ "$(openrc_cron_service_name debian)" == 'cron' ]] || { echo 'FAIL: Debian OpenRC cron service name must be cron'; failures=$((failures + 1)); }
    [[ "$(openrc_cron_service_name ubuntu)" == 'cron' ]] || { echo 'FAIL: Ubuntu OpenRC cron service name must be cron'; failures=$((failures + 1)); }
    # Alpine default is BusyBox crond unless cronie/dcron units are present.
    if [[ -x /etc/init.d/cronie ]]; then
        [[ "$(openrc_cron_service_name alpine)" == 'cronie' ]] || { echo 'FAIL: Alpine OpenRC cron service name must prefer cronie when installed'; failures=$((failures + 1)); }
    elif [[ -x /etc/init.d/dcron ]]; then
        [[ "$(openrc_cron_service_name alpine)" == 'dcron' ]] || { echo 'FAIL: Alpine OpenRC cron service name must prefer dcron when installed'; failures=$((failures + 1)); }
    else
        [[ "$(openrc_cron_service_name alpine)" == 'crond' ]] || { echo 'FAIL: Alpine OpenRC cron service name must be crond by default'; failures=$((failures + 1)); }
    fi
    # The old assertion grepped the policy comment itself, so it passed
    # even if the Alpine deps array installed cronie. Check the logic:
    # the alpine) branch's deps array must not contain cronie.
    _alpine_deps=$(awk '/Use BusyBox crond/{f=1} f && /deps=\(/ {g=1} g{print} g && /\)/{exit}' "$source_body_file")
    [[ -n "$_alpine_deps" && "$_alpine_deps" != *'cronie'* ]] || { echo 'FAIL: Alpine deps must not force-install cronie by default'; failures=$((failures + 1)); }
    grep -Fq 'curl-minimal' "$source_body_file" || { echo 'FAIL: RHEL/Rocky curl-minimal conflict handling missing'; failures=$((failures + 1)); }
    release="$_saved_release"
    SB_ARCH="$_saved_sb_arch"

    grep -q 'traffic_error() {' "$source_body_file" || { echo 'FAIL: safe traffic error logger missing'; failures=$((failures + 1)); }
    grep -Fq '非交互部署检测到 wg/warp/tun 默认出口' "$source_body_file" || { echo 'FAIL: WARP default-route deployment gate missing'; failures=$((failures + 1)); }
    grep -q 'A-Box-traffic.log' "$source_body_file" || { echo 'FAIL: traffic log path missing'; failures=$((failures + 1)); }
    ! grep -Eq 'deps=\([^\n]*\bvnstat\b' "$0" || { echo 'FAIL: vnStat must not be a baseline hard dependency'; failures=$((failures + 1)); }
    ! grep -Eq '^    need_cmd_pkg vnstat ' "$0" || { echo 'FAIL: vnStat must not be an unconditional command dependency'; failures=$((failures + 1)); }
    ! grep -Eq '^    need_cmd_pkg (qrencode|fail2ban-client) ' "$0" || { echo 'FAIL: optional qrencode/Fail2Ban must not be hard dependencies'; failures=$((failures + 1)); }
    grep -Fq 'if ! remove_abox_swap; then' "$source_body_file" || { echo 'FAIL: full uninstall must retain ownership marker when swap cleanup fails'; failures=$((failures + 1)); }
    grep -q '^rollback_new_swap_activation_only() {' "$0" || { echo 'FAIL: early Swap rollback must have fstab-independent activation-only helper'; failures=$((failures + 1)); }
    grep -Fq 'fstab 备份失败；已回滚新建 Swap，且未修改 /etc/fstab。' "$source_body_file" || { echo 'FAIL: early Swap backup failure must not invoke fstab-modifying rollback'; failures=$((failures + 1)); }
    grep -Fq 'rm -rf -- "$ABOX_DIR" || die' "$source_body_file" || { echo 'FAIL: full uninstall must verify A-Box directory removal'; failures=$((failures + 1)); }
    ! grep -Eq 'mapfile -t rules < <\(\"\$cmd\" -w -S INPUT|done < <\(\"\$cmd\" -w -S INPUT' "$0" || { echo 'FAIL: firewall reorder must propagate iptables -S failure'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_DEPLOY_TX_BACKUP_DIR="$uninstall_tx_dir"' "$source_body_file" || { echo 'FAIL: full uninstall rollback must use an external transaction backup'; failures=$((failures + 1)); }
    grep -Fq 'backup_auth_verify_with_key_file "$_rbc" "${_rbc}.hmac" "$key_file"' "$source_body_file" || { echo 'FAIL: rollback external transaction key verification missing'; failures=$((failures + 1)); }
    if (( EUID == 0 )); then
        local post_abox_sig='' post_abox_exists=0
        if [[ -e /etc/ddr || -L /etc/ddr ]]; then post_abox_exists=1; fi
        post_abox_sig=$(selftest_abox_signature) || { echo 'FAIL: live /etc/ddr post-test signature unavailable'; failures=$((failures + 1)); }
        if (( post_abox_exists != real_abox_exists )); then
            echo 'FAIL: --self-test changed /etc/ddr existence state'; failures=$((failures + 1))
        elif [[ "$post_abox_sig" != "$real_abox_sig" ]]; then
            echo 'FAIL: --self-test changed live /etc/ddr directory state'; failures=$((failures + 1))
        fi
    fi
    ! grep -Fq "asn_cache='/tmp'" "$source_body_file" || { echo 'FAIL: ASN cache must never fall back to shared /tmp'; failures=$((failures + 1)); }
    ! grep -Eq 'mktemp -d /tmp/A-Box-asn-cache\.XXXXXX.*\|\|[[:space:]]*asn_cache=.*/tmp' "$source_body_file" || { echo 'FAIL: ASN cache mktemp failure must not fall back to shared /tmp'; failures=$((failures + 1)); }
    ! grep -Fq 'used=$(month_bytes "$iface" "${TRAFFIC_LIMIT_MODE:-total}") || exit 0' "$source_body_file" || { echo 'FAIL: traffic measurement failure must not fail open'; failures=$((failures + 1)); }
    grep -q '^traffic_fail_closed() {' "$source_body_file" || { echo 'FAIL: traffic monitor fail-closed enforcement helper missing'; failures=$((failures + 1)); }
    traffic_body=$(sed -n '/cat > \"\$_tm_tmp\" <<'"'"'EOF_TRAFFIC'"'"'/,/^EOF_TRAFFIC$/p' "$0") || traffic_body=''
    ! grep -Fq 'load_state || exit 0' <<< "$traffic_body" || { echo 'FAIL: traffic monitor must not silently exit on persisted state load failure'; failures=$((failures + 1)); }
    grep -Fq 'state_load_failed=0' <<< "$traffic_body" || { echo 'FAIL: traffic monitor persisted-state failure handling missing'; failures=$((failures + 1)); }
    grep -Fq 'stop_all_owned_services() {' <<< "$traffic_body" || { echo 'FAIL: traffic monitor fail-closed stop path missing'; failures=$((failures + 1)); }
    # M41-NEW-03 follow-up: the main-script stop family (used by
    # clear_all_protocols) must stay byte-identical to the template
    # copies in traffic_monitor.sh; a drift means one side was edited
    # without the other.
    for _sf in managed_unit_path owned force_stop_owned_openrc core_family_unit_registered _core_exe_and_config _cmdline_has_arg core_process_matches find_core_residual_pid stop_core_residual_process stop_owned; do
        _main_fn=$(sed -n '/^# BEGIN MAIN STOP FAMILY/,/^# END MAIN STOP FAMILY/p' "$0" | awk -v fn="$_sf" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} /^}$/ && on {exit}')
        _tmpl_fn=$(printf '%s\n' "$traffic_body" | awk -v fn="$_sf" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} /^}$/ && on {exit}')
        [[ -n "$_main_fn" && "$_main_fn" == "$_tmpl_fn" ]] || { echo "FAIL: stop family drift: $_sf differs between main script and traffic_monitor template"; failures=$((failures + 1)); }
    done
    # C-1 (Gemini): behaviour-level stop-family check with a fake core
    # process. The drift guard above only proves the two copies match; a
    # helper missing from BOTH sides would still pass it. Source the
    # extracted traffic-template family (standalone, as the cron script
    # runs it) and the main-script family (with the main-script helpers),
    # then prove core_process_matches / find_core_residual_pid /
    # stop_core_residual_process actually kill a fake xray process (exe +
    # whole-argv config token). The fake-process part runs only as root,
    # only when no real /usr/local/bin/xray exists (never clobber a real
    # install), and only when /usr/local/bin is writable; the dependency
    # behaviour checks below it always run. The fake core is a copy of the
    # bash binary itself (never `yes`): on Alpine `yes` is a BusyBox
    # symlink, so a copy run as "xray" dies at once with "applet not
    # found" (rc=127) and the match checks fail; bash is a real ELF on
    # every matrix image. The `-c 'sleep 120; :'` form matters: a lone
    # `sleep` would be exec'd directly by bash, turning exe into
    # /usr/bin/sleep and dropping the config token; the trailing `:`
    # forces a fork so the bash copy stays alive with exe + config argv.
    local _c1_tmp='' _c1_pid='' _c1_fake=0 _c1_out='' _c1_rc=0 _c1_bash=''
    _c1_tmp=$(mktemp -d /tmp/A-Box-c1-selftest.XXXXXX) || { echo 'FAIL: C-1 self-test temp dir creation failed'; failures=$((failures + 1)); }
    if [[ -n "$_c1_tmp" ]]; then
        : > "$_c1_tmp/traffic_fns.sh"
        for _sf in managed_unit_path owned force_stop_owned_openrc core_family_unit_registered _core_exe_and_config _cmdline_has_arg core_process_matches find_core_residual_pid stop_core_residual_process stop_owned systemd_available pid_exe_matches proc_starttime _manifest_rows_valid; do
            printf '%s\n' "$traffic_body" | awk -v fn="$_sf" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} /^}$/ && on {exit}' >> "$_c1_tmp/traffic_fns.sh"
        done
        : > "$_c1_tmp/main_fns.sh"
        for _sf in managed_unit_path owned force_stop_owned_openrc core_family_unit_registered _core_exe_and_config _cmdline_has_arg core_process_matches find_core_residual_pid stop_core_residual_process stop_owned; do
            sed -n '/^# BEGIN MAIN STOP FAMILY/,/^# END MAIN STOP FAMILY/p' "$0" | awk -v fn="$_sf" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} /^}$/ && on {exit}' >> "$_c1_tmp/main_fns.sh"
        done
        for _sf in systemd_available pid_exe_matches proc_starttime _manifest_rows_valid; do
            awk -v fn="$_sf" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} /^}$/ && on {exit}' "$source_body_file" >> "$_c1_tmp/main_fns.sh"
        done
        bash -n "$_c1_tmp/traffic_fns.sh" || { echo 'FAIL: C-1 self-test traffic family extraction is not valid bash'; failures=$((failures + 1)); }
        bash -n "$_c1_tmp/main_fns.sh" || { echo 'FAIL: C-1 self-test main family extraction is not valid bash'; failures=$((failures + 1)); }
        # Dependency behaviour (no fake process, always runs): each helper
        # must be defined AND behave, not merely exist as a name.
        bash -c 'source "$0"; pid_exe_matches "$$" "$(readlink "/proc/$$/exe")"' "$_c1_tmp/traffic_fns.sh" || { echo 'FAIL: C-1 traffic pid_exe_matches self-check failed'; failures=$((failures + 1)); }
        bash -u -c 'source "$0"; pid_exe_matches "$$" "$(readlink "/proc/$$/exe")"' "$_c1_tmp/main_fns.sh" || { echo 'FAIL: C-1 main pid_exe_matches self-check failed'; failures=$((failures + 1)); }
        _c1_out=$(bash -c 'source "$0"; proc_starttime "$$"' "$_c1_tmp/traffic_fns.sh" 2>/dev/null) || { echo 'FAIL: C-1 traffic proc_starttime self-check failed'; failures=$((failures + 1)); }
        [[ "$_c1_out" =~ ^[0-9]+$ ]] || { echo 'FAIL: C-1 traffic proc_starttime did not print digits'; failures=$((failures + 1)); }
        printf 'F\txray\t/etc/systemd/system/xray.service\t%s\n' "$(printf '0%.0s' {1..64})" > "$_c1_tmp/valid.tsv"
        bash -c 'source "$0"; _manifest_rows_valid "$1"' "$_c1_tmp/traffic_fns.sh" "$_c1_tmp/valid.tsv" || { echo 'FAIL: C-1 traffic _manifest_rows_valid on a valid row failed'; failures=$((failures + 1)); }
        bash -c 'source "$0"; _manifest_rows_valid "$1"' "$_c1_tmp/traffic_fns.sh" "$_c1_tmp/does-not-exist" 2>/dev/null && { echo 'FAIL: C-1 traffic _manifest_rows_valid must fail on a missing file'; failures=$((failures + 1)); } || true
        bash -c 'source "$0"; systemd_available' "$_c1_tmp/traffic_fns.sh" 2>/dev/null; _c1_rc=$?; (( _c1_rc == 0 || _c1_rc == 1 )) || { echo 'FAIL: C-1 traffic systemd_available must return 0/1, not 127'; failures=$((failures + 1)); }
        _c1_bash=$(command -v bash 2>/dev/null || true)
        if (( EUID == 0 )) && [[ -n "$_c1_bash" && -d /usr/local/bin && -w /usr/local/bin && ! -e /usr/local/bin/xray ]]; then
            cp -f "$_c1_bash" /usr/local/bin/xray || { echo 'FAIL: C-1 self-test fake core install failed'; failures=$((failures + 1)); }
            if [[ -e /usr/local/bin/xray ]]; then
                _c1_fake=1
                /usr/local/bin/xray -c 'sleep 120; :' /usr/local/etc/xray/config.json >/dev/null 2>&1 &
                _c1_pid=$!
                sleep 0.3
                bash -c 'source "$0"; core_process_matches "$1" "$2"' "$_c1_tmp/traffic_fns.sh" xray "$_c1_pid" || { echo 'FAIL: C-1 traffic core_process_matches missed the fake core'; failures=$((failures + 1)); }
                _c1_out=$(bash -c 'source "$0"; find_core_residual_pid "$1"' "$_c1_tmp/traffic_fns.sh" xray 2>/dev/null) || { echo 'FAIL: C-1 traffic find_core_residual_pid missed the fake core'; failures=$((failures + 1)); }
                [[ "$_c1_out" == "$_c1_pid" ]] || { echo 'FAIL: C-1 traffic find_core_residual_pid returned the wrong pid'; failures=$((failures + 1)); }
                bash -c 'source "$0"; stop_core_residual_process "$1"' "$_c1_tmp/traffic_fns.sh" xray || { echo 'FAIL: C-1 traffic stop_core_residual_process failed'; failures=$((failures + 1)); }
                sleep 0.5
                if kill -0 "$_c1_pid" 2>/dev/null; then echo 'FAIL: C-1 traffic stop reported success but the fake core is still alive'; failures=$((failures + 1)); kill -KILL "$_c1_pid" 2>/dev/null || true; fi
                wait "$_c1_pid" 2>/dev/null || true
                /usr/local/bin/xray -c 'sleep 120; :' /usr/local/etc/xray/config.json >/dev/null 2>&1 &
                _c1_pid=$!
                sleep 0.3
                bash -u -c 'source "$0"; core_process_matches "$1" "$2"' "$_c1_tmp/main_fns.sh" xray "$_c1_pid" || { echo 'FAIL: C-1 main core_process_matches missed the fake core'; failures=$((failures + 1)); }
                _c1_out=$(bash -u -c 'source "$0"; find_core_residual_pid "$1"' "$_c1_tmp/main_fns.sh" xray 2>/dev/null) || { echo 'FAIL: C-1 main find_core_residual_pid missed the fake core'; failures=$((failures + 1)); }
                [[ "$_c1_out" == "$_c1_pid" ]] || { echo 'FAIL: C-1 main find_core_residual_pid returned the wrong pid'; failures=$((failures + 1)); }
                bash -u -c 'source "$0"; stop_core_residual_process "$1"' "$_c1_tmp/main_fns.sh" xray || { echo 'FAIL: C-1 main stop_core_residual_process failed'; failures=$((failures + 1)); }
                sleep 0.5
                if kill -0 "$_c1_pid" 2>/dev/null; then echo 'FAIL: C-1 main stop reported success but the fake core is still alive'; failures=$((failures + 1)); kill -KILL "$_c1_pid" 2>/dev/null || true; fi
                wait "$_c1_pid" 2>/dev/null || true
                rm -f /usr/local/bin/xray
                _c1_fake=0
            fi
        fi
        if (( _c1_fake == 1 )); then [[ -n "$_c1_pid" ]] && { kill -KILL "$_c1_pid" 2>/dev/null || true; wait "$_c1_pid" 2>/dev/null || true; }; rm -f /usr/local/bin/xray; fi
        rm -rf "$_c1_tmp"
    fi
    grep -Fq 'persisted traffic state is unreadable or invalid' <<< "$traffic_body" || { echo 'FAIL: traffic monitor invalid persisted state must fail closed'; failures=$((failures + 1)); }
    grep -q '^reorder_ss_whitelist_rules_one() {' "$source_body_file" || { echo 'FAIL: firewall reorder transaction missing'; failures=$((failures + 1)); }
    grep -Fq 'exec {lock_fd}>>"$lock_file"' "$source_body_file" || { echo 'FAIL: firewall reorder transaction lock missing'; failures=$((failures + 1)); }
    grep -Fq '[[ "$lock_fd" =~ ^[0-9]+$ ]]' "$source_body_file" || { echo 'FAIL: __abox_firewall_unlock "$lock_fd"; lock_fd='' must guard empty lock_fd'; failures=$((failures + 1)); }
    grep -Fq 'flock -s -n 8' "$source_body_file" || { echo 'FAIL: status/preflight must use shared non-blocking flock'; failures=$((failures + 1)); }
    grep -Fq 'umask 077; mktemp /tmp/A-Box-remote.XXXXXX' "$source_body_file" || { echo 'FAIL: remote script temp must use umask 077'; failures=$((failures + 1)); }
    ! grep -Fq 'mktemp /tmp/A-Box-remote.XXXXXX.sh' "$source_body_file" || { echo 'FAIL: remote script temp must not use .sh suffix (BusyBox mktemp requires template to end with XXXXXX)'; failures=$((failures + 1)); }
    grep -Fq 'unset ABOX_DIE_HOOK' "$source_body_file" || { echo 'FAIL: enter_runtime must ignore ambient ABOX_DIE_HOOK'; failures=$((failures + 1)); }

    grep -Fq 'firewall_rollback() {' "$source_body_file" || { echo 'FAIL: firewall reorder rollback helper missing'; failures=$((failures + 1)); }
    grep -Fq 'recovery snapshot preserved at $recovery_snapshot' "$source_body_file" || { echo 'FAIL: firewall rollback conflict must preserve recovery snapshot'; failures=$((failures + 1)); }
    grep -Fq "_restore_input+=$'\\n-D INPUT '" "$source_body_file" || { echo 'FAIL: firewall rollback must remove exact owned rules'; failures=$((failures + 1)); }
    grep -Fq 'iptables-restore backend mismatch' "$source_body_file" || { echo 'FAIL: firewall rollback must match iptables-restore backend before atomic rollback'; failures=$((failures + 1)); }
    grep -Fq 'current_foreign_lines' "$source_body_file" || { echo 'FAIL: firewall rollback must track foreign INPUT rules'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe "$ABOX_DIR" || return 1' "$source_body_file" || { echo 'FAIL: rollback restore must validate A-Box parent chain'; failures=$((failures + 1)); }
    grep -Fq 'install -d -m 700 "$ABOX_DIR" || return 1' "$source_body_file" || { echo 'FAIL: rollback restore must recreate a missing A-Box directory'; failures=$((failures + 1)); }
    grep -Fq 'previous_state=$(get_desired_state)' "$source_body_file" || { echo 'FAIL: manual service transitions must snapshot desired state'; failures=$((failures + 1)); }
    grep -Fq 'local pre_state=' "$source_body_file" || { echo 'FAIL: manual service transactions must capture pre-state'; failures=$((failures + 1)); }
    # R16-05: per-service restore routes each changed service through
    # restore_managed_service_state with its own singleton journals
    # (the old whole-journal call shape is gone; the guard is the same
    # function, so the expected-state conflict preflight still applies).
    grep -Fq 'restore_managed_service_state "$_rb_sp" "$_rb_se"' "$source_body_file" || { echo 'FAIL: manual service rollback must use expected-state conflict guards'; failures=$((failures + 1)); }
    grep -Fq 'current_state_before=$(managed_service_state_value' "$source_body_file" || { echo 'FAIL: service rollback must recheck state before mutation'; failures=$((failures + 1)); }
    grep -Fq 'start_abox_service_soft "$srv"' "$source_body_file" || { echo 'FAIL: manual start must use non-fatal service start path'; failures=$((failures + 1)); }
    declare -p redacted_json >/dev/null 2>&1 && declare -p redacted_headers >/dev/null 2>&1 || { echo 'FAIL: redaction self-test variables are not separated'; failures=$((failures + 1)); }
    grep -Fq 'target_ref="$ABOX_RESOLVED_XRAY_VERSION"' "$source_body_file" || { echo 'FAIL: Xray core-only upgrade must use centralized compatibility version'; failures=$((failures + 1)); }
    grep -q '^core_post_upgrade_health_gate() {' "$0" || { echo 'FAIL: core post-upgrade health gate missing'; failures=$((failures + 1)); }
    # L15 (R62-L02): the health gate now lives in _core_upgrade_commit_install
    # (shared by all three cores); check the wiring instead of the old
    # inline call sites: the helper must enforce the gate, and the xray /
    # sing-box call sites must pass their own health argument through.
    grep -Fq 'core_post_upgrade_health_gate "$health_arg"' "$source_body_file" || { echo 'FAIL: Xray post-upgrade health gate not enforced'; failures=$((failures + 1)); }
    grep -Fq '_core_upgrade_commit_install xray xray' "$source_body_file" || { echo 'FAIL: Xray post-upgrade health gate not enforced'; failures=$((failures + 1)); }
    grep -Fq '_core_upgrade_commit_install sing-box singbox' "$source_body_file" || { echo 'FAIL: sing-box post-upgrade health gate not enforced'; failures=$((failures + 1)); }
    # Audit 2026-10-14: regression guards for P1-1/P1-2/P2/P3 fixes.
    declare -F stop_abox_service_soft >/dev/null || { echo 'FAIL: stop_abox_service_soft must be defined'; failures=$((failures + 1)); }
    # B9-02: core_tls_listen_ports removed (was dead code).
    grep -Fq "svc='sing-box'" "$source_body_file" || { echo 'FAIL: health gate must map singbox to sing-box systemd unit'; failures=$((failures + 1)); }
    grep -Fq "ota_choice=''" "$source_body_file" || { echo 'FAIL: ota_choice must be cleared before read'; failures=$((failures + 1)); }
    grep -Fq "Policy: latest-first (user directive)" "$source_body_file" || { echo 'FAIL: test-script must stay latest-first with verified-mirror fallback'; failures=$((failures + 1)); }
    _traffic_menu=$(sed -n '/^traffic_management_menu() {$/,/^manage_ss_whitelist()/p' "$0") || _traffic_menu=''
    _setup_line=$(grep -n -m1 'setup_traffic_monitor' <<< "$_traffic_menu" | cut -d: -f1 || true)
    _update_line=$(grep -n -m1 'update_traffic_state_atomically "$limit_gb" "$mode_choice"' <<< "$_traffic_menu" | cut -d: -f1 || true)
    [[ "$_setup_line" =~ ^[0-9]+$ && "$_update_line" =~ ^[0-9]+$ && "$_setup_line" -lt "$_update_line" ]] || { echo 'FAIL: quota monitor must be provisioned before quota-state commit'; failures=$((failures + 1)); }
    grep -q '^capture_vnstat_runtime_state() {' "$0" || { echo 'FAIL: traffic transaction vnStat snapshot helper missing'; failures=$((failures + 1)); }
    grep -q '^traffic_restore_cron_block() {' "$0" || { echo 'FAIL: traffic transaction must restore only the A-Box TRAFFIC cron block'; failures=$((failures + 1)); }
    grep -q '^traffic_quota_transaction_rollback() {' "$0" || { echo 'FAIL: traffic quota rollback helper missing'; failures=$((failures + 1)); }
    grep -Fq 'expected_vnstat' "$source_body_file" || { echo 'FAIL: traffic rollback must not reuse cron expected-state variable for vnStat'; failures=$((failures + 1)); }
    grep -Fq 'ABOX_DIE_HOOK=traffic_quota_menu_die_rollback' "$source_body_file" || { echo 'FAIL: traffic setup/commit failure must trigger transaction rollback'; failures=$((failures + 1)); }
    grep -q '^firewall_snapshot_is_abox_managed() {' "$source_body_file" || { echo 'FAIL: firewall persistence ownership gate missing'; failures=$((failures + 1)); }
    grep -Fq 'auxiliary_content_is_abox_managed "$fw_file" /etc/ddr/firewall_restore.sh || return 1' "$source_body_file" || { echo 'FAIL: firewall persistence must preflight ownership before service deletion'; failures=$((failures + 1)); }
    grep -Fq '(( uid != 0 && gid != 0 )) || return 1' "$source_body_file" || { echo 'FAIL: runtime service identity must never resolve to root UID/GID'; failures=$((failures + 1)); }
    grep -Fq 'prepare_abox_runtime_permissions "$srv" || return 1' "$source_body_file" || { echo 'FAIL: restore must reapply runtime service permissions before start'; failures=$((failures + 1)); }
    grep -q '^install_optional_package() {' "$0" || { echo 'FAIL: optional package installer missing'; failures=$((failures + 1)); }
    grep -q '^ensure_abox_log_file() {' "$0" || { echo 'FAIL: safe A-Box log file gate missing'; failures=$((failures + 1)); }
    grep -q 'firewalld_zone_for_abox' "$source_body_file" || { echo 'FAIL: firewalld zone-aware routing missing'; failures=$((failures + 1)); }
    grep -Fq 'read -r -p "$(tr_msg main_command)" choice || exit 0' "$source_body_file" || { echo 'FAIL: main menu must use EOF-safe non-readline input'; failures=$((failures + 1)); }
    grep -q '^prompt_hy2_bandwidth_mbps_input() {' "$0" || { echo 'FAIL: HY2 bandwidth prompt helper missing'; failures=$((failures + 1)); }
    grep -Fq 'valid_traffic_limit_gb "$limit_gb"' "$source_body_file" || { echo 'FAIL: traffic-limit prompt must use the persisted traffic-limit validator'; failures=$((failures + 1)); }
    grep -Fq 'read -r -p "$prompt" input || return 1' "$source_body_file" || { echo 'FAIL: looped input prompts must return failure on EOF'; failures=$((failures + 1)); }
    grep -Fq 'VLESS_PORT=$(prompt_port_input "$L_VISION" "$DEF_V_PORT") || die' "$source_body_file" || { echo 'FAIL: prompt command substitutions must propagate EOF failure'; failures=$((failures + 1)); }
    grep -Fq 'exec < /dev/tty || die' "$source_body_file" || { echo 'FAIL: need_interactive_tty must fail fast when opening /dev/tty fails'; failures=$((failures + 1)); }
    if grep -Eq '(^|[[:space:];])read[[:space:]]+-r[[:space:]]+-e(p)?([[:space:]]|$)' "$0" || grep -Eq '(^|[[:space:];])read[[:space:]]+-r[[:space:]]+-e[[:space:]]+-p([[:space:]]|$)' "$0"; then
        echo 'FAIL: interactive reads must not use readline mode because Ctrl-D/EOF can stall on PTY inputs'
        failures=$((failures + 1))
    fi
    if remove_core_family_force __A_BOX_INVALID_CORE_FAMILY__; then
        echo 'FAIL: core path enumeration failure must abort forced cleanup'
        failures=$((failures + 1))
    fi
    grep -Fq 'local -a paths=()' "$source_body_file" || { echo 'FAIL: forced core cleanup must preflight all paths before deletion'; failures=$((failures + 1)); }
    grep -Fq 'core_paths=$(core_family_paths "$srv") || return 1' "$source_body_file" || { echo 'FAIL: ownership recording must not swallow core path enumeration errors'; failures=$((failures + 1)); }
    grep -q '^backup_root_contains_service() {' "$0" || { echo 'FAIL: backup service path checker missing'; failures=$((failures + 1)); }
    grep -Fq 'core_paths=$(core_family_paths "$srv") || { rm -rf "$work"; die "Core path enumeration failed during backup: $srv"; }' "$source_body_file" || { echo 'FAIL: backup core path enumeration must fail closed'; failures=$((failures + 1)); }
    grep -Fq 'def path_is_mountpoint(path):' "$source_body_file" || { echo 'FAIL: core ownership recording must use mountinfo-aware mount detection'; failures=$((failures + 1)); }
    grep -Fq 'fail closed instead of using the weaker ismount()' "$source_body_file" || { echo 'FAIL: destructive manifest removal must not fall back to weak mount detection'; failures=$((failures + 1)); }
    if sed -n "/^python3 -I - \"\$srv\" \"\$ABOX_CORE_OWNERSHIP\" <<'PY_CORE_REMOVE'$/,/^PY_CORE_REMOVE$/p" "$0" | grep -Fq 'return os.path.ismount(path)'; then
        echo 'FAIL: destructive manifest removal still contains fail-open mountinfo fallback'
        failures=$((failures + 1))
    fi
    path_tree_has_mountpoint /proc || { echo 'FAIL: mountpoint guard does not detect /proc'; failures=$((failures + 1)); }
    ! path_tree_has_mountpoint "$tmp" || { echo 'FAIL: mountpoint guard falsely reports self-test temp directory'; failures=$((failures + 1)); }
    if command -v python3 >/dev/null 2>&1; then
        _prod_decode=$(sed -n "/^def decode_mountinfo_path(value):/,/return/p" "$0" | head -2)
        python3 -I - "$_prod_decode" <<'PY_MOUNTINFO_DECODE_TEST' || { echo 'FAIL: mountinfo path decoder must decode octal escapes in one pass'; failures=$((failures + 1)); }
import re, sys
exec(sys.argv[1])
checks = {
    r'/mnt/a\040b': '/mnt/a b',
    r'/mnt/a\011b': '/mnt/a\tb',
    r'/mnt/a\012b': '/mnt/a\nb',
    r'/mnt/a\134011b': r'/mnt/a\011b',
}
for raw, expected in checks.items():
    if decode_mountinfo_path(raw) != expected:
        raise SystemExit(1)
PY_MOUNTINFO_DECODE_TEST
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$0" <<'PY_MOUNTINFO_DECODE_CONSISTENCY' || { echo 'FAIL: mountinfo path decoder copies disagree'; failures=$((failures + 1)); }
import re, sys
src = open(sys.argv[1]).read().splitlines()
blocks, cur = [], None
for line in src:
    if line.startswith('def decode_mountinfo_path(value):'):
        cur = [line]
    elif cur is not None:
        cur.append(line)
        if line.lstrip().startswith('return '):
            blocks.append('\n'.join(cur))
            cur = None
assert len(blocks) == 2, 'expected 2 decode copies, got %d' % len(blocks)
vecs = [r'/mnt/a\040b', r'/mnt/a\134011b', r'/mnt/plain', r'/x\011y']
outs = []
for b in blocks:
    ns = {}
    exec(b, {'re': re}, ns)
    outs.append([ns['decode_mountinfo_path'](v) for v in vecs])
assert outs[0] == outs[1], 'decode copies disagree'
PY_MOUNTINFO_DECODE_CONSISTENCY
    fi
    if command -v python3 >/dev/null 2>&1; then
        _guard_fail_bin="$tmp/.A-Box-failing-python"
        _guard_fail_fixture="$tmp/.guard-target"
        printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$_guard_fail_bin" || { echo 'FAIL: mount helper failure-test fixture creation'; failures=$((failures + 1)); }
        chmod 700 "$_guard_fail_bin" || { echo 'FAIL: mount helper failure-test fixture chmod'; failures=$((failures + 1)); }
        ln -sf -- "$_guard_fail_bin" "$tmp/python3" || { echo 'FAIL: mount helper failure-test python shim'; failures=$((failures + 1)); }
        if ! ( PATH="${tmp}:$PATH"; path_tree_has_mountpoint "$tmp" ); then
            echo 'FAIL: path_tree_has_mountpoint must fail closed on helper errors'; failures=$((failures + 1))
        fi
        if ! ( PATH="${tmp}:$PATH"; path_is_mountpoint "$tmp" ); then
            echo 'FAIL: path_is_mountpoint must fail closed on helper errors'; failures=$((failures + 1))
        fi
        mkdir -p "$_guard_fail_fixture" || { echo 'FAIL: mount helper target fixture creation'; failures=$((failures + 1)); }
        if ! ( PATH="${tmp}:$PATH"; core_family_paths() { printf '%s\n' "$_guard_fail_fixture"; }; ! remove_core_family_force xray ); then
            echo 'FAIL: remove_core_family_force did not fail closed on mount-helper error'; failures=$((failures + 1))
        elif [[ ! -d "$_guard_fail_fixture" ]]; then
            echo 'FAIL: remove_core_family_force deleted target after mount-helper error'; failures=$((failures + 1))
        fi
        rm -f -- "$tmp/python3" "$_guard_fail_bin"
        rm -rf -- "$_guard_fail_fixture"
    fi
    grep -Fq '/proc/self/mountinfo' "$source_body_file" || { echo 'FAIL: core ownership record/remove mountpoint guard missing'; failures=$((failures + 1)); }
    grep -q 'Restore cleanup encountered a mountpoint' "$source_body_file" || { echo 'FAIL: restore cleanup mountpoint guard missing'; failures=$((failures + 1)); }
    grep -Fq 'path_tree_has_mountpoint "$path" && return 1' "$source_body_file" || { echo 'FAIL: source-absent restore must guard the entire target tree for nested mounts'; failures=$((failures + 1)); }
    grep -Fq 'remove_owned_runtime_helper "$ABOX_DIR/geo_update.sh"' "$source_body_file" || { echo 'FAIL: Geo helper deletion must be ownership-gated'; failures=$((failures + 1)); }
    grep -q 'validate_backup_core_init_compatibility' "$source_body_file" || { echo 'FAIL: restore must preflight backup/current init compatibility before destructive changes'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/fail2ban/filter.d/A-Box.conf' "$source_body_file" || { echo 'FAIL: Fail2Ban filter parent chain must be checked before mkdir/write'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/fail2ban/jail.d/A-Box.local' "$source_body_file" || { echo 'FAIL: Fail2Ban jail parent chain must be checked before mkdir/write'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/sysctl.d/99-A-Box-tune.conf || return 1' "$source_body_file" || { echo 'FAIL: tune restore must check sysctl parent chain before restore'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/security/limits.d/A-Box.conf || return 1' "$source_body_file" || { echo 'FAIL: tune restore must check limits parent chain before restore'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/conf.d/hysteria || die' "$source_body_file" || { echo 'FAIL: Hysteria OpenRC conf.d parent chain guard missing'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/conf.d/xray || die' "$source_body_file" || { echo 'FAIL: Xray OpenRC conf.d parent chain guard missing'; failures=$((failures + 1)); }
    grep -Fq 'path_parent_chain_safe /etc/conf.d/sing-box || die' "$source_body_file" || { echo 'FAIL: sing-box OpenRC conf.d parent chain guard missing'; failures=$((failures + 1)); }
    grep -Fq 'aux_paths=$(managed_auxiliary_paths) ||' "$source_body_file" || { echo 'FAIL: backup must not swallow managed auxiliary path enumeration errors through process substitution'; failures=$((failures + 1)); }
    # R16-03: the reclaim branches (and their lock_dir_created flag)
    # are gone; creation ownership is now tracked by the identity pin
    # (_fb_id: dev:ino captured at mkdir, verified before any cleanup
    # touches the dir), which the failure cleanup below still checks.
    grep -Fq '_fb_id=$(stat -Lc' "$source_body_file" || { echo 'FAIL: fallback runtime lock must track newly created directory for rollback'; failures=$((failures + 1)); }
    if command -v flock >/dev/null 2>&1; then
        (
            _saved_lock_fallback="$LOCK_FALLBACK_DIR"
            LOCK_FALLBACK_DIR="$tmp/.A-Box-fallback-lock-regression"
            chown() { return 42; }
            ! acquire_fallback_runtime_lock
            [[ ! -e "$LOCK_FALLBACK_DIR" && ! -L "$LOCK_FALLBACK_DIR" ]]
        ) || { echo 'FAIL: fallback runtime lock failure must clean newly created lock directory'; failures=$((failures + 1)); }
    fi
    grep -Fq 'Backup init system is incompatible with the current VPS; restore was aborted before destructive changes.' "$source_body_file" || { echo 'FAIL: manual restore must abort cross-init backups before destructive changes'; failures=$((failures + 1)); }
    grep -Fq 'service_active_state_value() {' "$source_body_file" || { echo 'FAIL: service active-state helper missing'; failures=$((failures + 1)); }
    _svc_test_bin="$tmp/service-state-bin"
    mkdir -m 700 "$_svc_test_bin" || { echo 'FAIL: service-state test directory'; failures=$((failures + 1)); }
    cat > "$_svc_test_bin/systemctl" <<'EOF_SVC_TEST_SYSTEMCTL' || { echo 'FAIL: service-state systemctl fixture'; failures=$((failures + 1)); }
#!/usr/bin/env bash
case "$1 $2 $3 $4" in
  'show -p ActiveState --value')
    [[ "${ABOX_SELFTEST_SERVICE_QUERY_FAIL:-0}" == 1 ]] && exit 42
    printf '%s\n' active
    ;;
  'show -p UnitFileState --value')
    [[ "${ABOX_SELFTEST_SERVICE_QUERY_FAIL:-0}" == 1 ]] && exit 42
    printf '%s\n' enabled
    ;;
  *) exit 0 ;;
esac
EOF_SVC_TEST_SYSTEMCTL
    chmod 700 "$_svc_test_bin/systemctl" || { echo 'FAIL: service-state systemctl fixture chmod'; failures=$((failures + 1)); }
    local _svc_test_saved_path="$PATH" _svc_test_saved_init='' _svc_test_saved_init_set=0
    if [[ ${INIT_SYS+x} ]]; then _svc_test_saved_init="$INIT_SYS"; _svc_test_saved_init_set=1; fi
    PATH="${_svc_test_bin}:$PATH"
    systemd_available() { return 0; }
    INIT_SYS=systemd
    _svc_guard_pre="$tmp/service-guard-pre.state"
    _svc_guard_expected="$tmp/service-guard-expected.state"
    _svc_guard_log="$tmp/service-guard.log"
    printf '%s\n' 'xray|0|disabled' > "$_svc_guard_pre"
    printf '%s\n' 'xray|1|enabled' > "$_svc_guard_expected"
    chmod 600 "$_svc_guard_pre" "$_svc_guard_expected"
    if (( EUID == 0 )); then
        chown root:root "$_svc_guard_pre" "$_svc_guard_expected" || { echo 'FAIL: root service-state fixture ownership setup'; failures=$((failures + 1)); }
        _svc_guard_saved_state_fn=$(declare -f managed_service_state_value)
        _svc_guard_saved_owns_fn=$(declare -f abox_owns_service)
        managed_service_state_value() { printf '%s\n' 'xray|1|disabled'; }
        abox_owns_service() { return 0; }
        : > "$_svc_guard_log"
        if restore_managed_service_state "$_svc_guard_pre" "$_svc_guard_expected" >/dev/null 2>&1; then
            echo 'FAIL: service rollback must reject externally changed state'
            failures=$((failures + 1))
        fi
        eval "$_svc_guard_saved_state_fn"
        eval "$_svc_guard_saved_owns_fn"
    else
        echo 'SELF_TEST_NOTE: root-only service rollback fixture skipped for non-root execution' >&2
    fi
    export ABOX_SELFTEST_SERVICE_QUERY_FAIL=1
    if service_active_state_value xray >/dev/null 2>&1; then
        echo 'FAIL: systemd active-state query error was accepted'
        failures=$((failures + 1))
    fi
    export ABOX_SELFTEST_SERVICE_QUERY_FAIL=0
    [[ "$(service_active_state_value xray 2>/dev/null)" == 1 ]] || { echo 'FAIL: systemd active-state success decode'; failures=$((failures + 1)); }
    PATH="$_svc_test_saved_path"
    if (( _svc_test_saved_init_set )); then INIT_SYS="$_svc_test_saved_init"; else unset INIT_SYS; fi

    cat > "$_svc_test_bin/rc-service" <<'EOF_SVC_TEST_RCSERVICE' || { echo 'FAIL: service-state rc-service fixture'; failures=$((failures + 1)); }
#!/usr/bin/env bash
if [[ "$2" == status ]]; then exit "${ABOX_SELFTEST_RC_STATUS:-3}"; fi
exit 0
EOF_SVC_TEST_RCSERVICE
    cat > "$_svc_test_bin/rc-update" <<'EOF_SVC_TEST_RCUPDATE' || { echo 'FAIL: service-state rc-update fixture'; failures=$((failures + 1)); }
#!/usr/bin/env bash
if [[ "$1" == 'show' && "$2" == 'default' ]]; then
    [[ "${ABOX_SELFTEST_RC_UPDATE_FAIL:-0}" == 1 ]] && exit 42
    printf '%s\n' 'xray | default'
    exit 0
fi
exit 0
EOF_SVC_TEST_RCUPDATE
    chmod 700 "$_svc_test_bin/rc-service" "$_svc_test_bin/rc-update" || { echo 'FAIL: OpenRC service-state fixture chmod'; failures=$((failures + 1)); }
    PATH="${_svc_test_bin}:$PATH"
    INIT_SYS=openrc
    export ABOX_SELFTEST_RC_STATUS=42 ABOX_SELFTEST_RC_UPDATE_FAIL=0
    if service_active_state_value xray >/dev/null 2>&1; then
        echo 'FAIL: OpenRC active-state query error was accepted'
        failures=$((failures + 1))
    fi
    export ABOX_SELFTEST_RC_STATUS=0 ABOX_SELFTEST_RC_UPDATE_FAIL=1
    if service_enabled_state_value xray >/dev/null 2>&1; then
        echo 'FAIL: OpenRC enabled-state query error was accepted'
        failures=$((failures + 1))
    fi
    export ABOX_SELFTEST_RC_STATUS=3 ABOX_SELFTEST_RC_UPDATE_FAIL=0
    [[ "$(service_active_state_value xray 2>/dev/null)" == 0 ]] || { echo 'FAIL: OpenRC stopped-state decode'; failures=$((failures + 1)); }
    PATH="$_svc_test_saved_path"
    if (( _svc_test_saved_init_set )); then INIT_SYS="$_svc_test_saved_init"; else unset INIT_SYS; fi
    unset ABOX_SELFTEST_SERVICE_QUERY_FAIL ABOX_SELFTEST_RC_STATUS ABOX_SELFTEST_RC_UPDATE_FAIL

    _canon_env_tmp="$tmp/.canonical-port-env"
    printf '%s\n' 'CORE=xray' 'MODE=SS' 'SS_PORT="02053"' > "$_canon_env_tmp" || { echo 'FAIL: canonical-port env fixture creation'; failures=$((failures + 1)); }
    chmod 600 "$_canon_env_tmp" || { echo 'FAIL: canonical-port env fixture chmod'; failures=$((failures + 1)); }
    if (( EUID == 0 )); then chown root:root "$_canon_env_tmp" || { echo 'FAIL: canonical-port env fixture ownership'; failures=$((failures + 1)); }; fi
    if load_abox_env "$_canon_env_tmp" >/dev/null 2>&1; then
        echo 'FAIL: persisted .env accepted non-canonical port with leading zero'
        failures=$((failures + 1))
    fi
    declare -F load_optional_abox_env_or_die >/dev/null 2>&1 || { echo 'FAIL: safe optional env loader missing'; failures=$((failures + 1)); }
    if ! ( unset ABOX_DIE_HOOK; ABOX_ENV="$tmp/.env-not-present"; load_optional_abox_env_or_die ); then
        echo 'FAIL: optional env loader rejected a genuinely absent first-install state'
        failures=$((failures + 1))
    fi
    _invalid_env="$tmp/.env-invalid-existing"
    printf '%s\n' 'UNKNOWN_KEY=unexpected' > "$_invalid_env" || { echo 'FAIL: invalid env fixture creation'; failures=$((failures + 1)); }
    chmod 600 "$_invalid_env" || { echo 'FAIL: invalid env fixture chmod'; failures=$((failures + 1)); }
    if ( unset ABOX_DIE_HOOK; ABOX_ENV="$_invalid_env"; load_optional_abox_env_or_die ) >/dev/null 2>&1; then
        echo 'FAIL: optional env loader accepted an existing invalid state file'
        failures=$((failures + 1))
    fi
    # M-08(3) quoter split: write_env must persist $/backtick/! values
    # exactly, and load_abox_env must read them back unchanged.
    # End-to-end guard (no sed extraction: see L-08).
    if (( EUID == 0 )); then
        _qt_dir="$tmp/.quoter-e2e"
        mkdir -p "$_qt_dir" || { echo 'FAIL: quoter e2e fixture mkdir'; failures=$((failures + 1)); }
        if ( unset ABOX_DIE_HOOK; ABOX_ENV="$_qt_dir/.env" ABOX_DIR="$_qt_dir" CORE=xray MODE=VISION SS_PASS='p$ss' HY2_PASS='a`b`c' HY2_MASQ_URL='https://example.com/cb?x=a!b' HY2_OBFS="a'b" write_env >/dev/null 2>&1 ); then
            if load_abox_env "$_qt_dir/.env" >/dev/null 2>&1; then
                [[ "${SS_PASS:-}" == 'p$ss' ]] || { echo "FAIL: quoter e2e round-trip corrupted SS_PASS (got '${SS_PASS:-}')"; failures=$((failures + 1)); }
                [[ "${HY2_PASS:-}" == 'a`b`c' ]] || { echo "FAIL: quoter e2e round-trip corrupted HY2_PASS (got '${HY2_PASS:-}')"; failures=$((failures + 1)); }
                [[ "${HY2_MASQ_URL:-}" == 'https://example.com/cb?x=a!b' ]] || { echo "FAIL: quoter e2e round-trip corrupted HY2_MASQ_URL (got '${HY2_MASQ_URL:-}')"; failures=$((failures + 1)); }
                [[ "${HY2_OBFS:-}" == "a'b" ]] || { echo "FAIL: quoter e2e round-trip corrupted HY2_OBFS (got '${HY2_OBFS:-}')"; failures=$((failures + 1)); }
            else
                echo 'FAIL: quoter e2e env failed to load'
                failures=$((failures + 1))
            fi
        else
            echo 'FAIL: quoter e2e write_env failed'
            failures=$((failures + 1))
        fi
        clear_abox_env_vars
    else
        echo 'SELF_TEST_NOTE: quoter round-trip fixture skipped for non-root execution' >&2
    fi
    # P2-03: Return code contract — 0=success, 1=general failure, 2=preflight failure.
    # Applies to CLI top-level and rollback orchestrators; NOT to polymorphic internals.
    grep -Fq 'P2-03 Return Code Contract' "$source_body_file" || { echo 'FAIL: P2-03 return code contract not documented'; failures=$((failures + 1)); }
    # traffic_quota_transaction_rollback: missing tx_dir is a preflight failure (return 2).
    traffic_quota_transaction_rollback "/nonexistent-tx-dir-$$" >/dev/null 2>&1; _rc=$?
    (( _rc == 2 )) || { echo "FAIL: traffic rollback preflight must return 2, got $_rc"; failures=$((failures + 1)); }
    # Polymorphic internals must NOT be standardized (callers depend on case $?):
    # remove_recorded_core_family uses 2/3/4; core_version_upgrade_decision uses 2/3/4.
    grep -Fq 'remove_recorded_core_family() {' "$source_body_file" || { echo 'FAIL: remove_recorded_core_family missing'; failures=$((failures + 1)); }
    if (( failures > 0 )); then
        echo "SELF_TEST_FAILED=$failures"
        selftest_cleanup
        return 1
    fi

    # Read-only status reporting must distinguish an inactive service from an
    # unqueryable service; query failure is an unknown state, not "stopped".
    _status_owns_orig=$(declare -f abox_owns_service)
    _status_state_orig=$(declare -f service_active_state_value)
    abox_owns_service() { return 0; }
    service_active_state_value() { printf '0\n'; return 0; }
    [[ "$(service_report_state xray)" == 'inactive' ]] || { echo 'FAIL: inactive service status'; failures=$((failures + 1)); }
    service_active_state_value() { return 1; }
    [[ "$(service_report_state xray)" == 'unknown' ]] || { echo 'FAIL: unknown service status'; failures=$((failures + 1)); }
    eval "$_status_owns_orig"
    eval "$_status_state_orig"

    # A mixed active/unknown stack must not collapse to a plain "stopped" UI.
    _status_owns_orig=$(declare -f abox_owns_service)
    _status_state_orig=$(declare -f service_active_state_value)
    abox_owns_service() { [[ "$1" == xray || "$1" == hysteria ]]; }
    service_active_state_value() {
        case "$1" in
            xray) printf '1\n' ;;
            hysteria) return 1 ;;
            *) printf '0\n' ;;
        esac
    }
    # build_status_str state words are localized; assert the English rendering.
    ( ABOX_LANG=en; [[ "$(build_status_str)" == *'Xray'* && "$(build_status_str)" == *'State Unknown'* ]] ) || { echo 'FAIL: mixed active/unknown status UI'; failures=$((failures + 1)); }
    eval "$_status_owns_orig"
    eval "$_status_state_orig"

    # A managed-service state query failure must not be treated as "no services"
    # during deployment replacement confirmation.  Unknown state must reach the
    # confirmation path rather than silently auto-approving a destructive change.
    managed_services_active__orig=$(declare -f managed_services_active)
    read__orig=$(declare -f read 2>/dev/null || true)
    die__orig=$(declare -f die)
    managed_services_active() { return 2; }
    read() { answer='N'; return 0; }
    die() { return 99; }
    clear_abox_env_vars
    CORE=''; MODE=''
    if confirm_deployment_replacement xray VISION >/dev/null 2>&1; then
        echo 'FAIL: managed-service state query failure was silently auto-approved'
        failures=$((failures + 1))
    fi
    eval "$managed_services_active__orig"
    eval "$die__orig"
    if [[ -n "$read__orig" ]]; then
        eval "$read__orig"
    else
        unset -f read 2>/dev/null || true
    fi
    # Native nftables-only firewalls must be recognized rather than silently
    # treated as an iptables backend. A mocked ruleset keeps this deterministic.
    _selftest_nft_orig=$(declare -f nft 2>/dev/null || true)
    nft() { printf '%s\n' 'table inet filter {' ' chain input {' ' }' '}'; }
    if ! nftables_native_rules_present; then
        echo 'FAIL: native nftables inet table was not detected'
        failures=$((failures + 1))
    fi
    if [[ -n "$_selftest_nft_orig" ]]; then
        eval "$_selftest_nft_orig"
    else
        unset -f nft 2>/dev/null || true
    fi
    # Wallos anti-downgrade comparator and backup/restore transaction tests.
    if ! wallos_version_is_older v1.9.0 v1.10.0; then
        echo 'FAIL: Wallos semver comparison must compare numeric components'
        failures=$((failures + 1))
    fi
    if wallos_version_is_older v2.0.0 v1.99.0; then
        echo 'FAIL: Wallos semver comparison accepted a downgrade as older'
        failures=$((failures + 1))
    fi
    if ! (
        WALLOS_DIR="$tmp/wallos-fixture"
        mkdir -p "$WALLOS_DIR/db" "$WALLOS_DIR/logos" "$WALLOS_DIR/backups" || exit 31
        printf 'before-upgrade\n' > "$WALLOS_DIR/db/state.txt" || exit 32
        printf 'old-logo\n' > "$WALLOS_DIR/logos/logo.txt" || exit 33
        printf 'IMAGE=bellamy/wallos:1.2.3\nPORT=8282\nTZ=UTC\n' > "$WALLOS_DIR/.abox-state" || exit 34
        backup=$(wallos_create_backup selftest) || exit 35
        wallos_upgrade_journal_write active 'bellamy/wallos:1.2.3' 8282 UTC 127.0.0.1 "$backup" 1 || exit 46
        [[ "$(stat -c %a "$WALLOS_DIR/.upgrade-transaction")" == 600 ]] || exit 47
        [[ "$(wallos_txn_value "$WALLOS_DIR/.upgrade-transaction" phase)" == active ]] || exit 48
        printf 'partially-migrated\n' > "$WALLOS_DIR/db/state.txt" || exit 36
        printf 'new-logo\n' > "$WALLOS_DIR/logos/logo.txt" || exit 37
        printf 'IMAGE=bellamy/wallos:1.2.4\nPORT=8282\nTZ=UTC\n' > "$WALLOS_DIR/.abox-state" || exit 38
        wallos_restore_backup "$backup" || exit 39
        grep -Fxq 'before-upgrade' "$WALLOS_DIR/db/state.txt" || exit 40
        grep -Fxq 'old-logo' "$WALLOS_DIR/logos/logo.txt" || exit 41
        grep -Fxq 'IMAGE=bellamy/wallos:1.2.3' "$WALLOS_DIR/.abox-state" || exit 42
        printf 'not-a-valid-gzip\n' > "$WALLOS_DIR/backups/wallos-corrupt.tar.gz" || exit 43
        if wallos_restore_backup "$WALLOS_DIR/backups/wallos-corrupt.tar.gz"; then exit 44; fi
        grep -Fxq 'before-upgrade' "$WALLOS_DIR/db/state.txt" || exit 45
    ); then
        echo 'FAIL: Wallos backup/restore transaction failed or damaged data on invalid archive'
        failures=$((failures + 1))
    fi
    # F-05: Ed25519 detached-signature round-trip with a throwaway keypair.
    # Generates a fresh key, signs data, verifies OK; tampered data/sig must FAIL.
    # Also exercises the enforcement gate and anti-replay timestamp check.
    if selftest_has openssl && selftest_has python3; then
        _f05_tdir=$(umask 077; mktemp -d "$tmp/f05.XXXXXX") || { echo 'FAIL: F-05 mktemp'; failures=$((failures + 1)); }
        if [[ -n "${_f05_tdir:-}" && -d "$_f05_tdir" ]]; then
            # Throwaway keypair (never the production key).
            if openssl genpkey -algorithm ed25519 -out "$_f05_tdir/priv.pem" 2>/dev/null && \
               openssl pkey -in "$_f05_tdir/priv.pem" -pubout -out "$_f05_tdir/pub.pem" 2>/dev/null; then
                _f05_pub_b64=$(python3 -I - "$_f05_tdir/pub.pem" <<'PY_F05_TPUB' 2>/dev/null
import base64, sys
pem = open(sys.argv[1]).read()
der = base64.b64decode(''.join(l for l in pem.splitlines() if '---' not in l))
print(base64.b64encode(der[-32:]).decode())
PY_F05_TPUB
) || _f05_pub_b64=''
                if [[ -n "$_f05_pub_b64" ]]; then
                    printf 'F-05 test fixture data\n' > "$_f05_tdir/data.txt"
                    # Ed25519 CLI signing needs `openssl pkeyutl -rawin` (OpenSSL 3.0+).
                    # On older OpenSSL (e.g. 1.1.1 on RHEL8) the positive roundtrip is
                    # impossible by design; assert the fail-closed behavior instead.
                    if _openssl_has_ed25519; then
                        openssl pkeyutl -sign -inkey "$_f05_tdir/priv.pem" -rawin \
                            -in "$_f05_tdir/data.txt" 2>/dev/null | base64 > "$_f05_tdir/data.txt.sig" || \
                            { echo 'FAIL: F-05 signing'; failures=$((failures + 1)); }
                    else
                        selftest_note 'F-05 positive roundtrip skipped (no Ed25519 CLI support); asserting fail-closed'
                        : > "$_f05_tdir/data.txt.sig"
                    fi
                    # Swap in the throwaway pubkey (save/restore the real array).
                    _f05_saved_pubkeys=("${ABOX_SIGNING_PUBKEYS[@]}")
                    ABOX_SIGNING_PUBKEYS=("f05-selftest:$_f05_pub_b64")
                    # V-C baked ctypes test vector (generated with OpenSSL 3.x;
                    # Ed25519 signatures are deterministic, so this vector is stable).
                    _f05_ct_pub_b64='H0fQSWPH2HDNqN3F6fFbu9Ye5XpY0H3228D3RgO7ixo='
                    _f05_ct_msg_b64='QS1Cb3ggRFMtUTQgY3R5cGVzIHRlc3QgdmVjdG9yIG1lc3NhZ2U='
                    _f05_ct_sig_b64='/4fy58kyo+tkmM1OT/Y2G88bdbKHsMmjsqgZWdH3Ey4koy6dSPelN/2VT2iBPUCr3L3NcxVJ287oimxF3gPxBg=='
                    if _openssl_has_ed25519; then
                        if ! verify_ed25519_detached "$_f05_tdir/data.txt" "$_f05_tdir/data.txt.sig"; then
                            echo 'FAIL: F-05 valid signature rejected'; failures=$((failures + 1))
                        fi
                        if ! ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/data.txt" "$_f05_tdir/data.txt.sig" "f05-test" 2>/dev/null; then
                            echo 'FAIL: F-05 gate rejected valid signature'; failures=$((failures + 1))
                        fi
                    else
                        # V-C: CLI path unavailable; exercise the ctypes verifier with the
                        # baked vector, and assert the gate routes through it (fail-closed
                        # on dummy sig, accepted on the valid vector).
                        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\n' > "$_f05_tdir/dummy.sig"
                        printf '%s' "$_f05_ct_msg_b64" | base64 -d > "$_f05_tdir/ct-msg.txt" 2>/dev/null || { echo 'FAIL: F-05 ctypes vector decode'; failures=$((failures + 1)); }
                        printf '%s' "$_f05_ct_sig_b64" > "$_f05_tdir/ct-data.txt.sig"
                        _f05_ct_saved_pubkeys=("${ABOX_SIGNING_PUBKEYS[@]}")
                        ABOX_SIGNING_PUBKEYS=("f05-ct:$_f05_ct_pub_b64")
                        if ! verify_ed25519_detached_ctypes "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig"; then
                            echo 'FAIL: F-05 ctypes baked vector rejected'; failures=$((failures + 1))
                        fi
                        printf 'F-05 CT TAMPERED\n' > "$_f05_tdir/ct-msg-bad.txt"
                        if verify_ed25519_detached_ctypes "$_f05_tdir/ct-msg-bad.txt" "$_f05_tdir/ct-data.txt.sig"; then
                            echo 'FAIL: F-05 ctypes tampered message accepted'; failures=$((failures + 1))
                        fi
                        if ! ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig" "f05-test" 2>/dev/null; then
                            echo 'FAIL: F-05 gate rejected ctypes-valid signature'; failures=$((failures + 1))
                        fi
                        if _f05_gate_err=$(ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/dummy.sig" "f05-test" 2>&1 >/dev/null); then
                            echo 'FAIL: F-05 gate did not fail-closed on dummy sig via ctypes'; failures=$((failures + 1))
                        else
                            grep -q 'WARNING: invalid Ed25519 signature' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 gate dummy sig emitted no invalid WARNING'; failures=$((failures + 1)); }
                            grep -q 'FATAL: signature enforcement is ON' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 gate dummy sig emitted no enforcement FATAL'; failures=$((failures + 1)); }
                        fi
                        ABOX_SIGNING_PUBKEYS=("${_f05_ct_saved_pubkeys[@]}")
                    fi
                    # Tampered data must FAIL.
                    printf 'F-05 TAMPERED\n' > "$_f05_tdir/data-tampered.txt"
                    if verify_ed25519_detached "$_f05_tdir/data-tampered.txt" "$_f05_tdir/data.txt.sig"; then
                        echo 'FAIL: F-05 tampered data accepted'; failures=$((failures + 1))
                    fi
                    # Tampered signature must FAIL.
                    printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\n' > "$_f05_tdir/bad.sig"
                    if verify_ed25519_detached "$_f05_tdir/data.txt" "$_f05_tdir/bad.sig"; then
                        echo 'FAIL: F-05 bad signature accepted'; failures=$((failures + 1))
                    fi
                    # Missing sig file must FAIL verify (gate decides enforcement).
                    if verify_ed25519_detached "$_f05_tdir/data.txt" "$_f05_tdir/nonexistent.sig"; then
                        echo 'FAIL: F-05 missing sig accepted'; failures=$((failures + 1))
                    fi
                    # Enforcement gate: with ENFORCE=1, missing sig must return 1
                    # on every host (V-C: ctypes covers 1.1.1, so no DS-Q4 exemption).
                    if _openssl_has_ed25519; then
                        if ! ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/data.txt" "$_f05_tdir/nonexistent.sig" "f05-test" 2>/dev/null; then
                            : # expected: gate returns 1
                        else
                            echo 'FAIL: F-05 gate did not fail-closed on missing sig'; failures=$((failures + 1))
                        fi
                    else
                        if _f05_gate_err=$(ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/data.txt" "$_f05_tdir/nonexistent.sig" "f05-test" 2>&1 >/dev/null); then
                            echo 'FAIL: F-05 gate did not fail-closed on missing sig without Ed25519 CLI'; failures=$((failures + 1))
                        else
                            grep -q 'WARNING: missing signature' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 missing-sig error message missing'; failures=$((failures + 1)); }
                            grep -q 'FATAL: signature enforcement is ON' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 missing-sig enforcement message missing'; failures=$((failures + 1)); }
                        fi
                    fi
                    # Enforcement gate: with ENFORCE=0, missing sig warns but returns 0.
                    if ! ABOX_SIGNING_ENFORCE=0 abox_verify_sig_gate "$_f05_tdir/data.txt" "$_f05_tdir/nonexistent.sig" "f05-test" 2>/dev/null; then
                        echo 'FAIL: F-05 gate should warn-only when enforcement off'; failures=$((failures + 1))
                    fi
                    # Unconditionally test the ctypes gate routing: injected
                    # capability-missing forces the probe-false branch on every host,
                    # so ctypes routing is covered even when all CI hosts are 3.0+.
                    printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\n' > "$_f05_tdir/dummy.sig"
                    printf '%s' "$_f05_ct_msg_b64" | base64 -d > "$_f05_tdir/ct-msg.txt" 2>/dev/null || { echo 'FAIL: F-05 ctypes vector decode'; failures=$((failures + 1)); }
                    printf '%s' "$_f05_ct_sig_b64" > "$_f05_tdir/ct-data.txt.sig"
                    _f05_ct_saved_pubkeys=("${ABOX_SIGNING_PUBKEYS[@]}")
                    ABOX_SIGNING_PUBKEYS=("f05-ct:$_f05_ct_pub_b64")
                    if ! _f05_gate_err=$(_OPENSSL_ED25519_OK=1 ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig" "f05-test" 2>&1 >/dev/null); then
                        echo 'FAIL: F-05 gate rejected ctypes-valid signature under injected incapable state'; failures=$((failures + 1))
                    fi
                    # H-14: the direct call (run_mirrored_test_script uses
                    # verify_ed25519_detached directly, bypassing the gate)
                    # must also fall back to ctypes when the CLI lacks
                    # -rawin; a valid signature must verify.
                    if ! _OPENSSL_ED25519_OK=1 verify_ed25519_detached "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig" 2>/dev/null; then
                        echo 'FAIL: F-05 direct verify rejected valid signature under injected incapable state'; failures=$((failures + 1))
                    fi
                    if _f05_gate_err=$(verify_ed25519_detached_ctypes() { return 2; }; _OPENSSL_ED25519_OK=1 ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/dummy.sig" "f05-test" 2>&1 >/dev/null); then
                        echo 'FAIL: F-05 gate did not fail-closed on stubbed no-verifier'; failures=$((failures + 1))
                    else
                        grep -q 'lacks Ed25519/rawin support; no ctypes verifier available' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed no-verifier emitted no lacks-no-verifier WARNING'; failures=$((failures + 1)); }
                        grep -q 'FATAL: signature enforcement is ON' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed no-verifier emitted no enforcement FATAL'; failures=$((failures + 1)); }
                    fi
                    if _f05_gate_err=$(_openssl_has_ed25519() { _OPENSSL_ED25519_PROBE_FAILED=1; return 1; }; verify_ed25519_detached_ctypes() { return 2; }; ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/dummy.sig" "f05-test" 2>&1 >/dev/null); then
                        echo 'FAIL: F-05 gate did not fail-closed on stubbed no-verifier probe failure'; failures=$((failures + 1))
                    else
                        grep -q 'capability probe failed' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed probe failure emitted no probe-failed WARNING'; failures=$((failures + 1)); }
                        grep -q 'no ctypes verifier available' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed probe failure emitted no no-verifier WARNING'; failures=$((failures + 1)); }
                        grep -q 'FATAL: signature enforcement is ON' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed probe failure emitted no enforcement FATAL'; failures=$((failures + 1)); }
                    fi
                    printf 'F-05 CT TAMPERED\n' > "$_f05_tdir/ct-msg-bad.txt"
                    # H-14 (fail-closed): the direct call must still reject
                    # a tampered message when routing through ctypes.
                    if _OPENSSL_ED25519_OK=1 verify_ed25519_detached "$_f05_tdir/ct-msg-bad.txt" "$_f05_tdir/ct-data.txt.sig" 2>/dev/null; then
                        echo 'FAIL: F-05 direct verify accepted tampered signature under injected incapable state'; failures=$((failures + 1))
                    fi
                    if _f05_gate_err=$(_OPENSSL_ED25519_OK=1 ABOX_SIGNING_ENFORCE=1 abox_verify_sig_gate "$_f05_tdir/ct-msg-bad.txt" "$_f05_tdir/ct-data.txt.sig" "f05-test" 2>&1 >/dev/null); then
                        echo 'FAIL: F-05 gate accepted ctypes-tampered signature under injected incapable state'; failures=$((failures + 1))
                    else
                        grep -q 'WARNING: invalid Ed25519 signature' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 injected tampered emitted no invalid WARNING'; failures=$((failures + 1)); }
                        grep -q 'FATAL: signature enforcement is ON' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 injected tampered emitted no enforcement FATAL'; failures=$((failures + 1)); }
                    fi
                    if _f05_gate_err=$(_OPENSSL_ED25519_OK=1 ABOX_SIGNING_ENFORCE=0 abox_verify_sig_gate "$_f05_tdir/ct-msg-bad.txt" "$_f05_tdir/ct-data.txt.sig" "f05-test" 2>&1 >/dev/null); then
                        grep -q 'WARNING: invalid Ed25519 signature' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 injected tampered ENFORCE=0 emitted no invalid WARNING'; failures=$((failures + 1)); }
                    else
                        echo 'FAIL: F-05 gate with ENFORCE=0 did not warn-and-continue on invalid sig'; failures=$((failures + 1))
                    fi
                    if _f05_gate_err=$(verify_ed25519_detached_ctypes() { return 2; }; _OPENSSL_ED25519_OK=1 ABOX_SIGNING_ENFORCE=0 abox_verify_sig_gate "$_f05_tdir/ct-msg.txt" "$_f05_tdir/dummy.sig" "f05-test" 2>&1 >/dev/null); then
                        grep -q 'no ctypes verifier available' <<< "$_f05_gate_err" || { echo 'FAIL: F-05 stubbed no-verifier ENFORCE=0 emitted no no-verifier WARNING'; failures=$((failures + 1)); }
                    else
                        echo 'FAIL: F-05 gate with ENFORCE=0 did not warn-and-continue on stubbed no-verifier'; failures=$((failures + 1))
                    fi
                    ABOX_SIGNING_PUBKEYS=("${_f05_ct_saved_pubkeys[@]}")
                    # Anti-replay: old timestamp rejected, current accepted.
                    if abox_signing_timestamp_ok "20200101000000"; then
                        echo 'FAIL: F-05 stale timestamp accepted'; failures=$((failures + 1))
                    fi
                    if ! abox_signing_timestamp_ok "$(date -u +%Y%m%d%H%M%S)"; then
                        echo 'FAIL: F-05 current timestamp rejected'; failures=$((failures + 1))
                    fi
                    if abox_signing_timestamp_ok "not-a-timestamp"; then
                        echo 'FAIL: F-05 malformed timestamp accepted'; failures=$((failures + 1))
                    fi
                    # Revocation: revoked key must not verify.
                    # R66-01: the old assertion used data.txt.sig, which
                    # is EMPTY on hosts without Ed25519 CLI support (the
                    # `: >` fallback above), so it passed vacuously even
                    # if revocation were broken. Reuse the baked ctypes
                    # vector instead: it verifies while unrevoked and
                    # must fail once its pubkey fingerprint is revoked.
                    # _OPENSSL_ED25519_OK=1 forces the ctypes path on
                    # every host, so the check is real everywhere.
                    _f05_ct_fp=$(printf '%s' "$_f05_ct_pub_b64" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
                    _f05_saved_revoked=("${ABOX_REVOKED_PUBKEY_FPS[@]}")
                    _f05_ct_saved_pubkeys2=("${ABOX_SIGNING_PUBKEYS[@]}")
                    ABOX_SIGNING_PUBKEYS=("f05-ct:$_f05_ct_pub_b64")
                    if ! _OPENSSL_ED25519_OK=1 verify_ed25519_detached "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig" 2>/dev/null; then
                        echo 'FAIL: F-05 baked vector rejected before revocation'; failures=$((failures + 1))
                    fi
                    ABOX_REVOKED_PUBKEY_FPS=("$_f05_ct_fp")
                    if _OPENSSL_ED25519_OK=1 verify_ed25519_detached "$_f05_tdir/ct-msg.txt" "$_f05_tdir/ct-data.txt.sig" 2>/dev/null; then
                        echo 'FAIL: F-05 revoked key still verifies'; failures=$((failures + 1))
                    fi
                    ABOX_REVOKED_PUBKEY_FPS=("${_f05_saved_revoked[@]}")
                    ABOX_SIGNING_PUBKEYS=("${_f05_ct_saved_pubkeys2[@]}")
                    ABOX_SIGNING_PUBKEYS=("${_f05_saved_pubkeys[@]}")
                else
                    echo 'FAIL: F-05 pubkey extraction'; failures=$((failures + 1))
                fi
            else
                selftest_note 'F-05 Ed25519 keygen unavailable; skipped'
            fi
            rm -rf -- "$_f05_tdir"
        fi
    else
        selftest_note 'F-05 Ed25519 tests skipped (openssl/python3 missing)'
    fi
    # G2 (roadmap step 3, gate 4): seven high-risk scenarios from the
    # 2026-11-25/26 arbitrations. Each guard below FAILS on the pre-fix
    # code named in legs/g2/high-risk-scenarios.md and PASSES on the fixed
    # code; per-item对照 logs live in legs/g2/gate4/.
    # g2_ordered_in_func FN BEFORE AFTER: both fixed strings must occur in
    # FN's body, BEFORE earlier than AFTER. g2_func_contains FN PAT: PAT
    # must occur in FN's body. Single-process awk on purpose: the script
    # runs under `set -o pipefail`, so a `sed | grep -q` pipeline reports
    # 141 (SIGPIPE) when grep -q exits early on a long function body
    # while sed is still writing -- the match is found yet the guard
    # fails (measured: rc=141 on 539- and 224-line bodies, 0 on short
    # ones). The source snapshot excludes this region, so these patterns
    # can never match their own assertion lines. The closing brace is
    # matched as a bare `}` line: deploy_singbox embeds lines starting
    # with }" inside a quoted string, which a /^}/ end would mistake
    # for the function's closing brace.
    g2_ordered_in_func() {
        awk -v fn="$1" -v before="$2" -v after="$3" '
            $0 == fn "() {" { in_fn = 1; next }
            in_fn && $0 == "}" { exit }
            in_fn && bl == 0 && index($0, before) { bl = NR }
            in_fn && al == 0 && index($0, after) { al = NR }
            END { exit (bl > 0 && al > 0 && bl < al) ? 0 : 1 }
        ' "$source_body_file"
    }
    g2_func_contains() {
        awk -v fn="$1" -v pat="$2" '
            $0 == fn "() {" { in_fn = 1; next }
            in_fn && $0 == "}" { exit }
            in_fn && index($0, pat) { found = 1; exit 0 }
            END { exit(found ? 0 : 1) }
        ' "$source_body_file"
    }
    # 1. H7-F1 (33b): recovery must accept the container this transaction
    # created. The journal's new_container_id is the expected live pin
    # after B is built; comparing live only against the old container A
    # refused recovery of its own replacement.
    g2_func_contains _wallos_recover_interrupted_upgrade_impl '[[ "$_rc_cid" != "$_journal_new_id" ]]' || { echo 'FAIL: H7-F1 Wallos recovery must compare the live container against the journal new_container_id'; failures=$((failures + 1)); }
    # 2. LOW-2 / H-2 dim 1 (Gemini): the TUIC uniqueness gate must run
    # before any certificate is generated, so a duplicate/foreign tag
    # dies before it can mint a key/cert pair.
    g2_ordered_in_func deploy_singbox_tuic 'length) == 1 and $same[0].type == "tuic"' 'generate_self_signed_cert_atomically "$_tuic_key" "$_tuic_crt"' || { echo 'FAIL: LOW-2 TUIC uniqueness gate must precede certificate generation'; failures=$((failures + 1)); }
    # 3. H-2 dim 2 (Gemini): a restored TUIC key/cert comes back 0600 and
    # sing-box runs as abox-singbox (needs 0640 root:abox-singbox);
    # restore_tuic_backups must re-apply runtime permissions after the
    # copy, before any caller restarts the service.
    g2_ordered_in_func restore_tuic_backups 'restore_cfg_backup "$cfg_bak" "$cfg"' 'prepare_abox_runtime_permissions sing-box' || { echo 'FAIL: H-2 TUIC restore must re-apply runtime permissions after the copy'; failures=$((failures + 1)); }
    # 4. M-6 (Gemini): deploy must snapshot before mutating config, and jq
    # must never read a JSONC config raw (a // comment breaks the parse
    # and the check silently passes or dies). The jq guards are scoped to
    # their functions: the same stripped-view prefix occurs in other
    # functions, so a whole-file grep would pass on pre-fix code.
    g2_func_contains deploy_singbox 'auto_backup_silent' || { echo 'FAIL: M-6 deploy_singbox must snapshot before mutating config'; failures=$((failures + 1)); }
    g2_func_contains deploy_official_hy2 'auto_backup_silent' || { echo 'FAIL: M-6 deploy_official_hy2 must snapshot before mutating config'; failures=$((failures + 1)); }
    g2_func_contains xray_config_reality_flags 'jsonc_strip_comments "$cfg" 2>/dev/null | jq -e' || { echo 'FAIL: M-6 reality flag probes must strip JSONC comments before jq'; failures=$((failures + 1)); }
    g2_func_contains _xrc_config_has_expected_data_inbound 'jsonc_strip_comments "$cfg" 2>/dev/null | jq -r' || { echo 'FAIL: M-6 xray port probe must strip JSONC comments before jq'; failures=$((failures + 1)); }
    g2_func_contains _xrc_restore_divergence_check 'jsonc_strip_comments "$_cfg" 2>/dev/null | jq -r' || { echo 'FAIL: M-6 xray divergence check must strip JSONC comments before jq'; failures=$((failures + 1)); }
    # 5. Manifest NUL (Gemini C-1): a NUL byte in the ownership manifest
    # must fail closed -- a truncated or injected row must never be
    # treated as a valid manifest.
    printf 'F\txray\t/etc/xray/config.json\t%064d\n' 0 > "$tmp/g2-manifest-good"
    assert_ok _manifest_rows_valid "$tmp/g2-manifest-good"
    { printf 'F\txray\t/etc/xray/config.json\t%064d' 0; printf '\x00\n'; } > "$tmp/g2-manifest-nul"
    assert_bad _manifest_rows_valid "$tmp/g2-manifest-nul"
    # #205 changed the mechanism, not the behavior: the pre-#205 check
    # piped through `cmp` (diffutils, absent on minimal RPM images), so
    # with cmp broken it rejects even a good manifest. The byte-count
    # check must accept a good manifest with cmp stubbed out.
    ( cmp() { return 1; }; _manifest_rows_valid "$tmp/g2-manifest-good" ) >/dev/null 2>&1 || { echo 'FAIL: manifest validation must not depend on cmp'; failures=$((failures + 1)); }
    # 6. S-X (33b): the uniqueness guard must demand exactly one same-tag
    # object of the right type, and it must run before the merge that
    # deletes the whole tag group -- otherwise a duplicate or foreign
    # inbound is silently wiped with the group.
    g2_ordered_in_func deploy_singbox_socks5_landing 'length) == 1 and ($same[0].type == "socks" or $same[0].type == "mixed")' 'map(select(.tag!=$t))' || { echo 'FAIL: S-X socks5 uniqueness guard must precede the tag-group merge'; failures=$((failures + 1)); }
    g2_ordered_in_func deploy_xray_trojan_landing 'length) == 1 and $same[0].protocol == "trojan"' 'map(select(.tag!=$t))' || { echo 'FAIL: S-X xray trojan uniqueness guard must precede the tag-group merge'; failures=$((failures + 1)); }
    g2_ordered_in_func deploy_singbox_trojan_landing 'length) == 1 and $same[0].type == "trojan"' 'map(select(.tag!=$t))' || { echo 'FAIL: S-X sing-box trojan uniqueness guard must precede the tag-group merge'; failures=$((failures + 1)); }
    g2_ordered_in_func deploy_singbox_tuic 'length) == 1 and $same[0].type == "tuic"' 'map(select(.tag!=$t))' || { echo 'FAIL: S-X TUIC uniqueness guard must precede the tag-group merge'; failures=$((failures + 1)); }
    g2_ordered_in_func argo_deploy_ws 'length) == 1 and $same[0].type == "vmess"' 'map(select(.tag=="vmess-ws-in" or .tag=="vless-ws-in"))' || { echo 'FAIL: S-X argo vmess uniqueness guard must precede the ws merge'; failures=$((failures + 1)); }
    g2_ordered_in_func argo_deploy_ws 'length) == 1 and $same[0].type == "vless"' 'map(select(.tag=="vmess-ws-in" or .tag=="vless-ws-in"))' || { echo 'FAIL: S-X argo vless uniqueness guard must precede the ws merge'; failures=$((failures + 1)); }
    # 7. C-2 (Gemini): a RETURN trap that cleans up a temp file must save
    # and restore the caller's RETURN trap first -- a bare `trap - RETURN`
    # in the cleanup kills the caller's trap chain and aborts the session.
    g2_func_contains users_xray_ensure_tags '_jq_caller_trap=$(trap -p RETURN' || { echo 'FAIL: C-2 users_xray_ensure_tags must save the caller RETURN trap'; failures=$((failures + 1)); }
    g2_func_contains users_xray_ensure_tags 'eval "$_jq_caller_trap"' || { echo 'FAIL: C-2 users_xray_ensure_tags must restore the caller RETURN trap'; failures=$((failures + 1)); }
    g2_func_contains users_sb_ensure_tags '_jq_caller_trap=$(trap -p RETURN' || { echo 'FAIL: C-2 users_sb_ensure_tags must save the caller RETURN trap'; failures=$((failures + 1)); }
    g2_func_contains users_sb_ensure_tags 'eval "$_jq_caller_trap"' || { echo 'FAIL: C-2 users_sb_ensure_tags must restore the caller RETURN trap'; failures=$((failures + 1)); }
    if (( failures > 0 )); then
        echo "SELF_TEST_FAILED=$failures"
        selftest_cleanup
        return 1
    fi
    echo 'SELF_TEST_OK'
    selftest_cleanup
    return 0
}

main() {
    case "${1:-}" in
        --version|-V) printf 'A-Box %s (%s)\n' "$ABOX_BUILD" "$ABOX_BUILD_EPOCH"; exit 0 ;;
        --export-backup-key) shift; prepare_noninteractive_file_operation; export_backup_recovery_key "${1:-}"; exit 0 ;;
        --convert-legacy-backup) shift; prepare_noninteractive_file_operation; _conv_out="${2:-$(dirname -- "${1:-.}")}"; [[ ! -L "$_conv_out" ]] || die 'Legacy conversion output directory must not be a symbolic link.'; _conv_out=$(realpath -m -- "$_conv_out" 2>/dev/null) || _conv_out="$_conv_out"; convert_legacy_backup_archive "${1:-}" "$_conv_out"; exit $? ;;
        --xray-config-autorecover) shift; prepare_noninteractive_file_operation; xray_config_autorecover; exit $? ;;
        --help|-h) show_cli_help; exit 0 ;;
        --self-test) run_self_tests; exit $? ;;
        --user-guard-tick) user_guard_tick; exit $? ;;
        --sni-test)
            # Hidden test hook: run SNI radar non-interactively for A/B testing.
            # Usage: sudo ABOX_SNI_TEST_PROFILE=mini ABOX_SNI_MINI_CONCURRENCY=16 \
            #          ABOX_SNI_MINI_MAX=500 bash install.sh --sni-test
            # Timing note: a driver-side timeout (e.g. 540 s) is not the radar
            # wall clock -- if the driver kills the parent, orphaned probes
            # may run on (observed 592 s total on S2); read stage timings
            # from workdir file mtimes, not the driver clock.
            prepare_noninteractive_file_operation
            run_builtin_sni_radar "${ABOX_SNI_TEST_PROFILE:-mini}" "SNI test (${ABOX_SNI_TEST_PROFILE:-mini})"
            exit 0
            ;;
        --status) show_status_report; exit 0 ;;
        --stop) manual_stop_managed_stack; exit $? ;;
        --start) manual_start_managed_stack; exit $? ;;
        --lang)
            ABOX_LANG_OVERRIDE="${2:-zh}"
            enter_runtime "$@"
            ABOX_LANG=$(normalize_lang "$ABOX_LANG_OVERRIDE")
            save_lang
            main_loop "$@"
            ;;
        --lang=*)
            ABOX_LANG_OVERRIDE="${1#--lang=}"
            enter_runtime "$@"
            ABOX_LANG=$(normalize_lang "$ABOX_LANG_OVERRIDE")
            save_lang
            main_loop "$@"
            ;;
        '') enter_runtime "$@"; main_loop "$@" ;;
        *) show_cli_help >&2; exit 2 ;;
    esac
}

main_loop() {
    detect_lang
    init_system_environment soft
    setup_shortcut
    # Menu status row: 3 segments spread left/center/right with margins
    # 14-system safe: ASCII only, standard ANSI colors, CJK width aware
    # Safely migrate active, exactly marked v7 installations into the new
    # per-file ownership model. Inactive or ambiguous services are not adopted.
    local _srv _pid _exe
    for _srv in xray sing-box hysteria; do
        abox_owns_service "$_srv" && is_service_running "$_srv" || continue
        _pid=$(managed_service_pid "$_srv" 2>/dev/null || true); _pid=${_pid%%$'\n'*}
        case "$_srv" in xray) _exe=/usr/local/bin/xray ;; sing-box) _exe=/usr/local/bin/sing-box ;; hysteria) _exe=/usr/local/bin/hysteria ;; esac
        if pid_exe_matches "$_pid" "$_exe"; then
            record_core_family_ownership "$_srv" || msg "${YELLOW}[!] Ownership migration for active ${_srv} could not be verified; destructive maintenance will remain blocked until registration succeeds.${NC}" >&2
        fi
    done
    GLOBAL_PUBLIC_IP=$(get_public_ip_swr || true)
    while true; do
        local STATUS_STR='' CUR_MODE='' choice
        # Portable epoch seconds: EPOCHSECONDS is Bash 5.0+ only and
        # this script supports Bash 4.4 (Rocky/Alma 8) under set -u.
        local _ml_now=0
        _ml_now=$(date +%s 2>/dev/null || printf '0')
        [[ "$_ml_now" =~ ^[0-9]+$ ]] || _ml_now=0
        # U237: a backwards clock jump makes the age negative (< 5),
        # so the stale cache would be reused until the old timestamp
        # plus five seconds; a negative age forces a rebuild instead.
        if [[ -z "${_ABOX_STATUS_CACHE:-}" ]] || (( _ml_now - ${_ABOX_STATUS_TS:-0} >= 5 )) || (( _ml_now < ${_ABOX_STATUS_TS:-0} )); then
            STATUS_STR=$(build_status_str)
            _ABOX_STATUS_CACHE="$STATUS_STR"; _ABOX_STATUS_TS=$_ml_now
        else
            STATUS_STR="$_ABOX_STATUS_CACHE"
        fi
        # A loadable .env may carry no deployment yet (e.g. traffic limit set
        # before any protocol install); only show [CORE-MODE] when both exist.
        if load_abox_env "$ABOX_ENV" 2>/dev/null && [[ -n "${CORE:-}" && -n "${MODE:-}" ]]; then
            CUR_MODE="[${CORE}-${MODE}]"
        else
            CUR_MODE=''
        fi
        clear
        _menu_banner
        case "${ABOX_LANG:-zh}" in
            en)
                _menu_info_display
                msg "${CYAN}[ Xray-core Deployment ]${NC}                ${CYAN}[ sing-box Deployment ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2 (Official)               ${CYAN}9.${NC}  Hysteria 2 (sing-box)"
                msg "${CYAN}5.${NC}  All protocols: 4-in-1 (Xray+Hy2)    ${CYAN}10.${NC} All protocols: 3-in-1 (sing-box)"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ Tools & System ]${NC}                      ${CYAN}[ Ops & Policy ]${NC}"
                msg "${CYAN}11.${NC}  Toolbox                            ${CYAN}16.${NC}  Wipe Nodes & Reset Env"
                msg "${CYAN}12.${NC}  View Node Configs & Links          ${CYAN}17.${NC}  Monthly Traffic Quota"
                msg "${CYAN}13.${NC}  User Guide & Manual                ${CYAN}18.${NC}  More Protocols"
                msg "${CYAN}14.${NC}  Update Core & Script (OTA)         ${CYAN}19.${NC}  Language / 语言设置"
                msg "${CYAN}15.${NC}  VPS Optimization                   ${CYAN}20.${NC}  Uninstall Script & Cores${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  Exit"
                ;;
            ru)
                _menu_info_display
                msg "${CYAN}[ Развёртывание Xray ]${NC}                  ${CYAN}[ Развёртывание sing-box ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2 (официальный)            ${CYAN}9.${NC}  Hysteria 2 (sing-box)"
                msg "${CYAN}5.${NC}  Все протоколы: 4 в 1 (Xray+Hy2)      ${CYAN}10.${NC} Все протоколы: 3 в 1 (sing-box)"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ Инструменты и система ]${NC}               ${CYAN}[ Управление и политики ]${NC}"
                msg "${CYAN}11.${NC}  Панель инструментов                ${CYAN}16.${NC}  Сброс узлов и окружения"
                msg "${CYAN}12.${NC}  Просмотр параметров узлов          ${CYAN}17.${NC}  Лимит месячного трафика"
                msg "${CYAN}13.${NC}  Справка и руководство              ${CYAN}18.${NC}  Ещё протоколы"
                msg "${CYAN}14.${NC}  Обновление ядра и скрипта          ${CYAN}19.${NC}  Язык / Language"
                msg "${CYAN}15.${NC}  Оптимизация VPS             ${CYAN}20.${NC}  Полное удаление скрипта и ядер${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  Выход"
                ;;
            fa)
                _menu_info_display
                msg "${CYAN}[ نصب Xray ]${NC}                            ${CYAN}[ نصب sing-box ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2 (رسمی)                   ${CYAN}9.${NC}  Hysteria 2 (sing-box)"
                msg "${CYAN}5.${NC}  همهٔ پروتکل‌ها، ۴ در ۱ (Xray+Hy2)   ${CYAN}10.${NC} همهٔ پروتکل‌ها، ۳ در ۱ (sing-box)"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ ابزارها و سیستم ]${NC}                     ${CYAN}[ عملیات و سیاست‌ها ]${NC}"
                msg "${CYAN}11.${NC}  جعبه ابزار                         ${CYAN}16.${NC}  پاکسازی نودها و بازنشانی محیط"
                msg "${CYAN}12.${NC}  مشاهده تنظیمات و نودها             ${CYAN}17.${NC}  مدیریت و محدودیت ترافیک"
                msg "${CYAN}13.${NC}  راهنمای استفاده                    ${CYAN}18.${NC}  پروتکل‌های بیشتر"
                msg "${CYAN}14.${NC}  به‌روزرسانی هسته و اسکریپت         ${CYAN}19.${NC}  تنظیم زبان / Language"
                msg "${CYAN}15.${NC}  بهینه‌سازی VPS                     ${CYAN}20.${NC}  حذف کامل اسکریپت و هسته${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  خروج"
                ;;
            zh-tw)
                _menu_info_display
                msg "${CYAN}[ Xray-core 部署 ]${NC}                      ${CYAN}[ sing-box 部署 ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2 (官方)                   ${CYAN}9.${NC}  Hysteria 2 (sing-box)"
                msg "${CYAN}5.${NC}  全協議四合一 (Xray+Hy2)             ${CYAN}10.${NC} 全協議三合一 (sing-box)"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ 工具與系統 ]${NC}                          ${CYAN}[ 運維與策略 ]${NC}"
                msg "${CYAN}11.${NC}  綜合工具箱                         ${CYAN}16.${NC}  清空節點與重置環境"
                msg "${CYAN}12.${NC}  查看節點配置與參數                 ${CYAN}17.${NC}  流量管控與額度限制"
                msg "${CYAN}13.${NC}  使用幫助與說明書                   ${CYAN}18.${NC}  更多協議"
                msg "${CYAN}14.${NC}  核心與腳本升級 (OTA)               ${CYAN}19.${NC}  多語言設置 / Language"
                msg "${CYAN}15.${NC}  VPS 一鍵優化                       ${CYAN}20.${NC}  徹底卸載腳本與核心${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  退出指令碼"
                ;;
            ja)
                _menu_info_display
                msg "${CYAN}[ Xray-core デプロイ ]${NC}                ${CYAN}[ sing-box デプロイ ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2（公式）                  ${CYAN}9.${NC}  Hysteria 2（sing-box）"
                msg "${CYAN}5.${NC}  全プロトコル・4-in-1（Xray+Hy2）  ${CYAN}10.${NC} 全プロトコル・3-in-1（sing-box）"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ ツールとシステム ]${NC}                    ${CYAN}[ 運用とポリシー ]${NC}"
                msg "${CYAN}11.${NC}  総合ツールボックス                 ${CYAN}16.${NC}  全ノード削除と環境初期化"
                msg "${CYAN}12.${NC}  ノード設定と情報の表示             ${CYAN}17.${NC}  月間通信量制限と管理"
                msg "${CYAN}13.${NC}  ヘルプとマニュアル                 ${CYAN}18.${NC}  追加のプロトコル"
                msg "${CYAN}14.${NC}  コアとスクリプト更新 (OTA)         ${CYAN}19.${NC}  言語設定 / Language"
                msg "${CYAN}15.${NC}  VPS 最適化                         ${CYAN}20.${NC}  スクリプトとコアの完全削除${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  スクリプトを終了します"
                ;;
            *)
                _menu_info_display
                msg "${CYAN}[ Xray-core 部署 ]${NC}                      ${CYAN}[ sing-box 部署 ]${NC}"
                msg "${CYAN}1.${NC}  VLESS-Vision-Reality                ${CYAN}6.${NC}  VLESS-Vision-Reality"
                msg "${CYAN}2.${NC}  VLESS-XHTTP-Reality                 ${CYAN}7.${NC}  VLESS + SS-2022"
                msg "${CYAN}3.${NC}  Shadowsocks-2022                    ${CYAN}8.${NC}  Shadowsocks-2022"
                msg "${CYAN}4.${NC}  Hysteria 2 (官方)                   ${CYAN}9.${NC}  Hysteria 2 (sing-box)"
                msg "${CYAN}5.${NC}  全协议四合一 (Xray+Hy2)             ${CYAN}10.${NC} 全协议三合一 (sing-box)"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}[ 工具与系统 ]${NC}                          ${CYAN}[ 运维与策略 ]${NC}"
                msg "${CYAN}11.${NC}  综合工具箱                         ${CYAN}16.${NC}  清空节点与重置环境"
                msg "${CYAN}12.${NC}  查看节点配置与参数                 ${CYAN}17.${NC}  流量管控与额度限制"
                msg "${CYAN}13.${NC}  使用帮助与说明书                   ${CYAN}18.${NC}  更多协议"
                msg "${CYAN}14.${NC}  核心与脚本升级 (OTA)               ${CYAN}19.${NC}  多语言设置 / Language"
                msg "${CYAN}15.${NC}  VPS 一键优化                       ${CYAN}20.${NC}  彻底卸载脚本与核心${NC}"
                msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
                msg "${CYAN}0.${NC}  退出脚本"
                ;;
        esac
        msg "${CYAN}────────────────────────────────────────────────────────────────────────────────${NC}"
        _menu_lock_released=0
        if [[ "${ABOX_RUNTIME_LOCK_MODE:-}" == flock ]] && [[ -e /proc/$$/fd/9 ]]; then
            flock -u 9 2>/dev/null && _menu_lock_released=1 || true
        fi
        read -r -p "$(tr_msg main_command)" choice || exit 0
        choice=$(normalize_fa_ar_digits "${choice:-}")
        if [[ "${_menu_lock_released:-0}" == 1 ]]; then
            # A-07: Wait up to 15s for lock (cron helpers hold it briefly); -n caused spurious menu exits.
            # M-03: a failed re-lock must not kill the session (die used to
            # drop the first session while the second kept running); warn
            # and redraw the menu instead, the next prompt retries.
            if ! flock -w 15 9; then
                msg "${YELLOW}[!] $(tr_msg main_loop_relock_failed)${NC}"
                sleep 2
                continue
            fi
        fi
        unset _menu_lock_released
        case "$choice" in
            1) deploy_xray VISION || pause_return ;;
            2) deploy_xray XHTTP || pause_return ;;
            3) deploy_xray SS || pause_return ;;
            4) deploy_official_hy2 NORMAL || pause_return ;;
            5) deploy_xray ALL || pause_return ;;
            6) deploy_singbox VISION || pause_return ;;
            7) deploy_singbox VLESS_SS || pause_return ;;
            8) deploy_singbox SS || pause_return ;;
            9) deploy_singbox HY2 || pause_return ;;
            10) deploy_singbox ALL || pause_return ;;
            11) vps_benchmark_menu ;;
            12) view_config manual ;;
            13) show_usage ;;
            14) ota_and_geo_menu ;;
            15) tune_vps ;;
            16) cleanup_protocols_menu ;;
            17) traffic_management_menu ;;
            18) other_protocols_menu ;;
            19) language_menu ;;
            20) clean_uninstall_menu ;;
            r|R) one_click_reality_deploy ;;
            0) clear; exit 0 ;;
            *) msg "${RED}$(tr_msg invalid_input): $choice${NC}"; sleep 1 ;;
        esac
        unset _MI_COLLECTED
    done
}

# SYD-B E0: dumb/unknown TERM or non-tty output makes ncurses clear emit
# junk into logs. Shadow clear for the whole main script; a real terminal
# still delegates to the system clear, everything else becomes a no-op.
clear() {
    [[ -t 1 ]] || return 0
    case "${TERM:-}" in ''|dumb|unknown) return 0 ;; esac
    command clear "$@" 2>/dev/null || :
}

main "$@"
