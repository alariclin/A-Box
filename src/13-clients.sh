# ABOX-MODULE-BEGIN 13-clients Clash/Mihomo emit, core upgrades, CLI
#   Source: install.sh lines 64540-69269 @ baseline 800a419bab03e7448533eb99072b3f07c8abba18
#   NOTE: this header is stripped by build.sh; it is NOT part of install.sh.
# ABOX-MODULE-END
# Detect the VPS country (ISO-3166 alpha-2, uppercase) from the public egress IP.
# Used to pick bootstrap DNS for the Clash YAML: Chinese defaults must never be
# hard-coded for non-CN VPS. Returns empty on any failure; caller falls back to
# global defaults.
_detect_vps_country() {
    local trace loc
    trace=$(curl -sS --connect-timeout 2 -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    loc=$(printf '%s\n' "$trace" | grep -m1 '^loc=' | cut -d= -f2 | tr -d '[:space:]')
    [[ "$loc" =~ ^[A-Za-z]{2}$ ]] || return 1
    printf '%s\n' "$loc" | tr 'a-z' 'A-Z'
}

# Bootstrap nameservers for the Clash YAML, chosen by VPS geolocation.
# Prints two plain IPv4 addresses, one per line.
_clash_default_nameservers() {
    local country="${1:-}"
    case "$country" in
        CN) printf '223.5.5.5\n119.29.29.29\n' ;;
        *)  printf '1.1.1.1\n8.8.8.8\n' ;;
    esac
}

