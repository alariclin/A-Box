#!/usr/bin/env bash
# Run every E-leg fixture against the current built install.sh.
# Rebuilds first (src/ is the only source), then runs each fixture and
# reports PASS/FAIL per observation. Exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."
bash build.sh || { printf 'BUILD FAILED\n' >&2; exit 1; }
failures=0
for f in fixtures-e/fx-*.sh; do
    [[ "$f" == 'fixtures-e/fx-lib.sh' || "$f" == 'fixtures-e/fx-run-all.sh' ]] && continue
    printf '=== %s ===\n' "$f"
    if bash "$f"; then :; else failures=$((failures + 1)); fi
done
if (( failures == 0 )); then printf 'ALL E-LEG FIXTURES PASS\n'; exit 0; fi
printf '%s fixture(s) FAILED\n' "$failures" >&2
exit 1
