#!/usr/bin/env bash
# vault-gate tests (no vault, no desktop touched): the matcher fixtures, and the headless path of vault-gate.sh with
# stubs for loginctl (no seat0 session), bw (locked), ssh (canned idle/lock per desktop), tmux and ask.
#   tests/run.sh
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; fails=0
bad() { echo "FAIL: $*"; fails=$((fails+1)); }; ok() { echo "ok:   $*"; }
python3 -I "$R/vault-gate-match.py" --test "$R/tests/match-fixtures.txt" | tail -1 | grep -q '^0 failure' && ok "matcher fixtures" || bad "matcher fixtures"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run"; chmod 700 "$T/run"
# A stub keyring FIRST on every test PATH: it stores nothing and finds nothing, so no test can reach the real keyring
# (katana has /usr/bin/secret-tool: without this, the gate's stale-token test and vault-login's login test would read,
# replace or clear JP's real cached session token; Oracle 2026-11-17).
NOKEYRING='#!/bin/sh
echo "$1" >> "${STUB_KEYRING_LOG:-/dev/null}"
case "$1" in store) cat >/dev/null; exit 1 ;; lookup) exit 1 ;; clear) exit 0 ;; esac
exit 1'
printf '%s\n' "$NOKEYRING" > "$T/bin/secret-tool"; chmod +x "$T/bin/secret-tool"
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
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tmux"; # the real gateway exits 22 without --who/ASK_WHO (measured 2026-11-11 01:33: the card stayed "unfiled", silently)
printf '#!/bin/sh\ncase " $* " in *" --who "*) echo "ask abc123def456 filed"; exit 0;; esac\n[ -n "$ASK_WHO" ] && { echo "ask abc123def456 filed"; exit 0; }\necho "ask: add: say who you are with --who <lane> (or ASK_WHO)" >&2; exit 22\n' > "$T/bin/ask"
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
rm -rf "$T/run/vault-gate.remote-open"; printf '#!/bin/sh\necho "ask: rejected: title too long" >&2; exit 22\n' > "$T/bin/ask"
out=$(run); rc=$?
grep -q "card unfiled" <<<"$out" && [ "$rc" -eq 2 ] && grep -q "card unfiled: ask add said: ask: rejected: title too long" "$T/run/vault-gate.log" && ok "a refused card leaves the gateway's words in the log and still blocks (rc 2)" || bad "a refused card is silent (log: $(grep -c 'card unfiled: ask add said' "$T/run/vault-gate.log" 2>/dev/null))"
printf '#!/bin/sh\ncase " $* " in *" --who "*) echo "ask abc123def456 filed"; exit 0;; esac\n[ -n "$ASK_WHO" ] && { echo "ask abc123def456 filed"; exit 0; }\necho "ask: add: say who you are with --who <lane> (or ASK_WHO)" >&2; exit 22\n' > "$T/bin/ask"
rm -rf "$T/run/vault-gate.remote-open"; printf 'unlocking' > "$T/run/bw-unlock-status"; touch -d '-11 minutes' "$T/run/bw-unlock-status"
out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
grep -q "DRY-RUN: would open on wakizashi" <<<"$out" && [ $rc -eq 0 ] && ok "an abandoned 'unlocking' status older than LOCK_TTL does not block a relaunch" || bad "stale status: rc=$rc out=$out"
rm -f "$T/run/bw-unlock-status"
# A present token is never touched unless bw says locked/unauthenticated for it, and never in a dry run (2026-11-06 13:06).
printf 'tok-12-42' > "$T/run/bw-session-token"; chmod 600 "$T/run/bw-session-token"; touch -d '-30 minutes' "$T/run/bw-session-token"
cat > "$T/bin/bw" <<'S'
#!/bin/sh
[ -n "$BW_SESSION" ] && { echo '{"status":"unlocked"}'; exit 0; }; echo '{"status":"locked"}'
S
chmod +x "$T/bin/bw"
out=$(run env); rc=$?; [ $rc -eq 0 ] && [ "$(cat "$T/run/bw-session-token")" = tok-12-42 ] && ok "a valid token: exit 0, token untouched" || bad "valid token: rc=$rc out=$out"
cat > "$T/bin/bw" <<'S'
#!/bin/sh
echo garbage
S
chmod +x "$T/bin/bw"
out=$(run env); rc=$?; [ $rc -eq 0 ] && [ "$(cat "$T/run/bw-session-token")" = tok-12-42 ] && ok "an unverifiable token (bw answers garbage): exit 0, token kept" || bad "unverifiable token: rc=$rc out=$out"
cat > "$T/bin/bw" <<'S'
#!/bin/sh
echo '{"status":"locked"}'
S
chmod +x "$T/bin/bw"
out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?; [ $rc -eq 0 ] && [ -f "$T/run/bw-session-token" ] && grep -q "Nothing touched" <<<"$out" && ok "dry run with bw saying locked: token kept" || bad "dry run stale: rc=$rc out=$out"
rm -rf "$T/run/vault-gate.remote-open"; out=$(run env VAULT_GATE_MAX_WAIT=1); rc=$?; [ ! -f "$T/run/bw-session-token" ] && grep -q "Cached token is locked" <<<"$out" && ok "a real run with bw saying locked clears the stale token and opens one window" || bad "real stale: rc=$rc files=$(ls "$T/run" | tr '\n' ' ') out=$out"
chmod 755 "$T/run"; out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
grep -q "BLOCKED: .* not a private (0700, mine) runtime dir" <<<"$out" && [ $rc -eq 2 ] && ok "a runtime dir that is not 0700 is refused" || bad "runtime dir check: rc=$rc out=$out"
chmod 700 "$T/run"
# lane hosts never unlock (2026-11-17 serialhub: no vault CLI, an unlock window opened locally, its script failed, and
# the gate reported "too many wrong passwords"): no CLI, or a host config marking it a lane host → refuse at once, no
# window, no card, and say where secrets come from instead
rm -rf "$T/run/vault-gate.remote-open" "$T/run/bw-unlock-status"
out=$(run env VAULT_GATE_BW="$T/bin/no-such-cli"); rc=$?
[ $rc -eq 2 ] && grep -q "BLOCKED: no vault on this host" <<<"$out" && ! grep -q "Unlock window\|DRY-RUN\|wrong password" <<<"$out" && [ ! -e "$T/run/vault-gate.remote-open" ] \
  && ok "no vault CLI: refused at once (exit 2), no window, no card" || bad "no CLI: rc=$rc out=$out"