write_clash_standalone_yaml() {
    local _nodes="$1" _groups="$2" _rows _record _pk _pub _rc=0
    local _sc="${ABOX_SB_CFG:-/etc/sing-box/config.json}"
    local _xc="${ABOX_XRAY_CFG:-/usr/local/etc/xray/config.json}"
    # H-5 (Gemini): the standalone exporter needs the Xray Reality
    # ML-KEM gate too -- decided by xray_reality_requires_mlkem
    # directly, NOT via clash_reality_mlkem_enabled (that one also
    # requires CORE==xray, which fails for a sing-box main stack with
    # a standalone Xray Trojan inbound).
    local _xray_mlkem='false'
    if xray_reality_requires_mlkem; then _xray_mlkem='true'; fi

    _rows=$(umask 077; mktemp "${_nodes%/*}/.A-Box-clash-records.XXXXXX") || return 1

    if ! python3 -I - "$_sc" "$_xc" "${LINK_IP:-}" "$_xray_mlkem" > "$_rows" <<'PY_CLASH_STANDALONE'
import json
import os
import re
import stat
import subprocess
import sys
import uuid

sb_path, xr_path, server, xray_mlkem_arg = sys.argv[1:]
LIMIT = 8 * 1024 * 1024


class Bad(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Bad(reason)


# H-5: the standalone Xray Reality ML-KEM flag ("true"/"false"), decided
# in bash by xray_reality_requires_mlkem. Validated here, after require
# exists; only trojan_xray passes it on (see reality()).
require(xray_mlkem_arg in ("true", "false"), "invalid xray_mlkem flag")
XRAY_MLKEM = xray_mlkem_arg == "true"


def obj(value):
    require(isinstance(value, dict), "invalid object")
    return value


def text(value, reason, empty=False):
    require(isinstance(value, str), reason)
    require(empty or bool(value), reason)
    require("\x00" not in value, reason)
    require(not any(0xD800 <= ord(c) <= 0xDFFF for c in value), reason)
    return value


def first(values, reason):
    require(isinstance(values, list) and bool(values), reason)
    return values[0]


def account(inbound, key):
    return obj(first(inbound.get(key), "missing account"))


def warning(message):
    print(json.dumps({"comment": "P6: " + message}, ensure_ascii=False))


def trusted_read(path):
    text(path, "missing file path")
    flags = os.O_RDONLY | os.O_NONBLOCK
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        require(stat.S_ISREG(st.st_mode), "not a regular file")
        require(st.st_uid in {0, os.geteuid()}, "untrusted file owner")
        require(not (st.st_mode & 0o022), "file is writable by group or others")
        data = stream.read(LIMIT + 1)
        require(len(data) <= LIMIT, "file too large")
        return data


def strip_jsonc_comments(data):
    # R7-F16-6: strip // and /* */ comments, mirroring the
    # jsonc_strip_comments state machine (string-aware: a // inside a
    # string is data, not a comment; backslash escapes inside strings
    # are honored). Unlike that helper, an unterminated block comment
    # raises instead of silently truncating the document.
    if isinstance(data, (bytes, bytearray)):
        data = bytes(data).decode("utf-8", errors="replace")
    out = []
    i = 0
    n = len(data)
    in_str = False
    esc = False
    bs = chr(92)
    while i < n:
        c = data[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == bs:
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and data[i + 1] == "/":
            while i < n and data[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and data[i + 1] == "*":
            j = data.find("*/", i + 2)
            if j < 0:
                raise ValueError("unterminated JSONC block comment")
            out.append(" ")
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load(path, label):
    try:
        data = json.loads(strip_jsonc_comments(trusted_read(path)))
        obj(data)
        inbounds = data.get("inbounds", [])
        require(isinstance(inbounds, list), "invalid inbounds")
        require(all(isinstance(i, dict) for i in inbounds), "invalid inbound")
        return inbounds
    except FileNotFoundError:
        return []
    except (OSError, ValueError, UnicodeError):
        warning(label + " source omitted: unreadable, invalid, or untrusted config")
        raise


def tagged(inbounds, tag):
    matches = [i for i in inbounds if i.get("tag") == tag]
    require(len(matches) <= 1, "duplicate inbound tag")
    return matches[0] if matches else None


def normalize_xray_port(port):
    # R7-F16-5: Xray accepts a string port (pure digits, or a "lo-hi"
    # range whose first port is the probe/export target). Anything else
    # (bool, float, list, dict, comma list, inverted or out-of-range
    # range) is rejected by the strict check in common() below.
    if isinstance(port, bool):
        raise Bad("invalid port")
    if isinstance(port, int):
        return port
    if isinstance(port, str):
        if re.fullmatch(r"[0-9]+", port):
            return int(port)
        m = re.fullmatch(r"([0-9]+)-([0-9]+)", port)
        if m:
            lo, hi = int(m.group(1)), int(m.group(2))
            if 1 <= lo <= 65535 and 1 <= hi <= 65535 and lo <= hi:
                return lo
    raise Bad("invalid port")


def common(name, kind, inbound, port_key):
    port = inbound.get(port_key)
    if port_key == "port":
        port = normalize_xray_port(port)
    require(type(port) is int and 1 <= port <= 65535, "invalid port")
    host = text(server, "missing export server")
    require(host != "N/A", "missing export server")
    return {"name": name, "type": kind, "server": host, "port": port}


def short_id(value):
    if isinstance(value, list):
        value = first(value, "missing Reality short ID")
    value = text(value, "missing Reality short ID", empty=True)
    require(re.fullmatch(r"(?:[0-9A-Fa-f]{2}){0,8}", value) is not None,
            "invalid Reality short ID")
    return value


def reality(node, private, sid, mlkem=None):
    private = text(private, "missing Reality private key")
    require(re.fullmatch(r"[A-Za-z0-9_-]{43}", private) is not None,
            "invalid Reality private key")
    node["reality-opts"] = {"public-key": "", "short-id": short_id(sid)}
    # H-5 (Gemini): only the Xray Trojan builder passes mlkem; the
    # sing-box Reality builders (trojan_sb, anytls) leave it None and
    # never write the field (no ML-KEM semantic there).
    if mlkem is not None:
        node["reality-opts"]["support-x25519mlkem768"] = mlkem
    return {"node": node, "private": private}


def sb_reality(inbound):
    tls = obj(inbound.get("tls"))
    require(tls.get("enabled") is True, "TLS is not enabled")
    r = obj(tls.get("reality"))
    require(r.get("enabled") is True, "Reality is not enabled")
    sni = tls.get("server_name")
    if not sni:
        handshake = r.get("handshake", {})
        if isinstance(handshake, dict):
            sni = handshake.get("server")
    return text(sni, "missing SNI"), r


def tcp_transport(inbound):
    transport = inbound.get("transport")
    if transport is None:
        return
    transport = obj(transport)
    require(transport.get("type", "tcp") == "tcp",
            "unsupported non-TCP transport")


def trojan_sb(inbound, inbounds):
    require(inbound.get("type") == "trojan", "unexpected inbound type")
    tcp_transport(inbound)
    sni, r = sb_reality(inbound)
    users = inbound.get("users")
    password = (account(inbound, "users").get("password")
                if users else inbound.get("password"))
    node = common("Trojan-Reality-sing-box", "trojan", inbound, "listen_port")
    node.update({
        "password": text(password, "missing Trojan password"),
        "udp": True,
        "sni": sni,
        "client-fingerprint": "chrome",
    })
    return reality(node, r.get("private_key"), r.get("short_id"))


def trojan_xray(inbound, inbounds):
    require(inbound.get("protocol") == "trojan", "unexpected inbound protocol")
    stream = obj(inbound.get("streamSettings"))
    # R16-F16-02: Xray's TransportProtocol.Build() accepts "raw" as TCP
    # (case "raw", "tcp"), and `method` overrides `network` when set;
    # read method first so `method: "ws"` without `network` is not
    # mis-accepted as TCP (same function, reverse misjudgment).
    _transport = stream.get("method") or stream.get("network", "tcp")
    require(_transport in ("tcp", "raw"),
            "unsupported non-TCP transport")
    require(stream.get("security") == "reality", "Reality is not enabled")
    r = obj(stream.get("realitySettings"))
    settings = obj(inbound.get("settings"))
    client = account(settings, "clients")
    node = common("Trojan-Reality-Xray", "trojan", inbound, "port")
    node.update({
        "password": text(client.get("password"), "missing Trojan password"),
        "udp": True,
        "sni": text(first(r.get("serverNames"), "missing SNI"), "missing SNI"),
        "client-fingerprint": "chrome",
    })
    return reality(node, r.get("privateKey"), r.get("shortIds"), XRAY_MLKEM)


def tuic_cert_policy(tls):
    # R14-F16-01: inline .tls.certificate takes priority over
    # certificate_path (it is the certificate sing-box actually uses;
    # mirrors the bash rebuild_standalone_links three-state logic).
    # A string is used as-is; an array of strings is joined with
    # "\n". Any other inline type fails closed without falling back
    # to the path. Only a positively absent inline certificate
    # authorises the certificate_path branch below.
    inline = tls.get("certificate")
    if inline is not None:
        try:
            if isinstance(inline, str):
                cert = inline.encode("utf-8")
            elif isinstance(inline, list) and all(isinstance(c, str) for c in inline):
                cert = "\n".join(inline).encode("utf-8")
            else:
                raise Bad("unsupported inline TUIC certificate type")
        except UnicodeEncodeError:
            raise Bad("unsupported inline TUIC certificate")
    else:
        path = text(tls.get("certificate_path"), "missing TUIC certificate path")
        # R16-F16-01: trusted_read() raises OSError (missing/unreadable
        # file, O_NOFOLLOW symlink refusal), not Bad; without this the
        # error escapes export()'s `except Bad` and kills the whole
        # Clash export instead of omitting just the TUIC node.
        try:
            cert = trusted_read(path)
        except OSError:
            raise Bad("TUIC certificate unreadable, invalid, or untrusted")
    try:
        result = subprocess.run(
            ["openssl", "x509", "-noout", "-issuer", "-subject",
             "-nameopt", "RFC2253"],
            input=cert, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=5, check=True,
        )
        lines = result.stdout.decode("utf-8").splitlines()
        issuer = next((s[len("issuer="):] for s in lines
                       if s.startswith("issuer=")), "")
        subject = next((s[len("subject="):] for s in lines
                        if s.startswith("subject=")), "")
        require(bool(issuer) and bool(subject), "unusable TUIC certificate")
        return issuer == subject
    except (OSError, ValueError, subprocess.SubprocessError):
        raise Bad("TUIC certificate unreadable, invalid, or untrusted")


def tuic(inbound, inbounds):
    require(inbound.get("type") == "tuic", "unexpected inbound type")
    user = account(inbound, "users")
    user_uuid = text(user.get("uuid"), "missing TUIC UUID")
    try:
        require(str(uuid.UUID(user_uuid)) == user_uuid.lower(), "invalid TUIC UUID")
    except ValueError:
        raise Bad("invalid TUIC UUID")
    require("password" in user, "missing TUIC password")
    password = text(user["password"], "invalid TUIC password", empty=True)
    tls = obj(inbound.get("tls"))
    require(tls.get("enabled") is True, "TLS is not enabled")
    alpn = tls.get("alpn", ["h3"])
    if isinstance(alpn, str):
        alpn = [alpn]
    require(isinstance(alpn, list) and bool(alpn), "invalid TUIC ALPN")
    alpn = [text(a, "invalid TUIC ALPN") for a in alpn]
    cc = inbound.get("congestion_control", "bbr")
    require(cc in ("bbr", "cubic", "new_reno"), "unsupported TUIC congestion controller")
    skip_verify = tuic_cert_policy(tls)
    node = common("TUIC", "tuic", inbound, "listen_port")
    node.update({
        "uuid": user_uuid,
        "password": password,
        "sni": text(tls.get("server_name"), "missing TUIC SNI"),
        "alpn": alpn,
        "congestion-controller": cc,
        "udp-relay-mode": "native",
        "reduce-rtt": False,
        "skip-cert-verify": skip_verify,
    })
    return {"node": node}


def anytls(inbound, inbounds):
    require(inbound.get("type") == "anytls", "unexpected inbound type")
    tcp_transport(inbound)
    sni, r = sb_reality(inbound)
    users = inbound.get("users")
    password = (account(inbound, "users").get("password")
                if users else inbound.get("password"))
    node = common("AnyTLS-Reality", "anytls", inbound, "listen_port")
    node.update({
        "password": text(password, "missing AnyTLS password"),
        "sni": sni,
        "client-fingerprint": "chrome",
        "skip-cert-verify": False,
    })
    return reality(node, r.get("private_key"), r.get("short_id"))


def shadowtls(inbound, inbounds):
    require(inbound.get("type") == "shadowtls", "unexpected inbound type")
    require(type(inbound.get("version")) is int and inbound["version"] == 3,
            "unsupported ShadowTLS version")
    detour = text(inbound.get("detour"), "missing ShadowTLS detour")
    inner = tagged(inbounds, detour)
    require(inner is not None, "missing ShadowTLS detour inbound")
    require(inner.get("type") == "shadowsocks", "detour is not Shadowsocks")
    require(inner.get("method") == "2022-blake3-aes-128-gcm",
            "unsupported ShadowTLS inner cipher")
    handshake = obj(inbound.get("handshake"))
    user = account(inbound, "users")
    node = common("ShadowTLS", "ss", inbound, "listen_port")
    node.update({
        "cipher": inner["method"],
        "password": text(inner.get("password"), "missing ShadowTLS inner password"),
        "udp": False,
        "plugin": "shadow-tls",
        "plugin-opts": {
            "host": text(handshake.get("server"), "missing ShadowTLS handshake host"),
            "password": text(user.get("password"), "missing ShadowTLS outer password"),
            "version": 3,
        },
    })
    return {"node": node}


def socks_sb(inbound, inbounds):
    require(inbound.get("type") in ("socks", "mixed"), "unexpected inbound type")
    user = account(inbound, "users")
    node = common("SOCKS5-sing-box", "socks5", inbound, "listen_port")
    node.update({
        "username": text(user.get("username"), "missing SOCKS5 username"),
        "password": text(user.get("password"), "missing SOCKS5 password"),
        "udp": True,
        "tls": False,
    })
    return {"node": node}


def socks_xray(inbound, inbounds):
    require(inbound.get("protocol") == "socks", "unexpected inbound protocol")
    settings = obj(inbound.get("settings"))
    require(settings.get("auth") == "password", "unsupported SOCKS5 authentication")
    require(settings.get("udp") is True, "unsupported SOCKS5 UDP setting")
    user = account(settings, "accounts")
    node = common("SOCKS5-Xray", "socks5", inbound, "port")
    node.update({
        "username": text(user.get("user"), "missing SOCKS5 username"),
        "password": text(user.get("pass"), "missing SOCKS5 password"),
        "udp": True,
        "tls": False,
    })
    return {"node": node}


def tagged_all(inbounds, tag):
    # H-24 (Carbon R3): prefix match for multi-instance inbounds
    # (tag == base or tag == base + "-<digits>", the same
    # (-[0-9]+)?$ morphology _standalone_link_survivor uses). Returns
    # (inbound, suffix) pairs in config order; the suffix ("", "-2",
    # "-3", ...) is appended to the node name so instances never
    # collide. tagged() stays exact for the ShadowTLS detour lookup.
    out = []
    for i in inbounds:
        t = i.get("tag")
        if t == tag:
            out.append((i, ""))
        elif isinstance(t, str) and t.startswith(tag + "-"):
            suffix = t[len(tag) + 1:]
            if re.fullmatch(r"[0-9]+", suffix):
                out.append((i, "-" + suffix))
    return out


def export(inbounds, label, tag, builder):
    # H-24: export every matching instance, not just the exact tag.
    # Each instance is tried independently: one bad instance is
    # omitted with a warning instead of dropping the others.
    for inbound, suffix in tagged_all(inbounds, tag):
        try:
            record = builder(inbound, inbounds)
            node = record["node"]
            if suffix:
                node["name"] = node["name"] + suffix
            print(json.dumps(record, ensure_ascii=False))
        except Bad as exc:
            warning(label + "/" + tag + suffix + " omitted: " + str(exc))


sb = load(sb_path, "sing-box")
xr = load(xr_path, "Xray")

export(xr, "Xray", "trojan-landing", trojan_xray)
export(sb, "sing-box", "trojan-landing", trojan_sb)
export(sb, "sing-box", "tuic-in", tuic)
export(sb, "sing-box", "anytls-in", anytls)
export(sb, "sing-box", "shadowtls-in", shadowtls)
export(xr, "Xray", "socks5-landing", socks_xray)
export(sb, "sing-box", "socks5-landing", socks_sb)
PY_CLASH_STANDALONE
    then
        rm -f -- "$_rows"
        return 1
    fi

    # U17: truncate the caller files only after the render succeeded, so
    # a render failure leaves any previous content untouched.
    { : > "$_nodes" && : > "$_groups"; } || { rm -f -- "$_rows"; return 1; }

    while IFS= read -r _record; do
        [[ -n "$_record" ]] || continue
        _pk=$(python3 -I -c \
            'import json,sys; print(json.load(sys.stdin).get("private", ""))' \
            <<< "$_record") || { _rc=1; break; }
        _pub=''
        if [[ -n "$_pk" ]]; then
            if _pub=$(x25519_pub_from_priv "$_pk" 2>/dev/null); then
                [[ "$_pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || _pub=''
            else
                _pub=''
            fi
        fi

        if ! python3 -I -c '
import json
import sys

nodes_path, groups_path, public_key = sys.argv[1:]
record = json.load(sys.stdin)


def scalar(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def fields(stream, mapping, indent):
    prefix = " " * indent
    for key, value in mapping.items():
        if isinstance(value, dict):
            stream.write(prefix + key + ":\n")
            fields(stream, value, indent + 2)
        elif isinstance(value, list):
            stream.write(prefix + key + ":\n")
            for item in value:
                stream.write(prefix + "  - " + scalar(item) + "\n")
        else:
            stream.write(prefix + key + ": " + scalar(value) + "\n")


with open(nodes_path, "a", encoding="utf-8") as nodes:
    if "comment" in record:
        nodes.write("  # " + record["comment"] + "\n")
        sys.exit(0)

    node = record["node"]
    if "private" in record:
        if not public_key:
            nodes.write("  # P6: " + node["name"] +
                        " omitted: Reality public-key derivation failed\n")
            sys.exit(0)
        node["reality-opts"]["public-key"] = public_key

    if node["type"] == "tuic" and node["skip-cert-verify"]:
        nodes.write("  # P6: TUIC uses an unverified self-issued certificate.\n")

    nodes.write("  - name: " + scalar(node["name"]) + "\n")
    fields(nodes, {k: v for k, v in node.items() if k != "name"}, 4)

with open(groups_path, "a", encoding="utf-8") as groups:
    groups.write("      - " + scalar(node["name"]) + "\n")
' "$_nodes" "$_groups" "$_pub" <<< "$_record"
        then
            _rc=1
            break
        fi
    done < "$_rows"

    unset _pk _record
    rm -f -- "$_rows"
    return "$_rc"
}

# U14 (D1): emit one Mihomo vless proxy block (Vision or XHTTP) with the
# version-gated reality-opts. Shared by write_clash_yaml (all users) and
# write_mihomo_user_yaml (one user): same gate value, same node data, so
# the two files can never disagree on fingerprint / ML-KEM / UUID / port /
# SNI / Reality / XHTTP fields. $1 = vision|xhttp, $2 = proxy name,
# $3 = uuid, $4 = clash_mlkem (true|false, from clash_reality_mlkem_enabled).
emit_mihomo_vless_proxy_block() {
    local kind="$1" proxy_name="$2" client_uuid="$3" clash_mlkem="$4"
    case "$kind" in
        vision)
            cat <<EOF_CLASH
  - name: "$proxy_name"
    type: vless
    server: "${LINK_IP:-}"
    port: ${VLESS_PORT:-443}
    uuid: "$client_uuid"
    udp: true
    tls: true
    servername: "${VISION_SNI:-}"
    client-fingerprint: chrome
    encryption: ""
    network: tcp
    flow: xtls-rprx-vision
    packet-encoding: xudp
    reality-opts:
      public-key: "${PUBLIC_KEY:-}"
      short-id: "${SHORT_ID:-}"
      support-x25519mlkem768: $clash_mlkem
    smux:
      enabled: false
EOF_CLASH
            ;;
        xhttp)
            cat <<EOF_CLASH
  - name: "$proxy_name"
    type: vless
    server: "${LINK_IP:-}"
    port: ${XHTTP_PORT:-8443}
    uuid: "$client_uuid"
    udp: true
    tls: true
    servername: "${XHTTP_SNI:-}"
    client-fingerprint: chrome
    encryption: ""
    network: xhttp
    alpn:
      - h2
    reality-opts:
      public-key: "${PUBLIC_KEY:-}"
      short-id: "${SHORT_ID:-}"
      support-x25519mlkem768: $clash_mlkem
    xhttp-opts:
      path: /xhttp
      host: "${XHTTP_SNI:-}"
      mode: stream-one
    smux:
      enabled: false
EOF_CLASH
            ;;
        *) return 1 ;;
    esac
}

# H-24(3): print one compact JSON object per ENABLED user of a
# registry file ({name, secret, login}), in registry order.
# Returns 1 when the registry is missing, a symlink, unreadable,
# or not parseable as a users registry (callers treat a missing
# file as "no multi-user data" and any other failure as fail-closed).
_clash_registry_users_json() {
    local reg="$1"
    [[ -f "$reg" && ! -L "$reg" && -r "$reg" ]] || return 1
    jq -c '.users[] | select(.disabled != true and ((.blocked // "") == "")) | {name: (.name // ""), secret: (.secret // ""), login: (.login // .name // "")}' "$reg" 2>/dev/null || return 1
    return 0
}

# H-24(3): effective Hy2 password for one YAML user. Mirrors the
# users_link hy2 branch: live config first (userpass ->
# "login:secret" of THIS user, password-only -> the bare server
# password); when live is unreadable or lacks the user, registry
# fallback (multi-user -> "login:secret", single user -> bare
# secret). On sing-box core Hy2 is password-only even multi-user
# (R1-11-F05), so the bare registry secret is used directly and no
# live lookup is attempted. Prints the password (no trailing
# newline); rc 1 when no credential can be determined.
# $1 = login (.login // .name); $2 = registry secret;
# $3 = enabled user count; $4 = core (${CORE}).
_clash_hy2_user_password() {
    local login="$1" reg_secret="$2" encount="${3:-1}" core="${4:-${CORE:-}}" _eff=''
    [[ -n "$login" ]] || return 1
    if [[ "$core" == 'singbox' || "$core" == 'sing-box' ]]; then
        [[ -n "$reg_secret" ]] || return 1
        printf '%s' "$reg_secret"
        return 0
    fi
    _eff=$(hy2_effective_password_for_user "$login" "${ABOX_HY2_CONFIG:-/etc/hysteria/config.yaml}" 2>/dev/null || true)
    if [[ -n "$_eff" ]]; then
        _eff=${_eff%__ABOX_TRAILING_NL_KEEP__}
        printf '%s' "$_eff"
        return 0
    fi
    if (( encount >= 2 )) && [[ -n "$reg_secret" ]]; then
        printf '%s' "${login}:${reg_secret}"
        return 0
    fi
    [[ -n "$reg_secret" ]] || return 1
    printf '%s' "$reg_secret"
    return 0
}

write_clash_yaml() {
    local out="${CLASH_YAML_PATH:-$ABOX_DIR/A-Box-clash.yaml}" S_IP="${LINK_IP:-}" hy2_name="Hy2" tmp_out out_real base_real clash_hop_port client_uuid proxy_name
    S_IP="${S_IP#[}"; S_IP="${S_IP%]}"
    local hy2_pass_yaml hy2_obfs_yaml ss_pass_yaml clash_mlkem=false clash_mlkem_rc
    local _hy2_eff_pass='' _hy2_eff_obfs='' _hy2_eff_user=''
    local clash_ns1 clash_ns2 clash_country
    local _clash_standalone_nodes_tmp='' _clash_standalone_groups_tmp=''
    if clash_reality_mlkem_enabled; then
        clash_mlkem=true
    else
        clash_mlkem_rc=$?
        (( clash_mlkem_rc == 1 )) || return 1
    fi
    [[ -n "$out" && "$out" == /* ]] || return 1
    # H-24: a bad Hy2 port configuration skips the Hy2 node (and warns)
    # instead of failing the whole YAML (menu 12 must not die on one
    # protocol's port problem).
    local _hy2_ports_bad=0
    if [[ "${HY2_HOP:-}" == true && ( "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ) ]]; then
        if ! valid_hy2_clash_ports "${HY2_CLASH_PORTS:-}" || ! valid_canonical_port "${HY2_BASE_PORT:-}"; then
            msg "${YELLOW}[!] Hy2 Clash ports are invalid; skipping the Hy2 node in Clash YAML.${NC}" >&2
            _hy2_ports_bad=1
        fi
    elif [[ -n "${HY2_BASE_PORT:-}" ]] && ! valid_canonical_port "${HY2_BASE_PORT:-}"; then
        msg "${YELLOW}[!] Hy2 base port '${HY2_BASE_PORT}' is invalid; skipping the Hy2 node in Clash YAML.${NC}" >&2
        _hy2_ports_bad=1
    fi
    [[ -n "${HY2_DOMAIN:-}" ]] && S_IP="${HY2_DOMAIN:-}"
    clash_hop_port="${HY2_BASE_PORT:-443}"
    if [[ "${CORE:-}" != singbox && "${HY2_HOP:-}" == true ]]; then
        if [[ "${HY2_RANGE_START:-}" =~ ^[0-9]+$ ]]; then
            clash_hop_port="${HY2_RANGE_START:-}"
        elif [[ "${HY2_CLASH_PORTS:-}" =~ ^([0-9]+)(-|$) ]]; then
            clash_hop_port="${BASH_REMATCH[1]}"
        fi
    fi
    [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]] && hy2_name='Hy2'
    ensure_abox_dir_owned "$ABOX_DIR" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    base_real=$(python3 -I - "$ABOX_DIR" <<'PY_CLASH_REALPATH'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY_CLASH_REALPATH
) || return 1
    out_real=$(python3 -I - "$out" <<'PY_CLASH_REALPATH'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY_CLASH_REALPATH
) || return 1
    [[ "$out_real" == "$base_real"/* ]] || return 1
    [[ ! -L "$out" ]] || return 1
    # R9C16-01: refuse a pre-existing non-regular output target. Without
    # this, mv below moves the generated YAML inside an existing
    # directory, chmod 600 then strips the directory's traverse bit,
    # and the function still reports success with no file at $out.
    [[ ! -e "$out" || -f "$out" ]] || { msg "${RED}Refusing to write Clash config: output path exists and is not a regular file: $out${NC}" >&2; return 1; }
    tmp_out=$(mktemp "$base_real/.A-Box-clash-new.XXXXXX") || return 1
    # TRAP-7: UUID list temp file with explicit status check (no process substitution).
    local _clash_uuid_list_tmp
    _clash_uuid_list_tmp=$(umask 077; mktemp /tmp/A-Box-clash-uuid.XXXXXX) || { rm -f -- "$tmp_out"; return 1; }
    if ! write_full_uuid_list_to_file "$_clash_uuid_list_tmp"; then
        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp"
        msg "${RED}UUID list unreadable or untrusted; refusing to generate incomplete Clash config.${NC}" >&2
        return 1
    fi
    # E62-NEW-01 (candidate B): XHTTP nodes are emitted only for UUIDs
    # the live XHTTP inbound actually has. The merged registry list is
    # the fallback when the live state cannot be read or has no xhttp
    # inbound (not-installed / self-test contexts, where the YAML is
    # .env-driven); a readable live xhttp inbound is authoritative even
    # when its client list is empty. A plain variable needs no temp-file
    # cleanup on the early returns below.
    local _xhttp_uuid_list=''
    if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]]; then
        if ! _xhttp_uuid_list=$(list_xhttp_live_uuids 2>/dev/null); then
            _xhttp_uuid_list=$(cat "$_clash_uuid_list_tmp" 2>/dev/null || true)
        fi
    else
        _xhttp_uuid_list=$(cat "$_clash_uuid_list_tmp" 2>/dev/null || true)
    fi
    # F-11 fix: clean up tmp_out and _clash_uuid_list_tmp on every early return below.
    # H-24: the YAML password is the effective Hy2 credential
    # (login:secret for multi-user userpass), not the stale .env value.
    local _hy2_eff_pass=''
    _hy2_eff_pass=$(hy2_effective_password 2>/dev/null || printf '%s' "${HY2_PASS:-}")
    _hy2_eff_pass=${_hy2_eff_pass%__ABOX_TRAILING_NL_KEEP__}
    hy2_pass_yaml=$(json_escape "$_hy2_eff_pass") || { rm -f -- "$tmp_out" "$_clash_uuid_list_tmp"; return 1; }
    hy2_obfs_yaml=$(json_escape "${HY2_OBFS:-}") || { rm -f -- "$tmp_out" "$_clash_uuid_list_tmp"; return 1; }
    # H-24(3): keep the raw SS password too: the single-user node
    # below is emitted from the resolved (name, password) lists.
    local _ss_eff_pass=''
    _ss_eff_pass=$(ss_effective_password 2>/dev/null || printf '%s' "${SS_PASS:-}")
    ss_pass_yaml=$(json_escape "$_ss_eff_pass") || { rm -f -- "$tmp_out" "$_clash_uuid_list_tmp"; return 1; }
    # SYD-B5 F3: reuse the view_config A3 pin gate for the YAML channel.
    # Effective fingerprint: live-certificate fingerprint when readable,
    # else the stored 64-hex fingerprint; empty means unusable.
    # L4 (A+C): for a sing-box node, a pin is not enough -- the live
    # config must still serve a hysteria2 inbound. A residual cert
    # (or a stale cached fingerprint) plus MODE still claiming HY2
    # used to resurrect a deleted node here; the publisher now asks
    # the same tri-state verdict the cert cleanup uses, and a missing
    # or unverifiable inbound withholds the node. The official-Hy2
    # node (CORE != singbox) is untouched: it has no sing-box inbound
    # to check, and must not disappear because of this gate.
    local hy2_pin_colon hy2_fp_yaml hy2_yaml_emit=false
    local _hy2_sb_live=1 _hy2_sb_state=0
    if [[ "${CORE:-}" == 'singbox' && ( "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ) ]]; then
        _singbox_hy2_inbound_state; _hy2_sb_state=$?
        if (( _hy2_sb_state != 0 )); then
            _hy2_sb_live=0
            if (( _hy2_sb_state == 2 )); then
                msg "${YELLOW}[!] Hy2 node omitted from Clash YAML: sing-box config '${ABOX_SB_CFG:-/etc/sing-box/config.json}' is unverifiable; refusing to publish a node that cannot be confirmed live.${NC}" >&2
            else
                msg "${YELLOW}[!] Hy2 node omitted from Clash YAML: no live hysteria2 inbound in the sing-box config; refusing to publish a node with no server behind it.${NC}" >&2
            fi
        fi
    fi
    if (( _hy2_sb_live == 1 )); then
        hy2_pin_colon=$(hy2_cert_pin_colon 2>/dev/null || true)
        if [[ -n "$hy2_pin_colon" ]]; then
            hy2_fp_yaml=$(tr -d ':' <<< "$hy2_pin_colon")
        elif [[ "${HY2_CERT_SHA256_FP:-}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            hy2_fp_yaml="${HY2_CERT_SHA256_FP:-}"
            # A4: cached fingerprint in use — the live cert could not be read,
            # so this pin was NOT verified against the current certificate.
            msg "${YELLOW}[!] Hy2 pin from cached fingerprint; not verified against the current certificate.${NC}" >&2
        else
            hy2_fp_yaml=''
        fi
    else
        hy2_pin_colon=''
        hy2_fp_yaml=''
    fi
    if [[ "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ]]; then
        if [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]]; then
            hy2_yaml_emit=true
        elif [[ -n "$hy2_fp_yaml" ]]; then
            hy2_yaml_emit=true
        fi
    fi
    # L4: the gate above already emptied the fingerprint, so the MODE
    # branch cannot re-emit; this is belt-and-braces so a later edit
    # to the pin selection cannot resurrect the node.
    if (( _hy2_sb_live == 0 )); then hy2_yaml_emit=false; fi
    # H-24: Hy2 emission also honors the port flag (a bad port skips
    # the node even when a fingerprint is available).
    if (( _hy2_ports_bad == 1 )); then hy2_yaml_emit=false; fi
    # H-24: per-protocol port gates for the Clash YAML. A port is
    # skipped when it is empty or invalid (D-1): an empty port must
    # not keep the historical :-default (443/8443/2053), which would
    # emit a node pointing at a port that does not exist. Warnings
    # are plain English (precedent: the cached-fingerprint warning
    # above).
    local _vless_port_ok=1 _xhttp_port_ok=1 _ss_port_ok=1
    local _vision_emit=0 _xhttp_emit=0 _ss_emit=0 _vision_base_emit=0 _xhttp_base_emit=0
    # H-24(3): nodes actually emitted (multi-user lists below).
    local _hy2_emit=0
    local -a _hy2_names=() _hy2_passes=() _ss_names=() _ss_passes=()
    local -a _hy2_emit_names=() _ss_emit_names=()
    if ! valid_canonical_port "${VLESS_PORT:-}"; then
        # O1 (followup5 D-leg): warn only when a Vision node could
        # have been emitted (MODE scope, same as the emission gate
        # below); a HY2-only deploy must not warn about a port it
        # never uses. The flag still gates emission either way.
        if [[ "${MODE:-}" == *'VISION'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]]; then
            msg "${YELLOW}[!] VLESS port '${VLESS_PORT:-}' is missing or invalid; skipping Vision nodes in Clash YAML.${NC}" >&2
        fi
        _vless_port_ok=0
    fi
    if ! valid_canonical_port "${XHTTP_PORT:-}"; then
        # O1 (followup5 D-leg): XHTTP is xray-only (emission gated
        # on CORE == xray below); on a sing-box stack the warning is
        # pure cross-stack noise, so suppress it there. The flag
        # still gates emission either way.
        if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]]; then
            msg "${YELLOW}[!] XHTTP port '${XHTTP_PORT:-}' is missing or invalid; skipping XHTTP nodes in Clash YAML.${NC}" >&2
        fi
        _xhttp_port_ok=0
    fi
    if ! valid_canonical_port "${SS_PORT:-}"; then
        # O1 (followup5 D-leg): warn only when an SS node could have
        # been emitted (MODE scope, same as the emission gate below).
        # NOTE: on a sing-box ALL overlay with an empty .env SS_PORT
        # the warning still fires (MODE matches) and the live SS node
        # on the 2053 default is still skipped from the YAML -- that
        # is the deliberate H-24 rule (an empty port must not keep
        # the historical default), not noise; fixing the underlying
        # .env persistence gap is a separate item.
        if [[ "${MODE:-}" == *'SS'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]]; then
            msg "${YELLOW}[!] SS port '${SS_PORT:-}' is missing or invalid; skipping the SS node in Clash YAML.${NC}" >&2
        fi
        _ss_port_ok=0
    fi
    # Bootstrap DNS by VPS geolocation; Chinese defaults only for CN VPS.
    clash_country=$(_detect_vps_country 2>/dev/null || true)
    clash_ns1=$(_clash_default_nameservers "$clash_country" 2>/dev/null | sed -n '1p')
    clash_ns2=$(_clash_default_nameservers "$clash_country" 2>/dev/null | sed -n '2p')
    [[ -n "$clash_ns1" && -n "$clash_ns2" ]] || { clash_ns1='1.1.1.1'; clash_ns2='8.8.8.8'; }
    _clash_standalone_nodes_tmp=$(umask 077; mktemp "$base_real/.A-Box-clash-nodes.XXXXXX") || {
        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp"
        return 1
    }
    _clash_standalone_groups_tmp=$(umask 077; mktemp "$base_real/.A-Box-clash-groups.XXXXXX") || {
        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" "$_clash_standalone_nodes_tmp"
        return 1
    }
    if ! write_clash_standalone_yaml "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"; then
        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
            "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
        return 1
    fi
    # H-24(3): resolve the Hy2/SS node lists (name, raw password) from
    # the multi-user registries. Arrays need no temp-file cleanup.
    # A registry that EXISTS but cannot be parsed fails the whole
    # YAML (fail-closed: an untrusted user list must not silently
    # drop users); a missing registry, or fewer than two enabled
    # users, keeps the legacy single node. When a multi-user registry
    # is present but NO user's credential resolves, no node is
    # emitted for that protocol (the legacy single node would carry
    # a bare password that cannot authenticate in userpass /
    # clients-form mode); the per-user warnings above already say so.
    local _hy2_reg='' _hy2_tag='hy2-official' _hy2_core='hy2' _ss_reg='' _ss_core='xray'
    local _hy2_users_json='' _ss_users_json=''
    local _hy2_multi=0 _ss_multi=0 _hy2_count=0 _ss_count=0
    if [[ "${CORE:-}" == 'singbox' ]]; then _hy2_core='sing-box'; _hy2_tag='hy2'; _ss_core='sing-box'; fi
    _hy2_reg=$(users_reg_file "$_hy2_core" "$_hy2_tag")
    _ss_reg=$(users_reg_file "$_ss_core" 'ss')
    if [[ -e "$_hy2_reg" || -L "$_hy2_reg" ]]; then
        if ! _hy2_users_json=$(_clash_registry_users_json "$_hy2_reg" 2>/dev/null); then
            rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
            msg "${RED}Hy2 user registry unreadable; refusing to generate incomplete Clash config.${NC}" >&2
            return 1
        fi
        _hy2_count=$(printf '%s' "$_hy2_users_json" | grep -c . || true)
        if (( _hy2_count >= 2 )); then
            _hy2_multi=1
            local _u='' _uname='' _usecret='' _ulogin='' _upass=''
            while IFS= read -r _u; do
                [[ -n "$_u" ]] || continue
                _uname=$(printf '%s' "$_u" | jq -r '.name // ""' 2>/dev/null || true)
                _usecret=$(printf '%s' "$_u" | jq -r '.secret // ""' 2>/dev/null || true)
                _ulogin=$(printf '%s' "$_u" | jq -r '.login // ""' 2>/dev/null || true)
                [[ -n "$_uname" ]] || continue
                [[ -n "$_ulogin" ]] || _ulogin="$_uname"
                if ! _upass=$(_clash_hy2_user_password "$_ulogin" "$_usecret" "$_hy2_count" "${CORE:-}" 2>/dev/null); then
                    msg "${YELLOW}[!] Skipping Hy2 user '$_uname': no usable credential.${NC}" >&2
                    continue
                fi
                _hy2_names+=("$_uname")
                _hy2_passes+=("$_upass")
            done <<< "$_hy2_users_json"
        fi
    fi
    if [[ -e "$_ss_reg" || -L "$_ss_reg" ]]; then
        if ! _ss_users_json=$(_clash_registry_users_json "$_ss_reg" 2>/dev/null); then
            rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
            msg "${RED}SS user registry unreadable; refusing to generate incomplete Clash config.${NC}" >&2
            return 1
        fi
        _ss_count=$(printf '%s' "$_ss_users_json" | grep -c . || true)
        if (( _ss_count >= 2 )); then
            _ss_multi=1
            local _u='' _uname='' _upass=''
            while IFS= read -r _u; do
                [[ -n "$_u" ]] || continue
                _uname=$(printf '%s' "$_u" | jq -r '.name // ""' 2>/dev/null || true)
                [[ -n "$_uname" ]] || continue
                if ! _upass=$(ss_effective_password_for_user "$_uname" 2>/dev/null); then
                    msg "${YELLOW}[!] Skipping SS user '$_uname': no usable credential.${NC}" >&2
                    continue
                fi
                _ss_names+=("$_uname")
                _ss_passes+=("$_upass")
            done <<< "$_ss_users_json"
        fi
    fi
    if (( _hy2_multi == 0 )); then _hy2_names=('main'); _hy2_passes=("$_hy2_eff_pass"); fi
    if (( _ss_multi == 0 )); then _ss_names=('main'); _ss_passes=("$_ss_eff_pass"); fi
    {
        cat <<EOF_CLASH
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - ${clash_ns1}
    - ${clash_ns2}
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.internal"
    - "*.example"
    - "localhost"
    - "time.apple.com"
    - "captive.apple.com"
    - "detectportal.firefox.com"
    - "msftconnecttest.com"
    - "www.msftconnecttest.com"
    - "msftncsi.com"
    - "www.msftncsi.com"
    - "connectivitycheck.platform.hicloud.com"
    - "connectivitycheck.gstatic.com"
    - "ntp.tencent.com"
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
  fallback:
    - tls://8.8.4.4
    - tls://1.1.1.1

proxies:
EOF_CLASH
        if [[ "${MODE:-}" == *'VISION'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]] && (( _vless_port_ok == 1 )); then
            while IFS= read -r client_uuid; do
                [[ -n "$client_uuid" ]] || continue
                _vision_emit=1
                if [[ "$client_uuid" == "${UUID:-}" ]]; then proxy_name='Vision'; _vision_base_emit=1; else proxy_name="Vision-$client_uuid"; fi
                emit_mihomo_vless_proxy_block vision "$proxy_name" "$client_uuid" "$clash_mlkem"
            done < "$_clash_uuid_list_tmp"
        fi
        if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]] && (( _xhttp_port_ok == 1 )); then
            while IFS= read -r client_uuid; do
                [[ -n "$client_uuid" ]] || continue
                _xhttp_emit=1
                if [[ "$client_uuid" == "${UUID:-}" ]]; then proxy_name='XHTTP'; _xhttp_base_emit=1; else proxy_name="XHTTP-$client_uuid"; fi
                emit_mihomo_vless_proxy_block xhttp "$proxy_name" "$client_uuid" "$clash_mlkem"
            done <<< "$_xhttp_uuid_list"
        fi
        if [[ "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ]]; then
            if (( _hy2_ports_bad == 1 )); then
                echo '  # Hy2 omitted: port configuration invalid; refusing to emit a node with a bad port.'
            elif (( _hy2_sb_live == 0 )); then
                echo '  # Hy2 omitted: no live Hy2 inbound in the sing-box config; refusing to publish a node with no server behind it.'
            elif [[ "$hy2_yaml_emit" != true ]]; then
                echo '  # Hy2 omitted: certificate fingerprint unavailable; refusing to emit an insecure node.'
            else
                # H-24(3): one node per resolved Hy2 user. 08b-H1: the
                # old domain and == true single-node branches are gone
                # (with == true / != true they covered every value and
                # this loop was unreachable); the loop drives all four
                # templates itself (domain/IP x hop/plain), so a domain
                # no longer pins the output to one legacy node.
                # Single-user lists hold exactly the legacy pair, so
                # the single node is byte-identical to before.
                local _hy2_i=0
                for (( _hy2_i = 0; _hy2_i < ${#_hy2_names[@]}; _hy2_i++ )); do
                    if [[ "${_hy2_names[$_hy2_i]}" == 'main' ]]; then hy2_name='Hy2'; else hy2_name="Hy2-${_hy2_names[$_hy2_i]}"; fi
                    hy2_pass_yaml=$(json_escape "${_hy2_passes[$_hy2_i]}") || {
                        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                            "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
                        return 1
                    }
                    _hy2_emit=1
                    _hy2_emit_names+=("$hy2_name")
                    if [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]]; then
                        if [[ "${HY2_HOP:-}" == 'true' ]]; then
                            cat <<EOF_CLASH
  - name: "$hy2_name"
    type: hysteria2
    server: "${HY2_DOMAIN:-}"
    port: $clash_hop_port
    ports: ${HY2_CLASH_PORTS:-}
    hop-interval: 30
    password: ${hy2_pass_yaml}
    alpn:
      - h3
    sni: "${HY2_DOMAIN:-}"
    obfs: salamander
    obfs-password: ${hy2_obfs_yaml}
EOF_CLASH
                        else
                            cat <<EOF_CLASH
  - name: "$hy2_name"
    type: hysteria2
    server: "${HY2_DOMAIN:-}"
    port: ${HY2_BASE_PORT:-443}
    password: ${hy2_pass_yaml}
    alpn:
      - h3
    sni: "${HY2_DOMAIN:-}"
    obfs: salamander
    obfs-password: ${hy2_obfs_yaml}
EOF_CLASH
                        fi
                    elif [[ "${HY2_HOP:-}" == 'true' ]]; then
                        cat <<EOF_CLASH
  - name: "$hy2_name"
    type: hysteria2
    server: "$S_IP"
    port: $clash_hop_port
    ports: ${HY2_CLASH_PORTS:-}
    hop-interval: 30
    password: ${hy2_pass_yaml}
    alpn:
      - h3
    skip-cert-verify: true
    fingerprint: "$hy2_fp_yaml"
    obfs: salamander
    obfs-password: ${hy2_obfs_yaml}
EOF_CLASH
                    else
                        cat <<EOF_CLASH
  - name: "$hy2_name"
    type: hysteria2
    server: "$S_IP"
    port: ${HY2_BASE_PORT:-443}
    password: ${hy2_pass_yaml}
    alpn:
      - h3
    skip-cert-verify: true
    fingerprint: "$hy2_fp_yaml"
    obfs: salamander
    obfs-password: ${hy2_obfs_yaml}
EOF_CLASH
                    fi
                done
            fi
        fi
        if [[ "${MODE:-}" == *'SS'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]] && (( _ss_port_ok == 1 )); then
            # H-24(3): one node per resolved SS user; the single-user
            # list holds exactly the legacy pair, so the single node
            # is byte-identical to before.
            local _ss_i=0 _ss_node_name=''
            for (( _ss_i = 0; _ss_i < ${#_ss_names[@]}; _ss_i++ )); do
                if [[ "${_ss_names[$_ss_i]}" == 'main' ]]; then _ss_node_name='SS'; else _ss_node_name="SS-${_ss_names[$_ss_i]}"; fi
                ss_pass_yaml=$(json_escape "${_ss_passes[$_ss_i]}") || {
                    rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                        "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
                    return 1
                }
                _ss_emit=1
                _ss_emit_names+=("$_ss_node_name")
                cat <<EOF_CLASH
  - name: "$_ss_node_name"
    type: ss
    server: "${LINK_IP:-}"
    port: ${SS_PORT:-2053}
    cipher: 2022-blake3-aes-128-gcm
    password: ${ss_pass_yaml}
    udp: true
    smux:
      enabled: false
EOF_CLASH
            done
        fi
        cat -- "$_clash_standalone_nodes_tmp" || {
            rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
            return 1
        }
        cat <<EOF_CLASH

proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF_CLASH
        # H-24: proxy-groups list only nodes actually emitted above
        # (emission flags), never MODE alone: a skipped protocol must
        # not leave a dangling group entry. The base names are listed
        # only when the base node itself was emitted: with UUID empty
        # (or absent from the list) only suffixed nodes exist, so the
        # base name must not appear.
        (( _vision_base_emit == 1 )) && echo '      - Vision'
        (( _xhttp_base_emit == 1 )) && echo '      - XHTTP'
        # E62-NEW-01 (candidate B): Vision entries come from the merged
        # registry list, XHTTP entries from the live XHTTP inbound list,
        # matching the node loops above; a shared loop would re-advertise
        # live-absent XHTTP UUIDs in the group.
        while IFS= read -r client_uuid; do
            [[ -n "$client_uuid" && "$client_uuid" != "${UUID:-}" ]] || continue
            (( _vision_emit == 1 )) && echo "      - Vision-$client_uuid"
        done < "$_clash_uuid_list_tmp"
        while IFS= read -r client_uuid; do
            [[ -n "$client_uuid" && "$client_uuid" != "${UUID:-}" ]] || continue
            (( _xhttp_emit == 1 )) && echo "      - XHTTP-$client_uuid"
        done <<< "$_xhttp_uuid_list"
        # H-24(3): list exactly the Hy2/SS nodes emitted above.
        for proxy_name in "${_hy2_emit_names[@]}"; do echo "      - $proxy_name"; done
        for proxy_name in "${_ss_emit_names[@]}"; do echo "      - $proxy_name"; done
        cat -- "$_clash_standalone_groups_tmp" || {
            rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
            return 1
        }
        cat <<EOF_CLASH
      - DIRECT

rules:
  - MATCH,PROXY
EOF_CLASH
    } > "$tmp_out" || {
        rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
            "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
        return 1
    }
    # H-24: fail-closed on an empty export. When every protocol was
    # skipped (e.g. MODE=HY2 with an incomplete port-hop state), the
    # YAML would contain no proxies at all: refuse to emit an empty
    # client config instead of writing a useless file. This keeps the
    # self-test's 'client export accepted incomplete port-hop state'
    # assertion (rc=1, no file) while the per-protocol skip still
    # applies whenever at least one other node is emitted.
    # R60-M3: the emptiness test reads the groups file, not the nodes
    # file: the renderer writes "# ..." comments into the nodes file
    # for omitted nodes (P6 Reality-key failures, unreadable sources)
    # and exits 0, so a comment-only nodes file is non-empty while no
    # proxy was emitted; the groups file is written only when a real
    # node is emitted.
    if (( _vision_emit == 0 )) && (( _xhttp_emit == 0 )) && (( _hy2_emit == 0 )) && (( _ss_emit == 0 )) && [[ ! -s "$_clash_standalone_groups_tmp" ]]; then
        # L4: one exception to the refusal -- when the Hy2 node was
        # withheld by the live-inbound gate above and a stale YAML
        # already sits at $out, discarding tmp_out would leave that
        # file publishing the ghost node. Install the generated
        # (Hy2-less) file instead so the refresh actually removes the
        # old node. A fresh path with no file keeps the refusal: there
        # is nothing stale to replace.
        if (( _hy2_sb_live == 0 )) && [[ -f "$out" ]]; then
            msg "${YELLOW}[!] All protocols were skipped; replacing the stale Clash YAML with the current (Hy2-less) output so the removed node stops being published.${NC}" >&2
        else
            msg "${YELLOW}[!] All protocols were skipped; refusing to emit a Clash YAML with no proxies.${NC}" >&2
            rm -f -- "$tmp_out" "$_clash_uuid_list_tmp" \
                "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
            return 1
        fi
    fi
    rm -f -- "$_clash_uuid_list_tmp" \
        "$_clash_standalone_nodes_tmp" "$_clash_standalone_groups_tmp"
    chmod 600 "$tmp_out" || { rm -f -- "$tmp_out"; return 1; }
    [[ $EUID -eq 0 ]] && chown root:root "$tmp_out" || true
    [[ -d "$out" ]] && { rm -f -- "$tmp_out"; return 1; }
    mv -f -- "$tmp_out" "$out" || { rm -f -- "$tmp_out"; return 1; }
    chmod 600 "$out" || return 1
    printf '%s\n' "$out"
}
# U14 (D1): write a single-user Mihomo YAML for one user/node only.
# Same version gate (clash_reality_mlkem_enabled) and the same node data
# as write_clash_yaml, via the shared emit_mihomo_vless_proxy_block, so
# the per-user file agrees with the full YAML field for field. Only the
# requested user's UUID is emitted; other users' credentials never appear.
# Import the file directly in a Mihomo client (local file import); the
# raw vless:// links / QR codes are NOT a complete Mihomo delivery.
# $1 = uuid (default ${UUID:-}); $2 = out path (default
# ${MIHOMO_USER_YAML_PATH:-$ABOX_DIR/A-Box-mihomo-single.yaml}).
# Prints the output path on stdout. Returns 1 on bad uuid / bad path /
# gate or write failure; returns 2 when the node has no VLESS leg to
# deliver (preflight: nothing to write, no file is left behind).
# No public subscription service is created; the file is local-only, 600.
# R60-M2: is this UUID deliverable as an XHTTP node in the
# single-user file? Returns 0 when it may be emitted.
_mihomo_xhttp_uuid_deliverable() {
    local _uuid="$1" _live='' _reg_tmp=''
    if _live=$(list_xhttp_live_uuids 2>/dev/null); then
        # Live inbound readable: authoritative even when empty.
        [[ -n "$_live" ]] || return 1
        if grep -qxF -- "$_uuid" <<< "$_live"; then return 0; else return 1; fi
    fi
    # Live unreadable / no inbound: merged-registry fallback.
    _reg_tmp=$(umask 077; mktemp /tmp/A-Box-mihomo-single-uuid.XXXXXX) || return 1
    if ! write_full_uuid_list_to_file "$_reg_tmp" 2>/dev/null; then
        rm -f -- "$_reg_tmp"
        return 1
    fi
    if grep -qxF -- "$_uuid" "$_reg_tmp"; then
        rm -f -- "$_reg_tmp"
        return 0
    fi
    rm -f -- "$_reg_tmp"
    return 1
}

write_mihomo_user_yaml() {
    local _uuid="${1:-${UUID:-}}" out="${2:-${MIHOMO_USER_YAML_PATH:-$ABOX_DIR/A-Box-mihomo-single.yaml}}"
    local clash_mlkem=false clash_mlkem_rc tmp_out out_real base_real
    local _has_vision=0 _has_xhttp=0 _emit_rc=0
    # S1-NEW-06: the UUID gate lives below the stale-file removal, not
    # here: a UUID-less node (Hy2-only .env has UUID="") must still reach
    # the removal branch, or its dead single-user file is never cleaned.
    if clash_reality_mlkem_enabled; then
        clash_mlkem=true
    else
        clash_mlkem_rc=$?
        (( clash_mlkem_rc == 1 )) || return 1
    fi
    [[ -n "$out" && "$out" == /* ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    ensure_abox_dir_owned "$ABOX_DIR" || return 1
    base_real=$(python3 -I - "$ABOX_DIR" <<'PY_CLASH_REALPATH'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY_CLASH_REALPATH
) || return 1
    out_real=$(python3 -I - "$out" <<'PY_CLASH_REALPATH'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY_CLASH_REALPATH
) || return 1
    [[ "$out_real" == "$base_real"/* ]] || return 1
    [[ ! -L "$out" ]] || return 1
    [[ ! -e "$out" || -f "$out" ]] || { msg "${RED}Refusing to write Mihomo config: output path exists and is not a regular file: $out${NC}" >&2; return 1; }
    # Nothing to deliver unless a VLESS Reality leg exists for this node.
    # R60-M1: same per-protocol port gates as write_clash_yaml (H-24):
    # an empty or invalid port must not keep the historical :-default
    # (443/8443) and emit a node pointing at a port that does not exist.
    if [[ "${MODE:-}" == *'VISION'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]]; then
        if valid_canonical_port "${VLESS_PORT:-}"; then
            _has_vision=1
        else
            msg "${YELLOW}[!] VLESS port '${VLESS_PORT:-}' is missing or invalid; skipping Vision node in Mihomo single-user YAML.${NC}" >&2
        fi
    fi
    if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]]; then
        if valid_canonical_port "${XHTTP_PORT:-}"; then
            _has_xhttp=1
        else
            msg "${YELLOW}[!] XHTTP port '${XHTTP_PORT:-}' is missing or invalid; skipping XHTTP node in Mihomo single-user YAML.${NC}" >&2
        fi
    fi
    # S1-Low-1 (final-round follow-up): a deploy with no VLESS leg (SS /
    # HY2-only / ...) must not leave a stale single-user file behind: the
    # file can only ever hold Vision / XHTTP nodes, so any content in it
    # is dead the moment this node has no such leg. Reached only after
    # the symlink / non-regular guards above, so $out here is either
    # absent or a regular file under $ABOX_DIR. Best-effort: a removal
    # failure must not fail the deploy (the file is advisory only).
    if (( _has_vision == 0 && _has_xhttp == 0 )) && [[ -f "$out" ]]; then
        rm -f -- "$out" 2>/dev/null || true
    fi
    # S1-NEW-06: UUID gate (moved down from the top of this function so
    # the removal above still runs for a UUID-less no-leg node). Still
    # returns 1 on a bad UUID, so the caller warning is unchanged; the
    # removal above already ran under the path guards, so $out here is
    # either absent or a regular file under $ABOX_DIR.
    [[ -n "$_uuid" ]] || return 1
    [[ "$_uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
    # R60-M2: the XHTTP leg follows the full export's live-list
    # authority (E62-NEW-01 in write_clash_yaml).
    if (( _has_xhttp == 1 )) && ! _mihomo_xhttp_uuid_deliverable "$_uuid"; then
        msg "${YELLOW}[!] XHTTP client is not in the live XHTTP inbound; skipping XHTTP node in Mihomo single-user YAML.${NC}" >&2
        _has_xhttp=0
    fi
    (( _has_vision == 1 || _has_xhttp == 1 )) || return 2
    tmp_out=$(mktemp "$base_real/.A-Box-mihomo-single-new.XXXXXX") || return 1
    {
        cat <<EOF_MIHOMO_SINGLE
# A-Box single-user Mihomo config: only this user's Vision / XHTTP node.
# Import this file directly in a Mihomo client (local file import).
# Do not scan single vless:// links for Mihomo: they carry no
# reality-opts, and on Xray >= v26.9.8 the handshake needs
# support-x25519mlkem768, which is set below from the installed version.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
EOF_MIHOMO_SINGLE
        if (( _has_vision == 1 )); then emit_mihomo_vless_proxy_block vision 'Vision' "$_uuid" "$clash_mlkem" || _emit_rc=1; fi
        if (( _has_xhttp == 1 )); then emit_mihomo_vless_proxy_block xhttp 'XHTTP' "$_uuid" "$clash_mlkem" || _emit_rc=1; fi
        cat <<EOF_MIHOMO_SINGLE
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF_MIHOMO_SINGLE
        (( _has_vision == 1 )) && echo '      - Vision'
        (( _has_xhttp == 1 )) && echo '      - XHTTP'
        cat <<EOF_MIHOMO_SINGLE
      - DIRECT

rules:
  - MATCH,PROXY
EOF_MIHOMO_SINGLE
    } > "$tmp_out" || { rm -f -- "$tmp_out"; return 1; }
    (( _emit_rc == 0 )) || { rm -f -- "$tmp_out"; return 1; }
    chmod 600 "$tmp_out" || { rm -f -- "$tmp_out"; return 1; }
    [[ $EUID -eq 0 ]] && chown root:root "$tmp_out" || true
    mv -f -T -- "$tmp_out" "$out" || { rm -f -- "$tmp_out"; return 1; }
    chmod 600 "$out" || return 1
    printf '%s\n' "$out"
}

ensure_qrencode() {
    command -v qrencode >/dev/null 2>&1 && return 0
    [[ -n "${_QR_ENSURED:-}" ]] && return 1
    _QR_ENSURED=1
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -q >/dev/null 2>&1 || true
        apt-get -y install qrencode >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y install qrencode >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum -y install qrencode >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        # Alpine <=3.18 ships the qrencode CLI in libqrencode itself;
        # >=3.19 splits it into libqrencode-tools. Try both.
        apk add --no-cache libqrencode-tools >/dev/null 2>&1 || apk add --no-cache libqrencode >/dev/null 2>&1 || true
    fi
    command -v qrencode >/dev/null 2>&1
}
generate_qr() {
    local url=$1
    ensure_qrencode || true
    if command -v qrencode >/dev/null 2>&1; then
        printf '\n%s\n' "${CYAN}$(tr_msg generate_qr_scan_banner)${NC}"
        printf '%s' "$url" | qrencode -s 1 -m 2 -t UTF8
        printf '%s\n\n' "${CYAN}==========================================================${NC}"
    elif [[ -z "${_QR_MISSING_WARNED:-}" ]]; then
        _QR_MISSING_WARNED=1
        msg "${YELLOW}[!] $(tr_msg generate_qr_qrencode_missing)${NC}"
        msg "${YELLOW}    Debian/Ubuntu: sudo apt install -y qrencode${NC}"
        msg "${YELLOW}    Rocky/Alma/Fedora: sudo dnf install -y qrencode${NC}"
        msg "${YELLOW}    Alpine: sudo apk add libqrencode-tools (<=3.18: libqrencode)${NC}"
    fi
}


build_hy2_uri_endpoint() {
    local raw="${HY2_URI_PORTS:-}" range
    if [[ -z "$raw" ]]; then
        if [[ "${HY2_HOP:-false}" == true && "${HY2_HOP_IMPL:-none}" == manual && "${HY2_BASE_PORT:-}" =~ ^[0-9]+$ && "${HY2_RANGE_START:-}" =~ ^[0-9]+$ && "${HY2_RANGE_END:-}" =~ ^[0-9]+$ ]]; then
            range="${HY2_RANGE_START}-${HY2_RANGE_END}"
            raw="${HY2_BASE_PORT},${range}"
        else
            raw="${HY2_BASE_PORT:-443}"
        fi
    fi
    valid_hy2_uri_ports "$raw" || return 1
    printf '%s\t%s\n' "$raw" ''
}

# E19: build the hysteria2:// standalone URL from live state — the same
# shape view_config emits (same pin rule, same branch order). $1 = auth
# password (raw), $2 = obfs password (raw), $3 = host override (IP or
# domain; default HY2_DOMAIN, else LINK_IP/F_IP). $4 = optional username:
# when given, emit the user:pass composite the server expects under
# userpass auth (a bare password is a dead link there); when empty,
# emit the bare password (password auth, and all pre-existing callers).
# Prints the URL on stdout; returns 1 when no usable link can be built (missing secrets,
# bad port endpoint, or the SYD-B4 A3 pin refusal: no pin and (no domain
# or sing-box core)). Callers register the result with
# register_standalone_link; the link file is 600 and may carry the real
# obfs password, like the other standalone links carry real secrets.
hy2_standalone_url() {
    local _pass="${1:-}" _obfs="${2:-}" _host="${3:-}" _user="${4:-}" _port='' _qp='' _pin='' _pe='' _he='' _oe='' _de='' _ui=''
    [[ -n "$_pass" && -n "$_obfs" ]] || return 1
    IFS=$'\t' read -r _port _qp < <(build_hy2_uri_endpoint 2>/dev/null || true) || return 1
    [[ -n "$_port" ]] || return 1
    if [[ -z "$_host" ]]; then
        if [[ -n "${HY2_DOMAIN:-}" ]]; then _host="$HY2_DOMAIN";
        elif [[ -n "${LINK_IP:-}" ]]; then _host="$LINK_IP";
        # S2-NEW-12 follow-up 5: LINK_IP/F_IP are unset in a
        # fresh-deploy process, so the SILENT Hy2 sub-deploy's
        # register step could build no host and never created
        # hy2.link; GLOBAL_PUBLIC_IP is set by pre_install_setup
        # before any deployer runs, so it is the live host here.
        elif [[ -n "${GLOBAL_PUBLIC_IP:-}" ]]; then _host="$GLOBAL_PUBLIC_IP";
        else _host="${F_IP:-}"; fi
    fi
    [[ -n "$_host" && "$_host" != 'N/A' ]] || return 1
    if [[ "$_host" == *:* && "$_host" != \[*\] ]]; then _host="[$_host]"; fi
    _pin=$(hy2_cert_pin_colon 2>/dev/null || true)
    if [[ -z "$_pin" && "${HY2_CERT_SHA256_FP:-}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        _pin=$(sed 's/\(..\)/\1:/g; s/:$//' <<< "${HY2_CERT_SHA256_FP}")
    fi
    _pe=$(urlencode "$_pin")
    # SYD-B4 A3 (same rule as view_config): a pin branch with no usable
    # pin refuses this link only.
    if [[ -z "$_pe" ]] && [[ -z "${HY2_DOMAIN:-}" || "${CORE:-}" == 'singbox' ]]; then return 1; fi
    _he=$(urlencode "$_pass"); _oe=$(urlencode "$_obfs"); _de=$(urlencode "${HY2_DOMAIN:-}")
    # FUP4: userpass auth needs the composite userinfo; password auth
    # (and every pre-existing 3-arg caller) keeps the bare password.
    _ui="$_he"
    [[ -n "$_user" ]] && _ui="$(urlencode "$_user"):$_he"
    if [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]]; then
        printf 'hysteria2://%s@%s:%s/?%ssni=%s&obfs=salamander&obfs-password=%s#Hy2' "$_ui" "$_host" "$_port" "$_qp" "$_de" "$_oe"
    elif [[ -n "${HY2_DOMAIN:-}" ]]; then
        printf 'hysteria2://%s@%s:%s/?%sinsecure=1&pinSHA256=%s&obfs=salamander&obfs-password=%s#Hy2' "$_ui" "$_host" "$_port" "$_qp" "$_pe" "$_oe"
    else
        printf 'hysteria2://%s@%s:%s/?%ssni=localhost&insecure=1&pinSHA256=%s&obfs=salamander&obfs-password=%s#Hy2' "$_ui" "$_host" "$_port" "$_qp" "$_pe" "$_oe"
    fi
}


# Registered standalone links, shown with a QR per URI. Usable without
# .env: the files are self-contained (title line + URI lines).
show_standalone_links() {
    if [[ -d "${ABOX_DIR:-/etc/ddr}/standalone-links.d" ]]; then
        local _lf _lt _lu _shown_sa=0
        for _lf in "${ABOX_DIR:-/etc/ddr}/standalone-links.d"/*.link; do
            [[ -f "$_lf" ]] || continue
            if (( ! _shown_sa )); then
                msg "${YELLOW}$(tr_msg show_standalone_links_title)${NC}"
                _shown_sa=1
            fi
            _lt=$(sed -n '1p' "$_lf")
            msg "${BOLD}${CYAN}── ${_lt}${NC}"
            while IFS= read -r _lu; do
                [[ -n "$_lu" ]] || continue
                msg "${GREEN}${_lu}${NC}"
                generate_qr "$_lu"
            done < <(sed -n '2,$p' "$_lf")
        done
    fi
}

# SYD-B3 E15: hysteria pinSHA256 is the whole-certificate SHA256
# fingerprint in colon-hex (the format hysteria validates), NOT the
# SPKI SHA256 base64 (SYD-B's claim, falsified by box matrix 2026-10-31:
# only DER-colon + insecure + SNI=localhost dials through). An explicit
# path argument overrides the CORE-based certificate resolution; the
# caller falls back to the stored .env fingerprint only when the
# certificate is unreadable.
hy2_cert_pin_colon() {
    local crt="${1:-}"
    if [[ -z "$crt" ]]; then
        case "${CORE:-}" in
            singbox) crt='/etc/sing-box/hy2.crt' ;;
            *) crt='/etc/hysteria/server.crt' ;;
        esac
    fi
    [[ -f "$crt" && ! -L "$crt" ]] || return 1
    local fp
    fp=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//') || return 1
    [[ "$fp" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || return 1
    printf '%s' "$fp"
}

view_config() {
    local CALLER=${1:-manual}
    clear
    [[ ! -f "$ABOX_ENV" ]] && { msg "${RED}$(tr_msg view_config_no_persisted_vars)${NC}"; show_standalone_links; pause_return; return 0; }
    load_abox_env "$ABOX_ENV" || die "$(tr_msg view_config_state_file_invalid)"
    if [[ -z "${CORE:-}" || -z "${MODE:-}" ]]; then show_standalone_links; pause_return; return 0; fi
    local refreshed_ip
    refreshed_ip=$(refresh_public_ip || true)
    if [[ -n "$refreshed_ip" && "$refreshed_ip" != 'N/A' && "$refreshed_ip" != "${LINK_IP:-}" ]]; then
        LINK_IP="$refreshed_ip"
        write_env || die "$(tr_msg view_config_public_ip_changed_save_failed)"
    fi
    VISION_SNI=${VISION_SNI:-${VLESS_SNI:-}}
    XHTTP_SNI=${XHTTP_SNI:-${VLESS_SNI:-}}
    # U224: capture the global CLASH_SUB_URL before the local below
    # shadows it; otherwise ${CLASH_SUB_URL:-} at assignment time reads
    # the (empty) local and the global fallback never works.
    local _clash_sub_global="${CLASH_SUB_URL:-}"
    local F_IP="${LINK_IP:-}" S_IP VLESS_URL XHTTP_URL HY2_URL SS_URL CLASH_FILE CLASH_SUB_URL CLASH_SCHEME MIHOMO_USER_FILE _mihomo_single_rc=0
    local VISION_SNI_E XHTTP_SNI_E PUBLIC_KEY_E SHORT_ID_E HY2_PASS_E HY2_OBFS_E HY2_DOMAIN_E HY2_PIN_E HY2_URI_PORT HY2_QUERY_PREFIX _hy2_tls_json _hy2_eff_pass _sb_json_started _vless_ok _xhttp_ok _ss_ok _hy2_json_ok _host_ok
    # H-24: a bad Hy2 port endpoint skips the Hy2 blocks below (and warns)
    # instead of killing the whole view (menu 12 must not die on one
    # protocol's port problem).
    IFS=$'\t' read -r HY2_URI_PORT HY2_QUERY_PREFIX < <(build_hy2_uri_endpoint) || { msg "${YELLOW}[!] Hy2 port endpoint is invalid; Hy2 links skipped in this view.${NC}"; HY2_URI_PORT=''; HY2_QUERY_PREFIX=''; }
    F_IP=$(uri_host "${LINK_IP:-}")
    [[ -z "${LINK_IP:-}" || "${LINK_IP:-}" == 'N/A' ]] && msg "${YELLOW}[!] $(tr_msg view_config_public_ip_unavailable)${NC}"
    VISION_SNI_E=$(urlencode "${VISION_SNI:-}")
    XHTTP_SNI_E=$(urlencode "${XHTTP_SNI:-}")
    PUBLIC_KEY_E=$(urlencode "${PUBLIC_KEY:-}")
    SHORT_ID_E=$(urlencode "${SHORT_ID:-}")
    # H-24: the URL userinfo carries the effective Hy2 credential
    # (login:secret for multi-user userpass); urlencode turns the ':'
    # into %3A in one pass over the composite string.
    _hy2_eff_pass=$(hy2_effective_password 2>/dev/null || printf '%s' "${HY2_PASS:-}")
    _hy2_eff_pass=${_hy2_eff_pass%__ABOX_TRAILING_NL_KEEP__}
    HY2_PASS_E=$(urlencode "$_hy2_eff_pass")
    HY2_OBFS_E=$(urlencode "${HY2_OBFS:-}")
    HY2_DOMAIN_E=$(urlencode "${HY2_DOMAIN:-}")
    # SYD-B3 E15: pinSHA256 is the whole-certificate fingerprint in
    # colon-hex (box matrix 2026-10-31: only DER-colon + insecure=1 +
    # SNI=localhost dials through; SPKI base64 never matches).
    # Recompute from the live certificate; fall back to the stored
    # .env fingerprint (re-colonized) only when it is unreadable.
    # R25-F-S1-09: only a deployed Hy2 has a certificate to check; on a
    # Vision-only (or any non-Hy2) node the unreadable-cert warning is noise.
    if [[ "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ]]; then
        HY2_PIN_E=$(hy2_cert_pin_colon 2>/dev/null || true)
        if [[ -z "$HY2_PIN_E" && "${HY2_CERT_SHA256_FP:-}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            HY2_PIN_E=$(sed 's/\(..\)/\1:/g; s/:$//' <<< "${HY2_CERT_SHA256_FP:-}")
            # A4: cached fingerprint in use — the live cert could not be read,
            # so this pin was NOT verified against the current certificate.
            msg "${YELLOW}[!] Hy2 pin from cached fingerprint; not verified against the current certificate.${NC}" >&2
        fi
        [[ -n "$HY2_PIN_E" ]] || msg "${YELLOW}[!] Hy2 certificate unreadable; pinSHA256 left empty.${NC}" >&2
    fi
    HY2_PIN_E=$(urlencode "${HY2_PIN_E:-}")
    # H-24: per-protocol port gates (parent decision: skip the block and
    # warn, never die the whole view). A port is skipped when it is set
    # but invalid; an empty port is invalid here because view_config
    # emits the raw value with no default (unlike the Clash YAML's
    # :-defaults). The UUID is required for the VLESS URLs as well.
    _vless_ok=1; _xhttp_ok=1; _ss_ok=1; _hy2_json_ok=1; _sb_json_started=0
    # 08c-M2: LINK_IP empty or 'N/A' is not a usable URI host (the
    # top already warned about it). The port/UUID gates alone still
    # emitted `vless://UUID@:port` or host-`N/A` links plus QR codes,
    # and the XHTTP/SS/Hy2 branches share the same F_IP. A bad host
    # clears all three F_IP gates (the SS/XHTTP JSON blocks below
    # read _ss_ok/_xhttp_ok, so they are covered too); the Hy2
    # blocks below additionally accept a usable HY2_DOMAIN instead
    # of the host.
    _host_ok=1
    [[ -z "${LINK_IP:-}" || "${LINK_IP:-}" == 'N/A' ]] && _host_ok=0
    if (( _host_ok == 0 )); then _vless_ok=0; _xhttp_ok=0; _ss_ok=0; fi
    if [[ "$MODE" == *'VISION'* || "$MODE" == *'ALL'* || "$MODE" == 'VLESS_SS' ]]; then
        if ! valid_canonical_port "${VLESS_PORT:-}" || [[ -z "${UUID:-}" ]]; then
            msg "${YELLOW}[!] VLESS port '${VLESS_PORT:-}' is invalid or UUID is missing; Vision link skipped.${NC}"
            _vless_ok=0
        fi
    fi
    if [[ "$CORE" == 'xray' && ( "$MODE" == *'XHTTP'* || "$MODE" == *'ALL'* ) ]]; then
        if ! valid_canonical_port "${XHTTP_PORT:-}" || [[ -z "${UUID:-}" ]]; then
            msg "${YELLOW}[!] XHTTP port '${XHTTP_PORT:-}' is invalid or UUID is missing; XHTTP link skipped.${NC}"
            _xhttp_ok=0
        fi
    fi
    if [[ "$MODE" == *'SS'* || "$MODE" == *'ALL'* || "$MODE" == 'VLESS_SS' ]]; then
        if ! valid_canonical_port "${SS_PORT:-}"; then
            msg "${YELLOW}[!] SS port '${SS_PORT:-}' is invalid; Shadowsocks link skipped.${NC}"
            _ss_ok=0
        fi
    fi
    if [[ "$MODE" == *'HY2'* || "$MODE" == *'ALL'* ]]; then
        [[ -z "$HY2_URI_PORT" ]] && _hy2_json_ok=0
        if [[ "${HY2_HOP:-}" != 'true' ]] && ! valid_canonical_port "${HY2_BASE_PORT:-443}"; then
            msg "${YELLOW}[!] Hy2 base port '${HY2_BASE_PORT:-}' is invalid; sing-box Hy2 example skipped.${NC}"
            _hy2_json_ok=0
        fi
    fi
    msg "${BLUE}======================================================================${NC}"
    msg "${BOLD}${CYAN}$(tprintf view_config_network_params_title "${MODE:-}")${NC}"
    msg "${BLUE}======================================================================${NC}"
    msg "${BOLD}$(tr_msg view_config_engine_stack_label)${NC} ${CORE:-} | ${BOLD}$(tr_msg view_config_mode_label)${NC} ${MODE:-}"
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${YELLOW}[ $(tr_msg view_config_single_node_uri_title) ]${NC}"
    if [[ "${MODE:-}" == *'VISION'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]] && (( _vless_ok == 1 )); then
        VLESS_URL="vless://${UUID:-}@$F_IP:${VLESS_PORT:-}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$VISION_SNI_E&fp=chrome&pbk=$PUBLIC_KEY_E&sid=$SHORT_ID_E&type=tcp#Vision"
        msg "${BOLD}${CYAN}── $(tprintf view_config_vless_vision_reality_port "${VLESS_PORT:-}")${NC}"
        msg "${GREEN}${VLESS_URL}${NC}"
        if [[ "${CORE:-}" == 'xray' ]] && [[ "$CALLER" != 'deploy' ]] && xray_reality_requires_mlkem; then
            msg "${YELLOW}$(tprintf vc_xray_mlkem_compat "$(effective_xray_version)")${NC}"
        fi
        generate_qr "$VLESS_URL"
    fi
    if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]] && (( _xhttp_ok == 1 )); then
        XHTTP_URL="vless://${UUID:-}@$F_IP:${XHTTP_PORT:-}?encryption=none&security=reality&sni=$XHTTP_SNI_E&fp=chrome&pbk=$PUBLIC_KEY_E&sid=$SHORT_ID_E&type=xhttp&host=$XHTTP_SNI_E&path=%2Fxhttp&mode=stream-one#XHTTP"
        msg "${BOLD}${CYAN}── $(tprintf view_config_vless_xhttp_reality_port "${XHTTP_PORT:-}")${NC}"
        msg "${GREEN}${XHTTP_URL}${NC}"
        # L-4: pure-XHTTP mode never reaches the VISION branch above,
        # so print the ML-KEM note here too; in ALL/VISION modes the
        # VISION branch already printed it once.
        if [[ "${CORE:-}" == 'xray' ]] && [[ "$CALLER" != 'deploy' ]] && xray_reality_requires_mlkem; then
            if (( _vless_ok == 0 )) || [[ "${MODE:-}" != *'VISION'* && "${MODE:-}" != *'ALL'* && "${MODE:-}" != 'VLESS_SS' ]]; then
                msg "${YELLOW}$(tprintf vc_xray_mlkem_compat "$(effective_xray_version)")${NC}"
            fi
        fi
        generate_qr "$XHTTP_URL"
    fi
    if [[ "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ]] && [[ -n "$HY2_URI_PORT" ]] && { [[ -n "${HY2_DOMAIN:-}" ]] || (( _host_ok == 1 )); }; then
        # SYD-B4 A3: a pin branch with no usable pin refuses this link
        # only; the rest of view_config continues. Never emit an insecure
        # link with an empty pinSHA256.
        if [[ -z "$HY2_PIN_E" ]] && [[ -z "${HY2_DOMAIN:-}" || "${CORE:-}" == 'singbox' ]]; then
            msg "${RED}[!] $(tr_msg view_config_hy2_fingerprint_unavailable)${NC}"
        else
        if [[ -n "${HY2_DOMAIN:-}" && "${CORE:-}" != 'singbox' ]]; then
            HY2_URL="hysteria2://$HY2_PASS_E@${HY2_DOMAIN:-}:$HY2_URI_PORT/?${HY2_QUERY_PREFIX}sni=$HY2_DOMAIN_E&obfs=salamander&obfs-password=$HY2_OBFS_E#Hy2"
        elif [[ -n "${HY2_DOMAIN:-}" ]]; then
            HY2_URL="hysteria2://$HY2_PASS_E@${HY2_DOMAIN:-}:$HY2_URI_PORT/?${HY2_QUERY_PREFIX}insecure=1&pinSHA256=$HY2_PIN_E&obfs=salamander&obfs-password=$HY2_OBFS_E#Hy2"
        else
            HY2_URL="hysteria2://$HY2_PASS_E@$F_IP:$HY2_URI_PORT/?${HY2_QUERY_PREFIX}sni=localhost&insecure=1&pinSHA256=$HY2_PIN_E&obfs=salamander&obfs-password=$HY2_OBFS_E#Hy2"
        fi
        msg "${BOLD}${CYAN}── $(tprintf view_config_hy2_port "${HY2_URI_PORT}")${NC}"
        msg "${GREEN}${HY2_URL}${NC}"
        [[ "${HY2_HOP:-}" == 'true' ]] && msg "${YELLOW}$(tr_msg view_config_port_hop_interval_note)${NC}"
        generate_qr "$HY2_URL"
        fi
    fi
    if [[ "${MODE:-}" == *'SS'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]] && (( _ss_ok == 1 )); then
        SS_URL=$(build_ss2022_uri "$F_IP" "${SS_PORT:-}" "$(ss_effective_password 2>/dev/null || printf '%s' "${SS_PASS:-}")")
        msg "${BOLD}${CYAN}── $(tprintf view_config_ss2022_port "${SS_PORT:-}")${NC}"
        msg "${GREEN}${SS_URL}${NC}"
        generate_qr "$SS_URL"
    fi

    # 08c-M1: H-24 menu tolerance: a failed Clash YAML must not kill
    # the whole view. The writer refusing an empty config is correct
    # fail-closed; losing the mihomo YAML, the subscription refresh
    # and the return to menu over it is not. Warn and continue with
    # no Clash file; the YAML display below is guarded on it.
    CLASH_FILE=$(write_clash_yaml) || { msg "${YELLOW}[!] $(tr_msg view_config_clash_yaml_failed)${NC}"; CLASH_FILE=''; }
    MIHOMO_USER_FILE=$(write_mihomo_user_yaml 2>/dev/null) || _mihomo_single_rc=$?
    # S2-NEW-03 follow-up: menu 12 reprints the YAML from the live
    # state; refresh the subscription export alongside it so the two
    # artifacts never disagree after an add-user. Deploy callers
    # already refreshed just before this view (CALLER=deploy), so
    # only the manual reprint path refreshes here (no double refresh
    # at deploy end). Best-effort: a stale export must not fail the view.
    if [[ "$CALLER" != 'deploy' ]]; then
        refresh_subscription_after_deploy || true
    fi
    CLASH_SUB_URL="${ABOX_CLASH_SUB_URL:-${_clash_sub_global:-}}"
    if [[ -n "$CLASH_FILE" ]]; then
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${YELLOW}[ $(tr_msg view_config_clash_full_config_title) ]${NC}"
    msg "${GREEN}Local YAML: ${CLASH_FILE}${NC}"
    msg "${YELLOW}$(tr_msg view_config_clash_import_note)${NC}"
    if [[ -n "$CLASH_SUB_URL" ]]; then
        CLASH_SCHEME="clash://install-config?url=$(urlencode "$CLASH_SUB_URL")"
        msg "${GREEN}Subscription URL: ${CLASH_SUB_URL}${NC}"
        generate_qr "$CLASH_SUB_URL"
        msg "${GREEN}Clash Verge Rev URL Scheme: ${CLASH_SCHEME}${NC}"
        generate_qr "$CLASH_SCHEME"
    else
        local _clash_launch=''
        _clash_launch=$(shortcut_primary_names 2>/dev/null | awk '{print $1; exit}' 2>/dev/null || true)
        _clash_launch=${_clash_launch:-ab}
        msg "${YELLOW}$(tprintf view_config_clash_sub_url_missing "${CLASH_FILE}")${NC}"
        msg "${CYAN}ABOX_CLASH_SUB_URL='https://example.com/A-Box-clash.yaml' ${_clash_launch}${NC}"
    fi
    fi

    if [[ -n "${MIHOMO_USER_FILE:-}" ]]; then
        msg "${YELLOW}[ $(tr_msg view_config_mihomo_single_title) ]${NC}"
        msg "${GREEN}Local YAML (this user only): ${MIHOMO_USER_FILE}${NC}"
        msg "${YELLOW}$(tr_msg view_config_mihomo_single_note)${NC}"
    elif [[ "$_mihomo_single_rc" != '2' ]]; then
        msg "${YELLOW}$(tr_msg view_config_mihomo_single_failed)${NC}"
    fi

    if [[ -n "$CLASH_FILE" ]]; then
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    msg "${YELLOW}[ $(tr_msg view_config_clash_yaml_preview_title) ]${NC}"
    sed -n '1,220p' "$CLASH_FILE" 2>/dev/null || true
    fi

    printf '\n%s\n' "${YELLOW}--- $(tr_msg view_config_singbox_outbound_example) ---${NC}"
    if [[ "${MODE:-}" == *'HY2'* || "${MODE:-}" == *'ALL'* ]] && (( _hy2_json_ok == 1 )) && { [[ -n "${HY2_DOMAIN:-}" ]] || (( _host_ok == 1 )); }; then
        S_IP="${LINK_IP:-}"
        S_IP="${S_IP#[}"; S_IP="${S_IP%]}"
        [[ -n "${HY2_DOMAIN:-}" ]] && S_IP="${HY2_DOMAIN:-}"
        if [[ "${HY2_HOP:-}" == 'true' ]]; then
            if valid_hy2_sb_ports "${HY2_SB_PORTS:-}"; then
                # U223: check the TLS fragment BEFORE embedding it; the
                # old $(...) inside the heredoc silently produced a
                # dangling comma and a missing tls block on failure.
                _hy2_tls_json=$(singbox_hy2_tls_json) || msg "${RED}[!] $(tr_msg view_config_singbox_tls_failed_skip)${NC}"
                if [[ -n "$_hy2_tls_json" ]]; then
                if (( _sb_json_started == 0 )); then printf '    [\n'; _sb_json_started=1; else printf '    ,\n'; fi
                cat <<EOF_SB
    {
      "type": "hysteria2",
      "server": "$S_IP",
      "server_ports": ["${HY2_SB_PORTS:-}"],
      "hop_interval": "30s",
      "password": $(json_escape "$_hy2_eff_pass"),
${_hy2_tls_json},
      "obfs": {
        "type": "salamander",
        "password": $(json_escape "${HY2_OBFS:-}")
      }
    }
EOF_SB
                fi
            else
                msg "${YELLOW}[!] $(tr_msg view_config_hy2_port_hop_state_invalid)${NC}"
            fi
        else
            _hy2_tls_json=$(singbox_hy2_tls_json) || msg "${RED}[!] $(tr_msg view_config_singbox_tls_failed_skip)${NC}"
            if [[ -n "$_hy2_tls_json" ]]; then
            if (( _sb_json_started == 0 )); then printf '    [\n'; _sb_json_started=1; else printf '    ,\n'; fi
            cat <<EOF_SB
    {
      "type": "hysteria2",
      "server": "$S_IP",
      "server_port": ${HY2_BASE_PORT:-443},
      "password": $(json_escape "$_hy2_eff_pass"),
${_hy2_tls_json},
      "obfs": {
        "type": "salamander",
        "password": $(json_escape "${HY2_OBFS:-}")
      }
    }
EOF_SB
            fi
        fi
    fi
    if [[ "${MODE:-}" == *'SS'* || "${MODE:-}" == *'ALL'* || "${MODE:-}" == 'VLESS_SS' ]] && (( _ss_ok == 1 )); then
        if (( _sb_json_started == 0 )); then printf '    [\n'; _sb_json_started=1; else printf '    ,\n'; fi
        cat <<EOF_SB
    {
      "type": "shadowsocks",
      "server": "${LINK_IP:-}",
      "server_port": ${SS_PORT:-},
      "method": "2022-blake3-aes-128-gcm",
      "password": $(json_escape "$(ss_effective_password 2>/dev/null || printf '%s' "${SS_PASS:-}")")
    }
EOF_SB
    fi
    if (( _sb_json_started == 1 )); then printf '    ]\n'; fi
    if [[ "${CORE:-}" == 'xray' && ( "${MODE:-}" == *'XHTTP'* || "${MODE:-}" == *'ALL'* ) ]] && (( _xhttp_ok == 1 )); then
        printf '\n%s\n' "${YELLOW}--- v2rayN / v2rayNG XHTTP JSON ---${NC}"
        cat <<EOF_V2N
{
  "v": "2",
  "ps": "XHTTP",
  "add": "${LINK_IP:-}",
  "port": "${XHTTP_PORT:-}",
  "id": "${UUID:-}",
  "net": "xhttp",
  "type": "none",
  "path": "/xhttp",
  "mode": "stream-one",
  "tls": "reality",
  "sni": "${XHTTP_SNI:-}",
  "fp": "chrome",
  "pbk": "${PUBLIC_KEY:-}",
  "sid": "${SHORT_ID:-}"
}
EOF_V2N
    fi
    rebuild_standalone_links || true
    # --- standalone protocols (links registered at deploy time) ---
    show_standalone_links
    msg "${BLUE}--------------------------------------------------------------------------------${NC}"
    [[ "$CALLER" == 'deploy' ]] && msg "${GREEN}$(tr_msg view_config_deploy_done)${NC}"
    pause_return
}

show_usage() {
    clear
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}A-Box / Full Manual / Полное руководство / راهنمای کامل${NC}"
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
            cat <<'EOF_USAGE'
[Deployment]
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  Official Hysteria 2
5  Xray + Hysteria 2 combined deployment
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 sing-box Vision + Hysteria 2 + Shadowsocks-2022 (no XHTTP)

[Operations]
11 Toolbox: the A-Check IP checker, benchmarks, IP/route tests, SNI workflows, WARP, Swap, backup/restore, redacted diagnostics, multi-user/subscription export, node-SNI change, SS-2022 whitelist, custom shortcuts, BBR/FQ apply/rollback, host settings and Wallos.
12 Display node parameters and client exports.
13 This manual.
14 Script OTA, Xray Geo data and core-only upgrade.
15 One-click VPS optimization.
16 Remove nodes and reinitialize the environment.
17 Monthly vnStat traffic limits; opening the menu shows usage up to now.
18 More protocols.
19 Language selection: Simplified Chinese, Traditional Chinese, English, Japanese, Russian, Persian.
20 Full uninstall of the script and cores.
r/R One-click Reality.

BBR/FQ does not run automatically after protocol deployment. Host DNS includes resolver benchmarking, supported DoT/DoH, and rollback. Timezone selection is based on the installed zone database and supports numbered paging/search; Locale and NTP are separate controls.

Wallos is optional. Installation uses the latest non-prerelease upstream release and matching Docker image first, then the `wallos-mirror` recovery release. Data is persisted and backed up before upgrades. Choose the access mode explicitly during installation; Caddy HTTPS is recommended, and plain HTTP is only a disaster-recovery fallback — never enter personal information on an HTTP URL.

Toolbox test scripts use upstream-first download and explicit execution confirmation. When upstream is unavailable, a fixed-name A-Box Release snapshot is accepted only after SHA256 verification. If both sources fail, the script is not executed.
EOF_USAGE
            ;;
        ru)
            cat <<'EOF_USAGE'
[Развёртывание]
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  Официальный Hysteria 2
5  Комбинированная установка Xray + Hysteria 2
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 sing-box Vision + Hysteria 2 + Shadowsocks-2022 (без XHTTP)

[Обслуживание]
11 Инструменты: проверка IP A-Check, тесты, качество IP/маршрута, SNI, WARP, Swap, резервное копирование/восстановление, диагностика без секретов, экспорт пользователей/подписок, смена SNI узла, белый список SS-2022, свои ярлыки, BBR/FQ и откат, настройки хоста и Wallos.
12 Параметры узлов и экспорт клиентских конфигураций.
13 Это руководство.
14 OTA скрипта, Geo-данные Xray и отдельное обновление ядер.
15 Оптимизация VPS в один клик.
16 Удаление узлов и повторная инициализация окружения.
17 Месячный лимит трафика vnStat; меню показывает расход на текущий момент.
18 Дополнительные протоколы.
19 Выбор языка: упрощённый китайский, традиционный китайский, английский, японский, русский, персидский.
20 Полное удаление скрипта и ядер.
r/R Reality в один клик.

BBR/FQ не запускается автоматически после установки протокола. Настройки DNS включают проверку задержки, поддерживаемые DoT/DoH и откат. Часовой пояс выбирается по установленной базе часовых поясов с нумерацией, страницами и поиском; Locale и NTP — отдельные настройки.

Wallos необязателен. Сначала используется последняя стабильная непредварительная версия upstream и соответствующий Docker-образ, затем резервный Release `wallos-mirror`. Данные сохраняются, перед обновлением создаётся резервная копия. Во время установки явно выберите режим доступа; рекомендуется HTTPS через Caddy, а обычный HTTP — только аварийный запасной вариант, никогда не вводите личные данные по HTTP-адресу.

Тестовые скрипты загружаются из upstream и требуют явного подтверждения. При недоступности upstream резервная копия A-Box принимается только после проверки SHA256. Если оба источника недоступны, скрипт не запускается.
EOF_USAGE
            ;;
        fa)
            cat <<'EOF_USAGE'
[نصب]
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  Hysteria 2 رسمی
5  نصب ترکیبی Xray + Hysteria 2
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 ترکیب sing-box Vision + Hysteria 2 + Shadowsocks-2022 (بدون XHTTP)

[عملیات]
11 جعبه ابزار: بررسی‌گر IP ‏A-Check، آزمون سرعت، کیفیت IP/مسیر، SNI، WARP، Swap، پشتیبان‌گیری/بازیابی، گزارش عیب‌یابی بدون اسرار، خروجی چندکاربره/اشتراک، تغییر SNI نود، فهرست مجاز SS-2022، میانبرهای سفارشی، اعمال/بازگردانی BBR/FQ، تنظیمات میزبان و Wallos.
12 نمایش پارامترهای نود و خروجی کلاینت.
13 همین راهنما.
14 OTA اسکریپت، داده Geo برای Xray و ارتقای مستقل هسته.
15 بهینه‌سازی VPS با یک کلیک.
16 حذف نودها و راه‌اندازی مجدد محیط.
17 محدودیت ماهانه ترافیک vnStat؛ منو مصرف تا همین لحظه را نشان می‌دهد.
18 پروتکل‌های بیشتر.
19 انتخاب زبان: چینی ساده‌شده، چینی سنتی، انگلیسی، ژاپنی، روسی، فارسی.
20 حذف کامل اسکریپت و هسته‌ها.
r/R Reality با یک کلیک.

BBR/FQ پس از نصب پروتکل به‌صورت خودکار اجرا نمی‌شود. تنظیم DNS شامل سنجش واقعی، DoT/DoH در backend پشتیبانی‌شده و بازگردانی است. منطقه زمانی از پایگاه نصب‌شده با انتخاب شماره‌ای، صفحه‌بندی و جست‌وجو انتخاب می‌شود؛ Locale و NTP گزینه‌های مستقل هستند.

Wallos اختیاری است. ابتدا آخرین نسخه پایدار و غیرپیش‌انتشار upstream و تصویر Docker متناظر استفاده می‌شود؛ در صورت خرابی، Release بازیابی `wallos-mirror` جایگزین می‌شود. داده‌ها پایدار می‌مانند و پیش از ارتقا پشتیبان تهیه می‌شود. در زمان نصب حالت دسترسی را صراحتاً انتخاب کنید؛ HTTPS با Caddy توصیه می‌شود و HTTP ساده فقط راه‌حل اضطراری بازیابی است — هرگز اطلاعات شخصی را روی URL ‏HTTP وارد نکنید.

اسکریپت‌های آزمون ابتدا از upstream دریافت و اجرای آن‌ها با تأیید صریح انجام می‌شود. در صورت خرابی upstream، نسخه پشتیبان A-Box فقط پس از تطبیق SHA256 اجرا می‌شود. اگر هر دو منبع در دسترس نباشند، هیچ اسکریپتی اجرا نمی‌شود.
EOF_USAGE
            ;;
        zh-tw)
            cat <<'EOF_USAGE'
【部署類】
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  官方 Hysteria 2
5  Xray + 官方 Hysteria 2 組合部署
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 sing-box Vision + Hysteria 2 + Shadowsocks-2022（不含 XHTTP）

【運維類】
11 綜合工具箱：A-Check IP 檢測、測速、IP/回程測試、SNI、WARP、Swap、備份恢復、脫敏診斷、多用戶/訂閱匯出、節點 SNI 修改、SS-2022 白名單、自訂快捷指令、BBR/FQ 應用與回滾、主機設定和 Wallos。
12 顯示節點引數與客戶端配置。
13 當前說明書。
14 指令碼 OTA、Xray Geo 資料與核心單獨升級。
15 VPS 一鍵優化。
16 刪除節點並重新初始化環境。
17 vnStat 月流量限制；開啟後顯示截至當前用量。
18 更多協議。
19 語言設定：簡體中文、繁體中文、English、日本語、Русский、فارسی。
20 徹底解除安裝指令碼與核心。
r/R 一鍵 Reality。

協議安裝後不會自動應用 BBR/FQ。主機設定包含 DNS 真實測速、受支援後端的 DoT/DoH 和回滾。時區列表來自本機已安裝時區資料庫，支援編號、分頁和搜尋；Locale 與 NTP 分開設定。

Wallos 為可選應用。正常情況下優先獲取上游最新正式穩定版及匹配 Docker 映像；上游失敗時才使用 A-Box `wallos-mirror` 災備 Release。資料獨立持久化，升級前備份，健康檢查失敗時嘗試回滾。安裝時請明確選擇存取模式；建議使用 Caddy HTTPS，純 HTTP 只是災備回退——切勿在 HTTP 位址上錄入個人資料。

測速指令碼優先從上游下載，顯示 SHA256 並要求確認；上游不可用時，僅在 SHA256 校驗透過後使用 A-Box `test-tools-mirror`。兩處來源都失敗則不執行。
EOF_USAGE
            ;;
        ja)
            cat <<'EOF_USAGE'
【デプロイ】
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  公式 Hysteria 2
5  Xray + 公式 Hysteria 2 の組み合わせデプロイ
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 sing-box Vision + Hysteria 2 + Shadowsocks-2022（XHTTP を含まない）

【運用】
11 ツールボックス：A-Check IP チェック、ベンチマーク、IP / 経路テスト、SNI、WARP、Swap、バックアップ / 復元、匿名化診断、マルチユーザー / 購読エクスポート、ノード SNI 変更、SS-2022 ホワイトリスト、カスタムショートカット、BBR/FQ の適用とロールバック、ホスト設定と Wallos。
12 ノードのパラメーターとクライアント設定を表示します。
13 現在の説明書を表示します。
14 A-Box スクリプト OTA、Xray Geo データ、コアの個別アップグレード。
15 VPS ワンクリック最適化。
16 ノードを削除し、環境を再初期化します。
17 vnStat 月間トラフィック制限；メニューを開くと現在の使用量が表示されます。
18 その他のプロトコル。
19 言語選択：簡体字中国語、繁体字中国語、English、日本語、Русский、فارسی。
20 スクリプトとコアの完全アンインストール。
r/R ワンクリック Reality。

プロトコルのデプロイ後、BBR/FQ は自動的には適用されません。ホスト設定には DNS 実測、サポートされているバックエンドの DoT/DoH、ロールバックが含まれます。タイムゾーン一覧はホストにインストール済みのタイムゾーンデータベースに基づき、番号指定、ページング、検索に対応しています；Locale と NTP は別々に設定します。

Wallos はオプションのアプリです。通常は upstream の最新の正式安定版と対応する Docker イメージを優先的に取得します；upstream が失敗した場合のみ A-Box `wallos-mirror` の災害復旧用 Release を使用します。データは独立して永続化され、アップグレード前にバックアップし、ヘルスチェック失敗時はロールバックを試みます。インストール時にアクセスモードを明示的に選択してください。Caddy による HTTPS を推奨します。平文 HTTP は災害復旧時のフォールバック専用です。HTTP の URL には個人情報を入力しないでください。

テストスクリプトは upstream からのダウンロードを優先し、SHA256 を表示して確認を求めます；upstream が利用できない場合、SHA256 検証に合格した後にのみ A-Box `test-tools-mirror` を使用します。両方のソースが失敗した場合は実行しません。
EOF_USAGE
            ;;
        *)
            cat <<'EOF_USAGE'
【部署类】
1  Xray VLESS Vision REALITY
2  Xray VLESS XHTTP REALITY
3  Xray Shadowsocks-2022
4  官方 Hysteria 2
5  Xray + 官方 Hysteria 2 组合部署
6  sing-box VLESS Vision REALITY
7  sing-box VLESS + Shadowsocks-2022
8  sing-box Shadowsocks-2022
9  sing-box Hysteria 2
10 sing-box Vision + Hysteria 2 + Shadowsocks-2022（不含 XHTTP）

【运维类】
11 综合工具箱：A-Check IP 检测、测速、IP/回程测试、SNI、WARP、Swap、备份恢复、脱敏诊断、多用户/订阅导出、节点 SNI 修改、SS-2022 白名单、自定义快捷命令、BBR/FQ 应用与回滚、主机设置和 Wallos。
12 显示节点参数与客户端配置。
13 当前说明书。
14 脚本 OTA、Xray Geo 数据与核心单独升级。
15 VPS 一键优化。
16 删除节点并重新初始化环境。
17 vnStat 月流量限制；打开后显示截至当前用量。
18 更多协议。
19 语言设置：简体中文、繁体中文、English、日本語、Русский、فارسی。
20 彻底卸载脚本与核心。
r/R 一键 Reality。

协议安装后不会自动应用 BBR/FQ。主机设置包含 DNS 真实测速、受支持后端的 DoT/DoH 和回滚。时区列表来自本机已安装时区数据库，支持编号、分页和搜索；Locale 与 NTP 分开设置。

Wallos 为可选应用。正常情况下优先获取上游最新正式稳定版及匹配 Docker 镜像；上游失败时才使用 A-Box `wallos-mirror` 灾备 Release。数据独立持久化，升级前备份，健康检查失败时尝试回滚。安装时请明确选择访问模式；推荐使用 Caddy HTTPS，纯 HTTP 只是灾备回退——切勿在 HTTP 地址上录入个人数据。

测速脚本优先从上游下载，显示 SHA256 并要求确认；上游不可用时，仅在 SHA256 校验通过后使用 A-Box `test-tools-mirror`。两处来源都失败则不执行。
EOF_USAGE
            ;;
    esac
    msg "${CYAN}======================================================================${NC}"
    pause_return
}
extract_abox_build_metadata() {
    local file="$1" build epoch
    build=$(awk -F"'" '/^ABOX_BUILD=/{print $2; exit}' "$file")
    epoch=$(awk -F= '/^ABOX_BUILD_EPOCH=[0-9]+$/{print $2; exit}' "$file")
    [[ -n "$build" && "$build" != *'|'* && "$epoch" =~ ^[0-9]+$ && ${#epoch} -le 18 ]] || return 1
    printf '%s|%s\n' "$build" "$epoch"
}

validate_ota_version_direction() {
    local file="$1" metadata remote_build remote_epoch
    metadata=$(extract_abox_build_metadata "$file") || { printf '%s\n' "$(tr_msg validate_ota_version_direction_missing_metadata)" >&2; return 1; }
    IFS='|' read -r remote_build remote_epoch <<< "$metadata"
    # The metadata travels as build|epoch; a '|' inside build would shift
    # the epoch field, so re-validate it here before any arithmetic use
    # (an invalid value must fail, never fall through as "not a downgrade").
    if [[ -z "$remote_build" || ! "$remote_epoch" =~ ^[0-9]+$ || ${#remote_epoch} -gt 18 ]]; then
        printf '%s\n' "$(tr_msg validate_ota_version_direction_bad_metadata)" >&2
        return 1
    fi
    if (( 10#$remote_epoch < 10#$ABOX_BUILD_EPOCH )); then
        [[ "${ABOX_ALLOW_DOWNGRADE:-0}" == 1 ]] || { printf '%s\n' "$(tprintf validate_ota_version_direction_downgrade_refused "${ABOX_BUILD}" "${ABOX_BUILD_EPOCH}" "${remote_build}" "${remote_epoch}")" >&2; return 1; }
        [[ -n "${ABOX_OTA_SHA256_ALLOWLIST:-}" ]] || { printf '%s\n' "$(tr_msg validate_ota_version_direction_allowlist_required)" >&2; return 1; }
    fi
    OTA_REMOTE_BUILD="$remote_build"
    OTA_REMOTE_EPOCH="$remote_epoch"
}

confirm_ota_script_hash() {
    local sha="$1" url="$2" answer
    if [[ -n "${ABOX_OTA_SHA256_ALLOWLIST:-}" ]]; then
        if sha256_in_allowlist "$sha" "$ABOX_OTA_SHA256_ALLOWLIST"; then
            msg "${GREEN}[*] OTA SHA256 matched ABOX_OTA_SHA256_ALLOWLIST.${NC}"
            return 0
        fi
        printf '%s\n' 'OTA SHA256 is not in ABOX_OTA_SHA256_ALLOWLIST.' >&2
        return 1
    fi
    if [[ "${ABOX_ASSUME_YES_OTA:-}" == '1' ]]; then
        printf '%s\n' "$(tr_msg confirm_ota_script_hash_assume_yes_disabled)" >&2
        return 1
    fi
    case "${ABOX_LANG:-zh}" in
        en)
        msg "${YELLOW}[!] OTA source is pinned to an immutable Git commit. Syntax/fingerprint and SHA256 display are not a cryptographic publisher signature.${NC}"
        msg "${YELLOW}[!] Source: ${url}${NC}"
        read -r -p 'Install this downloaded A-Box script? [Y/N]: ' answer || return 1
            ;;
        ru)
        msg "${YELLOW}[!] Источник OTA привязан к неизменному Git-коммиту. Проверка синтаксиса/отпечатка и отображение SHA256 не являются криптографической подписью издателя.${NC}"
        msg "${YELLOW}[!] Источник: ${url}${NC}"
        read -r -p 'Установить этот загруженный скрипт A-Box? [Y/N]: ' answer || return 1
            ;;
        fa)
        msg "${YELLOW}[!] منبع OTA به یک کامیت Git تغییرناپذیر سنجاق شده است. نمایش نحو/اثرانگشت و SHA256 امضای رمزنگاری ناشر نیست.${NC}"
        msg "${YELLOW}[!] منبع: ${url}${NC}"
        read -r -p 'این اسکریپت دانلود شده A-Box نصب شود؟ [Y/N]: ' answer || return 1
            ;;
        ja)
            msg "${YELLOW}[!] OTA のソースは変更不可能な Git commit に固定されています。構文 / フィンガープリントの確認と SHA256 の表示は、リリース発行者による暗号学的署名の代わりにはなりません。${NC}"
            msg "${YELLOW}[!] ソース: ${url}${NC}"
            read -r -p 'ダウンロードした A-Box スクリプトをインストールしますか？[Y/N]: ' answer || return 1
            ;;
        zh-tw)
        msg "${YELLOW}[!] OTA 已固定到不可變 Git commit。語法/指紋檢查與 SHA256 展示仍不是釋出者密碼學簽名。${NC}"
        msg "${YELLOW}[!] 來源：${url}${NC}"
        read -r -p '是否安裝此下載的 A-Box 指令碼？[Y/N]: ' answer || return 1
            ;;
        *)
        msg "${YELLOW}[!] OTA 已固定到不可变 Git commit。语法/指纹检查与 SHA256 展示仍不是发布者密码学签名。${NC}"
        msg "${YELLOW}[!] 来源：${url}${NC}"
        read -r -p '是否安装此下载的 A-Box 脚本？[Y/N]: ' answer || return 1
            ;;
    esac
    is_yes "$answer"
}

# W7-OBS-2: true when the installed A-Box.sh already has the given
# SHA256 (i.e. the OTA download is byte-identical to what is
# installed). Fails closed on an empty sha, an unreadable installed
# script, or any mismatch -- the caller then proceeds as before.
ota_local_sha_matches() {
    local _sha="${1:-}" _local=''
    [[ -n "$_sha" ]] || return 1
    _local=$(sha256sum "$ABOX_DIR/A-Box.sh" 2>/dev/null | awk '{print $1}') || return 1
    [[ -n "$_local" && "$_local" == "$_sha" ]]
}

update_script() {
    clear
    local OTA_URL OTA_SNI_URL tmp_update tmp_sni_download tmp_sni_normalized tmp_old_script='' tmp_old_sni_cache=''
    local sni_cache old_cache_exists=0 sha script_restore_ok=1 cache_restore_ok=1
    OTA_URL=$(resolve_abox_main_commit_url) || die "$(tr_msg update_script_resolve_main_commit_failed)"
    [[ "$OTA_URL" =~ ^https://raw\.githubusercontent\.com/alariclin/A-Box/[0-9a-f]{40}/install\.sh$ ]] || die "$(tr_msg update_script_ota_url_not_immutable)"
    OTA_SNI_URL="${OTA_URL%/install.sh}/data/sni-candidates.txt"
    tmp_update=$(umask 077; mktemp /tmp/A-Box-update.XXXXXX) || die "$(tr_msg update_script_tmp_create_failed)"
    tmp_sni_download=$(umask 077; mktemp /tmp/A-Box-update-sni.XXXXXX) || { rm -f -- "$tmp_update"; die "$(tr_msg update_script_sni_tmp_create_failed)"; }
    tmp_sni_normalized=$(umask 077; mktemp /tmp/A-Box-update-sni-normalized.XXXXXX) || { rm -f -- "$tmp_update" "$tmp_sni_download"; die "$(tr_msg update_script_sni_verify_tmp_create_failed)"; }
    msg "${YELLOW}[*] $(tr_msg update_script_syncing_pinned_commit)${NC}"
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 10 -m 60 "$OTA_URL" -o "$tmp_update"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${RED}[!] $(tr_msg update_script_download_failed_unchanged)${NC}"
        pause_return
        return 1
    fi
    if ! validate_abox_script_file "$tmp_update" "$(tr_msg update_script_ota_script_label)"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${RED}[!] $(tr_msg update_script_verify_failed_unchanged)${NC}"
        pause_return
        return 1
    fi
    # Check version eligibility before hash confirmation to avoid asking the user
    # to approve a candidate that the direction policy rejects. Passing this check
    # does not authorize installation; hash confirmation is still required before
    # committing either the script or the SNI cache.
    if ! validate_ota_version_direction "$tmp_update"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${RED}[!] $(tr_msg update_script_version_direction_failed_unchanged)${NC}"
        pause_return
        return 1
    fi
    sha=$(sha256sum "$tmp_update" | awk '{print $1}')
    msg "${YELLOW}[*] OTA SHA256: ${sha}${NC}"
    # W7-OBS-2: the download is byte-identical to the installed
    # script -- report "already latest" instead of asking whether to
    # install it. Nothing is changed (no SNI download, no install).
    if ota_local_sha_matches "$sha"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${GREEN}$(tr_msg update_script_already_latest)${NC}"
        pause_return
        return 0
    fi
    if ! curl -fLsS --proto =https --proto-redir =https --connect-timeout 8 -m 45 --max-filesize "$ABOX_SNI_CANDIDATE_MAX_BYTES" "$OTA_SNI_URL" -o "$tmp_sni_download" 2>/dev/null || ! sni_normalize_candidate_file "$tmp_sni_download" "$tmp_sni_normalized"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${RED}[!] $(tr_msg update_script_sni_missing_cancelled)${NC}"
        pause_return
        return 1
    fi
    if ! confirm_ota_script_hash "$sha" "$OTA_URL"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        msg "${YELLOW}[*] OTA update canceled; script and SNI cache were not changed.${NC}"
        pause_return
        return 0
    fi
    msg "${YELLOW}[*] OTA remote build: ${OTA_REMOTE_BUILD} (${OTA_REMOTE_EPOCH})${NC}"

    # Snapshot both current files before changing either one. If a later write
    # or post-write validation fails, restore the old script/cache pair.
    [[ -d "$ABOX_DIR" && ! -L "$ABOX_DIR" ]] && path_owned_by_root "$ABOX_DIR" && path_mode_has_no_group_other_write "$ABOX_DIR" || {
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        die "$(tr_msg update_script_data_dir_check_failed)"
    }
    [[ -f "$ABOX_DIR/A-Box.sh" && ! -L "$ABOX_DIR/A-Box.sh" ]] && \
        path_owned_by_root "$ABOX_DIR/A-Box.sh" && path_mode_has_no_group_other_write "$ABOX_DIR/A-Box.sh" && \
        path_parent_chain_safe "$ABOX_DIR/A-Box.sh" || {
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        die "$(tr_msg update_script_abox_sh_missing_unsafe)"
    }
    tmp_old_script=$(umask 077; mktemp /tmp/A-Box-update-old-script.XXXXXX) || {
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        die "$(tr_msg update_script_ota_snapshot_failed)"
    }
    if ! cp -p -- "$ABOX_DIR/A-Box.sh" "$tmp_old_script"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script"
        die "$(tr_msg update_script_save_current_script_failed)"
    fi
    sni_cache="$ABOX_DIR/A-Box-sni-candidates.txt"
    if [[ -e "$sni_cache" || -L "$sni_cache" ]]; then
        if [[ ! -f "$sni_cache" || -L "$sni_cache" ]] || ! path_owned_by_root "$sni_cache" || \
            ! path_mode_has_no_group_other_write "$sni_cache" || path_tree_has_mountpoint "$sni_cache"; then
            rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script"
            die "$(tr_msg update_script_sni_cache_unsafe)"
        fi
        tmp_old_sni_cache=$(umask 077; mktemp /tmp/A-Box-update-old-sni.XXXXXX) || {
            rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script"
            die "$(tr_msg update_script_sni_snapshot_failed)"
        }
        if ! cp -p -- "$sni_cache" "$tmp_old_sni_cache"; then
            rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script" "$tmp_old_sni_cache"
            die "$(tr_msg update_script_save_sni_cache_failed)"
        fi
        old_cache_exists=1
    fi

    if ! sni_store_candidate_cache "$tmp_sni_normalized"; then
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script" "$tmp_old_sni_cache"
        die "$(tr_msg update_script_commit_sni_cache_failed)"
    fi
    if ! install_binary_atomically "$tmp_update" "$ABOX_DIR/A-Box.sh"; then
        restore_sni_candidate_cache_snapshot "$tmp_old_sni_cache" "$old_cache_exists" || cache_restore_ok=0
        if (( cache_restore_ok == 1 )); then
            rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script" "$tmp_old_sni_cache"
            die "$(tr_msg update_script_atomic_write_failed_rolled_back)"
        fi
        # U226: incomplete rollback keeps the snapshots for manual
        # recovery (only the throwaway downloads are removed here).
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        die "$(tr_msg update_script_atomic_write_failed_rollback_incomplete)"
    fi
    if ! validate_abox_script_file "$ABOX_DIR/A-Box.sh" "$(tr_msg ss2_ctx_persisted)"; then
        rollback_binary_install "$ABOX_DIR/A-Box.sh" "$tmp_old_script" || script_restore_ok=0
        restore_sni_candidate_cache_snapshot "$tmp_old_sni_cache" "$old_cache_exists" || cache_restore_ok=0
        if (( script_restore_ok == 1 && cache_restore_ok == 1 )); then
            rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script" "$tmp_old_sni_cache"
            die "$(tr_msg update_script_persist_verify_failed_restored)"
        fi
        # U226: incomplete rollback keeps the snapshots for manual recovery.
        rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized"
        die "$(tr_msg update_script_persist_verify_failed_rollback_incomplete)"
    fi
    rm -f -- "$tmp_update" "$tmp_sni_download" "$tmp_sni_normalized" "$tmp_old_script" "$tmp_old_sni_cache"
    msg "${GREEN}$(tr_msg update_script_core_sni_synced)${NC}"
    sleep 2
    export ABOX_INHERITED_LOCK_MODE="$ABOX_RUNTIME_LOCK_MODE"
    exec "$ABOX_DIR/A-Box.sh"
}

force_update_geo() {
    clear
    init_system_environment
    load_optional_abox_env_or_die
    if ! abox_owns_service xray; then
        msg "${YELLOW}[!] $(tr_msg force_update_geo_no_xray)${NC}"
        pause_return
        return 0
    fi
    [[ -x "$ABOX_DIR/geo_update.sh" ]] || setup_geo_cron
    msg "${YELLOW}[*] $(tr_msg force_update_geo_fetching)${NC}"
    if ABOX_CALLER_HOLDS_LOCK=1 bash "$ABOX_DIR/geo_update.sh"; then
        msg "${GREEN}$(tr_msg force_update_geo_done)${NC}"
    else
        msg "${RED}[!] $(tr_msg force_update_geo_failed)${NC}"
    fi
    pause_return
}


service_unit_exists() {
    local srv="$1"
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # S166: exit code alone is not existence (a nonexistent
        # name can list zero units successfully); require an exact
        # first-column match, as __abox_reconcile_systemd_unit does.
        systemctl list-unit-files "${srv}.service" 2>/dev/null | awk -v wanted="${srv}.service" '$1 == wanted { found=1 } END { exit !found }' && return 0
        [[ -f "/etc/systemd/system/${srv}.service" || -f "/lib/systemd/system/${srv}.service" || -f "/usr/lib/systemd/system/${srv}.service" ]] && return 0
    else
        [[ -x "/etc/init.d/${srv}" ]] && return 0
    fi
    return 1
}

# H-23 (Carbon R3): restart gate for config-writing paths. A restart is
# permitted only when the desired state reads RUNNING and the service was
# already running before the change; any failure reading the desired
# state fails closed (no restart). Callers that skip the restart still
# persist the new config on disk.
service_restart_permitted() {
    local svc="$1" _desired
    _desired=$(get_desired_state 2>/dev/null) || return 1
    [[ "$_desired" == RUNNING ]] || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl is-active --quiet "$svc" 2>/dev/null || return 1
    else
        rc-service "$svc" status >/dev/null 2>&1 || return 1
    fi
    return 0
}

restart_service_soft() {
    local srv="$1"
    abox_owns_service "$srv" || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl restart "$srv" >/dev/null 2>&1 || return 1
        sleep 2
        systemctl is-active --quiet "$srv" || return 1
        record_core_family_ownership "$srv"
    else
        rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || return 1
        sleep 2
        rc-service "$srv" status >/dev/null 2>&1 || return 1
        record_core_family_ownership "$srv"
    fi
}

enable_abox_service_soft() {
    local srv="$1" state
    abox_owns_service "$srv" || return 1
    if [[ "${INIT_SYS:-}" == systemd ]]; then
        systemctl enable "$srv" >/dev/null 2>&1 || return 1
    elif [[ "${INIT_SYS:-}" == openrc ]]; then
        rc-update add "$srv" default >/dev/null 2>&1 || return 1
    else
        return 1
    fi
    state=$(managed_service_state_value "$srv") || return 1
    [[ "$state" == "$srv|1|enabled" || "$state" == "$srv|0|enabled" ]]
}

start_abox_service_soft() {
    local srv="$1"
    abox_owns_service "$srv" || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable "$srv" >/dev/null 2>&1 || return 1
        systemctl restart "$srv" >/dev/null 2>&1 || return 1
        sleep 2
        systemctl is-active --quiet "$srv" || return 1
        record_core_family_ownership "$srv"
    else
        rc-update add "$srv" default >/dev/null 2>&1 || return 1
        rc-service "$srv" restart >/dev/null 2>&1 9>&- 10>&- || return 1
        sleep 2
        rc-service "$srv" status >/dev/null 2>&1 || return 1
        record_core_family_ownership "$srv"
    fi
}

# M-04 (Carbon audit): ensure a managed service is running WITHOUT
# restarting it. service_manager start unconditionally restarts (and its
# die() exits the whole process on failure, so a caller's `|| true` never
# runs); the deployers above already restarted via restart_service_soft,
# so a second restart here only destroys zero-downtime hot-adds and hides
# failures. Returns 1 (never dies) so the caller can roll back.
# Liveness follows the R2C10-02 pattern (managed_service_pid + kill -0).
ensure_service_running_soft() {
    local srv="$1"
    abox_owns_service "$srv" || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl enable "$srv" >/dev/null 2>&1 || return 1
        if systemctl is-active --quiet "$srv"; then
            :
        else
            systemctl start "$srv" >/dev/null 2>&1 || return 1
            sleep 2
            systemctl is-active --quiet "$srv" || return 1
            record_core_family_ownership "$srv" || return 1
        fi
    else
        rc-update add "$srv" default >/dev/null 2>&1 || return 1
        if rc-service "$srv" status >/dev/null 2>&1; then
            :
        else
            rc-service "$srv" start >/dev/null 2>&1 9>&- 10>&- || return 1
            sleep 2
            rc-service "$srv" status >/dev/null 2>&1 || return 1
            record_core_family_ownership "$srv" || return 1
        fi
    fi
    local _live_pid='' _tries=0
    while (( _tries < 20 )); do
        _live_pid=$(managed_service_pid "$srv" 2>/dev/null || true)
        if [[ "$_live_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_live_pid" 2>/dev/null; then
            return 0
        fi
        _live_pid=''
        sleep 0.25; _tries=$((_tries + 1))
    done
    return 1
}

# P2: Soft-stop a managed service (stop only, do NOT disable).
# Previously called at hysteria smoke test but never defined (command not
# found was swallowed by || true, leaving a stopped service running).
stop_abox_service_soft() {
    local srv="$1"
    abox_owns_service "$srv" || return 1
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        systemctl stop "$srv" >/dev/null 2>&1 || return 1
    else
        rc-service "$srv" stop >/dev/null 2>&1 || return 1
    fi
}

jsonc_strip_comments() {
    local file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$file" <<'PY_JSONC_STRIP' 2>/dev/null || cat "$file"
import sys
data = open(sys.argv[1], 'r', encoding='utf-8', errors='replace').read()
out = []
i = 0
n = len(data)
in_str = False
esc = False
BS = chr(92)
NL = chr(10)
while i < n:
    c = data[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == BS:
            esc = True
        elif c == '"':
            in_str = False
        i += 1
        continue
    if c == '"':
        in_str = True
        out.append(c)
        i += 1
        continue
    if c == '/' and i + 1 < n and data[i+1] == '/':
        while i < n and data[i] != NL:
            i += 1
        continue
    if c == '/' and i + 1 < n and data[i+1] == '*':
        j = data.find('*/', i + 2)
        if j == -1:
            raise ValueError('unterminated JSONC block comment')
        out.append(' ')
        i = j + 2
        continue
    out.append(c)
    i += 1
sys.stdout.write(''.join(out))
PY_JSONC_STRIP
    else
        cat "$file"
    fi
}

core_expected_listen_ports() {
    local core="$1" cfg="$2"
    case "$core" in
        xray)
            # XRAY-API: exclude the loopback-only gRPC control plane (tag "api")
            # from data-plane health checks; it is infrastructure, not a service port.
            # U228: xray socks listens on UDP only when settings.udp
            # is true (absent/false means TCP-only); emitting udp/ for a
            # TCP-only socks inbound failed the health check outright.
            jsonc_strip_comments "$cfg" 2>/dev/null | jq -r 'def norm: (if type == "number" then tostring elif type == "string" then (if test("^[0-9]+$") then (tonumber | tostring) elif test("^[0-9]+-[0-9]+$") then ((split("-") | map(tonumber)) as $r | "\($r[0])-\($r[1])") else . end) else tostring end); (.api.tag // "__no_api__") as $apit | ((.inbounds[]? | select(.port != null and .tag != $apit) | (if .protocol == "shadowsocks" then (if (.settings.network // "tcp") == "tcp" then "tcp/\(.port | norm)" elif (.settings.network // "tcp") == "udp" then "udp/\(.port | norm)" else "tcp/\(.port | norm)\nudp/\(.port | norm)" end) elif .protocol == "socks" then (if .settings.udp == true then "tcp/\(.port | norm)\nudp/\(.port | norm)" else "tcp/\(.port | norm)" end) elif .protocol == "dokodemo-door" then (if (.settings.network // "tcp") == "tcp" then "tcp/\(.port | norm)" elif (.settings.network // "tcp") == "udp" then "udp/\(.port | norm)" else "tcp/\(.port | norm)\nudp/\(.port | norm)" end) elif (.streamSettings.network // "tcp") == "kcp" or (.streamSettings.network // "tcp") == "quic" then "udp/\(.port | norm)" else "tcp/\(.port | norm)" end)) , (.inbounds[]? | select(.port == null and (.listen | type == "string") and ((.listen | contains("/")) or (.listen | startswith("@"))) and .tag != $apit) | "unix/\(.listen)"))' 2>/dev/null
            ;;
        singbox)
            jsonc_strip_comments "$cfg" 2>/dev/null | jq -r 'def norm: (if type == "number" then tostring elif type == "string" then (if test("^[0-9]+$") then (tonumber | tostring) elif test("^[0-9]+-[0-9]+$") then ((split("-") | map(tonumber)) as $r | "\($r[0])-\($r[1])") else . end) else tostring end); .inbounds[]? | select(.listen_port != null) | (if .type == "hysteria2" or .type == "tuic" then "udp/\(.listen_port | norm)" elif .type == "shadowsocks" then (if .network == "tcp" then "tcp/\(.listen_port | norm)" elif .network == "udp" then "udp/\(.listen_port | norm)" else "tcp/\(.listen_port | norm)", "udp/\(.listen_port | norm)" end) elif .type == "socks" or .type == "mixed" then "tcp/\(.listen_port | norm)" elif .type == "direct" then (if .network == "tcp" then "tcp/\(.listen_port | norm)" elif .network == "udp" then "udp/\(.listen_port | norm)" else "tcp/\(.listen_port | norm)", "udp/\(.listen_port | norm)" end) else "tcp/\(.listen_port | norm)" end)' 2>/dev/null
            ;;
        hysteria)
            # Hysteria 2 config uses listen: :PORT (or [::]:PORT).
            # Top-level listen only (nested keys ignored); quoted keys accepted; default udp/443 when absent.
            awk '
                {
                    k=$0; gsub(/["'"'"']/, "", k)
                    if ($0 !~ /^[ \t]/ && k ~ /^listen:/) {
                        found=1
                        v=k; sub(/^listen:[ \t\r]*/, "", v); sub(/[ \t\r#].*$/, "", v)
                        sub(/^.*:/, "", v)
                        # C-01: Port ranges like :20000-25000 must use FIRST port, not concat to 2000025000.
                        sub(/-.*$/, "", v)
                        gsub(/[^0-9]/, "", v)
                        # 08d-03: normalize a leading-zero port (Hysteria
                        # accepts listen: :0443) to decimal, so it does
                        # not reach ss matching as udp/0443 (ss shows
                        # :443). The empty check stays on the string form.
                        if (v != "") { v = v + 0; print "udp/" v }
                    }
                }
                END { if (!found) print "udp/443" }
            ' "$cfg" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

core_ports_listening() {
    local core="$1" cfg="$2" spec proto port flags any=0
    local -a checks=()
    local lo hi p enum_out enum_rc
    enum_out=$(core_expected_listen_ports "$core" "$cfg" 2>/dev/null); enum_rc=$?
    if (( enum_rc != 0 )); then
        msg "${RED}[!] $(tprintf core_ports_listening_enum_failed "${core}" "${cfg}")${NC}"
        return 1
    fi
    while IFS= read -r spec; do
        if [[ "$spec" =~ ^unix/(.+)$ ]]; then
            checks+=("$spec")
        elif [[ "$spec" =~ ^(tcp|udp)/([0-9]+)-([0-9]+)$ ]]; then
            # R4C16-03: expand a range spec to single-port entries so it
            # is probed instead of skipped (a range-only inbound no longer
            # yields any=0, and a failing port inside a range is caught).
            # A reversed range yields no entries (the for loop is skipped).
            # 08d-03: 10# so a leading-zero bound (0443) is decimal 443,
            # not octal 291 in arithmetic context.
            proto="${BASH_REMATCH[1]}"; lo=$((10#${BASH_REMATCH[2]})); hi=$((10#${BASH_REMATCH[3]}))
            for ((p=lo; p<=hi; p++)); do checks+=("$proto/$p"); done
        elif [[ "$spec" =~ ^(tcp|udp)/([0-9]+)$ ]]; then
            # 08d-03: normalize a leading-zero spec (udp/0443) to
            # decimal here too, so the ss match below sees :443.
            checks+=("${BASH_REMATCH[1]}/$((10#${BASH_REMATCH[2]}))")
        fi
    done < <(printf '%s\n' "$enum_out" | awk '!seen[$0]++')
    for spec in "${checks[@]}"; do
        if [[ "$spec" == unix/* ]]; then
            sockpath="${spec#unix/}"
            any=1
            if ! ss -H -lnx 2>/dev/null | awk -v p="$sockpath" '$5 == p {found=1} END{exit !found}'; then
                msg "${RED}[!] $(tprintf core_ports_listening_unix_not_listening "${core}" "${sockpath}")${NC}"
                return 1
            fi
            continue
        fi
        proto="${spec%%/*}"; port="${spec##*/}"
        any=1
        [[ "$proto" == tcp ]] && flags='-H -lntp' || flags='-H -lnup'
        # Single-protocol ss omits the Netid column, so Local Address:Port is $4.
        # shellcheck disable=SC2086
        if ! ss $flags 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'; then
            msg "${RED}[!] $(tprintf core_ports_listening_port_not_listening "${core}" "${port}" "${proto}")${NC}"
            return 1
        fi
    done
    if (( any == 0 )); then
        msg "${RED}[!] $(tprintf core_ports_listening_no_expected "${core}")${NC}"
        return 1
    fi
    return 0
}

# F-01: data-plane smoke probe. Verifies the listening port actually speaks
# TLS (not just TCP accept) by sending a minimal ClientHello and requiring
# a ServerHello/fallback response. Catches binaries that start and listen
# but cannot complete handshakes (e.g. protocol regressions).
# P1-2: Return only TLS-capable inbound ports (for TLS smoke probe).
# B9-02: core_tls_listen_ports removed (dead code; production uses
# core_expected_tls_tcp_targets). 2026-10-16.

# C-01: Only TLS/REALITY TCP ports may receive a TLS ClientHello probe.
# Probing plain-TCP inbounds (SS, non-TLS vless) or UDP ports causes false failures.
core_expected_tls_tcp_targets() {
    # R15-06/07/08: enumerate per-inbound (host, port) TLS targets as TSV
    # (host<TAB>port, one line per target), NOT bare ports. For xray and
    # singbox, the config is stripped (JSONC) and parsed with each step
    # checked separately: the
    # strip helper falls back to cat when its python fails, so only the
    # parse check can catch a strip failure. The document shape is
    # validated (one object, .inbounds null-or-array) so an empty or
    # unparseable document never becomes a successful no-TLS. A
    # selected-but-unusable target is DIAGNOSED (rc 1), never silently
    # skipped: non-scalar port, hostname listen (listen accepts an IP or
    # a Unix socket, not a hostname), unclassified transport. An omitted
    # sing-box listen binds 127.0.0.1 (verified by running the pinned
    # sing-box 1.14.4 binary; the docs mark listen Required but the
    # binary does not enforce it). Dedup is on host+port
    # (same port on different addresses is legitimate). Unix listeners
    # (path or abstract "@name") are not TCP targets. Xray: any protocol
    # with TLS/REALITY security on a TCP transport (tcp/raw/ws/grpc/http/
    # h2/httpupgrade/xhttp/splithttp); kcp/quic excluded; the "api"
    # control-plane inbound is excluded. sing-box: any type with
    # tls.enabled, except the UDP types tuic/hysteria2/hysteria and any
    # inbound whose configured network is UDP-only.
    local core="$1" cfg="$2"
    local _stripped _strip_rc _doc _doc_rc _targets _enum_rc _line _diag
    [[ -f "$cfg" && ! -L "$cfg" ]] || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_config_missing "${cfg}")${NC}" >&2; return 1; }
    # R1-F16-1: only xray/singbox use the JSON(C) inbound schema below.
    # Hysteria config is YAML and its primary listener is QUIC/UDP;
    # other cores are not enumerated here. Return before parsing so an
    # unparsable-as-JSON config cannot fail the health gate.
    case "$core" in
        xray|singbox) ;;
        *) return 0 ;;
    esac
    _stripped=$(jsonc_strip_comments "$cfg" 2>/dev/null); _strip_rc=$?
    (( _strip_rc == 0 )) || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_strip_failed "${cfg}")${NC}" >&2; return 1; }
    _doc=$(printf '%s' "$_stripped" | jq -s -c 'if length == 1 then .[0] else error("expected exactly one JSON document") end' 2>/dev/null); _doc_rc=$?
    (( _doc_rc == 0 )) || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_parse_failed "${cfg}")${NC}" >&2; return 1; }
    printf '%s' "$_doc" | jq -e 'type == "object" and (.inbounds == null or (.inbounds | type == "array"))' >/dev/null 2>&1 || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_bad_shape "${cfg}")${NC}" >&2; return 1; }
    case "$core" in
        xray)
            # R7-F16-5: a string port is normalized before the scalar
            # check (see the $raw_port step below): a pure-digit string
            # becomes its number, and a "lo-hi" range contributes only
            # its first port (the probe target is a single port; the
            # range's other ports are not probed). Anything else is
            # still a diagnostic, never silently skipped.
            _targets=$(printf '%s' "$_doc" | jq -c '.inbounds[]? | select(.tag != "api") | select(.streamSettings.security == "tls" or .streamSettings.security == "reality") | (.listen // "0.0.0.0") as $listen | (.streamSettings.network // "tcp") as $net | if ($listen | type) != "string" then {"diag": "non-string listen on a TLS inbound"} elif ($listen | contains("/") or startswith("@")) then empty elif (["tcp","raw","ws","grpc","http","h2","httpupgrade","xhttp","splithttp"] | index($net)) then (if $listen == "0.0.0.0" then "127.0.0.1" elif $listen == "::" then "::1" elif ($listen | test("^(\\d{1,3}\\.){3}\\d{1,3}$") or contains(":")) then ($listen | gsub("^\\[|\\]$"; "")) else null end) as $host | (.port) as $raw_port | (if ($raw_port | type) == "number" then $raw_port elif ($raw_port | type) == "string" and ($raw_port | test("^[0-9]+$")) then ($raw_port | tonumber) elif ($raw_port | type) == "string" and ($raw_port | test("^[0-9]+-[0-9]+$")) then (($raw_port | split("-") | map(tonumber)) as $r | if $r[0] >= 1 and $r[0] <= 65535 and $r[1] >= 1 and $r[1] <= 65535 and $r[0] <= $r[1] then $r[0] else null end) else null end) as $port | if ($port | type != "number") or $port < 1 or $port > 65535 then {"diag": ("non-scalar TLS port " + (($raw_port // "?") | tostring))} elif $host == null then {"diag": ("hostname listen " + $listen + " is not a dialable address")} else {"host": $host, "port": $port} end elif $net == "kcp" or $net == "quic" then empty else {"diag": ("unclassified TLS transport " + ($net | tostring))} end' 2>/dev/null); _enum_rc=$?
            ;;
        singbox)
            _targets=$(printf '%s' "$_doc" | jq -c '.inbounds[]? | select(.tls.enabled == true) | select(.type != "tuic" and .type != "hysteria2" and .type != "hysteria") | select((.network // "tcp") != "udp") | if (.listen | type != "string") and .listen != null then {"diag": "non-string listen on a TLS inbound"} elif ((.listen // "") | contains("/") or startswith("@")) then empty else (if (.listen == null or .listen == "") then "127.0.0.1" elif .listen == "0.0.0.0" then "127.0.0.1" elif .listen == "::" then "::1" elif (.listen | test("^(\\d{1,3}\\.){3}\\d{1,3}$") or contains(":")) then (.listen | gsub("^\\[|\\]$"; "")) else null end) as $host | (.listen_port) as $port | if ($port | type != "number") or $port < 1 or $port > 65535 then {"diag": ("non-scalar TLS port " + (($port // "?") | tostring))} elif $host == null then {"diag": ("hostname listen " + .listen + " is not a dialable address")} else {"host": $host, "port": $port} end end' 2>/dev/null); _enum_rc=$?
            ;;
        # hysteria (and any other core): no TLS TCP inbounds to enumerate;
        # a parsed config with no targets probes nothing. The health gate
        # calls this probe for hysteria too -- it must not fail there.
        *) return 0 ;;
    esac
    (( _enum_rc == 0 )) || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_enum_failed "${cfg}")${NC}" >&2; return 1; }
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -n "$_line" ]] || continue
        _diag=$(printf '%s' "$_line" | jq -r 'if has("diag") then .diag else empty end' 2>/dev/null)
        if [[ -n "$_diag" ]]; then
            msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_diag "${_diag}" "${cfg}")${NC}" >&2
            return 1
        fi
        printf '%s' "$_line" | jq -r '"\(.host)\t\(.port)"' 2>/dev/null || { msg "${RED}[!] $(tprintf core_expected_tls_tcp_targets_bad_target "${cfg}")${NC}" >&2; return 1; }
    done <<< "$_targets"
    return 0
}

