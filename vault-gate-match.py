#!/usr/bin/env python3
"""vault-gate-match.py: does this Bash command RUN the Bitwarden CLI? Exit 0 = yes (gate it), 1 = no.

The hook used to grep for "bw " anywhere in the command text, so a heredoc, a grep pattern or a commit message
that mentioned the CLI opened the unlock window too (2026-11-06: four lanes, 120 s each). Now `bw` must sit at a
COMMAND position: the first word of a simple command (after VAR=val assignments and wrappers such as sudo, exec,
env, timeout N), the first word after ; && || | ( or a newline, inside $( ) or backticks, or the -c argument of a
shell. Text inside quotes, heredoc bodies and comments never counts. A remote `ssh host 'bw …'` is not local and does
not count. If the command cannot be tokenised (an unbalanced quote), the old loose match decides, so a broken
quote fails toward gating, never toward skipping the vault check.

    printf '%s' "$CMD" | python3 -I vault-gate-match.py        # stdin
    python3 -I vault-gate-match.py --test tests/match-fixtures.txt   # fixtures: lines "trip|cmd" / "pass|cmd"
"""
import os, re, shlex, sys

WRAPPERS = {"sudo", "doas", "exec", "env", "nohup", "command", "time", "nice", "ionice", "timeout", "stdbuf", "xargs", "builtin"}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
LOOSE = re.compile(r"(?<![/\w.-])bw\s|[\"']bw\s")
SUBST = re.compile(r"(?:\$\(|`)\s*(?:[\w./~-]*/)?bw(?=\s|\)|`)")
HEREDOC = re.compile(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|(\w+))")


def strip_heredocs(text: str) -> str:
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        tags = [a or b or c for a, b, c in HEREDOC.findall(line)]
        i += 1
        while tags and i < len(lines):
            if lines[i].strip() == tags[0]:
                tags.pop(0)
            i += 1
    return "\n".join(out)


def is_bw(word: str) -> bool:
    return os.path.basename(word) == "bw"


def head_is_bw(words: list) -> bool:
    """words: one simple command's tokens. Skip assignments and wrappers; recurse into shell -c and eval."""
    i = 0
    while i < len(words):
        w = words[i]
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w):
            i += 1
            continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            i += 1
            if base == "timeout" and i < len(words) and re.fullmatch(r"[0-9.]+[smhd]?", words[i]):
                i += 1
            while i < len(words) and (words[i].startswith("-") or (base == "env" and "=" in words[i])):
                i += 1
            continue
        if base in SHELLS:
            if "-c" in words[i + 1:]:
                j = words.index("-c", i + 1)
                return j + 1 < len(words) and trips(words[j + 1])
            return False
        if base == "eval":
            return trips(" ".join(words[i + 1:]))
        return is_bw(w)
    return False


def split_commands(line: str):
    lex = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
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
    text = strip_heredocs(text)
    if SUBST.search(text):
        return True
    for line in text.split("\n"):
        if not line.strip():
            continue
        try:
            cmds = list(split_commands(line))
        except ValueError:
            if LOOSE.search(line):
                return True
            continue
        for words in cmds:
            if head_is_bw(words):
                return True
    return False


def run_fixtures(path: str) -> int:
    bad = 0
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
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
