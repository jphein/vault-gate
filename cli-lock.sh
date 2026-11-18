#!/usr/bin/env bash
# cli-lock.sh — one vault CLI process at a time on this host (row 89ba0555, 2026-11-17).
#
# Why: the CLI (2026.6.0) parses data.json OUTSIDE its own file lock (apps/cli/src/platform/services/
# lowdb-storage.service.ts:76, lock taken only at :70), and lowdb 1.0.0's FileSync writes with a non-atomic
# writeFileSync. A CLI starting while another one writes can read a half-written file; its SyntaxError handler
# (:78-93) then writes {} and the migrations leave {"stateVersion":N}: the CLI is logged out with no logout anywhere.
# familiar 2026-11-07 13:14:59 and 2026-11-17 20:31:13 (load 32, six timer jobs running the CLI at once).
#
# The fix is a host-wide flock around EVERY CLI process, at the one path every caller runs: ~/.npm-global/bin/<cli>
# (vault-gate, the wrapper, xreview and the timers all call it by that path). The lock's fd stays open across exec,
# so it is held for the CLI's whole life.
#
#   cli-lock.sh install   wrap the entry (idempotent): an existing wrapper script gets the lock lines after its
#                         shebang; npm's symlink is replaced by a small script that execs node on its target
#   cli-lock.sh check     exit 0 when the entry holds the lock, 1 when it does not, 2 when there is no CLI
#   cli-lock.sh remove    undo (restores the backup install wrote)
set -euo pipefail
C=b""w
ENTRY="${VAULT_CLI_ENTRY:-$HOME/.npm-global/bin/$C}"
MARK="# vault-gate cli-lock (row 89ba0555)"
# unlock and login wait on a person at a password prompt, sometimes for minutes: holding the host lock through that
# would stall every other caller, vault-gate's own status polling included. They run unlocked: a person is present,
# and CHECK vault-cli-state still catches a wipe.
LOCKLINES='case "${1:-}" in unlock|login) ;; *)
  lock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vault-cli.lock"
  exec 9>>"$lock"
  flock -w "${VAULT_CLI_LOCK_WAIT:-120}" 9 || { echo "vault CLI busy: another CLI process held $lock for ${VAULT_CLI_LOCK_WAIT:-120} s" >&2; exit 75; } ;;
esac'

has_lock() { [ -f "$ENTRY" ] && [ ! -L "$ENTRY" ] && grep -qF "$MARK" "$ENTRY"; }

case "${1:-}" in
check)
  [ -e "$ENTRY" ] || { echo "no vault CLI at $ENTRY"; exit 2; }
  has_lock && { echo "locked entry: $ENTRY"; exit 0; }
  echo "UNLOCKED entry: $ENTRY"; exit 1 ;;
install)
  [ -e "$ENTRY" ] || { echo "no vault CLI at $ENTRY: nothing to wrap"; exit 2; }
  has_lock && { echo "already locked: $ENTRY"; exit 0; }
  bak="$ENTRY.pre-cli-lock"
  tmp="$ENTRY.cli-lock.$$"
  if [ -L "$ENTRY" ]; then
    target=$(readlink -f "$ENTRY")
    [ -f "$target" ] || { echo "the symlink's target is missing: $target"; exit 1; }
    cp -P "$ENTRY" "$bak"
    { printf '#!/bin/sh\n%s\n%s\n' "$MARK" "$LOCKLINES"; printf 'exec node %s "$@"\n' "$(printf '%q' "$target")"; } > "$tmp"
  else
    head -1 "$ENTRY" | grep -q '^#!' || { echo "$ENTRY is not a script with a shebang: refusing to edit it"; exit 1; }
    cp -p "$ENTRY" "$bak"
    { head -1 "$ENTRY"; printf '%s\n%s\n' "$MARK" "$LOCKLINES"; tail -n +2 "$ENTRY"; } > "$tmp"
  fi
  chmod 755 "$tmp"; sh -n "$tmp" || { rm -f "$tmp"; echo "the wrapped entry does not parse: nothing changed"; exit 1; }
  mv -f "$tmp" "$ENTRY"
  echo "locked: $ENTRY (backup $bak)" ;;
remove)
  bak="$ENTRY.pre-cli-lock"
  [ -e "$bak" ] || [ -L "$bak" ] || { echo "no backup at $bak"; exit 1; }
  rm -f "$ENTRY"; mv -f "$bak" "$ENTRY"; echo "restored: $ENTRY" ;;
*) echo "usage: cli-lock.sh install | check | remove" >&2; exit 22 ;;
esac
