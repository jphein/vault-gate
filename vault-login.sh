#!/bin/bash
# vault-login.sh — re-LOGIN the Vaultwarden CLI on this host after a server-side logout (changed master password,
# "deauthorize sessions", or a revoked session) and cache the session token exactly like vault-unlock.sh does.
# Run interactively in a window JP's hands are on: `bw login` asks for the master password (and 2FA if set).
# Never logs the password or the token. Sen 2026-11-07 (familiar CLI logged out at 13:14:59).
# This repo is public: the account (VAULT_EMAIL) and the server (VAULT_SERVER) come from the host's
# ~/.config/vault-gate/config or the environment, never from this file. A lane host (LANE_HOST=1) never logs in.
set -u
BW="$HOME/.npm-global/bin/bw"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SESSION_FILE="$RUNTIME_DIR/bw-session-token"
CFG="$HOME/.config/vault-gate/config"; STORAGE="keyring"; LANE_HOST=0
[ -r "$CFG" ] && . "$CFG" 2>/dev/null || true
command -v secret-tool >/dev/null 2>&1 || STORAGE="file"
EMAIL="${VAULT_EMAIL:-}"; SERVER="${VAULT_SERVER:-}"
[ "$LANE_HOST" = 1 ] && { echo "no vault on this host ($(hostname)): lane hosts never log in"; sleep 4; exit 2; }
[ -n "$EMAIL" ] && [ -n "$SERVER" ] || { echo "set VAULT_EMAIL and VAULT_SERVER in $CFG"; sleep 6; exit 2; }
# the same private runtime dir the gate insists on: the token file lives here
if [ "$(stat -c %u "$RUNTIME_DIR" 2>/dev/null)" != "$(id -u)" ] || [ "$(stat -c %a "$RUNTIME_DIR" 2>/dev/null)" != 700 ]; then
    echo "$RUNTIME_DIR is not a private (0700, mine) runtime dir; refusing to keep the token there"; sleep 6; exit 2
fi
umask 077

cli_status() { BW_SESSION="${1:-}" "$BW" status 2>/dev/null | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo '?'; }

# status FIRST: the CLI refuses `config server` while any account is logged in ("Logout required before server
# config update"), so a merely locked vault must go to the unlock window before anything is changed
status=$(cli_status)
if [ "$status" != "unauthenticated" ]; then
    echo "Status is '$status', not unauthenticated: use the normal unlock window instead."; sleep 4; exit 0
fi
"$BW" config server "$SERVER" >/dev/null 2>&1 || { echo "could not set server $SERVER"; sleep 6; exit 1; }
echo "Vault LOGIN on $(hostname) -> $SERVER: the CLI was logged out server-side. Email $EMAIL; master password + 2FA if asked."

# vault-unlock.sh's token_write: under the gate's token lock; the keyring entry is read back and must EQUAL the new
# token (a stale entry from before the logout would be preferred by the gate and the wrapper), else it is cleared and
# the file holds the token
token_write() {
    local token="$1" readback
    exec 8>"$RUNTIME_DIR/vault-gate.tokenlock"
    flock -w 30 8 || echo "WARNING: token lock busy for 30 s; publishing anyway so the login is not wasted" >&2
    if [ "$STORAGE" = "keyring" ]; then
        printf '%s\n' "$token" | secret-tool store --label="Bitwarden session (vault-gate)" service vault-gate account bw-session 2>/dev/null || true
        readback=$(secret-tool lookup service vault-gate account bw-session 2>/dev/null || true)
        if [ "$readback" != "$token" ]; then
            secret-tool clear service vault-gate account bw-session 2>/dev/null || true
            printf '%s' "$token" > "$SESSION_FILE"; chmod 600 "$SESSION_FILE"
            STORAGE="file"
        fi
    else
        printf '%s' "$token" > "$SESSION_FILE"; chmod 600 "$SESSION_FILE"
    fi
    flock -u 8 2>/dev/null || true
}

token=$("$BW" login "$EMAIL" --raw) || { echo "login failed"; sleep 6; exit 1; }
[ -n "$token" ] || { echo "no session token returned"; sleep 6; exit 1; }
token_write "$token"
verify=$(cli_status "$token")
BW_SESSION="$token" "$BW" sync >/dev/null 2>&1 && echo "synced" || echo "sync failed (run bw sync later)"
unset token
echo "Vault status now: $verify (token cached: $STORAGE). This window closes in 5 s."
sleep 5
