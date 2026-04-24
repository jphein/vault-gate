#!/bin/bash
# vault-unlock.sh — Interactive vault unlock with Ghostty popup
# Called by vault-gate.sh when vault is locked.
# Writes session token to /tmp/bw-session-token on success.
# Password input is handled by bw itself (secure TTY read).
# bw's native output (padlock, prompt) is shown to the user.

set -euo pipefail

BW="$HOME/.npm-global/bin/bw"
SESSION_FILE="/tmp/bw-session-token"
STATUS_FILE="/tmp/bw-unlock-status"
OUTPUT_FILE="/tmp/bw-unlock-output"

rm -f "$SESSION_FILE" "$STATUS_FILE" "$OUTPUT_FILE"
echo "pending" > "$STATUS_FILE"

# --- Colors ---
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# --- Spinner function (runs in background) ---
spinner() {
    local msg="$1"
    local frames=('   ' '.  ' '.. ' '...')
    local i=0
    while true; do
        printf "\r  ${DIM}%s${CYAN}%s${RESET}" "$msg" "${frames[$((i % 4))]}"
        i=$((i + 1))
        sleep 0.3
    done
}

stop_spinner() {
    if [ -n "${SPINNER_PID:-}" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        unset SPINNER_PID
        printf "\r\033[K"
    fi
}

echo ""
echo -e "  ${DIM}Claude Code needs vault access.${RESET}"
echo -e "  ${DIM}Input is hidden — just type and press Enter.${RESET}"
echo ""

ATTEMPTS=0
MAX_ATTEMPTS=5

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    ATTEMPTS=$((ATTEMPTS + 1))

    # Let bw run with its native output visible (padlock, prompt, etc.)
    # tee captures output while displaying it — bw reads password from /dev/tty
    rm -f "$OUTPUT_FILE"
    "$BW" unlock 2>&1 | tee "$OUTPUT_FILE" || true
    OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null || true)

    # Password submitted — show processing feedback
    echo ""
    spinner "Verifying" &
    SPINNER_PID=$!
    sleep 0.3

    if echo "$OUTPUT" | grep -q "Invalid master password"; then
        stop_spinner
        REMAINING=$((MAX_ATTEMPTS - ATTEMPTS))
        echo -e "  ${RED}${BOLD}Wrong password.${RESET} ${DIM}($REMAINING attempts left)${RESET}"
        echo ""
        echo "unlocking" > "$STATUS_FILE"
        continue
    fi

    # Extract session token
    TOKEN=$(echo "$OUTPUT" | grep -oP 'BW_SESSION="\K[^"]+' || true)

    if [ -n "$TOKEN" ]; then
        stop_spinner
        echo -e "  ${GREEN}${BOLD}Password accepted${RESET}"
        echo ""

        # Save token
        echo "$TOKEN" > "$SESSION_FILE"
        chmod 600 "$SESSION_FILE"
        echo "success" > "$STATUS_FILE"

        # Sync vault with feedback
        spinner "Syncing vault" &
        SPINNER_PID=$!
        BW_SESSION="$TOKEN" "$BW" sync --quiet 2>/dev/null || true
        stop_spinner
        echo -e "  ${GREEN}Vault synced${RESET}"
        echo ""

        echo -e "  ${BOLD}${GREEN}UNLOCKED${RESET} ${DIM}— token saved, closing in 2s${RESET}"
        sleep 2
        rm -f "$OUTPUT_FILE"
        exit 0
    fi

    stop_spinner
    echo -e "  ${YELLOW}Unexpected response. Retrying...${RESET}"
    echo ""
done

stop_spinner
rm -f "$OUTPUT_FILE"
echo "failed" > "$STATUS_FILE"
echo ""
echo -e "  ${RED}${BOLD}FAILED${RESET} ${DIM}— too many attempts. Close window and try again.${RESET}"
echo ""
echo -e "  Press Enter to close..."
read -r
exit 1
