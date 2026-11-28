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

# Lane hosts never unlock the vault (Sen 2026-11-17; the same rule as vault-gate.sh): no CLI here, or this host's own
# config says LANE_HOST=1 → say so and stop, instead of exec'ing a missing program
LANE_HOST=0
# shellcheck source=/dev/null
[ -f "$HOME/.config/vault-gate/config" ] && . "$HOME/.config/vault-gate/config"
if [ "$LANE_HOST" = 1 ] || [ ! -x "$REAL_BW" ]; then
    echo "no vault on this host ($(hostname)): lane hosts never unlock the vault; a secret reaches them only as a 0600 file the lead places." >&2
    exit 2
fi

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

# Caller ledger (money c81d2860, 2026-11-28): one line per CLI call so the busiest consumers can be named
# (the 11/27 sampler saw 349 password reads in 2 h and no caller). Never a value: the verb and object word,
# the item NAME only as a sha256 prefix, and the parent's argv with every long slashless token elided.
# Off with VAULT_CALL_LEDGER=0. File: $XDG_RUNTIME_DIR/vault-calls.log (tmpfs, 0600, gone at logout).
if [ "${VAULT_CALL_LEDGER:-1}" != 0 ]; then
    __rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    __verb="${1:-}"; __obj="${2:-}"; __item=""
    case "$__verb" in get|edit|delete) [ -n "${3:-}" ] && __item=$(printf '%s' "$3" | sha256sum | cut -c1-12) ;; esac
    __parent=""
    if [ -r "/proc/$PPID/cmdline" ]; then
        __parent=$(tr '\0' '\n' < "/proc/$PPID/cmdline" | awk 'length($0)>40 && index($0,"/")==0 {print "…"; next} {print}' | tr '\n' ' ' | cut -c1-160)
    fi
    ( umask 077; printf '%s pid=%s ppid=%s verb=%s obj=%s item=%s parent=%s\n' "$(date +%H:%M:%S)" "$$" "$PPID" "$__verb" "$__obj" "$__item" "$__parent" >> "$__rt/vault-calls.log" ) 2>/dev/null || true
fi

exec "$REAL_BW" "$@"
