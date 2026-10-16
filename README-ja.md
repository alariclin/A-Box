<p align="center">
  <img width="300" alt="A-Box_github" src="https://github.com/user-attachments/assets/4f51a6a1-5d1b-49db-90df-98ffae63d1ca" />
</p>

[English](README.md) | [简体中文](README-zh.md) | [繁體中文](README-zh-tw.md) | [Русский](README-ru.md) | [فارسی](README-fa.md)

ワンクリック Linux ネットワークゲートウェイ・ツールキット。

A-Box は、Linux ネットワークゲートウェイサービスのデプロイと保守のためのスタンドアロン Bash スクリプトです。互換性ピンは Xray `v26.7.28`（互換性維持のため意図的に残された上流プレリリース）、sing-box `v1.14.3`、Hysteria `app/v2.13.0` です。最新安定版の選択時に、既にインストール済みの新しいコアを黙ってダウングレードすることはありません。

Xray-core、sing-box、公式 Hysteria 2 サーバー、VLESS Vision REALITY、VLESS XHTTP REALITY、Shadowsocks-2022、クライアント設定のエクスポート、ローカル SNI 候補テスト、バックアップと復元、ファイアウォール管理、診断、トラフィック制限、ヘルスチェック、コアソフトウェアのアップグレードに対応しています。

> 本プロジェクトは、合法的で認可されたコンプライアンス環境でのみ使用してください。すべての法的・運用上・セキュリティ上の結果について、利用者が責任を負います。

## コンプライアンスと免責事項

本プロジェクトは、ネットワークアーキテクチャのテスト、サイバーセキュリティ研究、システム管理の自動化、および完全に認可された環境における合法的なプライバシー保護を目的としています。不正攻撃、不正アクセス、監査回避、ネットワーク乱用、インフラ破壊、その他の違法行為には使用しないでください。所有・管理している、または明示的な許可を得たサーバー・ネットワーク・システムでのみ使用してください。

本プロジェクトは「現状のまま」提供され、保証はありません。実行前にスクリプトと想定される変更内容を確認し、メンテナンスやアップグレードの前に復元可能なバックアップを保持してください。

## 安全なクイックスタート

### GitHub 公式ソース

```bash
curl -fsSL https://raw.githubusercontent.com/alariclin/A-Box/a80b95ef073c0a45b1cfc826f379cc0100bdd229/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# ダウンロードしたスクリプトを確認後、別途実行してください：
sudo bash A-Box.sh
```

### サードパーティ・フォールバックミラー

```bash
curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/alariclin/A-Box/a80b95ef073c0a45b1cfc826f379cc0100bdd229/install.sh -o A-Box.sh
bash -n A-Box.sh && sha256sum A-Box.sh && less A-Box.sh
# ダウンロードしたスクリプトを確認後、別途実行してください：
sudo bash A-Box.sh
```

どちらのコマンドも、インストーラーを不変のコミット `d3cc55548e7c7cb4fcbb197741fab5379069876a` にピン留めします。プロキシ URL はサードパーティの転送サービスであり、A-Box 公式エンドポイントではありません。構文チェックと SHA-256 のみでは発行者の真正性は証明されません。実行前にダウンロードしたファイルを確認し、本番環境では独立した信頼できる経路でコミットとチェックサムを検証してください。新規 Alpine インストールでは、まず `apk add --no-cache bash curl` を実行してください。インストール後は `sb` と入力してメニューを開きます。

## 主な機能

- **プロトコルデプロイ：** Xray VLESS Vision REALITY、Xray VLESS XHTTP REALITY、Xray Shadowsocks-2022、公式 Hysteria 2、および対応する sing-box Vision、Shadowsocks-2022、Hysteria 2 オプション。
- **バンドルデプロイ：** Xray + Hysteria 2 バンドル、sing-box Vision + Hysteria 2 + Shadowsocks-2022 バンドル。sing-box バンドルには意図的に XHTTP は含まれません。
- **クライアント設定エクスポート：** 共有リンク/URI、QR コード、Clash/Mihomo YAML、sing-box アウトバウンドテンプレート、v2rayN/v2rayNG XHTTP JSON。
- **運用と診断：** ヘルスチェック、システム/ダウンロードベンチマーク、IP 品質・ルートテスト、BBR/FQ チューニングとロールバック、IP プリファレンス、実測 DNS、対応 DoT/DoH、番号指定タイムゾーン選択、ロケール/NTP 設定、Wallos インストール/バックアップ、Fail2Ban/logrotate、トラフィック制限、バックアップ/復元、編集済み診断、プリフライトチェック。
- **運用機能：** ワンクリック Reality、高速/厳格モード（`ABOX_FAST`）、安定コアピンとロールバック可能なアップグレード、マルチ UUID サーバー側の追加/取消、URI/Base64/Clash エクスポート、実際のダウンロードソース可用性チェック。
- **コアバイナリミラー：** 安定版 Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/A-Box/releases/tag/core-binaries) には、固定互換性ピン資産とバージョン付きの最新公式安定版 Xray・sing-box・Hysteria ビルドが保持されます。週次パブリッシャーは draft/prerelease タグを除外し、公式 SHA-256 ダイジェストとアセットのアーキテクチャを検証、ランナーで実行可能なバイナリのバージョンをプローブし、ロールバック用に古いバージョン資産を保持します。インストーラーはインストール前に対象環境で実際のバイナリバージョンを確認します。最新安定版の復旧は、まず完全一致のバージョン化ミラーを試し、次に固定互換性ピンにフォールバックします。`SHA256SUMS` は同一 Release 内の整合性マニフェストであり、独立した署名ではありません。詳細は [`mirrors/README.md`](mirrors/README.md) を参照。
- **SNI 候補ワークフロー：** ローカルのフル・ミニホスト候補テスト、保存済み結果ビューア、入力検証、ファイルサイズ/行数上限、重複除去、利用可能な場合は有効なローカルキャッシュまたは隣接データファイルへのフォールバック。
- **メンテナンス：** SHA-256 を表示し明示的な確認を求めるスクリプト OTA、Xray Geo データ更新、ノードパラメータを保持したコア単体アップグレード。
- **安全制御：** デプロイ前プリフライトチェック、保護されたサービス所有権/状態変更、ファイアウォール処理、対応操作のロールバックパス。

