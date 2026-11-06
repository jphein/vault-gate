#!/usr/bin/env python3
"""vault-gate-match.py: does this Bash command RUN the Bitwarden CLI? Exit 0 = yes (gate it), 1 = no.

The hook used to grep for "bw " anywhere in the command text, so a heredoc, a grep pattern or a commit message
that mentioned the CLI opened the unlock window too (2026-11-06: four lanes, 120 s each). Now `bw` must sit at a
COMMAND position: the first word of a simple command after assignments, redirections, reserved words (if, while,
!, {) and wrappers (sudo -u x / --user x, env, exec, timeout -k 1 10, nice, xargs, ...); after ; && || | ( & or a
newline; inside an unquoted or double-quoted $( ) or backtick substitution (also in the body of an unquoted
heredoc, which expands); or in the -c string of a shell (bash -lc '...' too). Single-quoted text (across lines
too), comments and heredoc bodies never count; a `<<EOF` inside quotes is text, not a heredoc; `for bw in …` names
a variable; `command -v bw` only looks bw up. A remote `ssh host 'bw …'` is not local and does not count. Any
parser failure (an unbalanced quote, a bug) falls back to the old loose match, so it fails toward gating.

    printf '%s' "$CMD" | python3 -I vault-gate-match.py        # stdin
    python3 -I vault-gate-match.py --test tests/match-fixtures.txt   # fixtures: lines "trip|cmd" / "pass|cmd"
"""
import os, re, shlex, sys

# wrappers: short options that take an operand, and long options that take an operand (without "=")
WRAPPERS = {
    "sudo": ("ugCDhprtTU", {"--user", "--group", "--host", "--prompt", "--role", "--type", "--close-from", "--chdir", "--other-user"}),
    "doas": ("u", set()), "exec": ("a", set()), "env": ("uCS", {"--unset", "--chdir", "--split-string"}),
    "nohup": ("", set()), "nice": ("n", {"--adjustment"}), "ionice": ("cnp", {"--class", "--classdata", "--pid"}),
    "timeout": ("ks", {"--kill-after", "--signal"}), "stdbuf": ("ioe", {"--input", "--output", "--error"}),
    "xargs": ("InPdLsaE", {"--max-args", "--max-procs", "--delimiter", "--replace", "--max-lines", "--max-chars", "--arg-file", "--eof"}),
    "builtin": ("", set()), "time": ("f", {"--format"}), "caffeinate": ("t", set()), "command": ("", set()),
}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "{", "}", "!", "esac", "coproc"}
NEVER_A_COMMAND = {"for", "select", "case", "function", "in"}   # the words after these name variables/patterns
LOOSE = re.compile(r"(?<![/\w.-])bw\s|[\"']bw\s")
HEREDOC = re.compile(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|(\w+))")
REDIR = re.compile(r"^[0-9]*(>>|>|<|<>|&>|>&|<&)[0-9]*$")
REDIR_WORD = re.compile(r"^[0-9]*(>>|>|<|&>|>&)\S+$")
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")
PH = re.compile(r"\x00(\d+)\x00")            # a single-quoted literal, kept out of the lexer's way (NUL never occurs in a command)
SEPMAP = {";": "\x01", "&": "\x02", "|": "\x03", "(": "\x04", ")": "\x05"}   # separators inside double quotes are text
UNSEP = {v: k for k, v in SEPMAP.items()}


