#!/usr/bin/env bash
# Setup serialization and read-only network inspection. Source common.sh first.
# No sudo, preference changes, public fallback, or output evaluated as shell.
set +x

# The top-level mutating operation holds this descriptor for its lifetime.
# Nested installers inherit the same open-file description and do not deadlock
# by opening a second lock. Setup/teardown and service cutover must share it.
# Linux only; preflight must already have approved the private config directory.
tailscale_acquire_setup_lock() {
    local directory="$1"
    if [ ! -d "$directory" ] || [ -L "$directory" ] ||
       [ "$(stat -c '%u:%a' "$directory" 2>/dev/null)" != "$(id -u):700" ]; then
        echo 'Setup locking requires an owned mode-0700 configuration directory.' >&2
        return 1
    fi
    relay_acquire_setup_lock "$directory"
}

# Validate defaults without mkdir/chmod, reading credentials, or touching the
# service. Configuration creation belongs after the human approves the summary.
tailscale_setup_context() {
    local directory current command_name
    if [ "$(uname -s)" != Linux ]; then
        echo 'Tailscale setup currently supports Linux systemd user services only.' >&2
        return 1
    fi
    case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo 'Supported Tailscale setup architectures: amd64 and arm64.' >&2; return 1 ;; esac
    require_user_service_context || return 1
    case "$HOME" in /*) ;; *) return 1 ;; esac
    case "$HOME" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [ -d "$HOME" ] && [ "$(cd "$HOME" && pwd -P)" = "$HOME" ] || {
        echo 'Tailscale setup requires a canonical, non-symlinked home directory.' >&2
        return 1
    }
    TAILSCALE_CONFIG_DIR="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events"
    TAILSCALE_ENV="$TAILSCALE_CONFIG_DIR/relay.env"
    TAILSCALE_STATE="$TAILSCALE_CONFIG_DIR/tailscale-setup.json"
    TAILSCALE_LABEL=herdr-mobile-relay-tailscale.service
    TAILSCALE_UNIT_DIR="$HOME/.config/systemd/user"
    TAILSCALE_UNIT="$TAILSCALE_UNIT_DIR/$TAILSCALE_LABEL"
    TAILSCALE_RELEASE_ROOT="$HOME/.local/share/herdr-mobile-relay"
    if [ "${XDG_CONFIG_HOME:-$HOME/.config}" != "$HOME/.config" ] ||
       [ "${XDG_DATA_HOME:-$HOME/.local/share}" != "$HOME/.local/share" ] ||
       [ "${XDG_STATE_HOME:-$HOME/.local/state}" != "$HOME/.local/state" ] ||
       [ "${HERDR_PLUGIN_CONFIG_DIR:-$TAILSCALE_CONFIG_DIR}" != "$TAILSCALE_CONFIG_DIR" ] ||
       [ "${HERDR_RELAY_ENV:-$TAILSCALE_ENV}" != "$TAILSCALE_ENV" ] ||
       [ "${HERDR_RELEASE_ROOT:-$TAILSCALE_RELEASE_ROOT}" != "$TAILSCALE_RELEASE_ROOT" ] ||
       [ "${HERDR_RELAY_BIN:-$TAILSCALE_RELEASE_ROOT/current/herdr-mobile-relay}" != "$TAILSCALE_RELEASE_ROOT/current/herdr-mobile-relay" ]; then
        echo 'Custom XDG, plugin, environment or release paths require manual migration review; nothing changed.' >&2
        return 1
    fi
    for directory in "$TAILSCALE_CONFIG_DIR" "$TAILSCALE_UNIT_DIR" "$TAILSCALE_RELEASE_ROOT" "$HOME/.local/state/herdr-mobile-relay/recovery"; do
        current="$directory"
        while [ "$current" != / ]; do
            if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
                echo 'Refusing a symlinked or non-directory Tailscale setup path.' >&2
                return 1
            fi
            current="$(dirname "$current")"
        done
    done
    for command_name in timeout flock curl systemctl systemd-analyze sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "Missing setup prerequisite: $command_name (no tools were installed)." >&2
            return 1
        }
    done
    timeout 10 systemctl --user show-environment >/dev/null 2>&1 || {
        echo 'The systemd user manager is unavailable. Sign in normally; do not run setup with sudo.' >&2
        return 1
    }
}

tailscale_render_unit() {
    local work environment launcher
    work="$(systemd_quoted "$TAILSCALE_RELEASE_ROOT/current")" || return 1
    environment="$(systemd_quoted "HERDR_RELAY_ENV=$TAILSCALE_ENV")" || return 1
    launcher="$(systemd_quoted "$TAILSCALE_RELEASE_ROOT/current/relay/tailscale-service.sh" exec)" || return 1
    printf '%s\n' '# herdr-mobile-relay-tailscale-v1' '[Unit]' \
        'Description=Herdr Mobile Relay (private Tailscale access)' '' '[Service]' \
        'Type=simple' "WorkingDirectory=$work" "Environment=$environment" \
        "ExecStart=$launcher" 'Restart=on-failure' 'RestartSec=5' 'UMask=0077' '' \
        '[Install]' 'WantedBy=default.target'
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
