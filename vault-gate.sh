#!/bin/bash
# vault-gate.sh — Claude Code PreToolUse hook for vault access
# Ensures Vaultwarden is unlocked before any bw command runs.
# If locked, opens Ghostty for interactive unlock, waits for token.
# Exit 0 = allow command, Exit 2 = block command.
# Status messages go to stderr so Claude Code sees them.

BW="$HOME/.npm-global/bin/bw"
SESSION_FILE="/tmp/bw-session-token"
STATUS_FILE="/tmp/bw-unlock-status"
UNLOCK_SCRIPT="$HOME/.claude/scripts/vault-unlock.sh"
POLL_INTERVAL=1
MAX_WAIT=120  # seconds

# --- Check if vault is already unlocked ---

# First check if we have a cached session that works
if [ -f "$SESSION_FILE" ]; then
    TOKEN=$(cat "$SESSION_FILE")
    STATUS=$(BW_SESSION="$TOKEN" "$BW" status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "unlocked" ]; then
        exit 0  # All good, let the command through
    fi
    # Stale token, clean up
    rm -f "$SESSION_FILE"
    echo "VAULT: Cached token expired, need fresh unlock." >&2
fi

# Check vault status without session
STATUS=$("$BW" status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")

if [ "$STATUS" = "unlocked" ]; then
    echo "VAULT: Unlocked but no session token cached. Re-unlock needed." >&2
    # Fall through to unlock flow instead of blocking
fi

if [ "$STATUS" = "unauthenticated" ]; then
    echo "BLOCKED: Vault not logged in. Run in a terminal: ~/.npm-global/bin/bw login" >&2
    exit 2
fi

# --- Vault is locked — launch interactive unlock ---

echo "VAULT: Vault is locked. Opening unlock window..." >&2

# Check if an unlock is already in progress
if [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "unlocking" ]; then
    echo "VAULT: Unlock already in progress, waiting..." >&2
else
    # Launch Ghostty with unlock script
    rm -f "$SESSION_FILE" "$STATUS_FILE"

    # Import display env from JP's running Ghostty. Shells spawned by the
    # Claude Code Bash tool (and by PreToolUse hooks running under it) do
    # not inherit DISPLAY/WAYLAND_DISPLAY. Without these, ghostty exits
    # silently with no visible window. Pick env from the live Ghostty PID.
    GHOSTTY_PID="$(pgrep -u "$USER" -x ghostty 2>/dev/null | head -1)"
    if [ -n "$GHOSTTY_PID" ] && [ -r "/proc/$GHOSTTY_PID/environ" ]; then
        while IFS= read -r var; do
            case "$var" in
                DISPLAY=*|WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|GDK_BACKEND=*)
                    export "$var"
                    ;;
            esac
        done < <(tr '\0' '\n' < "/proc/$GHOSTTY_PID/environ")
    fi

    # Log the spawn so failures are diagnosable
    LOG="/tmp/vault-gate.log"
    {
        echo "[$(date -Iseconds)] spawn: DISPLAY=${DISPLAY:-unset} WAYLAND=${WAYLAND_DISPLAY:-unset}"
        echo "[$(date -Iseconds)] ghostty_pid=${GHOSTTY_PID:-none} unlock_script=$UNLOCK_SCRIPT"
    } >> "$LOG" 2>/dev/null || true

    snap run ghostty -e bash "$UNLOCK_SCRIPT" >/dev/null 2>&1 &
    disown
    echo "VAULT: Ghostty unlock window opened. Enter master password there." >&2
fi

# --- Wait for unlock to complete, reporting status ---

WAITED=0
LAST_STATUS=""
while [ $WAITED -lt $MAX_WAIT ]; do
    if [ -f "$SESSION_FILE" ]; then
        # Verify the token works
        TOKEN=$(cat "$SESSION_FILE")
        VERIFY=$(BW_SESSION="$TOKEN" "$BW" status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
        if [ "$VERIFY" = "unlocked" ]; then
            echo "VAULT: Unlocked successfully. Proceeding." >&2
            exit 0  # Success — let the command through
        fi
        rm -f "$SESSION_FILE"  # Bad token, keep waiting
    fi

    # Check and relay status changes from the unlock script
    if [ -f "$STATUS_FILE" ]; then
        CURRENT_STATUS=$(cat "$STATUS_FILE" 2>/dev/null)
        if [ "$CURRENT_STATUS" != "$LAST_STATUS" ]; then
            case "$CURRENT_STATUS" in
                unlocking)
                    echo "VAULT: Wrong password entered. Retrying in unlock window..." >&2
                    ;;
                failed)
                    echo "BLOCKED: Vault unlock failed — too many wrong passwords. Try the bw command again to reopen the unlock window." >&2
                    exit 2
                    ;;
            esac
            LAST_STATUS="$CURRENT_STATUS"
        fi
    fi

    sleep $POLL_INTERVAL
    WAITED=$((WAITED + POLL_INTERVAL))

    # Periodic waiting indicator every 10s
    if [ $((WAITED % 10)) -eq 0 ] && [ $WAITED -gt 0 ]; then
        echo "VAULT: Still waiting for unlock... (${WAITED}s/${MAX_WAIT}s)" >&2
    fi
done

echo "BLOCKED: Vault unlock timed out after ${MAX_WAIT}s. Try the bw command again." >&2
exit 2
