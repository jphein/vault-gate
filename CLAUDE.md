# CLAUDE.md — vault-gate

Project-specific instructions for Claude Code working in this repo.

## What this is

A Claude Code hook that auto-unlocks your Vaultwarden vault when a `bw` command is about to run. Popups a Ghostty window for the password, caches the session token.

## Key constraints

- **Claude Code hook format is stdin-JSON (not env vars).** Migrating from old `$CLAUDE_TOOL_INPUT` to `jq -r '.tool_input.command'` is a known pain point. Don't revert to env vars.
- **Display env is not inherited.** When spawning Ghostty from a hook, import `DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` from the running Ghostty PID. Without this, the unlock window silently fails.
- **Absolute paths everywhere.** Hook shells may not inherit `~/.npm-global/bin`. Use `$HOME/.npm-global/bin/bw` and `/usr/bin/ghostty` (native apt ghostty since 2026-08-26; the snap and the wsh/WaveTerm launcher branch are gone).
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

## Known shapes (bw from a timer or a ProxyCommand)

- **2026-11-14 07:42, stale session + closed stdin → bw exits 0 with nothing.** After familiar's 04:57 reboot a timer
  (status-coverage → realm-cloud `aws-env.sh` → `bw get item`) ran with a stale session token and `stdin=/dev/null`.
  bw prompted for the master password, node's readline threw `ERR_USE_AFTER_CLOSE` after the prompt, and bw **exited 0**
  with empty stdout and exactly 733 chars of stderr (reproduced on familiar with `BW_SESSION=invalid … </dev/null`).
  A caller that judges by exit code reads an empty success; the next layer says "no usable login", and the vault-locked
  signal never appears. **Rule:** every non-interactive bw call carries `--nointeraction` (measured: the same state then
  exits 1 "Vault is locked.") and treats rc 0 with empty stdout on `get`/`list` as a failure, never a value. Reference
  implementation: realm-cloud `bootstrap/bw_retry.py` (#229). Not yet proven on a real locked vault: the next reboot is
  the proof (ubox0 HANDOFF 2026-11-14).

## One vault CLI process at a time (`cli-lock.sh`, CHECK vault-cli-state; row 89ba0555)

- **The race (read from CLI 2026.6.0's source map):** `lowdb-storage.service.ts` takes its file lock at :70 only around
  `new FileSync(path)`. It parses data.json at :76 (`lowdb(adapter)`) **outside** that lock. On a `SyntaxError` (:78–93)
  it writes `{}`, and the migrations leave `{"stateVersion":N}`: the CLI is logged out with no logout anywhere.
  lowdb 1.0.0's `FileSync` writes with a non-atomic `writeFileSync`, so a CLI starting while another one writes can read
  half a file. It happened on familiar 2026-11-07 13:14:59 and 2026-11-17 20:31:13 (load 32, six timers at once).
- **`cli-lock.sh install`** wraps `~/.npm-global/bin/bw`, the one path every caller runs, with a host-wide `flock`
  (`$XDG_RUNTIME_DIR/vault-cli.lock`, wait 120 s, then exit 75). Interactive `unlock` and `login` skip the lock: a
  person at a password prompt would stall every other caller. An `npm` update replaces the entry, and the CHECK says so.
- **CHECK vault-cli-state** (`check-cli-state.sh`, `systemd/vault-cli-state.timer`, every 15 min): **fail** when
  data.json holds only `stateVersion` (wiped: re-login with `vault-login.sh`), **warn** when the entry is not locked.
  It reads key names only, never a value. A host without the CLI writes no line.
- Deploy order on a vault host: `cli-lock.sh install`, then link and enable the timer. Never during a re-login.

## Don't

- Don't reach into `~/.claude/settings.local.json` outside of `install.sh` / `uninstall.sh`. Manual JSON fiddling is how hooks drift.
- Don't write the master password to stdin or any file.
- Don't delete the session token (GNOME Keyring entry or `$XDG_RUNTIME_DIR/bw-session-token`) unless you also re-unlock; the hook's caching logic assumes the stored token is authoritative while present.
- **Storage config** lives at `~/.config/vault-gate/config`. `STORAGE=keyring` (default) uses GNOME Keyring via `secret-tool`; `STORAGE=file` uses `$XDG_RUNTIME_DIR` (mode 700 tmpfs).
- **Headless means "no seat0 graphical session" (loginctl), never "no gnome-shell"**: familiar's lane compositor is a headless gnome-shell. Test the headless path with `tests/run.sh` (stubs) and `VAULT_GATE_DRY_RUN=1`; never open a real window from a test.
- **The hook matcher is `vault-gate-match.py`**, not a grep; add a fixture for every new tripping/non-tripping shape before changing it.