def scan(line: str, state: str, lits: list):
    """Scan one raw line from quote state state ('n' plain, 's' in single quotes, 'd' in double quotes).
    Returns (code, code_nq, state, subs): code keeps double-quoted text (a quoted path can be the command) with
    its separators hidden and single-quoted literals as placeholders; code_nq blanks double-quoted text (for the
    heredoc scan); subs are the $( ) and backtick bodies, which execute and are judged on their own."""
    out, nq, subs, heredocs, i, n = [], [], [], [], 0, len(line)

    open_depth = [0]   # >0 after the loop: a $( that did not close on this line (its body goes on next line)

    def take_subst(i):
        if line.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if line.startswith("$(", j):
                    depth += 1; j += 2; continue
                depth += (line[j] == "(") - (line[j] == ")")
                j += 1
            if depth == 0:
                subs.append(line[i + 2:j - 1])
            else:
                subs.append(line[i + 2:]); open_depth[0] = depth
            return j
        j = line.find("`", i + 1)
        subs.append(line[i + 1:j] if j >= 0 else line[i + 1:])
        return (j + 1) if j >= 0 else n

    while i < n:
        c = line[i]
        if state == "s":
            if c == "'":
                state = "n"; i += 1
            else:
                lits[-1] += c; i += 1
            continue
        if state == "n":
            if c == "\\" and i + 1 < n:
                out.append(line[i:i + 2]); nq.append(line[i:i + 2]); i += 2; continue
            if line.startswith("<<<", i):                      # a here-string, not a heredoc
                out.append("<<<"); nq.append("<<<"); i += 3; continue
            if line.startswith("<<", i):                       # a heredoc delimiter, read here so quoted "<<EOF" text never counts
                m = re.match(r"<<(-?)\s*(?:'([^']+)'|\"([^\"]+)\"|(\w+))", line[i:])
                if m:
                    dash, a, b, c2 = m.groups(); heredocs.append((a or b or c2, not (a or b), bool(dash)))
                    out.append(" "); nq.append(" "); i += m.end(); continue
            if c == "'" or line.startswith("$'", i):
                lits.append(""); ph = f"'\x00{len(lits) - 1}\x00'"; out.append(ph); nq.append(ph); state = "s"; i += 2 if c == "$" else 1; continue
            if c == "#" and (i == 0 or line[i - 1] in " \t;&|("):
                break
            if c == '"':
                out.append(c); nq.append(c); state = "d"; i += 1; continue
            if line.startswith("$(", i) or c == "`":
                i = take_subst(i); out.append("_SUB_"); nq.append("_SUB_"); continue
            out.append(c); nq.append(c); i += 1; continue
        # state d
        if c == "\\" and i + 1 < n:
            out.append(line[i:i + 2]); i += 2; continue
        if c == '"':
            out.append(c); nq.append(c); state = "n"; i += 1; continue
        if line.startswith("$(", i) or c == "`":
            i = take_subst(i); out.append("_SUB_"); continue
        out.append(SEPMAP.get(c, c)); i += 1
    if open_depth[0]:
        state = "p%d%s" % (open_depth[0], state)   # e.g. p1d: one open paren, begun inside double quotes
    return "".join(out), "".join(nq), state, subs, heredocs


def continue_paren(line: str, depth: int):
    """Feed one more raw line into an open $( … ): returns (body_part, new_depth, rest_of_line_after_close)."""
    j = 0
    while j < len(line) and depth:
        if line.startswith("$(", j):
            depth += 1; j += 2; continue
        depth += (line[j] == "(") - (line[j] == ")")
        j += 1
    if depth == 0:
        return line[:j - 1], 0, line[j:]
    return line, depth, ""


RAW_SUBST = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")   # inside an unquoted heredoc body quotes do not suppress expansion


def unquote(tok: str, lits: list) -> str:
    tok = PH.sub(lambda m: lits[int(m.group(1))], tok)
    return "".join(UNSEP.get(ch, ch) for ch in tok)


def is_bw(word: str) -> bool:
    return os.path.basename(word) == "bw"


BW_VARS: set = set()   # variables assigned a path whose basename is bw, within the command text being judged
VARREF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")


def head_is_bw(words: list, lits: list) -> bool:
    words = [unquote(w, lits) for w in words]
    if words and words[0] in NEVER_A_COMMAND:
        return False
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN.fullmatch(w):
            name, val = w.split("=", 1)
            if is_bw(val.strip("\"'")):
                BW_VARS.add(name)                                 # BW="$HOME/.npm-global/bin/bw"; "$BW" status
            i += 1; continue
        if w == "--" or w in RESERVED or REDIR_WORD.match(w):
            i += 1; continue
        m = VARREF.fullmatch(w)
        if m and m.group(1) in BW_VARS:
            return True
        if REDIR.match(w):
            i += 2; continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            short_ops, long_ops = WRAPPERS[base]
            i += 1
            while i < len(words):
                o = words[i]
                if o == "--":
                    i += 1; break
                if base == "command" and (o in ("-v", "-V") or (o.startswith("-") and not o.startswith("--") and ("v" in o or "V" in o))):
                    return False                                  # a lookup, not a run
                if base == "env" and o.startswith("--split-string="):
                    return trips(o.split("=", 1)[1])
                if base == "env" and (o == "-S" or o == "--split-string") and i + 1 < len(words):
                    return trips(words[i + 1])                    # env -S 'bw status' runs the string
                if o.startswith("--"):
                    i += 1 + (1 if o in long_ops else 0); continue
                if o.startswith("-") and len(o) > 1:
                    i += 1 + (1 if (len(o) == 2 and o[1] in short_ops) else 0); continue
                if base == "env" and "=" in o:
                    i += 1; continue
                break
            if base == "timeout" and i < len(words) and re.fullmatch(r"[0-9.]+[smhd]?", words[i]):
                i += 1
            continue
        if base in SHELLS:
            j = i + 1
            while j < len(words) and words[j].startswith("-"):
                if words[j] != "--" and "c" in words[j][1:]:
                    return j + 1 < len(words) and trips(words[j + 1])
                j += 1
            return False
        if base == "eval":
            return trips(" ".join(words[i + 1:]))
        return is_bw(w)
    return False


