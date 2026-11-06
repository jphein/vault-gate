# vault-gate

**[https://jphein.github.io/vault-gate/](https://jphein.github.io/vault-gate/)** · **[GitHub](https://github.com/jphein/vault-gate)**

Claude Code hook that auto-unlocks your Vaultwarden vault whenever a `bw` command is about to run. When the vault is locked, it pops a Ghostty window where you enter your master password; the `$BW_SESSION` token is captured and cached — by default in GNOME Keyring — so subsequent `bw` calls in the session just work.

## What's in here

- **`vault-gate.sh`** — PreToolUse hook entry. Checks if the vault is unlocked; if not, spawns `vault-unlock.sh` in a Ghostty window and polls for the session token. Returns exit 0 (allow) on success, exit 2 (block) on failure.
- **`vault-unlock.sh`** — Runs *inside* the Ghostty window. Handles the `bw unlock` prompt, retries on wrong password (up to 5 attempts), writes the session token via the configured storage backend on success.
- **`bw-wrapper.sh`** — Tiny shim symlinked to `~/.local/bin/bw`. Reads the cached session from the configured storage and exports `BW_SESSION` before exec'ing the real `~/.npm-global/bin/bw`. Without this, Claude Code's Bash tool never inherits `BW_SESSION`, so each new `bw` invocation appears locked even after a successful unlock.
- **`install.sh`** — Creates symlinks in `~/.claude/scripts/` and `~/.local/bin/`, ensures `~/.local/bin` precedes the real bw in `PATH` (via a marker-guarded snippet in `.bashrc`/`.profile`), writes a default config to `~/.config/vault-gate/config`, and registers the hook in `~/.claude/settings.local.json` (idempotent).
- **`uninstall.sh`** — Removes symlinks, the hook entry, the PATH snippet, keyring credentials, and runtime files.

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

## Headless hosts (familiar) and the strict matcher (2026-11-06)

- **Where the window appears.** A host that shows a desktop is one with a seat0 graphical session of this user (`loginctl`), not one with a `gnome-shell` process: familiar runs a *headless* gnome-shell for its lane browsers, and the old test sent the window there, where nobody looks, while every lane waited out the 120 s hook timeout. On a headless host the unlock runs in a tmux session `vault-unlock` (the same `vault-unlock.sh`: retries, keyring, status file), and a Ghostty window attaching to it over ssh is opened on JP's active desktop: the unlocked one with the most recent input among `REMOTE_DESKTOPS` (config, default `katana wakizashi`; `REMOTE_DESKTOP=<host>` pins one), via `ssh <desktop> systemd-run --user --collect /usr/bin/ghostty -e ssh -t <host> tmux attach -t vault-unlock`. Without tmux the window runs `vault-unlock-inline.sh` instead.
- **One window per 10 min.** `$XDG_RUNTIME_DIR/vault-gate.remote-open` (and `.card`, the JP-queue ask id filed with `ask add --key vault:unlock`, closed by `--close file:<token>` when the token appears) make every further caller fail at once with `BLOCKED: unlock pending, card <id>` instead of waiting. `LOCK_TTL` (seconds) is configurable.
- **The matcher.** `vault-gate-match.py` gates a command only when `bw` sits at a command position (first word after assignments and wrappers such as sudo/exec/env/timeout; after `; && || | (` or a newline; inside `$( )` or backticks; the `-c` of a shell). Quoted text, heredoc bodies and comments never trip it; a remote `ssh host 'bw …'` does not either; an untokenisable command falls back to the old loose match (fails toward gating). Fixtures: `tests/match-fixtures.txt`.
- **Tests:** `tests/run.sh` (fixtures + the headless path with stubbed loginctl/bw/ssh/tmux/ask, including the lock refusal and a stale lock). `VAULT_GATE_DRY_RUN=1` prints the desktop and the command instead of opening anything.
- **Install on JP's fleet:** the hook line lives in the synced global `~/.claude/settings.json` (claude-config), so run `VAULT_GATE_NO_HOOK=1 ./install.sh` there (symlinks only).

## Why a wrapper is needed

Claude Code's PreToolUse hooks can only allow or block a tool call (exit 0 / exit 2); they cannot mutate the environment of the subsequent process. So when `vault-gate.sh` writes the unlocked `BW_SESSION` into GNOME Keyring (or `$XDG_RUNTIME_DIR`), the next `bw` invocation still has no `BW_SESSION` in its env — it queries the daemon, gets back `locked`, and the cache is effectively useless. The shim at `~/.local/bin/bw` reads the cached token and exports `BW_SESSION` itself before exec'ing the real `bw`, closing the loop. A bash function in `.bashrc` would be cleaner but won't work — Claude Code's Bash tool runs `bash -c '…'` (non-interactive, non-login), which doesn't source `.bashrc` at all.

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
- **Hot reload.** `settings.local.json` changes take effect on the next Claude Code session. Running sessions keep the hook config from session start. Worse, modifying the file mid-session can detach the entire PreToolUse-Bash chain in that session, so even pre-existing hooks stop firing until you restart. `install.sh` detects `$CLAUDE_CODE_ENTRYPOINT` and prints a loud warning + interactive y/N prompt when run from inside Claude Code; set `VAULT_GATE_FROM_CLAUDE=1` to skip the prompt for automation.
- **PATH order.** The wrapper at `~/.local/bin/bw` only works if `~/.local/bin` precedes `~/.npm-global/bin` in `$PATH`. `install.sh` appends a marker-guarded snippet to your `.bashrc` and `.profile` that prepends `~/.local/bin`. Open a new terminal (or `source ~/.bashrc`) after install. Verify with `which bw` — it should print `~/.local/bin/bw`, not `~/.npm-global/bin/bw`.

## Troubleshooting

- **Hook doesn't fire:** tail `$XDG_RUNTIME_DIR/vault-gate.log` and run a `bw` command in Claude Code. If the log is empty, the hook isn't being invoked — verify the entry in `~/.claude/settings.local.json` and restart Claude Code.
- **Ghostty window never opens:** hit the display-env issue. Confirm your desktop has a `ghostty` process running (`pgrep -x ghostty`) so the env import works.
- **Wrong password 5 times:** the script writes `failed` to the status file and gives up. Run another `bw` command to restart the flow, or unlock manually: `eval "$(bw unlock --raw)"`.
- **Keyring fallback message:** if you see `VAULT: secret-tool not found, falling back to file storage`, install `libsecret-tools` (see above) and it will start using keyring automatically.

## License

AGPL-3.0-or-later © 2026 Jeffrey Pine Hein. See [LICENSE](LICENSE).