core_tls_smoke_probe() {
    local core="$1" cfg="$2" host port _targets _enum_rc
    # R1-16-F3 (revised R15-07): probe each inbound at ITS OWN listen
    # address -- a :: listener via ::1, a 0.0.0.0 listener via 127.0.0.1,
    # an explicit IP via itself; never the host wildcard preference.
    # R15-06: enumeration runs FIRST and its failure is a gate failure,
    # never a vacuous pass. A parsed config with no TLS inbounds
    # legitimately probes nothing.
    _targets=$(core_expected_tls_tcp_targets "$core" "$cfg"); _enum_rc=$?
    (( _enum_rc == 0 )) || return 1
    # C-01 NUL: Do NOT store ClientHello in Bash var (Bash strips \x00). Send via printf in subshell.
    # Valid 50-byte TLS 1.2 ClientHello: Record len 0x002d (45), HandshakeType 0x01 (ClientHello), Handshake len 0x000029 (41).
    while IFS=$'\t' read -r host port || [[ -n "$host" ]]; do
        [[ -z "$host" && -z "$port" ]] && continue
        [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { msg "${RED}[!] $(tprintf core_tls_smoke_probe_bad_target "${core}" "${host}" "${port}")${NC}" >&2; return 1; }
        # Open TCP, send ClientHello, read the full 5-byte TLS record
        # header plus its declared payload. Only a TLS record proves
        # the data plane is alive: first byte 0x16 (ServerHello, incl.
        # REALITY fallback to a TLS site) or 0x15 (Alert). A non-TLS
        # target is a misconfiguration and fails.
        # Timeout 5s. The destination is passed as DATA ($1/$2), never
        # interpolated into the child shell source: the host comes from
        # config text (R15-07).
        if ! timeout 5 bash -c '
            exec 3<>/dev/tcp/$1/$2 || exit 1
            printf "\x16\x03\x01\x00\x2d\x01\x00\x00\x29\x03\x03\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x00\x00\x02\x00\x2f\x01\x00" >&3 || exit 1
            # 08d-01: read the full 5-byte TLS record header. The old
            # `read -d ""` stopped at the first NUL (the length high
            # byte is usually 0x00), so it verified only the first
            # three bytes and passed a truncated record prefix.
            # head -c reads exact bytes; od turns them into hex
            # (Bash vars cannot hold NULs).
            hdr=$(head -c 5 <&3 | od -An -tx1 | tr -d " \n") || exit 1
            [[ "${#hdr}" == 10 ]] || exit 1
            rtype="${hdr:0:2}"; rlen=$((16#${hdr:6:2} * 256 + 16#${hdr:8:2}))
            # S165: only a TLS record proves the data plane: first
            # byte 0x16 (Handshake/ServerHello) or 0x15 (Alert),
            # major version 0x03, length 1..16384. Plaintext (or any
            # other record type) must fail.
            [[ "$rtype" == 16 || "$rtype" == 15 ]] || exit 1
            [[ "${hdr:2:2}" == 03 ]] || exit 1
            (( rlen >= 1 && rlen <= 16384 )) || exit 1
            # Read the full declared payload: a truncated record
            # (fewer bytes than the header promises) must fail.
            n=$(head -c "$rlen" <&3 | wc -c) || exit 1
            n="${n//[[:space:]]/}"
            [[ "$n" == "$rlen" ]] || exit 1
        ' _ "$host" "$port" 2>/dev/null; then
            msg "${RED}[!] $(tprintf core_tls_smoke_probe_no_response "${core}" "${host}" "${port}")${NC}" >&2
            return 1
        fi
    done < <(printf '%s\n' "$_targets" | awk '!seen[$0]++')
    return 0
}

core_post_upgrade_health_gate() {
    local core="$1" cfg bin
    case "$core" in
        xray)
            cfg='/usr/local/etc/xray/config.json'; bin='/usr/local/bin/xray'
            [[ -x "$bin" && -f "$cfg" ]] || return 1
            XRAY_LOCATION_ASSET=/usr/local/share/xray "$bin" run -test -config "$cfg" >/dev/null 2>&1 || return 1
            ;;
        singbox)
            cfg='/etc/sing-box/config.json'; bin='/usr/local/bin/sing-box'
            [[ -x "$bin" && -f "$cfg" ]] || return 1
            "$bin" check -c "$cfg" >/dev/null 2>&1 || return 1
            ;;
        hysteria)
            cfg='/etc/hysteria/config.yaml'; bin='/usr/local/bin/hysteria'
            [[ -x "$bin" && -f "$cfg" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    # P1-1: systemd unit is 'sing-box' (with hyphen), not internal name 'singbox'.
    local svc="$core"
    [[ "$core" == 'singbox' ]] && svc='sing-box'
    is_service_running "$svc" || return 1
    core_ports_listening "$core" "$cfg" || return 1
    # F-01: data-plane smoke probe (TLS handshake check). Set
    # ABOX_SKIP_TRAFFIC_PROBE=1 to bypass (not recommended).
    if [[ "${ABOX_SKIP_TRAFFIC_PROBE:-0}" != "1" ]]; then
        core_tls_smoke_probe "$core" "$cfg" || return 1
    fi
}

# R62-L02: shared version-direction gate for the three core-only
# upgrade functions (xray / sing-box / hysteria). Calls
# core_version_upgrade_decision and maps its outcome: 0 proceeds;
# 3 (current above target) / 4 (already at target) print the
# caller's skip/already message and return 3/4 so the caller can
# return 0; 1 (downgrade refused) / 2 (uncomparable) / unexpected
# die with the caller's message. Message strings are preformatted by
# the caller: each core has its own translation keys and tprintf
# enforces exact arg counts, so the keys cannot be shared. $10 is an
# optional staged temp dir: when given, a die/skip/already outcome
# removes it first (the final gate's tmp; the initial gate passes
# '' because no tmp exists yet) and skip/already also clear
# ABOX_CORE_UPGRADE_TMP, matching the inline code. Returns 0/3/4.
_core_upgrade_version_direction() {
    local current_tag="$1" target_ref="$2" pinned_flag="$3" allow_downgrade="$4"
    local downgrade_msg="$5" incomparable_msg="$6" skip_msg="$7" already_msg="$8" unexpected_msg="$9" tmp_dir="${10:-}"
    local decision=0
    core_version_upgrade_decision "$current_tag" "$target_ref" "$pinned_flag" "$allow_downgrade"
    decision=$?
    case "$decision" in
        0) return 0 ;;
        1) [[ -n "$tmp_dir" ]] && rm -rf -- "$tmp_dir"; die "$downgrade_msg" ;;
        2) [[ -n "$tmp_dir" ]] && rm -rf -- "$tmp_dir"; die "$incomparable_msg" ;;
        3) msg "${YELLOW}[!] ${skip_msg}${NC}"; if [[ -n "$tmp_dir" ]]; then rm -rf -- "$tmp_dir"; ABOX_CORE_UPGRADE_TMP=''; fi; return 3 ;;
        4) msg "${GREEN}[OK] ${already_msg}${NC}"; if [[ -n "$tmp_dir" ]]; then rm -rf -- "$tmp_dir"; ABOX_CORE_UPGRADE_TMP=''; fi; return 4 ;;
        *) [[ -n "$tmp_dir" ]] && rm -rf -- "$tmp_dir"; die "$unexpected_msg" ;;
    esac
}

