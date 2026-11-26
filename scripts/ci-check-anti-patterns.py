#!/usr/bin/env python3
"""Static anti-pattern gate (A-Box CI gate 2).

Five rules, each grounded in a real confirmed defect from the
arbitration records (see scripts/ci-anti-pattern-rules.md for the
per-rule source issue, defect shape and correct form):

  AP-01  bare jq reading a live JSONC config (M-6)
  AP-02  cmp reading from stdin without a `command -v cmp` guard
         (C-1 / _manifest_rows_valid)
  AP-03  curl following redirects without --proto/--proto-redir
         (M-2, GEO-F2)
  AP-04  RETURN trap without the save/restore idiom (C-2 / L10)
  AP-05  mktemp template with a suffix after XXXXXX (H-6)

Allowlist policy: every exemption is a per-item entry in the
ALLOWLIST tables below, keyed by enclosing function + a regex on the
offending line, with a code-evidence reason.  No whole-class
exemptions, no blank reasons.  A new occurrence of the same shape in
a function without an entry still fails.

Usage: python3 scripts/ci-check-anti-patterns.py [install.sh] [--verbose]
Exit: 0 pass, 1 violations found, 2 checker error.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

DEF_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
TOP_DEF_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
HEREDOC_RE = re.compile(r"<<-?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")

# ---------------------------------------------------------------- AP-01
# Live JSONC configs: user-editable files that may contain comments.
# Anything else jq reads (stripped views $_jq_cfg/$_cfg_stripped/
# $stripped/$src_cfg/$_cfg09v, stdin/herestring/pipe input, jq-written
# temp/state files such as $tmp_cfg/$tmp/$tmp_json/$reg/
# $ROUTING_STATE_FILE) is out of scope by construction; the survey
# behind this set is documented in ci-anti-pattern-rules.md (AP-01).
LIVE_CONFIG_VARS = {"$cfg", "$config", "$sb_cfg"}
LIVE_CONFIG_PATHS = {
    "/etc/sing-box/config.json",
    "/usr/local/etc/xray/config.json",
    "/etc/ddr/wallos-caddy.json",
}
# function -> [(regex, reason)] for the residual bare reads that
# exist in current main.  Each entry names its code evidence; see
# ci-anti-pattern-rules.md.  New occurrences elsewhere still fail.
AP01_ALLOWLIST = {
    "standalone_preserve_restore": [
        (r"""jq\s.*['"]?\$cfg(?![A-Za-z0-9_])""",
         "post-restore inventory/count only; parse failure tolerated "
         "(2>/dev/null || printf ''); residual bare read, recorded "
         "here -- fix belongs to a later batch, not G1"),
        (r"""--slurpfile now ['"]?\$cfg(?![A-Za-z0-9_])""",
         "post-restore drop/conflict report only; parse failure "
         "tolerated (2>/dev/null || printf ''); residual bare read, "
         "recorded here -- fix belongs to a later batch, not G1"),
    ],
    "_menu_info_collect": [
        (r"""jq\s.*['"]?/etc/sing-box/config\.json(?![A-Za-z0-9_./-])""",
         "best-effort status/menu display; failure yields an empty "
         "string, no control-flow consequence; residual bare read, "
         "recorded here -- fix belongs to a later batch, not G1"),
        (r"""jq\s.*['"]?/usr/local/etc/xray/config\.json(?![A-Za-z0-9_./-])""",
         "best-effort status/menu display (SNI line); failure yields "
         "an empty string, no control-flow consequence; residual "
         "bare read, recorded here -- fix belongs to a later batch, "
         "not G1"),
    ],
    "_recycle_port_rules_if_unused": [
        (r"""jq\s.*['"]?\$sb_cfg(?![A-Za-z0-9_])""",
         "parse probe; failure returns 0 and the caller treats the "
         "port as unused (best-effort cleanup, no die); residual "
         "bare read, recorded here -- fix belongs to a later batch, "
         "not G1"),
    ],
    "deploy_singbox": [
        (r"""jq empty /etc/sing-box/config\.json""",
         "validation immediately after build_singbox_config wrote "
         "this file in the same function (pure jq output); no "
         "comment can be present at this point"),
    ],
    "users_xray_ensure_tags": [
        (r"""jq\s.*['"]?\$cfg(?![A-Za-z0-9_])""",
         "$cfg was just atomically installed from jq-generated $tmp "
         "by users_commit_cfg in this same function; comment-free "
         "by construction"),
    ],
    "users_sb_ensure_tags": [
        (r"""jq\s.*['"]?\$cfg(?![A-Za-z0-9_])""",
         "sing-box twin of users_xray_ensure_tags: $cfg was just "
         "atomically installed from jq-generated $tmp by "
         "users_commit_cfg in this same function; comment-free by "
         "construction; the read is a post-commit warning probe "
         "(failure only suppresses the warning)"),
    ],
    "users_hot_remove": [
        (r"""jq\s.*['"]?\$cfg(?![A-Za-z0-9_])""",
         "in-code comment at the site: every path reaching here "
         "passed install_file_atomically \"$tmp\" \"$cfg\" with "
         "jq-generated output in this same invocation, so no "
         "comment can be present"),
    ],
    "wallos_rebuild_state_from_live": [
        (r"""jq\s.*['"]?/etc/ddr/wallos-caddy\.json(?![A-Za-z0-9_./-])""",
         "file is jq-generated by _wallos_write_caddy_config "
         "(tmp_json built by jq, installed atomically); parse "
         "failure tolerated (2>/dev/null || true)"),
    ],
    "_wallos_caddy_config_matches": [
        (r"""jq\s.*['"]?\$cfg(?![A-Za-z0-9_])""",
         "local cfg='/etc/ddr/wallos-caddy.json'; the file is "
         "jq-generated by _wallos_write_caddy_config (tmp_json "
         "built by jq, installed atomically); parse failure "
         "returns 1 (no-match), no die"),
    ],
}

