#!/bin/bash
# vault-unlock-inline.sh: the fallback unlock for a headless host WITHOUT tmux, run inside a terminal that ssh'd in
# with a PTY (ssh -t <host> bash vault-unlock-inline.sh). JP types the master password here. Writes the session
# token where the wrapper reads it: $XDG_RUNTIME_DIR/bw-session-token (mode 600). From Sen's working script of
# 2026-11-06. The normal headless path runs vault-unlock.sh in tmux instead (retries, keyring, status file).
set -u
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SESSION_FILE="$RUNTIME_DIR/bw-session-token"
BW="$HOME/.npm-global/bin/bw"
[ -x "$BW" ] || BW="$(command -v bw)"
echo "Unlocking the vault on $(hostname). Type your master password:"
out=$("$BW" unlock --raw < /dev/tty 2>/dev/tty)
rc=$?
if [ $rc -eq 0 ] && [ -n "$out" ]; then
  umask 077
  printf '%s' "$out" > "$SESSION_FILE"
  chmod 600 "$SESSION_FILE"
  unset out
  echo "Unlocked. Token cached on $(hostname). You can close this window."
  exit 0
fi
echo "Unlock failed (exit $rc). Try again."
exit 1