# R62-L02: shared install/commit tail for the three core-only upgrade
# functions. $1 = service (xray | sing-box | hysteria), $2 = health-gate
# arg (xray | singbox | hysteria), $3 = installed binary path,
# $4 = staged binary path, $5 = staged temp dir, $6 = was_active (0/1),
# $7/$8 = old/new version strings, $9 = backup-failure message,
# ${10} = install-failure message, ${11} = ownership-failure tr_msg key,
# ${12} = OK message, ${13} = optional stopped-state smoke-test function
# (hysteria only: it has no standalone config-check command, so a
# stopped service gets a temporary start + port probe + stop cycle
# instead of a blind OK; the other cores pass '' and skip it).
_core_upgrade_commit_install() {
    local svc="$1" health_arg="$2" bin_path="$3" staged_path="$4" tmp="$5" was_active="$6" old_ver="$7" new_ver="$8"
    local backup_fail_msg="$9" install_fail_msg="${10}" ownership_fail_key="${11}" ok_msg="${12}" smoke_fn="${13:-}"
    local backup=''
    # M-11: prechecks are done; arm the transaction now, immediately
    # before the first mutating step (old-binary backup + install).
    core_upgrade_transaction_arm
    [[ -f "$bin_path" ]] && { backup="$tmp/$(basename "$bin_path").backup"; cp -a "$bin_path" "$backup" || { rm -rf "$tmp"; die "$backup_fail_msg"; }; }
    install_binary_atomically "$staged_path" "$bin_path" || { rm -rf "$tmp"; die "$install_fail_msg"; }
    if [[ "$was_active" == '1' ]]; then
        if ! restart_service_soft "$svc" || ! core_post_upgrade_health_gate "$health_arg"; then
            rollback_core_upgrade_verified "$svc" "$bin_path" "$backup" "$tmp"
        fi
    else
        if [[ -n "$smoke_fn" ]]; then
            if ! "$smoke_fn"; then
                msg "${RED}[!] New Hysteria binary failed smoke test with current config. Rolling back...${NC}"
                rollback_core_upgrade_verified "$svc" "$bin_path" "$backup" "$tmp" "$was_active"
            fi
        fi
        # P1-A: service was stopped, so restart_service_soft (which refreshes
        # the ownership manifest) was skipped. Record the new binary now to
        # keep /etc/ddr/.managed-core-files.tsv in sync.
        record_core_family_ownership "$svc" || { rm -rf "$tmp"; die "$(tr_msg "$ownership_fail_key")"; }
    fi
    msg "${GREEN}[OK] ${ok_msg}${NC} ${old_ver:-unknown} -> ${new_ver:-unknown}"
    rm -rf -- "$tmp"
    ABOX_CORE_UPGRADE_TMP=''
}

