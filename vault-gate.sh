#!/bin/bash
# vault-gate.sh — Claude Code PreToolUse hook for vault access
# Ensures Vaultwarden is unlocked before any bw command runs.
# If locked, opens Ghostty for interactive unlock, waits for token.
# Exit 0 = allow command, Exit 2 = block command.
# Status messages go to stderr so Claude Code sees them.

BW="${VAULT_GATE_BW:-$HOME/.npm-global/bin/bw}"   # VAULT_GATE_BW: a stub for tests
UNLOCK_SCRIPT="$HOME/.claude/scripts/vault-unlock.sh"
POLL_INTERVAL=1
MAX_WAIT="${VAULT_GATE_MAX_WAIT:-120}"  # seconds (tests shorten it)

# D-Bus address needed for secret-tool in shells spawned outside GNOME session
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

# User-private tmpfs (mode 700, cleaned on logout, not written to disk)
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
umask 077   # every state file here (lock, card, log, token fallback) is private
if [ "$(stat -c %u "$RUNTIME_DIR" 2>/dev/null)" != "$(id -u)" ] || [ "$(stat -c %a "$RUNTIME_DIR" 2>/dev/null)" != 700 ]; then
    echo "BLOCKED: $RUNTIME_DIR is not a private (0700, mine) runtime dir; refusing to keep vault state there." >&2
    exit 2
fi
STATUS_FILE="$RUNTIME_DIR/bw-unlock-status"
LOG="$RUNTIME_DIR/vault-gate.log"

# Always log invocation so the absence of an unlock window doesn't hide whether
# the hook actually fired. Runs before any conditional, regardless of vault state.
{
    echo "[$(date -Iseconds)] entered: pid=$$ ppid=$PPID parent=$(ps -o comm= -p $PPID 2>/dev/null || echo '?') argv=$0"
} >> "$LOG" 2>/dev/null || true

# --- Config ---
# STORAGE=keyring (default) — GNOME Keyring via secret-tool
# STORAGE=file             — plaintext in $XDG_RUNTIME_DIR (mode 700 dir)
CONFIG_FILE="$HOME/.config/vault-gate/config"
STORAGE="keyring"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Fallback to file if secret-tool is unavailable
if [ "$STORAGE" = "keyring" ] && ! command -v secret-tool >/dev/null 2>&1; then
    echo "VAULT: secret-tool not found, falling back to file storage." >&2
    STORAGE="file"
fi

SESSION_FILE="$RUNTIME_DIR/bw-session-token"
LOCKFILE="$RUNTIME_DIR/vault-gate.lockfile"     # flock: the whole launch decision (inspect, reclaim, probe, launch, card)
TOKENLOCK="$RUNTIME_DIR/vault-gate.tokenlock"   # flock: token clear (here) vs token publish (vault-unlock.sh); never held long

# --- Storage helpers ---

token_read() {
    if [ "$STORAGE" = "keyring" ]; then
        local val
        val=$(secret-tool lookup service vault-gate account bw-session 2>/dev/null || true)
        if [ -n "$val" ]; then echo "$val"; return; fi
        # vault-unlock.sh may have fallen back to file if keyring write failed
        [ -f "$SESSION_FILE" ] && cat "$SESSION_FILE" || true
    else
        [ -f "$SESSION_FILE" ] && cat "$SESSION_FILE" || true
    fi
}

token_clear() {   # clear ONLY the value we found stale, under the lock the publisher (vault-unlock.sh) also takes
    local stale="$1"
    (
        flock -w 5 8 || exit 0
        # clear only the backend(s) that actually hold the stale value: a fresh token in the other one survives
        if [ "$STORAGE" = "keyring" ] && [ "$(secret-tool lookup service vault-gate account bw-session 2>/dev/null || true)" = "$stale" ]; then
            secret-tool clear service vault-gate account bw-session 2>/dev/null || true
        fi
        if [ -f "$SESSION_FILE" ] && [ "$(cat "$SESSION_FILE")" = "$stale" ]; then
            rm -f "$SESSION_FILE"
        fi
    ) 8>"$TOKENLOCK"
}

