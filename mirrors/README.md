# Release mirrors

Large binary archives belong in GitHub Releases rather than the Git tree.

## Core binaries

The stable core recovery endpoint is the Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/A-Box/releases/tag/core-binaries), with the fixed tag `core-binaries`. Keep this tag stable across routine script releases. The Release contains (1) fixed-name compatibility-pin assets used by normal installs and the final fallback, and (2) versioned assets for the latest official stable Xray, sing-box, and Hysteria releases. The installer checks upstream first and validates mirror assets against `SHA256SUMS` plus the actual binary version. An explicit version override may use a mirror asset only when its tag exactly matches the requested version; it never substitutes another tag. For an automatic latest-stable attempt, it tries the exact target tag in the versioned mirror before falling back to the fixed compatibility pin. The former versioned Release `core-mirrors-v171` has been removed; older installer copies that hard-code that tag can no longer download assets from it. New deployments must use `core-binaries`.

The compatibility pins configured in `install.sh` remain Xray `v26.7.28`, sing-box `v1.14.3`, and Hysteria `app/v2.13.0`. The official Xray Release metadata marks `v26.7.28` as a prerelease; it is intentionally retained as the compatibility pin and is not the latest stable tag. See the `CORE-VERSIONS` asset in this Release for the current version pointer. A newer installed core is never silently downgraded merely to match an older stable tag.

### Per-core update policy (2026-10-14)

- **Xray: `pinned`.** Manual updates only. Xray ≥`v26.9.8` requires an ML-KEM key share in the REALITY ClientHello and breaks sing-box, default mihomo configs, and Karing clients (see sing-box#4520, mihomo#3193). The installer never auto-tracks Xray latest; set `ABOX_XRAY_VERSION` for an explicit override.
- **sing-box / Hysteria: `auto-stable`.** The installer resolves the latest official stable release first (upstream API, then `CORE-VERSIONS` mirror metadata), falling back to the compatibility pin when unreachable. A stable release is only accepted after a 7-day cooldown (`ABOX_STABLE_COOLDOWN_DAYS`); cooling is necessary but not sufficient — the candidate still goes through binary verification, config check, and health gate. Override with `ABOX_SINGBOX_UPDATE_POLICY=pinned` / `ABOX_HYSTERIA_UPDATE_POLICY=pinned`, or pin an exact version via `ABOX_SINGBOX_VERSION` / `ABOX_HYSTERIA_APP_VERSION`.

### Rollback assets

The Release retains versioned assets for the previous-version rollback candidates — Xray `v26.6.27`, Hysteria `app/v2.12.3` (published in `core-binaries`; use `scripts/upload-rollback-binaries.sh` for future backfills) — so a failed upgrade can roll back without depending on upstream availability. These are candidates, not validated rollback versions: they must pass A-Box config and client regression tests before being treated as approved. Versioned filenames are immutable; never overwrite an existing asset.

### Pinned utilities (Argo / WARP)

The mirror also carries the two version-pinned helper binaries used by standalone features: `cloudflared-<version>-linux-<arch>` (Argo tunnels) and `wgcf_<version>_linux_<arch>` (WARP provisioning), for amd64 and arm64. Unlike sing-box and Hysteria they are pinned, not latest-tracking: the mirror refresh reads the pins (`CLOUDFLARED_VERSION`, `WGCF_VERSION`) from `install.sh`, downloads exactly those upstream releases, and verifies them like core assets (official digest, architecture, version probe where available). The installer tries the mirror copy first and falls back to the pinned official URL; either way, the downloaded bytes must match the SHA-256 pin compiled into `install.sh`.

## Wallos recovery

The stable Release name is `wallos-mirror`; asset names are fixed and contain no version suffix:

- `wallos-source.tar.gz` — source archive for the latest non-prerelease upstream release, including its license.
- `wallos-linux-amd64.tar.gz`, `wallos-linux-arm64.tar.gz` and `wallos-linux-armv7.tar.gz` — Docker archives tagged with the exact version recorded in the manifest.
- `wallos-manifest.txt` and `SHA256SUMS` — upstream tag, image tag, retrieval time, architecture, and checksums.

The Wallos workflow updates this Release with `--clobber`. The installer still tries the official release metadata and Docker Hub image first; it uses this recovery copy only after upstream retrieval fails. Wallos data backups are staged and validated before publication; Wallos binds to loopback by default.

## Benchmark and IP-quality tools

The stable Release name is `test-tools-mirror`; asset names also remain fixed:

- `bench.sh` — upstream VPS benchmark script.
- `Check.Place.sh` — upstream IP quality / streaming / route script.
- `YABS-LICENSE` and `IPQuality-LICENSE` — upstream license texts.
- `test-tools-manifest.txt` and `SHA256SUMS` — source URLs, retrieval time, validation results, and digests.

The toolbox tries the upstream script first, checks size, shebang, HTML error-page signatures and Bash syntax, displays SHA-256 and asks for confirmation. The mirror copy is only executed after its digest matches `SHA256SUMS`. These checks are not a complete security audit of third-party scripts.

## Updating mirrors

`.github/workflows/update-core-mirror.yml` runs weekly and can be dispatched manually; pull requests run the same publisher in a read-only dry run, while manual dispatch also defaults to a non-mutating dry run. Set `dry_run=false` only to publish manually. It downloads only each upstream repository's `releases/latest` asset set, rejects draft/prerelease tags, requires exact official URLs and GitHub-provided SHA-256 digests, validates archive structure and ELF architecture, and probes executable-reported versions where the CI runner can run that binary (native amd64 glibc builds). Cross-architecture and musl variants are not executed on the runner; their official digest and architecture are checked, and the installer revalidates the actual binary version on the target before installation. Versioned filenames are added without deleting old versioned assets. It updates `CORE-VERSIONS` and publishes `SHA256SUMS` last. If a versioned filename already exists with a different digest, the workflow fails instead of overwriting that rollback asset. `.github/workflows/update-mirrors.yml` separately refreshes Wallos weekly; benchmark/IP-quality scripts are refreshed only by manually dispatching it with `refresh_test_tool_mirror=true`. The checks detect corruption and mismatched versions but do not create an independent trust root or prove third-party code benign. `SHA256SUMS` is hosted in the same Release and is not a cryptographic signature.
