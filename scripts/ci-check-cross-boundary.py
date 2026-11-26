#!/usr/bin/env python3
"""Cross-boundary function completeness check (A-Box CI gate 1).

Verifies that no shell function is called from a place where its
definition is unavailable at run time:

  (a) the main script (install.sh) must not call a function that is
      defined ONLY inside a heredoc-generated standalone script
      (the H-7 pattern: ``service_is_abox_managed`` was defined only
      in the EOF_PROBE socket_probe.sh heredoc, yet two main-script
      call sites used it -> ``command not found`` at run time);
  (b) a heredoc-generated standalone script must not call a function
      that is defined ONLY in the main script (the generated script
      runs standalone and never sources install.sh).

Design notes (see also the roadmap step-3 G1 leg notes):

* Scope is derived from the file itself, never hard-coded to four
  heredoc names.  Every heredoc is enumerated; a block is treated as
  a standalone shell script when its body starts with a shell shebang
  or defines at least one shell function (or is written with mode
  700/755 to a script path).  systemd units, OpenRC *unit* text
  without functions, fail2ban/logrotate configs, YAML/JSON templates
  and plain text are out of scope and are listed with --verbose.
  Python heredocs (tags PY, PY_*, PYEOF) are excluded: they are not
  shell code.
* A function defined on BOTH sides (main + heredoc) is intentional
  sharing, not a violation: each generated script is standalone, so
  shared helpers are duplicated verbatim (same body) in main and in
  the heredoc, and each side closes over its own copy.  The checker
  derives this duplicate map from the code on every run; the
  per-function reasons live in scripts/ci-cross-boundary-notes.md.
  The existing CI step "Verify normalize_managed_rule_line
  definitions" (BUG-28 + B-02) is the precedent for this: that
  function is defined once in main and once in the
  EOF_ABOX_FW_RESTORE closure.
* Definitions that exist ONLY inside run_self_tests() are test
  fixtures/mocks (stub ``cat``/``grep``/``curl``/``docker`` ...), not
  runtime main-script functions, so they are excluded from the main
  definition set.  The self-test range is delimited exactly the way
  the script's own self-test extracts it: ``^run_self_tests() {$``
  .. ``^main() {$``.
* A main-script function whose body delegates to the external command
  of the same name (``command <name>``) is a transparent wrapper
  (today: ``jq()``), so a heredoc calling that name resolves to the
  system binary and is not a violation.
* Call extraction is a small quote-aware shell lexer: single-quoted
  text, comments, ``${...}`` and arithmetic are not code; ``$(...)``
  and backquotes inside an *unquoted* heredoc body run in main
  context at generation time and are attributed to MAIN, while the
  same constructs inside a *quoted* heredoc body run in the generated
  script and are attributed to the heredoc.  Inline Python blocks
  (``<<'PY_*'``) nested inside a shell heredoc are skipped.
* Known static-analysis limits (documented, not silent): ``eval`` /
  ``bash -c`` / variable-indirect calls cannot be resolved; a
  ``case`` pattern word is never treated as a call.

Usage: python3 scripts/ci-check-cross-boundary.py [install.sh] [--verbose]
Exit: 0 pass, 1 violations found, 2 checker error.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

DEF_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
TOP_DEF_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
HEREDOC_RE = re.compile(r"<<-?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
PY_TAG_RE = re.compile(r"^PY(_[A-Za-z0-9_]+)?$|^PYEOF$")
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SELFTEST_START_RE = re.compile(r"^run_self_tests\(\) \{$")
SELFTEST_END_RE = re.compile(r"^main\(\) \{$")

# First words that are shell syntax / builtins, never a call to an
# install.sh function.  `command` is handled separately (the word
# after it, minus flags, IS a call).
KEYWORDS = {
    "if", "then", "elif", "else", "fi", "for", "while", "until", "do",
    "done", "case", "esac", "select", "in", "time", "coproc",
    "function", "!", "[[", "]]", "test", "[", "echo", "printf",
    "local", "declare", "typeset", "export", "readonly", "return",
    "exit", "break", "continue", "shift", "set", "unset", "source",
    ".", "eval", "exec", "builtin", "trap", "umask", "cd", "pwd",
    "true", "false", ":", "let", "read", "getopts", "alias",
    "unalias", "jobs", "fg", "bg", "wait", "kill", "disown",
    "history", "fc", "dirs", "pushd", "popd", "enable", "shopt",
    "caller", "mapfile", "readarray", "compgen", "complete",
    "compopt", "logout", "suspend", "ulimit",
}
DECL_BUILTINS = {"local", "declare", "typeset", "export", "readonly"}
LEAD_KEYWORDS_RE = re.compile(r"(if|then|elif|else|while|until|do|!|time)\s+")
FOR_LOOP_RE = re.compile(r"for\s+[A-Za-z_][A-Za-z0-9_]*\s+in\b")
ASSIGN_RE = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|\"[^\"]*\"|[^ \t;&|()]+)?\s*")


def _scan_balanced(text, start, open_ch, close_ch):
    """Scan a balanced bracket starting at text[start] == open_ch.

    Returns (end_index_exclusive, inner_text) or (None, None) when
    unbalanced.  Quote-aware: brackets inside single/double quotes
    do not count.
    """
    depth = 0
    i = start
    quote = None
    while i < len(text):
        ch = text[i]
        if quote == "'":
            if ch == "'":
                quote = None
        elif quote == '"':
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                quote = None
        else:
            if ch == "'":
                quote = "'"
            elif ch == '"':
                quote = '"'
            elif ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth == 0:
                    return i + 1, text[start + 1:i]
        i += 1
    return None, None


def split_code_line(line):
    """Split one physical shell line into code and substitutions.

    Returns (cleaned, inners): `cleaned` is the line with strings,
    comments, ${...} expansions and command substitutions removed;
    `inners` is the list of ``$(...)`` / backquote bodies found
    outside single quotes (i.e. code that really executes).
    """
    cleaned = []
    inners = []
    i = 0
    n = len(line)
    quote = None
    while i < n:
        ch = line[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                quote = None
                i += 1
                continue
            if line.startswith("$(", i):
                end, inner = _scan_balanced(line, i + 1, "(", ")")
                if end is None:
                    i += 2
                    continue
                inners.append(inner)
                i = end
                continue
            if ch == "`":
                j = line.find("`", i + 1)
                if j == -1:
                    i += 1
                    continue
                inners.append(line[i + 1:j])
                i = j + 1
                continue
            if line.startswith("${", i):
                end, inner = _scan_balanced(line, i + 1, "{", "}")
                if end is None:
                    i += 2
                    continue
                # ${X:-$(foo)} still runs foo: keep its substitutions.
                _, sub = split_code_line(inner)
                inners.extend(sub)
                i = end
                continue
            i += 1
            continue
        # quote is None: real code
        if ch == "#":
            break
        if ch == "'":
            quote = "'"
            i += 1
            continue
        if ch == '"':
            quote = '"'
            i += 1
            continue
        if line.startswith("$(", i):
            end, inner = _scan_balanced(line, i + 1, "(", ")")
            if end is None:
                cleaned.append(ch)
                i += 1
                continue
            inners.append(inner)
            cleaned.append(" ")
            i = end
            continue
        if ch == "`":
            j = line.find("`", i + 1)
            if j == -1:
                cleaned.append(ch)
                i += 1
                continue
            inners.append(line[i + 1:j])
            cleaned.append(" ")
            i = j + 1
            continue
        if line.startswith("${", i):
            end, inner = _scan_balanced(line, i + 1, "{", "}")
            if end is None:
                cleaned.append(ch)
                i += 1
                continue
            _, sub = split_code_line(inner)
            inners.extend(sub)
            cleaned.append(" ")
            i = end
            continue
        cleaned.append(ch)
        i += 1
    return "".join(cleaned), inners


def _is_case_pattern(cleaned, word):
    """True when `word` sits in a case-pattern position on the line.

    Patterns look like ``pat)``, ``a|b)`` or ``;; pat)``.  A match
    ending in ``)`` is a pattern by itself; a match ending in ``|``
    (``a|b)``) only counts when the rest up to the next ``)`` is
    pattern characters only, so a real piped call (``foo | bar`` or
    ``foo | (bar)``) is never mistaken for a pattern.
    """
    for m in re.finditer(r"(^|;;|\|)\s*" + re.escape(word) + r"\s*([|)])",
                         cleaned):
        if m.group(2) == ")":
            return True
        rest = cleaned[m.end():]
        if re.match(r"[A-Za-z0-9_|*?@!+.\-/]*\)", rest):
            return True
    return False


def calls_in_cleaned(cleaned, lineno, region, out):
    """Record first-word calls from already-cleaned code."""
    for seg in re.split(r"[;&|(){}]+", cleaned):
        seg = seg.strip()
        if not seg:
            continue
        while True:
            m = LEAD_KEYWORDS_RE.match(seg)
            if m:
                seg = seg[m.end():].lstrip()
                continue
            break
        if not seg:
            continue
        if FOR_LOOP_RE.match(seg):
            continue
        if re.match(r"(local|declare|typeset|export|readonly)\b", seg):
            continue
        while True:
            m = ASSIGN_RE.match(seg)
            if m:
                seg = seg[m.end():].lstrip()
                continue
            break
        if not seg:
            continue
        if seg.startswith("command"):
            rest = seg[len("command"):].strip()
            rest = re.sub(r"^(-[A-Za-z]+)\s+", "", rest)
            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_-])",
                         rest)
            if m and m.group(1) not in KEYWORDS:
                out.append((m.group(1), lineno, region))
            continue
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_-])", seg)
        if not m:
            continue
        word = m.group(1)
        if word in KEYWORDS:
            continue
        if _is_case_pattern(cleaned, word):
            continue
        out.append((word, lineno, region))


def calls_in_text(text, lineno, region, out):
    """Record calls from one physical line (plus its substitutions)."""
    cleaned, inners = split_code_line(text)
    for inner in inners:
        calls_in_text(inner, lineno, region, out)
    calls_in_cleaned(cleaned, lineno, region, out)


def find_heredocs(lines):
    """Return [(tag, start_idx, end_idx, quoted, opener_line)].

    start_idx/end_idx are 0-based indexes of the opener and the
    terminator line.  An opener with no later terminator line is a
    string mention (e.g. a self-test grep pattern), not a heredoc.
    """
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
                quoted = ("'" + tag + "'") in lines[i] or \
                    ('"' + tag + '"') in lines[i]
                regions.append((tag, i, end, quoted, lines[i]))
                i = end + 1
                continue
        i += 1
    return regions


def region_of(idx, regions):
    """Region tag for a line index, or 'MAIN' (opener/terminator lines
    count as MAIN: they are main-script code)."""
    for tag, start, end, _quoted, _op in regions:
        if start < idx < end:
            return tag
    return "MAIN"


def is_shell_script(tag, start, end, lines, opener):
    """Classify a heredoc body as a standalone shell script.

    Returns (in_scope, reason).  A block is in scope when its body
    starts with a shell shebang, defines at least one shell function,
    or is written with mode 700/755 to a script path.
    """
    body = lines[start + 1:end]
    for ln in body:
        s = ln.strip()
        if not s or s.startswith("#"):
            if s.startswith("#!"):
                return True, "shebang %s" % s[:40]
            continue
        break
    for ln in body:
        if DEF_RE.match(ln):
            return True, "defines shell function(s)"
    if re.search(r"\b(700|755)\b", opener) and re.search(
            r"\.sh\b|/usr/local/(s?bin)/|/etc/init\.d/", opener):
        return True, "written 700/755 to a script path"
    return False, "no shebang, no function definition (config/text)"


def collect(lines, regions):
    """Collect definitions and calls.

    Returns (defs, calls, scope, selftest_range) where defs maps a
    name to the set of region tags defining it ('MAIN' for the main
    script), calls maps (region, name) to [linenos], and scope maps a
    region tag to (in_scope, reason).
    """
    # Self-test range: definitions inside it are fixtures/mocks.
    st_start = st_end = None
    for i, ln in enumerate(lines):
        if SELFTEST_START_RE.match(ln):
            st_start = i
        elif SELFTEST_END_RE.match(ln) and st_start is not None:
            st_end = i
            break
    if st_start is None or st_end is None:
        raise SystemExit(
            "ERROR: self-test delimiters not found "
            "(^run_self_tests() {$ .. ^main() {$); refusing to guess")

    defs = defaultdict(set)
    def_lines = defaultdict(list)
    for i, ln in enumerate(lines):
        m = DEF_RE.match(ln)
        if not m:
            continue
        region = region_of(i, regions)
        if region == "MAIN" and st_start < i < st_end:
            continue  # test fixture/mock, not a runtime function
        defs[m.group(1)].add(region)
        def_lines[m.group(1)].append((region, i + 1))

    scope = {}
    shell_regions = []
    for tag, start, end, quoted, opener in regions:
        if PY_TAG_RE.match(tag):
            scope[(tag, start)] = (False, "Python heredoc (not shell)")
            continue
        in_scope, reason = is_shell_script(
            tag, start, end, lines, opener)
        scope[(tag, start)] = (in_scope, reason)
        if in_scope:
            shell_regions.append((tag, start, end, quoted))

    calls = defaultdict(list)
    call_list = []

    def process_line(text, lineno, region):
        # A one-line definition may carry calls after the '{'.
        m = DEF_RE.match(text)
        if m:
            calls_in_text(text[m.end():], lineno, region, call_list)
            return
        calls_in_text(text, lineno, region, call_list)

    # MAIN lines (everything outside any heredoc body).
    for i, ln in enumerate(lines):
        if region_of(i, regions) != "MAIN":
            continue
        process_line(ln, i + 1, "MAIN")

    # Shell-script heredoc bodies.
    for tag, start, end, quoted in shell_regions:
        in_py = None
        for i in range(start + 1, end):
            ln = lines[i]
            if in_py is not None:
                if ln.strip() == in_py:
                    in_py = None
                continue
            pm = re.search(r"<<-?['\"]?(PY[A-Za-z0-9_]*)['\"]?", ln)
            if pm:
                in_py = pm.group(1)
                # The opener line itself is shell code (python3 ...).
                process_line(ln, i + 1, tag)
                continue
            if not quoted:
                # Unquoted heredoc: $(...) runs in MAIN at generation
                # time; attribute it to MAIN, keep the rest as heredoc.
                cleaned, inners = split_code_line(ln)
                for inner in inners:
                    calls_in_text(inner, i + 1, "MAIN", call_list)
                calls_in_cleaned(cleaned, i + 1, tag, call_list)
            else:
                process_line(ln, i + 1, tag)

    for name, lineno, region in call_list:
        calls[(region, name)].append(lineno)

    return defs, calls, scope, (st_start + 1, st_end + 1), def_lines


def find_wrappers(lines, regions, def_lines):
    """Main-script functions delegating to `command <same name>`.

    Such a function is a transparent external-command wrapper, so a
    heredoc calling that name resolves to the system binary.
    """
    wrappers = {}
    top_defs = []
    for i, ln in enumerate(lines):
        if TOP_DEF_RE.match(ln) and region_of(i, regions) == "MAIN":
            top_defs.append(i)
    top_defs.append(len(lines))
    for name, occurrences in def_lines.items():
        for region, lineno in occurrences:
            if region != "MAIN":
                continue
            start = lineno - 1
            nxt = min([d for d in top_defs if d > start],
                      default=len(lines))
            for j in range(start, nxt):
                code, _ = split_code_line(lines[j])
                if re.search(r"(?<![A-Za-z0-9_-])command\s+" +
                             re.escape(name) + r"(?![A-Za-z0-9_-])",
                             code):
                    wrappers[name] = lineno
                    break
    return wrappers


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else Path("install.sh")
    verbose = "--verbose" in argv
    if not path.is_file():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2
    lines = path.read_text(encoding="utf-8").splitlines()
    regions = find_heredocs(lines)
    defs, calls, scope, _st, def_lines = collect(lines, regions)
    wrappers = find_wrappers(lines, regions, def_lines)

    errors = []
    # Direction (a): MAIN calls a function defined only in heredocs.
    for (region, name), linenos in sorted(calls.items()):
        if region != "MAIN":
            continue
        defined = defs.get(name, set())
        if defined and "MAIN" not in defined:
            errors.append(
                f"MAIN:{linenos[0]}: call to '{name}' which is defined "
                f"only in heredoc(s) {sorted(defined)} "
                f"(H-7 pattern; called at lines {sorted(set(linenos))[:5]})")
    # Direction (b): heredoc calls a function defined in MAIN (and
    # not in that heredoc itself), unless it is a transparent wrapper.
    for (region, name), linenos in sorted(calls.items()):
        if region == "MAIN" or PY_TAG_RE.match(region):
            continue
        defined = defs.get(name, set())
        if "MAIN" in defined and region not in defined \
                and name not in wrappers:
            errors.append(
                f"{region}:{linenos[0]}: call to '{name}' which is "
                f"defined in MAIN (lines "
                f"{[ln for r, ln in def_lines[name] if r == 'MAIN'][:3]}) "
                f"but not in this generated script "
                f"(called at lines {sorted(set(linenos))[:5]})")

    if verbose:
        print(f"heredoc regions: {len(regions)}")
        seen = set()
        for tag, start, end, quoted, _op in regions:
            key = (tag, start)
            in_scope, reason = scope[key]
            print(f"  {tag} L{start + 1}-{end + 1} "
                  f"{'quoted' if quoted else 'unquoted'} "
                  f"{'SHELL' if in_scope else 'skip'}: {reason}")
            seen.add(tag)
        print(f"functions defined: {len(defs)} "
              f"(MAIN: {sum(1 for r in defs.values() if 'MAIN' in r)})")
        dups = {n: sorted(r) for n, r in defs.items() if len(r) > 1}
        print(f"defined on both sides (intentional sharing): {len(dups)}")
        for name in sorted(dups):
            print(f"  {name}: {dups[name]}")
        if wrappers:
            print("transparent external-command wrappers (MAIN def "
                  "delegates to `command <name>`):")
            for name, ln in sorted(wrappers.items()):
                print(f"  {name} (MAIN:{ln})")
        print(f"calls recorded: {sum(len(v) for v in calls.values())}")

    if errors:
        print("CROSS-BOUNDARY CHECK FAILED:")
        for err in errors:
            print(f"  ERROR: {err}")
        return 1
    n_shell = sum(1 for (_t, _s), (ok, _r) in scope.items() if ok)
    print(f"OK: cross-boundary check passed "
          f"({len(regions)} heredoc regions, {n_shell} shell scripts, "
          f"{len(defs)} functions, "
          f"{sum(len(v) for v in calls.values())} calls checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
