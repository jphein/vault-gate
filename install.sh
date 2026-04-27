#!/bin/bash
# Install vault-gate: symlink scripts into ~/.claude/scripts/ and register
# the PreToolUse-Bash hook in ~/.claude/settings.local.json.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.local.json"
CONFIG_DIR="$HOME/.config/vault-gate"
CONFIG_FILE="$CONFIG_DIR/config"

# Detect installs from inside a live Claude Code session. Rewriting
# ~/.claude/settings.local.json mid-session can detach the in-memory hook
# chain (Claude Code loads hooks at startup, not on file change) — so the
# very hook you just installed silently won't fire until you restart.
if [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] && [ -z "${VAULT_GATE_FROM_CLAUDE:-}" ]; then
    RED='\033[1;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
    {
        echo ""
        printf "${RED}╔══════════════════════════════════════════════════════════════════╗${RESET}\n"
        printf "${RED}║  WARNING: installing vault-gate from inside Claude Code          ║${RESET}\n"
        printf "${RED}╚══════════════════════════════════════════════════════════════════╝${RESET}\n"
        printf "${YELLOW}This rewrites ~/.claude/settings.local.json. Claude Code loads hooks${RESET}\n"
        printf "${YELLOW}at session start, not on file change — modifying it mid-session can${RESET}\n"
        printf "${YELLOW}detach the entire PreToolUse-Bash hook chain until you restart.${RESET}\n"
        printf "${YELLOW}You'll get the wrapper + scripts on disk, but no hook will fire in${RESET}\n"
        printf "${YELLOW}this session — including the vault-gate hook itself.${RESET}\n"
        echo ""
        printf "${YELLOW}Recommended: cancel here, restart Claude Code, then run install.sh${RESET}\n"
        printf "${YELLOW}from a fresh terminal (or set VAULT_GATE_FROM_CLAUDE=1 to skip this${RESET}\n"
        printf "${YELLOW}prompt for automation).${RESET}\n"
        echo ""
    } >&2
    if [ -t 0 ]; then
        read -r -p "Continue anyway? [y/N] " ANSWER
        case "${ANSWER:-}" in
            y|Y|yes|YES) echo "  proceeding (you opted in)" >&2 ;;
            *) echo "  aborted." >&2; exit 1 ;;
        esac
    else
        echo "  non-interactive shell — proceeding. Restart Claude Code afterward." >&2
    fi
fi

echo ">>> Installing vault-gate from ${REPO_ROOT}..."

# 1. Create default config if not present
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
# vault-gate storage backend for the BW session token.
# keyring — GNOME Keyring via secret-tool (recommended, default)
# file    — plaintext file in $XDG_RUNTIME_DIR (mode 700, RAM-backed, not on disk)
STORAGE=keyring
EOF
    echo "  created $CONFIG_FILE (STORAGE=keyring)"
else
    echo "  config exists at $CONFIG_FILE (not overwritten)"
fi

# 2. Symlink scripts
mkdir -p "$CLAUDE_SCRIPTS"
for script in vault-gate.sh vault-unlock.sh; do
    target="$CLAUDE_SCRIPTS/$script"
    src="$REPO_ROOT/$script"
    # Replace existing symlink / file so updates propagate
    rm -f "$target"
    ln -s "$src" "$target"
    echo "  ln -s $src $target"
done

# 3. Install bw wrapper to ~/.local/bin/bw so cached BW_SESSION reaches the real bw
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
WRAPPER_TARGET="$LOCAL_BIN/bw"
WRAPPER_SRC="$REPO_ROOT/bw-wrapper.sh"
if [ -e "$WRAPPER_TARGET" ] && [ ! -L "$WRAPPER_TARGET" ]; then
    echo "  WARNING: $WRAPPER_TARGET exists and is not a symlink — leaving it alone."
    echo "           Move or remove it, then re-run install.sh."
elif [ -L "$WRAPPER_TARGET" ] && [ "$(readlink "$WRAPPER_TARGET")" = "$WRAPPER_SRC" ]; then
    echo "  wrapper already linked: $WRAPPER_TARGET -> $WRAPPER_SRC"
else
    rm -f "$WRAPPER_TARGET"
    ln -s "$WRAPPER_SRC" "$WRAPPER_TARGET"
    echo "  ln -s $WRAPPER_SRC $WRAPPER_TARGET"
fi

# 4. Ensure ~/.local/bin precedes the real bw in PATH (idempotent, marker-guarded)
PATH_MARKER_BEGIN="# >>> vault-gate PATH (added by ~/Projects/vault-gate/install.sh) >>>"
PATH_MARKER_END="# <<< vault-gate PATH <<<"
PATH_SNIPPET="$PATH_MARKER_BEGIN
case \":\$PATH:\" in
    *\":\$HOME/.local/bin:\"*) ;;
    *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;
esac
$PATH_MARKER_END"

for rcfile in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rcfile" ] || continue
    if grep -qF "$PATH_MARKER_BEGIN" "$rcfile"; then
        echo "  PATH snippet already in $rcfile"
    else
        printf '\n%s\n' "$PATH_SNIPPET" >> "$rcfile"
        echo "  appended PATH snippet to $rcfile"
    fi
done

# 5. Register PreToolUse-Bash hook in settings.local.json (idempotent)
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

python3 - <<PYEOF
import json, sys

p = "$SETTINGS"
with open(p) as f:
    s = json.load(f)

s.setdefault("hooks", {}).setdefault("PreToolUse", [])

# Current stdin-JSON format: parse command with jq, then grep for bw
hook_cmd = (
    "TOOL_INPUT=\"\$(jq -r '.tool_input.command // \"\"' 2>/dev/null || echo '')\"; "
    "if echo \"\$TOOL_INPUT\" | grep -qP '(?<![/\\\\w.-])bw\\\\s|[\"\\\\x27]bw\\\\s'; then "
    "bash \"\$HOME/.claude/scripts/vault-gate.sh\"; fi"
)

# Find or create the Bash matcher entry
bash_entry = None
for entry in s["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        bash_entry = entry
        break
if bash_entry is None:
    bash_entry = {"matcher": "Bash", "hooks": []}
    s["hooks"]["PreToolUse"].append(bash_entry)

# Remove any pre-existing vault-gate hook (so this is idempotent)
bash_entry["hooks"] = [
    h for h in bash_entry.get("hooks", [])
    if "vault-gate" not in h.get("command", "")
]

# Add the current hook
bash_entry["hooks"].append({
    "type": "command",
    "command": hook_cmd,
    "timeout": 130000,
})

with open(p, "w") as f:
    json.dump(s, f, indent=4)

print(f"  registered PreToolUse-Bash vault-gate hook in {p}")
PYEOF

echo ""
echo ">>> Installed."
echo ">>> Restart Claude Code (and re-source your shell rc, or open a new terminal)"
echo ">>> so the PATH change picks up ~/.local/bin/bw ahead of ~/.npm-global/bin/bw."
echo ">>> Config: $CONFIG_FILE"
echo ">>> Logs:   \$XDG_RUNTIME_DIR/vault-gate.log  (e.g. /run/user/$(id -u)/vault-gate.log)"
echo ">>> Verify: \`which bw\` should print $LOCAL_BIN/bw, then a 'bw status' from"
echo ">>>         a fresh Claude Code session should report 'unlocked' after the"
echo ">>>         hook's first unlock prompt completes."
