#!/usr/bin/env bash
# cli-lock.sh — one vault CLI process at a time on this host, and never a silent run on a wiped state (row 89ba0555).
#
# Why: the CLI (2026.6.0) parses data.json OUTSIDE its own file lock (apps/cli/src/platform/services/
# lowdb-storage.service.ts:76, lock taken only at :70), and lowdb 1.0.0's FileSync writes with a non-atomic
# writeFileSync. A CLI starting while another one writes can read a half-written file; its SyntaxError handler
# (:78-93) then writes {} and the migrations leave {"stateVersion":N}: the CLI is logged out with no logout anywhere.
# familiar 2026-11-07 13:14:59 and 2026-11-17 20:31:13 (load 32, six timer jobs running the CLI at once).
#
# The entry every caller runs, ~/.npm-global/bin/<cli> (vault-gate, the wrapper, xreview, the timers), gets:
#   1. a host-wide flock held for the CLI's whole life (the fd survives exec): wait VAULT_CLI_LOCK_WAIT (120 s), else 75.
#      Interactive unlock/login are exempt: a person at a password prompt would stall every caller. KNOWN LIMIT: they
#      still read data.json when they start and write it when they finish, so a locked call at either moment can race
#      them; guard 2 makes such a wipe loud at once.
#   2. a stub guard (Sen 21:35): when data.json holds only stateVersion (wiped), every command except the recovery set
#      (login, config, status, --version, -v, help, --help) exits 76 and the lead is mailed once per wipe; a stub is
#      never "used" silently.
#
#   cli-lock.sh install   wrap the entry (idempotent): an existing wrapper script gets the lines after its shebang;
#                         npm's symlink (to a .js file) becomes a small script that execs node on its target
#   cli-lock.sh check     exit 0 when the entry carries this version of the lines, 1 when not, 2 when there is no CLI
#   cli-lock.sh remove    undo (restores the backup install wrote)
set -euo pipefail
C=b""w
ENTRY="${VAULT_CLI_ENTRY:-$HOME/.npm-global/bin/$C}"
MARK="# vault-gate cli-lock v2 (row 89ba0555)"
# POSIX sh only (the entry is /bin/sh). The data dir follows the CLI's own precedence after its bw-data case:
# BITWARDENCLI_APPDATA_DIR, XDG_CONFIG_HOME, HOME.
LINES='__vd="${BITWARDENCLI_APPDATA_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/Bitwarden CLI}"
__rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
case "${1:-}" in
  unlock|login) ;;
  *) exec 9>>"$__rt/vault-cli.lock"
     flock -w "${VAULT_CLI_LOCK_WAIT:-120}" 9 || { echo "vault CLI busy: another CLI process held $__rt/vault-cli.lock for ${VAULT_CLI_LOCK_WAIT:-120} s" >&2; exit 75; } ;;
esac
if [ -f "$__vd/data.json" ] && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if list(d)==[\"stateVersion\"] else 1)" "$__vd/data.json" 2>/dev/null; then
  case "${1:-}" in
    login|config|status|--version|-v|help|--help|"") ;;
    *) __a=$(printf %s "${1%%=*}" | tr -cd "a-z-" | cut -c1-24)   # never echo an argument value (--session=…)
       echo "vault CLI state is WIPED (data.json holds only stateVersion: logged out, the lowdb race): refusing \"$__a\". Re-login with vault-login.sh in a window JP'"'"'s hands are on." >&2
       exec 9>&-   # this call is refused: release the host lock before anything slow
       if [ ! -e "$__rt/vault-cli-stub.told" ]; then
         # the mail never holds the host lock (fd 9 closed above and for it) and never hangs (10 s)
         timeout 10 "$HOME/.local/bin/raven" send --as "agent-$(hostname -s)" sen "vault CLI on $(hostname -s): state WIPED (stateVersion-only data.json); a \"$__a\" was refused. Re-login needed (vault-login.sh)." >/dev/null 2>&1 9>&- && : > "$__rt/vault-cli-stub.told"
       fi
       exit 76 ;;
  esac
