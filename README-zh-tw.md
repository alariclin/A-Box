<div align="center">
  <img width="300" alt="A-Box" src="https://github.com/user-attachments/assets/4f51a6a1-5d1b-49db-90df-98ffae63d1ca" />
  <h1>A-Box</h1>
  <p><b>Linux 網路服務一鍵部署與管理工具箱</b> — 單一檔案 Bash 腳本 · Xray / sing-box / Hysteria 2 · 六種語言選單</p>
  <p>
    <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="license">
    <img src="https://img.shields.io/badge/script-Bash-green" alt="bash">
    <img src="https://img.shields.io/badge/platform-Linux-orange" alt="platform">
  </p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README-zh.md">简体中文</a> ·
    <a href="README-zh-tw.md">繁體中文</a> ·
    <a href="README-ja.md">日本語</a> ·
    <a href="README-ru.md">Русский</a> ·
    <a href="README-fa.md">فارسی</a>
  </p>
</div>

---

## 介面截圖

主選單（狀態矩陣、系統/網路資訊與部署選單）：

![主選單](docs/showcase-menu.png)

## 這是什麼

A-Box 是一個單一檔案 Bash 腳本（`install.sh`，約 26,000 行），用於在 Linux VPS 上部署和維護代理與網路服務。它負責安裝和設定 Xray、sing-box 與官方 Hysteria 2 伺服器端，產生用戶端設定，並把日常維運——防火牆規則、Fail2Ban 防護、DNS 設定、備份、升級與診斷——收進一個六種語言的互動選單。你在選單裡選定之前，腳本不會部署任何東西；破壞性操作都會先要求確認。

## 快速開始

官方來源，指令已鎖定到不可變的提交：

```bash
curl -fsSL https://raw.githubusercontent.com/alariclin/A-Box/d63434e3b98d666896e37787b050e6f4e8737601/install.sh -o A-Box.sh && sudo bash A-Box.sh
```

第三方鏡像（與上面是同一個鎖定檔案，僅作傳輸通道，不是官方入口）：

```bash
curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/alariclin/A-Box/d63434e3b98d666896e37787b050e6f4e8737601/install.sh -o A-Box.sh && sudo bash A-Box.sh
```

- 全新的 Alpine 系統請先執行 `apk add --no-cache bash curl`。
- 首次執行後，輸入 `sb` 即可再次開啟選單。
- 生產環境使用前，請透過獨立可信管道核對下載到的檔案。

## 主選單

| 編號 | Xray 核心 | 編號 | sing-box |
|---:|---|---:|---|
| 1 | VLESS-Vision-Reality | 6 | VLESS-Vision-Reality |
| 2 | VLESS-XHTTP-Reality | 7 | VLESS + SS-2022 |
| 3 | Shadowsocks-2022 | 8 | Shadowsocks-2022 |
| 4 | Hysteria 2（官方伺服器端） | 9 | Hysteria 2（Sing-box） |
| 5 | 全協議四合一（Xray+Hy2） | 10 | 全協議三合一（Sing-box） |

Xray 四合一包含 Vision（TCP 443）、XHTTP（TCP 8443）、Shadowsocks-2022（TCP/UDP 2053）與 Hysteria 2（UDP 443）。sing-box 三合一包含 Vision、Shadowsocks-2022 與 Hysteria 2，不含 XHTTP。

| 編號 | 工具與系統 | 編號 | 維運與策略 |
|---:|---|---:|---|
| 11 | 綜合工具箱 | 16 | 清空節點與重置環境 |
| 12 | 查看節點配置與參數 | 17 | 流量管控與額度限制 |
| 13 | 使用幫助與說明書 | 18 | 更多協議（子選單見下） |
| 14 | 核心與腳本升級（OTA） | 19 | 多語言設定 |
| 15 | VPS 一鍵優化 | 20 | 徹底卸載腳本與核心 |
| 0 | 退出腳本 | R | 一鍵 Reality（快捷鍵） |

### 更多協議（選單 18）

獨立部署，與上面的組合部署互不影響。每個協議都會詢問連接埠、產生或接受密碼、寫入前先用核心校驗設定、把分享連結登記到選單 12，並在結束時刷新 Fail2Ban 規則。