upgrade_xray_core_only() {
    local was_active=0 active_state='' backup='' tmp xray_zip xray_ext old_ver new_ver
    # C2 (Q8): handle any retired xray-latest instance before upgrading.
    xray_latest_legacy_retire || return 1
    abox_owns_service xray || die "$(tr_msg upgrade_xray_core_only_not_abox_managed)"
    msg "${YELLOW}[*] Upgrading Xray-core binary only; node parameters will be preserved...${NC}"
    get_architecture
    active_state=$(service_active_state_value xray 2>/dev/null) || die "$(tr_msg upgrade_xray_core_only_service_state_unknown)"
    case "$active_state" in 1) was_active=1 ;; 0) was_active=0 ;; *) die "$(tr_msg upgrade_xray_core_only_service_state_invalid)" ;; esac
    [[ -x /usr/local/bin/xray ]] && old_ver=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 || true)
    core_version_probe_safe /usr/local/bin/xray "${old_ver:-}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" || die "$(tr_msg upgrade_xray_core_only_read_version_failed)"
    local target_ref current_tag='' decision=0
    clear_core_release_resolution XTLS/Xray-core
    resolve_core_release_target XTLS/Xray-core || die "$(tr_msg upgrade_xray_core_only_resolve_target_failed)"
    target_ref="$ABOX_RESOLVED_XRAY_VERSION"
    if [[ -n "${old_ver:-}" ]]; then
        current_tag=$(core_version_from_output "$old_ver" || true)
        if [[ -z "$current_tag" ]]; then
            [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] || die "$(tr_msg upgrade_xray_core_only_current_version_unparseable)"
        else
            _core_upgrade_version_direction "$current_tag" "$target_ref" "${ABOX_XRAY_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
                "$(tprintf upgrade_xray_core_only_downgrade_refused "${current_tag}" "${target_ref}")" \
                "$(tr_msg upgrade_xray_core_only_version_uncomparable)" \
                "$(tprintf upgrade_xray_core_only_current_higher_skip "${current_tag}" "${target_ref}")" \
                "$(tprintf upgrade_xray_core_only_already_target "${current_tag}" "${target_ref}")" \
                'Xray version-direction guard returned an unexpected status.' \
                ''
            decision=$?
            case "$decision" in
                0) ;;
                3|4) return 0 ;;
                *) die 'Xray version-direction guard returned an unexpected status.' ;;
            esac
        fi
        [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] && msg "${YELLOW}[!] ABOX_ALLOW_CORE_DOWNGRADE=1: Xray version-direction guard explicitly bypassed.${NC}"
    fi
    tmp=$(abox_mktemp_exec_dir A-Box-core-xray) || die 'Xray core upgrade temp directory failed.'
    ABOX_CORE_UPGRADE_TMP="$tmp"
    xray_zip="$tmp/xray_core.zip"; xray_ext="$tmp/xray_ext"; mkdir -p "$xray_ext"
    fetch_github_release XTLS/Xray-core xray_core.zip "$xray_zip"
    extract_zip_member_safely "$xray_zip" xray "$xray_ext/xray" || { rm -rf "$tmp"; die 'Xray core archive safe extraction failed.'; }
    [[ -f "$xray_ext/xray" && ! -L "$xray_ext/xray" ]] || { rm -rf "$tmp"; die 'Xray binary not found after safe extraction.'; }
    chmod 755 "$xray_ext/xray" || { rm -rf "$tmp"; die 'Xray staged binary chmod failed.'; }
    new_ver=$("$xray_ext/xray" version 2>/dev/null | head -n 1 || true)
    [[ -n "$new_ver" ]] || { rm -rf "$tmp"; die 'Xray staged binary execution check failed.'; }
    core_binary_matches_release_ref "$ABOX_LAST_CORE_RELEASE_REF" "$new_ver" || { rm -rf "$tmp"; die "$(tprintf upgrade_xray_core_only_final_binary_mismatch "${ABOX_LAST_CORE_RELEASE_REF}")"; }
    if [[ -n "$current_tag" ]]; then
        local final_tag='' final_decision=0
        final_tag=$(core_version_from_output "$new_ver" 2>/dev/null) || { rm -rf "$tmp"; die "$(tr_msg upgrade_xray_core_only_final_version_unparseable)"; }
        _core_upgrade_version_direction "$current_tag" "$final_tag" "${ABOX_XRAY_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
            "$(tprintf upgrade_xray_core_only_downgrade_final_refused "${current_tag}" "${final_tag}")" \
            "$(tr_msg upgrade_xray_core_only_final_version_uncomparable)" \
            "$(tprintf upgrade_xray_core_only_final_lower_skip "${final_tag}" "${current_tag}")" \
            "$(tprintf upgrade_xray_core_only_final_same_skip "${final_tag}")" \
            "$(tr_msg upgrade_xray_core_only_direction_check_abnormal)" \
            "$tmp"
        final_decision=$?
        case "$final_decision" in
            0) ;;
            3|4) return 0 ;;
            *) rm -rf "$tmp"; die "$(tr_msg upgrade_xray_core_only_direction_check_abnormal)" ;;
        esac
    fi
    if [[ -f /usr/local/etc/xray/config.json ]] && ! XRAY_LOCATION_ASSET=/usr/local/share/xray "$xray_ext/xray" run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        rm -rf "$tmp"; die 'New Xray is incompatible with the current config; installed binary was not changed.'
    fi
    _core_upgrade_commit_install xray xray /usr/local/bin/xray "$xray_ext/xray" "$tmp" "$was_active" "${old_ver:-}" "${new_ver:-}" \
        'Xray binary backup failed.' 'Xray binary atomic install failed.' \
        'upgrade_xray_core_only_ownership_update_failed' 'Xray-core upgraded.'
}

upgrade_singbox_core_only() {
    local was_active=0 active_state='' backup='' tmp sb_tar sb_ext sb_path old_ver new_ver
    abox_owns_service sing-box || die "$(tr_msg upgrade_singbox_core_only_not_owned)"
    msg "${YELLOW}[*] Upgrading sing-box binary only; node parameters will be preserved...${NC}"
    get_architecture
    active_state=$(service_active_state_value sing-box 2>/dev/null) || die "$(tr_msg upgrade_singbox_core_only_state_unknown)"
    case "$active_state" in 1) was_active=1 ;; 0) was_active=0 ;; *) die "$(tr_msg upgrade_singbox_core_only_state_invalid)" ;; esac
    [[ -x /usr/local/bin/sing-box ]] && old_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 || true)
    core_version_probe_safe /usr/local/bin/sing-box "${old_ver:-}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" || die "$(tr_msg upgrade_singbox_core_only_version_unreadable)"
    local target_ref='' current_tag='' decision=0
    clear_core_release_resolution SagerNet/sing-box
    resolve_core_release_target SagerNet/sing-box || die "$(tr_msg upgrade_singbox_core_only_target_unresolvable)"
    target_ref="$ABOX_RESOLVED_SINGBOX_VERSION"
    if [[ -n "${old_ver:-}" ]]; then
        current_tag=$(core_version_from_output "$old_ver" || true)
        if [[ -z "$current_tag" ]]; then
            [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] || die "$(tr_msg upgrade_singbox_core_only_current_version_unparseable)"
        else
            _core_upgrade_version_direction "$current_tag" "$target_ref" "${ABOX_SINGBOX_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
                "$(tprintf upgrade_singbox_core_only_downgrade_refused "${current_tag}" "${target_ref}")" \
                "$(tr_msg upgrade_singbox_core_only_version_incomparable)" \
                "$(tprintf upgrade_singbox_core_only_above_pinned_skip "${current_tag}" "${target_ref}")" \
                "$(tprintf upgrade_singbox_core_only_already_pinned "${current_tag}")" \
                'sing-box version-direction guard returned an unexpected status.' \
                ''
            decision=$?
            case "$decision" in
                0) ;;
                3|4) return 0 ;;
                *) die 'sing-box version-direction guard returned an unexpected status.' ;;
            esac
        fi
        [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] && msg "${YELLOW}[!] ABOX_ALLOW_CORE_DOWNGRADE=1: sing-box version-direction guard explicitly bypassed.${NC}"
    fi
    tmp=$(abox_mktemp_exec_dir A-Box-core-singbox) || die 'sing-box core upgrade temp directory failed.'
    ABOX_CORE_UPGRADE_TMP="$tmp"
    sb_tar="$tmp/singbox_core.tar.gz"; sb_ext="$tmp/extract"; mkdir -p "$sb_ext"
    fetch_github_release SagerNet/sing-box singbox_core.tar.gz "$sb_tar"
    sb_path="$sb_ext/sing-box"
    extract_tar_regular_basename_safely "$sb_tar" sing-box "$sb_path" || { rm -rf "$tmp"; die 'sing-box archive safe extraction failed.'; }
    [[ -f "$sb_path" && ! -L "$sb_path" ]] || { rm -rf "$tmp"; die 'sing-box binary not found after safe extraction.'; }
    chmod 755 "$sb_path" || { rm -rf "$tmp"; die 'sing-box staged binary chmod failed.'; }
    new_ver=$("$sb_path" version 2>/dev/null | head -n 1 || true)
    [[ -n "$new_ver" ]] || { rm -rf "$tmp"; die 'sing-box staged binary execution check failed.'; }
    core_binary_matches_release_ref "$ABOX_LAST_CORE_RELEASE_REF" "$new_ver" || { rm -rf "$tmp"; die "$(tprintf upgrade_singbox_core_only_final_mismatch "${ABOX_LAST_CORE_RELEASE_REF}")"; }
    if [[ -n "$current_tag" ]]; then
        local final_tag='' final_decision=0
        final_tag=$(core_version_from_output "$new_ver" 2>/dev/null) || { rm -rf "$tmp"; die "$(tr_msg upgrade_singbox_core_only_final_version_unparseable)"; }
        _core_upgrade_version_direction "$current_tag" "$final_tag" "${ABOX_SINGBOX_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
            "$(tprintf upgrade_singbox_core_only_final_downgrade_refused "${current_tag}" "${final_tag}")" \
            "$(tr_msg upgrade_singbox_core_only_final_version_incomparable)" \
            "$(tprintf upgrade_singbox_core_only_final_below_skip "${final_tag}" "${current_tag}")" \
            "$(tprintf upgrade_singbox_core_only_final_same "${final_tag}")" \
            "$(tr_msg upgrade_singbox_core_only_final_direction_error)" \
            "$tmp"
        final_decision=$?
        case "$final_decision" in
            0) ;;
            3|4) return 0 ;;
            *) rm -rf "$tmp"; die "$(tr_msg upgrade_singbox_core_only_final_direction_error)" ;;
        esac
    fi
    if [[ -f /etc/sing-box/config.json ]] && ! "$sb_path" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        rm -rf "$tmp"; die 'New sing-box is incompatible with the current config; installed binary was not changed.'
    fi
    _core_upgrade_commit_install sing-box singbox /usr/local/bin/sing-box "$sb_path" "$tmp" "$was_active" "${old_ver:-}" "${new_ver:-}" \
        'sing-box binary backup failed.' 'sing-box binary atomic install failed.' \
        'upgrade_singbox_core_only_ownership_update_fail' 'sing-box upgraded.'
}

upgrade_hysteria_core_only() {
    local was_active=0 active_state='' backup='' tmp hy2_bin old_ver new_ver
    abox_owns_service hysteria || die "$(tr_msg upgrade_hysteria_core_only_not_owned)"
    msg "${YELLOW}[*] Upgrading Hysteria 2 binary only; node parameters will be preserved. Hysteria has no documented standalone config-check command; a staged loopback startup precheck runs before replacement, followed by the existing post-install checks and rollback on failure.${NC}"
    get_architecture
    active_state=$(service_active_state_value hysteria 2>/dev/null) || die "$(tr_msg upgrade_hysteria_core_only_state_unknown)"
    case "$active_state" in 1) was_active=1 ;; 0) was_active=0 ;; *) die "$(tr_msg upgrade_hysteria_core_only_state_invalid)" ;; esac
    [[ -x /usr/local/bin/hysteria ]] && old_ver=$(/usr/local/bin/hysteria version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    core_version_probe_safe /usr/local/bin/hysteria "${old_ver:-}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" || die "$(tr_msg upgrade_hysteria_core_only_version_unreadable)"
    local target_ref='' current_tag='' decision=0
    clear_core_release_resolution HyNetworks/hysteria
    resolve_core_release_target HyNetworks/hysteria || die "$(tr_msg upgrade_hysteria_core_only_target_unresolvable)"
    target_ref="$ABOX_RESOLVED_HYSTERIA_VERSION"
    if [[ -n "${old_ver:-}" ]]; then
        current_tag=$(core_version_from_output "$old_ver" || true)
        if [[ -z "$current_tag" ]]; then
            [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] || die "$(tr_msg upgrade_hysteria_core_only_current_version_unparseable)"
        else
            _core_upgrade_version_direction "$current_tag" "$target_ref" "${ABOX_HYSTERIA_APP_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
                "$(tprintf upgrade_hysteria_core_only_downgrade_refused "${current_tag}" "${target_ref#*/}")" \
                "$(tr_msg upgrade_hysteria_core_only_version_incomparable)" \
                "$(tprintf upgrade_hysteria_core_only_above_pinned_skip "${current_tag}" "${target_ref#*/}")" \
                "$(tprintf upgrade_hysteria_core_only_already_pinned "${current_tag}")" \
                'Hysteria version-direction guard returned an unexpected status.' \
                ''
            decision=$?
            case "$decision" in
                0) ;;
                3|4) return 0 ;;
                *) die 'Hysteria version-direction guard returned an unexpected status.' ;;
            esac
        fi
        [[ "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" == 1 ]] && msg "${YELLOW}[!] ABOX_ALLOW_CORE_DOWNGRADE=1: Hysteria version-direction guard explicitly bypassed.${NC}"
    fi
    tmp=$(abox_mktemp_exec_dir A-Box-core-hysteria) || die 'Hysteria core upgrade temp directory failed.'
    ABOX_CORE_UPGRADE_TMP="$tmp"
    hy2_bin="$tmp/hysteria_core"
    fetch_github_release HyNetworks/hysteria hysteria_core "$hy2_bin"
    chmod 755 "$hy2_bin" || { rm -rf "$tmp"; die 'Hysteria staged binary chmod failed.'; }
    new_ver=$("$hy2_bin" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ -n "$new_ver" ]] || { rm -rf "$tmp"; die 'Hysteria staged binary execution check failed.'; }
    core_binary_matches_release_ref "$ABOX_LAST_CORE_RELEASE_REF" "$new_ver" || { rm -rf "$tmp"; die "$(tprintf upgrade_hysteria_core_only_final_mismatch "${ABOX_LAST_CORE_RELEASE_REF}")"; }
    if [[ -n "$current_tag" ]]; then
        local final_tag='' final_decision=0
        final_tag=$(core_version_from_output "$new_ver" 2>/dev/null) || { rm -rf "$tmp"; die "$(tr_msg upgrade_hysteria_core_only_final_version_unparseable)"; }
        _core_upgrade_version_direction "$current_tag" "$final_tag" "${ABOX_HYSTERIA_APP_VERSION:+1}" "${ABOX_ALLOW_CORE_DOWNGRADE:-0}" \
            "$(tprintf upgrade_hysteria_core_only_final_downgrade_refused "${current_tag}" "${final_tag}")" \
            "$(tr_msg upgrade_hysteria_core_only_final_version_incomparable)" \
            "$(tprintf upgrade_hysteria_core_only_final_below_skip "${final_tag}" "${current_tag}")" \
            "$(tprintf upgrade_hysteria_core_only_final_same "${final_tag}")" \
            "$(tr_msg upgrade_hysteria_core_only_final_direction_error)" \
            "$tmp"
        final_decision=$?
        case "$final_decision" in
            0) ;;
            3|4) return 0 ;;
            *) rm -rf "$tmp"; die "$(tr_msg upgrade_hysteria_core_only_final_direction_error)" ;;
        esac
    fi
    if ! hysteria_staged_binary_smoke_test "$hy2_bin"; then
        rm -rf "$tmp"; die 'Hysteria staged startup precheck failed; installed binary was not changed.'
    fi
    _core_upgrade_commit_install hysteria hysteria /usr/local/bin/hysteria "$hy2_bin" "$tmp" "$was_active" "${old_ver:-}" "${new_ver:-}" \
        'Hysteria binary backup failed.' 'Hysteria binary atomic install failed.' \
        'upgrade_hysteria_core_only_ownership_update_fail' 'Hysteria upgraded.' 'hysteria_binary_smoke_test'
}

# H1 (OTA Hy2 gap): staged-startup precheck helpers. The staged binary is
# started directly (never via systemctl), on a temporary loopback copy of
# the current config, and stopped again before any install happens.
# Set while a staged child is alive; the INT/TERM guard uses it to kill
# the child before re-raising so the caller's handler still runs.
_HY2_STAGED_PID=''
_HY2_PREV_INT=''
_HY2_PREV_TERM=''

# True (rc 0) iff PID is already dead or a zombie. /proc/<pid>/stat is
# "<pid> (<comm>) <state> ...": strip greedily through the last ')'
# (comm may itself contain spaces/parens) and read the state field.
hy2_staged_pid_dead() {
    local p="$1" st=''
    kill -0 "$p" 2>/dev/null || return 0
    st=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1}' || true)
    [[ "$st" == "Z" ]]
}

# Stop the staged child: SIGTERM, up to 3s grace, then SIGKILL, then reap.
# Returns 0 iff the child is dead/reaped afterwards; 1 if it is still
# alive (the caller must treat that as precheck failure). Never kills by
# name or port owner: only the recorded staged PID.
hy2_staged_kill_child() {
    local p="${_HY2_STAGED_PID:-}" waited=0
    [[ -n "$p" ]] || return 0
    # R15-F16-02: the PID registration is cleared only after the child is
    # confirmed dead (or after the final KILL attempt below). Clearing it
    # before the TERM let a signal landing in between make the trap handler
    # see an empty registration and leave the child without any signal.
    kill -TERM "$p" 2>/dev/null || true
    while (( waited < 3 )); do
        if hy2_staged_pid_dead "$p"; then wait "$p" 2>/dev/null || true; _HY2_STAGED_PID=''; return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    if hy2_staged_pid_dead "$p"; then wait "$p" 2>/dev/null || true; _HY2_STAGED_PID=''; return 0; fi
    kill -KILL "$p" 2>/dev/null || true
    waited=0
    while (( waited < 3 )); do
        if hy2_staged_pid_dead "$p"; then wait "$p" 2>/dev/null || true; _HY2_STAGED_PID=''; return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    if hy2_staged_pid_dead "$p"; then wait "$p" 2>/dev/null || true; _HY2_STAGED_PID=''; return 0; fi
    _HY2_STAGED_PID=''
    return 1
}

