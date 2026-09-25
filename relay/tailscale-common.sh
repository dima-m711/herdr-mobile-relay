#!/usr/bin/env bash
# Setup serialization and read-only network inspection. Source common.sh first.
# No sudo, preference changes, public fallback, or output evaluated as shell.
set +x

# The top-level mutating operation holds this descriptor for its lifetime.
# Nested installers inherit the same open-file description and do not deadlock
# by opening a second lock. Setup/teardown and service cutover must share it.
# Linux only; preflight must already have approved the private config directory.
tailscale_acquire_setup_lock() {
    local directory="$1" lock identity fd inherited="${HERDR_RELAY_SETUP_LOCK_FD:-}"
    lock="$directory/.setup.lock"
    if [ ! -d "$directory" ] || [ -L "$directory" ] ||
       [ "$(stat -c '%u:%a' "$directory" 2>/dev/null)" != "$(id -u):700" ]; then
        echo 'Setup locking requires an owned mode-0700 configuration directory.' >&2
        return 1
    fi
    command -v flock >/dev/null 2>&1 || {
        echo 'flock is required to serialize relay setup and service changes.' >&2
        return 1
    }
    if [ -e "$lock" ] || [ -L "$lock" ]; then
        private_owned_file "$lock" || {
            echo 'Refusing an unsafe relay setup lock file.' >&2
            return 1
        }
    fi
    if [ -n "$inherited" ]; then
        [[ "$inherited" =~ ^[0-9]+$ ]] || return 1
        identity="$(stat -c '%d:%i' "$lock" 2>/dev/null)" || return 1
        if [ "$(stat -Lc '%d:%i' "/proc/$BASHPID/fd/$inherited" 2>/dev/null)" != "$identity" ]; then
            echo 'Inherited relay setup lock does not match this configuration.' >&2
            return 1
        fi
        flock -n "$inherited" || return 1
        return 0
    fi
    local previous_umask
    previous_umask="$(umask)"
    umask 077
    if ! exec {fd}<>"$lock"; then
        umask "$previous_umask"
        return 1
    fi
    umask "$previous_umask"
    if ! private_owned_file "$lock" || ! flock -n "$fd"; then
        exec {fd}>&-
        echo 'Another relay setup or service change is in progress, or its lock is unsafe.' >&2
        return 1
    fi
    export HERDR_RELAY_SETUP_LOCK_FD="$fd"
}

tailscale_require_client() {
    local version major minor
    command -v tailscale >/dev/null 2>&1 || {
        echo 'Tailscale is required. Install and connect it before setup.' >&2
        return 1
    }
    command -v timeout >/dev/null 2>&1 || {
        echo 'GNU timeout is required for bounded Tailscale checks.' >&2
        return 1
    }
    version="$(timeout 10 tailscale version 2>/dev/null)" || {
        echo 'Cannot read the Tailscale client version.' >&2
        return 1
    }
    version="${version%%$'\n'*}"
    if [[ ! "$version" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]+([-.].*)?$ ]]; then
        echo 'Unrecognized Tailscale version; review the client before setup.' >&2
        return 1
    fi
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    if (( major < 1 || (major == 1 && minor < 52) )); then
        echo 'Tailscale 1.52 or newer is required for HTTPS Serve setup.' >&2
        return 1
    fi
}

tailscale_hostname() {
    local binary status
    tailscale_require_client || return 1
    binary="$(relay_binary)" || return 1
    status="$(timeout 10 tailscale status --json --peers=false 2>/dev/null)" || {
        echo 'Cannot inspect Tailscale. Confirm the daemon is running and connected.' >&2
        return 1
    }
    printf '%s' "$status" | "$binary" tailscale-inspect hostname
}

tailscale_serve_inspect() {
    local binary status
    [ "$#" -eq 3 ] || return 1
    tailscale_require_client || return 1
    binary="$(relay_binary)" || return 1
    status="$(timeout 10 tailscale serve status --json 2>/dev/null)" || {
        echo 'Cannot inspect Tailscale Serve. Resolve daemon access before setup; no state was changed.' >&2
        return 1
    }
    printf '%s' "$status" | "$binary" tailscale-inspect serve "$1" "$2" "$3"
}
