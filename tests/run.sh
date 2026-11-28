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
# logged OUT (status unauthenticated): the same window path, running vault-login.sh (2026-11-27: before this the hook
# printed a copy-paste "bw login" line and exited 2 while JP sat at katana with no window; never again)
printf '#!/bin/sh\necho %s\n' "'{\"status\":\"unauthenticated\"}'" > "$T/bin/bw"; chmod +x "$T/bin/bw"
mkdir -p "$T/.claude/scripts"; printf '#!/bin/bash\nexit 0\n' > "$T/.claude/scripts/vault-login.sh"; chmod +x "$T/.claude/scripts/vault-login.sh"
out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
[ $rc -eq 0 ] && grep -q "VAULT: not logged in: the window runs vault-login.sh" <<<"$out" && grep -q "DRY-RUN: would open on wakizashi" <<<"$out" \
  && ok "logged out: the unlock window path runs vault-login.sh instead of a copy-paste line" || bad "logged-out window: rc=$rc out=$out"
rm -f "$T/.claude/scripts/vault-login.sh"; out=$(run env VAULT_GATE_DRY_RUN=1); rc=$?
[ $rc -eq 0 ] && grep -q "VAULT: not logged in" <<<"$out" && ok "logged out with no installed copy: the repo's own vault-login.sh beside the hook is the fallback" || bad "logged-out repo fallback: rc=$rc out=$out"
# neither the installed copy nor one beside the hook (a gate copied away from the repo): a loud refusal naming the installer
mkdir -p "$T/gate"; cp "$R/vault-gate.sh" "$T/gate/vault-gate.sh"
out=$(PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" HOME="$T" VAULT_GATE_BW="$T/bin/bw" VAULT_GATE_SSH="$T/bin/ssh" VAULT_GATE_MAX_WAIT=2 REMOTE_DESKTOPS="ghost katana wakizashi" VAULT_GATE_DRY_RUN=1 bash "$T/gate/vault-gate.sh" 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q "no vault-login.sh is installed" <<<"$out" && ok "logged out with no vault-login.sh anywhere: a loud refusal naming the installer" || bad "logged-out no-script: rc=$rc out=$out"
printf '#!/bin/sh\necho %s\n' "'{\"status\":\"locked\"}'" > "$T/bin/bw"; chmod +x "$T/bin/bw"   # back to the locked stub
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
out=$(PATH="$T/bin:$PATH" HOME="$T" bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q "no vault on this host" <<<"$out" && ok "wrapper on a host with no CLI: exit 2, says why" || bad "wrapper no CLI: rc=$rc out=$out"
mkdir -p "$T/.npm-global/bin"; printf '#!/bin/sh\necho real-cli-ran\n' > "$T/.npm-global/bin/bw"; chmod +x "$T/.npm-global/bin/bw"
out=$(PATH="$T/bin:$PATH" HOME="$T" BW_SESSION=x bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = real-cli-ran ] && ok "wrapper with a CLI present: execs it" || bad "wrapper with CLI: rc=$rc out=$out"
printf 'LANE_HOST=1\n' > "$T/.config/vault-gate/config"
out=$(PATH="$T/bin:$PATH" HOME="$T" BW_SESSION=x bash "$R/bw-wrapper.sh" status 2>&1); rc=$?
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
# cli-lock.sh + check-cli-state.sh (row 89ba0555): one vault CLI process at a time; a wiped state is refused and loud
CL="$T/cl"; mkdir -p "$CL/bin" "$CL/run" "$CL/checks" "$CL/data" "$CL/home/.local/bin"; chmod 700 "$CL/run"
printf '#!/bin/sh\necho "$*" >> "%s/raven.log"\n' "$CL" > "$CL/home/.local/bin/raven"; chmod +x "$CL/home/.local/bin/raven"
# a fake CLI entry shaped like familiar's wrapper: a shebang, then the program; it logs start/end around a 1 s run
mkentry() { rm -f "$CL/bin/cli"; printf '#!/bin/sh\n# Wrapper: pinned node\necho "start $$" >> "%s/order.log"; sleep 1; echo "end $$" >> "%s/order.log"\n' "$CL" "$CL" > "$CL/bin/cli"; chmod +x "$CL/bin/cli"; }
mkentry
E() { HOME="$CL/home" BITWARDENCLI_APPDATA_DIR="$CL/data" XDG_RUNTIME_DIR="$CL/run" "$@"; }
cl() { VAULT_CLI_ENTRY="$CL/bin/cli" XDG_RUNTIME_DIR="$CL/run" bash "$R/cli-lock.sh" "$@"; }
interleaved() { : > "$CL/order.log"; E "$CL/bin/cli" x & E "$CL/bin/cli" x & wait
  [ "$(cut -d' ' -f1 "$CL/order.log" | tr '\n' ' ')" != "start end start end " ]; }
cl check >/dev/null; r0=$?; interleaved; il0=$?
[ $r0 = 1 ] && [ $il0 = 0 ] && ok "control: an unwrapped entry reads UNLOCKED and two concurrent runs interleave" || bad "control: check=$r0 interleaved-rc=$il0"
cl install >/dev/null && cl check >/dev/null; r1=$?; interleaved; il1=$?
[ $r1 = 0 ] && [ $il1 = 1 ] && [ -f "$CL/bin/cli.pre-cli-lock" ] && ok "install: the wrapper is locked, two concurrent runs serialize, a backup is kept" || bad "install: check=$r1 order=$(tr '\n' ' ' < "$CL/order.log")"
sum1=$(sha256sum < "$CL/bin/cli"); cl install >/dev/null; [ "$(sha256sum < "$CL/bin/cli")" = "$sum1" ] && ok "install twice: unchanged (idempotent)" || bad "install not idempotent"
( exec 9>>"$CL/run/vault-cli.lock"; flock 9; sleep 3 ) & hp=$!; sleep 0.3
out=$(VAULT_CLI_LOCK_WAIT=1 E "$CL/bin/cli" x 2>&1); rc=$?; wait $hp
[ $rc = 75 ] && grep -q "vault CLI busy" <<<"$out" && ok "a lock held past VAULT_CLI_LOCK_WAIT: exit 75, says why" || bad "lock wait: rc=$rc out=$out"
( exec 9>>"$CL/run/vault-cli.lock"; flock 9; sleep 3 ) & hp=$!; sleep 0.3
s0=$(date +%s); VAULT_CLI_LOCK_WAIT=2 E "$CL/bin/cli" unlock >/dev/null 2>&1; rcu=$?; s1=$(date +%s); wait $hp
[ $rcu = 0 ] && [ $((s1 - s0)) -le 1 ] && ok "unlock runs at once while another CLI holds the lock (no wait)" || bad "unlock waited: rc=$rcu took $((s1 - s0)) s"
# the stub guard (Sen 21:35): a wiped data.json refuses everything but the recovery set, and mails the lead ONCE
printf '{"stateVersion":67}' > "$CL/data/data.json"; : > "$CL/raven.log"; : > "$CL/order.log"
out=$(E "$CL/bin/cli" get item 2>&1); rc=$?; out2=$(E "$CL/bin/cli" list items 2>&1); rc2=$?
[ $rc = 76 ] && [ $rc2 = 76 ] && grep -q "state is WIPED" <<<"$out" && [ ! -s "$CL/order.log" ] && [ "$(grep -c 'state WIPED' "$CL/raven.log")" = 1 ] \
  && ok "stub guard: get/list on a wiped state exit 76 without running the CLI; the lead is mailed once" || bad "stub guard: rc=$rc/$rc2 ran=$(wc -l < "$CL/order.log") mails=$(grep -c . "$CL/raven.log") out=$out"
: > "$CL/order.log"; E "$CL/bin/cli" login >/dev/null 2>&1; E "$CL/bin/cli" status >/dev/null 2>&1
[ "$(grep -c '^start' "$CL/order.log")" = 2 ] && ok "stub guard: login and status still run on a wiped state (the recovery set)" || bad "stub recovery: $(tr '\n' ' ' < "$CL/order.log")"
# (Oracle r2) an argument value never reaches stderr or the mail; the mail never holds the host lock
rm -f "$CL/run/vault-cli-stub.told"; : > "$CL/raven.log"
out=$(E "$CL/bin/cli" --session=FAKE-TOKEN-123 list items 2>&1)
! grep -q 'FAKE-TOKEN' <<<"$out" && ! grep -q 'FAKE-TOKEN' "$CL/raven.log" && grep -q 'refusing "--session"' <<<"$out" \
  && ok "stub guard: an argument's value (--session=…) never reaches stderr or the lead's mail" || bad "arg leak: out=$out mail=$(cat "$CL/raven.log")"
printf '#!/bin/sh\nsleep 3\necho "$*" >> "%s/raven.log"\n' "$CL" > "$CL/home/.local/bin/raven"; rm -f "$CL/run/vault-cli-stub.told"
E "$CL/bin/cli" get item >/dev/null 2>&1 & gp=$!; sleep 0.5
s0=$(date +%s); E "$CL/bin/cli" status >/dev/null 2>&1; s1=$(date +%s); wait $gp
[ $((s1 - s0)) -le 1 ] && ok "stub guard: the lead's mail runs without the host lock (a concurrent status did not wait on it)" || bad "mail held the lock: status waited $((s1 - s0)) s"
printf '#!/bin/sh\necho "$*" >> "%s/raven.log"\n' "$CL" > "$CL/home/.local/bin/raven"
printf '{"stateVersion":67,"global_account_activeAccountId":"x"}' > "$CL/data/data.json"; E "$CL/bin/cli" get item >/dev/null 2>&1
[ ! -e "$CL/run/vault-cli-stub.told" ] && ok "stub guard: a healthy state clears the told-stamp (the next wipe mails again)" || bad "stub stamp not cleared"
cl remove >/dev/null && cl check >/dev/null; [ $? = 1 ] && ! grep -q 'cli-lock' "$CL/bin/cli" && ok "remove: the original entry is back" || bad "remove failed"
# npm's symlink shape; the Oracle's sequence: a SECOND install after the entry became a plain script must never write
# through the first install's backup symlink into the CLI's own code
if command -v node >/dev/null; then
  odd="$CL/odd dir 'q' é"; mkdir -p "$odd"; printf 'console.log("node-cli " + process.argv.slice(2).join(" "))\n' > "$odd/cli.js"
  js_sum=$(sha256sum < "$odd/cli.js"); rm -f "$CL/bin/cli" "$CL/bin/cli.pre-cli-lock"; ln -s "$odd/cli.js" "$CL/bin/cli"
  LC_ALL=C cl install >/dev/null; out=$(E "$CL/bin/cli" status 2>&1)
  cl check >/dev/null && [ "$out" = "node-cli status" ] && [ -L "$CL/bin/cli.pre-cli-lock" ] && head -1 "$CL/bin/cli" | grep -q '^#!/bin/sh' \
    && ok "install on npm's symlink to an odd path (space, quote, é; LC_ALL=C): a /bin/sh script that runs node on it" || bad "symlink install: out=$out"
  mkentry; cl install >/dev/null; [ "$(sha256sum < "$odd/cli.js")" = "$js_sum" ] && [ ! -L "$CL/bin/cli.pre-cli-lock" ] \
    && ok "a second install over a backup symlink replaces the backup, never writes through it (the CLI's code untouched)" || bad "second install damaged the CLI's code"
  printf 'echo hi\n' > "$CL/tool.sh"; rm -f "$CL/bin/cli" "$CL/bin/cli.pre-cli-lock"; ln -s "$CL/tool.sh" "$CL/bin/cli"
  cl install >/dev/null 2>&1; [ $? = 1 ] && [ -L "$CL/bin/cli" ] && ok "a symlink to a non-.js target is refused, nothing changed" || bad "non-js symlink accepted"
  # the native standalone build (wakizashi): a real ELF (perl; asserted ELF below) stays reachable under its OWN name
  # via a hard link in .cli-lock-real/, the backup is a second hard link, and the entry is never missing. A native build
  # is wrapped only when its sha256 is listed in VAULT_CLI_ELF_OK (xreview r3: directory independence is verified per
  # build by a person, never assumed)
  hexof() { sha256sum < "$1" | cut -d' ' -f1; }
  rm -rf "$CL/bin/cli" "$CL/bin/cli.pre-cli-lock" "$CL/bin/.cli-lock-real"; cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; elf_sum=$(sha256sum < "$CL/bin/cli"); elf_hex=$(hexof "$CL/bin/cli")
  [ "$(head -c 4 "$CL/bin/cli" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && ok "fixture: the stand-in CLI is a real ELF (the ELF branch runs, not the shebang one)" || bad "fixture is not an ELF"
  out=$(cl install 2>&1); rc=$?
  [ $rc = 1 ] && grep -q 'not listed in VAULT_CLI_ELF_OK' <<<"$out" && [ "$(sha256sum < "$CL/bin/cli")" = "$elf_sum" ] && [ ! -e "$CL/bin/cli.pre-cli-lock" ] \
    && ok "a native build whose sha256 is not in VAULT_CLI_ELF_OK is refused, unchanged" || bad "unlisted elf: rc=$rc out=$out"
  VAULT_CLI_ELF_OK="0000 $elf_hex" cl install >/dev/null; out=$(E "$CL/bin/cli" -e 'print "@ARGV|" . $^X' hello elf 2>&1)
  cl check >/dev/null && [ "${out%%|*}" = "hello elf" ] && [ "${out##*/}" = cli ] && [ "$(stat -c %h "$CL/bin/.cli-lock-real/cli")" = 2 ] \
    && [ "$(sha256sum < "$CL/bin/cli.pre-cli-lock")" = "$elf_sum" ] && head -1 "$CL/bin/cli" | grep -q '^#!/bin/sh' \
    && ok "install on a listed native binary: it runs under its own name (argv basename 'cli'), args kept; real + backup are one inode (no copy)" || bad "elf install: out=$out"
  ( exec 9>>"$CL/run/vault-cli.lock"; flock 9; sleep 3 ) & hp=$!; sleep 0.3
  out=$(VAULT_CLI_LOCK_WAIT=1 E "$CL/bin/cli" x 2>&1); rc=$?; wait $hp
  [ $rc = 75 ] && ok "the native binary's entry waits on the host lock like the others" || bad "elf lock: rc=$rc out=$out"
  # an interrupted state (entry gone, backup there) is never a silent "nothing to wrap": install says to run remove
  mv "$CL/bin/cli" "$CL/bin/cli.moved"; out=$(cl install 2>&1); rc=$?; mv "$CL/bin/cli.moved" "$CL/bin/cli"
  [ $rc = 1 ] && grep -q "run cli-lock.sh remove" <<<"$out" && ok "a missing entry with a backup present: install says to run remove (no silent nothing-to-wrap)" || bad "interrupted: rc=$rc out=$out"
  # xreview r2+r3: a wrapper already waiting on the lock while remove, a NEW build landing (an update), and a re-install
  # run still runs a CLI afterwards (the real path is published by one rename, never unlinked first)
  ( exec 9>>"$CL/run/vault-cli.lock"; flock 9; sleep 1.5 ) & hp=$!; sleep 0.3
  E "$CL/bin/cli" -e 'print "inflight-ran"' > "$CL/inflight.out" 2>&1 & ip=$!; sleep 0.3
  cl remove >/dev/null; cp "$CL/bin/cli" "$CL/bin/cli.upd"; mv -f "$CL/bin/cli.upd" "$CL/bin/cli"   # same bytes, a new inode
  VAULT_CLI_ELF_OK="$elf_hex" cl install >/dev/null; r_inst=$?; wait $hp; wait $ip
  [ "$(cat "$CL/inflight.out")" = inflight-ran ] && [ $r_inst = 0 ] && cl check >/dev/null && [ "$CL/bin/.cli-lock-real/cli" -ef "$CL/bin/cli.pre-cli-lock" ] \
    && ok "a wrapper waiting on the lock through remove + an update + re-install still ran; the new build is the published one" || bad "inflight: install=$r_inst out=$(cat "$CL/inflight.out")"
  cl remove >/dev/null; VAULT_CLI_ELF_OK="$elf_hex" cl install >/dev/null && cl check >/dev/null \
    && ok "remove + re-install of the SAME build (same inode already published) succeeds" || bad "same-build reinstall failed"
  cl remove >/dev/null; [ "$(sha256sum < "$CL/bin/cli")" = "$elf_sum" ] && [ ! -e "$CL/bin/cli.pre-cli-lock" ] \
    && ok "remove on a native binary: the binary is back byte-identical" || bad "elf remove"
  # xreview r4: an update REPLACING the entry between the check and the publish never gets an unlisted build wrapped:
  # the checked candidate is what is published and backed up
  cl remove >/dev/null 2>&1; rm -rf "$CL/bin/.cli-lock-real" "$CL/bin/cli.pre-cli-lock"
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli")
  cp "$CL/bin/cli" "$CL/unlisted"; printf 'UNLISTED' >> "$CL/unlisted"; unl=$(hexof "$CL/unlisted")
  CLI_LOCK_TEST_AFTER_CANDIDATE="cp '$CL/unlisted' '$CL/bin/cli.x' && mv -f '$CL/bin/cli.x' '$CL/bin/cli'" VAULT_CLI_ELF_OK="$listed" cl install >/dev/null 2>&1
  [ "$(hexof "$CL/bin/.cli-lock-real/cli")" = "$listed" ] && [ "$(hexof "$CL/bin/cli.pre-cli-lock")" = "$listed" ] && cl check >/dev/null \
    && [ -z "$(ls "$CL/bin/.cli-lock-real" | grep -E 'cand|new')" ] \
    && ok "an entry replaced right after the candidate: the LISTED build is published and backed up, never the replacement; no temp links left" \
    || bad "race: real=$(hexof "$CL/bin/.cli-lock-real/cli" | cut -c1-8) bak=$(hexof "$CL/bin/cli.pre-cli-lock" 2>/dev/null | cut -c1-8) listed=${listed:0:8} unlisted=${unl:0:8}"
  cl remove >/dev/null 2>&1; rm -rf "$CL/bin/.cli-lock-real"
  # xreview r5: an entry swapped for a SYMLINK (to a listed ELF) right before the candidate is refused, nothing changed
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; cp "$CL/bin/cli" "$CL/listed.elf"; listed=$(hexof "$CL/listed.elf")
  out=$(CLI_LOCK_TEST_BEFORE_CANDIDATE="ln -sfn '$CL/listed.elf' '$CL/bin/cli.s' && mv -fT '$CL/bin/cli.s' '$CL/bin/cli'" VAULT_CLI_ELF_OK="$listed" cl install 2>&1); rc=$?
  [ $rc = 1 ] && grep -q "changed into a symlink" <<<"$out" && [ ! -e "$CL/bin/cli.pre-cli-lock" ] && [ -z "$(ls -A "$CL/bin/.cli-lock-real" 2>/dev/null | grep -vx cli)" ] \
    && ok "an entry swapped for a symlink right before the candidate: refused, nothing published or backed up" || bad "symlink swap: rc=$rc out=$out"
  rm -f "$CL/bin/cli"; rm -rf "$CL/bin/.cli-lock-real"
  # xreview r6: a planted symlink at the published path (back to the entry) is replaced by the real build, never kept
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli"); mkdir -p "$CL/bin/.cli-lock-real"
  ln -s ../cli "$CL/bin/.cli-lock-real/cli"
  VAULT_CLI_ELF_OK="$listed" cl install >/dev/null 2>&1; out=$(E timeout 10 "$CL/bin/cli" -e 'print "ran-real"' 2>&1)   # bounded: a self-exec loop must FAIL, not hang
  [ ! -L "$CL/bin/.cli-lock-real/cli" ] && [ "$(hexof "$CL/bin/.cli-lock-real/cli")" = "$listed" ] && [ "$out" = ran-real ] \
    && ok "a planted symlink at the published path is replaced by the listed build (the wrapper runs the CLI, never itself)" || bad "planted real symlink: out=$out"
  cl remove >/dev/null 2>&1; rm -rf "$CL/bin/.cli-lock-real"
  # and a .cli-lock-real that is itself a symlink is refused
  mkdir -p "$CL/elsewhere"; ln -s "$CL/elsewhere" "$CL/bin/.cli-lock-real"
  out=$(VAULT_CLI_ELF_OK="$listed" cl install 2>&1); rc=$?; rm -f "$CL/bin/.cli-lock-real"
  [ $rc = 1 ] && grep -q "is a symlink: refusing" <<<"$out" && [ -z "$(ls -A "$CL/elsewhere")" ] && ok "a .cli-lock-real dir that is a symlink is refused, nothing written through it" || bad "dir symlink: rc=$rc out=$out"
  # xreview r7: a DIRECTORY planted at the published path makes install fail, the entry unchanged (mv -T)
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli"); mkdir -p "$CL/bin/.cli-lock-real/cli"
  out=$(VAULT_CLI_ELF_OK="$listed" cl install 2>&1); rc=$?
  [ $rc = 1 ] && [ "$(hexof "$CL/bin/cli")" = "$listed" ] && [ ! -e "$CL/bin/cli.pre-cli-lock" ] && [ -z "$(ls -A "$CL/bin/.cli-lock-real/cli")" ] \
    && ok "a directory planted at the published path: install fails, the entry and the directory unchanged" || bad "planted dir: rc=$rc out=$out"
  rm -rf "$CL/bin/.cli-lock-real"
  # xreview r8: a directory planted at the STAGING path (cli.new.<pid>) makes install fail too (ln -T), nothing published
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli"); rm -rf "$CL/bin/.cli-lock-real"
  out=$(CLI_LOCK_TEST_AFTER_CANDIDATE='mkdir "$(dirname "$0")/x" 2>/dev/null; mkdir "'"$CL"'/bin/.cli-lock-real/cli.new.$PPID"' VAULT_CLI_ELF_OK="$listed" cl install 2>&1); rc=$?
  [ $rc = 1 ] && [ "$(hexof "$CL/bin/cli")" = "$listed" ] && [ ! -e "$CL/bin/cli.pre-cli-lock" ] && [ ! -e "$CL/bin/.cli-lock-real/cli" ] \
    && ok "a directory planted at the staging path: install fails, the entry unchanged, nothing published or backed up" || bad "staging dir: rc=$rc out=$out real=$(ls -la "$CL/bin/.cli-lock-real" 2>&1 | tail -2 | tr '\n' ' ')"
  rm -rf "$CL/bin/.cli-lock-real"
  # a directory planted at the BACKUP path: install fails before the entry is replaced (never a wrapper without a backup)
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli"); mkdir -p "$CL/bin/cli.pre-cli-lock"
  out=$(VAULT_CLI_ELF_OK="$listed" cl install 2>&1); rc=$?
  [ $rc = 1 ] && grep -qE "cannot write the backup|Is a directory" <<<"$out" && [ "$(hexof "$CL/bin/cli")" = "$listed" ] && [ -z "$(ls -A "$CL/bin/cli.pre-cli-lock")" ] \
    && ok "a directory planted at the backup path: install fails, the entry unchanged" || bad "backup dir: rc=$rc out=$out"
  rmdir "$CL/bin/cli.pre-cli-lock"; rm -rf "$CL/bin/.cli-lock-real"
  # xreview r9: remove recovers an install interrupted after the backup link (entry and backup are one inode)
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; listed=$(hexof "$CL/bin/cli"); ln -T "$CL/bin/cli" "$CL/bin/cli.pre-cli-lock"
  out=$(cl remove 2>&1); rc=$?
  [ $rc = 0 ] && [ ! -e "$CL/bin/cli.pre-cli-lock" ] && [ "$(hexof "$CL/bin/cli")" = "$listed" ] && [ "$(stat -c %h "$CL/bin/cli")" = 1 ] \
    && ok "remove after an install interrupted at the backup link: the extra link goes, the program stays" || bad "interrupted remove: rc=$rc out=$out"
  # second line: even a LISTED build that names $ORIGIN or ${ORIGIN}, or has the CLI's bw-data beside it, is refused
  for tok in '$ORIGIN' '${ORIGIN}'; do
    cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; printf 'RUNPATH=%s/lib' "$tok" >> "$CL/bin/cli"; sum_o=$(sha256sum < "$CL/bin/cli")
    out=$(VAULT_CLI_ELF_OK="$(hexof "$CL/bin/cli")" cl install 2>&1); rc=$?
    [ $rc = 1 ] && grep -q 'ORIGIN' <<<"$out" && [ "$(sha256sum < "$CL/bin/cli")" = "$sum_o" ] && ok "a listed ELF that names $tok is still refused, unchanged" || bad "origin $tok: rc=$rc out=$out"
  done
  cp "$(readlink -f "$(command -v perl)")" "$CL/bin/cli"; mkdir -p "$CL/bin/bw-data"
  out=$(VAULT_CLI_ELF_OK="$elf_hex" cl install 2>&1); rc=$?; rmdir "$CL/bin/bw-data"
  [ $rc = 1 ] && grep -q 'data dir sits beside' <<<"$out" && ok "a listed ELF with the CLI's bw-data beside it is still refused" || bad "bw-data: rc=$rc out=$out"
else
  bad "node is not on PATH: the symlink cases cannot run (never a silent skip)"
fi
# CHECK vault-cli-state: under the same lock; wiped/out/unreadable fail, in+locked ok, in+unlocked warn, busy warn
rm -f "$CL/bin/cli" "$CL/bin/cli.pre-cli-lock"; mkentry; cl install >/dev/null
cs() { VAULT_CLI_ENTRY="$CL/bin/cli" VAULT_CLI_DATA="$CL/data/data.json" CHECKS_DIR="$CL/checks" XDG_RUNTIME_DIR="$CL/run" "$@" bash "$R/check-cli-state.sh" >/dev/null 2>&1; cat "$CL/checks/vault-cli-state.line" 2>/dev/null; }
printf '{"stateVersion":67}' > "$CL/data/data.json"; l=$(cs env)
[[ "$l" == "CHECK vault-cli-state fail · "*"state was wiped"* ]] && ok "CHECK: stateVersion-only → fail (wiped)" || bad "CHECK stub: $l"
printf '{"stateVersion":67,"global_environment_x":{}}' > "$CL/data/data.json"; l=$(cs env)
[[ "$l" == "CHECK vault-cli-state fail · "*"no active account"* ]] && ok "CHECK: keys but no active account → fail (logged out), never ok" || bad "CHECK out: $l"
printf '{"stateVersion":67,"global_account_activeAccountId":"x"}' > "$CL/data/data.json"; l=$(cs env)
[[ "$l" == "CHECK vault-cli-state ok · "* ]] && ! grep -q '"x"\|· x' <<<"$l" && ok "CHECK: an active account + locked entry → ok (no value printed)" || bad "CHECK ok: $l"
( exec 9>>"$CL/run/vault-cli.lock"; flock 9; sleep 3 ) & hp=$!; sleep 0.3; l=$(cs env CHECK_LOCK_WAIT=1); wait $hp
[[ "$l" == "CHECK vault-cli-state warn · "*"held the host lock"* ]] && ok "CHECK: reads only under the lock (busy → warn, never a false fail)" || bad "CHECK busy: $l"
cl remove >/dev/null; l=$(cs env); [[ "$l" == "CHECK vault-cli-state warn · "*"not locked"* ]] && ok "CHECK: an unlocked entry → warn" || bad "CHECK unlocked: $l"
rm -f "$CL/bin/cli" "$CL/checks/vault-cli-state.line"; l=$(cs env); [ -z "$l" ] && ok "CHECK: no CLI on this host (a lane host) → no line" || bad "CHECK no CLI: $l"
# caller ledger (money c81d2860): one line per call in $XDG_RUNTIME_DIR/vault-calls.log, the item name only as a sha prefix,
# the parent's argv with long slashless tokens elided (a value on a command line never lands in the ledger)
rm -f "$T/.config/vault-gate/config" "$T/run/vault-calls.log"; mkdir -p "$T/.npm-global/bin"
printf '#!/bin/sh\necho real-cli-ran\n' > "$T/.npm-global/bin/bw"; chmod +x "$T/.npm-global/bin/bw"
out=$(PATH="$T/bin:$PATH" HOME="$T" XDG_RUNTIME_DIR="$T/run" BW_SESSION=x bash -c 'exec bash "'"$R"'/bw-wrapper.sh" get password "fixture item name" zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' 2>&1)
sha=$(printf '%s' "fixture item name" | sha256sum | cut -c1-12)
l=$(cat "$T/run/vault-calls.log" 2>/dev/null)
[[ "$l" == *"verb=get obj=password item=$sha "* ]] && ! grep -q "fixture item name" <<<"$l" && ! grep -q "zzzzzzzzzzzz" <<<"$l" \
  && ok "wrapper ledger: verb, object, item sha prefix; no item name, no long token" || bad "wrapper ledger: $l"
[ "$(stat -c %a "$T/run/vault-calls.log" 2>/dev/null)" = 600 ] && ok "wrapper ledger: 0600" || bad "wrapper ledger mode: $(stat -c %a "$T/run/vault-calls.log" 2>/dev/null)"
rm -f "$T/run/vault-calls.log"
out=$(PATH="$T/bin:$PATH" HOME="$T" XDG_RUNTIME_DIR="$T/run" BW_SESSION=x VAULT_CALL_LEDGER=0 bash "$R/bw-wrapper.sh" status 2>&1)
[ ! -e "$T/run/vault-calls.log" ] && ok "wrapper ledger: VAULT_CALL_LEDGER=0 writes nothing" || bad "wrapper ledger off still wrote"

echo "$fails failure(s)"; [ "$fails" -eq 0 ]