def split_commands(code: str):
    lex = shlex.shlex(code, posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    cur = []
    for tok in lex:
        if tok in (";", "&&", "||", "|", "&", "(", ")", ";;", "|&"):
            if cur:
                yield cur
            cur = []
        else:
            cur.append(tok)
    if cur:
        yield cur


def _trips(text: str) -> bool:
    state, lits, tags, buf, pending, pbody = "n", [], [], [], [], []
    for line in text.replace("\\\n", "").split("\n"):   # bash joins a backslash-newline before anything else
        if tags and state == "n" and not buf:            # inside a heredoc body
            tag, expands, dash = tags[0]
            if (line.lstrip("\t") if dash else line) == tag:   # bash: the delimiter alone on its line; <<- strips leading tabs only
                tags.pop(0); continue
            if expands:                                   # an unquoted heredoc runs $( ) in its body, quotes or not
                for m in RAW_SUBST.finditer(line):
                    if _trips(m.group(1) or m.group(2) or ""):
                        return True
            continue
        if not line.strip() and state == "n" and not buf:
            continue
        if state.startswith("p"):                         # inside a $( … ) that began on an earlier line
            m = re.fullmatch(r"p(\d+)([nd])", state)
            part, depth, rest = continue_paren(line, int(m.group(1)))
            pbody.append(part)
            if depth:
                continue
            if _trips("\n".join(pbody)):                  # the whole body, heredocs inside it included
                return True
            pbody, state = [], m.group(2)                  # back to the quote state the $( began in
            buf.append("_SUB_")
            line = rest
            if not line.strip() and state == "n":
                logical, buf = "\n".join(buf), []
                for words in split_commands(logical):
                    if head_is_bw(words, lits):
                        return True
                tags.extend(pending); pending = []
                continue
        code, nq, state, subs, heredocs = scan(line, state, lits)
        buf.append(code); pending.extend(heredocs)
        if state.startswith("p"):
            pbody = [subs.pop()]                           # the partial body; judged once the parens close
        for body in subs:
            if _trips(body):
                return True
        if state.startswith("p"):
            continue
        if state == "s":
            lits[-1] += "\n"; continue                    # the literal goes on next line
        if state == "d":
            continue                                      # the quoted word goes on next line
        logical, buf = "\n".join(buf), []
        for words in split_commands(logical):
            if head_is_bw(words, lits):
                return True
        tags.extend(pending); pending = []
    if state != "n":
        raise ValueError("unbalanced quote")
    return False


def trips(text: str) -> bool:
    BW_VARS.clear()
    try:
        return _trips(text)
    except Exception:                                      # a parser failure never skips the gate
        return bool(LOOSE.search(text))


def run_fixtures(path: str) -> int:
    bad = 0
    for raw in open(path, encoding="utf-8"):
        raw = raw.rstrip("\n")
        if not raw or raw.startswith("#"):
            continue
        want, cmd = raw.split("|", 1)
        cmd = cmd.replace("<NL>", "\n")
        got = trips(cmd)
        ok = got == (want == "trip")
        print(f"{'ok  ' if ok else 'FAIL'} {want:4} {cmd[:70]!r}")
        bad += 0 if ok else 1
    print(f"{bad} failure(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--test":
        sys.exit(run_fixtures(sys.argv[2]))
    cmd = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
    sys.exit(0 if trips(cmd) else 1)
