# Release mirrors

Large binary archives belong in GitHub Releases rather than the Git tree.

## Core binaries

The stable core recovery endpoint is the Release [`A-Box Core Binary Mirrors`](https://github.com/alariclin/a-box/releases/tag/core-binaries), with the fixed tag `core-binaries`. Keep this tag stable across routine script releases. The Release contains (1) fixed-name compatibility-pin assets used by normal installs and the final fallback, and (2) versioned assets for the latest official stable Xray, sing-box, and Hysteria releases. The installer checks upstream first and validates mirror assets against `SHA256SUMS` plus the actual binary version. For an explicit latest-stable attempt, it tries the exact target tag in the versioned mirror before falling back to the fixed compatibility pin. The former versioned Release `core-mirrors-v171` has been removed; older installer copies that hard-code that tag can no longer download assets from it. New deployments must use `core-binaries`.

The compatibility pins configured in `install.sh` remain Xray `v26.7.28`, sing-box `v1.14.2`, and Hysteria `app/v2.13.0`. The official Xray Release metadata marks `v26.7.28` as a prerelease; it is intentionally retained as the compatibility pin and is not the latest stable tag. As verified on 2026-10-13, the official latest stable tags were Xray `v26.3.27`, sing-box `v1.14.3`, and Hysteria `app/v2.13.0`; the `CORE-VERSIONS` Release asset is the workflow-maintained latest-stable pointer. A newer installed core is never silently downgraded merely to match an older stable tag.

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

`.github/workflows/update-core-mirror.yml` runs weekly and can be dispatched manually. It downloads only each upstream repository's `releases/latest` asset set, rejects draft/prerelease tags, requires exact official URLs and GitHub-provided SHA-256 digests, validates archive structure and the executable's reported version, and adds versioned filenames without deleting old versioned assets. It updates `CORE-VERSIONS` and publishes `SHA256SUMS` last. If a versioned filename already exists with a different digest, the workflow fails instead of overwriting that rollback asset. `.github/workflows/update-mirrors.yml` separately refreshes Wallos weekly; benchmark/IP-quality scripts are refreshed only by manually dispatching it with `refresh_test_tool_mirror=true`. The checks detect corruption and mismatched versions but do not create an independent trust root or prove third-party code benign. `SHA256SUMS` is hosted in the same Release and is not a cryptographic signature.
