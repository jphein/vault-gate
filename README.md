# vault-gate

**[https://jphein.github.io/vault-gate/](https://jphein.github.io/vault-gate/)** · **[GitHub](https://github.com/jphein/vault-gate)**

Claude Code hook that auto-unlocks your Vaultwarden vault whenever a `bw` command is about to run. When the vault is locked, it pops a Ghostty window where you enter your master password; the `$BW_SESSION` token is captured and cached — by default in GNOME Keyring — so subsequent `bw` calls in the session just work.

## What's in here

- **`vault-gate.sh`** — PreToolUse hook entry. Checks if the vault is unlocked; if not, spawns `vault-unlock.sh` in a Ghostty window and polls for the session token. Returns exit 0 (allow) on success, exit 2 (block) on failure.
- **`vault-unlock.sh`** — Runs *inside* the Ghostty window. Handles the `bw unlock` prompt, retries on wrong password (up to 5 attempts), writes the session token via the configured storage backend on success.
- **`install.sh`** — Creates symlinks in `~/.claude/scripts/`, writes a default config to `~/.config/vault-gate/config`, and registers the hook in `~/.claude/settings.local.json` (idempotent).
- **`uninstall.sh`** — Removes symlinks, hook entry, keyring credentials, and runtime files.

## Token storage

Configured via `~/.config/vault-gate/config`:

```bash
# keyring — GNOME Keyring via secret-tool (recommended, default)
# file    — plaintext file in $XDG_RUNTIME_DIR (mode 700, RAM-backed)
STORAGE=keyring
```

| Backend | Where | On disk? | Cleared on logout? |
|---------|-------|----------|--------------------|
| `keyring` | GNOME Keyring (libsecret) | No | Yes (session-tied) |
| `file` | `$XDG_RUNTIME_DIR/bw-session-token` | No (tmpfs) | Yes |

Both backends avoid `/tmp`, which is world-readable by directory even when the file itself is mode 600. `keyring` is default; if `secret-tool` isn't installed, both scripts automatically fall back to `file` with a warning.

Install `secret-tool` on Ubuntu/Debian:

```bash
sudo apt install libsecret-tools
```

## How it integrates with Claude Code hooks

Claude Code passes hook input as **JSON on stdin**. The hook command in `settings.local.json` parses it with `jq`:

```bash
TOOL_INPUT="$(jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
if echo "$TOOL_INPUT" | grep -qP '(?<![/\w.-])bw\s|["\x27]bw\s'; then
    bash "$HOME/.claude/scripts/vault-gate.sh"
fi
```

`install.sh` adds this entry if it's not already present.

## Install

```bash
git clone https://github.com/jphein/vault-gate.git ~/Projects/vault-gate
cd ~/Projects/vault-gate
./install.sh
# restart Claude Code
```

`install.sh` is idempotent — safe to re-run after updates.

## Gotchas

- **Display env.** Shells spawned by Claude Code's Bash tool (and hooks under it) don't inherit `DISPLAY`/`WAYLAND_DISPLAY`. `vault-gate.sh` imports these from the running Ghostty process before spawning the unlock window. Without this import Ghostty exits silently, the unlock window never appears, and the hook times out after 120s.
- **PTY for `bw unlock`.** `bw unlock` uses the TTY directly for the password prompt. `vault-unlock.sh` keeps bw's native output visible using `tee` rather than redirecting stdout — the classic `bw unlock --raw > file` pattern silently swallows the prompt.
- **Absolute paths.** Both scripts use `$HOME/.npm-global/bin/bw` explicitly, because Ghostty-spawned bash shells may not inherit the full PATH.
- **Hot reload.** `settings.local.json` changes take effect on the next Claude Code session. Running sessions keep the hook config from session start.

## Troubleshooting

- **Hook doesn't fire:** tail `$XDG_RUNTIME_DIR/vault-gate.log` and run a `bw` command in Claude Code. If the log is empty, the hook isn't being invoked — verify the entry in `~/.claude/settings.local.json` and restart Claude Code.
- **Ghostty window never opens:** hit the display-env issue. Confirm your desktop has a `ghostty` process running (`pgrep -x ghostty`) so the env import works.
- **Wrong password 5 times:** the script writes `failed` to the status file and gives up. Run another `bw` command to restart the flow, or unlock manually: `eval "$(bw unlock --raw)"`.
- **Keyring fallback message:** if you see `VAULT: secret-tool not found, falling back to file storage`, install `libsecret-tools` (see above) and it will start using keyring automatically.

## License

MIT
