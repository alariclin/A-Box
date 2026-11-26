# Static anti-pattern gate — rules

Checker: `scripts/ci-check-anti-patterns.py` (pure Python 3, stdlib
only). Every rule below is grounded in a real, already-fixed defect;
no rule was invented from style preference. The checker fails closed
(exit 2) if the `run_self_tests()` / `main()` delimiters it relies on
for the self-test exclusion are missing.

## AP-01 — bare jq reading a live JSONC config

- **Source:** M-6, Gemini arbitration 2026-11-25
  (`~/workspace/finalcheck/gemini-review-20261125/ARBITRATION-20261125.md`
  L70, L139–141). Bare `jq` reads of `$cfg` at L42515/L42538 and of
  `xray_config_reality_flags` L24201–24202; the latter is now fixed
  (`jsonc_strip_comments "$cfg" | jq`).
- **Defect shape:** `jq` with a live config as a file operand —
  `$cfg`, `$config`, `$sb_cfg`, `/etc/sing-box/config.json`,
  `/usr/local/etc/xray/config.json`, `/etc/ddr/wallos-caddy.json` —
  without the read going through `jsonc_strip_comments`. JSONC
  comments break `jq`, so the read fails (or yields nothing) on any
  config the user has commented.
- **Correct form:** `jsonc_strip_comments "$cfg" | jq ...`, or read a
  stripped temp view (`$_jq_cfg`, `$_cfg_stripped`, `$stripped`,
  `$src_cfg`). The codebase idiom is strip-once into a temp view and
  then plain `jq` on the view.
- **Out of scope by construction:** stripped views; stdin / herestring
  / pipe input; jq-written temp/state files (`$tmp_cfg`, `$tmp`,
  `$tmp_json`, `$reg`, `$ROUTING_STATE_FILE`, `$applied_src`); a
  caller-supplied temp object (`$json_file` in `xray_api_add_inbound`).
- **Allowlist:** `AP01_ALLOWLIST` in the script, per function, each
  entry with the evidence for why that read is safe (file just
  installed from jq-generated output, …). 7 live-config reads on
  current main, all allowlisted, 0 violations. (Was 17 before the
  2026-11-26 AP-01 residual batch fixed 10: `_menu_info_collect` 6,
  `wallos_rebuild_state_from_live` 1, `_wallos_caddy_config_matches`
  2, `_recycle_port_rules_if_unused` 1; the remaining 7 are verified
  comment-free by construction.)

## AP-02 — bare `cmp` for NUL-byte validation

- **Source:** C-1 / `_manifest_rows_valid`,
  `~/workspace/finalcheck/final-review/fix-batch-20261122/PROGRESS.md`
  L1509–1515. `cmp -s -` was missing from Rocky/Alma/Fedora minimal
  images; the 14-system run went 9/14. Fix: tr+wc byte-count
  comparison, commit `6468ff7`, then 14/14.
- **Defect shape:** `cmp` with a stdin operand (`-` or `/dev/stdin`)
  and no nearby `command -v cmp` guard. The stdin form is the one
  used for NUL validation; plain file-vs-file `cmp -s --` is out of
  scope (it is a different use and is not gated here).
- **Correct form:** guard with `command -v cmp` (as the three
  self-test sites do), or use the tr+wc byte-count comparison.
- **Current main:** only 3 occurrences, all in self-test, all guarded
  (L69499, L69590, L69663, each with `if command -v cmp` directly
  above).

## AP-03 — curl following redirects without `--proto`/`--proto-redir`

- **Source:** M-2, GEO-F2, PROGRESS.md L1427. Fix: 45 redirecting
  curl lines given `--proto =https --proto-redir =https`.
- **Defect shape:** `curl` with `-L` / `--location` (including bundled
  flags such as `-fsSL`, and array form `args=(-sS -L ...)`) without
  both `--proto` and `--proto-redir`. A redirect may downgrade the
  request to plain http.
- **Correct form:** `curl -fsSL --proto =https --proto-redir =https
  <url>`. The flag lives at the array-construction site for
  `curl "${args[@]}"` (see `github_api_get`, L23190).
- **Out of scope:** curl without `-L` (26 invocations, e.g.
  `curl --help`, `curl -fsS4` IP lookups); `curl -fsSL <URL>` inside
  single-quoted i18n help text (L10986–10991, documentation, never
  executed — the checker strips single-quoted spans).
- **Current main:** 60 `curl ... -L ...` lines; all real redirecting
  curls carry both flags.

## AP-04 — RETURN trap without save/restore

- **Source:** C-2 / L10, PROGRESS.md L880–891, L1460. L10 installed
  `trap 'rm -rf -- "$asn_cache"...' RETURN` with no save/restore.
  Bash RETURN traps are a single global slot: the action refires on
  ancestor returns, and `$asn_cache` unbound under `set -u` killed
  SNI auto-select.
- **Defect shape:** `trap '...' RETURN` where the action neither
  restores the caller's saved trap nor clears the slot.
- **Correct form:** save first —
  `local _caller_trap=$(trap -p RETURN 2>/dev/null || true)` — then
  inside the action `eval "$_caller_trap"` when non-empty else
  `trap - RETURN`, and end the action with `true`.
- **Current main:** 11 `trap '...' RETURN` installs (L251, L21382,
  L33605, L34910, L35588, L43207, L43254, L45969, L46231, L51620,
  L51780), all with a `trap -p RETURN` save within the preceding
  lines and a restore in the action.

## AP-05 — mktemp template with a suffix after XXXXXX

- **Source:** H-6, Gemini arbitration L101–111. BusyBox `mktemp`
  rejects `mktemp ….XXXXXX.json` (rc=1); GNU accepts it. 8 places
  fixed.
- **Defect shape:** an `mktemp` template that contains `XXXXXX`
  followed by more characters (`.json`, `.bak`, …). Templates ending
  in `XXXXXX` (including 10-X forms such as `XXXXXXXXXX`) are valid.
- **Correct form:** keep the template ending in `XXXXXX` and add the
  suffix after creation (`mv` / rename), or use the bare template.
- **Current main:** 395 mktemp invocations; exactly 1 suffixed
  template — L13603 inside `_abox_mktemp_json_ok`, which is the H-6
  capability probe itself (it deliberately runs the suffixed template;
  failure is the signal). That is the single AP-05 allowlist entry.
  Self-test grep patterns mentioning suffixed templates (L71461,
  L71559) are strings, not invocations, and are not flagged.
