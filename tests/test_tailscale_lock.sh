#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then
    echo 'Skipping Linux-only Tailscale setup locking tests'
    exit 0
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-lock.XXXXXX")"
child=''
trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
export HOME="$WORK/home"
mkdir -p "$HOME"
source "$REPO_DIR/relay/common.sh"
source "$REPO_DIR/relay/tailscale-common.sh"
unset HERDR_RELAY_SETUP_LOCK_FD

tailscale_acquire_setup_lock "$WORK"
[[ "$(stat -c %a "$WORK/.setup.lock")" == 600 ]]
first_fd="$HERDR_RELAY_SETUP_LOCK_FD"
# Re-entry and a nested installer use the inherited descriptor, not a new lock.
tailscale_acquire_setup_lock "$WORK"
[[ "$HERDR_RELAY_SETUP_LOCK_FD" == "$first_fd" ]]
bash -c 'source "$1/relay/common.sh"; source "$1/relay/tailscale-common.sh"; tailscale_acquire_setup_lock "$2"' _ "$REPO_DIR" "$WORK"
# A separate operation must fail, without waiting for the current owner.
if HERDR_RELAY_SETUP_LOCK_FD='' bash -c 'source "$1/relay/common.sh"; source "$1/relay/tailscale-common.sh"; tailscale_acquire_setup_lock "$2"' _ "$REPO_DIR" "$WORK" 2> "$WORK/error"; then
 echo 'concurrent operation acquired the lock' >&2; exit 1
fi
exec {first_fd}>&-
unset HERDR_RELAY_SETUP_LOCK_FD
tailscale_acquire_setup_lock "$WORK"
fd="$HERDR_RELAY_SETUP_LOCK_FD"
exec {fd}>&-
unset HERDR_RELAY_SETUP_LOCK_FD
# A long-lived child drops only its copy; the parent still excludes writers.
tailscale_acquire_setup_lock "$WORK"
mkfifo "$WORK/child-exit"
bash -c 'source "$1/relay/common.sh"; relay_drop_setup_lock "$2"; touch "$2/child-ready"; read -r _ < "$2/child-exit"' _ "$REPO_DIR" "$WORK" &
child=$!
for _ in {1..1000}; do [ ! -e "$WORK/child-ready" ] || break; sleep 0.01; done
[[ -e "$WORK/child-ready" ]]
if env -u HERDR_RELAY_SETUP_LOCK_FD bash -c 'source "$1/relay/common.sh"; relay_acquire_setup_lock "$2"' _ "$REPO_DIR" "$WORK" 2> "$WORK/error"; then echo 'child unlocked its parent lease' >&2; exit 1; fi
relay_drop_setup_lock "$WORK"
# The child is still alive but no longer pins the parent's lock.
kill -0 "$child"
bash -c 'source "$1/relay/common.sh"; relay_acquire_setup_lock "$2"' _ "$REPO_DIR" "$WORK"
printf 'done\n' > "$WORK/child-exit"
wait "$child"
child=''
rm "$WORK/.setup.lock"
printf 'keep\n' > "$WORK/foreign"
chmod 600 "$WORK/foreign"
ln -s "$WORK/foreign" "$WORK/.setup.lock"
if tailscale_acquire_setup_lock "$WORK" 2> "$WORK/error"; then echo 'symlink lock accepted' >&2; exit 1; fi
[[ "$(< "$WORK/foreign")" == keep ]]
rm "$WORK/.setup.lock"
chmod 755 "$WORK"
if tailscale_acquire_setup_lock "$WORK" 2> "$WORK/error"; then echo 'nonprivate lock directory accepted' >&2; exit 1; fi
[[ ! -e "$WORK/.setup.lock" ]]
echo 'Tailscale setup locking tests passed'
