#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then
    echo 'Skipping Linux-only Tailscale setup locking tests'
    exit 0
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-lock.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
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
