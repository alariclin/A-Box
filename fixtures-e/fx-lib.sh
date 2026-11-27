#!/usr/bin/env bash
# E-leg shared fixture helpers (W5/W6/W7 observations, fix-matrix4-20261126).
# Each fixture extracts the REAL function bodies from the built install.sh
# (never a hand copy) and runs them against stubbed surroundings.
# Usage: source this file, then call fx_extract_* helpers.
# Environment: INSTALL_SH (default: <fixtures dir>/../install.sh).

FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-$FX_DIR/../install.sh}"

fx_fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
fx_pass() { printf 'PASS: %s\n' "$*"; return 0; }

# fx_extract_func <file> <funcname> <outfile>
# Extracts one top-level function (from its `name() {` line to the line
# just before the next top-level `name() {` definition).
fx_extract_func() {
    local file="$1" name="$2" out="$3" s e
    s=$(grep -n "^${name}() {" "$file" | head -1 | cut -d: -f1)
    [[ -n "$s" ]] || { printf 'fx_extract_func: %s not found in %s\n' "$name" "$file" >&2; return 1; }
    e=$(awk -v s="$s" 'NR > s && /^[A-Za-z_][A-Za-z0-9_]*[(][)] \{ *$/ { print NR - 1; exit }' "$file")
    [[ -n "$e" ]] || e=$(wc -l < "$file")
    sed -n "${s},${e}p" "$file" > "$out"
}

# fx_extract_until <file> <start-pattern> <end-pattern> <outfile>
# Extracts from the first line matching start-pattern (inclusive) to the
# line just before the first line matching end-pattern.
fx_extract_until() {
    local file="$1" sp="$2" ep="$3" out="$4" s e
    s=$(grep -nE "$sp" "$file" | head -1 | cut -d: -f1)
    [[ -n "$s" ]] || { printf 'fx_extract_until: start %s not found\n' "$sp" >&2; return 1; }
    # grep -E (not awk) for the end anchor: awk would read `\(` in the
    # pattern as a group, grep -E reads it as a literal paren.
    e=$(grep -nE "$ep" "$file" | awk -F: -v s="$s" '$1 > s { print $1 - 1; exit }')
    [[ -n "$e" ]] || e=$(wc -l < "$file")
    sed -n "${s},${e}p" "$file" > "$out"
}

# Standard i18n extraction: real tr_msg + tprintf from the built script.
fx_extract_i18n() {
    local out="$1"
    fx_extract_until "$INSTALL_SH" '^tr_msg\(\) {' '^tprintf\(\) {' "$out" || return 1
    fx_extract_until "$INSTALL_SH" '^tprintf\(\) {' '^proto_label\(\) {' "${out}.tprintf" || return 1
    cat "${out}.tprintf" >> "$out"
    rm -f -- "${out}.tprintf"
}

# Extract the global color definitions (00-header.sh block) so extracted
# functions can run under `set -u` like the real script does.
fx_extract_colors() {
    local out="$1"
    grep -E '^(GREEN|YELLOW|RED|CYAN|LBLW|NC|GRAY|BOLD|BLUE)=' "$INSTALL_SH" | head -20 > "$out"
}
fx_msg_stub() {
    cat <<'EOF_STUB'
msg() { printf '%s\n' "$*"; }
die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }
pause_return() { return 0; }
EOF_STUB
}
