#!/bin/bash
# vault-login.sh — re-LOGIN the Vaultwarden CLI on this host after a server-side logout (changed master password,
# "deauthorize sessions", or a revoked session) and cache the session token exactly like vault-unlock.sh does.
# Run interactively in a window JP's hands are on: `bw login` asks for the master password (and 2FA if set).
# Never logs the password or the token. Sen 2026-11-07 (familiar CLI logged out at 13:14:59).
set -u
BW="$HOME/.npm-global/bin/bw"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SESSION_FILE="$RUNTIME_DIR/bw-session-token"
CFG="$HOME/.config/vault-gate/config"; STORAGE="keyring"; LANE_HOST=0
[ -r "$CFG" ] && . "$CFG" 2>/dev/null || true
command -v secret-tool >/dev/null 2>&1 || STORAGE="file"
# this repo is public: the account and the server come from the host's own config (or the environment), never here
EMAIL="${VAULT_EMAIL:-}"; SERVER="${VAULT_SERVER:-}"
[ "$LANE_HOST" = 1 ] && { echo "no vault on this host ($(hostname)): lane hosts never log in"; sleep 4; exit 2; }
[ -n "$EMAIL" ] && [ -n "$SERVER" ] || { echo "set VAULT_EMAIL and VAULT_SERVER in $CFG"; sleep 6; exit 2; }
"$BW" config server "$SERVER" >/dev/null 2>&1 || { echo "could not set server $SERVER"; sleep 6; exit 1; }
echo "Vault LOGIN on $(hostname) -> $SERVER: the CLI was logged out server-side. Email $EMAIL; master password + 2FA if asked."
status=$("$BW" status 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo '?')
if [ "$status" != "unauthenticated" ]; then
    echo "Status is '$status', not unauthenticated: use the normal unlock window instead."; sleep 4; exit 0
fi
token=$("$BW" login "$EMAIL" --raw) || { echo "login failed"; sleep 6; exit 1; }
[ -n "$token" ] || { echo "no session token returned"; sleep 6; exit 1; }
if [ "$STORAGE" = "keyring" ]; then
    printf '%s\n' "$token" | secret-tool store --label="vault-gate bw session" service vault-gate account bw-session 2>/dev/null || STORAGE="file"
fi
( umask 077; printf '%s' "$token" > "$SESSION_FILE" )
verify=$(BW_SESSION="$token" "$BW" status 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo '?')
BW_SESSION="$token" "$BW" sync >/dev/null 2>&1 && echo "synced" || echo "sync failed (run bw sync later)"
unset token
echo "Vault status now: $verify (token cached: $STORAGE + file). This window closes in 5 s."
sleep 5
