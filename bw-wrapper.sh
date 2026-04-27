#!/bin/bash
# bw-wrapper.sh — Bridges vault-gate's cached session token into bw's environment.
#
# Background:
#   vault-gate.sh stores the unlocked $BW_SESSION token in GNOME Keyring (default)
#   or in $XDG_RUNTIME_DIR/bw-session-token. The real `bw` CLI only reads from the
#   $BW_SESSION env var, so without this wrapper the cached token is never picked
#   up and every subsequent `bw` call still reports "Vault is locked".
#
# Install location:
#   ~/.local/bin/bw  (PATH-prepended ahead of ~/.npm-global/bin/bw)

set -e

REAL_BW="$HOME/.npm-global/bin/bw"

if [ -z "${BW_SESSION:-}" ]; then
    CONFIG_FILE="$HOME/.config/vault-gate/config"
    STORAGE="keyring"
    # shellcheck source=/dev/null
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

    RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    SESSION_FILE="$RUNTIME_DIR/bw-session-token"

    TOKEN=""
    if [ "$STORAGE" = "keyring" ] && command -v secret-tool >/dev/null 2>&1; then
        TOKEN=$(secret-tool lookup service vault-gate account bw-session 2>/dev/null || true)
    fi
    if [ -z "$TOKEN" ] && [ -f "$SESSION_FILE" ]; then
        TOKEN=$(cat "$SESSION_FILE" 2>/dev/null || true)
    fi
    if [ -n "$TOKEN" ]; then
        export BW_SESSION="$TOKEN"
    fi
fi

exec "$REAL_BW" "$@"
