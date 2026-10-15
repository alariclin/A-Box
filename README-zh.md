# A-Box

Linux 网络网关一键工具箱。

[English](README.md) | [简体中文](README-zh.md) | [Русский](README-ru.md) | [فارسی](README-fa.md)

<p align="center">
  <img width="804" height="867" alt="A-Box_github" src="https://github.com/user-attachments/assets/4f51a6a1-5d1b-49db-90df-98ffae63d1ca" />
</p>

A-Box 是一个独立 Bash 脚本，用于部署和维护 Linux 网络网关服务。当前兼容性 pin 为 Xray `v26.7.28`（上游预发布版，因兼容性需要而保留）、sing-box `v1.14.3` 和 Hysteria `app/v2.13.0`；选择最新稳定版时不会静默降级已安装的较新核心。

支持 Xray-core、sing-box、官方 Hysteria 2 服务端、VLESS Vision REALITY、VLESS XHTTP REALITY、Shadowsocks-2022、客户端配置导出、本地 SNI 候选测试、备份恢复、防火墙管理、诊断、流量限制、健康检查和核心软件升级；最新稳定版下载失败时先尝试同版本的校验镜像，再回退到固定兼容性 pin。

> 仅限在合法、授权、合规的环境中使用。用户自行承担所有法律、运维和安全后果。

## 合规与免责声明

本项目用于网络架构测试、网络安全研究、系统运维自动化，以及在完全授权环境中的合法隐私保护。请勿将本项目用于非法攻击、未授权访问、规避审计、网络滥用、破坏基础设施或任何违法活动。请仅在您拥有、管理或已获得明确授权的服务器、网络和系统中使用。

本项目按“现状”提供，不提供任何担保。执行前请审阅脚本及其可能造成的系统变更；维护或升级前应保留可恢复的备份。

## 安全快速开始

### GitHub 官方源

```bash
curl -fsSL https://raw.githubusercontent.com/alariclin/a-box/c6e5df2a03dc611c66b8a3e0e1a4fe62eb597260/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# 审阅下载的脚本后，再单独执行：
sudo bash A-Box.sh
```

### 第三方备用镜像

```bash
curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/alariclin/a-box/c6e5df2a03dc611c66b8a3e0e1a4fe62eb597260/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# 审阅下载的脚本后，再单独执行：
sudo bash A-Box.sh
```

两个命令均将安装脚本固定到不可变提交 `c6e5df2a03dc611c66b8a3e0e1a4fe62eb597260`；代理网址仍属于第三方传输服务，不是 A-Box 官方端点。语法检查与 SHA-256 摘要本身不能证明发布者身份，执行前应审阅下载文件；生产环境还应通过独立可信渠道核对提交与摘要。全新 Alpine 系统运行前先执行 `apk add --no-cache bash curl`。安装后输入 `sb` 打开菜单。

## 主要功能

- **协议部署：** Xray VLESS Vision REALITY、Xray VLESS XHTTP REALITY、Xray Shadowsocks-2022、官方 Hysteria 2，以及对应的 sing-box Vision、Shadowsocks-2022 和 Hysteria 2 选项。
- **组合部署：** Xray + Hysteria 2 组合；sing-box Vision + Hysteria 2 + Shadowsocks-2022 组合。sing-box 组合按设计不包含 XHTTP。
- **客户端配置导出：** 分享链接/URI、二维码、Clash/Mihomo YAML、sing-box 出站模板、v2rayN/v2rayNG XHTTP JSON。
- **运维和诊断：** 健康检查、系统/下载测速、IP 质量与路由测试、BBR/FQ 调优和回滚、IP 偏好、DNS 实测优选与受支持后端的 DoT/DoH、时区编号选择、Locale/NTP、Wallos 安装与数据备份、Fail2Ban/logrotate、流量限制、备份恢复、脱敏诊断包和预检查。
- **运维增强：** 一键 Reality、快速/严格模式（`ABOX_FAST`）、核心固定版本与失败回滚、多 UUID 服务端添加/撤销、URI/Base64/Clash 导出，以及真实下载源可用性探测。
- **核心二进制镜像：** 固定入口 Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/a-box/releases/tag/core-binaries) 同时保留固定兼容性版本资产和带版本号的最新正式稳定版资产。每周工作流会排除 draft/prerelease，校验官方 SHA-256 与资产架构；仅对 CI 运行器可执行的二进制进行版本探测，并保留旧版本资产供回滚。安装器还会在目标环境校验实际二进制版本。最新稳定版回退先尝试完全匹配的版本化镜像，再回退到固定兼容性 pin。`SHA256SUMS` 是同一 Release 内的完整性清单，不是独立签名；详见 [`mirrors/README.md`](mirrors/README.md)。
- **SNI 候选工作流：** 本地完整和微型主机候选测试、已保存结果查看器、输入校验、文件大小/行数上限、重复项清理，以及可用时回退到有效本地缓存或同目录数据文件。
- **维护：** 显示 SHA-256 并要求明确确认的脚本 OTA、Xray Geo 数据更新，以及不重置节点参数的核心程序单独升级。
- **安全控制：** 部署前检查、受控服务归属/状态变更、防火墙处理，以及受支持操作的回滚路径。