# ---------------------------------------------------------------- AP-02
# cmp with a stdin operand ('-' or /dev/stdin) is the exact construct
# the C-1 fix removed (cmp is absent from Rocky/Alma/Fedora minimal
# images).  File-vs-file cmp is NOT in scope (unchanged by that fix).
AP02_ALLOWLIST = {}  # no bare stdin-cmp may remain unguarded

# ---------------------------------------------------------------- AP-05
# The only suffixed mktemp template in main is the H-6 capability
# probe itself, which tests that exact template on purpose.
AP05_ALLOWLIST = {
    "_abox_mktemp_json_ok": [
        (r"""mktemp /tmp/A-Box-mktemp-probe\.XXXXXX\.json""",
         "capability probe by design: it runs the suffixed template "
         "to detect BusyBox mktemp (rc=1) vs GNU (rc=0); the probe "
         "failing IS the signal, and it returns 1 on failure"),
    ],
}


def find_heredocs(lines):
    regions = []
    i = 0
    while i < len(lines):
        m = HEREDOC_RE.search(lines[i])
        if m:
            tag = m.group(1)
            end = None
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == tag:
                    end = j
                    break
            if end is not None:
                regions.append((i, end))
                i = end + 1
                continue
        i += 1
    return regions


def logical_lines(lines):
    """Join backslash continuations and trailing |/&&/|| continuations.

    Returns [(start_lineno_1based, text)].  Lines inside a heredoc
    body are still separate physical lines except for the same joins.
    """
    out = []
    i = 0
    while i < len(lines):
        start = i + 1
        buf = lines[i]
        while True:
            stripped = buf.rstrip()
            if stripped.endswith("\\") and i + 1 < len(lines):
                i += 1
                buf = stripped[:-1] + " " + lines[i]
                continue
            if re.search(r"(\|\||&&|\|)\s*$", stripped) \
                    and i + 1 < len(lines) \
                    and lines[i + 1].strip() != "":
                # A pipeline/logic line continued on the next line
                # (no backslash).  Only join when the next line does
                # not start a new statement keyword.
                nxt = lines[i + 1].strip()
                if not re.match(
                        r"(if|then|elif|else|fi|for|while|do|done|"
                        r"case|esac|return|exit|local|declare)\b", nxt):
                    i += 1
                    buf = buf + " " + lines[i]
                    continue
            break
        out.append((start, buf))
        i += 1
    return out


