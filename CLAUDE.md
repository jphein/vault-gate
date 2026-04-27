# CLAUDE.md — vault-gate

Project-specific instructions for Claude Code working in this repo.

## What this is

A Claude Code hook that auto-unlocks your Vaultwarden vault when a `bw` command is about to run. Popups a Ghostty window for the password, caches the session token.

## Key constraints

- **Claude Code hook format is stdin-JSON (not env vars).** Migrating from old `$CLAUDE_TOOL_INPUT` to `jq -r '.tool_input.command'` is a known pain point. Don't revert to env vars.
- **Display env is not inherited.** When spawning Ghostty from a hook, import `DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` from the running Ghostty PID. Without this, the unlock window silently fails.
- **Absolute paths everywhere.** Hook shells may not inherit `~/.npm-global/bin` or `/snap/bin`. Use `$HOME/.npm-global/bin/bw` and `/snap/bin/ghostty`.
- **Don't redirect `bw unlock --raw > file`.** Swallows the password prompt. Use `bw unlock` with `tee` to capture output while keeping the PTY.
- **Idempotency matters.** `install.sh` and `uninstall.sh` must be safe to re-run.
- **Hooks can't mutate the next process's env.** PreToolUse hooks gate (exit 0 / 2) but cannot inject `BW_SESSION` into the subsequent `bw` call. That's why `bw-wrapper.sh` exists: a `~/.local/bin/bw` PATH shim that reads the cached token and exports `BW_SESSION` before exec'ing the real bw. Don't try to "fix" this by writing exports into `.bashrc` — Claude Code's Bash tool runs non-interactive non-login shells and won't source it.
- **Don't clobber a non-symlink `~/.local/bin/bw`.** If a user has their own `bw` shim there, leave it; print a warning. The check is `[ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]`.

## Testing

Manual test flow:
```bash
./install.sh
# restart Claude Code
# in a new session, from Claude Code's Bash tool:
bw status  # locked response
bw get password 'some-item'  # Ghostty opens, unlock, token cached
tail "$XDG_RUNTIME_DIR/vault-gate.log"  # verify hook fired
```

## Don't

- Don't reach into `~/.claude/settings.local.json` outside of `install.sh` / `uninstall.sh`. Manual JSON fiddling is how hooks drift.
- Don't write the master password to stdin or any file.
- Don't delete the session token (GNOME Keyring entry or `$XDG_RUNTIME_DIR/bw-session-token`) unless you also re-unlock; the hook's caching logic assumes the stored token is authoritative while present.
- **Storage config** lives at `~/.config/vault-gate/config`. `STORAGE=keyring` (default) uses GNOME Keyring via `secret-tool`; `STORAGE=file` uses `$XDG_RUNTIME_DIR` (mode 700 tmpfs).
