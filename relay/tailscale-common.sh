#!/usr/bin/env bash
# Read-only prerequisites and inspection. Source common.sh first. No sudo,
# preference changes, public fallback, or command output evaluated as shell.
set +x

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