| 編號 | 協議 | 說明 |
|---:|---|---|
| 1 | Trojan-Reality | 獨立 Trojan + REALITY，可選 Xray 或 sing-box 核心 |
| 2 | TUIC | sing-box 的 TUIC v5，UDP，自簽憑證 |
| 3 | AnyTLS | sing-box 的 AnyTLS，帶 REALITY |
| 4 | SOCKS5 / Mixed | 獨立 SOCKS5，帶帳號密碼認證，可選核心 |
| 5 | ShadowTLS | sing-box 的 ShadowTLS v3，轉接到內部 Shadowsocks-2022 入站 |
| 6 | Argo (CDN) | VMess / VLESS 經 WebSocket 走 Cloudflare 隧道，伺服器不開任何入站連接埠。臨時隧道是隨機 `*.trycloudflare.com` 位址，重新啟動即變；固定隧道用你自己的網域和隧道權杖 |

## 狀態面板

選單頂部是 16 格狀態矩陣（運行 / 未開啟 / 故障）：Xray、sing-box、Hy2、Trojan、TUIC、AnyTLS、ShadowTLS、SOCKS5、WARP、Cloudflare、Fail2ban、Wallos、Traffic、Docker、BBR、Firewall，其後是系統、硬體與網路資訊行。網路行會標註出口 IP 的位置與類型（機房 / 住宅 / 蜂窩、廣播或原生）。已部署節點會列出連接埠與 SNI。綠格只表示服務在運行或連接埠在監聽，不等於端到端連通，請以用戶端實測為準。

## 綜合工具箱（選單 11）

| 編號 | 功能 | 編號 | 功能 |
|---:|---|---:|---|
| 1 | A-Check IP 純淨度檢測 | 9 | 本地 SNI 優選 |
| 2 | 系統效能與下載測速 | 10 | 微型主機 SNI 優選 |
| 3 | IP 品質 / 串流解鎖 / 回程測試 | 11 | SNI 優選記錄 |
| 4 | 匯出脫敏診斷包 | 12 | 配置備份 / 還原 |
| 5 | WARP 與分流管理 | 13 | 多用戶 / 訂閱連結匯出 |
| 6 | 建立 2 GB Swap | 14 | Wallos 安裝 / 升級 / 備份 |
| 7 | VPS 一鍵優化 | 15 | SS-2022 存取白名單 |
| 8 | IP / DNS / 時區 / 下載源設定 | | |
| 0 | 返回主選單 | | |

第 1、2 項的測試腳本從經校驗的 `test-tools-mirror` 發布中取得，SHA-256 與清單一致才執行。鏡像不可用或校驗不一致時，只有設定了 `ABOX_ALLOW_UNVERIFIED_UPSTREAM=1` 才會改用上游腳本，否則什麼都不執行。