# Restore the INT/TERM/HUP traps the staged helper saved on entry
# (sentinel 'trap - INT' / 'trap - TERM' / 'trap - HUP' means "no
# previous trap": remove ours).
hy2_staged_restore_traps() {
    eval "$_HY2_PREV_INT"
    eval "$_HY2_PREV_TERM"
    eval "$_HY2_PREV_HUP"
}

# INT/TERM guard for the staged run: stop the child, restore the caller's
# traps, then re-raise so the caller's handler (e.g. the core-upgrade
# transaction abort) runs. Mirrors the install/restore trap discipline
# used by the core-upgrade transaction itself.
hy2_staged_trap_abort() {
    local sig="$1"
    # R11-F R2-10-3 (scheme D): a signal arriving while the staged
    # server is being started but its PID is not yet registered is
    # only RECORDED here; the smoke test runs the real abort right
    # after registration. This neither drops the abort request (as
    # trap '' would) nor guesses a PID via $! (which could still be
    # a stale unrelated background job). First pending signal wins.
    if [[ "${_HY2_STAGED_STARTING:-0}" == 1 ]]; then
        if [[ -z "${_HY2_STAGED_PENDING_SIG:-}" ]]; then
            _HY2_STAGED_PENDING_SIG="$sig"
        fi
        return 0
    fi
    hy2_staged_kill_child || true
    # The re-raise below kills this shell, so the helper's normal
    # `rm -rf "$work"` never runs: remove the staged work dir here
    # (it holds a copy of the config). `work` is the helper's local,
    # visible via dynamic scoping while the helper is on the stack.
    [[ -n "${work:-}" ]] && rm -rf -- "$work" 2>/dev/null || true
    hy2_staged_restore_traps
    kill -"$sig" "$BASHPID"
}

# True iff ss shows UDP 127.0.0.1:<port> owned by <pid> on the same
# record. Exact endpoint token AND exact numeric PID token: a PID-prefix
# match (pid=123 vs pid=1234), a wildcard/IPv6 listener, another PID on
# the endpoint, or missing process info all fail. ss failure fails.
hy2_ss_owns_port() {
    local pid="$1" port="$2"
    [[ "$pid" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
    ss -H -4 -lnup 2>/dev/null | awk -v addr="127.0.0.1:${port}" -v pid="$pid" '
        index($0, addr " ") > 0 && $0 ~ "(^|[^0-9])pid=" pid "([^0-9]|$)" { found=1 }
        END { exit !found }'
}

# True iff any UDP listener owns 127.0.0.1:<port> (used for the pre-start
# collision check; ownership by anyone counts as a collision here).
hy2_ss_port_bound() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ss -H -4 -lnup 2>/dev/null | awk -v addr="127.0.0.1:${port}" '
        index($0, addr " ") > 0 { found=1 }
        END { exit !found }'
}

# H1 (OTA Hy2 gap): pre-install staged startup precheck for a Hysteria
# binary that has been downloaded but NOT yet installed. Runs the staged
# binary with a temporary loopback copy of the current config, requires
# the staged process itself to own the UDP socket, then stops it.
# Coverage (scoped, GPT A' verdict): detects config/initialisation
# failures exercised by that staged environment. Does NOT validate the
# original listener, the full service execution context, or QUIC/Hysteria
# handshakes (that leg stays an open residual, covered by live-traffic
# testing, not by this gate). Runs as root like the other installer
# checks; it does not validate service-user permissions.
# Recognised A-Box ACME profiles are skipped, never started: upstream
# runs certmagic ManageSync synchronously at startup, so a loopback
# staged start could contact external services or modify certificate
# storage. Unrecognised shapes fail (never skip). No new tr_msg keys:
# the die/warning strings follow the hardcoded-English precedent of the
# Xray/sing-box sibling precheck messages.
hysteria_staged_binary_smoke_test() {
    local bin="$1" cfg="${2:-/etc/hysteria/config.yaml}"
    local work='' tmp_cfg='' port='' profile='' pid='' rc=1
    local outcome='' ok='' attempt=0 deadline=0 ready=0 py_rc=0
    command -v python3 >/dev/null 2>&1 || return 1
    command -v ss >/dev/null 2>&1 || return 1
    [[ -x "$bin" && -f "$cfg" && ! -L "$cfg" ]] || return 1
    abox_owns_service hysteria || return 1
    work=$(mktemp -d /tmp/A-Box-hy2-staged.XXXXXX) || return 1
    chmod 700 "$work" || { rm -rf "$work"; return 1; }
    tmp_cfg="$work/config.yaml"
    _HY2_PREV_INT=$(trap -p INT || true); [[ -n "$_HY2_PREV_INT" ]] || _HY2_PREV_INT='trap - INT'
    _HY2_PREV_TERM=$(trap -p TERM || true); [[ -n "$_HY2_PREV_TERM" ]] || _HY2_PREV_TERM='trap - TERM'
    _HY2_PREV_HUP=$(trap -p HUP || true); [[ -n "$_HY2_PREV_HUP" ]] || _HY2_PREV_HUP='trap - HUP'
    # R11-F R2-10-3: start-window state (function locals; the abort
    # helper reads them via dynamic scoping, same as $work below).
    local _HY2_STAGED_STARTING=0 _HY2_STAGED_PENDING_SIG=''
    trap 'hy2_staged_trap_abort INT' INT
    trap 'hy2_staged_trap_abort TERM' TERM
    trap 'hy2_staged_trap_abort HUP' HUP
    deadline=$(( $(date +%s) + 10 ))
    while (( attempt < 3 )); do
        attempt=$((attempt + 1))
        # Fresh recognition + rewrite each attempt (fresh ephemeral port).
        # The recogniser prints "OK <port> <tls|acme>" or "REJECT <reason>".
        outcome=$(python3 -I - "$cfg" "$tmp_cfg" <<'PY_HY2_STAGED' 2>"$work/py.err"
import os
import socket
import sys

ALLOWED_TOP = {"listen", "tls", "acme", "obfs", "auth", "bandwidth", "masquerade"}

def reject(reason):
    sys.stdout.write("REJECT " + reason + "\n")
    sys.exit(1)

def main():
    cfg = sys.argv[1]
    out = sys.argv[2]
    try:
        # R62-L01: newline="" keeps CR/CRLF intact so the "\r" check
        # below can actually fire; the default universal-newlines mode
        # translated CRLF to "\n" and made the reject branch dead code.
        with open(cfg, "r", encoding="utf-8", newline="") as f:
            raw = f.read()
    except OSError:
        reject("config unreadable")
    if "\r" in raw:
        reject("CRLF config unsupported")
    lines = raw.split("\n")
    top = {}
    top_order = []
    listen_idx = -1
    listen_val = None
    for i, line in enumerate(lines):
        if line == "" or line.startswith("#"):
            continue
        if line.startswith("---") or line.startswith("..."):
            reject("multi-document config unsupported")
        if line[0] in " \t":
            low = line.strip()
            if low.startswith("listen:") or low.startswith("listenHTTP:") or low.startswith("listenHTTPS:"):
                reject("nested listen line unsupported")
            continue
        if line[0] in "\"'":
            reject("quoted top-level key unsupported")
        if ":" not in line:
            reject("unsupported top-level line")
        key = line.split(":", 1)[0]
        if not key or not key[0].isalpha() or not key.replace("_", "").replace("-", "").isalnum():
            reject("unsupported top-level key")
        if key in top:
            reject("duplicate top-level key " + key)
        top[key] = i
        top_order.append(key)
        if key == "listen":
            listen_idx = i
            listen_val = line.split(":", 1)[1].strip()
    unknown = [k for k in top_order if k not in ALLOWED_TOP]
    if unknown:
        reject("unsupported top-level key " + unknown[0])
    if listen_idx < 0:
        reject("missing top-level listen")
    val = listen_val.split("#", 1)[0].strip()
    if val.startswith("\"") or val.startswith("'"):
        reject("quoted listen value unsupported")
    if not val.startswith(":"):
        reject("listen value must be :port or :start-end")
    portpart = val[1:]
    if "-" in portpart:
        pair = portpart.split("-", 1)
        if len(pair) != 2 or not pair[0].isdigit() or not pair[1].isdigit():
            reject("listen range not numeric")
        lo = int(pair[0])
        hi = int(pair[1])
        if not (1 <= lo <= 65535 and 1 <= hi <= 65535 and lo <= hi):
            reject("listen range out of bounds")
    else:
        if not portpart.isdigit():
            reject("listen port not numeric")
        lo = int(portpart)
        if not (1 <= lo <= 65535):
            reject("listen port out of bounds")
    has_tls = "tls" in top
    has_acme = "acme" in top
    if has_tls == has_acme:
        reject("config must set exactly one of tls or acme")
    profile = "tls" if has_tls else "acme"
    def block(bkey):
        start = top[bkey]
        end = len(lines)
        for k2, idx in top.items():
            if idx > start and idx < end:
                end = idx
        return lines[start + 1:end]
    if profile == "tls":
        cert = None
        keyf = None
        for ln in block("tls"):
            s = ln.strip()
            if s.startswith("cert:"):
                if cert is not None:
                    reject("duplicate tls cert")
                cert = s.split(":", 1)[1].strip().strip("\"'")
            elif s.startswith("key:"):
                if keyf is not None:
                    reject("duplicate tls key")
                keyf = s.split(":", 1)[1].strip().strip("\"'")
        if not cert or not keyf:
            reject("tls cert/key missing")
        if not cert.startswith("/") or not keyf.startswith("/"):
            reject("tls cert/key must be absolute paths")
    else:
        d = None
        typ = None
        email = None
        domains = 0
        in_domains = False
        for ln in block("acme"):
            if ln.startswith("  ") and not ln.startswith("   "):
                s = ln.strip()
                if s.startswith("dir:"):
                    d = s.split(":", 1)[1].strip().strip("\"'")
                    in_domains = False
                elif s.startswith("type:"):
                    typ = s.split(":", 1)[1].strip().strip("\"'")
                    in_domains = False
                elif s.startswith("email:"):
                    email = s.split(":", 1)[1].strip().strip("\"'")
                    in_domains = False
                elif s.startswith("domains:"):
                    in_domains = True
                else:
                    in_domains = False
            elif ln.startswith("    - ") and in_domains:
                domains += 1
            elif ln.strip() == "":
                continue
            else:
                in_domains = False
        if d != "/etc/hysteria/acme":
            reject("acme dir must be /etc/hysteria/acme")
        if typ not in ("http", "dns"):
            reject("acme type must be http or dns")
        if domains < 1:
            reject("acme domains empty")
        if not email:
            reject("acme email missing")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    finally:
        s.close()
    lines[listen_idx] = "listen: 127.0.0.1:" + str(port)
    try:
        with open(out, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
    except OSError:
        reject("temp config write failed")
    sys.stdout.write("OK " + str(port) + " " + profile + "\n")

main()
PY_HY2_STAGED
)
        py_rc=$?
        if (( py_rc != 0 )); then
            msg "${RED}[!] Hysteria staged precheck: ${outcome#REJECT }${NC}" >&2
            rc=1; break
        fi
        read -r ok port profile <<<"$outcome"
        if [[ "$ok" != "OK" || ! "$port" =~ ^[0-9]+$ || ( "$profile" != "tls" && "$profile" != "acme" ) ]]; then
            msg "${RED}[!] Hysteria staged precheck: unrecognised recogniser output.${NC}" >&2
            rc=1; break
        fi
        chmod 600 "$tmp_cfg" || { rc=1; break; }
        if [[ "$profile" == "acme" ]]; then
            msg "${YELLOW}[!] WARNING: Hysteria staged startup precheck skipped for this A-Box ACME configuration. Startup performs synchronous ACME certificate management and may contact external services or modify certificate storage. The staged binary was not started. Upgrade will proceed using the existing post-install restart/rollback checks.${NC}"
            rc=0; break
        fi
        # Collision already present on the fresh port: retry with a new one.
        if hy2_ss_port_bound "$port"; then
            if (( attempt < 3 )) && (( $(date +%s) < deadline )); then continue; fi
            msg "${RED}[!] Hysteria staged precheck: loopback port ${port} already in use.${NC}" >&2
            rc=1; break
        fi
        # R11-F R2-10-3: signals between here and PID registration
        # are recorded, not executed, by the trap (see above); the
        # pending request is executed immediately below, once
        # _HY2_STAGED_PID is set. Do not insert work between clearing
        # STARTING and the pending check.
        _HY2_STAGED_STARTING=1
        "$bin" server -c "$tmp_cfg" >"$work/server.log" 2>&1 9>&- 10>&- &
        pid=$!
        _HY2_STAGED_PID="$pid"
        _HY2_STAGED_STARTING=0
        if [[ -n "${_HY2_STAGED_PENDING_SIG:-}" ]]; then
            hy2_staged_trap_abort "$_HY2_STAGED_PENDING_SIG"
        fi
        ready=0
        while (( $(date +%s) < deadline )); do
            if hy2_staged_pid_dead "$pid"; then break; fi
            if hy2_ss_owns_port "$pid" "$port"; then
                if ! hy2_staged_pid_dead "$pid"; then ready=1; break; fi
            fi
            sleep 1
        done
        if ! hy2_staged_kill_child; then
            msg "${RED}[!] Hysteria staged precheck: could not stop the staged server.${NC}" >&2
            rc=1; break
        fi
        if (( ready == 1 )); then rc=0; break; fi
        # Retry ONLY a positively identified local bind collision.
        if grep -q "address already in use" "$work/server.log" 2>/dev/null; then
            if (( attempt < 3 )) && (( $(date +%s) < deadline )); then continue; fi
        fi
        msg "${RED}[!] Hysteria staged precheck: staged server did not reach a listening state.${NC}" >&2
        rc=1; break
    done
    rm -rf "$work"
    hy2_staged_restore_traps
    return "$rc"
}

# N-04: smoke-test a Hysteria binary against the current config by doing a
# temporary start, waiting for the port, then stopping. Used when the service
# was not active before upgrade (no restart-based validation available).
# FINAL-AUDIT fix: the temporary start must NOT change the service's
# enablement state. start_abox_service_soft() runs `systemctl enable` /
# `rc-update add`, which would silently flip a deliberately disabled/stopped
# service to enabled. Snapshot active+enabled before, start without enable,
# and restore the original enablement afterwards; a failed restore is an
# error, not a silent pass.
hysteria_binary_smoke_test() {
    local cfg='/etc/hysteria/config.yaml'
    local was_enabled_state='' ok=0 waited=0 rc=1 restore_failed=0 cur_state='' rc_out='' rc_status=0 stop_rc=0 stop_state='' stop_unknown=0
    [[ -x /usr/local/bin/hysteria && -f "$cfg" ]] || return 1
    abox_owns_service hysteria || return 1
    # Snapshot enablement state with full granularity. systemctl is-enabled
    # can return: enabled, disabled, masked, enabled-runtime, static,
    # indirect, generated, transient, etc. We must restore exactly.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        # U229: is-enabled prints the state word AND exits non-zero
        # for disabled/masked, so $(... || printf 'unknown') produced
        # "disabled\nunknown" and no case branch matched. Capture the
        # output first; 'unknown' only when nothing was printed.
        was_enabled_state=$(systemctl is-enabled hysteria 2>/dev/null || true)
        [[ -n "$was_enabled_state" ]] || was_enabled_state='unknown'
        # A masked service cannot be started; skip rather than unmasking it.
        if [[ "$was_enabled_state" == 'masked' ]]; then
            msg "${YELLOW}[!] Hysteria service is masked; skipping smoke test.${NC}" >&2
            return 1
        fi
        [[ "$was_enabled_state" != 'unknown' ]] || return 1
    elif [[ "${INIT_SYS:-}" == 'openrc' ]]; then
        # S164: a failed rc-update query must not be read as
        # "disabled": capture output + status first; nonzero means the
        # state is unknown, so fail instead of recording a lie.
        rc_out=$(rc-update show default 2>/dev/null); rc_status=$?
        (( rc_status == 0 )) || return 1
        if printf '%s\n' "$rc_out" | grep -Eq '(^|[[:space:]])hysteria([[:space:]]|$)'; then
            was_enabled_state='enabled'
        else
            was_enabled_state='disabled'
        fi
    else
        return 1
    fi
    # --- Test body: start WITHOUT changing enablement, then probe. ---
    # (`systemctl start` / `rc-service start` never touch enablement.)
    # Every path below falls through to the unified cleanup; there are no
    # early returns after this point.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        if systemctl daemon-reload >/dev/null 2>&1; then
            if systemctl start hysteria >/dev/null 2>&1 || systemctl restart hysteria >/dev/null 2>&1; then
                # U230: the port check joins the wait loop; a port that
                # is not ready yet must retry while budget remains,
                # not fail on a single post-active check.
                while (( waited < 10 )); do
                    sleep 1; waited=$((waited + 1))
                    if is_service_running hysteria 2>/dev/null && core_ports_listening hysteria "$cfg" 2>/dev/null; then
                        ok=1; break
                    fi
                done
            fi
        fi
    else
        if rc-service hysteria restart >/dev/null 2>&1 9>&- 10>&-; then
            # U230: same loop-join as the systemd branch.
            while (( waited < 10 )); do
                sleep 1; waited=$((waited + 1))
                if is_service_running hysteria 2>/dev/null && core_ports_listening hysteria "$cfg" 2>/dev/null; then
                    ok=1; break
                fi
            done
        fi
    fi
    (( ok == 1 )) && rc=0
    # --- Unified cleanup: ALWAYS runs (success, start failure, probe timeout).
    # Stop the service first.
    # R7-F16-4: distinguish "stopped" from "unknown". A failed stop
    # command or an unreadable service state must not be read as
    # "stopped": the temporary service may still be running. Only a
    # confirmed stopped state (service_active_state_value rc 0, output
    # 0) clears the stop; an unknown state fails the restore. A
    # non-zero stop alone is not a failure when the service is
    # confirmed stopped (it may already have been stopped).
    stop_abox_service_soft hysteria >/dev/null 2>&1 || stop_rc=$?
    waited=0
    while (( waited < 10 )); do
        if stop_state=$(service_active_state_value hysteria 2>/dev/null); then
            [[ "$stop_state" == 0 ]] && break
        else
            stop_unknown=1
            break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if (( stop_unknown == 1 )); then
        msg "${RED}[!] Hysteria smoke test could not determine whether the temporary service stopped; manual check required.${NC}" >&2
        restore_failed=1
    elif [[ "$stop_state" != 0 ]]; then
        msg "${RED}[!] Hysteria smoke test could not stop the temporary service; manual check required.${NC}" >&2
        restore_failed=1
    fi
    # Restore the exact original enablement state. A changed state here would
    # mean the temporary start leaked a state change; report loudly.
    if [[ "${INIT_SYS:-}" == 'systemd' ]]; then
        cur_state=$(systemctl is-enabled hysteria 2>/dev/null || true)
        [[ -n "$cur_state" ]] || cur_state='unknown'
        # S164: an unreadable current state cannot prove restoration.
        [[ "$cur_state" != 'unknown' ]] || restore_failed=1
        if [[ "$cur_state" != "$was_enabled_state" ]]; then
            case "$was_enabled_state" in
                enabled)
                    systemctl enable hysteria >/dev/null 2>&1 || restore_failed=1
                    [[ "$(systemctl is-enabled hysteria 2>/dev/null)" == enabled ]] || restore_failed=1 ;;
                enabled-runtime) systemctl disable hysteria >/dev/null 2>&1 || restore_failed=1; systemctl enable --runtime hysteria >/dev/null 2>&1 || restore_failed=1; [[ "$(systemctl is-enabled hysteria 2>/dev/null)" == enabled-runtime ]] || restore_failed=1 ;;
                masked)
                    systemctl mask hysteria >/dev/null 2>&1 || restore_failed=1 ;;
                disabled)
                    case "$cur_state" in
                        enabled|enabled-runtime)
                            systemctl disable hysteria >/dev/null 2>&1 || restore_failed=1 ;;
                    esac ;;
                # static, indirect, generated, etc.: informational states tied
                # to the unit file; `start` cannot change them. Do not touch.
            esac
        fi
    else
        # S164: a failed cleanup query must fail the restore, not
        # be swallowed (the old `|| true` hid it and restore_failed
        # stayed 0 while restoration was unverified).
        rc_out=$(rc-update show default 2>/dev/null); rc_status=$?
        if (( rc_status != 0 )); then
            restore_failed=1
        elif [[ "$was_enabled_state" == 'enabled' ]]; then
            printf '%s\n' "$rc_out" | grep -Eq '(^|[[:space:]])hysteria([[:space:]]|$)' || { rc-update add hysteria default >/dev/null 2>&1 || restore_failed=1; }
        else
            printf '%s\n' "$rc_out" | grep -Eq '(^|[[:space:]])hysteria([[:space:]]|$)' && { rc-update del hysteria default >/dev/null 2>&1 || restore_failed=1; }
        fi
    fi
    if (( restore_failed == 1 )); then
        msg "${RED}[!] Hysteria smoke test could not restore the original service enablement state; manual check required.${NC}" >&2
        return 1
    fi
    return "$rc"
}

restore_core_upgrade_transaction_traps() {
    restore_saved_trap EXIT "$ABOX_CORE_TX_PREV_TRAP_EXIT"
    restore_saved_trap INT "$ABOX_CORE_TX_PREV_TRAP_INT"
    restore_saved_trap TERM "$ABOX_CORE_TX_PREV_TRAP_TERM"
    restore_saved_trap HUP "$ABOX_CORE_TX_PREV_TRAP_HUP"
    ABOX_CORE_TX_PREV_TRAP_EXIT=''; ABOX_CORE_TX_PREV_TRAP_INT=''; ABOX_CORE_TX_PREV_TRAP_TERM=''; ABOX_CORE_TX_PREV_TRAP_HUP=''
}

# S163: record a core-transaction rollback outcome for the parent
# loop. No-op when the caller did not provide a status file (other
# begin callers are unaffected). An unwritable file is removed so the
# parent reads "unknown" and stops, rather than a stale state.
# States: not-started (begin never ran / backup failed), not-modified
# (M-11: prepared but nothing installed yet; a precheck failure needs
# no rollback), active, ok, failed.
core_upgrade_transaction_set_status() {
    [[ -n "${ABOX_CORE_TX_RB_STATUS:-}" ]] || return 0
    printf '%s\n' "$1" > "$ABOX_CORE_TX_RB_STATUS" 2>/dev/null || rm -f -- "$ABOX_CORE_TX_RB_STATUS"
}

# 2ds residual: shared pure-validation gate for a restore archive.
# Mirrors the pure-validation prefix of restore_latest_backup_silent
# (selection, F01 private copy, checksum, HMAC, structure, unpack,
# target-safe, shortcut-safe, init-compatibility, live-manifest) and
# stops BEFORE any destructive step. The core-upgrade rollback calls
# it so a backup that passes checksum/HMAC/structure but fails a
# deeper check aborts BEFORE services are stopped and core families
# force-removed. Pure validation only: the private work dir is
# removed on every return path; the restore itself re-validates
# independently when it runs (the double unpack is deliberate and
# cheap against destroying a live system on a bad backup).
restore_backup_prevalidate() {
    local backup_dir="${1:-$ABOX_DIR/backups}" selected="${2:-}" retain="${3:-0}" work root
    [[ -d "$backup_dir" ]] || { msg "prevalidate gate failed: backup-dir" >&2; return 1; }
    if [[ -n "$selected" ]]; then
        [[ -f "$selected" && "$(dirname "$selected")" == "$backup_dir" ]] || { msg "prevalidate gate failed: selected-path" >&2; return 1; }
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
) || { msg "prevalidate gate failed: latest-select" >&2; return 1; }
    fi
    [[ -n "$selected" ]] || { msg "prevalidate gate failed: selected-empty" >&2; return 1; }
    # R15-09: a retained pin is a recovery bundle from an earlier
    # transaction -- never silently overwrite it, and never publish a
    # new one while one is live. A dangling value (dir gone) is cleared.
    if [[ -n "${ABOX_PREVALIDATE_WORK:-}" ]]; then
        if [[ -d "$ABOX_PREVALIDATE_WORK" ]]; then
            msg "prevalidate gate failed: stale retained pin exists: $ABOX_PREVALIDATE_WORK" >&2; return 1
        fi
        ABOX_PREVALIDATE_WORK=''
    fi
    # F01: verify-and-extract must use one pinned copy, not the
    # shared $selected path (a writer on the backup dir could
    # swap it between verify and tar). Copy the archive plus
    # its sidecars (same basenames, so every derived sidecar
    # and key path stays correct) into the private work dir
    # first; every later step uses the copy.
    work=$(mktemp -d /tmp/A-Box-prevalidate.XXXXXX) || { msg "prevalidate gate failed: workdir" >&2; return 1; }; chmod 700 "$work"
    local _rbc="$work/$(basename "$selected")" _rbs=''
    cp -- "$selected" "$_rbc" || { rm -rf "$work"; msg "prevalidate gate failed: private-copy" >&2; return 1; }
    chmod 600 "$_rbc" || { rm -rf "$work"; msg "prevalidate gate failed: private-copy" >&2; return 1; }
    for _rbs in "${selected}.sha256" "${selected}.hmac" "${selected}.key"; do
        if [[ -e "$_rbs" ]]; then
            cp -- "$_rbs" "$work/$(basename "$_rbs")" || { rm -rf "$work"; msg "prevalidate gate failed: private-copy" >&2; return 1; }
        fi
    done
    backup_checksum_verify "$_rbc" "${_rbc}.sha256" || { rm -rf "$work"; msg "prevalidate gate failed: checksum" >&2; return 1; }
    backup_auth_verify "$_rbc" "${_rbc}.hmac" || { rm -rf "$work"; msg "prevalidate gate failed: hmac" >&2; return 1; }
    validate_backup_archive "$_rbc" || { rm -rf "$work"; msg "prevalidate gate failed: archive" >&2; return 1; }
    tar -xzf "$_rbc" -C "$work" || { rm -rf "$work"; msg "prevalidate gate failed: unpack" >&2; return 1; }
    root="$work/root"; assert_restore_target_safe "$root" || { rm -rf "$work"; msg "prevalidate gate failed: target-safe" >&2; return 1; }; assert_restore_shortcut_safe "$root" || { rm -rf "$work"; msg "prevalidate gate failed: shortcut-safe" >&2; return 1; }; validate_backup_core_init_compatibility "$root" || { rm -rf "$work"; msg "prevalidate gate failed: init-compat" >&2; return 1; }
    if [[ -e "$ABOX_CORE_OWNERSHIP" || -L "$ABOX_CORE_OWNERSHIP" ]]; then
        [[ -f "$ABOX_CORE_OWNERSHIP" && ! -L "$ABOX_CORE_OWNERSHIP" ]] || { rm -rf "$work"; msg "prevalidate gate failed: live-manifest" >&2; return 1; }
        # SYD-B7: validate the live manifest BEFORE any destructive step;
        # a corrupt live manifest must fail here, not after stop/remove/clear.
        [[ "$(stat -c %s "$ABOX_CORE_OWNERSHIP" 2>/dev/null || echo 99999999)" -le 4194304 ]] || { rm -rf "$work"; msg "prevalidate gate failed: live-manifest-size" >&2; return 1; }
        _manifest_rows_valid "$ABOX_CORE_OWNERSHIP" || { rm -rf "$work"; msg "prevalidate gate failed: live-manifest-rows" >&2; return 1; }
    fi
    # R15-09: retain the verified copy ONLY on opt-in. Check-only callers
    # keep the old behaviour (the work dir is deleted). The pin is
    # published here -- after every gate above succeeded -- and the
    # rollback consumes it through the existing restore arguments.
    if [[ "$retain" == 1 ]]; then
        ABOX_PREVALIDATE_WORK="$work"
    else
        rm -rf "$work"
    fi
    return 0
}

core_upgrade_rollback_backup_valid() {
    # 2ds residual: the shallow checks below used to live here
    # (checksum/HMAC/structure on the shared path, candidate-exists
    # for the no-selected case). They are subsumed by the shared
    # deep gate, which additionally covers unpack, target-safe,
    # shortcut-safe, init-compat and the live manifest, all on an
    # F01 private copy. A non-backup candidate no longer passes.
    local selected="${1:-}" retain="${2:-0}"
    restore_backup_prevalidate "${ABOX_DIR}/backups" "$selected" "$retain"
}

core_upgrade_transaction_rollback() {
    [[ "${ABOX_CORE_UPGRADE_ACTIVE:-0}" == 1 ]] || return 0
    local backup="${ABOX_CORE_UPGRADE_BACKUP:-}" targets="${ABOX_CORE_UPGRADE_TARGETS:-}" srv core_tmp="${ABOX_CORE_UPGRADE_TMP:-}"
    # Disable recursive EXIT handling but retain backup/target/temp context until
    # the prior snapshot is actually restored and verified.
    ABOX_CORE_UPGRADE_ACTIVE=0
    ABOX_DIE_HOOK=''
    restore_core_upgrade_transaction_traps
    msg "${YELLOW}[!] Core upgrade failed or was interrupted; restoring the exact pre-upgrade snapshot.${NC}"
    # R5C16-03: verify the restore archive BEFORE any destructive step.
    # A missing or invalid backup must abort here, not after services
    # are stopped and core families force-removed (unrecoverable).
    # R15-09: the verified copy is retained (opt-in) and is the object
    # the restore consumes -- the shared backup must not be re-read after
    # the core is deleted. A pin from an earlier transaction is a
    # recovery bundle: refuse rather than overwrite it.
    if [[ -n "${ABOX_PREVALIDATE_WORK:-}" ]]; then
        if [[ -d "$ABOX_PREVALIDATE_WORK" ]]; then
            msg "${RED}[!] Core-upgrade rollback aborted: a retained recovery bundle already exists: ${ABOX_PREVALIDATE_WORK}; manual handling required.${NC}" >&2
            core_upgrade_transaction_set_status failed
            return 1
        fi
        ABOX_PREVALIDATE_WORK=''
    fi
    if ! core_upgrade_rollback_backup_valid "$backup" 1; then
        msg "${RED}[!] Core-upgrade rollback aborted: restore backup missing or invalid: ${backup:-missing}. No services stopped, no core families removed.${NC}" >&2
        core_upgrade_transaction_set_status failed
        return 1
    fi
    # The retained bundle is the restore source from here on. It must
    # be complete (archive present, not a symlink) before any destructive
    # step; a failed stop/remove/restore RETAINS it and names it, so the
    # operator can recover by hand. Only a successful restore deletes it.
    local _pinned_dir="$ABOX_PREVALIDATE_WORK"
    local _pinned_archive="$_pinned_dir/$(basename "$backup")"
    [[ -n "$_pinned_dir" && -f "$_pinned_archive" && ! -L "$_pinned_archive" ]] || { msg "${RED}[!] Core-upgrade rollback aborted: the retained recovery bundle is incomplete: ${_pinned_archive:-missing}.${NC}" >&2; core_upgrade_transaction_set_status failed; return 1; }
    if ! stop_all_managed_services >/dev/null 2>&1; then
        msg "${RED}[!] Core-upgrade rollback aborted: one or more managed services could not be confirmed stopped. Recovery bundle retained: $_pinned_archive${NC}" >&2
        core_upgrade_transaction_set_status failed
        return 1
    fi
    for srv in $targets; do
        case "$srv" in singbox) srv='sing-box' ;; esac
        if ! remove_core_family_force "$srv"; then
            msg "${RED}[!] Core-upgrade rollback aborted: unable to remove ${srv} safely. Recovery bundle retained: $_pinned_archive${NC}" >&2
            core_upgrade_transaction_set_status failed
            return 1
        fi
    done
    if ! restore_latest_backup_silent "$_pinned_dir" "$_pinned_archive"; then
        msg "${RED}[!] Core upgrade rollback failed: ${_pinned_archive}. Recovery bundle retained: ${_pinned_archive}${NC}" >&2
        core_upgrade_transaction_set_status failed
        return 1
    fi
    rm -rf -- "$_pinned_dir" || { msg "${RED}[!] Prior core state restored, but retained-bundle cleanup failed: $_pinned_dir${NC}" >&2; core_upgrade_transaction_set_status failed; return 1; }
    ABOX_PREVALIDATE_WORK=''
    if [[ -n "$core_tmp" ]]; then
        rm -rf -- "$core_tmp" || { msg "${RED}[!] Prior core state restored, but upgrade staging cleanup failed: $core_tmp${NC}" >&2; core_upgrade_transaction_set_status failed; return 1; }
    fi
    ABOX_CORE_UPGRADE_BACKUP=''
    ABOX_CORE_UPGRADE_TARGETS=''
    ABOX_CORE_UPGRADE_TMP=''
    core_upgrade_transaction_set_status ok
    return 0
}

core_upgrade_transaction_signal_abort() {
    local sig="$1" code=130
    [[ "$sig" == TERM ]] && code=143
    [[ "$sig" == HUP ]] && code=129
    core_upgrade_transaction_rollback
    exit "$code"
}

