#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
TAILSCALE_SUDO=false
for argument in "$@"; do
    case "$argument" in
        --sudo) TAILSCALE_SUDO=true ;;
        --help|-h) echo 'Usage: tailscale-teardown.sh [--sudo] (private interactive terminal required)'; exit 0 ;;
        *) echo 'Unknown Tailscale teardown option.' >&2; exit 2 ;;
    esac
done
[ -t 0 ] && [ -t 1 ] || { echo 'Teardown requires your private interactive terminal; nothing changed.' >&2; exit 1; }
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
tailscale_setup_context
export HERDR_RELAY_ENV="$TAILSCALE_ENV" HERDR_RELEASE_ROOT="$TAILSCALE_RELEASE_ROOT"
TAILSCALE_BINARY="$(relay_binary)"
tailscale_no_other_services
# State is checked before opening/creating a lock. A missing record never
# authorizes inferring ownership from a matching service or endpoint.
PHASE="$(tailscale_state_value phase)"
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
tailscale_no_pending_update
PHASE="$(tailscale_state_value phase)"
TAILSCALE_HOST="$(tailscale_state_value hostname)"
TAILSCALE_HTTPS="$(tailscale_state_value https_port)"
TAILSCALE_PORT="$(tailscale_state_value relay_port)"
TAILSCALE_INSTANCE="$(tailscale_state_value instance)"
tailscale_check_state_identity
case "$PHASE" in
    removed)
        [ ! -e "$TAILSCALE_UNIT" ] && [ ! -L "$TAILSCALE_UNIT" ] &&
            [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] &&
            [ "$(native_systemd_state is-enabled "$TAILSCALE_LABEL")" = false ] || {
            echo 'Service resources reappeared after teardown; review them rather than inferring ownership.' >&2; exit 1;
        }
        echo 'Recorded teardown is complete; retained credentials and external routes are unchanged.'
        exit 0 ;;
    verified|teardown-pending) ;;
    *) echo 'An installation is incomplete. Recover it with tailscale-setup.sh --recover before teardown.' >&2; exit 1 ;;
esac
"$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT"
ENV_DIGEST="$(sha256sum "$TAILSCALE_ENV")"
UNIT_PRESENT=false
if [ -e "$TAILSCALE_UNIT" ] || [ -L "$TAILSCALE_UNIT" ]; then
    tailscale_check_managed_unit || { echo 'Unit changed; refusing to remove an unfamiliar definition.' >&2; exit 1; }
    tailscale_check_loaded_unit
    UNIT_PRESENT=true
    if [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = true ]; then
        pid="$(systemctl --user show "$TAILSCALE_LABEL" --property MainPID --value)"
        "$TAILSCALE_BINARY" tailscale-preflight listener "$pid" "$TAILSCALE_PORT" "$TAILSCALE_BINARY"
    fi
else
    [ "$PHASE" = teardown-pending ] && [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] || {
        echo 'The recorded service definition disappeared; inspect its ownership before cleanup.' >&2; exit 1;
    }
fi
[ "$(tailscale_hostname)" = "$TAILSCALE_HOST" ] || { echo 'Tailscale hostname changed; review endpoint ownership before cleanup.' >&2; exit 1; }
tailscale_read_serve
BEFORE_STATE="$TAILSCALE_ROUTE_STATE" BEFORE_DIGEST="$TAILSCALE_DIGEST"
OWNERSHIP="$(tailscale_state_value route_ownership)"
case "$OWNERSHIP" in created|adopted) ;; *) echo 'No verified endpoint ownership is recorded.' >&2; exit 1 ;; esac
echo "Disable and remove only $TAILSCALE_LABEL (including any runbook service explicitly adopted into this unit)."
echo 'Keep relay.env, device-auth, private backups and unrelated services/routes. No credentials will be deleted or rolled back.'
if [ "$OWNERSHIP" = created ] && [ "$BEFORE_STATE" = matching ]; then
    echo "Remove only the still-matching owned endpoint: tailscale serve --https=$TAILSCALE_HTTPS off"
    [ "$TAILSCALE_SUDO" = false ] || echo 'That scoped Serve removal will use sudo in this terminal.'
else echo 'No Serve route will be removed; adopted/external routes remain untouched.'; fi
tailscale_confirm 'Approve this teardown?'
# Capture a new baseline for teardown; unrelated routes may legitimately have
# changed since installation. Only changes during this operation are conflicts.
"$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT"
[ "$(sha256sum "$TAILSCALE_ENV")" = "$ENV_DIGEST" ] || { echo 'Environment changed during approval; aborting.' >&2; exit 1; }
if [ "$UNIT_PRESENT" = true ]; then tailscale_check_managed_unit; tailscale_check_loaded_unit
else [ ! -e "$TAILSCALE_UNIT" ] && [ ! -L "$TAILSCALE_UNIT" ] || exit 1; fi
tailscale_read_serve
[ "$TAILSCALE_ROUTE_STATE" = "$BEFORE_STATE" ] && [ "$TAILSCALE_DIGEST" = "$BEFORE_DIGEST" ] || { echo 'Serve changed during approval; aborting.' >&2; exit 1; }
if [ "$PHASE" = verified ]; then "$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" verified teardown-pending; fi
if [ "$OWNERSHIP" = created ] && [ "$TAILSCALE_ROUTE_STATE" = matching ]; then
    tailscale_change_route remove
    tailscale_read_serve
    [ "$TAILSCALE_ROUTE_STATE" = absent ] && [ "$TAILSCALE_DIGEST" = "$BEFORE_DIGEST" ] || { echo 'Serve changed during removal; teardown remains pending for review.' >&2; exit 1; }
fi
if [ "$UNIT_PRESENT" = true ]; then
    systemctl --user disable --now "$TAILSCALE_LABEL"
    tailscale_check_managed_unit
    tailscale_check_loaded_unit
    [ "$(sha256sum "$TAILSCALE_ENV")" = "$ENV_DIGEST" ] || exit 1
    rm -- "$TAILSCALE_UNIT"
fi
systemctl --user daemon-reload
[ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] && [ "$(native_systemd_state is-enabled "$TAILSCALE_LABEL")" = false ] || exit 1
"$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" teardown-pending removed
echo 'Owned teardown complete. Credentials and paired-device data were retained; adopted routes were not removed.'