def strip_sq_keep_dq(line):
    """Remove comments; keep operands, drop program text.

    Rules AP-01/AP-02/AP-05 need the operands (``"$cfg"``,
    ``"$tmp/fb-out"``, ``"$dir/.A-Box-owner.XXXXXX"``), so a quoted
    span whose content is a single simple token is replaced by that
    token.  Any other quoted span (jq programs, help text, grep
    patterns -- all contain spaces or ``$``) becomes the placeholder
    ``__SQ__`` so token positions are preserved: without it, a
    stripped jq program makes the parser mistake the first file
    operand for the program.
    """
    out = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "'":
            j = line.find("'", i + 1)
            if j == -1:
                break
            inner = line[i + 1:j]
            # Single-quoted text is literal: a '$' inside is not a
            # variable, so only a plain token counts as an operand.
            if inner and not re.search(r"[\s$`]", inner):
                out.append(inner)
            else:
                out.append(" __SQ__ ")
            i = j + 1
            continue
        if ch == '"':
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            inner = line[i + 1:j]
            # Double-quoted "$var" is a real operand; "$(...)" is code.
            if inner and not re.search(r"[\s`]", inner) \
                    and "$(" not in inner:
                out.append(inner)
            else:
                out.append(" ")
            i = j + 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def strip_strings_comments(line):
    """Remove single-quoted spans, double-quoted spans and comments.

    Double-quoted spans are dropped whole (their $(...) contents are
    code, but every rule here only needs the unquoted flags/words).
    Returns the cleaned line.
    """
    out = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "'":
            j = line.find("'", i + 1)
            if j == -1:
                break
            i = j + 1
            continue
        if ch == '"':
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            i = j + 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def func_map(lines, regions):
    """Map line numbers to the enclosing top-level function name."""
    defs = []
    for i, ln in enumerate(lines):
        if TOP_DEF_RE.match(ln) and not any(
                s < i < e for s, e in regions):
            defs.append((i + 1, TOP_DEF_RE.match(ln).group(1)))
    def func_of(ln):
        cur = "TOPLEVEL"
        for start, name in defs:
            if start <= ln:
                cur = name
            else:
                break
        return cur
    return func_of


# ------------------------------------------------------------ shared bits
def allowlisted(allowlist, func, line):
    """Return the reason when (func, line) matches an allowlist entry."""
    for pattern, reason in allowlist.get(func, []):
        if re.search(pattern, line):
            return reason
    return None


def _balanced_end(line, start, open_ch, close_ch):
    """End index (exclusive) of the bracket opened at start, or None."""
    depth = 0
    i = start
    while i < len(line):
        ch = line[i]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


BOUNDARY = {"|", "||", "&&", ";", "&", "(", ")", "{", "}", "<",
            ">", ">>", "<<", "<<<", "$(", "`", "="}