# --- Check if vault is already unlocked ---

TOKEN=$(token_read)
if [ -n "$TOKEN" ]; then
    STATUS=$(BW_SESSION="$TOKEN" "$BW" status 2>/dev/null \
        | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null \
        || echo "unknown")
    case "$STATUS" in
        unlocked)
            exit 0 ;;
        locked|unauthenticated)
            # A DEFINITE answer from bw with this token: it is stale. Never in a dry run (2026-11-06 13:06: a dry run
            # with a stub bw that said "locked" deleted JP's valid 12:42 token; the window and card that followed were real).
            if [ -n "${VAULT_GATE_DRY_RUN:-}" ]; then
                echo "DRY-RUN: bw says $STATUS for the cached token; a real run would clear it. Nothing touched." >&2
                exit 0
            fi
            token_clear "$TOKEN"
            echo "VAULT: Cached token is $STATUS, need fresh unlock." >&2 ;;
        *)
            # No usable answer (bw missing, network, parse error): the token may be fine. Keep it and let the command run.
            echo "VAULT: could not verify the cached token (bw status: $STATUS); keeping it." >&2
            exit 0 ;;
    esac
fi

# Check vault status without a session
STATUS=$("$BW" status 2>/dev/null \
    | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null \
    || echo "unknown")

if [ "$STATUS" = "unauthenticated" ]; then
    echo "BLOCKED: Vault not logged in. Run in a terminal: ~/.npm-global/bin/bw login" >&2
    exit 2
fi

# --- Vault is locked — launch interactive unlock ---

echo "VAULT: Vault is locked. Opening unlock window..." >&2

# The launch decision (inspect the lock, reclaim a stale one, probe, launch) runs under one flock: two callers can
# never both launch, and a fresh lock can never be reclaimed by a late caller. Released before the wait below.
exec 9>"$LOCKFILE"
if ! flock -w 20 9; then
    echo "BLOCKED: another caller is opening the unlock window; retry in a minute." >&2
    exit 2
fi
# A headless host's earlier caller opened a window on a desktop within LOCK_TTL: refuse at once, don't wait MAX_WAIT.
LOCK="$RUNTIME_DIR/vault-gate.remote-open"; LOCK_TTL="${LOCK_TTL:-600}"   # a directory: mkdir is the atomic acquire
if [ -d "$LOCK" ] && [ $(( $(date +%s) - $(stat -c %Y "$LOCK") )) -lt "$LOCK_TTL" ]; then
    echo "BLOCKED: unlock pending, card $(cat "$LOCK/card" 2>/dev/null || echo unfiled): a Vault Unlock window is open on $(cat "$LOCK/desk" 2>/dev/null || echo '?') since $(date -d "@$(stat -c %Y "$LOCK")" +%H:%M). Retry after JP unlocks (tmux 'vault-unlock' on $(hostname))." >&2
    exit 2
fi

if [ -f "$STATUS_FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$STATUS_FILE") )) -ge "$LOCK_TTL" ]; then
    rm -f "$STATUS_FILE"   # an abandoned unlock (window closed mid-way) left "unlocking"/"pending" behind: not proof of a live owner
fi
if [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "unlocking" ]; then
    echo "VAULT: Unlock already in progress, waiting..." >&2
