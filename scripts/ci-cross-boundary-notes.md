# Cross-boundary function completeness — notes

Checker: `scripts/ci-check-cross-boundary.py` (pure Python 3, stdlib
only). It checks two directions:

- (a) the main script must not call a function defined only inside a
  heredoc (the H-7 pattern);
- (b) a heredoc-generated standalone script must not call a function
  defined only in the main script (it would fail at runtime, alone).

## Why functions defined on both sides are not violations

Each heredoc-generated script is standalone: it is written to disk and
run on its own, with no access to the main script's functions. Shared
helpers therefore have to be duplicated verbatim in main *and* in the
heredoc. A function defined on both sides is intentional sharing, not a
cross-boundary leak. On current main the duplicate map has 43
functions; representative examples:

- `__abox_normalize_managed_rule_line` — MAIN + EOF_ABOX_FW_RESTORE.
  The existing CI step "Verify normalize_managed_rule_line
  definitions" (BUG-28 + B-02) already requires exactly one definition
  in main and one in that heredoc; this checker agrees with it and
  does not duplicate its verdict.
- `acquire_abox_runtime_guard` — EOF_PROBE + EOF_GEO + EOF_TRAFFIC
  only (no main definition); each generated script carries its own
  copy.
- `load_state` — EOF_PROBE + EOF_TRAFFIC only.
- `depend` — the six OpenRC runscript heredocs (EOF_RC, EOF_WCADDY_RC,
  EOF_WCFTRC, EOF_ZRAM_RC and the OpenRC variants of EOF_SVC).
- `msg` — MAIN + EOF_GEO.

The full duplicate list is printed by `--verbose`.

## What counts as a heredoc script

Scope is derived from the file on every run, not hard-coded to four
names: a heredoc region is in scope when it has a shebang, or defines
at least one function, or is written (700/755) to a script path. That
yields 28 shell scripts on current main (181 heredoc regions total,
1132 functions, 34537 calls checked). Out of scope: systemd units,
fail2ban/logrotate/confd/YAML/JSON/text heredocs, and all Python
heredocs (`PY`, `PY_*`, `PYEOF`).

## Self-test fixtures

Definitions inside `run_self_tests()` (L69264) .. `main()` (L72180)
are test fixtures and mocks (stub `cat`/`grep`/`sed`/`curl`/`python3`/
`docker`/`swapon`/`ip6tables`/`chown`/`nft`, plus redefinitions of
`has_ipv6` and `systemd_available`) and are excluded from the MAIN
definition set. The delimiters match the script's own self-test
extraction (`sed -n '/^run_self_tests() {$/,/^main() {$/!p'`,
L69386). The checker fails closed (exit 2) if the delimiters are
missing.

## Transparent wrappers

A MAIN function whose body contains `command <same-name>` is a
transparent wrapper around the external command of the same name, not
a definition a heredoc script depends on. Verified instances:
`jq()` (MAIN L146) and `clear()` (MAIN L72427 — the SYD-B E0 wrapper
shadowing ncurses `clear`, delegating to `command clear` on a real
terminal). Such wrappers are exempt in direction (b).

## Lexer notes and limitations

- Call extraction uses a quote-aware shell lexer: single-quoted text,
  comments, `${...}` and arithmetic are not code.
- `$(...)` / backquotes inside an **unquoted** heredoc body run in MAIN
  at generation time and are attributed to MAIN; inside a **quoted**
  heredoc they are attributed to the heredoc.
- Inline `<<'PY_*'` blocks nested inside a shell heredoc are skipped.
- Known limitations (documented, not silently ignored): `eval` /
  `bash -c` / variable-indirect calls cannot be resolved statically
  and are not tracked.
