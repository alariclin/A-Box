<p align="center">
  <img width="300" alt="A-Box_github" src="https://github.com/user-attachments/assets/4f51a6a1-5d1b-49db-90df-98ffae63d1ca" />
</p>

[简体中文](README-zh.md) | [繁體中文](README-zh-tw.md) | [日本語](README-ja.md) | [Русский](README-ru.md) | [فارسی](README-fa.md)

One-click Linux network gateway toolkit.

A-Box is a standalone Bash script for deploying and maintaining Linux network gateway services. Its compatibility pins are Xray `v26.7.28` (an upstream prerelease intentionally retained for compatibility), sing-box `v1.14.3`, and Hysteria `app/v2.13.0`; latest-stable selection never silently downgrades an already installed newer core.

It supports Xray-core, sing-box, the official Hysteria 2 server, VLESS Vision REALITY, VLESS XHTTP REALITY, Shadowsocks-2022, client configuration export, local SNI candidate testing, backup and restore, firewall management, diagnostics, traffic limits, health checks, and core software upgrades.

> Use this project only in legal, authorized, and compliant environments. You are responsible for all legal, operational, and security consequences.

## Compliance and Disclaimer

This project is intended for network architecture testing, cybersecurity research, systems administration automation, and lawful privacy protection in fully authorized environments. Do not use it for unlawful attacks, unauthorized access, audit evasion, network abuse, infrastructure disruption, or any other illegal activity. Use it only on servers, networks, and systems that you own, manage, or have explicit permission to operate.

The project is provided “as is”, without warranty. Review the script and the changes it may make before running it, and keep recoverable backups before maintenance or upgrades.

## Quick Start

### Official GitHub source

```bash
curl -fsSL https://raw.githubusercontent.com/alariclin/A-Box/b5999b9391348c87e344b2cd6d97eaa10e0421a3/install.sh -o A-Box.sh && sudo bash A-Box.sh
```

### Third-party fallback mirror

```bash
curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/alariclin/A-Box/b5999b9391348c87e344b2cd6d97eaa10e0421a3/install.sh -o A-Box.sh && sudo bash A-Box.sh
```

Both commands pin the installer to immutable commit `a7cb193e6539cee6478648e766f5ce415ccd5d41`; the proxy URL remains a third-party transport, not an official A-Box endpoint. For production, verify the commit and checksum through an independent trusted channel. On a fresh Alpine install, first run `apk add --no-cache bash curl`. After installation, enter `sb` to open the menu.

## Main Features

- **Protocol deployment:** Xray VLESS Vision REALITY; Xray VLESS XHTTP REALITY; Xray Shadowsocks-2022; official Hysteria 2; corresponding sing-box Vision, Shadowsocks-2022, and Hysteria 2 options.
- **Combined deployments:** Xray + Hysteria 2 bundle, and a sing-box Vision + Hysteria 2 + Shadowsocks-2022 bundle. The sing-box bundle intentionally does not include XHTTP.
- **Client configuration export:** share links/URIs, QR codes, Clash/Mihomo YAML, sing-box outbound templates, and v2rayN/v2rayNG XHTTP JSON.
- **Operations and diagnostics:** health checks, system/download benchmark, IP quality and route tests, BBR/FQ tuning with rollback, IP preference, measured host DNS, supported DoT/DoH, numbered timezone selection, locale/NTP settings, Wallos installation/backup, Fail2Ban/logrotate, traffic limits, backup/restore, redacted diagnostics, and preflight checks.
- **Operations:** one-click Reality, fast/strict mode (`ABOX_FAST`), stable core pins and rollback-capable upgrades, multi-UUID server-side add/revoke plus URI/Base64/Clash export, and real download-source availability checks.
- **Core binary mirrors:** the stable Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/A-Box/releases/tag/core-binaries) keeps fixed compatibility-pin assets and versioned copies of the latest official stable Xray, sing-box, and Hysteria builds. The weekly publisher rejects draft/prerelease tags, verifies official SHA-256 digests and asset architecture, probes versions where the runner can execute the binary, and retains older versioned assets for rollback; the installer checks the actual binary version on the target before installation. Latest-stable recovery tries the exact-tag mirror first, then the fixed compatibility pins. `SHA256SUMS` is a same-Release integrity manifest, not an independent signature; see [`mirrors/README.md`](mirrors/README.md).
- **SNI candidate workflow:** local full and mini-host candidate tests, saved-result viewer, input validation, bounded file size/row count, duplicate removal, and fallback to a valid local cache or adjacent data file when available.
- **Maintenance:** controlled script OTA with displayed SHA-256 and explicit confirmation, Xray Geo data updates, and core-only upgrades that preserve node parameters.
- **Safety controls:** deployment preflight checks, guarded service ownership/state changes, firewall handling, and rollback paths for supported operations.
- **WARP one-click egress & split routing:** deploy Cloudflare WARP as a native WireGuard outbound in one click; streaming/CN-direct/global presets; multi-host SOCKS5 outbound with domain-based routing rules.
- **DNS three-mode:** IPv4-only, IPv6-only, or dual-stack DNS with 10 providers and automatic v4/v6 pairing.