仓库内置候选种子文件见 [`data/sni-candidates.txt`](data/sni-candidates.txt)。SNI 列表仅是候选项。域名出现在列表中，**不代表它从特定 VPS 当前可用，也不保证符合目标 REALITY 部署所需的 TLS/ALPN/SAN 条件**。使用前必须在目标网络实际验证。无法取得有效列表或有效备用副本时，SNI 工作流会拒绝继续，而不是使用未经验证的数据。

## 主菜单

| 编号 | 功能 |
|---:|---|
| `1` | Xray VLESS Vision REALITY |
| `2` | Xray VLESS XHTTP REALITY |
| `3` | Xray Shadowsocks-2022 |
| `4` | 官方 Hysteria 2 服务端 |
| `5` | Xray + Hysteria 2 组合：Vision TCP 443、XHTTP TCP 8443、Hysteria 2 UDP 443、SS-2022 TCP/UDP 2053 |
| `6` | sing-box VLESS Vision REALITY |
| `7` | sing-box Shadowsocks-2022 |
| `8` | sing-box VLESS + Shadowsocks-2022 |
| `9` | sing-box Hysteria 2 |
| `10` | sing-box Vision + Hysteria 2 + Shadowsocks-2022（不含 XHTTP） |
| `11` | 综合工具箱：测速、诊断、Wallos 与系统设置 |
| `12` | 显示节点参数和客户端配置 |
| `13` | 脚本说明书 |
| `14` | 脚本 OTA、Xray Geo 数据和核心单独升级 |
| `15` | 全部/部分卸载 |
| `16` | 删除节点并重新初始化环境 |
| `17` | 每月流量限制（vnStat），显示截至当前的累计用量 |
| `18` | SS-2022 IP/CIDR 白名单管理 |
| `19` | 界面语言：中文、English、Русский、فارسی |
| `20` | **一键 Reality**；`r` 为快捷别名 |
| `0` | 退出 |

### 综合工具箱

原有系统/下载测速、IP 质量、SNI 全量与微型主机优选、WARP、2 GB Swap、备份/恢复、脱敏诊断、预检查和订阅导出功能均保留。新增/归并的入口包括：BBR/FQ 调优子菜单（仅应用与回滚）；主机设置（IP 偏好、明文 DNS、后端支持时的 DoT、实测 DNS 优选、受支持环境的 DoH、时区/Locale/NTP 与下载源偏好）；以及 Wallos 安装、升级、状态、备份和保留数据卸载容器功能。BBR 为手动选择，不会在协议安装后自动执行。

测速和 IP 质量选项先访问上游脚本，检查内容格式和 Bash 语法，显示 SHA-256 并要求确认。上游不可用或内容无效时，才回退到 A-Box Release `test-tools-mirror`；只有 `SHA256SUMS` 校验通过才会执行。双源都失败时不会运行脚本。

Wallos 是可选的自托管订阅管理工具。安装器优先读取 Wallos 稳定版与匹配的 Docker 镜像；上游不可用时回退到 `wallos-mirror`。数据备份先写入临时文件并验证，再原子提交；升级失败时会尝试通过暂存恢复流程回滚。Wallos 默认只绑定 `127.0.0.1`；远程访问应使用 HTTPS 反向代理或 SSH 隧道。只有明确设置 `WALLOS_BIND_ADDRESS=0.0.0.0` 并再次确认后，才会将未加密 HTTP 端口发布到所有 IPv4 网卡。第三方测速脚本镜像需要手动触发工作流并确认刷新。