リポジトリには [`data/sni-candidates.txt`](data/sni-candidates.txt) に厳選されたシードリストが同梱されています。SNI エントリーは候補に過ぎません。ホスト名がリストに載っていることは、特定の VPS から現在動作すること、必要な TLS/ALPN/SAN 特性を満たすこと、特定の REALITY デプロイに適することを**保証しません**。使用前に対象ネットワークで検証してください。有効な候補リストまたはフォールバックコピーを取得できない場合、SNI ワークフローはフェイルクローズします。

## メインメニュー

| 番号 | 機能 |
|---:|---|
| `1` | Xray VLESS Vision REALITY |
| `2` | Xray VLESS XHTTP REALITY |
| `3` | Xray Shadowsocks-2022 |
| `4` | 公式 Hysteria 2 サーバー |
| `5` | Xray + Hysteria 2 バンドル：Vision TCP 443、XHTTP TCP 8443、Hysteria 2 UDP 443、SS-2022 TCP/UDP 2053 |
| `6` | sing-box VLESS Vision REALITY |
| `7` | sing-box Shadowsocks-2022 |
| `8` | sing-box VLESS + Shadowsocks-2022 |
| `9` | sing-box Hysteria 2 |
| `10` | sing-box Vision + Hysteria 2 + Shadowsocks-2022（XHTTP なし） |
| `11` | ツールボックス：ベンチマーク、診断、Wallos、ホスト設定 |
| `12` | ノードパラメータとクライアント設定の表示 |
| `13` | マニュアル |
| `14` | スクリプト OTA、Xray Geo データ、コア単体アップグレード |
| `15` | 完全/部分アンインストール |
| `16` | ノード削除と環境の再初期化 |
| `17` | 月間トラフィック制限（vnStat）と現時点までの使用量表示 |
| `18` | SS-2022 IP/CIDR 許可リスト管理 |
| `19` | UI 言語：簡体中文、繁體中文、English、日本語、Русский、فارسی |
| `20` | **ワンクリック Reality**；`r` はエイリアス |
| `0` | 終了 |

### ツールボックス

ツールボックスには、既存のベンチマーク、IP 品質、SNI、WARP、Swap、バックアップ/復元、編集済み診断、プリフライト、サブスクリプションエクスポート機能がすべて保持されています。BBR/FQ チューニングサブメニュー（適用とロールバックのみ）、ホスト設定（IP プリファレンス、プレーン DNS、対応 DoT、実測 DNS 選択、対応 DoH、タイムゾーン/ロケール/NTP、ダウンロードソース設定）、Wallos インストール/更新/状態/バックアップも含まれます。BBR はオプトインであり、プロトコルインストール後に自動実行されることはありません。

ベンチマークと IP 品質オプションは、まず A-Box 検証済みミラー（`test-tools-mirror` Release）を試行し、`SHA256SUMS` エントリーと一致する場合にのみ実行します。ミラーが利用不可またはチェックサム不一致の場合、`ABOX_ALLOW_UNVERIFIED_UPSTREAM=1` が設定されている場合にのみ上流スクリプトにフォールバックします（未検証、SHA ピンなし）。それ以外の場合はスクリプトは実行されません。

