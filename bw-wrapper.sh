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
# (the 11/27 sampler saw 349 password reads in 2 h and no caller). Nothing from any command line is copied:
# the verb and the object are written only when they are on the allowlists below (anything else is "other",
# so `unlock <password>` or a stray positional secret never lands here), the item NAME only as a sha256
# prefix, and the parent only as the kernel's view of it (/proc/PPID/exe basename and comm, never argv, which
# `exec -a` can forge). The write goes only into a missing path or an owned regular non-symlink file (a FIFO,
# a symlink, dangling or not, or someone else's file is skipped), is forced to 0600, and runs under a 2 s
# timeout; every helper failure is tolerated, so the ledger can never stop the exec below.
# Off with VAULT_CALL_LEDGER=0. File: $XDG_RUNTIME_DIR/vault-calls.log (tmpfs, gone at logout).
if [ "${VAULT_CALL_LEDGER:-1}" != 0 ]; then
    __rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    __verb=other; __obj=-; __item=-; __parent=-
    case "${1:-}" in
        get|list|create|edit|delete|restore|status|sync|generate|encode|move|share|confirm|send|serve|completion|--version|-v|help|--help) __verb="$1" ;;
    esac
    case "$__verb" in
        get|list|create|edit|delete|restore|move|share)
            case "${2:-}" in
                item|items|username|password|uri|totp|notes|exposed|attachment|folder|folders|collection|collections|organization|organizations|org-collection|org-collections|org-members|template|fingerprint|send|sends) __obj="$2" ;;
                "") __obj=- ;;
                *) __obj=other ;;
            esac ;;
    esac
    case "$__verb" in
        get|edit|delete|restore)
            if [ -n "${3:-}" ]; then
                __item=$( { printf '%s' "$3" | sha256sum | cut -c1-12; } 2>/dev/null ) || __item=-
                case "$__item" in *[!0-9a-f]*|"") __item=- ;; esac
            fi ;;
    esac
    __pexe=$(readlink "/proc/$PPID/exe" 2>/dev/null) || __pexe=""
    __pcomm=$(tr -d '\n' < "/proc/$PPID/comm" 2>/dev/null) || __pcomm=""
    __parent="${__pexe##*/}"; [ -n "$__parent" ] || __parent=-
    [ -n "$__pcomm" ] && [ "$__pcomm" != "$__parent" ] && __parent="$__parent/$__pcomm"
    __parent=$(printf '%s' "$__parent" | tr -c 'A-Za-z0-9._/+-' '_' | cut -c1-48)
    __line="$(date +%H:%M:%S 2>/dev/null || echo -) pid=$$ ppid=$PPID verb=$__verb obj=$__obj item=$__item parent=$__parent"
    ( timeout 2 bash -c '
        rt=$1; line=$2; log="$rt/vault-calls.log"
        [ -d "$rt" ] || exit 0
        [ -L "$log" ] && exit 0
        if [ -e "$log" ]; then { [ -f "$log" ] && [ -O "$log" ]; } || exit 0; chmod 600 "$log" || exit 0; fi
        umask 077; printf "%s\n" "$line" >> "$log"' _ "$__rt" "$__line" ) >/dev/null 2>&1 || true
fi

exec "$REAL_BW" "$@"