else
    rm -f "$STATUS_FILE"

    {
        echo "[$(date -Iseconds)] storage=$STORAGE unlock_script=$UNLOCK_SCRIPT"
    } >> "$LOG" 2>/dev/null || true

    # --- Where can a window appear? ---
    # A desktop THIS host shows = a seat0 graphical session of this user (loginctl). "Is gnome-shell running" was
    # the wrong test: familiar runs a HEADLESS gnome-shell (wayland-lane2, for the lane browsers), so the window
    # opened on a display nobody looks at and every lane waited out MAX_WAIT (2026-11-06, four lanes x 120 s).
    local_session=""
    for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        info=$(loginctl show-session "$s" -p Name -p Seat -p Type -p Active 2>/dev/null)
        [ "$(sed -n 's/^Name=//p' <<<"$info")" = "$USER" ] || continue
        [ "$(sed -n 's/^Seat=//p' <<<"$info")" = "seat0" ] || continue
        [ "$(sed -n 's/^Active=//p' <<<"$info")" = "yes" ] || continue
        case "$(sed -n 's/^Type=//p' <<<"$info")" in wayland|x11) local_session="$s"; break ;; esac
    done

    if [ -z "$local_session" ]; then
        # Headless: run the unlock here in tmux (vault-unlock.sh: retries, keyring, status file) and open a window
        # on JP's active desktop that attaches to it over ssh. One window per LOCK_TTL; meanwhile every caller is
        # refused at once with the card id instead of waiting out MAX_WAIT.
        SSH="${VAULT_GATE_SSH:-ssh}"
        pick_desktop() {   # the unlocked desktop with the most recent input; else the first reachable; else none
            local h best="" best_idle="" out idle locked
            for h in ${REMOTE_DESKTOP:-${REMOTE_DESKTOPS:-katana wakizashi}}; do
                out=$("$SSH" -o BatchMode=yes -o ConnectTimeout=4 "$h" 'gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null; gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive 2>/dev/null' 2>/dev/null) || continue
                idle=$(sed -n 's/.*uint64 \([0-9][0-9]*\).*/\1/p' <<<"$out" | head -1); locked=$(grep -oE '\((true|false),\)' <<<"$out" | grep -oE 'true|false')
                [ -n "$idle" ] || idle=999999999; [ "$locked" = true ] && idle=$((idle + 1000000000))   # a locked screen loses to any unlocked one
                if [ -z "$best" ] || [ "$idle" -lt "$best_idle" ]; then best="$h"; best_idle="$idle"; fi
            done
            [ -n "$best" ] && echo "$best"
        }
        # Under the flock: the freshness check above already passed, so any lock dir here is stale.
        [ -d "$LOCK" ] && rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || { echo "BLOCKED: cannot create $LOCK" >&2; exit 2; }
        desk=$(pick_desktop)
        if [ -z "$desk" ]; then
            rmdir "$LOCK" 2>/dev/null
            echo "BLOCKED: Vault is locked and no desktop (${REMOTE_DESKTOP:-${REMOTE_DESKTOPS:-katana wakizashi}}) answers. Unlock from a terminal: ssh -t $(hostname) bw unlock" >&2
            exit 2
        fi
        if command -v tmux >/dev/null 2>&1; then
            remote_cmd="ssh -t $(hostname) tmux attach -t vault-unlock"
        else
            remote_cmd="ssh -t $(printf %q "$(hostname)") bash $(printf %q "$HOME/.claude/scripts/vault-unlock-inline.sh")"
        fi
        open_cmd="systemd-run --user --collect --quiet /usr/bin/ghostty --title='Vault Unlock ($(hostname))' -e $remote_cmd"
        if [ -n "${VAULT_GATE_DRY_RUN:-}" ]; then
            echo "DRY-RUN: would open on $desk: $open_cmd" >&2
            rmdir "$LOCK" 2>/dev/null
            exit 0
        fi
        if command -v tmux >/dev/null 2>&1; then
            tmux kill-session -t vault-unlock 2>/dev/null || true
            tmux new-session -d -s vault-unlock "bash '$UNLOCK_SCRIPT'"
        fi
        if ! "$SSH" -o BatchMode=yes -o ConnectTimeout=6 "$desk" "$open_cmd" >/dev/null 2>&1; then
            rm -rf "$LOCK"
            echo "BLOCKED: could not open the unlock window on $desk. Unlock from a terminal: ssh -t $(hostname) tmux attach -t vault-unlock" >&2
            exit 2
        fi
        printf '%s' "$desk" > "$LOCK/desk"; touch "$LOCK"
        card=unfiled
        if command -v ask >/dev/null 2>&1; then
            # --who is mandatory for the gateway (exit 22 without it; 2026-11-11 01:33 the card stayed "unfiled" and
            # nothing said why). A repeat merges into the open vault:unlock card by key, so this is idempotent.
            out=$(ask add --who vault-gate --key vault:unlock --title "Unlock the password vault on $(hostname)" \
                --action "do: type your master password in the 'Vault Unlock ($(hostname))' window on $desk" \
                --minutes 1 --due "$(date +%F)" --lane admin --owner vault-gate \
                --why "agent jobs on $(hostname) wait for the vault; every retry is refused until it is unlocked" \
                --close "file:$SESSION_FILE" 2>&1) && card=$(grep -oE '\b[0-9a-f]{12}\b' <<<"$out" | head -1)
            if [ -z "$card" ] || [ "$card" = unfiled ]; then   # card=unfiled is the preset, so test both
                card=unfiled
                # the gateway's own words go to the log, so an unfiled card is never silent again
                { printf '%s\n' "[$(date -Iseconds)] card unfiled: ask add said: $(tr -d '\000-\011\013-\037\177' <<<"$out" | tr '\n' ' ' | cut -c1-300)"; } >> "$LOG" 2>/dev/null || true
            fi
        fi
        printf '%s' "$card" > "$LOCK/card"
        { echo "[$(date -Iseconds)] headless: window on $desk, card $card"; } >> "$LOG" 2>/dev/null || true
        echo "VAULT: Unlock window opened on $desk (tmux 'vault-unlock' on $(hostname)); card $card. Enter the master password there." >&2
    else
        # A local desktop: import its display env from the seat's gnome-shell (never the --headless one).
        for gui_pid in $(pgrep -u "$USER" -x gnome-shell 2>/dev/null); do
            grep -qa -- '--headless' "/proc/$gui_pid/cmdline" 2>/dev/null && continue
            [ -r "/proc/$gui_pid/environ" ] || continue
            while IFS= read -r var; do
                case "$var" in
                    DISPLAY=*|WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|GDK_BACKEND=*) export "$var" ;;
                esac
            done < <(tr '\0' '\n' < "/proc/$gui_pid/environ")
            break
        done
        export DISPLAY="${DISPLAY:-:0}"
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        [ -d "$LOCK" ] && rm -rf "$LOCK"   # under the flock, and the freshness check above passed: stale
        mkdir "$LOCK" 2>/dev/null && printf '%s' "this desktop" > "$LOCK/desk" && printf 'local' > "$LOCK/card"
        if [ -x /usr/bin/ghostty ]; then
            /usr/bin/ghostty --title="Vault Unlock" -e bash "$UNLOCK_SCRIPT" >/dev/null 2>&1 &
        elif command -v gnome-terminal >/dev/null 2>&1; then
            gnome-terminal -- bash "$UNLOCK_SCRIPT" >/dev/null 2>&1 &
        else
            echo "BLOCKED: No terminal (ghostty/gnome-terminal) found." >&2
            exit 2
        fi
        echo "VAULT: Unlock window opened. Enter master password there." >&2
        disown
    fi
fi

flock -u 9 2>/dev/null || true   # launch done; other callers may now inspect the lock

# --- Wait for unlock to complete ---

WAITED=0
LAST_STATUS=""
while [ $WAITED -lt $MAX_WAIT ]; do
    TOKEN=$(token_read)
    if [ -n "$TOKEN" ]; then
        VERIFY=$(BW_SESSION="$TOKEN" "$BW" status 2>/dev/null \
            | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null \
            || echo "unknown")
        if [ "$VERIFY" = "unlocked" ]; then
            echo "VAULT: Unlocked successfully. Proceeding." >&2
            exit 0
        fi
        case "$VERIFY" in locked|unauthenticated) token_clear "$TOKEN" ;; esac   # only a definite bad token is cleared
    fi

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

    if [ $((WAITED % 10)) -eq 0 ] && [ $WAITED -gt 0 ]; then
        echo "VAULT: Still waiting for unlock... (${WAITED}s/${MAX_WAIT}s)" >&2
    fi
done

echo "BLOCKED: Vault unlock timed out after ${MAX_WAIT}s. Try the bw command again." >&2
exit 2