def tokenize_words(line):
    """Split a cleaned line into words and boundary tokens.

    ``${...}`` stays one word; ``$(``, backticks, ``; & | ( ) { }``,
    ``< >`` and ``=`` are command boundaries (emitted as tokens so a
    command parser can stop at them).  The cleaned line has no quotes
    left (see strip_sq_keep_dq / strip_strings_comments).
    """
    words = []
    cur = []
    i = 0
    n = len(line)

    def flush():
        if cur:
            words.append("".join(cur))
            del cur[:]

    while i < n:
        ch = line[i]
        if ch.isspace():
            flush()
            i += 1
            continue
        if line.startswith("${", i):
            end = _balanced_end(line, i + 1, "{", "}")
            if end is None:
                cur.append(ch)
                i += 1
                continue
            flush()
            words.append(line[i:end])
            i = end
            continue
        three = line[i:i + 3]
        two = line[i:i + 2]
        if three == "<<<":
            flush()
            words.append("<<<")
            i += 3
            continue
        if two in ("||", "&&", ">>", "<<", "$("):
            flush()
            words.append(two)
            i += 2
            continue
        if ch in ";|&(){}<>=" or ch == "`":
            flush()
            words.append(ch)
            i += 1
            continue
        cur.append(ch)
        i += 1
    flush()
    return words


# ---------------------------------------------------------------- AP-01
def jq_file_operands(cleaned):
    """Extract (operand, index) pairs for one logical line's jq calls.

    Parses jq's CLI: skips flags and option values; the first
    non-option word is the program; later non-option words (up to the
    next command boundary) are file operands; --slurpfile/--rawfile
    values and ``< file`` redirects are file operands too.  A bare
    ``jq`` after ``command -v`` is an availability probe, not a call.
    Returns [] when the line has no jq invocation.
    """
    words = tokenize_words(cleaned)
    operands = []
    i = 0
    while i < len(words):
        if words[i] == "jq":
            # `command -v jq` probes for the binary; not a call.
            if i >= 2 and words[i - 2] == "command" \
                    and words[i - 1] in ("-v", "-V"):
                i += 1
                continue
        elif words[i] == "command" and i + 1 < len(words) \
                and words[i + 1] == "jq":
            i += 1  # now at 'jq'
        else:
            i += 1
            continue
        i += 1  # skip 'jq'
        program_seen = False
        while i < len(words):
            w = words[i]
            if w in BOUNDARY:
                if w == "<":
                    if i + 1 < len(words) and words[i + 1] == "<":
                        # << / <<< heredoc/herestring: skip it + word.
                        j = i + 1
                        while j < len(words) and words[j] == "<":
                            j += 1
                        i = j + 1
                        continue
                    if i + 1 < len(words):
                        operands.append((words[i + 1], i + 1))
                    i += 2
                    continue
                break
            if w.startswith("--slurpfile") or w.startswith("--rawfile"):
                if i + 2 < len(words):
                    operands.append((words[i + 2], i + 2))
                i += 3
                continue
            if w.startswith("--arg") or w.startswith("--argjson"):
                i += 3  # option, NAME, VALUE
                continue
            if w in ("--from-file", "-f"):
                i += 2  # program file, not a config read
                program_seen = True
                continue
            if w.startswith("-") and w != "-":
                i += 1
                continue
            if not program_seen:
                program_seen = True
                i += 1
                continue
            operands.append((w, i))
            i += 1
    return operands


def _norm_operand(word):
    word = word.strip("\"'")
    word = re.sub(r"^\$\{([^}]*)\}$", r"$\1", word)
    return word


def check_ap01(logical, func_of, verbose):
    """Bare jq reading a live JSONC config."""
    violations = []
    checked = 0
    for lineno, raw in logical:
        cleaned = strip_sq_keep_dq(raw)
        if "jq" not in cleaned:
            continue
        # A jq program in a single-quoted string is documentation
        # (e.g. tr_msg help text); strip_strings_comments removed it.
        if "jsonc_strip_comments" in cleaned:
            # Same pipeline: strip feeds jq (pipe or process subst).
            if re.search(r"jsonc_strip_comments.*\|.*\bjq\b", cleaned) \
                    or re.search(r"<\(jsonc_strip_comments", cleaned) \
                    or re.search(r"jsonc_strip_comments[^|]*\bjq\b",
                                 cleaned):
                continue
        for operand, _idx in jq_file_operands(cleaned):
            norm = _norm_operand(operand)
            if norm not in LIVE_CONFIG_VARS \
                    and norm not in LIVE_CONFIG_PATHS:
                continue
            checked += 1
            func = func_of(lineno)
            reason = allowlisted(AP01_ALLOWLIST, func, raw)
            if reason:
                if verbose:
                    print(f"  AP-01 allowlisted L{lineno} [{func}]: "
                          f"{reason[:80]}")
                continue
            violations.append(
                f"AP-01 L{lineno} [{func}]: bare jq reads live JSONC "
                f"config {norm}; pipe it through jsonc_strip_comments "
                f"first (M-6) :: {raw.strip()[:140]}")
    return violations, checked


