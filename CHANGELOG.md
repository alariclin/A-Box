# Changelog

All notable changes to A-Box are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This file
starts with the 2026-11-09 fix batch; earlier history was not tracked
in a changelog and is not reconstructed here.

## [Unreleased]

Base: tip `3352270` (`2026-11-07`). Fix batch of 2026-11-09
(GPT full review + Sydney real-device matrix + DeepSeek audit).

### Docs (block A1)

- `docs/SIGNING.md`: missing signing key is now documented as
  fail-closed — the CI signing step exits 1 when
  `ABOX_SIGNING_PRIVKEY_B64` is absent (`update-core-mirror.yml`,
  R6C19-02; Wallos manifests in `update-mirrors.yml`, R6C19-03) and
  the pre-publish gate refuses unsigned manifests. The previous
  "skips gracefully" wording contradicted both the workflows and the
  document's own Section 4, and is removed. The single exception is
  documented: the scheduled (non-manual) test-tools refresh logs a
  notice and skips signing.
- `docs/GLOBAL-BEST.md`: control-plane requirement corrected from
  Bash 4.3+ to Bash 4.4+, matching `install.sh`. Removed the
  `--preflight` flag, which does not exist as a CLI flag
  (`install.sh` has 0 occurrences); the real scriptable flags
  `--self-test` and `--status` remain listed.
- Added `THIRD-PARTY-NOTICES`: sing-box is GPLv3 (upstream
  https://github.com/SagerNet/sing-box), with Corresponding Source
  pointers and a written offer under GPLv3 section 6(b). A-Box itself
  remains Apache License 2.0 (`LICENSE`, unchanged).
- Added `SECURITY.md`, `CONTRIBUTING.md`, `CODEOWNERS`,
  `CODE_OF_CONDUCT.md`, GitHub issue templates (bug report, feature
  request) and a pull-request template (see below).

_Other blocks of this fix batch (workflows, rollback scripts,
`install.sh` fixes, translation dead keys) record their own entries
here when they land._
