#!/usr/bin/env bash
# vault-gate tests (no vault, no desktop touched): the matcher fixtures, and the headless path of vault-gate.sh with
# stubs for loginctl (no seat0 session), bw (locked), ssh (canned idle/lock per desktop), tmux and ask.
#   tests/run.sh
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; fails=0
bad() { echo "FAIL: $*"; fails=$((fails+1)); }; ok() { echo "ok:   $*"; }
python3 -I "$R/vault-gate-match.py" --test "$R/tests/match-fixtures.txt" | tail -1 | grep -q '^0 failure' && ok "matcher fixtures" || bad "matcher fixtures"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run"; chmod 700 "$T/run"
cat > "$T/bin/loginctl" <<'S'
#!/bin/sh
case "$1" in list-sessions) printf '1 1000 jp - 2439  manager - no -\n4 1000 jp - 7983  user    - no -\n';;
  show-session) printf 'Name=jp\nSeat=\nType=tty\nActive=yes\n';; esac
S
cat > "$T/bin/bw" <<'S'
#!/bin/sh
echo '{"status":"locked"}'
S
cat > "$T/bin/ssh" <<'S'
#!/bin/sh
# canned desktops: katana idle 362 s unlocked, wakizashi idle 153 s unlocked, wakizashi wins; ghost unreachable
for a in "$@"; do h=$a; done; host=""
while [ $# -gt 0 ]; do case "$1" in -o) shift;; -*) ;; *) host=$1; break;; esac; shift; done
case "$host" in katana) printf '(uint64 362308,)\n(false,)\n';; wakizashi) printf '(uint64 153087,)\n(false,)\n';; *) exit 255;; esac
S
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tmux"; printf '#!/bin/sh\necho "ask abc123def456 filed"\n' > "$T/bin/ask"
chmod +x "$T/bin"/*
run() { PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" HOME="$T" VAULT_GATE_BW="$T/bin/bw" VAULT_GATE_SSH="$T/bin/ssh" VAULT_GATE_MAX_WAIT=2 REMOTE_DESKTOPS="ghost katana wakizashi" "$@" bash "$R/vault-gate.sh" 2>&1; }
out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
grep -q "DRY-RUN: would open on wakizashi: systemd-run --user --collect --quiet /usr/bin/ghostty --title='Vault Unlock ($(hostname))' -e ssh -t $(hostname) tmux attach -t vault-unlock" <<<"$out" && [ $rc -eq 0 ] && ok "headless dry run picks the least idle desktop and would open ghostty via systemd-run" || bad "headless dry run: rc=$rc out=$out"
mkdir -p "$T/run/vault-gate.remote-open"; printf 'wakizashi' > "$T/run/vault-gate.remote-open/desk"; printf 'abc123def456' > "$T/run/vault-gate.remote-open/card"
out=$(run env); rc=$?
grep -q "BLOCKED: unlock pending, card abc123def456: a Vault Unlock window is open on wakizashi" <<<"$out" && [ $rc -eq 2 ] && ok "a fresh lock refuses at once with the card id (exit 2)" || bad "fresh lock: rc=$rc out=$out"
touch -d '-11 minutes' "$T/run/vault-gate.remote-open"
out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
grep -q "DRY-RUN: would open on wakizashi" <<<"$out" && [ $rc -eq 0 ] && ok "a stale lock (11 min) opens again" || bad "stale lock: rc=$rc out=$out"
rm -rf "$T/run/vault-gate.remote-open"
( run env >"$T/a.out" 2>&1 & run env >"$T/b.out" 2>&1 & wait )
opened=$(cat "$T/a.out" "$T/b.out" | grep -c "VAULT: Unlock window opened on"); refused=$(cat "$T/a.out" "$T/b.out" | grep -c "BLOCKED: unlock pending")
[ "$opened" = 1 ] && [ "$refused" = 1 ] && ok "two concurrent callers: exactly one opens, one is refused (flock)" || bad "concurrency: opened=$opened refused=$refused: $(cat "$T/a.out" "$T/b.out" | tr '\n' ' ' | cut -c1-300)"
[ "$(cat "$T/run/vault-gate.remote-open/card")" = abc123def456 ] && ok "the card id is stored in the lock dir" || bad "card not stored"
chmod 755 "$T/run"; out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
grep -q "BLOCKED: .* not a private (0700, mine) runtime dir" <<<"$out" && [ $rc -eq 2 ] && ok "a runtime dir that is not 0700 is refused" || bad "runtime dir check: rc=$rc out=$out"
chmod 700 "$T/run"
echo "$fails failure(s)"; [ "$fails" -eq 0 ]