# ---------------------------------------------------------------- AP-02
def check_ap02(logical, lines, verbose):
    """cmp reading from stdin without a `command -v cmp` guard."""
    violations = []
    for lineno, raw in logical:
        cleaned = strip_sq_keep_dq(raw)
        m = re.search(
            r"(^|[;&|]\s*|if\s+|!\s*|then\s+|do\s+|\(\s*|\$\()\s*"
            r"cmp\s+(.*)$", cleaned)
        if not m:
            continue
        rest = m.group(2)
        operands = [t.strip("\"'") for t in rest.split()]
        operands = [t for t in operands
                    if t not in ("-s", "-l", "--silent", "--")]
        if "-" not in operands and "/dev/stdin" not in operands:
            continue
        guard = any("command -v cmp" in lines[j]
                    for j in range(max(0, lineno - 16), lineno - 1))
        if guard:
            if verbose:
                print(f"  AP-02 guarded L{lineno}: "
                      f"command -v cmp within 15 lines above")
            continue
        violations.append(
            f"AP-02 L{lineno}: cmp reads stdin ('-' operand) without "
            f"a `command -v cmp` guard; cmp is absent from Rocky/Alma/"
            f"Fedora minimal images -- use tr+wc byte comparison "
            f"(C-1) :: {raw.strip()[:140]}")
    return violations


# ---------------------------------------------------------------- AP-03
REDIRECT_FLAG_RE = re.compile(r"-[A-Za-z]*L[A-Za-z]*$")


def _curl_redirects(cleaned):
    """True when the logical line invokes curl following redirects."""
    for m in re.finditer(r"(?<![A-Za-z0-9_-])curl(?![A-Za-z0-9_-])",
                         cleaned):
        rest = cleaned[m.end():]
        # Only the flags before the first URL/operand matter; scan
        # the whole rest: --proto pins are on the same line anyway.
        for w in rest.split():
            if w in ("--location", "--location-trusted"):
                return True
            if w.startswith("--"):
                continue
            if REDIRECT_FLAG_RE.match(w):
                return True
            if w.startswith("-") and "L" in w[1:] \
                    and re.match(r"^-[A-Za-z]+$", w):
                return True
    return False


def check_ap03(logical, verbose):
    """curl following redirects without --proto/--proto-redir."""
    violations = []
    for lineno, raw in logical:
        cleaned = strip_strings_comments(raw)
        if "curl" not in cleaned and "args=(" not in cleaned:
            continue
        if "curl" in cleaned and not _curl_redirects(cleaned):
            continue
        if "curl" not in cleaned:
            # Array form: args=(-sS -L ...); the -L lives in the array.
            if not re.search(r"=\([^)]*-[A-Za-z]*L[A-Za-z]*[^)]*\)",
                             cleaned):
                continue
        if "--proto" in cleaned and "--proto-redir" in cleaned:
            continue
        violations.append(
            f"AP-03 L{lineno}: curl follows redirects (-L/--location) "
            f"without --proto/--proto-redir; a redirect may downgrade "
            f"to http (M-2, GEO-F2) :: {raw.strip()[:140]}")
    return violations


