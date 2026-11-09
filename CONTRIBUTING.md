# Contributing to A-Box

## Workflow

1. Fork https://github.com/alariclin/A-Box and create a branch off
   the current tip of `main`.
2. Make focused changes — one concern per pull request.
3. Verify before opening the PR (see below).
4. Open a pull request against `main`. `main` is branch-protected:
   changes land through pull requests, never by direct push.
5. Fill in the PR template: what changed, why, how it was tested.

Commit messages in this repository are title-only: the message is
exactly `update`, with no body.

## Before you submit

- Syntax check: `bash -n install.sh`
- Self-test gate (must end with `SELF_TEST_OK`):
  `bash install.sh --self-test > self-test.log 2>&1; echo rc=$?`
- If you touched a workflow, `bash -n` any shell it embeds is not
  enough — read the changed steps back in the diff.
- If you changed user-visible text, keep the six menu languages in
  sync (zh / en / ru / fa / zh-tw / ja). Do not ship a feature with
  only the Chinese strings filled in.
- Do not commit secrets, keys, real IPs, real domains or credentials.
  Test fixtures must use documentation-range addresses
  (e.g. `203.0.113.0/24`) and example values only.

## Releases

A-Box is distributed by commit pin, not by versioned releases: the
README links a 40-character commit SHA. The maintainer runs the
14-system install matrix on the VPS before a tip is published;
contributors do not need to run it. Do not open a release PR — the
maintainer handles publishing.

## Where things live

- `install.sh` — the whole product: single-file Bash installer and
  menu. Never `source` it in a test harness; it executes `main "$@"`
  unconditionally at the end.
- `docs/` — design and operations docs (`docs/SIGNING.md` for the
  Ed25519 mirror signing, `docs/GLOBAL-BEST.md` for the architecture
  vision).
- `mirrors/` — mirror metadata and the signing public keys.
- `scripts/` — maintainer-side helper scripts.
- `.github/workflows/` — CI and mirror-update workflows.
- `THIRD-PARTY-NOTICES` — license notices for bundled third-party
  software (sing-box is GPLv3; see that file before redistributing).
