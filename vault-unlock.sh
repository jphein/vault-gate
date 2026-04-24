#!/bin/bash
# vault-unlock.sh — Interactive vault unlock with Ghostty popup
# Called by vault-gate.sh when vault is locked.
# Writes session token via configured storage backend on success.
# Password input is handled by bw itself (secure TTY read).

set -euo pipefail

BW="$HOME/.npm-global/bin/bw"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATUS_FILE="$RUNTIME_DIR/bw-unlock-status"
OUTPUT_FILE="$RUNTIME_DIR/bw-unlock-output"

# --- Config (must match vault-gate.sh) ---
CONFIG_FILE="$HOME/.config/vault-gate/config"
STORAGE="keyring"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ "$STORAGE" = "keyring" ] && ! command -v secret-tool >/dev/null 2>&1; then
    STORAGE="file"
fi

SESSION_FILE="$RUNTIME_DIR/bw-session-token"

token_write() {
    local token="$1"
    if [ "$STORAGE" = "keyring" ]; then
        printf '%s\n' "$token" | secret-tool store \
            --label="Bitwarden session (vault-gate)" \
            service vault-gate \
            account bw-session 2>/dev/null
    else
        printf '%s' "$token" > "$SESSION_FILE"
        chmod 600 "$SESSION_FILE"
    fi
}

rm -f "$STATUS_FILE" "$OUTPUT_FILE"
echo "pending" > "$STATUS_FILE"

# --- Colors ---
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# --- Spinner ---
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
if [ "$STORAGE" = "keyring" ]; then
    echo -e "  ${DIM}Token will be stored in GNOME Keyring.${RESET}"
else
    echo -e "  ${DIM}Token will be stored in \$XDG_RUNTIME_DIR (RAM, mode 700).${RESET}"
fi
echo ""

ATTEMPTS=0
MAX_ATTEMPTS=5

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    ATTEMPTS=$((ATTEMPTS + 1))

    rm -f "$OUTPUT_FILE"
    "$BW" unlock 2>&1 | tee "$OUTPUT_FILE" || true
    OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null || true)

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

    TOKEN=$(echo "$OUTPUT" | grep -oP 'BW_SESSION="\K[^"]+' || true)

    if [ -n "$TOKEN" ]; then
        stop_spinner
        echo -e "  ${GREEN}${BOLD}Password accepted${RESET}"
        echo ""

        token_write "$TOKEN"
        echo "success" > "$STATUS_FILE"

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
