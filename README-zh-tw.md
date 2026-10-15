# A-Box

<p align="center">
  <img width="804" height="867" alt="A-Box_github" src="https://github.com/user-attachments/assets/4f51a6a1-5d1b-49db-90df-98ffae63d1ca" />
</p>

[🇺🇸 English](README.md) | [🇨🇳 简体中文](README-zh.md) | [🇯🇵 日本語](README-ja.md) | [🇷🇺 Русский](README-ru.md) | [🇮🇷 فارسی](README-fa.md)

Linux 網路閘道一鍵工具箱。

A-Box 是一個獨立 Bash 腳本，用於部署和維護 Linux 網路閘道服務。當前相容性 pin 為 Xray `v26.7.28`（上游預發布版，因相容性需要而保留）、sing-box `v1.14.3` 和 Hysteria `app/v2.13.0`；選擇最新穩定版時不會靜默降級已安裝的較新核心。

支援 Xray-core、sing-box、官方 Hysteria 2 服務端、VLESS Vision REALITY、VLESS XHTTP REALITY、Shadowsocks-2022、客戶端配置匯出、本地 SNI 候選測試、備份恢復、防火牆管理、診斷、流量限制、健康檢查和核心軟體升級；最新穩定版下載失敗時先嘗試同版本的校驗映象，再回退到固定相容性 pin。

> 僅限在合法、授權、合規的環境中使用。使用者自行承擔所有法律、運維和安全後果。

## 合規與免責聲明

本專案用於網路架構測試、網路安全研究、系統運維自動化，以及在完全授權環境中的合法隱私保護。請勿將本專案用於非法攻擊、未授權存取、規避審計、網路濫用、破壞基礎設施或任何違法活動。請僅在您擁有、管理或已獲得明確授權的伺服器、網路和系統中使用。

本專案按「現狀」提供，不提供任何擔保。執行前請審閱腳本及其可能造成的系統變更；維護或升級前應保留可恢復的備份。

## 安全快速開始

### GitHub 官方源

```bash
curl -fsSL https://raw.githubusercontent.com/alariclin/A-Box/0bc5586486c337deb01cca1d053701dc79bc816d/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# 審閱下載的腳本後，再單獨執行：
sudo bash A-Box.sh
```

### 第三方備用映象

```bash
curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/alariclin/A-Box/0bc5586486c337deb01cca1d053701dc79bc816d/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# 審閱下載的腳本後，再單獨執行：
sudo bash A-Box.sh
```

兩個命令均將安裝腳本固定到不可變提交 `888f2d9227d8f3aa4211d1bc036155747e83d390`；代理網址仍屬於第三方傳輸服務，不是 A-Box 官方端點。語法檢查與 SHA-256 摘要本身不能證明發布者身份，執行前應審閱下載檔案；生產環境還應透過獨立可信渠道核對提交與摘要。全新 Alpine 系統執行前先執行 `apk add --no-cache bash curl`。安裝後輸入 `sb` 開啟選單。

## 主要功能

- **協議部署：** Xray VLESS Vision REALITY、Xray VLESS XHTTP REALITY、Xray Shadowsocks-2022、官方 Hysteria 2，以及對應的 sing-box Vision、Shadowsocks-2022 和 Hysteria 2 選項。
- **組合部署：** Xray + Hysteria 2 組合；sing-box Vision + Hysteria 2 + Shadowsocks-2022 組合。sing-box 組合按設計不包含 XHTTP。
- **客戶端配置匯出：** 分享連結/URI、二維碼、Clash/Mihomo YAML、sing-box 出站模板、v2rayN/v2rayNG XHTTP JSON。
- **運維和診斷：** 健康檢查、系統/下載測速、IP 品質與路由測試、BBR/FQ 調優和回滾、IP 偏好、DNS 實測優選與受支援後端的 DoT/DoH、時區編號選擇、Locale/NTP、Wallos 安裝與資料備份、Fail2Ban/logrotate、流量限制、備份恢復、脫敏診斷包和預檢查。
- **運維增強：** 一鍵 Reality、快速/嚴格模式（`ABOX_FAST`）、核心固定版本與失敗回滾、多 UUID 服務端新增/撤銷、URI/Base64/Clash 匯出，以及真實下載源可用性探測。
- **核心二進位映象：** 固定入口 Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/A-Box/releases/tag/core-binaries) 同時保留固定相容性版本資產和帶版本號的最新正式穩定版資產。每週工作流會排除 draft/prerelease，校驗官方 SHA-256 與資產架構；僅對 CI 執行器可執行的二進位進行版本探測，並保留舊版本資產供回滾。安裝器還會在目標環境校驗實際二進位版本。最新穩定版回退先嘗試完全匹配的版本化映象，再回退到固定相容性 pin。`SHA256SUMS` 是同一 Release 內的完整性清單，不是獨立簽名；詳見 [`mirrors/README.md`](mirrors/README.md)。
- **SNI 候選工作流：** 本地完整和微型主機候選測試、已儲存結果檢視器、輸入校驗、檔案大小/行數上限、重複項清理，以及可用時回退到有效本地快取或同目錄資料檔案。
- **維護：** 顯示 SHA-256 並要求明確確認的腳本 OTA、Xray Geo 資料更新，以及不重置節點參數的核心程式單獨升級。
- **安全控制：** 部署前檢查、受控服務歸屬/狀態變更、防火牆處理，以及受支援操作的回滚路徑。

