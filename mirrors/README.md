# Release mirrors

Large binary archives belong in GitHub Releases rather than the Git tree.

## Core binaries

The existing core recovery assets remain on the Release [`core-mirrors-v171`](https://github.com/alariclin/a-box/releases/tag/core-mirrors-v171). The installer checks the upstream release first and verifies downloaded mirror assets against that Release's `SHA256SUMS` before installation. Do not change the existing tag as part of routine script edits.

The current core pins configured in `install.sh` are Xray `v26.7.28`, sing-box `v1.14.2`, and Hysteria `app/v2.13.0`. These are software versions, not per-edit filenames.

## Wallos recovery

The stable Release name is `wallos-mirror`; asset names are fixed and contain no version suffix:

- `wallos-source.tar.gz` — source archive for the latest non-prerelease upstream release, including its license.
- `wallos-linux-amd64.tar.gz`, `wallos-linux-arm64.tar.gz` and `wallos-linux-armv7.tar.gz` — Docker archives tagged with the exact version recorded in the manifest.
- `wallos-manifest.txt` and `SHA256SUMS` — upstream tag, image tag, retrieval time, architecture, and checksums.

The Wallos workflow updates this Release with `--clobber`. The installer still tries the official release metadata and Docker Hub image first; it uses this recovery copy only after upstream retrieval fails.

## Benchmark and IP-quality tools

The stable Release name is `test-tools-mirror`; asset names also remain fixed:

- `bench.sh` — upstream VPS benchmark script.
- `Check.Place.sh` — upstream IP quality / streaming / route script.
- `YABS-LICENSE` and `IPQuality-LICENSE` — upstream license texts.
- `test-tools-manifest.txt` and `SHA256SUMS` — source URLs, retrieval time, validation results, and digests.

The toolbox tries the upstream script first, checks size, shebang, HTML error-page signatures and Bash syntax, displays SHA-256 and asks for confirmation. The mirror copy is only executed after its digest matches `SHA256SUMS`. These checks are not a complete security audit of third-party scripts.

## Updating mirrors

`.github/workflows/update-mirrors.yml` refreshes the stable Wallos and test-tool Releases on a schedule or manually. The workflow must be uploaded to GitHub and run successfully before its Release assets exist. Routine script edits should not create version-suffixed filenames or one-off Release names.
