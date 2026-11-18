#!/usr/bin/env bash
# check-cli-state.sh — CHECK vault-cli-state (row 89ba0555): one line in ~/.local/state/checks/vault-cli-state.line.
#   fail  the CLI's data.json holds only "stateVersion": its state was wiped (the lowdb race, cli-lock.sh), so it is
#         logged out and every vault read fails until a re-login (vault-login.sh, in a window JP's hands are on)
#   warn  the state is fine but the entry is not locked (cli-lock.sh install)
#   ok    a logged-in state and a locked entry
# Reads only key NAMES, never a value. A host with no CLI (a lane host) writes nothing.
set -u
C=b""w
DATA="${VAULT_CLI_DATA:-$HOME/.config/Bitwarden CLI/data.json}"
OUT="${CHECKS_DIR:-$HOME/.local/state/checks}"
here=$(cd "$(dirname "$0")" && pwd)
"$here/cli-lock.sh" check >/dev/null 2>&1; lk=$?
[ "$lk" = 2 ] && exit 0
keys=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(d)) if isinstance(d,dict) else "?")' "$DATA" 2>/dev/null || echo "?")
mt=$(stat -c %y "$DATA" 2>/dev/null | cut -c1-16)
if [ "$keys" = stateVersion ] || [ "$keys" = "" ]; then
  line="CHECK vault-cli-state fail · $(hostname): the vault CLI's state was wiped at $mt (data.json holds only stateVersion: logged out) · re-login with vault-login.sh in a window JP's hands are on"
elif [ "$keys" = "?" ]; then
  line="CHECK vault-cli-state fail · $(hostname): the vault CLI's data.json is unreadable · look at it before any vault read"
elif [ "$lk" != 0 ]; then
  line="CHECK vault-cli-state warn · $(hostname): state ok, but the CLI entry is not locked (a concurrent start can wipe it) · vault-gate cli-lock.sh install"
else
  line="CHECK vault-cli-state ok · $(hostname): state ok, entry locked · nothing to do"
fi
mkdir -p "$OUT"; tmp=$(mktemp "$OUT/.vault-cli-state.XXXXXX"); printf '%s\n' "$line" > "$tmp"; mv -fT "$tmp" "$OUT/vault-cli-state.line"
printf '%s\n' "$line"
