#!/usr/bin/env bash
# check-cli-state.sh — CHECK vault-cli-state (row 89ba0555): one line in ~/.local/state/checks/vault-cli-state.line.
#   fail  data.json holds only "stateVersion" (wiped by the lowdb race: logged out), or no active account (logged out
#         some other way), or it cannot be read: every vault read fails until a re-login (vault-login.sh, in a window
#         JP's hands are on)
#   warn  logged in, but the entry is not locked (cli-lock.sh install); or the CLI held the lock past 30 s (unread)
#   ok    an active account and a locked entry
# Reads under the same host lock the CLI takes (never mid-write), and reads key NAMES and the presence of the active
# account id only, never a value. A host with no CLI (a lane host) writes nothing.
set -u
DATA="${VAULT_CLI_DATA:-${BITWARDENCLI_APPDATA_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/Bitwarden CLI}/data.json}"
OUT="${CHECKS_DIR:-$HOME/.local/state/checks}"
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
here=$(cd "$(dirname "$0")" && pwd)
"$here/cli-lock.sh" check >/dev/null 2>&1; lk=$?
[ "$lk" = 2 ] && exit 0
h=$(hostname -s)
exec 9>>"$RT/vault-cli.lock"
if ! flock -w "${CHECK_LOCK_WAIT:-30}" 9; then
  state=busy
else
  state=$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); sys.exit()
if not isinstance(d, dict): print("unreadable")
elif list(d) == ["stateVersion"]: print("wiped")
elif d.get("global_account_activeAccountId"): print("in")
else: print("out")' "$DATA" 2>/dev/null || echo unreadable)
fi
flock -u 9 2>/dev/null
mt=$(stat -c %y "$DATA" 2>/dev/null | cut -c1-16)
case "$state" in
  wiped)      line="CHECK vault-cli-state fail · $h: the vault CLI's state was wiped at $mt (data.json holds only stateVersion: logged out) · re-login with vault-login.sh in a window JP's hands are on" ;;
  out)        line="CHECK vault-cli-state fail · $h: the vault CLI has no active account (logged out) · re-login with vault-login.sh in a window JP's hands are on" ;;
  unreadable) line="CHECK vault-cli-state fail · $h: the vault CLI's data.json is unreadable · look at it before any vault read" ;;
  busy)       line="CHECK vault-cli-state warn · $h: a CLI held the host lock past ${CHECK_LOCK_WAIT:-30} s, state not read · read it next run" ;;
  in) if [ "$lk" = 0 ]; then line="CHECK vault-cli-state ok · $h: logged in, entry locked · nothing to do"
      else line="CHECK vault-cli-state warn · $h: logged in, but the CLI entry is not locked (a concurrent start can wipe it) · vault-gate cli-lock.sh install"; fi ;;
esac
mkdir -p "$OUT"; tmp=$(mktemp "$OUT/.vault-cli-state.XXXXXX"); printf '%s\n' "$line" > "$tmp"; mv -fT "$tmp" "$OUT/vault-cli-state.line"
printf '%s\n' "$line"
