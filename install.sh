#!/bin/bash
# Install vault-gate: symlink scripts into ~/.claude/scripts/ and register
# the PreToolUse-Bash hook in ~/.claude/settings.local.json.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SCRIPTS="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.local.json"

echo ">>> Installing vault-gate from ${REPO_ROOT}..."

# 1. Symlink scripts
mkdir -p "$CLAUDE_SCRIPTS"
for script in vault-gate.sh vault-unlock.sh; do
    target="$CLAUDE_SCRIPTS/$script"
    src="$REPO_ROOT/$script"
    # Replace existing symlink / file so updates propagate
    rm -f "$target"
    ln -s "$src" "$target"
    echo "  ln -s $src $target"
done

# 2. Register PreToolUse-Bash hook in settings.local.json (idempotent)
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
echo ">>> Installed. Restart Claude Code for the hook to take effect."
echo ">>> To verify after restart: run any bw command; check /tmp/vault-gate.log."
