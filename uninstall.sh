#!/bin/bash
# Uninstall vault-gate: remove symlinks and de-register the hook.
set -euo pipefail

CLAUDE_SCRIPTS="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.local.json"

echo ">>> Uninstalling vault-gate..."

for script in vault-gate.sh vault-unlock.sh; do
    target="$CLAUDE_SCRIPTS/$script"
    if [ -L "$target" ]; then
        rm -f "$target"
        echo "  rm $target"
    fi
done

if [ -f "$SETTINGS" ]; then
    python3 - <<PYEOF
import json
p = "$SETTINGS"
with open(p) as f:
    s = json.load(f)
changed = False
for entry in s.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") == "Bash":
        new_hooks = [h for h in entry.get("hooks", []) if "vault-gate" not in h.get("command", "")]
        if len(new_hooks) != len(entry["hooks"]):
            entry["hooks"] = new_hooks
            changed = True
if changed:
    with open(p, "w") as f:
        json.dump(s, f, indent=4)
    print(f"  removed vault-gate hook from {p}")
PYEOF
fi

# Remove cached session token from wherever it's stored
CONFIG_FILE="$HOME/.config/vault-gate/config"
STORAGE="keyring"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ "$STORAGE" = "keyring" ] && command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service vault-gate account bw-session 2>/dev/null && \
        echo "  cleared vault-gate entry from GNOME Keyring" || true
fi
rm -f "$RUNTIME_DIR/bw-session-token" "$RUNTIME_DIR/bw-unlock-status" \
      "$RUNTIME_DIR/bw-unlock-output" "$RUNTIME_DIR/vault-gate.log"
echo "  cleared runtime files from $RUNTIME_DIR"

echo ""
echo ">>> Uninstalled. Config left at $CONFIG_FILE (remove manually if desired)."