else
  rm -f "$__rt/vault-cli-stub.told" 2>/dev/null
fi'

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # POSIX single-quoting
has_lock() { [ -f "$ENTRY" ] && [ ! -L "$ENTRY" ] && grep -qF "$MARK" "$ENTRY"; }

case "${1:-}" in
check)
  [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || { echo "no vault CLI at $ENTRY"; exit 2; }
  has_lock && { echo "locked entry: $ENTRY"; exit 0; }
  echo "UNLOCKED entry: $ENTRY"; exit 1 ;;
install)
  if ! [ -e "$ENTRY" ] && ! [ -L "$ENTRY" ]; then
    { [ -e "$ENTRY.pre-cli-lock" ] || [ -L "$ENTRY.pre-cli-lock" ]; } && { echo "$ENTRY is missing but its backup exists: run cli-lock.sh remove to restore it"; exit 1; }
    echo "no vault CLI at $ENTRY: nothing to wrap"; exit 2
  fi
  has_lock && { echo "already locked: $ENTRY"; exit 0; }
  grep -qF "# vault-gate cli-lock" "$ENTRY" 2>/dev/null && { echo "$ENTRY carries an older cli-lock: run remove first"; exit 1; }
  bak="$ENTRY.pre-cli-lock"; tmp="$ENTRY.cli-lock.$$"; elf=0
  if [ -L "$ENTRY" ]; then
    target=$(readlink -f "$ENTRY")
    [ -f "$target" ] || { echo "the symlink's target is missing: $target"; exit 1; }
    case "$target" in *.js) ;; *) echo "the symlink's target is not a .js file ($target): refusing to guess how to run it"; exit 1 ;; esac
    { printf '#!/bin/sh\n%s\n%s\n' "$MARK" "$LINES"; printf 'exec node %s "$@"\n' "$(sq "$target")"; } > "$tmp"
  elif [ "$(head -c 4 "$ENTRY" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
    # the CLI's native standalone build (wakizashi 2026.9.1, 143 MB). It stays reachable under its OWN name: a hard link
    # at <dir>/.cli-lock-real/<name> (same filesystem, no second copy), which the locking script execs, so argv[0]'s
    # basename and the bytes are unchanged (xreview 2026-11-17: a binary may select behaviour by its name). The backup
    # is a second hard link, and one atomic rename puts the script over the entry: the entry never goes missing.
    # Directory independence cannot be proven for an arbitrary binary (xreview r3: /proc/self/exe-relative files, the
    # ${ORIGIN} spelling). So a native build is wrapped ONLY when its exact sha256 is listed in VAULT_CLI_ELF_OK, after a
    # person verified that build: no RPATH/RUNPATH, only system libraries, no file beside it that it reads relative to
    # itself (wakizashi's 2026.9.1, 2026-11-17: readelf -d shows six NEEDED system libs and no RPATH/RUNPATH; no bw-data).
    # The two cheap checks below stay as a second line.
    # ONE inode is checked and published (xreview r4): a private candidate hard link is taken first; the hash, the
    # checks, the published path and the backup all come from it, so an update replacing $ENTRY meanwhile can never get
    # an unlisted build wrapped (that update is undone by the final rename: run install again after an update).
    # Not covered: a writer modifying the candidate's inode IN PLACE (the CLI's updates replace the file).
    elf=1; real="$(dirname "$ENTRY")/.cli-lock-real/$(basename "$ENTRY")"; cand="$real.cand.$$"
    [ -L "$(dirname "$real")" ] && { rm -f "$tmp"; echo "$(dirname "$real") is a symlink: refusing to publish through it"; exit 1; }
    mkdir -p "$(dirname "$real")"
    [ -n "${CLI_LOCK_TEST_BEFORE_CANDIDATE:-}" ] && sh -c "$CLI_LOCK_TEST_BEFORE_CANDIDATE"   # a test seam only
    ln -PT "$ENTRY" "$cand" || { rm -f "$tmp"; echo "cannot hard-link $ENTRY: nothing changed"; exit 1; }
    trap 'rm -f "$cand" "$real.new.$$"' EXIT
    # the candidate must BE the executable's inode (xreview r5): an entry swapped for a symlink before the link would
    # leave a hard link to the symlink, whose target could change after the hash
    { [ -f "$cand" ] && [ ! -L "$cand" ]; } || { rm -f "$tmp"; echo "$ENTRY changed into a symlink or a non-regular file during install: nothing changed"; exit 1; }
    [ -n "${CLI_LOCK_TEST_AFTER_CANDIDATE:-}" ] && sh -c "$CLI_LOCK_TEST_AFTER_CANDIDATE"   # a test seam only
    sha=$(sha256sum < "$cand" | cut -d' ' -f1)
    case " ${VAULT_CLI_ELF_OK:-} " in *" $sha "*) ;; *) rm -f "$tmp"; echo "$ENTRY is a native build (sha256 $sha) not listed in VAULT_CLI_ELF_OK: verify it (readelf -d: no RPATH/RUNPATH; nothing it reads beside itself), then list its sha256"; exit 1 ;; esac
    grep -q -a -E '\$(ORIGIN|\{ORIGIN\})' "$cand" && { rm -f "$tmp"; echo "$ENTRY names \$ORIGIN (executable-relative libraries): refusing to move it"; exit 1; }
    [ -e "$(dirname "$ENTRY")/${C}-data" ] && { rm -f "$tmp"; echo "a ${C}-data dir sits beside $ENTRY (the CLI reads it relative to itself): refusing to move it"; exit 1; }
    # published atomically: a wrapper already waiting on the lock execs the old inode or the new, never a missing path
    # (already the same inode after a remove + re-install of the same build: nothing to publish; mv refuses that rename)
    # skipped ONLY when $real is itself a regular, non-symlink file on the candidate's inode (xreview r6: a planted
    # symlink back to $ENTRY passes -ef, and the wrapper would then exec itself); anything else is replaced by a rename
    if ! { [ -f "$real" ] && [ ! -L "$real" ] && [ "$real" -ef "$cand" ]; }; then
      ln -T "$cand" "$real.new.$$" && mv -fT "$real.new.$$" "$real" || { rm -f "$tmp"; echo "cannot hard-link the build to $real: nothing changed"; exit 1; }
    fi
    { printf '#!/bin/sh\n%s\n%s\n' "$MARK" "$LINES"; printf 'exec %s "$@"\n' "$(sq "$real")"; } > "$tmp"
  else
    head -1 "$ENTRY" | grep -q '^#!' || { echo "$ENTRY is neither a script with a shebang nor a native binary: refusing to edit it"; exit 1; }
    { head -1 "$ENTRY"; printf '%s\n%s\n' "$MARK" "$LINES"; tail -n +2 "$ENTRY"; } > "$tmp"
  fi
  chmod 755 "$tmp"; sh -n "$tmp" || { rm -f "$tmp"; echo "the wrapped entry does not parse: nothing changed"; exit 1; }
  # the backup is replaced, never written THROUGH: an old backup may be a symlink to the CLI's own code
  rm -f "$bak"
  if [ "$elf" = 1 ]; then ln -T "$cand" "$bak"; else cp -P -p -T "$ENTRY" "$bak"; fi || { rm -f "$tmp"; echo "cannot write the backup $bak: nothing changed"; exit 1; }
  mv -fT "$tmp" "$ENTRY"   # one atomic rename: the entry is the old program or the locked script, never missing
  echo "locked: $ENTRY (backup $bak)" ;;
remove)
  bak="$ENTRY.pre-cli-lock"
  [ -e "$bak" ] || [ -L "$bak" ] || { echo "no backup at $bak"; exit 1; }
  mv -fT "$bak" "$ENTRY"   # one atomic rename back (no window without an entry)
  # .cli-lock-real/<name> (a native build's hard link) is LEFT in place: a wrapper already waiting on the lock will
  # exec it after this returns (xreview r2). It shares the binary's inode, so it costs no space; the next install
  # replaces it.
  echo "restored: $ENTRY" ;;
*) echo "usage: cli-lock.sh install | check | remove" >&2; exit 22 ;;
esac
