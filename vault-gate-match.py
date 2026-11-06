#!/usr/bin/env python3
"""vault-gate-match.py: does this Bash command RUN the Bitwarden CLI? Exit 0 = yes (gate it), 1 = no.

The hook used to grep for "bw " anywhere in the command text, so a heredoc, a grep pattern or a commit message
that mentioned the CLI opened the unlock window too (2026-11-06: four lanes, 120 s each). Now `bw` must sit at a
COMMAND position: the first word of a simple command after assignments, redirections, reserved words (if, while,
!, {) and wrappers (sudo -u x, env, exec, timeout 10, nice, xargs, ...); after ; && || | ( & or a newline; inside
an unquoted or double-quoted $( ) or backtick substitution; or in the -c string of a shell (bash -lc '...' too).
Single-quoted text, comments and heredoc bodies never count; a `<<EOF` inside quotes is text, not a heredoc (so
the line after it is a command).
A remote `ssh host 'bw …'` is not local and does not count; `command -v bw` only looks bw up. A line that cannot
be tokenised (an unbalanced quote) falls back to the old loose match, so a broken quote fails toward gating.

    printf '%s' "$CMD" | python3 -I vault-gate-match.py        # stdin
    python3 -I vault-gate-match.py --test tests/match-fixtures.txt   # fixtures: lines "trip|cmd" / "pass|cmd"
"""
import os, re, shlex, sys

# wrappers and the options of theirs that take an operand (the operand is not the command)
WRAPPERS = {"sudo": "ugCDhprtTU", "doas": "u", "exec": "a", "env": "uCS", "nohup": "", "nice": "n", "ionice": "cnp",
            "timeout": "ks", "stdbuf": "ioe", "xargs": "InPdLsaE", "builtin": "", "time": "f", "caffeinate": "t"}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "{", "}", "!", "case", "esac",
            "in", "select", "for", "function", "coproc"}
LOOSE = re.compile(r"(?<![/\w.-])bw\s|[\"']bw\s")
HEREDOC = re.compile(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|(\w+))")
REDIR = re.compile(r"^[0-9]*(>>|>|<|<>|&>|>&|<&)[0-9]*$")
REDIR_WORD = re.compile(r"^[0-9]*(>>|>|<|&>|>&)\S+$")
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")


def scan(line: str):
    """One line → (code, subs). code: the line with single-quoted strings and the comment removed and every
    substitution ($( ), ` `) replaced by a placeholder; subs: the substitution bodies (they execute, so they are
    judged as commands of their own). Double-quoted text stays in code (a quoted path can be the command)."""
    out, subs, lits, i, n = [], [], [], 0, len(line)
    state = "n"   # n = normal, d = double quoted
    while i < n:
        c = line[i]
        if state == "n":
            if c == "\\" and i + 1 < n:
                out.append(line[i:i + 2]); i += 2; continue
            if c == "'":
                j = line.find("'", i + 1)
                if j < 0:
                    raise ValueError("unbalanced single quote")
                lits.append(line[i + 1:j]); out.append(f"'__SQ{len(lits) - 1}__'"); i = j + 1; continue
            if c == "#" and (i == 0 or line[i - 1] in " \t;&|("):
                break
            if c == '"':
                state = "d"; out.append(c); i += 1; continue
        else:
            if c == "\\" and i + 1 < n:
                out.append(line[i:i + 2]); i += 2; continue
            if c == '"':
                state = "n"; out.append(c); i += 1; continue
        if line.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if line.startswith("$(", j):
                    depth += 1; j += 2; continue
                if line[j] == "(":
                    depth += 1
                elif line[j] == ")":
                    depth -= 1
                j += 1
            subs.append(line[i + 2:j - 1] if depth == 0 else line[i + 2:])
            out.append("_SUB_"); i = j; continue
        if c == "`":
            j = line.find("`", i + 1)
            subs.append(line[i + 1:j] if j >= 0 else line[i + 1:])
            out.append("_SUB_"); i = (j + 1) if j >= 0 else n; continue
        out.append(c); i += 1
    if state == "d":
        raise ValueError("unbalanced double quote")
    return "".join(out), subs, lits


SQ = re.compile(r"__SQ(\d+)__")


def unquote(tok: str, lits: list) -> str:
    """Put a single-quoted literal back into a token (the -c string of a shell, a heredoc tag, a quoted head)."""
    return SQ.sub(lambda m: lits[int(m.group(1))], tok)


def is_bw(word: str) -> bool:
    return os.path.basename(word) == "bw"


def head_is_bw(words: list, lits: list = ()) -> bool:
    words = [unquote(w, lits) for w in words]
    i = 0
    while i < len(words):
        w = words[i]
        if w in RESERVED or ASSIGN.fullmatch(w) or REDIR_WORD.match(w):
            i += 1; continue
        if REDIR.match(w):
            i += 2; continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            if base == "command" and i + 1 < len(words) and words[i + 1] in ("-v", "-V"):
                return False
            i += 1
            if base == "timeout" and i < len(words) and re.fullmatch(r"[0-9.]+[smhd]?", words[i]):
                i += 1
            while i < len(words):
                o = words[i]
                if o == "--":
                    i += 1; break
                if o.startswith("--"):
                    i += 1; continue
                if o.startswith("-") and len(o) > 1:
                    i += 1
                    if o[-1] in WRAPPERS[base] and len(o) == 2:   # -u root: the operand is next
                        i += 1
                    continue
                if base == "env" and "=" in o:
                    i += 1; continue
                break
            continue
        if base == "command":
            i += 1; continue
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


def trips(text: str) -> bool:
    tags = []
    for line in text.split("\n"):
        if tags:
            if line.strip() == tags[0]:
                tags.pop(0)
            continue
        if not line.strip():
            continue
        try:
            code, subs, lits = scan(line)
            cmds = list(split_commands(code))
        except ValueError:
            if LOOSE.search(line):
                return True
            continue
        for body in subs:
            if trips(body):
                return True
        for words in cmds:
            if head_is_bw(words, lits):
                return True
        tags = [unquote(a or b or c, lits) for a, b, c in HEREDOC.findall(code)]
    return False


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