BBR/FQ 不会静默修改系统。DNS 优选根据当前 VPS 对候选解析器发起多轮真实查询，延迟和可用率只代表本次测量，不是全球通用排名。DoT 仅在当前 DNS 后端支持时启用，并要求输入上游 TLS 认证主机名，让 systemd-resolved 校验解析器证书（例如 `1.1.1.1#cloudflare-dns.com` 或 `8.8.8.8#dns.google`）；DoH 使用 `dnscrypt-proxy`，且限制在支持的软件包和 systemd-resolved 环境。DNS 与时区设置均提供回滚路径。

四种语言覆盖主菜单、运维菜单及本次新增/调整的工具流程；少数旧协议向导和旧错误消息仍可能混有中英文，不能据此宣称所有历史提示已完成百分之百的四语翻译。

## 命令行用法

仓库中的脚本文件名为 `install.sh`。下方 curl 示例会保存为 `A-Box.sh`；只要内容是本脚本，两种文件名均可。

在脚本所在目录执行：

| 命令 | 作用 |
|---|---|
| `sudo bash A-Box.sh --help` | 显示命令行帮助 |
| `sudo bash A-Box.sh --lang zh` / `--lang en` / `--lang ru` / `--lang fa` | 设置界面语言并启动菜单 |
| `sudo bash A-Box.sh --self-test` | 运行内置回归/自测 |
| `sudo bash A-Box.sh --preflight` 或 `--dry-run` | 运行预检查，不部署新节点 |
| `sudo bash A-Box.sh --status` | 查看托管配置和服务状态 |
| `sudo bash A-Box.sh --start` / `--stop` | 启动/停止托管服务 |
| `sudo bash A-Box.sh --version` | 显示脚本构建元数据 |
| `sudo bash A-Box.sh --export-backup-key /secure/path/A-Box-recovery.key` | 将恢复密钥导出到受保护路径 |
| `sudo bash A-Box.sh --convert-legacy-backup OLD.tar.gz [OUTPUT_DIR]` | 将旧版备份转换为 manifest v3 格式 |

请妥善保护导出的恢复密钥和备份。`--self-test` 通过不能替代目标主机预检查、真实安装或客户端互通测试。

## 系统要求

脚本包含对下列环境的兼容处理；实际兼容性还取决于系统版本、初始化系统、CPU 架构、依赖、服务商网络环境和上游下载可用性。

| 项目 | 要求 |
|---|---|
| 系统系列 | Debian 10+、Ubuntu 20.04+、CentOS/RHEL/Rocky/AlmaLinux 8+ 或 Alpine Linux |
| 初始化系统 | systemd 或 OpenRC |
| CPU 架构 | amd64/x86_64 或 arm64/aarch64 |
| 权限 | root 或 sudo |
| 网络 | 可访问系统软件源和所需上游/GitHub 发布端点 |
| 脚本界面 | 中文、English、Русский、فارسی（部分旧协议向导仍含双语提示） |

脚本语言菜单支持中文、English、Русский、فارسی 的选择；主菜单与本次整理的运维菜单已翻译。部分较早的协议向导提示仍保留中英双语文本。

## 生产环境检查清单

1. 审阅脚本并选择可信、固定版本的来源；不要盲目信任第三方镜像。
2. 在目标 VPS 上先运行 `--self-test` 和 `--preflight`。
3. 确认云服务商防火墙/安全组规则，以及所选协议、端口和客户端的兼容性。
4. 将恢复密钥独立保存；执行破坏性维护前保留并验证备份。
5. 从实际使用节点的网络验证 DNS、TLS、ALPN、SNI、连通性和客户端行为。CI 通过本身不能证明所有 VPS 服务商、操作系统和客户端都可正常使用。

## 反馈与许可证

- [GitHub Issues](https://github.com/alariclin/a-box/issues)
- 欢迎提交 Pull Request。
- 本项目使用 [Apache License 2.0](LICENSE)。