core_upgrade_transaction_exit_guard() {
    local rc="$1"
    if [[ "${ABOX_CORE_UPGRADE_ACTIVE:-0}" == 1 ]]; then core_upgrade_transaction_rollback; fi
    return "$rc"
}

install_core_upgrade_transaction_traps() {
    ABOX_CORE_TX_PREV_TRAP_EXIT=$(trap -p EXIT); [[ -n "$ABOX_CORE_TX_PREV_TRAP_EXIT" ]] || ABOX_CORE_TX_PREV_TRAP_EXIT='trap - EXIT'
    ABOX_CORE_TX_PREV_TRAP_INT=$(trap -p INT); [[ -n "$ABOX_CORE_TX_PREV_TRAP_INT" ]] || ABOX_CORE_TX_PREV_TRAP_INT='trap - INT'
    ABOX_CORE_TX_PREV_TRAP_TERM=$(trap -p TERM); [[ -n "$ABOX_CORE_TX_PREV_TRAP_TERM" ]] || ABOX_CORE_TX_PREV_TRAP_TERM='trap - TERM'
    ABOX_CORE_TX_PREV_TRAP_HUP=$(trap -p HUP); [[ -n "$ABOX_CORE_TX_PREV_TRAP_HUP" ]] || ABOX_CORE_TX_PREV_TRAP_HUP='trap - HUP'
    trap 'core_upgrade_transaction_exit_guard "$?"' EXIT
    trap 'core_upgrade_transaction_signal_abort INT' INT
    trap 'core_upgrade_transaction_signal_abort TERM' TERM
    trap 'core_upgrade_transaction_signal_abort HUP' HUP
}

begin_core_upgrade_transaction() {
    ABOX_LAST_BACKUP=''
    auto_backup_silent 'all-core atomic upgrade' "$ABOX_DIR/backups"
    [[ -n "$ABOX_LAST_BACKUP" && -f "$ABOX_LAST_BACKUP" ]] || die "$(tr_msg begin_core_upgrade_transaction_backup_failed)"
    ABOX_CORE_UPGRADE_BACKUP="$ABOX_LAST_BACKUP"
    ABOX_CORE_UPGRADE_TARGETS="$*"
    # M-11: the transaction is only PREPARED here (backup taken, nothing
    # modified yet). The die hook and traps stay disarmed until
    # core_upgrade_transaction_arm runs just before the atomic binary
    # install, so a precheck failure (download / version direction /
    # staged run -test) exits the subshell without stopping every
    # managed service for a rollback of nothing. Status stays
    # not-modified until armed; a backup failure above dies with the
    # hook still empty, so the parent reads not-started.
    core_upgrade_transaction_set_status not-modified
}

# M-11: arm a prepared core-upgrade transaction just before the atomic
# binary install. Only from here on may a die trigger the full-stack
# rollback; earlier failures exit with status not-modified and no
# rollback. No-op when no prepared transaction exists (an upgrade
# function called outside a transaction keeps its old behaviour).
core_upgrade_transaction_arm() {
    [[ -n "${ABOX_CORE_UPGRADE_BACKUP:-}" && -f "${ABOX_CORE_UPGRADE_BACKUP:-}" ]] || return 0
    [[ "${ABOX_CORE_UPGRADE_ACTIVE:-0}" == 1 ]] && return 0
    ABOX_CORE_UPGRADE_ACTIVE=1
    core_upgrade_transaction_set_status active
    ABOX_DIE_HOOK=core_upgrade_transaction_rollback
    install_core_upgrade_transaction_traps
}

commit_core_upgrade_transaction() {
    ABOX_CORE_UPGRADE_ACTIVE=0
    ABOX_CORE_UPGRADE_BACKUP=''
    ABOX_CORE_UPGRADE_TARGETS=''
    ABOX_CORE_UPGRADE_TMP=''
    ABOX_DIE_HOOK=''
    restore_core_upgrade_transaction_traps
}

# M-11: dispatch one core's upgrade-only step by tag (shared by the
# two core-upgrade loops so the per-core command cannot drift).
upgrade_core_only_by_tag() {
    case "$1" in
        xray) upgrade_xray_core_only ;;
        singbox) upgrade_singbox_core_only ;;
        hysteria) upgrade_hysteria_core_only ;;
        *) return 1 ;;
    esac
}

# M-11: shared per-core attempt runner for the two core-upgrade loops.
# Runs begin -> "$@" -> commit in a subshell; "$@" is the per-core
# upgrade step. The caller owns the RB status file (via
# ABOX_CORE_TX_RB_STATUS) and reads the outcome from it. Returns the
# subshell status.
core_upgrade_transaction_attempt() {
    local t="$1"; shift
    ( begin_core_upgrade_transaction "$t"
      "$@" || { core_upgrade_transaction_rollback; exit 1; }
      commit_core_upgrade_transaction )
}

# M-11: one try-latest attempt for a core: resolve the latest stable
# candidate, then run the core-only upgrade. Runs inside the attempt
# subshell, so a candidate-resolution die exits with status
# not-modified (nothing installed, no rollback).
try_latest_upgrade_one() {
    local t="$1" latest=''
    case "$t" in
        xray)
            latest=$(core_latest_stable_release_ref XTLS/Xray-core 2>/dev/null || core_release_mirror_version XTLS/Xray-core) || die "$(tr_msg tl_cand_xray)"
            msg "${YELLOW}$(tprintf tl_try_xray "$latest")${NC}"
            ABOX_TRY_LATEST_CORE_STABLE=1 upgrade_xray_core_only ;;
        singbox)
            latest=$(core_latest_stable_release_ref SagerNet/sing-box 2>/dev/null || core_release_mirror_version SagerNet/sing-box) || die "$(tr_msg tl_cand_sb)"
            msg "${YELLOW}$(tprintf tl_try_sb "$latest")${NC}"
            ABOX_TRY_LATEST_CORE_STABLE=1 upgrade_singbox_core_only ;;
        hysteria)
            latest=$(core_latest_stable_release_ref HyNetworks/hysteria 2>/dev/null || core_release_mirror_version HyNetworks/hysteria) || die "$(tr_msg tl_cand_hy)"
            msg "${YELLOW}$(tprintf tl_try_hy "$latest")${NC}"
            ABOX_TRY_LATEST_CORE_STABLE=1 upgrade_hysteria_core_only ;;
    esac
}

upgrade_current_cores_only() {
    clear
    init_system_environment
    load_optional_abox_env_or_die
    local targets=() answer t
    if abox_owns_service xray && { [[ -x /usr/local/bin/xray || -f /usr/local/etc/xray/config.json ]] || service_unit_exists xray; }; then targets+=(xray); fi
    if abox_owns_service sing-box && { [[ -x /usr/local/bin/sing-box || -f /etc/sing-box/config.json ]] || service_unit_exists sing-box; }; then targets+=(singbox); fi
    if abox_owns_service hysteria && { [[ -x /usr/local/bin/hysteria || -f /etc/hysteria/config.yaml ]] || service_unit_exists hysteria; }; then targets+=(hysteria); fi
    if (( ${#targets[@]} == 0 )); then
        msg "${YELLOW}[!] No A-Box-owned proxy cores detected; foreign same-name installations are intentionally ignored.${NC}"
        pause_return; return 0
    fi
    msg "${CYAN}======================================================================${NC}"
    msg "${BOLD}${GREEN}$(tr_msg upgrade_current_cores_only_title)${NC}"
    msg "${CYAN}======================================================================${NC}"
    msg "Detected A-Box-owned cores: ${targets[*]}"
    msg 'Each staged binary is executed and checked against the current config where supported before atomic replacement.'
    read -r -p 'Continue core-only upgrade? [Y/N]: ' answer || { msg "${YELLOW}$(tr_msg tl_cancelled)${NC}"; pause_return; return 0; }
    is_yes "$answer" || { msg "${YELLOW}$(tr_msg tl_cancelled)${NC}"; pause_return; return 0; }
    # Each core gets an independent transaction (begin → upgrade → commit)
    # inside a subshell, so a failure rolls back only that core.
    local failed_cores=() stopped=0 idx=0 rb_ok=0 rb_none=0 rb_bad=0
    for t in "${targets[@]}"; do
        msg "${CYAN}--- Upgrading $t (independent transaction) ---${NC}"
        # Each core runs in a subshell with its own transaction and
        # reports its rollback outcome through a status file, so the
        # parent never claims a rollback it did not observe.
        # S163: not-started -> active -> ok/failed; a missing or
        # unexpected state (e.g. SIGKILL mid-transaction) is unknown.
        local rb_status rb_state
        rb_status=$(mktemp) || { msg "${RED}[!] [$t] cannot create rollback status file; aborting core upgrades.${NC}"; return 1; }
        printf 'not-started\n' > "$rb_status" || { rm -f -- "$rb_status"; msg "${RED}[!] [$t] cannot create rollback status file; aborting core upgrades.${NC}"; return 1; }
        ABOX_CORE_TX_RB_STATUS="$rb_status"
        if core_upgrade_transaction_attempt "$t" upgrade_core_only_by_tag "$t"; then
            rm -f -- "$rb_status"
            msg "${GREEN}[$t] upgrade completed.${NC}"
        else
            rb_state=$(cat "$rb_status" 2>/dev/null || echo unknown)
            rm -f -- "$rb_status"
            case "$rb_state" in
                ok)
                    msg "${YELLOW}[!] [$t] upgrade failed and was rolled back independently; continuing.${NC}"
                    failed_cores+=("$t"); rb_ok=$((rb_ok + 1))
                    ;;
                not-started)
                    msg "${YELLOW}[!] [$t] upgrade failed before any change was made; no rollback needed; continuing.${NC}"
                    failed_cores+=("$t"); rb_none=$((rb_none + 1))
                    ;;
                not-modified)
                    msg "${YELLOW}[!] [$t] upgrade failed during precheck; installed binary was not changed, no rollback needed; continuing.${NC}"
                    failed_cores+=("$t"); rb_none=$((rb_none + 1))
                    ;;
                failed)
                    msg "${RED}[!] [$t] upgrade failed and its rollback FAILED; stopping further core upgrades.${NC}"
                    failed_cores+=("$t"); rb_bad=$((rb_bad + 1)); stopped=1
                    break
                    ;;
                *)
                    msg "${RED}[!] [$t] upgrade failed with rollback state unknown (interrupted mid-transaction); stopping further core upgrades.${NC}"
                    failed_cores+=("$t"); rb_bad=$((rb_bad + 1)); stopped=1
                    break
                    ;;
            esac
        fi
        idx=$((idx+1))
    done
    ABOX_CORE_TX_RB_STATUS=''
    if (( stopped == 1 )); then
        # R16C16-02: the unattempted cores are the targets after the
        # one that stopped the loop, not failed_cores (which holds
        # attempted cores, including the stopping one).
        local unattempted=() j
        for (( j=idx+1; j<${#targets[@]}; j++ )); do unattempted+=("${targets[j]}"); done
        msg "${YELLOW}[!] Core upgrade loop stopped early; failed cores: ${failed_cores[*]}; remaining cores not attempted: ${unattempted[*]}${NC}"
    elif (( ${#failed_cores[@]} > 0 )); then
        # R63a-L01: do not claim every failure was rolled back: only
        # the `ok` class was; `not-started`/`not-modified` needed no
        # rollback, and `failed`/unknown means rollback failed or
        # never reported. Summarise the three classes separately.
        msg "${YELLOW}[!] Completed with failures: ${failed_cores[*]} (rolled back: ${rb_ok}; no rollback needed: ${rb_none}; rollback failed/unknown: ${rb_bad})${NC}"
    else
        msg "${GREEN}All detected core-only upgrades completed. Node parameters were preserved.${NC}"
    fi
    pause_return
}

ota_and_geo_menu() {
    # Submenu loop: sub-functions return here; 0/Enter goes back to the parent menu.
    while true; do
    # P3: Clear stale choice so EOF (Ctrl-D) does not re-execute previous selection.
    ota_choice=''
    clear
    msg "${CYAN}======================================================================${NC}"
    case "${ABOX_LANG:-zh}" in
        en)
        msg "${BOLD}${GREEN}OTA, Geo and Core-only Upgrade${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC} Upgrade A-Box script"
        msg "${CYAN}2.${NC} Update Xray Loyalsoldier Geo resources now"
        msg "${CYAN}3.${NC} Upgrade current installed proxy cores only; preserve node parameters"
        msg "${CYAN}4.${NC} Show compatibility pin docs [U3]"
        msg "${CYAN}5.${NC} DANGER: try upstream latest cores (auto-rollback) [U3]"
        msg "${CYAN}0.${NC} Back"
        read -r -p 'Select [0-5]: ' ota_choice || return 0
        ota_choice=$(normalize_fa_ar_digits "$ota_choice")
            ;;
        ru)
        msg "${BOLD}${GREEN}OTA, Geo и обновление только ядер${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC} Обновить скрипт A-Box"
        msg "${CYAN}2.${NC} Обновить Geo-ресурсы Xray Loyalsoldier"
        msg "${CYAN}3.${NC} Обновить только установленные ядра; сохранить параметры узлов"
        msg "${CYAN}4.${NC} Показать документацию по фиксированным версиям [U3]"
        msg "${CYAN}5.${NC} ОПАСНО: попробовать последние ядра upstream (автооткат) [U3]"
        msg "${CYAN}0.${NC} Назад"
        read -r -p 'Выберите [0-5]: ' ota_choice || return 0
            ;;
        fa)
        msg "${BOLD}${GREEN}ارتقای OTA، Geo و فقط هسته${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC} به‌روزرسانی اسکریپت A-Box"
        msg "${CYAN}2.${NC} به‌روزرسانی منابع Geo Loyalsoldier برای Xray"
        msg "${CYAN}3.${NC} فقط هسته‌های نصب‌شده را ارتقا بده؛ پارامترهای نود حفظ شود"
        msg "${CYAN}4.${NC} نمایش مستندات نسخه‌های ثابت [U3]"
        msg "${CYAN}5.${NC} خطر: امتحان آخرین هسته‌های upstream (بازگشت خودکار) [U3]"
        msg "${CYAN}0.${NC} بازگشت"
        read -r -p 'انتخاب [0-5]: ' ota_choice || return 0
            ;;
        ja)
            msg "${BOLD}${GREEN}スクリプト OTA、Xray Geo データ、コアのみのアップグレード${NC}"
            msg "${CYAN}======================================================================${NC}"
            msg "${CYAN}1.${NC} A-Box スクリプトをアップグレード"
            msg "${CYAN}2.${NC} Xray Loyalsoldier Geo データを直ちに取得して更新"
            msg "${CYAN}3.${NC} インストール済みのプロトコルコアのみをアップグレード（ノードパラメーターはリセットしません）"
            msg "${CYAN}4.${NC} 互換性のある固定バージョンの説明を表示 [U3]"
            msg "${CYAN}5.${NC} 危険: upstream の latest コアを試します（失敗時は自動ロールバック）[U3]"
            msg "${CYAN}0.${NC} メインメニューに戻る"
            read -r -p '0～5 を選択してください: ' ota_choice || return 0
            ;;
        zh-tw)
        msg "${BOLD}${GREEN}指令碼 OTA、Xray Geo 與核心無損升級${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC} 升級 A-Box 核心指令碼"
        msg "${CYAN}2.${NC} 立即拉取並更新 Xray Loyalsoldier Geo 資源"
        msg "${CYAN}3.${NC} 僅升級當前已安裝協議核心，不重置節點引數"
        msg "${CYAN}4.${NC} 檢視相容釘扎說明 [U3]"
        msg "${CYAN}5.${NC} 危險：試用上游 latest 核心（失敗自動回滾）[U3]"
        msg "${CYAN}0.${NC} 返回主選單"
        read -r -p '請選擇 [0-5]: ' ota_choice || return 0
            ;;
        *)
        msg "${BOLD}${GREEN}脚本 OTA、Xray Geo 与核心无损升级${NC}"
        msg "${CYAN}======================================================================${NC}"
        msg "${CYAN}1.${NC} 升级 A-Box 核心脚本"
        msg "${CYAN}2.${NC} 立即拉取并更新 Xray Loyalsoldier Geo 资源"
        msg "${CYAN}3.${NC} 仅升级当前已安装协议核心，不重置节点参数"
        msg "${CYAN}4.${NC} 查看兼容钉扎说明 [U3]"
        msg "${CYAN}5.${NC} 危险：试用上游 latest 核心（失败自动回滚）[U3]"
        msg "${CYAN}0.${NC} 返回主菜单"
        read -r -p '请选择 [0-5]: ' ota_choice || return 0
            ;;
    esac
    # M-36: normalize Persian/Arabic digits for every language branch
    # (the en branch already normalizes at read time; this shared line
    # covers ru/fa/ja/zh-tw/zh). normalize_fa_ar_digits is idempotent.
    ota_choice=$(normalize_fa_ar_digits "$ota_choice")
    case "$ota_choice" in
        1) update_script ;;
        2) force_update_geo ;;
        3) upgrade_current_cores_only ;;
        4) show_core_pin_docs ;;
        5) try_latest_cores_danger ;;
        0) return 0 ;;
        *) msg "${RED}$(tr_msg invalid_input): $ota_choice${NC}"; sleep 1 ;;
    esac
    done
}


runtime_lock_proc_starttime() {
    local pid="$1"
    # F4: comm (field 2, in parentheses) may contain spaces, which
    # shifts whitespace-split fields so $22 is itrealvalue, not
    # starttime. Strip the pid and the whole parenthesized comm
    # (greedy .* reaches the LAST close paren, so a comm containing
    # parens is handled) and take field 20 of the remainder, i.e.
    # original field 22. No parenthesized comm -> no output.
    awk '{ if (sub(/^[^ ]+ \(.*\) /, "") == 0) exit 1; print $20 }' "/proc/${pid}/stat" 2>/dev/null
}

# R16-01: shared parent-dir safety check for runtime lock paths. A lock
# file/dir is only safe if its parent cannot be used to unlink and
# replace it: the parent must be a real directory owned root:root whose
# mode parses as octal, and group/other write permission is allowed only
# with the sticky bit set. Without the sticky rule, 0777/0770/0775 let
# any local user unlink the lock while an instance holds it and create a
# fresh root-owned lock on another inode, so two instances both pass
# their checks and enter the protected operation. Fail closed on every
# inspection failure.
runtime_lock_parent_dir_safe() {
    local parent="$1" mode
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ "$(stat -c %u:%g "$parent" 2>/dev/null || true)" == 0:0 ]] || return 1
    mode=$(stat -c %a "$parent" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{1,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 || (8#$mode & 8#1000) != 0 ))
}

open_runtime_flock_fd() {
    local uid gid mode fd_id path_id _flock_fd_owner
    # R16-01: the lock parent must pass the shared sticky rule (see
    # runtime_lock_parent_dir_safe); fchmod(0600) on the file cannot
    # stop a parent-write holder from unlinking the pathname.
    runtime_lock_parent_dir_safe "$(dirname "$LOCK_FILE")" || return 1
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || return 1
        uid=$(stat -c %u "$LOCK_FILE" 2>/dev/null) || return 1
        gid=$(stat -c %g "$LOCK_FILE" 2>/dev/null) || return 1
        mode=$(stat -c %a "$LOCK_FILE" 2>/dev/null) || return 1
        [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        # No permission check here: the legacy 0644 case is normalized
        # below by fchmod on the held fd, never by a path-based chmod
        # (a path chmod in the pre-open window follows a swapped link).
    else
        ( umask 077; set -o noclobber; : > "$LOCK_FILE" ) 2>/dev/null || return 1
    fi
    exec 9>>"$LOCK_FILE" || return 1
    # Post-open, pre-harden identity: the path must still name the very
    # inode fd 9 holds. stat WITHOUT -L reports a swapped-in symlink's
    # own inode, never its target's, so any swap is seen before
    # anything is hardened. No path is touched after this point.
    fd_id=$(stat -Lc '%d:%i' /proc/$$/fd/9 2>/dev/null) || { exec 9>&-; return 1; }
    path_id=$(stat -c '%d:%i' "$LOCK_FILE" 2>/dev/null) || { exec 9>&-; return 1; }
    [[ "$fd_id" == "$path_id" ]] || { exec 9>&-; return 1; }
    # Harden the HELD fd: fstat re-validates (regular file, root:root,
    # catching a pre-open regular-file swap), then fchown/fchmod on fd
    # 9 itself. A later swap cannot redirect this hardening anywhere.
    # Upgrade compatibility: older A-Box builds created the root-owned
    # regular lock file with the caller's default umask (commonly
    # 0644); the fchmod below normalizes that exact safe legacy case,
    # and an active older process is still detected by flock.
    # R14-F17-01: python3 may be absent before ensure_commands installs
    # it (same caveat as the fallback lock); refusing here broke
    # bootstrap on minimal systems that DO have flock. Without python3,
    # keep the bash-side re-validation of the HELD fd and skip only the
    # fchown/fchmod normalisation (a legacy 0644 lock file stays 0644
    # until a later python-equipped run normalises it).
    if command -v python3 >/dev/null 2>&1; then
    python3 -I - <<'PY_FLOCK_HARDEN' || { exec 9>&-; return 1; }
import os, stat
st = os.fstat(9)
if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0:
    raise SystemExit(1)
os.fchown(9, 0, 0)
os.fchmod(9, 0o600)
PY_FLOCK_HARDEN
    else
        # NOTE: do NOT use stat %F here: GNU stat reports an empty
        # regular file as 'regular empty file', which would fail a
        # 'regular file' comparison for this (always empty) lock file.
        [[ -f /proc/$$/fd/9 ]] || { exec 9>&-; return 1; }
        _flock_fd_owner=$(stat -Lc '%u:%g' /proc/$$/fd/9 2>/dev/null) || { exec 9>&-; return 1; }
        [[ "$_flock_fd_owner" == '0:0' ]] || { exec 9>&-; return 1; }
    fi
}

validate_inherited_flock_lock() {
    local fd_id path_id
    # R16-01: the inherited lock is only as safe as its parent: an
    # fd/path match alone does not prove nobody can unlink the
    # pathname and substitute another inode.
    runtime_lock_parent_dir_safe "$(dirname "$LOCK_FILE")" || return 1
    [[ -e /proc/$$/fd/9 && -e "$LOCK_FILE" ]] || return 1
    fd_id=$(stat -Lc '%d:%i' /proc/$$/fd/9 2>/dev/null) || return 1
    path_id=$(stat -Lc '%d:%i' "$LOCK_FILE" 2>/dev/null) || return 1
    [[ "$fd_id" == "$path_id" ]] || return 1
    flock -n 9 || return 1
}

validate_owned_fallback_runtime_lock() {
    local pid start uid gid mode
    [[ -d "$LOCK_FALLBACK_DIR" && ! -L "$LOCK_FALLBACK_DIR" ]] || return 1
    uid=$(stat -c %u "$LOCK_FALLBACK_DIR" 2>/dev/null) || return 1
    gid=$(stat -c %g "$LOCK_FALLBACK_DIR" 2>/dev/null) || return 1
    mode=$(stat -c %a "$LOCK_FALLBACK_DIR" 2>/dev/null) || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 )) || return 1
    [[ -f "$LOCK_FALLBACK_DIR/pid" && ! -L "$LOCK_FALLBACK_DIR/pid" && -f "$LOCK_FALLBACK_DIR/starttime" && ! -L "$LOCK_FALLBACK_DIR/starttime" ]] || return 1
    IFS= read -r pid < "$LOCK_FALLBACK_DIR/pid" || return 1
    IFS= read -r start < "$LOCK_FALLBACK_DIR/starttime" || return 1
    [[ -n "$start" && "$pid" == "$$" && "$start" == "$(runtime_lock_proc_starttime $$)" ]] || return 1
}

runtime_lock_cleanup() {
    # M-03 (Carbon audit): explicitly release the flock as well. A plain
    # close on process exit releases it, but an explicit unlock also
    # covers children that inherited a copy of fd 9.
    if [[ -e /proc/$$/fd/9 ]]; then
        flock -u 9 2>/dev/null || true
    fi
    if [[ "${ABOX_RUNTIME_LOCK_MODE:-}" == fallback ]] && validate_owned_fallback_runtime_lock; then
        rm -f -- "$LOCK_FALLBACK_DIR/pid" "$LOCK_FALLBACK_DIR/starttime" 2>/dev/null || true
        rmdir -- "$LOCK_FALLBACK_DIR" 2>/dev/null || true
    fi
}

fallback_runtime_lock_held() { # 0 = a live process holds the fallback lock
    # R16-02: tri-state. 0 = a live holder is proven; 1 = definitely no
    # live holder (dir absent, pid dead, or starttime mismatch, i.e. a
    # different process incarnation); 2 = holder state UNKNOWN, fail
    # closed. A failed /proc probe, an unreadable/missing/empty pid or
    # starttime, a non-numeric pid, a symlink dir, or a non-root-owned
    # dir proves nothing about absence, so all of them are 2, never 1.
    # (The old code returned 1 for every one of these, which the
    # flock-branch caller read as "no holder" and then took a second
    # lock.) An empty starttime is unknown too: a legitimate holder
    # always publishes a non-empty starttime (S159).
    local pid start actual
    [[ -e "$LOCK_FALLBACK_DIR" || -L "$LOCK_FALLBACK_DIR" ]] || return 1
    [[ -d "$LOCK_FALLBACK_DIR" && ! -L "$LOCK_FALLBACK_DIR" ]] || return 2
    [[ "$(stat -c %u:%g "$LOCK_FALLBACK_DIR" 2>/dev/null || true)" == 0:0 ]] || return 2
    IFS= read -r pid < "$LOCK_FALLBACK_DIR/pid" || return 2
    IFS= read -r start < "$LOCK_FALLBACK_DIR/starttime" || return 2
    [[ -n "$start" ]] || return 2
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    [[ -d "/proc/$pid" ]] || return 1
    actual=$(runtime_lock_proc_starttime "$pid" || true)
    [[ -n "$actual" ]] || return 2
    [[ "$actual" == "$start" ]]
}

acquire_fallback_runtime_lock() {
    # R16-03 (narrow variant, GPT-02): NO automatic reclamation. The old
    # complete/incomplete-metadata reclaim branches moved the canonical
    # dir aside with mv and could orphan a LIVE lock (17-F2): the mv is
    # not atomic with the metadata check, so interleaved reclaimers
    # could steal each other's live locks, and a creator SIGSTOPped
    # before writing its pid could later overwrite the new owner's
    # metadata. The exchange-and-rollback scheme was rejected for the
    # same reason (an interleaved exchange-back can rm -rf a live lock).
    # mkdir success is the only acquisition: an existing canonical dir
    # means another instance may own it, so refuse and say so. A crashed
    # instance's residue is recovered only by explicit manual removal
    # (rm -rf the fallback dir) or a reboot (/run is tmpfs); never
    # automatically. The kernel-lock tier (python fcntl on an inherited
    # fd) was verified working, but it is not made mandatory here:
    # python3 may be absent before ensure_commands installs it, and
    # refusing to run then would break bootstrap on minimal systems.
    # R16-01 parent rule (GPT-01(c)): the fallback dir's parent must
    # pass the same sticky check as the flock lock's parent.
    local _self_start _held_rc _fb_id _fb_rc _fb_umask
    runtime_lock_parent_dir_safe "$(dirname "$LOCK_FALLBACK_DIR")" || return 1
    if ! mkdir -m 700 "$LOCK_FALLBACK_DIR" 2>/dev/null; then
        # Best-effort diagnostic only (read-only classification):
        # live holder / stale residue / unknown. Never removes or moves
        # anything.
        _held_rc=0
        fallback_runtime_lock_held || _held_rc=$?
        case "$_held_rc" in
            0) printf '%s\n' "A-Box fallback lock is held by a live instance (pid $(cat "$LOCK_FALLBACK_DIR/pid" 2>/dev/null || true))." >&2 ;;
            1) printf '%s\n' "A-Box fallback lock dir already exists but no live holder was found; remove it manually if no instance is running: rm -rf -- $LOCK_FALLBACK_DIR" >&2 ;;
            *) printf '%s\n' "A-Box fallback lock dir already exists and its holder state could not be determined; refusing to proceed." >&2 ;;
        esac
        return 1
    fi
    chown root:root "$LOCK_FALLBACK_DIR" || { rmdir "$LOCK_FALLBACK_DIR" 2>/dev/null || true; return 1; }
    # H-09: save/restore the caller umask (bare umask 077 leaked). No
    # subshell wrapper: this function sets the global
    # ABOX_RUNTIME_LOCK_MODE on the success path below.
    _fb_umask=$(umask)
    umask 077
    # Identity pin: record the dir we just created; every later step
    # verifies it is still the same inode before touching it, and
    # cleanup below removes only our own dir.
    _fb_id=$(stat -Lc '%d:%i' "$LOCK_FALLBACK_DIR" 2>/dev/null) || { umask "$_fb_umask"; return 1; }
    _fb_rc=0
    # Noclobber metadata writes: a pre-existing pid/starttime file in
    # a dir we just created means the dir is not fresh; never
    # overwrite it.
    ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FALLBACK_DIR/pid" ) 2>/dev/null || _fb_rc=1
    if (( _fb_rc == 0 )); then
        # S159: capture starttime first and require it non-empty. The old
        # `printf ... "$(...)" > file || ...` tested printf's status, not
        # the /proc read's: a failed read wrote an empty line and the lock
        # was still granted with an empty starttime (which validate then
        # accepted, empty == empty, while liveness checks demand non-empty).
        _self_start=$(runtime_lock_proc_starttime $$) || _fb_rc=1
        [[ -n "$_self_start" ]] || _fb_rc=1
    fi
    if (( _fb_rc == 0 )); then
        ( set -o noclobber; printf '%s\n' "$_self_start" > "$LOCK_FALLBACK_DIR/starttime" ) 2>/dev/null || _fb_rc=1
    fi
    if (( _fb_rc == 0 )); then
        chmod 600 "$LOCK_FALLBACK_DIR/pid" "$LOCK_FALLBACK_DIR/starttime" || _fb_rc=1
        chown root:root "$LOCK_FALLBACK_DIR/pid" "$LOCK_FALLBACK_DIR/starttime" || _fb_rc=1
    fi
    if (( _fb_rc == 0 )); then
        # Final read-back verification: the published metadata must be
        # ours, in the dir we created. Anything else means the dir was
        # replaced under us; refuse without touching it.
        [[ "$(cat "$LOCK_FALLBACK_DIR/pid" 2>/dev/null || true)" == "$$" ]] || _fb_rc=1
        [[ "$(cat "$LOCK_FALLBACK_DIR/starttime" 2>/dev/null || true)" == "$_self_start" ]] || _fb_rc=1
        [[ "$(stat -Lc '%d:%i' "$LOCK_FALLBACK_DIR" 2>/dev/null || true)" == "$_fb_id" ]] || _fb_rc=1
    fi
    if (( _fb_rc != 0 )); then
        if [[ "$(stat -Lc '%d:%i' "$LOCK_FALLBACK_DIR" 2>/dev/null || true)" == "$_fb_id" ]]; then
            rm -f -- "$LOCK_FALLBACK_DIR/pid" "$LOCK_FALLBACK_DIR/starttime" 2>/dev/null || true
            rmdir -- "$LOCK_FALLBACK_DIR" 2>/dev/null || true
        fi
        umask "$_fb_umask"
        return 1
    fi
    umask "$_fb_umask"
    ABOX_RUNTIME_LOCK_MODE='fallback'
}