The repository ships a curated seed list at [`data/sni-candidates.txt`](data/sni-candidates.txt). SNI entries are only candidates. A listed hostname is **not** a guarantee that it currently works from a particular VPS, supports the required TLS/ALPN/SAN characteristics, or is suitable for a specific REALITY deployment. Verify candidates on the target network before use. The SNI workflow fails closed when it cannot obtain a valid candidate list or fallback copy.

## Main Menu

| No. | Function |
|---:|---|
| `1` | Xray VLESS Vision REALITY |
| `2` | Xray VLESS XHTTP REALITY |
| `3` | Xray Shadowsocks-2022 |
| `4` | Official Hysteria 2 server |
| `5` | Xray + Hysteria 2 bundle: Vision TCP 443, XHTTP TCP 8443, Hysteria 2 UDP 443, SS-2022 TCP/UDP 2053 |
| `6` | sing-box VLESS Vision REALITY |
| `7` | sing-box Shadowsocks-2022 |
| `8` | sing-box VLESS + Shadowsocks-2022 |
| `9` | sing-box Hysteria 2 |
| `10` | sing-box Vision + Hysteria 2 + Shadowsocks-2022 (no XHTTP) |
| `11` | Toolbox: benchmarks, diagnostics, WARP & split routing, Wallos and host settings |
| `12` | Display node parameters and client configurations |
| `13` | Manual |
| `14` | Script OTA, Xray Geo data, and core-only upgrade |
| `15` | VPS one-click optimization |
| `16` | Delete nodes and reinitialize the environment |
| `17` | Monthly traffic control with usage dashboard and progress bar |
| `18` | SS-2022 IP/CIDR allowlist manager |
| `19` | UI language: Simplified Chinese, Traditional Chinese, English, Japanese, Russian or Persian |
| `20` | Complete uninstall of script and cores |
| `0` | Exit |
| `r` | One-click Reality shortcut |

### Toolbox

The toolbox keeps all existing benchmark, IP quality, SNI, WARP one-click egress & split routing (WireGuard outbound, streaming/CN-direct/global presets, multi-host SOCKS5 outbound with domain rules), Swap, backup/restore, redacted diagnostics, preflight and subscription-export functions. It also includes a BBR/FQ tuning submenu (apply and rollback only), host settings (IP preference, plain DNS, supported DoT, measured DNS selection, supported DoH, timezone/locale/NTP and download-source preference), and Wallos installation/update/status/backup. BBR is opt-in and does not run automatically after protocol installation.

The benchmark and IP-quality options try the A-Box verified mirror (`test-tools-mirror` Release) first, and run the script only when the asset matches its `SHA256SUMS` entry. If the mirror is unavailable or the checksum mismatches, they fall back to the upstream script only when `ABOX_ALLOW_UNVERIFIED_UPSTREAM=1` is set (unverified, no SHA pin); otherwise no script is executed.

