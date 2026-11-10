# Release mirrors

Large binary archives belong in GitHub Releases rather than the Git tree.

## Core binaries

The stable core recovery endpoint is the Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/A-Box/releases/tag/core-binaries), with the fixed tag `core-binaries`. Keep this tag stable across routine script releases. Xray, sing-box and Hysteria all default to `auto-stable`; fixed-name compatibility assets are not the default installation path for Xray. When resolving a new automatic target, the installer tries official upstream stable-release metadata before current mirror metadata. Mirror assets must pass validation against `SHA256SUMS` and the actual binary version. If an upstream asset download fails, automatic recovery first tries the exact target tag in the versioned mirror, then the current verified mirror version, which may be older; there is no automatic fixed-pin fallback. Explicit version overrides and `pinned` targets may use mirror recovery only when the asset matches the selected tag exactly, never by substituting another tag. If no usable candidate remains, installation is refused. The former versioned Release `core-mirrors-v171` has been removed; older installer copies that hard-code that tag can no longer download assets from it. New deployments must use `core-binaries`.

The compatibility defaults are configured in `install.sh` by `ABOX_XRAY_DEFAULT_VERSION`, `ABOX_SINGBOX_DEFAULT_VERSION` and `ABOX_HYSTERIA_DEFAULT_VERSION`. An explicit `pinned` policy selects the corresponding default as its installation target; these defaults are not automatic recovery fallbacks. An explicit version override requests its own tag and takes precedence over policy, whether or not that tag matches a compatibility default. Historical mirror mappings do not guarantee that the corresponding versions remain available. See the `CORE-VERSIONS` asset in this Release for the current version pointer. For explicit overrides and `pinned` targets, mirror recovery never silently changes the selected version; automatic recovery may instead select the current verified mirror version. A newer installed core is never silently downgraded to match an older target: the upgrade path checks the version direction first and skips the upgrade (or refuses it) unless downgrade is explicitly allowed with `ABOX_ALLOW_CORE_DOWNGRADE=1`.

### Per-core update policy

- **Xray / sing-box / Hysteria: `auto-stable`.** All three default to the latest official stable release, excluding drafts and prereleases. There is no cooling-off period; adoption still requires binary verification, a config check and a health gate. New automatic targets are resolved from upstream stable-release metadata first, then current mirror metadata. If an upstream download fails, recovery tries the same-tag versioned mirror before the current verified mirror version, which may be older. If no usable upstream or mirror candidate remains, installation is refused rather than falling back automatically to a fixed compatibility pin. Xray >= `v26.9.8` introduces the REALITY ML-KEM ClientHello requirement; the `ABOX_XRAY_REALITY_MLKEM_MIN_VERSION` threshold is enforced separately, and client interoperability must still be verified.

Override policy with `ABOX_XRAY_UPDATE_POLICY`, `ABOX_SINGBOX_UPDATE_POLICY` or `ABOX_HYSTERIA_UPDATE_POLICY`. An explicit `pinned` policy selects the corresponding compatibility default configured in `install.sh`. Exact-version overrides use `ABOX_XRAY_VERSION`, `ABOX_SINGBOX_VERSION` or `ABOX_HYSTERIA_APP_VERSION` and take precedence over policy. Mirror recovery for explicit or pinned targets must match the selected tag exactly; it cannot silently substitute another version.

### No multi-version rollback store

After new assets have been verified and published, mirror refresh prunes superseded assets with `scripts/prune-core-mirror.sh`. The Release does not guarantee retention of previous-version rollback candidates and must not be treated as a multi-version rollback store. Versioned filenames are immutable; never overwrite an existing asset.

### Utilities (Argo / WARP)

The mirror also carries the two versioned helper binaries used by standalone features: `cloudflared-<version>-linux-<arch>` (Argo tunnels) and `wgcf_<version>_linux_<arch>` (WARP provisioning), for amd64 and arm64. cloudflared is pinned (the mirror refresh reads `CLOUDFLARED_VERSION` from `install.sh`), while wgcf tracks the upstream latest release: the mirror refresh resolves the latest ViRb3/wgcf release and the installer resolves it at runtime too. Both are verified like core assets (official digest, architecture, version probe where available). The installer tries the mirror copy first and falls back to the official release URL for the resolved version; either way, the downloaded bytes must match the SHA-256 digest from that release (API asset digest, or the release's checksums.txt).

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

`.github/workflows/update-core-mirror.yml` runs every 3 days and can be dispatched manually; pull requests run the same publisher in a read-only dry run, while manual dispatch also defaults to a non-mutating dry run. Set `dry_run=false` only to publish manually. It downloads each upstream core repository's `releases/latest` asset set. For utilities, it reads cloudflared's pinned version from `CLOUDFLARED_VERSION` in `install.sh` and resolves the latest ViRb3/wgcf release. It rejects draft/prerelease tags, requires exact official URLs and GitHub-provided SHA-256 digests, validates archive structure and ELF architecture, and probes executable-reported versions where the CI runner can run that binary (native amd64 glibc builds). Cross-architecture and musl variants are not executed on the runner; their official digest and architecture are checked, and the installer revalidates the actual binary version on the target before installation. Versioned filenames are immutable: if a versioned filename already exists with a different digest, the workflow fails instead of overwriting the existing asset. It updates `CORE-VERSIONS` and publishes `SHA256SUMS` last, then runs `scripts/prune-core-mirror.sh` to delete superseded assets; historical versions are not retained as a multi-version rollback archive. `.github/workflows/update-mirrors.yml` separately refreshes Wallos weekly; benchmark/IP-quality scripts are refreshed only by manually dispatching it with `refresh_test_tool_mirror=true`. The checks detect corruption and mismatched versions but do not create an independent trust root or prove third-party code benign. `SHA256SUMS` is hosted in the same Release and is not a cryptographic signature.