倉庫內建候選種子檔案見 [`data/sni-candidates.txt`](data/sni-candidates.txt)。SNI 列表僅是候選項。域名出現在列表中，**不代表它從特定 VPS 當前可用，也不保證符合目標 REALITY 部署所需的 TLS/ALPN/SAN 條件**。使用前必須在目標網路實際驗證。無法取得有效列表或有效備用副本時，SNI 工作流會拒絕繼續，而不是使用未經驗證的資料。

## 主選單

| 編號 | 功能 |
|---:|---|
| `1` | Xray VLESS Vision REALITY |
| `2` | Xray VLESS XHTTP REALITY |
| `3` | Xray Shadowsocks-2022 |
| `4` | 官方 Hysteria 2 服務端 |
| `5` | Xray + Hysteria 2 組合：Vision TCP 443、XHTTP TCP 8443、Hysteria 2 UDP 443、SS-2022 TCP/UDP 2053 |
| `6` | sing-box VLESS Vision REALITY |
| `7` | sing-box Shadowsocks-2022 |
| `8` | sing-box VLESS + Shadowsocks-2022 |
| `9` | sing-box Hysteria 2 |
| `10` | sing-box Vision + Hysteria 2 + Shadowsocks-2022（不含 XHTTP） |
| `11` | 綜合工具箱：測速、診斷、Wallos 與系統設定 |
| `12` | 顯示節點參數和客戶端配置 |
| `13` | 腳本說明書 |
| `14` | 腳本 OTA、Xray Geo 資料和核心單獨升級 |
| `15` | 全部/部分解除安裝 |
| `16` | 刪除節點並重新初始化環境 |
| `17` | 每月流量限制（vnStat），顯示截至目前的累計用量 |
| `18` | SS-2022 IP/CIDR 白名單管理 |
| `19` | 介面語言：中文、English、Русский、فارسی |
| `20` | **一鍵 Reality**；`r` 為快捷別名 |
| `0` | 退出 |

### 綜合工具箱

原有系統/下載測速、IP 品質、SNI 全量與微型主機優選、WARP、2 GB Swap、備份/恢復、脫敏診斷、預檢查和訂閱匯出功能均保留。新增/歸併的入口包括：BBR/FQ 調優子選單（僅應用與回滾）；主機設定（IP 偏好、明文 DNS、後端支援時的 DoT、實測 DNS 優選、受支援環境的 DoH、時區/Locale/NTP 與下載源偏好）；以及 Wallos 安裝、升級、狀態、備份和保留資料解除安裝容器功能。BBR 為手動選擇，不會在協議安裝後自動執行。

測速和 IP 品質選項先存取上游腳本，檢查內容格式和 Bash 語法，顯示 SHA-256 並要求確認。上游不可用或內容無效時，才回退到 A-Box Release `test-tools-mirror`；只有 `SHA256SUMS` 校驗通過才會執行。雙源都失敗時不會執行腳本。

Wallos 是可選的自託管訂閱管理工具。安裝器優先讀取 Wallos 穩定版與匹配的 Docker 映象；上游不可用時回退到 `wallos-mirror`。資料備份先寫入臨時檔案並驗證，再原子提交；升級失敗時會嘗試透過暫存恢復流程回滾。Wallos 預設只綁定 `127.0.0.1`；遠端存取應使用 HTTPS 反向代理或 SSH 隧道。只有明確設定 `WALLOS_BIND_ADDRESS=0.0.0.0` 並再次確認後，才會將未加密 HTTP 連接埠發佈到所有 IPv4 網卡。第三方測速腳本映象需要手動觸發工作流並確認重新整理。