# ---------------------------------------------------------------- AP-04
def check_ap04(lines, verbose):
    """RETURN trap without the save/restore idiom."""
    violations = []
    for i, ln in enumerate(lines):
        s = ln.strip()
        m = re.match(r"""trap\s+'([^']*)'\s+RETURN\b""", s) or \
            re.match(r"""trap\s+"([^"]*)"\s+RETURN\b""", s)
        if not m:
            continue
        lineno = i + 1
        action = m.group(1)
        save = any("trap -p RETURN" in lines[j]
                   for j in range(max(0, i - 15), i))
        restore = ("trap - RETURN" in action) or \
            ("eval" in action and "caller_trap" in action)
        if save and restore:
            if verbose:
                print(f"  AP-04 ok L{lineno}: caller trap saved and "
                      f"restored in the action")
            continue
        missing = []
        if not save:
            missing.append("no `trap -p RETURN` save above")
        if not restore:
            missing.append("action never restores/clears the trap")
        violations.append(
            f"AP-04 L{lineno}: bare RETURN trap ({'; '.join(missing)}); "
            f"RETURN traps are a single global slot -- a lingering "
            f"action refires on ancestor returns and is fatal under "
            f"set -u (C-2/L10) :: {s[:140]}")
    return violations


# ---------------------------------------------------------------- AP-05
def check_ap05(logical, func_of, verbose):
    """mktemp template with a suffix after XXXXXX (BusyBox rejects)."""
    violations = []
    for lineno, raw in logical:
        cleaned = strip_sq_keep_dq(raw)
        for m in re.finditer(r"(?<![A-Za-z0-9_-])mktemp(?![A-Za-z0-9_-])",
                             cleaned):
            rest = cleaned[m.end():]
            toks = tokenize_words(rest)
            args = [t for t in toks
                    if t not in BOUNDARY and not t.startswith("-")]
            if not args:
                continue
            template = args[0].strip("\"'")
            if "XXXXXX" not in template:
                continue
            if re.search(r"X{6,}$", template):
                continue
            func = func_of(lineno)
            reason = allowlisted(AP05_ALLOWLIST, func, raw)
            if reason:
                if verbose:
                    print(f"  AP-05 allowlisted L{lineno} [{func}]: "
                          f"{reason[:80]}")
                continue
            violations.append(
                f"AP-05 L{lineno} [{func}]: mktemp template "
                f"'{template}' has a suffix after XXXXXX; BusyBox "
                f"mktemp requires the template to end with XXXXXX "
                f"(H-6) :: {raw.strip()[:140]}")
    return violations


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else Path("install.sh")
    verbose = "--verbose" in argv
    if not path.is_file():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2
    lines = path.read_text(encoding="utf-8").splitlines()
    regions = find_heredocs(lines)
    func_of = func_map(lines, regions)
    logical = logical_lines(lines)

    all_violations = []
    v01, n01 = check_ap01(logical, func_of, verbose)
    v02 = check_ap02(logical, lines, verbose)
    v03 = check_ap03(logical, verbose)
    v04 = check_ap04(lines, verbose)
    v05 = check_ap05(logical, func_of, verbose)
    counts = {"AP-01": (len(v01), n01), "AP-02": (len(v02), None),
              "AP-03": (len(v03), None), "AP-04": (len(v04), None),
              "AP-05": (len(v05), None)}
    all_violations = v01 + v02 + v03 + v04 + v05

    if verbose:
        for rule, (n_viol, n_checked) in sorted(counts.items()):
            extra = f", {n_checked} live-config reads examined" \
                if n_checked is not None else ""
            print(f"  {rule}: {n_viol} violation(s){extra}")

    if all_violations:
        print("ANTI-PATTERN GATE FAILED:")
        for viol in all_violations:
            print(f"  ERROR: {viol}")
        return 1
    print(f"OK: anti-pattern gate passed "
          f"(AP-01 {n01} live-config reads clean; AP-02/03/04/05 clean)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