第 1 項 **A-Check** 是配套專案 [A-Check](https://github.com/alariclin/A-Check) 的 IP 純淨度檢測工具。腳本下載其鎖定版本檔案（`v4.13.4`），執行前校驗 SHA-256，並快取在 `/etc/ddr/tools`；校驗不一致的副本永不執行。需要 Python 3.8 或更高版本。

## 子系統

**用戶端配置。** 每次部署都會列印分享連結和 QR 碼。選單 12 隨時可重看全部節點參數與連結——包括選單 18 的獨立協議——並匯出 Clash / Mihomo YAML、sing-box JSON 與 v2rayN / v2rayNG 配置。支援在伺服器端新增或撤銷多個 UUID，並按用戶分別匯出。

**WARP 與分流。** 一鍵把 Cloudflare WARP 作為原生 WireGuard 出站部署，帶串流、CN 直連與全域三種預設，外加自訂網域分流規則和多主機 SOCKS5 出站。

**DNS 設定。** 自動實測優選會用真實查詢分別測出最快的明文 DNS、DoT 與 DoH；另有自訂填寫、Cloudflare / Quad9 預置、改動前的配置快照還原，以及三模式設定（僅 IPv4 / 僅 IPv6 / 雙棧）。DoT 經 systemd-resolved 生效；DoH 經本地 dnscrypt-proxy 轉發。

**Wallos。** 可選的自託管訂閱管理器（Docker）。安裝時選擇存取方式：公網 HTTPS（Caddy 終結 Let's Encrypt 的 IP 憑證，自動續期；失敗時經你確認才回退到下一種方式）、僅本機 + SSH 隧道、用自己網域的 Cloudflare 隧道，或公網明文 HTTP 容災。帶狀態頁、資料庫健康檢查與 tar 備份。

**主動防禦。** 系統沒有 Fail2Ban 時自動安裝。它的 jail 除 SSH 外，還覆蓋從現行 Xray / sing-box 設定裡收割到的全部公網連接埠——不只是最近一次部署的連接埠——封禁時長遞增。Wallos 有盯住其登入入口的專屬 jail。

**快速模式。** 設定 `ABOX_FAST=1` 後，部署過程中的重複確認提示會被跳過。

**備份、升級與 OTA。** 配置備份/還原使用帶版本號的清單格式與還原金鑰（`--export-backup-key`）。核心升級保留現有節點參數；腳本自身的 OTA 更新會顯示 SHA-256 並要求明確確認。Xray Geo 資料可單獨更新。

**核心版本。** Xray 鎖定在 `v26.7.28`：Xray ≥ v26.9.8 要求 X25519MLKEM768 金鑰交換，sing-box 用戶端目前無法完成該握手。sing-box 預設 `v1.14.3`，Hysteria 為 `app/v2.13.0`；Argo 用的 cloudflared 鎖定 `2026.10.2`，Wallos 的 HTTPS 前端 Caddy 鎖定 `2.11.7`，均帶 SHA-256 校驗。核心二進位按發布清單做 SHA-256 校驗，已發布簽名的強制 Ed25519 驗簽（見 `docs/SIGNING.md`）。固定版本與各版本最新穩定版都保存在 `core-binaries` 發布中以便回滾。

**SNI 候選。** 倉庫自帶 4,158 條候選網域種子列表（`data/sni-candidates.txt`）。工具箱可在目標 VPS 上實測優選（完整版或微型版）並保存記錄。列表裡的網域只是候選，不保證在你的網路可用、也不保證適合某個具體的 REALITY 部署。拿不到有效列表時該流程直接失敗，不硬湊。

## 命令行

| 指令 | 用途 |
|---|---|
| `sudo bash A-Box.sh` | 開啟互動選單 |
| `sudo bash A-Box.sh --help` | 顯示命令行幫助 |
| `sudo bash A-Box.sh --lang zh` / `zh-tw` / `en` / `ja` / `ru` / `fa` | 指定介面語言啟動 |
| `sudo bash A-Box.sh --self-test` | 執行內建自檢 |
| `sudo bash A-Box.sh --status` | 顯示受管服務與配置狀態 |
| `sudo bash A-Box.sh --start` / `--stop` | 啟動或停止受管服務 |
| `sudo bash A-Box.sh --version` | 顯示腳本建置標識 |
| `sudo bash A-Box.sh --export-backup-key /secure/path.key` | 匯出備份還原金鑰 |
| `sudo bash A-Box.sh --convert-legacy-backup OLD.tar.gz [目錄]` | 把舊格式備份轉換為現行格式 |

自檢通過不等於真實安裝或用戶端連通驗證都通過。

## 系統要求

已實測系統（14 個）：Debian 10 / 11 / 12 / 13、Ubuntu 20.04 / 22.04 / 24.04、Rocky Linux 8 / 9、AlmaLinux 8 / 9、Fedora 40、Alpine 3.18 / 3.19。

| 項目 | 要求 |
|---|---|
| 初始化系統 | systemd 或 OpenRC |
| CPU | amd64 / x86_64 或 arm64 / aarch64 |
| 權限 | root，或 sudo |
| 網路 | 能存取系統套件來源與 GitHub / 上游發布端點；部署的連接埠必須可達（雲端廠商防火牆也要放行） |

## 注意事項

- 面板的 IP 類型與位置資料來自公開 IP 情報服務，偶有誤判；多源比對只能減少、不能消除錯誤。
- Let's Encrypt 的 IP 憑證（Wallos HTTPS 模式）有效期很短（約 160 小時），由 Caddy 自動續期；與所有憑證一樣，它們會出現在公開的憑證透明度日誌中。
- Argo 臨時隧道位址在 cloudflared 每次重新啟動後都會變化；需要固定位址請使用自有網域的固定隧道。
- BBR/FQ 調校、DNS 修改與 WARP 分流都只在你選用時才套用，DNS 與調校改動保留回滾路徑。
- 備份與還原金鑰請存放在獨立且受保護的位置。

## 合規與免責

請僅在你擁有、管理或已獲得明確授權的伺服器、網路與系統上使用本專案，並遵守適用於你的法律法規——包括當地關於加密、代理與網路存取的規定。本專案面向授權環境下的系統管理、網路測試與研究。不得用於未授權存取、攻擊、濫用或規避合法監管。

本軟體按「現狀」提供，不附任何擔保。執行前請先審閱腳本內容，維護或升級前請保留可還原的備份。使用後果由你自行承擔法律、維運與安全責任。

## 回饋與授權

- 問題回饋：[GitHub Issues](https://github.com/alariclin/A-Box/issues)
- 本專案以 [Apache License 2.0](LICENSE) 發布。
