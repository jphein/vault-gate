#!/bin/bash
# Uninstall vault-gate: remove symlinks and de-register the hook.
set -euo pipefail

CLAUDE_SCRIPTS="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.local.json"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

echo ">>> Uninstalling vault-gate..."

for script in vault-gate.sh vault-unlock.sh; do
    target="$CLAUDE_SCRIPTS/$script"
    if [ -L "$target" ]; then
        rm -f "$target"
        echo "  rm $target"
    fi
done

# Remove bw wrapper symlink only if it points at our script
WRAPPER_TARGET="$HOME/.local/bin/bw"
WRAPPER_SRC="$REPO_ROOT/bw-wrapper.sh"
if [ -L "$WRAPPER_TARGET" ] && [ "$(readlink "$WRAPPER_TARGET")" = "$WRAPPER_SRC" ]; then
    rm -f "$WRAPPER_TARGET"
    echo "  rm $WRAPPER_TARGET"
elif [ -e "$WRAPPER_TARGET" ]; then
    echo "  skipped $WRAPPER_TARGET (not our symlink)"
fi

# Remove PATH snippet from rc files (marker-guarded)
PATH_MARKER_BEGIN="# >>> vault-gate PATH (added by ~/Projects/vault-gate/install.sh) >>>"
PATH_MARKER_END="# <<< vault-gate PATH <<<"
for rcfile in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rcfile" ] || continue
    if grep -qF "$PATH_MARKER_BEGIN" "$rcfile"; then
        # Delete the marker block (including markers and inner lines)
        python3 - "$rcfile" "$PATH_MARKER_BEGIN" "$PATH_MARKER_END" <<'PYEOF'
import sys, re
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()
pattern = re.compile(r'\n?' + re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', re.DOTALL)
new_text, n = pattern.subn('\n', text)
if n:
    with open(path, 'w') as f:
        f.write(new_text)
PYEOF
        echo "  removed PATH snippet from $rcfile"
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