# R15-F17-01: probe whether a flock holder exists on LOCK_FILE without
# the flock binary, via python fcntl (same flock(2) lock the flock binary
# takes). Tri-state by exit code, mirroring fallback_runtime_lock_held:
# 0 = no holder (lock free), 10 = a live holder, 20 = unknown (fail closed).
# Any other exit code (e.g. python startup failure, rc 1) is unknown too.
# The file is opened O_RDONLY|O_NOFOLLOW and never created or truncated;
# an absent file means no holder can exist on that path (a holder on an
# unlinked inode is indistinguishable here, exactly as in the flock branch,
# which creates the file when missing). The probe briefly takes the lock
# itself and releases it by closing the fd.
# R16-F17-01: top-level on purpose — acquire_runtime_lock calls
# this probe from a fresh process that never ran the upgrade
# function; a nested definition is only registered when the outer
# function runs, so the no-flock fallback path always died 127.
probe_runtime_flock_holder() {
    python3 -I - "$LOCK_FILE" <<'PY_FLOCK_PROBE'
import fcntl
import os
import stat
import sys

FREE, HELD, UNKNOWN = 0, 10, 20


def probe(path):
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return FREE
    if not stat.S_ISREG(before.st_mode):
        return UNKNOWN
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return UNKNOWN
    try:
        opened = os.fstat(fd)
        if (not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
            return UNKNOWN
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return HELD
        after = os.lstat(path)
        if (not stat.S_ISREG(after.st_mode)
                or (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)):
            return UNKNOWN
        return FREE
    finally:
        os.close(fd)


try:
    sys.exit(probe(sys.argv[1]))
except Exception:
    sys.exit(UNKNOWN)
PY_FLOCK_PROBE
}

upgrade_runtime_lock_to_flock_if_possible() {
# After ensure_commands may have installed flock, promote a session that
    # started on LOCK_FALLBACK_DIR onto LOCK_FILE so helpers and main share one object.
    [[ "${ABOX_RUNTIME_LOCK_MODE:-}" == fallback ]] || return 0
    command -v flock >/dev/null 2>&1 || return 0
    _abox_flock_w_ok || return 0
    open_runtime_flock_fd || return 1
    flock -n 9 || {
        # Another process already holds the flock; keep fallback ownership for cleanup.
        eval "exec 9>&-" 2>/dev/null || true
        return 1
    }
    if validate_owned_fallback_runtime_lock; then
        rm -f -- "$LOCK_FALLBACK_DIR/pid" "$LOCK_FALLBACK_DIR/starttime" 2>/dev/null || true
        rmdir -- "$LOCK_FALLBACK_DIR" 2>/dev/null || true
    fi
    ABOX_RUNTIME_LOCK_MODE='flock'
}

acquire_runtime_lock() {
    if [[ "${ABOX_INHERITED_LOCK_MODE:-}" == flock ]]; then
        command -v flock >/dev/null 2>&1 || die "$(tr_msg acquire_runtime_lock_inherited_flock_unverifiable)"
        validate_inherited_flock_lock || die "$(tr_msg acquire_runtime_lock_inherited_lock_invalid)"
        ABOX_RUNTIME_LOCK_MODE='flock'
    elif [[ "${ABOX_INHERITED_LOCK_MODE:-}" == fallback ]]; then
        validate_owned_fallback_runtime_lock || die "$(tr_msg acquire_runtime_lock_inherited_fallback_invalid)"
        ABOX_RUNTIME_LOCK_MODE='fallback'
    elif command -v flock >/dev/null 2>&1 && _abox_flock_w_ok; then
        # M-15(2): a flock without -w (BusyBox) cannot serve the
        # flock -w 15 relock in pause_return/main_loop; fall through
        # to the fallback lock instead of dying at the first pause.
        # U133: a live fallback lock means another instance is running even
        # though the flock is free; never hold two lock objects at once.
        # R16-02: fallback_runtime_lock_held is tri-state: 0 live holder,
        # 1 definitely no holder, 2 holder state unknown. Only 1 may
        # proceed; unknown refuses (fail closed) instead of being read
        # as "no holder" and taking a second lock.
        local _fb_held_rc=0
        fallback_runtime_lock_held || _fb_held_rc=$?
        case "$_fb_held_rc" in
            0) die "$(tr_msg acquire_runtime_lock_another_instance_running)" ;;
            1) : ;;
            *) die "$(tr_msg acquire_runtime_lock_fallback_owner_unknown)" ;;
        esac
        open_runtime_flock_fd || die "$(tr_msg acquire_runtime_lock_lock_path_unsafe)"
        flock -n 9 || die "$(tr_msg acquire_runtime_lock_another_instance_running)"
        # 08e-H01 (H19): post-acquire recheck of the fallback lock. The
        # pre-check above and the flock can straddle a scheduling gap in
        # which another instance takes the fallback lock; without this
        # recheck both instances hold different lock objects at once
        # (the fallback branch's R6C17-01 recheck is the mirror image).
        # A live fallback holder — or an unknown holder state — releases
        # the flock and refuses. The EXIT trap is installed only after
        # this branch, so the release here must be explicit.
        local _fb_recheck_rc=0
        fallback_runtime_lock_held || _fb_recheck_rc=$?
        case "$_fb_recheck_rc" in
            1) : ;;
            0) eval "exec 9>&-" 2>/dev/null || true
               die "$(tr_msg acquire_runtime_lock_another_instance_running)" ;;
            *) eval "exec 9>&-" 2>/dev/null || true
               die "$(tr_msg acquire_runtime_lock_fallback_owner_unknown)" ;;
        esac
        ABOX_RUNTIME_LOCK_MODE='flock'
    else
        acquire_fallback_runtime_lock || die "$(tr_msg acquire_runtime_lock_another_instance_no_flock)"
        # R6C17-01: post-publish recheck. Another process may have
        # promoted to flock while this one was scheduled out; holding
        # fallback alongside its flock is double hold. If flock is now
        # available, promotion must succeed; if it is contended, the
        # flock holder is live: release our fallback and refuse. (The
        # EXIT cleanup trap is only installed after this branch, so the
        # release here must be explicit.)
        # R15-F17-01: the reverse check is unconditional now. When flock
        # is unavailable the old code skipped the check entirely and ran on
        # the fallback lock next to a live flock holder (flock binary
        # removed/replaced after the holder took it, or two processes with
        # different PATHs). Without the flock binary, probe the lock file
        # with python fcntl instead; when neither verifier exists the
        # holder state is unknown and this refuses (fail closed, same
        # tri-state discipline as the flock branch above).
        # 08e-H02 (H20): promotion is only attempted when flock can
        # actually take a timed lock. When flock exists but lacks -w
        # (BusyBox), upgrade_runtime_lock_to_flock_if_possible returns 0
        # for "stayed on fallback", which the old bare `command -v flock`
        # test misread as "promotion done" and skipped the reverse probe
        # below entirely — a live flock holder was then never verified.
        # Route that combination to the probe instead. (The upgrade
        # function's own return-0 on missing -w is kept: the
        # ensure_commands caller treats it as "stay on fallback", not
        # as an error.)
        if command -v flock >/dev/null 2>&1 && _abox_flock_w_ok; then
            upgrade_runtime_lock_to_flock_if_possible || { runtime_lock_cleanup; die "$(tr_msg acquire_runtime_lock_another_instance_after_fallback)"; }
        else
            local _flock_probe_rc=0
            if ! command -v python3 >/dev/null 2>&1; then
                runtime_lock_cleanup; die "$(tr_msg acquire_runtime_lock_flock_unverifiable)"
            fi
            probe_runtime_flock_holder || _flock_probe_rc=$?
            case "$_flock_probe_rc" in
                0) : ;;
                10) runtime_lock_cleanup; die "$(tr_msg acquire_runtime_lock_flock_holder)" ;;
                *) runtime_lock_cleanup; die "$(tr_msg acquire_runtime_lock_flock_unverifiable)" ;;
            esac
        fi
    fi
    unset ABOX_INHERITED_LOCK_MODE
    trap 'runtime_lock_cleanup' EXIT
    trap 'runtime_lock_cleanup; exit 129' HUP
    trap 'runtime_lock_cleanup; exit 130' INT
    trap 'runtime_lock_cleanup; exit 143' TERM
}

enter_runtime() {
    if [[ $EUID -ne 0 ]]; then
        if [[ -f "$0" && -r "$0" && "$0" != 'bash' && "$0" != '-bash' ]] && command -v sudo >/dev/null 2>&1; then
            exec sudo bash "$0" "$@"
        fi
        die "$(tr_msg enter_runtime_pipe_no_sudo)"
    fi
    # Force-heal is call-stack only; never honor a caller-exported env toggle.
    unset ABOX_HEAL_MISSING_MANIFEST 2>/dev/null || true
    # Die-hooks are installed only by in-script transactions; ignore ambient export.
    unset ABOX_DIE_HOOK 2>/dev/null || true
    # A-leg (TTY guard i18n): resolve the language BEFORE the TTY guard.
    # detect_lang() honors --lang (ABOX_LANG_OVERRIDE), then ABOX_LANG,
    # then LANG_FILE; need_interactive_tty() dies with tr_msg tp_tty_menu /
    # tp_tty_open, so calling it first left ABOX_LANG at the 'zh' default
    # and the refusal was always Chinese regardless of --lang / LANG_FILE.
    detect_lang
    need_interactive_tty
    mkdir -p /var/run || die "$(tr_msg enter_runtime_var_run_failed)"
    ensure_abox_dir_owned "$ABOX_DIR"
    acquire_runtime_lock
    # Registry rewrites (default-name normalization) must run under
    # the runtime lock, not before it.
    users_normalize_all_default_names >/dev/null 2>&1 || true
    initial_language_select
}

expected_managed_services() {
    # M-06: a missing .env is a legitimate empty stack (pure standalone
    # deployments have none), not unreadable state. Only load when the
    # file exists; a present-but-corrupt file must still fail (return 1).
    if [[ -e "$ABOX_ENV" || -L "$ABOX_ENV" ]]; then
        load_abox_env "$ABOX_ENV" || return 1
    else
        clear_abox_env_vars
    fi
    local -a _svcs=()
    case "${CORE:-}" in
        xray) _svcs+=(xray); [[ "${MODE:-}" == *ALL* ]] && _svcs+=(hysteria) ;;
        singbox) _svcs+=(sing-box) ;;
        hysteria) _svcs+=(hysteria) ;;
        # R26-H-NF-04: no main pair (both-empty after a clear-all) is a
        # legitimate undeployed state, not unreadable state: fall through
        # to the owned-services mirror below. The env has already passed
        # validate_abox_env_semantics inside load_abox_env, so a
        # half-present or corrupt pair cannot reach this branch.
        *) : ;;
    esac
    # R16-04: the main .env CORE/MODE pair is not the whole managed
    # stack. A-Box-owned auxiliary cores deployed outside the main pair
    # (e.g. a toolbox-deployed sing-box SOCKS5/Trojan landing next to
    # a CORE=xray main) are managed too: --stop/--start and the traffic
    # unblock path must cover them, or they keep proxying while the
    # command announces the whole managed stack stopped/started. Mirror
    # expected_service_list (traffic-monitor side): main set first,
    # then every additional owned service from the fixed live slots,
    # deduplicated; ownership is gated by abox_owns_service, never by
    # unit existence alone. xray-latest is retired and is never added
    # to either direction. The traffic-block side already stops the
    # whole owned set (stop_all_owned_services fallback), so widening
    # the unblock/start side to match it is the consistent behavior.
    local _srv _s _dup
    for _srv in xray sing-box hysteria; do
        _dup=0
        for _s in "${_svcs[@]}"; do
            if [[ "$_s" == "$_srv" ]]; then _dup=1; break; fi
        done
        (( _dup == 1 )) && continue
        abox_owns_service "$_srv" 2>/dev/null && _svcs+=("$_srv")
    done
    printf '%s\n' "${_svcs[@]}"
    return 0
}

prepare_noninteractive_file_operation() {
    # L12 (TTY guard i18n, same root cause as the A-leg enter_runtime
    # fix): resolve the language BEFORE any tr_msg use. The top-level
    # ABOX_LANG='zh' init runs before main() dispatches, so without
    # detect_lang() every message on these non-interactive CLI paths
    # (--export-backup-key / --convert-legacy-backup /
    # --xray-config-autorecover / --sni-test) stayed zh even when a
    # language was saved in LANG_FILE.
    detect_lang
    [[ $EUID -eq 0 ]] || die "$(tr_msg prepare_noninteractive_file_operation_root_required)"
    mkdir -p /run || die "$(tr_msg prepare_noninteractive_file_operation_run_failed)"
    ensure_abox_dir_owned "$ABOX_DIR"
    acquire_runtime_lock
}

prepare_noninteractive_service_control() {
    [[ $EUID -eq 0 ]] || die "$(tr_msg prepare_noninteractive_service_control_root_required)"
    mkdir -p /var/run || die "$(tr_msg prepare_noninteractive_service_control_var_run_failed)"
    ensure_abox_dir_owned "$ABOX_DIR"
    acquire_runtime_lock
    if systemd_available; then INIT_SYS='systemd'; elif command -v rc-service >/dev/null 2>&1; then INIT_SYS='openrc'; else die "$(tr_msg prepare_noninteractive_service_control_no_init)"; fi
}

# BUG-28: hoisted from manual_stop_managed_stack()/manual_start_managed_stack().
# $1=changed_pre $2=changed_expected (transaction state files).
__abox_service_tx_rollback() {
    local changed_pre="$1" changed_expected="$2"
    local _tx_pre_keys='' _tx_exp_keys='' _tx_last_pre='' _tx_pre_minus_last=''
    # R10-F17-2 (A'): an empty pre journal with a non-empty expected
    # journal is corrupt input, not "nothing changed". A missing or
    # empty pre with an empty expected journal means nothing changed.
    if [[ ! -s "$changed_pre" ]]; then
        [[ -s "$changed_expected" ]] && return 1
        return 0
    fi
    # A missing/unreadable expected journal is still a hard failure;
    # a legally empty expected file (zero records: the first pre
    # append raced the signal) enters the A' set check below.
    [[ -f "$changed_expected" && ! -L "$changed_expected" ]] || return 1
    # R16-05: the old code skipped restore only when EVERY registered
    # service was still at its pre-state, then handed ALL registrations
    # to the strict expected-state preflight; one changed service made
    # the unchanged services (still at pre-state, not expected-state)
    # fail the whole rollback (return 2), leaving the changed service
    # changed. Restore PER SERVICE instead: a service still at its
    # pre-state needs no restore; only a changed service goes through
    # the strict per-service restore of its own pre/expected pair.
    # (The old all-unchanged shortcut is subsumed: every service is
    # skipped, so the loop below returns 0 silently.)
    # Safeguard 1: validate the complete input journals BEFORE
    # restoring anything (valid rows, unique keys). The service sets
    # must be identical, or expected must equal pre minus exactly the
    # last pre record (R10-F17-2 A': the trailing service whose pre
    # append landed but whose expected append did not). A service
    # with no expected record is never restored; any other mismatch
    # is refused before any restore. The "no partial restore ever"
    # promise no longer holds for that one trailing-item shape.
    validate_services_state_file "$changed_pre" || return 1
    validate_services_state_file "$changed_expected" || return 1
    _tx_pre_keys=$(awk -F'|' 'NF {print $1}' "$changed_pre" | LC_ALL=C sort) || return 1
    _tx_exp_keys=$(awk -F'|' 'NF {print $1}' "$changed_expected" | LC_ALL=C sort) || return 1
    if [[ "$_tx_pre_keys" != "$_tx_exp_keys" ]]; then
        _tx_last_pre=$(awk -F'|' 'NF {k=$1} END {print k}' "$changed_pre") || return 1
        [[ -n "$_tx_last_pre" ]] || return 1
        _tx_pre_minus_last=$(awk -F'|' -v last="$_tx_last_pre" 'NF && $1 != last {print $1}' "$changed_pre" | LC_ALL=C sort) || return 1
        [[ "$_tx_pre_minus_last" == "$_tx_exp_keys" ]] || return 1
    fi
    local _rb_srv _rb_pre _rb_cur _rb_exp _rb_mid _rb_pre_srv _rb_pre_active _rb_pre_enabled _rb_failed=() _rb_conflict=0 _rb_other=0 _rb_txd _rb_sp _rb_se _rb_srv_rc _rb_umask
    _rb_umask=$(umask)
    umask 077
    while IFS='|' read -r _rb_srv _ _ || [[ -n "$_rb_srv" ]]; do
        [[ -n "$_rb_srv" ]] || continue
        _rb_pre=$(awk -F'|' -v target="$_rb_srv" '$1 == target {print; found=1; exit} END {if (!found) exit 1}' "$changed_pre") || { _rb_other=1; _rb_failed+=("$_rb_srv"); continue; }
        _rb_cur=$(managed_service_state_value "$_rb_srv" 2>/dev/null) || { _rb_other=1; _rb_failed+=("$_rb_srv"); continue; }
        [[ "$_rb_cur" == "$_rb_pre" ]] && continue
        # F17-1: a changed service is restored only when its live state
        # is exactly a step-prefix of this transaction's own step:
        # stop-prefix (srv|0|<pre-enabled>) towards srv|0|disabled, or
        # start-prefix (srv|<pre-active>|enabled) towards srv|1|enabled.
        # Any other shape is a conflict: record it and move on to the
        # other services (never blocks them). The temp expected file
        # below then holds the one frozen live observation, still
        # re-checked by the strict preflight.
        _rb_exp=$(awk -F'|' -v target="$_rb_srv" '$1 == target {print; found=1; exit} END {if (!found) exit 1}' "$changed_expected") || { _rb_other=1; _rb_failed+=("$_rb_srv"); continue; }
        _rb_mid=''
        if [[ "$_rb_cur" != "$_rb_exp" ]]; then
            IFS='|' read -r _rb_pre_srv _rb_pre_active _rb_pre_enabled <<< "$_rb_pre"
            if [[ "$_rb_exp" == "$_rb_srv|0|disabled" ]]; then
                _rb_mid="$_rb_srv|0|$_rb_pre_enabled"
            elif [[ "$_rb_exp" == "$_rb_srv|1|enabled" ]]; then
                _rb_mid="$_rb_srv|$_rb_pre_active|enabled"
            fi
            if [[ -z "$_rb_mid" || "$_rb_cur" != "$_rb_mid" ]]; then
                _rb_conflict=1; _rb_failed+=("$_rb_srv"); continue
            fi
        fi
        # Changed: strict per-service restore of this service's own
        # pre/expected pair. Singleton journals live in a fresh private
        # temp dir (0700 root:root, files 0600 root:root); every
        # creation/write/ownership/permission step is checked, and the
        # temp dir is always removed afterwards. A query failure above
        # records the service as failed and moves on (never blocks the
        # other services); a conflict/restore failure is recorded the
        # same way. The caller's original tx journals are untouched, so
        # recovery information is preserved on failure.
        # F17-1: the exemption above is a whitelist, not a shape proof:
        # only the two step-prefixes of this transaction's own step are
        # accepted, and the temp expected file holds the one frozen live
        # observation, still re-checked by the strict preflight. An
        # indistinguishable foreign operation with the same shape (e.g.
        # an admin stop-only) cannot be told apart from P/E/L alone.
        _rb_txd=$(mktemp -d /run/A-Box-service-tx-rollback.XXXXXX) || { _rb_other=1; _rb_failed+=("$_rb_srv"); continue; }
        if ! chmod 700 "$_rb_txd" || { [[ $EUID -eq 0 ]] && ! chown root:root "$_rb_txd"; }; then rm -rf -- "$_rb_txd" 2>/dev/null || true; _rb_other=1; _rb_failed+=("$_rb_srv"); continue; fi
        _rb_sp="$_rb_txd/pre.state"; _rb_se="$_rb_txd/expected.state"
        if ! printf '%s\n' "$_rb_pre" > "$_rb_sp" || ! printf '%s\n' "$_rb_cur" > "$_rb_se"; then rm -rf -- "$_rb_txd" 2>/dev/null || true; _rb_other=1; _rb_failed+=("$_rb_srv"); continue; fi
        if ! chmod 600 "$_rb_sp" "$_rb_se" || { [[ $EUID -eq 0 ]] && ! chown root:root "$_rb_sp" "$_rb_se"; }; then rm -rf -- "$_rb_txd" 2>/dev/null || true; _rb_other=1; _rb_failed+=("$_rb_srv"); continue; fi
        restore_managed_service_state "$_rb_sp" "$_rb_se"
        _rb_srv_rc=$?
        rm -rf -- "$_rb_txd" 2>/dev/null || true
        if (( _rb_srv_rc != 0 )); then
            _rb_failed+=("$_rb_srv")
            if (( _rb_srv_rc == 2 )); then _rb_conflict=1; else _rb_other=1; fi
        fi
    done < "$changed_pre"
    umask "$_rb_umask"
    if (( ${#_rb_failed[@]} == 0 )); then
        return 0
    fi
    printf '%s\n' "A-Box service tx rollback incomplete; failed services: ${_rb_failed[*]}" >&2
    # Preserve status 2 for a conflict-only outcome (callers may
    # distinguish it); any other failure kind aggregates to 1.
    if (( _rb_conflict == 1 && _rb_other == 0 )); then
        return 2
    fi
    return 1
}
# S161: trap/failure-path wrapper: restore block period + desired state
# + service state together, and report any step failure. The signal
# trap previously restored services only, leaving a committed desired
# state / cleared block period behind on a rolled-back stack.
# $1=tx_dir (holds previous.state, block-present.state,
# previous-block.state, changed-pre.state, changed-expected.state).
# Never dies (trap context); returns nonzero if any step failed.
__abox_service_tx_rollback_all() {
    local tx_dir="$1" _w_rc=0 _w_prev='' _w_flag='' _w_block=''
    if [[ -f "$tx_dir/block-present.state" && ! -L "$tx_dir/block-present.state" ]]; then
        if IFS= read -r _w_flag < "$tx_dir/block-present.state" 2>/dev/null; then
            if [[ "$_w_flag" == 1 ]]; then
                if IFS= read -r _w_block < "$tx_dir/previous-block.state" 2>/dev/null; then
                    set_traffic_block_period "$_w_block" >/dev/null 2>&1 || { msg "${RED}[!] service tx rollback: traffic block period restore failed.${NC}" >&2; _w_rc=1; }
                else
                    msg "${RED}[!] service tx rollback: previous block period unreadable.${NC}" >&2; _w_rc=1
                fi
            elif [[ "$_w_flag" == 0 ]]; then
                clear_traffic_block_period >/dev/null 2>&1 || { msg "${RED}[!] service tx rollback: traffic block period clear failed.${NC}" >&2; _w_rc=1; }
            else
                msg "${RED}[!] service tx rollback: block-present state unreadable.${NC}" >&2; _w_rc=1
            fi
        else
            msg "${RED}[!] service tx rollback: block-present state unreadable.${NC}" >&2; _w_rc=1
        fi
    fi
    if [[ -f "$tx_dir/previous.state" && ! -L "$tx_dir/previous.state" ]]; then
        if IFS= read -r _w_prev < "$tx_dir/previous.state" 2>/dev/null && [[ -n "$_w_prev" ]]; then
            set_desired_state "$_w_prev" >/dev/null 2>&1 || { msg "${RED}[!] service tx rollback: desired state restore failed.${NC}" >&2; _w_rc=1; }
        else
            msg "${RED}[!] service tx rollback: previous desired state unreadable.${NC}" >&2; _w_rc=1
        fi
    else
        msg "${RED}[!] service tx rollback: previous desired state missing.${NC}" >&2; _w_rc=1
    fi
    __abox_service_tx_rollback "$tx_dir/changed-pre.state" "$tx_dir/changed-expected.state" || { msg "${RED}[!] service tx rollback: service state restore failed.${NC}" >&2; _w_rc=1; }
    return "$_w_rc"
}
manual_stop_managed_stack() {
    local srv failed=0 services previous_state pre_state changed_pre changed_expected tx_dir before after active enabled
    prepare_noninteractive_service_control
    services=$(expected_managed_services) || die "$(tr_msg manual_stop_managed_stack_state_unreadable)"
    previous_state=$(get_desired_state) || die "$(tr_msg manual_stop_managed_stack_desired_state_unreadable)"
    tx_dir=$(mktemp -d /run/A-Box-service-tx.XXXXXX) || die "$(tr_msg manual_stop_managed_stack_tx_dir_fail)"
    chmod 700 "$tx_dir" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_stop_managed_stack_tx_dir_perm_fail)"; }
    pre_state="$tx_dir/pre.state"; changed_pre="$tx_dir/changed-pre.state"; changed_expected="$tx_dir/changed-expected.state"
    capture_managed_service_state "$pre_state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_stop_managed_stack_snapshot_fail)"; }
    : > "$changed_pre"; : > "$changed_expected"
    # S161: persist the pre-transaction desired state for the trap
    # wrapper: a signal after commit must restore it, not leave the
    # committed value behind on a rolled-back stack.
    printf '%s\n' "$previous_state" > "$tx_dir/previous.state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_stop_managed_stack_prev_state_save_fail)"; }
    # U232: a signal mid-transaction must roll the service changes
    # back, not just clean the runtime lock. These replace
    # acquire_runtime_lock's signal traps for the transaction window;
    # they are restored after commit below.
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 129' HUP
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 130' INT
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 143' TERM

    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        before=$(managed_service_state_value "$srv" 2>/dev/null) || { failed=1; break; }
        IFS='|' read -r _ active enabled <<< "$before"
        [[ "$active" == 0 && "$enabled" == disabled ]] && continue
        # S160: register BEFORE mutating (traffic-flow precedent). A
        # signal landing mid-mutation must find the service in the
        # transaction record, or the trap rollback skips it entirely.
        append_managed_service_state_entry "$pre_state" "$changed_pre" "$srv" || { failed=1; break; }
        printf '%s\n' "$srv|0|disabled" >> "$changed_expected" || { failed=1; break; }
        stop_abox_service "$srv" || failed=1
        after=$(managed_service_state_value "$srv" 2>/dev/null || true)
        [[ "$after" == "$srv|0|disabled" ]] || failed=1
        (( failed == 0 )) || break
    done <<< "$services"

    if (( failed != 0 )); then
        if ! __abox_service_tx_rollback_all "$tx_dir"; then printf '%s\n' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; else trap - HUP INT TERM; rm -rf -- "$tx_dir"; fi
        die "$(tr_msg manual_stop_managed_stack_stop_commit_fail)"
    fi
    set_desired_state MANUAL_STOPPED || {
        if ! __abox_service_tx_rollback_all "$tx_dir"; then printf '%s\n' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; else trap - HUP INT TERM; rm -rf -- "$tx_dir"; fi
        die "$(tr_msg manual_stop_managed_stack_submit_fail)"
    }
    # U232: transaction committed; restore the lock traps exactly.
    trap 'runtime_lock_cleanup; exit 129' HUP
    trap 'runtime_lock_cleanup; exit 130' INT
    trap 'runtime_lock_cleanup; exit 143' TERM
    rm -rf -- "$tx_dir" || die "$(tr_msg manual_stop_managed_stack_tx_cleanup_fail)"
    printf 'A-Box managed stack stopped; Intent=MANUAL_STOPPED\n'
}

manual_start_managed_stack() {
    local srv failed=0 services previous_state previous_block_period='' block_state_present=0 before after active enabled tx_dir
    prepare_noninteractive_service_control
    services=$(expected_managed_services) || die "$(tr_msg manual_start_managed_stack_state_unreadable)"
    previous_state=$(get_desired_state) || die "$(tr_msg manual_start_managed_stack_desired_state_unreadable)"
    if [[ -e "$ABOX_TRAFFIC_BLOCK_STATE" || -L "$ABOX_TRAFFIC_BLOCK_STATE" ]]; then
        previous_block_period=$(get_traffic_block_period) || die "$(tr_msg manual_start_managed_stack_block_period_unreadable)"
        block_state_present=1
    fi
    tx_dir=$(mktemp -d /run/A-Box-service-tx.XXXXXX) || die "$(tr_msg manual_start_managed_stack_tx_dir_fail)"
    chmod 700 "$tx_dir" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_start_managed_stack_tx_dir_perm_fail)"; }
    local pre_state="$tx_dir/pre.state" changed_pre="$tx_dir/changed-pre.state" changed_expected="$tx_dir/changed-expected.state"
    capture_managed_service_state "$pre_state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_start_managed_stack_snapshot_fail)"; }
    : > "$changed_pre"; : > "$changed_expected"
    # S161: persist pre-transaction desired state + block period for
    # the trap wrapper (see stop flow).
    printf '%s\n' "$previous_state" > "$tx_dir/previous.state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_start_managed_stack_prev_state_save_fail)"; }
    printf '%s\n' "$block_state_present" > "$tx_dir/block-present.state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_start_managed_stack_block_flag_save_fail)"; }
    printf '%s\n' "$previous_block_period" > "$tx_dir/previous-block.state" || { rm -rf -- "$tx_dir"; die "$(tr_msg manual_start_managed_stack_block_period_save_fail)"; }
    # U232: a signal mid-transaction must roll the service changes
    # back, not just clean the runtime lock. These replace
    # acquire_runtime_lock's signal traps for the transaction window;
    # they are restored after commit below.
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 129' HUP
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 130' INT
    trap '__abox_service_tx_rollback_all "$tx_dir" >/dev/null 2>&1 || printf '\''%s\n'\'' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; runtime_lock_cleanup; exit 143' TERM

    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        abox_owns_service "$srv" || { failed=1; break; }
        before=$(managed_service_state_value "$srv" 2>/dev/null) || { failed=1; break; }
        IFS='|' read -r _ active enabled <<< "$before"
        { [[ "$active" == 1 && "$enabled" == enabled ]] || [[ "$active" == 1 && "$enabled" == enabled-runtime ]] || [[ "$active" == 1 && "$enabled" == indirect ]]; } && continue
        # S160: register BEFORE mutating (see stop flow).
        append_managed_service_state_entry "$pre_state" "$changed_pre" "$srv" || { failed=1; break; }
        printf '%s\n' "$srv|1|enabled" >> "$changed_expected" || { failed=1; break; }
        if [[ "$active" == 1 ]]; then
            enable_abox_service_soft "$srv" || failed=1
        else
            start_abox_service_soft "$srv" || failed=1
        fi
        after=$(managed_service_state_value "$srv" 2>/dev/null || true)
        [[ "$after" == "$srv|1|enabled" ]] || failed=1
        (( failed == 0 )) || break
    done <<< "$services"

    if (( failed == 0 )); then
        clear_traffic_block_period || failed=1
        (( failed != 0 )) || set_desired_state RUNNING || failed=1
    fi
    if (( failed != 0 )); then
        # S162: no more `|| true` file-state restores: the wrapper
        # restores block period + desired state + services together,
        # and tx_dir is deleted only when ALL steps report ok.
        if ! __abox_service_tx_rollback_all "$tx_dir"; then printf '%s\n' "A-Box service rollback incomplete; recovery state preserved at $tx_dir" >&2; else trap - HUP INT TERM; rm -rf -- "$tx_dir"; fi
        die "$(tr_msg manual_start_managed_stack_start_commit_fail)"
    fi
    # U232: transaction committed; restore the lock traps exactly.
    trap 'runtime_lock_cleanup; exit 129' HUP
    trap 'runtime_lock_cleanup; exit 130' INT
    trap 'runtime_lock_cleanup; exit 143' TERM
    rm -rf -- "$tx_dir" || die "$(tr_msg manual_start_managed_stack_tx_cleanup_fail)"
    printf 'A-Box managed stack started; Intent=RUNNING\n'
}


show_cli_help() {
    cat <<'EOF_HELP'
A-Box
Usage:
  bash install.sh                    启动交互菜单 / Start interactive menu
  bash install.sh --lang zh|zh-tw|en|ja|ru|fa 设置脚本界面语言并启动 / Select UI language
  bash install.sh --self-test        运行无副作用静态自测 / Run static self-test
  bash install.sh --status           显示当前配置和服务状态 / Show current status
  bash install.sh --stop             停止托管服务并保持手动停止状态 / Stop managed services
  bash install.sh --start            启动托管服务并恢复运行状态 / Start managed services
  bash install.sh --version          显示构建版本 / Show build version
  bash install.sh --export-backup-key /secure/path/A-Box-recovery.key
                                      将恢复密钥导出到独立可信介质 / Export the recovery key to separate trusted media
  bash install.sh --convert-legacy-backup OLD.tar.gz /root/converted
                                      安全转换旧版备份为 manifest v3 / Safely convert a legacy backup to manifest v3
  bash install.sh --xray-config-autorecover
                                      xray 配置损坏时从可信备份自动恢复一次（探针调用） / Auto-recover a damaged Xray config once from a trusted backup (probe call)
  bash install.sh --help             显示命令行帮助 / Show help
EOF_HELP
}

check_i18n_parity_file() {
    local _f="$1" _keys _out _bad
    _keys=$(grep -oE '^        (zh|en|ru|fa|zh-tw|ja):[a-z0-9_]+\)' "$_f" | sed 's/^.*://; s/)$//' | sort -u)
    [[ -n "$_keys" ]] || { echo 'FAIL: i18n key enumeration empty'; return 1; }
    # S172: single-pass count. S167 counted PER language (a total of 6
    # can hide one missing arm cancelled by one duplicate arm, so the
    # per-language verdict stays), but with one full-file grep per key
    # per language: 1192 keys x 6 = 7152 scans. On Alpine's BusyBox
    # grep at ~43ms/scan that is ~300s and blows the 180s harness cap,
    # while GNU grep at ~1ms hides it elsewhere. One grep extracts
    # every lang:key arm, one awk counts per pair; verdicts unchanged.
    _out=$(grep -oE '^        (zh|en|ru|fa|zh-tw|ja):[a-z0-9_]+\)' "$_f" | sed 's/^        //; s/)$//' | awk -v keys="$_keys" '
        BEGIN { n = split(keys, ka, "\n"); }
        { cnt[$0]++ }
        END {
            langs[1] = "zh"; langs[2] = "en"; langs[3] = "ru"; langs[4] = "fa"; langs[5] = "zh-tw"; langs[6] = "ja";
            bad = 0;
            for (i = 1; i <= n; i++) {
                k = ka[i];
                for (j = 1; j <= 6; j++) {
                    c = cnt[langs[j] ":" k] + 0;
                    if (c != 1) { printf "FAIL: i18n key %s language %s has %d arm(s), expected 1\n", k, langs[j], c; bad++; }
                }
            }
            printf "BAD=%d\n", bad;
        }')
    _bad=${_out##*BAD=}
    _out=${_out%BAD=*}
    _out=${_out%$'\n'}
    [[ -n "$_out" ]] && printf '%s\n' "$_out"
    # R16-06: bash return codes are 8 bits; returning $_bad raw wraps
    # 256/512 to 0 and the self-test would still print SELF_TEST_OK.
    # Clamp to 255 (preserves the 1..255 contribution to the caller's
    # failure count, unlike collapsing to 1).
    (( _bad > 255 )) && _bad=255
    return "$_bad"
}