Wallos はオプションのセルフホスト型サブスクリプショントラッカーです。インストーラーは OS とアーキテクチャを検出し、安定版 Wallos リリースと対応する Docker イメージを取得します。上流の取得に失敗した場合のみ固定 `wallos-mirror` リリースを使用します。バックアップは公開前にステージング・検証され、アップグレードはヘルスチェック失敗時にロールバックを試みます。Wallos はデフォルトで `127.0.0.1` にバインドします。リモートアクセスには HTTPS リバースプロキシまたは SSH トンネルを使用してください。平文 HTTP を全 IPv4 インターフェースに公開するには、明示的な `WALLOS_BIND_ADDRESS=0.0.0.0` オーバーライドと確認が必要です。サードパーティ製ベンチマークスクリプトの更新には、手動ワークフローディスパッチの承認が必要です。

BBR/FQ の変更が黙って適用されることはありません。DNS 測定は、現在の VPS から成功したライブテストクエリを用いてリゾルバをランク付けします。結果はそのテスト期間に固有のもので、普遍的なランキングではありません。DoT はアクティブなバックエンドが対応している場合にのみ有効化されます。systemd-resolved が DNS サーバー証明書を検証できるよう、上流 TLS 認証ホスト名を入力してください（例：`1.1.1.1#cloudflare-dns.com`、`8.8.8.8#dns.google`）。DoH は `dnscrypt-proxy` を使用し、対応パッケージ/systemd-resolved セットアップに制限されます。DNS とタイムゾーン設定にはロールバックパスがあります。

## コマンドライン使用法

リポジトリのファイル名は `install.sh` です。以下の curl 例では `A-Box.sh` として保存しますが、本スクリプトであればどちらのファイル名でも動作します。

スクリプトのあるディレクトリでコマンドを実行：

| コマンド | 目的 |
|---|---|
| `sudo bash A-Box.sh --help` | コマンドラインヘルプの表示 |
| `sudo bash A-Box.sh --lang zh` / `--lang zh-tw` / `--lang en` / `--lang ja` / `--lang ru` / `--lang fa` | UI 言語の設定とメニュー起動 |
| `sudo bash A-Box.sh --self-test` | 内蔵回帰/セルフテストの実行 |
| `sudo bash A-Box.sh --preflight` または `--dry-run` | 新規ノードをデプロイせずプリフライトチェックを実行 |
| `sudo bash A-Box.sh --status` | 管理設定とサービス状態の表示 |
| `sudo bash A-Box.sh --start` / `--stop` | 管理サービスの起動/停止 |
| `sudo bash A-Box.sh --version` | スクリプトビルドメタデータの表示 |
| `sudo bash A-Box.sh --export-backup-key /secure/path/A-Box-recovery.key` | リカバリキーを保護されたパスにエクスポート |
| `sudo bash A-Box.sh --convert-legacy-backup OLD.tar.gz [OUTPUT_DIR]` | レガシーバックアップを manifest v3 形式に変換 |

エクスポートしたリカバリキーとバックアップは保護してください。`--self-test` の合格は、対象ホストでのプリフライト、ライブインストール、クライアント相互運用テストの代わりにはなりません。

## システム要件

スクリプトには以下の環境向けの互換性パスが含まれています。実際の互換性は OS リリース、init システム、アーキテクチャ、依存関係、プロバイダーネットワーク、上流ダウンロードに依存します。

| 項目 | 要件 |
|---|---|
| OS ファミリー | Debian 10+、Ubuntu 20.04+、CentOS/RHEL/Rocky/AlmaLinux 8+、または Alpine Linux |
| init システム | systemd または OpenRC |
| CPU アーキテクチャ | amd64/x86_64 または arm64/aarch64 |
| 権限 | root または sudo |
| ネットワーク | システムパッケージリポジトリと必要な上流/GitHub リリースエンドポイントへのアクセス |
| スクリプト UI | 中国語、英語、ロシア語、ペルシア語のメニュー選択（レガシープロンプトの注記参照） |

対話型言語セレクタは、メインメニューと更新された操作メニューで中国語・英語・ロシア語・ペルシア語に対応しています。一部の古いプロトコル固有プロンプトはバイリンガルのままで、レガシーな中英表記を含む場合があります。

## 本番環境チェックリスト

1. スクリプトを確認し、信頼できるバージョン固定ソースを選択する。サードパーティミラーを盲信しない。
2. 対象 VPS でデプロイ前に `--self-test` と `--preflight` を実行する。
3. プロバイダーのファイアウォール/セキュリティグループ規則と、選択したプロトコル・ポート・クライアントの互換性を確認する。
4. リカバリキーを別途保管し、破壊的なメンテナンスの前に検証済みバックアップを保持する。
5. ノードを利用するネットワークから、実際の DNS・TLS・ALPN・SNI・到達性・クライアント動作を検証する。CI の合格だけでは、すべての VPS プロバイダー・OS・クライアントでの動作は保証されない。

## フィードバックとライセンス

- [GitHub Issues](https://github.com/alariclin/A-Box/issues)
- プルリクエスト歓迎。
- [Apache License 2.0](LICENSE) の下でリリース。
