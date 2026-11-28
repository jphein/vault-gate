# vault-gate backends (outside sources this project talks to)

Rule 28 of the plan's FOR-AGENTS (2026-11-24; JP 11-21 "move token-requiring systems to token-less ones as we go"): every
row says whether it needs a token (`none`, `agent vault`, `JP own`) and what would remove it. vault-gate is the hook and
wrapper that unlock JP's Vaultwarden for `bw` commands; it holds no secret of its own and ships none. Written 2026-11-27
(Flow aa9ec2df, money).

| Source | What vault-gate does with it | Kind | Token | Token-less by | Status |
|---|---|---|---|---|---|
| Vaultwarden at vault.jphe.in (the real `bw` CLI, `~/.npm-global/bin/bw`) | unlock on demand (`vault-gate.sh` PreToolUse hook → Ghostty "Vault Unlock" window), `bw-wrapper.sh` injects the cached session into every `bw` call | JP's own vault; the master password is typed by JP in the window, never by an agent | JP own | the agents vault design (money Flow 534ae6f9: a Vaultwarden org "agents" with a machine login on familiar) moves lane secrets to `agent vault`; JP's personal items stay `JP own` by design | live |
| GNOME Keyring (`secret-tool`) | caches the unlocked `BW_SESSION` on a desktop host (default storage) | local OS keyring, no outside account | none | — | live on katana |
| `$XDG_RUNTIME_DIR/bw-session-token` (0600) | caches the session on hosts with no keyring (familiar); lanes test the file to learn the lock state without a `bw` probe | local file, no outside account | none | — | live on familiar |
| `cli-lock.sh` (flock under the runtime dir) | serialises concurrent `bw` calls from many lanes (one at a time; a pipeline of two `bw` calls deadlocks) | local lock, no outside account | none | money Flow c81d2860 measures the post-unlock queueing (three-minute waits on 2026-11-27) | live |
| Ghostty (`/usr/bin/ghostty`) | the native unlock window; display env imported from the running Ghostty PID | local app | none | — | live |
| `vault-cli-state.timer` / `check-cli-state.sh` (systemd user units) | periodic read of the CLI's own state (logged in / locked / stale token) so a logged-out vault opens the login window instead of hanging | local, reads `bw status` through the wrapper | none (reads JP's session when present) | — | live |
| GitHub jphein/vault-gate + Pages (jphein.github.io/vault-gate) | the repo and its docs site | code hosting | none for readers; pushes use `gh`'s credential helper on the lead's seats | — | live |

Nothing here calls a network service other than Vaultwarden (through `bw`) and GitHub (through `git`/`gh`). No API keys,
no third-party tokens. The one `JP own` dependency is the vault master password itself, which is the point of the project.