BBR/FQ 不會靜默修改系統。DNS 優選根據當前 VPS 對候選解析器發起多輪真實查詢，延遲和可用率只代表本次測量，不是全球通用排名。DoT 僅在當前 DNS 後端支援時啟用，並要求輸入上游 TLS 認證主機名，讓 systemd-resolved 校驗解析器憑證（例如 `1.1.1.1#cloudflare-dns.com` 或 `8.8.8.8#dns.google`）；DoH 使用 `dnscrypt-proxy`，且限制在支援的軟體包和 systemd-resolved 環境。DNS 與時區設定均提供回滾路徑。

四種語言覆蓋主選單、運維選單及本次新增/調整的工具流程；少數舊協議嚮導和舊錯誤訊息仍可能混有中英文，不能據此宣稱所有歷史提示已完成百分之百的四語翻譯。

## 命令列用法

倉庫中的腳本檔案名為 `install.sh`。下方 curl 範例會儲存為 `A-Box.sh`；只要內容是本腳本，兩種檔名均可。

在腳本所在目錄執行：

| 命令 | 作用 |
|---|---|
| `sudo bash A-Box.sh --help` | 顯示命令列說明 |
| `sudo bash A-Box.sh --lang zh` / `--lang en` / `--lang ru` / `--lang fa` | 設定介面語言並啟動選單 |
| `sudo bash A-Box.sh --self-test` | 執行內建迴歸/自測 |
| `sudo bash A-Box.sh --preflight` 或 `--dry-run` | 執行預檢查，不部署新節點 |
| `sudo bash A-Box.sh --status` | 查看託管配置和服務狀態 |
| `sudo bash A-Box.sh --start` / `--stop` | 啟動/停止託管服務 |
| `sudo bash A-Box.sh --version` | 顯示腳本建構後設資料 |
| `sudo bash A-Box.sh --export-backup-key /secure/path/A-Box-recovery.key` | 將恢復金鑰匯出到受保護路徑 |
| `sudo bash A-Box.sh --convert-legacy-backup OLD.tar.gz [OUTPUT_DIR]` | 將舊版備份轉換為 manifest v3 格式 |

請妥善保護匯出的恢復金鑰和備份。`--self-test` 通過不能替代目標主機預檢查、真實安裝或客戶端互通測試。

## 系統要求

腳本包含對下列環境的相容處理；實際相容性還取決於系統版本、初始化系統、CPU 架構、依賴、服務商網路環境和上游下載可用性。

| 項目 | 要求 |
|---|---|
| 系統系列 | Debian 10+、Ubuntu 20.04+、CentOS/RHEL/Rocky/AlmaLinux 8+ 或 Alpine Linux |
| 初始化系統 | systemd 或 OpenRC |
| CPU 架構 | amd64/x86_64 或 arm64/aarch64 |
| 權限 | root 或 sudo |
| 網路 | 可存取系統軟體源和所需上游/GitHub 發布端點 |
| 腳本介面 | 中文、English、Русский、فارسی（部分舊協議嚮導仍含雙語提示） |

腳本語言選單支援中文、English、Русский、فارسی 的選擇；主選單與本次整理的運維選單已翻譯。部分較早的協議嚮導提示仍保留中英雙語文字。

## 生產環境檢查清單

1. 審閱腳本並選擇可信、固定版本的來源；不要盲目信任第三方映象。
2. 在目標 VPS 上先執行 `--self-test` 和 `--preflight`。
3. 確認雲服務商防火牆/安全群組規則，以及所選協議、連接埠和客戶端的相容性。
4. 將恢復金鑰獨立儲存；執行破壞性維護前保留並驗證備份。
5. 從實際使用節點的網路驗證 DNS、TLS、ALPN、SNI、連通性和客戶端行為。CI 通過本身不能證明所有 VPS 服務商、作業系統和客戶端都可正常使用。

## 回饋與授權

- [GitHub Issues](https://github.com/alariclin/A-Box/issues)
- 歡迎提交 Pull Request。
- 本專案使用 [Apache License 2.0](LICENSE)。