rm -rf "$T/run/vault-gate.remote-open" "$T/run/bw-unlock-status"
mkdir -p "$T/.config/vault-gate"; printf 'LANE_HOST=1\n' > "$T/.config/vault-gate/config"
out=$(run env); rc=$?
[ $rc -eq 2 ] && grep -q "BLOCKED: no vault on this host" <<<"$out" && ! grep -q "Unlock window\|wrong password" <<<"$out" && [ ! -e "$T/run/vault-gate.remote-open" ] \
  && ok "LANE_HOST=1 in the host's config: refused even with a CLI present" || bad "lane host: rc=$rc out=$out"
rm -f "$T/.config/vault-gate/config"
# the PATH wrapper says the same and exits 2, instead of exec'ing a CLI that is not there (HOME=$T has none)
out=$(HOME="$T" bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q "no vault on this host" <<<"$out" && ok "wrapper on a host with no CLI: exit 2, says why" || bad "wrapper no CLI: rc=$rc out=$out"
mkdir -p "$T/.npm-global/bin"; printf '#!/bin/sh\necho real-cli-ran\n' > "$T/.npm-global/bin/bw"; chmod +x "$T/.npm-global/bin/bw"
out=$(HOME="$T" BW_SESSION=x bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = real-cli-ran ] && ok "wrapper with a CLI present: execs it" || bad "wrapper with CLI: rc=$rc out=$out"
printf 'LANE_HOST=1\n' > "$T/.config/vault-gate/config"
out=$(HOME="$T" BW_SESSION=x bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
[ $rc -eq 2 ] && [[ "$out" != *real-cli-ran* ]] && ok "wrapper on a LANE_HOST=1 host: exit 2 even with a CLI" || bad "wrapper lane: rc=$rc out=$out"
rm -rf "$T/.npm-global" "$T/.config/vault-gate/config"
# vault-login.sh (Sen's re-login tool): public repo, so no account or server inside it; lane hosts refuse; status
# FIRST (the real CLI refuses `config server` while logged in: bw.js "Logout required before server config update");
# the token goes through the gate's token lock with a keyring read-back (a stale entry is cleared)
mkdir -p "$T/vl/bin" "$T/vl/.npm-global/bin" "$T/vl/.config/vault-gate" "$T/vl/run"; chmod 700 "$T/vl/run"
printf '#!/bin/sh\nexit 0\n' > "$T/vl/bin/sleep"
printf '%s\n' "$NOKEYRING" > "$T/vl/bin/secret-tool"; chmod +x "$T/vl/bin/secret-tool"
cat > "$T/vl/.npm-global/bin/bw" <<'S'
#!/bin/sh
echo "$1 session=${BW_SESSION:+set}" >> "$HOME/cli.log"
case "$1" in
  status) if [ "${BW_SESSION:-}" = tok-login-1 ]; then echo '{"status":"unlocked"}'; else echo "{\"status\":\"${FAKE_STATUS:-locked}\"}"; fi ;;
  config) [ "${FAKE_STATUS:-locked}" = unauthenticated ] || { echo "Logout required before server config update." >&2; exit 1; } ;;
  login) echo tok-login-1 ;;
  sync) [ "${BW_SESSION:-}" = tok-login-1 ] || exit 1 ;;
