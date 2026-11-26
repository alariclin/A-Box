#!/usr/bin/env bash
# A-Box modular build: assemble install.sh from src/ modules.
#
# Model: install.sh stays committed in the repo as a build artifact;
# src/*.sh is the only source. `bash build.sh` regenerates install.sh
# byte-identically (verified by `cmp` in CI and by the split leg's
# equivalence evidence). No timestamps, no randomness, no glob order:
# the module list below is fixed and authoritative.
#
# Each module file carries a header block delimited by
#   # ABOX-MODULE-BEGIN ... / # ABOX-MODULE-END
# which this script strips before concatenation. The header is
# attribution only and is never part of install.sh.
#
# Usage: bash build.sh [output-path]   (default: install.sh, in place)
# Exit non-zero on any guard failure (missing module, bad header,
# module not newline-terminated). Atomic: build to a temp file in the
# destination directory, chmod 644, then rename over the target.
set -euo pipefail

cd "$(dirname "$0")"

MODULES=(
    src/00-header.sh
    src/01-bootstrap.sh
    src/02-i18n.sh
    src/03-validate.sh
    src/04-registry.sh
    src/05-firewall.sh
    src/06-env-geo.sh
    src/07-core-deploy.sh
    src/08-argo-traffic.sh
    src/09-units-deploy.sh
    src/10-users-dns.sh
    src/11-dns-backup.sh
    src/12-wallos.sh
    src/13-clients.sh
    src/14-selftest-main.sh
)

OUT="${1:-install.sh}"
OUT_DIR="$(dirname "$OUT")"
TMP="$(mktemp "${OUT_DIR}/.install.sh.build.XXXXXX")"
trap 'rm -f -- "$TMP"' EXIT

for m in "${MODULES[@]}"; do
    [[ -f "$m" ]] || { printf 'build.sh: missing module: %s\n' "$m" >&2; exit 1; }
    # Exactly one header block, BEGIN before END, at the top of the file.
    [[ "$(grep -c '^# ABOX-MODULE-BEGIN ' "$m")" == 1 ]] || { printf 'build.sh: %s: expected exactly one ABOX-MODULE-BEGIN header\n' "$m" >&2; exit 1; }
    [[ "$(grep -c '^# ABOX-MODULE-END$' "$m")" == 1 ]] || { printf 'build.sh: %s: expected exactly one ABOX-MODULE-END header\n' "$m" >&2; exit 1; }
    [[ "$(grep -n '^# ABOX-MODULE-BEGIN ' "$m" | cut -d: -f1)" -lt "$(grep -n '^# ABOX-MODULE-END$' "$m" | cut -d: -f1)" ]] || { printf 'build.sh: %s: header markers out of order\n' "$m" >&2; exit 1; }
    # Module must end with a newline, or concatenation would glue lines.
    [[ -z "$(tail -c 1 "$m")" ]] || { printf 'build.sh: %s: module does not end with a newline\n' "$m" >&2; exit 1; }
    sed '/^# ABOX-MODULE-BEGIN /,/^# ABOX-MODULE-END$/d' "$m" >> "$TMP"
done

chmod 644 "$TMP"
mv -- "$TMP" "$OUT"
trap - EXIT
printf 'build.sh: wrote %s (%s modules)\n' "$OUT" "${#MODULES[@]}"
