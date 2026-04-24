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

echo ">>> Uninstalled."