esac
S
chmod +x "$T/vl/bin/sleep" "$T/vl/.npm-global/bin/bw"
vl() { HOME="$T/vl" XDG_RUNTIME_DIR="$T/vl/run" PATH="$T/vl/bin:$PATH" "$@" bash "$R/vault-login.sh" 2>&1; }
! grep -qiE 'jphein|jphe\.in|@[a-z0-9.-]+\.(com|in|org)' "$R/vault-login.sh" && ok "vault-login.sh names no account or server (public repo)" || bad "vault-login.sh carries an account or server"
: > "$T/vl/cli.log"; out=$(vl env); rc=$?; [ $rc -eq 2 ] && grep -q "set VAULT_EMAIL and VAULT_SERVER" <<<"$out" && [ ! -s "$T/vl/cli.log" ] && ok "vault-login with no account configured: exit 2, the CLI untouched" || bad "vl unset: rc=$rc out=$out"
printf 'VAULT_EMAIL=someone@example.org\nVAULT_SERVER=https://vault.example.org\nLANE_HOST=1\n' > "$T/vl/.config/vault-gate/config"
: > "$T/vl/cli.log"; out=$(vl env); rc=$?; [ $rc -eq 2 ] && grep -q "no vault on this host" <<<"$out" && [ ! -s "$T/vl/cli.log" ] && ok "vault-login on a lane host: exit 2, the CLI untouched" || bad "vl lane: rc=$rc out=$out"
sed -i '/^LANE_HOST=1$/d' "$T/vl/.config/vault-gate/config"
: > "$T/vl/cli.log"; out=$(vl env FAKE_STATUS=locked); rc=$?
[ $rc -eq 0 ] && grep -q "not unauthenticated: use the normal unlock window" <<<"$out" && ! grep -qE '^(config|login)' "$T/vl/cli.log" \
  && ok "vault-login on a merely locked vault: status first, no config, no login (the real CLI refuses config while logged in)" || bad "vl locked: rc=$rc out=$out log=$(tr '\n' ' ' < "$T/vl/cli.log")"
chmod 755 "$T/vl/run"; out=$(vl env FAKE_STATUS=unauthenticated); rc=$?; chmod 700 "$T/vl/run"
[ $rc -eq 2 ] && grep -q "not a private (0700, mine) runtime dir" <<<"$out" && ok "vault-login refuses a runtime dir that is not 0700" || bad "vl 0700: rc=$rc out=$out"
# the login path with the stub keyring (stores nothing): the read-back fails, so the token lands in a 0600 file;
# verify and sync run WITH the new session
rm -f "$T/vl/run/bw-session-token"; : > "$T/vl/cli.log"
out=$(PATH="$T/vl/bin:/usr/bin:/bin" vl env FAKE_STATUS=unauthenticated PATH="$T/vl/bin:/usr/bin:/bin"); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$T/vl/run/bw-session-token" 2>/dev/null)" = tok-login-1 ] && [ "$(stat -c %a "$T/vl/run/bw-session-token")" = 600 ] \
  && grep -q '^sync session=set' "$T/vl/cli.log" && grep -q 'Vault status now: unlocked' <<<"$out" && grep -q '^synced' <<<"$out" \
  && ok "vault-login path: token in a 0600 file, verified unlocked, synced with the new session" || bad "vl login: rc=$rc out=$out log=$(tr '\n' ' ' < "$T/vl/cli.log")"
# keyring present but the store fails while a STALE token is there: the stale entry is cleared and the file holds the new one
cat > "$T/vl/bin/secret-tool" <<'S'
#!/bin/sh
echo "$1" >> "$HOME/st.log"
case "$1" in store) cat >/dev/null; exit 1 ;; lookup) echo old-token-before-logout ;; clear) exit 0 ;; esac
S
chmod +x "$T/vl/bin/secret-tool"; rm -f "$T/vl/run/bw-session-token" "$T/vl/st.log"
out=$(vl env FAKE_STATUS=unauthenticated); rc=$?
[ $rc -eq 0 ] && grep -q '^clear' "$T/vl/st.log" && [ "$(cat "$T/vl/run/bw-session-token" 2>/dev/null)" = tok-login-1 ] && grep -q 'token cached: file' <<<"$out" \
  && ok "vault-login: a failed keyring store with a stale entry clears it and falls back to the file" || bad "vl stale keyring: rc=$rc out=$out st=$(tr '\n' ' ' < "$T/vl/st.log" 2>/dev/null)"
printf '%s\n' "$NOKEYRING" > "$T/vl/bin/secret-tool"; chmod +x "$T/vl/bin/secret-tool"   # back to the refusing stub
# guard: no test reached a real secret-tool (every call above went to a stub)
rm -f "$T/vl/run/bw-session-token" "$T/kr.log"
out=$(vl env FAKE_STATUS=unauthenticated STUB_KEYRING_LOG="$T/kr.log"); rc=$?
[ $rc -eq 0 ] && [ "$(sort -u "$T/kr.log" 2>/dev/null | tr '\n' ' ')" = "clear lookup store " ] \
  && ok "positive control: vault-login's keyring calls (store, lookup, clear) all reached the stub, never the real keyring" || bad "keyring stub not used: rc=$rc log=$(tr '\n' ' ' < "$T/kr.log" 2>/dev/null)"
echo "$fails failure(s)"; [ "$fails" -eq 0 ]
