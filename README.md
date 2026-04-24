# vault-gate

Claude Code hook that auto-unlocks your Vaultwarden vault whenever a `bw` command is about to run. When the vault is locked, it pops a Ghostty window where you enter your master password; the `$BW_SESSION` key is captured and cached to `/tmp/bw-session-token` so subsequent `bw` calls in the session just work.

Previously lived scattered across `~/Projects/outline/` with a duplicate unlock helper inside `~/Projects/familiar.realm.watch/ops/scripts/`. This repo centralizes both.

## What's in here

- **`vault-gate.sh`** — PreToolUse hook entry. Checks if the vault is unlocked; if not, spawns `vault-unlock.sh` in a Ghostty window and polls for the session token. Returns exit 0 (allow) on success, exit 2 (block) on failure.
- **`vault-unlock.sh`** — Runs *inside* the Ghostty window. Handles the `bw unlock` prompt, retries on wrong password (up to 5 attempts), writes the session token to `/tmp/bw-session-token` on success.
- **`install.sh`** — Creates symlinks in `~/.claude/scripts/` and registers the hook entry in `~/.claude/settings.local.json` (idempotent).
- **`uninstall.sh`** — Removes symlinks and hook entry.

## How it integrates with Claude Code hooks

Claude Code 2.1+ passes hook input as **JSON on stdin** (not via `$CLAUDE_TOOL_INPUT` env var). The hook command in `settings.local.json` parses it with `jq`:

```bash
TOOL_INPUT="$(jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
if echo "$TOOL_INPUT" | grep -qP '(?<![/\w.-])bw\s|["\x27]bw\s'; then
    bash "$HOME/.claude/scripts/vault-gate.sh"
fi
```

`install.sh` adds this entry if it's not already present.

## Gotchas

- **Display env.** Shells spawned by Claude Code's Bash tool (and hooks under it) don't inherit `DISPLAY`/`WAYLAND_DISPLAY`. `vault-gate.sh` imports these from the running Ghostty process before spawning the unlock window. Without this import Ghostty exits silently, the unlock window never appears, and the hook times out at 120s.
- **PTY for `bw unlock`.** `bw unlock` uses the TTY directly for the password prompt. `vault-unlock.sh` keeps bw's native output visible (padlock, prompt) using `tee` rather than redirecting stdout to a file — the classic `bw unlock --raw > /tmp/session` pattern silently swallows the prompt and the user sees nothing.
- **Absolute paths.** Both scripts use `$HOME/.npm-global/bin/bw` explicitly, because Ghostty-spawned bash shells may not inherit the `~/.npm-global/bin/` PATH.
- **Token cache.** A successful unlock writes `/tmp/bw-session-token` (mode 600). Subsequent `bw` commands within the same session use the cached token; if it expires, the hook re-runs the unlock flow.
- **Hot reload.** `settings.local.json` changes take effect on the next Claude Code session. Running sessions keep the hook config from session start.

## Install

```bash
git clone https://github.com/jphein/vault-gate.git ~/Projects/vault-gate
cd ~/Projects/vault-gate
./install.sh
```

`install.sh` is idempotent — safe to re-run after updates.

## Troubleshooting

- **Hook doesn't fire:** check `/tmp/vault-gate.log`. Tail it and run a `bw` command in Claude Code. If the log is empty, the hook isn't being invoked — verify the entry in `~/.claude/settings.local.json` and restart Claude Code.
- **Ghostty window never opens:** you've hit the display-env issue. Confirm your desktop has a `ghostty` process running (`pgrep -x ghostty`) so the env import works.
- **Wrong password 5 times:** `vault-unlock.sh` writes `failed` to `/tmp/bw-unlock-status` and gives up. Run another `bw` command to restart the flow, or unlock manually: `eval "$(bw unlock --raw)"`.

## License

MIT