Wallos is an optional self-hosted subscription tracker. The installer detects OS and architecture, fetches a stable Wallos release and matching Docker image, and uses the fixed `wallos-mirror` release only if upstream retrieval fails. Backups are staged and validated before publication, and upgrades attempt rollback on a failed health check. Wallos binds to `127.0.0.1` by default; use an HTTPS reverse proxy or SSH tunnel for remote access. Publishing plain HTTP on all IPv4 interfaces requires the explicit `WALLOS_BIND_ADDRESS=0.0.0.0` override and confirmation. Refreshing mutable third-party benchmark scripts requires a manual workflow dispatch approval.

BBR/FQ changes are never silently applied. DNS measurement ranks resolvers using successful live test queries from the current VPS; the result is local to that test window, not a universal ranking. DoT is enabled only when the active backend supports it; enter the upstream TLS authentication hostname so systemd-resolved can validate the DNS server certificate (for example, `1.1.1.1#cloudflare-dns.com` or `8.8.8.8#dns.google`). DoH uses `dnscrypt-proxy` and is restricted to supported package/systemd-resolved setups. DNS and timezone settings include a rollback path.

## Command-line Usage

The repository file is named `install.sh`. The curl examples below save it as `A-Box.sh`; either filename works if it is this script.

Run commands from the directory containing the script:

| Command | Purpose |
|---|---|
| `sudo bash A-Box.sh --help` | Show command-line help |
| `sudo bash A-Box.sh --lang zh` / `--lang zh-tw` / `--lang en` / `--lang ja` / `--lang ru` / `--lang fa` | Set the UI language and start the menu |
| `sudo bash A-Box.sh --self-test` | Run built-in regression/self-tests |
| `sudo bash A-Box.sh --preflight` or `--dry-run` | Run the preflight check without deploying a new node |
| `sudo bash A-Box.sh --status` | Show managed configuration and service status |
| `sudo bash A-Box.sh --start` / `--stop` | Start or stop managed services |
| `sudo bash A-Box.sh --version` | Show script build metadata |
| `sudo bash A-Box.sh --export-backup-key /secure/path/A-Box-recovery.key` | Export the recovery key to a protected path |
| `sudo bash A-Box.sh --convert-legacy-backup OLD.tar.gz [OUTPUT_DIR]` | Convert a legacy backup to manifest v3 format |

Protect exported recovery keys and backups. A `--self-test` pass does not replace a target-host preflight, live installation, or client interoperability test.

## System Requirements

The script contains compatibility paths for the following environments; actual compatibility depends on OS release, init system, architecture, dependencies, provider networking, and upstream downloads.

| Item | Requirement |
|---|---|
| OS families | Debian 10+, Ubuntu 20.04+, CentOS/RHEL/Rocky/AlmaLinux 8+, or Alpine Linux |
| Init system | systemd or OpenRC |
| CPU architecture | amd64/x86_64 or arm64/aarch64 |
| Privileges | root or sudo |
| Network | Access to system package repositories and required upstream/GitHub release endpoints |
| Script UI | Chinese, English, Russian and Persian menu selection; see note above for legacy prompts |

The interactive language selector supports Simplified Chinese, Traditional Chinese, English, Japanese, Russian and Persian for the main menu and updated operations menus. Some older protocol-specific prompts remain bilingual and may still contain legacy Chinese/English wording.

## Recommended Production Checklist

1. Review the script and choose a trusted, version-pinned source; do not blindly trust third-party mirrors.
2. Run `--self-test` and `--preflight` on the target VPS before deployment.
3. Confirm provider firewall/security-group rules and client compatibility for the selected protocol and ports.
4. Export and store the recovery key separately; keep a verified backup before destructive maintenance.
5. Verify actual DNS, TLS, ALPN, SNI, reachability, and client behavior from the networks that will use the node. Passing CI alone does not prove that all VPS providers, operating systems, or clients will work.

## Feedback and License

- [GitHub Issues](https://github.com/alariclin/A-Box/issues)
- Pull requests are welcome.
- Released under the [Apache License 2.0](LICENSE).
